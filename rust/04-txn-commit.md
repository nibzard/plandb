# Transaction Commit Specification

## Purpose

The commit operation transforms a WriteTxn's buffered mutations into a durable, visible database state. It implements a multi-phase commit protocol that guarantees atomicity (all-or-nothing visibility) and durability (survives crashes and reboots). The commit flow coordinates between the WAL, B+tree, meta pages, and snapshot registry to ensure a consistent transactional state.

This specification describes the complete commit algorithm, including the critical fsync ordering that prevents data loss, the crash recovery boundaries at each phase, and the error handling that ensures no partial commits become visible.

---

## Types

### CommitPhase

**Description**: Represents the current phase of a two-phase commit operation. Used for crash recovery analysis and debugging.

**Variants**:
- `Prepare` - Validating transaction state and mutations before persistence
- `Apply` - Executing B+tree mutations to compute new root page ID
- `Append` - Writing commit record to log file and syncing to disk
- `Meta` - Updating meta page (A/B flip) and syncing database file
- `Finalize` - Registering snapshot, cleaning up resources, publishing new state
- `RolledBack` - Transaction was rolled back due to error or explicit abort
- `Committed` - Transaction successfully committed and visible to readers

**Invariants**:
- Phase transitions are strictly monotonic (forward only, no reversions)
- Once a phase completes, all resources acquired in that phase must be released on rollback
- Only `Committed` transactions are visible to new ReadTxn instances
- Crashes during any phase before `Committed` result in rollback or retry

### CommitResult

**Description**: Result of a commit operation, containing either the new transaction ID or a commit error.

**Variants**:
- `Ok(txn_id: u64)` - Transaction committed successfully, returns new TxnId
- `Err(CommitError)` - Commit failed, transaction rolled back

**Fields** (on success):
- `txn_id` - The newly allocated transaction ID (monotonically increasing)
- This `txn_id` is now visible to readers calling `begin_read(latest)`

### CommitError

**Description**: Errors that can occur during commit, categorized by phase and severity.

**Variants**:
- `TxnClosed` - Transaction already committed or rolled back
- `NoMutations` - Commit called with zero mutations (use error or allow empty commits?)
- `PrepareFailed(PrepareError)` - Validation or conflict detection failed
- `ApplyFailed(ApplyError)` - B+tree mutation execution failed
- `AppendFailed(AppendError)` - WAL append or log file write failed
- `MetaFailed(MetaError)` - Meta page update failed
- `FinalizeFailed(FinalizeError)` - Snapshot registration or cleanup failed
- `IoError(io::Error)` - Underlying I/O operation failed
- `FsSyncFailed` - fsync failed after write (durability violation)
- `LogWriteFailed` - Log file write failed before sync
- `MetaUpdateFailed` - Meta page A/B flip failed
- `SnapshotRegistryFull` - Cannot register new snapshot (capacity limit)
- `DuplicateTxnId` - TxnId already exists in registry (should never happen)

**Recovery Strategy**:
- All errors except `DuplicateTxnId` are recoverable (rollback transaction)
- `DuplicateTxnId` indicates database corruption or TxnId allocator bug
- Errors after `Append` phase may leave durable commit record in log (replay on recovery)

### CommitContext

**Description**: Holds all context needed to execute a commit, including mutation buffers, new root page ID, and allocated TxnId.

**Fields**:
- `txn_id: u64` - Allocated transaction ID for this commit
- `mutations: Vec<Mutation>` - Buffer of pending mutations (Put/Delete operations)
- `mutation_count: usize` - Number of mutations in buffer
- `mutation_bytes: usize` - Total bytes of all mutations (size tracking)
- `root_page_id_before: u64` - Root page ID before applying mutations (for rollback)
- `root_page_id_after: u64` - Root page ID after applying mutations (new committed root)
- `commit_lsn: u64` - LSN of commit record in log (after append phase)
- `start_phase: CommitPhase` - Phase where commit started (for crash recovery)
- `end_phase: CommitPhase` - Phase where commit ended (success or failure)

**Invariants**:
- `mutation_count` must equal `mutations.len()`
- `root_page_id_after` is valid only after `Apply` phase completes
- `commit_lsn` is valid only after `Append` phase completes
- `end_phase >= start_phase` (phases are monotonic)

---

## Functions

### commit(&mut self) -> Result<u64, CommitError>

**Purpose**: Atomically commit all mutations buffered in this WriteTxn, making them visible to future read transactions. This is the primary durability operation - after successful commit returns, all changes are guaranteed to survive process crash and OS reboot.

**Parameters**:
- `&mut self` - Mutable borrow of WriteTxn (consumes the transaction)

**Returns**:
- `Result<u64, CommitError>` - New transaction ID on success, error on failure

**Preconditions**:
- Transaction state must be `Active` (not already committed/rolled back)
- At least one mutation must be buffered (or policy decision on empty commits)
- Database must be in file-backed mode (not pure in-memory)
- WAL and Pager must be initialized

**Postconditions** (on success):
- Transaction state transitions to `Committed`
- All mutations are visible to new `begin_read(latest)` calls
- Commit record is durable in log file (survives crash)
- Meta page points to new root page ID (survives crash)
- Database file is synced to disk (survives crash)
- New snapshot registered in snapshot registry at `txn_id`
- Write lock is released (new WriteTxn can begin)
- Old WriteTxn handle is invalidated (cannot be used again)

**Postconditions** (on error):
- Transaction state transitions to `RolledBack`
- No mutations are visible to any reader
- Write lock is released (new WriteTxn can begin)
- Resources are cleaned up (buffers freed, locks released)
- Transaction handle is invalidated

**Algorithm**:

**Phase 1: Prepare** (validation and conflict checking)
1. Check transaction state - if not `Active`, return `TxnClosed` error
2. Validate mutation count - if zero, return `NoMutations` error (or policy decision)
3. Validate mutation bytes - if exceeds `MAX_MUTATION_BYTES`, return error
4. Check for key conflicts within pending mutations (last-write-wins already enforced)
5. Call `context.prepare()` to validate mutation ordering and size
6. If prepare fails, return `PrepareFailed` and transition to `RolledBack`
7. Record current root page ID as `root_page_id_before`

**Phase 2: Apply** (execute B+tree mutations)
1. Create copy of current root page ID: `root_page_id = pager.getRootPageId()`
2. For each mutation in `context.mutations` (in order):
   a. If `Put(key, value)`:
      - Call `pager.putBtreeValue(key, value, txn_id)`
      - If put fails (page allocation, split, corruption), return `ApplyFailed`
   b. If `Delete(key)`:
      - Call `pager.deleteBtreeValue(key, txn_id)`
      - If delete fails (key not found, page merge error), return `ApplyFailed`
3. After all mutations applied, get new root page ID: `root_page_id_after = pager.getRootPageId()`
4. Store `root_page_id_after` in commit context
5. If root page ID unchanged (no actual B+tree modifications), still commit (idempotent)
6. Record phase as `Apply` in commit context

**Phase 3: Append** (write commit record to log)
1. Create commit record using `context.createCommitRecord(root_page_id_after)`:
   - Encode record header (magic, version, type, txn_id, prev_lsn, lengths)
   - Encode commit payload header (CMIT magic, txn_id, root_page_id_after, op_count)
   - Encode operations (Put/Delete) in mutation order
   - Calculate header CRC32C (with checksum field zeroed)
   - Calculate payload CRC32C
   - Encode trailer (magic2, total_len, trailer_crc32c)
2. Open or create log file at `<db_path>.log` (append mode)
3. Seek to end of log file to get current LSN position
4. Write commit record bytes to log file
5. If write fails (disk full, I/O error), close log and return `AppendFailed`
6. **CRITICAL DURABILITY STEP**: Call `fsync(log_file)` to flush to disk
7. If fsync fails, return `FsSyncFailed` (commit record may be lost)
8. Store the LSN position as `commit_lsn` in commit context
9. Close log file handle (or keep open for batching optimization)
10. Record phase as `Append` in commit context

**Crash Recovery Point A**: If crash occurs after Phase 3 fsync completes:
- Commit record is durable in log file
- Meta page NOT yet updated (old root still valid)
- Recovery will replay commit record and update meta page

**Phase 4: Meta** (update meta page with new root)
1. Get current meta state from pager: `current_meta = pager.current_meta`
2. Create new meta copy: `new_meta = current_meta.meta.clone()`
3. Update `new_meta.committed_txn_id = txn_id`
4. Determine opposite meta page ID (A/B flip):
   - If `current_meta.page_id == META_PAGE_A`, use `META_PAGE_B`
   - If `current_meta.page_id == META_PAGE_B`, use `META_PAGE_A`
5. Encode meta page into buffer: `encodeMetaPage(opposite_meta_id, new_meta, buffer)`
6. Write meta page buffer to file at opposite page offset
7. If write fails, return `MetaFailed` (old meta still valid)
8. Update pager's `current_meta` to point to new meta page
9. **CRITICAL DURABILITY STEP**: Call `pager.commitSync()` which calls `fsync(db_file)`
10. If fsync fails, return `FsSyncFailed` (meta update may be lost)
11. Record phase as `Meta` in commit context

**Crash Recovery Point B**: If crash occurs after Phase 4 fsync completes:
- Commit record is durable in log file
- Meta page updated with new txn_id and root_page_id
- Recovery will read latest valid meta page and commit record matches
- Transaction is fully committed and visible

**Phase 5: Finalize** (register snapshot, cleanup, publish)
1. Register new snapshot in snapshot registry:
   - Call `registry.registerSnapshot(txn_id, root_page_id_after)`
   - If registry full, apply eviction policy or return `SnapshotRegistryFull`
2. Update transaction context state to `Committed`
3. Release write lock: `db.writer_active = false`
4. Clear mutation buffers: `context.mutations.clear()`
5. Execute plugin `on_commit` hooks (if any):
   - Create `CommitContext` with txn_id, mutations, root_page_id
   - Call each plugin's `on_commit` callback
   - Plugin errors logged but do not fail commit (best-effort)
6. Invalidate WriteTxn handle (set state to `Committed`)
7. Record phase as `Finalize` then transition to `Committed`
8. Return `Ok(txn_id)` to caller

**Crash Recovery Point C**: If crash occurs during Phase 5:
- Commit record is durable in log file
- Meta page is updated with new txn_id and root_page_id
- Snapshot registration may be incomplete (will be rebuilt on recovery)
- Recovery will rebuild snapshot registry from meta history and commit records
- Transaction is fully committed and visible (registration is optimization)

**Error Handling During Commit**:
- If any phase fails, execute rollback sequence:
  1. Release write lock (if held)
  2. Clear mutation buffers
  3. Invalidate WriteTxn handle
  4. Transition state to `RolledBack`
  5. Return error to caller
- **IMPORTANT**: Do NOT attempt to undo Phase 3 or Phase 4 (leave durable state for recovery)
- Recovery process will detect incomplete commits (durable log record but no meta update)
- Recovery will either complete the commit (apply mutations) or roll it back (truncate log)

**Concurrency Considerations**:
- Only one WriteTxn can commit at a time (single writer enforced by `begin_write`)
- Readers never block on commit (they continue using old snapshots)
- New readers after commit will see new state (via meta page or snapshot registry)
- Write lock is held for entire commit duration (begin_write to commit/rollback)
- Future multi-writer: need conflict detection and retry logic in Phase 1

**Performance Characteristics**:
- Phase 1 (Prepare): O(1) validation checks
- Phase 2 (Apply): O(M * log N) where M = mutation count, N = total keys
- Phase 3 (Append): O(M) to encode and write commit record, plus fsync latency
- Phase 4 (Meta): O(1) meta update, plus fsync latency
- Phase 5 (Finalize): O(1) registry update and cleanup
- Total latency dominated by two fsync calls (log file and database file)
- Batch optimization: keep log file open across commits to reduce open/close overhead

---

## Invariants

### Commit Phase Invariants
- Phase transitions are strictly monotonic (forward only)
- Once a phase completes successfully, all subsequent phases must be attempted
- Crash during commit results in either rollback or recovery (no partial visibility)

### Atomicity Invariants
- All mutations become visible simultaneously at commit completion
- No mutations are visible if commit fails
- Readers see either all mutations or none (never partial state)

### Durability Invariants
- After `commit()` returns `Ok(txn_id)`, the commit survives process crash
- After `commit()` returns `Ok(txn_id)`, the commit survives OS reboot
- Fsync ordering: log file fsync BEFORE meta page fsync
- Meta page fsync is the final durability step (must complete before return)

### Ordering Invariants
- TxnId allocation is monotonic (each commit gets higher TxnId than previous)
- Commit records are appended to log in TxnId order
- Meta page TxnId is always the latest committed transaction
- Snapshots are ordered by TxnId (higher TxnId = later in time)

### Fsync Ordering Invariants (CRITICAL)
1. Write commit record to log file
2. fsync(log_file) - ensure commit record is durable
3. Write meta page with new txn_id and root_page_id
4. fsync(db_file) - ensure meta update is durable
5. Return success to caller

This ordering ensures:
- If crash after step 2 but before step 4: recovery will find commit record and complete meta update
- If crash before step 2: commit record is lost, transaction is not committed (correct rollback)
- If crash after step 4: commit is fully durable, recovery will find valid meta page

### Recovery Invariants
- Recovery reads latest valid meta page (by checksum and highest TxnId)
- Recovery verifies commit record exists for meta's TxnId
- If commit record missing, meta page is invalid (corruption detected)
- If commit record exists but meta not updated, recovery completes commit
- Recovery rebuilds snapshot registry from meta history and commit records

### Error Handling Invariants
- All errors result in transaction rollback (no partial commits)
- Error returns never leave database in inconsistent visible state
- Write lock is always released on error (allows new WriteTxn)
- Transaction handle is always invalidated on error (prevents reuse)

---

## Dependencies

### Uses
- **WriteTxn** (task 4.4) - Transaction type with mutation buffer
- **TransactionContext** (task 4.2) - Mutation tracking and state management
- **CommitRecord** (spec/commit_record_v0.md) - Binary format for commit persistence
- **WAL** (phase 3) - Commit record append and fsync operations
- **Pager** (phase 2) - B+tree mutations and meta page management
- **SnapshotRegistry** (phase 5) - Snapshot registration and lookup
- **PluginManager** (phase 7) - Commit hooks and event notifications

### Used By
- **Db** (phase 7) - Public API for commit operations
- **Recovery** (phase 3) - Crash recovery uses commit records to rebuild state
- **Replication** (future) - Commit records become replication payload

---

## Rust Implementation Guidance

### Module Structure

The commit implementation should be organized in `src/txn/commit.rs` with:

```rust
// Public commit API
impl WriteTxn {
    pub fn commit(&mut self) -> Result<u64, CommitError>;
}

// Internal commit context and phases
pub struct CommitContext {
    pub txn_id: u64,
    pub mutations: Vec<Mutation>,
    pub root_page_id_before: u64,
    pub root_page_id_after: u64,
    pub commit_lsn: u64,
    pub start_phase: CommitPhase,
    pub end_phase: CommitPhase,
}

// Commit phases (internal)
impl CommitContext {
    fn phase1_prepare(&mut self) -> Result<(), CommitError>;
    fn phase2_apply(&mut self, pager: &mut Pager) -> Result<(), CommitError>;
    fn phase3_append(&mut self, log_path: &Path) -> Result<(), CommitError>;
    fn phase4_meta(&mut self, pager: &mut Pager) -> Result<(), CommitError>;
    fn phase5_finalize(&mut self, registry: &mut SnapshotRegistry) -> Result<(), CommitError>;
}
```

### Type Definitions

**CommitPhase**: Use enum with explicit variants for each phase:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum CommitPhase {
    Prepare = 1,
    Apply = 2,
    Append = 3,
    Meta = 4,
    Finalize = 5,
    RolledBack = 99,
    Committed = 100,
}
```

Derive `PartialOrd` and `Ord` to enable monotonic phase checking (`end_phase >= start_phase`).

**CommitError**: Use thiserror enum for structured errors:

```rust
use thiserror::Error;

#[derive(Error, Debug)]
pub enum CommitError {
    #[error("transaction already closed")]
    TxnClosed,

    #[error("no mutations to commit")]
    NoMutations,

    #[error("prepare phase failed: {0}")]
    PrepareFailed(#[from] PrepareError),

    #[error("apply phase failed: {0}")]
    ApplyFailed(#[from] ApplyError),

    #[error("append phase failed: {0}")]
    AppendFailed(#[from] AppendError),

    #[error("meta phase failed: {0}")]
    MetaFailed(#[from] MetaError),

    #[error("finalize phase failed: {0}")]
    FinalizeFailed(#[from] FinalizeError),

    #[error("I/O error: {0}")]
    IoError(#[from] io::Error),

    #[error("fsync failed - durability violation")]
    FsSyncFailed,

    #[error("log file write failed")]
    LogWriteFailed,

    #[error("meta page update failed")]
    MetaUpdateFailed,

    #[error("snapshot registry full")]
    SnapshotRegistryFull,

    #[error("duplicate txn_id {0} - corruption detected")]
    DuplicateTxnId(u64),
}
```

**CommitResult**: Use standard `Result<u64, CommitError>`.

### Concurrency

**Write Lock**: Commit holds write lock for entire duration (begin_write to commit/rollback):

```rust
struct Db {
    writer_active: AtomicBool,  // Enforce single writer
}

impl Db {
    fn begin_write(&self) -> Result<WriteTxn, DbError> {
        // Try to acquire write lock
        if self.writer_active.compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed).is_err() {
            return Err(DbError::WriteBusy);
        }

        // Create WriteTxn with release guard
        Ok(WriteTxn { ... })
    }
}

impl Drop for WriteTxn {
    fn drop(&mut self) {
        // Release write lock on drop
        self.db.writer_active.store(false, Ordering::Release);
    }
}
```

**Readers Never Block**: Readers use snapshots, which are immutable:

```rust
impl ReadTxn {
    // No locks needed - reads from immutable snapshot
    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, ReadError> {
        // Direct B+tree lookup using snapshot.root
        self.db.btree_get(self.snapshot.root, key)
    }
}
```

**Fsync Is Critical**: Use `File::sync_all()` for durability:

```rust
use std::fs::File;
use std::io::Write;

fn phase3_append(log_path: &Path, record: &[u8]) -> Result<u64, CommitError> {
    let mut log_file = OpenOptions::new()
        .write(true)
        .append(true)
        .create(true)
        .open(log_path)?;

    let lsn = log_file.seek(SeekFrom::End(0))?;
    log_file.write_all(record)?;
    log_file.sync_all()?; // CRITICAL: fsync before meta update

    Ok(lsn)
}
```

### Key Decisions

**Empty Commits**: Should commits with zero mutations be allowed?
- **Option A**: Return `NoMutations` error (current spec approach)
- **Option B**: Allow empty commits (useful for transaction markers)
- **Recommendation**: Allow empty commits but flag with `is_empty` in CommitRecord

**Fsync Strategy**: When to fsync?
- **Log file**: Must fsync after EVERY commit record write (no batching)
- **Database file**: Must fsync after EVERY meta page update (no batching)
- **Optimization**: Batch multiple commits and fsync once at end of batch
- **V0 Approach**: Fsync every commit (correctness over performance)

**Meta Page A/B Flip**: Why alternate meta pages?
- **Atomicity**: Write to opposite page, then flip on fsync
- **Corruption Detection**: Checksum both pages, pick valid one with highest TxnId
- **Crash Safety**: If crash during write, old page is still valid

**Commit Record in Separate File**: Why not embed in database file?
- **Simpler Fsync Ordering**: Separate file allows clear log → meta ordering
- **Append-Only**: Log file grows sequentially, easier to manage
- **Replay Efficiency**: Scan log file without reading entire database
- **V0 Choice**: Separate `<db>.log` file for simplicity

**Rollback on Error**: Should we undo partial phases on error?
- **Phase 1 or 2 failure**: No durable state, simple rollback (clear buffers, release lock)
- **Phase 3 failure (after fsync)**: Commit record is durable, leave it for recovery
- **Phase 4 failure (after fsync)**: Meta update durable, but may lack commit record (corruption)
- **Recommendation**: Never undo durable state, let recovery handle it

### Implementation Notes

**Step 1: Prepare Phase**
- Validate transaction state (`self.state == TransactionState::Active`)
- Check mutation count and bytes against limits
- Validate mutation ordering (no duplicate keys - already enforced)
- Store current root page ID for rollback comparison

**Step 2: Apply Phase**
- Execute B+tree mutations in order
- Track new root page ID after each mutation (it may change on splits/merges)
- If B+tree operation fails, return error immediately (rollback)
- B+tree operations are isolated (not visible to readers until commit)

**Step 3: Append Phase**
- Create commit record with all mutation details
- Write to log file in append mode
- **CRITICAL**: Call `fsync()` before proceeding to meta update
- Store LSN position for recovery verification

**Step 4: Meta Phase**
- Get current meta page (A or B)
- Create new meta with updated txn_id and root_page_id
- Encode meta page to buffer with checksum
- Write to opposite meta page (A → B or B → A)
- **CRITICAL**: Call `fsync()` on database file before returning success

**Step 5: Finalize Phase**
- Register snapshot in registry (may fail if registry full)
- Transition transaction state to `Committed`
- Release write lock (allow new WriteTxn)
- Execute plugin hooks (best-effort, errors logged but not fail commit)
- Invalidate WriteTxn handle (prevent reuse)

**Error Recovery**: If any phase fails:
- Release write lock (if held)
- Clear mutation buffers
- Invalidate WriteTxn handle
- Transition to `RolledBack` state
- Return error to caller
- **Do NOT undo durable state** (log record or meta page)

### Testing Strategy

**Unit Tests Needed**:
- `commit_empty_transaction` - Should return `NoMutations` error (or succeed per policy)
- `commit_with_puts` - Single and multiple put mutations
- `commit_with_deletes` - Delete operations commit correctly
- `commit_mixed_mutations` - Put and delete in same transaction
- `commit_updates_same_key` - Last-write-wins within transaction
- `commit_root_page_changes` - Verify root_page_id is updated
- `commit_meta_page_flip` - Verify A/B alternation
- `commit_creates_snapshot` - Verify snapshot registration
- `commit_releases_write_lock` - New WriteTxn can begin after commit
- `commit_invalidates_handle` - Cannot reuse committed WriteTxn

**Integration Tests**:
- `commit_survives_process_crash` - Kill process after commit, verify state on reopen
- `commit_survives_os_reboot` - Reboot machine, verify database integrity
- `commit_fsync_ordering` - Verify log fsync before meta fsync
- `commit_record_matches_meta` - Recovery verifies commit record for meta's TxnId
- `snapshot_sees_committed_state` - New reader sees committed mutations
- `old_reader_doesnt_see_commit` - Old reader still sees pre-commit snapshot
- `multiple_commits_in_sequence` - TxnIds are monotonic
- `commit_after_rollback` - Rollback then commit in new transaction

**Property-Based Tests**:
- `commit_preserves_reference_model` - Random sequences, compare to reference
- `commit_is_idempotent` - Commit same mutations twice, verify state
- `commit_commutativity` - Order-independent mutations (same keys, different values)
- `rollback_then_commit_same_mutations` - Verify final state

**Hardening Tests** (crash simulation):
- `kill_during_prepare` - Crash before any persistence, verify rollback
- `kill_during_apply` - Crash during B+tree mutations, verify rollback
- `kill_after_log_fsync` - Crash after log fsync but before meta update
- `kill_after_meta_fsync` - Crash after meta fsync, verify full commit
- `kill_during_snapshot_registration` - Crash during finalize, verify commit visible
- `torn_write_log_header` - Corrupt log header, verify recovery detects
- `torn_write_log_payload` - Corrupt log payload, verify recovery detects
- `torn_write_meta_page` - Corrupt meta page, verify other meta is valid

**Concurrency Tests**:
- `concurrent_readers_during_commit` - Readers never block on commit
- `multiple_writers_serialize` - Second WriteTxn waits or gets WriteBusy
- `read_snapshot_isolation` - Reader sees consistent snapshot during commit

**Performance Tests**:
- `commit_latency_single_mutation` - Baseline commit overhead
- `commit_latency_batch_mutations` - 100, 1000, 10000 mutations
- `commit_throughput` - Commits per second (single thread)
- `fsync_latency_breakdown` - Measure log fsync vs db fsync

---

## Crash Recovery Analysis

### Recovery Scenarios by Phase

**Crash During Phase 1 (Prepare)**:
- No durable state written
- Transaction is not committed
- Recovery: Ignore transaction, normal startup

**Crash During Phase 2 (Apply)**:
- No durable state written (B+tree changes in memory only)
- Transaction is not committed
- Recovery: Ignore transaction, normal startup

**Crash During Phase 3 (Append)**:
- **Case A**: Crash before fsync
  - Commit record may be partially written or lost
  - Transaction is not committed
  - Recovery: Scan log, find last valid commit record, ignore partial

- **Case B**: Crash after fsync but before Phase 4
  - Commit record is durable in log file
  - Meta page NOT updated
  - Recovery: Replay commit record, apply mutations, update meta page

**Crash During Phase 4 (Meta)**:
- **Case A**: Crash before fsync
  - Commit record is durable in log file
  - Meta page write may be partial or lost
  - Recovery: Find commit record, verify meta page TxnId < commit TxnId, complete meta update

- **Case B**: Crash after fsync
  - Commit record is durable
  - Meta page is durable with new TxnId
  - Transaction is fully committed
  - Recovery: Read latest valid meta page, verify commit record exists, done

**Crash During Phase 5 (Finalize)**:
- Commit record is durable
- Meta page is durable
- Snapshot registration may be incomplete
- Transaction is fully committed and visible
- Recovery: Read meta page, rebuild snapshot registry from commit records

### Recovery Algorithm

On database open:

1. **Find Latest Valid Meta Page**:
   - Read both meta pages (A and B)
   - Validate checksums
   - Pick valid page with highest `committed_txn_id`
   - If neither valid, return `Corrupt` error

2. **Scan Commit Log**:
   - Open `<db>.log` file
   - Scan forward from beginning, validating each commit record
   - Find highest TxnId with valid commit record
   - If log is corrupted after some point, truncate at last valid record

3. **Verify Consistency**:
   - If `meta.committed_txn_id` exists in log: consistent, done
   - If `meta.committed_txn_id` NOT in log: meta ahead of log (corruption or lost log)
     - Option A: Return `Corrupt` error (strict, V0 recommended)
     - Option B: Roll back to last TxnId present in log (future enhancement)

4. **Replay Incomplete Commits** (if any):
   - If log has records with TxnId > meta.committed_txn_id
   - Replay those records to bring database forward
   - This handles crash during Phase 3B or Phase 4A

5. **Rebuild Snapshot Registry**:
   - Scan all commit records from genesis to latest
   - For each commit, register snapshot with (txn_id, root_page_id)
   - This handles crash during Phase 5

6. **Resume Normal Operation**:
   - Database is now in consistent state
   - New WriteTxn can begin
   - New ReadTxn can read latest state or historical snapshots

---

## Summary

The commit operation is the core of transactional durability in NorthstarDB. It implements a five-phase protocol that guarantees atomicity and durability through careful ordering of fsync operations and crash recovery boundaries. The commit record format is fully specified in `spec/commit_record_v0.md` and provides a deterministic replay mechanism for time-travel queries and crash recovery.

Key implementation requirements:
1. **Fsync ordering is critical**: log file fsync before meta page fsync
2. **Meta page A/B flip**: Provides atomicity and corruption detection
3. **Commit record completeness**: All mutations fully described for replay
4. **Crash recovery**: Handle all crash scenarios without data loss
5. **Single writer enforcement**: Only one WriteTxn can commit at a time
6. **Readers never block**: Snapshot isolation provides lock-free reads

The commit specification provides complete guidance for implementing correct, crash-safe transactions in Rust, with detailed error handling, concurrency considerations, and testing requirements.
