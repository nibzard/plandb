//! Comprehensive in-memory reference model for MVCC and correctness validation.
//!
//! Provides a complete implementation of multi-version concurrency control with
//! deterministic replay, seedable operation generation, and byte-identical state
//! comparison capabilities. This serves as the ground truth for database testing.
//!
//! Features:
//! - MVCC snapshots with proper isolation
//! - Deterministic operation generation with seeds
//! - Commit log for replay and time-travel queries
//! - Byte-identical state comparison
//! - Property-based testing support
//! - Comprehensive correctness validation

const std = @import("std");
const builtin = @import("builtin");

/// Represents a single key-value pair
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Represents a database operation
pub const Operation = struct {
    op_type: enum { put, delete },
    key: []const u8,
    value: ?[]const u8, // null for delete operations
};

/// Represents a committed transaction
pub const CommitRecord = struct {
    txn_id: u64,
    operations: []Operation,
    timestamp_ns: u64,
};

/// Snapshot state representing a point-in-time view
pub const SnapshotState = std.StringHashMap([]const u8);

/// Commit log for deterministic replay
pub const CommitLog = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(CommitRecord),

    pub fn init(allocator: std.mem.Allocator) CommitLog {
        return .{
            .allocator = allocator,
            .records = std.ArrayList(CommitRecord).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *CommitLog) void {
        for (self.records.items) |record| {
            for (record.operations) |op| {
                self.allocator.free(op.key);
                if (op.value) |val| {
                    self.allocator.free(val);
                }
            }
            self.allocator.free(record.operations);
        }
        self.records.deinit(self.allocator);
    }

    pub fn append(self: *CommitLog, record: CommitRecord) !void {
        try self.records.append(self.allocator, record);
    }

    pub fn getRecord(self: *const CommitLog, txn_id: u64) ?CommitRecord {
        for (self.records.items) |record| {
            if (record.txn_id == txn_id) {
                return record;
            }
        }
        return null;
    }

    pub fn replayToTxn(self: *const CommitLog, allocator: std.mem.Allocator, target_txn_id: u64) !SnapshotState {
        var snapshot = SnapshotState.init(allocator);

        for (self.records.items) |record| {
            if (record.txn_id > target_txn_id) break;

            for (record.operations) |op| {
                switch (op.op_type) {
                    .put => {
                        const key_copy = try allocator.dupe(u8, op.key);
                        const value_copy = try allocator.dupe(u8, op.value.?);
                        try snapshot.put(key_copy, value_copy);
                    },
                    .delete => {
                        const key = snapshot.getKey(op.key) orelse continue;
                        allocator.free(key);
                        _ = snapshot.remove(op.key);
                    },
                }
            }
        }

        return snapshot;
    }
};

/// Random number generator for deterministic operation generation
pub const SeededRng = struct {
    state: u64,

    pub fn init(seed: u64) SeededRng {
        return .{ .state = seed };
    }

    pub fn next(self: *SeededRng) u64 {
        // Xorshift64* algorithm
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        return self.state *% 2685821577748429807;
    }

    pub fn nextRange(self: *SeededRng, min: u64, max: u64) u64 {
        const range = max - min + 1;
        return min + (self.next() % range);
    }

    pub fn nextBytes(self: *SeededRng, allocator: std.mem.Allocator, len: usize) ![]u8 {
        const bytes = try allocator.alloc(u8, len);
        for (bytes) |*byte| {
            byte.* = @intCast(self.next() % 256);
        }
        return bytes;
    }

    pub fn nextString(self: *SeededRng, allocator: std.mem.Allocator, min_len: usize, max_len: usize) ![]u8 {
        const len = min_len + self.nextRange(0, max_len - min_len);
        const bytes = try self.nextBytes(allocator, len);

        // Make it printable (alphanumeric)
        for (bytes) |*byte| {
            byte.* = 'a' + @as(u8, @intCast(byte.* % 26));
        }

        return bytes;
    }
};

/// Operation sequence generator for testing
pub const OperationGenerator = struct {
    rng: SeededRng,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64) OperationGenerator {
        return .{
            .rng = SeededRng.init(seed),
            .allocator = allocator,
        };
    }

    pub fn generateSequence(self: *OperationGenerator, num_ops: usize, num_keys: usize) ![]Operation {
        const operations = try self.allocator.alloc(Operation, num_ops);

        // Pre-generate keys to ensure reuse
        const keys = try self.allocator.alloc([]const u8, num_keys);
        defer {
            for (keys) |key| {
                self.allocator.free(key);
            }
            self.allocator.free(keys);
        }

        for (keys) |*key| {
            key.* = try self.rng.nextString(self.allocator, 8, 16);
        }

        for (operations) |*op| {
            const key_idx = self.rng.nextRange(0, num_keys - 1);
            const is_delete = self.rng.nextRange(0, 9) == 0; // 10% delete probability

            if (is_delete) {
                op.* = .{
                    .op_type = .delete,
                    .key = try self.allocator.dupe(u8, keys[key_idx]),
                    .value = null,
                };
            } else {
                op.* = .{
                    .op_type = .put,
                    .key = try self.allocator.dupe(u8, keys[key_idx]),
                    .value = try self.rng.nextString(self.allocator, 16, 64),
                };
            }
        }

        return operations;
    }
};

/// Enhanced reference model with comprehensive MVCC support
pub const Model = struct {
    allocator: std.mem.Allocator,
    current_txn_id: u64,
    snapshots: std.AutoHashMap(u64, SnapshotState),
    commit_log: CommitLog,
    timestamp_base: u64,

    pub fn init(allocator: std.mem.Allocator) !Model {
        var model = Model{
            .allocator = allocator,
            .current_txn_id = 0,
            .snapshots = std.AutoHashMap(u64, SnapshotState).init(allocator),
            .commit_log = CommitLog.init(allocator),
            .timestamp_base = @intCast(std.time.nanoTimestamp()),
        };

        // Create genesis snapshot
        const genesis = SnapshotState.init(allocator);
        try model.snapshots.put(0, genesis);

        return model;
    }

    pub fn deinit(self: *Model) void {
        // Free all snapshot data
        var snapshot_it = self.snapshots.valueIterator();
        while (snapshot_it.next()) |snapshot| {
            var key_it = snapshot.iterator();
            while (key_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            snapshot.deinit();
        }
        self.snapshots.deinit();

        // Free commit log
        self.commit_log.deinit();
    }

    pub fn beginRead(self: *Model, txn_id: u64) !SnapshotState {
        if (txn_id > self.current_txn_id) return error.InvalidTxnId;

        if (self.snapshots.get(txn_id)) |snapshot| {
            return try self.cloneSnapshot(snapshot);
        }
        return error.SnapshotNotFound;
    }

    pub fn beginReadLatest(self: *Model) !SnapshotState {
        return self.beginRead(self.current_txn_id);
    }

    pub fn beginWrite(self: *Model) WriteTxn {
        return WriteTxn{
            .allocator = self.allocator,
            .model = self,
            .operations = std.ArrayList(Operation).initCapacity(self.allocator, 0) catch unreachable,
            .committed = false,
        };
    }

    pub fn getCurrentTxnId(self: *const Model) u64 {
        return self.current_txn_id;
    }

    pub fn getAllSnapshots(self: *const Model, allocator: std.mem.Allocator) ![]u64 {
        const keys = try allocator.alloc(u64, self.snapshots.count());
        var i: usize = 0;
        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            keys[i] = entry.key_ptr.*;
            i += 1;
        }
        return keys;
    }

    pub fn hasSnapshot(self: *const Model, txn_id: u64) bool {
        return self.snapshots.contains(txn_id);
    }

    pub fn getLatestSnapshot(self: *Model) !SnapshotState {
        return self.beginReadLatest();
    }

    fn cloneSnapshot(self: *Model, original: SnapshotState) !SnapshotState {
        var clone = SnapshotState.init(self.allocator);
        var it = original.iterator();
        while (it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
            try clone.put(key_copy, value_copy);
        }
        return clone;
    }

    fn createSnapshotFromLog(self: *Model, txn_id: u64) !SnapshotState {
        return self.commit_log.replayToTxn(self.allocator, txn_id);
    }

    pub fn compareStates(self: *Model, txn_id1: u64, txn_id2: u64) !bool {
        const snap1 = try self.beginRead(txn_id1);
        defer {
            var it = snap1.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            snap1.deinit();
        }

        const snap2 = try self.beginRead(txn_id2);
        defer {
            var it = snap2.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            snap2.deinit();
        }

        // Compare key counts
        if (snap1.count() != snap2.count()) return false;

        // Compare each key-value pair
        var it = snap1.iterator();
        while (it.next()) |entry| {
            const val2 = snap2.get(entry.key_ptr.*) orelse return false;
            if (!std.mem.eql(u8, entry.value_ptr.*, val2)) return false;
        }

        return true;
    }
};

/// Enhanced write transaction with comprehensive operation tracking
pub const WriteTxn = struct {
    allocator: std.mem.Allocator,
    model: *Model,
    operations: std.ArrayList(Operation),
    committed: bool = false,

    pub fn put(self: *WriteTxn, key: []const u8, value: []const u8) !void {
        const op = Operation{
            .op_type = .put,
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        };
        try self.operations.append(self.allocator, op);
    }

    pub fn del(self: *WriteTxn, key: []const u8) !void {
        const op = Operation{
            .op_type = .delete,
            .key = try self.allocator.dupe(u8, key),
            .value = null,
        };
        try self.operations.append(self.allocator, op);
    }

    pub fn commit(self: *WriteTxn) !u64 {
        if (self.committed) return error.AlreadyCommitted;

        self.model.current_txn_id += 1;
        const new_txn_id = self.model.current_txn_id;

        // Create commit record
        const operations_copy = try self.allocator.alloc(Operation, self.operations.items.len);
        for (self.operations.items, 0..) |op, i| {
            operations_copy[i] = .{
                .op_type = op.op_type,
                .key = try self.allocator.dupe(u8, op.key),
                .value = if (op.value) |val| try self.allocator.dupe(u8, val) else null,
            };
        }

        const commit_record = CommitRecord{
            .txn_id = new_txn_id,
            .operations = operations_copy,
            .timestamp_ns = self.model.timestamp_base + @as(u64, @intCast(std.time.nanoTimestamp())),
        };

        // Append to commit log
        try self.model.commit_log.append(commit_record);

        // Create new snapshot by replaying log
        const new_snapshot = try self.model.createSnapshotFromLog(new_txn_id);
        try self.model.snapshots.put(new_txn_id, new_snapshot);

        self.committed = true;
        self.cleanup();

        return new_txn_id;
    }

    pub fn abort(self: *WriteTxn) void {
        self.cleanup();
    }

    pub fn getOperationCount(self: *const WriteTxn) usize {
        return self.operations.items.len;
    }

    fn cleanup(self: *WriteTxn) void {
        for (self.operations.items) |op| {
            self.allocator.free(op.key);
            if (op.value) |val| {
                self.allocator.free(val);
            }
        }
        self.operations.deinit(self.allocator);
    }
};

// Comprehensive tests
test "comprehensive reference model operations" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    // Test basic put/get
    var w1 = model.beginWrite();
    try w1.put("key1", "value1");
    try w1.put("key2", "value2");
    const txn1 = try w1.commit();

    var snap1 = try model.beginRead(txn1);
    defer {
        var it = snap1.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        snap1.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), snap1.count());
    try std.testing.expect(std.mem.eql(u8, snap1.get("key1").?, "value1"));
    try std.testing.expect(std.mem.eql(u8, snap1.get("key2").?, "value2"));

    // Test transaction isolation
    var w2 = model.beginWrite();
    try w2.put("key1", "updated_value1");
    try w2.del("key2");
    const txn2 = try w2.commit();

    // Original snapshot should be unchanged
    try std.testing.expect(std.mem.eql(u8, snap1.get("key1").?, "value1"));
    try std.testing.expect(snap1.get("key2") != null);

    // New snapshot should reflect changes
    var snap2 = try model.beginRead(txn2);
    defer {
        var it = snap2.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        snap2.deinit();
    }

    try std.testing.expect(std.mem.eql(u8, snap2.get("key1").?, "updated_value1"));
    try std.testing.expect(snap2.get("key2") == null);
}

test "commit log replay and deterministic behavior" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    // Generate deterministic operations
    var generator = OperationGenerator.init(std.testing.allocator, 12345);
    const operations = try generator.generateSequence(10, 5);
    defer {
        for (operations) |op| {
            std.testing.allocator.free(op.key);
            if (op.value) |val| {
                std.testing.allocator.free(val);
            }
        }
        std.testing.allocator.free(operations);
    }

    // Apply operations
    var w = model.beginWrite();
    for (operations) |op| {
        switch (op.op_type) {
            .put => try w.put(op.key, op.value.?),
            .delete => try w.del(op.key),
        }
    }
    const txn_id = try w.commit();

    // Create new model and replay to same point
    var model2 = try Model.init(std.testing.allocator);
    defer model2.deinit();

    // Copy commit log
    for (model.commit_log.records.items) |record| {
        var ops_copy = try std.testing.allocator.alloc(Operation, record.operations.len);
        for (record.operations, 0..) |op, i| {
            ops_copy[i] = .{
                .op_type = op.op_type,
                .key = try std.testing.allocator.dupe(u8, op.key),
                .value = if (op.value) |val| try std.testing.allocator.dupe(u8, val) else null,
            };
        }
        const record_copy = CommitRecord{
            .txn_id = record.txn_id,
            .operations = ops_copy,
            .timestamp_ns = record.timestamp_ns,
        };
        try model2.commit_log.append(record_copy);
    }

    // Replay and compare
    const replayed_snap = try model2.createSnapshotFromLog(txn_id);
    defer {
        var it = replayed_snap.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        replayed_snap.deinit();
    }

    const original_snap = try model.beginRead(txn_id);
    defer {
        var it = original_snap.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        original_snap.deinit();
    }

    try std.testing.expectEqual(original_snap.count(), replayed_snap.count());

    // Compare all key-value pairs
    var it = original_snap.iterator();
    while (it.next()) |entry| {
        const replayed_value = replayed_snap.get(entry.key_ptr.*) orelse unreachable;
        try std.testing.expect(std.mem.eql(u8, entry.value_ptr.*, replayed_value));
    }
}

test "state comparison functionality" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    // Create different states
    var w1 = model.beginWrite();
    try w1.put("a", "1");
    const txn1 = try w1.commit();

    var w2 = model.beginWrite();
    try w2.put("a", "1");
    try w2.put("b", "2");
    const txn2 = try w2.commit();

    var w3 = model.beginWrite();
    try w3.put("a", "3");
    try w3.put("b", "2");
    const txn3 = try w3.commit();

    // Compare states
    try std.testing.expect(!try model.compareStates(txn1, txn2)); // different key count
    try std.testing.expect(!try model.compareStates(txn2, txn3)); // different value for key "a"
    try std.testing.expect(try model.compareStates(txn1, txn1)); // same state
}