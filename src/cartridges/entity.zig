//! Entity cartridge implementation for structured memory storage
//!
//! Implements entity storage, indexing, and query operations according to
//! structured_memory_v1.md specification
//!
//! Features:
//! - Incremental entity updates for streaming extraction
//! - Type-based indexing
//! - Attribute-based filtering
//! - Temporal indexing for time-travel queries

const std = @import("std");

pub const EntityCartridge = struct {
    allocator: std.mem.Allocator,
    entities: std.StringHashMap(EntityRecord),
    type_index: std.StringHashMap(std.ArrayList(EntityId)),
    attribute_index: AttributeIndex,
    temporal_index: TemporalIndex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .entities = std.StringHashMap(EntityRecord).init(allocator),
            .type_index = std.StringHashMap(std.ArrayList(EntityId)).init(allocator),
            .attribute_index = try AttributeIndex.init(allocator),
            .temporal_index = try TemporalIndex.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entities.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.entities.deinit();

        var type_it = self.type_index.iterator();
        while (type_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.type_index.deinit();

        self.attribute_index.deinit();
        self.temporal_index.deinit();
    }

    pub fn add_entity(
        self: *Self,
        entity_id: EntityId,
        entity_type: EntityType,
        attributes: []Attribute,
        txn_id: u64
    ) !void {
        const entity_record = try EntityRecord.init(
            self.allocator,
            entity_id,
            entity_type,
            attributes,
            txn_id
        );

        try self.entities.put(entity_id.toString(), entity_record);

        // Update type index
        const type_list = try self.type_index.getOrPut(entity_type.toString());
        if (!type_list.found_existing) {
            type_list.value_ptr.* = std.array_list.Managed(EntityId).init(self.allocator);
        }
        try type_list.value_ptr.*.append(entity_id);

        // Update attribute index
        try self.attribute_index.index_entity(entity_id, attributes);

        // Update temporal index
        try self.temporal_index.insert(.{
            .entity_id = entity_id,
            .txn_id = txn_id,
            .operation = .create,
        });
    }

    pub fn get_entity(self: *const Self, entity_id: EntityId) ?*const EntityRecord {
        return self.entities.get(entity_id.toString());
    }

    pub fn query_entities(
        self: *const Self,
        entity_type: EntityType,
        filters: []AttributeFilter
    ) EntityIterator {
        const type_list = self.type_index.get(entity_type.toString()) orelse {
            return EntityIterator.init_empty(self.allocator);
        };

        return EntityIterator.init(self.allocator, type_list.items, filters);
    }

    pub fn update_entity(
        self: *Self,
        entity_id: EntityId,
        updates: []Attribute,
        txn_id: u64
    ) !void {
        const existing = self.entities.get(entity_id.toString()) orelse {
            return error.EntityNotFound;
        };

        // Create new version with updates
        const updated_record = try existing.create_updated_version(
            self.allocator,
            updates,
            txn_id
        );

        // Replace old record
        try self.entities.put(entity_id.toString(), updated_record);

        // Update indexes
        try self.attribute_index.update_entity(entity_id, updates);
        try self.temporal_index.insert(.{
            .entity_id = entity_id,
            .txn_id = txn_id,
            .operation = .update,
        });
    }

    /// Incrementally add entity from streaming extraction
    /// This is called during commit for real-time entity extraction
    pub fn add_entity_incremental(
        self: *Self,
        entity_id_str: []const u8,
        entity_type_str: []const u8,
        confidence: f32,
        txn_id: u64
    ) !void {
        // Parse entity ID from string format "namespace:local_id"
        const colon_idx = std.mem.indexOf(u8, entity_id_str, ":") orelse {
            return error.InvalidEntityIdFormat;
        };

        const namespace = entity_id_str[0..colon_idx];
        const local_id = entity_id_str[colon_idx + 1 ..];

        const entity_id = EntityId{
            .namespace = namespace,
            .local_id = local_id,
        };

        // Map entity type string to enum
        const entity_type = parseEntityType(entity_type_str);

        // Create minimal attribute set for streaming extraction
        const attributes = [_]Attribute{
            .{
                .key = "confidence",
                .value = .{ .float = confidence },
                .confidence = 1.0,
                .source = "streaming_extraction",
            },
        };

        // Use existing add_entity method
        try self.add_entity(entity_id, entity_type, &attributes, txn_id);
    }

    /// Parse entity type from string
    fn parseEntityType(type_str: []const u8) EntityType {
        if (std.mem.eql(u8, type_str, "file")) return .file;
        if (std.mem.eql(u8, type_str, "person")) return .person;
        if (std.mem.eql(u8, type_str, "function")) return .function;
        if (std.mem.eql(u8, type_str, "commit")) return .commit;
        if (std.mem.eql(u8, type_str, "topic")) return .topic;
        if (std.mem.eql(u8, type_str, "project")) return .project;
        return .custom;
    }

    /// Get statistics about the cartridge
    pub fn get_stats(self: *const Self) CartridgeStats {
        return CartridgeStats{
            .total_entities = self.entities.count(),
            .total_types = self.type_index.count(),
        };
    }
};

pub const EntityId = struct {
    namespace: []const u8,
    local_id: []const u8,

    pub fn toString(self: EntityId) []const u8 {
        // Implementation to create string representation
        return ""; // placeholder
    }

    pub fn parse(str: []const u8) !EntityId {
        _ = str;
        return error.NotImplemented;
    }
};

pub const EntityType = enum {
    file,
    person,
    function,
    commit,
    topic,
    project,
    custom,

    pub fn toString(self: EntityType) []const u8 {
        return @tagName(self);
    }
};

pub const EntityRecord = struct {
    id: EntityId,
    type: EntityType,
    attributes: std.StringHashMap(AttributeValue),
    created_at: u64,
    last_modified: u64,
    created_by: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        id: EntityId,
        entity_type: EntityType,
        attributes: []Attribute,
        txn_id: u64
    ) !EntityRecord {
        var attr_map = std.StringHashMap(AttributeValue).init(allocator);
        for (attributes) |attr| {
            try attr_map.put(attr.key, attr.value);
        }

        return EntityRecord{
            .id = id,
            .type = entity_type,
            .attributes = attr_map,
            .created_at = txn_id,
            .last_modified = txn_id,
            .created_by = "system",
        };
    }

    pub fn create_updated_version(
        self: *const EntityRecord,
        allocator: std.mem.Allocator,
        updates: []Attribute,
        txn_id: u64
    ) !EntityRecord {
        // Copy existing attributes
        var updated_attrs = std.StringHashMap(AttributeValue).init(allocator);

        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            try updated_attrs.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Apply updates
        for (updates) |update| {
            try updated_attrs.put(update.key, update.value);
        }

        return EntityRecord{
            .id = self.id,
            .type = self.type,
            .attributes = updated_attrs,
            .created_at = self.created_at,
            .last_modified = txn_id,
            .created_by = self.created_by,
        };
    }

    pub fn deinit(self: *EntityRecord) void {
        self.attributes.deinit();
    }

    pub fn get_attribute(self: *const EntityRecord, key: []const u8) ?AttributeValue {
        return self.attributes.get(key);
    }
};

pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,
    confidence: f32 = 1.0,
    source: []const u8 = "unknown",
};

pub const AttributeValue = union {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: std.ArrayList(AttributeValue),
    object: std.StringHashMap(AttributeValue),
};

pub const AttributeFilter = struct {
    key: []const u8,
    operator: FilterOperator,
    value: AttributeValue,

    pub const FilterOperator = enum {
        equals,
        not_equals,
        contains,
        starts_with,
        ends_with,
        greater_than,
        less_than,
    };
};

pub const EntityIterator = struct {
    allocator: std.mem.Allocator,
    entity_ids: []EntityId,
    filters: []AttributeFilter,
    current_index: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        entity_ids: []EntityId,
        filters: []AttributeFilter
    ) EntityIterator {
        return EntityIterator{
            .allocator = allocator,
            .entity_ids = entity_ids,
            .filters = filters,
            .current_index = 0,
        };
    }

    pub fn init_empty(allocator: std.mem.Allocator) EntityIterator {
        return EntityIterator{
            .allocator = allocator,
            .entity_ids = &[_]EntityId{},
            .filters = &[_]AttributeFilter{},
            .current_index = 0,
        };
    }

    pub fn next(self: *EntityIterator) ?EntityId {
        if (self.current_index >= self.entity_ids.len) {
            return null;
        }

        const entity_id = self.entity_ids[self.current_index];
        self.current_index += 1;

        // Apply filters (simplified - in real implementation would check against actual entities)
        // For now, just return the entity ID
        return entity_id;
    }
};

// Placeholder index implementations
pub const AttributeIndex = struct {
    pub fn init(allocator: std.mem.Allocator) !AttributeIndex {
        _ = allocator;
        return error.NotImplemented;
    }

    pub fn deinit(self: *AttributeIndex) void {
        _ = self;
    }

    pub fn index_entity(
        self: *AttributeIndex,
        entity_id: EntityId,
        attributes: []Attribute
    ) !void {
        _ = self;
        _ = entity_id;
        _ = attributes;
        return error.NotImplemented;
    }

    pub fn update_entity(
        self: *AttributeIndex,
        entity_id: EntityId,
        updates: []Attribute
    ) !void {
        _ = self;
        _ = entity_id;
        _ = updates;
        return error.NotImplemented;
    }
};

pub const TemporalIndex = struct {
    pub fn init(allocator: std.mem.Allocator) !TemporalIndex {
        _ = allocator;
        return error.NotImplemented;
    }

    pub fn deinit(self: *TemporalIndex) void {
        _ = self;
    }

    pub fn insert(self: *TemporalIndex, entry: TemporalEntry) !void {
        _ = self;
        _ = entry;
        return error.NotImplemented;
    }

    pub const TemporalEntry = struct {
        entity_id: EntityId,
        txn_id: u64,
        operation: Operation,
    };

    pub const Operation = enum {
        create,
        update,
        delete,
    };
};

/// Cartridge statistics
pub const CartridgeStats = struct {
    total_entities: usize,
    total_types: usize,
};

test "entity_cartridge_basic_operations" {
    var cartridge = try EntityCartridge.init(std.testing.allocator);
    defer cartridge.deinit();

    const entity_id = EntityId{
        .namespace = "file",
        .local_id = "main.zig",
    };

    const attributes = [_]Attribute{
        .{
            .key = "size",
            .value = .{ .integer = 1024 },
        },
        .{
            .key = "language",
            .value = .{ .string = "zig" },
        },
    };

    try cartridge.add_entity(entity_id, .file, &attributes, 12345);

    const retrieved = cartridge.get_entity(entity_id).?;
    try std.testing.expect(EntityType.file == retrieved.type);
    try std.testing.expectEqual(@as(i64, 1024), retrieved.get_attribute("size").?.integer);
    try std.testing.expectEqualStrings("zig", retrieved.get_attribute("language").?.string);
}

test "entity_iterator" {
    var cartridge = try EntityCartridge.init(std.testing.allocator);
    defer cartridge.deinit();

    // Add some test entities
    const entities = [_]EntityId{
        .{ .namespace = "file", .local_id = "test1.zig" },
        .{ .namespace = "file", .local_id = "test2.zig" },
    };

    for (entities) |entity_id| {
        try cartridge.add_entity(entity_id, .file, &[_]Attribute{}, 1);
    }

    const filters = [_]AttributeFilter{};
    var iterator = cartridge.query_entities(.file, &filters);

    var count: usize = 0;
    while (iterator.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "add_entity_incremental" {
    var cartridge = try EntityCartridge.init(std.testing.allocator);
    defer cartridge.deinit();

    // Test incremental entity addition
    try cartridge.add_entity_incremental("file:main.zig", "file", 0.95, 100);
    try cartridge.add_entity_incremental("user:alice", "person", 0.88, 101);
    try cartridge.add_entity_incremental("commit:abc123", "commit", 0.92, 102);

    const stats = cartridge.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.total_entities);

    // Verify the file entity was added correctly
    const file_entity_id = EntityId{
        .namespace = "file",
        .local_id = "main.zig",
    };
    const file_entity = cartridge.get_entity(file_entity_id);
    try std.testing.expect(file_entity != null);
    try std.testing.expect(EntityType.file == file_entity.?.type);

    // Verify confidence attribute
    const confidence_attr = file_entity.?.get_attribute("confidence");
    try std.testing.expect(confidence_attr != null);
    try std.testing.expectEqual(@as(f64, 0.95), confidence_attr.?.float);
}

test "cartridge_stats" {
    var cartridge = try EntityCartridge.init(std.testing.allocator);
    defer cartridge.deinit();

    var stats = cartridge.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total_entities);
    try std.testing.expectEqual(@as(usize, 0), stats.total_types);

    // Add entities of different types
    try cartridge.add_entity_incremental("file:a.zig", "file", 0.9, 1);
    try cartridge.add_entity_incremental("file:b.zig", "file", 0.9, 2);
    try cartridge.add_entity_incremental("user:alice", "person", 0.8, 3);

    stats = cartridge.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.total_entities);
    try std.testing.expectEqual(@as(usize, 2), stats.total_types); // file and person
}
