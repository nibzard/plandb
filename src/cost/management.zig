//! Cost management and optimization for LLM operations
//!
//! Provides comprehensive cost tracking and optimization:
//! - Token usage tracking per model/provider
//! - Per-query cost calculation
//! - Budget enforcement and alerts
//! - Smart model selection for cost optimization
//! - Caching strategies to reduce costs

const std = @import("std");
const mem = std.mem;

/// Cost manager for LLM operations
pub const CostManager = struct {
    allocator: std.mem.Allocator,
    config: CostConfig,
    state: CostState,
    model_costs: std.StringHashMap(ModelCost),
    budgets: std.StringHashMap(Budget),
    usage_tracker: *UsageTracker,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        config: CostConfig,
        usage_tracker: *UsageTracker
    ) Self {
        const state = CostState{
            .daily_costs = std.StringHashMap(DailyCost).init(allocator),
            .hourly_costs = std.ArrayList(HourlyCost).initCapacity(allocator, 24) catch unreachable,
            .alerts = std.ArrayList(CostAlert).initCapacity(allocator, 100) catch unreachable,
            .stats = CostStatistics{},
        };

        var manager = CostManager{
            .allocator = allocator,
            .config = config,
            .state = state,
            .model_costs = std.StringHashMap(ModelCost).init(allocator),
            .budgets = std.StringHashMap(Budget).init(allocator),
            .usage_tracker = usage_tracker,
        };

        // Initialize default model costs
        manager.initDefaultModelCosts() catch {};

        return manager;
    }

    pub fn deinit(self: *Self) void {
        var cost_it = self.state.daily_costs.iterator();
        while (cost_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.state.daily_costs.deinit();

        for (self.state.hourly_costs.items) |*cost| {
            cost.deinit(self.allocator);
        }
        self.state.hourly_costs.deinit(self.allocator);

        for (self.state.alerts.items) |*alert| {
            alert.deinit(self.allocator);
        }
        self.state.alerts.deinit(self.allocator);

        var model_it = self.model_costs.iterator();
        while (model_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.model_costs.deinit();

        var budget_it = self.budgets.iterator();
        while (budget_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.budgets.deinit();
    }

    /// Calculate cost for an LLM request
    pub fn calculateCost(self: *Self, model_name: []const u8, input_tokens: u64, output_tokens: u64) !Cost {
        const cost_info = self.model_costs.get(model_name) orelse {
            return error.ModelNotFound;
        };

        const input_cost = @as(f64, @floatFromInt(input_tokens)) * cost_info.input_cost_per_1k / 1000.0;
        const output_cost = @as(f64, @floatFromInt(output_tokens)) * cost_info.output_cost_per_1k / 1000.0;

        return Cost{
            .input_cost = input_cost,
            .output_cost = output_cost,
            .total_cost = input_cost + output_cost,
            .currency = "USD",
        };
    }

    /// Record LLM operation with cost tracking
    pub fn recordOperation(self: *Self, operation: LLMOperation) !void {
        const cost = try self.calculateCost(operation.model_name, operation.input_tokens, operation.output_tokens);

        // Update daily costs
        const date_key = try self.getDateKey(operation.timestamp);
        const daily_entry = try self.state.daily_costs.getOrPut(date_key);
        if (!daily_entry.found_existing) {
            daily_entry.key_ptr.* = date_key;
            daily_entry.value_ptr.* = DailyCost{
                .date = date_key,
                .total_cost = 0,
                .operation_count = 0,
                .total_tokens = 0,
            };
        }
        daily_entry.value_ptr.total_cost += cost.total_cost;
        daily_entry.value_ptr.operation_count += 1;
        daily_entry.value_ptr.total_tokens += operation.input_tokens + operation.output_tokens;

        // Update hourly costs
        try self.updateHourlyCosts(operation.timestamp, cost.total_cost);

        // Update statistics
        self.state.stats.total_cost += cost.total_cost;
        self.state.stats.total_operations += 1;
        self.state.stats.total_tokens += operation.input_tokens + operation.output_tokens;

        // Check budget constraints
        try self.checkBudgets(cost.total_cost);
    }

    /// Check if operation is within budget limits
    pub fn checkBudgetLimits(self: *Self, estimated_cost: f64) !BudgetCheck {
        var exceeded_budgets = std.ArrayList([]const u8).initCapacity(self.allocator, 5) catch unreachable;

        var budget_it = self.budgets.iterator();
        while (budget_it.next()) |entry| {
            const budget = entry.value_ptr.*;
            const current_cost = self.getCostForPeriod(budget.period, budget.period_start);

            if (current_cost + estimated_cost > budget.limit) {
                try exceeded_budgets.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
            }
        }

        const within_budget = exceeded_budgets.items.len == 0;

        return BudgetCheck{
            .within_budget = within_budget,
            .exceeded_budgets = try exceeded_budgets.toOwnedSlice(self.allocator),
            .estimated_cost = estimated_cost,
        };
    }

    /// Get optimal model for request (cost optimization)
    pub fn getOptimalModel(self: *Self, requirements: ModelRequirements) ![]const u8 {
        var candidates = std.ArrayList(ModelCandidate).initCapacity(self.allocator, 10) catch unreachable;
        defer {
            for (candidates.items) |*c| {
                self.allocator.free(c.model_name);
            }
            candidates.deinit(self.allocator);
        }

        var model_it = self.model_costs.iterator();
        while (model_it.next()) |entry| {
            const model_name = entry.key_ptr.*;
            const cost_info = entry.value_ptr.*;

            // Check if model meets requirements
            if (cost_info.max_tokens < requirements.min_max_tokens) continue;
            if (cost_info.quality_score < requirements.min_quality) continue;

            // Calculate score (balance cost and quality)
            const cost_score = 1.0 / (cost_info.input_cost_per_1k + cost_info.output_cost_per_1k);
            const quality_factor = @as(f32, @floatFromInt(requirements.quality_priority)) / 10.0;
            const score = cost_score * 0.6 + @as(f32, @floatFromInt(cost_info.quality_score)) / 100.0 * quality_factor * 0.4;

            try candidates.append(self.allocator, .{
                .model_name = try self.allocator.dupe(u8, model_name),
                .score = score,
                .cost_per_1k = cost_info.input_cost_per_1k + cost_info.output_cost_per_1k,
            });
        }

        // Sort by score (highest first)
        std.sort.insertion(ModelCandidate, candidates.items, {}, struct {
            fn lessThan(_: void, a: ModelCandidate, b: ModelCandidate) bool {
                return a.score > b.score;
            }
        }.lessThan);

        if (candidates.items.len == 0) {
            return error.NoSuitableModel;
        }

        // Return the name of the best candidate (caller should dupe if needed)
        return candidates.items[0].model_name;
    }

    /// Get cost optimization recommendations
    pub fn getRecommendations(self: *Self) ![]CostRecommendation {
        var recommendations = std.ArrayList(CostRecommendation).initCapacity(self.allocator, 10) catch unreachable;

        // Check for high-cost operations
        var model_it = self.model_costs.iterator();
        while (model_it.next()) |entry| {
            const model_name = entry.key_ptr.*;
            const cost_info = entry.value_ptr.*;

            if (cost_info.input_cost_per_1k > self.config.expensive_model_threshold) {
                try recommendations.append(self.allocator, .{
                    .type = .switch_to_cheaper_model,
                    .model_name = try self.allocator.dupe(u8, model_name),
                    .description = try std.fmt.allocPrint(self.allocator, "Consider switching to a cheaper model for {s} operations", .{model_name}),
                    .estimated_savings = 0.5, // 50% potential savings
                    .priority = .high,
                });
            }
        }

        // Check for caching opportunities
        const cache_stats = self.usage_tracker.getCacheStats();
        if (cache_stats.hit_rate < 0.5) {
            try recommendations.append(self.allocator, .{
                .type = .enable_caching,
                .model_name = try self.allocator.dupe(u8, "all"),
                .description = try self.allocator.dupe(u8, "Enable caching for repeated queries to reduce costs"),
                .estimated_savings = 1.0 - cache_stats.hit_rate,
                .priority = .medium,
            });
        }

        return recommendations.toOwnedSlice(self.allocator);
    }

    /// Set budget limit
    pub fn setBudget(self: *Self, name: []const u8, budget: Budget) !void {
        try self.budgets.put(try self.allocator.dupe(u8, name), budget);
    }

    /// Get current cost statistics
    pub fn getStatistics(self: *const Self) CostStatistics {
        return self.state.stats;
    }

    /// Get daily cost report
    pub fn getDailyReport(self: *Self, date_key: []const u8) !?DailyCost {
        return self.state.daily_costs.get(date_key);
    }

    /// Get hourly cost breakdown
    pub fn getHourlyBreakdown(self: *Self) ![]const HourlyCost {
        return self.state.hourly_costs.items;
    }

    /// Get cost alerts
    pub fn getAlerts(self: *Self) ![]const CostAlert {
        return self.state.alerts.items;
    }

    /// Add model cost
    pub fn addModelCost(self: *Self, model_name: []const u8, cost: ModelCost) !void {
        try self.model_costs.put(try self.allocator.dupe(u8, model_name), cost);
    }

    fn initDefaultModelCosts(self: *Self) !void {
        // OpenAI models (approximate costs as of 2024)
        try self.addModelCost("gpt-4", .{
            .input_cost_per_1k = 0.03,
            .output_cost_per_1k = 0.06,
            .max_tokens = 8192,
            .quality_score = 95,
        });
        try self.addModelCost("gpt-4-turbo", .{
            .input_cost_per_1k = 0.01,
            .output_cost_per_1k = 0.03,
            .max_tokens = 128000,
            .quality_score = 90,
        });
        try self.addModelCost("gpt-3.5-turbo", .{
            .input_cost_per_1k = 0.0005,
            .output_cost_per_1k = 0.0015,
            .max_tokens = 16385,
            .quality_score = 80,
        });

        // Anthropic models
        try self.addModelCost("claude-3-opus", .{
            .input_cost_per_1k = 0.015,
            .output_cost_per_1k = 0.075,
            .max_tokens = 200000,
            .quality_score = 98,
        });
        try self.addModelCost("claude-3-sonnet", .{
            .input_cost_per_1k = 0.003,
            .output_cost_per_1k = 0.015,
            .max_tokens = 200000,
            .quality_score = 92,
        });
        try self.addModelCost("claude-3-haiku", .{
            .input_cost_per_1k = 0.00025,
            .output_cost_per_1k = 0.00125,
            .max_tokens = 200000,
            .quality_score = 75,
        });
    }

    fn getDateKey(self: *Self, timestamp: i128) ![]const u8 {
        const epoch_day = @divFloor(timestamp, 86_400_000_000_000);
        return std.fmt.allocPrint(self.allocator, "{d}", .{epoch_day});
    }

    fn updateHourlyCosts(self: *Self, timestamp: i128, cost: f64) !void {
        const epoch_hour = @divFloor(timestamp, 3_600_000_000_000);
        const current_hour = @rem(epoch_hour, 24);

        // Ensure we have 24 hourly slots
        while (self.state.hourly_costs.items.len < 24) {
            try self.state.hourly_costs.append(self.allocator, .{
                .hour = self.state.hourly_costs.items.len,
                .total_cost = 0,
                .operation_count = 0,
            });
        }

        // Update the current hour
        const hour_idx: usize = @intCast(current_hour);
        if (hour_idx < self.state.hourly_costs.items.len) {
            self.state.hourly_costs.items[hour_idx].total_cost += cost;
            self.state.hourly_costs.items[hour_idx].operation_count += 1;
        }
    }

    fn checkBudgets(self: *Self, cost: f64) !void {
        var budget_it = self.budgets.iterator();
        while (budget_it.next()) |entry| {
            const budget = entry.value_ptr.*;
            const current_cost = self.getCostForPeriod(budget.period, budget.period_start);
            const new_cost = current_cost + cost;

            if (new_cost > budget.limit) {
                // Budget exceeded
                const alert = CostAlert{
                    .alert_type = .budget_exceeded,
                    .budget_name = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .current_cost = new_cost,
                    .budget_limit = budget.limit,
                    .timestamp = std.time.nanoTimestamp(),
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Budget '{s}' exceeded: ${d:.2} / ${d:.2}",
                        .{ entry.key_ptr.*, new_cost, budget.limit }
                    ),
                };
                try self.state.alerts.append(self.allocator, alert);
            } else if (new_cost > budget.limit * budget.warning_threshold) {
                // Approaching budget limit
                const alert = CostAlert{
                    .alert_type = .budget_warning,
                    .budget_name = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .current_cost = new_cost,
                    .budget_limit = budget.limit,
                    .timestamp = std.time.nanoTimestamp(),
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Budget '{s}' at {d:.0}%: ${d:.2} / ${d:.2}",
                        .{ entry.key_ptr.*, (new_cost / budget.limit) * 100, new_cost, budget.limit }
                    ),
                };
                try self.state.alerts.append(self.allocator, alert);
            }
        }

        // Trim alerts if needed
        while (self.state.alerts.items.len > self.config.max_alerts) {
            const removed = self.state.alerts.orderedRemove(0);
            removed.deinit(self.allocator);
        }
    }

    fn getCostForPeriod(self: *const Self, period: BudgetPeriod, start_time: i128) f64 {
        _ = start_time;

        var total: f64 = 0;

        switch (period) {
            .daily => {
                // Get today's cost
                var cost_it = self.state.daily_costs.iterator();
                while (cost_it.next()) |entry| {
                    total += entry.value_ptr.total_cost;
                }
            },
            .hourly => {
                // Get current hour's cost
                const epoch_hour = @divFloor(std.time.nanoTimestamp(), 3_600_000_000_000);
                const hour_idx: usize = @intCast(@rem(epoch_hour, 24));
                if (hour_idx < self.state.hourly_costs.items.len) {
                    total = self.state.hourly_costs.items[hour_idx].total_cost;
                }
            },
            .monthly => {
                // Sum all daily costs (simplified)
                var cost_it = self.state.daily_costs.iterator();
                while (cost_it.next()) |entry| {
                    total += entry.value_ptr.total_cost;
                }
            },
        }

        return total;
    }
};

/// Usage statistics tracker
pub const UsageTracker = struct {
    allocator: std.mem.Allocator,
    cache_stats: CacheStatistics,
    operation_history: std.ArrayList(OperationRecord),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .cache_stats = CacheStatistics{
                .hits = 0,
                .misses = 0,
                .total_requests = 0,
                .hit_rate = 0,
            },
            .operation_history = std.ArrayList(OperationRecord).initCapacity(allocator, 1000) catch unreachable,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.operation_history.items) |*record| {
            record.deinit(self.allocator);
        }
        self.operation_history.deinit(self.allocator);
    }

    pub fn recordCacheHit(self: *Self) void {
        self.cache_stats.hits += 1;
        self.cache_stats.total_requests += 1;
    }

    pub fn recordCacheMiss(self: *Self) void {
        self.cache_stats.misses += 1;
        self.cache_stats.total_requests += 1;
    }

    pub fn getCacheStats(self: *const Self) CacheStatistics {
        const hit_rate = if (self.cache_stats.total_requests > 0)
            @as(f32, @floatFromInt(self.cache_stats.hits)) / @as(f32, @floatFromInt(self.cache_stats.total_requests))
        else
            0;

        return .{
            .hits = self.cache_stats.hits,
            .misses = self.cache_stats.misses,
            .total_requests = self.cache_stats.total_requests,
            .hit_rate = hit_rate,
        };
    }
};

/// Cost configuration
pub const CostConfig = struct {
    expensive_model_threshold: f32 = 0.01, // $0.01 per 1k tokens
    max_alerts: usize = 1000,
    default_budget_limit: f64 = 100.0, // $100 default
    enable_auto_optimization: bool = true,
    min_cache_savings_threshold: f32 = 0.2, // 20% savings to recommend caching
};

/// Cost state
pub const CostState = struct {
    daily_costs: std.StringHashMap(DailyCost),
    hourly_costs: std.ArrayList(HourlyCost),
    alerts: std.ArrayList(CostAlert),
    stats: CostStatistics,
};

/// Model cost information
pub const ModelCost = struct {
    input_cost_per_1k: f32,
    output_cost_per_1k: f32,
    max_tokens: u64,
    quality_score: u8, // 0-100
};

/// Budget configuration
pub const Budget = struct {
    limit: f64,
    period: BudgetPeriod,
    period_start: i128,
    warning_threshold: f32 = 0.8, // Alert at 80%
};

/// Budget period
pub const BudgetPeriod = enum {
    hourly,
    daily,
    monthly,
};

/// Budget check result
pub const BudgetCheck = struct {
    within_budget: bool,
    exceeded_budgets: []const []const u8,
    estimated_cost: f64,

    pub fn deinit(self: *const BudgetCheck, allocator: std.mem.Allocator) void {
        for (self.exceeded_budgets) |budget| {
            allocator.free(budget);
        }
        allocator.free(self.exceeded_budgets);
    }
};

/// Cost breakdown
pub const Cost = struct {
    input_cost: f64,
    output_cost: f64,
    total_cost: f64,
    currency: []const u8,
};

/// LLM operation record
pub const LLMOperation = struct {
    model_name: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    timestamp: i128,
    operation_id: ?[]const u8,
};

/// Model requirements for optimization
pub const ModelRequirements = struct {
    min_max_tokens: u64,
    min_quality: u8,
    quality_priority: u8 = 5, // 1-10 scale
    max_cost_per_1k: ?f32 = null,
};

/// Model candidate for selection
const ModelCandidate = struct {
    model_name: []const u8,
    score: f32,
    cost_per_1k: f32,
};

/// Cost recommendation
pub const CostRecommendation = struct {
    type: RecommendationType,
    model_name: []const u8,
    description: []const u8,
    estimated_savings: f32,
    priority: Priority,

    pub fn deinit(self: *CostRecommendation, allocator: std.mem.Allocator) void {
        allocator.free(self.model_name);
        allocator.free(self.description);
    }

    pub const RecommendationType = enum {
        switch_to_cheaper_model,
        enable_caching,
        batch_requests,
        reduce_context,
        use_fallback_model,
    };

    pub const Priority = enum {
        low,
        medium,
        high,
        critical,
    };
};

/// Cost statistics
pub const CostStatistics = struct {
    total_cost: f64 = 0,
    total_operations: u64 = 0,
    total_tokens: u64 = 0,
    average_cost_per_operation: f64 = 0,
    average_tokens_per_operation: f64 = 0,
};

/// Daily cost record
pub const DailyCost = struct {
    date: []const u8,
    total_cost: f64,
    operation_count: u64,
    total_tokens: u64,

    pub fn deinit(self: *DailyCost, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // date is owned by the HashMap key, not this struct
    }
};

/// Hourly cost record
pub const HourlyCost = struct {
    hour: usize,
    total_cost: f64,
    operation_count: u64,

    pub fn deinit(self: *HourlyCost, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Cost alert
pub const CostAlert = struct {
    alert_type: AlertType,
    budget_name: []const u8,
    current_cost: f64,
    budget_limit: f64,
    timestamp: i128,
    message: []const u8,

    pub fn deinit(self: *const CostAlert, allocator: std.mem.Allocator) void {
        allocator.free(self.budget_name);
        allocator.free(self.message);
    }

    pub const AlertType = enum {
        budget_warning,
        budget_exceeded,
        cost_spike,
        unusual_usage,
    };
};

/// Cache statistics
pub const CacheStatistics = struct {
    hits: u64,
    misses: u64,
    total_requests: u64,
    hit_rate: f32,
};

/// Operation record
pub const OperationRecord = struct {
    operation_id: []const u8,
    model_name: []const u8,
    tokens_used: u64,
    cost: f64,
    timestamp: i128,

    pub fn deinit(self: *OperationRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.operation_id);
        allocator.free(self.model_name);
    }
};

// ==================== Tests ====================//

test "CostManager init" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 6), manager.model_costs.count());
}

test "CostManager calculateCost" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    const cost = try manager.calculateCost("gpt-3.5-turbo", 1000, 500);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0005), cost.input_cost, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00075), cost.output_cost, 0.0001);
    try std.testing.expect(cost.total_cost > 0);
}

test "CostManager recordOperation" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    const operation = LLMOperation{
        .model_name = "gpt-3.5-turbo",
        .input_tokens = 1000,
        .output_tokens = 500,
        .timestamp = std.time.nanoTimestamp(),
        .operation_id = "op-123",
    };

    try manager.recordOperation(operation);

    try std.testing.expectEqual(@as(u64, 1), manager.state.stats.total_operations);
    try std.testing.expect(manager.state.stats.total_cost > 0);
}

test "CostManager checkBudgetLimits within budget" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    try manager.setBudget("test", .{
        .limit = 100.0,
        .period = .daily,
        .period_start = std.time.nanoTimestamp(),
    });

    const check = try manager.checkBudgetLimits(1.0);
    defer check.deinit(std.testing.allocator);

    try std.testing.expect(check.within_budget);
}

test "CostManager checkBudgetLimits exceeded" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    try manager.setBudget("test", .{
        .limit = 0.01,
        .period = .daily,
        .period_start = std.time.nanoTimestamp(),
    });

    const check = try manager.checkBudgetLimits(1.0);
    defer check.deinit(std.testing.allocator);

    try std.testing.expect(!check.within_budget);
    try std.testing.expectEqual(@as(usize, 1), check.exceeded_budgets.len);
}

test "CostManager getOptimalModel" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    const requirements = ModelRequirements{
        .min_max_tokens = 1000,
        .min_quality = 70,
    };

    const model = try manager.getOptimalModel(requirements);

    try std.testing.expect(model.len > 0);
}

test "CostManager getRecommendations" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{
        .expensive_model_threshold = 0.0001, // Trigger recommendation for all models
    }, &usage_tracker);
    defer manager.deinit();

    const recommendations = try manager.getRecommendations();
    defer {
        for (recommendations) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(recommendations);
    }

    try std.testing.expect(recommendations.len > 0);
}

test "UsageTracker cache stats" {
    var tracker = UsageTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.recordCacheHit();
    tracker.recordCacheHit();
    tracker.recordCacheMiss();

    const stats = tracker.getCacheStats();

    try std.testing.expectEqual(@as(u64, 2), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectApproxEqAbs(@as(f32, 0.666), stats.hit_rate, 0.01);
}

test "CostManager getStatistics" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    const stats = manager.getStatistics();

    try std.testing.expectEqual(@as(f64, 0), stats.total_cost);
}

test "CostManager daily report" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    const date_key = try manager.getDateKey(std.time.nanoTimestamp());
    defer std.testing.allocator.free(date_key);

    const report = try manager.getDailyReport(date_key);

    // No operations recorded yet
    try std.testing.expect(report == null);
}

test "CostManager addModelCost" {
    var usage_tracker = UsageTracker.init(std.testing.allocator);
    defer usage_tracker.deinit();

    var manager = CostManager.init(std.testing.allocator, .{}, &usage_tracker);
    defer manager.deinit();

    try manager.addModelCost("custom-model", .{
        .input_cost_per_1k = 0.001,
        .output_cost_per_1k = 0.002,
        .max_tokens = 4000,
        .quality_score = 85,
    });

    try std.testing.expectEqual(@as(usize, 7), manager.model_costs.count());
}
