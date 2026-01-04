# B+Tree Value Storage Strategy

## Purpose

This specification defines how values are stored within the B+Tree leaf nodes. Values are the actual data associated with each key and can range from a few bytes to many megabytes. The storage strategy balances space efficiency, access performance, and implementation complexity. Small values are stored inline within the leaf node for fast access, while large values overflow to separate page chains to avoid wasting space and reducing node capacity.

## Types

### Value

**Description**: Variable-length byte array representing the data associated with a key. Values are opaque byte sequences with no interpretation by the B+Tree structure itself.

**Size**: Variable length, 0 to 16,777,215 bytes (16MB - 1)

**Structure**:
- **Length prefix** (u16, 2 bytes): Number of bytes in the value data
- **Value data** (byte array, 0-16,777,215 bytes): Raw value bytes OR overflow page ID

**Alignment**: None (byte-aligned)

**Invariants**:
- Value length must be between 0 and MAX_VALUE_SIZE (16,777,215)
- Empty values (length 0) are allowed
- Value bytes stored exactly as provided, no transformation
- If value fits inline, value bytes stored directly
- If value overflows, length field set to 0xFFFF and overflow_page_id stored instead

### InlineValue

**Description**: Value small enough to be stored directly within the leaf node alongside its key. Most common case for typical workloads.

**Size**: Variable length, 0 to INLINE_THRESHOLD bytes (default ~2000 bytes)

**Storage Location**: Within leaf node entry, immediately following key

**Invariants**:
- Value length <= INLINE_THRESHOLD
- Value bytes stored contiguously in node
- No additional page references needed

### OverflowValue

**Description**: Value too large to store inline, stored in separate page chain. Leaf entry stores page ID of first overflow page.

**Size**: Variable length, INLINE_THRESHOLD + 1 to MAX_VALUE_SIZE bytes

**Storage Location**: Chain of dedicated overflow pages

**Invariants**:
- Value length > INLINE_THRESHOLD
- Value bytes spread across multiple overflow pages
- Leaf entry stores overflow_page_id (u64) instead of value bytes
- Overflow pages linked via next_page pointers

### OverflowPage

**Description**: Dedicated page for storing large value data. Forms singly-linked list for values spanning multiple pages.

**Size**: Exactly one page (16384 bytes)

**Structure**:
- **Header**: PageHeader with magic 0x4F56464C ("OVFL")
- **next_page** (u64, 8 bytes): Page ID of next overflow page in chain, or 0 if last page
- **data** (byte array, ~16368 bytes): Value data chunk

**Invariants**:
- Magic number must be 0x4F56464C
- next_page is 0 for last page in chain, non-zero otherwise
- All pages in chain except last have next_page != 0
- Total data across all pages equals value length

## Value Encoding

### Inline Value Encoding

**Purpose**: Store value bytes directly in leaf node entry

**Binary Format**:
```
Offset  Size    Field          Description
------  ----    -----          -----------
0       2       value_len      Number of value bytes (0-65534)
2       N       value_bytes    Raw value data (N = value_len)
--      --      --             --
Total:  2+N bytes              Variable length
```

**Example Encodings**:
- Empty value: [0x00, 0x00] (2 bytes)
- Value "hello": [0x00, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F] (7 bytes)
- Value 1000 bytes: [0x03, 0xE8, ...1000 bytes...] (1002 bytes)

**Special Values**:
- value_len = 0x0000: Empty value (0 bytes)
- value_len = 0xFFFF: Overflow marker (not inline, see overflow encoding)

**Advantages**:
- Single page read retrieves both key and value
- No additional I/O for value access
- Simple implementation
- Low overhead (2-byte length prefix)

**Disadvantages**:
- Large values consume excessive node space
- Reduces node capacity (fewer entries per node)
- Increases tree height for same number of keys

### Overflow Value Encoding

**Purpose**: Store reference to overflow page chain for large values

**Binary Format**:
```
Offset  Size    Field              Description
------  ----    -----              -----------
0       2       value_len          0xFFFF (overflow marker)
2       8       overflow_page_id   First overflow page ID
--      --      --                 --
Total:  10 bytes                  Fixed length
```

**Example Encoding**:
- Overflow page 12345: [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x39]

**Reading Overflow Value**:
1. Read leaf entry, detect value_len = 0xFFFF
2. Read overflow_page_id field
3. Read overflow page at overflow_page_id
4. Read data from overflow page
5. Follow next_page pointers to read subsequent pages
6. Concatenate all data chunks to reconstruct full value

**Advantages**:
- Leaf nodes remain compact (10 bytes per large value)
- Node capacity preserved for small values
- Supports arbitrarily large values (up to 16MB)
- Efficient for workloads with mixed value sizes

**Disadvantages**:
- Additional I/O to read overflow pages
- More complex implementation
- Page fragmentation (value may not exactly fill pages)

### Overflow Page Encoding

**Purpose**: Store value data chunks in dedicated pages

**Binary Format**:
```
Offset  Size    Field          Description
------  ----    -----          -----------
0       8       magic          0x4F56464C ("OVFL")
8       8       next_page      Next overflow page ID (0 if last)
16      16368   data           Value data chunk
--      --      --             --
Total:  16384 bytes             One page
```

**Value Distribution Across Pages**:
- First overflow page: First 16368 bytes of value
- Second overflow page: Next 16368 bytes of value
- Last overflow page: Remaining value data (may be less than 16368 bytes)
- Last page detected by next_page = 0

**Calculation**:
- Number of overflow pages = ceil(value_length / 16368)
- Page 0 bytes: min(value_length, 16368)
- Page i bytes (i > 0): min(value_length - i * 16368, 16368)

## Storage Strategy Selection

### INLINE_THRESHOLD

**Purpose**: Boundary between inline and overflow storage

**Default Value**: 2000 bytes

**Rationale**:
- Fits most typical values (strings, JSON documents, binary payloads)
- Leaves ~14KB free in node for keys and other entries
- Balances node capacity vs overflow overhead

**Calculation**:
- For 16KB page with ~600 entry capacity
- Average key size: 16 bytes
- Per-entry overhead: key_len (1) + value_len (2) + lsn (8) = 11 bytes
- Entry total: 16 + 2000 + 11 = 2027 bytes
- Entries per node: floor(16384 / 2027) ≈ 8 entries
- Wait, that's too few! Let me recalculate...

**Recalculation**:
- Leaf node usable space: ~16320 bytes (after 64-byte header)
- Typical entry: 16-byte key + 8-byte LSN + 2-byte lengths = 26 bytes overhead
- Available for value: 16320 / 8 ≈ 2040 bytes per entry (for 8 entries)
- Inline threshold should ensure reasonable node capacity
- 2000-byte threshold → ~7-8 entries per node (acceptable for small workloads)
- For high node capacity, use smaller threshold (e.g., 500 bytes → ~30 entries)

**Tunable Parameter**: INLINE_THRESHOLD configurable per B+Tree instance

**Recommendation**:
- Workloads with small values (< 100 bytes): threshold 500-1000 bytes
- Workloads with medium values (100-1000 bytes): threshold 1000-2000 bytes
- Workloads with large values (> 1000 bytes): threshold 2000-4000 bytes
- Analyze value size distribution in production to optimize

### Storage Decision Algorithm

**should_store_inline(value_length: usize) -> bool**

**Purpose**: Determine whether to store value inline or in overflow pages

**Algorithm**:
1. If value_length <= INLINE_THRESHOLD, return true (inline)
2. If value_length > INLINE_THRESHOLD, return false (overflow)

**Returns**: true if inline storage, false if overflow storage

**Complexity**: O(1) single comparison

**Use Cases**:
- Called on insert to decide storage strategy
- Called on update to determine if existing inline value must move to overflow
- Used for space planning before node modification

### MAX_VALUE_SIZE

**Value**: 16,777,215 bytes (16MB - 1)

**Rationale**:
- Fits in 3-byte length field if needed (V0 uses 2-byte inline length)
- 16MB sufficient for most use cases (documents, images, blobs)
- Prevents runaway values from consuming excessive storage
- Prevents integer overflow in internal calculations

**Alternatives Considered**:
- Unlimited: Risk of out-of-memory, difficult to test
- 4GB (u32 max): Excessive, risks resource exhaustion
- 1MB: Too restrictive for some use cases (large JSON, images)

**Overflow Page Calculation**:
- Max overflow pages for 16MB value: ceil(16,777,215 / 16368) ≈ 1025 pages
- Total storage: 1025 pages × 16KB = ~16MB (reasonable)

## Value Operations

### Value Insert

**insert_value(key: &[u8], value: &[u8], lsn: Lsn) -> Result<(), Error>**

**Purpose**: Insert new key-value pair into tree

**Algorithm**:
1. Validate value length <= MAX_VALUE_SIZE
2. Check should_store_inline(value.len())
3. If inline:
   a. Search tree to find target leaf node
   b. Check leaf has sufficient free space for key + value + LSN
   c. If no space, trigger node split
   d. Insert encoded key and inline value into leaf entry
   e. Update node header (increment num_keys, update free_space)
4. If overflow:
   a. Allocate overflow page chain: num_pages = ceil(value.len() / 16368)
   b. For each page i:
      i. Allocate overflow page from Pager
      ii. Set magic = 0x4F56464C
      iii. Copy value chunk [i*16368, min((i+1)*16368, value.len())] to page data
      iv. Set next_page to next page ID (0 for last page)
   c. Search tree to find target leaf node
   d. Check leaf has sufficient free space for key + overflow_ref (10 bytes) + LSN
   e. If no space, trigger node split
   f. Insert encoded key and overflow reference into leaf entry
   g. Store overflow_page_id in entry
   h. Update node header (increment num_keys, update free_space)

**Error Conditions**:
- ValueTooLarge: value length exceeds MAX_VALUE_SIZE
- AllocationFailed: Pager cannot allocate overflow pages
- NodeFull: Cannot find space in tree even after splits

**Complexity**:
- Inline: O(log n) to find leaf + O(1) to insert
- Overflow: O(log n) to find leaf + O(num_pages) to allocate and write overflow pages

### Value Read

**read_value(key: &[u8], snapshot_lsn: Lsn) -> Result<Option<Vec<u8>>, Error>**

**Purpose**: Retrieve value for key at specific snapshot

**Algorithm**:
1. Search tree for key (see search operations)
2. If key not found, return Ok(None)
3. Read leaf entry containing key
4. Resolve version: find entry with LSN <= snapshot_lsn
5. Check value_len field in entry
6. If value_len != 0xFFFF (inline):
   a. Extract value_bytes from entry
   b. Return Ok(Some(value_bytes.to_vec()))
7. If value_len == 0xFFFF (overflow):
   a. Extract overflow_page_id from entry
   b. Initialize empty buffer with capacity = estimated value size
   c. current_page = overflow_page_id
   d. Loop:
      i. Read overflow page at current_page
      ii. Validate page magic = 0x4F56464C
      iii. Append page.data to buffer
      iv. If page.next_page == 0, break (end of chain)
      v. Set current_page = page.next_page
   e. Return Ok(Some(buffer))

**Error Conditions**:
- NotFound: Key not found in tree
- CorruptionError: Overflow page magic invalid
- IOError: Page read failed

**Complexity**:
- Inline: O(log n) to find leaf + O(1) to extract value
- Overflow: O(log n) to find leaf + O(num_pages) to read overflow chain

**Optimization**: Cache frequently accessed overflow values

### Value Update

**update_value(key: &[u8], new_value: &[u8], lsn: Lsn) -> Result<(), Error>**

**Purpose**: Update existing key with new value (creates new version)

**Algorithm**:
1. Search tree for key
2. If key not found, return NotFound error
3. Read current value entry
4. Check if current value storage type matches new value:
   a. If both inline and new_value fits in existing space:
      i. Replace value bytes in place
      ii. Update LSN
      iii. Recalculate node checksum
   b. If storage type changes (inline to overflow or overflow to inline):
      i. Delete existing entry
      ii. Insert new entry with correct storage type
      iii. If moving inline to overflow, free old inline space
      iv. If moving overflow to inline, free overflow page chain
5. Update node header (free_space)

**Error Conditions**:
- NotFound: Key not found
- ValueTooLarge: New value exceeds MAX_VALUE_SIZE
- AllocationFailed: Cannot allocate overflow pages for new value
- NodeFull: Cannot accommodate new value even after splits

**Complexity**:
- In-place update: O(log n) to find leaf + O(1) to update
- Storage type change: O(log n) + O(num_pages) to allocate/deallocate

### Value Delete

**delete_value(key: &[u8], lsn: Lsn) -> Result<(), Error>**

**Purpose**: Mark key-value pair as deleted (creates tombstone version)

**Algorithm**:
1. Search tree for key
2. If key not found, return NotFound error
3. Read current value entry
4. Check if current value is overflow:
   a. Extract overflow_page_id from entry
   b. Trace overflow page chain to count pages
   c. Do NOT free overflow pages yet (may still be referenced by old snapshots)
5. Create tombstone entry with deleted flag
6. Decrement node num_keys
7. Update node header (increment free_space)
8. Check if node below minimum occupancy
   a. If so, trigger merge or borrow operation
9. Queue overflow pages for reclamation after all snapshots release LSN

**Error Conditions**:
- NotFound: Key not found

**Complexity**: O(log n) to find leaf + O(num_pages) to trace overflow chain

**Reclamation**: Overflow pages freed after all snapshots with LSN < delete_lsn are released

## Value Compression

### Inline Compression

**Purpose**: Reduce inline value storage size via compression

**Algorithm**:
1. Before inserting inline value, attempt compression
2. Compress value bytes using fast algorithm (e.g., LZ4, Zstd)
3. If compressed size < original size:
   a. Store compressed value with compression flag set
   b. On read, decompress value bytes
4. If compressed size >= original size:
   a. Store uncompressed value
   b. Clear compression flag

**Benefits**:
- Reduced node space consumption
- Higher node capacity
- Fewer tree levels for same data

**Drawbacks**:
- CPU overhead for compression/decompression
- Latency increase for value access
- Variable compression ratio (some values incompressible)

**Use Cases**:
- Text data (JSON, XML, HTML): High compression ratio
- Already compressed data (JPEG, MP4, gzip): Minimal benefit
- Structured data with repetition: Moderate compression

**Recommended Algorithms**:
- LZ4: Very fast, moderate compression (2-3x)
- Zstd level 1: Fast, good compression (3-4x)
- Snappy: Fast, moderate compression (2-3x)

### Overflow Page Compression

**Purpose**: Compress overflow page data to reduce page count

**Algorithm**:
1. Before allocating overflow pages, compress value
2. Calculate compressed size
3. Allocate overflow pages for compressed data
4. Store compressed data in overflow pages
5. Set compression flag in overflow page header
6. On read, decompress page data

**Benefits**:
- Fewer overflow pages allocated
- Less I/O to read large values
- Reduced storage overhead

**Drawbacks**:
- CPU overhead for compression/decompression
- Additional latency on large value access
- In-place updates require recompression

**Tradeoff**: Compress only if compressed_size + overhead < original_size

## Value Versioning

### MVCC Value Versions

**Purpose**: Maintain multiple value versions for concurrent snapshots

**Storage**: Each value version is separate entry in leaf node
- Version 1 (oldest): key1 + value1 + lsn1
- Version 2: key1 + value2 + lsn2
- Version 3 (newest): key1 + value3 + lsn3

**Layout**:
```
[Key][Value3][LSN3][Key][Value2][LSN2][Key][Value1][LSN1]
```

**Note**: Duplicate keys in node! Ordered by LSN (newest first)

**Version Resolution**:
- Search for key in leaf node
- Scan entries with matching key from newest to oldest
- Return first value with entry.lsn <= snapshot_lsn

**Overflow Versioning**:
- Each version may have different overflow page chain
- Overflow chains independent per version
- Old versions' overflow pages freed after all snapshots release

### Version Chain Compaction

**Purpose**: Remove old value versions no longer needed

**Trigger**:
- Node has too many old versions (space threshold)
- All snapshots with LSN < old_version_lsn released

**Algorithm**:
1. Find minimum LSN across all active snapshots
2. Scan node entries for old versions (entry.lsn < min_snapshot_lsn)
3. For each obsolete version:
   a. Remove entry from node
   b. If overflow value, queue overflow pages for deallocation
4. Compact remaining entries (shift to fill gaps)
5. Update node header (decrement num_keys, increase free_space)

**Benefits**:
- Reclaims space from obsolete versions
- Maintains node capacity
- Prevents unbounded version growth

**Drawbacks**:
- CPU overhead for compaction
- May trigger node splits/merges
- Requires coordination with snapshot management

## Value Performance Considerations

### Inline Value Performance

**Read Latency**:
- Single page read retrieves key + value
- O(log n) tree traversal + O(1) value extraction
- Typical: 1-3 I/Os for cached tree, +1 I/O for leaf page

**Write Latency**:
- Single leaf page write for key + value
- O(log n) tree traversal + O(1) value insertion
- Typical: 1-3 I/Os to find leaf, +1 I/O to write leaf

**Space Overhead**:
- 2-byte length prefix per value
- Value bytes stored directly
- No additional page allocation

**Node Capacity**:
- Higher for small values (more entries per node)
- Lower for large values (fewer entries per node)
- Impacts tree height and I/O for all operations

### Overflow Value Performance

**Read Latency**:
- Multiple page reads for large values
- O(log n) tree traversal + O(num_pages) overflow chain traversal
- Typical: 1-3 I/Os for tree + 1-1000 I/Os for overflow pages (16MB value)

**Write Latency**:
- Multiple page writes for large values
- O(log n) tree traversal + O(num_pages) overflow page allocation and writes
- Typical: 1-3 I/Os for tree + 1-1000 I/Os for overflow pages

**Space Overhead**:
- 10-byte overflow reference in leaf entry (2-byte marker + 8-byte page ID)
- Overflow page headers: 16 bytes per page
- Partially filled final overflow page (internal fragmentation)

**Node Capacity**:
- Unaffected by large value size
- Consistent node capacity regardless of value size distribution
- Leaf nodes remain compact

### Cache Considerations

**Page Cache Utilization**:
- Inline values: Leaf pages contain frequently accessed data, good cache locality
- Overflow values: Leaf pages contain references, not data, may reduce cache effectiveness

**Prefetching**:
- Inline values: Prefetch leaf page only
- Overflow values: Prefetch entire overflow chain for sequential access

**Cache Eviction**:
- Inline values: Large values push other entries out of cache
- Overflow values: Only overflow references in leaf cache, overflow pages cached separately

## Rust Implementation Guidance

### Module Structure

Define value types and functions in:
- `northstar_core::tree::value::Value` - Value type and encoding
- `northstar_core::tree::value::InlineValue` - Inline value representation
- `northstar_core::tree::value::OverflowValue` - Overflow value representation
- `northstar_core::tree::value::OverflowPage` - Overflow page structure

### Type Definitions

**Value Encoding**:
```rust
pub const INLINE_THRESHOLD: usize = 2000;
pub const MAX_VALUE_SIZE: usize = 16_777_215; // 16MB - 1
pub const OVERFLOW_MARKER: u16 = 0xFFFF;

pub enum ValueStorage<'a> {
    Inline(&'a [u8]),
    Overflow(PageId),
}

pub struct OverflowPage {
    pub magic: u32,        // 0x4F56464C
    pub next_page: PageId, // 0 if last page
    pub data: [u8; 16368], // Value chunk
}
```

**Value Encoding/Decoding**:
```rust
pub fn encode_inline_value(value: &[u8]) -> Vec<u8> {
    let mut encoded = Vec::with_capacity(2 + value.len());
    encoded.extend_from_slice(&(value.len() as u16).to_le_bytes());
    encoded.extend_from_slice(value);
    encoded
}

pub fn encode_overflow_value(page_id: PageId) -> [u8; 10] {
    let mut encoded = [0u8; 10];
    encoded[0..2].copy_from_slice(&OVERFLOW_MARKER.to_le_bytes());
    encoded[2..10].copy_from_slice(&page_id.to_le_bytes());
    encoded
}

pub fn decode_value_entry(data: &[u8]) -> Result<ValueStorage, ValueError> {
    let value_len = u16::from_le_bytes([data[0], data[1]]);
    if value_len != OVERFLOW_MARKER {
        let value_bytes = &data[2..2 + value_len as usize];
        Ok(ValueStorage::Inline(value_bytes))
    } else {
        let page_id = u64::from_le_bytes(data[2..10].try_into().unwrap());
        Ok(ValueStorage::Overflow(PageId::from(page_id)))
    }
}
```

### Overflow Page Management

**Allocate Overflow Pages**:
```rust
pub fn allocate_overflow_chain(
    pager: &mut Pager,
    value: &[u8],
) -> Result<PageId, ValueError> {
    const CHUNK_SIZE: usize = 16368;
    let num_pages = (value.len() + CHUNK_SIZE - 1) / CHUNK_SIZE;
    let mut first_page_id = None;
    let mut prev_page_id = None;

    for i in 0..num_pages {
        let page_id = pager.allocate_page()?;
        let page = pager.get_page_mut(page_id)?;

        // Initialize overflow page
        page.magic = 0x4F56464C;
        let start = i * CHUNK_SIZE;
        let end = std::cmp::min(start + CHUNK_SIZE, value.len());
        page.data[..(end - start)].copy_from_slice(&value[start..end]);
        page.next_page = PageId::from(0);

        // Link pages
        if let Some(prev_id) = prev_page_id {
            let prev_page = pager.get_page_mut(prev_id)?;
            prev_page.next_page = page_id;
        } else {
            first_page_id = Some(page_id);
        }

        prev_page_id = Some(page_id);
    }

    first_page_id.ok_or(ValueError::AllocationFailed)
}
```

**Read Overflow Chain**:
```rust
pub fn read_overflow_chain(
    pager: &Pager,
    first_page_id: PageId,
) -> Result<Vec<u8>, ValueError> {
    let mut buffer = Vec::new();
    let mut current_page_id = first_page_id;

    loop {
        let page = pager.get_page(current_page_id)?;

        // Validate overflow page
        if page.magic != 0x4F56464C {
            return Err(ValueError::InvalidOverflowPage(current_page_id));
        }

        // Append data chunk
        let data_len = if page.next_page.is_valid() {
            16368
        } else {
            // Last page: find actual data length
            // (Need to track this separately or use sentinel)
        };
        buffer.extend_from_slice(&page.data[..data_len]);

        // Check if last page
        if !page.next_page.is_valid() {
            break;
        }

        current_page_id = page.next_page;
    }

    Ok(buffer)
}
```

**Free Overflow Chain**:
```rust
pub fn free_overflow_chain(
    pager: &mut Pager,
    first_page_id: PageId,
) -> Result<(), ValueError> {
    let mut current_page_id = first_page_id;

    loop {
        let page = pager.get_page(current_page_id)?;
        let next_page_id = page.next_page;

        pager.free_page(current_page_id)?;

        if !next_page_id.is_valid() {
            break;
        }

        current_page_id = next_page_id;
    }

    Ok(())
}
```

### Error Handling

**ValueError Enum**:
```rust
#[derive(Debug, thiserror::Error)]
pub enum ValueError {
    #[error("value too large: {len} bytes (max: {max})")]
    ValueTooLarge { len: usize, max: usize },

    #[error("overflow page {0} has invalid magic number")]
    InvalidOverflowPage(PageId),

    #[error("overflow page chain corrupted or truncated")]
    CorruptedOverflowChain,

    #[error("failed to allocate overflow pages")]
    AllocationFailed,

    #[error("overflow marker not found")]
    ExpectedOverflowMarker,
}
```

### Compression Support

**Optional Compression**:
```rust
pub fn maybe_compress_value(
    value: &[u8],
    algorithm: CompressionAlgorithm,
) -> (Vec<u8>, bool) {
    // Compress
    let compressed = match algorithm {
        CompressionAlgorithm::LZ4 => lz4_compress(value),
        CompressionAlgorithm::Zstd => zstd_compress(value),
    };

    // Check if compression beneficial
    if compressed.len() < value.len() {
        (compressed, true)  // Compressed
    } else {
        (value.to_vec(), false)  // Uncompressed
    }
}
```

### Testing Strategy

**Unit tests needed for**:
- Inline value encoding/decoding
- Overflow reference encoding/decoding
- Overflow page allocation, reading, freeing
- Storage decision (inline vs overflow)
- Value size validation
- Overflow chain integrity

**Property tests for**:
- Encoding round-trip: decode(encode(value)) == value
- Overflow chain links correctly (next_page consistent)
- Free space calculation accurate
- Value size limits enforced

**Integration scenarios**:
- Insert inline value, verify readable
- Insert overflow value, verify all data present
- Update inline to overflow, verify old pages freed
- Update overflow to inline, verify overflow chain freed
- Delete overflow value, verify pages freed after reclamation

**Performance tests**:
- Inline value read/write latency
- Overflow value read/write latency (various sizes)
- Overflow page allocation throughput
- Cache hit rates for inline vs overflow

## Invariants

### Value Encoding Invariants
1. Inline value encoding length equals 2 + value_length
2. Overflow reference encoding always exactly 10 bytes
3. value_len = 0xFFFF indicates overflow, never inline value
4. value_len < 0xFFFF indicates inline, never overflow

### Overflow Chain Invariants
1. All overflow pages have magic = 0x4F56464C
2. For every page in chain except last, next_page != 0
3. For last page in chain, next_page = 0
4. Total data bytes across chain equals original value length

### Node Space Invariants
1. Inline value entries reduce node free_space by (2 + value_length)
2. Overflow value entries reduce node free_space by exactly 10 bytes
3. Node capacity calculation accounts for value storage type
4. free_space never negative after value insert

## Dependencies

**Uses**:
- Error types module (for ValueError)
- PageId type (for overflow page references)
- Pager module (for overflow page allocation and I/O)
- Constants for INLINE_THRESHOLD and MAX_VALUE_SIZE

**Used By**:
- B+Tree insert operations (value storage)
- B+Tree search operations (value retrieval)
- B+Tree delete operations (overflow page reclamation)
- Leaf node structures (value entry encoding)
- MVCC versioning (multiple value versions)

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design
- **06-btree-node.md**: Leaf node structure storing values
- **06-btree-insert.md**: Insert operations with value storage
- **06-btree-key.md**: Key encoding (complementary to value encoding)
- **02-pager-*.md**: Pager integration for overflow page allocation
- **01-key-value-types.md**: General value type definitions
