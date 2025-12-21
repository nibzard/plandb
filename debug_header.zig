const std = @import("std");
const wal = @import("src/wal.zig");

pub fn main() !void {
    const test_filename = "debug_header.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    // Create a simple RecordHeader and write it directly
    const header = wal.WriteAheadLog.RecordHeader{
        .magic = 0x4C4F4752, // "LOGR"
        .record_version = 0,
        .record_type = 0,
        .header_len = 40,
        .flags = 0x02,
        .txn_id = 1,
        .prev_lsn = 0,
        .payload_len = 46,
        .header_crc32c = 0x12345678,
        .payload_crc32c = 0x87654321,
    };

    std.debug.print("RecordHeader size: {}\n", .{@sizeOf(wal.WriteAheadLog.RecordHeader)});

    // Write it to a file
    var file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true, .read = true });
    defer file.close();

    const header_bytes = std.mem.asBytes(&header);
    _ = try file.writeAll(header_bytes);

    // Read it back
    try file.seekTo(0);
    var read_bytes: [@sizeOf(wal.WriteAheadLog.RecordHeader)]u8 = undefined;
    const bytes_read = try file.readAll(&read_bytes);

    std.debug.print("Read {} bytes\n", .{bytes_read});
    std.debug.print("Header bytes: ", .{});
    for (read_bytes) |byte| {
        std.debug.print("{x:0>2} ", .{byte});
    }
    std.debug.print("\n", .{});

    const read_header = std.mem.bytesAsValue(wal.WriteAheadLog.RecordHeader, &read_bytes);
    std.debug.print("Read header magic: 0x{x} (expected: 0x{x})\n", .{ read_header.magic, header.magic });
    std.debug.print("Read header txn_id: {} (expected: {})\n", .{ read_header.txn_id, header.txn_id });
    std.debug.print("Read header payload_len: {} (expected: {})\n", .{ read_header.payload_len, header.payload_len });
}