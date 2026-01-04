# B+Tree Node Structures

## Purpose

B+Tree nodes are the fundamental building blocks of the B+Tree index structure. Each node occupies exactly one database page (16KB) and contains either index routing information (internal nodes) or actual key-value data (leaf nodes). This specification defines the precise structure, layout, and behavior of both internal and leaf node types, ensuring consistent implementation across the Rust codebase and maintaining binary compatibility with the on-disk format.

## Types

### NodeHeader

**Description**: Common metadata structure that appears at the start of every B+Tree node regardless of type. Provides identification, validation, and state information needed to interpret the node contents correctly.

**Size**: Exactly 32 bytes (fixed, must match for all node types)

**Alignment**: 8-byte aligned for efficient access on 64-bit architectures

**Fields**:

1. **magic** (u32, 4 bytes)
   - **Offset**: 0
   - **Purpose**: Node identification magic number
   - **Value**: 0x4E534442 (ASCII "NSDB") - same as page magic
   - **Validation**: Must equal this exact value or node is invalid
   - **Byte Order**: Little endian

2. **node_type** (u8, 1 byte)
   - **Offset**: 4
   - **Purpose**: Distinguishes internal nodes from leaf nodes
   - **Values**:
     - 1: Internal node (branch node with child pointers)
     - 2: Leaf node (contains key-value pairs)
   - **Byte Order**: Little endian (effectively N/A for 1 byte)

3. **flags** (u8, 1 byte)
   - **Offset**: 5
   - **Purpose**: Node state flags for optimization and tracking
   - **Bit Fields**:
     - Bit 0 (0x01): Dirty flag - node modified since last flush
     - Bit 1 (0x02): Underfull flag - node below minimum occupancy
     - Bit 2 (0x04): Overflow flag - node has overflow pages
     - Bits 3-7: Reserved for future use (must be 0)
   - **Byte Order**: Little endian (effectively N/A for 1 byte)

4. **entry_count** (u16, 2 bytes)
   - **Offset**: 6
   - **Purpose**: Number of entries currently stored in the node
   - **Internal Nodes**: Number of separator keys (child pointers = entry_count + 1)
   - **Leaf Nodes**: Number of key-value pairs
   - **Valid Range**: 0 to max_entry_count (depends on node type and key/value sizes)
   - **Byte Order**: Little endian

5. **rightmost_child** (u64, 8 bytes)
   - **Offset**: 8
   - **Purpose**: Page ID of the rightmost child pointer (internal nodes only)
   - **Internal Nodes**: Always valid (points to last child)
   - **Leaf Nodes**: Set to 0 (not used for leaf nodes)
   - **Byte Order**: Little endian

6. **next_leaf** (u64, 8 bytes)
   - **Offset**: 16
   - **Purpose**: Page ID of next leaf node in key order
   - **Leaf Nodes**: Valid pointer (0 if this is rightmost leaf)
   - **Internal Nodes**: Set to 0 (not used for internal nodes)
   - **Byte Order**: Little endian

7. **prev_leaf** (u64, 8 bytes)
   - **Offset**: 24
   - **Purpose**: Page ID of previous leaf node in key order
   - **Leaf Nodes**: Valid pointer (0 if this is leftmost leaf)
   - **Internal Nodes**: Set to 0 (not used for internal nodes)
   - **Byte Order**: Little endian

**Invariants**:
- magic must always equal 0x4E534442
- node_type must be either 1 (internal) or 2 (leaf)
- entry_count must be within valid range for the node type
- For internal nodes: rightmost_child must be non-zero (except root)
- For leaf nodes: next_leaf and prev_leaf must form consistent linked list
- If entry_count is 0, node is empty and should be recycled

### InternalNode

**Description**: Branch node that stores separator keys and child page pointers, forming the upper levels of the B+Tree. Internal nodes do not store actual data values, only routing information to guide searches to the correct leaf node.

**Total Size**: Exactly 16384 bytes (one page, including NodeHeader)

**Structure**:
- **NodeHeader**: Fixed-size header (first 32 bytes)
- **Separator Array**: Variable-length array of separator keys
- **Child Pointer Array**: Variable-length array of child page IDs
- **Free Space**: Remaining bytes for future insertions

**Capacity**:
- Maximum entries depends on key size and page size
- Formula: max_entries = floor((page_size - header_size) / (key_size + child_ptr_size))
- For 8-byte keys: max_entries = floor(16352 / 16) = 1022 entries
- For variable-length keys: approximate, based on average key size
- Minimum entries (except root): ceil(max_entries / 2)

**Separator Array**:
- **Purpose**: Array of key values that divide the key space between children
- **Element Type**: Variable-length byte array (key)
- **Element Format**: [length (u8)] [key_bytes (0-255 bytes)]
- **Ordering**: Strictly increasing (separator[i] < separator[i+1])
- **Position**: Starts immediately after NodeHeader (offset 32)
- **Size**: entry_count * (1 + average_key_length) bytes

**Child Pointer Array**:
- **Purpose**: Array of page IDs pointing to child nodes
- **Element Type**: u64 (PageId)
- **Element Size**: Exactly 8 bytes per pointer
- **Count**: entry_count + 1 (one more than separators)
- **Position**: Starts after Separator Array (variable offset)
- **Size**: (entry_count + 1) * 8 bytes

**Search Property**: For any separator key at index i:
- All keys in child[i] < separator[i]
- All keys in child[i+1] >= separator[i]
- The rightmost child (child[entry_count]) is accessed via rightmost_child field

**Invariants**:
- entry_count between 0 and max_entries
- entry_count >= minimum_entries (except root)
- Separator keys in strictly increasing order
- Child pointers point to valid B+Tree nodes (internal or leaf)
- All children at same depth (balance invariant)
- Total space used must not exceed page size

**Binary Layout**:
```
Offset  Size              Field              Description
------  ----              -----              -----------
0       4                 magic              0x4E534442 ("NSDB")
4       1                 node_type          1 (internal)
5       1                 flags              Node state flags
6       2                 entry_count        Number of separators
8       8                 rightmost_child    Rightmost child page ID
16      8                 next_leaf          0 (unused)
24      8                 prev_leaf          0 (unused)
--      --                --                 --
32      variable          separators[]       Separator key array
32+N    variable          children[]         Child pointer array
--      --                --                 --
Total: 16384 bytes                           One page
```

### LeafNode

**Description**: Data node that stores actual key-value pairs. Leaf nodes form the bottom level of the B+Tree and are linked together in a doubly-linked list to support efficient range scans.

**Total Size**: Exactly 16384 bytes (one page, including NodeHeader)

**Structure**:
- **NodeHeader**: Fixed-size header (first 32 bytes)
- **Entry Array**: Variable-length array of key-value entries
- **Free Space**: Remaining bytes for future insertions

**Capacity**:
- Maximum entries depends on key and value sizes
- Formula: max_entries = floor((page_size - header_size) / avg_entry_size)
- Where avg_entry_size = key_length + value_length + lsn_size (8 bytes)
- For 8-byte keys and 8-byte values: max_entries = floor(16352 / 24) = 681 entries
- For variable-length keys/values: approximate, based on average sizes
- Minimum entries (except root): ceil(max_entries / 2)

**Entry Array**:
- **Purpose**: Array of key-value pairs with MVCC versioning
- **Element Type**: Struct containing key, value, and LSN
- **Element Format**:
  - Key: [length (u8)] [key_bytes (0-255 bytes)]
  - Value: [length (u16)] [value_bytes (0-65535 bytes)] or overflow_page_id (u64)
  - LSN: u64 (8 bytes, log sequence number)
- **Ordering**: Strictly increasing by key
- **Position**: Starts immediately after NodeHeader (offset 32)
- **Size**: Sum of all entry sizes (variable)

**Value Storage**:
- **Inline Values**: Value bytes stored directly in entry (max 65535 bytes per value)
- **Overflow Pages**: Large values stored in separate page chain, entry stores page ID
- **Overflow Threshold**: Configurable (default: values larger than ~2000 bytes overflow)
- **Overflow Chain**: Singly-linked list of pages via next_page pointers

**Leaf Linked List**:
- **next_leaf**: Page ID of next leaf node in key order (0 if rightmost)
- **prev_leaf**: Page ID of previous leaf node in key order (0 if leftmost)
- **Purpose**: Enables range scans without backtracking to parent nodes
- **Consistency**: All keys in node < all keys in next_leaf node

**Invariants**:
- entry_count between 0 and max_entries
- entry_count >= minimum_entries (except root)
- Keys in strictly increasing order
- next_leaf and prev_leaf form consistent doubly-linked list
- All keys in this node < all keys in next_leaf (if next_leaf != 0)
- All keys in this node > all keys in prev_leaf (if prev_leaf != 0)
- Total space used must not exceed page size
- LSN values monotonically increase (newer entries have higher LSN)

**Binary Layout**:
```
Offset  Size              Field              Description
------  ----              -----              -----------
0       4                 magic              0x4E534442 ("NSDB")
4       1                 node_type          2 (leaf)
5       1                 flags              Node state flags
6       2                 entry_count        Number of entries
8       8                 rightmost_child    0 (unused)
16      8                 next_leaf          Next leaf page ID
24      8                 prev_leaf          Previous leaf page ID
--      --                --                 --
32      variable          entries[]          Key-value entry array
--      --                --                 --
Total: 16384 bytes                           One page
```

**Entry Format** (within entries array):
```
Offset  Size    Field         Description
------  ----    -----         -----------
0       1       key_len       Key length (0-255)
1       N       key_bytes     Key data
1+N     2       value_len     Value length (0-65535) or overflow marker
3+N     M       value_bytes   Value data (inline) or page ID (overflow)
3+N+M   8       lsn           Log sequence number
--      --      --            --
Total: 4+N+M bytes per entry (inline) or 12+N bytes (overflow)
```

### Node Differences Summary

**Internal vs Leaf Nodes**:

**Purpose**:
- Internal nodes: Route searches, store separators and child pointers
- Leaf nodes: Store data, contain actual key-value pairs

**Child Pointers**:
- Internal nodes: Have entry_count + 1 child pointers (including rightmost_child)
- Leaf nodes: No child pointers (next_leaf and prev_leaf are for linked list, not hierarchy)

**Separator vs Data**:
- Internal nodes: Store separator keys only (not actual data)
- Leaf nodes: Store complete key-value pairs with LSN

**Linked List**:
- Internal nodes: Not linked (no next/prev pointers)
- Leaf nodes: Linked in doubly-linked list (next_leaf and prev_leaf)

**Capacity**:
- Internal nodes: Higher capacity (smaller entries: key + pointer)
- Leaf nodes: Lower capacity (larger entries: key + value + LSN)

**Occupancy Rules**:
- Internal nodes: Minimum ceil((max_entries - 1) / 2) separators
- Leaf nodes: Minimum ceil((max_entries - 1) / 2) entries

**Search Behavior**:
- Internal nodes: Binary search separators, follow child pointer
- Leaf nodes: Binary search entries, return value if found

**Modification Impact**:
- Internal node split: Propagate separator up to parent
- Leaf node split: Propagate separator up to parent, update linked list

## Functions

### InternalNode Functions

**search_separator(node: InternalNode, key: &[u8]) -> usize**

**Purpose**: Find the child index where the search should continue

**Algorithm**:
1. Perform binary search on separator array
2. Find largest separator < search key
3. Return child index (0 to entry_count)
4. If key < all separators, return 0 (leftmost child)
5. If key >= all separators, return entry_count (rightmost child via rightmost_child field)

**Returns**: Index of child pointer to follow

**validate_invariants(node: InternalNode) -> Result<(), Error>**

**Purpose**: Verify all internal node invariants hold

**Algorithm**:
1. Verify magic equals 0x4E534442
2. Verify node_type equals 1 (internal)
3. Verify entry_count within valid range
4. Verify separators in strictly increasing order
5. Verify all child pointers non-zero (except possibly during empty tree state)
6. Verify total space used does not exceed page size
7. Verify entry_count >= minimum_entries (except root)

**Error Conditions**:
- InvalidMagic: Magic number mismatch
- InvalidNodeType: Not an internal node
- InvalidEntryCount: Entry count out of range
- UnsortedSeparators: Separators not in increasing order
- InvalidChildPointer: Null child pointer
- SpaceOverflow: Node exceeds page size
- UnderfullNode: Below minimum occupancy (except root)

**split_node(node: InternalNode) -> (InternalNode, InternalNode, Vec<u8>)**

**Purpose**: Split an overfull internal node into two nodes

**Algorithm**:
1. Calculate split point: ceil(entry_count / 2)
2. Allocate new internal node from Pager
3. Move separators [split_point, entry_count) to new node
4. Move corresponding child pointers to new node
5. Set original node entry_count to split_point
6. Set new node entry_count to entry_count - split_point
7. Extract separator at split_point (becomes separator for parent)
8. Update right pointers and child relationships
9. Return (original_node, new_node, separator_for_parent)

**Returns**: Tuple of (left node, right node, separator to insert in parent)

### LeafNode Functions

**search_entry(node: LeafNode, key: &[u8]) -> Option<usize>**

**Purpose**: Find entry index for exact key match

**Algorithm**:
1. Perform binary search on entry array
2. Compare key with each entry's key
3. If exact match found, return entry index
4. If no match found, return None

**Returns**: Entry index if found, None otherwise

**validate_invariants(node: LeafNode) -> Result<(), Error>**

**Purpose**: Verify all leaf node invariants hold

**Algorithm**:
1. Verify magic equals 0x4E534442
2. Verify node_type equals 2 (leaf)
3. Verify entry_count within valid range
4. Verify keys in strictly increasing order
5. Verify next_leaf and prev_leaf form consistent linked list
6. Verify all keys in this node < all keys in next_leaf (if next_leaf != 0)
7. Verify total space used does not exceed page size
8. Verify entry_count >= minimum_entries (except root)
9. Verify LSN values monotonically increase

**Error Conditions**:
- InvalidMagic: Magic number mismatch
- InvalidNodeType: Not a leaf node
- InvalidEntryCount: Entry count out of range
- UnsortedKeys: Keys not in increasing order
- InconsistentLinkedList: Next/prev pointers don't match
- InvalidKeyOrdering: Keys violate ordering with next_leaf
- SpaceOverflow: Node exceeds page size
- UnderfullNode: Below minimum occupancy (except root)

**split_node(node: LeafNode) -> (LeafNode, LeafNode, Vec<u8>)**

**Purpose**: Split an overfull leaf node into two nodes

**Algorithm**:
1. Calculate split point: ceil(entry_count / 2)
2. Allocate new leaf node from Pager
3. Move entries [split_point, entry_count) to new node
4. Set original node entry_count to split_point
5. Set new node entry_count to entry_count - split_point
6. Extract first key from new node (becomes separator for parent)
7. Update linked list:
   - Set new_node.next_leaf = original_node.next_leaf
   - Set new_node.prev_leaf = original_node.page_id
   - Set original_node.next_leaf = new_node.page_id
   - If new_node.next_leaf != 0, update that node's prev_leaf to new_node.page_id
8. Return (original_node, new_node, separator_for_parent)

**Returns**: Tuple of (left node, right node, separator to insert in parent)

**resolve_version(node: LeafNode, entry_index: usize, snapshot_lsn: Lsn) -> Option<&[u8]>**

**Purpose**: Find correct value version for snapshot LSN

**Algorithm**:
1. Get entry at entry_index
2. Check entry.lsn <= snapshot_lsn
3. If true, return entry.value (visible to snapshot)
4. If false, traverse version chain:
   a. Follow older version pointer
   b. Check older version LSN <= snapshot_lsn
   c. Repeat until found or chain exhausted
5. If chain exhausted without finding visible version, return None

**Returns**: Value bytes if visible version exists, None otherwise

## Memory Layout

### Internal Node Binary Format (Byte-by-Byte)

```
Offset  Size    Field              Description
------  ----    -----              -----------
0       4       magic              0x4E534442 ("NSDB")
4       1       node_type          1 (internal)
5       1       flags              State flags
6       2       entry_count        Number of separators
8       8       rightmost_child    Rightmost child page ID
16      8       next_leaf          0 (unused for internal)
24      8       prev_leaf          0 (unused for internal)
--      --      --                 --
32      1+N     separators[0]      First separator key (length + bytes)
33+N    1+M     separators[1]      Second separator key
...     ...     ...               ...
32+X    8       children[0]        First child page ID
40+X    8       children[1]        Second child page ID
...     ...     ...               ...
--      --      --                 --
Total: 16384 bytes                 One page

Where:
  N, M = separator key lengths (variable, 0-255 bytes each)
  X = sum of all separator sizes including length prefixes
  Children count = entry_count + 1
```

### Leaf Node Binary Format (Byte-by-Byte)

```
Offset  Size    Field              Description
------  ----    -----              -----------
0       4       magic              0x4E534442 ("NSDB")
4       1       node_type          2 (leaf)
5       1       flags              State flags
6       2       entry_count        Number of entries
8       8       rightmost_child    0 (unused for leaf)
16      8       next_leaf          Next leaf page ID
24      8       prev_leaf          Previous leaf page ID
--      --      --                 --
32      1+N     entries[0].key     First entry key (length + bytes)
33+N    2+M     entries[0].value   First entry value (length + bytes)
35+N+M  8       entries[0].lsn     First entry LSN
43+N+M  1+P     entries[1].key     Second entry key
...     ...     ...               ...
--      --      --                 --
Total: 16384 bytes                 One page

Where:
  N, P = key lengths (variable, 0-255 bytes each)
  M = value length (variable, 0-65535 bytes, or overflow marker)
  Each entry = 1 (key_len) + N (key) + 2 (value_len) + M (value) + 8 (lsn)
  Overflow entries: value_len = 0xFFFF, next 8 bytes = overflow_page_id
```

### Alignment and Padding

- All multi-byte integers use little-endian byte order
- NodeHeader is 8-byte aligned for efficient access
- Variable-length arrays have no padding between elements
- Total structure size must equal exactly one page (16384 bytes)
- Unused space at end of page is free space for future insertions

## Invariants

### Structural Invariants

**Node Header**:
- magic must equal 0x4E534442 for valid nodes
- node_type must be 1 (internal) or 2 (leaf)
- entry_count must be within valid range [0, max_capacity]
- Flags must only use defined bits (0-2), bits 3-7 reserved

**Internal Node**:
- Separator keys strictly increasing (separator[i] < separator[i+1])
- Child pointers must point to valid nodes (internal or leaf)
- All children at same depth (balanced tree)
- entry_count >= minimum_entries for non-root nodes
- Total size must not exceed page size

**Leaf Node**:
- Keys strictly increasing (key[i] < key[i+1])
- next_leaf and prev_leaf form consistent doubly-linked list
- All keys in node < all keys in next_leaf (if next_leaf != 0)
- entry_count >= minimum_entries for non-root nodes
- Total size must not exceed page size

### Operational Invariants

**After Insert**:
- Node must not exceed maximum capacity
- If at capacity, must trigger split operation
- Entry count incremented by 1
- Ordering invariants maintained

**After Delete**:
- Node must not fall below minimum capacity (except root)
- If below minimum, must trigger merge or borrow operation
- Entry count decremented by 1
- Ordering invariants maintained

**After Split**:
- Original and new nodes each within capacity
- Separator key chosen correctly (middle key)
- Parent updated with new separator
- For leaf nodes: linked list updated correctly

**After Merge**:
- Merged node must fit within capacity
- Both original nodes below minimum before merge
- Parent separator removed
- For leaf nodes: linked list updated correctly

## Dependencies

**Uses**:
- Error types module (for validation errors)
- PageId type (for child and leaf pointers)
- Lsn type (for MVCC versioning)
- Pager module (for node allocation and I/O)

**Used By**:
- B+Tree search operations
- B+Tree insert operations
- B+Tree delete operations
- B+Tree split/merge operations
- Range scan operations

## Rust Implementation Guidance

### Module Structure

The node structures should be defined in:
- `northstar_core::tree::node::NodeHeader` - Common header structure
- `northstar_core::tree::node::InternalNode` - Internal (branch) node
- `northstar_core::tree::node::LeafNode` - Data node
- `northstar_core::tree::node::NodeType` - Node type enumeration

### Type Definitions

**NodeHeader**: Use `#[repr(C, packed)]` to ensure exact binary layout. Must match the byte-by-byte specification exactly. Consider using `bytemuck::Pod` for safe byte casting.

**InternalNode**: Represent as struct with:
- `header: NodeHeader`
- `separators: Vec<Vec<u8>>` (or more efficient storage)
- `children: Vec<PageId>`

**LeafNode**: Represent as struct with:
- `header: NodeHeader`
- `entries: Vec<Entry>` where Entry contains key, value, LSN

**NodeType**: Implement as Rust enum with `#[repr(u8)]`:
- `Internal = 1`
- `Leaf = 2`

### Storage Strategies

**Separator Array**: Consider using `Vec<Vec<u8>>` for simplicity, or a more efficient representation like:
- `Vec<(u8, [u8; 255])>` with length prefix
- Single `Vec<u8>` with manual offset management
- Custom arena allocator within the page

**Entry Array**: Consider using `Vec<Entry>` where:
- Entry struct contains key (Bytes), value (Bytes or overflow PageId), lsn (Lsn)
- For zero-copy, use `&[u8]` references into page buffer

**Child Pointers**: Store as `Vec<PageId>` with length = entry_count + 1

### Key Decisions

**Enum vs Struct for Node**: Consider using an enum:
- `enum Node { Internal(InternalNode), Leaf(LeafNode) }`
- This provides type safety and prevents mixing internal/leaf operations
- Requires boxing or large size (due to InternalNode and LeafNode size differences)

**Or use separate types with trait**:
- Define `trait BTreeNode` with common methods
- Implement for InternalNode and LeafNode
- Allows generic operations on any node type

**Inline vs Overflow**: Threshold based on page size:
- Default threshold: values larger than (page_size / 8) overflow
- Configurable via B+Tree initialization parameters
- Overflow flag in node_type.flags indicates overflow present

**Validation**: Implement as methods:
- `NodeHeader::validate(&self) -> Result<(), Error>`
- `InternalNode::validate(&self) -> Result<(), Error>`
- `LeafNode::validate(&self) -> Result<(), Error>`

**Binary Compatibility**: Use `#[repr(C, packed)]` for all structures that are persisted. Ensure the Rust struct layout matches the specification exactly.

### Implementation Notes

1. **Entry Count Tracking**: Increment/decrement entry_count immediately after insert/delete. Do not wait for flush.

2. **Separator vs Key**: For internal nodes, separators are keys from the level below. During split, the middle key is promoted to parent as separator.

3. **Linked List Updates**: When splitting leaf nodes, always update three pointers: new_node.next_leaf, new_node.prev_leaf, and the next node's prev_leaf (if exists).

4. **Free Space Calculation**: Track free space within node:
   - free_space = page_size - header_size - space_used
   - space_used = sum of all separator/entry sizes
   - Check free_space before each insert to detect overflow early

5. **Overflow Handling**: For large values:
   - Check value length against threshold before insert
   - If overflow: allocate page chain, store page ID instead of value bytes
   - Mark overflow flag in node_type.flags
   - On read: detect overflow (value_len == 0xFFFF), fetch from page chain

6. **Version Chains**: For MVCC, entries may have older versions:
   - Entry contains pointer to older version (or inline if small)
   - Version chain is singly-linked (newest to oldest)
   - Reclamation: walk chain after all snapshots release LSN

7. **Debug Visibility**: Implement `Debug` trait showing:
   - Node type, entry count, capacity utilization
   - For internal: first and last separator, child count
   - For leaf: first and last key, next/prev pointers

8. **Error Context**: When validation fails, include:
   - Node type (internal or leaf)
   - What invariant failed (magic, entry_count, ordering, etc.)
   - Relevant values (expected vs actual)

### Testing Strategy

**Unit tests needed for**:
- NodeHeader magic validation (valid and invalid)
- Node type enumeration values
- Entry count bounds checking
- Separator array ordering (internal nodes)
- Key ordering validation (leaf nodes)
- Linked list consistency (leaf nodes)
- Binary format round-trip (serialize/deserialize)
- Free space calculation accuracy

**Property tests for**:
- Separator binary search correctness
- Entry binary search correctness
- Split produces valid nodes
- Merge produces valid nodes
- Ordering invariants maintained after operations
- Free space never negative

**Integration scenarios**:
- Read node from disk, validate structure
- Insert entry until split, verify split result
- Delete entries until underflow, verify merge/borrow
- Range scan follows linked list correctly
- Overflow values stored and retrieved correctly
- Version chains resolve correctly for various LSNs

**Invariant checking**:
- Run validate_invariants after every operation in tests
- Verify all structural invariants hold
- Check occupancy rules enforced
- Validate pointer consistency across operations

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and node types
- **06-btree-header.md**: Detailed NodeHeader field specifications
- **06-btree-search.md**: Search algorithms using node structures
- **06-btree-insert.md**: Insert operations and split handling
- **06-btree-split.md**: Detailed split algorithms
- **06-btree-merge.md**: Detailed merge algorithms
- **06-btree-scan.md**: Range scan using leaf linked list
- **06-btree-key.md**: Key encoding and comparison
- **06-btree-value.md**: Value storage and overflow handling
