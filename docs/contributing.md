# Contributing to NorthstarDB

NorthstarDB follows a strict principle: **benchmarks and tests are the source of truth**. All changes must be backed by measurable evidence.

## Core Philosophy

> **"You're allowed to implement the DB only if the benchmarks and tests are green"**

This project uses test-driven development enforced by CI gates:
- Write/extend benchmark or test first
- Implement smallest change to pass
- Lock in with regression baselines

## The Rule of Three

Every change follows this workflow:

### 1. Write the Test/Benchmark First

Before implementing any feature:

```bash
# Write a failing test
zig test src/db.zig --test-filter "my_new_feature"

# Or extend benchmark suite
# Edit src/bench/suite.zig to add new benchmark
```

### 2. Make It Pass

Implement the minimal change:

```zig
// Smallest implementation that passes
pub fn myNewFeature(...) !void {
    // TODO: optimize later, prove it works first
}
```

### 3. Lock in with Baselines

```bash
# Run benchmarks to establish performance
zig build run -- run --suite micro --repeats 5

# If performance is acceptable, capture baselines
zig build run -- run --output bench/baselines/ci/bench/
```

## Evidence Requirements

### For Bug Fixes

**Required:**
- Unit test demonstrating the bug
- Benchmark showing no regression (or improvement)

```zig
test "fix: handle empty key in put" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    var wtxn = try db.beginWrite();
    defer wtxn.abort();

    // Should return error, not crash
    try std.testing.expectError(error.KeyEmpty, wtxn.put("", "value"));
}
```

### For New Features

**Required:**
1. Unit tests covering edge cases
2. Benchmark for performance-critical paths
3. Hardening test if affecting crash safety

**Example PR Description:**

```markdown
## Add: B+tree range query optimization

### Evidence
- **Unit tests**: `src/btree.zig:452-489` (8 tests)
- **Benchmark**: `bench/btree/range_scan_optimized` (new)
- **Results**:
  - Hot scan: +45% throughput (1.2M -> 1.74M ops/sec)
  - P99 latency: -38% (15us -> 9.3us)
  - No regression in other benchmarks

### Performance Profile
```
Before: 1.2M ops/sec, p99=15us
After:  1.74M ops/sec, p99=9.3us
```

### Baselines
- `bench/baselines/ci/bench/btree/range_scan_optimized.json`
```

### For Performance Changes

**Required:**
- Before/after benchmark numbers
- Regression gate must pass
- Explanation for any intentional regressions

```markdown
## Perf: Add checksum caching

### Trade-off
- Read latency: +2% (within gate threshold)
- Checksum CPU: -40% (major improvement)

### Gate Status
- All critical benchmarks: PASSED
- Throughput regression: 0.8% (threshold: 5%)
- P99 regression: 1.2% (threshold: 10%)
```

## Running Tests

### Unit Tests

```bash
# Run all tests
zig build test

# Test specific module
zig test src/db.zig
zig test src/btree.zig

# Run with filter
zig build test -- --test-filter "mvcc"
```

### Hardening Tests

```bash
# Run crash consistency tests
zig build run -- property-test --iterations 1000

# Quick validation
zig build run -- property-test --quick
```

### Benchmarks

```bash
# Run all micro benchmarks
zig build run -- run --suite micro

# Run single benchmark with warmup
zig build run -- run --filter "point_get_hot" --repeats 10 --warmup-ops 1000

# Output JSON for analysis
zig build run -- run --output results/
```

## CI Gating

### Thresholds (Month 1)

| Metric | Threshold | Description |
|--------|-----------|-------------|
| Throughput | -5% | Max regression allowed |
| P99 Latency | +10% | Max regression allowed |
| Alloc/op | +5% | Max regression allowed |
| Fsync/op | 0% | No increase allowed |

### Critical Benchmarks

Only these are gated in CI:

- `bench/pager/open_close_empty` - DB open cost
- `bench/pager/read_page_random_16k_hot` - Hot read path
- `bench/pager/commit_meta_fsync` - Commit cost anchor
- `bench/btree/point_get_hot_1m` - Point query performance
- `bench/btree/build_sequential_insert_1m` - Build performance
- `bench/mvcc/readers_256_point_get_hot` - Read scalability

### Updating Baselines

**When legitimate performance changes occur:**

1. Document the trade-off in commit message
2. Add `[update-baselines]` tag
3. CI will auto-update on merge to main

```bash
git commit -m "Add WAL preallocation [update-baselines]

Trade-off: +3% first-write latency for -50% variance"
```

## Code Review Checklist

Reviewers should verify:

- [ ] Tests added for new behavior
- [ ] Benchmarks show no unexpected regression
- [ ] Hardening tests pass (crash safety)
- [ ] Evidence included in PR description
- [ ] Baselines updated if performance changed
- [ ] CI gate passes (or baselines refresh approved)

## Development Workflow

### Starting Work

```bash
# Create feature branch
git checkout -b feature/my-feature

# Ensure tests pass
zig build test

# Check current benchmark state
zig build run -- run --suite micro --repeats 3
```

### Making Changes

```bash
# Write test first
# Edit src/db.zig to add test

# Run test (should fail)
zig test src/db.zig

# Implement minimal fix
# Edit src/db.zig to implement

# Verify test passes
zig test src/db.zig

# Check performance
zig build run -- run --suite micro
```

### Submitting

```bash
# Run full test suite
zig build test

# Run benchmark gate
zig build run -- gate bench/baselines/ci

# If gate passes, commit
git add .
git commit -m "feat: add feature

Evidence:
- Tests: src/module.zig:123-145
- Bench: +5% throughput on X
- Baseline: no regressions"

git push origin feature/my-feature
```

## Common Patterns

### Adding a New Benchmark

```zig
// In src/bench/suite.zig

pub const newBenchmark = Benchmark{
    .name = "bench/my_new_operation",
    .description = "Measures X performance under Y conditions",
    .suite = .micro,
    .critical = true,  // Set to true if this should gate CI
    .fn = benchmarkMyNewOperation,
};

fn benchmarkMyNewOperation(allocator: std.mem.Allocator, opts: RunOptions) !Result {
    // Setup
    var db = try Db.open(allocator);
    defer db.close();

    // Warmup
    var timer = try std.time.Timer.start();
    for (0..opts.warmup_ops) |_| {
        _ = try db.someOperation();
    }

    // Measurement
    var ops: u64 = 0;
    const start = timer.read();
    while (timer.read() - start < opts.measure_ns) {
        _ = try db.someOperation();
        ops += 1;
    }

    // Return result
    return Result{
        .ops_total = ops,
        .duration_ns = timer.read() - start,
        // ... other fields
    };
}
```

### Property-Based Testing

```zig
test "property: B+tree maintains invariants under random operations" {
    var prng = std.Random.DefaultPrng.init(42);
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    for (0..1000) |_| {
        const op = prng.random().enumValue(Op);
        switch (op) {
            .put => try randomPut(&db, &prng),
            .get => _ = try randomGet(&db, &prng),
            .del => try randomDel(&db, &prng),
        }
        // Verify invariants after each operation
        try validateInvariants(&db);
    }
}
```

## Project Structure

```
src/
├── db.zig              # Public API
├── pager.zig           # Storage layer
├── btree.zig           # B+tree implementation
├── mvcc.zig            # Concurrency control
├── bench/              # Benchmark infrastructure
│   ├── runner.zig      # Benchmark executor
│   ├── suite.zig       # Benchmark definitions
│   └── types.zig       # Common types
└── hardening.zig       # Hardening test utilities

spec/                   # Specifications (truth for behavior)
├── benchmarks_v0.md    # Performance targets
├── hardening_v0.md     # Crash safety requirements
└── semantics_v0.md     # Transaction semantics

bench/
├── baselines/
│   ├── ci/             # CI regression gates
│   └── dev_nvme/       # Development baselines
└── results.schema.json # Result schema

scripts/
└── manage_baselines.sh # Baseline management
```

## Getting Help

- **Specs**: See `spec/` directory for authoritative requirements
- **Examples**: Check existing benchmarks in `src/bench/suite.zig`
- **Tests**: Unit tests demonstrate expected behavior
- **Docs**: `docs/bench-harness.md` for benchmark details

## Quick Reference

| Command | Purpose |
|---------|---------|
| `zig build test` | Run unit tests |
| `zig build run -- run` | Run all benchmarks |
| `zig build run -- gate <dir>` | Run CI gate |
| `zig build run -- property-test` | Run hardening tests |
| `./scripts/manage_baselines.sh generate` | Create baselines |
