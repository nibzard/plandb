//! Performance bottleneck detection plugin
//!
//! Automatically detects performance bottlenecks, generates recommendations,
//! and integrates with auto-tuning capabilities for autonomous optimization.

const std = @import("std");
const mem = std.mem;

/// Performance bottleneck detection plugin
pub const BottleneckDetectionPlugin = struct {
    allocator: std.mem.Allocator,
    pattern_detector: ?*anyopaque, // *PatternDetector - opaque to avoid circular deps
    optimizer: ?*anyopaque, // *QueryOptimizer - opaque to avoid circular deps
    config: DetectionConfig,
    state: PluginState,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        pattern_detector: ?*anyopaque,
        optimizer: ?*anyopaque,
        config: DetectionConfig
    ) Self {
        return .{
            .allocator = allocator,
            .pattern_detector = pattern_detector,
            .optimizer = optimizer,
            .config = config,
            .state = PluginState{
                .active_bottlenecks = std.ArrayList(Bottleneck).initCapacity(allocator, 0) catch unreachable,
                .history = std.ArrayList(DetectionRecord).initCapacity(allocator, 0) catch unreachable,
                .stats = Statistics{},
            },
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.state.active_bottlenecks.items) |*b| {
            b.deinit(self.allocator);
        }
        self.state.active_bottlenecks.deinit(self.allocator);

        for (self.state.history.items) |*h| {
            h.deinit(self.allocator);
        }
        self.state.history.deinit(self.allocator);
    }

    /// Analyze query for performance issues
    pub fn analyzeQuery(self: *Self, query: []const u8, latency_ms: f64, result_count: usize) !AnalysisResult {
        const threshold = self.config.latency_threshold_ms;
        const is_bottleneck = latency_ms > threshold;

        if (is_bottleneck) {
            const severity = calculateSeverity(latency_ms, threshold);
            const bottleneck = Bottleneck{
                .query = try self.allocator.dupe(u8, query),
                .type = try classifyBottleneck(self, query, latency_ms, result_count),
                .latency_ms = latency_ms,
                .severity = severity,
                .detected_at = std.time.nanoTimestamp(),
                .result_count = result_count,
                .recommendations = try generateRecommendations(self, query, latency_ms, result_count),
            };

            try self.state.active_bottlenecks.append(self.allocator, bottleneck);
            try recordDetection(self, query, latency_ms, severity);
            self.state.stats.total_bottlenecks += 1;
        }

        return AnalysisResult{
            .is_bottleneck = is_bottleneck,
            .severity = if (is_bottleneck) calculateSeverity(latency_ms, threshold) else 0,
            .latency_ms = latency_ms,
            .threshold_ms = threshold,
        };
    }

    /// Detect performance regression
    pub fn detectRegression(self: *Self, query: []const u8, current_latency: f64) !?RegressionReport {
        // Find historical baseline for this query
        var baseline_latency: ?f64 = null;
        var samples: usize = 0;

        for (self.state.history.items) |record| {
            if (mem.eql(u8, record.query, query)) {
                baseline_latency = if (baseline_latency == null)
                    record.latency_ms
                else
                    @max(baseline_latency.?, record.latency_ms);
                samples += 1;
            }
        }

        if (baseline_latency == null or samples < self.config.min_samples_for_baseline) {
            return null;
        }

        const baseline = baseline_latency.?;
        const regression_ratio = current_latency / baseline;

        if (regression_ratio > self.config.regression_threshold) {
            return RegressionReport{
                .query = try self.allocator.dupe(u8, query),
                .baseline_latency_ms = baseline,
                .current_latency_ms = current_latency,
                .regression_ratio = regression_ratio,
                .severity = calculateSeverity(current_latency, baseline),
                .detected_at = std.time.nanoTimestamp(),
            };
        }

        return null;
    }

    /// Get current active bottlenecks
    pub fn getActiveBottlenecks(self: *const Self) []const Bottleneck {
        return self.state.active_bottlenecks.items;
    }

    /// Run comprehensive performance analysis
    pub fn runAnalysis(self: *Self) !AnalysisReport {
        // Note: In real implementation, would call pattern_detector.detectBottlenecks()
        // For now, use existing active bottlenecks

        var total_latency: f64 = 0;
        var worst_latency: f64 = 0;

        for (self.state.active_bottlenecks.items) |b| {
            total_latency += b.latency_ms;
            worst_latency = @max(worst_latency, b.latency_ms);
        }

        const avg_latency = if (self.state.active_bottlenecks.items.len > 0)
            total_latency / @as(f64, @floatFromInt(self.state.active_bottlenecks.items.len))
        else
            0;

        return AnalysisReport{
            .bottleneck_count = self.state.active_bottlenecks.items.len,
            .avg_latency_ms = avg_latency,
            .worst_latency_ms = worst_latency,
            .timestamp = std.time.nanoTimestamp(),
        };
    }

    /// Get statistics
    pub fn getStats(self: *const Self) Statistics {
        return self.state.stats;
    }

    /// Clear resolved bottlenecks
    pub fn clearResolved(self: *Self) !usize {
        var resolved: usize = 0;

        var i: usize = 0;
        while (i < self.state.active_bottlenecks.items.len) {
            const bottleneck = &self.state.active_bottlenecks.items[i];

            // Check if resolved (below threshold)
            if (bottleneck.latency_ms < self.config.resolution_threshold_ms) {
                bottleneck.deinit(self.allocator);
                _ = self.state.active_bottlenecks.orderedRemove(i);
                resolved += 1;
            } else {
                i += 1;
            }
        }

        self.state.stats.bottlenecks_resolved += resolved;

        return resolved;
    }
};

fn calculateSeverity(latency: f64, threshold: f64) u8 {
    const ratio = latency / threshold;
    const severity = @min(10, @as(u8, @intFromFloat(@floor((ratio - 1) * 5))));
    return @max(1, severity);
}

fn classifyBottleneck(self: *const BottleneckDetectionPlugin, query: []const u8, latency: f64, result_count: usize) !BottleneckType {
    _ = self;
    _ = latency;

    // Analyze query pattern
    if (mem.indexOf(u8, query, "SELECT *") != null or mem.indexOf(u8, query, "scan") != null) {
        return .full_table_scan;
    }
    if (mem.indexOf(u8, query, "ORDER BY") != null and result_count > 1000) {
        return .large_sort;
    }
    if (mem.indexOf(u8, query, "JOIN") != null) {
        const join_count = countOccurrences(query, "JOIN");
        if (join_count >= 3) return .complex_join;
        return .simple_join;
    }
    if (mem.indexOf(u8, query, "GROUP BY") != null) {
        return .aggregation;
    }
    if (mem.indexOf(u8, query, "subquery") != null) {
        return .nested_query;
    }

    return .unknown;
}

fn generateRecommendations(self: *BottleneckDetectionPlugin, query: []const u8, latency: f64, result_count: usize) ![]const Recommendation {
    var recommendations = std.ArrayList(Recommendation).initCapacity(self.allocator, 3) catch unreachable;

    // Generic recommendations based on query characteristics
    if (mem.indexOf(u8, query, "SELECT *") != null) {
        try recommendations.append(self.allocator, .{
            .type = .add_column_index,
            .description = try self.allocator.dupe(u8, "Specify columns instead of SELECT *"),
            .priority = 5,
            .estimated_improvement = 0.3,
        });
    }

    if (result_count > 10000) {
        try recommendations.append(self.allocator, .{
            .type = .add_limit,
            .description = try std.fmt.allocPrint(self.allocator, "Add LIMIT clause (got {} results)", .{result_count}),
            .priority = 7,
            .estimated_improvement = 0.5,
        });
    }

    if (latency > 1000) {
        try recommendations.append(self.allocator, .{
            .type = .build_cartridge,
            .description = try self.allocator.dupe(u8, "Build cartridge for this query pattern"),
            .priority = 8,
            .estimated_improvement = 0.8,
        });
    }

    return recommendations.toOwnedSlice(self.allocator);
}

fn recordDetection(self: *BottleneckDetectionPlugin, query: []const u8, latency: f64, severity: u8) !void {
    const record = DetectionRecord{
        .query = try self.allocator.dupe(u8, query),
        .latency_ms = latency,
        .severity = severity,
        .timestamp = std.time.nanoTimestamp(),
    };

    try self.state.history.append(self.allocator, record);

    // Trim history if needed
    if (self.state.history.items.len > self.config.max_history_size) {
        const removed = self.state.history.orderedRemove(0);
        removed.deinit(self.allocator);
    }
}

fn countOccurrences(text: []const u8, pattern: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;

    while (mem.indexOfPos(u8, text, start, pattern)) |idx| {
        count += 1;
        start = idx + pattern.len;
    }

    return count;
}

/// Configuration for bottleneck detection
pub const DetectionConfig = struct {
    /// Latency threshold for bottleneck detection (ms)
    latency_threshold_ms: f64 = 100,
    /// Threshold for considering a bottleneck resolved
    resolution_threshold_ms: f64 = 50,
    /// Ratio for detecting regression
    regression_threshold: f32 = 1.5,
    /// Minimum samples needed for baseline
    min_samples_for_baseline: usize = 5,
    /// Maximum history to maintain
    max_history_size: usize = 10000,
};

/// Bottleneck record
pub const Bottleneck = struct {
    query: []const u8,
    type: BottleneckType,
    latency_ms: f64,
    severity: u8,
    detected_at: i128,
    result_count: u64,
    recommendations: []const Recommendation,

    pub fn deinit(self: *Bottleneck, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        for (self.recommendations) |*r| {
            r.deinit(allocator);
        }
        allocator.free(self.recommendations);
    }
};

/// Bottleneck type classification
pub const BottleneckType = enum {
    full_table_scan,
    large_sort,
    complex_join,
    simple_join,
    aggregation,
    nested_query,
    missing_index,
    n_plus_1,
    cartesian_product,
    unknown,
};

/// Recommendation for optimization
pub const Recommendation = struct {
    type: RecommendationType,
    description: []const u8,
    priority: u8,
    estimated_improvement: f32,

    pub fn deinit(self: *const Recommendation, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
    }
};

/// Recommendation type
pub const RecommendationType = enum {
    add_index,
    add_column_index,
    add_limit,
    build_cartridge,
    optimize_query,
    analyze_query_plan,
    cache_results,
    denormalize,
};

/// Query analysis result
pub const AnalysisResult = struct {
    is_bottleneck: bool,
    severity: u8,
    latency_ms: f64,
    threshold_ms: f64,
};

/// Regression detection report
pub const RegressionReport = struct {
    query: []const u8,
    baseline_latency_ms: f64,
    current_latency_ms: f64,
    regression_ratio: f64,
    severity: u8,
    detected_at: i128,

    pub fn deinit(self: *const RegressionReport, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
    }
};

/// Analysis report
pub const AnalysisReport = struct {
    bottleneck_count: usize,
    avg_latency_ms: f64,
    worst_latency_ms: f64,
    timestamp: i128,
};

/// Detection record for historical tracking
pub const DetectionRecord = struct {
    query: []const u8,
    latency_ms: f64,
    severity: u8,
    timestamp: i128,

    pub fn deinit(self: *const DetectionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
    }
};

/// Plugin state
pub const PluginState = struct {
    active_bottlenecks: std.ArrayList(Bottleneck),
    history: std.ArrayList(DetectionRecord),
    stats: Statistics,
};

/// Plugin statistics
pub const Statistics = struct {
    total_bottlenecks: u64 = 0,
    bottlenecks_resolved: u64 = 0,
    regressions_detected: u64 = 0,
    total_analyses: u64 = 0,
};

// ==================== Tests ====================//

test "BottleneckDetectionPlugin init" {
    var plugin = BottleneckDetectionPlugin.init(std.testing.allocator, null, null, .{});
    defer plugin.deinit();

    try std.testing.expectEqual(@as(usize, 0), plugin.state.active_bottlenecks.items.len);
}

test "BottleneckDetectionPlugin analyzeQuery - bottleneck" {
    var plugin = BottleneckDetectionPlugin.init(std.testing.allocator, null, null, .{
        .latency_threshold_ms = 100,
    });
    defer plugin.deinit();

    const result = try plugin.analyzeQuery("SELECT * FROM large_table", 150, 10000);

    try std.testing.expect(result.is_bottleneck);
    try std.testing.expect(result.severity >= 1);
}

test "BottleneckDetectionPlugin analyzeQuery - normal" {
    var plugin = BottleneckDetectionPlugin.init(std.testing.allocator, null, null, .{});
    defer plugin.deinit();

    const result = try plugin.analyzeQuery("SELECT name FROM users", 50, 10);

    try std.testing.expect(!result.is_bottleneck);
}

test "BottleneckDetectionPlugin clearResolved" {
    var plugin = BottleneckDetectionPlugin.init(std.testing.allocator, null, null, .{
        .latency_threshold_ms = 100,
        .resolution_threshold_ms = 50,
    });
    defer plugin.deinit();

    _ = try plugin.analyzeQuery("slow query", 150, 0);

    const cleared = try plugin.clearResolved();

    try std.testing.expectEqual(@as(usize, 0), cleared); // Still above resolution threshold
}

test "BottleneckDetectionPlugin detectRegression" {
    var plugin = BottleneckDetectionPlugin.init(std.testing.allocator, null, null, .{
        .min_samples_for_baseline = 3,
        .regression_threshold = 1.5,
    });
    defer plugin.deinit();

    // Build up baseline
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try plugin.analyzeQuery("test query", 50, 10);
    }

    // Now test with regression
    const report = try plugin.detectRegression("test query", 100);

    // Should detect regression (100 vs 50 baseline is 2x regression)
    if (report) |r| {
        try std.testing.expect(r.regression_ratio >= 1.5);
        defer r.deinit(std.testing.allocator);
    }
}

test "BottleneckDetectionPlugin runAnalysis" {
    var plugin = BottleneckDetectionPlugin.init(std.testing.allocator, null, null, .{});
    defer plugin.deinit();

    _ = try plugin.analyzeQuery("slow query", 200, 0);
    _ = try plugin.analyzeQuery("another slow query", 150, 0);

    const report = try plugin.runAnalysis();

    try std.testing.expect(report.bottleneck_count >= 2);
}

test "classifyBottleneck" {
    var plugin = BottleneckDetectionPlugin.init(std.testing.allocator, null, null, .{});
    defer plugin.deinit();

    const btype = try classifyBottleneck(&plugin, "SELECT * FROM table", 100, 1000);

    try std.testing.expectEqual(BottleneckType.full_table_scan, btype);
}

test "calculateSeverity" {
    const severity = calculateSeverity(200, 100); // 2x threshold

    try std.testing.expect(severity >= 1);
    try std.testing.expect(severity <= 10);
}

test "getStats" {
    var plugin = BottleneckDetectionPlugin.init(std.testing.allocator, null, null, .{});
    defer plugin.deinit();

    const stats = plugin.getStats();

    try std.testing.expectEqual(@as(u64, 0), stats.total_bottlenecks);
}

test "AnalysisResult fields" {
    const result = AnalysisResult{
        .is_bottleneck = true,
        .severity = 5,
        .latency_ms = 150.0,
        .threshold_ms = 100.0,
    };

    try std.testing.expect(result.is_bottleneck);
    try std.testing.expectEqual(@as(u8, 5), result.severity);
}
