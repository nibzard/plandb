# B+Tree Insert Operation

## Purpose

The insert operation adds new key-value pairs to the B+Tree or updates existing keys with new values. Insert is the fundamental write operation that modifies tree structure, potentially triggering node splits that propagate upward to maintain balance. The insert operation supports MVCC by creating new versions of values with associated LSNs, allowing concurrent readers to access historical versions while writers create new versions. This specification covers the complete insert flow, from leaf node insertion to split propagation up to root split and tree growth.

## Types

### InsertResult

**Description**: Result type returned by insert operations indicating success or specific failure conditions

**Fields**:
- **status**: InsertStatus - Success or failure reason
- **existing_value**: Option<Value> - Previous value if key existed (for update operations)
- **page_modifications**: u32 - Number of nodes modified during insert (including splits)
- **tree_height_changed**: bool - True if insert caused root split and tree growth

**Rationale**: Rich result type provides visibility into operation cost and whether tree structure changed

### InsertStatus

**Description**: Enumeration of possible insert operation outcomes

**Values**:
- **Inserted**: New key-value pair added to tree
- **Updated**: Existing key updated with new value version
- **Duplicate**: Key already exists (error if duplicates not allowed)
- **KeyTooLarge**: Key size exceeds maximum (255 bytes)
- **ValueTooLarge**: Value size exceeds maximum (16MB or overflow threshold)
- **NodeFull**: Insufficient space in target node and split failed
- **IOError**: Pager I/O operation failed during insert

**Rationale**: Distinguishes between success, expected failures, and error conditions

### InsertContext

**Description**: Context structure tracking state during insert operation

**Fields**:
- **target_leaf**: PageId - Page ID of leaf node where insert will occur
- **insertion_index**: u16 - Index within leaf where key should be inserted
- **key_exists**: bool - True if key already exists in leaf
- **existing_lsn**: Option<Lsn> - LSN of existing value if key exists
- **path**: SearchPath - Traversal path from root to parent of target leaf (for split propagation)
- **lsn**: Lsn - LSN for this insert operation (from transaction commit)

**Rationale**: Captures all state from search phase needed for insert phase, avoiding retraversal

### SplitPropagation

**Description**: Record tracking node split that needs to be propagated to parent

**Fields**:
- **split_node_page_id**: PageId - Page ID of node that was split
- **new_node_page_id**: PageId - Page ID of newly created sibling node
- **separator_key**: Vec<u8> - Separator key to insert in parent
- **parent_page_id**: PageId - Page ID of parent node that needs update
- **parent_insertion_index**: u16 - Index in parent where separator should be inserted

**Rationale**: Encapsulates all information needed to update parent after child split

## Algorithms

### Leaf Node Insert (New Key)

**Purpose**: Insert a new key-value pair into a leaf node that does not already contain the key

**Context**: This is the common case for inserting new keys. The leaf node has sufficient free space for the new entry.

**Algorithm**:

1. **Input**: Leaf node with entries array, key to insert, value to insert, insertion_index from search, LSN
2. **Validation**:
   - Verify key does not already exist at insertion_index (search found insertion point)
   - Verify key size <= maximum key size (255 bytes)
   - Verify value size <= maximum value size (16MB) or check overflow threshold
   - Calculate entry_size = key_len + value_len + LSN_size + overhead_bytes
   - Verify leaf node free_space >= entry_size (node not full)
3. **Value Storage Decision**:
   - If value_size <= overflow_threshold:
     - Store value inline in leaf entry
   - Else:
     - Allocate overflow page chain from Pager
     - Write value bytes to overflow pages
     - Store overflow_page_id in leaf entry instead of value bytes
     - Set overflow flag in node header flags
4. **Insert Entry**:
   - Shift entries [insertion_index, num_keys) one position to the right
   - Create new entry at insertion_index with key, value (or overflow_page_id), LSN
   - Increment entry_count by 1
   - Decrease free_space by entry_size
5. **Update Node Header**:
   - Set dirty flag
   - Increment generation counter
   - Recalculate checksum
6. **Validation**:
   - Verify entry_count <= maximum capacity
   - Verify keys remain in sorted order
   - Verify free_space >= 0

**Time Complexity**: O(n) where n is number of entries in leaf (for shifting entries during insertion)

**Space Complexity**: O(1) (in-place modification)

**Returns**: InsertResult { status: Inserted, existing_value: None, page_modifications: 1, tree_height_changed: false }

**Error Conditions**:
- KeyTooLarge: Key size exceeds 255 bytes
- ValueTooLarge: Value size exceeds 16MB hard limit
- NodeFull: Insufficient space for new entry (should trigger split instead)
- IOError: Pager allocation or write operation failed

**Concurrency**: Exclusive access required (write operation)

**Edge Cases**:
- **Empty leaf**: Insert at index 0, no shifting needed
- **Insert at beginning**: Shift all entries right by one position
- **Insert at end**: No shifting needed, append after last entry
- **Large value overflow**: Allocate overflow pages, store page ID in entry

### Leaf Node Insert (Update Existing Key)

**Purpose**: Update an existing key with a new value by adding a new version to the version chain

**Context**: Key already exists in tree. MVCC requires preserving old versions for concurrent readers, so we prepend new version to chain rather than replacing in-place.

**Algorithm**:

1. **Input**: Leaf node with entries array, key to update, new value, entry_index from search, existing entry, new LSN
2. **Validation**:
   - Verify key matches entry at entry_index exactly
   - Verify new value size <= maximum value size (16MB)
   - Calculate new_version_size = key_len + value_len + LSN_size + version_chain_ptr_size
3. **Version Chain Update**:
   - Create new version entry with new value and new LSN
   - Set new version's older_version pointer to current entry
   - Replace entry at entry_index with new version entry
4. **Space Reclamation Consideration**:
   - Check if old version is visible to any active snapshot (old LSN >= min active snapshot LSN)
   - If old version not visible:
     - Reclaim old version space immediately
     - Update free_space accordingly
   - Else:
     - Keep old version allocated
     - Space not reclaimed until all snapshots release LSN
5. **Update Node Header**:
   - Set dirty flag
   - Increment generation counter
   - Recalculate checksum
   - Note: entry_count unchanged (update, not insert)
6. **Validation**:
   - Verify key order unchanged (same key at same index)
   - Verify new LSN > old LSN (monotonic)

**Time Complexity**: O(1) (in-place update, no shifting)

**Space Complexity**: O(1) for version chain pointer, O(value_size) for new version storage

**Returns**: InsertResult { status: Updated, existing_value: Some(old_value), page_modifications: 1, tree_height_changed: false }

**Error Conditions**:
- ValueTooLarge: New value size exceeds 16MB hard limit
- IOError: Pager write operation failed

**Concurrency**: Exclusive access required

**Edge Cases**:
- **First update**: No older version exists (version chain pointer is null)
- **Multiple updates**: Version chain grows, old versions accumulate until reclaimed
- **Large value update**: Old value was inline, new value overflows (or vice versa)

### Leaf Node Split

**Purpose**: Divide an overfull leaf node into two nodes, each within capacity limits

**Context**: Insert operation caused leaf node to exceed maximum capacity. Split creates a new sibling leaf and redistributes entries.

**Algorithm**:

1. **Input**: Overfull leaf node with num_keys entries
2. **Calculate Split Point**:
   - split_point = ceil(num_keys / 2)
   - Ensure both resulting nodes have at least minimum entries
   - For even num_keys: split_point = num_keys / 2
   - For odd num_keys: split_point = (num_keys + 1) / 2
3. **Allocate New Node**:
   - Allocate new leaf node from Pager
   - Initialize NodeHeader as leaf node (not root)
   - Set new node's level = 0 (leaf level)
   - Set new node's parent_page_id = same as original node
4. **Move Entries to New Node**:
   - Move entries [split_point, num_keys) from original node to new node
   - Update new node's entry_count = num_keys - split_point
   - Update original node's entry_count = split_point
   - Calculate and set free_space for both nodes
5. **Update Linked List Pointers**:
   - Read original node's next_leaf pointer
   - Set new_node.next_leaf = original_node.next_leaf
   - Set new_node.prev_leaf = original_node.page_id
   - Set original_node.next_leaf = new_node.page_id
   - If new_node.next_leaf != 0:
     - Read that leaf node
     - Update its prev_leaf pointer to new_node.page_id
     - Write that leaf node back
6. **Extract Separator for Parent**:
   - Separator = first key in new node (entry at index 0)
   - This separator will be inserted into parent node
7. **Update Node Headers**:
   - Set dirty flag on both nodes
   - Increment generation counter on both nodes
   - Recalculate checksum for both nodes
8. **Write Both Nodes**:
   - Write original modified node to Pager
   - Write new node to Pager
9. **Return SplitPropagation Record**:
   - Construct SplitPropagation with:
     - split_node_page_id = original_node.page_id
     - new_node_page_id = new_node.page_id
     - separator_key = extracted separator
     - parent_page_id = original_node.parent_page_id
     - parent_insertion_index = TBD (determined during parent update)

**Time Complexity**: O(n) where n is number of entries in leaf (for moving entries during split)

**Space Complexity**: O(1) (allocates one new node)

**Returns**: SplitPropagation record for parent update

**Error Conditions**:
- AllocationFailed: Pager cannot allocate new node
- IOError: Pager write operation failed
- InvalidSplitPoint: Calculated split point violates occupancy rules

**Concurrency**: Exclusive access required (blocks all other operations on this subtree)

**Edge Cases**:
- **Root is leaf**: Root split triggers tree growth (special case)
- **All entries same key**: Split point still divides entries evenly
- **Overflow pages**: Some entries have overflow pages, must move page IDs correctly

### Internal Node Insert (Separator from Child Split)

**Purpose**: Insert separator key and new child pointer into parent internal node after child split

**Context**: Child node (leaf or internal) split and produced a separator. Parent internal node must be updated to include new separator and pointer to new child.

**Algorithm**:

1. **Input**: Internal node with separators and child arrays, SplitPropagation record from child split
2. **Validation**:
   - Verify internal node has sufficient free space for new separator and child pointer
   - Calculate insert_size = separator_key_len + child_ptr_size
   - Verify free_space >= insert_size
3. **Find Insertion Point**:
   - Binary search separators to find correct position
   - Insertion point is where separator_key should be inserted to maintain order
   - insertion_index = result of binary search (0 to num_keys)
4. **Insert Separator and Child Pointer**:
   - Shift separators [insertion_index, num_keys) one position right
   - Shift child pointers [insertion_index + 1, num_keys + 1) one position right
   - Insert separator_key at separators[insertion_index]
   - Insert new_node_page_id at child_ptrs[insertion_index + 1]
   - Increment num_keys by 1
   - Decrease free_space by insert_size
5. **Update Child Parent Pointers**:
   - Read new child node (from SplitPropagation.new_node_page_id)
   - Update child's parent_page_id to this internal node's page_id
   - Write child node back
6. **Update Node Header**:
   - Set dirty flag
   - Increment generation counter
   - Recalculate checksum
7. **Validation**:
   - Verify separators remain in strictly increasing order
   - Verify child pointer count = num_keys + 1
   - Verify all child pointers non-zero

**Time Complexity**: O(n) where n is number of separators in internal node (for shifting during insertion)

**Space Complexity**: O(1) (in-place modification)

**Returns**: Ok(()) if parent updated successfully, Err if parent full and needs split

**Error Conditions**:
- NodeFull: Insufficient space for new separator (should trigger internal node split)
- InvalidChildPointer: Child pointer is null or invalid
- IOError: Pager read/write operation failed

**Concurrency**: Exclusive access required

**Edge Cases**:
- **Empty internal node**: Should not occur (only root can be empty)
- **Insert at beginning**: Shift all separators and child pointers right
- **Insert at end**: No shifting needed, append separator and child pointer

### Internal Node Split

**Purpose**: Divide an overfull internal node into two nodes

**Context**: Inserting separator from child split caused internal node to exceed capacity. Split propagates upward, potentially triggering recursive splits.

**Algorithm**:

1. **Input**: Overfull internal node with num_keys separators and num_keys + 1 child pointers
2. **Calculate Split Point**:
   - split_point = ceil(num_keys / 2)
   - Ensure both resulting nodes have at least minimum separators
3. **Allocate New Node**:
   - Allocate new internal node from Pager
   - Initialize NodeHeader as internal node (not root)
   - Set new node's level = same as original node
   - Set new node's parent_page_id = same as original node
4. **Move Separators and Child Pointers to New Node**:
   - Move separators [split_point + 1, num_keys) to new node
     - Note: Separator at split_point is promoted to parent, not moved
   - Move child pointers [split_point + 1, num_keys + 1) to new node
   - Update new node's entry_count = num_keys - split_point - 1
   - Update original node's entry_count = split_point
   - Calculate and set free_space for both nodes
5. **Extract Separator for Parent**:
   - Separator = separator at split_point (the "middle" separator)
   - This separator will be inserted into parent node
6. **Update Child Parent Pointers**:
   - For each child pointer moved to new node:
     - Read child node
     - Update child's parent_page_id to new node's page_id
     - Write child node back
7. **Update Node Headers**:
   - Set dirty flag on both nodes
   - Increment generation counter on both nodes
   - Recalculate checksum for both nodes
8. **Write Both Nodes**:
   - Write original modified node to Pager
   - Write new node to Pager
9. **Return SplitPropagation Record**:
   - Construct SplitPropagation with promoted separator

**Time Complexity**: O(n) for moving entries + O(c) for updating child parent pointers where c is number of children

**Space Complexity**: O(1) (allocates one new node)

**Returns**: SplitPropagation record for parent update

**Error Conditions**:
- AllocationFailed: Pager cannot allocate new node
- IOError: Pager read/write operation failed
- InvalidSplitPoint: Calculated split point violates occupancy rules

**Concurrency**: Exclusive access required (blocks entire tree during recursive splits)

**Edge Cases**:
- **Root is internal**: Root split triggers tree growth (special case)
- **Only two separators**: Split results in nodes with 0 and 1 separators

### Root Split (Tree Growth)

**Purpose**: Split root node when it becomes overfull, increasing tree height by one level

**Context**: Root node (leaf or internal) is full and needs to split. Root split is special because it creates a new root and grows the tree.

**Algorithm**:

1. **Input**: Full root node (leaf or internal)
2. **Allocate New Root and Sibling**:
   - Allocate new internal node to become new root from Pager
   - Allocate new sibling node (leaf or internal) from Pager
   - Initialize both nodes with appropriate types
3. **Split Original Root**:
   - If original root is leaf:
     - Execute leaf node split algorithm
     - Original root becomes left sibling
   - If original root is internal:
     - Execute internal node split algorithm
     - Original root becomes left sibling
   - Promote separator from split
4. **Initialize New Root**:
   - Set new root as internal node
   - Set new root's level = original root's level + 1
   - Set new root's parent_page_id = 0 (root has no parent)
   - Set new root's is_root = true
   - Set original root's is_root = false
   - Set new sibling's is_root = false
5. **Populate New Root**:
   - Insert promoted separator into new root (only separator)
   - Set child pointers:
     - child_ptrs[0] = original root page_id
     - child_ptrs[1] = new sibling page_id
   - Set entry_count = 1
   - Calculate and set free_space
6. **Update Child Parent Pointers**:
   - Update original root's parent_page_id to new root page_id
   - Update new sibling's parent_page_id to new root page_id
7. **Update Node Headers**:
   - Set dirty flag on all three nodes
   - Increment generation counter on all three nodes
   - Recalculate checksum for all three nodes
8. **Write All Nodes**:
   - Write original modified root (now left sibling)
   - Write new sibling node
   - Write new root node
9. **Update Database Metadata**:
   - Update root_page_id in database metadata to new root page_id
   - Increment tree_height counter by 1
   - Flush metadata to disk

**Time Complexity**: O(n) for split + O(1) for new root initialization

**Space Complexity**: O(1) (allocates two new nodes: new root and sibling)

**Returns**: InsertResult with tree_height_changed = true

**Error Conditions**:
- AllocationFailed: Pager cannot allocate new nodes (need two allocations)
- IOError: Pager write operation or metadata update failed
- MetadataUpdateFailed: Cannot persist new root_page_id

**Concurrency**: Exclusive access required (blocks entire tree)

**Edge Cases**:
- **First split**: Tree grows from height 0 (single leaf) to height 1 (root + 2 leaves)
- **Large tree height**: Root split at height 10 creates height 11 (still efficient)

### Full Insert Operation

**Purpose**: Complete insert algorithm from search to insertion to split propagation

**Context**: High-level insert operation that orchestrates all phases

**Algorithm**:

1. **Input**: B+Tree with root_page_id, key to insert, value to insert, LSN
2. **Search Phase**:
   - Execute full tree search for key
   - Obtain SearchResult with:
     - found status (true if key exists)
     - leaf_page_id where search ended
     - key_index (insertion point or existing entry index)
     - SearchPath from root to leaf parent
3. **Leaf Modification Phase**:
   - Read leaf node at leaf_page_id from Pager
   - Validate leaf node header (checksum, magic)
   - If found is true (key exists):
     - Execute leaf node update (existing key algorithm)
     - Return InsertResult immediately (no split possible for update)
   - If found is false (new key):
     - Check leaf node free_space vs required entry_size
     - If sufficient space:
       - Execute leaf node insert (new key algorithm)
       - Return InsertResult (no split needed)
     - If insufficient space:
       - Proceed to split phase
4. **Split Phase (if needed)**:
   - Execute leaf node split algorithm
   - Obtain SplitPropagation record
   - Set current_split_propagation = leaf split result
5. **Split Propagation Phase**:
   - Loop while current_split_propagation is not None:
     - Read parent node from current_split_propagation.parent_page_id
     - Check parent node free_space vs required insert_size
     - If parent has sufficient space:
       - Execute internal node insert (separator from child split)
       - Clear current_split_propagation (propagation complete)
       - Break loop
     - If parent does not have sufficient space:
       - Check if parent is root (parent_page_id == 0):
         - Execute root split (tree growth algorithm)
         - Clear current_split_propagation (propagation complete)
         - Break loop
       - Else (parent is not root):
         - Execute internal node split algorithm
         - Update current_split_propagation with new split result
         - Continue loop (propagate to grandparent)
6. **Finalization Phase**:
   - Flush all dirty nodes to Pager
   - Update database statistics if tree height changed
   - Return InsertResult with appropriate status and page_modifications count

**Time Complexity**:
- Search: O(log n)
- Insert: O(1) amortized (leaf modification)
- Split propagation: O(log n) worst case (splits at every level)
- Total: O(log n) average, O(log n) worst case

**Space Complexity**: O(h) for SearchPath stack where h is tree height

**Returns**: InsertResult with status, existing value (if any), page modification count, tree height change flag

**Error Conditions**:
- All error types from sub-algorithms (search, insert, split, propagation)
- TreeCorrupted: Propagation detected structural inconsistency

**Concurrency**: Exclusive write access required (blocks all other writes, allows concurrent reads via MVCC)

**Edge Cases**:
- **Empty tree**: Root does not exist, create initial root leaf node
- **Single node tree**: Root is leaf, insert may cause root split
- **Cascading splits**: Multiple levels split in single insert (rare but possible)

## Invariants

### Insert Invariants

1. **Key Ordering**: After insert, all keys within node remain in strictly increasing order
2. **Leaf Linked List**: After leaf insert or split, next/prev pointers form consistent doubly-linked list
3. **LSN Monotonicity**: New versions always have higher LSN than old versions for same key
4. **Parent Pointers**: After split, all child nodes have correct parent_page_id
5. **Tree Balance**: After all splits and propagation, all leaves remain at same depth
6. **Root Uniqueness**: Exactly one root node exists after all operations

### Split Invariants

1. **Split Point Validity**: Split point ensures both resulting nodes have at least minimum entries
2. **Separator Promotion**: Promoted separator key is present in the right node after split
3. **Child Distribution**: All children are distributed between split nodes (no children lost)
4. **Parent Consistency**: Parent separator correctly divides key space between split children
5. **Overflow Pages**: Overflow page references remain valid after split

### Propagation Invariants

1. **Termination**: Propagation always terminates (reaches root or finds non-full parent)
2. **Path Validity**: Propagation follows SearchPath upward correctly
3. **Separator Ordering**: Inserted separators maintain parent node ordering
4. **Root Split**: Root split always succeeds (tree can always grow)
5. **Metadata Consistency**: Database metadata updated correctly after root split

## Error Conditions and Handling

### Validation Errors

**KeyTooLarge**:
- **Detection**: key.len() > MAX_KEY_SIZE (255 bytes)
- **Handling**: Return error immediately, do not modify tree
- **User Action**: Truncate key or use smaller key

**ValueTooLarge**:
- **Detection**: value.len() > MAX_VALUE_SIZE (16MB)
- **Handling**: Return error immediately, do not modify tree
- **User Action**: Split value or use external storage

**InvalidKey**: Empty key or null key
- **Detection**: key.is_empty() or key.is_null()
- **Handling**: Return error immediately
- **User Action**: Provide non-empty key

### Space Errors

**NodeFull**:
- **Detection**: free_space < entry_size during insert
- **Handling**: Trigger split operation, not an error condition
- **Recovery**: Split must succeed, propagate upward if needed

**AllocationFailed**:
- **Detection**: Pager.allocate_page() returns error
- **Handling**: Abort insert operation, rollback partial changes
- **Recovery**: Return error to caller, transaction must abort
- **User Action**: Free disk space or increase database size limit

### Structural Errors

**CorruptNode**:
- **Detection**: Checksum validation fails or node header invalid
- **Handling**: Abort insert operation immediately
- **Recovery**: Initiate recovery from WAL or checkpoint
- **User Action**: Run database recovery/repair utility

**ParentNotFound**:
- **Detection**: During split propagation, parent_page_id is invalid
- **Handling**: Abort insert operation, tree is corrupted
- **Recovery**: Rebuild tree structure from WAL
- **User Action**: Run database verification and repair

**InconsistentTree**:
- **Detection**: Propagation detects structural inconsistency (e.g., child points to wrong parent)
- **Handling**: Abort insert operation immediately
- **Recovery**: Mark database as corrupted, require full recovery
- **User Action**: Restore from backup or run repair

### I/O Errors

**IOError**:
- **Detection**: Pager read/write operation fails
- **Handling**: Abort insert operation, dirty nodes may not be written
- **Recovery**: Depends on write-ahead log:
  - If WAL entry written: transaction committed but dirty pages not flushed
  - If WAL entry not written: transaction not committed, no recovery needed
- **User Action**: Check disk health, free disk space, restart database

### MVCC Version Errors

**VersionChainCorrupted**:
- **Detection**: Version chain traversal encounters invalid pointer or loop
- **Handling**: Abort insert operation, do not modify version chain
- **Recovery**: Rebuild version chains from WAL
- **User Action**: Run database verification

**SnapshotConflict**:
- **Detection**: Attempting to update value with LSN older than existing version
- **Handling**: Return error immediately, LSN must be monotonically increasing
- **User Action**: Ensure transaction commit order is correct

## Rust Implementation Guidance

### Module Structure

The insert functionality should be organized as:
- `northstar_core::tree::insert::insert_new_key` - Leaf node insert for new keys
- `northstar_core::tree::insert::update_existing_key` - Leaf node update for existing keys
- `northstar_core::tree::insert::split_leaf` - Leaf node split algorithm
- `northstar_core::tree::insert::split_internal` - Internal node split algorithm
- `northstar_core::tree::insert::propagate_split` - Split propagation loop
- `northstar_core::tree::insert::split_root` - Root split and tree growth
- `northstar_core::tree::insert::insert` - Full insert operation orchestrator

### Type Definitions

**InsertResult**: Implement as struct with fields:
```rust
pub struct InsertResult {
    pub status: InsertStatus,
    pub existing_value: Option<Value>,
    pub page_modifications: u32,
    pub tree_height_changed: bool,
}
```

**InsertStatus**: Implement as Rust enum:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InsertStatus {
    Inserted,
    Updated,
    Duplicate,
    KeyTooLarge,
    ValueTooLarge,
    NodeFull,
    IOError,
}
```

**InsertContext**: Implement as struct:
```rust
pub struct InsertContext {
    pub target_leaf: PageId,
    pub insertion_index: u16,
    pub key_exists: bool,
    pub existing_lsn: Option<Lsn>,
    pub path: SearchPath,
    pub lsn: Lsn,
}
```

**SplitPropagation**: Implement as struct:
```rust
pub struct SplitPropagation {
    pub split_node_page_id: PageId,
    pub new_node_page_id: PageId,
    pub separator_key: Vec<u8>,
    pub parent_page_id: PageId,
    pub parent_insertion_index: u16,
}
```

### Leaf Node Insert Implementation

Use Rust's slice manipulation for efficient entry shifting:
```rust
pub fn insert_new_key(
    leaf: &mut LeafNode,
    key: &[u8],
    value: &[u8],
    insertion_index: u16,
    lsn: Lsn,
) -> Result<(), InsertError> {
    // Validate sizes
    if key.len() > MAX_KEY_SIZE {
        return Err(InsertError::KeyTooLarge);
    }
    if value.len() > MAX_VALUE_SIZE {
        return Err(InsertError::ValueTooLarge);
    }

    // Calculate entry size
    let entry_size = key.len() + value.len() + LSN_SIZE + OVERHEAD;
    if leaf.free_space < entry_size as u16 {
        return Err(InsertError::NodeFull);
    }

    // Store value inline or allocate overflow pages
    let stored_value = if value.len() > OVERFLOW_THRESHOLD {
        let overflow_page_id = allocate_overflow_pages(value)?;
        StoredValue::Overflow(overflow_page_id)
    } else {
        StoredValue::Inline(value.to_vec())
    };

    // Shift entries to make space
    leaf.entries.insert(insertion_index as usize, Entry {
        key: key.to_vec(),
        value: stored_value,
        lsn,
    });

    // Update node metadata
    leaf.header.num_keys += 1;
    leaf.header.free_space -= entry_size as u16;
    leaf.header.set_flag(NodeFlags::DIRTY);
    leaf.header.generation += 1;
    leaf.header.checksum = calculate_checksum(leaf);

    Ok(())
}
```

### Version Chain Update Implementation

Prepend new version to chain:
```rust
pub fn update_existing_key(
    leaf: &mut LeafNode,
    entry_index: u16,
    new_value: &[u8],
    new_lsn: Lsn,
    snapshot_registry: &SnapshotRegistry,
) -> Result<Value, InsertError> {
    let entry = &leaf.entries[entry_index as usize];

    // Create new version
    let new_version = Entry {
        key: entry.key.clone(),
        value: StoredValue::Inline(new_value.to_vec()),
        lsn: new_lsn,
        older_version: Some(Box::new(entry.clone())),
    };

    // Check if old version can be reclaimed
    let can_reclaim = !snapshot_registry.has_active_snapshots_before(entry.lsn);

    // Replace entry with new version
    leaf.entries[entry_index as usize] = new_version;

    // Update metadata (note: entry_count unchanged)
    leaf.header.set_flag(NodeFlags::DIRTY);
    leaf.header.generation += 1;

    Ok(entry.value.clone())
}
```

### Split Implementation

Split leaf node:
```rust
pub fn split_leaf(
    leaf: &mut LeafNode,
    pager: &mut Pager,
) -> Result<SplitPropagation, InsertError> {
    // Calculate split point
    let split_point = (leaf.header.num_keys + 1) / 2;

    // Allocate new leaf node
    let new_leaf_page_id = pager.allocate_page()?;
    let mut new_leaf = LeafNode::new(new_leaf_page_id);
    new_leaf.header.parent_page_id = leaf.header.parent_page_id;

    // Move entries to new node
    let entries_to_move = leaf.entries.split_off(split_point as usize);
    new_leaf.entries.extend(entries_to_move);

    // Update entry counts
    new_leaf.header.num_keys = leaf.entries.len() as u16;
    leaf.header.num_keys = split_point;

    // Update linked list pointers
    new_leaf.header.next_leaf = leaf.header.next_leaf;
    new_leaf.header.prev_leaf = leaf.header.node_id;
    leaf.header.next_leaf = new_leaf_page_id;

    // Update next node's prev pointer
    if new_leaf.header.next_leaf != 0 {
        let mut next_leaf = pager.read_page(new_leaf.header.next_leaf)?;
        next_leaf.header.prev_leaf = new_leaf_page_id;
        pager.write_page(new_leaf.header.next_leaf, &next_leaf)?;
    }

    // Extract separator for parent
    let separator_key = new_leaf.entries[0].key.clone();

    // Update metadata
    leaf.header.set_flag(NodeFlags::DIRTY);
    new_leaf.header.set_flag(NodeFlags::DIRTY);
    leaf.header.generation += 1;
    new_leaf.header.generation += 1;

    // Write both nodes
    pager.write_page(leaf.header.node_id, leaf)?;
    pager.write_page(new_leaf_page_id, &new_leaf)?;

    Ok(SplitPropagation {
        split_node_page_id: leaf.header.node_id,
        new_node_page_id: new_leaf_page_id,
        separator_key,
        parent_page_id: leaf.header.parent_page_id,
        parent_insertion_index: 0, // TBD during parent update
    })
}
```

### Propagation Loop Implementation

Handle split propagation with loop:
```rust
pub fn propagate_split(
    tree: &mut BTree,
    mut propagation: SplitPropagation,
    pager: &mut Pager,
) -> Result<(), InsertError> {
    loop {
        // Read parent node
        let mut parent = if propagation.parent_page_id == 0 {
            // Root split needed
            return split_root(tree, propagation, pager);
        } else {
            pager.read_page(propagation.parent_page_id)?
        };

        // Check if parent has space
        let insert_size = propagation.separator_key.len() + CHILD_PTR_SIZE;
        if parent.header.free_space >= insert_size as u16 {
            // Insert separator and child pointer
            insert_separator(
                &mut parent,
                &propagation.separator_key,
                propagation.new_node_page_id,
            )?;
            pager.write_page(propagation.parent_page_id, &parent)?;
            return Ok(()); // Propagation complete
        } else {
            // Parent needs split
            let new_propagation = split_internal(parent, pager)?;

            // Update child parent pointers
            update_child_parent(pager, propagation.new_node_page_id, propagation.split_node_page_id)?;

            // Update propagation for next level
            propagation = new_propagation;
            // Continue loop to propagate to grandparent
        }
    }
}
```

### Root Split Implementation

Split root and grow tree:
```rust
pub fn split_root(
    tree: &mut BTree,
    propagation: SplitPropagation,
    pager: &mut Pager,
) -> Result<(), InsertError> {
    // Allocate new root and sibling
    let new_root_page_id = pager.allocate_page()?;
    let new_sibling_page_id = pager.allocate_page()?;

    let mut new_root = InternalNode::new(new_root_page_id);
    let mut new_sibling = Node::new_sibling(propagation.split_node_page_id);

    // Split original root
    let original_root = pager.read_page(tree.root_page_id)?;
    let (left_root, separator) = split_node(original_root, &mut new_sibling, pager)?;

    // Initialize new root
    new_root.header.is_root = true;
    new_root.header.level = left_root.header.level + 1;
    new_root.separators.push(separator);
    new_root.children.push(left_root.header.node_id);
    new_root.children.push(new_sibling.header.node_id);
    new_root.header.num_keys = 1;

    // Update child parent pointers
    left_root.header.parent_page_id = new_root_page_id;
    new_sibling.header.parent_page_id = new_root_page_id;
    left_root.header.is_root = false;

    // Write all nodes
    pager.write_page(new_root_page_id, &new_root)?;
    pager.write_page(left_root.header.node_id, &left_root)?;
    pager.write_page(new_sibling.header.node_id, &new_sibling)?;

    // Update tree metadata
    tree.root_page_id = new_root_page_id;
    tree.height += 1;

    Ok(())
}
```

### Key Decisions

**Update vs Split Decision**: Check space availability before modification. If node full, immediately trigger split rather than attempting insert and handling overflow.

**Split Point Selection**: Use ceil(num_keys / 2) for even distribution. Alternative: Choose split point to balance key ranges (more complex but can improve query performance).

**Eager vs Lazy Propagation**: Propagate splits eagerly (immediately up the tree). Alternative: Lazy propagation (mark nodes as split-needed, propagate during next operation). Eager is simpler and ensures consistency.

**Overflow Page Allocation**: Allocate overflow pages during insert phase before leaf modification. If allocation fails, abort insert without modifying tree.

**Version Chain Storage**: Store version chain pointers inline with entry. Alternative: Separate version chain page (adds indirection but reduces leaf entry size).

**Checksum Update**: Recalculate checksum after every modification. Alternative: Defer checksum calculation until flush (risky if crash occurs before flush).

### Implementation Notes

1. **Space Calculation**: Always calculate required space before modification to avoid partial updates when node is full:
   ```rust
   let required_space = key.len() + value.len() + LSN_SIZE + OVERHEAD;
   if node.free_space < required_space {
       return trigger_split();
   }
   ```

2. **Entry Shifting**: Use Vec::insert for automatic shifting:
   ```rust
   entries.insert(insertion_index, new_entry);
   ```
   For better performance with large arrays, consider manual shifting with copy_from_slice.

3. **Overflow Value Handling**: Distinguish inline vs overflow values:
   ```rust
   pub enum StoredValue {
       Inline(Vec<u8>),
       Overflow(PageId), // Page ID of first overflow page
   }
   ```

4. **Parent Pointer Updates**: After split, update parent pointers for all moved children. This is critical for tree traversal and future split propagation.

5. **Linked List Updates**: When splitting leaf nodes, always update three pointers:
   - new_node.next_leaf
   - new_node.prev_leaf
   - next_node.prev_leaf (if next_node exists)

6. **Dirty Flag Management**: Set dirty flag immediately after modification. Clear dirty flag only after successful flush to disk.

7. **Generation Counter**: Increment generation counter on every modification (insert, update, split). Use for optimistic concurrency control in future versions.

8. **Root Split Special Case**: Root split is the only time tree height increases. Must update database metadata atomically with root page write.

9. **Error Rollback**: If split propagation fails partway through, attempt to rollback completed modifications. This may require deallocating allocated nodes and restoring original node state.

10. **Concurrent Reads**: During insert, concurrent readers should not block. Use copy-on-write: readers access old node version, writer modifies new version and swaps pointer atomically.

### Testing Strategy

**Unit tests needed for**:
- Insert new key in empty leaf
- Insert new key in non-empty leaf with sufficient space
- Insert at various positions (beginning, middle, end)
- Insert with key larger than maximum (error handling)
- Insert with value larger than maximum (error handling)
- Update existing key with new value
- Update with value size change (inline to overflow, overflow to inline)
- Leaf split at various occupancy levels (just full, very full)
- Leaf split with overflow page references
- Internal node insert with sufficient space
- Internal node split at various occupancy levels
- Root split (leaf to height-1 tree)
- Root split (internal to height+1 tree)
- Cascading splits (leaf → internal → root)
- Separator key extraction correctness
- Linked list pointer updates after leaf split
- Parent pointer updates after internal node split
- Tree height increment after root split
- Metadata update after root split

**Property tests for**:
- Insert maintains key ordering invariant
- Split maintains occupancy rules (both nodes at least half full)
- Split propagation terminates (reaches root or non-full parent)
- Root split increases tree height by exactly 1
- After insert, all tree invariants hold (verify function passes)
- Version chain LSNs are monotonically increasing
- Parent pointers form consistent tree structure (no cycles)
- Leaf linked list is consistent (next/prev pointers match)

**Integration scenarios**:
- Insert 1K keys sequentially, verify tree structure
- Insert 1M keys with random order, verify height and occupancy
- Insert causing multiple splits, verify all nodes valid
- Insert into tree with concurrent readers (MVCC correctness)
- Insert, crash during split, recover, verify consistency
- Insert with value overflow pages, verify overflow chain correctness
- Insert then search, verify new key findable
- Update existing key, verify version chain correct
- Insert then delete same key, verify key removed

**Fuzzing targets**:
- Insert with invalid key sizes (0, 256, very large)
- Insert with invalid value sizes (0, 16MB+1, very large)
- Insert with malformed keys (non-UTF8, random bytes)
- Rapid inserts causing many splits (stress test)
- Insert sequence that creates unbalanced tree (pathological keys)
- Insert during concurrent operations (race conditions)
- Insert with I/O errors injected (recovery testing)

**Performance benchmarks**:
- Insert throughput (keys per second)
- Insert latency (p50, p99) for various tree sizes
- Split cost (time per split operation)
- Root split cost (tree growth overhead)
- Leaf vs internal split cost comparison
- Propagation cost (splits at multiple levels)
- Overflow page allocation impact on insert latency
- Concurrent insert vs read performance (MVCC overhead)

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and insert overview
- **06-btree-node.md**: Internal and leaf node structures for insert targets
- **06-btree-header.md**: Node header fields updated during insert
- **06-btree-search.md**: Search algorithm to find insertion point
- **06-btree-split.md**: Detailed split algorithms (referenced but not expanded here)
- **06-btree-key.md**: Key encoding and comparison for ordering
- **06-btree-value.md**: Value storage and overflow page handling
- **02-pager-*.md**: Pager integration for node allocation and I/O
- **03-wal-*.md**: WAL integration for crash-safe inserts
- **04-txn-*.md**: Transaction system integration for LSN allocation
