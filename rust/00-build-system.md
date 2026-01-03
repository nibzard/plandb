# NorthstarDB Rust Migration: Build System Specification

## Purpose

This document provides a comprehensive natural language specification of the NorthstarDB build system, describing the current Zig build configuration and mapping each component to its Cargo equivalent. This specification enables a Rust developer to implement the complete build system without referring to Zig code.

---

## Current Zig Build System Overview

### Build System Architecture

The Zig build system is configured in a single build.zig file at the repository root. This file defines compilation targets, build steps, and command-line interfaces for running benchmarks and tests. The system follows Zig's compile-time execution model, where the build script runs at compile time to configure the build graph.

### Primary Build Outputs

The Zig build system produces two main outputs: a benchmark executable and a test suite. The benchmark executable serves as both a performance measurement tool and a general-purpose CLI for database operations. The test suite aggregates unit tests from all source modules into a single test executable.

### Build Step Structure

The build system defines three categories of build steps: compilation steps, execution steps, and dependency relationships. Compilation steps transform source code into executable artifacts. Execution steps run compiled artifacts with optional arguments. Dependency relationships ensure steps run in the correct order.

---

## Zig Build Steps in Detail

### Step One: Benchmark Executable Creation

The build process begins by creating the benchmark executable. This step has several key characteristics:

The executable name is set to "bench". The root source file points to src/main.zig, which contains the CLI entry point. Target and optimization settings are configurable through command-line options. The build system accepts standard target and optimization flags from Zig's build API, allowing cross-compilation and debug/release builds.

The executable is installed to the standard output directory, making it available for subsequent steps.

### Step Two: Benchmark Run Step

After creating the executable, the build system defines a run step for the benchmark harness. This step:

Depends on the install step, ensuring the executable exists before running. Accepts command-line arguments passed through from the build invocation. Forwards all user-provided arguments to the benchmark executable. Creates a named build step called "run" that can be invoked directly.

The run step enables the common pattern of building and executing benchmarks in a single command.

### Step Three: Test Suite Creation

The build system creates a separate executable for running tests. This executable:

Uses the same root source file (src/main.zig) as the benchmark executable. Collects all test blocks from imported modules. Exposes them through Zig's test runner infrastructure.

The test step enables comprehensive unit testing with a single command.

---

## Source File Test Organization

### Embedded Test Pattern

Zig uses an embedded test pattern where tests reside alongside the code they test. Each Zig source file can contain test blocks that define unit tests. The main entry point imports all modules that contain tests, registering them with the test runner.

### Test Discovery Mechanism

Test discovery happens through module imports and comptime test registration. The main.zig file imports all modules containing tests. Each imported module's test blocks are automatically registered. The test runner executes all discovered tests when invoked.

This pattern ensures tests always stay synchronized with the code they test.

---

## Benchmark Harness Integration

### CLI Entry Point Structure

The main.zig file serves as the CLI entry point for multiple commands. It provides a unified interface to:

Run benchmarks with configurable options. Compare benchmark results against baselines. Execute property-based tests. Validate database file integrity. Dump database structure for debugging. Run fuzzing tests. Manage plugins.

### Command Parsing and Dispatch

The CLI uses a simple command parser that:

Reads command-line arguments. Identifies the subcommand as the first argument. Dispatches to handler functions based on the subcommand. Parses subcommand-specific options. Executes the requested operation.

### Benchmark Command Options

The benchmark run command accepts numerous options:

Repeats: Controls how many times each benchmark executes. Filter pattern: Selects benchmarks matching a substring. Suite filter: Limits execution to micro, macro, or hardening suites. Output directory: Specifies where JSON results are written. Baseline directory: Provides baseline data for comparison. Seed: Sets random seed for reproducibility. Warmup operations: Configures pre-measurement warmup. Warmup nanoseconds: Sets time-based warmup duration. CSV output: Requests CSV format alongside JSON.

These options enable flexible benchmark execution for different scenarios.

---

## Baseline Comparison System

### Comparison Command Structure

The compare command enables performance regression detection by comparing two benchmark result files. The system:

Reads baseline results from a reference file. Reads candidate results from a new run. Calculates percentage changes for throughput, latency, and fsync metrics. Determines pass/fail based on configurable thresholds.

### Directory Comparison

The compare-dirs command extends comparison to entire directories of results. This enables:

Comprehensive regression testing across all benchmarks. Aggregated pass/fail reporting. Per-benchmark detailed metrics.

### Gating Command

The gate command combines benchmark execution with regression checking. It:

Runs benchmarks with specified options. Compares results against a baseline directory. Applies configurable thresholds for critical metrics. Exits with non-zero status if critical regressions detected.

This enables continuous integration gates that fail on performance regressions.

---

## Property-Based Testing Integration

### Property Test Command

The property-test command executes property-based tests with configurable parameters:

Iterations: Controls test repetition count. Seed: Sets random seed for reproducibility. Max concurrent transactions: Limits transaction concurrency. Max keys per transaction: Controls test data size. Crash simulation: Enables crash equivalence testing. Quick mode: Reduces iterations for fast validation.

### Property Test Framework

The property-based testing framework:

Generates random database operations. Executes operations against both the database and a reference model. Verifies equivalence of results. Tests crash recovery behavior. Reports detailed failure information.

---

## Validation and Debugging Commands

### Validate Command

The validate command checks database file integrity by:

Opening the specified database file. Traversing the B+tree structure. Verifying invariants at each node. Reporting any structural corruption or invariant violations.

### Dump Command

The dump command provides visibility into database structure:

Reads the complete B+tree. Prints keys in sorted order. Optionally prints values. Truncates long keys and values for readability. Useful for debugging test failures.

### Fuzz Command

The fuzz command runs fuzzing tests:

Configurable iteration count. Seed for reproducibility. Quick mode for reduced testing. Tests node decode operations with mutated inputs.

---

## Plugin Management CLI

### Plugin Command Structure

The plugin command provides a sub-CLI for plugin management:

List: Shows available and installed plugins. Test: Executes plugin functionality. Validate: Checks plugin correctness. Info: Displays plugin metadata. Mock: Creates mock plugin data. Trace: Enables plugin execution tracing.

---

## Cargo Build System Mapping

### Workspace Root Configuration

The Cargo build system uses a workspace structure to mirror Zig's organization. The workspace root Cargo.toml defines:

Member crates list matching the project structure. Shared package metadata (version, edition, license). Consolidated dependency management. Build profiles for optimization levels. Feature flags for conditional compilation.

### Workspace Members

The workspace includes fourteen member crates:

Core database engine. B+tree implementation. Testing utilities. Benchmark framework. LLM client integration. Plugin system. Structured memory cartridges. Query processing. Autonomous optimization. Replication system. Consensus algorithm. Observability tools. CLI application.

### Workspace Dependency Management

Cargo enables centralized dependency declaration at the workspace level. All member crates inherit these dependencies, ensuring version consistency and reducing duplication. External dependencies like tokio, serde, and testing crates are declared once with version constraints.

---

## Benchmark Executable Mapping

### Cargo Binary Equivalent

The Zig bench executable maps to a Cargo binary crate. The northstar-cli crate provides:

Binary compilation through Cargo's [[bin]] configuration. Access to all feature-gated crates through optional dependencies. Clap-based argument parsing mirroring Zig's CLI. Subcommand dispatch to benchmark, testing, and validation functions.

### Criterion Integration

For microbenchmarking, Cargo integrates Criterion as a modern alternative to custom benchmark harnesses. Criterion provides:

Statistical rigor in benchmark execution. HTML reports with visualizations. Automatic baseline comparison. Warmup and measurement phases.

For macro benchmarks that require custom harnessing, the Rust port replicates the Zig runner pattern using custom infrastructure.

---

## Test Organization Mapping

### Unit Test Structure

Zig's embedded tests map to Rust's unit test modules. Each Rust source file includes a tests module containing:

Unit tests for public functions. Integration tests for internal components. Property tests using proptest or quickcheck.

### Integration Test Directory

Cargo's integration test pattern provides dedicated test directories. The tests/ directory in each crate contains:

Multi-file test scenarios. End-to-end workflows. Cross-crate integration tests.

### Test Discovery

Cargo automatically discovers and runs:

Unit tests in src/ files marked with #[test]. Integration tests in tests/ directory. Doc tests in documentation examples. Benchmarks in benches/ directory.

This automatic discovery mirrors Zig's comptime test registration.

---

## Build Step Mapping

### Compilation Steps

Zig's addExecutable maps to Cargo's package build process. Each crate in the workspace compiles independently based on its Cargo.toml configuration. Dependencies compile before dependents, ensuring correct build order.

### Run Steps

Zig's addRunArtifact maps to Cargo's run and test commands. The cargo run command executes binaries. The cargo test command executes test suites. The cargo bench command executes benchmarks.

### Custom Commands

Zig's custom step names map to Cargo's workspace member targets. Running specific crates uses the package flag. Running specific binaries uses the bin flag. This provides fine-grained control over what gets built and executed.

---

## Build Profile Mapping

### Development Profile

Zig's Debug optimization maps to Cargo's dev profile. Fast compilation takes priority over runtime performance. Minimal optimization enables quick edit-compile cycles.

### Release Profile

Zig's Release optimization maps to Cargo's release profile. Maximum optimization enables production performance. Link-time optimization reduces binary size and improves speed. Single codegen unit enables better cross-crate optimization.

### Benchmark Profile

Cargo supports a dedicated bench profile inheriting from release. Additional debugging information enables profiling. Optimizations match release for accurate measurement.

---

## Feature Flag Integration

### Conditional Compilation

Zig's build.zig uses comptime conditionals for features. Cargo uses feature flags for conditional compilation. Features enable or disable crate dependencies. Features control conditional compilation within crates.

### Feature Composition

Cargo features compose through dependency relationships. The AI feature enables multiple sub-features. The distributed feature combines replication and consensus. The full feature enables all capabilities.

This composition model provides flexible feature selection at build time.

---

## Benchmark Harness Implementation Strategy

### Criterion for Microbenchmarks

Use Criterion for Suite A benchmarks measuring pager primitives and low-level operations. Criterion provides statistical analysis and comparison out of the box. Microbenchmarks focus on single operation performance.

### Custom Harness for Macrobenchmarks

Replicate the Zig runner for Suite B, C, D benchmarks involving complex workflows. Custom harness enables:

JSON result output matching Zig format. Baseline comparison logic. Gating with configurable thresholds. Suite categorization (micro, macro, hardening). Warmup configuration. Repeat control with statistical aggregation.

### Benchmark Registration

Replicate Zig's comptime registration with compile-time macros. A benchmark registration macro collects:

Benchmark name and function. Suite classification. Critical flag for regression gating. Configuration for repeats and warmup.

The registration happens at compile time, building a benchmark catalog the runner can execute.

---

## Test Strategy Migration

### Property-Based Testing

Migrate property-based tests from Zig's custom framework to proptest. Proptest provides:

Strategy-based input generation. Automated shrinking for minimal counterexamples. Rich configuration options.

### Hardening Tests

Migrate crash consistency tests to Rust with similar structure. Tests should:

Simulate crashes at various points. Verify recovery correctness. Check equivalence with reference model. Use test fixtures for reproducible crashes.

### Fuzzing Integration

Migrate fuzzing harness to use cargo-fuzz or libFuzzer. Fuzz targets exercise:

Node decode operations. Deserialization logic. Parsing routines.

---

## Command Equivalents

### Benchmark Execution

Zig: zig build run -- run [options]

Rust: cargo run --release --bin northstar-cli -- run [options]

Or for Criterion microbenchmarks: cargo bench --bench suite_a

### Test Execution

Zig: zig build test

Rust: cargo test --workspace

### Unit Tests for Specific Crate

Zig: zig test src/main.zig

Rust: cargo test --package northstar-core

### Baseline Comparison

Zig: zig build run -- compare baseline.json candidate.json

Rust: cargo run --release --bin northstar-cli -- compare baseline.json candidate.json

### Gated Benchmarks

Zig: zig build run -- gate baseline_dir --suite micro

Rust: cargo run --release --bin northstar-cli -- gate baseline_dir --suite micro

---

## Build Configuration Best Practices

### Workspace Inheritance

Use workspace inheritance for package metadata to ensure consistency. All crates share the same version and edition. License information declared once. Repository URL centralized.

### Dependency Consolidation

Declare external dependencies at workspace level. All crates use workspace = true to inherit. Version constraints managed centrally. Feature configurations standardized.

### Profile Standardization

Define dev, release, and bench profiles at workspace level. All crates inherit optimized settings. Ensure consistent optimization across the project.

---

## Continuous Integration Mapping

### Test Commands

CI runs cargo test with feature flag combinations:

No default features: Tests core functionality only. All features: Tests complete feature set. Specific features: Tests individual feature combinations.

### Benchmark Commands

CI runs cargo bench to generate performance data. Baseline comparison uses the compare command. Gating uses the gate command with threshold configuration.

### Lint and Formatting

CI uses cargo clippy for lint detection. CI uses cargo fmt for formatting checks. Fail the build on warnings to enforce quality.

---

## Performance Validation Strategy

### Baseline Establishment

Run full benchmark suite on initial implementation. Store results as baselines in version control. Use baselines for regression detection in CI.

### Regression Thresholds

Configure thresholds matching Zig CI gates:

Throughput regression: maximum five percent slowdown. P99 latency regression: maximum ten percent increase. Allocation regression: maximum five percent increase. Fsync regression: zero percent increase tolerance.

These thresholds ensure performance does not degrade unnoticed.

---

## Build System Differences and Adaptations

### Compilation Model Difference

Zig compiles from source every time without intermediate artifact caching. Cargo uses target directory with incremental compilation. Rust builds may be faster after initial compilation due to caching.

### Test Execution Model

Zig runs all tests in a single executable. Cargo runs tests per crate by default. Use workspace test flag to run all tests together.

### Benchmark Discovery

Zig uses comptime registration. Rust uses compile-time attribute macros. Both achieve the same result: benchmark catalog at startup.

---

## Recommended Build Workflow

### Development Loop

Use dev profile for fastest compilation during active development. Run targeted tests for the current crate. Use release profile for performance validation.

### Performance Work

Use release profile for accurate measurement. Run benchmarks before and after changes. Use baseline comparison to detect regressions. Gate changes on performance criteria.

### CI Pipeline

Run tests with all feature combinations. Run benchmarks and compare to baseline. Fail build on performance regression. Run linters and formatters.

---

## Summary

The Zig build system provides a single-file build configuration with comptime execution. The Cargo equivalent uses a workspace structure with per-crate configuration and centralized dependency management. Benchmark execution transitions from custom harness to Criterion plus custom runner. Test organization transitions from embedded tests to unit test modules plus integration test directories. Feature flags replace comptime conditionals for conditional compilation. Build profiles map directly between systems with equivalent optimization levels. Command-line interfaces maintain parity between Zig and Rust implementations.

This specification enables implementing the complete Rust build system that preserves all Zig build system capabilities while leveraging Cargo's strengths in dependency management and incremental compilation.
