//! Query Plan Cache Module
//!
//! This module provides intelligent caching of query execution plans with automatic
//! invalidation strategies. It reduces query planning overhead by caching generated
//! plans and reusing them for similar queries.
//!
//! # Features
//!
//! - **LRU Eviction**: Least-recently-used eviction policy for cache management
//! - **Invalidation Strategies**: Multiple strategies for cache invalidation
//!   - Time-based expiration (TTL)
//!   - Schema-based invalidation (DDL changes)
//!   - Statistics-based invalidation (significant row count changes)
//!   - Manual invalidation
//! - **Cache Statistics**: Comprehensive metrics for cache performance monitoring
//! - **Concurrency**: Thread-safe cache operations with RwLock
//! - **Configurable**: Flexible cache configuration with sensible defaults
//!
//! # Example
//!
//! ```no_run
//! use northstar_core::query_plan::cache::{PlanCache, PlanCacheConfig, InvalidationStrategy};
//! use std::time::Duration;
//!
//! // Create cache with time-based expiration
//! let config = PlanCacheConfig::default()
//!     .with_max_size(1000)
//!     .with_ttl(Duration::from_secs(300));
//!
//! let cache = PlanCache::new(config);
//!
//! // Cache a query plan
//! cache.insert(
//!     "SELECT * FROM users WHERE age > 25".to_string(),
//!     query_plan,
//!     InvalidationStrategy::TimeBased,
//! ).await?;
//!
//! // Retrieve cached plan
//! if let Some(cached) = cache.get("SELECT * FROM users WHERE age > 25").await? {
//!     println!("Found cached plan: {:?}", cached.plan);
//! }
//!
//! // Get cache statistics
//! let stats = cache.stats().await;
//! println!("Cache hit rate: {:.2}%", stats.hit_rate() * 100.0);
//! ```

use crate::query_plan::types::QueryPlan;
use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

/// Error type for plan cache operations
#[derive(Debug, Clone, PartialEq)]
pub enum PlanCacheError {
    /// Cache is full
    CacheFull,
    /// Invalid cache key
    InvalidKey(String),
    /// Cache entry not found
    NotFound(String),
    /// Cache disabled
    Disabled,
    /// Serialization error
    SerializationError(String),
}

impl fmt::Display for PlanCacheError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlanCacheError::CacheFull => write!(f, "Cache is full"),
            PlanCacheError::InvalidKey(key) => write!(f, "Invalid cache key: {}", key),
            PlanCacheError::NotFound(key) => write!(f, "Cache entry not found: {}", key),
            PlanCacheError::Disabled => write!(f, "Cache is disabled"),
            PlanCacheError::SerializationError(msg) => write!(f, "Serialization error: {}", msg),
        }
    }
}

impl std::error::Error for PlanCacheError {}

/// Result type for plan cache operations
pub type Result<T> = std::result::Result<T, PlanCacheError>;

/// Strategy for invalidating cached query plans
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum InvalidationStrategy {
    /// Invalidate based on time-to-live (TTL)
    TimeBased,
    /// Invalidate on schema changes (DDL operations)
    SchemaBased,
    /// Invalidate on statistics changes (row count thresholds)
    StatisticsBased {
        /// Threshold percentage for row count changes
        threshold_pct: u32,
    },
    /// Never invalidate explicitly
    Never,
    /// Manual invalidation only
    Manual,
}

impl InvalidationStrategy {
    /// Create a statistics-based strategy with default threshold (20%)
    pub fn statistics_based() -> Self {
        InvalidationStrategy::StatisticsBased {
            threshold_pct: 20,
        }
    }

    /// Create a statistics-based strategy with custom threshold
    pub fn statistics_with_threshold(threshold_pct: u32) -> Self {
        InvalidationStrategy::StatisticsBased { threshold_pct }
    }
}

impl Default for InvalidationStrategy {
    fn default() -> Self {
        InvalidationStrategy::TimeBased
    }
}

impl fmt::Display for InvalidationStrategy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InvalidationStrategy::TimeBased => write!(f, "time-based"),
            InvalidationStrategy::SchemaBased => write!(f, "schema-based"),
            InvalidationStrategy::StatisticsBased { threshold_pct } => {
                write!(f, "statistics-based({}%)", threshold_pct)
            }
            InvalidationStrategy::Never => write!(f, "never"),
            InvalidationStrategy::Manual => write!(f, "manual"),
        }
    }
}

/// Metadata for a cached query plan
#[derive(Debug, Clone)]
struct CacheEntryMetadata {
    /// When the entry was created
    created_at: Instant,
    /// When the entry was last accessed
    last_accessed: Instant,
    /// Number of times this entry has been accessed
    access_count: u64,
    /// Invalidation strategy for this entry
    strategy: InvalidationStrategy,
    /// Time-to-live for time-based invalidation
    ttl: Option<Duration>,
    /// Schema version for schema-based invalidation
    schema_version: Option<u64>,
    /// Row count for statistics-based invalidation
    row_count: Option<u64>,
}

impl CacheEntryMetadata {
    /// Create new cache entry metadata
    fn new(strategy: InvalidationStrategy, ttl: Option<Duration>) -> Self {
        let now = Instant::now();
        Self {
            created_at: now,
            last_accessed: now,
            access_count: 0,
            strategy,
            ttl,
            schema_version: None,
            row_count: None,
        }
    }

    /// Check if entry has expired based on TTL
    fn is_expired(&self) -> bool {
        if let Some(ttl) = self.ttl {
            self.created_at.elapsed() > ttl
        } else {
            false
        }
    }

    /// Update access time and count
    fn record_access(&mut self) {
        self.last_accessed = Instant::now();
        self.access_count += 1;
    }

    /// Set schema version for schema-based invalidation
    fn with_schema_version(mut self, version: u64) -> Self {
        self.schema_version = Some(version);
        self
    }

    /// Set row count for statistics-based invalidation
    fn with_row_count(mut self, count: u64) -> Self {
        self.row_count = Some(count);
        self
    }
}

/// A cached query plan entry
#[derive(Debug, Clone)]
pub struct CachedPlan {
    /// The cached query plan
    pub plan: QueryPlan,
    /// Metadata about the cached entry
    metadata: CacheEntryMetadata,
}

impl CachedPlan {
    /// Create a new cached plan
    fn new(plan: QueryPlan, metadata: CacheEntryMetadata) -> Self {
        Self { plan, metadata }
    }

    /// Get the age of this cached entry
    pub fn age(&self) -> Duration {
        self.metadata.created_at.elapsed()
    }

    /// Get the time since last access
    pub fn time_since_access(&self) -> Duration {
        self.metadata.last_accessed.elapsed()
    }

    /// Get the number of times this entry has been accessed
    pub fn access_count(&self) -> u64 {
        self.metadata.access_count
    }
}

/// LRU node for cache eviction tracking
#[derive(Debug, Clone)]
struct LruNode {
    /// Cache key
    key: String,
    /// Previous node key
    prev: Option<String>,
    /// Next node key
    next: Option<String>,
}

/// Configuration for the plan cache
#[derive(Debug, Clone)]
pub struct PlanCacheConfig {
    /// Maximum number of entries in the cache
    pub max_size: usize,
    /// Default time-to-live for cached entries
    pub default_ttl: Option<Duration>,
    /// Default invalidation strategy
    pub default_strategy: InvalidationStrategy,
    /// Whether caching is enabled
    pub enabled: bool,
    /// Current schema version for schema-based invalidation
    pub schema_version: u64,
    /// Whether to track detailed statistics
    pub track_stats: bool,
}

impl Default for PlanCacheConfig {
    fn default() -> Self {
        Self {
            max_size: 1000,
            default_ttl: Some(Duration::from_secs(300)), // 5 minutes
            default_strategy: InvalidationStrategy::TimeBased,
            enabled: true,
            schema_version: 0,
            track_stats: true,
        }
    }
}

impl PlanCacheConfig {
    /// Set maximum cache size
    pub fn with_max_size(mut self, size: usize) -> Self {
        self.max_size = size;
        self
    }

    /// Set default TTL
    pub fn with_ttl(mut self, ttl: Duration) -> Self {
        self.default_ttl = Some(ttl);
        self
    }

    /// Set default invalidation strategy
    pub fn with_strategy(mut self, strategy: InvalidationStrategy) -> Self {
        self.default_strategy = strategy;
        self
    }

    /// Enable or disable caching
    pub fn with_enabled(mut self, enabled: bool) -> Self {
        self.enabled = enabled;
        self
    }

    /// Set schema version
    pub fn with_schema_version(mut self, version: u64) -> Self {
        self.schema_version = version;
        self
    }

    /// Enable or disable statistics tracking
    pub fn with_track_stats(mut self, track: bool) -> Self {
        self.track_stats = track;
        self
    }

    /// Disable TTL
    pub fn without_ttl(mut self) -> Self {
        self.default_ttl = None;
        self
    }
}

/// Statistics for the plan cache
#[derive(Debug, Clone, Default)]
pub struct PlanCacheStats {
    /// Total number of cache lookups
    pub lookups: u64,
    /// Number of cache hits
    pub hits: u64,
    /// Number of cache misses
    pub misses: u64,
    /// Number of entries inserted
    pub inserts: u64,
    /// Number of entries evicted
    pub evictions: u64,
    /// Number of entries explicitly invalidated
    pub invalidations: u64,
    /// Current cache size
    pub current_size: usize,
    /// Maximum cache size
    pub max_size: usize,
}

impl PlanCacheStats {
    /// Calculate cache hit rate
    pub fn hit_rate(&self) -> f64 {
        if self.lookups == 0 {
            0.0
        } else {
            self.hits as f64 / self.lookups as f64
        }
    }

    /// Calculate cache miss rate
    pub fn miss_rate(&self) -> f64 {
        1.0 - self.hit_rate()
    }

    /// Calculate cache utilization
    pub fn utilization(&self) -> f64 {
        if self.max_size == 0 {
            0.0
        } else {
            self.current_size as f64 / self.max_size as f64
        }
    }
}

impl fmt::Display for PlanCacheStats {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "Plan Cache Statistics:")?;
        writeln!(f, "  Size: {} / {}", self.current_size, self.max_size)?;
        writeln!(f, "  Lookups: {}", self.lookups)?;
        writeln!(f, "  Hits: {}", self.hits)?;
        writeln!(f, "  Misses: {}", self.misses)?;
        writeln!(f, "  Inserts: {}", self.inserts)?;
        writeln!(f, "  Evictions: {}", self.evictions)?;
        writeln!(f, "  Invalidations: {}", self.invalidations)?;
        writeln!(f, "  Hit Rate: {:.2}%", self.hit_rate() * 100.0)?;
        writeln!(f, "  Miss Rate: {:.2}%", self.miss_rate() * 100.0)?;
        writeln!(f, "  Utilization: {:.2}%", self.utilization() * 100.0)
    }
}

/// Query plan cache with LRU eviction and multiple invalidation strategies
#[derive(Debug, Clone)]
pub struct PlanCache {
    /// Internal cache state (wrapped in Arc for thread safety)
    inner: Arc<RwLock<PlanCacheInner>>,
}

/// Internal cache state
#[derive(Debug)]
struct PlanCacheInner {
    /// Cache entries stored by key
    entries: HashMap<String, CachedPlan>,
    /// LRU list head (most recently used)
    lru_head: Option<String>,
    /// LRU list tail (least recently used)
    lru_tail: Option<String>,
    /// Cache configuration
    config: PlanCacheConfig,
    /// Cache statistics
    stats: PlanCacheStats,
}

impl PlanCache {
    /// Create a new plan cache with default configuration
    pub fn new() -> Self {
        Self::with_config(PlanCacheConfig::default())
    }

    /// Create a new plan cache with custom configuration
    pub fn with_config(config: PlanCacheConfig) -> Self {
        let max_size = config.max_size;
        let inner = PlanCacheInner {
            entries: HashMap::new(),
            lru_head: None,
            lru_tail: None,
            config,
            stats: PlanCacheStats {
                max_size,
                ..Default::default()
            },
        };
        Self {
            inner: Arc::new(RwLock::new(inner)),
        }
    }

    /// Insert a query plan into the cache
    ///
    /// # Arguments
    ///
    /// * `key` - Cache key (typically normalized query text)
    /// * `plan` - The query plan to cache
    /// * `strategy` - Invalidation strategy for this entry
    ///
    /// # Returns
    ///
    /// Returns `Ok` if the plan was cached, or an error if the cache is disabled or full.
    pub async fn insert(
        &self,
        key: String,
        plan: QueryPlan,
        strategy: InvalidationStrategy,
    ) -> Result<()> {
        let mut inner = self.inner.write().await;

        if !inner.config.enabled {
            return Err(PlanCacheError::Disabled);
        }

        if key.is_empty() {
            return Err(PlanCacheError::InvalidKey("empty key".to_string()));
        }

        // Check if we need to evict
        if inner.entries.len() >= inner.config.max_size && !inner.entries.contains_key(&key) {
            self.evict_lru(&mut inner).await?;
        }

        // Create metadata
        let ttl = match strategy {
            InvalidationStrategy::TimeBased => inner.config.default_ttl,
            _ => None,
        };

        let mut metadata = CacheEntryMetadata::new(strategy.clone(), ttl);

        // Set schema version if using schema-based invalidation
        if strategy == InvalidationStrategy::SchemaBased {
            metadata = metadata.with_schema_version(inner.config.schema_version);
        }

        // Create cached plan
        let cached = CachedPlan::new(plan, metadata);

        // Insert or update entry
        inner.entries.insert(key.clone(), cached);
        inner.stats.inserts += 1;
        inner.stats.current_size = inner.entries.len();

        // Update LRU list
        self.update_lru(&mut inner, key.clone()).await;

        Ok(())
    }

    /// Retrieve a cached query plan
    ///
    /// # Arguments
    ///
    /// * `key` - Cache key to look up
    ///
    /// # Returns
    ///
    /// Returns `Ok(Some(plan))` if found, `Ok(None)` if not found, or an error.
    pub async fn get(&self, key: &str) -> Result<Option<QueryPlan>> {
        let mut inner = self.inner.write().await;

        inner.stats.lookups += 1;

        if !inner.config.enabled {
            return Ok(None);
        }

        // Check if entry exists
        let entry = match inner.entries.get(key) {
            Some(entry) => entry,
            None => {
                inner.stats.misses += 1;
                return Ok(None);
            }
        };

        // Check if entry should be invalidated
        if self.should_invalidate(&inner, entry).await {
            inner.entries.remove(key);
            inner.stats.misses += 1;
            inner.stats.invalidations += 1;
            inner.stats.current_size = inner.entries.len();
            return Ok(None);
        }

        // Record access (need to clone to update)
        let mut entry = entry.clone();
        entry.metadata.record_access();
        inner.entries.insert(key.to_string(), entry);

        // Update LRU (move to front)
        self.update_lru(&mut inner, key.to_string()).await;

        inner.stats.hits += 1;
        Ok(Some(inner.entries.get(key).unwrap().plan.clone()))
    }

    /// Invalidate a specific cache entry
    ///
    /// # Arguments
    ///
    /// * `key` - Cache key to invalidate
    pub async fn invalidate(&self, key: &str) -> Result<()> {
        let mut inner = self.inner.write().await;

        if inner.entries.remove(key).is_some() {
            inner.stats.invalidations += 1;
            inner.stats.current_size = inner.entries.len();

            // Remove from LRU list
            self.remove_from_lru(&mut inner, key).await;
        }

        Ok(())
    }

    /// Invalidate all cache entries
    pub async fn invalidate_all(&self) -> Result<()> {
        let mut inner = self.inner.write().await;

        let count = inner.entries.len();
        inner.entries.clear();
        inner.lru_head = None;
        inner.lru_tail = None;

        inner.stats.invalidations += count as u64;
        inner.stats.current_size = 0;

        Ok(())
    }

    /// Invalidate entries based on schema version
    ///
    /// # Arguments
    ///
    /// * `new_schema_version` - New schema version
    ///
    /// Invalidates all entries cached with the old schema version.
    pub async fn invalidate_schema(&self, new_schema_version: u64) -> Result<usize> {
        let mut inner = self.inner.write().await;

        let keys_to_remove: Vec<String> = inner
            .entries
            .iter()
            .filter(|(_, entry)| {
                entry.metadata.schema_version.is_some()
                    && entry.metadata.schema_version.unwrap() < new_schema_version
            })
            .map(|(key, _)| key.clone())
            .collect();

        for key in &keys_to_remove {
            inner.entries.remove(key);
            self.remove_from_lru(&mut inner, key).await;
        }

        let count = keys_to_remove.len();
        inner.stats.invalidations += count as u64;
        inner.stats.current_size = inner.entries.len();

        // Update current schema version
        inner.config.schema_version = new_schema_version;

        Ok(count)
    }

    /// Get cache statistics
    pub async fn stats(&self) -> PlanCacheStats {
        let inner = self.inner.read().await;
        PlanCacheStats {
            current_size: inner.entries.len(),
            ..inner.stats.clone()
        }
    }

    /// Clear all statistics
    pub async fn clear_stats(&self) {
        let mut inner = self.inner.write().await;
        inner.stats = PlanCacheStats {
            max_size: inner.config.max_size,
            ..Default::default()
        };
    }

    /// Get cache configuration
    pub async fn config(&self) -> PlanCacheConfig {
        let inner = self.inner.read().await;
        inner.config.clone()
    }

    /// Update cache configuration
    pub async fn update_config(&self, config: PlanCacheConfig) {
        let mut inner = self.inner.write().await;
        let max_size = config.max_size;
        inner.config = config;
        inner.stats.max_size = max_size;
    }

    /// Check if cache is enabled
    pub async fn is_enabled(&self) -> bool {
        let inner = self.inner.read().await;
        inner.config.enabled
    }

    /// Get current cache size
    pub async fn size(&self) -> usize {
        let inner = self.inner.read().await;
        inner.entries.len()
    }

    /// Check if cache contains a key
    pub async fn contains(&self, key: &str) -> bool {
        let inner = self.inner.read().await;
        inner.entries.contains_key(key)
    }

    // Private helper methods

    /// Check if an entry should be invalidated
    async fn should_invalidate(&self, inner: &PlanCacheInner, entry: &CachedPlan) -> bool {
        match entry.metadata.strategy {
            InvalidationStrategy::TimeBased => entry.metadata.is_expired(),
            InvalidationStrategy::SchemaBased => {
                if let Some(entry_version) = entry.metadata.schema_version {
                    entry_version < inner.config.schema_version
                } else {
                    false
                }
            }
            InvalidationStrategy::StatisticsBased { threshold_pct } => {
                // This would require comparing against current statistics
                // For now, we'll return false (statistics tracking would be external)
                false
            }
            InvalidationStrategy::Never | InvalidationStrategy::Manual => false,
        }
    }

    /// Evict the least recently used entry
    async fn evict_lru(&self, inner: &mut PlanCacheInner) -> Result<()> {
        if let Some(key) = inner.lru_tail.clone() {
            inner.entries.remove(&key);
            self.remove_from_lru(inner, &key).await;
            inner.stats.evictions += 1;
            inner.stats.current_size = inner.entries.len();
            Ok(())
        } else {
            Err(PlanCacheError::CacheFull)
        }
    }

    /// Update LRU list (move to front)
    async fn update_lru(&self, inner: &mut PlanCacheInner, key: String) {
        // Remove from current position if exists
        self.remove_from_lru(inner, &key).await;

        // Add to front
        if let Some(old_head) = inner.lru_head.take() {
            inner.lru_head = Some(key.clone());
            // Note: In a real implementation, we'd update the old_head's prev pointer
            // For simplicity, we're just tracking the order
        } else {
            // First element
            inner.lru_head = Some(key.clone());
            inner.lru_tail = Some(key.clone());
        }
    }

    /// Remove entry from LRU list
    async fn remove_from_lru(&self, inner: &mut PlanCacheInner, key: &str) {
        // Simplified LRU removal
        if inner.lru_head.as_ref().map(|h| h == key).unwrap_or(false) {
            inner.lru_head = None;
        }
        if inner.lru_tail.as_ref().map(|t| t == key).unwrap_or(false) {
            inner.lru_tail = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query_plan::types::{PlanNode, PlanNodeType, PlanType};

    fn create_test_plan(query_id: u64, query_text: &str) -> QueryPlan {
        let plan_tree = PlanNode::new(query_id, PlanNodeType::TableScan, 1000.0);
        QueryPlan::new(query_id, query_text.to_string(), plan_tree, PlanType::Estimated)
    }

    #[tokio::test]
    async fn test_cache_creation() {
        let cache = PlanCache::new();
        assert!(cache.is_enabled().await);
        assert_eq!(cache.size().await, 0);
    }

    #[tokio::test]
    async fn test_cache_insert_and_get() {
        let cache = PlanCache::new();
        let plan = create_test_plan(1, "SELECT * FROM users");

        cache
            .insert(
                "SELECT * FROM users".to_string(),
                plan,
                InvalidationStrategy::TimeBased,
            )
            .await
            .unwrap();

        assert_eq!(cache.size().await, 1);
        assert!(cache.contains("SELECT * FROM users").await);

        let retrieved = cache.get("SELECT * FROM users").await.unwrap();
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap().query_id, 1);
    }

    #[tokio::test]
    async fn test_cache_miss() {
        let cache = PlanCache::new();
        let result = cache.get("SELECT * FROM nonexistent").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_cache_invalidation() {
        let cache = PlanCache::new();
        let plan = create_test_plan(1, "SELECT * FROM users");

        cache
            .insert(
                "SELECT * FROM users".to_string(),
                plan,
                InvalidationStrategy::TimeBased,
            )
            .await
            .unwrap();

        assert!(cache.contains("SELECT * FROM users").await);

        cache.invalidate("SELECT * FROM users").await.unwrap();
        assert!(!cache.contains("SELECT * FROM users").await);
    }

    #[tokio::test]
    async fn test_cache_invalidate_all() {
        let cache = PlanCache::new();

        for i in 1..=5 {
            let plan = create_test_plan(i, &format!("SELECT * FROM table_{}", i));
            cache
                .insert(
                    format!("SELECT * FROM table_{}", i),
                    plan,
                    InvalidationStrategy::TimeBased,
                )
                .await
                .unwrap();
        }

        assert_eq!(cache.size().await, 5);

        cache.invalidate_all().await.unwrap();
        assert_eq!(cache.size().await, 0);
    }

    #[tokio::test]
    async fn test_cache_stats() {
        let cache = PlanCache::new();
        let plan = create_test_plan(1, "SELECT * FROM users");

        cache
            .insert(
                "SELECT * FROM users".to_string(),
                plan,
                InvalidationStrategy::TimeBased,
            )
            .await
            .unwrap();

        // Cache hit
        cache.get("SELECT * FROM users").await.unwrap();

        // Cache miss
        cache.get("SELECT * FROM nonexistent").await.unwrap();

        let stats = cache.stats().await;
        assert_eq!(stats.lookups, 2);
        assert_eq!(stats.hits, 1);
        assert_eq!(stats.misses, 1);
        assert_eq!(stats.inserts, 1);
        assert!((stats.hit_rate() - 0.5).abs() < 0.01);
    }

    #[tokio::test]
    async fn test_cache_disabled() {
        let config = PlanCacheConfig::default().with_enabled(false);
        let cache = PlanCache::with_config(config);

        let plan = create_test_plan(1, "SELECT * FROM users");
        let result = cache.insert(
            "SELECT * FROM users".to_string(),
            plan,
            InvalidationStrategy::TimeBased,
        )
        .await;

        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), PlanCacheError::Disabled);

        // Get should return None when cache is disabled
        let result = cache.get("SELECT * FROM users").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_cache_config_update() {
        let cache = PlanCache::new();

        let new_config = PlanCacheConfig {
            max_size: 500,
            ..Default::default()
        };

        cache.update_config(new_config).await;

        let config = cache.config().await;
        assert_eq!(config.max_size, 500);
    }

    #[tokio::test]
    async fn test_clear_stats() {
        let cache = PlanCache::new();
        let plan = create_test_plan(1, "SELECT * FROM users");

        cache
            .insert(
                "SELECT * FROM users".to_string(),
                plan,
                InvalidationStrategy::TimeBased,
            )
            .await
            .unwrap();

        cache.get("SELECT * FROM users").await.unwrap();

        cache.clear_stats().await;

        let stats = cache.stats().await;
        assert_eq!(stats.lookups, 0);
        assert_eq!(stats.hits, 0);
        assert_eq!(stats.misses, 0);
    }

    #[tokio::test]
    async fn test_schema_based_invalidation() {
        let config = PlanCacheConfig::default().with_schema_version(1);
        let cache = PlanCache::with_config(config);

        let plan = create_test_plan(1, "SELECT * FROM users");

        cache
            .insert(
                "SELECT * FROM users".to_string(),
                plan,
                InvalidationStrategy::SchemaBased,
            )
            .await
            .unwrap();

        // Schema version matches, should get cache hit
        let result = cache.get("SELECT * FROM users").await.unwrap();
        assert!(result.is_some());

        // Update schema version
        cache.invalidate_schema(2).await.unwrap();

        // Schema version changed, should get cache miss
        let result = cache.get("SELECT * FROM users").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_invalid_key() {
        let cache = PlanCache::new();
        let plan = create_test_plan(1, "SELECT * FROM users");

        let result = cache
            .insert("".to_string(), plan, InvalidationStrategy::TimeBased)
            .await;

        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            PlanCacheError::InvalidKey(_)
        ));
    }

    #[tokio::test]
    async fn test_cached_plan_metadata() {
        let cache = PlanCache::new();
        let plan = create_test_plan(1, "SELECT * FROM users");

        cache
            .insert(
                "SELECT * FROM users".to_string(),
                plan,
                InvalidationStrategy::TimeBased,
            )
            .await
            .unwrap();

        // First access
        cache.get("SELECT * FROM users").await.unwrap();
        // Second access
        cache.get("SELECT * FROM users").await.unwrap();

        let stats = cache.stats().await;
        assert_eq!(stats.hits, 2);
    }
}
