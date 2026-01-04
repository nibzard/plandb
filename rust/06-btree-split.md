# B+Tree Node Split Operation

## Purpose

The split operation divides overfull B+Tree nodes into two nodes, maintaining tree balance and accommodating growth. Splits are triggered when insert operations cause nodes to exceed maximum capacity. The split operation is fundamental to B+Tree maintenance, ensuring nodes remain within occupancy bounds and the tree stays balanced. This specification covers split algorithms for both leaf and internal nodes, split point selection strategies, separator key promotion, linked list updates for leaf nodes, parent pointer updates for internal nodes, root splits for tree growth, and comprehensive error handling.

## Types

### SplitResult

**Description**: Result type returned by node split operations containing split metadata

**Fields**:
- **left_node_page_id**: PageId - Page ID of original node (now left sibling after split)
- **right_node_page_id**: PageId - Page ID of newly created right sibling
- **separator_key**: Vec<u8> - Separator key to be promoted to parent
- **split_point**: u16 - Index where split occurred (for validation and debugging)
- **entries_moved**: u16 - Number of entries moved to right node
- **parent_page_id**: PageId - Page ID of parent node that needs update

**Rationale**: Encapsulates all information needed to update parent and maintain tree structure

### SplitPoint

**Description**: Enumeration of strategies for selecting split position within node

**Values**:
- **Half**: Split at midpoint (ceil(num_keys / 2)) - simplest strategy
- **Balanced**: Split to balance total key space (consider key sizes, not just count)
- **LeftHeavy**: Split to leave more entries in left node (60/40 distribution)
- **RightHeavy**: Split to leave more entries in right node (40/60 distribution)

**Rationale**: Different split strategies optimize for different access patterns and workloads

### SplitContext

**Description**: Context structure tracking state during split operation

**Fields**:
- **node_to_split**: PageId - Page ID of overfull node
- **node_type**: NodeType - Type of node being split (leaf or internal)
- **num_keys_before_split**: u16 - Entry count before split (for validation)
- **is_root_split**: bool - True if splitting root node (triggers tree growth)
- **parent_page_id**: PageId - Parent node that needs separator insertion
- **level**: u16 - Tree level of node being split (0 for leaves)

**Rationale**: Captures node state and context for split execution and validation

### SeparationResult

**Description**: Result of separator key extraction for parent promotion

**Fields**:
- **separator**: Vec<u8> - Separator key promoted to parent
- **separator_index**: u16 - Index of separator in original node
- **belongs_to**: NodeSide - Whether separator stays in left or moves to right
- **key_order_preserved**: bool - Verification that split maintains key ordering

**NodeSide**:
- **Left**: Separator remains in left node after split
- **Right**: Separator moves to right node after split
- **Promoted**: Separator promoted to parent (not in either child)

**Rationale**: Separator handling differs between leaf and internal nodes

## Algorithms

### Split Point Selection

**Purpose**: Determine optimal position to divide node entries into two siblings

**Context**: Split point selection is critical for tree balance. Different strategies optimize for different workloads.

**Algorithm - Half Strategy (Default)**:

1. **Input**: Node with num_keys entries
2. **Calculate Midpoint**:
   - split_point = num_keys / 2 (integer division)
   - For even num_keys: split at exactly half (e.g., 10 keys split at 5)
   - For odd num_keys: split at ceil(num_keys / 2) (e.g., 11 keys split at 6)
3. **Validate Split Point**:
   - Verify left_node_count = split_point >= MINIMUM_OCCUPANCY
   - Verify right_node_count = num_keys - split_point >= MINIMUM_OCCUPANCY
   - For internal nodes: verify both nodes have at least MIN_CHILDREN pointers
4. **Return**: split_point

**Time Complexity**: O(1)

**Space Complexity**: O(1)

**Returns**: u16 split point index

**Error Conditions**:
- **InsufficientEntries**: num_keys < 2 * MINIMUM_OCCUPANCY (node too small to split)
- **InvalidSplitPoint**: Calculated split point violates occupancy rules

**Edge Cases**:
- **Minimum occupancy split**: Node has exactly 2 * MINIMUM_OCCUPANCY entries, split results in two nodes each with MINIMUM_OCCUPANCY
- **Maximum occupancy split**: Node is completely full, split creates two nodes with roughly half capacity each
- **Odd number of entries**: Left node gets one more entry than right (or vice versa depending on rounding)

**Algorithm - Balanced Strategy (Key Size Aware)**:

1. **Input**: Node with entries array, each entry with known key_size and value_size
2. **Calculate Total Size**:
   - total_size = sum of all entry sizes (keys + values + overhead)
   - target_left_size = total_size / 2
3. **Scan for Balance Point**:
   - accumulated_size = 0
   - For i from 0 to num_keys - 1:
     - accumulated_size += entry[i].size
     - If accumulated_size >= target_left_size:
       - split_point = i
       - Break loop
4. **Validate Split Point**:
   - Ensure both sides have at least MINIMUM_OCCUPANCY entries
   - If validation fails, fall back to Half strategy
5. **Return**: split_point

**Time Complexity**: O(n) where n is number of entries (scan to calculate sizes)

**Space Complexity**: O(1)

**Returns**: u16 split point index

**Rationale**: Produces more balanced space utilization when keys and values have variable sizes

**Trade-off**: More expensive calculation for better space distribution

**Algorithm - LeftHeavy Strategy**:

1. **Input**: Node with num_keys entries, target_left_ratio (default 0.6)
2. **Calculate Left-Heavy Split Point**:
   - split_point = ceil(num_keys * target_left_ratio)
   - For 10 entries with 0.6 ratio: split_point = 6
3. **Validate Split Point**:
   - Verify right_node_count = num_keys - split_point >= MINIMUM_OCCUPANCY
   - If validation fails, adjust split_point downward until valid
4. **Return**: split_point

**Rationale**: Leaves more entries in left node, beneficial for sequential read workloads that scan left-to-right (left node has more data, reducing traversal to right node)

**Algorithm - RightHeavy Strategy**:

1. **Input**: Node with num_keys entries, target_right_ratio (default 0.6)
2. **Calculate Right-Heavy Split Point**:
   - split_point = ceil(num_keys * (1.0 - target_right_ratio))
   - For 10 entries with 0.6 ratio: split_point = 4
3. **Validate Split Point**:
   - Verify left_node_count = split_point >= MINIMUM_OCCUPANCY
   - If validation fails, adjust split_point upward until valid
4. **Return**: split_point

**Rationale**: Leaves more entries in right node, beneficial for insert-heavy workloads where new keys tend to be higher than existing keys (right node has more capacity for inserts)

### Leaf Node Split

**Purpose**: Divide overfull leaf node into two leaf nodes, maintaining linked list structure

**Context**: Leaf node has exceeded maximum capacity due to insert operation. Split creates new sibling leaf and redistributes entries.

**Algorithm**:

1. **Input**: Overfull leaf node with num_keys entries, split strategy
2. **Select Split Point**:
   - Execute split point selection algorithm (Half strategy by default)
   - split_point = result of selection algorithm
3. **Allocate New Leaf Node**:
   - Allocate new page from Pager for right sibling
   - new_leaf_page_id = allocated page ID
   - Initialize new node as leaf type:
     - Set node_type = Leaf
     - Set is_root = false
     - Set level = 0 (leaf level)
     - Set parent_page_id = same as original leaf
4. **Redistribute Entries**:
   - Move entries [split_point, num_keys) from original leaf to new leaf
   - Original leaf keeps entries [0, split_point)
   - Update original leaf entry_count = split_point
   - Update new leaf entry_count = num_keys - split_point
   - Calculate new free_space for both nodes
   - Update free_space field in both node headers
5. **Extract Separator for Parent**:
   - Separator = first key in new leaf (entries[0].key)
   - This separator divides key space between siblings
   - Store separator for insertion into parent
6. **Update Leaf Linked List Pointers**:
   - Read original leaf's next_leaf pointer (original_next)
   - Set new_leaf.prev_leaf = original_leaf.page_id
   - Set new_leaf.next_leaf = original_next
   - Set original_leaf.next_leaf = new_leaf.page_id
   - If original_next != 0:
     - Read original_next leaf node
     - Update original_next.prev_leaf = new_leaf.page_id
     - Write original_next leaf back to Pager
7. **Update Node Headers**:
   - Set dirty flag on both nodes
   - Increment generation counter on both nodes
   - Recalculate checksum for original leaf (based on new entries)
   - Recalculate checksum for new leaf (based on moved entries)
8. **Validate Consistency**:
   - Verify original_leaf.entry_count + new_leaf.entry_count = num_keys_before_split
   - Verify all keys present (no keys lost during move)
   - Verify key ordering maintained (original keys < separator <= new keys)
   - Verify linked list consistency (prev/next pointers form valid list)
9. **Write Both Nodes**:
   - Write original modified leaf to Pager
   - Write new leaf to Pager
10. **Construct SplitResult**:
    - Return SplitResult with:
      - left_node_page_id = original_leaf.page_id
      - right_node_page_id = new_leaf.page_id
      - separator_key = extracted separator
      - split_point = calculated split point
      - entries_moved = new_leaf.entry_count
      - parent_page_id = original_leaf.parent_page_id

**Time Complexity**:
- Split point selection: O(1) for Half strategy, O(n) for Balanced strategy
- Entry redistribution: O(n) where n is number of entries in leaf
- Linked list updates: O(1)
- Total: O(n)

**Space Complexity**: O(1) (allocates one new node)

**Returns**: SplitResult containing split metadata

**Error Conditions**:
- **AllocationFailed**: Pager cannot allocate new node
- **IOError**: Pager read/write operation failed
- **InvalidSplitPoint**: Calculated split point violates occupancy rules
- **CorruptNode**: Node header validation fails (checksum, magic)
- **BrokenLinkedList**: Next/prev pointer inconsistency detected

**Concurrency**: Exclusive access required (blocks all other operations on this subtree)

**Edge Cases**:
- **Root is leaf**: Special case handled by root split algorithm (creates new root)
- **All entries same key**: Split point still divides entries evenly, separator equals that key
- **Overflow page references**: Some entries have overflow pages, page IDs moved correctly
- **Empty right sibling after split**: Should not occur if split point selection correct
- **Linked list at tree boundary**: Original next_leaf is 0 (no next node), only update new_leaf.next_leaf

### Internal Node Split

**Purpose**: Divide overfull internal node into two internal nodes, promoting separator to parent

**Context**: Internal node has exceeded maximum capacity due to separator insertion from child split. Split propagates upward, potentially triggering recursive splits.

**Algorithm**:

1. **Input**: Overfull internal node with num_keys separators and num_keys + 1 child pointers, split strategy
2. **Select Split Point**:
   - Execute split point selection algorithm (Half strategy by default)
   - split_point = result of selection algorithm
   - For internal nodes, split_point refers to separator index
3. **Allocate New Internal Node**:
   - Allocate new page from Pager for right sibling
   - new_internal_page_id = allocated page ID
   - Initialize new node as internal type:
     - Set node_type = Internal
     - Set is_root = false
     - Set level = same as original node
     - Set parent_page_id = same as original internal node
4. **Extract Separator for Parent**:
   - separator = separators[split_point] (the "middle" separator)
   - This separator will be promoted to parent node
   - Mark separator as promoted (not kept in either child)
5. **Redistribute Separators**:
   - Original node keeps separators [0, split_point)
   - New node gets separators [split_point + 1, num_keys)
   - Note: Separator at split_point is promoted, not moved
   - Update original node entry_count = split_point
   - Update new node entry_count = num_keys - split_point - 1
6. **Redistribute Child Pointers**:
   - Original node keeps child pointers [0, split_point]
   - New node gets child pointers [split_point + 1, num_keys + 1)
   - Child pointers count = separators count + 1 for each node
   - Update child pointer counts in both nodes
7. **Update Parent Pointers for Moved Children**:
   - For each child pointer moved to new node:
     - Read child node from Pager
     - Update child.parent_page_id = new_internal_page_id
     - Write child node back to Pager
   - This is critical for future traversal and split propagation
8. **Calculate Free Space**:
   - Calculate freed space in original node (separators and child pointers removed)
   - Calculate used space in new node (separators and child pointers added)
   - Update free_space field in both node headers
9. **Update Node Headers**:
   - Set dirty flag on both nodes
   - Increment generation counter on both nodes
   - Recalculate checksum for original internal node
   - Recalculate checksum for new internal node
10. **Validate Consistency**:
    - Verify original_node.entry_count + new_node.entry_count + 1 = num_keys_before_split (+1 for promoted separator)
    - Verify child pointer count = entry_count + 1 for both nodes
    - Verify all child pointers non-zero
    - Verify all separators present (no separators lost)
    - Verify parent pointers updated for all moved children
11. **Write Both Nodes**:
    - Write original modified internal node to Pager
    - Write new internal node to Pager
12. **Construct SplitResult**:
    - Return SplitResult with:
      - left_node_page_id = original_internal.page_id
      - right_node_page_id = new_internal.page_id
      - separator_key = promoted separator
      - split_point = calculated split point
      - entries_moved = new_internal.entry_count
      - parent_page_id = original_internal.parent_page_id

**Time Complexity**:
- Split point selection: O(1) for Half strategy, O(n) for Balanced strategy
- Entry redistribution: O(n) where n is number of separators
- Parent pointer updates: O(c) where c is number of children moved
- Total: O(n + c)

**Space Complexity**: O(1) (allocates one new node)

**Returns**: SplitResult containing split metadata

**Error Conditions**:
- **AllocationFailed**: Pager cannot allocate new node
- **IOError**: Pager read/write operation failed
- **InvalidChildPointer**: Child pointer is null or invalid page ID
- **InvalidSplitPoint**: Calculated split point violates occupancy rules
- **CorruptNode**: Node header validation fails
- **ParentUpdateFailed**: Cannot update child parent pointers

**Concurrency**: Exclusive access required (blocks entire tree during recursive splits)

**Edge Cases**:
- **Root is internal**: Special case handled by root split algorithm (creates new root)
- **Minimum separators**: Only 2 separators, split results in nodes with 0 and 1 separators
- **Large fanout**: Internal node with hundreds of children, split moves many parent pointers
- **Deep tree**: Split at high level (e.g., level 5), affects many descendant nodes

### Separator Key Promotion

**Purpose**: Extract and prepare separator key for insertion into parent node

**Context**: After split, separator key must be inserted into parent to maintain search path correctness.

**Algorithm - Leaf Node Separator**:

1. **Input**: Split leaf node with entries array, split_point
2. **Extract Separator**:
   - separator = entries[split_point].key (first key in right sibling)
   - This key divides key space: left sibling keys < separator <= right sibling keys
3. **Validate Separator**:
   - Verify separator is valid key (non-empty, within size limits)
   - Verify separator > all keys in left sibling
   - Verify separator <= all keys in right sibling
4. **Return**: separator

**Time Complexity**: O(1)

**Space Complexity**: O(k) where k is key size (copy separator bytes)

**Returns**: Vec<u8> separator key

**Algorithm - Internal Node Separator**:

1. **Input**: Split internal node with separators array, split_point
2. **Extract Separator**:
   - separator = separators[split_point] (the "middle" separator)
   - This separator is promoted, not kept in either child
3. **Validate Separator**:
   - Verify separator is valid key
   - Verify separator > all separators in left sibling
   - Verify separator < all separators in right sibling
   - Note: Separator promoted to parent, not present in children
4. **Determine Child Pointers**:
   - Left child pointers: [0, split_point]
   - Right child pointers: [split_point + 1, num_keys + 1)
   - Total children = split_point + 1 + (num_keys - split_point) = num_keys + 1 (preserved)
5. **Return**: separator

**Time Complexity**: O(1)

**Space Complexity**: O(k) where k is key size

**Returns**: Vec<u8> separator key

**Separator Characteristics**:
- **Leaf separator**: Minimum key in right sibling, present in right sibling
- **Internal separator**: Promoted separator, not present in either sibling
- **Key ordering**: Left keys < separator <= Right keys (leaf) or Left sep < separator < Right sep (internal)
- **Uniqueness**: Separator uniquely identifies split point in parent

### Linked List Updates (Leaf Nodes Only)

**Purpose**: Maintain doubly-linked list of leaf nodes after split

**Context**: Leaf nodes form linked list for efficient range scans. Split must update list pointers consistently.

**Algorithm**:

1. **Input**: Original leaf, new leaf, split point
2. **Read Current Pointers**:
   - original_next = original_leaf.next_leaf
   - original_prev = original_leaf.prev_leaf (unchanged)
3. **Update New Leaf Pointers**:
   - new_leaf.prev_leaf = original_leaf.page_id
   - new_leaf.next_leaf = original_next
4. **Update Original Leaf Pointer**:
   - original_leaf.next_leaf = new_leaf.page_id
5. **Update Next Leaf's Previous Pointer**:
   - If original_next != 0:
     - Read next_leaf node from Pager
     - next_leaf.prev_leaf = new_leaf.page_id
     - Write next_leaf back to Pager
   - Else (original_next == 0):
     - New leaf is now last leaf in list (no next leaf to update)
6. **Verify Linked List Consistency**:
   - Verify new_leaf.prev_leaf points to original_leaf
   - Verify original_leaf.next_leaf points to new_leaf
   - If new_leaf.next_leaf != 0, verify that leaf's prev_leaf points to new_leaf
   - Verify no circular references (A.next == B && B.next == A)
7. **Return**: Updated nodes ready for write

**Time Complexity**: O(1) (constant time pointer updates)

**Space Complexity**: O(1)

**Returns**: Updated leaf nodes with consistent pointers

**Error Conditions**:
- **CorruptedList**: Detected circular reference or invalid pointer
- **IOError**: Cannot read/write next leaf node
- **InvalidPageId**: next_leaf or prev_leaf is invalid page ID

**Concurrency**: Exclusive access required (blocks range scans that traverse linked list)

**Edge Cases**:
- **Split at list boundary**: Original leaf has next_leaf == 0 (is last leaf), new leaf becomes last leaf
- **Split at list beginning**: Original leaf has prev_leaf == 0 (is first leaf), new leaf inserted after it
- **Empty original next**: No next leaf to update, only update original and new leaves
- **Concurrent range scan**: Range scan in progress may see inconsistent list state if not using MVCC snapshots

**Linked List Invariants After Split**:
1. All leaves reachable via next pointers from first leaf
2. All leaves reachable via prev pointers from last leaf
3. For any adjacent leaves A and B: A.next_leaf == B.page_id && B.prev_leaf == A.page_id
4. First leaf has prev_leaf == 0
5. Last leaf has next_leaf == 0
6. No circular references

### Parent Pointer Updates (Internal Nodes Only)

**Purpose**: Update child nodes' parent_page_id fields after internal node split

**Context**: Child nodes need correct parent pointers for traversal and future split propagation.

**Algorithm**:

1. **Input**: New internal node with child pointers array
2. **Iterate Over Child Pointers**:
   - For each child_page_id in new_internal.child_pointers:
     - Execute parent pointer update subroutine
3. **Parent Pointer Update Subroutine**:
   - Read child node from Pager (child_page_id)
   - Validate child node (checksum, magic)
   - Verify child.parent_page_id == original_internal.page_id (precondition)
   - Update child.parent_page_id = new_internal.page_id
   - Set child.dirty flag
   - Increment child.generation counter
   - Recalculate child.checksum
   - Write child back to Pager
4. **Verify All Updates**:
   - Count successful parent pointer updates
   - Verify count == new_internal.entry_count + 1 (all children updated)
5. **Handle Failures**:
   - If any child update fails, attempt rollback:
     - Update successfully updated children back to original parent
     - Return error to caller
   - Rollback best-effort (may fail if crash occurs)
6. **Return**: Success or error

**Time Complexity**: O(c) where c is number of children moved to new node

**Space Complexity**: O(1)

**Returns**: Success (updated all children) or error

**Error Conditions**:
- **IOError**: Cannot read or write child node
- **CorruptChild**: Child node validation fails
- **InvalidParentPointer**: Child's current parent_page_id doesn't match expected
- **PartialUpdateFailure**: Some children updated, others failed (rollback attempted)

**Concurrency**: Exclusive access required (blocks all operations on affected subtrees)

**Edge Cases**:
- **Leaf children**: Moved children are leaf nodes (split at level 1)
- **Internal children**: Moved children are internal nodes (split at higher level)
- **Deep update**: Child nodes have their own children, but parent update doesn't recurse to grandchildren
- **Large fanout**: Moving hundreds of children requires hundreds of parent pointer updates

**Why Parent Pointers Matter**:
- **Traversal**: Search operations use parent pointers for split propagation
- **Split propagation**: When child splits, parent pointer identifies which node to update
- **Tree validation**: Parent pointers enable structural consistency checks
- **Recovery**: Recovery process can rebuild tree structure using parent pointers

### Root Split (Tree Growth)

**Purpose**: Split root node and increase tree height by one level

**Context**: Root node (leaf or internal) is full and needs to split. Root split is special because it creates a new root rather than updating an existing parent.

**Algorithm**:

1. **Input**: Full root node (leaf or internal)
2. **Check Root Split Condition**:
   - Verify root.is_root == true
   - Verify root.parent_page_id == 0 (root has no parent)
3. **Allocate New Root**:
   - new_root_page_id = allocate page from Pager
   - Initialize new_root as internal node:
     - node_type = Internal
     - is_root = true
     - level = root.level + 1 (increase tree height)
     - parent_page_id = 0 (root has no parent)
     - entry_count = 1 (will contain one separator)
4. **Allocate New Sibling**:
   - new_sibling_page_id = allocate page from Pager
   - Initialize new_sibling:
     - node_type = same as original root (leaf or internal)
     - is_root = false
     - level = same as original root
     - parent_page_id = new_root_page_id (will point to new root)
5. **Split Original Root**:
   - If original root is leaf:
     - Execute leaf node split algorithm
     - Original root becomes left sibling
     - New sibling becomes right sibling
     - Extract separator from split
   - If original root is internal:
     - Execute internal node split algorithm
     - Original root becomes left sibling
     - New sibling becomes right sibling
     - Extract separator from split
6. **Populate New Root**:
   - Insert separator into new_root.separators[0]
   - Set new_root.child_pointers[0] = original_root.page_id (left sibling)
   - Set new_root.child_pointers[1] = new_sibling.page_id (right sibling)
   - Set new_root.entry_count = 1
   - Calculate and set new_root.free_space
7. **Update Child Root Flags**:
   - Set original_root.is_root = false (no longer root)
   - new_sibling.is_root = false (was never root)
   - new_root.is_root = true (new root)
8. **Update Child Parent Pointers**:
   - Update original_root.parent_page_id = new_root_page_id
   - Update new_sibling.parent_page_id = new_root_page_id
9. **Update Node Headers**:
   - Set dirty flag on all three nodes
   - Increment generation counter on all three nodes
   - Recalculate checksum for all three nodes
10. **Write All Nodes**:
    - Write original modified root (now left sibling)
    - Write new sibling node
    - Write new root node
11. **Update Database Metadata**:
    - Update root_page_id in database metadata = new_root_page_id
    - Increment tree_height counter = old_tree_height + 1
    - Flush metadata to disk
    - Sync metadata file to ensure persistence
12. **Validate Tree Growth**:
    - Verify new_root.page_id matches metadata root_page_id
    - Verify tree_height increased by exactly 1
    - Verify new_root has exactly 1 separator and 2 children
    - Verify both children point to new_root as parent
    - Verify all keys reachable from new root

**Time Complexity**:
- Root split: O(n) where n is number of entries in root
- New root initialization: O(1)
- Metadata update: O(1)
- Total: O(n)

**Space Complexity**: O(1) (allocates two new nodes: new root and sibling)

**Returns**: SplitResult with is_root_split flag set

**Error Conditions**:
- **AllocationFailed**: Pager cannot allocate new nodes (need two allocations)
- **IOError**: Pager write operation or metadata update failed
- **MetadataUpdateFailed**: Cannot persist new root_page_id
- **RootCorruption**: Root structure invalid before or after split
- **TreeHeightOverflow**: Tree height exceeds maximum (theoretical limit around 55 for 16KB pages)

**Concurrency**: Exclusive access required (blocks entire tree)

**Critical**: Root split must be atomic from external perspective. If crash occurs mid-split, recovery must either:
- Roll back to pre-split state (old root still root)
- Complete split (new root is root, tree height increased)
- No inconsistent state (two roots, height mismatch, etc.)

**Edge Cases**:
- **First split**: Tree grows from height 0 (single leaf) to height 1 (root + 2 leaves)
- **Large tree height**: Root split at height 10 creates height 11 (still efficient)
- **Empty tree**: No root exists, create initial leaf root (not a split)
- **Single node tree**: Root is leaf with no parent, split creates first internal root

**Tree Growth Example**:
```
Before split (height 0):
[Root Leaf: keys 1-10]

After split (height 1):
      [Root Internal: sep=5]
      /                    \
[Left Leaf: 1-4]      [Right Leaf: 5-10]
```

## Error Handling

### Allocation Errors

**AllocationFailed**:
- **Detection**: Pager.allocate_page() returns error
- **Handling**:
  - Abort split operation immediately
  - Do not modify original node (still overfull, but consistent)
  - Return error to caller
  - Caller must retry or abort transaction
- **Recovery**:
  - No rollback needed (no modifications made)
  - Original node remains overfull but valid
  - Future insert may retry split
- **User Action**: Free disk space or increase database size limit

**Partial Allocation**:
- **Detection**: First allocation succeeds, second allocation fails (root split)
- **Handling**:
  - Deallocate first allocated node
  - Abort split operation
  - Return error to caller
- **Recovery**: Free allocated page(s), return to pre-split state

### I/O Errors

**ReadFailure**:
- **Detection**: Pager.read_page() fails during split (reading sibling, child, next node)
- **Handling**:
  - Abort split operation
  - If modifications made to original node, attempt rollback
  - Return error to caller
- **Recovery**:
  - If original node modified: Restore from backup copy if available
  - If no backup: Mark node as corrupted, require recovery
- **User Action**: Check disk health, retry operation, run recovery

**WriteFailure**:
- **Detection**: Pager.write_page() fails during split (writing split nodes, updated children)
- **Handling**:
  - Abort split operation
  - Do not deallocate allocated nodes (may contain partial data)
  - Mark nodes as "orphaned" (allocated but not referenced)
  - Return error to caller
- **Recovery**:
  - Orphaned nodes reclaimed during next free list scan
  - Original node unmodified if write failed before modification
  - Original node may be corrupted if write failed during modification
- **User Action**: Check disk health, run database recovery

**MetadataWriteFailure** (Root split only):
- **Detection**: Cannot update database metadata with new root_page_id
- **Handling**:
  - CRITICAL: Tree now has two roots (old and new)
  - Mark database as inconsistent
  - Initiate emergency recovery
  - Return fatal error to caller
- **Recovery**:
  - Recovery process must detect two roots
  - Use WAL to determine correct root
  - Delete incorrect root
  - Update metadata correctly
- **User Action**: Restart database, recovery runs automatically

### Structural Errors

**InvalidSplitPoint**:
- **Detection**: Calculated split_point violates occupancy rules
- **Handling**:
  - Abort split operation
  - Try alternative split strategy (e.g., Half -> Balanced)
  - If all strategies fail, return error
- **Recovery**: No modifications made, original node valid
- **User Action**: Report bug (should not occur with correct implementation)

**ParentNotFound**:
- **Detection**: During split propagation, parent_page_id is invalid or parent doesn't exist
- **Handling**:
  - Abort split operation
  - Mark tree as corrupted
  - Return error to caller
- **Recovery**: Rebuild tree structure from WAL or checkpoint
- **User Action**: Run database verification and repair

**BrokenLinkedList** (Leaf split):
- **Detection**: Next/prev pointer inconsistency detected (circular reference, invalid page ID)
- **Handling**:
  - Abort split operation
  - Do not update linked list pointers
  - Return error to caller
- **Recovery**:
  - Original leaf and new leaf valid but not linked
  - Recovery process rebuilds linked list by scanning all leaves
- **User Action**: Run database repair

**CorruptChild** (Parent pointer update):
- **Detection**: Child node validation fails (checksum, magic)
- **Handling**:
  - Abort parent pointer update
  - If some children already updated, attempt rollback
  - Return error to caller
- **Recovery**:
  - Rollback updated children's parent pointers
  - If rollback fails, tree has inconsistent parent pointers
  - Full recovery from WAL required
- **User Action**: Run database recovery

### Overflow Page Errors

**OverflowAllocationFailed**:
- **Detection**: Cannot allocate overflow pages for large value during split
- **Handling**:
  - Abort split operation
  - Deallocate any overflow pages already allocated
  - Return error to caller
- **Recovery**: No modifications to tree structure

**OverflowChainBroken**:
- **Detection**: Entry references overflow page ID that doesn't exist or is corrupted
- **Handling**:
  - Abort split operation
  - Mark entry as corrupted
  - Return error to caller
- **Recovery**: Delete corrupted entry or recover overflow chain from WAL

### Concurrency Errors

**ConcurrentModificationDetected**:
- **Detection**: Node modified by another operation during split (generation counter mismatch)
- **Handling**:
  - Abort split operation
  - Retry split with fresh node read
  - If retry fails multiple times, return error
- **Recovery**: No data loss (retry with updated node)

**LockTimeout** (Future multi-writer support):
- **Detection**: Cannot acquire exclusive lock on node or subtree
- **Handling**:
  - Wait for lock with timeout
  - If timeout expires, return error to caller
  - Caller may retry or abort transaction
- **Recovery**: No data loss (operation not performed)

### Recovery and Rollback

**Split Operation Rollback Strategy**:

1. **Before any modifications**:
   - Read original node
   - Make backup copy in memory
   - No rollback needed if allocation fails

2. **After allocation, before modification**:
   - If split fails after allocation:
     - Deallocate allocated nodes
     - No rollback of original node needed

3. **During node modification**:
   - If failure occurs during entry redistribution:
     - Restore original node from backup copy
     - Deallocate allocated nodes
     - Write restored original node

4. **After node write, before parent update**:
   - If parent update fails:
     - Tree has split child but parent not updated
     - Mark as inconsistent state
     - Recovery: Delete orphaned child or complete parent update

5. **During parent pointer updates**:
   - If partial failure (some children updated, others not):
     - Attempt rollback of updated children
     - If rollback succeeds: Clean state
     - If rollback fails: Inconsistent state, require recovery

6. **Root split metadata update failure**:
   - CRITICAL: Tree has two roots
   - Recovery must use WAL to determine correct root
   - Delete incorrect root, update metadata

**Recovery Process for Failed Splits**:

1. **Detect inconsistent state**:
   - Scan tree for nodes with parent_page_id != actual parent
   - Scan leaf linked list for inconsistencies
   - Check for orphaned nodes (allocated but not referenced)

2. **Rebuild from WAL**:
   - Replay WAL entries to reconstruct correct tree state
   - WAL entries show intended tree structure
   - Apply all committed transactions

3. **Delete orphaned nodes**:
   - Nodes allocated during failed split but not referenced
   - Add to free list for reuse

4. **Verify tree structure**:
   - Check all parent pointers
   - Verify leaf linked list
   - Validate all node checksums
   - Ensure exactly one root

## Invariants

### Split Invariants

1. **Occupancy Preserved**: After split, both nodes have at least MINIMUM_OCCUPANCY entries
2. **Total Keys Preserved**: left.entry_count + right.entry_count = original.entry_count (before split)
3. **Key Ordering**: All keys in left node < separator <= All keys in right node
4. **No Key Loss**: Every key from original node present in left or right node
5. **No Key Duplication**: No key appears in both left and right nodes
6. **Separator Validity**: Separator key divides key space correctly

### Leaf Split Invariants

1. **Linked List Consistency**: Next/prev pointers form valid doubly-linked list
2. **List Connectivity**: All leaves remain reachable from first leaf via next pointers
3. **Boundary Preservation**: First leaf and last leaf unchanged (unless splitting boundary leaf)
4. **Overflow References**: Overflow page IDs moved correctly to new node
5. **Version Chains**: MVCC version chains preserved during entry move

### Internal Node Split Invariants

1. **Separator Promotion**: Separator at split point promoted to parent, not in children
2. **Child Distribution**: All children distributed between split nodes (no lost children)
3. **Child Pointer Count**: child_ptr_count = entry_count + 1 for both nodes
4. **Parent Pointer Correctness**: All children have correct parent_page_id
5. **Level Preservation**: Both new nodes at same level as original node

### Root Split Invariants

1. **Single Root**: Exactly one root node exists after split
2. **Height Increment**: Tree height increases by exactly 1
3. **New Root Validity**: New root is internal node with exactly 1 separator and 2 children
4. **Child Updates**: Both children have is_root = false and parent_page_id = new_root
5. **Metadata Consistency**: Database metadata root_page_id matches actual root
6. **Old Root Demoted**: Original root no longer marked as root

### Parent Pointer Invariants

1. **Child-Parent Consistency**: For every child, child.parent_page_id = actual parent node
2. **Root Has No Parent**: Root node parent_page_id = 0
3. **Non-Root Has Parent**: All non-root nodes have parent_page_id != 0
4. **Parent Pointer Reachability**: Following parent pointers from any node eventually reaches root
5. **No Cycles**: Parent pointer graph is acyclic (no node is its own ancestor)

### Linked List Invariants (Leaves)

1. **Prev Consistency**: For adjacent leaves A and B: A.next_leaf == B.page_id implies B.prev_leaf == A.page_id
2. **First Leaf**: First leaf has prev_leaf == 0
3. **Last Leaf**: Last leaf has next_leaf == 0
4. **No Circularity**: No sequence of next pointers leads back to starting leaf
5. **Reachability**: All leaves reachable from first leaf via next pointers

## Rust Implementation Guidance

### Module Structure

The split functionality should be organized as:
- `northstar_core::tree::split::select_split_point` - Split point selection strategies
- `northstar_core::tree::split::split_leaf` - Leaf node split algorithm
- `northstar_core::tree::split::split_internal` - Internal node split algorithm
- `northstar_core::tree::split::extract_separator` - Separator extraction and validation
- `northstar_core::tree::split::update_leaf_linked_list` - Linked list pointer updates
- `northstar_core::tree::split::update_child_parent_pointers` - Parent pointer updates
- `northstar_core::tree::split::split_root` - Root split and tree growth
- `northstar_core::tree::split::rollback_split` - Split operation rollback

### Type Definitions

**SplitResult**: Implement as struct with fields:
```rust
pub struct SplitResult {
    pub left_node_page_id: PageId,
    pub right_node_page_id: PageId,
    pub separator_key: Vec<u8>,
    pub split_point: u16,
    pub entries_moved: u16,
    pub parent_page_id: PageId,
}
```

**SplitPoint**: Implement as enum:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitStrategy {
    Half,
    Balanced,
    LeftHeavy { target_left_ratio: f32 }, // default 0.6
    RightHeavy { target_right_ratio: f32 }, // default 0.6
}
```

**SplitContext**: Implement as struct:
```rust
pub struct SplitContext {
    pub node_to_split: PageId,
    pub node_type: NodeType,
    pub num_keys_before_split: u16,
    pub is_root_split: bool,
    pub parent_page_id: PageId,
    pub level: u16,
}
```

**SeparationResult**: Implement as struct with NodeSide enum:
```rust
pub struct SeparationResult {
    pub separator: Vec<u8>,
    pub separator_index: u16,
    pub belongs_to: NodeSide,
    pub key_order_preserved: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeSide {
    Left,
    Right,
    Promoted,
}
```

### Split Point Selection Implementation

Implement half split strategy (default):
```rust
pub fn select_split_point_half(
    num_keys: u16,
    min_occupancy: u16,
) -> Result<u16, SplitError> {
    if num_keys < 2 * min_occupancy {
        return Err(SplitError::InsufficientEntries);
    }

    let split_point = (num_keys + 1) / 2; // Ceiling division

    // Validate both sides have minimum occupancy
    let left_count = split_point;
    let right_count = num_keys - split_point;

    if left_count < min_occupancy || right_count < min_occupancy {
        return Err(SplitError::InvalidSplitPoint);
    }

    Ok(split_point)
}
```

Implement balanced strategy (key size aware):
```rust
pub fn select_split_point_balanced(
    entries: &[Entry],
    min_occupancy: u16,
) -> Result<u16, SplitError> {
    let total_size: u32 = entries.iter()
        .map(|e| e.key.len() + e.value.len() + OVERHEAD)
        .sum();

    let target_left_size = total_size / 2;
    let mut accumulated_size = 0;

    for (i, entry) in entries.iter().enumerate() {
        accumulated_size += (entry.key.len() + entry.value.len() + OVERHEAD) as u32;

        if accumulated_size >= target_left_size {
            let split_point = i as u16;

            // Validate minimum occupancy
            if split_point >= min_occupancy &&
               (entries.len() as u16 - split_point) >= min_occupancy {
                return Ok(split_point);
            }
        }
    }

    // Fall back to half strategy if balanced split violates occupancy
    select_split_point_half(entries.len() as u16, min_occupancy)
}
```

### Leaf Node Split Implementation

Split leaf node:
```rust
pub fn split_leaf(
    leaf: &mut LeafNode,
    pager: &mut Pager,
    strategy: SplitStrategy,
) -> Result<SplitResult, SplitError> {
    let num_keys = leaf.header.num_keys;
    let min_occupancy = calculate_min_occupancy(leaf.header.page_size);

    // Select split point
    let split_point = match strategy {
        SplitStrategy::Half => select_split_point_half(num_keys, min_occupancy)?,
        SplitStrategy::Balanced => select_split_point_balanced(&leaf.entries, min_occupancy)?,
        SplitStrategy::LeftHeavy { target_left_ratio } => {
            select_split_point_left_heavy(num_keys, min_occupancy, target_left_ratio)?
        }
        SplitStrategy::RightHeavy { target_right_ratio } => {
            select_split_point_right_heavy(num_keys, min_occupancy, target_right_ratio)?
        }
    };

    // Allocate new leaf node
    let new_leaf_page_id = pager.allocate_page()?;
    let mut new_leaf = LeafNode::new(new_leaf_page_id);
    new_leaf.header.parent_page_id = leaf.header.parent_page_id;
    new_leaf.header.level = 0; // Leaf level

    // Redistribute entries
    let entries_to_move = leaf.entries.split_off(split_point as usize);
    let entries_moved = entries_to_move.len() as u16;
    new_leaf.entries.extend(entries_to_move);

    // Update entry counts
    leaf.header.num_keys = split_point;
    new_leaf.header.num_keys = entries_moved;

    // Calculate and set free space
    leaf.header.free_space = calculate_free_space(&leaf);
    new_leaf.header.free_space = calculate_free_space(&new_leaf);

    // Extract separator for parent
    let separator_key = new_leaf.entries[0].key.clone();

    // Update linked list pointers
    update_leaf_linked_list(leaf, &mut new_leaf, pager)?;

    // Update node headers
    leaf.header.set_flag(NodeFlags::DIRTY);
    new_leaf.header.set_flag(NodeFlags::DIRTY);
    leaf.header.generation += 1;
    new_leaf.header.generation += 1;
    leaf.header.checksum = calculate_checksum(leaf);
    new_leaf.header.checksum = calculate_checksum(&new_leaf);

    // Write both nodes
    pager.write_page(leaf.header.node_id, leaf)?;
    pager.write_page(new_leaf_page_id, &new_leaf)?;

    Ok(SplitResult {
        left_node_page_id: leaf.header.node_id,
        right_node_page_id: new_leaf_page_id,
        separator_key,
        split_point,
        entries_moved,
        parent_page_id: leaf.header.parent_page_id,
    })
}
```

### Internal Node Split Implementation

Split internal node:
```rust
pub fn split_internal(
    internal: &mut InternalNode,
    pager: &mut Pager,
    strategy: SplitStrategy,
) -> Result<SplitResult, SplitError> {
    let num_keys = internal.header.num_keys;
    let min_occupancy = calculate_min_occupancy(internal.header.page_size);

    // Select split point
    let split_point = match strategy {
        SplitStrategy::Half => select_split_point_half(num_keys, min_occupancy)?,
        // ... other strategies
    };

    // Allocate new internal node
    let new_internal_page_id = pager.allocate_page()?;
    let mut new_internal = InternalNode::new(new_internal_page_id);
    new_internal.header.parent_page_id = internal.header.parent_page_id;
    new_internal.header.level = internal.header.level;

    // Extract separator for parent (promoted, not kept in children)
    let separator_key = internal.separators[split_point as usize].clone();

    // Redistribute separators (exclude promoted separator)
    let separators_to_move = internal.separators.split_off((split_point + 1) as usize);
    new_internal.separators.extend(separators_to_move);

    // Redistribute child pointers
    let children_to_move = internal.children.split_off((split_point + 1) as usize);
    new_internal.children.extend(children_to_move);

    // Update entry counts
    internal.header.num_keys = split_point;
    new_internal.header.num_keys = num_keys - split_point - 1; // -1 for promoted separator

    // Update parent pointers for moved children
    for child_page_id in &new_internal.children {
        update_child_parent_pointer(pager, *child_page_id, new_internal_page_id)?;
    }

    // Calculate and set free space
    internal.header.free_space = calculate_free_space(internal);
    new_internal.header.free_space = calculate_free_space(&new_internal);

    // Update node headers
    internal.header.set_flag(NodeFlags::DIRTY);
    new_internal.header.set_flag(NodeFlags::DIRTY);
    internal.header.generation += 1;
    new_internal.header.generation += 1;
    internal.header.checksum = calculate_checksum(internal);
    new_internal.header.checksum = calculate_checksum(&new_internal);

    // Write both nodes
    pager.write_page(internal.header.node_id, internal)?;
    pager.write_page(new_internal_page_id, &new_internal)?;

    Ok(SplitResult {
        left_node_page_id: internal.header.node_id,
        right_node_page_id: new_internal_page_id,
        separator_key,
        split_point,
        entries_moved: new_internal.header.num_keys,
        parent_page_id: internal.header.parent_page_id,
    })
}
```

### Linked List Update Implementation

Update leaf linked list pointers:
```rust
pub fn update_leaf_linked_list(
    original_leaf: &mut LeafNode,
    new_leaf: &mut LeafNode,
    pager: &mut Pager,
) -> Result<(), SplitError> {
    let original_next = original_leaf.header.next_leaf;

    // Update new leaf pointers
    new_leaf.header.prev_leaf = original_leaf.header.node_id;
    new_leaf.header.next_leaf = original_next;

    // Update original leaf pointer
    original_leaf.header.next_leaf = new_leaf.header.node_id;

    // Update next leaf's previous pointer (if exists)
    if original_next != 0 {
        let mut next_leaf = pager.read_page::<LeafNode>(original_next)?;
        next_leaf.header.prev_leaf = new_leaf.header.node_id;
        next_leaf.header.set_flag(NodeFlags::DIRTY);
        next_leaf.header.generation += 1;
        next_leaf.header.checksum = calculate_checksum(&next_leaf);
        pager.write_page(original_next, &next_leaf)?;
    }

    Ok(())
}
```

### Parent Pointer Update Implementation

Update child parent pointers:
```rust
pub fn update_child_parent_pointer(
    pager: &mut Pager,
    child_page_id: PageId,
    new_parent_page_id: PageId,
) -> Result<(), SplitError> {
    let mut child = pager.read_page(child_page_id)?;

    // Verify current parent
    if child.header.parent_page_id != new_parent_page_id {
        // This is expected (child's parent is changing)
    }

    // Update parent pointer
    child.header.parent_page_id = new_parent_page_id;
    child.header.set_flag(NodeFlags::DIRTY);
    child.header.generation += 1;
    child.header.checksum = calculate_checksum(&child);

    pager.write_page(child_page_id, &child)?;

    Ok(())
}

pub fn update_all_child_parent_pointers(
    pager: &mut Pager,
    children: &[PageId],
    new_parent_page_id: PageId,
) -> Result<(), SplitError> {
    let mut updated_children = Vec::new();

    for &child_page_id in children {
        match update_child_parent_pointer(pager, child_page_id, new_parent_page_id) {
            Ok(()) => updated_children.push(child_page_id),
            Err(e) => {
                // Rollback: restore parent pointers for already updated children
                for &updated_child_id in &updated_children {
                    // Attempt rollback (best-effort)
                    let _ = rollback_parent_pointer(pager, updated_child_id);
                }
                return Err(e);
            }
        }
    }

    Ok(())
}
```

### Root Split Implementation

Split root and grow tree:
```rust
pub fn split_root(
    root: &mut Node,
    pager: &mut Pager,
    strategy: SplitStrategy,
) -> Result<SplitResult, SplitError> {
    // Verify root split conditions
    if !root.header.is_root {
        return Err(SplitError::NotRoot);
    }
    if root.header.parent_page_id != 0 {
        return Err(SplitError::RootHasParent);
    }

    // Allocate new root and sibling
    let new_root_page_id = pager.allocate_page()?;
    let new_sibling_page_id = pager.allocate_page()?;

    let mut new_root = InternalNode::new(new_root_page_id);
    new_root.header.is_root = true;
    new_root.header.level = root.header.level + 1;
    new_root.header.parent_page_id = 0;

    // Split original root (becomes left sibling)
    let split_result = match root {
        Node::Leaf(leaf) => split_leaf(leaf, pager, strategy)?,
        Node::Internal(internal) => split_internal(internal, pager, strategy)?,
    };

    // Initialize new sibling
    let mut new_sibling = match root {
        Node::Leaf(_) => Node::Leaf(LeafNode::new(new_sibling_page_id)),
        Node::Internal(_) => Node::Internal(InternalNode::new(new_sibling_page_id)),
    };

    // Populate new root with separator and child pointers
    new_root.separators.push(split_result.separator_key.clone());
    new_root.children.push(split_result.left_node_page_id);
    new_root.children.push(split_result.right_node_page_id);
    new_root.header.num_keys = 1;
    new_root.header.free_space = calculate_free_space(&new_root);

    // Update child root flags and parent pointers
    update_node_root_flag(pager, split_result.left_node_page_id, false)?;
    update_node_root_flag(pager, split_result.right_node_page_id, false)?;
    update_child_parent_pointer(pager, split_result.left_node_page_id, new_root_page_id)?;
    update_child_parent_pointer(pager, split_result.right_node_page_id, new_root_page_id)?;

    // Update original root
    root.header.is_root = false;
    root.header.parent_page_id = new_root_page_id;

    // Update new root metadata
    new_root.header.set_flag(NodeFlags::DIRTY);
    new_root.header.generation += 1;
    new_root.header.checksum = calculate_checksum(&new_root);

    // Write all nodes
    pager.write_page(new_root_page_id, &new_root)?;
    pager.write_page(split_result.left_node_page_id, root)?;
    pager.write_page(split_result.right_node_page_id, &new_sibling)?;

    // Update database metadata
    pager.update_root_page_id(new_root_page_id)?;
    pager.increment_tree_height()?;

    Ok(split_result)
}
```

### Key Decisions

**Split Strategy Default**: Use Half strategy (ceil(num_keys / 2)) for simplicity and reasonable balance. Alternative: Balanced strategy for variable-size entries.

**Leaf Separator Extraction**: Extract first key from right sibling as separator. This key remains in right sibling. Alternative: Use last key from left sibling (not recommended, complicates deletion).

**Internal Separator Promotion**: Promote separator at split_point, not keep in either child. This maintains B+Tree property that internal node separators are copies of leaf keys.

**Eager Parent Pointer Updates**: Update all child parent pointers immediately during split. Alternative: Lazy updates (mark as dirty, update during traversal). Eager is simpler and ensures consistency.

**Root Split Atomicity**: Write both children and new root before updating metadata. If crash occurs, recovery uses WAL to determine correct root. Alternative: Write-ahead log entry for root split, replay during recovery.

**Linked List Update Order**: Update new leaf, then original leaf, then next leaf. This order ensures no broken references if crash occurs. Alternative: Update next leaf first (risk of broken reference if crash before new/original update).

**Checksum Calculation**: Recalculate checksum after all modifications, before write. Alternative: Defer checksum until flush (risky if crash occurs).

**Rollback Strategy**: For parent pointer updates, track successfully updated children and rollback on failure. Alternative: Leave partially updated state, require full recovery. Rollback is cleaner but more complex.

### Implementation Notes

1. **Split Point Validation**: Always validate split point results in valid nodes:
   ```rust
   assert!(left_count >= MIN_OCCUPANCY);
   assert!(right_count >= MIN_OCCUPANCY);
   ```

2. **Entry Movement**: Use Vec::split_off for efficient entry redistribution:
   ```rust
   let entries_to_move = entries.split_off(split_point as usize);
   new_entries.extend(entries_to_move);
   ```

3. **Separator Extraction**: For leaf nodes, separator is first key in right node:
   ```rust
   let separator = new_leaf.entries[0].key.clone();
   ```

4. **Internal Separator**: For internal nodes, separator is promoted, not in children:
   ```rust
   let separator = separators[split_point].clone();
   // Don't include separator in either child
   ```

5. **Child Pointer Updates**: Update parent pointers for all moved children:
   ```rust
   for child_id in &new_internal.children {
       update_child_parent_pointer(pager, *child_id, new_internal_page_id)?;
   }
   ```

6. **Linked List Updates**: Update three nodes (original, new, next):
   ```rust
   new_leaf.prev_leaf = original_leaf.page_id;
   original_leaf.next_leaf = new_leaf.page_id;
   if next_leaf != 0 {
       next_leaf.prev_leaf = new_leaf.page_id;
   }
   ```

7. **Root Split Metadata**: Update metadata atomically after node writes:
   ```rust
   pager.write_page(new_root_page_id, &new_root)?;
   pager.update_root_page_id(new_root_page_id)?;
   pager.sync_metadata()?;
   ```

8. **Error Handling**: Use question mark operator for clean error propagation:
   ```rust
   let split_point = select_split_point_half(num_keys, min_occupancy)?;
   let new_page_id = pager.allocate_page()?;
   ```

9. **Validation**: Assert invariants after split:
   ```rust
   assert!(left.entry_count + right.entry_count == original.entry_count);
   assert!(left.keys.last() < separator);
   assert!(separator <= right.keys.first());
   ```

10. **Concurrency**: Ensure exclusive access during split:
    ```rust
    let _lock = pager.acquire_exclusive_lock(node_page_id)?;
    ```

### Testing Strategy

**Unit tests needed for**:
- Split point selection (half, balanced, left-heavy, right-heavy)
- Split point validation (minimum occupancy)
- Leaf node split at various occupancy levels
- Leaf node split with overflow page references
- Internal node split at various occupancy levels
- Internal node split with many children
- Separator extraction correctness (leaf and internal)
- Leaf linked list pointer updates
- Parent pointer updates for moved children
- Root split (leaf to height-1 tree)
- Root split (internal to height+1 tree)
- Split validation invariants

**Property tests for**:
- Split maintains key ordering
- Split preserves total entry count
- Split maintains occupancy rules (both nodes >= MIN_OCCUPANCY)
- Separator correctly divides key space
- Parent pointers form valid tree (no cycles, all paths lead to root)
- Leaf linked list is consistent after split
- Child pointer count = entry count + 1 (internal nodes)
- Root split increases tree height by exactly 1
- After split, tree is valid (verify_tree function passes)

**Integration scenarios**:
- Insert 1K keys, verify splits occur and tree valid
- Insert 1M keys, verify tree height reasonable (~3-4 for 16KB pages)
- Insert causing cascading splits (leaf → internal → root)
- Split, crash during split, recover, verify tree valid
- Split with concurrent readers (MVCC correctness)
- Split at tree boundaries (first leaf, last leaf)
- Split with large values and overflow pages

**Fuzzing targets**:
- Split with various occupancy levels (just full, very full)
- Split with malformed keys (non-UTF8, random bytes)
- Rapid splits (stress test allocation and I/O)
- Split during concurrent operations (race conditions)
- Split with I/O errors injected (recovery testing)
- Split with invalid split points (validation testing)

**Performance benchmarks**:
- Leaf split cost (time per split)
- Internal split cost (time per split)
- Root split cost (tree growth overhead)
- Split point selection comparison (half vs balanced)
- Parent pointer update cost (O(c) for c children)
- Linked list update cost
- Cascading split cost (multiple levels)
- Split impact on insert latency

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and split overview
- **06-btree-node.md**: Internal and leaf node structures for split targets
- **06-btree-header.md**: Node header fields updated during split
- **06-btree-search.md**: Search algorithm for finding parent nodes
- **06-btree-insert.md**: Insert operation that triggers splits
- **06-btree-key.md**: Key encoding and comparison for separator ordering
- **06-btree-value.md**: Value storage and overflow page handling
- **02-pager-*.md**: Pager integration for node allocation and I/O
- **03-wal-*.md**: WAL integration for crash-safe splits
- **04-txn-*.md**: Transaction system integration for LSN allocation
