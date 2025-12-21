//! Write-Ahead Log (WAL) scaffolding for commit logging.
//!
//! Provides a minimal append-only log structure with simple record framing.
//! Checkpointing, replay, and full crash-recovery guarantees are not implemented yet.

const std = @import("std");
const txn = @import("txn.zig");
const pager = @import("pager.zig");

/// Write-Ahead Log provides durability for transactions
pub const WriteAheadLog = struct {
    file: std.fs.File,
    current_lsn: u64,
    buffer: []u8,
    buffer_pos: usize,
    sync_needed: bool,
    allocator: std.mem.Allocator,
    file_pos: usize, // Current file position for appending

    const Self = @This();

    /// WAL record header per spec/commit_record_v0.md
    pub const RecordHeader = struct {
        magic: u32 = 0x4C4F4752, // "LOGR"
        record_version: u16 = 0,
        record_type: u16,
        header_len: u16 = 40, // bytes of header in V0
        flags: u16,
        txn_id: u64,
        prev_lsn: u64,
        payload_len: u32,
        header_crc32c: u32,
        payload_crc32c: u32,

        pub const SIZE: usize = @sizeOf(@This());

        pub fn calculateHeaderChecksum(self: @This()) u32 {
            var hasher = std.hash.Crc32.init();
            const temp = RecordHeader{
                .magic = self.magic,
                .record_version = self.record_version,
                .record_type = self.record_type,
                .header_len = self.header_len,
                .flags = self.flags,
                .txn_id = self.txn_id,
                .prev_lsn = self.prev_lsn,
                .payload_len = self.payload_len,
                .header_crc32c = 0,
                .payload_crc32c = self.payload_crc32c,
            };
            hasher.update(std.mem.asBytes(&temp));
            return hasher.final();
        }

        pub fn validateHeaderChecksum(self: @This()) bool {
            return self.header_crc32c == self.calculateHeaderChecksum();
        }
    };

    pub const RecordType = enum(u16) {
        commit = 0,
        checkpoint = 1,
        cartridge_meta = 2,
    };

    /// WAL record trailer per spec/commit_record_v0.md
    pub const RecordTrailer = struct {
        magic2: u32 = 0x52474F4C, // "RGOL" (LOGR reversed)
        total_len: u32, // header_len + payload_len + trailer_len
        trailer_crc32c: u32,

        pub const SIZE: usize = @sizeOf(@This());

        pub fn calculateTrailerChecksum(self: @This()) u32 {
            var hasher = std.hash.Crc32.init();
            const temp = RecordTrailer{
                .magic2 = self.magic2,
                .total_len = self.total_len,
                .trailer_crc32c = 0,
            };
            hasher.update(std.mem.asBytes(&temp));
            return hasher.final();
        }

        pub fn validateTrailerChecksum(self: @This()) bool {
            return self.trailer_crc32c == self.calculateTrailerChecksum();
        }
    };

    /// Initialize or open a WAL file
    pub fn open(path: []const u8, allocator: std.mem.Allocator) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        errdefer file.close();

        // Get current file size to determine next LSN
        const file_size = try file.getEndPos();
        var current_lsn: u64 = 0;

        if (file_size > 0) {
            // Scan existing WAL to find highest LSN
            current_lsn = try scanHighestLsn(&file);
        }

        const buffer = try allocator.alignedAlloc(u8, null, 64 * 1024); // 64KB buffer
        errdefer allocator.free(buffer);

        return Self{
            .file = file,
            .current_lsn = current_lsn,
            .buffer = buffer,
            .buffer_pos = 0,
            .sync_needed = false,
            .allocator = allocator,
            .file_pos = file_size,
        };
    }

    /// Create a new WAL file
    pub fn create(path: []const u8, allocator: std.mem.Allocator) !Self {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = true });
        errdefer file.close();

        const buffer = try allocator.alignedAlloc(u8, null, 64 * 1024);
        errdefer allocator.free(buffer);

        return Self{
            .file = file,
            .current_lsn = 0,
            .buffer = buffer,
            .buffer_pos = 0,
            .sync_needed = false,
            .allocator = allocator,
            .file_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // Try to flush any pending data
        self.flush() catch {};
        self.file.close();
        self.allocator.free(self.buffer);
    }

    /// Append a commit record to the WAL
    pub fn appendCommitRecord(self: *Self, record: txn.CommitRecord) !u64 {
        if (!record.validateChecksum()) return error.InvalidChecksum;

        const serialized = try self.serializeCommitRecord(&record);
        defer self.allocator.free(serialized);

        const payload_crc32c = record.calculatePayloadChecksum();

        const header = RecordHeader{
            .magic = 0x4C4F4752, // "LOGR"
            .record_version = 0,
            .record_type = @intFromEnum(WriteAheadLog.RecordType.commit),
            .header_len = 40,
            .flags = 0x02, // bit1: payload contains inline values (V0: 1)
            .txn_id = record.txn_id,
            .prev_lsn = self.current_lsn,
            .payload_len = @intCast(serialized.len),
            .header_crc32c = 0, // Will be calculated
            .payload_crc32c = payload_crc32c,
        };

        return self.appendRecordWithTrailer(header, serialized);
    }

    /// Append a checkpoint record
    pub fn appendCheckpoint(self: *Self, txn_id: u64) !u64 {
        const checkpoint_data = std.mem.toBytes(txn_id);
        const header = RecordHeader{
            .lsn = self.current_lsn + 1,
            .record_type = .checkpoint,
            .length = @intCast(checkpoint_data.len),
            .checksum = 0,
        };

        return self.appendRecord(header, &checkpoint_data);
    }

    /// Sync WAL to ensure durability
    pub fn sync(self: *Self) !void {
        if (self.buffer_pos > 0) {
            try self.flush();
        }
        try self.file.sync();
        self.sync_needed = false;
    }

    /// Get current LSN (highest committed record)
    pub fn getCurrentLsn(self: *const Self) u64 {
        return self.current_lsn;
    }

    /// Replay WAL from a given starting LSN
    pub fn replayFrom(self: *Self, start_lsn: u64, allocator: std.mem.Allocator) !ReplayResult {
        var result = ReplayResult.init(allocator);
        errdefer result.deinit();

        // Ensure we're at the start of the file for reading
        try self.file.seekTo(0);
        var file_pos: usize = 0;
        const file_size = try self.file.getEndPos();

        std.debug.print("Replay: file_size={}, file_pos={}\n", .{ file_size, file_pos });

        var iterations: usize = 0;
        var current_lsn: u64 = 1; // LSN starts from 1
        while (file_pos < file_size and iterations < 1000) {
            std.debug.print("Replay iteration {}: file_pos={}, file_size={}\n", .{ iterations, file_pos, file_size });
            iterations += 1;
            // Ensure we have enough bytes for a header
            if (file_pos + RecordHeader.SIZE > file_size) break;

            var header_bytes: [RecordHeader.SIZE]u8 = undefined;
            const bytes_read = try self.file.pread(&header_bytes, file_pos);
            if (bytes_read < RecordHeader.SIZE) break;

            const header = readExplicitHeader(&header_bytes) catch {
                std.debug.print("Failed to read header at pos {}\n", .{file_pos});
                break; // Invalid header format
            };
            if (header.magic != 0x4C4F4752) {
                std.debug.print("Invalid magic number: 0x{x} at pos {}\n", .{ header.magic, file_pos });
                break; // "LOGR"
            }

            // Validate header checksum using explicit calculation
            const expected_header_crc = calculateExplicitHeaderChecksum(header);
            if (header.header_crc32c != expected_header_crc) {
                std.debug.print("Checksum mismatch: expected 0x{x}, got 0x{x} at pos {}\n", .{ expected_header_crc, header.header_crc32c, file_pos });
                break;
            }

            // Ensure we have enough bytes for the full record
            const record_size = RecordHeader.SIZE + header.payload_len + RecordTrailer.SIZE;
            if (file_pos + record_size > file_size) break;

            if (current_lsn < start_lsn) {
                file_pos += record_size;
                current_lsn += 1;
                continue;
            }

            // Read record data
            const record_data = try allocator.alloc(u8, header.payload_len);
            defer allocator.free(record_data);

            const data_read = try self.file.pread(record_data, file_pos + RecordHeader.SIZE);
            if (data_read < header.payload_len) break;

            // Verify payload CRC
            var hasher = std.hash.Crc32.init();
            hasher.update(record_data);
            const calculated_payload_crc = hasher.final();
            if (calculated_payload_crc != header.payload_crc32c) {
                file_pos += record_size; // Skip corrupted record
                continue;
            }

            switch (header.record_type) {
                0 => { // commit
                    const commit_record = try WriteAheadLog.deserializeCommitRecord(record_data, allocator);
                    try result.commit_records.append(allocator, commit_record);
                },
                1 => { // checkpoint
                    if (header.payload_len == @sizeOf(u64)) {
                        const checkpoint_txn_id = std.mem.bytesAsValue(u64, record_data);
                        result.last_checkpoint_txn_id = checkpoint_txn_id.*;
                    }
                },
                2 => { // cartridge_meta
                    result.truncate_lsn = header.txn_id;
                },
                else => {
                    // Unknown record type, skip it
                },
            }

            result.last_lsn = current_lsn;
            file_pos += record_size;
            current_lsn += 1;
        }

        return result;
    }

    /// Truncate WAL up to a specific LSN
    pub fn truncate(self: *Self, keep_lsn: u64) !void {
        // Flush any buffered data first
        try self.flush();
        try self.sync();

        var file_pos: usize = 0;
        var current_lsn: u64 = 1;
        const file_size = try self.file.getEndPos();

        // Find position of record with keep_lsn
        while (file_pos < file_size) {
            var header_bytes: [RecordHeader.SIZE]u8 = undefined;
            const bytes_read = try self.file.pread(&header_bytes, file_pos);
            if (bytes_read < RecordHeader.SIZE) break;

            const header = readExplicitHeader(&header_bytes) catch break;
            if (header.magic != 0x4C4F4752) break; // "LOGR"

            const record_size = RecordHeader.SIZE + header.payload_len + RecordTrailer.SIZE;

            if (current_lsn >= keep_lsn) {
                // We've found the keep LSN or beyond, truncate here
                try self.file.setEndPos(file_pos);
                try self.file.seekTo(0);
                const scanned_lsn = scanHighestLsn(&self.file) catch 0;
                self.current_lsn = scanned_lsn;
                return;
            }
            file_pos += record_size;
            current_lsn += 1;
        }

        // If we didn't find the LSN, truncate everything
        try self.file.setEndPos(0);
        try self.file.seekTo(0);
        self.current_lsn = 0;
    }

    /// Private: Append any record type to WAL with trailer
    fn appendRecordWithTrailer(self: *Self, header: RecordHeader, data: []const u8) !u64 {
        const record_size = RecordHeader.SIZE + data.len + RecordTrailer.SIZE;

        // Calculate header CRC
        const header_crc = calculateExplicitHeaderChecksum(header);
        const payload_crc = header.payload_crc32c;

        // Create trailer
        const total_len: u32 = @intCast(record_size);
        const trailer_crc = calculateExplicitTrailerChecksum(total_len);

        // Check if record fits in buffer
        if (self.buffer_pos + record_size > self.buffer.len) {
            try self.flush();
        }

        // If record is larger than buffer, write directly
        if (record_size > self.buffer.len) {
            // Write header fields in explicit order
            var offset: usize = self.file_pos;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header.magic), offset);
            offset += 4;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header.record_version), offset);
            offset += 2;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header.record_type), offset);
            offset += 2;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header.header_len), offset);
            offset += 2;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header.flags), offset);
            offset += 2;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header.txn_id), offset);
            offset += 8;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header.prev_lsn), offset);
            offset += 8;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header.payload_len), offset);
            offset += 4;
            _ = try self.file.pwriteAll(std.mem.asBytes(&header_crc), offset);
            offset += 4;
            _ = try self.file.pwriteAll(std.mem.asBytes(&payload_crc), offset);
            offset += 4;

            // Write payload
            _ = try self.file.pwriteAll(data, offset);
            offset += data.len;

            // Write trailer fields in explicit order
            const trailer_magic = @as(u32, 0x52474F4C); // "RGOL"
            _ = try self.file.pwriteAll(std.mem.asBytes(&trailer_magic), offset);
            offset += 4;
            _ = try self.file.pwriteAll(std.mem.asBytes(&total_len), offset);
            offset += 4;
            _ = try self.file.pwriteAll(std.mem.asBytes(&trailer_crc), offset);
            offset += 4;

            self.file_pos += record_size;
            self.current_lsn += 1; // Increment LSN as record counter
            self.sync_needed = true;
            return self.current_lsn;
        }

        // Write to buffer in explicit order
        var buffer_pos: usize = self.buffer_pos;

        // Header fields
        @memcpy(self.buffer[buffer_pos..buffer_pos + 4], std.mem.asBytes(&header.magic));
        buffer_pos += 4;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 2], std.mem.asBytes(&header.record_version));
        buffer_pos += 2;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 2], std.mem.asBytes(&header.record_type));
        buffer_pos += 2;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 2], std.mem.asBytes(&header.header_len));
        buffer_pos += 2;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 2], std.mem.asBytes(&header.flags));
        buffer_pos += 2;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 8], std.mem.asBytes(&header.txn_id));
        buffer_pos += 8;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 8], std.mem.asBytes(&header.prev_lsn));
        buffer_pos += 8;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 4], std.mem.asBytes(&header.payload_len));
        buffer_pos += 4;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 4], std.mem.asBytes(&header_crc));
        buffer_pos += 4;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 4], std.mem.asBytes(&payload_crc));
        buffer_pos += 4;

        // Payload
        if (data.len > 0) {
            @memcpy(self.buffer[buffer_pos..buffer_pos + data.len], data);
            buffer_pos += data.len;
        }

        // Trailer fields
        const trailer_magic = @as(u32, 0x52474F4C); // "RGOL"
        @memcpy(self.buffer[buffer_pos..buffer_pos + 4], std.mem.asBytes(&trailer_magic));
        buffer_pos += 4;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 4], std.mem.asBytes(&total_len));
        buffer_pos += 4;
        @memcpy(self.buffer[buffer_pos..buffer_pos + 4], std.mem.asBytes(&trailer_crc));
        buffer_pos += 4;

        self.buffer_pos = buffer_pos;
        self.current_lsn += 1; // Increment LSN for each record appended
        self.sync_needed = true;
        return self.current_lsn;
    }

    /// Calculate header checksum with explicit field ordering
    fn calculateExplicitHeaderChecksum(header: RecordHeader) u32 {
        var hasher = std.hash.Crc32.init();
        hasher.update(std.mem.asBytes(&header.magic));
        hasher.update(std.mem.asBytes(&header.record_version));
        hasher.update(std.mem.asBytes(&header.record_type));
        hasher.update(std.mem.asBytes(&header.header_len));
        hasher.update(std.mem.asBytes(&header.flags));
        hasher.update(std.mem.asBytes(&header.txn_id));
        hasher.update(std.mem.asBytes(&header.prev_lsn));
        hasher.update(std.mem.asBytes(&header.payload_len));
        hasher.update(std.mem.asBytes(&@as(u32, 0))); // header_crc32c field set to 0
        hasher.update(std.mem.asBytes(&header.payload_crc32c));
        return hasher.final();
    }

    /// Calculate trailer checksum with explicit field ordering
    fn calculateExplicitTrailerChecksum(total_len: u32) u32 {
        var hasher = std.hash.Crc32.init();
        const trailer_magic = @as(u32, 0x52474F4C); // "RGOL"
        hasher.update(std.mem.asBytes(&trailer_magic));
        hasher.update(std.mem.asBytes(&total_len));
        hasher.update(std.mem.asBytes(&@as(u32, 0))); // trailer_crc32c field set to 0
        return hasher.final();
    }

    /// Read header fields explicitly from byte buffer
    fn readExplicitHeader(bytes: []const u8) !RecordHeader {
        if (bytes.len < RecordHeader.SIZE) return error.InvalidHeaderSize;

        var pos: usize = 0;

        const magic = std.mem.littleToNative(u32, std.mem.bytesAsValue(u32, bytes[pos..pos + 4]).*);
        pos += 4;
        const record_version = std.mem.littleToNative(u16, std.mem.bytesAsValue(u16, bytes[pos..pos + 2]).*);
        pos += 2;
        const record_type = std.mem.littleToNative(u16, std.mem.bytesAsValue(u16, bytes[pos..pos + 2]).*);
        pos += 2;
        const header_len = std.mem.littleToNative(u16, std.mem.bytesAsValue(u16, bytes[pos..pos + 2]).*);
        pos += 2;
        const flags = std.mem.littleToNative(u16, std.mem.bytesAsValue(u16, bytes[pos..pos + 2]).*);
        pos += 2;
        const txn_id = std.mem.littleToNative(u64, std.mem.bytesAsValue(u64, bytes[pos..pos + 8]).*);
        pos += 8;
        const prev_lsn = std.mem.littleToNative(u64, std.mem.bytesAsValue(u64, bytes[pos..pos + 8]).*);
        pos += 8;
        const payload_len = std.mem.littleToNative(u32, std.mem.bytesAsValue(u32, bytes[pos..pos + 4]).*);
        pos += 4;
        const header_crc32c = std.mem.littleToNative(u32, std.mem.bytesAsValue(u32, bytes[pos..pos + 4]).*);
        pos += 4;
        const payload_crc32c = std.mem.littleToNative(u32, std.mem.bytesAsValue(u32, bytes[pos..pos + 4]).*);
        pos += 4;

        return RecordHeader{
            .magic = magic,
            .record_version = record_version,
            .record_type = record_type,
            .header_len = header_len,
            .flags = flags,
            .txn_id = txn_id,
            .prev_lsn = prev_lsn,
            .payload_len = payload_len,
            .header_crc32c = header_crc32c,
            .payload_crc32c = payload_crc32c,
        };
    }

    /// Private: Legacy append function for compatibility (deprecated)
    fn appendRecord(self: *Self, header: RecordHeader, data: []const u8) !u64 {
        const new_header = RecordHeader{
            .magic = 0x4C4F4752, // "LOGR"
            .record_version = 0,
            .record_type = header.record_type,
            .header_len = 40,
            .flags = 0,
            .txn_id = @intCast(header.payload_len), // Legacy compatibility
            .prev_lsn = self.current_lsn,
            .payload_len = @intCast(data.len),
            .header_crc32c = 0,
            .payload_crc32c = 0,
        };
        return self.appendRecordWithTrailer(new_header, data);
    }

    /// Flush buffer to file
    pub fn flush(self: *Self) !void {
        if (self.buffer_pos == 0) return;
        _ = try self.file.pwriteAll(self.buffer[0..self.buffer_pos], self.file_pos);
        self.file_pos += self.buffer_pos;
        self.buffer_pos = 0;
    }

    /// Private: Scan existing WAL to find highest LSN (count of records)
    fn scanHighestLsn(file: *const std.fs.File) !u64 {
        var record_count: u64 = 0;
        var file_pos: usize = 0;
        const file_size = try file.getEndPos();

        while (file_pos < file_size) {
            var header_bytes: [RecordHeader.SIZE]u8 = undefined;
            const bytes_read = try file.pread(&header_bytes, file_pos);
            if (bytes_read < RecordHeader.SIZE) break;

            const header = readExplicitHeader(&header_bytes) catch break;
            if (header.magic != 0x4C4F4752) break; // "LOGR"

            // Validate header checksum using explicit calculation
            const expected_header_crc = calculateExplicitHeaderChecksum(header);
            if (header.header_crc32c != expected_header_crc) break;

            record_count += 1;
            file_pos += RecordHeader.SIZE + header.payload_len + RecordTrailer.SIZE;
        }

        return record_count;
    }

    /// Serialize commit record payload per spec/commit_record_v0.md
    pub fn serializeCommitRecord(self: *Self, record: *const txn.CommitRecord) ![]u8 {
        var buffer = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        errdefer buffer.deinit(self.allocator);

        // Write commit payload header
        const payload_header = txn.CommitPayloadHeader{
            .commit_magic = 0x434D4954, // "CMIT"
            .txn_id = record.txn_id,
            .root_page_id = record.root_page_id,
            .op_count = @intCast(record.mutations.len),
            .reserved = 0,
        };
        try payload_header.serialize(buffer.writer(self.allocator));

        
        // Write operations using new encoding with validation
        for (record.mutations) |mutation| {
            switch (mutation) {
                .put => |p| {
                    const op = txn.EncodedOperation{
                        .op_type = 0, // Put
                        .op_flags = 0, // V0 must be 0
                        .key_len = @intCast(p.key.len),
                        .val_len = @intCast(p.value.len),
                        .key_bytes = p.key,
                        .val_bytes = p.value,
                    };
                    try op.validate();
                    try op.serialize(buffer.writer(self.allocator));
                },
                .delete => |d| {
                    const op = txn.EncodedOperation{
                        .op_type = 1, // Delete
                        .op_flags = 0, // V0 must be 0
                        .key_len = @intCast(d.key.len),
                        .val_len = 0, // Must be 0 for delete
                        .key_bytes = d.key,
                        .val_bytes = &[_]u8{},
                    };
                    try op.validate();
                    try op.serialize(buffer.writer(self.allocator));
                },
            }
        }

        return try buffer.toOwnedSlice(self.allocator);
    }

    /// Private: Deserialize commit record payload per spec/commit_record_v0.md
    pub fn deserializeCommitRecord(data: []const u8, allocator: std.mem.Allocator) !txn.CommitRecord {
        if (data.len < txn.CommitPayloadHeader.SIZE) return error.PayloadTooSmall;

        var pos: usize = 0;

        // Read commit payload header
        var fbs = std.io.fixedBufferStream(data);
        const header = try txn.CommitPayloadHeader.deserialize(fbs.reader());
        pos = txn.CommitPayloadHeader.SIZE;

        // Validate that we don't read beyond data
        if (header.op_count > txn.SizeLimits.MAX_OPERATIONS_PER_COMMIT) return error.TooManyOperations;

        var mutations = std.ArrayList(txn.Mutation).initCapacity(allocator, header.op_count) catch unreachable;
        errdefer mutations.deinit(allocator);

        // Read operations with validation
        for (0..header.op_count) |_| {
            // Ensure we have enough bytes for operation header
            if (pos + 1 + 1 + 2 + 4 > data.len) return error.PayloadTruncated;

            const op_type = data[pos];
            pos += 1;
            const op_flags = data[pos];
            pos += 1;
            const key_len = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            const val_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            // Validate operation header
            // Validate before accessing data
            if (op_type > 1) return error.InvalidOperationType;
            if (op_flags != 0) return error.InvalidOperationFlags;
            if (key_len > txn.SizeLimits.MAX_KEY_SIZE) return error.KeyTooLarge;
            if (val_len > txn.SizeLimits.MAX_VALUE_SIZE) return error.ValueTooLarge;

            // Ensure we have enough bytes for key and value data
            if (pos + key_len + val_len > data.len) return error.PayloadTruncated;

            const key = try allocator.dupe(u8, data[pos..pos + key_len]);
            pos += key_len;

            switch (op_type) {
                0 => { // Put
                    if (val_len == 0) return error.PutHasNoValue;
                    const value = try allocator.dupe(u8, data[pos..pos + val_len]);
                    pos += val_len;
                    try mutations.append(allocator, txn.Mutation{ .put = .{ .key = key, .value = value } });
                },
                1 => { // Delete
                    if (val_len != 0) return error.DeleteHasValue;
                    try mutations.append(allocator, txn.Mutation{ .delete = .{ .key = key } });
                },
                else => return error.InvalidOperationType,
            }
        }

        const record = txn.CommitRecord{
            .txn_id = header.txn_id,
            .root_page_id = header.root_page_id,
            .mutations = try mutations.toOwnedSlice(allocator),
            .checksum = 0,
        };

        return txn.CommitRecord{
            .txn_id = record.txn_id,
            .root_page_id = record.root_page_id,
            .mutations = record.mutations,
            .checksum = record.calculatePayloadChecksum(),
        };
    }
};

/// Result of WAL replay
pub const ReplayResult = struct {
    commit_records: std.ArrayList(txn.CommitRecord),
    allocator: std.mem.Allocator,
    last_lsn: u64,
    last_checkpoint_txn_id: u64,
    truncate_lsn: ?u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .commit_records = std.ArrayList(txn.CommitRecord).initCapacity(allocator, 0) catch unreachable,
            .allocator = allocator,
            .last_lsn = 0,
            .last_checkpoint_txn_id = 0,
            .truncate_lsn = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all commit records
        for (self.commit_records.items) |*record| {
            // Free allocated strings in mutations
            for (record.mutations) |mutation| {
                switch (mutation) {
                    .put => |p| {
                        self.allocator.free(p.key);
                        self.allocator.free(p.value);
                    },
                    .delete => |d| {
                        self.allocator.free(d.key);
                    },
                }
            }
            self.allocator.free(record.mutations);
        }
        self.commit_records.deinit(self.allocator);
    }
};

// ==================== Unit Tests ====================

test "WriteAheadLog.create_and_append_commit_record" {
    const test_filename = "test_wal_create.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var wal = try WriteAheadLog.create(test_filename, std.testing.allocator);
    defer wal.deinit();

    // Create a commit record
    const mutations = [_]txn.Mutation{
        txn.Mutation{ .put = .{ .key = "key1", .value = "value1" } },
        txn.Mutation{ .delete = .{ .key = "key2" } },
    };

    var record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 3,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculatePayloadChecksum();

    // Append record
    const lsn = try wal.appendCommitRecord(record);
    try testing.expectEqual(@as(u64, 1), lsn);
    try testing.expectEqual(@as(u64, 1), wal.getCurrentLsn());
}

test "WriteAheadLog.open_existing_finds_correct_lsn" {
    const test_filename = "test_wal_open.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    {
        // Create WAL with some records
        var wal = try WriteAheadLog.create(test_filename, std.testing.allocator);
        defer wal.deinit();

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

        _ = try wal.appendCommitRecord(record);
        _ = try wal.appendCommitRecord(record); // Add second record
    }

    // Open existing WAL
    var wal = try WriteAheadLog.open(test_filename, std.testing.allocator);
    defer wal.deinit();

    // Should find highest LSN from previous session
    try testing.expectEqual(@as(u64, 2), wal.getCurrentLsn());
}

test "WriteAheadLog.replay_reads_commit_records" {
    const test_filename = "test_wal_replay.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    // Create WAL with records
    var wal = try WriteAheadLog.create(test_filename, std.testing.allocator);
    defer wal.deinit();

    const mutations = [_]txn.Mutation{
        txn.Mutation{ .put = .{ .key = "key1", .value = "value1" } },
        txn.Mutation{ .delete = .{ .key = "key2" } },
    };

    var record = txn.CommitRecord{
        .txn_id = 42,
        .root_page_id = 7,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculatePayloadChecksum();

    _ = try wal.appendCommitRecord(record);
    try wal.flush(); // Flush buffer to ensure data is written
    try wal.sync();

    // Replay from beginning
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result = try wal.replayFrom(0, arena.allocator());
    defer result.deinit();

    try testing.expectEqual(@as(u64, 1), result.last_lsn);
    try testing.expectEqual(@as(usize, 1), result.commit_records.items.len);

    const replayed_record = result.commit_records.items[0];
    try testing.expectEqual(@as(u64, 42), replayed_record.txn_id);
    try testing.expectEqual(@as(u64, 7), replayed_record.root_page_id);
    try testing.expectEqual(@as(usize, 2), replayed_record.mutations.len);
}

test "WriteAheadLog.truncate_keeps_specified_lsn" {
    const test_filename = "test_wal_truncate.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    // Create WAL with multiple records
    var wal = try WriteAheadLog.create(test_filename, std.testing.allocator);
    defer wal.deinit();

    const mutations = [_]txn.Mutation{
        txn.Mutation{ .put = .{ .key = "key1", .value = "value1" } },
    };

    var record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 3,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculatePayloadChecksum();

    _ = try wal.appendCommitRecord(record);
    const keep_lsn = try wal.appendCommitRecord(record);
    _ = try wal.appendCommitRecord(record);

    try testing.expectEqual(@as(u64, 3), wal.getCurrentLsn());

    // Truncate to keep only record 2
    try wal.truncate(keep_lsn);

    // Reopen and verify only one record remains
    var wal_reopened = try WriteAheadLog.open(test_filename, std.testing.allocator);
    defer wal_reopened.deinit();

    try testing.expectEqual(@as(u64, 1), wal_reopened.getCurrentLsn());
}

test "WriteAheadLog.deserializeCommitRecord_validation" {
    const test_filename = "test_wal_deserialize_validation.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    // Create WAL with a record
    var wal = try WriteAheadLog.create(test_filename, std.testing.allocator);
    defer wal.deinit();

    const mutations = [_]txn.Mutation{
        txn.Mutation{ .put = .{ .key = "key1", .value = "value1" } },
        txn.Mutation{ .delete = .{ .key = "key2" } },
    };

    var record = txn.CommitRecord{
        .txn_id = 42,
        .root_page_id = 7,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculatePayloadChecksum();

    _ = try wal.appendCommitRecord(record);
    try wal.flush(); // Flush buffer to ensure data is written
    try wal.sync();

    // Replay and verify record can be deserialized
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result = try wal.replayFrom(0, arena.allocator());
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.commit_records.items.len);

    const replayed_record = result.commit_records.items[0];
    try testing.expectEqual(@as(u64, 42), replayed_record.txn_id);
    try testing.expectEqual(@as(u64, 7), replayed_record.root_page_id);
    try testing.expectEqual(@as(usize, 2), replayed_record.mutations.len);
}

const testing = std.testing;
