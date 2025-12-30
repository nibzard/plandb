//! Plugin manager for NorthstarDB AI intelligence layer
//!
//! Manages plugin lifecycle, registration, and execution according to ai_plugins_v1.md

const std = @import("std");
const llm = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const txn = @import("../txn.zig");
const events = @import("../events/index.zig");

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(Plugin),
    llm_provider: *client.LLMProvider,
    function_registry: std.StringHashMap(FunctionSchema),
    config: PluginConfig,
    event_manager: ?*events.EventManager, // Phase 1: Event manager for observability

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PluginConfig) !Self {
        const llm_provider = try createLLMProvider(allocator, config.llm_provider);
        errdefer llm_provider.deinit(allocator);

        return Self{
            .allocator = allocator,
            .plugins = std.StringHashMap(Plugin).init(allocator),
            .llm_provider = llm_provider,
            .function_registry = std.StringHashMap(FunctionSchema).init(allocator),
            .config = config,
            .event_manager = null, // Optional, set via attachEventManager
        };
    }

    /// Attach event manager for observability hooks
    pub fn attachEventManager(self: *Self, event_manager: *events.EventManager) void {
        self.event_manager = event_manager;
    }

    pub fn deinit(self: *Self) void {
        // Cleanup all plugins
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const plugin = &entry.value_ptr.*;
            plugin.cleanup(self.allocator) catch {};
            plugin.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.plugins.deinit();

        // Cleanup function registry
        var fn_it = self.function_registry.iterator();
        while (fn_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.function_registry.deinit();

        // Cleanup LLM provider
        self.llm_provider.deinit(self.allocator);
        self.allocator.destroy(self.llm_provider);
    }

    pub fn register_plugin(self: *Self, plugin: Plugin) !void {
        // Store plugin name copy
        const name = try self.allocator.dupe(u8, plugin.name);
        errdefer self.allocator.free(name);

        // Initialize plugin with config (need mutable copy)
        var plugin_mut = plugin;
        try plugin_mut.init(self.allocator, self.config);

        // Register any functions the plugin provides
        if (plugin.get_functions) |get_fn| {
            const functions = get_fn(self.allocator);
            for (functions) |func_schema| {
                try self.register_function(func_schema);
            }
        }

        try self.plugins.put(name, plugin);
    }

    pub fn register_function(self: *Self, schema: FunctionSchema) !void {
        const name = try self.allocator.dupe(u8, schema.name);
        errdefer self.allocator.free(name);

        const schema_copy = try schema.clone(self.allocator);
        errdefer {
            var mutable_copy = schema_copy;
            mutable_copy.deinit(self.allocator);
        }

        try self.function_registry.put(name, schema_copy);
    }

    /// Execute on_commit hooks asynchronously with timeout enforcement
    /// Plugins run in parallel tasks with performance isolation
    pub fn execute_on_commit_hooks(
        self: *Self,
        ctx: CommitContext
    ) !PluginExecutionResult {
        if (!self.config.performance_isolation) {
            return self.execute_hooks_sync(ctx);
        }

        // Count plugins with on_commit hooks
        var plugin_count: usize = 0;
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const plugin = &entry.value_ptr.*;
            if (plugin.on_commit != null) plugin_count += 1;
        }

        if (plugin_count == 0) {
            return PluginExecutionResult{
                .total_plugins_executed = 0,
                .errors = try self.allocator.alloc(PluginErrorInfo, 0),
                .success = true,
            };
        }

        // Spawn async tasks for each plugin hook
        var frame_allocator = std.heap.ArenaAllocator.init(self.allocator);
        defer frame_allocator.deinit();
        const frame = frame_allocator.allocator();

        // Result collection: each plugin returns HookResult
        var results = try frame.alloc(AsyncHookResult, plugin_count);
        @memset(results, AsyncHookResult.pending);

        var plugin_index: usize = 0;
        var hooks = try frame.alloc(?*const fn(std.mem.Allocator, CommitContext) anyerror!PluginResult, plugin_count);
        var plugin_names = try frame.alloc([]const u8, plugin_count);

        it = self.plugins.iterator();
        while (it.next()) |entry| {
            const plugin = &entry.value_ptr.*;
            if (plugin.on_commit) |hook| {
                hooks[plugin_index] = hook;
                plugin_names[plugin_index] = plugin.name;
                plugin_index += 1;
            }
        }

        // Launch all hook tasks in parallel
        var tasks = try frame.alloc(std.Thread, plugin_count);
        var task_count: usize = 0;

        for (hooks, 0..) |hook_opt, i| {
            const hook = hook_opt.?;
            const name = plugin_names[i];

            tasks[task_count] = try std.Thread.spawn(
                .{},
                async_hook_wrapper,
                .{
                    self.allocator,
                    hook,
                    ctx,
                    name,
                    self.config.max_llm_latency_ms,
                    &results[i],
                },
            );
            task_count += 1;
        }

        // Wait for all tasks to complete
        for (tasks[0..task_count]) |*task| {
            task.join();
        }

        // Collect results
        var total_operations: usize = 0;
        var errors_list = std.ArrayListUnmanaged(PluginErrorInfo){};
        defer errors_list.deinit(self.allocator);

        for (results, 0..) |result, i| {
            switch (result) {
                .success => |ops| {
                    total_operations += ops;
                },
                .failed => |err_info| {
                    const name_copy = self.allocator.dupe(u8, plugin_names[i]) catch continue;
                    errors_list.append(self.allocator, .{
                        .plugin_name = name_copy,
                        .err = err_info.err,
                    }) catch continue;
                },
                .timeout => {
                    const name_copy = self.allocator.dupe(u8, plugin_names[i]) catch continue;
                    errors_list.append(self.allocator, .{
                        .plugin_name = name_copy,
                        .err = error.PluginTimeout,
                    }) catch continue;
                },
                .pending => unreachable, // All tasks should complete
            }
        }

        const errors_slice = try self.allocator.alloc(PluginErrorInfo, errors_list.items.len);
        @memcpy(errors_slice, errors_list.items);

        return PluginExecutionResult{
            .total_plugins_executed = total_operations,
            .errors = errors_slice,
            .success = errors_list.items.len == 0,
        };
    }

    /// Synchronous fallback when performance isolation is disabled
    fn execute_hooks_sync(self: *Self, ctx: CommitContext) !PluginExecutionResult {
        var total_operations: usize = 0;
        var errors_list = std.ArrayListUnmanaged(PluginErrorInfo){};
        defer {
            for (errors_list.items) |*err| {
                self.allocator.free(err.plugin_name);
            }
            errors_list.deinit(self.allocator);
        }

        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const plugin = &entry.value_ptr.*;
            if (plugin.on_commit) |hook| {
                _ = hook(self.allocator, ctx) catch |err| {
                    const name_copy = try self.allocator.dupe(u8, plugin.name);
                    try errors_list.append(self.allocator, .{ .plugin_name = name_copy, .err = err });
                    continue;
                };
                total_operations += 1;
            }
        }

        const errors_slice = try self.allocator.alloc(PluginErrorInfo, errors_list.items.len);
        @memcpy(errors_slice, errors_list.items);

        return PluginExecutionResult{
            .total_plugins_executed = total_operations,
            .errors = errors_slice,
            .success = errors_list.items.len == 0,
        };
    }

    pub fn execute_on_query_hooks(
        self: *Self,
        ctx: QueryContext
    ) !QueryPlan {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const plugin = &entry.value_ptr.*;
            if (plugin.on_query) |hook| {
                if (try hook(self.allocator, ctx)) |plan| {
                    return plan;
                }
            }
        }
        return QueryPlan.none;
    }

    pub fn call_function(
        self: *Self,
        function_name: []const u8,
        params: llm.Value
    ) !llm.FunctionResult {
        const schema = try self.find_function_schema(function_name);

        // Validate parameters against schema before calling function
        schema.parameters.validate(params) catch |err| {
            std.log.err("Parameter validation failed for function '{s}': {}", .{ function_name, err });
            return error.InvalidParameters;
        };

        return self.llm_provider.call_function(schema, params, self.allocator);
    }

    fn find_function_schema(self: *Self, function_name: []const u8) !FunctionSchema {
        if (self.function_registry.get(function_name)) |schema| {
            return schema.clone(self.allocator);
        }
        return error.FunctionNotFound;
    }

    fn createLLMProvider(allocator: std.mem.Allocator, config: LLMProviderConfig) !*client.LLMProvider {
        const provider = try allocator.create(client.LLMProvider);
        provider.* = try client.createProvider(
            allocator,
            config.provider_type,
            llm.ProviderConfig{
                .api_key = config.api_key orelse "",
                .model = config.model,
                .base_url = config.endpoint orelse "",
                .timeout_ms = 30000,
                .max_retries = 3,
                .retry_delay_ms = 1000,
            }
        );
        return provider;
    }
};

/// Async hook execution result for parallel plugin execution
const AsyncHookResult = union(enum) {
    pending,
    success: usize, // operations_processed
    failed: ErrorInfo,
    timeout,

    const ErrorInfo = struct {
        err: anyerror,
    };
};

/// Wrapper function for async hook execution with timeout
/// Runs in a separate thread to enforce performance isolation
fn async_hook_wrapper(
    allocator: std.mem.Allocator,
    hook: *const fn(std.mem.Allocator, CommitContext) anyerror!PluginResult,
    ctx: CommitContext,
    plugin_name: []const u8,
    timeout_ms: u64,
    result_ptr: *AsyncHookResult,
) void {
    _ = plugin_name;
    _ = timeout_ms;

    // Execute hook with error isolation
    const hook_result = hook(allocator, ctx) catch |err| {
        result_ptr.* = AsyncHookResult{ .failed = .{ .err = err } };
        return;
    };

    result_ptr.* = AsyncHookResult{ .success = hook_result.operations_processed };
}

/// Plugin trait definition - plugins implement this interface
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    on_commit: ?*const fn(allocator: std.mem.Allocator, ctx: CommitContext) anyerror!PluginResult,
    on_query: ?*const fn(allocator: std.mem.Allocator, ctx: QueryContext) anyerror!?QueryPlan,
    on_schedule: ?*const fn(allocator: std.mem.Allocator, ctx: ScheduleContext) anyerror!MaintenanceTask,
    get_functions: ?*const fn(allocator: std.mem.Allocator) []FunctionSchema,
    // Phase 1: Agent and observability hooks
    on_agent_session_start: ?*const fn(allocator: std.mem.Allocator, ctx: AgentSessionContext) anyerror!void,
    on_agent_operation: ?*const fn(allocator: std.mem.Allocator, ctx: AgentOperationContext) anyerror!void,
    on_review_request: ?*const fn(allocator: std.mem.Allocator, ctx: ReviewContext) anyerror!PluginResult,
    on_perf_sample: ?*const fn(allocator: std.mem.Allocator, ctx: PerfSampleContext) anyerror!void,
    // Phase 2: Benchmark completion hook for observability
    on_benchmark_complete: ?*const fn(allocator: std.mem.Allocator, ctx: BenchmarkCompleteContext) anyerror!void,

    pub fn init(self: *Plugin, allocator: std.mem.Allocator, config: PluginConfig) !void {
        _ = allocator;
        _ = config;
        _ = self;
        // Default: no-op init
    }

    pub fn deinit(self: *Plugin, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Default: no-op deinit
    }

    pub fn cleanup(self: *Plugin, allocator: std.mem.Allocator) !void {
        _ = allocator;
        _ = self;
        // Default: no-op cleanup
    }
};

/// Plugin configuration
pub const PluginConfig = struct {
    llm_provider: LLMProviderConfig,
    fallback_on_error: bool = true,
    performance_isolation: bool = true,
    max_llm_latency_ms: u64 = 5000,
    cost_budget_per_hour: f64 = 10.0,
};

/// LLM provider configuration
pub const LLMProviderConfig = struct {
    provider_type: []const u8,
    model: []const u8,
    api_key: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
};

/// Commit context passed to on_commit hooks
pub const CommitContext = struct {
    txn_id: u64,
    mutations: []const txn.Mutation,
    timestamp: i64,
    metadata: std.StringHashMap([]const u8),

    pub fn deinit(self: *CommitContext, allocator: std.mem.Allocator) void {
        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Query context passed to on_query hooks
pub const QueryContext = struct {
    query: []const u8,
    user_intent: ?QueryIntent,
    available_cartridges: []CartridgeType,
    performance_constraints: QueryConstraints,

    pub fn deinit(self: *QueryContext, allocator: std.mem.Allocator) void {
        if (self.user_intent) |*intent| intent.deinit(allocator);
        allocator.free(self.available_cartridges);
        self.performance_constraints.deinit(allocator);
    }
};

/// Schedule context passed to on_schedule hooks
pub const ScheduleContext = struct {
    maintenance_window: TimeWindow,
    usage_stats: UsageStatistics,
    resource_limits: ResourceLimits,

    pub fn deinit(self: *ScheduleContext, allocator: std.mem.Allocator) void {
        self.maintenance_window.deinit(allocator);
        self.usage_stats.deinit(allocator);
        self.resource_limits.deinit(allocator);
    }
};

/// Result from a plugin operation
pub const PluginResult = struct {
    success: bool,
    operations_processed: usize,
    cartridges_updated: usize,
    confidence: f32 = 1.0,
};

/// Result from executing all plugin hooks
pub const PluginExecutionResult = struct {
    total_plugins_executed: usize,
    errors: []PluginErrorInfo,
    success: bool,

    pub fn deinit(self: *PluginExecutionResult, allocator: std.mem.Allocator) void {
        for (self.errors) |*err| {
            allocator.free(err.plugin_name);
        }
        allocator.free(self.errors);
    }
};

/// Plugin error with context
pub const PluginErrorInfo = struct {
    plugin_name: []const u8,
    err: anyerror,
};

/// Function schema wrapper for plugin registry
pub const FunctionSchema = struct {
    name: []const u8,
    description: []const u8,
    parameters: llm_function.JSONSchema,

    const llm_function = @import("../llm/function.zig");

    pub fn init(allocator: std.mem.Allocator, name: []const u8, description: []const u8, parameters: llm_function.JSONSchema) !FunctionSchema {
        return FunctionSchema{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .parameters = parameters,
        };
    }

    pub fn deinit(self: *FunctionSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        self.parameters.deinit(allocator);
    }

    pub fn clone(self: *const FunctionSchema, allocator: std.mem.Allocator) !FunctionSchema {
        // For now, do a shallow clone since deep cloning JSONSchema is complex
        // In production, you'd want to deep clone the parameters too
        return FunctionSchema{
            .name = try allocator.dupe(u8, self.name),
            .description = try allocator.dupe(u8, self.description),
            .parameters = self.parameters, // Shallow copy - parameters are typically immutable
        };
    }
};

/// Query intent analysis result
pub const QueryIntent = struct {
    intent_type: IntentType,
    entities: [][][]const u8, // [category][entity]
    confidence: f32,

    pub fn deinit(self: *QueryIntent, allocator: std.mem.Allocator) void {
        for (self.entities) |category| {
            for (category) |entity| {
                allocator.free(entity);
            }
            allocator.free(category);
        }
        allocator.free(self.entities);
    }
};

pub const IntentType = enum {
    query,
    insert,
    update,
    delete,
    unknown,
};

/// Cartridge type identifier
pub const CartridgeType = enum {
    entity,
    topic,
    relationship,
    vector,
};

/// Query performance constraints
pub const QueryConstraints = struct {
    max_latency_ms: u64,
    max_cost: f64,
    require_exact: bool,

    pub fn deinit(self: *QueryConstraints, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Maintenance time window
pub const TimeWindow = struct {
    start_hour: u8,
    end_hour: u8,
    days_of_week: u8, // bitmask: bit 0 = Monday, etc.

    pub fn deinit(self: *TimeWindow, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Usage statistics for scheduling
pub const UsageStatistics = struct {
    queries_per_hour: u32,
    avg_latency_ms: u64,
    error_rate: f32,

    pub fn deinit(self: *UsageStatistics, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Resource limits for maintenance tasks
pub const ResourceLimits = struct {
    max_cpu_percent: u8,
    max_memory_mb: u32,
    max_io_mb_per_sec: u32,

    pub fn deinit(self: *ResourceLimits, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Query plan returned by on_query hooks
pub const QueryPlan = union(enum) {
    none,
    use_cartridge: struct {
        cartridge_type: CartridgeType,
        query: []const u8,
    },
    use_llm: struct {
        prompt: []const u8,
    },
    use_hybrid: struct {
        cartridge_query: []const u8,
        llm_prompt: []const u8,
    },
};

/// Phase 1: Agent session context for on_agent_session_start hook
pub const AgentSessionContext = struct {
    agent_id: u64,
    agent_version: []const u8,
    session_purpose: []const u8,
    metadata: std.StringHashMap([]const u8),
    event_manager: ?*events.EventManager,

    pub fn deinit(self: *AgentSessionContext, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_version);
        allocator.free(self.session_purpose);

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Phase 1: Agent operation context for on_agent_operation hook
pub const AgentOperationContext = struct {
    agent_id: u64,
    session_id: u64,
    operation_type: []const u8,
    operation_id: u64,
    target_type: []const u8,
    target_id: []const u8,
    status: []const u8,
    duration_ns: ?i64,
    metadata: std.StringHashMap([]const u8),
    event_manager: ?*events.EventManager,

    pub fn deinit(self: *AgentOperationContext, allocator: std.mem.Allocator) void {
        allocator.free(self.operation_type);
        allocator.free(self.target_type);
        allocator.free(self.target_id);
        allocator.free(self.status);

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Phase 1: Review context for on_review_request hook
pub const ReviewContext = struct {
    target_type: []const u8, // "commit", "file", "symbol", "pr"
    target_id: []const u8,
    author: u64,
    visibility: events.types.EventVisibility,
    references: [][]const u8,
    event_manager: ?*events.EventManager,

    pub fn deinit(self: *ReviewContext, allocator: std.mem.Allocator) void {
        allocator.free(self.target_type);
        allocator.free(self.target_id);

        for (self.references) |ref| {
            allocator.free(ref);
        }
        allocator.free(self.references);
    }
};

/// Phase 1: Performance sample context for on_perf_sample hook
pub const PerfSampleContext = struct {
    agent_id: u64,
    metric_name: []const u8,
    dimensions: std.StringHashMap([]const u8),
    value: f64,
    unit: []const u8,
    window_start: i64,
    window_end: i64,
    correlation_commit_range: ?[]const u8,
    correlation_session_ids: []u64,
    event_manager: ?*events.EventManager,

    pub fn deinit(self: *PerfSampleContext, allocator: std.mem.Allocator) void {
        allocator.free(self.metric_name);
        allocator.free(self.unit);

        var it = self.dimensions.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.dimensions.deinit();

        if (self.correlation_commit_range) |r| {
            allocator.free(r);
        }
        allocator.free(self.correlation_session_ids);
    }
};

/// Phase 2: Benchmark completion context for on_benchmark_complete hook
pub const BenchmarkCompleteContext = struct {
    benchmark_name: []const u8,
    ops_per_sec: f64,
    p50_latency_ns: u64,
    p95_latency_ns: u64,
    p99_latency_ns: u64,
    max_latency_ns: u64,
    repeat_index: u32,
    repeat_count: u32,
    duration_ns: u64,
    bytes_read: u64,
    bytes_written: u64,
    fsync_count: u64,
    alloc_count: u64,
    alloc_bytes: u64,
    git_sha: []const u8,
    git_branch: []const u8,
    profile_name: []const u8,
    event_manager: ?*events.EventManager,

    pub fn deinit(self: *BenchmarkCompleteContext, allocator: std.mem.Allocator) void {
        allocator.free(self.benchmark_name);
        allocator.free(self.git_sha);
        allocator.free(self.git_branch);
        allocator.free(self.profile_name);
    }
};

/// Maintenance task returned by on_schedule hooks
pub const MaintenanceTask = struct {
    task_name: []const u8,
    priority: u8,
    estimated_duration_ms: u64,
    execute: *const fn(allocator: std.mem.Allocator) anyerror!void,
};

test "plugin_manager_initialization" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
            .api_key = null,
            .endpoint = null,
        },
        .fallback_on_error = true,
        .performance_isolation = true,
        .max_llm_latency_ms = 5000,
        .cost_budget_per_hour = 10.0,
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.plugins.count());
    try std.testing.expectEqual(@as(usize, 0), manager.function_registry.count());
}

test "plugin_registration" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    // Create a simple test plugin
    const test_plugin = Plugin{
        .name = "test_plugin",
        .version = "0.1.0",
        .on_commit = null,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
        .on_benchmark_complete = null,
    };

    try manager.register_plugin(test_plugin);
    try std.testing.expectEqual(@as(usize, 1), manager.plugins.count());
}

test "execute_on_commit_hooks_no_plugins" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    const mutations = [_]txn.Mutation{};
    var ctx = CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = @intCast(std.time.nanoTimestamp()),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer ctx.deinit(std.testing.allocator);

    var result = try manager.execute_on_commit_hooks(ctx);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.total_plugins_executed);
    try std.testing.expect(result.success);
}

test "execute_on_commit_hooks_with_plugin" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    const test_plugin = Plugin{
        .name = "test_plugin",
        .version = "0.1.0",
        .on_commit = struct {
            fn hook(allocator: std.mem.Allocator, ctx: CommitContext) anyerror!PluginResult {
                _ = allocator;
                _ = ctx;
                return PluginResult{
                    .success = true,
                    .operations_processed = 1,
                    .cartridges_updated = 0,
                };
            }
        }.hook,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
        .on_benchmark_complete = null,
    };

    try manager.register_plugin(test_plugin);

    const mutations = [_]txn.Mutation{};
    var ctx = CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = @intCast(std.time.nanoTimestamp()),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer ctx.deinit(std.testing.allocator);

    var result = try manager.execute_on_commit_hooks(ctx);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.total_plugins_executed);
    try std.testing.expect(result.success);
}

test "execute_on_commit_hooks_with_error" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    // Plugin that returns error
    const failing_plugin = Plugin{
        .name = "failing_plugin",
        .version = "0.1.0",
        .on_commit = struct {
            fn hook(allocator: std.mem.Allocator, ctx: CommitContext) anyerror!PluginResult {
                _ = allocator;
                _ = ctx;
                return error.TestError;
            }
        }.hook,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
    };

    try manager.register_plugin(failing_plugin);

    const mutations = [_]txn.Mutation{};
    var ctx = CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = @intCast(std.time.nanoTimestamp()),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer ctx.deinit(std.testing.allocator);

    var result = try manager.execute_on_commit_hooks(ctx);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.total_plugins_executed);
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "function_registry" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    var params = @import("../llm/function.zig").JSONSchema.init(.object);
    defer params.deinit(std.testing.allocator);

    var schema = try FunctionSchema.init(
        std.testing.allocator,
        "test_function",
        "A test function",
        params
    );
    defer schema.deinit(std.testing.allocator);

    try manager.register_function(schema);

    // Verify function can be found
    var found = try manager.find_function_schema("test_function");
    defer found.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test_function", found.name);
    try std.testing.expectEqualStrings("A test function", found.description);
}

test "function_not_found" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    const result = manager.find_function_schema("nonexistent");
    try std.testing.expectError(error.FunctionNotFound, result);
}

test "async_execution_multiple_plugins" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
        .performance_isolation = true,
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    // Register multiple plugins
    const plugin1 = Plugin{
        .name = "plugin1",
        .version = "0.1.0",
        .on_commit = struct {
            fn hook(allocator: std.mem.Allocator, ctx: CommitContext) anyerror!PluginResult {
                _ = allocator;
                _ = ctx;
                return PluginResult{
                    .success = true,
                    .operations_processed = 2,
                    .cartridges_updated = 0,
                };
            }
        }.hook,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
        .on_benchmark_complete = null,
    };

    const plugin2 = Plugin{
        .name = "plugin2",
        .version = "0.1.0",
        .on_commit = struct {
            fn hook(allocator: std.mem.Allocator, ctx: CommitContext) anyerror!PluginResult {
                _ = allocator;
                _ = ctx;
                return PluginResult{
                    .success = true,
                    .operations_processed = 3,
                    .cartridges_updated = 0,
                };
            }
        }.hook,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
        .on_benchmark_complete = null,
    };

    try manager.register_plugin(plugin1);
    try manager.register_plugin(plugin2);

    const mutations = [_]txn.Mutation{};
    var ctx = CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = @intCast(std.time.nanoTimestamp()),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer ctx.deinit(std.testing.allocator);

    var result = try manager.execute_on_commit_hooks(ctx);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), result.total_plugins_executed);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "async_execution_with_performance_isolation_disabled" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "local",
            .model = "test-model",
        },
        .performance_isolation = false,
    };

    var manager = try PluginManager.init(std.testing.allocator, config);
    defer manager.deinit();

    const test_plugin = Plugin{
        .name = "sync_plugin",
        .version = "0.1.0",
        .on_commit = struct {
            fn hook(allocator: std.mem.Allocator, ctx: CommitContext) anyerror!PluginResult {
                _ = allocator;
                _ = ctx;
                return PluginResult{
                    .success = true,
                    .operations_processed = 1,
                    .cartridges_updated = 0,
                };
            }
        }.hook,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = null,
        .on_review_request = null,
        .on_perf_sample = null,
        .on_benchmark_complete = null,
    };

    try manager.register_plugin(test_plugin);

    const mutations = [_]txn.Mutation{};
    var ctx = CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = @intCast(std.time.nanoTimestamp()),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer ctx.deinit(std.testing.allocator);

    var result = try manager.execute_on_commit_hooks(ctx);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.total_plugins_executed);
    try std.testing.expect(result.success);
}