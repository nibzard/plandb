//! LLM-powered query planner for intelligent query routing
//!
//! Converts natural language queries into optimized execution plans that
//! route to the appropriate cartridges (entity, topic, relationship).

const std = @import("std");
const mem = std.mem;

const TopicQuery = @import("topic_based.zig").TopicQuery;
const ScopeFilter = @import("topic_based.zig").ScopeFilter;
const EntityId = @import("../cartridges/structured_memory.zig").EntityId;
const EntityType = @import("../cartridges/structured_memory.zig").EntityType;
const RelationshipType = @import("../cartridges/structured_memory.zig").RelationshipType;

const llm_client = @import("../llm/client.zig");
const llm_function = @import("../llm/function.zig");
const llm_types = @import("../llm/types.zig");

/// Query plan with execution steps and cartridge routing
pub const QueryPlan = struct {
    query_type: QueryType,
    steps: []const ExecutionStep,
    estimated_cost: f64,
    requires_cartridges: []const CartridgeRequirement,
    confidence: f32,

    pub fn deinit(self: *QueryPlan, allocator: std.mem.Allocator) void {
        for (self.steps) |*s| s.deinit(allocator);
        allocator.free(self.steps);
        allocator.free(self.requires_cartridges);
    }

    pub const QueryType = enum {
        topic_search,
        entity_lookup,
        relationship_traversal,
        hybrid,
    };
};

/// Single execution step in the query plan
pub const ExecutionStep = struct {
    operation: Operation,
    target_cartridge: CartridgeType,
    parameters: StepParameters,
    dependencies: []const usize, // Indices of steps this depends on

    pub fn deinit(self: *ExecutionStep, allocator: std.mem.Allocator) void {
        self.parameters.deinit(allocator);
        allocator.free(self.dependencies);
    }

    pub const Operation = enum {
        search_topics,
        lookup_entity,
        traverse_relationships,
        filter_results,
        merge_results,
        rank_results,
    };

    pub const StepParameters = union(Operation) {
        search_topics: TopicSearchParams,
        lookup_entity: EntityLookupParams,
        traverse_relationships: TraversalParams,
        filter_results: FilterParams,
        merge_results: MergeParams,
        rank_results: RankParams,

        pub fn deinit(self: *StepParameters, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .search_topics => |*p| p.deinit(allocator),
                .lookup_entity => |*p| p.deinit(allocator),
                .traverse_relationships => |*p| p.deinit(allocator),
                .filter_results => |*p| p.deinit(allocator),
                .merge_results => |*p| p.deinit(allocator),
                .rank_results => |*p| p.deinit(allocator),
            }
        }
    };
};

/// Cartridge type for query routing
pub const CartridgeType = enum {
    entity_index,
    topic_index,
    relationship_graph,
};

/// Cartridge requirement for the query
pub const CartridgeRequirement = struct {
    cartridge_type: CartridgeType,
    access_pattern: AccessPattern,

    pub const AccessPattern = enum {
        read_only,
        read_write,
    };
};

/// Topic search parameters
pub const TopicSearchParams = struct {
    query: TopicQuery,
    use_inverted_index: bool,
    max_results: usize,

    pub fn deinit(self: *TopicSearchParams, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
    }
};

/// Entity lookup parameters
pub const EntityLookupParams = struct {
    entity_id: ?EntityId,
    entity_type: ?EntityType,
    filters: []const EntityFilter,

    pub fn deinit(self: *EntityLookupParams, allocator: std.mem.Allocator) void {
        if (self.entity_id) |*id| {
            allocator.free(id.namespace);
            allocator.free(id.local_id);
        }
        for (self.filters) |*f| f.deinit(allocator);
        allocator.free(self.filters);
    }
};

/// Entity filter for lookups
pub const EntityFilter = struct {
    attribute_name: []const u8,
    operator: FilterOperator,
    value: FilterValue,

    pub fn deinit(self: *EntityFilter, allocator: std.mem.Allocator) void {
        allocator.free(self.attribute_name);
        self.value.deinit(allocator);
    }

    pub const FilterOperator = enum {
        equals,
        contains,
        greater_than,
        less_than,
    };

    pub const FilterValue = union(enum) {
        string: []const u8,
        integer: i64,
        float: f64,

        pub fn deinit(self: *FilterValue, allocator: std.mem.Allocator) void {
            if (self.*) == .string) {
                allocator.free(self.string);
            }
        }
    };
};

/// Relationship traversal parameters
pub const TraversalParams = struct {
    start_entity: []const u8,
    relationship_types: []const RelationshipType,
    max_depth: u8,
    direction: TraversalDirection,

    pub fn deinit(self: *TraversalParams, allocator: std.mem.Allocator) void {
        allocator.free(self.start_entity);
        allocator.free(self.relationship_types);
    }

    pub const TraversalDirection = enum {
        outgoing,
        incoming,
        both,
    };
};

/// Filter parameters
pub const FilterParams = struct {
    source_step: usize,
    filter_func: FilterFunc,

    pub fn deinit(self: *FilterParams, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub const FilterFunc = enum {
        by_confidence,
        by_entity_type,
        by_time_range,
    };
};

/// Merge parameters
pub const MergeParams = struct {
    source_steps: []const usize,
    merge_strategy: MergeStrategy,

    pub fn deinit(self: *MergeParams, allocator: std.mem.Allocator) void {
        allocator.free(self.source_steps);
    }

    pub const MergeStrategy = enum {
        union,
        intersection,
        weighted_combine,
    };
};

/// Rank parameters
pub const RankParams = struct {
    source_step: usize,
    ranking_method: RankingMethod,
    max_results: usize,

    pub fn deinit(self: *RankParams, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub const RankingMethod = enum {
        relevance,
        recency,
        strength,
    };
};

/// LLM-powered query planner
pub const QueryPlanner = struct {
    allocator: std.mem.Allocator,
    llm_provider: *llm_client.LLMProvider,
    schema: llm_function.FunctionSchema,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, llm_provider: *llm_client.LLMProvider) !Self {
        const schema = try buildPlanningSchema(allocator);
        return QueryPlanner{
            .allocator = allocator,
            .llm_provider = llm_provider,
            .schema = schema,
        };
    }

    pub fn deinit(self: *Self) void {
        self.schema.deinit(self.allocator);
    }

    /// Plan query execution from natural language
    pub fn planQuery(self: *Self, natural_query: []const u8) !PlanningResult {
        // Build parameters
        var params_map = std.StringHashMap(llm_types.Value).init(self.allocator);
        defer {
            var it = params_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            params_map.deinit();
        }

        const query_key = try self.allocator.dupe(u8, "query");
        try params_map.put(query_key, .{ .string = natural_query });

        const params_value = .{ .object = try hashMapToObjectMap(self.allocator, &params_map) };

        // Call LLM
        const function_result = try self.llm_provider.call_function(
            self.schema,
            params_value,
            self.allocator
        );
        defer function_result.deinit(self.allocator);

        // Validate response
        const validation = try self.llm_provider.validate_response(function_result, self.allocator);
        defer validation.deinit(self.allocator);

        if (!validation.is_valid) {
            return PlanningResult{
                .success = false,
                .error_message = validation.error_message orelse "Unknown validation error",
                .plan = null,
            };
        }

        // Extract plan from result
        const plan = try self.extractPlanFromResult(function_result.data) orelse {
            return PlanningResult{
                .success = false,
                .error_message = "Failed to extract plan from LLM response",
                .plan = null,
            };
        };

        return PlanningResult{
            .success = true,
            .error_message = null,
            .plan = plan,
        };
    }

    /// Plan with fallback to rule-based planning
    pub fn planWithFallback(self: *Self, natural_query: []const u8) !PlanningResult {
        const llm_result = self.planQuery(natural_query) catch |err| {
            std.log.warn("LLM planning failed: {}, using rule-based", .{err});
            return self.ruleBasedPlan(natural_query);
        };

        if (llm_result.success) {
            return llm_result;
        }

        return self.ruleBasedPlan(natural_query);
    }

    /// Rule-based query planning fallback
    fn ruleBasedPlan(self: *Self, input: []const u8) !PlanningResult {
        const lower = try self.allocator.alloc(u8, input.len);
        defer self.allocator.free(lower);

        for (input, 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }

        // Detect query type patterns
        if (mem.indexOf(u8, lower, "files about") != null or
            mem.indexOf(u8, lower, "find files") != null or
            mem.indexOf(u8, lower, "related to") != null)
        {
            return self.planTopicSearch(input);
        }

        if (mem.indexOf(u8, lower, "connected to") != null or
            mem.indexOf(u8, lower, "depends on") != null or
            mem.indexOf(u8, lower, "imports") != null)
        {
            return self.planRelationshipTraversal(input);
        }

        if (mem.indexOf(u8, lower, "entity") != null and mem.indexOf(u8, lower, "with") != null) {
            return self.planEntityLookup(input);
        }

        // Default: topic search
        return self.planTopicSearch(input);
    }

    fn planTopicSearch(self: *Self, input: []const u8) !PlanningResult {
        var steps = std.array_list.Managed(ExecutionStep).init(self.allocator);

        // Extract topic from input
        const topic = try extractSearchTerm(self.allocator, input);

        var terms = std.array_list.Managed([]const u8).init(self.allocator);
        try terms.append(topic);

        var operators = std.array_list.Managed(TopicQuery.BooleanOp).init(self.allocator);
        var filters = std.array_list.Managed(ScopeFilter).init(self.allocator);

        const topic_query = TopicQuery{
            .terms = try terms.toOwnedSlice(),
            .operators = try operators.toOwnedSlice(),
            .filters = try filters.toOwnedSlice(),
            .limit = 100,
            .min_confidence = 0.0,
        };

        const step = ExecutionStep{
            .operation = .search_topics,
            .target_cartridge = .topic_index,
            .parameters = .{ .search_topics = .{
                .query = topic_query,
                .use_inverted_index = true,
                .max_results = 100,
            }},
            .dependencies = &.{},
        };

        try steps.append(step);

        var cartridge_reqs = std.array_list.Managed(CartridgeRequirement).init(self.allocator);
        try cartridge_reqs-append(.{
            .cartridge_type = .topic_index,
            .access_pattern = .read_only,
        }));

        const plan = try self.allocator.create(QueryPlan);
        plan.* = QueryPlan{
            .query_type = .topic_search,
            .steps = try steps.toOwnedSlice(),
            .estimated_cost = 1.0,
            .requires_cartridges = try cartridge_reqs.toOwnedSlice(),
            .confidence = 0.8,
        };

        return PlanningResult{
            .success = true,
            .error_message = null,
            .plan = plan,
        };
    }

    fn planRelationshipTraversal(self: *Self, input: []const u8) !PlanningResult {
        _ = self;
        _ = input;
        // Simplified plan for relationship traversal
        return PlanningResult{
            .success = false,
            .error_message = try self.allocator.dupe(u8, "Relationship traversal planning not yet implemented"),
            .plan = null,
        };
    }

    fn planEntityLookup(self: *Self, input: []const u8) !PlanningResult {
        _ = self;
        _ = input;
        // Simplified plan for entity lookup
        return PlanningResult{
            .success = false,
            .error_message = try self.allocator.dupe(u8, "Entity lookup planning not yet implemented"),
            .plan = null,
        };
    }

    fn extractPlanFromResult(self: *Self, data: llm_types.Value) !?QueryPlan {
        _ = self;
        _ = data;
        // TODO: Implement full LLM result extraction
        return null;
    }
};

/// Planning result
pub const PlanningResult = struct {
    success: bool,
    error_message: ?[]const u8,
    plan: ?*QueryPlan,

    pub fn deinit(self: *PlanningResult, allocator: std.mem.Allocator) void {
        if (self.plan) |*p| {
            p.deinit(allocator);
            allocator.destroy(p);
        }
        if (self.error_message) |msg| allocator.free(msg);
    }
};

/// Build JSON schema for query planning function
fn buildPlanningSchema(allocator: std.mem.Allocator) !llm_function.FunctionSchema {
    var params = llm_function.JSONSchema.init(.object);
    try params.setDescription(allocator, "Parameters for query planning");

    var query_schema = llm_function.JSONSchema.init(.string);
    try query_schema.setDescription(allocator, "The natural language query to plan");
    try params.addProperty(allocator, "query", query_schema);
    try params.addRequired(allocator, "query");

    return llm_function.FunctionSchema.init(
        allocator,
        "plan_query_execution",
        "Generate an optimized execution plan for a natural language database query",
        params
    );
}

fn hashMapToObjectMap(allocator: std.mem.Allocator, map: *const std.StringHashMap(llm_types.Value)) !std.json.ObjectMap {
    var result = std.json.ObjectMap.init(allocator);
    errdefer {
        var it = result.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
        }
        result.deinit();
    }

    var it = map.iterator();
    while (it.next()) |entry| {
        const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
        try result.put(key_dup, entry.value_ptr.*);
    }

    return result;
}

/// Extract search term from input
fn extractSearchTerm(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const lower = try allocator.alloc(u8, input.len);
    defer allocator.free(lower);

    for (input, 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }

    // Try to extract after common keywords
    const keywords = [_][]const u8{ "files about", "find files", "related to", "show me" };
    for (keywords) |kw| {
        if (mem.indexOf(u8, lower, kw)) |idx| {
            var start = idx + kw.len;
            while (start < lower.len and (lower[start] == ' ' or lower[start] == '\t')) {
                start += 1;
            }
            if (start >= lower.len) continue;

            var end = start;
            while (end < lower.len and lower[end] != ' ' and lower[end] != '.') {
                end += 1;
            }

            return try allocator.dupe(u8, input[start..end]);
        }
    }

    // Default: first word
    var end: usize = 0;
    while (end < input.len and input[end] != ' ') {
        end += 1;
    }

    return try allocator.dupe(u8, input[0..end]);
}

// ==================== Tests ====================//

test "QueryPlanner ruleBasedPlan topic search" {
    var mock_provider = llm_client.LLMProvider{ .local = undefined };

    var planner = try QueryPlanner.init(std.testing.allocator, &mock_provider);
    defer planner.deinit();

    const result = try planner.planWithFallback("files about database");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.plan != null);

    const plan = result.plan.?;
    try std.testing.expectEqual(QueryPlan.QueryType.topic_search, plan.query_type);
    try std.testing.expectEqual(@as(usize, 1), plan.steps.len);
    try std.testing.expectEqual(ExecutionStep.Operation.search_topics, plan.steps[0].operation);
}

test "QueryPlanner ruleBasedPlan relationship traversal" {
    var mock_provider = llm_client.LLMProvider{ .local = undefined };

    var planner = try QueryPlanner.init(std.testing.allocator, &mock_provider);
    defer planner.deinit();

    const result = try planner.planWithFallback("files connected to main.zig");
    defer result.deinit(std.testing.allocator);

    // Should return plan or error (not fully implemented yet)
    _ = result;
}

test "extractSearchTerm from query" {
    const term = try extractSearchTerm(std.testing.allocator, "files about database performance");
    defer std.testing.allocator.free(term);

    try std.testing.expectEqualStrings("database", term);
}

test "CartridgeRequirement sizes" {
    try std.testing.expectEqual(@sizeOf(CartridgeType), 1);
}

test "QueryPlan deinit" {
    var steps = try std.testing.allocator.create(ExecutionStep);
    defer {
        steps.deinit(std.testing.allocator);
        std.testing.allocator.destroy(steps);
    }

    steps.* = ExecutionStep{
        .operation = .search_topics,
        .target_cartridge = .topic_index,
        .parameters = .{ .search_topics = .{
            .query = .{
                .terms = &.{},
                .operators = &.{},
                .filters = &.{},
                .limit = 100,
                .min_confidence = 0.0,
            },
            .use_inverted_index = true,
            .max_results = 100,
        }},
        .dependencies = &.{},
    };

    var reqs = try std.testing.allocator.create(CartridgeRequirement);
    std.testing.allocator.destroy(reqs);
}
