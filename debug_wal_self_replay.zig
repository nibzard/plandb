const std = @import("std");
const wal = @import("src/wal.zig");
const txn = @import("src/txn.zig");

pub fn main() !void {
    const test_filename = "debug_wal_self_replay.db";
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

    _ = try wal_inst.appendCommitRecord(record);
    try wal_inst.flush();
    try wal_inst.sync();

    std.debug.print("WAL LSN after append: {}\n", .{wal_inst.getCurrentLsn()});

    // Now replay from the same WAL instance
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var result = try wal_inst.replayFrom(0, arena.allocator());
    defer result.deinit();

    std.debug.print("Replay result - last_lsn: {}, commit_records.len: {}\n", .{ result.last_lsn, result.commit_records.items.len });
    std.debug.print("Replay result - last_checkpoint_txn_id: {}, truncate_lsn: {}\n", .{ result.last_checkpoint_txn_id, result.truncate_lsn orelse 0 });
}