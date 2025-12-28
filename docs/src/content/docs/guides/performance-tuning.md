---
title: Performance Tuning Guide
description: Learn how to benchmark, optimize, and deploy NorthstarDB for maximum performance.
---

import { Card, Cards } from '@astrojs/starlight/components';

This guide covers performance optimization strategies for NorthstarDB, from benchmarking methodology to production deployment tips.

<Cards>
  <Card title="Benchmark" icon="activity">
    Measure performance with built-in benchmarking tools.
  </Card>
  <Card title="Optimize" icon="zap">
    Apply strategies to improve throughput and latency.
  </Card>
  <Card title="Deploy" icon="server">
    Configure NorthstarDB for production workloads.
  </Card>
</Cards>

## Overview

NorthstarDB is designed for:
- **Massive read concurrency** - Unlimited concurrent readers
- **Deterministic performance** - Predictable latency under load
- **Crash safety** - No data loss, ever
- **AI intelligence** - Autonomous optimization with structured memory

Performance tuning follows a systematic approach:

1. **Measure** - Benchmark current performance
2. **Identify** - Find bottlenecks using profiling
3. **Optimize** - Apply targeted improvements
4. **Validate** - Verify improvements with benchmarks

## Benchmarking Methodology

### Running Benchmarks

NorthstarDB includes a comprehensive benchmark harness:

```bash
# Build the benchmark harness
zig build

# Run all benchmarks
zig build run -- run

# Run specific suite
zig build run -- run --suite micro

# Run with repeats
zig build run -- run --repeats 10

# Filter by name pattern
zig build run -- run --filter "point_get"

# Output JSON results
zig build run -- run --output ./results
```

### Benchmark Structure

Benchmarks are organized into suites:

```zig
// Suite A: Pager/Storage primitives
- bench_open_close_db
- bench_read_write_pages
- bench_checksum_validation

// Suite B: B+tree core operations
- bench_point_get
- bench_point_put
- bench_range_scan
- bench_delete

// Suite C: MVCC snapshots
- bench_readers_scaling
- bench_snapshot_isolation
- bench_conflict_detection

// Suite D: Time-travel/commit stream
- bench_commit_stream_append
- bench_snapshot_by_txn
- bench_time_travel_query
```

### Interpreting Results

Benchmark results include:

```json
{
  "name": "bench_point_get",
  "suite": "micro",
  "throughput": {
    "value": 1250000,
    "unit": "ops/s"
  },
  "latency": {
    "p50": 800,
    "p99": 1200,
    "p999": 1500,
    "unit": "ns"
  },
  "repeats": 5,
  "timestamp": "2025-12-28T10:00:00Z"
}
```

**Key metrics:**
- **Throughput** - Operations per second (higher is better)
- **P50 latency** - Median response time
- **P99 latency** - 99th percentile (critical for SLAs)
- **P999 latency** - 99.9th percentile (tail latency)

### Regression Gates

CI enforces performance regression gates:

```bash
# Compare against baseline
zig build run -- compare ./baselines/ci ./results/candidate

# Gates: -5% throughput, +10% p99 latency
# Failures indicate performance regression
```

## Performance Bottlenecks

### 1. I/O Bottlenecks

**Symptoms:**
- High latency on page reads
- Low throughput on write-heavy workloads
- Disk I/O at 100%

**Diagnosis:**
```zig
// Enable I/O profiling
const db_config = db.Db.Config{
    .enable_io_stats = true,
    .io_stats_interval_ns = 1_000_000_000, // 1 second
};

// Check stats
const stats = my_db.getIOStats();
std.debug.print("Page reads: {}\n", .{stats.page_reads});
std.debug.print("Page writes: {}\n", .{stats.page_writes});
std.debug.print("Cache hit rate: {.2}%\n", .{
    stats.cache_hits * 100.0 / (stats.cache_hits + stats.cache_misses)
});
```

**Solutions:**
- Use NVMe storage for lower latency
- Increase page cache size
- Batch writes to reduce fsync overhead

### 2. Page Cache Issues

**Symptoms:**
- Poor cache hit rates (< 80%)
- Repeated reads of same pages
- High memory usage but low performance

**Diagnosis:**
```zig
const cache_stats = my_db.getCacheStats();
std.debug.print("Cache size: {} pages\n", .{cache_stats.size});
std.debug.print("Cache capacity: {} pages\n", .{cache_stats.capacity});
std.debug.print("Hit rate: {.2}%\n", .{cache_stats.hit_rate});
```

**Solutions:**
```zig
// Increase cache size
const config = db.Db.Config{
    .page_cache_size = 1024 * 1024 * 1024, // 1GB
};

// Preload hot pages
var r = try my_db.beginReadLatest();
defer r.close();

// Scan to preload
_ = try r.scan("user:");
```

### 3. B+tree Depth

**Symptoms:**
- Degraded performance with large datasets
- Multiple page reads per operation

**Diagnosis:**
```zig
const tree_stats = my_db.getBTreeStats();
std.debug.print("Tree depth: {}\n", .{tree_stats.depth});
std.debug.print("Total pages: {}\n", .{tree_stats.total_pages});
std.debug.print("Leaf pages: {}\n", .{tree_stats.leaf_pages});
```

**Solutions:**
- Larger page size (reduces depth)
- Key design for better locality
- Regular compaction

### 4. Transaction Contention

**Symptoms:**
- Write transaction retries
- High write latency spikes
- `WriteBusy` errors

**Diagnosis:**
```zig
const txn_stats = my_db.getTxnStats();
std.debug.print("Write retries: {}\n", .{txn_stats.write_retries});
std.debug.print("Conflicts: {}\n", .{txn_stats.conflicts});
std.debug.print("Avg commit latency: {} us\n", .{txn_stats.avg_commit_us});
```

**Solutions:**
- Reduce transaction size
- Batch operations
- Optimize write patterns

## Optimization Strategies

### 1. Configuration Tuning

#### Page Size

Larger pages reduce tree depth but increase memory:

```zig
// For read-heavy workloads
const config = db.Db.Config{
    .page_size = 16 * 1024, // 16KB pages
};

// For write-heavy workloads
const config = db.Db.Config{
    .page_size = 4 * 1024, // 4KB pages
};
```

**Trade-offs:**
- **16KB pages** - Better read performance, higher memory
- **4KB pages** - Lower memory, more page reads

#### Cache Size

Match cache to working set:

```zig
// Calculate working set
const avg_value_size = 1024; // 1KB
const key_size = 32;
const total_entries = 1_000_000;
const working_set = (avg_value_size + key_size) * total_entries;

// Set cache to 50% of working set
const config = db.Db.Config{
    .page_cache_size = working_set / 2,
};
```

#### Concurrency Settings

Tune for workload:

```zig
// For massive concurrent reads
const config = db.Db.Config{
    .max_concurrent_reads = 0, // Unlimited
};

// For write-heavy workloads
const config = db.Db.Config{
    .write_backlog = 100,
    .write_timeout_ms = 5000,
};
```

### 2. Key Design

Good key design improves performance:

```zig
// Good: Hierarchical keys
"user:001:profile"
"user:001:settings"
"user:002:profile"
"user:002:settings"

// Enables efficient prefix scans
const results = try r.scan("user:001:");

// Bad: Flat keys
"user001_profile"
"user001_settings"
// Harder to query
```

**Key design principles:**
1. **Use prefixes** - Enables efficient range queries
2. **Keep keys short** - Reduces memory overhead
3. **Avoid hot prefixes** - Distributes load evenly
4. **Use fixed-width IDs** - Improves locality

### 3. Batch Operations

Batch writes reduce fsync overhead:

```zig
// Bad: Many small transactions
for (items) |item| {
    var w = try db.beginWrite();
    defer w.abort();
    try w.put(item.key, item.value);
    _ = try w.commit();
}

// Good: Single large transaction
var w = try db.beginWrite();
defer w.abort();

for (items) |item| {
    try w.put(item.key, item.value);
}
_ = try w.commit(); // Single fsync
```

**Performance improvement:**
- 10x-100x faster for bulk inserts
- Reduced transaction overhead
- Better write coalescing

### 4. Snapshot Management

Reuse snapshots when possible:

```zig
// Bad: Create new snapshot for each read
for (keys) |key| {
    var r = try db.beginReadLatest();
    defer r.close();
    const value = r.get(key);
}

// Good: Reuse snapshot
var r = try db.beginReadLatest();
defer r.close();

for (keys) |key| {
    const value = r.get(key);
}
```

### 5. Read-Your-Writes

Use write transactions for immediate reads:

```zig
// Bad: Write + separate read
var w = try db.beginWrite();
defer w.abort();
try w.put("key", "value");
_ = try w.commit();

var r = try db.beginReadLatest();
defer r.close();
const value = r.get("key"); // May miss due to timing

// Good: Read from write transaction
var w = try db.beginWrite();
defer w.abort();
try w.put("key", "value");
const value = w.get("key"); // Guaranteed to see write
_ = try w.commit();
```

## Production Deployment

### NVMe Optimization

For maximum performance:

```bash
# Format with optimal settings
mkfs.xfs -f -d agcount=4 /dev/nvme0n1

# Mount with noatime
mount -o noatime /dev/nvme0n1 /data

# Disable swap (database manages memory)
swapoff -a
```

**Expected performance:**
- **Random read**: 500K-1M ops/s
- **Random write**: 200K-500K ops/s
- **Sequential**: 3-7 GB/s

### File Descriptor Limits

Increase for high concurrency:

```bash
# Check current limit
ulimit -n

# Increase temporarily
ulimit -n 65536

# Set permanently in /etc/security/limits.conf
* soft nofile 65536
* hard nofile 65536
```

### Memory Settings

Tune for workload:

```zig
// Calculate optimal cache size
const total_memory = 16 * 1024 * 1024 * 1024; // 16GB
const cache_fraction = 0.5; // 50% for cache
const cache_size = @intFromFloat(total_memory * cache_fraction);

const config = db.Db.Config{
    .page_cache_size = cache_size,
};
```

**Memory allocation:**
- **50%** - Page cache
- **30%** - Write buffers
- **20%** - System overhead

### Concurrency Tuning

For read-heavy workloads:

```zig
const config = db.Db.Config{
    .max_concurrent_reads = 0, // Unlimited readers
    .read_backlog = 1000,
};
```

For write-heavy workloads:

```zig
const config = db.Db.Config{
    .write_backlog = 100,
    .write_batch_size = 1000,
    .write_timeout_ms = 10000,
};
```

### Monitoring

Track these metrics:

```zig
// Throughput
const throughput = db.getThroughputStats();
std.debug.print("Read ops/s: {}\n", .{throughput.read_ops});
std.debug.print("Write ops/s: {}\n", .{throughput.write_ops});

// Latency
const latency = db.getLatencyStats(.{
    .window_ns = 60_000_000_000, // 1 minute
});
std.debug.print("P99 read latency: {} us\n", .{latency.read_p99_us});
std.debug.print("P99 write latency: {} us\n", .{latency.write_p99_us});

// Cache
const cache = db.getCacheStats();
std.debug.print("Cache hit rate: {.2}%\n", .{cache.hit_rate});
```

### Backup Strategies

For production:

```zig
// Incremental backup
pub fn backupIncremental(
    db: *db.Db,
    backup_path: []const u8
) !void {
    var w = try db.beginWrite();
    defer w.abort();

    // Get last LSN
    const last_lsn = try db.getLastLsn();

    // Copy pages changed since last backup
    var backup = try std.fs.cwd().createFile(backup_path, .{});
    defer backup.close();

    try db.copyPagesSince(w, last_lsn, backup.writer());

    _ = try w.commit();
}
```

### High Availability

For HA setups:

```zig
// Replica setup
const config = db.Db.Config{
    .replication_enabled = true,
    .replication_targets = &[_][]const u8{
        "replica1:7100",
        "replica2:7100",
    },
    .replication_mode = .async, // or .sync for strong consistency
};
```

## Performance Checklist

Use this checklist before deploying:

- [ ] Run full benchmark suite
- [ ] Compare against CI baselines
- [ ] Verify cache hit rate > 80%
- [ ] Check P99 latency meets SLA
- [ ] Validate crash recovery
- [ ] Test with production workload
- [ ] Configure appropriate cache size
- [ ] Set optimal page size
- [ ] Enable monitoring
- [ ] Configure backup strategy
- [ ] Tune kernel parameters
- [ ] Set file descriptor limits

## Common Issues

### Issue: Low Cache Hit Rate

**Solution:**
```zig
// Increase cache size
const config = db.Db.Config{
    .page_cache_size = 2 * 1024 * 1024 * 1024, // 2GB
};
```

### Issue: High Write Latency

**Solution:**
```zig
// Batch writes
var w = try db.beginWrite();
defer w.abort();

for (items) |item| {
    try w.put(item.key, item.value);
}

_ = try w.commit();
```

### Issue: Read Contention

**Solution:**
```zig
// NorthstarDB supports unlimited concurrent readers
// No special tuning needed
// Verify no write transactions blocking reads
```

### Issue: Slow Startup

**Solution:**
```zig
// Preload cache
var r = try db.beginReadLatest();
defer r.close();

// Scan common prefixes
_ = try r.scan("user:");
_ = try r.scan("product:");
_ = try r.scan("order:");
```

## Next Steps

Now that you understand performance tuning:

- [CRUD Operations](./crud-operations.md) - Efficient data access
- [Snapshots & Time Travel](./snapshots-time-travel.md) - Historical queries
- [Cartridges Usage](./cartridges-usage.md) - AI-powered data structures
- [Db API Reference](../reference/db.md) - Complete API documentation
- [Benchmark Specification](../../benchmark-plan.md) - Detailed methodology
