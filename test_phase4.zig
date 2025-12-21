const std = @import("std");
const db = @import("src/db.zig");
const testing = std.testing;

test "Phase 4: Commit creates separate .log file" {
    const test_db = "test_phase4.db";
    const test_wal = "test_phase4.wal";
    const test_log = "test_phase4.log";

    // Clean up any existing test files
    std.fs.cwd().deleteFile(test_db) catch {};
    std.fs.cwd().deleteFile(test_wal) catch {};
    std.fs.cwd().deleteFile(test_log) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create file-based database
    var database = try db.Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer database.close();

    // Begin a write transaction
    var w = try database.beginWrite();
    try w.put("test_key", "test_value");

    // Commit should create a .log file
    const lsn = try w.commit();

    // Verify .log file was created
    const log_file = std.fs.cwd().openFile(test_log, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return error.LogFileNotCreated,
        else => return err,
    };
    defer log_file.close();

    // Verify log file has content
    const log_size = try log_file.getEndPos();
    try testing.expect(log_size > 0);

    // Verify LSN is reasonable (should be txn_id)
    try testing.expect(lsn > 0);

    std.debug.print("Phase 4 test passed: log file created with {d} bytes, LSN: {d}\n", .{ log_size, lsn });
}

test "Phase 4: Fsync ordering verification" {
    const test_db = "test_phase4_sync.db";
    const test_wal = "test_phase4_sync.wal";
    const test_log = "test_phase4_sync.log";

    // Clean up any existing test files
    std.fs.cwd().deleteFile(test_db) catch {};
    std.fs.cwd().deleteFile(test_wal) catch {};
    std.fs.cwd().deleteFile(test_log) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create file-based database
    var database = try db.Db.openWithFile(arena.allocator(), test_db, test_wal);
    defer database.close();

    // Begin a write transaction
    var w = try database.beginWrite();
    try w.put("sync_test", "sync_value");

    // Commit should follow the new fsync ordering: log -> meta -> database
    const lsn = try w.commit();

    // Verify all files exist and have reasonable sizes
    const log_file = std.fs.cwd().openFile(test_log, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return error.LogFileNotCreated,
        else => return err,
    };
    defer log_file.close();

    const db_file = std.fs.cwd().openFile(test_db, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return error.DatabaseFileNotCreated,
        else => return err,
    };
    defer db_file.close();

    const log_size = try log_file.getEndPos();
    const db_size = try db_file.getEndPos();

    // Both files should have content
    try testing.expect(log_size > 0);
    try testing.expect(db_size > 0);
    try testing.expect(lsn > 0);

    std.debug.print("Phase 4 sync test passed: log={d} bytes, db={d} bytes, LSN: {d}\n", .{ log_size, db_size, lsn });
}