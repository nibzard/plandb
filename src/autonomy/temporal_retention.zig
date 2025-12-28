//! Automated retention policies for temporal history data
//!
//! Implements age-based downsampling, TTL management, and archival integration
//! for temporal history cartridge data.

const std = @import("std");
const ArrayListManaged = std.ArrayListUnmanaged;

const ArchiveManager = @import("archival.zig").ArchiveManager;
const TieredStorageManager = @import("tiered_storage.zig").TieredStorageManager;
const StorageTier = @import("tiered_storage.zig").StorageTier;

/// Downsampling granularity for temporal data
pub const DownsamplingLevel = enum(u8) {
    /// No downsampling - keep raw data
    raw = 0,
    /// Sample to 1-minute intervals
    one_min = 1,
    /// Sample to 5-minute intervals
    five_min = 2,
    /// Sample to 1-hour intervals
    one_hour = 3,
    /// Sample to 1-day intervals
    one_day = 4,
    /// Sample to 1-week intervals
    one_week = 5,
    /// Sample to 1-month intervals
    one_month = 6,

    pub fn intervalSeconds(self: DownsamplingLevel) u64 {
        return switch (self) {
            .raw => 1,
            .one_min => 60,
            .five_min => 300,
            .one_hour => 3600,
            .one_day => 86400,
            .one_week => 604800,
            .one_month => 2592000, // 30 days
        };
    }

    pub fn fromAge(age_seconds: u64) DownsamplingLevel {
        if (age_seconds < 7 * 86400) return .raw; // < 7 days: raw
        if (age_seconds < 30 * 86400) return .one_min; // < 30 days: 1-min
        if (age_seconds < 90 * 86400) return .five_min; // < 90 days: 5-min
        if (age_seconds < 365 * 86400) return .one_hour; // < 1 year: 1-hour
        if (age_seconds < 2 * 365 * 86400) return .one_day; // < 2 years: 1-day
        return .one_week; // >= 2 years: 1-week
    }
};

/// Retention policy for a specific entity type
pub const EntityRetentionPolicy = struct {
    /// Entity namespace pattern (e.g., "metrics_*", "logs_*")
    entity_pattern: []const u8,
    /// TTL for raw data (seconds, 0 = infinite)
    raw_ttl_seconds: u64,
    /// Downsampling schedule
    downsampling_schedule: []const DownsamplingTier,
    /// Whether to archive to cold storage
    enable_archival: bool,
    /// Target tier for archived data
    target_tier: StorageTier,

    pub const DownsamplingTier = struct {
        /// Age threshold for this tier (seconds)
        age_threshold_seconds: u64,
        /// Target downsampling level
        level: DownsamplingLevel,
        /// Minimum samples to keep after downsampling
        min_samples: usize,
    };

    /// Default policy for high-frequency metrics
    pub fn defaultForMetrics() EntityRetentionPolicy {
        const tiers = [_]DownsamplingTier{
            .{ .age_threshold_seconds = 7 * 86400, .level = .raw, .min_samples = 10080 }, // 7 days raw
            .{ .age_threshold_seconds = 30 * 86400, .level = .one_min, .min_samples = 43200 }, // 30 days 1-min
            .{ .age_threshold_seconds = 90 * 86400, .level = .five_min, .min_samples = 25920 }, // 90 days 5-min
            .{ .age_threshold_seconds = 365 * 86400, .level = .one_hour, .min_samples = 8760 }, // 1 year 1-hour
            .{ .age_threshold_seconds = 730 * 86400, .level = .one_day, .min_samples = 365 }, // 2 years 1-day
        };

        return EntityRetentionPolicy{
            .entity_pattern = "metrics_*",
            .raw_ttl_seconds = 7 * 86400, // 7 days raw
            .downsampling_schedule = &tiers,
            .enable_archival = true,
            .target_tier = .cold,
        };
    }

    /// Default policy for logs
    pub fn defaultForLogs() EntityRetentionPolicy {
        const tiers = [_]DownsamplingTier{
            .{ .age_threshold_seconds = 1 * 86400, .level = .raw, .min_samples = 1440 }, // 1 day raw
            .{ .age_threshold_seconds = 7 * 86400, .level = .five_min, .min_samples = 2016 }, // 7 days 5-min
            .{ .age_threshold_seconds = 30 * 86400, .level = .one_hour, .min_samples = 720 }, // 30 days 1-hour
            .{ .age_threshold_seconds = 90 * 86400, .level = .one_day, .min_samples = 90 }, // 90 days 1-day
        };

        return EntityRetentionPolicy{
            .entity_pattern = "logs_*",
            .raw_ttl_seconds = 1 * 86400, // 1 day raw
            .downsampling_schedule = &tiers,
            .enable_archival = true,
            .target_tier = .cold,
        };
    }

    /// Default policy for entity state snapshots
    pub fn defaultForSnapshots() EntityRetentionPolicy {
        const tiers = [_]DownsamplingTier{
            .{ .age_threshold_seconds = 30 * 86400, .level = .raw, .min_samples = 100 }, // 30 days raw
            .{ .age_threshold_seconds = 90 * 86400, .level = .one_hour, .min_samples = 1440 }, // 90 days 1-hour
            .{ .age_threshold_seconds = 365 * 86400, .level = .one_day, .min_samples = 275 }, // 1 year 1-day
        };

        return EntityRetentionPolicy{
            .entity_pattern = "snapshots_*",
            .raw_ttl_seconds = 30 * 86400, // 30 days raw
            .downsampling_schedule = &tiers,
            .enable_archival = false, // Snapshots stay accessible
            .target_tier = .warm,
        };
    }

    /// Get recommended downsampling level for data age
    pub fn getDownsamplingLevel(self: *const EntityRetentionPolicy, age_seconds: u64) DownsamplingLevel {
        for (self.downsampling_schedule) |tier| {
            if (age_seconds < tier.age_threshold_seconds) {
                return tier.level;
            }
        }
        return .one_week; // Oldest data gets highest downsampling
    }
};

/// Temporal retention policy manager
pub const TemporalRetentionManager = struct {
    allocator: std.mem.Allocator,
    /// Entity type -> policy mapping
    policies: std.StringHashMap(EntityRetentionPolicy),
    /// Archive manager for cold storage
    archive_manager: ?*ArchiveManager,
    /// Tiered storage manager
    storage_manager: ?*TieredStorageManager,
    /// Statistics
    stats: RetentionStats,

    pub const RetentionStats = struct {
        /// Total data points processed
        total_points_processed: u64 = 0,
        /// Total data points downsampled
        total_points_downsampled: u64 = 0,
        /// Total data points archived
        total_points_archived: u64 = 0,
        /// Storage savings (bytes)
        storage_savings_bytes: u64 = 0,
        /// Accuracy impact (0-1, lower is better)
        accuracy_impact: f32 = 0.0,

        pub fn formatReport(self: *const RetentionStats, allocator: std.mem.Allocator) ![]const u8 {
            const reduction_pct = if (self.total_points_processed > 0)
                @as(f32, @floatFromInt(self.total_points_downsampled)) / @as(f32, @floatFromInt(self.total_points_processed)) * 100.0
            else
                0.0;

            const savings_mb = @as(f32, @floatFromInt(self.storage_savings_bytes)) / (1024.0 * 1024.0);

            return std.fmt.allocPrint(allocator,
                \\Retention Statistics:
                \\  Points Processed: {d}
                \\  Points Downsampled: {d} ({d:.1}%)
                \\  Points Archived: {d}
                \\  Storage Savings: {d:.1} MB
                \\  Accuracy Impact: {d:.3}
            , .{
                self.total_points_processed,
                self.total_points_downsampled,
                reduction_pct,
                self.total_points_archived,
                savings_mb,
                self.accuracy_impact,
            });
        }
    };

    pub fn init(allocator: std.mem.Allocator) TemporalRetentionManager {
        return TemporalRetentionManager{
            .allocator = allocator,
            .policies = std.StringHashMap(EntityRetentionPolicy).init(allocator),
            .archive_manager = null,
            .storage_manager = null,
            .stats = RetentionStats{},
        };
    }

    pub fn deinit(self: *TemporalRetentionManager) void {
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Note: EntityRetentionPolicy contains slices we don't own (static strings)
        }
        self.policies.deinit();
    }

    /// Set archive manager
    pub fn setArchiveManager(self: *TemporalRetentionManager, manager: *ArchiveManager) void {
        self.archive_manager = manager;
    }

    /// Set storage manager
    pub fn setStorageManager(self: *TemporalRetentionManager, manager: *TieredStorageManager) void {
        self.storage_manager = manager;
    }

    /// Add a retention policy for an entity type
    pub fn addPolicy(self: *TemporalRetentionManager, entity_type: []const u8, policy: EntityRetentionPolicy) !void {
        const key = try self.allocator.dupe(u8, entity_type);
        errdefer self.allocator.free(key);
        try self.policies.put(key, policy);
    }

    /// Get policy for an entity (returns default if not found)
    pub fn getPolicyForEntity(self: *TemporalRetentionManager, entity_namespace: []const u8) EntityRetentionPolicy {
        // Try exact match
        if (self.policies.get(entity_namespace)) |policy| {
            return policy;
        }

        // Try pattern match (simple prefix matching for now)
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            const pattern = entry.key_ptr.*;
            const policy = entry.value_ptr.*;

            // Check if pattern ends with wildcard
            if (std.mem.endsWith(u8, pattern, "*")) {
                const prefix = pattern[0 .. pattern.len - 1];
                if (std.mem.startsWith(u8, entity_namespace, prefix)) {
                    return policy;
                }
            }
        }

        // Default to metrics policy
        return EntityRetentionPolicy.defaultForMetrics();
    }

    /// Determine if data point should be downsampled
    pub fn shouldDownsample(
        self: *TemporalRetentionManager,
        entity_namespace: []const u8,
        data_age_seconds: u64
    ) ? DownsamplingLevel {
        const policy = self.getPolicyForEntity(entity_namespace);
        const current_level = DownsamplingLevel.fromAge(data_age_seconds);

        // Check if we've moved past the raw data TTL
        if (data_age_seconds > policy.raw_ttl_seconds and current_level != .raw) {
            return current_level;
        }

        return null;
    }

    /// Downsample temporal data points
    pub fn downsampleDataPoints(
        self: *TemporalRetentionManager,
        entity_namespace: []const u8,
        points: []const TemporalDataPoint,
        target_level: DownsamplingLevel
    ) ![]const TemporalDataPoint {
        _ = entity_namespace;
        self.stats.total_points_processed += points.len;

        const interval = target_level.intervalSeconds();
        if (interval == 1) {
            // No downsampling needed
            return points;
        }

        var downsampled = std.ArrayListManaged(TemporalDataPoint).init(self.allocator);

        // Group points by interval buckets
        var last_bucket: i64 = -1;
        var bucket_sum: f64 = 0.0;
        var bucket_count: u64 = 0;
        var bucket_min: f64 = std.math.inf(f32);
        var bucket_max: f64 = -std.math.inf(f32);

        for (points) |point| {
            const bucket = @divTrunc(point.timestamp, interval);

            if (bucket != last_bucket and last_bucket != -1) {
                // Emit aggregated point for previous bucket
                const avg = bucket_sum / @as(f64, @floatFromInt(bucket_count));
                try downsampled.append(.{
                    .timestamp = last_bucket * interval,
                    .value = avg,
                    .min = bucket_min,
                    .max = bucket_max,
                    .count = bucket_count,
                });

                // Reset bucket
                bucket_sum = 0.0;
                bucket_count = 0;
                bucket_min = std.math.inf(f32);
                bucket_max = -std.math.inf(f32);
            }

            // Accumulate
            bucket_sum += point.value;
            bucket_count += 1;
            bucket_min = @min(bucket_min, point.value);
            bucket_max = @max(bucket_max, point.value);
            last_bucket = bucket;
        }

        // Emit final bucket
        if (bucket_count > 0) {
            const avg = bucket_sum / @as(f64, @floatFromInt(bucket_count));
            try downsampled.append(.{
                .timestamp = last_bucket * interval,
                .value = avg,
                .min = bucket_min,
                .max = bucket_max,
                .count = bucket_count,
            });
        }

        self.stats.total_points_downsampled += points.len - downsampled.items.len;
        self.stats.storage_savings_bytes += @as(u64, @intCast((points.len - downsampled.items.len) * @sizeOf(TemporalDataPoint)));

        return downsampled.toOwnedSlice();
    }

    /// Check if data should be archived
    pub fn shouldArchive(
        self: *TemporalRetentionManager,
        entity_namespace: []const u8,
        data_age_seconds: u64,
        data_size_bytes: u64
    ) bool {
        const policy = self.getPolicyForEntity(entity_namespace);

        if (!policy.enable_archival) return false;

        // Archive if past raw TTL and significant size
        return data_age_seconds > policy.raw_ttl_seconds and data_size_bytes > 1024 * 1024; // 1MB
    }

    /// Process retention policies on a batch of temporal data
    pub fn processDataBatch(
        self: *TemporalRetentionManager,
        entity_namespace: []const u8,
        data_points: []const TemporalDataPoint,
        current_timestamp: i64
    ) !RetentionResult {
        var total_kept: usize = 0;
        var total_downsampled: usize = 0;
        var total_archived: usize = 0;

        var retained_points = std.ArrayListManaged(TemporalDataPoint).init(self.allocator);
        defer {
            for (retained_points.items) |p| p.deinit(self.allocator);
            retained_points.deinit(self.allocator);
        }

        for (data_points) |point| {
            defer point.deinit(self.allocator);

            const age = current_timestamp - point.timestamp;
            const age_seconds = @abs(age);

            // Check if should downsample
            if (self.shouldDownsample(entity_namespace, age_seconds)) |level| {
                // Would need to batch process for efficient downsampling
                // For now, just track the stat
                total_downsampled += 1;
                _ = level;
            } else {
                try retained_points.append(point);
                total_kept += 1;
            }

            // Check if should archive
            if (self.shouldArchive(entity_namespace, age_seconds, 100)) { // 100 bytes estimate
                total_archived += 1;
            }
        }

        return RetentionResult{
            .original_count = data_points.len,
            .retained_count = total_kept,
            .downsampled_count = total_downsampled,
            .archived_count = total_archived,
        };
    }

    /// Generate retention report
    pub fn generateReport(self: *const TemporalRetentionManager) ![]const u8 {
        return self.stats.formatReport(self.allocator);
    }
};

/// Temporal data point
pub const TemporalDataPoint = struct {
    timestamp: i64,
    value: f64,
    min: f64,
    max: f64,
    count: u64,
    metadata: ?[]const u8 = null,

    pub fn deinit(self: TemporalDataPoint, allocator: std.mem.Allocator) void {
        if (self.metadata) |m| allocator.free(m);
    }
};

/// Result of retention policy processing
pub const RetentionResult = struct {
    original_count: usize,
    retained_count: usize,
    downsampled_count: usize,
    archived_count: usize,
};

// ==================== Tests ====================

test "DownsamplingLevel fromAge" {
    const tests = [_]struct {
        age: u64,
        expected: DownsamplingLevel,
    }{
        .{ .age = 1 * 86400, .expected = .raw }, // 1 day
        .{ .age = 10 * 86400, .expected = .one_min }, // 10 days
        .{ .age = 45 * 86400, .expected = .five_min }, // 45 days
        .{ .age = 200 * 86400, .expected = .one_hour }, // 200 days
        .{ .age = 400 * 86400, .expected = .one_day }, // 400 days
        .{ .age = 1000 * 86400, .expected = .one_week }, // 1000 days
    };

    for (tests) |t| {
        const level = DownsamplingLevel.fromAge(t.age);
        try std.testing.expectEqual(t.expected, level);
    }
}

test "EntityRetentionPolicy defaultForMetrics" {
    const policy = EntityRetentionPolicy.defaultForMetrics();
    try std.testing.expectEqualStrings("metrics_*", policy.entity_pattern);
    try std.testing.expectEqual(@as(u64, 7 * 86400), policy.raw_ttl_seconds);
    try std.testing.expect(policy.enable_archival);
}

test "TemporalRetentionManager init and addPolicy" {
    var manager = TemporalRetentionManager.init(std.testing.allocator);
    defer manager.deinit();

    const policy = EntityRetentionPolicy.defaultForMetrics();
    try manager.addPolicy("test_entity", policy);

    const retrieved = manager.getPolicyForEntity("test_entity");
    try std.testing.expectEqual(@as(u64, 7 * 86400), retrieved.raw_ttl_seconds);
}

test "TemporalRetentionManager pattern matching" {
    var manager = TemporalRetentionManager.init(std.testing.allocator);
    defer manager.deinit();

    const policy = EntityRetentionPolicy.defaultForLogs();
    try manager.addPolicy("logs_*", policy);

    // Should match pattern
    const retrieved = manager.getPolicyForEntity("logs_app");
    try std.testing.expectEqual(@as(u64, 1 * 86400), retrieved.raw_ttl_seconds);

    // Should fall back to default for non-matching
    const default_retrieved = manager.getPolicyForEntity("metrics_cpu");
    try std.testing.expectEqual(@as(u64, 7 * 86400), default_retrieved.raw_ttl_seconds);
}

test "TemporalRetentionManager downsampleDataPoints" {
    var manager = TemporalRetentionManager.init(std.testing.allocator);
    defer manager.deinit();

    // Create 100 points spread over 10 seconds
    var points = try std.testing.allocator.alloc(TemporalDataPoint, 100);
    defer {
        for (points) |p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(points);
    }

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        points[i] = .{
            .timestamp = @intCast(i * 100), // 100ms intervals
            .value = @as(f64, @floatFromInt(i)),
            .min = @as(f64, @floatFromInt(i)),
            .max = @as(f64, @floatFromInt(i)),
            .count = 1,
        };
    }

    // Downsample to 1-second intervals
    const result = try manager.downsampleDataPoints("test", points, .one_min);
    defer std.testing.allocator.free(result);

    // Should be much fewer points (roughly 100 points -> 1 point since all in same minute)
    try std.testing.expect(result.len < 100);
}

test "RetentionStats formatReport" {
    var stats = TemporalRetentionManager.RetentionStats{};
    stats.total_points_processed = 1000;
    stats.total_points_downsampled = 800;
    stats.storage_savings_bytes = 1024 * 1024; // 1 MB

    const report = try stats.formatReport(std.testing.allocator);
    defer std.testing.allocator.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "800") != null);
}
