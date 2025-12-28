---
title: WriteTxn API
description: Write transactions with ACID guarantees, read-your-writes, and atomic commits.
---

import { Card, Cards } from '@astrojs/starlight/components';

`WriteTxn` provides ACID write operations with single-writer concurrency control and read-your-writes semantics.

<Cards>
  <Card title="Single Writer" icon="lock">
    Only one write transaction at a time ensures serializability.
  </Card>
  <Card title="Read-Your-Writes" icon="eye">
    Reads see uncommitted changes within the same transaction.
  </Card>
  <Card title="Atomic Commit" icon="check">
    All changes or none - two-phase commit for durability.
  </Card>
</Cards>

## Starting a Write Transaction

### `db.beginWrite`

Starts a new write transaction. Fails if another write is active.

```zig
var w = try db.beginWrite();
defer {
    if (!w.committed) w.abort();
}

// Perform writes...
_ = try w.commit();
```

**Returns:** `!WriteTxn`

**Errors:**
- `WriteBusy` - Another write transaction is active

**Best practice:** Always use `defer` to ensure cleanup on error paths.

---

## Writing Data

### `w.put`

Insert or update a key-value pair.

```zig
try w.put("user:123", "Alice");

// Read-your-writes: sees the change immediately
const value = w.get("user:123");
try std.testing.expectEqualStrings("Alice", value.?);
```

**Parameters:**
- `key: []const u8` - Key to insert/update
- `value: []const u8` - Value to store

**Returns:** `!void`

**Behavior:**
- If key exists → Updates value
- If key doesn't exist → Creates new entry
- Change visible within transaction (read-your-writes)
- Not visible to other transactions until commit

---

### `w.del`

Delete a key from the database.

```zig
try w.del("user:123");

// Read-your-writes: key is now null
const value = w.get("user:123");
try std.testing.expect(value == null);
```

**Parameters:**
- `key: []const u8` - Key to delete

**Returns:** `!void`

**Behavior:**
- If key exists → Marks for deletion
- If key doesn't exist → No-op
- Change visible within transaction (read-your-writes)
- Not visible to other transactions until commit

---

## Reading Data (Read-Your-Writes)

### `w.get`

Read a key, seeing both committed data and uncommitted changes within this transaction.

```zig
// Read committed data
const old = w.get("counter").?;

// Update within transaction
try w.put("counter", "42");

// Read sees uncommitted change
const new = w.get("counter").?;
try std.testing.expectEqualStrings("42", new);
```

**Parameters:**
- `key: []const u8` - Key to read

**Returns:** `?[]const u8` - Value or null

**Read-your-writes priority:**
1. Check if deleted in this transaction → return null
2. Check if updated in this transaction → return new value
3. Check committed database state

---

## Committing or Aborting

### `w.commit`

Atomically commit all changes to the database.

```zig
var w = try db.beginWrite();
try w.put("key", "value");

const txn_id = try w.commit();
std.debug.print("Committed transaction {}\n", .{txn_id});
```

**Returns:** `!u64` - Transaction ID (LSN for file-backed)

**Commit process (file-backed):**
1. Prepare transaction (lock mutations)
2. Apply changes to B+tree
3. Write commit record to log file
4. Fsync log file
5. Update and write meta page
6. Fsync database file
7. Release writer lock
8. Run plugin hooks

**Commit process (in-memory):**
1. Update in-memory model
2. Release writer lock

**Errors:** Commit may fail due to I/O errors or resource constraints.

---

### `w.abort`

Rollback all changes and release the writer lock.

```zig
var w = try db.beginWrite();

try w.put("temp", "data");

// Abort - changes are discarded
w.abort();

// Key doesn't exist
var r = try db.beginReadLatest();
defer r.close();
try std.testing.expect(r.get("temp") == null);
```

**Best practice:** Use `defer` to ensure abort on error paths:

```zig
var w = try db.beginWrite();
defer w.abort();  // Runs if commit fails or we return early

try w.put("key1", "value1");
try someComplexOperation(&w);

_ = try w.commit();  // Explicit commit
```

---

## Transaction Metadata

### `w.getTxnId`

Get the transaction ID for this write transaction.

```zig
var w = try db.beginWrite();
const txn_id = w.getTxnId();
std.debug.print("Transaction ID: {}\n", .{txn_id});
```

**Returns:** `u64` - Transaction ID

---

### `w.hasMutations`

Check if the transaction has any pending mutations.

```zig
var w = try db.beginWrite();
try std.testing.expect(!w.hasMutations());

try w.put("key", "value");
try std.testing.expect(w.hasMutations());
```

**Returns:** `bool` - True if any put/del operations

---

## Coordination Primitives

### `w.claimTask`

Atomically claim a task using compare-and-swap semantics.

```zig
// Agent 1 tries to claim task 42
const claimed = try w.claimTask(42, 1, timestamp);
if (claimed) {
    std.debug.print("Agent 1 claimed task 42\n", .{});
    _ = try w.commit();
} else {
    std.debug.print("Task already claimed or doesn't exist\n", .{});
    w.abort();
}
```

**Parameters:**
- `task_id: u64` - Task to claim
- `agent_id: u64` - Agent claiming the task
- `claim_timestamp: i64` - When the claim is made

**Returns:** `!bool` - True if claim succeeded

**Atomic operations:**
1. Check if task metadata exists (`task:{id}`)
2. Check if already claimed by this agent (`claim:{id}:{agent}`)
3. Check if claimed by another agent (`claimed:{id}`)
4. Create claim record and update index
5. Increment agent's active task count

---

### `w.completeTask`

Atomically complete a claimed task.

```zig
const completed = try w.completeTask(42, 1, timestamp);
if (completed) {
    std.debug.print("Task 42 marked complete\n", .{});
    _ = try w.commit();
}
```

**Parameters:**
- `task_id: u64` - Task to complete
- `agent_id: u64` - Agent completing the task
- `completion_timestamp: i64` - When completed

**Returns:** `!bool` - True if completion succeeded

**Atomic operations:**
1. Verify claim exists for this agent
2. Mark task as completed (`completed:{id}`)
3. Remove claim record
4. Clear claimed index
5. Decrement agent's active task count

---

## Complete Examples

### Simple Write Transaction

```zig
fn updateUser(allocator: std.mem.Allocator, db: *Db, user_id: u64, name: []const u8) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var w = try db.beginWrite();
    defer w.abort();

    try w.put(key, name);

    // Verify write-your-writes
    const value = w.get(key);
    try std.testing.expectEqualStrings(name, value.?);

    _ = try w.commit();
}
```

### Batch Operations

```zig
fn batchImport(db: *Db, entries: []const struct { []const u8, []const u8 }) !void {
    var w = try db.beginWrite();
    defer w.abort();

    for (entries) |entry| {
        try w.put(entry[0], entry[1]);
    }

    // All or nothing - single atomic commit
    const txn_id = try w.commit();
    std.debug.print("Imported {} entries in txn {}\n", .{entries.len, txn_id});
}
```

### Conditional Update

```zig
fn incrementCounter(db: *Db, key: []const u8) !u64 {
    var w = try db.beginWrite();
    defer w.abort();

    // Read current value (read-your-writes)
    const current_str = w.get(key) orelse "0";
    const current = try std.fmt.parseInt(u64, current_str, 10);

    // Increment
    const new_value = current + 1;
    var value_buf: [32]u8 = undefined;
    const new_str = try std.fmt.bufPrint(&value_buf, "{}", .{new_value});

    try w.put(key, new_str);

    _ = try w.commit();
    return new_value;
}
```

### Task Queue Coordination

```zig
fn claimNextTask(db: *Db, agent_id: u64) !?u64 {
    var w = try db.beginWrite();
    defer w.abort();

    // Find next unclaimed task
    var r = try db.beginReadLatest();
    defer r.close();

    const tasks = try r.scan("task:");
    defer {
        for (tasks) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(tasks);
    }

    for (tasks) |kv| {
        // Extract task ID from key "task:123"
        const task_id = try std.fmt.parseInt(u64, kv.key[5..], 10);

        // Try to claim
        const now = @intCast(std.time.nanoTimestamp());
        if (try w.claimTask(task_id, agent_id, now)) {
            _ = try w.commit();
            return task_id;
        }
    }

    w.abort();
    return null;  // No tasks available
}

fn completeTask(db: *Db, task_id: u64, agent_id: u64) !void {
    var w = try db.beginWrite();
    defer w.abort();

    const now = @intCast(std.time.nanoTimestamp());
    if (!try w.completeTask(task_id, agent_id, now)) {
        return error.TaskNotClaimed;
    }

    _ = try w.commit();
}
```

### Delete and Verify

```zig
fn deleteUser(db: *Db, user_id: u64) !void {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "user:{d}", .{user_id});

    var w = try db.beginWrite();
    defer w.abort();

    // Delete the user
    try w.del(key);

    // Verify read-your-writes
    const value = w.get(key);
    try std.testing.expect(value == null);

    _ = try w.commit();
}
```

---

## Error Handling Patterns

### Writer Lock Enforcement

```zig
fn writeToDatabase(db: *Db) !void {
    var w = db.beginWrite() catch |err| {
        if (err == error.WriteBusy) {
            std.log.err("Another write is in progress", .{});
            return error.TryAgainLater;
        }
        return err;
    };
    defer w.abort();

    // ... perform writes ...

    _ = try w.commit();
}
```

### Commit Retry Logic

```zig
fn writeWithRetry(db: *Db, key: []const u8, value: []const u8, max_retries: u32) !void {
    var retry: u32 = 0;
    while (retry < max_retries) : (retry += 1) {
        var w = try db.beginWrite();
        defer w.abort();

        try w.put(key, value);

        _ = w.commit() catch |err| {
            std.log.warn("Commit failed (attempt {}): {}", .{retry, err});
            continue;
        };

        return;  // Success
    }
    return error.MaxRetriesExceeded;
}
```

---

## Reference Summary

| Method | Description |
|--------|-------------|
| `db.beginWrite()` | Start write transaction |
| `w.put(key, value)` | Insert or update |
| `w.del(key)` | Delete key |
| `w.get(key)` | Read with read-your-writes |
| `w.commit()` | Atomically commit changes |
| `w.abort()` | Rollback changes |
| `w.getTxnId()` | Get transaction ID |
| `w.hasMutations()` | Check if has changes |
| `w.claimTask(task_id, agent_id, ts)` | Atomically claim task |
| `w.completeTask(task_id, agent_id, ts)` | Atomically complete task |

See also:
- [Db API](./db.md) - Database opening and configuration
- [ReadTxn API](./readtxn.md) - Read transaction methods
- [Transaction Semantics](../specs/semantics-v0.md) - ACID guarantees
