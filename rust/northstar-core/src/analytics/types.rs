//! Core type definitions for time-series analytics.

use crate::analytics::error::TimeSeriesError;
use std::collections::HashMap;
use std::fmt;
use crate::analytics::TimeSeriesResult as AnalyticsResult;

/// Defines a time interval for aggregation
#[derive(Debug, Clone, PartialEq)]
pub struct TimeWindow {
    /// Window start timestamp (milliseconds since epoch)
    pub start: i64,
    /// Window end timestamp (milliseconds since epoch)
    pub end: i64,
    /// Window length in milliseconds
    pub duration_ms: i64,
}

impl TimeWindow {
    /// Create a new time window
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if end <= start
    pub fn new(start: i64, end: i64) -> AnalyticsResult<Self> {
        if end <= start {
            return Err(TimeSeriesError::InvalidWindow(format!(
                "end ({}) <= start ({})",
                end, start
            )));
        }
        let duration_ms = end - start;
        Ok(Self { start, end, duration_ms })
    }

    /// Check if a timestamp falls within this window
    pub fn contains(&self, timestamp: i64) -> bool {
        timestamp >= self.start && timestamp < self.end
    }

    /// Check if this window overlaps with another
    pub fn overlaps(&self, other: &TimeWindow) -> bool {
        self.start < other.end && other.start < self.end
    }
}

impl fmt::Display for TimeWindow {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}, {})", self.start, self.end)
    }
}

/// Type of time window
#[derive(Debug, Clone, PartialEq)]
pub enum WindowType {
    /// Non-overlapping fixed-size windows
    Tumbling(TumblingWindow),
    /// Overlapping windows that advance by step size
    Sliding(SlidingWindow),
    /// Dynamic windows based on activity gaps
    Session(SessionWindow),
    /// Windows aligned to calendar boundaries
    Calendar(CalendarWindow),
}

/// Fixed-size non-overlapping window configuration
#[derive(Debug, Clone, PartialEq)]
pub struct TumblingWindow {
    /// Window size in milliseconds
    pub size_ms: i64,
    /// Optional offset for window alignment (default: 0)
    pub offset_ms: i64,
}

impl TumblingWindow {
    /// Create a new tumbling window
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if size_ms <= 0 or offset_ms is invalid
    pub fn new(size_ms: i64, offset_ms: i64) -> AnalyticsResult<Self> {
        if size_ms <= 0 {
            return Err(TimeSeriesError::InvalidWindow(
                "size_ms must be positive".to_string(),
            ));
        }
        if offset_ms < 0 || offset_ms >= size_ms {
            return Err(TimeSeriesError::InvalidWindow(format!(
                "offset_ms must be in [0, {}), got {}",
                size_ms, offset_ms
            )));
        }
        Ok(Self { size_ms, offset_ms })
    }
}

/// Overlapping window configuration
#[derive(Debug, Clone, PartialEq)]
pub struct SlidingWindow {
    /// Window size in milliseconds
    pub size_ms: i64,
    /// How much the window advances each step
    pub slide_ms: i64,
    /// Optional offset for alignment (default: 0)
    pub offset_ms: i64,
}

impl SlidingWindow {
    /// Create a new sliding window
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if configuration is invalid
    pub fn new(size_ms: i64, slide_ms: i64, offset_ms: i64) -> AnalyticsResult<Self> {
        if size_ms <= 0 {
            return Err(TimeSeriesError::InvalidWindow(
                "size_ms must be positive".to_string(),
            ));
        }
        if slide_ms <= 0 {
            return Err(TimeSeriesError::InvalidWindow(
                "slide_ms must be positive".to_string(),
            ));
        }
        if slide_ms > size_ms {
            return Err(TimeSeriesError::InvalidWindow(format!(
                "slide_ms ({}) must be <= size_ms ({})",
                slide_ms, size_ms
            )));
        }
        if offset_ms < 0 || offset_ms >= size_ms {
            return Err(TimeSeriesError::InvalidWindow(format!(
                "offset_ms must be in [0, {}), got {}",
                size_ms, offset_ms
            )));
        }
        Ok(Self {
            size_ms,
            slide_ms,
            offset_ms,
        })
    }
}

/// Dynamic window based on activity gaps
#[derive(Debug, Clone, PartialEq)]
pub struct SessionWindow {
    /// Maximum gap between events before starting new session
    pub gap_ms: i64,
    /// Optional maximum session duration
    pub max_duration_ms: Option<i64>,
    /// Minimum events required to form a session
    pub min_events: usize,
}

impl SessionWindow {
    /// Create a new session window
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if configuration is invalid
    pub fn new(gap_ms: i64, max_duration_ms: Option<i64>, min_events: usize) -> AnalyticsResult<Self> {
        if gap_ms <= 0 {
            return Err(TimeSeriesError::InvalidWindow(
                "gap_ms must be positive".to_string(),
            ));
        }
        if let Some(max) = max_duration_ms {
            if max <= 0 {
                return Err(TimeSeriesError::InvalidWindow(
                    "max_duration_ms must be positive".to_string(),
                ));
            }
        }
        if min_events < 1 {
            return Err(TimeSeriesError::InvalidWindow(
                "min_events must be at least 1".to_string(),
            ));
        }
        Ok(Self {
            gap_ms,
            max_duration_ms,
            min_events,
        })
    }
}

/// Window aligned to calendar time boundaries
#[derive(Debug, Clone, PartialEq)]
pub struct CalendarWindow {
    /// Time unit for windows
    pub unit: CalendarUnit,
    /// Number of units per window
    pub count: usize,
    /// IANA timezone name (e.g., "UTC", "America/New_York")
    pub timezone: String,
}

impl CalendarWindow {
    /// Create a new calendar window
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if count < 1
    pub fn new(unit: CalendarUnit, count: usize, timezone: String) -> AnalyticsResult<Self> {
        if count < 1 {
            return Err(TimeSeriesError::InvalidWindow(
                "count must be at least 1".to_string(),
            ));
        }
        Ok(Self { unit, count, timezone })
    }
}

/// Calendar time unit
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CalendarUnit {
    /// Minute-aligned windows
    Minute,
    /// Hour-aligned windows
    Hour,
    /// Day-aligned windows (midnight)
    Day,
    /// Week-aligned windows (Monday)
    Week,
    /// Month-aligned windows (first of month)
    Month,
    /// Quarter-aligned windows (Jan 1, Apr 1, Jul 1, Oct 1)
    Quarter,
    /// Year-aligned windows (Jan 1)
    Year,
}

/// Single time-series data point
#[derive(Debug, Clone, PartialEq)]
pub struct TimeSeriesPoint {
    /// Timestamp in milliseconds since epoch
    pub timestamp: i64,
    /// Numeric value
    pub value: f64,
    /// Optional dimensional tags
    pub tags: HashMap<String, String>,
}

impl TimeSeriesPoint {
    /// Create a new time-series point
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if value is not finite
    pub fn new(timestamp: i64, value: f64) -> AnalyticsResult<Self> {
        if !value.is_finite() {
            return Err(TimeSeriesError::InvalidWindow(
                "value must be finite".to_string(),
            ));
        }
        Ok(Self {
            timestamp,
            value,
            tags: HashMap::new(),
        })
    }

    /// Create a new time-series point with tags
    pub fn with_tags(timestamp: i64, value: f64, tags: HashMap<String, String>) -> AnalyticsResult<Self> {
        if !value.is_finite() {
            return Err(TimeSeriesError::InvalidWindow(
                "value must be finite".to_string(),
            ));
        }
        Ok(Self {
            timestamp,
            value,
            tags,
        })
    }

    /// Add a tag to this point
    pub fn add_tag(&mut self, key: String, value: String) {
        self.tags.insert(key, value);
    }
}

impl PartialOrd for TimeSeriesPoint {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.timestamp.cmp(&other.timestamp))
    }
}

/// Type of aggregation to apply
#[derive(Debug, Clone, PartialEq)]
pub enum AggregateFunction {
    /// Number of points in window
    Count,
    /// Sum of values
    Sum,
    /// Average (mean) of values
    Avg,
    /// Minimum value
    Min,
    /// Maximum value
    Max,
    /// First value in window
    First,
    /// Last value in window
    Last,
    /// Standard deviation
    StdDev,
    /// Statistical variance
    Variance,
    /// Value at percentile (0.0 to 1.0)
    Percentile(f64),
    /// Rate of change (values per second)
    Rate,
    /// Difference between last and first value
    Delta,
    /// Moving average over N periods
    MovingAverage(usize),
}

/// Strategy for handling empty time windows
#[derive(Debug, Clone, PartialEq)]
pub enum FillStrategy {
    /// Skip empty windows (don't emit results)
    None,
    /// Use zero as value
    Zero,
    /// Use NaN as value
    Null,
    /// Use previous window's value
    Previous,
    /// Interpolate between adjacent windows
    Linear,
    /// Use specified constant value
    Fixed(f64),
}

/// Tag comparison operator
#[derive(Debug, Clone, PartialEq)]
pub enum FilterOperator {
    /// Exact match
    Equal,
    /// Not equal
    NotEqual,
    /// Regex match
    Matches,
    /// String contains substring
    Contains,
    /// String starts with prefix
    StartsWith,
    /// String ends with suffix
    EndsWith,
}

/// Filter condition on tags
#[derive(Debug, Clone, PartialEq)]
pub struct TagFilter {
    /// Tag to filter on
    pub tag_name: String,
    /// Comparison operator
    pub operator: FilterOperator,
    /// Value to compare against
    pub value: String,
}

impl TagFilter {
    /// Create a new tag filter
    pub fn new(tag_name: String, operator: FilterOperator, value: String) -> Self {
        Self {
            tag_name,
            operator,
            value,
        }
    }

    /// Check if a point matches this filter
    pub fn matches(&self, point: &TimeSeriesPoint) -> bool {
        let tag_value = match point.tags.get(&self.tag_name) {
            Some(v) => v,
            None => return false,
        };

        match &self.operator {
            FilterOperator::Equal => tag_value == &self.value,
            FilterOperator::NotEqual => tag_value != &self.value,
            FilterOperator::Contains => tag_value.contains(&self.value),
            FilterOperator::StartsWith => tag_value.starts_with(&self.value),
            FilterOperator::EndsWith => tag_value.ends_with(&self.value),
            FilterOperator::Matches => {
                regex::Regex::new(&self.value)
                    .map(|re| re.is_match(tag_value))
                    .unwrap_or(false)
            }
        }
    }
}

/// Result of time-series aggregation
#[derive(Debug, Clone, PartialEq)]
pub struct TimeSeriesAggregate {
    /// Time window for this aggregate
    pub window: TimeWindow,
    /// Function applied
    pub function: AggregateFunction,
    /// Aggregated value
    pub value: f64,
    /// Number of points aggregated
    pub count: usize,
    /// Tags from source points
    pub tags: HashMap<String, String>,
}

/// Query specification for time-series aggregation
#[derive(Debug, Clone, PartialEq)]
pub struct TimeSeriesQuery {
    /// Query start time (inclusive)
    pub start_time: i64,
    /// Query end time (exclusive)
    pub end_time: i64,
    /// Window configuration
    pub window: WindowType,
    /// Aggregates to compute
    pub functions: Vec<AggregateFunction>,
    /// Optional tag-based filtering
    pub tag_filters: Vec<TagFilter>,
    /// Maximum results to return
    pub limit: Option<usize>,
    /// How to handle empty windows
    pub fill_strategy: FillStrategy,
}

impl TimeSeriesQuery {
    /// Create a new time-series query
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidTimeRange` if end_time <= start_time
    pub fn new(
        start_time: i64,
        end_time: i64,
        window: WindowType,
        functions: Vec<AggregateFunction>,
    ) -> AnalyticsResult<Self> {
        if end_time <= start_time {
            return Err(TimeSeriesError::InvalidTimeRange {
                start: start_time,
                end: end_time,
            });
        }
        if functions.is_empty() {
            return Err(TimeSeriesError::InvalidWindow(
                "functions must not be empty".to_string(),
            ));
        }
        Ok(Self {
            start_time,
            end_time,
            window,
            functions,
            tag_filters: Vec::new(),
            limit: None,
            fill_strategy: FillStrategy::None,
        })
    }

    /// Add a tag filter to the query
    pub fn with_tag_filter(mut self, filter: TagFilter) -> Self {
        self.tag_filters.push(filter);
        self
    }

    /// Set the limit on results
    pub fn with_limit(mut self, limit: usize) -> Self {
        self.limit = Some(limit);
        self
    }

    /// Set the fill strategy
    pub fn with_fill_strategy(mut self, strategy: FillStrategy) -> Self {
        self.fill_strategy = strategy;
        self
    }
}

/// Complete query result with metadata
#[derive(Debug, Clone, PartialEq)]
pub struct TimeSeriesQueryResult {
    /// Aggregated results
    pub aggregates: Vec<TimeSeriesAggregate>,
    /// Total source points processed
    pub total_points: usize,
    /// Number of time windows
    pub windows_generated: usize,
    /// Number of windows with no data
    pub empty_windows: usize,
    /// Original query for reference
    pub query: TimeSeriesQuery,
}

/// Grouping configuration for multi-series aggregation
#[derive(Debug, Clone, PartialEq)]
pub struct GroupBy {
    /// Tag names to group by
    pub tags: Vec<String>,
    /// If true, group by all tag combinations
    pub all: bool,
}

impl GroupBy {
    /// Create a new group by configuration
    pub fn new(tags: Vec<String>, all: bool) -> AnalyticsResult<Self> {
        if tags.is_empty() && !all {
            return Err(TimeSeriesError::InvalidGroupBy(
                "tags must be non-empty or all must be true".to_string(),
            ));
        }
        Ok(Self { tags, all })
    }
}

/// Result of grouped time-series query
#[derive(Debug, Clone, PartialEq)]
pub struct MultiSeriesTimeSeriesResult {
    /// Results by group key
    pub series: HashMap<String, TimeSeriesQueryResult>,
    /// Grouping configuration applied
    pub group_by: GroupBy,
}

/// Strategy for merging overlapping time-series points
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MergeStrategy {
    /// Keep first encountered value
    First,
    /// Keep last encountered value
    Last,
    /// Average of all values
    Avg,
    /// Sum of all values
    Sum,
    /// Minimum of all values
    Min,
    /// Maximum of all values
    Max,
}

/// Time unit for rate calculations
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TimeUnit {
    /// Per second rate
    Second,
    /// Per minute rate
    Minute,
    /// Per hour rate
    Hour,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_time_window_creation() {
        let window = TimeWindow::new(0, 1000).unwrap();
        assert_eq!(window.start, 0);
        assert_eq!(window.end, 1000);
        assert_eq!(window.duration_ms, 1000);
    }

    #[test]
    fn test_time_window_invalid() {
        let result = TimeWindow::new(1000, 0);
        assert!(result.is_err());
    }

    #[test]
    fn test_time_window_contains() {
        let window = TimeWindow::new(0, 1000).unwrap();
        assert!(window.contains(500));
        assert!(!window.contains(1000));
        assert!(!window.contains(-1));
    }

    #[test]
    fn test_time_window_overlaps() {
        let w1 = TimeWindow::new(0, 1000).unwrap();
        let w2 = TimeWindow::new(500, 1500).unwrap();
        let w3 = TimeWindow::new(1000, 2000).unwrap();

        assert!(w1.overlaps(&w2));
        assert!(!w1.overlaps(&w3));
    }

    #[test]
    fn test_tumbling_window_creation() {
        let window = TumblingWindow::new(60000, 0).unwrap();
        assert_eq!(window.size_ms, 60000);
        assert_eq!(window.offset_ms, 0);
    }

    #[test]
    fn test_tumbling_window_invalid_size() {
        let result = TumblingWindow::new(-1, 0);
        assert!(result.is_err());
    }

    #[test]
    fn test_tumbling_window_invalid_offset() {
        let result = TumblingWindow::new(60000, 60000);
        assert!(result.is_err());
    }

    #[test]
    fn test_sliding_window_creation() {
        let window = SlidingWindow::new(300000, 60000, 0).unwrap();
        assert_eq!(window.size_ms, 300000);
        assert_eq!(window.slide_ms, 60000);
    }

    #[test]
    fn test_sliding_window_invalid_slide() {
        let result = SlidingWindow::new(300000, 300001, 0);
        assert!(result.is_err());
    }

    #[test]
    fn test_session_window_creation() {
        let window = SessionWindow::new(300000, Some(3600000), 2).unwrap();
        assert_eq!(window.gap_ms, 300000);
        assert_eq!(window.max_duration_ms, Some(3600000));
        assert_eq!(window.min_events, 2);
    }

    #[test]
    fn test_calendar_window_creation() {
        let window = CalendarWindow::new(CalendarUnit::Hour, 1, "UTC".to_string()).unwrap();
        assert_eq!(window.unit, CalendarUnit::Hour);
        assert_eq!(window.count, 1);
    }

    #[test]
    fn test_timeseries_point_creation() {
        let point = TimeSeriesPoint::new(1000, 42.0).unwrap();
        assert_eq!(point.timestamp, 1000);
        assert_eq!(point.value, 42.0);
    }

    #[test]
    fn test_timeseries_point_invalid_value() {
        let result = TimeSeriesPoint::new(1000, f64::NAN);
        assert!(result.is_err());
    }

    #[test]
    fn test_timeseries_point_with_tags() {
        let mut tags = HashMap::new();
        tags.insert("host".to_string(), "server1".to_string());
        let point = TimeSeriesPoint::with_tags(1000, 42.0, tags).unwrap();
        assert_eq!(point.tags.get("host"), Some(&"server1".to_string()));
    }

    #[test]
    fn test_tag_filter_equal() {
        let filter = TagFilter::new("host".to_string(), FilterOperator::Equal, "server1".to_string());

        let mut tags = HashMap::new();
        tags.insert("host".to_string(), "server1".to_string());
        let point = TimeSeriesPoint::with_tags(1000, 42.0, tags).unwrap();

        assert!(filter.matches(&point));
    }

    #[test]
    fn test_tag_filter_contains() {
        let filter = TagFilter::new("host".to_string(), FilterOperator::Contains, "server".to_string());

        let mut tags = HashMap::new();
        tags.insert("host".to_string(), "server1".to_string());
        let point = TimeSeriesPoint::with_tags(1000, 42.0, tags).unwrap();

        assert!(filter.matches(&point));
    }

    #[test]
    fn test_query_creation() {
        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let functions = vec![AggregateFunction::Count];
        let query = TimeSeriesQuery::new(0, 3600000, window, functions).unwrap();

        assert_eq!(query.start_time, 0);
        assert_eq!(query.end_time, 3600000);
    }

    #[test]
    fn test_query_invalid_range() {
        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let functions = vec![AggregateFunction::Count];
        let result = TimeSeriesQuery::new(3600000, 0, window, functions);

        assert!(result.is_err());
    }

    #[test]
    fn test_query_with_filters() {
        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let functions = vec![AggregateFunction::Count];
        let query = TimeSeriesQuery::new(0, 3600000, window, functions)
            .unwrap()
            .with_tag_filter(TagFilter::new("host".to_string(), FilterOperator::Equal, "server1".to_string()))
            .with_limit(100)
            .with_fill_strategy(FillStrategy::Zero);

        assert_eq!(query.tag_filters.len(), 1);
        assert_eq!(query.limit, Some(100));
        assert_eq!(query.fill_strategy, FillStrategy::Zero);
    }

    #[test]
    fn test_group_by_creation() {
        let group_by = GroupBy::new(vec!["host".to_string(), "region".to_string()], false).unwrap();
        assert_eq!(group_by.tags.len(), 2);
        assert!(!group_by.all);
    }

    #[test]
    fn test_group_by_all_tags() {
        let group_by = GroupBy::new(vec![], true).unwrap();
        assert!(group_by.tags.is_empty());
        assert!(group_by.all);
    }

    #[test]
    fn test_group_by_invalid() {
        let result = GroupBy::new(vec![], false);
        assert!(result.is_err());
    }
}
