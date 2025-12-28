# Time-Series Telemetry

A high-performance time-series database for metrics and telemetry data.

## Overview

This example implements a time-series database optimized for:
- High-frequency metric ingestion
- Efficient time-range queries
- Automatic downsampling and aggregation
- Multi-dimensional metric support
- Rollup and retention policies

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Time-Series Storage                        │
├─────────────────────────────────────────────────────────────┤
│  Raw Data (high precision):                                 │
│  ts:<metric>:<series_id>:<timestamp_ns> → value             │
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

## Usage

```zig
// Create time-series database
var tsdb = try TimeSeriesDB.init(allocator, &database);

// Define a metric series
const series = try tsdb.registerSeries(.{
    .name = "cpu_usage",
    .tags = .{
        .host = "server-01",
        .region = "us-east",
    },
});

// Write data points
try tsdb.write(series.id, std.time.timestamp(), 45.2);
try tsdb.write(series.id, std.time.timestamp(), 52.1);

// Query time range
const points = try tsdb.queryRange(series.id, start_time, end_time);

// Aggregate
const avg = try tsdb.aggregate(series.id, start_time, end_time, .avg);
```

## Running the Example

```bash
zig build-exe examples/time_series/main.zig
./time_series
```

## Features

### Data Ingestion
- **Batch Writes**: Efficient multi-point insertion
- **Compression**: Delta-of-delta encoding for timestamps
- **Async Flush**: Background write buffering

### Query Operations
- **Range Queries**: Fetch points in time window
- **Aggregation**: avg, min, max, sum, count
- **Downsampling**: Automatic precision selection based on range
- **Group By**: Aggregate by tag values

### Retention Management
- **Rollup Rules**: Define downsampling schedules
- **TTL**: Automatic data expiration
- **Partitioning**: Time-based partition pruning

## Data Model

### Series Definition
Each series represents a unique metric + tag combination:
```
series:abc123 = {"name":"cpu_usage","tags":{"host":"server-01","region":"us-east"}}
```

### Data Point Storage
Raw nanosecond precision:
```
ts:cpu_usage:abc123:1704067200000000000 = 45.2
ts:cpu_usage:abc123:1704067200000001000 = 46.1
```

### Downsampled Data
1-minute rollups:
```
ts_1m:cpu_usage:abc123:28401120 = "45.5,52.1,38.2,1440"
                               ↑avg   ↑max  ↑min  ↑count
```

## Aggregation Functions

| Function | Description |
|----------|-------------|
| `avg` | Average of all values |
| `min` | Minimum value |
| `max` | Maximum value |
| `sum` | Sum of all values |
| `count` | Number of data points |
| `rate` | Per-second rate of change |
| `percentile(p)` | Approximate percentile |

## Query Examples

### Simple Range
```zig
const points = try tsdb.queryRange(series_id, @as(i64, start), @as(i64, end));
```

### With Aggregation
```zig
const result = try tsdb.aggregate(series_id, start, end, .avg);
// Returns: 42.5
```

### Group By Tag
```zig
const by_region = try tsdb.groupBy("cpu_usage", start, end, "region", .avg);
// Returns: .{ .{"us-east", 45.2}, .{"us-west", 38.7} }
```

## Performance Tips

1. **Batch Writes**: Group multiple points in one transaction
2. **Appropriate Resolution**: Don't store nanosecond precision for minute-level metrics
3. **Tag Cardinality**: Keep tag values low-cardinality (< 1000 unique values)
4. **Query Pruning**: Use series metadata to filter before data access

## Scaling

For large-scale deployments:
1. **Shard by Series ID**: Distribute series across nodes
2. **Partition by Time**: Separate databases per day/week
3. **Hot-Cold Tiers**: Move old data to cheaper storage
4. **Query Federation**: Parallelize across shards
