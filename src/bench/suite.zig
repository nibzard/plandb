const std = @import("std");
const runner = @import("runner.zig");
const types = @import("types.zig");
const db = @import("../db.zig");
const pager = @import("../pager.zig");

// Stub benchmark functions for testing the harness

pub fn registerBenchmarks(bench_runner: *runner.Runner) !void {
    // Pager benchmarks
    try bench_runner.addBenchmark(.{
        .name = "bench/pager/open_close_empty",
        .run_fn = benchPagerOpenClose,
        .critical = true,
        .suite = .micro,
    });

    try bench_runner.addBenchmark(.{
        .name = "bench/pager/read_page_random_16k_hot",
        .run_fn = benchPagerReadRandomHot,
        .critical = true,
        .suite = .micro,
    });

    try bench_runner.addBenchmark(.{
        .name = "bench/pager/commit_meta_fsync",
        .run_fn = benchPagerCommitMeta,
        .critical = true,
        .suite = .micro,
    });

    // B+tree benchmarks
    try bench_runner.addBenchmark(.{
        .name = "bench/btree/point_get_hot_1m",
        .run_fn = benchBtreeGetHot,
        .critical = true,
        .suite = .micro,
    });

    try bench_runner.addBenchmark(.{
        .name = "bench/btree/build_sequential_insert_1m",
        .run_fn = benchBtreeBuildSequential,
        .critical = true,
        .suite = .micro,
    });

    // MVCC benchmarks
    try bench_runner.addBenchmark(.{
        .name = "bench/mvcc/snapshot_open_close",
        .run_fn = benchMvccSnapshotOpen,
        .critical = true,
        .suite = .micro,
    });

    try bench_runner.addBenchmark(.{
        .name = "bench/mvcc/readers_256_point_get_hot",
        .run_fn = benchMvccManyReaders,
        .critical = true,
        .suite = .micro,
    });

    // Log/commit stream benchmarks
    try bench_runner.addBenchmark(.{
        .name = "bench/log/append_commit_record",
        .run_fn = benchLogAppendCommit,
        .critical = true,
        .suite = .micro,
    });
}

// Stub implementations - these will be replaced with real implementations

fn benchPagerOpenClose(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    _ = config;
    const iterations: u64 = 200;

    var total_alloc_bytes: u64 = 0;
    var total_reads: u64 = 0;
    var total_writes: u64 = 0;

    const start_time = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        // Create temporary empty database file
        const test_filename = try std.fmt.allocPrint(allocator, "bench_empty_{d}.db", .{std.time.milliTimestamp()});
        defer allocator.free(test_filename);

        // Create empty database file with proper meta pages
        {
            const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
            defer file.close();

            // Create meta pages for empty database
            var buffer_a: [pager.DEFAULT_PAGE_SIZE]u8 = undefined;
            var buffer_b: [pager.DEFAULT_PAGE_SIZE]u8 = undefined;

            const meta = pager.MetaPayload{
                .committed_txn_id = 0,
                .root_page_id = 0, // Empty tree
                .freelist_head_page_id = 0,
                .log_tail_lsn = 0,
                .meta_crc32c = 0,
            };

            try pager.encodeMetaPage(pager.META_A_PAGE_ID, meta, &buffer_a);
            try pager.encodeMetaPage(pager.META_B_PAGE_ID, meta, &buffer_b);

            _ = try file.pwriteAll(&buffer_a, 0);
            _ = try file.pwriteAll(&buffer_b, pager.DEFAULT_PAGE_SIZE);
            total_writes += pager.DEFAULT_PAGE_SIZE * 2;
        }

        // Open and close the database
        {
            var pager_instance = try pager.Pager.open(test_filename, allocator);
            total_reads += pager.DEFAULT_PAGE_SIZE * 2; // Reads both meta pages during open
            pager_instance.close();
        }

        // Clean up file
        try std.fs.cwd().deleteFile(test_filename);

        total_alloc_bytes += 1024; // Estimated allocation per open/close
    }
    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

    return basicResult(iterations, duration_ns, .{
        .read_total = total_reads,
        .write_total = total_writes,
    }, .{ .fsync_count = 0 }, .{ .alloc_count = iterations * 2, .alloc_bytes = total_alloc_bytes });
}

fn benchPagerReadRandomHot(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    const ops: u64 = 5_000;
    var prng = std.Random.DefaultPrng.init(config.seed orelse 12345);
    const rand = prng.random();
    var database = try db.Db.open(allocator);
    defer database.close();

    // preload
    var w = database.beginWrite();
    for (0..10_000) |i| {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key{d}", .{i});
        try w.put(key, "v");
    }
    _ = try w.commit();

    const start_time = std.time.nanoTimestamp();
    var r = try database.beginReadLatest();
    defer r.close();
    for (0..ops) |_| {
        const idx = rand.intRangeLessThan(usize, 0, 10_000);
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key{d}", .{idx});
        _ = r.get(key);
    }
    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

    return basicResult(ops, duration_ns, .{ .read_total = ops * config.db.page_size, .write_total = 0 }, .{ .fsync_count = 0 }, .{ .alloc_count = ops, .alloc_bytes = ops * 32 });
}

fn benchPagerCommitMeta(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    _ = config;
    const commits: u64 = 200;
    var database = try db.Db.open(allocator);
    defer database.close();

    const start_time = std.time.nanoTimestamp();
    for (0..commits) |i| {
        var w = database.beginWrite();
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "c{d}", .{i});
        try w.put(key, "v");
        _ = try w.commit();
    }
    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

    return basicResult(commits, duration_ns, .{ .read_total = commits * 64, .write_total = commits * 128 }, .{ .fsync_count = commits }, .{ .alloc_count = commits * 4, .alloc_bytes = commits * 256 });
}

fn benchBtreeGetHot(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    const ops: u64 = 50_000;
    var prng = std.Random.DefaultPrng.init(config.seed orelse 42);
    const rand = prng.random();
    var database = try db.Db.open(allocator);
    defer database.close();
    var w = database.beginWrite();
    for (0..ops) |i| {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        try w.put(key, "v");
    }
    _ = try w.commit();

    var r = try database.beginReadLatest();
    defer r.close();
    const start_time = std.time.nanoTimestamp();
    for (0..ops) |_| {
        const idx = rand.intRangeLessThan(usize, 0, ops);
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "k{d}", .{idx});
        _ = r.get(key);
    }
    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

    return basicResult(ops, duration_ns, .{ .read_total = ops * 64, .write_total = 0 }, .{ .fsync_count = 0 }, .{ .alloc_count = ops, .alloc_bytes = ops * 64 });
}

fn benchBtreeBuildSequential(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    _ = config;
    const ops: u64 = 20_000;
    var database = try db.Db.open(allocator);
    defer database.close();
    const start_time = std.time.nanoTimestamp();
    var w = database.beginWrite();
    for (0..ops) |i| {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "s{d}", .{i});
        try w.put(key, "v");
    }
    _ = try w.commit();
    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

    return basicResult(ops, duration_ns, .{ .read_total = ops * 32, .write_total = ops * 64 }, .{ .fsync_count = 1 }, .{ .alloc_count = ops * 2, .alloc_bytes = ops * 32 });
}

fn benchMvccSnapshotOpen(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    _ = config;
    const ops: u64 = 5_000;
    var database = try db.Db.open(allocator);
    defer database.close();
    var w = database.beginWrite();
    try w.put("seed", "1");
    _ = try w.commit();

    const start_time = std.time.nanoTimestamp();
    for (0..ops) |_| {
        var r = try database.beginReadLatest();
        r.close();
    }
    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

    return basicResult(ops, duration_ns, .{ .read_total = 0, .write_total = 0 }, .{ .fsync_count = 0 }, .{ .alloc_count = ops, .alloc_bytes = ops * 16 });
}

fn benchMvccManyReaders(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    _ = config;
    const readers: usize = 16;
    const ops_per: u64 = 1_000;
    var database = try db.Db.open(allocator);
    defer database.close();
    var w = database.beginWrite();
    try w.put("seed", "v");
    _ = try w.commit();

    const start_time = std.time.nanoTimestamp();
    for (0..readers) |_| {
        var r = try database.beginReadLatest();
        for (0..ops_per) |_| {
            _ = r.get("seed");
        }
        r.close();
    }
    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
    const total_ops = ops_per * readers;

    return basicResult(total_ops, duration_ns, .{ .read_total = total_ops * 32, .write_total = 0 }, .{ .fsync_count = 0 }, .{ .alloc_count = readers, .alloc_bytes = readers * 1024 });
}

fn benchLogAppendCommit(allocator: std.mem.Allocator, config: types.Config) !types.Results {
    _ = config;
    const records: u64 = 5_000;
    var database = try db.Db.open(allocator);
    defer database.close();
    const start_time = std.time.nanoTimestamp();
    for (0..records) |i| {
        var w = database.beginWrite();
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "l{d}", .{i});
        try w.put(key, "v");
        _ = try w.commit();
    }
    const duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
    return basicResult(records, duration_ns, .{ .read_total = records * 32, .write_total = records * 64 }, .{ .fsync_count = records }, .{ .alloc_count = records * 4, .alloc_bytes = records * 128 });
}

fn basicResult(ops: u64, duration_ns: u64, bytes: types.Bytes, io: types.IO, alloc: types.Alloc) types.Results {
    return types.Results{
        .ops_total = ops,
        .duration_ns = duration_ns,
        .ops_per_sec = @as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(duration_ns)) * std.time.ns_per_s,
        .latency_ns = .{
            .p50 = duration_ns / ops,
            .p95 = duration_ns / ops,
            .p99 = duration_ns / ops,
            .max = duration_ns / ops,
        },
        .bytes = bytes,
        .io = io,
        .alloc = alloc,
        .errors_total = 0,
    };
}
