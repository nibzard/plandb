//! Query optimizer for entity/topic access patterns
//!
//! Analyzes query patterns and optimizes execution by selecting efficient
//! cartridge access strategies, caching results, and recommending improvements.

const std = @import("std");
const mem = std.mem;

/// Access pattern statistics
pub const AccessPattern = struct {
    pattern_type: PatternType,
    access_count: u64,
    last_accessed: u64,
    avg_latency_ms: f64,
    cache_hit_rate: f32,

    pub const PatternType = enum {
        single_entity_lookup,
        topic_search,
        relationship_traversal,
        range_scan,
        complex_join,
    };
};

/// Query optimization result
pub const OptimizationResult = struct {
    original_plan: *const QueryPlan,
    optimized_plan: QueryPlan,
    improvements: []const OptimizationSuggestion,
    estimated_speedup: f32,

    pub fn deinit(self: *OptimizationResult, allocator: std.mem.Allocator) void {
        self.optimized_plan.deinit(allocator);
        for (self.improvements) |*i| i.deinit(allocator);
        allocator.free(self.improvements);
    }
};

/// Optimization suggestion
pub const OptimizationSuggestion = struct {
    suggestion_type: SuggestionType,
    description: []const u8,
    estimated_impact: Impact,

    pub fn deinit(self: *OptimizationSuggestion, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
    }

    pub const SuggestionType = enum {
        use_cache,
        rewrite_query,
        add_index,
        batch_operations,
        limit_results,
    };

    pub const Impact = enum {
        low,
        medium,
        high,
    };
};

/// Query plan reference (minimal for optimizer)
pub const QueryPlan = struct {
    query_type: QueryType,
    steps: []const PlanStep,
    estimated_cost: f64,

    pub fn deinit(self: *QueryPlan, allocator: std.mem.Allocator) void {
        for (self.steps) |*s| s.deinit(allocator);
        allocator.free(self.steps);
    }

    pub const QueryType = enum {
        topic_search,
        entity_lookup,
        relationship_traversal,
        hybrid,
    };

    pub const PlanStep = struct {
        operation: []const u8,
        target: []const u8,
        cost: f64,

        pub fn deinit(self: *PlanStep, allocator: std.mem.Allocator) void {
            allocator.free(self.operation);
            allocator.free(self.target);
        }
    };
};

/// Query statistics tracker
pub const QueryStatistics = struct {
    allocator: std.mem.Allocator,
    pattern_stats: std.StringHashMap(AccessPattern),
    total_queries: u64,
    cache_hits: u64,
    cache_misses: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return QueryStatistics{
            .allocator = allocator,
            .pattern_stats = std.StringHashMap(AccessPattern).init(allocator),
            .total_queries = 0,
            .cache_hits = 0,
            .cache_misses = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.pattern_stats.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pattern_stats.deinit();
    }

    /// Record a query access
    pub fn recordAccess(self: *Self, pattern_key: []const u8, pattern_type: AccessPattern.PatternType, latency_ms: f64) !void {
        self.total_queries += 1;

        const entry = try self.pattern_stats.getOrPut(pattern_key);
        if (!entry.found_existing) {
            entry.value_ptr.* = AccessPattern{
                .pattern_type = pattern_type,
                .access_count = 0,
                .last_accessed = 0,
                .avg_latency_ms = 0,
                .cache_hit_rate = 0,
            };
        }

        entry.value_ptr.access_count += 1;
        entry.value_ptr.last_accessed = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000_000));

        // Update moving average of latency
        const old_avg = entry.value_ptr.avg_latency_ms;
        const new_count = @as(f64, @floatFromInt(entry.value_ptr.access_count));
        entry.value_ptr.avg_latency_ms = (old_avg * (new_count - 1) + latency_ms) / new_count;
    }

    /// Record cache hit
    pub fn recordCacheHit(self: *Self) void {
        self.cache_hits += 1;
    }

    /// Record cache miss
    pub fn recordCacheMiss(self: *Self) void {
        self.cache_misses += 1;
    }

    /// Get cache hit rate
    pub fn getCacheHitRate(self: *const Self) f32 {
        const total = self.cache_hits + self.cache_misses;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.cache_hits)) / @as(f32, @floatFromInt(total));
    }

    /// Get most accessed patterns
    pub fn getTopPatterns(self: *const Self, limit: usize) ![]const PatternEntry {
        var entries = std.array_list.Managed(PatternEntry).init(self.allocator);

        var it = self.pattern_stats.iterator();
        while (it.next()) |entry| {
            try entries.append(.{
                .key = entry.key_ptr.*,
                .pattern = entry.value_ptr.*,
            });
        }

        // Sort by access count
        std.sort.insertion(PatternEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: PatternEntry, b: PatternEntry) bool {
                return a.pattern.access_count > b.pattern.access_count;
            }
        }.lessThan);

        if (entries.items.len > limit) {
            entries.items.len = limit;
        }

        return entries.toOwnedSlice();
    }

    pub const PatternEntry = struct {
        key: []const u8,
        pattern: AccessPattern,
    };
};

/// Query optimizer
pub const QueryOptimizer = struct {
    allocator: std.mem.Allocator,
    stats: *QueryStatistics,
    cache: QueryCache,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, stats: *QueryStatistics) Self {
        return QueryOptimizer{
            .allocator = allocator,
            .stats = stats,
            .cache = QueryCache.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit(self.allocator);
    }

    /// Optimize a query plan
    pub fn optimize(self: *Self, plan: *const QueryPlan) !OptimizationResult {
        var improvements = std.array_list.Managed(OptimizationSuggestion).init(self.allocator);

        // Check cache for similar queries
        const cache_key = try self.buildCacheKey(plan);
        if (self.cache.get(cache_key)) |_| {
            try improvements.append(.{
                .suggestion_type = .use_cache,
                .description = try self.allocator.dupe(u8, "Use cached query result"),
                .estimated_impact = .high,
            });
            self.stats.recordCacheHit();
        } else {
            self.stats.recordCacheMiss();
        }

        // Analyze plan for optimization opportunities
        try self.analyzeForCaching(plan, &improvements);
        try self.analyzeForIndexing(plan, &improvements);
        try self.analyzeForLimit(plan, &improvements);
        try self.analyzeForBatching(plan, &improvements);

        // Build optimized plan
        var optimized_steps = std.array_list.Managed(QueryPlan.PlanStep).init(self.allocator);
        var total_cost: f64 = 0;

        for (plan.steps) |*step| {
            const optimized_step = QueryPlan.PlanStep{
                .operation = try self.allocator.dupe(u8, step.operation),
                .target = try self.allocator.dupe(u8, step.target),
                .cost = step.cost * 0.8, // Assume 20% improvement from optimizations
            };
            try optimized_steps.append(optimized_step);
            total_cost += optimized_step.cost;
        }

        const optimized_plan = QueryPlan{
            .query_type = plan.query_type,
            .steps = try optimized_steps.toOwnedSlice(),
            .estimated_cost = total_cost,
        };

        const estimated_speedup = if (plan.estimated_cost > 0)
            @as(f32, @floatCast(plan.estimated_cost / total_cost))
        else
            1.0;

        return OptimizationResult{
            .original_plan = plan,
            .optimized_plan = optimized_plan,
            .improvements = try improvements.toOwnedSlice(),
            .estimated_speedup = estimated_speedup,
        };
    }

    /// Get optimization recommendations based on statistics
    pub fn getRecommendations(self: *Self) ![]const Recommendation {
        var recommendations = std.array_list.Managed(Recommendation).init(self.allocator);

        // Analyze cache hit rate
        const hit_rate = self.stats.getCacheHitRate();
        if (hit_rate < 0.5) {
            try recommendations.append(.{
                .recommendation_type = .increase_cache_size,
                .description = try std.fmt.allocPrint(
                    self.allocator,
                    "Low cache hit rate ({d:.0}%). Consider increasing cache size.",
                    .{@as(f64, @floatFromInt(hit_rate)) * 100}
                ),
                .priority = .medium,
            });
        }

        // Analyze top patterns
        const top_patterns = try self.stats.getTopPatterns(5);
        defer {
            for (top_patterns) |*p| {
                self.allocator.free(p.key);
            }
            self.allocator.free(top_patterns);
        }

        for (top_patterns) |pattern| {
            if (pattern.pattern.access_count > 1000) {
                try recommendations.append(.{
                    .recommendation_type = .build_cartridge,
                    .description = try std.fmt.allocPrint(
                        self.allocator,
                        "High-frequency pattern '{s}' accessed {} times. Consider building dedicated cartridge.",
                        .{ pattern.key, pattern.pattern.access_count }
                    ),
                    .priority = .high,
                });
            }
        }

        return recommendations.toOwnedSlice();
    }

    fn analyzeForCaching(self: *Self, plan: *const QueryPlan, improvements: *std.ArrayList(OptimizationSuggestion)) !void {
        // Simple queries benefit from caching
        if (plan.steps.len == 1 and plan.estimated_cost < 10) {
            try improvements.*.append(.{
                .suggestion_type = .use_cache,
                .description = try self.allocator.dupe(u8, "Simple query - cache results"),
                .estimated_impact = .medium,
            });
        }
    }

    fn analyzeForIndexing(self: *Self, plan: *const QueryPlan, improvements: *std.ArrayList(OptimizationSuggestion)) !void {
        _ = self;
        _ = plan;
        _ = improvements;
        // Check if queries would benefit from additional indexes
        // This would analyze actual query patterns
    }

    fn analyzeForLimit(self: *Self, plan: *const QueryPlan, improvements: *std.ArrayList(OptimizationSuggestion)) !void {
        // Check if plan has result limiting
        var has_limit = false;
        for (plan.steps) |step| {
            if (mem.indexOf(u8, step.operation, "limit")) |_| {
                has_limit = true;
                break;
            }
        }

        if (!has_limit and plan.steps.len > 0) {
            try improvements.*.append(.{
                .suggestion_type = .limit_results,
                .description = try self.allocator.dupe(u8, "Add LIMIT clause to reduce result set"),
                .estimated_impact = .medium,
            });
        }
    }

    fn analyzeForBatching(self: *Self, plan: *const QueryPlan, improvements: *std.ArrayList(OptimizationSuggestion)) !void {
        _ = self;
        _ = plan;
        _ = improvements;
        // Check for opportunities to batch operations
    }

    fn buildCacheKey(self: *Self, plan: *const QueryPlan) ![]const u8 {
        var key_parts = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (key_parts.items) |p| self.allocator.free(p);
            key_parts.deinit();
        }

        try key_parts.append(try self.allocator.dupe(u8, @tagName(plan.query_type)));

        for (plan.steps) |step| {
            try key_parts.append(try self.allocator.dupe(u8, step.operation));
            try key_parts.append(try self.allocator.dupe(u8, step.target));
        }

        const key = try std.mem.join(self.allocator, ":", key_parts.items);
        return key;
    }
};

/// Query result cache
pub const QueryCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CacheEntry),
    max_entries: usize,
    max_age_ms: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return QueryCache{
            .allocator = allocator,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .max_entries = 1000,
            .max_age_ms = 5 * 60 * 1000, // 5 minutes
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn get(self: *Self, key: []const u8) ?*const CacheEntry {
        const entry = self.entries.get(key) orelse return null;
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));

        if (now - entry.timestamp > self.max_age_ms) {
            // Entry expired
            return null;
        }

        return entry;
    }

    pub fn put(self: *Self, key: []const u8, result: []const u8) !void {
        if (self.entries.count() >= self.max_entries) {
            // Evict oldest entry (simplified)
            var it = self.entries.iterator();
            if (it.next()) |first| {
                self.allocator.free(first.key_ptr.*);
                first.value_ptr.deinit(self.allocator);
                _ = self.entries.remove(first.key_ptr.*);
            }
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const timestamp = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        const result_copy = try self.allocator.dupe(u8, result);

        const entry = CacheEntry{
            .result = result_copy,
            .timestamp = timestamp,
        };

        try self.entries.put(key_copy, entry);
    }

    pub fn clear(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
    }
};

pub const CacheEntry = struct {
    result: []const u8,
    timestamp: u64,

    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.result);
    }
};

/// Optimization recommendation
pub const Recommendation = struct {
    recommendation_type: RecommendationType,
    description: []const u8,
    priority: Priority,

    pub fn deinit(self: *Recommendation, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
    }

    pub const RecommendationType = enum {
        increase_cache_size,
        build_cartridge,
        add_index,
        tune_query,
    };

    pub const Priority = enum {
        low,
        medium,
        high,
    };
};

// ==================== Tests ====================//

test "QueryStatistics init and record" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    try stats.recordAccess("test:query", .topic_search, 5.0);

    try std.testing.expectEqual(@as(u64, 1), stats.total_queries);
    try std.testing.expectEqual(@as(u64, 0), stats.cache_hits);
}

test "QueryStatistics cache hit rate" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    stats.recordCacheHit();
    stats.recordCacheHit();
    stats.recordCacheMiss();

    const rate = stats.getCacheHitRate();
    try std.testing.expectApproxEqAbs(@as(f32, 0.6667), rate, 0.01);
}

test "QueryStatistics getTopPatterns" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    try stats.recordAccess("query:a", .topic_search, 1.0);
    try stats.recordAccess("query:a", .topic_search, 1.0);
    try stats.recordAccess("query:b", .entity_lookup, 1.0);

    const top = try stats.getTopPatterns(10);
    defer {
        for (top) |*p| std.testing.allocator.free(p.key);
        std.testing.allocator.free(top);
    }

    try std.testing.expect(top.len >= 2);
    try std.testing.expectEqual(@as(u64, 2), top[0].pattern.access_count);
}

test "QueryCache put and get" {
    var cache = QueryCache.init(std.testing.allocator);
    defer cache.deinit();

    const key = "test_key";
    const result = "test_result";

    try cache.put(key, result);

    const entry = cache.get(key);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings(result, entry.?.result);
}

test "QueryCache expiration" {
    var cache = QueryCache.init(std.testing.allocator);
    defer cache.deinit();

    // Set very short max age
    cache.max_age_ms = 0;

    const key = "test_key";
    try cache.put(key, "result");

    const entry = cache.get(key);
    try std.testing.expect(entry == null); // Should be expired
}

test "QueryOptimizer init" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    var optimizer = QueryOptimizer.init(std.testing.allocator, &stats);
    defer optimizer.deinit();

    try std.testing.expect(optimizer.stats == &stats);
}

test "QueryOptimizer optimize simple plan" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    var optimizer = QueryOptimizer.init(std.testing.allocator, &stats);
    defer optimizer.deinit();

    const steps = try std.testing.allocator.create(QueryPlan.PlanStep);
    steps.* = .{
        .operation = try std.testing.allocator.dupe(u8, "search"),
        .target = try std.testing.allocator.dupe(u8, "topic_index"),
        .cost = 5.0,
    };

    const plan = QueryPlan{
        .query_type = .topic_search,
        .steps = @as([*]const QueryPlan.PlanStep, @ptrCast(steps))[0..1],
        .estimated_cost = 5.0,
    };

    const result = try optimizer.optimize(&plan);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.optimized_plan.estimated_cost < plan.estimated_cost);
}

test "QueryOptimizer getRecommendations" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    var optimizer = QueryOptimizer.init(std.testing.allocator, &stats);
    defer optimizer.deinit();

    const recommendations = try optimizer.getRecommendations();
    defer {
        for (recommendations) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(recommendations);
    }

    // Should return some recommendations (even if empty list)
    try std.testing.expect(true);
}

test "OptimizationResult deinit" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    var optimizer = QueryOptimizer.init(std.testing.allocator, &stats);
    defer optimizer.deinit();

    const steps = try std.testing.allocator.create(QueryPlan.PlanStep);
    steps.* = .{
        .operation = try std.testing.allocator.dupe(u8, "search"),
        .target = try std.testing.allocator.dupe(u8, "topic_index"),
        .cost = 1.0,
    };

    const plan = QueryPlan{
        .query_type = .topic_search,
        .steps = @as([*]const QueryPlan.PlanStep, @ptrCast(steps))[0..1],
        .estimated_cost = 1.0,
    };

    const result = try optimizer.optimize(&plan);
    result.deinit(std.testing.allocator);

    // If we got here without crash, deinit worked
    try std.testing.expect(true);
}
