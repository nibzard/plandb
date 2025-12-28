//! Performance Analyzer Plugin
//!
//! Monitors database operations, collects metrics, and detects regressions:
//! - Hooks on agent operations and commits
//! - Automatic metric collection with hot path safety
//! - Regression detection and alerting
//! - Correlation with commits and sessions

const std = @import("std");
const manager = @import("./manager.zig");
const events = @import("../events/index.zig");
const observability = @import("../cartridges/observability.zig");

// ==================== Hook Functions ====================

/// Hook: on_agent_operation - track operation metrics
fn on_agent_operation(allocator: std.mem.Allocator, ctx: manager.AgentOperationContext) anyerror!void {
    _ = allocator;

    // Get plugin instance from global registry or create context-based approach
    // For now, just record the operation timing
    const duration_ms = if (ctx.duration_ns) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else null;

    // Record to event manager if available
    if (ctx.event_manager) |em| {
        if (duration_ms) |d| {
            // Get commit range from metadata
            const commit_range_val = ctx.metadata.get("commit_range");
            var commit_range: ?[]const u8 = null;
            if (commit_range_val) |cr| {
                commit_range = cr;
            }

            // Create dimensions map
            var dimensions = std.StringHashMap([]const u8).init(allocator);
            defer {
                var it = dimensions.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                dimensions.deinit();
            }

            try dimensions.put("operation_type", ctx.operation_type);
            try dimensions.put("target_type", ctx.target_type);
            try dimensions.put("status", ctx.status);

            try em.recordPerfSample(
                "operation_latency_ms",
                d,
                "ms",
                dimensions,
                commit_range,
                &[_]u64{ctx.session_id},
            );
        }
    }
}

/// Hook: on_commit - analyze commit for performance impact
fn on_commit(allocator: std.mem.Allocator, ctx: manager.CommitContext) anyerror!manager.PluginResult {
    _ = allocator;

    // Analyze commit mutations for performance-relevant changes
    var mutations_analyzed: usize = 0;

    for (ctx.mutations) |mutation| {
        _ = mutation;
        mutations_analyzed += 1;
    }

    return manager.PluginResult{
        .success = true,
        .operations_processed = mutations_analyzed,
        .cartridges_updated = 0,
        .confidence = 1.0,
    };
}

/// Hook: on_perf_sample - process performance samples
fn on_perf_sample(allocator: std.mem.Allocator, ctx: manager.PerfSampleContext) anyerror!void {
    _ = allocator;
    _ = ctx;
    // Performance samples are handled by the observability cartridge
    // This hook can be used for additional processing or filtering
}

// ==================== Plugin State ====================

/// Performance analyzer plugin state
pub const PerfAnalyzerState = struct {
    allocator: std.mem.Allocator,
    operation_metrics: std.StringHashMap(OperationStats),
    observability_cartridge: ?*observability.ObservabilityCartridge,
    last_regression_check_ms: u64,
    config: PluginConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PluginConfig) !Self {
        return Self{
            .allocator = allocator,
            .operation_metrics = std.StringHashMap(OperationStats).init(allocator),
            .observability_cartridge = null,
            .last_regression_check_ms = 0,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.operation_metrics.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.operation_metrics.deinit();
    }

    /// Record operation statistics
    pub fn recordOperation(
        self: *Self,
        operation_type: []const u8,
        target_type: []const u8,
        duration_ms: ?f64,
        status: []const u8,
    ) !void {
        const key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ operation_type, target_type },
        );
        errdefer self.allocator.free(key);

        const entry = try self.operation_metrics.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            const stats = entry.value_ptr;
            stats.count += 1;
            if (duration_ms) |d| {
                stats.total_duration_ms += d;
                if (d > stats.max_duration_ms) stats.max_duration_ms = d;
                if (stats.min_duration_ms == 0 or d < stats.min_duration_ms) {
                    stats.min_duration_ms = d;
                }
            }
            if (std.mem.eql(u8, status, "failed")) {
                stats.error_count += 1;
            }
        } else {
            const d = duration_ms orelse 0;
            entry.value_ptr.* = OperationStats{
                .count = 1,
                .total_duration_ms = d,
                .avg_duration_ms = d,
                .min_duration_ms = d,
                .max_duration_ms = d,
                .error_count = if (std.mem.eql(u8, status, "failed")) @as(usize, 1) else 0,
            };
        }
    }

    /// Get operation statistics
    pub fn getOperationStats(
        self: *const Self,
        operation_type: []const u8,
        target_type: []const u8,
    ) ?OperationStats {
        const key = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ operation_type, target_type },
        ) catch return null;
        defer self.allocator.free(key);

        return self.operation_metrics.get(key);
    }

    /// Detect regressions if enough time has passed since last check
    pub fn detectRegressionsIfNeeded(self: *Self) !void {
        const now_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000)));

        if (now_ms - self.last_regression_check_ms >= self.config.regression_check_interval_ms) {
            self.last_regression_check_ms = now_ms;

            if (self.observability_cartridge) |cartridge| {
                const alerts = try cartridge.detectRegressions();
                defer {
                    for (alerts) |*a| a.deinit(self.allocator);
                    self.allocator.free(alerts);
                }

                if (alerts.len > 0) {
                    std.log.warn("Detected {d} performance regressions", .{alerts.len});
                }
            }
        }
    }

    /// Attach observability cartridge
    pub fn attachObservabilityCartridge(
        self: *Self,
        cartridge: *observability.ObservabilityCartridge,
    ) void {
        self.observability_cartridge = cartridge;
    }

    /// Get plugin statistics
    pub fn getStats(self: *const Self) PluginStats {
        var total_operations: usize = 0;
        var total_errors: usize = 0;

        var it = self.operation_metrics.iterator();
        while (it.next()) |entry| {
            const stats = entry.value_ptr.*;
            total_operations += stats.count;
            total_errors += stats.error_count;
        }

        return PluginStats{
            .operation_types_tracked = self.operation_metrics.count(),
            .total_operations_recorded = total_operations,
            .total_errors = total_errors,
            .last_regression_check_ms = self.last_regression_check_ms,
        };
    }
};

// ==================== Types ====================

pub const PluginConfig = struct {
    max_payload_size: usize = 4096,
    sampling_rate: f32 = 1.0,
    rate_limit_per_sec: u32 = 1000,
    auto_detect_regressions: bool = true,
    regression_check_interval_ms: u64 = 60_000,
};

pub const OperationStats = struct {
    count: usize,
    total_duration_ms: f64,
    avg_duration_ms: f64,
    min_duration_ms: f64,
    max_duration_ms: f64,
    error_count: usize,
};

pub const PluginStats = struct {
    operation_types_tracked: usize,
    total_operations_recorded: usize,
    total_errors: usize,
    last_regression_check_ms: u64,
};

// ==================== Plugin Export ====================

/// Create the perf_analyzer plugin instance
pub fn createPlugin() manager.Plugin {
    return .{
        .name = "perf_analyzer",
        .version = "0.1.0",
        .on_commit = on_commit,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
        .on_agent_session_start = null,
        .on_agent_operation = on_agent_operation,
        .on_review_request = null,
        .on_perf_sample = on_perf_sample,
    };
}

// ==================== Tests ====================

test "PerfAnalyzerState record operation" {
    var state = try PerfAnalyzerState.init(std.testing.allocator, .{});
    defer state.deinit();

    try state.recordOperation("read", "btree", 5.0, "completed");
    try state.recordOperation("read", "btree", 10.0, "completed");
    try state.recordOperation("read", "btree", 3.0, "failed");

    const stats = state.getOperationStats("read", "btree");
    try std.testing.expect(stats != null);

    if (stats) |s| {
        try std.testing.expectEqual(@as(usize, 3), s.count);
        try std.testing.expectEqual(@as(usize, 1), s.error_count);
        try std.testing.expectEqual(@as(f64, 18.0), s.total_duration_ms);
        try std.testing.expectEqual(@as(f64, 10.0), s.max_duration_ms);
        try std.testing.expectEqual(@as(f64, 3.0), s.min_duration_ms);
    }
}

test "PerfAnalyzerState get stats" {
    var state = try PerfAnalyzerState.init(std.testing.allocator, .{});
    defer state.deinit();

    try state.recordOperation("read", "btree", 5.0, "completed");
    try state.recordOperation("write", "btree", 10.0, "failed");

    const stats = state.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.operation_types_tracked);
    try std.testing.expectEqual(@as(usize, 2), stats.total_operations_recorded);
    try std.testing.expectEqual(@as(usize, 1), stats.total_errors);
}

test "PerfAnalyzerPlugin create plugin export" {
    const plugin = createPlugin();

    try std.testing.expectEqualStrings("perf_analyzer", plugin.name);
    try std.testing.expectEqualStrings("0.1.0", plugin.version);
    try std.testing.expect(plugin.on_commit != null);
    try std.testing.expect(plugin.on_agent_operation != null);
    try std.testing.expect(plugin.on_perf_sample != null);
}

test "PerfAnalyzerState multiple operations" {
    var state = try PerfAnalyzerState.init(std.testing.allocator, .{});
    defer state.deinit();

    // Record various operations
    try state.recordOperation("read", "btree", 5.0, "completed");
    try state.recordOperation("read", "pager", 2.0, "completed");
    try state.recordOperation("write", "btree", 15.0, "completed");
    try state.recordOperation("write", "pager", 8.0, "failed");

    // Verify separate tracking
    const read_btree = state.getOperationStats("read", "btree");
    try std.testing.expect(read_btree != null);
    try std.testing.expectEqual(@as(usize, 1), read_btree.?.count);

    const read_pager = state.getOperationStats("read", "pager");
    try std.testing.expect(read_pager != null);
    try std.testing.expectEqual(@as(usize, 1), read_pager.?.count);

    const write_btree = state.getOperationStats("write", "btree");
    try std.testing.expect(write_btree != null);
    try std.testing.expectEqual(@as(usize, 1), write_btree.?.count);

    const write_pager = state.getOperationStats("write", "pager");
    try std.testing.expect(write_pager != null);
    try std.testing.expectEqual(@as(usize, 1), write_pager.?.error_count);
}

test "on_commit hook" {
    const txn = @import("../txn.zig");
    const mutations = [_]txn.Mutation{};

    var ctx = manager.CommitContext{
        .txn_id = 1,
        .mutations = &mutations,
        .timestamp = @intCast(std.time.nanoTimestamp()),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer ctx.deinit(std.testing.allocator);

    const result = try on_commit(std.testing.allocator, ctx);
    try std.testing.expect(result.success);
}

test "on_agent_operation hook" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_hook_events.dat",
        .index_path = "test_hook_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    }

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);

    var metadata = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        metadata.deinit();
    }

    const duration_ns: i64 = 5_000_000;
    try metadata.put("commit_range", try allocator.dupe(u8, "abc123..def456"));

    var ctx = manager.AgentOperationContext{
        .agent_id = 1,
        .session_id = 100,
        .operation_type = "read",
        .operation_id = 1,
        .target_type = "btree",
        .target_id = "test_key",
        .status = "completed",
        .duration_ns = duration_ns,
        .metadata = metadata,
        .event_manager = &event_manager,
    };

    try on_agent_operation(allocator, ctx);

    // Verify event was recorded
    const events_list = try event_manager.query(.{
        .event_types = &[_]events.types.EventType{.perf_sample},
        .limit = 10,
    });
    defer {
        for (events_list) |*e| e.deinit();
        allocator.free(events_list);
    }

    try std.testing.expect(events_list.len > 0);
}
