const std = @import("std");
const types = @import("types.zig");

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

    pub fn init(allocator: std.mem.Allocator) Runner {
        return .{
            .allocator = allocator,
            .benchmarks = .{},
        };
    }

    pub fn deinit(self: *Runner) void {
        self.benchmarks.deinit(self.allocator);
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

            const result = try self.runSingle(bench, args);

            // Output JSON
            if (args.output_dir) |dir| {
                const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{bench.name});
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

                // Compare with baseline if provided
                if (args.baseline_dir) |baseline_dir| {
                    const baseline_filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{bench.name});
                defer self.allocator.free(baseline_filename);
                const baseline_path = try std.fs.path.join(self.allocator, &.{ baseline_dir, baseline_filename });
                    defer self.allocator.free(baseline_path);

                    if (self.compareWithBaseline(result, baseline_path)) |comparison| {
                        std.debug.print("  Comparison: {s}\n", .{comparison});
                    } else |err| {
                        std.debug.print("  Baseline comparison failed: {}\n", .{err});
                    }
                }
            } else {
                const buf = try self.allocator.alloc(u8, 4096);
                defer self.allocator.free(buf);
                var fbs = std.io.fixedBufferStream(buf);
                try self.writeJson(fbs.writer(), result);
                std.debug.print("{s}\n", .{fbs.getWritten()});
            }
        }
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
        _ = self;

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
        }

        // Sort latencies for percentile calculation
        std.mem.sort(u64, latencies.items, {}, comptime std.sort.asc(u64));

        const p50_idx = latencies.items.len / 2;
        const p95_idx = latencies.items.len * 95 / 100;
        const p99_idx = latencies.items.len * 99 / 100;

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
        _ = self;
        const cpu_count = @as(u32, @intCast(try std.Thread.getCpuCount()));
        const os_name = @tagName(@import("builtin").os.tag);
        const fs_name: []const u8 = "unknown";

        var ram_gb: f64 = 0;
        // Best-effort /proc/meminfo parse
        if (std.fs.cwd().openFile("/proc/meminfo", .{})) |file| {
            defer file.close();
            var buf: [4096]u8 = undefined;
            const n = try file.readAll(&buf);
            if (std.mem.indexOf(u8, buf[0..n], "MemTotal:")) |idx| {
                var it = std.mem.tokenizeAny(u8, buf[idx..n], " \\t");
                _ = it.next();
                if (it.next()) |val_str| {
                    if (std.fmt.parseInt(u64, val_str, 10)) |kb| {
                        ram_gb = @as(f64, @floatFromInt(kb)) / (1024.0 * 1024.0);
                    } else |_| {}
                }
            }
        } else |_| {}

        return .{
            .name = .ci,
            .cpu_model = null,
            .core_count = cpu_count,
            .ram_gb = ram_gb,
            .os = os_name,
            .fs = fs_name,
        };
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
        const branch = self.runCmd(&branch_buf, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });

        return .{
            .sha = sha,
            .branch = branch,
            .dirty = null,
        };
    }

    fn runCmd(self: *Runner, buf: []u8, argv: []const []const u8) ?[]const u8 {
        _ = buf;
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
        }) catch return null;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
        return if (trimmed.len == 0) null else trimmed;
    }

    fn getTimestamp(self: *Runner) ![]const u8 {
        const ts = std.time.timestamp();
        const iso_buf = try self.allocator.alloc(u8, 32);
        const len = try std.fmt.bufPrint(iso_buf, "{d}", .{ts});
        return iso_buf[0..len.len];
    }

    fn writeJson(self: *Runner, writer: anytype, result: types.BenchmarkResult) !void {
        _ = self;
        _ = writer;
        _ = result; // TODO: implement JSON output
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
    config: types.Config = .{
        .db = .{
            .page_size = 16384,
        },
    },
};
