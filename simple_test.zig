const std = @import("std");
const db = @import("src/db.zig");

pub fn main() !void {
    const test_db = "simple_test.db";
    const test_wal = "simple_test.wal";

    // Clean up any existing test files
    std.fs.cwd().deleteFile(test_db) catch {};
    std.fs.cwd().deleteFile(test_wal) catch {};

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Creating file-based database...\n", .{});

    // Create file-based database
    var database = try db.Db.openWithFile(allocator, test_db, test_wal);
    defer database.close();

    std.debug.print("Database created successfully!\n", .{});

    // Begin a write transaction
    var w = try database.beginWrite();
    try w.put("test_key", "test_value");
    std.debug.print("Put operation successful!\n", .{});

    // Commit should create a .log file
    const lsn = try w.commit();
    std.debug.print("Commit successful! LSN: {}\n", .{lsn});

    // Check if .log file was created
    const test_log = "simple_test.log";
    const log_file = std.fs.cwd().openFile(test_log, .{ .mode = .read_only }) catch |err| {
        std.debug.print("ERROR: Could not open log file: {}\n", .{err});
        return;
    };
    defer log_file.close();

    const log_size = try log_file.getEndPos();
    std.debug.print("SUCCESS: Phase 4 log file created with {} bytes\n", .{log_size});

    // Clean up test files
    std.fs.cwd().deleteFile(test_db) catch {};
    std.fs.cwd().deleteFile(test_wal) catch {};
    std.fs.cwd().deleteFile(test_log) catch {};
}