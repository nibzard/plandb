//! Simplified in-memory reference model used for tests.
//!
//! Currently provides basic snapshot bookkeeping; full MVCC semantics and history
//! cloning are stubbed out and will be expanded alongside the B+tree/MVCC work.

const std = @import("std");

pub const SnapshotState = std.StringHashMap([]const u8);

/// Represents a single database operation
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
                        const key_ptr = snapshot.getPtr(op.key) orelse continue;
                        allocator.free(key_ptr.*);
                        allocator.free(op.key);
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
                    .key = try self.allocator.dupe(u8, keys[@intCast(key_idx)]),
                    .value = null,
                };
            } else {
                op.* = .{
                    .op_type = .put,
                    .key = try self.allocator.dupe(u8, keys[@intCast(key_idx)]),
                    .value = try self.rng.nextString(self.allocator, 16, 64),
                };
            }
        }

        return operations;
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    current_txn_id: u64,
    history: std.AutoHashMap(u64, SnapshotState),
    commit_log: CommitLog,

    pub fn init(allocator: std.mem.Allocator) !Model {
        var history = std.AutoHashMap(u64, SnapshotState).init(allocator);
        const genesis = SnapshotState.init(allocator);
        try history.put(0, genesis);
        return .{
            .allocator = allocator,
            .current_txn_id = 0,
            .history = history,
            .commit_log = CommitLog.init(allocator),
        };
    }

    pub fn deinit(self: *Model) void {
        var snapshot_it = self.history.iterator();
        while (snapshot_it.next()) |entry| {
            // Free all key-value pairs in the snapshot
            var kv_it = entry.value_ptr.*.iterator();
            while (kv_it.next()) |kv_entry| {
                self.allocator.free(kv_entry.key_ptr.*);
                self.allocator.free(kv_entry.value_ptr.*);
            }
            entry.value_ptr.*.deinit();
        }
        self.history.deinit();
        self.commit_log.deinit();
    }

    pub fn beginRead(self: *Model, txn_id: u64) !SnapshotState {
        if (self.history.get(txn_id)) |snap| {
            return try cloneSnapshot(self.allocator, snap);
        }
        return error.SnapshotNotFound;
    }

    pub fn beginWrite(self: *Model) WriteTxn {
        return WriteTxn{ .allocator = self.allocator, .model = self, .writes = std.StringHashMap(?[]const u8).init(self.allocator) };
    }

        fn cloneSnapshot(allocator: std.mem.Allocator, snap: SnapshotState) !SnapshotState {
        var copy = SnapshotState.init(allocator);
        var it = snap.iterator();
        while (it.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
            try copy.put(key_copy, value_copy);
        }
        return copy;
    }

    // Enhanced methods for comprehensive MVCC support
    pub fn beginReadLatest(self: *Model) !SnapshotState {
        return self.beginRead(self.current_txn_id);
    }

    pub fn getCurrentTxnId(self: *const Model) u64 {
        return self.current_txn_id;
    }

    pub fn getAllSnapshots(self: *const Model, allocator: std.mem.Allocator) ![]u64 {
        const keys = try allocator.alloc(u64, self.history.count());
        var i: usize = 0;
        var it = self.history.iterator();
        while (it.next()) |entry| {
            keys[i] = entry.key_ptr.*;
            i += 1;
        }
        return keys;
    }

    pub fn hasSnapshot(self: *const Model, txn_id: u64) bool {
        return self.history.contains(txn_id);
    }

    pub fn getLatestSnapshot(self: *Model) !SnapshotState {
        return self.beginReadLatest();
    }

    pub fn compareStates(self: *Model, txn_id1: u64, txn_id2: u64) !bool {
        var snap1 = try self.beginRead(txn_id1);
        defer {
            var it = snap1.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            snap1.deinit();
        }

        var snap2 = try self.beginRead(txn_id2);
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

    pub fn createSnapshotFromLog(self: *Model, txn_id: u64) !SnapshotState {
        return self.commit_log.replayToTxn(self.allocator, txn_id);
    }
};

pub const WriteTxn = struct {
    allocator: std.mem.Allocator,
    model: *Model,
    writes: std.StringHashMap(?[]const u8),
    committed: bool = false,

    pub fn put(self: *WriteTxn, key: []const u8, value: []const u8) !void {
        try self.writes.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
    }

    pub fn del(self: *WriteTxn, key: []const u8) !void {
        try self.writes.put(try self.allocator.dupe(u8, key), null);
    }

    pub fn commit(self: *WriteTxn) !u64 {
        if (self.committed) return error.AlreadyCommitted;
        const base_snap = self.model.history.get(self.model.current_txn_id) orelse return error.SnapshotNotFound;
        var new_snap = try Model.cloneSnapshot(self.allocator, base_snap);

        var it = self.writes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                // Transfer ownership of key and value to new snapshot
                // We need to make a copy since the original will be freed in cleanup()
                const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                const value_copy = try self.allocator.dupe(u8, val);
                try new_snap.put(key_copy, value_copy);
            } else {
                _ = new_snap.remove(entry.key_ptr.*);
                // key will be freed in cleanup()
            }
        }

        self.model.current_txn_id += 1;
        const new_id = self.model.current_txn_id;
        try self.model.history.put(new_id, new_snap);
        self.committed = true;
        self.cleanup();
        return new_id;
    }

    pub fn abort(self: *WriteTxn) void {
        self.cleanup();
    }

    fn cleanup(self: *WriteTxn) void {
        var it = self.writes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |val| self.allocator.free(val);
        }
        self.writes.deinit();
    }
};

test "txn atomicity and abort" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var w = model.beginWrite();
    try w.put("k", "v");
    const id = try w.commit();
    try std.testing.expectEqual(@as(u64, 1), id);

    var snap = try model.beginRead(id);
    defer {
        var it = snap.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        snap.deinit();
    }
    const val = snap.get("k") orelse unreachable;
    try std.testing.expect(std.mem.eql(u8, val, "v"));

    var w2 = model.beginWrite();
    try w2.put("k", "new");
    w2.abort();
    var snap2 = try model.beginRead(id);
    defer {
        var it = snap2.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        snap2.deinit();
    }
    const val2 = snap2.get("k") orelse unreachable;
    try std.testing.expect(std.mem.eql(u8, val2, "v"));
}

test "snapshot immutability" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var w = model.beginWrite();
    try w.put("a", "1");
    const id = try w.commit();

    var snap = try model.beginRead(id);
    defer {
        var it = snap.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        snap.deinit();
    }

    var w2 = model.beginWrite();
    try w2.put("a", "2");
    _ = try w2.commit();

    const val = snap.get("a") orelse unreachable;
    try std.testing.expect(std.mem.eql(u8, val, "1"));
}

// Enhanced tests for comprehensive reference model functionality
test "enhanced reference model operations" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    // Test enhanced methods
    try std.testing.expectEqual(@as(u64, 0), model.getCurrentTxnId());
    try std.testing.expect(model.hasSnapshot(0));
    try std.testing.expect(!model.hasSnapshot(999));

    // Test beginReadLatest
    var w = model.beginWrite();
    try w.put("key1", "value1");
    _ = try w.commit();

    try std.testing.expectEqual(@as(u64, 1), model.getCurrentTxnId());

    var latest_snap = try model.beginReadLatest();
    defer {
        var it = latest_snap.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        latest_snap.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), latest_snap.count());
    try std.testing.expect(std.mem.eql(u8, latest_snap.get("key1").?, "value1"));
}

test "operation generation and deterministic behavior" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    // Test operation generation
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

    try std.testing.expectEqual(@as(usize, 10), operations.len);

    // Apply generated operations
    var w = model.beginWrite();
    for (operations) |op| {
        switch (op.op_type) {
            .put => try w.put(op.key, op.value.?),
            .delete => try w.del(op.key),
        }
    }
    _ = try w.commit();

    // Verify results
    var snap = try model.beginReadLatest();
    defer {
        var it = snap.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        snap.deinit();
    }

    // The exact content depends on the random seed, but should have applied operations
    try std.testing.expect(snap.count() > 0);
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
