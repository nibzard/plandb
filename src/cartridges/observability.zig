//! Observability Cartridge for performance monitoring and regression detection
//!
//! Provides structured storage and analysis of performance metrics:
//! - Metric ingestion with bounded size and rate limiting
//! - Regression detection with configurable thresholds
//! - Correlation to commits/sessions
//! - Hot path safety enforcement (payload limits, sampling, retention)

const std = @import("std");
const events = @import("../events/index.zig");
const autonomy = @import("../autonomy/regression_detection.zig");

// ==================== Rate Limiting ====================

/// Token bucket state for per-key rate limiting
const TokenBucket = struct {
    tokens: f64,
    last_refill_ns: i64,

    pub fn init(capacity: f64, now_ns: i64) TokenBucket {
        return TokenBucket{
            .tokens = capacity,
            .last_refill_ns = now_ns,
        };
    }
};

/// Rate limit state tracking across metric keys
const RateLimitState = struct {
    buckets: std.StringHashMap(TokenBucket),
    mutex: std.Thread.Mutex,
    rate_per_sec: u32,
    bucket_capacity: f64,

    pub fn init(allocator: std.mem.Allocator, rate_per_sec: u32) RateLimitState {
        return RateLimitState{
            .buckets = std.StringHashMap(TokenBucket).init(allocator),
            .mutex = .{},
            .rate_per_sec = rate_per_sec,
            .bucket_capacity = @as(f64, @floatFromInt(rate_per_sec)) * 2.0, // Allow bursts up to 2x rate
        };
    }

    pub fn deinit(self: *RateLimitState) void {
        self.buckets.deinit();
    }

    /// Try to consume a token from the bucket for the given key
    pub fn tryAcquire(self: *RateLimitState, key: []const u8, now_ns: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const bucket = self.getOrCreateBucket(key, now_ns);
        return self.consumeToken(bucket, now_ns);
    }

    /// Clean up stale buckets (older than 5 minutes)
    pub fn cleanup(self: *RateLimitState, allocator: std.mem.Allocator, now_ns: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stale_threshold_ns = 5 * 60 * 1_000_000_000; // 5 minutes
        var it = self.buckets.iterator();
        while (it.next()) |entry| {
            const bucket = entry.value_ptr.*;
            if (now_ns - bucket.last_refill_ns > stale_threshold_ns) {
                allocator.free(entry.key_ptr.*);
                _ = self.buckets.remove(entry.key_ptr.*);
            }
        }
    }

    fn getOrCreateBucket(self: *RateLimitState, key: []const u8, now_ns: i64) *TokenBucket {
        const gop = self.buckets.getOrPut(key) catch unreachable;
        if (!gop.found_existing) {
            gop.key_ptr.* = key;
            gop.value_ptr.* = TokenBucket.init(self.bucket_capacity, now_ns);
        }
        return gop.value_ptr;
    }

    fn consumeToken(self: *RateLimitState, bucket: *TokenBucket, now_ns: i64) bool {
        // Refill tokens based on elapsed time
        const elapsed_ns = now_ns - bucket.last_refill_ns;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

        // Calculate tokens to add: rate * elapsed_time
        const tokens_to_add = elapsed_sec * @as(f64, @floatFromInt(self.rate_per_sec));
        bucket.tokens = @min(bucket.tokens + tokens_to_add, self.bucket_capacity);
        bucket.last_refill_ns = now_ns;

        // Try to consume one token
        if (bucket.tokens >= 1.0) {
            bucket.tokens -= 1.0;
            return true;
        }

        return false;
    }
};

/// Observability Cartridge
///
/// Ingests, analyzes, and retrieves performance metrics with:
/// - Bounded metric storage (payload size limits)
/// - Sampling and rate limiting for hot path safety
/// - Automatic regression detection
/// - Correlation to commits and sessions
pub const ObservabilityCartridge = struct {
    allocator: std.mem.Allocator,
    event_manager: *events.EventManager,
    detector: autonomy.RegressionDetector,
    config: Config,
    rate_limit_state: RateLimitState,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        event_manager: *events.EventManager,
        config: Config,
    ) !Self {
        const detector_config = autonomy.DetectorConfig{
            .max_history_per_metric = config.max_metrics_per_key,
            .min_samples_for_detection = config.min_samples_for_detection,
            .trend_sample_count = config.trend_sample_count,
            .throughput_regression_threshold = config.throughput_regression_threshold,
            .latency_regression_threshold = config.latency_regression_threshold,
            .p99_regression_threshold = config.p99_regression_threshold,
            .error_rate_regression_threshold = config.error_rate_regression_threshold,
        };

        return Self{
            .allocator = allocator,
            .event_manager = event_manager,
            .detector = autonomy.RegressionDetector.init(allocator, detector_config),
            .config = config,
            .rate_limit_state = RateLimitState.init(allocator, config.rate_limit_per_sec),
        };
    }

    pub fn deinit(self: *Self) void {
        self.detector.deinit();
        self.rate_limit_state.deinit();
    }

    /// Record a performance metric sample
    /// Enforces payload size limits and sampling
    pub fn recordMetric(
        self: *Self,
        metric_name: []const u8,
        value: f64,
        unit: []const u8,
        dimensions: DimensionMap,
        correlation_hints: CorrelationHints,
    ) !void {
        // Apply sampling if configured
        if (self.config.sampling_rate < 1.0) {
            const rand = @as(f32, @floatFromInt(std.crypto.random.int(u64))) / @as(f32, std.math.maxF32(f32));
            if (rand > self.config.sampling_rate) {
                return; // Sampled out
            }
        }

        // Validate payload size
        const payload_size = self.estimateMetricSize(metric_name, unit, &dimensions);
        if (payload_size > self.config.max_metric_payload_size) {
            return error.PayloadTooLarge;
        }

        // Check rate limit
        if (self.config.rate_limit_per_sec > 0) {
            const now = std.time.nanoTimestamp();
            const key = try self.formatMetricKey(metric_name, &dimensions);
            defer self.allocator.free(key);

            if (!self.tryAcquireRateLimit(key, now)) {
                return error.RateLimited;
            }
        }

        // Record via event manager
        _ = try self.event_manager.recordPerfSample(
            metric_name,
            value,
            unit,
            dimensions.map,
            correlation_hints.commit_range,
            correlation_hints.session_ids,
        );

        // Store in regression detector
        const detector_key = try self.formatDetectorKey(metric_name, &dimensions);
        defer self.allocator.free(detector_key);

        const snapshot = autonomy.MetricSnapshot{
            .timestamp_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000))),
            .throughput_ops_per_sec = if (std.mem.eql(u8, unit, "ops/sec")) value else 0,
            .avg_latency_ms = if (std.mem.eql(u8, unit, "ms")) value else 0,
            .p99_latency_ms = 0, // Would need separate p99 metric
            .error_rate = if (std.mem.eql(u8, unit, "errors")) value else 0,
        };

        try self.detector.recordMetrics(detector_key, snapshot);
    }

    /// Establish a performance baseline for a metric
    pub fn establishBaseline(
        self: *Self,
        metric_name: []const u8,
        dimensions: DimensionMap,
        baseline: PerformanceBaseline,
    ) !void {
        const key = try self.formatDetectorKey(metric_name, &dimensions);
        defer self.allocator.free(key);

        const perf_baseline = autonomy.PerformanceBaseline{
            .throughput_ops_per_sec = baseline.throughput_ops_per_sec,
            .avg_latency_ms = baseline.avg_latency_ms,
            .p99_latency_ms = baseline.p99_latency_ms,
            .error_rate = baseline.error_rate,
            .established_ts = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000))),
        };

        try self.detector.establishBaseline(key, perf_baseline);
    }

    /// Detect regressions across all tracked metrics
    pub fn detectRegressions(self: *Self) ![]RegressionAlert {
        const raw_alerts = try self.detector.detectRegressions();
        defer {
            for (raw_alerts) |*a| a.deinit(self.allocator);
            self.allocator.free(raw_alerts);
        }

        // Convert to our alert type with metric name parsing
        var alerts = std.ArrayList(RegressionAlert).init(self.allocator);
        defer {
            for (alerts.items) |*a| a.deinit(self.allocator);
            alerts.deinit();
        }

        for (raw_alerts) |raw_alert| {
            const alert = try self.convertAlert(raw_alert);
            try alerts.append(alert);
        }

        // Record regression events
        for (alerts.items) |alert| {
            _ = try self.event_manager.recordPerfRegression(
                alert.metric_name,
                alert.baseline_value,
                alert.current_value,
                alert.regression_percent,
                alert.severity,
                alert.likely_cause,
            );
        }

        return alerts.toOwnedSlice();
    }

    /// Get performance trend for a metric
    pub fn getPerformanceTrend(
        self: *Self,
        metric_name: []const u8,
        dimensions: DimensionMap,
    ) !?PerformanceTrend {
        const key = try self.formatDetectorKey(metric_name, &dimensions);
        defer self.allocator.free(key);

        const raw_trend = try self.detector.getPerformanceTrend(key);
        if (raw_trend) |*t| {
            return PerformanceTrend{
                .metric_name = try self.allocator.dupe(u8, metric_name),
                .baseline_throughput = t.baseline_throughput,
                .current_throughput = t.current_throughput,
                .baseline_latency = t.baseline_latency,
                .current_latency = t.current_latency,
                .direction = t.direction,
            };
        }

        return null;
    }

    /// Query metrics by filter
    pub fn queryMetrics(
        self: *Self,
        filter: MetricFilter,
    ) ![]MetricSample {
        const events_results = try self.event_manager.query(.{
            .event_types = &[_]events.types.EventType{.perf_sample},
            .start_time = filter.start_time,
            .end_time = filter.end_time,
            .limit = filter.limit,
        });

        var samples = std.ArrayList(MetricSample).init(self.allocator);
        errdefer {
            for (samples.items) |*s| s.deinit(self.allocator);
            samples.deinit();
        }

        for (events_results) |event_result| {
            defer event_result.deinit();

            // Parse perf sample from event payload
            const sample = try self.parsePerfSample(event_result);
            try samples.append(sample);
        }

        self.allocator.free(events_results);
        return samples.toOwnedSlice();
    }

    /// Get metrics for a specific session
    pub fn getSessionMetrics(
        self: *Self,
        session_id: u64,
        limit: ?usize,
    ) ![]MetricSample {
        const events_results = try self.event_manager.query(.{
            .event_types = &[_]events.types.EventType{.perf_sample},
            .session_id = session_id,
            .limit = limit,
        });

        var samples = std.ArrayList(MetricSample).init(self.allocator);
        errdefer {
            for (samples.items) |*s| s.deinit(self.allocator);
            samples.deinit();
        }

        for (events_results) |event_result| {
            defer event_result.deinit();

            const sample = try self.parsePerfSample(event_result);
            try samples.append(sample);
        }

        self.allocator.free(events_results);
        return samples.toOwnedSlice();
    }

    /// Get metrics for a specific commit range
    pub fn getCommitRangeMetrics(
        self: *Self,
        commit_range: []const u8,
        limit: ?usize,
    ) ![]MetricSample {
        // Query all perf samples and filter by commit range
        const events_results = try self.event_manager.query(.{
            .event_types = &[_]events.types.EventType{.perf_sample},
            .limit = limit,
        });

        var samples = std.ArrayList(MetricSample).init(self.allocator);
        errdefer {
            for (samples.items) |*s| s.deinit(self.allocator);
            samples.deinit();
        }

        for (events_results) |event_result| {
            defer event_result.deinit();

            // Parse and check commit range
            var sample = try self.parsePerfSample(event_result);

            if (sample.correlation_hints.commit_range) |range| {
                if (std.mem.eql(u8, range, commit_range)) {
                    try samples.append(sample);
                } else {
                    sample.deinit(self.allocator);
                }
            } else {
                sample.deinit(self.allocator);
            }
        }

        self.allocator.free(events_results);
        return samples.toOwnedSlice();
    }

    /// Apply retention policy to old metrics
    pub fn applyRetention(self: *Self, retain_hours: u32) !void {
        const now = std.time.nanoTimestamp();
        const cutoff_ns = now - (@as(i64, @intCast(retain_hours)) * 60 * 60 * 1_000_000_000);

        // Compact event storage
        try self.event_manager.store.compact(now - cutoff_ns);

        // Clear old alerts
        self.detector.clearOldAlerts(retain_hours * 60 * 60 * 1000);
    }

    /// Get observability statistics
    pub fn getStats(self: *const Self) ObservabilityStats {
        const detector_stats = self.detector.getStats();

        return ObservabilityStats{
            .metrics_tracked = detector_stats.metrics_tracked,
            .baselines_tracked = detector_stats.baselines_tracked,
            .total_snapshots = detector_stats.total_snapshots,
            .active_regressions = detector_stats.active_alerts,
            .sampling_rate = self.config.sampling_rate,
            .max_payload_size = self.config.max_metric_payload_size,
        };
    }

    // ==================== Private Helpers ====================

    fn estimateMetricSize(
        self: *Self,
        metric_name: []const u8,
        unit: []const u8,
        dimensions: *const DimensionMap,
    ) usize {
        var size: usize = metric_name.len + unit.len;

        var it = dimensions.map.iterator();
        while (it.next()) |entry| {
            size += entry.key_ptr.*.len + entry.value_ptr.*.len;
        }

        return size;
    }

    fn formatMetricKey(
        self: *Self,
        metric_name: []const u8,
        dimensions: *const DimensionMap,
   ) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        try buf.appendSlice(metric_name);

        var it = dimensions.map.iterator();
        while (it.next()) |entry| {
            try buf.append(';');
            try buf.appendSlice(entry.key_ptr.*);
            try buf.append('=');
            try buf.appendSlice(entry.value_ptr.*);
        }

        return buf.toOwnedSlice();
    }

    fn formatDetectorKey(
        self: *Self,
        metric_name: []const u8,
        dimensions: *const DimensionMap,
    ) ![]u8 {
        return self.formatMetricKey(metric_name, dimensions);
    }

    fn tryAcquireRateLimit(self: *Self, key: []const u8, now: i64) bool {
        // Use token bucket algorithm for per-key rate limiting
        return self.rate_limit_state.tryAcquire(key, now);
    }

    fn convertAlert(self: *Self, raw_alert: autonomy.RegressionAlert) !RegressionAlert {
        // Parse metric name from key (removes dimension suffixes)
        const metric_name = try self.parseMetricNameFromKey(raw_alert.metric_key);

        return RegressionAlert{
            .metric_name = metric_name,
            .alert_type = raw_alert.alert_type,
            .severity = raw_alert.severity,
            .baseline_value = raw_alert.baseline_value,
            .current_value = raw_alert.current_value,
            .regression_percent = raw_alert.degradation_pct,
            .timestamp = raw_alert.timestamp,
            .description = try self.allocator.dupe(u8, raw_alert.description),
            .likely_cause = null, // Would be filled by correlation analysis
        };
    }

    fn parseMetricNameFromKey(self: *Self, key: []const u8) ![]const u8 {
        // Key format: "metric_name;dim1=val1;dim2=val2"
        const end_idx = std.mem.indexOfScalar(u8, key, ';') orelse key.len;
        return self.allocator.dupe(u8, key[0..end_idx]);
    }

    fn parsePerfSample(self: *Self, event_result: events.types.EventResult) !MetricSample {
        const payload = event_result.payload;

        // Simple format: metric_name\0value\0unit\0timestamp\0commit_range\0session_count
        var parts = std.mem.splitScalar(u8, payload, 0);

        const metric_name = parts.first() orelse return error.InvalidPayload;
        const value_str = parts.next() orelse return error.InvalidPayload;
        const unit = parts.next() orelse return error.InvalidPayload;
        const timestamp_str = parts.next() orelse return error.InvalidPayload;

        const value = try std.fmt.parseFloat(f64, value_str);
        const timestamp = try std.fmt.parseInt(i64, timestamp_str, 10);

        var commit_range: ?[]const u8 = null;
        var session_ids = std.ArrayList(u64).init(self.allocator);

        // Parse optional fields
        if (parts.next()) |commit_range_str| {
            if (commit_range_str.len > 0) {
                commit_range = try self.allocator.dupe(u8, commit_range_str);
            }
        }

        const correlation = CorrelationHints{
            .commit_range = commit_range,
            .session_ids = session_ids.toOwnedSlice(),
        };

        var dimensions = DimensionMap{ .map = std.StringHashMap([]const u8).init(self.allocator) };

        return MetricSample{
            .metric_name = try self.allocator.dupe(u8, metric_name),
            .value = value,
            .unit = try self.allocator.dupe(u8, unit),
            .dimensions = dimensions,
            .timestamp_window = .{
                .start = timestamp,
                .end = timestamp,
            },
            .correlation_hints = correlation,
        };
    }
};

// ==================== Types ====================

pub const Config = struct {
    // Hot path safety
    max_metric_payload_size: usize = 4096, // 4KB max per metric
    sampling_rate: f32 = 1.0, // 1.0 = no sampling
    rate_limit_per_sec: u32 = 0, // 0 = no limit

    // Retention
    default_retention_hours: u32 = 24 * 7, // 1 week

    // Regression detection
    max_metrics_per_key: usize = 100,
    min_samples_for_detection: usize = 5,
    trend_sample_count: usize = 10,
    throughput_regression_threshold: f64 = 0.95,
    latency_regression_threshold: f64 = 1.1,
    p99_regression_threshold: f64 = 1.15,
    error_rate_regression_threshold: f64 = 1.5,
};

pub const DimensionMap = struct {
    map: std.StringHashMap([]const u8),

    pub fn deinit(self: *DimensionMap) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.key_ptr.*.allocator.free(entry.key_ptr.*);
            entry.key_ptr.*.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }
};

pub const CorrelationHints = struct {
    commit_range: ?[]const u8,
    session_ids: []u64,
};

pub const PerformanceBaseline = struct {
    throughput_ops_per_sec: f64,
    avg_latency_ms: f64,
    p99_latency_ms: f64,
    error_rate: f64,
};

pub const RegressionAlert = struct {
    metric_name: []const u8,
    alert_type: autonomy.RegressionAlert.AlertType,
    severity: autonomy.RegressionAlert.AlertSeverity,
    baseline_value: f64,
    current_value: f64,
    regression_percent: f64,
    timestamp: u64,
    description: []const u8,
    likely_cause: ?[]const u8,

    pub fn deinit(self: *RegressionAlert, allocator: std.mem.Allocator) void {
        allocator.free(self.metric_name);
        allocator.free(self.description);
        if (self.likely_cause) |c| allocator.free(c);
    }
};

pub const PerformanceTrend = struct {
    metric_name: []const u8,
    baseline_throughput: f64,
    current_throughput: f64,
    baseline_latency: f64,
    current_latency: f64,
    direction: autonomy.PerformanceTrend.TrendDirection,

    pub fn deinit(self: *PerformanceTrend, allocator: std.mem.Allocator) void {
        allocator.free(self.metric_name);
    }
};

pub const MetricFilter = struct {
    metric_name: ?[]const u8 = null,
    start_time: ?i64 = null,
    end_time: ?i64 = null,
    limit: ?usize = null,
};

pub const MetricSample = struct {
    metric_name: []const u8,
    value: f64,
    unit: []const u8,
    dimensions: DimensionMap,
    timestamp_window: struct {
        start: i64,
        end: i64,
    },
    correlation_hints: CorrelationHints,

    pub fn deinit(self: *MetricSample, allocator: std.mem.Allocator) void {
        allocator.free(self.metric_name);
        allocator.free(self.unit);
        self.dimensions.deinit();

        if (self.correlation_hints.commit_range) |r| {
            allocator.free(r);
        }
        allocator.free(self.correlation_hints.session_ids);
    }
};

pub const ObservabilityStats = struct {
    metrics_tracked: usize,
    baselines_tracked: usize,
    total_snapshots: usize,
    active_regressions: usize,
    sampling_rate: f32,
    max_payload_size: usize,
};

// ==================== Tests ====================

test "ObservabilityCartridge init and record metric" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_obs_cart_events.dat",
        .index_path = "test_obs_cart_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    }

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);
    var cartridge = try ObservabilityCartridge.init(allocator, &event_manager, .{});
    defer cartridge.deinit();

    // Record a metric
    var dimensions = DimensionMap{ .map = std.StringHashMap([]const u8).init(allocator) };
    defer dimensions.deinit();

    try dimensions.map.put("operation", try allocator.dupe(u8, "read"));
    try dimensions.map.put("table", try allocator.dupe(u8, "users"));

    try cartridge.recordMetric(
        "latency_ms",
        5.2,
        "ms",
        dimensions,
        .{ .commit_range = null, .session_ids = &[_]u64{} },
    );

    const stats = cartridge.getStats();
    try std.testing.expect(stats.metrics_tracked > 0);
}

test "ObservabilityCartridge establish baseline and detect regression" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_obs_regression_events.dat",
        .index_path = "test_obs_regression_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    }

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);
    var cartridge = try ObservabilityCartridge.init(allocator, &event_manager, .{
        .min_samples_for_detection = 2,
    });
    defer cartridge.deinit();

    var dimensions = DimensionMap{ .map = std.StringHashMap([]const u8).init(allocator) };
    defer dimensions.deinit();
    try dimensions.map.put("op", try allocator.dupe(u8, "write"));

    // Establish baseline
    try cartridge.establishBaseline("throughput", dimensions, .{
        .throughput_ops_per_sec = 1000,
        .avg_latency_ms = 10,
        .p99_latency_ms = 50,
        .error_rate = 0.001,
    });

    // Record degraded metrics
    try cartridge.recordMetric("throughput", 500, "ops/sec", dimensions, .{
        .commit_range = null,
        .session_ids = &[_]u64{},
    });
    try cartridge.recordMetric("throughput", 500, "ops/sec", dimensions, .{
        .commit_range = null,
        .session_ids = &[_]u64{},
    });

    // Detect regressions
    const alerts = try cartridge.detectRegressions();
    defer {
        for (alerts) |*a| a.deinit(allocator);
        allocator.free(alerts);
    }

    try std.testing.expect(alerts.len > 0);
}

test "ObservabilityCartridge sampling" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_obs_sampling_events.dat",
        .index_path = "test_obs_sampling_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    }

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);
    var cartridge = try ObservabilityCartridge.init(allocator, &event_manager, .{
        .sampling_rate = 0.0, // Sample nothing
    });
    defer cartridge.deinit();

    var dimensions = DimensionMap{ .map = std.StringHashMap([]const u8).init(allocator) };
    defer dimensions.deinit();

    // Try to record - should be sampled out
    try cartridge.recordMetric("latency", 10, "ms", dimensions, .{
        .commit_range = null,
        .session_ids = &[_]u64{},
    });

    const stats = cartridge.getStats();
    // Should have 0 metrics since all were sampled out
    try std.testing.expectEqual(@as(usize, 0), stats.metrics_tracked);
}

test "ObservabilityCartridge performance trend" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_obs_trend_events.dat",
        .index_path = "test_obs_trend_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    }

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);
    var cartridge = try ObservabilityCartridge.init(allocator, &event_manager, .{});
    defer cartridge.deinit();

    var dimensions = DimensionMap{ .map = std.StringHashMap([]const u8).init(allocator) };
    defer dimensions.deinit();
    try dimensions.map.put("op", try allocator.dupe(u8, "read"));

    // Establish baseline
    try cartridge.establishBaseline("latency", dimensions, .{
        .throughput_ops_per_sec = 0,
        .avg_latency_ms = 10,
        .p99_latency_ms = 0,
        .error_rate = 0,
    });

    // Record multiple samples
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try cartridge.recordMetric("latency", 12, "ms", dimensions, .{
            .commit_range = null,
            .session_ids = &[_]u64{},
        });
    }

    // Get trend
    const trend = try cartridge.getPerformanceTrend("latency", dimensions);
    try std.testing.expect(trend != null);

    if (trend) |*t| {
        defer t.deinit(allocator);
        try std.testing.expectEqual(@as(f64, 10), t.baseline_latency);
    }
}

test "TokenBucket init" {
    const bucket = TokenBucket.init(10.0, 0);
    try std.testing.expectEqual(@as(f64, 10.0), bucket.tokens);
    try std.testing.expectEqual(@as(i64, 0), bucket.last_refill_ns);
}

test "TokenBucket consume token" {
    var bucket = TokenBucket.init(5.0, 0);

    // Consume one token
    try std.testing.expectEqual(@as(f64, 5.0), bucket.tokens);
    bucket.tokens -= 1.0;
    try std.testing.expectEqual(@as(f64, 4.0), bucket.tokens);
}

test "RateLimitState.tryAcquire within limit" {
    const allocator = std.testing.allocator;
    var state = RateLimitState.init(allocator, 100); // 100 tokens/sec
    defer state.deinit();

    // First acquisition should succeed
    try std.testing.expect(state.tryAcquire("metric_key", 0));

    // Immediate second acquisition should also succeed (burst capacity)
    try std.testing.expect(state.tryAcquire("metric_key", 0));
}

test "RateLimitState.tryAcquire respects rate limit" {
    const allocator = std.testing.allocator;
    var state = RateLimitState.init(allocator, 10); // 10 tokens/sec, 20 burst capacity
    defer state.deinit();

    // Consume all burst tokens (20 = rate * 2)
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try std.testing.expect(state.tryAcquire("test_key", 0), "Should succeed within burst capacity");
    }

    // Next request should fail (no tokens left)
    try std.testing.expect(!state.tryAcquire("test_key", 0), "Should fail when tokens exhausted");

    // After 100ms (0.1s), should get 1 token back
    const now_100ms = 100_000_000;
    try std.testing.expect(state.tryAcquire("test_key", now_100ms), "Should succeed after refill");

    // Should fail again immediately
    try std.testing.expect(!state.tryAcquire("test_key", now_100ms), "Should fail again after consuming refill");

    // After 1 second, should get 10 more tokens
    const now_1s = 1_000_000_000;
    i = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(state.tryAcquire("test_key", now_1s), "Should succeed after 1 second refill");
    }

    // Should fail again
    try std.testing.expect(!state.tryAcquire("test_key", now_1s), "Should fail after consuming 1 second refill");
}

test "RateLimitState separate buckets for separate keys" {
    const allocator = std.testing.allocator;
    var state = RateLimitState.init(allocator, 10); // 10 tokens/sec
    defer state.deinit();

    // Each key should have its own bucket
    try std.testing.expect(state.tryAcquire("key1", 0));
    try std.testing.expect(state.tryAcquire("key2", 0));
    try std.testing.expect(state.tryAcquire("key3", 0));

    // Can exhaust one bucket without affecting others
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        _ = state.tryAcquire("key1", 0);
    }

    // key1 should be exhausted
    try std.testing.expect(!state.tryAcquire("key1", 0));

    // But key2 and key3 should still work
    try std.testing.expect(state.tryAcquire("key2", 0));
    try std.testing.expect(state.tryAcquire("key3", 0));
}

test "RateLimitState.token refill over time" {
    const allocator = std.testing.allocator;
    var state = RateLimitState.init(allocator, 5); // 5 tokens/sec
    defer state.deinit();

    // Exhaust initial burst capacity (10 tokens)
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(state.tryAcquire("metric", 0));
    }

    // Should be exhausted
    try std.testing.expect(!state.tryAcquire("metric", 0));

    // After 200ms (0.2s), should get 1 token (0.2 * 5 = 1)
    try std.testing.expect(state.tryAcquire("metric", 200_000_000));
    try std.testing.expect(!state.tryAcquire("metric", 200_000_000));

    // After another 200ms (400ms total), should get another token
    try std.testing.expect(state.tryAcquire("metric", 400_000_000));
    try std.testing.expect(!state.tryAcquire("metric", 400_000_000));

    // After 1 second total, should get 5 tokens
    i = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(state.tryAcquire("metric", 1_000_000_000));
    }

    // Should be exhausted again
    try std.testing.expect(!state.tryAcquire("metric", 1_000_000_000));
}

test "ObservabilityCartridge rate limiting" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_obs_rate_limit_events.dat",
        .index_path = "test_obs_rate_limit_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    }

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);

    // Set rate limit to 10 per second with burst capacity of 20
    var cartridge = try ObservabilityCartridge.init(allocator, &event_manager, .{
        .rate_limit_per_sec = 10,
    });
    defer cartridge.deinit();

    var dimensions = DimensionMap{ .map = std.StringHashMap([]const u8).init(allocator) };
    defer dimensions.deinit();

    // Should be able to record up to burst capacity (20)
    var success_count: usize = 0;
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const result = cartridge.recordMetric("latency", 10, "ms", dimensions, .{
            .commit_range = null,
            .session_ids = &[_]u64{},
        });

        if (result) |_| {
            success_count += 1;
        } else |err| {
            // Should get RateLimited error after burst capacity
            try std.testing.expectEqual(error.RateLimited, err);
        }
    }

    // Should have succeeded exactly 20 times (burst capacity = rate * 2)
    try std.testing.expectEqual(@as(usize, 20), success_count);
}

test "ObservabilityCartridge rate limiting per metric key" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_obs_rate_limit_perkey_events.dat",
        .index_path = "test_obs_rate_limit_perkey_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    }

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);

    // Set rate limit to 5 per second
    var cartridge = try ObservabilityCartridge.init(allocator, &event_manager, .{
        .rate_limit_per_sec = 5,
    });
    defer cartridge.deinit();

    var dimensions1 = DimensionMap{ .map = std.StringHashMap([]const u8).init(allocator) };
    defer dimensions1.deinit();
    try dimensions1.map.put("op", try allocator.dupe(u8, "read"));

    var dimensions2 = DimensionMap{ .map = std.StringHashMap([]const u8).init(allocator) };
    defer dimensions2.deinit();
    try dimensions2.map.put("op", try allocator.dupe(u8, "write"));

    // Each metric should have its own rate limit bucket
    // Should be able to record 10 for each (burst capacity = 5 * 2)
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try cartridge.recordMetric("read_latency", 10, "ms", dimensions1, .{
            .commit_range = null,
            .session_ids = &[_]u64{},
        });
        try cartridge.recordMetric("write_latency", 10, "ms", dimensions2, .{
            .commit_range = null,
            .session_ids = &[_]u64{},
        });
    }

    // Both should succeed since they have separate buckets
    const stats = cartridge.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.metrics_tracked);
}
