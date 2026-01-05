//! Query Pattern Analysis for Usage Analytics.
//!
//! This module provides pattern recognition and clustering for similar queries
//! to identify recurring access patterns and optimize database performance.

use crate::analytics::usage::{QueryFingerprint, QueryType, QueryPattern};
use crate::query_plan::QueryPlan;
use std::collections::HashMap;
use std::time::SystemTime;
use serde::{Serialize, Deserialize};

/// Pattern cluster containing similar queries.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatternCluster {
    /// Cluster ID (representative fingerprint)
    pub cluster_id: QueryFingerprint,

    /// Cluster size (number of unique queries in cluster)
    pub cluster_size: usize,

    /// Representative query (most frequent)
    pub representative_query: String,

    /// Query type for this cluster
    pub query_type: QueryType,

    /// Table name
    pub table_name: String,

    /// Columns accessed
    pub columns: Vec<String>,

    /// Total executions across all queries in cluster
    pub total_executions: u64,

    /// Average latency across cluster
    pub avg_latency_ms: f64,

    /// Cluster efficiency score (0.0 to 1.0)
    pub efficiency_score: f64,
}

/// Pattern analyzer for clustering and analysis.
pub struct PatternAnalyzer {
    /// Query patterns
    patterns: HashMap<QueryFingerprint, QueryPattern>,

    /// Pattern clusters (fingerprint -> cluster_id)
    clusters: HashMap<QueryFingerprint, QueryFingerprint>,
}

impl PatternAnalyzer {
    /// Create new pattern analyzer.
    pub fn new() -> Self {
        Self {
            patterns: HashMap::new(),
            clusters: HashMap::new(),
        }
    }

    /// Add query to pattern analyzer.
    pub fn add_query(&mut self, fingerprint: QueryFingerprint, query: &QueryPlan, query_type: QueryType) {
        let table_name = Self::extract_table_name(query);

        let pattern = self.patterns.entry(fingerprint).or_insert_with(|| {
            QueryPattern::new(fingerprint, query_type, table_name)
        });

        // Update pattern would happen here with actual metrics
    }

    /// Cluster similar patterns.
    pub fn cluster_patterns(&mut self) -> Vec<PatternCluster> {
        let mut clusters: HashMap<QueryFingerprint, PatternCluster> = HashMap::new();

        for (fingerprint, pattern) in &self.patterns {
            // Simple clustering: group by table and query type
            let cluster_key = Self::compute_cluster_key(pattern);

            let cluster = clusters.entry(cluster_key).or_insert_with(|| {
                PatternCluster {
                    cluster_id: cluster_key,
                    cluster_size: 0,
                    representative_query: pattern.table_name.clone(),
                    query_type: pattern.query_type,
                    table_name: pattern.table_name.clone(),
                    columns: pattern.columns_accessed.clone(),
                    total_executions: 0,
                    avg_latency_ms: 0.0,
                    efficiency_score: 0.0,
                }
            });

            cluster.cluster_size += 1;
            cluster.total_executions += pattern.execution_count;
            cluster.avg_latency_ms += pattern.avg_latency_ms;
        }

        // Compute averages
        for cluster in clusters.values_mut() {
            if cluster.cluster_size > 0 {
                cluster.avg_latency_ms /= cluster.cluster_size as f64;
            }

            // Compute efficiency score (low scan/return ratio = high efficiency)
            let pattern = self.patterns.get(&cluster.cluster_id);
            if let Some(p) = pattern {
                cluster.efficiency_score = if p.scan_return_ratio > 0.0 {
                    (1.0 / p.scan_return_ratio).min(1.0)
                } else {
                    0.0
                };
            }
        }

        clusters.into_values().collect()
    }

    /// Get pattern by fingerprint.
    pub fn get_pattern(&self, fingerprint: QueryFingerprint) -> Option<&QueryPattern> {
        self.patterns.get(&fingerprint)
    }

    /// Get all patterns.
    pub fn get_all_patterns(&self) -> Vec<&QueryPattern> {
        self.patterns.values().collect()
    }

    /// Extract table name from query.
    fn extract_table_name(query: &QueryPlan) -> String {
        let text = query.query_text.to_lowercase();

        if let Some(idx) = text.find("from ") {
            let rest = &text[idx + 5..];
            if let Some(end) = rest.chars().position(|c| c.is_whitespace()) {
                return rest[..end].to_string();
            }
        }

        "unknown".to_string()
    }

    /// Compute cluster key for pattern.
    fn compute_cluster_key(pattern: &QueryPattern) -> QueryFingerprint {
        use std::hash::{Hash, Hasher};
        use std::collections::hash_map::DefaultHasher;

        let mut hasher = DefaultHasher::new();
        pattern.table_name.hash(&mut hasher);
        (pattern.query_type as u8).hash(&mut hasher);
        hasher.finish()
    }
}

impl Default for PatternAnalyzer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pattern_analyzer_creation() {
        let analyzer = PatternAnalyzer::new();
        assert_eq!(analyzer.get_all_patterns().len(), 0);
    }

    #[test]
    fn test_add_query() {
        let mut analyzer = PatternAnalyzer::new();

        use crate::query_plan::{PlanNode, PlanType, PlanNodeType};
        let scan_node = PlanNode::new(1, PlanNodeType::TableScan, 1000.0);

        let plan = QueryPlan::new(
            1,
            "SELECT * FROM users WHERE id = 123".to_string(),
            scan_node,
            PlanType::Estimated,
        );

        analyzer.add_query(12345, &plan, QueryType::PointLookup);

        assert_eq!(analyzer.get_all_patterns().len(), 1);
    }

    #[test]
    fn test_cluster_patterns() {
        let mut analyzer = PatternAnalyzer::new();

        use crate::query_plan::{PlanNode, PlanType, PlanNodeType};
        let scan_node1 = PlanNode::new(1, PlanNodeType::TableScan, 1000.0);
        let scan_node2 = PlanNode::new(2, PlanNodeType::TableScan, 1000.0);

        let plan1 = QueryPlan::new(
            1,
            "SELECT * FROM users WHERE id = 123".to_string(),
            scan_node1,
            PlanType::Estimated,
        );

        let plan2 = QueryPlan::new(
            2,
            "SELECT * FROM users WHERE name = 'test'".to_string(),
            scan_node2,
            PlanType::Estimated,
        );

        analyzer.add_query(12345, &plan1, QueryType::PointLookup);
        analyzer.add_query(12346, &plan2, QueryType::PointLookup);

        let clusters = analyzer.cluster_patterns();

        // Should cluster both queries together (same table, same type)
        assert!(clusters.len() >= 1);
    }
}
