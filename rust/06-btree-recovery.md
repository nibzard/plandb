# B+Tree Recovery from WAL

## Purpose

B+Tree recovery is the process of reconstructing a consistent tree structure from the Write-Ahead Log (WAL) after a crash or shutdown. This specification defines the complete recovery algorithm, including scanning WAL records, replaying committed transactions, rebuilding tree nodes, and validating the reconstructed tree. Recovery ensures durability (committed transactions preserved) and atomicity (uncommitted transactions discarded) while maintaining all B+Tree invariants.

## Types

### RecoveryContext

**Description**: State tracking during B+Tree recovery process. Contains all information needed to scan WAL, replay operations, and rebuild tree.

**Fields**:
- **pager** (Pager): Reference to Pager for node I/O
- **wal** (Wal): Reference to WAL for record scanning
- **recovery_lsn** (Lsn): LSN up to which recovery should proceed
- **root_page_id** (PageId): Reconstructed root page ID after recovery
- **tree_height** (usize): Reconstructed tree height
- **nodes_rebuilt** (usize): Count of nodes rebuilt during recovery
- **mutations_replayed** (usize): Count of mutations replayed
- **checksum_errors** (usize): Count of checksum mismatches detected

**Invariants**:
- recovery_lsn >= highest committed LSN in WAL
- root_page_id valid after successful recovery
- tree_height matches depth of reconstructed tree
- All B+Tree invariants hold after recovery

### RecoveryState

**Description**: Enum representing recovery phase

**Variants**:
- **Scanning**: Reading WAL records from start to recovery_lsn
- **Replaying**: Applying committed mutations to B+Tree
- **Validating**: Checking tree invariants
- **Complete**: Recovery finished successfully
- **Failed**: Recovery failed, database inconsistent

**Transitions**:
- Initial: Scanning
- Scanning → Replaying: After WAL scan complete
- Replaying → Validating: After all mutations applied
- Validating → Complete: After invariants verified
- Any → Failed: On error or corruption detected

### RecoveryStats

**Description**: Statistics about recovery operation

**Fields**:
- **wal_records_scanned** (usize): Number of WAL records read
- **commit_records_found** (usize): Number of commit records found
- **transactions_replayed** (usize): Number of transactions successfully replayed
- **transactions_skipped** (usize): Number of incomplete transactions skipped
- **nodes_allocated** (usize): New nodes allocated during recovery
- **nodes_freed** (usize): Orphaned nodes freed during recovery
- **overflow_pages_allocated** (usize): Overflow pages for large values
- **recovery_duration_ms** (u64): Time taken for recovery
- **final_root_page_id** (PageId): Root page ID after recovery
- **final_tree_height** (usize): Tree height after recovery

**Invariants**:
- commit_records_found >= transactions_replayed
- transactions_skipped = commit_records_found - transactions_replayed
- All statistics valid after recovery completes

## Recovery Algorithm

### Recovery Overview

**Purpose**: Restore B+Tree to consistent state after crash

**Trigger Conditions**:
- Database opened after unclean shutdown
- WAL file contains records after last checkpoint LSN
- Metadata indicates inconsistent state (dirty flag set)

**Recovery Goal**:
- All transactions committed before crash: Applied to tree
- All transactions not committed before crash: Discarded
- Tree structure valid and consistent
- All invariants verified

**Recovery Guarantees**:
- Atomicity: Transactions either fully applied or fully discarded
- Durability: Committed changes never lost
- Consistency: Tree satisfies all invariants after recovery
- Isolation: Recovered state equivalent to serial execution

### High-Level Recovery Process

**recover_btree(pager: Pager, wal: Wal) -> Result<RecoveryStats, RecoveryError>**

**Purpose**: Main recovery entry point

**Algorithm**:
1. **Initialize Recovery**:
   a. Create RecoveryContext with pager, wal references
   b. Determine recovery_lsn (highest LSN in WAL)
   c. Initialize empty B+Tree structure
   d. Set state to Scanning

2. **Scan WAL**:
   a. Open WAL file for sequential scanning
   b. Iterate from WAL start to end:
      i. Read record header (magic, version, type, txn_id, lsn, payload_len)
      ii. Validate record header checksum
      iii. If record_type == CommitRecord:
         - Deserialize commit payload (operations list)
         - Store in pending_commits buffer keyed by txn_id
         - Track highest_lsn seen
   c. If corruption detected:
      - Attempt to skip to next valid record (resync)
      - If resync fails, return CorruptionError
   d. Update stats: wal_records_scanned, commit_records_found

3. **Filter Committed Transactions**:
   a. Identify complete transactions (have both begin and commit records)
   b. Identify incomplete transactions (begin without commit)
   c. Sort committed transactions by LSN (replay in commit order)
   d. Update stats: transactions_replayed, transactions_skipped

4. **Replay Mutations**:
   a. Set state to Replaying
   b. For each committed transaction (in LSN order):
      i. Load transaction mutations from commit record
      ii. For each mutation:
         - Apply mutation to B+Tree: put(key, value, lsn) or delete(key, lsn)
         - Track nodes allocated and modified
      iii. If mutation application fails:
         - Return RecoveryError with context
   c. After all transactions replayed:
      i. Update tree metadata with root_page_id
      ii. Update stats: nodes_allocated, overflow_pages_allocated

5. **Validate Reconstructed Tree**:
   a. Set state to Validating
   b. Run B+Tree verification: verify_tree_invariants(btree)
   c. Check all nodes have valid checksums
   d. Check root page ID consistent with metadata
   e. Check tree height reasonable (not excessively deep)
   f. If validation fails:
      - Return CorruptionError with details
   g. Set state to Complete

6. **Update Metadata**:
   a. Write new root page ID to database metadata
   b. Write last committed LSN to metadata
   c. Clear dirty flag
   d. fsync metadata to disk

7. **Return Success**:
   a. Compile RecoveryStats
   b. Return Ok(RecoveryStats)

**Returns**: Ok(RecoveryStats) on success, Err(RecoveryError) on failure

**Error Conditions**:
- WalCorrupted: WAL file corrupted, cannot recover
- TreeCorrupted: Reconstructed tree fails validation
- MetadataCorrupted: Database metadata inconsistent
- AllocationFailed: Cannot allocate nodes during recovery
- IOError: I/O error during recovery

**Complexity**: O(n + m) where n = WAL records, m = mutations replayed

### WAL Scanning Phase

**scan_wal_for_commits(wal: Wal) -> Result<Vec<CommittedTransaction>, ScanError>**

**Purpose**: Scan WAL and extract all committed transactions

**Algorithm**:
1. Initialize commits buffer: Vec<CommittedTransaction>
2. Initialize current_position = WAL start offset
3. Loop while current_position < WAL file end:
   a. Read record header (40 bytes)
   b. Validate header magic (0x4E53544D "NSTM")
   c. Validate header checksum
   d. If validation fails:
      i. Attempt resync: scan for next valid magic
      ii. If resync fails after threshold, return CorruptionError
   e. Extract record_type, txn_id, lsn, payload_len
   f. If record_type == CommitRecord:
      i. Read payload (payload_len bytes)
      ii. Deserialize commit payload (root_page_id, operations)
      iii. Validate payload checksum
      iv. Create CommittedTransaction: { txn_id, lsn, operations }
      v. Push to commits buffer
   g. Advance current_position by: header_size (40) + payload_len + trailer_size (12)
4. Return commits buffer

**Returns**: Vector of all committed transactions found in WAL

**Error Conditions**:
- TruncatedWAL: WAL ends mid-record
- CorruptionError: Record checksum invalid, resync failed
- InvalidRecordType: Unknown record type encountered

**Complexity**: O(n) where n = WAL records

**Resync Strategy**:
- Scan byte-by-byte for magic number 0x4E53544D
- Accept up to 4KB of garbage data before giving up
- Log corruption warnings but continue recovery

### Transaction Filtering

**filter_committed_transactions(all_txns: Vec<CommittedTransaction>) -> Vec<CommittedTransaction>**

**Purpose**: Identify and sort committed transactions for replay

**Algorithm**:
1. Create map: HashMap<TxnId, CommittedTransaction>
2. For each transaction in all_txns:
   a. Insert into map keyed by txn_id
3. Verify each transaction has complete operation list:
   a. Check all operations deserializable
   b. Check key and value lengths valid
   c. Check LSNs monotonically increasing within transaction
4. Filter out incomplete/corrupted transactions:
   a. Remove transactions with deserialization errors
   b. Log skipped transactions
5. Sort remaining transactions by LSN (ascending):
   a. Ensures replay in commit order
   b. Maintains serializability
6. Return sorted transaction vector

**Returns**: Committed transactions sorted by LSN

**Error Conditions**: None (returns empty vector if all transactions corrupt)

**Complexity**: O(n log n) where n = committed transactions (sorting cost)

### Mutation Replay Phase

**replay_mutations(btree: BTree, transactions: Vec<CommittedTransaction>) -> Result<(), ReplayError>**

**Purpose**: Apply all committed mutations to B+Tree

**Algorithm**:
1. Initialize replay stats: mutations_applied = 0
2. For each transaction in transactions:
   a. For each operation in transaction.operations:
      i. Match operation type:
         - Put: Call btree.put(operation.key, operation.value, operation.lsn)
         - Delete: Call btree.delete(operation.key, operation.lsn)
      ii. If operation fails:
         - Return ReplayError with context (txn_id, operation_index)
      iii. Increment mutations_applied
   b. If all operations succeed:
      i. Continue to next transaction
3. After all transactions replayed:
   a. Verify B+Tree root valid
   b. Return Ok(())

**Returns**: Ok(()) if all mutations applied, Err(ReplayError) on failure

**Error Conditions**:
- KeyTooLarge: Operation key exceeds limit
- ValueTooLarge: Operation value exceeds limit
- AllocationFailed: Cannot allocate nodes during replay
- NodeCorrupted: Newly allocated node invalid
- IOError: Pager I/O error

**Complexity**: O(m * log t) where m = mutations, t = tree size

**Optimization**: Batch operations targeting same node (reduce I/O)

### Tree Validation Phase

**validate_recovered_tree(btree: BTree) -> Result<(), ValidationError>**

**Purpose**: Verify reconstructed tree satisfies all invariants

**Algorithm**:
1. **Validate Root**:
   a. Check root page ID valid (non-zero)
   b. Read root node from pager
   c. Verify root node checksum
   d. Check root node magic number
   e. Verify root node type (Internal or Leaf)

2. **Validate Tree Structure**:
   a. Traverse tree from root to all leaves
   b. Verify parent pointers consistent
   c. Verify sibling pointers consistent (leaf linked list)
   d. Verify all node checksums valid
   e. Verify key ordering within nodes
   e. Verify key ordering across levels

3. **Validate Occupancy**:
   a. Check all non-root nodes at minimum occupancy
   b. Check all nodes at maximum capacity
   c. Check node counts reasonable

4. **Validate Integrity**:
   a. Verify no orphaned nodes (all nodes reachable from root)
   b. Verify no cycles in tree structure
   c. Verify leaf linked list consistent
   d. Verify level fields correct

5. **Return**:
   a. If all checks pass: Ok(())
   b. If any check fails: Err(ValidationError) with details

**Returns**: Ok(()) if tree valid, Err(ValidationError) if corrupted

**Error Conditions**:
- RootInvalid: Root node corrupted or missing
- OrphanedNode: Node not reachable from root
- CycleDetected: Tree structure has cycle
- OccupancyViolation: Node below minimum or above maximum
- OrderingViolation: Keys not sorted correctly

**Complexity**: O(n) where n = number of nodes (full tree traversal)

## Recovery Optimization

### Incremental Recovery

**Purpose**: Replay only WAL records since last checkpoint

**Algorithm**:
1. Read last checkpoint LSN from metadata
2. Load checkpoint tree state (frozen B+Tree at checkpoint LSN)
3. Scan WAL from checkpoint LSN + 1 (not from beginning)
4. Replay transactions with LSN > checkpoint_lsn
5. Apply replayed mutations to checkpoint tree

**Benefit**:
- Faster recovery (only recent transactions replayed)
- Less I/O (skip old WAL records)
- Lower CPU usage

**Tradeoff**:
- Requires checkpoint mechanism
- Checkpoint creation overhead during normal operation

**Use Case**: Production databases with frequent checkpoints

### Parallel Recovery

**Purpose**: Use multiple threads to accelerate recovery

**Algorithm**:
1. Partition WAL records by transaction ID
2. Assign partition groups to worker threads
3. Each thread replays its assigned transactions
4. Merge results from all threads
5. Coordinate root page ID updates

**Challenge**: B+Tree modifications require synchronization
- Use thread-safe node allocation
- Coordinate root splits
- Merge replay results carefully

**Benefit**: Faster recovery on multi-core systems

**Complexity**: Significant implementation complexity
- Thread coordination
- Lock contention
- Deterministic replay order

**Recommendation**: Implement only if profiling shows recovery is bottleneck

### Checkpoint-Assisted Recovery

**Purpose**: Use pre-built checkpoint tree to avoid full WAL replay

**Algorithm**:
1. Load checkpoint tree from disk (complete tree image)
2. Scan WAL for transactions after checkpoint LSN
3. Apply post-checkpoint transactions to checkpoint tree
4. Result: Recovered tree without replaying entire history

**Benefit**:
- Recovery time proportional to post-checkpoint activity
- Typical: Recover in seconds even after days of runtime

**Checkpoint Frequency**:
- Tradeoff: Frequent checkpoints → faster recovery, more overhead
- Typical: Every 5-15 minutes
- Configurable based on workload

## Recovery Error Handling

### WAL Corruption Handling

**Scenario**: WAL file corrupted mid-record

**Recovery Strategy**:
1. Detect corruption: Checksum validation fails
2. Attempt resync: Scan for next valid record magic
3. If resync successful:
   - Skip corrupted record
   - Log corruption warning
   - Continue recovery from resync position
4. If resync fails:
   - Return CorruptionError
   - Recommend restore from backup

**Data Loss**: Transactions after corruption point lost

**Prevention**:
- WAL on separate disk with battery-backed cache
- fsync after critical WAL records
- Redundant WAL replication (future feature)

### Incomplete Transaction Handling

**Scenario**: Transaction committed to WAL but operations incomplete

**Detection**: Commit record exists but operation count mismatches

**Recovery Strategy**:
1. Validate transaction completeness during scan
2. If transaction incomplete:
   a. Skip transaction (do not replay)
   b. Log warning
   c. Continue with next transaction
3. Update stats: transactions_skipped++

**Rationale**: Incomplete transaction cannot be safely replayed

**Effect**: Transactions after incomplete one still replayed (if valid)

### Node Allocation Failure

**Scenario**: Cannot allocate nodes during recovery (storage full)

**Recovery Strategy**:
1. Detect allocation failure: Pager returns error
2. Abort recovery immediately
3. Return AllocationFailed error
4. Database unusable until space freed

**User Action Required**:
- Free disk space
- Delete unnecessary data
- Re-run recovery

### Tree Validation Failure

**Scenario**: Reconstructed tree fails invariant check

**Detection**: validate_recovered_tree() returns error

**Recovery Strategy**:
1. Log validation error details
2. Return CorruptionError
3. Database unusable

**Recovery Options**:
- Restore from recent backup
- Replay WAL from earlier checkpoint
- Manual data extraction (last resort)

## Recovery Statistics and Monitoring

### Recovery Metrics

**Key Metrics**:
- Recovery duration (milliseconds)
- WAL records scanned
- Transactions replayed vs skipped
- Nodes allocated
- Mutations applied
- Checksum errors detected

**Monitoring Integration**:
- Publish metrics to monitoring system
- Alert on slow recovery (> 1 minute)
- Alert on high skip rate (> 10% transactions skipped)
- Alert on checksum errors (should be zero)

### Recovery Logging

**Log Levels**:
- INFO: Recovery started, WAL scanning, replay phases
- WARN: Corruption detected, transactions skipped, resync events
- ERROR: Recovery failed, validation failed, allocation failed
- DEBUG: Detailed per-transaction replay, per-node validation

**Log Examples**:
- INFO: "B+Tree recovery started, WAL LSN range: [1000, 5000]"
- INFO: "Scanned 4000 WAL records, found 150 commit records"
- INFO: "Replaying 148 committed transactions, skipping 2 incomplete"
- WARN: "WAL corruption at offset 12345, resyncing to 12389"
- INFO: "Replayed 1523 mutations, allocated 45 new nodes"
- INFO: "Tree validation passed, all invariants satisfied"
- INFO: "Recovery completed in 234ms"

## Rust Implementation Guidance

### Module Structure

Define recovery types and functions in:
- `northstar_core::tree::recovery::RecoveryContext` - Recovery state
- `northstar_core::tree::recovery::RecoveryState` - Recovery phase enum
- `northstar_core::tree::recovery::recover_btree` - Main recovery function

### Type Definitions

**RecoveryContext**:
```rust
pub struct RecoveryContext {
    pager: Arc<Pager>,
    wal: Arc<Wal>,
    recovery_lsn: Lsn,
    root_page_id: Option<PageId>,
    tree_height: usize,
    nodes_rebuilt: usize,
    mutations_replayed: usize,
    checksum_errors: usize,
    stats: RecoveryStats,
}

impl RecoveryContext {
    pub fn new(pager: Arc<Pager>, wal: Arc<Wal>) -> Self {
        Self {
            pager,
            wal,
            recovery_lsn: Lsn::from(0),
            root_page_id: None,
            tree_height: 0,
            nodes_rebuilt: 0,
            mutations_replayed: 0,
            checksum_errors: 0,
            stats: RecoveryStats::default(),
        }
    }
}
```

**RecoveryState Enum**:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryState {
    Scanning,
    Replaying,
    Validating,
    Complete,
    Failed,
}
```

**RecoveryStats**:
```rust
#[derive(Debug, Default)]
pub struct RecoveryStats {
    pub wal_records_scanned: usize,
    pub commit_records_found: usize,
    pub transactions_replayed: usize,
    pub transactions_skipped: usize,
    pub nodes_allocated: usize,
    pub nodes_freed: usize,
    pub overflow_pages_allocated: usize,
    pub recovery_duration_ms: u64,
    pub final_root_page_id: PageId,
    pub final_tree_height: usize,
}
```

### Recovery Implementation

**Main Recovery Function**:
```rust
pub fn recover_btree(
    pager: Arc<Pager>,
    wal: Arc<Wal>,
) -> Result<RecoveryStats, RecoveryError> {
    let start_time = std::time::Instant::now();
    let mut ctx = RecoveryContext::new(pager, wal);

    // Scan WAL for committed transactions
    ctx.state = RecoveryState::Scanning;
    let commits = scan_wal_for_commits(&ctx.wal)?;
    ctx.stats.commit_records_found = commits.len();
    ctx.stats.wal_records_scanned = commits.len() * 10; // Approximate

    // Filter and sort committed transactions
    let committed_txns = filter_committed_transactions(commits);
    ctx.stats.transactions_replayed = committed_txns.len();
    ctx.stats.transactions_skipped =
        ctx.stats.commit_records_found - committed_txns.len();

    // Create empty B+Tree for recovery
    let mut btree = BTree::new_empty(ctx.pager.clone())?;

    // Replay mutations
    ctx.state = RecoveryState::Replaying;
    replay_mutations(&mut btree, &committed_txns, &mut ctx)?;

    // Validate recovered tree
    ctx.state = RecoveryState::Validating;
    validate_recovered_tree(&btree)?;

    // Update metadata
    update_metadata(&ctx.pager, btree.root_page_id(), ctx.recovery_lsn)?;

    // Finalize
    ctx.state = RecoveryState::Complete;
    ctx.stats.final_root_page_id = btree.root_page_id();
    ctx.stats.final_tree_height = btree.height();
    ctx.stats.recovery_duration_ms = start_time.elapsed().as_millis() as u64;

    Ok(ctx.stats)
}
```

**WAL Scanning**:
```rust
fn scan_wal_for_commits(wal: &Wal) -> Result<Vec<CommittedTransaction>, ScanError> {
    let mut commits = Vec::new();
    let mut position = 0;

    // Iterate WAL records
    while position < wal.file_len()? {
        // Read record header
        let header = wal.read_record_header(position)?;

        // Validate header
        if header.magic != 0x4E53544D {
            // Attempt resync
            position = resync_wal(wal, position)?;
            if position == 0 {
                return Err(ScanError::CorruptionError);
            }
            continue;
        }

        // Check for commit record
        if header.record_type == RecordType::CommitRecord {
            // Read payload
            let payload = wal.read_payload(position, header.payload_len)?;

            // Deserialize commit
            let commit = deserialize_commit_record(&payload)?;

            commits.push(commit);
        }

        // Advance to next record
        position += header.total_size();
    }

    Ok(commits)
}
```

**Mutation Replay**:
```rust
fn replay_mutations(
    btree: &mut BTree,
    transactions: &[CommittedTransaction],
    ctx: &mut RecoveryContext,
) -> Result<(), ReplayError> {
    for txn in transactions {
        for op in &txn.operations {
            match op.op_type {
                OperationType::Put => {
                    btree.put(&op.key, &op.value, op.lsn)?;
                    ctx.mutations_replayed += 1;
                }
                OperationType::Delete => {
                    btree.delete(&op.key, op.lsn)?;
                    ctx.mutations_replayed += 1;
                }
            }
        }
        ctx.nodes_rebuilt = btree.node_count();
    }

    Ok(())
}
```

**Tree Validation**:
```rust
fn validate_recovered_tree(btree: &BTree) -> Result<(), ValidationError> {
    // Verify root exists
    let root_page_id = btree.root_page_id();
    if !root_page_id.is_valid() {
        return Err(ValidationError::RootInvalid);
    }

    // Verify all node checksums
    btree.verify_checksums()?;

    // Verify structural invariants
    btree.verify_structure()?;

    // Verify occupancy rules
    btree.verify_occupancy()?;

    // Verify key ordering
    btree.verify_ordering()?;

    Ok(())
}
```

### Error Handling

**RecoveryError Enum**:
```rust
#[derive(Debug, thiserror::Error)]
pub enum RecoveryError {
    #[error("WAL corrupted: {0}")]
    WalCorrupted(String),

    #[error("B+Tree corrupted after recovery: {0}")]
    TreeCorrupted(String),

    #[error("Metadata corrupted: {0}")]
    MetadataCorrupted(String),

    #[error("Allocation failed during recovery")]
    AllocationFailed,

    #[error("I/O error during recovery: {0}")]
    IOError(#[from] std::io::Error),
}
```

### Testing Strategy

**Unit tests needed for**:
- WAL scanning (valid and corrupted records)
- Transaction filtering (complete and incomplete)
- Mutation replay (put and delete operations)
- Tree validation (all invariants)

**Integration tests**:
- Crash during transaction (verify uncommitted txn discarded)
- Crash after commit (verify committed txn present)
- WAL corruption (verify resync or graceful failure)
- Recovery from checkpoint (verify faster recovery)

**Property tests**:
- Recovery idempotency: Recover same WAL twice produces identical tree
- Deterministic replay: Same WAL always produces same tree
- Checksum validation: Detect all single-bit errors

**Stress tests**:
- Large WAL recovery (millions of records)
- Many small transactions
- Few large transactions (thousands of operations each)
- Concurrent recovery simulation

## Invariants

### Recovery Phase Invariants
1. Scanning phase: Only reading WAL, not modifying B+Tree
2. Replaying phase: Applying mutations in LSN order
3. Validating phase: B+Tree fully reconstructed, read-only verification
4. Complete state: All invariants satisfied, tree ready for use
5. Failed state: Recovery aborted, tree unusable

### WAL Scanning Invariants
1. All valid commit records found and extracted
2. Corrupted records either resynced or cause failure
3. Record LSNs monotonically increasing in WAL
4. Commit records contain valid operation lists

### Mutation Replay Invariants
1. Mutations applied in LSN order (commit order)
2. Each mutation successfully applied or entire replay fails
3. B+Tree root_page_id updated after each transaction
4. Node allocations tracked accurately

### Tree Validation Invariants
1. All nodes reachable from root
2. All node checksums valid
3. Key ordering correct within and across nodes
4. Occupancy rules satisfied
5. No cycles or structural corruption

## Dependencies

**Uses**:
- Pager module (node I/O)
- WAL module (record scanning)
- B+Tree module (mutation application)
- Error types (recovery errors)
- Lsn type (LSN ordering and comparison)

**Used By**:
- Database open (after crash detection)
- WAL replay system (transaction recovery)
- Checkpoint system (incremental recovery)
- Database initialization (first open)

## Related Specifications

- **06-btree-overview.md**: B+Tree structure and invariants
- **06-btree-insert.md**: Insert operations used during replay
- **06-btree-delete.md**: Delete operations used during replay
- **03-wal-*.md**: WAL structure and scanning
- **04-txn-commit.md**: Commit record format
- **02-pager-*.md**: Node allocation and I/O
- **04-txn-*.md**: Transaction system and LSN tracking
