const std = @import("std");
const pager_mod = @import("pager.zig");
const wal = @import("wal.zig");
const txn = @import("txn.zig");

/// Crash recovery manager for database consistency
pub const RecoveryManager = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Recover database after a crash
    pub fn recoverDatabase(allocator: std.mem.Allocator, db_path: []const u8, wal_path: []const u8) !RecoveryResult {
        var result = RecoveryResult.init(allocator);
        errdefer result.deinit();

        // Step 1: Open WAL and read replay data
        var wal_inst = try wal.WriteAheadLog.open(wal_path, allocator);
        defer wal_inst.deinit();

        const replay_data = try wal_inst.replayFrom(0, allocator);
        defer replay_data.deinit();

        // Step 2: Open database with pager recovery
        var pager = try pager_mod.Pager.open(db_path, allocator);
        defer pager.close();

        // Step 3: Determine recovery needed
        const db_committed_txn_id = pager.getCommittedTxnId();
        const wal_last_txn_id = if (replay_data.commit_records.items.len > 0)
            replay_data.commit_records.items[replay_data.commit_records.items.len - 1].txn_id
        else
            0;

        result.db_txn_id = db_committed_txn_id;
        result.wal_txn_id = wal_last_txn_id;

        // If WAL has transactions beyond what DB has committed, need recovery
        if (wal_last_txn_id > db_committed_txn_id) {
            result.recovery_needed = true;

            // Step 4: Apply recovery
            try applyRecovery(&replay_data, &pager, &result);
        }

        return result;
    }

    /// Apply recovery by reconciling WAL and database state
    fn applyRecovery(replay_data: *const wal.ReplayResult, pager: *pager_mod.Pager, result: *RecoveryResult) !void {
        // Find the highest committed transaction that made it to the database
        var highest_committed_in_db = pager.getCommittedTxnId();

        // Replay transactions that are missing from the database
        for (replay_data.commit_records.items) |commit_record| {
            if (commit_record.txn_id <= highest_committed_in_db) {
                // This transaction is already reflected in the database
                continue;
            }

            // Validate commit record checksum
            if (!commit_record.validateChecksum()) {
                result.corrupted_records += 1;
                continue;
            }

            // This transaction made it to WAL but not to database
            // Update the database meta page to reflect this transaction
            result.recovered_txns += 1;

            // Update database meta to reflect this committed transaction
            const current_meta = pager.current_meta.meta;
            var new_meta = current_meta;
            new_meta.committed_txn_id = commit_record.txn_id;

            // Get opposite meta page for atomic update
            const opposite_meta_id = try pager_mod.getOppositeMetaId(current_meta.page_id);

            // Encode new meta page
            var meta_buffer: [pager_mod.DEFAULT_PAGE_SIZE]u8 = undefined;
            try pager_mod.encodeMetaPage(opposite_meta_id, new_meta, &meta_buffer);

            // Write meta page
            try pager.writePage(opposite_meta_id, &meta_buffer);
        }

        // Final sync to ensure recovery is durable
        try pager.sync();
    }

    /// Check database consistency
    pub fn checkConsistency(allocator: std.mem.Allocator, db_path: []const u8, wal_path: []const u8) !ConsistencyResult {
        var result = ConsistencyResult.init(allocator);
        errdefer result.deinit();

        // Open WAL
        var wal_inst = try wal.WriteAheadLog.open(wal_path, allocator);
        defer wal_inst.deinit();

        const replay_data = try wal_inst.replayFrom(0, allocator);
        defer replay_data.deinit();

        // Open database
        var pager = try pager_mod.Pager.open(db_path, allocator);
        defer pager.close();

        // Check for consistency issues
        result.db_txn_id = pager.getCommittedTxnId();
        result.wal_txn_id = replay_data.last_lsn;

        // Check if WAL has transactions beyond what's committed in DB
        for (replay_data.commit_records.items) |commit_record| {
            if (commit_record.txn_id > result.db_txn_id) {
                // This transaction is in WAL but not reflected in DB
                try result.missing_txns.append(commit_record.txn_id);
            }

            // Validate checksums
            if (!commit_record.validateChecksum()) {
                result.corrupted_records += 1;
            }
        }

        // Database is consistent if WAL doesn't have transactions beyond DB's committed ID
        result.is_consistent = result.missing_txns.items.len == 0;

        return result;
    }

    /// Perform a checkpoint to truncate WAL
    pub fn checkpoint(allocator: std.mem.Allocator, db_path: []const u8, wal_path: []const u8) !CheckpointResult {
        var result = CheckpointResult{
            .old_wal_size = 0,
            .new_wal_size = 0,
            .checkpoint_txn_id = 0,
        };

        // Open WAL and database
        var wal_inst = try wal.WriteAheadLog.open(wal_path, allocator);
        defer wal_inst.deinit();

        var pager = try pager_mod.Pager.open(db_path, allocator);
        defer pager.close();

        // Get current WAL size
        result.old_wal_size = try wal_inst.file.getEndPos();

        // Get current committed transaction ID
        result.checkpoint_txn_id = pager.getCommittedTxnId();

        // Add checkpoint record to WAL
        const checkpoint_lsn = try wal_inst.appendCheckpoint(result.checkpoint_txn_id);
        _ = checkpoint_lsn; // Not used currently

        // Truncate WAL up to checkpoint point
        try wal_inst.truncate(checkpoint_lsn);

        // Get new WAL size
        result.new_wal_size = try wal_inst.file.getEndPos();

        return result;
    }
};

/// Result of database recovery
pub const RecoveryResult = struct {
    recovery_needed: bool,
    db_txn_id: u64,
    wal_txn_id: u64,
    recovered_txns: usize,
    corrupted_records: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .recovery_needed = false,
            .db_txn_id = 0,
            .wal_txn_id = 0,
            .recovered_txns = 0,
            .corrupted_records = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self; // Nothing to clean up currently
    }
};

/// Result of consistency check
pub const ConsistencyResult = struct {
    is_consistent: bool,
    db_txn_id: u64,
    wal_txn_id: u64,
    missing_txns: std.ArrayList(u64),
    corrupted_records: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .is_consistent = true,
            .db_txn_id = 0,
            .wal_txn_id = 0,
            .missing_txns = std.ArrayList(u64).init(allocator),
            .corrupted_records = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.missing_txns.deinit();
    }
};

/// Result of checkpoint operation
pub const CheckpointResult = struct {
    old_wal_size: u64,
    new_wal_size: u64,
    checkpoint_txn_id: u64,
};

// ==================== Unit Tests ====================

test "RecoveryManager.recoverDatabase_no_recovery_needed" {
    const test_db = "test_recovery_no_need.db";
    const test_wal = "test_recovery_no_need.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create empty database and WAL
    {
        var pager = try pager_mod.Pager.create(test_db, arena.allocator());
        defer pager.close();

        var wal_inst = try wal.WriteAheadLog.create(test_wal, arena.allocator());
        defer wal_inst.deinit();
    }

    // Test recovery - should indicate no recovery needed
    const result = try RecoveryManager.recoverDatabase(arena.allocator(), test_db, test_wal);
    defer result.deinit();

    try testing.expect(!result.recovery_needed);
    try testing.expectEqual(@as(u64, 0), result.db_txn_id);
    try testing.expectEqual(@as(u64, 0), result.wal_txn_id);
    try testing.expectEqual(@as(usize, 0), result.recovered_txns);
}

test "RecoveryManager.checkConsistency_consistent_database" {
    const test_db = "test_consistency_consistent.db";
    const test_wal = "test_consistency_consistent.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create consistent database and WAL
    {
        var pager = try pager_mod.Pager.create(test_db, arena.allocator());
        defer pager.close();

        var wal_inst = try wal.WriteAheadLog.create(test_wal, arena.allocator());
        defer wal_inst.deinit();

        // Create a checkpoint at txn_id 0
        _ = try wal_inst.appendCheckpoint(0);
    }

    // Test consistency check
    const result = try RecoveryManager.checkConsistency(arena.allocator(), test_db, test_wal);
    defer result.deinit();

    try testing.expect(result.is_consistent);
    try testing.expectEqual(@as(usize, 0), result.missing_txns.items.len);
    try testing.expectEqual(@as(usize, 0), result.corrupted_records);
}

test "RecoveryManager.checkpoint_truncates_wal" {
    const test_db = "test_checkpoint.db";
    const test_wal = "test_checkpoint.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create database with some WAL records
    {
        var pager = try pager_mod.Pager.create(test_db, arena.allocator());
        defer pager.close();

        var wal_inst = try wal.WriteAheadLog.create(test_wal, arena.allocator());
        defer wal_inst.deinit();

        // Add some records to WAL
        _ = try wal_inst.appendCheckpoint(0);
        _ = try wal_inst.appendCheckpoint(1);
        _ = try wal_inst.appendCheckpoint(2);
    }

    // Perform checkpoint
    const result = try RecoveryManager.checkpoint(arena.allocator(), test_db, test_wal);

    // Should have truncated WAL
    try testing.expect(result.old_wal_size > result.new_wal_size);
    try testing.expectEqual(@as(u64, 2), result.checkpoint_txn_id);
}

const testing = std.testing;