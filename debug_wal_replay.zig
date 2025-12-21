const std = @import("std");
const wal = @import("src/wal.zig");
const txn = @import("src/txn.zig");

pub fn main() !void {
    const test_filename = "debug_wal_replay.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    // Create WAL and append a record
    var wal_inst = try wal.WriteAheadLog.create(test_filename, std.heap.page_allocator);
    defer wal_inst.deinit();

    const mutations = [_]txn.Mutation{
        txn.Mutation{ .put = .{ .key = "key1", .value = "value1" } },
    };

    var record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculatePayloadChecksum();

    const lsn = try wal_inst.appendCommitRecord(record);
    std.debug.print("Appended record with LSN: {}\n", .{lsn});

    try wal_inst.flush();
    try wal_inst.sync();

    std.debug.print("Current LSN after flush: {}\n", .{wal_inst.getCurrentLsn()});

    // Now try to replay
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var result = try wal_inst.replayFrom(0, arena.allocator());
    defer result.deinit();

    std.debug.print("Replay result - last_lsn: {}, commit_records.len: {}\n", .{ result.last_lsn, result.commit_records.items.len });

    // Also test with a fresh WAL instance (like the test does)
    var wal_fresh = try wal.WriteAheadLog.open(test_filename, std.heap.page_allocator);
    defer wal_fresh.deinit();

    std.debug.print("Fresh WAL current LSN: {}\n", .{wal_fresh.getCurrentLsn()});

    var result2 = try wal_fresh.replayFrom(0, arena.allocator());
    defer result2.deinit();

    std.debug.print("Fresh WAL replay result - last_lsn: {}, commit_records.len: {}\n", .{ result2.last_lsn, result2.commit_records.items.len });
}