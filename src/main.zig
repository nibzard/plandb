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
    } else if (std.mem.eql(u8, command, "gate")) {
        try gateSuite(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "--list") or std.mem.eql(u8, command, "list")) {
        try listBenchmarks(allocator);
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
        \\  bench compare <baseline> <candidate>  Compare results
        \\  bench gate <baseline> [options]        Gate suite - fail on critical regressions
        \\  bench --list                   List all available benchmarks and suites
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
    defer allocator.free(result.notes);

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
