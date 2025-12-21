const std = @import("std");
const wal = @import("src/wal.zig");
const txn = @import("src/txn.zig");

pub fn main() !void {
    const test_filename = "debug_wal.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    // Create WAL with a simple record
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

    // Read back the raw file
    var file = try std.fs.cwd().openFile(test_filename, .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();
    std.debug.print("File size: {} bytes\n", .{file_size});

    const buffer = try std.heap.page_allocator.alloc(u8, file_size);
    defer std.heap.page_allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    std.debug.print("Bytes read: {}\n", .{bytes_read});

    std.debug.print("File contents (hex):\n", .{});
    for (buffer, 0..) |byte, i| {
        if (i % 16 == 0) std.debug.print("\n{d:04}: ", .{i});
        std.debug.print("{d:0>2} ", .{byte});
    }
    std.debug.print("\n", .{});
}