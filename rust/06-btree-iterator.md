# B+Tree Iterator State Machine

## Purpose

The B+Tree iterator implements a state machine that maintains position and state during range scan operations. The iterator tracks the current leaf node, entry index, traversal path from root, and scan context to efficiently yield sequential key-value pairs. This specification describes the complete iterator design, including state representation, state transitions, stack-based traversal, forward and reverse iteration, and integration with the Pager cache system.

## Types

### IteratorState

**Description**: Current state of iterator in its lifecycle

**Variants**:

1. **Initialized**
   - **Purpose**: Iterator created but not yet advanced
   - **Next State**: Active (after first next() call)
   - **Behavior**: Position at start of scan range, ready to yield first result

2. **Active**
   - **Purpose**: Iterator actively yielding results
   - **Next State**: Active or Exhausted
   - **Behavior**: Valid current position, can yield result or advance

3. **Exhausted**
   - **Purpose**: Iterator reached end of scan range
   - **Next State**: Terminal (no further transitions)
   - **Behavior**: No more results, next() returns None

4. **Error
   - **Purpose**: Iterator encountered error
   - **Next State**: Terminal (no further transitions)
   - **Behavior**: next() returns None, error accessible via get_error()

### IteratorPosition

**Description**: Position tracking within B+Tree structure

**Fields**:

1. **current_page_id** (PageId, 8 bytes)
   - **Purpose**: Page ID of current leaf node
   - **Value**: Valid page ID of leaf currently being iterated
   - **Invariant**: Must point to valid leaf node in tree

2. **current_index** (u16, 2 bytes)
   - **Purpose**: Index of current entry within current leaf
   - **Value**: 0 to leaf.entry_count - 1
   - **Invariant**: Must be within valid range for current leaf

3. **prev_page_id** (Option<PageId>, 8 bytes)
   - **Purpose**: Page ID of previous leaf node (for reverse traversal)
   - **Value**: Some(page_id) if valid previous leaf, None if leftmost
   - **Invariant**: If Some, must point to valid leaf node

4. **next_page_id** (Option<PageId>, 8 bytes)
   - **Purpose**: Page ID of next leaf node (for forward traversal)
   - **Value**: Some(page_id) if valid next leaf, None if rightmost
   - **Invariant**: If Some, must point to valid leaf node

**Size**: Approximately 34 bytes

### TraversalStack

**Description**: Stack-based path from root to current position

**Purpose**: Enables efficient backtracking and upward navigation without redundant searches

**Structure**: Vector of stack frames, one per tree level

**Stack Frame**:

1. **page_id** (PageId, 8 bytes)
   - **Purpose**: Page ID of node at this level
   - **Value**: Valid page ID of internal or leaf node

2. **index** (u16, 2 bytes)
   - **Purpose**: Index within this node leading to next level
   - **Value**: 0 to node.entry_count

3. **node_type** (u8, 1 byte)
   - **Purpose**: Type of node (internal or leaf)
   - **Value**: NodeType enum value

**Frame Size**: 11 bytes

**Stack Size**: 0 to tree_height frames (typically 1-4 for practical trees)

### ScanContext

**Description**: Scan parameters and options controlling iteration

**Fields**:

1. **start_key** (Option<Vec<u8>>, variable)
   - **Purpose**: Lower bound of scan range
   - **Value**: Some(key) for bounded, None for unbounded

2. **end_key** (Option<Vec<u8>>, variable)
   - **Purpose**: Upper bound of scan range
   - **Value**: Some(key) for bounded, None for unbounded

3. **snapshot_lsn** (Lsn, 8 bytes)
   - **Purpose**: Snapshot LSN for MVCC visibility
   - **Value**: Valid committed LSN

4. **reverse** (bool, 1 byte)
   - **Purpose**: Scan direction
   - **Value**: false (forward/ascending) or true (reverse/descending)

5. **skip_deleted** (bool, 1 byte)
   - **Purpose**: Skip tombstone entries
   - **Value**: true to skip deleted, false to include

6. **max_results** (Option<usize>, 8 bytes)
   - **Purpose**: Maximum results to yield
   - **Value**: Some(limit) to cap results, None for unlimited

**Size**: Variable (depends on key lengths)

### BTreeIterator

**Description**: Main iterator structure implementing state machine

**Fields**:

1. **state** (IteratorState, 1 byte)
   - **Purpose**: Current iterator state
   - **Value**: One of Initialized, Active, Exhausted, Error

2. **position** (IteratorPosition, 34 bytes)
   - **Purpose**: Current position in tree
   - **Value**: Current page, index, and neighboring pages

3. **stack** (TraversalStack, variable)
   - **Purpose**: Path from root to current position
   - **Value**: Stack frames for each level

4. **context** (ScanContext, variable)
   - **Purpose**: Scan parameters and options
   - **Value**: Range, snapshot, direction options

5. **stats** (ScanStats, 40 bytes)
   - **Purpose**: Statistics collected during iteration
   - **Value**: Entries scanned, returned, pages read, duration

6. **yielded_count** (usize, 8 bytes)
   - **Purpose**: Number of results yielded so far
   - **Value**: 0 to max_results (if bounded)

7. **error** (Option<IteratorError>, variable)
   - **Purpose**: Error encountered during iteration
   - **Value**: Some(error) if in Error state, None otherwise

**Size**: Variable (depends on stack depth and key lengths)

## State Machine

### State Transitions

**Initial State**: Initialized

**Transition Rules**:

1. **Initialized → Active**:
   - **Trigger**: First call to next() or next_back()
   - **Action**: Position at start of scan range, attempt to yield first result
   - **Validity**: Always valid (no preconditions)

2. **Active → Active**:
   - **Trigger**: Call to next() or next_back() with more results available
   - **Action**: Advance position, check bounds, yield next result
   - **Validity**: Current position valid, within range, not at max_results

3. **Active → Exhausted**:
   - **Trigger**: Call to next() or next_back() with no more results
   - **Action**: Mark iterator exhausted, return None
   - **Validity**: Reached end of range, end of tree, or max_results

4. **[Any State] → Error**:
   - **Trigger**: I/O error, corruption detected, or invariant violation
   - **Action**: Store error, transition to Error state
   - **Validity**: Error occurred during operation

5. **Error → Terminal**:
   - **Trigger**: Any subsequent operation after entering Error state
   - **Action**: Return None, error accessible via get_error()
   - **Validity**: Error state is terminal

**State Diagram**:
```
        next() / next_back()
    +---------------------------+
    |                           |
    v                           |
[Initialized] --------> [Active]
                            |
                            | No more results
                            v
                       [Exhausted]

[Any State] --error--> [Error] --any op--> [Terminal]
```

### State Validity Checks

**Initialized State**:
- position.current_page_id valid (or None if unbounded start)
- stack empty or partially populated
- context valid (range, snapshot, options)
- stats.zeroed
- yielded_count = 0

**Active State**:
- position.current_page_id valid and points to leaf
- position.current_index within valid range [0, leaf.entry_count)
- stack fully populated (path from root to current position)
- yielded_count <= max_results (if bounded)
- state not exhausted or error

**Exhausted State**:
- position may be at end of tree or invalid
- yielded_count == max_results (if bounded) or reached range end
- state terminal (no further transitions)

**Error State**:
- error field contains error details
- state terminal (no further transitions)
- stats reflect partial progress before error

## Functions

### Iterator Creation

**create_iterator(tree: BTree, context: ScanContext) -> BTreeIterator**

**Purpose**: Create new iterator initialized at start position

**Algorithm**:
1. **Validate Context**:
   a. Check start_key and end_key valid (if provided)
   b. Validate snapshot_lsn is valid committed LSN
   c. Validate options (reverse, skip_deleted, max_results)

2. **Initialize Position**:
   a. If context.start_key is None:
      i. Traverse to leftmost (or rightmost if reverse) leaf
      ii. Set position.current_page_id = leaf.page_id
      iii. Set position.current_index = 0 (or leaf.entry_count - 1 if reverse)
   b. If context.start_key is Some:
      i. Search for start_key in tree
      ii. Position at exact match or next key > start_key
      iii. Set position.current_page_id and current_index accordingly

3. **Build Traversal Stack**:
   a. Starting from root, record path to current position
   b. For each level:
      i. Create stack frame with page_id, index, node_type
      ii. Push frame onto stack
   c. Stack height = tree_height

4. **Initialize Iterator**:
   a. Set state = Initialized
   b. Set position (current_page_id, current_index, neighbors)
   c. Set stack (path from root to position)
   d. Set context (scan parameters)
   e. Initialize stats = ScanStats::zero()
   f. Set yielded_count = 0

5. **Return Iterator**:
   a. Return BTreeIterator ready for first next() call

**Returns**: Initialized BTreeIterator

**Error Conditions**:
- InvalidRange: start_key > end_key
- InvalidSnapshot: snapshot_lsn invalid
- TreeCorrupt: Tree structure inconsistent
- IOError: Pager I/O failure during traversal

**Concurrency**: Creates independent iterator (safe for concurrent iterators)

### Forward Iteration

**next(iterator: BTreeIterator) -> Option<ScanResult>**

**Purpose**: Advance iterator and return next result (forward direction)

**Algorithm**:
1. **Check State**:
   a. If state == Exhausted or state == Error, return None
   b. If state == Initialized, transition to Active

2. **Check Max Results**:
   a. If context.max_results is Some(limit) and yielded_count >= limit:
      i. Transition state to Exhausted
      ii. Return None

3. **Read Current Entry**:
   a. Read current leaf page from Pager using position.current_page_id
   b. Access entry at position.current_index
   c. Extract key, value, and LSN from entry

4. **Check End Key Bound**:
   a. If context.end_key is Some(end_key):
      i. If current_key >= end_key (exclusive) or current_key > end_key (inclusive):
         - Transition state to Exhausted
         - Return None
   b. If no end_key bound, continue

5. **Check Visibility**:
   a. If entry.lsn > context.snapshot_lsn:
      i. Skip this entry (invisible to snapshot)
      ii. Advance to next entry (see step 8)
      iii. Recursively call next() and return result
   b. If entry visible, continue

6. **Check Deleted Flag**:
   a. If context.skip_deleted is true and entry.is_deleted is true:
      i. Skip this entry (deleted)
      ii. Advance to next entry (see step 8)
      iii. Recursively call next() and return result
   b. If entry not deleted or skip_deleted is false, continue

7. **Yield Result**:
   a. Create ScanResult with key, value, lsn
   b. Increment stats.entries_returned
   c. Increment yielded_count
   d. Create result to return (don't advance yet)

8. **Advance Position**:
   a. Increment position.current_index by 1
   b. If position.current_index >= leaf.entry_count:
      i. Move to next leaf:
         - Set position.current_page_id = leaf.next_leaf
         - Set position.current_index = 0
      ii. Update stack: pop leaf frame, traverse to next leaf
      iii. If next_leaf is 0 (rightmost):
         - Transition state to Exhausted
   c. Increment stats.entries_scanned

9. **Return Result**:
   a. Return Some(ScanResult) created in step 7

**Returns**: Some(ScanResult) for next result, None if exhausted

**Error Conditions**: On error, transition to Error state and return None

**Concurrency**: Read-only (safe for concurrent reads)

### Reverse Iteration

**next_back(iterator: BTreeIterator) -> Option<ScanResult>**

**Purpose**: Advance iterator and return previous result (reverse direction)

**Algorithm**:
1. **Check State**:
   a. If state == Exhausted or state == Error, return None
   b. If state == Initialized, transition to Active

2. **Check Max Results**:
   a. If context.max_results is Some(limit) and yielded_count >= limit:
      i. Transition state to Exhausted
      ii. Return None

3. **Read Current Entry**:
   a. Read current leaf page from Pager using position.current_page_id
   b. Access entry at position.current_index
   c. Extract key, value, and LSN from entry

4. **Check End Key Bound (Reverse)**:
   a. If context.end_key is Some(end_key) (lower bound in reverse):
      i. If current_key < end_key (exclusive) or current_key <= end_key (inclusive):
         - Transition state to Exhausted
         - Return None
   b. If no end_key bound, continue

5. **Check Visibility**:
   a. If entry.lsn > context.snapshot_lsn:
      i. Skip this entry (invisible to snapshot)
      ii. Advance to previous entry (see step 8)
      iii. Recursively call next_back() and return result
   b. If entry visible, continue

6. **Check Deleted Flag**:
   a. If context.skip_deleted is true and entry.is_deleted is true:
      i. Skip this entry (deleted)
      ii. Advance to previous entry (see step 8)
      iii. Recursively call next_back() and return result
   b. If entry not deleted or skip_deleted is false, continue

7. **Yield Result**:
   a. Create ScanResult with key, value, lsn
   b. Increment stats.entries_returned
   c. Increment yielded_count
   d. Create result to return (don't advance yet)

8. **Advance Position (Reverse)**:
   a. Decrement position.current_index by 1
   b. If position.current_index wrapped (underflow to max u16):
      i. Move to previous leaf:
         - Set position.current_page_id = leaf.prev_leaf
         - Set position.current_index = leaf.entry_count - 1
      ii. Update stack: pop leaf frame, traverse to prev leaf
      iii. If prev_leaf is 0 (leftmost):
         - Transition state to Exhausted
   c. Increment stats.entries_scanned

9. **Return Result**:
   a. Return Some(ScanResult) created in step 7

**Returns**: Some(ScanResult) for previous result, None if exhausted

**Error Conditions**: On error, transition to Error state and return None

**Concurrency**: Read-only (safe for concurrent reads)

### Stack-Based Traversal

**traverse_to_leaf(tree: BTree, start_key: Option<&[u8]>, reverse: bool) -> (PageId, usize, TraversalStack)**

**Purpose**: Traverse from root to leaf, building stack path

**Algorithm**:
1. **Initialize Stack**:
   a. Create empty TraversalStack
   b. Set current_node = tree.root_page_id

2. **Traverse Downward**:
   a. While current_node is internal node:
      i. Read current_node from Pager
      ii. If start_key is None:
         - target_index = 0 if reverse, else node.entry_count
      iii. If start_key is Some:
         - Binary search for start_key in current_node
         - target_index = insertion point
      iv. Create stack frame:
         - frame.page_id = current_node.page_id
         - frame.index = target_index
         - frame.node_type = current_node.node_type
      v. Push frame onto stack
      vi. Follow child pointer: current_node = current_node.children[target_index]

3. **Reach Leaf**:
   a. current_node is now leaf node
   b. If start_key is None:
      - leaf_index = 0 if reverse, else leaf.entry_count - 1
   c. If start_key is Some:
      - Binary search for start_key in leaf
      - leaf_index = exact match or insertion point
   d. Create final stack frame for leaf
   e. Push frame onto stack

4. **Return Result**:
   a. Return (leaf.page_id, leaf_index, stack)

**Returns**: Leaf page ID, entry index, and traversal stack

**Error Conditions**:
- TreeCorrupt: Invalid node structure or parent pointers
- IOError: Pager I/O failure
- NotFound: Start key beyond all keys in tree

**Concurrency**: Read-only (safe for concurrent reads)

### Stack Update

**update_stack_for_next_leaf(iterator: BTreeIterator) -> Result<(), TraversalError>**

**Purpose**: Update traversal stack when moving to next leaf

**Algorithm**:
1. **Pop Current Leaf Frame**:
   a. Pop top frame from stack (current leaf)
   b. Verify popped frame.node_type == Leaf

2. **Backtrack to Parent**:
   a. New top of stack is parent internal node
   b. Read parent page from Pager

3. **Increment Parent Index**:
   a. Increment parent.frame.index by 1
   b. If parent.frame.index >= parent.entry_count:
      i. Continue backtracking (pop parent, repeat from step 1)
   c. If parent.frame.index < parent.entry_count:
      i. Follow child pointer to next leaf
      ii. Traverse down to leaf (push frames onto stack)
      iii. Return Ok(())

4. **Handle Stack Exhaustion**:
   a. If stack empty (reached root without finding next):
      i. No more leaves in tree
      ii. Return Err(TraversalError::NoNextLeaf)

**Returns**: Ok(()) on success, Err if no more leaves

**Error Conditions**:
- NoNextLeaf: Iterator at rightmost leaf
- TreeCorrupt: Stack inconsistent or tree structure invalid
- IOError: Pager I/O failure

**Concurrency**: Modifies iterator state (not thread-safe)

### Position Validation

**validate_position(iterator: BTreeIterator) -> Result<(), PositionError>**

**Purpose**: Validate current iterator position is consistent

**Algorithm**:
1. **Validate Current Page**:
   a. Read current_page_id from Pager
   b. Verify node is valid leaf (magic, checksum, type)

2. **Validate Current Index**:
   a. Check current_index within [0, leaf.entry_count)
   b. Return Err(PositionError::IndexOutOfRange) if invalid

3. **Validate Stack**:
   a. Verify stack not empty
   b. Verify stack height == tree_height
   c. For each frame:
      i. Verify page_id valid
      ii. Verify index within valid range for node
      iii. Verify parent-child consistency

4. **Validate Neighbors**:
   a. If prev_page_id is Some, verify prev.next_leaf == current_page_id
   b. If next_page_id is Some, verify next.prev_leaf == current_page_id

**Returns**: Ok(()) if position valid, Err if invalid

**Error Conditions**:
- IndexOutOfRange: current_index outside valid range
- InvalidPage: current_page_id invalid or corrupted
- StackCorrupt: Traversal stack inconsistent
- NeighborMismatch: Linked list pointers inconsistent

**Concurrency**: Read-only (safe to call during iteration)

## Invariants

### State Invariants

1. **State Validity**: Iterator always in one of defined states (Initialized, Active, Exhausted, Error)
2. **Monotonic Progress**: State transitions are unidirectional (Initialized → Active → Exhausted/Error)
3. **Terminal States**: Exhausted and Error are terminal (no further transitions)

### Position Invariants

1. **Valid Page**: current_page_id always points to valid leaf node (except Exhausted/Error)
2. **Valid Index**: current_index always within [0, leaf.entry_count) for Active state
3. **Consistent Neighbors**: prev_page_id and next_page_id form consistent linked list
4. **Within Range**: Current position always within scan range bounds

### Stack Invariants

1. **Path Completeness**: Stack contains path from root to current position
2. **Stack Height**: Stack size equals tree_height
3. **Parent-Child Consistency**: For consecutive frames, parent.children[frame[i].index] == frame[i+1].page_id
4. **Ordering**: Frames ordered from root (bottom) to leaf (top)

### Context Invariants

1. **Valid Range**: If both start_key and end_key specified, start_key <= end_key
2. **Valid Snapshot**: snapshot_lsn is valid committed LSN
3. **Immutable**: Context never changes after iterator creation
4. **Direction Consistency**: reverse flag matches iteration direction

## Dependencies

**Uses**:
- BTree structure: Root page ID, tree height
- Node structures: LeafNode, InternalNode, NodeHeader
- Search algorithms: Binary search within nodes
- Pager module: Read nodes, access page cache
- MVCC system: Snapshot LSN, version resolution
- Error types module: IOError, CorruptionError, TraversalError

**Used By**:
- Scan operations: Range scan iteration
- Database API: Public iterator interface
- Query execution: Result iteration for SQL queries
- Backup operations: Sequential data export
- Compaction operations: Tree rewriting

## Rust Implementation Guidance

### Module Structure

Iterator implementation should be in:
- `northstar_core::tree::iterator::BTreeIterator` - Main iterator struct
- `northstar_core::tree::iterator::IteratorState` - State enum
- `northstar_core::tree::iterator::IteratorPosition` - Position tracking
- `northstar_core::tree::iterator::TraversalStack` - Stack frames
- `northstar_core::tree::iterator::create_iterator()` - Factory function
- `northstar_core::tree::iterator::next()` - Forward iteration
- `northstar_core::tree::iterator::next_back()` - Reverse iteration

### Type Definitions

**IteratorState**: Use enum with variants:
```rust
pub enum IteratorState {
    Initialized,
    Active,
    Exhausted,
    Error(IteratorError),
}
```

**BTreeIterator**: Implement as struct with state and fields:
```rust
pub struct BTreeIterator {
    state: IteratorState,
    position: IteratorPosition,
    stack: Vec<StackFrame>,
    context: ScanContext,
    stats: ScanStats,
    yielded_count: usize,
}

impl Iterator for BTreeIterator {
    type Item = ScanResult;
    fn next(&mut self) -> Option<Self::Item>;
}
```

**TraversalStack**: Represent as Vec of stack frames:
```rust
pub struct TraversalStack(Vec<StackFrame>);

pub struct StackFrame {
    pub page_id: PageId,
    pub index: u16,
    pub node_type: NodeType,
}
```

### Key Decisions

**Iterator Trait**: Implement Rust Iterator trait for ergonomic usage. next() returns Option<ScanResult>. Also implement DoubleEndedIterator for next_back() support.

**State Machine**: Use enum for IteratorState. Match on state in next() to determine behavior. Transition states explicitly. No implicit state changes.

**Stack Representation**: Use Vec<StackFrame> for traversal stack. Push frames during traversal, pop during backtracking. Stack capacity = tree_height (pre-allocate for efficiency).

**Position Tracking**: Store current_page_id and current_index explicitly. Cache prev_page_id and next_page_id from leaf node for quick access. Update on leaf transitions.

**Error Handling**: Don't use Result in Iterator trait (not idiomatic). Transition to Error state on errors. Provide get_error() method to retrieve error after exhaustion.

**Visibility Checking**: Check MVCC visibility during iteration, not upfront. Skip invisible entries without yielding. Maintain snapshot consistency throughout scan.

**Reverse Iteration**: Implement next_back() for DoubleEndedIterator. Use prev_leaf pointers. Decrement index, handle underflow (wrap to previous leaf).

**Lazy Evaluation**: Read pages on-demand during iteration. Don't buffer results. Use Pager page cache to avoid re-reading.

**Clone Consideration**: Iterators are not cloneable (stateful). If clone needed, create new iterator at same position.

### Implementation Notes

1. **Stack Management**: Stack grows during traversal to leaf (push frames), shrinks during backtracking (pop frames). Keep stack size bounded by tree_height. Pre-allocate Vec capacity to tree_height for efficiency.

2. **Position Advancement**: For forward iteration, increment index. If index >= leaf.entry_count, move to next leaf. For reverse iteration, decrement index. If index wrapped (< 0), move to previous leaf.

3. **Leaf Transitions**: When moving between leaves:
   - Update current_page_id to next_leaf or prev_leaf
   - Reset current_index to 0 (forward) or leaf.entry_count - 1 (reverse)
   - Update stack: pop current leaf frame, backtrack to parent, descend to new leaf
   - Read new leaf from Pager (may be cached)

4. **Stack Updates**: On leaf transition:
   - Pop current leaf frame from stack
   - Backtrack to parent internal node
   - Increment/decrement parent index based on direction
   - Descend from parent to new leaf (push new frames)
   - Handle case where parent index also overflows (continue backtracking)

5. **Visibility and Filtering**: During iteration:
   - Check entry.lsn <= context.snapshot_lsn
   - If not visible, skip entry (advance and continue)
   - Check entry.is_deleted and context.skip_deleted
   - If deleted and skipping, skip entry (advance and continue)
   - Only yield if visible and not deleted (or not skipping deleted)

6. **Range Boundary Checks**:
   - Forward: Stop when current_key >= end_key (exclusive) or current_key > end_key (inclusive)
   - Reverse: Stop when current_key < end_key (exclusive) or current_key <= end_key (inclusive)
   - Unbounded: No boundary check (iterate to end of tree)

7. **Statistics Tracking**: Update stats in every operation:
   - entries_scanned: Increment on every entry visited
   - entries_returned: Increment on every entry yielded
   - pages_read: Increment on every unique page read from Pager
   - bytes_read: pages_read * PAGE_SIZE
   - scan_duration_ms: Calculate on exhaustion

8. **Error Recovery**: On error during iteration:
   - Store error in iterator.error field
   - Transition state to Error
   - Subsequent next() calls return None
   - Caller can call get_error() to retrieve error details
   - Don't panic or unwrap Results

9. **Max Results Limiting**: If context.max_results is Some(limit):
   - Check yielded_count < limit before yielding result
   - If yielded_count >= limit, transition to Exhausted
   - Return None (iterator exhausted early)

10. **Snapshot Isolation**: Iterator sees consistent snapshot at context.snapshot_lsn:
    - Even if concurrent commits modify keys in range, iterator unaffected
    - No blocking of concurrent writers
    - Iterator may see stale data but never inconsistent data

11. **Performance Optimizations**:
    - Pre-allocate stack Vec with capacity = tree_height
    - Use Pager page cache to avoid redundant I/O
    - Batch reads by prefetching next leaf during iteration
    - Avoid buffering results (yield immediately)
    - Use zero-copy reads where possible (reference page buffer)

### Testing Strategy

**Unit tests needed for**:
- Iterator creation (initialized state)
- State transitions (initialized → active → exhausted)
- Forward iteration (next())
- Reverse iteration (next_back())
- Stack building (traverse_to_leaf)
- Stack updates on leaf transitions
- Position validation (valid and invalid)
- Range boundary checks (start_key, end_key)
- Visibility filtering (snapshot_lsn)
- Deleted entry skipping (skip_deleted)
- Max results limiting
- Statistics tracking accuracy
- Error state transitions
- Empty range handling
- Single page iteration
- Multi-page iteration (leaf transitions)

**Property tests for**:
- State transitions are valid and monotonic
- Iterator never yields same entry twice
- Iterator yields entries in correct order
- All yielded entries visible to snapshot
- Stack always contains valid path from root to current position
- Position always within scan range
- Statistics match actual iteration behavior
- Forward and reverse iteration are inverses

**Integration scenarios**:
- Iterator with concurrent tree modifications
- Iterator during checkpoint (pages flushed)
- Iterator after tree growth (height increased)
- Iterator after tree shrink (height decreased)
- Multiple concurrent iterators (no interference)
- Long-running iterator across many pages
- Iterator with page cache hits and misses
- Iterator with corrupted page (error handling)

**Edge case tests**:
- Empty tree (no results)
- Single entry tree
- Range with no valid entries
- All entries deleted (skip_deleted true/false)
- All entries invisible to snapshot
- Iterator at exact start_key position
- Iterator with start_key beyond all keys
- Max results = 0 (empty)
- Reverse iteration on leftmost leaf
- Forward iteration on rightmost leaf

**Performance tests**:
- Measure iteration throughput (entries/second)
- Measure iteration latency per entry
- Compare cached vs uncached performance
- Benchmark stack update cost
- Test memory usage (stack + position)
- Verify iteration meets SLA requirements

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and iteration
- **06-btree-node.md**: Leaf node structure and linked list pointers
- **06-btree-search.md**: Search algorithms for positioning
- **06-btree-scan.md**: Range scan algorithm using iterator
- **05-snapshot-vis.md**: MVCC visibility calculation
- **04-txn-get.md**: Transaction integration with iterators
- **02-pager-read.md**: Pager page cache integration
