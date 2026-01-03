# Pager Cache

## Purpose

The Pager cache is an in-memory LRU (Least Recently Used) cache for database pages that reduces I/O by keeping frequently accessed pages in memory. The cache supports pinning to prevent eviction of pages actively in use by snapshot readers, provides zero-copy borrowed references for efficient access, and tracks cache statistics for monitoring and tuning. This specification details the cache data structure, hit/miss tracking, lock contention strategy, and implementation approach for Rust.

## Cache Data Structure

### Cache Entry

**Description**: Represents one page currently cached in memory

**Fields**:
- **page_id**: u64 - Page identifier (cache key for hash map lookup)
- **data**: Byte slice or Box<[u8; PAGE_SIZE]> - Page data (owned by cache)
- **pin_count**: u32 or AtomicU32 - Number of active references preventing eviction
- **last_access**: u64 or AtomicU64 - Access timestamp or sequence number for LRU ordering
- **prev**: Optional pointer to previous entry in LRU list (for doubly-linked list)
- **next**: Optional pointer to next entry in LRU list (for doubly-linked list)

**Invariants**:
- data buffer size equals page_size (16384 bytes for default)
- pin_count is at least 0
- last_access is monotonically increasing on each access
- prev and next pointers maintain consistent doubly-linked list structure
- Entry exists in hash map while present in LRU list

**Lifetime**: Entry lives from insertion until eviction
- Created when page loaded on cache miss
- Freed when evicted or cache is deinitialized
- Multiple cache hits return references to same entry

### Hash Map

**Purpose**: Fast O(1) lookup from page_id to cache entry

**Type**: HashMap<u64, CacheEntry> or similar

**Operations**:
- Insert: Add entry for page_id (may replace existing entry)
- Lookup: Retrieve entry by page_id
- Remove: Delete entry by page_id
- Contains: Check if page_id exists in cache

**Collision Resolution**: Chaining (each bucket is linked list or tree)

**Complexity**: O(1) average case for all operations

**Usage**: Primary lookup mechanism for cache hits

### LRU List

**Purpose**: Track access order for eviction policy (least recently used at tail)

**Type**: Doubly-linked list of CacheEntry references

**Operations**:
- Move to front: Mark entry as most recently used
- Remove from back: Evict least recently used entry
- Iterate: Find eviction candidates (must skip pinned pages)
- Add to front: Insert new entry as most recently used

**Pointers**: Each CacheEntry has prev and next pointers

**Integration**: Hash map entries point to LRU list nodes for position updates

**Complexity**: O(1) for move-to-front, O(n) worst case for eviction search (if many pinned pages)

### Overall Cache Structure

**PageCache Struct**: Combines hash map and LRU list with capacity limits

**Fields**:
- **entries**: HashMap<u64, CacheEntry> - Fast page_id lookup
- **lru_head**: Optional pointer to most recently used entry
- **lru_tail**: Optional pointer to least recently used entry
- **access_counter**: u64 or AtomicU64 - Monotonic counter for access timestamps
- **max_pages**: usize - Maximum number of pages (e.g., 1024)
- **max_bytes**: usize - Maximum memory usage (e.g., 16MB)
- **current_bytes**: usize or AtomicUsize - Current memory usage

**Invariants**:
- Number of entries does not exceed max_pages (unless all pinned)
- current_bytes does not exceed max_bytes (unless all pinned)
- All entries in LRU list are in entries map
- LRU list contains all cache entries (no orphan entries)
- Pinned entries are not evicted (may exceed capacity)

## Hit/Miss Tracking

### Cache Hit Path

**Description**: Fast path when requested page is already in cache

**Algorithm**:
1. Look up page_id in hash map
2. If found:
   a. Increment pin_count (prevent eviction while in use)
   b. Update last_access to current access_counter value
   c. Move entry to front of LRU list (most recently used)
   d. Return borrowed reference to page data
3. If not found: Return null (cache miss)

**Benefits**:
- No I/O required (page already in memory)
- Zero-copy (borrowed reference, no data copying)
- Very fast (O(1) hash map lookup)

**Costs**:
- Hash map lookup (minimal CPU)
- Pin count increment (atomic operation if concurrent)
- LRU list manipulation (pointer updates)

### Cache Miss Path

**Description**: Slow path when page not in cache, must load from storage

**Algorithm**:
1. Look up page_id in hash map
2. If not found (cache miss):
   a. Allocate temporary buffer for read from storage
   b. Read page from storage into temporary buffer
   c. Allocate cache buffer (owned by cache)
   d. Copy data from temporary to cache buffer
   e. Insert cache buffer into cache with page_id as key
   f. Look up page_id again (now it's in cache)
   g. Increment pin_count and return borrowed reference

**Costs**:
- I/O operation (disk read or memory copy)
- Memory allocation (two buffers: temporary and cache)
- Data copy (one memcpy operation)
- Cache eviction may be triggered if cache is full

### Hit Rate Measurement

**Purpose**: Track cache effectiveness for tuning

**Metrics**:
- Total lookups: Counter incremented on every cache access
- Cache hits: Counter incremented when page found in cache
- Cache misses: Counter incremented when page not found
- Hit rate: hits / (hits + misses) as percentage

**Implementation**: Optional statistics tracking
- Can be enabled for debugging and performance analysis
- Adds minimal overhead (few atomic increments per access)
- Useful for determining optimal cache size

**Usage**:
- Hit rate above 90%: Good cache performance
- Hit rate below 70%: Cache too small or poor access pattern
- Hit rate near 0%: Sequential scan pattern (cache not helping)

## Lock Contention Strategy

### Single-Writer Model (Zig)

**Current Design**: Single thread owns the pager

**No Internal Locking**: Cache operations are not synchronized
- Assumes single-threaded access
- No mutex or RWLock inside cache
- Caller responsible for coordination

**Rationale**:
- Zig implementation has single writer
- Simpler implementation (no lock overhead)
- Sufficient for embedded database use case

**Limitations**:
- Cannot safely share cache across threads
- Concurrent reads require external synchronization
- Not suitable for multi-threaded workloads

### Rust Concurrent Access

**RwLock Pattern**: Recommended for multi-threaded access

**Read Operations**: Shared read access (multiple readers)
- Cache hit: Multiple threads can access cache simultaneously
- Lookup: Hash map is read-only
- LRU update: May require exclusive access (depends on implementation)

**Write Operations**: Exclusive write access (single writer)
- Cache insertion: Modifies hash map and LRU list
- Eviction: Removes entries from structures
- Clear: Removes multiple entries

**Implementation**:
```rust
pub struct PageCache {
    entries: RwLock<HashMap<u64, CacheEntry>>,
    lru_head: Mutex<Option<*mut CacheEntry>>,
    lru_tail: Mutex<Option<*mut CacheEntry>>,
    access_counter: AtomicU64,
    max_pages: usize,
    max_bytes: usize,
    current_bytes: AtomicUsize,
}
```

**Lock Granularity**:
- Coarse-grained: One lock for entire cache (simple)
- Fine-grained: Separate locks for hash map and LRU list (complex)
- Per-bucket locking: Each hash bucket has own lock (very complex)

**Recommendation**: Start with coarse-grained RwLock
- Simple implementation
- Good read scalability (multiple readers)
- Single writer blocks all readers (acceptable for most workloads)

### Lock-Free Considerations

**Potential Optimization**: Lock-free cache for read-heavy workloads

**Techniques**:
- Atomic pin counts for lock-free pin/unpin
- RCU (Read-Copy-Update) for LRU list updates
- Lock-free hash map (e.g., crossbeam SkipMap)

**Trade-offs**:
- Pro: Excellent read scalability
- Pro: No lock contention on cache hits
- Con: Very complex implementation
- Con: Hard to ensure correctness
- Con: May not outperform simple RwLock in practice

**Recommendation**: Use RwLock initially, consider lock-free only if profiling shows lock contention

## Cache Implementation Approach

### Ownership Model

**Cache-Owned Data**: Cache owns all page buffers

**Entry Creation**:
- Page data copied into cache-owned allocation
- Cache manages buffer lifetime
- Caller receives borrowed reference

**Reference Lifetime**:
- Borrowed reference valid until page unpinned
- Caller must not use reference after unpin
- Use-after-unpin is undefined behavior (may access freed memory)

**Rust Borrowing**: Use lifetimes to express this
```rust
pub fn get(&self, page_id: u64) -> Option<&[u8]> {
    // Return reference tied to cache lifetime
}
```

### Pinning Mechanism

**Purpose**: Prevent eviction of pages actively in use

**Pin Count**: Each cached page has counter of active references
- Initial value: 0 when inserted into cache
- Incremented by: get() or read_page_cached() (each access pins the page)
- Decremented by: unpin() (caller indicates done)
- Page eligible for eviction when pin count reaches 0

**Pinned Pages Protection**:
- Eviction algorithm skips pages with pin_count > 0
- Cache may exceed capacity limits if all pages pinned
- Caller must unpin pages to allow eviction

**Usage Pattern**:
1. Call get() or read_page_cached() to access page (auto-pins)
2. Use borrowed reference to read page contents
3. Call unpin() or drop guard when done with page
4. Page becomes eligible for eviction

### Eviction Algorithm

**LRU (Least Recently Used) Policy**:
- Pages with lowest last_access value evicted first
- Doubly-linked list tracks access order
- Most recently accessed items at head (lru_head)
- Least recently accessed items at tail (lru_tail)

**Eviction Triggers**:
- Entry count exceeds max_pages
- Byte count exceeds max_bytes
- Whichever limit is reached first triggers eviction

**Eviction Process**:
1. Check if cache exceeds capacity (entries or bytes)
2. If over capacity:
   a. Start at LRU tail (least recently used)
   b. Find first unpinned entry (pin_count == 0)
   c. Remove entry from hash map
   d. Remove entry from LRU list
   e. Free entry's page buffer
   f. Decrement current_bytes
   g. Repeat until under capacity
3. If all entries pinned: Cache may exceed capacity (acceptable)

**Pinned Pages**: Never evicted even if cache over capacity
- Prevents use-after-free errors
- Ensures active readers not disrupted
- Caller must unpin to allow future evictions

### Capacity Limits

**Dual Limits**: Both entry count and byte count enforced

**max_pages**: Maximum number of pages (default: 1024)
- Prevents excessive hash map size
- Bounds LRU list length
- Each entry has overhead (pointers, metadata)

**max_bytes**: Maximum memory usage (default: 16MB)
- Prevents cache from consuming too much memory
- Accounts for actual page data size
- More direct measure of memory pressure

**Default Values**:
- 1024 pages at 16KB per page = 16MB total
- Reasonable default for embedded database
- Tunable based on workload and available memory

**Configuration**: Set at cache initialization
- May be adjusted for specific workloads
- Read-heavy workloads benefit from larger cache
- Write-heavy workloads may use smaller cache

## Functions

### get(&mut self, page_id: u64) -> Option<&[u8]>

**Purpose**: Get cached page with auto-pinning

**Returns**: Borrowed slice reference to page data (pinned), or None if not in cache

**Algorithm**:
1. Look up page_id in hash map
2. If found:
   a. Increment pin_count
   b. Update last_access
   c. Move to LRU front
   d. Return borrowed reference to data
3. If not found: Return None

### unpin(&mut self, page_id: u64)

**Purpose**: Release pinned page, making it eligible for eviction

**Behavior**:
- Decrements pin count for page_id if found
- Page may be evicted immediately if pin count reaches 0
- Safe to call multiple times (pin count clamped to 0)

### put(&mut self, page_id: u64, data: &[u8]) -> Result<(), Error>

**Purpose**: Insert or update page in cache

**Algorithm**:
1. If page_id already exists:
   a. Update data (free old buffer, allocate new)
   b. Update last_access and move to LRU front
   c. Update current_bytes
2. If page_id doesn't exist:
   a. Allocate cache entry and copy data
   b. Insert into hash map
   c. Add to LRU front
   d. Update current_bytes
   e. Trigger eviction if over capacity

### remove(&mut self, page_id: u64) -> bool

**Purpose**: Force eviction of specific page

**Returns**: True if page was removed, false if not found or pinned

**Algorithm**:
1. Look up page_id in hash map
2. If found and pin_count == 0:
   a. Remove from hash map
   b. Remove from LRU list
   c. Free page buffer
   d. Decrement current_bytes
   e. Return true
3. If not found or pinned: Return false

### clear(&mut self)

**Purpose**: Remove all unpinned pages from cache

**Algorithm**:
1. Iterate over all entries in hash map
2. For each entry with pin_count == 0:
   a. Add page_id to removal list
3. Remove all pages in removal list
4. Pinned pages remain in cache

### getStats(&self) -> Stats

**Purpose**: Get cache performance statistics

**Returns**: Stats structure with current metrics

**Stats Fields**:
- total_pages: Current number of cached pages
- pinned_pages: Number of pages with pin_count > 0
- total_bytes: Current memory usage
- max_pages: Configured maximum pages
- max_bytes: Configured maximum bytes

## Invariants

- **Hash Map Consistency**: All LRU entries exist in hash map
- **LRU List Consistency**: All hash map entries in LRU list (no orphan entries)
- **Capacity Limits**: Cache respects max_pages and max_bytes (unless all pinned)
- **Pin Count**: Pinned pages (pin_count > 0) are never evicted
- **Access Ordering**: LRU list maintains least-recently-used ordering
- **Data Ownership**: Cache owns all page data until eviction
- **Reference Safety**: Borrowed references invalidated on unpin

## Dependencies

- **Uses**: HashMap or similar hash table, LRU list implementation
- **Used by**: Pager (cached reads), B+tree (node caching), Snapshots (pinned pages for MVCC)

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
    pin_count: AtomicU32,
    last_access: AtomicU64,
    prev: Option<*mut CacheEntry>,
    next: Option<*mut CacheEntry>,
}
```

**PageCache**: Main cache structure
```rust
pub struct PageCache {
    entries: RwLock<HashMap<u64, CacheEntry>>,
    lru_head: Mutex<Option<*mut CacheEntry>>,
    lru_tail: Mutex<Option<*mut CacheEntry>>,
    access_counter: AtomicU64,
    max_pages: usize,
    max_bytes: usize,
    current_bytes: AtomicUsize,
}
```

**Unsafe Pointers**: LRU list uses raw pointers for circular references
- Must ensure memory safety through careful ownership
- Alternative: Use indices or library-provided LRU implementation

### Synchronization

**Recommended**: RwLock for cache operations
```rust
impl PageCache {
    pub fn get(&self, page_id: u64) -> Option<&[u8]> {
        let entries = self.entries.read().unwrap();
        // Lookup and return reference
    }

    pub fn put(&self, page_id: u64, data: &[u8]) -> Result<(), CacheError> {
        let mut entries = self.entries.write().unwrap();
        // Insert with exclusive access
    }
}
```

**Challenge**: Returning reference from RwLock guard
- Reference lifetime tied to guard lifetime
- Guard must live as long as reference
- Makes pinning API more complex

**Alternative**: Use Arc for shared ownership
- CacheEntry wrapped in Arc
- get() returns Arc<[u8]>
- Caller holds reference explicitly
- Unpin drops Arc reference

### LRU Implementation

**Manual Doubly-Linked List**: Complex due to unsafe pointers

**Recommended**: Use third-party crate
- lru crate: Simple LRU cache
- lru-mem crate: LRU with size limits
- cacheping crate: Alternative caching library

**Example with lru crate**:
```rust
use lru::LruCache;

pub struct PageCache {
    entries: Mutex<LruCache<u64, Box<[u8; PAGE_SIZE]>>>,
    max_pages: usize,
    max_bytes: usize,
    current_bytes: AtomicUsize,
}
```

**Limitation**: Built-in LRU doesn't support pinning
- Need custom implementation or wrapper
- Track pinned pages separately

### Pinning API

**Rust Pattern**: Use RAII guard for automatic unpin
```rust
pub struct PageGuard<'a> {
    cache: &'a PageCache,
    page_id: u64,
}

impl<'a> Drop for PageGuard<'a> {
    fn drop(&mut self) {
        self.cache.unpin(self.page_id);
    }
}

impl PageCache {
    pub fn get(&self, page_id: u64) -> Option<(PageGuard, &[u8])> {
        // Returns guard and reference
        // Guard unpins on drop
    }
}
```

**Usage**:
```rust
if let Some((guard, data)) = cache.get(page_id) {
    // Use data
    println!("{:?}", data);
    // guard.unpin() called automatically on drop
}
```

### Testing Strategy

**Unit tests needed for**:
- Cache hit returns immediately without I/O
- Cache miss triggers storage read and cache insertion
- Unpin reduces pin count correctly
- Eviction removes least recently used unpinned page
- Pinned pages are never evicted
- Capacity limits enforced (entry count and byte count)
- Clear removes unpinned but not pinned pages

**Property tests for**:
- Cache hit rate improves with repeated reads of same pages
- LRU eviction removes oldest page when cache full
- Pin count goes to zero after corresponding number of unpins
- Memory usage never exceeds max_bytes (unless all pinned)

**Integration tests for**:
- Cached reads return same data as uncached reads
- Multiple concurrent readers can access cache simultaneously
- Cache correctly reflects storage contents after write
- Eviction does not lose dirty data (pages are not dirty in current design)
