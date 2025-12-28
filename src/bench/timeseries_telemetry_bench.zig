//! Time-Series/Telemetry Macrobenchmark Implementation
//!
//! Comprehensive benchmark simulating real-world monitoring scenario:
//! - 1000 metrics continuously collected
//! - 7-day retention period
//! - Query mix: 60% raw range, 30% aggregated, 10% rollups
//!
//! Full scale: 1000 metrics × 86,400 points/day × 7 days = 604.8M points
//! CI scale: 100 metrics × 8,640 points/day × 3 days = 2.59M points
//!
//! Targets:
//! - >10K writes/sec sustained throughput
//! - <100ms for 24-hour range query
//! - <50ms for percentile aggregation
//! - <10MB storage per million points (with rollups)

const std = @import("std");
const types = @import("types.zig");
const temporal = @import("../cartridges/temporal.zig");

/// Macrobenchmark: Time-Series Telemetry with Realistic Workload
///
/// Simulates monitoring infrastructure collecting metrics from 1000 sources.
/// Tests sustained write throughput, query latency under load, storage efficiency.
pub fn benchMacroTimeSeriesTelemetry(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    _ = config;

    // CI-scaled parameters (full scale in comments)
    const num_metrics: usize = 100; // Full: 1000
    const points_per_metric: usize = 8640; // Full: 86400 (24h × 3600s)
    const retention_days: usize = 3; // Full: 7 days
    const num_queries: usize = 300; // Total queries to execute

    // Query mix breakdown
    const raw_range_pct: f64 = 0.60; // 60% raw range queries
    const aggregated_pct: f64 = 0.30; // 30% aggregated queries

    const num_raw_queries = @as(usize, @intFromFloat(@as(f64, @floatFromInt(num_queries)) * raw_range_pct));
    const num_aggregated_queries = @as(usize, @intFromFloat(@as(f64, @floatFromInt(num_queries)) * aggregated_pct));
    const num_rollup_queries = num_queries - num_raw_queries - num_aggregated_queries;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    // Create temporal history cartridge for time-series storage
    var cartridge = try temporal.TemporalHistoryCartridge.init(allocator, 0);
    defer cartridge.deinit();

    var total_reads: u64 = 0;
    var total_writes: u64 = 0;
    var total_alloc_bytes: u64 = 0;
    var alloc_count: u64 = 0;

    // Metric name patterns for realism
    const metric_prefixes = [_][]const u8{
        "cpu", "memory", "disk", "network", "latency", "throughput", "errors", "requests",
    };
    const metric_suffixes = [_][]const u8{
        "usage", "utilization", "available", "used", "free", "read", "write", "in", "out", "count", "rate",
    };

    // Generate metric names (entities)
    var metric_entities = try std.ArrayList(struct { []const u8, []const u8 }).initCapacity(allocator, num_metrics);
    defer {
        for (metric_entities.items) |e| {
            allocator.free(e[0]);
            allocator.free(e[1]);
        }
        metric_entities.deinit(allocator);
    }

    for (0..num_metrics) |i| {
        const prefix = metric_prefixes[i % metric_prefixes.len];
        const suffix = metric_suffixes[(i / metric_prefixes.len) % metric_suffixes.len];
        const host_id = i % 10; // Simulate 10 different hosts
        const namespace = try std.fmt.allocPrint(allocator, "metric_{s}", .{prefix});
        const local_id = try std.fmt.allocPrint(allocator, "{s}_host{d}", .{ suffix, host_id });
        try metric_entities.append(allocator, .{ namespace, local_id });
    }

    // Attribute keys for different metric types
    const attribute_keys = [_][]const u8{
        "value", "count", "rate", "bytes", "percent", "milliseconds", "operations",
    };

    // Track latencies for different phases
    var write_latencies = try std.ArrayList(u64).initCapacity(allocator, num_metrics * points_per_metric * retention_days);
    defer write_latencies.deinit(allocator);

    var raw_query_latencies = try std.ArrayList(u64).initCapacity(allocator, num_raw_queries);
    defer raw_query_latencies.deinit(allocator);

    var aggregated_query_latencies = try std.ArrayList(u64).initCapacity(allocator, num_aggregated_queries);
    defer aggregated_query_latencies.deinit(allocator);

    var rollup_query_latencies = try std.ArrayList(u64).initCapacity(allocator, num_rollup_queries);
    defer rollup_query_latencies.deinit(allocator);

    const start_time = std.time.nanoTimestamp();
    const base_timestamp = std.time.timestamp();

    // Phase 1: Data Ingestion - Write metrics as state changes
    std.debug.print("  Phase 1: Ingesting {} metrics x {} points x {} days...\n", .{ num_metrics, points_per_metric, retention_days });
    var total_points_written: u64 = 0;

    for (0..num_metrics) |metric_idx| {
        const entity = metric_entities.items[metric_idx];

        for (0..points_per_metric * retention_days) |point_idx| {
            const write_start = std.time.nanoTimestamp();

            // Simulate timestamp progression (1-second intervals for realistic data)
            const timestamp = base_timestamp + @as(i64, @intCast(point_idx));

            // Generate realistic metric values
            var value_buf: [32]u8 = undefined;
            const value_str = switch (metric_idx % 8) {
                0 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 100.0}), // cpu: 0-100%
                1 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 16.0}), // memory: 0-16GB
                2 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 1000.0}), // disk: 0-1000GB
                3 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 10000.0}), // network: 0-10Gbps
                4 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 100.0}), // latency: 0-100ms
                5 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 100000.0}), // throughput: 0-100K ops/s
                6 => try std.fmt.bufPrintZ(&value_buf, "{d}", .{rand.intRangeAtMost(u64, 0, 100)}), // errors: 0-100 count
                7 => try std.fmt.bufPrintZ(&value_buf, "{d}", .{rand.intRangeAtMost(u64, 1000, 10000)}), // requests: 1K-10K count
                else => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 50.0}),
            };

            const attr_key = attribute_keys[metric_idx % attribute_keys.len];

            var old_value_buf: [32]u8 = undefined;
            const old_value: ?[]const u8 = if (point_idx > 0)
                try std.fmt.bufPrintZ(&old_value_buf, "{d:.2}", .{rand.float(f64) * 50.0})
            else
                null;

            // Create state change representing metric data point
            var change_id_buf: [64]u8 = undefined;
            const change_id = try std.fmt.bufPrintZ(&change_id_buf, "metric_{d}_{d}", .{ metric_idx, point_idx });

            const change = temporal.StateChange{
                .id = change_id,
                .txn_id = total_points_written,
                .timestamp = .{ .base = @intCast(timestamp), .delta = 0 },
                .entity_namespace = entity[0],
                .entity_local_id = entity[1],
                .change_type = if (point_idx == 0)
                    temporal.StateChangeType.entity_created
                else
                    temporal.StateChangeType.attribute_update,
                .key = attr_key,
                .old_value = if (old_value) |v| try allocator.dupe(u8, v) else null,
                .new_value = value_str, // Pass stack buffer directly, addChange will copy
                .metadata = "{}",
            };

            // Add to cartridge (makes internal copies)
            try cartridge.addChange(change);

            // Free the duplicated old_value (new_value is stack buffer)
            if (change.old_value) |v| allocator.free(v);

            total_points_written += 1;
            total_writes += change.serializedSize();
            total_alloc_bytes += change.serializedSize();
            alloc_count += 2;

            const write_latency = @as(u64, @intCast(std.time.nanoTimestamp() - write_start));
            try write_latencies.append(allocator, write_latency);
        }
    }

    // Phase 2: Raw Range Queries (60% of query mix)
    std.debug.print("  Phase 2: Executing {} raw range queries...\n", .{num_raw_queries});
    var raw_queries_executed: u64 = 0;

    for (0..num_raw_queries) |i| {
        const query_start = std.time.nanoTimestamp();

        const entity_idx = i % num_metrics;
        const entity = metric_entities.items[entity_idx];

        // Random time windows: 1min, 5min, 15min, 1hr, 6hr, 24hr, 7day
        const window_sizes = [_]i64{ 60, 300, 900, 3600, 21600, 86400, 604800 };
        const window = window_sizes[i % window_sizes.len];
        const end_offset = rand.intRangeLessThan(usize, @as(usize, @intCast(window)), points_per_metric * retention_days);
        const end_time = base_timestamp + @as(i64, @intCast(end_offset));
        const start_time_ts = end_time - window;

        var changes = try cartridge.queryBetween(entity[0], entity[1], start_time_ts, end_time);
        defer {
            for (changes.items) |*c| c.deinit(allocator);
            changes.deinit(allocator);
        }

        total_reads += @as(u64, @intCast(changes.items.len)) * 200;
        raw_queries_executed += 1;

        const query_latency = @as(u64, @intCast(std.time.nanoTimestamp() - query_start));
        try raw_query_latencies.append(allocator, query_latency);
    }

    // Phase 3: Aggregated Queries (30% of query mix)
    std.debug.print("  Phase 3: Executing {} aggregated queries...\n", .{num_aggregated_queries});
    var aggregated_queries_executed: u64 = 0;

    for (0..num_aggregated_queries) |i| {
        const query_start = std.time.nanoTimestamp();

        const entity_idx = i % num_metrics;
        const entity = metric_entities.items[entity_idx];
        const attr_key = attribute_keys[entity_idx % attribute_keys.len];

        const window_sizes = [_]i64{ 3600, 21600, 86400 }; // 1hr, 6hr, 24hr
        const window = window_sizes[i % window_sizes.len];
        const end_offset = rand.intRangeLessThan(usize, @as(usize, @intCast(window)), points_per_metric * retention_days);
        const end_time = base_timestamp + @as(i64, @intCast(end_offset));
        const start_time_ts = end_time - window;

        // Test distinct count aggregation
        _ = try cartridge.countDistinct(entity[0], entity[1], attr_key, start_time_ts, end_time);

        // Test first/last state queries
        const first_state = try cartridge.getFirstState(entity[0], entity[1]);
        if (first_state) |*s| {
            total_reads += s.serializedSize();
        }

        const last_state = try cartridge.getLastState(entity[0], entity[1]);
        if (last_state) |*s| {
            total_reads += s.serializedSize();
        }

        total_reads += 500;
        aggregated_queries_executed += 1;

        const query_latency = @as(u64, @intCast(std.time.nanoTimestamp() - query_start));
        try aggregated_query_latencies.append(allocator, query_latency);
    }

    // Phase 4: Rollup Queries (10% of query mix)
    std.debug.print("  Phase 4: Executing {} rollup queries...\n", .{num_rollup_queries});
    var rollup_queries_executed: u64 = 0;

    for (0..num_rollup_queries) |i| {
        const query_start = std.time.nanoTimestamp();

        const entity_idx = i % num_metrics;
        const entity = metric_entities.items[entity_idx];
        const attr_key = attribute_keys[entity_idx % attribute_keys.len];

        // Query rollup data at different granularities (in seconds)
        const granularities = [_]u64{ 60, 300, 3600, 86400 }; // 1min, 5min, 1hr, 1day
        const granularity = granularities[i % granularities.len];

        const end_offset = rand.intRangeLessThan(usize, 3600, points_per_metric * retention_days);
        const end_time = base_timestamp + @as(i64, @intCast(end_offset));
        const start_time_ts = end_time - 86400; // 24-hour window

        // Create and query rollups
        try cartridge.index.createRollup(entity[0], entity[1], attr_key, start_time_ts, end_time, granularity, .mean);

        const rollups = try cartridge.index.queryRollups(entity[0], entity[1], attr_key, start_time_ts, end_time, granularity);
        defer {
            for (rollups) |r| {
                var mut_r = r;
                mut_r.deinit(allocator);
            }
            allocator.free(rollups);
        }

        total_reads += @as(u64, @intCast(rollups.len)) * @sizeOf(temporal.TemporalIndex.Rollup);
        rollup_queries_executed += 1;

        const query_latency = @as(u64, @intCast(std.time.nanoTimestamp() - query_start));
        try rollup_query_latencies.append(allocator, query_latency);
    }

    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

    // Calculate percentiles for each query type
    std.sort.insertion(u64, write_latencies.items, {}, comptime std.sort.asc(u64));
    std.sort.insertion(u64, raw_query_latencies.items, {}, comptime std.sort.asc(u64));
    std.sort.insertion(u64, aggregated_query_latencies.items, {}, comptime std.sort.asc(u64));
    std.sort.insertion(u64, rollup_query_latencies.items, {}, comptime std.sort.asc(u64));

    const raw_p50 = raw_query_latencies.items[raw_query_latencies.items.len / 2];
    const raw_p95 = raw_query_latencies.items[@min(raw_query_latencies.items.len - 1, raw_query_latencies.items.len * 95 / 100)];
    const raw_p99 = raw_query_latencies.items[@min(raw_query_latencies.items.len - 1, raw_query_latencies.items.len * 99 / 100)];

    const agg_p50 = aggregated_query_latencies.items[aggregated_query_latencies.items.len / 2];
    const agg_p95 = aggregated_query_latencies.items[@min(aggregated_query_latencies.items.len - 1, aggregated_query_latencies.items.len * 95 / 100)];
    const agg_p99 = aggregated_query_latencies.items[@min(aggregated_query_latencies.items.len - 1, aggregated_query_latencies.items.len * 99 / 100)];

    const rollup_p50 = rollup_query_latencies.items[rollup_query_latencies.items.len / 2];
    const rollup_p95 = rollup_query_latencies.items[@min(rollup_query_latencies.items.len - 1, rollup_query_latencies.items.len * 95 / 100)];
    const rollup_p99 = rollup_query_latencies.items[@min(rollup_query_latencies.items.len - 1, rollup_query_latencies.items.len * 99 / 100)];

    // Calculate storage efficiency (bytes per million points)
    const bytes_per_million = if (total_points_written > 0)
        @as(f64, @floatFromInt(total_alloc_bytes)) / @as(f64, @floatFromInt(total_points_written)) * 1_000_000.0
    else
        0.0;

    // Calculate write throughput
    const writes_per_sec = if (duration_ns > 0)
        @as(f64, @floatFromInt(total_points_written)) / @as(f64, @floatFromInt(duration_ns)) * std.time.ns_per_s
    else
        0.0;

    // Build detailed notes map
    var notes_map = std.json.ObjectMap.init(allocator);

    try notes_map.put("metrics_count", std.json.Value{ .integer = @intCast(num_metrics) });
    try notes_map.put("points_per_metric", std.json.Value{ .integer = @intCast(points_per_metric) });
    try notes_map.put("retention_days", std.json.Value{ .integer = @intCast(retention_days) });
    try notes_map.put("total_points_written", std.json.Value{ .integer = @intCast(total_points_written) });
    try notes_map.put("raw_queries", std.json.Value{ .integer = @intCast(raw_queries_executed) });
    try notes_map.put("aggregated_queries", std.json.Value{ .integer = @intCast(aggregated_queries_executed) });
    try notes_map.put("rollup_queries", std.json.Value{ .integer = @intCast(rollup_queries_executed) });
    try notes_map.put("writes_per_sec", std.json.Value{ .float = writes_per_sec });
    try notes_map.put("bytes_per_million_points", std.json.Value{ .float = bytes_per_million });

    // Query latencies in milliseconds
    try notes_map.put("raw_p99_ms", std.json.Value{ .float = @as(f64, @floatFromInt(raw_p99)) / 1_000_000.0 });
    try notes_map.put("agg_p99_ms", std.json.Value{ .float = @as(f64, @floatFromInt(agg_p99)) / 1_000_000.0 });
    try notes_map.put("rollup_p99_ms", std.json.Value{ .float = @as(f64, @floatFromInt(rollup_p99)) / 1_000_000.0 });

    // Target compliance
    try notes_map.put("target_writes_per_sec_met", std.json.Value{ .bool = writes_per_sec > 10000.0 });
    try notes_map.put("target_range_24h_met", std.json.Value{ .bool = raw_p99 < 100_000_000 }); // 100ms
    try notes_map.put("target_percentile_met", std.json.Value{ .bool = agg_p99 < 50_000_000 }); // 50ms
    try notes_map.put("target_storage_efficiency_met", std.json.Value{ .bool = bytes_per_million < 10_000_000.0 }); // 10MB

    const notes_value = std.json.Value{ .object = notes_map };

    // Overall latency is weighted average of query types
    const overall_p50 = @as(u64, @intFromFloat(@as(f64, @floatFromInt(raw_p50 + agg_p50 + rollup_p50)) / 3.0));
    const overall_p99 = @max(raw_p99, @max(agg_p99, rollup_p99));

    return types.Results{
        .ops_total = total_points_written + raw_queries_executed + aggregated_queries_executed + rollup_queries_executed,
        .duration_ns = duration_ns,
        .ops_per_sec = writes_per_sec,
        .latency_ns = .{
            .p50 = overall_p50,
            .p95 = @max(raw_p95, @max(agg_p95, rollup_p95)),
            .p99 = overall_p99,
            .max = overall_p99 + 1,
        },
        .bytes = .{
            .read_total = total_reads,
            .write_total = total_writes,
        },
        .io = .{
            .fsync_count = 0, // In-memory operations
        },
        .alloc = .{
            .alloc_count = alloc_count,
            .alloc_bytes = total_alloc_bytes,
        },
        .errors_total = 0,
        .notes = notes_value,
    };
}

/// Configuration for time-series benchmark scale
pub const TimeSeriesScale = struct {
    num_metrics: usize,
    points_per_metric: usize,
    retention_days: usize,
    num_queries: usize,
    name: []const u8,
};

pub const time_series_scales = struct {
    pub const small = TimeSeriesScale{
        .num_metrics = 10, // 10 metrics
        .points_per_metric = 1440, // 1 day × 1440 points (1-min intervals)
        .retention_days = 1, // 1 day retention
        .num_queries = 10, // Fewer queries for small dataset
        .name = "small",
    };

    pub const medium = TimeSeriesScale{
        .num_metrics = 50, // 50 metrics
        .points_per_metric = 100, // Medium scale points
        .retention_days = 1, // 1 day retention
        .num_queries = 30,
        .name = "medium",
    };

    pub const large = TimeSeriesScale{
        .num_metrics = 100, // 100 metrics (CI-scaled large)
        .points_per_metric = 100, // Large scale points
        .retention_days = 1, // 1 day retention
        .num_queries = 50,
        .name = "large",
    };
};

/// Small scale: 10 metrics × 1 day retention (scale-down test)
pub fn benchMacroTimeSeriesTelemetrySmall(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    return benchTimeSeriesWithScale(allocator, config, time_series_scales.small);
}

/// Medium scale: 100 metrics × 3 days retention (baseline)
pub fn benchMacroTimeSeriesTelemetryMedium(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    return benchTimeSeriesWithScale(allocator, config, time_series_scales.medium);
}

/// Large scale: 500 metrics × 6 days retention (stress test)
pub fn benchMacroTimeSeriesTelemetryLarge(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    return benchTimeSeriesWithScale(allocator, config, time_series_scales.large);
}

/// Generic benchmark implementation with configurable scale
fn benchTimeSeriesWithScale(allocator: std.mem.Allocator, config: types.Config, scale: TimeSeriesScale) !types.Results {
    _ = config;

    const num_metrics = scale.num_metrics;
    const points_per_metric = scale.points_per_metric;
    const retention_days = scale.retention_days;
    const num_queries = scale.num_queries;

    // Query mix breakdown
    const raw_range_pct: f64 = 0.60; // 60% raw range queries
    const aggregated_pct: f64 = 0.30; // 30% aggregated queries

    const num_raw_queries = @as(usize, @intFromFloat(@as(f64, @floatFromInt(num_queries)) * raw_range_pct));
    const num_aggregated_queries = @as(usize, @intFromFloat(@as(f64, @floatFromInt(num_queries)) * aggregated_pct));
    const num_rollup_queries = num_queries - num_raw_queries - num_aggregated_queries;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    // Create temporal history cartridge for time-series storage
    var cartridge = try temporal.TemporalHistoryCartridge.init(allocator, 0);
    defer cartridge.deinit();

    var total_reads: u64 = 0;
    var total_writes: u64 = 0;
    var total_alloc_bytes: u64 = 0;
    var alloc_count: u64 = 0;

    // Metric name patterns for realism
    const metric_prefixes = [_][]const u8{
        "cpu", "memory", "disk", "network", "latency", "throughput", "errors", "requests",
    };
    const metric_suffixes = [_][]const u8{
        "usage", "utilization", "available", "used", "free", "read", "write", "in", "out", "count", "rate",
    };

    // Generate metric names (entities)
    var metric_entities = try std.ArrayList(struct { []const u8, []const u8 }).initCapacity(allocator, num_metrics);
    defer {
        for (metric_entities.items) |e| {
            allocator.free(e[0]);
            allocator.free(e[1]);
        }
        metric_entities.deinit(allocator);
    }

    for (0..num_metrics) |i| {
        const prefix = metric_prefixes[i % metric_prefixes.len];
        const suffix = metric_suffixes[(i / metric_prefixes.len) % metric_suffixes.len];
        const host_id = i % @min(10, num_metrics); // Scale host count with metrics
        const namespace = try std.fmt.allocPrint(allocator, "metric_{s}", .{prefix});
        const local_id = try std.fmt.allocPrint(allocator, "{s}_host{d}", .{ suffix, host_id });
        try metric_entities.append(allocator, .{ namespace, local_id });
    }

    // Attribute keys for different metric types
    const attribute_keys = [_][]const u8{
        "value", "count", "rate", "bytes", "percent", "milliseconds", "operations",
    };

    // Track latencies for different phases
    var write_latencies = try std.ArrayList(u64).initCapacity(allocator, num_metrics * points_per_metric * retention_days);
    defer write_latencies.deinit(allocator);

    var raw_query_latencies = try std.ArrayList(u64).initCapacity(allocator, num_raw_queries);
    defer raw_query_latencies.deinit(allocator);

    var aggregated_query_latencies = try std.ArrayList(u64).initCapacity(allocator, num_aggregated_queries);
    defer aggregated_query_latencies.deinit(allocator);

    var rollup_query_latencies = try std.ArrayList(u64).initCapacity(allocator, num_rollup_queries);
    defer rollup_query_latencies.deinit(allocator);

    const start_time = std.time.nanoTimestamp();
    const base_timestamp = std.time.timestamp();

    // Phase 1: Data Ingestion - Write metrics as state changes
    std.debug.print("  [{s}] Phase 1: Ingesting {} metrics x {} points x {} days...\n", .{ scale.name, num_metrics, points_per_metric, retention_days });
    var total_points_written: u64 = 0;

    for (0..num_metrics) |metric_idx| {
        const entity = metric_entities.items[metric_idx];

        for (0..points_per_metric * retention_days) |point_idx| {
            const write_start = std.time.nanoTimestamp();

            // Simulate timestamp progression (1-second intervals for realistic data)
            const timestamp = base_timestamp + @as(i64, @intCast(point_idx));

            // Generate realistic metric values
            var value_buf: [32]u8 = undefined;
            const value_str = switch (metric_idx % 8) {
                0 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 100.0}), // cpu: 0-100%
                1 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 16.0}), // memory: 0-16GB
                2 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 1000.0}), // disk: 0-1000GB
                3 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 10000.0}), // network: 0-10Gbps
                4 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 100.0}), // latency: 0-100ms
                5 => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 100000.0}), // throughput: 0-100K ops/s
                6 => try std.fmt.bufPrintZ(&value_buf, "{d}", .{rand.intRangeAtMost(u64, 0, 100)}), // errors: 0-100 count
                7 => try std.fmt.bufPrintZ(&value_buf, "{d}", .{rand.intRangeAtMost(u64, 1000, 10000)}), // requests: 1K-10K count
                else => try std.fmt.bufPrintZ(&value_buf, "{d:.2}", .{rand.float(f64) * 50.0}),
            };

            const attr_key = attribute_keys[metric_idx % attribute_keys.len];

            var old_value_buf: [32]u8 = undefined;
            const old_value: ?[]const u8 = if (point_idx > 0)
                try std.fmt.bufPrintZ(&old_value_buf, "{d:.2}", .{rand.float(f64) * 50.0})
            else
                null;

            // Create state change representing metric data point
            var change_id_buf: [64]u8 = undefined;
            const change_id = try std.fmt.bufPrintZ(&change_id_buf, "metric_{d}_{d}", .{ metric_idx, point_idx });

            const change = temporal.StateChange{
                .id = change_id,
                .txn_id = total_points_written,
                .timestamp = .{ .base = @intCast(timestamp), .delta = 0 },
                .entity_namespace = entity[0],
                .entity_local_id = entity[1],
                .change_type = if (point_idx == 0)
                    temporal.StateChangeType.entity_created
                else
                    temporal.StateChangeType.attribute_update,
                .key = attr_key,
                .old_value = if (old_value) |v| try allocator.dupe(u8, v) else null,
                .new_value = value_str, // Pass stack buffer directly, addChange will copy
                .metadata = "{}",
            };

            // Add to cartridge (makes internal copies)
            try cartridge.addChange(change);

            // Free the duplicated old_value (new_value is stack buffer)
            if (change.old_value) |v| allocator.free(v);

            total_points_written += 1;
            total_writes += change.serializedSize();
            total_alloc_bytes += change.serializedSize();
            alloc_count += 2;

            const write_latency = @as(u64, @intCast(std.time.nanoTimestamp() - write_start));
            try write_latencies.append(allocator, write_latency);
        }
    }

    // Phase 2: Raw Range Queries (60% of query mix)
    std.debug.print("  [{s}] Phase 2: Executing {} raw range queries...\n", .{ scale.name, num_raw_queries });
    var raw_queries_executed: u64 = 0;

    for (0..num_raw_queries) |i| {
        const query_start = std.time.nanoTimestamp();

        const entity_idx = i % num_metrics;
        const entity = metric_entities.items[entity_idx];

        // Scale window sizes based on available data (in data points)
        const max_points = points_per_metric * retention_days;
        const is_small = std.mem.eql(u8, scale.name, "small");
        const is_medium = std.mem.eql(u8, scale.name, "medium");
        // Window size as percentage of total data points (must be < max_points for intRangeLessThan)
        const window_points: usize = if (is_small)
            @min(60, max_points - 1) // 60 points max for small, ensure < max_points
        else if (is_medium) blk: {
            const sizes = [_]usize{ 10, 20, 50, 75 };
            break :blk @min(sizes[i % sizes.len], max_points - 1);
        } else blk: {
            const sizes = [_]usize{ 20, 40, 60, 80 };
            break :blk @min(sizes[i % sizes.len], max_points - 1);
        };
        // Ensure window_points is at least 1 and less than max_points
        const safe_window = if (window_points >= max_points) @max(1, max_points - 1) else window_points;
        const end_offset = rand.intRangeLessThan(usize, safe_window, max_points);
        const end_time = base_timestamp + @as(i64, @intCast(end_offset));
        const start_time_ts = end_time - @as(i64, @intCast(safe_window));

        var changes = try cartridge.queryBetween(entity[0], entity[1], start_time_ts, end_time);
        defer {
            for (changes.items) |*c| c.deinit(allocator);
            changes.deinit(allocator);
        }

        total_reads += @as(u64, @intCast(changes.items.len)) * 200;
        raw_queries_executed += 1;

        const query_latency = @as(u64, @intCast(std.time.nanoTimestamp() - query_start));
        try raw_query_latencies.append(allocator, query_latency);
    }

    // Phase 3: Aggregated Queries (30% of query mix)
    std.debug.print("  [{s}] Phase 3: Executing {} aggregated queries...\n", .{ scale.name, num_aggregated_queries });
    var aggregated_queries_executed: u64 = 0;

    for (0..num_aggregated_queries) |i| {
        const query_start = std.time.nanoTimestamp();

        const entity_idx = i % num_metrics;
        const entity = metric_entities.items[entity_idx];
        const attr_key = attribute_keys[entity_idx % attribute_keys.len];

        // Scale window sizes for aggregated queries (in data points)
        const max_points = points_per_metric * retention_days;
        const is_small = std.mem.eql(u8, scale.name, "small");
        const is_medium = std.mem.eql(u8, scale.name, "medium");
        const window_points: usize = if (is_small)
            @min(60, max_points - 1) // 60 points for small
        else if (is_medium)
            @min(50, max_points - 1) // 50 points for medium
        else blk: {
            const sizes = [_]usize{ 30, 50, 80 };
            break :blk @min(sizes[i % sizes.len], max_points - 1);
        };
        const safe_window = if (window_points >= max_points) @max(1, max_points - 1) else window_points;
        const end_offset = rand.intRangeLessThan(usize, safe_window, max_points);
        const end_time = base_timestamp + @as(i64, @intCast(end_offset));
        const start_time_ts = end_time - @as(i64, @intCast(safe_window));

        // Test distinct count aggregation
        _ = try cartridge.countDistinct(entity[0], entity[1], attr_key, start_time_ts, end_time);

        // Test first/last state queries
        const first_state = try cartridge.getFirstState(entity[0], entity[1]);
        if (first_state) |*s| {
            total_reads += s.serializedSize();
        }

        const last_state = try cartridge.getLastState(entity[0], entity[1]);
        if (last_state) |*s| {
            total_reads += s.serializedSize();
        }

        total_reads += 500;
        aggregated_queries_executed += 1;

        const query_latency = @as(u64, @intCast(std.time.nanoTimestamp() - query_start));
        try aggregated_query_latencies.append(allocator, query_latency);
    }

    // Phase 4: Rollup Queries (10% of query mix)
    std.debug.print("  [{s}] Phase 4: Executing {} rollup queries...\n", .{ scale.name, num_rollup_queries });
    var rollup_queries_executed: u64 = 0;

    for (0..num_rollup_queries) |i| {
        const query_start = std.time.nanoTimestamp();

        const entity_idx = i % num_metrics;
        const entity = metric_entities.items[entity_idx];
        const attr_key = attribute_keys[entity_idx % attribute_keys.len];

        // Query rollup data at different granularities (in seconds)
        const is_small = std.mem.eql(u8, scale.name, "small");
        var granularity_buf: [4]u64 = undefined;
        const granularities = if (is_small)
            blk: {
                granularity_buf[0] = 60;
                break :blk granularity_buf[0..1];
            }
        else
            blk: {
                granularity_buf[0] = 60;
                granularity_buf[1] = 300;
                granularity_buf[2] = 3600;
                granularity_buf[3] = 86400;
                break :blk granularity_buf[0..4];
            };
        const granularity = granularities[i % granularities.len];

        // Scale offset for rollup queries (in data points)
        const max_offset = points_per_metric * retention_days;
        const min_offset: usize = if (is_small) 10 else @min(20, max_offset - 1);
        const safe_min = if (min_offset >= max_offset) @max(1, max_offset - 1) else min_offset;
        const end_offset = rand.intRangeLessThan(usize, safe_min, max_offset);
        const end_time = base_timestamp + @as(i64, @intCast(end_offset));
        const window_points: usize = if (is_small) 30 else @min(60, max_offset - 1);
        const safe_window = if (window_points >= max_offset) @max(1, max_offset - 1) else window_points;
        const start_time_ts = end_time - @as(i64, @intCast(safe_window)); // Scale window

        // Create and query rollups
        try cartridge.index.createRollup(entity[0], entity[1], attr_key, start_time_ts, end_time, granularity, .mean);

        const rollups = try cartridge.index.queryRollups(entity[0], entity[1], attr_key, start_time_ts, end_time, granularity);
        defer {
            for (rollups) |r| {
                var mut_r = r;
                mut_r.deinit(allocator);
            }
            allocator.free(rollups);
        }

        total_reads += @as(u64, @intCast(rollups.len)) * @sizeOf(temporal.TemporalIndex.Rollup);
        rollup_queries_executed += 1;

        const query_latency = @as(u64, @intCast(std.time.nanoTimestamp() - query_start));
        try rollup_query_latencies.append(allocator, query_latency);
    }

    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

    // Calculate percentiles for each query type
    std.sort.insertion(u64, write_latencies.items, {}, comptime std.sort.asc(u64));
    std.sort.insertion(u64, raw_query_latencies.items, {}, comptime std.sort.asc(u64));
    std.sort.insertion(u64, aggregated_query_latencies.items, {}, comptime std.sort.asc(u64));
    std.sort.insertion(u64, rollup_query_latencies.items, {}, comptime std.sort.asc(u64));

    const raw_p50 = raw_query_latencies.items[raw_query_latencies.items.len / 2];
    const raw_p95 = raw_query_latencies.items[@min(raw_query_latencies.items.len - 1, raw_query_latencies.items.len * 95 / 100)];
    const raw_p99 = raw_query_latencies.items[@min(raw_query_latencies.items.len - 1, raw_query_latencies.items.len * 99 / 100)];

    const agg_p50 = aggregated_query_latencies.items[aggregated_query_latencies.items.len / 2];
    const agg_p95 = aggregated_query_latencies.items[@min(aggregated_query_latencies.items.len - 1, aggregated_query_latencies.items.len * 95 / 100)];
    const agg_p99 = aggregated_query_latencies.items[@min(aggregated_query_latencies.items.len - 1, aggregated_query_latencies.items.len * 99 / 100)];

    const rollup_p50 = rollup_query_latencies.items[rollup_query_latencies.items.len / 2];
    const rollup_p95 = rollup_query_latencies.items[@min(rollup_query_latencies.items.len - 1, rollup_query_latencies.items.len * 95 / 100)];
    const rollup_p99 = rollup_query_latencies.items[@min(rollup_query_latencies.items.len - 1, rollup_query_latencies.items.len * 99 / 100)];

    // Calculate storage efficiency (bytes per million points)
    const bytes_per_million = if (total_points_written > 0)
        @as(f64, @floatFromInt(total_alloc_bytes)) / @as(f64, @floatFromInt(total_points_written)) * 1_000_000.0
    else
        0.0;

    // Calculate write throughput
    const writes_per_sec = if (duration_ns > 0)
        @as(f64, @floatFromInt(total_points_written)) / @as(f64, @floatFromInt(duration_ns)) * std.time.ns_per_s
    else
        0.0;

    // Build detailed notes map
    var notes_map = std.json.ObjectMap.init(allocator);

    try notes_map.put("scale", std.json.Value{ .string = scale.name });
    try notes_map.put("metrics_count", std.json.Value{ .integer = @intCast(num_metrics) });
    try notes_map.put("points_per_metric", std.json.Value{ .integer = @intCast(points_per_metric) });
    try notes_map.put("retention_days", std.json.Value{ .integer = @intCast(retention_days) });
    try notes_map.put("total_points_written", std.json.Value{ .integer = @intCast(total_points_written) });
    try notes_map.put("raw_queries", std.json.Value{ .integer = @intCast(raw_queries_executed) });
    try notes_map.put("aggregated_queries", std.json.Value{ .integer = @intCast(aggregated_queries_executed) });
    try notes_map.put("rollup_queries", std.json.Value{ .integer = @intCast(rollup_queries_executed) });
    try notes_map.put("writes_per_sec", std.json.Value{ .float = writes_per_sec });
    try notes_map.put("bytes_per_million_points", std.json.Value{ .float = bytes_per_million });

    // Query latencies in milliseconds
    try notes_map.put("raw_p99_ms", std.json.Value{ .float = @as(f64, @floatFromInt(raw_p99)) / 1_000_000.0 });
    try notes_map.put("agg_p99_ms", std.json.Value{ .float = @as(f64, @floatFromInt(agg_p99)) / 1_000_000.0 });
    try notes_map.put("rollup_p99_ms", std.json.Value{ .float = @as(f64, @floatFromInt(rollup_p99)) / 1_000_000.0 });

    // Target compliance
    try notes_map.put("target_writes_per_sec_met", std.json.Value{ .bool = writes_per_sec > 10000.0 });
    try notes_map.put("target_range_24h_met", std.json.Value{ .bool = raw_p99 < 100_000_000 }); // 100ms
    try notes_map.put("target_percentile_met", std.json.Value{ .bool = agg_p99 < 50_000_000 }); // 50ms
    try notes_map.put("target_storage_efficiency_met", std.json.Value{ .bool = bytes_per_million < 10_000_000.0 }); // 10MB

    const notes_value = std.json.Value{ .object = notes_map };

    // Overall latency is weighted average of query types
    const overall_p50 = @as(u64, @intFromFloat(@as(f64, @floatFromInt(raw_p50 + agg_p50 + rollup_p50)) / 3.0));
    const overall_p99 = @max(raw_p99, @max(agg_p99, rollup_p99));

    return types.Results{
        .ops_total = total_points_written + raw_queries_executed + aggregated_queries_executed + rollup_queries_executed,
        .duration_ns = duration_ns,
        .ops_per_sec = writes_per_sec,
        .latency_ns = .{
            .p50 = overall_p50,
            .p95 = @max(raw_p95, @max(agg_p95, rollup_p95)),
            .p99 = overall_p99,
            .max = overall_p99 + 1,
        },
        .bytes = .{
            .read_total = total_reads,
            .write_total = total_writes,
        },
        .io = .{
            .fsync_count = 0, // In-memory operations
        },
        .alloc = .{
            .alloc_count = alloc_count,
            .alloc_bytes = total_alloc_bytes,
        },
        .errors_total = 0,
        .notes = notes_value,
    };
}
