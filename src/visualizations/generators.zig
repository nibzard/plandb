//! Visualization data generators for NorthstarDB analytics
//!
//! Generates JSON data for common chart libraries:
//! - Line charts for time-series data
//! - Heatmaps for 2D metric distributions
//! - Histograms for value distributions
//! - Scatter plots for correlation analysis

const std = @import("std");

const analytics = @import("../queries/analytics.zig");

/// Chart types supported
pub const ChartType = enum {
    line,
    area,
    bar,
    scatter,
    heatmap,
    histogram,
    pie,
};

/// Chart library target format
pub const ChartLibrary = enum {
    chart_js,
    d3,
    vega,
    plotly,
    echarts,
};

/// Data point for time-series charts
pub const DataPoint = struct {
    x: f64, // Timestamp or X value
    y: f64, // Y value
    label: ?[]const u8 = null,

    pub fn deinit(self: DataPoint, allocator: std.mem.Allocator) void {
        if (self.label) |l| allocator.free(l);
    }
};

/// Data series for multi-series charts
pub const DataSeries = struct {
    name: []const u8,
    points: []const DataPoint,
    color: ?[]const u8 = null,

    pub fn deinit(self: DataSeries, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.points) |*p| p.deinit(allocator);
        allocator.free(self.points);
        if (self.color) |c| allocator.free(c);
    }
};

/// Heatmap data point
pub const HeatmapPoint = struct {
    x: f64,
    y: f64,
    value: f64,
    label: ?[]const u8 = null,

    pub fn deinit(self: HeatmapPoint, allocator: std.mem.Allocator) void {
        if (self.label) |l| allocator.free(l);
    }
};

/// Histogram bin
pub const HistogramBin = struct {
    min: f64,
    max: f64,
    count: u64,
    percentage: f64,
};

/// Generated chart data
pub const ChartData = struct {
    chart_type: ChartType,
    title: ?[]const u8,
    x_axis_label: ?[]const u8,
    y_axis_label: ?[]const u8,
    series: []const DataSeries,
    /// Additional metadata
    metadata: std.StringHashMap([]const u8),

    pub fn deinit(self: ChartData, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.x_axis_label) |l| allocator.free(l);
        if (self.y_axis_label) |l| allocator.free(l);
        for (self.series) |*s| s.deinit(allocator);
        allocator.free(self.series);

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Heatmap data structure
pub const HeatmapData = struct {
    title: ?[]const u8,
    x_axis_label: ?[]const u8,
    y_axis_label: ?[]const u8,
    points: []const HeatmapPoint,
    x_min: f64,
    x_max: f64,
    y_min: f64,
    y_max: f64,

    pub fn deinit(self: HeatmapData, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.x_axis_label) |l| allocator.free(l);
        if (self.y_axis_label) |l| allocator.free(l);
        for (self.points) |*p| p.deinit(allocator);
        allocator.free(self.points);
    }
};

/// Histogram data structure
pub const HistogramData = struct {
    title: ?[]const u8,
    x_axis_label: ?[]const u8,
    y_axis_label: []const u8,
    bins: []const HistogramBin,
    min: f64,
    max: f64,
    mean: f64,
    median: f64,

    pub fn deinit(self: HistogramData, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.x_axis_label) |l| allocator.free(l);
        allocator.free(self.y_axis_label);
        allocator.free(self.bins);
    }
};

/// Visualization generator
pub const VisualizationGenerator = struct {
    allocator: std.mem.Allocator,
    analytics_engine: *analytics.AnalyticsEngine,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        analytics_engine: *analytics.AnalyticsEngine,
    ) Self {
        return Self{
            .allocator = allocator,
            .analytics_engine = analytics_engine,
        };
    }

    /// Generate line chart from aggregation result
    pub fn generateLineChart(
        self: *Self,
        result: analytics.AggregationResult,
        config: ChartConfig,
    ) !ChartData {
        var series_list = std.ArrayList(DataSeries).init(self.allocator, {});

        // Extract values for first aggregation function
        if (result.buckets.len == 0) {
            return ChartData{
                .chart_type = .line,
                .title = if (config.title) |t| try self.allocator.dupe(u8, t) else null,
                .x_axis_label = if (config.x_label) |l| try self.allocator.dupe(u8, l) else null,
                .y_axis_label = if (config.y_label) |l| try self.allocator.dupe(u8, l) else null,
                .series = &.{},
                .metadata = std.StringHashMap([]const u8).init(self.allocator),
            };
        }

        const func_idx = 0; // First function
        var points = std.ArrayList(DataPoint).init(self.allocator, {});

        for (result.buckets) |bucket| {
            if (func_idx < bucket.values.len) {
                const point = DataPoint{
                    .x = @floatFromInt(bucket.timestamp_ms),
                    .y = bucket.values[func_idx],
                    .label = null,
                };
                try points.append(point);
            }
        }

        const series = DataSeries{
            .name = try self.allocator.dupe(u8, "metric"),
            .points = try points.toOwnedSlice(),
            .color = if (config.color) |c| try self.allocator.dupe(u8, c) else null,
        };
        try series_list.append(series);

        return ChartData{
            .chart_type = .line,
            .title = if (config.title) |t| try self.allocator.dupe(u8, t) else null,
            .x_axis_label = if (config.x_label) |l| try self.allocator.dupe(u8, l) else null,
            .y_axis_label = if (config.y_label) |l| try self.allocator.dupe(u8, l) else null,
            .series = try series_list.toOwnedSlice(),
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };
    }

    /// Generate heatmap from correlation data
    pub fn generateHeatmap(
        self: *Self,
        x_values: []const f64,
        y_values: []const f64,
        values: []const f64,
        config: HeatmapConfig,
    ) !HeatmapData {
        if (x_values.len != y_values.len or x_values.len != values.len) {
            return error.DimensionMismatch;
        }

        var points = std.ArrayList(HeatmapPoint).init(self.allocator, {});

        for (x_values, y_values, values) |x, y, v| {
            const point = HeatmapPoint{
                .x = x,
                .y = y,
                .value = v,
                .label = null,
            };
            try points.append(point);
        }

        var x_min: f64 = std.math.inf(f32);
        var x_max: f64 = -std.math.inf(f32);
        var y_min: f64 = std.math.inf(f32);
        var y_max: f64 = -std.math.inf(f32);

        for (x_values) |x| {
            x_min = @min(x_min, x);
            x_max = @max(x_max, x);
        }
        for (y_values) |y| {
            y_min = @min(y_min, y);
            y_max = @max(y_max, y);
        }

        return HeatmapData{
            .title = if (config.title) |t| try self.allocator.dupe(u8, t) else null,
            .x_axis_label = if (config.x_label) |l| try self.allocator.dupe(u8, l) else null,
            .y_axis_label = if (config.y_label) |l| try self.allocator.dupe(u8, l) else null,
            .points = try points.toOwnedSlice(),
            .x_min = x_min,
            .x_max = x_max,
            .y_min = y_min,
            .y_max = y_max,
        };
    }

    /// Generate histogram from raw values
    pub fn generateHistogram(
        self: *Self,
        values: []const f64,
        config: HistogramConfig,
    ) !HistogramData {
        if (values.len == 0) {
            return HistogramData{
                .title = if (config.title) |t| try self.allocator.dupe(u8, t) else null,
                .x_axis_label = if (config.x_label) |l| try self.allocator.dupe(u8, l) else null,
                .y_axis_label = try self.allocator.dupe(u8, "Count"),
                .bins = &.{},
                .min = 0,
                .max = 0,
                .mean = 0,
                .median = 0,
            };
        }

        // Find min/max
        var min_val: f64 = std.math.inf(f32);
        var max_val: f64 = -std.math.inf(f32);
        var sum: f64 = 0;

        for (values) |v| {
            min_val = @min(min_val, v);
            max_val = @max(max_val, v);
            sum += v;
        }

        const mean = sum / @as(f64, @floatFromInt(values.len));

        // Compute median
        const median = analytics.AnalyticsEngine.computePercentile(values, 50.0);

        // Create bins
        const num_bins = config.num_bins orelse @max(10, @as(usize, @intFromFloat(@sqrt(@as(f64, @floatFromInt(values.len))))));
        const bin_width = (max_val - min_val) / @as(f64, @floatFromInt(num_bins));

        var bins = std.ArrayList(HistogramBin).init(self.allocator, {});
        var bin_counts = std.ArrayList(u64).init(self.allocator, {});

        // Initialize bins
        for (0..num_bins) |_| {
            try bin_counts.append(0);
        }

        // Fill bins
        for (values) |v| {
            const bin_idx = @min(
                @as(usize, @intFromFloat((v - min_val) / bin_width)),
                num_bins - 1,
            );
            bin_counts.items[bin_idx] += 1;
        }

        // Create HistogramBin structs
        for (bin_counts.items, 0..) |count, i| {
            const bin_min = min_val + (@as(f64, @floatFromInt(i)) * bin_width);
            const bin_max = bin_min + bin_width;
            const percentage = if (values.len > 0)
                @as(f64, @floatFromInt(count)) * 100.0 / @as(f64, @floatFromInt(values.len))
            else
                0.0;

            try bins.append(.{
                .min = bin_min,
                .max = bin_max,
                .count = count,
                .percentage = percentage,
            });
        }

        return HistogramData{
            .title = if (config.title) |t| try self.allocator.dupe(u8, t) else null,
            .x_axis_label = if (config.x_label) |l| try self.allocator.dupe(u8, l) else null,
            .y_axis_label = try self.allocator.dupe(u8, "Count"),
            .bins = try bins.toOwnedSlice(),
            .min = min_val,
            .max = max_val,
            .mean = mean,
            .median = median,
        };
    }

    /// Export chart data as JSON for specific library
    pub fn exportToJson(
        self: *Self,
        chart_data: ChartData,
        library: ChartLibrary,
    ) ![]const u8 {
        return switch (library) {
            .chart_js => self.exportChartJs(chart_data),
            .d3 => self.exportD3(chart_data),
            .vega => self.exportVega(chart_data),
            .plotly => self.exportPlotly(chart_data),
            .echarts => self.exportECharts(chart_data),
        };
    }

    fn exportChartJs(self: *Self, data: ChartData) ![]const u8 {
        var json = std.ArrayList(u8).init(self.allocator, {});

        try json.append('{');

        if (data.title) |title| {
            try json.appendSlice("\"title\":\"");
            try json.appendSlice(title);
            try json.appendSlice("\",");
        }

        try json.appendSlice("\"type\":\"");
        try json.appendSlice(@tagName(data.chart_type));
        try json.appendSlice("\",");

        try json.appendSlice("\"datasets\":[");

        for (data.series, 0..) |series, i| {
            if (i > 0) try json.append(',');

            try json.appendSlice("{\"label\":\"");
            try json.appendSlice(series.name);
            try json.appendSlice("\",\"data\":[");

            for (series.points, 0..) |point, j| {
                if (j > 0) try json.append(',');
                try json.appendSlice("{\"x\":");
                try std.fmt.formatJsonFloat(point.x, .{}, json.writer());
                try json.appendSlice(",\"y\":");
                try std.fmt.formatJsonFloat(point.y, .{}, json.writer());
                try json.append('}');
            }

            try json.appendSlice("]}");
        }

        try json.appendSlice("]}");

        return json.toOwnedSlice();
    }

    fn exportD3(self: *Self, data: ChartData) ![]const u8 {
        _ = self;
        _ = data;
        return error.NotImplemented;
    }

    fn exportVega(self: *Self, data: ChartData) ![]const u8 {
        _ = self;
        _ = data;
        return error.NotImplemented;
    }

    fn exportPlotly(self: *Self, data: ChartData) ![]const u8 {
        _ = self;
        _ = data;
        return error.NotImplemented;
    }

    fn exportECharts(self: *Self, data: ChartData) ![]const u8 {
        _ = self;
        _ = data;
        return error.NotImplemented;
    }
};

/// Chart generation configuration
pub const ChartConfig = struct {
    title: ?[]const u8 = null,
    x_label: ?[]const u8 = null,
    y_label: ?[]const u8 = null,
    color: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

/// Heatmap configuration
pub const HeatmapConfig = struct {
    title: ?[]const u8 = null,
    x_label: ?[]const u8 = null,
    y_label: ?[]const u8 = null,
    color_scale: []const u8 = "heatmap", // or "viridis", "plasma", etc.
};

/// Histogram configuration
pub const HistogramConfig = struct {
    title: ?[]const u8 = null,
    x_label: ?[]const u8 = null,
    num_bins: ?usize = null,
    cumulative: bool = false,
};

// Tests
test "generateHistogram with empty data" {
    const allocator = std.testing.allocator;

    const engine = try analytics.AnalyticsEngine.init(
        allocator,
        undefined, // event_manager placeholder
        .{},
    );
    defer engine.deinit();

    const generator = VisualizationGenerator.init(allocator, &engine);

    const values = [_]f64{};
    const config = HistogramConfig{};

    const result = try generator.generateHistogram(&values, config);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.bins.len);
}

test "generateHistogram with data" {
    const allocator = std.testing.allocator;

    const engine = try analytics.AnalyticsEngine.init(
        allocator,
        undefined,
        .{},
    );
    defer engine.deinit();

    const generator = VisualizationGenerator.init(allocator, &engine);

    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 };
    const config = HistogramConfig{
        .num_bins = 5,
        .x_label = "Value",
    };

    const result = try generator.generateHistogram(&values, config);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), result.bins.len);
    try std.testing.expectApproxEqAbs(5.5, result.mean, 0.1);
    try std.testing.expectApproxEqAbs(5.0, result.median, 0.1);
}
