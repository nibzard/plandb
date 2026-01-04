# B+Tree Node Borrow Operation

## Purpose

The borrow operation redistributes entries between sibling nodes to resolve underflow without merging. Borrowing is triggered when a node becomes underfull after a delete and one of its siblings has excess entries (above MINIMUM_OCCUPANCY). Unlike merge operations which combine two nodes, borrow moves just enough entries from the richer sibling to bring the underfull node back to minimum occupancy, preserving both nodes. Borrowing is preferred over merging because it moves fewer entries and maintains tree structure. This specification covers borrow algorithms for both leaf and internal nodes, borrow condition detection, entry redistribution strategies, separator updates during borrow, and comprehensive error handling strategies.

## Types

### BorrowResult

**Description**: Result type returned by borrow operations containing borrow metadata

**Fields**:
- **underfull_node_id**: PageId - Page ID of node that received entries (borrower)
- **donor_node_id**: PageId - Page ID of node that gave entries (donor)
- **entries_borrowed**: u16 - Number of entries moved from donor to borrower
- **direction**: BorrowDirection - Which node borrowed from which
- **separator_updated**: bool - True if parent separator was updated
- **new_separator**: Option<Vec<u8>> - New separator key after borrow (if updated)
- **parent_page_id**: PageId - Parent node that had separator updated

**Rationale**: Encapsulates all information needed to track borrow outcome and parent updates

### BorrowDirection

**Description**: Enumeration of possible borrow directions

**Values**:
- **BorrowFromLeft**: Borrow entries from left sibling (move rightmost entries from left)
- **BorrowFromRight**: Borrow entries from right sibling (move leftmost entries from right)

**Rationale**: Direction determines which entries to move and how to update separators

### BorrowContext

**Description**: Context structure tracking state during borrow operation

**Fields**:
- **underfull_node**: PageId - Page ID of underfull node triggering borrow
- **donor_sibling**: PageId - Page ID of donor sibling with excess entries
- **direction**: BorrowDirection - Which direction entries are borrowed
- **parent_page_id**: PageId - Parent node containing separator
- **separator_index**: u16 - Index of separator in parent that divides siblings
- **entries_needed**: u16 - Number of entries required to reach minimum occupancy
- **donor_excess**: u16 - Number of excess entries available in donor

**Rationale**: Captures borrow planning state for validation and execution

### BorrowCandidates

**Description**: Result of borrow eligibility check for siblings

**Fields**:
- **left_sibling_id**: Option<PageId> - Left sibling page ID (if exists)
- **right_sibling_id**: Option<PageId> - Right sibling page ID (if exists)
- - **left_can_donate**: bool - True if left sibling has excess entries
- **right_can_donate**: bool - True if right sibling has excess entries
- **left_excess**: u16 - Number of excess entries in left sibling
- **right_excess**: u16 - Number of excess entries in right sibling
- **preferred_direction**: Option<BorrowDirection> - Recommended borrow direction

**Rationale**: Provides borrow eligibility, available entries, and direction recommendation

## Algorithms

### Borrow Condition Detection

**Purpose**: Determine if underfull node can borrow entries from siblings

**Context**: Node is underfull after delete, checking if siblings have excess entries

**Algorithm**:

1. **Input**: Underfull node page ID, parent node page ID
2. **Read Underfull Node**:
   - underfull_node = pager.read_page(underfull_node_id)
   - underfull_count = underfull_node.header.num_keys
   - min_occupancy = MINIMUM_OCCUPANCY
   - entries_needed = min_occupancy - underfull_count
3. **Read Parent Node**:
   - parent = pager.read_page(parent_page_id)
4. **Locate Underfull Node in Parent**:
   - Execute binary search in parent for separator leading to underfull_node
   - separator_index = search result
5. **Identify Siblings**:
   - If separator_index > 0:
     - left_sibling_id = parent.child_pointers[separator_index - 1]
   - Else:
     - left_sibling_id = None
   - If separator_index < parent.header.num_keys:
     - right_sibling_id = parent.child_pointers[separator_index + 1]
   - Else:
     - right_sibling_id = None
6. **Check Left Sibling Donation**:
   - If left_sibling_id exists:
     - left_sibling = pager.read_page(left_sibling_id)
     - left_count = left_sibling.header.num_keys
     - left_excess = left_count - min_occupancy
     - left_can_donate = (left_excess > 0)
   - Else:
     - left_can_donate = false
     - left_excess = 0
7. **Check Right Sibling Donation**:
   - If right_sibling_id exists:
     - right_sibling = pager.read_page(right_sibling_id)
     - right_count = right_sibling.header.num_keys
     - right_excess = right_count - min_occupancy
     - right_can_donate = (right_excess > 0)
   - Else:
     - right_can_donate = false
     - right_excess = 0
8. **Determine Preferred Direction**:
   - If left_can_donate && right_can_donate:
     - Prefer sibling with more excess entries (maximize borrow efficiency)
     - If left_excess >= right_excess:
       - preferred_direction = BorrowFromLeft
     - Else:
       - preferred_direction = BorrowFromRight
   - Else if left_can_donate:
     - preferred_direction = BorrowFromLeft
   - Else if right_can_donate:
     - preferred_direction = BorrowFromRight
   - Else:
     - preferred_direction = None (no sibling can donate)
9. **Return**: BorrowCandidates with eligibility and excess counts

**Time Complexity**: O(1) for reads and calculations

**Space Complexity**: O(1)

**Returns**: BorrowCandidates indicating borrow eligibility

**Error Conditions**:
- **InvalidParent**: Parent node validation fails
- **NodeNotFound**: Underfull node or sibling not found
- **CorruptNode**: Node header validation fails

**Concurrency**: Shared read access to siblings

### Leaf Node Borrow (From Right Sibling)

**Purpose**: Borrow entries from right leaf sibling to resolve underflow

**Context**: Left leaf is underfull, right leaf has excess entries

**Algorithm**:

1. **Input**: Left (underfull) leaf, right (donor) leaf, parent node, separator_index
2. **Calculate Borrow Count**:
   - underfull_count = left_leaf.header.num_keys
   - min_occupancy = MINIMUM_OCCUPANCY
   - entries_needed = min_occupancy - underfull_count
   - donor_excess = right_leaf.header.num_keys - min_occupancy
   - borrow_count = min(entries_needed, donor_excess)
   - Don't take more than needed (preserve donor's minimum occupancy)
3. **Move Entries from Right to Left**:
   - For i from 0 to borrow_count - 1:
     - entry = right_leaf.entries[0] (leftmost entry)
     - Remove entry from right_leaf.entries[0]
     - Shift right_leaf.entries[1..] left by one position
     - Append entry to left_leaf.entries
   - Move borrow_count entries total
4. **Update Entry Counts**:
   - left_leaf.header.num_keys += borrow_count
   - right_leaf.header.num_keys -= borrow_count
5. **Update Parent Separator**:
   - Old separator divided siblings: left keys < separator <= right keys
   - New separator = first key remaining in right leaf (right_leaf.entries[0].key)
   - parent.separators[separator_index] = new_separator
6. **Update Node Metadata**:
   - Recalculate left_leaf.header.free_space
   - Recalculate right_leaf.header.free_space
   - Set dirty flag on both leaves
   - Increment generation counter on both leaves
   - Recalculate checksum for both leaves
   - Set parent dirty flag
   - Increment parent generation
   - Recalculate parent checksum
7. **Write Modified Nodes**:
   - Write left_leaf to Pager
   - Write right_leaf to Pager
   - Write parent to Pager
8. **Validate Borrow**:
   - Verify left_leaf.header.num_keys >= min_occupancy
   - Verify right_leaf.header.num_keys >= min_occupancy
   - Verify total entries preserved: left_count + right_count = original_total
   - Verify new separator correctly divides key space
9. **Construct BorrowResult**:
    - Return BorrowResult with:
      - underfull_node_id = left_leaf.page_id
      - donor_node_id = right_leaf.page_id
      - entries_borrowed = borrow_count
      - direction = BorrowFromRight
      - separator_updated = true
      - new_separator = new separator key
      - parent_page_id = parent.page_id

**Time Complexity**:
- Entry movement: O(b) where b is borrow_count (shifting right leaf entries)
- Separator update: O(1)
- Total: O(b)

**Space Complexity**: O(1)

**Returns**: BorrowResult containing borrow metadata

**Error Conditions**:
- **InsufficientExcess**: Donor doesn't have enough entries to maintain minimum
- **IOError**: Pager read/write operation fails
- **CorruptNode**: Node validation fails
- **SeparatorUpdateFailed**: Cannot update parent separator

**Concurrency**: Exclusive access required (blocks operations on both leaves and parent)

**Edge Cases**:
- **Borrow exactly needed**: Borrow exactly entries_needed entries (left reaches minimum, right stays above minimum)
- **Borrow all excess**: Donor has exactly minimum after borrow (right at minimum)
- **Borrow with overflow pages**: Overflow page IDs moved correctly with entries
- **Borrow with tombstones**: Tombstone entries moved like normal entries

### Leaf Node Borrow (From Left Sibling)

**Purpose**: Borrow entries from left leaf sibling to resolve underflow

**Context**: Right leaf is underfull, left leaf has excess entries

**Algorithm**:

1. **Input**: Left (donor) leaf, right (underfull) leaf, parent node, separator_index
2. **Calculate Borrow Count**:
   - underfull_count = right_leaf.header.num_keys
   - min_occupancy = MINIMUM_OCCUPANCY
   - entries_needed = min_occupancy - underfull_count
   - donor_excess = left_leaf.header.num_keys - min_occupancy
   - borrow_count = min(entries_needed, donor_excess)
3. **Move Entries from Left to Right**:
   - For i from 0 to borrow_count - 1:
     - entry = left_leaf.entries[last_index] (rightmost entry)
     - Remove entry from left_leaf.entries[last_index]
     - Prepend entry to right_leaf.entries (insert at beginning)
     - Shift right_leaf.entries[0..] right by one position
   - Move borrow_count entries total
4. **Update Entry Counts**:
   - left_leaf.header.num_keys -= borrow_count
   - right_leaf.header.num_keys += borrow_count
5. **Update Parent Separator**:
   - Old separator divided siblings: left keys < separator <= right keys
   - New separator = first key in right leaf after borrow (right_leaf.entries[0].key)
   - parent.separators[separator_index] = new_separator
6. **Update Node Metadata**:
   - Recalculate free_space for both leaves
   - Set dirty flag on both leaves
   - Increment generation counter on both leaves
   - Recalculate checksum for both leaves
   - Update parent metadata
7. **Write Modified Nodes**:
   - Write left_leaf to Pager
   - Write right_leaf to Pager
   - Write parent to Pager
8. **Validate Borrow**:
   - Verify right_leaf.header.num_keys >= min_occupancy
   - Verify left_leaf.header.num_keys >= min_occupancy
   - Verify total entries preserved
   - Verify new separator correctly divides key space
9. **Construct BorrowResult**:
    - Return BorrowResult with:
      - underfull_node_id = right_leaf.page_id
      - donor_node_id = left_leaf.page_id
      - entries_borrowed = borrow_count
      - direction = BorrowFromLeft
      - separator_updated = true
      - new_separator = new separator key
      - parent_page_id = parent.page_id

**Time Complexity**: O(b) where b is borrow_count (shifting right leaf entries)

**Space Complexity**: O(1)

**Returns**: BorrowResult

**Rationale**: Borrowing from left is symmetric to borrowing from right, but requires prepending entries (more shifting).

### Internal Node Borrow (From Right Sibling)

**Purpose**: Borrow separator and child pointers from right internal sibling

**Context**: Left internal is underfull, right internal has excess separators

**Algorithm**:

1. **Input**: Left (underfull) internal, right (donor) internal, parent node, separator_index
2. **Calculate Borrow Count**:
   - underfull_count = left_internal.header.num_keys
   - min_occupancy = MINIMUM_OCCUPANCY
   - entries_needed = min_occupancy - underfull_count
   - donor_excess = right_internal.header.num_keys - min_occupancy
   - borrow_count = min(entries_needed, donor_excess)
3. **Move Parent Separator to Left**:
   - parent_separator = parent.separators[separator_index]
   - Append parent_separator to left_internal.separators
   - This separator divided the siblings, now belongs to left
4. **Move Separators from Right to Left**:
   - For i from 0 to borrow_count - 1:
     - separator = right_internal.separators[0] (leftmost separator)
     - Remove separator from right_internal.separators[0]
     - Shift right_internal.separators[1..] left
     - Append separator to left_internal.separators
5. **Move Child Pointers from Right to Left**:
   - For i from 0 to borrow_count:
     - child_pointer = right_internal.children[0] (leftmost child pointer)
     - Remove child_pointer from right_internal.children[0]
     - Shift right_internal.children[1..] left
     - Append child_pointer to left_internal.children
     - Update child.parent_page_id = left_internal.page_id
   - Move borrow_count + 1 child pointers (one more than separators)
6. **Update Parent Separator**:
   - New parent separator = first separator remaining in right_internal
   - parent.separators[separator_index] = new_parent_separator
7. **Update Counts**:
   - left_internal.header.num_keys += borrow_count + 1 (+1 for parent separator)
   - right_internal.header.num_keys -= borrow_count
8. **Update Node Metadata**:
   - Recalculate free_space for both internal nodes
   - Set dirty flag on both nodes
   - Increment generation counter on both nodes
   - Recalculate checksum for both nodes
   - Update parent metadata
9. **Write Modified Nodes**:
   - Write left_internal to Pager
   - Write right_internal to Pager
   - Write parent to Pager
   - Write updated children to Pager (parent pointer updates)
10. **Validate Borrow**:
    - Verify left_internal.header.num_keys >= min_occupancy
    - Verify right_internal.header.num_keys >= min_occupancy
    - Verify child pointer count = separator count + 1 for both
    - Verify all parent pointers updated correctly
11. **Construct BorrowResult**:
    - Return BorrowResult with:
      - underfull_node_id = left_internal.page_id
      - donor_node_id = right_internal.page_id
      - entries_borrowed = borrow_count
      - direction = BorrowFromRight
      - separator_updated = true
      - new_separator = new parent separator
      - parent_page_id = parent.page_id

**Time Complexity**:
- Separator movement: O(b) where b is borrow_count
- Child pointer movement: O(b + c) where c is children moved
- Parent pointer updates: O(c)
- Total: O(b + c)

**Space Complexity**: O(1)

**Returns**: BorrowResult

**Error Conditions**:
- **InsufficientExcess**: Donor doesn't have enough separators
- **IOError**: Pager operation fails
- **CorruptNode**: Node validation fails
- **ChildUpdateFailed**: Cannot update child parent pointers

**Concurrency**: Exclusive access required (blocks entire subtree)

**Edge Cases**:
- **Borrow with large fanout**: Moving hundreds of separators and children
- **Deep internal borrow**: Borrowing at high tree level (e.g., level 5)
- **Parent separator as first separator**: Parent separator becomes part of left's separators

### Internal Node Borrow (From Left Sibling)

**Purpose**: Borrow separator and child pointers from left internal sibling

**Context**: Right internal is underfull, left internal has excess separators

**Algorithm**:

1. **Input**: Left (donor) internal, right (underfull) internal, parent node, separator_index
2. **Calculate Borrow Count**:
   - underfull_count = right_internal.header.num_keys
   - min_occupancy = MINIMUM_OCCUPANCY
   - entries_needed = min_occupancy - underfull_count
   - donor_excess = left_internal.header.num_keys - min_occupancy
   - borrow_count = min(entries_needed, donor_excess)
3. **Move Parent Separator to Right**:
   - parent_separator = parent.separators[separator_index]
   - Prepend parent_separator to right_internal.separators
   - Shift right_internal.separators[0..] right by one position
4. **Move Separators from Left to Right**:
   - For i from 0 to borrow_count - 1:
     - separator = left_internal.separators[last_index] (rightmost separator)
     - Remove separator from left_internal.separators[last_index]
     - Prepend separator to right_internal.separators
     - Shift right_internal.separators[0..] right
5. **Move Child Pointers from Left to Right**:
   - For i from 0 to borrow_count:
     - child_pointer = left_internal.children[last_index] (rightmost child pointer)
     - Remove child_pointer from left_internal.children[last_index]
     - Prepend child_pointer to right_internal.children
     - Shift right_internal.children[0..] right
     - Update child.parent_page_id = right_internal.page_id
   - Move borrow_count + 1 child pointers
6. **Update Parent Separator**:
   - New parent separator = last separator moved from left_internal
   - parent.separators[separator_index] = new_parent_separator
7. **Update Counts**:
   - left_internal.header.num_keys -= borrow_count
   - right_internal.header.num_keys += borrow_count + 1
8. **Update Node Metadata**:
   - Recalculate free_space for both nodes
   - Set dirty flag on both nodes
   - Increment generation counter on both nodes
   - Recalculate checksum for both nodes
   - Update parent metadata
9. **Write Modified Nodes**:
   - Write left_internal to Pager
   - Write right_internal to Pager
   - Write parent to Pager
   - Write updated children to Pager
10. **Validate Borrow**:
    - Verify right_internal.header.num_keys >= min_occupancy
    - Verify left_internal.header.num_keys >= min_occupancy
    - Verify child pointer count = separator count + 1
    - Verify all parent pointers updated correctly
11. **Construct BorrowResult**:
    - Return BorrowResult with:
      - underfull_node_id = right_internal.page_id
      - donor_node_id = left_internal.page_id
      - entries_borrowed = borrow_count
      - direction = BorrowFromLeft
      - separator_updated = true
      - new_separator = new parent separator
      - parent_page_id = parent.page_id

**Time Complexity**: O(b + c) (same as borrow from right)

**Space Complexity**: O(1)

**Returns**: BorrowResult

**Rationale**: Borrowing from left requires prepending (more shifting), but is necessary when only left sibling has excess.

## Error Handling

### Borrow Condition Errors

**CannotBorrow**:
- **Detection**: No sibling has excess entries to donate
- **Handling**:
  - Abort borrow operation
  - Attempt merge operation instead
  - If merge also fails: return error
- **Recovery**: Use merge to combine underfull nodes
- **User Action**: No action needed (merge should succeed)

**InsufficientExcess**:
- **Detection**: Donor sibling doesn't have enough entries to maintain minimum after borrow
- **Handling**:
  - Abort borrow operation
  - Calculate if borrow_count > donor_excess
  - Try other sibling (if available)
  - If neither sibling can donate: attempt merge
- **Recovery**: Borrow from other sibling or merge with sibling
- **User Action**: No action needed

### I/O Errors

**ReadFailure**:
- **Detection**: Pager.read_page() fails during borrow (reading sibling)
- **Handling**:
  - Abort borrow operation
  - Return error to caller
- **Recovery**: Retry borrow or attempt merge
- **User Action**: Check disk health, retry operation

**WriteFailure**:
- **Detection**: Pager.write_page() fails after entry movement
- **Handling**:
  - Abort borrow operation
  - Mark nodes as inconsistent (entries partially moved)
  - Return error to caller
- **Recovery**:
  - Recovery process detects partial borrow (entry counts don't match total)
  - Completes borrow or rolls back from WAL
- **User Action**: Run database recovery

**ChildUpdateFailure** (Internal borrow):
- **Detection**: Cannot update child parent pointers
- **Handling**:
  - Abort borrow operation
  - Some children may have updated parent pointers
  - Mark tree as corrupted
  - Return error
- **Recovery**:
  - Rebuild parent pointers from tree structure
  - Or rollback from WAL
- **User Action**: Run database verification and repair

### Structural Errors

**BorrowValidationFailed**:
- **Detection**: Entry count validation fails after borrow
- **Handling**:
  - Abort borrow operation
  - Tree may have corrupted state
  - Return error
- **Recovery**: Rebuild tree structure from WAL
- **User Action**: Run database recovery

**SeparatorUpdateFailed**:
- **Detection**: Cannot update parent separator
- **Handling**:
  - Abort borrow operation
  - Children may have moved but parent not updated
  - Mark tree as corrupted
- **Recovery**: Rebuild parent separators from child boundaries
- **User Action**: Run database repair

**ChildParentPointerInconsistency**:
- **Detection**: Child parent pointers not updated correctly after borrow
- **Handling**:
  - Abort borrow operation
  - Mark tree as corrupted
  - Return error
- **Recovery**: Traverse tree, rebuild parent pointers
- **User Action**: Run database verification and repair

## Invariants

### Borrow Invariants

1. **Minimum Occupancy**: After borrow, both nodes have >= MINIMUM_OCCUPANCY entries
2. **Entry Preservation**: Total entries preserved across both nodes
3. **No Entry Loss**: No entries lost during borrow
4. **No Entry Duplication**: No entry appears in both nodes after borrow
5. **Key Ordering**: Key ordering maintained after borrow

### Leaf Borrow Invariants

1. **Separator Update**: Parent separator updated to reflect new division
2. **Linked List Unchanged**: Leaf linked list pointers unchanged (borrow doesn't affect list structure)
3. **Overflow References**: Overflow page IDs moved correctly with entries
4. **Tombstone Handling**: Tombstone entries moved like normal entries
5. **Scan Correctness**: Range scans still work correctly (linked list unchanged)

### Internal Borrow Invariants

1. **Parent Separator Movement**: Parent separator moves to borrower or becomes new separator
2. **Child Distribution**: All children distributed between borrow nodes (no lost children)
3. **Child Pointer Count**: child_ptr_count = separator_count + 1 for both nodes after borrow
4. **Parent Pointer Correctness**: All moved children have correct parent_page_id
5. **Separator Validity**: New parent separator correctly divides key space

### Borrow vs Merge Invariants

1. **Prefer Borrow**: Borrow attempted before merge (moves fewer entries)
2. **Borrow Sufficient**: If borrow possible, merge not needed
3. **Merge Fallback**: Merge used only when borrow not possible
4. **Donor Preservation**: Donor node remains at or above minimum occupancy
5. **Borrower Recovery**: Borrower node reaches minimum occupancy after borrow

## Rust Implementation Guidance

### Module Structure

The borrow functionality should be organized as:
- `northstar_core::tree::borrow::check_borrow_eligibility` - Borrow condition detection
- `northstar_core::tree::borrow::borrow_leaf_from_right` - Leaf borrow (from right)
- `northstar_core::tree::borrow::borrow_leaf_from_left` - Leaf borrow (from left)
- `northstar_core::tree::borrow::borrow_internal_from_right` - Internal borrow (from right)
- `northstar_core::tree::borrow::borrow_internal_from_left` - Internal borrow (from left)
- `northstar_core::tree::borrow::validate_borrow` - Borrow validation and consistency checks

### Type Definitions

**BorrowResult**: Implement as struct:
```rust
pub struct BorrowResult {
    pub underfull_node_id: PageId,
    pub donor_node_id: PageId,
    pub entries_borrowed: u16,
    pub direction: BorrowDirection,
    pub separator_updated: bool,
    pub new_separator: Option<Vec<u8>>,
    pub parent_page_id: PageId,
}
```

**BorrowDirection**: Implement as enum:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BorrowDirection {
    BorrowFromLeft,  // Borrow from left sibling
    BorrowFromRight, // Borrow from right sibling
}
```

**BorrowContext**: Implement as struct:
```rust
pub struct BorrowContext {
    pub underfull_node: PageId,
    pub donor_sibling: PageId,
    pub direction: BorrowDirection,
    pub parent_page_id: PageId,
    pub separator_index: u16,
    pub entries_needed: u16,
    pub donor_excess: u16,
}
```

**BorrowCandidates**: Implement as struct:
```rust
pub struct BorrowCandidates {
    pub left_sibling_id: Option<PageId>,
    pub right_sibling_id: Option<PageId>,
    pub left_can_donate: bool,
    pub right_can_donate: bool,
    pub left_excess: u16,
    pub right_excess: u16,
    pub preferred_direction: Option<BorrowDirection>,
}
```

### Borrow Condition Detection

Check borrow eligibility:
```rust
pub fn check_borrow_eligibility(
    underfull_node_id: PageId,
    parent_page_id: PageId,
    pager: &Pager,
) -> Result<BorrowCandidates, BorrowError> {
    // Read underfull node
    let underfull_node = pager.read_page(underfull_node_id)?;
    let underfull_count = underfull_node.header.num_keys;
    let entries_needed = MINIMUM_OCCUPANCY.saturating_sub(underfull_count);

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
    let (left_can_donate, left_excess) = if let Some(left_id) = left_sibling_id {
        let left_sibling = pager.read_page(left_id)?;
        let excess = left_sibling.header.num_keys.saturating_sub(MINIMUM_OCCUPANCY);
        (excess > 0, excess)
    } else {
        (false, 0)
    };

    // Check right sibling eligibility
    let (right_can_donate, right_excess) = if let Some(right_id) = right_sibling_id {
        let right_sibling = pager.read_page(right_id)?;
        let excess = right_sibling.header.num_keys.saturating_sub(MINIMUM_OCCUPANCY);
        (excess > 0, excess)
    } else {
        (false, 0)
    };

    // Determine preferred direction
    let preferred_direction = match (left_can_donate, right_can_donate) {
        (true, true) => {
            if left_excess >= right_excess {
                Some(BorrowDirection::BorrowFromLeft)
            } else {
                Some(BorrowDirection::BorrowFromRight)
            }
        }
        (true, false) => Some(BorrowDirection::BorrowFromLeft),
        (false, true) => Some(BorrowDirection::BorrowFromRight),
        (false, false) => None,
    };

    Ok(BorrowCandidates {
        left_sibling_id,
        right_sibling_id,
        left_can_donate,
        right_can_donate,
        left_excess,
        right_excess,
        preferred_direction,
    })
}
```

### Leaf Borrow Implementation (From Right)

Borrow from right leaf sibling:
```rust
pub fn borrow_leaf_from_right(
    left_leaf: &mut LeafNode,
    right_leaf: &mut LeafNode,
    parent: &mut InternalNode,
    separator_index: usize,
) -> Result<BorrowResult, BorrowError> {
    // Calculate borrow count
    let underfull_count = left_leaf.header.num_keys;
    let entries_needed = MINIMUM_OCCUPANCY.saturating_sub(underfull_count);
    let donor_excess = right_leaf.header.num_keys.saturating_sub(MINIMUM_OCCUPANCY);
    let borrow_count = entries_needed.min(donor_excess);

    if borrow_count == 0 {
        return Err(BorrowError::InsufficientExcess);
    }

    // Move entries from right to left
    for _ in 0..borrow_count {
        let entry = right_leaf.entries.remove(0);
        left_leaf.entries.push(entry);
    }

    // Update counts
    left_leaf.header.num_keys += borrow_count;
    right_leaf.header.num_keys -= borrow_count;

    // Update parent separator
    let new_separator = right_leaf.entries[0].key.clone();
    let old_separator = parent.separators[separator_index].clone();
    parent.separators[separator_index] = new_separator.clone();

    // Update metadata
    left_leaf.header.free_space = calculate_free_space(left_leaf);
    right_leaf.header.free_space = calculate_free_space(right_leaf);
    left_leaf.header.set_flag(NodeFlags::DIRTY);
    right_leaf.header.set_flag(NodeFlags::DIRTY);
    left_leaf.header.generation += 1;
    right_leaf.header.generation += 1;
    left_leaf.header.checksum = calculate_checksum(left_leaf);
    right_leaf.header.checksum = calculate_checksum(right_leaf);

    parent.header.set_flag(NodeFlags::DIRTY);
    parent.header.generation += 1;
    parent.header.checksum = calculate_checksum(parent);

    // Write nodes
    pager.write_page(left_leaf.header.node_id, left_leaf)?;
    pager.write_page(right_leaf.header.node_id, right_leaf)?;
    pager.write_page(parent.header.node_id, parent)?;

    Ok(BorrowResult {
        underfull_node_id: left_leaf.header.node_id,
        donor_node_id: right_leaf.header.node_id,
        entries_borrowed: borrow_count,
        direction: BorrowDirection::BorrowFromRight,
        separator_updated: true,
        new_separator: Some(new_separator),
        parent_page_id: parent.header.node_id,
    })
}
```

### Leaf Borrow Implementation (From Left)

Borrow from left leaf sibling:
```rust
pub fn borrow_leaf_from_left(
    left_leaf: &mut LeafNode,
    right_leaf: &mut LeafNode,
    parent: &mut InternalNode,
    separator_index: usize,
) -> Result<BorrowResult, BorrowError> {
    // Calculate borrow count
    let underfull_count = right_leaf.header.num_keys;
    let entries_needed = MINIMUM_OCCUPANCY.saturating_sub(underfull_count);
    let donor_excess = left_leaf.header.num_keys.saturating_sub(MINIMUM_OCCUPANCY);
    let borrow_count = entries_needed.min(donor_excess);

    if borrow_count == 0 {
        return Err(BorrowError::InsufficientExcess);
    }

    // Move entries from left to right (prepend)
    for _ in 0..borrow_count {
        let entry = left_leaf.entries.pop().unwrap();
        right_leaf.entries.insert(0, entry);
    }

    // Update counts
    left_leaf.header.num_keys -= borrow_count;
    right_leaf.header.num_keys += borrow_count;

    // Update parent separator
    let new_separator = right_leaf.entries[0].key.clone();
    parent.separators[separator_index] = new_separator.clone();

    // Update metadata
    left_leaf.header.free_space = calculate_free_space(left_leaf);
    right_leaf.header.free_space = calculate_free_space(right_leaf);
    // ... dirty flags, generation, checksum ...

    Ok(BorrowResult {
        underfull_node_id: right_leaf.header.node_id,
        donor_node_id: left_leaf.header.node_id,
        entries_borrowed: borrow_count,
        direction: BorrowDirection::BorrowFromLeft,
        separator_updated: true,
        new_separator: Some(new_separator),
        parent_page_id: parent.header.node_id,
    })
}
```

### Internal Borrow Implementation (From Right)

Borrow from right internal sibling:
```rust
pub fn borrow_internal_from_right(
    left_internal: &mut InternalNode,
    right_internal: &mut InternalNode,
    parent: &mut InternalNode,
    separator_index: usize,
    pager: &mut Pager,
) -> Result<BorrowResult, BorrowError> {
    // Calculate borrow count
    let underfull_count = left_internal.header.num_keys;
    let entries_needed = MINIMUM_OCCUPANCY.saturating_sub(underfull_count);
    let donor_excess = right_internal.header.num_keys.saturating_sub(MINIMUM_OCCUPANCY);
    let borrow_count = entries_needed.min(donor_excess);

    if borrow_count == 0 {
        return Err(BorrowError::InsufficientExcess);
    }

    // Move parent separator to left
    let parent_separator = parent.separators[separator_index].clone();
    left_internal.separators.push(parent_separator);

    // Move separators from right to left
    for _ in 0..borrow_count {
        let separator = right_internal.separators.remove(0);
        left_internal.separators.push(separator);
    }

    // Move child pointers from right to left
    for _ in 0..(borrow_count + 1) {
        let child_id = right_internal.children.remove(0);

        // Update child parent pointer
        let mut child = pager.read_page(child_id)?;
        child.header.parent_page_id = left_internal.header.node_id;
        child.header.set_flag(NodeFlags::DIRTY);
        child.header.generation += 1;
        child.header.checksum = calculate_checksum(&child);
        pager.write_page(child_id, &child)?;

        left_internal.children.push(child_id);
    }

    // Update parent separator
    let new_separator = right_internal.separators[0].clone();
    parent.separators[separator_index] = new_separator.clone();

    // Update counts
    left_internal.header.num_keys += borrow_count + 1;
    right_internal.header.num_keys -= borrow_count;

    // Update metadata
    // ... free_space, dirty flags, generation, checksum ...

    // Write nodes
    pager.write_page(left_internal.header.node_id, left_internal)?;
    pager.write_page(right_internal.header.node_id, right_internal)?;
    pager.write_page(parent.header.node_id, parent)?;

    Ok(BorrowResult {
        underfull_node_id: left_internal.header.node_id,
        donor_node_id: right_internal.header.node_id,
        entries_borrowed: borrow_count,
        direction: BorrowDirection::BorrowFromRight,
        separator_updated: true,
        new_separator: Some(new_separator),
        parent_page_id: parent.header.node_id,
    })
}
```

### Internal Borrow Implementation (From Left)

Borrow from left internal sibling:
```rust
pub fn borrow_internal_from_left(
    left_internal: &mut InternalNode,
    right_internal: &mut InternalNode,
    parent: &mut InternalNode,
    separator_index: usize,
    pager: &mut Pager,
) -> Result<BorrowResult, BorrowError> {
    // Calculate borrow count
    let underfull_count = right_internal.header.num_keys;
    let entries_needed = MINIMUM_OCCUPANCY.saturating_sub(underfull_count);
    let donor_excess = left_internal.header.num_keys.saturating_sub(MINIMUM_OCCUPANCY);
    let borrow_count = entries_needed.min(donor_excess);

    if borrow_count == 0 {
        return Err(BorrowError::InsufficientExcess);
    }

    // Move parent separator to right (prepend)
    let parent_separator = parent.separators[separator_index].clone();
    right_internal.separators.insert(0, parent_separator);

    // Move separators from left to right (prepend)
    for _ in 0..borrow_count {
        let separator = left_internal.separators.pop().unwrap();
        right_internal.separators.insert(0, separator);
    }

    // Move child pointers from left to right (prepend)
    for _ in 0..(borrow_count + 1) {
        let child_id = left_internal.children.pop().unwrap();

        // Update child parent pointer
        let mut child = pager.read_page(child_id)?;
        child.header.parent_page_id = right_internal.header.node_id;
        child.header.set_flag(NodeFlags::DIRTY);
        child.header.generation += 1;
        child.header.checksum = calculate_checksum(&child);
        pager.write_page(child_id, &child)?;

        right_internal.children.insert(0, child_id);
    }

    // Update parent separator
    let new_separator = right_internal.separators[borrow_count].clone();
    parent.separators[separator_index] = new_separator.clone();

    // Update counts
    left_internal.header.num_keys -= borrow_count;
    right_internal.header.num_keys += borrow_count + 1;

    // Update metadata
    // ... free_space, dirty flags, generation, checksum ...

    // Write nodes
    pager.write_page(left_internal.header.node_id, left_internal)?;
    pager.write_page(right_internal.header.node_id, right_internal)?;
    pager.write_page(parent.header.node_id, parent)?;

    Ok(BorrowResult {
        underfull_node_id: right_internal.header.node_id,
        donor_node_id: left_internal.header.node_id,
        entries_borrowed: borrow_count,
        direction: BorrowDirection::BorrowFromLeft,
        separator_updated: true,
        new_separator: Some(new_separator),
        parent_page_id: parent.header.node_id,
    })
}
```

### Key Decisions

**Borrow vs Merge**: Always prefer borrow over merge. Borrow moves fewer entries (1 to many vs all entries). Merge only when borrow not possible (both siblings at minimum).

**Borrow Direction Selection**: Prefer sibling with more excess entries. Maximizes borrow efficiency and may prevent immediate future borrow/merge.

**Separator Update**: Always update parent separator after borrow. Critical for maintaining search path correctness.

**Parent Pointer Updates**: Update all moved children's parent pointers immediately. Eager updates ensure consistency for future operations.

**Borrow Count Calculation**: borrow_count = min(entries_needed, donor_excess). Don't take more than needed (preserves donor's minimum).

**Internal Borrow with Parent Separator**: Parent separator moves to borrower. Distinguishes internal borrow from leaf borrow (where parent separator stays in parent).

### Implementation Notes

1. **Borrow Count**: Calculate minimum of needed and excess:
   ```rust
   let borrow_count = entries_needed.min(donor_excess);
   ```

2. **Entry Movement**: Use remove/insert or pop/push:
   ```rust
   // From right: remove from front
   let entry = right_leaf.entries.remove(0);
   left_leaf.entries.push(entry);

   // From left: pop from back
   let entry = left_leaf.entries.pop().unwrap();
   right_leaf.entries.insert(0, entry);
   ```

3. **Separator Update**: Update parent separator:
   ```rust
   parent.separators[separator_index] = new_separator;
   ```

4. **Parent Separator Movement**: Move parent separator to internal node:
   ```rust
   let parent_separator = parent.separators[separator_index].clone();
   left_internal.separators.push(parent_separator);
   ```

5. **Child Pointer Updates**: Update all moved children:
   ```rust
   for child_id in &moved_children {
       update_child_parent(pager, *child_id, new_parent_id)?;
   }
   ```

6. **Validation**: Verify borrow invariants:
   ```rust
   assert!(left_leaf.num_keys >= MIN_OCCUPANCY);
   assert!(right_leaf.num_keys >= MIN_OCCUPANCY);
   assert!(left_leaf.num_keys + right_leaf.num_keys == original_total);
   ```

7. **Error Handling**: Use question mark operator:
   ```rust
   let borrow_count = entries_needed.min(donor_excess);
   if borrow_count == 0 {
       return Err(BorrowError::InsufficientExcess);
   }
   ```

### Testing Strategy

**Unit tests needed for**:
- Borrow condition detection (various occupancy levels)
- Leaf borrow from right
- Leaf borrow from left
- Internal borrow from right
- Internal borrow from left
- Borrow validation (entry counts, ordering)
- Separator update correctness
- Child parent pointer updates (internal borrow)

**Property tests for**:
- Borrow preserves total entries
- Borrow maintains key ordering
- Both nodes >= minimum occupancy after borrow
- Parent separator correctly divides key space
- Child pointers valid after internal borrow
- Borrow moves fewer entries than merge

**Integration scenarios**:
- Delete causing borrow (trigger redistribution)
- Borrow at various tree levels
- Borrow with overflow pages and tombstones
- Borrow with concurrent readers (MVCC correctness)
- Borrow, crash during borrow, recover, verify consistency
- Borrow preventing merge (verify efficiency)

**Fuzzing targets**:
- Borrow with various occupancy levels (just at minimum)
- Borrow with malformed nodes
- Rapid borrows (stress test entry movement)
- Borrow during concurrent operations
- Borrow with I/O errors injected

**Performance benchmarks**:
- Leaf borrow cost (time per borrow)
- Internal borrow cost
- Comparison with merge operation cost
- Borrow impact on delete latency
- Separator update overhead
- Child pointer update cost

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and borrow overview
- **06-btree-node.md**: Internal and leaf node structures for borrow targets
- **06-btree-header.md**: Node header fields updated during borrow
- **06-btree-delete.md**: Delete operation that triggers borrows
- **06-btree-merge.md**: Merge operation as alternative to borrow
- **06-btree-search.md**: Search algorithm for finding siblings
- **02-pager-*.md**: Pager integration for node I/O
- **03-wal-*.md**: WAL integration for crash-safe borrows
