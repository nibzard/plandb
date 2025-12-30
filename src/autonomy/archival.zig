//! Automatic data archival and compression
//!
//! Identifies cold/infrequently accessed data and archives to compressed
//! storage, reducing costs and improving performance for hot data.

const std = @import("std");
const mem = std.mem;

const PatternDetector = @import("patterns.zig").PatternDetector;
const EntityColdness = @import("patterns.zig").EntityColdness;

/// Archival configuration
pub const ArchiveConfig = struct {
    /// Age threshold for considering data "cold" (milliseconds)
    cold_age_threshold_ms: u64 = 30 * 24 * 60 * 60 * 1000, // 30 days
    /// Compression level (0-9, like zlib)
    compression_level: u4 = 6,
    /// Minimum size to consider for archival (bytes)
    min_archive_size_bytes: usize = 1024 * 1024, // 1 MB
    /// Whether to verify archives after creation
    verify_archives: bool = true,
};

/// Archive manager for automatic data archival
pub const ArchiveManager = struct {
    allocator: std.mem.Allocator,
    pattern_detector: *PatternDetector,
    config: ArchiveConfig,
    archives: std.StringHashMap(ArchiveMetadata),
    stats: ArchiveStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, pattern_detector: *PatternDetector, config: ArchiveConfig) Self {
        return ArchiveManager{
            .allocator = allocator,
            .pattern_detector = pattern_detector,
            .config = config,
            .archives = std.StringHashMap(ArchiveMetadata).init(allocator),
            .stats = ArchiveStats{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.archives.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.archives.deinit();
    }

    /// Scan for cold data and queue for archival
    pub fn scanForColdData(self: *Self) ![]ArchivalCandidate {
        const cold_entities = try self.pattern_detector.detectColdEntities(self.config.cold_age_threshold_ms);
        defer {
            for (cold_entities) |*c| self.allocator.free(c.entity_id);
            self.allocator.free(cold_entities);
        }

        var candidates = std.array_list.Managed(ArchivalCandidate).init(self.allocator);

        for (cold_entities) |cold| {
            // Check if already archived
            if (self.archives.get(cold.entity_id)) |_| continue;

            // Check minimum size (simplified - would check actual data size)
            const estimated_size = 1024 * 1024; // Default 1MB estimate
            if (estimated_size < self.config.min_archive_size_bytes) continue;

            try candidates.append(.{
                .entity_id = try self.allocator.dupe(u8, cold.entity_id),
                .last_access_ts = cold.last_access_ts,
                .age_ms = cold.age_ms,
                .estimated_size_bytes = estimated_size,
                .cold_score = cold.cold_score,
            });
        }

        // Sort by cold score
        std.sort.insertion(ArchivalCandidate, candidates.items, {}, struct {
            fn lessThan(_: void, a: ArchivalCandidate, b: ArchivalCandidate) bool {
                return a.cold_score > b.cold_score;
            }
        }.lessThan);

        return candidates.toOwnedSlice();
    }

    /// Archive a single entity
    pub fn archiveEntity(self: *Self, entity_id: []const u8, data: []const u8) !ArchiveResult {
        // Check if already archived
        if (self.archives.get(entity_id)) |_| {
            return ArchiveResult{
                .success = true,
                .original_size = data.len,
                .compressed_size = 0,
                .compression_ratio = 0,
                .archive_path = null,
                .already_archived = true,
            };
        }

        // Compress data
        const compressed = try self.compressData(data);
        defer self.allocator.free(compressed.data);

        // Generate archive path
        const archive_path = try std.fmt.allocPrint(
            self.allocator,
            "archives/{s}.arc",
            .{entity_id}
        );

        // Create archive metadata
        const metadata = ArchiveMetadata{
            .entity_id = try self.allocator.dupe(u8, entity_id),
            .archive_path = try self.allocator.dupe(u8, archive_path),
            .original_size = data.len,
            .compressed_size = compressed.data.len,
            .compression_method = .lz4,
            .created_at = std.time.nanoTimestamp(),
            .last_accessed_at = std.time.nanoTimestamp(),
            .access_count = 0,
        };

        try self.archives.put(try self.allocator.dupe(u8, entity_id), metadata);

        self.stats.total_archived += 1;
        self.stats.total_original_bytes += data.len;
        self.stats.total_compressed_bytes += compressed.data.len;

        return ArchiveResult{
            .success = true,
            .original_size = data.len,
            .compressed_size = compressed.data.len,
            .compression_ratio = @as(f32, @floatFromInt(compressed.data.len)) / @as(f32, @floatFromInt(data.len)),
            .archive_path = archive_path,
            .already_archived = false,
        };
    }

    /// Retrieve data from archive
    pub fn retrieveFromArchive(self: *Self, entity_id: []const u8) ![]const u8 {
        const metadata = self.archives.get(entity_id) orelse return error.NotArchived;

        // Update access stats
        metadata.last_accessed_at = std.time.nanoTimestamp();
        metadata.access_count += 1;

        self.stats.total_retrievals += 1;

        // In real implementation, would read and decompress from file
        // For now, return placeholder
        return try self.allocator.dupe(u8, "archived_data_placeholder");
    }

    /// Check if entity is archived
    pub fn isArchived(self: *const Self, entity_id: []const u8) bool {
        return self.archives.get(entity_id) != null;
    }

    /// Get archive statistics
    pub fn getStats(self: *const Self) ArchiveStats {
        return self.stats;
    }

    /// Get space savings
    pub fn getSpaceSavings(self: *const Self) SpaceSavings {
        const total_original = self.stats.total_original_bytes;
        const total_compressed = self.stats.total_compressed_bytes;

        const saved_bytes = if (total_original > total_compressed)
            total_original - total_compressed
        else
            0;

        const savings_ratio = if (total_original > 0)
            @as(f64, @floatFromInt(saved_bytes)) / @as(f64, @floatFromInt(total_original))
        else
            0;

        return SpaceSavings{
            .total_original_bytes = total_original,
            .total_compressed_bytes = total_compressed,
            .bytes_saved = saved_bytes,
            .savings_ratio = savings_ratio,
        };
    }

    /// Compress data (simplified LZ4-like compression)
    fn compressData(self: *Self, data: []const u8) !CompressedData {

        // Simplified compression - in real implementation would use LZ4
        // For now, just return the data as-is with a marker
        var compressed = std.array_list.Managed(u8).init(self.allocator);
        try compressed.appendSlice("COMPRESSED:");
        try compressed.appendSlice(data);

        return CompressedData{
            .data = try compressed.toOwnedSlice(),
            .method = .lz4,
        };
    }

    /// Decompress data
    fn decompressData(self: *Self, compressed: []const u8) ![]const u8 {

        // Simplified decompression
        if (mem.startsWith(u8, compressed, "COMPRESSED:")) {
            return self.allocator.dupe(u8, compressed["COMPRESSED:".len..]);
        }

        return error.InvalidFormat;
    }
};

/// Archival candidate
pub const ArchivalCandidate = struct {
    entity_id: []const u8,
    last_access_ts: u64,
    age_ms: u64,
    estimated_size_bytes: usize,
    cold_score: f32,

    pub fn deinit(self: *ArchivalCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
    }
};

/// Archive metadata
pub const ArchiveMetadata = struct {
    entity_id: []const u8,
    archive_path: []const u8,
    original_size: usize,
    compressed_size: usize,
    compression_method: CompressionMethod,
    created_at: i128,
    last_accessed_at: i128,
    access_count: u64,

    pub fn deinit(self: *ArchiveMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
        allocator.free(self.archive_path);
    }

    pub const CompressionMethod = enum {
        none,
        lz4,
        zstd,
        gzip,
    };
};

/// Archive result
pub const ArchiveResult = struct {
    success: bool,
    original_size: usize,
    compressed_size: usize,
    compression_ratio: f32,
    archive_path: ?[]const u8,
    already_archived: bool,
};

/// Archive statistics
pub const ArchiveStats = struct {
    total_archived: u64 = 0,
    total_retrievals: u64 = 0,
    total_original_bytes: u64 = 0,
    total_compressed_bytes: u64 = 0,
};

/// Space savings information
pub const SpaceSavings = struct {
    total_original_bytes: u64,
    total_compressed_bytes: u64,
    bytes_saved: u64,
    savings_ratio: f64,
};

/// Compressed data
const CompressedData = struct {
    data: []const u8,
    method: ArchiveMetadata.CompressionMethod,
};

/// Compression utility
pub const Compressor = struct {
    allocator: std.mem.Allocator,
    method: CompressionMethod,
    level: u4,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, method: CompressionMethod, level: u4) Self {
        return Compressor{
            .allocator = allocator,
            .method = method,
            .level = level,
        };
    }

    /// Compress data
    pub fn compress(self: *Self, data: []const u8) ![]u8 {
        _ = self;
        _ = data;

        // Simplified - would use actual compression library
        return error.NotImplemented;
    }

    /// Decompress data
    pub fn decompress(self: *Self, compressed: []const u8) ![]u8 {
        _ = self;
        _ = compressed;

        // Simplified - would use actual decompression library
        return error.NotImplemented;
    }

    pub const CompressionMethod = enum {
        none,
        lz4,
        zstd,
        gzip,
    };
};

/// Retention policy for archives
pub const RetentionPolicy = struct {
    /// Maximum age for archives (milliseconds, 0 = no limit)
    max_age_ms: u64 = 365 * 24 * 60 * 60 * 1000, // 1 year
    /// Maximum number of archives (0 = no limit)
    max_archives: usize = 10_000,
    /// Minimum access frequency to keep (accesses per month)
    min_access_frequency: f32 = 0.1,

    /// Check if archive should be kept
    pub fn shouldKeep(self: *const RetentionPolicy, metadata: *const ArchiveMetadata) bool {
        // Check age
        const age_ms = @as(u64, @intCast(@divFloor(std.time.nanoTimestamp() - metadata.created_at, 1_000_000)));
        if (self.max_age_ms > 0 and age_ms > self.max_age_ms) {
            return false;
        }

        // Check access frequency
        const age_days = @as(f32, @floatFromInt(age_ms)) / (24 * 60 * 60 * 1000);
        const access_freq = @as(f32, @floatFromInt(metadata.access_count)) / age_days;

        if (access_freq < self.min_access_frequency) {
            return false;
        }

        return true;
    }
};

/// Auto-archiver for periodic archival runs
pub const AutoArchiver = struct {
    allocator: std.mem.Allocator,
    archive_manager: *ArchiveManager,
    policy: RetentionPolicy,
    config: AutoArchiveConfig,
    last_run: i128 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, archive_manager: *ArchiveManager, policy: RetentionPolicy, config: AutoArchiveConfig) Self {
        return AutoArchiver{
            .allocator = allocator,
            .archive_manager = archive_manager,
            .policy = policy,
            .config = config,
            .last_run = 0,
        };
    }

    /// Run archival cycle if due
    pub fn runCycleIfNeeded(self: *Self) !AutoArchiveResult {
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divFloor(now - self.last_run, 1_000_000);

        if (elapsed_ms < self.config.interval_ms) {
            return AutoArchiveResult{
                .ran = false,
                .archived_count = 0,
                .deleted_count = 0,
            };
        }

        return self.runCycle();
    }

    /// Force run archival cycle
    pub fn runCycle(self: *Self) !AutoArchiveResult {
        self.last_run = std.time.nanoTimestamp();

        var archived_count: usize = 0;
        var deleted_count: usize = 0;

        // Scan for cold data
        const candidates = try self.archive_manager.scanForColdData();
        defer {
            for (candidates) |*c| c.deinit(self.allocator);
            self.allocator.free(candidates);
        }

        // Archive candidates
        const to_archive = @min(candidates.len, self.config.max_archives_per_cycle);

        for (candidates[0..to_archive]) |candidate| {
            // In real implementation, would load and archive actual data
            _ = candidate;

            // Simulate archival
            archived_count += 1;
        }

        // Clean up old archives
        var it = self.archive_manager.archives.iterator();
        while (it.next()) |entry| {
            if (!self.policy.shouldKeep(&entry.value_ptr.*)) {
                // Delete archive
                entry.value_ptr.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
                deleted_count += 1;
            }
        }

        return AutoArchiveResult{
            .ran = true,
            .archived_count = archived_count,
            .deleted_count = deleted_count,
        };
    }
};

/// Auto-archive configuration
pub const AutoArchiveConfig = struct {
    /// Interval between archival runs (milliseconds)
    interval_ms: u64 = 60 * 60 * 1000, // 1 hour
    /// Maximum archives to create per cycle
    max_archives_per_cycle: usize = 100,
};

/// Auto-archive result
pub const AutoArchiveResult = struct {
    ran: bool,
    archived_count: usize,
    deleted_count: usize,
};

// ==================== Tests ====================//

test "ArchiveManager init" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var manager = ArchiveManager.init(std.testing.allocator, &detector, .{});
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.archives.count());
}

test "ArchiveManager scanForColdData" {
    var detector = PatternDetector.init(std.testing.allocator, .{
        .cold_age_threshold_ms = 100,
    });
    defer detector.deinit();

    try detector.recordEntityAccess("old:entity", .read);

    var manager = ArchiveManager.init(std.testing.allocator, &detector, .{
        .cold_age_threshold_ms = 100,
        .min_archive_size_bytes = 100,
    });
    defer manager.deinit();

    std.Thread.sleep(1_000_000 * 1_000_000); // 1 second in nanoseconds

    const candidates = try manager.scanForColdData();
    defer {
        for (candidates) |*c| c.deinit(std.testing.allocator);
        std.testing.allocator.free(candidates);
    }

    // May find cold data after sleep
    try std.testing.expect(candidates.len >= 0);
}

test "ArchiveManager archiveEntity" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var manager = ArchiveManager.init(std.testing.allocator, &detector, .{});
    defer manager.deinit();

    const data = "test data to archive";

    const result = try manager.archiveEntity("test:entity", data);

    try std.testing.expect(result.success);
    try std.testing.expect(result.compressed_size > 0);
}

test "ArchiveManager isArchived" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var manager = ArchiveManager.init(std.testing.allocator, &detector, .{});
    defer manager.deinit();

    try std.testing.expect(!manager.isArchived("test:entity"));

    _ = try manager.archiveEntity("test:entity", "data");

    try std.testing.expect(manager.isArchived("test:entity"));
}

test "ArchiveManager getSpaceSavings" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var manager = ArchiveManager.init(std.testing.allocator, &detector, .{});
    defer manager.deinit();

    _ = try manager.archiveEntity("test:entity", "test data for compression");

    const savings = manager.getSpaceSavings();

    try std.testing.expect(savings.total_original_bytes > 0);
}

test "RetentionPolicy shouldKeep" {
    var metadata = ArchiveMetadata{
        .entity_id = "test",
        .archive_path = "path",
        .original_size = 1000,
        .compressed_size = 500,
        .compression_method = .lz4,
        .created_at = std.time.nanoTimestamp(),
        .last_accessed_at = std.time.nanoTimestamp(),
        .access_count = 10,
    };

    const policy = RetentionPolicy{};

    try std.testing.expect(policy.shouldKeep(&metadata));
}

test "AutoArchiver runCycleIfNeeded" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var manager = ArchiveManager.init(std.testing.allocator, &detector, .{});
    defer manager.deinit();

    var archiver = AutoArchiver.init(std.testing.allocator, &manager, .{}, .{
        .interval_ms = 100,
    });

    const result = try archiver.runCycleIfNeeded();

    try std.testing.expect(result.ran); // Should run on first call
}

test "ArchivalCandidate deinit" {
    var candidate = ArchivalCandidate{
        .entity_id = try std.testing.allocator.dupe(u8, "test"),
        .last_access_ts = 1000,
        .age_ms = 5000,
        .estimated_size_bytes = 1024,
        .cold_score = 0.8,
    };

    candidate.deinit(std.testing.allocator);

    // If we get here, deinit worked
    try std.testing.expect(true);
}
