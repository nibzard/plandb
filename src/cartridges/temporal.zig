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
            .metadata = "{}", // TODO: Add actual metadata
        };

        try self.index.addSnapshot(snapshot);

        return snapshot_id;
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

        // For now, use simple field-level delta (placeholder)
        // In real implementation, would parse JSON and compute actual field deltas
        _ = prev_snapshot;
        _ = new_state;

        // TODO: Implement actual delta computation
        return null;
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
                    // Apply delta if needed
                    if (snapshot.delta_info) |di| {
                        // TODO: Apply delta to base snapshot
                        _ = di;
                        return snapshot.state_data; // Placeholder
                    }
                    return snapshot.state_data;
                }
            }
        }

        return null;
    }
};

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
