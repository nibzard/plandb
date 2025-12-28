//! Pattern detection and anomaly analysis for NorthstarDB metrics
//!
//! Provides statistical analysis capabilities:
//! - Statistical baseline computation
//! - Sudden change detection (3-sigma, EMA)
//! - Seasonal pattern detection
//! - Predictive alerting based on trends

const std = @import("std");

/// Metric data point with timestamp
pub const MetricPoint = struct {
    timestamp_ms: u64,
    value: f64,
};

/// Statistical baseline for a metric
pub const StatisticalBaseline = struct {
    mean: f64,
    std_dev: f64,
    median: f64,
    p95: f64,
    p99: f64,
    min: f64,
    max: f64,
    sample_count: u64,
    computed_at_ms: u64,
};

/// Anomaly detection result
pub const AnomalyResult = struct {
    timestamp_ms: u64,
    value: f64,
    anomaly_type: AnomalyType,
    severity: Severity,
    score: f64,         // Confidence score 0-1
    expected_value: f64,
    deviation: f64,
    description: []const u8,

    pub fn deinit(self: AnomalyResult, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
    }

    pub const AnomalyType = enum {
        sudden_spike,      // Value suddenly increased
        sudden_drop,       // Value suddenly decreased
        trend_change,      // Long-term trend shifted
        pattern_break,     // Expected pattern violated
        outlier,           // Statistical outlier
    };

    pub const Severity = enum {
        low,
        medium,
        high,
        critical,
    };
};

/// Detected trend
pub const Trend = struct {
    trend_type: TrendType,
    strength: f64,      // 0-1, higher = stronger trend
    start_ms: u64,
    end_ms: u64,
    slope: f64,         // Change per unit time

    pub const TrendType = enum {
        increasing,
        decreasing,
        stable,
        variable,
        seasonal,
    };
};

/// Seasonal pattern
pub const SeasonalPattern = struct {
    period_ms: u64,     // Duration of one cycle
    amplitude: f64,     // Peak-to-trough range
    phase_offset_ms: u64,
    confidence: f64,    // 0-1
};

/// Pattern detector
pub const PatternDetector = struct {
    allocator: std.mem.Allocator,
    config: Config,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Compute statistical baseline from metric points
    pub fn computeBaseline(
        self: *Self,
        points: []const MetricPoint,
    ) !StatisticalBaseline {
        if (points.len == 0) {
            return StatisticalBaseline{
                .mean = 0,
                .std_dev = 0,
                .median = 0,
                .p95 = 0,
                .p99 = 0,
                .min = 0,
                .max = 0,
                .sample_count = 0,
                .computed_at_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000))),
            };
        }

        // Extract values
        var values = std.ArrayList(f64).init(self.allocator, {});
        defer values.deinit();

        for (points) |p| try values.append(p.value);

        // Compute mean
        var sum: f64 = 0;
        for (values.items) |v| sum += v;
        const mean = sum / @as(f64, @floatFromInt(values.items.len));

        // Compute standard deviation
        var variance: f64 = 0;
        for (values.items) |v| {
            const diff = v - mean;
            variance += diff * diff;
        }
        variance /= @as(f64, @floatFromInt(values.items.len));
        const std_dev = @sqrt(variance);

        // Sort for percentiles
        std.sort.insert(f64, values.items, {}, comptime std.sort.asc(f64));

        const median = values.items[@divTrunc(values.items.len, 2)];
        const p95_idx = @min(@as(usize, @intFromFloat(@as(f64, @floatFromInt(values.items.len - 1)) * 0.95)), values.items.len - 1);
        const p99_idx = @min(@as(usize, @intFromFloat(@as(f64, @floatFromInt(values.items.len - 1)) * 0.99)), values.items.len - 1);

        var min_val: f64 = std.math.inf(f32);
        var max_val: f64 = -std.math.inf(f32);
        for (values.items) |v| {
            min_val = @min(min_val, v);
            max_val = @max(max_val, v);
        }

        return StatisticalBaseline{
            .mean = mean,
            .std_dev = std_dev,
            .median = median,
            .p95 = values.items[p95_idx],
            .p99 = values.items[p99_idx],
            .min = min_val,
            .max = max_val,
            .sample_count = @intCast(points.len),
            .computed_at_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000))),
        };
    }

    /// Detect anomalies using 3-sigma rule
    pub fn detectAnomalies3Sigma(
        self: *Self,
        points: []const MetricPoint,
        baseline: StatisticalBaseline,
    ) ![]const AnomalyResult {
        var anomalies = std.ArrayList(AnomalyResult).init(self.allocator, {});

        const threshold = self.config.sigma_threshold * baseline.std_dev;

        for (points) |p| {
            const deviation = p.value - baseline.mean;

            if (@abs(deviation) > threshold) {
                const anomaly_type = if (deviation > 0)
                    AnomalyResult.AnomalyType.sudden_spike
                else
                    AnomalyResult.AnomalyType.sudden_drop;

                const severity = if (@abs(deviation) > threshold * 2)
                    AnomalyResult.Severity.critical
                else if (@abs(deviation) > threshold * 1.5)
                    AnomalyResult.Severity.high
                else
                    AnomalyResult.Severity.medium;

                const score = @min(1.0, @abs(deviation) / (threshold * 2));

                const description = try std.fmt.allocPrint(
                    self.allocator,
                    "Value {d:.2} deviates {d:.2} from mean ({d:.2})",
                    .{ p.value, deviation, baseline.mean },
                );

                try anomalies.append(.{
                    .timestamp_ms = p.timestamp_ms,
                    .value = p.value,
                    .anomaly_type = anomaly_type,
                    .severity = severity,
                    .score = score,
                    .expected_value = baseline.mean,
                    .deviation = deviation,
                    .description = description,
                });
            }
        }

        return anomalies.toOwnedSlice();
    }

    /// Detect anomalies using EMA (Exponential Moving Average)
    pub fn detectAnomaliesEMA(
        self: *Self,
        points: []const MetricPoint,
    ) ![]const AnomalyResult {
        if (points.len < self.config.ema_min_samples) {
            return &.{};
        }

        var anomalies = std.ArrayList(AnomalyResult).init(self.allocator, {});

        const alpha = self.config.ema_alpha;
        var ema = points[0].value;
        var ema_std: f64 = 0;

        // Bootstrap EMA
        for (points[0..@min(points.len, self.config.ema_min_samples)]) |p| {
            ema = alpha * p.value + (1 - alpha) * ema;
        }

        // Compute EMA std dev
        for (points) |p| {
            ema = alpha * p.value + (1 - alpha) * ema;
            const diff = p.value - ema;
            ema_std = alpha * (diff * diff) + (1 - alpha) * ema_std;
        }
        ema_std = @sqrt(ema_std);

        // Detect anomalies
        ema = points[0].value;
        for (points) |p| {
            ema = alpha * p.value + (1 - alpha) * ema;
            const deviation = p.value - ema;
            const threshold = self.config.ema_sigma_threshold * ema_std;

            if (@abs(deviation) > threshold) {
                const anomaly_type = if (deviation > 0)
                    AnomalyResult.AnomalyType.sudden_spike
                else
                    AnomalyResult.AnomalyType.sudden_drop;

                const score = @min(1.0, @abs(deviation) / (threshold * 2));

                const description = try std.fmt.allocPrint(
                    self.allocator,
                    "Value {d:.2} deviates from EMA {d:.2}",
                    .{ p.value, ema },
                );

                try anomalies.append(.{
                    .timestamp_ms = p.timestamp_ms,
                    .value = p.value,
                    .anomaly_type = anomaly_type,
                    .severity = if (score > 0.8) .critical else if (score > 0.5) .high else .medium,
                    .score = score,
                    .expected_value = ema,
                    .deviation = deviation,
                    .description = description,
                });
            }
        }

        return anomalies.toOwnedSlice();
    }

    /// Detect trend in metric data
    pub fn detectTrend(
        self: *Self,
        points: []const MetricPoint,
    ) !Trend {
        if (points.len < 2) {
            return Trend{
                .trend_type = .stable,
                .strength = 0,
                .start_ms = 0,
                .end_ms = 0,
                .slope = 0,
            };
        }

        // Compute linear regression
        var n: f64 = @floatFromInt(points.len);
        var sum_x: f64 = 0;
        var sum_y: f64 = 0;
        var sum_xy: f64 = 0;
        var sum_xx: f64 = 0;

        const start_ms = points[0].timestamp_ms;
        const end_ms = points[points.len - 1].timestamp_ms;

        for (points, 0..) |p, i| {
            const x = @as(f64, @floatFromInt(i));
            const y = p.value;
            sum_x += x;
            sum_y += y;
            sum_xy += x * y;
            sum_xx += x * x;
        }

        const slope = (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x);
        const intercept = (sum_y - slope * sum_x) / n;

        // Compute R-squared for strength
        var ss_res: f64 = 0;
        var ss_tot: f64 = 0;
        const mean_y = sum_y / n;

        for (points, 0..) |p, i| {
            const x = @as(f64, @floatFromInt(i));
            const y_pred = slope * x + intercept;
            ss_res += (p.value - y_pred) * (p.value - y_pred);
            ss_tot += (p.value - mean_y) * (p.value - mean_y);
        }

        const r_squared = if (ss_tot > 0) 1 - (ss_res / ss_tot) else 0;
        const strength = @sqrt(@max(0.0, r_squared));

        // Determine trend type
        const trend_type = if (strength < 0.3) {
            if (self.isVolatile(points)) .variable else .stable
        } else if (slope > self.config.trend_threshold) {
            .increasing
        } else if (slope < -self.config.trend_threshold) {
            .decreasing
        } else {
            .stable
        };

        return Trend{
            .trend_type = trend_type,
            .strength = strength,
            .start_ms = start_ms,
            .end_ms = end_ms,
            .slope = slope,
        };
    }

    /// Detect seasonal patterns in data
    pub fn detectSeasonality(
        self: *Self,
        points: []const MetricPoint,
        max_period_ms: u64,
    ) !?SeasonalPattern {
        if (points.len < self.config.min_seasonality_samples) {
            return null;
        }

        // Try different periods
        var best_period: u64 = 0;
        var best_score: f64 = 0;

        var period: u64 = self.config.min_period_ms;
        while (period <= max_period_ms) : (period += self.config.period_step_ms) {
            const score = try self.computeSeasonalityScore(points, period);
            if (score > best_score) {
                best_score = score;
                best_period = period;
            }
        }

        if (best_score < self.config.seasonality_threshold) {
            return null;
        }

        // Compute amplitude and phase
        const amplitude = try self.computeAmplitude(points, best_period);
        const phase = try self.computePhase(points, best_period);

        return SeasonalPattern{
            .period_ms = best_period,
            .amplitude = amplitude,
            .phase_offset_ms = phase,
            .confidence = best_score,
        };
    }

    /// Predict next values based on trend
    pub fn predictNext(
        self: *Self,
        points: []const MetricPoint,
        count: usize,
    ) ![]const f64 {
        if (points.len < 2) {
            var predictions = std.ArrayList(f64).init(self.allocator, {});
            for (0..count) |_|
                try predictions.append(0);
            return predictions.toOwnedSlice();
        }

        const trend = try self.detectTrend(points);

        // Simple linear extrapolation
        var predictions = std.ArrayList(f64).init(self.allocator, {});

        const last_value = points[points.len - 1].value;
        const time_span_ms = if (points.len > 1)
            points[points.len - 1].timestamp_ms - points[points.len - 2].timestamp_ms
        else
            60000; // Default to 1 minute

        for (0..count) |i| {
            const predicted = last_value + (@as(f64, @floatFromInt(i + 1)) * trend.slope);
            try predictions.append(predicted);
        }

        return predictions.toOwnedSlice();
    }

    fn isVolatile(self: *Self, points: []const MetricPoint) bool {
        _ = self;
        if (points.len < 3) return false;

        // Check coefficient of variation
        var sum: f64 = 0;
        for (points) |p| sum += p.value;
        const mean = sum / @as(f64, @floatFromInt(points.len));

        var variance: f64 = 0;
        for (points) |p| {
            const diff = p.value - mean;
            variance += diff * diff;
        }
        variance /= @as(f64, @floatFromInt(points.len));
        const std_dev = @sqrt(variance);

        const cv = if (mean != 0) @abs(std_dev / mean) else 0;
        return cv > self.config.volatility_threshold;
    }

    fn computeSeasonalityScore(
        self: *Self,
        points: []const MetricPoint,
        period_ms: u64,
    ) !f64 {
        _ = self;
        // Simple autocorrelation-based score
        // Higher score = more likely to have this period
        var score: f64 = 0;
        var count: usize = 0;

        for (points, 0..) |p, i| {
            const expected_idx = i + @as(usize, @intCast(@divTrunc(period_ms, 60000))); // Assume ~1min intervals
            if (expected_idx < points.len) {
                const other = points[expected_idx];
                const diff = @abs(p.value - other.value);
                const max_diff = @max(p.value, other.value);
                if (max_diff > 0) {
                    score += 1 - (diff / max_diff);
                }
                count += 1;
            }
        }

        return if (count > 0) score / @as(f64, @floatFromInt(count)) else 0;
    }

    fn computeAmplitude(
        self: *Self,
        points: []const MetricPoint,
        period_ms: u64,
    ) !f64 {
        _ = period_ms;
        _ = self;
        if (points.len == 0) return 0;

        var min_val: f64 = std.math.inf(f32);
        var max_val: f64 = -std.math.inf(f32);
        for (points) |p| {
            min_val = @min(min_val, p.value);
            max_val = @max(max_val, p.value);
        }

        return max_val - min_val;
    }

    fn computePhase(
        self: *Self,
        points: []const MetricPoint,
        period_ms: u64,
   ) !f64 {
        _ = self;
        _ = period_ms;
        if (points.len == 0) return 0;
        return points[0].timestamp_ms;
    }
};

/// Pattern detector configuration
pub const Config = struct {
    // 3-sigma config
    sigma_threshold: f64 = 3.0,

    // EMA config
    ema_alpha: f64 = 0.2,
    ema_min_samples: usize = 10,
    ema_sigma_threshold: f64 = 2.5,

    // Trend config
    trend_threshold: f64 = 0.01,
    volatility_threshold: f64 = 0.5,

    // Seasonality config
    min_period_ms: u64 = 3600000, // 1 hour
    period_step_ms: u64 = 1800000, // 30 min
    min_seasonality_samples: usize = 100,
    seasonality_threshold: f64 = 0.7,
};

// Tests
test "computeBaseline with values" {
    const allocator = std.testing.allocator;
    const detector = PatternDetector.init(allocator, .{});

    const points = [_]MetricPoint{
        .{ .timestamp_ms = 1000, .value = 10.0 },
        .{ .timestamp_ms = 2000, .value = 20.0 },
        .{ .timestamp_ms = 3000, .value = 30.0 },
        .{ .timestamp_ms = 4000, .value = 40.0 },
        .{ .timestamp_ms = 5000, .value = 50.0 },
    };

    const baseline = try detector.computeBaseline(&points);

    try std.testing.expectApproxEqAbs(30.0, baseline.mean, 0.1);
    try std.testing.expectEqual(@as(usize, 5), baseline.sample_count);
}

test "detectTrend increasing" {
    const allocator = std.testing.allocator;
    const detector = PatternDetector.init(allocator, .{});

    const points = [_]MetricPoint{
        .{ .timestamp_ms = 1000, .value = 10.0 },
        .{ .timestamp_ms = 2000, .value = 20.0 },
        .{ .timestamp_ms = 3000, .value = 30.0 },
        .{ .timestamp_ms = 4000, .value = 40.0 },
        .{ .timestamp_ms = 5000, .value = 50.0 },
    };

    const trend = try detector.detectTrend(&points);

    try std.testing.expectEqual(Trend.TrendType.increasing, trend.trend_type);
    try std.testing.expect(trend.strength > 0.9);
}

test "predictNext linear" {
    const allocator = std.testing.allocator;
    const detector = PatternDetector.init(allocator, .{});

    const points = [_]MetricPoint{
        .{ .timestamp_ms = 1000, .value = 10.0 },
        .{ .timestamp_ms = 2000, .value = 20.0 },
        .{ .timestamp_ms = 3000, .value = 30.0 },
    };

    const predictions = try detector.predictNext(&points, 2);
    defer allocator.free(predictions);

    try std.testing.expectEqual(@as(usize, 2), predictions.len);
    try std.testing.expectApproxEqAbs(40.0, predictions[0], 1.0);
    try std.testing.expectApproxEqAbs(50.0, predictions[1], 1.0);
}
