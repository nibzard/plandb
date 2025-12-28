# AI-Powered Knowledge Base

A semantic knowledge base using NorthstarDB's AI plugin system with structured memory cartridges.

## Overview

This example demonstrates Phase 7 AI Intelligence features: entity extraction, topic-based knowledge organization, relationship tracking, and natural language query processing using LLM function calling.

## Use Cases

- Knowledge graph construction
- Semantic search engines
- Question answering systems
- Document understanding
- Entity-relationship extraction
- Intelligent content recommendation

## Features Demonstrated

- **Entity Extraction**: LLM function calling for automatic entity detection
- **Topic Organization**: Hierarchical knowledge categorization
- **Relationship Mapping**: Explicit and implicit entity connections
- **Natural Language Queries**: Semantic search beyond keyword matching
- **Structured Memory**: Cartridge-based knowledge storage
- **Autonomous Maintenance**: Self-improving knowledge graph

## Running the Example

```bash
cd examples/ai_knowledge_base
zig build run

# Or build manually
zig build-exe main.zig
./ai_knowledge_base

# Note: Full LLM integration requires API keys
# export OPENAI_API_KEY="sk-..."
# export ANTHROPIC_API_KEY="sk-..."
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│              AI-Powered Knowledge Base                       │
├─────────────────────────────────────────────────────────────┤
│  Knowledge Cartridges (Structured Memory):                   │
│  cartridge:entity:<id>         → entity data                │
│  cartridge:topic:<id>          → topic hierarchy            │
│  cartridge:relationship:<id>   → entity connections         │
│                                                               │
│  AI Plugin Hooks:                                            │
│  plugin:extract_entities    → LLM function for extraction   │
│  plugin:query_natural       → NL to structured query        │
│  plugin:suggest_relations   → Find missing connections      │
│                                                               │
│  Index Structures:                                           │
│  idx:entity:name:<name>:<id>  → name lookup                 │
│  idx:topic:members:<id>:<entity_id> → topic membership      │
│  idx:relation:from:<id>:<to_id> → outgoing relations       │
└─────────────────────────────────────────────────────────────┘
```

## Code Walkthrough

### 1. Knowledge Base Initialization

```zig
var kb = KnowledgeBase.init(allocator, &database);
```

The example works without an LLM for demonstration. In production:

```zig
var kb = try KnowledgeBase.initWithAI(allocator, &database, .{
    .llm_provider = .openai,
    .api_key = "sk-...",
    .model = "gpt-4",
});
```

### 2. Adding Entities

```zig
var attrs = std.StringHashMap([]const u8).init(allocator);
try attrs.put("paradigm", "systems programming");
try attrs.put("year_created", "2016");
try attrs.put("creator", "Andrew Kelley");

const zig_id = try kb.addEntity("Zig", .technology, attrs);
```

**What happens:**
1. Generate unique entity ID (name hash)
2. Serialize entity to JSON
3. Store in entity cartridge
4. Create name index for fast lookup
5. Store all attributes as key-value pairs

### 3. Creating Relationships

```zig
try kb.addRelationship("NorthstarDB", "Zig", .written_in);
try kb.addRelationship("NorthstarDB", "MVCC", .uses);
try kb.addRelationship("Zig", "Andrew Kelley", .created_by);
```

**Relationship Types:**
- `is_a`: Taxonomic classification
- `part_of`: Component relationships
- `uses`: Dependency relationships
- `related_to`: General associations
- `written_in`: Programming language
- `created_by`: Creator attribution

### 4. Topic Organization

```zig
// Create topic hierarchy
_ = try kb.createTopic("Programming Languages", null);
_ = try kb.createTopic("Databases", null);
_ = try kb.createTopic("Concepts", null);

// Add entities to topics
try kb.addToTopic("Zig", "Programming Languages");
try kb.addToTopic("NorthstarDB", "Databases");
try kb.addToTopic("MVCC", "Concepts");
```

### 5. Natural Language Queries

```zig
const results = try kb.query("What database is written in Zig?");
```

**Query Process:**
1. Parse query for entity mentions
2. Look up entities in knowledge graph
3. Traverse relationships to find connections
4. Rank results by relevance
5. Return matching entities

## Data Model

### Entity Cartridge

```json
{
  "id": "entity_abc123",
  "name": "NorthstarDB",
  "type": "Technology",
  "attributes": {
    "language": "Zig",
    "paradigm": "embedded database"
  },
  "topics": ["databases", "embedded systems"],
  "created_at": 1704067200,
  "confidence": 0.95
}
```

### Relationship Cartridge

```json
{
  "id": "rel_xyz789",
  "from_entity": "NorthstarDB",
  "to_entity": "Zig",
  "type": "written_in",
  "confidence": 1.0,
  "metadata": {
    "source": "documentation"
  }
}
```

### Topic Cartridge

```json
{
  "id": "topic_db",
  "name": "Databases",
  "parent": null,
  "children": ["embedded_dbs", "distributed_dbs"],
  "entity_count": 42
}
```

## LLM Function Calling

### Entity Extraction Function

The AI uses structured function calling to extract entities:

```json
{
  "name": "extract_entities",
  "description": "Extract entities from text",
  "parameters": {
    "type": "object",
    "properties": {
      "entities": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "name": "string",
            "type": "string",
            "attributes": "object"
          }
        }
      }
    }
  }
}
```

**Example Usage:**

```zig
// With LLM integration
const extracted = try kb.extractEntitiesFromText(
    "NorthstarDB is written in Zig and offers MVCC concurrency."
);
// Returns: [
//   { .name = "NorthstarDB", .type = "Technology", ... },
//   { .name = "Zig", .type = "Technology", ... },
//   { .name = "MVCC", .type = "Concept", ... }
// ]
```

### Query Processing Function

```json
{
  "name": "process_query",
  "description": "Convert natural language to structured query",
  "parameters": {
    "type": "object",
    "properties": {
      "entity_filters": "array",
      "relation_path": "array",
      "constraints": "object"
    }
  }
}
```

**Example Query Translation:**

```
NL: "What databases are written in Zig?"
→ {
    "entity_filters": [
      { "type": "Technology", "name": "Zig" }
    ],
    "relation_path": [
      { "direction": "incoming", "type": "written_in" }
    ]
  }
```

## Query Patterns

### Direct Entity Lookup

```zig
const entity = try kb.getEntity("Zig");
// Returns entity with all attributes and relations
```

### Natural Language Query

```zig
const results = try kb.query("What technologies use Zig?");
// Returns: [NorthstarDB, Bun, Mach, ...]
```

### Relationship Traversal

```zig
const path = try kb.findPath("Zig", "embedded systems");
// Returns: Zig → written_in → NorthstarDB → category_of → embedded systems
```

**Implementation:**

```zig
fn findPath(kb: *KnowledgeBase, from: []const u8, to: []const u8) ![]const []const u8 {
    // BFS through relationship graph
    var queue = std.ArrayList([]const u8).init(allocator);
    var visited = std.StringHashMap(void).init(allocator);

    try queue.append(from);
    try visited.put(from, {});

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        if (std.mem.eql(u8, current, to)) {
            return reconstructPath(from, to);
        }

        const related = try kb.findRelated(current, null);
        for (related.items) |next| {
            if (!visited.contains(next)) {
                try queue.append(next);
                try visited.put(next, {});
            }
        }
    }

    return error.NoPathFound;
}
```

### Topic Exploration

```zig
const members = try kb.getTopicMembers("Databases");
// Returns all entities under Databases topic
```

### Multi-Hop Queries

```zig
// Find technologies created by Andrew Kelley
const creator = try kb.getEntity("Andrew Kelley");
const technologies = try kb.findRelated(creator.name, .created_by);

// Find which ones are related to embedded systems
for (technologies.items) |tech| {
    const related = try kb.findRelated(tech, .related_to);
    for (related.items) |r| {
        if (isInTopic(r, "embedded systems")) {
            std.debug.print("{s} → {s}\n", .{ tech, r });
        }
    }
}
```

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Entity Insert | O(log n) | Plus LLM call (~200ms) |
| Entity Lookup | O(log n) | Direct index access |
| NL Query | O(k log n) | k = candidate entities |
| Relation Find | O(d) | d = graph depth |

### LLM Call Optimization

```zig
// Batch entity extraction
const texts = &[_][]const u8{
    "NorthstarDB is written in Zig...",
    "Bun is a JavaScript runtime...",
    "Mach is a game engine...",
};

const all_entities = try kb.batchExtractEntities(texts);
// Single LLM call instead of 3 separate calls
```

### Caching Strategy

```zig
// Cache extraction results
var extraction_cache = std.StringHashMap([]Entity).init(allocator);

fn getCachedOrExtract(kb: *KnowledgeBase, text: []const u8) ![]Entity {
    const hash = std.hash.Wyhash.hash(0, text);
    const key = try std.fmt.allocPrint(allocator, "{x}", .{hash});

    if (extraction_cache.get(key)) |entities| {
        return entities;
    }

    const entities = try kb.extractEntitiesFromText(text);
    try extraction_cache.put(key, entities);
    return entities;
}
```

## AI Intelligence Features

### Autonomous Maintenance

```zig
// 1. Detect duplicate entities
const duplicates = try kb.findDuplicateEntities();
// Uses string similarity + attribute matching

// 2. Suggest missing relations
const suggestions = try kb.suggestMissingRelations();
// "NorthstarDB → should relate to → B+Tree"

// 3. Propose new topics
const topic_suggestions = try kb.suggestTopics();
// "Consider creating topic: Embedded Databases"

// 4. Flag stale information
const stale = try kb.findStaleEntities();
// "Zig's 'latest_version' is 6 months old"
```

### Learning from Queries

```zig
// Track query patterns
fn recordQuery(kb: *KnowledgeBase, query: []const u8, results: []Entity) !void {
    // Store query analytics
    const query_key = try std.fmt.allocPrint(allocator, "query:analytics:{d}", .{std.time.timestamp()});
    const analytics = try std.fmt.allocPrint(allocator,
        \\{{"query":"{s}","result_count":{d},"entities":[{s}]}}
    , .{ query, results.len, joinEntityIds(results) });

    try kb.database.put(query_key, analytics);
}

// Identify missing knowledge
fn identifyKnowledgeGaps(kb: *KnowledgeBase) ![][]const u8 {
    // Find entities that are queried but don't exist
    var gaps = std.ArrayList([]const u8).init(allocator);

    const failed_queries = try kb.getFailedQueries();
    for (failed_queries.items) |query| {
        const mentioned = try kb.extractMentionedEntities(query);
        for (mentioned) |entity_name| {
            if (try kb.getEntity(entity_name) == null) {
                try gaps.append(entity_name);
            }
        }
    }

    return gaps.toOwnedSlice();
}
```

### Provider Support

#### OpenAI (GPT-4)

```zig
var kb = try KnowledgeBase.initWithAI(allocator, &database, .{
    .llm_provider = .openai,
    .api_key = "sk-...",
    .model = "gpt-4-turbo",
    .api_endpoint = "https://api.openai.com/v1",
});
```

#### Anthropic (Claude)

```zig
var kb = try KnowledgeBase.initWithAI(allocator, &database, .{
    .llm_provider = .anthropic,
    .api_key = "sk-...",
    .model = "claude-3-opus-20240229",
    .api_endpoint = "https://api.anthropic.com/v1",
});
```

#### Local Models (Ollama)

```zig
var kb = try KnowledgeBase.initWithAI(allocator, &database, .{
    .llm_provider = .ollama,
    .model = "mistral:7b",
    .api_endpoint = "http://localhost:11434",
});
```

## Scaling Considerations

### 1. LLM Costs

**Cache Aggressively:**
```zig
// Don't re-extract same text
const cache_key = hash(text);
if (cache.get(cache_key)) |entities| {
    return entities;
}
```

**Batch When Possible:**
```zig
// Single call for multiple texts
const entities = try llm.extractEntities(&.{ text1, text2, text3 });
```

### 2. Graph Partitioning

```zig
// Partition by domain
fn getPartition(entity_name: []const u8) []const u8 {
    if (isTechnology(entity_name)) return "tech";
    if (isPerson(entity_name)) return "people";
    return "general";
}

// Store in separate databases
var tech_db = try db.Db.open(allocator, "knowledge_tech.db");
var people_db = try db.Db.open(allocator, "knowledge_people.db");
```

### 3. Query Latency

```zig
// Parallel entity lookup
var results: []?Entity = undefined;

const threads = try std.Thread.spawnBatch(
    .{},
    lookupEntity,
    kb,
    entity_names,
    .{ .allocator = allocator }
);

// Wait for all lookups to complete
for (threads) |thread| thread.join();
```

## Real-World Usage Example

```zig
// Research assistant for technical documentation

// 1. Ingest documentation
const docs = &[_][]const u8{
    "NorthstarDB is a database written in Zig with MVCC...",
    "B+Tree is a tree data structure used for indexing...",
    "Multi-Version Concurrency Control allows non-blocking reads...",
};

for (docs) |doc| {
    const entities = try kb.extractEntitiesFromText(doc);
    for (entities) |entity| {
        _ = try kb.addEntity(entity.name, entity.type, entity.attributes);
    }
}

// 2. Build relationships automatically
const relationships = try kb.extractRelationshipsFromText(
    "NorthstarDB uses B+Tree for indexing and implements MVCC..."
);
// Extracts: NorthstarDB → uses → B+Tree
//           NorthstarDB → implements → MVCC

for (relationships) |rel| {
    try kb.addRelationship(rel.from, rel.to, rel.type);
}

// 3. Answer questions
const answer = try kb.query("How does NorthstarDB achieve non-blocking reads?");
// Query translation: Find path from "NorthstarDB" to "non-blocking reads"
// Result: NorthstarDB → implements → MVCC → enables → non-blocking reads

// 4. Generate explanations
const explanation = try kb.explainRelationship("NorthstarDB", "MVCC");
// "NorthstarDB implements MVCC (Multi-Version Concurrency Control),
//  which allows multiple readers to access data without blocking writers."
```

## Testing

```zig
test "add and retrieve entity" {
    var kb = KnowledgeBase.init(testing.allocator, &database);

    var attrs = std.StringHashMap([]const u8).init(testing.allocator);
    try attrs.put("language", "Zig");

    const id = try kb.addEntity("NorthstarDB", .technology, attrs);
    const entity = try kb.getEntity("NorthstarDB");

    try testing.expect(entity != null);
    try testing.expectEqualStrings("NorthstarDB", entity.?.name);
}

test "relationship traversal" {
    var kb = KnowledgeBase.init(testing.allocator, &database);

    _ = try kb.addEntity("Zig", .technology, attrs);
    _ = try kb.addEntity("NorthstarDB", .technology, attrs);
    try kb.addRelationship("NorthstarDB", "Zig", .written_in);

    const related = try kb.findRelated("NorthstarDB", null);
    try testing.expect(related.items.len > 0);
}
```

## Next Steps

- **document_repo**: For indexing and search patterns
- **task_queue**: For processing AI workloads
- **basic_kv**: For fundamental data storage

## See Also

- [Structured Memory Cartridges](../../docs/ai_cartridges_v1.md)
- [AI Plugin System](../../docs/ai_plugins_v1.md)
- [LLM Integration Guide](../../docs/guides/llm-integration.md)
