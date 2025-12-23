# Benchmark Harness Guide

NorthstarDB's benchmark harness provides comprehensive performance testing, regression detection, and CI gating capabilities.

## Quick Start

```bash
# Build
zig build

# Run all benchmarks
zig build run -- run

# List available benchmarks
zig build run -- --list

# Compare results
zig build run -- compare baseline.json candidate.json
```

## Commands

### `bench run` - Run Benchmarks

Execute benchmarks with configurable options.

```bash
zig build run -- run [options]
```

#### Run Options

| Option | Description | Default |
|--------|-------------|---------|
| `--repeats <n>` | Number of repeats per benchmark | 5 |
| `--filter <pattern>` | Filter benchmarks by name pattern | none (all) |
| `--suite <type>` | Filter by suite: `micro`, `macro`, `hardening` | none (all) |
| `--output <dir>` | Output directory for JSON results | stdout only |
| `--baseline <dir>` | Baseline directory for comparison | none |
| `--seed <n>` | Random seed for reproducibility | system time |
| `--warmup-ops <n>` | Warmup operations before measurement | 0 |
| `--warmup-ns <n>` | Warmup time in nanoseconds | 0 |

#### Examples

```bash
# Run all benchmarks with console output
zig build run -- run

# Run single benchmark, 10 repeats
zig build run -- run --filter "point_get_hot" --repeats 10

# Run micro suite only, output to directory
zig build run -- run --suite micro --output results/

# Run with warmup and baseline comparison
zig build run -- run --warmup-ops 1000 --baseline bench/baselines/ci --output results/
```

### `bench compare` - Compare Single Results

Compare two benchmark result files.

```bash
zig build run -- compare <baseline> <candidate>
```

#### Output

- `passed`: Boolean indicating if candidate is within thresholds
- Percentage change for throughput, P99 latency, fsync/op
- Exit code 1 if failed

#### Example

```bash
zig build run -- compare bench/baselines/ci/bench_pager_open_close_empty.json results/bench_pager_open_close_empty_r000.json
```

### `bench compare-dirs` - Compare Directories

Compare entire baseline and candidate directories.

```bash
zig build run -- compare-dirs <baseline_dir> <candidate_dir>
```

Collects all `*.json` files recursively, matches by basename, compares each.

#### Output

- Summary report with comparison notes
- Individual benchmark pass/fail status
- Exit code 1 if any comparison failed

#### Example

```bash
zig build run -- compare-dirs bench/baselines/ci results/
```

### `bench gate` - CI Regression Gate

Run benchmarks and fail if critical metrics regress.

```bash
zig build run -- gate <baseline_dir> [options]
```

Uses baseline directory as regression reference. Only critical benchmarks affect gate result.

#### Gate Thresholds

| Threshold | Default | Description |
|----------|---------|-------------|
| `--threshold-throughput <pct>` | 5.0 | Max throughput regression % |
| `--threshold-p99 <pct>` | 10.0 | Max P99 latency regression % |
| `--threshold-alloc <pct>` | 5.0 | Max allocation regression % |
| `--threshold-fsync <pct>` | 0.0 | Max fsync increase % |

#### Gate Behavior

- Passes if all critical benchmarks within thresholds
- Exits with code 1 on failure
- Outputs detailed failure notes

#### Example

```bash
# CI gate with custom thresholds
zig build run -- gate bench/baselines/ci \
  --threshold-throughput 10.0 \
  --threshold-p99 15.0 \
  --output results/
```

### `bench --list` / `bench list` - List Benchmarks

List all registered benchmarks grouped by suite.

```bash
zig build run -- --list
```

#### Output

- Micro benchmarks (with CRITICAL marker)
- Macro benchmarks (with CRITICAL marker)
- Hardening benchmarks (with CRITICAL marker)
- Summary counts

### `bench validate` - Validate B+tree

Check B+tree invariants in a database file.

```bash
zig build run -- validate <database.db>
```

### `bench dump` - Dump B+tree Structure

Dump B+tree contents for debugging.

```bash
zig build run -- dump <database.db> [options]
```

#### Dump Options

| Option | Description | Default |
|--------|-------------|---------|
| `--show-values` | Include values in output | keys only |
| `--max-key-len <n>` | Truncate keys at length | 50 |
| `--max-val-len <n>` | Truncate values at length | 50 |

### `bench property-test` - Property-Based Tests

Run correctness tests with random workloads.

```bash
zig build run -- property-test [options]
```

#### Property Test Options

| Option | Description | Default |
|--------|-------------|---------|
| `--iterations <n>` | Test iterations | 100 |
| `--seed <n>` | Random seed | 42 |
| `--max-txns <n>` | Max concurrent transactions | 10 |
| `--max-keys <n>` | Max keys per transaction | 50 |
| `--crash-simulation` | Enable crash equivalence testing | true |
| `--quick` | Reduced iterations for quick validation | - |

### `bench fuzz` - Fuzzing Tests

Run fuzzing tests on node decode.

```bash
zig build run -- fuzz [options]
```

#### Fuzz Options

| Option | Description | Default |
|--------|-------------|---------|
| `--iterations <n>` | Fuzz iterations per test | 1000 |
| `--seed <n>` | Random seed | 12345 |
| `--quick` | Reduced iterations | - |

## Benchmark Suites

### Micro Benchmarks

Low-level component tests (pager, B+tree, MVCC, log).

- `bench/pager/open_close_empty` - Empty DB open/close (CRITICAL)
- `bench/pager/read_page_random_16k_hot` - Hot random page reads (CRITICAL)
- `bench/pager/commit_meta_fsync` - Meta commit with fsync (CRITICAL)
- `bench/pager/read_page_random_16k_cold` - Cold random page reads (CRITICAL)
- `bench/btree/point_get_hot_1m` - Point gets on 1M keys (CRITICAL)
- `bench/btree/build_sequential_insert_1m` - Sequential insert build (CRITICAL)
- `bench/btree/range_scan_1k_rows_hot` - Hot range scan 1K rows (CRITICAL)
- `bench/mvcc/snapshot_open_close` - Snapshot open/close (CRITICAL)
- `bench/mvcc/readers_256_point_get_hot` - 256 readers point get (CRITICAL)
- `bench/mvcc/writer_commits_with_readers_128` - Writer with 128 readers (CRITICAL)
- `bench/log/append_commit_record` - Commit record append (CRITICAL)
- `bench/log/replay_into_memtable` - Replay into memtable (CRITICAL)

### Macro Benchmarks

Realistic workload simulations.

- `bench/macro/task_queue_claims` - Multi-agent task queue (CRITICAL)
- `bench/macro/code_knowledge_graph` - Code repo knowledge graph (CRITICAL)
- `bench/macro/time_travel_replay` - Time-travel + replay (CRITICAL)
- `bench/macro/cartridge_latency` - Cartridge vs baseline scan (CRITICAL)

### Hardening Benchmarks

Crash consistency and corruption detection.

- `bench/hardening/torn_write_header_detection` - Torn write header (CRITICAL)
- `bench/hardening/torn_write_payload_detection` - Torn write payload (CRITICAL)
- `bench/hardening/short_write_missing_trailer` - Short write detection (CRITICAL)
- `bench/hardening/mixed_valid_corrupt_records` - Mixed records (CRITICAL)
- `bench/hardening/invalid_magic_number` - Invalid magic detection (CRITICAL)
- `bench/hardening/clean_recovery_to_txn_id` - Clean recovery (CRITICAL)

## Baselines

### Structure

```
bench/baselines/
├── ci/               # CI regression gates
│   └── bench/
│       ├── pager/
│       ├── btree/
│       ├── mvcc/
│       ├── log/
│       ├── macro/
│       └── hardening/
└── dev_nvme/         # Development performance tracking
    └── bench/
        └── ...
```

### Baseline Files

Each benchmark has a single aggregated baseline file:

- Naming: `<benchmark_name>.json`
- Example: `bench/pager/open_close_empty.json`
- Contains aggregated metrics across all repeats
- Used by `gate` and `compare` commands

### Per-Repeat Output Files

When `--output` is specified, individual repeat files are created:

- Naming: `<benchmark_name>_r<repeat_index>.json`
- Example: `bench/pager/open_close_empty_r000.json`
- One file per repeat per benchmark
- Schema-validated JSON

### Establishing New Baselines

```bash
# Run benchmarks and output to directory
zig build run -- run --output bench/baselines/ci/bench/

# Aggregate per-repeat files manually if needed
# (TODO: add aggregate command)
```

## JSON Schema

### Schema File

`bench/results.schema.json` - JSON Schema for validation

### Result Structure

```json
{
  "bench_name": "bench/pager/open_close_empty",
  "profile": {
    "name": "ci",
    "cpu_model": "...",
    "core_count": 4,
    "ram_gb": 8.0,
    "os": "linux",
    "fs": "ext4"
  },
  "build": {
    "zig_version": "0.12.0",
    "mode": "ReleaseFast",
    "target": null,
    "lto": null
  },
  "git": {
    "sha": "abc1234",
    "branch": "main",
    "dirty": false
  },
  "config": {
    "seed": 42,
    "warmup_ops": 0,
    "warmup_ns": 0,
    "measure_ops": 1,
    "threads": 1,
    "db": {
      "page_size": 16384,
      "checksum": "crc32c",
      "sync_mode": "fsync_per_commit",
      "mmap": false
    }
  },
  "results": {
    "ops_total": 10000,
    "duration_ns": 500000000,
    "ops_per_sec": 20000.0,
    "latency_ns": {
      "p50": 50,
      "p95": 100,
      "p99": 200,
      "max": 500
    },
    "bytes": {
      "read_total": 0,
      "write_total": 0
    },
    "io": {
      "fsync_count": 0,
      "fdatasync_count": 0,
      "open_count": 0,
      "close_count": 0,
      "mmap_faults": 0
    },
    "alloc": {
      "alloc_count": 100,
      "alloc_bytes": 8192
    },
    "errors_total": 0,
    "notes": null,
    "stability": {
      "coefficient_of_variation": 0.03,
      "is_stable": true,
      "repeat_count": 5,
      "threshold_used": 0.05
    }
  },
  "repeat_index": 0,
  "repeat_count": 5,
  "timestamp_utc": "1234567890"
}
```

### Key Metrics

| Metric | Description |
|--------|-------------|
| `ops_per_sec` | Primary throughput metric |
| `latency_ns.p99` | Primary latency metric |
| `io.fsync_count` | Durability cost |
| `alloc.alloc_bytes` | Memory usage |
| `stability.coefficient_of_variation` | Result stability (lower = more stable) |

## Filtering Patterns

The `--filter` option uses substring matching on benchmark names.

```bash
# All pager benchmarks
zig build run -- run --filter "pager"

# All point get benchmarks
zig build run -- run --filter "point_get"

# All macro benchmarks
zig build run -- run --filter "macro"

# Specific benchmark
zig build run -- run --filter "open_close_empty"
```

## Warmup Strategies

Two warmup modes available:

### Count-based (`--warmup-ops`)

Runs N operations before measurement. Good for steady-state measurement.

```bash
zig build run -- run --warmup-ops 1000
```

### Time-based (`--warmup-ns`)

Runs for specified nanoseconds before measurement. Good for JIT warmup.

```bash
zig build run -- run --warmup-ns 1000000000  # 1 second
```

## CI Integration

### Regression Gates

```yaml
# .github/workflows/bench.yml
- name: Run benchmark gate
  run: zig build run -- gate bench/baselines/ci

- name: Upload results
  if: always()
  uses: actions/upload-artifact@v3
  with:
    name: bench-results
    path: results/
```

### Baseline Refresh

```yaml
# Nightly baseline update
- name: Refresh baselines
  run: |
    zig build run -- run --output bench/baselines/ci/bench/
    git commit -am "nightly: refresh baselines"
```

## Profile Detection

Harness auto-detects hardware profile:

| Profile | Requirements |
|---------|--------------|
| `dev_nvme` | 8+ cores, 16GB+ RAM, high-performance storage |
| `ci` | Default (CI environments) |

Profile affects baseline selection and threshold tuning.

## Stability Metrics

The coefficient of variation (CV) measures result stability:

- CV = std_dev / mean
- Threshold: CV < 0.05 (5%) = stable
- Included in aggregated results when repeats >= 2
