# Cartridge Format v1 Specification

**Version**: 1.0
**Date**: 2025-12-23
**Status**: Draft

## Overview

This specification defines the cartridge artifact format for NorthstarDB's structured memory cartridges. Cartridges are materialized views built from the commit stream that enable fast query patterns without scanning the full database.

## Design Principles

1. **Immutable Artifacts**: Cartridges are built once and used read-only
2. **Deterministic Building**: Same commit stream produces identical cartridge
3. **Version Control**: Schema evolution with migration support
4. **Invalidation Policy**: Clear rules for when to rebuild
5. **Memory Mappable**: Efficient access via mmap for hot lookups

## Cartridge Types

| Type | Purpose | Target Latency |
|------|---------|----------------|
| `pending_tasks_by_type` | Fast task lookup by type | <1ms |
| `entity_index` | Entity storage with attributes | <1ms |
| `topic_index` | Inverted term index | <10ms |
| `relationship_graph` | Entity relationships | <100ms |

## File Format

### Global Header (64 bytes)

```
Offset  Field              Type    Description
------  -----------------  ------  -----------------------------------------
0x00    magic             u32     "NCAR" (0x4E434152)
0x04    version_major     u8      Cartridge format major version
0x05    version_minor     u8      Cartridge format minor version
0x06    version_patch     u8      Cartridge format patch version
0x07    flags             u8      Feature flags (reserved)
0x08    cartridge_type    u32     Cartridge type identifier
0x0C    created_at        u64     Unix timestamp of creation
0x14    source_txn_id     u64     Last transaction ID in source
0x1C    entry_count       u64     Number of entries in cartridge
0x24    index_offset      u64     Offset to index section
0x2C    data_offset       u64     Offset to data section
0x34    metadata_offset   u64     Offset to metadata section
0x3C    checksum          u32     CRC32C of entire file
```

### Type Identifiers

```zig
pub const CartridgeType = enum(u32) {
    pending_tasks_by_type = 0x50544254, // "PTBT"
    entity_index = 0x454E5449,           // "ENTI"
    topic_index = 0x544F5049,            // "TOPI"
    relationship_graph = 0x52454C47,     // "RELG"
    custom = 0x43555354,                 // "CUST"
};
```

### Feature Flags

```zig
pub const FeatureFlags = packed struct {
    compressed: bool = false,     // Data section is compressed (LZ4)
    encrypted: bool = false,      // Data section is encrypted
    checksummed: bool = true,     // Per-entry checksums present
    temporal: bool = false,       // Includes temporal index
    reserved: u4 = 0,
};
```

## Cartridge Metadata Section

### Metadata Header

```
Offset  Field              Type    Description
------  -----------------  ------  -----------------------------------------
0x00    format_name       [32]    Format name (null-terminated string)
0x20    schema_version    u32     Schema version for this cartridge type
0x24    build_time_ms     u64     Time taken to build (milliseconds)
0x2C    source_db_hash    [32]    Hash of source database file
0x4C    builder_version   [32]    Builder version string
0x6C    invalidation_txns [??]    List of txn IDs that invalidate this cartridge
```

### Invalidation Policy

```zig
pub const InvalidationPolicy = struct {
    /// Maximum age before rebuild is recommended (seconds, 0 = no limit)
    max_age_seconds: u64,

    /// Minimum transaction count before incremental rebuild
    min_new_txns: u64,

    /// Maximum transaction count before full rebuild
    max_new_txns: u64,

    /// Specific transaction patterns that trigger invalidation
    invalidation_patterns: []InvalidationPattern,

    pub const InvalidationPattern = struct {
        key_prefix: []const u8,
        check_mutation_type: bool,
        mutation_type: ?MutationType,
    };

    pub const MutationType = enum {
        put,
        delete,
        any,
    };

    /// Check if a transaction should invalidate this cartridge
    pub fn shouldInvalidate(
        policy: InvalidationPolicy,
        txn: CommitRecord,
        current_txn_id: u64,
        cartridge_txn_id: u64
    ) bool {
        // Check if too many transactions have passed
        const new_txn_count = current_txn_id - cartridge_txn_id;
        if (new_txn_count >= policy.max_new_txns) return true;

        // Check invalidation patterns
        for (policy.invalidation_patterns) |pattern| {
            for (txn.mutations) |mutation| {
                const key = mutation.getKey();
                if (std.mem.startsWith(u8, key, pattern.key_prefix)) {
                    if (!pattern.check_mutation_type) return true;
                    if (pattern.mutation_type) |mt| {
                        const matches = switch (mt) {
                            .put => mutation == .put,
                            .delete => mutation == .delete,
                            .any => true,
                        };
                        if (matches) return true;
                    }
                }
            }
        }

        return false;
    }
};
```

## Type-Specific Format: `pending_tasks_by_type`

This cartridge provides fast lookup of pending tasks grouped by type.

### Index Section

```
Type Index Header
├── Type Count (u32)
├── Type Entries[]

Type Entry
├── Type String Length (u16)
├── Type String (variable)
├── Task Count (u32)
├── First Task Offset (u64)
├── Last Task Offset (u64)
└── Checksum (u32)
```

### Data Section

```
Task Entry
├── Header (8 bytes)
│   ├── Flags (u8)       0x01 = claimed, 0x02 = deleted
│   ├── Priority (u8)    0-255, higher = more important
│   ├── Type Len (u16)
│   └── Key Len (u32)
├── Type String (variable)
├── Task Key (variable)
├── Claim Info (8 bytes, optional)
│   ├── Claimed By (variable length string)
│   └── Claim Time (u64)
└── Checksum (u32)
```

### Query Interface

```zig
pub const PendingTasksCartridge = struct {
    /// Get all pending tasks for a specific type
    pub fn getTasksByType(
        cartridge: *PendingTasksCartridge,
        task_type: []const u8
    ) ![]TaskEntry;

    /// Get a specific task by key
    pub fn getTask(
        cartridge: *PendingTasksCartridge,
        key: []const u8
    ) !?TaskEntry;

    /// Claim a task (returns updated task entry)
    pub fn claimTask(
        cartridge: *PendingTasksCartridge,
        key: []const u8,
        claimer: []const u8
    ) !TaskEntry;

    /// Iterate all tasks in priority order
    pub fn iterateByPriority(
        cartridge: *PendingTasksCartridge
    ) PriorityIterator;

    pub const TaskEntry = struct {
        key: []const u8,
        task_type: []const u8,
        priority: u8,
        claimed: bool,
        claimed_by: ?[]const u8,
        claim_time: ?u64,
    };
};
```

## Serialization Format

### Integer Encoding

All multi-byte integers use little-endian byte order.

### String Encoding

Strings are encoded as:
- Length prefix (u16 for short strings <64KB, u32 for longer)
- UTF-8 bytes (no null terminator)
- No padding

### Checksum Algorithm

- Per-entry checksums: CRC32C
- File checksum: CRC32C of entire file with checksum field set to 0

## Versioning and Compatibility

### Semantic Versioning

- **Major**: Incompatible changes, requires migration
- **Minor**: Backward compatible new features
- **Patch**: Backward compatible bug fixes

### Migration Strategy

```zig
pub const Migration = struct {
    from_version: SchemaVersion,
    to_version: SchemaVersion,
    migrate_fn: *const fn([]const u8, Allocator) ![]const u8,
};

pub const SchemaVersion = struct {
    major: u8,
    minor: u8,
    patch: u8,

    pub fn compatVersion(self: SchemaVersion) Compatibility {
        if (self.major == 1 and self.minor == 0) return .v1_0;
        return .unknown;
    }

    pub const Compatibility = enum {
        v1_0,
        unknown,
    };
};
```

### Compatibility Matrix

| Reader Version | Can Read |
|----------------|----------|
| 1.0.x | 1.0.y (same minor) |
| 1.1.x | 1.0.y, 1.1.y |
| 2.0.x | 2.0.y only (major break) |

## Performance Characteristics

### Build Performance

| Metric | Target |
|--------|--------|
| Build speed | 10K tasks/second |
| Incremental update | 1K tasks/second |
| Memory usage | <100MB per 1M tasks |

### Query Performance

| Operation | Target | Notes |
|-----------|--------|-------|
| Get by type | <1ms | O(1) hash lookup |
| Get by key | <1ms | O(1) hash lookup |
| Iterate by priority | <10ms for 1K | Pre-sorted |
| Claim task | <1ms | Updates in-memory copy |

### Storage Efficiency

| Metric | Value |
|--------|-------|
| Per-task overhead | ~64 bytes |
| Compression ratio | 3-5x with LZ4 |
| Mmap friendly | Yes |

## Error Handling

### Validation Errors

```zig
pub const ValidationError = error{
    InvalidMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    CorruptedData,
    InvalidCartridgeType,
    MissingRequiredFeature,
};
```

### Runtime Errors

```zig
pub const CartridgeError = error{
    NotFound,
    OutOfMemory,
    PermissionDenied,
    Locked,
    NeedsRebuild,
};
```

## Security Considerations

1. **Validation**: All user inputs validated before cartridge operations
2. **Bounds Checking**: Array access always bounds-checked
3. **Checksum Verification**: All entries verified on load
4. **Path Traversal**: File paths sanitized before cartridge operations

## Testing Requirements

### Unit Tests

- Header serialization/deserialization
- Version compatibility matrix
- Invalidation policy logic
- Checksum calculation and verification

### Integration Tests

- Full build from commit stream
- Query operations on built cartridge
- Migration between versions

### Property Tests

- Randomized build/query cycles
- Corruption detection and recovery
- Concurrent access patterns

## Implementation Status

- [x] Global header format
- [x] Versioning system
- [x] Invalidation policy definition
- [ ] pending_tasks_by_type format implementation
- [ ] Builder implementation
- [ ] Query interface implementation

## References

- [PLAN-LIVING-DB.md](../PLAN-LIVING-DB.md) - Overall AI intelligence architecture
- [structured_memory_v1.md](./structured_memory_v1.md) - Structured memory format
- [commit_record_v0.md](./commit_record_v0.md) - Commit stream format
