//! Transaction scaffolding and basic two-phase commit plumbing.
//!
//! Tracks mutations and commit context for experimentation; full ACID semantics
//! (durable logging, recovery, and isolation guarantees) are not implemented yet.

const std = @import("std");
const pager = @import("pager.zig");

/// Transaction state for two-phase commit protocol
pub const TransactionState = enum {
    active,     // Transaction is actively making changes
    preparing,  // Changes written, preparing to commit
    committed,  // Transaction committed successfully
    aborted,    // Transaction was aborted/rolled back
};

/// Mutation represents a single operation within a transaction
pub const Mutation = union(enum) {
    put: struct {
        key: []const u8,
        value: []const u8,
    },
    delete: struct {
        key: []const u8,
    },

    pub fn getKey(self: @This()) []const u8 {
        return switch (self) {
            .put => |p| p.key,
            .delete => |d| d.key,
        };
    }
};

/// Commit record written to WAL for durability
pub const CommitRecord = struct {
    txn_id: u64,
    parent_txn_id: u64,
    timestamp_ns: u64,
    mutations: []const Mutation,
    checksum: u32,

    pub const SIZE: usize = @sizeOf(u64) * 3 + @sizeOf(u32) + @sizeOf(u32); // txn_id, parent, timestamp, mutation_count, checksum

    pub fn calculateChecksum(self: @This()) u32 {
        // Create temporary record with checksum zeroed for calculation
        const temp = CommitRecord{
            .txn_id = self.txn_id,
            .parent_txn_id = self.parent_txn_id,
            .timestamp_ns = self.timestamp_ns,
            .mutations = self.mutations,
            .checksum = 0,
        };

        // Calculate checksum of all mutations
        var hasher = std.hash.Crc32.init();
        hasher.update(std.mem.asBytes(&temp.txn_id));
        hasher.update(std.mem.asBytes(&temp.parent_txn_id));
        hasher.update(std.mem.asBytes(&temp.timestamp_ns));

        const mutation_count: u32 = @intCast(self.mutations.len);
        hasher.update(std.mem.asBytes(&mutation_count));

        for (self.mutations) |mutation| {
            switch (mutation) {
                .put => |p| {
                    const key_len: u32 = @intCast(p.key.len);
                    const val_len: u32 = @intCast(p.value.len);
                    hasher.update(std.mem.asBytes(&key_len));
                    hasher.update(p.key);
                    hasher.update(std.mem.asBytes(&val_len));
                    hasher.update(p.value);
                },
                .delete => |d| {
                    const key_len: u32 = @intCast(d.key.len);
                    hasher.update(std.mem.asBytes(&key_len));
                    hasher.update(d.key);
                },
            }
        }

        return hasher.final();
    }

    pub fn validateChecksum(self: @This()) bool {
        return self.checksum == self.calculateChecksum();
    }
};

/// Transaction context tracks state during two-phase commit
pub const TransactionContext = struct {
    txn_id: u64,
    parent_txn_id: u64,
    state: TransactionState,
    mutations: std.ArrayList(Mutation),
    allocated_pages: std.ArrayList(u64),
    modified_pages: std.HashMap(u64, []const u8, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage), // page_id -> before_image
    timestamp_ns: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, txn_id: u64, parent_txn_id: u64) !Self {
        const timestamp = std.time.nanoTimestamp();
        return Self{
            .txn_id = txn_id,
            .parent_txn_id = parent_txn_id,
            .state = .active,
            .mutations = std.ArrayList(Mutation).initCapacity(allocator, 0) catch unreachable,
            .allocated_pages = std.ArrayList(u64).initCapacity(allocator, 0) catch unreachable,
            .modified_pages = std.HashMap(u64, []const u8, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .timestamp_ns = @intCast(timestamp),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutations.deinit(self.allocator);
        self.allocated_pages.deinit(self.allocator);

        // Free all before images
        var it = self.modified_pages.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.modified_pages.deinit();
    }

    /// Record a PUT mutation in the transaction
    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        if (self.state != .active) return error.TransactionNotActive;

        // Copy key and value since they may not persist
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try self.mutations.append(self.allocator, Mutation{ .put = .{ .key = key_copy, .value = value_copy } });
    }

    /// Record a DELETE mutation in the transaction
    pub fn delete(self: *Self, key: []const u8) !void {
        if (self.state != .active) return error.TransactionNotActive;

        // Copy key since it may not persist
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        try self.mutations.append(self.allocator, Mutation{ .delete = .{ .key = key_copy } });
    }

    /// Track a page that was allocated during this transaction
    pub fn trackAllocatedPage(self: *Self, page_id: u64) !void {
        if (self.state != .active) return error.TransactionNotActive;
        try self.allocated_pages.append(self.allocator, page_id);
    }

    /// Capture before image of a page for rollback capability
    pub fn captureBeforeImage(self: *Self, page_id: u64, before_image: []const u8) !void {
        if (self.state != .active) return error.TransactionNotActive;

        // If we already have a before image for this page, free it first
        if (self.modified_pages.get(page_id)) |existing| {
            self.allocator.free(existing);
        }

        const image_copy = try self.allocator.dupe(u8, before_image);
        try self.modified_pages.put(page_id, image_copy);
    }

    /// Transition to preparing state - no more mutations allowed
    pub fn prepare(self: *Self) !void {
        if (self.state != .active) return error.TransactionNotActive;
        self.state = .preparing;
    }

    /// Transition to committed state
    pub fn commit(self: *Self) !void {
        if (self.state != .preparing) return error.TransactionNotPreparing;
        self.state = .committed;
    }

    /// Transition to aborted state
    pub fn abort(self: *Self) void {
        self.state = .aborted;
    }

    /// Generate commit record for WAL
    pub fn createCommitRecord(self: *Self) !CommitRecord {
        const mutations_slice = try self.allocator.dupe(Mutation, self.mutations.items);
        const record = CommitRecord{
            .txn_id = self.txn_id,
            .parent_txn_id = self.parent_txn_id,
            .timestamp_ns = self.timestamp_ns,
            .mutations = mutations_slice,
            .checksum = 0, // Will be calculated
        };

        return CommitRecord{
            .txn_id = record.txn_id,
            .parent_txn_id = record.parent_txn_id,
            .timestamp_ns = record.timestamp_ns,
            .mutations = record.mutations,
            .checksum = record.calculateChecksum(),
        };
    }

    /// Get pages that need to be written during commit
    pub fn getModifiedPages(self: *const Self) []const u64 {
        return self.modified_pages.keys();
    }

    /// Get pages allocated during this transaction
    pub fn getAllocatedPages(self: *const Self) []const u64 {
        return self.allocated_pages.items;
    }

    /// Check if transaction has any mutations
    pub fn hasMutations(self: *const Self) bool {
        return self.mutations.items.len > 0;
    }

    /// Get the value for a key from pending mutations, if any
    /// Returns: null if key not found in mutations, value if found, deleted_flag for delete operations
    pub fn getPendingMutation(self: *const Self, key: []const u8) ?struct { value: ?[]const u8, is_deleted: bool } {
        // Search mutations in reverse order to get the latest operation for this key
        var i = self.mutations.items.len;
        while (i > 0) {
            i -= 1;
            const mutation = self.mutations.items[i];

            if (std.mem.eql(u8, mutation.getKey(), key)) {
                return switch (mutation) {
                    .put => |p| .{ .value = p.value, .is_deleted = false },
                    .delete => .{ .value = null, .is_deleted = true },
                };
            }
        }

        return null;
    }
};

test "TransactionContext tracks_mutations_correctly" {
    var ctx = try TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    try testing.expectEqual(TransactionState.active, ctx.state);
    try testing.expect(!ctx.hasMutations());

    // Add mutations
    try ctx.put("key1", "value1");
    try ctx.delete("key2");
    try ctx.put("key3", "value3");

    try testing.expect(ctx.hasMutations());
    try testing.expectEqual(@as(usize, 3), ctx.mutations.items.len);

    // Verify mutations
    try testing.expectEqualStrings("key1", ctx.mutations.items[0].put.key);
    try testing.expectEqualStrings("value1", ctx.mutations.items[0].put.value);
    try testing.expectEqualStrings("key2", ctx.mutations.items[1].delete.key);
    try testing.expectEqualStrings("key3", ctx.mutations.items[2].put.key);
    try testing.expectEqualStrings("value3", ctx.mutations.items[2].put.value);
}

test "TransactionContext tracks_allocated_pages" {
    var ctx = try TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    try ctx.trackAllocatedPage(5);
    try ctx.trackAllocatedPage(10);
    try ctx.trackAllocatedPage(3);

    try testing.expectEqual(@as(usize, 3), ctx.allocated_pages.items.len);
    try testing.expectEqual(@as(u64, 5), ctx.allocated_pages.items[0]);
    try testing.expectEqual(@as(u64, 10), ctx.allocated_pages.items[1]);
    try testing.expectEqual(@as(u64, 3), ctx.allocated_pages.items[2]);
}

test "TransactionContext captures_before_images" {
    var ctx = try TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    const before_image = "original page data";
    try ctx.captureBeforeImage(7, before_image);

    const retrieved = ctx.modified_pages.get(7).?;
    try testing.expectEqualStrings(before_image, retrieved);
}

test "TransactionContext_state_transitions" {
    var ctx = try TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    // Initial state is active
    try testing.expectEqual(TransactionState.active, ctx.state);

    // Can prepare from active
    try ctx.prepare();
    try testing.expectEqual(TransactionState.preparing, ctx.state);

    // Cannot prepare again
    try testing.expectError(error.TransactionNotActive, ctx.prepare());

    // Can commit from preparing
    try ctx.commit();
    try testing.expectEqual(TransactionState.committed, ctx.state);

    // Cannot commit again
    try testing.expectError(error.TransactionNotPreparing, ctx.commit());
}

test "TransactionContext_abort" {
    var ctx = try TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    // Can abort from active
    ctx.abort();
    try testing.expectEqual(TransactionState.aborted, ctx.state);
}

test "TransactionContext_rejects_mutations_when_not_active" {
    var ctx = try TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    try ctx.prepare();

    try testing.expectError(error.TransactionNotActive, ctx.put("key", "value"));
    try testing.expectError(error.TransactionNotActive, ctx.delete("key"));
    try testing.expectError(error.TransactionNotActive, ctx.trackAllocatedPage(1));
    try testing.expectError(error.TransactionNotActive, ctx.captureBeforeImage(1, "data"));
}

test "CommitRecord_checksum_validation" {
    const mutations = [_]Mutation{
        Mutation{ .put = .{ .key = "key1", .value = "value1" } },
        Mutation{ .delete = .{ .key = "key2" } },
    };

    var record = CommitRecord{
        .txn_id = 42,
        .parent_txn_id = 1,
        .timestamp_ns = 1234567890,
        .mutations = &mutations,
        .checksum = 0,
    };

    record.checksum = record.calculateChecksum();
    try testing.expect(record.validateChecksum());

    // Corrupt checksum
    record.checksum += 1;
    try testing.expect(!record.validateChecksum());
}

test "TransactionContext_getPendingMutation" {
    var ctx = try TransactionContext.init(std.testing.allocator, 1, 0);
    defer ctx.deinit();

    // Initially no mutations
    const result1 = ctx.getPendingMutation("key1");
    try testing.expect(result1 == null);

    // Add a put mutation
    try ctx.put("key1", "value1");

    // Should find the put mutation
    const result2 = ctx.getPendingMutation("key1");
    try testing.expect(result2 != null);
    try testing.expect(!result2.?.is_deleted);
    try testing.expectEqualStrings("value1", result2.?.value.?);

    // Add another put mutation for same key (should override)
    try ctx.put("key1", "value1_updated");

    // Should find the latest put mutation
    const result3 = ctx.getPendingMutation("key1");
    try testing.expect(result3 != null);
    try testing.expect(!result3.?.is_deleted);
    try testing.expectEqualStrings("value1_updated", result3.?.value.?);

    // Delete the key
    try ctx.delete("key1");

    // Should find the delete mutation
    const result4 = ctx.getPendingMutation("key1");
    try testing.expect(result4 != null);
    try testing.expect(result4.?.is_deleted);
    try testing.expect(result4.?.value == null);

    // Add another key
    try ctx.put("key2", "value2");

    // key1 should still be deleted, key2 should have value
    const result5 = ctx.getPendingMutation("key1");
    try testing.expect(result5 != null);
    try testing.expect(result5.?.is_deleted);

    const result6 = ctx.getPendingMutation("key2");
    try testing.expect(result6 != null);
    try testing.expect(!result6.?.is_deleted);
    try testing.expectEqualStrings("value2", result6.?.value.?);
}

const testing = std.testing;
