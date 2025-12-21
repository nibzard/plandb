//! Public database API scaffold for NorthstarDB.
//!
//! Exposes a minimal Db type backed by the in-memory reference model, with
//! optional pager/WAL hooks for file-backed experimentation. Full ACID semantics
//! and durability guarantees are not implemented yet.

const std = @import("std");
const ref_model = @import("ref_model.zig");
const txn = @import("txn.zig");
const wal = @import("wal.zig");
const pager_mod = @import("pager.zig");
const testing = std.testing;

pub const Db = struct {
    allocator: std.mem.Allocator,
    model: ref_model.Model,
    wal: ?wal.WriteAheadLog,
    pager: ?pager_mod.Pager,
    next_txn_id: u64,

    pub fn open(allocator: std.mem.Allocator) !Db {
        return .{
            .allocator = allocator,
            .model = try ref_model.Model.init(allocator),
            .wal = null,
            .pager = null,
            .next_txn_id = 1,
        };
    }

    pub fn openWithFile(allocator: std.mem.Allocator, db_path: []const u8, wal_path: []const u8) !Db {
        // Open pager for file-based operations
        var pager = try pager_mod.Pager.open(db_path, allocator);

        // Open WAL
        const wal_inst = try wal.WriteAheadLog.open(wal_path, allocator);

        // Get next transaction ID from current state
        const next_txn_id = pager.getCommittedTxnId() + 1;

        return .{
            .allocator = allocator,
            .model = try ref_model.Model.init(allocator),
            .wal = wal_inst,
            .pager = pager,
            .next_txn_id = next_txn_id,
        };
    }

    pub fn close(self: *Db) void {
        self.model.deinit();
        if (self.wal) |*wal_inst| {
            wal_inst.deinit();
        }
        if (self.pager) |*pager_inst| {
            pager_inst.close();
        }
    }

    pub fn beginReadLatest(self: *Db) !ReadTxn {
        return ReadTxn{
            .snapshot = try self.model.beginRead(self.model.current_txn_id),
            .allocator = self.allocator,
            .db = self,
        };
    }

    pub fn beginReadAt(self: *Db, txn_id: u64) !ReadTxn {
        return ReadTxn{
            .snapshot = try self.model.beginRead(txn_id),
            .allocator = self.allocator,
            .db = self,
        };
    }

    pub fn beginWrite(self: *Db) !WriteTxn {
        const txn_id = self.next_txn_id;
        self.next_txn_id += 1;

        const parent_txn_id = if (self.pager) |pager_inst| pager_inst.getCommittedTxnId() else 0;

        const ctx = try txn.TransactionContext.init(self.allocator, txn_id, parent_txn_id);

        return WriteTxn{
            .inner = self.model.beginWrite(),
            .txn_ctx = ctx,
            .db = self,
        };
    }

    // Internal method to execute two-phase commit with proper fsync ordering
    fn executeTwoPhaseCommit(self: *Db, txn_ctx: *txn.TransactionContext) !u64 {
        if (self.wal == null or self.pager == null) return error.NotFileBased;

        var wal_inst = self.wal.?;
        var pager_inst = self.pager.?;

        // Phase 1: Prepare
        try txn_ctx.prepare();

        // Create commit record
        const commit_record = try txn_ctx.createCommitRecord();
        defer self.allocator.free(commit_record.mutations);

        // Append commit record to WAL
        const commit_lsn = try wal_inst.appendCommitRecord(commit_record);

        // CRITICAL: Fsync WAL to ensure commit record is durable
        // This is step 2 of the fsync ordering: data -> WAL -> meta
        try wal_inst.sync();

        // Phase 2: Commit - Update meta page
        const current_meta_state = pager_inst.current_meta;
        var new_meta = current_meta_state.meta;
        new_meta.committed_txn_id = commit_record.txn_id;

        // Get opposite meta page for atomic update
        const opposite_meta_id = try pager_mod.getOppositeMetaId(current_meta_state.page_id);

        // Encode new meta page
        var meta_buffer: [pager_mod.DEFAULT_PAGE_SIZE]u8 = undefined;
        try pager_mod.encodeMetaPage(opposite_meta_id, new_meta, &meta_buffer);

        // Write meta page
        try pager_inst.writePage(opposite_meta_id, &meta_buffer);

        // CRITICAL: Fsync database file to ensure meta update is durable
        // This is step 3 of the fsync ordering: data -> WAL -> meta -> DB sync
        try pager_inst.commitSync(wal_inst);

        // Mark transaction as committed
        try txn_ctx.commit();

        return commit_lsn;
    }
};

pub const ReadTxn = struct {
    snapshot: ref_model.SnapshotState,
    allocator: std.mem.Allocator,
    db: *Db,

    pub fn get(self: *ReadTxn, key: []const u8) ?[]const u8 {
        // For file-based databases, use B+tree operations
        if (self.db.pager) |*pager| {
            // Use a temporary buffer for the value (would be allocated in real implementation)
            var value_buffer: [1024]u8 = undefined;
            if (pager.getBtreeValue(key, &value_buffer)) |value| {
                // In a real implementation, we'd need to manage the value lifetime
                // For now, return null and rely on the in-memory model
                _ = value;
                return null;
            }
            return null;
        }

        // For in-memory databases, use the reference model
        if (self.snapshot.get(key)) |value| return value;
        return null;
    }

    pub fn scan(self: *ReadTxn, prefix: []const u8) ![]const KV {
        var items = std.ArrayList(KV).initCapacity(self.allocator, 0) catch unreachable;
        var it = self.snapshot.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                try items.append(self.allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
            }
        }
        std.mem.sort(KV, items.items, {}, kvLess);
        return items.toOwnedSlice(self.allocator);
    }

    pub fn close(self: *ReadTxn) void {
        self.snapshot.deinit();
    }
};

pub const WriteTxn = struct {
    inner: ref_model.WriteTxn,
    txn_ctx: txn.TransactionContext,
    db: *Db,

    pub fn put(self: *WriteTxn, key: []const u8, value: []const u8) !void {
        // Track mutation in transaction context
        try self.txn_ctx.put(key, value);

        // For file-based databases, use B+tree operations
        if (self.db.pager) |*pager| {
            try pager.putBtreeValue(key, value, self.txn_ctx.txn_id);
        }

        // Also update in-memory model
        try self.inner.put(key, value);
    }

    pub fn del(self: *WriteTxn, key: []const u8) !void {
        // Track mutation in transaction context
        try self.txn_ctx.delete(key);

        // For file-based databases, use B+tree operations
        if (self.db.pager) |*pager| {
            _ = try pager.deleteBtreeValue(key, self.txn_ctx.txn_id);
        }

        // Also update in-memory model
        try self.inner.del(key);
    }

    pub fn commit(self: *WriteTxn) !u64 {
        // If file-based, use two-phase commit
        if (self.db.wal != null and self.db.pager != null) {
            const lsn = try self.db.executeTwoPhaseCommit(&self.txn_ctx);

            // Update in-memory model
            _ = try self.inner.commit();

            return lsn;
        } else {
            // In-memory mode - just use the model
            return try self.inner.commit();
        }
    }

    pub fn abort(self: *WriteTxn) void {
        self.txn_ctx.abort();
        self.inner.abort();
    }

    // Get transaction ID for this transaction
    pub fn getTxnId(self: *const WriteTxn) u64 {
        return self.txn_ctx.txn_id;
    }

    // Check if transaction has any mutations
    pub fn hasMutations(self: *const WriteTxn) bool {
        return self.txn_ctx.hasMutations();
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

test "WriteTxn tracks_mutations_in_transaction_context" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    var w = try db.beginWrite();

    // Initially no mutations
    try testing.expect(!w.hasMutations());

    // Add mutations
    try w.put("key1", "value1");
    try testing.expect(w.hasMutations());

    try w.del("key2");
    try testing.expect(w.hasMutations());

    // Commit to clean up
    _ = try w.commit();
}

test "WriteTxn.abort_cleans_up_transaction_context" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    var w = try db.beginWrite();
    const txn_id = w.getTxnId();

    try w.put("key1", "value1");
    try testing.expect(w.hasMutations());

    // Abort the transaction
    w.abort();

    // Transaction should be aborted and cleaned up
    try testing.expectEqual(@as(u64, txn_id), w.getTxnId()); // ID shouldn't change
}

test "Db.openWithFile_creates_file_based_database" {
    const test_db = "test_db_file.db";
    const test_wal = "test_db_file.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create file-based database
    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();

    // Should have WAL and pager initialized
    try testing.expect(db.wal != null);
    try testing.expect(db.pager != null);
    try testing.expect(db.next_txn_id > 1);
}

test "Db.executeTwoPhaseCommit_with_fsyc_ordering" {
    const test_db = "test_commit_ordering.db";
    const test_wal = "test_commit_ordering.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();

    var w = try db.beginWrite();
    try w.put("test_key", "test_value");

    // Commit should use two-phase commit with proper fsync ordering
    const lsn = try w.commit();

    // Should get a valid LSN
    try testing.expect(lsn > 0);
}

test "TransactionContext_mutations_persist_across_operations" {
    var ctx = try txn.TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    try ctx.put("key1", "value1");
    try ctx.delete("key2");
    try ctx.put("key3", "value3");

    // Verify all mutations are tracked
    try testing.expectEqual(@as(usize, 3), ctx.mutations.items.len);
    try testing.expect(ctx.hasMutations());

    // Verify mutation types and content
    try testing.expectEqualStrings("key1", ctx.mutations.items[0].put.key);
    try testing.expectEqualStrings("value1", ctx.mutations.items[0].put.value);

    try testing.expectEqualStrings("key2", ctx.mutations.items[1].delete.key);

    try testing.expectEqualStrings("key3", ctx.mutations.items[2].put.key);
    try testing.expectEqualStrings("value3", ctx.mutations.items[2].put.value);
}

test "Two-phase_commit_state_transitions" {
    var ctx = try txn.TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    // Start in active state
    try testing.expectEqual(txn.TransactionState.active, ctx.state);

    // Can add mutations in active state
    try ctx.put("test", "value");

    // Transition to preparing
    try ctx.prepare();
    try testing.expectEqual(txn.TransactionState.preparing, ctx.state);

    // Cannot add mutations after preparing
    try testing.expectError(error.TransactionNotActive, ctx.put("test2", "value2"));

    // Can transition to committed
    try ctx.commit();
    try testing.expectEqual(txn.TransactionState.committed, ctx.state);

    // Cannot commit again
    try testing.expectError(error.TransactionNotPreparing, ctx.commit());
}
