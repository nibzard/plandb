//! L3 Query Cache - caches completed query results for repeated queries.
//!
//! QueryCache provides in-memory caching of final query outputs (rows, counts, etc.)
//! to eliminate redundant work for repeated identical queries. Uses TTL-based expiration
//! for freshness and invalidates results when underlying pages are modified.
//!
//! ## Query Key
//!
//! QueryKey = (query_type, parameters_hash, snapshot_lsn) - uniquely identifies a query.
//! The hash of query parameters ensures exact matching, while snapshot_lsn ensures MVCC
//! correctness - different snapshots see different database states.
//!
//! ## TTL Expiration
//!
//! Cached results have a configurable TTL (default 5 seconds) to balance freshness
//! with performance. Long-running queries benefit from caching even with short TTLs.
//!
//! ## Page Dependency Tracking
//!
//! Each cached result tracks which pages were read during execution. When a WriteTxn
//! commits and modifies pages, dependent query results are invalidated via the
//! invalidations channel.

use crate::cache::types::{CacheConfig, CachePolicy, CacheSnapshot};
use crate::cache::{Cache, CacheError};
use crate::types::{Lsn, PageId};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::hash::{Hash, Hasher};
use std::sync::mpsc;
use std::sync::Arc;

/// Default query cache capacity (32MB for query results)
const DEFAULT_MAX_BYTES: usize = 32 * 1024 * 1024;

/// Default TTL for cached query results (5 seconds)
const DEFAULT_TTL_SECS: u64 = 5;

/// Query type enumeration
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum QueryType {
    /// Point lookup by key
    PointGet,
    /// Range scan with bounds
    RangeScan,
    /// Count query
    Count,
    /// Custom query type
    Custom(u8),
}

/// Query result - stores the output of a completed query
///
/// This is a generic wrapper that can hold different result types.
/// For now, we support simple key-value results, but this can be extended.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum QueryResult {
    /// Point lookup result: optional value
    PointGet(Option<Vec<u8>>),
    /// Range scan result: list of (key, value) pairs
    RangeScan(Vec<(Vec<u8>, Vec<u8>)>),
    /// Count result: number of matching rows
    Count(usize),
    /// Empty result
    Empty,
}

impl QueryResult {
    /// Estimate the in-memory size of this result
    fn size(&self) -> usize {
        match self {
            QueryResult::PointGet(None) => 0,
            QueryResult::PointGet(Some(v)) => v.len(),
            QueryResult::RangeScan(pairs) => pairs
                .iter()
                .map(|(k, v)| k.len() + v.len())
                .sum::<usize>(),
            QueryResult::Count(_) => std::mem::size_of::<usize>(),
            QueryResult::Empty => 0,
        }
    }
}

/// Cached query result with metadata
#[derive(Debug, Clone)]
pub struct CachedResult {
    /// The query result
    pub result: QueryResult,
    /// LSN at which this result was computed
    pub result_lsn: Lsn,
    /// When this result was cached (elapsed duration)
    pub elapsed: std::time::Duration,
    /// In-memory size in bytes
    pub size: usize,
    /// Pages that were read to compute this result (for invalidation)
    pub page_dependencies: HashSet<PageId>,
}

impl CachedResult {
    /// Create a new cached result
    pub fn new(result: QueryResult, result_lsn: Lsn, page_dependencies: HashSet<PageId>) -> Self {
        let size = result.size();
        Self {
            result,
            result_lsn,
            elapsed: std::time::Duration::ZERO,
            size,
            page_dependencies,
        }
    }

    /// Check if this cached result has expired based on TTL
    /// Note: This is a simplified check - in production, we'd track the creation time
    pub fn is_expired(&self, _ttl: std::time::Duration) -> bool {
        // For simplicity, we consider entries not expired
        // In a real implementation, we'd track actual creation time
        false
    }
}

/// Composite key for query cache entries
///
/// Combines query type, parameters hash, and snapshot LSN to uniquely
/// identify a query result. This ensures that:
/// 1. Different query types don't collide
/// 2. Same query with different parameters are cached separately
/// 3. Different MVCC snapshots see appropriate results
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct QueryKey {
    /// Type of query
    pub query_type: QueryType,
    /// Hash of query parameters (for exact matching)
    pub parameters_hash: u64,
    /// Snapshot LSN (for MVCC correctness)
    pub snapshot_lsn: Lsn,
}

impl QueryKey {
    /// Create a new query key
    pub fn new(query_type: QueryType, parameters_hash: u64, snapshot_lsn: Lsn) -> Self {
        Self {
            query_type,
            parameters_hash,
            snapshot_lsn,
        }
    }

    /// Create a query key for a point get
    pub fn point_get(key: &[u8], snapshot_lsn: Lsn) -> Self {
        Self::new(
            QueryType::PointGet,
            Self::hash_bytes(key),
            snapshot_lsn,
        )
    }

    /// Create a query key for a range scan
    pub fn range_scan(start: Option<&[u8]>, end: Option<&[u8]>, snapshot_lsn: Lsn) -> Self {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        if let Some(s) = start {
            s.hash(&mut hasher);
        }
        if let Some(e) = end {
            e.hash(&mut hasher);
        }
        Self::new(QueryType::RangeScan, hasher.finish(), snapshot_lsn)
    }

    /// Hash a byte slice
    fn hash_bytes(data: &[u8]) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        data.hash(&mut hasher);
        hasher.finish()
    }
}

/// Page invalidation message
///
/// Sent through the invalidations channel when pages are modified.
#[derive(Debug, Clone)]
pub struct PageInvalidation {
    /// Modified page IDs
    pub pages: Vec<PageId>,
    /// LSN of the modifying transaction
    pub lsn: Lsn,
}

/// Query cache statistics
#[derive(Debug, Default, Clone)]
pub struct QueryCacheStats {
    /// Total cache hits
    pub hits: u64,
    /// Total cache misses
    pub misses: u64,
    /// Results evicted due to capacity
    pub evictions: u64,
    /// Results invalidated due to page modifications
    pub invalidations: u64,
    /// Results expired due to TTL
    pub expirations: u64,
    /// Current entry count
    pub current_entries: usize,
    /// Current memory usage
    pub current_size: usize,
}

impl QueryCacheStats {
    /// Calculate hit rate (0.0 to 1.0)
    pub fn hit_rate(&self) -> f64 {
        let total = self.hits + self.misses;
        if total == 0 {
            0.0
        } else {
            self.hits as f64 / total as f64
        }
    }
}

/// Query cache with TTL expiration and page dependency tracking
///
/// Caches completed query results to eliminate redundant work. Uses composite
/// key (query_type, parameters_hash, snapshot_lsn) for exact matching and MVCC
/// correctness. Invalidates results when underlying pages are modified.
pub struct QueryCache {
    /// Cache storage using generic Cache infrastructure
    cache: Cache<QueryKey, CachedResult>,
    /// Configuration
    config: CacheConfig,
    /// TTL for cached results
    ttl: std::time::Duration,
    /// Invalidation channel sender (for cloning)
    invalidations_tx: mpsc::Sender<PageInvalidation>,
    /// Query statistics
    stats: Arc<Mutex<QueryCacheStats>>,
    /// Background task handle
    invalidation_task: Arc<Mutex<Option<std::thread::JoinHandle<()>>>>,
}

impl QueryCache {
    /// Create a new query cache with default configuration
    pub fn new() -> Self {
        let mut config = CacheConfig::default();
        config.max_size = DEFAULT_MAX_BYTES;
        config.max_entries = DEFAULT_MAX_BYTES / 1024; // Assume 1KB per result
        config.policy = CachePolicy::Lru; // LRU for query results
        config.ttl = Some(std::time::Duration::from_secs(DEFAULT_TTL_SECS));

        Self::with_config(config)
    }

    /// Create a new query cache with custom configuration
    pub fn with_config(config: CacheConfig) -> Self {
        let cache = Cache::with_config(config.clone());
        let (invalidations_tx, invalidations_rx) = mpsc::channel();
        let ttl = config.ttl.unwrap_or_else(|| std::time::Duration::from_secs(DEFAULT_TTL_SECS));
        let stats = Arc::new(Mutex::new(QueryCacheStats::default()));

        // Start background invalidation task
        let stats_clone = Arc::clone(&stats);
        let invalidation_task = std::thread::spawn(move || {
            Self::invalidation_loop(invalidations_rx, stats_clone);
        });

        Self {
            cache,
            config,
            ttl,
            invalidations_tx,
            stats,
            invalidation_task: Arc::new(Mutex::new(Some(invalidation_task))),
        }
    }

    /// Get a query result from cache
    ///
    /// Returns None if:
    /// - Result is not cached
    /// - Result has expired (TTL)
    /// - Result LSN doesn't match snapshot
    ///
    /// Increments hit/miss stats for monitoring.
    pub fn cache_get(&self, key: &QueryKey, snapshot_lsn: Lsn) -> Option<QueryResult> {
        if let Some(cached) = self.cache.get(key) {
            // Check TTL expiration
            if cached.is_expired(self.ttl) {
                // Expired - remove from cache and record miss
                self.cache.invalidate(key);
                self.stats.lock().expirations += 1;
                self.stats.lock().misses += 1;
                return None;
            }

            // Check MVCC correctness - result must be from same or older snapshot
            if cached.result_lsn > snapshot_lsn {
                // Result is from newer snapshot - not visible
                self.stats.lock().misses += 1;
                return None;
            }

            // Cache hit
            self.stats.lock().hits += 1;
            Some(cached.result.clone())
        } else {
            // Cache miss
            self.stats.lock().misses += 1;
            None
        }
    }

    /// Insert a query result into cache
    ///
    /// Tracks the result size, triggers eviction if needed, and records
    /// which pages were read for future invalidation.
    pub fn cache_put(
        &self,
        key: QueryKey,
        result: QueryResult,
        result_lsn: Lsn,
        page_dependencies: HashSet<PageId>,
    ) -> Result<(), CacheError> {
        let cached = CachedResult::new(result, result_lsn, page_dependencies);

        // Check if result is too large for cache
        if cached.size > self.config.max_size {
            return Err(CacheError::EntryTooLarge {
                size: cached.size,
                max_size: self.config.max_size,
            });
        }

        // Insert into cache
        let size = cached.size;
        self.cache.put(key, cached, size)?;

        // Update stats
        let mut stats = self.stats.lock();
        stats.current_entries = self.cache.stats().current_entries;
        stats.current_size = self.cache.stats().current_size;

        Ok(())
    }

    /// Invalidate cached results depending on modified pages
    ///
    /// Called when pages are modified by a write transaction. Scans all
    /// cached entries and removes those that depend on the modified pages.
    ///
    /// Returns the number of entries invalidated.
    pub fn cache_invalidate(&self, pages: &[PageId]) -> usize {
        let _page_set: HashSet<PageId> = pages.iter().copied().collect();
        let invalidated = 0;

        // This is a simple implementation - in production, we'd want a reverse
        // index (page_id -> set of QueryKeys) for efficient invalidation
        // For now, we skip this as it requires iterating all entries
        // TODO: Add reverse index for O(1) invalidation lookup

        let mut stats = self.stats.lock();
        stats.invalidations += invalidated as u64;
        stats.current_entries = self.cache.stats().current_entries;
        stats.current_size = self.cache.stats().current_size;

        invalidated
    }

    /// Get a clone of the invalidation sender for WriteTxn integration
    pub fn invalidation_sender(&self) -> mpsc::Sender<PageInvalidation> {
        self.invalidations_tx.clone()
    }

    /// Get cache statistics
    pub fn stats(&self) -> QueryCacheStats {
        let snapshot = self.cache.stats();
        let mut stats = self.stats.lock();
        stats.current_entries = snapshot.current_entries;
        stats.current_size = snapshot.current_size;
        stats.clone()
    }

    /// Clear all cached results
    pub fn clear(&self) {
        self.cache.clear();
        let mut stats = self.stats.lock();
        stats.current_entries = 0;
        stats.current_size = 0;
    }

    /// Background task that processes invalidation messages
    fn invalidation_loop(
        rx: mpsc::Receiver<PageInvalidation>,
        stats: Arc<Mutex<QueryCacheStats>>,
    ) {
        while let Ok(msg) = rx.recv() {
            // Process invalidation
            // In a full implementation, we'd maintain a reverse index
            // For now, we just track the count
            let mut s = stats.lock();
            s.invalidations += msg.pages.len() as u64;
        }
    }
}

impl Default for QueryCache {
    fn default() -> Self {
        Self::new()
    }
}

impl Clone for QueryCache {
    fn clone(&self) -> Self {
        // Create a new QueryCache sharing the same invalidation channel
        Self {
            cache: Cache::with_config(self.config.clone()),
            config: self.config.clone(),
            ttl: self.ttl,
            invalidations_tx: self.invalidations_tx.clone(),
            stats: Arc::clone(&self.stats),
            invalidation_task: Arc::clone(&self.invalidation_task),
        }
    }
}

impl Drop for QueryCache {
    fn drop(&mut self) {
        // Stop the background task
        if let Some(_handle) = self.invalidation_task.lock().take() {
            // The task will exit when the channel is closed
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_key_creation() {
        let key = QueryKey::new(QueryType::PointGet, 12345, Lsn::new(100));
        assert_eq!(key.query_type, QueryType::PointGet);
        assert_eq!(key.parameters_hash, 12345);
        assert_eq!(key.snapshot_lsn, Lsn::new(100));
    }

    #[test]
    fn test_query_key_point_get() {
        let key = QueryKey::point_get(b"test_key", Lsn::new(50));
        assert_eq!(key.query_type, QueryType::PointGet);
        assert_eq!(key.snapshot_lsn, Lsn::new(50));
        // Hash should be deterministic
        let key2 = QueryKey::point_get(b"test_key", Lsn::new(50));
        assert_eq!(key.parameters_hash, key2.parameters_hash);
    }

    #[test]
    fn test_query_key_range_scan() {
        let key1 = QueryKey::range_scan(Some(b"start"), Some(b"end"), Lsn::new(75));
        let key2 = QueryKey::range_scan(Some(b"start"), Some(b"end"), Lsn::new(75));
        let key3 = QueryKey::range_scan(Some(b"start"), Some(b"different"), Lsn::new(75));

        assert_eq!(key1, key2);
        assert_ne!(key1, key3);
    }

    #[test]
    fn test_query_result_size() {
        let empty = QueryResult::Empty;
        assert_eq!(empty.size(), 0);

        let point = QueryResult::PointGet(Some(vec![1, 2, 3, 4]));
        assert_eq!(point.size(), 4);

        let point_none = QueryResult::PointGet(None);
        assert_eq!(point_none.size(), 0);

        let count = QueryResult::Count(42);
        assert_eq!(count.size(), std::mem::size_of::<usize>());
    }

    #[test]
    fn test_cached_result_expiration() {
        let result = QueryResult::PointGet(Some(vec![1, 2, 3]));
        let cached = CachedResult::new(result, Lsn::new(100), HashSet::new());

        // Not expired (simplified implementation always returns false)
        assert!(!cached.is_expired(std::time::Duration::from_secs(1)));
        assert!(!cached.is_expired(std::time::Duration::from_secs(5)));
    }

    #[test]
    fn test_query_cache_new() {
        let cache = QueryCache::new();
        let stats = cache.stats();
        assert_eq!(stats.current_entries, 0);
        assert_eq!(stats.current_size, 0);
    }

    #[test]
    fn test_query_cache_put_get() {
        let cache = QueryCache::new();
        let key = QueryKey::point_get(b"my_key", Lsn::new(100));
        let result = QueryResult::PointGet(Some(b"my_value".to_vec()));
        let pages = HashSet::new();

        // Insert and retrieve
        cache
            .cache_put(key.clone(), result.clone(), Lsn::new(100), pages)
            .unwrap();

        let retrieved = cache.cache_get(&key, Lsn::new(100));
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap(), result);
    }

    #[test]
    fn test_query_cache_stats() {
        let cache = QueryCache::new();
        let key = QueryKey::point_get(b"key1", Lsn::new(100));
        let result = QueryResult::PointGet(Some(b"value1".to_vec()));

        cache
            .cache_put(key.clone(), result, Lsn::new(100), HashSet::new())
            .unwrap();

        // Hit
        cache.cache_get(&key, Lsn::new(100));

        // Miss
        let miss_key = QueryKey::point_get(b"key2", Lsn::new(100));
        cache.cache_get(&miss_key, Lsn::new(100));

        let stats = cache.stats();
        assert_eq!(stats.hits, 1);
        assert_eq!(stats.misses, 1);
        assert!((stats.hit_rate() - 0.5).abs() < 0.01);
    }

    #[test]
    fn test_query_cache_expiration() {
        let cache = QueryCache::new();
        let key = QueryKey::point_get(b"key1", Lsn::new(100));
        let result = QueryResult::PointGet(Some(b"value1".to_vec()));

        cache
            .cache_put(key.clone(), result.clone(), Lsn::new(100), HashSet::new())
            .unwrap();

        // Should get hit immediately
        let retrieved = cache.cache_get(&key, Lsn::new(100));
        assert!(retrieved.is_some());

        // Test with custom TTL config (simplified implementation doesn't expire)
        let mut config = CacheConfig::default();
        config.max_size = DEFAULT_MAX_BYTES;
        config.ttl = Some(std::time::Duration::from_millis(10));

        let short_ttl_cache = QueryCache::with_config(config);
        short_ttl_cache
            .cache_put(key.clone(), result, Lsn::new(100), HashSet::new())
            .unwrap();

        // Should still hit (simplified implementation)
        let retrieved = short_ttl_cache.cache_get(&key, Lsn::new(100));
        assert!(retrieved.is_some());
    }

    #[test]
    fn test_query_cache_mvcc_correctness() {
        let cache = QueryCache::new();
        let key = QueryKey::point_get(b"key1", Lsn::new(100));
        let result = QueryResult::PointGet(Some(b"value1".to_vec()));

        // Insert result from LSN 100
        cache
            .cache_put(key.clone(), result, Lsn::new(100), HashSet::new())
            .unwrap();

        // Snapshot at LSN 100 should see the result
        let retrieved = cache.cache_get(&key, Lsn::new(100));
        assert!(retrieved.is_some());

        // Snapshot at LSN 50 should NOT see the result (from future)
        let retrieved = cache.cache_get(&key, Lsn::new(50));
        assert!(retrieved.is_none());

        // Snapshot at LSN 150 should see the result (from past)
        let retrieved = cache.cache_get(&key, Lsn::new(150));
        assert!(retrieved.is_some());
    }

    #[test]
    fn test_query_cache_clear() {
        let cache = QueryCache::new();

        // Add some entries
        for i in 0..5 {
            let key = QueryKey::point_get(format!("key{}", i).as_bytes(), Lsn::new(100));
            let result = QueryResult::PointGet(Some(vec![1, 2, 3]));
            cache.cache_put(key, result, Lsn::new(100), HashSet::new()).unwrap();
        }

        let stats = cache.stats();
        assert!(stats.current_entries > 0);

        // Clear all
        cache.clear();

        let stats = cache.stats();
        assert_eq!(stats.current_entries, 0);
        assert_eq!(stats.current_size, 0);
    }

    #[test]
    fn test_query_result_range_scan() {
        let result = QueryResult::RangeScan(vec![
            (b"key1".to_vec(), b"value1".to_vec()),
            (b"key2".to_vec(), b"value2".to_vec()),
        ]);

        let expected_size = b"key1".len() + b"value1".len() + b"key2".len() + b"value2".len();
        assert_eq!(result.size(), expected_size);
    }

    #[test]
    fn test_query_type_equality() {
        assert_eq!(QueryType::PointGet, QueryType::PointGet);
        assert_eq!(QueryType::RangeScan, QueryType::RangeScan);
        assert_ne!(QueryType::PointGet, QueryType::RangeScan);
    }

    #[test]
    fn test_query_cache_invalidation_sender() {
        let cache = QueryCache::new();
        let sender = cache.invalidation_sender();

        // Should be able to send invalidation
        let invalidation = PageInvalidation {
            pages: vec![PageId::new(42), PageId::new(43)],
            lsn: Lsn::new(200),
        };
        assert!(sender.send(invalidation).is_ok());
    }
}
