# B+Tree Node Header

## Purpose

The NodeHeader is a fixed-size metadata structure that appears at the start of every B+Tree node (both internal and leaf nodes). It provides critical identification, validation, and state information needed to interpret node contents correctly. This header enables fast node type detection, integrity verification through checksums, space management for splits and merges, and tree navigation through parent and sibling pointers. The NodeHeader is designed to be cache-friendly and efficiently readable, with all commonly accessed fields in the first 64 bytes.

## Types

### NodeHeader

**Description**: Fixed-size metadata structure that prefixes every B+Tree node. Contains all information needed to identify, validate, and manage a node without reading its entire contents.

**Size**: Exactly 64 bytes (must be consistent for all node types)

**Alignment**: 8-byte aligned for optimal performance on 64-bit architectures

**Fields**:

1. **magic** (u32, 4 bytes)
   - **Offset**: 0
   - **Purpose**: Node identification and corruption detection
   - **Value**: 0x4E535452 (ASCII "NSTR") - unique B+Tree node magic
   - **Validation**: Must equal this exact value or node is corrupted
   - **Byte Order**: Little endian
   - **Rationale**: Different from page magic to distinguish node pages from other page types
   - **Default Value**: 0x4E535452

2. **node_type** (u8, 1 byte)
   - **Offset**: 4
   - **Purpose**: Distinguishes between internal and leaf node structures
   - **Values**:
     - 1: Internal node (branch node with separator keys and child pointers)
     - 2: Leaf node (contains key-value pairs and linked list pointers)
     - 3: RootInternal (internal node that is also the tree root)
     - 4: RootLeaf (leaf node that is also the tree root)
   - **Byte Order**: Little endian (single byte, no conversion needed)
   - **Default Value**: 2 (leaf) for new nodes
   - **Rationale**: Enables correct interpretation of node body without external metadata

3. **is_root** (bool, 1 byte)
   - **Offset**: 5
   - **Purpose**: Fast detection of root node status
   - **Values**:
     - 0: Not root (normal internal or leaf node)
     - 1: Root node (tree entry point)
   - **Byte Order**: Little endian (single byte, no conversion needed)
   - **Default Value**: 0 (not root)
   - **Rationale**: Root nodes have special privileges (can violate minimum occupancy rules)
   - **Note**: Stored as u8 for C compatibility, interpreted as boolean

4. **num_keys** (u16, 2 bytes)
   - **Offset**: 6
   - **Purpose**: Number of entries currently stored in the node
   - **Internal Nodes**: Number of separator keys (child pointers = num_keys + 1)
   - **Leaf Nodes**: Number of key-value pairs
   - **Valid Range**:
     - Minimum: 0 (empty node)
     - Maximum: Depends on key/value sizes and page size
     - For 16KB pages with 8-byte keys: ~1000 separators (internal) or ~600 entries (leaf)
   - **Byte Order**: Little endian
   - **Default Value**: 0
   - **Rationale**: Enables binary search and capacity checking without parsing entire node

5. **parent_page_id** (u64, 8 bytes)
   - **Offset**: 8
   - **Purpose**: Page ID of parent node in the tree structure
   - **Internal Nodes**: Points to parent internal node (0 if this node is root)
   - **Leaf Nodes**: Points to parent internal node (0 if this node is root)
   - **Special Value**: 0 indicates this is the root node (no parent)
   - **Byte Order**: Little endian
   - **Default Value**: 0 (assumes root until assigned)
   - **Rationale**: Enables upward traversal for splits, merges, and tree rebalancing

6. **right_sibling_page_id** (u64, 8 bytes)
   - **Offset**: 16
   - **Purpose**: Page ID of right sibling node at the same tree level
   - **Internal Nodes**: Right sibling internal node (0 if none)
   - **Leaf Nodes**: Right sibling leaf node for linked list (0 if rightmost)
   - **Special Value**: 0 indicates no right sibling (rightmost node at this level)
   - **Byte Order**: Little endian
   - **Default Value**: 0
   - **Rationale**: Enables efficient range scans (leaf nodes) and sibling operations (borrow/merge)

7. **free_space** (u16, 2 bytes)
   - **Offset**: 24
   - **Purpose**: Number of free bytes available in the node body
   - **Calculation**: page_size - header_size - space_used_by_entries
   - **Valid Range**: 0 to (page_size - header_size)
   - **For 16KB pages**: 0 to 16320 bytes
   - **Byte Order**: Little endian
   - **Default Value**: page_size - header_size (16320 for 16KB pages)
   - **Rationale**: Enables fast overflow/underflow detection without full node scan
   - **Update Frequency**: Updated on every insert, delete, split, merge, or borrow operation

8. **level** (u16, 2 bytes)
   - **Offset**: 26
   - **Purpose**: Tree level (height from leaves)
   - **Leaf Nodes**: Always 0 (bottom level)
   - **Internal Nodes**: Distance to leaves (1 for nodes directly above leaves)
   - **Root Node**: Total tree height - 1
   - **Valid Range**: 0 to 65535 (practical limit much lower due to fanout)
   - **Byte Order**: Little endian
   - **Default Value**: 0 (assumes leaf until assigned)
   - **Rationale**: Enables traversal validation and height-based optimizations

9. **checksum** (u32, 4 bytes)
   - **Offset**: 28
   - **Purpose**: CRC32C checksum for integrity verification
   - **Coverage**: All bytes in the node except the checksum field itself
   - **Algorithm**: CRC32C (Castagnoli polynomial)
   - **Byte Order**: Little endian
   - **Default Value**: Calculated on node initialization
   - **Rationale**: Detects corruption from disk errors, crashes, or bugs
   - **Validation**: Checked on every node read from disk
   - **Update**: Recalculated after every modification to the node

10. **flags** (u32, 4 bytes)
    - **Offset**: 32
    - **Purpose**: Node state and optimization flags
    - **Bit Fields**:
      - Bit 0 (0x00000001): Dirty flag - node modified since last flush
      - Bit 1 (0x00000002): Underfull flag - node below minimum occupancy
      - Bit 2 (0x00000004): Overflow flag - node contains overflow page references
      - Bit 3 (0x00000008): Compressed flag - node body is compressed
      - Bit 4 (0x00000010): Deleted flag - node marked for deletion
      - Bit 5 (0x00000020): SplitPending flag - split operation in progress
      - Bit 6 (0x00000040): MergePending flag - merge operation in progress
      - Bits 7-31: Reserved for future use (must be 0)
    - **Byte Order**: Little endian
    - **Default Value**: 0 (no flags set)
    - **Rationale**: Enables fast state checking without parsing node body

11. **generation** (u64, 8 bytes)
    - **Offset**: 36
    - **Purpose**: Monotonically increasing counter for node versioning
    - **Usage**: Incremented on every node modification
    - **Valid Range**: 1 to 2^64 - 1 (practically unlimited)
    - **Byte Order**: Little endian
    - **Default Value**: 1 on creation
    - **Rationale**: Enables change detection and concurrency control
    - **Applications**: LSN integration, optimistic locking, change tracking

12. **reserved** (u64, 8 bytes)
    - **Offset**: 44
    - **Purpose**: Reserved space for future use
    - **Current Value**: Must be 0
    - **Byte Order**: Little endian
    - **Default Value**: 0
    - **Rationale**: Forward compatibility for future header extensions

13. **node_id** (u64, 8 bytes)
    - **Offset**: 52
    - **Purpose**: Unique node identifier (page ID from Pager)
    - **Usage**: Matches the page ID assigned by the Pager
    - **Valid Range**: 1 to 2^64 - 1 (0 is invalid)
    - **Byte Order**: Little endian
    - **Default Value**: 0 (assigned by Pager on allocation)
    - **Rationale**: Enables node self-identification and validation
    - **Validation**: Must match the page ID used to read the node

**Binary Layout Diagram**:
```
Offset  Size    Field                  Description
------  ----    -----                  -----------
0       4       magic                  0x4E535452 ("NSTR")
4       1       node_type              1=Internal, 2=Leaf, 3=RootInternal, 4=RootLeaf
5       1       is_root                0=normal, 1=root node
6       2       num_keys               Number of entries/separators
8       8       parent_page_id         Parent node page ID (0 if root)
16      8       right_sibling_page_id  Right sibling page ID (0 if none)
24      2       free_space             Available bytes for entries
26      2       level                  Tree level (0=leaf)
28      4       checksum               CRC32C of node contents
32      4       flags                  Node state flags
36      8       generation             Node version counter
44      8       reserved               Reserved for future (must be 0)
52      8       node_id                Page ID (must match page address)
--      --      --                     --
Total:  64 bytes                        Fixed-size header
```

### NodeType Enum

**Description**: Enumeration of possible node type values for the node_type field

**Values**:
- **Internal (1)**: Branch node containing separator keys and child pointers
- **Leaf (2)**: Data node containing key-value pairs and linked list pointers
- **RootInternal (3)**: Internal node that is also the tree root
- **RootLeaf (4)**: Leaf node that is also the tree root

**Rationale**: Combining node type and root status into a single field enables faster type checking with fewer comparisons.

**Alternative Design**: Could use separate node_type and is_root fields (current design uses both for flexibility).

### NodeFlags Enum

**Description**: Bit flag values for the flags field

**Values**:
- **Dirty (0x00000001)**: Node modified in memory, not yet flushed to disk
- **Underfull (0x00000002)**: Node below minimum occupancy, needs merge/borrow
- **Overflow (0x00000004)**: Node contains references to overflow pages
- **Compressed (0x00000008)**: Node body is compressed (future feature)
- **Deleted (0x00000010)**: Node marked for deletion, awaiting deallocation
- **SplitPending (0x00000020)**: Split operation in progress on this node
- **MergePending (0x00000040)**: Merge operation in progress on this node

**Flag Combinations**:
- Dirty can combine with any other flag
- Underfull and SplitPending are mutually exclusive (node cannot be both)
- Overflow and Compressed are mutually exclusive (different storage strategies)

## Invariants

### Structural Invariants

1. **Magic Invariant**: magic field must always equal 0x4E535452 for valid nodes
2. **Type Invariant**: node_type must be one of the defined values (1-4)
3. **Consistency Invariant**: is_root flag must match node_type (RootInternal/Internal, RootLeaf/Leaf)
4. **Capacity Invariant**: num_keys must not exceed maximum capacity for the node type
5. **Parent Invariant**: If is_root is true, parent_page_id must be 0
6. **Sibling Invariant**: For leaf nodes, right_sibling_page_id must form consistent linked list
7. **Space Invariant**: free_space + header_size + space_used_by_entries must equal page_size
8. **Level Invariant**: For leaf nodes, level must be 0
9. **Checksum Invariant**: checksum field must contain valid CRC32C of node contents
10. **Reserved Invariant**: reserved field must be 0 (for forward compatibility)
11. **ID Invariant**: node_id must match the page ID used to read the node

### Operational Invariants

**After Node Creation**:
- magic set to 0x4E535452
- node_type and is_root set appropriately
- num_keys set to 0
- free_space set to (page_size - header_size)
- checksum calculated and set
- generation set to 1
- flags cleared (all bits 0)

**After Insert Operation**:
- num_keys incremented by 1
- free_space decreased by entry_size
- dirty flag set
- generation incremented
- checksum recalculated

**After Delete Operation**:
- num_keys decremented by 1
- free_space increased by entry_size
- underfull flag set if below minimum occupancy
- dirty flag set
- generation incremented
- checksum recalculated

**After Split Operation**:
- Original node: num_keys reduced, free_space increased, dirty flag set, split_pending flag set
- New node: magic initialized, num_keys set, free_space calculated, dirty flag set
- Both nodes: generation incremented, checksum recalculated

**After Merge Operation**:
- Merged node: num_keys increased, free_space decreased, dirty flag set, merge_pending flag set
- Freed node: deleted flag set
- Merged node: generation incremented, checksum recalculated

**After Flush to Disk**:
- dirty flag cleared
- All other fields unchanged
- Checksum already valid

## Functions

### Header Initialization

**init_header(header: NodeHeader, node_type: NodeType, is_root: bool, page_id: PageId) -> NodeHeader**

**Purpose**: Initialize a new NodeHeader with appropriate default values

**Parameters**:
- header: Uninitialized header structure
- node_type: Type of node being created (Internal, Leaf, RootInternal, RootLeaf)
- is_root: Whether this node is the tree root
- page_id: Page ID assigned by Pager for this node

**Algorithm**:
1. Set magic to 0x4E535452
2. Set node_type field to the provided node type value
3. Set is_root field to the provided is_root value
4. Set num_keys to 0
5. Set parent_page_id to 0 (will be set when node attached to tree)
6. Set right_sibling_page_id to 0
7. Set free_space to (page_size - header_size)
8. Set level based on node_type (0 for leaf, calculated for internal)
9. Set generation to 1
10. Set flags to 0 (no flags set)
11. Set reserved to 0
12. Calculate and set checksum (excluding checksum field itself)
13. Set node_id to provided page_id

**Returns**: Initialized NodeHeader structure

**Error Conditions**: None (initialization always succeeds)

**Concurrency**: Single-threaded (node creation is not concurrent)

### Header Validation

**validate_header(header: NodeHeader) -> Result<(), ValidationError>**

**Purpose**: Verify that a NodeHeader contains valid and consistent metadata

**Algorithm**:
1. Check magic field equals 0x4E535452
   - If not, return InvalidMagic error
2. Check node_type is valid value (1-4)
   - If not, return InvalidNodeType error
3. Check is_root flag consistency with node_type
   - If node_type is RootInternal or RootLeaf, is_root must be true
   - If node_type is Internal or Leaf, is_root must be false
   - If inconsistent, return TypeMismatch error
4. Check num_keys within valid range
   - Must be >= 0 and <= max_capacity
   - If not, return InvalidEntryCount error
5. Check parent_page_id consistency
   - If is_root is true, parent_page_id must be 0
   - If not, return ParentConsistency error
6. Check level field consistency
   - For leaf nodes (types 2, 4), level must be 0
   - For internal nodes (types 1, 3), level must be > 0
   - If not, return LevelMismatch error
7. Check free_space validity
   - Must be >= 0 and <= (page_size - header_size)
   - If not, return InvalidFreeSpace error
8. Verify checksum field
   - Calculate CRC32C of node contents (excluding checksum field)
   - Compare with stored checksum
   - If mismatch, return ChecksumMismatch error
9. Check reserved field is 0
   - If not, return ReservedNotEmpty error (may indicate newer format)
10. Validate node_id
    - Must not be 0
    - Should match the page ID used to read the node
    - If not, return NodeIdMismatch error

**Returns**: Ok(()) if all validations pass, Err(ValidationError) if any check fails

**Error Conditions**:
- InvalidMagic: Magic number is incorrect
- InvalidNodeType: Node type not in valid range
- TypeMismatch: is_root flag inconsistent with node_type
- InvalidEntryCount: num_keys out of valid range
- ParentConsistency: parent_page_id inconsistent with is_root
- LevelMismatch: level field inconsistent with node_type
- InvalidFreeSpace: free_space out of valid range
- ChecksumMismatch: Calculated checksum does not match stored value
- ReservedNotEmpty: Reserved field contains non-zero values
- NodeIdMismatch: node_id does not match page address

**Concurrency**: Read-only (safe to call concurrently)

### Checksum Calculation

**calculate_checksum(node_bytes: &[u8]) -> u32**

**Purpose**: Compute CRC32C checksum for node contents

**Algorithm**:
1. Create a mutable copy of the node_bytes
2. Zero out the checksum field (bytes 28-31)
3. Calculate CRC32C over the entire node (all bytes)
4. Return the calculated checksum value

**Returns**: 32-bit CRC32C checksum value

**Error Conditions**: None (CRC32C calculation cannot fail)

**Concurrency**: Read-only (safe to call concurrently)

**Note**: Use hardware-accelerated CRC32C (SSE4.2 or ARM CRC) for performance

### Checksum Verification

**verify_checksum(node_bytes: &[u8]) -> bool**

**Purpose**: Verify that the stored checksum matches the calculated checksum

**Algorithm**:
1. Extract stored_checksum from bytes 28-31
2. Calculate calculated_checksum using calculate_checksum()
3. Compare stored_checksum with calculated_checksum
4. Return true if equal, false otherwise

**Returns**: true if checksums match, false if mismatch

**Error Conditions**: None (comparison cannot fail)

**Concurrency**: Read-only (safe to call concurrently)

### Free Space Calculation

**calculate_free_space(header: NodeHeader, entry_sizes: &[usize]) -> u16**

**Purpose**: Calculate the actual free space in a node

**Algorithm**:
1. Sum all entry sizes from entry_sizes array
2. Calculate used_space = header_size + sum_entry_sizes
3. Calculate free_space = page_size - used_space
4. Assert free_space >= 0 and free_space <= (page_size - header_size)
5. Return free_space as u16

**Returns**: Free space in bytes

**Error Conditions**:
- InvalidEntrySizes: Sum of entry sizes exceeds available space
- SpaceOverflow: Calculated free_space is negative

**Concurrency**: Depends on caller (requires consistent view of node)

### Node Type Detection

**get_node_type(header: NodeHeader) -> NodeType**

**Purpose**: Extract and interpret the node type from header

**Algorithm**:
1. Read node_type field (byte at offset 4)
2. Match against known values:
   - 1: Return NodeType::Internal
   - 2: Return NodeType::Leaf
   - 3: Return NodeType::RootInternal
   - 4: Return NodeType::RootLeaf
   - Other: Return error or unknown type
3. Return matched NodeType

**Returns**: NodeType enum value

**Error Conditions**:
- InvalidNodeType: node_type field contains unknown value

**Concurrency**: Read-only (safe to call concurrently)

### Root Status Check

**is_root_node(header: NodeHeader) -> bool**

**Purpose**: Fast check whether node is the tree root

**Algorithm**:
1. Read is_root field (byte at offset 5)
2. Return true if value is 1, false otherwise

**Returns**: true if root node, false otherwise

**Error Conditions**: None (boolean interpretation cannot fail)

**Concurrency**: Read-only (safe to call concurrently)

### Capacity Checking

**is_node_full(header: NodeHeader, entry_size: usize) -> bool**

**Purpose**: Check if node has sufficient space for a new entry

**Algorithm**:
1. Read free_space from header
2. Check if free_space >= entry_size
3. Return true if sufficient space, false otherwise

**Returns**: true if node can accommodate entry, false if full

**Error Conditions**: None (comparison cannot fail)

**Concurrency**: Requires consistent view of header (may need synchronization)

**Note**: This check should be performed before insert to detect overflow early

### Occupancy Checking

**is_node_underfull(header: NodeHeader, min_entries: u16) -> bool**

**Purpose**: Check if node is below minimum occupancy threshold

**Algorithm**:
1. Read num_keys from header
2. Compare num_keys with min_entries
3. Return true if num_keys < min_entries, false otherwise

**Returns**: true if underfull, false if at or above minimum

**Error Conditions**: None (comparison cannot fail)

**Concurrency**: Read-only (safe to call concurrently)

**Note**: Underfull nodes are candidates for merge or borrow operations

### Flag Operations

**set_flag(header: NodeHeader, flag: NodeFlag)**

**Purpose**: Set a specific flag in the flags field

**Algorithm**:
1. Read current flags value
2. Perform bitwise OR: new_flags = current_flags | flag_value
3. Write new_flags back to header
4. If flag changed, set dirty flag

**Error Conditions**: None (bitwise operation cannot fail)

**Concurrency**: Requires exclusive access to header

**clear_flag(header: NodeHeader, flag: NodeFlag)**

**Purpose**: Clear a specific flag in the flags field

**Algorithm**:
1. Read current flags value
2. Perform bitwise AND with complement: new_flags = current_flags & !flag_value
3. Write new_flags back to header
4. If flag changed, set dirty flag

**Error Conditions**: None (bitwise operation cannot fail)

**Concurrency**: Requires exclusive access to header

**check_flag(header: NodeHeader, flag: NodeFlag) -> bool**

**Purpose**: Check if a specific flag is set

**Algorithm**:
1. Read current flags value
2. Perform bitwise AND: result = current_flags & flag_value
3. Return true if result != 0, false otherwise

**Returns**: true if flag is set, false otherwise

**Error Conditions**: None (bitwise operation cannot fail)

**Concurrency**: Read-only (safe to call concurrently)

## Dependencies

**Uses**:
- CRC32C implementation for checksum calculation
- PageId type for page ID fields
- Error types module for validation errors
- Constants for magic numbers and field sizes

**Used By**:
- Internal node operations (split, merge, search)
- Leaf node operations (insert, delete, scan)
- Tree operations (grow, shrink, verify)
- Pager integration (node read/write)
- Recovery operations (node validation after crash)

## Rust Implementation Guidance

### Module Structure

The NodeHeader should be defined in:
- `northstar_core::tree::header::NodeHeader` - Header structure
- `northstar_core::tree::header::NodeType` - Node type enumeration
- `northstar_core::tree::header::NodeFlag` - Flag bit values

### Type Definitions

**NodeHeader**: Use `#[repr(C, packed)]` to ensure exact binary layout matching the specification:
```rust
#[repr(C, packed)]
pub struct NodeHeader {
    pub magic: u32,              // Offset 0
    pub node_type: u8,           // Offset 4
    pub is_root: u8,             // Offset 5
    pub num_keys: u16,           // Offset 6
    pub parent_page_id: u64,     // Offset 8
    pub right_sibling_page_id: u64, // Offset 16
    pub free_space: u16,         // Offset 24
    pub level: u16,              // Offset 26
    pub checksum: u32,           // Offset 28
    pub flags: u32,              // Offset 32
    pub generation: u64,         // Offset 36
    pub reserved: u64,           // Offset 44
    pub node_id: u64,            // Offset 52
}
// Total size: 64 bytes
```

**NodeType**: Implement as Rust enum with `#[repr(u8)]`:
```rust
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeType {
    Internal = 1,
    Leaf = 2,
    RootInternal = 3,
    RootLeaf = 4,
}
```

**NodeFlag**: Implement flag values as constants or bitflags:
```rust
pub struct NodeFlags;
impl NodeFlags {
    pub const DIRTY: u32 = 0x00000001;
    pub const UNDERFULL: u32 = 0x00000002;
    pub const OVERFLOW: u32 = 0x00000004;
    pub const COMPRESSED: u32 = 0x00000008;
    pub const DELETED: u32 = 0x00000010;
    pub const SPLIT_PENDING: u32 = 0x00000020;
    pub const MERGE_PENDING: u32 = 0x00000040;
}
```

### Checksum Implementation

**Recommended Crate**: Use `crc32fast` for hardware-accelerated CRC32C:
```rust
use crc32fast::Hasher;

pub fn calculate_checksum(node_bytes: &[u8]) -> u32 {
    let mut hasher = Hasher::new();
    hasher.update(&node_bytes[0..28]);  // Bytes before checksum
    hasher.update(&[0u8; 4]);           // Skip checksum field
    hasher.update(&node_bytes[32..]);   // Bytes after checksum
    hasher.finalize()
}
```

**Alternative**: Use `crc-catalog` or manual implementation for zero dependencies.

### Validation Functions

Implement validation as a method on NodeHeader:
```rust
impl NodeHeader {
    pub fn validate(&self, page_id: PageId) -> Result<(), NodeHeaderError> {
        // Check magic
        if self.magic != 0x4E535452 {
            return Err(NodeHeaderError::InvalidMagic(self.magic));
        }
        // Check node_type
        if !(1..=4).contains(&self.node_type) {
            return Err(NodeHeaderError::InvalidNodeType(self.node_type));
        }
        // Check consistency
        if self.is_root != 0 && self.parent_page_id != 0 {
            return Err(NodeHeaderError::ParentConsistency);
        }
        // Verify checksum
        // ... (full validation logic)
        Ok(())
    }
}
```

### Flag Operations

Implement flag operations as methods:
```rust
impl NodeHeader {
    pub fn set_flag(&mut self, flag: u32) {
        self.flags |= flag;
    }

    pub fn clear_flag(&mut self, flag: u32) {
        self.flags &= !flag;
    }

    pub fn has_flag(&self, flag: u32) -> bool {
        (self.flags & flag) != 0
    }
}
```

### Key Decisions

**Endianess**: Use little-endian for all multi-byte integers (x86_64 standard). Use `byteorder` crate or manual byte swapping for cross-platform support.

**Checksum Algorithm**: CRC32C (Castagnoli) is preferred due to hardware acceleration on modern CPUs (SSE4.2 on Intel, CRC extension on ARM).

**Packed vs Aligned**: Use `#[repr(C, packed)]` for exact binary layout. This prevents padding and ensures the structure matches the on-disk format exactly.

**Validation Strategy**: Validate on every node read from disk. Consider lazy validation for performance (validate checksum, validate full structure on first access).

**Dirty Tracking**: Use the dirty flag to avoid unnecessary checksum recalculations. Only recalculate checksum when dirty flag is set and node is being flushed.

**Generation Counter**: Increment on every modification. Use for optimistic locking and change detection. Can be integrated with LSN for transactional semantics.

**Type Safety**: Consider using newtype patterns for specific field types (e.g., `struct NumKeys(u16)`) to prevent misuse and add type-level documentation.

### Implementation Notes

1. **Header Size Mismatch**: If actual struct size differs from 64 bytes due to padding, use explicit padding fields:
   ```rust
   #[repr(C, packed)]
   pub struct NodeHeader {
       // ... fields ...
       pub _padding: u64,  // Explicit padding if needed
   }
   ```

2. **Atomic Operations**: For concurrent access, consider using atomic types for frequently modified fields:
   ```rust
   pub struct NodeHeader {
       // ... non-atomic fields ...
       pub flags: AtomicU32,
       pub generation: AtomicU64,
   }
   ```

3. **Checksum Caching**: Cache checksum value to avoid recalculation:
   - Calculate on node modification
   - Store in checksum field
   - Only recalculate when dirty flag is set

4. **Default Values**: implement Default trait:
   ```rust
   impl Default for NodeHeader {
       fn default() -> Self {
           Self {
               magic: 0x4E535452,
               node_type: NodeType::Leaf as u8,
               is_root: 0,
               num_keys: 0,
               parent_page_id: 0,
               right_sibling_page_id: 0,
               free_space: PAGE_SIZE - HEADER_SIZE,
               level: 0,
               checksum: 0,
               flags: 0,
               generation: 1,
               reserved: 0,
               node_id: 0,
           }
       }
   }
   ```

5. **Debug Representation**: Implement Debug trait with detailed output:
   ```rust
   impl fmt::Debug for NodeHeader {
       fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
           f.debug_struct("NodeHeader")
               .field("magic", &format_args!("0x{:08X}", self.magic))
               .field("node_type", &self.node_type)
               .field("is_root", &self.is_root != 0)
               .field("num_keys", &self.num_keys)
               // ... other fields ...
               .finish()
       }
   }
   ```

6. **Error Context**: When validation fails, include detailed context:
   - Expected vs actual values
   - Node type and ID
   - Field that failed validation
   - This aids debugging and recovery

7. **Const Generics**: Consider using const generics for page size:
   ```rust
   pub struct NodeHeader<const PAGE_SIZE: usize = 16384> {
       // ... fields ...
       pub free_space: u16,  // Max value: PAGE_SIZE - 64
   }
   ```

### Testing Strategy

**Unit tests needed for**:
- Header initialization with all node types
- Magic validation (valid and invalid values)
- Node type enumeration values
- Is root flag consistency
- Checksum calculation and verification
- Free space calculation accuracy
- Flag operations (set, clear, check)
- Capacity checking (is_node_full)
- Occupancy checking (is_node_underfull)
- Binary format round-trip (serialize/deserialize)

**Property tests for**:
- Checksum correctness (random data, verify calculation)
- Flag operations (set, clear, check invariants)
- Free space never negative
- Capacity checks prevent overflow
- All validation invariants hold

**Integration scenarios**:
- Read node from disk, validate header
- Modify node, update header fields, verify checksum
- Flush node to disk, verify header persistence
- Recover from crash, validate all node headers
- Tree operations update header correctly

**Fuzzing targets**:
- Invalid magic numbers
- Corrupted checksums
- Invalid node types
- Out-of-range field values
- Inconsistent flag combinations

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and node type overview
- **06-btree-node.md**: Detailed internal and leaf node structures using NodeHeader
- **06-btree-search.md**: Search operations using header metadata
- **06-btree-insert.md**: Insert operations that update header fields
- **06-btree-delete.md**: Delete operations that update header fields
- **06-btree-split.md**: Split operations that create new nodes with headers
- **06-btree-merge.md**: Merge operations that update headers of merged nodes
- **01-checksum.md**: CRC32C algorithm details and implementation
- **01-page-types.md**: Page structure and how nodes fit within pages
