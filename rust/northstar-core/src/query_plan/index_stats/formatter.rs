//! Text Output Formatting
//!
//! Functions for generating human-readable text reports of index statistics.

use super::types::IndexUsageStats;
use super::UnusedIndexReport;

/// Generate human-readable text report of index statistics
pub fn format_index_stats_text(stats: &IndexUsageStats) -> String {
    use std::fmt::Write;

    let mut output = String::new();

    // Header
    writeln!(
        output,
        "Index: {} on Table: {}",
        stats.index_name, stats.table_name
    )
    .unwrap();
    writeln!(
        output,
        "Type: {}, Columns: {:?}, Unique: {}",
        stats.index_type, stats.indexed_columns, stats.is_unique
    )
    .unwrap();
    writeln!(output).unwrap();

    // Access Statistics
    writeln!(output, "Access Statistics:").unwrap();
    writeln!(output, "  Total seeks: {}", format_number(stats.access_stats.total_seeks)).unwrap();
    writeln!(output, "  Total scans: {}", format_number(stats.access_stats.total_scans)).unwrap();
    writeln!(
        output,
        "  Rows returned: {}",
        format_number(stats.access_stats.rows_returned)
    )
    .unwrap();
    writeln!(
        output,
        "  Index-only scans: {} ({:.1}%)",
        format_number(stats.access_stats.index_only_scans),
        stats.access_stats.index_only_scan_pct()
    )
    .unwrap();

    if let Some(last_access) = stats.access_stats.last_access_time {
        writeln!(output, "  Last accessed: {}", format_timestamp(last_access)).unwrap();
    } else {
        writeln!(output, "  Last accessed: Never").unwrap();
    }

    writeln!(output).unwrap();

    // Efficiency Metrics
    writeln!(output, "Efficiency Metrics:").unwrap();
    writeln!(
        output,
        "  Avg selectivity: {:.4} ({})",
        stats.efficiency_metrics.selectivity_avg,
        stats.efficiency_metrics.selectivity_rating()
    )
    .unwrap();
    writeln!(
        output,
        "  Avg rows per scan: {:.1}",
        stats.efficiency_metrics.avg_rows_per_scan
    )
    .unwrap();
    writeln!(
        output,
        "  Cache hit ratio: {:.1}%",
        stats.efficiency_metrics.cache_hit_ratio * 100.0
    )
    .unwrap();
    writeln!(
        output,
        "  Index depth: {} levels",
        stats.efficiency_metrics.index_depth
    )
    .unwrap();
    writeln!(output).unwrap();

    // Size Statistics
    writeln!(output, "Size Statistics:").unwrap();
    writeln!(
        output,
        "  Total pages: {}",
        format_number(stats.size_stats.total_pages)
    )
    .unwrap();
    writeln!(
        output,
        "  Total size: {}",
        stats.size_stats.format_size()
    )
    .unwrap();
    writeln!(
        output,
        "  Avg page fill: {:.1}%",
        stats.size_stats.avg_leaf_fill_pct
    )
    .unwrap();
    writeln!(
        output,
        "  Fragmentation: {:.1}%",
        stats.size_stats.fragmentation_pct
    )
    .unwrap();
    writeln!(output).unwrap();

    // Maintenance Overhead
    writeln!(output, "Maintenance Overhead:").unwrap();
    writeln!(
        output,
        "  Inserts handled: {}",
        format_number(stats.maintenance_stats.inserts_handled)
    )
    .unwrap();
    writeln!(
        output,
        "  Avg insert time: {:.0} μs",
        stats.maintenance_stats.avg_insert_time_us
    )
    .unwrap();
    writeln!(
        output,
        "  Write amplification: {:.1}x",
        stats.maintenance_stats.write_amplification
    )
    .unwrap();
    writeln!(
        output,
        "  Maintenance overhead: {:.1}%",
        stats.maintenance_stats.maintenance_overhead_pct
    )
    .unwrap();
    writeln!(output).unwrap();

    // Efficiency Score
    let score = crate::query_plan::index_stats::analyzer::calculate_index_efficiency_score(stats);
    writeln!(output, "Efficiency Score: {:.1} / 100", score).unwrap();

    output
}

/// Generate text summary of unused indexes
pub fn format_unused_report_text(report: &UnusedIndexReport) -> String {
    use std::fmt::Write;

    let mut output = String::new();

    // Header
    writeln!(output, "Unused Index Report").unwrap();
    writeln!(
        output,
        "Period: {} to {}",
        format_timestamp(report.period_start),
        format_timestamp(report.period_end)
    )
    .unwrap();
    writeln!(output).unwrap();

    // Summary
    writeln!(output, "Summary:").unwrap();
    writeln!(
        output,
        "  Total unused indexes: {}",
        report.total_unused_indexes
    )
    .unwrap();
    writeln!(
        output,
        "  Potential disk savings: {}",
        format_bytes(report.potential_savings_bytes)
    )
    .unwrap();
    writeln!(
        output,
        "  Potential write overhead reduction: {:.1}%",
        report.potential_savings_overhead_pct
    )
    .unwrap();
    writeln!(output).unwrap();

    // Individual indexes
    if !report.unused_indexes.is_empty() {
        writeln!(output, "Unused Indexes:").unwrap();

        for (i, idx) in report.unused_indexes.iter().enumerate() {
            writeln!(output, "  {}. {}", i + 1, idx.index_name).unwrap();
            writeln!(output, "     Table: {}", idx.table_name).unwrap();
            writeln!(output, "     Columns: {:?}", idx.indexed_columns).unwrap();
            writeln!(output, "     Type: {}", idx.index_type).unwrap();
            writeln!(
                output,
                "     Size: {}",
                format_bytes(idx.size_bytes)
            )
            .unwrap();
            writeln!(
                output,
                "     Total accesses: {}",
                format_number(idx.total_accesses)
            )
            .unwrap();
            writeln!(
                output,
                "     Days since last access: {}",
                idx.days_since_last_access
            )
            .unwrap();
            writeln!(
                output,
                "     Maintenance cost: {:.1}%",
                idx.maintenance_cost_pct
            )
            .unwrap();
            writeln!(output, "     Drop safety: {:?}", idx.drop_safety).unwrap();

            if idx.is_drop_candidate() {
                writeln!(output, "     Recommendation: Consider dropping").unwrap();
            } else {
                writeln!(output, "     Recommendation: Keep (required or risky)").unwrap();
            }
            writeln!(output).unwrap();
        }
    }

    output
}

// Helper functions

fn format_number(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}

fn format_timestamp(secs: u64) -> String {
    use std::time::{Duration, UNIX_EPOCH};

    if UNIX_EPOCH.checked_add(Duration::from_secs(secs)).is_some() {
        // Use chrono or similar for proper formatting
        // For now, just return the raw timestamp
        format!("{} (Unix timestamp)", secs)
    } else {
        "Invalid timestamp".to_string()
    }
}

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
    fn test_format_index_stats_text() {
        let stats = create_test_stats();
        let text = format_index_stats_text(&stats);

        assert!(text.contains("idx_users_email"));
        assert!(text.contains("users"));
        assert!(text.contains("Access Statistics"));
        assert!(text.contains("Efficiency Metrics"));
        assert!(text.contains("Size Statistics"));
        assert!(text.contains("Maintenance Overhead"));
        assert!(text.contains("Efficiency Score"));
        assert!(text.contains("15.4K")); // Total seeks formatted
        assert!(text.contains("9.8 MB")); // Size formatted
    }

    #[test]
    fn test_format_index_stats_text_no_last_access() {
        let mut stats = create_test_stats();
        stats.access_stats.last_access_time = None;

        let text = format_index_stats_text(&stats);
        assert!(text.contains("Last accessed: Never"));
    }

    #[test]
    fn test_format_unused_report_text_empty() {
        let report = UnusedIndexReport {
            report_id: 1,
            period_start: 1000,
            period_end: 2000,
            unused_indexes: vec![],
            total_unused_indexes: 0,
            potential_savings_bytes: 0,
            potential_savings_overhead_pct: 0.0,
        };

        let text = format_unused_report_text(&report);

        assert!(text.contains("Unused Index Report"));
        assert!(text.contains("Total unused indexes: 0"));
    }

    #[test]
    fn test_format_number() {
        assert_eq!(format_number(500), "500");
        assert_eq!(format_number(1_500), "1.5K");
        assert_eq!(format_number(1_500_000), "1.5M");
    }

    #[test]
    fn test_format_bytes() {
        assert_eq!(format_bytes(500), "500 B");
        assert!(format_bytes(2_000).contains("KB"));
        assert!(format_bytes(5_000_000).contains("MB"));
        assert!(format_bytes(2_000_000_000).contains("GB"));
    }

    #[test]
    fn test_format_timestamp() {
        let ts = format_timestamp(1_600_000_000);
        assert!(ts.contains("1600000000"));
        assert!(ts.contains("Unix timestamp"));
    }
}
