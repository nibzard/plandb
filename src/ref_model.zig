//! Simplified in-memory reference model used for tests.
//!
//! Currently provides basic snapshot bookkeeping; full MVCC semantics and history
//! cloning are stubbed out and will be expanded alongside the B+tree/MVCC work.

const std = @import("std");

pub const SnapshotState = std.StringHashMap([]const u8);

pub const Model = struct {
    allocator: std.mem.Allocator,
    current_txn_id: u64,
    history: std.AutoHashMap(u64, SnapshotState),

    pub fn init(allocator: std.mem.Allocator) !Model {
        var history = std.AutoHashMap(u64, SnapshotState).init(allocator);
        const genesis = SnapshotState.init(allocator);
        try history.put(0, genesis);
        return .{ .allocator = allocator, .current_txn_id = 0, .history = history };
    }

    pub fn deinit(self: *Model) void {
        var it = self.history.valueIterator();
        while (it.next()) |snap| {
            // TODO: fix iterator for new Zig HashMap API
            snap.*.deinit();
        }
        self.history.deinit();
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
        const copy = SnapshotState.init(allocator);
        var it = snap.iterator();
        while (it.next()) |entry| {
            _ = entry;
            // TODO: fix cloning for new Zig HashMap API
        }
        return copy;
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
                try new_snap.put(entry.key_ptr.*, val);
            } else {
                _ = new_snap.remove(entry.key_ptr.*);
                self.allocator.free(entry.key_ptr.*);
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
    defer snap.deinit();
    const val = snap.get("k") orelse unreachable;
    try std.testing.expect(std.mem.eql(u8, val, "v"));

    var w2 = model.beginWrite();
    try w2.put("k", "new");
    w2.abort();
    var snap2 = try model.beginRead(id);
    defer snap2.deinit();
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
    defer snap.deinit();

    var w2 = model.beginWrite();
    try w2.put("a", "2");
    _ = try w2.commit();

    const val = snap.get("a") orelse unreachable;
    try std.testing.expect(std.mem.eql(u8, val, "1"));
}
