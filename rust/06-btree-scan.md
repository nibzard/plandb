# B+Tree Range Scan

## Purpose

Range scan operations iterate over all key-value pairs within a specified key range [start, end), leveraging the B+Tree leaf node linked list for efficient sequential access. Range scans are fundamental for queries that process multiple keys, such as prefix queries, range queries, and full table scans. This specification describes the range scan algorithm, including start key positioning, iteration strategy, leaf traversal, snapshot visibility, and integration with the MVCC system.

## Types

### ScanRange

**Description**: Defines the key range for scan operation

**Fields**:

1. **start_key** (Option<Vec<u8>>, variable)
   - **Purpose**: Lower bound of scan range (inclusive)
   - **Value**: Some(key_bytes) for bounded range, None for unbounded (minimum key)
   - **Invariant**: If Some, key must be valid byte array
   - **Semantics**: Scan starts at first key >= start_key

2. **end_key** (Option<Vec<u8>>, variable)
   - **Purpose**: Upper bound of scan range (exclusive)
   - **Value**: Some(key_bytes) for bounded range, None for unbounded (maximum key)
   - **Invariant**: If Some, key must be valid byte array
   - **Semantics**: Scan stops at first key >= end_key

3. **start_inclusive** (bool, 1 byte)
   - **Purpose**: Whether start_key is inclusive (true) or exclusive (false)
   - **Value**: true (inclusive) by default
   - **Default**: true
   - **Semantics**: If true, include start_key if it exists

4. **end_inclusive** (bool, 1 byte)
   - **Purpose**: Whether end_key is inclusive (true) or exclusive (false)
   - **Value**: false (exclusive) by default
   - **Default**: false
   - **Semantics**: If true, include end_key if it exists

**Size**: Variable (depends on key lengths)

### ScanOptions

**Description**: Configuration options for scan operation behavior

**Fields**:

1. **reverse** (bool, 1 byte)
   - **Purpose**: Scan in reverse key order (descending)
   - **Value**: false for forward scan (ascending), true for reverse scan
   - **Default**: false
   - **Semantics**: If true, iterate from high to low keys

2. **max_results** (Option<usize>, 8 bytes)
   - **Purpose**: Maximum number of results to return
   - **Value**: Some(limit) to limit results, None for unlimited
   - **Default**: None (unlimited)
   - **Semantics**: Stop iteration after yielding max_results entries

3. **skip_deleted** (bool, 1 byte)
   - **Purpose**: Whether to skip entries marked as deleted
   - **Value**: true to skip tombstones, false to include them
   - **Default**: true
   - **Semantics**: If true, deleted entries not yielded to caller

4. **snapshot_lsn** (Lsn, 8 bytes)
   - **Purpose**: LSN of snapshot for MVCC visibility
   - **Value**: Valid LSN from snapshot
   - **Invariant**: Must be valid committed LSN
   - **Semantics**: Only yield entries with LSN <= snapshot_lsn

**Size**: Approximately 18 bytes

### ScanResult

**Description**: Result type returned by scan operation

**Fields**:

1. **key** (Vec<u8>, variable)
   - **Purpose**: Key of current entry
   - **Value**: Valid key byte array
   - **Invariant**: Key within scan range

2. **value** (Vec<u8>, variable)
   - **Purpose**: Value of current entry
   - **Value**: Valid value byte array (or empty if deleted)
   - **Invariant**: Value visible to snapshot (LSN <= snapshot_lsn)

3. **lsn** (Lsn, 8 bytes)
   - **Purpose**: LSN of this entry version
   - **Value**: Valid LSN
   - **Invariant**: lsn <= snapshot_lsn

**Size**: Variable (depends on key and value lengths)

### ScanStats

**Description**: Statistics collected during scan operation

**Fields**:

1. **entries_scanned** (u64, 8 bytes)
   - **Purpose**: Total entries examined (including skipped)
   - **Value**: Non-negative counter
   - **Increment**: Incremented for each entry visited

2. **entries_returned** (u64, 8 bytes)
   - **Purpose**: Total entries yielded to caller
   - **Value**: Non-negative counter
   - **Increment**: Incremented for each result returned

3. **pages_read** (u64, 8 bytes)
   - **Purpose**: Total leaf pages read during scan
   - **Value**: Non-negative counter
   - **Increment**: Incremented for each unique leaf page accessed

4. **bytes_read** (u64, 8 bytes)
   - **Purpose**: Total bytes read from leaf pages
   - **Value**: Non-negative counter
   - **Increment**: Incremented by page size for each page read

5. **scan_duration_ms** (u64, 8 bytes)
   - **Purpose**: Wall-clock time of scan operation
   - **Value**: Milliseconds elapsed
   - **Measurement**: Recorded from start to end of scan

**Size**: 40 bytes

## Functions

### Range Scan Entry Point

**scan(tree: BTree, range: ScanRange, options: ScanOptions) -> ScanIterator**

**Purpose**: Create iterator for range scan over B+Tree

**Algorithm**:
1. **Validate Scan Range**:
   a. Check if start_key and end_key are valid (if provided)
   b. If start_key > end_key (both provided), return empty iterator
   c. Validate options (snapshot_lsn must be valid)

2. **Position Scan at Start**:
   a. If start_key is None:
      i. Position at leftmost (minimum) key in tree
      ii. Traverse from root to leftmost leaf
      iii. Set current position to first entry in leftmost leaf
   b. If start_key is Some:
      i. Search for start_key using tree search algorithm
      ii. If exact match found: position at that entry
      iii. If not found: position at next key > start_key
      iv. If start_key > all keys: return empty iterator (no results)

3. **Initialize Scan State**:
   a. Create ScanIterator with:
      - current_page_id (leaf containing start position)
      - current_index (entry index within leaf)
      - remaining_range (end_key and bounds)
      - options (scan configuration)
      - stats (zero-initialized statistics)

4. **Return Iterator**:
   a. Return ScanIterator ready to yield first result
   b. Iterator will yield entries on next() calls

**Returns**: ScanIterator for iterating over scan results

**Error Conditions**: None (scan always succeeds, may return empty iterator)

**Concurrency**: Read-only (safe for concurrent reads with other scans)

### Leaf Traversal

**find_start_leaf(tree: BTree, start_key: Option<&[u8]>) -> Option<(PageId, usize)>**

**Purpose**: Locate leaf page and entry index for scan start position

**Algorithm**:
1. **If start_key is None** (unbounded start):
   a. Start at root node
   b. While current node is internal:
      i. Follow leftmost child pointer (child[0])
      ii. Read child node from Pager
   c. Current node is leftmost leaf
   d. Return (leaf_page_id, 0) (first entry in leftmost leaf)

2. **If start_key is Some** (bounded start):
   a. Search for start_key using tree search algorithm
   b. Traverse from root to leaf containing start_key
   c. Perform binary search within leaf for start_key
   d. If exact match found:
      i. Return (leaf_page_id, entry_index)
   e. If no exact match found:
      i. Binary search returns insertion point (first key > start_key)
      ii. Return (leaf_page_id, insertion_index)
   f. If start_key greater than all keys in tree:
      i. Return None (empty scan)

**Returns**: Some((leaf_page_id, entry_index)) for valid start, None for empty scan

**Error Conditions**: None (returns None if start position not found)

**Concurrency**: Read-only (safe for concurrent reads)

### Scan Iteration

**next_scan(iter: ScanIterator) -> Option<ScanResult>**

**Purpose**: Advance scan iterator and return next result

**Algorithm**:
1. **Check Scan Completion**:
   a. If iterator exhausted, return None
   b. If max_results reached, return None

2. **Check Range Bounds**:
   a. If current_key >= end_key (exclusive), return None
   b. If current_key > end_key (inclusive), return None
   c. If end_key is None, no upper bound check

3. **Read Current Entry**:
   a. Read current leaf page from Pager (if not cached)
   b. Access entry at current_index
   c. Extract key, value, and LSN from entry

4. **Check Visibility**:
   a. Check entry.lsn <= snapshot_lsn
   b. If not visible: skip to next entry, recurse to step 2
   c. If visible: continue to step 5

5. **Check Deletion Flag**:
   a. If skip_deleted option is true and entry is deleted:
      i. Skip to next entry, recurse to step 2
   b. If entry not deleted or skip_deleted is false:
      i. Continue to step 6

6. **Yield Result**:
   a. Create ScanResult with key, value, lsn
   b. Increment stats.entries_returned
   c. Advance iterator to next entry (see advance iterator below)
   d. Return Some(ScanResult)

7. **Advance Iterator**:
   a. Increment current_index by 1
   b. If current_index >= leaf.entry_count:
      i. Move to next leaf: current_page_id = leaf.next_leaf
      ii. Set current_index = 0 (first entry in next leaf)
      iii. If next_leaf is 0 (rightmost): mark iterator exhausted
   c. Increment stats.entries_scanned

**Returns**: Some(ScanResult) for next result, None if exhausted

**Error Conditions**: None (returns None on exhaustion or I/O error)

**Concurrency**: Read-only (safe for concurrent reads)

### Reverse Scan Iteration

**next_scan_reverse(iter: ScanIterator) -> Option<ScanResult>**

**Purpose**: Advance reverse scan iterator and return previous result

**Algorithm**:
1. **Check Scan Completion**:
   a. If iterator exhausted, return None
   b. If max_results reached, return None

2. **Check Range Bounds**:
   a. If current_key < end_key (exclusive), return None
   b. If current_key <= end_key (inclusive), return None
   c. If end_key is None, no lower bound check

3. **Read Current Entry**:
   a. Read current leaf page from Pager (if not cached)
   b. Access entry at current_index
   c. Extract key, value, and LSN from entry

4. **Check Visibility**:
   a. Check entry.lsn <= snapshot_lsn
   b. If not visible: skip to previous entry, recurse to step 2
   c. If visible: continue to step 5

5. **Check Deletion Flag**:
   a. If skip_deleted option is true and entry is deleted:
      i. Skip to previous entry, recurse to step 2
   b. If entry not deleted or skip_deleted is false:
      i. Continue to step 6

6. **Yield Result**:
   a. Create ScanResult with key, value, lsn
   b. Increment stats.entries_returned
   c. Advance iterator to previous entry (see advance reverse iterator below)
   d. Return Some(ScanResult)

7. **Advance Iterator (Reverse)**:
   a. Decrement current_index by 1
   b. If current_index < 0 (wrapped around):
      i. Move to previous leaf: current_page_id = leaf.prev_leaf
      ii. Set current_index = leaf.entry_count - 1 (last entry in prev leaf)
      iii. If prev_leaf is 0 (leftmost): mark iterator exhausted
   c. Increment stats.entries_scanned

**Returns**: Some(ScanResult) for next result, None if exhausted

**Error Conditions**: None (returns None on exhaustion or I/O error)

**Concurrency**: Read-only (safe for concurrent reads)

### Statistics Collection

**collect_scan_stats(iter: ScanIterator) -> ScanStats**

**Purpose**: Collect statistics from completed or in-progress scan

**Algorithm**:
1. **Create ScanStats** with current iterator state:
   a. entries_scanned = iter.stats.entries_scanned
   b. entries_returned = iter.stats.entries_returned
   c. pages_read = iter.stats.pages_read
   d. bytes_read = iter.stats.bytes_read
   e. scan_duration_ms = current_time() - iter.start_time

2. **Return Statistics**:
   a. Return ScanStats structure

**Returns**: ScanStats with all collected metrics

**Error Conditions**: None (statistics collection always succeeds)

**Concurrency**: Read-only (safe to call during scan)

## Invariants

### Scan Range Invariants

1. **Range Validity**: If both start_key and end_key specified, start_key <= end_key
2. **Empty Range Handling**: If start_key > end_key, scan yields no results
3. **Unbounded Ranges**: None for start_key means minimum key, None for end_key means maximum key
4. **Inclusive/Exclusive Semantics**: Start inclusive by default, end exclusive by default

### Iterator State Invariants

1. **Valid Position**: current_page_id and current_index always point to valid entry (or exhausted)
2. **Forward Progress**: Iterator advances monotonically (forward or reverse)
3. **No Revisit**: Iterator never yields the same entry twice
4. **Range Adherence**: Iterator never yields entries outside specified range

### Visibility Invariants

1. **Snapshot Consistency**: All yielded entries have LSN <= snapshot_lsn
2. **Monotonic Keys**: Keys yielded in strictly increasing order (forward) or decreasing order (reverse)
3. **Deletion Handling**: Tombstones skipped if skip_deleted is true
4. **Version Resolution**: If multiple versions exist, correct version for snapshot_lsn yielded

### Performance Invariants

1. **Leaf Traversal**: Scan follows leaf linked list, no backtracking to parent nodes
2. **Page Cache**: Each leaf page read at most once per scan
3. **Sequential I/O**: Forward scans benefit from sequential I/O patterns
4. **Stats Accuracy**: Statistics accurately reflect scan operation

## Dependencies

**Uses**:
- BTree structure: Root page ID, tree height
- Node structures: LeafNode, InternalNode, NodeHeader
- Search algorithms: Binary search within nodes, tree traversal
- Pager module: Read leaf pages, access page cache
- MVCC system: Snapshot LSN, version resolution
- Error types module: IOError, CorruptionError

**Used By**:
- Transaction read operations: Range queries within transaction
- Database API: Public range scan interface
- Query execution: SQL range queries, key-value scans
- Backup operations: Full or partial database dump
- Compaction operations: Scan and rewrite key ranges

## Rust Implementation Guidance

### Module Structure

Range scan implementation should be in:
- `northstar_core::tree::scan::scan()` - Main scan entry point
- `northstar_core::tree::scan::find_start_leaf()` - Start position location
- `northstar_core::tree::scan::next_scan()` - Forward iteration
- `northstar_core::tree::scan::next_scan_reverse()` - Reverse iteration
- `northstar_core::tree::scan::ScanIterator` - Iterator state and implementation
- `northstar_core::tree::scan::ScanRange` - Range type
- `northstar_core::tree::scan::ScanOptions` - Options type
- `northstar_core::tree::scan::ScanResult` - Result type
- `northstar_core::tree::scan::ScanStats` - Statistics type

### Type Definitions

**ScanRange**: Represent as struct with optional bounds:
```rust
pub struct ScanRange {
    pub start_key: Option<Vec<u8>>,
    pub end_key: Option<Vec<u8>>,
    pub start_inclusive: bool,
    pub end_inclusive: bool,
}
```

**ScanOptions**: Represent as struct with configuration:
```rust
pub struct ScanOptions {
    pub reverse: bool,
    pub max_results: Option<usize>,
    pub skip_deleted: bool,
    pub snapshot_lsn: Lsn,
}
```

**ScanResult**: Represent as struct with entry data:
```rust
pub struct ScanResult {
    pub key: Vec<u8>,
    pub value: Vec<u8>,
    pub lsn: Lsn,
}
```

**ScanIterator**: Implement as struct with state and Iterator trait:
```rust
pub struct ScanIterator {
    current_page_id: PageId,
    current_index: usize,
    range: ScanRange,
    options: ScanOptions,
    stats: ScanStats,
    exhausted: bool,
}

impl Iterator for ScanIterator {
    type Item = ScanResult;
    fn next(&mut self) -> Option<Self::Item>;
}
```

### Key Decisions

**Iterator Implementation**: Use Rust Iterator trait for ergonomic usage. ScanIterator holds state and yields ScanResult on next() calls. Implement DoubleEndedIterator for reverse iteration support.

**Lazy Evaluation**: Read leaf pages on-demand as iterator advances. Don't read entire range into memory. Use Pager page cache to avoid re-reading pages.

**Visibility Checking**: Check MVCC visibility (LSN <= snapshot_lsn) during iteration, not upfront. Skip invisible entries without yielding them. Maintain snapshot consistency throughout scan.

**Snapshot Isolation**: Scan operates at consistent snapshot LSN. Even if concurrent commits modify keys in range, scan sees only state at snapshot_lsn. No blocking of concurrent writers.

**Reverse Traversal**: Use prev_leaf pointers for reverse scans. Start at rightmost leaf for unbounded reverse range. Follow prev pointers backwards. Be careful with underflow (current_index < 0).

**Statistics Collection**: Track all statistics in ScanIterator struct. Update counters on each operation. Provide accessor method to retrieve stats. Consider zero-cost statistics (conditional compilation) for production.

**Error Handling**: Don't expose I/O errors through Iterator interface. Log errors and return None (iterator exhausted). Caller can check ScanStats for error indications (e.g., pages_read = 0 but expected results).

**Memory Efficiency**: Avoid buffering results. Yield each entry immediately. Use zero-copy reads where possible (reference page buffer). Clone key/value only when creating ScanResult.

### Implementation Notes

1. **Start Positioning**: For unbounded start (None), traverse to leftmost leaf. For bounded start, binary search for start_key within leaf. If start_key not found, position at next key > start_key (insertion point).

2. **Range Boundary Checks**: Check end_key condition before yielding result. For exclusive end, stop when key >= end_key. For inclusive end, stop when key > end_key. Support both via end_inclusive flag.

3. **Leaf Linked List Traversal**: Forward scans follow next_leaf pointers. When current_index >= leaf.entry_count, move to next leaf and set current_index = 0. Stop when next_leaf = 0 (rightmost).

4. **Reverse Scan Considerations**: Reverse scans follow prev_leaf pointers. When current_index < 0 (after decrement), move to prev leaf and set current_index = leaf.entry_count - 1 (last entry). Stop when prev_leaf = 0 (leftmost).

5. **Visibility and Versioning**: For each entry, check LSN against snapshot_lsn. If entry has multiple versions (version chain), traverse chain to find visible version. Only yield if visible version found and not deleted (or skip_deleted is false).

6. **Deletion Handling**: If skip_deleted is true, check entry deletion status. Tombstone entries (marked deleted) are skipped without yielding. If skip_deleted is false, deleted entries yielded with empty value or deletion marker.

7. **Page Cache Integration**: Use Pager page cache to avoid redundant I/O. Each leaf page read once per scan. Page cache benefits concurrent scans accessing same ranges.

8. **Statistics Tracking**: Increment counters on every relevant operation:
   - entries_scanned: Every entry visited (including skipped)
   - entries_returned: Every entry yielded to caller
   - pages_read: Every unique leaf page read
   - bytes_read: pages_read * page_size
   - scan_duration_ms: current_time - start_time

9. **Max Results Limiting**: If max_results is Some(limit), stop iteration after yielding limit entries. Check before advancing iterator. Include in ScanStats for transparency.

10. **Empty Range Handling**: If start_key > end_key (both bounded), return empty iterator immediately. No tree traversal needed. This is an optimization and also validates range semantics.

11. **Concurrent Modifications**: Scan is isolated from concurrent writes by MVCC. Readers see snapshot state. Writers don't block readers. Iterator may see stale data but never inconsistent data.

12. **Performance Optimizations**:
    - Batch I/O by prefetching next leaf page
    - Use sequential read pattern for forward scans
    - Consider memory-mapped I/O for large scans
    - Limit memory usage by avoiding buffering

### Testing Strategy

**Unit tests needed for**:
- Empty range scan (start_key > end_key)
- Unbounded start scan (None to end_key)
- Unbounded end scan (start_key to None)
- Full table scan (None to None)
- Bounded range scan (start_key to end_key)
- Inclusive vs exclusive bounds
- Forward scan iteration order
- Reverse scan iteration order
- Start key found (exact match)
- Start key not found (position at next key)
- End key boundary condition (stop before/at end)
- Single page range scan
- Multi-page range scan (follow next pointers)
- Snapshot visibility filtering
- Deleted entry skipping (skip_deleted true/false)
- Max results limiting
- Statistics collection accuracy
- Iterator exhaustion behavior

**Property tests for**:
- Scan yields results in strictly increasing key order (forward)
- Scan yields results in strictly decreasing key order (reverse)
- Scan never yields same entry twice
- Scan never yields entries outside range
- All yielded entries have LSN <= snapshot_lsn
- Scan results consistent with repeated scans at same LSN
- Empty scan if range empty (start_key > end_key)
- Stats match actual scan behavior

**Integration scenarios**:
- Scan with concurrent insert (scan unaffected)
- Scan with concurrent delete (scan unaffected)
- Scan with page cache hits (avoid redundant I/O)
- Large range scan across many pages
- Scan during checkpoint (pages may be flushed)
- Scan after tree growth (height increased)
- Scan after tree shrink (height decreased)
- Multiple concurrent scans (no interference)
- Scan with very large keys/values

**Performance tests**:
- Measure scan throughput (entries/second)
- Measure scan latency for various range sizes
- Compare cached vs uncached scan performance
- Benchmark sequential I/O vs random I/O
- Test scan scalability with increasing tree size
- Verify scan latency meets SLA requirements

**Edge case tests**:
- Scan empty tree (no results)
- Scan single entry tree
- Scan range with all deleted entries (no results if skip_deleted)
- Scan range with only invisible entries (no results for snapshot)
- Scan with start_key = end_key (single key or empty)
- Scan with reverse direction on single page
- Scan with max_results = 0 (empty)
- Scan with corrupted leaf page (error handling)

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and scan operations
- **06-btree-node.md**: Leaf node structure and linked list pointers
- **06-btree-search.md**: Search algorithms for start key positioning
- **06-btree-iterator.md**: Detailed iterator state machine and operations
- **05-snapshot-vis.md**: MVCC visibility calculation for snapshot LSN
- **04-txn-get.md**: Transaction integration with scan operations
- **02-pager-read.md**: Pager page cache integration for scan I/O
