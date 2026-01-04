//! Hot Path Identification Module
//!
//! This module provides comprehensive hot path analysis for NorthstarDB's query
//! optimization system. It analyzes query execution patterns to automatically
//! identify frequently accessed data, performance bottlenecks, and optimization
//! opportunities.
//!
//! # Overview
//!
//! The hot path identification system tracks:
//! - Hot queries: Frequently executed query patterns
//! - Hot tables: High-access tables with I/O metrics
//! - Hot indexes: Heavy index usage with benefit metrics
//! - Hot pages: Frequently accessed disk pages
//! - Bottlenecks: Performance bottlenecks with severity classification
//! - Optimization opportunities: Actionable optimization suggestions
//!
//! # Main Types
//!
//! - [`HotPathReport`] - Comprehensive report aggregating all analysis results
//! - [`HotQuery`] - Frequent query pattern with execution statistics
//! - [`HotTable`] - High-access table with I/O metrics
//! - [`HotIndex`] - Heavy index usage with benefit metrics
//! - [`HotPage`] - Frequently accessed disk pages
//! - [`Bottleneck`] - Performance bottlenecks with severity classification
//! - [`OptimizationOpportunity`] - Suggested optimizations with risk/effort assessment
//!
//! # Usage
//!
//! ```rust
//! use northstar_core::query_plan::hot_path::{
//!     generate_hot_path_report,
//!     format_hot_path_report_text,
//!     AnalyzerConfig,
//!     ReportConfig,
//! };
//! use chrono::{Utc, Duration};
//!
//! // Configure analysis
//! let analyzer_config = AnalyzerConfig::default();
//! let report_config = ReportConfig::default();
//!
//! // Generate report
//! let report = generate_hot_path_report(
//!     Utc::now() - Duration::hours(24),
//!     Utc::now(),
//!     query_executions,
//!     table_stats,
//!     page_stats,
//!     Some(system_metrics),
//!     &analyzer_config,
//!     &report_config,
//! )?;
//!
//! // Format as text
//! let text_report = format_hot_path_report_text(&report);
//! println!("{}", text_report);
//! # Ok::<(), northstar_core::query_plan::hot_path::HotPathError>(())
//! ```

pub mod types;
pub mod error;
pub mod normalizer;
pub mod analyzer;
pub mod detector;
pub mod suggester;
pub mod reporter;

// Re-export main types for convenience
pub use types::{
    HotPathReport,
    HotQuery,
    HotTable,
    HotIndex,
    HotPage,
    HotProcedure,
    Bottleneck,
    BottleneckType,
    Severity,
    OptimizationOpportunity,
    OptimizationType,
    EffortLevel,
    RiskLevel,
    AccessPattern,
    AccessPatternType,
    IndexType,
    PageType,
};

pub use error::{HotPathError, HotPathResult};

pub use analyzer::{
    AnalyzerConfig,
    QueryExecution,
    TableAccessStats,
    PageAccessStats,
    identify_hot_queries,
    identify_hot_tables,
    identify_hot_pages,
    calculate_impact_score,
};

pub use detector::{
    SystemMetrics,
    BottleneckThresholds,
    TableScanStats,
    IndexUsageStats,
    detect_bottlenecks,
    detect_table_scan_bottleneck,
    detect_missing_index_bottlenecks,
};

pub use normalizer::{normalize_query, query_hash};

pub use reporter::{
    ReportConfig,
    generate_hot_path_report,
    format_hot_path_report_text,
};

pub use suggester::suggest_optimizations;
