//! Basic Key-Value Store Example
//!
//! Demonstrates core NorthstarDB operations:
//! - Creating and opening a database
//! - Write transactions for storing data
//! - Read transactions for retrieving data
//! - Updating and deleting values

const std = @import("std");
const db = @import("northstar");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open database (creates if doesn't exist)
    std.debug.print("Opening database...\n", .{});
    var database = try db.Db.open(allocator, "kv_store.db");
    defer database.close();

    // === CREATE: Store initial data ===
    std.debug.print("\n--- Creating Records ---\n", .{});
    {
        var wtxn = try database.beginWriteTxn();
        errdefer wtxn.rollback();

        try wtxn.put("user:1001:name", "Alice Johnson");
        try wtxn.put("user:1001:email", "alice@example.com");
        try wtxn.put("user:1001:role", "admin");
        try wtxn.put("user:1002:name", "Bob Smith");
        try wtxn.put("user:1002:email", "bob@example.com");
        try wtxn.put("user:1002:role", "user");

        try wtxn.commit();
        std.debug.print("Created 2 users with 3 fields each\n", .{});
    }

    // === READ: Retrieve stored data ===
    std.debug.print("\n--- Reading Records ---\n", .{});
    {
        var rtxn = try database.beginReadTxn();
        defer rtxn.commit();

        if (rtxn.get("user:1001:name")) |name| {
            std.debug.print("User 1001 name: {s}\n", .{name});
        } else |err| {
            std.debug.print("Error reading name: {}\n", .{err});
        }

        if (rtxn.get("user:1001:email")) |email| {
            std.debug.print("User 1001 email: {s}\n", .{email});
        } else |err| {
            std.debug.print("Error reading email: {}\n", .{err});
        }
    }

    // === UPDATE: Modify existing values ===
    std.debug.print("\n--- Updating Records ---\n", .{});
    {
        var wtxn = try database.beginWriteTxn();
        errdefer wtxn.rollback();

        try wtxn.put("user:1001:role", "superadmin");
        try wtxn.put("user:1002:role", "moderator");

        try wtxn.commit();
        std.debug.print("Updated user roles\n", .{});
    }

    // Verify updates
    {
        var rtxn = try database.beginReadTxn();
        defer rtxn.commit();

        if (rtxn.get("user:1001:role")) |role| {
            std.debug.print("User 1001 new role: {s}\n", .{role});
        }
    }

    // === DELETE: Remove data ===
    std.debug.print("\n--- Deleting Records ---\n", .{});
    {
        var wtxn = try database.beginWriteTxn();
        errdefer wtxn.rollback();

        try wtxn.delete("user:1002:email");

        try wtxn.commit();
        std.debug.print("Deleted user 1002 email\n", .{});
    }

    // Verify deletion
    {
        var rtxn = try database.beginReadTxn();
        defer rtxn.commit();

        if (rtxn.get("user:1002:email")) |email| {
            std.debug.print("User 1002 email (should not exist): {s}\n", .{email});
        } else |err| {
            std.debug.print("User 1002 email not found (expected): {}\n", .{err});
        }
    }

    // === RANGE SCAN: Query by prefix ===
    std.debug.print("\n--- Range Scan (user:1001:*) ---\n", .{});
    {
        var rtxn = try database.beginReadTxn();
        defer rtxn.commit();

        var iter = try rtxn.scan("user:1001:");
        defer iter.deinit();

        var count: usize = 0;
        while (try iter.next()) |entry| {
            std.debug.print("  {s} = {s}\n", .{ entry.key, entry.value });
            count += 1;
        }
        std.debug.print("Found {d} fields for user 1001\n", .{count});
    }

    std.debug.print("\n--- Example Complete ---\n", .{});
}
