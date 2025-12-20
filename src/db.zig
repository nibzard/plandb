const std = @import("std");
const ref_model = @import("ref_model.zig");

pub const Db = struct {
    allocator: std.mem.Allocator,
    model: ref_model.Model,

    pub fn open(allocator: std.mem.Allocator) !Db {
        return .{ .allocator = allocator, .model = try ref_model.Model.init(allocator) };
    }

    pub fn close(self: *Db) void {
        self.model.deinit();
    }

    pub fn beginReadLatest(self: *Db) !ReadTxn {
        return ReadTxn{ .snapshot = try self.model.beginRead(self.model.current_txn_id), .allocator = self.allocator };
    }

    pub fn beginReadAt(self: *Db, txn_id: u64) !ReadTxn {
        return ReadTxn{ .snapshot = try self.model.beginRead(txn_id), .allocator = self.allocator };
    }

    pub fn beginWrite(self: *Db) WriteTxn {
        return .{ .inner = self.model.beginWrite() };
    }
};

pub const ReadTxn = struct {
    snapshot: ref_model.SnapshotState,
    allocator: std.mem.Allocator,

    pub fn get(self: *ReadTxn, key: []const u8) ?[]const u8 {
        if (self.snapshot.get(key)) |value| return value;
        return null;
    }

    pub fn scan(self: *ReadTxn, prefix: []const u8) ![]const KV {
        var items = std.ArrayList(KV).init(self.allocator);
        var it = self.snapshot.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                try items.append(.{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
            }
        }
        std.mem.sort(KV, items.items, {}, kvLess);
        return items.toOwnedSlice();
    }

    pub fn close(self: *ReadTxn) void {
        self.snapshot.deinit();
    }
};

pub const WriteTxn = struct {
    inner: ref_model.WriteTxn,

    pub fn put(self: *WriteTxn, key: []const u8, value: []const u8) !void {
        try self.inner.put(key, value);
    }

    pub fn del(self: *WriteTxn, key: []const u8) !void {
        try self.inner.del(key);
    }

    pub fn commit(self: *WriteTxn) !u64 {
        return try self.inner.commit();
    }

    pub fn abort(self: *WriteTxn) void {
        self.inner.abort();
    }
};

pub const KV = struct { key: []const u8, value: []const u8 };

fn kvLess(_: void, a: KV, b: KV) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

test "range scan stable" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    var w = db.beginWrite();
    try w.put("a1", "1");
    try w.put("a2", "2");
    const id = try w.commit();

    var r = try db.beginReadAt(id);
    defer r.close();
    const items = try r.scan("a");
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(std.mem.eql(u8, items[0].value, "1"));
    try std.testing.expect(std.mem.eql(u8, items[1].value, "2"));
}
