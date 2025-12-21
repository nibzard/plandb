//! MVCC Snapshot Registry
//!
//! Provides mapping from transaction IDs to root page IDs for concurrent readers.
//! This enables true multi-version concurrency control by allowing readers to
//! access historical snapshots of the database while writes continue.

const std = @import("std");
const pager = @import("pager.zig");

/// Snapshot registry maps transaction IDs to their root page IDs
/// This allows concurrent readers to access consistent snapshots
pub const SnapshotRegistry = struct {
    allocator: std.mem.Allocator,
    // Map from txn_id -> root_page_id
    snapshots: std.AutoHashMap(u64, u64),
    // Current committed transaction ID
    current_txn_id: u64,
    // Current root page ID
    current_root_page_id: u64,

    const Self = @This();

    /// Initialize a new snapshot registry
    pub fn init(allocator: std.mem.Allocator, initial_txn_id: u64, initial_root_page_id: u64) !Self {
        var snapshots = std.AutoHashMap(u64, u64).init(allocator);

        // Insert genesis snapshot (txn_id 0 -> root_page_id 0 for empty tree)
        try snapshots.put(0, initial_root_page_id);

        return Self{
            .allocator = allocator,
            .snapshots = snapshots,
            .current_txn_id = initial_txn_id,
            .current_root_page_id = initial_root_page_id,
        };
    }

    /// Clean up snapshot registry
    pub fn deinit(self: *Self) void {
        self.snapshots.deinit();
    }

    /// Register a new committed snapshot
    pub fn registerSnapshot(self: *Self, txn_id: u64, root_page_id: u64) !void {
        // Only register if txn_id is newer than current
        if (txn_id <= self.current_txn_id) return;

        try self.snapshots.put(txn_id, root_page_id);
        self.current_txn_id = txn_id;
        self.current_root_page_id = root_page_id;
    }

    /// Get the root page ID for a specific transaction snapshot
    pub fn getSnapshotRoot(self: *const Self, txn_id: u64) ?u64 {
        // If txn_id is newer than current, return current snapshot
        if (txn_id > self.current_txn_id) {
            return self.current_root_page_id;
        }

        return self.snapshots.get(txn_id);
    }

    /// Get the latest committed snapshot (highest txn_id)
    pub fn getLatestSnapshot(self: *const Self) u64 {
        return self.current_root_page_id;
    }

    /// Get the current committed transaction ID
    pub fn getCurrentTxnId(self: *const Self) u64 {
        return self.current_txn_id;
    }

    /// Get all snapshot entries (useful for debugging/inspection)
    pub fn getAllSnapshots(self: *const Self) []const struct { txn_id: u64, root_page_id: u64 } {
        // Convert to array of structs for easier consumption
        const entries = self.allocator.alloc(struct { txn_id: u64, root_page_id: u64 }, self.snapshots.count()) catch &[_]struct { txn_id: u64, root_page_id: u64 }{};

        var i: usize = 0;
        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            if (i < entries.len) {
                entries[i] = .{ .txn_id = entry.key_ptr.*, .root_page_id = entry.value_ptr.* };
                i += 1;
            }
        }

        return entries;
    }

    /// Clean up old snapshots (garbage collection)
    /// Keeps only snapshots newer than keep_txns or the most recent keep_count snapshots
    pub fn cleanupOldSnapshots(self: *Self, keep_txns: u64, keep_count: usize) !usize {
        if (self.snapshots.count() <= keep_count) return 0;

        const cutoff_txn_id = if (self.current_txn_id > keep_txns)
            self.current_txn_id - keep_txns
        else
            0;

        // Collect snapshots to remove
        var to_remove = std.ArrayList(u64).initCapacity(self.allocator, 16) catch unreachable;
        defer to_remove.deinit(self.allocator);

        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            const txn_id = entry.key_ptr.*;
            // Never remove genesis snapshot (txn_id 0)
            if (txn_id == 0) continue;

            // Don't remove the most recent keep_count snapshots
            const position_from_latest = self.current_txn_id - txn_id;
            if (position_from_latest >= keep_count) {
                // Also respect the txn_age cutoff
                if (keep_txns == 0 or txn_id < cutoff_txn_id) {
                    try to_remove.append(self.allocator, txn_id);
                }
            }
        }

        // Remove old snapshots
        for (to_remove.items) |txn_id| {
            _ = self.snapshots.remove(txn_id);
        }

        return to_remove.items.len;
    }

    /// Check if a snapshot exists for the given transaction ID
    pub fn hasSnapshot(self: *const Self, txn_id: u64) bool {
        if (txn_id > self.current_txn_id) return false;
        return self.snapshots.contains(txn_id);
    }

    /// Get statistics about the snapshot registry
    pub const Stats = struct {
        total_snapshots: usize,
        current_txn_id: u64,
        oldest_txn_id: u64,
        newest_txn_id: u64,
    };

    pub fn getStats(self: *const Self) Stats {
        var oldest_txn_id: u64 = self.current_txn_id;
        var newest_txn_id: u64 = 0;

        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            const txn_id = entry.key_ptr.*;
            if (txn_id < oldest_txn_id) oldest_txn_id = txn_id;
            if (txn_id > newest_txn_id) newest_txn_id = txn_id;
        }

        return Stats{
            .total_snapshots = self.snapshots.count(),
            .current_txn_id = self.current_txn_id,
            .oldest_txn_id = oldest_txn_id,
            .newest_txn_id = newest_txn_id,
        };
    }
};

test "SnapshotRegistry basic functionality" {
    var registry = try SnapshotRegistry.init(std.testing.allocator, 0, 0);
    defer registry.deinit();

    // Initial state
    try std.testing.expectEqual(@as(u64, 0), registry.getCurrentTxnId());
    try std.testing.expectEqual(@as(u64, 0), registry.getLatestSnapshot());
    try std.testing.expectEqual(@as(u64, 0), registry.getSnapshotRoot(0).?);
    try std.testing.expect(registry.hasSnapshot(0));
    try std.testing.expect(!registry.hasSnapshot(1));

    // Register first snapshot
    try registry.registerSnapshot(1, 5);
    try std.testing.expectEqual(@as(u64, 1), registry.getCurrentTxnId());
    try std.testing.expectEqual(@as(u64, 5), registry.getLatestSnapshot());
    try std.testing.expectEqual(@as(u64, 5), registry.getSnapshotRoot(1).?);
    try std.testing.expectEqual(@as(u64, 0), registry.getSnapshotRoot(0).?);

    // Register more snapshots
    try registry.registerSnapshot(3, 8);
    try registry.registerSnapshot(5, 12);

    try std.testing.expectEqual(@as(u64, 5), registry.getCurrentTxnId());
    try std.testing.expectEqual(@as(u64, 12), registry.getLatestSnapshot());
    try std.testing.expectEqual(@as(u64, 8), registry.getSnapshotRoot(3).?);
    try std.testing.expectEqual(@as(u64, 12), registry.getSnapshotRoot(5).?);

    // Test accessing future txn_id returns current snapshot
    try std.testing.expectEqual(@as(u64, 12), registry.getSnapshotRoot(10).?);
}

test "SnapshotRegistry cleanup old snapshots" {
    var registry = try SnapshotRegistry.init(std.testing.allocator, 0, 0);
    defer registry.deinit();

    // Register multiple snapshots
    try registry.registerSnapshot(1, 5);
    try registry.registerSnapshot(2, 6);
    try registry.registerSnapshot(3, 7);
    try registry.registerSnapshot(4, 8);
    try registry.registerSnapshot(5, 9);

    try std.testing.expectEqual(@as(usize, 6), registry.snapshots.count()); // including genesis

    // Simple test: remove nothing (keep all)
    const removed_none = try registry.cleanupOldSnapshots(0, 10);
    try std.testing.expectEqual(@as(usize, 0), removed_none);
    try std.testing.expectEqual(@as(usize, 6), registry.snapshots.count());

    // Now test keeping only last 2 snapshots (4, 5) + genesis (0)
    const removed = try registry.cleanupOldSnapshots(0, 2);
    try std.testing.expectEqual(@as(usize, 3), removed); // Should remove 1, 2, 3
    try std.testing.expectEqual(@as(usize, 3), registry.snapshots.count()); // Keep 0, 4, 5
    try std.testing.expect(!registry.hasSnapshot(1));
    try std.testing.expect(!registry.hasSnapshot(2));
    try std.testing.expect(!registry.hasSnapshot(3));
    try std.testing.expect(registry.hasSnapshot(4));
    try std.testing.expect(registry.hasSnapshot(5));
    try std.testing.expect(registry.hasSnapshot(0)); // Genesis always kept
}

test "SnapshotRegistry stats" {
    var registry = try SnapshotRegistry.init(std.testing.allocator, 0, 0);
    defer registry.deinit();

    try registry.registerSnapshot(2, 6);
    try registry.registerSnapshot(5, 9);

    const stats = registry.getStats();
    try std.testing.expectEqual(@as(usize, 3), stats.total_snapshots); // genesis + 2 snapshots
    try std.testing.expectEqual(@as(u64, 5), stats.current_txn_id);
    try std.testing.expectEqual(@as(u64, 0), stats.oldest_txn_id);
    try std.testing.expectEqual(@as(u64, 5), stats.newest_txn_id);
}