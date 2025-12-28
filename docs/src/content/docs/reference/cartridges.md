---
title: Cartridges API
description: Structured memory cartridges for entities, topics, relationships, and semantic search in NorthstarDB.
---

import { Card, Cards } from '@astrojs/starlight/components';

Cartridges are **read-optimized, materialized views** built from the commit log. They provide fast access patterns for specific query types without scanning the entire database. Each cartridge type is optimized for a different access pattern.

## Overview

<Cards>
  <Card title="PendingTasksCartridge" icon="list">
    Fast task queue operations grouped by type. O(1) task lookups and type filtering.
  </Card>
  <Card title="EntityIndexCartridge" icon="database">
    Entity storage with attributes and metadata. Filter by entity type and attributes.
  </Card>
  <Card title="TopicCartridge" icon="tags">
    Inverted term index for topic-based search. Trie-based term lookup with posting lists.
  </Card>
  <Card title="RelationshipCartridge" icon="git-branch">
    Entity relationship graph with BFS/DFS traversal and path finding.
  </Card>
  <Card title="EmbeddingsCartridge" icon="cpu">
    Semantic vector search with HNSW index. Multiple distance metrics and quantization options.
  </Card>
  <Card title="Deterministic Build" icon="refresh-cw">
    Rebuild from commit log produces identical cartridge. Enables incremental updates and invalidation.
  </Card>
</Cards>

## Cartridge Lifecycle

### Building from Commit Log

All cartridges are built deterministically from the commit log:

```zig
const cartridges = @import("northstar/cartridges");

// Build from WAL log file
var cartridge = try cartridges.PendingTasksCartridge.buildFromLog(
    allocator,
    "data.wal",  // Path to commit log
);
defer cartridge.deinit();

// Cartridge now contains all pending tasks
const task_count = cartridge.getTaskCount("processing");
std.log.info("Built cartridge with {d} processing tasks", .{task_count});
```

**Build characteristics:**
- **Deterministic** - Same log → identical cartridge (byte-for-byte)
- **Offline** - No database lock required during build
- **Incremental** - Rebuild only new transactions since last build
- **Parallel** - Multiple cartridges can be built concurrently

---

### Opening Existing Cartridges

Load a previously built cartridge from disk:

```zig
// Open existing cartridge file
var cartridge = try cartridges.PendingTasksCartridge.open(
    allocator,
    "pending_tasks.cartridge",
);
defer cartridge.deinit();

// Cartridge is ready for queries
const tasks = try cartridge.getTasksByType("upload");
defer {
    for (tasks) |*t| t.deinit(allocator);
    allocator.free(tasks);
}
```

**File format:**
- Header with magic, version, type, checksum
- Index section for fast lookups
- Data section with compressed/quantized entries
- Metadata with build time, source transaction ID, invalidation policy

---

### Writing to Disk

Serialize cartridge to file for later use:

```zig
var cartridge = try cartridges.PendingTasksCartridge.init(allocator, 0);
defer cartridge.deinit();

// Add tasks...
const task = cartridges.TaskEntry{
    .key = "task:001",
    .task_type = "processing",
    .priority = 10,
    .claimed = false,
    .claimed_by = null,
    .claim_time = null,
};
try cartridge.addTask(task);

// Write to file
try cartridge.writeToFile("pending_tasks.cartridge");
```

**Output file structure:**
- **Header** (64 bytes): Magic, version, type, offsets, checksum
- **Index** (varies): Type/task mappings for O(1) lookups
- **Data** (varies): Actual task entries with optional compression
- **Metadata** (varies): Build info, schema version, invalidation policy

---

### Invalidation and Rebuild

Cartridges include **invalidation policies** that trigger automatic rebuilds:

```zig
const format = @import("northstar/cartridges/format");

// Check if rebuild is needed
const current_txn_id = my_db.last_txn_id;
if (cartridge.needsRebuild(current_txn_id)) {
    std.log.info("Cartridge needs rebuild", .{});

    // Rebuild from latest log
    var new_cartridge = try cartridges.PendingTasksCartridge.buildFromLog(
        allocator,
        "data.wal",
    );
    defer new_cartridge.deinit();

    try new_cartridge.writeToFile("pending_tasks.cartridge");
}
```

**Invalidation triggers:**
- **Transaction count** - Rebuild after N new transactions
- **Time-based** - Rebuild after age threshold (e.g., 1 hour)
- **Pattern-based** - Rebuild when specific keys are mutated
- **Manual** - Explicit rebuild requested by application

**Rebuild strategies:**
- **Full rebuild** - Rebuild entire cartridge from scratch
- **Incremental rebuild** - Only process new transactions since last build
- **Background rebuild** - Build new cartridge while serving queries from old one

---

## PendingTasksCartridge

Fast task queue operations with type-based grouping.

### Initialization

```zig
const cartridges = @import("northstar/cartridges");

// Create new cartridge
var cartridge = try cartridges.PendingTasksCartridge.init(
    allocator,
    source_txn_id,  // Last transaction ID in source database
);
defer cartridge.deinit();
```

---

### Adding Tasks

```zig
const task = cartridges.TaskEntry{
    .key = "task:001",
    .task_type = "processing",
    .priority = 10,  // Lower = higher priority
    .claimed = false,
    .claimed_by = null,
    .claim_time = null,
};
try cartridge.addTask(task);
```

**Task metadata:**
- **Priority** - Lower value = higher priority (0-255)
- **Type** - Arbitrary string for grouping ("upload", "processing", etc.)
- **Claim state** - Track which agent is working on the task

---

### Querying Tasks

```zig
// Get all tasks of a specific type
const tasks = try cartridge.getTasksByType("processing");
defer {
    for (tasks) |*t| t.deinit(allocator);
    allocator.free(tasks);
}

for (tasks) |task| {
    std.log.info("Task: {s} (priority: {d})", .{ task.key, task.priority });
}

// Get task count without loading
const count = cartridge.getTaskCount("processing");
std.log.info("Processing tasks: {d}", .{count});

// Get specific task by key
const task = try cartridge.getTask("task:001");
if (task) |*t| {
    defer t.deinit(allocator);
    std.log.info("Found task: {s}", .{t.key});
}
```

---

### Claiming Tasks

```zig
// Claim a task (transient, not persisted to cartridge)
const claimed = try cartridge.claimTask("task:001", "agent-42");
if (claimed) |*task| {
    defer task.deinit(allocator);

    std.log.info("Claimed task: {s}", .{task.key});
    std.log.info("Claimed by: {s}", .{task.claimed_by.?});

    // For persistent claims, write to database
    // and rebuild cartridge
}
```

**Claim semantics:**
- **Transient** - Claim exists only in memory
- **Persistent** - Write `claim:TASK_ID:AGENT_ID` to database
- **Exclusive** - One agent per task at a time
- **Timeout** - Claims can expire based on `claim_time`

---

### Use Cases

| Use Case | Description |
|----------|-------------|
| **Job queues** | Distribute work across multiple agents |
| **Task scheduling** | Prioritize and track background jobs |
| **Agent coordination** | Coordinate AI agents working on tasks |
| **Workflow engines** | Track multi-step processing pipelines |

---

## EntityIndexCartridge

Store and query entities with attributes.

### Entity Structure

```zig
const cartridges = @import("northstar/cartridges");

// Entity ID with namespace
const entity_id = cartridges.EntityId{
    .namespace = "file",
    .local_id = "src/main.zig",
};

// Create entity
var entity = try cartridges.Entity.init(
    allocator,
    entity_id,
    .file,  // EntityType
    "system",  // created_by
    txn_id,  // Transaction timestamp
);
defer entity.deinit(allocator);

// Add attributes
const size_attr = cartridges.Attribute{
    .key = "size",
    .value = .{ .integer = 1024 },
    .confidence = 1.0,
    .source = "stat",
};
try entity.addAttribute(allocator, size_attr);

const lang_attr = cartridges.Attribute{
    .key = "language",
    .value = .{ .string = "zig" },
    .confidence = 0.95,
    .source = "extension",
};
try entity.addAttribute(allocator, lang_attr);
```

**Entity types:**
- `file` - Source code files, documents
- `person` - People, users, contacts
- `function` - Functions, methods, procedures
- `commit` - Version control commits
- `topic` - Categories, tags, topics
- `project` - Projects, repositories
- `custom` - User-defined types

**Attribute value types:**
- `string` - Text values
- `integer` - Signed 64-bit integers
- `float` - 64-bit floating point
- `boolean` - True/false
- `string_array` - List of strings
- `integer_array` - List of integers

---

### Building Entity Cartridge

```zig
var cartridge = try cartridges.EntityIndexCartridge.init(
    allocator,
    source_txn_id,
);
defer cartridge.deinit();

// Add entities
try cartridge.addEntity(entity);

// Write to disk
try cartridge.writeToFile("entities.cartridge");
```

---

### Querying Entities

```zig
// Open existing cartridge
var cartridge = try cartridges.EntityIndexCartridge.open(
    allocator,
    "entities.cartridge",
);
defer cartridge.deinit();

// Get entity by ID
const entity_id = cartridges.EntityId{
    .namespace = "file",
    .local_id = "src/main.zig",
};
if (try cartridge.getEntity(entity_id)) |*entity| {
    const size_attr = entity.getAttribute("size");
    if (size_attr) |*attr| {
        std.log.info("File size: {d}", .{attr.value.integer});
    }
}
```

---

## TopicCartridge

Inverted term index for topic-based search.

### Building Topic Index

```zig
const cartridges = @import("northstar/cartridges");

var cartridge = try cartridges.TopicCartridge.init(
    allocator,
    source_txn_id,
);
defer cartridge.deinit();

// Index entity terms
const entity_id = cartridges.EntityId{
    .namespace = "file",
    .local_id = "src/main.zig",
};
const terms = [_][]const u8{ "zig", "database", "btree", "performance" };
try cartridge.addEntityTerms(entity_id, &terms, txn_id);

// Write to disk
try cartridge.writeToFile("topics.cartridge");
```

**Indexing behavior:**
- Each term creates an entry in a trie
- Posting lists track which entities contain each term
- Term frequency and document frequency calculated automatically
- Supports prefix search via trie traversal

---

### Searching by Topic

```zig
// Open cartridge
var cartridge = try cartridges.TopicCartridge.open(
    allocator,
    "topics.cartridge",
);
defer cartridge.deinit();

// Search for entities matching terms
const query_terms = [_][]const u8{ "zig", "database" };
var results = try cartridge.searchByTopic(&query_terms, 10);
defer {
    for (results.items) |*r| {
        allocator.free(r.entity_id.namespace);
        allocator.free(r.entity_id.local_id);
    }
    results.deinit(allocator);
}

// Results are sorted by relevance (TF-IDF)
for (results.items) |result| {
    std.log.info("{s}:{s} (score: {d:.2})", .{
        result.entity_id.namespace,
        result.entity_id.local_id,
        result.score,
    });
}
```

**Relevance scoring:**
- **Term frequency** - How often term appears in entity
- **Document frequency** - How many entities contain term
- **TF-IDF** - Term frequency × inverse document frequency
- **Multi-term queries** - Scores summed across all query terms

---

### Term Statistics

```zig
// Get statistics for a specific term
if (cartridge.getTermStats("database")) |*stats| {
    std.log.info("Term: {s}", .{stats.term});
    std.log.info("Document frequency: {d}", .{stats.document_frequency});
    std.log.info("Total frequency: {d}", .{stats.total_frequency});
    std.log.info("IDF: {d:.4}", .{stats.idf});
}
```

**Uses for term stats:**
- Identify important/rare terms
- Filter by term popularity
- Analyze vocabulary distribution
- Optimize indexing strategy

---

## RelationshipCartridge

Store and query entity relationships with graph traversal.

### Building Relationship Graph

```zig
const cartridges = @import("northstar/cartridges");

var cartridge = try cartridges.RelationshipCartridge.init(
    allocator,
    source_txn_id,
);
defer cartridge.deinit();

// Create relationship
const from_id = cartridges.EntityId{
    .namespace = "file",
    .local_id = "main.zig",
};
const to_id = cartridges.EntityId{
    .namespace = "file",
    .local_id = "utils.zig",
};

var rel = try cartridges.Relationship.init(
    allocator,
    from_id,
    to_id,
    .imports,  // RelationshipType
    0.8,  // Strength/confidence
    txn_id,
);
defer rel.deinit(allocator);

// Add metadata
const line_attr = cartridges.Attribute{
    .key = "line_count",
    .value = .{ .integer = 5 },
    .confidence = 1.0,
    .source = "static_analysis",
};
try rel.addMetadata(allocator, line_attr);

// Add to graph
try cartridge.addRelationship(rel);
```

**Relationship types:**
- **Code**: `imports`, `calls`, `implements`, `extends`, `depends_on`, `modifies`
- **People**: `authored_by`, `reviewed_by`, `assigned_to`, `mentioned`
- **Semantic**: `related_to`, `similar_to`, `part_of`, `references`
- **Custom**: User-defined relationship types

---

### Traversing Relationships

```zig
// Open cartridge
var cartridge = try cartridges.RelationshipCartridge.open(
    allocator,
    "relationships.cartridge",
);
defer cartridge.deinit();

const start_id = cartridges.EntityId{
    .namespace = "file",
    .local_id = "main.zig",
};

// BFS traversal
var paths = try cartridge.bfs(
    start_id,
    3,  // max_depth
    .imports,  // filter_type (null = all types)
);
defer {
    for (paths.items) |*p| p.deinit(allocator);
    paths.deinit(allocator);
}

for (paths.items) |*path| {
    std.log.info("Path (strength: {d:.2}):", .{path.total_strength});
    for (path.elements.items) |*elem| {
        std.log.info("  -> {s}:{s} ({s})", .{
            elem.entity_id.namespace,
            elem.entity_id.local_id,
            @tagName(elem.relationship_type),
        });
    }
}
```

**Traversal options:**
- **BFS** - Breadth-first search (shortest path)
- **DFS** - Depth-first search (exhaustive)
- **Filtered** - Only traverse specific relationship types
- **Depth limit** - Limit traversal depth

---

### Path Finding

```zig
const from_id = cartridges.EntityId{
    .namespace = "file",
    .local_id = "a.zig",
};
const to_id = cartridges.EntityId{
    .namespace = "file",
    .local_id = "c.zig",
};

// Find shortest path
const path = try cartridge.findShortestPath(from_id, to_id);
if (path) |*p| {
    defer p.deinit(allocator);

    std.log.info("Shortest path ({d} hops):", .{p.elements.items.len});
    for (p.elements.items) |*elem| {
        std.log.info("  {s} -> {s}", .{
            @tagName(elem.relationship_type),
            elem.entity_id.local_id,
        });
    }
}
```

**Path finding features:**
- **Shortest path** - BFS for minimum hop count
- **All paths** - Find all paths up to max depth
- **Strength weighted** - Consider relationship strength
- **Cycle detection** - Avoid infinite loops

---

### Neighbor Queries

```zig
// Get entities within N hops
var neighbors = try cartridge.getNeighbors(
    start_id,
    2,  // max_hops
    .imports,  // filter_type
);
defer {
    for (neighbors.items) |*n| {
        allocator.free(n.namespace);
        allocator.free(n.local_id);
    }
    neighbors.deinit(allocator);
}

for (neighbors.items) |neighbor| {
    std.log.info("Neighbor: {s}:{s}", .{
        neighbor.namespace,
        neighbor.local_id,
    });
}
```

---

## EmbeddingsCartridge

Semantic vector search with HNSW (Hierarchical Navigable Small World) index.

### Creating Embedding Cartridge

```zig
const cartridges = @import("northstar/cartridges");

// Initialize with vector dimensionality and quantization
var cartridge = try cartridges.EmbeddingsCartridge.init(
    allocator,
    source_txn_id,
    384,  // dimensions (e.g., all-MiniLM-L6-v2)
    .fp32,  // QuantizationType (fp32, fp16, int8)
);
defer cartridge.deinit();
```

**Dimensionality:**
- **384d** - Small models (all-MiniLM-L6-v2)
- **768d** - Medium models (text-embedding-3-small)
- **1536d** - Large models (text-embedding-ada-002)

**Quantization:**
- **FP32** - Full precision (4 bytes/dimension)
- **FP16** - Half precision (2 bytes/dimension)
- **INT8** - 8-bit quantization (1 byte/dimension)

---

### Adding Embeddings

```zig
const vector = [_]f32{0.1, 0.2, 0.3, ...}; // 384 dimensions

const embedding = cartridges.Embedding{
    .id = "emb_001",
    .data = &([_]u8{0} ** 1536),  // Quantized data
    .dimensions = 384,
    .quantization = .fp32,
    .entity_namespace = "file",
    .entity_local_id = "src/main.zig",
    .model_name = "all-MiniLM-L6-v2",
    .created_at = std.time.nanoTimestamp(),
    .confidence = 0.95,
};

try cartridge.addEmbedding(embedding, &vector);
```

---

### Semantic Search

```zig
const query_vector = [_]f32{ 0.15, 0.25, 0.35, ... }; // 384d

// Search for k nearest neighbors
var results = try cartridge.search(&query_vector, 10);
defer {
    for (results.items) |*r| r.deinit(allocator);
    results.deinit(allocator);
}

for (results.items) |result| {
    std.log.info("{s}:{s} - distance: {d:.4}", .{
        result.entity_namespace,
        result.entity_local_id,
        result.score,
    });
}
```

**Search options:**

```zig
// Advanced search with options
const opts = cartridges.SearchOptions{
    .k = 10,  // Number of results
    .ef_search = 50,  // Search width (higher = better recall)
    .metric = .cosine,  // Distance metric
    .max_distance = 0.3,  // Exclude results beyond threshold
};

var results = try cartridge.searchWithOptions(&query_vector, opts);
defer {
    for (results.items) |*r| r.deinit(allocator);
    results.deinit(allocator);
}
```

**Distance metrics:**
- **Euclidean** - L2 distance (default)
- **Cosine** - 1 - cosine similarity
- **Dot product** - Negated for min-heap ranking

---

### HNSW Index Behavior

The HNSW (Hierarchical Navigable Small World) index provides:
- **O(log N)** search complexity
- **Approximate nearest neighbor** - Sub-millisecond queries
- **Dynamic updates** - Insert/delete without full rebuild
- **Tunable recall** - Balance speed vs accuracy with `ef_search`

**Maintenance:**

```zig
// Periodic maintenance after many inserts/deletes
try cartridge.index.maintain();

// Compact index (removes deleted nodes)
try cartridge.index.compact();
```

---

## Cartridge Format Specification

### File Structure

```
+-------------------+
| Header (64 bytes) |
+-------------------+
| Index Section     |
| - Type mappings   |
| - Offsets         |
| - Checksums       |
+-------------------+
| Data Section      |
| - Entries         |
| - Compressed      |
| - Quantized       |
+-------------------+
| Metadata Section  |
| - Build info      |
| - Schema version  |
| - Invalidations   |
+-------------------+
```

---

### Header Format

```zig
const CartridgeHeader = struct {
    magic: u32 = 0x4E434152,  // "NCAR"
    version: Version = .{ .major = 1, .minor = 0, .patch = 0 },
    flags: FeatureFlags,
    cartridge_type: CartridgeType,
    created_at: u64,
    source_txn_id: u64,
    entry_count: u64,
    index_offset: u64,
    data_offset: u64,
    metadata_offset: u64,
    checksum: u32,
};
```

---

### Invalidation Policy

```zig
const InvalidationPolicy = struct {
    max_age_seconds: u64,  // Rebuild after age
    min_new_txns: u64,     // Minimum txns for incremental
    max_new_txns: u64,     // Maximum txns for full rebuild
    patterns: []InvalidationPattern,  // Key patterns to watch
};
```

**Example policy:**

```zig
var policy = cartridges.InvalidationPolicy.init(allocator);
policy.max_age_seconds = 3600;  // 1 hour
policy.min_new_txns = 10;  // Incremental after 10 txns
policy.max_new_txns = 1000;  // Full rebuild after 1000

// Add pattern for task invalidation
try policy.addPattern(allocator, .{
    .key_prefix = "task:",
    .check_mutation_type = true,
    .mutation_type = .put,
});
```

---

## Reference Summary

| Cartridge | Use Case | Query Type |
|-----------|----------|------------|
| **PendingTasksCartridge** | Task queues | By type, by key, claim operations |
| **EntityIndexCartridge** | Entity storage | By ID, by type, attribute filters |
| **TopicCartridge** | Topic search | By term, prefix search, TF-IDF |
| **RelationshipCartridge** | Graph queries | BFS/DFS, path finding, neighbors |
| **EmbeddingsCartridge** | Semantic search | ANN, k-NN, distance metrics |

| Method | Description |
|--------|-------------|
| `buildFromLog(allocator, log_path)` | Build cartridge from commit log |
| `open(allocator, path)` | Open existing cartridge file |
| `writeToFile(path)` | Serialize cartridge to disk |
| `needsRebuild(current_txn_id)` | Check if rebuild needed |
| `deinit()` | Free cartridge resources |

See also:
- [Cartridge Format Spec](../../specs/cartridge-format-v1.md) - On-disk format details
- [Structured Memory Spec](../../specs/structured-memory-v1.md) - Entity, topic, relationship schemas
- [Db API](./db.md) - Database operations that generate commit logs
