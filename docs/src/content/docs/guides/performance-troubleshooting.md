---
title: Performance Troubleshooting Guide
description: Learn how to diagnose and fix performance issues in NorthstarDB, from slow queries to memory leaks and I/O bottlenecks.
---

import { Card, Cards } from '@astrojs/starlight/components';

This guide helps you identify and resolve performance issues in NorthstarDB deployments.

<Cards>
  <Card title="Diagnose" icon="search">
    Identify bottlenecks using profiling tools and metrics.
  </Card>
  <Card title="Analyze" icon="trending-up">
    Understand the root cause of performance problems.
  </Card>
  <Card title="Resolve" icon="zap">
    Apply targeted fixes and validate improvements.
  </Card>
</Cards>

## Overview

Performance troubleshooting follows a systematic approach:

1. **Measure** - Collect metrics and baseline performance
2. **Identify** - Locate the bottleneck using profiling
3. **Analyze** - Understand the root cause
4. **Fix** - Apply targeted improvements
5. **Validate** - Verify with benchmarks

## Quick Diagnosis Checklist

Use this checklist to quickly identify common issues:

| Symptom | Likely Cause | Quick Check |
|---------|--------------|-------------|
| Slow reads | Low cache hit rate | Check `getCacheStats().hit_rate` |
| Slow writes | Too many fsyncs | Check `getIOStats().fsync_count` |
| High memory | Cache too large | Review `page_cache_size` config |
| Slow startup | Cold cache | Consider cache preloading |
| High latency | Tree depth | Check `getBTreeStats().depth` |
| Write conflicts | Long transactions | Check `getTxnStats().write_retries` |

## Slow Query Diagnosis

### Identifying Slow Queries

#### Enable Query Logging

```zig
const db_config = db.Db.Config{
    .enable_query_logging = true,
    .slow_query_threshold_ns = 1_000_000, // Log queries > 1ms
};

// Queries exceeding threshold are logged:
// [SLOW] point_get user:001:profile took 2.3ms
```

#### Profile Specific Operations

```zig
// Time a specific operation
var timer = try std.time.Timer.start();
timer.start();

const value = try r.get("user:001:profile");

const elapsed_ns = timer.read();
if (elapsed_ns > 1_000_000) { // > 1ms
    std.debug.print("SLOW: get() took {} us\n", .{elapsed_ns / 1000});
}
```

#### Benchmark Workload Patterns

```bash
# Benchmark your specific workload
zig-out/bin/bench run --filter "my_workload" --repeats 10

# Compare against baselines
zig-out/bin/bench compare bench/baselines/ci ./results
```

### Common Query Bottlenecks

#### 1. Cache Misses

**Symptoms:**
- Queries slower after restart
- Poor performance on large datasets
- High disk I/O

**Diagnosis:**
```zig
const cache_stats = my_db.getCacheStats();
std.debug.print("Cache hit rate: {.2}%\n", .{cache_stats.hit_rate});
std.debug.print("Cache misses: {}\n", .{cache_stats.cache_misses});

// Hit rate < 80% indicates problem
if (cache_stats.hit_rate < 80.0) {
    std.debug.print("WARNING: Low cache hit rate\n");
}
```

**Solutions:**
```zig
// Solution 1: Increase cache size
const config = db.Db.Config{
    .page_cache_size = 2 * 1024 * 1024 * 1024, // 2GB
};

// Solution 2: Preload hot data
var r = try db.beginReadLatest();
defer r.close();

// Scan to preload into cache
var iter = try r.scan("user:");
while (try iter.next()) |entry| {
    _ = entry; // Force page load
}
```

#### 2. Deep B+tree

**Symptoms:**
- Multiple page reads per query
- Performance degrades with data size
- High latency on large datasets

**Diagnosis:**
```zig
const tree_stats = my_db.getBTreeStats();
std.debug.print("Tree depth: {}\n", .{tree_stats.depth});
std.debug.print("Total pages: {}\n", .{tree_stats.total_pages});
std.debug.print("Internal nodes: {}\n", .{tree_stats.internal_nodes});

// Depth > 4 indicates potential issue
if (tree_stats.depth > 4) {
    std.debug.print("WARNING: Tree depth is high\n");
}
```

**Solutions:**
```zig
// Solution 1: Increase page size (reduces depth)
const config = db.Db.Config{
    .page_size = 16 * 1024, // 16KB pages
};

// Solution 2: Better key design
// Good: Prefix-based for locality
"user:001:profile"
"user:001:settings"

// Bad: Random distribution
"abc123xyz"
```

#### 3. Large Value Reads

**Symptoms:**
- Slow point queries on large values
- High memory usage
- Network latency in remote setups

**Diagnosis:**
```zig
// Check average value size
const stats = my_db.getValueStats();
std.debug.print("Avg value size: {} bytes\n", .{stats.avg_value_size});
std.debug.print("Max value size: {} bytes\n", .{stats.max_value_size});

// Values > 1MB may need special handling
if (stats.avg_value_size > 1_048_576) {
    std.debug.print("WARNING: Large values detected\n");
}
```

**Solutions:**
```zig
// Solution 1: Split large values
const large_key = "document:001";
const chunk_size = 256 * 1024; // 256KB chunks

// Store chunks
var i: u32 = 0;
while (i * chunk_size < value.len) {
    const start = i * chunk_size;
    const end = @min(start + chunk_size, value.len);
    const chunk_key = try std.fmt.allocPrint(allocator, "{}:chunk:{}", .{large_key, i});
    try w.put(chunk_key, value[start..end]);
    i += 1;
}

// Store metadata
try w.put(large_key, try std.fmt.allocPrint(allocator, "chunks:{}", .{i}));

// Solution 2: Use range queries for partial access
const range_start = "document:001:chunk:0";
const range_end = "document:001:chunk:10";
var iter = try r.range(range_start, range_end);
```

#### 4. Inefficient Scan Patterns

**Symptoms:**
- Range scans slower than expected
- High page reads
- Poor prefix locality

**Diagnosis:**
```zig
// Profile scan operation
var timer = try std.time.Timer.start();
timer.start();

var iter = try r.scan("user:");
var count: usize = 0;
while (try iter.next()) |_| {
    count += 1;
}

const elapsed = timer.read();
const ops_per_sec = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000);
std.debug.print("Scan rate: {.2} ops/s\n", .{ops_per_sec});

// < 100K ops/s indicates problem
if (ops_per_sec < 100_000) {
    std.debug.print("WARNING: Slow scan rate\n");
}
```

**Solutions:**
```zig
// Solution 1: Use hierarchical keys
// Good:
"user:001:profile"
"user:001:settings"
"user:002:profile"
"user:002:settings"

// Enables efficient prefix scan:
var iter = try r.scan("user:001:");

// Solution 2: Limit scan range
var iter = try r.range("user:001:", "user:002:");
while (try iter.next()) |entry| {
    // Process entries
    if (entry.key.len > 20) break; // Early exit
}
```

### Query Optimization Strategies

#### Batch Reads

```zig
// Bad: Sequential reads
for (keys) |key| {
    var r = try db.beginReadLatest();
    defer r.close();
    const value = r.get(key);
}

// Good: Batch with single snapshot
var r = try db.beginReadLatest();
defer r.close();

for (keys) |key| {
    const value = r.get(key);
}
```

#### Use Indexes Effectively

```zig
// Design keys for query patterns
// Query: Get user profile
"user:001:profile" -> O(log n)

// Query: List all users
var iter = try r.scan("user:");

// Query: Get user settings
"user:001:settings" -> O(log n)
```

#### Avoid Hot Spots

```zig
// Bad: Single hot prefix
"user:profile:001"
"user:profile:002"
// All writes go to same page range

// Good: Distribute with hash
"user:{hash}:profile"  // hash distributes load
```

## Memory Issues

### Memory Leak Detection

#### Track Allocations

```zig
// Enable allocation tracking
const config = db.Db.Config{
    .track_allocations = true,
    .allocation_dump_interval_ns = 60_000_000_000, // Every minute
};

// Check allocation stats
const alloc_stats = my_db.getAllocationStats();
std.debug.print("Allocations: {}\n", .{alloc_stats.alloc_count});
std.debug.print("Deallocations: {}\n", .{alloc_stats.free_count});
std.debug.print("Leaked: {} bytes\n", .{
    alloc_stats.bytes_allocated - alloc_stats.bytes_freed
});

// Growing gap indicates leak
const leak_delta = (alloc_stats.bytes_allocated - alloc_stats.bytes_freed);
if (leak_delta > 10 * 1024 * 1024) { // > 10MB
    std.debug.print("WARNING: Potential memory leak\n");
}
```

#### Valgrind Detection

```bash
# Run with Valgrind for leak detection
valgrind --leak-check=full --show-leak-kinds=all \
  zig-out/bin/bench run --filter "point_get"

# Look for:
# - definitely lost: bytes
# - indirectly lost: bytes
# - still reachable: bytes (OK for cache)
```

#### Heap Profiling

```bash
# Use heap profiler
zig build \
  -Drelease-fast \
  -Dheap-profile

# Generates heap profile on exit
# Analyze with pprof
pprof --text zig-out/bin/bench > heap.txt
```

### Memory Usage Patterns

#### Normal Usage

```zig
// Typical memory breakdown:
// - Page cache: 50-70%
// - Write buffers: 10-20%
// - Metadata: 5-10%
// - System overhead: 10-20%

const total_memory = 16 * 1024 * 1024 * 1024; // 16GB
const cache_size = total_memory / 2; // 8GB for cache

const config = db.Db.Config{
    .page_cache_size = cache_size,
};
```

#### Abnormal Usage

```zig
// Check for excessive memory
const mem_stats = my_db.getMemoryStats();
std.debug.print("Page cache: {} MB\n", .{mem_stats.page_cache_mb});
std.debug.print("Write buffers: {} MB\n", .{mem_stats.write_buffers_mb});
std.debug.print("Metadata: {} MB\n", .{mem_stats.metadata_mb});

// Cache > 80% of total indicates misconfiguration
if (mem_stats.page_cache_mb * 100 / (total_memory / 1024 / 1024) > 80) {
    std.debug.print("WARNING: Cache too large for system\n");
}
```

### Cache Sizing and Configuration

#### Calculate Working Set

```zig
// Estimate working set size
const avg_key_size = 32;
const avg_value_size = 1024;
const entries = 1_000_000;

const entry_size = avg_key_size + avg_value_size;
const working_set = entry_size * entries;
const cache_target = working_set / 2; // Cache 50%

const config = db.Db.Config{
    .page_cache_size = cache_target,
};
```

#### Dynamic Cache Adjustment

```zig
// Monitor cache hit rate
const cache_stats = my_db.getCacheStats();

if (cache_stats.hit_rate < 70.0) {
    // Increase cache
    const new_size = cache_stats.capacity * 3 / 2;
    try my_db.resizeCache(new_size);
} else if (cache_stats.hit_rate > 95.0) {
    // Reduce cache (save memory)
    const new_size = cache_stats.capacity * 2 / 3;
    try my_db.resizeCache(new_size);
}
```

#### Cache Eviction Policies

```zig
// NorthstarDB uses LRU eviction
// Monitor eviction rate
const cache_stats = my_db.getCacheStats();
std.debug.print("Evictions: {}\n", .{cache_stats.evictions});
std.debug.print("Eviction rate: {.2}/sec\n", .{
    @as(f64, @floatFromInt(cache_stats.evictions)) / 60.0
});

// High eviction indicates undersized cache
if (cache_stats.evictions > 1000) {
    std.debug.print("WARNING: High cache eviction rate\n");
}
```

### Allocator Selection Guidance

#### Zig's General Purpose Allocator

```zig
// Default: Good for most cases
const gpa = std.heap.general_purpose_allocator;

const config = db.Db.Config{
    .allocator = gpa.allocator(),
};
```

#### Arena Allocator for Batch Operations

```zig
// Use arena for short-lived operations
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const arena_alloc = arena.allocator();

// Batch insert with arena
var w = try db.beginWrite();
defer w.abort();

for (items) |item| {
    // Allocations freed in one shot
    const key = try arena_alloc.dupe(u8, item.key);
    const value = try arena_alloc.dupe(u8, item.value);
    try w.put(key, value);
}

_ = try w.commit();
arena.deinit(); // Free all at once
```

#### CMA for Page Cache

```zig
// CMA (c_malloc_allocator) for page cache
// Better for large allocations
const cma = std.heap.c_allocator;

const config = db.Db.Config{
    .page_cache_allocator = cma,
};
```

## I/O Bottlenecks

### Disk I/O Profiling

#### Enable I/O Statistics

```zig
const config = db.Db.Config{
    .enable_io_stats = true,
    .io_stats_interval_ns = 1_000_000_000, // 1 second
};

// Check I/O stats
const io_stats = my_db.getIOStats();
std.debug.print("Page reads: {}\n", .{io_stats.page_reads});
std.debug.print("Page writes: {}\n", .{io_stats.page_writes});
std.debug.print("Bytes read: {} MB\n", .{io_stats.bytes_read / 1024 / 1024});
std.debug.print("Bytes written: {} MB\n", .{io_stats.bytes_written / 1024 / 1024});
std.debug.print("Fsync count: {}\n", .{io_stats.fsync_count});
```

#### Identify I/O Patterns

```zig
// Check for excessive reads
const io_stats = my_db.getIOStats();
const reads_per_write = @as(f64, @floatFromInt(io_stats.page_reads)) /
                       @max(1, @as(f64, @floatFromInt(io_stats.page_writes)));

std.debug.print("Reads per write: {.2}\n", .{reads_per_write});

// > 10:1 indicates read-heavy workload
// Optimize for reads: larger cache
```

#### Profile Disk Latency

```bash
# Use iostat to monitor disk
iostat -x 1

# Look for:
# - %util: > 80% indicates saturation
# - await: High average wait time
# - svctm: Service time

# Example output:
# sdb  5.00  100.00  50.00  85.50    2.50  45.00
#      ^     ^        ^       ^        ^      ^
#      |     |        |       |        |      |
#    util  read/s write/s await  svctm  %busy
```

### Page Cache Optimization

#### Cache Hit Rate

```zig
const cache_stats = my_db.getCacheStats();
std.debug.print("Cache hits: {}\n", .{cache_stats.cache_hits});
std.debug.print("Cache misses: {}\n", .{cache_stats.cache_misses});

const hit_rate = @as(f64, @floatFromInt(cache_stats.cache_hits * 100)) /
                @as(f64, @floatFromInt(cache_stats.cache_hits + cache_stats.cache_misses));

std.debug.print("Hit rate: {.2}%\n", .{hit_rate});

// < 80%: Increase cache or preheat
// 80-95%: Good
// > 95%: Oversized, consider reducing
```

#### Cache Preloading

```zig
// Preload common prefixes on startup
fn preloadCache(db: *db.Db, prefixes: [][]const u8) !void {
    var r = try db.beginReadLatest();
    defer r.close();

    for (prefixes) |prefix| {
        std.debug.print("Preloading: {s}\n", .{prefix});
        var iter = try r.scan(prefix);
        var count: usize = 0;
        while (try iter.next()) |_| {
            count += 1;
        }
        std.debug.print("Loaded {} entries\n", .{count});
    }
}

// Usage
const prefixes = &[_][]const u8{
    "user:",
    "product:",
    "order:",
};
try preloadCache(&my_db, prefixes);
```

#### Cache Warming

```zig
// Warm cache with synthetic workload
fn warmCache(db: *db.Db, size: usize) !void {
    var w = try db.beginWrite();
    defer w.abort();

    var i: usize = 0;
    while (i < size) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "warmup:{:010}", .{i});
        const value = try std.fmt.allocPrint(allocator, "value_{}", .{i});
        try w.put(key, value);
    }

    _ = try w.commit();
}
```

### WAL and Commit Log Tuning

#### Reduce Fsync Overhead

```zig
// Problem: Each commit calls fsync
// Solution: Batch commits

var w = try db.beginWrite();
defer w.abort();

// Accumulate writes
for (items) |item| {
    try w.put(item.key, item.value);
}

// Single fsync for all writes
_ = try w.commit();
```

#### WAL Buffer Sizing

```zig
// Increase WAL buffer for write-heavy workloads
const config = db.Db.Config{
    .wal_buffer_size = 16 * 1024 * 1024, // 16MB
    .wal_sync_mode = .batch, // Sync every N operations
};
```

#### Commit Grouping

```zig
// Group multiple commits
// Useful for bulk imports

const batch_size = 1000;
var i: usize = 0;

while (i < items.len) {
    const end = @min(i + batch_size, items.len);

    var w = try db.beginWrite();
    defer w.abort();

    var j = i;
    while (j < end) : (j += 1) {
        try w.put(items[j].key, items[j].value);
    }

    _ = try w.commit();
    i = end;
}
```

### Storage Device Recommendations

#### NVMe vs SSD vs HDD

| Device | IOPS | Throughput | Latency | Use Case |
|--------|------|------------|---------|----------|
| **NVMe** | 500K-1M | 3-7 GB/s | < 100μs | Production, high performance |
| **SATA SSD** | 50K-100K | 500 MB/s | < 1ms | Development, moderate load |
| **HDD** | 100-200 | 150 MB/s | 5-10ms | Archive, bulk storage |

#### Filesystem Selection

```bash
# NVMe: Use XFS for best performance
mkfs.xfs -f -d agcount=4 /dev/nvme0n1
mount -o noatime,allocsize=4M /dev/nvme0n1 /data

# SSD: ext4 with optimizations
mkfs.ext4 -O extent,uninit_bg,dir_index /dev/sdb1
mount -o noatime,barrier=0 /dev/sdb1 /data
```

#### Mount Options

```bash
# Recommended mount options
mount -o noatime,nodiratime,barrier=0 \
  /dev/nvme0n1 /data/northstar

# Options explained:
# - noatime: Don't update access time (reduces writes)
# - nodiratime: Don't update directory access time
# - barrier=0: Disable write barriers (if battery-backed cache)
```

## Profiling Tools

### Built-in Profiling Commands

#### Enable Statistics

```zig
const config = db.Db.Config{
    .enable_stats = true,
    .stats_output_interval_ns = 10_000_000_000, // Every 10 seconds
};

// Stats automatically logged:
// [STATS] throughput=1.2M ops/s latency=800ns cache=92%
```

#### Query Statistics

```zig
// Get comprehensive stats
const stats = my_db.getStats();

std.debug.print("=== Database Statistics ===\n", .{});
std.debug.print("Uptime: {} s\n", .{stats.uptime_s});
std.debug.print("Read ops: {}\n", .{stats.read_ops});
std.debug.print("Write ops: {}\n", .{stats.write_ops});
std.debug.print("Avg read latency: {} us\n", .{stats.avg_read_latency_us});
std.debug.print("Avg write latency: {} us\n", .{stats.avg_write_latency_us});
std.debug.print("Cache hit rate: {.2}%\n", .{stats.cache_hit_rate});
```

#### Transaction Statistics

```zig
const txn_stats = my_db.getTxnStats();

std.debug.print("=== Transaction Statistics ===\n", .{});
std.debug.print("Active readers: {}\n", .{txn_stats.active_readers});
std.debug.print("Active writers: {}\n", .{txn_stats.active_writers});
std.debug.print("Write retries: {}\n", .{txn_stats.write_retries});
std.debug.print("Conflicts: {}\n", .{txn_stats.conflicts});
std.debug.print("Avg commit latency: {} us\n", .{txn_stats.avg_commit_us});
```

### External Tool Integration

#### perf (Linux)

```bash
# Profile CPU usage
perf record -F 99 -g zig-out/bin/bench run --filter "point_get"

# Analyze results
perf report

# Common patterns:
# - High CPU in B+tree: Key comparison overhead
# - High CPU in checksum: Hash computation
# - High CPU in allocator: Memory allocation overhead
```

#### Flame Graphs

```bash
# Generate flame graph
perf script | stackcollapse-perf.pl | flamegraph.pl > flamegraph.svg

# Look for:
# - Wide bars: Hot paths
# - Deep stacks: Complex call chains
# - Missing bars: Unused code (dead code elimination)
```

#### iostat

```bash
# Monitor I/O in real-time
iostat -x 1

# Key metrics:
# - %util: Should be < 80%
# - await: Average wait time (lower is better)
# - svctm: Service time (lower is better)
```

#### vmstat

```bash
# Monitor memory and I/O
vmstat 1

# Look for:
# - si/so: Swap in/out (should be 0)
# - bi/bo: Block in/out (I/O rate)
# - cs: Context switches (lower is better)
```

### Performance Metrics Interpretation

#### Throughput Metrics

```zig
const throughput = my_db.getThroughputStats();

std.debug.print("Read throughput: {} ops/s\n", .{throughput.read_ops_per_sec});
std.debug.print("Write throughput: {} ops/s\n", .{throughput.write_ops_per_sec});
std.debug.print("Scan throughput: {} rows/s\n", .{throughput.scan_rows_per_sec});

// Compare against baselines
// - NVMe: > 1M ops/s
// - SSD: > 100K ops/s
// - HDD: > 10K ops/s
```

#### Latency Metrics

```zig
const latency = my_db.getLatencyStats(.{
    .window_ns = 60_000_000_000, // 1 minute window
});

std.debug.print("P50 read: {} us\n", .{latency.read_p50_us});
std.debug.print("P99 read: {} us\n", .{latency.read_p99_us});
std.debug.print("P999 read: {} us\n", .{latency.read_p999_us});

// P99 latency critical for SLAs
// - < 1ms: Excellent
// - 1-10ms: Good
// - > 10ms: Needs investigation
```

#### Cache Metrics

```zig
const cache = my_db.getCacheStats();

std.debug.print("Cache size: {} pages\n", .{cache.size});
std.debug.print("Cache capacity: {} pages\n", .{cache.capacity});
std.debug.print("Hit rate: {.2}%\n", .{cache.hit_rate});
std.debug.print("Evictions: {}\n", .{cache.evictions});

// Target: > 80% hit rate
// < 70%: Increase cache size
// > 95%: May be oversized
```

### Benchmarking Methodology

#### Microbenchmarking

```bash
# Benchmark single operation
zig-out/bin/bench run --filter "point_get" --repeats 100

# Use many repeats for statistical significance
# Analyze variance: CV < 5% is good
```

#### Macro Workload Testing

```bash
# Run real-world workload simulation
zig-out/bin/bench run --suite macro --repeats 5

# Compare against baselines
zig-out/bin/bench compare bench/baselines/dev_nvme ./results
```

#### Regression Testing

```bash
# Automated regression gate
zig-out/bin/bench run --baseline bench/baselines/ci

# Fails if:
# - Throughput down > 5%
# - P99 latency up > 10%
```

## Real-World Scenarios

### Scenario 1: Read-Heavy API Backend

**Problem:** API endpoints slow after adding 10M users

**Diagnosis:**
```zig
const cache_stats = my_db.getCacheStats();
// Hit rate: 45% (too low)

const tree_stats = my_db.getBTreeStats();
// Depth: 5 (acceptable)

const io_stats = my_db.getIOStats();
// Page reads: High (10M/minute)
```

**Solution:**
```zig
// Increase cache size
const config = db.Db.Config{
    .page_cache_size = 4 * 1024 * 1024 * 1024, // 4GB
    // Preload user profiles on startup
};

// Result: Hit rate 92%, latency 80% reduction
```

### Scenario 2: Write-Heavy Event Logging

**Problem:** Event ingestion slow (10K events/s)

**Diagnosis:**
```zig
const io_stats = my_db.getIOStats();
// Fsync count: 10K/second (one per event)

const txn_stats = my_db.getTxnStats();
// Avg commit latency: 5000us (5ms)
```

**Solution:**
```zig
// Batch events into larger transactions
const batch_size = 1000;
var i: usize = 0;
while (i < events.len) {
    var w = try db.beginWrite();
    defer w.abort();

    var j: i;
    while (j < @min(i + batch_size, events.len)) : (j += 1) {
        try w.put(events[j].key, events[j].value);
    }

    _ = try w.commit();
    i += batch_size;
}

// Result: 100K events/s (10x improvement)
```

### Scenario 3: Memory-Constrained Container

**Problem:** OOM kills in 512MB container

**Diagnosis:**
```zig
const mem_stats = my_db.getMemoryStats();
// Page cache: 800MB (exceeds container)

const cache_stats = my_db.getCacheStats();
// Hit rate: 98% (oversized cache)
```

**Solution:**
```zig
// Reduce cache size
const config = db.Db.Config{
    .page_cache_size = 128 * 1024 * 1024, // 128MB
    .max_concurrent_reads = 100, // Limit concurrency
};

// Monitor and adjust
// Result: Stable at 200MB RSS
```

### Scenario 4: HDD Archive Storage

**Problem:** Queries on HDD storage slow (10s+)

**Diagnosis:**
```bash
iostat -x 1
// %util: 100% (saturated)
// await: 50ms (high latency)
```

**Solution:**
```zig
// Larger cache to reduce disk access
const config = db.Db.Config{
    .page_cache_size = 8 * 1024 * 1024 * 1024, // 8GB
    .page_size = 16 * 1024, // Larger pages
    .read_ahead = true, // Enable read-ahead
};

// Consider SSD cache tier
// Result: P99 latency 500ms (20x improvement)
```

## Troubleshooting Checklist

Use this checklist when diagnosing issues:

### Initial Diagnosis
- [ ] Collect baseline metrics
- [ ] Enable query logging
- [ ] Check cache hit rate
- [ ] Monitor I/O stats
- [ ] Profile with perf

### Memory Issues
- [ ] Check for leaks (allocation tracking)
- [ ] Validate cache sizing
- [ ] Review allocator choice
- [ ] Monitor swap usage

### I/O Issues
- [ ] Check disk utilization (iostat)
- [ ] Profile read/write patterns
- [ ] Verify filesystem mount options
- [ ] Consider storage upgrade

### Query Issues
- [ ] Identify slow queries
- [ ] Check B+tree depth
- [ ] Review key design
- [ ] Optimize access patterns

### Validation
- [ ] Run benchmark suite
- [ ] Compare against baselines
- [ ] Verify no regressions
- [ ] Document changes

## Next Steps

Now that you understand performance troubleshooting:

- [Performance Tuning Guide](./performance-tuning.md) - Proactive optimization strategies
- [Benchmarking Guide](./benchmarking.mdx) - Comprehensive benchmark methodology
- [Development Setup Guide](./development-setup.mdx) - Build and run from source
- [Testing Guide](./testing.mdx) - Test coverage and quality assurance
