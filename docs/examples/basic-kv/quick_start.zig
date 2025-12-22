//! Quick start example for NorthstarDB basic key-value operations
//!
//! This example demonstrates:
//! - Creating and opening a database
//! - Basic put/get operations
//! - Transaction management
//! - Error handling
//!
//! Run with: zig run examples/basic-kv/quick_start.zig

const std = @import("std");
const db = @import("../../src/db.zig");

pub fn main() !void {
    var gpa = std.heap.page_allocator;

    std.debug.print("NorthstarDB Quick Start Example\n");
    std.debug.print("==============================\n\n");

    // Example 1: In-memory database
    try inMemoryExample(gpa);

    std.debug.print("\n");

    // Example 2: File-based database
    try fileBasedExample(gpa);

    std.debug.print("\n");

    // Example 3: Advanced operations
    try advancedOperationsExample(gpa);
}

fn inMemoryExample(allocator: std.mem.Allocator) !void {
    std.debug.print("1. In-Memory Database Example\n");
    std.debug.print("----------------------------\n");

    // Create an in-memory database
    var memory_db = try db.Db.open(allocator);
    defer memory_db.close();

    std.debug.print("Opened in-memory database\n");

    // Start a write transaction
    var wtxn = try memory_db.beginWrite();
    defer wtxn.abort(); // Will be overridden by commit

    // Add some key-value pairs
    const test_data = [_]struct { []const u8, []const u8 }{
        .{ "user:001", "Alice Smith" },
        .{ "user:002", "Bob Johnson" },
        .{ "user:003", "Charlie Brown" },
        .{ "config:theme", "dark" },
        .{ "config:language", "en" },
    };

    for (test_data) |data| {
        try wtxn.put(data[0], data[1]);
        std.debug.print("Stored: {s} = {s}\n", .{ data[0], data[1] });
    }

    // Commit the transaction
    const txn_id = try wtxn.commit();
    std.debug.print("Committed transaction ID: {}\n", .{txn_id});

    // Start a read transaction
    var rtxn = try memory_db.beginReadLatest();
    defer rtxn.close();

    // Read values back
    std.debug.print("\nReading values:\n");
    const alice = rtxn.get("user:001");
    if (alice) |name| {
        std.debug.print("user:001 = {s}\n", .{name});
    }

    const theme = rtxn.get("config:theme");
    if (theme) |theme_value| {
        std.debug.print("config:theme = {s}\n", .{theme_value});
    }

    // Try to read non-existent key
    const missing = rtxn.get("nonexistent:key");
    if (missing == null) {
        std.debug.print("nonexistent:key = (not found)\n");
    }
}

fn fileBasedExample(allocator: std.mem.Allocator) !void {
    std.debug.print("2. File-Based Database Example\n");
    std.debug.print("----------------------------\n");

    const db_path = "example.db";
    const wal_path = "example.wal";

    // Clean up any existing files
    cleanupFiles(db_path, wal_path) catch {};

    // Open file-based database
    var file_db = try db.Db.openWithFile(allocator, db_path, wal_path);
    defer file_db.close();

    std.debug.print("Opened file-based database: {s}\n", .{db_path});

    // Use the database
    var wtxn = try file_db.beginWrite();
    defer wtxn.abort();

    // Store some persistent data
    const persistent_data = [_]struct { []const u8, []const u8 }{
        .{ "app:version", "1.0.0" },
        .{ "app:name", "MyApplication" },
        .{ "settings:max_connections", "100" },
        .{ "settings:timeout", "30" },
    };

    for (persistent_data) |data| {
        try wtxn.put(data[0], data[1]);
        std.debug.print("Persisted: {s} = {s}\n", .{ data[0], data[1] });
    }

    const txn_id = try wtxn.commit();
    std.debug.print("Committed persistent transaction ID: {}\n", .{txn_id});

    // Reopen the database to verify persistence
    std.debug.print("\nReopening database to verify persistence...\n");
    var reopened_db = try db.Db.openWithFile(allocator, db_path, wal_path);
    defer reopened_db.close();

    var rtxn = try reopened_db.beginReadLatest();
    defer rtxn.close();

    const version = rtxn.get("app:version");
    if (version) |version_value| {
        std.debug.print("Persistent version: {s}\n", .{version_value});
    }
}

fn advancedOperationsExample(allocator: std.mem.Allocator) !void {
    std.debug.print("3. Advanced Operations Example\n");
    std.debug.print("----------------------------\n");

    var db = try db.Db.open(allocator);
    defer db.close();

    // Prepare test data
    const test_data = [_]struct { []const u8, []const u8 }{
        .{ "task:001", "Implement user authentication" },
        .{ "task:002", "Design database schema" },
        .{ "task:003", "Write API documentation" },
        .{ "task:004", "Add unit tests" },
        .{ "task:005", "Performance optimization" },
    };

    // Insert data
    var wtxn = try db.beginWrite();
    defer wtxn.abort();

    for (test_data) |data| {
        try wtxn.put(data[0], data[1]);
    }
    _ = try wtxn.commit();

    // Advanced read operations
    var rtxn = try db.beginReadLatest();
    defer rtxn.close();

    // Prefix scan - get all tasks
    std.debug.print("All tasks:\n");
    const tasks = try rtxn.scan("task:");
    defer allocator.free(tasks);

    for (tasks) |task| {
        std.debug.print("  {s}: {s}\n", .{ task.key, task.value });
    }

    // Demonstrate read-your-writes in a single transaction
    std.debug.print("\nRead-your-writes example:\n");
    var wtxn2 = try db.beginWrite();
    defer wtxn2.abort();

    // Initially doesn't exist
    const initial = wtxn2.get("temp:counter");
    std.debug.print("Initial counter value: {s}\n", .{initial orelse "null"});

    // Put and immediately read
    try wtxn2.put("temp:counter", "1");
    const after_put = wtxn2.get("temp:counter");
    std.debug.print("After put: {s}\n", .{after_put orelse "null"});

    // Update and read again
    try wtxn2.put("temp:counter", "2");
    const after_update = wtxn2.get("temp:counter");
    std.debug.print("After update: {s}\n", .{after_update orelse "null"});

    // Delete and read
    try wtxn2.del("temp:counter");
    const after_delete = wtxn2.get("temp:counter");
    std.debug.print("After delete: {s}\n", .{after_delete orelse "null"});

    _ = try wtxn2.commit();

    // Range operations example
    std.debug.print("\nRange operations example:\n");
    var range_wtxn = try db.beginWrite();
    defer range_wtxn.abort();

    const range_data = [_]struct { []const u8, []const u8 }{
        .{ "a", "value_a" },
        .{ "b", "value_b" },
        .{ "c", "value_c" },
        .{ "d", "value_d" },
        .{ "e", "value_e" },
    };

    for (range_data) |data| {
        try range_wtxn.put(data[0], data[1]);
    }
    _ = try range_wtxn.commit();

    var range_rtxn = try db.beginReadLatest();
    defer range_rtxn.close();

    std.debug.print("Keys in range [b, d):\n");
    var range_iter = try range_rtxn.iteratorRange("b", "e");
    defer {}

    while (try range_iter.next()) |kv| {
        std.debug.print("  {s}: {s}\n", .{ kv.key, kv.value });
    }
}

fn cleanupFiles(db_path: []const u8, wal_path: []const u8) !void {
    std.fs.cwd().deleteFile(db_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};
}

test "quick_start_example" {
    var gpa = std.testing.allocator;

    // Test that we can create and use a database
    var test_db = try db.Db.open(gpa);
    defer test_db.close();

    var wtxn = try test_db.beginWrite();
    defer wtxn.abort();

    try wtxn.put("test:key", "test:value");
    const txn_id = try wtxn.commit();

    var rtxn = try test_db.beginReadLatest();
    defer rtxn.close();

    const value = rtxn.get("test:key");
    try std.testing.expect(value != null);
    try std.testing.expect(std.mem.eql(u8, "test:value", value.?));
}