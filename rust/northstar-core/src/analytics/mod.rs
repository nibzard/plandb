//! Time-series aggregation and analytics for NorthstarDB.
//!
//! This module provides specialized query operations for aggregating metrics,
//! events, and measurements over time windows, supporting the analytics and
//! monitoring needs of AI agent workflows and observability systems.

pub mod error;
pub mod types;
pub mod window;
pub mod aggregate;
pub mod query;
pub mod calendar;
pub mod visualization;
pub mod usage;
pub mod pattern;
pub mod recommendation;

// Re-exports for convenience
pub use error::{TimeSeriesError, TimeSeriesResult};
pub use types::{
    TimeWindow, WindowType, TumblingWindow, SlidingWindow, SessionWindow, CalendarWindow,
    CalendarUnit, TimeSeriesPoint, AggregateFunction, FillStrategy, TagFilter, FilterOperator,
    TimeSeriesAggregate, TimeSeriesQuery, TimeSeriesQueryResult, GroupBy, MultiSeriesTimeSeriesResult,
    MergeStrategy, TimeUnit,
};
pub use window::{
    generate_time_windows, align_to_calendar, detect_sessions, merge_series, downsample_series,
    compute_rate,
};
pub use aggregate::aggregate_window;
pub use query::{execute_time_series_query, execute_grouped_time_series_query, group_by_tags};

// Visualization re-exports
pub use visualization::{
    // Core types
    VisualizationFormat, ChartType, ChartConfig, DataPoint, DataSeries,
    TimeSeriesData, HistogramBucket, HistogramData, HeatmapData, ColorScale,
    TableData, ColumnDefinition, ColumnType, TableCell, PaginationInfo,
    GaugeData, GaugeThreshold, Trend, TrendDirection,

    // Chart.js types
    ChartJsData, ChartJsDataset, ChartJsOptions, ChartJsPlugins,
    ChartJsLegend, ChartJsTitle, ChartJsTooltip, ChartJsScales,
    ChartJsAxis, ChartJsAxisTitle, ChartJsGrid,

    // Plotly types
    PlotlyData, PlotlyTrace, PlotlyLayout, PlotlyTitle, PlotlyAxis,
    PlotlyAxisTitle, PlotlyConfig, PlotlyLine,

    // Prometheus types
    PrometheusResult, PrometheusSeries,

    // Generators
    generate_chart_js, generate_plotly, generate_csv, generate_histogram,
    generate_heatmap, generate_prometheus_matrix, convert_time_series,
    compute_trend, format_timestamp_millis, apply_theme,

    // Theme and formatting
    ChartTheme, ThemeColors, TimestampFormat,
};

// Usage analytics re-exports
pub use usage::{
    UsageAnalytics, QueryPattern, KeyAccessStats, HotKeyReport, ColdDataReport,
    PerformanceAnomaly, Recommendation, ImpactEstimate, Evidence,
    QueryFingerprint, QueryType, HotKeyClassification, ColdDataClassification,
    AnomalyType, AnomalySeverity, RecommendationType, RecommendationTarget,
    EffortLevel, RecommendationPriority, UsageAnalyticsResult, UsageAnalyticsError,
};
pub use pattern::{PatternAnalyzer, PatternCluster};
pub use recommendation::{RecommendationEngine, RecommendationConfig};
