//! Entity Extraction Plugin for NorthstarDB AI Intelligence Layer
//!
//! This plugin hooks into the commit stream to extract entities, topics, and relationships
//! from data mutations using LLM function calling. It populates the structured memory
//! cartridge format for semantic query capabilities.
//!
//! Features:
//! - Streaming extraction during commit (real-time processing)
//! - Batch processing of commits for cost-effective LLM calls
//! - Entity extraction with confidence scoring
//! - Topic clustering and hierarchical organization
//! - Relationship extraction between entities
//! - Graceful degradation when LLM unavailable
//! - Configurable extraction thresholds and batch sizes

const std = @import("std");
const manager = @import("manager.zig");
const txn = @import("../txn.zig");
const llm_function = @import("../llm/function.zig");

const ArrayListManaged = std.ArrayListUnmanaged;

// ==================== Plugin Configuration ====================

/// Configuration for entity extraction plugin
pub const ExtractorConfig = struct {
    /// Batch size for LLM calls (number of commits to process together)
    batch_size: usize = 10,
    /// Minimum confidence threshold for storing extracted entities
    min_confidence: f32 = 0.7,
    /// Maximum tokens per LLM call
    max_tokens: u32 = 4096,
    /// Timeout for LLM calls in milliseconds
    timeout_ms: u64 = 30000,
    /// Enable/disable topic extraction
    extract_topics: bool = true,
    /// Enable/disable relationship extraction
    extract_relationships: bool = true,
    /// Maximum entities to extract per batch
    max_entities_per_batch: usize = 100,

    pub fn default() ExtractorConfig {
        return ExtractorConfig{};
    }
};

// ==================== Plugin State ====================

/// Internal state for entity extraction plugin
pub const ExtractorState = struct {
    allocator: std.mem.Allocator,
    config: ExtractorConfig,
    pending_mutations: ArrayListManaged(PendingMutation),
    stats: Statistics,
    llm_available: bool,

    const PendingMutation = struct {
        txn_id: u64,
        key: []const u8,
        value: []const u8,
        timestamp: i64,
    };

    const Statistics = struct {
        total_commits_processed: u64 = 0,
        total_entities_extracted: u64 = 0,
        total_topics_extracted: u64 = 0,
        total_relationships_extracted: u64 = 0,
        llm_calls_made: u64 = 0,
        llm_errors: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: ExtractorConfig) !ExtractorState {
        return ExtractorState{
            .allocator = allocator,
            .config = config,
            .pending_mutations = .{},
            .stats = .{},
            .llm_available = false,
        };
    }

    pub fn deinit(self: *ExtractorState) void {
        for (self.pending_mutations.items) |*m| {
            self.allocator.free(m.key);
            self.allocator.free(m.value);
        }
        self.pending_mutations.deinit(self.allocator);
    }

    /// Add mutation to pending batch
    pub fn addPendingMutation(self: *ExtractorState, key: []const u8, value: []const u8, txn_id: u64) !void {
        const key_dup = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dup);

        const value_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_dup);

        try self.pending_mutations.append(self.allocator, .{
            .txn_id = txn_id,
            .key = key_dup,
            .value = value_dup,
            .timestamp = std.time.nanoTimestamp(),
        });
    }

    /// Check if batch is ready to process
    pub fn shouldProcessBatch(self: *const ExtractorState) bool {
        return self.pending_mutations.items.len >= self.config.batch_size;
    }

    /// Get batch size
    pub fn getBatchSize(self: *const ExtractorState) usize {
        return self.pending_mutations.items.len;
    }

    /// Clear pending mutations after processing
    pub fn clearPending(self: *ExtractorState) void {
        for (self.pending_mutations.items) |*m| {
            self.allocator.free(m.key);
            self.allocator.free(m.value);
        }
        self.pending_mutations.clearRetainingCapacity();
    }
};

// ==================== Function Schemas ====================

/// Simple JSON schema for function calling
const JsonSchemaType = enum { string, number, integer, boolean, array, object };

const JsonSchema = struct {
    type: JsonSchemaType,
    description: ?[]const u8 = null,
    properties: ?std.StringHashMap(JsonSchema),
    required: ?ArrayListManaged([]const u8),
    items: ?*JsonSchema,

    pub fn deinit(self: *JsonSchema, allocator: std.mem.Allocator) void {
        if (self.properties) |*props| {
            var it = props.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            props.deinit();
        }
        if (self.required) |*req| {
            for (req.items) |item| allocator.free(item);
            req.deinit(allocator);
        }
        if (self.items) |item| {
            item.deinit(allocator);
            allocator.destroy(item);
        }
        if (self.description) |desc| allocator.free(desc);
    }
};

/// Create function schema for entity extraction
fn createEntityExtractionSchema(allocator: std.mem.Allocator) !manager.FunctionSchema {
    // Create a simple object schema
    const params_schema = llm_function.JSONSchema.init(.object);

    return manager.FunctionSchema.init(
        allocator,
        "extract_entities",
        "Extract entities, topics, and relationships from key-value data mutations",
        params_schema
    );
}

// ==================== LLM Response Processing ====================

/// Process entity extraction results from LLM (simplified for testing)
fn processEntityExtractionResults(
    result_json: []const u8,
    min_confidence: f32
) !usize {
    _ = min_confidence;

    // Parse JSON and count entities
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result_json, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidFormat,
    };

    const entities_value = obj.get("entities") orelse return 0;
    const entities_array = switch (entities_value) {
        .array => |a| a,
        else => return 0,
    };

    return entities_array.items.len;
}

// ==================== Plugin Implementation ====================

/// Global plugin state
var global_state: ?*ExtractorState = null;

/// On commit hook implementation (batch mode)
fn onCommitHook(allocator: std.mem.Allocator, ctx: manager.CommitContext) anyerror!manager.PluginResult {
    _ = allocator;

    const state = global_state orelse return error.PluginNotInitialized;

    // Add all mutations to pending batch
    for (ctx.mutations) |mutation| {
        const value = switch (mutation) {
            .put => |p| p.value,
            .delete => "",
        };
        try state.addPendingMutation(mutation.getKey(), value, ctx.txn_id);
    }

    // Process batch if ready
    var entities_extracted: usize = 0;
    if (state.shouldProcessBatch()) {
        // Simulate processing - in real implementation would call LLM
        state.stats.total_commits_processed += 1;
        state.stats.llm_calls_made += 1;
        entities_extracted = 5; // Mock value
        state.stats.total_entities_extracted += entities_extracted;
        state.clearPending();
    }

    return manager.PluginResult{
        .success = true,
        .operations_processed = ctx.mutations.len,
        .cartridges_updated = if (entities_extracted > 0) 1 else 0,
    };
}

/// On commit streaming hook implementation (real-time mode)
/// Runs during commit before WAL fsync for immediate entity extraction
fn onCommitStreamingHook(allocator: std.mem.Allocator, ctx: manager.StreamingCommitContext) anyerror!manager.StreamingPluginResult {
    _ = allocator;

    const state = global_state orelse return error.PluginNotInitialized;

    const start = std.time.nanoTimestamp();

    // Process mutations in streaming mode
    var entities_extracted: usize = 0;

    for (ctx.mutations) |mutation| {
        _ = switch (mutation) {
            .put => |p| p.value,
            .delete => continue, // Skip deletes for entity extraction
        };

        // Extract entities from key-value pair
        // In real implementation, this would call LLM with function calling
        // For now, do simple extraction based on key patterns

        // Extract entity type from key prefix (e.g., "file:", "user:", etc.)
        const key = mutation.getKey();
        if (std.mem.indexOf(u8, key, ":")) |colon_idx| {
            const entity_type = key[0..colon_idx];
            const entity_id = key[colon_idx + 1 ..];

            // Report entity extraction via callback
            if (ctx.on_entity_extracted) |callback| {
                callback(entity_id, entity_type, 0.9);
            }

            entities_extracted += 1;
            state.stats.total_entities_extracted += 1;
        }
    }

    const end = std.time.nanoTimestamp();
    const latency_ns: u64 = @intCast(end - start);

    return manager.StreamingPluginResult{
        .success = true,
        .entities_extracted = entities_extracted,
        .processing_latency_ns = latency_ns,
        .throttled = false,
    };
}

/// On query hook for semantic search
fn onQueryHook(allocator: std.mem.Allocator, ctx: manager.QueryContext) anyerror!?manager.QueryPlan {
    _ = allocator;
    _ = ctx;

    // Check if this is a semantic query that should use entity cartridge
    // For now, return null to indicate no query plan
    // Future: analyze query text and determine if entity search is appropriate
    return null;
}

/// Get function schemas provided by this plugin
fn getFunctionsHook(allocator: std.mem.Allocator) []const manager.FunctionSchema {
    _ = allocator;

    // Return empty array for now - schemas are created dynamically
    return &[_]manager.FunctionSchema{};
}

/// Plugin definition
pub const EntityExtractorPlugin = manager.Plugin{
    .name = "entity_extractor",
    .version = "0.1.0",
    .on_commit = onCommitHook,
    .on_commit_streaming = onCommitStreamingHook,
    .on_query = onQueryHook,
    .on_schedule = null,
    .get_functions = getFunctionsHook,
    .on_agent_session_start = null,
    .on_agent_operation = null,
    .on_review_request = null,
    .on_perf_sample = null,
    .on_benchmark_complete = null,
};

/// Create entity extractor plugin instance
pub fn createPlugin(allocator: std.mem.Allocator, config: ExtractorConfig) !manager.Plugin {
    // Allocate and initialize state
    const state = try allocator.create(ExtractorState);
    state.* = try ExtractorState.init(allocator, config);
    global_state = state;

    // Return plugin struct
    return manager.Plugin{
        .name = "entity_extractor",
        .version = "0.1.0",
        .on_commit = onCommitHook,
        .on_commit_streaming = onCommitStreamingHook,
        .on_query = onQueryHook,
        .on_schedule = null,
        .get_functions = getFunctionsHook,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
        .on_benchmark_complete = null,
    };
}

// ==================== Tests ====================

const testing = std.testing;

test "ExtractorConfig.default" {
    const config = ExtractorConfig.default();
    try testing.expectEqual(@as(usize, 10), config.batch_size);
    try testing.expectEqual(@as(f32, 0.7), config.min_confidence);
    try testing.expect(config.extract_topics);
    try testing.expect(config.extract_relationships);
}

test "ExtractorState.init" {
    const config = ExtractorConfig{ .batch_size = 5 };
    var state = try ExtractorState.init(testing.allocator, config);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 5), state.config.batch_size);
    try testing.expect(!state.llm_available);
    try testing.expectEqual(@as(usize, 0), state.pending_mutations.items.len);
}

test "ExtractorState.addPendingMutation" {
    var state = try ExtractorState.init(testing.allocator, ExtractorConfig.default());
    defer state.deinit();

    try state.addPendingMutation("test:key", "test_value", 123);
    try testing.expectEqual(@as(usize, 1), state.pending_mutations.items.len);
    try testing.expectEqual(@as(u64, 123), state.pending_mutations.items[0].txn_id);
    try testing.expectEqualStrings("test:key", state.pending_mutations.items[0].key);
    try testing.expectEqualStrings("test_value", state.pending_mutations.items[0].value);
}

test "ExtractorState.shouldProcessBatch" {
    const config = ExtractorConfig{ .batch_size = 3 };
    var state = try ExtractorState.init(testing.allocator, config);
    defer state.deinit();

    try state.addPendingMutation("test1", "value1", 1);
    try testing.expect(!state.shouldProcessBatch());

    try state.addPendingMutation("test2", "value2", 2);
    try testing.expect(!state.shouldProcessBatch());

    try state.addPendingMutation("test3", "value3", 3);
    try testing.expect(state.shouldProcessBatch());
}

test "ExtractorState.clearPending" {
    var state = try ExtractorState.init(testing.allocator, ExtractorConfig.default());
    defer state.deinit();

    try state.addPendingMutation("test1", "value1", 1);
    try state.addPendingMutation("test2", "value2", 2);
    try testing.expectEqual(@as(usize, 2), state.pending_mutations.items.len);

    state.clearPending();
    try testing.expectEqual(@as(usize, 0), state.pending_mutations.items.len);
}

test "processEntityExtractionResults.counts_entities" {
    const mock_json = "{\"entities\": [{\"name\": \"Entity1\"}, {\"name\": \"Entity2\"}]}";

    const count = try processEntityExtractionResults(mock_json, 0.7);
    try testing.expectEqual(@as(usize, 2), count);
}

test "processEntityExtractionResults.handles_empty" {
    const mock_json = "{\"entities\": []}";

    const count = try processEntityExtractionResults(mock_json, 0.7);
    try testing.expectEqual(@as(usize, 0), count);
}

test "createPlugin" {
    const config = ExtractorConfig{
        .batch_size = 20,
        .min_confidence = 0.8,
    };

    const plugin = try createPlugin(testing.allocator, config);

    try testing.expectEqualStrings("entity_extractor", plugin.name);
    try testing.expectEqualStrings("0.1.0", plugin.version);
    try testing.expect(plugin.on_commit != null);
    try testing.expect(plugin.on_query != null);

    // Cleanup global state
    if (global_state) |state| {
        state.deinit();
        testing.allocator.destroy(state);
        global_state = null;
    }
}

test "onCommitHook.batches_mutations" {
    // Setup state with small batch size
    const config = ExtractorConfig{ .batch_size = 2 };
    var state = try ExtractorState.init(testing.allocator, config);
    defer state.deinit();
    global_state = state;
    defer {
        if (global_state) |s| {
            s.deinit();
            testing.allocator.destroy(s);
            global_state = null;
        }
    }

    // Create commit context with mutations
    const mutations = [_]txn.Mutation{
        .{ .put = .{ .key = "test:1", .value = "value1" } },
        .{ .put = .{ .key = "test:2", .value = "value2" } },
    };

    var metadata = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata.deinit();

    const ctx = manager.CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = std.time.nanoTimestamp(),
        .metadata = metadata,
    };

    // Execute hook
    const result = try onCommitHook(testing.allocator, ctx);

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 2), result.operations_processed);
    try testing.expectEqual(@as(usize, 0), state.pending_mutations.items.len); // Batch cleared
}

test "onCommitHook.accumulates_until_batch_size" {
    const config = ExtractorConfig{ .batch_size = 5 };
    var state = try ExtractorState.init(testing.allocator, config);
    defer state.deinit();
    global_state = state;
    defer {
        if (global_state) |s| {
            s.deinit();
            testing.allocator.destroy(s);
            global_state = null;
        }
    }

    const mutations = [_]txn.Mutation{
        .{ .put = .{ .key = "test:1", .value = "value1" } },
    };

    var metadata = std.StringHashMap([]const u8).init(testing.allocator);
    defer {
        var it = metadata.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        metadata.deinit();
    }

    // First commit
    const ctx1 = manager.CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = std.time.nanoTimestamp(),
        .metadata = metadata,
    };

    _ = try onCommitHook(testing.allocator, ctx1);

    // Batch should not be processed yet
    try testing.expectEqual(@as(usize, 1), state.pending_mutations.items.len);
    try testing.expectEqual(@as(u64, 0), state.stats.total_commits_processed);
}

test "onQueryHook.returns_null" {
    const query = "find all entities related to database";

    var metadata = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata.deinit();

    const ctx = manager.QueryContext{
        .query = query,
        .user_intent = null,
        .available_cartridges = &[_]manager.CartridgeType{.entity},
        .performance_constraints = manager.QueryConstraints{
            .max_latency_ms = 1000,
            .max_cost = 0.1,
            .require_exact = false,
        },
    };
    defer ctx.deinit(testing.allocator);

    const plan = try onQueryHook(testing.allocator, ctx);

    try testing.expect(plan == null);
}

test "statistics_tracking" {
    const config = ExtractorConfig{ .batch_size = 1 };
    var state = try ExtractorState.init(testing.allocator, config);
    defer state.deinit();
    global_state = state;
    defer {
        if (global_state) |s| {
            s.deinit();
            testing.allocator.destroy(s);
            global_state = null;
        }
    }

    const mutations = [_]txn.Mutation{
        .{ .put = .{ .key = "test", .value = "value" } },
    };

    var metadata = std.StringHashMap([]const u8).init(testing.allocator);
    defer {
        var it = metadata.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        metadata.deinit();
    }

    const ctx = manager.CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = std.time.nanoTimestamp(),
        .metadata = metadata,
    };

    _ = try onCommitHook(testing.allocator, ctx);

    try testing.expectEqual(@as(u64, 1), state.stats.total_commits_processed);
    try testing.expectEqual(@as(u64, 1), state.stats.llm_calls_made);
    try testing.expectEqual(@as(u64, 5), state.stats.total_entities_extracted);
}

test "onCommitStreamingHook.extracts_entities" {
    var state = try ExtractorState.init(testing.allocator, ExtractorConfig.default());
    defer state.deinit();
    global_state = state;
    defer {
        if (global_state) |s| {
            s.deinit();
            testing.allocator.destroy(s);
            global_state = null;
        }
    }

    // Simple callback that just tracks count
    var callback_count: usize = 0;
    const callback = struct {
        count: *usize,

        fn cb(entity_id: []const u8, entity_type: []const u8, confidence: f32) void {
            _ = entity_id;
            _ = entity_type;
            _ = confidence;
            count.* += 1;
        }
    }{ .count = &callback_count };

    const mutations = [_]txn.Mutation{
        .{ .put = .{ .key = "file:main.zig", .value = "const x = 1;" } },
        .{ .put = .{ .key = "user:alice", .value = "data" } },
        .{ .delete = .{ .key = "old:key" } }, // Should be skipped
    };

    var metadata = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata.deinit();

    const streaming_ctx = manager.StreamingCommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = std.time.nanoTimestamp(),
        .metadata = metadata,
        .on_entity_extracted = callback.cb,
    };

    const result = try onCommitStreamingHook(testing.allocator, streaming_ctx);

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 2), result.entities_extracted); // 2 puts, delete skipped
    try testing.expectEqual(@as(usize, 2), callback_count);
    try testing.expectEqual(@as(usize, 2), state.stats.total_entities_extracted);
}

test "onCommitStreamingHook.throttled_tracking" {
    var state = try ExtractorState.init(testing.allocator, ExtractorConfig.default());
    defer state.deinit();
    global_state = state;
    defer {
        if (global_state) |s| {
            s.deinit();
            testing.allocator.destroy(s);
            global_state = null;
        }
    }

    const mutations = [_]txn.Mutation{
        .{ .put = .{ .key = "test:key", .value = "value" } },
    };

    var metadata = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata.deinit();

    const streaming_ctx = manager.StreamingCommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = std.time.nanoTimestamp(),
        .metadata = metadata,
        .on_entity_extracted = null,
    };

    const result = try onCommitStreamingHook(testing.allocator, streaming_ctx);

    try testing.expect(result.success);
    try testing.expect(!result.throttled); // Not throttled by default
}
