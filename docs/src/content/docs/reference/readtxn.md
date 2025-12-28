---
title: ReadTxn API
description: Read-only transactions with consistent snapshots and time-travel queries.
---

import { Card, Cards } from '@astrojs/starlight/components';

`ReadTxn` provides read-only access to the database with MVCC snapshot isolation. Multiple readers can execute concurrently without blocking.

<Cards>
  <Card title="Snapshot Isolation" icon="camera">
    Reads see a consistent snapshot from the transaction start time.
  </Card>
  <Card title="Concurrent Readers" icon="users">
    Unlimited readers can execute simultaneously.
  </Card>
  <Card title="Time Travel" icon="history">
    Query data as it existed at any past transaction.
  </Card>
</Cards>

## Starting a Read Transaction

### `db.beginReadLatest`

Start a read transaction at the latest committed state.

```zig
var r = try db.beginReadLatest();
defer r.close();

const value = r.get("my_key");
```

**Returns:** `!ReadTxn`

**Use case:** Reading current data with consistency guarantees.

---

### `db.beginReadAt`

Start a read transaction at a specific past transaction (time-travel query).

```zig
// Read state as it existed after transaction 42
var r = try db.beginReadAt(42);
defer r.close();

const old_value = r.get("my_key");
```

**Parameters:**
- `txn_id: u64` - Transaction ID to read from

**Returns:** `!ReadTxn`

**Errors:**
- `SnapshotNotFound` - No snapshot exists for given txn_id

**Use case:** Auditing, historical analysis, rollback recovery.

---

## Reading Data

### `r.get`

Reads a single key-value pair.

```zig
if (r.get("user:123")) |value| {
    std.debug.print("Value: {s}\n", .{value});
    allocator.free(value);  // Caller owns the memory
} else {
    std.debug.print("Key not found\n", .{});
}
```

**Parameters:**
- `key: []const u8` - Key to look up

**Returns:** `?[]const u8` - Value if found, null if not found

**Memory ownership:** Caller must free the returned value.

**File-based behavior:** Reads from B+tree at snapshot's root page.

**In-memory behavior:** Reads from in-memory map.

---

### `r.scan`

Prefix scan returns all key-value pairs with a given prefix, sorted by key.

```zig
// Get all user entries
const users = try r.scan("user:");
defer {
    for (users) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
    allocator.free(users);
}

for (users) |kv| {
    std.debug.print("{s} = {s}\n", .{kv.key, kv.value});
}
```

**Parameters:**
- `prefix: []const u8` - Key prefix to scan

**Returns:** `![]const KV` - Array of key-value pairs

**Memory ownership:** Caller owns all memory (array and strings).

**Order:** Results are sorted by key.

---

### `r.iterator`

Creates an iterator for full key range.

```zig
var iter = try r.iterator();
while (try iter.next()) |kv| {
    std.debug.print("{s} = {s}\n", .{kv.key, kv.value});
}
```

**Returns:** `!ReadIterator`

**Note:** Only supported for file-based databases.

---

### `r.iteratorRange`

Creates an iterator for a specific key range `[start_key, end_key)`.

```zig
// Iterate keys from "apple" to "cherry"
var iter = try r.iteratorRange("apple", "cherry");
while (try iter.next()) |kv| {
    std.debug.print("{s} = {s}\n", .{kv.key, kv.value});
}
```

**Parameters:**
- `start_key: ?[]const u8` - Start key (inclusive), `null` for beginning
- `end_key: ?[]const u8` - End key (exclusive), `null` for end

**Returns:** `!ReadIterator`

**Note:** Only supported for file-based databases.

---

## Closing a Transaction

### `r.close`

Releases resources associated with the read transaction.

```zig
var r = try db.beginReadLatest();
defer r.close();  // Always close

// Use transaction...
```

**Best practice:** Always use `defer` to ensure cleanup.

---

## Iterator API

### `iter.next`

Advances iterator and returns current key-value pair.

```zig
while (try iter.next()) |kv| {
    // Process kv.key and kv.value
}
```

**Returns:** `!?KV` - Next pair, or `null` when exhausted

### `iter.valid`

Checks if iterator has more items.

```zig
if (iter.valid()) {
    // Has more items
}
```

---

## Complete Examples

### Simple Point Read

```zig
fn getUser(allocator: std.mem.Allocator, db: *Db, user_id: u64) !?[]const u8 {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var r = try db.beginReadLatest();
    defer r.close();

    return r.get(key);  // Caller owns memory
}
```

### Prefix Scan

```zig
fn listUsers(allocator: std.mem.Allocator, db: *Db) ![][]const u8 {
    var r = try db.beginReadLatest();
    defer r.close();

    const kvs = try r.scan("user:");
    defer {
        for (kvs) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(kvs);
    }

    // Extract just the values
    var users = try allocator.alloc([]const u8, kvs.len);
    for (kvs, 0..) |kv, i| {
        users[i] = try allocator.dupe(u8, kv.value);
    }

    return users;
}
```

### Range Iteration

```zig
fn rangeLookup(db: *Db, start: []const u8, end: []const u8) !void {
    var r = try db.beginReadLatest();
    defer r.close();

    var iter = try r.iteratorRange(start, end);
    while (try iter.next()) |kv| {
        std.debug.print("{s} = {s}\n", .{kv.key, kv.value});
    }
}
```

### Time Travel Query

```zig
fn auditLog(db: *Db, as_of_txn_id: u64) !void {
    var r = try db.beginReadAt(as_of_txn_id);
    defer r.close();

    const entries = try r.scan("audit:");
    defer {
        for (entries) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(entries);
    }

    std.debug.print("State as of txn {}:\n", .{as_of_txn_id});
    for (entries) |kv| {
        std.debug.print("  {s}: {s}\n", .{kv.key, kv.value});
    }
}
```

---

## Reference Summary

| Method | Description |
|--------|-------------|
| `db.beginReadLatest()` | Start read at latest state |
| `db.beginReadAt(txn_id)` | Start read at specific snapshot |
| `r.get(key)` | Point lookup |
| `r.scan(prefix)` | Prefix scan (sorted) |
| `r.iterator()` | Full range iterator |
| `r.iteratorRange(start, end)` | Bounded range iterator |
| `r.close()` | Release resources |
| `iter.next()` | Get next item from iterator |
| `iter.valid()` | Check if more items available |

See also:
- [Db API](./db.md) - Database opening and configuration
- [WriteTxn API](./writetxn.md) - Write transaction methods
- [MVCC Semantics](../specs/semantics-v0.md) - Snapshot isolation details
