# Write Transaction Creation and API

## Purpose

This document describes the creation, lifecycle, and operations of read-write transactions (WriteTxn) in NorthstarDB. Write transactions provide mutation tracking, read-your-writes semantics, two-phase commit, and exclusive write access to ensure serializable isolation.

## Write Transaction Overview

### WriteTxn Characteristics

**Read-Write**: Can modify data (put, delete) and read (get, scan)
- Supports all CRUD operations
- Tracks mutations in memory
- Sees own mutations (read-your-writes)
- Buffers changes until commit

**Exclusive Write Access**: Only one writer at a time
- begin_write() blocks until current writer finishes
- Write lock ensures serialization
- No concurrent writers
- Writers don't block readers (MVCC)

**Read-Your-Writes**: Transaction sees its own mutations
- put() and delete() visible to subsequent get() and scan()
- Pending mutations checked before B+Tree lookup
- Last-write-wins within transaction
- Mutations buffered until commit

**Two-Phase Commit**: Atomic persistence via WAL
- Phase 1: Prepare (validate, build commit record)
- Phase 2: Commit (WAL append, B+Tree apply, registry register, meta flush)
- Crash recovery: All or nothing
- Durable after commit returns

**Not Thread-Safe**: !Send to enforce single-threaded access
- Must remain on creating thread
- Cannot move across threads
- Prevents concurrent mutation bugs
- Compiler enforcement via !Send bound

### Transaction Lifecycle

**Creation (begin_write)**:
1. Acquire exclusive write lock (blocking)
2. Acquire exclusive lock on DbInner
3. Capture snapshot LSN and root page ID (base snapshot)
4. Allocate transaction ID (monotonically increasing)
5. Create WriteTxn with empty mutation buffer
6. Register transaction for cleanup tracking
7. Return WriteTxn to caller

**Active State**:
- get(), scan(), put(), delete() operations allowed
- Mutations buffered in memory
- Read-your-writes enforced
- No coordination with other transactions

**Preparing State**:
- commit() called, validation in progress
- Build commit record from mutations
- Check for conflicts (future feature)
- Transition to committing

**Committing State**:
- Two-phase commit in progress
- WAL append → B+Tree apply → registry register → meta flush
- Irrevocable after WAL append
- Transition to Committed

**Committed State**:
- All mutations persisted
- Transaction terminal
- Operations return TxnClosed error

**Aborted State**:
- Mutations discarded
- Transaction terminal
- Operations return TxnClosed error

## Write Transaction Creation

### db.begin_write()

**Purpose**: Create write transaction with exclusive write access

**Algorithm**:
1. Acquire exclusive write lock (Mutex<()>)
   - Blocking: Wait until current WriteTxn commits/rolls back
   - Timeout: Return LockTimeout if wait exceeds threshold (default 30 seconds)
2. Acquire exclusive lock on DbInner (RwLock::write())
3. Read current_root_page_id from AtomicU64
4. Read snapshot LSN from SnapshotRegistry (base snapshot for reads)
5. Allocate new transaction ID from current_txn_id (AtomicU64::fetch_add)
6. Create WriteTxn with:
   - db: Arc<Db> clone
   - snapshot_lsn: Base snapshot LSN (for reads not affected by mutations)
   - root_page_id: Base root page ID (for reads not affected by mutations)
   - txn_id: Allocated transaction ID
   - pending_ops: HashMap::new() (mutation buffer)
   - pending_size: 0 (total mutation size in bytes)
   - state: TransactionState::Active
7. Register WriteTxn in Db's active transaction registry
8. Release exclusive lock on DbInner (but keep write_lock!)
9. Return Ok(WriteTxn)

**Lock Behavior**:
- Exclusive write lock (Mutex<>) held for entire transaction lifetime
- Exclusive DbInner lock acquired briefly during begin
- DbInner lock released after begin (write_lock ensures exclusivity)
- begin_write() blocks until current writer finishes

**Error Conditions**:
- DatabaseClosed: is_open is false
- LockTimeout: Write lock acquisition timeout (another writer hung)
- SnapshotError: Failed to capture snapshot
- AllocationFailed: Transaction ID allocation failed

**Performance**:
- O(1) time complexity (lock acquisition + atomic reads)
- Blocking: May wait for current writer to finish
- No I/O (snapshot already in memory)
- Typical latency: ~100 nanoseconds (no contention), ~milliseconds (contended)

**Example**:
```
let mut txn = db.begin_write()?;
txn.put(b"key1", b"value1")?;
txn.put(b"key2", b"value2")?;
txn.commit()?;
```

## WriteTxn Structure

### WriteTxn<'db>

**Description**: Read-write transaction handle with lifetime tied to Db

**Fields**:

**db: Arc<Db>**
- Type: Arc<Db>
- Purpose: Keep database alive for transaction lifetime
- Invariants: Always valid, is_open is true during transaction
- Lifetime: 'db (ensures Db outlives WriteTxn)

**snapshot_lsn: Lsn**
- Type: Lsn (u64 wrapper)
- Purpose: Base snapshot LSN for reads not affected by mutations
- Invariants: Valid LSN from SnapshotRegistry
- Immutability: Never changes after transaction begin
- Usage: Visibility for reads of keys not in pending_ops

**root_page_id: PageId**
- Type: PageId (u64 wrapper)
- Purpose: Base root page ID for B+Tree reads
- Invariants: Valid page ID, points to root node
- Immutability: Never changes after transaction begin
- Usage: Starting point for B+Tree traversal

**txn_id: TransactionId**
- Type: TransactionId (u64 wrapper)
- Purpose: Unique identifier for transaction
- Invariants: Monotonically increasing, unique
- Immutability: Never changes after transaction begin
- Usage: WAL commit records, transaction registration

**pending_ops: PendingOpsMap**
- Type: HashMap<Key, PendingOp>
- Purpose: Buffer for pending mutations (put, delete)
- Invariants: Contains all uncommitted mutations
- Mutability: Modified by put(), delete()
- Structure: Key → (Operation, Size)
- Operation enum: Put { value, size }, Delete { tombstone }

**pending_size: usize**
- Type: usize
- Purpose: Total size of pending mutations in bytes
- Invariants: Sum of all operation sizes
- Mutability: Incremented by put(), decremented by rollback
- Validation: Must be <= MAX_DELTA_SIZE (16MB)

**state: TransactionState**
- Type: TransactionState (enum: Active, Preparing, Committed, Aborted)
- Purpose: Track transaction state
- Initial value: TransactionState::Active
- Transitions: Active → Preparing → Committed or Active → Aborted
- Validation: Operations only allowed in Active state

**_phantom: PhantomData<&'db Db>**
- Type: PhantomData<&'db Db>
- Purpose: Tie WriteTxn lifetime to Db
- Invariants: Ensures WriteTxn cannot outlive Db
- Zero-size: No runtime overhead

**write_lock: MutexGuard<()>**
- Type: MutexGuard<'db, ()>
- Purpose: Hold exclusive write lock for transaction lifetime
- Invariants: Lock held from begin to commit/rollback/drop
- Lifetime: 'db (tied to Db lifetime)
- Release: Automatically dropped when WriteTxn drops

**Size**: ~200 bytes (Arc pointer 8B + 4× u64 32B + HashMap ~128B + pending_size 8B + state 1B + guard ~16B + padding)

### WriteTxnTraits

**Clone**: Not implemented (transactions are unique)
- Each begin_write() creates new transaction
- Explicitly prevent accidental cloning
- Use db.begin_write() for new transaction

**!Send**: Not thread-safe (enforces single-threaded access)
- Cannot move across threads
- Prevents concurrent mutation bugs
- Compiler enforcement via !Send bound (due to MutexGuard)

**!Sync**: Not thread-safe for concurrent access
- Only one thread can use WriteTxn at a time
- Prevents data races
- Compiler enforcement via !Sync bound

**Debug**: Display transaction information
- Shows txn_id, snapshot_lsn, root_page_id, state, pending_size, mutation count
- Useful for debugging and logging

**Drop**: Automatic cleanup on scope exit
- Rolls back transaction if Active
- Releases write lock
- Unregisters transaction from Db
- Cleans up mutation buffer

## Write Transaction API Methods

### txn.put(key, value)

**Purpose**: Insert or update key-value pair in transaction

**Algorithm**:
1. Validate transaction state is Active
2. Validate key size <= MAX_KEY_SIZE (4KB)
3. Validate value size <= MAX_VALUE_SIZE (16MB)
4. Calculate operation size: key.len() + value.len() + OVERHEAD
5. Validate pending_size + operation_size <= MAX_DELTA_SIZE (16MB)
6. Check if key already in pending_ops:
   a. If exists and is Put: Subtract old size from pending_size
   b. If exists and is Delete: Subtract old size from pending_size
   c. Remove old entry
7. Add new entry to pending_ops: key → Put { value, size }
8. Add operation size to pending_size
9. Return Ok(())

**Last-Write-Wins**: Within transaction, last put() wins
- Duplicate key: New value replaces old value
- Size tracking: Old size removed, new size added
- Ordering: Latest value visible to get() and scan()

**Write-Your-Writes**: put() visible to subsequent operations
- get(key) returns new value immediately
- scan() includes new value
- delete(key) followed by put(key): put wins

**Error Conditions**:
- TxnClosed: Transaction state is not Active
- KeyTooLarge: key.len() > MAX_KEY_SIZE
- ValueTooLarge: value.len() > MAX_VALUE_SIZE
- DeltaTooLarge: pending_size + operation_size > MAX_DELTA_SIZE

**Performance**:
- O(1) time complexity (HashMap insert)
- No I/O (buffered in memory)
- No locks (single-threaded access)
- Typical latency: ~100 nanoseconds

**Buffering**: Changes not persisted until commit
- Stored in pending_ops HashMap
- Written to WAL during commit
- Applied to B+Tree during commit

**Example**:
```
txn.put(b"user:1:name", b"Alice")?;
txn.put(b"user:1:email", b"alice@example.com")?;
```

### txn.delete(key)

**Purpose**: Delete key from database

**Algorithm**:
1. Validate transaction state is Active
2. Validate key size <= MAX_KEY_SIZE
3. Check if key already in pending_ops:
   a. If exists and is Put: Remove entry, subtract size from pending_size
   b. If exists and is Delete: No-op (already deleted)
   c. Return Ok(()) (no need to add tombstone for pending delete)
4. If key not in pending_ops:
   a. Verify key exists in B+Tree (optional, for error checking)
   b. If key not found: Return KeyNotFound error (optional, can skip)
   c. Create tombstone marker
   d. Calculate tombstone size: key.len() + TOMBSTONE_OVERHEAD
   e. Add entry to pending_ops: key → Delete { tombstone }
   f. Add tombstone size to pending_size
5. Return Ok(())

**Idempotent**: Duplicate delete() is no-op
- Second delete() on same key succeeds without error
- Tombstone not duplicated
- Size not incremented twice

**Read-Your-Writes**: delete() visible to subsequent operations
- get(key) returns None after delete()
- scan() excludes deleted key
- put(key) after delete(key): put wins (replaces tombstone)

**Tombstone**: Marker for deleted key
- Indicates key deleted in transaction
- Distinguished from Put operation
- Applied to B+Tree during commit
- Creates tombstone record in B+Tree (MVCC delete)

**Error Conditions**:
- TxnClosed: Transaction state is not Active
- KeyTooLarge: key.len() > MAX_KEY_SIZE
- KeyNotFound: Key not in database (optional, can be silent)

**Performance**:
- O(1) time complexity (HashMap insert or B+Tree lookup)
- Optional B+Tree lookup: O(log n) for existence check
- No I/O (buffered in memory)
- Typical latency: ~100 nanoseconds (no existence check), ~1-10 microseconds (with existence check)

**Example**:
```
txn.delete(b"user:1")?;
```

### txn.get(key)

**Purpose**: Get value for key, seeing own mutations (read-your-writes)

**Algorithm**:
1. Validate transaction state is Active
2. Validate key size <= MAX_KEY_SIZE
3. Check pending_ops for key:
   a. If found and is Put: Return Ok(Some(value))
   b. If found and is Delete: Return Ok(None)
4. If key not in pending_ops:
   a. Call B+Tree get with key, root_page_id, snapshot_lsn
   b. B+Tree traversal and search (same as ReadTxn)
   c. Return Ok(value) or Ok(None)
5. Return result

**Read-Your-Writes**: Priority order for lookups
1. pending_ops (highest priority): See own mutations first
2. B+Tree: See base snapshot for keys not mutated

**Visibility Rules**:
- Put in pending_ops: Return new value
- Delete in pending_ops: Return None
- Not in pending_ops: Query B+Tree with base snapshot

**Error Conditions**:
- TxnClosed: Transaction state is not Active
- KeyTooLarge: key.len() > MAX_KEY_SIZE
- CorruptBtree: B+Tree structure corruption
- BufferTooSmall: Buffer too small for value
- AllocationFailed: Memory allocation failed

**Performance**:
- O(1) if key in pending_ops (HashMap lookup)
- O(log n) if key not in pending_ops (B+Tree traversal)
- Typical latency: ~100 nanoseconds (cached), ~1-10 microseconds (disk I/O)

**Example**:
```
txn.put(b"key", b"value1")?;
let value = txn.get(b"key")?; // Returns Some(b"value1")
txn.delete(b"key")?;
let value = txn.get(b"key")?; // Returns None
```

### txn.scan(start, end)

**Purpose**: Iterate over key range, seeing own mutations

**Algorithm**:
1. Validate transaction state is Active
2. Validate start <= end
3. Validate key sizes <= MAX_KEY_SIZE
4. Create ScanIterator with:
   - db: Arc<Db> clone
   - root_page_id: Transaction's root page ID
   - snapshot_lsn: Transaction's snapshot LSN
   - start: Start key (inclusive)
   - end: End key (exclusive)
   - pending_ops: Reference to pending_ops (for mutation integration)
5. Return ScanIterator

**ScanIterator Behavior**:
- Implements Iterator trait
- Integrates pending_ops with B+Tree scan
- For each key in range:
  - Check pending_ops first
  - If Put in pending_ops: Return (key, new_value)
  - If Delete in pending_ops: Skip key
  - If not in pending_ops: Query B+Tree, return if exists
- Monotonic keys: Sorted order maintained
- Mutation priority: pending_ops overrides B+Tree

**Error Conditions**:
- TxnClosed: Transaction state is not Active
- InvalidRange: start > end
- KeyTooLarge: start or end > MAX_KEY_SIZE
- CorruptBtree: B+Tree structure corruption

**Performance**:
- O(log n + k) time complexity (k = results)
- First result: O(log n) (B+Tree traversal)
- Subsequent results: O(1) amortized (leaf linked list)
- Pending ops integration: O(1) per key (HashMap lookup)

**Example**:
```
txn.put(b"key2", b"value2")?;
txn.delete(b"key3")?;
for result in txn.scan(b"key", None)? {
    let (key, value) = result?;
    // Sees key2 with new value, doesn't see key3 (deleted)
}
```

### txn.commit()

**Purpose**: Commit transaction (two-phase commit)

**Algorithm**:
1. Validate transaction state is Active
2. Transition state to Preparing
3. Validate pending_ops not empty (error if empty)
4. Validate pending_size <= MAX_DELTA_SIZE
5. Validate operation count <= MAX_OPERATIONS_PER_TXN (1000)
6. Build commit record:
   a. Serialize all mutations to commit record format
   b. Calculate checksum for commit record
   c. Allocate buffer for serialized commit record
7. Transition state to Committing
8. Phase 1: WAL Append
   a. Append commit record to WAL
   b. fsync WAL (durability)
   c. Get new LSN from WAL
9. Phase 2: B+Tree Apply
   a. For each mutation in commit record:
      - If Put: Apply to B+Tree (insert or update)
      - If Delete: Apply to B+Tree (create tombstone)
   b. Get new root page ID from B+Tree
10. Phase 3: SnapshotRegistry Register
    a. Register new snapshot with txn_id and new_root_page_id
    b. Update current_txn_id
    c. Update current_root_page_id
11. Phase 4: Meta Page Update
    a. Update meta page with new_root_page_id
    b. fsync database file
12. Phase 5: Finalize
    a. Clear pending_ops HashMap
    b. Reset pending_size to 0
    c. Transition state to Committed
    d. Release write lock (drop MutexGuard)
    e. Unregister transaction from Db
    f. Return Ok(())
13. Error Handling: If any phase fails:
    a. Rollback transaction (discard mutations, release lock)
    b. Return error

**Two-Phase Commit Details**:

**Phase 1: Prepare (in-memory)**:
- Validate mutations (size, count, format)
- Build commit record (serialize mutations)
- Calculate checksum
- No I/O yet (reversible)

**Phase 2: Commit (on-disk, irreversible after WAL append)**:
- Append commit record to WAL
- fsync WAL (durability point)
- Apply mutations to B+Tree
- Register snapshot in SnapshotRegistry
- Update meta page
- fsync database file

**Crash Recovery Points**:
- Before WAL append: Transaction not applied (no state change)
- After WAL append, before B+Tree apply: Replay completes commit
- After B+Tree apply, before meta update: Replay completes commit
- After meta update: Transaction fully committed

**Error Conditions**:
- TxnClosed: Transaction already committed or rolled back
- EmptyTransaction: No mutations to commit
- DeltaTooLarge: pending_size > MAX_DELTA_SIZE
- TooManyOperations: operation_count > MAX_OPERATIONS_PER_TXN
- IoError: WAL append or B+Tree update failed
- CorruptBtree: B+Tree corruption during apply
- SerializationError: Commit record serialization failed

**Performance**:
- O(n) time complexity (n = number of mutations)
- WAL append: Single sequential write (fast)
- B+Tree apply: O(n log m) (m = tree size)
- Meta update: O(1) (single page write)
- fsync: Dominant cost (~10-100 ms)

**Durability**: Transaction persists after commit() returns
- WAL fsync ensures durability
- Crash recovery replays from WAL if needed
- Meta page update provides checkpoint

**Example**:
```
txn.put(b"key1", b"value1")?;
txn.put(b"key2", b"value2")?;
txn.commit()?; // All or nothing
```

### txn.rollback()

**Purpose**: Rollback transaction (discard mutations)

**Algorithm**:
1. Validate transaction state is Active
2. Transition state to Aborted
3. Clear pending_ops HashMap (discard all mutations)
4. Reset pending_size to 0
5. Release write lock (drop MutexGuard)
6. Unregister transaction from Db
7. Return Ok(())

**Idempotent**: Multiple calls safe
- Subsequent calls after first are no-ops
- State already Aborted

**Discard Mutations**: All changes lost
- pending_ops cleared
- pending_size reset
- No WAL write
- No B+Tree modification

**Release Lock**: Allows next writer to proceed
- MutexGuard dropped
- begin_write() unblocks

**Use Cases**:
- Explicit abort on error condition
- Early termination
- Consistency check failure

**Example**:
```
txn.put(b"key1", b"value1")?;
if error_condition {
    txn.rollback()?;
    return Err(error);
}
txn.commit()?;
```

### txn.id()

**Purpose**: Get transaction ID

**Returns**: TransactionId

**Use Cases**:
- Logging and debugging
- Correlating operations with transactions
- Transaction tracking

**Example**:
```
let txn = db.begin_write()?;
println!("Transaction ID: {}", txn.id());
```

### txn.mutation_count()

**Purpose**: Get number of pending mutations

**Returns**: usize (pending_ops.len())

**Use Cases**:
- Logging and debugging
- Transaction monitoring
- Size validation

**Example**:
```
txn.put(b"key1", b"value1")?
txn.put(b"key2", b"value2")?
println!("Mutations: {}", txn.mutation_count()); // 2
```

## Write Transaction Drop

### Implicit Rollback

**Drop Trait Implementation**:
1. Check transaction state
2. If Active:
   a. Rollback transaction (clear mutations, release lock)
   b. Log warning (transaction dropped without commit or rollback)
3. If Preparing/Committing:
   a. Panic (commit in progress, drop is programmer error)
4. If Committed/Aborted:
   - No-op (already terminal)

**Automatic Scope Exit**:
```
{
    let mut txn = db.begin_write()?;
    txn.put(b"key", b"value")?;
    // forgot to call commit() or rollback()
} // txn.drop() called → rollback automatically
```

**Panic Safety**:
- Drop always executes, even during panic
- Unwind-safe: No double-panic
- Resources cleaned up (mutations discarded, lock released)

**Warning for Active Drop**:
- Log warning if transaction Active when dropped
- Indicates likely programming error
- Suggests missing commit() or rollback()

**Panic During Commit**:
- If drop during Preparing/Committing: Panic
- Indicates serious bug (commit interrupted)
- Database may be in inconsistent state
- Requires recovery

## Invariants

### WriteTxn Invariants

1. **Exclusive Write Access**: Only one WriteTxn active
   - write_lock held for entire transaction lifetime
   - begin_write() blocks until lock available
   - Compiler enforces !Send (cannot move across threads)

2. **Read-Your-Writes**: Transaction sees its own mutations
   - pending_ops checked before B+Tree
   - Last-write-wins within transaction
   - Consistent view for entire transaction

3. **Mutation Buffering**: Changes not visible until commit
   - pending_ops stores uncommitted mutations
   - B+Tree not modified until commit
   - Other transactions don't see mutations

4. **State Transitions**: Active → Preparing → Committed or Active → Aborted
   - Active: Operations allowed
   - Preparing: commit() in progress, validation
   - Committing: WAL append and B+Tree apply
   - Committed/Aborted: Terminal, operations return TxnClosed

5. **Two-Phase Commit**: All or nothing persistence
   - Prepare: Validate and serialize
   - Commit: WAL → B+Tree → Registry → Meta
   - Crash recovery: Replay completes commit

6. **Size Limits**: Mutations within configured limits
   - pending_size <= MAX_DELTA_SIZE (16MB)
   - operation_count <= MAX_OPERATIONS_PER_TXN (1000)

## Dependencies

### WriteTxn Uses

- **Db**: Snapshot capture, transaction registration, coordination
- **BTree**: get() and scan() operations, commit apply
- **Wal**: Commit record append, LSN allocation
- **SnapshotRegistry**: Snapshot registration on commit
- **Config**: MAX_KEY_SIZE, MAX_VALUE_SIZE, MAX_DELTA_SIZE, MAX_OPERATIONS_PER_TXN

### WriteTxn Used By

- **Application Code**: All write operations, mutations, transactions

## Rust Implementation Guidance

### Module Structure

```
northstar-core/src/txn/
├── mod.rs          # Transaction traits and common types
├── write.rs        # WriteTxn implementation
└── pending.rs      # PendingOpsMap and PendingOp types
```

### Type Definitions

**WriteTxn**: Should be public struct with private fields
- Lifetime parameter 'db tied to Db
- Fields: db, snapshot_lsn, root_page_id, txn_id, pending_ops, pending_size, state, phantom, write_lock
- Does NOT implement Send, Sync, or Clone
- Implements !Send via MutexGuard<'db, ()> field

**PendingOp**: Should be enum with Put and Delete variants
- Put { value: Vec<u8>, size: usize }
- Delete { tombstone: TombstoneMarker }

**PendingOpsMap**: Should be HashMap<Key, PendingOp>
- Fast O(1) lookup for read-your-writes
- Iteration support for commit serialization

### Concurrency

**WriteTxn Thread-Safety**:
- !Send: Cannot move across threads
- !Sync: Only one thread can access at a time
- Enforced by MutexGuard<'db, ()> field (contains borrowed data)
- Compiler errors if attempt to send across threads

**Lock Strategy**:
- begin_write(): Acquires exclusive write lock (blocking)
- Holding lock: Entire transaction lifetime
- get(), put(), delete(), scan(): No additional locks (single-threaded)
- commit(), rollback(): Release lock before returning

### Key Decisions

**MutexGuard<'db, ()> vs separate lock field**:
- Choose MutexGuard as field to enforce !Send
- Borrowed data with lifetime 'db prevents Send
- Compiler enforces single-threaded access
- Automatic lock release on drop

**HashMap for pending_ops vs Vec**:
- Choose HashMap for O(1) lookup
- Read-your-writes requires fast key lookup
- Tradeoff: More memory vs faster lookups
- Alternative: BTreeMap for ordered iteration (slower lookups)

**Separate pending_size vs recalculate**:
- Choose incremental tracking (pending_size field)
- O(1) size validation
- Tradeoff: Maintain invariant vs calculate on demand
- Recalculating would be O(n) for each put()

**Explicit rollback vs implicit rollback only**:
- Provide both explicit rollback() and implicit drop
- Explicit: Clear intent, early termination
- Implicit: Safety net, resource cleanup
- Log warning on implicit rollback (likely bug)

### Implementation Notes

**Step 1: Transaction Begin (begin_write)**
- Acquire write lock (Mutex::lock()) - blocking
- Acquire exclusive lock on DbInner
- Read current_root_page_id and snapshot_lsn
- Allocate txn_id (atomic fetch_add)
- Create WriteTxn with empty pending_ops
- Register in Db's transaction registry
- Release exclusive DbInner lock
- Keep write lock (MutexGuard stored in WriteTxn)
- Return WriteTxn

**Step 2: put() Operation**
- Validate state is Active
- Validate key and value sizes
- Check for duplicate key in pending_ops
- Remove old entry if exists (last-write-wins)
- Add new Put entry to pending_ops
- Update pending_size
- Return Ok(())

**Step 3: delete() Operation**
- Validate state is Active
- Validate key size
- Check pending_ops for key
- If Put exists: Remove entry, update pending_size
- If Delete exists: No-op (idempotent)
- If not in pending_ops: Add Delete entry with tombstone
- Return Ok(())

**Step 4: get() Operation**
- Validate state is Active
- Check pending_ops for key
- If Put found: Return Ok(Some(value))
- If Delete found: Return Ok(None)
- If not found: Query B+Tree with base snapshot
- Return result

**Step 5: scan() Operation**
- Validate state is Active
- Create ScanIterator with pending_ops reference
- Iterator merges pending_ops with B+Tree scan
- Return iterator

**Step 6: commit() Operation**
- Validate state is Active
- Transition to Preparing
- Validate mutations (size, count)
- Build commit record (serialize)
- Transition to Committing
- Append commit record to WAL
- fsync WAL
- Apply mutations to B+Tree
- Register snapshot in SnapshotRegistry
- Update meta page
- fsync database file
- Clear pending_ops
- Transition to Committed
- Release write lock (drop MutexGuard)
- Unregister from Db
- Return Ok(())

**Step 7: rollback() Operation**
- Validate state is Active
- Transition to Aborted
- Clear pending_ops
- Reset pending_size
- Release write lock (drop MutexGuard)
- Unregister from Db
- Return Ok(())

**Step 8: drop() Operation**
- If Active:
  - Rollback (same as rollback())
  - Log warning
- If Preparing/Committing:
  - Panic (serious bug)
- If Committed/Aborted:
  - No-op

### Testing Strategy

**Unit tests needed for**:
- begin_write() creates valid WriteTxn (blocks if writer active)
- put() adds entry to pending_ops
- put() handles duplicate keys (last-write-wins)
- put() validates key and value sizes
- put() validates pending_size limit
- delete() adds Delete entry to pending_ops
- delete() handles duplicate deletes (idempotent)
- delete() removes pending Put entry
- get() returns value from pending_ops
- get() returns None for pending Delete
- get() queries B+Tree for keys not in pending_ops
- scan() integrates pending_ops with B+Tree
- commit() persists mutations to WAL
- commit() applies mutations to B+Tree
- commit() updates SnapshotRegistry
- commit() updates meta page
- rollback() discards mutations
- rollback() releases write lock
- drop() rolls back Active transaction
- drop() panics during commit

**Property tests needed for**:
- Read-your-writes: put() visible to get()
- Last-write-wins: Duplicate put() keeps last value
- Idempotent delete: Second delete() is no-op
- Atomic commit: All mutations or none
- Commit durability: Mutations persist after crash
- Rollback discard: Mutations lost after rollback

**Integration tests needed for**:
- Large transactions: Many mutations (approaching limits)
- Long-running transactions: Hold write lock for extended period
- Concurrent writes: begin_write() blocks until current writer finishes
- Write-read concurrency: Readers don't see uncommitted writes
- Crash recovery: Committed transactions survive crash

**Performance benchmarks needed for**:
- begin_write() latency (with and without contention)
- put() latency (in-memory buffering)
- delete() latency (in-memory buffering)
- get() latency (pending_ops vs B+Tree)
- scan() throughput (with mutations)
- commit() latency (WAL append, B+Tree apply, meta update)
- commit() throughput (mutations per second)
- rollback() latency
