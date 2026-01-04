# B+Tree Overview

## Purpose

The B+Tree is the core ordered key-value storage structure in NorthstarDB, providing efficient lookups, range scans, inserts, and deletes with O(log n) complexity. It stores all data records in leaf nodes with internal nodes acting as an index, enabling fast traversal from root to leaf. The B+Tree is multi-version aware, supporting MVCC snapshots by maintaining multiple versions of values with different LSNs (Log Sequence Numbers). This design allows concurrent readers to operate on historical versions while writers create new versions, ensuring snapshot isolation without blocking reads.

## Responsibilities

### Ordered Key-Value Storage

**Point Operations**: Fast key-based access
- Get: Retrieve value for a specific key
- Put: Insert or update a key-value pair
- Delete: Remove a key from the tree
- All operations traverse from root to leaf in O(log n) time

**Range Operations**: Efficient ordered iteration
- Scan: Iterate over key range [start, end)
- Forward iteration: Follow leaf node linked list
- Reverse iteration: Backtrack through leaf nodes using prev pointers
- Range queries leverage leaf node ordering for sequential access

**Multi-Version Support**: Maintain historical value versions
- Each value stores associated LSN
- Multiple versions chained per key (newest to oldest)
- Version resolution based on snapshot LSN
- Old versions reclaimed after all snapshots release them

### Tree Structure Management

**Node Types**: Two distinct node structures
- Internal nodes: Store separator keys and child page pointers
- Leaf nodes: Store key-value pairs and forward/backward pointers
- Root node: Can be internal or leaf, single node when tree has few keys
- All nodes fixed size (one page), ensuring uniform I/O

**Balance Maintenance**: Keep tree balanced for consistent performance
- Split: Divide overfull nodes during insert
- Merge: Combine underfull nodes during delete
- Borrow: Redistribute entries between sibling nodes
- Height changes: Root split grows tree, root merge shrinks tree

**Occupancy Rules**: Maintain minimum and maximum occupancy
- Internal nodes: At least half full (except root), at most full
- Leaf nodes: At least half full (except root), at most full
- Root node: Can have as few as one entry (even when empty)
- Fanout calculated from page size and key-value sizes

### Integration with Storage Layer

**Pager Interaction**: Use Pager for node I/O
- Read nodes via Pager page cache
- Write dirty nodes through Pager
- Allocate new nodes via Pager free list
- Free nodes via Pager deallocation

**WAL Integration**: Ensure crash-safe updates
- All node modifications written to WAL before page write
- LSN tracking for each node modification
- Recovery replays WAL to rebuild consistent tree state
- Checkpointing flushes dirty nodes and truncates WAL

**Transaction Support**: Coordinate with transaction system
- Uncommitted changes tracked in transaction delta layer
- Commit atomically applies delta to B+Tree
- Rollback discards delta without modifying tree
- Conflict detection ensures serializable isolation

## Design Decisions

### Node Structure

**Fixed-Size Nodes**: Each node occupies exactly one page
- **Rationale**: Simplifies I/O, cache management, and allocation
- **Tradeoff**: External values overflow to separate pages, adding indirection
- **Page size**: 16KB default (configurable, must be power of 2)
- **Node capacity**: Determined by key and value sizes

**Separator Keys in Internal Nodes**: Internal nodes store keys, not values
- **Rationale**: Maximizes fanout, reduces tree height, minimizes I/O
- **Tradeoff**: Additional traversal to reach leaf for value access
- **Separator selection**: Middle key during split, ensures balanced subtree sizes

**Leaf Node Linked List**: Doubly-linked list for sequential access
- **Rationale**: Enables efficient range scans without backtracking to parent
- **Tradeoff**: Extra 8 bytes per leaf node (next and prev pointers)
- **Forward pointer**: Page ID of next leaf node
- **Backward pointer**: Page ID of previous leaf node

### Fanout and Height

**Fanout Calculation**: Maximum children per internal node
- Formula: floor((page_size - node_header_size) / (key_size + child_ptr_size))
- Typical fanout: ~200-400 for 16KB pages with 8-byte keys
- Tree height: log_fanout(N), where N is number of keys
- Example: 1 billion keys → height 3-4 with fanout 400

**Minimum Occupancy**: Half of maximum (except root)
- Internal nodes: ceil((fanout - 1) / 2) separators minimum
- Leaf nodes: ceil((leaf_capacity - 1) / 2) entries minimum
- Root exceptions: Can have 1 entry (or 0 when tree empty)
- Rationale: Prevents cascading splits/merges during modifications

### Multi-Versioning

**Version Chains**: Linked list of value versions per key
- Newest version first, oldest version last
- Each version tagged with LSN
- Chains can span multiple nodes if value updated many times
- Old versions reclaimed after all snapshots release them

**Version Resolution**: Find correct version for snapshot LSN
- Traverse chain from newest to oldest
- Return first version with LSN ≤ snapshot LSN
- If chain exhausted, key does not exist in snapshot
- Complexity: O(k) where k is chain length (typically small)

**Storage Overhead**: Historical versions consume space
- Each version adds key + value + LSN + next pointer
- Compaction merges versions when safe
- Tradeoff: Space vs time-travel capability
- Configuration: Max versions per key, compaction threshold

### Key and Value Encoding

**Key Format**: Variable-length byte arrays
- Maximum key size: 255 bytes (stored in single byte length prefix)
- Comparison: Lexicographic byte ordering
- No special encoding (raw bytes)
- Support for any serializable key type

**Value Storage**: Inline or overflow pages
- Inline: Value stored directly in leaf node (up to ~2000 bytes)
- Overflow: Large values stored in separate page chain
- Threshold: Configurable, based on page size and node capacity
- Overflow page chain: Singly-linked list via page pointers

**Comparison Functions**: Custom ordering support
- Default: Lexicographic byte comparison
- Custom: User-defined comparison function per tree
- Collation: Optional collation-aware comparison
- Consistency: Same comparison used for all operations

## Node Types and Structures

### Internal Node (Branch Node)

**Purpose**: Index structure routing searches to leaves
**Fields**:
- Node header (common to all node types)
- Separator keys: Array of key values dividing child ranges
- Child pointers: Array of page IDs, one more than separators
- Entry count: Number of separator keys present
- Key search: Binary search to find child pointer

**Layout**:
```
[Node Header]
[Separator Key 1][Child Pointer 1]
[Separator Key 2][Child Pointer 2]
...
[Separator Key N][Child Pointer N]
[Child Pointer N+1]  // Last child has no separator
```

**Invariants**:
- Entry count between minimum and maximum occupancy
- Separator keys in strictly increasing order
- All keys in Child[i] < Separator[i] ≤ all keys in Child[i+1]
- Child pointers point to valid internal or leaf nodes

### Leaf Node

**Purpose**: Store actual key-value pairs
**Fields**:
- Node header (common to all node types)
- Key-value pairs: Array of (key, value, LSN) entries
- Entry count: Number of key-value pairs present
- Next pointer: Page ID of next leaf in key order
- Prev pointer: Page ID of previous leaf in key order

**Layout**:
```
[Node Header]
[Key 1][Value 1][LSN 1]
[Key 2][Value 2][LSN 2]
...
[Key N][Value N][LSN N]
[Next Leaf Pointer]
[Prev Leaf Pointer]
```

**Invariants**:
- Entry count between minimum and maximum occupancy
- Keys in strictly increasing order
- Next and prev pointers form consistent doubly-linked list
- All keys in this node < all keys in next node

### Root Node

**Purpose**: Entry point for all tree operations
**Special Properties**:
- Can be internal node or leaf node
- Only node allowed to violate minimum occupancy rules
- Height 0: Root is leaf node with all data
- Height H>0: Root is internal node with H+1 levels below

**Root Split**: Tree grows when root overflows
- Allocate new internal node
- Move half entries to new node
- Create new root with two children
- Height increases by 1

**Root Merge**: Tree shrinks when root has one child
- If root is internal with single child
- Promote child to new root
- Free old root page
- Height decreases by 1

### Node Header (Common to All Nodes)

**Purpose**: Metadata identifying node type and state
**Fields**:
- Node type: Internal (0x01) or Leaf (0x02)
- Entry count: Number of keys/entries in node
- Rightmost child: For internal nodes, page ID of last child
- Next leaf: For leaf nodes, page ID of next leaf
- Prev leaf: For leaf nodes, page ID of previous leaf
- Flags: Node state flags (dirty, underfull, etc.)
- Checksum: Integrity verification value

**Layout** (estimated, see 06-btree-header.md for exact):
- Magic number (4 bytes): Identify valid node
- Node type (1 byte): Internal or Leaf
- Entry count (2 bytes): 0 to 65535
- Flags (2 bytes): State flags
- Reserved (X bytes): Padding and future use
- Checksum (4 bytes): CRC32C of node contents

## Core Operations

### Search (Point Lookup)

**Operation**: Find value for given key
**Algorithm**:
1. Start at root node
2. While current node is internal:
   a. Binary search separators for key
   b. Find child pointer where key belongs
   c. Read child node from Pager
   d. Set current node to child node
3. Current node is leaf:
   a. Binary search entries for key
   b. If found, resolve version for snapshot LSN
   c. Return value or NotFound error
**Complexity**: O(log n) node reads, O(log fanout) comparisons per node
**I/O**: One node read per level (cached after first read)

### Insert

**Operation**: Insert new key-value pair or update existing key
**Algorithm**:
1. Search for key to find insertion leaf
2. If key exists:
   a. Append new version with current LSN to version chain
   b. Update entry (in-place or via delta layer)
   c. Check node overflow, split if needed
3. If key not found:
   a. Insert new entry in sorted position
   b. Increment entry count
   c. Check node overflow, split if needed
4. If leaf split occurred:
   a. Propagate separator key to parent
   b. Recursively split parent if overflowed
   c. If root split, grow tree height
**Complexity**: O(log n) for search + O(log n) for split propagation
**I/O**: Read path to leaf, write all modified nodes

### Delete

**Operation**: Remove key from tree
**Algorithm**:
1. Search for key to find target leaf
2. If key not found, return NotFound error
3. Mark entry as deleted (tombstone) or remove entry
4. Decrement entry count
5. Check node underflow:
   a. If below minimum occupancy:
      i. Try to borrow from sibling
      ii. If sibling also underfull, merge with sibling
      iii. Recursively handle parent underflow
6. If root merge possible, shrink tree height
**Complexity**: O(log n) for search + O(log n) for merge propagation
**I/O**: Read path to leaf, read siblings, write all modified nodes

### Split

**Operation**: Divide overfull node into two nodes
**Algorithm** (for leaf node):
1. Allocate new node from Pager
2. Calculate split point (ceil(entry_count / 2))
3. Move entries [split_point, entry_count) to new node
4. Set entry count to split_point in original node
5. Update linked list pointers (next, prev)
6. Return separator key (first key in new node) to parent
**Algorithm** (for internal node):
1. Allocate new node from Pager
2. Calculate split point (ceil(entry_count / 2))
3. Move entries [split_point, entry_count) to new node
4. Promote separator at split_point to parent
5. Move child pointers accordingly
6. Return promoted separator to parent
**Complexity**: O(n) to copy entries within node (n is node capacity)
**I/O**: Allocate new node, write both modified nodes

### Merge

**Operation**: Combine two underfull sibling nodes
**Algorithm**:
1. Verify both nodes together fit in one node
2. Copy all entries from right sibling to left sibling
3. Update entry count in left node
4. Free right sibling node via Pager
5. Remove separator key from parent
6. Recursively merge parent if underfull
**Complexity**: O(n) to copy entries
**I/O**: Read both nodes, write merged node, free node, update parent

### Borrow (Redistribution)

**Operation**: Move entries from sibling to underfull node
**Algorithm**:
1. Find immediate left or right sibling
2. Check if sibling has extra entries (above minimum)
3. If left sibling has extra:
   a. Move last entry from left sibling to underfull node
   b. Update separator in parent
4. If right sibling has extra:
   a. Move first entry from right sibling to underfull node
   b. Update separator in parent
**Complexity**: O(1) to move single entry
**I/O**: Read both nodes, write both modified nodes, update parent

### Range Scan

**Operation**: Iterate over key range [start, end)
**Algorithm**:
1. Search for start key to find starting leaf
2. If start not found, find next key >= start
3. Iterate entries from starting position:
   a. Yield key-value pair if key < end
   b. If end of leaf node, follow next pointer
   c. Continue until key >= end or next pointer is null
**Complexity**: O(log n + m) where m is number of entries in range
**I/O**: O(log n) to find start + O(m / leaf_capacity) to iterate

## Invariants and Guarantees

### Structural Invariants

1. **Balance Invariant**: All leaf nodes at same depth
2. **Order Invariant**: Keys strictly increasing within nodes and across levels
3. **Occupancy Invariant**: All nodes (except root) at least half full
4. **Pointer Consistency**: All child/next/prev pointers point to valid nodes
5. **Root Uniqueness**: Exactly one root node, accessible from metadata

### Operations Invariants

1. **Search Correctness**: Search finds key if and only if key exists
2. **Insert Correctness**: Insert makes key findable via subsequent searches
3. **Delete Correctness**: Delete makes key unfindable via subsequent searches
4. **Split Preserves Balance**: Split maintains all invariants
5. **Merge Preserves Balance**: Merge maintains all invariants

### Concurrency Invariants

1. **Snapshot Isolation**: Readers see consistent view at their LSN
2. **Write Serialization**: Only one write transaction at a time
3. **Version Visibility**: Snapshot sees only versions with LSN ≤ snapshot LSN
4. **Reclamation Safety**: Versions never reclaimed while referenced

## Public Functions

### Tree Operations

**create(pager: &Pager, root_page_id: PageId) -> Result<BTree, Error>**
- **Purpose**: Initialize B+Tree instance with existing root
- **Parameters**:
  - pager: Reference to Pager for node I/O
  - root_page_id: Page ID of root node (read from metadata)
- **Returns**: Initialized B+Tree instance
- **Behavior**:
  - Store pager reference for node I/O
  - Cache root page ID for fast access
  - Initialize tree state (height, statistics)
- **Error Conditions**: Pager unavailable, invalid root_page_id

**get(&self, key: &[u8], snapshot_lsn: Lsn) -> Result<Option<Value>, Error>**
- **Purpose**: Retrieve value for key at specific snapshot LSN
- **Parameters**:
  - key: Key to look up (variable-length byte array)
  - snapshot_lsn: LSN of snapshot for version resolution
- **Returns**: Some(value) if found, None if key not exists
- **Behavior**:
  - Traverse tree from root to leaf
  - Search leaf for exact key match
  - Resolve version: find newest version with LSN ≤ snapshot_lsn
  - Return value or None
- **Error Conditions**: I/O error reading nodes, corruption detected

**put(&mut self, key: &[u8], value: &[u8], lsn: Lsn) -> Result<(), Error>**
- **Purpose**: Insert or update key-value pair at specific LSN
- **Parameters**:
  - key: Key to insert (variable-length byte array)
  - value: Value to store (variable-length byte array)
  - lsn: LSN for this modification (from transaction commit)
- **Returns**: Empty tuple on success
- **Behavior**:
  - Traverse tree to find insertion leaf
  - If key exists: append new version to version chain
  - If key not exists: insert new entry
  - Handle overflow by splitting nodes
  - Update metadata if root split occurred
- **Error Conditions**: I/O error, insufficient space, node corruption

**delete(&mut self, key: &[u8], lsn: Lsn) -> Result<(), Error>**
- **Purpose**: Mark key as deleted at specific LSN
- **Parameters**:
  - key: Key to delete (variable-length byte array)
  - lsn: LSN for this deletion (from transaction commit)
- **Returns**: Empty tuple on success
- **Behavior**:
  - Traverse tree to find target leaf
  - If key not found: return NotFound error
  - Mark entry as deleted (tombstone) with this LSN
  - Handle underflow by merging or borrowing
  - Update metadata if root merged
- **Error Conditions**: I/O error, key not found, node corruption

**scan(&self, start: Option<&[u8]>, end: Option<&[u8]>, snapshot_lsn: Lsn) -> Result<ScanIter, Error>**
- **Purpose**: Create iterator over key range at specific snapshot LSN
- **Parameters**:
  - start: Start key (inclusive), None means minimum key
  - end: End key (exclusive), None means maximum key
  - snapshot_lsn: LSN of snapshot for version resolution
- **Returns**: Iterator yielding key-value pairs
- **Behavior**:
  - If start specified: find leaf containing start key
  - If start not specified: start at leftmost leaf
  - Iterate entries, yielding keys in [start, end)
  - Follow next pointers between leaf nodes
  - Stop when key >= end or end of tree
- **Error Conditions**: I/O error, invalid range

### Tree Management

**grow(&mut self) -> Result<(), Error>**
- **Purpose**: Increase tree height by splitting root
- **Behavior**:
  - Allocate new internal node from Pager
  - Move half of root entries to new node
  - Allocate new root with two children (old root, new node)
  - Update metadata with new root page ID
  - Increment height counter
- **Error Conditions**: Pager allocation failure, I/O error

**shrink(&mut self) -> Result<(), Error>**
- **Purpose**: Decrease tree height by merging root
- **Behavior**:
  - Check if root is internal with single child
  - If true: promote child to new root
  - Free old root page via Pager
  - Update metadata with new root page ID
  - Decrement height counter
- **Error Conditions**: Pager free failure, I/O error

**verify(&self) -> Result<(), Error>**
- **Purpose**: Check all tree invariants hold
- **Behavior**:
  - Traverse entire tree structure
  - Verify node types match expected
  - Verify key ordering within nodes
  - Verify pointer consistency
  - Verify occupancy rules
  - Verify leaf linked list consistency
- **Returns**: Empty tuple if all invariants hold, Error if any violated
- **Use Cases**: Debugging, testing, recovery validation

### Statistics and Debugging

**height(&self) -> usize**
- **Purpose**: Return current tree height
- **Returns**: Number of levels (0 = root is leaf, 1 = root is internal)

**node_count(&self) -> usize**
- **Purpose**: Return total number of nodes in tree
- **Returns**: Count of all internal and leaf nodes

**entry_count(&self) -> usize**
- **Purpose**: Return total number of key-value entries
- **Returns**: Count across all leaf nodes

**statistics(&self) -> TreeStats**
- **Purpose**: Return comprehensive tree statistics
- **Returns**: Struct with height, node counts, entry counts, occupancy metrics

## Module Structure

### Rust Modules

```
src/
├── tree/
│   ├── mod.rs              # Public API exports
│   ├── tree.rs             # BTree struct, top-level operations
│   ├── node.rs             # Node types (internal, leaf), header
│   ├── search.rs           # Search operations
│   ├── insert.rs           # Insert logic and split handling
│   ├── delete.rs           # Delete logic and merge handling
│   ├── scan.rs             # Range scan and iterator
│   ├── version.rs          # Multi-version chain management
│   ├── stats.rs            # Statistics and verification
│   └── tests.rs            # Unit tests
│
├── storage/
│   ├── pager.rs            # Pager integration
│   └── page_id.rs          # PageId type
│
└── txn/
    ├── lsn.rs              # Lsn type
    └── snapshot.rs         # Snapshot for version resolution
```

### Key Data Structures

**BTree**: Top-level tree struct
- Fields: pager, root_page_id, height, stats
- Methods: get, put, delete, scan, grow, shrink, verify

**Node**: Enum of node types
- Variants: Internal(InternalNode), Leaf(LeafNode)
- Common: NodeHeader with metadata

**InternalNode**: Branch node for routing
- Fields: separators, child_ptrs, entry_count
- Methods: search, insert, split, merge, borrow

**LeafNode**: Data node for storage
- Fields: entries (key, value, lsn), next_leaf, prev_leaf, entry_count
- Methods: search, insert, delete, split, merge

**ScanIter**: Iterator for range scans
- Fields: current_page, current_index, end_key, snapshot_lsn
- Methods: next, seek

**VersionChain**: Linked list of value versions
- Fields: current (value, lsn), older (Option<Box<VersionChain>>)
- Methods: resolve, prepend, reclaim

## Performance Characteristics

### Time Complexity

| Operation | Average Case | Worst Case | Notes |
|-----------|--------------|------------|-------|
| Get (search) | O(log n) | O(log n) | n = number of keys |
| Put (insert) | O(log n) | O(log n) | Split propagation adds O(log n) |
| Delete | O(log n) | O(log n) | Merge propagation adds O(log n) |
| Range scan | O(log n + m) | O(log n + m) | m = entries in range |
| Version resolve | O(k) | O(k) | k = versions per key (typically small) |

### Space Complexity

- **Node storage**: O(n) nodes, each one page
- **Version storage**: O(v) where v is total historical versions
- **Overflow pages**: O(l) where l is number of large values
- **Total**: O(n + v + l) pages

### I/O Complexity

- **Point operation**: O(log n) page reads (cached after first access)
- **Insert/modify**: O(log n) page writes (split propagation)
- **Range scan**: O(log n + m/leaf_capacity) page reads
- **Tree growth**: O(1) page allocations per level

### Fanout Impact

For 16KB page size, 8-byte keys, 8-byte pointers:
- **Internal node capacity**: ~1000 separators → fanout 1001
- **Tree height for 1 billion keys**: log_1001(1e9) ≈ 3 levels
- **Maximum keys in height-3 tree**: 1001^3 ≈ 1 billion entries

For 4KB page size, 8-byte keys, 8-byte pointers:
- **Internal node capacity**: ~250 separators → fanout 251
- **Tree height for 1 billion keys**: log_251(1e9) ≈ 4 levels
- **Maximum keys in height-4 tree**: 251^4 ≈ 4 billion entries

## Error Handling

### Error Types

**NotFoundError**: Key not found in tree
- Occurs during: get, delete
- Recovery: Return None to caller, or error for delete

**CorruptionError**: Node structure invariant violated
- Occurs during: any operation when node validation fails
- Recovery: Abort operation, return error, initiate recovery

**OverflowError**: Node too full to accommodate insert
- Occurs during: insert, split
- Recovery: Trigger node split operation

**UnderflowError**: Node below minimum occupancy
- Occurs during: delete
- Recovery: Trigger merge or borrow operation

**IOError**: Pager I/O operation failed
- Occurs during: node read/write
- Recovery: Propagate to caller, transaction abort

### Validation and Recovery

**Node Validation**: Check node structure before use
- Verify node header checksum
- Verify entry count within valid range
- Verify keys sorted within node
- Verify pointers point to valid pages

**Tree Verification**: Check all invariants periodically
- Run verify() operation during testing
- Verify after recovery from crash
- Verify before compaction operations

**Recovery Integration**: Rebuild tree from WAL after crash
- Replay all committed transactions from WAL
- Rebuild tree structure by applying modifications
- Verify tree invariants after recovery
- Fall back to checkpoint if WAL corrupted

## Testing Strategy

### Unit Tests

**Node Operations**: Test individual node manipulations
- Insert into empty node
- Insert into non-empty node
- Split at various occupancy levels
- Merge underfull nodes
- Borrow from sibling
- Key ordering validation

**Tree Traversal**: Test search correctness
- Search for existing key
- Search for non-existent key
- Search in single-node tree
- Search in multi-level tree
- Search with duplicate keys (versioned)

**Modification Operations**: Test insert/delete
- Insert into empty tree
- Insert causing leaf split
- Insert causing internal node split
- Insert causing root split (tree growth)
- Delete from leaf
- Delete causing merge
- Delete causing root merge (tree shrink)

### Integration Tests

**Transaction Integration**: Test with transaction system
- Commit transaction with multiple puts
- Rollback transaction discards changes
- Conflict detection with concurrent transactions
- MVCC snapshot isolation

**Persistence Integration**: Test with Pager and WAL
- Create tree, close, reopen, verify
- Crash mid-transaction, recover, verify
- Checkpoint and truncate WAL
- Recover from checkpoint after crash

### Property-Based Tests

**Invariants**: Test tree properties hold for arbitrary operations
- Generate random sequence of puts and deletes
- Verify tree invariants after each operation
- Verify search results match inserted keys
- Verify range scans return correct entries

**Persistence**: Test crash recovery for arbitrary states
- Generate random tree state
- Crash at arbitrary point
- Recover and verify tree consistent
- Verify all committed operations preserved

### Performance Tests

**Benchmarks**: Measure operation latencies and throughput
- Point lookup latency
- Insert throughput
- Delete throughput
- Range scan throughput for various range sizes
- Tree build time for large datasets

**Scalability**: Test behavior with increasing tree sizes
- 1K entries: single-level tree
- 1M entries: 2-3 level tree
- 1B entries: 3-4 level tree
- Measure operation latency vs tree height

## Related Specifications

- **06-btree-node.md**: Detailed node structure specifications
- **06-btree-header.md**: Node header format and fields
- **06-btree-search.md**: Search algorithm details
- **06-btree-insert.md**: Insert operation and split handling
- **06-btree-delete.md**: Delete operation and merge/borrow
- **06-btree-scan.md**: Range scan and iteration
- **06-btree-key.md**: Key encoding and comparison
- **06-btree-value.md**: Value storage and overflow pages
- **06-btree-delta.md**: Uncommitted change tracking
- **02-pager-*.md**: Pager integration for node I/O
- **03-wal-*.md**: WAL integration for crash safety
- **04-txn-*.md**: Transaction system integration

## Future Enhancements

**Optimizations**: Potential performance improvements
- Node compression for sparse keys
- Prefix compression for keys with common prefixes
- Cached node lookups for frequently accessed nodes
- Prefetch sibling nodes during scans
- Bulk load for optimized initial tree construction

**Features**: Additional functionality
- Cursor-based operations for positioned updates
- Multi-key operations (batch put/delete)
- Tree compaction and reorganization
- Adaptive node sizing based on workload
- Alternative tree variants (e.g., B*-tree, B-link tree)
