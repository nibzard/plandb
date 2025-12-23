//! AI operations observability and debugging
//!
//! Provides comprehensive observability for AI operations including:
//! - Metrics collection (counters, gauges, histograms) with OpenMetrics export
//! - Distributed tracing with correlation ID propagation
//! - Debug CLI for inspecting AI operation state
//! - Integration with existing audit logging and plugin tracing
//!
//! # Quick Start
//!
//! ```zig
//! const observability = @import("observability");
//!
//! // Initialize observability stack
//! var metrics = try observability.MetricsCollector.init(allocator, .{});
//! defer metrics.deinit();
//!
//! var trace_mgr = observability.TraceManager.init(allocator, .{});
//! defer trace_mgr.deinit();
//!
//! var debug_if = try observability.DebugInterface.init(allocator, &metrics, &trace_mgr);
//! defer debug_if.deinit();
//!
//! // Record an LLM call
//! try metrics.recordLLMCall(.{
//!     .provider = "openai",
//!     .model = "gpt-4",
//!     .input_tokens = 100,
//!     .output_tokens = 50,
//!     .cost = 0.01,
//!     .latency_ms = 500,
//!     .success = true,
//! });
//!
//! // Start a trace span
//! const span = try trace_mgr.startSpan("ai_operation", .client, null);
//! defer trace_mgr.endSpan(span, .ok) catch {};
//!
//! // Export metrics
//! try metrics.exportOpenMetrics(writer);
//! ```

const std = @import("std");

pub const metrics = @import("metrics.zig");
pub const tracing = @import("tracing.zig");
pub const debug = @import("debug.zig");

// Re-export main types
pub const MetricsCollector = metrics.MetricsCollector;
pub const TraceManager = tracing.TraceManager;
pub const DebugInterface = debug.DebugInterface;

// Re-export metric types
pub const Counter = metrics.Counter;
pub const Gauge = metrics.Gauge;
pub const Histogram = metrics.Histogram;

// Re-export trace types
pub const TraceSpan = tracing.TraceSpan;
pub const SpanKind = tracing.SpanKind;
pub const SpanStatus = tracing.SpanStatus;
pub const AttributeValue = tracing.AttributeValue;

// Re-export configuration
pub const MetricsConfig = metrics.Config;
pub const TraceConfig = tracing.Config;

/// Unified observability manager
///
/// Combines metrics collection, tracing, and debugging into a single
/// easy-to-use interface for AI operations.
pub const ObservabilityManager = struct {
    allocator: std.mem.Allocator,
    metrics: MetricsCollector,
    trace_manager: TraceManager,
    debug_interface: DebugInterface,
    config: ManagerConfig,

    const Self = @This();

    /// Initialize the observability stack
    pub fn init(allocator: std.mem.Allocator, config: ManagerConfig) !Self {
        var metrics_collector = try MetricsCollector.init(allocator, config.metrics);
        var trace_mgr = TraceManager.init(allocator, config.tracing);
        const debug_if = try DebugInterface.init(allocator, &metrics_collector, &trace_mgr);

        return ObservabilityManager{
            .allocator = allocator,
            .metrics = metrics_collector,
            .trace_manager = trace_mgr,
            .debug_interface = debug_if,
            .config = config,
        };
    }

    /// Clean up all observability resources
    pub fn deinit(self: *Self) void {
        self.debug_interface.deinit();
        self.trace_manager.deinit();
        self.metrics.deinit();
    }

    /// Execute a debug command
    pub fn executeDebugCommand(self: *Self, command: []const u8) ![]const u8 {
        return self.debug_interface.executeCommand(command);
    }

    /// Get current observability status
    pub fn getStatus(self: *const Self) ManagerStatus {
        return ManagerStatus{
            .active_spans = self.trace_manager.activeSpanCount(),
            .completed_spans = self.trace_manager.completedSpanCount(),
            .counter_count = self.metrics.counters.count(),
            .gauge_count = self.metrics.gauges.count(),
            .histogram_count = self.metrics.histograms.count(),
        };
    }

    /// Export all observability data as JSON
    pub fn exportJson(self: *const Self, writer: anytype) !void {
        try writer.writeAll("{");

        // Write metrics
        try writer.writeAll("\"metrics\":");
        try self.metrics.exportJson(writer);

        try writer.writeAll(",\"traces\":");
        try self.trace_manager.exportJson(writer);

        try writer.writeAll(",\"status\":");
        const status = self.getStatus();
        try writer.print("{{\"active_spans\":{d},\"completed_spans\":{d},\"metrics\":{d}}", .{
            status.active_spans,
            status.completed_spans,
            status.counter_count + status.gauge_count + status.histogram_count,
        });

        try writer.writeAll("}");
    }

    /// Export metrics in OpenMetrics format
    pub fn exportOpenMetrics(self: *const Self, writer: anytype) !void {
        try self.metrics.exportOpenMetrics(writer);
    }
};

/// Configuration for the observability manager
pub const ManagerConfig = struct {
    metrics: metrics.Config = .{},
    tracing: tracing.Config = .{},
};

/// Status snapshot of the observability system
pub const ManagerStatus = struct {
    active_spans: usize,
    completed_spans: usize,
    counter_count: usize,
    gauge_count: usize,
    histogram_count: usize,
};

// ==================== Integration with Existing Systems ====================

/// Helper to integrate with audit logger
pub fn integrateWithAuditLogger(audit_logger: anytype) !void {
    _ = audit_logger;
    // In production, would wire up audit events to metrics
}

/// Helper to integrate with plugin tracer
pub fn integrateWithPluginTracer(tracer: anytype) !void {
    _ = tracer;
    // In production, would wire up plugin traces to trace manager
}

// ==================== Tests ====================//

test "ObservabilityManager init" {
    var manager = try ObservabilityManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const status = manager.getStatus();
    try std.testing.expectEqual(@as(usize, 0), status.active_spans);
}

test "ObservabilityManager executeDebugCommand" {
    var manager = try ObservabilityManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const result = try manager.executeDebugCommand("help");
    defer std.testing.allocator.free(result);

    try std.testing.expect(result.len > 0);
}

test "ObservabilityManager getStatus" {
    var manager = try ObservabilityManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const status = manager.getStatus();
    try std.testing.expect(status.counter_count > 0);
    try std.testing.expect(status.gauge_count > 0);
    try std.testing.expect(status.histogram_count > 0);
}

test "ObservabilityManager recordLLMCall" {
    var manager = try ObservabilityManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    try manager.metrics.startLLMCall("openai", "gpt-4");

    const call = metrics.LLMCallMetrics{
        .provider = "openai",
        .model = "gpt-4",
        .input_tokens = 100,
        .output_tokens = 50,
        .cost = 0.01,
        .latency_ms = 500,
        .success = true,
    };

    try manager.metrics.recordLLMCall(call);

    const total_calls = manager.metrics.counters.get("ai_llm_calls_total").?;
    try std.testing.expectEqual(@as(u64, 1), total_calls.get());
}

test "ObservabilityManager startSpan" {
    var manager = try ObservabilityManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const span = try manager.trace_manager.startSpan("test_operation", .internal, null);
    try manager.trace_manager.endSpan(span, .ok);

    try std.testing.expectEqual(@as(usize, 1), manager.trace_manager.completedSpanCount());
}

test "ObservabilityManager exportJson" {
    var manager = try ObservabilityManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try manager.exportJson(buffer.writer());

    try std.testing.expect(buffer.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"metrics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"traces\"") != null);
}

test "ObservabilityManager exportOpenMetrics" {
    var manager = try ObservabilityManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try manager.exportOpenMetrics(buffer.writer());

    try std.testing.expect(buffer.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "# TYPE") != null);
}
