//! Natural language to structured query conversion for NorthstarDB
//!
//! Converts natural language queries to topic-based structured queries with scope expressions.
//! Uses LLM function calling for deterministic, structured extraction.
//! Phase 1: Extended to support review and observability queries.

const std = @import("std");
const mem = std.mem;

const TopicQuery = @import("topic_based.zig").TopicQuery;
const ScopeFilter = @import("topic_based.zig").ScopeFilter;
const events = @import("../events/index.zig");

const llm_client = @import("../llm/client.zig");
const llm_function = @import("../llm/function.zig");
const llm_types = @import("../llm/types.zig");

/// Phase 1: Extended query intent types
pub const QueryIntent = enum {
    topic_search,     // Search entities/topics by keywords
    review_explain,   // Explain code changes/review notes
    review_notes,     // Get review notes for a target
    agent_activity,   // Query agent operations/sessions
    observability,    // Performance/telemetry queries
    regression_hunt,  // Find performance regressions
    unknown,
};

/// Natural language to structured query converter
pub const NLToQueryConverter = struct {
    allocator: std.mem.Allocator,
    llm_provider: *llm_client.LLMProvider,
    function_schema: llm_function.FunctionSchema,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, llm_provider: *llm_client.LLMProvider) !Self {
        const schema = try buildQueryExtractionSchema(allocator);
        return NLToQueryConverter{
            .allocator = allocator,
            .llm_provider = llm_provider,
            .function_schema = schema,
        };
    }

    pub fn deinit(self: *Self) void {
        self.function_schema.deinit(self.allocator);
    }

    /// Convert natural language query to structured TopicQuery
    pub fn convert(self: *Self, natural_query: []const u8) !ConversionResult {
        // Build parameters for LLM function call
        var params_map = std.StringHashMap(llm_types.Value).init(self.allocator);
        defer {
            var it = params_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                // Value cleanup is handled by allocator
            }
            params_map.deinit();
        }

        const query_key = try self.allocator.dupe(u8, "query");
        try params_map.put(query_key, .{ .string = natural_query });

        const params_value = .{ .object = try hashMapToObjectMap(self.allocator, &params_map) };

        // Call LLM with function calling
        const function_result = try self.llm_provider.call_function(
            self.function_schema,
            params_value,
            self.allocator
        );
        defer function_result.deinit(self.allocator);

        // Validate response
        const validation = try self.llm_provider.validate_response(function_result, self.allocator);
        defer validation.deinit(self.allocator);

        if (!validation.is_valid) {
            return ConversionResult{
                .success = false,
                .error_message = validation.error_message orelse "Unknown validation error",
                .query = null,
                .clarifications = &.{},
            };
        }

        // Extract structured data from result
        const query = try self.extractQueryFromResult(function_result.data) orelse {
            return ConversionResult{
                .success = false,
                .error_message = "Failed to extract query from LLM response",
                .query = null,
                .clarifications = &.{},
            };
        };

        return ConversionResult{
            .success = true,
            .error_message = null,
            .query = query,
            .clarifications = &.{},
        };
    }

    /// Convert with fallback to rule-based parsing when LLM unavailable
    pub fn convertWithFallback(self: *Self, natural_query: []const u8) !ConversionResult {
        // Try LLM-based conversion first
        const llm_result = self.convert(natural_query) catch |err| {
            std.log.warn("LLM conversion failed: {}, falling back to rule-based", .{err});
            return self.ruleBasedConvert(natural_query);
        };

        if (llm_result.success) {
            return llm_result;
        }

        return self.ruleBasedConvert(natural_query);
    }

    /// Rule-based conversion fallback for common patterns
    fn ruleBasedConvert(self: *Self, input: []const u8) !ConversionResult {
        const lower = try self.allocator.alloc(u8, input.len);
        defer self.allocator.free(lower);

        for (input, 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }

        // Phase 1: Review and observability query patterns

        // Review explanation patterns
        if (mem.indexOf(u8, lower, "why did") != null and
            (mem.indexOf(u8, lower, "change") != null or mem.indexOf(u8, lower, "modify") != null))
        {
            // "Why did agent X change Y?"
            return self.buildReviewExplainQuery(input);
        }

        if (mem.indexOf(u8, lower, "explain") != null and
            (mem.indexOf(u8, lower, "commit") != null or mem.indexOf(u8, lower, "change") != null))
        {
            return self.buildReviewExplainQuery(input);
        }

        // Review notes patterns
        if (mem.indexOf(u8, lower, "show review") != null or
            mem.indexOf(u8, lower, "review notes for") != null or
            mem.indexOf(u8, lower, "get reviews for") != null)
        {
            // "Show review notes for commit ABC"
            return self.buildReviewNotesQuery(input);
        }

        // Agent activity patterns
        if (mem.indexOf(u8, lower, "what did") != null and mem.indexOf(u8, lower, "agent") != null) {
            return self.buildAgentActivityQuery(input);
        }

        if (mem.indexOf(u8, lower, "agent") != null and mem.indexOf(u8, lower, "activity") != null) {
            return self.buildAgentActivityQuery(input);
        }

        // Regression hunting patterns
        if (mem.indexOf(u8, lower, "regression") != null or
            (mem.indexOf(u8, lower, "performance") != null and mem.indexOf(u8, lower, "since") != null))
        {
            return self.buildRegressionHuntQuery(input);
        }

        // Observability/performance patterns
        if (mem.indexOf(u8, lower, "performance") != null or
            mem.indexOf(u8, lower, "latency") != null or
            mem.indexOf(u8, lower, "throughput") != null)
        {
            return self.buildObservabilityQuery(input);
        }

        // Existing patterns for topic search
        if (mem.indexOf(u8, lower, "files about") != null or
            mem.indexOf(u8, lower, "find files about") != null)
        {
            // Extract topic after "about"
            if (extractPhraseAfter(lower, "about")) |topic| {
                return self.buildSimpleQuery(topic, "file");
            }
        }

        if (mem.indexOf(u8, lower, "related to") != null) {
            if (extractPhraseAfter(lower, "related to")) |topic| {
                return self.buildSimpleQuery(topic, null);
            }
        }

        if (mem.indexOf(u8, lower, "show me") != null) {
            if (extractPhraseAfter(lower, "show me")) |topic| {
                return self.buildSimpleQuery(topic, null);
            }
        }

        if (mem.indexOf(u8, lower, "what") != null and mem.indexOf(u8, lower, "in") != null) {
            // "what <topic> in <entity_type>"
            if (const after_what = extractPhraseAfter(lower, "what")) {
                const parts = mem.splitSequence(u8, after_what, " in ");
                const topic = parts.next().?;
                const entity_type = parts.next().?;
                return self.buildSimpleQuery(topic, entity_type);
            }
        }

        // Default: treat entire input as topic search
        return self.buildSimpleQuery(input, null);
    }

    /// Phase 1: Build review explanation query
    fn buildReviewExplainQuery(self: *Self, input: []const u8) !ConversionResult {
        return ConversionResult{
            .success = true,
            .error_message = null,
            .query = null,
            .clarifications = &.{},
            .intent = .review_explain,
            .raw_query = try self.allocator.dupe(u8, input),
        };
    }

    /// Phase 1: Build review notes query
    fn buildReviewNotesQuery(self: *Self, input: []const u8) !ConversionResult {
        return ConversionResult{
            .success = true,
            .error_message = null,
            .query = null,
            .clarifications = &.{},
            .intent = .review_notes,
            .raw_query = try self.allocator.dupe(u8, input),
        };
    }

    /// Phase 1: Build agent activity query
    fn buildAgentActivityQuery(self: *Self, input: []const u8) !ConversionResult {
        return ConversionResult{
            .success = true,
            .error_message = null,
            .query = null,
            .clarifications = &.{},
            .intent = .agent_activity,
            .raw_query = try self.allocator.dupe(u8, input),
        };
    }

    /// Phase 1: Build regression hunt query
    fn buildRegressionHuntQuery(self: *Self, input: []const u8) !ConversionResult {
        return ConversionResult{
            .success = true,
            .error_message = null,
            .query = null,
            .clarifications = &.{},
            .intent = .regression_hunt,
            .raw_query = try self.allocator.dupe(u8, input),
        };
    }

    /// Phase 1: Build observability query
    fn buildObservabilityQuery(self: *Self, input: []const u8) !ConversionResult {
        return ConversionResult{
            .success = true,
            .error_message = null,
            .query = null,
            .clarifications = &.{},
            .intent = .observability,
            .raw_query = try self.allocator.dupe(u8, input),
        };
    }

    fn buildSimpleQuery(self: *Self, topic: []const u8, entity_type: ?[]const u8) !ConversionResult {
        const topic_dupe = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_dupe);

        var terms = std.array_list.Managed([]const u8).init(self.allocator);
        try terms.append(topic_dupe);

        var operators = std.array_list.Managed(TopicQuery.BooleanOp).init(self.allocator);

        var filters = std.array_list.Managed(ScopeFilter).init(self.allocator);

        if (entity_type) |et| {
            const filter = ScopeFilter{
                .filter_type = .entity_type,
                .string_value = try self.allocator.dupe(u8, et),
                .numeric_value = null,
                .range = null,
            };
            try filters.append(filter);
        }

        const query = TopicQuery{
            .terms = try terms.toOwnedSlice(),
            .operators = try operators.toOwnedSlice(),
            .filters = try filters.toOwnedSlice(),
            .limit = 100,
            .min_confidence = 0.0,
        };

        return ConversionResult{
            .success = true,
            .error_message = null,
            .query = query,
            .clarifications = &.{},
        };
    }

    fn extractQueryFromResult(self: *Self, data: llm_types.Value) !?TopicQuery {
        if (data != .object) return null;

        const obj = data.object;

        // Extract terms array
        const terms_value = obj.get("terms") orelse return null;
        if (terms_value != .array) return null;

        var terms = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer {
            for (terms.items) |t| self.allocator.free(t);
            terms.deinit();
        }

        for (terms_value.array.items) |item| {
            if (item == .string) {
                try terms.append(try self.allocator.dupe(u8, item.string));
            }
        }

        // Extract filters array
        var filters = std.array_list.Managed(ScopeFilter).init(self.allocator);
        errdefer {
            for (filters.items) |*f| f.deinit(self.allocator);
            filters.deinit();
        }

        if (obj.get("filters")) |filters_value| {
            if (filters_value == .array) {
                for (filters_value.array.items) |filter_item| {
                    if (filter_item == .object) {
                        if (try self.extractFilterFromObject(filter_item.object)) |filter| {
                            try filters.append(filter);
                        }
                    }
                }
            }
        }

        // Extract limit
        var limit: usize = 100;
        if (obj.get("limit")) |limit_value| {
            if (limit_value == .integer) {
                limit = @intCast(limit_value.integer);
            }
        }

        // Build operators (default to AND)
        const operators_len = if (terms.items.len > 0) terms.items.len - 1 else 0;
        var operators = std.array_list.Managed(TopicQuery.BooleanOp).init(self.allocator);
        errdefer operators.deinit();

        var i: usize = 0;
        while (i < operators_len) : (i += 1) {
            try operators.append(.@"and");
        }

        return TopicQuery{
            .terms = try terms.toOwnedSlice(),
            .operators = try operators.toOwnedSlice(),
            .filters = try filters.toOwnedSlice(),
            .limit = limit,
            .min_confidence = 0.0,
        };
    }

    fn extractFilterFromObject(self: *Self, obj: std.json.ObjectMap) !?ScopeFilter {
        const type_value = obj.get("type") orelse return null;
        if (type_value != .string) return null;

        const filter_type = filterTypeFromString(type_value.string) orelse return null;

        const value_value = obj.get("value");

        return switch (filter_type) {
            .entity_type => ScopeFilter{
                .filter_type = .entity_type,
                .string_value = if (value_value != null and value_value.? == .string)
                    try self.allocator.dupe(u8, value_value.?.string)
                else
                    null,
                .numeric_value = null,
                .range = null,
            },
            .confidence => ScopeFilter{
                .filter_type = .confidence,
                .string_value = null,
                .numeric_value = if (value_value != null and value_value.? == .number)
                    value_value.?.number
                else
                    null,
                .range = null,
            },
            .after_txn => ScopeFilter{
                .filter_type = .after_txn,
                .string_value = null,
                .numeric_value = if (value_value != null and value_value.? == .number)
                    value_value.?.number
                else
                    null,
                .range = null,
            },
            .before_txn => ScopeFilter{
                .filter_type = .before_txn,
                .string_value = null,
                .numeric_value = if (value_value != null and value_value.? == .number)
                    value_value.?.number
                else
                    null,
                .range = null,
            },
            .wildcard => ScopeFilter{
                .filter_type = .wildcard,
                .string_value = if (value_value != null and value_value.? == .string)
                    try self.allocator.dupe(u8, value_value.?.string)
                else
                    null,
                .numeric_value = null,
                .range = null,
            },
            .time_range => blk: {
                // Parse min,max from value object
                var range: ?ScopeFilter.ValueRange = null;
                if (value_value != null and value_value.? == .object) {
                    const range_obj = value_value.?.object;
                    const min_val = range_obj.get("min");
                    const max_val = range_obj.get("max");
                    if (min_val != null and min_val.? == .number and
                        max_val != null and max_val.? == .number)
                    {
                        range = ScopeFilter.ValueRange{
                            .min = min_val.?.number,
                            .max = max_val.?.number,
                        };
                    }
                }
                break :blk ScopeFilter{
                    .filter_type = .time_range,
                    .string_value = null,
                    .numeric_value = null,
                    .range = range,
                };
            },
        };
    }
};

pub const ConversionResult = struct {
    success: bool,
    error_message: ?[]const u8,
    query: ?TopicQuery,
    clarifications: []const []const u8,
    // Phase 1: Extended fields for review/observability queries
    intent: QueryIntent = .unknown,
    raw_query: ?[]const u8 = null, // Original query text

    pub fn deinit(self: *ConversionResult, allocator: std.mem.Allocator) void {
        if (self.query) |*q| q.deinit(allocator);
        if (self.error_message) |msg| allocator.free(msg);
        for (self.clarifications) |c| allocator.free(c);
        if (self.raw_query) |q| allocator.free(q);
    }
};

/// Build JSON schema for query extraction function
fn buildQueryExtractionSchema(allocator: std.mem.Allocator) !llm_function.FunctionSchema {
    var params = llm_function.JSONSchema.init(.object);
    try params.setDescription(allocator, "Parameters for query extraction");

    // Query parameter
    var query_schema = llm_function.JSONSchema.init(.string);
    try query_schema.setDescription(allocator, "The natural language query to convert");
    try params.addProperty(allocator, "query", query_schema);
    try params.addRequired(allocator, "query");

    return llm_function.FunctionSchema.init(
        allocator,
        "extract_topic_query",
        "Extract structured topic query with filters from natural language",
        params
    );
}

fn filterTypeFromString(str: []const u8) ?ScopeFilter.FilterType {
    if (mem.eql(u8, str, "entity_type")) return .entity_type;
    if (mem.eql(u8, str, "confidence")) return .confidence;
    if (mem.eql(u8, str, "after_txn")) return .after_txn;
    if (mem.eql(u8, str, "before_txn")) return .before_txn;
    if (mem.eql(u8, str, "time_range")) return .time_range;
    if (mem.eql(u8, str, "wildcard")) return .wildcard;
    return null;
}

/// Extract phrase after a keyword (simplified)
fn extractPhraseAfter(input: []const u8, keyword: []const u8) ?[]const u8 {
    const idx = mem.indexOf(u8, input, keyword) orelse return null;
    var start = idx + keyword.len;

    // Skip whitespace
    while (start < input.len and (input[start] == ' ' or input[start] == '\t')) {
        start += 1;
    }

    if (start >= input.len) return null;

    // Find end (space, period, or end)
    var end = start;
    while (end < input.len and input[end] != ' ' and input[end] != '.') {
        end += 1;
    }

    return input[start..end];
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

// ==================== Tests ====================//

test "NLToQueryConverter rule-based conversion simple" {
    // Mock LLM provider (null for now, using rule-based fallback)
    var mock_provider = llm_client.LLMProvider{ .local = undefined };

    var converter = try NLToQueryConverter.init(std.testing.allocator, &mock_provider);
    defer converter.deinit();

    const result = try converter.convertWithFallback("database");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.query != null);

    const query = result.query.?;
    try std.testing.expectEqual(@as(usize, 1), query.terms.len);
    try std.testing.expectEqualStrings("database", query.terms[0]);
}

test "NLToQueryConverter rule-based conversion with entity type" {
    var mock_provider = llm_client.LLMProvider{ .local = undefined };

    var converter = try NLToQueryConverter.init(std.testing.allocator, &mock_provider);
    defer converter.deinit();

    const result = try converter.convertWithFallback("files about performance");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.query != null);

    const query = result.query.?;
    try std.testing.expectEqual(@as(usize, 1), query.terms.len);
    try std.testing.expectEqualStrings("performance", query.terms[0]);
    try std.testing.expectEqual(@as(usize, 1), query.filters.len);
    try std.testing.expectEqual(ScopeFilter.FilterType.entity_type, query.filters[0].filter_type);
    try std.testing.expectEqualStrings("file", query.filters[0].string_value.?);
}

test "extractPhraseAfter" {
    const input = "files about database performance";
    const result = extractPhraseAfter(input, "about");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("database", result.?);
}

test "extractPhraseAfter with trailing" {
    const input = "show me btree files";
    const result = extractPhraseAfter(input, "show me");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("btree", result.?);
}

test "buildSimpleQuery without entity type" {
    var mock_provider = llm_client.LLMProvider{ .local = undefined };

    var converter = try NLToQueryConverter.init(std.testing.allocator, &mock_provider);
    defer converter.deinit();

    const result = try converter.buildSimpleQuery("database", null);
    defer {
        if (result.query) |*q| q.deinit(std.testing.allocator);
        if (result.error_message) |msg| std.testing.allocator.free(msg);
    }

    try std.testing.expect(result.success);
    try std.testing.expect(result.query != null);

    const query = result.query.?;
    try std.testing.expectEqual(@as(usize, 1), query.terms.len);
    try std.testing.expectEqual(@as(usize, 0), query.filters.len);
}
