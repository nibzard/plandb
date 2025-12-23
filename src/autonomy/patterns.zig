//! Usage pattern detection and analysis for autonomous database operations
//!
//! Tracks query frequency, access patterns, temporal trends, and detects
//! hot/cold data patterns to enable self-optimizing behaviors.

const std = @import("std");
const mem = std.mem;

/// Pattern detection engine for autonomous operations
pub const PatternDetector = struct {
    allocator: std.mem.Allocator,
    query_patterns: std.StringHashMap(QueryPattern),
    entity_patterns: std.StringHashMap(EntityPattern),
    temporal_patterns: TemporalPatternTracker,
    config: DetectorConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: DetectorConfig) Self {
        return PatternDetector{
            .allocator = allocator,
            .query_patterns = std.StringHashMap(QueryPattern).init(allocator),
            .entity_patterns = std.StringHashMap(EntityPattern).init(allocator),
            .temporal_patterns = TemporalPatternTracker.init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.query_patterns.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.query_patterns.deinit();

        var it2 = self.entity_patterns.iterator();
        while (it2.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.entity_patterns.deinit();

        self.temporal_patterns.deinit();
    }

    /// Record a query execution
    pub fn recordQuery(self: *Self, query: []const u8, latency_ms: f64, result_count: usize) !void {
        const entry = try self.query_patterns.getOrPut(query);
        if (!entry.found_existing) {
            entry.value_ptr.* = QueryPattern.init(self.allocator, query);
        }

        try entry.value_ptr.recordAccess(latency_ms, result_count);

        // Also record in temporal tracker
        try self.temporal_patterns.recordQuery(query, latency_ms);
    }

    /// Record an entity access
    pub fn recordEntityAccess(self: *Self, entity_id: []const u8, access_type: AccessType) !void {
        const entry = try self.entity_patterns.getOrPut(entity_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = EntityPattern.init(self.allocator, entity_id);
        }

        try entry.value_ptr.recordAccess(access_type);
    }

    /// Detect hot entities (frequently accessed)
    pub fn detectHotEntities(self: *Self, threshold: u64) ![]EntityHotness {
        var results = std.ArrayList(EntityHotness).init(self.allocator);

        var it = self.entity_patterns.iterator();
        while (it.next()) |entry| {
            const pattern = entry.value_ptr.*;
            if (pattern.total_accesses >= threshold) {
                try results.append(.{
                    .entity_id = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .access_count = pattern.total_accesses,
                    .heat_score = self.calculateHeatScore(&pattern),
                });
            }
        }

        // Sort by heat score
        std.sort.insertion(EntityHotness, results.items, {}, struct {
            fn lessThan(_: void, a: EntityHotness, b: EntityHotness) bool {
                return a.heat_score > b.heat_score;
            }
        }.lessThan);

        return results.toOwnedSlice();
    }

    /// Detect cold entities (rarely accessed)
    pub fn detectColdEntities(self: *Self, threshold_age_ms: u64) ![]EntityColdness {
        var results = std.ArrayList(EntityColdness).init(self.allocator);

        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));

        var it = self.entity_patterns.iterator();
        while (it.next()) |entry| {
            const pattern = entry.value_ptr.*;
            const age_ms = now - pattern.last_access_ts;

            if (age_ms >= threshold_age_ms) {
                try results.append(.{
                    .entity_id = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .last_access_ts = pattern.last_access_ts,
                    .age_ms = age_ms,
                    .cold_score = self.calculateColdScore(&pattern, age_ms),
                });
            }
        }

        // Sort by cold score
        std.sort.insertion(EntityColdness, results.items, {}, struct {
            fn lessThan(_: void, a: EntityColdness, b: EntityColdness) bool {
                return a.cold_score > b.cold_score;
            }
        }.lessThan);

        return results.toOwnedSlice();
    }

    /// Detect performance bottlenecks
    pub fn detectBottlenecks(self: *Self, latency_threshold_ms: f64) ![]Bottleneck {
        var results = std.ArrayList(Bottleneck).init(self.allocator);

        var it = self.query_patterns.iterator();
        while (it.next()) |entry| {
            const pattern = entry.value_ptr.*;

            if (pattern.avg_latency_ms >= latency_threshold_ms) {
                try results.append(.{
                    .query = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .avg_latency_ms = pattern.avg_latency_ms,
                    .execution_count = pattern.access_count,
                    .severity = self.calculateSeverity(pattern.avg_latency_ms, latency_threshold_ms),
                });
            }
        }

        // Sort by severity
        std.sort.insertion(Bottleneck, results.items, {}, struct {
            fn lessThan(_: void, a: Bottleneck, b: Bottleneck) bool {
                return a.severity > b.severity;
            }
        }.lessThan);

        return results.toOwnedSlice();
    }

    /// Get recommendations based on patterns
    pub fn getRecommendations(self: *Self) ![]Recommendation {
        var recommendations = std.ArrayList(Recommendation).init(self.allocator);

        // Check for hot entities needing caching
        const hot = try self.detectHotEntities(self.config.hot_threshold);
        defer {
            for (hot) |*h| self.allocator.free(h.entity_id);
            self.allocator.free(hot);
        }

        for (hot[0..@min(hot.len, 5)]) |h| {
            try recommendations.append(.{
                .type = .add_cache,
                .target = try self.allocator.dupe(u8, h.entity_id),
                .priority = @intFromFloat(h.heat_score * 10),
                .description = try std.fmt.allocPrint(
                    self.allocator,
                    "Hot entity accessed {} times (score: {d:.2})",
                    .{ h.access_count, h.heat_score }
                ),
            });
        }

        // Check for cold entities that could be archived
        const cold = try self.detectColdEntities(self.config.cold_age_threshold_ms);
        defer {
            for (cold) |*c| self.allocator.free(c.entity_id);
            self.allocator.free(cold);
        }

        for (cold[0..@min(cold.len, 5)]) |c| {
            try recommendations.append(.{
                .type = .archive_data,
                .target = try self.allocator.dupe(u8, c.entity_id),
                .priority = @intFromFloat(c.cold_score * 5),
                .description = try std.fmt.allocPrint(
                    self.allocator,
                    "Cold entity not accessed for {d}ms",
                    .{ c.age_ms }
                ),
            });
        }

        // Check for bottlenecks
        const bottlenecks = try self.detectBottlenecks(self.config.bottleneck_latency_ms);
        defer {
            for (bottlenecks) |*b| {
                self.allocator.free(b.query);
            }
            self.allocator.free(bottlenecks);
        }

        for (bottlenecks[0..@min(bottlenecks.len, 5)]) |b| {
            try recommendations.append(.{
                .type = .optimize_query,
                .target = try self.allocator.dupe(u8, b.query),
                .priority = b.severity,
                .description = try std.fmt.allocPrint(
                    self.allocator,
                    "Slow query: {d:.2}ms avg latency",
                    .{ b.avg_latency_ms }
                ),
            });
        }

        return recommendations.toOwnedSlice();
    }

    fn calculateHeatScore(self: *Self, pattern: *const EntityPattern) f32 {
        _ = self;
        // Heat score based on access frequency and recency
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        const age_hours = @as(f32, @floatFromInt(now - pattern.last_access_ts)) / (1000 * 60 * 60);

        const frequency_score = @min(1.0, @as(f32, @floatFromInt(pattern.total_accesses)) / 100);
        const recency_score = @max(0.0, 1.0 - (age_hours / 24));

        return (frequency_score * 0.7) + (recency_score * 0.3);
    }

    fn calculateColdScore(self: *Self, pattern: *const EntityPattern, age_ms: u64) f32 {
        _ = pattern;
        // Cold score based primarily on age
        const age_days = @as(f32, @floatFromInt(age_ms)) / (1000 * 60 * 60 * 24);
        return @min(1.0, age_days / 30); // Max score at 30 days
    }

    fn calculateSeverity(self: *Self, latency: f64, threshold: f64) u8 {
        _ = self;
        const ratio = latency / threshold;
        return @intFromFloat(@min(10, ratio * 5));
    }

    /// Get statistics
    pub fn getStats(self: *const Self) DetectorStats {
        return DetectorStats{
            .total_queries_tracked = self.query_patterns.count(),
            .total_entities_tracked = self.entity_patterns.count(),
            .total_temporal_records = self.temporal_patterns.totalRecords(),
        };
    }
};

/// Query access pattern
pub const QueryPattern = struct {
    query: []const u8,
    access_count: u64,
    total_latency_ms: f64,
    avg_latency_ms: f64,
    min_latency_ms: f64,
    max_latency_ms: f64,
    total_results: usize,
    avg_results: f32,
    first_seen_ts: u64,
    last_seen_ts: u64,

    pub fn init(allocator: std.mem.Allocator, query: []const u8) QueryPattern {
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        return QueryPattern{
            .query = allocator.dupe(u8, query) catch unreachable,
            .access_count = 0,
            .total_latency_ms = 0,
            .avg_latency_ms = 0,
            .min_latency_ms = std.math.inf(f32),
            .max_latency_ms = 0,
            .total_results = 0,
            .avg_results = 0,
            .first_seen_ts = now,
            .last_seen_ts = now,
        };
    }

    pub fn deinit(self: *QueryPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
    }

    pub fn recordAccess(self: *QueryPattern, latency_ms: f64, result_count: usize) !void {
        self.access_count += 1;
        self.last_seen_ts = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));

        // Update latency stats
        self.total_latency_ms += latency_ms;
        self.avg_latency_ms = self.total_latency_ms / @as(f64, @floatFromInt(self.access_count));
        self.min_latency_ms = @min(self.min_latency_ms, @as(f32, @floatCast(latency_ms)));
        self.max_latency_ms = @max(self.max_latency_ms, @as(f32, @floatCast(latency_ms)));

        // Update result count stats
        self.total_results += result_count;
        self.avg_results = @as(f32, @floatFromInt(self.total_results)) / @as(f32, @floatFromInt(self.access_count));
    }
};

/// Entity access pattern
pub const EntityPattern = struct {
    entity_id: []const u8,
    total_accesses: u64,
    read_count: u64,
    write_count: u64,
    last_access_ts: u64,
    first_access_ts: u64,

    pub fn init(allocator: std.mem.Allocator, entity_id: []const u8) EntityPattern {
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        return EntityPattern{
            .entity_id = allocator.dupe(u8, entity_id) catch unreachable,
            .total_accesses = 0,
            .read_count = 0,
            .write_count = 0,
            .last_access_ts = now,
            .first_access_ts = now,
        };
    }

    pub fn deinit(self: *EntityPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
    }

    pub fn recordAccess(self: *EntityPattern, access_type: AccessType) !void {
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        self.total_accesses += 1;
        self.last_access_ts = now;

        switch (access_type) {
            .read => self.read_count += 1,
            .write => self.write_count += 1,
        }
    }
};

/// Access type
pub const AccessType = enum {
    read,
    write,
};

/// Temporal pattern tracker
pub const TemporalPatternTracker = struct {
    allocator: std.mem.Allocator,
    hourly_records: [24]std.ArrayList(TemporalRecord),

    pub fn init(allocator: std.mem.Allocator) TemporalPatternTracker {
        var tracker: TemporalPatternTracker = undefined;
        for (&tracker.hourly_records) |*hour| {
            hour.* = std.ArrayList(TemporalRecord).init(allocator);
        }
        tracker.allocator = allocator;
        return tracker;
    }

    pub fn deinit(self: *TemporalPatternTracker) void {
        for (&self.hourly_records) |*hour| {
            for (hour.items) |*rec| {
                rec.deinit(self.allocator);
            }
            hour.deinit();
        }
    }

    pub fn recordQuery(self: *TemporalPatternTracker, query: []const u8, latency_ms: f64) !void {
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        const hour = @as(usize, @intCast((now / (60 * 60 * 1000)) % 24));

        try self.hourly_records[hour].append(TemporalRecord{
            .query = try self.allocator.dupe(u8, query),
            .timestamp_ms = now,
            .latency_ms = latency_ms,
        });
    }

    pub fn totalRecords(self: *const TemporalPatternTracker) usize {
        var total: usize = 0;
        for (&self.hourly_records) |*hour| {
            total += hour.items.len;
        }
        return total;
    }
};

/// Temporal access record
pub const TemporalRecord = struct {
    query: []const u8,
    timestamp_ms: u64,
    latency_ms: f64,

    pub fn deinit(self: *TemporalRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
    }
};

/// Entity hotness result
pub const EntityHotness = struct {
    entity_id: []const u8,
    access_count: u64,
    heat_score: f32,
};

/// Entity coldness result
pub const EntityColdness = struct {
    entity_id: []const u8,
    last_access_ts: u64,
    age_ms: u64,
    cold_score: f32,
};

/// Performance bottleneck
pub const Bottleneck = struct {
    query: []const u8,
    avg_latency_ms: f64,
    execution_count: u64,
    severity: u8, // 1-10
};

/// Optimization recommendation
pub const Recommendation = struct {
    type: RecommendationType,
    target: []const u8,
    priority: u8, // 1-10
    description: []const u8,

    pub fn deinit(self: *Recommendation, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.description);
    }

    pub const RecommendationType = enum {
        add_cache,
        remove_cache,
        archive_data,
        build_cartridge,
        optimize_query,
        increase_capacity,
    };
};

/// Detector configuration
pub const DetectorConfig = struct {
    /// Minimum accesses to consider "hot"
    hot_threshold: u64 = 100,
    /// Age threshold for "cold" detection (milliseconds)
    cold_age_threshold_ms: u64 = 7 * 24 * 60 * 60 * 1000, // 7 days
    /// Latency threshold for bottleneck detection
    bottleneck_latency_ms: f64 = 100,
    /// Minimum queries before making recommendations
    min_queries_for_recommendations: usize = 50,
};

/// Detector statistics
pub const DetectorStats = struct {
    total_queries_tracked: usize,
    total_entities_tracked: usize,
    total_temporal_records: usize,
};

// ==================== Tests ====================//

test "PatternDetector init and record" {
    var detector = PatternDetector.init(std.testing.allocator, DetectorConfig{});
    defer detector.deinit();

    try detector.recordQuery("SELECT * FROM test", 50.0, 10);

    try std.testing.expectEqual(@as(usize, 1), detector.query_patterns.count());
}

test "PatternDetector detectHotEntities" {
    var detector = PatternDetector.init(std.testing.allocator, DetectorConfig{
        .hot_threshold = 5,
    });
    defer detector.deinit();

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try detector.recordEntityAccess("hot:entity", .read);
    }

    const hot = try detector.detectHotEntities(5);
    defer {
        for (hot) |*h| std.testing.allocator.free(h.entity_id);
        std.testing.allocator.free(hot);
    }

    try std.testing.expectEqual(@as(usize, 1), hot.len);
    try std.testing.expectEqualStrings("hot:entity", hot[0].entity_id);
}

test "PatternDetector detectColdEntities" {
    var detector = PatternDetector.init(std.testing.allocator, DetectorConfig{
        .cold_age_threshold_ms = 1000,
    });
    defer detector.deinit();

    // Entity accessed long ago
    try detector.recordEntityAccess("old:entity", .read);
    std.time.sleep(1 * std.time.ns_per_ms);

    const cold = try detector.detectColdEntities(500);
    defer {
        for (cold) |*c| std.testing.allocator.free(c.entity_id);
        std.testing.allocator.free(cold);
    }

    try std.testing.expect(cold.len > 0);
}

test "PatternDetector detectBottlenecks" {
    var detector = PatternDetector.init(std.testing.allocator, DetectorConfig{
        .bottleneck_latency_ms = 50,
    });
    defer detector.deinit();

    try detector.recordQuery("slow query", 100.0, 10);
    try detector.recordQuery("slow query", 150.0, 10);

    const bottlenecks = try detector.detectBottlenecks(50);
    defer {
        for (bottlenecks) |*b| std.testing.allocator.free(b.query);
        std.testing.allocator.free(bottlenecks);
    }

    try std.testing.expectEqual(@as(usize, 1), bottlenecks.len);
}

test "PatternDetector getRecommendations" {
    var detector = PatternDetector.init(std.testing.allocator, DetectorConfig{
        .hot_threshold = 5,
        .min_queries_for_recommendations = 0,
    });
    defer detector.deinit();

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try detector.recordEntityAccess("hot:entity", .read);
    }

    const recommendations = try detector.getRecommendations();
    defer {
        for (recommendations) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(recommendations);
    }

    try std.testing.expect(recommendations.len > 0);
}

test "QueryPattern init and recordAccess" {
    var pattern = QueryPattern.init(std.testing.allocator, "test query");
    defer pattern.deinit(std.testing.allocator);

    try pattern.recordAccess(50.0, 10);
    try pattern.recordAccess(100.0, 20);

    try std.testing.expectEqual(@as(u64, 2), pattern.access_count);
    try std.testing.expectApproxEqAbs(@as(f64, 75), pattern.avg_latency_ms, 0.1);
}

test "EntityPattern init and recordAccess" {
    var pattern = EntityPattern.init(std.testing.allocator, "entity:123");
    defer pattern.deinit(std.testing.allocator);

    try pattern.recordAccess(.read);
    try pattern.recordAccess(.write);
    try pattern.recordAccess(.read);

    try std.testing.expectEqual(@as(u64, 3), pattern.total_accesses);
    try std.testing.expectEqual(@as(u64, 2), pattern.read_count);
    try std.testing.expectEqual(@as(u64, 1), pattern.write_count);
}

test "TemporalPatternTracker init" {
    var tracker = TemporalPatternTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.recordQuery("test query", 50.0);

    try std.testing.expect(tracker.totalRecords() > 0);
}

test "DetectorStats" {
    var detector = PatternDetector.init(std.testing.allocator, DetectorConfig{});
    defer detector.deinit();

    const stats = detector.getStats();

    try std.testing.expectEqual(@as(usize, 0), stats.total_queries_tracked);
}
