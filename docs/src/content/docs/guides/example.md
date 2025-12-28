---
title: Examples
description: Complete example projects demonstrating NorthstarDB features
---

Explore these complete, working examples to learn NorthstarDB patterns and best practices. Each example includes full source code, build instructions, and detailed documentation.

## Available Examples

### [Basic Key-Value Store](https://github.com/northstardb/plandb/tree/main/examples/basic_kv)

A simple key-value store demonstrating core NorthstarDB operations.

**Features:**
- Create, Read, Update, Delete (CRUD) operations
- Transaction safety with proper error handling
- Pattern-matching with key prefixes
- Range queries for key scanning

**Use Case:** Learning the basics, simple configuration storage

[View Source](https://github.com/northstardb/plandb/tree/main/examples/basic_kv) | [Run Locally](#running-examples)

---

### [Task Queue System](https://github.com/northstardb/plandb/tree/main/examples/task_queue)

A robust, persistent task queue with worker pools.

**Features:**
- Multiple queue types (email, notifications, processing)
- Priority-based task execution
- Task status tracking (pending → processing → completed/failed)
- Automatic retry logic with exponential backoff
- Atomic statistics tracking

**Use Case:** Background job processing, async workflows

[View Source](https://github.com/northstardb/plandb/tree/main/examples/task_queue) | [Run Locally](#running-examples)

---

### [Document Repository](https://github.com/northstardb/plandb/tree/main/examples/document_repo)

A full-text searchable document storage system with metadata indexing.

**Features:**
- Document storage with auto-generated IDs
- Metadata field indexing for fast queries
- Full-text content search with word tokenization
- Tag-based filtering with boolean logic
- Version history tracking

**Use Case:** Content management, knowledge bases, document archives

[View Source](https://github.com/northstardb/plandb/tree/main/examples/document_repo) | [Run Locally](#running-examples)

---

### [Time-Series Telemetry](https://github.com/northstardb/plandb/tree/main/examples/time_series)

A high-performance time-series database for metrics and monitoring.

**Features:**
- High-frequency metric ingestion
- Efficient time-range queries
- Automatic aggregation (avg, min, max, sum, count)
- Multi-dimensional metrics with tags
- Downsampling and rollup support

**Use Case:** Application monitoring, IoT data, analytics

[View Source](https://github.com/northstardb/plandb/tree/main/examples/time_series) | [Run Locally](#running-examples)

---

### [AI-Powered Knowledge Base](https://github.com/northstardb/plandb/tree/main/examples/ai_knowledge_base)

A semantic knowledge base using AI for entity extraction and relationship mapping.

**Features:**
- Entity extraction using LLM function calling
- Topic-based knowledge organization
- Relationship tracking between entities
- Natural language query processing
- Structured memory cartridges

**Use Case:** Knowledge graphs, semantic search, AI applications

[View Source](https://github.com/northstardb/plandb/tree/main/examples/ai_knowledge_base) | [Run Locally](#running-examples)

---

## Running Examples

### Prerequisites

```bash
# Install Zig (0.11.0 or later)
# Visit: https://ziglang.org/download/
```

### Build and Run

Each example has its own `build.zig` file:

```bash
# Navigate to example directory
cd examples/basic_kv

# Build the example
zig build

# Run the example
zig build run
```

### Interactive Code Runner

Try NorthstarDB directly in your browser with our interactive code runner:

```bash
# Start the documentation site with live examples
cd docs
npm install
npm run dev
```

Visit http://localhost:4321 to see interactive examples running in WebAssembly.

## Example Patterns

### Key Organization

Use colon-separated prefixes for organized data:

```zig
// User data
"user:1001:name" = "Alice"
"user:1001:email" = "alice@example.com"

// Session data
"session:abc123:user_id" = "user_1001"
"session:abc123:created_at" = "1704067200"

// Metrics
"metric:server01:cpu:2024-01-15" = "45.2"
"metric:server01:memory:2024-01-15" = "68.5"
```

### Transaction Safety

Always use proper transaction handling:

```zig
{
    var wtxn = try database.beginWriteTxn();
    errdefer wtxn.rollback();  // Rollback on error

    try wtxn.put("key", "value");

    try wtxn.commit();  // Commit on success
}
```

### Batch Operations

Group multiple operations for efficiency:

```zig
{
    var wtxn = try database.beginWriteTxn();
    errdefer wtxn.rollback();

    // Multiple puts in one transaction
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "batch:{d}", .{i});
        try wtxn.put(key, "value");
    }

    try wtxn.commit();
}
```

## Advanced Topics

### Building Custom Examples

When building your own examples:

1. **Start Simple**: Begin with basic CRUD operations
2. **Add Transactions**: Ensure proper error handling
3. **Design Keys**: Use consistent naming conventions
4. **Test Thoroughly**: Verify edge cases and error paths
5. **Document Well**: Explain key design decisions

### Performance Considerations

- **Batch Writes**: Group operations in transactions
- **Key Design**: Prefixes enable efficient range scans
- **Read Isolation**: Use read transactions for consistency
- **Memory Management**: Choose appropriate allocators

## Contributing Examples

Have an interesting use case? We welcome contributions!

1. Fork the repository
2. Add your example to `examples/`
3. Include README, source code, and build.zig
4. Submit a pull request

See [CONTRIBUTING.md](https://github.com/northstardb/plandb/blob/main/CONTRIBUTING.md) for guidelines.

## Next Steps

- Explore the [API Reference](/reference/db)
- Learn about [CRUD Operations](/guides/crud-operations)
- Understand [Snapshots & Time Travel](/guides/snapshots-time-travel)
- Read about [AI Intelligence Features](/guides/ai-queries)
