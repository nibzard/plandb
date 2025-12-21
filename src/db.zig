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
const snapshot = @import("snapshot.zig");
const testing = std.testing;

pub const WriteBusy = error{
    WriteBusy,
};

pub const Db = struct {
    allocator: std.mem.Allocator,
    model: ref_model.Model,
    wal: ?wal.WriteAheadLog,
    pager: ?pager_mod.Pager,
    next_txn_id: u64,
    snapshot_registry: ?snapshot.SnapshotRegistry,
    writer_active: bool,
    log_path: ?[]const u8, // Phase 4: Path to separate .log file

    pub fn open(allocator: std.mem.Allocator) !Db {
        return .{
            .allocator = allocator,
            .model = try ref_model.Model.init(allocator),
            .wal = null,
            .pager = null,
            .next_txn_id = 1,
            .snapshot_registry = null, // In-memory databases don't need snapshot registry
            .writer_active = false,
            .log_path = null, // In-memory databases don't need log file
        };
    }

    pub fn openWithFile(allocator: std.mem.Allocator, db_path: []const u8, wal_path: []const u8) !Db {
        // Check if database file exists
        const db_exists = blk: {
            const file = std.fs.cwd().openFile(db_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            file.close();
            break :blk true;
        };

        // Open or create pager
        var pager = if (!db_exists)
            try pager_mod.Pager.create(db_path, allocator)
        else
            try pager_mod.Pager.open(db_path, allocator);

        // Check if WAL exists
        const wal_exists = blk: {
            const file = std.fs.cwd().openFile(wal_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            file.close();
            break :blk true;
        };

        // Open or create WAL
        const wal_inst = if (!wal_exists)
            try wal.WriteAheadLog.create(wal_path, allocator)
        else
            try wal.WriteAheadLog.open(wal_path, allocator);

        // Phase 4: Create log path from database path
        const log_path = try createLogPathFromDbPath(allocator, db_path);

        // Get current state from pager
        const committed_txn_id = pager.getCommittedTxnId();
        const root_page_id = pager.getRootPageId();
        const next_txn_id = committed_txn_id + 1;

        // Initialize snapshot registry with current state
        const snapshot_registry = try snapshot.SnapshotRegistry.init(allocator, committed_txn_id, root_page_id);

        return .{
            .allocator = allocator,
            .model = try ref_model.Model.init(allocator),
            .wal = wal_inst,
            .pager = pager,
            .next_txn_id = next_txn_id,
            .snapshot_registry = snapshot_registry,
            .writer_active = false,
            .log_path = log_path,
        };
    }

    // Helper function to create log path from database path
    fn createLogPathFromDbPath(allocator: std.mem.Allocator, db_path: []const u8) ![]const u8 {
        // Extract the base name without extension and add .log extension
        const path_without_ext = std.fs.path.stem(db_path);
        return std.fmt.allocPrint(allocator, "{s}.log", .{path_without_ext});
    }

    pub fn close(self: *Db) void {
        self.model.deinit();
        if (self.wal) |*wal_inst| {
            wal_inst.deinit();
        }
        if (self.pager) |*pager_inst| {
            pager_inst.close();
        }
        if (self.snapshot_registry) |*registry| {
            registry.deinit();
        }
        if (self.log_path) |log_path| {
            self.allocator.free(log_path);
        }
    }

    pub fn beginReadLatest(self: *Db) !ReadTxn {
        // For file-based databases, use snapshot registry
        if (self.snapshot_registry) |*registry| {
            const latest_txn_id = registry.getCurrentTxnId();
            const latest_root = registry.getLatestSnapshot();

            return ReadTxn{
                .snapshot = try self.model.beginRead(self.model.current_txn_id),
                .allocator = self.allocator,
                .db = self,
                .txn_id = latest_txn_id,
                .root_page_id = latest_root,
            };
        }

        // For in-memory databases, use model
        return ReadTxn{
            .snapshot = try self.model.beginRead(self.model.current_txn_id),
            .allocator = self.allocator,
            .db = self,
            .txn_id = self.model.current_txn_id,
            .root_page_id = 0, // Not used for in-memory
        };
    }

    pub fn beginReadAt(self: *Db, txn_id: u64) !ReadTxn {
        // For file-based databases, use snapshot registry
        if (self.snapshot_registry) |*registry| {
            const root_page_id = registry.getSnapshotRoot(txn_id) orelse return error.SnapshotNotFound;

            return ReadTxn{
                .snapshot = try self.model.beginRead(txn_id),
                .allocator = self.allocator,
                .db = self,
                .txn_id = txn_id,
                .root_page_id = root_page_id,
            };
        }

        // For in-memory databases, use model
        return ReadTxn{
            .snapshot = try self.model.beginRead(txn_id),
            .allocator = self.allocator,
            .db = self,
            .txn_id = txn_id,
            .root_page_id = 0, // Not used for in-memory
        };
    }

    pub fn beginWrite(self: *Db) !WriteTxn {
        // Enforce single-writer rule
        if (self.writer_active) {
            return WriteBusy.WriteBusy;
        }

        const txn_id = self.next_txn_id;
        self.next_txn_id += 1;

        const parent_txn_id = if (self.pager) |pager_inst| pager_inst.getCommittedTxnId() else 0;

        const ctx = try txn.TransactionContext.init(self.allocator, txn_id, parent_txn_id);

        // Mark writer as active
        self.writer_active = true;

        return WriteTxn{
            .inner = self.model.beginWrite(),
            .txn_ctx = ctx,
            .db = self,
        };
    }

    // Internal method to execute two-phase commit with proper fsync ordering
    fn executeTwoPhaseCommit(self: *Db, txn_ctx: *txn.TransactionContext) !u64 {
        if (self.wal == null or self.pager == null) return error.NotFileBased;

        const wal_inst = self.wal.?; // Still needed for commitSync
        var pager_inst = self.pager.?;

        // Phase 1: Prepare
        try txn_ctx.prepare();

        // Apply mutations to B+tree first to get the new root page ID
        var root_page_id: u64 = pager_inst.getRootPageId();
        for (txn_ctx.mutations.items) |mutation| {
            switch (mutation) {
                .put => |put_op| {
                    try pager_inst.putBtreeValue(put_op.key, put_op.value, txn_ctx.txn_id);
                },
                .delete => |del_op| {
                    // TODO: Implement delete operation when needed
                    _ = del_op;
                },
            }
        }
        root_page_id = pager_inst.getRootPageId(); // Get new root after mutations

        // Create commit record with the correct root page ID
        const commit_record = try txn_ctx.createCommitRecord(root_page_id);
        defer self.allocator.free(commit_record.mutations);

        // Phase 4: Append to separate .log file instead of WAL
        if (self.log_path == null) return error.LogPathNotSet;

        // Create or open the separate log file
        var log_file = try openOrCreateLogFile(self.log_path.?);
        defer log_file.close();

        // Write commit record to log file
        try self.writeCommitRecordToLog(&log_file, commit_record);

        // CRITICAL: Fsync log file to ensure commit record is durable
        // This is step 1 of the new fsync ordering: log -> meta -> database
        try log_file.sync();

        // Get the current meta state after applying mutations (putBtreeValue already updated it)
        const current_meta_state = pager_inst.current_meta;
        var new_meta = current_meta_state.meta;
        new_meta.committed_txn_id = commit_record.txn_id;

        // Get opposite meta page for atomic update
        const opposite_meta_id = try pager_mod.getOppositeMetaId(current_meta_state.page_id);

        // Encode new meta page with updated txn_id
        var meta_buffer: [pager_mod.DEFAULT_PAGE_SIZE]u8 = undefined;
        try pager_mod.encodeMetaPage(opposite_meta_id, new_meta, &meta_buffer);

        // Write meta page
        try pager_inst.writePage(opposite_meta_id, &meta_buffer);

        // Update pager's current_meta to reflect the new state
        const meta_header = try pager_mod.PageHeader.decode(&meta_buffer);
        pager_inst.current_meta = .{
            .page_id = opposite_meta_id,
            .header = meta_header,
            .meta = new_meta,
        };

        // CRITICAL: Fsync database file to ensure meta update is durable
        // This is step 2 of the fsync ordering: log -> meta -> database sync
        try pager_inst.commitSync(wal_inst);

        // Mark transaction as committed
        try txn_ctx.commit();

        // Get new root page ID after commit (now that current_meta is updated)
        const new_root_page_id = pager_inst.getRootPageId();

        // Register new snapshot in snapshot registry
        if (self.snapshot_registry) |*registry| {
            try registry.registerSnapshot(commit_record.txn_id, new_root_page_id);
        }

        return commit_record.txn_id; // Return txn_id as LSN since we're not using WAL anymore
    }

    // Helper function to open or create log file
    fn openOrCreateLogFile(log_path: []const u8) !std.fs.File {
        // Try to open existing file, create if it doesn't exist
        return std.fs.cwd().openFile(log_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(log_path, .{ .truncate = false, .read = true }),
            else => return err,
        };
    }

    // Helper function to write commit record to log file with proper framing
    fn writeCommitRecordToLog(self: *Db, log_file: *std.fs.File, commit_record: txn.CommitRecord) !void {
        // For Phase 4, we need to write complete framed records to the .log file
        // This includes: RecordHeader + Payload + RecordTrailer

        // Create a temporary WAL instance for proper record framing
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}_temp_wal", .{self.log_path.?});
        defer self.allocator.free(temp_path);

        var temp_wal = try wal.WriteAheadLog.create(temp_path, self.allocator);
        defer temp_wal.deinit();

        // Use the WAL's appendCommitRecord to get proper framing
        _ = try temp_wal.appendCommitRecord(commit_record);
        try temp_wal.flush();

        // Read the framed record from temp WAL and write to log file
        var temp_file = try std.fs.cwd().openFile(temp_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return error.InternalError,
            else => return err,
        };
        defer temp_file.close();
        defer std.fs.cwd().deleteFile(temp_path) catch {};

        const record_size = try temp_file.getEndPos();
        const record_buffer = try self.allocator.alloc(u8, record_size);
        defer self.allocator.free(record_buffer);

        const bytes_read = try temp_file.readAll(record_buffer);
        if (bytes_read != record_size) return error.InternalError;

        // Write the fully framed record to the log file
        const file_size = try log_file.getEndPos();
        _ = try log_file.pwriteAll(record_buffer, file_size);
    }
};

pub const ReadTxn = struct {
    snapshot: ref_model.SnapshotState,
    allocator: std.mem.Allocator,
    db: *Db,
    txn_id: u64, // Transaction ID for this snapshot
    root_page_id: u64, // Root page ID for this snapshot

    pub fn get(self: *ReadTxn, key: []const u8) ?[]const u8 {
        // For file-based databases, use B+tree operations with snapshot root
        if (self.db.pager) |*pager| {
            // Use a temporary buffer for the value (would be allocated in real implementation)
            var value_buffer: [1024]u8 = undefined;

            // Read from the snapshot's root page, not the current root
            if (pager.getBtreeValueAtRoot(key, &value_buffer, self.root_page_id) catch |err| switch (err) {
                error.CorruptBtree => return null,
                error.BufferTooSmall => return null,
                else => return null,
            }) |value| {
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

    // Create an iterator for all key-value pairs in order
    // Note: Currently only supported for file-based databases
    pub fn iterator(self: *ReadTxn) !ReadIterator {
        if (self.db.pager) |*pager| {
            return ReadIterator{
                .iter = try pager.createIteratorWithRangeAtRoot(self.allocator, null, null, self.root_page_id),
            };
        }

        // In-memory databases don't support this iterator API yet
        // Use the scan() method for in-memory iteration
        return error.InMemoryIteratorNotSupported;
    }

    // Create an iterator for a specific key range [start_key, end_key)
    // Note: Currently only supported for file-based databases
    pub fn iteratorRange(self: *ReadTxn, start_key: ?[]const u8, end_key: ?[]const u8) !ReadIterator {
        if (self.db.pager) |*pager| {
            return ReadIterator{
                .iter = try pager.createIteratorWithRangeAtRoot(self.allocator, start_key, end_key, self.root_page_id),
            };
        }

        // In-memory databases don't support this iterator API yet
        // Use the scan() method for in-memory iteration
        return error.InMemoryIteratorNotSupported;
    }

    // Prefix scan is a convenience method that uses range scan under the hood
    pub fn scan(self: *ReadTxn, prefix: []const u8) ![]const KV {
        // For file-based databases, use B+tree iterator
        if (self.db.pager) |*pager| {
            // Create range iterator for prefix scan
            // Start with prefix, end with next character after prefix
            const start_key = prefix;

            // Calculate end_key by finding next string after prefix
            var end_key_buffer: [256]u8 = undefined;
            var end_key_len: usize = prefix.len;
            if (prefix.len < end_key_buffer.len) {
                @memcpy(end_key_buffer[0..prefix.len], prefix);

                // Find last character and increment it (simple approach)
                if (prefix.len > 0) {
                    var last_char_idx = prefix.len - 1;
                    while (true) {
                        if (end_key_buffer[last_char_idx] == 255) {
                            if (last_char_idx == 0) {
                                // All characters were 255, set end_key to empty to get all keys
                                end_key_len = 0;
                                break;
                            }
                            end_key_buffer[last_char_idx] = 0;
                            last_char_idx -= 1;
                        } else {
                            end_key_buffer[last_char_idx] += 1;
                            break;
                        }
                    }
                }
            }

            const end_key = if (end_key_len > 0) end_key_buffer[0..end_key_len] else null;

            var iter = try pager.createIteratorWithRangeAtRoot(self.allocator, start_key, end_key, self.root_page_id);

            // First pass: count items to allocate exact size
            var item_count: usize = 0;
            var temp_iter = try pager.createIteratorWithRangeAtRoot(self.allocator, start_key, end_key, self.root_page_id);
            while (try temp_iter.next()) |kv| {
                if (std.mem.startsWith(u8, kv.key, prefix)) {
                    item_count += 1;
                }
            }

            // Allocate exact sized array
            var items = try self.allocator.alloc(KV, item_count);
            var current_index: usize = 0;

            while (try iter.next()) |kv| {
                // Double-check prefix match (in case our end_key calculation isn't perfect)
                if (std.mem.startsWith(u8, kv.key, prefix)) {
                    // Copy key and value (they're in temporary buffers)
                    const key_copy = try self.allocator.alloc(u8, kv.key.len);
                    @memcpy(key_copy, kv.key);

                    const value_copy = try self.allocator.alloc(u8, kv.value.len);
                    @memcpy(value_copy, kv.value);

                    items[current_index] = .{ .key = key_copy, .value = value_copy };
                    current_index += 1;
                }
            }

            return items;
        }

        // For in-memory databases, use the reference model
        // First pass: count matching items
        var item_count: usize = 0;
        var it = self.snapshot.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                item_count += 1;
            }
        }

        // Allocate exact sized array
        var items = try self.allocator.alloc(KV, item_count);
        var current_index: usize = 0;

        // Reset iterator and collect items
        it = self.snapshot.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                items[current_index] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
                current_index += 1;
            }
        }

        // Sort the results
        std.mem.sort(KV, items, {}, kvLess);
        return items;
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

    pub fn get(self: *WriteTxn, key: []const u8) ?[]const u8 {
        // First check if there's a pending mutation for this key
        if (self.txn_ctx.getPendingMutation(key)) |pending| {
            // Key was mutated in this transaction
            if (pending.is_deleted) {
                return null; // Key was deleted in this transaction
            } else {
                return pending.value.?; // Return the updated value
            }
        }

        // No pending mutation, check the database state
        // For file-based databases, read from B+tree
        if (self.db.pager) |*pager| {
            // Use a stack-allocated buffer for the value
            var buffer: [1024]u8 = undefined;
            if (pager.getBtreeValue(key, &buffer)) |value| {
                return value;
            } else |_| {
                return null;
            }
        }

        // For in-memory databases, check the writes then the model
        if (self.inner.writes.get(key)) |value| {
            return value; // Return value from write set (may be null if deleted)
        }
        // Fall back to the current model state
        const current_snapshot = self.inner.model.beginRead(self.inner.model.current_txn_id) catch return null;
        return current_snapshot.get(key);
    }

    pub fn commit(self: *WriteTxn) !u64 {
        defer {
            // Release writer lock regardless of outcome
            self.db.writer_active = false;
        }

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
        // Release writer lock
        self.db.writer_active = false;

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

// Iterator for reading key-value pairs from a ReadTxn
pub const ReadIterator = struct {
    // For file-based databases - this is the main focus
    iter: ?pager_mod.BtreeIterator = null,

    // For in-memory databases - simplified for now
    unsupported_in_memory: bool = false,

    const Self = @This();

    pub fn next(self: *Self) !?KV {
        if (self.iter) |*iter| {
            // File-based B+tree iterator
            if (try iter.next()) |kv| {
                return .{ .key = kv.key, .value = kv.value };
            }
            return null;
        }

        // In-memory iteration not yet implemented for this iterator
        // Use the existing scan() method instead
        return error.InMemoryIteratorNotSupported;
    }

    pub fn valid(self: *const Self) bool {
        if (self.iter) |iter| {
            return iter.valid();
        } else {
            return false;
        }
    }

    // No explicit close needed - iterators are cleaned up when ReadTxn is closed
};

fn kvLess(_: void, a: KV, b: KV) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

test "range scan stable" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    var w = try db.beginWrite();
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

test "Snapshot_registry_functionality" {
    const test_db = "test_snapshots.db";
    const test_wal = "test_snapshots.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();

    // Should have snapshot registry initialized
    try testing.expect(db.snapshot_registry != null);
    var registry = &db.snapshot_registry.?;

    // Initial state - should have genesis snapshot
    try testing.expectEqual(@as(u64, 0), registry.getCurrentTxnId());
    try testing.expect(registry.hasSnapshot(0));

    // Write some data and commit
    var w1 = try db.beginWrite();
    try w1.put("key1", "value1");
    const txn_id_1 = try w1.commit();

    // Registry should be updated with new snapshot
    try testing.expectEqual(txn_id_1, registry.getCurrentTxnId());
    try testing.expect(registry.hasSnapshot(txn_id_1));

    // Write more data
    var w2 = try db.beginWrite();
    try w2.put("key2", "value2");
    const txn_id_2 = try w2.commit();

    // Should have all snapshots
    try testing.expectEqual(txn_id_2, registry.getCurrentTxnId());
    try testing.expect(registry.hasSnapshot(0));
    try testing.expect(registry.hasSnapshot(txn_id_1));
    try testing.expect(registry.hasSnapshot(txn_id_2));

    // Read from different snapshots
    var r1 = try db.beginReadAt(txn_id_1);
    defer r1.close();
    try testing.expectEqual(txn_id_1, r1.txn_id);

    var r_latest = try db.beginReadLatest();
    defer r_latest.close();
    try testing.expectEqual(txn_id_2, r_latest.txn_id);
}

test "Snapshot_registry_cleanup" {
    var registry = try snapshot.SnapshotRegistry.init(std.testing.allocator, 0, 0);
    defer registry.deinit();

    // Add some snapshots
    try registry.registerSnapshot(1, 5);
    try registry.registerSnapshot(2, 6);
    try registry.registerSnapshot(3, 7);
    try registry.registerSnapshot(4, 8);
    try registry.registerSnapshot(5, 9);

    try testing.expectEqual(@as(usize, 6), registry.snapshots.count());

    // Clean up keeping last 2 snapshots
    const removed = try registry.cleanupOldSnapshots(100, 2);
    try testing.expectEqual(@as(usize, 3), removed);
    try testing.expectEqual(@as(usize, 3), registry.snapshots.count());
    try testing.expect(!registry.hasSnapshot(3));
    try testing.expect(registry.hasSnapshot(4));
    try testing.expect(registry.hasSnapshot(5));
}

test "Single_writer_lock_enforcement" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    // Initially no writer should be active
    try testing.expect(!db.writer_active);

    // Begin first write transaction - should succeed
    var w1 = try db.beginWrite();
    try testing.expect(db.writer_active);

    // Attempt to begin second write transaction - should fail with WriteBusy
    const w2_result = db.beginWrite();
    try testing.expectError(WriteBusy.WriteBusy, w2_result);

    // Commit first transaction - should release the lock
    _ = try w1.commit();
    try testing.expect(!db.writer_active);

    // Now we should be able to begin a new write transaction
    var w3 = try db.beginWrite();
    try testing.expect(db.writer_active);

    // Abort should also release the lock
    w3.abort();
    try testing.expect(!db.writer_active);
}

test "Single_writer_with_abort_releases_lock" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    // Begin write transaction
    var w1 = try db.beginWrite();
    try testing.expect(db.writer_active);

    // Abort should release the lock
    w1.abort();
    try testing.expect(!db.writer_active);

    // Should be able to begin new transaction after abort
    var w2 = try db.beginWrite();
    defer w2.abort();
    try testing.expect(db.writer_active);
}

test "WriteTxn_read_your_writes" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    // Begin a write transaction
    var w = try db.beginWrite();
    defer w.abort();

    // Should not find non-existent key
    const non_existent = w.get("non_existent_key");
    try testing.expect(non_existent == null);

    // Put a new key
    try w.put("new_key", "new_value");

    // Should read own writes (core read-your-writes functionality)
    const new_value = w.get("new_key");
    try testing.expect(new_value != null);
    try testing.expect(std.mem.eql(u8, "new_value", new_value.?));

    // Update the same key
    try w.put("new_key", "updated_value");

    // Should read the updated value (latest write wins)
    const updated_value = w.get("new_key");
    try testing.expect(updated_value != null);
    try testing.expect(std.mem.eql(u8, "updated_value", updated_value.?));

    // Delete the key
    try w.del("new_key");

    // Should not find deleted key (even though it existed before)
    const deleted_value = w.get("new_key");
    try testing.expect(deleted_value == null);

    // Put and delete the same key in same transaction
    try w.put("temp_key", "temp_value");
    const temp_value = w.get("temp_key");
    try testing.expect(temp_value != null);
    try testing.expect(std.mem.eql(u8, "temp_value", temp_value.?));

    try w.del("temp_key");
    const temp_after_delete = w.get("temp_key");
    try testing.expect(temp_after_delete == null);

    // Multiple operations on the same key should work correctly
    try w.put("counter", "1");
    try testing.expect(std.mem.eql(u8, "1", w.get("counter").?));

    try w.put("counter", "2");
    try testing.expect(std.mem.eql(u8, "2", w.get("counter").?));

    try w.del("counter");
    try testing.expect(w.get("counter") == null);

    try w.put("counter", "3");
    try testing.expect(std.mem.eql(u8, "3", w.get("counter").?));

    // Test that multiple independent keys work
    try w.put("key1", "value1");
    try w.put("key2", "value2");
    try w.put("key3", "value3");

    try testing.expect(std.mem.eql(u8, "value1", w.get("key1").?));
    try testing.expect(std.mem.eql(u8, "value2", w.get("key2").?));
    try testing.expect(std.mem.eql(u8, "value3", w.get("key3").?));

    // Delete one key and verify others still exist
    try w.del("key2");
    try testing.expect(std.mem.eql(u8, "value1", w.get("key1").?));
    try testing.expect(w.get("key2") == null);
    try testing.expect(std.mem.eql(u8, "value3", w.get("key3").?));
}

test "ReadTxn_iterator_file_based" {
    const test_db = "test_iterator.db";
    const test_wal = "test_iterator.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();

    // Insert test data
    var w = try db.beginWrite();
    try w.put("a", "1");
    try w.put("b", "2");
    try w.put("c", "3");
    try w.put("d", "4");
    try w.put("e", "5");
    _ = try w.commit();

    // Test full iteration
    var r = try db.beginReadLatest();
    defer r.close();

    var iter = try r.iterator();
    defer {}

    var count: usize = 0;
    var keys: [5][]const u8 = undefined;
    while (try iter.next()) |kv| {
        keys[count] = kv.key;
        count += 1;
    }

    try testing.expectEqual(@as(usize, 5), count);

    // Verify keys are in sorted order
    try testing.expectEqualStrings("a", keys[0]);
    try testing.expectEqualStrings("b", keys[1]);
    try testing.expectEqualStrings("c", keys[2]);
    try testing.expectEqualStrings("d", keys[3]);
    try testing.expectEqualStrings("e", keys[4]);
}

test "ReadTxn_iteratorRange_file_based" {
    const test_db = "test_iterator_range.db";
    const test_wal = "test_iterator_range.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();

    // Insert test data
    var w = try db.beginWrite();
    try w.put("apple", "red");
    try w.put("apricot", "orange");
    try w.put("banana", "yellow");
    try w.put("blueberry", "blue");
    try w.put("cherry", "red");
    _ = try w.commit();

    // Test range iteration
    var r = try db.beginReadLatest();
    defer r.close();

    var iter = try r.iteratorRange("ap", "bq"); // Should get apple, apricot, banana
    defer {}

    var items: [3]KV = undefined;
    var count: usize = 0;
    while (try iter.next()) |kv| {
        items[count] = kv;
        count += 1;
        if (count >= items.len) break;
    }

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("apple", items[0].key);
    try testing.expectEqualStrings("red", items[0].value);
    try testing.expectEqualStrings("apricot", items[1].key);
    try testing.expectEqualStrings("orange", items[1].value);
    try testing.expectEqualStrings("banana", items[2].key);
    try testing.expectEqualStrings("yellow", items[2].value);
}

test "ReadTxn_scan_prefix" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    // Insert test data
    var w = try db.beginWrite();
    try w.put("user:001", "Alice");
    try w.put("user:002", "Bob");
    try w.put("user:003", "Charlie");
    try w.put("product:001", "Widget");
    try w.put("user:004", "David");
    _ = try w.commit();

    // Test prefix scan
    var r = try db.beginReadLatest();
    defer r.close();

    const user_items = try r.scan("user:");
    defer testing.allocator.free(user_items);

    try testing.expectEqual(@as(usize, 4), user_items.len);
    try testing.expectEqualStrings("user:001", user_items[0].key);
    try testing.expectEqualStrings("Alice", user_items[0].value);
    try testing.expectEqualStrings("user:002", user_items[1].key);
    try testing.expectEqualStrings("Bob", user_items[1].value);
    try testing.expectEqualStrings("user:003", user_items[2].key);
    try testing.expectEqualStrings("Charlie", user_items[2].value);
    try testing.expectEqualStrings("user:004", user_items[3].key);
    try testing.expectEqualStrings("David", user_items[3].value);
}
