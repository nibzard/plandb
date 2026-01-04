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
