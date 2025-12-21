//! Log dump utility for NorthstarDB commit logs.
//!
//! This tool inspects and verifies commit records in a .log file.
//! It can decode records, validate checksums, and display human-readable
//! information about the commit stream.

const std = @import("std");
const wal = @import("wal");

const Command = enum {
    dump,
    verify,
    scan,
    help,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return error.InvalidArguments;
    }

    const command = parseCommand(args[1]) catch {
        try printUsage();
        return error.InvalidCommand;
    };

    switch (command) {
        .help => {
            try printUsage();
            return;
        },
        .dump => {
            if (args.len < 3) {
                std.log.err("Error: dump command requires a log file path", .{});
                return error.MissingArgument;
            }
            try dumpLogFile(args[2], allocator);
        },
        .verify => {
            if (args.len < 3) {
                std.log.err("Error: verify command requires a log file path", .{});
                return error.MissingArgument;
            }
            try verifyLogFile(args[2], allocator);
        },
        .scan => {
            if (args.len < 3) {
                std.log.err("Error: scan command requires a log file path", .{});
                return error.MissingArgument;
            }
            try scanLogFile(args[2], allocator);
        },
    }
}

fn parseCommand(arg: []const u8) !Command {
    if (std.mem.eql(u8, arg, "dump")) return .dump;
    if (std.mem.eql(u8, arg, "verify")) return .verify;
    if (std.mem.eql(u8, arg, "scan")) return .scan;
    if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
    return error.UnknownCommand;
}

fn printUsage() !void {
    std.debug.print(
        \\NorthstarDB Log Inspection Tool
        \\
        \\Usage: logdump <command> <log_file>
        \\
        \\Commands:
        \\  dump <file>     - Decode and display all records in human-readable format
        \\  verify <file>   - Validate record structure and checksums
        \\  scan <file>     - Quick scan showing record count and basic stats
        \\  help            - Show this help message
        \\
        \\Examples:
        \\  logdump dump test.db.log
        \\  logdump verify test.db.log
        \\  logdump scan test.db.log
        \\
    , .{});
}

fn dumpLogFile(path: []const u8, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size == 0) {
        std.log.info("Log file is empty", .{});
        return;
    }

    var buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != file_size) {
        return error.UnexpectedEOF;
    }

    std.log.info("Dumping log file: {s} ({} bytes)", .{ path, file_size });
    std.log.info("=" ** 60, .{});

    var pos: usize = 0;
    var record_count: usize = 0;
    var errors: usize = 0;

    while (pos < file_size) {
        // Check if we have enough bytes for a header
        if (pos + wal.WriteAheadLog.RecordHeader.SIZE > file_size) {
            std.log.warn("Incomplete record header at offset {d}", .{pos});
            errors += 1;
            break;
        }

        // Parse header
        const header_bytes = buffer[pos..pos + wal.WriteAheadLog.RecordHeader.SIZE];
        const header = std.mem.bytesAsValue(wal.WriteAheadLog.RecordHeader, header_bytes[0..wal.WriteAheadLog.RecordHeader.SIZE]);

        // Validate magic
        if (header.magic != 0x4C4F4752) { // "LOGR"
            std.log.err("Invalid record magic at offset {d}: found 0x{x}", .{ pos, header.magic });
            errors += 1;
            break;
        }

        // Validate header checksum
        if (!header.validateHeaderChecksum()) {
            std.log.err("Header checksum validation failed at offset {d}", .{pos});
            errors += 1;
            // Try to resync by scanning for next magic
            pos += 4;
            continue;
        }

        // Calculate total record size
        const total_size = header.header_len + header.payload_len + wal.WriteAheadLog.RecordTrailer.SIZE;

        // Check if we have enough bytes for the complete record
        if (pos + total_size > file_size) {
            std.log.warn("Incomplete record at offset {d}: need {} bytes, have {}", .{ pos, total_size, file_size - pos });
            errors += 1;
            break;
        }

        // Parse trailer
        const trailer_offset = pos + header.header_len + header.payload_len;
        const trailer_bytes = buffer[trailer_offset..trailer_offset + wal.WriteAheadLog.RecordTrailer.SIZE];
        const trailer = std.mem.bytesAsValue(wal.WriteAheadLog.RecordTrailer, trailer_bytes[0..wal.WriteAheadLog.RecordTrailer.SIZE]);

        // Validate trailer magic and checksum
        if (trailer.magic2 != 0x52474F4C) { // "RGOL"
            std.log.err("Invalid trailer magic at offset {d}: found 0x{x}", .{ trailer_offset, trailer.magic2 });
            errors += 1;
            pos += 4;
            continue;
        }

        if (!trailer.validateTrailerChecksum()) {
            std.log.err("Trailer checksum validation failed at offset {d}", .{trailer_offset});
            errors += 1;
            pos += 4;
            continue;
        }

        record_count += 1;

        // Display record info
        std.log.info("Record #{d} at LSN {d}", .{ record_count, pos });
        std.log.info("  Type: {s}", .{switch (header.record_type) {
            0 => "Commit",
            1 => "Checkpoint",
            2 => "CartridgeMeta",
            else => "Unknown",
        }});
        std.log.info("  TxnId: {d}", .{header.txn_id});
        std.log.info("  Prev LSN: {d}", .{header.prev_lsn});
        std.log.info("  Payload Size: {d} bytes", .{header.payload_len});

        if (header.record_type == 0 and header.payload_len > 0) { // Commit record
            dumpCommitRecord(buffer[pos + header.header_len .. pos + header.header_len + header.payload_len]) catch |err| {
                std.log.warn("  Failed to decode commit record: {}", .{err});
            };
        }

        std.log.info("  Total Size: {d} bytes", .{total_size});
        std.log.info("", .{});

        pos += total_size;
    }

    std.log.info("=" ** 60, .{});
    std.log.info("Summary: {d} records processed, {d} errors", .{ record_count, errors });
}

fn dumpCommitRecord(payload_bytes: []const u8) !void {
    if (payload_bytes.len < 20) { // Minimum size for CommitPayloadHeader
        std.log.warn("  Payload too small for commit header", .{});
        return;
    }

    // Parse CommitPayloadHeader
    const commit_magic = @as(*const [4]u8, @ptrCast(payload_bytes[0..4])).*;
    if (std.mem.readInt(u32, &commit_magic, .little) != 0x434D4954) { // "CMIT"
        const commit_magic_val = std.mem.readInt(u32, &commit_magic, .little);
        std.log.warn("  Invalid commit payload magic: 0x{x}", .{commit_magic_val});
        return;
    }

    const txn_id_slice = @as(*const [8]u8, @ptrCast(payload_bytes[4..12])).*;
    const root_page_slice = @as(*const [8]u8, @ptrCast(payload_bytes[12..20])).*;
    const op_count_slice = @as(*const [4]u8, @ptrCast(payload_bytes[20..24])).*;
    const reserved_slice = @as(*const [4]u8, @ptrCast(payload_bytes[24..28])).*;

    const txn_id = std.mem.readInt(u64, &txn_id_slice, .little);
    const root_page_id = std.mem.readInt(u64, &root_page_slice, .little);
    const op_count = std.mem.readInt(u32, &op_count_slice, .little);
    const reserved = std.mem.readInt(u32, &reserved_slice, .little);

    std.log.info("  Commit Payload:", .{});
    std.log.info("    TxnId (payload): {d}", .{txn_id});
    std.log.info("    Root Page ID: {d}", .{root_page_id});
    std.log.info("    Operation Count: {d}", .{op_count});

    if (reserved != 0) {
        std.log.warn("    Reserved field non-zero: {d}", .{reserved});
    }

    // Parse operations
    var op_pos: usize = 28; // After header
    var op_index: usize = 0;

    while (op_index < op_count and op_pos < payload_bytes.len) {
        if (op_pos + 7 > payload_bytes.len) { // Minimum op header size
            std.log.warn("  Incomplete operation header at offset {d}", .{op_pos});
            break;
        }

        const op_type = payload_bytes[op_pos];
        const op_flags = payload_bytes[op_pos + 1];
        const key_len_slice = @as(*const [2]u8, @ptrCast(payload_bytes[op_pos + 2 .. op_pos + 4])).*;
        const val_len_slice = @as(*const [4]u8, @ptrCast(payload_bytes[op_pos + 4 .. op_pos + 8])).*;
        const key_len = std.mem.readInt(u16, &key_len_slice, .little);
        const val_len = std.mem.readInt(u32, &val_len_slice, .little);

        const op_start = op_pos + 8;
        const op_total = key_len + val_len;

        if (op_start + op_total > payload_bytes.len) {
            std.log.warn("  Operation {d} exceeds payload boundary", .{op_index});
            break;
        }

        const key_bytes = payload_bytes[op_start..op_start + key_len];
        const val_bytes = payload_bytes[op_start + key_len .. op_start + key_len + val_len];

        std.log.info("    Op #{d}: {s} key_len={d} val_len={d}", .{
            op_index,
            switch (op_type) {
                0 => "Put",
                1 => "Del",
                else => "Unknown",
            },
            key_len,
            val_len
        });

        // Print key as string if it looks like UTF-8
        if (key_len > 0 and std.unicode.utf8ValidateSlice(key_bytes)) {
            const max_display = @min(key_len, 50);
            std.log.info("      Key: \"{s}\"{s}", .{
                key_bytes[0..max_display],
                if (key_len > max_display) "..." else ""
            });
        } else {
            std.log.info("      Key: {any} ({} bytes)", .{ key_bytes, key_len });
        }

        // For Put operations, show value preview
        if (op_type == 0 and val_len > 0) {
            const max_display = @min(val_len, 50);
            std.log.info("      Val: {any}{s} ({} bytes)", .{
                val_bytes[0..max_display],
                if (val_len > max_display) "..." else "",
                val_len
            });
        }

        if (op_flags != 0) {
            std.log.warn("      Flags: 0x{x} (V0 should be 0)", .{op_flags});
        }

        op_pos += 8 + op_total;
        op_index += 1;
    }
}

fn verifyLogFile(path: []const u8, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size == 0) {
        std.log.info("Log file is empty - verification passed", .{});
        return;
    }

    var buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);

    std.log.info("Verifying log file: {s}", .{ path });

    var pos: usize = 0;
    var record_count: usize = 0;
    var errors: usize = 0;
    var warnings: usize = 0;

    while (pos < file_size) {
        _ = try file.seekTo(pos);

        // Read and validate header
        if (pos + wal.WriteAheadLog.RecordHeader.SIZE > file_size) {
            std.log.warn("EOF: Incomplete record header at offset {d}", .{pos});
            warnings += 1;
            break;
        }

        const bytes_read = try file.readAll(buffer[0..wal.WriteAheadLog.RecordHeader.SIZE]);
        if (bytes_read != wal.WriteAheadLog.RecordHeader.SIZE) {
            std.log.err("Read error at offset {d}", .{pos});
            errors += 1;
            break;
        }

        const header = std.mem.bytesAsValue(wal.WriteAheadLog.RecordHeader, buffer[0..wal.WriteAheadLog.RecordHeader.SIZE]);

        if (header.magic != 0x4C4F4752) {
            std.log.err("Invalid magic at offset {d}: 0x{x}", .{ pos, header.magic });
            errors += 1;
            // Try to resync
            pos += 4;
            continue;
        }

        if (!header.validateHeaderChecksum()) {
            std.log.err("Header checksum failed at offset {d}", .{pos});
            errors += 1;
            pos += 4;
            continue;
        }

        const total_size = header.header_len + header.payload_len + wal.WriteAheadLog.RecordTrailer.SIZE;

        if (pos + total_size > file_size) {
            std.log.warn("EOF: Incomplete record at offset {d}", .{pos});
            warnings += 1;
            break;
        }

        // Read and validate trailer
        _ = try file.seekTo(pos + header.header_len + header.payload_len);
        _ = try file.readAll(buffer[0..wal.WriteAheadLog.RecordTrailer.SIZE]);

        const trailer = std.mem.bytesAsValue(wal.WriteAheadLog.RecordTrailer, buffer[0..wal.WriteAheadLog.RecordTrailer.SIZE]);

        if (trailer.magic2 != 0x52474F4C) {
            std.log.err("Invalid trailer magic at offset {d}", .{pos + header.header_len + header.payload_len});
            errors += 1;
            pos += 4;
            continue;
        }

        if (!trailer.validateTrailerChecksum()) {
            std.log.err("Trailer checksum failed at offset {d}", .{pos + header.header_len + header.payload_len});
            errors += 1;
            pos += 4;
            continue;
        }

        // Validate payload checksum
        if (header.payload_len > 0) {
            const payload_buffer = try allocator.alloc(u8, header.payload_len);
            defer allocator.free(payload_buffer);

            _ = try file.seekTo(pos + header.header_len);
            _ = try file.readAll(payload_buffer);

            var hasher = std.hash.Crc32.init();
            hasher.update(payload_buffer);
            const calculated_payload_crc = hasher.final();

            if (calculated_payload_crc != header.payload_crc32c) {
                std.log.err("Payload checksum mismatch at offset {d}: expected 0x{x}, got 0x{x}", .{
                    pos, header.payload_crc32c, calculated_payload_crc
                });
                errors += 1;
            }
        }

        record_count += 1;
        pos += total_size;
    }

    std.log.info("Verification complete:", .{});
    std.log.info("  Records: {d}", .{record_count});
    std.log.info("  Errors: {d}", .{errors});
    std.log.info("  Warnings: {d}", .{warnings});

    if (errors == 0 and warnings == 0) {
        std.log.info("Result: PASSED", .{});
    } else if (errors == 0) {
        std.log.info("Result: PASSED with warnings", .{});
    } else {
        std.log.info("Result: FAILED", .{});
    }
}

fn scanLogFile(path: []const u8, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size == 0) {
        std.log.info("Log file is empty", .{});
        return;
    }

    const buffer = try allocator.alloc(u8, wal.WriteAheadLog.RecordHeader.SIZE);
    defer allocator.free(buffer);

    std.log.info("Scanning log file: {s} ({} bytes)", .{ path, file_size });

    var pos: usize = 0;
    var record_count: usize = 0;
    var commit_count: usize = 0;
    var checkpoint_count: usize = 0;
    var max_payload: u32 = 0;
    var min_payload: u32 = std.math.maxInt(u32);
    var total_payload: u64 = 0;

    while (pos < file_size) {
        _ = try file.seekTo(pos);

        if (pos + wal.WriteAheadLog.RecordHeader.SIZE > file_size) break;

        _ = try file.readAll(buffer);
        const header = std.mem.bytesAsValue(wal.WriteAheadLog.RecordHeader, buffer[0..wal.WriteAheadLog.RecordHeader.SIZE]);

        if (header.magic != 0x4C4F4752) {
            // Try to find next valid magic
            pos += 4;
            continue;
        }

        const total_size = header.header_len + header.payload_len + wal.WriteAheadLog.RecordTrailer.SIZE;

        if (pos + total_size > file_size) break;

        record_count += 1;

        switch (header.record_type) {
            0 => commit_count += 1,
            1 => checkpoint_count += 1,
            else => {},
        }

        // Track payload statistics
        if (header.payload_len > 0) {
            max_payload = @max(max_payload, header.payload_len);
            min_payload = @min(min_payload, header.payload_len);
            total_payload += header.payload_len;
        }

        pos += total_size;
    }

    std.log.info("Scan Results:", .{});
    std.log.info("  Total Records: {d}", .{record_count});
    std.log.info("    Commits: {d}", .{commit_count});
    std.log.info("    Checkpoints: {d}", .{checkpoint_count});
    if (record_count > 0) {
        std.log.info("  Payload Statistics:", .{});
        std.log.info("    Min Size: {d} bytes", .{min_payload});
        std.log.info("    Max Size: {d} bytes", .{max_payload});
        std.log.info("    Avg Size: {d:.1} bytes", .{@as(f64, @floatFromInt(total_payload)) / @as(f64, @floatFromInt(record_count))});
    }
}