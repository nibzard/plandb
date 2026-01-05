//! Usage-Based Optimization Recommendations.
//!
//! This module generates actionable optimization recommendations based on
//! query patterns, hot keys, cold data, and performance anomalies.

use crate::analytics::usage::{
    QueryPattern, HotKeyReport, ColdDataReport, PerformanceAnomaly,
    Recommendation, RecommendationType, RecommendationTarget, RecommendationPriority,
    EffortLevel, ImpactEstimate, HotKeyClassification, Evidence, RecommendationId,
};
use std::collections::HashMap;
use std::time::SystemTime;

/// Recommendation engine configuration.
#[derive(Debug, Clone)]
pub struct RecommendationConfig {
    /// Minimum execution count to generate recommendations
    pub min_execution_count: u64,

    /// Minimum scan/return ratio to trigger index recommendation
    pub min_scan_return_ratio: f64,

    /// Minimum hotness score for cache warming recommendations
    pub min_hotness_score: f64,

    /// Minimum days inactive for cold data recommendations
    pub min_days_inactive: u64,

    /// Maximum recommendations to generate
    pub max_recommendations: usize,
}

impl Default for RecommendationConfig {
    fn default() -> Self {
        Self {
            min_execution_count: 100,
            min_scan_return_ratio: 10.0,
            min_hotness_score: 0.7,
            min_days_inactive: 90,
            max_recommendations: 50,
        }
    }
}

/// Recommendation engine for generating optimization suggestions.
pub struct RecommendationEngine {
    /// Configuration
    config: RecommendationConfig,

    /// Next recommendation ID
    next_id: RecommendationId,
}

impl RecommendationEngine {
    /// Create new recommendation engine.
    pub fn new(config: RecommendationConfig) -> Self {
        Self {
            config,
            next_id: 1,
        }
    }

    /// Create with default configuration.
    pub fn default_config() -> Self {
        Self::new(RecommendationConfig::default())
    }

    /// Generate recommendations from query patterns.
    pub fn generate_from_patterns(&mut self, patterns: &[QueryPattern]) -> Vec<Recommendation> {
        let mut recommendations = Vec::new();

        for pattern in patterns {
            if pattern.execution_count < self.config.min_execution_count {
                continue;
            }

            // Check for index recommendations
            if let Some(rec) = self.recommend_index_for_pattern(pattern) {
                recommendations.push(rec);
            }

            // Check for cache warming recommendations
            if let Some(rec) = self.recommend_cache_for_pattern(pattern) {
                recommendations.push(rec);
            }

            // Check for partitioning recommendations
            if let Some(rec) = self.recommend_partition_for_pattern(pattern) {
                recommendations.push(rec);
            }
        }

        // Limit recommendations
        recommendations.truncate(self.config.max_recommendations);
        recommendations
    }

    /// Generate recommendations from hot keys.
    pub fn generate_from_hot_keys(&mut self, hot_keys: &[HotKeyReport]) -> Vec<Recommendation> {
        let mut recommendations = Vec::new();

        for hot_key in hot_keys {
            if hot_key.hotness_score < self.config.min_hotness_score {
                continue;
            }

            let rec = match hot_key.recommendation {
                crate::analytics::usage::HotKeyRecommendation::CacheInL1 => {
                    Some(self.create_cache_warming_recommendation(
                        &format!("{:?}", hot_key.key),
                        1,
                        hot_key.hotness_score,
                        hot_key.read_frequency,
                    ))
                }
                crate::analytics::usage::HotKeyRecommendation::CacheInL2 => {
                    Some(self.create_cache_warming_recommendation(
                        &format!("{:?}", hot_key.key),
                        2,
                        hot_key.hotness_score,
                        hot_key.read_frequency,
                    ))
                }
                _ => None,
            };

            if let Some(rec) = rec {
                recommendations.push(rec);
            }
        }

        recommendations.truncate(self.config.max_recommendations);
        recommendations
    }

    /// Generate recommendations from cold data.
    pub fn generate_from_cold_data(&mut self, cold_data: &[ColdDataReport]) -> Vec<Recommendation> {
        let mut recommendations = Vec::new();

        for cold in cold_data {
            if cold.days_since_last_access < self.config.min_days_inactive {
                continue;
            }

            let rec = match cold.recommendation {
                crate::analytics::usage::ColdDataRecommendation::ArchiveToS3 => {
                    Some(self.create_archive_recommendation(
                        &cold.table_name,
                        "S3 Glacier",
                        cold.estimated_size_bytes,
                    ))
                }
                crate::analytics::usage::ColdDataRecommendation::Compress => {
                    Some(self.create_compress_recommendation(
                        &cold.table_name,
                        cold.estimated_size_bytes,
                    ))
                }
                _ => None,
            };

            if let Some(rec) = rec {
                recommendations.push(rec);
            }
        }

        recommendations.truncate(self.config.max_recommendations);
        recommendations
    }

    /// Recommend index for pattern.
    fn recommend_index_for_pattern(&mut self, pattern: &QueryPattern) -> Option<Recommendation> {
        // Check if this is a scan pattern with high ratio
        if pattern.scan_return_ratio < self.config.min_scan_return_ratio {
            return None;
        }

        // Calculate potential benefit
        let latency_reduction = ((pattern.scan_return_ratio - 1.0) / pattern.scan_return_ratio) * 100.0;
        let latency_reduction = latency_reduction.min(95.0); // Cap at 95%

        Some(Recommendation {
            recommendation_id: self.next_id(),
            generated_at: SystemTime::now(),
            recommendation_type: RecommendationType::CreateIndex {
                table: pattern.table_name.clone(),
                columns: pattern.columns_accessed.clone(),
            },
            title: format!("Create index on {}", pattern.table_name),
            description: format!(
                "Frequent scans on {} with high scan/return ratio ({:.1}:1). \
                 Creating an index could reduce latency by {:.1}%.",
                pattern.table_name, pattern.scan_return_ratio, latency_reduction
            ),
            rationale: format!(
                "Query executed {} times with avg latency {:.2}ms, \
                 scanning {:.0} rows but returning only {:.0} rows.",
                pattern.execution_count, pattern.avg_latency_ms,
                pattern.avg_rows_scanned, pattern.avg_rows_returned
            ),
            target_type: RecommendationTarget::Table,
            target_name: pattern.table_name.clone(),
            estimated_benefit: ImpactEstimate {
                latency_reduction_percent: latency_reduction,
                throughput_increase_percent: latency_reduction * 0.5,
                cost_reduction_percent: None,
                storage_overhead_bytes: Some(pattern.avg_rows_returned as u64 * 100),
            },
            effort_level: EffortLevel::Easy,
            priority: Self::calculate_priority(pattern.execution_count, latency_reduction),
            confidence: 0.85,
            supporting_evidence: vec![
                Evidence {
                    evidence_type: "query_frequency".to_string(),
                    description: format!("Executed {} times", pattern.execution_count),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("count".to_string(), pattern.execution_count.to_string());
                        map
                    },
                },
                Evidence {
                    evidence_type: "scan_efficiency".to_string(),
                    description: format!("Scan/return ratio: {:.1}:1", pattern.scan_return_ratio),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("ratio".to_string(), pattern.scan_return_ratio.to_string());
                        map
                    },
                },
            ],
        })
    }

    /// Recommend cache warming for pattern.
    fn recommend_cache_for_pattern(&mut self, pattern: &QueryPattern) -> Option<Recommendation> {
        // Only recommend caching for high-frequency point lookups
        if pattern.query_type != crate::analytics::usage::QueryType::PointLookup {
            return None;
        }

        if pattern.execution_count < self.config.min_execution_count * 2 {
            return None;
        }

        Some(Recommendation {
            recommendation_id: self.next_id(),
            generated_at: SystemTime::now(),
            recommendation_type: RecommendationType::CacheWarming { cache_level: 1 },
            title: format!("Pre-warm cache for {}", pattern.table_name),
            description: format!(
                "High-frequency point lookups on {} ({} executions). \
                 Pre-warming L1 cache could reduce latency by 90%.",
                pattern.table_name, pattern.execution_count
            ),
            rationale: format!(
                "Point lookups executed {} times with avg latency {:.2}ms. \
                 Caching could reduce latency to < 1ms.",
                pattern.execution_count, pattern.avg_latency_ms
            ),
            target_type: RecommendationTarget::Table,
            target_name: pattern.table_name.clone(),
            estimated_benefit: ImpactEstimate {
                latency_reduction_percent: 90.0,
                throughput_increase_percent: 100.0,
                cost_reduction_percent: None,
                storage_overhead_bytes: Some(1024),
            },
            effort_level: EffortLevel::Trivial,
            priority: RecommendationPriority::Medium,
            confidence: 0.95,
            supporting_evidence: vec![
                Evidence {
                    evidence_type: "query_frequency".to_string(),
                    description: format!("Executed {} times", pattern.execution_count),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("count".to_string(), pattern.execution_count.to_string());
                        map
                    },
                },
                Evidence {
                    evidence_type: "query_type".to_string(),
                    description: "Point lookup (ideal for caching)".to_string(),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("type".to_string(), "point_lookup".to_string());
                        map
                    },
                },
            ],
        })
    }

    /// Recommend partitioning for pattern.
    fn recommend_partition_for_pattern(&mut self, pattern: &QueryPattern) -> Option<Recommendation> {
        // Recommend partitioning for very high scan volumes
        if pattern.avg_rows_scanned < 1_000_000.0 {
            return None;
        }

        Some(Recommendation {
            recommendation_id: self.next_id(),
            generated_at: SystemTime::now(),
            recommendation_type: RecommendationType::PartitionTable {
                partition_key: pattern.columns_accessed.first().cloned().unwrap_or("id".to_string()),
            },
            title: format!("Partition table {}", pattern.table_name),
            description: format!(
                "Large table {} with {:.0} avg rows scanned. \
                 Partitioning could improve parallel query performance.",
                pattern.table_name, pattern.avg_rows_scanned
            ),
            rationale: format!(
                "Table scans are accessing {:.0} rows on average. \
                 Partitioning would enable parallel processing.",
                pattern.avg_rows_scanned
            ),
            target_type: RecommendationTarget::Table,
            target_name: pattern.table_name.clone(),
            estimated_benefit: ImpactEstimate {
                latency_reduction_percent: 40.0,
                throughput_increase_percent: 150.0,
                cost_reduction_percent: None,
                storage_overhead_bytes: None,
            },
            effort_level: EffortLevel::Complex,
            priority: RecommendationPriority::Low,
            confidence: 0.7,
            supporting_evidence: vec![
                Evidence {
                    evidence_type: "table_size".to_string(),
                    description: format!("Avg rows scanned: {:.0}", pattern.avg_rows_scanned),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("rows".to_string(), pattern.avg_rows_scanned.to_string());
                        map
                    },
                },
            ],
        })
    }

    /// Create cache warming recommendation.
    fn create_cache_warming_recommendation(
        &mut self,
        key: &str,
        cache_level: u8,
        hotness_score: f64,
        frequency: f64,
    ) -> Recommendation {
        let latency_reduction = if cache_level == 1 { 95.0 } else { 80.0 };

        Recommendation {
            recommendation_id: self.next_id(),
            generated_at: SystemTime::now(),
            recommendation_type: RecommendationType::CacheWarming { cache_level },
            title: format!("Pre-warm L{} cache for key {}", cache_level, key),
            description: format!(
                "Hot key {} ({:.0} ops/sec, hotness score {:.2}). \
                 Pre-warming cache could reduce latency by {:.0}%.",
                key, frequency, hotness_score, latency_reduction
            ),
            rationale: format!(
                "Key accessed at {:.0} ops/sec with hotness score {:.2}. \
                 Caching in L{} would provide significant latency reduction.",
                frequency, hotness_score, cache_level
            ),
            target_type: RecommendationTarget::Key,
            target_name: key.to_string(),
            estimated_benefit: ImpactEstimate {
                latency_reduction_percent: latency_reduction,
                throughput_increase_percent: 50.0,
                cost_reduction_percent: None,
                storage_overhead_bytes: Some(key.len() as u64),
            },
            effort_level: EffortLevel::Trivial,
            priority: if hotness_score > 0.9 {
                RecommendationPriority::High
            } else {
                RecommendationPriority::Medium
            },
            confidence: 0.95,
            supporting_evidence: vec![
                Evidence {
                    evidence_type: "hotness_score".to_string(),
                    description: format!("Hotness score: {:.2}", hotness_score),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("score".to_string(), hotness_score.to_string());
                        map
                    },
                },
                Evidence {
                    evidence_type: "access_frequency".to_string(),
                    description: format!("{:.0} ops/sec", frequency),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("frequency".to_string(), frequency.to_string());
                        map
                    },
                },
            ],
        }
    }

    /// Create archive recommendation.
    fn create_archive_recommendation(
        &mut self,
        table: &str,
        target: &str,
        size_bytes: u64,
    ) -> Recommendation {
        let size_mb = size_bytes / (1024 * 1024);
        let cost_reduction = 80.0; // S3 Glacier is ~80% cheaper

        Recommendation {
            recommendation_id: self.next_id(),
            generated_at: SystemTime::now(),
            recommendation_type: RecommendationType::ArchiveData {
                target: target.to_string(),
            },
            title: format!("Archive {} to {}", table, target),
            description: format!(
                "Table {} is {}MB and inactive. Archiving to {} could reduce costs by {:.0}%.",
                table, size_mb, target, cost_reduction
            ),
            rationale: format!(
                "Data hasn't been accessed in > 90 days. Moving to cold storage \
                 would reduce storage costs by {:.0}%.",
                cost_reduction
            ),
            target_type: RecommendationTarget::Table,
            target_name: table.to_string(),
            estimated_benefit: ImpactEstimate {
                latency_reduction_percent: 0.0,
                throughput_increase_percent: 0.0,
                cost_reduction_percent: Some(cost_reduction),
                storage_overhead_bytes: None,
            },
            effort_level: EffortLevel::Moderate,
            priority: RecommendationPriority::Low,
            confidence: 0.85,
            supporting_evidence: vec![
                Evidence {
                    evidence_type: "data_size".to_string(),
                    description: format!("Size: {}MB", size_mb),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("size_mb".to_string(), size_mb.to_string());
                        map
                    },
                },
                Evidence {
                    evidence_type: "inactivity".to_string(),
                    description: "No access in > 90 days".to_string(),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("days_inactive".to_string(), "90".to_string());
                        map
                    },
                },
            ],
        }
    }

    /// Create compression recommendation.
    fn create_compress_recommendation(
        &mut self,
        table: &str,
        size_bytes: u64,
    ) -> Recommendation {
        let size_mb = size_bytes / (1024 * 1024);
        let compression_ratio = 0.6; // Assume 60% size reduction

        Recommendation {
            recommendation_id: self.next_id(),
            generated_at: SystemTime::now(),
            recommendation_type: RecommendationType::CompressData,
            title: format!("Compress cold data in {}", table),
            description: format!(
                "Table {} is {}MB and inactive. Compression could save {}MB.",
                table, size_mb, (size_mb as f64 * compression_ratio) as u64
            ),
            rationale: format!(
                "Low access rate data can be compressed to save {:.0}% storage.",
                compression_ratio * 100.0
            ),
            target_type: RecommendationTarget::Table,
            target_name: table.to_string(),
            estimated_benefit: ImpactEstimate {
                latency_reduction_percent: 0.0,
                throughput_increase_percent: 0.0,
                cost_reduction_percent: Some(compression_ratio * 100.0),
                storage_overhead_bytes: None,
            },
            effort_level: EffortLevel::Easy,
            priority: RecommendationPriority::Low,
            confidence: 0.75,
            supporting_evidence: vec![
                Evidence {
                    evidence_type: "data_size".to_string(),
                    description: format!("Size: {}MB", size_mb),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("size_mb".to_string(), size_mb.to_string());
                        map
                    },
                },
                Evidence {
                    evidence_type: "compression_ratio".to_string(),
                    description: format!("Expected {:.0}% size reduction", compression_ratio * 100.0),
                    data: {
                        let mut map = HashMap::new();
                        map.insert("ratio".to_string(), compression_ratio.to_string());
                        map
                    },
                },
            ],
        }
    }

    /// Calculate recommendation priority.
    fn calculate_priority(execution_count: u64, potential_benefit: f64) -> RecommendationPriority {
        if execution_count > 1000 && potential_benefit > 50.0 {
            RecommendationPriority::Critical
        } else if execution_count > 500 || potential_benefit > 30.0 {
            RecommendationPriority::High
        } else if execution_count > 100 || potential_benefit > 10.0 {
            RecommendationPriority::Medium
        } else {
            RecommendationPriority::Low
        }
    }

    /// Get next recommendation ID.
    fn next_id(&mut self) -> RecommendationId {
        let id = self.next_id;
        self.next_id += 1;
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_recommendation_engine_creation() {
        let engine = RecommendationEngine::default_config();
        assert_eq!(engine.config.min_execution_count, 100);
    }

    #[test]
    fn test_generate_from_empty_patterns() {
        let mut engine = RecommendationEngine::default_config();
        let recommendations = engine.generate_from_patterns(&[]);
        assert_eq!(recommendations.len(), 0);
    }

    #[test]
    fn test_generate_from_patterns() {
        let mut engine = RecommendationEngine::default_config();

        let pattern = QueryPattern {
            fingerprint: 12345,
            query_type: crate::analytics::usage::QueryType::FullScan,
            table_name: "users".to_string(),
            columns_accessed: vec!["id".to_string(), "name".to_string()],
            execution_count: 1000,
            first_seen: SystemTime::now(),
            last_seen: SystemTime::now(),
            avg_latency_ms: 100.0,
            p50_latency_ms: 50.0,
            p95_latency_ms: 200.0,
            p99_latency_ms: 300.0,
            avg_rows_scanned: 100000.0,
            avg_rows_returned: 1000.0,
            scan_return_ratio: 100.0,
            cache_hit_rate: 0.5,
            plan_cache_hit_rate: 0.6,
            hourly_frequency: [0; 24],
            day_of_week_frequency: [0; 7],
        };

        let recommendations = engine.generate_from_patterns(&[pattern]);

        // Should generate at least one recommendation
        assert!(recommendations.len() >= 1);

        // Check that recommendation has expected fields
        let rec = &recommendations[0];
        assert!(!rec.title.is_empty());
        assert!(!rec.description.is_empty());
        assert!(rec.estimated_benefit.latency_reduction_percent > 0.0);
    }

    #[test]
    fn test_priority_calculation() {
        let priority = RecommendationEngine::calculate_priority(2000, 80.0);
        assert_eq!(priority, RecommendationPriority::Critical);

        let priority = RecommendationEngine::calculate_priority(100, 5.0);
        assert_eq!(priority, RecommendationPriority::Low);
    }

    #[test]
    fn test_create_cache_warming_recommendation() {
        let mut engine = RecommendationEngine::default_config();
        let rec = engine.create_cache_warming_recommendation("user:1234", 1, 0.95, 500.0);

        assert_eq!(rec.target_type, RecommendationTarget::Key);
        assert_eq!(rec.target_name, "user:1234");
        assert_eq!(rec.priority, RecommendationPriority::High);
        assert_eq!(rec.effort_level, EffortLevel::Trivial);
        assert!(rec.estimated_benefit.latency_reduction_percent > 90.0);
    }
}
