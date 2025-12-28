# ADR-004: Cartridge Artifact Format

**Status**: Accepted

**Date**: 2025-12-28

## Context

NorthstarDB's "Living Database" vision requires **structured knowledge artifacts** that AI plugins can build and query:

1. **Derived from commit stream**: All cartridges built by replaying transaction history
2. **Query optimization**: Enable semantic queries without full table scans
3. **Invalidation**: Need policies for when cartridges become stale
4. **Portability**: Cartridges should be independent, shareable artifacts

Key requirements:
- **Structured over fuzzy**: Entity/topic indices vs vector embeddings
- **Deterministic builds**: Same input → same cartridge
- **Efficient invalidation**: Know exactly when to rebuild
- **Multi-format support**: Different cartridge types for different use cases

## Decision

NorthstarDB uses a **structured cartridge file format** with explicit versioning and invalidation policies:

### Core Design

1. **Three-section layout**: Header, Index, Data, Metadata
2. **Self-describing**: Metadata includes schema version and build info
3. **Invalidation-aware**: Policies encode when rebuild is needed
4. **Type system**: Magic numbers for cartridge types

### File Layout

```
┌─────────────────────┐
│   CartridgeHeader   │ 64 bytes - magic, version, type, offsets
├─────────────────────┤
│   Index Section     │ Variable - inverted indices, offsets
├─────────────────────┤
│    Data Section     │ Variable - actual payload data
├─────────────────────┤
│  Metadata Section   │ Variable - schema, build info, policies
└─────────────────────┘
```

### Header Structure

```zig
const CartridgeHeader = struct {
    magic: u32 = 0x4E434152,        // "NCAR"
    version: Version = .{ .major = 1, .minor = 0, .patch = 0 },
    flags: FeatureFlags,            // compression, encryption, etc.
    cartridge_type: CartridgeType,  // entity_index, topic_index, etc.
    created_at: u64,                // Unix timestamp
    source_txn_id: u64,             // Last TxnId in source DB
    entry_count: u64,               // Number of entries
    index_offset: u64,              // Offset to index section
    data_offset: u64,               // Offset to data section
    metadata_offset: u64,           // Offset to metadata section
    checksum: u32,                  // CRC32C of entire file
};
```

### Cartridge Types

```zig
const CartridgeType = enum(u32) {
    pending_tasks_by_type = 0x50544254,  // "PTBT"
    entity_index = 0x454E5449,           // "ENTI"
    topic_index = 0x544F5049,            // "TOPI"
    relationship_graph = 0x52454C47,     // "RELG"
    semantic_embeddings = 0x56454D42,    // "VEMB"
    temporal_history = 0x54484953,       // "THIS"
    document_history = 0x44464849,       // "DFHI"
    custom = 0x43555354,                 // "CUST"
};
```

### Invalidation Policy

```zig
const InvalidationPolicy = struct {
    max_age_seconds: u64,        // Rebuild after this time
    min_new_txns: u64,           // Min txns before incremental
    max_new_txns: u64,           // Max txns before full rebuild
    pattern_count: u32,
    patterns: []InvalidationPattern,  // Key patterns to watch
};

const InvalidationPattern = struct {
    key_prefix: []const u8,      // "task:", "user:", etc.
    check_mutation_type: bool,
    mutation_type: ?enum { put, delete, any },
};
```

### Metadata Section

```zig
const CartridgeMetadata = struct {
    format_name: []const u8,         // "entity_index_v1"
    schema_version: SchemaVersion,   // Cartridge-type versioning
    build_time_ms: u64,              // Build duration
    source_db_hash: [32]u8,          // SHA-256 of source DB
    builder_version: []const u8,      // "northstar_db.cartridge.v1"
    invalidation_policy: InvalidationPolicy,
};
```

## Consequences

### Positive

- **Type safety**: Magic numbers prevent loading wrong cartridge type
- **Explicit versioning**: Schema evolution without breaking existing code
- **Efficient invalidation**: Know exactly when cartridge is stale
- **Shareable artifacts**: Portable files for distribution
- **Build verification**: Source hash ensures correctness

### Negative

- **Build complexity**: Must replay commit stream to build
- **Storage overhead**: Duplicate data from main database
- **Format maintenance**: Schema migrations for each cartridge type
- **Validation cost**: Must verify integrity on load

### Mitigations

- **Build complexity**: Acceptable tradeoff for query performance
- **Storage overhead**: Compression, selective building
- **Format maintenance**: Version fields, backward compatibility
- **Validation cost**: Checksums, incremental verification

## Related Specifications

- `src/cartridges/format.zig` - Cartridge format implementation
- `src/cartridges/entity.zig` - Entity index cartridge
- `src/cartridges/temporal.zig` - Temporal history cartridge
- `PLAN-LIVING-DB.md` - AI intelligence architecture

## Cartridge Examples

### Entity Index Cartridge
- **Purpose**: Fast entity lookup by type and attributes
- **Built from**: Commit stream + entity extraction plugin
- **Invalidation**: Rebuild when entity-related keys change

### Topic Index Cartridge
- **Purpose**: Inverted index for topic-based queries
- **Built from**: Commit stream + topic extraction plugin
- **Invalidation**: Rebuild when new topics detected

### Relationship Graph Cartridge
- **Purpose**: Graph traversal for entity relationships
- **Built from**: Commit stream + relationship extraction plugin
- **Invalidation**: Rebuild when relationship patterns change

## Alternatives Considered

1. **Inline indexes**: Rejected (mixes concerns, harder to invalidate)
2. **Vector embeddings only**: Rejected (non-deterministic, fuzzy results)
3. **No cartridges**: Rejected (no semantic query capability)
4. **SQLite companion**: Rejected (defeats purpose of embedded DB)
