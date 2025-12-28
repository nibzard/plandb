# AI-Powered Knowledge Base

A semantic knowledge base using NorthstarDB's AI plugin system with structured memory cartridges.

## Overview

This example demonstrates Phase 7 AI Intelligence features:
- Entity extraction and storage using LLM function calling
- Topic-based knowledge organization
- Relationship tracking between entities
- Natural language query processing
- Autonomous knowledge graph maintenance

## Architecture

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

## Usage

```zig
// Initialize knowledge base with AI plugin
var kb = try KnowledgeBase.init(allocator, &database, .{
    .llm_provider = .openai,
    .api_key = "sk-...",
});

// Ingest text and extract entities
const doc_id = try kb.ingestDocument(
    "NorthstarDB is written in Zig and offers MVCC concurrency."
);
// Automatically extracts: NorthstarDB, Zig, MVCC

// Query naturally
const results = try kb.query("What databases are written in Zig?");

// Get entity details
const entity = try kb.getEntity("NorthstarDB");
// Returns: { .type = "Technology", .topics = {"Databases"} }
```

## Running the Example

```bash
# Set your OpenAI API key
export OPENAI_API_KEY="sk-..."

zig build-exe examples/ai_knowledge_base/main.zig
./ai_knowledge_base
```

## Features

### Entity Extraction
- **Automatic Detection**: LLM function calling extracts entities
- **Type Classification**: Person, Organization, Technology, Concept
- **Attribute Extraction**: Properties and metadata
- **Confidence Scoring**: Track extraction reliability

### Topic Organization
- **Hierarchical Topics**: Multi-level topic taxonomy
- **Auto-Clustering**: Group related entities
- **Topic Evolution**: Topics grow as knowledge grows
- **Cross-References**: Link related topics

### Relationship Mapping
- **Explicit Relations**: is-a, part-of, uses, related-to
- **Implicit Discovery**: AI suggests missing connections
- **Strength Scoring**: Relationship confidence metrics
- **Transitive Queries**: Find indirect connections

### Natural Language Queries
- **Semantic Search**: Find by meaning, not keywords
- **Question Answering**: Extract answers from knowledge
- **Query Translation**: NL → structured query
- **Result Ranking**: Relevance-ordered results

## LLM Function Schema

### Entity Extraction Function
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

## Query Examples

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

### Topic Exploration
```zig
const members = try kb.getTopicMembers("Databases");
// Returns all entities under Databases topic
```

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Entity Insert | O(log n) | Plus LLM call (~200ms) |
| Entity Lookup | O(log n) | Direct index access |
| NL Query | O(k log n) | k = candidate entities |
| Relation Find | O(d) | d = graph depth |

## AI Intelligence Features

### Autonomous Maintenance
- **Merge Candidates**: Detect duplicate entities
- **Missing Relations**: Suggest unstated connections
- **Topic Suggestion**: Propose new topic groupings
- **Stale Detection**: Flag outdated information

### Learning from Queries
- **Query Analytics**: Track common patterns
- **Result Feedback**: Improve relevance scoring
- **Missing Knowledge**: Identify gaps

### Provider Support
- **OpenAI**: GPT-4 for complex reasoning
- **Anthropic**: Claude for nuanced extraction
- **Local Models**: Ollama/LM Studio for privacy

## Scaling Considerations

1. **LLM Costs**: Cache extraction results aggressively
2. **Embedding Costs**: Use function calling, not embeddings
3. **Graph Size**: Consider partitioning by domain
4. **Query Latency**: Batch LLM calls when possible
