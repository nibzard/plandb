---
title: Snapshots & Time Travel Guide
description: Learn how to use MVCC snapshots for consistent reads and time-travel queries in NorthstarDB.
---

import { Card, Cards } from '@astrojs/starlight/components';

NorthstarDB's MVCC (Multi-Version Concurrency Control) architecture enables powerful snapshot isolation and time-travel query capabilities. This guide shows you how to leverage these features for consistent reads and historical analysis.

<Cards>
  <Card title="Snapshot Isolation" icon="camera">
    Reads see a consistent view at a point in time.
  </Card>
  <Card title="Time Travel" icon="history">
    Query data as it existed at any past transaction.
  </Card>
  <Card title="Zero Blocking" icon="zap">
    Readers never block writers or each other.
  </Card>
</Cards>

## Understanding Snapshots

A **snapshot** represents the database state at a specific transaction ID. When you start a read transaction, you get a snapshot that remains consistent for the duration of that transaction.

### How Snapshots Work

```zig
// Transaction 1: Insert data
var w1 = try db.beginWrite();
try w1.put("key1", "value1");
const txn_id_1 = try w1.commit();

// Transaction 2: Update data
var w2 = try db.beginWrite();
try w2.put("key1", "value2");
const txn_id_2 = try w2.commit();

// Both snapshots are available simultaneously
var r_old = try db.beginReadAt(txn_id_1);  // Sees "value1"
defer r_old.close();

var r_new = try db.beginReadAt(txn_id_2);  // Sees "value2"
defer r_new.close();
```

## Reading the Latest State

### `db.beginReadLatest`

Start a read transaction at the most recent committed state:

```zig
var r = try db.beginReadLatest();
defer r.close();

const value = r.get("my_key");
if (value) |v| {
    defer allocator.free(v);
    std.debug.print("Latest value: {s}\n", .{v});
}
```

**Use cases:**
- Reading current data
- Real-time queries
- Standard application reads

**Benefits:**
- Always sees the latest committed data
- No blocking from concurrent writers
- Consistent view within the transaction

## Time Travel Queries

### Reading Historical State

### `db.beginReadAt`

Start a read transaction at a specific past transaction:

```zig
// Read state as it existed after transaction 42
var r = try db.beginReadAt(42);
defer r.close();

const old_value = r.get("user:123");
if (old_value) |v| {
    defer allocator.free(v);
    std.debug.print("Value as of txn 42: {s}\n", .{v});
}
```

**When to use time travel:**
- Auditing and compliance
- Debugging historical issues
- Rollback recovery analysis
- Data archaeology

### Example: Audit Trail

```zig
fn auditUserChanges(
    db: *db.Db,
    user_id: u64,
    from_txn: u64,
    to_txn: u64,
    allocator: std.mem.Allocator
) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    std.debug.print("Audit trail for user {}:\n", .{user_id});

    // Check state at multiple points in time
    var txn_id = from_txn;
    while (txn_id <= to_txn) : (txn_id += 1) {
        var r = db.beginReadAt(txn_id) catch |err| switch (err) {
            error.SnapshotNotFound => continue,  // Skip missing snapshots
            else => return err,
        };
        defer r.close();

        if (r.get(key)) |value| {
            defer allocator.free(value);
            std.debug.print("  Txn {}: {s}\n", .{txn_id, value});
        }
    }
}
```

## Snapshot Isolation Guarantees

### Consistent Reads

Within a single read transaction, all reads see the same snapshot:

```zig
var r = try db.beginReadLatest();
defer r.close();

// Both reads see the same snapshot, even if
// another transaction commits in between
const value1 = r.get("key1");
const value2 = r.get("key2");

// value1 and value2 are consistent with each other
```

### No Phantom Reads

Snapshot isolation prevents phantom reads:

```zig
var r1 = try db.beginReadLatest();
defer r1.close();

const count1 = countUsers(&r1);  // Returns 10

// Another transaction adds users here

const count2 = countUsers(&r1);  // Still returns 10
// Same snapshot, consistent result
```

### Concurrent Readers

Multiple read transactions can execute simultaneously without blocking:

```zig
// All these reads can happen at the same time
var r1 = try db.beginReadLatest();
defer r1.close();

var r2 = try db.beginReadLatest();
defer r2.close();

var r3 = try db.beginReadLatest();
defer r3.close();

// None of these block each other
```

## Practical Patterns

### Pattern 1: Point-in-Time Analysis

```zig
fn analyzeStateAt(
    db: *db.Db,
    txn_id: u64,
    allocator: std.mem.Allocator
) !void {
    var r = try db.beginReadAt(txn_id);
    defer r.close();

    // Analyze database state at specific point in time
    const user_count = try countUsersWithPrefix(&r, "user:", allocator);
    const order_count = try countUsersWithPrefix(&r, "order:", allocator);

    std.debug.print("State at txn {}:\n", .{txn_id});
    std.debug.print("  Users: {}\n", .{user_count});
    std.debug.print("  Orders: {}\n", .{order_count});
}

fn countUsersWithPrefix(
    r: *db.ReadTxn,
    prefix: []const u8,
    allocator: std.mem.Allocator
) !usize {
    const items = try r.scan(prefix);
    defer {
        for (items) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(items);
    }
    return items.len;
}
```

### Pattern 2: Change Detection

```zig
fn detectChanges(
    db: *db.Db,
    key: []const u8,
    from_txn: u64,
    to_txn: u64
) !bool {
    var r1 = try db.beginReadAt(from_txn);
    defer r1.close();

    var r2 = try db.beginReadAt(to_txn);
    defer r2.close();

    const old_value = r1.get(key);
    const new_value = r2.get(key);

    // Compare values
    if (old_value == null and new_value == null) {
        return false;  // No change (key didn't exist)
    }

    if (old_value == null or new_value == null) {
        return true;  // Key added or removed
    }

    // Both non-null, compare contents
    return !std.mem.eql(u8, old_value.?, new_value.?);
}
```

### Pattern 3: Temporal Join

```zig
fn getUserOrderAtTime(
    db: *db.Db,
    user_id: u64,
    order_id: u64,
    as_of_txn: u64,
    allocator: std.mem.Allocator
) !struct { []const u8, []const u8 } {
    // Read both user and order at same point in time
    var r = try db.beginReadAt(as_of_txn);
    defer r.close();

    var user_key_buf: [32]u8 = undefined;
    const user_key = try std.fmt.bufPrint(&user_key_buf, "user:{d}", .{user_id});

    var order_key_buf: [32]u8 = undefined;
    const order_key = try std.fmt.bufPrint(&order_key_buf, "order:{d}", .{order_id});

    const user = r.get(user_key) orelse return error.UserNotFound;
    const order = r.get(order_key) orelse return error.OrderNotFound;

    // Return copies since r.close() will invalidate them
    return .{
        try allocator.dupe(u8, user),
        try allocator.dupe(u8, order),
    };
}
```

### Pattern 4: Version History

```zig
fn getVersionHistory(
    db: *db.Db,
    key: []const u8,
    allocator: std.mem.Allocator
) ![][]const u8 {
    // This is a simplified example
    // In production, you'd need to track snapshot IDs separately

    var versions = std.ArrayList([]const u8).init(allocator);

    // Check recent snapshots (example: last 10 transactions)
    var txn_id: u64 = 0;
    while (txn_id < 10) : (txn_id += 1) {
        var r = db.beginReadAt(txn_id) catch |err| switch (err) {
            error.SnapshotNotFound => continue,
            else => return err,
        };
        defer r.close();

        if (r.get(key)) |value| {
            const copy = try allocator.dupe(u8, value);
            try versions.append(copy);
        }
    }

    return versions.toOwnedSlice();
}
```

## Snapshot Lifecycle

### Automatic Cleanup

NorthstarDB automatically manages snapshot lifecycle. For in-memory databases, snapshots are garbage collected when no longer in use. For file-backed databases, the snapshot registry manages cleanup:

```zig
// Cleanup old snapshots (keeping recent N)
const snapshot_registry = db.snapshot_registry orelse return;

const removed = try snapshot_registry.cleanupOldSnapshots(
    latest_txn_id,
    keep_last_n  // Keep last N snapshots
);

std.debug.print("Cleaned up {} old snapshots\n", .{removed});
```

### Snapshot Availability

Snapshots are available as long as:
1. They haven't been cleaned up
2. The database file hasn't been compacted
3. For in-memory: The data hasn't been freed

## Error Handling

### Snapshot Not Found

```zig
fn safeReadAt(db: *db.Db, txn_id: u64, key: []const u8) !?[]const u8 {
    var r = db.beginReadAt(txn_id) catch |err| switch (err) {
        error.SnapshotNotFound => {
            std.log.warn("Snapshot {} not available", .{txn_id});
            return null;
        },
        else => return err,
    };
    defer r.close();

    return r.get(key);
}
```

### Handling Missing Snapshots

```zig
fn readWithFallback(
    db: *db.Db,
    preferred_txn: u64,
    key: []const u8
) !?[]const u8 {
    // Try preferred snapshot
    var r = db.beginReadAt(preferred_txn) catch |err| switch (err) {
        error.SnapshotNotFound => {
            // Fallback to latest
            std.log.warn("Snapshot {} unavailable, using latest", .{preferred_txn});
            var r_latest = try db.beginReadLatest();
            defer r_latest.close();
            return r_latest.get(key);
        },
        else => return err,
    };
    defer r.close();

    return r.get(key);
}
```

## Use Cases

### 1. Debugging Production Issues

```zig
fn investigateIssue(
    db: *db.Db,
    issue_time: i64,
    suspect_key: []const u8
) !void {
    // Convert timestamp to approximate transaction ID
    const txn_id = timestampToTxnId(issue_time);

    std.debug.print("Investigating state at txn {}:\n", .{txn_id});

    var r = try db.beginReadAt(txn_id);
    defer r.close();

    if (r.get(suspect_key)) |value| {
        defer allocator.free(value);
        std.debug.print("Key value at time of issue: {s}\n", .{value});
    } else {
        std.debug.print("Key didn't exist at time of issue\n", .{});
    }

    // Check related keys
    const related = try r.scan("related:");
    defer {
        for (related) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(related);
    }

    for (related) |kv| {
        std.debug.print("  {s}: {s}\n", .{kv.key, kv.value});
    }
}
```

### 2. Compliance Auditing

```zig
fn complianceAudit(
    db: *db.Db,
    user_id: u64,
    audit_start: u64,
    audit_end: u64,
    allocator: std.mem.Allocator
) !void {
    std.debug.print("Compliance audit for user {}:\n", .{user_id});

    var txn_id = audit_start;
    while (txn_id <= audit_end) : (txn_id += 1) {
        var r = db.beginReadAt(txn_id) catch |err| switch (err) {
            error.SnapshotNotFound => continue,
            else => return err,
        };
        defer r.close();

        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

        if (r.get(key)) |value| {
            defer allocator.free(value);
            std.log.info("Txn {}: {s}", .{txn_id, value});
        }
    }
}
```

### 3. Rollback Recovery

```zig
fn findRollbackPoint(
    db: *db.Db,
    key: []const u8,
    bad_txn: u64
) !?u64 {
    // Search backwards for last known good state
    var txn_id = bad_txn - 1;

    while (txn_id > 0) : (txn_id -= 1) {
        var r = db.beginReadAt(txn_id) catch |err| switch (err) {
            error.SnapshotNotFound => continue,
            else => return err,
        };
        defer r.close();

        if (r.get(key)) |value| {
            defer allocator.free(value);
            // Found a good state
            return txn_id;
        }
    }

    return null;
}
```

### 4. Data Reconciliation

```zig
fn reconcileData(
    db: *db.Db,
    key: []const u8,
    txn1: u64,
    txn2: u64
) !void {
    var r1 = try db.beginReadAt(txn1);
    defer r1.close();

    var r2 = try db.beginReadAt(txn2);
    defer r2.close();

    const value1 = r1.get(key);
    const value2 = r2.get(key);

    if (value1 == null and value2 == null) {
        std.debug.print("{s}: didn't exist in either snapshot\n", .{key});
    } else if (value1 == null) {
        defer allocator.free(value2.?);
        std.debug.print("{s}: added after txn {} -> {s}\n", .{key, txn1, value2.?});
    } else if (value2 == null) {
        defer allocator.free(value1.?);
        std.debug.print("{s}: deleted after txn {} (was: {s})\n", .{key, txn1, value1.?});
    } else {
        defer {
            allocator.free(value1.?);
            allocator.free(value2.?);
        }
        if (std.mem.eql(u8, value1.?, value2.?)) {
            std.debug.print("{s}: unchanged\n", .{key});
        } else {
            std.debug.print("{s}: changed\n", .{key});
            std.debug.print("  Txn {}: {s}\n", .{txn1, value1.?});
            std.debug.print("  Txn {}: {s}\n", .{txn2, value2.?});
        }
    }
}
```

## Performance Considerations

### Memory Usage

Each read transaction holds a snapshot:

```zig
// These snapshots consume memory
var r1 = try db.beginReadLatest();
var r2 = try db.beginReadLatest();
var r3 = try db.beginReadLatest();

// Close when done
r1.close();
r2.close();
r3.close();
```

**Best practice:** Close snapshots promptly when done.

### Snapshot Freshness

For near-real-time reads, use `beginReadLatest`:

```zig
// Good for real-time
var r = try db.beginReadLatest();
defer r.close();
```

For point-in-time analysis, use `beginReadAt`:

```zig
// Good for historical analysis
var r = try db.beginReadAt(historical_txn_id);
defer r.close();
```

## Complete Example: Temporal Version Control

Here's a complete example showing a simple version control system:

```zig
const std = @import("std");
const db = @import("northstar");

/// Document with version history
pub const Document = struct {
    key: []const u8,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, key: []const u8, content: []const u8) !Document {
        return .{
            .key = try allocator.dupe(u8, key),
            .content = try allocator.dupe(u8, content),
        };
    }

    pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.content);
    }
};

/// Create a new document version
pub fn createDocument(
    database: *db.Db,
    key: []const u8,
    content: []const u8
) !u64 {
    var w = try database.beginWrite();
    defer w.abort();

    try w.put(key, content);
    return try w.commit();
}

/// Get current document
pub fn getCurrentDocument(
    database: *db.Db,
    key: []const u8,
    allocator: std.mem.Allocator
) !?Document {
    var r = try database.beginReadLatest();
    defer r.close();

    const content = r.get(key) orelse return null;
    errdefer allocator.free(content);

    return Document.init(allocator, key, content);
}

/// Get document at specific version
pub fn getDocumentAt(
    database: *db.Db,
    key: []const u8,
    version: u64,
    allocator: std.mem.Allocator
) !?Document {
    var r = database.beginReadAt(version) catch |err| switch (err) {
        error.SnapshotNotFound => return null,
        else => return err,
    };
    defer r.close();

    const content = r.get(key) orelse return null;
    errdefer allocator.free(content);

    return Document.init(allocator, key, content);
}

/// Compare two versions
pub fn diffVersions(
    database: *db.Db,
    key: []const u8,
    version1: u64,
    version2: u64
) !void {
    var r1 = try database.beginReadAt(version1);
    defer r1.close();

    var r2 = try database.beginReadAt(version2);
    defer r2.close();

    const content1 = r1.get(key);
    const content2 = r2.get(key);

    std.debug.print("Diff for {s}:\n", .{key});

    if (content1) |c1| {
        defer allocator.free(c1);
        std.debug.print("  Version {}: {} bytes\n", .{version1, c1.len});
    } else {
        std.debug.print("  Version {}: (doesn't exist)\n", .{version1});
    }

    if (content2) |c2| {
        defer allocator.free(c2);
        std.debug.print("  Version {}: {} bytes\n", .{version2, c2.len});
    } else {
        std.debug.print("  Version {}: (doesn't exist)\n", .{version2});
    }
}

/// Get document history
pub fn getDocumentHistory(
    database: *db.Db,
    key: []const u8,
    from_version: u64,
    to_version: u64,
    allocator: std.mem.Allocator
) ![]Document {
    var versions = std.ArrayList(Document).init(allocator);

    var version = from_version;
    while (version <= to_version) : (version += 1) {
        var r = database.beginReadAt(version) catch |err| switch (err) {
            error.SnapshotNotFound => continue,
            else => {
                versions.deinit();
                return err;
            },
        };
        defer r.close();

        if (r.get(key)) |content| {
            errdefer allocator.free(content);
            const doc = try Document.init(allocator, key, content);
            try versions.append(doc);
        }
    }

    return versions.toOwnedSlice();
}
```

## Next Steps

Now that you understand snapshots and time travel:

- [CRUD Operations](./crud-operations.md) - Basic database operations
- [Cartridges Usage](./cartridges-usage.md) - AI-powered data structures
- [Performance Tuning](./performance-tuning.md) - Optimize snapshot usage
- [ReadTxn API](../reference/readtxn.md) - Complete read transaction API
