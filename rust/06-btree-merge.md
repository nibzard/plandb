# B+Tree Node Merge Operation

## Purpose

The merge operation combines two sibling nodes that are both at or near minimum occupancy, restoring balance after deletes. Merges are triggered when a node becomes underfull (below MINIMUM_OCCUPANCY) after a delete operation and neither sibling has excess entries to borrow. Merging is the inverse of splitting: it reduces tree height when root merges, and it maintains the B+Tree occupancy invariant by eliminating sparse nodes. This specification covers merge algorithms for both leaf and internal nodes, merge condition detection, separator handling during merge, cascade operations for maintaining tree structure, and comprehensive error handling strategies.

## Types

### MergeResult

**Description**: Result type returned by merge operations containing merge metadata

**Fields**:
- **merged_into**: PageId - Page ID of node that absorbed entries (surviving node)
- - **merged_from**: PageId - Page ID of node that was deallocated (consumed node)
- **entries_absorbed**: u16 - Number of entries moved from consumed node
- **separator_deleted**: Vec<u8> - Separator key removed from parent (if applicable)
- **parent_page_id**: PageId - Parent node that had separator deleted
- **is_root_merge**: bool - True if merge occurred at root level (tree shrink)

**Rationale**: Encapsulates all information needed to update parent and track merge outcome

### MergeDirection

**Description**: Enumeration of possible merge directions

**Values**:
- **MergeLeft**: Merge left sibling into right sibling
- **MergeRight**: Merge right sibling into left sibling
- **MergeEither**: Direction chosen based on free space (prefer right into left)

**Rationale**: Merge direction affects which node survives and how separator is handled

### MergeContext

**Description**: Context structure tracking state during merge operation

**Fields**:
- **underfull_node**: PageId - Page ID of underfull node triggering merge
- **target_sibling**: PageId - Page ID of sibling to merge with
- **merge_direction**: MergeDirection - Which node absorbs which
- **parent_page_id**: PageId - Parent node containing separator
- **separator_index**: u16 - Index of separator in parent node
- **total_entries**: u16 - Combined entry count after merge
- **fits_in_one_node**: bool - True if combined entries fit in single node

**Rationale**: Captures merge planning state for validation and execution

### MergeCandidates

**Description**: Result of merge eligibility check for siblings

**Fields**:
- **left_sibling_id**: Option<PageId> - Left sibling page ID (if exists)
- **right_sibling_id**: Option<PageId> - Right sibling page ID (if exists)
- **left_can_merge**: bool - True if left sibling can absorb underfull node
- **right_can_merge**: bool - True if right sibling can absorb underfull node
- **preferred_direction**: Option<MergeDirection> - Recommended merge direction

**Rationale**: Provides merge eligibility and direction recommendation

## Algorithms

### Merge Condition Detection

**Purpose**: Determine if two sibling nodes should merge based on occupancy

**Context**: Node is underfull after delete, checking if siblings can absorb entries

**Algorithm**:

1. **Input**: Underfull node page ID, parent node page ID
2. **Read Underfull Node**:
   - underfull_node = pager.read_page(underfull_node_id)
   - underfull_entry_count = underfull_node.header.num_keys
3. **Read Parent Node**:
   - parent = pager.read_page(parent_page_id)
4. **Locate Underfull Node in Parent**:
   - Execute binary search in parent for separator that leads to underfull_node
   - separator_index = search result
5. **Identify Siblings**:
   - If separator_index > 0:
     - left_sibling_id = parent.child_pointers[separator_index - 1]
   - Else:
     - left_sibling_id = None (no left sibling)
   - If separator_index < parent.header.num_keys:
     - right_sibling_id = parent.child_pointers[separator_index + 1]
   - Else:
     - right_sibling_id = None (no right sibling)
6. **Check Left Sibling Eligibility**:
   - If left_sibling_id exists:
     - left_sibling = pager.read_page(left_sibling_id)
     - combined_count = underfull_entry_count + left_sibling.header.num_keys
     - max_capacity = calculate_max_capacity(left_sibling)
     - left_can_merge = (combined_count <= max_capacity)
   - Else:
     - left_can_merge = false
7. **Check Right Sibling Eligibility**:
   - If right_sibling_id exists:
     - right_sibling = pager.read_page(right_sibling_id)
     - combined_count = underfull_entry_count + right_sibling.header.num_keys
     - max_capacity = calculate_max_capacity(right_sibling)
     - right_can_merge = (combined_count <= max_capacity)
   - Else:
     - right_can_merge = false
8. **Determine Preferred Direction**:
   - If left_can_merge && right_can_merge:
     - Prefer MergeIntoLeft (right into left) for sequential scan locality
   - Else if left_can_merge:
     - preferred_direction = MergeRight (left absorbs underfull)
   - Else if right_can_merge:
     - preferred_direction = MergeLeft (right absorbs underfull)
   - Else:
     - preferred_direction = None (neither can merge, must borrow or fail)
9. **Return**: MergeCandidates with eligibility and direction

**Time Complexity**: O(1) for reads and comparisons

**Space Complexity**: O(1)

**Returns**: MergeCandidates indicating merge eligibility

**Error Conditions**:
- **InvalidParent**: Parent node validation fails
- **NodeNotFound**: Underfull node or sibling not found
- **CorruptNode**: Node header validation fails

**Concurrency**: Shared read access to siblings

### Leaf Node Merge (Right into Left)

**Purpose**: Merge right leaf node into left leaf node

**Context**: Left and right siblings both at minimum occupancy, combined entries fit in one node

**Algorithm**:

1. **Input**: Left leaf node, right leaf node, parent node, separator_index
2. **Calculate Combined Entry Count**:
   - left_count = left_leaf.header.num_keys
   - right_count = right_leaf.header.num_keys
   - combined_count = left_count + right_count
   - Verify combined_count <= MAXIMUM_CAPACITY
3. **Move Entries from Right to Left**:
   - For each entry in right_leaf.entries (in order):
     - Append entry to left_leaf.entries
     - Update left_leaf.header.num_keys += 1
4. **Update Left Leaf Linked List Pointers**:
   - Set left_leaf.next_leaf = right_leaf.next_leaf
   - If right_leaf.next_leaf != 0:
     - Read next_next_leaf node
     - Set next_next_leaf.prev_leaf = left_leaf.page_id
     - Write next_next_leaf back to Pager
5. **Delete Separator from Parent**:
   - separator_to_delete = parent.separators[separator_index]
   - Remove parent.separators[separator_index]
   - Remove parent.child_pointers[separator_index + 1] (right leaf pointer)
   - Shift subsequent separators and child pointers left
   - Update parent.header.num_keys -= 1
6. **Update Left Leaf Metadata**:
   - Recalculate left_leaf.header.free_space
   - Set left_leaf.header.dirty flag
   - Increment left_leaf.header.generation counter
   - Recalculate left_leaf.header.checksum
7. **Mark Right Leaf for Deletion**:
   - Add right_leaf.page_id to free list (Pager deallocation)
   - Right leaf will be reclaimed during next free list scan
8. **Write Modified Nodes**:
   - Write left_leaf to Pager
   - Write parent to Pager
   - (Right leaf not written, will be deallocated)
9. **Validate Merge**:
   - Verify left_leaf.header.num_keys == combined_count
   - Verify all entries from right_leaf present in left_leaf
   - Verify linked list consistency (prev/next pointers valid)
   - Verify parent separator deleted
10. **Construct MergeResult**:
    - Return MergeResult with:
      - merged_into = left_leaf.page_id
      - merged_from = right_leaf.page_id
      - entries_absorbed = right_count
      - separator_deleted = separator_to_delete
      - parent_page_id = parent.page_id
      - is_root_merge = parent.is_root

**Time Complexity**:
- Entry movement: O(n) where n is entries in right leaf
- Linked list update: O(1)
- Parent separator delete: O(s) where s is separators in parent
- Total: O(n + s)

**Space Complexity**: O(1) (deallocates right leaf)

**Returns**: MergeResult containing merge metadata

**Error Conditions**:
- **MergeFailed**: Combined entries exceed maximum capacity
- **IOError**: Pager read/write operation fails
- **CorruptNode**: Node validation fails
- **BrokenLinkedList**: Linked list pointer inconsistency detected
- **ParentUpdateFailed**: Cannot delete separator from parent

**Concurrency**: Exclusive access required (blocks operations on both leaves and parent)

**Edge Cases**:
- **Merge at tree boundary**: Left or right leaf at list edge, handle null pointers
- **Merge with overflow pages**: Overflow page IDs moved correctly
- **Merge with tombstones**: Tombstone entries moved, reclamation triggered later
- **Empty right leaf**: Right leaf has no entries (should not occur with correct occupancy checks)

### Leaf Node Merge (Left into Right)

**Purpose**: Merge left leaf node into right leaf node

**Context**: Left and right siblings both at minimum occupancy, prefer right as surviving node

**Algorithm**:

1. **Input**: Left leaf node, right leaf node, parent node, separator_index
2. **Calculate Combined Entry Count**:
   - left_count = left_leaf.header.num_keys
   - right_count = right_leaf.header.num_keys
   - combined_count = left_count + right_count
   - Verify combined_count <= MAXIMUM_CAPACITY
3. **Move Entries from Left to Right**:
   - For each entry in left_leaf.entries (in order):
     - Prepend entry to right_leaf.entries (insert at beginning)
     - Update right_leaf.header.num_keys += 1
   - Alternative: Extend right_leaf.entries, sort (less efficient)
4. **Update Right Leaf Linked List Pointers**:
   - Set right_leaf.prev_leaf = left_leaf.prev_leaf
   - If left_leaf.prev_leaf != 0:
     - Read prev_prev_leaf node
     - Set prev_prev_leaf.next_leaf = right_leaf.page_id
     - Write prev_prev_leaf back to Pager
5. **Delete Separator from Parent**:
   - separator_to_delete = parent.separators[separator_index]
   - Remove parent.separators[separator_index]
   - Remove parent.child_pointers[separator_index] (left leaf pointer)
   - Shift subsequent separators and child pointers left
   - Update parent.header.num_keys -= 1
6. **Update Right Leaf Metadata**:
   - Recalculate right_leaf.header.free_space
   - Set right_leaf.header.dirty flag
   - Increment right_leaf.header.generation counter
   - Recalculate right_leaf.header.checksum
7. **Mark Left Leaf for Deletion**:
   - Add left_leaf.page_id to free list
8. **Write Modified Nodes**:
   - Write right_leaf to Pager
   - Write parent to Pager
9. **Validate Merge**:
   - Verify right_leaf.header.num_keys == combined_count
   - Verify all entries from left_leaf present in right_leaf
   - Verify linked list consistency
10. **Construct MergeResult**:
    - Return MergeResult with:
      - merged_into = right_leaf.page_id
      - merged_from = left_leaf.page_id
      - entries_absorbed = left_count
      - separator_deleted = separator_to_delete
      - parent_page_id = parent.page_id
      - is_root_merge = parent.is_root

**Time Complexity**: O(n + s) (same as right-into-left merge)

**Space Complexity**: O(1)

**Returns**: MergeResult

**Rationale**: Merging left into right is less common (right-into-left preferred for scan locality), but necessary when right has more free space.

### Internal Node Merge

**Purpose**: Merge two internal child nodes after their parent lost a separator

**Context**: Child node merged, parent separator deleted, parent now underfull

**Algorithm**:

1. **Input**: Left internal node, right internal node, parent node, separator_index
2. **Extract Separator from Parent**:
   - separator = parent.separators[separator_index]
   - This separator divided the two children, will be inserted into merged node
3. **Calculate Combined Count**:
   - left_separators = left_internal.header.num_keys
   - right_separators = right_internal.header.num_keys
   - combined_separators = left_separators + 1 + right_separators (+1 for parent separator)
   - combined_children = left_separators + 1 + right_separators + 1
   - Verify combined_separators <= MAXIMUM_SEPARATORS
4. **Append Separator to Left Node**:
   - Append parent separator to left_internal.separators
   - left_internal.header.num_keys += 1
5. **Move Separators from Right to Left**:
   - For each separator in right_internal.separators (in order):
     - Append separator to left_internal.separators
     - left_internal.header.num_keys += 1
6. **Move Child Pointers from Right to Left**:
   - For each child pointer in right_internal.children (in order):
     - Append child pointer to left_internal.children
   - Update child.parent_page_id = left_internal.page_id for all moved children
7. **Delete Separator from Parent**:
   - Remove parent.separators[separator_index]
   - Remove parent.child_pointers[separator_index + 1]
   - Shift subsequent separators and child pointers left
   - parent.header.num_keys -= 1
8. **Update Left Internal Metadata**:
   - Recalculate left_internal.header.free_space
   - Set left_internal.header.dirty flag
   - Increment left_internal.header.generation counter
   - Recalculate left_internal.header.checksum
9. **Mark Right Internal for Deletion**:
   - Add right_internal.page_id to free list
10. **Write Modified Nodes**:
    - Write left_internal to Pager
    - Write parent to Pager
    - Write updated children to Pager (parent pointer updates)
11. **Validate Merge**:
    - Verify left_internal.header.num_keys == combined_separators
    - Verify child pointer count = separator count + 1
    - Verify all parent pointers updated correctly
12. **Construct MergeResult**:
    - Return MergeResult with:
      - merged_into = left_internal.page_id
      - merged_from = right_internal.page_id
      - entries_absorbed = right_separators + 1 (+1 for separator)
      - separator_deleted = separator
      - parent_page_id = parent.page_id
      - is_root_merge = parent.is_root

**Time Complexity**:
- Separator/child movement: O(n) where n is separators in right node
- Parent pointer updates: O(c) where c is children moved
- Parent separator delete: O(p) where p is separators in parent
- Total: O(n + c + p)

**Space Complexity**: O(1)

**Returns**: MergeResult

**Error Conditions**:
- **MergeFailed**: Combined separators exceed maximum capacity
- **IOError**: Pager operation fails
- **CorruptNode**: Node validation fails
- **ParentUpdateFailed**: Cannot delete separator from parent
- **ChildUpdateFailed**: Cannot update child parent pointers

**Concurrency**: Exclusive access required (blocks entire subtree)

**Edge Cases**:
- **Merge at root level**: Root has only 2 children, merge creates single child (tree shrink)
- **Deep internal merge**: Merging internal nodes at high level (e.g., level 5)
- **Large fanout**: Merging nodes with hundreds of separators and children

### Root Merge (Tree Shrink)

**Purpose**: Merge root's two children and decrease tree height by one level

**Context**: Root internal node has only 1 separator and 2 children, merge children into new root

**Algorithm**:

1. **Input**: Root internal node with 1 separator, 2 children
2. **Verify Root Merge Condition**:
   - Verify root.is_root == true
   - Verify root.header.num_keys == 1
   - Verify root has exactly 2 children
3. **Read Child Nodes**:
   - left_child = pager.read_page(root.child_pointers[0])
   - right_child = pager.read_page(root.child_pointers[1])
4. **Merge Children**:
   - If children are leaf nodes:
     - Execute leaf node merge (right into left or vice versa)
   - If children are internal nodes:
     - Execute internal node merge
   - merged_node = surviving child after merge
5. **Promote Merged Node to Root**:
   - Set merged_node.is_root = true
   - Set merged_node.parent_page_id = 0
6. **Update Database Metadata**:
   - new_root_page_id = merged_node.page_id
   - Update root_page_id in database metadata
   - Decrement tree_height counter = old_tree_height - 1
   - Flush metadata to disk
7. **Deallocate Old Root and Consumed Child**:
   - Add root.page_id to free list
   - Add consumed_child.page_id to free list
8. **Write Merged Root**:
   - Write merged_node to Pager
9. **Validate Tree Shrink**:
   - Verify new_root_page_id matches metadata
   - Verify tree_height decreased by exactly 1
   - Verify new_root.is_root == true
    - Verify new_root.parent_page_id == 0
   - Verify all keys reachable from new root
10. **Construct MergeResult**:
    - Return MergeResult with:
      - merged_into = new_root_page_id
      - merged_from = consumed_child.page_id
      - entries_absorbed = entries count in consumed child
      - separator_deleted = root.separators[0]
      - parent_page_id = 0 (root has no parent)
      - is_root_merge = true

**Time Complexity**:
- Child merge: O(n) where n is entries in children
- Metadata update: O(1)
- Total: O(n)

**Space Complexity**: O(-1) (deallocates 2 nodes, creates 0 new nodes)

**Returns**: MergeResult with is_root_merge flag set

**Error Conditions**:
- **InvalidRootState**: Root doesn't have exactly 1 separator and 2 children
- **MergeFailed**: Child merge fails
- **MetadataUpdateFailed**: Cannot persist new root_page_id
- **RootCorruption**: Root structure invalid before or after merge

**Concurrency**: Exclusive access required (blocks entire tree)

**Critical**: Root merge must be atomic. If crash occurs, recovery must either:
- Roll back to pre-merge state (old root still root)
- Complete merge (new root is root, tree height decreased)

**Edge Cases**:
- **Shrink to single leaf**: Tree height goes from 1 to 0 (root becomes leaf)
- **Shrink large tree**: Tree height goes from 10 to 9 (still efficient)
- **Empty tree after merge**: All keys deleted, tree has empty root leaf

## Cascade Merge Operations

**Purpose**: Propagate merge operations upward when parent becomes underfull

**Context**: Merge at one level deletes parent separator, causing parent underflow

**Algorithm - Cascade Merge**:

1. **Input**: MergeResult from child merge indicating parent underflow
2. **Check Parent Underflow**:
   - parent = pager.read_page(merge_result.parent_page_id)
   - If parent.header.num_keys >= MINIMUM_OCCUPANCY:
     - Return merge_result (cascade not needed)
   - Else (parent underfull):
     - Proceed with cascade
3. **Check if Parent is Root**:
   - If parent.is_root == true:
     - If parent.header.num_keys == 1:
       - Execute root merge algorithm (tree shrink)
     - Else:
       - Return merge_result (root can have 1 separator)
4. **Trigger Parent Merge**:
   - Execute merge condition detection for parent
   - Identify parent's siblings and merge eligibility
   - If parent can merge with sibling:
     - Execute merge at this level
     - Create new MergeResult for parent merge
   - Else if parent can borrow from sibling:
     - Execute borrow operation (see 06-btree-borrow.md)
     - Return borrow result
   - Else:
     - Return error (tree corruption, parent underfull but cannot rebalance)
5. **Propagate Upward**:
   - If parent merge succeeded and grandparent became underfull:
     - Recurse with grandparent
   - Continue cascade until root or non-underfull node reached
6. **Return**: Final MergeResult at highest level merged

**Time Complexity**: O(h * n) where h is tree height, n is node size

**Space Complexity**: O(h) for recursion stack

**Returns**: MergeResult at highest level

**Rationale**: Deletes can trigger cascading merges up the tree to root, similar to cascading splits during inserts.

## Error Handling

### Merge Condition Errors

**CannotMerge**:
- **Detection**: Combined entries exceed maximum capacity
- **Handling**:
  - Abort merge operation
  - Attempt borrow operation instead
  - If borrow also fails: return error
- **Recovery**: Use borrow to redistribute entries between siblings
- **User Action**: No action needed (borrow should succeed)

**NoSiblingAvailable**:
- **Detection**: Node has no left or right sibling to merge with
- **Handling**:
  - Abort merge operation
  - Return error to caller
- **Recovery**: Tree corruption (node should have sibling unless root)
- **User Action**: Run database verification and repair

### I/O Errors

**ReadFailure**:
- **Detection**: Pager.read_page() fails during merge (reading sibling, parent)
- **Handling**:
  - Abort merge operation
  - Return error to caller
- **Recovery**: Retry merge or abort transaction
-**User Action**: Check disk health, retry operation

**WriteFailure**:
- **Detection**: Pager.write_page() fails after node merge
- **Handling**:
  - Abort merge operation
  - Mark tree as inconsistent (nodes partially merged)
  - Return error to caller
- **Recovery**:
  - Recovery process detects partial merge (surviving node has wrong count)
  - Completes merge or rolls back from WAL
- **User Action**: Run database recovery

**MetadataWriteFailure** (Root merge):
- **Detection**: Cannot update database metadata with new root_page_id
- **Handling**:
  - CRITICAL: Tree now has two roots (old and new)
  - Mark database as inconsistent
  - Initiate emergency recovery
- **Recovery**: Recovery detects two roots, uses WAL to determine correct root
- **User Action**: Restart database, recovery runs automatically

### Structural Errors

**MergeValidationFailed**:
- **Detection**: Combined entry count validation fails after merge
- **Handling**:
  - Abort merge operation
  - Tree may have corrupted state
  - Return error
- **Recovery**: Rebuild tree structure from WAL
- **User Action**: Run database recovery

**BrokenLinkedList** (Leaf merge):
- **Detection**: Linked list pointer inconsistency detected after merge
- **Handling**:
  - Abort merge operation
  - Mark list as corrupted
  - Return error
- **Recovery**: Rebuild leaf linked list by scanning all leaves
- **User Action**: Run database repair

**ChildParentPointerInconsistency** (Internal merge):
- **Detection**: Child parent pointers not updated correctly after merge
- **Handling**:
  - Abort merge operation
  - Mark tree as corrupted
  - Return error
- **Recovery**: Traverse tree, rebuild parent pointers
- **User Action**: Run database verification and repair

**CascadeFailure**:
- **Detection**: Parent merge fails during cascade
- **Handling**:
  - Abort cascade operation
  - Tree has inconsistent state (child merged, parent not)
  - Mark as needing repair
- **Recovery**: Recovery completes cascade or rolls back child merge
- **User Action**: Run database recovery

## Invariants

### Merge Invariants

1. **Capacity Constraint**: Combined entries must fit in one node (<= MAXIMUM_CAPACITY)
2. **Entry Preservation**: All entries from both nodes present in merged node
3. **No Entry Loss**: No entries lost during merge
4. **No Entry Duplication**: No entry appears twice in merged node
5. **Key Ordering**: Key ordering maintained after merge

### Leaf Merge Invariants

1. **Linked List Consistency**: Next/prev pointers form valid list after merge
2. **List Connectivity**: All leaves remain reachable from first leaf
3. **Boundary Preservation**: First and last leaf boundaries updated correctly
4. **Overflow References**: Overflow page IDs moved correctly to merged node
5. **Tombstone Handling**: Tombstone entries moved with reclamation scheduled

### Internal Merge Invariants

1. **Separator Insertion**: Parent separator inserted between child separators
2. **Child Distribution**: All children from both nodes present in merged node
3. **Child Pointer Count**: child_ptr_count = separator_count + 1 after merge
4. **Parent Pointer Correctness**: All children have correct parent_page_id
5. **Level Preservation**: Merged node at same level as original children

### Root Merge Invariants

1. **Single Root**: Exactly one root exists after merge
2. **Height Decrement**: Tree height decreases by exactly 1
3. **New Root Validity**: New root is surviving child node
4. **Metadata Consistency**: Database metadata root_page_id matches actual root
5. **Old Root Freed**: Old root page added to free list

### Cascade Merge Invariants

1. **Upward Propagation**: Merge propagates toward root
2. **Termination**: Cascade terminates at root or non-underfull node
3. **Consistent State**: All intermediate levels valid after cascade
4. **Atomicity**: Either entire cascade completes or none does
5. **Recovery Support**: WAL enables recovery from partial cascade

## Rust Implementation Guidance

### Module Structure

The merge functionality should be organized as:
- `northstar_core::tree::merge::check_merge_eligibility` - Merge condition detection
- `northstar_core::tree::merge::merge_leaf_right_into_left` - Leaf merge (right into left)
- `northstar_core::tree::merge::merge_leaf_left_into_right` - Leaf merge (left into right)
- `northstar_core::tree::merge::merge_internal_nodes` - Internal node merge
- `northstar_core::tree::merge::merge_root` - Root merge and tree shrink
- `northstar_core::tree::merge::cascade_merge` - Upward merge propagation
- `northstar_core::tree::merge::validate_merge` - Merge validation and consistency checks

### Type Definitions

**MergeResult**: Implement as struct:
```rust
pub struct MergeResult {
    pub merged_into: PageId,
    pub merged_from: PageId,
    pub entries_absorbed: u16,
    pub separator_deleted: Vec<u8>,
    pub parent_page_id: PageId,
    pub is_root_merge: bool,
}
```

**MergeDirection**: Implement as enum:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeDirection {
    MergeLeft,   // Merge left sibling into right
    MergeRight,  // Merge right sibling into left
    MergeEither, // Direction chosen by algorithm
}
```

**MergeContext**: Implement as struct:
```rust
pub struct MergeContext {
    pub underfull_node: PageId,
    pub target_sibling: PageId,
    pub merge_direction: MergeDirection,
    pub parent_page_id: PageId,
    pub separator_index: u16,
    pub total_entries: u16,
    pub fits_in_one_node: bool,
}
```

**MergeCandidates**: Implement as struct:
```rust
pub struct MergeCandidates {
    pub left_sibling_id: Option<PageId>,
    pub right_sibling_id: Option<PageId>,
    pub left_can_merge: bool,
    pub right_can_merge: bool,
    pub preferred_direction: Option<MergeDirection>,
}
```

### Merge Condition Detection

Check merge eligibility:
```rust
pub fn check_merge_eligibility(
    underfull_node_id: PageId,
    parent_page_id: PageId,
    pager: &Pager,
) -> Result<MergeCandidates, MergeError> {
    // Read underfull node
    let underfull_node = pager.read_page(underfull_node_id)?;
    let underfull_count = underfull_node.header.num_keys;

    // Read parent
    let parent = pager.read_page(parent_page_id)?;

    // Find underfull node in parent
    let separator_index = find_child_index(&parent, underfull_node_id)?;

    // Identify siblings
    let left_sibling_id = if separator_index > 0 {
        Some(parent.child_pointers[separator_index - 1])
    } else {
        None
    };

    let right_sibling_id = if separator_index < parent.header.num_keys {
        Some(parent.child_pointers[separator_index + 1])
    } else {
        None
    };

    // Check left sibling eligibility
    let left_can_merge = if let Some(left_id) = left_sibling_id {
        let left_sibling = pager.read_page(left_id)?;
        let combined = underfull_count + left_sibling.header.num_keys;
        combined <= MAXIMUM_CAPACITY
    } else {
        false
    };

    // Check right sibling eligibility
    let right_can_merge = if let Some(right_id) = right_sibling_id {
        let right_sibling = pager.read_page(right_id)?;
        let combined = underfull_count + right_sibling.header.num_keys;
        combined <= MAXIMUM_CAPACITY
    } else {
        false
    };

    // Determine preferred direction
    let preferred_direction = match (left_can_merge, right_can_merge) {
        (true, true) => Some(MergeDirection::MergeRight), // Prefer right into left
        (true, false) => Some(MergeDirection::MergeRight),
        (false, true) => Some(MergeDirection::MergeLeft),
        (false, false) => None,
    };

    Ok(MergeCandidates {
        left_sibling_id,
        right_sibling_id,
        left_can_merge,
        right_can_merge,
        preferred_direction,
    })
}
```

### Leaf Merge Implementation

Merge right leaf into left leaf:
```rust
pub fn merge_leaf_right_into_left(
    left_leaf: &mut LeafNode,
    right_leaf: &mut LeafNode,
    parent: &mut InternalNode,
    separator_index: usize,
    pager: &mut Pager,
) -> Result<MergeResult, MergeError> {
    // Calculate combined count
    let left_count = left_leaf.header.num_keys;
    let right_count = right_leaf.header.num_keys;
    let combined_count = left_count + right_count;

    if combined_count > MAXIMUM_CAPACITY {
        return Err(MergeError::CannotMerge);
    }

    // Move entries from right to left
    let entries_to_move = right_leaf.entries.clone();
    left_leaf.entries.extend(entries_to_move);
    left_leaf.header.num_keys = combined_count;

    // Update linked list
    let right_next = right_leaf.header.next_leaf;
    left_leaf.header.next_leaf = right_next;

    if right_next != 0 {
        let mut next_leaf = pager.read_page::<LeafNode>(right_next)?;
        next_leaf.header.prev_leaf = left_leaf.header.node_id;
        next_leaf.header.set_flag(NodeFlags::DIRTY);
        next_leaf.header.generation += 1;
        next_leaf.header.checksum = calculate_checksum(&next_leaf);
        pager.write_page(right_next, &next_leaf)?;
    }

    // Delete separator from parent
    let separator_deleted = parent.separators[separator_index].clone();
    parent.separators.remove(separator_index);
    parent.children.remove(separator_index + 1);
    parent.header.num_keys -= 1;

    // Update left leaf metadata
    left_leaf.header.free_space = calculate_free_space(left_leaf);
    left_leaf.header.set_flag(NodeFlags::DIRTY);
    left_leaf.header.generation += 1;
    left_leaf.header.checksum = calculate_checksum(left_leaf);

    // Write nodes
    pager.write_page(left_leaf.header.node_id, left_leaf)?;
    pager.write_page(parent.header.node_id, parent)?;

    // Deallocate right leaf
    pager.deallocate_page(right_leaf.header.node_id)?;

    Ok(MergeResult {
        merged_into: left_leaf.header.node_id,
        merged_from: right_leaf.header.node_id,
        entries_absorbed: right_count,
        separator_deleted,
        parent_page_id: parent.header.node_id,
        is_root_merge: parent.header.is_root,
    })
}
```

### Internal Merge Implementation

Merge internal nodes:
```rust
pub fn merge_internal_nodes(
    left_internal: &mut InternalNode,
    right_internal: &mut InternalNode,
    parent: &mut InternalNode,
    separator_index: usize,
    pager: &mut Pager,
) -> Result<MergeResult, MergeError> {
    // Extract separator from parent
    let separator = parent.separators[separator_index].clone();

    // Append separator to left
    left_internal.separators.push(separator);

    // Move separators from right to left
    let separators_to_move = right_internal.separators.clone();
    left_internal.separators.extend(separators_to_move);

    // Move children from right to left
    let children_to_move = right_internal.children.clone();
    for child_id in &children_to_move {
        // Update child parent pointers
        let mut child = pager.read_page(child_id)?;
        child.header.parent_page_id = left_internal.header.node_id;
        child.header.set_flag(NodeFlags::DIRTY);
        child.header.generation += 1;
        child.header.checksum = calculate_checksum(&child);
        pager.write_page(*child_id, &child)?;
    }
    left_internal.children.extend(children_to_move);

    // Update counts
    left_internal.header.num_keys += 1 + right_internal.header.num_keys;

    // Delete separator from parent
    let separator_deleted = parent.separators[separator_index].clone();
    parent.separators.remove(separator_index);
    parent.children.remove(separator_index + 1);
    parent.header.num_keys -= 1;

    // Update left internal metadata
    left_internal.header.free_space = calculate_free_space(left_internal);
    left_internal.header.set_flag(NodeFlags::DIRTY);
    left_internal.header.generation += 1;
    left_internal.header.checksum = calculate_checksum(left_internal);

    // Write nodes
    pager.write_page(left_internal.header.node_id, left_internal)?;
    pager.write_page(parent.header.node_id, parent)?;

    // Deallocate right internal
    pager.deallocate_page(right_internal.header.node_id)?;

    Ok(MergeResult {
        merged_into: left_internal.header.node_id,
        merged_from: right_internal.header.node_id,
        entries_absorbed: right_internal.header.num_keys + 1,
        separator_deleted,
        parent_page_id: parent.header.node_id,
        is_root_merge: parent.header.is_root,
    })
}
```

### Root Merge Implementation

Merge root's children and shrink tree:
```rust
pub fn merge_root(
    root: &mut InternalNode,
    pager: &mut Pager,
) -> Result<MergeResult, MergeError> {
    // Verify root merge condition
    if !root.header.is_root {
        return Err(MergeError::NotRoot);
    }
    if root.header.num_keys != 1 {
        return Err(MergeError::InvalidRootState);
    }

    // Read children
    let left_child_id = root.children[0];
    let right_child_id = root.children[1];

    let mut left_child = pager.read_page(left_child_id)?;
    let mut right_child = pager.read_page(right_child_id)?;

    // Merge children
    let merge_result = match (&left_child, &right_child) {
        (Node::Leaf(left), Node::Leaf(right)) => {
            merge_leaf_right_into_left(left, right, root, 0, pager)?
        }
        (Node::Internal(left), Node::Internal(right)) => {
            merge_internal_nodes(left, right, root, 0, pager)?
        }
        _ => return Err(MergeError::MismatchedNodeTypes),
    };

    // Promote merged child to root
    let new_root_id = merge_result.merged_into;
    let mut new_root = pager.read_page(new_root_id)?;
    new_root.header.is_root = true;
    new_root.header.parent_page_id = 0;
    new_root.header.set_flag(NodeFlags::DIRTY);
    new_root.header.generation += 1;
    new_root.header.checksum = calculate_checksum(&new_root);
    pager.write_page(new_root_id, &new_root)?;

    // Update metadata
    pager.update_root_page_id(new_root_id)?;
    pager.decrement_tree_height()?;

    // Deallocate old root and consumed child
    pager.deallocate_page(root.header.node_id)?;
    pager.deallocate_page(merge_result.merged_from)?;

    Ok(merge_result)
}
```

### Cascade Merge Implementation

Propagate merge upward:
```rust
pub fn cascade_merge(
    mut merge_result: MergeResult,
    pager: &mut Pager,
) -> Result<MergeResult, MergeError> {
    let mut parent_page_id = merge_result.parent_page_id;

    loop {
        // Read parent
        let mut parent = pager.read_page(parent_page_id)?;

        // Check if parent is underfull
        if parent.header.num_keys >= MINIMUM_OCCUPANCY {
            return Ok(merge_result);
        }

        // Check if parent is root
        if parent.header.is_root {
            if parent.header.num_keys == 1 {
                // Root merge (tree shrink)
                return merge_root(&mut parent, pager);
            } else {
                return Ok(merge_result);
            }
        }

        // Trigger parent merge
        let parent_parent_id = parent.header.parent_page_id;
        let candidates = check_merge_eligibility(parent_page_id, parent_parent_id, pager)?;

        match candidates.preferred_direction {
            Some(direction) => {
                // Execute parent merge
                merge_result = execute_merge(&candidates, direction, pager)?;
                parent_page_id = parent_parent_id;
                // Continue cascade
            }
            None => {
                // Cannot merge, try borrow
                return borrow_from_sibling(&parent, &candidates, pager)?;
            }
        }
    }
}
```

### Key Decisions

**Merge Direction**: Prefer right into left for leaf merges (maintains scan locality). Alternative: Always left into right (same cost, different scan pattern).

**Merge vs Borrow**: Prefer borrow over merge (borrow moves fewer entries). Merge only when both nodes at minimum occupancy.

**Root Merge Trigger**: Merge root children when root has exactly 1 separator. Alternative: Allow root to have 1 separator (simpler but wastes space).

**Cascade Strategy**: Immediate propagation upward. Alternative: Deferred merges (mark nodes, fix later). Immediate propagation maintains invariants but has O(h * n) worst case.

**Leaf Linked List Update**: Update three nodes (left, right, next). Critical for maintaining scan correctness.

**Parent Pointer Updates**: Update all moved children's parent pointers immediately. Eager updates ensure consistency.

### Implementation Notes

1. **Capacity Check**: Always verify combined entries fit:
   ```rust
   assert!(left_count + right_count <= MAX_CAPACITY);
   ```

2. **Entry Movement**: Use extend for efficient transfer:
   ```rust
   left.entries.extend(right.entries.clone());
   ```

3. **Linked List Update**: Update next leaf's prev pointer:
   ```rust
   if right_next != 0 {
       next_leaf.prev_leaf = left_leaf.page_id;
   }
   ```

4. **Separator Deletion**: Remove separator and child pointer:
   ```rust
   parent.separators.remove(separator_index);
   parent.children.remove(separator_index + 1);
   ```

5. **Parent Separator**: Insert parent separator between child separators:
   ```rust
   left.separators.push(parent_separator);
   left.separators.extend(right.separators.clone());
   ```

6. **Child Pointer Updates**: Update all moved children:
   ```rust
   for child_id in &right.children {
       update_child_parent(pager, *child_id, left_id)?;
   }
   ```

7. **Root Merge**: Decrease tree height after root merge:
   ```rust
   pager.decrement_tree_height()?;
   ```

8. **Validation**: Verify merge invariants:
   ```rust
   assert!(left.num_keys == left_count + right_count);
   assert!(left.children.len() == left.separators.len() + 1);
   ```

### Testing Strategy

**Unit tests needed for**:
- Merge condition detection (various occupancy levels)
- Leaf merge right into left
- Leaf merge left into right
- Internal node merge
- Root merge (tree shrink)
- Merge validation (entry counts, ordering)
- Linked list consistency after merge
- Parent pointer updates after internal merge

**Property tests for**:
- Merge preserves all entries
- Merge maintains key ordering
- Combined entries fit in one node
- Merged node has correct count
- Parent separator deleted correctly
- Child pointers valid after merge
- Leaf linked list consistent
- Tree height decreases on root merge

**Integration scenarios**:
- Delete keys causing merge (trigger rebalancing)
- Merge at various tree levels (leaf, internal, root)
- Cascading merges (multiple levels)
- Merge with concurrent readers (MVCC correctness)
- Merge, crash during merge, recover, verify consistency
- Merge causing tree shrink (height decrease)
- Merge with overflow pages and tombstones

**Fuzzing targets**:
- Merge with various occupancy levels (just at minimum)
- Merge with malformed nodes (corrupted metadata)
- Rapid merges (stress test deallocation)
- Merge during concurrent operations
- Merge with I/O errors injected
- Cascade merge failures

**Performance benchmarks**:
- Leaf merge cost (time per merge)
- Internal merge cost
- Root merge cost (tree shrink overhead)
- Cascade merge cost (multiple levels)
- Merge impact on delete latency
- Comparison with borrow operation cost

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and merge overview
- **06-btree-node.md**: Internal and leaf node structures for merge targets
- **06-btree-header.md**: Node header fields updated during merge
- **06-btree-delete.md**: Delete operation that triggers merges
- **06-btree-borrow.md**: Borrow operation as alternative to merge
- **06-btree-split.md**: Split operation (inverse of merge)
- **06-btree-search.md**: Search algorithm for finding siblings
- **02-pager-*.md**: Pager integration for node I/O and deallocation
- **03-wal-*.md**: WAL integration for crash-safe merges
