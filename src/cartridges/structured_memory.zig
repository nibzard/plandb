//! Structured Memory Cartridge Format Implementation
//!
//! Implements entity, topic, and relationship storage for the Living Database
//! according to spec/structured_memory_v1.md and spec/cartridge_format_v1.md
//!
//! This module provides the on-disk format and in-memory structures for
//! AI-extracted structured memory with deterministic function calling.

const std = @import("std");
const format = @import("format.zig");
const ArrayListManaged = std.ArrayListUnmanaged;

// ==================== Core Types ====================

/// Unique identifier for entities across namespaces
pub const EntityId = struct {
    /// Namespace for disambiguation (e.g., "file", "person", "function")
    namespace: []const u8,
    /// Local identifier within namespace (e.g., "src/main.zig", "niko")
    local_id: []const u8,

    /// Create string representation: "namespace:local_id"
    pub fn toString(id: EntityId, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ id.namespace, id.local_id });
    }

    /// Parse from string format "namespace:local_id"
    pub fn parse(str: []const u8, allocator: std.mem.Allocator) !EntityId {
        const colon_idx = std.mem.indexOfScalar(u8, str, ':') orelse return error.InvalidEntityIdFormat;
        return EntityId{
            .namespace = try allocator.dupe(u8, str[0..colon_idx]),
            .local_id = try allocator.dupe(u8, str[colon_idx + 1 ..]),
        };
    }

    /// Hash function for HashMap usage
    pub fn hash(id: EntityId) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(id.namespace);
        hasher.update(":");
        hasher.update(id.local_id);
        return hasher.final();
    }

    /// Compare two EntityIds for equality
    pub fn eql(a: EntityId, b: EntityId) bool {
        return std.mem.eql(u8, a.namespace, b.namespace) and
               std.mem.eql(u8, a.local_id, b.local_id);
    }
};

/// Context for HashMap with EntityId keys
pub const EntityIdContext = struct {
    pub fn hash(self: @This(), id: EntityId) u64 {
        _ = self;
        return EntityId.hash(id);
    }

    pub fn eql(self: @This(), a: EntityId, b: EntityId) bool {
        _ = self;
        return EntityId.eql(a, b);
    }
};

/// Entity type classification
pub const EntityType = enum(u8) {
    file = 1,
    person = 2,
    function = 3,
    commit = 4,
    topic = 5,
    project = 6,
    repository = 7,
    issue = 8,
    pull_request = 9,
    custom = 255,

    pub fn fromUint(v: u8) !EntityType {
        return std.meta.intToEnum(EntityType, v);
    }

    pub fn toUint(et: EntityType) u8 {
        return @intFromEnum(et);
    }
};

/// Attribute value types
pub const AttributeValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    string_array: ArrayListManaged([]const u8),
    integer_array: ArrayListManaged(i64),

    pub fn deinit(self: *AttributeValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .string_array => |*arr| {
                for (arr.items) |item| allocator.free(item);
                arr.deinit(allocator);
            },
            .integer_array => |*arr| arr.deinit(allocator),
            else => {},
        }
    }

    /// Serialize value to byte stream
    pub fn serialize(self: AttributeValue, writer: anytype) !void {
        // Write value type byte
        const type_byte: u8 = switch (self) {
            .string => @intFromEnum(ValueType.string),
            .integer => @intFromEnum(ValueType.integer),
            .float => @intFromEnum(ValueType.float),
            .boolean => @intFromEnum(ValueType.boolean),
            .string_array => @intFromEnum(ValueType.string_array),
            .integer_array => @intFromEnum(ValueType.integer_array),
        };
        try writer.writeByte(type_byte);

        switch (self) {
            .string => |s| {
                try writer.writeInt(u16, @intCast(s.len), .little);
                try writer.writeAll(s);
            },
            .integer => |i| try writer.writeInt(i64, i, .little),
            .float => |f| try writer.writeInt(u64, @bitCast(f), .little),
            .boolean => |b| try writer.writeByte(@intFromBool(b)),
            .string_array => |*arr| {
                try writer.writeInt(u16, @intCast(arr.items.len), .little);
                for (arr.items) |item| {
                    try writer.writeInt(u16, @intCast(item.len), .little);
                    try writer.writeAll(item);
                }
            },
            .integer_array => |*arr| {
                try writer.writeInt(u16, @intCast(arr.items.len), .little);
                for (arr.items) |item| {
                    try writer.writeInt(i64, item, .little);
                }
            },
        }
    }

    /// Deserialize value from byte stream
    pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !AttributeValue {
        const type_byte = try reader.readByte();
        const value_type = std.meta.intToEnum(ValueType, type_byte) catch return error.InvalidAttributeType;

        switch (value_type) {
            .string => {
                const len = try reader.readInt(u16, .little);
                const str = try allocator.alloc(u8, len);
                try reader.readNoEof(str);
                return AttributeValue{ .string = str };
            },
            .integer => {
                const val = try reader.readInt(i64, .little);
                return AttributeValue{ .integer = val };
            },
            .float => {
                const bits = try reader.readInt(u64, .little);
                return AttributeValue{ .float = @bitCast(bits) };
            },
            .boolean => {
                const val = try reader.readByte();
                return AttributeValue{ .boolean = val != 0 };
            },
            .string_array => {
                const len = try reader.readInt(u16, .little);
                var arr = ArrayListManaged([]const u8){};
                try arr.ensureTotalCapacity(allocator, len);
                var i: u16 = 0;
                while (i < len) : (i += 1) {
                    const item_len = try reader.readInt(u16, .little);
                    const item = try allocator.alloc(u8, item_len);
                    try reader.readNoEof(item);
                    arr.appendAssumeCapacity(item);
                }
                return AttributeValue{ .string_array = arr };
            },
            .integer_array => {
                const len = try reader.readInt(u16, .little);
                var arr = ArrayListManaged(i64){};
                try arr.ensureTotalCapacity(allocator, len);
                var i: u16 = 0;
                while (i < len) : (i += 1) {
                    const val = try reader.readInt(i64, .little);
                    arr.appendAssumeCapacity(val);
                }
                return AttributeValue{ .integer_array = arr };
            },
        }
    }

    pub const ValueType = enum(u8) {
        string = 1,
        integer = 2,
        float = 3,
        boolean = 4,
        string_array = 5,
        integer_array = 6,
    };
};

/// Entity attribute with confidence scoring
pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,
    confidence: f32 = 1.0,
    source: []const u8 = "unknown",

    pub fn deinit(self: *Attribute, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
        allocator.free(self.source);
    }

    pub fn serializedSize(self: Attribute) usize {
        var size: usize = 2 + self.key.len; // key length + key
        size += 1; // value type
        size += self.serializedValueSize();
        size += 4; // confidence
        size += 2 + self.source.len; // source length + source
        return size;
    }

    fn serializedValueSize(self: Attribute) usize {
        return switch (self.value) {
            .string => |s| 2 + s.len,
            .integer => 8,
            .float => 8,
            .boolean => 1,
            .string_array => |*arr| blk: {
                var total: usize = 2; // array length
                for (arr.items) |item| {
                    total += 2 + item.len;
                }
                break :blk total;
            },
            .integer_array => |*arr| 2 + (8 * arr.items.len),
        };
    }
};

/// Full entity record with all metadata
pub const Entity = struct {
    id: EntityId,
    type: EntityType,
    attributes: ArrayListManaged(Attribute),
    created_at: u64,
    last_modified: u64,
    confidence: f32,
    created_by: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        id: EntityId,
        entity_type: EntityType,
        created_by: []const u8,
        txn_id: u64
   ) !Entity {
        const namespace = try allocator.dupe(u8, id.namespace);
        errdefer allocator.free(namespace);

        const local_id = try allocator.dupe(u8, id.local_id);
        errdefer allocator.free(local_id);

        return Entity{
            .id = .{
                .namespace = namespace,
                .local_id = local_id,
            },
            .type = entity_type,
            .attributes = .{},
            .created_at = txn_id,
            .last_modified = txn_id,
            .confidence = 1.0,
            .created_by = allocator.dupe(u8, created_by) catch "",
        };
    }

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        allocator.free(self.id.namespace);
        allocator.free(self.id.local_id);
        for (self.attributes.items) |*attr| attr.deinit(allocator);
        self.attributes.deinit(allocator);
        allocator.free(self.created_by);
    }

    pub fn addAttribute(self: *Entity, allocator: std.mem.Allocator, attr: Attribute) !void {
        const attr_copy = Attribute{
            .key = try allocator.dupe(u8, attr.key),
            .value = try dupeAttributeValue(allocator, attr.value),
            .confidence = attr.confidence,
            .source = try allocator.dupe(u8, attr.source),
        };
        try self.attributes.append(allocator, attr_copy);
    }

    pub fn getAttribute(self: *const Entity, key: []const u8) ?*const Attribute {
        for (self.attributes.items) |*attr| {
            if (std.mem.eql(u8, attr.key, key)) return attr;
        }
        return null;
    }

    /// Calculate serialized size for storage
    pub fn serializedSize(self: Entity) usize {
        var size: usize = 2; // flags + entity type
        size += 4; // confidence
        size += 8; // created_at
        size += 8; // last_modified
        size += 2 + self.id.namespace.len; // namespace length + namespace
        size += 2 + self.id.local_id.len; // local_id length + local_id
        size += 2; // attribute count
        for (self.attributes.items) |attr| {
            size += attr.serializedSize();
        }
        return size;
    }

    /// Serialize entity to byte stream
    pub fn serialize(self: Entity, writer: anytype) !void {
        const flags: u8 = 0;
        try writer.writeByte(flags);
        try writer.writeByte(@intFromEnum(self.type));
        try writer.writeInt(u32, @bitCast(self.confidence), .little);
        try writer.writeInt(u64, self.created_at, .little);
        try writer.writeInt(u64, self.last_modified, .little);
        try writer.writeInt(u16, @intCast(self.id.namespace.len), .little);
        try writer.writeAll(self.id.namespace);
        try writer.writeInt(u16, @intCast(self.id.local_id.len), .little);
        try writer.writeAll(self.id.local_id);
        try writer.writeInt(u16, @intCast(self.attributes.items.len), .little);
        for (self.attributes.items) |attr| {
            try writer.writeInt(u16, @intCast(attr.key.len), .little);
            try writer.writeAll(attr.key);
            try attr.value.serialize(writer);
            try writer.writeInt(u32, @bitCast(attr.confidence), .little);
            try writer.writeInt(u16, @intCast(attr.source.len), .little);
            try writer.writeAll(attr.source);
        }
    }
};

fn dupeAttributeValue(allocator: std.mem.Allocator, value: AttributeValue) !AttributeValue {
    return switch (value) {
        .string => |s| AttributeValue{ .string = try allocator.dupe(u8, s) },
        .integer => |i| AttributeValue{ .integer = i },
        .float => |f| AttributeValue{ .float = f },
        .boolean => |b| AttributeValue{ .boolean = b },
        .string_array => |*arr| blk: {
            var new_arr = ArrayListManaged([]const u8){};
            try new_arr.ensureTotalCapacity(allocator, arr.items.len);
            for (arr.items) |item| {
                const dupe = try allocator.dupe(u8, item);
                new_arr.appendAssumeCapacity(dupe);
            }
            break :blk AttributeValue{ .string_array = new_arr };
        },
        .integer_array => |*arr| blk: {
            var new_arr = ArrayListManaged(i64){};
            try new_arr.ensureTotalCapacity(allocator, arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(item);
            }
            break :blk AttributeValue{ .integer_array = new_arr };
        },
    };
}

// ==================== Topic Types ====================

/// Topic identifier with hierarchical path
pub const TopicId = struct {
    /// Dot-separated path (e.g., "database.performance.btree")
    path: []const u8,

    pub fn init(path: []const u8) TopicId {
        return TopicId{ .path = path };
    }

    pub fn deinit(self: TopicId, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    /// Create hierarchical topic ID from components
    pub fn fromComponents(allocator: std.mem.Allocator, components: []const []const u8) !TopicId {
        var total_len: usize = 0;
        for (components, 0..) |comp, i| {
            total_len += comp.len;
            if (i < components.len - 1) total_len += 1; // dot separator
        }
        var path = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (components, 0..) |comp, i| {
            @memcpy(path[pos..][0..comp.len], comp);
            pos += comp.len;
            if (i < components.len - 1) {
                path[pos] = '.';
                pos += 1;
            }
        }
        return TopicId{ .path = path };
    }

    pub fn eql(a: TopicId, b: TopicId) bool {
        return std.mem.eql(u8, a.path, b.path);
    }

    pub fn hash(id: TopicId) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(id.path);
        return hasher.final();
    }
};

/// Transaction pointer with relevance scoring
pub const TxnPointer = struct {
    txn_id: u64,
    relevance: f32,
    offset: ?u64 = null,

    pub fn serializedSize() usize {
        return 8 + 4 + 8; // txn_id + relevance + offset
    }

    pub fn serialize(self: TxnPointer, writer: anytype) !void {
        try writer.writeInt(u64, self.txn_id, .little);
        try writer.writeInt(u32, @bitCast(self.relevance), .little);
        try writer.writeInt(u64, self.offset orelse 0, .little);
    }
};

/// Topic with hierarchical organization
pub const Topic = struct {
    id: TopicId,
    name: []const u8,
    parent: ?TopicId,
    children: ArrayListManaged(TopicId),
    back_pointers: ArrayListManaged(TxnPointer),
    term_frequency: u32,
    related_topics: ArrayListManaged(TopicId),

    pub fn init(allocator: std.mem.Allocator, id: TopicId, name: []const u8) !Topic {
        const id_path = try allocator.dupe(u8, id.path);
        errdefer allocator.free(id_path);

        return Topic{
            .id = .{ .path = id_path },
            .name = try allocator.dupe(u8, name),
            .parent = null,
            .children = .{},
            .back_pointers = .{},
            .term_frequency = 1,
            .related_topics = .{},
        };
    }

    pub fn deinit(self: *Topic, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        allocator.free(self.name);
        if (self.parent) |p| p.deinit(allocator);
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
        self.back_pointers.deinit(allocator);
        for (self.related_topics.items) |*rel| rel.deinit(allocator);
        self.related_topics.deinit(allocator);
    }

    pub fn addChild(self: *Topic, allocator: std.mem.Allocator, child_id: TopicId) !void {
        // Duplicate the topic ID for storage
        const dupe = TopicId{
            .path = try allocator.dupe(u8, child_id.path),
        };
        try self.children.append(allocator, dupe);
    }

    pub fn addBackPointer(self: *Topic, allocator: std.mem.Allocator, pointer: TxnPointer) !void {
        try self.back_pointers.append(allocator, pointer);
    }
};

// ==================== Relationship Types ====================

/// Relationship type classification
pub const RelationshipType = enum(u8) {
    // Code/file relationships
    imports = 1,
    calls = 2,
    implements = 3,
    extends = 4,
    depends_on = 5,
    modifies = 6,
    // People relationships
    authored_by = 10,
    reviewed_by = 11,
    assigned_to = 12,
    mentioned = 13,
    // Semantic relationships
    related_to = 20,
    similar_to = 21,
    part_of = 22,
    references = 23,
    custom = 255,
};

/// Relationship between two entities
pub const Relationship = struct {
    from_entity: EntityId,
    to_entity: EntityId,
    type: RelationshipType,
    strength: f32,
    established_at: u64,
    metadata: ArrayListManaged(Attribute),

    pub fn init(
        allocator: std.mem.Allocator,
        from: EntityId,
        to: EntityId,
        rel_type: RelationshipType,
        strength: f32,
        txn_id: u64
    ) !Relationship {
        const from_namespace = try allocator.dupe(u8, from.namespace);
        errdefer allocator.free(from_namespace);

        const from_local = try allocator.dupe(u8, from.local_id);
        errdefer allocator.free(from_local);

        const to_namespace = try allocator.dupe(u8, to.namespace);
        errdefer allocator.free(to_namespace);

        const to_local = try allocator.dupe(u8, to.local_id);
        errdefer allocator.free(to_local);

        return Relationship{
            .from_entity = .{
                .namespace = from_namespace,
                .local_id = from_local,
            },
            .to_entity = .{
                .namespace = to_namespace,
                .local_id = to_local,
            },
            .type = rel_type,
            .strength = strength,
            .established_at = txn_id,
            .metadata = .{},
        };
    }

    pub fn deinit(self: *Relationship, allocator: std.mem.Allocator) void {
        allocator.free(self.from_entity.namespace);
        allocator.free(self.from_entity.local_id);
        allocator.free(self.to_entity.namespace);
        allocator.free(self.to_entity.local_id);
        for (self.metadata.items) |*attr| attr.deinit(allocator);
        self.metadata.deinit(allocator);
    }

    pub fn addMetadata(self: *Relationship, allocator: std.mem.Allocator, attr: Attribute) !void {
        const attr_copy = Attribute{
            .key = try allocator.dupe(u8, attr.key),
            .value = try dupeAttributeValue(allocator, attr.value),
            .confidence = attr.confidence,
            .source = try allocator.dupe(u8, attr.source),
        };
        try self.metadata.append(allocator, attr_copy);
    }

    /// Add metadata to a const relationship (returns new relationship)
    pub fn withMetadata(self: Relationship, allocator: std.mem.Allocator, attr: Attribute) !Relationship {
        var result = try Relationship.init(
            allocator,
            self.from_entity,
            self.to_entity,
            self.type,
            self.strength,
            self.established_at
        );
        errdefer result.deinit(allocator);

        for (self.metadata.items) |*meta| {
            try result.addMetadata(allocator, meta.*);
        }
        try result.addMetadata(allocator, attr);

        return result;
    }
};

// ==================== Cartridge Storage ====================

/// Entity index cartridge
pub const EntityIndexCartridge = struct {
    allocator: std.mem.Allocator,
    header: format.CartridgeHeader,
    entities: std.StringHashMap(EntityOffset),
    entity_data: ArrayListManaged(EntityRecord),

    const EntityOffset = struct {
        offset: u64,
        size: u64,
    };

    const EntityRecord = struct {
        entity: Entity,
        offset: u64,
    };

    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64) !EntityIndexCartridge {
        const header = format.CartridgeHeader.init(.entity_index, source_txn_id);
        return EntityIndexCartridge{
            .allocator = allocator,
            .header = header,
            .entities = std.StringHashMap(EntityOffset).init(allocator),
            .entity_data = .{},
        };
    }

    pub fn deinit(self: *EntityIndexCartridge) void {
        var it = self.entities.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entities.deinit();
        for (self.entity_data.items) |*rec| rec.entity.deinit(self.allocator);
        self.entity_data.deinit(self.allocator);
    }

    pub fn addEntity(self: *EntityIndexCartridge, entity: Entity) !void {
        const id_str = try entity.id.toString(self.allocator);
        errdefer self.allocator.free(id_str);

        const entity_copy = try dupeEntity(self.allocator, entity);
        errdefer {
            var mut_copy = entity_copy;
            mut_copy.deinit(self.allocator);
        }

        try self.entity_data.append(self.allocator, .{
            .entity = entity_copy,
            .offset = 0, // Set during write
        });

        try self.entities.put(id_str, .{
            .offset = 0,
            .size = entity.serializedSize(),
        });

        self.header.entry_count += 1;
    }

    pub fn getEntity(self: *const EntityIndexCartridge, id: EntityId) ?*Entity {
        const id_str = blk: {
            const str = id.toString(self.allocator) catch return null;
            defer self.allocator.free(str);
            break :blk str;
        };
        const offset = self.entities.get(id_str) orelse return null;
        if (offset.offset == 0) return null; // Not yet written
        // In full implementation, would read from mapped data
        return null;
    }

    fn dupeEntity(allocator: std.mem.Allocator, entity: Entity) !Entity {
        var new_entity = Entity{
            .id = .{
                .namespace = try allocator.dupe(u8, entity.id.namespace),
                .local_id = try allocator.dupe(u8, entity.id.local_id),
            },
            .type = entity.type,
            .attributes = .{},
            .created_at = entity.created_at,
            .last_modified = entity.last_modified,
            .confidence = entity.confidence,
            .created_by = try allocator.dupe(u8, entity.created_by),
        };

        try new_entity.attributes.ensureTotalCapacity(allocator, entity.attributes.items.len);
        for (entity.attributes.items) |attr| {
            const attr_copy = Attribute{
                .key = try allocator.dupe(u8, attr.key),
                .value = try dupeAttributeValue(allocator, attr.value),
                .confidence = attr.confidence,
                .source = try allocator.dupe(u8, attr.source),
            };
            new_entity.attributes.appendAssumeCapacity(attr_copy);
        }

        return new_entity;
    }

    pub fn writeToFile(self: *EntityIndexCartridge, path: []const u8) !void {
        // Calculate sizes
        const header_size = format.CartridgeHeader.SIZE;
        const data_size = self.calculateDataSize();
        const metadata_size = self.calculateMetadataSize();
        const total_size = header_size + data_size + metadata_size;

        // Allocate buffer
        var buffer = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(buffer);

        var pos: usize = 0;

        // Write header
        var header_fbs = std.io.fixedBufferStream(buffer[pos..]);
        try self.header.serialize(header_fbs.writer());
        pos += header_size;

        // Write data section
        self.header.data_offset = @intCast(pos);
        var data_fbs = std.io.fixedBufferStream(buffer[pos .. pos + data_size]);
        try self.writeDataSection(data_fbs.writer());
        pos += data_size;

        // Write metadata
        self.header.metadata_offset = @intCast(pos);
        var metadata_fbs = std.io.fixedBufferStream(buffer[pos..]);
        try self.writeMetadataSection(metadata_fbs.writer());

        // Write to file
        const file = try std.fs.cwd().createFile(path, .{ .read = true });
        defer file.close();
        try file.writeAll(buffer);
    }

    fn calculateDataSize(self: *const EntityIndexCartridge) usize {
        var size: usize = 0;
        for (self.entity_data.items) |*rec| {
            size += rec.entity.serializedSize();
        }
        return size;
    }

    fn writeDataSection(self: *EntityIndexCartridge, writer: anytype) !void {
        for (self.entity_data.items) |*rec| {
            try rec.entity.serialize(writer);
        }
    }

    fn calculateMetadataSize() usize {
        return 32 + 12 + 8 + 32 + 32; // Basic metadata size
    }

    fn writeMetadataSection(writer: anytype) !void {
        // Format name
        var name_buf: [32]u8 = [_]u8{0} ** 32;
        const format_name = "entity_index_v1";
        @memcpy(name_buf[0..format_name.len], format_name);
        try writer.writeAll(&name_buf);

        // Schema version
        try writer.writeInt(u32, 1, .little);
        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u32, 0, .little);

        // Build time
        try writer.writeInt(u64, 0, .little);

        // Source hash (placeholder)
        var hash_buf: [32]u8 = [_]u8{0} ** 32;
        try writer.writeAll(&hash_buf);

        // Builder version
        var builder_buf: [32]u8 = [_]u8{0} ** 32;
        const builder = "northstar.structured_memory.v1";
        @memcpy(builder_buf[0..builder.len], builder);
        try writer.writeAll(&builder_buf);
    }
};

// ==================== Inverted Index (Topic Cartridge) ====================

/// Term posting with entity reference and relevance
pub const TermPosting = struct {
    entity_id: EntityId,
    frequency: u16,
    relevance_score: f32,
    timestamp: u64,
    positions: ArrayListManaged(u32),

    pub fn init(
        allocator: std.mem.Allocator,
        entity: EntityId,
        txn_id: u64
    ) !TermPosting {
        const ns = try allocator.dupe(u8, entity.namespace);
        errdefer allocator.free(ns);
        const local = try allocator.dupe(u8, entity.local_id);
        errdefer allocator.free(local);

        return TermPosting{
            .entity_id = .{ .namespace = ns, .local_id = local },
            .frequency = 1,
            .relevance_score = 1.0,
            .timestamp = txn_id,
            .positions = .{},
        };
    }

    pub fn deinit(self: *TermPosting, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id.namespace);
        allocator.free(self.entity_id.local_id);
        self.positions.deinit(allocator);
    }

    pub fn addPosition(self: *TermPosting, allocator: std.mem.Allocator, pos: u32) !void {
        try self.positions.append(allocator, pos);
        self.frequency += 1;
    }
};

/// Term data with posting list offset and statistics
pub const TermData = struct {
    term: []const u8,
    posting_offset: u64,
    document_frequency: u32,
    total_frequency: u64,
    last_updated: u64,

    pub fn init(allocator: std.mem.Allocator, term: []const u8) !TermData {
        return TermData{
            .term = try allocator.dupe(u8, term),
            .posting_offset = 0,
            .document_frequency = 0,
            .total_frequency = 0,
            .last_updated = 0,
        };
    }

    pub fn deinit(self: *TermData, allocator: std.mem.Allocator) void {
        allocator.free(self.term);
    }
};

/// Trie node for efficient term lookup and prefix search
pub const TrieNode = struct {
    character: u8,
    children: std.AutoHashMap(u8, *TrieNode),
    term_data: ?*TermData,
    frequency: u32,

    pub fn init(allocator: std.mem.Allocator, char: u8) !*TrieNode {
        const node = try allocator.create(TrieNode);
        node.* = TrieNode{
            .character = char,
            .children = std.AutoHashMap(u8, *TrieNode).init(allocator),
            .term_data = null,
            .frequency = 0,
        };
        return node;
    }

    pub fn deinit(self: *TrieNode, allocator: std.mem.Allocator) void {
        var it = self.children.valueIterator();
        while (it.next()) |child_ptr| {
            child_ptr.*.deinit(allocator);
        }
        self.children.deinit();
        if (self.term_data) |td| {
            td.deinit(allocator);
            allocator.destroy(td);
        }
        allocator.destroy(self);
    }

    /// Insert a term and return its term data (creating if needed)
    pub fn insert(self: *TrieNode, allocator: std.mem.Allocator, term: []const u8) !*TermData {
        var current = self;

        for (term) |ch| {
            const child_ptr = try current.children.getOrPut(ch);
            if (!child_ptr.found_existing) {
                child_ptr.value_ptr.* = try TrieNode.init(allocator, ch);
            }
            current = child_ptr.value_ptr.*;
        }

        if (current.term_data == null) {
            const td = try allocator.create(TermData);
            td.* = try TermData.init(allocator, term);
            current.term_data = td;
        }

        current.frequency += 1;
        return current.term_data.?;
    }

    /// Lookup a term in the trie
    pub fn lookup(self: *const TrieNode, term: []const u8) ?*TermData {
        var current = self;

        for (term) |ch| {
            const child = current.children.get(ch) orelse return null;
            current = child;
        }

        return current.term_data;
    }

    /// Find all terms with a given prefix
    pub fn findPrefix(self: *const TrieNode, prefix: []const u8, allocator: std.mem.Allocator) !ArrayListManaged([]const u8) {
        var results = ArrayListManaged([]const u8){};
        var current = self;

        // Navigate to prefix end
        for (prefix) |ch| {
            const child = current.children.get(ch) orelse return results;
            current = child;
        }

        // Collect all terms from this point
        var buffer = ArrayListManaged(u8){};
        buffer.appendSlice(allocator, prefix) catch return results;
        defer buffer.deinit(allocator);

        try self.collectTerms(current, &buffer, allocator, &results);
        return results;
    }

    fn collectTerms(self: *const TrieNode, node: *const TrieNode, buffer: *ArrayListManaged(u8), allocator: std.mem.Allocator, results: *ArrayListManaged([]const u8)) !void {
        if (node.term_data) |td| {
            const term_copy = try allocator.dupe(u8, td.term);
            try results.append(allocator, term_copy);
        }

        var it = node.children.iterator();
        while (it.next()) |entry| {
            try buffer.append(allocator, entry.key_ptr.*);
            try self.collectTerms(entry.value_ptr.*, buffer, allocator, results);
            _ = buffer.pop();
        }
    }
};

/// Topic cartridge with inverted index
pub const TopicCartridge = struct {
    allocator: std.mem.Allocator,
    header: format.CartridgeHeader,
    term_dict: *TrieNode,
    posting_lists: ArrayListManaged(ArrayListManaged(TermPosting)),
    total_documents: u64,

    /// Create new topic cartridge
    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64) !TopicCartridge {
        const header = format.CartridgeHeader.init(.topic_index, source_txn_id);
        return TopicCartridge{
            .allocator = allocator,
            .header = header,
            .term_dict = try TrieNode.init(allocator, 0),
            .posting_lists = .{},
            .total_documents = 0,
        };
    }

    pub fn deinit(self: *TopicCartridge) void {
        self.term_dict.deinit(self.allocator);
        for (self.posting_lists.items) |*list| {
            for (list.items) |*posting| posting.deinit(self.allocator);
            list.deinit(self.allocator);
        }
        self.posting_lists.deinit(self.allocator);
    }

    /// Add entity terms to the inverted index
    pub fn addEntityTerms(
        self: *TopicCartridge,
        entity_id: EntityId,
        terms: []const []const u8,
        txn_id: u64
    ) !void {
        for (terms) |term| {
            // Get or create term data
            const term_data = try self.term_dict.insert(self.allocator, term);

            // Assign posting offset if this is a new term
            if (term_data.document_frequency == 0 and term_data.total_frequency == 0) {
                term_data.posting_offset = self.posting_lists.items.len;
                try self.posting_lists.append(self.allocator, .{});
            }

            const posting_list = &self.posting_lists.items[term_data.posting_offset];

            // Check if entity already has a posting for this term
            var found = false;
            for (posting_list.items) |*posting| {
                if (EntityId.eql(posting.entity_id, entity_id)) {
                    posting.frequency += 1;
                    posting.timestamp = txn_id;
                    term_data.total_frequency += 1;
                    found = true;
                    break;
                }
            }

            // Add new posting if not found
            if (!found) {
                const posting = try TermPosting.init(self.allocator, entity_id, txn_id);
                try posting_list.append(self.allocator, posting);
                term_data.document_frequency += 1;
                term_data.total_frequency += 1;
                self.header.entry_count += 1;
            }
        }
    }

    /// Search for entities matching terms
    pub fn searchByTopic(
        self: *const TopicCartridge,
        query_terms: []const []const u8,
        limit: usize
    ) !ArrayListManaged(EntityResult) {
        var results = ArrayListManaged(EntityResult){};
        if (query_terms.len == 0) return results;

        // Score entities by term frequency
        var scores = std.HashMap(EntityId, f32, EntityIdContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer scores.deinit();

        // Collect postings from all query terms
        for (query_terms) |term| {
            if (self.term_dict.lookup(term)) |term_data| {
                if (term_data.posting_offset < self.posting_lists.items.len) {
                    const postings = &self.posting_lists.items[term_data.posting_offset];
                    for (postings.items) |posting| {
                        const current_score = scores.get(posting.entity_id) orelse 0;
                        const boost = @as(f32, @floatFromInt(posting.frequency));
                        const ns = try self.allocator.dupe(u8, posting.entity_id.namespace);
                        errdefer self.allocator.free(ns);
                        const local = try self.allocator.dupe(u8, posting.entity_id.local_id);
                        errdefer self.allocator.free(local);

                        const eid = EntityId{ .namespace = ns, .local_id = local };
                        try scores.put(eid, current_score + boost * posting.relevance_score);
                    }
                }
            }
        }

        // Convert to results and sort - take ownership of keys from HashMap
        var it = scores.iterator();
        while (it.next()) |entry| {
            const result = EntityResult{
                .entity_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
            };
            try results.append(self.allocator, result);
        }

        // Sort by score (descending)
        sortResults(results.items);

        // Limit results
        if (results.items.len > limit) {
            for (results.items[limit..]) |*r| {
                self.allocator.free(r.entity_id.namespace);
                self.allocator.free(r.entity_id.local_id);
            }
            results.items.len = limit;
        }

        return results;
    }

    /// Get term frequency statistics
    pub fn getTermStats(self: *const TopicCartridge, term: []const u8) ?TermStats {
        const term_data = self.term_dict.lookup(term) orelse return null;

        var entity_count: u32 = 0;
        var total_occurrences: u64 = 0;

        if (term_data.posting_offset < self.posting_lists.items.len) {
            const postings = &self.posting_lists.items[term_data.posting_offset];
            entity_count = @intCast(postings.items.len);
            for (postings.items) |posting| {
                total_occurrences += posting.frequency;
            }
        }

        return TermStats{
            .term = term,
            .document_frequency = entity_count,
            .total_frequency = total_occurrences,
            .idf = if (self.total_documents > 0)
                @log(@as(f32, @floatFromInt(self.total_documents)) / @as(f32, @floatFromInt(entity_count)))
            else
                0,
        };
    }
};

const EntityResult = struct {
    entity_id: EntityId,
    score: f32,
};

const TermStats = struct {
    term: []const u8,
    document_frequency: u32,
    total_frequency: u64,
    idf: f32,
};

fn sortResults(items: []EntityResult) void {
    std.sort.insertion(EntityResult, items, {}, struct {
        fn lessThan(_: void, a: EntityResult, b: EntityResult) bool {
            return a.score > b.score;
        }
    }.lessThan);
}

// ==================== Relationship Graph Cartridge ====================

/// Directed edge in the relationship graph
const GraphEdge = struct {
    to_entity: EntityId,
    relationship: Relationship,
    offset: u64,

    pub fn init(allocator: std.mem.Allocator, to_entity: EntityId, relationship: Relationship) !GraphEdge {
        const to_ns = try allocator.dupe(u8, to_entity.namespace);
        errdefer allocator.free(to_ns);
        const to_local = try allocator.dupe(u8, to_entity.local_id);
        errdefer allocator.free(to_local);

        const rel_ns = try allocator.dupe(u8, relationship.from_entity.namespace);
        errdefer allocator.free(rel_ns);
        const rel_local = try allocator.dupe(u8, relationship.from_entity.local_id);
        errdefer allocator.free(rel_local);
        const rel_to_ns = try allocator.dupe(u8, relationship.to_entity.namespace);
        errdefer allocator.free(rel_to_ns);
        const rel_to_local = try allocator.dupe(u8, relationship.to_entity.local_id);
        errdefer allocator.free(rel_to_local);

        var metadata = ArrayListManaged(Attribute){};
        for (relationship.metadata.items) |*attr| {
            const attr_copy = Attribute{
                .key = try allocator.dupe(u8, attr.key),
                .value = try dupeAttributeValue(allocator, attr.value),
                .confidence = attr.confidence,
                .source = try allocator.dupe(u8, attr.source),
            };
            try metadata.append(allocator, attr_copy);
        }

        return GraphEdge{
            .to_entity = .{ .namespace = to_ns, .local_id = to_local },
            .relationship = .{
                .from_entity = .{ .namespace = rel_ns, .local_id = rel_local },
                .to_entity = .{ .namespace = rel_to_ns, .local_id = rel_to_local },
                .type = relationship.type,
                .strength = relationship.strength,
                .established_at = relationship.established_at,
                .metadata = metadata,
            },
            .offset = 0,
        };
    }

    pub fn deinit(self: *GraphEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.to_entity.namespace);
        allocator.free(self.to_entity.local_id);
        self.relationship.deinit(allocator);
    }
};

/// Adjacency list entry for a node in the graph
const AdjacencyEntry = struct {
    entity_id: EntityId,
    outgoing: ArrayListManaged(GraphEdge),
    incoming: ArrayListManaged(EntityId),

    pub fn init(allocator: std.mem.Allocator, entity_id: EntityId) !AdjacencyEntry {
        const ns = try allocator.dupe(u8, entity_id.namespace);
        errdefer allocator.free(ns);
        const local = try allocator.dupe(u8, entity_id.local_id);
        errdefer allocator.free(local);

        return AdjacencyEntry{
            .entity_id = .{ .namespace = ns, .local_id = local },
            .outgoing = .{},
            .incoming = .{},
        };
    }

    pub fn deinit(self: *AdjacencyEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id.namespace);
        allocator.free(self.entity_id.local_id);
        for (self.outgoing.items) |*edge| edge.deinit(allocator);
        self.outgoing.deinit(allocator);
        for (self.incoming.items) |*eid| {
            allocator.free(eid.namespace);
            allocator.free(eid.local_id);
        }
        self.incoming.deinit(allocator);
    }
};

/// Path element for traversal results
pub const PathElement = struct {
    entity_id: EntityId,
    relationship_type: RelationshipType,
    strength: f32,

    pub fn deinit(self: *PathElement, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id.namespace);
        allocator.free(self.entity_id.local_id);
    }
};

/// Path found during graph traversal
pub const GraphPath = struct {
    elements: ArrayListManaged(PathElement),
    total_strength: f32,

    pub fn init(allocator: std.mem.Allocator) GraphPath {
        _ = allocator;
        return GraphPath{
            .elements = .{},
            .total_strength = 1.0,
        };
    }

    pub fn deinit(self: *GraphPath, allocator: std.mem.Allocator) void {
        for (self.elements.items) |*elem| elem.deinit(allocator);
        self.elements.deinit(allocator);
    }

    pub fn addElement(self: *GraphPath, allocator: std.mem.Allocator, elem: PathElement) !void {
        try self.elements.append(allocator, elem);
        self.total_strength *= elem.strength;
    }
};

/// Relationship graph cartridge with adjacency list storage
pub const RelationshipCartridge = struct {
    allocator: std.mem.Allocator,
    header: format.CartridgeHeader,
    /// Map from entity ID to its adjacency entry
    adjacency: std.HashMap(EntityId, *AdjacencyEntry, EntityIdContext, std.hash_map.default_max_load_percentage),
    /// Flat storage of adjacency entries
    entries: ArrayListManaged(*AdjacencyEntry),

    /// Create new relationship cartridge
    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64) !RelationshipCartridge {
        const header = format.CartridgeHeader.init(.relationship_graph, source_txn_id);
        return RelationshipCartridge{
            .allocator = allocator,
            .header = header,
            .adjacency = std.HashMap(EntityId, *AdjacencyEntry, EntityIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .entries = .{},
        };
    }

    pub fn deinit(self: *RelationshipCartridge) void {
        var it = self.adjacency.valueIterator();
        while (it.next()) |entry| {
            entry.*.deinit(self.allocator);
            self.allocator.destroy(entry.*);
        }
        self.adjacency.deinit();
        self.entries.deinit(self.allocator);
    }

    /// Get or create adjacency entry for an entity
    fn getOrCreateEntry(self: *RelationshipCartridge, entity_id: EntityId) !*AdjacencyEntry {
        if (self.adjacency.get(entity_id)) |entry| {
            return entry;
        }

        const entry = try self.allocator.create(AdjacencyEntry);
        entry.* = try AdjacencyEntry.init(self.allocator, entity_id);
        try self.adjacency.put(entry.entity_id, entry);
        try self.entries.append(self.allocator, entry);
        return entry;
    }

    /// Add a relationship to the graph
    pub fn addRelationship(self: *RelationshipCartridge, relationship: Relationship) !void {
        const from_entry = try self.getOrCreateEntry(relationship.from_entity);
        const to_entry = try self.getOrCreateEntry(relationship.to_entity);

        // Create outgoing edge
        const edge = try GraphEdge.init(self.allocator, relationship.to_entity, relationship);
        try from_entry.outgoing.append(self.allocator, edge);

        // Add to incoming list
        const from_dupe = EntityId{
            .namespace = try self.allocator.dupe(u8, relationship.from_entity.namespace),
            .local_id = try self.allocator.dupe(u8, relationship.from_entity.local_id),
        };
        try to_entry.incoming.append(self.allocator, from_dupe);

        self.header.entry_count += 1;
    }

    /// Get outgoing relationships for an entity
    pub fn getOutgoing(self: *const RelationshipCartridge, entity_id: EntityId) !ArrayListManaged(Relationship) {
        var results = ArrayListManaged(Relationship){};
        const entry = self.adjacency.get(entity_id) orelse return results;

        for (entry.outgoing.items) |*edge| {
            var rel = try Relationship.init(
                self.allocator,
                entity_id,
                edge.to_entity,
                edge.relationship.type,
                edge.relationship.strength,
                edge.relationship.established_at
            );
            errdefer rel.deinit(self.allocator);

            for (edge.relationship.metadata.items) |*meta| {
                try rel.addMetadata(self.allocator, meta.*);
            }
            try results.append(self.allocator, rel);
        }

        return results;
    }

    /// Get incoming relationships for an entity
    pub fn getIncoming(self: *const RelationshipCartridge, entity_id: EntityId) !ArrayListManaged(Relationship) {
        var results = ArrayListManaged(Relationship){};
        const entry = self.adjacency.get(entity_id) orelse return results;

        for (entry.incoming.items) |from_id| {
            const from_entry = self.adjacency.get(from_id) orelse continue;

            for (from_entry.outgoing.items) |*edge| {
                if (EntityId.eql(edge.to_entity, entity_id)) {
                    var rel = try Relationship.init(
                        self.allocator,
                        from_id,
                        entity_id,
                        edge.relationship.type,
                        edge.relationship.strength,
                        edge.relationship.established_at
                    );
                    errdefer rel.deinit(self.allocator);

                    for (edge.relationship.metadata.items) |*meta| {
                        try rel.addMetadata(self.allocator, meta.*);
                    }
                    try results.append(self.allocator, rel);
                }
            }
        }

        return results;
    }

    /// BFS traversal from start entity
    pub fn bfs(
        self: *const RelationshipCartridge,
        start: EntityId,
        max_depth: usize,
        filter_type: ?RelationshipType
    ) !ArrayListManaged(GraphPath) {
        var results = ArrayListManaged(GraphPath){};
        const start_entry = self.adjacency.get(start) orelse return results;

        // Queue for BFS: (entity, path, depth)
        const QueueItem = struct {
            entity: EntityId,
            path: *GraphPath,
            depth: usize,
        };
        var queue = std.ArrayListUnmanaged(QueueItem){};
        defer {
            for (queue.items) |item| {
                item.path.deinit(self.allocator);
                self.allocator.destroy(item.path);
            }
            queue.deinit(self.allocator);
        }

        // Initialize with direct neighbors
        for (start_entry.outgoing.items) |*edge| {
            if (filter_type) |ft| {
                if (edge.relationship.type != ft) continue;
            }

            var path = try self.allocator.create(GraphPath);
            path.* = GraphPath.init(self.allocator);

            const elem = PathElement{
                .entity_id = .{
                    .namespace = try self.allocator.dupe(u8, edge.to_entity.namespace),
                    .local_id = try self.allocator.dupe(u8, edge.to_entity.local_id),
                },
                .relationship_type = edge.relationship.type,
                .strength = edge.relationship.strength,
            };
            try path.addElement(self.allocator, elem);

            try queue.append(self.allocator, .{
                .entity = edge.to_entity,
                .path = path,
                .depth = 1,
            });
        }

        // Process queue
        while (queue.items.len > 0) {
            const item = queue.orderedRemove(0);

            // Clone path for result
            var path_copy = GraphPath.init(self.allocator);
            for (item.path.elements.items) |*elem| {
                const elem_copy = PathElement{
                    .entity_id = .{
                        .namespace = try self.allocator.dupe(u8, elem.entity_id.namespace),
                        .local_id = try self.allocator.dupe(u8, elem.entity_id.local_id),
                    },
                    .relationship_type = elem.relationship_type,
                    .strength = elem.strength,
                };
                try path_copy.addElement(self.allocator, elem_copy);
            }
            try results.append(self.allocator, path_copy);

            // Expand if not at max depth
            if (item.depth < max_depth) {
                const next_entry = self.adjacency.get(item.entity) orelse continue;
                for (next_entry.outgoing.items) |*edge| {
                    if (filter_type) |ft| {
                        if (edge.relationship.type != ft) continue;
                    }

                    var new_path = try self.allocator.create(GraphPath);
                    new_path.* = GraphPath.init(self.allocator);

                    // Copy existing path
                    for (item.path.elements.items) |*elem| {
                        const elem_copy = PathElement{
                            .entity_id = .{
                                .namespace = try self.allocator.dupe(u8, elem.entity_id.namespace),
                                .local_id = try self.allocator.dupe(u8, elem.entity_id.local_id),
                            },
                            .relationship_type = elem.relationship_type,
                            .strength = elem.strength,
                        };
                        try new_path.addElement(self.allocator, elem_copy);
                    }

                    // Add new element
                    const new_elem = PathElement{
                        .entity_id = .{
                            .namespace = try self.allocator.dupe(u8, edge.to_entity.namespace),
                            .local_id = try self.allocator.dupe(u8, edge.to_entity.local_id),
                        },
                        .relationship_type = edge.relationship.type,
                        .strength = edge.relationship.strength,
                    };
                    try new_path.addElement(self.allocator, new_elem);

                    try queue.append(self.allocator, .{
                        .entity = edge.to_entity,
                        .path = new_path,
                        .depth = item.depth + 1,
                    });
                }
            }
        }

        return results;
    }

    /// Find shortest path between two entities using BFS
    pub fn findShortestPath(
        self: *const RelationshipCartridge,
        from: EntityId,
        to: EntityId
    ) !?GraphPath {
        // Start and end are the same
        if (EntityId.eql(from, to)) {
            const path = GraphPath.init(self.allocator);
            return path;
        }

        const from_entry = self.adjacency.get(from) orelse return null;

        // Queue for BFS: (entity, path)
        const PathQueueItem = struct {
            entity: EntityId,
            path: ArrayListManaged(PathElement),
        };
        var queue = std.ArrayListUnmanaged(PathQueueItem){};
        defer {
            for (queue.items) |*item| {
                for (item.path.items) |*elem| elem.deinit(self.allocator);
                item.path.deinit(self.allocator);
            }
            queue.deinit(self.allocator);
        }

        // Visited set
        var visited = std.HashMap(EntityId, void, EntityIdContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer visited.deinit();
        try visited.put(from, {});

        // Initialize with direct neighbors
        for (from_entry.outgoing.items) |*edge| {
            var path = try ArrayListManaged(PathElement).initCapacity(self.allocator, 1);

            const elem = PathElement{
                .entity_id = .{
                    .namespace = try self.allocator.dupe(u8, edge.to_entity.namespace),
                    .local_id = try self.allocator.dupe(u8, edge.to_entity.local_id),
                },
                .relationship_type = edge.relationship.type,
                .strength = edge.relationship.strength,
            };
            try path.append(self.allocator, elem);

            if (EntityId.eql(edge.to_entity, to)) {
                // Found direct path
                var result = GraphPath.init(self.allocator);
                result.total_strength = edge.relationship.strength;
                result.elements = path;
                return result;
            }

            try queue.append(self.allocator, .{
                .entity = edge.to_entity,
                .path = path,
            });
            try visited.put(edge.to_entity, {});
        }

        // BFS search
        while (queue.items.len > 0) {
            const item = queue.orderedRemove(0);
            const next_entry = self.adjacency.get(item.entity) orelse continue;

            for (next_entry.outgoing.items) |*edge| {
                // Skip if already visited
                if (visited.get(edge.to_entity) != null) continue;
                try visited.put(edge.to_entity, {});

                // Build new path
                var new_path = try ArrayListManaged(PathElement).initCapacity(self.allocator, item.path.items.len + 1);

                for (item.path.items) |*elem| {
                    const elem_copy = PathElement{
                        .entity_id = .{
                            .namespace = try self.allocator.dupe(u8, elem.entity_id.namespace),
                            .local_id = try self.allocator.dupe(u8, elem.entity_id.local_id),
                        },
                        .relationship_type = elem.relationship_type,
                        .strength = elem.strength,
                    };
                    try new_path.append(self.allocator, elem_copy);
                }

                const new_elem = PathElement{
                    .entity_id = .{
                        .namespace = try self.allocator.dupe(u8, edge.to_entity.namespace),
                        .local_id = try self.allocator.dupe(u8, edge.to_entity.local_id),
                    },
                    .relationship_type = edge.relationship.type,
                    .strength = edge.relationship.strength,
                };
                try new_path.append(self.allocator, new_elem);

                if (EntityId.eql(edge.to_entity, to)) {
                    // Found path
                    var result = GraphPath.init(self.allocator);
                    var total_strength: f32 = 1.0;
                    for (new_path.items) |*elem| {
                        total_strength *= elem.strength;
                    }
                    result.total_strength = total_strength;
                    result.elements = new_path;

                    // Clean up queue
                    for (queue.items) |*q_item| {
                        for (q_item.path.items) |*elem| elem.deinit(self.allocator);
                        q_item.path.deinit(self.allocator);
                    }

                    return result;
                }

                try queue.append(self.allocator, .{
                    .entity = edge.to_entity,
                    .path = new_path,
                });
            }
        }

        return null;
    }

    /// Find all paths between two entities up to max depth
    pub fn findAllPaths(
        self: *const RelationshipCartridge,
        from: EntityId,
        to: EntityId,
        max_depth: usize
    ) !ArrayListManaged(GraphPath) {
        var results = ArrayListManaged(GraphPath){};

        if (EntityId.eql(from, to)) {
            return results;
        }

        var visited = std.HashMap(EntityId, void, EntityIdContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        try self.findAllPathsRecursive(from, to, max_depth, &visited, &results, .{});

        return results;
    }

    fn findAllPathsRecursive(
        self: *const RelationshipCartridge,
        current: EntityId,
        target: EntityId,
        remaining_depth: usize,
        visited: *std.HashMap(EntityId, void, EntityIdContext, std.hash_map.default_max_load_percentage),
        results: *ArrayListManaged(GraphPath),
        current_path: ArrayListManaged(PathElement)
    ) !void {
        _ = visited.put(current, {}) catch {};

        const entry = self.adjacency.get(current) orelse {
            _ = visited.remove(current);
            return;
        };

        for (entry.outgoing.items) |*edge| {
            // Check if reached target
            if (EntityId.eql(edge.to_entity, target)) {
                var result_path = GraphPath.init(self.allocator);
                for (current_path.items) |*elem| {
                    const elem_copy = PathElement{
                        .entity_id = .{
                            .namespace = try self.allocator.dupe(u8, elem.entity_id.namespace),
                            .local_id = try self.allocator.dupe(u8, elem.entity_id.local_id),
                        },
                        .relationship_type = elem.relationship_type,
                        .strength = elem.strength,
                    };
                    try result_path.addElement(self.allocator, elem_copy);
                }

                const final_elem = PathElement{
                    .entity_id = .{
                        .namespace = try self.allocator.dupe(u8, edge.to_entity.namespace),
                        .local_id = try self.allocator.dupe(u8, edge.to_entity.local_id),
                    },
                    .relationship_type = edge.relationship.type,
                    .strength = edge.relationship.strength,
                };
                try result_path.addElement(self.allocator, final_elem);
                try results.append(self.allocator, result_path);
                continue;
            }

            // Skip if visited or no depth remaining
            if (remaining_depth == 0) continue;
            if (visited.get(edge.to_entity) != null) continue;

            // Extend path and recurse
            const elem = PathElement{
                .entity_id = .{
                    .namespace = try self.allocator.dupe(u8, edge.to_entity.namespace),
                    .local_id = try self.allocator.dupe(u8, edge.to_entity.local_id),
                },
                .relationship_type = edge.relationship.type,
                .strength = edge.relationship.strength,
            };

            var new_path = try ArrayListManaged(PathElement).initCapacity(self.allocator, current_path.items.len + 1);
            for (current_path.items) |*p| {
                const p_copy = PathElement{
                    .entity_id = .{
                        .namespace = try self.allocator.dupe(u8, p.entity_id.namespace),
                        .local_id = try self.allocator.dupe(u8, p.entity_id.local_id),
                    },
                    .relationship_type = p.relationship_type,
                    .strength = p.strength,
                };
                try new_path.append(self.allocator, p_copy);
            }
            try new_path.append(self.allocator, elem);

            try self.findAllPathsRecursive(edge.to_entity, target, remaining_depth - 1, visited, results, new_path);

            for (new_path.items) |*p| {
                p.deinit(self.allocator);
            }
            new_path.deinit(self.allocator);
        }

        _ = visited.remove(current);
    }

    /// Get connected entities within N hops
    pub fn getNeighbors(
        self: *const RelationshipCartridge,
        entity_id: EntityId,
        max_hops: usize,
        filter_type: ?RelationshipType
    ) !ArrayListManaged(EntityId) {
        var results = ArrayListManaged(EntityId){};
        var visited = std.HashMap(EntityId, void, EntityIdContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer visited.deinit();

        const NeighborQueueItem = struct {
            entity: EntityId,
            hops: usize,
        };
        var queue = std.ArrayListUnmanaged(NeighborQueueItem){};
        defer queue.deinit(self.allocator);

        try queue.append(self.allocator, .{ .entity = entity_id, .hops = 0 });
        try visited.put(entity_id, {});

        while (queue.items.len > 0) {
            const item = queue.orderedRemove(0);
            if (item.hops >= max_hops) continue;

            const entry = self.adjacency.get(item.entity) orelse continue;

            for (entry.outgoing.items) |*edge| {
                if (visited.get(edge.to_entity) != null) continue;
                if (filter_type) |ft| {
                    if (edge.relationship.type != ft) continue;
                }

                try visited.put(edge.to_entity, {});

                const neighbor = EntityId{
                    .namespace = try self.allocator.dupe(u8, edge.to_entity.namespace),
                    .local_id = try self.allocator.dupe(u8, edge.to_entity.local_id),
                };
                try results.append(self.allocator, neighbor);

                try queue.append(self.allocator, .{
                    .entity = edge.to_entity,
                    .hops = item.hops + 1,
                });
            }
        }

        return results;
    }
};

// ==================== Tests ====================

test "EntityId.toString roundtrip" {
    const id = EntityId{
        .namespace = "file",
        .local_id = "src/main.zig",
    };

    const str = try id.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqualStrings("file:src/main.zig", str);

    const parsed = try EntityId.parse(str, std.testing.allocator);
    defer {
        std.testing.allocator.free(parsed.namespace);
        std.testing.allocator.free(parsed.local_id);
    }

    try std.testing.expectEqualStrings("file", parsed.namespace);
    try std.testing.expectEqualStrings("src/main.zig", parsed.local_id);
}

test "EntityId.parse error handling" {
    const result = EntityId.parse("invalid_format", std.testing.allocator);
    try std.testing.expectError(error.InvalidEntityIdFormat, result);
}

test "Entity.addAttribute" {
    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        12345
    );
    defer entity.deinit(std.testing.allocator);

    const attr = Attribute{
        .key = "size",
        .value = .{ .integer = 1024 },
        .confidence = 1.0,
        .source = "test",
    };
    try entity.addAttribute(std.testing.allocator, attr);

    try std.testing.expectEqual(@as(usize, 1), entity.attributes.items.len);
    try std.testing.expectEqualStrings("size", entity.attributes.items[0].key);
    try std.testing.expectEqual(@as(i64, 1024), entity.attributes.items[0].value.integer);
}

test "Entity.getAttribute" {
    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        12345
    );
    defer entity.deinit(std.testing.allocator);

    const attr1 = Attribute{
        .key = "size",
        .value = .{ .integer = 1024 },
        .confidence = 1.0,
        .source = "test",
    };
    try entity.addAttribute(std.testing.allocator, attr1);

    const attr2 = Attribute{
        .key = "language",
        .value = .{ .string = "zig" },
        .confidence = 0.9,
        .source = "test",
    };
    try entity.addAttribute(std.testing.allocator, attr2);

    const size_attr = entity.getAttribute("size").?;
    try std.testing.expectEqual(@as(i64, 1024), size_attr.value.integer);

    const lang_attr = entity.getAttribute("language").?;
    try std.testing.expectEqualStrings("zig", lang_attr.value.string);

    try std.testing.expect(entity.getAttribute("nonexistent") == null);
}

test "TopicId.fromComponents" {
    const components = [_][]const u8{ "database", "performance", "btree" };
    const topic_id = try TopicId.fromComponents(std.testing.allocator, &components);
    defer std.testing.allocator.free(topic_id.path);

    try std.testing.expectEqualStrings("database.performance.btree", topic_id.path);
}

test "Topic.addChild" {
    const parent_id = TopicId{ .path = "database" };
    const child_id = TopicId{ .path = "database.performance" };

    var topic = try Topic.init(std.testing.allocator, parent_id, "Database");
    defer topic.deinit(std.testing.allocator);

    try topic.addChild(std.testing.allocator, child_id);

    try std.testing.expectEqual(@as(usize, 1), topic.children.items.len);
    try std.testing.expectEqualStrings("database.performance", topic.children.items[0].path);
}

test "Topic.addBackPointer" {
    const topic_id = TopicId{ .path = "performance" };
    var topic = try Topic.init(std.testing.allocator, topic_id, "Performance");
    defer topic.deinit(std.testing.allocator);

    const pointer = TxnPointer{
        .txn_id = 12345,
        .relevance = 0.95,
        .offset = 100,
    };
    try topic.addBackPointer(std.testing.allocator, pointer);

    try std.testing.expectEqual(@as(usize, 1), topic.back_pointers.items.len);
    try std.testing.expectEqual(@as(u64, 12345), topic.back_pointers.items[0].txn_id);
    try std.testing.expectEqual(@as(f32, 0.95), topic.back_pointers.items[0].relevance);
}

test "Relationship.init and addMetadata" {
    const from_id = EntityId{ .namespace = "file", .local_id = "main.zig" };
    const to_id = EntityId{ .namespace = "file", .local_id = "utils.zig" };

    var rel = try Relationship.init(std.testing.allocator, from_id, to_id, .imports, 0.8, 12345);
    defer rel.deinit(std.testing.allocator);

    const meta = Attribute{
        .key = "line_count",
        .value = .{ .integer = 5 },
        .confidence = 1.0,
        .source = "static_analysis",
    };
    try rel.addMetadata(std.testing.allocator, meta);

    try std.testing.expectEqual(@as(usize, 1), rel.metadata.items.len);
    try std.testing.expectEqualStrings("line_count", rel.metadata.items[0].key);
}

test "EntityIndexCartridge.addEntity" {
    var cartridge = try EntityIndexCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        12345
    );
    defer entity.deinit(std.testing.allocator);

    const attr = Attribute{
        .key = "size",
        .value = .{ .integer = 1024 },
        .confidence = 1.0,
        .source = "test",
    };
    try entity.addAttribute(std.testing.allocator, attr);

    try cartridge.addEntity(entity);

    try std.testing.expectEqual(@as(u64, 1), cartridge.header.entry_count);
    try std.testing.expectEqual(@as(usize, 1), cartridge.entity_data.items.len);
}

test "AttributeValue.serialize roundtrip string" {
    const original = AttributeValue{ .string = "hello world" };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try original.serialize(fbs.writer());

    fbs.pos = 0;
    var restored = try AttributeValue.deserialize(fbs.reader(), std.testing.allocator);
    defer restored.deinit(std.testing.allocator);

    try std.testing.expect(restored == .string);
    try std.testing.expectEqualStrings("hello world", restored.string);
}

test "AttributeValue.serialize roundtrip integer" {
    const original = AttributeValue{ .integer = -42 };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try original.serialize(fbs.writer());

    fbs.pos = 0;
    var restored = try AttributeValue.deserialize(fbs.reader(), std.testing.allocator);
    defer restored.deinit(std.testing.allocator);

    try std.testing.expect(restored == .integer);
    try std.testing.expectEqual(@as(i64, -42), restored.integer);
}

test "AttributeValue.serialize roundtrip boolean" {
    const original = AttributeValue{ .boolean = true };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try original.serialize(fbs.writer());

    fbs.pos = 0;
    var restored = try AttributeValue.deserialize(fbs.reader(), std.testing.allocator);
    defer restored.deinit(std.testing.allocator);

    try std.testing.expect(restored == .boolean);
    try std.testing.expectEqual(true, restored.boolean);
}

test "Entity.serialize roundtrip" {
    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        12345
    );
    defer entity.deinit(std.testing.allocator);

    const attr = Attribute{
        .key = "size",
        .value = .{ .integer = 1024 },
        .confidence = 0.9,
        .source = "test_source",
    };
    try entity.addAttribute(std.testing.allocator, attr);

    const size = entity.serializedSize();
    var buffer = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(buffer);

    var fbs = std.io.fixedBufferStream(buffer);
    try entity.serialize(fbs.writer());

    // Read back
    fbs.pos = 0;
    const reader = fbs.reader();

    _ = try reader.readByte(); // flags
    const type_val = try reader.readByte();
    try std.testing.expectEqual(@as(u8, 1), type_val); // file = 1

    _ = try reader.readInt(u32, .little); // confidence
    _ = try reader.readInt(u64, .little); // created_at
    _ = try reader.readInt(u64, .little); // last_modified

    const ns_len = try reader.readInt(u16, .little);
    try std.testing.expectEqual(@as(u16, 4), ns_len);
    const ns = buffer[fbs.pos..][0..ns_len];
    fbs.pos += ns_len;
    try std.testing.expectEqualStrings("file", ns);

    const local_len = try reader.readInt(u16, .little);
    try std.testing.expectEqual(@as(u16, 8), local_len);
    const local = buffer[fbs.pos..][0..local_len];
    fbs.pos += local_len;
    try std.testing.expectEqualStrings("test.zig", local);
}

test "EntityType.fromUint and toUint" {
    const et = EntityType.function;
    const val = et.toUint();
    try std.testing.expectEqual(@as(u8, 3), val);

    const restored = try EntityType.fromUint(val);
    try std.testing.expectEqual(EntityType.function, restored);
}

test "TrieNode.insert and lookup" {
    var root = try TrieNode.init(std.testing.allocator, 0);
    defer root.deinit(std.testing.allocator);

    const term1 = "database";
    const data1 = try root.insert(std.testing.allocator, term1);
    try std.testing.expectEqualStrings(term1, data1.term);

    const found = root.lookup(term1);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(term1, found.?.term);

    const not_found = root.lookup("nonexistent");
    try std.testing.expect(not_found == null);
}

test "TrieNode.findPrefix" {
    var root = try TrieNode.init(std.testing.allocator, 0);
    defer root.deinit(std.testing.allocator);

    // Insert terms with common prefix
    _ = try root.insert(std.testing.allocator, "database");
    _ = try root.insert(std.testing.allocator, "data");
    _ = try root.insert(std.testing.allocator, "dat");
    _ = try root.insert(std.testing.allocator, "btree");

    var results = try root.findPrefix("dat", std.testing.allocator);
    defer {
        for (results.items) |term| std.testing.allocator.free(term);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 3), results.items.len);

    // Check all expected terms are present
    var found_data = false;
    var found_database = false;
    var found_dat = false;
    for (results.items) |term| {
        if (std.mem.eql(u8, term, "data")) found_data = true;
        if (std.mem.eql(u8, term, "database")) found_database = true;
        if (std.mem.eql(u8, term, "dat")) found_dat = true;
    }
    try std.testing.expect(found_data);
    try std.testing.expect(found_database);
    try std.testing.expect(found_dat);
}

test "TermPosting.init and addPosition" {
    const entity_id = EntityId{ .namespace = "file", .local_id = "test.zig" };
    var posting = try TermPosting.init(std.testing.allocator, entity_id, 100);
    defer posting.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 1), posting.frequency);
    try std.testing.expectEqual(@as(u64, 100), posting.timestamp);

    try posting.addPosition(std.testing.allocator, 5);
    try std.testing.expectEqual(@as(u16, 2), posting.frequency);
    try std.testing.expectEqual(@as(usize, 1), posting.positions.items.len);
}

test "TopicCartridge.addEntityTerms" {
    var cartridge = try TopicCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const entity_id = EntityId{ .namespace = "file", .local_id = "main.zig" };
    const terms = [_][]const u8{ "zig", "database", "performance" };

    try cartridge.addEntityTerms(entity_id, &terms, 100);

    // Each unique term-entity pair creates one posting
    try std.testing.expectEqual(@as(u64, 3), cartridge.header.entry_count);
    try std.testing.expectEqual(@as(usize, 3), cartridge.posting_lists.items.len);
}

test "TopicCartridge.searchByTopic" {
    var cartridge = try TopicCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    // Add entities with overlapping terms
    const entity1 = EntityId{ .namespace = "file", .local_id = "db.zig" };
    const terms1 = [_][]const u8{ "zig", "database", "btree" };
    try cartridge.addEntityTerms(entity1, &terms1, 100);

    const entity2 = EntityId{ .namespace = "file", .local_id = "pager.zig" };
    const terms2 = [_][]const u8{ "zig", "pager", "io" };
    try cartridge.addEntityTerms(entity2, &terms2, 101);

    // Search for "zig" - should find both entities
    const query1 = [_][]const u8{"zig"};
    var results1 = try cartridge.searchByTopic(&query1, 10);
    defer {
        for (results1.items) |*r| {
            std.testing.allocator.free(r.entity_id.namespace);
            std.testing.allocator.free(r.entity_id.local_id);
        }
        results1.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), results1.items.len);

    // Search for "btree" - should find only entity1
    const query2 = [_][]const u8{"btree"};
    var results2 = try cartridge.searchByTopic(&query2, 10);
    defer {
        for (results2.items) |*r| {
            std.testing.allocator.free(r.entity_id.namespace);
            std.testing.allocator.free(r.entity_id.local_id);
        }
        results2.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results2.items.len);
    try std.testing.expectEqualStrings("db.zig", results2.items[0].entity_id.local_id);
}

test "TopicCartridge.getTermStats" {
    var cartridge = try TopicCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const entity1 = EntityId{ .namespace = "file", .local_id = "a.zig" };
    const terms1 = [_][]const u8{ "zig", "zig", "database" }; // zig appears twice
    try cartridge.addEntityTerms(entity1, &terms1, 100);

    const entity2 = EntityId{ .namespace = "file", .local_id = "b.zig" };
    const terms2 = [_][]const u8{ "zig", "database" };
    try cartridge.addEntityTerms(entity2, &terms2, 101);

    const stats = cartridge.getTermStats("zig");
    try std.testing.expect(stats != null);
    // 2 entities have "zig" (document_frequency)
    try std.testing.expectEqual(@as(u32, 2), stats.?.document_frequency);
    // Each time "zig" appears in the terms array, frequency is incremented
    // entity1 has "zig" twice (frequency=2), entity2 has "zig" once (frequency=1)
    // total_frequency = 2 + 1 = 3
    try std.testing.expectEqual(@as(u64, 3), stats.?.total_frequency);

    const no_stats = cartridge.getTermStats("nonexistent");
    try std.testing.expect(no_stats == null);
}

test "RelationshipCartridge.addRelationship" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const from_id = EntityId{ .namespace = "file", .local_id = "main.zig" };
    const to_id = EntityId{ .namespace = "file", .local_id = "utils.zig" };

    var rel = try Relationship.init(std.testing.allocator, from_id, to_id, .imports, 0.8, 100);
    defer rel.deinit(std.testing.allocator);

    try cartridge.addRelationship(rel);

    try std.testing.expectEqual(@as(u64, 1), cartridge.header.entry_count);
    try std.testing.expectEqual(@as(usize, 2), cartridge.adjacency.count());
}

test "RelationshipCartridge.getOutgoing" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const main_id = EntityId{ .namespace = "file", .local_id = "main.zig" };
    const utils_id = EntityId{ .namespace = "file", .local_id = "utils.zig" };
    const db_id = EntityId{ .namespace = "file", .local_id = "db.zig" };

    var rel1 = try Relationship.init(std.testing.allocator, main_id, utils_id, .imports, 0.8, 100);
    defer rel1.deinit(std.testing.allocator);
    var rel2 = try Relationship.init(std.testing.allocator, main_id, db_id, .calls, 0.9, 100);
    defer rel2.deinit(std.testing.allocator);

    try cartridge.addRelationship(rel1);
    try cartridge.addRelationship(rel2);

    var outgoing = try cartridge.getOutgoing(main_id);
    defer {
        for (outgoing.items) |*r| r.deinit(std.testing.allocator);
        outgoing.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), outgoing.items.len);
}

test "RelationshipCartridge.getIncoming" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const main_id = EntityId{ .namespace = "file", .local_id = "main.zig" };
    const utils_id = EntityId{ .namespace = "file", .local_id = "utils.zig" };

    var rel = try Relationship.init(std.testing.allocator, main_id, utils_id, .imports, 0.8, 100);
    defer rel.deinit(std.testing.allocator);

    try cartridge.addRelationship(rel);

    var incoming = try cartridge.getIncoming(utils_id);
    defer {
        for (incoming.items) |*r| r.deinit(std.testing.allocator);
        incoming.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), incoming.items.len);
    try std.testing.expectEqualStrings("main.zig", incoming.items[0].from_entity.local_id);
}

test "RelationshipCartridge.findShortestPath direct" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const a_id = EntityId{ .namespace = "file", .local_id = "a.zig" };
    const b_id = EntityId{ .namespace = "file", .local_id = "b.zig" };

    var rel = try Relationship.init(std.testing.allocator, a_id, b_id, .imports, 0.8, 100);
    defer rel.deinit(std.testing.allocator);
    try cartridge.addRelationship(rel);

    {
        var path = try cartridge.findShortestPath(a_id, b_id);
        try std.testing.expect(path != null);
        defer if (path) |*p| p.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), path.?.elements.items.len);
        try std.testing.expectEqualStrings("b.zig", path.?.elements.items[0].entity_id.local_id);
    }
}

test "RelationshipCartridge.findShortestPath multiHop" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const a_id = EntityId{ .namespace = "file", .local_id = "a.zig" };
    const b_id = EntityId{ .namespace = "file", .local_id = "b.zig" };
    const c_id = EntityId{ .namespace = "file", .local_id = "c.zig" };

    // a -> b -> c
    var rel1 = try Relationship.init(std.testing.allocator, a_id, b_id, .imports, 0.8, 100);
    defer rel1.deinit(std.testing.allocator);
    var rel2 = try Relationship.init(std.testing.allocator, b_id, c_id, .imports, 0.8, 100);
    defer rel2.deinit(std.testing.allocator);

    try cartridge.addRelationship(rel1);
    try cartridge.addRelationship(rel2);

    {
        var path = try cartridge.findShortestPath(a_id, c_id);
        try std.testing.expect(path != null);
        defer if (path) |*p| p.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 2), path.?.elements.items.len);
        try std.testing.expectEqualStrings("b.zig", path.?.elements.items[0].entity_id.local_id);
        try std.testing.expectEqualStrings("c.zig", path.?.elements.items[1].entity_id.local_id);
    }
}

test "RelationshipCartridge.findShortestPath noPath" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const a_id = EntityId{ .namespace = "file", .local_id = "a.zig" };
    const b_id = EntityId{ .namespace = "file", .local_id = "b.zig" };
    const c_id = EntityId{ .namespace = "file", .local_id = "c.zig" };

    var rel = try Relationship.init(std.testing.allocator, a_id, b_id, .imports, 0.8, 100);
    defer rel.deinit(std.testing.allocator);
    try cartridge.addRelationship(rel);

    // c is isolated, no path from a to c
    const path = try cartridge.findShortestPath(a_id, c_id);
    try std.testing.expect(path == null);
}

test "RelationshipCartridge.bfs depthLimited" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const a_id = EntityId{ .namespace = "file", .local_id = "a.zig" };
    const b_id = EntityId{ .namespace = "file", .local_id = "b.zig" };
    const c_id = EntityId{ .namespace = "file", .local_id = "c.zig" };
    const d_id = EntityId{ .namespace = "file", .local_id = "d.zig" };

    // a -> b -> c -> d
    var rel1 = try Relationship.init(std.testing.allocator, a_id, b_id, .imports, 0.8, 100);
    defer rel1.deinit(std.testing.allocator);
    var rel2 = try Relationship.init(std.testing.allocator, b_id, c_id, .imports, 0.8, 100);
    defer rel2.deinit(std.testing.allocator);
    var rel3 = try Relationship.init(std.testing.allocator, c_id, d_id, .imports, 0.8, 100);
    defer rel3.deinit(std.testing.allocator);

    try cartridge.addRelationship(rel1);
    try cartridge.addRelationship(rel2);
    try cartridge.addRelationship(rel3);

    var paths = try cartridge.bfs(a_id, 2, null);
    defer {
        for (paths.items) |*p| p.deinit(std.testing.allocator);
        paths.deinit(std.testing.allocator);
    }

    // Should find paths to b (depth 1) and c (depth 2), but not d (depth 3)
    try std.testing.expect(paths.items.len > 0);
}

test "RelationshipCartridge.findAllPaths" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const a_id = EntityId{ .namespace = "file", .local_id = "a.zig" };
    const b_id = EntityId{ .namespace = "file", .local_id = "b.zig" };

    // a -> b (twice via different rel types)
    var rel1 = try Relationship.init(std.testing.allocator, a_id, b_id, .imports, 0.8, 100);
    defer rel1.deinit(std.testing.allocator);
    var rel2 = try Relationship.init(std.testing.allocator, a_id, b_id, .calls, 0.9, 100);
    defer rel2.deinit(std.testing.allocator);

    try cartridge.addRelationship(rel1);
    try cartridge.addRelationship(rel2);

    var paths = try cartridge.findAllPaths(a_id, b_id, 3);
    defer {
        for (paths.items) |*p| p.deinit(std.testing.allocator);
        paths.deinit(std.testing.allocator);
    }

    // Should find 2 paths (one for each relationship type)
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
}

test "RelationshipCartridge.getNeighbors" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const a_id = EntityId{ .namespace = "file", .local_id = "a.zig" };
    const b_id = EntityId{ .namespace = "file", .local_id = "b.zig" };
    const c_id = EntityId{ .namespace = "file", .local_id = "c.zig" };
    const d_id = EntityId{ .namespace = "file", .local_id = "d.zig" };

    // a -> b -> c, and a -> d
    var rel1 = try Relationship.init(std.testing.allocator, a_id, b_id, .imports, 0.8, 100);
    defer rel1.deinit(std.testing.allocator);
    var rel2 = try Relationship.init(std.testing.allocator, b_id, c_id, .imports, 0.8, 100);
    defer rel2.deinit(std.testing.allocator);
    var rel3 = try Relationship.init(std.testing.allocator, a_id, d_id, .calls, 0.9, 100);
    defer rel3.deinit(std.testing.allocator);

    try cartridge.addRelationship(rel1);
    try cartridge.addRelationship(rel2);
    try cartridge.addRelationship(rel3);

    var neighbors = try cartridge.getNeighbors(a_id, 2, null);
    defer {
        for (neighbors.items) |*n| {
            std.testing.allocator.free(n.namespace);
            std.testing.allocator.free(n.local_id);
        }
        neighbors.deinit(std.testing.allocator);
    }

    // Should find b, c (via b), and d
    try std.testing.expect(neighbors.items.len >= 2);
}

test "RelationshipCartridge.getNeighbors withFilter" {
    var cartridge = try RelationshipCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const a_id = EntityId{ .namespace = "file", .local_id = "a.zig" };
    const b_id = EntityId{ .namespace = "file", .local_id = "b.zig" };
    const c_id = EntityId{ .namespace = "file", .local_id = "c.zig" };

    // a -> b (imports), a -> c (calls)
    var rel1 = try Relationship.init(std.testing.allocator, a_id, b_id, .imports, 0.8, 100);
    defer rel1.deinit(std.testing.allocator);
    var rel2 = try Relationship.init(std.testing.allocator, a_id, c_id, .calls, 0.9, 100);
    defer rel2.deinit(std.testing.allocator);

    try cartridge.addRelationship(rel1);
    try cartridge.addRelationship(rel2);

    var neighbors = try cartridge.getNeighbors(a_id, 1, .imports);
    defer {
        for (neighbors.items) |*n| {
            std.testing.allocator.free(n.namespace);
            std.testing.allocator.free(n.local_id);
        }
        neighbors.deinit(std.testing.allocator);
    }

    // Should only find b (imports relationship)
    try std.testing.expectEqual(@as(usize, 1), neighbors.items.len);
    try std.testing.expectEqualStrings("b.zig", neighbors.items[0].local_id);
}

test "GraphPath.addElement" {
    var path = GraphPath.init(std.testing.allocator);
    defer path.deinit(std.testing.allocator);

    const elem = PathElement{
        .entity_id = .{ .namespace = "file", .local_id = "test.zig" },
        .relationship_type = .imports,
        .strength = 0.8,
    };

    // Note: this will leak since we're using a stack-allocated EntityId
    // In real usage, entity_id strings should be allocated
    const elem_copy = PathElement{
        .entity_id = .{
            .namespace = try std.testing.allocator.dupe(u8, elem.entity_id.namespace),
            .local_id = try std.testing.allocator.dupe(u8, elem.entity_id.local_id),
        },
        .relationship_type = elem.relationship_type,
        .strength = elem.strength,
    };
    try path.addElement(std.testing.allocator, elem_copy);

    try std.testing.expectEqual(@as(usize, 1), path.elements.items.len);
    try std.testing.expectEqual(@as(f32, 0.8), path.total_strength);
}
