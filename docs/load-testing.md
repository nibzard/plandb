# Production Load Testing Guide

## Overview

NorthstarDB includes production-scale load testing infrastructure to validate database behavior under high concurrency, large datasets, and sustained operations. This guide covers running and interpreting load tests.

## Load Test Infrastructure

### Components

- **`src/bench/load_test.zig`** - Core load testing harness
  - `LoadTestConfig` - Test configuration parameters
  - `LoadTestHarness` - Main test execution engine
  - `WorkerState` - Per-thread worker state management
  - `ResourceSnapshot` - Resource monitoring data

### Resource Monitoring

The load test harness tracks:
- **CPU Utilization** - Percentage CPU usage during test
- **Memory Usage** - GB used and percentage of total
- **Thread Count** - Active threads during execution
- **Open File Descriptors** - For leak detection

Platform support:
- **Linux**: Full support via `/proc` filesystem
- **macOS**: Partial support (stubs for future implementation)

## Available Load Tests

### `bench/load/concurrent_readers_1000`

**Purpose**: Validate read scalability under high concurrency

**Configuration**:
- 1000 concurrent reader threads
- 0 writer threads
- 1M pre-populated keys
- 60 second measurement duration

**Success Criteria**:
- No significant throughput degradation vs single-reader baseline
- P99 latency stays within 2x of baseline
- Zero errors under normal load

### `bench/load/mixed_read_write_1000x4`

**Purpose**: Validate mixed workload with high read/write concurrency

**Configuration**:
- 1000 concurrent reader threads
- 4 concurrent writer threads
- 1M pre-populated keys
- 60 second measurement duration

**Success Criteria**:
- Writer throughput not starved by readers
- Read latency not severely impacted by writes
- Transaction conflicts handled gracefully

### `bench/load/burst_traffic_pattern`

**Purpose**: Simulate production traffic spikes

**Configuration**:
- 500 concurrent reader threads
- 2 concurrent writer threads
- 500K pre-populated keys
- Burst pattern: 5x normal traffic every 10 seconds for 2 seconds

**Success Criteria**:
- Database handles burst without crashes
- Graceful degradation when resource limits approached
- Recovery to baseline performance after burst

### `bench/load/sustained_1hour`

**Purpose**: Detect memory leaks, performance degradation over time

**Configuration**:
- 100 concurrent reader threads
- 2 concurrent writer threads
- 100K pre-populated keys
- CI runs 1 minute version; full test runs 1 hour

**Success Criteria**:
- No memory leaks (stable memory usage)
- No performance degradation over time
- Zero crashes or assertion failures

## Running Load Tests

### Quick Start

```bash
# Run all load tests
zig build run -- run --suite macro --filter "bench/load"

# Run specific load test
zig build run -- run --suite macro --filter "bench/load/concurrent_readers_1000"

# Run with JSON output
zig build run -- run --suite macro --filter "bench/load" --output-dir results/load

# Run with CSV output for analysis
zig build run -- run --suite macro --filter "bench/load" --csv-output --output-dir results/load
```

### Custom Configuration

Load test parameters can be customized in `src/bench/suite.zig`:

```zig
const load_config = load_test.LoadTestConfig{
    .reader_count = 1000,           // Number of reader threads
    .writer_count = 4,              // Number of writer threads
    .warmup_duration_ns = 5 * std.time.ns_per_s,  // Warmup time
    .measure_duration_ns = 60 * std.time.ns_per_s, // Measurement time
    .initial_keys = 1_000_000,      // Pre-populated key count
    .key_size = 16,                 // Key size in bytes
    .value_size = 256,              // Value size in bytes
    .enable_burst = false,          // Enable burst traffic pattern
};
```

## Interpreting Results

### Metrics Collected

**Throughput Metrics**:
- `ops_per_sec` - Total operations per second
- `reads_per_sec` - Read operations per second
- `writes_per_sec` - Write operations per second

**Latency Metrics**:
- `latency_ns.p50` - Median latency
- `latency_ns.p95` - 95th percentile latency
- `latency_ns.p99` - 99th percentile latency
- `latency_ns.max` - Maximum latency observed

**Resource Metrics**:
- `avg_cpu_percent` - Average CPU usage
- `peak_cpu_percent` - Peak CPU usage
- `avg_memory_gb` - Average memory used
- `peak_memory_gb` - Peak memory used

**Stability Metrics**:
- `throughput_variance` - Coefficient of variation (CV)
- `is_stable` - CV < 15% considered stable

**Error Metrics**:
- `errors_total` - Total errors encountered
- `error_rate` - Errors per operation

### Success Criteria

A load test is considered successful if:
1. **Stability**: `is_stable = true` (CV < 15%)
2. **Errors**: `error_rate < 0.001` (0.1% max)
3. **Throughput**: Within 80% of single-operation baseline
4. **Resources**: No resource exhaustion (CPU < 95%, memory within limits)

### Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Throughput degradation | < 20% vs baseline | Under high concurrency |
| P99 latency increase | < 2x baseline | 1000 readers vs 1 reader |
| Memory stability | < 5% variance | Over sustained test |
| Error rate | < 0.1% | Under normal load |
| Crash-free | 100% uptime | For sustained tests |

## Integration with CI

Load tests run in CI with reduced duration:
- CI runs 60-second versions for quick feedback
- Nightly runs full 1-hour sustained tests
- Pre-commit hooks run quick smoke tests (10 seconds)

### CI Configuration

```bash
# Quick CI load tests (< 2 minutes total)
zig build run -- run --suite macro --filter "bench/load" \
    --repeats 1 --output-dir ci-results/load
```

## Troubleshooting

### High Memory Usage

**Symptoms**: `peak_memory_gb` increases continuously during test

**Causes**:
- Memory leaks in DB implementation
- Unbounded cache growth
- Latency sample accumulation

**Solutions**:
- Check `valgrind` or `ASAN` reports
- Review cache eviction policies
- Reduce `initial_keys` or measurement duration

### CPU Saturation

**Symptoms**: `peak_cpu_percent` near 100%, throughput drops

**Causes**:
- Too many threads for available cores
- Inefficient locking/serialization
- Exponential time complexity in hot path

**Solutions**:
- Reduce thread count to match core count
- Profile with `perf` to find bottlenecks
- Check for lock contention

### High Error Rate

**Symptoms**: `error_rate > 0.001`

**Causes**:
- Resource exhaustion (file descriptors, memory)
- Lock timeouts
- Assertion failures

**Solutions**:
- Check `dmesg` for OS-level errors
- Increase resource limits (`ulimit -n`)
- Review error handling code

## Future Enhancements

- [ ] Real database integration (currently uses simulated latency)
- [ ] Network-distributed load testing
- [ ] Performance regression baselines
- [ ] Automatic performance degradation alerts
- [ ] Comparison with other databases (Redis, SQLite)
- [ ] Custom workload definition language

## References

- **Benchmark Specification**: `spec/benchmarks_v0.md`
- **Load Test Implementation**: `src/bench/load_test.zig`
- **Benchmark Harness**: `src/bench/runner.zig`
