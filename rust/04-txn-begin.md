# Transaction Begin

## Purpose

Transaction begin is the entry point for all database operations in NorthstarDB. It creates a new transaction context, allocates a unique transaction identifier, captures the starting snapshot for MVCC, and initializes all state needed for the transaction lifecycle. The begin process is designed to be fast and minimal, deferring expensive operations until commit time. Transaction begin handles both read-only and read-write transactions with different initialization paths and resource requirements.

## Overview

Transaction begin is the process of transitioning from "no transaction" to "active transaction" state. It involves:
- Allocating a unique TransactionId from a global counter
- Determining transaction type (read vs write)
- Acquiring appropriate locks (shared for reads, exclusive for writes)
- Capturing the starting snapshot for MVCC visibility
- Registering the transaction with the database context
- Initializing transaction-local state (mutations, page tracking, etc.)

The begin operation is designed to be:
- **Fast**: Minimal work during begin, defer expensive operations
- **Safe**: Unique ID allocation, proper lock acquisition
- **Isolated**: Each transaction gets independent state
- **Trackable**: All active transactions registered for cleanup

## Transaction Types

### Read-Only Transactions (ReadTxn)

**Description**: Transactions that can only read data, never modify

**Characteristics**:
- Shared access (multiple readers can proceed concurrently)
- Snapshot isolation at transaction start
- No mutation tracking needed
- No two-phase commit (just release resources on close)
- Lower overhead than write transactions

**Use Cases**:
- Queries and analytics
- Reporting and aggregation
- Time-travel queries (historical snapshots)
- Concurrent read-heavy workloads

**Initialization Differences**:
- Acquires shared lock on database
- Captures snapshot from snapshot registry
- No pending mutations buffer
- No page tracking structures
- Simpler state machine (Active → Closed)

### Read-Write Transactions (WriteTxn)

**Description**: Transactions that can read and modify data

**Characteristics**:
- Exclusive access (only one writer at a time)
- Mutation tracking for two-phase commit
- Write-your-writes visibility
- Before-images for rollback
- Higher overhead for tracking and coordination

**Use Cases**:
- Data modifications (inserts, updates, deletes)
- Multi-step atomic operations
- Application state changes
- Write-heavy workloads

**Initialization Differences**:
- Acquires exclusive lock on database
- Initializes empty mutation buffer
- Allocates page tracking structures
- Prepares for two-phase commit
- More complex state machine (Active → Preparing → Committed/Aborted)

## TransactionId Allocation

### Global Counter

**Description**: Monotonically increasing counter for unique transaction IDs

**Storage**: In database meta page, persisted across restarts

**Type**: u64 (64-bit unsigned integer)

**Initial Value**: 1 (txn_id 0 is reserved)

**Allocation Algorithm**:
1. Read current txn_id from database meta page
2. Atomically increment by 1
3. Write new value back to meta page (optional: can defer to checkpoint)
4. Return allocated txn_id to caller

**Uniqueness Guarantee**:
- Atomic increment ensures no two transactions get same ID
- Counter persisted across restarts prevents reuse after crash
- 64-bit range provides virtually unlimited IDs (18 quintillion)

**Concurrency**:
- Use atomic fetch-and-add for lock-free allocation
- Multiple threads can allocate IDs without contention
- Meta page write can be batched (written during checkpoint)

**Recovery Considerations**:
- After crash, reload counter from meta page
- Any IDs allocated but not committed are orphaned (acceptable)
- Counter continues from last persisted value
- No need to reclaim orphaned IDs (64-bit space is sufficient)

### Reserved TransactionIds

**txn_id 0**: Reserved/invalid
- Never allocated to actual transactions
- Used to indicate "no transaction" or invalid state
- Parent_txn_id is 0 for top-level transactions (no nesting in V0)

**Special Values**: None other than 0
- All other values are valid transaction IDs
- No special meaning for specific ranges
- Simpler than having sentinel values for different purposes

## Lock Acquisition

### Read Transaction Locks

**Shared Lock**: Acquire shared read lock on database
- Multiple readers can hold shared lock concurrently
- Readers do not block each other
- Writer must wait for all shared locks to release
- Implemented via RwLock read lock

**Lock Acquisition Order**:
1. Attempt to acquire shared lock
2. If writer is active, wait until writer completes
3. Once acquired, proceed with snapshot capture
4. Lock held until transaction closes

**Fairness**: FIFO ordering to prevent writer starvation
- New readers wait if writer is waiting
- Writer proceeds once active readers finish
- Prevents continuous stream of readers from blocking writer indefinitely

### Write Transaction Locks

**Exclusive Lock**: Acquire exclusive write lock on database
- Only one writer can hold exclusive lock
- Blocks all new readers and writers
- Waits for active readers to complete
- Implemented via RwLock write lock

**Lock Acquisition Order**:
1. Attempt to acquire exclusive lock
2. Wait for active readers to complete (if any)
3. Wait for any other writer to complete (should be at most one)
4. Once acquired, proceed with mutation buffer initialization
5. Lock held until commit or rollback completes

**Write-Write Coordination**:
- Only one write transaction at a time (by design in V0)
- Exclusive lock ensures serialization
- Future versions may support concurrent writes with conflict detection

## Snapshot Acquisition

### Purpose of Snapshots

**Snapshot Isolation**: Each transaction reads from a consistent database state
- All reads in transaction see same version of data
- Uncommitted changes from other transactions are invisible
- Changes committed after transaction start are invisible
- Enables time-travel queries to historical states

### Snapshot Acquisition for Read Transactions

**Step 1: Determine Snapshot Type**
- **Latest**: Read most recent committed state (begin_read_latest)
- **Historical**: Read state at specific transaction ID (begin_read_at)

**Step 2: Capture Snapshot Identity**
- For latest: Read current_txn_id from database meta page
- For historical: Use provided txn_id parameter
- Read root_page_id from snapshot registry for this txn_id
- Snapshot registry is B+tree mapping txn_id → root_page_id

**Step 3: Create Snapshot State**
- For file-based databases: root_page_id identifies B+tree root
- For in-memory databases: Copy entire key-value map to snapshot
- Snapshot is immutable after creation
- All reads use this snapshot for consistency

**Step 4: Validate Snapshot**
- Ensure txn_id exists in snapshot registry
- For historical reads, txn_id must be <= current committed txn_id
- Return error if snapshot not found

### Snapshot Acquisition for Write Transactions

**Simpler Process**: Write transactions always use latest snapshot
- Read current_txn_id from database meta page
- This becomes the transaction's base snapshot
- Mutations are layered on top of this snapshot
- Read-your-writes: Transaction sees its own mutations via pending_ops

**No Snapshot Registry Entry**: Until commit
- Write transaction does NOT register snapshot during begin
- Snapshot is registered during commit after WAL write
- This ensures only committed transactions create snapshots
- Prevents uncommitted state from being visible

**Visibility Calculation**:
- Reads check pending_ops first (own mutations)
- Then check B+tree at base snapshot
- Mutations from other transactions are invisible (exclusive lock)

## Transaction Registration

### Active Transaction Registry

**Description**: Tracks all currently active transactions

**Purpose**:
- Cleanup on database close
- Debugging and monitoring
- Future: Detect long-running transactions
- Future: Implement transaction timeouts

**Storage**: HashSet or Vec of active transaction IDs

**Registration**:
- During begin, add txn_id to active registry
- Use atomic operation or lock for thread-safety
- Store transaction start timestamp for monitoring

**Unregistration**:
- During commit or close, remove txn_id from registry
- During rollback, remove txn_id from registry
- Ensures registry only contains live transactions

**Concurrency**:
- Registry protected by mutex or lock
- Fast path: check if transaction is still active
- Updates on begin and end (infrequent compared to reads)

### Resource Tracking

**Read Transactions**:
- Track minimal metadata (txn_id, start time)
- No page allocation or mutation tracking
- Cleaned up on close or drop

**Write Transactions**:
- Track mutation buffer (pending_ops)
- Track allocated pages for rollback
- Track modified pages with before-images
- All resources freed on commit or rollback

## Begin Operation Algorithms

### begin_read_latest() - Read Latest Committed State

**Purpose**: Create read transaction at most recent committed snapshot

**Algorithm**:
1. Acquire shared lock on database (blocking if writer active)
2. Allocate next TransactionId from global counter
3. Read current committed txn_id from meta page
4. Look up root_page_id from snapshot registry for current txn_id
5. Create SnapshotState (empty for file-based, full copy for in-memory)
6. Initialize ReadTxn with:
   - txn_id (allocated ID)
   - root_page_id (from registry)
   - snapshot (captured state)
   - db reference (borrowed)
   - state = Active
7. Register txn_id in active transaction registry
8. Return ReadTxn handle

**Error Conditions**:
- SnapshotNotFound: Current txn_id not in registry (corruption)
- AllocationFailed: Out of memory for ReadTxn or snapshot

**Complexity**: O(1) - constant time operations

### begin_read_at(txn_id) - Read Historical State

**Purpose**: Create read transaction at specific historical snapshot

**Algorithm**:
1. Validate txn_id parameter (must be > 0 and <= current committed txn_id)
2. Acquire shared lock on database
3. Look up root_page_id from snapshot registry for provided txn_id
4. If not found, return SnapshotNotFound error
5. Create SnapshotState for historical txn_id
6. Initialize ReadTxn with historical snapshot
7. Register txn_id in active transaction registry
8. Return ReadTxn handle

**Error Conditions**:
- SnapshotNotFound: Provided txn_id not in registry
- InvalidTxnId: txn_id is 0 or > current committed txn_id

**Use Cases**:
- Time-travel queries (as-of queries)
- Auditing and forensic analysis
- Replication and catch-up
- Backup and restore verification

### begin_write() - Begin Read-Write Transaction

**Purpose**: Create write transaction with mutation tracking

**Algorithm**:
1. Acquire exclusive lock on database (blocking until readers finish)
2. Allocate next TransactionId from global counter
3. Read current committed txn_id from meta page (base snapshot)
4. Initialize empty TransactionContext with:
   - txn_id (allocated ID)
   - parent_txn_id = 0 (no nesting in V0)
   - state = Active
   - mutations = empty Vec
   - allocated_pages = empty Vec
   - modified_pages = empty HashMap
   - start_timestamp_ns = current time
   - commit_lsn = None
5. Initialize empty pending_ops mutation buffer (HashMap or LRU cache)
6. Register txn_id in active transaction registry
7. Initialize WriteTxn with:
   - db reference (borrowed)
   - context (TransactionContext)
   - pending_ops (mutation buffer)
   - snapshot (base snapshot)
   - txn_id (allocated ID)
   - state = Active
   - metrics (empty)
8. Return WriteTxn handle

**Error Conditions**:
- AllocationFailed: Out of memory for TransactionContext or mutation buffer
- ConcurrentWriteLimit: Future: limit concurrent write transactions

**Complexity**: O(1) - constant time initialization

## State Initialization

### Initial State: Active

**Description**: Transaction begins in Active state, ready for operations

**Valid Operations in Active State**:
- Read transactions: get(), scan(), iterator(), close()
- Write transactions: get(), put(), delete(), prepare(), rollback()

**State Transitions from Active**:
- Read: Active → Closed (on close)
- Write: Active → Preparing (on prepare), Active → Aborted (on rollback)

**Invariants**:
- txn_id is allocated and unique
- Snapshot is captured and immutable
- For writes: pending_ops is empty, can accept mutations
- Transaction is registered in active registry

### Field Initialization Values

**Common Fields (ReadTxn and WriteTxn)**:
- txn_id: Allocated from global counter
- root_page_id: From snapshot registry (0 for in-memory)
- snapshot: Captured at begin (empty for writes, populated for reads)
- db: Borrowed reference to database
- state: TransactionState::Active
- start_timestamp_ns: Current system time

**WriteTxn-Specific Fields**:
- parent_txn_id: 0 (no nesting in V0)
- mutations: Empty Vec
- mutation_count: 0
- allocated_pages: Empty Vec
- modified_pages: Empty HashMap
- commit_lsn: None
- pending_ops: Empty mutation buffer

## Error Conditions

### Lock Acquisition Errors

**WouldBlock**: Lock acquisition would block (if using try_lock variant)
- When: Another transaction holds conflicting lock
- Effect: begin() returns error or blocks (depending on variant)
- Recovery: Retry begin operation, wait for current transaction to complete

**LockTimeout**: Lock acquisition timed out (future feature with timeout)
- When: Lock held for longer than timeout threshold
- Effect: begin() returns error
- Recovery: Retry or investigate long-running transaction

### Snapshot Errors

**SnapshotNotFound**: Requested snapshot does not exist
- When: begin_read_at() called with invalid txn_id, or snapshot registry corrupted
- Effect: begin() returns error
- Recovery: Use valid txn_id, check snapshot registry integrity

**InvalidTxnId**: Transaction ID parameter is invalid
- When: txn_id is 0 or greater than current committed txn_id
- Effect: begin_read_at() returns error
- Recovery: Use valid txn_id within valid range

### Allocation Errors

**AllocationFailed**: Memory allocation failed
- When: Out of memory during transaction context allocation
- Effect: begin() returns error
- Recovery: Free memory, close other transactions, retry

### Resource Limit Errors

**TooManyActiveTransactions**: Too many concurrent transactions (future limit)
- When: Active transaction registry exceeds configured limit
- Effect: begin() returns error
- Recovery: Wait for existing transactions to complete, increase limit

**WriteTransactionInProgress**: Another write transaction is active
- When: begin_write() called while another write transaction is active
- Effect: begin_write() blocks or returns error (depending on implementation)
- Recovery: Wait for active write transaction to commit or rollback

## Performance Considerations

### Fast Begin Path

**Design Principle**: Minimize work during begin, defer to commit
- Allocate ID with atomic increment (single instruction)
- Capture snapshot with single registry lookup
- Initialize empty data structures (no allocation beyond initial capacity)
- Register transaction (hash set insertion)

**Target Latency**: < 1 microsecond for in-memory begin
- Atomic increment: ~10-50ns
- Snapshot lookup: ~50-100ns
- Lock acquisition: variable, should be uncontended
- Data structure init: ~100-200ns

### Lock Contention

**Read Transactions**: Minimal contention with RwLock
- Shared lock acquisition is fast
- Multiple readers proceed concurrently
- Only block on writer (infrequent in read-heavy workloads)

**Write Transactions**: Can block on active readers
- Exclusive lock waits for all readers to complete
- Long-running readers delay writer start
- Mitigation: Use read timeouts, fair lock ordering

### Memory Allocation

**Pre-allocation Strategy**: Allocate with capacity for expected operations
- mutations Vec: Pre-allocate capacity for 10-100 operations
- pending_ops HashMap: Pre-allocate for expected number of keys
- Reduces reallocations during transaction

**Allocation Timing**:
- All allocations during begin (predictable)
- No allocations during hot path operations (put/get)
- Exceptions: Key/value copies for mutations (unavoidable)

### Snapshot Capture Optimization

**File-Based Databases**: Zero-copy snapshot capture
- Only capture root_page_id (single u64)
- No data copying
- B+tree pages are immutable for snapshot duration
- Page cache provides fast access

**In-Memory Databases**: Full snapshot copy (expensive)
- Must copy entire key-value map
- Use Arc/clone-on-write for optimization
- Consider reference counting for large snapshots
- Future: Implement copy-on-write at key-value level

## Concurrency and Thread Safety

### Thread Safety of Begin Operations

**ReadTxn Begin**: Thread-safe with RwLock
- Multiple threads can call begin_read_latest concurrently
- Shared lock allows concurrent readers
- Registry updates protected by separate mutex

**WriteTxn Begin**: Thread-safe with exclusive lock
- Only one thread can be in begin_write at a time
- Exclusive lock serializes write transactions
- Future: May allow concurrent writes with conflict detection

### Transaction ID Allocation

**Atomic Counter**: Lock-free ID allocation
- Use atomic fetch_and_add for thread-safe increment
- No locks needed for ID allocation
- High throughput even with many concurrent begins

**Meta Page Write**: Can be deferred
- Not necessary to persist counter on every begin
- Write during checkpoint for durability
- Counter reloaded from meta page on restart

### Registry Updates

**Mutex Protected**: Active transaction registry
- Insert and remove operations protected by mutex
- Fast path: check if txn is active (read-only)
- Updates infrequent (begin/end) compared to reads

## Invariants

### Transaction ID Invariants

- **Uniqueness**: No two active transactions have same txn_id
- **Monotonic**: txn_id values increase over time
- **Non-Zero**: Valid txn_id values are >= 1
- **Persistence**: Counter survives process restart

### Lock Invariants

- **Read Shared**: Multiple readers can hold shared lock
- **Write Exclusive**: Only one writer at a time
- **Fairness**: FIFO ordering prevents starvation
- **Scope**: Lock held from begin to close/commit/rollback

### Snapshot Invariants

- **Immutability**: Snapshot never changes after begin
- **Consistency**: All reads use same snapshot within transaction
- **Validity**: Snapshot txn_id exists in registry
- **Visibility**: Uncommitted changes from other txns invisible

### State Invariants

- **Initial State**: Transaction always starts in Active state
- **State Transitions**: Only follow valid state machine
- **Terminal States**: Committed and Aborted are terminal
- **One-shot**: Cannot reuse transaction after close/commit/rollback

### Registry Invariants

- **Liveness**: All active transactions registered
- **Uniqueness**: No duplicate txn_id in registry
- **Cleanup**: Transactions removed on close/commit/rollback
- **Consistency**: Registry matches actual active transactions

## Dependencies

- **Uses**:
  - TransactionId type (identifier)
  - TransactionState type (lifecycle)
  - PageId type (snapshot root)
  - SnapshotRegistry (snapshot management)
  - Lock primitives (RwLock, Mutex)
  - Atomic operations (ID allocation)
  - Error types module (error handling)

- **Used By**:
  - Db::begin_read_latest() API
  - Db::begin_read_at() API
  - Db::begin_write() API
  - ReadTxn constructor
  - WriteTxn constructor
  - Transaction tests (fixture setup)

## Rust Implementation Guidance

### Module Structure

```rust
// northstar_core::txn
impl Db {
    pub fn begin_read_latest(&self) -> Result<ReadTxn, Error>;
    pub fn begin_read_at(&self, txn_id: TransactionId) -> Result<ReadTxn, Error>;
    pub fn begin_write(&self) -> Result<WriteTxn, Error>;
}

impl ReadTxn {
    fn new(db: &Db, txn_id: TransactionId, root_page_id: PageId) -> Self;
}

impl WriteTxn {
    fn new(db: &Db, txn_id: TransactionId) -> Self;
}
```

### Type Definitions

**TransactionId Counter**:
```rust
use std::sync::atomic::{AtomicU64, Ordering};

pub struct TxnIdAllocator {
    next_id: AtomicU64,
}

impl TxnIdAllocator {
    pub fn new(initial: u64) -> Self {
        Self {
            next_id: AtomicU64::new(initial),
        }
    }

    pub fn allocate(&self) -> TransactionId {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        TransactionId::new(id)
    }

    pub fn current(&self) -> TransactionId {
        TransactionId::new(self.next_id.load(Ordering::SeqCst))
    }
}
```

### Lock Strategy

**RwLock for Database Access**:
```rust
use std::sync::RwLock;

pub struct Db {
    lock: RwLock<()>,
    // ... other fields
}

impl Db {
    pub fn begin_read_latest(&self) -> Result<ReadTxn, Error> {
        let _lock = self.lock.read().unwrap(); // Shared lock
        // ... proceed with read transaction begin
    }

    pub fn begin_write(&self) -> Result<WriteTxn, Error> {
        let _lock = self.lock.write().unwrap(); // Exclusive lock
        // ... proceed with write transaction begin
    }
}
```

**Fair RwLock**: Use fair lock variant if available
- Prevents writer starvation
- New readers wait if writer is waiting
- Consider parking_lot::RwLock for fair scheduling

### TransactionID Allocation

**Atomic Operations**:
```rust
pub struct Db {
    txn_id_allocator: TxnIdAllocator,
    // ... other fields
}

impl Db {
    fn begin_read_latest(&self) -> Result<ReadTxn, Error> {
        let txn_id = self.txn_id_allocator.allocate();
        // ... rest of begin logic
    }
}
```

**Persistance**: Write to meta page during checkpoint
```rust
impl Db {
    fn checkpoint(&mut self) -> Result<(), Error> {
        // Write current txn_id counter to meta page
        let current_txn_id = self.txn_id_allocator.current();
        self.meta_page.set_current_txn_id(current_txn_id);
        self.pager.write_meta_page(&self.meta_page)?;
        Ok(())
    }
}
```

### Snapshot Registry

**Snapshot Registry Structure**:
```rust
use std::collections::HashMap;
use std::sync::RwLock;

pub struct SnapshotRegistry {
    snapshots: RwLock<HashMap<TransactionId, PageId>>,
    current_txn_id: RwLock<TransactionId>,
}

impl SnapshotRegistry {
    pub fn register(&self, txn_id: TransactionId, root_page_id: PageId) {
        let mut snapshots = self.snapshots.write().unwrap();
        snapshots.insert(txn_id, root_page_id);
        *self.current_txn_id.write().unwrap() = txn_id;
    }

    pub fn get(&self, txn_id: TransactionId) -> Option<PageId> {
        let snapshots = self.snapshots.read().unwrap();
        snapshots.get(&txn_id).copied()
    }

    pub fn get_current(&self) -> TransactionId {
        *self.current_txn_id.read().unwrap()
    }
}
```

### Active Transaction Registry

**Registry Structure**:
```rust
use std::sync::{Arc, Mutex};
use std::collections::HashSet;

pub struct ActiveTxnRegistry {
    active: Mutex<HashSet<TransactionId>>,
}

impl ActiveTxnRegistry {
    pub fn register(&self, txn_id: TransactionId) {
        let mut active = self.active.lock().unwrap();
        active.insert(txn_id);
    }

    pub fn unregister(&self, txn_id: TransactionId) {
        let mut active = self.active.lock().unwrap();
        active.remove(&txn_id);
    }

    pub fn is_active(&self, txn_id: TransactionId) -> bool {
        let active = self.active.lock().unwrap();
        active.contains(&txn_id)
    }
}
```

### ReadTxn Construction

**Constructor**:
```rust
impl Db {
    pub fn begin_read_latest(&self) -> Result<ReadTxn, Error> {
        // Acquire shared lock
        let _lock = self.lock.read().unwrap();

        // Allocate txn_id
        let txn_id = self.txn_id_allocator.allocate();

        // Get snapshot
        let current_txn_id = self.snapshot_registry.get_current();
        let root_page_id = self.snapshot_registry
            .get(current_txn_id)
            .ok_or(Error::SnapshotNotFound)?;

        // Create ReadTxn
        let txn = ReadTxn::new(self, txn_id, root_page_id);

        // Register
        self.active_registry.register(txn_id);

        Ok(txn)
    }

    pub fn begin_read_at(&self, txn_id: TransactionId) -> Result<ReadTxn, Error> {
        // Validate txn_id
        if txn_id.as_u64() == 0 {
            return Err(Error::InvalidTxnId);
        }

        // Acquire shared lock
        let _lock = self.lock.read().unwrap();

        // Get snapshot
        let root_page_id = self.snapshot_registry
            .get(txn_id)
            .ok_or(Error::SnapshotNotFound)?;

        // Create ReadTxn with historical snapshot
        let txn = ReadTxn::new(self, txn_id, root_page_id);

        // Register
        self.active_registry.register(txn_id);

        Ok(txn)
    }
}
```

### WriteTxn Construction

**Constructor**:
```rust
impl Db {
    pub fn begin_write(&self) -> Result<WriteTxn, Error> {
        // Acquire exclusive lock
        let _lock = self.lock.write().unwrap();

        // Allocate txn_id
        let txn_id = self.txn_id_allocator.allocate();

        // Get base snapshot (current committed state)
        let current_txn_id = self.snapshot_registry.get_current();
        let root_page_id = self.snapshot_registry
            .get(current_txn_id)
            .ok_or(Error::SnapshotNotFound)?;

        // Create TransactionContext
        let context = TransactionContext::new(txn_id);

        // Create pending_ops buffer
        let pending_ops = HashMap::new(); // or LRU cache

        // Create WriteTxn
        let txn = WriteTxn::new(self, context, pending_ops, txn_id, root_page_id);

        // Register
        self.active_registry.register(txn_id);

        Ok(txn)
    }
}
```

### Pre-allocation Strategy

**Capacity Hints**:
```rust
impl TransactionContext {
    pub fn with_capacity(txn_id: TransactionId, capacity: usize) -> Self {
        Self {
            txn_id,
            parent_txn_id: TransactionId::INITIAL,
            state: TransactionState::Active,
            mutations: Vec::with_capacity(capacity),
            mutation_count: 0,
            allocated_pages: Vec::with_capacity(16),
            modified_pages: HashMap::with_capacity(16),
            start_timestamp_ns: get_timestamp_ns(),
            commit_lsn: None,
        }
    }
}
```

### Error Handling

**Comprehensive Error Types**:
```rust
pub enum Error {
    // Lock errors
    LockTimeout,
    WouldBlock,

    // Snapshot errors
    SnapshotNotFound,
    InvalidTxnId,

    // Resource errors
    AllocationFailed,
    TooManyActiveTransactions,
    WriteTransactionInProgress,

    // ... other errors
}
```

### Key Decisions

**Lock Type**: RwLock vs Mutex
- Use RwLock for database access (multiple readers, single writer)
- Use Mutex for registries and internal state
- Consider parking_lot for performance and fair locks

**Atomic Ordering**: SeqCst vs Acquire/Release
- Use SeqCst for txn_id allocation (simpler, safer)
- Use Acquire/Release for other atomics if needed for performance
- Prefer correctness over premature optimization

**Lock Granularity**: Database-level vs table-level
- V0: Database-level lock (simpler)
- Future: Table-level or key-level locks for more concurrency
- Trade-off: Complexity vs concurrency

**Fairness**: Fair RwLock vs unfair
- Use fair RwLock to prevent writer starvation
- Small performance penalty acceptable for correctness
- Consider both options with configuration

### Testing Strategy

**Unit tests needed for**:
- begin_read_latest() creates valid ReadTxn
- begin_read_at() creates ReadTxn at correct snapshot
- begin_read_at() returns error for invalid txn_id
- begin_write() creates valid WriteTxn
- Transaction ID allocation is monotonic
- Transaction IDs are unique
- Snapshot registry lookup succeeds for valid txn_id
- Snapshot registry lookup fails for invalid txn_id
- Active registry contains transaction after begin
- Active registry does not contain transaction after close

**Property tests for**:
- Transaction ID uniqueness across concurrent begins
- Transaction ID monotonic increase
- begin_read_latest() snapshot equals current committed txn_id
- Multiple readers can proceed concurrently
- Only one writer can proceed at a time
- Writer waits for active readers

**Integration scenarios**:
- Read transaction sees consistent snapshot across multiple reads
- Read transaction does not see uncommitted changes
- Write transaction can begin after readers complete
- Write transaction blocks new readers
- Multiple sequential transactions get increasing IDs
- Transaction begin survives database restart (counter persisted)
- begin_read_at() reads historical state correctly
