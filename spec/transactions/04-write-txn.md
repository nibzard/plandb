# WriteTxn Specification

## Purpose

WriteTxn (Write Transaction) provides the interface for modifying data in NorthstarDB. It tracks pending mutations, manages transaction state, and coordinates the two-phase commit protocol to ensure atomicity and durability. WriteTxn implements read-your-writes semantics, allowing a transaction to see its own uncommitted changes while keeping them isolated from other readers.

The WriteTxn is the sole mechanism for data modification in V0, enforcing the single-writer invariant to guarantee serialized commit order and simplified conflict resolution.

## Types

### WriteTxn

**Description**: Main write transaction structure that holds transaction context, database reference, and manages the mutation buffer.

**Fields**:
- `inner`: Reference model WriteTxn - Provides in-memory B+tree for pending mutations and read-your-writes lookup
- `txn_ctx`: TransactionContext - Tracks mutations, allocated pages, modified pages, and two-phase commit state
- `db`: Pointer to Db - Reference to the parent database for accessing pager, WAL, and snapshot registry
- `txn_id`: u64 - Unique transaction identifier allocated at begin time
- `start_lsn`: Lsn - WAL position when transaction started (for recovery and time travel)
- `state`: TransactionState - Current state in the transaction lifecycle (active, preparing, committed, aborted)
- `has_mutations`: bool - Flag indicating whether any mutations have been recorded

**Size**: Depends on platform (pointer-sized fields)
**Alignment**: Pointer alignment
**Invariants**:
- Only one WriteTxn can exist per Db at any time (enforced by Db.writer_active flag)
- txn_id is globally unique and monotonically increasing
- state transitions must follow valid state machine (cannot go from committed back to active)
- All mutations are buffered in memory until commit phase
- Once state is preparing or committed, no new mutations can be added

### MutationBufferEntry

**Description**: Individual mutation tracked within the transaction.

**Fields**:
- `op_type`: MutationOperation - Either Put or Delete
- `key`: Bytes - Key being modified (owned copy to ensure lifetime safety)
- `value`: Option<Bytes> - Value for Put operations, None for Delete
- `key_size`: u32 - Length of key in bytes (for size limit validation)
- `value_size`: u32 - Length of value in bytes (zero for Delete operations)

**Size**: Variable (depends on key and value lengths)
**Invariants**:
- key_size must be less than or equal to MAX_KEY_SIZE (4KB recommended)
- value_size must be less than or equal to MAX_VALUE_SIZE (16MB recommended)
- value must be Some if op_type is Put, None if Delete
- Keys are compared lexicographically using unsigned byte comparison

## Functions

### new(db: &Db) -> Result<WriteTxn, Error>

**Purpose**: Begin a new write transaction, allocating a unique transaction identifier and initializing transaction context.

**Parameters**:
- `db`: Reference to Db - Parent database instance

**Returns**: Result containing WriteTxn instance or Error
- `Ok(WriteTxn)`: Transaction successfully started
- `Err(Error::WriteBusy)`: Another write transaction is already active
- `Err(Error::IoError)`: Failed to allocate transaction ID or initialize context

**Algorithm**:
1. Acquire exclusive write lock on Db (check Db.writer_active flag)
2. If writer_active is true, return WriteBusy error immediately
3. Set Db.writer_active to true to block concurrent writers
4. Allocate next transaction ID from Db.txn_id_counter (atomic increment)
5. Read current WAL position and store as start_lsn
6. Initialize TransactionContext with allocated txn_id and parent_txn_id = 0
7. Set initial state to TransactionState::Active
8. Set has_mutations flag to false
9. Return WriteTxn instance

**Error Conditions**:
- `Error::WriteBusy`: Another writer already holds the lock
- `Error::IoError`: System error during initialization

**Concurrency**: Must be atomic with respect to other begin_write calls. Uses Db.writer_active mutex or atomic flag.

### get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, Error>

**Purpose**: Read a key with read-your-writes semantics. First checks pending mutations, then falls back to committed B+tree.

**Parameters**:
- `key`: Byte slice - Key to look up

**Returns**: Result containing optional value or Error
- `Ok(Some(value))`: Key found (either in pending mutations or committed state)
- `Ok(None)`: Key does not exist
- `Err(Error::KeyTooLarge)`: Key exceeds MAX_KEY_SIZE limit
- `Err(Error::InvalidKey)`: Empty key or invalid key format

**Algorithm**:
1. Validate key length (must be greater than 0 and less than MAX_KEY_SIZE)
2. Check pending mutations buffer in reverse order (most recent first)
3. If key found in mutations:
   - If mutation is Put, return Some(value) with the pending value
   - If mutation is Delete, return None (key is deleted by this transaction)
4. If not found in mutations, perform lookup in committed B+tree via inner reference model
5. Return result from B+tree lookup (Some(value) or None)

**Error Conditions**:
- `Error::KeyTooLarge`: Key size exceeds configured limit
- `Error::InvalidKey`: Key is empty or contains invalid bytes

**Concurrency**: Read-only operation, safe to call concurrently with other reads on same WriteTxn.

### put(&mut self, key: &[u8], value: &[u8]) -> Result<(), Error>

**Purpose**: Buffer a Put mutation for the given key and value. Does not write to disk immediately.

**Parameters**:
- `key`: Byte slice - Key to insert or update
- `value`: Byte slice - Value to associate with key

**Returns**: Result indicating success or Error
- `Ok(())`: Mutation successfully buffered
- `Err(Error::TransactionNotActive)`: Transaction is not in active state
- `Err(Error::KeyTooLarge)`: Key exceeds MAX_KEY_SIZE (4KB)
- `Err(Error::ValueTooLarge)`: Value exceeds MAX_VALUE_SIZE (16MB)
- `Err(Error::InvalidKey)`: Key is empty
- `Err(Error::InvalidValue)`: Value validation failed

**Algorithm**:
1. Check transaction state; if not Active, return TransactionNotActive error
2. Validate key is non-empty
3. Validate key length is less than or equal to MAX_KEY_SIZE
4. Validate value length is less than or equal to MAX_VALUE_SIZE
5. Make owned copies of key and value bytes (allocate in heap)
6. Create MutationBufferEntry with op_type=Put, key copy, value copy
7. Append entry to TransactionContext.mutations list
8. Set has_mutations flag to true
9. Return success

**Error Conditions**:
- `Error::TransactionNotActive`: State is not Active (already preparing, committed, or aborted)
- `Error::KeyTooLarge`: Key size exceeds 4KB limit
- `Error::ValueTooLarge`: Value size exceeds 16MB limit
- `Error::InvalidKey`: Key is empty
- `Error::AllocationFailed`: Memory allocation failed for key/value copies

**Concurrency**: Mutates internal state, must not be called concurrently on same WriteTxn instance.

### delete(&mut self, key: &[u8]) -> Result<(), Error>

**Purpose**: Buffer a Delete mutation for the given key. Does not write to disk immediately.

**Parameters**:
- `key`: Byte slice - Key to delete

**Returns**: Result indicating success or Error
- `Ok(())`: Delete mutation successfully buffered
- `Err(Error::TransactionNotActive)`: Transaction is not in active state
- `Err(Error::KeyTooLarge)`: Key exceeds MAX_KEY_SIZE (4KB)
- `Err(Error::InvalidKey)`: Key is empty

**Algorithm**:
1. Check transaction state; if not Active, return TransactionNotActive error
2. Validate key is non-empty
3. Validate key length is less than or equal to MAX_KEY_SIZE
4. Make owned copy of key bytes (allocate in heap)
5. Create MutationBufferEntry with op_type=Delete, key copy, value=None
6. Append entry to TransactionContext.mutations list
7. Set has_mutations flag to true
8. Return success

**Error Conditions**:
- `Error::TransactionNotActive`: State is not Active
- `Error::KeyTooLarge`: Key size exceeds limit
- `Error::InvalidKey`: Key is empty
- `Error::AllocationFailed`: Memory allocation failed

**Concurrency**: Mutates internal state, must not be called concurrently.

### commit(&mut self) -> Result<TxnId, Error>

**Purpose**: Execute two-phase commit protocol to make all mutations durable and visible. Returns the new transaction ID.

**Parameters**: None

**Returns**: Result containing committed TxnId or Error
- `Ok(txn_id)`: Transaction successfully committed with this ID
- `Err(Error::TransactionNotActive)`: Transaction already committed or aborted
- `Err(Error::PrepareFailed)`: Failed during prepare phase
- `Err(Error::CommitFailed)`: Failed during commit phase
- `Err(Error::IoError)`: I/O error during persistence
- `Err(Error::WalSyncFailed)`: Failed to sync WAL to disk

**Algorithm**:

**Phase 1: Prepare**
1. Check transaction state is Active; if not, return error
2. Transition state to Preparing
3. If has_mutations is false (empty transaction), skip to Phase 2 step 7
4. Apply all buffered mutations to in-memory B+tree (inner reference model)
5. For each mutation that allocates or modifies pages:
   - Track allocated pages in TransactionContext.allocated_pages
   - Capture before-images in TransactionContext.modified_pages for rollback capability
6. Build CommitRecord from mutations and new root PageId
7. Serialize CommitRecord to WAL format bytes
8. Append commit record to WAL file
9. Call fsync on WAL file to ensure durability
10. Return LSN of commit record

**Phase 2: Commit**
11. Write all dirty pages (allocated and modified) to database file via Pager
12. Write new meta page pointing to new root PageId and referencing WAL LSN
13. Call fsync on database file
14. Transition state to Committed
15. Register new snapshot with SnapshotRegistry using committed txn_id
16. Release writer lock on Db (set Db.writer_active to false)
17. Return committed txn_id

**Error Conditions**:
- `Error::TransactionNotActive`: Transaction state is not Active
- `Error::PrepareFailed`: Prepare phase validation failed
- `Error::CommitFailed`: Commit phase I/O failed
- `Error::IoError`: File I/O operation failed
- `Error::WalSyncFailed`: WAL fsync failed
- `Error::ChecksumMismatch`: Computed checksum does not match recorded checksum

**Concurrency**: Exclusive access to write path. Blocks all other writers. Readers can proceed concurrently with snapshot isolation.

### abort(&mut self)

**Purpose**: Rollback the transaction, discarding all buffered mutations and releasing the write lock.

**Parameters**: None

**Returns**: None (always succeeds)

**Algorithm**:
1. Check transaction state; if already Committed or Aborted, return immediately
2. Discard all buffered mutations (drop MutationBufferEntry list)
3. Discard all before-images in TransactionContext.modified_pages
4. Clear TransactionContext.allocated_pages
5. Transition state to Aborted
6. Release writer lock on Db (set Db.writer_active to false)
7. Return

**Error Conditions**: None - abort always succeeds even if transaction is already closed

**Concurrency**: Safe to call from any state. Idempotent (calling abort twice is harmless).

### get_txn_id(&self) -> TxnId

**Purpose**: Get the unique transaction identifier allocated at begin time.

**Parameters**: None

**Returns**: TxnId - This transaction's unique ID

**Algorithm**: Return the txn_id field stored at transaction creation

**Concurrency**: Read-only, thread-safe

### has_mutations(&self) -> bool

**Purpose**: Check whether this transaction has any pending mutations.

**Parameters**: None

**Returns**: bool - True if at least one Put or Delete has been buffered

**Algorithm**: Return the has_mutations flag, or check if mutations list is non-empty

**Concurrency**: Read-only, thread-safe

### is_active(&self) -> bool

**Purpose**: Check if the transaction is still active (not committed, aborted, or preparing).

**Parameters**: None

**Returns**: bool - True if state is Active

**Algorithm**: Return true if state equals TransactionState::Active

**Concurrency**: Read-only, thread-safe

## Invariants

1. **Single Writer**: Only one WriteTxn can exist per Db instance at any time
2. **Mutation Isolation**: All mutations are invisible to other transactions until commit
3. **Read-Your-Writes**: Transaction can see its own pending mutations via get()
4. **State Monotonicity**: State transitions only go forward (Active -> Preparing -> Committed, or Active -> Aborted)
5. **Atomic Commit**: All mutations become visible simultaneously at commit point
6. **Durability Ordering**: WAL record is persisted before meta page update
7. **Key Uniqueness**: Within a transaction, multiple mutations to same key are resolved by last-write-wins in buffer
8. **Size Limits**: All keys and values must respect configured size limits

## Dependencies

- **Uses**:
  - TransactionContext (from txn module) - Stores mutations and manages two-phase commit state
  - Mutation (from txn module) - Enum representing Put or Delete operations
  - CommitRecord (from commit_record module) - Serialized commit record for WAL
  - Db (from db module) - Parent database for pager, WAL, and snapshot registry access
  - Pager (from pager module) - Page allocation and writing during commit
  - Wal (from wal module) - Commit record append and fsync
  - SnapshotRegistry (from snapshot module) - Snapshot registration after commit

- **Used by**:
  - Db.begin_write() - Creates WriteTxn instances
  - Application code - Uses WriteTxn to perform data modifications

## Mutation Tracking Strategy

### Buffer Organization

Mutations are tracked in order within a dynamically-sized buffer (Vec or ArrayList). Each mutation entry contains:

1. **Operation Type**: Put or Delete
2. **Key**: Owned copy of key bytes (heap-allocated)
3. **Value**: For Put operations, owned copy of value bytes
4. **Metadata**: Key length, value length for validation

### Key Coalescing

When multiple mutations target the same key within a transaction, the buffer preserves all mutations in order. The get() operation searches the buffer in reverse order (most recent first) to implement last-write-wins semantics within the transaction.

Example:
1. put("user:1", "Alice")
2. put("user:1", "Alice Smith")
3. delete("user:1")

At commit time, all three mutations are serialized to the commit record. However, get("user:1") after step 3 would return None (the delete is visible within the transaction).

### Memory Management

- Keys and values are copied into heap-allocated buffers when put() or delete() is called
- This ensures the mutation data outlives the caller's slices
- On commit, mutations are serialized to WAL and then the in-memory buffer is dropped
- On abort, all mutation buffers are dropped without being written

### Size Validation

All mutations are validated when buffered, not at commit time:
- MAX_KEY_SIZE: 4KB recommended (configurable)
- MAX_VALUE_SIZE: 16MB recommended (configurable)
- MAX_OPERATIONS_PER_COMMIT: 1000 operations limit to prevent runaway transactions

### Page Tracking

During commit (prepare phase), the transaction tracks:
- **Allocated Pages**: New pages allocated for B+tree growth (stored in TransactionContext.allocated_pages)
- **Modified Pages**: Existing pages that were rewritten (stored in TransactionContext.modified_pages with before-images)
- This information is used for rollback capability and for optimizing page writes

## Transaction Lifecycle

### State Machine

WriteTxn follows this state transition diagram:

```
     [Created/Begin]
           |
           v
      [Active] <─────────────┐
           |                  |
           | put()/delete()   | (mutations allowed)
           v                  |
     [Preparing] ─────────────┘
           |
           | (write mutations to WAL)
           v
      [Committed]
           |
           | (cleanup)
           v
      [Closed]

     Alternatively, from [Active]:
           |
           | abort()
           v
      [Aborted]
           |
           | (cleanup)
           v
      [Closed]
```

### Valid State Transitions

1. **Active -> Preparing**: Triggered by commit() entering Phase 1
2. **Preparing -> Committed**: Triggered by successful Phase 2 completion
3. **Active -> Aborted**: Triggered by abort() or error during prepare
4. **Preparing -> Aborted**: Triggered by error during commit phase
5. **Any State -> Closed**: Implicit via Drop trait or explicit close

### Invalid State Transitions

- Committed -> Active: Cannot resume a committed transaction
- Aborted -> Active: Cannot resume an aborted transaction
- Committed -> Preparing: Already committed
- Preparing -> Active: Cannot go back to accepting mutations

### Lifecycle Phases

**Phase 1: Begin (Creation)**
- Db.begin_write() creates WriteTxn
- Acquires exclusive write lock
- Allocates unique TxnId
- Initializes empty mutation buffer
- State: Active

**Phase 2: Mutation Accumulation**
- Application calls put() and delete()
- Mutations buffered in memory
- Read-your-writes via get() checking buffer first
- State: Active (remains)
- Can abort at any point

**Phase 3: Prepare (Commit Phase 1)**
- Application calls commit()
- State transitions to Preparing
- No more mutations allowed
- Apply mutations to in-memory B+tree
- Build CommitRecord from mutations
- Serialize commit record to WAL bytes
- Append to WAL and fsync
- State: Preparing

**Phase 4: Commit (Commit Phase 2)**
- Write dirty pages to database file
- Write new meta page
- Fsync database file
- Register snapshot in registry
- Release write lock
- State: Committed
- Return new TxnId to caller

**Phase 5: Cleanup (Drop)**
- Release all mutation buffers
- Drop TransactionContext
- If not explicitly committed/aborted, Drop trait should abort automatically

## Rust Implementation Guidance

### Module Structure

WriteTxn should be defined in the `northstar_core::txn` module:

```
northstar-core/
├── src/
│   ├── txn.rs           # TransactionContext, WriteTxn, ReadTxn
│   ├── db.rs            # Db, begin_write()
│   ├── wal.rs           # Wal, commit record append
│   ├── pager.rs         # Pager, page write/flush
│   └── snapshot.rs      # SnapshotRegistry
```

### Type Definitions

**WriteTxn Struct**:
```rust
pub struct WriteTxn<'db> {
    inner: ref_model::WriteTxn<'db>,
    txn_ctx: TransactionContext,
    db: &'db Db,
    txn_id: TxnId,
    start_lsn: Lsn,
    state: TransactionState,
    has_mutations: bool,
    _phantom: PhantomData<&'db Db>,
}
```

**Key Design Decisions**:
- **Lifetime Parameter `'db`**: Ensures WriteTxn cannot outlive the Db reference
- **PhantomData**: Makes lifetime explicit and enables variance
- **inner ref_model::WriteTxn**: Delegates B+tree operations to reference model
- **txn_ctx: TransactionContext**: Owns the mutation buffer and state tracking

**TransactionContext** (defined separately in txn module):
```rust
pub struct TransactionContext {
    pub txn_id: TxnId,
    pub parent_txn_id: TxnId,
    pub state: TransactionState,
    pub mutations: Vec<Mutation>,
    pub allocated_pages: Vec<PageId>,
    pub modified_pages: HashMap<PageId, Vec<u8>>, // page_id -> before_image
    pub timestamp_ns: u64,
}
```

**Mutation Enum**:
```rust
pub enum Mutation {
    Put { key: Vec<u8>, value: Vec<u8> },
    Delete { key: Vec<u8> },
}
```

### Concurrency

**Pattern**: Use interior mutability with Cell for state tracking within single-threaded WriteTxn

**Rationale**: WriteTxn is not thread-safe (should not be shared across threads). It should explicitly not implement Sync or Send for the mutable operations. However, the Db reference it holds can be shared.

**Thread Safety**:
- WriteTxn should NOT implement Sync (not safe to share references)
- WriteTxn CAN implement Send (can be moved across threads, but only one thread at a time)
- Db.writer_active flag should be AtomicBool for lock-free check in begin_write()

### Key Decisions

**Owned vs Borrowed Keys/Values**:
- **Choice**: Use owned Vec<u8> for keys and values in mutation buffer
- **Rationale**: put() and delete() accept borrowed &[u8], but we copy into owned buffers to ensure the mutation data outlives the caller's slices. This is safer and simpler than managing lifetimes.

**Memory Allocation Strategy**:
- **Choice**: Allocate key and value copies immediately in put()/delete()
- **Rationale**: Predictable allocation patterns, easier error handling, no lifetime concerns. The cost is acceptable compared to the commit I/O cost.

**State Management**:
- **Choice**: Explicit TransactionState enum with validated transitions
- **Rationale**: Catches programming errors early (e.g., put() after commit)

**Error Handling**:
- **Choice**: Use Result<T, Error> for all fallible operations
- **Rationale**: Explicit error handling aligns with Rust best practices and database correctness requirements

### Implementation Notes

**Step 1: Mutation Buffering**
- Use Vec<Mutation> for ordered mutation list
- Clone key and value bytes into Vec<u8> for ownership
- Update has_mutations flag on first mutation

**Step 2: Read-Your-Writes in get()**
- First check mutations.iter().rev().find() for matching key
- If found, return the pending mutation result
- If not found, delegate to inner B+tree lookup

**Step 3: Prepare Phase**
- Validate state is Active before transitioning
- Apply mutations to inner B+tree (in-memory)
- Capture before-images for all modified pages
- Build CommitRecord with mutations and new root PageId
- Serialize to WAL format bytes
- Append to WAL and fsync (critical for durability)

**Step 4: Commit Phase**
- Write all dirty pages via pager.write_pages()
- Write meta page via pager.write_meta()
- Fsync database file
- Register snapshot with snapshot_registry.add_snapshot()
- Clear Db.writer_active flag
- Return txn_id

**Step 5: Abort**
- Discard mutations list (drop)
- Clear allocated_pages and modified_pages
- Set state to Aborted
- Clear Db.writer_active flag

**Step 6: Drop Trait**
- Implement Drop to auto-abort if not explicitly committed/aborted
- Prevent resource leaks
- Log warning if transaction dropped while Active (may indicate bug)

### Testing Strategy

**Unit tests needed for**:
- begin_write() correctly enforces single writer
- put() and delete() validate size limits
- get() implements read-your-writes correctly
- Multiple mutations to same key resolved by last-write-wins
- commit() two-phase protocol phases execute in order
- abort() discards mutations and releases lock
- Transaction state transitions validated
- Empty transaction (no mutations) commits successfully
- Large transactions (many mutations) handle correctly

**Property tests for**:
- Transaction state machine invariant (no invalid transitions)
- Mutation buffer order preserved during commit
- Checksum calculation deterministic for same mutations
- Aborted transaction mutations never visible to other transactions

**Integration scenarios**:
- Single transaction with multiple puts, deletes, gets
- Commit with page allocation (B+tree growth)
- Commit with page modification (B+tree node split)
- Abort during prepare phase (WAL written but not committed)
- Concurrent readers during write commit (snapshot isolation)
- begin_write() failure when another writer active
- Recovery after crash during commit (WAL replay)

**Hardening tests**:
- Kill process during WAL append
- Kill process after WAL fsync but before meta page write
- Kill process during page flush
- Kill process during meta page write
- Verify recovery leads to consistent state (either fully committed or fully rolled back)

### Performance Considerations

**Mutation Buffer**:
- Use Vec with pre-allocated capacity for common cases (e.g., 16 mutations)
- Avoid reallocation for small transactions

**Read-Your-Writes Lookup**:
- Linear search through mutations is acceptable for typical transaction sizes (< 100 mutations)
- Consider HashMap index for transactions with many mutations (> 100)

**Commit Path Optimization**:
- Batch page writes during commit phase
- Use scatter-gather I/O if available
- Parallelize checksum calculation for large commit records

**Memory Footprint**:
- Transaction overhead should be minimal (< 1KB for empty transaction)
- Mutation copies add key + value size per operation
- Before-images only for modified pages, not entire database
