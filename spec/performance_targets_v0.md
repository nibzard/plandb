spec/performance_targets_v0.md

# Performance Targets v0

## Overview

This document defines explicit performance targets for NorthstarDB benchmarks across two hardware profiles:
- **CI profile**: Cheap runner configuration for regression detection in CI
- **dev_nvme profile**: High-performance configuration for development and performance claims

## Profile Specifications

### CI Profile (ci)
- **Purpose**: Regression detection in continuous integration
- **CPU**: 4 core virtual machine
- **RAM**: 8GB
- **Storage**: Standard VM storage (variable performance)
- **Build mode**: ReleaseFast
- **Focus**: Regression detection only (absolute targets may vary due to hardware variability)

### dev_nvme Profile
- **Purpose**: Performance validation and development targets
- **CPU**: Physical CPU with 8+ cores
- **RAM**: 16GB+
- **Storage**: NVMe SSD with consistent performance
- **Build mode**: ReleaseFast
- **Focus**: Absolute performance targets and regression detection

## Measurement Rules

### Common Requirements (Both Profiles)
- **Warmup**: 1-3 seconds or N operations (not counted in results)
- **Repeats**: Minimum 5 runs per benchmark
- **Variability**: Coefficient of variation > 10% marks results as unstable
- **Metrics**: All benchmarks must report full metric set per spec/benchmarks_v0.md

### CI Profile Rules
- Primary focus on **regression detection**
- Absolute performance targets are informational (hardware varies)
- Critical benchmarks must pass regression gates
- Some benchmarks may run with reduced datasets due to time constraints

### dev_nvme Profile Rules
- Must meet **absolute performance targets**
- Both regression detection and absolute performance validation
- Full dataset sizes for comprehensive performance measurement
- Performance claims must be demonstrated on this profile

## Benchmark Performance Targets

### Suite A: Pager / Storage Primitives

#### bench/pager/open_close_empty
**CI Profile**: Regression only
**dev_nvme Profile**:
- Target p99 < 200µs
- Target throughput > 50,000 ops/sec

#### bench/pager/read_page_random_16k_hot
**CI Profile**: Regression only
**dev_nvme Profile**:
- Target p50 < 5µs
- Target p99 < 20µs
- Target throughput > 200,000 ops/sec

#### bench/pager/read_page_random_16k_cold
**CI Profile**: Regression only
**dev_nvme Profile**:
- Target p50 < 200µs
- Target p99 < 1ms
- Target throughput > 1,000 ops/sec

#### bench/pager/commit_meta_fsync
**CI Profile**: Regression + fsync correctness
**dev_nvme Profile**:
- Target p50 < 2ms
- Target p99 < 10ms
- Must maintain fsync_count == commits
- Target throughput > 100 commits/sec

### Suite B: B+tree Core

#### bench/btree/build_sequential_insert_1m
**CI Profile**: Regression only (may use 100k records)
**dev_nvme Profile**:
- Target build time < 10s for 1M records
- Target throughput > 100,000 inserts/sec
- Write amplification < 2.0

#### bench/btree/point_get_hot_1m
**CI Profile**: Regression only
**dev_nvme Profile**:
- Target p50 < 2µs
- Target p99 < 10µs
- Target throughput > 500,000 gets/sec

#### bench/btree/range_scan_1k_rows_hot
**CI Profile**: Regression only
**dev_nvme Profile**:
- Target p99 < 200µs per scan
- Target throughput > 5,000 scans/sec
- Target rows/sec > 5,000,000

### Suite C: MVCC Snapshots

#### bench/mvcc/snapshot_open_close
**CI Profile**: Regression only
**dev_nvme Profile**:
- Target p99 < 5µs
- Target throughput > 200,000 snapshots/sec

#### bench/mvcc/readers_256_point_get_hot
**CI Profile**: Regression only (may use reduced thread count)
**dev_nvme Profile**:
- Target scaling: 16× single-thread throughput by 256 readers
- Target aggregate throughput > 1,000,000 ops/sec
- Per-thread p99 < 20µs

#### bench/mvcc/writer_commits_with_readers_128
**CI Profile**: Regression only
**dev_nvme Profile**:
- Writer p99 < 20ms under read pressure
- Reader p99 degradation < 2× vs no-writer case
- Target writer throughput > 50 commits/sec

### Suite D: Time-Travel / Commit Stream

#### bench/log/append_commit_record
**CI Profile**: Regression only
**dev_nvme Profile**:
- Target throughput > 200,000 records/sec
- Target latency p99 < 50µs per record

#### bench/log/replay_into_memtable
**CI Profile**: Regression only
**dev_nvme Profile**:
- Target replay time < 2s for 1M records
- Target throughput > 500,000 records/sec

## Regression Thresholds

Both profiles use these regression thresholds:
- **Throughput**: -5% or worse vs baseline
- **Latency p99**: +10% or worse vs baseline
- **Allocations/op**: +5% or worse vs baseline
- **fsync/op**: Any increase fails unless explicitly approved

## Implementation Requirements

### Benchmark Harness
- Must emit profile identifier in JSON output
- Must validate hardware meets minimum profile requirements
- Must warn when results are unstable (CV > 10%)
- Must provide clear pass/fail indicators for targets

### Baseline Management
- CI baselines updated automatically on approved runs
- dev_nvme baselines updated manually on performance improvements
- All baselines include full hardware and build metadata

### Target Validation
- dev_nvme runs must validate absolute targets
- CI runs focus on regression detection
- Failed targets should produce clear diagnostic information
- Performance below targets requires investigation and optimization

## Success Metrics

### Month 1 Success Criteria
- All critical benchmarks pass CI regression gates
- dev_nvme profile meets >= 80% of absolute targets
- Performance regressions caught before merge
- Clear performance trend visibility over time

### Future Evolution
- Targets will tighten as implementation matures
- Additional benchmarks added for new features
- Profile specifications may evolve with hardware changes
- Success metrics should improve month over month