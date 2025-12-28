//! Document Repository Example
//!
//! Demonstrates building a document repository with:
//! - Document storage with auto-generated IDs
//! - Metadata indexing for fast queries
//! - Tag-based filtering
//! - Version history tracking
//! - Full-text content search

const std = @import("std");
const db = @import("northstar");

const Document = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    tags: []const []const u8,
    created_at: i64,
    updated_at: i64,
    version: u32,
};

const DocumentInput = struct {
    title: []const u8,
    content: []const u8,
    author: []const u8,
    tags: []const []const u8,
};

const QueryFilter = struct {
    author: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    created_after: ?i64 = null,
    created_before: ?i64 = null,
};

const DocumentRepo = struct {
    allocator: std.mem.Allocator,
    database: *db.Db,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, database: *db.Db) Self {
        return Self{
            .allocator = allocator,
            .database = database,
        };
    }

    /// Insert a new document
    pub fn insert(self: *Self, input: DocumentInput) !Document {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        const now = std.time.timestamp();
        const doc_id = try self.generateId();

        // Create document JSON (simplified)
        const doc_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":\"{s}\",\"title\":\"{s}\",\"content\":\"{s}\",\"author\":\"{s}\",\"created\":{d},\"version\":1}}",
            .{ doc_id, input.title, input.content, input.author, now },
        );

        // Store document
        const doc_key = try std.fmt.allocPrint(self.allocator, "doc:{s}", .{doc_id});
        try wtxn.put(doc_key, doc_json);

        // Create initial version
        const version_key = try std.fmt.allocPrint(self.allocator, "doc:{s}:version:1", .{doc_id});
        try wtxn.put(version_key, doc_json);

        // Index metadata fields
        try self.indexAuthor(&wtxn, doc_id, input.author);

        // Index tags
        for (input.tags) |tag| {
            try self.indexTag(&wtxn, doc_id, tag);
        }

        // Index content words (simplified full-text)
        try self.indexContent(&wtxn, doc_id, input.content);

        try wtxn.commit();

        return Document{
            .id = try self.allocator.dupe(u8, doc_id),
            .title = try self.allocator.dupe(u8, input.title),
            .content = try self.allocator.dupe(u8, input.content),
            .author = try self.allocator.dupe(u8, input.author),
            .tags = try self.allocator.dupe([]const u8, input.tags),
            .created_at = now,
            .updated_at = now,
            .version = 1,
        };
    }

    /// Get document by ID
    pub fn get(self: *Self, doc_id: []const u8) !?Document {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        const doc_key = try std.fmt.allocPrint(self.allocator, "doc:{s}", .{doc_id});
        defer self.allocator.free(doc_key);

        if (rtxn.get(doc_key)) |doc_json| {
            // Parse JSON (simplified - in production use proper parser)
            return Document{
                .id = try self.allocator.dupe(u8, doc_id),
                .title = "Document Title",
                .content = "Document content...",
                .author = "author@example.com",
                .tags = &.{},
                .created_at = std.time.timestamp(),
                .updated_at = std.time.timestamp(),
                .version = 1,
            };
        }

        return null;
    }

    /// Query documents by filter
    pub fn query(self: *Self, filter: QueryFilter) !std.ArrayList(Document) {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        var results = std.ArrayList(Document).init(self.allocator);

        // If author filter, use author index
        if (filter.author) |author| {
            const author_key = try std.fmt.allocPrint(self.allocator, "index:author:{s}:", .{author});
            defer self.allocator.free(author_key);

            var iter = try rtxn.scan(author_key);
            defer iter.deinit();

            while (try iter.next()) |entry| {
                const doc_id = entry.key[author_key.len..];
                if (try self.get(doc_id)) |doc| {
                    // Apply additional filters
                    if (filter.tags) |tags| {
                        if (try self.hasAllTags(doc_id, tags)) {
                            try results.append(doc);
                        }
                    } else {
                        try results.append(doc);
                    }
                }
            }
        }

        return results;
    }

    /// Full-text search
    pub fn searchText(self: *Self, query: []const u8) !std.ArrayList([]const u8) {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        var results = std.ArrayList([]const u8).init(self.allocator);
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        // Tokenize query (simplified - split by spaces)
        var iter = std.mem.splitScalar(u8, query, ' ');
        while (iter.next()) |word| {
            const trimmed = std.mem.trim(u8, word, " \t\n\r");
            if (trimmed.len == 0) continue;

            const ft_key = try std.fmt.allocPrint(self.allocator, "ft:{s}:", .{trimmed});
            defer self.allocator.free(ft_key);

            var doc_iter = try rtxn.scan(ft_key);
            defer doc_iter.deinit();

            while (try doc_iter.next()) |entry| {
                const doc_id = entry.key[ft_key.len..];
                if (!seen.contains(doc_id)) {
                    try seen.put(try self.allocator.dupe(u8, doc_id), {});
                    try results.append(try self.allocator.dupe(u8, doc_id));
                }
            }
        }

        return results;
    }

    /// Get documents by tag
    pub fn getByTag(self: *Self, tag: []const u8) !std.ArrayList([]const u8) {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        var results = std.ArrayList([]const u8).init(self.allocator);

        const tag_key = try std.fmt.allocPrint(self.allocator, "tag:{s}:", .{tag});
        defer self.allocator.free(tag_key);

        var iter = try rtxn.scan(tag_key);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            const doc_id = entry.key[tag_key.len..];
            try results.append(try self.allocator.dupe(u8, doc_id));
        }

        return results;
    }

    // Index helpers
    fn indexAuthor(self: *Self, txn: *db.WriteTxn, doc_id: []const u8, author: []const u8) !void {
        const key = try std.fmt.allocPrint(self.allocator, "index:author:{s}:{s}", .{ author, doc_id });
        try txn.put(key, "");
    }

    fn indexTag(self: *Self, txn: *db.WriteTxn, doc_id: []const u8, tag: []const u8) !void {
        const key = try std.fmt.allocPrint(self.allocator, "tag:{s}:{s}", .{ tag, doc_id });
        try txn.put(key, "");
    }

    fn indexContent(self: *Self, txn: *db.WriteTxn, doc_id: []const u8, content: []const u8) !void {
        // Tokenize and index each word
        var iter = std.mem.splitScalar(u8, content, ' ');
        while (iter.next()) |word| {
            const trimmed = std.mem.trim(u8, word, " \t\n\r.,!?;:\"'");
            if (trimmed.len > 2) { // Only index words longer than 2 chars
                const key = try std.fmt.allocPrint(self.allocator, "ft:{s}:{s}", .{ trimmed, doc_id });
                try txn.put(key, "");
            }
        }
    }

    fn hasAllTags(self: *Self, doc_id: []const u8, tags: []const []const u8) !bool {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        for (tags) |tag| {
            const key = try std.fmt.allocPrint(self.allocator, "tag:{s}:{s}", .{ tag, doc_id });
            defer self.allocator.free(key);

            if (rtxn.get(key)) |_| {
                // Tag exists
            } else {
                return false;
            }
        }

        return true;
    }

    fn generateId(self: *Self) ![]const u8 {
        const timestamp = std.time.timestamp();
        const random = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
        return try std.fmt.allocPrint(self.allocator, "doc_{d}_{x}", .{ timestamp, random });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Document Repository Example ===\n\n", .{});

    // Open database
    var database = try db.Db.open(allocator, "documents.db");
    defer database.close();

    var repo = DocumentRepo.init(allocator, &database);

    // === Insert Documents ===
    std.debug.print("--- Inserting Documents ---\n", .{});

    const tags1 = &.{ "database", "tutorial", "embedded" };
    _ = try repo.insert(.{
        .title = "Introduction to NorthstarDB",
        .content = "NorthstarDB is a high-performance embedded database built in Zig. It offers massive read concurrency and deterministic replay capabilities.",
        .author = "alice@example.com",
        .tags = tags1,
    });

    const tags2 = &.{ "database", "performance", "optimization" };
    _ = try repo.insert(.{
        .title = "Performance Optimization Guide",
        .content = "Learn how to optimize your database queries for maximum throughput and minimal latency.",
        .author = "bob@example.com",
        .tags = tags2,
    });

    const tags3 = &.{ "tutorial", "beginner", "getting-started" };
    _ = try repo.insert(.{
        .title = "Getting Started with Zig",
        .content = "Zig is a general-purpose programming language with performance safety guarantees.",
        .author = "alice@example.com",
        .tags = tags3,
    });

    const tags4 = &.{ "database", "mvcc", "concurrency" };
    _ = try repo.insert(.{
        .title = "Understanding MVCC",
        .content = "Multi-Version Concurrency Control allows multiple readers to access data without blocking writers.",
        .author = "alice@example.com",
        .tags = tags4,
    });

    std.debug.print("Inserted 4 documents\n", .{});

    // === Query by Author ===
    std.debug.print("\n--- Query by Author (alice@example.com) ---\n", .{});
    const alice_docs = try repo.query(.{ .author = "alice@example.com" });
    defer {
        for (alice_docs.items) |doc| {
            allocator.free(doc.id);
        }
        alice_docs.deinit();
    }
    std.debug.print("Found {d} documents by Alice\n", .{alice_docs.items.len});

    // === Query by Tag ===
    std.debug.print("\n--- Query by Tag (tutorial) ---\n", .{});
    const tutorial_ids = try repo.getByTag("tutorial");
    defer {
        for (tutorial_ids.items) |id| allocator.free(id);
        tutorial_ids.deinit();
    }
    std.debug.print("Found {d} documents tagged 'tutorial'\n", .{tutorial_ids.items.len});

    // === Full-Text Search ===
    std.debug.print("\n--- Full-Text Search ('database performance') ---\n", .{});
    const search_results = try repo.searchText("database performance");
    defer {
        for (search_results.items) |id| allocator.free(id);
        search_results.deinit();
    }
    std.debug.print("Found {d} documents matching search\n", .{search_results.items.len});
    for (search_results.items) |id| {
        std.debug.print("  - {s}\n", .{id});
    }

    // === Combined Query ===
    std.debug.print("\n--- Combined Query (author + tags) ---\n", .{});
    const filtered_tags = &.{ "database" };
    const filtered = try repo.query(.{
        .author = "alice@example.com",
        .tags = filtered_tags,
    });
    defer {
        for (filtered.items) |doc| {
            allocator.free(doc.id);
        }
        filtered.deinit();
    }
    std.debug.print("Found {d} documents by Alice tagged 'database'\n", .{filtered.items.len});

    std.debug.print("\n=== Example Complete ===\n", .{});
}
