# Reference Model: Operations

**Phase**: 8
**Task**: 8.3
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [B+Tree Core Operations](#btree-core-operations)
3. [Transaction Operations](#transaction-operations)
4. [Read Operations](#read-operations)
5. [Write Operations](#write-operations)
6. [Iteration Operations](#iteration-operations)
7. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

This specification describes all operations supported by the reference model, including B+Tree core operations, transaction lifecycle operations, read operations, write operations, and iteration operations.

Each operation includes:
- **Purpose**: What the operation does
- **Parameters**: Input values and their constraints
- **Returns**: Output values and their meaning
- **Algorithm**: Step-by-step plain English description
- **Error Conditions**: When and why failures occur
- **Complexity**: Time and space characteristics

---

## B+Tree Core Operations

### lookup(tree: &BTree, key: &KeyBytes) -> Option<ValueBytes>

**Purpose**: Find the value associated with a key in the B+Tree.

**Parameters**:
- **tree**: Reference to the B+Tree to search
- **key**: Key to look up (must be valid KeyBytes)

**Returns**:
- **Some(value)**: Key exists, associated value is returned
- **None**: Key not found in tree

**Algorithm**:

1. Start at the root node
2. If current node is a LeafNode:
   a. Search entries vector for key (binary search or linear scan)
   b. If found at index i, return Some(entries[i].value)
   c. If not found, return None
3. If current node is an InternalNode:
   a. Search keys vector to find appropriate child:
      - If key < keys[0], go to child 0
      - If key >= keys[last], go to child keys.len()
      - Otherwise, find i where keys[i-1] <= key < keys[i], go to child i
   b. Set current node = child[i]
   c. Go to step 2
4. Key was not found in any leaf, return None

**Error Conditions**:
- None (lookup cannot fail; key not found is normal case, not an error)

**Complexity**:
- **Time**: O(height * log(fanout)) where height is tree height, fanout is max children per node
- **Space**: O(1) (no allocation, just traversal)

**Invariants**:
- If key was previously inserted and not deleted, lookup returns Some(value)
- If key was never inserted or was deleted, lookup returns None
- Tree structure is unchanged by lookup

---

### insert(tree: &mut BTree, key: KeyBytes, value: ValueBytes) -> Result<(), InsertError>

**Purpose**: Insert a new key-value pair or update existing key.

**Parameters**:
- **tree**: Mutable reference to B+Tree
- **key**: Key to insert (must not be empty for implementation simplicity)
- **value**: Value to associate with key

**Returns**:
- **Ok(())**: Insert succeeded
- **Err(InsertError::DuplicateKey)**: Key already exists (if treating duplicate as error)

**Algorithm**:

1. If tree.root is a LeafNode:
   a. If root has space (entries.len() < max_entries):
      - Insert (key, value) in correct position (maintain sorted order)
      - Increment tree.count
      - Return Ok(())
   b. If root is full (entries.len() == max_entries):
      - Split root into two leaf nodes
      - Create new internal root with two children
      - Insert new key in appropriate leaf
      - Increment tree.height
      - Increment tree.count
      - Return Ok(())

2. If tree.root is an InternalNode:
   a. Traverse from root to find leaf where key belongs:
      - At each internal node, follow appropriate child pointer
      - Keep track of path (stack of nodes and indices)
   b. Once leaf is reached:
      - If leaf has space:
        * Insert (key, value) in correct position
        * Increment tree.count
        * Return Ok(())
      - If leaf is full:
        * Split leaf into two leaf nodes
        * Promote median key up to parent
        * Insert new key in appropriate new leaf
        * If parent is full, recursively split parent
        * May propagate to root, increasing tree height
        * Increment tree.count
        * Return Ok(())

**Error Conditions**:
- **InsertError::DuplicateKey**: If policy disallows updates and key exists
- **InsertError::KeyTooLarge**: If key exceeds maximum size limit (optional constraint)

**Complexity**:
- **Time**: O(height * fanout) for traversal and potential splits
- **Space**: O(height) for new nodes during splits (logarithmic)

**Invariants**:
- After successful insert, lookup(key) returns Some(value)
- Tree height increases by at most 1
- All B+Tree invariants maintained (balanced, ordered, capacity constraints)
- tree.count incremented by exactly 1

---

### delete(tree: &mut BTree, key: &KeyBytes) -> Result<Option<ValueBytes>, DeleteError>

**Purpose**: Remove a key-value pair from the tree.

**Parameters**:
- **tree**: Mutable reference to B+Tree
- **key**: Key to delete

**Returns**:
- **Ok(Some(value))**: Key was found and removed, returns previous value
- **Ok(None)**: Key was not found (no-op)
- **Err(...)**: Error occurred (rare, see error conditions)

**Algorithm**:

1. Traverse tree to find leaf containing key:
   a. Follow internal node routing from root
   b. Keep track of path (stack of nodes and child indices)
2. If leaf node doesn't contain key:
   a. Return Ok(None) (key not present)
3. If leaf node contains key at index i:
   a. Remove entry at index i from leaf.entries
   b. Decrement tree.count
   c. Save the removed value
   d. Check if leaf node is underfull:
      - If entries.len() < min_entries (typically max_entries / 2):
        * Try to borrow from sibling:
          - If left sibling has extra entries, redistribute
          - If right sibling has extra entries, redistribute
          - Update separator keys in parent
        * If borrowing not possible, merge with sibling:
          - Combine entries from this node and sibling
          - Remove separator key from parent
          - If parent underfull, recursively handle underflow
          - May propagate to root, potentially decreasing height
   e. Return Ok(Some(removed_value))

**Error Conditions**:
- **DeleteError::TreeEmpty**: Attempted to delete from empty tree (optional, can treat as no-op)

**Complexity**:
- **Time**: O(height * fanout) for traversal and potential merges
- **Space**: O(1) for deletions without merges, O(height) if merges cascade

**Invariants**:
- After successful delete, lookup(key) returns None
- Tree height decreases by at most 1 (if root underflows)
- All B+Tree invariants maintained
- tree.count decremented by exactly 1 if key found

---

### update(tree: &mut BTree, key: KeyBytes, value: ValueBytes) -> Result<Option<ValueBytes>, UpdateError>

**Purpose**: Update an existing key's value or insert if not present.

**Parameters**:
- **tree**: Mutable reference to B+Tree
- **key**: Key to update
- **value**: New value to associate with key

**Returns**:
- **Ok(Some(old_value))**: Key existed, returns previous value
- **Ok(None)**: Key didn't exist, was inserted
- **Err(...)**: Error occurred

**Algorithm**:

1. Attempt to lookup key in tree
2. If key found:
   a. Navigate to leaf containing key
   b. Replace value at key's position
   c. Return Ok(Some(old_value))
3. If key not found:
   a. Insert key with new value (same as insert operation)
   b. Return Ok(None)

**Error Conditions**:
- **UpdateError::KeyTooLarge**: If key exceeds maximum size limit
- **UpdateError::ValueTooLarge**: If value exceeds maximum size limit

**Complexity**:
- **Time**: O(height * fanout) (lookup + optional insert)
- **Space**: O(height) if insert triggers splits

**Invariants**:
- After update, lookup(key) returns Some(value)
- If key existed, tree.count unchanged
- If key didn't exist, tree.count incremented by 1
- All B+Tree invariants maintained

---

## Transaction Operations

### begin_read(model: &RefModel, txn_id: Option<TxnId>) -> Result<ReadTxn, ReadError>

**Purpose**: Start a new read transaction on a specific snapshot.

**Parameters**:
- **model**: Reference to RefModel
- **txn_id**: Transaction ID to read from, or None for latest snapshot

**Returns**:
- **Ok(ReadTxn)**: Handle for read operations
- **Err(ReadError::SnapshotNotFound)**: Requested txn_id doesn't exist

**Algorithm**:

1. Determine target snapshot:
   a. If txn_id is None, target = model.current_state
   b. If txn_id is Some(i):
      - Lookup snapshots[i] in model.snapshots
      - If not found, return Err(ReadError::SnapshotNotFound)
      - target = snapshots[i]
2. Create ReadTxn {
   a. snapshot: Arc::clone(target)
   b. txn_id: target.txn_id
   }
3. Return Ok(ReadTxn)

**Error Conditions**:
- **ReadError::SnapshotNotFound**: Requested txn_id doesn't exist in snapshots map
- **ReadError::InvalidTxnId**: txn_id is 0 (initial state) or negative

**Complexity**:
- **Time**: O(1) (map lookup + Arc clone)
- **Space**: O(1) (just Arc reference count increment)

**Invariants**:
- ReadTxn snapshot is immutable
- Multiple ReadTxn can reference same snapshot
- ReadTxn operations don't affect model state

---

### begin_write(model: &RefModel) -> WriteTxn

**Purpose**: Start a new write transaction for staging modifications.

**Parameters**:
- **model**: Reference to RefModel

**Returns**:
- **WriteTxn**: Handle for write operations

**Algorithm**:

1. Create WriteTxn {
   a. base_snapshot: Arc::clone(model.current_state)
   b. writes: BTreeMap::new() (empty write buffer)
   c. committed: false
   }
2. Return WriteTxn

**Error Conditions**:
- None (begin_write always succeeds)

**Complexity**:
- **Time**: O(1) (Arc clone + empty BTreeMap)
- **Space**: O(1) (empty writes buffer)

**Invariants**:
- WriteTxn starts with empty write buffer
- All reads go through base_snapshot
- Writes don't affect base_snapshot or model state until commit

---

### commit(model: &mut RefModel, txn: &mut WriteTxn) -> Result<TxnId, CommitError>

**Purpose**: Atomically apply all staged writes to create a new snapshot.

**Parameters**:
- **model**: Mutable reference to RefModel
- **txn**: Mutable reference to WriteTxn to commit

**Returns**:
- **Ok(new_txn_id)**: Transaction ID assigned to committed transaction
- **Err(CommitError::AlreadyCommitted)**: Transaction already committed or aborted

**Algorithm**:

1. Check if txn.committed is true:
   a. If true, return Err(CommitError::AlreadyCommitted)
2. Create new snapshot:
   a. Start with copy of txn.base_snapshot.tree
   b. For each (key, opt_value) in txn.writes.iter() in sorted order:
      - If opt_value is Some(value):
        * Insert or update key with value in tree
      - If opt_value is None:
        * Delete key from tree
   c. Create new SnapshotState {
      * tree: modified_tree
      * txn_id: model.current_txn_id + 1
      * parent_txn_id: Some(txn.base_snapshot.txn_id)
      * timestamp: generate_new_timestamp()
      }
3. Update RefModel:
   a. Increment model.current_txn_id by 1
   b. Insert new_snapshot into model.snapshots at key new_txn_id
   c. Set model.current_state = Arc::new(new_snapshot)
4. Mark txn as committed:
   a. Set txn.committed = true
5. Return Ok(new_txn_id)

**Error Conditions**:
- **CommitError::AlreadyCommitted**: Transaction already committed or aborted
- **CommitError::Conflict**: If conflict detection is enabled and conflict detected (optional)

**Complexity**:
- **Time**: O(W * log(N)) where W is number of writes, N is number of keys
- **Space**: O(N) for new snapshot copy (depends on copy-on-write strategy)

**Invariants**:
- After commit, all writes are visible in new snapshot
- new_txn_id > all previous transaction IDs
- model.current_state reflects new snapshot
- txn cannot be used after commit (committed flag prevents operations)

---

### abort(txn: &mut WriteTxn) -> Result<(), AbortError>

**Purpose**: Discard all staged writes without applying them.

**Parameters**:
- **txn**: Mutable reference to WriteTxn to abort

**Returns**:
- **Ok(())**: Abort succeeded, writes discarded
- **Err(AbortError::AlreadyCommitted)**: Transaction already committed or aborted

**Algorithm**:

1. Check if txn.committed is true:
   a. If true, return Err(AbortError::AlreadyCommitted)
2. Discard write buffer:
   a. Clear txn.writes (or just drop transaction)
3. Mark txn as aborted:
   a. Set txn.committed = true
4. Return Ok(())

**Error Conditions**:
- **AbortError::AlreadyCommitted**: Transaction already committed or aborted

**Complexity**:
- **Time**: O(W) to clear writes buffer (or O(1) if just dropping)
- **Space**: O(1) (writes buffer is dropped)

**Invariants**:
- After abort, none of the writes are visible in any snapshot
- base_snapshot is unchanged
- txn cannot be used after abort (committed flag prevents operations)

---

## Read Operations

### get(txn: &ReadTxn, key: &KeyBytes) -> Result<Option<ValueBytes>, GetError>

**Purpose**: Look up a key's value in the transaction's snapshot.

**Parameters**:
- **txn**: Reference to ReadTxn
- **key**: Key to look up

**Returns**:
- **Ok(Some(value))**: Key found in snapshot
- **Ok(None)**: Key not found in snapshot
- **Err(GetError::InvalidTxn)**: Transaction already closed

**Algorithm**:

1. Check if txn is valid (optional flag check)
2. Call txn.snapshot.tree.lookup(key)
3. Return result (Some value or None)

**Error Conditions**:
- **GetError::InvalidTxn**: Transaction used after being closed
- **GetError::KeyNotFound**: (Not an error; return Ok(None) instead)

**Complexity**:
- **Time**: O(height * log(fanout)) (B+Tree lookup)
- **Space**: O(1)

**Invariants**:
- Returns value from snapshot's consistent view
- Doesn't affect snapshot or transaction state
- Repeated get calls with same key return same result

---

### get_for_update(txn: &WriteTxn, key: &KeyBytes) -> Result<Option<ValueBytes>, GetError>

**Purpose**: Look up a key's value, checking staged writes first, then base snapshot.

**Parameters**:
- **txn**: Reference to WriteTxn
- **key**: Key to look up

**Returns**:
- **Ok(Some(value))**: Key found (in writes or snapshot)
- **Ok(None)**: Key not found
- **Err(GetError::InvalidTxn)**: Transaction already committed/aborted

**Algorithm**:

1. Check if txn.committed is true:
   a. If true, return Err(GetError::InvalidTxn)
2. Check txn.writes for key:
   a. If key in txn.writes:
      - If txn.writes[key] is Some(value), return Ok(Some(value))
      - If txn.writes[key] is None, return Ok(None) (deleted)
3. If key not in writes, look up in base snapshot:
   a. Call txn.base_snapshot.tree.lookup(key)
   b. Return result

**Error Conditions**:
- **GetError::InvalidTxn**: Transaction already committed or aborted

**Complexity**:
- **Time**: O(log(W) + height * log(fanout)) where W is writes buffer size
- **Space**: O(1)

**Invariants**:
- Returns value reflecting staged writes (writes shadow snapshot)
- Doesn't modify transaction state
- Repeated calls with same key return same result (unless write modifies key)

---

### exists(txn: &ReadTxn, key: &KeyBytes) -> Result<bool, ExistsError>

**Purpose**: Check if a key exists in the snapshot.

**Parameters**:
- **txn**: Reference to ReadTxn
- **key**: Key to check

**Returns**:
- **Ok(true)**: Key exists in snapshot
- **Ok(false)**: Key doesn't exist in snapshot
- **Err(ExistsError::InvalidTxn)**: Transaction already closed

**Algorithm**:

1. Call txn.get(key)
2. If result is Ok(Some(_)), return Ok(true)
3. If result is Ok(None), return Ok(false)
4. If result is Err, propagate error

**Error Conditions**:
- **ExistsError::InvalidTxn**: Transaction already closed

**Complexity**:
- **Time**: O(height * log(fanout)) (same as get)
- **Space**: O(1)

**Invariants**:
- Returns true iff get would return Some(value)
- Doesn't modify snapshot or transaction state

---

## Write Operations

### put(txn: &mut WriteTxn, key: KeyBytes, value: ValueBytes) -> Result<(), PutError>

**Purpose**: Stage a key insert or update in the write transaction.

**Parameters**:
- **txn**: Mutable reference to WriteTxn
- **key**: Key to insert or update
- **value**: Value to associate with key

**Returns**:
- **Ok(())**: Write staged successfully
- **Err(PutError::InvalidTxn)**: Transaction already committed/aborted
- **Err(PutError::KeyTooLarge)**: Key exceeds maximum size
- **Err(PutError::ValueTooLarge)**: Value exceeds maximum size

**Algorithm**:

1. Check if txn.committed is true:
   a. If true, return Err(PutError::InvalidTxn)
2. Validate key and value sizes (optional constraints)
3. Insert or update in write buffer:
   a. txn.writes.insert(key, Some(value))
4. Return Ok(())

**Error Conditions**:
- **PutError::InvalidTxn**: Transaction already committed or aborted
- **PutError::KeyTooLarge**: Key size exceeds maximum (e.g., 4KB)
- **PutError::ValueTooLarge**: Value size exceeds maximum (e.g., 1MB)

**Complexity**:
- **Time**: O(log(W)) for BTreeMap insert
- **Space**: O(1) amortized (BTreeMap grows as needed)

**Invariants**:
- Write is not visible until commit
- Subsequent puts to same key overwrite previous puts
- get_for_update returns staged value, not snapshot value

---

### delete(txn: &mut WriteTxn, key: &KeyBytes) -> Result<(), DeleteError>

**Purpose**: Stage a key deletion in the write transaction.

**Parameters**:
- **txn**: Mutable reference to WriteTxn
- **key**: Key to delete

**Returns**:
- **Ok(())**: Deletion staged successfully
- **Err(DeleteError::InvalidTxn)**: Transaction already committed/aborted

**Algorithm**:

1. Check if txn.committed is true:
   a. If true, return Err(DeleteError::InvalidTxn)
2. Insert deletion marker in write buffer:
   a. txn.writes.insert(key.clone(), None)
3. Return Ok(())

**Error Conditions**:
- **DeleteError::InvalidTxn**: Transaction already committed or aborted

**Complexity**:
- **Time**: O(log(W)) for BTreeMap insert
- **Space**: O(1) amortized

**Invariants**:
- Deletion is not visible until commit
- Subsequent delete to same key is no-op (idempotent)
- get_for_update returns None even if key exists in snapshot
- Delete followed by put results in put winning

---

## Iteration Operations

### iter(txn: &ReadTxn) -> Result<ForwardIterator, IterError>

**Purpose**: Create a forward iterator over all keys in the snapshot.

**Parameters**:
- **txn**: Reference to ReadTxn

**Returns**:
- **Ok(ForwardIterator)**: Iterator yielding (key, value) pairs in ascending order
- **Err(IterError::InvalidTxn)**: Transaction already closed

**Algorithm**:

1. Check if txn is valid
2. Create ForwardIterator {
   a. current: reference to first leaf node (leftmost)
   b. index: 0 (first entry in current leaf)
   c. snapshot: Arc::clone(txn.snapshot)
   }
3. Return Ok(ForwardIterator)

**Error Conditions**:
- **IterError::InvalidTxn**: Transaction already closed

**Complexity**:
- **Time**: O(1) to create iterator
- **Space**: O(1)

**Invariants**:
- Iterator yields all keys in ascending order
- Each key-value pair appears exactly once
- Iterator can be cloned (both clones independent)

---

### iter_from(txn: &ReadTxn, start: &KeyBytes) -> Result<ForwardIterator, IterError>

**Purpose**: Create a forward iterator starting from a specific key.

**Parameters**:
- **txn**: Reference to ReadTxn
- **start**: Key to start iteration from (inclusive)

**Returns**:
- **Ok(ForwardIterator)**: Iterator yielding (key, value) pairs starting from >= start
- **Err(IterError::InvalidTxn)**: Transaction already closed

**Algorithm**:

1. Check if txn is valid
2. Find leaf node containing start key:
   a. Traverse tree from root using internal node routing
   b. If start key not found, find leaf where it would be inserted
3. Create ForwardIterator {
   a. current: found leaf node
   b. index: position of start key (or insertion point if not found)
   c. snapshot: Arc::clone(txn.snapshot)
   }
4. Return Ok(ForwardIterator)

**Error Conditions**:
- **IterError::InvalidTxn**: Transaction already closed

**Complexity**:
- **Time**: O(height * log(fanout)) to find starting position
- **Space**: O(1)

**Invariants**:
- First yielded key is >= start
- Yields remaining keys in ascending order
- If start > all keys, iterator is empty (yields nothing)

---

### iter_range(txn: &ReadTxn, start: &KeyBytes, end: &KeyBytes) -> Result<RangeIterator, IterError>

**Purpose**: Create an iterator over keys in a specific range [start, end).

**Parameters**:
- **txn**: Reference to ReadTxn
- **start**: Start of range (inclusive)
- **end**: End of range (exclusive)

**Returns**:
- **Ok(RangeIterator)**: Iterator yielding (key, value) where start <= key < end
- **Err(IterError::InvalidTxn)**: Transaction already closed

**Algorithm**:

1. Check if txn is valid
2. Create iterator starting at start (same as iter_from)
3. Wrap in RangeIterator that checks each key:
   a. Before yielding, verify key < end
   b. If key >= end, stop iteration
4. Return Ok(RangeIterator)

**Error Conditions**:
- **IterError::InvalidTxn**: Transaction already closed

**Complexity**:
- **Time**: O(height * log(fanout)) to find start, O(1) per yielded item
- **Space**: O(1)

**Invariants**:
- Yields keys where start <= key < end
- Keys in strictly ascending order
- Empty if no keys in range

---

### iter_rev(txn: &ReadTxn) -> Result<ReverseIterator, IterError>

**Purpose**: Create a reverse iterator over all keys in descending order.

**Parameters**:
- **txn**: Reference to ReadTxn

**Returns**:
- **Ok(ReverseIterator)**: Iterator yielding (key, value) pairs in descending order
- **Err(IterError::InvalidTxn)**: Transaction already closed

**Algorithm**:

1. Check if txn is valid
2. Find last leaf node (rightmost):
   a. Start at root
   b. Repeatedly follow rightmost child until leaf
3. Create ReverseIterator {
   a. current: last leaf node
   b. index: last entry in current leaf
   c. snapshot: Arc::clone(txn.snapshot)
   }
4. Return Ok(ReverseIterator)

**Error Conditions**:
- **IterError::InvalidTxn**: Transaction already closed

**Complexity**:
- **Time**: O(height) to find last leaf, O(1) to create iterator
- **Space**: O(1)

**Invariants**:
- Yields keys in strictly descending order
- Each key-value pair appears exactly once
- Iterator can be cloned

---

### Iterator::next(iterator: &mut ForwardIterator) -> Option<(KeyBytes, ValueBytes)>

**Purpose**: Advance iterator and return next key-value pair.

**Parameters**:
- **iterator**: Mutable reference to iterator

**Returns**:
- **Some((key, value))**: Next key-value pair in sequence
- **None**: Iterator exhausted

**Algorithm**:

1. If iterator.current is None:
   a. Return None (iterator exhausted)
2. Get entry at iterator.index in iterator.current:
   a. If index < current.entries.len():
      - entry = current.entries[index]
      - Increment iterator.index
      - Return Some(entry)
   b. If index == current.entries.len():
      - Move to next leaf: iterator.current = current.next
      - Reset iterator.index = 0
      - Recursively call next (or loop to get first entry of next leaf)
3. Return None (no more leaves)

**Error Conditions**:
- None (iterator exhaustion is normal)

**Complexity**:
- **Time**: O(1) amortized (occasional leaf transition)
- **Space**: O(1)

**Invariants**:
- After returning Some((key, value)), subsequent calls don't yield same key
- After returning None, all subsequent calls return None
- Total number of Some returns equals number of keys in snapshot

---

### ReverseIterator::next(iterator: &mut ReverseIterator) -> Option<(KeyBytes, ValueBytes)>

**Purpose**: Advance reverse iterator and return previous key-value pair.

**Parameters**:
- **iterator**: Mutable reference to reverse iterator

**Returns**:
- **Some((key, value))**: Next key-value pair in descending order
- **None**: Iterator exhausted

**Algorithm**:

1. If iterator.current is None:
   a. Return None (iterator exhausted)
2. Get entry at iterator.index in iterator.current:
   a. If index >= 0:
      - entry = current.entries[index]
      - Decrement iterator.index
      - Return Some(entry)
   b. If index < 0:
      - Move to previous leaf: iterator.current = current.prev
      - Reset iterator.index = prev.entries.len() - 1
      - Recursively call next (or loop to get last entry of prev leaf)
3. Return None (no more leaves)

**Error Conditions**:
- None (iterator exhaustion is normal)

**Complexity**:
- **Time**: O(1) amortized
- **Space**: O(1)

**Invariants**:
- Yields keys in strictly descending order
- After returning None, all subsequent calls return None

---

## Rust Implementation Guidance

### Module Structure

Operations should be implemented in their respective modules:

```
ref_model/
├── btree/
│   ├── tree.rs         # lookup, insert, delete, update
│   └── iter.rs         # Iterator types and next methods
├── txn/
│   ├── read.rs         # get, exists, iter methods
│   ├── write.rs        # put, delete, get_for_update
│   └── commit.rs       # begin_read, begin_write, commit, abort
└── model.rs            # Top-level transaction management
```

### Type Definitions

#### Use Result Types for Error Handling

```rust
pub type Result<T> = std::result::Result<T, Error>;

pub enum Error {
    Read(ReadError),
    Write(WriteError),
    Commit(CommitError),
    // ...
}
```

**Benefits**:
- Explicit error handling at call sites
- Compiler enforces error checks
- Clear error propagation with ? operator

#### Use Iterator Trait for Standard Iteration

```rust
pub struct ForwardIterator {
    current: Option<Arc<LeafNode>>,
    index: usize,
    snapshot: Arc<SnapshotState>,
}

impl Iterator for ForwardIterator {
    type Item = (KeyBytes, ValueBytes);
    fn next(&mut self) -> Option<Self::Item> {
        // Implementation
    }
}
```

**Benefits**:
- Standard Rust iteration pattern
- Works with for loops, collect, map, filter
- Familiar to Rust developers

### Concurrency

#### Iterators Hold Arc References

```rust
pub struct ForwardIterator {
    snapshot: Arc<SnapshotState>,  // Keeps snapshot alive
    // ...
}
```

**Benefits**:
- Snapshot cannot be dropped while iterator exists
- Multiple iterators can coexist
- Safe concurrent access (Arc is thread-safe)

### Key Decisions

#### Return Option vs Result for Lookup
**Decision**: Return Option<ValueBytes> for lookup, Result for operations that can fail

**Reason**:
- Key not found is normal case (use Option)
- Invalid transaction is error case (use Result)
- Clear distinction between "expected absence" and "error"

#### Iterator Ownership vs Borrowing
**Decision**: Iterators borrow snapshot (via Arc), don't consume it

**Reason**:
- Multiple iterators on same snapshot
- Iterator doesn't prevent other operations
- Cheap to create iterators

#### Write Transaction Mutability
**Decision**: WriteTxn methods take &mut self

**Reason**:
- Enforces exclusive access to write buffer
- Prevents concurrent puts on same transaction
- Clear lifetime management

### Implementation Notes

#### Step 1: Core B+Tree Operations
Implement lookup, insert, delete, update:
- Start with lookup (simplest)
- Add insert with basic split logic
- Add delete with merge logic
- Add update as lookup + insert

#### Step 2: Transaction Lifecycle
Implement begin_read, begin_write, commit, abort:
- begin_read: Arc clone snapshot
- begin_write: Create empty writes buffer
- commit: Apply writes, create new snapshot
- abort: Clear writes buffer

#### Step 3: Read and Write Operations
Implement get, put, delete, exists:
- Read operations: Traverse snapshot tree
- Write operations: Modify writes buffer
- get_for_update: Check writes first, then snapshot

#### Step 4: Iteration
Implement iterators and helper methods:
- ForwardIterator: Standard ascending iteration
- ReverseIterator: Descending iteration
- RangeIterator: Bounded range iteration
- iter_from: Start at specific key

### Testing Strategy

#### Unit Tests Needed For

**B+Tree Operations**:
- Insert into empty tree, verify structure
- Insert causing single split, verify rebalancing
- Insert cascading multiple levels
- Delete from leaf with borrowing
- Delete causing merge, verify rebalancing
- Update existing key, verify new value
- Lookup found and not found cases

**Transaction Operations**:
- begin_write returns valid handle
- Commit creates new snapshot with writes
- Abort discards writes
- begin_read on specific txn_id
- Error cases (already committed, invalid txn_id)

**Read Operations**:
- get returns correct value
- get on non-existent key returns None
- exists matches get behavior
- Multiple concurrent reads on same snapshot

**Write Operations**:
- put stages write in buffer
- delete stages deletion marker
- get_for_update sees staged writes
- Multiple puts to same key, last wins
- Delete then put, put wins

**Iteration**:
- Forward iterator yields all keys in order
- Reverse iterator yields all keys in reverse
- Range iterator respects bounds
- iter_from starts at correct position
- Empty tree returns empty iterator
- Single element tree works

#### Property Tests For

**Operation Semantics**:
- Insert then lookup finds key
- Delete then lookup doesn't find key
- Update then lookup returns new value
- Commit makes writes visible
- Abort discards writes

**Iterator Correctness**:
- Forward then reverse yield same keys (reversed)
- Iterator visits each key exactly once
- Collecting iterator yields sorted vector
- Range iterator subset of full iterator

**Transaction Isolation**:
- Read doesn't see uncommitted writes
- Committed writes visible to new reads
- Concurrent reads see same snapshot

#### Integration Scenarios

**Complex Sequences**:
- 1000 random puts, commits, deletes
- Verify tree structure after each operation
- Verify iteration yields correct keys

**Mixed Operations**:
- Put, delete, update same key multiple times
- Verify final state matches expected

**Time Travel**:
- Commit 10 transactions
- Query each snapshot
- Verify each snapshot's correctness

---

## Summary

The reference model operations provide:

- **Complete CRUD interface**: Create (put), Read (get, exists), Update (update), Delete
- **Transaction support**: Read and write transactions with commit/abort
- **Iteration**: Forward, reverse, range-based iteration
- **Error handling**: Comprehensive error types for all failure modes
- **Deterministic behavior**: Same inputs always produce same outputs

All operations are designed for **correctness and clarity**, establishing the expected behavior that the production implementation must match.
