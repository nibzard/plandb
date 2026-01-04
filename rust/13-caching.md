# Caching Strategies

## Purpose

Multi-level caching system for NorthstarDB that minimizes disk I/O and reduces latency for frequently accessed data. Caching operates at three levels: page cache (disk blocks), B+Tree node cache (internal nodes), and query result cache (completed queries). Cache policies are adaptive based on access patterns, with automatic eviction when memory limits are reached.

## Types

### CacheEntry

**Description**: Generic cache entry storing key-value pair with metadata for tracking access patterns and eviction decisions.

**Fields**:
- `key: K` - Cache key (PageId for page cache, composite key for node cache)
- `value: V` - Cached value (Page for page cache, Node for node cache)
- `access_count: u64` - Number of times this entry has been accessed
- `last_access: Instant` - Timestamp of most recent access
- `size: usize` - Memory size in bytes
- `dirty: bool` - Whether value has been modified (page cache only)
- `pin_count: AtomicUsize` - Number of pins preventing eviction (for in-use entries)

**Size**: Variable (key size + value size + 32 bytes metadata)
**Invariants**:
- `access_count` is monotonically increasing
- `last_access` is never older than entry creation time
- `pin_count > 0` means entry cannot be evicted
- `dirty == true` implies entry must be written before eviction

### CachePolicy

**Description**: Enumeration of cache eviction policies supported by the cache system.

**Variants**:
- `LRU` - Least Recently Used: evict entries with oldest access time
- `LFU` - Least Frequently Used: evict entries with lowest access count
- `ARC` - Adaptive Replacement Cache: balances between recency and frequency
- `FIFO` - First In First Out: evict oldest entries regardless of access
- `LIFO` - Last In First Out: evict most recently added entries

**Default**: `ARC` for adaptive behavior, `LRU` for simple workloads

### CacheStats

**Description**: Performance metrics for cache monitoring and tuning.

**Fields**:
- `hits: AtomicU64` - Number of cache hits (lookups found in cache)
- `misses: AtomicU64` - Number of cache misses (lookups not in cache)
- `evictions: AtomicU64` - Number of entries evicted
- `insertions: AtomicU64` - Number of entries inserted
- `dirty_evictions: AtomicU64` - Number of dirty entries evicted (requiring write)
- `current_size: AtomicUsize` - Current memory usage in bytes
- `current_entries: AtomicUsize` - Current number of entries
- `pin_count: AtomicUsize` - Number of currently pinned entries

**Derived Metrics**:
- `hit_rate = hits / (hits + misses)` - Cache effectiveness (0.0 to 1.0)
- `avg_entry_size = current_size / current_entries` - Average entry size

### CacheConfig

**Description**: Configuration parameters for cache behavior.

**Fields**:
- `max_size: usize` - Maximum memory usage in bytes (default: 256MB)
- `max_entries: usize` - Maximum number of entries (default: 100,000)
- `policy: CachePolicy` - Eviction policy to use (default: ARC)
- `shard_count: usize` - Number of cache shards for lock scalability (default: number of CPU cores)
- `enable_stats: bool` - Whether to collect detailed statistics (default: true)
- `enable_prefetch: bool` - Whether to enable prefetch hints (default: true)
- `ttl: Option<Duration>` - Time-to-live for entries (None = no expiration)
- `write_back: bool` - Lazy write-back for dirty entries (default: true)
- `write_back_interval: Duration` - Background write-back interval (default: 1 second)

**Validation Rules**:
- `max_size` must be >= 1MB
- `max_entries` must be >= 1000
- `shard_count` must be a power of 2
- `ttl` if present must be >= 1 millisecond

### PageCache

**Description**: L1 cache for disk pages, stores complete 16KB pages with checksum validation.

**Fields**:
- `shards: Vec<CacheShard<PageId, Page>>` - Sharded cache for concurrent access
- `config: Arc<CacheConfig>` - Shared configuration
- `stats: Arc<CacheStats>` - Shared statistics
- `pager: Arc<Pager>` - Reference to pager for page loading
- `writeback_task: Option<JoinHandle<()>>` - Background write-back task handle

**Size**: Configuration-dependent (typically ~256MB across all shards)
**Invariants**:
- Total memory usage across shards <= `config.max_size`
- Total entries across shards <= `config.max_entries`
- Dirty pages tracked for write-back before eviction

### NodeCache

**Description**: L2 cache for B+Tree internal nodes, stores decoded node structures for faster traversal.

**Fields**:
- `shards: Vec<CacheShard<NodeKey, Node>>` - Sharded cache by (page_id, lsn)
- `config: Arc<CacheConfig>` - Shared configuration
- `stats: Arc<CacheStats>` - Shared statistics
- `page_cache: Arc<PageCache>` - L1 cache for loading nodes

**NodeKey**: Composite key of `(page_id: PageId, lsn: Lsn)` to distinguish node versions

**Size**: Configuration-dependent (typically ~64MB, smaller than page cache)
**Invariants**:
- Node versions keyed by LSN for MVCC correctness
- Nodes evicted before their underlying pages (dependency management)

### QueryCache

**Description**: L3 cache for completed query results, stores final query outputs for repeated identical queries.

**Fields**:
- `inner: Arc<RwLock<HashMap<QueryKey, CachedResult>>>` - Single shard due to lower contention
- `config: Arc<CacheConfig>` - Shared configuration
- `stats: Arc<CacheStats>` - Shared statistics
- `invalidations: Arc<crossbeam::channel::Sender<PageId>>` - Invalidation channel

**QueryKey**: Hash of (query_type, parameters, snapshot_lsn) for exact match

**CachedResult**:
- `result: QueryResult` - Query output (rows, count, etc.)
- `result_lsn: Lsn` - LSN at which query was executed
- `creation_time: Instant` - When result was cached
- `size: usize` - Memory size of result

**Size**: Configuration-dependent (typically ~32MB, smallest cache)
**Invariants**:
- Results invalidated when underlying pages modified
- TTL-based expiration for freshness (default: 5 seconds)

### CacheShard<K, V>

**Description**: Single cache shard with independent lock for concurrent access.

**Fields**:
- `entries: RwLock<HashMap<K, CacheEntry<V>>>` - Protected entry map
- `policy: CachePolicy` - Eviction policy for this shard
- `lru_list: Mutex<LinkedList<K>>` - LRU tracking (LRU policy only)
- `lfu_heap: Mutex<BinaryHeap<AccessCountEntry>>` - LFU tracking (LFU policy only)
- `arc_state: Mutex<ArcState>` - ARC adaptive state (ARC policy only)

**ArcState**:
- `p: usize` - Size of T1 (recently used)
- `q: usize` - Size of B2 (frequently used)
- `t1: HashMap<K, ()>` - Ghost list for recently evicted
- `t2: HashMap<K, ()>` - Ghost list for frequently evicted
- `delta_t1: usize` - Adaptive increments for T1
- `delta_t2: usize` - Adaptive increments for T2

**Size**: ~8MB per shard (256MB / 32 cores)
**Invariants**:
- Each shard is independent with no cross-shard locks
- Hash(key) % shard_count determines target shard
- Eviction only affects local shard

## Functions

### cache_get<K, V>(cache: &Cache<K, V>, key: K) -> Option<V>

**Purpose**: Retrieve value from cache, updating access metadata on hit.

**Parameters**:
- `cache: &Cache<K, V>` - Cache to query
- `key: K` - Key to look up

**Returns**: `Option<V>` - Some(value) if found, None if miss

**Algorithm**:
1. Compute shard index: `shard_idx = hash(key) % shard_count`
2. Acquire read lock on target shard
3. Look up entry in shard's HashMap
4. On miss:
   - Increment `stats.misses`
   - Return None
5. On hit:
   - Increment `stats.hits`
   - Increment entry's `access_count`
   - Update entry's `last_access` to now
   - Update LRU tracking (move to front if LRU policy)
   - Update LFU tracking (increment counter if LFU policy)
   - Increment entry's `pin_count`
   - Clone value (or return reference if zero-copy)
   - Release read lock
   - Return Some(value)

**Error Conditions**: None (cache lookups are infallible)

**Concurrency**: Multiple readers can access different shards concurrently. Same shard requires read lock (multiple readers allowed).

### cache_put<K, V>(cache: &Cache<K, V>, key: K, value: V, size: usize) -> Result<(), CacheError>

**Purpose**: Insert or update entry in cache, triggering eviction if needed.

**Parameters**:
- `cache: &Cache<K, V>` - Cache to modify
- `key: K` - Key to insert
- `value: V` - Value to store
- `size: usize` - Memory size of value

**Returns**: `Result<(), CacheError>` - Success or error

**Algorithm**:
1. Compute shard index: `shard_idx = hash(key) % shard_count`
2. Acquire write lock on target shard
3. Check if key already exists:
   - If yes: Update value, update metadata, release lock, return Ok
4. Check capacity constraints:
   - Calculate new size: `current_size + size`
   - Calculate new entries: `current_entries + 1`
   - If new_size > max_size OR new_entries > max_entries:
     - Trigger eviction loop:
       - Select victim entry based on policy
       - Skip entry if `pin_count > 0` (pinned entries protected)
       - Remove victim from cache
       - If victim is dirty (page cache), queue for write-back
       - Update eviction statistics
       - Repeat until capacity available
5. Insert new entry:
   - Create `CacheEntry` with key, value, size
   - Initialize `access_count = 1`, `last_access = now`
   - Insert into shard's HashMap
   - Update insertion statistics
6. Release write lock
7. Return Ok

**Error Conditions**:
- `CacheError::EntryTooLarge`: Value size exceeds max_size
- `CacheError::CacheFull`: Cannot evict enough entries (all pinned)
- `CacheError::Poisoned`: Lock poisoned (concurrent access bug)

**Concurrency**: Exclusive write lock on shard. Blocks all other access to same shard.

### cache_invalidate<K, V>(cache: &Cache<K, V>, key: K) -> bool

**Purpose**: Remove entry from cache, writing back if dirty.

**Parameters**:
- `cache: &Cache<K, V>` - Cache to modify
- `key: K` - Key to invalidate

**Returns**: `bool` - True if entry was present and removed

**Algorithm**:
1. Compute shard index: `shard_idx = hash(key) % shard_count`
2. Acquire write lock on target shard
3. Check if key exists:
   - If no: Release lock, return false
4. Remove entry from HashMap
5. If entry is dirty (page cache):
   - Write page to pager
   - Mark as clean
6. Update statistics (increment evictions if dirty)
7. Release lock
8. Return true

**Error Conditions**: None (invalidation is infallible)

**Concurrency**: Exclusive write lock on shard.

### cache_pin<K, V>(cache: &Cache<K, V>, key: K) -> Option<PinGuard<V>>

**Purpose**: Pin entry to prevent eviction while in use, returning guard that auto-unpins on drop.

**Parameters**:
- `cache: &Cache<K, V>` - Cache to pin from
- `key: K` - Key to pin

**Returns**: `Option<PinGuard<V>>` - Some(guard) if found, None if miss

**Algorithm**:
1. Compute shard index: `shard_idx = hash(key) % shard_count`
2. Acquire read lock on target shard
3. Look up entry
4. If not found: Release lock, return None
5. Increment entry's `pin_count` (atomic fetch_add)
6. Create `PinGuard` holding reference to cache and key
7. Release read lock
8. Return Some(guard)

**PinGuard Behavior**:
- Implements `Drop` trait
- On drop: decrement `pin_count`, allowing eviction
- Holds reference to value (zero-copy access)

**Error Conditions**: None

**Concurrency**: Read lock on shard. Atomic increment on pin_count.

### cache_clear<K, V>(cache: &Cache<K, V>) -> ClearResult

**Purpose**: Empty all cache entries, writing back dirty pages.

**Returns**: `ClearResult` - Statistics about cleared entries

**ClearResult**:
- `entries_cleared: usize` - Total entries removed
- `dirty_pages_written: usize` - Dirty pages flushed
- `memory_freed: usize` - Total bytes freed

**Algorithm**:
1. Create `ClearResult` initialized to zeros
2. For each shard:
   - Acquire write lock
   - Iterate all entries:
     - If dirty: Write to pager, increment `dirty_pages_written`
     - Remove entry, increment `entries_cleared`
     - Add size to `memory_freed`
   - Clear shard's HashMap
   - Reset policy-specific state (LRU list, LFU heap, ARC state)
   - Release write lock
3. Reset global statistics (hits, misses, evictions)
4. Return `ClearResult`

**Error Conditions**: Returns partial results if write-back fails

**Concurrency**: Locks all shards sequentially. Blocks all cache access during clear.

### cache_stats<K, V>(cache: &Cache<K, V>) -> CacheSnapshot

**Purpose**: Capture current cache statistics for monitoring.

**Returns**: `CacheSnapshot` - Point-in-time statistics

**CacheSnapshot**:
- `hits: u64` - Total cache hits
- `misses: u64` - Total cache misses
- `evictions: u64` - Total evictions
- `hit_rate: f64` - Hit ratio (0.0 to 1.0)
- `current_size: usize` - Current memory usage
- `current_entries: usize` - Current entry count
- `dirty_pages: usize` - Number of dirty pages (page cache only)
- `pinned_entries: usize` - Number of pinned entries
- `shard_stats: Vec<ShardStats>` - Per-shard breakdown

**Algorithm**:
1. Read atomic counters from `stats`
2. Compute `hit_rate = hits / (hits + misses)` (handle divide-by-zero)
3. For each shard:
   - Acquire read lock
   - Count dirty and pinned entries
   - Collect per-shard metrics
   - Release read lock
4. Return `CacheSnapshot`

**Error Conditions**: None (statistics read is infallible)

**Concurrency**: Read locks on each shard (non-blocking).

### evict_lru<K, V>(shard: &mut CacheShard<K, V>, required_bytes: usize) -> usize

**Purpose**: Evict least-recently-used entries until capacity available (LRU policy).

**Parameters**:
- `shard: &mut CacheShard<K, V>` - Shard to evict from
- `required_bytes: usize` - Bytes to free

**Returns**: `usize` - Bytes actually freed

**Algorithm**:
1. Initialize `freed_bytes = 0`
2. While `freed_bytes < required_bytes` AND LRU list not empty:
   - Pop oldest key from back of LRU list
   - Look up entry in HashMap
   - If `pin_count > 0`: Skip entry, continue loop
   - Remove entry from HashMap
   - Add entry.size to `freed_bytes`
   - If entry is dirty: Queue for write-back
3. Return `freed_bytes`

**Concurrency**: Requires write lock on shard.

### evict_lfu<K, V>(shard: &mut CacheShard<K, V>, required_bytes: usize) -> usize

**Purpose**: Evict least-frequently-used entries until capacity available (LFU policy).

**Algorithm**:
1. Initialize `freed_bytes = 0`
2. While `freed_bytes < required_bytes` AND LFU heap not empty:
   - Pop entry with lowest access_count from heap
   - If `pin_count > 0`: Skip entry, continue loop
   - Remove entry from HashMap
   - Add entry.size to `freed_bytes`
   - If entry is dirty: Queue for write-back
3. Return `freed_bytes`

**Concurrency**: Requires write lock on shard.

### evict_arc<K, V>(shard: &mut CacheShard<K, V>, required_bytes: usize) -> usize

**Purpose**: Adaptive Replacement Cache eviction, balances between recency and frequency.

**Algorithm**:
1. Initialize `freed_bytes = 0`
2. Check adaptive state:
   - If `delta_t1 > delta_t2`: Prefer evicting from T2 (frequent)
   - If `delta_t2 > delta_t1`: Prefer evicting from T1 (recent)
3. While `freed_bytes < required_bytes`:
   - Select victim list based on adaptive state
   - Pop oldest key from selected list
   - If `pin_count > 0`: Skip entry, continue loop
   - Remove entry from HashMap
   - Add to ghost list (t1 or t2)
   - Increment corresponding delta counter
   - Add entry.size to `freed_bytes`
   - If entry is dirty: Queue for write-back
4. Adapt `p` and `q` values based on ghost list hits
5. Return `freed_bytes`

**Concurrency**: Requires write lock on shard.

### prefetch_pages(page_cache: &PageCache, page_ids: Vec<PageId>) -> Result<(), CacheError>

**Purpose**: Asynchronously prefetch pages into cache before they are needed.

**Parameters**:
- `page_cache: &PageCache` - Page cache to populate
- `page_ids: Vec<PageId>` - Pages to prefetch

**Returns**: `Result<(), CacheError>`

**Algorithm**:
1. Spawn background task
2. For each page_id in page_ids:
   - Check if page already in cache
   - If present: Skip, continue to next page
   - If absent:
     - Load page from pager
     - Insert into cache with low priority (prefetch flag)
     - Yield to async runtime
3. Return Ok immediately (non-blocking)

**Error Conditions**: Returns Ok even if some prefetches fail (best-effort)

**Concurrency**: Runs concurrently with main operations. Locks individual shards.

### invalidate_query_cache(query_cache: &QueryCache, modified_pages: Vec<PageId>) -> usize

**Purpose**: Invalidate query results that depend on modified pages.

**Parameters**:
- `query_cache: &QueryCache` - Query cache to invalidate
- `modified_pages: Vec<PageId>` - Pages that were modified

**Returns**: `usize` - Number of query results invalidated

**Algorithm**:
1. Acquire write lock on query cache
2. Initialize `invalidated = 0`
3. Iterate all cached query results:
   - Check if query result depends on any modified page
   - If yes: Remove entry, increment `invalidated`
4. Release write lock
5. Return `invalidated`

**Dependency Tracking**: Each `CachedResult` tracks which pages it read during execution

**Concurrency**: Write lock on query cache (single shard).

## Invariants

- **Capacity Invariant**: Total cache memory never exceeds `max_size`
- **Entry Count Invariant**: Total entries never exceeds `max_entries`
- **Pin Safety**: Pinned entries are never evicted
- **Write-Back Before Eviction**: Dirty pages are written before eviction
- **Shard Independence**: Cache shards operate independently without cross-shard locks
- **Monotonic Statistics**: Hit/miss counters only increase
- **TTL Expiration**: Expired entries not returned (if TTL configured)
- **Query Dependency**: Query results invalidated when underlying pages modified

## Dependencies

**Uses**:
- `crate::pager::Pager` - For loading pages on cache miss
- `crate::btree::Node` - For node cache entries
- `crate::types::PageId, Lsn` - For cache keys
- `parking_lot::RwLock, Mutex` - For concurrent access
- `std::collections::HashMap, LinkedList, BinaryHeap` - For cache storage
- `crossbeam::channel` - For invalidation signaling
- `atomic` - For lock-free statistics

**Used by**:
- `crate::pager::Pager` - Integrates page cache for read operations
- `crate::btree::Tree` - Integrates node cache for traversal
- `crate::db::Db` - Integrates query cache for result caching

## Rust Implementation Guidance

### Module Structure

```
northstar-core/src/cache/
├── mod.rs           # Cache module exports
├── entry.rs         # CacheEntry and PinGuard
├── policy.rs        # CachePolicy enum and eviction algorithms
├── stats.rs         # CacheStats and CacheSnapshot
├── config.rs        # CacheConfig and validation
├── shard.rs         # CacheShard implementation
├── page.rs          # PageCache implementation
├── node.rs          # NodeCache implementation
├── query.rs         # QueryCache implementation
└── prefetch.rs      # Prefetch heuristics and task spawning
```

### Type Definitions

- **CacheEntry<K, V>**: Generic struct with key, value, metadata. Use `HashMap<K, CacheEntry<V>>` for storage.
- **CachePolicy**: Enum with `#[derive(Clone, Copy, Debug, PartialEq)]`. Default to `CachePolicy::ARC`.
- **CacheConfig**: Struct with `#[derive(Clone)]`. Use `Arc<CacheConfig>` for sharing across shards.
- **CacheStats**: Struct with `AtomicU64` and `AtomicUsize` fields for lock-free reads.
- **PinGuard<V>**: RAII guard with `Deref<Target=V>` for zero-copy access. Implements `Drop` for auto-unpin.

### Concurrency

- **Sharding**: Use `Vec<Arc<CacheShard<K, V>>>` with shard_count = number of CPU cores. Hash key to determine shard: `hash(key) % shard_count`.
- **Lock Strategy**: Use `parking_lot::RwLock` instead of `std::sync::RwLock` for better performance. Read locks for gets, write locks for puts.
- **Statistics**: Use `AtomicU64` and `AtomicUsize` for lock-free statistic reads. Expensive statistics (dirty page count) use read locks.
- **Pin Safety**: Use `AtomicUsize` for pin_count. Pin operations use `fetch_add(1, Ordering::Acquire)` and unpin uses `fetch_sub(1, Ordering::Release)`.

### Key Decisions

- **Sharding vs Single Lock**: Shard the cache to reduce lock contention. Each shard has independent locks. No cross-shard locks.
- **Cache Size**: Default to 256MB for page cache, 64MB for node cache, 32MB for query cache. Make configurable via CacheConfig.
- **Eviction Policy**: Default to ARC (Adaptive Replacement Cache) for adaptive behavior. Fall back to LRU for simplicity.
- **Write-Back**: Lazy write-back for dirty pages. Background task flushes dirty pages every 1 second (configurable).
- **Prefetch**: Best-effort prefetching. Spawn background task, return immediately. Prefetch failures are ignored.
- **Query Invalidation**: Track page dependencies per query result. Invalidate results when underlying pages are modified.
- **Pin Guards**: Use RAII guards for pinning. Auto-unpin on drop prevents leaks.
- **Statistics**: Enable detailed statistics by default. Disable in production for performance (optional).
- **TTL**: Optional TTL for query cache (default 5 seconds). No TTL for page/node caches (manual invalidation only).
- **Cache Hierarchies**: Page cache (L1) is source of truth. Node cache (L2) depends on page cache. Query cache (L3) is independent.

### Testing Requirements

**Unit Tests**:
- Test cache hit/miss tracking
- Test eviction policies (LRU, LFU, ARC)
- Test pin/unpin prevents eviction
- Test dirty page write-back on eviction
- Test capacity limits enforced
- Test sharding distributes keys evenly
- Test TTL expiration (query cache only)
- Test statistics accuracy

**Integration Tests**:
- Test page cache integration with Pager
- Test node cache integration with B+Tree
- Test query cache invalidation on page modification
- Test prefetch task completes asynchronously
- Test background write-back flushes dirty pages

**Performance Tests**:
- Benchmark cache hit rate with realistic workloads
- Benchmark lock contention under high concurrency
- Benchmark eviction policy effectiveness
- Benchmark cache warmup time

### Example Usage

```rust
// Create page cache with default config
let config = CacheConfig::default()
    .max_size(256 * 1024 * 1024) // 256MB
    .shard_count(num_cpus::get())
    .policy(CachePolicy::ARC);
let page_cache = PageCache::new(pager, config)?;

// Cache get with pin guard
if let Some(guard) = cache_pin(&page_cache, page_id)? {
    // Use page while pinned (prevents eviction)
    let value = guard.key();
    process_value(value);
    // Auto-unpin when guard dropped
} else {
    // Cache miss, load from storage
    let page = pager.read_page(page_id)?;
    cache_put(&page_cache, page_id, page.clone(), page.size())?;
}

// Async prefetch
prefetch_pages(&page_cache, vec![page_id1, page_id2, page_id3])?;
// Continue with other work while prefetching in background
```
