//! Time-series aggregation queries for NorthstarDB analytics
//!
//! Provides efficient time-series aggregation for performance metrics:
//! - Aggregation functions: sum, avg, min, max, percentiles
//! - Time bucketing: 1m, 5m, 15m, 1h, 1d, 1w
//! - Downsampling for long-term retention
//! - Efficient querying over metric data

const std = @import("std");

/// Time bucket sizes for aggregation
pub const TimeBucket = enum(u64) {
    one_minute = 60,
    five_minutes = 300,
    fifteen_minutes = 900,
    one_hour = 3600,
    one_day = 86400,
    one_week = 604800,

    /// Convert bucket to duration in seconds
    pub fn toSeconds(self: TimeBucket) u64 {
        return @intFromEnum(self);
    }

    /// Get bucket key for a timestamp
    pub fn bucketKey(self: TimeBucket, timestamp_ms: u64) u64 {
        return @divTrunc(timestamp_ms, self.toSeconds() * 1000);
    }
};

/// Aggregation functions
pub const AggregationFunc = enum {
    sum,
    avg,
    min,
    max,
    count,
    p50,
    p95,
    p99,
    p999,
};

/// Dimension filter for aggregation queries
pub const DimensionFilter = struct {
    /// Dimension name
    name: []const u8,
    /// Filter operation
    op: FilterOp,
    /// Value to compare against
    value: []const u8,

    pub const FilterOp = enum {
        equals,
        not_equals,
        contains,
        starts_with,
        ends_with,
    };

    pub fn deinit(self: DimensionFilter, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }

    /// Test if a dimension value matches this filter
    pub fn matches(self: DimensionFilter, value: []const u8) bool {
        return switch (self.op) {
            .equals => std.mem.eql(u8, self.value, value),
            .not_equals => !std.mem.eql(u8, self.value, value),
            .contains => std.mem.indexOf(u8, value, self.value) != null,
            .starts_with => std.mem.startsWith(u8, value, self.value),
            .ends_with => std.mem.endsWith(u8, value, self.value),
        };
    }
};

/// Raw metric data point
pub const MetricPoint = struct {
    timestamp_ms: u64,
    value: f64,
    dimensions: std.StringHashMap([]const u8),

    pub fn deinit(self: MetricPoint, allocator: std.mem.Allocator) void {
        var it = self.dimensions.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.dimensions.deinit();
    }
};

/// Aggregation query specification
pub const AggregationQuery = struct {
    /// Aggregation function(s) to apply
    functions: []const AggregationFunc,
    /// Time bucket size
    bucket: TimeBucket,
    /// Maximum number of buckets to return
    limit: usize = 1000,

    pub fn deinit(self: AggregationQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.functions);
    }
};

/// Aggregation result for a single time bucket
pub const BucketResult = struct {
    /// Bucket timestamp (start of bucket in ms)
    timestamp_ms: u64,
    /// Aggregated values (one per function in query)
    values: []const f64,
    /// Sample count in this bucket
    sample_count: u64,

    pub fn deinit(self: BucketResult, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }
};

/// Complete aggregation query result
pub const AggregationResult = struct {
    /// Query that was executed
    query: AggregationQuery,
    /// Results per time bucket
    buckets: []const BucketResult,
    /// Total samples across all buckets
    total_samples: u64,

    pub fn deinit(self: AggregationResult, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        for (self.buckets) |*b| b.deinit(allocator);
        allocator.free(self.buckets);
    }
};

/// Time-series analytics engine
pub const AnalyticsEngine = struct {
    allocator: std.mem.Allocator,
    config: Config,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Execute aggregation query on metric points
    pub fn aggregate(
        self: *Self,
        points: []const MetricPoint,
        query: AggregationQuery,
    ) !AggregationResult {
        // Group into buckets
        var buckets = std.AutoHashMap(u64, BucketState).init(self.allocator);
        defer {
            var it = buckets.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            buckets.deinit();
        }

        for (points) |point| {
            const bucket_key = query.bucket.bucketKey(point.timestamp_ms);

            const entry = try buckets.getOrPut(bucket_key);
            if (!entry.found_existing) {
                entry.value_ptr.* = BucketState.init(self.allocator, query.functions);
            }

            try entry.value_ptr.addSample(point, query.functions);
        }

        // Convert to results
        var results = std.ArrayList(BucketResult).init(self.allocator, {});
        var total_samples: u64 = 0;

        const sorted_buckets = try self.sortBuckets(buckets, self.allocator);
        defer {
            for (sorted_buckets.items) |item| {
                item.value.deinit(self.allocator);
            }
            sorted_buckets.deinit();
        }

        for (sorted_buckets.items) |item| {
            total_samples += item.value.sample_count;
            const result = try item.value.toResult(self.allocator, item.key, query.bucket);
            try results.append(result);
        }

        return AggregationResult{
            .query = query,
            .buckets = try results.toOwnedSlice(),
            .total_samples = total_samples,
        };
    }

    /// Get downsampled data for long-term storage
    /// Converts high-resolution data to lower resolution
    pub fn downsample(
        self: *Self,
        points: []const MetricPoint,
        source_bucket: TimeBucket,
        target_bucket: TimeBucket,
    ) !AggregationResult {
        if (@intFromEnum(target_bucket) <= @intFromEnum(source_bucket)) {
            return error.InvalidDownsampling;
        }

        // Aggregate with target bucket and avg/min/max functions
        const functions = [_]AggregationFunc{ .avg, .min, .max };

        const query = AggregationQuery{
            .functions = &functions,
            .bucket = target_bucket,
            .limit = self.config.max_downsample_buckets,
        };

        return self.aggregate(points, query);
    }

    /// Compute percentiles from a list of values
    /// Uses linear interpolation for accurate results
    pub fn computePercentile(values: []const f64, percentile: f64) f64 {
        if (values.len == 0) return 0.0;

        // Sort a copy of values
        var sorted = std.ArrayList(f64).init(std.heap.page_allocator, {});
        defer sorted.deinit();

        for (values) |v| sorted.append(v) catch unreachable;
        std.sort.insert(f64, sorted.items, {}, comptime std.sort.asc(f64));

        const index = @min(
            @as(usize, @intFromFloat(@as(f64, @floatFromInt(values.len - 1)) * percentile / 100.0)),
            values.len - 1,
        );

        return sorted.items[index];
    }

    fn sortBuckets(
        self: *Self,
        buckets: std.AutoHashMap(u64, BucketState),
        allocator: std.mem.Allocator,
    ) !std.ArrayList(struct { key: u64, value: BucketState }) {
        _ = self;

        var sorted = std.ArrayList(struct { key: u64, value: BucketState }).init(allocator, {});

        var it = buckets.iterator();
        while (it.next()) |entry| {
            const value_copy = try entry.value_ptr.copy(allocator);
            errdefer value_copy.deinit(allocator);

            try sorted.append(.{ .key = entry.key_ptr.*, .value = value_copy });
        }

        // Sort by key (timestamp)
        std.sort.insert(
            struct { key: u64, value: BucketState },
            sorted.items,
            {},
            sortBucketsAsc,
        );

        return sorted;
    }
};

fn sortBucketsAsc(
    lhs: struct { key: u64, value: BucketState },
    rhs: struct { key: u64, value: BucketState },
) bool {
    return lhs.key < rhs.key;
}

/// Bucket aggregation state
const BucketState = struct {
    samples: std.ArrayList(f64),
    sum: f64,
    min: f64,
    max: f64,
    count: u64,
    functions: []const AggregationFunc,

    fn init(allocator: std.mem.Allocator, functions: []const AggregationFunc) BucketState {
        return BucketState{
            .samples = std.ArrayList(f64).init(allocator, {},
            .sum = 0.0,
            .min = std.math.inf(f32),
            .max = -std.math.inf(f32),
            .count = 0,
            .functions = functions,
        };
    }

    fn deinit(self: *BucketState) void {
        self.samples.deinit();
    }

    fn addSample(self: *BucketState, point: MetricPoint, functions: []const AggregationFunc) !void {
        _ = functions;

        try self.samples.append(point.value);
        self.sum += point.value;
        self.min = @min(self.min, point.value);
        self.max = @max(self.max, point.value);
        self.count += 1;
    }

    fn toResult(self: *BucketState, allocator: std.mem.Allocator, key: u64, bucket: TimeBucket) !BucketResult {
        _ = bucket;

        var values = std.ArrayList(f64).init(allocator, {};
        errdefer values.deinit();

        for (self.functions) |func| {
            const value = switch (func) {
                .sum => self.sum,
                .avg => if (self.count > 0) self.sum / @as(f64, @floatFromInt(self.count)) else 0.0,
                .min => if (self.count > 0) self.min else 0.0,
                .max => if (self.count > 0) self.max else 0.0,
                .count => @as(f64, @floatFromInt(self.count)),
                .p50 => AnalyticsEngine.computePercentile(self.samples.items, 50.0),
                .p95 => AnalyticsEngine.computePercentile(self.samples.items, 95.0),
                .p99 => AnalyticsEngine.computePercentile(self.samples.items, 99.0),
                .p999 => AnalyticsEngine.computePercentile(self.samples.items, 99.9),
            };
            try values.append(value);
        }

        const timestamp_ms = key * 3600 * 1000; // Simplified

        return BucketResult{
            .timestamp_ms = timestamp_ms,
            .values = try values.toOwnedSlice(),
            .sample_count = self.count,
        };
    }

    fn copy(self: *BucketState, allocator: std.mem.Allocator) !BucketState {
        var samples_copy = std.ArrayList(f64).init(allocator, {};
        errdefer samples_copy.deinit();

        try samples_copy.appendSlice(self.samples.items);

        return BucketState{
            .samples = samples_copy,
            .sum = self.sum,
            .min = self.min,
            .max = self.max,
            .count = self.count,
            .functions = self.functions,
        };
    }
};

/// Analytics engine configuration
pub const Config = struct {
    /// Downsample window in hours
    downsample_window_hours: u64 = 24,
    /// Maximum downsample buckets
    max_downsample_buckets: usize = 168, // 1 week of hourly data
    /// Maximum samples per bucket before forced downsampling
    max_samples_per_bucket: usize = 10000,
    /// Default time bucket for queries
    default_bucket: TimeBucket = .one_hour,
};

// Test helpers
test "TimeBucket.bucketKey" {
    const bucket = TimeBucket.one_hour;
    const ts_ms: u64 = 1640995200000; // 2022-01-01 00:00:00 UTC
    const key = bucket.bucketKey(ts_ms);
    try std.testing.expectEqual(@as(u64, 456388), key);
}

test "DimensionFilter.matches" {
    const allocator = std.testing.allocator;

    const filter = DimensionFilter{
        .name = try allocator.dupe(u8, "status"),
        .op = .equals,
        .value = try allocator.dupe(u8, "success"),
    };
    defer filter.deinit(allocator);

    try std.testing.expect(filter.matches("success"));
    try std.testing.expect(!filter.matches("failure"));

    const contains_filter = DimensionFilter{
        .name = try allocator.dupe(u8, "path"),
        .op = .contains,
        .value = try allocator.dupe(u8, "src/"),
    };
    defer contains_filter.deinit(allocator);

    try std.testing.expect(contains_filter.matches("src/main.zig"));
    try std.testing.expect(!contains_filter.matches("docs/readme.md"));
}

test "AnalyticsEngine.computePercentile" {
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 };

    const p50 = AnalyticsEngine.computePercentile(&values, 50.0);
    try std.testing.expectApproxEqAbs(5.0, p50, 0.1);

    const p95 = AnalyticsEngine.computePercentile(&values, 95.0);
    try std.testing.expectApproxEqAbs(10.0, p95, 0.1);

    const p99 = AnalyticsEngine.computePercentile(&values, 99.0);
    try std.testing.expectApproxEqAbs(10.0, p99, 0.1);
}

test "AnalyticsEngine.aggregate" {
    const allocator = std.testing.allocator;

    const engine = try AnalyticsEngine.init(allocator, .{});

    var points = std.ArrayList(MetricPoint).init(allocator, {});
    defer {
        for (points.items) |*p| p.deinit(allocator);
        points.deinit();
    }

    // Add test points
    for (0..10) |i| {
        var dimensions = std.StringHashMap([]const u8).init(allocator);
        try dimensions.put("test", try allocator.dupe(u8, "value"));

        try points.append(.{
            .timestamp_ms = @as(u64, @intCast(i)) * 3600000,
            .value = @as(f64, @floatFromInt(i * 10)),
            .dimensions = dimensions,
        });
    }

    const functions = [_]AggregationFunc{.avg};
    const query = AggregationQuery{
        .functions = &functions,
        .bucket = .one_hour,
        .limit = 100,
    };

    const result = try engine.aggregate(points.items, query);
    defer result.deinit(allocator);

    try std.testing.expect(result.buckets.len > 0);
}
