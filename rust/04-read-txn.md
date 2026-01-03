# ReadTxn

## Purpose

ReadTxn is the read-only transaction interface for NorthstarDB, providing consistent snapshot reads with concurrent access support. ReadTxn captures a database snapshot at transaction start, ensures all reads see a consistent view, and allows multiple readers to proceed concurrently without blocking each other. ReadTxn provides point lookups, range scans, and prefix iteration while maintaining snapshot isolation guarantees.

## Core Structure

### ReadTxn

**Description**: Read-only transaction handle that provides access to a consistent snapshot of the database

**Lifetime**: From transaction begin until explicit close or scope end

**Ownership**: ReadTxn borrows the database (holds reference) and owns its snapshot state

**Thread Safety**: ReadTxn is Send + Sync (can be safely shared across threads for reads)

## Fields

### Snapshot Identity

#### txn_id: TransactionId

**Type**: TransactionId (newtype wrapper around u64)

**Purpose**: Unique identifier for the snapshot this transaction is reading from

**Assignment**: Assigned at transaction begin from database's committed transaction ID

**Usage**:
- MVCC visibility calculations
- Snapshot identification in registry
- Distinguishing between different transaction snapshots
- Debugging and logging

**Invariants**:
- txn_id corresponds to a committed transaction state
- txn_id never changes during transaction lifetime
- All reads use this txn_id for visibility
- txn_id <= database's current committed transaction ID

#### root_page_id: PageId

**Type**: PageId (newtype wrapper around u64)

**Purpose**: B+tree root page ID for this snapshot (file-based databases only)

**Assignment**: Retrieved from snapshot registry at transaction begin

**Usage**:
- File-based databases: Identifies B+tree root for snapshot
- In-memory databases: Set to 0 (not used)
- Ensures reads use correct B+tree version

**Invariants**:
- root_page_id corresponds to txn_id in snapshot registry
- root_page_id identifies a valid B+tree root
- For in-memory databases, root_page_id is 0
- All B+tree reads use this root_page_id

### Snapshot State

#### snapshot: SnapshotState

**Type**: SnapshotState (in-memory snapshot representation)

**Purpose**: In-memory copy of database state at txn_id (for in-memory databases)

**Assignment**: Created from reference model at transaction begin

**Usage**:
- In-memory databases: Contains all key-value pairs
- File-based databases: Empty (data is in B+tree)
- Provides read operations for in-memory mode

**Invariants**:
- snapshot contains state as of txn_id
- For file-based databases, snapshot is empty placeholder
- snapshot is immutable (read-only)
- snapshot is cleaned up on close/drop

#### db: &Db

**Type**: Reference to database handle

**Purpose**: Reference to parent database for operations

**Lifetime**: Must outlive ReadTxn

**Usage**:
- Access to pager for B+tree reads
- Access to snapshot registry
- Resource management

**Invariants**:
- db reference remains valid for ReadTxn lifetime
- ReadTxn does not modify db through this reference
- Multiple ReadTxn can hold concurrent references

### Allocator

#### allocator: Allocator

**Type**: Memory allocator (Zig-specific, Rust uses standard allocator)

**Purpose**: Memory allocator for read transaction allocations

**Usage**:
- Allocate value copies for get() operations
- Allocate buffers for range scans
- Allocate iterator state
- All ReadTxn memory comes from this allocator

**Invariants**:
- allocator is provided at transaction creation
- All allocations use this allocator consistently
- allocator outlives the ReadTxn
- On drop, all allocated memory is freed to this allocator

## Read-Only Guarantees

### No Modification

**Immutable State**: ReadTxn cannot modify the database
- No put, delete, or other mutation operations
- Cannot begin nested write transactions
- Cannot alter snapshot state
- Cannot modify B+tree structure

**Borrow Semantics**: ReadTxn holds shared reference to database
- Multiple readers can hold concurrent references
- Writer cannot modify while readers hold references
- ReadTxn does not acquire exclusive locks
- Reads proceed without blocking other readers

### Snapshot Isolation

**Consistent Snapshot**: All reads see database as of txn_id
- Reads do not see uncommitted changes from active writers
- Reads do not see changes from transactions after txn_id
- Multiple reads in same transaction see same data
- No phantom reads (range scan results stable)

**Time Travel**: Can read historical database states
- beginReadAt(txn_id) reads specific historical state
- beginReadLatest() reads most recent committed state
- Old snapshots remain valid until garbage collected
- Supports time-travel queries and auditing

### Concurrency

**Multiple Readers**: Unlimited concurrent read transactions
- No limit on number of concurrent ReadTxn instances
- Readers do not block each other
- Each reader has independent snapshot
- Readers can proceed in parallel across threads

**Writer Coordination**: Readers coordinate with single writer
- New readers wait for active writer to complete commit
- Active readers are not blocked by new writers
- Writer waits for all active readers to complete before committing
- FIFO ordering prevents starvation

## Operations

### Point Lookup

**get(&self, key: &[u8]) -> Option<Value>**

Purpose: Read a single value by key

Parameters:
- key: Key bytes to look up

Algorithm:
- For file-based databases:
  - Use B+tree lookup at root_page_id
  - Traverse B+tree from snapshot root
  - Return value if found, None if not found
- For in-memory databases:
  - Look up key in snapshot state
  - Return value if found, None if not found

Returns: Some(Value) if key exists at snapshot, None if not found

Value Lifetime: Returned value is allocated and owned by caller, must be freed

**Invariants**:
- Returns value as of txn_id snapshot
- Does not see uncommitted changes
- Same key always returns same value within transaction
- Key not found returns None (not an error)

### Range Scan

**scan(&self, prefix: &[u8]) -> Result<Vec<KV>, Error>**

Purpose: Scan all keys with given prefix in sorted order

Parameters:
- prefix: Key prefix to match

Algorithm:
- For file-based databases:
  - Create B+tree range iterator [prefix, prefix + 1)
  - Iterate over all matching keys
  - Allocate and return vector of key-value pairs
- For in-memory databases:
  - Iterate over snapshot state
  - Filter keys starting with prefix
  - Sort results and return vector

Returns: Vector of key-value pairs in sorted order

Memory: Caller owns returned vector, must free all key-value pairs

**Invariants**:
- All returned keys start with prefix
- Results are in sorted key order
- All values are as of txn_id snapshot
- Empty vector if no keys match prefix

### Iteration

**iterator(&self) -> Result<ReadIterator, Error>**

Purpose: Create iterator over all key-value pairs in database

Returns: Iterator that yields all keys in sorted order

**Invariants**:
- Iterator yields all keys as of txn_id snapshot
- Results are in sorted key order
- Iterator is valid for ReadTxn lifetime
- Iterator does not hold exclusive locks

**iterator_range(&self, start: Option<&[u8]>, end: Option<&[u8]>) -> Result<ReadIterator, Error>**

Purpose: Create iterator over key range [start, end)

Parameters:
- start: Inclusive start key (None = beginning)
- end: Exclusive end key (None = end of database)

Returns: Iterator that yields keys in range, sorted

**Invariants**:
- Iterator yields keys in [start, end) range
- Results are in sorted key order
- Iterator is valid for ReadTxn lifetime
- Empty range yields no results

### Lifecycle

**close(self)**

Purpose: Explicitly close transaction and release resources

Effects:
- Frees snapshot state
- Releases any held locks
- Frees allocated memory
- Invalidates ReadTxn for further use

**Invariants**:
- close() is idempotent (safe to call multiple times)
- Cannot use ReadTxn after close
- Resources freed even if close not called (drop cleanup)

## Trait Bounds

### Send

**Required**: ReadTxn must implement Send

**Purpose**: Allow ReadTxn to be transferred across threads

**Safety**:
- All internal data is thread-safe for transfer
- No borrowed data from thread-local storage
- Proper ownership semantics

**Usage**:
- Can send ReadTxn to another thread
- Supports parallel read operations
- Enables work stealing for read queries

**Implementation**:
```rust
// ReadTxn is Send because:
// - txn_id and root_page_id are Copy (u64)
// - snapshot owns its data (no borrowed references)
// - db reference lifetime is tracked
// - allocator is Send or thread-local
```

### Sync

**Required**: ReadTxn must implement Sync

**Purpose**: Allow &ReadTxn to be shared across threads

**Safety**:
- All reads are immutable (no interior mutation)
- No concurrent modification of shared state
- Proper synchronization for any shared mutable state

**Usage**:
- Can share &ReadTxn between threads
- Multiple threads can read from same ReadTxn
- Enables parallel query execution

**Implementation**:
```rust
// ReadTxn is Sync because:
// - get() and scan() take &self (immutable reference)
// - No internal mutable state
// - B+tree reads are thread-safe (snapshot isolation)
// - SnapshotState is immutable
```

**Note**: For Zig, these semantics are achieved through proper const qualifiers and explicit thread safety

## State Machine

### States

**Active**: Transaction is open and accepting read operations
- get(), scan(), iterator() operations valid
- close() transitions to closed state

**Closed**: Transaction has been explicitly closed or dropped
- No operations valid
- Terminal state

### State Transitions

```
    begin()
       |
       v
  [Active] ────── get() / scan() / iterator()
       |
       | close()
       v
  [Closed]
```

**Valid Transitions**:
- Active → Closed (on close() call or drop)

**Invalid Operations**:
- Any operation in Closed state
- Begin new transaction without closing old one

## Memory Management

### Value Allocation

**Owned Values**: get() returns allocated values
- Value bytes copied from B+tree or snapshot
- Caller owns returned value and must free
- Allows ReadTxn to be dropped while value still valid

**Rust Equivalent**: Returns Vec<u8> (owned)

### Scan Results

**Vector Allocation**: scan() returns owned vector
- All key-value pairs allocated and owned
- Caller must free entire vector
- Each key and value individually allocated

**Rust Equivalent**: Returns Vec<(Vec<u8>, Vec<u8>)>

### Iterator State

**Iterator Ownership**: Iterator borrows from ReadTxn
- Iterator holds reference to ReadTxn
- Iterator lifetime <= ReadTxn lifetime
- No additional allocation for iterator creation

### Cleanup

**On Close**:
- Snapshot state freed
- No locks to release (read-only)
- Allocator can reclaim memory

**On Drop**:
- Same cleanup as close
- Automatic resource cleanup
- No memory leaks

## Invariants

### State Invariants

- **Active State**: Only get(), scan(), iterator() valid in Active state
- **Closed State**: No operations valid after close
- **Snapshot Consistency**: All reads use same txn_id and root_page_id

### Identity Invariants

- **Immutable txn_id**: txn_id never changes
- **Immutable root_page_id**: root_page_id never changes
- **Valid Snapshot**: txn_id and root_page_id correspond to valid snapshot

### Read-Only Invariants

- **No Modifications**: ReadTxn cannot modify database
- **No Mutations**: No put, delete, or other write operations
- **Immutable Snapshot**: snapshot state never changes

### Concurrency Invariants

- **Thread Safety**: Multiple threads can read concurrently
- **Send + Sync**: Can be shared and transferred across threads
- **No Blocking**: Readers don't block other readers

## Error Conditions

### Snapshot Errors

**SnapshotNotFound**: Requested txn_id does not exist
- When: beginReadAt() called with invalid txn_id
- Effect: beginReadAt() returns error
- Recovery: Use valid txn_id or beginReadLatest()

### Iterator Errors

**InMemoryIteratorNotSupported**: Iterator not available for in-memory databases
- When: iterator() called on in-memory database
- Effect: iterator() returns error
- Recovery: Use scan() method instead

### Allocation Errors

**AllocationFailed**: Memory allocation failed
- When: Out of memory during value copy or scan
- Effect: Operation returns error
- Recovery: Free memory and retry, or use smaller queries

### B+Tree Errors

**CorruptBtree**: B+tree structure corrupted
- When: Page checksum fails or structure invalid
- Effect: get() or scan() returns error
- Recovery: Restore from backup or run recovery

**BufferTooSmall**: Value buffer too small for result
- When: Value size exceeds allocated buffer
- Effect: get() returns error
- Recovery: Use larger buffer

## Relationships to Other Types

### ReadTxn vs WriteTxn

**Complementarity**: Two transaction types for different purposes
- ReadTxn: Read-only, shared access, snapshot isolation
- WriteTxn: Read-write, exclusive access, two-phase commit

**Coordination**:
- Only one WriteTxn at a time
- Unlimited ReadTxn concurrent with each other
- WriteTxn waits for active ReadTxn to complete before committing

### ReadTxn vs Db

**Creation**: Db creates ReadTxn instances
- Db.beginReadLatest() creates ReadTxn at latest snapshot
- Db.beginReadAt(txn_id) creates ReadTxn at specific snapshot
- Db manages snapshot registry for ReadTxn

**Lifetime**: ReadTxn borrows from Db
- Db must outlive ReadTxn
- Multiple ReadTxn can borrow from same Db
- ReadTxn holds &Db reference

### ReadTxn vs SnapshotState

**Composition**: ReadTxn contains SnapshotState
- For in-memory databases: SnapshotState contains all data
- For file-based databases: SnapshotState is empty placeholder
- SnapshotState provides read operations

### ReadTxn vs B+Tree

**Access**: ReadTxn reads from B+tree for file-based databases
- Uses root_page_id to identify snapshot's B+tree root
- Traverses B+tree for point lookups and range scans
- B+tree structure not modified by reads

## Public API

### Creation

**Db.begin_read_latest(&self) -> Result<ReadTxn, Error>**

Purpose: Create read transaction at latest committed snapshot

Returns: ReadTxn reading from most recent committed transaction

**Db.begin_read_at(&self, txn_id: TransactionId) -> Result<ReadTxn, Error>**

Purpose: Create read transaction at specific historical snapshot

Parameters:
- txn_id: Historical transaction ID to read from

Returns: ReadTxn reading from specified snapshot

Error: Returns SnapshotNotFound if txn_id invalid

### Read Operations

**get(&self, key: &[u8]) -> Option<Value>**

Purpose: Get value for key from snapshot

Returns: Some(value) if key exists, None if not found

**scan(&self, prefix: &[u8]) -> Result<Vec<KV>, Error>**

Purpose: Scan all keys with prefix

Returns: Vector of key-value pairs in sorted order

**iterator(&self) -> Result<ReadIterator, Error>**

Purpose: Create iterator over all keys

Returns: Iterator yielding all key-value pairs

**iterator_range(&self, start: Option<&[u8]>, end: Option<&[u8]>) -> Result<ReadIterator, Error>**

Purpose: Create iterator over key range

Returns: Iterator yielding key-value pairs in range

### Cleanup

**close(self)**

Purpose: Close transaction and release resources

## Rust Implementation Guidance

### Module Structure

```rust
// northstar_core::txn
pub struct ReadTxn<'a> {
    txn_id: TransactionId,
    root_page_id: PageId,
    snapshot: SnapshotState,
    db: &'a Db,
    allocator: Allocator,  // Rust uses standard allocator
}

impl<'a> ReadTxn<'a> {
    // methods...
}
```

### Type Definition

**Basic Structure**:
```rust
use crate::types::{TransactionId, PageId};
use crate::ref_model::SnapshotState;

pub struct ReadTxn<'a> {
    // Identity
    pub txn_id: TransactionId,
    pub root_page_id: PageId,

    // Snapshot state
    pub snapshot: SnapshotState,

    // Database reference
    pub db: &'a Db,
}
```

### Constructor

**From Db**:
```rust
impl Db {
    pub fn begin_read_latest(&self) -> Result<ReadTxn, Error> {
        let txn_id = self.get_current_txn_id();
        let root_page_id = self.snapshot_registry.get_latest_root();

        ReadTxn {
            txn_id,
            root_page_id,
            snapshot: SnapshotState::in_memory_empty(), // or actual state
            db: self,
        }
    }

    pub fn begin_read_at(&self, txn_id: TransactionId) -> Result<ReadTxn, Error> {
        let root_page_id = self.snapshot_registry.get_root(txn_id)
            .ok_or(Error::SnapshotNotFound)?;

        ReadTxn {
            txn_id,
            root_page_id,
            snapshot: SnapshotState::in_memory_empty(),
            db: self,
        }
    }
}
```

### Read Operations

**Point Lookup**:
```rust
impl<'a> ReadTxn<'a> {
    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, Error> {
        // For file-based databases
        if let Some(pager) = &self.db.pager {
            return pager.btree_get_at_root(key, self.root_page_id)
                .map(|v| v.map(|vec| vec.clone()));
        }

        // For in-memory databases
        Ok(self.snapshot.get(key).map(|v| v.to_vec()))
    }
}
```

**Range Scan**:
```rust
impl<'a> ReadTxn<'a> {
    pub fn scan(&self, prefix: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>, Error> {
        // For file-based databases
        if let Some(pager) = &self.db.pager {
            let iter = pager.btree_range_iterator(
                self.root_page_id,
                Some(prefix),
                next_prefix(prefix),
            )?;

            let mut results = Vec::new();
            while let Some(kv) = iter.next()? {
                if kv.key.starts_with(prefix) {
                    results.push((kv.key.to_vec(), kv.value.to_vec()));
                }
            }
            return Ok(results);
        }

        // For in-memory databases
        let mut results: Vec<_> = self.snapshot
            .iter()
            .filter(|(k, _)| k.starts_with(prefix))
            .map(|(k, v)| (k.to_vec(), v.to_vec()))
            .collect();
        results.sort_by_key(|(k, _)| k.clone());
        Ok(results)
    }
}
```

### Iterator

**Read Iterator**:
```rust
pub struct ReadIterator<'a, 'b>
where
    'a: 'b,
{
    txn: &'b ReadTxn<'a>,
    btree_iter: Option<BtreeIterator>,
    in_memory_iter: Option<InMemoryIterator>,
}

impl<'a, 'b> Iterator for ReadIterator<'a, 'b> {
    type Item = Result<(&[u8], &[u8]), Error>;

    fn next(&mut self) -> Option<Self::Item> {
        // Implementation based on database type
    }
}
```

### Trait Bounds

**Send and Sync**:
```rust
// Safety: ReadTxn is Send because:
// - txn_id and root_page_id are Copy (u64)
// - snapshot owns its data
// - db reference lifetime tracked

unsafe impl<'a> Send for ReadTxn<'a> {}

// Safety: ReadTxn is Sync because:
// - All operations take &self (immutable reference)
// - No interior mutable state
// - B+tree reads are thread-safe

unsafe impl<'a> Sync for ReadTxn<'a> {}
```

### Drop Implementation

**Resource Cleanup**:
```rust
impl<'a> Drop for ReadTxn<'a> {
    fn drop(&mut self) {
        // Rust automatically drops owned fields:
        // - snapshot dropped
        // - No explicit cleanup needed
        // - Locks released by RwLock drop
    }
}
```

**Close Method**:
```rust
impl<'a> ReadTxn<'a> {
    pub fn close(self) {
        // Explicit close - takes ownership
        // Rust's Drop runs automatically
        // No explicit action needed
    }
}
```

### Clone Behavior

**Not Cloneable**: ReadTxn should NOT implement Clone
- **Reason**: Would create ambiguous ownership and duplicate snapshots
- **Correctness**: Each read transaction should be unique
- **Pattern**: Create new ReadTxn from Db if needed

### Testing Strategy

**Unit tests needed for**:
- begin_read_latest() creates valid ReadTxn
- begin_read_at() creates ReadTxn at correct snapshot
- get() returns correct value for existing key
- get() returns None for non-existent key
- scan() returns all keys with prefix in sorted order
- scan() returns empty vector if no keys match
- iterator() yields all keys in sorted order
- iterator_range() yields keys in range
- close() releases resources
- Multiple concurrent ReadTxn can coexist

**Property tests for**:
- get() returns consistent values across calls
- scan() returns results in sorted order
- scan() results match iteration over same range
- All operations use same snapshot (txn_id)

**Integration scenarios**:
- ReadTxn sees snapshot as of txn_id
- ReadTxn does not see uncommitted changes
- Multiple readers proceed concurrently
- Reader at old txn_id sees historical state
- Reader blocked by writer during commit

## Dependencies

- **Uses**:
  - TransactionId type (identifier)
  - PageId type (B+tree root)
  - SnapshotState type (in-memory snapshot)
  - Db type (database reference)
  - Error types module (error handling)

- **Used By**:
  - Application code (read operations)
  - Query layer (natural language queries)
  - Backup/restore (snapshot exports)
  - Analytics (historical data reads)
