//! Core cache type definitions

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::Instant;

use crate::cache::error::CacheResult;

/// Cache eviction policies
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CachePolicy {
    /// Least Recently Used: evict entries with oldest access time
    Lru,
    /// Least Frequently Used: evict entries with lowest access count
    Lfu,
    /// Adaptive Replacement Cache: balances between recency and frequency
    Arc,
    /// First In First Out: evict oldest entries regardless of access
    Fifo,
    /// Last In First Out: evict most recently added entries
    Lifo,
}

impl Default for CachePolicy {
    fn default() -> Self {
        Self::Arc
    }
}

/// Generic cache entry storing key-value pair with metadata
#[derive(Debug)]
pub struct CacheEntry<V> {
    /// Cached value
    pub value: V,
    /// Number of times this entry has been accessed
    pub access_count: u64,
    /// Timestamp of most recent access
    pub last_access: Instant,
    /// Memory size in bytes
    pub size: usize,
    /// Whether value has been modified (page cache only)
    pub dirty: bool,
    /// Number of pins preventing eviction
    pub pin_count: AtomicUsize,
}

impl<V> CacheEntry<V> {
    /// Create a new cache entry
    pub fn new(value: V, size: usize) -> Self {
        Self {
            value,
            access_count: 1,
            last_access: Instant::now(),
            size,
            dirty: false,
            pin_count: AtomicUsize::new(0),
        }
    }

    /// Increment the pin count to prevent eviction
    pub fn pin(&self) -> usize {
        self.pin_count.fetch_add(1, Ordering::AcqRel)
    }

    /// Decrement the pin count to allow eviction
    pub fn unpin(&self) -> usize {
        self.pin_count.fetch_sub(1, Ordering::AcqRel).saturating_sub(1)
    }

    /// Get current pin count
    pub fn get_pin_count(&self) -> usize {
        self.pin_count.load(Ordering::Acquire)
    }

    /// Check if entry is pinned (cannot be evicted)
    pub fn is_pinned(&self) -> bool {
        self.get_pin_count() > 0
    }

    /// Mark entry as dirty
    pub fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    /// Mark entry as clean
    pub fn mark_clean(&mut self) {
        self.dirty = false;
    }

    /// Record an access (increment count, update timestamp)
    pub fn record_access(&mut self) {
        self.access_count += 1;
        self.last_access = Instant::now();
    }
}

/// Performance metrics for cache monitoring
#[derive(Debug, Default)]
pub struct CacheStats {
    /// Number of cache hits
    pub hits: AtomicU64,
    /// Number of cache misses
    pub misses: AtomicU64,
    /// Number of entries evicted
    pub evictions: AtomicU64,
    /// Number of entries inserted
    pub insertions: AtomicU64,
    /// Number of dirty entries evicted
    pub dirty_evictions: AtomicU64,
    /// Current memory usage in bytes
    pub current_size: AtomicUsize,
    /// Current number of entries
    pub current_entries: AtomicUsize,
    /// Number of currently pinned entries
    pub pin_count: AtomicUsize,
}

impl CacheStats {
    /// Create new cache stats
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a cache hit
    pub fn record_hit(&self) {
        self.hits.fetch_add(1, Ordering::Relaxed);
    }

    /// Record a cache miss
    pub fn record_miss(&self) {
        self.misses.fetch_add(1, Ordering::Relaxed);
    }

    /// Record an eviction
    pub fn record_eviction(&self) {
        self.evictions.fetch_add(1, Ordering::Relaxed);
    }

    /// Record a dirty eviction
    pub fn record_dirty_eviction(&self) {
        self.dirty_evictions.fetch_add(1, Ordering::Relaxed);
    }

    /// Record an insertion
    pub fn record_insertion(&self) {
        self.insertions.fetch_add(1, Ordering::Relaxed);
    }

    /// Get hit rate (0.0 to 1.0)
    pub fn hit_rate(&self) -> f64 {
        let hits = self.hits.load(Ordering::Relaxed);
        let misses = self.misses.load(Ordering::Relaxed);
        let total = hits + misses;
        if total == 0 {
            0.0
        } else {
            hits as f64 / total as f64
        }
    }

    /// Get current size
    pub fn size(&self) -> usize {
        self.current_size.load(Ordering::Relaxed)
    }

    /// Get current entry count
    pub fn entry_count(&self) -> usize {
        self.current_entries.load(Ordering::Relaxed)
    }

    /// Get pinned entry count
    pub fn pinned_count(&self) -> usize {
        self.pin_count.load(Ordering::Relaxed)
    }
}

/// Configuration parameters for cache behavior
#[derive(Debug, Clone)]
pub struct CacheConfig {
    /// Maximum memory usage in bytes
    pub max_size: usize,
    /// Maximum number of entries
    pub max_entries: usize,
    /// Eviction policy
    pub policy: CachePolicy,
    /// Number of cache shards for lock scalability
    pub shard_count: usize,
    /// Whether to collect detailed statistics
    pub enable_stats: bool,
    /// Whether to enable prefetch hints
    pub enable_prefetch: bool,
    /// Time-to-live for entries (None = no expiration)
    pub ttl: Option<std::time::Duration>,
    /// Lazy write-back for dirty entries
    pub write_back: bool,
    /// Background write-back interval
    pub write_back_interval: std::time::Duration,
}

impl Default for CacheConfig {
    fn default() -> Self {
        Self {
            max_size: 256 * 1024 * 1024, // 256MB
            max_entries: 100_000,
            policy: CachePolicy::default(),
            shard_count: num_cpus::get(),
            enable_stats: true,
            enable_prefetch: true,
            ttl: None,
            write_back: true,
            write_back_interval: std::time::Duration::from_secs(1),
        }
    }
}

impl CacheConfig {
    /// Validate configuration
    pub fn validate(&self) -> CacheResult<()> {
        if self.max_size < 1024 * 1024 {
            return Err(crate::cache::error::CacheError::InvalidConfig(
                "max_size must be >= 1MB".to_string(),
            ));
        }
        if self.max_entries < 1000 {
            return Err(crate::cache::error::CacheError::InvalidConfig(
                "max_entries must be >= 1000".to_string(),
            ));
        }
        if !self.shard_count.is_power_of_two() {
            return Err(crate::cache::error::CacheError::InvalidConfig(
                "shard_count must be a power of 2".to_string(),
            ));
        }
        if let Some(ttl) = self.ttl {
            if ttl < std::time::Duration::from_millis(1) {
                return Err(crate::cache::error::CacheError::InvalidConfig(
                    "ttl must be >= 1 millisecond".to_string(),
                ));
            }
        }
        Ok(())
    }
}

/// RAII guard that auto-unpins entry on drop
pub struct PinGuard<'cache, K, V>
where
    K: Clone + Eq + std::hash::Hash,
{
    cache: &'cache crate::cache::shard::CacheShard<K, V>,
    key: K,
    value: *const V,
}

unsafe impl<'cache, K, V> Send for PinGuard<'cache, K, V>
where
    K: Clone + Eq + std::hash::Hash + Send,
    V: Send,
{
}

unsafe impl<'cache, K, V> Sync for PinGuard<'cache, K, V>
where
    K: Clone + Eq + std::hash::Hash + Sync,
    V: Sync,
{
}

impl<'cache, K, V> PinGuard<'cache, K, V>
where
    K: Clone + Eq + std::hash::Hash,
{
    /// Create a new pin guard
    pub(crate) fn new(
        cache: &'cache crate::cache::shard::CacheShard<K, V>,
        key: K,
        value: *const V,
    ) -> Self {
        Self { cache, key, value }
    }

    /// Get reference to pinned value
    pub fn get(&self) -> &V {
        // SAFETY: The value pointer is valid for the lifetime of the guard
        unsafe { &*self.value }
    }

    /// Get reference to pinned value (dereference)
    pub fn as_ref(&self) -> &V {
        self.get()
    }
}

impl<'cache, K, V> Drop for PinGuard<'cache, K, V>
where
    K: Clone + Eq + std::hash::Hash,
{
    fn drop(&mut self) {
        // Decrement pin count when guard is dropped
        if let Some(entry) = self.cache.get_entry_unchecked(&self.key) {
            entry.unpin();
        }
    }
}

impl<'cache, K, V> std::ops::Deref for PinGuard<'cache, K, V>
where
    K: Clone + Eq + std::hash::Hash,
{
    type Target = V;

    fn deref(&self) -> &Self::Target {
        self.get()
    }
}

/// Statistics snapshot at a point in time
#[derive(Debug, Clone)]
pub struct CacheSnapshot {
    pub hits: u64,
    pub misses: u64,
    pub evictions: u64,
    pub hit_rate: f64,
    pub current_size: usize,
    pub current_entries: usize,
    pub dirty_pages: usize,
    pub pinned_entries: usize,
}

/// Result from cache clear operation
#[derive(Debug, Clone, Default)]
pub struct ClearResult {
    pub entries_cleared: usize,
    pub dirty_pages_written: usize,
    pub memory_freed: usize,
}

/// LFU heap entry for access count tracking
#[derive(Debug, Clone)]
pub struct AccessCountEntry<K> {
    pub key: K,
    pub access_count: u64,
}

impl<K> PartialEq for AccessCountEntry<K> {
    fn eq(&self, other: &Self) -> bool {
        self.access_count == other.access_count
    }
}

impl<K> Eq for AccessCountEntry<K> {}

impl<K> PartialOrd for AccessCountEntry<K> {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl<K> Ord for AccessCountEntry<K> {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // Reverse order for min-heap behavior
        other.access_count.cmp(&self.access_count)
    }
}

/// ARC adaptive state for balancing recency and frequency
#[derive(Debug)]
pub struct ArcState<K>
where
    K: Clone + Eq + std::hash::Hash,
{
    /// Size of T1 (recently used)
    pub p: usize,
    /// Size of B2 (frequently used)
    pub q: usize,
    /// Ghost list for recently evicted entries
    pub t1: HashMap<K, ()>,
    /// Ghost list for frequently evicted entries
    pub t2: HashMap<K, ()>,
    /// Adaptive increment for T1
    pub delta_t1: usize,
    /// Adaptive increment for T2
    pub delta_t2: usize,
}

impl<K> Default for ArcState<K>
where
    K: Clone + Eq + std::hash::Hash,
{
    fn default() -> Self {
        Self {
            p: 0,
            q: 0,
            t1: HashMap::new(),
            t2: HashMap::new(),
            delta_t1: 0,
            delta_t2: 0,
        }
    }
}

impl<K> ArcState<K>
where
    K: Clone + Eq + std::hash::Hash,
{
    /// Create new ARC state
    pub fn new() -> Self {
        Self::default()
    }

    /// Check if key is in T1 ghost list
    pub fn in_t1(&self, key: &K) -> bool {
        self.t1.contains_key(key)
    }

    /// Check if key is in T2 ghost list
    pub fn in_t2(&self, key: &K) -> bool {
        self.t2.contains_key(key)
    }

    /// Add key to T1 ghost list
    pub fn add_t1(&mut self, key: K) {
        self.t1.insert(key, ());
    }

    /// Add key to T2 ghost list
    pub fn add_t2(&mut self, key: K) {
        self.t2.insert(key, ());
    }

    /// Remove key from ghost lists
    pub fn remove(&mut self, key: &K) {
        self.t1.remove(key);
        self.t2.remove(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cache_entry_pin_unpin() {
        let entry = CacheEntry::new(42, 8);
        assert_eq!(entry.get_pin_count(), 0);
        assert!(!entry.is_pinned());

        let count = entry.pin();
        assert_eq!(count, 0); // Returns the OLD value
        assert!(entry.is_pinned());
        assert_eq!(entry.get_pin_count(), 1);

        let count = entry.unpin();
        assert_eq!(count, 0); // Returns 0 after decrementing 1->0
        assert!(!entry.is_pinned());
    }

    #[test]
    fn test_cache_stats_hit_rate() {
        let stats = CacheStats::new();
        assert_eq!(stats.hit_rate(), 0.0);

        stats.record_hit();
        stats.record_hit();
        stats.record_miss();
        assert!((stats.hit_rate() - 0.666).abs() < 0.01);
    }

    #[test]
    fn test_cache_config_validation() {
        let mut config = CacheConfig::default();
        assert!(config.validate().is_ok());

        config.max_size = 512 * 1024; // Less than 1MB
        assert!(config.validate().is_err());

        config.max_size = 256 * 1024 * 1024;
        config.shard_count = 7; // Not a power of 2
        assert!(config.validate().is_err());
    }
}
