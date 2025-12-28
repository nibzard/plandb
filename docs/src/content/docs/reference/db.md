---
title: Db API
description: Core database interface for opening, closing, and configuring NorthstarDB.
---

import { Card, Cards } from '@astrojs/starlight/components';

The `Db` type is the main entry point for working with NorthstarDB. It provides methods for opening databases (in-memory or file-backed), beginning transactions, and managing database lifecycle.

## Overview

<Cards>
  <Card title="In-Memory Mode" icon="memory">
    Fast, ephemeral storage for testing and caching. No persistence.
  </Card>
  <Card title="File-Backed Mode" icon="file">
    Durable storage with ACID semantics via WAL and B+tree.
  </Card>
  <Card title="Single Writer" icon="lock">
    Only one write transaction at a time. Unlimited concurrent readers.
  </Card>
</Cards>

## Opening a Database

### `Db.open`

Opens an in-memory database. Data is stored only in RAM and lost when the database is closed.

```zig
const std = @import("std");
const db = @import("northstar");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var my_db = try db.Db.open(allocator);
    defer my_db.close();

    // Use the database...
}
```

**Returns:** `!Db` - Errors from allocator failures

**Use cases:**
- Unit tests
- Caching layers
- Session storage
- Temporary computations

---

### `Db.openWithFile`

Opens a file-backed database with durability guarantees. Creates files if they don't exist.

```zig
const std = @import("std");
const db = @import("northstar");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open file-backed database
    var my_db = try db.Db.openWithFile(
        allocator,
        "data.db",    // Database file path
        "data.wal",   // Write-ahead log path
    );
    defer my_db.close();

    // Database is now durable
}
```

**Parameters:**
- `allocator: std.mem.Allocator` - Memory allocator for the database
- `db_path: []const u8` - Path to database file (`.db`)
- `wal_path: []const u8` - Path to write-ahead log file (`.wal`)

**Returns:** `!Db` - Errors from file I/O, allocator failures, or corruption

**Error handling:**

```zig
var my_db = db.Db.openWithFile(allocator, "data.db", "data.wal") catch |err| {
    std.log.err("Failed to open database: {}", .{err});
    return err;
};
```

**File creation behavior:**
- If `db_path` doesn't exist → Creates new database
- If `db_path` exists → Opens existing database
- If `wal_path` doesn't exist → Creates new WAL
- If `wal_path` exists → Replays WAL for recovery

---

## Closing a Database

### `db.close`

Closes the database and releases all resources. Must be called before the database goes out of scope.

```zig
var my_db = try db.Db.open(allocator);
defer my_db.close();  // Always close, even on error

// Use database...
```

**Behavior:**
- Flushes any pending writes
- Closes file descriptors
- Frees allocated memory
- Deinitializes WAL and pager
- **Does NOT** cleanup `plugin_manager` (caller's responsibility)

**Important:** Always use `defer` to ensure cleanup:

```zig
var my_db = try db.Db.open(allocator);
defer my_db.close();

// Even if code here panics or returns error, close() runs
```

---

## Database Configuration

NorthstarDB currently doesn't have a formal config struct. Configuration is done through:

1. **Mode selection** - `open()` vs `openWithFile()`
2. **File paths** - Passed to `openWithFile()`
3. **Plugin attachment** - Optional via `attachPluginManager()`

### Attaching Plugins (Phase 7)

Enable AI intelligence by attaching a plugin manager:

```zig
const plugins = @import("northstar/plugins");

// Create plugin manager
var plugin_manager = try plugins.PluginManager.init(allocator, .{
    .llm_provider = .{
        .provider_type = "openai",  // or "anthropic", "local"
        .model = "gpt-4",
    },
    .fallback_on_error = true,
    .performance_isolation = true,
});
defer plugin_manager.deinit();

// Register plugins
try plugin_manager.register_plugin(my_plugin);

// Attach to database
var my_db = try db.Db.openWithFile(allocator, "data.db", "data.wal");
defer my_db.close();
my_db.attachPluginManager(&plugin_manager);

// Plugin hooks now run on commits
```

**Note:** The database does **not** own the plugin manager. You must deinit it separately.

---

## Error Handling Patterns

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `OutOfMemory` | Allocator failed | Use larger arena or check memory |
| `FileNotFound` | (handled internally) | Creates new file automatically |
| `InvalidFile` | Corrupted database file | Check file integrity, restore backup |
| `WriteBusy` | Two concurrent write transactions | Commit/abort first transaction |

### Proper Error Handling

```zig
const std = @import("std");
const db = @import("northstar");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open with error handling
    var my_db = db.Db.openWithFile(allocator, "data.db", "data.wal") catch |err| {
        std.log.err("Failed to open database: {}", .{err});
        return err;
    };
    defer my_db.close();

    // Begin write transaction
    var w = my_db.beginWrite() catch |err| {
        if (err == db.WriteBusy.WriteBusy) {
            std.log.err("Another write transaction is active", .{});
        }
        return err;
    };
    defer {
        if (!w.committed) w.abort();
    }

    // Do work...
    _ = try w.put("key", "value");
    _ = try w.commit();
}
```

---

## Lifecycle Examples

### In-Memory Database

```zig
test "in-memory lifecycle" {
    const allocator = std.testing.allocator;

    var db = try Db.open(allocator);
    defer db.close();

    var w = try db.beginWrite();
    try w.put("test", "data");
    _ = try w.commit();

    var r = try db.beginReadLatest();
    defer r.close();
    try std.testing.expectEqualStrings("data", r.get("test").?);
}
```

### File-Backed Database

```zig
test "file-backed lifecycle" {
    const allocator = std.testing.allocator;
    const db_path = "test.db";
    const wal_path = "test.wal";
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        std.fs.cwd().deleteFile(wal_path) catch {};
    }

    // First open - creates files
    {
        var db = try Db.openWithFile(allocator, db_path, wal_path);
        defer db.close();

        var w = try db.beginWrite();
        try w.put("persistent", "value");
        _ = try w.commit();
    }

    // Second open - recovers from disk
    {
        var db = try Db.openWithFile(allocator, db_path, wal_path);
        defer db.close();

        var r = try db.beginReadLatest();
        defer r.close();
        try std.testing.expectEqualStrings("value", r.get("persistent").?);
    }
}
```

### Database with Plugins

```zig
test "database with ai plugins" {
    const allocator = std.testing.allocator;

    // Setup plugin manager
    var plugin_manager = try plugins.PluginManager.init(allocator, .{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    });
    defer plugin_manager.deinit();

    // Register plugin
    const my_plugin = plugins.Plugin{
        .name = "entity_extractor",
        .version = "1.0.0",
        .on_commit = entityExtractorHook,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
    };
    try plugin_manager.register_plugin(my_plugin);

    // Open database with plugins
    var db = try Db.open(allocator);
    defer db.close();
    db.attachPluginManager(&plugin_manager);

    // Commits now trigger entity extraction
    var w = try db.beginWrite();
    try w.put("user:123", "Alice");
    _ = try w.commit();  // Plugin hook runs here
}
```

---

## Reference Summary

| Method | Description |
|--------|-------------|
| `Db.open(allocator)` | Open in-memory database |
| `Db.openWithFile(allocator, db_path, wal_path)` | Open file-backed database |
| `db.close()` | Close database and release resources |
| `db.attachPluginManager(manager)` | Attach AI plugin manager |
| `db.beginReadLatest()` | Start read transaction at latest state |
| `db.beginReadAt(txn_id)` | Start read transaction at specific snapshot |
| `db.beginWrite()` | Start write transaction |

See also:
- [ReadTxn API](./readtxn.md) - Read transaction methods
- [WriteTxn API](./writetxn.md) - Write transaction methods
- [Transaction Semantics](../specs/semantics-v0.md) - ACID guarantees
