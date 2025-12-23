//! Query routing to optimal cartridges
//!
//! Intelligently routes queries to the most appropriate cartridges (entity,
//! topic, relationship) based on query patterns and optimization analysis.

const std = @import("std");
const mem = std.mem;

const TopicQuery = @import("topic_based.zig").TopicQuery;
const ScopeFilter = @import("topic_based.zig").ScopeFilter;
const EntityId = @import("../cartridges/structured_memory.zig").EntityId;
const Entity = @import("../cartridges/structured_memory.zig").Entity;
const EntityType = @import("../cartridges/structured_memory.zig").EntityType;
const RelationshipType = @import("../cartridges/structured_memory.zig").RelationshipType;

const QueryPlanner = @import("planner.zig").QueryPlanner;
const QueryOptimizer = @import("optimizer.zig").QueryOptimizer;
const QueryStatistics = @import("optimizer.zig").QueryStatistics;

/// Cartridge selector for routing decisions
pub const CartridgeSelector = struct {
    allocator: std.mem.Allocator,
    cartridge_stats: std.StringHashMap(CartridgeStats),
    routing_rules: std.ArrayList(RoutingRule),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return CartridgeSelector{
            .allocator = allocator,
            .cartridge_stats = std.StringHashMap(CartridgeStats).init(allocator),
            .routing_rules = std.ArrayList(RoutingRule).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.cartridge_stats.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.cartridge_stats.deinit();

        for (self.routing_rules.items) |*rule| {
            rule.deinit(self.allocator);
        }
        self.routing_rules.deinit();
    }

    /// Select best cartridge for a query
    pub fn selectCartridge(self: *Self, query: *const RoutedQuery) !CartridgeSelection {
        var scores = std.ArrayList(CartridgeScore).init(self.allocator);
        defer {
            for (scores.items) |*s| {
                self.allocator.free(s.cartridge_id);
            }
            scores.deinit();
        }

        // Score each cartridge type
        try self.scoreCartridge(&scores, .entity_index, query);
        try self.scoreCartridge(&scores, .topic_index, query);
        try self.scoreCartridge(&scores, .relationship_graph, query);

        // Find highest score
        if (scores.items.len == 0) {
            return CartridgeSelection{
                .cartridge_type = .topic_index, // default
                .confidence = 0.0,
                .reasoning = try self.allocator.dupe(u8, "No scoring data available"),
            };
        }

        var best_idx: usize = 0;
        var best_score: f32 = 0;

        for (scores.items, 0..) |s, i| {
            if (s.score > best_score) {
                best_score = s.score;
                best_idx = i;
            }
        }

        const selected = scores.items[best_idx];

        return CartridgeSelection{
            .cartridge_type = selected.cartridge_type,
            .confidence = best_score,
            .reasoning = try self.allocator.dupe(u8, selected.reasoning),
        };
    }

    /// Score a cartridge for the given query
    fn scoreCartridge(self: *Self, scores: *std.ArrayList(CartridgeScore), cartridge_type: CartridgeType, query: *const RoutedQuery) !void {
        var score: f32 = 0;
        var reasons = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (reasons.items) |r| self.allocator.free(r);
            reasons.deinit();
        }

        switch (cartridge_type) {
            .entity_index => {
                // High score for entity-specific queries
                if (query.has_entity_type_filter) {
                    score += 0.8;
                    try reasons.append("Has entity type filter");
                }
                if (query.target_entity != null) {
                    score += 0.9;
                    try reasons.append("Targets specific entity");
                }
                if (query.terms.len == 0) {
                    score += 0.2;
                    try reasons.append("No search terms (direct lookup)");
                }
            },
            .topic_index => {
                // High score for topic-based searches
                if (query.terms.len > 0) {
                    score += 0.7;
                    try reasons.append("Has search terms");
                }
                if (query.terms.len > 1) {
                    score += 0.1;
                    try reasons.append("Multiple terms (complex search)");
                }
                if (query.has_entity_type_filter) {
                    score += 0.2;
                    try reasons.append("Can combine with type filter");
                }
            },
            .relationship_graph => {
                // High score for relationship queries
                if (query.requires_relationships) {
                    score += 0.9;
                    try reasons.append("Requires relationship data");
                }
                if (query.max_depth > 1) {
                    score += 0.1;
                    try reasons.append("Multi-hop traversal");
                }
            },
        }

        // Apply cartridge-specific statistics
        const cart_id = try std.fmt.allocPrint(self.allocator, "{s}", .{@tagName(cartridge_type)});
        defer self.allocator.free(cart_id);

        if (self.cartridge_stats.get(cart_id)) |stats| {
            if (stats.avg_latency_ms > 0) {
                const latency_score = @max(0, 1.0 - (stats.avg_latency_ms / 1000));
                score *= latency_score;
                try reasons.append("Latency-adjusted score");
            }

            if (stats.hit_rate > 0.8) {
                score += 0.1;
                try reasons.append("High cache hit rate");
            }
        }

        var reasoning = try std.ArrayList(u8).init(self.allocator);
        for (reasons.items, 0..) |r, i| {
            if (i > 0) try reasoning.appendSlice("; ");
            try reasoning.appendSlice(r);
        }

        try scores.append(.{
            .cartridge_type = cartridge_type,
            .cartridge_id = try self.allocator.dupe(u8, @tagName(cartridge_type)),
            .score = score,
            .reasoning = reasoning.toOwnedSlice(),
        });
    }

    /// Update cartridge statistics
    pub fn updateStats(self: *Self, cartridge_type: CartridgeType, latency_ms: f64, hit: bool) !void {
        const cart_id = try std.fmt.allocPrint(self.allocator, "{s}", .{@tagName(cartridge_type)});
        errdefer self.allocator.free(cart_id);

        const entry = try self.cartridge_stats.getOrPut(cart_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = CartridgeStats{
                .query_count = 0,
                .total_latency_ms = 0,
                .avg_latency_ms = 0,
                .hits = 0,
                .misses = 0,
                .hit_rate = 0,
            };
        }

        entry.value_ptr.query_count += 1;
        entry.value_ptr.total_latency_ms += latency_ms;
        entry.value_ptr.avg_latency_ms = entry.value_ptr.total_latency_ms / @as(f64, @floatFromInt(entry.value_ptr.query_count));

        if (hit) {
            entry.value_ptr.hits += 1;
        } else {
            entry.value_ptr.misses += 1;
        }

        const total = entry.value_ptr.hits + entry.value_ptr.misses;
        if (total > 0) {
            entry.value_ptr.hit_rate = @as(f32, @floatFromInt(entry.value_ptr.hits)) / @as(f32, @floatFromInt(total));
        }
    }
};

/// Query routing result
pub const CartridgeSelection = struct {
    cartridge_type: CartridgeType,
    confidence: f32,
    reasoning: []const u8,

    pub fn deinit(self: *CartridgeSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.reasoning);
    }
};

/// Cartridge score for routing
const CartridgeScore = struct {
    cartridge_type: CartridgeType,
    cartridge_id: []const u8,
    score: f32,
    reasoning: []const u8,
};

/// Cartridge performance statistics
pub const CartridgeStats = struct {
    query_count: u64,
    total_latency_ms: f64,
    avg_latency_ms: f64,
    hits: u64,
    misses: u64,
    hit_rate: f32,
};

/// Routing rule
pub const RoutingRule = struct {
    name: []const u8,
    condition: RuleCondition,
    action: RuleAction,
    priority: u8,

    pub fn deinit(self: *RoutingRule, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.condition.deinit(allocator);
        self.action.deinit(allocator);
    }

    pub const RuleCondition = struct {
        query_pattern: []const u8,
        min_terms: usize,
        requires_type: bool,

        pub fn deinit(self: *RuleCondition, allocator: std.mem.Allocator) void {
            allocator.free(self.query_pattern);
        }
    };

    pub const RuleAction = struct {
        target_cartridge: CartridgeType,
        max_results: usize,

        pub fn deinit(self: *RuleAction, allocator: std.mem.Allocator) void {
            _ = allocator;
        }
    };
};

/// Cartridge type enumeration
pub const CartridgeType = enum {
    entity_index,
    topic_index,
    relationship_graph,
};

/// Query for routing
pub const RoutedQuery = struct {
    terms: []const []const u8,
    filters: []const ScopeFilter,
    target_entity: ?EntityId,
    has_entity_type_filter: bool,
    requires_relationships: bool,
    max_depth: u8,
};

/// Query router with intelligent routing
pub const QueryRouter = struct {
    allocator: std.mem.Allocator,
    selector: CartridgeSelector,
    planner: *QueryPlanner,
    optimizer: *QueryOptimizer,
    stats: *QueryStatistics,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        planner: *QueryPlanner,
        optimizer: *QueryOptimizer,
        stats: *QueryStatistics
    ) Self {
        return QueryRouter{
            .allocator = allocator,
            .selector = CartridgeSelector.init(allocator),
            .planner = planner,
            .optimizer = optimizer,
            .stats = stats,
        };
    }

    pub fn deinit(self: *Self) void {
        self.selector.deinit();
    }

    /// Route a query to the optimal cartridge
    pub fn route(self: *Self, natural_query: []const u8) !RouteResult {
        const start_time = std.time.nanoTimestamp();

        // Parse query into structured form
        const routed_query = try self.parseQuery(natural_query);
        defer self.cleanupQuery(routed_query);

        // Select optimal cartridge
        const selection = try self.selector.selectCartridge(&routed_query);
        defer selection.deinit(self.allocator);

        const end_time = std.time.nanoTimestamp();
        const latency_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000;

        // Update statistics
        try self.selector.updateStats(selection.cartridge_type, latency_ms, true);

        return RouteResult{
            .cartridge_type = selection.cartridge_type,
            .confidence = selection.confidence,
            .reasoning = try self.allocator.dupe(u8, selection.reasoning),
            .estimated_latency_ms = latency_ms,
        };
    }

    /// Batch route multiple queries
    pub fn routeBatch(self: *Self, queries: []const []const u8) ![]RouteResult {
        var results = std.ArrayList(RouteResult).init(self.allocator);

        for (queries) |query| {
            const result = try self.route(query) catch |err| {
                // Return error result for failed routing
                try results.append(.{
                    .cartridge_type = .topic_index,
                    .confidence = 0,
                    .reasoning = try self.allocator.dupe(u8, @errorName(err)),
                    .estimated_latency_ms = 0,
                });
                continue;
            };
            try results.append(result);
        }

        return results.toOwnedSlice();
    }

    /// Get routing statistics
    pub fn getStats(self: *const Self) !RouterStats {
        var total_queries: u64 = 0;
        var total_latency: f64 = 0;

        var it = self.selector.cartridge_stats.iterator();
        while (it.next()) |entry| {
            total_queries += entry.value_ptr.query_count;
            total_latency += entry.value_ptr.total_latency_ms;
        }

        return RouterStats{
            .total_queries = total_queries,
            .avg_latency_ms = if (total_queries > 0) total_latency / @as(f64, @floatFromInt(total_queries)) else 0,
        };
    }

    fn parseQuery(self: *Self, input: []const u8) !RoutedQuery {
        _ = self;

        // Simple parsing - in production would use NLToQueryConverter
        var terms_list = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (terms_list.items) |t| self.allocator.free(t);
            terms_list.deinit();
        }

        // Extract words as terms
        var iter = mem.splitScalar(u8, input, ' ');
        while (iter.next()) |word| {
            if (word.len > 0) {
                try terms_list.append(try self.allocator.dupe(u8, word));
            }
        }

        // Check for entity type filter
        var has_type_filter = false;
        if (mem.indexOf(u8, input, "file") != null or
            mem.indexOf(u8, input, "files") != null)
        {
            has_type_filter = true;
        }

        // Check for relationship requirements
        const requires_rels = mem.indexOf(u8, input, "connected") != null or
            mem.indexOf(u8, input, "related") != null or
            mem.indexOf(u8, input, "imports") != null;

        return RoutedQuery{
            .terms = try terms_list.toOwnedSlice(),
            .filters = &.{},
            .target_entity = null,
            .has_entity_type_filter = has_type_filter,
            .requires_relationships = requires_rels,
            .max_depth = 1,
        };
    }

    fn cleanupQuery(self: *Self, query: RoutedQuery) void {
        _ = self;
        for (query.terms) |t| {
            self.allocator.free(t);
        }
        self.allocator.free(query.terms);
    }
};

/// Routing result
pub const RouteResult = struct {
    cartridge_type: CartridgeType,
    confidence: f32,
    reasoning: []const u8,
    estimated_latency_ms: f64,

    pub fn deinit(self: *RouteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.reasoning);
    }
};

/// Router statistics
pub const RouterStats = struct {
    total_queries: u64,
    avg_latency_ms: f64,
};

// ==================== Tests ====================//

test "CartridgeSelector init" {
    var selector = CartridgeSelector.init(std.testing.allocator);
    defer selector.deinit();

    try std.testing.expectEqual(@as(usize, 0), selector.cartridge_stats.count());
    try std.testing.expectEqual(@as(usize, 0), selector.routing_rules.items.len);
}

test "CartridgeSelector selectCartridge topic search" {
    var selector = CartridgeSelector.init(std.testing.allocator);
    defer selector.deinit();

    const terms = [_][]const u8{"database"};

    const query = RoutedQuery{
        .terms = &terms,
        .filters = &.{},
        .target_entity = null,
        .has_entity_type_filter = false,
        .requires_relationships = false,
        .max_depth = 1,
    };

    const result = try selector.selectCartridge(&query);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.confidence > 0);
}

test "CartridgeSelector selectCartridge entity lookup" {
    var selector = CartridgeSelector.init(std.testing.allocator);
    defer selector.deinit();

    const terms = [_][]const u8{};

    const query = RoutedQuery{
        .terms = &terms,
        .filters = &.{},
        .target_entity = null,
        .has_entity_type_filter = true,
        .requires_relationships = false,
        .max_depth = 1,
    };

    const result = try selector.selectCartridge(&query);
    defer result.deinit(std.testing.allocator);

    // Entity lookup should prefer entity_index
    try std.testing.expect(CartridgeType.entity_index == result.cartridge_type);
}

test "CartridgeSelector selectCartridge relationship" {
    var selector = CartridgeSelector.init(std.testing.allocator);
    defer selector.deinit();

    const terms = [_][]const u8{};

    const query = RoutedQuery{
        .terms = &terms,
        .filters = &.{},
        .target_entity = null,
        .has_entity_type_filter = false,
        .requires_relationships = true,
        .max_depth = 2,
    };

    const result = try selector.selectCartridge(&query);
    defer result.deinit(std.testing.allocator);

    // Relationship queries should use relationship_graph
    try std.testing.expect(CartridgeType.relationship_graph == result.cartridge_type);
}

test "CartridgeSelector updateStats" {
    var selector = CartridgeSelector.init(std.testing.allocator);
    defer selector.deinit();

    try selector.updateStats(.topic_index, 50.0, true);

    const cart_id = "topic_index";
    const stats = selector.cartridge_stats.get(cart_id);
    try std.testing.expect(stats != null);
    try std.testing.expectEqual(@as(u64, 1), stats.?.query_count);
}

test "QueryRouter route simple query" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    var mock_planner = undefined; // Would be real planner
    var mock_optimizer = QueryOptimizer.init(std.testing.allocator, &stats);
    defer mock_optimizer.deinit();

    var router = QueryRouter.init(std.testing.allocator, &mock_planner, &mock_optimizer, &stats);
    defer router.deinit();

    const result = try router.route("database files");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.confidence >= 0);
}

test "QueryRouter routeBatch" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    var mock_planner = undefined;
    var mock_optimizer = QueryOptimizer.init(std.testing.allocator, &stats);
    defer mock_optimizer.deinit();

    var router = QueryRouter.init(std.testing.allocator, &mock_planner, &mock_optimizer, &stats);
    defer router.deinit();

    const queries = [_][]const u8{ "database", "performance" };
    const results = try router.routeBatch(&queries);
    defer {
        for (results) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "QueryRouter getStats" {
    var stats = QueryStatistics.init(std.testing.allocator);
    defer stats.deinit();

    var mock_planner = undefined;
    var mock_optimizer = QueryOptimizer.init(std.testing.allocator, &stats);
    defer mock_optimizer.deinit();

    var router = QueryRouter.init(std.testing.allocator, &mock_planner, &mock_optimizer, &stats);
    defer router.deinit();

    const router_stats = try router.getStats();

    try std.testing.expectEqual(@as(u64, 0), router_stats.total_queries);
}
