//! Debugging utilities and CLI for AI operations
//!
//! Provides debugging tools and CLI commands for:
//! - Inspecting active traces and spans
//! - Viewing metrics snapshots
//! - Querying observability data
//! - Diagnosing AI operation issues
//!
//! CLI Commands:
//! - `ai debug traces` - List active/completed traces
//! - `ai debug spans` - Show detailed span information
//! - `ai debug metrics` - Display current metrics
//! - `ai debug llm` - Show LLM call history
//! - `ai debug plugins` - Show plugin execution history

const std = @import("std");
const metrics_mod = @import("metrics.zig");
const tracing_mod = @import("tracing.zig");

/// Debug interface for AI operations
pub const DebugInterface = struct {
    allocator: std.mem.Allocator,
    metrics_collector: *metrics_mod.MetricsCollector,
    trace_manager: *tracing_mod.TraceManager,
    command_handlers: std.StringHashMap(CommandHandler),
    output_buffer: std.ArrayList(u8),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        metrics_collector: *metrics_mod.MetricsCollector,
        trace_manager: *tracing_mod.TraceManager,
    ) !Self {
        var debug_if = DebugInterface{
            .allocator = allocator,
            .metrics_collector = metrics_collector,
            .trace_manager = trace_manager,
            .command_handlers = std.StringHashMap(CommandHandler).init(allocator),
            .output_buffer = std.ArrayList(u8){},
        };

        // Register command handlers
        try debug_if.registerCommands();

        return debug_if;
    }

    pub fn deinit(self: *Self) void {
        var it = self.command_handlers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.command_handlers.deinit();
        self.output_buffer.deinit(self.allocator);
    }

    /// Execute a debug command
    pub fn executeCommand(self: *Self, command: []const u8) ![]const u8 {
        self.output_buffer.clearRetainingCapacity();

        var parts = std.mem.splitScalar(u8, command, ' ');
        const cmd_name = parts.next() orelse return error.EmptyCommand;
        const remaining = parts.rest();

        const handler = self.command_handlers.get(cmd_name) orelse {
            try self.output_buffer.appendSlice(self.allocator, "Unknown command. Available commands:\n");
            try self.listCommands(&self.output_buffer);
            return self.output_buffer.toOwnedSlice(self.allocator);
        };

        try handler.fn_ptr(self, remaining);

        return self.output_buffer.toOwnedSlice(self.allocator);
    }

    /// Get formatted help text
    pub fn getHelp(self: *Self) ![]const u8 {
        var buffer = std.ArrayList(u8){};
        try buffer.appendSlice(self.allocator, "AI Debug Commands:\n\n");

        var it = self.command_handlers.iterator();
        while (it.next()) |entry| {
            try buffer.print(self.allocator, "  {s} - {s}\n", .{ entry.key_ptr.*, entry.value_ptr.description });
        }

        return buffer.toOwnedSlice(self.allocator);
    }

    fn registerCommands(self: *Self) !void {
        // Trace commands
        try self.registerCommand("traces", .{
            .fn_ptr = &cmdTraces,
            .description = "List all traces (use 'traces active' or 'traces completed')",
        });
        try self.registerCommand("span", .{
            .fn_ptr = &cmdSpan,
            .description = "Show detailed span info (usage: span <span_id>)",
        });
        try self.registerCommand("tree", .{
            .fn_ptr = &cmdTree,
            .description = "Show trace tree (usage: tree <trace_id>)",
        });

        // Metrics commands
        try self.registerCommand("metrics", .{
            .fn_ptr = &cmdMetrics,
            .description = "Show current metrics snapshot",
        });
        try self.registerCommand("counters", .{
            .fn_ptr = &cmdCounters,
            .description = "Show all counter values",
        });
        try self.registerCommand("gauges", .{
            .fn_ptr = &cmdGauges,
            .description = "Show all gauge values",
        });

        // AI-specific commands
        try self.registerCommand("llm", .{
            .fn_ptr = &cmdLLM,
            .description = "Show LLM call statistics",
        });
        try self.registerCommand("plugins", .{
            .fn_ptr = &cmdPlugins,
            .description = "Show plugin execution statistics",
        });
        try self.registerCommand("entities", .{
            .fn_ptr = &cmdEntities,
            .description = "Show entity extraction statistics",
        });
        try self.registerCommand("queries", .{
            .fn_ptr = &cmdQueries,
            .description = "Show query performance statistics",
        });

        // Utility commands
        try self.registerCommand("export", .{
            .fn_ptr = &cmdExport,
            .description = "Export metrics/traces (usage: export <format> [json|openmetrics])",
        });
        try self.registerCommand("status", .{
            .fn_ptr = &cmdStatus,
            .description = "Show overall observability status",
        });
        try self.registerCommand("help", .{
            .fn_ptr = &cmdHelp,
            .description = "Show this help message",
        });
    }

    fn registerCommand(self: *Self, name: []const u8, handler: CommandHandler) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.command_handlers.put(name_copy, handler);
    }

    fn listCommands(self: *Self, buffer: *std.ArrayList(u8)) !void {
        var it = self.command_handlers.iterator();
        while (it.next()) |entry| {
            try buffer.print(self.allocator, "  {s} - {s}\n", .{ entry.key_ptr.*, entry.value_ptr.description });
        }
    }

    // ==================== Command Handlers ====================

    fn cmdTraces(self: *Self, args_str: []const u8) anyerror!void {
        var parts = std.mem.splitScalar(u8, args_str, ' ');
        const filter = parts.next();

        try self.output_buffer.appendSlice(self.allocator, "=== Traces ===\n\n");

        if (filter) |f| {
            if (std.mem.eql(u8, f, "active")) {
                try self.printActiveTraces();
            } else if (std.mem.eql(u8, f, "completed")) {
                try self.printCompletedTraces();
            } else {
                try self.output_buffer.appendSlice(self.allocator, "Unknown filter. Use 'active' or 'completed'\n");
            }
        } else {
            try self.output_buffer.appendSlice(self.allocator, "Active:\n");
            try self.printActiveTraces();
            try self.output_buffer.appendSlice(self.allocator, "\nCompleted:\n");
            try self.printCompletedTraces();
        }
    }

    fn cmdSpan(self: *Self, args_str: []const u8) anyerror!void {
        var parts = std.mem.splitScalar(u8, args_str, ' ');
        const span_id = parts.next() orelse {
            try self.output_buffer.appendSlice(self.allocator, "Usage: span <span_id>\n");
            return;
        };

        // Search for span in both active and completed
        var found = false;

        for (self.trace_manager.active_spans.items) |span| {
            if (span.span_id) |id| {
                if (std.mem.eql(u8, id, span_id)) {
                    try self.printSpanDetails(span);
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            for (self.trace_manager.completed_spans.items) |span| {
                if (span.span_id) |id| {
                    if (std.mem.eql(u8, id, span_id)) {
                        try self.printSpanDetails(span);
                        found = true;
                        break;
                    }
                }
            }
        }

        if (!found) {
            try self.output_buffer.print(self.allocator, "Span '{s}' not found\n", .{span_id});
        }
    }

    fn cmdTree(self: *Self, args_str: []const u8) anyerror!void {
        var parts = std.mem.splitScalar(u8, args_str, ' ');
        const trace_id = parts.next() orelse {
            try self.output_buffer.appendSlice(self.allocator, "Usage: tree <trace_id>\n");
            return;
        };

        var tree_opt = try self.trace_manager.getTraceTree(trace_id);
        if (tree_opt == null) {
            try self.output_buffer.print(self.allocator, "Trace '{s}' not found\n", .{trace_id});
            return;
        }
        defer tree_opt.?.deinit(self.allocator);

        try self.output_buffer.print(self.allocator, "=== Trace Tree: {s} ===\n", .{trace_id});
        try self.output_buffer.print(self.allocator, "Total spans: {d}\n\n", .{tree_opt.?.span_count});

        try self.printTreeNode(tree_opt.?.root, 0);
    }

    fn cmdMetrics(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        var snapshot = try self.metrics_collector.snapshot();
        defer snapshot.deinit();

        try self.output_buffer.appendSlice(self.allocator, "=== Metrics Snapshot ===\n");
        try self.output_buffer.print(self.allocator, "Timestamp: {d}\n\n", .{snapshot.timestamp_ms});

        try self.output_buffer.appendSlice(self.allocator, "Counters:\n");
        var counter_it = snapshot.counters.iterator();
        while (counter_it.next()) |entry| {
            try self.output_buffer.print(self.allocator, "  {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try self.output_buffer.appendSlice(self.allocator, "\nGauges:\n");
        var gauge_it = snapshot.gauges.iterator();
        while (gauge_it.next()) |entry| {
            try self.output_buffer.print(self.allocator, "  {s}: {d:.6}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn cmdCounters(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        var snapshot = try self.metrics_collector.snapshot();
        defer snapshot.deinit();

        try self.output_buffer.appendSlice(self.allocator, "=== Counters ===\n");
        var it = snapshot.counters.iterator();
        while (it.next()) |entry| {
            try self.output_buffer.print(self.allocator, "  {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn cmdGauges(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        var snapshot = try self.metrics_collector.snapshot();
        defer snapshot.deinit();

        try self.output_buffer.appendSlice(self.allocator, "=== Gauges ===\n");
        var it = snapshot.gauges.iterator();
        while (it.next()) |entry| {
            try self.output_buffer.print(self.allocator, "  {s}: {d:.6}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn cmdLLM(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        try self.output_buffer.appendSlice(self.allocator, "=== LLM Call Statistics ===\n");

        const total_calls = if (self.metrics_collector.counters.get("ai_llm_calls_total")) |c| c.get() else 0;
        const total_tokens = if (self.metrics_collector.counters.get("ai_llm_tokens_total")) |c| c.get() else 0;
        const total_cost = if (self.metrics_collector.counters.get("ai_llm_cost_usd")) |c| c.get() else 0;
        const active_calls = if (self.metrics_collector.gauges.get("ai_llm_active_calls")) |g| g.get() else 0;

        try self.output_buffer.print(self.allocator, "Total calls: {d}\n", .{total_calls});
        try self.output_buffer.print(self.allocator, "Total tokens: {d}\n", .{total_tokens});
        try self.output_buffer.print(self.allocator, "Total cost: ${d:.6}\n", .{@as(f64, @floatFromInt(total_cost)) / 1000000.0});
        try self.output_buffer.print(self.allocator, "Active calls: {d}\n", .{active_calls});
    }

    fn cmdPlugins(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        try self.output_buffer.appendSlice(self.allocator, "=== Plugin Execution Statistics ===\n");

        const total_executions = if (self.metrics_collector.counters.get("ai_plugin_executions_total")) |c| c.get() else 0;

        try self.output_buffer.print(self.allocator, "Total executions: {d}\n", .{total_executions});
    }

    fn cmdEntities(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        try self.output_buffer.appendSlice(self.allocator, "=== Entity Extraction Statistics ===\n");

        const total_extractions = if (self.metrics_collector.counters.get("ai_entity_extractions_total")) |c| c.get() else 0;

        try self.output_buffer.print(self.allocator, "Total extractions: {d}\n", .{total_extractions});
    }

    fn cmdQueries(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        try self.output_buffer.appendSlice(self.allocator, "=== Query Statistics ===\n");

        const total_queries = if (self.metrics_collector.counters.get("ai_queries_total")) |c| c.get() else 0;
        const scan_ratio = if (self.metrics_collector.gauges.get("ai_query_scan_ratio")) |g| g.get() else 0;

        try self.output_buffer.print(self.allocator, "Total queries: {d}\n", .{total_queries});
        try self.output_buffer.print(self.allocator, "Scan ratio: {d:.4}\n", .{scan_ratio});
    }

    fn cmdExport(self: *Self, args_str: []const u8) anyerror!void {
        var parts = std.mem.splitScalar(u8, args_str, ' ');
        const format = parts.next() orelse {
            try self.output_buffer.appendSlice(self.allocator, "Usage: export <format> (json|openmetrics)\n");
            return;
        };

        if (std.mem.eql(u8, format, "json")) {
            try self.metrics_collector.exportJson(self.output_buffer.writer(self.allocator));
        } else if (std.mem.eql(u8, format, "openmetrics")) {
            try self.metrics_collector.exportOpenMetrics(self.output_buffer.writer(self.allocator));
        } else {
            try self.output_buffer.print(self.allocator, "Unknown format: {s}\n", .{format});
        }
    }

    fn cmdStatus(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        try self.output_buffer.appendSlice(self.allocator, "=== Observability Status ===\n\n");

        try self.output_buffer.appendSlice(self.allocator, "Trace Manager:\n");
        try self.output_buffer.print(self.allocator, "  Active spans: {d}\n", .{self.trace_manager.activeSpanCount()});
        try self.output_buffer.print(self.allocator, "  Completed spans: {d}\n", .{self.trace_manager.completedSpanCount()});

        try self.output_buffer.appendSlice(self.allocator, "\nMetrics Collector:\n");
        try self.output_buffer.print(self.allocator, "  Counters: {d}\n", .{self.metrics_collector.counters.count()});
        try self.output_buffer.print(self.allocator, "  Gauges: {d}\n", .{self.metrics_collector.gauges.count()});
        try self.output_buffer.print(self.allocator, "  Histograms: {d}\n", .{self.metrics_collector.histograms.count()});
    }

    fn cmdHelp(self: *Self, args_str: []const u8) anyerror!void {
        _ = args_str;
        const help = try self.getHelp();
        defer self.allocator.free(help);
        try self.output_buffer.appendSlice(self.allocator, help);
    }

    // ==================== Print Helpers ====================

    fn printActiveTraces(self: *Self) !void {
        const count = self.trace_manager.activeSpanCount();
        if (count == 0) {
            try self.output_buffer.appendSlice(self.allocator, "  (none)\n");
            return;
        }

        for (self.trace_manager.active_spans.items) |span| {
            const duration = if (span.getDurationNs()) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else null;
            try self.output_buffer.print(self.allocator, "  [{s}] {s}", .{ @tagName(span.kind), span.name });
            if (duration) |d| {
                try self.output_buffer.print(self.allocator, " ({d:.2}ms)", .{d});
            }
            try self.output_buffer.appendSlice(self.allocator, "\n");
        }
    }

    fn printCompletedTraces(self: *Self) !void {
        const count = self.trace_manager.completedSpanCount();
        if (count == 0) {
            try self.output_buffer.appendSlice(self.allocator, "  (none)\n");
            return;
        }

        // Show last 10
        const start = if (count > 10) count - 10 else 0;
        var i: usize = start;
        while (i < count) : (i += 1) {
            const span = self.trace_manager.completed_spans.items[i];
            const duration = if (span.getDurationNs()) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else 0;
            try self.output_buffer.print(self.allocator, "  [{s}] {s} ({d:.2}ms) - {s}\n", .{
                @tagName(span.kind),
                span.name,
                duration,
                @tagName(span.status),
            });
        }
    }

    fn printSpanDetails(self: *Self, span: *const tracing_mod.TraceSpan) !void {
        try self.output_buffer.print(self.allocator, "=== Span: {s} ===\n", .{span.name});
        try self.output_buffer.print(self.allocator, "ID: {s}\n", .{if (span.span_id) |id| id else "(none)"});
        try self.output_buffer.print(self.allocator, "Trace ID: {s}\n", .{span.trace_id});
        try self.output_buffer.print(self.allocator, "Kind: {s}\n", .{@tagName(span.kind)});
        try self.output_buffer.print(self.allocator, "Status: {s}\n", .{@tagName(span.status)});

        const duration = if (span.getDurationNs()) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else null;
        if (duration) |d| {
            try self.output_buffer.print(self.allocator, "Duration: {d:.2}ms\n", .{d});
        }

        if (span.attributes.count() > 0) {
            try self.output_buffer.appendSlice(self.allocator, "\nAttributes:\n");
            var it = span.attributes.iterator();
            while (it.next()) |entry| {
                try self.output_buffer.print(self.allocator, "  {s}: ", .{entry.key_ptr.*});
                try self.printAttributeValue(entry.value_ptr.*);
                try self.output_buffer.appendSlice(self.allocator, "\n");
            }
        }

        if (span.events.items.len > 0) {
            try self.output_buffer.appendSlice(self.allocator, "\nEvents:\n");
            for (span.events.items) |event| {
                try self.output_buffer.print(self.allocator, "  {s}\n", .{event.name});
            }
        }
    }

    fn printTreeNode(self: *Self, node: *const tracing_mod.TreeNode, depth: usize) !void {
        // Generate indent string by repeating
        var indent_buf: [128]u8 = undefined;
        var indent_idx: usize = 0;
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            if (indent_idx + 2 <= indent_buf.len) {
                @memcpy(indent_buf[indent_idx..][0..2], "  ");
                indent_idx += 2;
            }
        }
        const indent = indent_buf[0..indent_idx];

        const duration = if (node.span.getDurationNs()) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else 0;

        try self.output_buffer.print(self.allocator, "{s}[{s}] {s} ({d:.2}ms)\n", .{
            indent,
            @tagName(node.span.kind),
            node.span.name,
            duration,
        });

        for (node.children.items) |child| {
            try self.printTreeNode(child, depth + 1);
        }
    }

    fn printAttributeValue(self: *Self, value: tracing_mod.AttributeValue) !void {
        switch (value) {
            .string => |s| try self.output_buffer.print(self.allocator, "\"{s}\"", .{s}),
            .int => |i| try self.output_buffer.print(self.allocator, "{d}", .{i}),
            .float => |f| try self.output_buffer.print(self.allocator, "{d}", .{f}),
            .bool => |b| try self.output_buffer.print(self.allocator, "{}", .{b}),
            .string_array => |arr| {
                try self.output_buffer.appendSlice(self.allocator, "[");
                for (arr, 0..) |s, i| {
                    if (i > 0) try self.output_buffer.appendSlice(self.allocator, ", ");
                    try self.output_buffer.print(self.allocator, "\"{s}\"", .{s});
                }
                try self.output_buffer.appendSlice(self.allocator, "]");
            },
        }
    }
};

// ==================== Types ====================

pub const CommandHandler = struct {
    fn_ptr: *const fn (*DebugInterface, []const u8) anyerror!void,
    description: []const u8,
};

// ==================== Tests ====================//

test "DebugInterface init" {
    var metrics = try metrics_mod.MetricsCollector.init(std.testing.allocator, .{});
    defer metrics.deinit();

    var trace_mgr = tracing_mod.TraceManager.init(std.testing.allocator, .{});
    defer trace_mgr.deinit();

    var debug_if = try DebugInterface.init(std.testing.allocator, &metrics, &trace_mgr);
    defer debug_if.deinit();

    try std.testing.expect(debug_if.command_handlers.count() > 0);
}

test "DebugInterface executeCommand help" {
    var metrics = try metrics_mod.MetricsCollector.init(std.testing.allocator, .{});
    defer metrics.deinit();

    var trace_mgr = tracing_mod.TraceManager.init(std.testing.allocator, .{});
    defer trace_mgr.deinit();

    var debug_if = try DebugInterface.init(std.testing.allocator, &metrics, &trace_mgr);
    defer debug_if.deinit();

    const result = try debug_if.executeCommand("help");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Commands") != null);
}

test "DebugInterface executeCommand status" {
    var metrics = try metrics_mod.MetricsCollector.init(std.testing.allocator, .{});
    defer metrics.deinit();

    var trace_mgr = tracing_mod.TraceManager.init(std.testing.allocator, .{});
    defer trace_mgr.deinit();

    var debug_if = try DebugInterface.init(std.testing.allocator, &metrics, &trace_mgr);
    defer debug_if.deinit();

    const result = try debug_if.executeCommand("status");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Observability Status") != null);
}

test "DebugInterface executeCommand unknown" {
    var metrics = try metrics_mod.MetricsCollector.init(std.testing.allocator, .{});
    defer metrics.deinit();

    var trace_mgr = tracing_mod.TraceManager.init(std.testing.allocator, .{});
    defer trace_mgr.deinit();

    var debug_if = try DebugInterface.init(std.testing.allocator, &metrics, &trace_mgr);
    defer debug_if.deinit();

    const result = try debug_if.executeCommand("unknown_command");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Unknown command") != null);
}

test "DebugInterface executeCommand traces" {
    var metrics = try metrics_mod.MetricsCollector.init(std.testing.allocator, .{});
    defer metrics.deinit();

    var trace_mgr = tracing_mod.TraceManager.init(std.testing.allocator, .{});
    defer trace_mgr.deinit();

    var debug_if = try DebugInterface.init(std.testing.allocator, &metrics, &trace_mgr);
    defer debug_if.deinit();

    const result = try debug_if.executeCommand("traces");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Traces") != null);
}

test "DebugInterface executeCommand metrics" {
    var metrics = try metrics_mod.MetricsCollector.init(std.testing.allocator, .{});
    defer metrics.deinit();

    var trace_mgr = tracing_mod.TraceManager.init(std.testing.allocator, .{});
    defer trace_mgr.deinit();

    var debug_if = try DebugInterface.init(std.testing.allocator, &metrics, &trace_mgr);
    defer debug_if.deinit();

    const result = try debug_if.executeCommand("metrics");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Metrics Snapshot") != null);
}

test "DebugInterface getHelp" {
    var metrics = try metrics_mod.MetricsCollector.init(std.testing.allocator, .{});
    defer metrics.deinit();

    var trace_mgr = tracing_mod.TraceManager.init(std.testing.allocator, .{});
    defer trace_mgr.deinit();

    var debug_if = try DebugInterface.init(std.testing.allocator, &metrics, &trace_mgr);
    defer debug_if.deinit();

    const help = try debug_if.getHelp();
    defer std.testing.allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "Commands") != null);
}

test "DebugInterface executeCommand export" {
    var metrics = try metrics_mod.MetricsCollector.init(std.testing.allocator, .{});
    defer metrics.deinit();

    var trace_mgr = tracing_mod.TraceManager.init(std.testing.allocator, .{});
    defer trace_mgr.deinit();

    var debug_if = try DebugInterface.init(std.testing.allocator, &metrics, &trace_mgr);
    defer debug_if.deinit();

    const result = try debug_if.executeCommand("export json");
    defer std.testing.allocator.free(result);

    // Should contain JSON
    try std.testing.expect(std.mem.indexOf(u8, result, "{") != null);
}
