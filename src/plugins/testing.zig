//! Plugin testing utilities for NorthstarDB AI intelligence layer
//!
//! Provides mock LLM providers, test harness, and debugging tools for plugin development

const std = @import("std");
const llm_types = @import("../llm/types.zig");
const llm_function = @import("../llm/function.zig");
const llm_client = @import("../llm/client.zig");
const manager = @import("manager.zig");

/// Mock LLM provider for deterministic testing
pub const MockLLMProvider = struct {
    allocator: std.mem.Allocator,
    responses: std.ArrayList(FunctionCallMock),
    call_count: usize,
    current_index: usize,

    const Self = @This();

    pub const FunctionCallMock = struct {
        function_name: []const u8,
        arguments: std.json.Value,
        tokens_used: llm_types.TokenUsage,
        simulate_error: ?anyerror = null,
        latency_ms: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .responses = std.ArrayListUnmanaged(FunctionCallMock){},
            .call_count = 0,
            .current_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.responses.deinit(self.allocator);
    }

    /// Add a predetermined response for the next call
    pub fn addResponse(self: *Self, mock: FunctionCallMock) !void {
        try self.responses.append(self.allocator, mock);
    }

    /// Add a simple success response
    pub fn addSimpleResponse(self: *Self, function_name: []const u8, args_json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, args_json, .{});
        const tokens = llm_types.TokenUsage{
            .prompt_tokens = 10,
            .completion_tokens = 5,
            .total_tokens = 15,
        };
        try self.responses.append(self.allocator, .{
            .function_name = function_name,
            .arguments = parsed.value,
            .tokens_used = tokens,
        });
    }

    /// Get call count
    pub fn getCallCount(self: *const Self) usize {
        return self.call_count;
    }

    /// Reset call history
    pub fn reset(self: *Self) void {
        self.call_count = 0;
        self.current_index = 0;
    }

    /// Create entity extraction mock response
    pub fn addEntityExtractionResponse(self: *Self, entities: []const EntityMock) !void {
        var entity_array = std.ArrayListUnmanaged(std.json.Value){};
        defer entity_array.deinit(self.allocator);
        for (entities) |ent| {
            var entity_obj = std.json.ObjectMap.init(self.allocator);
            try entity_obj.put(try self.allocator.dupe(u8, "name"), .{ .string = ent.name });
            try entity_obj.put(try self.allocator.dupe(u8, "type"), .{ .string = ent.type_name });
            try entity_obj.put(try self.allocator.dupe(u8, "confidence"), .{ .float = ent.confidence });
            try entity_array.append(self.allocator, .{ .object = entity_obj });
        }

        var root_obj = std.json.ObjectMap.init(self.allocator);
        var json_array = std.json.Array.init(self.allocator);
        for (entity_array.items) |item| {
            try json_array.append(item);
        }
        try root_obj.put(try self.allocator.dupe(u8, "entities"), .{ .array = json_array });

        try self.responses.append(self.allocator, .{
            .function_name = "extract_entities",
            .arguments = .{ .object = root_obj },
            .tokens_used = .{ .prompt_tokens = 50, .completion_tokens = 30, .total_tokens = 80 },
        });
    }

    pub const EntityMock = struct {
        name: []const u8,
        type_name: []const u8,
        confidence: f32,
    };

    /// Create test harness for plugin testing
    pub fn createTestHarness(self: *Self, config: manager.PluginConfig) !TestHarness {
        return TestHarness.init(self.allocator, self, config);
    }
};

/// Test harness for end-to-end plugin testing
pub const TestHarness = struct {
    allocator: std.mem.Allocator,
    mock_provider: *MockLLMProvider,
    plugin_manager: ?*manager.PluginManager,
    results: std.ArrayListUnmanaged(TestResult),

    const Self = @This();

    pub const TestResult = struct {
        test_name: []const u8,
        passed: bool,
        duration_ns: u64,
        error_message: ?[]const u8,
        llm_calls: usize,

        pub fn deinit(self: *TestResult, allocator: std.mem.Allocator) void {
            allocator.free(self.test_name);
            if (self.error_message) |msg| allocator.free(msg);
        }
    };

    pub fn init(allocator: std.mem.Allocator, mock: *MockLLMProvider, config: manager.PluginConfig) !Self {
        _ = config;
        return Self{
            .allocator = allocator,
            .mock_provider = mock,
            .plugin_manager = null,
            .results = std.ArrayListUnmanaged(TestResult){},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.results.items) |*r| r.deinit(self.allocator);
        self.results.deinit(self.allocator);
        if (self.plugin_manager) |pm| {
            pm.deinit();
            self.allocator.destroy(pm);
        }
    }

    /// Register a plugin for testing
    pub fn registerPlugin(self: *Self, plugin: manager.Plugin) !void {
        if (self.plugin_manager == null) {
            const pm = try self.allocator.create(manager.PluginManager);
            pm.* = try manager.PluginManager.init(self.allocator, .{
                .llm_provider = .{
                    .provider_type = "local",
                    .model = "test-model",
                    .api_key = null,
                    .endpoint = null,
                },
                .fallback_on_error = true,
                .performance_isolation = false,
            });
            self.plugin_manager = pm;
        }
        try self.plugin_manager.?.register_plugin(plugin);
    }

    /// Run a single test case
    pub fn runTest(self: *Self, test_name: []const u8, test_fn: *const fn(*TestHarness) anyerror!void) !void {
        const start = std.time.nanoTimestamp();
        const call_count_before = self.mock_provider.getCallCount();

        const result = test_fn(self) catch |err| {
            const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start));
            try self.results.append(self.allocator, .{
                .test_name = try self.allocator.dupe(u8, test_name),
                .passed = false,
                .duration_ns = duration,
                .error_message = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}),
                .llm_calls = self.mock_provider.getCallCount() - call_count_before,
            });
            return;
        };

        _ = result;
        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start));
        try self.results.append(self.allocator, .{
            .test_name = try self.allocator.dupe(u8, test_name),
            .passed = true,
            .duration_ns = duration,
            .error_message = null,
            .llm_calls = self.mock_provider.getCallCount() - call_count_before,
        });
    }

    /// Get test results summary
    pub fn getSummary(self: *const Self) TestSummary {
        var passed: usize = 0;
        var failed: usize = 0;
        var total_duration: u64 = 0;
        var total_calls: usize = 0;

        for (self.results.items) |r| {
            if (r.passed) passed += 1 else failed += 1;
            total_duration += r.duration_ns;
            total_calls += r.llm_calls;
        }

        return .{
            .total = self.results.items.len,
            .passed = passed,
            .failed = failed,
            .total_duration_ns = total_duration,
            .total_llm_calls = total_calls,
        };
    }

    pub const TestSummary = struct {
        total: usize,
        passed: usize,
        failed: usize,
        total_duration_ns: u64,
        total_llm_calls: usize,
    };

    /// Print results to stdout
    pub fn printResults(self: *const Self) void {
        const summary = self.getSummary();

        std.debug.print("\n=== Plugin Test Results ===\n", .{});
        std.debug.print("Total: {d}, Passed: {d}, Failed: {d}\n", .{
            summary.total, summary.passed, summary.failed
        });
        std.debug.print("Duration: {d}ms, LLM Calls: {d}\n\n", .{
            summary.total_duration_ns / 1_000_000, summary.total_llm_calls
        });

        for (self.results.items) |r| {
            const status = if (r.passed) "PASS" else "FAIL";
            std.debug.print("  [{s}] {s} ({d}ms, {d} calls)\n", .{
                status, r.test_name, r.duration_ns / 1_000_000, r.llm_calls
            });
            if (r.error_message) |msg| {
                std.debug.print("    Error: {s}\n", .{msg});
            }
        }
    }
};

/// Plugin fixture factory for common test scenarios
pub const PluginFixtures = struct {
    /// Create a simple entity extraction plugin for testing
    pub fn createEntityExtractionPlugin(allocator: std.mem.Allocator) manager.Plugin {
        _ = allocator;
        return manager.Plugin{
            .name = "entity_extractor",
            .version = "0.1.0-test",
            .on_commit = struct {
                fn hook(alloc: std.mem.Allocator, ctx: manager.CommitContext) anyerror!manager.PluginResult {
                    _ = alloc;
                    _ = ctx;
                    return manager.PluginResult{
                        .success = true,
                        .operations_processed = 1,
                        .cartridges_updated = 0,
                    };
                }
            }.hook,
            .on_query = null,
            .on_schedule = null,
            .get_functions = null,
        };
    }

    /// Create a plugin that extracts topics from text
    pub fn createTopicExtractionPlugin(allocator: std.mem.Allocator) manager.Plugin {
        _ = allocator;
        return manager.Plugin{
            .name = "topic_extractor",
            .version = "0.1.0-test",
            .on_commit = struct {
                fn hook(alloc: std.mem.Allocator, ctx: manager.CommitContext) anyerror!manager.PluginResult {
                    _ = alloc;
                    _ = ctx;
                    return manager.PluginResult{
                        .success = true,
                        .operations_processed = 1,
                        .cartridges_updated = 1,
                    };
                }
            }.hook,
            .on_query = null,
            .on_schedule = null,
            .get_functions = null,
        };
    }

    /// Create a plugin that provides function schemas
    pub fn createFunctionProvidingPlugin(allocator: std.mem.Allocator) manager.Plugin {
        _ = allocator;
        return manager.Plugin{
            .name = "function_provider",
            .version = "0.1.0-test",
            .on_commit = null,
            .on_query = null,
            .on_schedule = null,
            .get_functions = struct {
                fn get(alloc: std.mem.Allocator) []manager.FunctionSchema {
                    _ = alloc;
                    // Return empty array for now - would be populated with actual schemas
                    return &[_]manager.FunctionSchema{};
                }
            }.get,
        };
    }

    /// Create a failing plugin for error testing
    pub fn createFailingPlugin(allocator: std.mem.Allocator, error_type: anyerror) manager.Plugin {
        _ = allocator;
        _ = error_type;
        return manager.Plugin{
            .name = "failing_plugin",
            .version = "0.1.0-test",
            .on_commit = struct {
                fn hook(alloc: std.mem.Allocator, ctx: manager.CommitContext) anyerror!manager.PluginResult {
                    _ = alloc;
                    _ = ctx;
                    return error.TestPluginFailure;
                }
            }.hook,
            .on_query = null,
            .on_schedule = null,
            .get_functions = null,
        };
    }

    /// Create mock commit context for testing
    pub fn createMockCommitContext(allocator: std.mem.Allocator) manager.CommitContext {
        return manager.CommitContext{
            .txn_id = 1,
            .mutations = &[_]std.meta.Child(manager.CommitContext.Mutations){},
            .timestamp = std.time.nanoTimestamp(),
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }
};

test "mock_llm_provider_basic" {
    var mock = MockLLMProvider.init(std.testing.allocator);
    defer mock.deinit();

    try mock.addSimpleResponse("test_func", "{\"result\": \"success\"}");

    try std.testing.expectEqual(@as(usize, 1), mock.responses.items.len);
    try std.testing.expectEqual(@as(usize, 0), mock.getCallCount());
}

test "mock_llm_provider_entity_extraction" {
    var mock = MockLLMProvider.init(std.testing.allocator);
    defer mock.deinit();

    const entities = [_]MockLLMProvider.EntityMock{
        .{ .name = "Claude", .type_name = "AI", .confidence = 0.95 },
        .{ .name = "Zig", .type_name = "Language", .confidence = 1.0 },
    };

    try mock.addEntityExtractionResponse(&entities);

    try std.testing.expectEqual(@as(usize, 1), mock.responses.items.len);
    try std.testing.expectEqualStrings("extract_entities", mock.responses.items[0].function_name);
}

test "test_harness_basic" {
    var mock = MockLLMProvider.init(std.testing.allocator);
    defer mock.deinit();

    const config = manager.PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test",
        },
    };

    var harness = try mock.createTestHarness(config);
    defer harness.deinit();

    const plugin = PluginFixtures.createEntityExtractionPlugin(std.testing.allocator);
    try harness.registerPlugin(plugin);

    try harness.runTest("sample_test", struct {
        fn testFn(h: *TestHarness) anyerror!void {
            _ = h;
            try std.testing.expect(true);
        }
    }.testFn);

    try std.testing.expectEqual(@as(usize, 1), harness.results.items.len);
    try std.testing.expect(harness.results.items[0].passed);
}

test "plugin_fixtures" {
    const plugin1 = PluginFixtures.createEntityExtractionPlugin(std.testing.allocator);
    try std.testing.expectEqualStrings("entity_extractor", plugin1.name);

    const plugin2 = PluginFixtures.createTopicExtractionPlugin(std.testing.allocator);
    try std.testing.expectEqualStrings("topic_extractor", plugin2.name);

    const ctx = PluginFixtures.createMockCommitContext(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), ctx.txn_id);
}
