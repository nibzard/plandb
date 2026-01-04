# B+Tree Search Operation

## Purpose

The search operation is the fundamental read operation of the B+Tree, enabling efficient key-based data retrieval with O(log n) time complexity. Search traverses the tree from root to leaf, performing binary search at each internal node to locate the correct child pointer, ultimately reaching a leaf node where the key-value pair resides or determining that the key does not exist. This specification covers point lookups (exact key matches), predecessor/successor queries for range navigation, and internal node search algorithms used during insert and delete operations. The search operation is read-only and never modifies tree structure, making it safe to execute concurrently with other read operations.

## Types

### SearchDirection

**Description**: Enumeration controlling search behavior when exact key match is not found

**Values**:
- **Exact**: Only return the exact key match, return None if not found
- **Predecessor**: Return the largest key less than or equal to search key (floor)
- **Successor**: Return the smallest key greater than or equal to search key (ceiling)
- **Both**: Return both predecessor and successor for range queries

**Rationale**: Enables flexible query patterns for range scans and navigation without multiple tree traversals

### SearchResult

**Description**: Result type returned by search operations containing status and optional value

**Fields**:
- **found**: bool - True if exact key match was found, false otherwise
- **value**: Option<Value> - Value if found, None if not found
- **leaf_page_id**: PageId - Page ID of leaf node where search ended
- **key_index**: u16 - Index within leaf node where key was found or should be inserted
- **path**: SearchPath - Traversal path from root to leaf (for insert/delete)

**Rationale**: Rich result type supports both read operations (need value) and write operations (need location for modification)

### SearchPath

**Description**: Record of nodes traversed during search, used by insert/delete to update nodes on path

**Fields**:
- **nodes**: Vec<(PageId, u16)> - List of (node_page_id, child_index) tuples from root to parent of leaf
- **root_page_id**: PageId - Root page ID where search started
- **depth**: u16 - Number of levels traversed (tree height)

**Rationale**: Enables efficient updates during insert/delete without retraversing the tree

### SearchStats

**Description**: Performance metrics for search operations

**Fields**:
- **nodes_visited**: u32 - Number of nodes read during search
- **pages_read**: u32 - Number of disk pages read (may be less than nodes_visited if cached)
- **comparisons**: u32 - Number of key comparisons performed
- **duration_us**: u64 - Search duration in microseconds

**Rationale**: Enables performance monitoring and optimization identification

## Algorithms

### Internal Node Binary Search

**Purpose**: Locate the correct child pointer in an internal node during tree traversal

**Context**: Internal nodes contain separator keys that partition the key space. For a node with n separator keys, it has n+1 child pointers. The goal is to find the child pointer whose key range contains the search key.

**Algorithm**:

1. **Input**: Internal node with separator_keys array and child_ptrs array, search_key
2. **Validation**:
   - Verify node_type is Internal or RootInternal
   - Verify num_keys > 0 (empty internal nodes should not exist except during tree initialization)
   - Verify separator_keys array is sorted in ascending order
3. **Binary Search**:
   - Set low = 0, high = num_keys - 1
   - While low <= high:
     - Calculate mid = low + (high - low) / 2
     - Compare search_key with separator_keys[mid]:
       - If search_key < separator_keys[mid]:
         - Set high = mid - 1 (search in left partition)
       - Else if search_key > separator_keys[mid]:
         - Set low = mid + 1 (search in right partition)
       - Else (exact match with separator):
         - Return child_ptrs[mid + 1] (separator key goes to right child)
4. **Post-Search**:
   - If loop exits without exact match, low is the insertion point
   - Return child_ptrs[low]
5. **Validation**:
   - Verify returned child pointer is not null (0)
   - If child pointer is null, return NodeNotFound error

**Time Complexity**: O(log n) where n is the number of separator keys in the node

**Space Complexity**: O(1) (in-place search, no additional allocation)

**Return**: PageId of the child node to traverse next

**Error Conditions**:
- EmptyInternalNode: Internal node has no keys (corrupted tree)
- InvalidChildPointer: Child pointer is null or invalid
- CorruptSeparators: Separator keys are not sorted (corruption detected)

**Concurrency**: Read-only, safe to execute concurrently with other searches

**Edge Cases**:
- **Search key less than all separators**: Returns first child (index 0)
- **Search key greater than all separators**: Returns last child (index num_keys)
- **Search key equals separator**: Returns right child (separator keys are "right-biased")
- **Single key node**: Direct comparison, returns left or right child

### Leaf Node Binary Search

**Purpose**: Locate an exact key match or insertion position within a leaf node

**Context**: Leaf nodes contain sorted key-value pairs. Search must find exact match for point queries or determine insertion position for range queries.

**Algorithm**:

1. **Input**: Leaf node with keys array and values array, search_key
2. **Validation**:
   - Verify node_type is Leaf or RootLeaf
   - Verify keys array is sorted in ascending order
3. **Binary Search**:
   - Set low = 0, high = num_keys - 1
   - While low <= high:
     - Calculate mid = low + (high - low) / 2
     - Compare search_key with keys[mid]:
       - If search_key < keys[mid]:
         - Set high = mid - 1 (search in left half)
       - Else if search_key > keys[mid]:
         - Set low = mid + 1 (search in right half)
       - Else (exact match found):
         - Return SearchResult { found: true, value: values[mid], leaf_page_id, key_index: mid }
4. **Not Found Case**:
   - If loop exits without match, return SearchResult { found: false, value: None, leaf_page_id, key_index: low }
   - The key_index indicates where the key would be inserted to maintain sorted order
5. **Validation**:
   - If found, verify value is not None
   - Verify key_index is within valid range [0, num_keys]

**Time Complexity**: O(log n) where n is the number of entries in the leaf

**Space Complexity**: O(1) (in-place search)

**Return**: SearchResult with found status, optional value, and location

**Error Conditions**:
- CorruptLeafKeys: Keys array is not sorted
- InvalidValueIndex: Value array length does not match keys array length

**Concurrency**: Read-only, safe to execute concurrently

**Edge Cases**:
- **Empty leaf**: Returns found: false, key_index: 0
- **Single entry leaf**: Direct comparison
- **Search key less than all keys**: Returns key_index: 0
- **Search key greater than all keys**: Returns key_index: num_keys

### Full Tree Search (Point Query)

**Purpose**: Traverse from root to leaf to find an exact key match

**Context**: This is the primary read operation for point lookups (get operations)

**Algorithm**:

1. **Input**: B+Tree with root_page_id, search_key
2. **Initialization**:
   - Create empty SearchPath to record traversal
   - Set current_page_id = root_page_id
   - Set nodes_visited = 0
3. **Tree Traversal**:
   - While true:
     - Increment nodes_visited counter
     - Read page current_page_id from Pager (may be cached or from disk)
     - Validate page has valid NodeHeader (checksum, magic)
     - Check node_type from header:
       - **If Internal or RootInternal**:
         - Perform internal node binary search to find child pointer
         - Record (current_page_id, child_index) in SearchPath
         - Set current_page_id = child_pointer from search
         - Continue loop (descend to child)
       - **If Leaf or RootLeaf**:
         - Perform leaf node binary search
         - Construct SearchResult with path
         - Update SearchStats (nodes_visited, comparisons)
         - Return SearchResult
       - **Else**:
         - Return InvalidNodeType error
4. **Termination**:
   - Loop always terminates at leaf level because tree height is finite
   - Leaf search always returns a result (found or not found)

**Time Complexity**: O(h * log n) where h is tree height and n is average node fanout
- In practice: O(log N) where N is total number of keys in tree

**Space Complexity**: O(h) for SearchPath stack

**Return**: SearchResult with found status, value (if found), and traversal path

**Error Conditions**:
- TreeEmpty: Root page ID is null
- InvalidRootPage: Root page does not exist
- CorruptNode: Node validation fails (checksum, magic)
- InvalidNodeType: Unknown node type encountered

**Concurrency**: Read-only, multiple searches can execute concurrently

**Performance Considerations**:
- Cache effectiveness: Upper levels (root, near-root) are likely in cache
- Disk I/O: One disk read per level if nodes not cached
- Comparison cost: Proportional to key length (variable-length keys)

**Edge Cases**:
- **Empty tree**: Return TreeEmpty error (root_page_id is 0)
- **Single node tree** (root is leaf): Skip internal node search, go directly to leaf search
- **Very tall tree**: May indicate pathological tree structure (fanout too small)

### Predecessor Search (Floor)

**Purpose**: Find the largest key less than or equal to the search key

**Context**: Used for range navigation, finding previous entry, and implementing range scan start points

**Algorithm**:

1. **Input**: B+Tree with root_page_id, search_key
2. **Tree Traversal**:
   - Follow same traversal as point query (internal node binary search, descend to leaf)
   - Record SearchPath during traversal
3. **Leaf Node Search with Predecessor Logic**:
   - Perform binary search on leaf node keys
   - **If exact match found**:
     - Return found: true, value: matched_value, key_index: match_index
   - **If no exact match**:
     - Binary search returns key_index = insertion_point
     - If insertion_point > 0:
       - Predecessor is at index insertion_point - 1
       - Return found: false, value: predecessor_value, key_index: insertion_point - 1
     - Else (insertion_point == 0):
       - Predecessor does not exist in this leaf (search key is less than all keys in this leaf)
       - Need to traverse to left sibling leaf
4. **Left Sibling Traversal** (if needed):
   - Follow right_sibling_page_id pointers backward (requires parent navigation)
   - Use SearchPath to navigate to parent, then to left sibling
   - Get maximum key from left sibling (last entry)
   - Return predecessor value
5. **No Predecessor Case**:
   - If no left sibling exists, search key is smaller than all keys in tree
   - Return found: false, value: None, key_index: 0

**Time Complexity**: O(log N + S) where S is sibling traversal cost (typically O(1))

**Space Complexity**: O(h) for SearchPath

**Return**: SearchResult with predecessor value or None if no predecessor exists

**Error Conditions**:
- Same as point query
- SiblingNavigationFailed: Cannot navigate to left sibling (corrupted sibling pointers)

**Concurrency**: Read-only, safe for concurrent execution

### Successor Search (Ceiling)

**Purpose**: Find the smallest key greater than or equal to the search key

**Context**: Used for range navigation, finding next entry, and implementing range scan end points

**Algorithm**:

1. **Input**: B+Tree with root_page_id, search_key
2. **Tree Traversal**:
   - Follow same traversal as point query
   - Record SearchPath
3. **Leaf Node Search with Successor Logic**:
   - Perform binary search on leaf node keys
   - **If exact match found**:
     - Return found: true, value: matched_value, key_index: match_index
   - **If no exact match**:
     - Binary search returns key_index = insertion_point
     - If insertion_point < num_keys:
       - Successor is at index insertion_point
       - Return found: false, value: successor_value, key_index: insertion_point
     - Else (insertion_point == num_keys):
       - Successor does not exist in this leaf (search key is greater than all keys in this leaf)
       - Need to traverse to right sibling leaf
4. **Right Sibling Traversal** (if needed):
   - Follow right_sibling_page_id pointer in leaf header
   - If right_sibling_page_id != 0:
     - Read right sibling page
     - Return first entry (index 0) from right sibling
   - Else:
     - No successor exists (search key is larger than all keys in tree)
     - Return found: false, value: None, key_index: num_keys

**Time Complexity**: O(log N + 1) for sibling traversal

**Space Complexity**: O(h) for SearchPath

**Return**: SearchResult with successor value or None if no successor exists

**Error Conditions**:
- Same as point query
- InvalidSiblingPointer: Right sibling pointer is invalid

**Concurrency**: Read-only, safe for concurrent execution

## Key Comparison Logic

### Comparison Function

**Purpose**: Define ordering semantics for keys to enable binary search

**Algorithm**:

1. **Input**: key1: &[u8], key2: &[u8]
2. **Lexicographic Comparison**:
   - Iterate through both byte arrays simultaneously
   - Compare byte1[i] with byte2[i]:
     - If byte1[i] < byte2[i]: return Less (-1)
     - If byte1[i] > byte2[i]: return Greater (1)
     - If equal: continue to next byte
3. **Length Comparison**:
   - If all compared bytes are equal:
     - If key1.len() < key2.len(): return Less (-1)
     - If key1.len() > key2.len(): return Greater (1)
     - Else: return Equal (0)
4. **Result**:
   - Return -1 for Less, 0 for Equal, 1 for Greater

**Properties**:
- **Transitive**: If a < b and b < c, then a < c
- **Antisymmetric**: If a < b, then not(b < a)
- **Total**: For any a, b, exactly one of a < b, a = b, a > b is true

**Rationale**: Lexicographic byte ordering enables consistent key ordering across all tree operations

### Comparison Optimization

**Purpose**: Minimize comparison cost for frequently accessed keys

**Strategies**:

1. **Prefix Caching**: Cache common key prefixes to avoid repeated byte comparisons
2. **Length Check First**: Compare key lengths before byte-by-byte comparison (early exit for different lengths)
3. **SIMD Comparison**: Use SIMD instructions to compare 16/32 bytes at a time for longer keys
4. **Hash-Based Pruning**: Compute key hash and compare hashes before full byte comparison (cheap inequality detection)

**Trade-offs**:
- Optimization increases code complexity
- Hash-based pruning requires hash field in key entries (increases storage)
- SIMD requires CPU feature detection and fallback

## Invariants

### Search Invariants

1. **Path Validity**: Every node in SearchPath must be a valid ancestor of the leaf node
2. **Monotonic Descent**: Tree traversal must always move from parent to child (never sideways or up)
3. **Key Ordering**: All keys in left subtree < separator key < all keys in right subtree
4. **Leaf Level**: All search paths must terminate at leaf level (level 0 in header)
5. **Separator Consistency**: Separator keys in internal nodes must be present in leaf nodes (for exact match searches)

### Binary Search Invariants

1. **Sorted Order**: Arrays must be sorted in ascending order before binary search
2. **Range Invariant**: At each iteration, search key (if present) is within range [low, high]
3. **Termination**: Binary search must terminate (low and high converge)
4. **Insertion Point**: If key not found, low is the correct insertion point to maintain sorted order

### Result Invariants

1. **Found Results**: If found is true, value must be Some (not None)
2. **Not Found Results**: If found is false, value must be None
3. **Key Index Validity**: key_index must be in range [0, num_keys]
4. **Path Completeness**: SearchPath must contain all nodes from root to leaf parent (not including leaf itself)

## Dependencies

**Uses**:
- NodeHeader (06-btree-header.md) for node type detection and validation
- Internal node structure (06-btree-node.md) for separator and child array access
- Leaf node structure (06-btree-node.md) for key and value array access
- Pager module for page read operations
- CRC32C checksum module for node validation
- Key type (01-key-value-types.md) for comparison logic

**Used By**:
- Get operation (read transaction lookup)
- Insert operation (to find insertion point)
- Delete operation (to find key to delete)
- Range scan (to find scan start point)
- Split operation (to find split point)
- Merge operation (to find merge target)

## Rust Implementation Guidance

### Module Structure

The search functionality should be organized as:
- `northstar_core::tree::search::binary_search_internal` - Internal node binary search
- `northstar_core::tree::search::binary_search_leaf` - Leaf node binary search
- `northstar_core::tree::search::search_tree` - Full tree search (point query)
- `northstar_core::tree::search::search_predecessor` - Predecessor search
- `northstar_core::tree::search::search_successor` - Successor search

### Type Definitions

**SearchDirection**: Implement as Rust enum:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchDirection {
    Exact,
    Predecessor,
    Successor,
    Both,
}
```

**SearchResult**: Implement as struct with optional value:
```rust
pub struct SearchResult {
    pub found: bool,
    pub value: Option<Value>,
    pub leaf_page_id: PageId,
    pub key_index: u16,
    pub path: SearchPath,
    pub stats: SearchStats,
}
```

**SearchPath**: Implement as struct with vector:
```rust
pub struct SearchPath {
    pub nodes: Vec<(PageId, u16)>, // (page_id, child_index)
    pub root_page_id: PageId,
    pub depth: u16,
}
```

**SearchStats**: Implement as struct:
```rust
pub struct SearchStats {
    pub nodes_visited: u32,
    pub pages_read: u32,
    pub comparisons: u32,
    pub duration_us: u64,
}
```

### Binary Search Implementation

Use standard Rust binary search pattern:
```rust
pub fn binary_search_internal(
    separators: &[Key],
    child_ptrs: &[PageId],
    search_key: &Key,
) -> Result<PageId, SearchError> {
    if separators.is_empty() {
        return Err(SearchError::EmptyInternalNode);
    }

    let mut low = 0;
    let mut high = separators.len() - 1;

    while low <= high {
        let mid = low + (high - low) / 2;
        match search_key.cmp(&separators[mid]) {
            Ordering::Less => {
                if mid == 0 {
                    break;
                }
                high = mid - 1;
            }
            Ordering::Greater => {
                low = mid + 1;
            }
            Ordering::Equal => {
                // Exact match with separator, go to right child
                return Ok(child_ptrs[mid + 1]);
            }
        }
    }

    // No exact match, low is insertion point
    Ok(child_ptrs[low])
}
```

**Leaf Binary Search**:
```rust
pub fn binary_search_leaf(
    keys: &[Key],
    values: &[Value],
    search_key: &Key,
) -> SearchResult {
    let mut low = 0;
    let mut high = keys.len() - 1;

    while low <= high {
        let mid = low + (high - low) / 2;
        match search_key.cmp(&keys[mid]) {
            Ordering::Less => {
                high = mid - 1;
            }
            Ordering::Greater => {
                low = mid + 1;
            }
            Ordering::Equal => {
                return SearchResult {
                    found: true,
                    value: Some(values[mid].clone()),
                    key_index: mid as u16,
                };
            }
        }
    }

    // Not found
    SearchResult {
        found: false,
        value: None,
        key_index: low as u16,
    }
}
```

### Key Comparison

Implement `Ord` trait for Key type:
```rust
impl Ord for Key {
    fn cmp(&self, other: &Self) -> Ordering {
        // Lexicographic byte comparison
        let min_len = self.0.len().min(other.0.len());
        for i in 0..min_len {
            match self.0[i].cmp(&other.0[i]) {
                Ordering::Equal => continue,
                other => return other,
            }
        }
        // All compared bytes equal, compare lengths
        self.0.len().cmp(&other.0.len())
    }
}

impl PartialOrd for Key {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
```

### Full Tree Search

Implement iterative traversal:
```rust
pub fn search_tree(
    tree: &BTree,
    search_key: &Key,
) -> Result<SearchResult, SearchError> {
    let mut current_page_id = tree.root_page_id;
    let mut path = SearchPath::new(tree.root_page_id);
    let mut stats = SearchStats::new();
    let start_time = Instant::now();

    loop {
        stats.nodes_visited += 1;

        // Read page from pager
        let page = tree.pager.read_page(current_page_id)?;

        // Validate header
        let header = NodeHeader::from_bytes(page.data());
        header.validate(current_page_id)?;

        match header.get_node_type()? {
            NodeType::Internal | NodeType::RootInternal => {
                let internal_node = InternalNode::from_bytes(page.data());
                let child_page_id = internal_node.binary_search(search_key, &mut stats)?;
                path.push(current_page_id, child_index);
                current_page_id = child_page_id;
            }
            NodeType::Leaf | NodeType::RootLeaf => {
                let leaf_node = LeafNode::from_bytes(page.data());
                let result = leaf_node.binary_search(search_key, &mut stats)?;
                stats.duration_us = start_time.elapsed().as_micros() as u64;
                return Ok(SearchResult {
                    found: result.found,
                    value: result.value,
                    leaf_page_id: current_page_id,
                    key_index: result.key_index,
                    path,
                    stats,
                });
            }
        }
    }
}
```

### Error Handling

Define comprehensive error types:
```rust
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error("Tree is empty (no root page)")]
    TreeEmpty,

    #[error("Root page {0} does not exist")]
    InvalidRootPage(PageId),

    #[error("Node {0} validation failed: {1}")]
    CorruptNode(PageId, String),

    #[error("Invalid node type: {0}")]
    InvalidNodeType(u8),

    #[error("Internal node has no separator keys")]
    EmptyInternalNode,

    #[error("Child pointer is null or invalid")]
    InvalidChildPointer,

    #[error("Separator keys are not sorted (corruption detected)")]
    CorruptSeparators,

    #[error("Cannot navigate to sibling: {0}")]
    SiblingNavigationFailed(String),
}
```

### Key Decisions

**Iterative vs Recursive Traversal**: Use iterative traversal (loop with manual stack) instead of recursion to avoid stack overflow for very tall trees and to enable SearchPath recording.

**Early Exit on Exact Match**: During leaf search, return immediately upon finding exact match rather than continuing search. This optimizes the common case of point lookups.

**SearchPath Allocation**: Pre-allocate SearchPath with capacity equal to maximum tree height (typically < 10) to avoid reallocation during traversal.

**Comparison Counting**: Increment comparison counter in binary search for performance monitoring. This has negligible overhead and provides valuable metrics.

**Sibling Traversal**: For predecessor/successor searches that require sibling navigation, use parent pointers from SearchPath rather than following sibling pointers backwards (which is inefficient for left sibling).

### Implementation Notes

1. **Cache-Aware Search**: Binary search has poor cache behavior for large arrays. Consider linear search for small arrays (e.g., < 32 entries) due to better cache locality.
   ```rust
   if num_keys < LINEAR_SEARCH_THRESHOLD {
       return linear_search(keys, values, search_key);
   }
   ```

2. **SIMD Comparison**: For longer keys, use SIMD instructions to compare multiple bytes at once:
   ```rust
   #[cfg(target_arch = "x86_64")]
   use std::arch::x86_64::*;

   unsafe fn simd_compare(a: &[u8], b: &[u8]) -> Ordering {
       // Compare 16 bytes at a time using SSE2
       // Fallback to byte-by-byte for remainder
   }
   ```

3. **Key Prefix Caching**: Cache frequently accessed key prefixes to avoid repeated comparisons:
   ```rust
   struct KeyCache {
       common_prefixes: HashMap<(PageId, u16), Vec<u8>>,
   }
   ```

4. **Read-Only Optimization**: Since search is read-only, take shared references (&self) rather than mutable references (&mut self). This enables concurrent searches.

5. **Node Validation**: Validate node header on every read from disk (checksum, magic) but skip validation for cached nodes (already validated).

6. **SearchPath Reuse**: For insert/delete operations, reuse SearchPath from search to avoid retraversing the tree.

7. **Page Prefetching**: Prefetch child pages during traversal to hide I/O latency:
   ```rust
   // Prefetch next level while processing current level
   if let Some(next_page_id) = peek_next_child() {
       pager.prefetch_page(next_page_id);
   }
   ```

8. **Empty Tree Handling**: Return TreeEmpty error immediately if root_page_id is 0, rather than attempting to read page 0.

### Testing Strategy

**Unit tests needed for**:
- Binary search on internal nodes with various separator counts (1, 10, 100, 1000)
- Binary search on leaf nodes with various entry counts
- Search key found at beginning, middle, end of array
- Search key not found (less than all, greater than all, between entries)
- Empty tree search (return error)
- Single node tree search (root is leaf)
- Very tall tree search (stress test SearchPath)
- Predecessor search with/without left sibling traversal
- Successor search with/without right sibling traversal
- Key comparison with various lengths (empty, short, long)
- Key comparison with common prefixes

**Property tests for**:
- Binary search always finds existing keys
- Binary search returns correct insertion point for non-existent keys
- Search path is valid (all nodes are ancestors)
- Search terminates (no infinite loops)
- Predecessor key < search key <= successor key (when both exist)
- Found results always have Some(value)
- Not found results always have None value

**Integration scenarios**:
- Search after insert (verify new key is found)
- Search after delete (verify deleted key not found)
- Search during concurrent inserts (verify consistency)
- Search on corrupted tree (detect and report corruption)
- Search performance with various tree sizes and heights

**Fuzzing targets**:
- Malformed keys (invalid UTF-8, extremely long keys)
- Corrupted separator arrays (unsorted, duplicates)
- Invalid node types
- Null or invalid page IDs
- Circular sibling pointers

**Performance benchmarks**:
- Search latency for various tree sizes (1K, 1M, 1B keys)
- Cache hit/miss ratios for upper vs lower tree levels
- Comparison count distribution
- Disk I/O count during search
- Concurrent search throughput (multiple threads searching simultaneously)

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and search overview
- **06-btree-node.md**: Internal and leaf node structures for search targets
- **06-btree-header.md**: Node header validation during search
- **06-btree-insert.md**: Uses search to find insertion point
- **06-btree-delete.md**: Uses search to find key to delete
- **06-btree-scan.md**: Uses predecessor/successor search for range navigation
- **01-key-value-types.md**: Key type and comparison semantics
