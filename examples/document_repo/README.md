# Document Repository

A full-text searchable document storage system with metadata indexing.

## Overview

This example builds a document repository similar to MongoDB or Elasticsearch, with:
- Document storage with automatic ID generation
- Metadata field indexing for fast queries
- Full-text content search
- Tag-based filtering
- Version history tracking

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Document Repository                        │
├─────────────────────────────────────────────────────────────┤
│  Storage Layout:                                            │
│  doc:<id>                    → document JSON                 │
│  doc:<id>:version:<n>        → version snapshot             │
│  doc:<id>:meta:<field>       → indexed metadata value       │
│  index:<field>:<value>:<id>  → reverse index for queries    │
│  tag:<tag>:<id>              → document IDs by tag          │
│  ft:<word>:<id>              → full-text word index         │
└─────────────────────────────────────────────────────────────┘
```

## Usage

```zig
// Create repository
var repo = try DocumentRepo.init(allocator, &database);

// Insert document
const doc = try repo.insert(.{
    .title = "Introduction to NorthstarDB",
    .content = "NorthstarDB is a high-performance...",
    .author = "alice@example.com",
    .tags = &.{ "database", "tutorial", "embedded" },
});

// Search by content
const results = try repo.searchText("performance database");

// Query by metadata
const docs = try repo.query(.{
    .author = "alice@example.com",
    .tags = &.{"tutorial"},
});
```

## Running the Example

```bash
zig build-exe examples/document_repo/main.zig
./document_repo
```

## Features

### Document Operations
- **Insert**: Add new documents with auto-generated IDs
- **Update**: Modify documents with version history
- **Delete**: Remove documents (soft delete with retention)
- **Get**: Retrieve by ID with version support

### Query Capabilities
- **Text Search**: Full-text search over content fields
- **Metadata Queries**: Filter by indexed fields
- **Tag Filtering**: Boolean AND/OR on tags
- **Range Queries**: Date/numeric range filters

### Indexing Strategy
- Fields marked as `indexed` are automatically inverted
- Full-text index uses word tokenization
- Tag index supports efficient set operations

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Insert | O(log n + m) | n = docs, m = words in text |
| Update | O(log n + m) | Rebuilds indices |
| Get by ID | O(log n) | Direct key lookup |
| Text Search | O(k log n) | k = matching words |
| Metadata Query | O(log n) | Using reverse index |

## Index Types

### Metadata Index
```
index:author:alice@example.com:doc123 = ""
index:status:published:doc456 = ""
```

### Full-Text Index
```
ft:northstar:doc123 = ""
ft:database:doc123 = ""
ft:performance:doc123 = ""
```

### Tag Index
```
tag:tutorial:doc123 = ""
tag:database:doc123 = ""
```

## Advanced Features

### Version History
Every update creates a version snapshot:
```zig
const history = try repo.getVersionHistory("doc123");
// Returns: [v1, v2, v3, ...]
```

### Soft Delete
Documents are marked deleted but retained:
```zig
try repo.softDelete("doc123");
// Document retrievable for 30 days
```

### Bulk Operations
```zig
try repo.bulkInsert(docs);
// Single transaction for multiple docs
```

## Scaling Considerations

1. **Index Size**: Full-text indices can be large; consider word frequency cutoffs
2. **Write Amplification**: Each insert updates multiple indices
3. **Query Optimization**: Combine filters before document fetch
4. **Sharding**: Partition by document ID prefix for scale
