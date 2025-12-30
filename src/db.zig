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
const plugins = @import("plugins/manager.zig");
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
    plugin_manager: ?*plugins.PluginManager, // Phase 7: AI plugin system

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
            .plugin_manager = null, // No plugins by default
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
            .plugin_manager = null, // No plugins by default
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
        // Note: plugin_manager is not owned by Db, owner is responsible for cleanup
    }

    /// Attach a plugin manager to the database for AI intelligence integration
    /// The plugin_manager is not owned by Db - caller is responsible for cleanup
    pub fn attachPluginManager(self: *Db, manager: *plugins.PluginManager) void {
        self.plugin_manager = manager;
    }

    pub fn beginReadLatest(self: *Db) !ReadTxn {
        // For file-based databases, use snapshot registry
        if (self.snapshot_registry) |*registry| {
            const latest_txn_id = registry.getCurrentTxnId();
            const latest_root = registry.getLatestSnapshot();

            // For file-based DBs, model snapshot is empty (data is in B+tree)
            // Create an empty snapshot state
            var snap_state = ref_model.SnapshotState.init(self.allocator);
            errdefer snap_state.deinit();

            return ReadTxn{
                .snapshot = snap_state,
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

            // For file-based DBs, model snapshot is empty (data is in B+tree)
            // Create an empty snapshot state
            var snap_state = ref_model.SnapshotState.init(self.allocator);
            errdefer snap_state.deinit();

            return ReadTxn{
                .snapshot = snap_state,
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
        // Use pointer directly to avoid copying Pager
        const pager_inst = &self.pager.?;

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
                    _ = try pager_inst.deleteBtreeValue(del_op.key, txn_ctx.txn_id);
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

        // Phase 7: Execute plugin on_commit hooks
        // Plugin errors should not prevent commit - they're logged but don't fail the transaction
        if (self.plugin_manager) |manager| {
            var commit_ctx = plugins.CommitContext{
                .txn_id = commit_record.txn_id,
                .mutations = txn_ctx.mutations.items,
                .timestamp = @intCast(std.time.nanoTimestamp()),
                .metadata = std.StringHashMap([]const u8).init(self.allocator),
            };
            defer commit_ctx.deinit(self.allocator);

            var result = manager.execute_on_commit_hooks(commit_ctx) catch |err| {
                // Log the error but don't fail the commit
                std.log.err("Plugin hook execution failed: {}", .{err});
                return commit_record.txn_id;
            };
            defer result.deinit(self.allocator);

            if (!result.success) {
                // Log plugin errors but don't fail the commit
                for (result.errors) |plugin_err| {
                    std.log.err("Plugin '{s}' on_commit hook failed: {}", .{plugin_err.plugin_name, plugin_err.err});
                }
            }
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
        var temp_file = std.fs.cwd().openFile(temp_path, .{ .mode = .read_only }) catch |err| switch (err) {
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
            // Use a temporary buffer for the value
            var value_buffer: [4096]u8 = undefined;

            // Read from the snapshot's root page, not the current root
            if (pager.getBtreeValueAtRoot(key, &value_buffer, self.root_page_id) catch |err| switch (err) {
                error.CorruptBtree => return null,
                error.BufferTooSmall => return null,
                else => return null,
            }) |value| {
                // Allocate a copy of the value so it persists
                const value_copy = self.allocator.dupe(u8, value) catch return null;
                return value_copy;
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

    pub fn delete(self: *WriteTxn, key: []const u8) !void {
        return self.del(key);
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

    /// Atomically claim a task if it exists and is not already claimed
    ///
    /// This method implements compare-and-swap semantics to ensure that
    /// under concurrency, no task can be claimed by multiple agents.
    ///
    /// Arguments:
    /// - task_id: The ID of the task to claim
    /// - agent_id: The ID of the agent attempting to claim
    /// - claim_timestamp: Timestamp for when the claim is made
    ///
    /// Returns:
    /// - true if the claim was successful (task existed and was unclaimed)
    /// - false if the task doesn't exist or is already claimed
    ///
    /// The operation is atomic within the transaction and includes:
    /// 1. Check if task metadata exists (using get() with read-your-writes)
    /// 2. Check if claim:{task_id}:{agent_id} already exists (prevent duplicates)
    /// 3. Check if any other agent has already claimed this task (using claimed:{task_id} index)
    /// 4. If all checks pass, create the claim record and update the index
    pub fn claimTask(self: *WriteTxn, task_id: u64, agent_id: u64, claim_timestamp: i64) !bool {
        // Check if this specific agent has already claimed this task
        var claim_key_buf: [64]u8 = undefined;
        const claim_key = try std.fmt.bufPrint(&claim_key_buf, "claim:{d}:{d}", .{ task_id, agent_id });

        if (self.get(claim_key)) |_| {
            // This agent has already claimed this task
            return false;
        }

        // Check if the task metadata exists
        var task_key_buf: [32]u8 = undefined;
        const task_key = try std.fmt.bufPrint(&task_key_buf, "task:{d}", .{task_id});

        if (self.get(task_key)) |_| {
            // Task exists, check if it's already claimed using the index
            var claimed_index_key_buf: [32]u8 = undefined;
            const claimed_index_key = try std.fmt.bufPrint(&claimed_index_key_buf, "claimed:{d}", .{task_id});

            if (self.get(claimed_index_key)) |_| {
                // Task is already claimed by another agent
                return false;
            }

            // Task exists and is unclaimed, create the claim
            var claim_value_buf: [32]u8 = undefined;
            const claim_value = try std.fmt.bufPrint(&claim_value_buf, "{}", .{claim_timestamp});
            try self.put(claim_key, claim_value);

            // Update the claimed index to store this agent_id
            var claimed_index_value_buf: [32]u8 = undefined;
            const claimed_index_value = try std.fmt.bufPrint(&claimed_index_value_buf, "{}", .{agent_id});
            try self.put(claimed_index_key, claimed_index_value);

            // Update agent's active task count
            var agent_key_buf: [32]u8 = undefined;
            var agent_value_buf: [16]u8 = undefined;
            const agent_key = try std.fmt.bufPrint(&agent_key_buf, "agent:{d}:active", .{agent_id});

            const current_active_str = self.get(agent_key) orelse "0";
            const current_active = try std.fmt.parseInt(u32, current_active_str, 10);
            const new_active = current_active + 1;
            const new_active_value = try std.fmt.bufPrint(&agent_value_buf, "{}", .{new_active});
            try self.put(agent_key, new_active_value);

            return true; // Successfully claimed
        } else {
            // Task doesn't exist
            return false;
        }
    }

    /// Atomically complete a claimed task and cleanup the claim
    ///
    /// This method handles the completion of a task by:
    /// 1. Verifying the claim exists for this agent and task
    /// 2. Marking the task as completed
    /// 3. Removing the claim record
    /// 4. Clearing the claimed index
    /// 5. Decrementing the agent's active task count
    ///
    /// Arguments:
    /// - task_id: The ID of the task to complete
    /// - agent_id: The ID of the agent completing the task
    /// - completion_timestamp: Timestamp for when the task is completed
    ///
    /// Returns:
    /// - true if the completion was successful
    /// - false if the claim doesn't exist (task wasn't claimed by this agent)
    pub fn completeTask(self: *WriteTxn, task_id: u64, agent_id: u64, completion_timestamp: i64) !bool {
        // Verify the claim exists for this agent
        var claim_key_buf: [64]u8 = undefined;
        const claim_key = try std.fmt.bufPrint(&claim_key_buf, "claim:{d}:{d}", .{ task_id, agent_id });

        if (self.get(claim_key)) |_| {
            // Claim exists, proceed with completion

            // Mark task as completed
            var completed_key_buf: [32]u8 = undefined;
            var completed_value_buf: [32]u8 = undefined;
            const completed_key = try std.fmt.bufPrint(&completed_key_buf, "completed:{d}", .{task_id});
            const completed_value = try std.fmt.bufPrint(&completed_value_buf, "{}", .{completion_timestamp});
            try self.put(completed_key, completed_value);

            // Remove the claim
            try self.del(claim_key);

            // Clear the claimed index
            var claimed_index_key_buf: [32]u8 = undefined;
            const claimed_index_key = try std.fmt.bufPrint(&claimed_index_key_buf, "claimed:{d}", .{task_id});
            try self.del(claimed_index_key);

            // Decrement agent's active task count
            var agent_key_buf: [32]u8 = undefined;
            var agent_value_buf: [16]u8 = undefined;
            const agent_key = try std.fmt.bufPrint(&agent_key_buf, "agent:{d}:active", .{agent_id});

            if (self.get(agent_key)) |current_active_str| {
                const current_active = try std.fmt.parseInt(u32, current_active_str, 10);
                if (current_active > 0) {
                    const new_active = current_active - 1;
                    const new_active_value = try std.fmt.bufPrint(&agent_value_buf, "{}", .{new_active});
                    try self.put(agent_key, new_active_value);
                }
            }

            return true; // Successfully completed
        } else {
            // No claim exists for this agent and task
            return false;
        }
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

test "claim_task_atomic_semantics" {
    var database = try Db.open(testing.allocator);
    defer database.close();

    // Create a task first
    {
        var w = try database.beginWrite();
        const task_metadata = "{\"priority\":5,\"type\":1,\"created_at\":12345}";
        try w.put("task:42", task_metadata);
        _ = try w.commit();
    }

    // Test successful claim
    {
        var w = try database.beginWrite();
        const claimed = try w.claimTask(42, 1, 12346);
        try testing.expect(claimed);

        // Verify claim was created
        const claim = w.get("claim:42:1");
        try testing.expect(claim != null);
        try testing.expectEqualStrings("12346", claim.?);

        // Verify agent active count was updated
        const active_count = w.get("agent:1:active");
        try testing.expect(active_count != null);
        try testing.expectEqualStrings("1", active_count.?);

        _ = try w.commit();
    }

    // Test duplicate claim by same agent fails
    {
        var w = try database.beginWrite();
        const claimed = try w.claimTask(42, 1, 12347);
        try testing.expect(!claimed);
        _ = try w.commit();
    }

    // Test claim by different agent fails
    {
        var w = try database.beginWrite();
        const claimed = try w.claimTask(42, 2, 12348);
        try testing.expect(!claimed);
        _ = try w.commit();
    }

    // Test claim of non-existent task fails
    {
        var w = try database.beginWrite();
        const claimed = try w.claimTask(999, 3, 12349);
        try testing.expect(!claimed);
        _ = try w.commit();
    }
}

test "complete_task_atomic_semantics" {
    var database = try Db.open(testing.allocator);
    defer database.close();

    // Create a task and claim it
    {
        var w = try database.beginWrite();
        try w.put("task:42", "{\"priority\":5,\"type\":1,\"created_at\":12345}");
        const claimed = try w.claimTask(42, 1, 12346);
        try testing.expect(claimed);
        _ = try w.commit();
    }

    // Test successful completion
    {
        var w = try database.beginWrite();
        const completed = try w.completeTask(42, 1, 12350);
        try testing.expect(completed);

        // Verify task was marked as completed
        const completed_marker = w.get("completed:42");
        try testing.expect(completed_marker != null);
        try testing.expectEqualStrings("12350", completed_marker.?);

        // Verify claim was removed
        const claim = w.get("claim:42:1");
        try testing.expect(claim == null);

        // Verify agent active count was decremented
        const active_count = w.get("agent:1:active");
        try testing.expect(active_count != null);
        try testing.expectEqualStrings("0", active_count.?);

        _ = try w.commit();
    }

    // Test completion by wrong agent fails
    {
        var w = try database.beginWrite();
        const completed = try w.completeTask(42, 2, 12351);
        try testing.expect(!completed);
        _ = try w.commit();
    }

    // Test completion of non-existent claim fails
    {
        var w = try database.beginWrite();
        const completed = try w.completeTask(999, 1, 12352);
        try testing.expect(!completed);
        _ = try w.commit();
    }
}

test "plugin_hooks_called_during_commit" {
    const test_db = "test_plugin_hooks.db";
    const test_wal = "test_plugin_hooks.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create plugin with on_commit hook
    const test_plugin = plugins.Plugin{
        .name = "test_hook_plugin",
        .version = "0.1.0",
        .on_commit = struct {
            fn hook(allocator: std.mem.Allocator, ctx: plugins.CommitContext) anyerror!plugins.PluginResult {
                _ = allocator;
                return plugins.PluginResult{
                    .success = true,
                    .operations_processed = ctx.mutations.len,
                    .cartridges_updated = 0,
                };
            }
        }.hook,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
    };

    // Create plugin manager
    const plugin_config = plugins.PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
        .fallback_on_error = true,
        .performance_isolation = true,
    };

    var plugin_manager = try plugins.PluginManager.init(arena.allocator(), plugin_config);
    defer plugin_manager.deinit();

    try plugin_manager.register_plugin(test_plugin);

    // Open database and attach plugin manager
    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();
    db.attachPluginManager(&plugin_manager);

    // Perform a commit - should not fail
    var w = try db.beginWrite();
    try w.put("key1", "value1");
    try w.put("key2", "value2");
    const lsn = try w.commit();

    // Verify commit succeeded (hook was called without error)
    try testing.expect(lsn > 0);
}

test "plugin_hook_error_does_not_prevent_commit" {
    const test_db = "test_plugin_error.db";
    const test_wal = "test_plugin_error.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create plugin that fails
    const failing_plugin = plugins.Plugin{
        .name = "failing_plugin",
        .version = "0.1.0",
        .on_commit = struct {
            fn hook(allocator: std.mem.Allocator, ctx: plugins.CommitContext) anyerror!plugins.PluginResult {
                _ = allocator;
                _ = ctx;
                return error.PluginFailed;
            }
        }.hook,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
    };

    const plugin_config = plugins.PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
        .fallback_on_error = true,
    };

    var plugin_manager = try plugins.PluginManager.init(arena.allocator(), plugin_config);
    defer plugin_manager.deinit();

    try plugin_manager.register_plugin(failing_plugin);

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();
    db.attachPluginManager(&plugin_manager);

    // Commit should succeed even though plugin fails
    var w = try db.beginWrite();
    try w.put("key1", "value1");
    const lsn = try w.commit();

    // Verify commit succeeded
    try testing.expect(lsn > 0);

    // Verify data was persisted
    var r = try db.beginReadLatest();
    defer r.close();
    const value = r.get("key1");
    try testing.expect(value != null);
    try testing.expectEqualStrings("value1", value.?);
}

test "plugin_hooks_with_no_plugins_registered" {
    const test_db = "test_no_plugins.db";
    const test_wal = "test_no_plugins.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create plugin manager but don't register any plugins
    const plugin_config = plugins.PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var plugin_manager = try plugins.PluginManager.init(arena.allocator(), plugin_config);
    defer plugin_manager.deinit();

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();
    db.attachPluginManager(&plugin_manager);

    // Commit should work normally
    var w = try db.beginWrite();
    try w.put("key1", "value1");
    const lsn = try w.commit();

    try testing.expect(lsn > 0);
}

test "plugin_hooks_with_no_plugin_manager_attached" {
    const test_db = "test_no_manager.db";
    const test_wal = "test_no_manager.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();

    // No plugin manager attached - commit should work normally
    var w = try db.beginWrite();
    try w.put("key1", "value1");
    const lsn = try w.commit();

    try testing.expect(lsn > 0);
}

test "plugin_hooks_multiple_plugins" {
    const test_db = "test_multi_plugins.db";
    const test_wal = "test_multi_plugins.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create a simple no-op plugin
    const createPlugin = struct {
        fn create(name: []const u8) plugins.Plugin {
            return plugins.Plugin{
                .name = name,
                .version = "0.1.0",
                .on_commit = struct {
                    fn hook(allocator: std.mem.Allocator, ctx: plugins.CommitContext) anyerror!plugins.PluginResult {
                        _ = allocator;
                        _ = ctx;
                        return plugins.PluginResult{
                            .success = true,
                            .operations_processed = 1,
                            .cartridges_updated = 0,
                        };
                    }
                }.hook,
                .on_query = null,
                .on_schedule = null,
                .get_functions = null,
                .on_agent_session_start = null,
                .on_agent_operation = null,
                .on_review_request = null,
                .on_perf_sample = null,
            };
        }
    };

    const plugin_config = plugins.PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var plugin_manager = try plugins.PluginManager.init(arena.allocator(), plugin_config);
    defer plugin_manager.deinit();

    // Register multiple plugins
    try plugin_manager.register_plugin(createPlugin.create("plugin1"));
    try plugin_manager.register_plugin(createPlugin.create("plugin2"));
    try plugin_manager.register_plugin(createPlugin.create("plugin3"));

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();
    db.attachPluginManager(&plugin_manager);

    var w = try db.beginWrite();
    try w.put("key1", "value1");
    const lsn = try w.commit();

    // Commit should succeed with all plugins called
    try testing.expect(lsn > 0);
}

test "attachPluginManager_method" {
    var db = try Db.open(std.testing.allocator);
    defer db.close();

    const plugin_config = plugins.PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var plugin_manager = try plugins.PluginManager.init(std.testing.allocator, plugin_config);
    defer plugin_manager.deinit();

    // Initially no plugin manager
    try testing.expect(db.plugin_manager == null);

    // Attach plugin manager
    db.attachPluginManager(&plugin_manager);

    // Should now have plugin manager
    try testing.expect(db.plugin_manager != null);
    try testing.expectEqual(@as(*plugins.PluginManager, @ptrCast(db.plugin_manager.?)), @as(*plugins.PluginManager, @ptrCast(&plugin_manager)));
}

test "delete_operation" {
    const test_db = "test_delete.db";
    const test_wal = "test_delete.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();

    // Write initial data
    var w1 = try db.beginWrite();
    try w1.put("key1", "value1");
    try w1.put("key2", "value2");
    try w1.put("key3", "value3");
    _ = try w1.commit();

    // Verify data exists
    var r1 = try db.beginReadLatest();
    try testing.expectEqualStrings("value1", r1.get("key1").?);
    try testing.expectEqualStrings("value2", r1.get("key2").?);
    try testing.expectEqualStrings("value3", r1.get("key3").?);
    r1.close();

    // Delete key2
    var w2 = try db.beginWrite();
    try w2.delete("key2");
    _ = try w2.commit();

    // Verify key2 is deleted but others remain
    var r2 = try db.beginReadLatest();
    try testing.expectEqualStrings("value1", r2.get("key1").?);
    try testing.expect(r2.get("key2") == null); // Deleted
    try testing.expectEqualStrings("value3", r2.get("key3").?);
    r2.close();

    // Delete non-existent key should not error
    var w3 = try db.beginWrite();
    try w3.delete("nonexistent");
    _ = try w3.commit();

    // Verify state unchanged
    var r3 = try db.beginReadLatest();
    try testing.expectEqualStrings("value1", r3.get("key1").?);
    try testing.expect(r3.get("key2") == null);
    try testing.expectEqualStrings("value3", r3.get("key3").?);
    r3.close();
}

test "delete_then_put" {
    const test_db = "test_delete_put.db";
    const test_wal = "test_delete_put.wal";
    defer {
        std.fs.cwd().deleteFile(test_db) catch {};
        std.fs.cwd().deleteFile(test_wal) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer db.close();

    // Write initial value
    var w1 = try db.beginWrite();
    try w1.put("key1", "old_value");
    _ = try w1.commit();

    // Delete and then put in same transaction
    var w2 = try db.beginWrite();
    try w2.delete("key1");
    try w2.put("key1", "new_value");
    _ = try w2.commit();

    // Should have new value
    var r = try db.beginReadLatest();
    try testing.expectEqualStrings("new_value", r.get("key1").?);
    r.close();
}
