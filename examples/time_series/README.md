# Time-Series Telemetry

A high-performance time-series database for metrics and telemetry data.

## Overview

This example implements a time-series database (TSDB) optimized for high-frequency metric ingestion, efficient time-range queries, automatic downsampling, and multi-dimensional metric support with tags.

## Use Cases

- Application metrics and monitoring
- IoT sensor data collection
- Financial ticker data
- Performance telemetry
- Log aggregation and analytics
- Infrastructure monitoring

## Features Demonstrated

- **High-Frequency Ingestion**: Batch writes for thousands of points/second
- **Efficient Time-Range Queries**: B+tree-ordered data for fast range scans
- **Automatic Downsampling**: Aggregate data into lower-resolution rollups
- **Multi-Dimensional Metrics**: Tag-based series organization
- **Aggregation Functions**: avg, min, max, sum, count
- **Rollup Policies**: Time-based data retention and aggregation

## Running the Example

```bash
cd examples/time_series
zig build run

# Or build manually
zig build-exe main.zig
./time_series
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                   Time-Series Storage                        │
├─────────────────────────────────────────────────────────────┤
│  Raw Data (high precision):                                 │
│  ts:<metric>:<series_id>:<timestamp> → value                │
│                                                               │
│  Downsampled (1-minute averages):                           │
│  ts_1m:<metric>:<series_id>:<timestamp_min> → avg,max,min   │
│                                                               │
│  Downsampled (1-hour averages):                             │
│  ts_1h:<metric>:<series_id>:<timestamp_hour> → agg          │
│                                                               │
│  Series Metadata:                                            │
│  series:<id> → {"name":"...","tags":{...}}                   │
│  metric_index:<name>:<id> → ""                               │
│                                                               │
│  Tag Index:                                                  │
│  tag:<key>:<value>:<series_id> → ""                          │
└─────────────────────────────────────────────────────────────┘
```

## Code Walkthrough

### 1. Database Initialization

```zig
var tsdb = try TimeSeriesDB.init(allocator, &database);
```

### 2. Series Registration

```zig
const cpu_series = try tsdb.registerSeries(.{
    .name = "cpu_usage",
    .tags = .{
        .host = "server-01",
        .region = "us-east",
        .service = "api-server",
    },
});
```

**What happens:**
1. Generate series ID from name + tags (hash-based)
2. Store series metadata
3. Index by metric name
4. Index by each tag for efficient querying

### 3. Writing Data Points

```zig
// Single point
try tsdb.write(series_id, timestamp, 45.2);

// Batch write
var points: [100]DataPoint = undefined;
for (&points, 0..) |*p, i| {
    p.* = DataPoint{
        .timestamp = now - (100 - i) * 60,
        .value = @as(f64, @floatFromInt(i)),
    };
}
try tsdb.writeBatch(series_id, &points);
```

**Benefits of Batch Writes:**
- Single transaction for multiple points
- Reduced write amplification
- Higher throughput
- Better disk I/O patterns

### 4. Querying Time Ranges

```zig
const points = try tsdb.queryRange(series_id, start_time, end_time);
```

**Query Process:**
1. Scan keys with prefix `ts:<series_id>:`
2. Filter by timestamp range
3. Sort results by timestamp
4. Return as DataPoint array

### 5. Aggregation

```zig
const avg_result = try tsdb.aggregate(series_id, start, end, .avg);
const max_result = try tsdb.aggregate(series_id, start, end, .max);
```

## Data Model

### Series Definition

Each series represents a unique metric + tag combination:

```json
{
  "id": "series_abc123",
  "name": "cpu_usage",
  "tags": {
    "host": "server-01",
    "region": "us-east",
    "service": "api-server"
  }
}
```

**Key Design:**
- Series ID = hash(name + all tags)
- Same metric + different tags = different series
- Enables efficient multi-dimensional queries

### Data Point Storage

Raw nanosecond precision (or second precision for this example):

```
ts:cpu_usage:series_abc123:1704067200 = 45.2
ts:cpu_usage:series_abc123:1704067260 = 46.1
ts:cpu_usage:series_abc123:1704067320 = 44.8
```

**Storage Format:**
- Key: `ts:<metric>:<series_id>:<timestamp>`
- Value: floating-point number as string
- Ordered by timestamp in B+tree

### Downsampled Data

1-minute rollups (stored separately):

```
ts_1m:cpu_usage:series_abc123:28401120 = "45.5,52.1,38.2,60"
                                      ↑avg   ↑max  ↑min  ↑count
```

**Rollup Benefits:**
- Reduce storage for old data
- Speed up long-range queries
- Automatic retention management

## Aggregation Functions

| Function | Description | Use Case |
|----------|-------------|----------|
| `avg` | Average of all values | Typical metric value |
| `min` | Minimum value | Capacity planning |
| `max` | Maximum value | Peak detection |
| `sum` | Sum of all values | Total count/volume |
| `count` | Number of data points | Data completeness |
| `rate` | Per-second rate of change | Growth trends |

## Query Examples

### Simple Range

```zig
const points = try tsdb.queryRange(series_id, start, end);
for (points.items) |point| {
    std.debug.print("{d}: {d:.2}\n", .{ point.timestamp, point.value });
}
```

### With Aggregation

```zig
// Average over time range
const avg = try tsdb.aggregate(series_id, start, end, .avg);
std.debug.print("Average: {d:.2}\n", .{avg.value});

// Multiple aggregations in one query
inline for (.{ .avg, .min, .max, .count }) |agg_type| {
    const result = try tsdb.aggregate(series_id, start, end, agg_type);
    std.debug.print("{s}: {d:.2}\n", .{ @tagName(agg_type), result.value });
}
```

### Group By Tag

```zig
// Get all series matching tag filter
const series_list = try tsdb.getSeriesByTag("region", "us-east");

// Aggregate across all matching series
for (series_list.items) |series_id| {
    const avg = try tsdb.aggregate(series_id, start, end, .avg);
    std.debug.print("{s}: {d:.2}\n", .{ series_id, avg.value });
}
```

### Cross-Series Comparison

```zig
// Compare multiple hosts
const host1 = tsdb.registerSeries(.{ .name = "cpu", .tags = .{ .host = "server-01" } });
const host2 = tsdb.registerSeries(.{ .name = "cpu", .tags = .{ .host = "server-02" } });

const avg1 = try tsdb.aggregate(host1, start, end, .avg);
const avg2 = try tsdb.aggregate(host2, start, end, .avg);

std.debug.print("Difference: {d:.2}%\n", .{avg1.value - avg2.value});
```

## Performance Optimization

### 1. Batch Writes

```zig
// GOOD: Batch 1000 points in one transaction
var batch: [1000]DataPoint = undefined;
// ... fill batch ...
try tsdb.writeBatch(series_id, &batch);

// AVOID: Individual writes
for (points) |point| {
    try tsdb.write(series_id, point.timestamp, point.value);
}
```

**Expected Throughput:**
- Individual writes: ~1,000 writes/sec
- Batch writes (1000): ~100,000 writes/sec

### 2. Appropriate Resolution

```zig
// GOOD: Second precision for per-second metrics
const timestamp = std.time.timestamp();

// AVOID: Nanosecond precision for minute-level metrics
const timestamp_ns = std.time.nanoTimestamp();  // Unnecessary overhead
```

### 3. Tag Cardinality

```zig
// GOOD: Low cardinality tags
.tags = .{
    .region = "us-east",      // ~10 values
    .environment = "prod",    // ~3 values
    .service = "api",         // ~50 values
}

// AVOID: High cardinality tags
.tags = .{
    .request_id = "abc123",   // Millions of unique values
    .user_id = "user_456",    // Creates too many series
}
```

**Rule of Thumb:** < 1000 unique values per tag key

### 4. Query Pruning

```zig
// GOOD: Use tag index to filter before data access
const east_series = try tsdb.getSeriesByTag("region", "us-east");
for (east_series.items) |series_id| {
    const points = try tsdb.queryRange(series_id, start, end);
    // ... process ...
}

// AVOID: Scan all series then filter
const all_series = try tsdb.getAllSeries();
for (all_series.items) |series_id| {
    const series = try tsdb.getSeries(series_id);
    if (std.mem.eql(u8, series.tags.region, "us-east")) {
        // ... process ...
    }
}
```

## Downsampling Strategy

### Time-Based Rollups

```zig
// Raw data: Keep for 7 days
// 1-minute rollups: Keep for 30 days
// 1-hour rollups: Keep for 1 year

fn getRollupKey(series_id: []const u8, timestamp: i64, resolution: RollupResolution) []const u8 {
    const rolled_ts = switch (resolution) {
        .raw => timestamp,
        .minute => timestamp / 60,
        .hour => timestamp / 3600,
        .day => timestamp / 86400,
    };
    return try std.fmt.allocPrint(allocator, "ts_{d}:{s}", .{ resolution, series_id, rolled_ts });
}
```

### Rollup Aggregation

```zig
fn createRollup(series_id: []const u8, start_ts: i64, end_ts: i64) !void {
    // Get raw data points
    const raw_points = try tsdb.queryRange(series_id, start_ts, end_ts);

    // Calculate aggregations
    var sum: f64 = 0;
    var min: f64 = std.math.floatMax(f64);
    var max: f64 = -std.math.floatMax(f64);
    var count: u64 = 0;

    for (raw_points.items) |point| {
        sum += point.value;
        min = @min(min, point.value);
        max = @max(max, point.value);
        count += 1;
    }

    const avg = sum / @as(f64, @floatFromInt(count));

    // Store rollup
    const rollup_key = getRollupKey(series_id, start_ts, .minute);
    const rollup_value = try std.fmt.allocPrint(
        allocator,
        "{d},{d},{d},{d}",
        .{ avg, max, min, count }
    );

    try tsdb.storeRollup(rollup_key, rollup_value);
}
```

## Scaling Considerations

### Vertical Scaling

1. **Increase Batch Size**
```zig
// Process larger batches
const BATCH_SIZE = 10000;
var batch: [BATCH_SIZE]DataPoint = undefined;
try tsdb.writeBatch(series_id, &batch);
```

2. **Async Writes**
```zig
// Background write thread
const WriteBuffer = struct {
    mutex: std.Thread.Mutex = .{},
    buffer: std.ArrayList(DataPoint),

    fn flush(self: *WriteBuffer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try tsdb.writeBatch(series_id, self.buffer.items);
        self.buffer.clearRetainingCapacity();
    }
};
```

### Horizontal Scaling

1. **Shard by Series ID**
```zig
fn getShard(series_id: []const u8) usize {
    const hash = std.hash.Wyhash.hash(0, series_id);
    return @mod(hash, num_shards);
}

// Route writes to appropriate shard
const shard_idx = getShard(series_id);
try shards[shard_idx].write(series_id, timestamp, value);
```

2. **Partition by Time**
```zig
// Separate database per day
const db_date = getDatabaseDate(timestamp);
var db = try db.Db.open(allocator, "telemetry_{d}.db", .{db_date});

// Write to time-partitioned database
try db.put(getKey(series_id, timestamp), value);
```

3. **Hot-Cold Tiers**
```zig
// Hot tier: Recent data (SSD)
var hot_db = try db.Db.open(allocator, "/ssd/telemetry.db");

// Cold tier: Old data (HDD/S3)
var cold_db = try db.Db.open(allocator, "/hdd/telemetry_archive.db");

// Migrate data after retention period
try migrateOldData(hot_db, cold_db, retention_cutoff);
```

## Real-World Usage Example

```zig
// Application monitoring

// 1. Register metric series
const cpu_series = try tsdb.registerSeries(.{
    .name = "app_cpu_usage",
    .tags = .{
        .app = "my-service",
        .instance = "us-east-1",
    },
});

const latency_series = try tsdb.registerSeries(.{
    .name = "request_latency",
    .tags = .{
        .app = "my-service",
        .endpoint = "/api/users",
    },
});

// 2. Collect metrics (in your application)
fn collectMetrics(tsdb: *TimeSeriesDB) !void {
    const cpu = getSystemCpuUsage();
    try tsdb.write(cpu_series, std.time.timestamp(), cpu);

    const latency = measureRequestLatency();
    try tsdb.write(latency_series, std.time.timestamp(), latency);
}

// 3. Query for monitoring dashboard
fn getMetricsForDashboard(tsdb: *TimeSeriesDB, duration: i64) !void {
    const now = std.time.timestamp();
    const start = now - duration;

    // Average CPU over period
    const cpu_avg = try tsdb.aggregate(cpu_series, start, now, .avg);

    // P95 latency
    const latency_points = try tsdb.queryRange(latency_series, start, now);
    const p95 = calculatePercentile(latency_points.items, 95);

    std.debug.print("CPU: {d:.1}%\n", .{cpu_avg.value});
    std.debug.print("P95 Latency: {d}ms\n", .{p95});
}

// 4. Alerting
fn checkAlerts(tsdb: *TimeSeriesDB) !void {
    const now = std.time.timestamp();
    const recent = now - 300; // Last 5 minutes

    const avg = try tsdb.aggregate(cpu_series, recent, now, .avg);
    if (avg.value > 80.0) {
        alert("High CPU usage: {d:.1}%", .{avg.value});
    }
}
```

## Testing

```zig
test "write and query data points" {
    var tsdb = TimeSeriesDB.init(testing.allocator, &database);

    const series = try tsdb.registerSeries(.{
        .name = "test_metric",
        .tags = .{ .host = "test" },
    });

    const now = std.time.timestamp();
    try tsdb.write(series, now, 42.0);

    const points = try tsdb.queryRange(series, now, now);
    try testing.expectEqual(@as(usize, 1), points.items.len);
    try testing.expectEqual(42.0, points.items[0].value);
}

test "aggregation functions" {
    var tsdb = TimeSeriesDB.init(testing.allocator, &database);

    const series = try tsdb.registerSeries(.{
        .name = "test_metric",
        .tags = .{ .host = "test" },
    });

    const now = std.time.timestamp();
    try tsdb.write(series, now, 10.0);
    try tsdb.write(series, now + 1, 20.0);
    try tsdb.write(series, now + 2, 30.0);

    const avg = try tsdb.aggregate(series, now, now + 2, .avg);
    try testing.expectEqual(20.0, avg.value);
}
```

## Next Steps

- **ai_knowledge_base**: For complex entity relationships
- **document_repo**: For full-text search patterns
- **task_queue**: For time-based scheduling

## See Also

- [B+Tree Range Queries](../../src/btree.zig)
- [Performance Tuning](../../docs/guides/performance.md)
- [Monitoring Best Practices](../../docs/guides/monitoring.md)
