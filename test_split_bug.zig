//! Test to reproduce B+tree key loss bug after leaf splits
//! Bug affects keys like "c10", "c101", "c100" when inserted in sequence

const std = @import("std");
const db = @import("src/db.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open test database
    const db_path = "/tmp/test_split_bug.db";
    const wal_path = "/tmp/test_split_bug.log";

    // Delete old test files if exist
    std.fs.cwd().deleteFile(db_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};

    std.log.info("Opening database at {s}", .{db_path});
    var database = try db.Db.openWithFile(allocator, db_path, wal_path);
    defer database.close();

    // Insert keys that will trigger multiple leaf splits
    // Using format "c{number}" to hit the specific bug pattern
    const num_keys = 100;
    std.log.info("Inserting {} keys (c1 through c{})...", .{ num_keys, num_keys });

    var missing_keys = std.ArrayList([]const u8){};
    defer {
        for (missing_keys.items) |key| {
            allocator.free(key);
        }
        missing_keys.deinit(allocator);
    }

    {
        // Write transaction - insert all keys in one transaction
        var wtxn = try database.beginWrite();

        var i: u32 = 1;
        while (i <= num_keys) : (i += 1) {
            const key = try std.fmt.allocPrint(allocator, "c{d}", .{i});
            defer allocator.free(key);

            const value = try std.fmt.allocPrint(allocator, "value_{d}", .{i});
            defer allocator.free(value);

            std.log.info("Inserting key: {s}", .{key});
            try wtxn.put(key, value);
        }

        std.log.info("Committing transaction...", .{});
        _ = try wtxn.commit();
        std.log.info("Transaction committed", .{});
    }

    std.log.info("Inserted {} keys, now verifying all can be retrieved...", .{num_keys});

    // Verify all keys exist
    {
        var rtxn = try database.beginReadLatest();
        defer rtxn.close();

        var i: u32 = 1;
        while (i <= num_keys) : (i += 1) {
            const key = try std.fmt.allocPrint(allocator, "c{d}", .{i});
            defer allocator.free(key);

            const value = rtxn.get(key);
            if (value == null) {
                const key_copy = try allocator.dupe(u8, key);
                try missing_keys.append(allocator, key_copy);
                std.log.err("MISSING KEY: {s}", .{key});
            } else {
                // Also verify the value is correct
                const expected = try std.fmt.allocPrint(allocator, "value_{d}", .{i});
                defer allocator.free(expected);

                if (!std.mem.eql(u8, value.?, expected)) {
                    std.log.err("KEY {s} has wrong value: expected '{s}', got '{s}'", .{ key, expected, value.? });
                }
            }
        }
    }

    // Report results
    std.log.info("\n=== TEST RESULTS ===", .{});
    std.log.info("Total keys inserted: {d}", .{num_keys});
    std.log.info("Missing keys: {d}", .{missing_keys.items.len});

    if (missing_keys.items.len > 0) {
        std.log.err("\nMISSING KEYS:", .{});
        for (missing_keys.items) |key| {
            std.log.err("  - {s}", .{key});
        }
        std.log.err("\nBUG CONFIRMED: {} keys were lost after splits!", .{missing_keys.items.len});

        // Analyze pattern
        std.log.err("\nAnalyzing missing key patterns...", .{});
        var two_digit: usize = 0;
        var three_digit: usize = 0;
        for (missing_keys.items) |key| {
            if (key.len == 3) two_digit += 1; // "c10" through "c99"
            if (key.len == 4) three_digit += 1; // "c100" through "c200"
        }
        std.log.err("  Two-digit keys (c10-c99) missing: {d}", .{two_digit});
        std.log.err("  Three-digit keys (c100-c200) missing: {d}", .{three_digit});

        return error.TestFailed;
    } else {
        std.log.info("\nSUCCESS: All keys were found!", .{});
    }
}
