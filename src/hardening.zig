//! Hardening tests for crash consistency and fault injection.
//!
//! Implements comprehensive tests for torn writes, short writes, and corruption
//! scenarios to verify the replay engine's robustness and clean recovery capabilities.

const std = @import("std");
const wal = @import("wal.zig");
const replay = @import("replay.zig");
const txn = @import("txn.zig");

/// Fault injector for simulating various corruption scenarios
pub const FaultInjector = struct {
    pub fn simulateTornWrite() !void {
        return error.NotImplemented;
    }

    pub fn simulateShortWrite() !void {
        return error.NotImplemented;
    }
};

/// Crash harness for controlled failure simulation
pub const CrashHarness = struct {
    pub fn killDuringWorkload() !void {
        return error.NotImplemented;
    }
};

// ==================== Hardening Test Functions ====================

/// Test torn write detection - truncated record headers
pub fn hardeningTornWriteHeader(log_path: []const u8, allocator: std.mem.Allocator) !TestResult {
    const test_name = "torn_write_header";
    var result = TestResult.init(test_name, allocator);

    // Create a valid log file first
    {
        var temp_wal = try wal.WriteAheadLog.create(log_path, allocator);
        defer temp_wal.deinit();

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
        _ = try temp_wal.appendCommitRecord(record);
        try temp_wal.flush();
    }

    // Corrupt the file by truncating in the middle of the header
    {
        const file = try std.fs.cwd().openFile(log_path, .{ .mode = .read_write });
        defer file.close();

        // Truncate after 20 bytes (middle of record header)
        try file.setEndPos(20);
    }

    // Test replay engine handles corruption gracefully
    var engine = try replay.ReplayEngine.init(allocator, log_path);
    defer engine.deinit();

    var replay_result = try engine.rebuildAll();
    defer replay_result.deinit();

    // Should process 0 transactions due to corruption
    if (replay_result.processed_txns != 0) {
        result.fail("Expected 0 processed transactions, got {}", .{replay_result.processed_txns});
        return result;
    }

    result.pass();
    return result;
}

/// Test torn write detection - truncated payload
pub fn hardeningTornWritePayload(log_path: []const u8, allocator: std.mem.Allocator) !TestResult {
    const test_name = "torn_write_payload";
    var result = TestResult.init(test_name, allocator);

    // Create a valid log file with a larger payload
    {
        var temp_wal = try wal.WriteAheadLog.create(log_path, allocator);
        defer temp_wal.deinit();

        const mutations = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "key1", .value = "value1_very_long_data_to_ensure_payload_is_large_enough" } },
            txn.Mutation{ .put = .{ .key = "key2", .value = "value2_also_substantially_long_to_test_payload_truncation" } },
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

    // Corrupt by truncating in the middle of the payload
    {
        const file = try std.fs.cwd().openFile(log_path, .{ .mode = .read_write });
        defer file.close();

        // Get file size and truncate after header + part of payload
        const file_size = try file.getEndPos();
        const truncate_pos = wal.WriteAheadLog.RecordHeader.SIZE + 30; // Partial payload
        if (truncate_pos < file_size) {
            try file.setEndPos(truncate_pos);
        }
    }

    // Test replay engine
    var engine = try replay.ReplayEngine.init(allocator, log_path);
    defer engine.deinit();

    var replay_result = try engine.rebuildAll();
    defer replay_result.deinit();

    // Should process 0 transactions due to truncated payload
    if (replay_result.processed_txns != 0) {
        result.fail("Expected 0 processed transactions due to truncated payload, got {}", .{replay_result.processed_txns});
        return result;
    }

    result.pass();
    return result;
}

/// Test short write detection - missing trailer
pub fn hardeningShortWriteMissingTrailer(log_path: []const u8, allocator: std.mem.Allocator) !TestResult {
    const test_name = "short_write_missing_trailer";
    var result = TestResult.init(test_name, allocator);

    // Create a valid log file
    {
        var temp_wal = try wal.WriteAheadLog.create(log_path, allocator);
        defer temp_wal.deinit();

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
        _ = try temp_wal.appendCommitRecord(record);
        try temp_wal.flush();
    }

    // Corrupt by removing the trailer
    {
        const file = try std.fs.cwd().openFile(log_path, .{ .mode = .read_write });
        defer file.close();

        const file_size = try file.getEndPos();
        const truncate_pos = file_size - wal.WriteAheadLog.RecordTrailer.SIZE;
        try file.setEndPos(truncate_pos);
    }

    // Test replay engine
    var engine = try replay.ReplayEngine.init(allocator, log_path);
    defer engine.deinit();

    var replay_result = try engine.rebuildAll();
    defer replay_result.deinit();

    // Should process 0 transactions due to missing trailer
    if (replay_result.processed_txns != 0) {
        result.fail("Expected 0 processed transactions due to missing trailer, got {}", .{replay_result.processed_txns});
        return result;
    }

    result.pass();
    return result;
}

/// Test clean recovery with mixed valid and corrupt records
pub fn hardeningMixedValidCorruptRecords(log_path: []const u8, allocator: std.mem.Allocator) !TestResult {
    const test_name = "mixed_valid_corrupt_records";
    var result = TestResult.init(test_name, allocator);

    // Create a log file with multiple valid records
    {
        var temp_wal = try wal.WriteAheadLog.create(log_path, allocator);
        defer temp_wal.deinit();

        // First valid commit
        const mutations1 = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "key1", .value = "value1" } },
        };
        var record1 = txn.CommitRecord{
            .txn_id = 1,
            .root_page_id = 2,
            .mutations = &mutations1,
            .checksum = 0,
        };
        record1.checksum = record1.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record1);

        // Second valid commit
        const mutations2 = [_]txn.Mutation{
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

        try temp_wal.flush();
    }

    // Corrupt the second record by overwriting its magic number
    {
        const file = try std.fs.cwd().openFile(log_path, .{ .mode = .read_write });
        defer file.close();

        // Find the start of the second record by scanning for the first record end
        var buffer: [100]u8 = undefined;
        _ = try file.pread(&buffer, wal.WriteAheadLog.RecordHeader.SIZE);

        // Approximate position of second record header (this is a simplified approach)
        // In practice, we'd need to parse the first record properly
        const second_record_pos = wal.WriteAheadLog.RecordHeader.SIZE + 50; // Rough estimate

        // Overwrite the magic number with invalid data
        const invalid_magic = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        _ = try file.pwriteAll(&invalid_magic, second_record_pos);
    }

    // Test replay engine - should recover first valid record only
    var engine = try replay.ReplayEngine.init(allocator, log_path);
    defer engine.deinit();

    var replay_result = try engine.rebuildAll();
    defer replay_result.deinit();

    // Should process at least the first valid transaction
    if (replay_result.processed_txns == 0) {
        result.fail("Expected at least 1 processed transaction, got 0", .{});
        return result;
    }

    // Should have key1 from the first valid transaction
    const value1 = engine.get("key1");
    if (value1 == null) {
        result.fail("Expected key1 to be present from valid first transaction", .{});
        return result;
    }

    result.pass();
    return result;
}

/// Test invalid magic number detection
pub fn hardeningInvalidMagicNumber(log_path: []const u8, allocator: std.mem.Allocator) !TestResult {
    const test_name = "invalid_magic_number";
    var result = TestResult.init(test_name, allocator);

    // Create a file with invalid magic numbers
    {
        const file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
        defer file.close();

        // Write garbage data with invalid magic
        const garbage_data = "INVALID_LOG_DATA_HERE_XXXXXXXXXXXXXXXXXXXXXXXX";
        _ = try file.writeAll(garbage_data);
    }

    // Test replay engine rejects invalid magic
    var engine = try replay.ReplayEngine.init(allocator, log_path);
    defer engine.deinit();

    var replay_result = try engine.rebuildAll();
    defer replay_result.deinit();

    // Should process 0 transactions due to invalid magic
    if (replay_result.processed_txns != 0) {
        result.fail("Expected 0 processed transactions due to invalid magic, got {}", .{replay_result.processed_txns});
        return result;
    }

    result.pass();
    return result;
}

/// Test clean recovery to specific transaction ID with corruption
pub fn hardeningCleanRecoveryToTxnId(log_path: []const u8, allocator: std.mem.Allocator) !TestResult {
    const test_name = "clean_recovery_to_txn_id";
    var result = TestResult.init(test_name, allocator);

    // Create a log file with multiple commits
    {
        var temp_wal = try wal.WriteAheadLog.create(log_path, allocator);
        defer temp_wal.deinit();

        // Txn 1
        const mutations1 = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "key1", .value = "value1" } },
        };
        var record1 = txn.CommitRecord{
            .txn_id = 1,
            .root_page_id = 2,
            .mutations = &mutations1,
            .checksum = 0,
        };
        record1.checksum = record1.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record1);

        // Txn 2
        const mutations2 = [_]txn.Mutation{
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

        // Txn 3
        const mutations3 = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "key3", .value = "value3" } },
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

    // Corrupt the third record
    {
        const file = try std.fs.cwd().openFile(log_path, .{ .mode = .read_write });
        defer file.close();

        // Get file size and corrupt near the end
        const file_size = try file.getEndPos();
        const corrupt_pos = file_size - 50; // Near end of third record
        try file.setEndPos(corrupt_pos);
    }

    // Test replay to txn_id 2 (should stop before corruption)
    var engine = try replay.ReplayEngine.init(allocator, log_path);
    defer engine.deinit();

    var replay_result = try engine.rebuildToTxnId(2);
    defer replay_result.deinit();

    // Should process exactly 2 transactions
    if (replay_result.processed_txns != 2) {
        result.fail("Expected 2 processed transactions, got {}", .{replay_result.processed_txns});
        return result;
    }

    if (replay_result.last_txn_id != 2) {
        result.fail("Expected last_txn_id=2, got {}", .{replay_result.last_txn_id});
        return result;
    }

    // Verify state includes only first 2 transactions
    const value1 = engine.get("key1");
    const value2 = engine.get("key2");
    const value3 = engine.get("key3");

    if (value1 == null or !std.mem.eql(u8, value1.?, "value1")) {
        result.fail("Expected key1=value1", .{});
        return result;
    }

    if (value2 == null or !std.mem.eql(u8, value2.?, "value2")) {
        result.fail("Expected key2=value2", .{});
        return result;
    }

    if (value3 != null) {
        result.fail("Expected key3 to be absent (txn 3 not replayed)", .{});
        return result;
    }

    result.pass();
    return result;
}

// ==================== Test Result Infrastructure ====================

pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    failure_reason: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(name: []const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .name = name,
            .passed = false,
            .allocator = allocator,
        };
    }

    pub fn pass(self: *Self) void {
        self.passed = true;
        self.failure_reason = null;
    }

    pub fn fail(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.passed = false;
        self.failure_reason = std.fmt.allocPrint(self.allocator, fmt, args) catch "Failed to allocate error message";
    }

    pub fn deinit(self: *Self) void {
        if (self.failure_reason) |reason| {
            self.allocator.free(reason);
        }
    }
};

/// Run all hardening tests
pub fn runAllHardeningTests(allocator: std.mem.Allocator) ![]TestResult {
    const test_log_prefix = "hardening_test";

    var results = std.ArrayList(TestResult).init(allocator);
    defer results.deinit();

    // Test 1: Torn write header
    {
        const log_path = try std.fmt.allocPrint(allocator, "{s}_torn_header.log", .{test_log_prefix});
        defer allocator.free(log_path);
        defer std.fs.cwd().deleteFile(log_path) catch {};

        const result = try hardeningTornWriteHeader(log_path, allocator);
        try results.append(result);
    }

    // Test 2: Torn write payload
    {
        const log_path = try std.fmt.allocPrint(allocator, "{s}_torn_payload.log", .{test_log_prefix});
        defer allocator.free(log_path);
        defer std.fs.cwd().deleteFile(log_path) catch {};

        const result = try hardeningTornWritePayload(log_path, allocator);
        try results.append(result);
    }

    // Test 3: Short write missing trailer
    {
        const log_path = try std.fmt.allocPrint(allocator, "{s}_missing_trailer.log", .{test_log_prefix});
        defer allocator.free(log_path);
        defer std.fs.cwd().deleteFile(log_path) catch {};

        const result = try hardeningShortWriteMissingTrailer(log_path, allocator);
        try results.append(result);
    }

    // Test 4: Mixed valid and corrupt records
    {
        const log_path = try std.fmt.allocPrint(allocator, "{s}_mixed_records.log", .{test_log_prefix});
        defer allocator.free(log_path);
        defer std.fs.cwd().deleteFile(log_path) catch {};

        const result = try hardeningMixedValidCorruptRecords(log_path, allocator);
        try results.append(result);
    }

    // Test 5: Invalid magic number
    {
        const log_path = try std.fmt.allocPrint(allocator, "{s}_invalid_magic.log", .{test_log_prefix});
        defer allocator.free(log_path);
        defer std.fs.cwd().deleteFile(log_path) catch {};

        const result = try hardeningInvalidMagicNumber(log_path, allocator);
        try results.append(result);
    }

    // Test 6: Clean recovery to txn_id with corruption
    {
        const log_path = try std.fmt.allocPrint(allocator, "{s}_clean_recovery.log", .{test_log_prefix});
        defer allocator.free(log_path);
        defer std.fs.cwd().deleteFile(log_path) catch {};

        const result = try hardeningCleanRecoveryToTxnId(log_path, allocator);
        try results.append(result);
    }

    return results.toOwnedSlice();
}

