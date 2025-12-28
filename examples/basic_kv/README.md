# Basic Key-Value Store

A simple key-value store demonstrating NorthstarDB's core operations.

## Overview

This example shows how to use NorthstarDB as a straightforward key-value storage system with basic CRUD operations.

## Features

- **Create**: Store key-value pairs
- **Read**: Retrieve values by key
- **Update**: Modify existing values
- **Delete**: Remove keys from storage
- **Pattern Matching**: Query keys by prefix

## Usage

```zig
const std = @import("std");
const db = @import("northstar");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open database
    var database = try db.Db.open(allocator, "kv_store.db");
    defer database.close();

    // Write transaction
    {
        var wtxn = try database.beginWriteTxn();
        defer wtxn.commit();

        try wtxn.put("user:1001:name", "Alice Johnson");
        try wtxn.put("user:1001:email", "alice@example.com");
        try wtxn.put("user:1002:name", "Bob Smith");
        try wtxn.put("user:1002:email", "bob@example.com");
    }

    // Read transaction
    {
        var rtxn = try database.beginReadTxn();
        defer rtxn.commit();

        const name = try rtxn.get("user:1001:name");
        std.debug.print("User name: {s}\n", .{name});
    }
}
```

## Running the Example

```bash
zig build-exe examples/basic_kv/main.zig --deps northstar
./basic_kv
```

## Key Concepts

### Transaction Safety
All operations must happen within a transaction. Write transactions (`WriteTxn`) can modify data, while read transactions (`ReadTxn`) provide consistent snapshots.

### Memory Management
NorthstarDB requires an allocator. Use the General Purpose Allocator for applications, or arena allocators for short-lived operations.

### Key Design
Use colon-separated prefixes for organized data:
- `user:<id>:<field>` - User attributes
- `session:<id>:<prop>` - Session properties
- `cache:<category>:<key>` - Cached values

## Performance Tips

1. **Batch Operations**: Group multiple puts in a single transaction
2. **Prefix Scans**: Use key prefixes for range queries
3. **Connection Pooling**: Reuse database connections
4. **Appropriate Allocators**: Match allocator to workload lifespan
