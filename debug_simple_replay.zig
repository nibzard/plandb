const std = @import("std");
const wal = @import("src/wal.zig");
const txn = @import("src/txn.zig");

pub fn main() !void {
    const test_filename = "debug_simple_replay.db";
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

    // Now manually replay the record like the replay function does
    var file = try std.fs.cwd().openFile(test_filename, .{ .mode = .read_only });
    defer file.close();

    // Manually implement the start of replayFrom
    try file.seekTo(0);
    const file_size = try file.getEndPos();
    std.debug.print("File size: {}\n", .{file_size});

    const file_pos: usize = 0;
    if (file_pos + wal.WriteAheadLog.RecordHeader.SIZE > file_size) {
        std.debug.print("Not enough bytes for header\n", .{});
        return;
    }

    var header_bytes: [wal.WriteAheadLog.RecordHeader.SIZE]u8 = undefined;
    const bytes_read = try file.pread(&header_bytes, file_pos);
    std.debug.print("Read {} bytes for header\n", .{bytes_read});
    std.debug.print("Header bytes: ", .{});
    for (header_bytes) |byte| {
        std.debug.print("{x:0>2} ", .{byte});
    }
    std.debug.print("\n", .{});

    const header = std.mem.bytesAsValue(wal.WriteAheadLog.RecordHeader, &header_bytes);
    std.debug.print("Header magic: 0x{x} (expected: 0x{x})\n", .{ header.magic, 0x4C4F4752 });
    std.debug.print("Header record_type: {}\n", .{header.record_type});
    std.debug.print("Header txn_id: {}\n", .{header.txn_id});
    std.debug.print("Header payload_len: {}\n", .{header.payload_len});
}