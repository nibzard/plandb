# Document Repository

A full-text searchable document storage system with metadata indexing and version tracking.

## Overview

This example builds a document repository similar to MongoDB or Elasticsearch, demonstrating advanced indexing patterns, full-text search, and version tracking capabilities with NorthstarDB.

## Use Cases

- Content management systems (CMS)
- Document storage and retrieval
- Knowledge base systems
- Blog platforms with search
- Technical documentation storage
- Note-taking applications

## Features Demonstrated

- **Document Storage**: Auto-generated IDs with JSON serialization
- **Metadata Indexing**: Reverse indexes for fast field-based queries
- **Full-Text Search**: Word-level inverted index for content search
- **Tag Filtering**: Multi-dimensional tag queries with AND/OR
- **Version History**: Automatic version snapshots on updates
- **Soft Delete**: Retention policy for deleted documents

## Running the Example

```bash
cd examples/document_repo
zig build run

# Or build manually
zig build-exe main.zig
./document_repo
```

## Architecture Overview

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

## Code Walkthrough

### 1. Repository Initialization

```zig
var repo = DocumentRepo.init(allocator, &database);
```

No complex initialization needed - the repository manages its own state.

### 2. Document Insert

```zig
const tags = &.{ "database", "tutorial", "embedded" };
const doc = try repo.insert(.{
    .title = "Introduction to NorthstarDB",
    .content = "NorthstarDB is a high-performance...",
    .author = "alice@example.com",
    .tags = tags,
});
```

**What happens:**
1. Generates unique document ID (timestamp + random)
2. Serializes document to JSON
3. Stores document with key `doc:<id>`
4. Creates initial version snapshot
5. Builds reverse index for author field
6. Indexes all tags
7. Tokenizes and indexes content words

### 3. Query by Metadata

```zig
const docs = try repo.query(.{
    .author = "alice@example.com",
    .tags = &.{"tutorial"},
});
```

**Query Process:**
1. Look up author in reverse index: `index:author:alice@example.com:*`
2. Filter results by tag membership
3. Fetch full documents for matching IDs
4. Return sorted by creation date

### 4. Full-Text Search

```zig
const results = try repo.searchText("performance database");
```

**Search Process:**
1. Tokenize query into words: ["performance", "database"]
2. Look up each word in full-text index
3. Union document IDs from all word matches
4. Return unique document IDs

## Index Types

### Metadata Index (Reverse Index)

```
index:author:alice@example.com:doc123 = ""
index:status:published:doc456 = ""
index:category:database:doc789 = ""
```

**Benefits:**
- O(log n) lookup by field value
- Efficient range queries on field values
- Natural for filtering and grouping

### Full-Text Index (Inverted Index)

```
ft:northstar:doc123 = ""
ft:database:doc123 = ""
ft:performance:doc123 = ""
ft:high:doc123 = ""
```

**Tokenization Strategy:**
- Split by whitespace
- Strip punctuation (.,!?;:"')
- Filter words < 3 characters
- Case-insensitive matching

### Tag Index

```
tag:tutorial:doc123 = ""
tag:database:doc123 = ""
tag:embedded:doc123 = ""
```

**Multi-Tag Queries:**
- AND: All tags must match
- OR: Any tag can match
- Combine with metadata filters

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Insert | O(log n + m) | n = docs, m = words in content |
| Update | O(log n + m) | Rebuilds all indices |
| Get by ID | O(log n) | Direct B+tree lookup |
| Text Search | O(k log n) | k = unique words in query |
| Metadata Query | O(log n + r) | r = matching documents |
| Tag Query | O(log n + r) | Using tag index |

### Write Amplification

Each insert updates:
1. Main document: 1 write
2. Version snapshot: 1 write
3. Author index: 1 write
4. Each tag: 1 write per tag
5. Each unique word: 1 write per word

**Example:** Document with 5 tags and 200 unique words = ~207 writes

**Mitigation:**
- Use batch inserts for multiple documents
- Limit indexed fields to frequently queried ones
- Consider word frequency thresholds

## Query Patterns

### Simple Metadata Query

```zig
const docs = try repo.query(.{
    .author = "alice@example.com",
});
```

### Multi-Field Query

```zig
const docs = try repo.query(.{
    .author = "alice@example.com",
    .tags = &.{"database", "tutorial"},
    .created_after = start_date,
    .created_before = end_date,
});
```

### Full-Text Search

```zig
// Single word
const results = try repo.searchText("database");

// Multiple words (OR semantics)
const results = try repo.searchText("performance optimization");

// Phrase search (future enhancement)
const results = try repo.searchPhrase("high performance");
```

### Combined Query

```zig
// First, filter by metadata
const candidates = try repo.query(.{
    .author = "alice@example.com",
});

// Then, search within results
const final_results = try repo.searchTextInSet(
    "database",
    candidates.items
);
```

## Advanced Features

### Version History

Every update creates a version snapshot:

```zig
// Update document
const updated = try repo.update("doc123", .{
    .title = "Updated Title",
    .content = "New content...",
});

// Get version history
const history = try repo.getVersionHistory("doc123");
// Returns: [v1, v2, v3, ...]

// Restore specific version
try repo.restoreVersion("doc123", 2);
```

**Version Storage:**
```
doc:doc123:version:1 → original document JSON
doc:doc123:version:2 → updated document JSON
doc:doc123:version:3 → current document JSON
```

### Soft Delete

Documents are marked deleted but retained:

```zig
try repo.softDelete("doc123", 30); // Retain for 30 days

// Check if deleted
if (try repo.isDeleted("doc123")) {
    std.debug.print("Document was deleted\n", .{});
}

// Restore before retention expires
try repo.restore("doc123");

// Permanent deletion after retention
try repo.purgeExpired();
```

**Soft Delete Storage:**
```
doc:doc123:deleted = "{\"deleted_at\": 1704067200, \"retention_days\": 30}"
```

### Bulk Operations

```zig
// Bulk insert
const docs = &[_]DocumentInput{
    .{ .title = "Doc 1", ... },
    .{ .title = "Doc 2", ... },
    .{ .title = "Doc 3", ... },
};
const ids = try repo.bulkInsert(docs);

// Bulk update
var updates = std.StringHashMap(DocumentInput).init(allocator);
try updates.put("doc123", .{ .title = "Updated 1", ... });
try updates.put("doc456", .{ .title = "Updated 2", ... });
try repo.bulkUpdate(updates);

// Bulk delete (soft)
const ids_to_delete = &[_][]const u8{ "doc123", "doc456" };
try repo.bulkSoftDelete(ids_to_delete, 30);
```

## Indexing Strategies

### Selective Field Indexing

Not all fields need reverse indexes:

```zig
// GOOD: Index frequently queried fields
indexAuthor("doc123", "alice@example.com");  // Queried often
indexStatus("doc123", "published");          // Filtered often

// AVOID: Index rarely queried fields
indexViewCount("doc123", 42);                // Not worth the cost
indexLastModified("doc123", timestamp);      // Use range scan instead
```

### Full-Text Index Optimization

```zig
// Stopwords to skip
const STOPLIST = std.StaticStringMap(void).initComptime(.{
    .{"the"}, .{"a"}, .{"an"}, .{"and"}, .{"or"},
    .{"but"}, .{"in"}, .{"on"}, .{"at"}, .{"to"},
});

// Word frequency threshold
const MIN_WORD_LENGTH = 3;
const MAX_WORD_LENGTH = 50;

// Only index meaningful words
fn shouldIndexWord(word: []const u8) bool {
    if (word.len < MIN_WORD_LENGTH) return false;
    if (word.len > MAX_WORD_LENGTH) return false;
    if (STOPLIST.has(word)) return false;
    return true;
}
```

## Scaling Considerations

### Index Size Management

1. **Word Frequency Cutoff**
```zig
// Only index words appearing < 1% of corpus
const global_word_freq = getGlobalWordFrequency();
if (global_word_freq.get(word) > corpus_size / 100) {
    skip_indexing(word);
}
```

2. **Document Pruning**
```zig
// Archive old documents
try repo.archiveBefore(cutoff_date);

// Move to separate database
var archive = try db.Db.open(allocator, "documents_archive.db");
try repo.transferTo(&archive, "doc:*");
```

3. **Shard by ID Prefix**
```zig
// Route to appropriate shard
const shard_id = doc_id[0..2];  // First 2 chars
var shard_db = getShardDatabase(shard_id);
```

### Query Optimization

1. **Filter Early**
```zig
// GOOD: Filter before full document fetch
const doc_ids = try getByAuthorIndex(author);
for (doc_ids) |id| {
    if (hasAllTags(id, tags)) {
        results.append(try getFullDocument(id));
    }
}

// AVOID: Fetch all documents first
const all_docs = try scanAllDocuments();
for (all_docs) |doc| {
    if (std.mem.eql(u8, doc.author, author)) {
        // ...
    }
}
```

2. **Combine Indexes**
```zig
// Intersect multiple index results
const by_author = try getAuthorIndex(author);
const by_status = try getStatusIndex(status);
const candidates = intersectIds(by_author, by_status);

// Only fetch candidate documents
for (candidates) |id| {
    results.append(try getDocument(id));
}
```

## Real-World Usage Example

```zig
// Blog platform with search
const BlogPost = struct {
    title: []const u8,
    content: []const u8,
    author: []const u8,
    tags: []const []const u8,
    published: bool,
};

// Create new post
const post = try repo.insert(.{
    .title = "Getting Started with NorthstarDB",
    .content = "NorthstarDB is a high-performance...",
    .author = "alice@example.com",
    .tags = &.{ "database", "tutorial", "embedded" },
});

// Find all published posts by author
const published = try repo.query(.{
    .author = "alice@example.com",
    .status = "published",
});

// Search for tutorials
const tutorials = try repo.query(.{
    .tags = &.{"tutorial"},
    .created_after = last_month,
});

// Full-text search for "database"
const results = try repo.searchText("database");

// Update post
try repo.update(post.id, .{
    .title = "Updated: Getting Started",
    .content = new_content,
});

// Get edit history
const history = try repo.getVersionHistory(post.id);
```

## Testing

```zig
test "insert and query document" {
    var repo = DocumentRepo.init(testing.allocator, &database);

    const doc = try repo.insert(.{
        .title = "Test",
        .content = "Test content",
        .author = "test@example.com",
        .tags = &.{ "test" },
    });

    const found = try repo.get(doc.id);
    try testing.expect(found != null);
    try testing.expectEqualStrings("Test", found.?.title);
}

test "full-text search" {
    var repo = DocumentRepo.init(testing.allocator, &database);

    _ = try repo.insert(.{
        .title = "Database Tutorial",
        .content = "Learn about databases",
        .author = "test@example.com",
        .tags = &.{},
    });

    const results = try repo.searchText("database");
    try testing.expect(results.items.len > 0);
}
```

## Next Steps

- **time_series**: For high-volume write patterns
- **ai_knowledge_base**: For advanced relationship modeling
- **basic_kv**: For fundamental CRUD operations

## See Also

- [B+Tree Indexing](../../src/btree.zig)
- [MVCC Snapshots](../../docs/guides/mvcc.md)
- [Query Optimization](../../docs/guides/performance.md)
