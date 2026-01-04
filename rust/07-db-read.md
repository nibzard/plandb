# Read Transaction Creation and API

## Purpose

This document describes the creation, lifecycle, and operations of read-only transactions (ReadTxn) in NorthstarDB. Read transactions provide snapshot isolation, allowing consistent reads from a point-in-time view of the database without blocking other readers or writers.

## Read Transaction Overview

### ReadTxn Characteristics

**Read-Only**: Cannot modify data
- No put, delete, or mutation operations
- Operations limited to get and scan
- No conflict detection needed
- No coordination with other transactions

**Snapshot Isolation**: Consistent view as of transaction start
- Snapshot captured at transaction begin
- All reads see same database state
- No dirty reads (never see uncommitted data)
- No non-repeatable reads (same key returns same value)
- Snapshot determined by LSN (Log Sequence Number)

**Non-Blocking**: Multiple readers proceed concurrently
- No locks between readers
- Readers don't block writers
- Writers don't block readers
- Shared access to DbInner

**Thread-Safe**: Send + Sync for cross-thread usage
- Can move across threads
- Multiple threads can share ReadTxn
- Safe for concurrent operations
- Cheap to clone (Arc::clone)

### Transaction Lifecycle

**Creation (begin_read)**:
1. Acquire shared lock on DbInner
2. Capture snapshot LSN and root page ID
3. Allocate transaction ID (monotonically increasing)
4. Create ReadTxn handle
5. Register transaction for cleanup tracking
6. Return ReadTxn to caller

**Active State**:
- get() and scan() operations allowed
- Reads see snapshot state only
- No mutations allowed
- Snapshot never changes

**Termination (commit or drop)**:
1. Unregister transaction from Db
2. Release snapshot reference
3. Allow snapshot cleanup if no other references
4. Drop handle

## Read Transaction Creation

### db.begin_read()

**Purpose**: Create read transaction on latest snapshot

**Algorithm**:
1. Acquire shared lock on DbInner (RwLock::read())
2. Read current_root_page_id from AtomicU64 (lock-free)
3. Read snapshot LSN from current_root_page_id (via SnapshotRegistry)
4. Allocate new transaction ID from current_txn_id (AtomicU64::fetch_add)
5. Create ReadTxn with:
   - db: Arc<Db> clone
   - snapshot_lsn: Current LSN
   - root_page_id: Current root page ID
   - txn_id: Allocated transaction ID
6. Register ReadTxn in Db's active transaction registry
7. Increment reference count on snapshot
8. Release shared lock
9. Return Ok(ReadTxn)

**Lock Behavior**:
- Shared lock on DbInner (allows concurrent readers)
- Fast path: Only lock acquisition, no I/O
- No blocking: Multiple begin_read() calls proceed concurrently
- Lock released before returning

**Error Conditions**:
- DatabaseClosed: is_open is false
- LockTimeout: Shared lock acquisition failed (rare)
- SnapshotError: Failed to capture snapshot (internal error)

**Performance**:
- O(1) time complexity (lock acquisition + atomic reads)
- No I/O (snapshot already in memory)
- No memory allocations (except ReadTxn handle)
- Typical latency: ~100 nanoseconds

**Example**:
```
let txn = db.begin_read()?;
let value = txn.get(b"key")?;
```

### db.begin_read_at(txn_id)

**Purpose**: Create read transaction at historical snapshot

**Algorithm**:
1. Acquire shared lock on DbInner (RwLock::read())
2. Query SnapshotRegistry for root_page_id at txn_id
3. If txn_id not found → return SnapshotNotFound error
4. If txn_id > current_txn_id → return TransactionInFuture error
5. If txn_id too old (garbage collected) → return TransactionExpired error
6. Create ReadTxn with:
   - db: Arc<Db> clone
   - snapshot_lsn: LSN from snapshot
   - root_page_id: root_page_id from snapshot
   - txn_id: Requested transaction ID
7. Register ReadTxn in Db's active transaction registry
8. Increment reference count on snapshot
9. Release shared lock
10. Return Ok(ReadTxn)

**Lock Behavior**:
- Shared lock on DbInner (allows concurrent readers)
- Lock held during SnapshotRegistry lookup
- Lock released before returning

**Error Conditions**:
- DatabaseClosed: is_open is false
- SnapshotNotFound: txn_id not in SnapshotRegistry
- TransactionInFuture: txn_id > current_txn_id
- TransactionExpired: txn_id garbage collected (too old)
- LockTimeout: Shared lock acquisition failed

**Use Cases**:
- Time-travel queries: Read database as of past transaction
- Historical analysis: Compare current vs past state
- Audit: Review database state at specific point in time
- Debugging: Inspect state before/after bug

**Example**:
```
let old_txn = db.begin_read_at(old_txn_id)?;
let past_value = old_txn.get(b"key")?;
```

## ReadTxn Structure

### ReadTxn<'db>

**Description**: Read-only transaction handle with lifetime tied to Db

**Fields**:

**db: Arc<Db>**
- Type: Arc<Db>
- Purpose: Keep database alive for transaction lifetime
- Invariants: Always valid, is_open is true during transaction
- Lifetime: 'db (ensures Db outlives ReadTxn)

**snapshot_lsn: Lsn**
- Type: Lsn (u64 wrapper)
- Purpose: LSN of snapshot for transaction
- Invariants: Valid LSN from SnapshotRegistry
- Immutability: Never changes after transaction begin
- Visibility: Only records with LSN <= snapshot_lsn are visible

**root_page_id: PageId**
- Type: PageId (u64 wrapper)
- Purpose: Root page ID of B+Tree for snapshot
- Invariants: Valid page ID, points to root node
- Immutability: Never changes after transaction begin
- Usage: Starting point for B+Tree traversal

**txn_id: TransactionId**
- Type: TransactionId (u64 wrapper)
- Purpose: Unique identifier for transaction
- Invariants: Monotonically increasing, unique
- Immutability: Never changes after transaction begin
- Usage: Registration, tracking, debugging

**state: TransactionState**
- Type: TransactionState (enum: Active, Committed, Aborted)
- Purpose: Track transaction state
- Initial value: TransactionState::Active
- Transitions: Active → Committed (commit) or Aborted (rollback/drop)
- Validation: Operations only allowed in Active state

**_phantom: PhantomData<&'db Db>**
- Type: PhantomData<&'db Db>
- Purpose: Tie ReadTxn lifetime to Db
- Invariants: Ensures ReadTxn cannot outlive Db
- Zero-size: No runtime overhead

**Size**: ~64 bytes (Arc pointer 8B + 3× u64 24B + state 1B + phantom 0B + padding)

### ReadTxnTraits

**Clone**: Not implemented (transactions are unique)
- Each begin_read() creates new transaction
- Explicitly prevent accidental cloning
- Use db.begin_read() for new transaction

**Send + Sync**: Thread-safe for concurrent access
- Multiple threads can share ReadTxn
- get() and scan() are thread-safe
- Snapshot is immutable, no coordination needed

**Debug**: Display transaction information
- Shows txn_id, snapshot_lsn, root_page_id, state
- Useful for debugging and logging

**Drop**: Automatic cleanup on scope exit
- Unregisters transaction from Db
- Decrements snapshot reference count
- Triggers snapshot cleanup if last reference

## Read Transaction API Methods

### txn.get(key)

**Purpose**: Get value for key from snapshot

**Algorithm**:
1. Validate transaction state is Active
2. Validate key size <= MAX_KEY_SIZE (4KB)
3. Call B+Tree get with:
   - key: Key to look up
   - root_page_id: Transaction's root page ID
   - snapshot_lsn: Transaction's snapshot LSN
4. B+Tree traversal:
   a. Start at root_page_id
   b. Traverse internal nodes using binary search
   c. Reach leaf node
   d. Search leaf node for key
   e. If key found:
      - Check MVCC version chain
      - Find version with LSN <= snapshot_lsn
      - Check version not deleted (tombstone)
      - Return Some(value) if visible version exists
   f. If key not found:
      - Return None
5. Return Ok(Some(value)) or Ok(None)

**Error Conditions**:
- TxnClosed: Transaction state is not Active
- KeyTooLarge: key size > MAX_KEY_SIZE
- CorruptBtree: B+Tree structure corruption detected
- BufferTooSmall: Buffer too small for value (rare)
- AllocationFailed: Memory allocation failed

**Performance**:
- O(log n) time complexity (B+Tree height)
- Typical: 3-4 page reads for 1B keys
- Cache-friendly: Pages cached in Pager
- Typical latency: ~1-10 microseconds (cached), ~1-10 ms (disk I/O)

**Visibility Rules**:
- Only records with LSN <= snapshot_lsn are visible
- Deleted records (tombstones) are invisible (return None)
- Multiple versions: Return newest visible version
- Write-your-writes: Not applicable (read-only transaction)

**Example**:
```
let txn = db.begin_read()?;
match txn.get(b"my_key")? {
    Some(value) => println!("Value: {:?}", value),
    None => println!("Key not found"),
}
```

### txn.scan(start, end)

**Purpose**: Iterate over key range [start, end)

**Algorithm**:
1. Validate transaction state is Active
2. Validate start <= end (lexicographic comparison)
3. Validate key sizes <= MAX_KEY_SIZE
4. Create ScanIterator with:
   - db: Arc<Db> clone
   - root_page_id: Transaction's root page ID
   - snapshot_lsn: Transaction's snapshot LSN
   - start: Start key (inclusive)
   - end: End key (exclusive)
5. Return ScanIterator

**ScanIterator Behavior**:
- Implements Iterator trait (Item = Result<(Key, Value), Error>)
- Forward iteration from start to end
- Lazy loading: Fetch pages on-demand
- Visibility filtering: Skip records with LSN > snapshot_lsn
- Tombstone skipping: Skip deleted records
- Monotonic keys: Keys returned in sorted order
- Stops when next_key >= end

**Error Conditions**:
- TxnClosed: Transaction state is not Active
- InvalidRange: start > end
- KeyTooLarge: start or end > MAX_KEY_SIZE
- CorruptBtree: B+Tree structure corruption

**Performance**:
- O(log n + k) time complexity (k = number of results)
- First result: O(log n) (tree traversal)
- Subsequent results: O(1) amortized (leaf linked list)
- Cache-friendly: Sequential leaf access
- Typical throughput: ~100K-1M records/sec

**Range Boundaries**:
- Inclusive start: start key included if exists
- Exclusive end: end key not included
- Unbounded start: use None for start (scan from beginning)
- Unbounded end: use None for end (scan to end)

**Example**:
```
let txn = db.begin_read()?;
for result in txn.scan(b"prefix_", None)? {
    let (key, value) = result?;
    println!("Key: {:?}, Value: {:?}", key, value);
}
```

### txn.commit()

**Purpose**: Explicitly release transaction (optional)

**Algorithm**:
1. Validate transaction state is Active
2. Transition state to Committed
3. Unregister transaction from Db's active registry
4. Decrement snapshot reference count
5. Trigger snapshot cleanup if reference count is zero
6. Return Ok(())

**Idempotent**: Multiple calls safe (subsequent calls are no-ops)

**Optional**: Drop trait also calls commit automatically

**Use Case**: Explicit resource cleanup, transaction bookkeeping

**Error Conditions**:
- TxnClosed: Transaction already committed or rolled back

**Example**:
```
let txn = db.begin_read()?;
// ... use transaction ...
txn.commit()?; // Explicit release
```

### txn.rollback()

**Purpose**: Explicitly rollback transaction (no-op for read transactions)

**Algorithm**:
1. Validate transaction state is Active
2. Transition state to Aborted
3. Unregister transaction from Db
4. Decrement snapshot reference count
5. Return Ok(())

**No-Op for ReadTxn**: Read transactions have no mutations to rollback

**Equivalent to commit()**: Same cleanup logic

**Use Case**: Consistency with write transaction API, explicit intent

**Example**:
```
let txn = db.begin_read()?;
txn.rollback()?; // Explicit abort
```

### txn.id()

**Purpose**: Get transaction ID

**Returns**: TransactionId

**Use Cases**:
- Logging and debugging
- Correlating operations with transactions
- Time-travel queries (pass to begin_read_at)

**Example**:
```
let txn = db.begin_read()?;
println!("Transaction ID: {}", txn.id());
```

### txn.snapshot_lsn()

**Purpose**: Get snapshot LSN

**Returns**: Lsn

**Use Cases**:
- Logging and debugging
- Understanding snapshot visibility
- Comparing snapshots

**Example**:
```
let txn = db.begin_read()?;
println!("Snapshot LSN: {}", txn.snapshot_lsn());
```

## Read Transaction Concurrency

### Concurrent Reads

**Multiple ReadTxn**:
- All proceed concurrently without coordination
- No locks between readers
- Each reader sees its own snapshot
- No blocking or interference

**Shared Lock on DbInner**:
- begin_read() acquires shared lock
- Multiple shared locks can coexist
- Readers don't block each other
- Fast path: No contention

**Snapshot Isolation**:
- Readers see consistent snapshot
- No dirty reads from uncommitted transactions
- No interference from concurrent writers
- Stable view for entire transaction

### Read-Write Concurrency

**Readers During Active Writer**:
- Readers proceed concurrently with writer
- Readers see snapshot from before writer started
- Writer mutations invisible to readers until commit
- No blocking between readers and writer

**Writer During Active Readers**:
- Writer proceeds independently of readers
- begin_write() acquires exclusive write lock
- Writers don't block active readers
- New readers see pre-writer snapshot

**Post-Commit Visibility**:
- Readers created after writer commit see new state
- Readers created before writer commit see old state
- Snapshots isolated by LSN

## Read Transaction Drop

### Implicit Cleanup

**Drop Trait Implementation**:
1. Check transaction state
2. If Active:
   a. Transition to Aborted
   b. Unregister from Db
   c. Decrement snapshot reference count
3. If already Committed or Aborted:
   - No-op (already cleaned up)

**Automatic Scope Exit**:
```
{
    let txn = db.begin_read()?;
    // ... use transaction ...
} // txn.drop() called automatically
```

**Panic Safety**:
- Drop always executes, even during panic
- Unwind-safe: No double-panic
- Resources cleaned up properly

**Reference Counting**:
- Arc<Db> ensures Db not dropped early
- Snapshot reference count tracked
- Cleanup triggers when count reaches zero

## Invariants

### ReadTxn Invariants

1. **Snapshot Immutability**: Snapshot never changes during transaction
   - snapshot_lsn is constant
   - root_page_id is constant
   - All reads see same view

2. **Read-Only**: No mutations allowed
   - No put, delete, or mutation operations
   - get() and scan() only
   - No conflict detection

3. **State Transitions**: Active → Committed or Aborted
   - Active: Operations allowed
   - Committed/Aborted: Operations return TxnClosed error
   - Terminal states: No transitions out

4. **Lifetime**: ReadTxn cannot outlive Db
   - PhantomData ties lifetime to 'db
   - Arc<Db> keeps Db alive
   - Compiler enforces lifetime

5. **Visibility**: Only records with LSN <= snapshot_lsn are visible
   - MVCC version chain filtered
   - Tombstones invisible
   - Newest visible version returned

### Concurrency Invariants

1. **Readers Don't Block**: Multiple readers proceed concurrently
   - Shared lock on DbInner
   - No inter-reader coordination
   - Non-blocking operations

2. **Readers See Snapshot**: Consistent view as of transaction start
   - No dirty reads
   - No non-repeatable reads
   - Snapshot isolation

3. **Writers Invisible**: Readers don't see uncommitted mutations
   - Writer mutations isolated
   - Post-commit visibility for new transactions
   - Pre-commit visibility for old transactions

## Dependencies

### ReadTxn Uses

- **Db**: Snapshot capture, transaction registration, cleanup
- **BTree**: get() and scan() operations
- **SnapshotRegistry**: Snapshot lookup (LSN, root_page_id)
- **Config**: MAX_KEY_SIZE for validation

### ReadTxn Used By

- **Application Code**: Read operations, queries, scans
- **Time-Travel Queries**: Historical database inspection

## Rust Implementation Guidance

### Module Structure

```
northstar-core/src/txn/
├── mod.rs          # Transaction traits and common types
├── read.rs         # ReadTxn implementation
└── scan.rs         # ScanIterator implementation
```

### Type Definitions

**ReadTxn**: Should be public struct with private fields
- Lifetime parameter 'db tied to Db
- Fields: db, snapshot_lsn, root_page_id, txn_id, state, phantom
- Implements Send + Sync
- Does NOT implement Clone (explicit new transaction required)

**ScanIterator**: Should be public struct with private fields
- Lifetime parameter tied to ReadTxn
- Implements Iterator trait
- Fields: db, root_page_id, snapshot_lsn, start, end, current_position
- Implements Send + Sync

### Concurrency

**ReadTxn Thread-Safety**:
- Send + Sync allows cross-thread usage
- get() and scan() are thread-safe
- Snapshot is immutable (no coordination needed)
- Multiple threads can call get()/scan() concurrently

**Lock Strategy**:
- begin_read(): Shared lock on DbInner (fast)
- get(): No locks (read from immutable snapshot)
- scan(): No locks (read from immutable snapshot)
- commit()/rollback(): Unregister (atomic operation)

### Key Decisions

**Arc<Db> vs &'db Db for db field**:
- Choose Arc<Db> because ReadTxn needs owned handle
- Allows ReadTxn to be stored and moved
- Enables flexible lifetime management
- Compiler ensures Db outlives ReadTxn via 'db lifetime

**PhantomData for lifetime**:
- Use PhantomData<&'db Db> to tie ReadTxn to Db
- Zero-cost at runtime (no actual data)
- Compiler enforces lifetime rules
- Prevents use-after-close

**No Clone for ReadTxn**:
- Don't implement Clone to prevent accidental duplication
- Each transaction should be explicitly created
- Clear intent: One transaction, one lifetime
- Use db.begin_read() for new transaction

**State tracking vs flag**:
- Use TransactionState enum instead of bool flag
- Clearer semantics (Active, Committed, Aborted)
- Enables future state machine extensions
- Better error messages

### Implementation Notes

**Step 1: Transaction Begin (begin_read)**
- Acquire shared lock on DbInner
- Read current_root_page_id (atomic load)
- Query SnapshotRegistry for LSN at root_page_id
- Allocate txn_id (atomic fetch_add on current_txn_id)
- Create ReadTxn with captured state
- Register in Db's transaction registry
- Increment snapshot reference count
- Release shared lock
- Return ReadTxn

**Step 2: get() Operation**
- Validate state is Active
- Validate key size <= MAX_KEY_SIZE
- Call btree.get(key, root_page_id, snapshot_lsn)
- B+Tree traverses from root_page_id
- B+Tree searches leaf for key
- B+Tree checks MVCC visibility (LSN <= snapshot_lsn)
- Return Some(value) or None

**Step 3: scan() Operation**
- Validate state is Active
- Validate start <= end
- Validate key sizes
- Create ScanIterator with range and snapshot
- Return ScanIterator (implements Iterator)

**Step 4: commit() Operation**
- Validate state is Active
- Transition to Committed
- Unregister from Db
- Decrement snapshot reference count
- Trigger cleanup if count is zero
- Return Ok(())

**Step 5: drop() Operation**
- If Active:
  - Transition to Aborted
  - Unregister from Db
  - Decrement snapshot reference count
- If Committed/Aborted:
  - No-op

### Testing Strategy

**Unit tests needed for**:
- begin_read() creates valid ReadTxn
- begin_read_at() with valid txn_id
- begin_read_at() with invalid txn_id (not found, future, expired)
- get() returns existing value
- get() returns None for missing key
- get() respects snapshot LSN (invisible uncommitted records)
- get() handles deleted keys (returns None)
- scan() iterates over range
- scan() respects boundaries (inclusive start, exclusive end)
- scan() handles unbounded ranges (None for start/end)
- scan() returns empty iterator for empty range
- commit() is idempotent
- rollback() is no-op
- drop() cleans up resources

**Property tests needed for**:
- Snapshot isolation: Readers see consistent view
- Concurrent reads: Multiple readers don't block
- Read-write concurrency: Readers don't see uncommitted writes
- Scan monotonicity: Keys returned in sorted order
- Scan completeness: All keys in range returned

**Integration tests needed for**:
- Large transactions: Many get() and scan() operations
- Long-running transactions: Snapshots retained
- Time-travel queries: begin_read_at() with historical txn_id
- Concurrent workload: Many readers, single writer

**Performance benchmarks needed for**:
- begin_read() latency
- get() latency (cached vs disk I/O)
- scan() throughput (records per second)
- Concurrent read scalability (readers vs throughput)
