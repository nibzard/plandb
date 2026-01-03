# Pager Read Operation

## Purpose

The Pager read operation is responsible for retrieving pages from storage with comprehensive validation, caching support, and bounds checking. This specification details the step-by-step read flow, cache lookup and insertion strategies, cache eviction policy, and buffer pool data structures. The read operation ensures data integrity through checksum validation and provides both direct I/O and cached access patterns.

## Read Flow

### Step 1: Buffer Size Validation

**Purpose**: Ensure caller-provided buffer is large enough to hold a complete page

**Validation**:
- Check buffer length is at least page_size bytes
- Return "buffer too small" error if buffer is too small

**Rationale**: Prevents buffer overflow and ensures page fits in provided buffer

**Error Condition**: Buffer length less than page_size (16384 bytes for V0)

### Step 2: Page ID Bounds Validation

**Purpose**: Ensure requested page ID exists within the file

**Validation**:
- Get current file size from storage
- Calculate maximum valid page ID as file_size divided by page_size
- Check if requested page_id is less than maximum
- Return "page out of bounds" error if page_id is too large

**Rationale**: Prevents reading beyond end of file and validates page ID is valid

**Error Condition**: page_id greater than or equal to total pages in file

### Step 3: Storage Read Operation

**Purpose**: Read page data from storage backend (file or memory)

**File Storage Path**:
- Calculate file offset as page_id multiplied by page_size
- Check for integer overflow (offset should equal product)
- Use pread (position-independent read) to read at offset
- Read exactly page_size bytes into buffer
- Return "unexpected EOF" if fewer bytes read than page_size

**Memory Storage Path**:
- Read page at page_id from memory buffer
- Copy exactly page_size bytes into buffer
- Return "unexpected EOF" if read fails

**Rationale**: pread allows reading without changing file position, enabling concurrent reads

**Error Conditions**:
- I/O error during read operation
- Unexpected EOF (fewer bytes than expected)

### Step 4: Page Validation

**Purpose**: Verify page integrity before returning data to caller

**Validation Steps**:
1. Parse PageHeader from first 40 bytes
2. Validate magic number equals PAGE_MAGIC
3. Validate format version is supported
4. Validate page type is known value
5. Validate header checksum matches calculated value
6. Parse payload length from header
7. Validate payload length fits within page (not too large)
8. Calculate and validate page payload checksum

**Error Detection**:
- InvalidMagic: First 4 bytes don't match PAGE_MAGIC
- InvalidHeaderChecksum: Header checksum doesn't match calculated value
- InvalidPageChecksum: Payload checksum doesn't match calculated value
- InvalidPayloadLength: Payload length exceeds maximum possible
- UnexpectedPageType: Page type value is not recognized

**Error Handling**: Return specific error for each validation failure
- Log error details for debugging
- Return error to caller
- Page is considered corrupt and unsafe to use

### Step 5: Page ID Consistency Check

**Purpose**: Verify page ID in header matches requested page ID

**Validation**:
- Compare page_id field in PageHeader with requested page_id parameter
- Return "page ID mismatch" error if they don't match
- Log both values for debugging

**Rationale**: Detects page swapped to wrong location (corruption or bug)

**Error Condition**: Header page_id differs from requested page_id

### Step 6: Return Successfully

**Completion**: All validations passed, page data is valid

**State**:
- Buffer contains valid page data
- Checksums have been verified
- Page ID in header matches requested ID
- Caller can safely use page contents

## Cache Lookup and Insertion

### Cached Read Path

**Purpose**: Provide zero-copy cached access to frequently accessed pages

**Entry Point**: read_page_cached function is called instead of read_page

**Step 1: Cache Lookup**
- Check if page exists in cache
- If cache hit: Return borrowed reference to cached data immediately
- If cache miss: Proceed to Step 2

**Step 2: Allocate Temporary Buffer**
- Allocate buffer of page_size bytes
- This buffer is temporary, used only for reading from storage

**Step 3: Read from Storage**
- Call read_page to populate temporary buffer
- Performs all validations described in Read Flow
- Returns error if read or validation fails

**Step 4: Allocate Cache Buffer**
- Allocate second buffer of page_size bytes
- Copy page data from temporary buffer to cache buffer
- Cache buffer becomes owned by cache

**Step 5: Insert into Cache**
- Insert cache buffer into page cache with page_id as key
- Cache takes ownership of cache buffer
- Temporary buffer is freed

**Step 6: Retrieve from Cache**
- Look up page_id in cache again
- Cache will pin the page (prevent eviction)
- Return borrowed reference to pinned cached data

**Step 7: Caller Use**
- Caller uses borrowed reference to read page contents
- Reference remains valid until unpin_page is called

**Step 8: Unpin**
- Caller calls unpin_page when done with page
- Decrements pin count for page
- Page becomes eligible for eviction when pin count reaches zero

### Cache Hit Behavior

**Fast Path**: Page is already in cache

**Steps**:
1. Look up page_id in cache
2. Cache returns borrowed reference to cached data
3. Page is automatically pinned (pin count incremented)
4. Return borrowed reference to caller immediately

**Benefits**:
- No I/O required (page already in memory)
- Zero-copy (borrowed reference, no data copying)
- Very fast (hash map lookup)

**Complexity**: O(1) for hash map lookup

### Cache Miss Behavior

**Slow Path**: Page is not in cache

**Steps**:
1. Allocate temporary buffer for read
2. Read page from storage into temporary buffer
3. Allocate cache buffer (owned by cache)
4. Copy data from temporary to cache buffer
5. Insert cache buffer into cache
6. Look up page in cache again (now it's there)
7. Return borrowed reference to pinned data

**Costs**:
- I/O operation (disk read or memory copy)
- Memory allocation (two buffers: temporary and cache)
- Data copy (one memcpy operation)
- Cache eviction may be triggered if cache is full

**Complexity**: O(1) plus I/O time plus potential eviction cost

### Cache Insertion

**Purpose**: Add newly read page to cache for future access

**Algorithm**:
1. Check if cache is at capacity (memory limit or entry count limit)
2. If at capacity: Trigger eviction to free space
3. Allocate buffer for cached page data
4. Copy page data to cache buffer
5. Insert into cache hash map with page_id as key
6. Initialize pin count to 1 (page is pinned on first access)

**Cache Buffer Ownership**:
- Cache owns the allocated buffer
- Buffer lives until page is evicted
- Multiple cache hits return references to same buffer
- No data copying on cache hit (zero-copy)

## Cache Eviction Policy

### LRU (Least Recently Used) Policy

**Description**: Pages that have not been accessed for the longest time are evicted first

**Implementation**: Doubly-linked list or equivalent structure
- Each cache entry has access timestamp or list position
- Most recently accessed items moved to front
- Least recently accessed items at back
- Eviction removes items from back

**Rationale**: LRU exploits temporal locality
- Recently accessed pages likely to be accessed again
- Old pages are good candidates for eviction
- Simple and effective for most workloads

### Eviction Triggers

**Capacity Limits**: Eviction occurs when cache is full
- Entry count limit: Maximum number of pages (e.g., 1024)
- Memory limit: Maximum bytes (e.g., 16MB)
- Whichever limit is reached first triggers eviction

**Eviction Process**:
1. Identify unpinned page with oldest access time
2. Remove from cache hash map
3. Free page buffer
4. Repeat until enough space for new page
5. Insert new page

**Pinned Pages**: Pages with non-zero pin count cannot be evicted
- Pinned pages are skipped during eviction selection
- Ensures pages currently in use are not removed
- Caller must unpin pages when done

### Pinning Mechanism

**Purpose**: Prevent cache eviction of pages currently in use

**Pin Count**: Each cached page has a counter of active references
- Initial value: 1 when inserted into cache
- Incremented by: read_page_cached (each hit pins the page)
- Decremented by: unpin_page (caller indicates done)
- Page eligible for eviction when pin count reaches 0

**Borrowed References**: Returned references depend on pinning
- Lifetime of reference is tied to pin count
- Caller must not use reference after calling unpin_page
- Reference becomes invalid after unpin (may be freed)

**Unpin Call**: Caller signals it's done with page
- Decrements pin count for page_id
- Page may be evicted immediately if pin count reaches 0
- Safe to call unpin multiple times (idempotent behavior)

## Buffer Pool Data Structure

### Cache Entry

**Description**: Represents one page currently cached in memory

**Fields**:
- **page_id**: u64 - Page identifier (cache key)
- **data**: Vec<u8> or Box<[u8; PAGE_SIZE]> - Page data (owned by cache)
- **pin_count**: usize or AtomicUsize - Number of active references
- **access_time**: Instant or u64 - Timestamp of last access (for LRU)
- **prev/next**: Pointers or indices for LRU list position

**Invariants**:
- data buffer size equals page_size
- pin_count is at least 1 while in cache (0 means being evicted)
- access_time is updated on each cache hit
- prev/next pointers maintain consistent doubly-linked list

### Hash Map

**Purpose**: Fast lookup from page_id to cache entry

**Type**: HashMap<u64, CacheEntry>

**Operations**:
- Insert: Add or update entry for page_id
- Lookup: Retrieve entry by page_id
- Remove: Delete entry by page_id

**Complexity**: O(1) average case for all operations

### LRU List

**Purpose**: Track access order for eviction policy

**Type**: Doubly-linked list or VecDeque with indices

**Operations**:
- Move to front: Mark entry as most recently used
- Remove from back: Evict least recently used entry
- Iterate: Find eviction candidates (must skip pinned pages)

**Integration**: Hash map entries point to LRU list nodes for position updates

### Overall Cache Structure

**PageCache Struct**: Combines hash map and LRU list

**Fields**:
- **entries**: HashMap<u64, CacheEntry> - Fast page_id lookup
- **lru_list**: Doubly-linked list of CacheEntry references - LRU ordering
- **capacity_entries**: usize - Maximum number of pages (e.g., 1024)
- **capacity_bytes**: usize - Maximum memory usage (e.g., 16MB)
- **current_bytes**: usize or AtomicUsize - Current memory usage

**Invariants**:
- Number of entries does not exceed capacity_entries
- current_bytes does not exceed capacity_bytes
- All entries in lru_list are in entries map
- LRU list contains all cache entries (no orphan entries)
- Pinned entries are not evicted (skipped during selection)

## Functions

### read_page(&mut self, page_id: u64, buffer: &mut [u8]) -> Result<(), Error>

**Purpose**: Read a page from storage directly into caller-provided buffer

**Parameters**:
- page_id: Page identifier to read
- buffer: Destination buffer (must be at least page_size bytes)

**Returns**: Empty tuple on success

**Algorithm**: Described in "Read Flow" section

**Error Conditions**:
- BufferTooSmall: Caller buffer is too small
- PageOutOfBounds: page_id is beyond file size
- UnexpectedEOF: Could not read full page from storage
- InvalidMagic, InvalidChecksum: Page is corrupt
- PageIdMismatch: Page ID in header doesn't match requested

### read_page_cached(&mut self, page_id: u64) -> Result<&[u8], Error>

**Purpose**: Read a page with caching, returning borrowed reference

**Parameters**:
- page_id: Page identifier to read

**Returns**: Borrowed slice reference to page data (pinned in cache)

**Lifetime**: Reference valid until unpin_page is called

**Algorithm**: Described in "Cached Read Path" section

**Error Conditions**: Same as read_page (storage and validation errors)

### unpin_page(&mut self, page_id: u64)

**Purpose**: Release pinned page, making it eligible for eviction

**Parameters**:
- page_id: Page identifier to unpin

**Returns**: Empty (no return value)

**Behavior**:
- Decrements pin count for page_id in cache
- Page may be evicted immediately if pin count reaches 0
- Safe to call multiple times (idempotent or clamped to zero)

**Note**: Should match each call to read_page_cached

## Invariants

- **Buffer Size**: Caller buffer must be exactly page_size bytes
- **Page Bounds**: page_id must be within valid range (0 to file_size/page_size - 1)
- **Checksum Valid**: All returned pages have valid checksums
- **Cache Consistency**: Cached pages match storage contents
- **Pin Count**: Pinned pages are not evicted
- **LRU Order**: Cache maintains least-recently-used ordering for eviction
- **Memory Limits**: Cache respects entry and byte capacity limits

## Dependencies

- **Uses**: PageCache module for caching, Storage for I/O
- **Used by**: B+tree (node reads), Transactions (data access)

## Rust Implementation Guidance

### Module Structure

Cache implementation in dedicated module:
- northstar_core::pager::cache - PageCache and related types
- Integrated into Pager via field reference

### Type Definitions

**Cache Entry**: Struct representing one cached page
```rust
struct CacheEntry {
    page_id: u64,
    data: Box<[u8; PAGE_SIZE]>,
    pin_count: AtomicUsize,
    lru_node: LinkedList<CacheEntry>, // or equivalent
}
```

**PageCache**: Main cache structure
```rust
pub struct PageCache {
    entries: HashMap<u64, CacheEntry>,
    lru_list: LinkedList<CacheEntry>, // or custom LRU structure
    capacity_entries: usize,
    capacity_bytes: usize,
    current_bytes: AtomicUsize,
}
```

### Synchronization

**Thread Safety**: PageCache requires internal synchronization

**Recommended**: RwLock for cache operations
- Multiple readers can access cache concurrently
- Only one writer (cache insertion or eviction)
- Read operations are common (cache hits)
- Write operations are relatively rare (cache misses, evictions)

**Implementation**:
```rust
pub struct PageCache {
    entries: RwLock<HashMap<u64, CacheEntry>>,
    lru_list: Mutex<LinkedList<CacheEntry>>,
    capacity_entries: usize,
    capacity_bytes: usize,
    current_bytes: AtomicUsize,
}
```

### Borrowed References

**Lifetime Management**: Use lifetimes to express borrow relationship

**Signature**:
```rust
pub fn read_page_cached(&mut self, page_id: u64) -> Result<&[u8], Error>
```

**Challenge**: Returning reference that depends on cache state

**Solutions**:
1. **BorrowMutSelf**: Return reference tied to &mut self lifetime
2. **Arena/Arena**: References tied to arena lifetime (complex)
3. **Pinning**: Caller must manually unpin (Zig approach)

**Recommended**: Use Pin API with manual unpin
- Similar to Zig approach (explicit unpin_page call)
- Caller responsible for calling unpin_page
- More explicit but requires user cooperation

### Eviction Implementation

**LRU with Linked List**: Use LinkedList from standard library
- Each CacheEntry contains LinkedList node
- LRU list maintains ordering
- Eviction walks list to find unpinned candidate

**Alternative**: Use third-party LRU cache crate
- lru crate provides LRU cache implementation
- Simplifies implementation
- May have different performance characteristics

### Testing Strategy

**Unit tests needed for**:
- Cache hit returns immediately without I/O
- Cache miss triggers storage read and cache insertion
- Unpin reduces pin count correctly
- Eviction removes least recently used unpinned page
- Pinned pages are never evicted
- Capacity limits are enforced (entry count and byte count)

**Property tests for**:
- Cache hit rate improves with repeated reads of same pages
- LRU eviction removes oldest page when cache full
- Pin count goes to zero after corresponding number of unpins
- Memory usage never exceeds capacity_bytes

**Integration tests for**:
- Cached reads return same data as uncached reads
- Multiple concurrent readers can hit cache simultaneously
- Cache correctly reflects storage contents after write
- Eviction does not lose dirty data (pages are not dirty in current design)