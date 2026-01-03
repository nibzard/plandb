# Snapshot Types

## Purpose

Snapshot types in NorthstarDB enable Multi-Version Concurrency Control (MVCC), allowing concurrent readers to access consistent historical versions of the database while writes proceed. The snapshot system captures the database state at a specific point in time, identified by a transaction ID and root page pointer, providing snapshot isolation guarantees without blocking reads or writes.

## Types

### SnapshotId

**Description**: A newtype wrapper around a TransactionId that represents the transactional context of a snapshot. While similar to TransactionId, SnapshotId provides semantic clarity that this identifier is used for snapshot visibility rather than transaction management.

**Size**: 8 bytes (same as the inner TransactionId/u64)

**Alignment**: 8-byte aligned

**Invariants**:
- Each SnapshotId corresponds to a valid committed transaction
- SnapshotId values are monotonically increasing over time
- SnapshotId 0 represents the initial empty database state
- SnapshotIds are never reused (same guarantee as TransactionId)

### ReadTxn

**Description**: A read-only transaction handle that provides access to a consistent snapshot of the database. ReadTxn captures the database state at a specific transaction ID and root page, allowing reads to proceed without being affected by concurrent writes.

**Fields**:
- **txn_id**: TransactionId identifying the snapshot point
- **root_page_id**: PageId of the B+tree root for this snapshot
- **snapshot**: Internal snapshot state (from reference model or empty for file-based DB)
- **db**: Reference to the parent database
- **allocator**: Memory allocator for snapshot resources

**Invariants**:
- txn_id never changes during the ReadTxn lifetime
- All reads through this ReadTxn see the same consistent state
- ReadTxn cannot be modified (no put/delete operations)
- ReadTxn must be explicitly closed to release resources
- Multiple ReadTxn can exist concurrently without blocking each other

### WriteTxn

**Description**: A read-write transaction handle that allows modifications to the database while tracking changes for atomic commit. WriteTxn buffers mutations and maintains transaction context for two-phase commit.

**Fields**:
- **txn_ctx**: TransactionContext tracking mutations and allocated pages
- **inner**: Reference model write transaction (for in-memory validation)
- **db**: Reference to the parent database
- **txn_id**: TransactionId assigned at transaction begin

**Invariants**:
- Only one WriteTxn can be active at a time per database
- Mutations are buffered until commit
- Transaction has a unique TransactionId allocated at begin
- WriteTxn must be committed or rolled back explicitly
- Resources are released after commit/rollback

### SnapshotRegistry

**Description**: Central registry that maps committed transaction IDs to their root page IDs. Maintains a historical record of snapshots for concurrent readers and enables MVCC visibility calculations.

**Fields**:
- **snapshots**: Map from TransactionId to PageId (root page for each committed transaction)
- **current_txn_id**: Highest committed transaction ID
- **current_root_page_id**: Root page ID of the most recent committed transaction
- **allocator**: Memory allocator for registry data structures

**Invariants**:
- Genesis snapshot (txn_id 0) is always present
- Transaction IDs in snapshots map are unique
- current_txn_id is always the maximum key in snapshots map
- Snapshots are only registered for committed transactions
- Registry is thread-safe for concurrent read access
- Old snapshots can be cleaned up when no readers reference them

### SnapshotState

**Description**: Internal state representing a snapshot view of the reference model. Used for in-memory database validation and testing.

**Fields** (from reference model):
- **txn_id**: Transaction ID for this snapshot
- **read_set**: Set of keys read during this transaction (for conflict detection)
- **write_set**: Set of keys written (buffered mutations)

**Invariants**:
- SnapshotState captures the database at a specific transaction ID
- Read operations check this state before accessing the B+tree
- State is immutable after snapshot creation
- Used primarily for in-memory validation and testing

## Snapshot States

### Transaction Lifecycle States

**Active**: Transaction is currently in progress
- **Description**: Transaction has begun but not yet committed or rolled back
- **For ReadTxn**: Snapshot is being actively used for read operations
- **For WriteTxn**: Mutations are being buffered
- **Visibility**: Changes are not visible to other transactions

**Committed**: Transaction has successfully committed
- **Description**: All mutations have been made durable and visible
- **For ReadTxn**: Snapshot remains valid for historical queries
- **For WriteTxn**: Changes written to WAL and B+tree, snapshot registered
- **Visibility**: Other transactions can see the committed changes

**Aborted**: Transaction has been rolled back
- **Description**: Transaction was cancelled and all changes discarded
- **For ReadTxn**: Snapshot is closed and resources released
- **For WriteTxn**: Buffered mutations are discarded, allocated pages freed
- **Visibility**: No changes are visible to any transaction

## MVCC Snapshot Requirements

### Consistent Reads

**Snapshot Isolation**: Each ReadTxn sees a consistent snapshot of the database
- All reads within a transaction see the same state
- Reads are not affected by concurrent writes
- No phantom reads (same query repeated returns same results)

**Implementation**: Snapshot captures state at transaction begin
- ReadTxn records the txn_id and root_page_id at creation
- All read operations use this root_page_id for B+tree traversal
- Page header txn_id is compared against snapshot txn_id for visibility

### Visibility Rules

**Page Visibility**: A page is visible to a snapshot if:
- Page's txn_id is less than or equal to snapshot's txn_id, AND
- Page was not freed before the snapshot transaction

**Transaction Visibility**: For historical snapshot access:
- Committed transactions with txn_id less than snapshot's txn_id are visible
- In-flight or future transactions are not visible
- Each snapshot reads from its assigned root_page_id

**Write-Your-Own-Reads**: A transaction sees its own uncommitted changes
- Implemented via pending mutations in transaction context
- Checked before B+tree lookup in read path

### Concurrent Readers

**Multiple Snapshots**: Many ReadTxn can exist simultaneously
- Each ReadTxn has its own snapshot state
- Readers do not block each other
- Readers do not block writers
- Writers do not block readers

**Registry Management**: SnapshotRegistry tracks all active snapshots
- Maps txn_id to root_page_id for each committed transaction
- Allows new readers to find appropriate snapshot
- Enables cleanup of old snapshots no longer in use

### LSN Range Tracking

**Log Sequence Numbers**: Snapshots may track LSN boundaries
- **start_lsn**: LSN at which snapshot was created
- **commit_lsn**: LSN at which transaction committed (for committed snapshots)
- **Purpose**: Enables time-travel queries and WAL-based snapshot reconstruction

**Recovery Integration**: After crash, snapshots can be rebuilt from WAL
- Use commit_lsn to find transaction's commit record
- Reconstruct root_page_id from commit record
- Restore snapshot registry state

## Lifetime Parameters

### Why Lifetimes Are Needed

**Borrowed References**: Snapshot types often hold references to parent database
- ReadTxn holds a reference to Db for the duration of the read
- WriteTxn holds a reference to Db during transaction
- These references must be valid for the entire transaction lifetime

**Preventing Use-After-Free**: Lifetimes ensure snapshot outlives its references
- Cannot close Db while ReadTxn is still active
- Cannot drop database while snapshot holds reference
- Compiler enforces correct usage patterns

**Lifetime Example**: In Rust, ReadTxn would have lifetime parameter
- ReadTxn has lifetime 'a tied to the Db reference
- Compiler ensures ReadTxn cannot outlive the Db
- Prevents dangling pointer bugs at compile time

### Lifetime Parameter Examples

**ReadTxn with Lifetime**:
- The snapshot holds a reference with lifetime 'a
- All operations on ReadTxn require 'a to still be valid
- When ReadTxn is closed, the reference is released

**WriteTxn with Lifetime**:
- Similar to ReadTxn but with mutation capability
- Lifetime 'a ensures Db reference remains valid
- Commit consumes the WriteTxn and ends the lifetime

**Self-Referential Patterns**: Some types may avoid lifetimes
- Using indices instead of references (arena allocation)
- Reference counting for shared state (Arc)
- Copying small values instead of borrowing

## Clone vs Copy Semantics

### ReadTxn: Neither Clone Nor Copy

**Not Copy**: ReadTxn cannot implement Copy trait
- **Reason**: ReadTxn manages resources that must be explicitly released
- **Semantic**: Copying would imply two independent transactions sharing state
- **Correctness**: Would lead to double-free or use-after-free bugs

**Not Clone**: ReadTxn should not implement Clone trait
- **Reason**: Cloning would create ambiguous ownership (who closes the transaction?)
- **Alternative**: Provide explicit clone_snapshot() if needed for forked reads
- **Pattern**: Each ReadTxn is a unique handle with exclusive ownership

### WriteTxn: Neither Clone Nor Copy

**Not Copy**: WriteTxn manages mutable state and resources
- **Reason**: Cannot have two writers for the same transaction
- **Semantic**: Transaction identity is tied to a specific handle
- **Correctness**: Copying would create conflicting mutations

**Not Clone**: WriteTxn cannot be safely cloned
- **Reason**: Would create concurrent modification confusion
- **Commit Atomicity**: Only one handle should commit the transaction
- **Pattern**: Single unique writer handle per transaction

### SnapshotId: Copy and Clone

**Copy**: SnapshotId can and should implement Copy trait
- **Reason**: SnapshotId is just a newtype wrapper around TransactionId
- **Semantic**: Copying creates another reference to the same snapshot point
- **Performance**: Zero-cost copy, just copying 8 bytes

**Clone**: Automatically derived from Copy
- **Reason**: Required for generic APIs that use Clone
- **Implementation**: Trivial derived implementation

### SnapshotState: Conditional

**If Holding References**: Not Clone or Copy
- Contains borrowed data with lifetimes
- Cannot be copied without violating lifetime constraints

**If Owning Data**: Can implement Clone
- If state owns its data (Vec, HashMap, etc.)
- Clone creates deep copy of all state
- Useful for snapshot branching or testing

## Functions

### SnapshotRegistry Functions

**register_snapshot(txn_id: TransactionId, root_page_id: PageId)**: Register new committed snapshot
- **Purpose**: Add a new snapshot entry after transaction commit
- **Validation**: Only accept txn_ids greater than current_txn_id
- **Effect**: Updates current_txn_id and current_root_page_id

**get_snapshot_root(txn_id: TransactionId) -> Option<PageId>**: Find root page for snapshot
- **Purpose**: Look up the root page ID for a given transaction
- **Behavior**: If txn_id is newer than current, return current root
- **Returns**: Some(PageId) if snapshot exists, None for invalid txn_id

**get_latest_snapshot() -> PageId**: Get most recent committed snapshot
- **Purpose**: Access the current database state for new readers
- **Returns**: Root page ID of highest committed transaction

**cleanup_old_snapshots(keep_count: usize)**: Remove old snapshots
- **Purpose**: Reclaim memory by removing unreferenced snapshots
- **Behavior**: Keep N most recent snapshots plus genesis (txn_id 0)
- **Safety**: Must ensure no active readers reference removed snapshots

### ReadTxn Functions

**get(key: &[u8]) -> Option<Vec<u8>>**: Read value from snapshot
- **Purpose**: Retrieve value for key at snapshot state
- **Visibility**: Only sees data committed before snapshot txn_id
- **Error Handling**: Returns None if key not found

**close()**: Release snapshot resources
- **Purpose**: Clean up snapshot state and deregister if needed
- **Required**: Must be called to avoid resource leaks
- **Idempotent**: Safe to call multiple times

### WriteTxn Functions

**put(key: &[u8], value: &[u8])**: Buffer a put operation
- **Purpose**: Queue a key-value pair for commit
- **Buffering**: Change not visible until commit
- **Validation**: Key and value must fit within size limits

**delete(key: &[u8])**: Buffer a delete operation
- **Purpose**: Queue key deletion for commit
- **Buffering**: Change not visible until commit
- **Validation**: Key must be valid

**commit() -> Result<(), Error>**: Atomically commit transaction
- **Purpose**: Make all buffered mutations durable and visible
- **Phases**: Write to WAL, update B+tree, register snapshot, update meta
- **Consumes**: WriteTxn handle is consumed and cannot be reused

**rollback()**: Discard all pending changes
- **Purpose**: Cancel transaction and release resources
- **Effect**: Frees allocated pages, discards mutations
- **Idempotent**: Safe to call multiple times

## Invariants

- **Snapshot Consistency**: Each snapshot provides a consistent view of the database
- **No Reader Blocking**: Reads never block writes and vice versa
- **Monotonic Snapshots**: Snapshot IDs strictly increase over time
- **Genesis Snapshot**: Snapshot with txn_id 0 always exists
- **Single Writer**: Only one WriteTxn can be active per database
- **Resource Ownership**: Each transaction handle owns its resources exclusively
- **Visibility Determinism**: Same snapshot always returns same results for same query

## Dependencies

- **Uses**: TransactionId, PageId, error types module
- **Used by**: Transactions (read/write operations), MVCC (visibility), Recovery (snapshot reconstruction)

## Rust Implementation Guidance

### Module Structure

Snapshot types should be organized as:
- `northstar_core::snapshot::SnapshotId` - Snapshot identifier
- `northstar_core::snapshot::ReadTxn` - Read transaction handle
- `northstar_core::snapshot::WriteTxn` - Write transaction handle
- `northstar_core::snapshot::SnapshotRegistry` - Snapshot management

### Type Definitions

**SnapshotId**: Use transparent newtype wrapper
```rust
#[repr(transparent)]
#[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SnapshotId(TransactionId);
```

**ReadTxn**: Use lifetime parameter for database reference
```rust
pub struct ReadTxn<'a> {
    txn_id: TransactionId,
    root_page_id: PageId,
    db: &'a Db,
    // Additional fields...
}
```

**WriteTxn**: Use lifetime parameter for database reference
```rust
pub struct WriteTxn<'a> {
    txn_id: TransactionId,
    txn_ctx: TransactionContext,
    db: &'a Db,
    // Additional fields...
}
```

**SnapshotRegistry**: Owns its data, no lifetime parameter needed
```rust
pub struct SnapshotRegistry {
    snapshots: HashMap<TransactionId, PageId>,
    current_txn_id: TransactionId,
    current_root_page_id: PageId,
}
```

### Lifetime Guidance

**ReadTxn and WriteTxn Must Have Lifetime Parameters**:
- The lifetime 'a ties the transaction to the database reference
- Prevents use-after-free bugs
- Ensures transactions are closed before database is dropped
- Compiler enforces correct usage patterns

**Example Lifetime Usage**:
```rust
impl<'a> ReadTxn<'a> {
    pub fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        // Self lifetime 'a ensures db is still valid
        // Can safely access self.db
    }
}
```

### Clone vs Copy Implementation

**SnapshotId**: Derive Copy and Clone
```rust
#[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SnapshotId(TransactionId);
```

**ReadTxn and WriteTxn**: Do NOT implement Copy or Clone
- Each handle is unique and manages exclusive ownership
- Cannot be safely copied or cloned
- Provide explicit fork() method if snapshot branching is needed

**Alternative Pattern**: If forked reads are needed
```rust
impl<'a> ReadTxn<'a> {
    pub fn fork(&self) -> ReadTxn<'a> {
        // Create new ReadTxn pointing to same snapshot
        // Both handles can read, but neither can write
    }
}
```

### Thread Safety

**SnapshotRegistry**: Use RwLock for concurrent access
```rust
pub struct SnapshotRegistry {
    snapshots: RwLock<HashMap<TransactionId, PageId>>,
    current_txn_id: AtomicU64,
    current_root_page_id: AtomicU64,
}
```

**ReadTxn**: Send and Sync if Db is Send and Sync
- Multiple threads can read concurrently
- Each thread has its own ReadTxn handle
- No shared mutable state between ReadTxn instances

**WriteTxn**: Not Send or Sync (single writer)
- Only one thread can hold the WriteTxn
- Must enforce at runtime or API level

### Implementation Notes

1. **Resource Management**: Use RAII pattern for cleanup
   ```rust
   impl<'a> Drop for ReadTxn<'a> {
       fn drop(&mut self) {
           // Automatically close snapshot if not explicitly closed
           // Log warning if not explicitly closed
       }
   }
   ```

2. **Explicit Close**: Provide explicit close() method
   ```rust
   impl<'a> ReadTxn<'a> {
       pub fn close(self) {
           // Consumes self to prevent use-after-close
           // Release resources
       }
   }
   ```

3. **Type Safety**: Use markers to prevent misuse
   ```rust
   pub struct ReadTxn<'a> { /* ... */ }
   pub struct WriteTxn<'a> { /* ... */ }

   // Cannot call put() on ReadTxn (compile error)
   // Cannot call get() on WriteTxn without explicit cast
   ```

4. **Visibility Calculation**: Optimize for common case
   ```rust
   impl<'a> ReadTxn<'a> {
       fn is_page_visible(&self, page: &Page) -> bool {
           page.txn_id <= self.txn_id
       }
   }
   ```

5. **Snapshot Cleanup**: Use reference counting for old snapshots
   ```rust
   pub struct SnapshotRegistry {
       snapshots: HashMap<TransactionId, (PageId, Arc<()>)>,
       // Arc reference count tracks active readers
   }
   ```

### Testing Strategy

**Unit tests needed for**:
- Snapshot creation and registration
- Snapshot root lookup for various transaction IDs
- Cleanup of old snapshots
- ReadTxn get operations return consistent results
- WriteTxn put/delete buffer correctly
- Commit makes changes visible
- Rollback discards changes

**Property tests for**:
- Snapshot isolation (reads don't see concurrent writes)
- Multiple readers can coexist without blocking
- Committed transactions become visible to new snapshots
- Rolled back transactions never become visible

**Integration scenarios**:
- Concurrent reads during writes see consistent snapshots
- Recovery rebuilds snapshot registry correctly
- Cleanup doesn't affect active readers
- Time-travel queries work with historical snapshots