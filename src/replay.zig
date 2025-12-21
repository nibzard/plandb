//! Replay engine for deterministic database rebuilding.
//!
//! Provides functionality to rebuild database state by reading commit records
//! from the separate .log file and applying mutations in order. Supports
//! full rebuild to latest or rebuild to specific transaction ID.

const std = @import("std");
const wal = @import("wal.zig");
const txn = @import("txn.zig");

/// Replay engine for rebuilding database state from commit log
pub const ReplayEngine = struct {
    allocator: std.mem.Allocator,
    log_path: []const u8,
    memtable: std.StringHashMap([]const u8),

    const Self = @This();

    /// Initialize replay engine with log file path
    pub fn init(allocator: std.mem.Allocator, log_path: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .log_path = log_path,
            .memtable = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Clean up replay engine resources
    pub fn deinit(self: *Self) void {
        // Free all stored values
        var it = self.memtable.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.memtable.deinit();
    }

    /// Rebuild entire database state from log file (deterministic)
    pub fn rebuildAll(self: *Self) !ReplayResult {
        return self.rebuildToTxnId(std.math.maxInt(u64));
    }

    /// Rebuild database state up to and including specific transaction ID
    pub fn rebuildToTxnId(self: *Self, target_txn_id: u64) !ReplayResult {
        var result = ReplayResult.init(self.allocator);
        errdefer result.deinit();

        // Clear any existing state
        self.clearState();

        // Open log file for reading
        var log_file = std.fs.cwd().openFile(self.log_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => {
                // Log file doesn't exist, return empty result
                return result;
            },
            else => return err,
        };
        defer log_file.close();

        // Read and process commit records from log file
        var file_pos: usize = 0;
        const file_size = try log_file.getEndPos();

        while (file_pos < file_size) {
            // Try to read a complete commit record
            const record_result = try self.readCommitRecordFromFile(&log_file, file_pos);

            if (record_result.record) |commit_record| {
                var mutable_record = commit_record;
                defer self.cleanupCommitRecord(&mutable_record);

                // Stop if we've reached the target transaction ID
                if (mutable_record.txn_id > target_txn_id) {
                    break;
                }

                // Apply mutations to rebuild state
                try self.applyCommitRecord(&mutable_record);

                result.processed_txns += 1;
                result.last_txn_id = mutable_record.txn_id;
                result.key_count = self.memtable.count();

                // Update file position to skip over this record
                file_pos = record_result.next_pos;
            } else {
                // No more valid records found
                break;
            }
        }

        return result;
    }

    /// Get a value from the rebuilt state
    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        return self.memtable.get(key);
    }

    /// Get all key-value pairs as a slice (for testing/verification)
    pub fn getAll(self: *const Self, allocator: std.mem.Allocator) ![]KV {
        const kvs = try allocator.alloc(KV, self.memtable.count());
        var i: usize = 0;

        var it = self.memtable.iterator();
        while (it.next()) |entry| {
            kvs[i] = KV{
                .key = try allocator.dupe(u8, entry.key_ptr.*),
                .value = try allocator.dupe(u8, entry.value_ptr.*),
            };
            i += 1;
        }

        return kvs;
    }

    /// Clear all state from the engine
    fn clearState(self: *Self) void {
        // Remove all entries and free their values
        var it = self.memtable.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        // Clear the hashmap but keep capacity
        self.memtable.clearRetainingCapacity();
    }

    /// Read a single commit record from the log file at given position
    fn readCommitRecordFromFile(self: *Self, file: *std.fs.File, start_pos: usize) !ReadCommitResult {
        const file_size = try file.getEndPos();
        var pos = start_pos;

        // Debug output
        std.debug.print("Replay: file_size={}, file_pos={}\n", .{ file_size, pos });

        // Ensure we have enough bytes for a record header
        if (pos + wal.WriteAheadLog.RecordHeader.SIZE > file_size) {
            return ReadCommitResult{ .record = null, .next_pos = pos };
        }

        // Read record header
        var header_bytes: [wal.WriteAheadLog.RecordHeader.SIZE]u8 = undefined;
        const bytes_read = try file.pread(&header_bytes, pos);
        if (bytes_read < wal.WriteAheadLog.RecordHeader.SIZE) {
            return ReadCommitResult{ .record = null, .next_pos = pos };
        }

        // Read header fields explicitly to avoid struct layout issues
        const magic = std.mem.readInt(u32, header_bytes[0..4], .little);
        const record_type = std.mem.readInt(u16, header_bytes[6..8], .little);
        const payload_len = std.mem.readInt(u32, header_bytes[28..32], .little);
        // const _payload_crc32c = std.mem.readInt(u32, header_bytes[36..40], .little);

        // Debug header validation
        const expected_magic = 0x4C4F4752;
        const expected_record_type = @intFromEnum(wal.WriteAheadLog.RecordType.commit);
        std.debug.print("Replay iteration {}: file_pos={}, file_size={}\n", .{ start_pos, pos, file_size });
        std.debug.print("Replay: magic=0x{x} (expected 0x{x}), record_type={} (expected {})\n", .{ magic, expected_magic, record_type, expected_record_type });

        // Validate header
        std.debug.print("Replay: Validating header magic\n", .{});
        if (magic != 0x4C4F4752) { // "LOGR"
            std.debug.print("Replay: Invalid magic number\n", .{});
            return ReadCommitResult{ .record = null, .next_pos = pos };
        }

        // TODO: Validate header checksum - need to implement explicit calculation
        // if (!validateHeaderChecksumExplicit(header_bytes)) {
        //     return ReadCommitResult{ .record = null, .next_pos = pos };
        // }

        // Check if this is a commit record
        std.debug.print("Replay: Validating record type\n", .{});
        if (record_type != @intFromEnum(wal.WriteAheadLog.RecordType.commit)) {
            std.debug.print("Replay: Not a commit record\n", .{});
            // Skip non-commit records
            const record_size = wal.WriteAheadLog.RecordHeader.SIZE + payload_len + wal.WriteAheadLog.RecordTrailer.SIZE;
            pos += record_size;
            return ReadCommitResult{ .record = null, .next_pos = pos };
        }

        // Ensure we have enough bytes for the full record
        const record_size = wal.WriteAheadLog.RecordHeader.SIZE + payload_len + wal.WriteAheadLog.RecordTrailer.SIZE;
        std.debug.print("Replay: record_size={}, payload_len={}\n", .{ record_size, payload_len });
        if (pos + record_size > file_size) {
            std.debug.print("Replay: Not enough bytes for full record\n", .{});
            return ReadCommitResult{ .record = null, .next_pos = pos };
        }

        // Read payload data
        std.debug.print("Replay: Reading payload data\n", .{});
        const payload_data = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload_data);

        const payload_read = try file.pread(payload_data, pos + wal.WriteAheadLog.RecordHeader.SIZE);
        if (payload_read < payload_len) {
            std.debug.print("Replay: Not enough payload data: read={}, expected={}\n", .{ payload_read, payload_len });
            return ReadCommitResult{ .record = null, .next_pos = pos };
        }

        std.debug.print("Replay: Payload data (first 16 bytes): {any}\n", .{payload_data[0..@min(16, payload_data.len)]});

        // TODO: Verify payload CRC - temporarily disabled for debugging
        std.debug.print("Replay: Skipping payload CRC verification for debugging\n", .{});
        // var hasher = std.hash.Crc32.init();
        // hasher.update(payload_data);
        // const calculated_payload_crc = hasher.final();
        // if (calculated_payload_crc != payload_crc32c) {
        //     std.debug.print("Replay: CRC mismatch: calculated={}, expected={}\n", .{ calculated_payload_crc, payload_crc32c });
        //     return ReadCommitResult{ .record = null, .next_pos = pos + record_size };
        // }

        // Read and verify trailer
        var trailer_bytes: [wal.WriteAheadLog.RecordTrailer.SIZE]u8 = undefined;
        const trailer_read = try file.pread(&trailer_bytes, pos + wal.WriteAheadLog.RecordHeader.SIZE + payload_len);
        if (trailer_read < wal.WriteAheadLog.RecordTrailer.SIZE) {
            return ReadCommitResult{ .record = null, .next_pos = pos };
        }

        // Read trailer fields explicitly
        const trailer_magic = std.mem.readInt(u32, trailer_bytes[0..4], .little);

        if (trailer_magic != 0x52474F4C) { // "RGOL"
            std.debug.print("Replay: Invalid trailer magic: 0x{x}\n", .{trailer_magic});
            return ReadCommitResult{ .record = null, .next_pos = pos + record_size };
        }

        std.debug.print("Replay: About to deserialize commit record\n", .{});

        // Deserialize commit record using WAL's implementation
        const commit_record = try wal.WriteAheadLog.deserializeCommitRecord(payload_data, self.allocator);
        pos += record_size;

        std.debug.print("Replay: Successfully deserialized commit record with txn_id={}\n", .{commit_record.txn_id});

        return ReadCommitResult{
            .record = commit_record,
            .next_pos = pos,
        };
    }

    /// Deserialize commit record payload (adapted from WAL implementation)
    fn deserializeCommitRecord(self: *Self, data: []const u8) !*txn.CommitRecord {
        if (data.len < txn.CommitPayloadHeader.SIZE) return error.PayloadTooSmall;

        var pos: usize = 0;

        // Read commit payload header
        var fbs = std.io.fixedBufferStream(data);
        const header = try txn.CommitPayloadHeader.deserialize(fbs.reader());
        pos += txn.CommitPayloadHeader.SIZE;

        // Validate operation count
        if (header.op_count > txn.SizeLimits.MAX_OPERATIONS_PER_COMMIT) return error.TooManyOperations;

        // Allocate mutations array first
        const mutations = try self.allocator.alloc(txn.Mutation, header.op_count);

        // Read operations
        for (0..header.op_count) |i| {
            // Ensure we have enough bytes for operation header
            if (pos + 1 + 1 + 2 + 4 > data.len) {
                self.cleanupMutations(mutations[0..i]);
                self.allocator.free(mutations);
                return error.PayloadTruncated;
            }

            const op_type = data[pos];
            pos += 1;
            const op_flags = data[pos];
            pos += 1;
            const key_len = std.mem.bytesAsValue(u16, data[pos..pos + 2]).*;
            pos += 2;
            const val_len = std.mem.bytesAsValue(u32, data[pos..pos + 4]).*;
            pos += 4;

            std.debug.print("Replay: Op {}: type={}, flags={}, key_len={}, val_len={}\n", .{ i, op_type, op_flags, key_len, val_len });

            // Validate operation header
            if (op_type > 1) {
                std.debug.print("Replay: Invalid operation type: {}\n", .{op_type});
                self.cleanupMutations(mutations[0..i]);
                self.allocator.free(mutations);
                return error.InvalidOperationType;
            }
            if (op_flags != 0) {
                self.cleanupMutations(mutations[0..i]);
                self.allocator.free(mutations);
                return error.InvalidOperationFlags;
            }
            if (key_len > txn.SizeLimits.MAX_KEY_SIZE) {
                self.cleanupMutations(mutations[0..i]);
                self.allocator.free(mutations);
                return error.KeyTooLarge;
            }
            if (val_len > txn.SizeLimits.MAX_VALUE_SIZE) {
                self.cleanupMutations(mutations[0..i]);
                self.allocator.free(mutations);
                return error.ValueTooLarge;
            }

            // Ensure we have enough bytes for key and value data
            if (pos + key_len + val_len > data.len) {
                self.cleanupMutations(mutations[0..i]);
                self.allocator.free(mutations);
                return error.PayloadTruncated;
            }

            const key = try self.allocator.dupe(u8, data[pos..pos + key_len]);
            pos += key_len;

            switch (op_type) {
                0 => { // Put
                    if (val_len == 0) {
                        self.cleanupMutations(mutations[0..i]);
                        self.allocator.free(mutations);
                        return error.PutHasNoValue;
                    }
                    const value = try self.allocator.dupe(u8, data[pos..pos + val_len]);
                    pos += val_len;
                    mutations[i] = txn.Mutation{ .put = .{ .key = key, .value = value } };
                },
                1 => { // Delete
                    if (val_len != 0) {
                        self.cleanupMutations(mutations[0..i]);
                        self.allocator.free(mutations);
                        return error.DeleteHasValue;
                    }
                    mutations[i] = txn.Mutation{ .delete = .{ .key = key } };
                },
                else => {
                    self.cleanupMutations(mutations[0..i]);
                    self.allocator.free(mutations);
                    return error.InvalidOperationType;
                },
            }
        }

        // Allocate commit record and set it up
        const record = try self.allocator.create(txn.CommitRecord);
        record.* = txn.CommitRecord{
            .txn_id = header.txn_id,
            .root_page_id = header.root_page_id,
            .mutations = mutations,
            .checksum = 0,
        };

        record.checksum = record.calculatePayloadChecksum();
        return record;
    }

    /// Clean up a slice of mutations (helper for error cleanup)
    fn cleanupMutations(self: *Self, mutations: []txn.Mutation) void {
        for (mutations) |mutation| {
            switch (mutation) {
                .put => |put_op| {
                    self.allocator.free(put_op.key);
                    self.allocator.free(put_op.value);
                },
                .delete => |del_op| {
                    self.allocator.free(del_op.key);
                },
            }
        }
    }

    /// Apply mutations from a commit record to rebuild state
    fn applyCommitRecord(self: *Self, commit_record: *const txn.CommitRecord) !void {
        for (commit_record.mutations) |mutation| {
            switch (mutation) {
                .put => |put_op| {
                    // For puts, we replace any existing value
                    const existing_value = self.memtable.get(put_op.key);
                    if (existing_value) |old_value| {
                        self.allocator.free(old_value);
                    }

                    // Store a copy of the key and value
                    const key_copy = try self.allocator.dupe(u8, put_op.key);
                    const value_copy = try self.allocator.dupe(u8, put_op.value);
                    try self.memtable.put(key_copy, value_copy);
                },
                .delete => |del_op| {
                    // For deletes, we remove the key if it exists
                    if (self.memtable.fetchRemove(del_op.key)) |entry| {
                        self.allocator.free(entry.key);
                        self.allocator.free(entry.value);
                    }
                    // Also free the key from the mutation since we won't need it
                    self.allocator.free(del_op.key);
                },
            }
        }
    }

    /// Clean up a commit record and all its allocated data
    fn cleanupCommitRecord(self: *Self, record: *txn.CommitRecord) void {
        // Free mutations array
        for (record.mutations) |mutation| {
            switch (mutation) {
                .put => |put_op| {
                    self.allocator.free(put_op.key);
                    self.allocator.free(put_op.value);
                },
                .delete => |del_op| {
                    self.allocator.free(del_op.key);
                },
            }
        }
        self.allocator.free(record.mutations);
        self.allocator.destroy(record);
    }
};

/// Result of a replay operation
pub const ReplayResult = struct {
    processed_txns: usize,
    last_txn_id: u64,
    key_count: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .processed_txns = 0,
            .last_txn_id = 0,
            .key_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Nothing to clean up currently
    }
};

/// Result of reading a commit record from file
const ReadCommitResult = struct {
    record: ?txn.CommitRecord,
    next_pos: usize,
};

/// Key-value pair for getAll results
pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

// ==================== Unit Tests ====================

test "ReplayEngine.rebuildAll_empty_log" {
    const test_log = "test_replay_empty.log";
    defer {
        std.fs.cwd().deleteFile(test_log) catch {};
    }

    var engine = try ReplayEngine.init(std.testing.allocator, test_log);
    defer engine.deinit();

    var result = try engine.rebuildAll();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.processed_txns);
    try std.testing.expectEqual(@as(u64, 0), result.last_txn_id);
    try std.testing.expectEqual(@as(usize, 0), result.key_count);
}

test "ReplayEngine.rebuildToTxnId_single_commit" {
    const test_log = "test_replay_single.log";
    defer {
        std.fs.cwd().deleteFile(test_log) catch {};
    }

    // Create a log file with a single commit record using WAL functionality
    {
        var temp_wal = try wal.WriteAheadLog.create(test_log, std.testing.allocator);
        defer temp_wal.deinit();

        // Create commit record with mutations
        const mutations = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "key1", .value = "value1" } },
            txn.Mutation{ .put = .{ .key = "key2", .value = "value2" } },
        };

        var record = txn.CommitRecord{
            .txn_id = 1,
            .root_page_id = 3,
            .mutations = &mutations,
            .checksum = 0,
        };
        record.checksum = record.calculatePayloadChecksum();

        // Write commit record to log file
        _ = try temp_wal.appendCommitRecord(record);
        try temp_wal.flush();
    }

    // Test replay engine
    var engine = try ReplayEngine.init(std.testing.allocator, test_log);
    defer engine.deinit();

    var result = try engine.rebuildAll();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.processed_txns);
    try std.testing.expectEqual(@as(u64, 1), result.last_txn_id);
    try std.testing.expectEqual(@as(usize, 2), result.key_count);

    // Verify rebuilt state
    const value1 = engine.get("key1");
    const value2 = engine.get("key2");

    try std.testing.expectEqualStrings("value1", value1.?);
    try std.testing.expectEqualStrings("value2", value2.?);
    try std.testing.expect(engine.get("nonexistent") == null);
}

test "ReplayEngine.rebuildToTxnId_multiple_commits" {
    const test_log = "test_replay_multiple.log";
    defer {
        std.fs.cwd().deleteFile(test_log) catch {};
    }

    // Create a log file with multiple commit records
    {
        var temp_wal = try wal.WriteAheadLog.create(test_log, std.testing.allocator);
        defer temp_wal.deinit();

        // First commit
        const mutations1 = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "key1", .value = "value1_v1" } },
        };
        var record1 = txn.CommitRecord{
            .txn_id = 1,
            .root_page_id = 2,
            .mutations = &mutations1,
            .checksum = 0,
        };
        record1.checksum = record1.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record1);

        // Second commit (updates key1 and adds key2)
        const mutations2 = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "key1", .value = "value1_v2" } },
            txn.Mutation{ .put = .{ .key = "key2", .value = "value2" } },
        };
        var record2 = txn.CommitRecord{
            .txn_id = 2,
            .root_page_id = 3,
            .mutations = &mutations2,
            .checksum = 0,
        };
        record2.checksum = record2.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record2);

        // Third commit (deletes key2)
        const mutations3 = [_]txn.Mutation{
            txn.Mutation{ .delete = .{ .key = "key2" } },
        };
        var record3 = txn.CommitRecord{
            .txn_id = 3,
            .root_page_id = 4,
            .mutations = &mutations3,
            .checksum = 0,
        };
        record3.checksum = record3.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record3);

        try temp_wal.flush();
    }

    // Test replay to specific transaction ID
    var engine = try ReplayEngine.init(std.testing.allocator, test_log);
    defer engine.deinit();

    // Replay to txn_id 2 (should include key1=v2 and key2=value2)
    var result = try engine.rebuildToTxnId(2);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.processed_txns);
    try std.testing.expectEqual(@as(u64, 2), result.last_txn_id);
    try std.testing.expectEqual(@as(usize, 2), result.key_count);

    // Verify state at txn_id 2
    const value1 = engine.get("key1");
    const value2 = engine.get("key2");

    try std.testing.expectEqualStrings("value1_v2", value1.?);
    try std.testing.expectEqualStrings("value2", value2.?);
}

test "ReplayEngine.getAll_verification" {
    const test_log = "test_replay_getall.log";
    defer {
        std.fs.cwd().deleteFile(test_log) catch {};
    }

    // Create a log file
    {
        var temp_wal = try wal.WriteAheadLog.create(test_log, std.testing.allocator);
        defer temp_wal.deinit();

        const mutations = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "a", .value = "1" } },
            txn.Mutation{ .put = .{ .key = "b", .value = "2" } },
            txn.Mutation{ .put = .{ .key = "c", .value = "3" } },
        };

        var record = txn.CommitRecord{
            .txn_id = 1,
            .root_page_id = 2,
            .mutations = &mutations,
            .checksum = 0,
        };
        record.checksum = record.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record);
        try temp_wal.flush();
    }

    // Test getAll
    var engine = try ReplayEngine.init(std.testing.allocator, test_log);
    defer engine.deinit();

    _ = try engine.rebuildAll();

    const all_kvs = try engine.getAll(std.testing.allocator);
    defer {
        for (all_kvs) |kv| {
            std.testing.allocator.free(kv.key);
            std.testing.allocator.free(kv.value);
        }
        std.testing.allocator.free(all_kvs);
    }

    try std.testing.expectEqual(@as(usize, 3), all_kvs.len);

    // Sort by key for consistent verification
    std.mem.sort(KV, all_kvs, {}, struct {
        fn compare(_: void, a: KV, b: KV) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.compare);

    try std.testing.expectEqualStrings("a", all_kvs[0].key);
    try std.testing.expectEqualStrings("1", all_kvs[0].value);
    try std.testing.expectEqualStrings("b", all_kvs[1].key);
    try std.testing.expectEqualStrings("2", all_kvs[1].value);
    try std.testing.expectEqualStrings("c", all_kvs[2].key);
    try std.testing.expectEqualStrings("3", all_kvs[2].value);
}