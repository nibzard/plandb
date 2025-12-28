# Basic Key-Value Store

A simple yet powerful key-value store demonstrating NorthstarDB's core operations.

## Overview

This example shows how to use NorthstarDB as a straightforward key-value storage system with basic CRUD operations. It's the perfect starting point for understanding NorthstarDB's fundamental APIs and transaction model.

## Use Cases

- Configuration storage and retrieval
- Session management
- User profile caching
- Feature flags and settings
- Simple data persistence without schemas

## Features Demonstrated

- **Create**: Store key-value pairs with automatic persistence
- **Read**: Retrieve values by key with error handling
- **Update**: Modify existing values atomically
- **Delete**: Remove keys from storage
- **Pattern Matching**: Query keys by prefix for range operations
- **Transaction Safety**: ACID guarantees with proper error handling
- **Memory Management**: Proper allocator usage in Zig

## Running the Example

```bash
# From project root
cd examples/basic_kv
zig build run

# Or build and run manually
zig build-exe main.zig --deps northstar
./basic_kv
```

## Code Walkthrough

### 1. Database Initialization

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var database = try db.Db.open(allocator, "kv_store.db");
defer database.close();
```

**Key Points:**
- GeneralPurposeAllocator is appropriate for long-running applications
- The allocator is passed to the database for all memory operations
- `defer` ensures proper cleanup even on error paths
- Database file is created if it doesn't exist

### 2. Write Transactions

```zig
var wtxn = try database.beginWriteTxn();
errdefer wtxn.rollback();

try wtxn.put("user:1001:name", "Alice Johnson");
try wtxn.put("user:1001:email", "alice@example.com");

try wtxn.commit();
```

**Key Points:**
- `beginWriteTxn()` creates a transaction for modifications
- `errdefer wtxn.rollback()` automatically rolls back on error
- Multiple operations can be batched in a single transaction
- Changes are atomic - all succeed or all fail
- `commit()` persists changes to disk

### 3. Read Transactions

```zig
var rtxn = try database.beginReadTxn();
defer rtxn.commit();

const name = try rtxn.get("user:1001:name");
std.debug.print("User name: {s}\n", .{name});
```

**Key Points:**
- Read transactions provide consistent snapshots
- Multiple concurrent readers don't block each other
- `defer rtxn.commit()` releases resources
- Reads don't interfere with write transactions (MVCC)

### 4. Error Handling

```zig
if (rtxn.get("user:1002:email")) |email| {
    std.debug.print("Email: {s}\n", .{email});
} else |err| {
    std.debug.print("Key not found: {}\n", .{err});
}
```

**Key Points:**
- Use `if-else` pattern for optional error handling
- Common errors: `error.KeyNotFound`, `error.CorruptedData`
- Always handle potential errors in production code

### 5. Prefix Scans

```zig
var iter = try rtxn.scan("user:1001:");
defer iter.deinit();

while (try iter.next()) |entry| {
    std.debug.print("  {s} = {s}\n", .{ entry.key, entry.value });
}
```

**Key Points:**
- Scans iterate over all keys matching a prefix
- Useful for retrieving grouped data (e.g., all fields for a user)
- Iterator must be cleaned up with `deinit()`
- Results are returned in key order

## Key Design Patterns

### Hierarchical Key Naming

Use colon-separated prefixes for organized data:

```zig
// User data
user:<id>:<field>           // user:1001:name
user:<id>:settings:<key>    // user:1001:settings:theme

// Session data
session:<id>:<property>     // session:abc123:user_id
session:<id>:expires        // session:abc123:expires

// Cache entries
cache:<category>:<key>      // cache:user_profile:1001
cache:<category>:<key>:ts   // cache:user_profile:1001:ts

// Feature flags
feature:<name>:enabled      // feature:new_ui:enabled
feature:<name>:rollout      // feature:new_ui:rollout
```

**Benefits:**
- Natural hierarchy for related data
- Efficient prefix scans for batch retrieval
- Easy to understand and maintain
- Supports range queries naturally

### Transaction Batching

Group related operations:

```zig
// GOOD: Single transaction
{
    var wtxn = try database.beginWriteTxn();
    defer wtxn.rollback();

    try wtxn.put("user:1001:name", "Alice");
    try wtxn.put("user:1001:email", "alice@example.com");
    try wtxn.put("user:1001:role", "admin");

    try wtxn.commit();
}

// AVOID: Multiple transactions for related data
{
    var wtxn = try database.beginWriteTxn();
    try wtxn.put("user:1001:name", "Alice");
    try wtxn.commit();
}
{
    var wtxn = try database.beginWriteTxn();
    try wtxn.put("user:1001:email", "alice@example.com");
    try wtxn.commit();
}
```

## Performance Tips

### 1. Batch Operations

Group multiple puts in a single transaction:

```zig
// Efficient: One transaction, multiple writes
var wtxn = try database.beginWriteTxn();
for (items) |item| {
    try wtxn.put(item.key, item.value);
}
try wtxn.commit();

// Inefficient: Separate transaction per write
for (items) |item| {
    var wtxn = try database.beginWriteTxn();
    try wtxn.put(item.key, item.value);
    try wtxn.commit();
}
```

### 2. Prefix Scans

Use key prefixes for range queries:

```zig
// Efficient: Single scan for all user fields
var iter = try rtxn.scan("user:1001:");
while (try iter.next()) |entry| {
    // Process each field
}

// Inefficient: Individual gets for each field
const name = try rtxn.get("user:1001:name");
const email = try rtxn.get("user:1001:email");
const role = try rtxn.get("user:1001:role");
```

### 3. Connection Management

Reuse database connections:

```zig
// GOOD: Single long-lived connection
var database = try db.Db.open(allocator, "app.db");
defer database.close();

// Use throughout application lifetime
while (running) {
    var txn = try database.beginWriteTxn();
    // ... operations ...
    try txn.commit();
}

// AVOID: Opening/closing frequently
while (running) {
    var database = try db.Db.open(allocator, "app.db");
    defer database.close();
    // ... operations ...
}
```

### 4. Appropriate Allocators

Match allocator to workload lifespan:

```zig
// Long-lived data: Use GPA
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var database = try db.Db.open(allocator, "app.db");

// Short-lived operations: Use Arena
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const temp_allocator = arena.allocator();

// Use arena for temporary data during transaction
var wtxn = try database.beginWriteTxn();
const temp_data = try temp_allocator.alloc(u8, 1024);
// ... use temp_data ...
try wtxn.commit();
```

## Common Patterns

### Counter Increment

```zig
fn incrementCounter(db: *db.Db, key: []const u8) !u64 {
    var wtxn = try db.beginWriteTxn();
    errdefer wtxn.rollback();

    const current = if (wtxn.get(key)) |val|
        try std.fmt.parseInt(u64, val, 10)
    else
        0;

    const new_val = current + 1;
    const val_str = try std.fmt.allocPrint(allocator, "{d}", .{new_val});
    try wtxn.put(key, val_str);

    try wtxn.commit();
    return new_val;
}
```

### Check-Then-Set (Conditional Update)

```zig
fn setIfNotExists(db: *db.Db, key: []const u8, value: []const u8) !bool {
    var wtxn = try db.beginWriteTxn();
    errdefer wtxn.rollback();

    if (wtxn.get(key)) |_| {
        // Key already exists
        try wtxn.rollback();
        return false;
    }

    try wtxn.put(key, value);
    try wtxn.commit();
    return true;
}
```

### List Operations (Append)

```zig
fn appendToList(db: *db.Db, list_key: []const u8, item: []const u8) !void {
    var wtxn = try db.beginWriteTxn();
    errdefer wtxn.rollback();

    const index_key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{
        list_key, std.time.timestamp()
    });

    try wtxn.put(index_key, item);
    try wtxn.commit();
}
```

## Error Handling Best Practices

### 1. Always Use errdefer

```zig
var wtxn = try database.beginWriteTxn();
errdefer wtxn.rollback();  // Auto rollback on error

try wtxn.put(key, value);
try wtxn.commit();  // Only commit if no errors
```

### 2. Handle Expected Errors

```zig
if (rtxn.get(key)) |value| {
    // Key exists
    processValue(value);
} else |err| switch (err) {
    error.KeyNotFound => {
        // Expected case - handle gracefully
        createDefaultValue();
    },
    else => {
        // Unexpected error - propagate
        return err;
    },
}
```

### 3. Cleanup Resources

```zig
// Always clean up iterators
var iter = try rtxn.scan(prefix);
defer iter.deinit();

while (try iter.next()) |entry| {
    // Process entry
}
```

## Testing Your Implementation

```zig
test "basic CRUD operations" {
    // Setup test database
    var database = try db.Db.open(testing.allocator, ":memory:");

    // Test create
    {
        var wtxn = try database.beginWriteTxn();
        try wtxn.put("test:key", "test:value");
        try wtxn.commit();
    }

    // Test read
    {
        var rtxn = try database.beginReadTxn();
        const value = try rtxn.get("test:key");
        try testing.expectEqualStrings("test:value", value);
    }

    // Test update
    {
        var wtxn = try database.beginWriteTxn();
        try wtxn.put("test:key", "new:value");
        try wtxn.commit();
    }

    // Test delete
    {
        var wtxn = try database.beginWriteTxn();
        try wtxn.delete("test:key");
        try wtxn.commit();
    }
}
```

## Troubleshooting

### Common Issues

1. **"Key not found" errors**
   - Ensure key exists before reading
   - Use proper error handling with `if-else`

2. **Memory leaks**
   - Always `defer` cleanup operations
   - Deinitialize iterators with `deinit()`

3. **Slow performance**
   - Batch operations in transactions
   - Use prefix scans instead of multiple gets
   - Profile with Zig's built-in profiling tools

4. **Corrupted database**
   - Always use proper transaction boundaries
   - Never skip error handling
   - Use `errdefer` for automatic cleanup

## Next Steps

- Explore the **task_queue** example for more complex transaction patterns
- See **document_repo** for indexing strategies
- Check **time_series** for high-volume write patterns
- Read **ai_knowledge_base** for advanced data modeling

## See Also

- [NorthstarDB Transaction Semantics](../../docs/semantics_v0.md)
- [B+Tree Implementation Details](../../src/btree.zig)
- [MVCC Concurrency Control](../../docs/guides/mvcc.md)
