//! Statistics-Based Query Optimizer
//!
//! This module provides query optimization based on statistical information
//! about data distribution. It uses histograms, cardinality estimates, and
//! correlation data to make better optimization decisions.

use crate::queries::types::{FilterOperator, QueryOperation, QueryPlan};
use crate::{Error, Result};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Histogram bucket for value distribution
#[derive(Debug, Clone)]
pub struct HistogramBucket {
    /// Lower bound (inclusive)
    pub lower_bound: f64,
    /// Upper bound (exclusive)
    pub upper_bound: f64,
    /// Number of rows in this bucket
    pub row_count: u64,
    /// Number of distinct values in this bucket
    pub distinct_count: u64,
}

impl HistogramBucket {
    /// Calculate selectivity for a predicate
    pub fn calculate_selectivity(&self, operator: &FilterOperator, value: f64) -> f64 {
        match operator {
            FilterOperator::Equal => {
                // Estimate: 1 / distinct_count
                if self.distinct_count > 0 {
                    1.0 / self.distinct_count as f64
                } else {
                    0.0
                }
            }
            FilterOperator::NotEqual => {
                // Estimate: 1 - (1 / distinct_count)
                if self.distinct_count > 0 {
                    1.0 - (1.0 / self.distinct_count as f64)
                } else {
                    1.0
                }
            }
            FilterOperator::LessThan | FilterOperator::LessEqual => {
                // Estimate based on value position in bucket
                if value <= self.lower_bound {
                    0.0
                } else if value >= self.upper_bound {
                    1.0
                } else {
                    let bucket_width = self.upper_bound - self.lower_bound;
                    let position = (value - self.lower_bound) / bucket_width;
                    position.min(1.0).max(0.0)
                }
            }
            FilterOperator::GreaterThan | FilterOperator::GreaterEqual => {
                // Complement of less-than
                if value <= self.lower_bound {
                    1.0
                } else if value >= self.upper_bound {
                    0.0
                } else {
                    let bucket_width = self.upper_bound - self.lower_bound;
                    let position = (value - self.lower_bound) / bucket_width;
                    (1.0 - position).min(1.0).max(0.0)
                }
            }
        }
    }
}

/// Column statistics
#[derive(Debug, Clone)]
pub struct ColumnStatistics {
    /// Column name
    pub column_name: String,
    /// Table name
    pub table_name: String,
    /// Total number of rows
    pub total_rows: u64,
    /// Number of distinct values
    pub distinct_count: u64,
    /// Number of null values
    pub null_count: u64,
    /// Minimum value
    pub min_value: Option<f64>,
    /// Maximum value
    pub max_value: Option<f64>,
    /// Average value
    pub avg_value: Option<f64>,
    /// Histogram buckets
    pub histogram: Vec<HistogramBucket>,
    /// Most common values (top-k)
    pub top_values: Vec<(f64, u64)>, // (value, frequency)
    /// Last updated timestamp
    pub last_updated: u64,
}

impl ColumnStatistics {
    /// Create new column statistics
    pub fn new(column_name: &str, table_name: &str, total_rows: u64) -> Self {
        Self {
            column_name: column_name.to_string(),
            table_name: table_name.to_string(),
            total_rows,
            distinct_count: total_rows,
            null_count: 0,
            min_value: None,
            max_value: None,
            avg_value: None,
            histogram: Vec::new(),
            top_values: Vec::new(),
            last_updated: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
        }
    }

    /// Estimate selectivity for a predicate
    pub fn estimate_selectivity(
        &self,
        operator: &FilterOperator,
        value: Option<f64>,
    ) -> f64 {
        // Handle null values
        if value.is_none() {
            return match operator {
                FilterOperator::Equal => self.null_count as f64 / self.total_rows as f64,
                FilterOperator::NotEqual => 1.0 - (self.null_count as f64 / self.total_rows as f64),
                _ => 0.0, // Comparisons with null are undefined
            };
        }

        let value = value.unwrap();

        // Check top values first (most accurate)
        for (top_value, freq) in &self.top_values {
            if (top_value - value).abs() < f64::EPSILON {
                return match operator {
                    FilterOperator::Equal => *freq as f64 / self.total_rows as f64,
                    FilterOperator::NotEqual => {
                        1.0 - (*freq as f64 / self.total_rows as f64)
                    }
                    _ => self.estimate_range_selectivity(operator, value),
                };
            }
        }

        self.estimate_range_selectivity(operator, value)
    }

    /// Estimate selectivity for range predicates
    fn estimate_range_selectivity(&self, operator: &FilterOperator, value: f64) -> f64 {
        // Use histogram if available
        if !self.histogram.is_empty() {
            for bucket in &self.histogram {
                if value >= bucket.lower_bound && value < bucket.upper_bound {
                    return bucket.calculate_selectivity(operator, value);
                }
            }
        }

        // Fall back to uniform distribution assumption
        let distinct = self.distinct_count as f64;
        match operator {
            FilterOperator::Equal => 1.0 / distinct,
            FilterOperator::NotEqual => 1.0 - (1.0 / distinct),
            FilterOperator::LessThan | FilterOperator::LessEqual => {
                if let (Some(min), Some(max)) = (self.min_value, self.max_value) {
                    if max > min {
                        let position = (value - min) / (max - min);
                        position.clamp(0.0, 1.0)
                    } else {
                        0.5
                    }
                } else {
                    0.5
                }
            }
            FilterOperator::GreaterThan | FilterOperator::GreaterEqual => {
                if let (Some(min), Some(max)) = (self.min_value, self.max_value) {
                    if max > min {
                        let position = (value - min) / (max - min);
                        (1.0 - position).clamp(0.0, 1.0)
                    } else {
                        0.5
                    }
                } else {
                    0.5
                }
            }
        }
    }

    /// Calculate cardinality estimate for a predicate
    pub fn estimate_cardinality(
        &self,
        operator: &FilterOperator,
        value: Option<f64>,
    ) -> u64 {
        let selectivity = self.estimate_selectivity(operator, value);
        ((self.total_rows as f64) * selectivity) as u64
    }
}

/// Correlation statistics between columns
#[derive(Debug, Clone)]
pub struct CorrelationStatistics {
    /// First column name
    pub column_a: String,
    /// Second column name
    pub column_b: String,
    /// Correlation coefficient (-1 to 1)
    pub correlation_coefficient: f64,
}

/// Statistics-based optimizer
pub struct StatisticsOptimizer {
    /// Column statistics
    column_stats: Arc<RwLock<HashMap<String, ColumnStatistics>>>,

    /// Correlation statistics
    correlations: Arc<RwLock<HashMap<String, CorrelationStatistics>>>,

    /// Statistics are stale after this duration (seconds)
    staleness_threshold: u64,
}

impl StatisticsOptimizer {
    /// Create new statistics-based optimizer
    pub fn new() -> Self {
        Self {
            column_stats: Arc::new(RwLock::new(HashMap::new())),
            correlations: Arc::new(RwLock::new(HashMap::new())),
            staleness_threshold: 3600, // 1 hour
        }
    }

    /// Create with custom staleness threshold
    pub fn with_staleness_threshold(seconds: u64) -> Self {
        Self {
            column_stats: Arc::new(RwLock::new(HashMap::new())),
            correlations: Arc::new(RwLock::new(HashMap::new())),
            staleness_threshold: seconds,
        }
    }

    /// Add or update column statistics
    pub async fn update_column_stats(&self, stats: ColumnStatistics) -> Result<()> {
        let key = format!("{}.{}", stats.table_name, stats.column_name);
        let mut stats_map = self.column_stats.write().await;
        stats_map.insert(key, stats);
        Ok(())
    }

    /// Get column statistics
    pub async fn get_column_stats(
        &self,
        table_name: &str,
        column_name: &str,
    ) -> Option<ColumnStatistics> {
        let key = format!("{}.{}", table_name, column_name);
        let stats_map = self.column_stats.read().await;
        stats_map.get(&key).cloned()
    }

    /// Estimate cost of a query operation
    pub async fn estimate_operation_cost(
        &self,
        operation: &QueryOperation,
    ) -> Result<f64> {
        let base_cost = match operation {
            QueryOperation::PointLookup { .. } => 1.0,
            QueryOperation::EntityLookup { lookup_type, .. } => match lookup_type {
                crate::queries::types::LookupType::ById => 1.0,
                crate::queries::types::LookupType::ByName => 2.0,
                _ => 5.0,
            },
            QueryOperation::Filter { .. } => 5.0,
            QueryOperation::RelationshipTraversal { max_depth, .. } => *max_depth as f64 * 10.0,
            QueryOperation::RangeScan { .. } => 50.0,
            QueryOperation::Aggregate { .. } => 15.0,
            QueryOperation::Sort { .. } => 20.0,
            QueryOperation::Limit { .. } => 0.5,
        };

        Ok(base_cost)
    }

    /// Estimate selectivity of a filter operation
    pub async fn estimate_filter_selectivity(
        &self,
        table_name: &str,
        column_name: &str,
        operator: &FilterOperator,
        value: Option<f64>,
    ) -> f64 {
        if let Some(stats) = self.get_column_stats(table_name, column_name).await {
            stats.estimate_selectivity(operator, value)
        } else {
            // Default selectivity estimates (heuristic)
            match operator {
                FilterOperator::Equal => 0.1,
                FilterOperator::NotEqual => 0.9,
                FilterOperator::LessThan | FilterOperator::LessEqual => 0.3,
                FilterOperator::GreaterThan | FilterOperator::GreaterEqual => 0.3,
            }
        }
    }

    /// Optimize query operations using statistics
    pub async fn optimize_operations(
        &self,
        operations: Vec<QueryOperation>,
    ) -> Result<Vec<QueryOperation>> {
        let mut optimized = Vec::new();

        // Reorder by estimated selectivity
        let mut cost_estimates: Vec<(QueryOperation, f64)> = operations
            .into_iter()
            .map(|op| {
                let cost = self
                    .estimate_operation_cost(&op)
                    .unwrap_or(10.0);
                (op, cost)
            })
            .collect();

        // Sort by cost (lowest first)
        cost_estimates.sort_by(|a, b| {
            a.1.partial_cmp(&b.1)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        for (op, _) in cost_estimates {
            optimized.push(op);
        }

        Ok(optimized)
    }

    /// Check if statistics are stale
    pub async fn are_stats_stale(&self, table_name: &str, column_name: &str) -> bool {
        if let Some(stats) = self.get_column_stats(table_name, column_name).await {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs();

            now.saturating_sub(stats.last_updated) > self.staleness_threshold
        } else {
            true // No stats means they're "stale"
        }
    }

    /// Add correlation statistics
    pub async fn add_correlation(&self, correlation: CorrelationStatistics) -> Result<()> {
        let key = format!("{}_{}", correlation.column_a, correlation.column_b);
        let mut corr_map = self.correlations.write().await;
        corr_map.insert(key, correlation);
        Ok(())
    }

    /// Get correlation between columns
    pub async fn get_correlation(
        &self,
        column_a: &str,
        column_b: &str,
    ) -> Option<CorrelationStatistics> {
        let key = format!("{}_{}", column_a, column_b);
        let corr_map = self.correlations.read().await;
        corr_map.get(&key).cloned()
    }

    /// Estimate combined selectivity for multiple predicates
    pub async fn estimate_combined_selectivity(
        &self,
        predicates: &[(String, String, FilterOperator, Option<f64>)], // (table, column, op, value)
    ) -> f64 {
        if predicates.is_empty() {
            return 1.0;
        }

        let mut selectivities: Vec<f64> = Vec::new();

        for (table, column, op, value) in predicates {
            let sel = self
                .estimate_filter_selectivity(table, column, op, *value)
                .await;
            selectivities.push(sel);
        }

        // Check for correlations
        let mut combined = selectivities[0];

        for i in 1..selectivities.len() {
            // Check if predicates are correlated
            let col_a = &predicates[i - 1].1;
            let col_b = &predicates[i].1;

            if let Some(corr) = self.get_correlation(col_a, col_b).await {
                // Adjust combined selectivity based on correlation
                // High positive correlation: less reduction in selectivity
                // High negative correlation: more reduction in selectivity
                let correlation_factor = 1.0 - (corr.correlation_coefficient.abs() * 0.3);
                combined *= selectivities[i] * correlation_factor;
            } else {
                // Assume independence
                combined *= selectivities[i];
            }
        }

        combined.max(0.0).min(1.0)
    }
}

impl Default for StatisticsOptimizer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::queries::types::LookupType;

    #[tokio::test]
    async fn test_column_stats_creation() {
        let stats = ColumnStatistics::new("id", "users", 1000);

        assert_eq!(stats.column_name, "id");
        assert_eq!(stats.total_rows, 1000);
        assert_eq!(stats.distinct_count, 1000);
    }

    #[tokio::test]
    async fn test_selectivity_equal() {
        let mut stats = ColumnStatistics::new("id", "users", 1000);
        stats.distinct_count = 1000;

        let selectivity = stats.estimate_selectivity(&FilterOperator::Equal, Some(5.0));
        assert!((selectivity - 0.001).abs() < 0.0001); // 1/1000
    }

    #[tokio::test]
    async fn test_selectivity_range() {
        let mut stats = ColumnStatistics::new("age", "users", 1000);
        stats.min_value = Some(0.0);
        stats.max_value = Some(100.0);

        // Greater than 50 should be ~50%
        let selectivity = stats.estimate_selectivity(&FilterOperator::GreaterThan, Some(50.0));
        assert!((selectivity - 0.5).abs() < 0.01);
    }

    #[tokio::test]
    async fn test_histogram_bucket() {
        let bucket = HistogramBucket {
            lower_bound: 0.0,
            upper_bound: 100.0,
            row_count: 100,
            distinct_count: 100,
        };

        // Equal selectivity
        let eq_sel = bucket.calculate_selectivity(&FilterOperator::Equal, 50.0);
        assert!((eq_sel - 0.01).abs() < 0.001);

        // Range selectivity
        let lt_sel = bucket.calculate_selectivity(&FilterOperator::LessThan, 75.0);
        assert!((lt_sel - 0.75).abs() < 0.01);
    }

    #[tokio::test]
    async fn test_update_column_stats() {
        let optimizer = StatisticsOptimizer::new();
        let stats = ColumnStatistics::new("id", "users", 1000);

        optimizer.update_column_stats(stats).await.unwrap();

        let retrieved = optimizer.get_column_stats("users", "id").await;
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap().total_rows, 1000);
    }

    #[tokio::test]
    async fn test_estimate_operation_cost() {
        let optimizer = StatisticsOptimizer::new();

        let point_lookup = QueryOperation::PointLookup { key: vec![1, 2, 3] };
        let cost = optimizer.estimate_operation_cost(&point_lookup).await.unwrap();
        assert_eq!(cost, 1.0);

        let range_scan = QueryOperation::RangeScan {
            start: vec![],
            end: vec![],
        };
        let cost = optimizer.estimate_operation_cost(&range_scan).await.unwrap();
        assert_eq!(cost, 50.0);
    }

    #[tokio::test]
    async fn test_optimize_operations() {
        let optimizer = StatisticsOptimizer::new();

        let operations = vec![
            QueryOperation::RangeScan {
                start: vec![],
                end: vec![],
            },
            QueryOperation::PointLookup { key: vec![1, 2, 3] },
        ];

        let optimized = optimizer.optimize_operations(operations).await.unwrap();

        // Point lookup should come first (lower cost)
        assert!(matches!(
            optimized[0],
            QueryOperation::PointLookup { .. }
        ));
    }

    #[tokio::test]
    async fn test_combined_selectivity() {
        let optimizer = StatisticsOptimizer::new();

        let predicates = vec![
            ("users".to_string(), "age".to_string(), FilterOperator::GreaterThan, Some(25.0)),
            ("users".to_string(), "age".to_string(), FilterOperator::LessThan, Some(75.0)),
        ];

        // Combined selectivity should be less than individual
        let combined = optimizer.estimate_combined_selectivity(&predicates).await;
        assert!(combined < 1.0);
        assert!(combined > 0.0);
    }

    #[tokio::test]
    async fn test_correlation() {
        let optimizer = StatisticsOptimizer::new();

        let correlation = CorrelationStatistics {
            column_a: "users.age".to_string(),
            column_b: "users.score".to_string(),
            correlation_coefficient: 0.8,
        };

        optimizer.add_correlation(correlation).await.unwrap();

        let retrieved = optimizer
            .get_correlation("users.age", "users.score")
            .await;
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap().correlation_coefficient, 0.8);
    }

    #[tokio::test]
    async fn test_stats_staleness() {
        let optimizer = StatisticsOptimizer::with_staleness_threshold(10);

        let mut stats = ColumnStatistics::new("id", "users", 1000);
        stats.last_updated = 0; // Very old

        optimizer.update_column_stats(stats).await.unwrap();

        assert!(optimizer.are_stats_stale("users", "id").await);
    }

    #[tokio::test]
    async fn test_cardinality_estimate() {
        let mut stats = ColumnStatistics::new("status", "orders", 10000);
        stats.distinct_count = 5; // 5 different status values

        // Cardinality for status = 'pending' should be ~2000
        let cardinality = stats.estimate_cardinality(&FilterOperator::Equal, Some(1.0));
        assert!((cardinality as f64 - 2000.0).abs() < 100.0);
    }
}
