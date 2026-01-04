//! Index Usage Statistics Module
//!
//! This module provides comprehensive tracking and analysis of index performance
//! and effectiveness within NorthstarDB. It enables database administrators and
//! automated systems to understand which indexes are being used, how efficiently
//! they are performing, and which indexes might be candidates for removal or
//! optimization.
//!
//! # Features
//!
//! - **Usage Tracking**: Monitor index access patterns (seeks, scans, rows)
//! - **Efficiency Metrics**: Selectivity, cache hit ratio, scan performance
//! - **Trend Analysis**: Track changes in usage and efficiency over time
//! - **Unused Detection**: Identify indexes that can be safely dropped
//! - **Index Comparison**: Find redundancy and consolidation opportunities
//!
//! # Example
//!
//! ```no_run
//! use northstar::query_plan::index_stats::{
//!     collect_index_stats, calculate_index_efficiency_score,
//! };
//!
//! // Collect statistics for an index
//! let stats = collect_index_stats(&conn, "idx_users_email").unwrap();
//!
//! // Calculate efficiency score
//! let score = calculate_index_efficiency_score(&stats);
//! println!("Index efficiency: {:.1}/100", score);
//! ```

mod analyzer;
mod collector;
mod error;
mod formatter;
mod reporter;
mod types;

pub use analyzer::{
    analyze_usage_trend, calculate_index_efficiency_score, compare_indexes,
    ConsolidationOpportunity, ConsolidationRisk, IndexOverlap, OverlapType,
    RecommendedAction, SelectivityTrend, TrendDirection, EfficiencyTrend, IndexComparisonReport,
};
pub use collector::{collect_all_index_stats, collect_index_stats, take_snapshot};
pub use error::{IndexStatsError, Result};
pub use formatter::{format_index_stats_text, format_unused_report_text};
pub use reporter::{
    generate_unused_index_report, DropSafety, UnusedIndexInfo, UnusedIndexReport,
};
pub use types::{
    IndexAccessStats, IndexEfficiencyMetrics, IndexMaintenanceStats, IndexSizeStats,
    IndexUsageSnapshot, IndexUsageStats, IndexType,
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query_plan::index_stats::types::{
        IndexAccessStats, IndexEfficiencyMetrics, IndexMaintenanceStats, IndexSizeStats,
        IndexType, IndexUsageStats,
    };
    use std::time::{SystemTime, UNIX_EPOCH};

    fn create_test_stats() -> IndexUsageStats {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();

        IndexUsageStats {
            index_name: "idx_users_email".to_string(),
            table_name: "users".to_string(),
            index_type: IndexType::BTree,
            indexed_columns: vec!["email".to_string()],
            is_unique: true,
            is_primary: false,
            period_start: now - 86400,
            period_end: now,
            access_stats: IndexAccessStats {
                total_seeks: 15432,
                total_scans: 2145,
                total_full_scans: 12,
                rows_returned: 18234,
                rows_read: 20000,
                index_only_scans: 1234,
                result_lookups: 911,
                unique_queries: 500,
                last_access_time: Some(now),
                access_frequency_per_hour: 730.0,
            },
            efficiency_metrics: IndexEfficiencyMetrics {
                selectivity_avg: 0.0001,
                selectivity_stddev: 0.00005,
                avg_rows_per_scan: 8.5,
                p50_rows_per_scan: 5.0,
                p95_rows_per_scan: 25.0,
                p99_rows_per_scan: 50.0,
                pages_read_per_scan_avg: 3.2,
                index_depth: 3,
                avg_seeks_per_query: 1.0,
                cache_hit_ratio: 0.942,
            },
            size_stats: IndexSizeStats {
                total_pages: 1234,
                leaf_pages: 1000,
                internal_pages: 234,
                total_size_bytes: 10_270_604,
                avg_leaf_fill_pct: 78.0,
                avg_internal_fill_pct: 85.0,
                fragmentation_pct: 12.0,
                cache_pages: 200,
                cache_memory_bytes: 1_638_400,
            },
            maintenance_stats: IndexMaintenanceStats {
                inserts_handled: 45678,
                updates_handled: 12345,
                deletes_handled: 2345,
                pages_split: 123,
                pages_merged: 45,
                avg_insert_time_us: 45.0,
                avg_delete_time_us: 35.0,
                write_amplification: 1.3,
                maintenance_overhead_pct: 8.5,
            },
        }
    }

    #[test]
    fn test_module_integration() {
        let stats = create_test_stats();

        // Test basic properties
        assert_eq!(stats.index_name, "idx_users_email");
        assert_eq!(stats.table_name, "users");
        assert!(stats.is_unique);
        assert!(!stats.is_primary);

        // Test efficiency score calculation
        let score = calculate_index_efficiency_score(&stats);
        assert!(score >= 0.0 && score <= 100.0);
        assert!(score > 50.0, "High-efficiency index should score well");
    }

    #[test]
    fn test_access_stats_invariants() {
        let access = IndexAccessStats::default();

        // Test default values
        assert_eq!(access.total_seeks, 0);
        assert_eq!(access.rows_returned, 0);
        assert_eq!(access.rows_read, 0);
    }

    #[test]
    fn test_efficiency_metrics_invariants() {
        let metrics = IndexEfficiencyMetrics::default();

        // Test default values
        assert_eq!(metrics.selectivity_avg, 0.0);
        assert_eq!(metrics.cache_hit_ratio, 0.0);
    }

    #[test]
    fn test_size_stats_invariants() {
        let size = IndexSizeStats::default();

        // Test default values
        assert_eq!(size.total_pages, 0);
        assert_eq!(size.total_size_bytes, 0);
    }

    #[test]
    fn test_maintenance_stats_invariants() {
        let maint = IndexMaintenanceStats::default();

        // Test default values
        assert_eq!(maint.inserts_handled, 0);
        assert_eq!(maint.write_amplification, 0.0);
    }

    #[test]
    fn test_formatting() {
        let stats = create_test_stats();

        // Test text formatting
        let text = format_index_stats_text(&stats);
        assert!(text.contains("idx_users_email"));
        assert!(text.contains("users"));
        assert!(text.contains("Access Statistics"));
        assert!(text.contains("Efficiency Metrics"));
    }
}
