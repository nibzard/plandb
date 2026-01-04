# Snapshot Creation

**Phase**: 5
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2026-01-04

## Table of Contents
1. [Purpose](#purpose)
2. [Snapshot Creation Overview](#snapshot-creation-overview)
3. [Creation Methods](#creation-methods)
4. [State Capture](#state-capture)
5. [Registration](#registration)
6. [Error Handling](#error-handling)
7. [Concurrency Considerations](#concurrency-considerations)
8. [Invariants](#invariants)
9. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Purpose

This specification defines how snapshots are created in NorthstarDB. Snapshot creation is the process of capturing a consistent view of the database at a specific point in time, represented by a transaction ID. The snapshot creation process must be:

- **Atomic**: Either fully succeeds or fully fails
- **Consistent**: Captures a complete, coherent database state
- **Fast**: Minimal overhead, O(1) complexity
- **Concurrent-safe**: Multiple callers can create snapshots simultaneously

A snapshot represents the database state at a particular transaction ID. Once created, the snapshot provides a stable, immutable view that never changes, regardless of subsequent writes.

---

## Snapshot Creation Overview

### What is a Snapshot?

A snapshot is a lightweight handle that captures the database state at a specific transaction ID. The snapshot itself does not copy any data. Instead, it records the root page ID of the B+tree at that transaction ID. All subsequent reads through the snapshot traverse the B+tree starting from that root page, seeing only the versions that existed at the snapshot's transaction ID.

### Creation Philosophy

NorthstarDB uses **copy-on-write** for snapshot creation:

- **No data copying**: Snapshot creation does NOT copy pages, keys, or values
- **Root capture**: The snapshot only stores the root page ID
- **Implicit retention**: Pages reachable from the root remain alive
- **Lazy cleanup**: Old pages freed after last snapshot referencing them drops

This design makes snapshot creation extremely fast (constant time) and allows unlimited concurrent snapshots with minimal memory overhead.

### Creation Flow

```
Application calls db.snapshot()
         │
         ├─► Acquire read lock (shared access)
         │
         ├─► Get current transaction ID
         │
         ├─► Get current root page ID
         │
         ├─► Create snapshot handle
         │    │
         │    └─► Store txn_id
         │    └─► Store root_page_id
         │
         ├─► Increment snapshot reference count
         │
         └─► Return snapshot handle to caller
```

---

## Creation Methods

### Method 1: Snapshot at Latest Transaction

**Function**: `snapshot()` or `begin_read()`

**Purpose**: Create a snapshot at the most recent committed transaction.

**Behavior**:
1. Acquire shared lock on database state
2. Read the current transaction ID from the registry
3. Read the current root page ID from the registry
4. Create a snapshot handle storing these values
5. Increment the snapshot reference count for this transaction ID
6. Release the shared lock
7. Return the snapshot handle

**When to use**: This is the most common method. Used for routine read transactions, queries, and analytics.

**Example scenario**:
```
Time  T1: Transaction 100 commits (root page ID = 50)
Time  T2: Application calls snapshot()
          - Returns snapshot with txn_id=100, root_page_id=50
Time  T3: Transaction 101 commits (root page ID = 55)
Time  T4: Application calls snapshot()
          - Returns snapshot with txn_id=101, root_page_id=55

Both snapshots can exist simultaneously. The first sees root page 50,
the second sees root page 55. Neither blocks the other.
```

---

### Method 2: Snapshot at Specific Transaction ID

**Function**: `snapshot_at(txn_id)` or `begin_read_at(txn_id)`

**Purpose**: Create a snapshot at a specific historical transaction ID.

**Behavior**:
1. Acquire shared lock on database state
2. Look up the requested transaction ID in the snapshot registry
3. If the transaction ID is not found:
   - If the ID is higher than the current transaction ID, return an error (future transaction)
   - If the ID is lower than the oldest retained transaction, return an error (expired)
   - Otherwise, return an error (transaction not found)
4. If the transaction ID is found:
   - Retrieve the root page ID associated with this transaction ID
   - Create a snapshot handle storing txn_id and root_page_id
   - Increment the snapshot reference count for this transaction ID
5. Release the shared lock
6. Return the snapshot handle

**When to use**: Time-travel queries, historical analysis, comparing database states, auditing.

**Example scenario**:
```
Database has transactions: 95 (root=40), 96 (root=42), 97 (root=45), 98 (root=48)

Application calls snapshot_at(96)
         - Registry lookup finds txn_id=96 maps to root_page_id=42
         - Returns snapshot with txn_id=96, root_page_id=42
         - Snapshot sees exactly the state as of transaction 96
```

---

### Method 3: Snapshot at Closest to Timestamp

**Function**: `snapshot_at_time(timestamp)` or `begin_read_at_time(timestamp)`

**Purpose**: Create a snapshot at the transaction closest to a given wall-clock timestamp.

**Behavior**:
1. Acquire shared lock on database state
2. Iterate through transaction IDs in the registry, newest to oldest
3. For each transaction, check its commit timestamp (stored in transaction metadata)
4. Find the transaction with the greatest commit timestamp less than or equal to the requested timestamp
5. If no transaction meets the criteria (all timestamps are after the requested time), return an error
6. If a transaction is found:
   - Retrieve its root page ID
   - Create a snapshot handle storing txn_id and root_page_id
   - Increment the snapshot reference count
7. Release the shared lock
8. Return the snapshot handle

**Note**: This method requires that commit timestamps are recorded for each transaction. If timestamp recording is disabled, this method returns an unsupported error.

**When to use**: Point-in-time recovery, historical queries by wall-clock time.

**Example scenario**:
```
Timestamp mapping:
  txn 95: 2026-01-04 10:00:00
  txn 96: 2026-01-04 10:05:00
  txn 97: 2026-01-04 10:10:00
  txn 98: 2026-01-04 10:15:00

Application calls snapshot_at_time(2026-01-04 10:12:00)
         - Searches for closest timestamp <= 10:12:00
         - Finds txn 97 at 10:10:00 (closest before request)
         - Returns snapshot with txn_id=97, root_page_id=45
```

---

## State Capture

### What Gets Captured

When a snapshot is created, the following state is captured and stored in the snapshot handle:

#### Captured Fields

1. **Transaction ID**: A 64-bit unsigned integer identifying the transaction
   - Purpose: Defines the visibility boundary for all reads through this snapshot
   - Invariant: Once set, never changes
   - Source: Read from the snapshot registry during creation

2. **Root Page ID**: A 64-bit unsigned integer identifying the B+tree root page
   - Purpose: Starting point for all B+tree traversals through this snapshot
   - Invariant: Once set, never changes
   - Source: Read from the snapshot registry, looked up by transaction ID

3. **Database Reference**: A shared reference (Arc or similar) to the database
   - Purpose: Keeps the database alive while the snapshot exists
   - Invariant: Reference count prevents database from being dropped
   - Source: Passed in from the calling context

#### What is NOT Captured

The following is deliberately NOT captured during snapshot creation:
- No keys are copied
- No values are copied
- No pages are copied
- No page data is loaded into memory
- No B+tree structure is duplicated

This "thin snapshot" design ensures snapshot creation is fast and lightweight.

---

### Snapshot Handle Structure

The snapshot handle is a small, stack-allocated structure containing:

**Field 1: txn_id**
- Type: Unsigned 64-bit integer
- Purpose: Identifies the transaction boundary
- Size: 8 bytes
- Invariant: Greater than zero, less than or equal to current transaction ID
- Source: Registry lookup or current transaction ID

**Field 2: root_page_id**
- Type: Unsigned 64-bit integer
- Purpose: Identifies the B+tree root page for this snapshot
- Size: 8 bytes
- Invariant: Valid page ID in the database file
- Source: Registry lookup by transaction ID

**Field 3: db**
- Type: Shared reference to database handle (Arc or similar)
- Purpose: Keeps database alive, provides access to pager for page reads
- Size: Pointer size (8 bytes on 64-bit systems)
- Invariant: Valid database reference
- Source: Passed in from caller

**Total Size**: Approximately 24 bytes on 64-bit systems (excluding Arc overhead)

---

## Registration

### Purpose of Registration

After a snapshot is created, it must be registered in the snapshot registry. Registration serves two purposes:

1. **Reference counting**: Tracks how many snapshots exist for each transaction ID
2. **Garbage collection prevention**: Prevents old pages from being freed while snapshots reference them

### Registration Process

When a snapshot is created, the following registration steps occur:

1. **Create the snapshot handle**: Allocate the snapshot structure with txn_id, root_page_id, and db reference

2. **Increment reference count**: Atomically increment the reference count for the transaction ID in the snapshot registry
   - This tells the system that at least one snapshot exists for this transaction
   - The registry maintains a map from transaction ID to reference count

3. **Return to caller**: The snapshot handle is returned to the application

4. **Automatic unregistration**: When the snapshot is dropped (goes out of scope, explicitly closed, or reference count reaches zero):
   - The snapshot's Drop trait is invoked
   - The reference count for the transaction ID is atomically decremented
   - If the reference count reaches zero, the registry may trigger cleanup for old transactions

### Registration Data Structure

The snapshot registry maintains:

**Field 1: snapshots**
- Type: HashMap mapping transaction ID to snapshot metadata
- Key: Transaction ID (64-bit unsigned integer)
- Value: Snapshot metadata structure containing:
  - root_page_id: The root page for this transaction
  - reference_count: Number of active snapshots for this transaction
- Purpose: Track active snapshots and prevent garbage collection
- Invariant: reference_count is always greater than or equal to zero
- Concurrency: Protected by a lock or concurrent map for thread-safe access

**Field 2: current_txn_id**
- Type: 64-bit unsigned integer
- Purpose: Tracks the most recently committed transaction
- Invariant: Monotonically increasing, never decreases
- Source: Updated during transaction commit

**Field 3: current_root_page_id**
- Type: 64-bit unsigned integer
- Purpose: Tracks the root page of the most recent transaction
- Invariant: Valid page ID, changes when root page changes during commit
- Source: Updated during transaction commit

### Registration Algorithm

The registration process follows these steps:

**Step 1**: Acquire exclusive access to the snapshot registry (via lock or atomic operation)

**Step 2**: Look up the transaction ID in the snapshots map:
   - If the entry exists: Increment the reference_count field
   - If the entry does not exist: This is an error (transaction not found in registry)

**Step 3**: Store the root_page_id from the registry entry in the snapshot handle

**Step 4**: Release exclusive access to the registry

**Step 5**: Return the snapshot handle to the caller

### Unregistration Algorithm

When a snapshot is dropped:

**Step 1**: Acquire exclusive access to the snapshot registry

**Step 2**: Look up the transaction ID in the snapshots map

**Step 3**: Decrement the reference_count field

**Step 4**: If reference_count reaches zero:
   - Optionally trigger garbage collection for this transaction
   - Or mark the transaction as eligible for cleanup

**Step 5**: Release exclusive access to the registry

**Step 6**: The snapshot handle is deallocated

---

## Error Handling

### Error Conditions

#### Error 1: Transaction Not Found

**Condition**: The requested transaction ID does not exist in the snapshot registry

**When occurs**:
- Application requests a snapshot at a transaction ID that was never committed
- Application requests a snapshot at a transaction ID that has been garbage collected

**Response**: Return a transaction-not-found error to the caller

**Recovery**: Caller can retry with a valid transaction ID, typically the current transaction ID

---

#### Error 2: Transaction in Future

**Condition**: The requested transaction ID is greater than the current transaction ID

**When occurs**: Application requests a snapshot at a transaction ID that has not been committed yet

**Response**: Return a transaction-in-future error to the caller

**Recovery**: Caller must wait for the transaction to commit, or use the current transaction ID instead

---

#### Error 3: Transaction Expired

**Condition**: The requested transaction ID has been garbage collected and is no longer available

**When occurs**: Application requests a snapshot at a very old transaction ID that has been cleaned up

**Response**: Return a transaction-expired error to the caller

**Recovery**: Caller must use a more recent transaction ID, or adjust the garbage collection policy

---

#### Error 4: Database Closed

**Condition**: Snapshot creation attempted after the database has been closed

**When occurs**: Application attempts to create a snapshot during or after database shutdown

**Response**: Return a database-closed error to the caller

**Recovery**: No recovery possible, database must be reopened

---

#### Error 5: Registry Corrupt

**Condition**: The snapshot registry is in an inconsistent state

**When occurs**: Internal bug or data corruption

**Response**: Return a registry-corrupt error to the caller

**Recovery**: Database must be restarted or recovered from backup

---

### Error Handling Strategy

All snapshot creation errors are handled synchronously:

1. **Detect error**: During creation process, validate all conditions
2. **Rollback**: If error detected after any state changes, roll back those changes
3. **Report**: Return error to caller with detailed error type and message
4. **No partial state**: Snapshot creation is all-or-nothing; no partially created snapshots exist

---

## Concurrency Considerations

### Concurrent Snapshot Creation

Multiple threads can create snapshots simultaneously without blocking:

**Property 1**: Snapshot creation only requires shared (read) access to the database state

**Property 2**: The snapshot registry can support multiple concurrent readers

**Property 3**: Each snapshot handle is independent and does not interfere with others

**Implementation strategy**:
- Use a reader-writer lock (RwLock) for the snapshot registry
- Snapshot creation acquires shared (read) lock
- Transaction commit (which updates the registry) acquires exclusive (write) lock
- Multiple snapshot creations proceed in parallel without blocking each other

---

### Snapshot Creation vs Transaction Commit

Snapshot creation and transaction commit can occur concurrently:

**Scenario**: Thread A is committing a transaction while thread B is creating a snapshot

**Behavior**:
- Thread A acquires exclusive lock on registry to update current_txn_id and current_root_page_id
- Thread B blocks waiting for shared lock
- Thread A releases exclusive lock
- Thread B acquires shared lock and reads the updated values
- Thread B sees either the pre-commit or post-commit state, never an intermediate state

**Correctness**: The use of locks ensures that thread B always sees a consistent snapshot, either entirely before or entirely after thread A's commit.

---

### Snapshot Creation vs Garbage Collection

Snapshot creation and garbage collection can occur concurrently:

**Scenario**: Thread A is creating a snapshot while thread B is performing garbage collection

**Behavior**:
- Thread A looks up a transaction ID in the registry
- Thread B checks reference counts to determine if transactions can be cleaned up
- If thread A increments the reference count before thread B checks it, the transaction is preserved
- If thread B checks before thread A increments, and the count is zero, the transaction may be cleaned up
- Thread A must handle the case where the transaction is not found (already cleaned up)

**Correctness**: Proper locking or atomic operations ensure that reference counts are accurate and transactions are not cleaned up while in use.

---

## Invariants

### Snapshot Handle Invariants

1. **Immutability**: Once created, a snapshot's txn_id and root_page_id never change
2. **Validity**: The txn_id is always a valid, committed transaction ID at the time of creation
3. **Page validity**: The root_page_id is always a valid page ID in the database file
4. **Database reference**: The snapshot holds a reference to the database, preventing it from being dropped

---

### Registry Invariants

1. **Monotonic transaction IDs**: current_txn_id never decreases
2. **Reference count non-negativity**: reference_count is always greater than or equal to zero
3. **Consistent mapping**: Each transaction ID in the registry maps to exactly one root page ID
4. **No orphaned references**: If reference_count is greater than zero, at least one snapshot exists for that transaction

---

### Creation Invariants

1. **Atomicity**: Snapshot creation either fully succeeds or fully fails; no partial snapshots exist
2. **Consistency**: A snapshot represents a complete, coherent database state
3. **Isolation**: Creating a snapshot does not block other snapshot creations
4. **Durability**: Once created, the snapshot handle is valid until explicitly dropped

---

## Rust Implementation Guidance

### Module Structure

The snapshot creation functionality should be organized in the Rust modules as follows:

**Module**: `snapshot/create.rs`
- Purpose: Contains snapshot creation logic
- Exports: Functions for creating snapshots (latest, at txn_id, at timestamp)
- Dependencies: snapshot registry, transaction ID types, page ID types

**Module**: `snapshot/handle.rs`
- Purpose: Defines the snapshot handle structure
- Exports: Snapshot struct with Drop trait for unregistration
- Dependencies: database Arc, transaction ID, page ID

---

### Type Definitions

**Type: Snapshot**

A struct representing a snapshot handle with the following fields:

- **Field 1**: txn_id
  - Type: u64 or TransactionId newtype
  - Access: Private (read-only accessor provided)
  - Purpose: Identifies the transaction boundary for this snapshot

- **Field 2**: root_page_id
  - Type: u64 or PageId newtype
  - Access: Private (read-only accessor provided)
  - Purpose: Starting point for B+tree traversals

- **Field 3**: db
  - Type: Arc<DbInner>
  - Access: Private
  - Purpose: Keeps database alive, provides access to storage

**Traits**:
- Implement Clone: Creates a new handle referencing the same transaction ID, increments reference count
- Implement Drop: Decrements reference count in registry
- Do NOT implement Copy: Reference counting semantics require explicit cloning

---

### Concurrency Strategy

**Option 1: RwLock for Snapshot Registry**

Use a RwLock to protect the snapshot registry:
- Snapshot creation: Acquires shared (read) lock
- Transaction commit: Acquires exclusive (write) lock
- Multiple snapshot creations can proceed concurrently
- Snapshot creation blocks during commit, but only briefly

**Option 2: Atomic Reference Counts**

Use atomic operations for reference counting:
- Store reference counts in AtomicUsize
- Use fetch_add for incrementing, fetch_sub for decrementing
- Allows true lock-free snapshot creation
- Requires careful handling of registry entry lifecycle

**Recommendation**: Start with RwLock for simplicity and correctness. Optimize to atomics if profiling shows lock contention.

---

### Key Implementation Steps

**Step 1: Define Snapshot struct**
- Create struct with txn_id, root_page_id, and db fields
- Make fields private, provide accessor methods
- Implement Clone and Drop traits

**Step 2: Implement snapshot creation function**
- Function signature: Takes reference to database, returns Result<Snapshot, Error>
- Acquire shared lock on registry
- Read current transaction ID and root page ID
- Create snapshot handle
- Increment reference count atomically
- Release lock
- Return snapshot

**Step 3: Implement snapshot_at function**
- Function signature: Takes reference to database and transaction ID, returns Result<Snapshot, Error>
- Acquire shared lock on registry
- Look up transaction ID in registry
- If not found, return error
- Create snapshot handle with looked-up root page ID
- Increment reference count
- Release lock
- Return snapshot

**Step 4: Implement snapshot_at_time function**
- Function signature: Takes reference to database and timestamp, returns Result<Snapshot, Error>
- Acquire shared lock on registry
- Iterate through transactions to find closest timestamp
- If found, create snapshot handle and increment reference count
- If not found, return error
- Release lock
- Return snapshot

**Step 5: Implement Drop trait**
- In Drop implementation, acquire exclusive lock on registry
- Decrement reference count for snapshot's transaction ID
- Optionally trigger cleanup if count reaches zero
- Release lock

---

### Error Handling

Define error types for all failure conditions:

**Error Enum: SnapshotError**

- **Variant 1**: TransactionNotFound
  - When: Requested transaction ID not in registry
  - Fields: txn_id (the missing ID)

- **Variant 2**: TransactionInFuture
  - When: Requested transaction ID is greater than current
  - Fields: requested_id, current_id

- **Variant 3**: TransactionExpired
  - When: Requested transaction ID has been garbage collected
  - Fields: txn_id

- **Variant 4**: DatabaseClosed
  - When: Database is closed during snapshot creation
  - Fields: None

- **Variant 5**: RegistryCorrupt
  - When: Registry in inconsistent state
  - Fields: Details describing the corruption

Use thiserror crate for automatic error display and source integration.

---

### Testing Strategy

**Unit tests needed for**:
- Snapshot creation at latest transaction returns correct txn_id and root_page_id
- Snapshot creation at specific transaction ID returns correct root_page_id
- Snapshot creation at invalid transaction ID returns error
- Snapshot creation at future transaction ID returns error
- Snapshot creation at expired transaction ID returns error
- Snapshot cloning increments reference count
- Snapshot dropping decrements reference count
- Reference count reaching zero triggers cleanup

**Property tests for**:
- Snapshot immutability: txn_id and root_page_id never change after creation
- Reference count accuracy: After N clones, count is incremented by N
- Registry consistency: After M snapshots created and dropped, reference counts are accurate

**Integration scenarios**:
- Create multiple snapshots concurrently from different threads
- Create snapshot while transaction is committing
- Create snapshot while garbage collection is running
- Create snapshot, verify reads return consistent state
- Create snapshot at time, verify correct transaction selected

---

### Performance Considerations

**Target complexity**:
- Snapshot creation: O(1) time complexity
- Snapshot clone: O(1) time complexity
- Snapshot drop: O(1) time complexity

**Memory overhead**:
- Per snapshot: Approximately 24 bytes plus Arc overhead
- Reference counting: Approximately 16 bytes per active transaction ID

**Lock contention**:
- Snapshot creation should not block other snapshot creations
- Brief blocking during transaction commit is acceptable
- Consider lock-free reference counting if contention becomes an issue

---

## Appendix

### Related Specifications

- [05-snapshot-overview.md](./05-snapshot-overview.md) - Overall snapshot and MVCC design
- [05-snapshot-registry.md](./05-snapshot-registry.md) - Snapshot registry implementation
- [04-txn-commit.md](./transactions/04-txn-commit.md) - Transaction commit updates snapshots
- [04-read-txn.md](./transactions/04-read-txn.md) - Read transactions use snapshots

### Terminology

| Term | Definition |
|------|------------|
| **Snapshot** | Immutable view of database at specific transaction ID |
| **Transaction ID** | Monotonically increasing identifier assigned to each transaction |
| **Root Page ID** | Page ID of the B+tree root for a given transaction |
| **Snapshot Registry** | Mapping from transaction ID to root page ID and reference counts |
| **Reference Count** | Number of active snapshots for a given transaction ID |
| **Garbage Collection** | Process of freeing old pages no longer referenced by any snapshot |

### Open Questions

1. **Timestamp resolution**: What granularity for transaction commit timestamps? (Decision: Millisecond)
2. **Timestamp storage**: Where are commit timestamps stored? (Decision: In transaction metadata in WAL)
3. **Cleanup trigger**: Should cleanup be immediate or deferred when reference count reaches zero? (Decision: Deferred, batched cleanup)

---

**Next**: [Task 5.4 - Snapshot Visibility](../rust/todo-rust.md#task-54)
