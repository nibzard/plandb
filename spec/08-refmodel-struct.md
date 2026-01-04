# Reference Model: In-Memory Structure

**Phase**: 8
**Task**: 8.2
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [B+Tree Node Structure](#btree-node-structure)
3. [B+Tree Container](#btree-container)
4. [Snapshot State](#snapshot-state)
5. [Transaction Types](#transaction-types)
6. [Reference Model State](#reference-model-state)
7. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

This specification details the in-memory data structures used in the reference model implementation. These structures prioritize **clarity and correctness** over performance, using straightforward representations that are easy to understand, validate, and compare.

All structures are designed for:
- **Deterministic behavior**: No non-deterministic choices
- **Explicit state**: All data directly observable
- **Easy validation**: Invariants are checkable
- **Simple serialization**: Canonical form for comparison

---

## B+Tree Node Structure

### Node: Enum (Internal or Leaf)

**Description**: A B+Tree node is either an internal node (contains pointers to child nodes and separator keys) or a leaf node (contains actual key-value pairs).

**Variants**:

#### InternalNode

**Description**: Non-leaf node that routes lookups to child nodes based on key ranges.

**Fields**:
- **keys**: Vec<KeyBytes> - Separator keys that divide key ranges between children. If keys = [k1, k2, k3], then:
  - Child 0 handles keys < k1
  - Child 1 handles keys >= k1 and < k2
  - Child 2 handles keys >= k2 and < k3
  - Child 3 handles keys >= k3

- **children**: Vec<Box<Node>> - Child node references. Length is always keys.len() + 1.

**Invariants**:
- All keys in children[i] are less than keys[i] (for i < children.len() - 1)
- All keys in children[i] are greater than or equal to keys[i-1] (for i > 0)
- keys.len() >= 1 and keys.len() <= MAX_FANOUT - 1 (fanout limits apply differently)
- children.len() >= 2 (internal nodes must have at least 2 children)

**Size**: Dynamic (Vecs grow as needed)

**Alignment**: Standard pointer alignment

#### LeafNode

**Description**: Leaf node containing actual key-value pairs.

**Fields**:
- **entries**: Vec<(KeyBytes, ValueBytes)> - Ordered list of key-value pairs. Keys are strictly increasing.

- **next**: Option<Box<Node>> - Pointer to next leaf node (for forward iteration). None for last leaf.

- **prev**: Option<Box<Node>> - Pointer to previous leaf node (for reverse iteration). None for first leaf.

**Invariants**:
- entries.len() >= 1 and entries.len() <= MAX_ENTRIES
- entries[i].0 < entries[i+1].0 for all valid i (strictly increasing keys)
- If next is Some, all keys in this node are less than all keys in next
- If prev is Some, all keys in this node are greater than all keys in prev
- next.prev == Some(this) and prev.next == Some(this) (doubly-linked)

**Size**: Dynamic (Vec grows as needed)

**Alignment**: Standard pointer alignment

### KeyBytes: Newtype Wrapper

**Description**: Wrapper around Vec<u8> providing type safety and consistent ordering semantics.

**Inner Representation**: Vec<u8>

**Invariants**:
- Bytes can be of any length (including empty)
- Ordering uses lexicographic byte comparison
- No special treatment of null bytes or encoding

**Operations**:
- **Comparison**: Compare byte-by-byte, shorter is less if prefix matches
- **Hashing**: Hash all bytes
- **Serialization**: Length prefix + bytes

### ValueBytes: Newtype Wrapper

**Description**: Wrapper around Vec<u8> for values (similar to KeyBytes but no ordering requirement).

**Inner Representation**: Vec<u8>

**Invariants**:
- Bytes can be of any length (including empty)
- No ordering semantics applied
- Empty value represents deletion tombstone in some contexts

---

## B+Tree Container

### BTree: Struct

**Description**: Container managing the root node and tree-wide configuration.

**Fields**:

#### root: Box<Node>

**Description**: Root node of the B+Tree. Can be InternalNode or LeafNode.

**Invariants**:
- If tree is empty, root is a LeafNode with empty entries
- If tree has one entry, root is a LeafNode with one entry
- If tree has > MAX_ENTRIES entries, root is InternalNode

#### height: usize

**Description**: Current height of the tree (number of levels from root to leaf). Leaf level is 0.

**Invariants**:
- Empty tree: height = 0 (root is empty LeafNode)
- Single-level tree: height = 1 (root is LeafNode)
- Multi-level tree: height >= 2 (root is InternalNode)

#### count: usize

**Description**: Total number of key-value pairs stored in the tree.

**Invariants**:
- count = sum of all entries in all LeafNodes
- count = 0 if and only if tree is empty
- count increases by 1 on insert, decreases by 1 on delete

#### max_fanout: usize

**Description**: Maximum number of children for internal nodes (configuration parameter).

**Typical Value**: 4 (small for testing, larger in production)

**Invariants**:
- max_fanout >= 2
- Internal node children count <= max_fanout

#### max_entries: usize

**Description**: Maximum number of entries per leaf node (configuration parameter).

**Typical Value**: max_fanout - 1

**Invariants**:
- max_entries >= 1
- Leaf node entries count <= max_entries

### BTree Invariants

#### Global Invariants
1. **All keys reachable**: Every key in the tree is reachable by traversing from root
2. **No duplicate keys**: Each key appears at most once in the entire tree
3. **Sorted order**: In-order traversal produces keys in strictly increasing order
4. **Balanced**: All root-to-leaf paths have same length (height)
5. **Node capacity**: All nodes respect min/max children or entries constraints

#### Internal Node Invariants
1. **Separator order**: keys[i] < keys[i+1] for all valid i
2. **Child bounds**: Each child is a valid node (recursive invariants)
3. **Routing correctness**: Key k routes to child i where:
   - i = 0 if k < keys[0]
   - i = len(keys) if k >= keys[len(keys)-1]
   - Otherwise, i where keys[i-1] <= k < keys[i]

#### Leaf Node Invariants
1. **Entry order**: entries[i].key < entries[i+1].key
2. **Linked list integrity**: Doubly-linked list structure is consistent
3. **Coverage**: Every non-internal node is a leaf

---

## Snapshot State

### SnapshotState: Struct

**Description**: Complete database state at a specific point in time. Immutable once created.

**Fields**:

#### tree: BTree

**Description**: B+Tree containing all key-value pairs in this snapshot.

**Invariants**:
- tree represents all committed data at this point in time
- tree is immutable (all operations create new BTree copies)

#### txn_id: TxnId

**Description**: Transaction identifier that created this snapshot. 0 for initial empty state.

**Invariants**:
- txn_id >= 0
- txn_id is monotonically increasing across snapshots
- Each committed transaction creates exactly one snapshot

#### parent_txn_id: Option<TxnId>

**Description**: Transaction ID of the snapshot this was derived from. None for initial state (txn_id = 0).

**Invariants**:
- parent_txn_id < txn_id (except for txn_id = 0 where parent is None)
- Parent snapshot's tree is the base before applying this transaction's writes

#### timestamp: u64

**Description**: Monotonically increasing timestamp for snapshot ordering. Can be derived from txn_id but kept explicit for clarity.

**Invariants**:
- timestamp increases with each new snapshot
- timestamp can be used for ordering snapshots independently of txn_id

### SnapshotState Invariants

#### Immutability
1. **No modifications**: Once created, tree structure never changes
2. **Safe sharing**: Multiple handles can reference same snapshot without coordination
3. **Deep equality**: Two snapshots are equal iff all fields are equal

#### Derivation
1. **From parent**: Each snapshot (except initial) is derived from a parent
2. **Transaction application**: Snapshot = parent.tree + transaction.writes
3. **Consistent view**: All operations on snapshot see same state

---

## Transaction Types

### ReadTxn: Struct

**Description**: Handle for read operations on an immutable snapshot.

**Fields**:

#### snapshot: Arc<SnapshotState>

**Description**: Reference to the snapshot state this transaction reads from.

**Invariants**:
- snapshot is immutable
- Multiple ReadTxn can reference same snapshot
- Arc enables cheap cloning (reference count increment)

#### txn_id: TxnId

**Description**: Transaction identifier (matches snapshot.txn_id).

**Invariants**:
- txn_id == snapshot.txn_id
- Used for debugging and logging

### WriteTxn: Struct

**Description**: Handle for write operations with a staging buffer.

**Fields**:

#### base_snapshot: Arc<SnapshotState>

**Description**: Snapshot state this transaction is based on.

**Invariants**:
- All reads go through base_snapshot
- base_snapshot is immutable
- Writes do not modify base_snapshot

#### writes: BTreeMap<KeyBytes, Option<ValueBytes>>

**Description**: Staged modifications waiting for commit. Map from key to optional value.

**Invariants**:
- Some(value) represents a put operation
- None represents a delete operation
- Last write to a key wins (later writes override earlier writes)
- reads check writes first (writes shadow base_snapshot)

#### committed: bool

**Description**: Flag indicating whether transaction has been committed or aborted.

**Invariants**:
- Initially false
- Set to true on commit() or abort()
- No operations allowed after committed = true

---

## Reference Model State

### RefModel: Struct

**Description**: Top-level container managing all snapshots and the current state.

**Fields**:

#### current_txn_id: TxnId

**Description**: Counter for assigning transaction IDs. Starts at 1 (ID 0 is initial state).

**Invariants**:
- current_txn_id >= 1
- Increases by 1 on each commit
- Never decreases

#### snapshots: BTreeMap<TxnId, Arc<SnapshotState>>

**Description**: All historical snapshots indexed by transaction ID.

**Invariants**:
- Contains entry for each committed transaction
- snapshots[0] is the initial empty state
- snapshots[k] is state after k-th commit
- Keys are strictly increasing (transaction order)

#### current_state: Arc<SnapshotState>

**Description**: Reference to the most recent snapshot (snapshots[current_txn_id]).

**Invariants**:
- current_state.txn_id == current_txn_id
- Always points to a valid snapshot in snapshots
- Updated on each commit

#### min_retained_txn_id: TxnId

**Description**: Oldest snapshot that must be retained (for cleanup decisions).

**Invariants**:
- min_retained_txn_id <= current_txn_id
- Snapshots older than min_retained_txn_id can be dropped
- For testing, typically set to 0 (keep all snapshots)

### RefModel Invariants

#### Consistency
1. **Snapshot coherence**: current_state always equals snapshots[current_txn_id]
2. **Transaction order**: For any i < j, snapshots[i].timestamp < snapshots[j].timestamp
3. **No gaps**: snapshots contains entries for all TxnId from 0 to current_txn_id
4. **Derivation chain**: For any txn_id > 0, snapshots[txn_id].parent_txn_id = Some(txn_id - 1)

#### State Transitions
1. **Commit**: Create new snapshot, increment current_txn_id, update current_state
2. **Abort**: No state changes (writes buffer discarded)
3. **Begin read**: Return Arc clone of specified snapshot
4. **Begin write**: Create new WriteTxn with current_state as base

---

## Rust Implementation Guidance

### Module Structure

The in-memory structures should be organized in the `ref_model` crate as follows:

```
ref_model/
├── lib.rs              # Public API exports
├── btree/
│   ├── mod.rs          # B+Tree public interface
│   ├── node.rs         # Node enum (Internal, Leaf)
│   └── tree.rs         # BTree container struct
├── snapshot/
│   ├── mod.rs          # Snapshot public interface
│   └── state.rs        # SnapshotState struct
├── txn/
│   ├── mod.rs          # Transaction public interface
│   ├── read.rs         # ReadTxn struct
│   └── write.rs        # WriteTxn struct
└── model.rs            # RefModel top-level struct
```

### Type Definitions

#### Use Newtype Pattern for Safety

```rust
pub struct KeyBytes(Vec<u8>);
pub struct ValueBytes(Vec<u8>);
pub type TxnId = u64;
```

**Benefits**:
- Type safety (can't confuse keys and values)
- Clear API (KeyBytes vs raw Vec<u8>)
- Easy to add methods (comparison, hashing, serialization)
- Prevents accidental misuse

#### Use Rc/Arc for Shared Snapshots

```rust
use std::sync::Arc;

pub struct SnapshotState {
    tree: BTree,
    txn_id: TxnId,
    // ...
}

pub struct ReadTxn {
    snapshot: Arc<SnapshotState>,
    // ...
}
```

**Benefits**:
- Cheap cloning (just increment reference count)
- Thread-safe reference counting (Arc)
- Clear ownership semantics
- Enables multiple concurrent readers

#### Use Box for Recursive Structures

```rust
pub enum Node {
    Internal(InternalNode),
    Leaf(LeafNode),
}

pub struct InternalNode {
    keys: Vec<KeyBytes>,
    children: Vec<Box<Node>>,  // Box for indirection
}

pub struct LeafNode {
    entries: Vec<(KeyBytes, ValueBytes)>,
    next: Option<Box<Node>>,  // Box for indirection
    prev: Option<Box<Node>>,
}
```

**Benefits**:
- Fixed-size Node enum (Box is pointer-sized)
- Recursive structures compile
- Clear heap allocation semantics
- Efficient for tree structures

### Concurrency

#### Reference Model is Single-Threaded

- No need for Mutex, RwLock, or atomic types
- Arc is used for sharing, not for thread safety
- All operations are sequential and deterministic
- Enables straightforward testing without race conditions

#### If Adding Concurrency (Future)

For future concurrent testing:
- Replace Arc with RwLock<Arc<SnapshotState>>
- Use Mutex for RefModel state
- Keep transactions single-threaded (no concurrent writes)
- Allow concurrent reads on same snapshot

### Key Decisions

#### B+Tree Fanout: Small vs Large
**Decision**: Use small fanout (4 children max)

**Reason**:
- Smaller trees easier to reason about
- More edge cases tested with frequent splits
- Debugging is simpler with shallow trees
- Performance is not a concern for reference model

#### Node Storage: Enum vs Trait Objects
**Decision**: Use enum for node types

**Reason**:
- Exhaustive pattern matching (compiler checks all cases)
- No dynamic dispatch overhead
- Simpler serialization (enum variant tag)
- Clear ownership and move semantics

#### Snapshot Storage: Arc vs Copy
**Decision**: Use Arc for snapshots

**Reason**:
- Avoid expensive deep copies
- Multiple readers can share same snapshot
- Clear immutable semantics (Arc enforces read-only)
- Reference counting makes lifetime management explicit

#### Write Buffer: BTreeMap vs HashMap
**Decision**: Use BTreeMap for write buffer

**Reason**:
- Ordered iteration for deterministic serialization
- Range queries on writes (though uncommon)
- Consistent with B+Tree ordering
- Slightly slower but more predictable

### Implementation Notes

#### Step 1: Define Basic Types
Start with KeyBytes, ValueBytes, TxnId types. Implement:
- Comparison traits (Ord, PartialOrd, Eq, PartialEq for KeyBytes)
- Hash traits (Hash for KeyBytes)
- Debug and Display for debugging

#### Step 2: Implement Node Enum
Create Node enum with Internal and Leaf variants:
- Implement constructors (new_leaf, new_internal)
- Add helper methods (is_leaf, is_internal, as_leaf, as_internal)
- Add invariants checking (validate method)

#### Step 3: Build BTree Container
Implement BTree struct with:
- Constructor (new, with_capacity)
- Basic operations (insert, lookup, remove)
- Tree maintenance (split_node, merge_nodes, rebalance)
- Iteration (iter, iter_range, iter_rev)

#### Step 4: Create Snapshot Types
Implement SnapshotState, ReadTxn, WriteTxn:
- Snapshot creation (from_base, apply_writes)
- Transaction lifecycle (begin_read, begin_write, commit, abort)
- State query methods (get, len, is_empty)

#### Step 5: Top-Level RefModel
Implement RefModel container:
- Initialization (new with empty snapshot)
- Transaction management (begin, commit, abort)
- Snapshot retention (cleanup old snapshots)
- State export (serialize for comparison)

### Testing Strategy

#### Unit Tests Needed For

**Node Types**:
- Leaf node creation and entry ordering
- Internal node child routing logic
- Linked list consistency (prev/next pointers)
- Split and merge operations

**BTree Operations**:
- Insert into empty tree
- Insert causing single node split
- Insert cascading multiple levels
- Delete from leaf, internal node
- Delete causing node merge
- Lookup (key found, key not found)

**Snapshot Types**:
- Snapshot creation from base
- Write transaction staging
- Commit creates new snapshot
- Abort discards writes
- Multiple snapshots coexist

**RefModel**:
- Initialization with empty state
- Sequential commits increment txn_id
- Snapshot retention logic
- State serialization

#### Property Tests For

**BTree Invariants**:
- All leaves at same depth
- Keys are ordered within nodes
- Separator keys correctly divide ranges
- No duplicate keys exist
- Insert then lookup finds key
- Delete then lookup doesn't find key

**Snapshot Consistency**:
- Parent txn_id always less than child
- Snapshots are immutable
- Transaction isolation (reads don't see uncommitted writes)
- Commit atomically applies all writes

**RefModel State**:
- current_txn_id increases monotonically
- snapshots map is complete (no gaps)
- current_state always equals snapshots[current_txn_id]

#### Integration Scenarios

**Complex Operation Sequences**:
- Insert 100 keys in random order
- Delete every other key
- Re-insert deleted keys
- Verify tree invariants after each operation

**Snapshot History**:
- Commit 100 transactions
- Query each historical snapshot
- Verify each snapshot's state is correct
- Verify snapshots are independent (modifying one doesn't affect others)

**Error Recovery**:
- Attempt to delete non-existent key
- Attempt to insert duplicate key
- Attempt to use transaction after commit/abort
- Verify error handling and state consistency

---

## Summary

The reference model in-memory structures provide:

- **Clear data model**: B+Tree nodes, snapshots, transactions are well-defined
- **Explicit invariants**: All structures have checkable properties
- **Deterministic behavior**: No hidden state or non-deterministic choices
- **Easy validation**: Structures can be serialized and compared directly

These structures form the foundation for implementing a **correctness oracle** that establishes the truth of database operations, against which the production implementation is continuously tested.
