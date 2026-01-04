//! Trend Analysis and Comparison Logic
//!
//! Functions for analyzing index usage trends and comparing indexes.

use super::error::{IndexStatsError, Result};
use super::types::{IndexType, IndexUsageStats, IndexUsageSnapshot};
use std::collections::HashMap;

/// Direction of usage trend
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TrendDirection {
    /// Index usage is growing over time
    Increasing,
    /// Index usage is declining over time
    Decreasing,
    /// Index usage remains consistent
    Stable,
    /// Index usage fluctuates unpredictably
    Volatile,
}

/// How the selectivity of index queries is changing
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SelectivityTrend {
    /// Queries are returning fewer rows (more selective)
    Improving,
    /// Queries are returning more rows (less selective)
    Degraded,
    /// Selectivity remains consistent
    Stable,
}

/// How the overall efficiency of the index is changing
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EfficiencyTrend {
    /// Cache hit ratio improving, scan times decreasing
    Improving,
    /// Cache hit ratio declining, scan times increasing
    Degraded,
    /// Performance remains consistent
    Stable,
}

/// Action to consider based on index usage analysis
#[derive(Debug, Clone, PartialEq)]
pub enum RecommendedAction {
    /// Index is valuable, maintain as-is
    Keep,
    /// Index is unused, consider dropping to reduce overhead
    Drop,
    /// Index is fragmented, rebuild to improve performance
    Rebuild,
    /// Adjust indexed columns based on query patterns
    ModifyColumns,
    /// Combine with other indexes into composite index
    CreateComposite,
    /// Break composite index into separate indexes
    SplitComposite,
    /// Adjust page size for better fit
    ResizePages,
    /// No clear recommendation
    NoAction,
}

/// Analysis of how index usage changes over time
#[derive(Debug, Clone)]
pub struct IndexUsageTrend {
    /// Name of the index
    pub index_name: String,
    /// Table containing the index
    pub table_name: String,
    /// Whether usage is increasing, decreasing, or stable
    pub trend_direction: TrendDirection,
    /// Percentage change in access frequency
    pub access_rate_change_pct: f64,
    /// How selectivity is changing
    pub selectivity_trend: SelectivityTrend,
    /// How efficiency is changing
    pub efficiency_trend: EfficiencyTrend,
    /// Suggested action based on trend
    pub recommended_action: RecommendedAction,
    /// Statistical confidence in trend analysis (0.0 to 1.0)
    pub confidence: f64,
}

impl IndexUsageTrend {
    /// Validate invariants
    pub fn validate(&self) -> Result<()> {
        if !(0.0..=1.0).contains(&self.confidence) {
            return Err(IndexStatsError::InvalidInput(
                "confidence must be between 0.0 and 1.0".to_string(),
            ));
        }
        Ok(())
    }
}

/// How two indexes overlap
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OverlapType {
    /// Indexes have exactly the same columns
    Identical,
    /// One index columns are a prefix of the other
    Prefix,
    /// Indexes share some but not all columns
    Partial,
    /// No column overlap
    None,
}

/// Risk level of index consolidation
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ConsolidationRisk {
    /// Clear benefit with minimal risk
    Low,
    /// Some queries may become slower
    Medium,
    /// Significant performance regression risk for some queries
    High,
}

/// Describes overlap between two indexes
#[derive(Debug, Clone)]
pub struct IndexOverlap {
    /// First index name
    pub index_a: String,
    /// Second index name
    pub index_b: String,
    /// Columns present in both indexes
    pub shared_columns: Vec<String>,
    /// Nature of the overlap
    pub overlap_type: OverlapType,
    /// Total accesses across both indexes
    pub combined_usage: u64,
    /// Accesses to index A only
    pub individual_usage_a: u64,
    /// Accesses to index B only
    pub individual_usage_b: u64,
}

/// Suggests combining multiple indexes into a more efficient single index
#[derive(Debug, Clone)]
pub struct ConsolidationOpportunity {
    /// Suggested composite index columns
    pub proposed_index_columns: Vec<String>,
    /// Indexes that could be replaced
    pub replaces_indexes: Vec<String>,
    /// Expected reduction in maintenance overhead
    pub estimated_benefit_pct: f64,
    /// Number of queries that would use the consolidated index
    pub covers_queries: u64,
    /// Potential downsides
    pub risk_assessment: ConsolidationRisk,
}

/// Report comparing multiple indexes on the same table
#[derive(Debug, Clone)]
pub struct IndexComparisonReport {
    /// Unique identifier for the report
    pub report_id: u64,
    /// Table being analyzed
    pub table_name: String,
    /// Indexes being compared
    pub indexes: Vec<String>,
    /// Pairs of indexes with significant overlap
    pub overlapping_indexes: Vec<IndexOverlap>,
    /// Potential index merges
    pub consolidation_opportunities: Vec<ConsolidationOpportunity>,
    /// Indexes that are subsets of others
    pub redundant_indexes: Vec<String>,
}

/// Analyze multiple snapshots over time to identify trends
pub fn analyze_usage_trend(
    index_name: &str,
    snapshots: Vec<IndexUsageSnapshot>,
) -> Result<IndexUsageTrend> {
    if snapshots.is_empty() {
        return Err(IndexStatsError::AnalysisError(
            "No snapshots provided for trend analysis".to_string(),
        ));
    }

    if snapshots.len() < 2 {
        return Err(IndexStatsError::AnalysisError(
            "At least 2 snapshots required for trend analysis".to_string(),
        ));
    }

    // Extract stats for the specified index from each snapshot
    let mut index_stats_list = Vec::new();
    for snapshot in &snapshots {
        if let Some(stats) = snapshot.get_index_stats(index_name) {
            index_stats_list.push(stats.clone());
        }
    }

    if index_stats_list.is_empty() {
        return Err(IndexStatsError::IndexNotFound(index_name.to_string()));
    }

    // Calculate linear regression of access frequency over time
    let access_freqs: Vec<f64> = index_stats_list
        .iter()
        .map(|s| s.access_stats.access_frequency_per_hour)
        .collect();

    let slope = calculate_slope(&access_freqs);
    let variance = calculate_variance(&access_freqs, slope);

    // Classify trend direction based on slope and variance
    let trend_direction = classify_trend_direction(slope, variance, &access_freqs);

    // Calculate percentage change
    let first = access_freqs.first().unwrap_or(&0.0);
    let last = access_freqs.last().unwrap_or(&0.0);
    let access_rate_change_pct = if *first > 0.0 {
        ((last - first) / first) * 100.0
    } else {
        0.0
    };

    // Analyze selectivity changes
    let selectivity_trend = analyze_selectivity_trend(&index_stats_list);

    // Compare efficiency
    let efficiency_trend = analyze_efficiency_trend(&index_stats_list);

    // Calculate confidence based on sample count and variance
    let confidence = calculate_confidence(snapshots.len(), variance);

    // Determine recommended action
    let recommended_action = determine_recommended_action(
        trend_direction,
        selectivity_trend,
        efficiency_trend,
        confidence,
    );

    Ok(IndexUsageTrend {
        index_name: index_name.to_string(),
        table_name: index_stats_list[0].table_name.clone(),
        trend_direction,
        access_rate_change_pct,
        selectivity_trend,
        efficiency_trend,
        recommended_action,
        confidence,
    })
}

/// Compute a single numerical score representing overall efficiency
pub fn calculate_index_efficiency_score(stats: &IndexUsageStats) -> f64 {
    // Usage component: normalize access frequency to 0-40 points
    let usage_score = (stats.access_stats.access_frequency_per_hour / 100.0 * 40.0).min(40.0);

    // Selectivity component: lower selectivity is better, 0-30 points
    let selectivity_score = (1.0 - stats.efficiency_metrics.selectivity_avg) * 30.0;

    // Efficiency component: cache hit ratio and scan speed, 0-20 points
    let cache_score = stats.efficiency_metrics.cache_hit_ratio * 15.0;
    let scan_score = if stats.efficiency_metrics.avg_rows_per_scan > 0.0 {
        (1.0 / stats.efficiency_metrics.avg_rows_per_scan) * 5.0
    } else {
        0.0
    };
    let efficiency_score = (cache_score + scan_score).min(20.0);

    // Size component: smaller indexes are better, 0-10 points
    let size_score = if stats.size_stats.total_size_bytes > 0 {
        let size_mb = stats.size_stats.total_size_bytes as f64 / (1024.0 * 1024.0);
        (10.0 - size_mb.log2() / 10.0).max(0.0)
    } else {
        0.0
    };

    // Sum components for final score
    let total_score = usage_score + selectivity_score + efficiency_score + size_score;

    // Clamp to 0-100 range
    total_score.max(0.0).min(100.0)
}

/// Analyze all indexes on a specific table
pub fn compare_indexes(_conn: &(), table_name: &str) -> Result<IndexComparisonReport> {
    // Placeholder implementation
    // In production, this would:
    // 1. Query all indexes defined on the specified table
    // 2. For each pair of indexes, compare column sets
    // 3. Identify overlaps and consolidation opportunities
    // 4. Detect redundant indexes
    // 5. Assess risks and benefits

    Ok(IndexComparisonReport {
        report_id: 1,
        table_name: table_name.to_string(),
        indexes: vec![],
        overlapping_indexes: vec![],
        consolidation_opportunities: vec![],
        redundant_indexes: vec![],
    })
}

// Helper functions

fn calculate_slope(values: &[f64]) -> f64 {
    if values.len() < 2 {
        return 0.0;
    }

    let n = values.len() as f64;
    let sum_x: f64 = (0..values.len()).map(|i| i as f64).sum();
    let sum_y: f64 = values.iter().sum();
    let sum_xy: f64 = values
        .iter()
        .enumerate()
        .map(|(i, y)| i as f64 * y)
        .sum();
    let sum_x2: f64 = (0..values.len()).map(|i| (i as f64) * (i as f64)).sum();

    let denominator = n * sum_x2 - sum_x * sum_x;
    if denominator == 0.0 {
        return 0.0;
    }

    (n * sum_xy - sum_x * sum_y) / denominator
}

fn calculate_variance(values: &[f64], slope: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }

    let mean = values.iter().sum::<f64>() / values.len() as f64;
    let sum_squared_diff: f64 = values
        .iter()
        .map(|v| (v - mean).powi(2))
        .sum();

    sum_squared_diff / values.len() as f64
}

fn classify_trend_direction(slope: f64, variance: f64, values: &[f64]) -> TrendDirection {
    const STABILITY_THRESHOLD: f64 = 0.1;
    const VARIANCE_THRESHOLD: f64 = 100.0;

    // Check for volatility first
    if variance > VARIANCE_THRESHOLD {
        return TrendDirection::Volatile;
    }

    // Classify based on slope
    if slope > STABILITY_THRESHOLD {
        TrendDirection::Increasing
    } else if slope < -STABILITY_THRESHOLD {
        TrendDirection::Decreasing
    } else {
        TrendDirection::Stable
    }
}

fn analyze_selectivity_trend(stats_list: &[IndexUsageStats]) -> SelectivityTrend {
    if stats_list.len() < 2 {
        return SelectivityTrend::Stable;
    }

    let first = stats_list.first().unwrap();
    let last = stats_list.last().unwrap();

    if last.efficiency_metrics.selectivity_avg < first.efficiency_metrics.selectivity_avg - 0.01 {
        SelectivityTrend::Improving
    } else if last.efficiency_metrics.selectivity_avg
        > first.efficiency_metrics.selectivity_avg + 0.01
    {
        SelectivityTrend::Degraded
    } else {
        SelectivityTrend::Stable
    }
}

fn analyze_efficiency_trend(stats_list: &[IndexUsageStats]) -> EfficiencyTrend {
    if stats_list.len() < 2 {
        return EfficiencyTrend::Stable;
    }

    let first = stats_list.first().unwrap();
    let last = stats_list.last().unwrap();

    let cache_improved = last.efficiency_metrics.cache_hit_ratio > first.efficiency_metrics.cache_hit_ratio + 0.05;
    let cache_degraded = last.efficiency_metrics.cache_hit_ratio < first.efficiency_metrics.cache_hit_ratio - 0.05;

    if cache_improved {
        EfficiencyTrend::Improving
    } else if cache_degraded {
        EfficiencyTrend::Degraded
    } else {
        EfficiencyTrend::Stable
    }
}

fn calculate_confidence(sample_count: usize, variance: f64) -> f64 {
    // More samples and lower variance = higher confidence
    let sample_factor = (sample_count as f64).min(10.0) / 10.0;
    let variance_factor = 1.0 / (1.0 + variance / 100.0);
    sample_factor * variance_factor
}

fn determine_recommended_action(
    trend: TrendDirection,
    _selectivity: SelectivityTrend,
    _efficiency: EfficiencyTrend,
    confidence: f64,
) -> RecommendedAction {
    if confidence < 0.5 {
        return RecommendedAction::NoAction;
    }

    match trend {
        TrendDirection::Decreasing => RecommendedAction::Drop,
        TrendDirection::Increasing => RecommendedAction::Keep,
        TrendDirection::Stable => RecommendedAction::Keep,
        TrendDirection::Volatile => RecommendedAction::NoAction,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn create_test_snapshot(id: u64, access_freq: f64) -> IndexUsageSnapshot {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();

        let stats = IndexUsageStats {
            index_name: "test_idx".to_string(),
            table_name: "test_table".to_string(),
            index_type: IndexType::BTree,
            indexed_columns: vec!["col".to_string()],
            is_unique: false,
            is_primary: false,
            period_start: now - 3600,
            period_end: now,
            access_stats: crate::query_plan::index_stats::types::IndexAccessStats {
                access_frequency_per_hour: access_freq,
                ..Default::default()
            },
            efficiency_metrics: crate::query_plan::index_stats::types::IndexEfficiencyMetrics {
                cache_hit_ratio: 0.9,
                ..Default::default()
            },
            size_stats: Default::default(),
            maintenance_stats: Default::default(),
        };

        IndexUsageSnapshot::new(id, now, vec![stats])
    }

    #[test]
    fn test_calculate_slope() {
        let increasing = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        assert!(calculate_slope(&increasing) > 0.0);

        let decreasing = vec![5.0, 4.0, 3.0, 2.0, 1.0];
        assert!(calculate_slope(&decreasing) < 0.0);

        let stable = vec![3.0, 3.0, 3.0, 3.0];
        assert!(calculate_slope(&stable).abs() < 0.01);
    }

    #[test]
    fn test_classify_trend_direction() {
        let values = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        assert_eq!(
            classify_trend_direction(1.0, 10.0, &values),
            TrendDirection::Increasing
        );
    }

    #[test]
    fn test_analyze_selectivity_trend() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();

        let stats1 = IndexUsageStats {
            index_name: "test".to_string(),
            table_name: "test".to_string(),
            index_type: IndexType::BTree,
            indexed_columns: vec!["col".to_string()],
            is_unique: false,
            is_primary: false,
            period_start: now - 7200,
            period_end: now - 3600,
            access_stats: Default::default(),
            efficiency_metrics: crate::query_plan::index_stats::types::IndexEfficiencyMetrics {
                selectivity_avg: 0.5,
                ..Default::default()
            },
            size_stats: Default::default(),
            maintenance_stats: Default::default(),
        };

        let stats2 = IndexUsageStats {
            efficiency_metrics: crate::query_plan::index_stats::types::IndexEfficiencyMetrics {
                selectivity_avg: 0.02,
                ..Default::default()
            },
            ..stats1.clone()
        };

        let trend = analyze_selectivity_trend(&[stats1, stats2]);
        assert_eq!(trend, SelectivityTrend::Improving);
    }

    #[test]
    fn test_calculate_confidence() {
        let conf1 = calculate_confidence(5, 10.0);
        let conf2 = calculate_confidence(20, 10.0);

        assert!(conf2 > conf1); // More samples = higher confidence

        let conf3 = calculate_confidence(10, 100.0);
        let conf4 = calculate_confidence(10, 10.0);

        assert!(conf4 > conf3); // Lower variance = higher confidence
    }

    #[test]
    fn test_efficiency_score_bounds() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();

        let stats = IndexUsageStats {
            index_name: "test".to_string(),
            table_name: "test".to_string(),
            index_type: IndexType::BTree,
            indexed_columns: vec!["col".to_string()],
            is_unique: false,
            is_primary: false,
            period_start: now - 3600,
            period_end: now,
            access_stats: crate::query_plan::index_stats::types::IndexAccessStats {
                access_frequency_per_hour: 1000.0,
                ..Default::default()
            },
            efficiency_metrics: crate::query_plan::index_stats::types::IndexEfficiencyMetrics {
                selectivity_avg: 0.001,
                avg_rows_per_scan: 5.0,
                cache_hit_ratio: 0.95,
                ..Default::default()
            },
            size_stats: Default::default(),
            maintenance_stats: Default::default(),
        };

        let score = calculate_index_efficiency_score(&stats);
        assert!(score >= 0.0 && score <= 100.0);
    }

    #[test]
    fn test_analyze_usage_trend_insufficient_snapshots() {
        let result = analyze_usage_trend("test_idx", vec![]);
        assert!(result.is_err());

        let snapshot = create_test_snapshot(1, 100.0);
        let result = analyze_usage_trend("test_idx", vec![snapshot]);
        assert!(result.is_err());
    }

    #[test]
    fn test_analyze_usage_trend_missing_index() {
        let snapshot1 = create_test_snapshot(1, 100.0);
        let snapshot2 = create_test_snapshot(2, 200.0);

        let result = analyze_usage_trend("nonexistent_idx", vec![snapshot1, snapshot2]);
        assert!(result.is_err());
    }

    #[test]
    fn test_analyze_usage_trend_success() {
        let snapshot1 = create_test_snapshot(1, 100.0);
        let snapshot2 = create_test_snapshot(2, 200.0);

        let result = analyze_usage_trend("test_idx", vec![snapshot1, snapshot2]);
        assert!(result.is_ok());

        let trend = result.unwrap();
        assert_eq!(trend.index_name, "test_idx");
        assert!(trend.confidence >= 0.0 && trend.confidence <= 1.0);
    }

    #[test]
    fn test_index_usage_trend_validation() {
        let trend = IndexUsageTrend {
            index_name: "test".to_string(),
            table_name: "test".to_string(),
            trend_direction: TrendDirection::Increasing,
            access_rate_change_pct: 10.0,
            selectivity_trend: SelectivityTrend::Improving,
            efficiency_trend: EfficiencyTrend::Improving,
            recommended_action: RecommendedAction::Keep,
            confidence: 0.8,
        };

        assert!(trend.validate().is_ok());

        let invalid_trend = IndexUsageTrend {
            confidence: 1.5,
            ..trend.clone()
        };

        assert!(invalid_trend.validate().is_err());
    }
}
