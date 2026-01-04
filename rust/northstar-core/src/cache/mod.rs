//! Multi-level caching system for NorthstarDB
//!
//! This module provides a three-level caching system:
//! - L1 Page Cache: 16KB disk pages with checksum validation
//! - L2 Node Cache: B+Tree internal nodes for faster traversal
//! - L3 Query Cache: Completed query results for repeated queries
//!
//! The cache supports multiple eviction policies (LRU, LFU, ARC) and
//! uses sharded design for high concurrency.

pub mod bench;
pub mod error;
pub mod page;
pub mod shard;
pub mod types;

pub use error::{CacheError, CacheResult};
pub use page::PageCache;
pub use shard::CacheShard;
pub use types::{
    CacheConfig, CacheEntry, CachePolicy, CacheSnapshot, CacheStats, ClearResult, PinGuard,
};

use std::hash::Hash;

/// Generic cache interface
pub struct Cache<K, V>
where
    K: Clone + Eq + Hash,
{
    /// Sharded cache for concurrent access
    pub shards: Vec<CacheShard<K, V>>,
    /// Configuration
    pub config: CacheConfig,
}

impl<K, V> Cache<K, V>
where
    K: Clone + Eq + Hash,
{
    /// Create a new cache with default configuration
    pub fn new() -> Self {
        Self::with_config(CacheConfig::default())
    }

    /// Create a new cache with custom configuration
    pub fn with_config(config: CacheConfig) -> Self {
        config.validate().unwrap();

        let shard_count = config.shard_count;
        let policy = config.policy;

        let shards = (0..shard_count)
            .map(|i| CacheShard::new(policy, config.clone(), i))
            .collect();

        Self { shards, config }
    }

    /// Get value from cache
    pub fn get(&self, key: &K) -> Option<V>
    where
        V: Clone,
    {
        let shard_idx = self.shard_index(key);
        self.shards[shard_idx].get(key)
    }

    /// Insert value into cache
    pub fn put(&self, key: K, value: V, size: usize) -> CacheResult<()>
    where
        V: Clone,
    {
        let shard_idx = self.shard_index(&key);
        self.shards[shard_idx].put(key, value, size)
    }

    /// Invalidate entry
    pub fn invalidate(&self, key: &K) -> bool
    where
        V: Clone,
    {
        let shard_idx = self.shard_index(key);
        self.shards[shard_idx].invalidate(key)
    }

    /// Pin entry to prevent eviction
    pub fn pin(&self, key: &K) -> bool {
        let shard_idx = self.shard_index(key);
        self.shards[shard_idx].pin(key)
    }

    /// Unpin entry
    pub fn unpin(&self, key: &K) -> bool {
        let shard_idx = self.shard_index(key);
        self.shards[shard_idx].unpin(key)
    }

    /// Clear all entries
    pub fn clear(&self) -> ClearResult
    where
        V: Clone,
    {
        let mut result = ClearResult::default();
        for shard in &self.shards {
            let shard_result = shard.clear();
            result.entries_cleared += shard_result.entries_cleared;
            result.dirty_pages_written += shard_result.dirty_pages_written;
            result.memory_freed += shard_result.memory_freed;
        }
        result
    }

    /// Get cache statistics
    pub fn stats(&self) -> CacheSnapshot {
        let mut total_hits: u64 = 0;
        let mut total_misses: u64 = 0;
        let mut total_evictions: u64 = 0;
        let mut total_size: usize = 0;
        let mut total_entries: usize = 0;
        let mut total_dirty: usize = 0;
        let mut total_pinned: usize = 0;

        for shard in &self.shards {
            let snapshot = shard.stats();
            total_hits = total_hits.saturating_add(snapshot.hits);
            total_misses = total_misses.saturating_add(snapshot.misses);
            total_evictions = total_evictions.saturating_add(snapshot.evictions);
            total_size = total_size.saturating_add(snapshot.current_size);
            total_entries = total_entries.saturating_add(snapshot.current_entries);
            total_dirty = total_dirty.saturating_add(snapshot.dirty_pages);
            total_pinned = total_pinned.saturating_add(snapshot.pinned_entries);
        }

        let total_requests = total_hits.saturating_add(total_misses);
        let hit_rate = if total_requests > 0 {
            total_hits as f64 / total_requests as f64
        } else {
            0.0
        };

        CacheSnapshot {
            hits: total_hits,
            misses: total_misses,
            evictions: total_evictions,
            hit_rate,
            current_size: total_size,
            current_entries: total_entries,
            dirty_pages: total_dirty,
            pinned_entries: total_pinned,
        }
    }

    /// Compute shard index for a key
    fn shard_index(&self, key: &K) -> usize {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        key.hash(&mut hasher);
        let hash_val = hasher.finish();
        (hash_val as usize) % self.shards.len()
    }
}

impl<K, V> Default for Cache<K, V>
where
    K: Clone + Eq + Hash,
{
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cache_basic_operations() {
        let cache: Cache<String, i32> = Cache::new();

        // Put and get
        cache.put("key1".to_string(), 42, 8).unwrap();
        assert_eq!(cache.get(&"key1".to_string()), Some(42));

        // Update
        cache.put("key1".to_string(), 100, 8).unwrap();
        assert_eq!(cache.get(&"key1".to_string()), Some(100));

        // Invalidate
        cache.invalidate(&"key1".to_string());
        assert_eq!(cache.get(&"key1".to_string()), None);
    }

    #[test]
    fn test_cache_stats() {
        let cache: Cache<String, i32> = Cache::new();

        cache.put("key1".to_string(), 42, 8).unwrap();
        cache.get(&"key1".to_string());
        cache.get(&"key2".to_string()); // Miss

        let stats = cache.stats();
        assert_eq!(stats.hits, 1);
        assert_eq!(stats.misses, 1);
        assert!((stats.hit_rate - 0.5).abs() < 0.01);
    }

    #[test]
    fn test_cache_clear() {
        let cache: Cache<String, i32> = Cache::new();

        cache.put("key1".to_string(), 1, 8).unwrap();
        cache.put("key2".to_string(), 2, 8).unwrap();

        let result = cache.clear();
        assert_eq!(result.entries_cleared, 2);
        assert_eq!(cache.stats().current_entries, 0);
    }
}
