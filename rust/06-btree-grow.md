# B+Tree Growth (Root Split)

## Purpose

B+Tree growth occurs when the root node becomes overfull and must split, increasing the tree height by one level. This is the only operation that increases tree height in a B+Tree. The growth process maintains all B+Tree invariants while creating a new root node that points to the two halves of the split old root. This specification describes the complete tree growth algorithm, including root split mechanics, metadata updates, and integration with the Pager and WAL systems.

## Types

### TreeGrowthContext

**Description**: Context structure tracking state during tree growth operation

**Fields**:

1. **old_root_page_id** (PageId, 8 bytes)
   - **Purpose**: Page ID of the root node before split
   - **Value**: Valid page ID of current root
   - **Invariant**: Must be valid non-zero page ID

2. **old_root_height** (u16, 2 bytes)
   - **Purpose**: Tree height before growth operation
   - **Value**: Current tree height (0 = root is leaf, 1+ = root is internal)
   - **Invariant**: Must match current tree height

3. **new_root_page_id** (Option<PageId>, 8 bytes)
   - **Purpose**: Page ID of newly allocated root node
   - **Value**: Some(page_id) after allocation, None before allocation
   - **Invariant**: If set, must be valid non-zero page ID different from old_root

4. **sibling_page_id** (Option<PageId>, 8 bytes)
   - **Purpose**: Page ID of new sibling node created from split
   - **Value**: Some(page_id) after allocation, None before allocation
   - **Invariant**: If set, must be valid non-zero page ID different from both roots

5. **separator_key** (Option<Vec<u8>>, variable)
   - **Purpose**: Separator key promoted to new root
   - **Value**: Some(key_bytes) after split, None before split
   - **Invariant**: If set, must be valid key from split point

6. **new_height** (u16, 2 bytes)
   - **Purpose**: Tree height after growth completes
   - **Value**: old_height + 1
   - **Invariant**: Must be exactly old_height + 1

**Size**: Approximately 44 bytes (excluding variable-length separator_key)

### GrowthResult

**Description**: Result type returned by tree growth operation

**Variants**:

1. **GrowthSuccess**
   - **Fields**:
     - new_root_page_id: PageId - Page ID of new root node
     - new_height: u16 - Increased tree height
     - old_root_page_id: PageId - Page ID of split root (now child)
     - sibling_page_id: PageId - Page ID of new sibling node
     - separator_key: Vec<u8> - Separator key stored in new root
   - **Purpose**: Indicates successful tree growth with all relevant metadata

2. **GrowthAborted**
   - **Fields**: None
   - **Purpose**: Growth operation aborted (root not actually overfull)
   - **Note**: Occurs if concurrent operation already split root

3. **GrowthError
   - **Purpose**: Growth operation failed due to error condition

**Error Types**:

- **RootAlreadySplit**: Concurrent operation already split root
- **RootNotOverfull**: Root node does not meet split criteria
- **AllocationFailed**: Pager failed to allocate new root or sibling
- **InvalidRoot**: Root page ID is invalid or root corrupted
- **TreeCorrupt**: Tree structure inconsistency detected
- **IOError**: Disk I/O operation failed
- **WALAppendFailed**: Failed to write growth record to WAL

## Functions

### Tree Growth Entry Point

**grow_tree(tree: BTree, lsn: Lsn) -> Result<GrowthResult, GrowthError>**

**Purpose**: Increase tree height by splitting the root node

**Algorithm**:
1. **Pre-Growth Validation**:
   a. Read current root node from Pager using tree.root_page_id
   b. Validate root node structure (checksum, magic, invariants)
   c. Check if root is overfull (num_keys >= max_capacity)
   d. If root not overfull, return GrowthAborted (no growth needed)

2. **Allocate New Root**:
   a. Allocate new internal node from Pager (will become new root)
   b. If allocation fails, return AllocationFailed error
   c. Initialize new root as internal node with:
      - node_type: RootInternal (3)
      - is_root: true
      - num_keys: 1 (will contain separator)
      - level: old_root.level + 1 (increased height)
      - parent_page_id: 0 (root has no parent)

3. **Split Old Root**:
   a. Determine old root type (leaf or internal)
   b. If old root is leaf:
      i. Perform leaf node split (see split algorithms)
   c. If old root is internal:
      i. Perform internal node split (see split algorithms)
   d. Split creates:
      - Modified old_root (left half, entries [0, split_point))
      - New sibling node (right half, entries [split_point, num_keys))
      - Separator key for insertion into new root

4. **Update New Root**:
   a. Insert separator key into new root at index 0
   b. Set new root child pointers:
      - child[0] = old_root_page_id (left half)
      - child[1] = sibling_page_id (right half)
   c. Update new root metadata:
      - num_keys = 1
      - rightmost_child = sibling_page_id

5. **Update Child Parent Pointers**:
   a. Set old_root.parent_page_id = new_root_page_id
   b. Set sibling.parent_page_id = new_root_page_id
   c. Flush both child nodes to Pager

6. **Update Tree Metadata**:
   a. Write growth record to WAL with:
      - old_root_page_id
      - new_root_page_id
      - sibling_page_id
      - separator_key
      - old_height
      - new_height
      - current LSN
   b. Update database metadata:
      - Set root_page_id = new_root_page_id
      - Set tree_height = new_height
   c. Flush metadata to disk (fsync)

7. **Cleanup**:
   a. Mark old root as non-root (clear is_root flag)
   b. Recalculate checksums for all modified nodes
   c. Return GrowthSuccess with all relevant metadata

**Returns**: GrowthResult indicating success, abort, or error

**Error Conditions**:
- RootAlreadySplit: Concurrent modification detected
- RootNotOverfull: Growth criteria not met
- AllocationFailed: Pager allocation failure
- InvalidRoot: Root page ID invalid or corrupted
- TreeCorrupt: Structural invariant violation
- IOError: Disk I/O failure
- WALAppendFailed: WAL write failure

**Concurrency**: Single-writer (only write transaction can call grow_tree)

### Root Node Split

**split_root(tree: BTree, root: Node, split_point: usize) -> Result<(Node, Node, Vec<u8>), SplitError>**

**Purpose**: Split overfull root node into two nodes

**Algorithm**:
1. **Validate Split Conditions**:
   a. Verify root.num_keys >= max_capacity (overfull)
   b. Verify split_point in valid range [1, root.num_keys - 1]
   c. Calculate ideal split_point as ceil(root.num_keys / 2)

2. **Allocate Sibling Node**:
   a. Allocate new node from Pager with same type as root
   b. If allocation fails, return AllocationFailed error

3. **Redistribute Entries**:
   a. **If root is leaf node**:
      i. Move entries [split_point, root.num_keys) to sibling
      ii. Update sibling.next_leaf and sibling.prev_leaf
      iii. Update root.next_leaf = sibling.page_id
      iv. Update next node's prev_leaf = sibling.page_id (if exists)
   b. **If root is internal node**:
      i. Move separators [split_point, root.num_keys) to sibling
      ii. Move child pointers [split_point + 1, root.num_keys + 1) to sibling
      iii. Extract separator at split_point for promotion

4. **Update Entry Counts**:
   a. Set root.num_keys = split_point
   b. Set sibling.num_keys = root.num_keys - split_point

5. **Extract Separator**:
   a. **If root was leaf**: separator = first key in sibling
   b. **If root was internal**: separator = key at split_point (promoted separator)

6. **Update Node Headers**:
   a. Clear is_root flag in both nodes
   b. Update free_space calculations
   c. Increment generation counters
   d. Recalculate checksums

7. **Return Split Result**:
   a. Return (modified_root, new_sibling, separator_key)

**Returns**: Tuple of (left node, right node, separator_key)

**Error Conditions**:
- InvalidSplitPoint: split_point out of valid range
- AllocationFailed: Pager allocation failure
- NodeCorrupt: Root node structure invalid
- SplitFailed: Entry redistribution failed

**Concurrency**: Single-writer (root split serialized)

### Metadata Update

**update_tree_metadata(tree: BTree, new_root: PageId, new_height: u16, lsn: Lsn) -> Result<(), IOError>**

**Purpose**: Update database metadata with new root and height

**Algorithm**:
1. **Write WAL Record**:
   a. Create TreeGrowthRecord containing:
      - old_root_page_id
      - new_root_page_id
      - new_height
      - separator_key
      - lsn
   b. Append record to WAL
   c. If WAL append fails, return WALAppendFailed error
   d. Sync WAL to disk (fsync)

2. **Update In-Memory Metadata**:
   a. Set tree.root_page_id = new_root
   b. Set tree.height = new_height

3. **Flush to Disk**:
   a. Write updated database header to disk
   b. Sync database file (fsync)
   c. If flush fails, return IOError

**Returns**: Ok(()) on success, Err on failure

**Error Conditions**:
- WALAppendFailed: Failed to write growth record to WAL
- IOError: Disk I/O failure during flush

**Concurrency**: Single-writer (metadata update serialized)

## Invariants

### Pre-Growth Invariants

1. **Root Validity**: old_root_page_id must point to valid node
2. **Root Overfull**: Root node must have num_keys >= max_capacity
3. **Tree Consistency**: All non-root nodes must satisfy minimum occupancy
4. **Height Correct**: old_root_height must match actual tree height
5. **Metadata Consistency**: Database metadata must match actual root and height

### Post-Growth Invariants

1. **New Root Valid**: new_root_page_id must point to valid internal node
2. **Root Type**: New root must be internal node with is_root flag set
3. **Root Entry Count**: New root must have exactly 1 entry (separator key)
4. **Height Increased**: new_height must equal old_height + 1
5. **Child Pointers**: New root must have exactly 2 children (old root and sibling)
6. **Parent Pointers**: Both children must have parent_page_id = new_root_page_id
7. **Split Validity**: Old root and sibling entries must partition original root entries
8. **Separator Correct**: Separator in new root must divide key space correctly
9. **Non-Root Flags**: Old root and sibling must have is_root flag cleared
10. **Tree Balance**: All leaves must remain at same depth (new_height)

### Operational Invariants

**During Growth**:
- Only one growth operation can occur at a time (serialized)
- No concurrent modifications to root during split
- WAL must record growth before metadata flush
- All modified nodes must be flushed before metadata update

**After Growth**:
- All B+Tree structural invariants must hold
- All nodes must have valid checksums
- All parent pointers must be consistent
- All leaf linked list pointers must be consistent (if applicable)
- Metadata must match actual tree state

## Dependencies

**Uses**:
- Pager module: Allocate new nodes, read/write nodes, flush pages
- WAL module: Record growth operation for crash recovery
- Node structures: InternalNode, LeafNode, NodeHeader
- Split algorithms: leaf_split(), internal_split()
- Error types module: GrowthError, SplitError, IOError

**Used By**:
- Insert operation: Triggers growth when root overfull
- Recovery operation: Replays growth records from WAL
- Verification operation: Validates tree growth invariants

## Rust Implementation Guidance

### Module Structure

Tree growth implementation should be in:
- `northstar_core::tree::growth::grow_tree()` - Main growth entry point
- `northstar_core::tree::growth::split_root()` - Root split algorithm
- `northstar_core::tree::growth::update_metadata()` - Metadata update
- `northstar_core::tree::growth::TreeGrowthContext` - Growth context
- `northstar_core::tree::growth::GrowthResult` - Result type

### Type Definitions

**TreeGrowthContext**: Represent as struct with all context fields:
```rust
pub struct TreeGrowthContext {
    pub old_root_page_id: PageId,
    pub old_root_height: u16,
    pub new_root_page_id: Option<PageId>,
    pub sibling_page_id: Option<PageId>,
    pub separator_key: Option<Vec<u8>>,
    pub new_height: u16,
}
```

**GrowthResult**: Use enum with variants for success, abort, error:
```rust
pub enum GrowthResult {
    GrowthSuccess {
        new_root_page_id: PageId,
        new_height: u16,
        old_root_page_id: PageId,
        sibling_page_id: PageId,
        separator_key: Vec<u8>,
    },
    GrowthAborted,
    GrowthError(GrowthError),
}
```

### Key Decisions

**Error Handling Strategy**: Use Result type with comprehensive GrowthError enum. Prefer returning errors over panicking. Validate all preconditions before modifying state.

**WAL Integration**: Write growth record to WAL before updating metadata. This ensures crash recovery can either complete or rollback the growth operation.

**Allocation Order**: Allocate new root before splitting old root. If allocation fails, no changes have been made yet. If split fails, already allocated new root can be freed.

**Concurrent Growth Detection**: Check root split condition (overfull) while holding write lock. If root already split by concurrent operation, abort and return GrowthAborted.

**Metadata Update Order**: Always WAL → metadata flush → node flush. This order ensures crash recovery can reconstruct consistent state.

**Checksum Updates**: Recalculate checksums for all modified nodes after split completes, but before flushing to disk.

**Parent Pointer Updates**: Update parent pointers in children after new root is allocated and initialized, but before metadata update.

### Implementation Notes

1. **Root Overflow Detection**: Check root overfull condition during insert before attempting split. Root can grow even when non-root nodes cannot split (root has no minimum occupancy requirement).

2. **Split Point Calculation**: For root split, use ceil(num_keys / 2) to ensure balanced split. For leaf root, first key in sibling becomes separator. For internal root, key at split_point is promoted separator.

3. **Height Tracking**: Increment height by 1 on every growth operation. Store height in database metadata and in-memory tree state. Validate height matches actual tree depth during verification.

4. **Leaf Root Growth**: When leaf root splits, tree grows from height 0 to height 1. New root is internal node with 2 leaf children.

5. **Internal Root Growth**: When internal root splits, tree grows from height H to height H+1. New root is internal node with 2 internal children.

6. **Metadata Persistence**: Database metadata includes root_page_id and tree_height. These fields are read on database open and updated on every growth or shrink operation.

7. **Crash Recovery**: If crash occurs during growth, recovery must:
   - Read WAL for TreeGrowthRecord
   - If WAL record present: complete growth (allocate nodes if needed, update metadata)
   - If WAL record absent: verify tree state, rollback partial growth if detected

8. **Verification**: After growth completes, verify:
   - New root is internal node with is_root flag
   - New root has exactly 1 entry (separator)
   - Both children exist and have correct parent pointers
   - Tree height increased by exactly 1
   - All leaves at same depth

9. **Error Recovery**: If any step fails:
   - If allocation fails: no state changed, safe to return error
   - If split fails: free allocated new root, return error
   - If WAL append fails: free allocated nodes, return error
   - If metadata flush fails: recovery will complete from WAL

10. **Performance Considerations**:
    - Root split is rare (O(log N) times over N insertions)
    - Split cost dominated by node allocation and I/O
    - Use buffer pool to cache frequently accessed root nodes
    - Consider allocating sibling and new root in parallel if Pager supports it

### Testing Strategy

**Unit tests needed for**:
- Tree growth from empty tree (first insert)
- Tree growth from single-node tree (leaf root split)
- Tree growth from multi-level tree (internal root split)
- Root split at various occupancy levels
- Split point calculation correctness
- Separator key extraction (leaf vs internal root)
- Parent pointer updates after growth
- Metadata updates (root_page_id, tree_height)
- Checksum recalculation after split
- Growth abort when root not overfull
- Concurrent growth detection and abort
- Error handling at each growth step

**Property tests for**:
- Growth always increases height by exactly 1
- New root always has exactly 1 entry
- Both children always valid and correctly linked
- All tree invariants preserved after growth
- Metadata matches actual tree state after growth
- Growth is idempotent when replayed from WAL
- Concurrent growth operations serialize correctly

**Integration scenarios**:
- Insert causing leaf root to split (tree height 0 → 1)
- Insert causing internal root to split (tree height H → H+1)
- Multiple sequential growth operations (height 0 → 1 → 2 → 3)
- Growth followed by verification operation
- Growth followed by crash and recovery
- Growth with concurrent read transactions (readers unaffected)
- Growth during long-running write transaction

**Crash recovery tests**:
- Crash after new root allocation, before split
- Crash after split, before WAL append
- Crash after WAL append, before metadata flush
- Crash after metadata flush, before node flush
- Verify recovery completes or rolls back correctly for each case

**Performance tests**:
- Measure growth operation latency at various tree sizes
- Benchmark root split cost for different node sizes
- Verify growth latency acceptable for target workload
- Test growth frequency under insert-heavy workload

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and growth triggers
- **06-btree-node.md**: Root node structure and properties
- **06-btree-header.md**: Node header fields (is_root flag, level, parent_page_id)
- **06-btree-split.md**: Detailed split algorithms for leaf and internal nodes
- **06-btree-shrink.md**: Tree shrink (inverse operation, root merge)
- **02-pager-alloc.md**: Pager node allocation for new root and sibling
- **03-wal-append.md**: WAL append for growth record persistence
- **04-txn-commit.md**: Transaction commit integrating with tree growth
