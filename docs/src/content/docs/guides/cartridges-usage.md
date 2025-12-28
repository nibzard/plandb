---
title: Cartridges Usage Guide
description: Learn when and how to use cartridges for optimized queries and structured memory in NorthstarDB.
---

import { Card, Cards } from '@astrojs/starlight/components';

Cartridges are **read-optimized, materialized views** built from your database's commit log. They provide fast access patterns for specific query types without scanning the entire database. This guide shows you when and how to use them effectively.

<Cards>
  <Card title="Performance" icon="zap">
    10-100x faster than full database scans for common queries.
  </Card>
  <Card title="Offline" icon="clock">
    Build without blocking database operations.
  </Card>
  <Card title="Deterministic" icon="refresh-cw">
    Same log always produces identical cartridge.
  </Card>
</Cards>

## When to Use Cartridges

### Use Cartridges When:

✅ **You need fast, repeated queries**
- Frequent lookups of the same data
- Dashboard queries aggregating data
- Search operations on large datasets

✅ **You can tolerate slight staleness**
- Analytics on recent but not real-time data
- Batch processing where minutes-old data is acceptable
- Reporting and audit queries

✅ **Your queries have predictable patterns**
- Always filtering by entity type
- Always searching by topic/term
- Always traversing relationships

### Don't Use Cartridges When:

❌ **You need absolute real-time data**
- Use direct database queries instead

❌ **Your data changes very frequently**
- Cartridge rebuild overhead may not be worth it

❌ **Your query patterns are unpredictable**
- Ad-hoc queries on random keys
- Direct database scans may be faster

## Quick Start

### Building Your First Cartridge

Let's build a simple task queue cartridge from database commits:

```zig
const std = @import("std");
const cartridges = @import("northstar/cartridges");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build cartridge from commit log
    var cartridge = try cartridges.PendingTasksCartridge.buildFromLog(
        allocator,
        "data.log",  // Commit log from your database
    );
    defer cartridge.deinit();

    // Query tasks by type
    const upload_tasks = try cartridge.getTasksByType("upload");
    defer {
        for (upload_tasks) |*t| t.deinit(allocator);
        allocator.free(upload_tasks);
    }

    std.debug.print("Found {} upload tasks\n", .{upload_tasks.len});
}
```

### Writing to Disk

```zig
// Build and save for later use
var cartridge = try cartridges.PendingTasksCartridge.buildFromLog(
    allocator,
    "data.log",
);
defer cartridge.deinit();

// Write to disk
try cartridge.writeToFile("tasks.cartridge");

// Later, open it instantly
var cached = try cartridges.PendingTasksCartridge.open(
    allocator,
    "tasks.cartridge",
);
defer cached.deinit();

// Queries are now instantaneous
const count = cached.getTaskCount("processing");
std.debug.print("Processing tasks: {}\n", .{count});
```

---

## Task Queue Cartridge

The **PendingTasksCartridge** is perfect for coordinating work across multiple agents or workers.

### Use Case: Job Processing System

```zig
const cartridges = @import("northstar/cartridges");

/// Build task queue from database
fn buildJobQueue(allocator: std.mem.Allocator, db_log_path: []const u8) !void {
    var cartridge = try cartridges.PendingTasksCartridge.buildFromLog(
        allocator,
        db_log_path,
    );
    defer cartridge.deinit();

    // Save for workers
    try cartridge.writeToFile("job_queue.cartridge");
}

/// Worker claims next available job
fn claimNextJob(
    allocator: std.mem.Allocator,
    worker_id: []const u8
) !?cartridges.TaskEntry {
    // Open cached cartridge
    var cartridge = try cartridges.PendingTasksCartridge.open(
        allocator,
        "job_queue.cartridge",
    );
    defer cartridge.deinit();

    // Get pending jobs (not claimed)
    const all_jobs = try cartridge.getTasksByType("process");
    defer {
        for (all_jobs) |*j| j.deinit(allocator);
        allocator.free(all_jobs);
    }

    for (all_jobs) |job| {
        if (!job.claimed) {
            // Claim this job (transient, not persisted to cartridge)
            const claimed = try cartridge.claimTask(job.key, worker_id);
            if (claimed) |*c| {
                // Copy task data before cartridge closes
                return try copyTask(allocator, c);
            }
        }
    }

    return null;
}

/// Complete a job and trigger rebuild
fn completeJob(
    allocator: std.mem.Allocator,
    db: *db.Db,
    job_key: []const u8,
    worker_id: []const u8
) !void {
    // Mark job complete in database
    var w = try db.beginWrite();
    defer w.abort();

    var complete_key_buf: [128]u8 = undefined;
    const complete_key = try std.fmt.bufPrint(
        &complete_key_buf,
        "completed:{s}",
        .{job_key}
    );
    try w.put(complete_key, worker_id);

    _ = try w.commit();

    // Rebuild cartridge (can be done in background)
    var cartridge = try cartridges.PendingTasksCartridge.buildFromLog(
        allocator,
        "data.log",
    );
    defer cartridge.deinit();

    try cartridge.writeToFile("job_queue.cartridge");
}
```

### Best Practices for Task Queues

1. **Batch rebuilds** - Don't rebuild after every job completion
2. **Background updates** - Rebuild in separate thread while serving from old cartridge
3. **Multiple types** - Use task types for prioritization (e.g., "urgent", "normal", "low")

---

## Entity Index Cartridge

The **EntityIndexCartridge** is ideal for storing and querying structured entities with attributes.

### Use Case: Code Intelligence

```zig
const cartridges = @import("northstar/cartridges");

/// Build entity index from code analysis
fn buildCodeIndex(
    allocator: std.mem.Allocator,
    source_files: []const []const u8
) !void {
    var cartridge = try cartridges.EntityIndexCartridge.init(
        allocator,
        0,  // Start with empty cartridge
    );
    defer cartridge.deinit();

    // Index each source file
    for (source_files) |file_path| {
        // Create file entity
        const entity_id = cartridges.EntityId{
            .namespace = "file",
            .local_id = file_path,
        };

        var entity = try cartridges.Entity.init(
            allocator,
            entity_id,
            .file,
            "static_analysis",
            std.time.nanoTimestamp(),
        );
        defer entity.deinit(allocator);

        // Add file attributes
        try entity.addAttribute(allocator, .{
            .key = "language",
            .value = .{ .string = "zig" },
            .confidence = 1.0,
            .source = "extension",
        });

        try entity.addAttribute(allocator, .{
            .key = "line_count",
            .value = .{ .integer = 150 },
            .confidence = 1.0,
            .source = "count",
        });

        try cartridge.addEntity(entity);
    }

    try cartridge.writeToFile("code_index.cartridge");
}

/// Query entities by attributes
fn findLargeFiles(allocator: std.mem.Allocator) !void {
    var cartridge = try cartridges.EntityIndexCartridge.open(
        allocator,
        "code_index.cartridge",
    );
    defer cartridge.deinit();

    // Get all file entities
    const files = try cartridge.getEntitiesByType(.file);
    defer {
        for (files) |*e| e.deinit(allocator);
        allocator.free(files);
    }

    // Filter by attribute
    for (files) |entity| {
        if (entity.getAttribute("line_count")) |*attr| {
            if (attr.value == .integer and attr.value.integer > 1000) {
                std.debug.print("Large file: {s} ({} lines)\n", .{
                    entity.id.local_id,
                    attr.value.integer,
                });
            }
        }
    }
}
```

### Best Practices for Entity Index

1. **Normalize attributes** - Use consistent attribute keys and types
2. **Confidence scores** - Track data quality with confidence values
3. **Source tracking** - Always attribute data to its source

---

## Topic Search Cartridge

The **TopicCartridge** provides inverted index search with TF-IDF relevance scoring.

### Use Case: Document Search

```zig
const cartridges = @import("northstar/cartridges");

/// Build search index from documents
fn buildDocumentSearch(
    allocator: std.mem.Allocator,
    docs: []const struct { []const u8, []const u8 }  // (id, content)
) !void {
    var cartridge = try cartridges.TopicCartridge.init(
        allocator,
        0,
    );
    defer cartridge.deinit();

    // Index each document
    for (docs) |doc| {
        const entity_id = cartridges.EntityId{
            .namespace = "doc",
            .local_id = doc[0],
        };

        // Extract terms (simplified - use proper tokenizer in production)
        var terms = std.ArrayList([]const u8).init(allocator);
        defer {
            for (terms.items) |t| allocator.free(t);
            terms.deinit();
        }

        var it = std.mem.splitScalar(u8, doc[1], ' ');
        while (it.next()) |term| {
            if (term.len > 2) {  // Skip short terms
                try terms.append(try allocator.dupe(u8, term));
            }
        }

        try cartridge.addEntityTerms(
            entity_id,
            terms.items,
            std.time.nanoTimestamp(),
        );
    }

    try cartridge.writeToFile("doc_search.cartridge");
}

/// Search for relevant documents
fn searchDocuments(
    allocator: std.mem.Allocator,
    query: []const u8
) !void {
    var cartridge = try cartridges.TopicCartridge.open(
        allocator,
        "doc_search.cartridge",
    );
    defer cartridge.deinit();

    // Parse query into terms
    var terms = std.ArrayList([]const u8).init(allocator);
    defer {
        for (terms.items) |t| allocator.free(t);
        terms.deinit();
    }

    var it = std.mem.splitScalar(u8, query, ' ');
    while (it.next()) |term| {
        if (term.len > 2) {
            try terms.append(try allocator.dupe(u8, term));
        }
    }

    // Search
    var results = try cartridge.searchByTopic(terms.items, 10);
    defer {
        for (results.items) |*r| {
            allocator.free(r.entity_id.namespace);
            allocator.free(r.entity_id.local_id);
        }
        results.deinit(allocator);
    }

    std.debug.print("Results for '{s}':\n", .{query});
    for (results.items) |result| {
        std.debug.print("  {s}: {s}:{s} (score: {.2})\n", .{
            @tagName(result.entity_type),
            result.entity_id.namespace,
            result.entity_id.local_id,
            result.score,
        });
    }
}
```

### Best Practices for Topic Search

1. **Tokenize properly** - Use proper tokenization (lowercase, stem, remove stop words)
2. **Term frequency** - Track how often terms appear
3. **Document frequency** - Track how many documents contain each term
4. **Relevance tuning** - Adjust TF-IDF weights for your domain

---

## Relationship Graph Cartridge

The **RelationshipCartridge** stores entity relationships and enables graph traversal queries.

### Use Case: Dependency Analysis

```zig
const cartridges = @import("northstar/cartridges");

/// Build dependency graph from imports
fn buildDependencyGraph(
    allocator: std.mem.Allocator,
    imports: []const struct { []const u8, []const u8 }  // (from, to)
) !void {
    var cartridge = try cartridges.RelationshipCartridge.init(
        allocator,
        0,
    );
    defer cartridge.deinit();

    // Index import relationships
    for (imports) |imp| {
        const from_id = cartridges.EntityId{
            .namespace = "file",
            .local_id = imp[0],
        };
        const to_id = cartridges.EntityId{
            .namespace = "file",
            .local_id = imp[1],
        };

        var rel = try cartridges.Relationship.init(
            allocator,
            from_id,
            to_id,
            .imports,
            1.0,  // Strength
            std.time.nanoTimestamp(),
        );
        defer rel.deinit(allocator);

        try cartridge.addRelationship(rel);
    }

    try cartridge.writeToFile("deps.cartridge");
}

/// Find all files that transitively import a given file
fn findDependents(
    allocator: std.mem.Allocator,
    file_path: []const u8
) !void {
    var cartridge = try cartridges.RelationshipCartridge.open(
        allocator,
        "deps.cartridge",
    );
    defer cartridge.deinit();

    const start_id = cartridges.EntityId{
        .namespace = "file",
        .local_id = file_path,
    };

    // Find reverse dependencies
    // Note: Need to reverse edges first or add reverse traversal support
    var paths = try cartridge.bfs(start_id, 3, null);
    defer {
        for (paths.items) |*p| p.deinit(allocator);
        paths.deinit(allocator);
    }

    std.debug.print("Files reachable from {s}:\n", .{file_path});
    for (paths.items) |*path| {
        for (path.elements.items) |*elem| {
            std.debug.print("  -> {s}\n", .{elem.entity_id.local_id});
        }
    }
}

/// Find shortest path between two files
fn findImportPath(
    allocator: std.mem.Allocator,
    from: []const u8,
    to: []const u8
) !void {
    var cartridge = try cartridges.RelationshipCartridge.open(
        allocator,
        "deps.cartridge",
    );
    defer cartridge.deinit();

    const from_id = cartridges.EntityId{
        .namespace = "file",
        .local_id = from,
    };
    const to_id = cartridges.EntityId{
        .namespace = "file",
        .local_id = to,
    };

    if (try cartridge.findShortestPath(from_id, to_id)) |*path| {
        defer path.deinit(allocator);

        std.debug.print("Shortest path ({d} hops):\n", .{path.elements.items.len});
        for (path.elements.items) |*elem| {
            std.debug.print("  {s} -> {s}\n", .{
                @tagName(elem.relationship_type),
                elem.entity_id.local_id,
            });
        }
    } else {
        std.debug.print("No path found\n", .{});
    }
}
```

### Best Practices for Relationship Graph

1. **Index both directions** - For reverse queries, add reverse edges
2. **Strength scores** - Use confidence/weight for relationship strength
3. **Cycle detection** - Ensure graph algorithms handle cycles
4. **Depth limits** - Limit traversal depth to prevent runaway queries

---

## Embeddings / Semantic Search Cartridge

The **EmbeddingsCartridge** provides semantic similarity search using vector embeddings.

### Use Case: Semantic Code Search

```zig
const cartridges = @import("northstar/cartridges");

/// Build semantic search index
fn buildSemanticIndex(
    allocator: std.mem.Allocator,
    code_snippets: []const struct { []const u8, []const f32 }  // (id, embedding)
) !void {
    // Initialize with 384 dimensions (all-MiniLM-L6-v2)
    var cartridge = try cartridges.EmbeddingsCartridge.init(
        allocator,
        0,
        384,
        .fp32,
    );
    defer cartridge.deinit();

    // Index embeddings
    for (code_snippets) |snippet| {
        const embedding = cartridges.Embedding{
            .id = snippet[0],
            .data = &([_]u8{0} ** 1536),  // Will be filled from embedding
            .dimensions = 384,
            .quantization = .fp32,
            .entity_namespace = "code",
            .entity_local_id = snippet[0],
            .model_name = "all-MiniLM-L6-v2",
            .created_at = std.time.nanoTimestamp(),
            .confidence = 0.95,
        };

        try cartridge.addEmbedding(embedding, snippet[1]);
    }

    try cartridge.writeToFile("semantic.cartridge");
}

/// Search by semantic similarity
fn semanticSearch(
    allocator: std.mem.Allocator,
    query_embedding: []const f32
) !void {
    var cartridge = try cartridges.EmbeddingsCartridge.open(
        allocator,
        "semantic.cartridge",
    );
    defer cartridge.deinit();

    // Search for top 10 similar
    var results = try cartridge.search(query_embedding, 10);
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    std.debug.print("Semantically similar code:\n", .{});
    for (results.items) |result| {
        std.debug.print("  {s}:{s} (similarity: {.4})\n", .{
            result.entity_namespace,
            result.entity_local_id,
            1.0 - result.score,  // Convert distance to similarity
        });
    }
}
```

### Best Practices for Embeddings

1. **Dimensionality** - Match embedding model dimensionality
2. **Quantization** - Use INT8 for large indices to save memory
3. **Distance metrics** - Cosine for text, Euclidean for general
4. **Batch updates** - Rebuild index after adding many embeddings

---

## Cartridge Invalidation

### When to Rebuild

Cartridges should be rebuilt when:

- **Time-based** - After a configured age (e.g., 1 hour)
- **Transaction count** - After N new transactions
- **Pattern-based** - When specific keys are modified
- **Manual** - When explicitly requested

### Checking Rebuild Need

```zig
fn maybeRebuildCartridge(
    allocator: std.mem.Allocator,
    cartridge_path: []const u8,
    db_txn_id: u64
) !bool {
    // Open existing cartridge
    var cartridge = try cartridges.PendingTasksCartridge.open(
        allocator,
        cartridge_path,
    );
    defer cartridge.deinit();

    // Check if rebuild needed
    if (cartridge.needsRebuild(db_txn_id)) {
        std.log.info("Cartridge needs rebuild", .{});

        // Rebuild
        var new_cartridge = try cartridges.PendingTasksCartridge.buildFromLog(
            allocator,
            "data.log",
        );
        defer new_cartridge.deinit();

        try new_cartridge.writeToFile(cartridge_path);
        return true;
    }

    return false;
}
```

### Invalidation Policies

```zig
/// Create custom invalidation policy
fn createPolicy(allocator: std.mem.Allocator) !cartridges.InvalidationPolicy {
    var policy = try cartridges.InvalidationPolicy.init(allocator);

    // Rebuild after 1 hour
    policy.max_age_seconds = 3600;

    // Incremental rebuild after 10 txns
    policy.min_new_txns = 10;

    // Full rebuild after 1000 txns
    policy.max_new_txns = 1000;

    // Rebuild when tasks are modified
    try policy.addPattern(allocator, .{
        .key_prefix = "task:",
        .check_mutation_type = true,
        .mutation_type = .put,
    });

    return policy;
}
```

---

## Advanced: Building Custom Cartridges

### Defining Your Cartridge Type

```zig
const cartridges = @import("northstar/cartridges");

/// Custom cartridge for analytics
pub const AnalyticsCartridge = struct {
    allocator: std.mem.Allocator,
    source_txn_id: u64,
    metrics: std.StringHashMap(MetricData),
    // ... your fields

    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64) !@This() {
        return @This(){
            .allocator = allocator,
            .source_txn_id = source_txn_id,
            .metrics = std.StringHashMap(MetricData).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        var it = self.metrics.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.metrics.deinit();
    }

    /// Process mutations from commit log
    pub fn processMutation(self: *@This(), mutation: cartridges.Mutation) !void {
        switch (mutation) {
            .put => |put_op| {
                // Extract metrics from key/value
                // Update internal indices
            },
            .delete => |del_op| {
                // Remove from indices
            },
        }
    }

    pub fn writeToFile(self: *@This(), path: []const u8) !void {
        // Serialize to your custom format
        // Follow cartridge file format spec
    }

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !@This() {
        // Deserialize from file
    }
};
```

---

## Performance Tips

### 1. Batch Rebuilds

```zig
// Bad: Rebuild after every transaction
// Good: Rebuild after N transactions
const REBUILD_THRESHOLD = 100;
var txn_count: u64 = 0;

// After each write
txn_count += 1;
if (txn_count >= REBUILD_THRESHOLD) {
    try rebuildCartridge();
    txn_count = 0;
}
```

### 2. Background Rebuilds

```zig
// Build in background while serving from old cartridge
var old_cartridge = try openCartridge("cache.cartridge");
defer old_cartridge.deinit();

// Build new cartridge in thread
try std.Thread.spawn(
    struct {
        fn build(allocator: std.mem.Allocator) !void {
            var new_cartridge = try buildFromLog(allocator);
            defer new_cartridge.deinit();
            try new_cartridge.writeToFile("cache_new.cartridge");

            // Atomic rename
            std.fs.cwd().rename("cache_new.cartridge", "cache.cartridge") catch {};
        }
    }.build,
    allocator,
);
```

### 3. Memory Mapping

For large cartridges, consider memory-mapped files:

```zig
// mmap the cartridge for zero-copy loading
const file = try std.fs.cwd().openFile("large.cartridge", .{});
const size = try file.getEndPos();
const mapped = try std.os.mmap(
    null,
    size,
    std.os.PROT.READ,
    std.os.MAP.PRIVATE,
    file.handle,
    0,
);
defer std.os.munmap(mapped);
```

---

## Complete Example: Real-Time Analytics

Here's a complete example showing a real-time analytics pipeline:

```zig
const std = @import("std");
const db = @import("northstar");
const cartridges = @import("northstar/cartridges");

/// Real-time analytics system
pub const AnalyticsSystem = struct {
    allocator: std.mem.Allocator,
    database: *db.Db,
    task_cartridge: cartridges.PendingTasksCartridge,
    entity_cartridge: cartridges.EntityIndexCartridge,

    pub fn init(
        allocator: std.mem.Allocator,
        database: *db.Db
    ) !@This() {
        // Build or open cartridges
        var task_cart = cartridges.PendingTasksCartridge.buildFromLog(
            allocator,
            "data.log",
        ) catch |err| switch (err) {
            error.FileNotFound => try cartridges.PendingTasksCartridge.init(allocator, 0),
            else => return err,
        };

        var entity_cart = try cartridges.EntityIndexCartridge.init(
            allocator,
            0,
        );

        return @This(){
            .allocator = allocator,
            .database = database,
            .task_cartridge = task_cart,
            .entity_cartridge = entity_cart,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.task_cartridge.deinit();
        self.entity_cartridge.deinit();
    }

    /// Process new mutations
    pub fn processMutations(self: *@This()) !void {
        // Get recent transactions
        const from_txn = self.task_cartridge.source_txn_id;
        const to_txn = self.database.getLastTxnId();

        // Rebuild task cartridge
        self.task_cartridge.deinit();
        self.task_cartridge = try cartridges.PendingTasksCartridge.buildFromLog(
            self.allocator,
            "data.log",
        );
    }

    /// Query analytics
    pub fn getAnalytics(self: *@This()) !AnalyticsReport {
        return AnalyticsReport{
            .pending_tasks = self.task_cartridge.getTaskCount("process"),
            .total_entities = self.entity_cartridge.getEntityCount(.file),
        };
    }
};

pub const AnalyticsReport = struct {
    pending_tasks: u64,
    total_entities: u64,
};
```

## Next Steps

- [CRUD Operations](./crud-operations.md) - Basic database operations
- [Snapshots & Time Travel](./snapshots-time-travel.md) - Historical queries
- [Cartridges API](../reference/cartridges.md) - Complete API reference
- [Performance Tuning](./performance-tuning.md) - Optimize cartridge performance
