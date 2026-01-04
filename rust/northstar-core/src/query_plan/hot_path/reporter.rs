//! Report Generator
//!
//! This module provides functionality to generate hot path analysis reports
//! in various formats (text and JSON).

use std::collections::HashMap;

use chrono::{DateTime, Utc};

use super::types::*;
use super::error::{HotPathError, HotPathResult};
use super::analyzer::{AnalyzerConfig, QueryExecution, TableAccessStats, PageAccessStats};
use super::detector::{SystemMetrics, BottleneckThresholds};
use super::suggester;

/// Report generator configuration.
#[derive(Debug, Clone)]
pub struct ReportConfig {
    /// Maximum number of items to include in each section
    pub max_items_per_section: usize,
    /// Whether to include optimization suggestions
    pub include_suggestions: bool,
    /// Whether to include bottleneck details
    pub include_bottlenecks: bool,
}

impl Default for ReportConfig {
    fn default() -> Self {
        Self {
            max_items_per_section: 10,
            include_suggestions: true,
            include_bottlenecks: true,
        }
    }
}

/// Generate comprehensive hot path analysis report.
///
/// # Arguments
/// * `period_start` - Start of analysis period
/// * `period_end` - End of analysis period
/// * `query_executions` - Query execution records
/// * `table_stats` - Table access statistics
/// * `page_stats` - Page access statistics
/// * `system_metrics` - Current system metrics
/// * `analyzer_config` - Analyzer configuration
/// * `report_config` - Report configuration
///
/// # Returns
/// Complete HotPathReport with all analysis results
pub fn generate_hot_path_report(
    period_start: DateTime<Utc>,
    period_end: DateTime<Utc>,
    query_executions: Vec<QueryExecution>,
    table_stats: Vec<TableAccessStats>,
    page_stats: Vec<PageAccessStats>,
    system_metrics: Option<SystemMetrics>,
    analyzer_config: &AnalyzerConfig,
    report_config: &ReportConfig,
) -> HotPathResult<HotPathReport> {
    // Validate time period
    validate_period(period_start, period_end)?;

    let generated_at = Utc::now();
    let report_id = generate_report_id();

    // Identify hot queries
    let hot_queries = super::analyzer::identify_hot_queries(
        query_executions,
        &AnalyzerConfig {
            limit: report_config.max_items_per_section,
            ..analyzer_config.clone()
        },
    )?;

    // Identify hot tables
    let hot_tables = super::analyzer::identify_hot_tables(
        table_stats,
        &AnalyzerConfig {
            limit: report_config.max_items_per_section,
            ..analyzer_config.clone()
        },
    )?;

    // Identify hot pages
    let hot_pages = super::analyzer::identify_hot_pages(
        page_stats,
        &AnalyzerConfig {
            limit: report_config.max_items_per_section,
            ..analyzer_config.clone()
        },
    )?;

    // Detect bottlenecks if metrics provided and enabled
    let bottlenecks = if report_config.include_bottlenecks {
        if let Some(metrics) = system_metrics {
            super::detector::detect_bottlenecks(&metrics, &BottleneckThresholds::default())?
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };

    // Placeholder for hot indexes (would come from index stats module)
    let hot_indexes: Vec<HotIndex> = Vec::new();

    // Placeholder for hot procedures
    let hot_procedures: Vec<HotProcedure> = Vec::new();

    // Create initial report
    let mut report = HotPathReport {
        report_id,
        generated_at,
        analysis_period_start: period_start,
        analysis_period_end: period_end,
        hot_queries,
        hot_tables,
        hot_indexes,
        hot_pages,
        hot_procedures,
        bottlenecks,
        optimization_opportunities: Vec::new(),
    };

    // Generate optimization suggestions if enabled
    if report_config.include_suggestions {
        report.optimization_opportunities = suggester::suggest_optimizations(&report);
        report.optimization_opportunities.truncate(report_config.max_items_per_section);
    }

    // Validate report
    report.validate().map_err(|e| HotPathError::ReportGenerationError(e))?;

    Ok(report)
}

/// Validate the analysis period.
fn validate_period(start: DateTime<Utc>, end: DateTime<Utc>) -> HotPathResult<()> {
    if end < start {
        return Err(HotPathError::InvalidPeriod(
            "End time is before start time".to_string(),
        ));
    }

    let duration_secs = (end - start).num_seconds();
    if duration_secs < 60 {
        return Err(HotPathError::InvalidPeriod(
            "Analysis period too short (minimum 1 minute)".to_string(),
        ));
    }

    if duration_secs > 90 * 24 * 60 * 60 {
        return Err(HotPathError::InvalidPeriod(
            "Analysis period too long (maximum 90 days)".to_string(),
        ));
    }

    Ok(())
}

/// Generate unique report ID.
fn generate_report_id() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Generate human-readable text report.
///
/// # Arguments
/// * `report` - Hot path report to format
///
/// # Returns
/// Multi-line string with formatted report
pub fn format_hot_path_report_text(report: &HotPathReport) -> String {
    let mut output = String::new();

    // Header
    output.push_str("╔════════════════════════════════════════════════════════════════════╗\n");
    output.push_str("║                    HOT PATH ANALYSIS REPORT                         ║\n");
    output.push_str("╚════════════════════════════════════════════════════════════════════╝\n\n");

    output.push_str(&format!(
        "Report ID: {}\n",
        report.report_id
    ));
    output.push_str(&format!(
        "Period: {} to {}\n",
        report.analysis_period_start.format("%Y-%m-%d %H:%M:%S"),
        report.analysis_period_end.format("%Y-%m-%d %H:%M:%S")
    ));
    output.push_str(&format!(
        "Generated: {}\n\n",
        report.generated_at.format("%Y-%m-%d %H:%M:%S")
    ));

    // Summary
    output.push_str("─────────────────────────────────────────────────────────────────────\n");
    output.push_str("SUMMARY\n");
    output.push_str("─────────────────────────────────────────────────────────────────────\n");
    output.push_str(&format!("Hot Queries: {}\n", report.hot_queries.len()));
    output.push_str(&format!("Hot Tables: {}\n", report.hot_tables.len()));
    output.push_str(&format!("Hot Indexes: {}\n", report.hot_indexes.len()));
    output.push_str(&format!("Hot Pages: {}\n", report.hot_pages.len()));
    output.push_str(&format!("Bottlenecks: {}\n", report.bottlenecks.len()));
    output.push_str(&format!("Optimization Opportunities: {}\n\n", report.optimization_opportunities.len()));

    // Top Hot Queries
    if !report.hot_queries.is_empty() {
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        output.push_str("TOP HOT QUERIES\n");
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        for (i, query) in report.hot_queries.iter().enumerate().take(10) {
            output.push_str(&format!("{}. {} (Impact: {:.1})\n", i + 1, query.query_pattern, query.impact_score));
            output.push_str(&format!("   Executions: {} | Avg time: {:.1}ms | Rows: {:.0}\n",
                query.execution_count, query.avg_execution_time_ms, query.rows_returned_avg));
            output.push_str(&format!("   Cache hit ratio: {:.1}%\n", query.cache_hit_ratio * 100.0));
            output.push_str("   Optimization: Consider reviewing index usage\n\n");
        }
    }

    // Top Hot Tables
    if !report.hot_tables.is_empty() {
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        output.push_str("TOP HOT TABLES\n");
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        for (i, table) in report.hot_tables.iter().enumerate().take(10) {
            output.push_str(&format!("{}. Table: {}.{} (Impact: {:.1})\n",
                i + 1, table.schema_name, table.table_name, table.impact_score));
            output.push_str(&format!("   Accesses: {} | Reads: {} | Writes: {}\n",
                table.access_count, table.read_count, table.write_count));
            output.push_str(&format!("   Cache hit ratio: {:.1}%\n", table.cache_hit_ratio * 100.0));
            output.push_str(&format!("   Table scans: {} | Index scans: {}\n\n",
                table.table_scan_count, table.index_scan_count));
        }
    }

    // Top Hot Indexes
    if !report.hot_indexes.is_empty() {
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        output.push_str("TOP HOT INDEXES\n");
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        for (i, index) in report.hot_indexes.iter().enumerate().take(10) {
            output.push_str(&format!("{}. Index: {} on {} (Impact: {:.1})\n",
                i + 1, index.index_name, index.table_name, index.impact_score));
            output.push_str(&format!("   Seeks: {} | Scans: {} | Selectivity: {:.2}\n",
                index.seek_count, index.scan_count, index.selectivity_avg));
            output.push_str(&format!("   Cache hit ratio: {:.1}%\n\n", index.cache_hit_ratio * 100.0));
        }
    }

    // Top Hot Pages
    if !report.hot_pages.is_empty() {
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        output.push_str("TOP HOT PAGES\n");
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        for (i, page) in report.hot_pages.iter().enumerate().take(10) {
            output.push_str(&format!("{}. Page {} in {} (Impact: {:.1})\n",
                i + 1, page.page_id, page.table_name, page.impact_score));
            output.push_str(&format!("   Access frequency: {:.1}/min | Evictions: {}\n",
                page.access_frequency_per_min, page.cache_evictions));
            output.push_str(&format!("   Cached: {} | Contention: {:.1}\n\n",
                page.is_currently_cached, page.read_contention));
        }
    }

    // Bottlenecks
    if !report.bottlenecks.is_empty() {
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        output.push_str("BOTTLENECKS\n");
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        for (i, bottleneck) in report.bottlenecks.iter().enumerate() {
            output.push_str(&format!("{}. [{:?}] {}\n", i + 1, bottleneck.severity, bottleneck.description));
            output.push_str(&format!("   Current: {:.1} | Threshold: {:.1} | Excess: {:.1}%\n",
                bottleneck.current_value, bottleneck.threshold_value, bottleneck.excess_pct));
            output.push_str(&format!("   Estimated impact: {:.1}ms\n", bottleneck.estimated_impact_ms));
            output.push_str(&format!("   Remediation: {}\n\n", bottleneck.suggested_remediation));
        }
    }

    // Optimization Opportunities
    if !report.optimization_opportunities.is_empty() {
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        output.push_str("OPTIMIZATION OPPORTUNITIES\n");
        output.push_str("─────────────────────────────────────────────────────────────────────\n");
        for (i, opp) in report.optimization_opportunities.iter().enumerate() {
            output.push_str(&format!("{}. {} (Benefit: {:.1}%)\n", i + 1, opp.title, opp.estimated_benefit_pct));
            output.push_str(&format!("   Effort: {:?} | Risk: {:?}\n", opp.effort_level, opp.risk_level));
            output.push_str(&format!("   {}\n", opp.description));
            output.push_str(&format!("   Steps:\n"));
            for (j, step) in opp.implementation_steps.iter().enumerate() {
                output.push_str(&format!("     {}. {}\n", j + 1, step));
            }
            output.push_str(&format!("   Rollback: {}\n\n", opp.rollback_plan));
        }
    }

    output
}

/// Format a severity level for display.
fn format_severity(severity: &Severity) -> &'static str {
    match severity {
        Severity::Low => "LOW",
        Severity::Medium => "MEDIUM",
        Severity::High => "HIGH",
        Severity::Critical => "CRITICAL",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn test_validate_period_valid() {
        let start = Utc::now();
        let end = start + chrono::Duration::hours(1);
        assert!(validate_period(start, end).is_ok());
    }

    #[test]
    fn test_validate_period_invalid_order() {
        let start = Utc::now();
        let end = start - chrono::Duration::hours(1);
        assert!(validate_period(start, end).is_err());
    }

    #[test]
    fn test_validate_period_too_short() {
        let start = Utc::now();
        let end = start + chrono::Duration::seconds(30);
        assert!(validate_period(start, end).is_err());
    }

    #[test]
    fn test_validate_period_too_long() {
        let start = Utc::now();
        let end = start + chrono::Duration::days(100);
        assert!(validate_period(start, end).is_err());
    }

    #[test]
    fn test_generate_report_empty() {
        let start = Utc::now();
        let end = start + chrono::Duration::hours(1);

        let report = generate_hot_path_report(
            start,
            end,
            Vec::new(),
            Vec::new(),
            Vec::new(),
            None,
            &AnalyzerConfig::default(),
            &ReportConfig::default(),
        );

        assert!(report.is_ok());
        let report = report.unwrap();
        assert!(report.hot_queries.is_empty());
        assert!(report.hot_tables.is_empty());
    }

    #[test]
    fn test_format_report_text_empty() {
        let report = HotPathReport::new(1, Utc::now(), Utc::now(), Utc::now());
        let text = format_hot_path_report_text(&report);
        assert!(text.contains("HOT PATH ANALYSIS REPORT"));
        assert!(text.contains("SUMMARY"));
    }

    #[test]
    fn test_format_report_text_with_content() {
        let mut report = HotPathReport::new(1, Utc::now(), Utc::now(), Utc::now());

        report.hot_queries.push(HotQuery {
            query_pattern: "SELECT * FROM users WHERE id = $LIT".to_string(),
            query_hash: 123,
            execution_count: 1000,
            total_execution_time_ms: 5000.0,
            avg_execution_time_ms: 5.0,
            min_execution_time_ms: 1.0,
            max_execution_time_ms: 20.0,
            p50_execution_time_ms: 4.0,
            p95_execution_time_ms: 10.0,
            p99_execution_time_ms: 15.0,
            rows_returned_total: 1000,
            rows_returned_avg: 1.0,
            rows_read_total: 10000,
            blocks_read_total: 100,
            cache_hit_ratio: 0.9,
            first_seen: Utc::now(),
            last_seen: Utc::now(),
            sample_query_text: "SELECT * FROM users WHERE id = 1".to_string(),
            impact_score: 85.0,
        });

        report.hot_pages.push(HotPage {
            page_id: crate::types::PageId::new(100),
            page_type: PageType::DataPage,
            table_name: "users".to_string(),
            access_count: 10000,
            access_frequency_per_min: 500.0,
            last_access_time: Utc::now(),
            first_access_time: Utc::now(),
            is_currently_cached: true,
            cache_evictions: 100,
            avg_cache_residence_time_ms: 1000.0,
            read_contention: 2.0,
            impact_score: 90.0,
        });

        let text = format_hot_path_report_text(&report);
        assert!(text.contains("TOP HOT QUERIES"));
        assert!(text.contains("SELECT * FROM users WHERE id = $LIT"));
        assert!(text.contains("Impact: 85"));
        assert!(text.contains("TOP HOT PAGES"));
    }

    #[test]
    fn test_report_id_generation() {
        let id1 = generate_report_id();
        std::thread::sleep(std::time::Duration::from_millis(10));
        let id2 = generate_report_id();
        assert!(id2 > id1);
    }
}
