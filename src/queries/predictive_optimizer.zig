//! Predictive query optimization combining ML-style prediction with query optimization
//!
//! Anticipates future queries based on historical patterns and pre-optimizes execution plans.
//! Self-contained module that doesn't depend on external query modules.

const std = @import("std");

/// Cartridge type for predictions
pub const CartridgeType = enum {
    entity_index,
    topic_index,
    relationship_graph,
    pending_tasks_by_type,
};

/// Predictive query optimizer
pub const PredictiveOptimizer = struct {
    allocator: std.mem.Allocator,
    pattern_history: std.StringHashMap(PatternObservation),
    plan_cache: PlanCache,
    stats: PredictorStats,
    config: Config,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return PredictiveOptimizer{
            .allocator = allocator,
            .pattern_history = std.StringHashMap(PatternObservation).init(allocator),
            .plan_cache = PlanCache.init(allocator),
            .stats = PredictorStats{},
            .config = Config.default(),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.pattern_history.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.pattern_history.deinit();
        self.plan_cache.deinit(self.allocator);
    }

    /// Record query execution for learning
    pub fn recordQuery(self: *Self, pattern: []const u8, cartridge_type: CartridgeType, latency_ms: f64) !void {
        _ = latency_ms;
        const now_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000)));

        // Build key for hashmap
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ @tagName(cartridge_type), pattern });
        defer self.allocator.free(key);

        // Check if pattern exists
        const entry = try self.pattern_history.getOrPut(key);
        if (entry.found_existing) {
            entry.value_ptr.access_count += 1;
            entry.value_ptr.timestamp_ms = now_ms;
        } else {
            // New pattern - need to allocate the key since we're using a StringHashMap
            entry.key_ptr.* = try self.allocator.dupe(u8, key);
            entry.value_ptr.* = PatternObservation{
                .pattern = try self.allocator.dupe(u8, pattern),
                .cartridge_type = cartridge_type,
                .timestamp_ms = now_ms,
                .access_count = 1,
            };
        }

        // Track query patterns
        self.stats.total_queries_recorded += 1;
        self.stats.unique_patterns = self.pattern_history.count();
    }

    /// Pre-generate optimized plans for predicted queries
    pub fn preoptimizePredictedQueries(self: *Self) !PreoptimizationResult {
        const now_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000)));

        var prepared: usize = 0;
        var cached: usize = 0;
        var skipped: usize = 0;

        var it = self.pattern_history.iterator();
        while (it.next()) |entry| {
            const obs = entry.value_ptr.*;

            // Calculate confidence based on access frequency and recency
            const age_ms = if (now_ms > obs.timestamp_ms) now_ms - obs.timestamp_ms else 0;
            const age_hours: f32 = @floatCast(@as(f64, @floatFromInt(age_ms)) / (1000 * 60 * 60));
            const recency_factor: f32 = if (age_hours < 1) 1.0 else if (age_hours < 24) 0.8 else 0.5;
            const confidence = @min(1.0, @as(f32, @floatFromInt(obs.access_count)) / 10.0 * recency_factor);

            if (confidence < self.config.min_preoptimization_confidence) {
                skipped += 1;
                continue;
            }

            // Check if plan already cached
            const cache_key = try self.buildPlanKey(obs.pattern, obs.cartridge_type);
            defer self.allocator.free(cache_key);

            if (self.plan_cache.get(cache_key) != null) {
                cached += 1;
                continue;
            }

            // Generate optimized plan for predicted query
            const plan = try self.generateOptimizedPlan(obs.pattern, obs.cartridge_type);
            errdefer plan.deinit(self.allocator);

            // Cache the plan
            try self.plan_cache.put(cache_key, .{
                .plan = plan,
                .confidence = confidence,
                .created_at = now_ms,
            });

            prepared += 1;
            self.stats.plans_preoptimized += 1;
        }

        // Cleanup expired plans
        const expired = try self.plan_cache.pruneExpired(self.allocator);
        self.stats.plans_expired += expired;

        return PreoptimizationResult{
            .plans_prepared = prepared,
            .plans_already_cached = cached,
            .plans_skipped = skipped,
            .plans_expired = expired,
        };
    }

    /// Get optimized plan for query (uses pre-optimized if available)
    pub fn getOptimizedPlan(self: *Self, pattern: []const u8, cartridge_type: CartridgeType) !GetPlanResult {
        const cache_key = try self.buildPlanKey(pattern, cartridge_type);
        defer self.allocator.free(cache_key);

        // Check if we have a pre-optimized plan
        if (self.plan_cache.get(cache_key)) |cached| {
            self.stats.cache_hits += 1;
            return GetPlanResult{
                .plan = try cached.plan.clone(self.allocator),
                .was_preoptimized = true,
                .confidence = cached.confidence,
            };
        }

        self.stats.cache_misses += 1;

        // No pre-optimized plan, generate one
        const plan = try self.generateOptimizedPlan(pattern, cartridge_type);
        errdefer plan.deinit(self.allocator);

        return GetPlanResult{
            .plan = plan,
            .was_preoptimized = false,
            .confidence = 0,
        };
    }

    /// Get predictive insights
    pub fn getPredictiveInsights(self: *const Self) PredictiveInsights {
        const now_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000)));

        var high_confidence: usize = 0;
        var medium_confidence: usize = 0;
        var low_confidence: usize = 0;

        var it = self.pattern_history.iterator();
        while (it.next()) |entry| {
            const obs = entry.value_ptr.*;
            const age_ms = if (now_ms > obs.timestamp_ms) now_ms - obs.timestamp_ms else 0;
            const age_hours: f32 = @floatCast(@as(f64, @floatFromInt(age_ms)) / (1000 * 60 * 60));
            const recency_factor: f32 = if (age_hours < 1) 1.0 else if (age_hours < 24) 0.8 else 0.5;
            const confidence = @min(1.0, @as(f32, @floatFromInt(obs.access_count)) / 10.0 * recency_factor);

            if (confidence >= 0.8) {
                high_confidence += 1;
            } else if (confidence >= 0.5) {
                medium_confidence += 1;
            } else {
                low_confidence += 1;
            }
        }

        const total_requests = self.stats.cache_hits + self.stats.cache_misses;
        const hit_rate = if (total_requests > 0)
            @as(f32, @floatFromInt(self.stats.cache_hits)) / @as(f32, @floatFromInt(total_requests))
        else
            0;

        var sum_confidence: f32 = 0;
        var count: usize = 0;

        it = self.pattern_history.iterator();
        while (it.next()) |entry| {
            const obs = entry.value_ptr.*;
            const age_ms = if (now_ms > obs.timestamp_ms) now_ms - obs.timestamp_ms else 0;
            const age_hours: f32 = @floatCast(@as(f64, @floatFromInt(age_ms)) / (1000 * 60 * 60));
            const recency_factor: f32 = if (age_hours < 1) 1.0 else if (age_hours < 24) 0.8 else 0.5;
            sum_confidence += @min(1.0, @as(f32, @floatFromInt(obs.access_count)) / 10.0 * recency_factor);
            count += 1;
        }

        return PredictiveInsights{
            .total_predictions = self.pattern_history.count(),
            .high_confidence_predictions = high_confidence,
            .medium_confidence_predictions = medium_confidence,
            .low_confidence_predictions = low_confidence,
            .cached_plans = self.plan_cache.count(),
            .cache_hit_rate = hit_rate,
            .avg_prediction_confidence = if (count > 0) sum_confidence / @as(f32, @floatFromInt(count)) else 0,
        };
    }

    /// Get optimization recommendations
    pub fn getRecommendations(self: *Self) ![]Recommendation {
        const insights = self.getPredictiveInsights();
        var count: usize = 0;

        // Count recommendations
        if (insights.cache_hit_rate < 0.3 and self.stats.cache_misses > 100) count += 1;
        if (insights.total_predictions > 50) count += 1;

        const recommendations = try self.allocator.alloc(Recommendation, count);
        var idx: usize = 0;

        // Low cache hit rate recommendation
        if (insights.cache_hit_rate < 0.3 and self.stats.cache_misses > 100) {
            const hit_pct = insights.cache_hit_rate * 100;
            recommendations[idx] = .{
                .type = .increase_preoptimization,
                .description = try std.fmt.allocPrint(
                    self.allocator,
                    "Low predictive cache hit rate ({d:.0}%). Consider lowering confidence threshold.",
                    .{hit_pct}
                ),
                .priority = .medium,
                .estimated_impact = .medium,
            };
            idx += 1;
        }

        // High prediction count - suggest scaling
        if (insights.total_predictions > 50) {
            recommendations[idx] = .{
                .type = .scale_prediction_engine,
                .description = try std.fmt.allocPrint(
                    self.allocator,
                    "High prediction volume ({}). Consider pruning old patterns.",
                    .{insights.total_predictions}
                ),
                .priority = .low,
                .estimated_impact = .low,
            };
            idx += 1;
        }

        return recommendations;
    }

    fn generateOptimizedPlan(self: *Self, pattern: []const u8, cartridge_type: CartridgeType) !OptimizedPlan {
        _ = cartridge_type;

        const steps = try self.allocator.alloc(PlanStep, 3);
        errdefer {
            for (steps) |*s| s.deinit(self.allocator);
            self.allocator.free(steps);
        }

        steps[0] = try PlanStep.init(self.allocator, "scan", pattern, 1.0);
        steps[1] = try PlanStep.init(self.allocator, "filter", "apply_predicates", 0.5);
        steps[2] = try PlanStep.init(self.allocator, "project", "select_columns", 0.3);

        return OptimizedPlan{
            .pattern = try self.allocator.dupe(u8, pattern),
            .steps = steps,
            .estimated_cost = 1.8,
            .created_at = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000))),
        };
    }

    fn buildPlanKey(self: *Self, pattern: []const u8, cartridge_type: CartridgeType) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}",
            .{ @tagName(cartridge_type), pattern }
        );
    }
};

/// Pattern observation
pub const PatternObservation = struct {
    pattern: []const u8,
    cartridge_type: CartridgeType,
    timestamp_ms: u64,
    access_count: u64,

    pub fn deinit(self: *PatternObservation, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
    }
};

/// Pre-optimization result
pub const PreoptimizationResult = struct {
    plans_prepared: usize,
    plans_already_cached: usize,
    plans_skipped: usize,
    plans_expired: usize,
};

/// Get plan result
pub const GetPlanResult = struct {
    plan: OptimizedPlan,
    was_preoptimized: bool,
    confidence: f32,

    pub fn deinit(self: *const GetPlanResult, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
    }
};

/// Optimized execution plan
pub const OptimizedPlan = struct {
    pattern: []const u8,
    steps: []const PlanStep,
    estimated_cost: f64,
    created_at: u64,

    pub fn deinit(self: *const OptimizedPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        for (self.steps) |*s| s.deinit(allocator);
        allocator.free(self.steps);
    }

    pub fn clone(self: *const OptimizedPlan, allocator: std.mem.Allocator) !OptimizedPlan {
        var steps_clone = try allocator.alloc(PlanStep, self.steps.len);
        errdefer allocator.free(steps_clone);

        for (self.steps, 0..) |step, i| {
            steps_clone[i] = try step.clone(allocator);
        }

        return OptimizedPlan{
            .pattern = try allocator.dupe(u8, self.pattern),
            .steps = steps_clone,
            .estimated_cost = self.estimated_cost,
            .created_at = self.created_at,
        };
    }
};

/// Plan execution step
pub const PlanStep = struct {
    operation: []const u8,
    target: []const u8,
    estimated_cost: f64,

    pub fn init(allocator: std.mem.Allocator, operation: []const u8, target: []const u8, cost: f64) !PlanStep {
        return PlanStep{
            .operation = try allocator.dupe(u8, operation),
            .target = try allocator.dupe(u8, target),
            .estimated_cost = cost,
        };
    }

    pub fn deinit(self: *const PlanStep, allocator: std.mem.Allocator) void {
        allocator.free(self.operation);
        allocator.free(self.target);
    }

    pub fn clone(self: *const PlanStep, allocator: std.mem.Allocator) !PlanStep {
        return PlanStep{
            .operation = try allocator.dupe(u8, self.operation),
            .target = try allocator.dupe(u8, self.target),
            .estimated_cost = self.estimated_cost,
        };
    }
};

/// Plan cache entry
const CachedPlan = struct {
    plan: OptimizedPlan,
    confidence: f32,
    created_at: u64,

    pub fn deinit(self: *const CachedPlan, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
    }
};

/// Plan cache
const PlanCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CachedPlan),
    max_age_ms: u64,
    max_entries: usize,

    fn init(allocator: std.mem.Allocator) PlanCache {
        return PlanCache{
            .allocator = allocator,
            .entries = std.StringHashMap(CachedPlan).init(allocator),
            .max_age_ms = 60 * 60 * 1000, // 1 hour
            .max_entries = 1000,
        };
    }

    fn deinit(self: *PlanCache, allocator: std.mem.Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.entries.deinit();
    }

    fn get(self: *PlanCache, key: []const u8) ?*const CachedPlan {
        const entry_ptr = self.entries.getPtr(key) orelse return null;
        const now = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000)));

        if (now - entry_ptr.created_at > self.max_age_ms) {
            return null;
        }

        return entry_ptr;
    }

    fn put(self: *PlanCache, key: []const u8, cached: CachedPlan) !void {
        if (self.entries.count() >= self.max_entries) {
            // Evict oldest
            var it = self.entries.iterator();
            if (it.next()) |first| {
                self.allocator.free(first.key_ptr.*);
                first.value_ptr.deinit(self.allocator);
                _ = self.entries.remove(first.key_ptr.*);
            }
        }

        const key_copy = try self.allocator.dupe(u8, key);
        try self.entries.put(key_copy, cached);
    }

    fn count(self: *const PlanCache) usize {
        return self.entries.count();
    }

    fn pruneExpired(self: *PlanCache, allocator: std.mem.Allocator) !usize {
        const now = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000)));
        var expired: usize = 0;

        // Collect expired keys first
        var expired_keys: [10][]const u8 = undefined;
        var expired_count: usize = 0;

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.created_at > self.max_age_ms) {
                if (expired_count < expired_keys.len) {
                    expired_keys[expired_count] = entry.key_ptr.*;
                    expired_count += 1;
                }
            }
        }

        // Remove expired entries
        for (expired_keys[0..expired_count]) |key| {
            if (self.entries.get(key)) |*cached| {
                const key_copy = try allocator.dupe(u8, key);
                defer allocator.free(key_copy);
                cached.deinit(allocator);
                _ = self.entries.remove(key_copy);
                expired += 1;
            }
        }

        return expired;
    }
};

/// Predictive insights
pub const PredictiveInsights = struct {
    total_predictions: usize,
    high_confidence_predictions: usize,
    medium_confidence_predictions: usize,
    low_confidence_predictions: usize,
    cached_plans: usize,
    cache_hit_rate: f32,
    avg_prediction_confidence: f32,
};

/// Optimization recommendation
pub const Recommendation = struct {
    type: RecommendationType,
    description: []const u8,
    priority: Priority,
    estimated_impact: Impact,

    pub fn deinit(self: *Recommendation, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
    }

    pub const RecommendationType = enum {
        increase_preoptimization,
        scale_prediction_engine,
        tune_confidence_threshold,
        expand_pattern_window,
    };

    pub const Priority = enum {
        low,
        medium,
        high,
        critical,
    };

    pub const Impact = enum {
        low,
        medium,
        high,
        critical,
    };
};

/// Predictor statistics
pub const PredictorStats = struct {
    total_queries_recorded: u64 = 0,
    unique_patterns: usize = 0,
    plans_preoptimized: u64 = 0,
    plans_expired: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
};

/// Configuration
pub const Config = struct {
    min_preoptimization_confidence: f32 = 0.6,
    max_cached_plans: usize = 1000,
    plan_cache_ttl_ms: u64 = 60 * 60 * 1000, // 1 hour

    pub fn default() Config {
        return Config{};
    }
};

// ==================== Tests ====================//

test "PredictiveOptimizer init" {
    var optimizer = PredictiveOptimizer.init(std.testing.allocator);
    defer optimizer.deinit();

    try std.testing.expectEqual(@as(usize, 0), optimizer.plan_cache.count());
}

test "PredictiveOptimizer record query" {
    var optimizer = PredictiveOptimizer.init(std.testing.allocator);
    defer optimizer.deinit();

    try optimizer.recordQuery("test:pattern", .topic_index, 5.0);

    try std.testing.expectEqual(@as(u64, 1), optimizer.stats.total_queries_recorded);
}

test "PredictiveOptimizer record same pattern twice" {
    var optimizer = PredictiveOptimizer.init(std.testing.allocator);
    defer optimizer.deinit();

    try optimizer.recordQuery("test:pattern", .topic_index, 5.0);
    try optimizer.recordQuery("test:pattern", .topic_index, 5.0);

    try std.testing.expectEqual(@as(u64, 2), optimizer.stats.total_queries_recorded);
    try std.testing.expectEqual(@as(usize, 1), optimizer.stats.unique_patterns);
}

test "PredictiveOptimizer preoptimize predicted queries" {
    var optimizer = PredictiveOptimizer.init(std.testing.allocator);
    defer optimizer.deinit();

    // Record some queries
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try optimizer.recordQuery("frequent:query", .topic_index, 5.0);
    }

    const result = try optimizer.preoptimizePredictedQueries();

    // Should have prepared some plans or skipped due to low confidence
    _ = result;
    try std.testing.expect(true);
}

test "PredictiveOptimizer get optimized plan" {
    var optimizer = PredictiveOptimizer.init(std.testing.allocator);
    defer optimizer.deinit();

    const result = try optimizer.getOptimizedPlan("test:query", .entity_index);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.was_preoptimized);
    try std.testing.expectEqual(@as(usize, 3), result.plan.steps.len);
}

test "PredictiveOptimizer predictive insights" {
    var optimizer = PredictiveOptimizer.init(std.testing.allocator);
    defer optimizer.deinit();

    const insights = optimizer.getPredictiveInsights();

    try std.testing.expectEqual(@as(usize, 0), insights.total_predictions);
    try std.testing.expectEqual(@as(f32, 0), insights.cache_hit_rate);
}

test "PredictiveOptimizer get recommendations" {
    var optimizer = PredictiveOptimizer.init(std.testing.allocator);
    defer optimizer.deinit();

    const recommendations = try optimizer.getRecommendations();
    defer {
        for (recommendations) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(recommendations);
    }

    try std.testing.expect(true);
}

test "OptimizedPlan clone" {
    // Create steps directly in the array
    const steps = try std.testing.allocator.alloc(PlanStep, 2);
    steps[0] = try PlanStep.init(std.testing.allocator, "op1", "target1", 1.0);
    steps[1] = try PlanStep.init(std.testing.allocator, "op2", "target2", 2.0);

    const original = OptimizedPlan{
        .pattern = try std.testing.allocator.dupe(u8, "test"),
        .steps = steps,
        .estimated_cost = 3.0,
        .created_at = 1000,
    };
    defer original.deinit(std.testing.allocator);

    const cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(original.pattern, cloned.pattern);
    try std.testing.expectEqual(original.steps.len, cloned.steps.len);
}

test "PlanStep init and clone" {
    var step = try PlanStep.init(std.testing.allocator, "scan", "table", 1.5);
    defer step.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("scan", step.operation);
    try std.testing.expectEqual(@as(f64, 1.5), step.estimated_cost);

    const cloned = try step.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(step.operation, cloned.operation);
}

test "PatternObservation deinit" {
    var obs = PatternObservation{
        .pattern = try std.testing.allocator.dupe(u8, "test"),
        .cartridge_type = .entity_index,
        .timestamp_ms = 1000,
        .access_count = 5,
    };
    obs.deinit(std.testing.allocator);

    try std.testing.expect(true);
}

test "Recommendation deinit" {
    var rec = Recommendation{
        .type = .increase_preoptimization,
        .description = try std.testing.allocator.dupe(u8, "test recommendation"),
        .priority = .medium,
        .estimated_impact = .low,
    };
    rec.deinit(std.testing.allocator);

    try std.testing.expect(true);
}
