//! Multi-model orchestration for intelligent LLM request routing
//!
//! Provides intelligent model selection and request routing:
//! - Task classification for appropriate model selection
//! - Cost-aware routing with performance optimization
//! - Provider load balancing and failover
//! - Automatic fallback and retry mechanisms

const std = @import("std");
const types = @import("types.zig");
const client = @import("client.zig");
const function = @import("function.zig");

/// Task classification for intelligent routing
pub const TaskType = enum {
    /// Simple extraction tasks (entity recognition, keyword extraction)
    simple_extraction,
    /// Complex reasoning tasks (query planning, optimization)
    complex_reasoning,
    /// Security analysis (vulnerability detection, code review)
    security_analysis,
    /// Summarization (context compression, report generation)
    summarization,
    /// General purpose (uncategorized tasks)
    general,
};

/// Task priority for routing decisions
pub const TaskPriority = enum {
    low,
    normal,
    high,
    critical,
};

/// Routing strategy for model selection
pub const RoutingStrategy = enum {
    /// Optimize for lowest cost
    cost_optimized,
    /// Optimize for highest quality
    quality_optimized,
    /// Balance cost and quality
    balanced,
    /// Optimize for lowest latency
    latency_optimized,
};

/// Provider health status
pub const ProviderHealth = enum {
    healthy,
    degraded,
    unavailable,
};

/// Provider registry entry
const ProviderEntry = struct {
    provider: *client.LLMProvider,
    config: ProviderRoutingConfig,
    health: ProviderHealth = .healthy,
    failure_count: u32 = 0,
    last_failure_time: ?i64 = null,
    request_count: u64 = 0,
    success_count: u64 = 0,
    avg_latency_ms: f64 = 0,
};

/// Provider routing configuration
pub const ProviderRoutingConfig = struct {
    /// Priority for this provider (higher = preferred)
    priority: u8 = 5,
    /// Max concurrent requests
    max_concurrent: u32 = 10,
    /// Request timeout override (0 = use provider default)
    timeout_ms: u32 = 0,
    /// Cost multiplier for this provider (1.0 = base cost)
    cost_multiplier: f32 = 1.0,
    /// Quality score for this provider (0-100)
    quality_score: u8 = 80,
    /// Latency score for this provider (0-100, higher = faster)
    latency_score: u8 = 70,
    /// Task types this provider supports
    supported_tasks: []const TaskType = &[_]TaskType{},
};

/// Multi-model orchestrator
pub const Orchestrator = struct {
    allocator: std.mem.Allocator,
    providers: std.StringHashMap(ProviderEntry),
    routing_config: RoutingConfig,
    model_registry: ModelRegistry,

    const Self = @This();

    pub const RoutingConfig = struct {
        /// Default routing strategy
        default_strategy: RoutingStrategy = .balanced,
        /// Enable automatic failover
        enable_failover: bool = true,
        /// Max retry attempts
        max_retries: u32 = 3,
        /// Retry delay in milliseconds
        retry_delay_ms: u32 = 1000,
        /// Health check interval in seconds
        health_check_interval_s: u32 = 60,
        /// Failure threshold before marking provider unavailable
        failure_threshold: u32 = 5,
        /// Recovery timeout in seconds (provider considered recovered after this time)
        recovery_timeout_s: u32 = 300,
    };

    pub fn init(allocator: std.mem.Allocator, config: RoutingConfig) !Self {
        var orchestrator = Self{
            .allocator = allocator,
            .providers = std.StringHashMap(ProviderEntry).init(allocator),
            .routing_config = config,
            .model_registry = try ModelRegistry.init(allocator),
        };

        // Initialize default model registry
        try orchestrator.model_registry.registerDefaults();

        return orchestrator;
    }

    pub fn deinit(self: *Self) void {
        var it = self.providers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Provider is owned elsewhere, don't deinit here
        }
        self.providers.deinit();
        self.model_registry.deinit();
    }

    /// Register a provider for routing
    pub fn registerProvider(
        self: *Self,
        name: []const u8,
        provider: *client.LLMProvider,
        config: ProviderRoutingConfig
    ) !void {
        const entry = ProviderEntry{
            .provider = provider,
            .config = config,
            .health = .healthy,
        };
        try self.providers.put(try self.allocator.dupe(u8, name), entry);
    }

    /// Unregister a provider
    pub fn unregisterProvider(self: *Self, name: []const u8) void {
        const entry = self.providers.fetchRemove(name);
        if (entry != null) {
            self.allocator.free(entry.?.key);
        }
    }

    /// Execute a function call with intelligent routing
    pub fn callFunction(
        self: *Self,
        task_type: TaskType,
        priority: TaskPriority,
        strategy: ?RoutingStrategy,
        schema: function.FunctionSchema,
        params: types.Value,
        allocator: std.mem.Allocator
    ) !types.FunctionResult {
        const selected_strategy = strategy orelse self.routing_config.default_strategy;

        // Select best provider for this task (name is temporarily owned by selector)
        const provider_name = try self.selectProvider(task_type, priority, selected_strategy);
        defer self.allocator.free(provider_name);

        // Get provider entry
        const entry = self.providers.get(provider_name) orelse return error.ProviderNotFound;
        var provider_entry = entry.value_ptr.*;

        // Attempt request with retry logic
        var attempt: u32 = 0;
        var last_error: ?anyerror = null;

        while (attempt < self.routing_config.max_retries) : (attempt += 1) {
            if (provider_entry.health == .unavailable) {
                // Try failover to another provider
                if (self.routing_config.enable_failover) {
                    const fallback_name = self.selectFallbackProvider(provider_name, task_type) catch {
                        // No fallback available
                        return error.AllProvidersUnavailable;
                    };
                    const fallback_entry = self.providers.get(fallback_name) orelse return error.ProviderNotFound;
                    provider_entry = fallback_entry.value_ptr.*;
                } else {
                    return error.ProviderUnavailable;
                }
            }

            // Record request start
            const start_time = std.time.milliTimestamp();
            provider_entry.request_count += 1;

            // Make the call
            const result = provider_entry.provider.call_function(schema, params, allocator);

            // Record completion
            const end_time = std.time.milliTimestamp();
            const latency = @as(f64, @floatFromInt(end_time - start_time));

            if (result) |r| {
                // Success - update stats
                provider_entry.success_count += 1;
                provider_entry.failure_count = 0;
                // Update moving average latency
                provider_entry.avg_latency_ms = (provider_entry.avg_latency_ms * 0.9) + (latency * 0.1);

                if (provider_entry.health == .degraded or provider_entry.health == .unavailable) {
                    provider_entry.health = .healthy;
                }

                return r;
            } else |err| {
                // Failure - record and retry
                last_error = err;
                provider_entry.failure_count += 1;
                provider_entry.last_failure_time = std.time.timestamp();

                // Update health status
                if (provider_entry.failure_count >= self.routing_config.failure_threshold) {
                    provider_entry.health = .unavailable;
                } else if (provider_entry.failure_count >= 2) {
                    provider_entry.health = .degraded;
                }

                // Delay before retry
                if (attempt < self.routing_config.max_retries - 1) {
                    std.time.sleep(self.routing_config.retry_delay_ms * 1_000_000);
                }
            }
        }

        // All retries exhausted
        return last_error orelse error.UnknownError;
    }

    /// Select the best provider for a given task
    fn selectProvider(
        self: *const Self,
        task_type: TaskType,
        priority: TaskPriority,
        strategy: RoutingStrategy
    ) ![]const u8 {
        // Count healthy providers first
        var count: usize = 0;
        {
            var it = self.providers.iterator();
            while (it.next()) |entry| {
                const provider_entry = entry.value_ptr;
                if (provider_entry.health == .unavailable) continue;

                // Check if provider supports this task type
                const supports_task = blk: {
                    if (provider_entry.config.supported_tasks.len == 0) {
                        break :blk true;
                    }
                    var found = false;
                    for (provider_entry.config.supported_tasks) |t| {
                        if (t == task_type) {
                            found = true;
                            break;
                        }
                    }
                    break :blk found;
                };

                if (supports_task) count += 1;
            }
        }

        if (count == 0) {
            return error.NoAvailableProviders;
        }

        // Allocate candidates array
        const Candidate = struct {
            name: []const u8,
            score: f64,
            priority: u8,
            health: ProviderHealth,
        };
        var candidates = try self.allocator.alloc(Candidate, count);
        defer {
            if (candidates.len > 1) {
                for (candidates[1..]) |*c| { // Skip index 0 - returned to caller
                    self.allocator.free(c.name);
                }
            }
            self.allocator.free(candidates);
        }

        // Fill candidates
        var idx: usize = 0;
        {
            var it = self.providers.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const provider_entry = entry.value_ptr;

                if (provider_entry.health == .unavailable) continue;

                // Check if provider supports this task type
                const supports_task = blk: {
                    if (provider_entry.config.supported_tasks.len == 0) {
                        break :blk true;
                    }
                    var found = false;
                    for (provider_entry.config.supported_tasks) |t| {
                        if (t == task_type) {
                            found = true;
                            break;
                        }
                    }
                    break :blk found;
                };

                if (!supports_task) continue;

                // Get model info for scoring
                _ = client.LLMProvider.get_capabilities(provider_entry.provider);
                const model_info = self.model_registry.getInfo(name) catch null;

                // Calculate score based on strategy
                const score = switch (strategy) {
                    .cost_optimized => self.calculateCostScore(provider_entry.*, model_info, priority),
                    .quality_optimized => self.calculateQualityScore(provider_entry.*, model_info, priority),
                    .latency_optimized => self.calculateLatencyScore(provider_entry.*, priority),
                    .balanced => self.calculateBalancedScore(provider_entry.*, model_info, priority),
                };

                candidates[idx] = .{
                    .name = try self.allocator.dupe(u8, name),
                    .score = score,
                    .priority = provider_entry.config.priority,
                    .health = provider_entry.health,
                };
                idx += 1;
            }
        }

        // Sort by score (highest first), then priority
        std.sort.insertion(Candidate, candidates, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                // Prefer healthy over degraded
                if (a.health != b.health) {
                    return @intFromEnum(a.health) < @intFromEnum(b.health);
                }
                // Then by score
                if (a.score != b.score) {
                    return a.score > b.score;
                }
                // Then by priority
                return a.priority > b.priority;
            }
        }.lessThan);

        // Return best candidate (transfer ownership to caller)
        return candidates[0].name;
    }

    /// Select a fallback provider
    fn selectFallbackProvider(
        self: *const Self,
        exclude_provider: []const u8,
        task_type: TaskType
    ) ![]const u8 {
        _ = task_type;
        var it = self.providers.iterator();
        var best_provider: ?[]const u8 = null;
        var best_priority: u8 = 0;

        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const provider_entry = entry.value_ptr;

            // Skip excluded provider
            if (std.mem.eql(u8, name, exclude_provider)) continue;

            // Skip unhealthy providers
            if (provider_entry.health == .unavailable) continue;

            // Prefer higher priority
            if (provider_entry.config.priority > best_priority) {
                best_priority = provider_entry.config.priority;
                best_provider = name;
            }
        }

        return best_provider orelse error.NoFallbackProvider;
    }

    /// Calculate cost-optimized score (lower is better)
    fn calculateCostScore(
        self: *const Self,
        entry: ProviderEntry,
        model_info: ?ModelInfo,
        priority: TaskPriority
    ) f64 {
        _ = self;
        _ = priority;
        const base_cost = if (model_info) |info|
            info.input_cost_per_1k + info.output_cost_per_1k
        else
            0.01;

        const effective_cost = base_cost * entry.config.cost_multiplier;
        // Invert so higher score = better
        return 1.0 / (effective_cost + 0.001);
    }

    /// Calculate quality-optimized score
    fn calculateQualityScore(
        self: *const Self,
        entry: ProviderEntry,
        model_info: ?ModelInfo,
        priority: TaskPriority
    ) f64 {
        _ = self;
        const quality = if (model_info) |info|
            @as(f64, @floatFromInt(info.quality_score))
        else
            @as(f64, @floatFromInt(entry.config.quality_score));

        // Boost score for high priority tasks
        const priority_boost: f64 = switch (priority) {
            .critical => 1.2,
            .high => 1.1,
            .normal => 1.0,
            .low => 0.9,
        };

        return quality * priority_boost / 100.0;
    }

    /// Calculate latency-optimized score
    fn calculateLatencyScore(
        self: *const Self,
        entry: ProviderEntry,
        priority: TaskPriority
    ) f64 {
        _ = self;
        _ = priority;
        const latency_score = @as(f64, @floatFromInt(entry.config.latency_score));

        // Incorporate historical latency if available
        const historical_factor = if (entry.avg_latency_ms > 0)
            1000.0 / (entry.avg_latency_ms + 100.0)
        else
            0.5;

        return (latency_score / 100.0) * 0.5 + historical_factor * 0.5;
    }

    /// Calculate balanced score
    fn calculateBalancedScore(
        self: *const Self,
        entry: ProviderEntry,
        model_info: ?ModelInfo,
        priority: TaskPriority
    ) f64 {
        const cost_score = self.calculateCostScore(entry, model_info, priority);
        const quality_score = self.calculateQualityScore(entry, model_info, priority);
        const latency_score = self.calculateLatencyScore(entry, priority);

        // Weighted balance: quality 40%, cost 35%, latency 25%
        return quality_score * 0.4 + cost_score * 0.35 + latency_score * 0.25;
    }

    /// Get task type from function schema
    pub fn classifyTask(schema: function.FunctionSchema) TaskType {
        const name = schema.name;

        // Security-related tasks
        if (std.mem.indexOf(u8, name, "security") != null or
            std.mem.indexOf(u8, name, "vulnerability") != null or
            std.mem.indexOf(u8, name, "analyze") != null) {
            return .security_analysis;
        }

        // Summarization tasks
        if (std.mem.indexOf(u8, name, "summarize") != null or
            std.mem.indexOf(u8, name, "compress") != null or
            std.mem.indexOf(u8, name, "digest") != null) {
            return .summarization;
        }

        // Complex reasoning tasks
        if (std.mem.indexOf(u8, name, "plan") != null or
            std.mem.indexOf(u8, name, "optimize") != null or
            std.mem.indexOf(u8, name, "reason") != null) {
            return .complex_reasoning;
        }

        // Simple extraction tasks
        if (std.mem.indexOf(u8, name, "extract") != null or
            std.mem.indexOf(u8, name, "parse") != null or
            std.mem.indexOf(u8, name, "detect") != null) {
            return .simple_extraction;
        }

        return .general;
    }

    /// Get provider health status
    pub fn getProviderHealth(self: *const Self, name: []const u8) ?ProviderHealth {
        if (self.providers.get(name)) |entry| {
            return entry.health;
        }
        return null;
    }

    /// Get all provider statuses
    pub fn getAllProviderStatuses(self: *const Self) ![]ProviderStatus {
        // Count providers
        const count = self.providers.count();
        if (count == 0) {
            return try self.allocator.alloc(ProviderStatus, 0);
        }

        // Allocate result array
        const result = try self.allocator.alloc(ProviderStatus, count);

        // Fill result
        var idx: usize = 0;
        var it = self.providers.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const provider_entry = entry.value_ptr;

            result[idx] = ProviderStatus{
                .name = try self.allocator.dupe(u8, name),
                .health = provider_entry.health,
                .request_count = provider_entry.request_count,
                .success_count = provider_entry.success_count,
                .failure_count = provider_entry.failure_count,
                .avg_latency_ms = provider_entry.avg_latency_ms,
            };
            idx += 1;
        }

        return result;
    }

    /// Reset provider health (use after maintenance)
    pub fn resetProviderHealth(self: *Self, name: []const u8) !void {
        if (self.providers.getPtr(name)) |entry| {
            entry.health = .healthy;
            entry.failure_count = 0;
            entry.last_failure_time = null;
        }
    }
};

/// Provider candidate for selection
const ProviderCandidate = struct {
    name: []const u8,
    score: f64,
    priority: u8,
    health: ProviderHealth,
};

/// Provider status report
pub const ProviderStatus = struct {
    name: []const u8,
    health: ProviderHealth,
    request_count: u64,
    success_count: u64,
    failure_count: u32,
    avg_latency_ms: f64,

    pub fn deinit(self: *ProviderStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Model registry for cost/performance tracking
const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    models: std.StringHashMap(ModelInfo),

    const Self = @This();

    fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .models = std.StringHashMap(ModelInfo).init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.models.deinit();
    }

    fn register(self: *Self, name: []const u8, info: ModelInfo) !void {
        try self.models.put(try self.allocator.dupe(u8, name), info);
    }

    fn getInfo(self: *const Self, name: []const u8) !ModelInfo {
        return self.models.get(name) orelse error.ModelNotFound;
    }

    fn registerDefaults(self: *Self) !void {
        // OpenAI models
        try self.register("gpt-4", .{
            .input_cost_per_1k = 0.03,
            .output_cost_per_1k = 0.06,
            .quality_score = 95,
            .latency_score = 60,
        });
        try self.register("gpt-4-turbo", .{
            .input_cost_per_1k = 0.01,
            .output_cost_per_1k = 0.03,
            .quality_score = 90,
            .latency_score = 70,
        });
        try self.register("gpt-3.5-turbo", .{
            .input_cost_per_1k = 0.0005,
            .output_cost_per_1k = 0.0015,
            .quality_score = 80,
            .latency_score = 85,
        });

        // Anthropic models
        try self.register("claude-3-opus", .{
            .input_cost_per_1k = 0.015,
            .output_cost_per_1k = 0.075,
            .quality_score = 98,
            .latency_score = 55,
        });
        try self.register("claude-3-sonnet", .{
            .input_cost_per_1k = 0.003,
            .output_cost_per_1k = 0.015,
            .quality_score = 92,
            .latency_score = 75,
        });
        try self.register("claude-3-haiku", .{
            .input_cost_per_1k = 0.00025,
            .output_cost_per_1k = 0.00125,
            .quality_score = 75,
            .latency_score = 90,
        });

        // Local models (lowest cost, variable quality)
        try self.register("local-llama", .{
            .input_cost_per_1k = 0,
            .output_cost_per_1k = 0,
            .quality_score = 60,
            .latency_score = 50,
        });
    }
};

/// Model information
const ModelInfo = struct {
    input_cost_per_1k: f32,
    output_cost_per_1k: f32,
    quality_score: u8,
    latency_score: u8,
};

// ==================== Tests ====================//

test "orchestrator initialization" {
    var orchestrator = try Orchestrator.init(std.testing.allocator, .{});
    defer orchestrator.deinit();

    try std.testing.expectEqual(@as(usize, 7), orchestrator.model_registry.models.count());
}

test "orchestrator provider_registration" {
    var orchestrator = try Orchestrator.init(std.testing.allocator, .{});
    defer orchestrator.deinit();

    // Create a mock provider (local has minimal requirements)
    var local_provider = client.LLMProvider{ .local = undefined };

    try orchestrator.registerProvider("test-local", &local_provider, .{
        .priority = 10,
        .quality_score = 85,
    });

    try std.testing.expectEqual(@as(usize, 1), orchestrator.providers.count());
}

test "orchestrator provider_unregistration" {
    var orchestrator = try Orchestrator.init(std.testing.allocator, .{});
    defer orchestrator.deinit();

    var local_provider = client.LLMProvider{ .local = undefined };

    try orchestrator.registerProvider("test-local", &local_provider, .{});
    try std.testing.expectEqual(@as(usize, 1), orchestrator.providers.count());

    orchestrator.unregisterProvider("test-local");
    try std.testing.expectEqual(@as(usize, 0), orchestrator.providers.count());
}

test "orchestrator task_classification" {
    // Create mock schemas for different task types
    var params = function.JSONSchema.init(.object);
    defer params.deinit(std.testing.allocator);

    var security_schema = try function.FunctionSchema.init(
        std.testing.allocator,
        "security_vulnerability_scan",
        "Scan for vulnerabilities",
        params
    );
    defer security_schema.deinit(std.testing.allocator);

    const task_type = Orchestrator.classifyTask(security_schema);
    try std.testing.expectEqual(TaskType.security_analysis, task_type);

    var extract_schema = try function.FunctionSchema.init(
        std.testing.allocator,
        "extract_entities",
        "Extract entities from text",
        params
    );
    defer extract_schema.deinit(std.testing.allocator);

    const extract_type = Orchestrator.classifyTask(extract_schema);
    try std.testing.expectEqual(TaskType.simple_extraction, extract_type);
}

test "orchestrator provider_selection" {
    var orchestrator = try Orchestrator.init(std.testing.allocator, .{
        .default_strategy = .cost_optimized,
    });
    defer orchestrator.deinit();

    // Register multiple providers
    var provider1 = client.LLMProvider{ .local = undefined };
    var provider2 = client.LLMProvider{ .local = undefined };

    try orchestrator.registerProvider("cheap-provider", &provider1, .{
        .priority = 5,
        .cost_multiplier = 0.5,
        .quality_score = 70,
    });

    try orchestrator.registerProvider("expensive-provider", &provider2, .{
        .priority = 5,
        .cost_multiplier = 2.0,
        .quality_score = 95,
    });

    // For cost-optimized, should prefer cheaper provider
    const selected = try orchestrator.selectProvider(.general, .normal, .cost_optimized);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("cheap-provider", selected);
}

test "orchestrator health_reset" {
    var orchestrator = try Orchestrator.init(std.testing.allocator, .{});
    defer orchestrator.deinit();

    var local_provider = client.LLMProvider{ .local = undefined };

    try orchestrator.registerProvider("test-provider", &local_provider, .{});

    // Manually set unhealthy state
    if (orchestrator.providers.getPtr("test-provider")) |entry| {
        entry.health = .unavailable;
        entry.failure_count = 10;
    }

    // Reset health
    try orchestrator.resetProviderHealth("test-provider");

    const health = orchestrator.getProviderHealth("test-provider");
    try std.testing.expect(health != null);
    try std.testing.expectEqual(ProviderHealth.healthy, health.?);
}

test "orchestrator get_all_statuses" {
    var orchestrator = try Orchestrator.init(std.testing.allocator, .{});
    defer orchestrator.deinit();

    var provider1 = client.LLMProvider{ .local = undefined };
    var provider2 = client.LLMProvider{ .local = undefined };

    try orchestrator.registerProvider("p1", &provider1, .{});
    try orchestrator.registerProvider("p2", &provider2, .{});

    const statuses = try orchestrator.getAllProviderStatuses();
    defer {
        for (statuses) |*s| s.deinit(std.testing.allocator);
        std.testing.allocator.free(statuses);
    }

    try std.testing.expectEqual(@as(usize, 2), statuses.len);
}

test "model_registry_costs" {
    var orchestrator = try Orchestrator.init(std.testing.allocator, .{});
    defer orchestrator.deinit();

    const gpt4 = try orchestrator.model_registry.getInfo("gpt-4");
    try std.testing.expectApproxEqAbs(@as(f32, 0.03), gpt4.input_cost_per_1k, 0.001);

    const haiku = try orchestrator.model_registry.getInfo("claude-3-haiku");
    try std.testing.expectApproxEqAbs(@as(f32, 0.00025), haiku.input_cost_per_1k, 0.0001);
}
