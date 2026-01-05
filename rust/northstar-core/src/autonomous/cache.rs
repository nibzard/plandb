//! Autonomous Cache Optimization.
//!
//! Automatically warms and resizes caches based on usage patterns.

use crate::autonomous::{
    OptimizationType, OptimizationResult,
    AutonomousResult, AutonomousError, OptimizationId,
};
use std::time::{SystemTime, Duration};
use std::collections::HashMap;

/// Cache metadata.
#[derive(Debug, Clone)]
pub struct CacheMetadata {
    /// Cache name
    pub name: String,

    /// Current size in bytes
    pub size_bytes: usize,

    /// Current hit rate (0.0 to 1.0)
    pub hit_rate: f64,

    /// Current memory usage (0.0 to 1.0 of total system memory)
    pub memory_usage: f64,

    /// Last adjusted timestamp
    pub last_adjusted_at: SystemTime,

    /// Number of times adjusted
    pub adjustment_count: u64,
}

/// Cache warming entry.
#[derive(Debug, Clone)]
pub struct CacheWarmEntry {
    /// Key to warm
    pub key: Vec<u8>,

    /// Cache level (1 = L1, 2 = L2)
    pub cache_level: u8,

    /// Priority (0.0 to 1.0)
    pub priority: f64,

    /// Access frequency (accesses per second)
    pub access_frequency: f64,
}

/// Autonomous cache optimizer.
pub struct CacheOptimizer {
    /// Cache configurations
    caches: HashMap<String, CacheMetadata>,

    /// Warm queue
    warm_queue: Vec<CacheWarmEntry>,

    /// Maximum warm queue size
    max_warm_queue: usize,
}

impl CacheOptimizer {
    /// Create new cache optimizer.
    pub fn new(max_warm_queue: usize) -> Self {
        Self {
            caches: HashMap::new(),
            warm_queue: Vec::new(),
            max_warm_queue,
        }
    }

    /// Register cache for optimization.
    pub fn register_cache(
        &mut self,
        name: String,
        size_bytes: usize,
        hit_rate: f64,
        memory_usage: f64,
    ) {
        let metadata = CacheMetadata {
            name,
            size_bytes,
            hit_rate,
            memory_usage,
            last_adjusted_at: SystemTime::now(),
            adjustment_count: 0,
        };

        self.caches.insert(metadata.name.clone(), metadata);
    }

    /// Get cache metadata.
    pub fn get_cache(&self, name: &str) -> Option<&CacheMetadata> {
        self.caches.get(name)
    }

    /// Calculate optimal cache size based on metrics.
    pub fn calculate_optimal_size(
        &self,
        cache_name: &str,
        target_hit_rate: f64,
        max_memory_usage: f64,
    ) -> AutonomousResult<usize> {
        let cache = self
            .caches
            .get(cache_name)
            .ok_or_else(|| AutonomousError::InvalidCandidate("Cache not found".to_string()))?;

        let current_hit_rate = cache.hit_rate;
        let current_memory = cache.memory_usage;
        let current_size = cache.size_bytes;

        let new_size = if current_hit_rate < target_hit_rate && current_memory < max_memory_usage {
            // Increase cache size to improve hit rate
            // Use logarithmic scaling: 20% increase each time
            let increase = (current_size as f64 * 0.2) as usize;
            current_size + increase
        } else if current_hit_rate > 0.95 && current_memory > max_memory_usage * 0.8 {
            // Decrease cache size (very high hit rate, high memory usage)
            let decrease = (current_size as f64 * 0.1) as usize;
            current_size.saturating_sub(decrease)
        } else {
            // No change needed
            return Err(AutonomousError::InvalidCandidate(
                "Cache size adjustment not needed".to_string(),
            ));
        };

        // Sanity check: don't allow extreme sizes
        let min_size = 1024 * 1024; // 1 MB minimum
        let max_size = 1024 * 1024 * 1024 * 16; // 16 GB maximum

        Ok(new_size.clamp(min_size, max_size))
    }

    /// Queue keys for warming.
    pub fn queue_warming(&mut self, keys: Vec<CacheWarmEntry>) -> AutonomousResult<()> {
        let total_queued = self.warm_queue.len() + keys.len();

        if total_queued > self.max_warm_queue {
            return Err(AutonomousError::ResourceLimitExceeded(
                "Warm queue full".to_string(),
            ));
        }

        // Sort by priority (highest first)
        let mut keys = keys;
        keys.sort_by(|a, b| b.priority.partial_cmp(&a.priority).unwrap());

        self.warm_queue.extend(keys);

        Ok(())
    }

    /// Get next batch of keys to warm.
    pub fn next_warm_batch(&mut self, batch_size: usize) -> Vec<CacheWarmEntry> {
        let batch_size = batch_size.min(self.warm_queue.len());
        self.warm_queue.drain(0..batch_size).collect()
    }

    /// Estimate hit rate improvement from warming.
    pub fn estimate_warming_benefit(&self, access_frequency: f64) -> f64 {
        // Higher access frequency = higher benefit
        // Use logarithmic scale: diminishing returns
        (access_frequency.log10() / 5.0).min(1.0).max(0.0)
    }

    /// Calculate cache hit rate from samples.
    pub fn calculate_hit_rate(hits: u64, misses: u64) -> f64 {
        let total = hits + misses;
        if total == 0 {
            return 0.0;
        }
        hits as f64 / total as f64
    }

    /// Apply cache size adjustment.
    pub fn apply_cache_resize(
        &mut self,
        cache_name: &str,
        new_size_bytes: usize,
    ) -> AutonomousResult<OptimizationResult> {
        let cache = self
            .caches
            .get_mut(cache_name)
            .ok_or_else(|| AutonomousError::InvalidCandidate("Cache not found".to_string()))?;

        let old_size = cache.size_bytes;
        cache.size_bytes = new_size_bytes;
        cache.last_adjusted_at = SystemTime::now();
        cache.adjustment_count += 1;

        Ok(OptimizationResult {
            id: OptimizationId(1),
            optimization_type: OptimizationType::CacheResize {
                cache_name: cache_name.to_string(),
                new_size_bytes,
            },
            started_at: SystemTime::now() - Duration::from_secs(1),
            completed_at: SystemTime::now(),
            success: true,
            actual_impact: None,
            error_message: None,
        })
    }

    /// Get warm queue status.
    pub fn warm_queue_status(&self) -> (usize, usize) {
        (self.warm_queue.len(), self.max_warm_queue)
    }

    /// Clear warm queue.
    pub fn clear_warm_queue(&mut self) {
        self.warm_queue.clear();
    }
}

impl Default for CacheOptimizer {
    fn default() -> Self {
        Self::new(1000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_register_cache() {
        let mut optimizer = CacheOptimizer::new(100);

        optimizer.register_cache(
            "l1_page_cache".to_string(),
            100 * 1024 * 1024, // 100 MB
            0.75,
            0.1,
        );

        let cache = optimizer.get_cache("l1_page_cache").unwrap();
        assert_eq!(cache.size_bytes, 100 * 1024 * 1024);
        assert_eq!(cache.hit_rate, 0.75);
    }

    #[test]
    fn test_calculate_hit_rate() {
        let hit_rate = CacheOptimizer::calculate_hit_rate(75, 25);
        assert!((hit_rate - 0.75).abs() < 0.001);

        let hit_rate = CacheOptimizer::calculate_hit_rate(0, 0);
        assert_eq!(hit_rate, 0.0);
    }

    #[test]
    fn test_queue_warming() {
        let mut optimizer = CacheOptimizer::new(10);

        let keys = vec![
            CacheWarmEntry {
                key: b"key1".to_vec(),
                cache_level: 1,
                priority: 0.9,
                access_frequency: 1000.0,
            },
            CacheWarmEntry {
                key: b"key2".to_vec(),
                cache_level: 1,
                priority: 0.5,
                access_frequency: 100.0,
            },
        ];

        assert!(optimizer.queue_warming(keys).is_ok());
        assert_eq!(optimizer.warm_queue_status().0, 2);

        // Test overflow
        let keys: Vec<_> = (0..20)
            .map(|_| CacheWarmEntry {
                key: vec![0],
                cache_level: 1,
                priority: 0.5,
                access_frequency: 100.0,
            })
            .collect();

        assert!(optimizer.queue_warming(keys).is_err());
    }

    #[test]
    fn test_calculate_optimal_size_increase() {
        let mut optimizer = CacheOptimizer::new(100);

        optimizer.register_cache("test".to_string(), 100_000_000, 0.6, 0.3);

        let new_size = optimizer.calculate_optimal_size("test", 0.85, 0.9).unwrap();
        assert!(new_size > 100_000_000); // Should increase
        assert!(new_size < 100_000_000 * 2); // But not double
    }

    #[test]
    fn test_calculate_optimal_size_decrease() {
        let mut optimizer = CacheOptimizer::new(100);

        optimizer.register_cache("test".to_string(), 1_000_000_000, 0.97, 0.85);

        let new_size = optimizer.calculate_optimal_size("test", 0.85, 0.9).unwrap();
        assert!(new_size < 1_000_000_000); // Should decrease
        assert!(new_size > 1_000_000_000 / 2); // But not halved
    }

    #[test]
    fn test_estimate_warming_benefit() {
        let optimizer = CacheOptimizer::new(100);

        let benefit = optimizer.estimate_warming_benefit(1000.0);
        assert!(benefit > 0.5);

        let benefit = optimizer.estimate_warming_benefit(10.0);
        assert!(benefit < 0.5);
    }
}
