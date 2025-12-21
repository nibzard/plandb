const std = @import("std");
const wal = @import("src/wal.zig");
const txn = @import("src/txn.zig");

pub fn main() !void {
    const test_filename = "debug_append_detail.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    // Create WAL
    var wal_inst = try wal.WriteAheadLog.create(test_filename, std.heap.page_allocator);
    defer wal_inst.deinit();

    std.debug.print("Initial WAL state - buffer_pos: {}, file_pos: {}\n", .{ wal_inst.buffer_pos, wal_inst.file_pos });

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

    std.debug.print("About to append record...\n", .{});
    const lsn = try wal_inst.appendCommitRecord(record);
    std.debug.print("Appended record with LSN: {}\n", .{lsn});
    std.debug.print("After append - buffer_pos: {}, file_pos: {}\n", .{ wal_inst.buffer_pos, wal_inst.file_pos });

    // Check file contents BEFORE flush
    var file = try std.fs.cwd().openFile(test_filename, .{ .mode = .read_only });
    defer file.close();

    const file_size_before = try file.getEndPos();
    std.debug.print("File size before flush: {} bytes\n", .{file_size_before});

    if (file_size_before >= 16) {
        var first_bytes: [16]u8 = undefined;
        const bytes_read = try file.pread(&first_bytes, 0);
        std.debug.print("First {} bytes before flush: ", .{bytes_read});
        for (first_bytes[0..bytes_read]) |byte| {
            std.debug.print("{x:0>2} ", .{byte});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("About to flush...\n", .{});
    try wal_inst.flush();
    std.debug.print("After flush - buffer_pos: {}, file_pos: {}\n", .{ wal_inst.buffer_pos, wal_inst.file_pos });

    // Check file contents AFTER flush
    const file_size_after = try file.getEndPos();
    std.debug.print("File size after flush: {} bytes\n", .{file_size_after});

    if (file_size_after >= 16) {
        var first_bytes: [16]u8 = undefined;
        const bytes_read = try file.pread(&first_bytes, 0);
        std.debug.print("First {} bytes after flush: ", .{bytes_read});
        for (first_bytes[0..bytes_read]) |byte| {
            std.debug.print("{x:0>2} ", .{byte});
        }
        std.debug.print("\n", .{});
    }
}