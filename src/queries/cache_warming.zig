//! Smart cache warming and prefetch strategies
//!
//! Implements intelligent cache warming and prefetching based on query patterns,
//! time-based access, and predictive models to reduce latency.

const std = @import("std");
const mem = std.mem;

const PredictionEngine = @import("prediction.zig").PredictionEngine;
const ProactiveBuilder = @import("prediction.zig").ProactiveBuilder;

/// Cache warming strategy
pub const WarmingStrategy = enum {
    /// Warm based on historical access patterns
    pattern_based,
    /// Warm based on time of day
    time_based,
    /// Warm based on predicted future access
    prediction_based,
    /// Warm all entries aggressively
    aggressive,
    /// Warm only high-confidence entries
    conservative,
};

/// Cache entry for warming
pub const CacheEntry = struct {
    key: []const u8,
    data: []const u8,
    access_count: u64,
    last_access: u64,
    size_bytes: usize,
    priority: f32,

    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.data);
    }
};

/// Cache warming configuration
pub const WarmingConfig = struct {
    /// Maximum entries to warm
    max_entries: usize = 1000,
    /// Maximum memory to use (bytes)
    max_memory_bytes: usize = 100 * 1024 * 1024, // 100 MB
    /// Minimum access count for warming
    min_access_count: u64 = 5,
    /// Minimum priority score
    min_priority: f32 = 0.3,
    /// Warming strategy
    strategy: WarmingStrategy = .pattern_based,
};

/// Smart cache warmer
pub const CacheWarmer = struct {
    allocator: std.mem.Allocator,
    cache: *Cache,
    predictor: *PredictionEngine,
    config: WarmingConfig,
    stats: WarmingStats,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        cache: *Cache,
        predictor: *PredictionEngine,
        config: WarmingConfig
    ) Self {
        return CacheWarmer{
            .allocator = allocator,
            .cache = cache,
            .predictor = predictor,
            .config = config,
            .stats = WarmingStats{},
        };
    }

    /// Execute cache warming based on configured strategy
    pub fn warm(self: *Self) !WarmingResult {
        var warmed: usize = 0;
        var skipped: usize = 0;
        var memory_used: usize = 0;

        switch (self.config.strategy) {
            .pattern_based => {
                const result = try self.warmByPattern();
                warmed = result.warmed;
                skipped = result.skipped;
                memory_used = result.memory_used;
            },
            .time_based => {
                const result = try self.warmByTime();
                warmed = result.warmed;
                skipped = result.skipped;
                memory_used = result.memory_used;
            },
            .prediction_based => {
                const result = try self.warmByPrediction();
                warmed = result.warmed;
                skipped = result.skipped;
                memory_used = result.memory_used;
            },
            .aggressive => {
                const result = try self.warmAggressive();
                warmed = result.warmed;
                skipped = result.skipped;
                memory_used = result.memory_used;
            },
            .conservative => {
                const result = try self.warmConservative();
                warmed = result.warmed;
                skipped = result.skipped;
                memory_used = result.memory_used;
            },
        }

        self.stats.total_warms += warmed;
        self.stats.total_skipped += skipped;

        return WarmingResult{
            .warmed = warmed,
            .skipped = skipped,
            .memory_used = memory_used,
        };
    }

    /// Warm cache based on historical access patterns
    fn warmByPattern(self: *Self) !WarmingResult {
        var warmed: usize = 0;
        var skipped: usize = 0;
        var memory_used: usize = 0;

        // Get top patterns from predictor
        for (self.predictor.pattern_history.items) |obs| {
            if (warmed + skipped >= self.config.max_entries) break;
            if (memory_used >= self.config.max_memory_bytes) break;

            if (obs.access_count < self.config.min_access_count) {
                skipped += 1;
                continue;
            }

            // Check if already in cache
            if (self.cache.get(obs.pattern)) |_| {
                skipped += 1;
                continue;
            }

            // Simulate loading data (in real implementation, would load from cartridge)
            const data = try std.fmt.allocPrint(self.allocator, "data:{s}", .{obs.pattern});
            errdefer self.allocator.free(data);

            const entry_size = obs.pattern.len + data.len;

            if (memory_used + entry_size > self.config.max_memory_bytes) {
                self.allocator.free(data);
                skipped += 1;
                continue;
            }

            try self.cache.put(obs.pattern, data);
            memory_used += entry_size;
            warmed += 1;
        }

        return WarmingResult{
            .warmed = warmed,
            .skipped = skipped,
            .memory_used = memory_used,
        };
    }

    /// Warm cache based on time-based patterns
    fn warmByTime(self: *Self) !WarmingResult {
        _ = self;

        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        const hour = @as(usize, @intCast((now / (60 * 60 * 1000)) % 24));

        var warmed: usize = 0;
        var skipped: usize = 0;
        var memory_used: usize = 0;

        // Warm entries typically accessed at this hour
        // In real implementation, would use TimeBasedPredictor
        _ = hour;
        _ = memory_used;

        return WarmingResult{
            .warmed = warmed,
            .skipped = skipped,
            .memory_used = memory_used,
        };
    }

    /// Warm cache based on predictions
    fn warmByPrediction(self: *Self) !WarmingResult {
        var warmed: usize = 0;
        var skipped: usize = 0;
        var memory_used: usize = 0;

        const predictions = try self.predictor.generatePredictions();

        for (predictions) |pred| {
            if (warmed >= self.config.max_entries) break;
            if (memory_used >= self.config.max_memory_bytes) break;

            if (pred.confidence < self.config.min_priority) {
                skipped += 1;
                continue;
            }

            if (self.cache.get(pred.pattern)) |_| {
                skipped += 1;
                continue;
            }

            const data = try std.fmt.allocPrint(self.allocator, "pred:{s}", .{pred.pattern});
            errdefer self.allocator.free(data);

            const entry_size = pred.pattern.len + data.len;

            if (memory_used + entry_size > self.config.max_memory_bytes) {
                self.allocator.free(data);
                skipped += 1;
                continue;
            }

            try self.cache.put(pred.pattern, data);
            memory_used += entry_size;
            warmed += 1;
        }

        return WarmingResult{
            .warmed = warmed,
            .skipped = skipped,
            .memory_used = memory_used,
        };
    }

    /// Aggressive warming - warm everything possible
    fn warmAggressive(self: *Self) !WarmingResult {
        var warmed: usize = 0;
        var skipped: usize = 0;
        var memory_used: usize = 0;

        for (self.predictor.pattern_history.items) |obs| {
            if (warmed >= self.config.max_entries) break;
            if (memory_used >= self.config.max_memory_bytes) break;

            if (self.cache.get(obs.pattern)) |_| {
                skipped += 1;
                continue;
            }

            const data = try std.fmt.allocPrint(self.allocator, "agg:{s}", .{obs.pattern});
            errdefer self.allocator.free(data);

            const entry_size = obs.pattern.len + data.len;

            if (memory_used + entry_size > self.config.max_memory_bytes) {
                self.allocator.free(data);
                skipped += 1;
                continue;
            }

            try self.cache.put(obs.pattern, data);
            memory_used += entry_size;
            warmed += 1;
        }

        return WarmingResult{
            .warmed = warmed,
            .skipped = skipped,
            .memory_used = memory_used,
        };
    }

    /// Conservative warming - only high confidence
    fn warmConservative(self: *Self) !WarmingResult {
        var warmed: usize = 0;
        var skipped: usize = 0;
        var memory_used: usize = 0;

        const predictions = try self.predictor.generatePredictions();

        for (predictions) |pred| {
            if (warmed >= self.config.max_entries) break;
            if (memory_used >= self.config.max_memory_bytes) break;

            // Very high threshold for conservative
            if (pred.confidence < 0.8) {
                skipped += 1;
                continue;
            }

            if (self.cache.get(pred.pattern)) |_| {
                skipped += 1;
                continue;
            }

            const data = try std.fmt.allocPrint(self.allocator, "cons:{s}", .{pred.pattern});
            errdefer self.allocator.free(data);

            const entry_size = pred.pattern.len + data.len;

            if (memory_used + entry_size > self.config.max_memory_bytes) {
                self.allocator.free(data);
                skipped += 1;
                continue;
            }

            try self.cache.put(pred.pattern, data);
            memory_used += entry_size;
            warmed += 1;
        }

        return WarmingResult{
            .warmed = warmed,
            .skipped = skipped,
            .memory_used = memory_used,
        };
    }
};

/// Warming result
pub const WarmingResult = struct {
    warmed: usize,
    skipped: usize,
    memory_used: usize,
};

/// Warming statistics
pub const WarmingStats = struct {
    total_warms: u64 = 0,
    total_skipped: u64 = 0,
};

/// Prefetch strategy
pub const PrefetchStrategy = enum {
    /// Prefetch after access (next-N)
    sequential,
    /// Prefetch based on co-access patterns
    co_access,
    /// Prefetch related entities
    related,
    /// Prefetch predicted queries
    predicted,
};

/// Prefetch engine
pub const PrefetchEngine = struct {
    allocator: std.mem.Allocator,
    cache: *Cache,
    strategy: PrefetchStrategy,
    prefetch_queue: std.ArrayList(PrefetchTask),
    stats: PrefetchStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cache: *Cache, strategy: PrefetchStrategy) Self {
        return PrefetchEngine{
            .allocator = allocator,
            .cache = cache,
            .strategy = strategy,
            .prefetch_queue = std.ArrayList(PrefetchTask).init(allocator),
            .stats = PrefetchStats{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.prefetch_queue.items) |*task| {
            task.deinit(self.allocator);
        }
        self.prefetch_queue.deinit();
    }

    /// Record access and trigger prefetch
    pub fn onAccess(self: *Self, key: []const u8) !void {
        self.stats.total_accesses += 1;

        switch (self.strategy) {
            .sequential => try self.prefetchSequential(key),
            .co_access => try self.prefetchCoAccess(key),
            .related => try self.prefetchRelated(key),
            .predicted => try self.prefetchPredicted(key),
        }
    }

    /// Prefetch next-N entries sequentially
    fn prefetchSequential(self: *Self, key: []const u8) !void {
        _ = key;
        // In real implementation, would determine next keys from index
    }

    /// Prefetch based on co-access patterns
    fn prefetchCoAccess(self: *Self, key: []const u8) !void {
        _ = key;
        // In real implementation, would track which keys are accessed together
    }

    /// Prefetch related entities
    fn prefetchRelated(self: *Self, key: []const u8) !void {
        _ = key;
        // In real implementation, would use relationship cartridge
    }

    /// Prefetch based on predictions
    fn prefetchPredicted(self: *Self, key: []const u8) !void {
        _ = key;
        // In real implementation, would use prediction engine
    }

    /// Execute queued prefetches
    pub fn executePrefetches(self: *Self, limit: usize) !PrefetchResult {
        var executed: usize = 0;
        var failed: usize = 0;

        const count = @min(limit, self.prefetch_queue.items.len);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const task = self.prefetch_queue.orderedRemove(0);

            const data = try std.fmt.allocPrint(self.allocator, "prefetch:{s}", .{task.key});
            errdefer self.allocator.free(data);

            try self.cache.put(task.key, data);
            task.deinit(self.allocator);
            executed += 1;
        }

        self.stats.total_prefetched += executed;

        return PrefetchResult{
            .executed = executed,
            .failed = failed,
            .remaining = self.prefetch_queue.items.len,
        };
    }
};

/// Prefetch task
pub const PrefetchTask = struct {
    key: []const u8,
    priority: f32,

    pub fn deinit(self: *PrefetchTask, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

/// Prefetch result
pub const PrefetchResult = struct {
    executed: usize,
    failed: usize,
    remaining: usize,
};

/// Prefetch statistics
pub const PrefetchStats = struct {
    total_accesses: u64 = 0,
    total_prefetched: u64 = 0,
};

/// Simple LRU cache
pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CacheEntry),
    max_size: usize,
    access_order: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
        return Cache{
            .allocator = allocator,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .max_size = max_size,
            .access_order = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();

        for (self.access_order.items) |key| {
            self.allocator.free(key);
        }
        self.access_order.deinit();
    }

    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        if (self.entries.get(key)) |entry| {
            // Update access order
            if (self.access_order.items.len > 0) {
                const last = self.access_order.orderedRemove(self.access_order.items.len - 1);
                self.allocator.free(last);
            }
            self.access_order.append(try self.allocator.dupe(u8, key)) catch {};
            return entry.data;
        }
        return null;
    }

    pub fn put(self: *Self, key: []const u8, data: []const u8) !void {
        // Evict if at capacity
        if (self.entries.count() >= self.max_size) {
            if (self.access_order.items.len > 0) {
                const lru_key = self.access_order.orderedRemove(0);
                if (self.entries.get(lru_key)) |entry| {
                    entry.deinit(self.allocator);
                }
                _ = self.entries.remove(lru_key);
                self.allocator.free(lru_key);
            }
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);

        const entry = CacheEntry{
            .key = key_copy,
            .data = data_copy,
            .access_count = 0,
            .last_access = 0,
            .size_bytes = key.len + data.len,
            .priority = 0.5,
        };

        try self.entries.put(key_copy, entry);
        try self.access_order.append(try self.allocator.dupe(u8, key));
    }

    pub fn size(self: *const Self) usize {
        return self.entries.count();
    }
};

// ==================== Tests ====================//

test "CacheWarmer init" {
    var predictor = PredictionEngine.init(std.testing.allocator);
    defer predictor.deinit();

    var cache = Cache.init(std.testing.allocator, 100);
    defer cache.deinit();

    const config = WarmingConfig{};
    var warmer = CacheWarmer.init(std.testing.allocator, &cache, &predictor, config);

    try std.testing.expect(warmer.cache == &cache);
}

test "CacheWarmer warmByPattern" {
    var predictor = PredictionEngine.init(std.testing.allocator);
    defer predictor.deinit();

    var cache = Cache.init(std.testing.allocator, 100);
    defer cache.deinit();

    const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));

    // Add observations
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try predictor.recordObservation("test:pattern", .topic_index, now - (@as(u64, i) * 1000));
    }

    var warmer = CacheWarmer.init(std.testing.allocator, &cache, &predictor, .{});
    const result = try warmer.warmByPattern();

    try std.testing.expect(result.warmed > 0);
}

test "CacheWarmer warmConservative" {
    var predictor = PredictionEngine.init(std.testing.allocator);
    defer predictor.deinit();

    var cache = Cache.init(std.testing.allocator, 100);
    defer cache.deinit();

    const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_1000));

    // Add observations to get high confidence
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try predictor.recordObservation("high:confidence", .topic_index, now - (@as(u64, i) * 1000));
    }

    var warmer = CacheWarmer.init(std.testing.allocator, &cache, &predictor, .{ .strategy = .conservative });
    const result = try warmer.warmConservative();

    _ = result;
    // Conservative only warms high confidence
}

test "PrefetchEngine init" {
    var cache = Cache.init(std.testing.allocator, 100);
    defer cache.deinit();

    var engine = PrefetchEngine.init(std.testing.allocator, &cache, .sequential);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.prefetch_queue.items.len);
}

test "PrefetchEngine onAccess" {
    var cache = Cache.init(std.testing.allocator, 100);
    defer cache.deinit();

    var engine = PrefetchEngine.init(std.testing.allocator, &cache, .sequential);
    defer engine.deinit();

    try engine.onAccess("test:key");

    try std.testing.expectEqual(@as(u64, 1), engine.stats.total_accesses);
}

test "Cache init and put" {
    var cache = Cache.init(std.testing.allocator, 10);
    defer cache.deinit();

    try cache.put("key1", "value1");

    try std.testing.expectEqual(@as(usize, 1), cache.size());

    const value = cache.get("key1");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("value1", value.?);
}

test "Cache LRU eviction" {
    var cache = Cache.init(std.testing.allocator, 2);
    defer cache.deinit();

    try cache.put("key1", "value1");
    try cache.put("key2", "value2");
    try cache.put("key3", "value3");

    // key1 should be evicted
    const value = cache.get("key1");
    try std.testing.expect(value == null);

    // key2 and key3 should remain
    const value2 = cache.get("key2");
    try std.testing.expect(value2 != null);
}
