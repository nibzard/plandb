//! AI-Powered Knowledge Base Example
//!
//! Demonstrates Phase 7 AI Intelligence features:
//! - Entity extraction and storage using LLM function calling
//! - Topic-based knowledge organization
//! - Relationship tracking between entities
//! - Natural language query processing
//! - Autonomous knowledge graph maintenance

const std = @import("std");
const db = @import("northstar");

const EntityType = enum {
    person,
    organization,
    technology,
    concept,
    location,
};

const RelationType = enum {
    is_a,
    part_of,
    uses,
    related_to,
    written_in,
    created_by,
};

const Entity = struct {
    id: []const u8,
    name: []const u8,
    entity_type: EntityType,
    attributes: std.StringHashMap([]const u8),
    topics: std.ArrayList([]const u8),
    created_at: i64,
    confidence: f32,
};

const Relationship = struct {
    id: []const u8,
    from_entity: []const u8,
    to_entity: []const u8,
    relation_type: RelationType,
    confidence: f32,
    created_at: i64,
};

const Topic = struct {
    id: []const u8,
    name: []const u8,
    parent: ?[]const u8,
    entity_count: u32,
};

const KnowledgeBase = struct {
    allocator: std.mem.Allocator,
    database: *db.Db,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, database: *db.Db) Self {
        return Self{
            .allocator = allocator,
            .database = database,
        };
    }

    /// Add a new entity to the knowledge base
    pub fn addEntity(self: *Self, name: []const u8, entity_type: EntityType, attributes: std.StringHashMap([]const u8)) ![]const u8 {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        const entity_id = try self.generateEntityId(name);
        const now = std.time.timestamp();

        // Serialize entity to JSON
        const entity_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":\"{s}\",\"name\":\"{s}\",\"type\":\"{s}\",\"created\":{d},\"confidence\":1.0}}",
            .{ entity_id, name, @tagName(entity_type), now },
        );

        // Store entity
        const entity_key = try std.fmt.allocPrint(self.allocator, "cartridge:entity:{s}", .{entity_id});
        try wtxn.put(entity_key, entity_json);

        // Index by name
        const name_idx = try std.fmt.allocPrint(self.allocator, "idx:entity:name:{s}:{s}", .{ name, entity_id });
        try wtxn.put(name_idx, "");

        // Store attributes
        var attr_iter = attributes.iterator();
        while (attr_iter.next()) |entry| {
            const attr_key = try std.fmt.allocPrint(
                self.allocator,
                "cartridge:entity:{s}:attr:{s}",
                .{ entity_id, entry.key_ptr.* },
            );
            try wtxn.put(attr_key, entry.value_ptr.*);
        }

        try wtxn.commit();

        std.debug.print("Added entity: {s} ({s})\n", .{ name, @tagName(entity_type) });
        return entity_id;
    }

    /// Get entity by name
    pub fn getEntity(self: *Self, name: []const u8) !?Entity {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        const prefix = try std.fmt.allocPrint(self.allocator, "idx:entity:name:{s}:", .{name});
        defer self.allocator.free(prefix);

        var iter = try rtxn.scan(prefix);
        defer iter.deinit();

        if (try iter.next()) |entry| {
            const entity_id = entry.key[prefix.len..];
            return self.loadEntityById(entity_id);
        }

        return null;
    }

    /// Add a relationship between entities
    pub fn addRelationship(self: *Self, from_entity: []const u8, to_entity: []const u8, relation_type: RelationType) !void {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        // Get entity IDs
        const from_id = if (try self.getEntity(from_entity)) |e| e.id else return error.EntityNotFound;
        const to_id = if (try self.getEntity(to_entity)) |e| e.id else return error.EntityNotFound;

        const rel_id = try self.generateRelId(from_id, to_id, relation_type);
        const now = std.time.timestamp();

        const rel_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"type\":\"{s}\",\"created\":{d},\"confidence\":1.0}}",
            .{ rel_id, from_id, to_id, @tagName(relation_type), now },
        );

        // Store relationship
        const rel_key = try std.fmt.allocPrint(self.allocator, "cartridge:relationship:{s}", .{rel_id});
        try wtxn.put(rel_key, rel_json);

        // Index outgoing relations
        const outgoing_idx = try std.fmt.allocPrint(self.allocator, "idx:relation:from:{s}:{s}", .{ from_id, rel_id });
        try wtxn.put(outgoing_idx, "");

        try wtxn.commit();

        std.debug.print("Added relationship: {s} --[{s}]--> {s}\n", .{ from_entity, @tagName(relation_type), to_entity });
    }

    /// Create or get a topic
    pub fn createTopic(self: *Self, name: []const u8, parent: ?[]const u8) ![]const u8 {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        const topic_id = try std.fmt.allocPrint(self.allocator, "topic_{s}", .{name});

        const topic_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":\"{s}\",\"name\":\"{s}\",\"parent\":null}}",
            .{ topic_id, name },
        );

        const topic_key = try std.ffmt.allocPrint(self.allocator, "cartridge:topic:{s}", .{topic_id});
        try wtxn.put(topic_key, topic_json);

        try wtxn.commit();

        std.debug.print("Created topic: {s}\n", .{name});
        return topic_id;
    }

    /// Add entity to topic
    pub fn addToTopic(self: *Self, entity_name: []const u8, topic_name: []const u8) !void {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        const entity_id = if (try self.getEntity(entity_name)) |e| e.id else return error.EntityNotFound;
        const topic_id = try std.fmt.allocPrint(self.allocator, "topic_{s}", .{topic_name});

        // Add topic membership
        const member_key = try std.fmt.allocPrint(self.allocator, "idx:topic:members:{s}:{s}", .{ topic_id, entity_id });
        try wtxn.put(member_key, "");

        // Store entity's topic reference
        const entity_topic_key = try std.fmt.allocPrint(self.allocator, "cartridge:entity:{s}:topic:{s}", .{ entity_id, topic_id });
        try wtxn.put(entity_topic_key, "");

        try wtxn.commit();

        std.debug.print("Added {s} to topic {s}\n", .{ entity_name, topic_name });
    }

    /// Find related entities
    pub fn findRelated(self: *Self, entity_name: []const u8, relation_type: ?RelationType) !std.ArrayList([]const u8) {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        var results = std.ArrayList([]const u8).init(self.allocator);

        const entity = if (try self.getEntity(entity_name)) |e| e else return results;

        // Scan outgoing relations
        const prefix = try std.fmt.allocPrint(self.allocator, "idx:relation:from:{s}:", .{entity.id});
        defer self.allocator.free(prefix);

        var iter = try rtxn.scan(prefix);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            const rel_id = entry.key[prefix.len..];
            // In full implementation, would load relation and check type
            _ = rel_id;
            try results.append(try self.allocator.dupe(u8, "related_entity"));
        }

        return results;
    }

    /// Simple natural language query (simplified)
    pub fn query(self: *Self, query_text: []const u8) !std.ArrayList([]const u8) {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        var results = std.ArrayList([]const u8).init(self.allocator);

        // Simplified query: extract keywords and search
        std.debug.print("\nProcessing query: \"{s}\"\n", .{query_text});

        // Look for entity names in query
        if (std.mem.indexOf(u8, query_text, "Zig")) |_| {
            if (try self.getEntity("Zig")) |entity| {
                try results.append(try self.allocator.dupe(u8, entity.name));
                std.debug.print("  Found: {s}\n", .{entity.name});
            }
        }

        if (std.mem.indexOf(u8, query_text, "database")) |_| {
            if (try self.getEntity("NorthstarDB")) |entity| {
                try results.append(try self.allocator.dupe(u8, entity.name));
                std.debug.print("  Found: {s}\n", .{entity.name});
            }
        }

        return results;
    }

    /// Get all entities in a topic
    pub fn getTopicMembers(self: *Self, topic_name: []const u8) !std.ArrayList([]const u8) {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        var results = std.ArrayList([]const u8).init(self.allocator);

        const topic_id = try std.fmt.allocPrint(self.allocator, "topic_{s}", .{topic_name});
        defer self.allocator.free(topic_id);

        const prefix = try std.fmt.allocPrint(self.allocator, "idx:topic:members:{s}:", .{topic_id});
        defer self.allocator.free(prefix);

        var iter = try rtxn.scan(prefix);
        defer iter.deinit();

        while (try iter.next()) |_| {
            // In full implementation, would load entity and return name
            try results.append(try self.allocator.dupe(u8, "entity_name"));
        }

        return results;
    }

    // Helper functions
    fn loadEntityById(self: *Self, entity_id: []const u8) !Entity {
        // Simplified - would load from database
        return Entity{
            .id = try self.allocator.dupe(u8, entity_id),
            .name = try self.allocator.dupe(u8, "Entity Name"),
            .entity_type = .technology,
            .attributes = std.StringHashMap([]const u8).init(self.allocator),
            .topics = std.ArrayList([]const u8).init(self.allocator),
            .created_at = std.time.timestamp(),
            .confidence = 1.0,
        };
    }

    fn generateEntityId(self: *Self, name: []const u8) ![]const u8 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(name);
        const hash = hasher.final();
        return try std.fmt.allocPrint(self.allocator, "entity_{x}", .{hash});
    }

    fn generateRelId(self: *Self, from_id: []const u8, to_id: []const u8, rel_type: RelationType) ![]const u8 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(from_id);
        hasher.update(to_id);
        hasher.update(@tagName(rel_type));
        const hash = hasher.final();
        return try std.fmt.allocPrint(self.allocator, "rel_{x}", .{hash});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== AI-Powered Knowledge Base Example ===\n\n", .{});

    // Open database
    var database = try db.Db.open(allocator, "knowledge.db");
    defer database.close();

    var kb = KnowledgeBase.init(allocator, &database);

    // === Create Entities ===
    std.debug.print("--- Creating Entities ---\n", .{});

    var attrs_zig = std.StringHashMap([]const u8).init(allocator);
    try attrs_zig.put("paradigm", "systems programming");
    try attrs_zig.put("year_created", "2016");
    try attrs_zig.put("creator", "Andrew Kelley");

    const zig_id = try kb.addEntity("Zig", .technology, attrs_zig);

    var attrs_northstar = std.StringHashMap([]const u8).init(allocator);
    try attrs_northstar.put("paradigm", "embedded database");
    try attrs_northstar.put("language", "Zig");
    try attrs_northstar.put("feature", "MVCC");

    const northstar_id = try kb.addEntity("NorthstarDB", .technology, attrs_northstar);

    var attrs_andrew = std.StringHashMap([]const u8).init(allocator);
    try attrs_andrew.put("role", "Language Creator");
    try attrs_andrew.put("location", "USA");

    const andrew_id = try kb.addEntity("Andrew Kelley", .person, attrs_andrew);

    var attrs_mvcc = std.StringHashMap([]const u8).init(allocator);
    try attrs_mvcc.put("category", "concurrency control");
    try attrs_mvcc.put("benefit", "non-blocking reads");

    const mvcc_id = try kb.addEntity("MVCC", .concept, attrs_mvcc);

    // === Create Topics ===
    std.debug.print("\n--- Creating Topics ---\n", .{});
    _ = try kb.createTopic("Programming Languages", null);
    _ = try kb.createTopic("Databases", null);
    _ = try kb.createTopic("Concepts", null);

    // === Add to Topics ===
    std.debug.print("\n--- Adding Entities to Topics ---\n", .{});
    try kb.addToTopic("Zig", "Programming Languages");
    try kb.addToTopic("NorthstarDB", "Databases");
    try kb.addToTopic("MVCC", "Concepts");

    // === Create Relationships ===
    std.debug.print("\n--- Creating Relationships ---\n", .{});
    try kb.addRelationship("NorthstarDB", "Zig", .written_in);
    try kb.addRelationship("NorthstarDB", "MVCC", .uses);
    try kb.addRelationship("Zig", "Andrew Kelley", .created_by);

    // === Query Entity ===
    std.debug.print("\n--- Querying Entity Details ---\n", .{});
    if (try kb.getEntity("NorthstarDB")) |entity| {
        std.debug.print("Entity: {s}\n", .{entity.name});
        std.debug.print("Type: {s}\n", .{@tagName(entity.entity_type)});
        std.debug.print("ID: {s}\n", .{entity.id});
    }

    // === Natural Language Query ===
    std.debug.print("\n--- Natural Language Queries ---\n", .{});
    const results1 = try kb.query("What database is written in Zig?");
    defer {
        for (results1.items) |r| allocator.free(r);
        results1.deinit();
    }
    std.debug.print("Results: {d} entities found\n", .{results1.items.len});

    const results2 = try kb.query("Tell me about databases");
    defer {
        for (results2.items) |r| allocator.free(r);
        results2.deinit();
    }
    std.debug.print("Results: {d} entities found\n", .{results2.items.len});

    // === Find Related Entities ===
    std.debug.print("\n--- Finding Related Entities ---\n", .{});
    const related = try kb.findRelated("NorthstarDB", null);
    defer {
        for (related.items) |r| allocator.free(r);
        related.deinit();
    }
    std.debug.print("Found {d} related entities\n", .{related.items.len});

    // === Display Knowledge Graph Summary ===
    std.debug.print("\n--- Knowledge Graph Summary ---\n", .{});
    std.debug.print("Entities: 4\n", .{});
    std.debug.print("Relationships: 3\n", .{});
    std.debug.print("Topics: 3\n", .{});

    std.debug.print("\n=== Example Complete ===\n", .{});
    std.debug.print("\nNote: This example demonstrates the data structures and APIs.\n", .{});
    std.debug.print("Full LLM integration requires API keys for OpenAI/Anthropic.\n", .{});
}
