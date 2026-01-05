//! Optimization Policy Engine.
//!
//! Evaluates optimization candidates using rules-based and ML-based approaches.

use crate::analytics::usage::{
    QueryPattern, HotKeyReport, ColdDataReport, Recommendation,
    QueryType, HotKeyClassification, ColdDataClassification,
    EffortLevel, RecommendationPriority, RecommendationType,
    ImpactEstimate,
};
use crate::autonomous::{
    OptimizationCandidate, OptimizationType,
    AutonomousResult, AutonomousError, OptimizationId,
};
use std::time::Duration;
use std::sync::atomic::{AtomicU64, Ordering};

/// Index creation policy configuration.
#[derive(Debug, Clone)]
pub struct IndexPolicy {
    /// Minimum execution count for index consideration
    pub min_execution_count: u64,

    /// Minimum scan/return ratio for index recommendation
    pub min_scan_return_ratio: f64,

    /// Maximum index size as percentage of table size
    pub max_index_size_ratio: f64,

    /// Write overhead threshold (refuse if > threshold)
    pub max_write_overhead: f64,
}

impl Default for IndexPolicy {
    fn default() -> Self {
        Self {
            min_execution_count: 1000,
            min_scan_return_ratio: 10.0,
            max_index_size_ratio: 0.5,
            max_write_overhead: 0.2,
        }
    }
}

/// Cache warming policy configuration.
#[derive(Debug, Clone)]
pub struct CacheWarmingPolicy {
    /// Minimum hotness score for cache warming
    pub min_hotness_score: f64,

    /// Maximum keys to warm per cycle
    pub max_keys_per_cycle: usize,

    /// Minimum access frequency for warming
    pub min_access_frequency: f64,
}

impl Default for CacheWarmingPolicy {
    fn default() -> Self {
        Self {
            min_hotness_score: 0.7,
            max_keys_per_cycle: 100,
            min_access_frequency: 100.0,
        }
    }
}

/// Cache sizing policy configuration.
#[derive(Debug, Clone)]
pub struct CacheSizingPolicy {
    /// Target cache hit rate
    pub target_hit_rate: f64,

    /// Minimum hit rate to consider shrinking cache
    pub min_hit_rate_for_shrink: f64,

    /// Maximum memory usage percentage
    pub max_memory_usage_percent: f64,

    /// Cache size adjustment increment (percentage)
    pub size_adjustment_increment: f64,
}

impl Default for CacheSizingPolicy {
    fn default() -> Self {
        Self {
            target_hit_rate: 0.85,
            min_hit_rate_for_shrink: 0.95,
            max_memory_usage_percent: 0.90,
            size_adjustment_increment: 0.2,
        }
    }
}

/// Data archival policy configuration.
#[derive(Debug, Clone)]
pub struct ArchivalPolicy {
    /// Minimum days inactive for archival
    pub min_days_inactive: u64,

    /// Minimum size for archival (bytes)
    pub min_size_bytes: u64,

    /// Maximum data to archive per cycle (bytes)
    pub max_archive_bytes_per_cycle: u64,
}

impl Default for ArchivalPolicy {
    fn default() -> Self {
        Self {
            min_days_inactive: 90,
            min_size_bytes: 10 * 1024 * 1024, // 10 MB
            max_archive_bytes_per_cycle: 100 * 1024 * 1024 * 1024, // 100 GB
        }
    }
}

/// Compaction policy configuration.
#[derive(Debug, Clone)]
pub struct CompactionPolicy {
    /// Minimum fragmentation ratio to trigger compaction
    pub min_fragmentation_ratio: f64,

    /// Minimum free pages ratio to trigger compaction
    pub min_free_pages_ratio: f64,

    /// Maximum compaction time
    pub max_compaction_time: Duration,
}

impl Default for CompactionPolicy {
    fn default() -> Self {
        Self {
            min_fragmentation_ratio: 0.3,
            min_free_pages_ratio: 0.2,
            max_compaction_time: Duration::from_secs(3600),
        }
    }
}

/// Optimization policy engine.
pub struct PolicyEngine {
    /// Index creation policy
    index_policy: IndexPolicy,

    /// Cache warming policy
    cache_warming_policy: CacheWarmingPolicy,

    /// Cache sizing policy
    cache_sizing_policy: CacheSizingPolicy,

    /// Data archival policy
    archival_policy: ArchivalPolicy,

    /// Compaction policy
    compaction_policy: CompactionPolicy,

    /// Next optimization ID
    next_id: AtomicU64,
}

impl PolicyEngine {
    /// Create new policy engine.
    pub fn new(
        index_policy: IndexPolicy,
        cache_warming_policy: CacheWarmingPolicy,
        cache_sizing_policy: CacheSizingPolicy,
        archival_policy: ArchivalPolicy,
        compaction_policy: CompactionPolicy,
    ) -> Self {
        Self {
            index_policy,
            cache_warming_policy,
            cache_sizing_policy,
            archival_policy,
            compaction_policy,
            next_id: AtomicU64::new(1),
        }
    }

    /// Create with default policies.
    pub fn default_config() -> Self {
        Self::new(
            IndexPolicy::default(),
            CacheWarmingPolicy::default(),
            CacheSizingPolicy::default(),
            ArchivalPolicy::default(),
            CompactionPolicy::default(),
        )
    }

    /// Generate optimization ID.
    fn next_id(&self) -> OptimizationId {
        OptimizationId(self.next_id.fetch_add(1, Ordering::SeqCst))
    }

    /// Evaluate query pattern for index optimization.
    pub fn evaluate_index_candidate(
        &self,
        pattern: &QueryPattern,
    ) -> AutonomousResult<OptimizationCandidate> {
        // Rule 1: Must have sufficient execution frequency
        if pattern.execution_count < self.index_policy.min_execution_count {
            return Err(AutonomousError::InvalidCandidate(
                "Insufficient execution count".to_string(),
            ));
        }

        // Rule 2: Must be inefficient (high scan/return ratio)
        if pattern.scan_return_ratio < self.index_policy.min_scan_return_ratio {
            return Err(AutonomousError::InvalidCandidate(
                "Scan/return ratio too low".to_string(),
            ));
        }

        // Rule 3: Must be point lookup or range scan
        if !matches!(
            pattern.query_type,
            QueryType::PointLookup | QueryType::RangeScan
        ) {
            return Err(AutonomousError::InvalidCandidate(
                "Not a lookup or scan query".to_string(),
            ));
        }

        // Estimate benefits
        let latency_reduction = if pattern.query_type == QueryType::PointLookup {
            0.95 // 95% reduction for point lookups
        } else {
            0.80 // 80% reduction for range scans
        };

        let estimated_benefit = ImpactEstimate {
            latency_reduction_percent: latency_reduction * 100.0,
            throughput_increase_percent: 50.0,
            cost_reduction_percent: None,
            storage_overhead_bytes: Some(
                (pattern.table_name.len() * 100) as u64
            ), // Rough estimate
        };

        Ok(OptimizationCandidate {
            optimization_type: OptimizationType::CreateIndex {
                table: pattern.table_name.clone(),
                columns: pattern.columns_accessed.clone(),
            },
            estimated_benefit,
            effort_level: EffortLevel::Easy,
            risk_level: 0.2, // Low risk
            confidence: 0.85,
            priority: if pattern.execution_count > 10000 {
                RecommendationPriority::High
            } else {
                RecommendationPriority::Medium
            },
            rationale: format!(
                "Frequent {} queries on {} ({} executions, {}ms avg latency, {} scan/return ratio). \
                 Adding index could reduce latency by {:.0}%.",
                match pattern.query_type {
                    QueryType::PointLookup => "point lookup",
                    QueryType::RangeScan => "range scan",
                    _ => "unknown",
                },
                pattern.table_name,
                pattern.execution_count,
                pattern.avg_latency_ms,
                pattern.scan_return_ratio,
                latency_reduction * 100.0
            ),
            evidence: vec![],
        })
    }

    /// Evaluate hot key for cache warming.
    pub fn evaluate_cache_warming(
        &self,
        hot_key: &HotKeyReport,
    ) -> AutonomousResult<OptimizationCandidate> {
        // Rule 1: Must be sufficiently hot
        if hot_key.hotness_score < self.cache_warming_policy.min_hotness_score {
            return Err(AutonomousError::InvalidCandidate(
                "Hotness score too low".to_string(),
            ));
        }

        // Rule 2: Must be read hot
        if !matches!(
            hot_key.classification,
            HotKeyClassification::ReadHot | HotKeyClassification::HotSpot
        ) {
            return Err(AutonomousError::InvalidCandidate(
                "Not a read hot key".to_string(),
            ));
        }

        let cache_level = match hot_key.classification {
            HotKeyClassification::HotSpot => 1, // L1 cache for hot spots
            _ => 2, // L2 cache for read hot
        };

        let estimated_benefit = ImpactEstimate {
            latency_reduction_percent: 90.0,
            throughput_increase_percent: 20.0,
            cost_reduction_percent: None,
            storage_overhead_bytes: Some(hot_key.key.len() as u64),
        };

        Ok(OptimizationCandidate {
            optimization_type: OptimizationType::CacheWarming {
                keys: vec![hot_key.key.clone()],
                cache_level,
            },
            estimated_benefit,
            effort_level: EffortLevel::Trivial,
            risk_level: 0.05, // Very low risk
            confidence: 0.95,
            priority: if hot_key.hotness_score > 0.9 {
                RecommendationPriority::High
            } else {
                RecommendationPriority::Medium
            },
            rationale: format!(
                "Key {:?} is read hot ({} reads/sec, hotness {:.2}). \
                 Pre-loading into L{} cache could reduce latency by 90%.",
                hot_key.key, hot_key.read_frequency, hot_key.hotness_score, cache_level
            ),
            evidence: vec![],
        })
    }

    /// Evaluate cold data for archival.
    pub fn evaluate_archival(
        &self,
        cold_data: &ColdDataReport,
    ) -> AutonomousResult<OptimizationCandidate> {
        // Rule 1: Must be inactive for long enough
        if cold_data.days_since_last_access < self.archival_policy.min_days_inactive {
            return Err(AutonomousError::InvalidCandidate(
                "Not inactive long enough".to_string(),
            ));
        }

        // Rule 2: Must be large enough
        if cold_data.estimated_size_bytes < self.archival_policy.min_size_bytes {
            return Err(AutonomousError::InvalidCandidate(
                "Data too small".to_string(),
            ));
        }

        let target = match cold_data.classification {
            ColdDataClassification::ArchiveCandidate => "S3 Standard",
            ColdDataClassification::DeleteCandidate => {
                return Err(AutonomousError::InvalidCandidate("Delete not supported".to_string()));
            }
            ColdDataClassification::CompressCandidate => "Compress",
        };

        let estimated_benefit = ImpactEstimate {
            latency_reduction_percent: 0.0,
            throughput_increase_percent: 0.0,
            cost_reduction_percent: Some(80.0), // 80% cost reduction
            storage_overhead_bytes: None, // Frees space
        };

        Ok(OptimizationCandidate {
            optimization_type: OptimizationType::ArchiveData {
                table: cold_data.table_name.clone(),
                target: target.to_string(),
            },
            estimated_benefit,
            effort_level: EffortLevel::Moderate,
            risk_level: 0.3, // Medium risk
            confidence: 0.8,
            priority: RecommendationPriority::Medium,
            rationale: format!(
                "Table {} not accessed in {} days ({} bytes). \
                 Archival to {} could reduce costs by 80%.",
                cold_data.table_name,
                cold_data.days_since_last_access,
                cold_data.estimated_size_bytes,
                target
            ),
            evidence: vec![],
        })
    }

    /// Evaluate cache sizing based on metrics.
    pub fn evaluate_cache_sizing(
        &self,
        cache_name: &str,
        current_size_bytes: usize,
        hit_rate: f64,
        memory_usage_percent: f64,
    ) -> AutonomousResult<OptimizationCandidate> {
        let new_size = if hit_rate < self.cache_sizing_policy.target_hit_rate
            && memory_usage_percent < self.cache_sizing_policy.max_memory_usage_percent
        {
            // Increase cache size
            let increase =
                (current_size_bytes as f64 * self.cache_sizing_policy.size_adjustment_increment)
                    as usize;
            current_size_bytes + increase
        } else if hit_rate > self.cache_sizing_policy.min_hit_rate_for_shrink
            && memory_usage_percent > self.cache_sizing_policy.max_memory_usage_percent
        {
            // Decrease cache size
            let decrease =
                (current_size_bytes as f64 * self.cache_sizing_policy.size_adjustment_increment)
                    as usize;
            current_size_bytes.saturating_sub(decrease)
        } else {
            return Err(AutonomousError::InvalidCandidate(
                "Cache size adjustment not needed".to_string(),
            ));
        };

        let is_increase = new_size > current_size_bytes;

        Ok(OptimizationCandidate {
            optimization_type: OptimizationType::CacheResize {
                cache_name: cache_name.to_string(),
                new_size_bytes: new_size,
            },
            estimated_benefit: ImpactEstimate {
                latency_reduction_percent: if is_increase { 15.0 } else { 0.0 },
                throughput_increase_percent: if is_increase { 10.0 } else { 0.0 },
                cost_reduction_percent: None,
                storage_overhead_bytes: if is_increase {
                    Some((new_size - current_size_bytes) as u64)
                } else {
                    None
                },
            },
            effort_level: EffortLevel::Trivial,
            risk_level: 0.1,
            confidence: 0.8,
            priority: RecommendationPriority::Medium,
            rationale: format!(
                "Cache {} hit rate {:.1}%, memory usage {:.1}%. {} to {} bytes.",
                cache_name,
                hit_rate * 100.0,
                memory_usage_percent * 100.0,
                if is_increase { "Increasing" } else { "Decreasing" },
                new_size
            ),
            evidence: vec![],
        })
    }
}

impl Default for PolicyEngine {
    fn default() -> Self {
        Self::default_config()
    }
}
