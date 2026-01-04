# Visualization Data Generators

## Purpose

Visualization data generators transform NorthstarDB query results into formats suitable for rendering charts, graphs, and dashboards. This component provides data export capabilities optimized for common visualization libraries and tools, enabling real-time observability and analytics dashboards without external BI systems.

## Core Concepts

### Data Transformation

Raw database results must be transformed into visualization-ready formats. This involves reshaping data structures, computing derived series, and applying formatting conventions expected by visualization libraries.

### Time-Series Formatting

Time-series data requires specific formatting for temporal axis rendering, including timestamp conversion, interval sampling, and gap handling for discontinuous data.

### Multi-Series Support

Visualization tools expect multi-series data in specific layouts (wide format, long format, nested structures). This specification provides generators for common visualization libraries.

## Types

### VisualizationFormat

**Description**: Target visualization format

**Variants**:
- `ChartJs` - Chart.js JavaScript library format
- `Plotly` - Plotly.js JavaScript library format
- `Grafana` - Grafana dashboard JSON format
- `Prometheus` - Prometheus query result format
- `Csv` - Comma-separated values for spreadsheet tools
- `Json` - Generic JSON for custom visualization
- `Sql` - SQL INSERT statements for data export

### ChartConfig

**Description**: Generic chart configuration

**Fields**:
- `chart_type: ChartType` - Type of chart to render
- `title: String` - Chart title
- `x_axis_label: String` - X-axis label
- `y_axis_label: String` - Y-axis label
- `width: Option<usize>` - Chart width in pixels
- `height: Option<usize>` - Chart height in pixels
- `interactive: bool` - Enable interactive features (tooltips, zoom)
- `theme: ChartTheme` - Color theme and styling

### ChartType

**Description**: Type of visualization

**Variants**:
- `Line` - Line chart for time-series
- `Bar` - Bar chart for categorical data
- `Scatter` - Scatter plot for correlation analysis
- `Pie` - Pie chart for proportion analysis
- `Area` - Area chart for cumulative values
- `Histogram` - Histogram for distribution analysis
- `Heatmap` - Heatmap for 2D density
- `Gauge` - Gauge chart for single-value display
- `Table` - Table for tabular data display
- `Metric` - Single metric value with trend

### ChartTheme

**Description**: Visual styling theme

**Variants**:
- `Light` - Light background with dark text
- `Dark` - Dark background with light text
- `Custom(ThemeColors)` - Custom color scheme

### ThemeColors

**Description**: Custom color scheme definitions

**Fields**:
- `background: String` - Background color (CSS color)
- `text: String` - Text color
- `primary: Vec<String>` - Primary color palette
- `secondary: Vec<String>` - Secondary color palette
- `grid: String` - Grid line color
- `axis: String` - Axis line color

### DataSeries

**Description**: Single data series for visualization

**Fields**:
- `name: String` - Series name/label
- `data: Vec<DataPoint>` - Data points in series
- `color: Option<String>` - Optional series color
- `y_axis: Option<usize>` - Y-axis index (for dual-axis charts)
- `visible: bool` - Initial visibility state
- `series_type: Option<ChartType>` - Override chart type for this series

**Invariants**:
- `data` is non-empty for visible series
- `y_axis` is None or valid axis index (0 or 1 for dual-axis)

### DataPoint

**Description**: Single data point with optional metadata

**Fields**:
- `x: f64` - X value (timestamp or category index)
- `y: f64` - Y value (measurement or count)
- `label: Option<String>` - Optional point label
- `metadata: HashMap<String, String>` - Additional point metadata

**Invariants**:
- `x` and `y` are finite (not NaN or infinity)

### TimeSeriesData

**Description**: Time-series data optimized for temporal charts

**Fields**:
- `timestamps: Vec<i64>` - Timestamps in milliseconds
- `values: Vec<f64>` - Corresponding values
- `labels: Vec<String>` - Optional labels for each point
- `series_name: String` - Series identifier

**Invariants**:
- `timestamps.len() == values.len()`
- `labels` is empty or same length as timestamps
- Timestamps are monotonically increasing

### HistogramBucket

**Description**: Histogram bucket for distribution visualization

**Fields**:
- `lower_bound: f64` - Bucket lower bound (inclusive)
- `upper_bound: f64` - Bucket upper bound (exclusive)
- `count: usize` - Number of items in bucket
- `percentage: f64` - Percentage of total items

**Invariants**:
- `lower_bound < upper_bound`
- `percentage` is between 0.0 and 1.0
- Adjacent buckets have matching bounds

### HistogramData

**Description**: Complete histogram for distribution visualization

**Fields**:
- `buckets: Vec<HistogramBucket>` - Histogram buckets
- `total_count: usize` - Total items across all buckets
- `mean: f64` - Mean value
- `median: f64` - Median value
- `stddev: f64` - Standard deviation
- `min: f64` - Minimum value
- `max: f64` - Maximum value

**Invariants**:
- `buckets` is non-empty
- Bucket counts sum to `total_count`
- `min` <= `median` <= `max`

### HeatmapData

**Description**: 2D heatmap data

**Fields**:
- `x_labels: Vec<String>` - X-axis labels
- `y_labels: Vec<String>` - Y-axis labels
- `values: Vec<Vec<f64>>` - 2D value grid (values[y][x])
- `x_title: String` - X-axis title
- `y_title: String` - Y-axis title
- `color_scale: ColorScale` - Color mapping for values

**Invariants**:
- `values.len() == y_labels.len()`
- Each inner `values[y]` has length `x_labels.len()`
- All values are finite or NaN for missing data

### ColorScale

**Description**: Color scale for heatmap

**Variants**:
- `Sequential(String, String)` - Gradient from low to high (two CSS colors)
- `Diverging(String, String, String)` - Three-way gradient (low, mid, high colors)
- `Categorical` - Discrete colors for categories

### TableData

**Description**: Tabular data for table visualization

**Fields**:
- `columns: Vec<ColumnDefinition>` - Column definitions
- `rows: Vec<Vec<TableCell>>` - Table rows (rows[row][col])
- `pagination: Option<PaginationInfo>` - Pagination metadata

**Invariants**:
- `columns` is non-empty
- Each row has same length as `columns`
- All cells match column type

### ColumnDefinition

**Description**: Table column definition

**Fields**:
- `name: String` - Column name
- `data_type: ColumnType` - Column data type
- `sortable: bool` - Whether column is sortable
- `filterable: bool` - Whether column is filterable
- `width: Option<usize>` - Optional column width in pixels

### ColumnType

**Description**: Column data type

**Variants**:
- `String` - Text data
- `Number` - Numeric data
- `Boolean` - True/false values
- `DateTime` - Timestamp data
- `Duration` - Time duration
- `Link` - Hyperlink reference

### TableCell

**Description**: Single table cell

**Variants**:
- `String(String)` - Text value
- `Number(f64)` - Numeric value
- `Boolean(bool)` - Boolean value
- `DateTime(i64)` - Timestamp in milliseconds
- `Null` - Null/missing value
- `Link { text: String, url: String }` - Hyperlink

### PaginationInfo

**Description**: Pagination metadata for table

**Fields**:
- `current_page: usize` - Current page number (1-indexed)
- `total_pages: usize` - Total number of pages
- `page_size: usize` - Items per page
- `total_items: usize` - Total items across all pages

**Invariants**:
- `current_page >= 1` and `current_page <= total_pages`
- `page_size > 0`
- `total_items > 0`

### GaugeData

**Description**: Single-value gauge visualization

**Fields**:
- `value: f64` - Current value
- `min: f64` - Minimum possible value
- `max: f64` - Maximum possible value
- `thresholds: Vec<GaugeThreshold>` - Threshold zones
- `label: String` - Value label
- `unit: Option<String>` - Unit of measurement
- `trend: Option<Trend>` - Optional trend indicator

**Invariants**:
- `min <= value <= max`
- `value` is finite
- `thresholds` are sorted by bound value

### GaugeThreshold

**Description**: Gauge threshold zone

**Fields**:
- `bound: f64` - Threshold value
- `color: String` - Zone color (CSS color)
- `label: String` - Zone label

**Invariants**:
- `bound` is between `min` and `max`

### Trend

**Description**: Trend indicator for gauges

**Fields**:
- `direction: TrendDirection` - Trend direction
- `magnitude: f64` - Percent change from previous value
- `period: String` - Time period for trend (e.g., "1h", "1d")

**Invariants**:
- `magnitude` is finite

### TrendDirection

**Description**: Trend direction

**Variants**:
- `Up` - Increasing trend
- `Down` - Decreasing trend
- `Flat` - No significant change
- `Unknown` - Insufficient data

### ChartJsData

**Description**: Chart.js library format

**Fields**:
- `labels: Vec<String>` - X-axis labels
- `datasets: Vec<ChartJsDataset>` - Data series
- `options: ChartJsOptions` - Chart configuration

### ChartJsDataset

**Description**: Chart.js data series

**Fields**:
- `label: String` - Series label
- `data: Vec<f64>` - Y values
- `border_color: Option<String>` - Line color
- `background_color: Option<String>` - Fill color
- `chart_type: Option<String>` - Override chart type (line, bar, etc.)

### ChartJsOptions

**Description**: Chart.js global options

**Fields**:
- `responsive: bool` - Enable responsive sizing
- `maintain_aspect_ratio: bool` - Maintain aspect ratio
- `plugins: ChartJsPlugins` - Plugin configuration
- `scales: Option<ChartJsScales>` - Axis configuration

### PlotlyData

**Description**: Plotly.js library format

**Fields**:
- `data: Vec<PlotlyTrace>` - Data traces
- `layout: PlotlyLayout` - Chart layout
- `config: PlotlyConfig` - Chart configuration

### PlotlyTrace

**Description**: Plotly data trace

**Fields**:
- `x: Vec<f64>` - X values
- `y: Vec<f64>` - Y values
- `name: String` - Trace name
- `mode: String` - Plot mode (lines, markers, lines+markers)
- `trace_type: String` - Trace type (scatter, bar, etc.)

### PlotlyLayout

**Description**: Plotly layout configuration

**Fields**:
- `title: String` - Chart title
- `xaxis: PlotlyAxis` - X-axis configuration
- `yaxis: PlotlyAxis` - Y-axis configuration
- `showlegend: bool` - Show legend

### PlotlyAxis

**Description**: Plotly axis configuration

**Fields**:
- `title: String` - Axis title
- `type_: String` - Axis type (linear, log, date, category)

### PrometheusResult

**Description**: Prometheus query result format

**Fields**:
- `result_type: String` - Result type (matrix, vector, scalar, string)
- `result: Vec<PrometheusSeries>` - Data series

### PrometheusSeries

**Description**: Prometheus time-series

**Fields**:
- `metric: HashMap<String, String>` - Metric labels
- `values: Vec<(i64, f64)>` - Timestamp-value pairs
- `value: Option<(i64, f64)>` - Single value for instant queries

## Functions

### generate_chart_js(config: ChartConfig, series: Vec<DataSeries>) -> String

**Purpose**: Generate Chart.js JSON configuration

**Parameters**:
- `config: ChartConfig` - Chart configuration
- `series: Vec<DataSeries>` - Data series to render

**Returns**: `String` - JSON string for Chart.js

**Algorithm**:
1. Extract x-axis labels from first series or use indices
2. For each DataSeries, create ChartJsDataset:
   a. Map DataPoint values to dataset data array
   b. Set label from series name
   c. Apply color from series or theme palette
3. Build ChartJsOptions from config:
   a. Set responsive and aspect ratio
   b. Configure axis titles and scales
   c. Apply theme colors
4. Serialize ChartJsData to JSON string
5. Return JSON

**Error Conditions**:
- `EmptySeries`: When no series provided
- `MismatchedLengths`: When series have different x-axis lengths

**Concurrency**: Read-only access to input data, thread-safe

### generate_plotly(config: ChartConfig, series: Vec<DataSeries>) -> String

**Purpose**: Generate Plotly.js JSON configuration

**Parameters**:
- `config: ChartConfig` - Chart configuration
- `series: Vec<DataSeries>` - Data series to render

**Returns**: `String` - JSON string for Plotly

**Algorithm**:
1. For each DataSeries, create PlotlyTrace:
   a. Extract x values from DataPoint.x
   b. Extract y values from DataPoint.y
   c. Set trace name and type from series
   d. Determine mode based on chart type (lines, markers, etc.)
2. Build PlotlyLayout from config:
   a. Set title from config
   b. Configure axis titles and types
   c. Set legend visibility
3. Create PlotlyConfig with responsive settings
4. Serialize PlotlyData to JSON string
5. Return JSON

**Error Conditions**:
- `EmptySeries`: When no series provided
- `InvalidChartType`: When chart type not supported by Plotly

**Concurrency**: Read-only access to input data, thread-safe

### generate_csv(series: Vec<DataSeries>) -> String

**Purpose**: Generate CSV format for spreadsheet tools

**Parameters**:
- `series: Vec<DataSeries>` - Data series to export

**Returns**: `String` - CSV formatted string

**Algorithm**:
1. Initialize CSV string builder
2. Write header row: "Timestamp,Series1,Series2,..."
3. Determine max length across all series
4. For each index from 0 to max_length:
   a. Write timestamp from first series (or index)
   b. For each series, write value or empty string if missing
   c. Join with commas and append to CSV
5. Return CSV string

**Error Conditions**: None (returns empty string for empty series)

**Concurrency**: Read-only access to input data, thread-safe

### generate_histogram(data: &[f64], bucket_count: usize) -> HistogramData

**Purpose**: Generate histogram data for distribution visualization

**Parameters**:
- `data: &[f64]` - Numeric values to histogram
- `bucket_count: usize` - Number of histogram buckets

**Returns**: `HistogramData` - Histogram with statistics

**Algorithm**:
1. If data is empty, return empty histogram
2. Find min and max values
3. Compute bucket width: (max - min) / bucket_count
4. Initialize bucket counts array
5. For each value in data:
   a. Compute bucket index: floor((value - min) / bucket_width)
   b. Clamp index to valid range [0, bucket_count - 1]
   c. Increment bucket count
6. Compute statistics:
   a. Mean: sum / count
   b. Median: Sort data, pick middle value
   c. Stddev: Square root of variance
7. Build HistogramBucket objects:
   a. For each bucket, compute lower and upper bounds
   b. Set count and percentage (count / total)
8. Return HistogramData

**Error Conditions**: None (returns empty histogram for empty data)

**Concurrency**: Read-only access to input data, thread-safe

### generate_heatmap(x_values: &[f64], y_values: &[f64], z_values: &[f64], x_bins: usize, y_bins: usize) -> HeatmapData

**Purpose**: Generate 2D heatmap from 3D data points

**Parameters**:
- `x_values: &[f64]` - X coordinates
- `y_values: &[f64]` - Y coordinates
- `z_values: &[f64]` - Z values (color intensity)
- `x_bins: usize` - Number of X bins
- `y_bins: usize` - Number of Y bins

**Returns**: `HeatmapData` - Heatmap with 2D grid

**Algorithm**:
1. Validate input arrays have same length
2. Find x and y ranges (min, max)
3. Initialize 2D grid with zeros
4. For each (x, y, z) point:
   a. Compute x bin index: floor((x - x_min) / (x_max - x_min) * x_bins)
   b. Compute y bin index: floor((y - y_min) / (y_max - y_min) * y_bins)
   c. Clamp indices to valid range
   d. Accumulate or average z value in grid[y][x]
5. Generate axis labels from bin boundaries
6. Create HeatmapData with grid and labels
7. Return HeatmapData

**Error Conditions**:
- `MismatchedLengths`: When x_values, y_values, z_values have different lengths

**Concurrency**: Read-only access to input data, thread-safe

### generate_table(columns: Vec<ColumnDefinition>, rows: Vec<Vec<TableCell>>, pagination: Option<PaginationInfo>) -> TableData

**Purpose**: Generate table data structure

**Parameters**:
- `columns: Vec<ColumnDefinition>` - Column definitions
- `rows: Vec<Vec<TableCell>>` - Table rows
- `pagination: Option<PaginationInfo>` - Optional pagination info

**Returns**: `TableData` - Complete table structure

**Algorithm**:
1. Validate each row has same length as columns
2. Validate each cell matches column type
3. Create TableData structure
4. Return TableData

**Error Conditions**:
- `MismatchedColumnCount`: When row length doesn't match column count
- `InvalidCellType`: When cell type doesn't match column type

**Concurrency**: Read-only access to input data, thread-safe

### generate_gauge(value: f64, min: f64, max: f64, label: String, thresholds: Vec<GaugeThreshold>) -> GaugeData

**Purpose**: Generate gauge visualization data

**Parameters**:
- `value: f64` - Current gauge value
- `min: f64` - Minimum value
- `max: f64` - Maximum value
- `label: String` - Gauge label
- `thresholds: Vec<GaugeThreshold>` - Threshold zones

**Returns**: `GaugeData` - Gauge data structure

**Algorithm**:
1. Validate value is within [min, max]
2. Sort thresholds by bound value
3. Create GaugeData with value, range, label
4. Add thresholds to gauge
5. Return GaugeData

**Error Conditions**:
- `ValueOutOfRange`: When value not in [min, max]

**Concurrency**: Pure function, thread-safe

### compute_trend(current: f64, previous: f64, period: String) -> Option<Trend>

**Purpose**: Compute trend indicator between two values

**Parameters**:
- `current: f64` - Current value
- `previous: f64` - Previous value
- `period: String` - Time period description

**Returns**: `Option<Trend>` - Trend indicator or None if insufficient data

**Algorithm**:
1. If previous is zero or NaN, return None
2. Compute percent change: (current - previous) / previous * 100
3. Determine direction:
   a. If change > 5%, return TrendDirection::Up
   b. If change < -5%, return TrendDirection::Down
   c. Otherwise, return TrendDirection::Flat
4. Create Trend with direction and magnitude
5. Return Trend

**Error Conditions**: None (returns None for invalid inputs)

**Concurrency**: Pure function, thread-safe

### format_timestamp_millis(ts: i64, format: TimestampFormat) -> String

**Purpose**: Format timestamp for display

**Parameters**:
- `ts: i64` - Timestamp in milliseconds
- `format: TimestampFormat` - Desired format

**Returns**: `String` - Formatted timestamp string

**Algorithm**:
1. Match on TimestampFormat variant:
   - ISO8601: Format as "2024-01-04T12:34:56Z"
   - Human: Format as "Jan 4, 2024 12:34 PM"
   - Relative: Format as "5 minutes ago", "2 hours ago"
   - Unix: Return timestamp as string
2. Return formatted string

**Error Conditions**: None (returns empty string for invalid timestamps)

**Concurrency**: Pure function, thread-safe

### TimestampFormat

**Description**: Timestamp display format

**Variants**:
- `ISO8601` - ISO 8601 standard format
- `Human` - Human-readable format
- `Relative` - Relative time ("5 minutes ago")
- `Unix` - Unix timestamp (milliseconds)

### convert_time_series(aggregates: Vec<TimeSeriesAggregate>) -> TimeSeriesData

**Purpose**: Convert time-series aggregates to TimeSeriesData format

**Parameters**:
- `aggregates: Vec<TimeSeriesAggregate>` - Aggregated time-series data

**Returns**: `TimeSeriesData` - Formatted time-series

**Algorithm**:
1. Initialize empty Vecs for timestamps and values
2. For each aggregate in order:
   a. Push aggregate.window.end to timestamps
   b. Push aggregate.value to values
3. Extract series name from first aggregate or use default
4. Create TimeSeriesData structure
5. Return TimeSeriesData

**Error Conditions**: None (returns empty TimeSeriesData for empty input)

**Concurrency**: Read-only access to input data, thread-safe

### apply_theme(data: String, theme: ChartTheme) -> String

**Purpose**: Apply color theme to visualization JSON

**Parameters**:
- `data: String` - Visualization JSON
- `theme: ChartTheme` - Theme to apply

**Returns**: `String` - Themed JSON

**Algorithm**:
1. Parse JSON string to Value
2. Match on theme variant:
   - Light: Set light background and dark text colors
   - Dark: Set dark background and light text colors
   - Custom(c): Apply custom color scheme
3. Update JSON with theme colors
4. Serialize back to JSON string
5. Return themed JSON

**Error Conditions**:
- `InvalidJson`: When data is not valid JSON

**Concurrency**: Read-only access to input data, thread-safe

### generate_prometheus_matrix(series: Vec<TimeSeriesData>) -> PrometheusResult

**Purpose**: Generate Prometheus matrix query result format

**Parameters**:
- `series: Vec<TimeSeriesData>` - Time-series data

**Returns**: `PrometheusResult` - Prometheus format

**Algorithm**:
1. Set result_type to "matrix"
2. For each TimeSeriesData:
   a. Extract metric labels from series_name
   b. Convert timestamps and values to Prometheus pairs
   c. Create PrometheusSeries
3. Build PrometheusResult with series
4. Return PrometheusResult

**Error Conditions**: None (returns empty result for empty input)

**Concurrency**: Read-only access to input data, thread-safe

## Invariants

- Visualization JSON must be valid JSON syntax
- All series in multi-series chart must have compatible x-axis
- Timestamps must be monotonically increasing for time-series
- Histogram buckets must cover full data range without gaps
- Heatmap grid must be rectangular (all rows same length)
- Table rows must match column count and types
- Gauge value must be within min/max bounds

## Dependencies

- **Uses**: Time-series aggregation types, Core database types
- **Used by**: Dashboard systems, monitoring tools, analytics pipelines

## Rust Implementation Guidance

### Module Structure

The visualization generators module should be organized as follows:

```
northstar-core/src/viz/
  mod.rs              - Public API exports
  types.rs            - Core type definitions
  chart_js.rs         - Chart.js format generator
  plotly.rs           - Plotly format generator
  grafana.rs          - Grafana format generator
  prometheus.rs       - Prometheus format generator
  csv.rs              - CSV export generator
  histogram.rs        - Histogram generation
  heatmap.rs          - Heatmap generation
  table.rs            - Table generation
  gauge.rs            - Gauge generation
  theme.rs            - Theme application
  format.rs           - Timestamp and value formatting
```

### Type Definitions

- **ChartType**: Enum with variants for each chart type
- **DataSeries**: Struct with name, data Vec, optional color and y_axis
- **DataPoint**: Struct with x, y f64 values and optional metadata
- **TimeSeriesData**: Struct with timestamps Vec<i64>, values Vec<f64>
- **HistogramData**: Struct with buckets Vec, statistics fields
- **TableData**: Struct with columns and rows, optional pagination

### Key Implementation Patterns

1. **JSON Generation**: Use `serde_json` for serializing to target formats
2. **Data Transformation**: Map internal types to visualization library types
3. **Theme Application**: Parse JSON, update color fields, serialize back
4. **Histogram Computing**: Single-pass algorithm with bucket counting
5. **Heatmap Binning**: 2D grid accumulation with coordinate binning

### Concurrency Model

- **Stateless**: All functions are pure transformations
- **Thread-Safe**: Read-only access to input data, immutable output
- **Parallelizable**: Multi-series charts can generate each series independently

### Performance Considerations

1. **JSON Serialization**: Use `serde_json::to_string` for efficient serialization
2. **String Building**: Use `String` with `push_str` for CSV generation
3. **Pre-allocation**: Pre-allocate Vecs with known capacity when possible
4. **Lazy Evaluation**: Avoid generating unused data series

### Key Decisions

- **JSON Library**: Use `serde_json` for serialization (de facto standard)
- **Chart Library Support**: Prioritize Chart.js and Plotly (most popular)
- **Export Formats**: CSV for spreadsheets, JSON for programmatic access
- **Timestamp Format**: Store as i64 milliseconds, format on output
- **Theme System**: Post-process JSON to apply colors (simpler than template system)

### External Dependencies

- **serde_json**: For JSON serialization and parsing
- **chrono**: For timestamp formatting and conversion
- **csv**: Optional, for robust CSV generation with quoting

### Testing Strategy

**Unit tests for**:
- Chart.js JSON generation for all chart types
- Plotly JSON generation for all chart types
- CSV export with various data patterns
- Histogram bucket computation accuracy
- Heatmap binning with edge cases

**Property tests for**:
- JSON validity (output must parse as valid JSON)
- Series data preservation (input equals output after round-trip)
- Histogram bucket coverage (no gaps, no overlaps)
- Table row/column consistency

**Integration scenarios**:
- Complete dashboard generation with multiple charts
- Large dataset performance (100k+ points)
- Theme application across chart types
- Multi-library format conversion

**Validation tests**:
- Validate generated JSON against library schemas
- Test rendering in actual Chart.js and Plotly environments
- Verify CSV import into spreadsheet applications

### Error Handling

- `EmptySeries`: Return empty JSON or error when no data provided
- `MismatchedLengths`: Return error for series with incompatible lengths
- `InvalidJson`: Return error when theme application fails to parse
- `ValueOutOfRange`: Return error for gauge values outside min/max

Use `thiserror` crate for error types with derive macros.

### Implementation Notes

1. Use `serde::{Serialize, Deserialize}` for all data types
2. Implement `Display` for ChartType and ChartTheme for debugging
3. Add builder pattern for ChartConfig for fluent construction
4. Use `#[serde(rename = "type")]` for fields conflicting with Rust keywords
5. Implement custom serializers for timestamp formatting
6. Consider using `tera` or `handlebars` for complex template-based generation

### Format-Specific Notes

**Chart.js**:
- Use camelCase for all field names (JavaScript convention)
- Support datasets with mixed chart types
- Include responsive and maintainAspectRatio options

**Plotly**:
- Use snake_case for field names
- Support traces with different modes (lines, markers, etc.)
- Include layout configuration for axis types

**Prometheus**:
- Match Prometheus API response format exactly
- Support both matrix (range queries) and vector (instant queries)
- Include metric labels as HashMap

**CSV**:
- Use RFC 4180 format (comma-separated, CRLF line endings)
- Quote fields containing commas or quotes
- Escape quotes by doubling ("")
