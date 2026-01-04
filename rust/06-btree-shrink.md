# B+Tree Shrink (Root Merge)

## Purpose

B+Tree shrink occurs when the root node has only one child and can be merged with that child, decreasing the tree height by one level. This is the only operation that decreases tree height in a B+Tree. The shrink process maintains all B+Tree invariants while removing the root node and promoting its sole child to become the new root. This specification describes the complete tree shrink algorithm, including root merge mechanics, metadata updates, and integration with the Pager and WAL systems.

## Types

### TreeShrinkContext

**Description**: Context structure tracking state during tree shrink operation

**Fields**:

1. **old_root_page_id** (PageId, 8 bytes)
   - **Purpose**: Page ID of the root node before merge
   - **Value**: Valid page ID of current root
   - **Invariant**: Must be valid non-zero page ID

2. **old_root_height** (u16, 2 bytes)
   - **Purpose**: Tree height before shrink operation
   - **Value**: Current tree height (1+ = root is internal with one child)
   - **Invariant**: Must be >= 1 (tree with height 0 cannot shrink)

3. **new_root_page_id** (Option<PageId>, 8 bytes)
   - **Purpose**: Page ID of child node promoted to root
   - **Value**: Some(page_id) after promotion, None before promotion
   - **Invariant**: If set, must be valid non-zero page ID different from old_root

4. **old_root_child_count** (u16, 2 bytes)
   - **Purpose**: Number of children in old root before shrink
   - **Value**: Must be 1 for shrink to proceed
   - **Invariant**: Must equal 1 for shrink to be valid

5. **separator_removed** (bool, 1 byte)
   - **Purpose**: Whether separator key was removed from old root
   - **Value**: true after merge, false before merge
   - **Invariant**: Must be true after successful shrink

6. **new_height** (u16, 2 bytes)
   - **Purpose**: Tree height after shrink completes
   - **Value**: old_height - 1
   - **Invariant**: Must be exactly old_height - 1

**Size**: Approximately 35 bytes

### ShrinkResult

**Description**: Result type returned by tree shrink operation

**Variants**:

1. **ShrinkSuccess**
   - **Fields**:
     - old_root_page_id: PageId - Page ID of removed root
     - new_root_page_id: PageId - Page ID of promoted child (new root)
     - new_height: u16 - Decreased tree height
     - freed_page_id: PageId - Page ID of root node freed to Pager
   - **Purpose**: Indicates successful tree shrink with all relevant metadata

2. **ShrinkAborted**
   - **Fields**: None
   - **Purpose**: Shrink operation aborted (root has more than one child)
   - **Note**: Occurs if root has 2+ children or root is leaf node

3. **ShrinkError
   - **Purpose**: Shrink operation failed due to error condition

**Error Types**:

- **RootNotInternal**: Root is leaf node (cannot shrink height 0 tree)
- **RootHasMultipleChildren**: Root has 2+ children (cannot shrink)
- **InvalidChild**: Sole child page ID is invalid or corrupted
- **PromotionFailed**: Failed to promote child to root
- **TreeCorrupt**: Tree structure inconsistency detected
- **IOError**: Disk I/O operation failed
- **WALAppendFailed**: Failed to write shrink record to WAL
- **FreeFailed**: Failed to free old root page to Pager

## Functions

### Tree Shrink Entry Point

**shrink_tree(tree: BTree, lsn: Lsn) -> Result<ShrinkResult, ShrinkError>**

**Purpose**: Decrease tree height by merging root with its sole child

**Algorithm**:
1. **Pre-Shrink Validation**:
   a. Read current root node from Pager using tree.root_page_id
   b. Validate root node structure (checksum, magic, invariants)
   c. Check if root is internal node (node_type = Internal or RootInternal)
   d. If root is leaf node, return ShrinkAborted (height 0 tree cannot shrink)
   e. Check root child count (num_keys + 1 = 2 for root with 1 child)
   f. If root has more than 1 child, return ShrinkAborted

2. **Identify Child to Promote**:
   a. Root has exactly one child at index 0
   b. Read child_page_id from root.children[0]
   c. Validate child_page_id is valid non-zero page ID
   d. If child_page_id invalid, return InvalidChild error

3. **Read Child Node**:
   a. Read child node from Pager using child_page_id
   b. Validate child node structure (checksum, magic, invariants)
   c. Verify child.parent_page_id == old_root_page_id
   d. If validation fails, return TreeCorrupt error

4. **Promote Child to Root**:
   a. **Update child node type**:
      i. If child was Internal: set node_type = RootInternal (3)
      ii. If child was Leaf: set node_type = RootLeaf (4)
   b. **Update child node flags**:
      i. Set is_root flag to true
      ii. Clear parent_page_id to 0 (root has no parent)
      iii. Clear underfull flag (root can violate occupancy rules)
   c. **Update child node level**:
      i. If child was internal: decrement level by 1
      ii. If child was leaf: level remains 0
   d. **Update child node metadata**:
      i. Increment generation counter
      ii. Recalculate checksum

5. **Write WAL Record**:
   a. Create TreeShrinkRecord containing:
      - old_root_page_id
      - new_root_page_id (child_page_id)
      - old_height
      - new_height (old_height - 1)
      - removed_separator (if internal root)
      - current LSN
   b. Append record to WAL
   c. If WAL append fails, return WALAppendFailed error
   d. Sync WAL to disk (fsync)

6. **Update Tree Metadata**:
   a. Update in-memory tree state:
      - Set tree.root_page_id = child_page_id
      - Set tree.height = old_height - 1
   b. Write updated database metadata to disk:
      - Set root_page_id = child_page_id
      - Set tree_height = new_height
   c. Sync database file (fsync)
   d. If flush fails, return IOError

7. **Free Old Root**:
   a. Flush promoted child (new root) to Pager
   b. Free old_root_page_id to Pager free list
   c. If free fails, log error but operation succeeds (space leak acceptable)
   d. Mark old root as deleted in memory

8. **Return Success**:
   a. Return ShrinkSuccess with:
      - old_root_page_id
      - new_root_page_id (child_page_id)
      - new_height (old_height - 1)
      - freed_page_id (old_root_page_id)

**Returns**: ShrinkResult indicating success, abort, or error

**Error Conditions**:
- RootNotInternal: Root is leaf node (height 0)
- RootHasMultipleChildren: Root has 2+ children
- InvalidChild: Child page ID invalid or child corrupted
- PromotionFailed: Child promotion to root failed
- TreeCorrupt: Structural invariant violation
- IOError: Disk I/O failure
- WALAppendFailed: WAL write failure
- FreeFailed: Pager free failed (non-fatal)

**Concurrency**: Single-writer (only write transaction can call shrink_tree)

### Root Merge Validation

**can_shrink_root(tree: BTree) -> bool**

**Purpose**: Check if root can be merged with child (shrink criteria)

**Algorithm**:
1. Read root node from Pager
2. Check if root is internal node (not leaf)
3. Check root child count: if num_keys + 1 == 2 (exactly one child)
4. Return true if all conditions met, false otherwise

**Returns**: true if shrink can proceed, false otherwise

**Error Conditions**: None (validation-only function)

**Concurrency**: Read-only (safe to call concurrently)

### Child Promotion

**promote_child_to_root(tree: BTree, child: Node, old_root_page_id: PageId) -> Result<Node, PromotionError>**

**Purpose**: Promote child node to become new root

**Algorithm**:
1. **Update Node Type**:
   a. If child.node_type == Internal: set to RootInternal
   b. If child.node_type == Leaf: set to RootLeaf
   c. Update is_root flag to true

2. **Clear Parent Reference**:
   a. Set child.parent_page_id = 0 (root has no parent)
   b. Clear underfull flag (root can be empty)

3. **Update Level Field**:
   a. If child is internal node: decrement child.level by 1
   b. If child is leaf node: level unchanged (remains 0)

4. **Update Metadata**:
   a. Increment child.header.generation by 1
   b. Set dirty flag in child.header.flags
   c. Recalculate checksum with updated fields

5. **Flush to Pager**:
   a. Write modified child node to Pager page cache
   b. Mark page as dirty for eventual flush to disk

6. **Return Promoted Node**:
   a. Return modified child node as new root

**Returns**: Promoted child node with root flags set

**Error Conditions**:
- InvalidNodeType: Child node type is invalid
- PromotionFailed: Failed to update node flags or metadata

**Concurrency**: Single-writer (promotion serialized)

### Metadata Update

**update_metadata_for_shrink(tree: BTree, new_root: PageId, new_height: u16, lsn: Lsn) -> Result<(), IOError>**

**Purpose**: Update database metadata after tree shrink

**Algorithm**:
1. **Update In-Memory State**:
   a. Set tree.root_page_id = new_root
   b. Set tree.height = new_height
   c. Verify new_height == old_height - 1

2. **Write to Disk**:
   a. Update database header fields:
      - root_page_id = new_root
      - tree_height = new_height
   b. Write database header to disk at offset 0
   c. Sync database file (fsync)
   d. If write or sync fails, return IOError

**Returns**: Ok(()) on success, Err on failure

**Error Conditions**:
- IOError: Disk I/O failure during write or sync

**Concurrency**: Single-writer (metadata update serialized)

## Invariants

### Pre-Shrink Invariants

1. **Root Validity**: old_root_page_id must point to valid internal node
2. **Root Type**: Root must be internal node (not leaf)
3. **Root Child Count**: Root must have exactly 1 child (num_keys + 1 == 2)
4. **Child Validity**: Sole child must be valid node with correct parent pointer
5. **Tree Height**: Tree height must be >= 1 (height 0 cannot shrink)
6. **Tree Consistency**: All non-root nodes must satisfy minimum occupancy
7. **Metadata Consistency**: Database metadata must match actual root and height

### Post-Shrink Invariants

1. **New Root Valid**: new_root_page_id must point to valid node
2. **New Root Type**: New root must have is_root flag set
3. **New Root Parent**: New root must have parent_page_id = 0
4. **Height Decreased**: new_height must equal old_height - 1
5. **Childless Old Root**: Old root must be freed to Pager
6. **Metadata Consistency**: Database metadata must match new root and height
7. **Tree Balance**: All leaves must remain at same depth (new_height)
8. **Root Can Be Empty**: New root may have 0 entries (valid for root)
9. **No Orphaned Nodes**: All nodes must be reachable from new root
10. **Checksums Valid**: All modified nodes must have valid checksums

### Operational Invariants

**During Shrink**:
- Only one shrink operation can occur at a time (serialized)
- No concurrent modifications to root during merge
- WAL must record shrink before metadata flush
- Old root must be freed after new root is durable

**After Shrink**:
- All B+Tree structural invariants must hold
- All nodes must have valid checksums
- All parent pointers must be consistent (new root has none)
- All leaf linked list pointers must be consistent (unchanged)
- Metadata must match actual tree state
- Old root page ID must not be accessible from any node

## Dependencies

**Uses**:
- Pager module: Read/write nodes, free old root page, flush pages
- WAL module: Record shrink operation for crash recovery
- Node structures: InternalNode, LeafNode, NodeHeader
- Error types module: ShrinkError, PromotionError, IOError

**Used By**:
- Delete operation: Triggers shrink when root has one child
- Recovery operation: Replays shrink records from WAL
- Verification operation: Validates tree shrink invariants
- Maintenance operation: Shrinks tree after bulk deletes

## Rust Implementation Guidance

### Module Structure

Tree shrink implementation should be in:
- `northstar_core::tree::shrink::shrink_tree()` - Main shrink entry point
- `northstar_core::tree::shrink::can_shrink_root()` - Shrink criteria check
- `northstar_core::tree::shrink::promote_child_to_root()` - Child promotion
- `northstar_core::tree::shrink::update_metadata()` - Metadata update
- `northstar_core::tree::shrink::TreeShrinkContext` - Shrink context
- `northstar_core::tree::shrink::ShrinkResult` - Result type

### Type Definitions

**TreeShrinkContext**: Represent as struct with all context fields:
```rust
pub struct TreeShrinkContext {
    pub old_root_page_id: PageId,
    pub old_root_height: u16,
    pub new_root_page_id: Option<PageId>,
    pub old_root_child_count: u16,
    pub separator_removed: bool,
    pub new_height: u16,
}
```

**ShrinkResult**: Use enum with variants for success, abort, error:
```rust
pub enum ShrinkResult {
    ShrinkSuccess {
        old_root_page_id: PageId,
        new_root_page_id: PageId,
        new_height: u16,
        freed_page_id: PageId,
    },
    ShrinkAborted,
    ShrinkError(ShrinkError),
}
```

### Key Decisions

**Error Handling Strategy**: Use Result type with comprehensive ShrinkError enum. Prefer returning errors over panicking. Validate all preconditions before modifying state. Free operation failure is non-fatal (acceptable space leak).

**WAL Integration**: Write shrink record to WAL before updating metadata. This ensures crash recovery can either complete or rollback the shrink operation. WAL record must include all information needed to replay shrink.

**Promotion Order**: Update child node metadata (flags, parent pointer, level) before updating database metadata. If promotion fails, no state has changed yet.

**Metadata Update Order**: Always WAL → metadata flush → node flush → free old root. This order ensures crash recovery can reconstruct consistent state.

**Concurrency with Growth**: Growth and shrink operations are mutually exclusive (only one can occur at a time). Shrink checks root child count, growth checks root entry count.

**Root Minimum Occupancy**: Root is allowed to violate minimum occupancy rules. After shrink, new root may have very few entries (even 0 in extreme case). This is valid and expected.

**Leaf Root Consideration**: If root is leaf node (height 0), shrink cannot proceed. This occurs when tree has very few keys (less than fanout). Delete operations should handle this case gracefully.

**Shrink Triggers**: Shrink is typically triggered after delete operations that remove the last separator from root. Check shrink condition after every delete that removes an entry from root.

### Implementation Notes

1. **Shrink Criteria Check**: Before attempting shrink, verify:
   - Root is internal node (height >= 1)
   - Root has exactly 1 child (num_keys + 1 == 2)
   - Child node is valid and has correct parent pointer

2. **Child Promotion Details**: When promoting child to root:
   - If child was internal node: clear parent pointer, decrement level
   - If child was leaf node: clear parent pointer, level unchanged (0)
   - Always set is_root flag and clear underfull flag
   - Update node type to RootInternal or RootLeaf

3. **Height Tracking**: Decrement height by 1 on every shrink operation. Store height in database metadata and in-memory tree state. Validate height matches actual tree depth during verification.

4. **Metadata Persistence**: Database metadata includes root_page_id and tree_height. These fields are updated atomically (single write + fsync). After crash, recovery replays WAL to ensure consistency.

5. **Crash Recovery**: If crash occurs during shrink, recovery must:
   - Read WAL for TreeShrinkRecord
   - If WAL record present: complete shrink (promote child if needed, update metadata)
   - If WAL record absent: verify tree state, detect and complete partial shrink if needed
   - Free old root page if not already freed

6. **Verification**: After shrink completes, verify:
   - New root has is_root flag set
   - New root has parent_page_id = 0
   - Tree height decreased by exactly 1
   - All nodes reachable from new root
   - All leaves at same depth (new_height)
   - Old root page ID not referenced anywhere

7. **Error Recovery**: If any step fails:
   - If validation fails: no state changed, safe to return error
   - If promotion fails: no state changed, safe to return error
   - If WAL append fails: no state changed, safe to return error
   - If metadata flush fails: recovery will complete from WAL
   - If free fails: operation succeeds, space leak acceptable

8. **Interaction with Merge**: Shrink is distinct from node merge. Merge combines two underfull sibling nodes. Shrinking removes root with single child. Both reduce tree height but operate at different levels.

9. **Performance Considerations**:
   - Root shrink is rare (occurs after bulk deletes)
   - Shrink cost dominated by metadata I/O (single write + fsync)
   - Child promotion is in-memory operation (flags updated, checksum recalculated)
   - Consider coalescing multiple shrink opportunities (unlikely in practice)

10. **Edge Cases**:
    - **Empty tree after shrink**: If all keys deleted, new root may be empty leaf node. This is valid state.
    - **Shrink to height 0**: Tree with internal root and single leaf child shrinks to height 0 (leaf becomes root).
    - **Concurrent deletes**: Multiple deletes may attempt shrink simultaneously. Only one should proceed (serialized by write lock).

### Testing Strategy

**Unit tests needed for**:
- Tree shrink from height 1 to height 0 (internal root → leaf root)
- Tree shrink from height 2+ (internal root → internal root)
- Shrink abort when root has multiple children
- Shrink abort when root is leaf node (height 0)
- Child promotion for internal nodes
- Child promotion for leaf nodes
- Parent pointer updates after promotion
- Level field updates after promotion
- Metadata updates (root_page_id, tree_height)
- Checksum recalculation after promotion
- Old root page freed to Pager
- Shrink with empty child node (edge case)
- Error handling at each shrink step

**Property tests for**:
- Shrink always decreases height by exactly 1
- New root always has is_root flag set
- New root always has parent_page_id = 0
- All tree invariants preserved after shrink
- Metadata matches actual tree state after shrink
- Old root page ID not referenced after shrink
- Shrink is idempotent when replayed from WAL
- Shrink followed by growth returns to original state

**Integration scenarios**:
- Delete causing root to have one child (trigger shrink)
- Multiple sequential deletes causing multiple shrinks
- Shrink followed by verification operation
- Shrink followed by crash and recovery
- Shrink with concurrent read transactions (readers see old root until commit)
- Shrink during long-running write transaction
- Bulk delete causing height reduction (e.g., 3 → 2 → 1)

**Crash recovery tests**:
- Crash after promotion, before WAL append
- Crash after WAL append, before metadata flush
- Crash after metadata flush, before old root free
- Crash after old root free (operation complete)
- Verify recovery completes or rolls back correctly for each case

**Performance tests**:
- Measure shrink operation latency
- Benchmark shrink cost for various tree sizes
- Verify shrink latency acceptable for target workload
- Test shrink frequency under delete-heavy workload

**Stress tests**:
- Repeated grow-shrink cycles (insert to grow, delete to shrink)
- Concurrent deletes with shrink opportunities
- Shrink with very large trees (height 5+)
- Shrink with corrupted tree state (error handling)

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and shrink triggers
- **06-btree-node.md**: Root node structure and properties
- **06-btree-header.md**: Node header fields (is_root flag, level, parent_page_id)
- **06-btree-merge.md**: Node merge algorithms (different from root shrink)
- **06-btree-grow.md**: Tree growth (inverse operation, root split)
- **06-btree-delete.md**: Delete operations that may trigger shrink
- **02-pager-alloc.md**: Pager free list for old root deallocation
- **03-wal-append.md**: WAL append for shrink record persistence
- **04-txn-commit.md**: Transaction commit integrating with tree shrink
