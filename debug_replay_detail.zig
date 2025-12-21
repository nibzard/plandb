const std = @import("std");
const wal = @import("src/wal.zig");
const txn = @import("src/txn.zig");

pub fn main() !void {
    const test_filename = "debug_replay_detail.db";
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

    // Manual file inspection
    var file = try std.fs.cwd().openFile(test_filename, .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();
    std.debug.print("File size: {} bytes\n", .{file_size});

    // Read first few bytes to see what's there
    if (file_size >= 16) {
        var first_bytes: [16]u8 = undefined;
        const bytes_read = try file.pread(&first_bytes, 0);
        std.debug.print("First {} bytes: ", .{bytes_read});
        for (first_bytes[0..bytes_read]) |byte| {
            std.debug.print("{x:0>2} ", .{byte});
        }
        std.debug.print("\n", .{});

        // Try to interpret as record header
        if (bytes_read >= @sizeOf(wal.WriteAheadLog.RecordHeader)) {
            const header = std.mem.bytesAsValue(wal.WriteAheadLog.RecordHeader, &first_bytes);
            std.debug.print("Header magic: 0x{x} (expected: 0x{x})\n", .{ header.magic, 0x4C4F4752 });
            std.debug.print("Header record_type: {}\n", .{header.record_type});
            std.debug.print("Header txn_id: {}\n", .{header.txn_id});
            std.debug.print("Header payload_len: {}\n", .{header.payload_len});
        }
    }

    // Check buffer status in WAL
    std.debug.print("WAL buffer_pos: {}\n", .{wal_inst.buffer_pos});
    std.debug.print("WAL file_pos: {}\n", .{wal_inst.file_pos});
}