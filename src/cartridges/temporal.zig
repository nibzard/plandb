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
//! - Immutable snapshots with full entity state versioning
//! - Delta compression between consecutive snapshots
//! - Branching history support for merge scenarios

const std = @import("std");
const format = @import("format.zig");
const ArrayListManaged = std.ArrayListUnmanaged;

// ==================== Entity Snapshot System ====================

/// Complete immutable snapshot of an entity at a point in time
pub const EntitySnapshot = struct {
    /// Unique snapshot identifier (UUID)
    id: []const u8,
    /// Entity namespace this snapshot captures
    entity_namespace: []const u8,
    /// Entity local ID this snapshot captures
    entity_local_id: []const u8,
    /// Transaction ID that created this snapshot
    txn_id: u64,
    /// Timestamp when snapshot was created
    timestamp: DeltaTimestamp,
    /// Snapshot version (monotonically increasing per entity)
    version: u64,
    /// Parent snapshot ID for version chain (null for initial snapshot)
    parent_snapshot_id: ?[]const u8,
    /// Branch identifier (for merge scenarios, null for main branch)
    branch_id: ?[]const u8,
    /// Complete entity state as JSON
    state_data: []const u8,
    /// Delta compression info (null if this is a full snapshot)
    delta_info: ?DeltaInfo,
    /// Additional metadata (JSON)
    metadata: []const u8,

    /// Delta compression information for incremental snapshots
    pub const DeltaInfo = struct {
        /// Base snapshot ID this delta is computed from
        base_snapshot_id: []const u8,
        /// Number of fields that changed
        changed_field_count: u32,
        /// Compressed delta data (binary format)
        delta_data: []const u8,
        /// Compression algorithm used
        compression: CompressionType,

        pub const CompressionType = enum(u8) {
            none = 0,
            /// Field-level delta encoding
            field_delta = 1,
            /// Binary delta (bsdiff-like)
            binary_delta = 2,
            /// LZ4 compressed delta
            lz4_delta = 3,
        };
    };

    /// Calculate serialized size
    pub fn serializedSize(self: EntitySnapshot) usize {
        var size: usize = 0;
        size += 2 + self.id.len; // id
        size += 2 + self.entity_namespace.len; // entity_namespace
        size += 2 + self.entity_local_id.len; // entity_local_id
        size += 8; // txn_id
        size += DeltaTimestamp.size(); // timestamp
        size += 8; // version
        if (self.parent_snapshot_id) |p| size += 2 + p.len else size += 1;
        if (self.branch_id) |b| size += 2 + b.len else size += 1;
        size += 4 + self.state_data.len; // state_data
        if (self.delta_info) |di| {
            size += 1; // has delta
            size += 2 + di.base_snapshot_id.len;
            size += 4; // changed_field_count
            size += 4 + di.delta_data.len;
            size += 1; // compression type
        } else {
            size += 1; // no delta flag
        }
        size += 4 + self.metadata.len; // metadata
        return size;
    }

    /// Free snapshot resources
    pub fn deinit(self: EntitySnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.entity_namespace);
        allocator.free(self.entity_local_id);
        if (self.parent_snapshot_id) |p| allocator.free(p);
        if (self.branch_id) |b| allocator.free(b);
        allocator.free(self.state_data);
        if (self.delta_info) |di| {
            allocator.free(di.base_snapshot_id);
            allocator.free(di.delta_data);
        }
        allocator.free(self.metadata);
    }
};

/// Snapshot index for fast lookups by txn_id and timestamp
pub const SnapshotIndex = struct {
    allocator: std.mem.Allocator,
    /// Map from entity key to snapshot chain
    entity_snapshots: std.StringHashMap(ArrayListManaged(EntitySnapshot)),
    /// Map from txn_id to snapshot IDs for fast lookup
    txn_index: std.AutoHashMap(u64, ArrayListManaged([]const u8)),
    /// Map from timestamp to snapshot IDs
    time_index: std.AutoHashMap(i64, ArrayListManaged([]const u8)),
    /// Track current version number per entity
    entity_versions: std.StringHashMap(u64),
    /// Total snapshots stored
    total_snapshots: u64,

    /// Create new snapshot index
    pub fn init(allocator: std.mem.Allocator) SnapshotIndex {
        return SnapshotIndex{
            .allocator = allocator,
            .entity_snapshots = std.StringHashMap(ArrayListManaged(EntitySnapshot)).init(allocator),
            .txn_index = std.AutoHashMap(u64, ArrayListManaged([]const u8)).init(allocator),
            .time_index = std.AutoHashMap(i64, ArrayListManaged([]const u8)).init(allocator),
            .entity_versions = std.StringHashMap(u64).init(allocator),
            .total_snapshots = 0,
        };
    }

    pub fn deinit(self: *SnapshotIndex) void {
        // Free all snapshots and their keys
        var it = self.entity_snapshots.iterator();
        while (it.next()) |entry| {
            // Free the entity key (we own it)
            self.allocator.free(entry.key_ptr.*);
            // Free all snapshots in the list
            for (entry.value_ptr.items) |*snapshot| snapshot.deinit(self.allocator);
            entry.value_ptr.deinit(self.allocator);
        }
        self.entity_snapshots.deinit();

        // Free txn index
        var txn_it = self.txn_index.iterator();
        while (txn_it.next()) |entry| {
            for (entry.value_ptr.items) |id| self.allocator.free(id);
            entry.value_ptr.deinit(self.allocator);
        }
        self.txn_index.deinit();

        // Free time index
        var time_it = self.time_index.iterator();
        while (time_it.next()) |entry| {
            for (entry.value_ptr.items) |id| self.allocator.free(id);
            entry.value_ptr.deinit(self.allocator);
        }
        self.time_index.deinit();

        // Free version tracker keys
        var ver_it = self.entity_versions.iterator();
        while (ver_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entity_versions.deinit();
    }

    /// Add snapshot to index
    pub fn addSnapshot(self: *SnapshotIndex, snapshot: EntitySnapshot) !void {
        // Build entity key and keep it allocated (we'll transfer ownership)
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{
            snapshot.entity_namespace,
            snapshot.entity_local_id,
        });

        // Check if key exists
        const gop = try self.entity_snapshots.getOrPut(entity_key);
        if (!gop.found_existing) {
            // Transfer ownership of entity_key to the map
            gop.key_ptr.* = entity_key;
            gop.value_ptr.* = .{};
        } else {
            // Key already exists, free our temporary copy
            self.allocator.free(entity_key);
        }

        // Create owned copy of snapshot
        const owned_snapshot = EntitySnapshot{
            .id = try self.allocator.dupe(u8, snapshot.id),
            .entity_namespace = try self.allocator.dupe(u8, snapshot.entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, snapshot.entity_local_id),
            .txn_id = snapshot.txn_id,
            .timestamp = snapshot.timestamp,
            .version = snapshot.version,
            .parent_snapshot_id = if (snapshot.parent_snapshot_id) |p| try self.allocator.dupe(u8, p) else null,
            .branch_id = if (snapshot.branch_id) |b| try self.allocator.dupe(u8, b) else null,
            .state_data = try self.allocator.dupe(u8, snapshot.state_data),
            .delta_info = if (snapshot.delta_info) |di| blk: {
                const delta_copy = EntitySnapshot.DeltaInfo{
                    .base_snapshot_id = try self.allocator.dupe(u8, di.base_snapshot_id),
                    .changed_field_count = di.changed_field_count,
                    .delta_data = try self.allocator.dupe(u8, di.delta_data),
                    .compression = di.compression,
                };
                break :blk delta_copy;
            } else null,
            .metadata = try self.allocator.dupe(u8, snapshot.metadata),
        };

        try gop.value_ptr.append(self.allocator, owned_snapshot);
        self.total_snapshots += 1;

        // Update entity version using entity key
        const entity_ver_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{
            snapshot.entity_namespace,
            snapshot.entity_local_id,
        });
        // Check if key already exists
        const ver_gop = try self.entity_versions.getOrPut(entity_ver_key);
        if (!ver_gop.found_existing) {
            ver_gop.key_ptr.* = entity_ver_key;
        } else {
            self.allocator.free(entity_ver_key);
        }
        ver_gop.value_ptr.* = snapshot.version;

        // Add to txn index
        const txn_entry = try self.txn_index.getOrPut(snapshot.txn_id);
        if (!txn_entry.found_existing) {
            txn_entry.value_ptr.* = .{};
        }
        const id_copy = try self.allocator.dupe(u8, snapshot.id);
        try txn_entry.value_ptr.append(self.allocator, id_copy);

        // Add to time index
        const ts = snapshot.timestamp.value();
        const time_entry = try self.time_index.getOrPut(ts);
        if (!time_entry.found_existing) {
            time_entry.value_ptr.* = .{};
        }
        const id_copy2 = try self.allocator.dupe(u8, snapshot.id);
        try time_entry.value_ptr.append(self.allocator, id_copy2);
    }

    /// Find snapshot by transaction ID
    pub fn findByTxnId(self: *const SnapshotIndex, txn_id: u64) !?[]const EntitySnapshot {
        const ids = self.txn_index.get(txn_id) orelse return null;
        var snapshots = ArrayListManaged(EntitySnapshot){};

        for (ids.items) |id| {
            // Search across all entities for this snapshot
            var it = self.entity_snapshots.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.items) |snapshot| {
                    if (std.mem.eql(u8, snapshot.id, id)) {
                        try snapshots.append(self.allocator, snapshot);
                        break;
                    }
                }
            }
        }

        return if (snapshots.items.len > 0) snapshots.toOwnedSlice(self.allocator) else null;
    }

    /// Find snapshot by timestamp (closest match at or before timestamp)
    pub fn findByTimestamp(self: *const SnapshotIndex, entity_namespace: []const u8, entity_local_id: []const u8, timestamp: i64) !?EntitySnapshot {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{
            entity_namespace,
            entity_local_id,
        });
        defer self.allocator.free(entity_key);

        const snapshots = self.entity_snapshots.get(entity_key) orelse return null;

        var result: ?EntitySnapshot = null;
        var best_ts: i64 = std.math.minInt(i64);

        for (snapshots.items) |snapshot| {
            const snap_ts = snapshot.timestamp.value();
            if (snap_ts <= timestamp and snap_ts > best_ts) {
                best_ts = snap_ts;
                result = snapshot;
            }
        }

        return result;
    }

    /// Get snapshot chain (all versions of an entity)
    pub fn getSnapshotChain(self: *const SnapshotIndex, entity_namespace: []const u8, entity_local_id: []const u8) ![]const EntitySnapshot {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{
            entity_namespace,
            entity_local_id,
        });
        defer self.allocator.free(entity_key);

        const snapshots = self.entity_snapshots.get(entity_key) orelse {
            return &[_]EntitySnapshot{};
        };

        // Return snapshots as-is (they're already stored)
        return snapshots.items;
    }
};

/// Snapshot manager for creating and maintaining snapshots
pub const SnapshotManager = struct {
    allocator: std.mem.Allocator,
    /// Snapshot index for lookups
    index: SnapshotIndex,
    /// Snapshot creation policy
    policy: SnapshotPolicy,

    /// Policy for when to create snapshots
    pub const SnapshotPolicy = struct {
        /// Create snapshot on every N transactions
        snapshot_interval: u64,
        /// Create snapshot for specific change types
        snapshot_on_change: []const StateChangeType,
        /// Max snapshots per entity before forced delta compression
        max_full_snapshots: u64,
        /// Use delta compression for snapshots
        enable_delta_compression: bool,

        pub fn default() SnapshotPolicy {
            return SnapshotPolicy{
                .snapshot_interval = 100, // Every 100 transactions
                .snapshot_on_change = &[_]StateChangeType{
                    .entity_created,
                    .entity_migration,
                    .batch_operation,
                },
                .max_full_snapshots = 10,
                .enable_delta_compression = true,
            };
        }
    };

    /// Create new snapshot manager
    pub fn init(allocator: std.mem.Allocator) SnapshotManager {
        return SnapshotManager{
            .allocator = allocator,
            .index = SnapshotIndex.init(allocator),
            .policy = SnapshotPolicy.default(),
        };
    }

    pub fn deinit(self: *SnapshotManager) void {
        self.index.deinit();
    }

    /// Create snapshot from entity state
    pub fn createSnapshot(
        self: *SnapshotManager,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        state_data: []const u8,
        txn_id: u64,
        change_type: StateChangeType,
    ) ![]const u8 {
        _ = change_type; // Used for policy decisions in future
        const ts = std.time.timestamp();

        // Build entity key to track version
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{
            entity_namespace,
            entity_local_id,
        });
        defer self.allocator.free(entity_key);

        // Get next version number for this entity
        const current_version = self.index.entity_versions.get(entity_key) orelse 0;
        const version = current_version + 1;

        // Get parent snapshot if exists
        const parent_id = if (version > 1) blk: {
            const chain = try self.index.getSnapshotChain(entity_namespace, entity_local_id);
            break :blk if (chain.len > 0) chain[chain.len - 1].id else null;
        } else null;

        // Determine if we should use delta compression
        const delta_info = if (self.policy.enable_delta_compression and parent_id != null)
            try self.computeDelta(entity_namespace, entity_local_id, state_data)
        else
            null;

        // Generate unique snapshot ID
        // Use a counter to ensure uniqueness even within the same second
        const snapshot_id = try std.fmt.allocPrint(self.allocator, "snap_{d}_{d}_{d}", .{
            txn_id,
            ts,
            version,
        });

        // Generate metadata about this snapshot
        const metadata = try self.generateSnapshotMetadata(
            entity_namespace,
            entity_local_id,
            version,
            delta_info != null,
        );
        errdefer self.allocator.free(metadata);

        const snapshot = EntitySnapshot{
            .id = snapshot_id,
            .entity_namespace = entity_namespace,
            .entity_local_id = entity_local_id,
            .txn_id = txn_id,
            .timestamp = .{ .base = @intCast(ts), .delta = 0 },
            .version = version,
            .parent_snapshot_id = parent_id,
            .branch_id = null, // TODO: Support branching
            .state_data = state_data,
            .delta_info = delta_info,
            .metadata = metadata,
        };

        try self.index.addSnapshot(snapshot);

        return snapshot_id;
    }

    /// Generate metadata JSON for a snapshot
    fn generateSnapshotMetadata(
        self: *SnapshotManager,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        version: u64,
        has_delta: bool,
    ) ![]const u8 {
        // Build a simple JSON metadata object
        var json_buffer = ArrayListManaged(u8){};
        try json_buffer.ensureTotalCapacity(self.allocator, 256);
        errdefer json_buffer.deinit(self.allocator);

        // Format numbers directly to avoid extra allocations
        var version_buf: [32]u8 = undefined;
        const version_str = try std.fmt.bufPrint(&version_buf, "{d}", .{version});

        var timestamp_buf: [32]u8 = undefined;
        const timestamp_str = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{std.time.nanoTimestamp()});

        try json_buffer.append(self.allocator, '{');
        try json_buffer.appendSlice(self.allocator, "\"entity_namespace\":");
        try json_buffer.append(self.allocator, '"');
        try json_buffer.appendSlice(self.allocator, entity_namespace);
        try json_buffer.append(self.allocator, '"');
        try json_buffer.appendSlice(self.allocator, ",\"entity_id\":");
        try json_buffer.append(self.allocator, '"');
        try json_buffer.appendSlice(self.allocator, entity_local_id);
        try json_buffer.append(self.allocator, '"');
        try json_buffer.appendSlice(self.allocator, ",\"version\":");
        try json_buffer.appendSlice(self.allocator, version_str);
        try json_buffer.appendSlice(self.allocator, ",\"has_delta\":");
        try json_buffer.appendSlice(self.allocator, if (has_delta) "true" else "false");
        try json_buffer.appendSlice(self.allocator, ",\"created_at\":");
        try json_buffer.appendSlice(self.allocator, timestamp_str);
        try json_buffer.append(self.allocator, '}');

        return json_buffer.toOwnedSlice(self.allocator);
    }

    /// Compute delta between current state and previous snapshot
    fn computeDelta(
        self: *SnapshotManager,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        new_state: []const u8,
    ) !?EntitySnapshot.DeltaInfo {
        // Get previous snapshot
        const prev_snapshot = try self.index.findByTimestamp(
            entity_namespace,
            entity_local_id,
            std.math.maxInt(i64),
        ) orelse return null;

        // Parse both JSON states
        const prev_parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            prev_snapshot.state_data,
            .{ .allocate = .alloc_if_needed },
        ) catch |err| {
            std.log.warn("Failed to parse previous snapshot state: {}", .{err});
            return null;
        };
        defer prev_parsed.deinit();

        const new_parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            new_state,
            .{ .allocate = .alloc_if_needed },
        ) catch |err| {
            std.log.warn("Failed to parse new state: {}", .{err});
            return null;
        };
        defer new_parsed.deinit();

        // Compute field-level delta
        var delta_result = try computeFieldDelta(
            self.allocator,
            prev_parsed.value,
            new_parsed.value,
        );

        // If no fields changed, return null (no delta needed)
        if (delta_result.changed_fields.items.len == 0) {
            delta_result.deinit(self.allocator);
            return null;
        }

        // Serialize delta data
        var delta_data_buffer = ArrayListManaged(u8){};
        try delta_data_buffer.ensureTotalCapacity(self.allocator, 256);
        defer delta_data_buffer.deinit(self.allocator);

        // Build delta data as JSON array of changed fields
        delta_data_buffer.appendAssumeCapacity('[');
        for (delta_result.changed_fields.items, 0..) |field, i| {
            if (i > 0) try delta_data_buffer.append(self.allocator, ',');
            try delta_data_buffer.append(self.allocator, '"');
            try delta_data_buffer.appendSlice(self.allocator, field);
            try delta_data_buffer.append(self.allocator, '"');
        }
        try delta_data_buffer.append(self.allocator, ']');

        const delta_data = try self.allocator.dupe(u8, delta_data_buffer.items);
        const base_snapshot_id = try self.allocator.dupe(u8, prev_snapshot.id);

        // Clean up
        delta_result.deinit(self.allocator);

        return EntitySnapshot.DeltaInfo{
            .base_snapshot_id = base_snapshot_id,
            .changed_field_count = @intCast(delta_result.changed_fields.items.len),
            .delta_data = delta_data,
            .compression = .field_delta,
        };
    }

    /// Restore entity state from snapshot
    pub fn restoreFromSnapshot(
        self: *const SnapshotManager,
        snapshot_id: []const u8,
    ) !?[]const u8 {
        // Find snapshot by ID
        var it = self.index.entity_snapshots.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |snapshot| {
                if (std.mem.eql(u8, snapshot.id, snapshot_id)) {
                    // Current design: snapshots store full state_data
                    // Future optimization: could store only deltas and reconstruct here
                    // The delta_info is currently metadata for compression info
                    _ = snapshot.delta_info; // Metadata for optimization purposes
                    return snapshot.state_data;
                }
            }
        }

        return null;
    }
};

// ==================== Delta Computation Helpers ====================

/// Result of field delta computation
pub const FieldDeltaResult = struct {
    changed_fields: std.ArrayList([]const u8),
    prev_value: std.json.Value,
    new_value: std.json.Value,

    pub fn deinit(self: *FieldDeltaResult, allocator: std.mem.Allocator) void {
        for (self.changed_fields.items) |field| {
            allocator.free(field);
        }
        self.changed_fields.deinit(allocator);
    }
};

/// Compare two JSON values for equality
pub fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |ab| b == .bool and ab == b.bool,
        .integer => |ai| b == .integer and ai == b.integer,
        .float => |af| b == .float and af == b.float,
        .string => |as| b == .string and std.mem.eql(u8, as, b.string),
        .number_string => |as| b == .number_string and std.mem.eql(u8, as, b.number_string),
        .array => |aa| {
            if (b != .array) return false;
            const ba = b.array;
            if (aa.items.len != ba.items.len) return false;
            for (aa.items, ba.items) |ai, bi| {
                if (!jsonValuesEqual(ai, bi)) return false;
            }
            return true;
        },
        .object => |ao| {
            if (b != .object) return false;
            const bo = b.object;
            if (ao.count() != bo.count()) return false;
            var it = ao.iterator();
            while (it.next()) |entry| {
                const b_val = bo.get(entry.key_ptr.*) orelse return false;
                if (!jsonValuesEqual(entry.value_ptr.*, b_val)) return false;
            }
            return true;
        },
    };
}

/// Compute field-level delta between two JSON objects
pub fn computeFieldDelta(
    allocator: std.mem.Allocator,
    prev: std.json.Value,
    new: std.json.Value,
) !FieldDeltaResult {
    var result = FieldDeltaResult{
        .changed_fields = std.ArrayListUnmanaged([]const u8){},
        .prev_value = prev,
        .new_value = new,
    };

    if (prev != .object) return result;
    if (new != .object) return result;
    const prev_obj = prev.object;
    const new_obj = new.object;

    // Find added/modified fields
    var new_it = new_obj.iterator();
    while (new_it.next()) |entry| {
        const field_name = entry.key_ptr.*;

        if (prev_obj.get(field_name)) |prev_value| {
            // Field exists in both, check if changed
            if (!jsonValuesEqual(prev_value, entry.value_ptr.*)) {
                try result.changed_fields.append(allocator, try allocator.dupe(u8, field_name));
            }
        } else {
            // Field is new
            try result.changed_fields.append(allocator, try allocator.dupe(u8, field_name));
        }
    }

    // Note: We don't track deleted fields since the full new state
    // is stored in the snapshot. The delta only indicates which fields
    // changed to enable delta compression optimization.

    return result;
}

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

        // Update timestamp range
        const change_time = change.timestamp.value();
        const current_start = self.start_timestamp.value();
        const current_end = self.end_timestamp.value();

        // Update start if this change is older
        if (change_time < current_start) {
            self.start_timestamp = change.timestamp;
        }
        // Update end if this change is newer
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
    /// Map from "entity:attr:granularity" to list of rollups
    rollups: std.StringHashMap(ArrayListManaged(Rollup)),
    /// Total state changes stored
    total_changes: u64,
    /// Retention policy
    retention_policy: RetentionPolicy,
    /// Supported rollup granularities (seconds): 1m, 5m, 1h, 1d
    rollup_granularities: []const u64,

    /// Create new temporal index
    pub fn init(allocator: std.mem.Allocator) TemporalIndex {
        const granularities = [_]u64{ 60, 300, 3600, 86400 }; // 1m, 5m, 1h, 1d
        return TemporalIndex{
            .allocator = allocator,
            .entity_chunks = std.StringHashMap(ArrayListManaged(*TimeChunk)).init(allocator),
            .time_index = std.AutoHashMap(u64, ArrayListManaged([]const u8)).init(allocator),
            .rollups = std.StringHashMap(ArrayListManaged(Rollup)).init(allocator),
            .total_changes = 0,
            .retention_policy = RetentionPolicy.default(),
            .rollup_granularities = &granularities,
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

        // Free rollups
        var rollup_it = self.rollups.iterator();
        while (rollup_it.next()) |entry| {
            for (entry.value_ptr.items) |*r| r.deinit(self.allocator);
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.rollups.deinit();
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

        // Find relevant chunk and changes using two-pass approach
        var latest_change: ?*const StateChange = null;
        var latest_ts: i64 = std.math.minInt(i64);

        for (chunks.items) |chunk| {
            const chunk_start = chunk.start_timestamp.value();
            const chunk_end = chunk.end_timestamp.value();

            // Skip if timestamp is outside chunk range
            if (timestamp < chunk_start or timestamp > chunk_end) continue;

            // Find last change before or at timestamp
            for (chunk.changes.items) |*change| {
                const change_time = change.timestamp.value();
                if (change_time <= timestamp and change_time > latest_ts) {
                    latest_ts = change_time;
                    latest_change = change;
                }
            }
        }

        // Create copy if found
        if (latest_change) |ch| {
            return StateChange{
                .id = try self.allocator.dupe(u8, ch.id),
                .txn_id = ch.txn_id,
                .timestamp = ch.timestamp,
                .entity_namespace = try self.allocator.dupe(u8, ch.entity_namespace),
                .entity_local_id = try self.allocator.dupe(u8, ch.entity_local_id),
                .change_type = ch.change_type,
                .key = try self.allocator.dupe(u8, ch.key),
                .old_value = if (ch.old_value) |v| try self.allocator.dupe(u8, v) else null,
                .new_value = if (ch.new_value) |v| try self.allocator.dupe(u8, v) else null,
                .metadata = try self.allocator.dupe(u8, ch.metadata),
            };
        }

        return null;
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

    /// Result type for change frequency analysis
    pub const ChangeFrequency = struct {
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        change_count: u64,
        first_change_ts: i64,
        last_change_ts: i64,
    };

    /// Anomaly detection result
    pub const AnomalyResult = struct {
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        /// Number of anomalies detected
        anomaly_count: u64,
        /// Baseline mean value for metric
        baseline_mean: f64,
        /// Baseline standard deviation
        baseline_stddev: f64,
        /// Threshold used (Z-score or IQR multiplier)
        threshold: f64,
        /// List of anomaly timestamps
        anomaly_timestamps: ArrayListManaged(i64),
        /// List of anomaly values (optional, for numeric attributes)
        anomaly_values: ArrayListManaged(f64),

        pub fn deinit(self: *AnomalyResult, allocator: std.mem.Allocator) void {
            allocator.free(self.entity_namespace);
            allocator.free(self.entity_local_id);
            self.anomaly_timestamps.deinit(allocator);
            self.anomaly_values.deinit(allocator);
        }
    };

    /// Temporal histogram bucket
    pub const HistogramBucket = struct {
        /// Time bucket identifier (e.g., hour of day: 0-23)
        bucket_id: u64,
        /// Count of events in this bucket
        count: u64,
        /// Start of this time period
        period_start: i64,
        /// End of this time period
        period_end: i64,
    };

    /// Temporal histogram result
    pub const TemporalHistogram = struct {
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        /// Total events histogramed
        total_events: u64,
        /// Histogram buckets
        buckets: ArrayListManaged(HistogramBucket),
        /// Time granularity (seconds per bucket)
        granularity_seconds: u64,

        pub fn deinit(self: *TemporalHistogram, allocator: std.mem.Allocator) void {
            allocator.free(self.entity_namespace);
            allocator.free(self.entity_local_id);
            self.buckets.deinit(allocator);
        }
    };

    /// Activity heatmap cell
    pub const HeatmapCell = struct {
        /// Row index (e.g., hour of day)
        row: u64,
        /// Column index (e.g., day of week)
        col: u64,
        /// Activity count for this cell
        count: u64,
        /// Normalized intensity (0.0 - 1.0)
        intensity: f64,
    };

    /// Activity heatmap result
    pub const ActivityHeatmap = struct {
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        /// Number of rows in heatmap
        rows: u64,
        /// Number of columns in heatmap
        cols: u64,
        /// Heatmap cells (row-major order)
        cells: ArrayListManaged(HeatmapCell),
        /// Row labels (optional, e.g., ["00:00", "01:00", ...])
        row_labels: ArrayListManaged([]const u8),
        /// Column labels (optional, e.g., ["Mon", "Tue", ...])
        col_labels: ArrayListManaged([]const u8),
        /// Maximum count (for normalization)
        max_count: u64,

        pub fn deinit(self: *ActivityHeatmap, allocator: std.mem.Allocator) void {
            allocator.free(self.entity_namespace);
            allocator.free(self.entity_local_id);
            self.cells.deinit(allocator);
            for (self.row_labels.items) |l| allocator.free(l);
            self.row_labels.deinit(allocator);
            for (self.col_labels.items) |l| allocator.free(l);
            self.col_labels.deinit(allocator);
        }
    };

    /// Downsampled data point
    pub const DownsampledPoint = struct {
        /// Time period start
        period_start: i64,
        /// Time period end
        period_end: i64,
        /// Number of original points in this period
        point_count: u64,
        /// Aggregated value (e.g., mean, sum, min, max)
        aggregated_value: f64,
        /// Minimum value in period
        min_value: f64,
        /// Maximum value in period
        max_value: f64,
        /// P95 percentile value (0.0 if not computed)
        p95_value: f64,
        /// P99 percentile value (0.0 if not computed)
        p99_value: f64,
    };

    /// Stored rollup for a specific time window and aggregation
    pub const Rollup = struct {
        /// Entity namespace
        entity_namespace: []const u8,
        /// Entity local ID
        entity_local_id: []const u8,
        /// Attribute key
        attribute_key: []const u8,
        /// Time window granularity (seconds)
        window_granularity: u64,
        /// Start timestamp of this rollup
        window_start: i64,
        /// End timestamp of this rollup
        window_end: i64,
        /// Aggregation method used
        aggregation_method: DownsampledSeries.AggregationMethod,
        /// Minimum value
        min_value: f64,
        /// Maximum value
        max_value: f64,
        /// Sum value
        sum_value: f64,
        /// Count of points
        count: u64,
        /// P95 percentile (0.0 if not computed)
        p95_value: f64,
        /// P99 percentile (0.0 if not computed)
        p99_value: f64,
        /// Timestamp when this rollup was created
        created_at: i64,
        /// Whether this rollup needs invalidation due to late data
        needs_invalidation: bool,

        /// Cleanup owned resources.
        /// NOTE: String slices (entity_namespace, entity_local_id, attribute_key)
        /// are borrowed from the TemporalIndex storage and should NOT be freed here.
        pub fn deinit(self: *Rollup, allocator: std.mem.Allocator) void {
            _ = allocator;
            _ = self;
            // Strings are owned by TemporalIndex, not by Rollup instances
        }
    };

    /// Downsampled time series
    pub const DownsampledSeries = struct {
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        /// Attribute key that was downsampled
        attribute_key: []const u8,
        /// Original granularity (seconds)
        original_granularity: u64,
        /// Downsampled granularity (seconds)
        downsampled_granularity: u64,
        /// Downsampled points
        points: ArrayListManaged(DownsampledPoint),
        /// Aggregation method used
        aggregation_method: AggregationMethod,

        pub const AggregationMethod = enum(u8) {
            mean = 0,
            sum = 1,
            min = 2,
            max = 3,
            count = 4,
            p95 = 5,
            p99 = 6,
        };

        pub fn deinit(self: *DownsampledSeries, allocator: std.mem.Allocator) void {
            allocator.free(self.entity_namespace);
            allocator.free(self.entity_local_id);
            allocator.free(self.attribute_key);
            self.points.deinit(allocator);
        }
    };

    /// Rate calculation data point
    pub const RatePoint = struct {
        /// Timestamp for this rate calculation
        timestamp: i64,
        /// Rate value (change per unit time)
        rate: f64,
        /// Time delta used for calculation (seconds)
        time_delta_seconds: f64,
    };

    /// Rate calculation result for time-series data
    pub const RateSeries = struct {
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        /// Attribute key that was analyzed
        attribute_key: []const u8,
        /// Time granularity for rate calculation (seconds)
        granularity_seconds: u64,
        /// Rate data points
        points: ArrayListManaged(RatePoint),
        /// Average rate across all points
        average_rate: f64,
        /// Maximum rate observed
        max_rate: f64,
        /// Minimum rate observed
        min_rate: f64,

        pub fn deinit(self: *RateSeries, allocator: std.mem.Allocator) void {
            allocator.free(self.entity_namespace);
            allocator.free(self.entity_local_id);
            allocator.free(self.attribute_key);
            self.points.deinit(allocator);
        }
    };

    /// Threshold violation alert
    pub const ThresholdViolation = struct {
        /// Timestamp when violation occurred
        timestamp: i64,
        /// Value that violated threshold
        value: f64,
        /// Threshold that was crossed
        threshold: f64,
        /// Type of violation (above/below)
        violation_type: ViolationType,
        /// Severity based on how much threshold was exceeded
        severity: f64,

        pub const ViolationType = enum(u8) {
            above = 0,
            below = 1,
        };
    };

    /// Alert query result
    pub const AlertResult = struct {
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        /// Attribute key monitored
        attribute_key: []const u8,
        /// Upper threshold (null if not set)
        upper_threshold: ?f64,
        /// Lower threshold (null if not set)
        lower_threshold: ?f64,
        /// Number of violations detected
        violation_count: u64,
        /// List of threshold violations
        violations: ArrayListManaged(ThresholdViolation),
        /// Time range analyzed
        start_time: i64,
        end_time: i64,

        pub fn deinit(self: *AlertResult, allocator: std.mem.Allocator) void {
            allocator.free(self.entity_namespace);
            allocator.free(self.entity_local_id);
            allocator.free(self.attribute_key);
            self.violations.deinit(allocator);
        }
    };

    /// Detect anomalies using Z-score method
    pub fn detectAnomaliesZScore(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        threshold: f64,
    ) !?AnomalyResult {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // Collect numeric values over time
        var values = ArrayListManaged(struct { i64, f64 }){};
        defer values.deinit(self.allocator);

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    if (std.mem.eql(u8, change.key, attribute_key)) {
                        if (change.new_value) |v| {
                            const parsed = std.fmt.parseFloat(f64, v) catch continue;
                            try values.append(self.allocator, .{ change_time, parsed });
                        }
                    }
                }
            }
        }

        if (values.items.len < 3) return null; // Need minimum data points

        // Calculate mean and standard deviation
        var sum: f64 = 0;
        for (values.items) |v| sum += v[1];
        const mean = sum / @as(f64, @floatFromInt(values.items.len));

        var variance: f64 = 0;
        for (values.items) |v| {
            const diff = v[1] - mean;
            variance += diff * diff;
        }
        variance /= @as(f64, @floatFromInt(values.items.len));
        const stddev = std.math.sqrt(variance);

        if (stddev == 0) return null; // No variation

        // Detect anomalies
        var anomaly_timestamps = ArrayListManaged(i64){};
        var anomaly_values = ArrayListManaged(f64){};
        errdefer {
            anomaly_timestamps.deinit(self.allocator);
            anomaly_values.deinit(self.allocator);
        }

        for (values.items) |v| {
            const z_score = @abs(v[1] - mean) / stddev;
            if (z_score > threshold) {
                try anomaly_timestamps.append(self.allocator, v[0]);
                try anomaly_values.append(self.allocator, v[1]);
            }
        }

        return AnomalyResult{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .anomaly_count = @intCast(anomaly_timestamps.items.len),
            .baseline_mean = mean,
            .baseline_stddev = stddev,
            .threshold = threshold,
            .anomaly_timestamps = anomaly_timestamps,
            .anomaly_values = anomaly_values,
        };
    }

    /// Detect anomalies using IQR (Interquartile Range) method
    pub fn detectAnomaliesIQR(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        multiplier: f64,
    ) !?AnomalyResult {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // Collect numeric values
        var values = ArrayListManaged(f64){};
        defer values.deinit(self.allocator);
        var timestamps = ArrayListManaged(i64){};
        defer timestamps.deinit(self.allocator);

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    if (std.mem.eql(u8, change.key, attribute_key)) {
                        if (change.new_value) |v| {
                            const parsed = std.fmt.parseFloat(f64, v) catch continue;
                            try values.append(self.allocator, parsed);
                            try timestamps.append(self.allocator, change_time);
                        }
                    }
                }
            }
        }

        if (values.items.len < 4) return null;

        // Sort values to find quartiles
        std.mem.sort(f64, values.items, {}, comptime std.sort.asc(f64));

        // Calculate Q1, Q3, and IQR
        const q1_idx = values.items.len / 4;
        const q3_idx = (3 * values.items.len) / 4;
        const q1 = values.items[q1_idx];
        const q3 = values.items[q3_idx];
        const iqr = q3 - q1;

        if (iqr == 0) return null;

        const lower_bound = q1 - (multiplier * iqr);
        const upper_bound = q3 + (multiplier * iqr);

        // Detect anomalies
        var anomaly_timestamps = ArrayListManaged(i64){};
        var anomaly_values = ArrayListManaged(f64){};
        errdefer {
            anomaly_timestamps.deinit(self.allocator);
            anomaly_values.deinit(self.allocator);
        }

        for (values.items, 0..) |v, i| {
            if (v < lower_bound or v > upper_bound) {
                try anomaly_timestamps.append(self.allocator, timestamps.items[i]);
                try anomaly_values.append(self.allocator, v);
            }
        }

        // Calculate mean and stddev for baseline
        var sum: f64 = 0;
        for (values.items) |v| sum += v;
        const mean = sum / @as(f64, @floatFromInt(values.items.len));

        var variance: f64 = 0;
        for (values.items) |v| {
            const diff = v - mean;
            variance += diff * diff;
        }
        variance /= @as(f64, @floatFromInt(values.items.len));
        const stddev = std.math.sqrt(variance);

        return AnomalyResult{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .anomaly_count = @intCast(anomaly_timestamps.items.len),
            .baseline_mean = mean,
            .baseline_stddev = stddev,
            .threshold = multiplier,
            .anomaly_timestamps = anomaly_timestamps,
            .anomaly_values = anomaly_values,
        };
    }

    /// Generate temporal histogram for time-based activity patterns
    pub fn generateTemporalHistogram(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
        granularity_seconds: u64,
    ) !?TemporalHistogram {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // Count events per time bucket
        var buckets = std.AutoHashMap(u64, u64).init(self.allocator);
        defer buckets.deinit();

        var total_events: u64 = 0;
        var min_bucket_id: u64 = std.math.maxInt(u64);
        var max_bucket_id: u64 = 0;

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    const bucket_id = @as(u64, @intCast(@divTrunc(change_time - start_time, @as(i64, @intCast(granularity_seconds)))));

                    const gop = try buckets.getOrPut(bucket_id);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = 0;
                    }
                    gop.value_ptr.* += 1;
                    total_events += 1;

                    if (bucket_id < min_bucket_id) min_bucket_id = bucket_id;
                    if (bucket_id > max_bucket_id) max_bucket_id = bucket_id;
                }
            }
        }

        if (total_events == 0) return null;

        // Convert to sorted buckets
        const bucket_count = max_bucket_id - min_bucket_id + 1;
        var histogram_buckets = ArrayListManaged(HistogramBucket){};
        errdefer histogram_buckets.deinit(self.allocator);

        var i: u64 = 0;
        while (i < bucket_count) : (i += 1) {
            const bucket_id = min_bucket_id + i;
            const count = buckets.get(bucket_id) orelse 0;
            const period_start = start_time + @as(i64, @intCast(bucket_id * granularity_seconds));
            const period_end = period_start + @as(i64, @intCast(granularity_seconds));

            try histogram_buckets.append(self.allocator, .{
                .bucket_id = bucket_id,
                .count = count,
                .period_start = period_start,
                .period_end = period_end,
            });
        }

        return TemporalHistogram{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .total_events = total_events,
            .buckets = histogram_buckets,
            .granularity_seconds = granularity_seconds,
        };
    }

    /// Generate hour-of-day histogram (24 buckets)
    pub fn generateHourOfDayHistogram(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
    ) !?TemporalHistogram {
        return self.generateTemporalHistogram(entity_namespace, entity_local_id, start_time, end_time, 3600);
    }

    /// Generate day-of-week histogram (7 buckets)
    pub fn generateDayOfWeekHistogram(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
    ) !?TemporalHistogram {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // Count events per day of week (0=Sunday, 6=Saturday)
        var day_counts: [7]u64 = [_]u64{0} ** 7;
        var total_events: u64 = 0;

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    // Calculate day of week
                    const epoch_day = @divTrunc(change_time, 86400);
                    const day_of_week = @as(u64, @intCast(@rem(epoch_day + 4, 7))); // +4 to align epoch (Thursday) to Sunday=0

                    day_counts[day_of_week] += 1;
                    total_events += 1;
                }
            }
        }

        if (total_events == 0) return null;

        // Create buckets for each day
        var histogram_buckets = ArrayListManaged(HistogramBucket){};
        errdefer histogram_buckets.deinit(self.allocator);

        // Create buckets for each day
        for (day_counts, 0..) |count, i| {
            try histogram_buckets.append(self.allocator, .{
                .bucket_id = @intCast(i),
                .count = count,
                .period_start = @as(i64, @intCast(i * 86400)),
                .period_end = @as(i64, @intCast((i + 1) * 86400)),
            });
        }

        return TemporalHistogram{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .total_events = total_events,
            .buckets = histogram_buckets,
            .granularity_seconds = 86400,
        };
    }

    /// Generate activity heatmap (hour vs day of week)
    pub fn generateActivityHeatmap(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
    ) !?ActivityHeatmap {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // 24 hours x 7 days = 168 cells
        const ROWS: u64 = 24;
        const COLS: u64 = 7;
        var cells_array: [ROWS][COLS]u64 = undefined;
        for (0..ROWS) |r| {
            for (0..COLS) |c| {
                cells_array[r][c] = 0;
            }
        }

        var max_count: u64 = 0;
        var total_events: u64 = 0;

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    // Extract hour and day of week
                    const seconds_in_day = @as(u64, @intCast(@rem(change_time, 86400)));
                    if (seconds_in_day < 0) continue;
                    const hour = @divTrunc(seconds_in_day, 3600);

                    const epoch_day = @divTrunc(change_time, 86400);
                    const day_of_week = @as(usize, @intCast(@rem(epoch_day + 4, 7)));

                    if (hour < ROWS and day_of_week < COLS) {
                        cells_array[hour][day_of_week] += 1;
                        total_events += 1;
                        if (cells_array[hour][day_of_week] > max_count) {
                            max_count = cells_array[hour][day_of_week];
                        }
                    }
                }
            }
        }

        if (total_events == 0) return null;

        // Convert to heatmap cells
        var cells = ArrayListManaged(HeatmapCell){};
        errdefer cells.deinit(self.allocator);

        var row_labels = ArrayListManaged([]const u8){};
        errdefer {
            for (row_labels.items) |l| self.allocator.free(l);
            row_labels.deinit(self.allocator);
        }

        var col_labels = ArrayListManaged([]const u8){};
        errdefer {
            for (col_labels.items) |l| self.allocator.free(l);
            col_labels.deinit(self.allocator);
        }

        const hour_names = [_][]const u8{
            "00:00", "01:00", "02:00", "03:00", "04:00", "05:00",
            "06:00", "07:00", "08:00", "09:00", "10:00", "11:00",
            "12:00", "13:00", "14:00", "15:00", "16:00", "17:00",
            "18:00", "19:00", "20:00", "21:00", "22:00", "23:00",
        };

        const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

        var row: u64 = 0;
        while (row < ROWS) : (row += 1) {
            try row_labels.append(self.allocator, try self.allocator.dupe(u8, hour_names[row]));

            var col: u64 = 0;
            while (col < COLS) : (col += 1) {
                if (row == 0) {
                    try col_labels.append(self.allocator, try self.allocator.dupe(u8, day_names[col]));
                }

                const count = cells_array[row][col];
                const intensity = if (max_count > 0)
                    @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(max_count))
                else
                    0;

                try cells.append(self.allocator, .{
                    .row = row,
                    .col = col,
                    .count = count,
                    .intensity = intensity,
                });
            }
        }

        return ActivityHeatmap{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .rows = ROWS,
            .cols = COLS,
            .cells = cells,
            .row_labels = row_labels,
            .col_labels = col_labels,
            .max_count = max_count,
        };
    }

    /// Downsample time series data for long-term trend analysis
    pub fn downsampleSeries(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        target_granularity_seconds: u64,
        aggregation_method: DownsampledSeries.AggregationMethod,
    ) !?DownsampledSeries {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // Collect all changes for this attribute
        var time_values = ArrayListManaged(struct { i64, f64 }){};
        defer time_values.deinit(self.allocator);

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    if (std.mem.eql(u8, change.key, attribute_key)) {
                        if (change.new_value) |v| {
                            const parsed = std.fmt.parseFloat(f64, v) catch continue;
                            try time_values.append(self.allocator, .{ change_time, parsed });
                        }
                    }
                }
            }
        }

        if (time_values.items.len == 0) return null;

        // Group by time periods
        var periods = std.AutoHashMap(u64, ArrayListManaged(f64)).init(self.allocator);
        defer {
            var it = periods.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            periods.deinit();
        }

        for (time_values.items) |tv| {
            const period_id = @as(u64, @intCast(@divTrunc(tv[0] - start_time, @as(i64, @intCast(target_granularity_seconds)))));
            const gop = try periods.getOrPut(period_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            try gop.value_ptr.append(self.allocator, tv[1]);
        }

        // Create downsampled points
        var points = ArrayListManaged(DownsampledPoint){};
        errdefer points.deinit(self.allocator);

        // Sort period IDs and create points
        var period_ids = ArrayListManaged(u64){};
        defer period_ids.deinit(self.allocator);

        var period_it = periods.iterator();
        while (period_it.next()) |entry| {
            try period_ids.append(self.allocator, entry.key_ptr.*);
        }

        std.mem.sort(u64, period_ids.items, {}, comptime std.sort.asc(u64));

        for (period_ids.items) |period_id| {
            const values = periods.get(period_id).?;
            const period_start = start_time + @as(i64, @intCast(period_id * target_granularity_seconds));
            const period_end = period_start + @as(i64, @intCast(target_granularity_seconds));

            // Calculate aggregates
            var sum: f64 = 0;
            var min_val: f64 = std.math.floatMax(f64);
            var max_val: f64 = std.math.floatMin(f64);
            var p95_val: f64 = 0.0;
            var p99_val: f64 = 0.0;

            // Use TDigest for percentile calculations
            var tdigest = TDigest.init(self.allocator, 50.0);
            defer tdigest.deinit();

            for (values.items) |v| {
                sum += v;
                if (v < min_val) min_val = v;
                if (v > max_val) max_val = v;
                try tdigest.add(v);
            }

            // Calculate percentiles if needed
            if (aggregation_method == .p95 or aggregation_method == .p99) {
                p95_val = tdigest.quantile(0.95);
                p99_val = tdigest.quantile(0.99);
            }

            const aggregated_value = switch (aggregation_method) {
                .mean => sum / @as(f64, @floatFromInt(values.items.len)),
                .sum => sum,
                .min => min_val,
                .max => max_val,
                .count => @as(f64, @floatFromInt(values.items.len)),
                .p95 => p95_val,
                .p99 => p99_val,
            };

            try points.append(self.allocator, .{
                .period_start = period_start,
                .period_end = period_end,
                .point_count = @intCast(values.items.len),
                .aggregated_value = aggregated_value,
                .min_value = min_val,
                .max_value = max_val,
                .p95_value = p95_val,
                .p99_value = p99_val,
            });
        }

        return DownsampledSeries{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .attribute_key = try self.allocator.dupe(u8, attribute_key),
            .original_granularity = 1, // Placeholder
            .downsampled_granularity = target_granularity_seconds,
            .points = points,
            .aggregation_method = aggregation_method,
        };
    }

    /// Create a rollup for the specified time window and granularity
    pub fn createRollup(
        self: *TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        window_start: i64,
        window_end: i64,
        granularity_seconds: u64,
        aggregation_method: DownsampledSeries.AggregationMethod,
    ) !void {
        // Compute aggregates for the window
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return;

        var sum: f64 = 0;
        var min_val: f64 = std.math.floatMax(f64);
        var max_val: f64 = std.math.floatMin(f64);
        var count: u64 = 0;

        // Use TDigest for percentile calculations
        var tdigest = TDigest.init(self.allocator, 50.0);
        defer tdigest.deinit();

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= window_start and change_time < window_end) {
                    if (std.mem.eql(u8, change.key, attribute_key)) {
                        if (change.new_value) |v| {
                            const parsed = std.fmt.parseFloat(f64, v) catch continue;
                            sum += parsed;
                            if (parsed < min_val) min_val = parsed;
                            if (parsed > max_val) max_val = parsed;
                            count += 1;
                            try tdigest.add(parsed);
                        }
                    }
                }
            }
        }

        if (count == 0) return;

        const p95_val = tdigest.quantile(0.95);
        const p99_val = tdigest.quantile(0.99);

        // Store the rollup
        const rollup_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}:{d}", .{ entity_namespace, entity_local_id, attribute_key, granularity_seconds });
        defer self.allocator.free(rollup_key);

        const entry = try self.rollups.getOrPut(rollup_key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, rollup_key);
            entry.value_ptr.* = .{};
        }

        const rollup = Rollup{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .attribute_key = try self.allocator.dupe(u8, attribute_key),
            .window_granularity = granularity_seconds,
            .window_start = window_start,
            .window_end = window_end,
            .aggregation_method = aggregation_method,
            .min_value = min_val,
            .max_value = max_val,
            .sum_value = sum,
            .count = count,
            .p95_value = p95_val,
            .p99_value = p99_val,
            .created_at = std.time.timestamp(),
            .needs_invalidation = false,
        };

        try entry.value_ptr.append(self.allocator, rollup);
    }

    /// Query pre-computed rollups for a time range
    pub fn queryRollups(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        granularity_seconds: u64,
    ) ![]const Rollup {
        const rollup_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}:{d}", .{ entity_namespace, entity_local_id, attribute_key, granularity_seconds });
        defer self.allocator.free(rollup_key);

        const rollups = self.rollups.get(rollup_key) orelse return &[_]Rollup{};

        // Filter by time range and check invalidation status
        var filtered = ArrayListManaged(Rollup){};
        errdefer filtered.deinit(self.allocator);

        for (rollups.items) |rollup| {
            if (!rollup.needs_invalidation and rollup.window_end > start_time and rollup.window_start < end_time) {
                try filtered.append(self.allocator, rollup);
            }
        }

        return filtered.toOwnedSlice(self.allocator);
    }

    /// Invalidate rollups that are affected by late-arriving data
    pub fn invalidateRollups(
        self: *TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        late_timestamp: i64,
    ) !void {
        // Mark all rollups that overlap with the late timestamp as needing invalidation
        var it = self.rollups.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.indexOf(u8, key, entity_namespace) != null and
                std.mem.indexOf(u8, key, entity_local_id) != null and
                std.mem.indexOf(u8, key, attribute_key) != null)
            {
                for (entry.value_ptr.items) |*rollup| {
                    // If the late data falls within or before this rollup's window, it's stale
                    if (late_timestamp <= rollup.window_end) {
                        rollup.needs_invalidation = true;
                    }
                }
            }
        }
    }

    /// Calculate rate of change (derivative) for time-series data
    /// Computes per-second or per-minute rate based on granularity_seconds
    pub fn calculateRate(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        granularity_seconds: u64,
    ) !?RateSeries {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // Collect all numeric time-series data for this attribute
        var time_values = ArrayListManaged(struct { i64, f64 }){};
        defer time_values.deinit(self.allocator);

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    if (std.mem.eql(u8, change.key, attribute_key)) {
                        if (change.new_value) |v| {
                            const parsed = std.fmt.parseFloat(f64, v) catch continue;
                            try time_values.append(self.allocator, .{ change_time, parsed });
                        }
                    }
                }
            }
        }

        if (time_values.items.len < 2) return null;

        // Sort by timestamp
        std.mem.sort(struct { i64, f64 }, time_values.items, {}, struct {
            fn lessThan(_: void, a: struct { i64, f64 }, b: struct { i64, f64 }) bool {
                return a[0] < b[0];
            }
        }.lessThan);

        // Calculate rates (derivatives)
        var points = ArrayListManaged(RatePoint){};
        errdefer points.deinit(self.allocator);

        var sum_rate: f64 = 0;
        var max_rate: f64 = std.math.floatMin(f64);
        var min_rate: f64 = std.math.floatMax(f64);

        for (time_values.items[0.. time_values.items.len - 1], 0..) |tv, i| {
            const next_tv = time_values.items[i + 1];
            const time_delta = @as(f64, @floatFromInt(next_tv[0] - tv[0]));

            // Only calculate rate if we have meaningful time difference
            if (time_delta > 0) {
                const value_delta = next_tv[1] - tv[1];
                const rate = value_delta / time_delta;

                // Scale to requested granularity (per-second, per-minute, etc.)
                const scaled_rate = rate * @as(f64, @floatFromInt(granularity_seconds));

                try points.append(self.allocator, .{
                    .timestamp = next_tv[0],
                    .rate = scaled_rate,
                    .time_delta_seconds = time_delta,
                });

                sum_rate += scaled_rate;
                if (scaled_rate > max_rate) max_rate = scaled_rate;
                if (scaled_rate < min_rate) min_rate = scaled_rate;
            }
        }

        if (points.items.len == 0) return null;

        const avg_rate = sum_rate / @as(f64, @floatFromInt(points.items.len));

        return RateSeries{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .attribute_key = try self.allocator.dupe(u8, attribute_key),
            .granularity_seconds = granularity_seconds,
            .points = points,
            .average_rate = avg_rate,
            .max_rate = max_rate,
            .min_rate = min_rate,
        };
    }

    /// Query threshold violations for time-series data
    /// Detects when values cross upper or lower thresholds
    pub fn queryThresholdViolations(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        upper_threshold: ?f64,
        lower_threshold: ?f64,
    ) !?AlertResult {
        // Must have at least one threshold
        if (upper_threshold == null and lower_threshold == null) return null;

        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        // Collect all numeric time-series data for this attribute
        var time_values = ArrayListManaged(struct { i64, f64 }){};
        defer time_values.deinit(self.allocator);

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    if (std.mem.eql(u8, change.key, attribute_key)) {
                        if (change.new_value) |v| {
                            const parsed = std.fmt.parseFloat(f64, v) catch continue;
                            try time_values.append(self.allocator, .{ change_time, parsed });
                        }
                    }
                }
            }
        }

        if (time_values.items.len == 0) return null;

        // Detect violations
        var violations = ArrayListManaged(ThresholdViolation){};
        errdefer violations.deinit(self.allocator);

        for (time_values.items) |tv| {
            const timestamp = tv[0];
            const value = tv[1];

            // Check upper threshold
            if (upper_threshold) |ut| {
                if (value > ut) {
                    const severity = if (ut != 0) (value - ut) / @abs(ut) else value;
                    try violations.append(self.allocator, .{
                        .timestamp = timestamp,
                        .value = value,
                        .threshold = ut,
                        .violation_type = .above,
                        .severity = severity,
                    });
                }
            }

            // Check lower threshold
            if (lower_threshold) |lt| {
                if (value < lt) {
                    const severity = if (lt != 0) (lt - value) / @abs(lt) else -value;
                    try violations.append(self.allocator, .{
                        .timestamp = timestamp,
                        .value = value,
                        .threshold = lt,
                        .violation_type = .below,
                        .severity = severity,
                    });
                }
            }
        }

        return AlertResult{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .attribute_key = try self.allocator.dupe(u8, attribute_key),
            .upper_threshold = upper_threshold,
            .lower_threshold = lower_threshold,
            .violation_count = @intCast(violations.items.len),
            .violations = violations,
            .start_time = start_time,
            .end_time = end_time,
        };
    }

    /// Compute change frequency for entity (hot/cold detection)
    pub fn computeChangeFrequency(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
    ) !?ChangeFrequency {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        var change_count: u64 = 0;
        var first_ts: i64 = std.math.maxInt(i64);
        var last_ts: i64 = std.math.minInt(i64);

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    change_count += 1;
                    if (change_time < first_ts) first_ts = change_time;
                    if (change_time > last_ts) last_ts = change_time;
                }
            }
        }

        if (change_count == 0) return null;

        return ChangeFrequency{
            .entity_namespace = try self.allocator.dupe(u8, entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, entity_local_id),
            .change_count = change_count,
            .first_change_ts = first_ts,
            .last_change_ts = last_ts,
        };
    }

    /// Count distinct values for an attribute over time
    pub fn countDistinct(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
    ) !u64 {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return 0;

        var distinct_set = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = distinct_set.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            distinct_set.deinit();
        }

        for (chunks.items) |chunk| {
            for (chunk.changes.items) |change| {
                const change_time = change.timestamp.value();
                if (change_time >= start_time and change_time <= end_time) {
                    if (std.mem.eql(u8, change.key, attribute_key)) {
                        if (change.new_value) |v| {
                            const owned = try self.allocator.dupe(u8, v);
                            try distinct_set.put(owned, {});
                        }
                    }
                }
            }
        }

        return distinct_set.count();
    }

    /// Get first state observation for an entity
    pub fn getFirstState(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
    ) !?StateChange {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        var earliest_change: ?*const StateChange = null;
        var earliest_ts: i64 = std.math.maxInt(i64);

        // First pass: find the earliest change
        for (chunks.items) |chunk| {
            for (chunk.changes.items) |*change| {
                const change_time = change.timestamp.value();
                if (change_time < earliest_ts) {
                    earliest_ts = change_time;
                    earliest_change = change;
                }
            }
        }

        // Second pass: create copy if found
        if (earliest_change) |ch| {
            return StateChange{
                .id = try self.allocator.dupe(u8, ch.id),
                .txn_id = ch.txn_id,
                .timestamp = ch.timestamp,
                .entity_namespace = try self.allocator.dupe(u8, ch.entity_namespace),
                .entity_local_id = try self.allocator.dupe(u8, ch.entity_local_id),
                .change_type = ch.change_type,
                .key = try self.allocator.dupe(u8, ch.key),
                .old_value = if (ch.old_value) |v| try self.allocator.dupe(u8, v) else null,
                .new_value = if (ch.new_value) |v| try self.allocator.dupe(u8, v) else null,
                .metadata = try self.allocator.dupe(u8, ch.metadata),
            };
        }

        return null;
    }

    /// Get last state observation for an entity
    pub fn getLastState(
        self: *const TemporalIndex,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
    ) !?StateChange {
        const entity_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entity_namespace, entity_local_id });
        defer self.allocator.free(entity_key);

        const chunks = self.entity_chunks.get(entity_key) orelse return null;

        var latest_change: ?*const StateChange = null;
        var latest_ts: i64 = std.math.minInt(i64);

        // First pass: find the latest change
        for (chunks.items) |chunk| {
            for (chunk.changes.items) |*change| {
                const change_time = change.timestamp.value();
                if (change_time > latest_ts) {
                    latest_ts = change_time;
                    latest_change = change;
                }
            }
        }

        // Second pass: create copy if found
        if (latest_change) |ch| {
            return StateChange{
                .id = try self.allocator.dupe(u8, ch.id),
                .txn_id = ch.txn_id,
                .timestamp = ch.timestamp,
                .entity_namespace = try self.allocator.dupe(u8, ch.entity_namespace),
                .entity_local_id = try self.allocator.dupe(u8, ch.entity_local_id),
                .change_type = ch.change_type,
                .key = try self.allocator.dupe(u8, ch.key),
                .old_value = if (ch.old_value) |v| try self.allocator.dupe(u8, v) else null,
                .new_value = if (ch.new_value) |v| try self.allocator.dupe(u8, v) else null,
                .metadata = try self.allocator.dupe(u8, ch.metadata),
            };
        }

        return null;
    }

    /// Query multiple entities at same timestamp (time-travel join)
    pub fn queryMultipleAsOf(
        self: *const TemporalIndex,
        entities: []const struct { []const u8, []const u8 },
        timestamp: i64,
    ) !ArrayListManaged(?StateChange) {
        var results = ArrayListManaged(?StateChange){};

        for (entities) |entity| {
            const ns, const id = entity;
            const state = try self.queryAsOf(ns, id, timestamp);
            if (state) |s| {
                const copy = StateChange{
                    .id = try self.allocator.dupe(u8, s.id),
                    .txn_id = s.txn_id,
                    .timestamp = s.timestamp,
                    .entity_namespace = try self.allocator.dupe(u8, s.entity_namespace),
                    .entity_local_id = try self.allocator.dupe(u8, s.entity_local_id),
                    .change_type = s.change_type,
                    .key = try self.allocator.dupe(u8, s.key),
                    .old_value = if (s.old_value) |v| try self.allocator.dupe(u8, v) else null,
                    .new_value = if (s.new_value) |v| try self.allocator.dupe(u8, v) else null,
                    .metadata = try self.allocator.dupe(u8, s.metadata),
                };
                try results.append(self.allocator, copy);
            } else {
                try results.append(self.allocator, null);
            }
        }

        return results;
    }
};

// ==================== Temporal History Cartridge ====================

/// Temporal history cartridge with time-series storage and snapshot support
pub const TemporalHistoryCartridge = struct {
    allocator: std.mem.Allocator,
    header: format.CartridgeHeader,
    /// Temporal index for time-series queries
    index: TemporalIndex,
    /// Snapshot manager for entity state versioning
    snapshot_manager: SnapshotManager,

    /// Create new temporal history cartridge
    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64) !TemporalHistoryCartridge {
        const header = format.CartridgeHeader.init(.temporal_history, source_txn_id);
        return TemporalHistoryCartridge{
            .allocator = allocator,
            .header = header,
            .index = TemporalIndex.init(allocator),
            .snapshot_manager = SnapshotManager.init(allocator),
        };
    }

    pub fn deinit(self: *TemporalHistoryCartridge) void {
        self.index.deinit();
        self.snapshot_manager.deinit();
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

    /// Create snapshot of entity state
    pub fn createSnapshot(
        self: *TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        state_data: []const u8,
        txn_id: u64,
        change_type: StateChangeType,
    ) ![]const u8 {
        return self.snapshot_manager.createSnapshot(
            entity_namespace,
            entity_local_id,
            state_data,
            txn_id,
            change_type,
        );
    }

    /// Get snapshot by transaction ID
    pub fn getSnapshotByTxnId(self: *const TemporalHistoryCartridge, txn_id: u64) !?[]const EntitySnapshot {
        return self.snapshot_manager.index.findByTxnId(txn_id);
    }

    /// Get snapshot at or before specific timestamp
    pub fn getSnapshotAsOf(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        timestamp: i64,
    ) !?EntitySnapshot {
        return self.snapshot_manager.index.findByTimestamp(entity_namespace, entity_local_id, timestamp);
    }

    /// Get all snapshots for an entity (version chain)
    pub fn getSnapshotChain(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
    ) ![]const EntitySnapshot {
        return self.snapshot_manager.index.getSnapshotChain(entity_namespace, entity_local_id);
    }

    /// Restore entity state from snapshot
    pub fn restoreFromSnapshot(
        self: *const TemporalHistoryCartridge,
        snapshot_id: []const u8,
    ) !?[]const u8 {
        return self.snapshot_manager.restoreFromSnapshot(snapshot_id);
    }

    // ==================== Temporal Aggregation API ====================

    /// Compute change frequency for entity (hot/cold detection)
    pub fn computeChangeFrequency(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
    ) !?TemporalIndex.ChangeFrequency {
        return self.index.computeChangeFrequency(entity_namespace, entity_local_id, start_time, end_time);
    }

    /// Count distinct values for an attribute over time
    pub fn countDistinct(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
    ) !u64 {
        return self.index.countDistinct(entity_namespace, entity_local_id, attribute_key, start_time, end_time);
    }

    /// Get first state observation for an entity
    pub fn getFirstState(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
    ) !?StateChange {
        return self.index.getFirstState(entity_namespace, entity_local_id);
    }

    /// Get last state observation for an entity
    pub fn getLastState(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
    ) !?StateChange {
        return self.index.getLastState(entity_namespace, entity_local_id);
    }

    /// Query multiple entities at same timestamp (time-travel join)
    pub fn queryMultipleAsOf(
        self: *const TemporalHistoryCartridge,
        entities: []const struct { []const u8, []const u8 },
        timestamp: i64,
    ) !ArrayListManaged(?StateChange) {
        return self.index.queryMultipleAsOf(entities, timestamp);
    }

    // ==================== Analytics API ====================

    /// Detect anomalies using Z-score method
    pub fn detectAnomaliesZScore(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        threshold: f64,
    ) !?TemporalIndex.AnomalyResult {
        return self.index.detectAnomaliesZScore(entity_namespace, entity_local_id, attribute_key, start_time, end_time, threshold);
    }

    /// Detect anomalies using IQR method
    pub fn detectAnomaliesIQR(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        multiplier: f64,
    ) !?TemporalIndex.AnomalyResult {
        return self.index.detectAnomaliesIQR(entity_namespace, entity_local_id, attribute_key, start_time, end_time, multiplier);
    }

    /// Generate temporal histogram
    pub fn generateTemporalHistogram(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
        granularity_seconds: u64,
    ) !?TemporalIndex.TemporalHistogram {
        return self.index.generateTemporalHistogram(entity_namespace, entity_local_id, start_time, end_time, granularity_seconds);
    }

    /// Generate hour-of-day histogram
    pub fn generateHourOfDayHistogram(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
    ) !?TemporalIndex.TemporalHistogram {
        return self.index.generateHourOfDayHistogram(entity_namespace, entity_local_id, start_time, end_time);
    }

    /// Generate day-of-week histogram
    pub fn generateDayOfWeekHistogram(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
    ) !?TemporalIndex.TemporalHistogram {
        return self.index.generateDayOfWeekHistogram(entity_namespace, entity_local_id, start_time, end_time);
    }

    /// Generate activity heatmap
    pub fn generateActivityHeatmap(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        start_time: i64,
        end_time: i64,
    ) !?TemporalIndex.ActivityHeatmap {
        return self.index.generateActivityHeatmap(entity_namespace, entity_local_id, start_time, end_time);
    }

    /// Downsample time series data
    pub fn downsampleSeries(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        target_granularity_seconds: u64,
        aggregation_method: TemporalIndex.DownsampledSeries.AggregationMethod,
    ) !?TemporalIndex.DownsampledSeries {
        return self.index.downsampleSeries(entity_namespace, entity_local_id, attribute_key, start_time, end_time, target_granularity_seconds, aggregation_method);
    }

    /// Calculate rate of change for time-series data
    pub fn calculateRate(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        granularity_seconds: u64,
    ) !?TemporalIndex.RateSeries {
        return self.index.calculateRate(entity_namespace, entity_local_id, attribute_key, start_time, end_time, granularity_seconds);
    }

    /// Query threshold violations for alerting
    pub fn queryThresholdViolations(
        self: *const TemporalHistoryCartridge,
        entity_namespace: []const u8,
        entity_local_id: []const u8,
        attribute_key: []const u8,
        start_time: i64,
        end_time: i64,
        upper_threshold: ?f64,
        lower_threshold: ?f64,
    ) !?TemporalIndex.AlertResult {
        return self.index.queryThresholdViolations(entity_namespace, entity_local_id, attribute_key, start_time, end_time, upper_threshold, lower_threshold);
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

// ==================== Snapshot System Tests ====================

test "SnapshotIndex.init and addSnapshot" {
    var index = SnapshotIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    const snapshot = EntitySnapshot{
        .id = "snap1",
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .version = 1,
        .parent_snapshot_id = null,
        .branch_id = null,
        .state_data = "{\"status\":\"active\"}",
        .delta_info = null,
        .metadata = "{}",
    };

    try index.addSnapshot(snapshot);

    try std.testing.expectEqual(@as(u64, 1), index.total_snapshots);
}

test "SnapshotIndex.findByTimestamp" {
    var index = SnapshotIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    const snapshot1 = EntitySnapshot{
        .id = "snap1",
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -100 },
        .version = 1,
        .parent_snapshot_id = null,
        .branch_id = null,
        .state_data = "{\"status\":\"pending\"}",
        .delta_info = null,
        .metadata = "{}",
    };

    const snapshot2 = EntitySnapshot{
        .id = "snap2",
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .txn_id = 101,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .version = 2,
        .parent_snapshot_id = "snap1",
        .branch_id = null,
        .state_data = "{\"status\":\"active\"}",
        .delta_info = null,
        .metadata = "{}",
    };

    try index.addSnapshot(snapshot1);
    try index.addSnapshot(snapshot2);

    // Query for snapshot at current time should return snap2
    const result = try index.findByTimestamp("test", "entity1", ts);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("snap2", result.?.id);
}

test "SnapshotIndex.getSnapshotChain" {
    var index = SnapshotIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    const snapshot1 = EntitySnapshot{
        .id = "snap1",
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -200 },
        .version = 1,
        .parent_snapshot_id = null,
        .branch_id = null,
        .state_data = "{\"v\":1}",
        .delta_info = null,
        .metadata = "{}",
    };

    const snapshot2 = EntitySnapshot{
        .id = "snap2",
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .txn_id = 101,
        .timestamp = .{ .base = @intCast(ts), .delta = -100 },
        .version = 2,
        .parent_snapshot_id = "snap1",
        .branch_id = null,
        .state_data = "{\"v\":2}",
        .delta_info = null,
        .metadata = "{}",
    };

    const snapshot3 = EntitySnapshot{
        .id = "snap3",
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .txn_id = 102,
        .timestamp = .{ .base = @intCast(ts), .delta = 0 },
        .version = 3,
        .parent_snapshot_id = "snap2",
        .branch_id = null,
        .state_data = "{\"v\":3}",
        .delta_info = null,
        .metadata = "{}",
    };

    try index.addSnapshot(snapshot1);
    try index.addSnapshot(snapshot2);
    try index.addSnapshot(snapshot3);

    const chain = try index.getSnapshotChain("test", "entity1");

    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqual(@as(u64, 1), chain[0].version);
    try std.testing.expectEqual(@as(u64, 2), chain[1].version);
    try std.testing.expectEqual(@as(u64, 3), chain[2].version);
}

test "SnapshotManager.createSnapshot" {
    var manager = SnapshotManager.init(std.testing.allocator);
    defer manager.deinit();

    const state_data = "{\"status\":\"active\",\"priority\":\"high\"}";

    const snapshot_id = try manager.createSnapshot(
        "test",
        "entity1",
        state_data,
        100,
        .entity_created,
    );
    defer std.testing.allocator.free(snapshot_id);

    try std.testing.expect(snapshot_id.len > 0);

    // Verify snapshot was indexed
    const chain = try manager.index.getSnapshotChain("test", "entity1");
    try std.testing.expectEqual(@as(usize, 1), chain.len);
    try std.testing.expectEqual(@as(u64, 1), chain[0].version);
}

test "SnapshotManager.createSnapshotVersioning" {
    var manager = SnapshotManager.init(std.testing.allocator);
    defer manager.deinit();

    // Create first snapshot
    const snap1_id = try manager.createSnapshot(
        "test",
        "entity1",
        "{\"v\":1}",
        100,
        .entity_created,
    );
    defer std.testing.allocator.free(snap1_id);

    // Create second snapshot
    const snap2_id = try manager.createSnapshot(
        "test",
        "entity1",
        "{\"v\":2}",
        101,
        .attribute_update,
    );
    defer std.testing.allocator.free(snap2_id);

    // Create third snapshot
    const snap3_id = try manager.createSnapshot(
        "test",
        "entity1",
        "{\"v\":3}",
        102,
        .attribute_update,
    );
    defer std.testing.allocator.free(snap3_id);

    const chain = try manager.index.getSnapshotChain("test", "entity1");

    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqual(@as(u64, 1), chain[0].version);
    try std.testing.expectEqual(@as(u64, 2), chain[1].version);
    try std.testing.expectEqual(@as(u64, 3), chain[2].version);

    // Verify parent chain
    try std.testing.expect(chain[0].parent_snapshot_id == null);
    try std.testing.expect(chain[1].parent_snapshot_id != null);
    try std.testing.expect(chain[2].parent_snapshot_id != null);
}

test "TemporalHistoryCartridge.createSnapshot" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const state_data = "{\"status\":\"active\",\"tags\":[\"important\"]}";

    const snapshot_id = try cartridge.createSnapshot(
        "file",
        "main.zig",
        state_data,
        100,
        .entity_created,
    );
    defer std.testing.allocator.free(snapshot_id);

    try std.testing.expect(snapshot_id.len > 0);

    // Verify we can retrieve the snapshot
    const snapshot = try cartridge.getSnapshotAsOf("file", "main.zig", std.time.timestamp());
    try std.testing.expect(snapshot != null);
    try std.testing.expectEqualStrings(state_data, snapshot.?.state_data);
}

test "TemporalHistoryCartridge.snapshotChainRetrieval" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    // Create multiple snapshots
    {
        const id = try cartridge.createSnapshot("test", "entity1", "{\"v\":1}", 100, .entity_created);
        defer std.testing.allocator.free(id);
    }
    {
        const id = try cartridge.createSnapshot("test", "entity1", "{\"v\":2}", 101, .attribute_update);
        defer std.testing.allocator.free(id);
    }
    {
        const id = try cartridge.createSnapshot("test", "entity1", "{\"v\":3}", 102, .attribute_update);
        defer std.testing.allocator.free(id);
    }

    const chain = try cartridge.getSnapshotChain("test", "entity1");

    try std.testing.expectEqual(@as(usize, 3), chain.len);

    // Verify version ordering
    try std.testing.expectEqual(@as(u64, 1), chain[0].version);
    try std.testing.expectEqual(@as(u64, 2), chain[1].version);
    try std.testing.expectEqual(@as(u64, 3), chain[2].version);
}

test "TemporalHistoryCartridge.restoreFromSnapshot" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const original_state = "{\"name\":\"test\",\"value\":42}";

    const snapshot_id = try cartridge.createSnapshot(
        "test",
        "entity1",
        original_state,
        100,
        .entity_created,
    );
    defer std.testing.allocator.free(snapshot_id);

    const restored = try cartridge.restoreFromSnapshot(snapshot_id);

    try std.testing.expect(restored != null);
    try std.testing.expectEqualStrings(original_state, restored.?);
}

test "EntitySnapshot.DeltaInfo.compressionTypes" {
    // Test that compression type enum works correctly
    const none: EntitySnapshot.DeltaInfo.CompressionType = .none;
    const field: EntitySnapshot.DeltaInfo.CompressionType = .field_delta;
    const binary: EntitySnapshot.DeltaInfo.CompressionType = .binary_delta;
    const lz4: EntitySnapshot.DeltaInfo.CompressionType = .lz4_delta;

    _ = none;
    _ = field;
    _ = binary;
    _ = lz4;

    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(EntitySnapshot.DeltaInfo.CompressionType.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EntitySnapshot.DeltaInfo.CompressionType.field_delta));
}

test "SnapshotManager.policyConfiguration" {
    var manager = SnapshotManager.init(std.testing.allocator);
    defer manager.deinit();

    // Test default policy
    try std.testing.expectEqual(@as(u64, 100), manager.policy.snapshot_interval);
    try std.testing.expectEqual(@as(u64, 10), manager.policy.max_full_snapshots);
    try std.testing.expect(manager.policy.enable_delta_compression);
}

test "TemporalHistoryCartridge.integratedOperations" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const ts = std.time.timestamp();

    // Add some state changes
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

    try cartridge.addChange(change1);
    try cartridge.addChange(change2);

    // Create snapshot after changes
    const snapshot_id = try cartridge.createSnapshot(
        "test",
        "entity1",
        "{\"status\":\"active\"}",
        102,
        .attribute_update,
    );
    defer std.testing.allocator.free(snapshot_id);

    // Verify both systems work together
    var changes = try cartridge.queryBetween("test", "entity1", ts - 200, ts);
    defer {
        for (changes.items) |*c| c.deinit(std.testing.allocator);
        changes.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), changes.items.len);

    const snapshot = try cartridge.getSnapshotAsOf("test", "entity1", ts + 1000);
    try std.testing.expect(snapshot != null);
    try std.testing.expectEqualStrings(snapshot_id, snapshot.?.id);
}

// ==================== Temporal Aggregation Tests ====================

test "TemporalIndex.computeChangeFrequency" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add multiple changes for same entity
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "status", .old_value = null, .new_value = "pending", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "status", .old_value = "pending", .new_value = "active", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "status", .old_value = "active", .new_value = "complete", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    const freq = try index.computeChangeFrequency("test", "entity1", ts - 350, ts);
    try std.testing.expect(freq != null);
    try std.testing.expectEqual(@as(u64, 3), freq.?.change_count);
}

test "TemporalIndex.countDistinct" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add changes with different values for same attribute
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "priority", .old_value = null, .new_value = "low", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "priority", .old_value = "low", .new_value = "high", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "priority", .old_value = "high", .new_value = "low", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    const count = try index.countDistinct("test", "entity1", "priority", ts - 350, ts);
    // Should count "low" and "high" = 2 distinct values
    try std.testing.expectEqual(@as(u64, 2), count);
}

test "TemporalIndex.getFirstState" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    const change1 = StateChange{
        .id = "first",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -200 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .entity_created,
        .key = "status",
        .old_value = null,
        .new_value = "initialized",
        .metadata = "{}",
    };

    const change2 = StateChange{
        .id = "second",
        .txn_id = 101,
        .timestamp = .{ .base = @intCast(ts), .delta = -100 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = "initialized",
        .new_value = "active",
        .metadata = "{}",
    };

    try index.addChange(change1);
    try index.addChange(change2);

    const first = try index.getFirstState("test", "entity1");
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("first", first.?.id);
    try std.testing.expectEqualStrings("initialized", first.?.new_value.?);
}

test "TemporalIndex.getLastState" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    const change1 = StateChange{
        .id = "early",
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
        .id = "late",
        .txn_id = 101,
        .timestamp = .{ .base = @intCast(ts), .delta = -100 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "status",
        .old_value = "pending",
        .new_value = "complete",
        .metadata = "{}",
    };

    try index.addChange(change1);
    try index.addChange(change2);

    const last = try index.getLastState("test", "entity1");
    try std.testing.expect(last != null);
    try std.testing.expectEqualStrings("late", last.?.id);
    try std.testing.expectEqualStrings("complete", last.?.new_value.?);
}

test "TemporalIndex.queryMultipleAsOf" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Entity1 at ts - 100
    const change1 = StateChange{
        .id = "entity1_v1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -100 },
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_type = .attribute_update,
        .key = "value",
        .old_value = null,
        .new_value = "A",
        .metadata = "{}",
    };

    // Entity2 at ts - 100
    const change2 = StateChange{
        .id = "entity2_v1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -100 },
        .entity_namespace = "test",
        .entity_local_id = "entity2",
        .change_type = .attribute_update,
        .key = "value",
        .old_value = null,
        .new_value = "B",
        .metadata = "{}",
    };

    // Entity3 (no changes at query time)

    try index.addChange(change1);
    try index.addChange(change2);

    const entities = [_]struct { []const u8, []const u8 }{
        .{ "test", "entity1" },
        .{ "test", "entity2" },
        .{ "test", "entity3" },
    };

    var results = try index.queryMultipleAsOf(&entities, ts - 50);
    defer {
        for (results.items) |r| {
            if (r) |*s| s.deinit(std.testing.allocator);
        }
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 3), results.items.len);
    try std.testing.expect(results.items[0] != null);
    try std.testing.expect(results.items[1] != null);
    try std.testing.expect(results.items[2] == null);
}

test "TemporalHistoryCartridge.temporalAggregations" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const ts = std.time.timestamp();

    // Build up change history
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -400 }, .entity_namespace = "file", .entity_local_id = "main.zig", .change_type = .attribute_update, .key = "lines", .old_value = null, .new_value = "100", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "file", .entity_local_id = "main.zig", .change_type = .attribute_update, .key = "lines", .old_value = "100", .new_value = "150", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "file", .entity_local_id = "main.zig", .change_type = .attribute_update, .key = "lines", .old_value = "150", .new_value = "200", .metadata = "{}" },
        .{ .id = "c4", .txn_id = 103, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "file", .entity_local_id = "main.zig", .change_type = .attribute_update, .key = "lines", .old_value = "200", .new_value = "250", .metadata = "{}" },
    };

    for (changes) |c| try cartridge.addChange(c);

    // Test change frequency
    const freq = try cartridge.computeChangeFrequency("file", "main.zig", ts - 500, ts);
    try std.testing.expect(freq != null);
    try std.testing.expectEqual(@as(u64, 4), freq.?.change_count);

    // Test distinct values (100, 150, 200, 250 = 4 distinct)
    const distinct = try cartridge.countDistinct("file", "main.zig", "lines", ts - 500, ts);
    try std.testing.expectEqual(@as(u64, 4), distinct);

    // Test first state
    const first = try cartridge.getFirstState("file", "main.zig");
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("100", first.?.new_value.?);

    // Test last state
    const last = try cartridge.getLastState("file", "main.zig");
    try std.testing.expect(last != null);
    try std.testing.expectEqualStrings("250", last.?.new_value.?);
}

test "TemporalHistoryCartridge.crossEntityTimeTravel" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const ts = std.time.timestamp();

    // Entity A: file1.txt
    try cartridge.addChange(StateChange{
        .id = "file1_v1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -200 },
        .entity_namespace = "document",
        .entity_local_id = "file1.txt",
        .change_type = .attribute_update,
        .key = "size",
        .old_value = null,
        .new_value = "1024",
        .metadata = "{}",
    });

    // Entity B: file2.txt
    try cartridge.addChange(StateChange{
        .id = "file2_v1",
        .txn_id = 100,
        .timestamp = .{ .base = @intCast(ts), .delta = -200 },
        .entity_namespace = "document",
        .entity_local_id = "file2.txt",
        .change_type = .attribute_update,
        .key = "size",
        .old_value = null,
        .new_value = "2048",
        .metadata = "{}",
    });

    const entities = [_]struct { []const u8, []const u8 }{
        .{ "document", "file1.txt" },
        .{ "document", "file2.txt" },
    };

    // Query both entities at the same point in time
    var results = try cartridge.queryMultipleAsOf(&entities, ts - 100);
    defer {
        for (results.items) |r| {
            if (r) |*s| s.deinit(std.testing.allocator);
        }
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expect(results.items[0] != null);
    try std.testing.expect(results.items[1] != null);
    try std.testing.expectEqualStrings("1024", results.items[0].?.new_value.?);
    try std.testing.expectEqualStrings("2048", results.items[1].?.new_value.?);
}

test "TemporalIndex.ChangeFrequency struct" {
    // Test the ChangeFrequency struct can be created
    const freq = TemporalIndex.ChangeFrequency{
        .entity_namespace = "test",
        .entity_local_id = "entity1",
        .change_count = 10,
        .first_change_ts = 1000,
        .last_change_ts = 2000,
    };

    try std.testing.expectEqual(@as(u64, 10), freq.change_count);
    try std.testing.expectEqual(@as(i64, 1000), freq.first_change_ts);
    try std.testing.expectEqual(@as(i64, 2000), freq.last_change_ts);
}

// ==================== Analytics Tests ====================

test "TemporalIndex.detectAnomaliesZScore" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add changes with one anomaly (values around 10-12, with 100.0 as anomaly)
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -500 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "metric", .old_value = null, .new_value = "10.0", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -400 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "metric", .old_value = "10.0", .new_value = "11.0", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "metric", .old_value = "11.0", .new_value = "10.5", .metadata = "{}" },
        .{ .id = "c4", .txn_id = 103, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "metric", .old_value = "10.5", .new_value = "11.5", .metadata = "{}" },
        .{ .id = "c5", .txn_id = 104, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "metric", .old_value = "11.5", .new_value = "10.2", .metadata = "{}" },
        .{ .id = "c6", .txn_id = 105, .timestamp = .{ .base = @intCast(ts), .delta = -50 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "metric", .old_value = "10.2", .new_value = "100.0", .metadata = "{}" },
        .{ .id = "c7", .txn_id = 106, .timestamp = .{ .base = @intCast(ts), .delta = 0 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "metric", .old_value = "100.0", .new_value = "10.8", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    var result = try index.detectAnomaliesZScore("test", "entity1", "metric", ts - 600, ts, 2.0);

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.anomaly_count > 0);
    try std.testing.expect(result.?.baseline_mean > 0);
    try std.testing.expect(result.?.baseline_stddev > 0);

    // Verify cleanup
    if (result) |*r| r.deinit(std.testing.allocator);
}

test "TemporalIndex.detectAnomaliesIQR" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add changes with outliers
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -400 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = null, .new_value = "10.0", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "10.0", .new_value = "12.0", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "12.0", .new_value = "11.0", .metadata = "{}" },
        .{ .id = "c4", .txn_id = 103, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "11.0", .new_value = "13.0", .metadata = "{}" },
        .{ .id = "c5", .txn_id = 104, .timestamp = .{ .base = @intCast(ts), .delta = 0 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "13.0", .new_value = "10.5", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    var result = try index.detectAnomaliesIQR("test", "entity1", "value", ts - 500, ts, 1.5);

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.baseline_mean > 0);

    // Verify cleanup
    if (result) |*r| r.deinit(std.testing.allocator);
}

test "TemporalIndex.generateTemporalHistogram" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add changes spread across time
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        const change = StateChange{
            .id = try std.fmt.allocPrint(std.testing.allocator, "c{d}", .{i}),
            .txn_id = 100 + i,
            .timestamp = .{ .base = @intCast(ts), .delta = -@as(i64, @intCast(i * 100)) },
            .entity_namespace = "test",
            .entity_local_id = "entity1",
            .change_type = .attribute_update,
            .key = "status",
            .old_value = null,
            .new_value = "active",
            .metadata = "{}",
        };
        defer std.testing.allocator.free(change.id);
        try index.addChange(change);
    }

    var result = try index.generateTemporalHistogram("test", "entity1", ts - 1000, ts, 100);

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.total_events == 10);
    try std.testing.expect(result.?.buckets.items.len > 0);
    try std.testing.expectEqual(@as(u64, 100), result.?.granularity_seconds);

    // Verify cleanup
    if (result) |*r| r.deinit(std.testing.allocator);
}

test "TemporalIndex.generateHourOfDayHistogram" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add changes at different hours
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -86400 - 3600 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "a", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -86400 + 3600 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "b", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -7200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "c", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    var result = try index.generateHourOfDayHistogram("test", "entity1", ts - 100000, ts);

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.total_events == 3);
    try std.testing.expectEqual(@as(u64, 3600), result.?.granularity_seconds);

    if (result) |*r| r.deinit(std.testing.allocator);
}

test "TemporalIndex.generateDayOfWeekHistogram" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add changes across different days
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -86400 * 3 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "a", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -86400 * 2 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "b", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -86400 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "c", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    var result = try index.generateDayOfWeekHistogram("test", "entity1", ts - 500000, ts);

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.total_events == 3);
    try std.testing.expectEqual(@as(u64, 7), result.?.buckets.items.len);

    if (result) |*r| r.deinit(std.testing.allocator);
}

test "TemporalIndex.generateActivityHeatmap" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add changes at different times
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -86400 * 2 - 3600 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "a", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -86400 - 7200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "b", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -3600 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "event", .old_value = null, .new_value = "c", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    var result = try index.generateActivityHeatmap("test", "entity1", ts - 200000, ts);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 24), result.?.rows);
    try std.testing.expectEqual(@as(u64, 7), result.?.cols);
    try std.testing.expectEqual(@as(usize, 24 * 7), result.?.cells.items.len);
    try std.testing.expectEqual(@as(usize, 24), result.?.row_labels.items.len);
    try std.testing.expectEqual(@as(usize, 7), result.?.col_labels.items.len);

    if (result) |*r| r.deinit(std.testing.allocator);
}

test "TemporalIndex.downsampleSeries" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add numeric changes
    var i: u64 = 0;
    while (i < 20) : (i += 1) {
        const value_str = try std.fmt.allocPrint(std.testing.allocator, "{d:.1}", .{@as(f64, @floatFromInt(i)) * 1.5});
        defer std.testing.allocator.free(value_str);

        const change = StateChange{
            .id = try std.fmt.allocPrint(std.testing.allocator, "c{d}", .{i}),
            .txn_id = 100 + i,
            .timestamp = .{ .base = @intCast(ts), .delta = -@as(i64, @intCast(i * 50)) },
            .entity_namespace = "test",
            .entity_local_id = "entity1",
            .change_type = .attribute_update,
            .key = "metric",
            .old_value = null,
            .new_value = value_str,
            .metadata = "{}",
        };
        defer std.testing.allocator.free(change.id);
        try index.addChange(change);
    }

    var result = try index.downsampleSeries("test", "entity1", "metric", ts - 2000, ts, 100, .mean);

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.points.items.len > 0);
    try std.testing.expectEqual(@as(u64, 100), result.?.downsampled_granularity);
    try std.testing.expectEqual(TemporalIndex.DownsampledSeries.AggregationMethod.mean, result.?.aggregation_method);

    if (result) |*r| r.deinit(std.testing.allocator);
}

test "TemporalIndex.downsampleSeriesAggregationMethods" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add numeric changes
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = null, .new_value = "10.0", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "10.0", .new_value = "20.0", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "20.0", .new_value = "15.0", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    // Test mean aggregation
    {
        var result = try index.downsampleSeries("test", "entity1", "value", ts - 500, ts, 200, .mean);
        try std.testing.expect(result != null);
        try std.testing.expect(result.?.points.items.len > 0);
        if (result) |*r| r.deinit(std.testing.allocator);
    }

    // Test sum aggregation
    {
        var result = try index.downsampleSeries("test", "entity1", "value", ts - 500, ts, 200, .sum);
        try std.testing.expect(result != null);
        try std.testing.expect(result.?.points.items.len > 0);
        if (result) |*r| r.deinit(std.testing.allocator);
    }

    // Test min aggregation
    {
        var result = try index.downsampleSeries("test", "entity1", "value", ts - 500, ts, 200, .min);
        try std.testing.expect(result != null);
        try std.testing.expect(result.?.points.items.len > 0);
        if (result) |*r| r.deinit(std.testing.allocator);
    }

    // Test max aggregation
    {
        var result = try index.downsampleSeries("test", "entity1", "value", ts - 500, ts, 200, .max);
        try std.testing.expect(result != null);
        try std.testing.expect(result.?.points.items.len > 0);
        if (result) |*r| r.deinit(std.testing.allocator);
    }
}

test "TemporalIndex.downsampleSeriesPercentile" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add more numeric changes to get meaningful percentiles
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -500 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = null, .new_value = "10.0", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -400 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "10.0", .new_value = "20.0", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "20.0", .new_value = "15.0", .metadata = "{}" },
        .{ .id = "c4", .txn_id = 103, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "15.0", .new_value = "25.0", .metadata = "{}" },
        .{ .id = "c5", .txn_id = 104, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "25.0", .new_value = "30.0", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    // Test p95 aggregation
    {
        var result = try index.downsampleSeries("test", "entity1", "value", ts - 600, ts, 300, .p95);
        try std.testing.expect(result != null);
        try std.testing.expect(result.?.points.items.len > 0);
        // p95 should be >= min_value
        for (result.?.points.items) |p| {
            try std.testing.expect(p.p95_value >= p.min_value);
            try std.testing.expect(p.p95_value <= p.max_value);
        }
        if (result) |*r| r.deinit(std.testing.allocator);
    }

    // Test p99 aggregation
    {
        var result = try index.downsampleSeries("test", "entity1", "value", ts - 600, ts, 300, .p99);
        try std.testing.expect(result != null);
        try std.testing.expect(result.?.points.items.len > 0);
        // p99 should be >= min_value
        for (result.?.points.items) |p| {
            try std.testing.expect(p.p99_value >= p.min_value);
            try std.testing.expect(p.p99_value <= p.max_value);
        }
        if (result) |*r| r.deinit(std.testing.allocator);
    }
}

test "TemporalHistoryCartridge.analyticsIntegration" {
    var cartridge = try TemporalHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const ts = std.time.timestamp();

    // Add numeric changes for testing
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -400 }, .entity_namespace = "metrics", .entity_local_id = "cpu", .change_type = .attribute_update, .key = "usage", .old_value = null, .new_value = "10.5", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "metrics", .entity_local_id = "cpu", .change_type = .attribute_update, .key = "usage", .old_value = "10.5", .new_value = "11.2", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "metrics", .entity_local_id = "cpu", .change_type = .attribute_update, .key = "usage", .old_value = "11.2", .new_value = "10.8", .metadata = "{}" },
        .{ .id = "c4", .txn_id = 103, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "metrics", .entity_local_id = "cpu", .change_type = .attribute_update, .key = "usage", .old_value = "10.8", .new_value = "11.0", .metadata = "{}" },
    };

    for (changes) |c| try cartridge.addChange(c);

    // Test anomaly detection through cartridge
    {
        var anomalies = try cartridge.detectAnomaliesZScore("metrics", "cpu", "usage", ts - 500, ts, 2.0);
        if (anomalies) |*a| {
            try std.testing.expect(a.baseline_mean > 0);
            a.deinit(std.testing.allocator);
        }
    }

    // Test histogram through cartridge
    {
        var hist = try cartridge.generateTemporalHistogram("metrics", "cpu", ts - 500, ts, 100);
        if (hist) |*h| {
            try std.testing.expect(h.total_events > 0);
            h.deinit(std.testing.allocator);
        }
    }

    // Test heatmap through cartridge
    {
        var heatmap = try cartridge.generateActivityHeatmap("metrics", "cpu", ts - 500000, ts);
        if (heatmap) |*hm| {
            try std.testing.expectEqual(@as(u64, 24), hm.rows);
            hm.deinit(std.testing.allocator);
        }
    }

    // Test downsampling through cartridge
    {
        var downsampled = try cartridge.downsampleSeries("metrics", "cpu", "usage", ts - 500, ts, 100, .mean);
        if (downsampled) |*ds| {
            try std.testing.expect(ds.points.items.len > 0);
            ds.deinit(std.testing.allocator);
        }
    }
}

test "TemporalIndex.AnomalyResult.deinit" {
    // Test that AnomalyResult.deinit properly cleans up
    var result = TemporalIndex.AnomalyResult{
        .entity_namespace = try std.testing.allocator.dupe(u8, "test"),
        .entity_local_id = try std.testing.allocator.dupe(u8, "entity1"),
        .anomaly_count = 2,
        .baseline_mean = 10.5,
        .baseline_stddev = 2.3,
        .threshold = 2.0,
        .anomaly_timestamps = .{},
        .anomaly_values = .{},
    };

    try result.anomaly_timestamps.append(std.testing.allocator, 1000);
    try result.anomaly_timestamps.append(std.testing.allocator, 2000);
    try result.anomaly_values.append(std.testing.allocator, 15.0);
    try result.anomaly_values.append(std.testing.allocator, 18.0);

    result.deinit(std.testing.allocator);

    // If no crash/panic, test passes
}

test "TemporalIndex.TemporalHistogram.deinit" {
    var buckets = ArrayListManaged(TemporalIndex.HistogramBucket){};
    try buckets.append(std.testing.allocator, .{
        .bucket_id = 0,
        .count = 10,
        .period_start = 0,
        .period_end = 100,
    });

    var hist = TemporalIndex.TemporalHistogram{
        .entity_namespace = try std.testing.allocator.dupe(u8, "test"),
        .entity_local_id = try std.testing.allocator.dupe(u8, "entity1"),
        .total_events = 10,
        .buckets = buckets,
        .granularity_seconds = 100,
    };

    hist.deinit(std.testing.allocator);
}

test "TemporalIndex.ActivityHeatmap.deinit" {
    var cells = ArrayListManaged(TemporalIndex.HeatmapCell){};
    try cells.append(std.testing.allocator, .{
        .row = 0,
        .col = 0,
        .count = 5,
        .intensity = 0.5,
    });

    var row_labels = ArrayListManaged([]const u8){};
    try row_labels.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "00:00"));

    var col_labels = ArrayListManaged([]const u8){};
    try col_labels.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "Mon"));

    var heatmap = TemporalIndex.ActivityHeatmap{
        .entity_namespace = try std.testing.allocator.dupe(u8, "test"),
        .entity_local_id = try std.testing.allocator.dupe(u8, "entity1"),
        .rows = 1,
        .cols = 1,
        .cells = cells,
        .row_labels = row_labels,
        .col_labels = col_labels,
        .max_count = 10,
    };

    heatmap.deinit(std.testing.allocator);
}

test "TemporalIndex.DownsampledSeries.deinit" {
    var points = ArrayListManaged(TemporalIndex.DownsampledPoint){};
    try points.append(std.testing.allocator, .{
        .period_start = 0,
        .period_end = 100,
        .point_count = 5,
        .aggregated_value = 12.5,
        .min_value = 10.0,
        .max_value = 15.0,
        .p95_value = 14.5,
        .p99_value = 14.9,
    });

    var series = TemporalIndex.DownsampledSeries{
        .entity_namespace = try std.testing.allocator.dupe(u8, "test"),
        .entity_local_id = try std.testing.allocator.dupe(u8, "entity1"),
        .attribute_key = try std.testing.allocator.dupe(u8, "metric"),
        .original_granularity = 1,
        .downsampled_granularity = 100,
        .points = points,
        .aggregation_method = .mean,
    };

    series.deinit(std.testing.allocator);
}

// ==================== TDigest Algorithm for Percentiles ====================

/// TDigest: A data structure for approximate quantile computation
///
/// Simple implementation using sorted sampling for time-series aggregation.
/// Stores samples up to a max size, then uses reservoir sampling.
pub const TDigest = struct {
    allocator: std.mem.Allocator,
    /// Maximum samples to store (compression parameter)
    max_samples: usize,
    /// Samples stored in sorted order
    samples: ArrayListManaged(f64),
    /// Total number of values added
    total_count: u64,
    /// Minimum value seen
    min_value: f64,
    /// Maximum value seen
    max_value: f64,

    /// Create new TDigest with specified max samples
    pub fn init(allocator: std.mem.Allocator, compression: f64) TDigest {
        const max_samples = @as(usize, @intFromFloat(compression * 10));
        return TDigest{
            .allocator = allocator,
            .max_samples = max_samples,
            .samples = .{},
            .total_count = 0,
            .min_value = std.math.floatMax(f64),
            .max_value = std.math.floatMin(f64),
        };
    }

    /// Free resources
    pub fn deinit(self: *TDigest) void {
        self.samples.deinit(self.allocator);
    }

    /// Add a value to the digest
    pub fn add(self: *TDigest, value: f64) !void {
        if (self.total_count == 0) {
            self.min_value = value;
            self.max_value = value;
        } else {
            if (value < self.min_value) self.min_value = value;
            if (value > self.max_value) self.max_value = value;
        }

        self.total_count += 1;

        // If under capacity, just add and sort
        if (self.samples.items.len < self.max_samples) {
            try self.samples.append(self.allocator, value);
            // Insert in sorted position
            const idx = self.samples.items.len - 1;
            var i = idx;
            while (i > 0 and self.samples.items[i - 1] > value) : (i -= 1) {
                self.samples.items[i] = self.samples.items[i - 1];
            }
            self.samples.items[i] = value;
        } else {
            // Reservoir sampling: replace random sample
            var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(self.total_count)));
            const idx = prng.random().uintAtMost(usize, self.total_count - 1);
            if (idx < self.max_samples) {
                self.samples.items[idx] = value;
                // Re-sort after replacement
                std.mem.sort(f64, self.samples.items, {}, comptime std.sort.asc(f64));
            }
        }
    }

    /// Query percentile (0.0 to 1.0)
    pub fn quantile(self: *const TDigest, q: f64) f64 {
        if (self.total_count == 0) return 0.0;
        if (self.samples.items.len == 0) return 0.0;
        if (self.samples.items.len == 1) return self.samples.items[0];
        if (q <= 0.0) return self.min_value;
        if (q >= 1.0) return self.max_value;

        // Linear interpolation
        const idx_float = q * @as(f64, @floatFromInt(self.samples.items.len - 1));
        const idx = @as(usize, @intFromFloat(idx_float));
        const frac = idx_float - @as(f64, @floatFromInt(idx));

        if (idx >= self.samples.items.len - 1) {
            return self.samples.items[self.samples.items.len - 1];
        }

        const lower = self.samples.items[idx];
        const upper = self.samples.items[idx + 1];
        return lower + frac * (upper - lower);
    }

    /// Merge another TDigest into this one
    pub fn merge(self: *TDigest, other: *const TDigest) !void {
        if (other.total_count == 0) return;

        // Combine samples
        const combined_capacity = @min(self.max_samples, self.samples.items.len + other.samples.items.len);
        var combined = ArrayListManaged(f64).init(self.allocator);
        errdefer combined.deinit(self.allocator);

        try combined.ensureTotalCapacity(self.allocator, combined_capacity);

        // Add samples from both
        for (self.samples.items) |s| try combined.append(self.allocator, s);
        for (other.samples.items) |s| try combined.append(self.allocator, s);

        // Sort and truncate if needed
        std.mem.sort(f64, combined.items, {}, comptime std.sort.asc(f64));
        if (combined.items.len > self.max_samples) {
            // Just keep first max_samples for simplicity
            var result = ArrayListManaged(f64).init(self.allocator);
            try result.appendSlice(self.allocator, combined.items[0..self.max_samples]);
            combined.deinit(self.allocator);
            combined = result;
        }

        self.samples.deinit(self.allocator);
        self.samples = combined;
        self.total_count += other.total_count;
        if (other.min_value < self.min_value) self.min_value = other.min_value;
        if (other.max_value > self.max_value) self.max_value = other.max_value;
    }
};

test "TDigest.basicOperations" {
    var digest = TDigest.init(std.testing.allocator, 10.0);
    defer digest.deinit();

    // Add sequential values
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try digest.add(@as(f64, @floatFromInt(i)));
    }

    // Test median (should be close to 50)
    const median = digest.quantile(0.5);
    try std.testing.expect(median > 40.0 and median < 60.0);

    // Test p95 (should be close to 95)
    const p95 = digest.quantile(0.95);
    try std.testing.expect(p95 > 85.0 and p95 < 100.0);

    // Test p99 (should be close to 99)
    const p99 = digest.quantile(0.99);
    try std.testing.expect(p99 > 90.0 and p99 <= 100.0);
}

test "TDigest.percentileAccuracy" {
    var digest = TDigest.init(std.testing.allocator, 100.0);
    defer digest.deinit();

    // Add values from normal distribution
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const value = rand.floatNorm(f64);
        try digest.add(value);
    }

    // For normal distribution:
    // p50 should be near 0
    // p95 should be positive

    const p50 = digest.quantile(0.5);
    try std.testing.expect(@abs(p50) < 1.0);

    const p95 = digest.quantile(0.95);
    try std.testing.expect(p95 > 0.5);
}

test "TDigest.extremeValues" {
    var digest = TDigest.init(std.testing.allocator, 10.0);
    defer digest.deinit();

    try digest.add(1.0);
    try digest.add(2.0);
    try digest.add(3.0);

    // min_value should be 1.0, max_value should be 3.0
    try std.testing.expectEqual(@as(f64, 1.0), digest.min_value);
    try std.testing.expectEqual(@as(f64, 3.0), digest.max_value);

    // q=0.0 should return min_value
    try std.testing.expectEqual(@as(f64, 1.0), digest.quantile(0.0));
    // q=1.0 should return max_value
    try std.testing.expectEqual(@as(f64, 3.0), digest.quantile(1.0));
}

test "TemporalIndex.createRollup" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add numeric changes
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = null, .new_value = "10.0", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "10.0", .new_value = "20.0", .metadata = "{}" },
        .{ .id = "c3", .txn_id = 102, .timestamp = .{ .base = @intCast(ts), .delta = -100 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "20.0", .new_value = "15.0", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    // Create a rollup
    try index.createRollup("test", "entity1", "value", ts - 400, ts, 60, .mean);

    // Query the rollup
    const rollups = try index.queryRollups("test", "entity1", "value", ts - 500, ts, 60);
    defer std.testing.allocator.free(rollups);

    try std.testing.expect(rollups.len > 0);
    try std.testing.expectEqual(@as(u64, 3), rollups[0].count);
}

test "TemporalIndex.invalidateRollups" {
    var index = TemporalIndex.init(std.testing.allocator);
    defer index.deinit();

    const ts = std.time.timestamp();

    // Add numeric changes
    const changes = [_]StateChange{
        .{ .id = "c1", .txn_id = 100, .timestamp = .{ .base = @intCast(ts), .delta = -300 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = null, .new_value = "10.0", .metadata = "{}" },
        .{ .id = "c2", .txn_id = 101, .timestamp = .{ .base = @intCast(ts), .delta = -200 }, .entity_namespace = "test", .entity_local_id = "entity1", .change_type = .attribute_update, .key = "value", .old_value = "10.0", .new_value = "20.0", .metadata = "{}" },
    };

    for (changes) |c| try index.addChange(c);

    // Create a rollup
    try index.createRollup("test", "entity1", "value", ts - 400, ts, 60, .mean);

    // Simulate late-arriving data
    try index.invalidateRollups("test", "entity1", "value", ts - 350);

    // Query should return no valid rollups (all invalidated)
    const rollups = try index.queryRollups("test", "entity1", "value", ts - 500, ts, 60);
    defer std.testing.allocator.free(rollups);

    try std.testing.expectEqual(rollups.len, 0);
}

// ==================== Delta Computation Tests ====================

test "jsonValuesEqual identical primitives" {
    try std.testing.expect(jsonValuesEqual(
        std.json.Value{ .integer = 42 },
        std.json.Value{ .integer = 42 },
    ));

    try std.testing.expect(jsonValuesEqual(
        std.json.Value{ .string = "hello" },
        std.json.Value{ .string = "hello" },
    ));

    try std.testing.expect(jsonValuesEqual(
        std.json.Value{ .bool = true },
        std.json.Value{ .bool = true },
    ));

    try std.testing.expect(jsonValuesEqual(
        std.json.Value.null,
        std.json.Value.null,
    ));
}

test "jsonValuesEqual different primitives" {
    try std.testing.expect(!jsonValuesEqual(
        std.json.Value{ .integer = 42 },
        std.json.Value{ .integer = 43 },
    ));

    try std.testing.expect(!jsonValuesEqual(
        std.json.Value{ .string = "hello" },
        std.json.Value{ .string = "world" },
    ));

    try std.testing.expect(!jsonValuesEqual(
        std.json.Value{ .integer = 42 },
        std.json.Value{ .string = "42" },
    ));
}

test "jsonValuesEqual arrays" {
    const allocator = std.testing.allocator;

    const arr1 = try std.json.parseFromSlice(std.json.Value, allocator, "[1,2,3]", .{});
    defer arr1.deinit();

    const arr2 = try std.json.parseFromSlice(std.json.Value, allocator, "[1,2,3]", .{});
    defer arr2.deinit();

    const arr3 = try std.json.parseFromSlice(std.json.Value, allocator, "[1,2,4]", .{});
    defer arr3.deinit();

    try std.testing.expect(jsonValuesEqual(arr1.value, arr2.value));
    try std.testing.expect(!jsonValuesEqual(arr1.value, arr3.value));
}

test "jsonValuesEqual objects" {
    const allocator = std.testing.allocator;

    const obj1 = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":2}", .{});
    defer obj1.deinit();

    const obj2 = try std.json.parseFromSlice(std.json.Value, allocator, "{\"b\":2,\"a\":1}", .{});
    defer obj2.deinit();

    const obj3 = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":3}", .{});
    defer obj3.deinit();

    try std.testing.expect(jsonValuesEqual(obj1.value, obj2.value));
    try std.testing.expect(!jsonValuesEqual(obj1.value, obj3.value));
}

test "computeFieldDelta no changes" {
    const allocator = std.testing.allocator;

    const prev = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":2}", .{});
    defer prev.deinit();

    const new = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":2}", .{});
    defer new.deinit();

    var result = try computeFieldDelta(allocator, prev.value, new.value);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.changed_fields.items.len);
}

test "computeFieldDelta single field change" {
    const allocator = std.testing.allocator;

    const prev = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":2}", .{});
    defer prev.deinit();

    const new = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":3}", .{});
    defer new.deinit();

    var result = try computeFieldDelta(allocator, prev.value, new.value);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.changed_fields.items.len);
    try std.testing.expectEqualStrings("b", result.changed_fields.items[0]);
}

test "computeFieldDelta multiple field changes" {
    const allocator = std.testing.allocator;

    const prev = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":2,\"c\":3}", .{});
    defer prev.deinit();

    const new = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":10,\"b\":20,\"c\":3}", .{});
    defer new.deinit();

    var result = try computeFieldDelta(allocator, prev.value, new.value);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.changed_fields.items.len);

    // Sort for consistent comparison
    std.mem.sort([]const u8, result.changed_fields.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("a", result.changed_fields.items[0]);
    try std.testing.expectEqualStrings("b", result.changed_fields.items[1]);
}

test "computeFieldDelta new field" {
    const allocator = std.testing.allocator;

    const prev = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":2}", .{});
    defer prev.deinit();

    const new = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1,\"b\":2,\"c\":3}", .{});
    defer new.deinit();

    var result = try computeFieldDelta(allocator, prev.value, new.value);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.changed_fields.items.len);
    try std.testing.expectEqualStrings("c", result.changed_fields.items[0]);
}

test "computeFieldDelta nested objects" {
    const allocator = std.testing.allocator;

    const prev = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":{\"x\":1},\"b\":2}", .{});
    defer prev.deinit();

    const new = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":{\"x\":2},\"b\":2}", .{});
    defer new.deinit();

    var result = try computeFieldDelta(allocator, prev.value, new.value);
    defer result.deinit(allocator);

    // The entire "a" field should be marked as changed
    try std.testing.expectEqual(@as(usize, 1), result.changed_fields.items.len);
    try std.testing.expectEqualStrings("a", result.changed_fields.items[0]);
}
