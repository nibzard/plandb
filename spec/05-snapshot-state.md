# Snapshot State

**Phase**: 5
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2026-01-04

## Table of Contents
1. [Purpose](#purpose)
2. [SnapshotState Type Overview](#snapshotstate-type-overview)
3. [SnapshotState Enum Variants](#snapshotstate-enum-variants)
4. [LSN Range Tracking](#lsn-range-tracking)
5. [State Transitions](#state-transitions)
6. [Lifecycle Management](#lifecycle-management)
7. [Integration with Other Components](#integration-with-other-components)
8. [Invariants](#invariants)
9. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Purpose

This specification defines the SnapshotState type, which tracks the lifecycle and validity status of MVCC snapshots in NorthstarDB. SnapshotState determines whether a snapshot is active, committed, expired, or being cleaned up, and is fundamental to maintaining consistency guarantees and managing memory correctly.

The SnapshotState type serves three primary purposes:
1. **Lifecycle tracking**: Monitors whether a snapshot is in use, completed, or ready for cleanup
2. **Visibility enforcement**: Ensures reads only access valid, consistent snapshot states
3. **Memory management**: Enables garbage collection by identifying snapshots no longer referenced

---

## SnapshotState Type Overview

### What is SnapshotState?

SnapshotState is an enumeration that represents the current state of a snapshot in its lifecycle. Every snapshot in NorthstarDB transitions through these states from creation to eventual cleanup.

### State Machine Philosophy

NorthstarDB uses a simple state machine for snapshot lifecycle:
- **Linear progression**: Snapshots move forward through states, never backward
- **Terminal states**: Some states are final (no further transitions possible)
- **State-based operations**: Certain operations are only valid in specific states

### Relationship to Other Types

SnapshotState is distinct from but related to:
- **SnapshotId**: Identifies which transaction a snapshot represents (unchanging)
- **SnapshotState**: Tracks the current lifecycle status of that snapshot (changing)
- **TransactionState**: Tracks the transaction's commit/abort status (separate concern)

---

## SnapshotState Enum Variants

### Variant 1: Active

**Numeric Value**: 0

**Description**: Snapshot is currently in use by one or more readers

**When this state occurs**:
- Immediately after snapshot creation via `db.snapshot()` or `db.begin_read()`
- Snapshot has been successfully registered in the snapshot registry
- At least one ReadTxn holds a reference to this snapshot
- Readers are actively performing get() and scan() operations through this snapshot

**Operations allowed in this state**:
- All read operations (get, scan, iterator)
- Snapshot cloning (creates new handle to same state)
- Reference count increment/decrement

**Operations NOT allowed in this state**:
- State cannot transition to Committed (snapshots don't "commit" - transactions do)
- Cannot be cleaned up while reference count is non-zero

**Transition paths**:
- Active → Expired (when reference count reaches zero and cleanup policy applies)
- Active → Closed (when explicitly closed by all readers)

**Invariants**:
- txn_id is a valid committed transaction ID
- root_page_id points to a valid B+tree root page
- Reference count in snapshot registry is greater than or equal to one
- All pages reachable from root_page_id are guaranteed to exist

**Duration**: From snapshot creation until all readers release their references

---

### Variant 2: Committed

**Numeric Value**: 1

**Description**: Snapshot represents a successfully committed transaction state

**When this state occurs**:
- After a WriteTxn successfully commits, creating a new snapshot entry in the registry
- The snapshot is registered with its txn_id and root_page_id
- This state indicates the underlying transaction committed successfully
- New readers can create Active snapshots from this committed state

**Operations allowed in this state**:
- New ReadTxn can be created from this snapshot (transitioning it to Active)
- The snapshot entry persists in the registry for historical queries
- Can be looked up by txn_id for time-travel queries

**Operations NOT allowed in this state**:
- Direct read operations (must create an Active snapshot first)
- Cannot be cleaned up if reference count is non-zero

**Transition paths**:
- Committed → Active (when a reader creates a ReadTxn from this snapshot)
- Committed → Expired (when cleanup policy removes old committed snapshots)

**Invariants**:
- txn_id is a committed transaction ID
- root_page_id is the durable root page after transaction commit
- All mutations from this transaction are visible
- Transaction's commit record exists in the WAL

**Duration**: Persists in registry from commit until cleaned up by garbage collection

**Note**: This is a registry state, not a snapshot handle state. The snapshot entry in the registry is "committed" and can be used to create Active snapshot handles for readers.

---

### Variant 3: Aborted

**Numeric Value**: 2

**Description**: Snapshot was invalidated due to transaction rollback or explicit closure

**When this state occurs**:
- After a WriteTxn is rolled back (if snapshot was created before commit)
- When a snapshot is explicitly closed before all reads complete
- When the database is closed while snapshots are still active
- When corruption is detected in the snapshot's B+tree structure

**Operations allowed in this state**:
- None - aborted snapshots are unusable

**Operations NOT allowed in this state**:
- All read operations return errors
- Cannot be cloned or resurrected
- Cannot transition back to Active

**Transition paths**:
- Terminal state - no further transitions possible
- Resources are released and memory is reclaimed

**Invariants**:
- Snapshot handle may still exist but operations fail
- Reference count is zero (or will be shortly)
- Pages may be reclaimed by garbage collector

**Duration**: Brief transition state before resource cleanup

**Note**: Aborted state is primarily for snapshots created for in-flight transactions that rollback. Committed snapshot entries in the registry are never "aborted" - they are either Committed (available) or removed (cleaned up).

---

## LSN Range Tracking

### Purpose of LSN Ranges

Snapshots track Log Sequence Number (LSN) boundaries to:
1. **Enable time-travel queries**: Find historical state by LSN
2. **Support WAL recovery**: Rebuild snapshots after crash
3. **Provide consistency guarantees**: Verify WAL contains all needed records

### LSN Fields in Snapshot Context

**Field 1: creation_lsn**

**Type**: 64-bit unsigned integer (Lsn type)

**Description**: The LSN at which this snapshot was created

**Purpose**:
- Marks the lower bound of visible WAL records for this snapshot
- All records with LSN less than or equal to snapshot_txn_lsn are potentially visible
- Records with LSN greater than snapshot_txn_lsn are NOT visible

**Invariants**:
- creation_lsn is less than or equal to the LSN of the snapshot's transaction
- For latest snapshots, creation_lsn equals the current WAL head LSN
- For historical snapshots, creation_lsn is the LSN at time of snapshot creation

**Size**: 8 bytes

---

**Field 2: snapshot_txn_lsn**

**Type**: 64-bit unsigned integer (Lsn type)

**Description**: The LSN of the commit record for this snapshot's transaction

**Purpose**:
- Defines the upper bound of visible WAL records
- Only transactions with LSN less than or equal to this value are visible
- This is the primary visibility boundary for MVCC

**Invariants**:
- snapshot_txn_lsn is always greater than or equal to creation_lsn
- snapshot_txn_lsn corresponds to a valid commit record in the WAL
- All transactions with LSN <= snapshot_txn_lsn are visible to this snapshot

**Size**: 8 bytes

---

### LSN Range Semantics

**Visibility Rule**: A transaction with commit LSN X is visible to a snapshot with snapshot_txn_lsn Y if and only if X <= Y

**Examples**:

```
Scenario 1: Latest snapshot
- WAL contains: [LSN 100: txn A, LSN 101: txn B, LSN 102: txn C]
- Application calls db.snapshot()
- Snapshot receives: creation_lsn=102, snapshot_txn_lsn=102
- Visible transactions: A (100), B (101), C (102)
- Invisible: None (all committed transactions are visible)

Scenario 2: Historical snapshot
- WAL contains: [LSN 100: txn A, LSN 101: txn B, LSN 102: txn C, LSN 103: txn D]
- Application calls db.snapshot_at_txn(101)
- Snapshot receives: creation_lsn=103, snapshot_txn_lsn=101
- Visible transactions: A (100), B (101)
- Invisible: C (102), D (103) - committed after snapshot
```

---

### LSN Range Tracking Implementation

**Storage location**: LSN ranges are tracked in two places:

1. **Snapshot handle (ReadTxn)**:
   - Stores snapshot_txn_lsn for visibility checks
   - Used during B+tree traversal to filter pages by txn_id/LSN

2. **Snapshot registry entry**:
   - Maps txn_id to root_page_id
   - Implicitly tracks LSN via commit records in WAL
   - Used for recovery and time-travel queries

**LSN lookup**: To find the LSN for a transaction ID:
1. Scan WAL to find commit record with matching txn_id
2. Extract LSN from commit record header
3. This LSN becomes the snapshot_txn_lsn for snapshots of that transaction

**Optimization**: For performance, maintain an LSN index:
- HashMap from txn_id to Lsn
- Built during WAL replay on recovery
- Updated on each commit
- Enables O(1) LSN lookup for snapshot creation

---

### WAL Recovery and LSN Ranges

After a crash, snapshots are reconstructed using LSN ranges:

**Recovery algorithm**:
1. Scan WAL from beginning to end
2. For each commit record, extract (txn_id, Lsn, root_page_id)
3. Rebuild snapshot registry with these mappings
4. For each active snapshot before crash:
   - Look up its txn_id in registry
   - Retrieve the associated LSN
   - Reconstruct snapshot with correct LSN boundaries

**Consistency verification**:
- Verify LSN monotonicity (no gaps in commit chain)
- Verify each LSN maps to a valid commit record
- Verify root_page_id exists in pager

**Failure handling**:
- If LSN chain has gaps: Recovery fails, database is corrupt
- If root_page_id is invalid: Snapshot cannot be restored, return error
- If commit record is missing: Transaction is considered uncommitted

---

## State Transitions

### State Transition Diagram

```
                    [Creation]
                         │
                         ▼
                    ┌─────────┐
                    │ Active  │ ◄───────┐
                    └────┬────┘         │
                         │              │
         [All readers    │              │ [New reader
          release]       │              │  creates handle]
                         ▼              │
                    ┌─────────┐         │
          [Cleanup  │ Expired │ ────────┘
           policy]  └────┬────┘
                    │    │
                    │    └─────► [Removed from registry]
                    │
                    ▼
              [Resources freed]
```

For committed snapshots in the registry:
```
                    [Commit]
                         │
                         ▼
                    ┌───────────┐
                    │ Committed │ ◄────┐
                    └─────┬─────┘      │
                          │            │ [Time-travel
           [Cleanup       │            │  query]
            policy]       │            │
                          ▼            │
                     ┌───────────┐    │
                     │  Expired  │ ───┘
                     └───────────┘
                          │
                          ▼
                    [Removed from registry]
```

---

### Transition Rules

**Transition 1: Creation → Active**

**Trigger**: `db.snapshot()` or `db.begin_read()` is called

** Preconditions**:
- Database is open
- Requested transaction ID exists in registry (or using latest)
- Registry entry is in Committed state

**Actions**:
1. Allocate new snapshot handle
2. Copy txn_id and root_page_id from registry
3. Increment reference count in registry
4. Set snapshot state to Active
5. Return handle to caller

**Postconditions**:
- Snapshot state is Active
- Reference count is greater than or equal to one
- All read operations through snapshot will succeed

**Error conditions**:
- TransactionNotFound: Requested txn_id not in registry
- DatabaseClosed: Database is shutting down

---

**Transition 2: Active → Expired**

**Trigger**: Reference count reaches zero AND cleanup policy applies

**Preconditions**:
- All ReadTxn handles have been dropped or closed
- Reference count in registry is zero
- Cleanup policy allows removal (age, count, or manual trigger)

**Actions**:
1. Mark snapshot state as Expired
2. Queue snapshot for cleanup
3. Garbage collector frees unreachable pages
4. Remove registry entry (if not needed for time-travel)

**Postconditions**:
- Snapshot handle is unusable (operations return error)
- Registry entry may be removed (depending on retention policy)
- Memory is reclaimed

**Note**: If retention policy requires keeping historical snapshots, the registry entry may persist even after snapshot handle is expired. Only the handle is expired; the committed state remains available for time-travel queries.

---

**Transition 3: Committed → Active**

**Trigger**: Time-travel query creates ReadTxn from historical transaction

**Preconditions**:
- Transaction ID exists in registry
- Registry entry is Committed (not removed)
- Transaction is within retention window

**Actions**:
1. Look up txn_id in snapshot registry
2. Retrieve root_page_id
3. Allocate new snapshot handle with these values
4. Increment reference count for this registry entry
5. Set snapshot state to Active
6. Return handle to caller

**Postconditions**:
- New Active snapshot handle exists
- Reference count incremented
- Snapshot can be used for read operations

**Error conditions**:
- TransactionNotFound: txn_id not in registry or was cleaned up
- TransactionExpired: txn_id exists but is outside retention window

---

**Transition 4: Committed → Expired (Registry Cleanup)**

**Trigger**: Cleanup policy removes old committed snapshots from registry

**Preconditions**:
- Registry entry has zero reference count
- Cleanup policy conditions are met (age, count threshold)
- Snapshot is not the genesis snapshot (txn_id 0)

**Actions**:
1. Mark registry entry as Expired
2. Remove entry from snapshots HashMap
3. Signal garbage collector to reclaim pages
4. Update registry statistics

**Postconditions**:
- Registry entry no longer exists
- New time-travel queries to this txn_id will fail
- Pages become reclaimable (if not referenced by other snapshots)

**Note**: Genesis snapshot (txn_id 0) is never removed, even if cleanup policy would otherwise delete it.

---

### Invalid Transitions

The following state transitions are **NEVER allowed**:

1. **Active → Committed**: Snapshots do not "commit" - transactions do. Snapshots are created from already-committed transactions.

2. **Expired → Active**: Once expired, a snapshot cannot be resurrected. A new snapshot handle must be created from the registry if the committed state still exists.

3. **Committed → Aborted**: Committed snapshots in the registry are never aborted. Only in-flight transaction snapshots can be aborted on rollback.

4. **Any state → Active without registration**: A snapshot cannot be Active unless it has a valid registry entry with incremented reference count.

---

## Lifecycle Management

### Creation Phase

**Step 1: Registry lookup**
- Application requests snapshot at specific or latest transaction ID
- SnapshotRegistry is queried for txn_id → root_page_id mapping
- Validation ensures transaction exists and is committed

**Step 2: Handle allocation**
- Snapshot structure is allocated with txn_id and root_page_id
- Database reference (Arc) is stored to keep database alive
- Initial state is set to Active

**Step 3: Reference registration**
- Reference count in snapshot registry is atomically incremented
- This prevents garbage collection while snapshot is in use
- Multiple handles can reference the same registry entry

**Step 4: Return to caller**
- Snapshot handle is returned to application
- Application can now perform read operations

---

### Active Phase

**Read operations**:
- All get() and scan() operations pass through snapshot
- B+tree traversal uses root_page_id as starting point
- Page visibility is checked against snapshot's txn_id
- Zero-copy reads reference pages directly

**Concurrency**:
- Multiple Active snapshots can coexist
- Readers never block each other
- Readers never block writers
- Writers never block readers

**Reference tracking**:
- Each snapshot handle holds a "claim" on the registry entry
- Cloning a snapshot increments reference count
- Dropping a snapshot decrements reference count
- Registry tracks total active references per transaction

---

### Expiration Phase

**Trigger conditions** (any of these can trigger expiration):
1. Reference count reaches zero (no more active handles)
2. Cleanup policy's age threshold is exceeded
3. Cleanup policy's count threshold is exceeded
4. Manual cleanup is triggered
5. Database is closing

**Expiration process**:
1. Snapshot state is marked as Expired
2. Registry entry may be removed (depending on retention policy)
3. Pages become eligible for garbage collection
4. Memory is reclaimed when no other snapshots reference those pages

**Retention policies**:
- **Count-based**: Keep N most recent snapshots
- **Age-based**: Keep snapshots newer than T seconds
- **Hybrid**: Keep N most recent AND all snapshots newer than T seconds
- **Manual**: Explicit cleanup triggered by application

---

### Cleanup Phase

**Garbage collection**:
- Pages unreachable from any Active snapshot are freed
- Reference counting tracks page usage across snapshots
- Incremental cleanup avoids blocking readers

**Resource release**:
- Snapshot handle memory is freed when last reference is dropped
- Registry entry is removed when no longer needed for time-travel
- B+tree pages are freed when no snapshots reference them

**Genesis exception**:
- Snapshot with txn_id 0 (empty database) is never removed
- Always kept as fallback for time-travel queries
- Minimal overhead (single empty root page)

---

## Integration with Other Components

### Integration with SnapshotRegistry

**SnapshotRegistry tracks**:
- Map from txn_id to (root_page_id, reference_count)
- Used for both Active snapshot handles and Committed registry entries

**Interaction**:
- Snapshot creation queries registry for txn_id mapping
- Snapshot handle increments registry reference count
- Snapshot dropping decrements registry reference count
- Registry cleanup removes entries with zero reference count

**State synchronization**:
- Registry entry Committed + refcount > 0 → snapshot handle can be Active
- Registry entry Committed + refcount = 0 → entry can be cleaned up
- Registry entry removed → snapshot handle cannot be created (error)

---

### Integration with Transaction System

**WriteTxn commit**:
1. Transaction commits at LSN X
2. New registry entry created: txn_id maps to new root_page_id
3. Registry entry state is Committed
4. Future readers can create Active snapshots from this entry

**ReadTxn creation**:
1. Application calls db.begin_read() or db.begin_read_at(txn_id)
2. Registry is queried for txn_id → root_page_id mapping
3. Snapshot handle is created in Active state
4. Registry reference count is incremented

**WriteTxn abort**:
1. Transaction is rolled back
2. No registry entry is created
3. Any snapshot handles created for this transaction (unlikely) are marked Aborted

---

### Integration with B+Tree

**B+tree stores multiple versions**:
- Each page has an associated txn_id
- Snapshots traverse from their root_page_id
- Page visibility: page.txn_id <= snapshot.txn_id

**Snapshot root navigation**:
- Snapshot's root_page_id is entry point for all reads
- Different snapshots may have different root_page_ids (from different commits)
- B+tree traversal respects snapshot's txn_id for visibility

**Garbage collection**:
- Pages not reachable from any Active snapshot's root are candidates for cleanup
- Reference counting across snapshots prevents premature cleanup

---

### Integration with WAL

**WAL records commit LSNs**:
- Each committed transaction has a commit record with LSN
- LSN defines total order of commits
- Snapshots use LSN for visibility calculations

**Recovery workflow**:
1. Scan WAL to rebuild snapshot registry (txn_id → Lsn → root_page_id)
2. For each txn_id, create Committed registry entry
3. Active snapshots before crash are restored from registry
4. LSN ranges are reconstructed from commit records

**Time-travel queries**:
- Application requests snapshot at specific LSN or timestamp
- WAL is scanned to find commit record closest to requested LSN
- Registry entry for that txn_id is used to create snapshot

---

## Invariants

### Snapshot Handle Invariants

1. **Immutability**: Once created, snapshot's txn_id and root_page_id never change
2. **Valid transaction**: txn_id is always a committed transaction ID
3. **Valid page**: root_page_id is always a valid page in the database
4. **Database alive**: Snapshot holds reference to database, preventing premature drop
5. **State consistency**: Snapshot state accurately reflects lifecycle status

---

### Registry Entry Invariants

1. **Existence**: Every txn_id in snapshots map has a valid root_page_id
2. **Uniqueness**: Each txn_id appears at most once in the map
3. **Monotonicity**: current_txn_id is the maximum txn_id in the map
4. **Genesis presence**: txn_id 0 is always present
5. **Reference accuracy**: reference_count equals number of Active snapshot handles

---

### State Transition Invariants

1. **Forward progression**: Snapshots never move backward through states
2. **Terminal states**: Expired and Aborted are terminal (no transitions out)
3. **Creation precondition**: Active state requires valid registry entry
4. **Expiration precondition**: Cannot expire while reference count > 0
5. **Committed stability**: Registry entries in Committed state remain until explicitly removed

---

### LSN Range Invariants

1. **Monotonicity**: snapshot_txn_lsn is always >= creation_lsn
2. **Valid LSN**: Both LSNs correspond to valid WAL records
3. **Visibility correctness**: All transactions with LSN <= snapshot_txn_lsn are visible
4. **Invisibility correctness**: No transactions with LSN > snapshot_txn_lsn are visible
5. **Ordering**: For two snapshots with txn_ids X and Y where X < Y, snapshot X's LSN <= snapshot Y's LSN

---

### Garbage Collection Invariants

1. **Safety**: Pages reachable from any Active snapshot are never freed
2. **Liveness**: Pages unreachable from all Active snapshots are eventually freed
3. **Genesis protection**: Snapshot with txn_id 0 is never cleaned up
4. **Reference respect**: Cleanup waits for reference count to reach zero
5. **Atomicity**: Page removal is atomic (no partial cleanup)

---

## Rust Implementation Guidance

### Module Structure

The SnapshotState type should be organized as:

**Module**: `snapshot/state.rs`
- Purpose: Defines SnapshotState enum and lifecycle management
- Exports: SnapshotState enum, transition functions, validation logic
- Dependencies: snapshot registry, transaction ID types, LSN types

---

### Type Definition

**SnapshotState Enum**

Define as a simple enum with three variants:

```rust
/// Lifecycle state of an MVCC snapshot
///
/// Snapshots transition through states from creation to cleanup.
/// Each state determines what operations are valid and when
/// resources can be reclaimed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotState {
    /// Snapshot is actively in use by one or more readers
    ///
    /// In this state:
    /// - All read operations (get, scan) are allowed
    /// - Snapshot holds a reference in the registry
    /// - Pages reachable from root are guaranteed to exist
    /// - Reference count is >= 1
    Active = 0,

    /// Snapshot represents a committed transaction in the registry
    ///
    /// This is a registry state, not a snapshot handle state.
    /// Committed registry entries can be used to create new Active
    /// snapshot handles for readers.
    ///
    /// In this state:
    /// - Registry entry exists and can be looked up
    /// - New Active snapshot handles can be created
    /// - May have zero or more active references
    /// - Persists until cleaned up by garbage collection
    Committed = 1,

    /// Snapshot was invalidated and is no longer usable
    ///
    /// In this state:
    /// - No operations are allowed
    /// - Resources are being released
    /// - Registry entry may be removed
    /// - Pages become eligible for garbage collection
    ///
    /// Terminal state - no further transitions possible.
    Aborted = 2,
}
```

**Traits to derive**:
- Debug: For logging and debugging
- Clone: For cheap state copying
- Copy: For trivial state value copying
- PartialEq: For state equality checks
- Eq: For total equality (no partial comparisons)

---

### State Transition Functions

**Function: can_transition_to**

```rust
impl SnapshotState {
    /// Check if transition to target state is valid
    ///
    /// # Returns
    /// - true: Transition is allowed
    /// - false: Transition would violate state machine rules
    pub fn can_transition_to(self, target: SnapshotState) -> bool {
        match (self, target) {
            // Valid transitions
            (Self::Committed, Self::Active) => true,  // Time-travel query
            (Self::Active, Self::Aborted) => true,     // Explicit close/abort

            // Invalid transitions
            (Self::Active, Self::Committed) => false,  // Snapshots don't commit
            (Self::Aborted, _) => false,               // Terminal state
            (Self::Active, Self::Active) => false,     // Already in state

            // All other combinations are context-dependent
            // and should be validated at call site with
            // additional conditions (reference counts, etc.)
            _ => false,
        }
    }
}
```

**Function: is_active**

```rust
impl SnapshotState {
    /// Returns true if snapshot is in Active state
    pub fn is_active(self) -> bool {
        matches!(self, Self::Active)
    }
}
```

**Function: is_committed**

```rust
impl SnapshotState {
    /// Returns true if snapshot is in Committed state
    pub fn is_committed(self) -> bool {
        matches!(self, Self::Committed)
    }
}
```

**Function: is_terminal**

```rust
impl SnapshotState {
    /// Returns true if snapshot is in a terminal state (no further transitions)
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Aborted)
    }
}
```

**Function: allows_reads**

```rust
impl SnapshotState {
    /// Returns true if read operations are allowed in this state
    pub fn allows_reads(self) -> bool {
        matches!(self, Self::Active)
    }
}
```

---

### Snapshot Structure with State

**Snapshot Handle Struct**

```rust
/// Handle representing a snapshot at a specific transaction
///
/// The snapshot provides a consistent, immutable view of the database
/// as of the transaction identified by txn_id.
pub struct Snapshot {
    /// Transaction ID defining the snapshot boundary
    txn_id: TransactionId,

    /// Root page of the B+tree for this snapshot
    root_page_id: PageId,

    /// Database reference (keeps database alive)
    db: Arc<DbInner>,

    /// Current state of this snapshot handle
    state: SnapshotState,
}

impl Snapshot {
    /// Create a new snapshot in Active state
    pub fn new(txn_id: TransactionId, root_page_id: PageId, db: Arc<DbInner>) -> Self {
        Self {
            txn_id,
            root_page_id,
            db,
            state: SnapshotState::Active,
        }
    }

    /// Get the current state of this snapshot
    pub fn state(&self) -> SnapshotState {
        self.state
    }

    /// Check if this snapshot is Active and usable
    pub fn is_active(&self) -> bool {
        self.state.is_active()
    }
}
```

---

### Registry Entry Structure

**Snapshot Registry Entry**

```rust
/// Entry in the snapshot registry tracking a committed transaction
pub struct RegistryEntry {
    /// Root page ID for this transaction's B+tree
    root_page_id: PageId,

    /// LSN of this transaction's commit record
    commit_lsn: Lsn,

    /// Number of active snapshot handles referencing this entry
    reference_count: AtomicUsize,

    /// State of this registry entry
    state: SnapshotState,
}

impl RegistryEntry {
    /// Create new registry entry for a committed transaction
    pub fn new(root_page_id: PageId, commit_lsn: Lsn) -> Self {
        Self {
            root_page_id,
            commit_lsn,
            reference_count: AtomicUsize::new(0),
            state: SnapshotState::Committed,
        }
    }

    /// Increment reference count (called when snapshot handle is created)
    pub fn increment_ref(&self) {
        self.reference_count.fetch_add(1, Ordering::AcqRel);
    }

    /// Decrement reference count (called when snapshot handle is dropped)
    ///
    /// Returns true if reference count reached zero
    pub fn decrement_ref(&self) -> bool {
        self.reference_count.fetch_sub(1, Ordering::AcqRel) == 1
    }

    /// Get current reference count
    pub fn ref_count(&self) -> usize {
        self.reference_count.load(Ordering::Acquire)
    }
}
```

---

### State Transition Implementation

**Snapshot Creation (Committed → Active)**

```rust
impl SnapshotRegistry {
    /// Create an Active snapshot handle from a committed registry entry
    pub fn create_snapshot(&self, txn_id: TransactionId) -> Result<Snapshot, SnapshotError> {
        // Step 1: Acquire read lock on registry
        let registry = self.snapshots.read().unwrap();

        // Step 2: Look up transaction in registry
        let entry = registry.get(&txn_id)
            .ok_or(SnapshotError::TransactionNotFound { txn_id })?;

        // Step 3: Validate state is Committed
        if !entry.state.is_committed() {
            return Err(SnapshotError::InvalidSnapshotState {
                txn_id,
                expected: SnapshotState::Committed,
                actual: entry.state,
            });
        }

        // Step 4: Increment reference count
        entry.increment_ref();

        // Step 5: Create snapshot handle in Active state
        drop(registry); // Release lock before allocating snapshot
        Ok(Snapshot::new(
            txn_id,
            entry.root_page_id,
            Arc::clone(&self.db),
        ))
    }
}
```

**Snapshot Expiration (Active → Aborted/Expired)**

```rust
impl Drop for Snapshot {
    fn drop(&mut self) {
        // Step 1: Get registry entry
        let registry = self.db.snapshot_registry.snapshots.read().unwrap();
        let entry = match registry.get(&self.txn_id) {
            Some(e) => e,
            None => return, // Registry already cleaned up
        };

        // Step 2: Decrement reference count
        let last_ref = entry.decrement_ref();

        // Step 3: If last reference, signal cleanup
        if last_ref {
            // Mark as eligible for cleanup
            // Actual cleanup happens asynchronously or on next cleanup call
            self.db.snapshot_registry.queue_for_cleanup(self.txn_id);
        }
    }
}
```

---

### Concurrency Considerations

**Thread Safety**:

**SnapshotState enum**: Safe to share between threads
- derives Copy, Clone, Send, Sync
- No internal mutable state
- Can be freely copied and sent between threads

**RegistryEntry reference counting**: Uses AtomicUsize
- Multiple threads can increment/decrement concurrently
- Uses AcqRel ordering for proper synchronization
- Lock-free reference count operations

**Snapshot handles**: Not designed for concurrent mutation
- Each handle is owned by a single thread
- Drop trait handles thread-safe cleanup
- Arc<DbInner> allows shared database access

**Lock strategy**:
- Registry HashMap protected by RwLock
- Multiple readers can hold shared lock
- Writers (commits, cleanup) acquire exclusive lock
- Reference counting uses atomics (no lock needed)

---

### Error Handling

**State-related errors**:

```rust
#[derive(Debug, thiserror::Error)]
pub enum SnapshotError {
    /// Requested transaction ID not found in registry
    #[error("Transaction {txn_id} not found in snapshot registry")]
    TransactionNotFound {
        txn_id: TransactionId,
    },

    /// Snapshot is in wrong state for requested operation
    #[error("Snapshot {txn_id} is in {actual:?} state, expected {expected:?}")]
    InvalidSnapshotState {
        txn_id: TransactionId,
        expected: SnapshotState,
        actual: SnapshotState,
    },

    /// Snapshot has expired and is no longer usable
    #[error("Snapshot {txn_id} has expired")]
    SnapshotExpired {
        txn_id: TransactionId,
    },
}
```

---

### Testing Strategy

**Unit tests needed for**:
1. State transition validation (can_transition_to)
2. State predicate functions (is_active, is_committed, is_terminal, allows_reads)
3. Reference counting accuracy (increment/decrement match actual handles)
4. Registry entry creation and cleanup
5. Snapshot creation from committed entries

**Property tests for**:
1. State machine correctness: All valid transitions work, invalid transitions fail
2. Reference count monotonicity: Never negative, accurate to handle count
3. State immutability: Snapshot handle state doesn't change unexpectedly

**Integration scenarios**:
1. Create snapshot → verify Active state → verify reads work
2. Drop all handles → verify cleanup triggers
3. Time-travel query → verify Committed → Active transition
4. Concurrent snapshot creation → verify no race conditions
5. Crash during snapshot use → verify recovery restores correct state

**Concurrency tests**:
1. Multiple threads create snapshots simultaneously
2. One thread drops snapshot while another reads
3. Cleanup runs while snapshots are in use
4. Registry updates (commits) during snapshot creation

---

### Performance Considerations

**State checks are cheap**:
- enum comparison is O(1)
- no heap allocations
- branch predictor-friendly

**Reference counting**:
- Atomic operations are fast (single CPU instruction on x86_64)
- Cache line contention possible with high concurrency
- Consider per-cache-line reference counters if profiling shows contention

**State transitions**:
- Creation: O(1) registry lookup + atomic increment
- Expiration: O(1) atomic decrement
- Cleanup: O(N) where N = number of expired snapshots (batched)

**Memory overhead**:
- SnapshotState: 1 byte (enum discriminant)
- RegistryEntry: ~32 bytes (root_page_id, commit_lsn, reference_count, state)
- Per snapshot: ~24 bytes handle + 1 byte state

---

## Appendix

### Related Specifications

- [05-snapshot-overview.md](./05-snapshot-overview.md) - Overall MVCC design and snapshot philosophy
- [05-snapshot-registry.md](./05-snapshot-registry.md) - SnapshotRegistry implementation details
- [05-snapshot-create.md](./05-snapshot-create.md) - Snapshot creation process
- [05-snapshot-cleanup.md](./05-snapshot-cleanup.md) - Garbage collection and cleanup policies
- [03-wal-lsn.md](./03-wal-lsn.md) - LSN allocation and tracking in the WAL
- [04-txn-commit.md](./04-txn-commit.md) - Transaction commit creates new snapshots

### Terminology

| Term | Definition |
|------|------------|
| **SnapshotState** | Enum representing the lifecycle state of a snapshot (Active, Committed, Aborted) |
| **Active** | Snapshot is currently in use by one or more readers |
| **Committed** | Snapshot exists in registry for a committed transaction (can create Active handles from it) |
| **Aborted** | Snapshot was invalidated and is no longer usable (terminal state) |
| **Expired** | Snapshot is no longer in use and can be cleaned up |
| **State transition** | Change from one state to another following defined rules |
| **Reference count** | Number of active snapshot handles referencing a registry entry |
| **State machine** | Model of valid states and transitions for snapshot lifecycle |

### Open Questions

1. **State persistence**: Should snapshot state be persisted anywhere? Currently no - state is reconstructed from registry on recovery. (Decision: No, state is derived from registry, not persisted separately.)

2. **State queries**: Should public API expose snapshot state queries? (Decision: Yes, for debugging and monitoring - is_active(), get_state() methods)

3. **State change notifications**: Should applications be notified when snapshots expire? (Decision: No, explicit cleanup only. Implicit expiration is internal detail.)

---

**Next**: [Task 5.7 - MVCC Isolation Guarantees](../rust/todo-rust.md#task-57)
