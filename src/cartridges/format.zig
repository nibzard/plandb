//! Cartridge artifact format implementation for NorthstarDB
//!
//! Provides the core cartridge format structures including versioning,
//! serialization, and invalidation policies as specified in spec/cartridge_format_v1.md

const std = @import("std");

/// Magic number for cartridge files: "NCAR" (0x4E434152)
pub const CARTRIDGE_MAGIC: u32 = 0x4E434152;

/// Current cartridge format version
pub const CARTRIDGE_VERSION = Version{
    .major = 1,
    .minor = 0,
    .patch = 0,
};

/// Commit record for invalidation checking
pub const CommitRecord = struct {
    txn_id: u64,
    root_page_id: u64,
    mutations: []const Mutation,
    checksum: u32,
};

/// Mutation type for invalidation pattern matching
pub const Mutation = union(enum) {
    put: struct {
        key: []const u8,
        value: []const u8,
    },
    delete: struct {
        key: []const u8,
    },

    pub fn getKey(self: @This()) []const u8 {
        return switch (self) {
            .put => |p| p.key,
            .delete => |d| d.key,
        };
    }
};

/// Semantic version for cartridge format
pub const Version = struct {
    major: u8,
    minor: u8,
    patch: u8,

    pub fn format(v: Version, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch unreachable;
    }

    pub fn compatVersion(v: Version) Compatibility {
        if (v.major == 1 and v.minor == 0) return .v1_0;
        return .unknown;
    }

    pub fn canRead(reader: Version, writer: Version) bool {
        // Same major and same minor: fully compatible
        if (reader.major == writer.major and reader.minor == writer.minor) return true;
        // Reader major > writer major: backward incompatible
        if (reader.major > writer.major) return false;
        // Reader same major, higher minor: can read older minor
        if (reader.major == writer.major and reader.minor > writer.minor) return true;
        return false;
    }

    pub const Compatibility = enum {
        v1_0,
        unknown,
    };
};

/// Cartridge type identifiers
pub const CartridgeType = enum(u32) {
    /// Pending tasks grouped by type for fast task queue operations
    pending_tasks_by_type = 0x50544254, // "PTBT"
    /// Entity storage with attributes and metadata
    entity_index = 0x454E5449, // "ENTI"
    /// Inverted term index for topic-based search
    topic_index = 0x544F5049, // "TOPI"
    /// Entity relationship graph
    relationship_graph = 0x52454C47, // "RELG"
    /// Custom user-defined cartridge type
    custom = 0x43555354, // "CUST"

    pub fn fromUint(v: u32) !CartridgeType {
        return std.meta.intToEnum(CartridgeType, v);
    }

    pub fn toString(ct: CartridgeType) []const u8 {
        return switch (ct) {
            .pending_tasks_by_type => "pending_tasks_by_type",
            .entity_index => "entity_index",
            .topic_index => "topic_index",
            .relationship_graph => "relationship_graph",
            .custom => "custom",
        };
    }

    pub fn fromString(s: []const u8) !CartridgeType {
        if (std.mem.eql(u8, s, "pending_tasks_by_type")) return .pending_tasks_by_type;
        if (std.mem.eql(u8, s, "entity_index")) return .entity_index;
        if (std.mem.eql(u8, s, "topic_index")) return .topic_index;
        if (std.mem.eql(u8, s, "relationship_index")) return .relationship_graph;
        if (std.mem.eql(u8, s, "custom")) return .custom;
        return error.UnknownCartridgeType;
    }
};

/// Feature flags for cartridge capabilities
pub const FeatureFlags = packed struct(u8) {
    /// Data section is compressed (LZ4)
    compressed: bool = false,
    /// Data section is encrypted
    encrypted: bool = false,
    /// Per-entry checksums present
    checksummed: bool = true,
    /// Includes temporal index for time-travel queries
    temporal: bool = false,
    /// Reserved for future use
    _reserved: u4 = 0,
};

/// Global cartridge file header (64 bytes)
pub const CartridgeHeader = struct {
    /// Magic number: "NCAR" (0x4E434152)
    magic: u32 = CARTRIDGE_MAGIC,
    /// Cartridge format version
    version: Version = CARTRIDGE_VERSION,
    /// Feature flags
    flags: FeatureFlags = .{},
    /// Cartridge type identifier
    cartridge_type: CartridgeType,
    /// Unix timestamp of creation
    created_at: u64,
    /// Last transaction ID in source database
    source_txn_id: u64,
    /// Number of entries in cartridge
    entry_count: u64,
    /// Offset to index section
    index_offset: u64,
    /// Offset to data section
    data_offset: u64,
    /// Offset to metadata section
    metadata_offset: u64,
    /// CRC32C of entire file (this field 0 during calculation)
    checksum: u32,

    pub const SIZE: usize = 64;

    pub fn init(cartridge_type: CartridgeType, source_txn_id: u64) CartridgeHeader {
        const timestamp = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000_000)));
        return CartridgeHeader{
            .cartridge_type = cartridge_type,
            .created_at = timestamp,
            .source_txn_id = source_txn_id,
            .entry_count = 0,
            .index_offset = SIZE, // Index starts right after header
            .data_offset = 0,     // Will be calculated during build
            .metadata_offset = 0, // Will be calculated during build
            .checksum = 0,
        };
    }

    pub fn serialize(header: CartridgeHeader, writer: anytype) !void {
        try writer.writeInt(u32, header.magic, .little);
        try writer.writeByte(header.version.major);
        try writer.writeByte(header.version.minor);
        try writer.writeByte(header.version.patch);
        try writer.writeByte(@as(u8, @bitCast(header.flags)));
        try writer.writeInt(u32, @intFromEnum(header.cartridge_type), .little);
        try writer.writeInt(u64, header.created_at, .little);
        try writer.writeInt(u64, header.source_txn_id, .little);
        try writer.writeInt(u64, header.entry_count, .little);
        try writer.writeInt(u64, header.index_offset, .little);
        try writer.writeInt(u64, header.data_offset, .little);
        try writer.writeInt(u64, header.metadata_offset, .little);
        try writer.writeInt(u32, header.checksum, .little);
    }

    pub fn deserialize(reader: anytype) !CartridgeHeader {
        const magic = try reader.readInt(u32, .little);
        if (magic != CARTRIDGE_MAGIC) return error.InvalidMagic;

        const major = try reader.readByte();
        const minor = try reader.readByte();
        const patch = try reader.readByte();
        const flags_byte = try reader.readByte();
        const type_value = try reader.readInt(u32, .little);
        const created_at = try reader.readInt(u64, .little);
        const source_txn_id = try reader.readInt(u64, .little);
        const entry_count = try reader.readInt(u64, .little);
        const index_offset = try reader.readInt(u64, .little);
        const data_offset = try reader.readInt(u64, .little);
        const metadata_offset = try reader.readInt(u64, .little);
        const checksum = try reader.readInt(u32, .little);

        const cartridge_type = try CartridgeType.fromUint(type_value);

        return CartridgeHeader{
            .magic = magic,
            .version = .{ .major = major, .minor = minor, .patch = patch },
            .flags = @bitCast(flags_byte),
            .cartridge_type = cartridge_type,
            .created_at = created_at,
            .source_txn_id = source_txn_id,
            .entry_count = entry_count,
            .index_offset = index_offset,
            .data_offset = data_offset,
            .metadata_offset = metadata_offset,
            .checksum = checksum,
        };
    }

    pub fn validate(header: CartridgeHeader) !void {
        if (header.magic != CARTRIDGE_MAGIC) return error.InvalidMagic;
        if (header.version.major > CARTRIDGE_VERSION.major) {
            return error.UnsupportedVersion;
        }
    }
};

/// Invalidation pattern for cartridge rebuild triggers
pub const InvalidationPattern = struct {
    key_prefix: []const u8,
    check_mutation_type: bool,
    mutation_type: ?InvalidationMutationType,

    pub fn deinit(self: *InvalidationPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.key_prefix);
    }
};

/// Mutation type for invalidation pattern matching
pub const InvalidationMutationType = enum {
    put,
    delete,
    any,
};

/// Invalidation policy for cartridge rebuilds
/// NOTE: Uses a simple fixed-size array for patterns. Will upgrade to dynamic
/// allocation once the ArrayList compatibility issue is resolved.
pub const InvalidationPolicy = struct {
    /// Maximum age before rebuild is recommended (seconds, 0 = no limit)
    max_age_seconds: u64,
    /// Minimum transaction count before incremental rebuild
    min_new_txns: u64,
    /// Maximum transaction count before full rebuild
    max_new_txns: u64,
    /// Number of patterns stored
    pattern_count: u32,
    /// Patterns that trigger invalidation (fixed-size array for now)
    patterns: [16]InvalidationPattern,

    pub fn default() InvalidationPolicy {
        return InvalidationPolicy{
            .max_age_seconds = 86400, // 24 hours
            .min_new_txns = 100,
            .max_new_txns = 10000,
            .pattern_count = 0,
            .patterns = undefined,
        };
    }

    pub fn init(allocator: std.mem.Allocator) InvalidationPolicy {
        _ = allocator;
        return InvalidationPolicy{
            .max_age_seconds = 86400, // 24 hours
            .min_new_txns = 100,
            .max_new_txns = 10000,
            .pattern_count = 0,
            .patterns = undefined,
        };
    }

    pub fn deinit(self: *InvalidationPolicy, allocator: std.mem.Allocator) void {
        var i: u32 = 0;
        while (i < self.pattern_count) : (i += 1) {
            self.patterns[i].deinit(allocator);
        }
    }

    pub fn addPattern(self: *InvalidationPolicy, allocator: std.mem.Allocator, pattern: InvalidationPattern) !void {
        _ = allocator;
        if (self.pattern_count >= 16) return error.TooManyPatterns;
        self.patterns[self.pattern_count] = pattern;
        self.pattern_count += 1;
    }

    pub fn serializedSize(self: *const InvalidationPolicy) usize {
        var size: usize = 8 + 8 + 8; // max_age, min_txns, max_txns
        size += 4; // pattern count
        var i: u32 = 0;
        while (i < self.pattern_count) : (i += 1) {
            const pattern = self.patterns[i];
            size += 2; // prefix length
            size += pattern.key_prefix.len;
            size += 1; // flags
            if (pattern.check_mutation_type) {
                size += 1; // mutation type
            }
        }
        return size;
    }

    pub fn serialize(self: *const InvalidationPolicy, writer: anytype) !void {
        try writer.writeInt(u64, self.max_age_seconds, .little);
        try writer.writeInt(u64, self.min_new_txns, .little);
        try writer.writeInt(u64, self.max_new_txns, .little);
        try writer.writeInt(u32, self.pattern_count, .little);

        var i: u32 = 0;
        while (i < self.pattern_count) : (i += 1) {
            const pattern = self.patterns[i];
            try writer.writeInt(u16, @intCast(pattern.key_prefix.len), .little);
            try writer.writeAll(pattern.key_prefix);

            var flags: u8 = 0;
            if (pattern.check_mutation_type) flags |= 0x01;
            try writer.writeByte(flags);

            if (pattern.check_mutation_type) {
                const mt_val: u8 = if (pattern.mutation_type) |mt| switch (mt) {
                    .put => 1,
                    .delete => 2,
                    .any => 0,
                } else 0;
                try writer.writeByte(mt_val);
            }
        }
    }

    pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !InvalidationPolicy {
        const max_age = try reader.readInt(u64, .little);
        const min_txns = try reader.readInt(u64, .little);
        const max_txns = try reader.readInt(u64, .little);
        const pattern_count = try reader.readInt(u32, .little);

        if (pattern_count > 16) return error.TooManyPatterns;

        var policy = InvalidationPolicy{
            .max_age_seconds = max_age,
            .min_new_txns = min_txns,
            .max_new_txns = max_txns,
            .pattern_count = pattern_count,
            .patterns = undefined,
        };

        var i: u32 = 0;
        while (i < pattern_count) : (i += 1) {
            const prefix_len = try reader.readInt(u16, .little);
            const prefix = try allocator.alloc(u8, prefix_len);
            try reader.readNoEof(prefix);

            const flags = try reader.readByte();
            const check_mutation_type = (flags & 0x01) != 0;

            var mutation_type: ?InvalidationMutationType = null;
            if (check_mutation_type) {
                const mt_val = try reader.readByte();
                mutation_type = switch (mt_val) {
                    1 => .put,
                    2 => .delete,
                    0 => .any,
                    else => return error.InvalidMutationType,
                };
            }

            policy.patterns[i] = .{
                .key_prefix = prefix,
                .check_mutation_type = check_mutation_type,
                .mutation_type = mutation_type,
            };
        }

        return policy;
    }

    /// Check if a transaction should invalidate this cartridge
    pub fn shouldInvalidate(
        policy: *const InvalidationPolicy,
        commit_record: CommitRecord,
        current_txn_id: u64,
        cartridge_txn_id: u64
    ) bool {
        // Check if too many transactions have passed
        const new_txn_count = current_txn_id - cartridge_txn_id;
        if (new_txn_count >= policy.max_new_txns) return true;

        // Check invalidation patterns
        var i: u32 = 0;
        while (i < policy.pattern_count) : (i += 1) {
            const pattern = policy.patterns[i];
            for (commit_record.mutations) |mutation| {
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

/// Cartridge metadata section
pub const CartridgeMetadata = struct {
    /// Format name (e.g., "pending_tasks_by_type_v1")
    format_name: []const u8,
    /// Schema version for this cartridge type
    schema_version: SchemaVersion,
    /// Time taken to build in milliseconds
    build_time_ms: u64,
    /// Hash of source database file (SHA-256, 32 bytes)
    source_db_hash: [32]u8,
    /// Builder version string
    builder_version: []const u8,
    /// Invalidation policy for this cartridge
    invalidation_policy: InvalidationPolicy,

    pub const SchemaVersion = struct {
        major: u32,
        minor: u32,
        patch: u32,
    };

    pub fn init(format_name: []const u8, allocator: std.mem.Allocator) CartridgeMetadata {
        return CartridgeMetadata{
            .format_name = allocator.dupe(u8, format_name) catch unreachable,
            .schema_version = .{ .major = 1, .minor = 0, .patch = 0 },
            .build_time_ms = 0,
            .source_db_hash = [_]u8{0} ** 32,
            .builder_version = allocator.dupe(u8, "northstar_db.cartridge.v1") catch unreachable,
            .invalidation_policy = InvalidationPolicy.default(),
        };
    }

    pub fn serializedSize(metadata: CartridgeMetadata) usize {
        return 32 + // format_name (fixed size)
            12 + // schema_version (3 x u32)
            8 + // build_time_ms
            32 + // source_db_hash
            32 + // builder_version (fixed size)
            metadata.invalidation_policy.serializedSize();
    }

    pub fn serialize(metadata: CartridgeMetadata, writer: anytype) !void {
        // Write format_name (32 bytes, null-padded)
        var name_buf: [32]u8 = [_]u8{0} ** 32;
        const copy_len = @min(metadata.format_name.len, 31);
        @memcpy(name_buf[0..copy_len], metadata.format_name[0..copy_len]);
        try writer.writeAll(&name_buf);

        // Write schema version
        try writer.writeInt(u32, metadata.schema_version.major, .little);
        try writer.writeInt(u32, metadata.schema_version.minor, .little);
        try writer.writeInt(u32, metadata.schema_version.patch, .little);

        // Write build time
        try writer.writeInt(u64, metadata.build_time_ms, .little);

        // Write source DB hash
        try writer.writeAll(&metadata.source_db_hash);

        // Write builder version (32 bytes, null-padded)
        var builder_buf: [32]u8 = [_]u8{0} ** 32;
        const builder_copy_len = @min(metadata.builder_version.len, 31);
        @memcpy(builder_buf[0..builder_copy_len], metadata.builder_version[0..builder_copy_len]);
        try writer.writeAll(&builder_buf);

        // Write invalidation policy
        try metadata.invalidation_policy.serialize(writer);
    }

    pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !CartridgeMetadata {
        var format_name_buf: [32]u8 = undefined;
        try reader.readNoEof(format_name_buf[0..]);
        const format_name = try allocator.dupe(u8, std.mem.sliceTo(format_name_buf[0..], 0));

        const schema_major = try reader.readInt(u32, .little);
        const schema_minor = try reader.readInt(u32, .little);
        const schema_patch = try reader.readInt(u32, .little);
        const build_time_ms = try reader.readInt(u64, .little);

        var source_hash: [32]u8 = undefined;
        try reader.readNoEof(source_hash[0..]);

        var builder_buf: [32]u8 = undefined;
        try reader.readNoEof(builder_buf[0..]);
        const builder_version = try allocator.dupe(u8, std.mem.sliceTo(builder_buf[0..], 0));

        const invalidation_policy = try InvalidationPolicy.deserialize(reader, allocator);

        return CartridgeMetadata{
            .format_name = format_name,
            .schema_version = .{
                .major = schema_major,
                .minor = schema_minor,
                .patch = schema_patch,
            },
            .build_time_ms = build_time_ms,
            .source_db_hash = source_hash,
            .builder_version = builder_version,
            .invalidation_policy = invalidation_policy,
        };
    }

    pub fn deinit(metadata: CartridgeMetadata, allocator: std.mem.Allocator) void {
        allocator.free(metadata.format_name);
        allocator.free(metadata.builder_version);
        @constCast(&metadata.invalidation_policy).deinit(allocator);
    }
};

/// Error set for cartridge operations
pub const CartridgeError = error{
    InvalidMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    CorruptedData,
    InvalidCartridgeType,
    MissingRequiredFeature,
    NotFound,
    OutOfMemory,
    PermissionDenied,
    Locked,
    NeedsRebuild,
    TooManyPatterns,
    InvalidMutationType,
};

// ==================== Tests ====================

test "Version.format" {
    const v = Version{ .major = 1, .minor = 2, .patch = 3 };
    var buf: [16]u8 = undefined;
    const result = v.format(&buf);
    try std.testing.expectEqualStrings("1.2.3", result);
}

test "Version.canRead compatibility matrix" {
    const v100 = Version{ .major = 1, .minor = 0, .patch = 0 };
    const v110 = Version{ .major = 1, .minor = 1, .patch = 0 };
    const v200 = Version{ .major = 2, .minor = 0, .patch = 0 };

    // Same version: can read
    try std.testing.expect(Version.canRead(v100, v100));

    // Reader higher minor: can read older
    try std.testing.expect(Version.canRead(v110, v100));

    // Reader lower minor: cannot read newer
    try std.testing.expect(!Version.canRead(v100, v110));

    // Different major: cannot read
    try std.testing.expect(!Version.canRead(v200, v100));
}

test "CartridgeType.toString and fromString" {
    const ct = CartridgeType.pending_tasks_by_type;
    try std.testing.expectEqualStrings("pending_tasks_by_type", ct.toString());

    const parsed = try CartridgeType.fromString("pending_tasks_by_type");
    try std.testing.expectEqual(ct, parsed);
}

test "CartridgeHeader.init" {
    const header = CartridgeHeader.init(.pending_tasks_by_type, 12345);
    try std.testing.expectEqual(CARTRIDGE_MAGIC, header.magic);
    try std.testing.expectEqual(@as(u8, 1), header.version.major);
    try std.testing.expectEqual(CartridgeType.pending_tasks_by_type, header.cartridge_type);
    try std.testing.expectEqual(@as(u64, 12345), header.source_txn_id);
}

test "CartridgeHeader.serialize roundtrip" {
    const original = CartridgeHeader.init(.entity_index, 67890);

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try original.serialize(fbs.writer());

    fbs.pos = 0;
    const deserialized = try CartridgeHeader.deserialize(fbs.reader());

    try std.testing.expectEqual(original.magic, deserialized.magic);
    try std.testing.expectEqual(original.version.major, deserialized.version.major);
    try std.testing.expectEqual(original.cartridge_type, deserialized.cartridge_type);
    try std.testing.expectEqual(original.source_txn_id, deserialized.source_txn_id);
}

test "CartridgeHeader.validate rejects invalid magic" {
    var header = CartridgeHeader.init(.custom, 1);
    header.magic = 0xBADBEEF;
    try std.testing.expectError(CartridgeError.InvalidMagic, header.validate());
}

test "CartridgeHeader.validate rejects unsupported version" {
    var header = CartridgeHeader.init(.custom, 1);
    header.version.major = 255; // Way ahead of current version
    try std.testing.expectError(CartridgeError.UnsupportedVersion, header.validate());
}

test "InvalidationPolicy.default" {
    const policy = InvalidationPolicy.default();
    try std.testing.expectEqual(@as(u64, 86400), policy.max_age_seconds);
    try std.testing.expectEqual(@as(u64, 100), policy.min_new_txns);
    try std.testing.expectEqual(@as(u64, 10000), policy.max_new_txns);
    try std.testing.expectEqual(@as(u32, 0), policy.pattern_count);
}

test "InvalidationPolicy.addPattern" {
    var policy = InvalidationPolicy.init(std.testing.allocator);
    defer policy.deinit(std.testing.allocator);

    const prefix = try std.testing.allocator.dupe(u8, "task:");
    // Note: don't free prefix here, since it's now owned by the policy

    try policy.addPattern(std.testing.allocator, .{
        .key_prefix = prefix,
        .check_mutation_type = true,
        .mutation_type = .put,
    });

    try std.testing.expectEqual(@as(u32, 1), policy.pattern_count);
    try std.testing.expectEqualStrings("task:", policy.patterns[0].key_prefix);
}

test "InvalidationPolicy.shouldInvalidate respects max_new_txns" {
    var policy = InvalidationPolicy.init(std.testing.allocator);
    defer policy.deinit(std.testing.allocator);
    policy.max_new_txns = 100;

    const mutations = [_]Mutation{};
    const commit_record = CommitRecord{
        .txn_id = 200,
        .root_page_id = 1,
        .mutations = &mutations,
        .checksum = 0,
    };

    // Exactly at limit: should invalidate
    try std.testing.expect(policy.shouldInvalidate(commit_record, 200, 100));

    // Under limit: should not invalidate
    try std.testing.expect(!policy.shouldInvalidate(commit_record, 150, 100));
}

test "InvalidationPolicy.shouldInvalidate respects patterns" {
    var policy = InvalidationPolicy.init(std.testing.allocator);
    defer policy.deinit(std.testing.allocator);
    policy.max_new_txns = 1000; // High limit

    // Add pattern: task:* keys with PUT should invalidate
    const prefix = try std.testing.allocator.dupe(u8, "task:");
    try policy.addPattern(std.testing.allocator, .{
        .key_prefix = prefix,
        .check_mutation_type = true,
        .mutation_type = .put,
    });

    const mutations = [_]Mutation{
        Mutation{ .put = .{ .key = "task:123", .value = "data" } },
    };
    const commit_record = CommitRecord{
        .txn_id = 105,
        .root_page_id = 1,
        .mutations = &mutations,
        .checksum = 0,
    };

    // Matching pattern: should invalidate
    try std.testing.expect(policy.shouldInvalidate(commit_record, 105, 100));

    // Non-matching key type: should not invalidate
    const mutations2 = [_]Mutation{
        Mutation{ .put = .{ .key = "other:123", .value = "data" } },
    };
    const commit_record2 = CommitRecord{
        .txn_id = 105,
        .root_page_id = 1,
        .mutations = &mutations2,
        .checksum = 0,
    };
    try std.testing.expect(!policy.shouldInvalidate(commit_record2, 105, 100));
}

test "InvalidationPolicy.serialize roundtrip" {
    var policy = InvalidationPolicy.init(std.testing.allocator);
    defer policy.deinit(std.testing.allocator);
    policy.max_age_seconds = 3600;
    policy.min_new_txns = 50;
    policy.max_new_txns = 500;

    // Add a pattern
    const prefix = try std.testing.allocator.dupe(u8, "test:");
    try policy.addPattern(std.testing.allocator, .{
        .key_prefix = prefix,
        .check_mutation_type = false,
        .mutation_type = null,
    });

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try policy.serialize(fbs.writer());

    fbs.pos = 0;
    var deserialized = try InvalidationPolicy.deserialize(fbs.reader(), std.testing.allocator);
    defer deserialized.deinit(std.testing.allocator);

    try std.testing.expectEqual(policy.max_age_seconds, deserialized.max_age_seconds);
    try std.testing.expectEqual(policy.min_new_txns, deserialized.min_new_txns);
    try std.testing.expectEqual(policy.max_new_txns, deserialized.max_new_txns);
    try std.testing.expectEqual(@as(u32, 1), deserialized.pattern_count);
    try std.testing.expectEqualStrings("test:", deserialized.patterns[0].key_prefix);
}
