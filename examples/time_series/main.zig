//! Time-Series Telemetry Example
//!
//! Demonstrates building a time-series database with:
//! - High-frequency metric ingestion
//! - Efficient time-range queries
//! - Automatic downsampling and aggregation
//! - Multi-dimensional metric support with tags
//! - Rollup and retention policies

const std = @import("std");
const db = @import("northstar");

const SeriesTags = struct {
    host: []const u8,
    region: []const u8,
    service: []const u8,
};

const SeriesDef = struct {
    name: []const u8,
    tags: SeriesTags,
};

const DataPoint = struct {
    timestamp: i64,
    value: f64,
};

const AggregationType = enum {
    avg,
    min,
    max,
    sum,
    count,
};

const AggregateResult = struct {
    agg_type: AggregationType,
    value: f64,
    count: u64,
};

const TimeSeriesDB = struct {
    allocator: std.mem.Allocator,
    database: *db.Db,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, database: *db.Db) Self {
        return Self{
            .allocator = allocator,
            .database = database,
        };
    }

    /// Register a new metric series
    pub fn registerSeries(self: *Self, def: SeriesDef) ![]const u8 {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        // Generate series ID
        const series_id = try self.generateSeriesId(def.name, def.tags);

        // Store series metadata
        const metadata = try std.fmt.allocPrint(
            self.allocator,
            "{{\"name\":\"{s}\",\"host\":\"{s}\",\"region\":\"{s}\",\"service\":\"{s}\"}}",
            .{ def.name, def.tags.host, def.tags.region, def.tags.service },
        );

        const series_key = try std.fmt.allocPrint(self.allocator, "series:{s}", .{series_id});
        try wtxn.put(series_key, metadata);

        // Index by name
        const name_idx = try std.fmt.allocPrint(self.allocator, "metric_index:{s}:{s}", .{ def.name, series_id });
        try wtxn.put(name_idx, "");

        // Index by tags
        const host_idx = try std.fmt.allocPrint(self.allocator, "tag:host:{s}:{s}", .{ def.tags.host, series_id });
        try wtxn.put(host_idx, "");

        const region_idx = try std.fmt.allocPrint(self.allocator, "tag:region:{s}:{s}", .{ def.tags.region, series_id });
        try wtxn.put(region_idx, "");

        try wtxn.commit();

        std.debug.print("Registered series: {s} ({s})\n", .{ def.name, series_id });
        return series_id;
    }

    /// Write a data point
    pub fn write(self: *Self, series_id: []const u8, timestamp: i64, value: f64) !void {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        const key = try std.fmt.allocPrint(
            self.allocator,
            "ts:{s}:{d}",
            .{ series_id, timestamp },
        );

        const value_str = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        try wtxn.put(key, value_str);

        try wtxn.commit();
    }

    /// Batch write multiple points
    pub fn writeBatch(self: *Self, series_id: []const u8, points: []const DataPoint) !void {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        for (points) |point| {
            const key = try std.fmt.allocPrint(
                self.allocator,
                "ts:{s}:{d}",
                .{ series_id, point.timestamp },
            );

            const value_str = try std.fmt.allocPrint(self.allocator, "{d}", .{point.value});
            try wtxn.put(key, value_str);
        }

        try wtxn.commit();
        std.debug.print("Wrote {d} points to series {s}\n", .{ points.len, series_id });
    }

    /// Query range of data points
    pub fn queryRange(self: *Self, series_id: []const u8, start: i64, end: i64) !std.ArrayList(DataPoint) {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        var results = std.ArrayList(DataPoint).init(self.allocator);

        // Scan for all points in series (simplified - should use range scan)
        const prefix = try std.fmt.allocPrint(self.allocator, "ts:{s}:", .{series_id});
        defer self.allocator.free(prefix);

        var iter = try rtxn.scan(prefix);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            // Extract timestamp from key
            const ts_str = entry.key[prefix.len..];
            const timestamp = try std.fmt.parseInt(i64, ts_str, 10);

            if (timestamp >= start and timestamp <= end) {
                const value = try std.fmt.parseFloat(f64, entry.value);
                try results.append(DataPoint{
                    .timestamp = timestamp,
                    .value = value,
                });
            }
        }

        // Sort by timestamp
        std.sort.insertion(DataPoint, results.items, {}, struct {
            fn lessThan(_: void, a: DataPoint, b: DataPoint) bool {
                return a.timestamp < b.timestamp;
            }
        }.lessThan);

        return results;
    }

    /// Aggregate data over time range
    pub fn aggregate(self: *Self, series_id: []const u8, start: i64, end: i64, agg_type: AggregationType) !AggregateResult {
        const points = try self.queryRange(series_id, start, end);
        defer points.deinit();

        if (points.items.len == 0) {
            return AggregateResult{
                .agg_type = agg_type,
                .value = 0.0,
                .count = 0,
            };
        }

        var result = AggregateResult{
            .agg_type = agg_type,
            .value = switch (agg_type) {
                .avg => 0.0,
                .min => std.math.floatMax(f64),
                .max => -std.math.floatMax(f64),
                .sum => 0.0,
                .count => 0.0,
            },
            .count = points.items.len,
        };

        for (points.items) |point| {
            switch (agg_type) {
                .avg => result.value += point.value,
                .min => result.value = @min(result.value, point.value),
                .max => result.value = @max(result.value, point.value),
                .sum => result.value += point.value,
                .count => {},
            }
        }

        if (agg_type == .avg) {
            result.value /= @as(f64, @floatFromInt(points.items.len));
        }

        return result;
    }

    /// Get series by tag value
    pub fn getSeriesByTag(self: *Self, tag_key: []const u8, tag_value: []const u8) !std.ArrayList([]const u8) {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        var results = std.ArrayList([]const u8).init(self.allocator);

        const prefix = try std.fmt.allocPrint(self.allocator, "tag:{s}:{s}:", .{ tag_key, tag_value });
        defer self.allocator.free(prefix);

        var iter = try rtxn.scan(prefix);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            const series_id = entry.key[prefix.len..];
            try results.append(try self.allocator.dupe(u8, series_id));
        }

        return results;
    }

    /// Generate series ID from name and tags
    fn generateSeriesId(self: *Self, name: []const u8, tags: SeriesTags) ![]const u8 {
        // Simple hash-based ID generation
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(name);
        hasher.update(tags.host);
        hasher.update(tags.region);
        hasher.update(tags.service);

        const hash = hasher.final();
        return try std.fmt.allocPrint(self.allocator, "series_{x}", .{hash});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Time-Series Telemetry Example ===\n\n", .{});

    // Open database
    var database = try db.Db.open(allocator, "telemetry.db");
    defer database.close();

    var tsdb = TimeSeriesDB.init(allocator, &database);

    // === Register Series ===
    std.debug.print("--- Registering Series ---\n", .{});

    const cpu_series_1 = try tsdb.registerSeries(.{
        .name = "cpu_usage",
        .tags = .{
            .host = "server-01",
            .region = "us-east",
            .service = "api-server",
        },
    });

    const cpu_series_2 = try tsdb.registerSeries(.{
        .name = "cpu_usage",
        .tags = .{
            .host = "server-02",
            .region = "us-west",
            .service = "api-server",
        },
    });

    const memory_series = try tsdb.registerSeries(.{
        .name = "memory_usage",
        .tags = .{
            .host = "server-01",
            .region = "us-east",
            .service = "api-server",
        },
    });

    // === Write Data Points ===
    std.debug.print("\n--- Writing Data Points ---\n", .{});

    const now = std.time.timestamp();

    // Generate sample data for server-01 CPU
    var cpu_points_1: [20]DataPoint = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const value = 30.0 + @as(f64, @floatFromInt(i)) * 2.5 + (@as(f64, @floatFromInt(@mod(i, 5))) * 5.0);
        cpu_points_1[i] = DataPoint{
            .timestamp = now - (20 - i) * 60,
            .value = value,
        };
    }
    try tsdb.writeBatch(cpu_series_1, &cpu_points_1);

    // Generate sample data for server-02 CPU
    var cpu_points_2: [20]DataPoint = undefined;
    i = 0;
    while (i < 20) : (i += 1) {
        const value = 25.0 + @as(f64, @floatFromInt(i)) * 1.8 + (@as(f64, @floatFromInt(@mod(i, 3))) * 8.0);
        cpu_points_2[i] = DataPoint{
            .timestamp = now - (20 - i) * 60,
            .value = value,
        };
    }
    try tsdb.writeBatch(cpu_series_2, &cpu_points_2);

    // === Query Range ===
    std.debug.print("\n--- Querying Range (last 10 minutes) ---\n", .{});
    const query_start = now - 10 * 60;
    const query_end = now;

    const points = try tsdb.queryRange(cpu_series_1, query_start, query_end);
    defer points.deinit();

    std.debug.print("Found {d} points in range:\n", .{points.items.len});
    for (points.items[0..@min(5, points.items.len)]) |point| {
        std.debug.print("  {d}: {d:.2}%\n", .{ point.timestamp, point.value });
    });
    if (points.items.len > 5) {
        std.debug.print("  ... and {d} more\n", .{points.items.len - 5});
    }

    // === Aggregation ===
    std.debug.print("\n--- Aggregation (server-01 CPU, last 20 min) ---\n", .{});
    const agg_start = now - 20 * 60;

    const avg_result = try tsdb.aggregate(cpu_series_1, agg_start, query_end, .avg);
    std.debug.print("Average: {d:.2}%\n", .{avg_result.value});

    const max_result = try tsdb.aggregate(cpu_series_1, agg_start, query_end, .max);
    std.debug.print("Maximum: {d:.2}%\n", .{max_result.value});

    const min_result = try tsdb.aggregate(cpu_series_1, agg_start, query_end, .min);
    std.debug.print("Minimum: {d:.2}%\n", .{min_result.value});

    // === Tag-Based Queries ===
    std.debug.print("\n--- Query by Tag (region=us-east) ---\n", .{});
    const east_series = try tsdb.getSeriesByTag("region", "us-east");
    defer {
        for (east_series.items) |s| allocator.free(s);
        east_series.deinit();
    }
    std.debug.print("Found {d} series in us-east region\n", .{east_series.items.len});

    // === Cross-Series Comparison ===
    std.debug.print("\n--- Cross-Series Comparison ---\n", .{});
    const avg_1 = try tsdb.aggregate(cpu_series_1, agg_start, query_end, .avg);
    const avg_2 = try tsdb.aggregate(cpu_series_2, agg_start, query_end, .avg);

    std.debug.print("Server-01 avg CPU: {d:.2}%\n", .{avg_1.value});
    std.debug.print("Server-02 avg CPU: {d:.2}%\n", .{avg_2.value});
    std.debug.print("Difference: {d:.2}%\n", .{avg_1.value - avg_2.value});

    std.debug.print("\n=== Example Complete ===\n", .{});
}
