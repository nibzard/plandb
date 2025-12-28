---
title: CRUD Operations Guide
description: Learn how to create, read, update, and delete data in NorthstarDB with practical examples.
---

import { Card, Cards } from '@astrojs/starlight/components';

This guide covers the fundamental CRUD (Create, Read, Update, Delete) operations in NorthstarDB. You'll learn how to work with data using the transaction API effectively.

<Cards>
  <Card title="Create" icon="plus">
    Insert new key-value pairs using write transactions.
  </Card>
  <Card title="Read" icon="search">
    Query data with point lookups, prefix scans, and range queries.
  </Card>
  <Card title="Update" icon="refresh">
    Modify existing values by overwriting keys.
  </Card>
  <Card title="Delete" icon="trash">
    Remove keys from the database.
  </Card>
</Cards>

## Prerequisites

Before working with CRUD operations, you should understand:

- Basic Zig programming
- How to open a database (in-memory or file-backed)
- Transaction basics (read vs write transactions)

If you're new to NorthstarDB, start with the [Db API](../reference/db.md) documentation.

## Creating Data

### Insert a Single Key-Value Pair

Use a write transaction to insert data:

```zig
const std = @import("std");
const db = @import("northstar");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var my_db = try db.Db.open(allocator);
    defer my_db.close();

    // Begin write transaction
    var w = try my_db.beginWrite();
    defer w.abort();

    // Insert a key-value pair
    try w.put("user:123", "Alice");

    // Commit the transaction
    _ = try w.commit();
}
```

**Key points:**
- Always use `defer w.abort()` to ensure cleanup on error
- Call `commit()` to persist changes
- Use `defer` pattern for automatic resource management

### Insert Multiple Key-Value Pairs

```zig
fn insertMultipleUsers(db: *db.Db) !void {
    var w = try db.beginWrite();
    defer w.abort();

    // Insert multiple users
    try w.put("user:001", "Alice");
    try w.put("user:002", "Bob");
    try w.put("user:003", "Charlie");

    // All changes commit atomically
    _ = try w.commit();
}
```

### Insert Structured Data

For structured data, serialize to strings (JSON is common):

```zig
fn insertUserRecord(
    db: *db.Db,
    user_id: u64,
    name: []const u8,
    email: []const u8
) !void {
    // Create JSON string
    var json_buffer: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &json_buffer,
        {{\"name\":\"{s}\",\"email\":\"{s}\"}}",
        .{name, email}
    );

    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var w = try db.beginWrite();
    defer w.abort();

    try w.put(key, json);
    _ = try w.commit();
}
```

## Reading Data

### Point Lookup

Read a single key by its exact value:

```zig
fn getUser(db: *db.Db, user_id: u64) !?[]const u8 {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var r = try db.beginReadLatest();
    defer r.close();

    return r.get(key);  // Caller owns the memory
}
```

**Memory management:**
- Caller owns returned value memory
- Use `allocator.free()` to clean up

```zig
const value = try getUser(my_db, 123);
if (value) |v| {
    defer allocator.free(v);  // Important: free the memory
    std.debug.print("User: {s}\n", .{v});
}
```

### Handle Missing Keys

```zig
fn getUserSafe(db: *db.Db, user_id: u64) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var r = try db.beginReadLatest();
    defer r.close();

    const value = r.get(key);
    if (value) |v| {
        defer allocator.free(v);
        std.debug.print("Found: {s}\n", .{v});
    } else {
        std.debug.print("User not found\n", .{});
    }
}
```

### Prefix Scan

Find all keys with a common prefix:

```zig
fn listAllUsers(db: *db.Db, allocator: std.mem.Allocator) !void {
    var r = try db.beginReadLatest();
    defer r.close();

    // Get all keys starting with "user:"
    const users = try r.scan("user:");
    defer {
        for (users) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(users);
    }

    std.debug.print("Found {} users:\n", .{users.len});
    for (users) |kv| {
        std.debug.print("  {s}: {s}\n", .{kv.key, kv.value});
    }
}
```

### Range Query

Iterate over a range of keys:

```zig
fn rangeQueryExample(db: *db.Db) !void {
    var r = try db.beginReadLatest();
    defer r.close();

    // Get all keys from "user:100" to "user:200"
    var iter = try r.iteratorRange("user:100", "user:200");

    while (try iter.next()) |kv| {
        std.debug.print("{s} = {s}\n", .{kv.key, kv.value});
    }
}
```

## Updating Data

NorthstarDB doesn't have a separate "update" operation. To update data, simply `put()` a new value for an existing key:

```zig
fn updateUser(db: *db.Db, user_id: u64, new_name: []const u8) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var w = try db.beginWrite();
    defer w.abort();

    // Overwrite existing value
    try w.put(key, new_name);

    // Verify with read-your-writes
    const updated = w.get(key);
    try std.testing.expectEqualStrings(new_name, updated.?);

    _ = try w.commit();
}
```

### Conditional Update

Read current value, modify it, then write back:

```zig
fn incrementCounter(db: *db.Db, key: []const u8) !u64 {
    var w = try db.beginWrite();
    defer w.abort();

    // Read current value (read-your-writes)
    const current_str = w.get(key) orelse "0";
    const current = try std.fmt.parseInt(u64, current_str, 10);

    // Increment
    const new_value = current + 1;

    // Write back
    var value_buf: [32]u8 = undefined;
    const new_str = try std.fmt.bufPrint(&value_buf, "{}", .{new_value});
    try w.put(key, new_str);

    _ = try w.commit();
    return new_value;
}
```

### Complex Update

```zig
fn appendToList(db: *db.Db, key: []const u8, item: []const u8) !void {
    var w = try db.beginWrite();
    defer w.abort();

    // Get current list or initialize
    const current = w.get(key) orelse "[]";

    // Parse, modify, serialize
    var parsed = try std.json.parseFromSlice(
        std.json.Array,
        allocator,
        current,
        .{}
    );
    defer parsed.deinit();

    try parsed.value.append(.{ .string = item });

    const updated = try std.json.stringifyAlloc(allocator, parsed.value, .{});

    // Write back
    try w.put(key, updated);

    _ = try w.commit();
}
```

## Deleting Data

### Delete a Single Key

```zig
fn deleteUser(db: *db.Db, user_id: u64) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var w = try db.beginWrite();
    defer w.abort();

    // Delete the key
    try w.del(key);

    // Verify with read-your-writes
    const value = w.get(key);
    try std.testing.expect(value == null);

    _ = try w.commit();
}
```

### Delete Multiple Keys

```zig
fn deleteUsersByPrefix(db: *db.Db, prefix: []const u8) !void {
    var w = try db.beginWrite();
    defer w.abort();

    // Scan for matching keys
    var r = try db.beginReadLatest();
    defer r.close();

    const items = try r.scan(prefix);
    defer {
        for (items) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(items);
    }

    // Delete each key
    for (items) |kv| {
        try w.del(kv.key);
    }

    _ = try w.commit();
}
```

### Conditional Delete

```zig
fn deleteIfMatches(db: *db.Db, key: []const u8, expected_value: []const u8) !bool {
    var w = try db.beginWrite();
    defer w.abort();

    const current = w.get(key);

    // Only delete if value matches
    if (current) |v| {
        if (std.mem.eql(u8, v, expected_value)) {
            try w.del(key);
            _ = try w.commit();
            return true;
        }
    }

    w.abort();
    return false;
}
```

## Error Handling

### Write Transaction Errors

```zig
fn safeInsert(db: *db.Db, key: []const u8, value: []const u8) !void {
    var w = db.beginWrite() catch |err| {
        std.log.err("Failed to begin write: {}", .{err});
        return err;
    };
    defer w.abort();

    try w.put(key, value);

    _ = w.commit() catch |err| {
        std.log.err("Commit failed: {}", .{err});
        return err;
    };
}
```

### Handle Write Busy

```zig
fn insertWithRetry(db: *db.Db, key: []const u8, value: []const u8, max_retries: u32) !void {
    var retry: u32 = 0;
    while (retry < max_retries) : (retry += 1) {
        var w = db.beginWrite() catch |err| {
            if (err == db.WriteBusy.WriteBusy) {
                std.log.warn("Write busy, retrying ({}/{})", .{retry, max_retries});
                std.time.sleep(100_000_000); // 100ms
                continue;
            }
            return err;
        };
        defer w.abort();

        try w.put(key, value);
        _ = try w.commit();
        return;
    }

    return error.MaxRetriesExceeded;
}
```

## Best Practices

### 1. Always Use Defer for Cleanup

```zig
var w = try db.beginWrite();
defer w.abort();  // Guaranteed cleanup

try w.put("key", "value");
_ = try w.commit();
```

### 2. Batch Operations in Single Transaction

```zig
// Good: Single transaction
var w = try db.beginWrite();
defer w.abort();

try w.put("key1", "value1");
try w.put("key2", "value2");
try w.put("key3", "value3");

_ = try w.commit();
```

```zig
// Bad: Multiple transactions
{
    var w = try db.beginWrite();
    try w.put("key1", "value1");
    _ = try w.commit();
}
{
    var w = try db.beginWrite();
    try w.put("key2", "value2");
    _ = try w.commit();
}
// Less efficient, more overhead
```

### 3. Validate Before Commit

```zig
fn createUser(db: *db.Db, user_id: u64, name: []const u8) !void {
    var w = try db.beginWrite();
    defer w.abort();

    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    // Check if user already exists
    if (w.get(key) != null) {
        return error.UserAlreadyExists;
    }

    // Validate name not empty
    if (name.len == 0) {
        return error.InvalidName;
    }

    try w.put(key, name);
    _ = try w.commit();
}
```

### 4. Free Memory Properly

```zig
var r = try db.beginReadLatest();
defer r.close();

const value = r.get("key");
if (value) |v| {
    defer allocator.free(v);  // Don't forget this!
    // Use v...
}
```

## Complete Example: User Management

Here's a complete example demonstrating CRUD operations:

```zig
const std = @import("std");
const db = @import("northstar");

pub const User = struct {
    id: u64,
    name: []const u8,
    email: []const u8,
};

pub fn createUser(
    database: *db.Db,
    user: User,
    allocator: std.mem.Allocator
) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user.id});

    // Serialize user data
    var json_buffer: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &json_buffer,
        {{\"id\":{},\"name\":\"{s}\",\"email\":\"{s}\"}}",
        .{user.id, user.name, user.email}
    );

    var w = try database.beginWrite();
    defer w.abort();

    // Check for duplicate
    if (w.get(key) != null) {
        return error.UserAlreadyExists;
    }

    try w.put(key, json);
    _ = try w.commit();
}

pub fn getUser(
    database: *db.Db,
    user_id: u64,
    allocator: std.mem.Allocator
) !?User {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var r = try database.beginReadLatest();
    defer r.close();

    const json = r.get(key) orelse return null;
    defer allocator.free(json);

    // Parse JSON (simplified - use proper JSON parser in production)
    // In production, use std.json.parse
    std.log.info("User data: {s}", .{json});

    return null;  // Return parsed user
}

pub fn updateUser(
    database: *db.Db,
    user_id: u64,
    new_name: []const u8
) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var w = try database.beginWrite();
    defer w.abort();

    if (w.get(key) == null) {
        return error.UserNotFound;
    }

    try w.put(key, new_name);
    _ = try w.commit();
}

pub fn deleteUser(database: *db.Db, user_id: u64) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var w = try database.beginWrite();
    defer w.abort();

    try w.del(key);
    _ = try w.commit();
}

pub fn listAllUsers(
    database: *db.Db,
    allocator: std.mem.Allocator
) !void {
    var r = try database.beginReadLatest();
    defer r.close();

    const users = try r.scan("user:");
    defer {
        for (users) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(users);
    }

    std.debug.print("Total users: {}\n", .{users.len});
    for (users) |kv| {
        std.debug.print("  {s}: {s}\n", .{kv.key, kv.value});
    }
}
```

## Performance Considerations

### Batch Writes

Group multiple writes into a single transaction for better performance:

```zig
// Good: Batch operation
var w = try db.beginWrite();
defer w.abort();

for (items) |item| {
    try w.put(item.key, item.value);
}

_ = try w.commit();  // Single fsync
```

### Read-Heavy Workloads

NorthstarDB supports unlimited concurrent readers:

```zig
// All these reads can happen simultaneously
var r1 = try db.beginReadLatest();
defer r1.close();

var r2 = try db.beginReadLatest();
defer r2.close();

var r3 = try db.beginReadLatest();
defer r3.close();

// No blocking between readers
```

### Key Design

Good key design improves performance:

```zig
// Good: Organized keys
"user:001"
"user:002"
"product:001"
"order:001"

// Bad: Unorganized keys make prefix scans inefficient
"1"
"2"
"3"
```

## Next Steps

Now that you understand CRUD operations, explore:

- [Snapshots & Time Travel](./snapshots-time-travel.md) - Query historical data
- [Cartridges Usage](./cartridges-usage.md) - AI-powered data structures
- [Performance Tuning](./performance-tuning.md) - Optimize your database
- [API Reference](../reference/db.md) - Complete API documentation
