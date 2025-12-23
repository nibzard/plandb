//! NorthstarDB benchmark harness CLI.
//!
//! Entry point for running benchmarks, comparing results, and gating CI.
//! Supports micro, macro, and hardening benchmark suites with configurable options.

const std = @import("std");
const bench = @import("bench/runner.zig");
const suite = @import("bench/suite.zig");
const compare = @import("bench/compare.zig");
const _ref_model_tests = @import("ref_model.zig");
const _db_tests = @import("db.zig");
const _property_based_tests = @import("property_based.zig");
const _validator = @import("validator.zig");
const _fuzz = @import("fuzz.zig");
const plugin_cli = @import("plugins/cli.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const allocator = gpa;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "run")) {
        try runBenchmarks(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "compare")) {
        try compareBaselines(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "compare-dirs")) {
        try compareDirs(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "gate")) {
        try gateSuite(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "property-test") or std.mem.eql(u8, command, "prop")) {
        try runPropertyTests(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "--list") or std.mem.eql(u8, command, "list")) {
        try listBenchmarks(allocator);
    } else if (std.mem.eql(u8, command, "validate")) {
        try validateTree(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "dump")) {
        try dumpTree(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "fuzz")) {
        try runFuzzTests(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "plugin")) {
        var cli = plugin_cli.PluginCli.init(allocator);
        try cli.run(args[2..]);
    } else {
        try printUsage();
    }
}

fn printUsage() !void {
    std.debug.print(
        \\NorthstarDB Benchmark Harness
        \\
        \\Usage:
        \\  bench run [options]          Run benchmarks
        \\  bench compare <baseline> <candidate>  Compare single result files
        \\  bench compare-dirs <baseline> <candidate>  Compare entire output dirs
        \\  bench gate <baseline> [options]        Gate suite - fail on critical regressions
        \\  bench property-test [options]          Run property-based correctness tests
        \\  bench --list                   List all available benchmarks and suites
        \\  bench validate <db.db>         Validate B+tree invariants
        \\  bench dump <db.db> [options]   Dump B+tree structure
        \\  bench fuzz [options]           Run fuzzing tests on node decode
        \\  bench plugin <cmd> [options]   Plugin management (list, test, validate, info, mock, trace)
        \\
        \\Run options:
        \\  --repeats <n>         Number of repeats (default: 5)
        \\  --filter <pattern>    Filter benchmarks by name
        \\  --suite <type>        Filter by suite (micro|macro|hardening)
        \\  --output <dir>        Output directory for JSON results
        \\  --baseline <dir>      Baseline directory for comparison
        \\  --seed <n>            Random seed
        \\  --warmup-ops <n>      Number of warmup operations before measurement
        \\  --warmup-ns <n>       Warmup time in nanoseconds before measurement
        \\
        \\Gate options:
        \\  --repeats <n>         Number of repeats (default: 5)
        \\  --filter <pattern>    Filter benchmarks by name
        \\  --suite <type>        Filter by suite (micro|macro|hardening)
        \\  --output <dir>        Output directory for JSON results
        \\  --seed <n>            Random seed
        \\  --warmup-ops <n>      Number of warmup operations before measurement
        \\  --warmup-ns <n>       Warmup time in nanoseconds before measurement
        \\  --threshold-throughput <pct>  Max throughput regression percentage (default: 5.0)
        \\  --threshold-p99 <pct>         Max P99 latency regression percentage (default: 10.0)
        \\  --threshold-alloc <pct>       Max allocation regression percentage (default: 5.0)
        \\  --threshold-fsync <pct>       Max fsync increase percentage (default: 0.0)
        \\
        \\Property-test options:
        \\  --iterations <n>       Number of test iterations (default: 100)
        \\  --seed <n>             Random seed for reproducible tests (default: 42)
        \\  --max-txns <n>         Maximum concurrent transactions (default: 10)
        \\  --max-keys <n>         Maximum keys per transaction (default: 50)
        \\  --crash-simulation     Enable crash equivalence testing (default: true)
        \\  --quick                Run with reduced iterations for quick validation
        \\
        \\Dump options:
        \\  --show-values          Show values in addition to keys
        \\  --max-key-len <n>      Truncate keys at this length (default: 50)
        \\  --max-val-len <n>      Truncate values at this length (default: 50)
        \\
        \\Fuzz options:
        \\  --iterations <n>       Number of fuzz iterations per test (default: 1000)
        \\  --seed <n>             Random seed for reproducible fuzzing (default: 12345)
        \\  --quick                Run with reduced iterations for quick validation
        \\
    , .{});
}

fn runBenchmarks(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var runner_args = bench.RunArgs{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--repeats") and i + 1 < args.len) {
            runner_args.repeats = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            runner_args.filter = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--suite") and i + 1 < args.len) {
            runner_args.suite = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            runner_args.output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--baseline") and i + 1 < args.len) {
            runner_args.baseline_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
            runner_args.seed = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--warmup-ops") and i + 1 < args.len) {
            runner_args.config.warmup_ops = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--warmup-ns") and i + 1 < args.len) {
            runner_args.config.warmup_ns = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            return;
        }
    }

    var bench_runner = bench.Runner.init(allocator);
    defer bench_runner.deinit();

    try suite.registerBenchmarks(&bench_runner);

    try bench_runner.run(runner_args);
}

fn compareBaselines(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Error: compare requires baseline and candidate paths\n", .{});
        return;
    }

    const baseline_path = args[0];
    const candidate_path = args[1];

    var comparator = compare.Comparator.init(allocator, .{});

    const result = try comparator.compare(baseline_path, candidate_path);
    defer {
        allocator.free(result.notes);
        allocator.free(result.bench_name);
    }

    if (result.passed) {
        std.debug.print("✅ PASSED: ", .{});
    } else {
        std.debug.print("❌ FAILED: ", .{});
    }

    std.debug.print(
        "Throughput: {d}%, P99 Latency: {d}%, Fsync/op: {d}%\n",
        .{ result.throughput_change_pct, result.p99_latency_change_pct, result.fsync_change_pct }
    );

    if (result.notes.len > 0) {
        std.debug.print("\n{s}\n", .{result.notes});
    }
}

fn compareDirs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Error: compare-dirs requires baseline and candidate directory paths\n", .{});
        return;
    }

    const baseline_dir = args[0];
    const candidate_dir = args[1];

    var comparator = compare.Comparator.init(allocator, .{});
    const result = try comparator.compareDirs(baseline_dir, candidate_dir);
    defer compare.freeDirComparisonResult(allocator, &result);

    std.debug.print("\n# Directory Comparison Report\n\n", .{});
    std.debug.print("{s}\n\n", .{result.notes});

    std.debug.print("Individual Results:\n", .{});
    for (result.comparisons) |comp| {
        const status = if (comp.passed) "✅" else "❌";
        std.debug.print("{s} {s}: ", .{ status, comp.bench_name });
        std.debug.print("Throughput: {d:.1}%, P99: {d:.1}%, Fsync/op: {d:.1}%\n", .{
            comp.throughput_change_pct,
            comp.p99_latency_change_pct,
            comp.fsync_change_pct,
        });
    }

    std.debug.print("\n", .{});
    if (result.passed) {
        std.debug.print("✅ DIR COMPARE PASSED: {d}/{d} passed\n", .{ result.passed_count, result.total_compared });
    } else {
        std.debug.print("❌ DIR COMPARE FAILED: {d}/{d} failed\n", .{ result.failed_count, result.total_compared });
        std.process.exit(1);
    }
}

fn gateSuite(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: gate requires baseline path\n", .{});
        return;
    }

    const baseline_path = args[0];
    var runner_args = bench.RunArgs{};
    runner_args.baseline_dir = baseline_path;

    // Parse remaining options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--repeats") and i + 1 < args.len) {
            runner_args.repeats = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            runner_args.filter = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--suite") and i + 1 < args.len) {
            runner_args.suite = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            runner_args.output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
            runner_args.seed = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--warmup-ops") and i + 1 < args.len) {
            runner_args.config.warmup_ops = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--warmup-ns") and i + 1 < args.len) {
            runner_args.config.warmup_ns = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--threshold-throughput") and i + 1 < args.len) {
            runner_args.max_throughput_regression_pct = try std.fmt.parseFloat(f64, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--threshold-p99") and i + 1 < args.len) {
            runner_args.max_p99_latency_regression_pct = try std.fmt.parseFloat(f64, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--threshold-alloc") and i + 1 < args.len) {
            runner_args.max_alloc_regression_pct = try std.fmt.parseFloat(f64, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--threshold-fsync") and i + 1 < args.len) {
            runner_args.max_fsync_increase_pct = try std.fmt.parseFloat(f64, args[i + 1]);
            i += 1;
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            return;
        }
    }

    var bench_runner = bench.Runner.init(allocator);
    defer bench_runner.deinit();

    try suite.registerBenchmarks(&bench_runner);

    // Run gated benchmarks
    const result = try bench_runner.runGated(runner_args);

    if (result.passed) {
        std.debug.print("✅ GATE PASSED: All critical benchmarks within thresholds\n", .{});
    } else {
        std.debug.print("❌ GATE FAILED: {d}/{d} critical benchmarks failed\n", .{ result.failed_critical, result.total_critical });

        if (result.failure_notes.len > 0) {
            std.debug.print("\nFailures:\n{s}\n", .{result.failure_notes});
        }

        // Exit with error code to fail the gate
        std.process.exit(1);
    }
}

fn listBenchmarks(allocator: std.mem.Allocator) !void {
    var bench_runner = bench.Runner.init(allocator);
    defer bench_runner.deinit();

    try suite.registerBenchmarks(&bench_runner);

    // Group benchmarks by suite
    const micro_suite = bench.Suite.micro;
    const macro_suite = bench.Suite.macro;
    const hardening_suite = bench.Suite.hardening;

    var micro_count: usize = 0;
    var macro_count: usize = 0;
    var hardening_count: usize = 0;

    std.debug.print("Available Benchmarks:\n\n", .{});

    // List micro benchmarks
    std.debug.print("Micro Benchmarks:\n", .{});
    for (bench_runner.benchmarks.items) |benchmark| {
        if (benchmark.suite == micro_suite) {
            const critical_marker = if (benchmark.critical) " (CRITICAL)" else "";
            std.debug.print("  {s}{s}\n", .{ benchmark.name, critical_marker });
            micro_count += 1;
        }
    }
    if (micro_count == 0) {
        std.debug.print("  (none)\n", .{});
    }

    // List macro benchmarks
    std.debug.print("\nMacro Benchmarks:\n", .{});
    for (bench_runner.benchmarks.items) |benchmark| {
        if (benchmark.suite == macro_suite) {
            const critical_marker = if (benchmark.critical) " (CRITICAL)" else "";
            std.debug.print("  {s}{s}\n", .{ benchmark.name, critical_marker });
            macro_count += 1;
        }
    }
    if (macro_count == 0) {
        std.debug.print("  (none)\n", .{});
    }

    // List hardening benchmarks
    std.debug.print("\nHardening Benchmarks:\n", .{});
    for (bench_runner.benchmarks.items) |benchmark| {
        if (benchmark.suite == hardening_suite) {
            const critical_marker = if (benchmark.critical) " (CRITICAL)" else "";
            std.debug.print("  {s}{s}\n", .{ benchmark.name, critical_marker });
            hardening_count += 1;
        }
    }
    if (hardening_count == 0) {
        std.debug.print("  (none)\n", .{});
    }

    // Summary
    const total = micro_count + macro_count + hardening_count;
    std.debug.print("\nSummary: {d} benchmarks ({d} micro, {d} macro, {d} hardening)\n", .{ total, micro_count, macro_count, hardening_count });
}

fn runPropertyTests(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const property_based = @import("property_based.zig");

    var config = property_based.PropertyTestConfig{
        .max_concurrent_txns = 10,
        .max_keys_per_txn = 50,
        .max_total_keys = 200,
        .random_seed = 42,
        .num_iterations = 100,
        .enable_crash_simulation = true,
    };

    // Parse command line arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            config.num_iterations = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
            config.random_seed = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--max-txns") and i + 1 < args.len) {
            config.max_concurrent_txns = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--max-keys") and i + 1 < args.len) {
            config.max_keys_per_txn = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-crash-simulation")) {
            config.enable_crash_simulation = false;
        } else if (std.mem.eql(u8, args[i], "--quick")) {
            config.num_iterations = 10;
            config.max_concurrent_txns = 3;
            config.max_keys_per_txn = 10;
        } else {
            std.debug.print("Unknown property-test option: {s}\n", .{args[i]});
            return;
        }
    }

    std.debug.print("Running property-based tests with configuration:\n", .{});
    std.debug.print("  Iterations: {}\n", .{config.num_iterations});
    std.debug.print("  Random seed: {}\n", .{config.random_seed});
    std.debug.print("  Max concurrent transactions: {}\n", .{config.max_concurrent_txns});
    std.debug.print("  Max keys per transaction: {}\n", .{config.max_keys_per_txn});
    std.debug.print("  Crash simulation: {}\n", .{config.enable_crash_simulation});
    std.debug.print("\n", .{});

    var runner = property_based.PropertyTestRunner.init(allocator, config);
    const results = try runner.runAllPropertyTests();
    defer {
        for (results) |*result| {
            result.deinit();
        }
        allocator.free(results);
    }

    property_based.PropertyTestRunner.printResults(results);

    // Check if all tests passed
    var all_passed = true;
    for (results) |result| {
        if (!result.passed) {
            all_passed = false;
        }
    }

    if (all_passed) {
        std.debug.print("\n✅ All property-based tests PASSED\n", .{});
    } else {
        std.debug.print("\n❌ Some property-based tests FAILED\n", .{});
        std.process.exit(1);
    }
}

fn validateTree(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: validate requires database path\n", .{});
        return;
    }

    const db_path = args[0];
    try _validator.runValidate(allocator, db_path);
}

fn dumpTree(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: dump requires database path\n", .{});
        return;
    }

    const db_path = args[0];
    var config = _validator.DumpConfig{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--show-values")) {
            config.show_values = true;
        } else if (std.mem.eql(u8, args[i], "--max-key-len") and i + 1 < args.len) {
            config.max_key_length = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--max-val-len") and i + 1 < args.len) {
            config.max_value_length = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            return;
        }
    }

    try _validator.dumpTree(allocator, db_path, config);
}

fn runFuzzTests(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var iterations: usize = 1000;
    var seed: u64 = 12345;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            iterations = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
            seed = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--quick")) {
            iterations = 100;
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            return;
        }
    }

    std.debug.print("Running fuzzing tests with {} iterations (seed: {})...\n\n", .{ iterations, seed });

    try _fuzz.runAllFuzzTests(allocator, iterations);
}
