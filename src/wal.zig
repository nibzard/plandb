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

    const Self = @This();

    /// WAL record header
    const RecordHeader = struct {
        magic: u32 = 0x57414C00, // "WAL\0"
        lsn: u64,
        record_type: RecordType,
        length: u32,
        checksum: u32,

        pub const SIZE: usize = @sizeOf(@This());

        pub fn calculateChecksum(self: @This()) u32 {
            var hasher = std.hash.Crc32.init();
            const temp = RecordHeader{
                .magic = self.magic,
                .lsn = self.lsn,
                .record_type = self.record_type,
                .length = self.length,
                .checksum = 0,
            };
            hasher.update(std.mem.asBytes(&temp));
            return hasher.final();
        }

        pub fn validateChecksum(self: @This()) bool {
            return self.checksum == self.calculateChecksum();
        }
    };

    pub const RecordType = enum(u8) {
        commit = 1,
        checkpoint = 2,
        truncate = 3,
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
        };
    }

    /// Create a new WAL file
    pub fn create(path: []const u8, allocator: std.mem.Allocator) !Self {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
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

        const header = RecordHeader{
            .lsn = self.current_lsn + 1,
            .record_type = .commit,
            .length = @intCast(serialized.len),
            .checksum = 0,
        };

        return self.appendRecord(header, serialized);
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

        var file_pos: usize = 0;
        const file_size = try self.file.getEndPos();

        while (file_pos < file_size) {
            var header_bytes: [RecordHeader.SIZE]u8 = undefined;
            const bytes_read = try self.file.pread(&header_bytes, file_pos);
            if (bytes_read < RecordHeader.SIZE) break;

            const header = std.mem.bytesAsValue(RecordHeader, &header_bytes);
            if (header.magic != 0x57414C00) break;
            if (!header.validateChecksum()) break;
            if (header.lsn < start_lsn) {
                file_pos += RecordHeader.SIZE + header.length;
                continue;
            }

            // Read record data
            const record_data = try allocator.alloc(u8, header.length);
            defer allocator.free(record_data);

            const data_read = try self.file.pread(record_data, file_pos + RecordHeader.SIZE);
            if (data_read < header.length) break;

            switch (header.record_type) {
                .commit => {
                    const commit_record = try WriteAheadLog.deserializeCommitRecord(record_data, allocator);
                    try result.commit_records.append(commit_record);
                },
                .checkpoint => {
                    if (header.length == @sizeOf(u64)) {
                        const checkpoint_txn_id = std.mem.bytesAsValue(u64, record_data);
                        result.last_checkpoint_txn_id = checkpoint_txn_id.*;
                    }
                },
                .truncate => {
                    result.truncate_lsn = header.lsn;
                },
            }

            result.last_lsn = header.lsn;
            file_pos += RecordHeader.SIZE + header.length;
        }

        return result;
    }

    /// Truncate WAL up to a specific LSN
    pub fn truncate(self: *Self, keep_lsn: u64) !void {
        var file_pos: usize = 0;
        const file_size = try self.file.getEndPos();

        // Find position of record with keep_lsn
        while (file_pos < file_size) {
            var header_bytes: [RecordHeader.SIZE]u8 = undefined;
            const bytes_read = try self.file.pread(&header_bytes, file_pos);
            if (bytes_read < RecordHeader.SIZE) break;

            const header = std.mem.bytesAsValue(RecordHeader, &header_bytes);
            if (header.magic != 0x57414C00) break;
            if (!header.validateChecksum()) break;
            if (header.lsn == keep_lsn) {
                // Found the record to keep, truncate everything before it
                try self.file.setEndPos(file_size - file_pos);
                try self.file.seekTo(0);
                return;
            }

            file_pos += RecordHeader.SIZE + header.length;
        }

        // If we didn't find the LSN, truncate everything
        try self.file.setEndPos(0);
        try self.file.seekTo(0);
    }

    /// Private: Append any record type to WAL
    fn appendRecord(self: *Self, header: RecordHeader, data: []const u8) !u64 {
        const record_size = RecordHeader.SIZE + data.len;

        // Check if record fits in buffer
        if (self.buffer_pos + record_size > self.buffer.len) {
            try self.flush();
        }

        // If record is larger than buffer, write directly
        if (record_size > self.buffer.len) {
            const header_with_checksum = RecordHeader{
                .magic = header.magic,
                .lsn = header.lsn,
                .record_type = header.record_type,
                .length = header.length,
                .checksum = header.calculateChecksum(),
            };

            try self.file.writeAll(std.mem.asBytes(&header_with_checksum));
            try self.file.writeAll(data);
            self.current_lsn = header.lsn;
            self.sync_needed = true;
            return header.lsn;
        }

        // Write to buffer
        const header_with_checksum = RecordHeader{
            .magic = header.magic,
            .lsn = header.lsn,
            .record_type = header.record_type,
            .length = header.length,
            .checksum = header.calculateChecksum(),
        };

        @memcpy(self.buffer[self.buffer_pos..self.buffer_pos + RecordHeader.SIZE], std.mem.asBytes(&header_with_checksum));
        self.buffer_pos += RecordHeader.SIZE;

        if (data.len > 0) {
            @memcpy(self.buffer[self.buffer_pos..self.buffer_pos + data.len], data);
            self.buffer_pos += data.len;
        }

        self.current_lsn = header.lsn;
        self.sync_needed = true;
        return header.lsn;
    }

    /// Private: Flush buffer to file
    fn flush(self: *Self) !void {
        if (self.buffer_pos == 0) return;
        _ = try self.file.pwriteAll(self.buffer[0..self.buffer_pos], 0);
        self.buffer_pos = 0;
    }

    /// Private: Scan existing WAL to find highest LSN
    fn scanHighestLsn(file: *const std.fs.File) !u64 {
        var highest_lsn: u64 = 0;
        var file_pos: usize = 0;
        const file_size = try file.getEndPos();

        while (file_pos < file_size) {
            var header_bytes: [RecordHeader.SIZE]u8 = undefined;
            const bytes_read = try file.pread(&header_bytes, file_pos);
            if (bytes_read < RecordHeader.SIZE) break;

            const header = std.mem.bytesAsValue(RecordHeader, &header_bytes);
            if (header.magic != 0x57414C00) break;
            if (!header.validateChecksum()) break;

            if (header.lsn > highest_lsn) {
                highest_lsn = header.lsn;
            }

            file_pos += RecordHeader.SIZE + header.length;
        }

        return highest_lsn;
    }

    /// Private: Serialize commit record
    fn serializeCommitRecord(self: *Self, record: *const txn.CommitRecord) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        // Write header fields
        try buffer.writer().writeInt(u64, record.txn_id, .little);
        try buffer.writer().writeInt(u64, record.parent_txn_id, .little);
        try buffer.writer().writeInt(u64, record.timestamp_ns, .little);

        const mutation_count: u32 = @intCast(record.mutations.len);
        try buffer.writer().writeInt(u32, mutation_count, .little);

        // Write mutations
        for (record.mutations) |mutation| {
            switch (mutation) {
                .put => |p| {
                    const key_len: u32 = @intCast(p.key.len);
                    const val_len: u32 = @intCast(p.value.len);
                    try buffer.writer().writeInt(u32, key_len, .little);
                    try buffer.appendSlice(p.key);
                    try buffer.writer().writeInt(u32, val_len, .little);
                    try buffer.appendSlice(p.value);
                },
                .delete => |d| {
                    const key_len: u32 = @intCast(d.key.len);
                    try buffer.writer().writeInt(u32, key_len, .little);
                    try buffer.appendSlice(d.key);
                },
            }
        }

        return buffer.toOwnedSlice();
    }

    /// Private: Deserialize commit record
    fn deserializeCommitRecord(data: []const u8, allocator: std.mem.Allocator) !txn.CommitRecord {
        var pos: usize = 0;

        const txn_id = std.mem.bytesAsValue(u64, data[pos..pos + 8]).*;
        pos += 8;
        const parent_txn_id = std.mem.bytesAsValue(u64, data[pos..pos + 8]).*;
        pos += 8;
        const timestamp_ns = std.mem.bytesAsValue(u64, data[pos..pos + 8]).*;
        pos += 8;
        const mutation_count = std.mem.bytesAsValue(u32, data[pos..pos + 4]).*;
        pos += 4;

        var mutations = std.ArrayList(txn.Mutation).init(allocator);
        errdefer mutations.deinit();

        for (0..mutation_count) |_| {
            const mutation_type = std.mem.bytesAsValue(u8, data[pos..pos + 1]).*;
            pos += 1;

            switch (mutation_type) {
                0 => { // PUT
                    const key_len = std.mem.bytesAsValue(u32, data[pos..pos + 4]).*;
                    pos += 4;
                    const key = try allocator.dupe(u8, data[pos..pos + key_len]);
                    pos += key_len;
                    const val_len = std.mem.bytesAsValue(u32, data[pos..pos + 4]).*;
                    pos += 4;
                    const value = try allocator.dupe(u8, data[pos..pos + val_len]);
                    pos += val_len;
                    try mutations.append(txn.Mutation{ .put = .{ .key = key, .value = value } });
                },
                1 => { // DELETE
                    const key_len = std.mem.bytesAsValue(u32, data[pos..pos + 4]).*;
                    pos += 4;
                    const key = try allocator.dupe(u8, data[pos..pos + key_len]);
                    pos += key_len;
                    try mutations.append(txn.Mutation{ .delete = .{ .key = key } });
                },
                else => return error.InvalidMutationType,
            }
        }

        const record = txn.CommitRecord{
            .txn_id = txn_id,
            .parent_txn_id = parent_txn_id,
            .timestamp_ns = timestamp_ns,
            .mutations = try mutations.toOwnedSlice(),
            .checksum = 0,
        };

        return txn.CommitRecord{
            .txn_id = record.txn_id,
            .parent_txn_id = record.parent_txn_id,
            .timestamp_ns = record.timestamp_ns,
            .mutations = record.mutations,
            .checksum = record.calculateChecksum(),
        };
    }
};

/// Result of WAL replay
pub const ReplayResult = struct {
    commit_records: std.ArrayList(txn.CommitRecord),
    last_lsn: u64,
    last_checkpoint_txn_id: u64,
    truncate_lsn: ?u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .commit_records = std.ArrayList(txn.CommitRecord).init(allocator),
            .last_lsn = 0,
            .last_checkpoint_txn_id = 0,
            .truncate_lsn = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all commit records
        for (self.commit_records.items) |*record| {
            self.commit_records.allocator.free(record.mutations);

            // Free allocated strings in mutations
            for (record.mutations) |mutation| {
                switch (mutation) {
                    .put => |p| {
                        self.commit_records.allocator.free(p.key);
                        self.commit_records.allocator.free(p.value);
                    },
                    .delete => |d| {
                        self.commit_records.allocator.free(d.key);
                    },
                }
            }
        }
        self.commit_records.deinit();
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
        .parent_txn_id = 0,
        .timestamp_ns = 1234567890,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculateChecksum();

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
            .parent_txn_id = 0,
            .timestamp_ns = 1234567890,
            .mutations = &mutations,
            .checksum = 0,
        };
        record.checksum = record.calculateChecksum();

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
        .parent_txn_id = 1,
        .timestamp_ns = 1234567890,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculateChecksum();

    _ = try wal.appendCommitRecord(record);
    try wal.sync();

    // Replay from beginning
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try wal.replayFrom(0, arena.allocator());
    defer result.deinit();

    try testing.expectEqual(@as(u64, 1), result.last_lsn);
    try testing.expectEqual(@as(usize, 1), result.commit_records.items.len);

    const replayed_record = result.commit_records.items[0];
    try testing.expectEqual(@as(u64, 42), replayed_record.txn_id);
    try testing.expectEqual(@as(u64, 1), replayed_record.parent_txn_id);
    try testing.expectEqual(@as(u64, 1234567890), replayed_record.timestamp_ns);
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
        .parent_txn_id = 0,
        .timestamp_ns = 1234567890,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculateChecksum();

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

const testing = std.testing;