# Time-Series Aggregation Queries

## Purpose

Time-series aggregation queries enable efficient analysis of temporal data patterns in NorthstarDB. This component provides specialized query operations for aggregating metrics, events, and measurements over time windows, supporting the analytics and monitoring needs of AI agent workflows and observability systems.

Time-series data differs from traditional database queries because it requires window-based operations, temporal grouping, and efficient handling of high-volume timestamped data. This specification defines the types and operations for time-series aggregation without requiring external time-series databases.

## Core Concepts

### Time Window

A time window is a discrete interval used for grouping temporal data. Windows can be fixed-size (tumbling) or overlapping (sliding). Each window produces one aggregated result.

### Temporal Grouping

Unlike standard GROUP BY operations which group by value, temporal grouping organizes data by time intervals. This requires efficient temporal indexing and window-aware aggregation.

### Aggregate Functions

Time-series aggregates compute summary statistics over windows: count, sum, average, min, max, percentiles, and specialized time-series functions like rate calculation and moving averages.

## Types

### TimeWindow

**Description**: Defines a time interval for aggregation

**Fields**:
- `start: i64` - Window start timestamp (milliseconds since epoch)
- `end: i64` - Window end timestamp (milliseconds since epoch)
- `duration_ms: i64` - Window length in milliseconds

**Invariants**:
- `end > start`
- `duration_ms == end - start`
- `duration_ms > 0`

**Size**: 24 bytes (three 64-bit integers)

### WindowType

**Description**: Type of time window

**Variants**:
- `Tumbling` - Non-overlapping fixed-size windows
- `Sliding` - Overlapping windows that advance by step size
- `Session` - Dynamic windows based on activity gaps
- `Calendar` - Windows aligned to calendar boundaries (hour, day, week)

### TumblingWindow

**Description**: Fixed-size non-overlapping window configuration

**Fields**:
- `size_ms: i64` - Window size in milliseconds
- `offset_ms: i64` - Optional offset for window alignment (default: 0)

**Invariants**:
- `size_ms > 0`
- `offset_ms >= 0`
- `offset_ms < size_ms`

**Examples**:
- 5-minute windows: `size_ms = 300000`
- Hourly windows: `size_ms = 3600000`

### SlidingWindow

**Description**: Overlapping window configuration

**Fields**:
- `size_ms: i64` - Window size in milliseconds
- `slide_ms: i64` - How much the window advances each step
- `offset_ms: i64` - Optional offset for alignment (default: 0)

**Invariants**:
- `size_ms > 0`
- `slide_ms > 0`
- `slide_ms <= size_ms`
- `offset_ms >= 0`
- `offset_ms < size_ms`

**Examples**:
- 5-minute windows sliding every 1 minute: `size_ms = 300000`, `slide_ms = 60000`

### SessionWindow

**Description**: Dynamic window based on activity gaps

**Fields**:
- `gap_ms: i64` - Maximum gap between events before starting new session
- `max_duration_ms: Option<i64>` - Optional maximum session duration
- `min_events: usize` - Minimum events required to form a session

**Invariants**:
- `gap_ms > 0`
- `max_duration_ms` is None or `> 0`
- `min_events >= 1`

### CalendarWindow

**Description**: Window aligned to calendar time boundaries

**Fields**:
- `unit: CalendarUnit` - Time unit for windows
- `count: usize` - Number of units per window
- `timezone: String` - IANA timezone name (e.g., "UTC", "America/New_York")

**Invariants**:
- `count >= 1`
- `timezone` is valid IANA timezone

### CalendarUnit

**Description**: Calendar time unit

**Variants**:
- `Minute` - Minute-aligned windows
- `Hour` - Hour-aligned windows
- `Day` - Day-aligned windows (midnight)
- `Week` - Week-aligned windows (Monday or Sunday based on locale)
- `Month` - Month-aligned windows (first of month)
- `Quarter` - Quarter-aligned windows (Jan 1, Apr 1, Jul 1, Oct 1)
- `Year` - Year-aligned windows (Jan 1)

### TimeSeriesPoint

**Description**: Single time-series data point

**Fields**:
- `timestamp: i64` - Timestamp in milliseconds since epoch
- `value: f64` - Numeric value
- `tags: HashMap<String, String>` - Optional dimensional tags

**Invariants**:
- `value` is finite (not NaN or infinity)
- Timestamp values should be monotonically increasing for insertion efficiency

### AggregateFunction

**Description**: Type of aggregation to apply

**Variants**:
- `Count` - Number of points in window
- `Sum` - Sum of values
- `Avg` - Average (mean) of values
- `Min` - Minimum value
- `Max` - Maximum value
- `First` - First value in window
- `Last` - Last value in window
- `StdDev` - Standard deviation
- `Variance` - Statistical variance
- `Percentile(f64)` - Value at percentile (0.0 to 1.0)
- `Rate` - Rate of change (values per second)
- `Delta` - Difference between last and first value
- `MovingAverage(usize)` - Moving average over N periods

### TimeSeriesAggregate

**Description**: Result of time-series aggregation

**Fields**:
- `window: TimeWindow` - Time window for this aggregate
- `function: AggregateFunction` - Function applied
- `value: f64` - Aggregated value
- `count: usize` - Number of points aggregated
- `tags: HashMap<String, String>` - Tags from source points

**Invariants**:
- `count >= 1`
- `value` is finite or NaN for empty windows

### TimeSeriesQuery

**Description**: Query specification for time-series aggregation

**Fields**:
- `start_time: i64` - Query start time (inclusive)
- `end_time: i64` - Query end time (exclusive)
- `window: WindowType` - Window configuration
- `functions: Vec<AggregateFunction>` - Aggregates to compute
- `tag_filters: Vec<TagFilter>` - Optional tag-based filtering
- `limit: Option<usize>` - Maximum results to return
- `fill_strategy: FillStrategy` - How to handle empty windows

**Invariants**:
- `end_time > start_time`
- `functions` is non-empty
- `limit` is None or `> 0`

### TagFilter

**Description**: Filter condition on tags

**Fields**:
- `tag_name: String` - Tag to filter on
- `operator: FilterOperator` - Comparison operator
- `value: String` - Value to compare against

### FilterOperator

**Description**: Tag comparison operator

**Variants**:
- `Equal` - Exact match
- `NotEqual` - Not equal
- `Matches` - Regex match
- `Contains` - String contains substring
- `StartsWith` - String starts with prefix
- `EndsWith` - String ends with suffix

### FillStrategy

**Description**: Strategy for handling empty time windows

**Variants**:
- `None` - Skip empty windows (don't emit results)
- `Zero` - Use zero as value
- `Null` - Use NaN as value
- `Previous` - Use previous window's value
- `Linear` - Interpolate between adjacent windows
- `Fixed(f64)` - Use specified constant value

### TimeSeriesResult

**Description**: Complete query result with metadata

**Fields**:
- `aggregates: Vec<TimeSeriesAggregate>` - Aggregated results
- `total_points: usize` - Total source points processed
- `windows_generated: usize` - Number of time windows
- `empty_windows: usize` - Number of windows with no data
- `query: TimeSeriesQuery` - Original query for reference

**Invariants**:
- `windows_generated >= empty_windows`
- `aggregates.len()` depends on FillStrategy

### GroupBy

**Description**: Grouping configuration for multi-series aggregation

**Fields**:
- `tags: Vec<String>` - Tag names to group by
- `all: bool` - If true, group by all tag combinations

**Invariants**:
- `tags` is non-empty or `all` is true

### MultiSeriesTimeSeriesResult

**Description**: Result of grouped time-series query

**Fields**:
- `series: HashMap<String, TimeSeriesResult>` - Results by group key
- `group_by: GroupBy` - Grouping configuration applied

**Invariants**:
- `series` is non-empty if any data matched query
- Group keys are formatted as "tag1=value1,tag2=value2"

## Functions

### execute_time_series_query(query: TimeSeriesQuery, data: &[TimeSeriesPoint]) -> Result<TimeSeriesResult, Error>

**Purpose**: Execute time-series aggregation query on data points

**Parameters**:
- `query: TimeSeriesQuery` - Query specification with window and aggregates
- `data: &[TimeSeriesPoint]` - Source time-series data points

**Returns**: `TimeSeriesResult` - Aggregated results with metadata

**Algorithm**:
1. Validate query parameters (time range, window configuration)
2. Filter data points by time range and tag filters
3. Generate time windows based on window type and configuration
4. For each time window:
   a. Collect points falling within window bounds
   b. Apply each aggregate function to points in window
   c. Apply fill strategy if window is empty
   d. Store TimeSeriesAggregate result
5. Compute metadata (total points, windows, empty windows)
6. Return TimeSeriesResult with aggregates and metadata

**Error Conditions**:
- `InvalidTimeRange`: When end_time <= start_time
- `InvalidWindow`: When window configuration is invalid
- `InvalidTagFilter`: When tag filter references non-existent tags

**Concurrency**: Read-only access to data, thread-safe for parallel queries

### generate_time_windows(start: i64, end: i64, window: WindowType) -> Vec<TimeWindow>

**Purpose**: Generate sequence of time windows for aggregation

**Parameters**:
- `start: i64` - Range start timestamp
- `end: i64` - Range end timestamp
- `window: WindowType` - Window configuration

**Returns**: `Vec<TimeWindow>` - Ordered list of non-overlapping windows

**Algorithm**:
1. Match on WindowType variant:
   - Tumbling: Generate fixed-size windows from start to end
   - Sliding: Generate windows starting at start, advancing by slide_ms
   - Session: Return empty (windows determined dynamically from data)
   - Calendar: Generate windows aligned to calendar boundaries
2. For Tumbling: First window starts at start aligned to offset
3. For Sliding: Generate all windows from start, stepping by slide_ms
4. For Calendar: Use timezone-aware calendar arithmetic
5. Ensure last window does not exceed end time
6. Return ordered list of windows

**Error Conditions**: None (returns empty Vec if invalid range)

**Concurrency**: Pure function, thread-safe

### aggregate_window(points: &[TimeSeriesPoint], function: AggregateFunction) -> f64

**Purpose**: Compute single aggregate value over points in a window

**Parameters**:
- `points: &[TimeSeriesPoint]` - Points in time window
- `function: AggregateFunction` - Aggregate to compute

**Returns**: `f64` - Aggregated value (or NaN if empty window)

**Algorithm**:
1. If points is empty, return NaN (caller applies fill strategy)
2. Extract values from points into slice
3. Match on AggregateFunction variant:
   - Count: Return points.len() as f64
   - Sum: Return sum of values
   - Avg: Return sum / count
   - Min/Max: Return minimum or maximum value
   - First/Last: Return first or last point's value
   - StdDev: Compute standard deviation using Welford's algorithm
   - Variance: Return square of standard deviation
   - Percentile(p): Sort values, return value at index p * len
   - Rate: Compute (last - first) / time_duration in seconds
   - Delta: Return last - first
   - MovingAverage(n): Compute average of last n values
4. Return computed value

**Error Conditions**: None (returns NaN for unsupported operations)

**Concurrency**: Pure function, thread-safe

### apply_fill_strategy(previous_value: Option<f64>, strategy: FillStrategy) -> f64

**Purpose**: Determine aggregate value for empty window using fill strategy

**Parameters**:
- `previous_value: Option<f64>` - Previous window's value (if available)
- `strategy: FillStrategy` - Fill strategy to apply

**Returns**: `f64` - Value to use for empty window

**Algorithm**:
1. Match on FillStrategy variant:
   - None: Return NaN (caller will skip window)
   - Zero: Return 0.0
   - Null: Return NaN
   - Previous: Return previous_value.unwrap_or(NaN)
   - Linear: Return previous_value.unwrap_or(NaN) (interpolation requires next value)
   - Fixed(v): Return v
2. Return computed value

**Error Conditions**: None

**Concurrency**: Pure function, thread-safe

### group_by_tags(query: TimeSeriesQuery, data: &[TimeSeriesPoint], group_by: GroupBy) -> Result<HashMap<String, Vec<TimeSeriesPoint>>, Error>

**Purpose**: Group data points by tag combinations for multi-series aggregation

**Parameters**:
- `query: TimeSeriesQuery` - Query specification
- `data: &[TimeSeriesPoint]` - Source data points
- `group_by: GroupBy` - Grouping configuration

**Returns**: `HashMap<String, Vec<TimeSeriesPoint>>` - Grouped data by series key

**Algorithm**:
1. Initialize empty HashMap for grouped results
2. For each data point:
   a. Extract tag values specified in group_by.tags
   b. Format group key as "tag1=value1,tag2=value2"
   c. Push point to corresponding Vec in HashMap
3. Return grouped HashMap
4. If group_by.all is true, use all tags from all points

**Error Conditions**: None (returns empty HashMap if no matching data)

**Concurrency**: Read-only access to data, thread-safe

### execute_grouped_time_series_query(query: TimeSeriesQuery, data: &[TimeSeriesPoint], group_by: GroupBy) -> Result<MultiSeriesTimeSeriesResult, Error>

**Purpose**: Execute time-series query with grouping by tag dimensions

**Parameters**:
- `query: TimeSeriesQuery` - Query specification
- `data: &[TimeSeriesPoint]` - Source data points
- `group_by: GroupBy` - Grouping configuration

**Returns**: `MultiSeriesTimeSeriesResult` - Grouped results by series

**Algorithm**:
1. Group data points by tags using group_by_tags()
2. Initialize empty HashMap for series results
3. For each (group_key, group_data) in grouped data:
   a. Execute time-series query on group_data
   b. Store result in series HashMap under group_key
3. Return MultiSeriesTimeSeriesResult with grouped results

**Error Conditions**:
- `InvalidGroupBy`: When group_by.tags references non-existent tags

**Concurrency**: Each group query is independent, can be parallelized

### downsample_series(data: &[TimeSeriesPoint], target_interval_ms: i64, function: AggregateFunction) -> Vec<TimeSeriesPoint>

**Purpose**: Downsample time-series to lower resolution by aggregating points

**Parameters**:
- `data: &[TimeSeriesPoint]` - Original high-resolution data
- `target_interval_ms: i64` - Target time interval between downsampled points
- `function: AggregateFunction` - Aggregation function for downsampling

**Returns**: `Vec<TimeSeriesPoint>` - Downsampled time-series

**Algorithm**:
1. Determine time range from first and last points
2. Generate tumbling windows of size target_interval_ms
3. For each window, aggregate points using aggregate_window()
4. Create TimeSeriesPoint with window timestamp (end of window) and aggregated value
5. Preserve tags from original points (merge if conflicting)
6. Return downsampled points

**Error Conditions**: None (returns empty Vec if input is empty)

**Concurrency**: Read-only access to data, thread-safe

### compute_rate(data: &[TimeSeriesPoint], unit: TimeUnit) -> Vec<TimeSeriesPoint>

**Purpose**: Compute rate of change (per second/minute/hour) for counter metrics

**Parameters**:
- `data: &[TimeSeriesPoint]` - Counter values over time
- `unit: TimeUnit` - Time unit for rate (Second, Minute, Hour)

**Returns**: `Vec<TimeSeriesPoint>` - Rate values with same timestamps

**Algorithm**:
1. Initialize empty result Vec
2. For each adjacent pair of points (prev, current):
   a. Compute value delta: current.value - prev.value
   b. Compute time delta: current.timestamp - prev.timestamp (milliseconds)
   c. Handle counter resets: if delta < 0, assume counter reset
   d. Compute rate: value_delta / (time_delta / 1000) for per-second rate
   e. Convert to target time unit
   f. Create point with current.timestamp and computed rate
3. Return rate points

**Error Conditions**: None (returns empty Vec if fewer than 2 points)

**Concurrency**: Read-only access to data, thread-safe

### TimeUnit

**Description**: Time unit for rate calculations

**Variants**:
- `Second` - Per second rate
- `Minute` - Per minute rate
- `Hour` - Per hour rate

### align_to_calendar(timestamp: i64, unit: CalendarUnit, timezone: &str) -> Result<i64, Error>

**Purpose**: Align timestamp to calendar boundary (floor to unit)

**Parameters**:
- `timestamp: i64` - Input timestamp in milliseconds
- `unit: CalendarUnit` - Calendar unit to align to
- `timezone: &str` - IANA timezone name

**Returns**: `i64` - Aligned timestamp (floored to calendar boundary)

**Algorithm**:
1. Parse timezone string to timezone handle
2. Convert timestamp to timezone-aware datetime
3. Match on CalendarUnit:
   - Minute: Floor to minute boundary (seconds = 0)
   - Hour: Floor to hour boundary (minutes = 0, seconds = 0)
   - Day: Floor to day boundary (hours = 0, midnight)
   - Week: Floor to week start (Monday or Sunday locale-dependent)
   - Month: Floor to month start (day = 1)
   - Quarter: Floor to quarter start (month = 1, 4, 7, or 10)
   - Year: Floor to year start (month = 1, day = 1)
4. Convert aligned datetime back to timestamp
5. Return aligned timestamp

**Error Conditions**:
- `InvalidTimezone`: When timezone string is not valid IANA timezone

**Concurrency**: Pure function with timezone parsing, thread-safe for cached timezone handles

### detect_sessions(data: &[TimeSeriesPoint], gap_ms: i64) -> Vec<Vec<TimeSeriesPoint>>

**Purpose**: Detect sessions in time-series based on activity gaps

**Parameters**:
- `data: &[TimeSeriesPoint]` - Time-ordered time-series points
- `gap_ms: i64` - Maximum gap between points in same session

**Returns**: `Vec<Vec<TimeSeriesPoint>>` - Groups of points by session

**Algorithm**:
1. If data is empty, return empty Vec
2. Initialize sessions Vec with first session containing first point
3. Initialize last_timestamp with first point's timestamp
4. For each subsequent point in data:
   a. Compute gap: point.timestamp - last_timestamp
   b. If gap > gap_ms, start new session
   c. Add point to current session
   d. Update last_timestamp
5. Return sessions

**Error Conditions**: None (returns single session if no gaps)

**Concurrency**: Read-only access to data, thread-safe

### merge_series(series: &[Vec<TimeSeriesPoint>], merge_strategy: MergeStrategy) -> Vec<TimeSeriesPoint>

**Purpose**: Merge multiple time-series into single series

**Parameters**:
- `series: &[Vec<TimeSeriesPoint>]` - Multiple time-series to merge
- `merge_strategy: MergeStrategy` - How to combine overlapping points

**Returns**: `Vec<TimeSeriesPoint>` - Merged time-series

**Algorithm**:
1. Collect all points from all series into single Vec
2. Sort by timestamp
3. For overlapping timestamps, apply merge_strategy:
   - First: Keep first value
   - Last: Keep last value
   - Avg: Use average of values
   - Sum: Sum all values
   - Min: Use minimum value
   - Max: Use maximum value
4. Return merged, sorted points

**Error Conditions**: None (returns empty Vec if all inputs empty)

**Concurrency**: Read-only access to data, thread-safe

### MergeStrategy

**Description**: Strategy for merging overlapping time-series points

**Variants**:
- `First` - Keep first encountered value
- `Last` - Keep last encountered value
- `Avg` - Average of all values
- `Sum` - Sum of all values
- `Min` - Minimum of all values
- `Max` - Maximum of all values

## Invariants

- Time windows must be non-overlapping for Tumbling windows
- Sliding windows may overlap, step size must be positive
- Session windows require at least one point to form
- Calendar windows must align to actual calendar boundaries
- Aggregate functions must return finite values or NaN for empty windows
- Tag filters are AND-combined (all must match)
- Group keys must uniquely identify a series combination
- Downsampled series must preserve time monotonicity

## Dependencies

- **Uses**: Core types (Lsn, PageId), B+Tree for temporal indexing, HashMap for tag storage
- **Used by**: Visualization generators, anomaly detection, monitoring systems

## Rust Implementation Guidance

### Module Structure

The time-series aggregation module should be organized as follows:

```
northstar-core/src/timeseries/
  mod.rs              - Public API exports
  types.rs            - Core type definitions
  window.rs           - Window generation and manipulation
  aggregate.rs        - Aggregate function implementations
  query.rs            - Query execution engine
  group.rs            - Grouping and multi-series operations
  calendar.rs         - Calendar-aligned window utilities
  session.rs          - Session detection logic
```

### Type Definitions

- **TimeSeriesPoint**: Struct with timestamp, value, and HashMap<String, String> for tags
- **TimeWindow**: Struct with start, end, duration_ms fields (derive Debug, Clone, PartialEq)
- **WindowType**: Enum with variants for each window type
- **AggregateFunction**: Enum with variants for each aggregate (Percentile variant holds f64)
- **FillStrategy**: Enum with variants (Fixed variant holds f64 value)
- **TagFilter**: Struct with tag_name, operator, value fields
- **GroupBy**: Struct with tags Vec and all boolean flag

### Key Implementation Patterns

1. **Window Generation**: Use iterator-based approach for generating time windows
2. **Aggregate Computation**: Use match on AggregateFunction for dispatch
3. **Tag Grouping**: Use HashMap with formatted string keys for group identification
4. **Calendar Alignment**: Use chrono crate for timezone-aware datetime operations
5. **Session Detection**: Single-pass algorithm with gap threshold comparison

### Concurrency Model

- **Query Execution**: Read-only access to data, can parallelize multi-series queries
- **Stateless**: All functions are pure or read-only, no shared mutable state
- **Thread-Safe**: TimeSeriesPoint and query types can be shared across threads
- **Parallel Aggregation**: Each time window can be aggregated independently

### Performance Considerations

1. **Window Generation**: Pre-allocate Vec with capacity based on estimated window count
2. **Tag Filtering**: Filter early before expensive aggregation operations
3. **Grouping**: Use HashMap with formatted keys for O(1) group lookup
4. **Sorting**: Use stable sort for time-series to preserve insertion order for ties
5. **Downsampling**: Use tumbling window approach for O(n) complexity

### Key Decisions

- **Time Representation**: Use i64 milliseconds since epoch for compatibility with standard libraries
- **Tag Storage**: HashMap<String, String> for flexibility (schema-less dimensions)
- **Fill Strategy**: Enum variant approach covers common use cases
- **Grouping Keys**: Formatted string "tag=value" pairs for readability and debugging
- **Calendar Operations**: Defer to chrono crate for timezone and calendar accuracy

### External Dependencies

- **chrono**: For timezone-aware calendar window generation and alignment
- **regex**: For Matches tag filter operator (regex pattern matching)
- **hashbrown**: Optional, for faster HashMap implementation

### Testing Strategy

**Unit tests for**:
- Window generation for all window types (tumbling, sliding, calendar)
- Aggregate function correctness with known input/output
- Fill strategy application for empty windows
- Tag filtering logic (equal, contains, regex)
- Session detection with various gap patterns

**Property tests for**:
- Window coverage (no gaps, no overlaps for tumbling windows)
- Monotonicity preservation in downsampling
- Group key uniqueness for tag combinations
- Rate computation accuracy for counter series

**Integration scenarios**:
- Multi-series grouped queries
- Calendar window alignment across DST transitions
- Large dataset aggregation performance
- Empty result handling with various fill strategies

**Performance benchmarks**:
- Aggregation throughput (points per second) for various window sizes
- Grouping performance for high-cardinality tags
- Downsampling latency for large time-series
- Query execution time vs data size scaling

### Error Handling

- **InvalidTimeRange**: Return Error when end_time <= start_time
- **InvalidWindow**: Return Error for invalid window configurations (negative size, zero step)
- **InvalidTagFilter**: Return Error when tag filter references non-existent tags
- **InvalidTimezone**: Return Error for invalid IANA timezone strings

Use `thiserror` crate for error types with derive macros for consistent error handling.

### Implementation Notes

1. Implement `Display` for TimeWindow to show formatted time ranges
2. Use `derive(Debug, Clone, PartialEq)` for all public types
3. Implement `PartialOrd` for TimeSeriesPoint based on timestamp for sorting
4. Add builder pattern for TimeSeriesQuery for fluent query construction
5. Use `Arc<str>` for tag name and value deduplication in high-cardinality scenarios
6. Consider using `ndarray` or `polars` for optimized aggregate computations on large datasets
