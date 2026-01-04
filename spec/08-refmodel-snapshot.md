# Reference Model: Historical State Tracking

**Phase**: 8
**Task**: 8.4
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [Snapshot Management](#snapshot-management)
3. [Snapshot History](#snapshot-history)
4. [Time-Travel Queries](#time-travel-queries)
5. [Snapshot Lifecycle](#snapshot-lifecycle)
6. [Retention & Cleanup](#retention--cleanup)
7. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

Historical state tracking is the reference model's mechanism for maintaining and accessing past database states. This capability enables **time-travel queries**, **snapshot isolation**, and **crash recovery verification**.

Each committed transaction creates a new snapshot, preserving the complete database state at that point in time. Snapshots are immutable and can be queried independently, allowing the database to "remember" its entire history.

---

## Snapshot Management

### Snapshot Creation

### create_snapshot(parent: &SnapshotState, writes: &BTreeMap<KeyBytes, Option<ValueBytes>>, new_txn_id: TxnId) -> SnapshotState

**Purpose**: Create a new snapshot by applying writes to a parent snapshot.

**Parameters**:
- **parent**: Reference to the base snapshot (immutable)
- **writes**: Ordered map of key changes to apply
- **new_txn_id**: Transaction ID to assign to the new snapshot

**Returns**:
- **SnapshotState**: New snapshot incorporating all writes

**Algorithm**:

1. Verify new_txn_id == parent.txn_id + 1:
   a. If not, panic or return error (transaction IDs must be sequential)
2. Clone parent's tree structure:
   a. Start with copy of parent.tree (deep copy or copy-on-write)
3. Apply each write in sorted order:
   a. For each (key, opt_value) in writes.iter() (sorted by key):
      - If opt_value is Some(value):
        * Call tree.insert(key, value) or tree.update(key, value)
      - If opt_value is None:
        * Call tree.delete(key) (ignore if not found)
4. Create new SnapshotState {
   a. tree: modified_tree
   b. txn_id: new_txn_id
   c. parent_txn_id: Some(parent.txn_id)
   d. timestamp: parent.timestamp + 1 (or monotonic counter)
   }
5. Return new snapshot

**Error Conditions**:
- **SnapshotError::InvalidTxnId**: new_txn_id is not parent.txn_id + 1
- **SnapshotError::WriteConflict**: If conflict detection enabled and conflict detected

**Complexity**:
- **Time**: O(W * log(N)) where W is number of writes, N is number of keys
- **Space**: O(N) for new tree copy (depends on copy strategy)

**Invariants**:
- New snapshot's tree equals parent's tree with writes applied
- new_txn_id is strictly greater than parent.txn_id
- Parent snapshot remains unchanged
- New snapshot is immutable once created

---

### Snapshot Lookup

### get_snapshot(model: &RefModel, txn_id: TxnId) -> Result<Arc<SnapshotState>, SnapshotError>

**Purpose**: Retrieve a historical snapshot by transaction ID.

**Parameters**:
- **model**: Reference to RefModel
- **txn_id**: Transaction ID of snapshot to retrieve

**Returns**:
- **Ok(Arc<SnapshotState>)**: Reference to requested snapshot
- **Err(SnapshotError::NotFound)**: Snapshot with txn_id doesn't exist

**Algorithm**:

1. Check if model.snapshots contains txn_id:
   a. If yes, return Ok(Arc::clone(model.snapshots[txn_id]))
   b. If no, return Err(SnapshotError::NotFound)

**Error Conditions**:
- **SnapshotError::NotFound**: Requested txn_id not in snapshots map
- **SnapshotError::InvalidTxnId**: txn_id is 0 (initial state) or negative

**Complexity**:
- **Time**: O(log(S)) where S is number of snapshots (BTreeMap lookup)
- **Space**: O(1) (just Arc clone)

**Invariants**:
- Returned snapshot is immutable
- Multiple callers can receive same snapshot (shared Arc)
- Snapshot remains valid as long as at least one reference exists

---

### Latest Snapshot

### get_latest_snapshot(model: &RefModel) -> Arc<SnapshotState>

**Purpose**: Get the most recent snapshot (current database state).

**Parameters**:
- **model**: Reference to RefModel

**Returns**:
- **Arc<SnapshotState>**: Reference to current snapshot

**Algorithm**:

1. Return Arc::clone(model.current_state)

**Error Conditions**:
- None (model always has at least initial snapshot)

**Complexity**:
- **Time**: O(1) (just Arc clone)
- **Space**: O(1)

**Invariants**:
- Returned snapshot is the most recent committed state
- Snapshot's txn_id equals model.current_txn_id
- Snapshot is immutable

---

## Snapshot History

### History Storage

### HistoryMap: BTreeMap<TxnId, Arc<SnapshotState>>

**Description**: Ordered map storing all snapshots indexed by transaction ID.

**Invariants**:
- Contains entry for txn_id 0 (initial empty state)
- Contains entry for each committed transaction
- For any i < j, history[i].txn_id < history[j].txn_id
- No gaps: if history contains txn_id k, it contains all txn_id from 0 to k

**Operations**:
- **Insert**: Add new snapshot at txn_id (only at current_txn_id + 1)
- **Lookup**: Retrieve snapshot by txn_id (O(log(S)))
- **Range query**: Get snapshots in txn_id range [a, b]

### History Traversal

### iter_history(model: &RefModel, start: Option<TxnId>) -> HistoryIterator

**Purpose**: Create an iterator over historical snapshots starting from a specific transaction ID.

**Parameters**:
- **model**: Reference to RefModel
- **start**: Starting txn_id (inclusive), or None for beginning (txn_id 0)

**Returns**:
- **HistoryIterator**: Iterator yielding (TxnId, Arc<SnapshotState>) in txn_id order

**Algorithm**:

1. Determine starting point:
   a. If start is None, start = 0
   b. If start is Some(i), start = i
2. Create iterator over model.snapshots.range(start..):
   a. Yield (txn_id, snapshot) pairs in ascending order
3. Return iterator

**Error Conditions**:
- None (if start txn_id doesn't exist, iterator starts from next available)

**Complexity**:
- **Time**: O(1) to create, O(log(S)) to find start position
- **Space**: O(1)

**Invariants**:
- Yields snapshots in strictly increasing txn_id order
- Each snapshot appears exactly once
- Iterator doesn't prevent new snapshots from being added (but won't see them)

---

### History Replay

### replay_history(model: &RefModel, start_txn_id: TxnId, end_txn_id: TxnId) -> Result<(), ReplayError>

**Purpose**: Verify that snapshots from start_txn_id to end_txn_id form a valid derivation chain.

**Parameters**:
- **model**: Reference to RefModel
- **start_txn_id**: First transaction in range to verify
- **end_txn_id**: Last transaction in range to verify

**Returns**:
- **Ok(())**: All snapshots in range are valid derivations
- **Err(ReplayError::Gap)**: Missing snapshot in range
- **Err(ReplayError::InvalidDerivation)**: Snapshot doesn't derive from parent

**Algorithm**:

1. Verify model.snapshots contains all txn_id from start_txn_id to end_txn_id:
   a. For i in start_txn_id..=end_txn_id:
      - If snapshots[i] doesn't exist, return Err(ReplayError::Gap(i))
2. For each txn_id from start_txn_id + 1 to end_txn_id:
   a. current = snapshots[txn_id]
   b. expected_parent = snapshots[txn_id - 1]
   c. Verify current.parent_txn_id == Some(txn_id - 1):
      - If not, return Err(ReplayError::InvalidDerivation(txn_id))
   d. Verify current.tree equals expected_parent.tree with writes applied:
      - Get writes from current.txn_id (need to store writes in snapshot or elsewhere)
      - Re-apply writes to expected_parent.tree
      - Compare result to current.tree
      - If not equal, return Err(ReplayError::InvalidDerivation(txn_id))
3. Return Ok(())

**Error Conditions**:
- **ReplayError::Gap**: Missing snapshot in range
- **ReplayError::InvalidDerivation**: Snapshot doesn't correctly derive from parent
- **ReplayError::InvalidRange**: start_txn_id > end_txn_id or out of bounds

**Complexity**:
- **Time**: O((E - S) * N) where E is end_txn_id, S is start_txn_id, N is number of keys
- **Space**: O(N) for temporary tree during re-application

**Invariants**:
- If verification succeeds, history is correct and reproducible
- All snapshots in range are reachable from initial state
- Each snapshot is a valid derivation of its parent

---

## Time-Travel Queries

### Time-Travel Read

### read_at_time(model: &RefModel, txn_id: TxnId, key: &KeyBytes) -> Result<Option<ValueBytes>, ReadError>

**Purpose**: Read a key's value as of a specific historical transaction.

**Parameters**:
- **model**: Reference to RefModel
- **txn_id**: Historical point to read at
- **key**: Key to look up

**Returns**:
- **Ok(Some(value))**: Key's value at txn_id
- **Ok(None)**: Key not present at txn_id
- **Err(ReadError::SnapshotNotFound)**: txn_id doesn't exist

**Algorithm**:

1. Retrieve snapshot at txn_id:
   a. Call model.get_snapshot(txn_id)
   b. If error, propagate
2. Look up key in snapshot.tree:
   a. Call snapshot.tree.lookup(key)
   b. Return result

**Error Conditions**:
- **ReadError::SnapshotNotFound**: txn_id doesn't exist in history
- **ReadError::InvalidKey**: Key is invalid (e.g., too large)

**Complexity**:
- **Time**: O(log(S) + height * log(fanout)) where S is number of snapshots
- **Space**: O(1)

**Invariants**:
- Returns value as of exactly txn_id
- Doesn't affect current state or any snapshots
- Multiple time-travel reads can execute concurrently

---

### Time-Travel Scan

### scan_at_time(model: &RefModel, txn_id: TxnId, range: (KeyBytes, KeyBytes)) -> Result<ForwardIterator, ScanError>

**Purpose**: Scan keys in a range as of a specific historical transaction.

**Parameters**:
- **model**: Reference to RefModel
- **txn_id**: Historical point to scan at
- **range**: (start, end) key bounds [start, end)

**Returns**:
- **Ok(ForwardIterator)**: Iterator over keys in range at txn_id
- **Err(ScanError::SnapshotNotFound)**: txn_id doesn't exist

**Algorithm**:

1. Retrieve snapshot at txn_id:
   a. Call model.get_snapshot(txn_id)
   b. If error, propagate
2. Create range iterator on snapshot.tree:
   a. Call snapshot.tree.iter_range(start, end)
   b. Return iterator

**Error Conditions**:
- **ScanError::SnapshotNotFound**: txn_id doesn't exist
- **ScanError::InvalidRange**: start >= end

**Complexity**:
- **Time**: O(log(S) + height * log(fanout)) to create iterator
- **Space**: O(1)

**Invariants**:
- Iterator yields keys in range as of txn_id
- Iterator doesn't see changes after txn_id
- Snapshot remains immutable during iteration

---

### Historical Comparison

### compare_states(model: &RefModel, txn_id1: TxnId, txn_id2: TxnId) -> Result<StateDiff, CompareError>

**Purpose**: Compare database states at two different points in time.

**Parameters**:
- **model**: Reference to RefModel
- **txn_id1**: First point in time
- **txn_id2**: Second point in time

**Returns**:
- **Ok(StateDiff)**: Differences between the two snapshots
- **Err(CompareError::SnapshotNotFound)**: One or both txn_ids don't exist

**StateDiff Structure**:
- **added**: Set of keys present in txn_id2 but not txn_id1
- **removed**: Set of keys present in txn_id1 but not txn_id2
- **modified**: Map of keys with different values in each snapshot

**Algorithm**:

1. Retrieve both snapshots:
   a. snapshot1 = model.get_snapshot(txn_id1)?
   b. snapshot2 = model.get_snapshot(txn_id2)?
2. Compare trees:
   a. Create empty StateDiff
   b. Iterate through all keys in snapshot1.tree:
      - If key not in snapshot2.tree, add to diff.removed
      - If values differ, add to diff.modified
   c. Iterate through all keys in snapshot2.tree:
      - If key not in snapshot1.tree, add to diff.added
3. Return StateDiff

**Error Conditions**:
- **CompareError::SnapshotNotFound**: One or both txn_ids don't exist
- **CompareError::ComparisonFailed**: Error during comparison

**Complexity**:
- **Time**: O(N + M) where N is keys in snapshot1, M is keys in snapshot2
- **Space**: O(N + M) for diff result

**Invariants**:
- If snapshots are equal, all diff fields are empty
- If snapshots are different, diff captures all changes
- Comparison is symmetric (compare_states(a, b) == inverse of compare_states(b, a))

---

## Snapshot Lifecycle

### Initialization

### initialize_history() -> RefModel

**Purpose**: Create a new RefModel with initial empty snapshot.

**Parameters**: None

**Returns**:
- **RefModel**: New model with txn_id 0 (empty state)

**Algorithm**:

1. Create empty B+Tree:
   a. tree = BTree::new() (root is empty LeafNode)
2. Create initial snapshot:
   a. snapshot = SnapshotState {
      * tree: empty_tree
      * txn_id: 0
      * parent_txn_id: None
      * timestamp: 0
      }
3. Create RefModel:
   a. model = RefModel {
      * current_txn_id: 0
      * snapshots: BTreeMap with entry {0: Arc::new(snapshot)}
      * current_state: Arc::new(snapshot)
      * min_retained_txn_id: 0
      }
4. Return model

**Error Conditions**: None

**Complexity**:
- **Time**: O(1) (create empty structures)
- **Space**: O(1)

**Invariants**:
- Model has exactly one snapshot (txn_id 0)
- current_txn_id equals 0
- current_state points to empty snapshot

---

### Snapshot Extension

### extend_history(model: &mut RefModel, writes: BTreeMap<KeyBytes, Option<ValueBytes>>) -> TxnId

**Purpose**: Create a new snapshot from writes and add it to history.

**Parameters**:
- **model**: Mutable reference to RefModel
- **writes**: Writes to apply (from a committed transaction)

**Returns**:
- **TxnId**: Transaction ID assigned to new snapshot

**Algorithm**:

1. Determine new transaction ID:
   a. new_txn_id = model.current_txn_id + 1
2. Create new snapshot:
   a. new_snapshot = create_snapshot(model.current_state, &writes, new_txn_id)
3. Add to history:
   a. model.snapshots.insert(new_txn_id, Arc::new(new_snapshot))
   b. model.current_txn_id = new_txn_id
   c. model.current_state = Arc::new(new_snapshot)
4. Return new_txn_id

**Error Conditions**:
- **HistoryError::InvalidState**: Model is in inconsistent state

**Complexity**:
- **Time**: O(W * log(N)) for snapshot creation
- **Space**: O(N) for new snapshot

**Invariants**:
- new_txn_id is exactly previous current_txn_id + 1
- model.current_state points to new snapshot
- model.snapshots contains new snapshot
- Parent snapshot is unchanged

---

### Snapshot Retirement

### retire_snapshots(model: &mut RefModel, before_txn_id: TxnId)

**Purpose**: Remove snapshots older than before_txn_id to free memory (for testing cleanup).

**Parameters**:
- **model**: Mutable reference to RefModel
- **before_txn_id**: Remove all snapshots with txn_id < before_txn_id

**Returns**: None

**Algorithm**:

1. For each txn_id from model.min_retained_txn_id to before_txn_id - 1:
   a. If Arc::strong_count(snapshots[txn_id]) == 1:
      - No other references, safe to remove
      - model.snapshots.remove(txn_id)
   b. Else:
      - Other references exist (e.g., active ReadTxn)
      - Skip this snapshot (will be cleaned up later)
2. Update model.min_retained_txn_id = before_txn_id

**Error Conditions**:
- **HistoryError::InvalidRange**: before_txn_id > current_txn_id or <= 0

**Complexity**:
- **Time**: O(R * log(S)) where R is number of snapshots removed
- **Space**: O(1) (frees memory as snapshots are dropped)

**Invariants**:
- All remaining snapshots have txn_id >= before_txn_id
- Snapshots with active references are preserved
- model.current_state is never removed

---

## Retention & Cleanup

### Retention Policy

### RetentionPolicy: Enum

**Description**: Policy for how long to retain historical snapshots.

**Variants**:

#### RetainAll

**Description**: Keep all snapshots forever (default for testing).

**Invariants**:
- No snapshots are ever removed
- Memory usage grows monotonically
- min_retained_txn_id always equals 0

#### RetainLast(n)

**Description**: Keep only the last n snapshots.

**Fields**:
- **n**: usize - Number of recent snapshots to retain

**Invariants**:
- Snapshots with txn_id < current_txn_id - n are eligible for cleanup
- At least n snapshots always retained
- Memory usage is bounded

#### RetainSince(txn_id)

**Description**: Keep all snapshots from txn_id onwards.

**Fields**:
- **txn_id**: TxnId - Oldest snapshot to retain

**Invariants**:
- Snapshots with txn_id < this.txn_id are eligible for cleanup
- At least one snapshot always retained (current)

### Cleanup Trigger

### cleanup_snapshots(model: &mut RefModel, policy: &RetentionPolicy)

**Purpose**: Apply retention policy and remove eligible snapshots.

**Parameters**:
- **model**: Mutable reference to RefModel
- **policy**: RetentionPolicy to apply

**Returns**: None

**Algorithm**:

1. Determine cutoff based on policy:
   a. If RetainAll: return (no cleanup)
   b. If RetainLast(n): cutoff = max(0, model.current_txn_id - n)
   c. If RetainSince(txn_id): cutoff = txn_id
2. Call retire_snapshots(model, cutoff)

**Error Conditions**:
- **CleanupError::InvalidPolicy**: Policy parameters are invalid

**Complexity**:
- **Time**: O(R * log(S)) where R is number of snapshots removed
- **Space**: O(1) (frees memory)

**Invariants**:
- After cleanup, all retained snapshots match policy
- Snapshots with active references are preserved
- Current snapshot is never removed

---

### Reference Counting

### Snapshot References

**Description**: Snapshots use Arc for automatic reference counting.

**Invariants**:
- Arc::strong_count(snapshot) >= 1 (snapshot exists)
- When strong_count drops to 0, snapshot is deallocated
- Cleanup only removes snapshots with strong_count == 1 (only RefModel holds reference)

**Reference Sources**:
- **RefModel.snapshots**: Always holds reference
- **RefModel.current_state**: Always holds reference (may duplicate snapshots entry)
- **ReadTxn.snapshot**: Holds reference while transaction active
- **Iterators**: Hold reference while iterating
- **Time-travel queries**: Hold reference for duration of query

**Cleanup Safety**:
- Before removing snapshot from snapshots map, check strong_count
- If strong_count > 1, other references exist (e.g., active ReadTxn)
- Skip cleanup for this snapshot, try again later
- When other references released, snapshot becomes eligible for cleanup

---

## Rust Implementation Guidance

### Module Structure

Snapshot history management should be organized as:

```
ref_model/
├── snapshot/
│   ├── mod.rs              # Snapshot public API
│   ├── state.rs            # SnapshotState struct
│   ├── history.rs          # HistoryMap and traversal
│   ├── retention.rs        # RetentionPolicy and cleanup
│   └── time_travel.rs      # Time-travel query operations
└── model.rs                # RefModel with history management
```

### Type Definitions

#### Use Arc for Shared Snapshots

```rust
use std::sync::Arc;

pub struct SnapshotState {
    tree: BTree,
    txn_id: TxnId,
    // ...
}

pub struct HistoryMap {
    snapshots: BTreeMap<TxnId, Arc<SnapshotState>>,
}
```

**Benefits**:
- Cheap cloning (reference count increment)
- Thread-safe reference counting
- Automatic cleanup when no references exist
- Clear ownership semantics

#### Use BTreeMap for Ordered History

```rust
use std::collections::BTreeMap;

pub struct RefModel {
    snapshots: BTreeMap<TxnId, Arc<SnapshotState>>,
    current_txn_id: TxnId,
    // ...
}
```

**Benefits**:
- Ordered by txn_id (natural ordering)
- Efficient range queries
- Logarithmic lookup, insert, delete
- Iteration in txn_id order

### Concurrency

#### Arc Enables Safe Concurrent Access

```rust
pub struct ReadTxn {
    snapshot: Arc<SnapshotState>,
    // ...
}

// Multiple threads can hold references to same snapshot
let txn1 = ReadTxn { snapshot: Arc::clone(&snapshot) };
let txn2 = ReadTxn { snapshot: Arc::clone(&snapshot) };
// Both txn1 and txn2 can read concurrently
```

**Benefits**:
- No locking needed (snapshots are immutable)
- Readers don't block each other
- Reference counting prevents premature cleanup
- Thread-safe by construction

#### Cleanup Checks Reference Count

```rust
fn cleanup_snapshots(model: &mut RefModel, cutoff: TxnId) {
    for (&txn_id, snapshot) in model.snapshots.range(..cutoff) {
        if Arc::strong_count(snapshot) == 1 {
            // Only RefModel holds reference, safe to remove
            model.snapshots.remove(&txn_id);
        }
    }
}
```

**Benefits**:
- Won't remove snapshots in use
- Safe concurrent cleanup
- Automatic retention of active snapshots

### Key Decisions

#### Store Writes in Snapshot vs Separate
**Decision**: Store writes separately from snapshot

**Reason**:
- Snapshot is immutable (writes are transaction-specific)
- Writes needed for commit processing, not snapshot queries
- Smaller snapshot objects (less memory)
- Clear separation of concerns

#### Full Copy vs Structural Sharing
**Decision**: Use full copy of tree for new snapshot

**Reason**:
- Simpler implementation (no persistent data structures)
- Easier to reason about (independent snapshots)
- Test workloads are small (copying is acceptable)
- Straightforward serialization for comparison

#### Cleanup: Eager vs Lazy
**Decision**: Use lazy cleanup triggered by retention policy

**Reason**:
- Simpler implementation (no background threads)
- Deterministic cleanup (explicit trigger)
- Testable (can verify cleanup behavior)
- No concurrency concerns (single-threaded)

### Implementation Notes

#### Step 1: Snapshot Creation
Implement create_snapshot function:
- Clone parent tree
- Apply writes in sorted order
- Create new SnapshotState
- Verify invariants

#### Step 2: History Storage
Implement history management:
- BTreeMap to store snapshots by txn_id
- get_snapshot, get_latest_snapshot functions
- iter_history for traversal

#### Step 3: Time-Travel Queries
Implement time-travel operations:
- read_at_time: get snapshot, lookup key
- scan_at_time: get snapshot, create iterator
- compare_states: diff two snapshots

#### Step 4: Retention & Cleanup
Implement retention policy:
- Define RetentionPolicy enum
- Implement cleanup_snapshots
- Check Arc::strong_count before removal
- Update min_retained_txn_id

### Testing Strategy

#### Unit Tests Needed For

**Snapshot Creation**:
- Create snapshot from empty parent
- Create snapshot with puts, deletes
- Verify parent unchanged
- Verify txn_id sequence

**History Storage**:
- Insert snapshots in order
- Lookup by txn_id
- Iterate history
- Verify no gaps

**Time-Travel Queries**:
- Read key at historical txn_id
- Scan range at historical txn_id
- Compare two snapshots
- Verify results correct

**Retention & Cleanup**:
- RetainAll: no snapshots removed
- RetainLast(n): only n recent kept
- RetainSince: older snapshots removed
- Active snapshots preserved (strong_count > 1)

#### Property Tests For

**Snapshot Derivation**:
- Each snapshot derives from parent (txn_id - 1)
- Applying writes to parent produces child
- Reverse: removing child writes produces parent

**History Consistency**:
- txn_ids are sequential (no gaps)
- parent_txn_id forms chain to root
- timestamps are monotonically increasing

**Cleanup Safety**:
- Cleanup never removes current snapshot
- Cleanup preserves active snapshots
- After cleanup, policy invariants hold

#### Integration Scenarios

**History Replay**:
- Commit 100 transactions
- Replay from txn_id 0 to 100
- Verify each step reproduces snapshot

**Time-Travel Validation**:
- Commit sequence of puts and deletes
- Query each historical state
- Verify each query returns correct value

**Retention Under Load**:
- Create 1000 snapshots
- Create ReadTxn on random snapshots
- Apply RetainLast(100)
- Verify active snapshots preserved
- Verify older snapshots cleaned up

---

## Summary

Historical state tracking provides:

- **Complete history**: Every committed transaction creates a snapshot
- **Time-travel queries**: Read and scan as of any historical point
- **Immutable snapshots**: Concurrent access without coordination
- **Flexible retention**: Policies control memory usage
- **Safe cleanup**: Reference counting prevents use-after-free

This capability enables **crash recovery verification** (replay history to reach expected state) and **correctness checking** (compare snapshots at different points).
