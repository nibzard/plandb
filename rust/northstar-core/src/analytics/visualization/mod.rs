//! Visualization data generators for NorthstarDB analytics.
//!
//! This module transforms time-series aggregation results into formats suitable
//! for rendering charts, graphs, and dashboards using common visualization
//! libraries like Chart.js, Plotly, Grafana, and Prometheus.

use crate::analytics::types::TimeSeriesAggregate;
use crate::analytics::TimeSeriesError;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;

pub mod visualization_format;
pub mod visualization_theme;

// Re-exports for convenience
pub use visualization_format::{format_timestamp_millis, TimestampFormat};
pub use visualization_theme::{apply_theme, ChartTheme, ThemeColors};

/// Target visualization format
#[derive(Debug, Clone, PartialEq)]
pub enum VisualizationFormat {
    /// Chart.js JavaScript library format
    ChartJs,
    /// Plotly.js JavaScript library format
    Plotly,
    /// Grafana dashboard JSON format
    Grafana,
    /// Prometheus query result format
    Prometheus,
    /// Comma-separated values for spreadsheet tools
    Csv,
    /// Generic JSON for custom visualization
    Json,
    /// SQL INSERT statements for data export
    Sql,
}

/// Type of visualization
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChartType {
    /// Line chart for time-series
    Line,
    /// Bar chart for categorical data
    Bar,
    /// Scatter plot for correlation analysis
    Scatter,
    /// Pie chart for proportion analysis
    Pie,
    /// Area chart for cumulative values
    Area,
    /// Histogram for distribution analysis
    Histogram,
    /// Heatmap for 2D density
    Heatmap,
    /// Gauge chart for single-value display
    Gauge,
    /// Table for tabular data display
    Table,
    /// Single metric value with trend
    Metric,
}

impl fmt::Display for ChartType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChartType::Line => write!(f, "line"),
            ChartType::Bar => write!(f, "bar"),
            ChartType::Scatter => write!(f, "scatter"),
            ChartType::Pie => write!(f, "pie"),
            ChartType::Area => write!(f, "area"),
            ChartType::Histogram => write!(f, "histogram"),
            ChartType::Heatmap => write!(f, "heatmap"),
            ChartType::Gauge => write!(f, "gauge"),
            ChartType::Table => write!(f, "table"),
            ChartType::Metric => write!(f, "metric"),
        }
    }
}

/// Generic chart configuration
#[derive(Debug, Clone, PartialEq)]
pub struct ChartConfig {
    /// Type of chart to render
    pub chart_type: ChartType,
    /// Chart title
    pub title: String,
    /// X-axis label
    pub x_axis_label: String,
    /// Y-axis label
    pub y_axis_label: String,
    /// Chart width in pixels
    pub width: Option<usize>,
    /// Chart height in pixels
    pub height: Option<usize>,
    /// Enable interactive features (tooltips, zoom)
    pub interactive: bool,
    /// Color theme and styling
    pub theme: ChartTheme,
}

impl ChartConfig {
    /// Create a new chart configuration with defaults
    pub fn new(chart_type: ChartType, title: String) -> Self {
        Self {
            chart_type,
            title,
            x_axis_label: String::new(),
            y_axis_label: String::new(),
            width: None,
            height: None,
            interactive: true,
            theme: ChartTheme::Light,
        }
    }

    /// Set axis labels
    pub fn with_axes(mut self, x_label: String, y_label: String) -> Self {
        self.x_axis_label = x_label;
        self.y_axis_label = y_label;
        self
    }

    /// Set dimensions
    pub fn with_dimensions(mut self, width: usize, height: usize) -> Self {
        self.width = Some(width);
        self.height = Some(height);
        self
    }

    /// Set interactive mode
    pub fn with_interactive(mut self, interactive: bool) -> Self {
        self.interactive = interactive;
        self
    }

    /// Set theme
    pub fn with_theme(mut self, theme: ChartTheme) -> Self {
        self.theme = theme;
        self
    }
}

/// Single data point with optional metadata
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DataPoint {
    /// X value (timestamp or category index)
    pub x: f64,
    /// Y value (measurement or count)
    pub y: f64,
    /// Optional point label
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// Additional point metadata
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    pub metadata: HashMap<String, String>,
}

impl DataPoint {
    /// Create a new data point
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidValue` if x or y is not finite
    pub fn new(x: f64, y: f64) -> Result<Self, TimeSeriesError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(TimeSeriesError::InvalidWindow(
                "x and y must be finite".to_string(),
            ));
        }
        Ok(Self {
            x,
            y,
            label: None,
            metadata: HashMap::new(),
        })
    }

    /// Create a new data point with label
    pub fn with_label(x: f64, y: f64, label: String) -> Result<Self, TimeSeriesError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(TimeSeriesError::InvalidWindow(
                "x and y must be finite".to_string(),
            ));
        }
        Ok(Self {
            x,
            y,
            label: Some(label),
            metadata: HashMap::new(),
        })
    }

    /// Add metadata to this point
    pub fn add_metadata(&mut self, key: String, value: String) {
        self.metadata.insert(key, value);
    }
}

/// Single data series for visualization
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DataSeries {
    /// Series name/label
    pub name: String,
    /// Data points in series
    pub data: Vec<DataPoint>,
    /// Optional series color
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Y-axis index (for dual-axis charts)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y_axis: Option<usize>,
    /// Initial visibility state
    pub visible: bool,
    /// Override chart type for this series
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series_type: Option<ChartType>,
}

impl DataSeries {
    /// Create a new data series
    pub fn new(name: String, data: Vec<DataPoint>) -> Result<Self, TimeSeriesError> {
        // Validate data is non-empty for visible series
        if !data.is_empty() {
            for point in &data {
                if !point.x.is_finite() || !point.y.is_finite() {
                    return Err(TimeSeriesError::InvalidWindow(
                        "data points must have finite x and y values".to_string(),
                    ));
                }
            }
        }

        Ok(Self {
            name,
            data,
            color: None,
            y_axis: None,
            visible: true,
            series_type: None,
        })
    }

    /// Set series color
    pub fn with_color(mut self, color: String) -> Self {
        self.color = Some(color);
        self
    }

    /// Set Y-axis index
    pub fn with_y_axis(mut self, axis: usize) -> Self {
        self.y_axis = Some(axis);
        self
    }

    /// Set visibility
    pub fn with_visibility(mut self, visible: bool) -> Self {
        self.visible = visible;
        self
    }

    /// Set series type override
    pub fn with_series_type(mut self, series_type: ChartType) -> Self {
        self.series_type = Some(series_type);
        self
    }
}

/// Time-series data optimized for temporal charts
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TimeSeriesData {
    /// Timestamps in milliseconds
    pub timestamps: Vec<i64>,
    /// Corresponding values
    pub values: Vec<f64>,
    /// Optional labels for each point
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub labels: Vec<String>,
    /// Series identifier
    pub series_name: String,
}

impl TimeSeriesData {
    /// Create a new time-series data
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if lengths don't match or timestamps not monotonic
    pub fn new(
        timestamps: Vec<i64>,
        values: Vec<f64>,
        series_name: String,
    ) -> Result<Self, TimeSeriesError> {
        if timestamps.len() != values.len() {
            return Err(TimeSeriesError::InvalidWindow(
                "timestamps and values must have same length".to_string(),
            ));
        }

        // Validate monotonic timestamps
        for i in 1..timestamps.len() {
            if timestamps[i] <= timestamps[i - 1] {
                return Err(TimeSeriesError::InvalidWindow(
                    "timestamps must be monotonically increasing".to_string(),
                ));
            }
        }

        Ok(Self {
            timestamps,
            values,
            labels: Vec::new(),
            series_name,
        })
    }

    /// Create with labels
    pub fn with_labels(
        timestamps: Vec<i64>,
        values: Vec<f64>,
        labels: Vec<String>,
        series_name: String,
    ) -> Result<Self, TimeSeriesError> {
        if timestamps.len() != values.len() {
            return Err(TimeSeriesError::InvalidWindow(
                "timestamps and values must have same length".to_string(),
            ));
        }
        if !labels.is_empty() && labels.len() != timestamps.len() {
            return Err(TimeSeriesError::InvalidWindow(
                "labels must be empty or same length as timestamps".to_string(),
            ));
        }

        // Validate monotonic timestamps
        for i in 1..timestamps.len() {
            if timestamps[i] <= timestamps[i - 1] {
                return Err(TimeSeriesError::InvalidWindow(
                    "timestamps must be monotonically increasing".to_string(),
                ));
            }
        }

        Ok(Self {
            timestamps,
            values,
            labels,
            series_name,
        })
    }
}

/// Histogram bucket for distribution visualization
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistogramBucket {
    /// Bucket lower bound (inclusive)
    pub lower_bound: f64,
    /// Bucket upper bound (exclusive)
    pub upper_bound: f64,
    /// Number of items in bucket
    pub count: usize,
    /// Percentage of total items
    pub percentage: f64,
}

impl HistogramBucket {
    /// Create a new histogram bucket
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if bounds invalid or percentage not in [0, 1]
    pub fn new(lower_bound: f64, upper_bound: f64, count: usize, total: usize) -> Result<Self, TimeSeriesError> {
        if lower_bound >= upper_bound {
            return Err(TimeSeriesError::InvalidWindow(
                "lower_bound must be less than upper_bound".to_string(),
            ));
        }

        let percentage = if total > 0 {
            count as f64 / total as f64
        } else {
            0.0
        };

        if percentage < 0.0 || percentage > 1.0 {
            return Err(TimeSeriesError::InvalidWindow(
                "percentage must be between 0.0 and 1.0".to_string(),
            ));
        }

        Ok(Self {
            lower_bound,
            upper_bound,
            count,
            percentage,
        })
    }
}

/// Complete histogram for distribution visualization
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistogramData {
    /// Histogram buckets
    pub buckets: Vec<HistogramBucket>,
    /// Total items across all buckets
    pub total_count: usize,
    /// Mean value
    pub mean: f64,
    /// Median value
    pub median: f64,
    /// Standard deviation
    pub stddev: f64,
    /// Minimum value
    pub min: f64,
    /// Maximum value
    pub max: f64,
}

impl HistogramData {
    /// Create new histogram data
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if data invalid
    pub fn new(
        buckets: Vec<HistogramBucket>,
        total_count: usize,
        mean: f64,
        median: f64,
        stddev: f64,
        min: f64,
        max: f64,
    ) -> Result<Self, TimeSeriesError> {
        if buckets.is_empty() {
            return Err(TimeSeriesError::InvalidWindow(
                "buckets must not be empty".to_string(),
            ));
        }

        // Validate bucket counts sum to total
        let sum: usize = buckets.iter().map(|b| b.count).sum();
        if sum != total_count {
            return Err(TimeSeriesError::InvalidWindow(
                "bucket counts must sum to total_count".to_string(),
            ));
        }

        // Validate min <= median <= max
        if min > median || median > max {
            return Err(TimeSeriesError::InvalidWindow(
                "min must be <= median <= max".to_string(),
            ));
        }

        Ok(Self {
            buckets,
            total_count,
            mean,
            median,
            stddev,
            min,
            max,
        })
    }
}

/// Color scale for heatmap
#[derive(Debug, Clone, PartialEq)]
pub enum ColorScale {
    /// Gradient from low to high (two CSS colors)
    Sequential(String, String),
    /// Three-way gradient (low, mid, high colors)
    Diverging(String, String, String),
    /// Discrete colors for categories
    Categorical(Vec<String>),
}

/// 2D heatmap data
#[derive(Debug, Clone, PartialEq)]
pub struct HeatmapData {
    /// X-axis labels
    pub x_labels: Vec<String>,
    /// Y-axis labels
    pub y_labels: Vec<String>,
    /// 2D value grid (values[y][x])
    pub values: Vec<Vec<f64>>,
    /// X-axis title
    pub x_title: String,
    /// Y-axis title
    pub y_title: String,
    /// Color mapping for values
    pub color_scale: ColorScale,
}

impl HeatmapData {
    /// Create new heatmap data
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if data dimensions invalid
    pub fn new(
        x_labels: Vec<String>,
        y_labels: Vec<String>,
        values: Vec<Vec<f64>>,
        x_title: String,
        y_title: String,
        color_scale: ColorScale,
    ) -> Result<Self, TimeSeriesError> {
        if values.len() != y_labels.len() {
            return Err(TimeSeriesError::InvalidWindow(
                "values row count must match y_labels length".to_string(),
            ));
        }

        for row in &values {
            if row.len() != x_labels.len() {
                return Err(TimeSeriesError::InvalidWindow(
                    "each values row must have same length as x_labels".to_string(),
                ));
            }
        }

        Ok(Self {
            x_labels,
            y_labels,
            values,
            x_title,
            y_title,
            color_scale,
        })
    }
}

/// Column data type
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ColumnType {
    /// Text data
    String,
    /// Numeric data
    Number,
    /// True/false values
    Boolean,
    /// Timestamp data
    DateTime,
    /// Time duration
    Duration,
    /// Hyperlink reference
    Link,
}

/// Table column definition
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColumnDefinition {
    /// Column name
    pub name: String,
    /// Column data type
    pub data_type: ColumnType,
    /// Whether column is sortable
    pub sortable: bool,
    /// Whether column is filterable
    pub filterable: bool,
    /// Optional column width in pixels
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<usize>,
}

impl ColumnDefinition {
    /// Create a new column definition
    pub fn new(name: String, data_type: ColumnType) -> Self {
        Self {
            name,
            data_type,
            sortable: false,
            filterable: false,
            width: None,
        }
    }

    /// Set sortable
    pub fn with_sortable(mut self, sortable: bool) -> Self {
        self.sortable = sortable;
        self
    }

    /// Set filterable
    pub fn with_filterable(mut self, filterable: bool) -> Self {
        self.filterable = filterable;
        self
    }

    /// Set width
    pub fn with_width(mut self, width: usize) -> Self {
        self.width = Some(width);
        self
    }
}

/// Single table cell
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum TableCell {
    /// Text value
    String(String),
    /// Numeric value
    Number(f64),
    /// Boolean value
    Boolean(bool),
    /// Timestamp in milliseconds
    DateTime(i64),
    /// Null/missing value
    Null,
    /// Hyperlink
    Link { text: String, url: String },
}

/// Pagination metadata for table
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaginationInfo {
    /// Current page number (1-indexed)
    pub current_page: usize,
    /// Total number of pages
    pub total_pages: usize,
    /// Items per page
    pub page_size: usize,
    /// Total items across all pages
    pub total_items: usize,
}

impl PaginationInfo {
    /// Create new pagination info
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if pagination invalid
    pub fn new(
        current_page: usize,
        total_pages: usize,
        page_size: usize,
        total_items: usize,
    ) -> Result<Self, TimeSeriesError> {
        if current_page < 1 || current_page > total_pages {
            return Err(TimeSeriesError::InvalidWindow(
                "current_page must be >= 1 and <= total_pages".to_string(),
            ));
        }
        if page_size == 0 {
            return Err(TimeSeriesError::InvalidWindow(
                "page_size must be > 0".to_string(),
            ));
        }
        if total_items == 0 {
            return Err(TimeSeriesError::InvalidWindow(
                "total_items must be > 0".to_string(),
            ));
        }

        Ok(Self {
            current_page,
            total_pages,
            page_size,
            total_items,
        })
    }
}

/// Tabular data for table visualization
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TableData {
    /// Column definitions
    pub columns: Vec<ColumnDefinition>,
    /// Table rows (rows[row][col])
    pub rows: Vec<Vec<TableCell>>,
    /// Pagination metadata
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pagination: Option<PaginationInfo>,
}

impl TableData {
    /// Create new table data
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if data invalid
    pub fn new(
        columns: Vec<ColumnDefinition>,
        rows: Vec<Vec<TableCell>>,
        pagination: Option<PaginationInfo>,
    ) -> Result<Self, TimeSeriesError> {
        if columns.is_empty() {
            return Err(TimeSeriesError::InvalidWindow(
                "columns must not be empty".to_string(),
            ));
        }

        // Validate each row has same length as columns
        for (i, row) in rows.iter().enumerate() {
            if row.len() != columns.len() {
                return Err(TimeSeriesError::InvalidWindow(format!(
                    "row {} has {} columns, expected {}",
                    i,
                    row.len(),
                    columns.len()
                )));
            }
        }

        Ok(Self {
            columns,
            rows,
            pagination,
        })
    }
}

/// Trend direction
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TrendDirection {
    /// Increasing trend
    Up,
    /// Decreasing trend
    Down,
    /// No significant change
    Flat,
    /// Insufficient data
    Unknown,
}

/// Trend indicator for gauges
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Trend {
    /// Trend direction
    pub direction: TrendDirection,
    /// Percent change from previous value
    pub magnitude: f64,
    /// Time period for trend (e.g., "1h", "1d")
    pub period: String,
}

impl Trend {
    /// Create a new trend
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if magnitude not finite
    pub fn new(direction: TrendDirection, magnitude: f64, period: String) -> Result<Self, TimeSeriesError> {
        if !magnitude.is_finite() {
            return Err(TimeSeriesError::InvalidWindow(
                "magnitude must be finite".to_string(),
            ));
        }

        Ok(Self {
            direction,
            magnitude,
            period,
        })
    }
}

/// Gauge threshold zone
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GaugeThreshold {
    /// Threshold value
    pub bound: f64,
    /// Zone color (CSS color)
    pub color: String,
    /// Zone label
    pub label: String,
}

impl GaugeThreshold {
    /// Create a new gauge threshold
    pub fn new(bound: f64, color: String, label: String) -> Self {
        Self {
            bound,
            color,
            label,
        }
    }
}

/// Single-value gauge visualization
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GaugeData {
    /// Current value
    pub value: f64,
    /// Minimum possible value
    pub min: f64,
    /// Maximum possible value
    pub max: f64,
    /// Threshold zones
    pub thresholds: Vec<GaugeThreshold>,
    /// Value label
    pub label: String,
    /// Unit of measurement
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
    /// Optional trend indicator
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trend: Option<Trend>,
}

impl GaugeData {
    /// Create a new gauge data
    ///
    /// # Errors
    /// Returns `TimeSeriesError::InvalidWindow` if value out of range
    pub fn new(
        value: f64,
        min: f64,
        max: f64,
        label: String,
        thresholds: Vec<GaugeThreshold>,
    ) -> Result<Self, TimeSeriesError> {
        if !value.is_finite() {
            return Err(TimeSeriesError::InvalidWindow(
                "value must be finite".to_string(),
            ));
        }
        if value < min || value > max {
            return Err(TimeSeriesError::InvalidWindow(format!(
                "value {} must be in range [{}, {}]",
                value, min, max
            )));
        }

        // Validate thresholds are sorted
        for i in 1..thresholds.len() {
            if thresholds[i].bound < thresholds[i - 1].bound {
                return Err(TimeSeriesError::InvalidWindow(
                    "thresholds must be sorted by bound value".to_string(),
                ));
            }
        }

        Ok(Self {
            value,
            min,
            max,
            thresholds,
            label,
            unit: None,
            trend: None,
        })
    }

    /// Set unit
    pub fn with_unit(mut self, unit: String) -> Self {
        self.unit = Some(unit);
        self
    }

    /// Set trend
    pub fn with_trend(mut self, trend: Trend) -> Self {
        self.trend = Some(trend);
        self
    }
}

/// Chart.js library format
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsData {
    /// X-axis labels
    pub labels: Vec<String>,
    /// Data series
    pub datasets: Vec<ChartJsDataset>,
    /// Chart configuration
    pub options: ChartJsOptions,
}

/// Chart.js data series
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsDataset {
    /// Series label
    pub label: String,
    /// Y values
    pub data: Vec<f64>,
    /// Line color
    #[serde(skip_serializing_if = "Option::is_none")]
    pub border_color: Option<String>,
    /// Fill color
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background_color: Option<String>,
    /// Override chart type (line, bar, etc.)
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub chart_type: Option<String>,
}

/// Chart.js global options
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsOptions {
    /// Enable responsive sizing
    pub responsive: bool,
    /// Maintain aspect ratio
    pub maintain_aspect_ratio: bool,
    /// Plugin configuration
    pub plugins: ChartJsPlugins,
    /// Axis configuration
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scales: Option<ChartJsScales>,
}

/// Chart.js plugin configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsPlugins {
    /// Legend configuration
    pub legend: ChartJsLegend,
    /// Title configuration
    pub title: ChartJsTitle,
    /// Tooltip configuration
    pub tooltip: ChartJsTooltip,
}

/// Chart.js legend configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsLegend {
    /// Show legend
    pub display: bool,
    /// Legend position
    pub position: String,
}

/// Chart.js title configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsTitle {
    /// Show title
    pub display: bool,
    /// Title text
    pub text: String,
}

/// Chart.js tooltip configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsTooltip {
    /// Enable tooltips
    pub enabled: bool,
    /// Tooltip mode
    pub mode: String,
    /// Tooltip intersection
    pub intersect: bool,
}

/// Chart.js axis configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsScales {
    /// X-axis configuration
    pub x: ChartJsAxis,
    /// Y-axis configuration
    pub y: Vec<ChartJsAxis>,
}

/// Chart.js single axis configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsAxis {
    /// Axis title
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<ChartJsAxisTitle>,
    /// Axis type
    #[serde(rename = "type")]
    pub axis_type: String,
    /// Axis position
    pub position: String,
    /// Grid configuration
    pub grid: ChartJsGrid,
}

/// Chart.js axis title
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsAxisTitle {
    /// Title text
    pub display: bool,
    pub text: String,
}

/// Chart.js grid configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartJsGrid {
    /// Show grid
    pub display: bool,
}

/// Plotly.js library format
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlotlyData {
    /// Data traces
    pub data: Vec<PlotlyTrace>,
    /// Chart layout
    pub layout: PlotlyLayout,
    /// Chart configuration
    pub config: PlotlyConfig,
}

/// Plotly data trace
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlotlyTrace {
    /// X values
    pub x: Vec<f64>,
    /// Y values
    pub y: Vec<f64>,
    /// Trace name
    pub name: String,
    /// Plot mode (lines, markers, lines+markers)
    pub mode: String,
    /// Trace type (scatter, bar, etc.)
    #[serde(rename = "type")]
    pub trace_type: String,
    /// Line color
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<PlotlyLine>,
}

/// Plotly line configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlotlyLine {
    /// Line color
    pub color: String,
    /// Line width
    pub width: f64,
}

/// Plotly layout configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlotlyLayout {
    /// Chart title
    pub title: PlotlyTitle,
    /// X-axis configuration
    pub xaxis: PlotlyAxis,
    /// Y-axis configuration
    pub yaxis: PlotlyAxis,
    /// Show legend
    pub showlegend: bool,
}

/// Plotly title configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlotlyTitle {
    /// Title text
    pub text: String,
}

/// Plotly axis configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlotlyAxis {
    /// Axis title
    pub title: PlotlyAxisTitle,
    /// Axis type
    #[serde(rename = "type")]
    pub axis_type: String,
    /// Grid color
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gridcolor: Option<String>,
    /// Zero line color
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zerolinecolor: Option<String>,
}

/// Plotly axis title
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlotlyAxisTitle {
    /// Title text
    pub text: String,
}

/// Plotly chart configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlotlyConfig {
    /// Responsive mode
    pub responsive: bool,
    /// Display mode bar
    pub display_mode_bar: bool,
}

/// Prometheus query result format
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrometheusResult {
    /// Result type (matrix, vector, scalar, string)
    pub result_type: String,
    /// Data series
    pub result: Vec<PrometheusSeries>,
}

/// Prometheus time-series
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrometheusSeries {
    /// Metric labels
    pub metric: HashMap<String, String>,
    /// Timestamp-value pairs for range queries
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub values: Vec<(i64, f64)>,
    /// Single value for instant queries
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<(i64, f64)>,
}

/// Convert time-series aggregates to TimeSeriesData format
pub fn convert_time_series(aggregates: Vec<TimeSeriesAggregate>) -> TimeSeriesData {
    if aggregates.is_empty() {
        return TimeSeriesData {
            timestamps: Vec::new(),
            values: Vec::new(),
            labels: Vec::new(),
            series_name: String::new(),
        };
    }

    let mut timestamps = Vec::with_capacity(aggregates.len());
    let mut values = Vec::with_capacity(aggregates.len());

    // Extract series name from first aggregate tags
    let series_name = aggregates
        .first()
        .and_then(|first_agg| {
            first_agg.tags.get("series")
                .or_else(|| first_agg.tags.get("name"))
        })
        .cloned()
        .unwrap_or_else(|| "series".to_string());

    for aggregate in &aggregates {
        timestamps.push(aggregate.window.end);
        values.push(aggregate.value);
    }

    TimeSeriesData {
        timestamps,
        values,
        labels: Vec::new(),
        series_name,
    }
}

/// Compute trend indicator between two values
pub fn compute_trend(current: f64, previous: f64, period: String) -> Option<Trend> {
    // If previous is zero or NaN, return None
    if previous == 0.0 || !previous.is_finite() || !current.is_finite() {
        return None;
    }

    // Compute percent change
    let magnitude = ((current - previous) / previous) * 100.0;

    // Determine direction
    let direction = if magnitude > 5.0 {
        TrendDirection::Up
    } else if magnitude < -5.0 {
        TrendDirection::Down
    } else {
        TrendDirection::Flat
    };

    Trend::new(direction, magnitude, period).ok()
}

/// Generate Chart.js JSON configuration
pub fn generate_chart_js(config: &ChartConfig, series: &[DataSeries]) -> Result<String, TimeSeriesError> {
    if series.is_empty() {
        return Err(TimeSeriesError::InvalidWindow("Empty series".to_string()));
    }

    // Extract x-axis labels from first series or use indices
    let first_series = series.first();
    let labels: Vec<String> = first_series
        .and_then(|s| s.data.first())
        .map(|p| {
            if let Some(ref label) = p.label {
                vec![label.clone()]
            } else {
                // Generate index-based labels
                let len = first_series.map(|s| s.data.len()).unwrap_or(0);
                (0..len).map(|i| i.to_string()).collect()
            }
        })
        .unwrap_or_default();

    // If first point has label, use all labels
    let labels = if first_series.and_then(|s| s.data.first()).is_some() {
        first_series
            .unwrap()
            .data
            .iter()
            .map(|p| {
                p.label
                    .as_ref()
                    .cloned()
                    .unwrap_or_else(|| p.x.to_string())
            })
            .collect()
    } else {
        labels
    };

    // Validate series lengths match
    let expected_len = labels.len();
    for s in series {
        if s.data.len() != expected_len && !s.data.is_empty() {
            return Err(TimeSeriesError::InvalidWindow(
                "Series have mismatched lengths".to_string(),
            ));
        }
    }

    // Create datasets
    let datasets: Vec<ChartJsDataset> = series
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let data: Vec<f64> = s.data.iter().map(|p| p.y).collect();
            visualization_theme::chart_js_dataset_with_theme(
                s.name.clone(),
                data,
                &config.theme,
                i,
            )
        })
        .collect();

    // Build options
    let colors = match &config.theme {
        ChartTheme::Light => ThemeColors::light(),
        ChartTheme::Dark => ThemeColors::dark(),
        ChartTheme::Custom(c) => c.clone(),
    };

    let options = ChartJsOptions {
        responsive: true,
        maintain_aspect_ratio: true,
        plugins: ChartJsPlugins {
            legend: ChartJsLegend {
                display: true,
                position: "top".to_string(),
            },
            title: ChartJsTitle {
                display: !config.title.is_empty(),
                text: config.title.clone(),
            },
            tooltip: ChartJsTooltip {
                enabled: config.interactive,
                mode: "index".to_string(),
                intersect: false,
            },
        },
        scales: Some(ChartJsScales {
            x: ChartJsAxis {
                title: if config.x_axis_label.is_empty() {
                    None
                } else {
                    Some(ChartJsAxisTitle {
                        display: true,
                        text: config.x_axis_label.clone(),
                    })
                },
                axis_type: "category".to_string(),
                position: "bottom".to_string(),
                grid: ChartJsGrid { display: true },
            },
            y: vec![ChartJsAxis {
                title: if config.y_axis_label.is_empty() {
                    None
                } else {
                    Some(ChartJsAxisTitle {
                        display: true,
                        text: config.y_axis_label.clone(),
                    })
                },
                axis_type: "linear".to_string(),
                position: "left".to_string(),
                grid: ChartJsGrid { display: true },
            }],
        }),
    };

    let chart_data = ChartJsData {
        labels,
        datasets,
        options,
    };

    serde_json::to_string_pretty(&chart_data)
        .map_err(|e| TimeSeriesError::InvalidWindow(format!("Failed to serialize: {}", e)))
}

/// Generate Plotly.js JSON configuration
pub fn generate_plotly(config: &ChartConfig, series: &[DataSeries]) -> Result<String, TimeSeriesError> {
    if series.is_empty() {
        return Err(TimeSeriesError::InvalidWindow("Empty series".to_string()));
    }

    let colors = match &config.theme {
        ChartTheme::Light => ThemeColors::light(),
        ChartTheme::Dark => ThemeColors::dark(),
        ChartTheme::Custom(c) => c.clone(),
    };

    // Create traces
    let data: Vec<PlotlyTrace> = series
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let x: Vec<f64> = s.data.iter().map(|p| p.x).collect();
            let y: Vec<f64> = s.data.iter().map(|p| p.y).collect();

            visualization_theme::plotly_trace_with_theme(
                s.name.clone(),
                x,
                y,
                config.chart_type.to_string(),
                trace_mode_for_type(config.chart_type),
                &config.theme,
                i,
            )
        })
        .collect();

    // Build layout
    let layout = PlotlyLayout {
        title: PlotlyTitle {
            text: config.title.clone(),
        },
        xaxis: PlotlyAxis {
            title: PlotlyAxisTitle {
                text: if config.x_axis_label.is_empty() {
                    "X".to_string()
                } else {
                    config.x_axis_label.clone()
                },
            },
            axis_type: axis_type_for_type(config.chart_type).to_string(),
            gridcolor: Some(colors.grid.clone()),
            zerolinecolor: Some(colors.axis.clone()),
        },
        yaxis: PlotlyAxis {
            title: PlotlyAxisTitle {
                text: if config.y_axis_label.is_empty() {
                    "Y".to_string()
                } else {
                    config.y_axis_label.clone()
                },
            },
            axis_type: "linear".to_string(),
            gridcolor: Some(colors.grid.clone()),
            zerolinecolor: Some(colors.axis.clone()),
        },
        showlegend: series.len() > 1,
    };

    let plotly_config = PlotlyConfig {
        responsive: true,
        display_mode_bar: config.interactive,
    };

    let plotly_data = PlotlyData {
        data,
        layout,
        config: plotly_config,
    };

    serde_json::to_string_pretty(&plotly_data)
        .map_err(|e| TimeSeriesError::InvalidWindow(format!("Failed to serialize: {}", e)))
}

/// Get trace mode for chart type
fn trace_mode_for_type(chart_type: ChartType) -> String {
    match chart_type {
        ChartType::Line => "lines".to_string(),
        ChartType::Scatter => "markers".to_string(),
        ChartType::Area => "lines".to_string(),
        _ => "lines+markers".to_string(),
    }
}

/// Get axis type for chart type
fn axis_type_for_type(chart_type: ChartType) -> &'static str {
    match chart_type {
        ChartType::Line | ChartType::Scatter | ChartType::Area => "linear",
        ChartType::Histogram => "linear",
        _ => "category",
    }
}

/// Generate CSV format for spreadsheet tools
pub fn generate_csv(series: &[DataSeries]) -> String {
    if series.is_empty() {
        return String::new();
    }

    let mut csv = String::new();

    // Write header row: Timestamp,Series1,Series2,...
    csv.push_str("Timestamp");
    for s in series {
        csv.push_str(",");
        csv.push_str(&escape_csv_field(&s.name));
    }
    csv.push_str("\n");

    // Find max length across all series
    let max_len = series.iter().map(|s| s.data.len()).max().unwrap_or(0);

    // For each index, write a row
    for i in 0..max_len {
        // Get timestamp from first series (or index if missing)
        let timestamp = series
            .first()
            .and_then(|s| s.data.get(i))
            .map(|p| p.x.to_string())
            .unwrap_or_else(|| i.to_string());

        csv.push_str(&timestamp);

        // Write each series value or empty string if missing
        for s in series {
            csv.push_str(",");
            let value = s.data.get(i).map(|p| p.y.to_string()).unwrap_or_default();
            csv.push_str(&value);
        }

        csv.push_str("\n");
    }

    csv
}

/// Escape CSV field if needed
fn escape_csv_field(field: &str) -> String {
    if field.contains(',') || field.contains('"') || field.contains('\n') {
        let escaped = field.replace("\"", "\"\"");
        format!("\"{}\"", escaped)
    } else {
        field.to_string()
    }
}

/// Generate histogram data for distribution visualization
pub fn generate_histogram(data: &[f64], bucket_count: usize) -> Result<HistogramData, TimeSeriesError> {
    if data.is_empty() {
        return Err(TimeSeriesError::InvalidWindow("Empty data".to_string()));
    }

    if bucket_count == 0 {
        return Err(TimeSeriesError::InvalidWindow("bucket_count must be > 0".to_string()));
    }

    // Find min and max values
    let min_val = data.iter().cloned().reduce(f64::min).unwrap();
    let max_val = data.iter().cloned().reduce(f64::max).unwrap();

    // Compute bucket width
    let bucket_width = (max_val - min_val) / bucket_count as f64;

    // Handle case where all values are the same
    let bucket_width = if bucket_width == 0.0 {
        1.0
    } else {
        bucket_width
    };

    // Initialize bucket counts
    let mut bucket_counts = vec![0usize; bucket_count];

    // Count values in each bucket
    for &value in data {
        let bucket_index = ((value - min_val) / bucket_width).floor() as usize;
        let bucket_index = bucket_index.min(bucket_count - 1);
        bucket_counts[bucket_index] += 1;
    }

    // Compute statistics
    let sum: f64 = data.iter().sum();
    let count = data.len();
    let mean = sum / count as f64;

    let mut sorted_data = data.to_vec();
    sorted_data.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = if count % 2 == 0 {
        (sorted_data[count / 2 - 1] + sorted_data[count / 2]) / 2.0
    } else {
        sorted_data[count / 2]
    };

    let variance = data.iter().map(|&x| (x - mean).powi(2)).sum::<f64>() / count as f64;
    let stddev = variance.sqrt();

    // Build histogram buckets
    let mut buckets = Vec::with_capacity(bucket_count);
    for (i, &bucket_count_i) in bucket_counts.iter().enumerate() {
        let lower_bound = min_val + (i as f64) * bucket_width;
        let upper_bound = lower_bound + bucket_width;
        let percentage = bucket_count_i as f64 / count as f64;

        buckets.push(HistogramBucket {
            lower_bound,
            upper_bound,
            count: bucket_count_i,
            percentage,
        });
    }

    HistogramData::new(
        buckets,
        count,
        mean,
        median,
        stddev,
        min_val,
        max_val,
    )
}

/// Generate 2D heatmap from 3D data points
pub fn generate_heatmap(
    x_values: &[f64],
    y_values: &[f64],
    z_values: &[f64],
    x_bins: usize,
    y_bins: usize,
) -> Result<HeatmapData, TimeSeriesError> {
    if x_values.len() != y_values.len() || y_values.len() != z_values.len() {
        return Err(TimeSeriesError::InvalidWindow(
            "x_values, y_values, and z_values must have same length".to_string(),
        ));
    }

    if x_values.is_empty() {
        return Err(TimeSeriesError::InvalidWindow("Empty data".to_string()));
    }

    if x_bins == 0 || y_bins == 0 {
        return Err(TimeSeriesError::InvalidWindow(
            "x_bins and y_bins must be > 0".to_string(),
        ));
    }

    // Find x and y ranges
    let x_min = x_values.iter().cloned().reduce(f64::min).unwrap();
    let x_max = x_values.iter().cloned().reduce(f64::max).unwrap();
    let y_min = y_values.iter().cloned().reduce(f64::min).unwrap();
    let y_max = y_values.iter().cloned().reduce(f64::max).unwrap();

    let x_range = x_max - x_min;
    let y_range = y_max - y_min;

    // Handle case where range is zero
    let x_range = if x_range == 0.0 { 1.0 } else { x_range };
    let y_range = if y_range == 0.0 { 1.0 } else { y_range };

    // Initialize 2D grid with zeros and counts
    let mut grid = vec![vec![0.0f64; x_bins]; y_bins];
    let mut counts = vec![vec![0usize; x_bins]; y_bins];

    // Accumulate z values in grid
    for i in 0..x_values.len() {
        let x = x_values[i];
        let y = y_values[i];
        let z = z_values[i];

        let x_bin = ((x - x_min) / x_range * x_bins as f64).floor() as usize;
        let y_bin = ((y - y_min) / y_range * y_bins as f64).floor() as usize;

        let x_bin = x_bin.min(x_bins - 1);
        let y_bin = y_bin.min(y_bins - 1);

        grid[y_bin][x_bin] += z;
        counts[y_bin][x_bin] += 1;
    }

    // Average the z values
    for y in 0..y_bins {
        for x in 0..x_bins {
            if counts[y][x] > 0 {
                grid[y][x] /= counts[y][x] as f64;
            } else {
                grid[y][x] = f64::NAN;
            }
        }
    }

    // Generate axis labels
    let x_labels = (0..x_bins)
        .map(|i| {
            let val = x_min + (i as f64 + 0.5) * x_range / x_bins as f64;
            format!("{:.2}", val)
        })
        .collect();

    let y_labels = (0..y_bins)
        .map(|i| {
            let val = y_min + (i as f64 + 0.5) * y_range / y_bins as f64;
            format!("{:.2}", val)
        })
        .collect();

    Ok(HeatmapData {
        x_labels,
        y_labels,
        values: grid,
        x_title: String::new(),
        y_title: String::new(),
        color_scale: ColorScale::Sequential("#ffffff".to_string(), "#0000ff".to_string()),
    })
}

/// Generate Prometheus matrix query result format
pub fn generate_prometheus_matrix(series: Vec<TimeSeriesData>) -> PrometheusResult {
    let result = series
        .into_iter()
        .map(|ts| {
            let metric = {
                let mut m = HashMap::new();
                m.insert("__name__".to_string(), ts.series_name.clone());
                m
            };

            let values: Vec<(i64, f64)> = ts
                .timestamps
                .into_iter()
                .zip(ts.values.into_iter())
                .collect();

            PrometheusSeries {
                metric,
                values,
                value: None,
            }
        })
        .collect();

    PrometheusResult {
        result_type: "matrix".to_string(),
        result,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_data_point_creation() {
        let point = DataPoint::new(1.0, 2.0).unwrap();
        assert_eq!(point.x, 1.0);
        assert_eq!(point.y, 2.0);
    }

    #[test]
    fn test_data_point_invalid() {
        let result = DataPoint::new(f64::NAN, 2.0);
        assert!(result.is_err());
    }

    #[test]
    fn test_data_series_creation() {
        let data = vec![DataPoint::new(1.0, 2.0).unwrap()];
        let series = DataSeries::new("test".to_string(), data).unwrap();
        assert_eq!(series.name, "test");
        assert_eq!(series.data.len(), 1);
    }

    #[test]
    fn test_time_series_data_creation() {
        let timestamps = vec![1000, 2000, 3000];
        let values = vec![1.0, 2.0, 3.0];
        let ts = TimeSeriesData::new(timestamps, values, "test".to_string()).unwrap();
        assert_eq!(ts.timestamps.len(), 3);
        assert_eq!(ts.series_name, "test");
    }

    #[test]
    fn test_time_series_data_invalid_lengths() {
        let timestamps = vec![1000, 2000];
        let values = vec![1.0, 2.0, 3.0];
        let result = TimeSeriesData::new(timestamps, values, "test".to_string());
        assert!(result.is_err());
    }

    #[test]
    fn test_time_series_data_not_monotonic() {
        let timestamps = vec![1000, 2000, 1500];
        let values = vec![1.0, 2.0, 3.0];
        let result = TimeSeriesData::new(timestamps, values, "test".to_string());
        assert!(result.is_err());
    }

    #[test]
    fn test_histogram_bucket_creation() {
        let bucket = HistogramBucket::new(0.0, 10.0, 5, 100).unwrap();
        assert_eq!(bucket.lower_bound, 0.0);
        assert_eq!(bucket.upper_bound, 10.0);
        assert_eq!(bucket.count, 5);
        assert_eq!(bucket.percentage, 0.05);
    }

    #[test]
    fn test_histogram_bucket_invalid_bounds() {
        let result = HistogramBucket::new(10.0, 0.0, 5, 100);
        assert!(result.is_err());
    }

    #[test]
    fn test_gauge_data_creation() {
        let thresholds = vec![
            GaugeThreshold::new(50.0, "green".to_string(), "OK".to_string()),
            GaugeThreshold::new(80.0, "yellow".to_string(), "Warning".to_string()),
        ];
        let gauge = GaugeData::new(75.0, 0.0, 100.0, "Test".to_string(), thresholds).unwrap();
        assert_eq!(gauge.value, 75.0);
        assert_eq!(gauge.min, 0.0);
        assert_eq!(gauge.max, 100.0);
    }

    #[test]
    fn test_gauge_data_value_out_of_range() {
        let thresholds = vec![];
        let result = GaugeData::new(150.0, 0.0, 100.0, "Test".to_string(), thresholds);
        assert!(result.is_err());
    }

    #[test]
    fn test_chart_config_builder() {
        let config = ChartConfig::new(ChartType::Line, "Test Chart".to_string())
            .with_axes("Time".to_string(), "Value".to_string())
            .with_dimensions(800, 600)
            .with_interactive(false)
            .with_theme(ChartTheme::Dark);

        assert_eq!(config.chart_type, ChartType::Line);
        assert_eq!(config.title, "Test Chart");
        assert_eq!(config.x_axis_label, "Time");
        assert_eq!(config.y_axis_label, "Value");
        assert_eq!(config.width, Some(800));
        assert_eq!(config.height, Some(600));
        assert!(!config.interactive);
        assert_eq!(config.theme, ChartTheme::Dark);
    }

    #[test]
    fn test_column_definition_builder() {
        let col = ColumnDefinition::new("Name".to_string(), ColumnType::String)
            .with_sortable(true)
            .with_filterable(true)
            .with_width(200);

        assert!(col.sortable);
        assert!(col.filterable);
        assert_eq!(col.width, Some(200));
    }

    #[test]
    fn test_pagination_info_creation() {
        let info = PaginationInfo::new(1, 10, 50, 500).unwrap();
        assert_eq!(info.current_page, 1);
        assert_eq!(info.total_pages, 10);
        assert_eq!(info.page_size, 50);
        assert_eq!(info.total_items, 500);
    }

    #[test]
    fn test_pagination_info_invalid_page() {
        let result = PaginationInfo::new(0, 10, 50, 500);
        assert!(result.is_err());
    }

    #[test]
    fn test_table_data_creation() {
        let columns = vec![
            ColumnDefinition::new("Name".to_string(), ColumnType::String),
            ColumnDefinition::new("Value".to_string(), ColumnType::Number),
        ];
        let rows = vec![
            vec![TableCell::String("Test".to_string()), TableCell::Number(42.0)],
        ];
        let table = TableData::new(columns, rows, None).unwrap();
        assert_eq!(table.columns.len(), 2);
        assert_eq!(table.rows.len(), 1);
    }

    #[test]
    fn test_table_data_mismatched_columns() {
        let columns = vec![
            ColumnDefinition::new("Name".to_string(), ColumnType::String),
            ColumnDefinition::new("Value".to_string(), ColumnType::Number),
        ];
        let rows = vec![
            vec![TableCell::String("Test".to_string())],
        ];
        let result = TableData::new(columns, rows, None);
        assert!(result.is_err());
    }

    #[test]
    fn test_compute_trend_up() {
        let trend = compute_trend(110.0, 100.0, "1h".to_string());
        assert!(trend.is_some());
        assert_eq!(trend.as_ref().unwrap().direction, TrendDirection::Up);
    }

    #[test]
    fn test_compute_trend_down() {
        let trend = compute_trend(90.0, 100.0, "1h".to_string());
        assert!(trend.is_some());
        assert_eq!(trend.as_ref().unwrap().direction, TrendDirection::Down);
    }

    #[test]
    fn test_compute_trend_flat() {
        let trend = compute_trend(102.0, 100.0, "1h".to_string());
        assert!(trend.is_some());
        assert_eq!(trend.as_ref().unwrap().direction, TrendDirection::Flat);
    }

    #[test]
    fn test_compute_trend_invalid_previous() {
        let trend = compute_trend(100.0, 0.0, "1h".to_string());
        assert!(trend.is_none());
    }

    #[test]
    fn test_convert_time_series() {
        use crate::analytics::types::{TimeWindow, AggregateFunction};

        let aggregates = vec![
            TimeSeriesAggregate {
                window: TimeWindow::new(0, 1000).unwrap(),
                function: AggregateFunction::Avg,
                value: 10.0,
                count: 1,
                tags: {
                    let mut tags = HashMap::new();
                    tags.insert("series".to_string(), "test".to_string());
                    tags
                },
            },
            TimeSeriesAggregate {
                window: TimeWindow::new(1000, 2000).unwrap(),
                function: AggregateFunction::Avg,
                value: 20.0,
                count: 1,
                tags: {
                    let mut tags = HashMap::new();
                    tags.insert("series".to_string(), "test".to_string());
                    tags
                },
            },
        ];

        let ts = convert_time_series(aggregates);
        assert_eq!(ts.timestamps.len(), 2);
        assert_eq!(ts.values, vec![10.0, 20.0]);
        assert_eq!(ts.series_name, "test");
    }

    #[test]
    fn test_generate_chart_js() {
        let data = vec![DataPoint::new(1.0, 2.0).unwrap(), DataPoint::new(2.0, 4.0).unwrap()];
        let series = vec![DataSeries::new("Test".to_string(), data).unwrap()];
        let config = ChartConfig::new(ChartType::Line, "Test Chart".to_string());

        let result = generate_chart_js(&config, &series);
        assert!(result.is_ok());

        let json = result.unwrap();
        assert!(json.contains("Test Chart"));
        assert!(json.contains("Test"));
    }

    #[test]
    fn test_generate_chart_js_empty_series() {
        let series = vec![];
        let config = ChartConfig::new(ChartType::Line, "Test".to_string());

        let result = generate_chart_js(&config, &series);
        assert!(result.is_err());
    }

    #[test]
    fn test_generate_plotly() {
        let data = vec![DataPoint::new(1.0, 2.0).unwrap(), DataPoint::new(2.0, 4.0).unwrap()];
        let series = vec![DataSeries::new("Test".to_string(), data).unwrap()];
        let config = ChartConfig::new(ChartType::Line, "Test Chart".to_string());

        let result = generate_plotly(&config, &series);
        assert!(result.is_ok());

        let json = result.unwrap();
        assert!(json.contains("Test Chart"));
        assert!(json.contains("Test"));
    }

    #[test]
    fn test_generate_csv() {
        let data1 = vec![DataPoint::new(1.0, 10.0).unwrap(), DataPoint::new(2.0, 20.0).unwrap()];
        let data2 = vec![DataPoint::new(1.0, 15.0).unwrap(), DataPoint::new(2.0, 25.0).unwrap()];
        let series = vec![
            DataSeries::new("Series1".to_string(), data1).unwrap(),
            DataSeries::new("Series2".to_string(), data2).unwrap(),
        ];

        let csv = generate_csv(&series);
        assert!(csv.contains("Timestamp"));
        assert!(csv.contains("Series1"));
        assert!(csv.contains("Series2"));
    }

    #[test]
    fn test_generate_csv_empty_series() {
        let series = vec![];
        let csv = generate_csv(&series);
        assert!(csv.is_empty());
    }

    #[test]
    fn test_generate_csv_escape_quotes() {
        let data = vec![DataPoint::new(1.0, 10.0).unwrap()];
        let series = vec![DataSeries::new("Series,With,Commas".to_string(), data).unwrap()];

        let csv = generate_csv(&series);
        assert!(csv.contains("\"Series,With,Commas\""));
    }

    #[test]
    fn test_generate_histogram() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let histogram = generate_histogram(&data, 5).unwrap();

        assert_eq!(histogram.total_count, 5);
        assert_eq!(histogram.buckets.len(), 5);
        assert_eq!(histogram.min, 1.0);
        assert_eq!(histogram.max, 5.0);
    }

    #[test]
    fn test_generate_histogram_empty() {
        let data = vec![];
        let result = generate_histogram(&data, 5);
        assert!(result.is_err());
    }

    #[test]
    fn test_generate_histogram_zero_buckets() {
        let data = vec![1.0, 2.0, 3.0];
        let result = generate_histogram(&data, 0);
        assert!(result.is_err());
    }

    #[test]
    fn test_generate_heatmap() {
        let x_values = vec![1.0, 2.0, 3.0];
        let y_values = vec![1.0, 2.0, 3.0];
        let z_values = vec![10.0, 20.0, 30.0];

        let heatmap = generate_heatmap(&x_values, &y_values, &z_values, 2, 2).unwrap();

        assert_eq!(heatmap.x_labels.len(), 2);
        assert_eq!(heatmap.y_labels.len(), 2);
        assert_eq!(heatmap.values.len(), 2);
        assert_eq!(heatmap.values[0].len(), 2);
    }

    #[test]
    fn test_generate_heatmap_mismatched_lengths() {
        let x_values = vec![1.0, 2.0, 3.0];
        let y_values = vec![1.0, 2.0];
        let z_values = vec![10.0, 20.0, 30.0];

        let result = generate_heatmap(&x_values, &y_values, &z_values, 2, 2);
        assert!(result.is_err());
    }

    #[test]
    fn test_generate_heatmap_empty() {
        let x_values = vec![];
        let y_values = vec![];
        let z_values = vec![];

        let result = generate_heatmap(&x_values, &y_values, &z_values, 2, 2);
        assert!(result.is_err());
    }

    #[test]
    fn test_generate_prometheus_matrix() {
        let ts_data = vec![
            TimeSeriesData {
                timestamps: vec![1000, 2000],
                values: vec![10.0, 20.0],
                labels: vec![],
                series_name: "metric1".to_string(),
            },
            TimeSeriesData {
                timestamps: vec![1000, 2000],
                values: vec![15.0, 25.0],
                labels: vec![],
                series_name: "metric2".to_string(),
            },
        ];

        let prometheus = generate_prometheus_matrix(ts_data);
        assert_eq!(prometheus.result_type, "matrix");
        assert_eq!(prometheus.result.len(), 2);
        assert!(prometheus.result[0].metric.contains_key("__name__"));
    }

    #[test]
    fn test_escape_csv_field() {
        assert_eq!(escape_csv_field("simple"), "simple");
        assert_eq!(escape_csv_field("with,comma"), "\"with,comma\"");
        assert_eq!(escape_csv_field("with\"quote"), "\"with\"\"quote\"");
        assert_eq!(escape_csv_field("with\nnewline"), "\"with\nnewline\"");
    }
}
