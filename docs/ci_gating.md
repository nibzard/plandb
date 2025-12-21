# CI Regression Gating System

This document describes the CI regression gating system for NorthstarDB, which enforces performance thresholds automatically.

## Overview

The CI gating system ensures that no database implementation changes are allowed unless all benchmarks and hardening tests pass. This is a core principle of the project.

## Architecture

### Components

1. **Benchmark Harness** (`src/main.zig`, `src/bench/runner.zig`)
   - Executes benchmarks with configurable repeats
   - Enforces threshold checking in `runGated()` function
   - CI thresholds: throughput (-5%), p99 latency (+10%), alloc/op (+5%), fsync/op (no increase)

2. **Baseline Management** (`scripts/manage_baselines.sh`)
   - Validates baseline JSON files
   - Generates new baselines
   - Runs benchmark gates

3. **GitHub Actions Workflow** (`.github/workflows/ci.yml`)
   - Runs unit tests
   - Checks for existing baselines
   - Runs benchmark gate if baselines exist
   - Establishes initial baselines if none exist
   - Updates baselines on demand

### Thresholds

The system enforces these CI thresholds for **critical benchmarks**:

- **Throughput**: Must not regress more than 5%
- **P99 Latency**: Must not increase more than 10%
- **Allocations/op**: Must not increase more than 5%
- **Fsync/op**: Must not increase (0% tolerance)

## Usage

### Local Development

```bash
# Build and run tests
zig build
zig build test

# Run benchmarks
./zig-out/bin/bench run --suite micro --repeats 5

# Run benchmark gate against current baselines
./zig-out/bin/bench gate bench/baselines/ci --suite micro

# Or use the management script
./scripts/manage_baselines.sh gate bench/baselines/ci micro

# Generate new baselines
./scripts/manage_baselines.sh generate micro 5 bench/baselines/my_new_baselines

# Validate existing baselines
./scripts/manage_baselines.sh validate bench/baselines/ci
```

### CI Workflow

The CI pipeline follows this flow:

1. **Test Phase**: Runs `zig build test`
2. **Baseline Check**: Determines if CI baselines exist
3. **Benchmark Gate**:
   - If baselines exist: Runs benchmark gate and fails CI on regressions
   - If no baselines: Skips gate and creates initial baselines
4. **Baseline Updates**:
   - Automatic: Establishes initial baselines on first run
   - Manual: Updates only when `[update-baselines]` is in commit message

### Benchmark Suites

- **Suite A**: Pager/Storage primitives (open/close, read/write, checksum)
- **Suite B**: B+tree core (point get/put, range scan, delete)
- **Suite C**: MVCC snapshots (readers scaling, conflict detection)
- **Suite D**: Time-travel/commit stream (record append, replay, snapshot by txn)

## Managing Baselines

### Establishing Initial Baselines

When first setting up CI on a new machine/environment:

```bash
# Generate clean baselines for critical benchmarks
./zig-out/bin/bench run --suite micro --repeats 5 --output bench/baselines/ci \
  --filter "micro/point_get|micro/point_put|micro/range_scan"

# Commit the baselines
git add bench/baselines/ci/
git commit -m "Add CI baselines for critical benchmarks"
```

### Updating Baselines

When legitimately changing performance characteristics (e.g., adding features):

1. Make your code changes
2. Update commit message to include `[update-baselines]`
3. Push to main branch
4. CI will automatically update baselines

```bash
git commit -m "Add new index feature [update-baselines]"
git push origin main
```

### Validating Baselines

Before committing baselines:

```bash
# Validate JSON format
./scripts/manage_baselines.sh validate bench/baselines/ci

# Test gate against new baselines (should pass)
./scripts/manage_baselines.sh gate bench/baselines/ci micro
```

## Critical vs Non-Critical Benchmarks

Only **critical benchmarks** are gated in CI. These are marked with `critical = true` in their registration.

Current critical benchmarks:
- Pager open/close operations
- Random page reads
- Metadata commit fsyncs

Non-critical benchmarks:
- Full database workloads (variable, environment-dependent)
- Hardening/fuzz tests (correctness-focused)
- Macro benchmarks (large-scale, noisy)

## Troubleshooting

### Gate Fails - No Baselines

```
⚠️ No CI baselines found - benchmark gate will be skipped
```

**Solution**: Push to main branch to trigger baseline establishment.

### Gate Fails - Regression

```
❌ GATE FAILED: 1/3 critical benchmarks failed
Failures:
- micro/point_get: FAILED (throughput -8%, p99 +15%)
```

**Solutions**:
1. **False positive**: Investigate if regression is real
2. **Legitimate change**: Add `[update-baselines]` to commit message
3. **Performance bug**: Fix the regression

### Gate Fails - Benchmark Error

```
error: InsufficientSpace
```

**Solution**: Benchmark implementation issue - fix the underlying bug.

### Baseline Validation Fails

```
ERROR: Invalid JSON in baseline file: bench/baselines/ci/micro_bench.json
```

**Solution**: Regenerate baselines or fix JSON corruption.

## Best Practices

1. **Always run benchmarks locally** before pushing
2. **Use consistent environments** for baseline generation
3. **Document legitimate performance changes** in commit messages
4. **Monitor CI artifacts** for benchmark results and trends
5. **Keep baselines clean** - only critical benchmarks needed
6. **Test baseline validation** after any manual changes

## Performance Monitoring

- CI artifacts contain detailed benchmark results
- Use `zig build run --output results` for local analysis
- Compare results with `./zig-out/bin/bench compare baseline candidate`

## File Structure

```
bench/
├── baselines/
│   ├── ci/              # CI gating baselines (auto-managed)
│   └── dev_nvme/        # Development baselines (manual)
├── results/             # Temporary benchmark output
└── *.schema.json        # Result schema validation

scripts/
└── manage_baselines.sh  # Baseline management utilities

.github/workflows/
└── ci.yml              # CI pipeline definition
```