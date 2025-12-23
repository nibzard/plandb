//! Hardening tests for crash consistency and fault injection.
//!
//! Implements comprehensive tests for torn writes, short writes, and corruption
//! scenarios to verify the replay engine's robustness and clean recovery capabilities.

const std = @import("std");
const wal = @import("wal.zig");
const replay = @import("replay.zig");
const txn = @import("txn.zig");
const ref_model = @import("ref_model.zig");
const pager_mod = @import("pager.zig");
const db = @import("db.zig");

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

/// Crash harness for task queue workload with prefix-check verification
/// Simulates random crashes during task queue operations and verifies recovery
pub fn crashHarnessTaskQueue(db_path: []const u8, allocator: std.mem.Allocator, seed: u64, crash_at_txn: ?u64) !TestResult {
    const test_name = if (crash_at_txn) |target_txn| try std.fmt.allocPrint(allocator, "crash_task_queue_at_txn_{d}", .{target_txn}) else "crash_task_queue_random";
    defer {
        if (crash_at_txn != null) allocator.free(test_name);
    }
    var result = TestResult.init(test_name, allocator);

    // Delete existing files if present
    std.fs.cwd().deleteFile(db_path) catch {};
    const wal_path = try std.fmt.allocPrint(allocator, "{s}.log", .{std.fs.path.stem(db_path)});
    defer allocator.free(wal_path);
    std.fs.cwd().deleteFile(wal_path) catch {};

    // Create reference model for verification
    var reference = try ref_model.Model.init(allocator);
    defer reference.deinit();

    // Create WAL for commit log
    var test_wal = try wal.WriteAheadLog.create(wal_path, allocator);
    defer test_wal.deinit();

    // Parameters for task queue workload
    const total_tasks: u64 = 50;
    const agents: usize = 5;
    const claim_attempts_per_agent: usize = 3;
    const completion_rate: f64 = 0.7;

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var committed_txns: u64 = 0;
    var crash_txn: u64 = 0;

    // Phase 1: Create tasks
    for (0..total_tasks) |task_id| {
        var task_key_buf: [32]u8 = undefined;
        const task_key = try std.fmt.bufPrint(&task_key_buf, "task:{d}", .{task_id});

        const priority = rand.intRangeLessThan(u8, 1, 10);
        const task_type = rand.intRangeLessThan(u8, 1, 8);
        const created_at = std.time.timestamp();

        var task_value_buf: [128]u8 = undefined;
        const task_value = try std.fmt.bufPrint(&task_value_buf,
            "{{\"priority\":{},\"type\":{},\"created_at\":{},\"status\":\"pending\"}}",
            .{ priority, task_type, created_at });

        // Add to reference model
        var write_txn = reference.beginWrite();
        try write_txn.put(task_key, task_value);
        _ = try write_txn.commit();

        committed_txns += 1;

        // Commit to WAL
        const mutations = &[_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = task_key, .value = task_value } },
        };
        var record = txn.CommitRecord{
            .txn_id = committed_txns,
            .root_page_id = 0,
            .mutations = mutations,
            .checksum = 0,
        };
        record.checksum = record.calculatePayloadChecksum();
        _ = try test_wal.appendCommitRecord(record);
        try test_wal.flush();

        // Check if we should crash here
        if (crash_at_txn) |target| {
            if (committed_txns == target) {
                crash_txn = committed_txns;
                break;
            }
        } else if (rand.float(f64) < 0.05) { // 5% chance to crash after each task creation
            crash_txn = committed_txns;
            break;
        }
    }

    // Phase 2: Agent claims (simulate crash at various points)
    if (crash_txn == 0) {
        for (0..agents) |agent_id| {
            var w = reference.beginWrite();

            for (0..claim_attempts_per_agent) |_| {
                const task_id = rand.intRangeLessThan(u64, 0, total_tasks);
                const claim_timestamp = std.time.timestamp();

                // Create claim key
                var claim_key_buf: [64]u8 = undefined;
                const claim_key = try std.fmt.bufPrint(&claim_key_buf, "claim:{d}:{d}", .{ task_id, agent_id });
                var claim_val_buf: [32]u8 = undefined;
                const claim_val = try std.fmt.bufPrint(&claim_val_buf, "{d}", .{claim_timestamp});

                // Add to reference model
                try w.put(claim_key, claim_val);

                committed_txns += 1;

                // Commit to WAL
                const mutations = &[_]txn.Mutation{
                    txn.Mutation{ .put = .{ .key = claim_key, .value = claim_val } },
                };
                var record = txn.CommitRecord{
                    .txn_id = committed_txns,
                    .root_page_id = 0,
                    .mutations = mutations,
                    .checksum = 0,
                };
                record.checksum = record.calculatePayloadChecksum();
                _ = try test_wal.appendCommitRecord(record);
                try test_wal.flush();

                // Check if we should crash
                if (crash_at_txn) |target| {
                    if (committed_txns == target) {
                        crash_txn = committed_txns;
                        break;
                    }
                } else if (rand.float(f64) < 0.08) { // 8% chance to crash during claims
                    crash_txn = committed_txns;
                    break;
                }
            }

            _ = try w.commit();

            if (crash_txn > 0) break;
        }
    }

    // Phase 3: Task completions (if no crash yet)
    if (crash_txn == 0) {
        const tasks_to_complete = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_tasks)) * completion_rate));

        for (0..tasks_to_complete) |_| {
            const task_id = rand.intRangeLessThan(u64, 0, total_tasks);
            const completion_timestamp = std.time.timestamp();

            var completed_key_buf: [32]u8 = undefined;
            const completed_key = try std.fmt.bufPrint(&completed_key_buf, "completed:{d}", .{task_id});
            var completed_val_buf: [32]u8 = undefined;
            const completed_val = try std.fmt.bufPrint(&completed_val_buf, "{d}", .{completion_timestamp});

            var w = reference.beginWrite();
            try w.put(completed_key, completed_val);
            _ = try w.commit();

            committed_txns += 1;

            // Commit to WAL
            const mutations = &[_]txn.Mutation{
                txn.Mutation{ .put = .{ .key = completed_key, .value = completed_val } },
            };
            var record = txn.CommitRecord{
                .txn_id = committed_txns,
                .root_page_id = 0,
                .mutations = mutations,
                .checksum = 0,
            };
            record.checksum = record.calculatePayloadChecksum();
            _ = try test_wal.appendCommitRecord(record);
            try test_wal.flush();

            // Check if we should crash
            if (crash_at_txn) |target| {
                if (committed_txns == target) {
                    crash_txn = committed_txns;
                    break;
                }
            } else if (rand.float(f64) < 0.1) { // 10% chance to crash during completions
                crash_txn = committed_txns;
                break;
            }

            if (crash_txn > 0) break;
        }
    }

    // If no crash triggered, use the last committed txn
    if (crash_txn == 0) {
        crash_txn = committed_txns;
    }

    // Now simulate crash by reopening with replay engine
    // The replay engine should only see transactions up to crash_txn
    var engine = try replay.ReplayEngine.init(allocator, wal_path);
    defer engine.deinit();

    var replay_result = try engine.rebuildAll();
    defer replay_result.deinit();

    // Prefix-check: replayed state should match reference model at crash_txn
    // Use reference.beginRead to get the snapshot at crash_txn
    var ref_snapshot = try reference.beginRead(crash_txn);
    defer {
        var it = ref_snapshot.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        ref_snapshot.deinit();
    }

    // Verify that replayed state matches reference model
    var ref_it = ref_snapshot.iterator();
    while (ref_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const expected_value = entry.value_ptr.*;

        const actual_value = engine.get(key) orelse {
            result.fail("Key '{s}' exists in reference model but not in replayed state", .{key});
            return result;
        };

        if (!std.mem.eql(u8, expected_value, actual_value)) {
            result.fail("Value mismatch for key '{s}': expected '{s}', got '{s}'", .{ key, expected_value, actual_value });
            return result;
        }
    }

    // Verify that replay processed the correct number of transactions
    if (replay_result.processed_txns > crash_txn) {
        result.fail("Processed {} transactions but should only have processed up to txn {}", .{ replay_result.processed_txns, crash_txn });
        return result;
    }

    // Verify last_txn_id matches or is less than crash_txn
    if (replay_result.last_txn_id > crash_txn) {
        result.fail("last_txn_id {} exceeds crash_txn {}", .{ replay_result.last_txn_id, crash_txn });
        return result;
    }

    result.pass();
    return result;
}

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

    // Test 7: Crash harness task queue (random crash)
    {
        const db_path = "hardening_crash_task_queue_test.db";
        defer std.fs.cwd().deleteFile(db_path) catch {};

        const result = try crashHarnessTaskQueue(db_path, allocator, 12345, null);
        try results.append(result);
    }

    // Test 8: Crash harness task queue (crash at txn 10)
    {
        const db_path = "hardening_crash_task_queue_txn10.db";
        defer std.fs.cwd().deleteFile(db_path) catch {};

        const result = try crashHarnessTaskQueue(db_path, allocator, 54321, 10);
        try results.append(result);
    }

    return results.toOwnedSlice();
}

// ==================== Golden File Tests ====================

/// Test: Empty DB v0 opens and validates correctly
/// Golden file test: verifies known empty database file opens properly
pub fn goldenFileEmptyDbV0(db_path: []const u8, allocator: std.mem.Allocator) !TestResult {
    const test_name = "golden_empty_db_v0";
    var result = TestResult.init(test_name, allocator);

    // First, create a valid empty DB v0 file
    {
        var file = try std.fs.cwd().createFile(db_path, .{ .truncate = true });
        defer file.close();

        // Create both meta pages for empty database
        var buffer_a: [pager_mod.DEFAULT_PAGE_SIZE]u8 = undefined;
        var buffer_b: [pager_mod.DEFAULT_PAGE_SIZE]u8 = undefined;

        const empty_meta = pager_mod.MetaPayload{
            .meta_magic = pager_mod.META_MAGIC,
            .format_version = pager_mod.FORMAT_VERSION,
            .page_size = pager_mod.DEFAULT_PAGE_SIZE,
            .committed_txn_id = 0,
            .root_page_id = 0, // Empty tree
            .freelist_head_page_id = 0,
            .log_tail_lsn = 0,
            .meta_crc32c = 0, // Will be recalculated by encodeMetaPage
        };

        try pager_mod.encodeMetaPage(pager_mod.META_A_PAGE_ID, empty_meta, &buffer_a);
        try pager_mod.encodeMetaPage(pager_mod.META_B_PAGE_ID, empty_meta, &buffer_b);

        // Write both meta pages
        _ = try file.pwriteAll(&buffer_a, 0);
        _ = try file.pwriteAll(&buffer_b, pager_mod.DEFAULT_PAGE_SIZE);

        // Ensure the file is synced
        try file.sync();
    }

    // Now test that the file can be opened and validated
    {
        // Try to open with the pager
        var pager = try pager_mod.Pager.open(db_path, allocator);
        defer pager.close();

        // Verify the pager state
        const committed_txn_id = pager.getCommittedTxnId();
        const root_page_id = pager.getRootPageId();

        // Empty DB should have txn_id=0 and root_page_id=0
        if (committed_txn_id != 0) {
            result.fail("Expected committed_txn_id=0 for empty DB, got {}", .{committed_txn_id});
            return result;
        }

        if (root_page_id != 0) {
            result.fail("Expected root_page_id=0 for empty DB, got {}", .{root_page_id});
            return result;
        }

        // Verify that opening with Db API also works
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{std.fs.path.stem(db_path)});
        defer allocator.free(wal_path);

        // Clean up any existing wal file
        std.fs.cwd().deleteFile(wal_path) catch {};

        var test_db = try db.Db.openWithFile(allocator, db_path, wal_path);
        defer test_db.close();

        // Verify DB state
        if (test_db.next_txn_id != 1) {
            result.fail("Expected next_txn_id=1 for empty DB, got {}", .{test_db.next_txn_id});
            return result;
        }
    }

    result.pass();
    return result;
}

// ==================== Unit Tests ====================

test "crash harness task queue - random crash" {
    const db_path = "test_crash_task_queue_random.db";
    defer std.fs.cwd().deleteFile(db_path) catch {};

    var result = try crashHarnessTaskQueue(db_path, std.testing.allocator, 42, null);
    defer result.deinit();

    try std.testing.expect(result.passed);
    if (result.failure_reason) |reason| {
        std.debug.print("Test failed: {s}\n", .{reason});
    }
}

test "crash harness task queue - crash at txn 5" {
    const db_path = "test_crash_task_queue_txn5.db";
    defer std.fs.cwd().deleteFile(db_path) catch {};

    var result = try crashHarnessTaskQueue(db_path, std.testing.allocator, 999, 5);
    defer result.deinit();

    try std.testing.expect(result.passed);
    if (result.failure_reason) |reason| {
        std.debug.print("Test failed: {s}\n", .{reason});
    }
}

test "golden file: empty DB v0 opens and validates" {
    const db_path = "test_golden_empty_v0.db";
    defer std.fs.cwd().deleteFile(db_path) catch {};
    const wal_path = "test_golden_empty_v0.db.wal";
    defer std.fs.cwd().deleteFile(wal_path) catch {};

    var result = try goldenFileEmptyDbV0(db_path, std.testing.allocator);
    defer result.deinit();

    try std.testing.expect(result.passed);
    if (result.failure_reason) |reason| {
        std.debug.print("Golden file test failed: {s}\n", .{reason});
    }
}
