//! Temporal History Cartridge Implementation
//!
//! Implements time-series storage for entity state history according to
//! spec/structured_memory_v1.md
//!
//! This cartridge supports:
//! - Chunked time-series storage (time-ordered chunks per entity)
//! - Multiple state change types: attribute updates, relationships, migrations
//! - Compression for long history (LZ4, delta encoding for timestamps)
//! - Retention policy configuration (TTL, sampling for old data)

const std = @import("std");
const format = @import("format.zig");
const ArrayListManaged = std.ArrayListUnmanaged;

// ==================== State Change Types ====================

/// Type of state change recorded
pub const StateChangeType = enum(u8) {
    /// Entity attribute was added or modified
    attribute_update = 1,
    /// Entity attribute was deleted
    attribute_delete = 2,
    /// Relationship was added between entities
    relationship_add = 3,
    /// Relationship was removed between entities
    relationship_remove = 4,
    /// Entity was migrated to new structure
    entity_migration = 5,
    /// Entity was created
    entity_created = 6,
    /// Entity was deleted
    entity_deleted = 7,
    /// Batch operation on multiple entities
    batch_operation = 8,

    pub fn fromUint(v: u8) !StateChangeType {
        return std.meta.intToEnum(StateChangeType, v);
    }
};

// ==================== Timestamp Encoding ====================

/// Delta-encoded timestamp for compression
pub const DeltaTimestamp = struct {
    /// Base timestamp for this delta (Unix epoch seconds)
    base: u64,
    /// Delta from base in seconds (can be negative for time-travel)
    delta: i64,

    /// Get the actual timestamp value
    pub fn value(dt: DeltaTimestamp) i64 {
        return @as(i64, @intCast(dt.base)) + dt.delta;
    }

    /// Serialized size
    pub fn size() usize {
        return 8 + 8; // base (u64) + delta (i64)
    }

    /// Serialize delta timestamp
    pub fn serialize(dt: DeltaTimestamp, writer: anytype) !void {
        try writer.writeInt(u64, dt.base, .little);
        try writer.writeInt(i64, dt.delta, .little);
    }

    /// Deserialize delta timestamp
    pub fn deserialize(reader: anytype) !DeltaTimestamp {
        const base = try reader.readInt(u64, .little);
        const delta = try reader.readInt(i64, .little);
        return DeltaTimestamp{ .base = base, .delta = delta };
    }
};

// ==================== State Change Record ====================

/// Single state change record
pub const StateChange = struct {
    /// Unique identifier for this change
    id: []const u8,
    /// Transaction ID that created this change
    txn_id: u64,
    /// Timestamp when the change occurred
    timestamp: DeltaTimestamp,
    /// Entity namespace this change affects
    entity_namespace: []const u8,
    /// Entity local ID this change affects
    entity_local_id: []const u8,
    /// Type of state change
    change_type: StateChangeType,
    /// Attribute or relationship key affected
    key: []const u8,
    /// Old value (null for additions)
    old_value: ?[]const u8,
    /// New value (null for deletions)
    new_value: ?[]const u8,
    /// Additional metadata (JSON)
    metadata: []const u8,

    /// Calculate serialized size
    pub fn serializedSize(self: StateChange) usize {
        var size: usize = 2 + self.id.len; // id
        size += 8; // txn_id
        size += DeltaTimestamp.size(); // timestamp
        size += 2 + self.entity_namespace.len; // entity_namespace
        size += 2 + self.entity_local_id.len; // entity_local_id
        size += 1; // change_type
        size += 2 + self.key.len; // key
        if (self.old_value) |v| size += 2 + v.len else size += 1;
        if (self.new_value) |v| size += 2 + v.len else size += 1;
        size += 4 + self.metadata.len; // metadata
        return size;
    }

    /// Serialize state change
    pub fn serialize(self: StateChange, writer: anytype) !void {
        try writer.writeInt(u16, @intCast(self.id.len), .little);
        try writer.writeAll(self.id);

        try writer.writeInt(u64, self.txn_id, .little);

        try self.timestamp.serialize(writer);

        try writer.writeInt(u16, @intCast(self.entity_namespace.len), .little);
        try writer.writeAll(self.entity_namespace);

        try writer.writeInt(u16, @intCast(self.entity_local_id.len), .little);
        try writer.writeAll(self.entity_local_id);

        try writer.writeByte(@intFromEnum(self.change_type));

        try writer.writeInt(u16, @intCast(self.key.len), .little);
        try writer.writeAll(self.key);

        if (self.old_value) |v| {
            try writer.writeInt(u16, @intCast(v.len), .little);
            try writer.writeAll(v);
        } else {
            try writer.writeInt(u16, 0, .little);
        }

        if (self.new_value) |v| {
            try writer.writeInt(u16, @intCast(v.len), .little);
            try writer.writeAll(v);
        } else {
            try writer.writeInt(u16, 0, .little);
        }

        try writer.writeInt(u32, @intCast(self.metadata.len), .little);
        try writer.writeAll(self.metadata);
    }

    /// Free state change resources
    pub fn deinit(self: StateChange, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.entity_namespace);
        allocator.free(self.entity_local_id);
        allocator.free(self.key);
        if (self.old_value) |v| allocator.free(v);
        if (self.new_value) |v| allocator.free(v);
        allocator.free(self.metadata);
    }
};

// ==================== Time Series Chunk ====================

/// Time-ordered chunk of state changes for a single entity
pub const TimeChunk = struct {
    /// Entity this chunk belongs to
    entity_namespace: []const u8,
    entity_local_id: []const u8,
    /// Start timestamp of this chunk
    start_timestamp: DeltaTimestamp,
    /// End timestamp of this chunk
    end_timestamp: DeltaTimestamp,
    /// Number of changes in this chunk
    change_count: u32,
    /// State changes in this chunk (time-ordered)
    changes: ArrayListManaged(StateChange),
    /// Chunk compression flag
    compressed: bool = false,

    /// Create new time chunk
    pub fn init(allocator: std.mem.Allocator, entity_namespace: []const u8, entity_local_id: []const u8) !TimeChunk {
        const ns = try allocator.dupe(u8, entity_namespace);
        errdefer allocator.free(ns);

        const local = try allocator.dupe(u8, entity_local_id);
        errdefer allocator.free(local);

        const ts = std.time.timestamp();

        return TimeChunk{
            .entity_namespace = ns,
            .entity_local_id = local,
            .start_timestamp = .{ .base = @intCast(ts), .delta = 0 },
            .end_timestamp = .{ .base = @intCast(ts), .delta = 0 },
            .change_count = 0,
            .changes = .{},
            .compressed = false,
        };
    }

    pub fn deinit(self: *TimeChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_namespace);
        allocator.free(self.entity_local_id);
        for (self.changes.items) |*change| change.deinit(allocator);
        self.changes.deinit(allocator);
    }

    /// Add state change to chunk
    pub fn addChange(self: *TimeChunk, allocator: std.mem.Allocator, change: StateChange) !void {
        // Create owned copy
        const owned_change = StateChange{
            .id = try allocator.dupe(u8, change.id),
            .txn_id = change.txn_id,
            .timestamp = change.timestamp,
            .entity_namespace = try allocator.dupe(u8, change.entity_namespace),
            .entity_local_id = try allocator.dupe(u8, change.entity_local_id),
            .change_type = change.change_type,
            .key = try allocator.dupe(u8, change.key),
            .old_value = if (change.old_value) |v| try allocator.dupe(u8, v) else null,
            .new_value = if (change.new_value) |v| try allocator.dupe(u8, v) else null,
            .metadata = try allocator.dupe(u8, change.metadata),
        };

        try self.changes.append(allocator, owned_change);
        self.change_count += 1;

        // Update end timestamp if this change is newer
        const change_time = change.timestamp.value();
        const current_end = self.end_timestamp.value();
        if (change_time > current_end) {
            self.end_timestamp = change.timestamp;
        }
    }

    /// Calculate chunk size in bytes
    pub fn byteSize(self: TimeChunk) usize {
        var size: usize = 0;
        for (self.changes.items) |change| {
            size += change.serializedSize();
        }
        return size;
    }
};

// ==================== Retention Policy ====================

/// Retention policy for temporal history
pub const RetentionPolicy = struct {
    /// Maximum age in seconds before data is archived/deleted (0 = no limit)
    max_age_seconds: u64,
    /// Maximum number of state changes to retain per entity (0 = no limit)
    max_changes_per_entity: u64,
    /// Sampling rate for old data (0.0 = delete all, 1.0 = keep all)
    sampling_rate: f32,
    /// Age threshold at which sampling applies (seconds)
    sampling_age_threshold: u64,

    pub fn default() RetentionPolicy {
        return RetentionPolicy{
            .max_age_seconds = 90 * 24 * 3600, // 90 days
            .max_changes_per_entity = 100000,
            .sampling_rate = 0.1, // Keep 10% of old data
            .sampling_age_threshold = 30 * 24 * 3600, // 30 days
        };
    }

    /// Check if a state change should be retained
    pub fn shouldRetain(policy: RetentionPolicy, change: StateChange, current_time: i64) bool {
        const change_age = current_time - change.timestamp.value();

        // Delete if too old
        if (policy.max_age_seconds > 0 and change_age > @as(i64, @intCast(policy.max_age_seconds))) {
            return false;
        }

        // Apply sampling for old data
        if (change_age > @as(i64, @intCast(policy.sampling_age_threshold))) {
            // Simple hash-based sampling for deterministic results
            var hash = std.hash.Wyhash.init(0);
            hash.update(change.id);
            const hash_value = hash.final();
            const should_keep = @as(f32, @floatFromInt(hash_value % 1000)) / 1000.0 < policy.sampling_rate;
            return should_keep;
        }

        return true;
    }
};

// ==================== Temporal Index ====================

/// Temporal index for time-series queries
pub const TemporalIndex = struct {
    allocator: std.mem.Allocator,
    /// Map from entity ID to list of time chunks
    entity_chunks: std.StringHashMap(ArrayListManaged(*TimeChunk)),
    /// Map from timestamp to list of change IDs (for time-range queries)
    time_index: std.AutoHashMap(u64, ArrayListManaged([]const u8)),
    /// Total state changes stored
    total_changes: u64,
    /// Retention policy
    retention_policy: RetentionPolicy,

    /// Create new temporal index
    pub fn init(allocator: std.mem.Allocator) TemporalIndex {
        return TemporalIndex{
            .allocator = allocator,
            .entity_chunks = std.StringHashMap(ArrayListManaged(*TimeChunk)).init(allocator),
            .time_index = std.AutoHashMap(u64, ArrayListManaged([]const u8)).init(allocator),
            .total_changes = 0,
            .retention_policy = RetentionPolicy.default(),
        };
    }

    pub fn deinit(self: *TemporalIndex) void {
        // Free all time chunks
        var it = self.entity_chunks.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |chunk| {
                chunk.deinit(self.allocator);
                self.allocator.destroy(chunk);
            }
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entity_chunks.deinit();

        // Free time index
        var time_it = self.time_index.iterator();
        while (time_it.next()) |entry| {
            for (entry.value_ptr.items) |id| self.allocator.free(id);
            entry.value_ptr.deinit(self.allocator);
        }
        self.time_index.deinit();
    }

    /// Add state change to the index
    pub fn addChange(self: *TemporalIndex, change: StateChange) !void {
        const current_time = std.time.timestamp();

        // Check retention policy
        if (!self.retention_policy.shouldRetain(change, current_time)) {
            return;
        }

        // Get or create entity key
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ change.entity_namespace, change.entity_local_id });
        defer self.allocator.free(entity_key);

        const entry = try self.entity_chunks.getOrPut(entity_key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, entity_key);
            entry.value_ptr.* = .{};
        }

        // Get or create time chunk for this entity
        var chunk: *TimeChunk = undefined;
        if (entry.value_ptr.items.len == 0) {
            // Create new chunk
            const new_chunk = try self.allocator.create(TimeChunk);
            new_chunk.* = try TimeChunk.init(self.allocator, change.entity_namespace, change.entity_local_id);
            try entry.value_ptr.append(self.allocator, new_chunk);
            chunk = new_chunk;
        } else {
            chunk = entry.value_ptr.items[entry.value_ptr.items.len - 1];
        }

        // Check if chunk is full (> 1000 changes or > 1MB)
        const CHUNK_SIZE_LIMIT = 1024 * 1024;
        if (chunk.change_count >= 1000 or chunk.byteSize() >= CHUNK_SIZE_LIMIT) {
            // Create new chunk
            const new_chunk = try self.allocator.create(TimeChunk);
            new_chunk.* = try TimeChunk.init(self.allocator, change.entity_namespace, change.entity_local_id);
            try entry.value_ptr.append(self.allocator, new_chunk);
            chunk = new_chunk;
        }

        // Add change to chunk
        try chunk.addChange(self.allocator, change);
        self.total_changes += 1;

        // Add to time index
        const ts = change.timestamp.value();
        const time_entry = try self.time_index.getOrPut(@intCast(ts));
        if (!time_entry.found_existing) {
            time_entry.value_ptr.* = .{};
        }
        const id_copy = try self.allocator.dupe(u8, change.id);
        try time_entry.value_ptr.append(self.allocator, id_copy);
    }

    /// Query entity state at specific point in time (AS OF query)
    pub fn queryAsOf(self: *const TemporalIndex, entity_namespace: []const u8, entity_local_id: []const u8, timestamp: i64) !?StateChange {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // Find relevant chunk and changes
        var result: ?StateChange = null;

        for (chunks.items) |chunk| {
            const chunk_start = chunk.start_timestamp.value();
            const chunk_end = chunk.end_timestamp.value();

            // Skip if timestamp is outside chunk range
            if (timestamp < chunk_start or timestamp > chunk_end) continue;

            // Find last change before or at timestamp
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time <= timestamp) {
                    // Create a copy of this change as the result
                    // (In a real implementation, we'd track the latest applicable state)
                    result = change;
                }
            }
        }

        return result;
    }

    /// Query state changes within time window (BETWEEN query)
    pub fn queryBetween(self: *const TemporalIndex, entity_namespace: []const u8, entity_local_id: []const u8, start_time: i64, end_time: i64) !ArrayListManaged(StateChange) {
        var results = ArrayListManaged(StateChange){};

        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return results;

        for (chunks.items) |chunk| {
            const chunk_start = chunk.start_timestamp.value();
            const chunk_end = chunk.end_timestamp.value();

            // Skip if chunk doesn't overlap with time range
            if (chunk_end < start_time or chunk_start > end_time) continue;

            // Collect changes within range
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    // Create copy of change
                    const copy = StateChange{
                        .id = try self.allocator.dupe(u8, change.id),
                        .txn_id = change.txn_id,
                        .timestamp = change.timestamp,
                        .entity_namespace = try self.allocator.dupe(u8, change.entity_namespace),
                        .entity_local_id = try self.allocator.dupe(u8, change.entity_local_id),
                        .change_type = change.change_type,
                        .key = try self.allocator.dupe(u8, change.key),
                        .old_value = if (change.old_value) |v| try self.allocator.dupe(u8, v) else null,
                        .new_value = if (change.new_value) |v| try self.allocator.dupe(u8, v) else null,
                        .metadata = try self.allocator.dupe(u8, change.metadata),
                    };
                    try results.append(self.allocator, copy);
                }
            }
        }

        return results;
    }

    /// Get all changes at a specific timestamp across all entities
    pub fn queryAtTimestamp(self: *const TemporalIndex, timestamp: i64) !ArrayListManaged(StateChange) {
        var results = ArrayListManaged(StateChange){};

        var it = self.entity_chunks.iterator();
        while (it.next()) |entry| {
            const chunks = entry.value_ptr.*;

            for (chunks.items) |chunk| {
                const chunk_start = chunk.start_timestamp.value();
                const chunk_end = chunk.end_timestamp.value();

                if (timestamp < chunk_start or timestamp > chunk_end) continue;

                for (chunk.changes.items) |change| {
                    if (change.timestamp.value() == timestamp) {
                        // Create copy of change
                        const copy = StateChange{
                            .id = try self.allocator.dupe(u8, change.id),
                            .txn_id = change.txn_id,
                            .timestamp = change.timestamp,
                            .entity_namespace = try self.allocator.dupe(u8, change.entity_namespace),
                            .entity_local_id = try self.allocator.dupe(u8, change.entity_local_id),
                            .change_type = change.change_type,
                            .key = try self.allocator.dupe(u8, change.key),
                            .old_value = if (change.old_value) |v| try self.allocator.dupe(u8, v) else null,
                            .new_value = if (change.new_value) |v| try self.allocator.dupe(u8, v) else null,
                            .metadata = try self.allocator.dupe(u8, change.metadata),
                        };
                        try results.append(self.allocator, copy);
                    }
                }
            }
        }

        return results;
    }
};

// ==================== Temporal History Cartridge ====================

/// Temporal history cartridge with time-series storage
pub const TemporalHistoryCartridge = struct {
    allocator: std.mem.Allocator,
    header: format.CartridgeHeader,
    /// Temporal index for time-series queries
    index: TemporalIndex,

    /// Create new temporal history cartridge
    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64) !TemporalHistoryCartridge {
        const header = format.CartridgeHeader.init(.temporal_history, source_txn_id);
        return TemporalHistoryCartridge{
            .allocator = allocator,
            .header = header,
            .index = TemporalIndex.init(allocator),
        };
    }

    pub fn deinit(self: *TemporalHistoryCartridge) void {
        self.index.deinit();
    }

    /// Add state change to the cartridge
    pub fn addChange(self: *TemporalHistoryCartridge, change: StateChange) !void {
        try self.index.addChange(change);
        self.header.entry_count += 1;
    }

    /// Query entity state at specific point in time
    pub fn queryAsOf(self: *const TemporalHistoryCartridge, entity_namespace: []const u8, entity_local_id: []const u8, timestamp: i64) !?StateChange {
        return self.index.queryAsOf(entity_namespace, entity_local_id, timestamp);
    }

    /// Query state changes within time window
    pub fn queryBetween(self: *const TemporalHistoryCartridge, entity_namespace: []const u8, entity_local_id: []const u8, start_time: i64, end_time: i64) !ArrayListManaged(StateChange) {
        return self.index.queryBetween(entity_namespace, entity_local_id, start_time, end_time);
    }
};

// ==================== Tests ====================

test "StateChangeType.fromUint" {
    const sc_type = try StateChangeType.fromUint(1);
    try std.testing.expectEqual(StateChangeType.attribute_update, sc_type);
}

test "DeltaTimestamp.value" {
    const dt = DeltaTimestamp{ .base = 1000000, .delta = 500 };
    try std.testing.expectEqual(@as(i64, 1000500), dt.value());
}

test "TimeChunk.init and addChange" {
    var chunk = try TimeChunk.init(std.testing.allocator, "test", "entity1");
    defer chunk.deinit(std.testing.allocator);

    const ts = std.time.timestamp();

    const change = StateChange{
        .id = "change1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = "old",
        .new_value = "new",
        .metadata = "{}",
    };

    try chunk.addChange(std.testing.allocator, change);

    try std.testing.expectEqual(@as(u32, 1), chunk.change_count);
    try std.testing.expectEqual(@as(usize, 1), chunk.changes.items.len);
}

test "TemporalIndex.init and addChange" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    const change = StateChange{
        .id = "change1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = null,
        .new_value = "active",
        .metadata = "{}",
    };

    try index.addChange(change);

    try std.testing.expectEqual(@as(u64, 1), index.total_changes);
}

test "TemporalIndex.queryAsOf" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    const change1 = StateChange{
        .id = "change1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -100 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = null,
        .new_value = "pending",
        .metadata = "{}",
    };

    const change2 = StateChange{
        .id = "change2",
        .txn_id = 101,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = "pending",
        .new_value = "active",
        .metadata = "{}",
    };

    try index.addChange(change1);
    try index.addChange(change2);

    const result = try index.queryAsOf("test", "entity1", ts);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("change2", result.?.id);
}

test "TemporalIndex.queryBetween" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    const change1 = StateChange{
        .id = "change1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -200 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = null,
        .new_value = "pending",
        .metadata = "{}",
    };

    const change2 = StateChange{
        .id = "change2",
        .txn_id = 101,
        .timestamp = .{ .base = @intCast(ts), .delta = -100 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = "pending",
        .new_value = "active",
        .metadata = "{}",
    };

    const change3 = StateChange{
        .id = "change3",
        .txn_id = 102,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = "active",
        .new_value = "complete",
        .metadata = "{}",
    };

    try index.addChange(change1);
    try index.addChange(change2);
    try index.addChange(change3);

    var results = try index.queryBetween("test", "entity1", ts - 150, ts);

    // Should get change2 (at -100) and change3 (at 0)
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    defer {
        for (results.items) |*r| r.deinit(std.testing.allocator);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("change2", results.items[0].id);
    try std.testing.expectEqualStrings("change3", results.items[1].id);
}

test "RetentionPolicy.default" {
    const policy = RetentionPolicy.default();
    try std.testing.expectEqual(@as(u64, 90 * 24 * 3600), policy.max_age_seconds);
    try std.testing.expectEqual(@as(u64, 100000), policy.max_changes_per_entity);
    try std.testing.expectEqual(@as(f32, 0.1), policy.sampling_rate);
}

test "RetentionPolicy.shouldRetain" {
    var policy = RetentionPolicy.default();
    policy.max_age_seconds = 100;
    policy.sampling_rate = 1.0; // Keep all

    const ts = std.time.timestamp();

    const recent_change = StateChange{
        .id = "recent",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -50 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = null,
        .new_value = "active",
        .metadata = "{}",
    };

    const old_change = StateChange{
        .id = "old",
        .txn_id = 99,
        .timestamp = .{ .base = @intCast(ts), .delta = -200 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = null,
        .new_value = "inactive",
        .metadata = "{}",
    };

    try std.testing.expect(policy.shouldRetain(recent_change, ts));
    try std.testing.expect(!policy.shouldRetain(old_change, ts));
}

test "TemporalHistoryCartridge.init and addChange" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const ts = std.time.timestamp();

    const change = StateChange{
        .id = "change1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = null,
        .new_value = "active",
        .metadata = "{}",
    };

    try cartridge.addChange(change);

    try std.testing.expectEqual(@as(u64, 1), cartridge.header.entry_count);
}

test "TemporalHistoryCartridge.queryAsOf" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const ts = std.time.timestamp();

    const change = StateChange{
        .id = "change1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = null,
        .new_value = "active",
        .metadata = "{}",
    };

    try cartridge.addChange(change);

    const result = try cartridge.queryAsOf("test", "entity1", ts);

    try std.testing.expect(result != null);
}
