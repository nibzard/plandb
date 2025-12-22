# Getting Started with NorthstarDB

This guide helps you get up and running with NorthstarDB, from basic installation to advanced AI intelligence features.

## Quick Start

### Prerequisites

- **Zig 0.15.2+**: Required for building the database
- **Git**: For cloning the repository
- **Linux/macOS**: Currently supported platforms (Windows in progress)

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/northstar-db.git
cd northstar-db

# Build the project
zig build

# Run tests to verify installation
zig build test

# Run benchmarks to check performance
zig build run -- run --suite micro --repeats 1
```

### Your First Database

```zig
const std = @import("std");
const db = @import("src/db.zig");

pub fn main() !void {
    var gpa = std.heap.page_allocator;

    // Open an in-memory database
    var my_db = try db.Db.open(gpa);
    defer my_db.close();

    // Start a write transaction
    var wtxn = try my_db.beginWrite();
    defer wtxn.abort(); // We'll commit instead later

    // Add some data
    try wtxn.put("user:001", "Alice");
    try wtxn.put("user:002", "Bob");
    try wtxn.put("user:003", "Charlie");

    // Commit the transaction
    const txn_id = try wtxn.commit();
    std.debug.print("Committed transaction {}\n", .{txn_id});

    // Start a read transaction
    var rtxn = try my_db.beginReadLatest();
    defer rtxn.close();

    // Read data
    const alice = rtxn.get("user:001");
    if (alice) |name| {
        std.debug.print("User: {s}\n", .{name});
    }

    // Scan by prefix
    const users = try rtxn.scan("user:");
    defer gpa.free(users);

    for (users) |user| {
        std.debug.print("{s}: {s}\n", .{ user.key, user.value });
    }
}
```

## File-Based Database

For persistent storage, use file-based databases:

```zig
pub fn persistent_example() !void {
    var gpa = std.heap.page_allocator;

    // Open file-based database
    var my_db = try db.Db.openWithFile(gpa, "mydata.db", "mydata.wal");
    defer my_db.close();

    // Same operations as in-memory example
    var wtxn = try my_db.beginWrite();
    defer wtxn.abort();

    try wtxn.put("config:theme", "dark");
    const txn_id = try wtxn.commit();

    std.debug.print("Stored config in transaction {}\n", .{txn_id});
}
```

## Time Travel Queries

Access historical data using transaction IDs:

```zig
pub fn time_travel_example() !void {
    var gpa = std.heap.page_allocator;

    var my_db = try db.Db.openWithFile(gpa, "history.db", "history.wal");
    defer my_db.close();

    // Create some history
    var wtxn1 = try my_db.beginWrite();
    try wtxn1.put("counter", "1");
    const txn1 = try wtxn1.commit();

    var wtxn2 = try my_db.beginWrite();
    try wtxn2.put("counter", "2");
    const txn2 = try wtxn2.commit();

    var wtxn3 = try my_db.beginWrite();
    try wtxn3.put("counter", "3");
    const txn3 = try wtxn3.commit();

    // Read different historical states
    {
        var rtxn = try my_db.beginReadAt(txn1);
        defer rtxn.close();
        const value = rtxn.get("counter");
        std.debug.print("State after txn1: {s}\n", .{value.?}); // "1"
    }

    {
        var rtxn = try my_db.beginReadAt(txn2);
        defer rtxn.close();
        const value = rtxn.get("counter");
        std.debug.print("State after txn2: {s}\n", .{value.?}); // "2"
    }

    {
        var rtxn = try my_db.beginReadLatest();
        defer rtxn.close();
        const value = rtxn.get("counter");
        std.debug.print("Current state: {s}\n", .{value.?}); // "3"
    }
}
```

## Benchmarks

Run performance benchmarks:

```bash
# Run all microbenchmarks
zig build run -- run --suite micro

# Run specific benchmark
zig build run -- run --filter "btree/point_get"

# Run with custom settings
zig build run -- run --repeats 10 --suite micro --output results/
```

### Benchmark Results

Results are saved as JSON files for analysis:

```bash
# View latest results
ls -la results/*.json

# Compare with baseline
zig build run -- compare baseline.json results.json
```

## Common Patterns

### Error Handling

```zig
pub fn error_handling_example() !void {
    var gpa = std.heap.page_allocator;
    var my_db = try db.Db.open(gpa);
    defer my_db.close();

    var wtxn = try my_db.beginWrite();
    defer wtxn.abort();

    // Handle put errors
    wtxn.put("key", "value") catch |err| switch (err) {
        error.OutOfMemory => return error.CannotStoreData,
        error.KeyTooLong => return error.InvalidKey,
        else => return err,
    };

    // Always check commit result
    const txn_id = wtxn.commit() catch |err| switch (err) {
        error.WriteConflict => return error.ConcurrentModification,
        else => return err,
    };

    std.debug.print("Successfully committed transaction {}\n", .{txn_id});
}
```

### Range Operations

```zig
pub fn range_operations_example() !void {
    var gpa = std.heap.page_allocator;
    var my_db = try db.Db.open(gpa);
    defer my_db.close();

    // Insert range data
    var wtxn = try my_db.beginWrite();
    defer wtxn.abort();

    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (keys) |key| {
        try wtxn.put(key, std.fmt.allocPrint(gpa, "value_{s}", .{key}));
    }
    _ = try wtxn.commit();

    // Read range
    var rtxn = try my_db.beginReadLatest();
    defer rtxn.close();

    var iter = try rtxn.iteratorRange("b", "e");
    defer {}

    std.debug.print("Keys in range [b, e):\n");
    while (try iter.next()) |kv| {
        std.debug.print("  {s}: {s}\n", .{ kv.key, kv.value });
    }
}
```

### Transaction Patterns

```zig
pub fn transaction_patterns_example() !void {
    var gpa = std.heap.page_allocator;
    var my_db = try db.Db.open(gpa);
    defer my_db.close();

    // Read-Your-Writes in a single transaction
    {
        var wtxn = try my_db.beginWrite();
        defer wtxn.abort();

        // Initially doesn't exist
        const initial = wtxn.get("temp");
        std.debug.assert(initial == null);

        // Put and immediately read
        try wtxn.put("temp", "temporary");
        const after_put = wtxn.get("temp");
        std.debug.assert(std.mem.eql(u8, after_put.?, "temporary"));

        // Delete and read again
        try wtxn.del("temp");
        const after_delete = wtxn.get("temp");
        std.debug.assert(after_delete == null);

        _ = try wtxn.commit();
    }

    // Separate transactions
    {
        var wtxn = try my_db.beginWrite();
        try wtxn.put("persistent", "stays");
        _ = try wtxn.commit();
    }

    {
        var rtxn = try my_db.beginReadLatest();
        defer rtxn.close();

        const value = rtxn.get("persistent");
        std.debug.assert(std.mem.eql(u8, value.?, "stays"));
    }
}
```

## Next Steps

### Learn More

- **[AI Development Guide](./ai-development.md)** - Build intelligent database features
- **[Plugin Development](./examples/ai-plugins/)** - Create custom AI plugins
- **[API Reference](../src/db.zig)** - Complete API documentation
- **[Benchmarks](../spec/benchmarks_v0.md)** - Performance specifications

### Examples

- **[Basic KV Operations](./examples/basic-kv/)** - Simple key-value examples
- **[AI Integration](./examples/ai-plugins/)** - Plugin development examples
- **[Intelligent Queries](./examples/intelligent-queries/)** - Natural language queries

### Contributing

See [CONTRIBUTING.md](../README-EXTENDED.md#contributing) for guidelines on contributing to NorthstarDB.

### Troubleshooting

**Build Issues:**
- Ensure Zig 0.15.2+ is installed
- Check that all dependencies are available
- Run `zig build test` to verify installation

**Performance Issues:**
- Run benchmarks to establish baseline
- Check system resources (memory, disk I/O)
- Review benchmark results for bottlenecks

**Transaction Issues:**
- Ensure proper error handling
- Check for write conflicts in concurrent scenarios
- Verify proper cleanup with `defer abort()`

## Support

- **Documentation**: [./README.md](../README.md) and [./README-EXTENDED.md](../README-EXTENDED.md)
- **Issues**: Report on GitHub Issues
- **Discussions**: Join our GitHub Discussions
- **Community**: Connect with other NorthstarDB developers