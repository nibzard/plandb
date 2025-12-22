//! Benchmark runner framework for executing and measuring performance tests.
//!
//! Provides the core runner that executes benchmarks with configurable repeats,
//! collects metrics, and enforces gating thresholds for CI/CD regression detection.

const std = @import("std");
const types = @import("types.zig");
const system_info = @import("system_info.zig");

test "schema validation rejects invalid benchmark results" {
    const allocator = std.testing.allocator;
    var runner = Runner.init(allocator);
    defer runner.deinit();

    // Create invalid result with empty bench_name
    const invalid_result = types.BenchmarkResult{
        .bench_name = "", // Invalid: empty string
        .profile = .{
            .name = .ci,
            .cpu_model = null,
            .core_count = 4,
            .ram_gb = 4.0,
            .os = "linux",
            .fs = "ext4",
        },
        .build = .{
            .zig_version = "0.15.2",
            .mode = .Debug,
            .target = null,
            .lto = null,
        },
        .config = .{
            .seed = null,
            .warmup_ops = 0,
            .warmup_ns = 0,
            .measure_ops = 1,
            .threads = 1,
            .db = .{
                .page_size = 16384,
                .checksum = .crc32c,
                .sync_mode = .fsync_per_commit,
                .mmap = false,
            },
        },
        .results = .{
            .ops_total = 100,
            .duration_ns = 1000000,
            .ops_per_sec = 100000.0,
            .latency_ns = .{
                .p50 = 10000,
                .p95 = 15000,
                .p99 = 20000,
                .max = 25000,
            },
            .bytes = .{
                .read_total = 1024,
                .write_total = 1024,
            },
            .io = .{
                .fsync_count = 1,
            },
            .alloc = .{
                .alloc_count = 10,
                .alloc_bytes = 1024,
            },
            .errors_total = 0,
        },
        .repeat_index = 0,
        .repeat_count = 5,
        .timestamp_utc = "1234567890",
        .git = .{
            .sha = "abc1234",
            .branch = "main",
            .dirty = null,
        },
    };

    // Try to write invalid result - should fail validation
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const validation_error = runner.writeJson(fbs.writer(), invalid_result);
    try std.testing.expectError(error.EmptyBenchName, validation_error);
}

test "schema validation accepts valid benchmark results" {
    const allocator = std.testing.allocator;
    var runner = Runner.init(allocator);
    defer runner.deinit();

    // Create valid result
    const valid_result = types.BenchmarkResult{
        .bench_name = "test/benchmark",
        .profile = .{
            .name = .ci,
            .cpu_model = null,
            .core_count = 4,
            .ram_gb = 4.0,
            .os = "linux",
            .fs = "ext4",
        },
        .build = .{
            .zig_version = "0.15.2",
            .mode = .Debug,
            .target = null,
            .lto = null,
        },
        .config = .{
            .seed = null,
            .warmup_ops = 0,
            .warmup_ns = 0,
            .measure_ops = 1,
            .threads = 1,
            .db = .{
                .page_size = 16384,
                .checksum = .crc32c,
                .sync_mode = .fsync_per_commit,
                .mmap = false,
            },
        },
        .results = .{
            .ops_total = 100,
            .duration_ns = 1000000,
            .ops_per_sec = 100000.0,
            .latency_ns = .{
                .p50 = 10000,
                .p95 = 15000,
                .p99 = 20000,
                .max = 25000,
            },
            .bytes = .{
                .read_total = 1024,
                .write_total = 1024,
            },
            .io = .{
                .fsync_count = 1,
            },
            .alloc = .{
                .alloc_count = 10,
                .alloc_bytes = 1024,
            },
            .errors_total = 0,
        },
        .repeat_index = 0,
        .repeat_count = 5,
        .timestamp_utc = "1234567890",
        .git = .{
            .sha = "abc1234",
            .branch = "main",
            .dirty = null,
        },
    };

    // Try to write valid result - should pass validation
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try runner.writeJson(fbs.writer(), valid_result);

    // Verify we can parse it back
    const json_str = fbs.getWritten();
    _ = try std.json.parseFromSliceLeaky(types.BenchmarkResult, allocator, json_str, .{});
}

pub const GateResult = struct {
    passed: bool,
    total_critical: usize,
    failed_critical: usize,
    failure_notes: []const u8,
};

pub const Benchmark = struct {
    name: []const u8,
    run_fn: RunFn,
    critical: bool = false,
    suite: Suite = .micro,
};

pub const Suite = enum { micro, macro, hardening };

pub const RunFn = *const fn (allocator: std.mem.Allocator, config: types.Config) anyerror!types.Results;

pub const Runner = struct {
    allocator: std.mem.Allocator,
    benchmarks: std.ArrayListUnmanaged(Benchmark),
    cached_profile: ?types.Profile = null,
    profile_cleanup: ?system_info.SystemInfo = null,

    pub fn init(allocator: std.mem.Allocator) Runner {
        return .{
            .allocator = allocator,
            .benchmarks = .{},
        };
    }

    pub fn deinit(self: *Runner) void {
        self.benchmarks.deinit(self.allocator);
        if (self.profile_cleanup) |cleanup| {
            system_info.freeSystemInfo(self.allocator, cleanup);
        }
    }

    pub fn addBenchmark(self: *Runner, bench: Benchmark) !void {
        try self.benchmarks.append(self.allocator, bench);
    }

    pub fn run(self: *Runner, args: RunArgs) !void {
        // Create output directory if needed
        if (args.output_dir) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        // Filter benchmarks
        const filtered = try self.filterBenchmarks(args.filter, args.suite);
        defer self.allocator.free(filtered);

        if (filtered.len == 0) {
            std.debug.print("No benchmarks match criteria\n", .{});
            return;
        }

        // Run benchmarks
        for (filtered) |bench| {
            std.debug.print("Running {s}...\n", .{bench.name});

            const results = try self.runSinglePerRepeat(bench, args);
            defer self.allocator.free(results);

            // Output per-repeat JSON files
            if (args.output_dir) |dir| {
                for (results) |result| {
                    const filename = try std.fmt.allocPrint(self.allocator, "{s}_r{d:0>3}.json", .{ bench.name, result.repeat_index });
                    defer self.allocator.free(filename);
                    const path = try std.fs.path.join(self.allocator, &.{ dir, filename });
                    defer self.allocator.free(path);

                    if (std.fs.path.dirname(path)) |parent| {
                        try std.fs.cwd().makePath(parent);
                    }

                    const file = try std.fs.cwd().createFile(path, .{});
                    defer file.close();

                    const buf = try self.allocator.alloc(u8, 4096);
                    defer self.allocator.free(buf);
                    try self.writeJson(file.writer(buf), result);
                }

                // Compare aggregated baseline if provided
                if (args.baseline_dir) |baseline_dir| {
                    const baseline_filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{bench.name});
                    defer self.allocator.free(baseline_filename);
                    const baseline_path = try std.fs.path.join(self.allocator, &.{ baseline_dir, baseline_filename });
                    defer self.allocator.free(baseline_path);

                    // Aggregate results for comparison
                    var results_data = std.ArrayListUnmanaged(types.Results){};
                    defer results_data.deinit(self.allocator);
                    for (results) |result| {
                        try results_data.append(self.allocator, result.results);
                    }
                    const aggregated = try self.aggregateResults(self.allocator, results_data.items);
                    const aggregated_result = types.BenchmarkResult{
                        .bench_name = bench.name,
                        .profile = try self.detectProfile(),
                        .build = try self.detectBuild(),
                        .config = args.config,
                        .results = aggregated,
                        .repeat_index = 0,
                        .repeat_count = args.repeats,
                        .timestamp_utc = try self.getTimestamp(),
                        .git = try self.detectGit(),
                    };

                    if (self.compareWithBaseline(aggregated_result, baseline_path)) |comparison| {
                        std.debug.print("  Comparison: {s}\n", .{comparison});
                    } else |err| {
                        std.debug.print("  Baseline comparison failed: {}\n", .{err});
                    }
                }
            } else {
                // Console output: show aggregated results only
                var results_data = std.ArrayListUnmanaged(types.Results){};
                defer results_data.deinit(self.allocator);
                for (results) |result| {
                    try results_data.append(self.allocator, result.results);
                }
                const aggregated = try self.aggregateResults(self.allocator, results_data.items);
                const aggregated_result = types.BenchmarkResult{
                    .bench_name = bench.name,
                    .profile = try self.detectProfile(),
                    .build = try self.detectBuild(),
                    .config = args.config,
                    .results = aggregated,
                    .repeat_index = 0,
                    .repeat_count = args.repeats,
                    .timestamp_utc = try self.getTimestamp(),
                    .git = try self.detectGit(),
                };

                const buf = try self.allocator.alloc(u8, 4096);
                defer self.allocator.free(buf);
                var fbs = std.io.fixedBufferStream(buf);
                try self.writeJson(fbs.writer(), aggregated_result);
                std.debug.print("{s}\n", .{fbs.getWritten()});
            }
        }
    }

    pub fn runGated(self: *Runner, args: RunArgs) !GateResult {
        if (args.baseline_dir == null) {
            return error.BaselineRequired;
        }

        // Create output directory if needed
        if (args.output_dir) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        // Filter benchmarks
        const filtered = try self.filterBenchmarks(args.filter, args.suite);
        defer self.allocator.free(filtered);

        if (filtered.len == 0) {
            std.debug.print("No benchmarks match criteria\n", .{});
            return GateResult{
                .passed = true,
                .total_critical = 0,
                .failed_critical = 0,
                .failure_notes = "",
            };
        }

        var total_critical: usize = 0;
        var failed_critical: usize = 0;
        var failure_notes = std.ArrayListUnmanaged(u8){};
        defer failure_notes.deinit(self.allocator);

        // Count critical benchmarks
        for (filtered) |bench| {
            if (bench.critical) {
                total_critical += 1;
            }
        }

        // Initialize comparator with CI thresholds from args
        var comparator = @import("compare.zig").Comparator.init(self.allocator, .{
            .max_throughput_regression_pct = args.max_throughput_regression_pct,
            .max_p99_latency_regression_pct = args.max_p99_latency_regression_pct,
            .max_alloc_regression_pct = args.max_alloc_regression_pct,
            .max_fsync_increase_pct = args.max_fsync_increase_pct,
        });

        // Run benchmarks and check critical ones
        for (filtered) |bench| {
            const critical_suffix = if (bench.critical) " (CRITICAL)" else "";
            std.debug.print("Running {s}{s}\n", .{ bench.name, critical_suffix });

            const results = try self.runSinglePerRepeat(bench, args);
            defer self.allocator.free(results);

            // Output per-repeat JSON files if requested
            if (args.output_dir) |dir| {
                for (results) |result| {
                    const filename = try std.fmt.allocPrint(self.allocator, "{s}_r{d:0>3}.json", .{ result.bench_name, result.repeat_index });
                    defer self.allocator.free(filename);
                    const path = try std.fs.path.join(self.allocator, &.{ dir, filename });
                    defer self.allocator.free(path);

                    if (std.fs.path.dirname(path)) |parent| {
                        try std.fs.cwd().makePath(parent);
                    }

                    const file = try std.fs.cwd().createFile(path, .{});
                    defer file.close();

                    const buf = try self.allocator.alloc(u8, 4096);
                    defer self.allocator.free(buf);
                    try self.writeJson(file.writer(buf), result);
                }
            }

            // Compare with baseline for critical benchmarks
            if (bench.critical) {
                const baseline_filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{bench.name});
                defer self.allocator.free(baseline_filename);
                const baseline_path = try std.fs.path.join(self.allocator, &.{ args.baseline_dir.?, baseline_filename });
                defer self.allocator.free(baseline_path);

                // Check if baseline exists
                if (std.fs.cwd().openFile(baseline_path, .{})) |baseline_file| {
                    baseline_file.close();

                    // Aggregate results for comparison
                    var results_data = std.ArrayListUnmanaged(types.Results){};
                    defer results_data.deinit(self.allocator);
                    for (results) |result| {
                        try results_data.append(self.allocator, result.results);
                    }
                    const aggregated_results = try self.aggregateResults(self.allocator, results_data.items);
                    const aggregated_result = types.BenchmarkResult{
                        .bench_name = bench.name,
                        .profile = try self.detectProfile(),
                        .build = try self.detectBuild(),
                        .config = args.config,
                        .results = aggregated_results,
                        .repeat_index = 0,
                        .repeat_count = args.repeats,
                        .timestamp_utc = try self.getTimestamp(),
                        .git = try self.detectGit(),
                    };

                    // Write candidate to temp file for comparison
                    const tmp_buf = try self.allocator.alloc(u8, 4096);
                    defer self.allocator.free(tmp_buf);
                    var fbs = std.io.fixedBufferStream(tmp_buf);
                    try self.writeJson(fbs.writer(), aggregated_result);

                    const tmp_path = try std.fs.path.join(self.allocator, &.{ "candidate.tmp.json" });
                    defer self.allocator.free(tmp_path);
                    {
                        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
                        defer tmp_file.close();
                        try tmp_file.writeAll(fbs.getWritten());
                    }

                    const comparison = try comparator.compare(baseline_path, tmp_path);
                    _ = std.fs.cwd().deleteFile(tmp_path) catch {};

                    if (!comparison.passed) {
                        failed_critical += 1;
                        const writer = failure_notes.writer(self.allocator);
                        try writer.print("- {s}: FAILED (throughput {d}%, p99 {d}%, fsync/op {d}%)\n", .{
                            bench.name,
                            comparison.throughput_change_pct,
                            comparison.p99_latency_change_pct,
                            comparison.fsync_change_pct,
                        });
                        if (comparison.notes.len > 0) {
                            try writer.print("  {s}\n", .{comparison.notes});
                        }
                    } else {
                        std.debug.print("  ✅ PASSED (throughput {d}%, p99 {d}%)\n", .{
                            comparison.throughput_change_pct,
                            comparison.p99_latency_change_pct,
                        });
                    }
                } else |err| switch (err) {
                    error.FileNotFound => {
                        failed_critical += 1;
                        const writer = failure_notes.writer(self.allocator);
                        try writer.print("- {s}: FAILED (baseline file not found)\n", .{bench.name});
                    },
                    else => {
                        failed_critical += 1;
                        const writer = failure_notes.writer(self.allocator);
                        try writer.print("- {s}: FAILED (baseline error: {})\n", .{ bench.name, err });
                    },
                }
            }
        }

        const passed = failed_critical == 0;
        return GateResult{
            .passed = passed,
            .total_critical = total_critical,
            .failed_critical = failed_critical,
            .failure_notes = try failure_notes.toOwnedSlice(self.allocator),
        };
    }

    fn runSinglePerRepeat(self: *Runner, bench: Benchmark, args: RunArgs) ![]types.BenchmarkResult {
        var results = std.ArrayListUnmanaged(types.BenchmarkResult){};
        defer results.deinit(self.allocator);

        // Prepare config
        var config = args.config;
        if (args.seed) |seed| config.seed = seed;

        // Run repeats
        for (0..args.repeats) |i| {
            // Perform warmup if specified
            if (config.warmup_ops > 0) {
                _ = bench.run_fn(self.allocator, config) catch |err| {
                    std.log.warn("Warmup failed for benchmark {s}: {}", .{ bench.name, err });
                    // Continue with measurement even if warmup fails
                };
            } else if (config.warmup_ns > 0) {
                // Time-based warmup: run until specified time elapsed
                const warmup_start = std.time.nanoTimestamp();
                while (std.time.nanoTimestamp() - warmup_start < @as(i64, @intCast(config.warmup_ns))) {
                    _ = bench.run_fn(self.allocator, config) catch |err| {
                        std.log.warn("Time-based warmup iteration failed for benchmark {s}: {}", .{ bench.name, err });
                        break; // Exit warmup loop on failure
                    };
                }
            }

            // Actual measurement
            const result = try bench.run_fn(self.allocator, config);

            const bench_result = types.BenchmarkResult{
                .bench_name = bench.name,
                .profile = try self.detectProfile(),
                .build = try self.detectBuild(),
                .config = config,
                .results = result,
                .repeat_index = @intCast(i),
                .repeat_count = args.repeats,
                .timestamp_utc = try self.getTimestamp(),
                .git = try self.detectGit(),
            };

            try results.append(self.allocator, bench_result);

            if (i < args.repeats - 1) {
                std.Thread.sleep(100 * std.time.ns_per_ms); // Brief pause
            }
        }

        return try results.toOwnedSlice(self.allocator);
    }

    fn runSingle(self: *Runner, bench: Benchmark, args: RunArgs) !types.BenchmarkResult {
        var results = std.ArrayListUnmanaged(types.Results){};
        defer results.deinit(self.allocator);

        // Prepare config
        var config = args.config;
        if (args.seed) |seed| config.seed = seed;

        // Run repeats
        for (0..args.repeats) |i| {
            const result = try bench.run_fn(self.allocator, config);
            try results.append(self.allocator, result);

            if (i < args.repeats - 1) {
                std.Thread.sleep(100 * std.time.ns_per_ms); // Brief pause
            }
        }

        // Aggregate results
        const aggregated = try self.aggregateResults(self.allocator, results.items);

        return types.BenchmarkResult{
            .bench_name = bench.name,
            .profile = try self.detectProfile(),
            .build = try self.detectBuild(),
            .config = config,
            .results = aggregated,
            .repeat_index = 0,
            .repeat_count = args.repeats,
            .timestamp_utc = try self.getTimestamp(),
            .git = try self.detectGit(),
        };
    }

    fn aggregateResults(self: *Runner, allocator: std.mem.Allocator, results: []const types.Results) !types.Results {

        var total_ops: u64 = 0;
        var total_duration: u64 = 0;
        var total_bytes_read: u64 = 0;
        var total_bytes_write: u64 = 0;
        var total_fsync: u64 = 0;
        var total_alloc_count: u64 = 0;
        var total_alloc_bytes: u64 = 0;
        var total_errors: u64 = 0;

        // Collect latency values for percentiles
        var latencies = std.ArrayListUnmanaged(u64){};
        defer latencies.deinit(allocator);

        // Collect ops_per_sec values for CV calculation
        var ops_per_sec_values = std.ArrayListUnmanaged(f64){};
        defer ops_per_sec_values.deinit(allocator);

        for (results) |result| {
            total_ops += result.ops_total;
            total_duration += result.duration_ns;
            total_bytes_read += result.bytes.read_total;
            total_bytes_write += result.bytes.write_total;
            total_fsync += result.io.fsync_count;
            total_alloc_count += result.alloc.alloc_count;
            total_alloc_bytes += result.alloc.alloc_bytes;
            total_errors += result.errors_total;

            try latencies.append(allocator, result.latency_ns.p99); // Use p99 for comparison
            try ops_per_sec_values.append(allocator, result.ops_per_sec);
        }

        // Sort latencies for percentile calculation
        std.mem.sort(u64, latencies.items, {}, comptime std.sort.asc(u64));

        const p50_idx = latencies.items.len / 2;
        const p95_idx = latencies.items.len * 95 / 100;
        const p99_idx = latencies.items.len * 99 / 100;

        // Calculate coefficient of variation for throughput (ops_per_sec)
        const stability = self.calculateStability(allocator, ops_per_sec_values.items);

        return types.Results{
            .ops_total = total_ops,
            .duration_ns = total_duration,
            .ops_per_sec = @as(f64, @floatFromInt(total_ops)) / @as(f64, @floatFromInt(total_duration)) * std.time.ns_per_s,
            .latency_ns = .{
                .p50 = if (p50_idx < latencies.items.len) latencies.items[p50_idx] else 0,
                .p95 = if (p95_idx < latencies.items.len) latencies.items[p95_idx] else 0,
                .p99 = if (p99_idx < latencies.items.len) latencies.items[p99_idx] else 0,
                .max = if (latencies.items.len > 0) latencies.items[latencies.items.len - 1] else 0,
            },
            .bytes = .{
                .read_total = total_bytes_read,
                .write_total = total_bytes_write,
            },
            .io = .{
                .fsync_count = total_fsync,
            },
            .alloc = .{
                .alloc_count = total_alloc_count,
                .alloc_bytes = total_alloc_bytes,
            },
            .errors_total = total_errors,
            .stability = stability,
        };
    }

    fn calculateStability(self: *Runner, allocator: std.mem.Allocator, values: []const f64) ?types.Stability {
        _ = allocator;
        _ = self;

        if (values.len < 2) return null;

        // Calculate mean
        var sum: f64 = 0.0;
        for (values) |v| {
            sum += v;
        }
        const mean = sum / @as(f64, @floatFromInt(values.len));

        // Calculate standard deviation
        var variance_sum: f64 = 0.0;
        for (values) |v| {
            const diff = v - mean;
            variance_sum += diff * diff;
        }
        const variance = variance_sum / @as(f64, @floatFromInt(values.len));
        const std_dev = @sqrt(variance);

        // Coefficient of variation (CV = std_dev / mean)
        const cv = if (mean > 0) std_dev / mean else 0.0;

        // Stability threshold: CV < 0.05 (5%) is considered stable
        const threshold = 0.05;
        const is_stable = cv < threshold;

        return types.Stability{
            .coefficient_of_variation = cv,
            .is_stable = is_stable,
            .repeat_count = @intCast(values.len),
            .threshold_used = threshold,
        };
    }

    fn filterBenchmarks(self: *Runner, filter: ?[]const u8, suite: ?[]const u8) ![]Benchmark {
        var list = std.ArrayListUnmanaged(Benchmark){};

        for (self.benchmarks.items) |bench| {
            if (suite) |s| {
                const desired = std.meta.stringToEnum(Suite, s) orelse null;
                if (desired) |d| {
                    if (bench.suite != d) continue;
                }
            }

            if (filter) |pat| {
                if (!std.mem.containsAtLeast(u8, bench.name, 1, pat)) continue;
            }

            try list.append(self.allocator, bench);
        }

        return try list.toOwnedSlice(self.allocator);
    }

    fn detectProfile(self: *Runner) !types.Profile {
        // Use cached profile if available
        if (self.cached_profile) |profile| {
            return profile;
        }

        // Detect system info and cache the result
        const sys_info = try system_info.detectSystemInfo(self.allocator);

        // Store cleanup info
        self.profile_cleanup = sys_info;

        // Determine profile based on hardware capabilities
        const profile_name = determineProfile(sys_info);

        // Create and cache the profile
        const profile = types.Profile{
            .name = profile_name,
            .cpu_model = sys_info.cpu_model,
            .core_count = sys_info.core_count,
            .ram_gb = sys_info.ram_gb,
            .os = sys_info.os_name,
            .fs = sys_info.fs_type,
        };

        self.cached_profile = profile;
        return profile;
    }

    /// Determine profile based on system capabilities according to spec/machine_specs_v0.md
    fn determineProfile(sys_info: system_info.SystemInfo) types.ProfileName {
        // Check for dev_nvme profile requirements
        if (sys_info.core_count >= 8 and sys_info.ram_gb >= 16.0) {
            // Additional heuristics for NVMe detection
            if (isHighPerformanceStorage(sys_info.fs_type)) {
                return .dev_nvme;
            }
        }

        // Default to CI profile
        return .ci;
    }

    /// Heuristic detection of high-performance storage
    fn isHighPerformanceStorage(fs_type: ?[]const u8) bool {
        if (fs_type) |fs| {
            // Check for common indicators of high-performance storage
            if (std.mem.indexOf(u8, fs, "ext4") != null or
                std.mem.indexOf(u8, fs, "xfs") != null) {
                return true;
            }
        }
        return false;
    }

    fn detectBuild(self: *Runner) !types.Build {
        _ = self;
        return .{
            .zig_version = @import("builtin").zig_version_string,
            .mode = if (@import("builtin").mode == .Debug) .Debug
                   else if (@import("builtin").mode == .ReleaseSafe) .ReleaseSafe
                   else if (@import("builtin").mode == .ReleaseFast) .ReleaseFast
                   else .ReleaseSmall,
        };
    }

    fn detectGit(self: *Runner) !types.Git {
        var sha_buf: [64]u8 = undefined;
        var branch_buf: [128]u8 = undefined;

        const sha = self.runCmd(&sha_buf, &.{ "git", "rev-parse", "--short", "HEAD" }) orelse "unknown";
        const branch = self.runCmd(&branch_buf, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse "unknown";

        // Make copies of the strings that will outlive the buffer
        const sha_copy = try self.allocator.dupeZ(u8, sha);
        const branch_copy = try self.allocator.dupeZ(u8, branch);

        return .{
            .sha = sha_copy,
            .branch = branch_copy,
            .dirty = null,
        };
    }

    fn runCmd(self: *Runner, buf: []u8, argv: []const []const u8) ?[]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
        }) catch return null;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
        if (trimmed.len == 0) return null;

        // Copy to the provided buffer to ensure null-termination
        if (trimmed.len < buf.len) {
            @memcpy(buf[0..trimmed.len], trimmed);
            buf[trimmed.len] = 0;
            return buf[0..trimmed.len];
        }

        return null;
    }

    fn getTimestamp(self: *Runner) ![]const u8 {
        const ts = std.time.timestamp();
        const timestamp_str = try self.allocator.alloc(u8, 32);
        const len = try std.fmt.bufPrint(timestamp_str, "{d}", .{ts});
        return timestamp_str[0..len.len];
    }

    fn writeJson(self: *Runner, writer: anytype, result: types.BenchmarkResult) !void {
        // Validate against schema before writing
        try self.validateResult(result);

        // Serialize to JSON
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
        defer self.allocator.free(json_str);

        // For file writers, access the underlying file directly
        if (@TypeOf(writer) == std.fs.File.Writer) {
            try writer.file.writeAll(json_str);
        } else {
            // For other writers (like FixedBufferStream), use the standard interface
            try writer.writeAll(json_str);
        }
    }

    fn validateResult(self: *Runner, result: types.BenchmarkResult) !void {
        // Basic validation by attempting to parse a generated JSON string
        // This provides schema validation by leveraging Zig's type system
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
        defer self.allocator.free(json_str);

        // Parse back to validate structure matches types
        const parsed = try std.json.parseFromSliceLeaky(types.BenchmarkResult, self.allocator, json_str, .{});

        // Additional explicit validation checks
        try self.validateRequiredFields(result);
        try self.validateValueRanges(result);

        // Schema-aware validation using the JSON schema file
        try self.validateAgainstSchema(json_str);

        _ = parsed; // Suppress unused variable warning
    }

    fn validateAgainstSchema(self: *Runner, json_str: []const u8) !void {
        // For now, we implement basic schema validation manually
        // In a full implementation, we would parse and validate against bench/results.schema.json

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, json_str, .{});
        const obj = parsed.object;

        // Check required top-level fields
        const required_fields = [_][]const u8{
            "bench_name", "profile", "build", "config", "results",
            "repeat_index", "repeat_count", "timestamp_utc", "git"
        };

        for (required_fields) |field| {
            if (!obj.contains(field)) {
                return error.MissingRequiredField;
            }
        }

        // Validate bench_name is non-empty string
        if (obj.get("bench_name").?.string.len == 0) {
            return error.EmptyBenchName;
        }

        // Validate repeat_index and repeat_count
        const repeat_index = obj.get("repeat_index").?.integer;
        const repeat_count = obj.get("repeat_count").?.integer;
        if (repeat_index < 0 or repeat_count <= 0 or repeat_index >= repeat_count) {
            return error.InvalidRepeatRange;
        }

        // Validate results object structure
        const results_obj = obj.get("results").?.object;
        const required_result_fields = [_][]const u8{
            "ops_total", "duration_ns", "ops_per_sec", "latency_ns",
            "bytes", "io", "alloc", "errors_total"
        };

        for (required_result_fields) |field| {
            if (!results_obj.contains(field)) {
                return error.MissingRequiredResultField;
            }
        }

        // Validate numeric ranges
        const ops_total = results_obj.get("ops_total").?.integer;
        const duration_ns = results_obj.get("duration_ns").?.integer;
        const ops_per_sec_val = results_obj.get("ops_per_sec").?;
        const ops_per_sec = switch (ops_per_sec_val) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => return error.InvalidOpsPerSec,
        };

        if (ops_total <= 0) return error.InvalidOpsTotal;
        if (duration_ns <= 0) return error.InvalidDuration;
        if (ops_per_sec <= 0) return error.InvalidOpsPerSec;

        // Validate latency structure
        const latency_obj = results_obj.get("latency_ns").?.object;
        const latency_fields = [_][]const u8{"p50", "p95", "p99", "max"};
        for (latency_fields) |field| {
            if (!latency_obj.contains(field)) {
                return error.MissingLatencyField;
            }
            if (latency_obj.get(field).?.integer <= 0) {
                return error.InvalidLatencyValue;
            }
        }
    }

    fn validateRequiredFields(self: *Runner, result: types.BenchmarkResult) !void {
        _ = self;

        // Check required string fields are not empty
        if (result.bench_name.len == 0) return error.EmptyBenchName;
        if (result.timestamp_utc.len == 0) return error.EmptyTimestamp;
        if (result.git.sha.len < 7) return error.InvalidGitSha;

        // Check required numeric ranges
        if (result.repeat_index >= result.repeat_count) return error.InvalidRepeatIndex;
        if (result.results.ops_total == 0) return error.ZeroOpsTotal;
        if (result.results.duration_ns == 0) return error.ZeroDuration;
        if (result.results.ops_per_sec <= 0) return error.InvalidOpsPerSec;
    }

    fn validateValueRanges(self: *Runner, result: types.BenchmarkResult) !void {
        _ = self;

        // Profile validation
        if (result.profile.core_count == 0) return error.InvalidCoreCount;
        if (result.profile.ram_gb < 0.5) return error.InvalidRamGb;

        // Config validation
        if (result.config.measure_ops == 0) return error.InvalidMeasureOps;
        if (result.config.threads == 0) return error.InvalidThreadCount;

        // Db config validation
        const valid_page_sizes = [_]u32{4096, 8192, 16384, 32768};
        var valid_page_size = false;
        for (valid_page_sizes) |size| {
            if (result.config.db.page_size == size) {
                valid_page_size = true;
                break;
            }
        }
        if (!valid_page_size) return error.InvalidPageSize;

        // Results validation
        const latency = result.results.latency_ns;
        if (latency.p50 == 0 or latency.p95 == 0 or latency.p99 == 0 or latency.max == 0) {
            return error.InvalidLatencyValues;
        }

        // Check monotonicity of latency values
        if (latency.p50 > latency.p95 or latency.p95 > latency.p99 or latency.p99 > latency.max) {
            return error.InvalidLatencyOrdering;
        }

        // IO validation - fsync_count can be 0 for read-only or open/close benchmarks
        // fsync_count validation is context-dependent - some benchmarks legitimately have 0 fsyncs

        // Alloc validation
        const alloc = result.results.alloc;
        if (alloc.alloc_count == 0 or alloc.alloc_bytes == 0) return error.InvalidAllocValues;

        // Bytes validation - can be 0 for open/close or metadata-only benchmarks
        // Byte activity validation is context-dependent - some benchmarks legitimately have 0 I/O
    }

    fn compareWithBaseline(self: *Runner, result: types.BenchmarkResult, baseline_path: []const u8) ![]const u8 {
        const tmp_buf = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(tmp_buf);
        var fbs = std.io.fixedBufferStream(tmp_buf);
        try self.writeJson(fbs.writer(), result);

        // Write candidate to temp file to reuse comparator loader
        const tmp_path = try std.fs.path.join(self.allocator, &.{ "candidate.tmp.json" });
        defer self.allocator.free(tmp_path);
        {
            const file = try std.fs.cwd().createFile(tmp_path, .{});
            defer file.close();
            try file.writeAll(fbs.getWritten());
        }

        var comparator = @import("compare.zig").Comparator.init(self.allocator, .{});
        const comp = try comparator.compare(baseline_path, tmp_path);
        // cleanup temp file best-effort
        _ = std.fs.cwd().deleteFile(tmp_path) catch {};
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);
        try w.print(
            "Throughput {d}%, P99 {d}%, Fsync/op {d}%", .{
                comp.throughput_change_pct,
                comp.p99_latency_change_pct,
                comp.fsync_change_pct,
            },
        );
        if (!comp.passed) try w.writeAll(" (FAILED)");
        return try buf.toOwnedSlice(self.allocator);
    }
};

pub const RunArgs = struct {
    repeats: u32 = 5,
    filter: ?[]const u8 = null,
    suite: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    baseline_dir: ?[]const u8 = null,
    seed: ?u32 = null,
    // CI thresholds for regression detection
    max_throughput_regression_pct: f64 = 5.0,
    max_p99_latency_regression_pct: f64 = 10.0,
    max_alloc_regression_pct: f64 = 5.0,
    max_fsync_increase_pct: f64 = 0.0,
    config: types.Config = .{
        .db = .{
            .page_size = 16384,
        },
    },
};
