const std = @import("std");
const types = @import("types.zig");

pub const ComparisonResult = struct {
    passed: bool,
    throughput_change_pct: f64,
    p99_latency_change_pct: f64,
    alloc_change_pct: ?f64,
    fsync_change_pct: f64,
    stability: bool,
    notes: []const u8,
};

pub const Comparator = struct {
    allocator: std.mem.Allocator,
    thresholds: Thresholds,

    pub const Thresholds = struct {
        max_throughput_regression_pct: f64 = 5.0,
        max_p99_latency_regression_pct: f64 = 10.0,
        max_alloc_regression_pct: f64 = 5.0,
        max_fsync_increase_pct: f64 = 0.0,
        max_variance_cv: f64 = 0.1, // Coefficient of variation
    };

    pub fn init(allocator: std.mem.Allocator, thresholds: Thresholds) Comparator {
        return .{
            .allocator = allocator,
            .thresholds = thresholds,
        };
    }

    pub fn compare(self: *Comparator, baseline_path: []const u8, candidate_path: []const u8) !ComparisonResult {
        const baseline = try self.loadResult(baseline_path);
        defer self.allocator.free(baseline);

        const candidate = try self.loadResult(candidate_path);
        defer self.allocator.free(candidate);

        const baseline_parsed = try std.json.parseFromSliceLeaky(types.BenchmarkResult, self.allocator, baseline, .{});
        const candidate_parsed = try std.json.parseFromSliceLeaky(types.BenchmarkResult, self.allocator, candidate, .{});

        return self.compareResults(baseline_parsed, candidate_parsed);
    }

    pub fn compareResults(self: *Comparator, baseline: types.BenchmarkResult, candidate: types.BenchmarkResult) !ComparisonResult {
        // Calculate percentage changes
        const throughput_change = pctChange(
            baseline.results.ops_per_sec,
            candidate.results.ops_per_sec,
        );

        const p99_latency_change = pctChange(
            @as(f64, @floatFromInt(baseline.results.latency_ns.p99)),
            @as(f64, @floatFromInt(candidate.results.latency_ns.p99)),
        );

        const alloc_change = if (baseline.results.alloc.alloc_count > 0)
            pctChange(
                @as(f64, @floatFromInt(baseline.results.alloc.alloc_count)),
                @as(f64, @floatFromInt(candidate.results.alloc.alloc_count)),
            )
        else
            null;

        const baseline_fsync_per_op = @as(f64, @floatFromInt(baseline.results.io.fsync_count)) / @as(f64, @floatFromInt(baseline.results.ops_total));
        const candidate_fsync_per_op = @as(f64, @floatFromInt(candidate.results.io.fsync_count)) / @as(f64, @floatFromInt(candidate.results.ops_total));
        const fsync_change = pctChange(baseline_fsync_per_op, candidate_fsync_per_op);

        // Check thresholds
        const passed =
            throughput_change >= -self.thresholds.max_throughput_regression_pct and
            p99_latency_change <= self.thresholds.max_p99_latency_regression_pct and
            (alloc_change == null or alloc_change.? >= -self.thresholds.max_alloc_regression_pct) and
            fsync_change <= self.thresholds.max_fsync_increase_pct;

        // Check stability (coefficient of variation)
        const stability = try self.checkStability(candidate);

        var notes_buf = std.ArrayListUnmanaged(u8){};
        defer notes_buf.deinit(self.allocator);

        const writer = notes_buf.writer(self.allocator);

        if (throughput_change < 0) {
            try writer.print("Throughput down {d}%\n", .{throughput_change});
        } else {
            try writer.print("Throughput up {d}%\n", .{throughput_change});
        }

        if (p99_latency_change > 0) {
            try writer.print("P99 latency up {d}%\n", .{p99_latency_change});
        } else {
            try writer.print("P99 latency down {d}%\n", .{-p99_latency_change});
        }

        if (fsync_change > 0) {
            try writer.print("Fsync/op up {d}%\n", .{fsync_change});
        }

        if (!stability) {
            try writer.writeAll("WARNING: Results unstable (high variance)\n");
        }

        return ComparisonResult{
            .passed = passed,
            .throughput_change_pct = throughput_change,
            .p99_latency_change_pct = p99_latency_change,
            .alloc_change_pct = alloc_change,
            .fsync_change_pct = fsync_change,
            .stability = stability,
            .notes = try notes_buf.toOwnedSlice(self.allocator),
        };
    }

    fn loadResult(self: *Comparator, path: []const u8) ![]const u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const contents = try self.allocator.alloc(u8, stat.size);
        const bytes_read = try file.readAll(contents);
        if (bytes_read != stat.size) {
            return error.EndOfFile;
        }

        return contents;
    }

    fn checkStability(self: *Comparator, result: types.BenchmarkResult) !bool {
        _ = self;
        _ = result;
        // TODO: Implement stability check based on repeat_count
        // For now, assume stable
        return true;
    }

    pub fn generateReport(self: *Comparator, comparisons: []ComparisonResult, writer: anytype) !void {
        _ = self;

        var passed: usize = 0;
        var failed: usize = 0;

        try writer.writeAll("# Benchmark Comparison Report\n\n");

        for (comparisons) |comp| {
            if (comp.passed) {
                passed += 1;
                try writer.writeAll("✅ ");
            } else {
                failed += 1;
                try writer.writeAll("❌ ");
            }

            try writer.print("Throughput: {d}%, P99 Latency: {d}%",
                .{ comp.throughput_change_pct, comp.p99_latency_change_pct });

            if (comp.alloc_change_pct) |alloc_change| {
                try writer.print(", Alloc: {d}%", .{alloc_change});
            }

            try writer.print(", Fsync/op: {d}%\n", .{comp.fsync_change_pct});

            if (comp.notes.len > 0) {
                try writer.print("   {s}\n", .{comp.notes});
            }
        }

        try writer.print("\nSummary: {d} passed, {d} failed\n", .{ passed, failed });
    }
};

fn pctChange(baseline: f64, candidate: f64) f64 {
    if (baseline == 0) {
        return if (candidate == 0) 0 else 100;
    }
    return ((candidate - baseline) / baseline) * 100.0;
}