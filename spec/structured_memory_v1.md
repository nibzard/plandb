# Structured Memory v1 Specification

**Version**: 1.0
**Date**: 2025-12-22
**Status**: Draft

## Overview

This specification defines the Structured Memory Cartridge format for NorthstarDB's Living Database intelligence layer. Structured Memory Cartridges store AI-extracted entities, topics, and relationships in a queryable format that enables semantic understanding without the storage overhead of vector embeddings.

## Design Principles

1. **Deterministic Storage**: Structured data vs opaque embeddings for predictable queries
2. **Storage Efficiency**: Inverted indices with back-pointers vs 4K vectors per message
3. **Query Performance**: Sub-millisecond lookups for millions of entities
4. **Incremental Updates**: Efficient real-time updates from commit stream
5. **Version Control**: Full history with time travel capabilities

## Architecture

### Data Flow

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Commit Stream │───▶│  AI Function     │───▶│  Structured      │
│   (Mutations)    │    │  Calling Engine  │    │  Memory Cartridge│
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                                       │
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Natural       │◄───│  Query Planner   │◄───│  Entity/Topic    │
│   Language      │    │  + Router        │    │  Indices        │
│   Queries        │    │                  │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

### Cartridge Types

1. **Entity Cartridge**: Structured entities with attributes and metadata
2. **Topic Cartridge**: Inverted index of terms with back-pointers to entities
3. **Relationship Cartridge**: Graph of entity relationships with traversal capabilities
4. **Semantic Index Cartridge**: Combined entity-topic-relationship queries

## Entity Cartridge Format

### Storage Layout

```
Entity Cartridge Header (32 bytes)
├── Magic Number (4 bytes): "ENT" + version
├── Entity Count (8 bytes)
├── Index Offset (8 bytes)
├── Data Offset (8 bytes)
└── Checksum (4 bytes)

Entity Index Section
├── Entity ID → Offset Mapping (Hash Index)
├── Type Index (B-tree by entity type)
├── Attribute Index (Multi-key index)
└── Temporal Index (B-tree by creation/modification time)

Entity Data Section
├── Entity Records (variable length)
├── Attribute Blocks (variable length)
└── Free Space Management
```

### Entity Record Structure

```zig
const EntityRecord = struct {
    header: EntityHeader,
    id: EntityId,
    type: EntityType,
    attributes: AttributeBlock,
    relationships: RelationshipBlock,
    temporal: TemporalData,

    const EntityHeader = struct {
        version: u8,
        flags: u8,
        attribute_count: u16,
        relationship_count: u16,
        record_size: u32,
        checksum: u32,
    };

    const EntityId = struct {
        namespace: []const u8,  // e.g., "file", "person", "function"
        local_id: []const u8,   // e.g., "main.rs", "niko", "putBtreeValue"
    };

    const EntityType = enum {
        file,
        person,
        function,
        commit,
        topic,
        project,
        custom,
    };

    const AttributeBlock = struct {
        attributes: []Attribute,

        const Attribute = struct {
            key: []const u8,
            value: AttributeValue,
            confidence: f32,
            source: []const u8,  // Which LLM/plugin extracted this
            timestamp: i64,
        };

        const AttributeValue = union {
            string: []const u8,
            integer: i64,
            float: f64,
            boolean: bool,
            array: []AttributeValue,
            object: HashMap([]const u8, AttributeValue),
        };
    };

    const TemporalData = struct {
        created_at: u64,      // txn_id when entity was first seen
        last_modified: u64,   // txn_id of last modification
        created_by: []const u8, // source plugin or operation
        ttl: ?u64,           // optional time-to-live
    };
};
```

### Entity Operations

```zig
// Entity lookup by ID
pub fn get_entity(cartridge: *EntityCartridge, id: EntityId) ?*EntityRecord {
    const offset = cartridge.entity_index.get(id) orelse return null;
    return cartridge.read_entity_at(offset);
}

// Entity query by type and attributes
pub fn query_entities(
    cartridge: *EntityCartridge,
    entity_type: EntityType,
    filters: []AttributeFilter
) EntityIterator {
    // Use type index + attribute filters for efficient query
    const type_range = cartridge.type_index.get_range(entity_type);
    return EntityIterator.init(cartridge, type_range, filters);
}

// Entity update (creates new version)
pub fn update_entity(
    cartridge: *EntityCartridge,
    id: EntityId,
    updates: []Attribute,
    txn_id: u64
) !void {
    // Create new entity record with updated attributes
    const new_record = try cartridge.create_entity_version(id, updates, txn_id);

    // Update indexes
    try cartridge.entity_index.put(id, new_record.offset);
    try cartridge.temporal_index.insert(.{
        .entity_id = id,
        .txn_id = txn_id,
        .operation = .update,
    });
}
```

## Topic Cartridge Format

### Inverted Index Structure

```
Topic Cartridge Header (32 bytes)
├── Magic Number (4 bytes): "TOP" + version
├── Term Count (8 bytes)
├── Posting Count (8 bytes)
├── Index Offset (8 bytes)
└── Checksum (4 bytes)

Term Index Section
├── Term Dictionary (Trie structure)
├── Posting List Offsets (Array)
└── Statistical Data (TF-IDF, etc.)

Posting Lists Section
├── Entity Postings (Entity ID + frequency)
├── Document Postings (Transaction ID + relevance)
└── Temporal Postings (Time decay information)
```

### Topic Record Structure

```zig
const TopicCartridge = struct {
    term_index: TermDictionary,
    posting_lists: PostingListStorage,
    statistics: TopicStatistics,

    const TermDictionary = struct {
        root: TrieNode,
        total_terms: u32,
        total_postings: u64,

        const TrieNode = struct {
            character: u8,
            children: [256]?*TrieNode,
            term_data: ?TermData,
            frequency: u32,
        };

        const TermData = struct {
            term: []const u8,
            posting_offset: u64,
            document_frequency: u32,
            total_frequency: u64,
            last_updated: u64,
        };
    };

    const PostingList = struct {
        postings: []Posting,
        compressed: bool,

        const Posting = struct {
            target_id: TargetId,    // Entity ID or Transaction ID
            frequency: u16,
            positions: []u32,      // Word positions within text
            relevance_score: f32,
            timestamp: u64,
        };

        const TargetId = union {
            entity: EntityId,
            transaction: u64,
        };
    };

    const TopicStatistics = struct {
        total_documents: u64,
        average_document_length: f32,
        vocabulary_size: u32,
        compression_ratio: f32,
    };
};
```

### Topic Operations

```zig
// Add term postings for an entity
pub fn add_entity_terms(
    cartridge: *TopicCartridge,
    entity_id: EntityId,
    terms: []TermFrequency,
    txn_id: u64
) !void {
    for (terms) |term_freq| {
        const term_data = try cartridge.term_index.get_or_create(term_freq.term);

        // Add posting to posting list
        const posting = Posting{
            .target_id = .{ .entity = entity_id },
            .frequency = term_freq.frequency,
            .positions = term_freq.positions,
            .relevance_score = calculate_relevance(term_freq),
            .timestamp = txn_id,
        };

        try cartridge.add_posting(term_data.posting_offset, posting);
    }
}

// Topic-based entity search
pub fn search_entities_by_topic(
    cartridge: *TopicCartridge,
    query: TopicQuery,
    limit: usize
) []SearchResult {
    // Parse query: "performance AND (btree OR pager)"
    const query_plan = cartridge.build_query_plan(query);

    // Execute query using posting lists
    var results = ArrayList(SearchResult).init(cartridge.allocator);
    var iterator = QueryIterator.init(cartridge, query_plan);

    while (iterator.next()) |result| {
        try results.append(result);
        if (results.items.len >= limit) break;
    }

    return results.toOwnedSlice();
}

const TopicQuery = struct {
    terms: []QueryTerm,
    operators: []QueryOperator,
    filters: []QueryFilter,

    const QueryTerm = struct {
        term: []const u8,
        boost: f32 = 1.0,
        fuzzy: bool = false,
    };

    const QueryOperator = enum {
        and,
        or,
        not,
        near,
    };
};
```

## Relationship Cartridge Format

### Graph Structure

```
Relationship Cartridge Header (32 bytes)
├── Magic Number (4 bytes): "REL" + version
├── Node Count (8 bytes)
├── Edge Count (8 bytes)
├── Index Offset (8 bytes)
└── Checksum (4 bytes)

Node Storage Section
├── Node Records (Variable length)
├── Node Index (Hash table)
└── Node Type Index (B-tree)

Edge Storage Section
├── Edge Records (Variable length)
├── Edge Index (Adjacency lists)
├── Type Index (Relationship type B-tree)
└── Weight Index (Edge weight B-tree)

Graph Indexes Section
├── Path Cache (Commonly traversed paths)
├── Centrality Index (Node importance scores)
└── Temporal Index (Time-based relationship queries)
```

### Relationship Structure

```zig
const RelationshipCartridge = struct {
    nodes: NodeStorage,
    edges: EdgeStorage,
    indexes: GraphIndexes,

    const Node = struct {
        id: EntityId,
        type: NodeType,
        attributes: AttributeBlock,
        adjacency_list: []EdgeId,
        metadata: NodeMetadata,

        const NodeType = enum {
            entity,
            topic,
            concept,
            event,
            temporal_anchor,
        };

        const NodeMetadata = struct {
            created_at: u64,
            last_accessed: u64,
            access_count: u64,
            centrality_score: f32,
        };
    };

    const Edge = struct {
        id: EdgeId,
        source: EntityId,
        target: EntityId,
        type: RelationshipType,
        weight: f32,
        attributes: AttributeBlock,
        temporal: TemporalData,

        const EdgeId = struct {
            source_hash: u64,
            target_hash: u64,
            type_hash: u64,
        };

        const RelationshipType = enum {
            // Structural relationships
            contains,
            part_of,
            depends_on,
            implements,

            // Temporal relationships
            created_before,
            modified_after,
            causally_related,

            // Semantic relationships
            similar_to,
            related_to,
            exemplifies,

            // Custom relationships
            custom,
        };

        const TemporalData = struct {
            created_at: u64,
            valid_from: u64,
            valid_to: ?u64,
            confidence_decay: f32,
        };
    };

    const GraphIndexes = struct {
        adjacency_index: AdjacencyIndex,
        type_index: TypeIndex,
        weight_index: WeightIndex,
        path_cache: PathCache,

        const AdjacencyIndex = struct {
            outgoing: HashMap(EntityId, []EdgeId),
            incoming: HashMap(EntityId, []EdgeId),
            bidirectional: HashMap(EntityId, []EdgeId),
        };

        const PathCache = struct {
            cache: LRUCache(PathKey, PathResult),
            hit_rate: f32,
            max_paths: usize,

            const PathKey = struct {
                source: EntityId,
                target: EntityId,
                max_depth: u8,
                constraints: PathConstraints,
            };
        };
    };
};
```

### Relationship Operations

```zig
// Add relationship between entities
pub fn add_relationship(
    cartridge: *RelationshipCartridge,
    source: EntityId,
    target: EntityId,
    relationship_type: RelationshipType,
    weight: f32,
    txn_id: u64
) !void {
    const edge_id = EdgeId{
        .source_hash = hash_entity_id(source),
        .target_hash = hash_entity_id(target),
        .type_hash = @intCast(u64, @enumToInt(relationship_type)),
    };

    const edge = Edge{
        .id = edge_id,
        .source = source,
        .target = target,
        .type = relationship_type,
        .weight = weight,
        .temporal = .{
            .created_at = txn_id,
            .valid_from = txn_id,
            .valid_to = null,
            .confidence_decay = 1.0,
        },
    };

    try cartridge.edges.add_edge(edge);
    try cartridge.indexes.update_adjacency_indexes(edge);
}

// Graph traversal for relationship queries
pub fn traverse_relationships(
    cartridge: *RelationshipCartridge,
    start_entity: EntityId,
    path_spec: PathSpecification
) GraphIterator {
    return GraphIterator.init(cartridge, start_entity, path_spec);
}

const PathSpecification = struct {
    max_depth: u8,
    allowed_types: []RelationshipType,
    weight_constraints: WeightConstraints,
    temporal_constraints: TemporalConstraints,

    const WeightConstraints = struct {
        min_weight: f32 = 0.0,
        max_weight: f32 = 1.0,
        prefer_higher_weight: bool = true,
    };

    const TemporalConstraints = struct {
        valid_at: u64,
        created_after: ?u64 = null,
        created_before: ?u64 = null,
    };
};

// Find related entities
pub fn find_related_entities(
    cartridge: *RelationshipCartridge,
    entity: EntityId,
    relationship_types: []RelationshipType,
    max_results: usize
) []RelatedEntity {
    var results = ArrayList(RelatedEntity).init(cartridge.allocator);

    for (relationship_types) |rel_type| {
        const outgoing = cartridge.indexes.adjacency_index.outgoing.get(entity) orelse continue;

        for (outgoing) |edge_id| {
            const edge = cartridge.edges.get_edge(edge_id) orelse continue;
            if (edge.type != rel_type) continue;

            const related = RelatedEntity{
                .entity = edge.target,
                .relationship = edge.type,
                .weight = edge.weight,
                .path_length = 1,
            };

            try results.append(related);
            if (results.items.len >= max_results) break;
        }
    }

    // Sort by weight and relevance
    sort_related_entities(results.items);
    return results.toOwnedSlice();
}
```

## Semantic Index Cartridge

### Unified Query Interface

```zig
const SemanticIndexCartridge = struct {
    entity_cartridge: *EntityCartridge,
    topic_cartridge: *TopicCartridge,
    relationship_cartridge: *RelationshipCartridge,
    query_planner: QueryPlanner,

    // Unified semantic queries
    pub fn semantic_search(
        cartridge: *SemanticIndexCartridge,
        query: SemanticQuery,
        options: QueryOptions
    []SemanticResult {
        const query_plan = cartridge.query_planner.plan_query(query);

        var results = ArrayList(SemanticResult).init(cartridge.allocator);

        // Execute across all cartridge types
        if (query_plan.entity_queries) |entity_queries| {
            for (entity_queries) |entity_query| {
                const entity_results = cartridge.entity_cartridge.query_entities(
                    entity_query.type,
                    entity_query.filters
                );

                for (entity_results) |entity| {
                    try results.append(.{
                        .type = .entity,
                        .entity = entity,
                        .relevance_score = calculate_entity_relevance(entity, query),
                    });
                }
            }
        }

        if (query_plan.topic_queries) |topic_queries| {
            for (topic_queries) |topic_query| {
                const topic_results = cartridge.topic_cartridge.search_entities_by_topic(
                    topic_query,
                    options.max_results
                );

                for (topic_results) |topic_result| {
                    try results.append(.{
                        .type = .topic_match,
                        .entity = topic_result.entity,
                        .relevance_score = topic_result.score,
                        .matched_terms = topic_result.terms,
                    });
                }
            }
        }

        if (query_plan.relationship_queries) |rel_queries| {
            for (rel_queries) |rel_query| {
                const rel_results = cartridge.relationship_cartridge.traverse_relationships(
                    rel_query.start_entity,
                    rel_query.path_spec
                );

                for (rel_results) |rel_result| {
                    try results.append(.{
                        .type = .relationship_path,
                        .entity = rel_result.target_entity,
                        .relevance_score = rel_result.path_score,
                        .relationship_path = rel_result.path,
                    });
                }
            }
        }

        // Sort by relevance and apply limit
        sort_by_relevance(results.items);
        return results.items[0..@min(results.items.len, options.max_results)];
    }

    const SemanticQuery = struct {
        natural_language: []const u8,
        intent: QueryIntent,
        entities: []EntityFilter,
        topics: []TopicFilter,
        relationships: []RelationshipFilter,
        temporal_constraints: TemporalConstraints,
    };

    const SemanticResult = struct {
        type: ResultType,
        entity: *EntityRecord,
        relevance_score: f32,
        explanation: []const u8,
        matched_terms: ?[][]const u8,
        relationship_path: ?[]Relationship,
    };
};
```

## Performance Characteristics

### Storage Efficiency

- **Entity Storage**: ~100 bytes per entity (vs 4K for vector embeddings)
- **Topic Index**: ~10% of raw text size (vs 100% for vector storage)
- **Relationship Graph**: ~50 bytes per edge
- **Compression**: LZ4 compression achieves 3-5x reduction on typical data

### Query Performance

- **Entity Lookup**: <1ms for 1M entities (hash index)
- **Topic Search**: <10ms for complex boolean queries
- **Relationship Traversal**: <100ms for 3-hop paths
- **Semantic Queries**: <50ms for multi-cartridge queries

### Update Performance

- **Entity Creation**: <5ms per entity
- **Topic Index Update**: <1ms per term
- **Relationship Addition**: <2ms per edge
- **Batch Processing**: 1000+ entities/second with batching

## Versioning and Time Travel

### Temporal Indexing

All cartridge types support temporal querying:

```zig
// Query entities as of specific transaction
pub fn get_entities_as_of(
    cartridge: *EntityCartridge,
    txn_id: u64,
    entity_filter: EntityFilter
) []EntityRecord {
    return cartridge.temporal_index.query_as_of(txn_id, entity_filter);
}

// Get relationship evolution over time
pub fn get_relationship_evolution(
    cartridge: *RelationshipCartridge,
    entity_id: EntityId,
    time_range: TimeRange
) []RelationshipSnapshot {
    return cartridge.indexes.temporal_index.get_evolution(entity_id, time_range);
}
```

### Incremental Updates

```zig
const UpdateBatch = struct {
    operations: []UpdateOperation,
    base_txn_id: u64,
    target_txn_id: u64,

    const UpdateOperation = union {
        create_entity: CreateEntityOp,
        update_entity: UpdateEntityOp,
        delete_entity: DeleteEntityOp,
        add_relationship: AddRelationshipOp,
        remove_relationship: RemoveRelationshipOp,
    };
};

// Apply batch of updates to all cartridges
pub fn apply_update_batch(
    cartridges: *CartridgeSet,
    batch: UpdateBatch
) !void {
    // Apply in transactional manner
    const transaction = try cartridges.begin_transaction();
    defer transaction.rollback() catch {};

    for (batch.operations) |operation| {
        try transaction.apply_operation(operation);
    }

    try transaction.commit(batch.target_txn_id);
}
```

## Testing and Validation

### Correctness Validation

```zig
// Validate cartridge consistency
pub fn validate_cartridge_integrity(cartridge: *EntityCartridge) !ValidationReport {
    var report = ValidationReport.init();

    // Check entity index consistency
    for (cartridge.entity_index.entries()) |entry| {
        const entity = cartridge.read_entity_at(entry.offset) orelse {
            report.add_error(.missing_entity, .{ .entity_id = entry.id });
            continue;
        };

        if (!entity.id.eql(entry.id)) {
            report.add_error(.entity_id_mismatch, .{ .expected = entry.id, .actual = entity.id });
        }
    }

    // Validate attribute indexes
    try cartridge.validate_attribute_indexes(&report);

    // Validate temporal consistency
    try cartridge.validate_temporal_consistency(&report);

    return report;
}
```

### Performance Benchmarks

```zig
// Standardized benchmark suite for structured memory
const StructuredMemoryBenchmarks = struct {
    pub fn benchmark_entity_lookup(cartridge: *EntityCartridge, iterations: usize) BenchmarkResult {
        const timer = std.time.nanoTimestamp();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const entity_id = generate_random_entity_id();
            _ = cartridge.get_entity(entity_id);
        }

        const elapsed = @intToFloat(f64, std.time.nanoTimestamp() - timer) / 1_000_000.0;
        return BenchmarkResult{
            .operations_per_second = @intToFloat(f64, iterations) / elapsed * 1000.0,
            .average_latency_ms = elapsed / @intToFloat(f64, iterations),
        };
    }

    pub fn benchmark_topic_search(cartridge: *TopicCartridge, queries: []TopicQuery) BenchmarkResult {
        // Implementation for topic search performance measurement
    }

    pub fn benchmark_relationship_traversal(cartridge: *RelationshipCartridge, paths: []PathSpec) BenchmarkResult {
        // Implementation for relationship traversal performance measurement
    }
};
```

## Migration and Compatibility

### Schema Evolution

```zig
const SchemaVersion = struct {
    major: u8,
    minor: u8,
    patch: u8,
};

const MigrationPath = struct {
    from_version: SchemaVersion,
    to_version: SchemaVersion,
    migration_function: *const fn(cartridge: *Cartridge) anyerror!void,
};

// Registry of supported migrations
const MIGRATION_PATHS = [_]MigrationPath{
    .{
        .from_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .to_version = .{ .major = 1, .minor = 1, .patch = 0 },
        .migration_function = migrate_v1_0_to_v1_1,
    },
};

pub fn migrate_cartridge(
    cartridge: *Cartridge,
    target_version: SchemaVersion
) !void {
    const current_version = cartridge.get_schema_version();

    if (current_version.eql(target_version)) return;

    for (MIGRATION_PATHS) |migration| {
        if (migration.from_version.eql(current_version)) {
            try migration.migration_function(cartridge);
            return migrate_cartridge(cartridge, target_version); // Recursive for multi-step migrations
        }
    }

    return error.NoMigrationPath;
}
```

---

## Implementation Status

**Current Phase**: Design Specification
**Next Phase**: Prototype Implementation
**Target Completion**: Month 7 of development roadmap

## References

- [PLAN-LIVING-DB.md](../PLAN-LIVING-DB.md) - Overall AI intelligence architecture
- [ai_plugins_v1.md](./ai_plugins_v1.md) - AI plugin system and function calling
- [living_db_semantics.md](./living_db_semantics.md) - AI-augmented transaction semantics