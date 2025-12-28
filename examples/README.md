# NorthstarDB Examples

This directory contains complete, working example projects demonstrating NorthstarDB features and best practices.

## Available Examples

### [Basic KV Store](./basic_kv/)
A simple key-value store demonstrating core NorthstarDB operations.
- **Features:** CRUD operations, transactions, range queries
- **Use Case:** Learning basics, configuration storage
- **Complexity:** Beginner
- [Read More](./basic_kv/README.md)

### [Task Queue System](./task_queue/)
A robust, persistent task queue with worker pool simulation.
- **Features:** Multi-queue support, task status tracking, retry logic
- **Use Case:** Background job processing, async workflows
- **Complexity:** Intermediate
- [Read More](./task_queue/README.md)

### [Document Repository](./document_repo/)
A full-text searchable document storage system.
- **Features:** Metadata indexing, full-text search, tag filtering
- **Use Case:** Content management, knowledge bases
- **Complexity:** Intermediate
- [Read More](./document_repo/README.md)

### [Time-Series Telemetry](./time_series/)
A high-performance time-series database for metrics.
- **Features:** Efficient time-range queries, aggregation, downsampling
- **Use Case:** Application monitoring, IoT, analytics
- **Complexity:** Intermediate
- [Read More](./time_series/README.md)

### [AI-Powered Knowledge Base](./ai_knowledge_base/)
A semantic knowledge base using AI for entity extraction.
- **Features:** Entity extraction, relationship mapping, NL queries
- **Use Case:** Knowledge graphs, semantic search, AI applications
- **Complexity:** Advanced
- [Read More](./ai_knowledge_base/README.md)

## Quick Start

Each example is self-contained with its own build system:

```bash
# Navigate to an example directory
cd examples/basic_kv

# Build the example
zig build

# Run the example
zig build run
```

## Prerequisites

- Zig 0.11.0 or later ([Install Zig](https://ziglang.org/download/))
- For AI examples: OpenAI or Anthropic API key

## Example Patterns

### Key Organization
Use colon-separated prefixes for organized data:
```zig
"user:1001:name" = "Alice"
"user:1001:email" = "alice@example.com"
"session:abc123:user_id" = "user_1001"
```

### Transaction Safety
Always use proper transaction handling:
```zig
{
    var wtxn = try database.beginWriteTxn();
    errdefer wtxn.rollback();

    try wtxn.put("key", "value");

    try wtxn.commit();
}
```

## Contributing Examples

We welcome community contributions! When adding a new example:

1. **Follow the structure:** README.md, main.zig, build.zig
2. **Document thoroughly:** Explain the use case and key concepts
3. **Test well:** Include error handling and edge cases
4. **Keep it simple:** Focus on one clear concept per example

See [CONTRIBUTING.md](../CONTRIBUTING.md) for contribution guidelines.

## Additional Resources

- [Documentation](https://northstardb.dev)
- [API Reference](https://northstardb.dev/reference/db)
- [Development Guide](../docs/src/content/docs/guides)
