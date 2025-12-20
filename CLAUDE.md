# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

NorthstarDB is a database built from scratch in Zig, designed for massive read concurrency and deterministic replay. The project follows a strict principle: **benchmarks and tests are the source of truth**. No DB implementation changes are allowed unless all benchmarks and hardening tests pass.

## Core Architecture

- **Language**: Zig (explicit memory, explicit errors, explicit performance)
- **Storage**: Single file format with pager system
- **Core components**: Pager (page allocation, IO), B+tree (ordered KV), MVCC snapshots, Commit stream
- **Design goal**: Many readers, single writer (initially) with crash safety

## Common Commands

### Building and Running
```bash
# Build the benchmark harness
zig build

# Run benchmarks
zig build run -- run [options]

# Run unit tests
zig build test

# Run specific test suites
zig test src/main.zig
```

### Benchmark Harness
The main entry point is `src/main.zig` which provides:
- `bench run` - Run benchmarks with options
- `bench compare <baseline> <candidate>` - Compare results

Common benchmark options:
- `--repeats <n>` - Number of repeats (default: 5)
- `--filter <pattern>` - Filter benchmarks by name
- `--suite <type>` - Filter by suite (micro|macro|hardening)
- `--output <dir>` - Output directory for JSON results

### Testing
Tests are embedded in the source files. Run with:
```bash
# All tests
zig build test

# Specific test file
zig test src/db.zig
zig test src/ref_model.zig
```

## Project Structure

### Source Organization
- `src/main.zig` - CLI entry point and benchmark harness
- `src/db.zig` - Public DB API (Db, ReadTxn, WriteTxn)
- `src/ref_model.zig` - Reference model implementation
- `src/hardening.zig` - Hardening test utilities
- `src/bench/` - Benchmark infrastructure
  - `runner.zig` - Benchmark runner framework
  - `suite.zig` - Benchmark definitions
  - `types.zig` - Common benchmark types
  - `compare.zig` - Baseline comparison logic

### Specifications
All critical specifications are in `spec/`:
- `benchmarks_v0.md` - Month 1 benchmark targets and CI thresholds
- `hardening_v0.md` - Crash consistency and fuzz tests
- `semantics_v0.md` - MVCC and transaction semantics
- `file_format_v0.md` - On-disk format specification

### Baselines
Benchmark baselines stored in `bench/baselines/`:
- `ci/` - CI baselines (regression gates)
- `dev_nvme/` - Development baselines

## Development Workflow

1. **Rule of Three**:
   - Write/extend benchmark or hardening test
   - Implement smallest change to pass
   - Lock in with regression baselines

2. **Performance Work**:
   - Microbenchmark → profile → change → microbenchmark again
   - Benchmark suite must show improvement or stability

3. **Critical Requirement**:
   - All benchmarks must be green before any DB implementation
   - Hardening tests must pass nightly
   - CI gates on regression: -5% throughput, +10% p99 latency

## Benchmark Suites (Month 1)

- **Suite A**: Pager/Storage primitives (open/close, read/write, checksum)
- **Suite B**: B+tree core (point get/put, range scan, delete)
- **Suite C**: MVCC snapshots (readers scaling, conflict detection)
- **Suite D**: Time-travel/commit stream (record append, replay, snapshot by txn)

## Key Constraints

- No DB implementation changes unless benchmarks and tests are green
- Performance claims must be proven with reproducible benchmarks
- Correctness first, proven continuously with property tests
- State is derived; the log is truth
- Pay coordination at commit, not on every read

## Design Principles

### Domain-Driven Design (DDD)
- **Ubiquitous Language**: Use consistent terminology across code and specs (TxnId, PageId, Lsn, Snapshot)
- **Bounded Contexts**: Each module has clear responsibility:
  - Pager: Physical storage and page management
  - B+tree: Logical ordering and tree operations
  - MVCC: Concurrency control and versioning
  - Log: Commit stream and replay semantics
- **Domain Isolation**: Core domain logic independent of infrastructure concerns

### Modularity
- **Explicit Dependencies**: Each module imports only what it needs
- **Clear Interfaces**: Well-defined APIs between components
- **Testable Units**: Each module can be unit tested in isolation
- **Incremental Development**: Can implement and validate modules independently

### Additional Principles

#### Test-Driven Development (TDD)
- **Red-Green-Refactor**: Write failing test, make it pass, then improve
- **Tests Before Code**: All features start with test definitions
- **Regression Protection**: Tests guard against future changes
- **Living Documentation**: Tests demonstrate intended behavior

#### Don't Repeat Yourself (DRY)
- **Single Source of Truth**: Each piece of logic exists once
- **Abstraction Over Duplication**: Extract common patterns
- **Configuration over Code**: Prefer data-driven approaches
- **Reusable Components**: Design for composition

#### Keep It Simple, Stupid (KISS)
- **Simplicity First**: Choose the simplest working solution
- **Avoid Premature Optimization**: Measure before optimizing
- **Clear Over Clever**: Readability matters more than cleverness
- **Incremental Complexity**: Add complexity only when needed

## Build System Notes

The project uses Zig's build system (`build.zig`) which creates:
- `bench` executable for running benchmarks
- Test targets for unit tests
- No external dependencies currently

You're allowed to implement the DB only if the benchmarks and tests are green
