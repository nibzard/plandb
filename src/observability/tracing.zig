//! Distributed tracing for AI operations
//!
//! Provides distributed tracing with correlation ID propagation across:
//! - LLM API calls (request/response tracking)
//! - Plugin execution (hook lifecycle)
//! - Entity extraction operations
//! - Query planning and execution
//!
//! Compatible with OpenTelemetry trace format for integration with observability platforms.

const std = @import("std");

/// Trace manager for AI operations
pub const TraceManager = struct {
    allocator: std.mem.Allocator,
    active_spans: std.ArrayList(*TraceSpan),
    completed_spans: std.ArrayList(*TraceSpan),
    config: Config,
    correlation_id_gen: CorrelationIdGenerator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return TraceManager{
            .allocator = allocator,
            .active_spans = std.ArrayList(*TraceSpan){},
            .completed_spans = std.ArrayList(*TraceSpan){},
            .config = config,
            .correlation_id_gen = CorrelationIdGenerator.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.active_spans.items) |span| {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }
        self.active_spans.deinit(self.allocator);

        for (self.completed_spans.items) |span| {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }
        self.completed_spans.deinit(self.allocator);
    }

    /// Start a new trace span
    pub fn startSpan(
        self: *Self,
        name: []const u8,
        span_kind: SpanKind,
        parent_id: ?[]const u8,
    ) !*TraceSpan {
        const span_id = try self.generateSpanId();
        const correlation_id = if (parent_id) |pid|
            self.getCorrelationIdForParent(pid)
        else
            try self.correlation_id_gen.generate();

        const span = try self.allocator.create(TraceSpan);
        span.* = TraceSpan{
            .name = try self.allocator.dupe(u8, name),
            .span_id = span_id,
            .parent_span_id = if (parent_id) |pid|
                try self.allocator.dupe(u8, pid)
            else
                null,
            .trace_id = correlation_id,
            .kind = span_kind,
            .start_time_ns = @intCast(std.time.nanoTimestamp()),
            .end_time_ns = null,
            .status = .unset,
            .attributes = std.StringHashMap(AttributeValue).init(self.allocator),
            .events = std.ArrayList(SpanEvent){},
            .links = std.ArrayList(SpanLink){},
        };

        try self.active_spans.append(self.allocator, span);
        return span;
    }

    /// End a trace span
    pub fn endSpan(self: *Self, span: *TraceSpan, status: SpanStatus) !void {
        span.end_time_ns = @intCast(std.time.nanoTimestamp());
        span.status = status;

        // Move from active to completed
        var i: usize = 0;
        while (i < self.active_spans.items.len) : (i += 1) {
            if (self.active_spans.items[i] == span) {
                _ = self.active_spans.orderedRemove(i);
                break;
            }
        }

        try self.completed_spans.append(self.allocator, span);

        // Trim completed spans if too many
        if (self.completed_spans.items.len > self.config.max_completed_spans) {
            const old = self.completed_spans.orderedRemove(0);
            old.deinit(self.allocator);
            self.allocator.destroy(old);
        }
    }

    /// Add attribute to span
    pub fn setAttribute(self: *Self, span: *TraceSpan, key: []const u8, value: AttributeValue) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try value.copy(self.allocator);
        try span.attributes.put(key_copy, value_copy);
    }

    /// Add event to span
    pub fn addEvent(self: *Self, span: *TraceSpan, event: SpanEvent) !void {
        const event_copy = try event.copy(self.allocator);
        try span.events.append(self.allocator, event_copy);
    }

    /// Record LLM call in span
    pub fn recordLLMCall(
        self: *Self,
        span: *TraceSpan,
        provider: []const u8,
        model: []const u8,
        function_name: []const u8,
        input_tokens: u64,
        output_tokens: u64,
        latency_ms: f64,
    ) !void {
        try self.setAttribute(span, "llm.provider", .{ .string = try self.allocator.dupe(u8, provider) });
        try self.setAttribute(span, "llm.model", .{ .string = try self.allocator.dupe(u8, model) });
        try self.setAttribute(span, "llm.function", .{ .string = try self.allocator.dupe(u8, function_name) });
        try self.setAttribute(span, "llm.input_tokens", .{ .int = @intCast(input_tokens) });
        try self.setAttribute(span, "llm.output_tokens", .{ .int = @intCast(output_tokens) });
        try self.setAttribute(span, "llm.latency_ms", .{ .float = latency_ms });
    }

    /// Record plugin execution in span
    pub fn recordPluginExecution(
        self: *Self,
        span: *TraceSpan,
        plugin_name: []const u8,
        hook_type: []const u8,
        execution_time_ms: f64,
        success: bool,
    ) !void {
        try self.setAttribute(span, "plugin.name", .{ .string = try self.allocator.dupe(u8, plugin_name) });
        try self.setAttribute(span, "plugin.hook", .{ .string = try self.allocator.dupe(u8, hook_type) });
        try self.setAttribute(span, "plugin.execution_ms", .{ .float = execution_time_ms });
        try self.setAttribute(span, "plugin.success", .{ .bool = success });
    }

    /// Get trace tree for a correlation ID
    pub fn getTraceTree(self: *Self, trace_id: []const u8) !?TraceTree {
        var spans = std.ArrayList(*TraceSpan){};

        for (self.completed_spans.items) |span| {
            if (std.mem.eql(u8, span.trace_id, trace_id)) {
                try spans.append(self.allocator, span);
            }
        }

        if (spans.items.len == 0) return null;

        // Build tree structure
        const root = try self.buildTraceTree(spans.items);
        return TraceTree{
            .root = root,
            .trace_id = try self.allocator.dupe(u8, trace_id),
            .span_count = spans.items.len,
        };
    }

    /// Export traces in JSON format
    pub fn exportJson(self: *const Self, writer: anytype) !void {
        try writer.writeAll("{\"traces\":[");

        var trace_map = std.StringHashMap(std.ArrayList(*TraceSpan)).init(self.allocator);
        defer {
            var it = trace_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            trace_map.deinit();
        }

        // Group spans by trace_id
        for (self.completed_spans.items) |span| {
            const entry = try trace_map.getOrPut(span.trace_id);
            if (!entry.found_existing) {
                entry.key_ptr.* = try self.allocator.dupe(u8, span.trace_id);
                entry.value_ptr.* = std.ArrayList(*TraceSpan){};
            }
            try entry.value_ptr.append(self.allocator, span);
        }

        var first = true;
        var trace_it = trace_map.iterator();
        while (trace_it.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            try writer.writeAll("{\"trace_id\":\"");
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeAll("\",\"spans\":[");

            var span_first = true;
            for (entry.value_ptr.items) |span| {
                if (!span_first) try writer.writeAll(",");
                span_first = false;
                try self.writeSpanJson(span, writer);
            }

            try writer.writeAll("]}");
        }

        try writer.writeAll("]}");
    }

    /// Get active span count
    pub fn activeSpanCount(self: *const Self) usize {
        return self.active_spans.items.len;
    }

    /// Get completed span count
    pub fn completedSpanCount(self: *const Self) usize {
        return self.completed_spans.items.len;
    }

    fn generateSpanId(self: *Self) ![]const u8 {
        const id = try self.correlation_id_gen.generate();
        return try std.fmt.allocPrint(self.allocator, "span_{s}", .{id});
    }

    fn getCorrelationIdForParent(self: *Self, parent_id: []const u8) []const u8 {
        // Find parent span and return its trace_id
        for (self.active_spans.items) |span| {
            if (span.span_id != null and std.mem.eql(u8, span.span_id.?, parent_id)) {
                return span.trace_id;
            }
        }
        for (self.completed_spans.items) |span| {
            if (span.span_id != null and std.mem.eql(u8, span.span_id.?, parent_id)) {
                return span.trace_id;
            }
        }
        // If not found, generate new
        const id = self.correlation_id_gen.generate() catch "unknown";
        return id;
    }

    fn buildTraceTree(self: *Self, spans: []const *TraceSpan) !*TreeNode {
        // Find root span (no parent)
        var root: ?*TraceSpan = null;
        for (spans) |span| {
            if (span.parent_span_id == null) {
                root = span;
                break;
            }
        }

        if (root == null) {
            // If no root found, use first span
            root = spans[0];
        }

        const node = try self.allocator.create(TreeNode);
        node.* = TreeNode{
            .span = root.?,
            .children = std.ArrayList(*TreeNode){},
        };

        // Find children
        for (spans) |span| {
            if (span.parent_span_id) |parent_id| {
                if (root.?.span_id != null and std.mem.eql(u8, parent_id, root.?.span_id.?)) {
                    const child = try self.buildTraceTreeForSpan(spans, span);
                    try node.children.append(self.allocator, child);
                }
            }
        }

        return node;
    }

    fn buildTraceTreeForSpan(self: *Self, spans: []const *TraceSpan, parent_span: *TraceSpan) !*TreeNode {
        const node = try self.allocator.create(TreeNode);
        node.* = TreeNode{
            .span = parent_span,
            .children = std.ArrayList(*TreeNode){},
        };

        if (parent_span.span_id == null) return node;

        // Find children
        for (spans) |span| {
            if (span.parent_span_id) |parent_id| {
                if (std.mem.eql(u8, parent_id, parent_span.span_id.?)) {
                    const child = try self.buildTraceTreeForSpan(spans, span);
                    try node.children.append(self.allocator, child);
                }
            }
        }

        return node;
    }

    fn writeSpanJson(self: *const Self, span: *const TraceSpan, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"name\":\"{s}\",", .{span.name});
        try writer.print("\"span_id\":\"{s}\",", .{if (span.span_id) |id| id else ""});
        try writer.print("\"trace_id\":\"{s}\",", .{span.trace_id});
        try writer.print("\"kind\":\"{s}\",", .{@tagName(span.kind)});
        try writer.print("\"start_ns\":{d},", .{span.start_time_ns});
        if (span.end_time_ns) |end| {
            try writer.print("\"duration_ns\":{d},", .{end - span.start_time_ns});
        }
        try writer.print("\"status\":\"{s}\",", .{@tagName(span.status)});

        // Attributes
        try writer.writeAll("\"attributes\":{");
        var attr_first = true;
        var attr_it = span.attributes.iterator();
        while (attr_it.next()) |entry| {
            if (!attr_first) try writer.writeAll(",");
            attr_first = false;
            try writer.print("\"{s}\":", .{entry.key_ptr.*});
            try self.writeAttributeValueJson(entry.value_ptr.*, writer);
        }
        try writer.writeAll("}");

        try writer.writeAll("}");
    }

    fn writeAttributeValueJson(self: *const Self, value: AttributeValue, writer: anytype) !void {
        _ = self;
        switch (value) {
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .bool => |b| try writer.print("{}", .{b}),
            .string_array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |s, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.print("\"{s}\"", .{s});
                }
                try writer.writeAll("]");
            },
        }
    }
};

/// Trace span representing an operation
pub const TraceSpan = struct {
    name: []const u8,
    span_id: ?[]const u8,
    parent_span_id: ?[]const u8,
    trace_id: []const u8,
    kind: SpanKind,
    start_time_ns: i64,
    end_time_ns: ?i64,
    status: SpanStatus,
    attributes: std.StringHashMap(AttributeValue),
    events: std.ArrayList(SpanEvent),
    links: std.ArrayList(SpanLink),

    pub fn deinit(self: *TraceSpan, allocator: std.mem.Allocator) void {
        if (self.span_id) |id| allocator.free(id);
        if (self.parent_span_id) |pid| allocator.free(pid);
        allocator.free(self.name);
        allocator.free(self.trace_id);

        var attr_it = self.attributes.iterator();
        while (attr_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.attributes.deinit();

        for (self.events.items) |*event| event.deinit(allocator);
        self.events.deinit(allocator);

        for (self.links.items) |*link| link.deinit(allocator);
        self.links.deinit(allocator);
    }

    pub fn getDurationNs(self: *const TraceSpan) ?u64 {
        if (self.end_time_ns) |end| {
            return @intCast(end - self.start_time_ns);
        }
        return null;
    }
};

pub const SpanKind = enum {
    /// Internal operation
    internal,
    /// Server handles request
    server,
    /// Client makes request
    client,
    /// Producer sends message
    producer,
    /// Consumer receives message
    consumer,
};

pub const SpanStatus = enum {
    unset,
    ok,
    @"error",
};

pub const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    string_array: [][]const u8,

    pub fn deinit(self: *AttributeValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .string_array => |arr| {
                for (arr) |s| allocator.free(s);
                allocator.free(arr);
            },
            else => {},
        }
    }

    pub fn copy(self: *const AttributeValue, allocator: std.mem.Allocator) !AttributeValue {
        return switch (self.*) {
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .int => |i| .{ .int = i },
            .float => |f| .{ .float = f },
            .bool => |b| .{ .bool = b },
            .string_array => |arr| blk: {
                var new_arr = try allocator.alloc([]const u8, arr.len);
                for (arr, 0..) |s, i| {
                    new_arr[i] = try allocator.dupe(u8, s);
                }
                break :blk .{ .string_array = new_arr };
            },
        };
    }
};

pub const SpanEvent = struct {
    name: []const u8,
    timestamp_ns: i64,
    attributes: std.StringHashMap(AttributeValue),

    pub fn deinit(self: *SpanEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.name);

        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.attributes.deinit();
    }

    pub fn copy(self: *const SpanEvent, allocator: std.mem.Allocator) !SpanEvent {
        var new_attrs = std.StringHashMap(AttributeValue).init(allocator);
        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            const value_copy = try entry.value_ptr.copy(allocator);
            try new_attrs.put(key_copy, value_copy);
        }

        return SpanEvent{
            .name = try allocator.dupe(u8, self.name),
            .timestamp_ns = self.timestamp_ns,
            .attributes = new_attrs,
        };
    }
};

pub const SpanLink = struct {
    trace_id: []const u8,
    span_id: []const u8,
    attributes: std.StringHashMap(AttributeValue),

    pub fn deinit(self: *SpanLink, allocator: std.mem.Allocator) void {
        allocator.free(self.trace_id);
        allocator.free(self.span_id);

        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.attributes.deinit();
    }
};

/// Tree node for trace visualization
pub const TreeNode = struct {
    span: *TraceSpan,
    children: std.ArrayList(*TreeNode),

    pub fn deinit(self: *TreeNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
    }
};

pub const TraceTree = struct {
    root: *TreeNode,
    trace_id: []const u8,
    span_count: usize,

    pub fn deinit(self: *TraceTree, allocator: std.mem.Allocator) void {
        self.root.deinit(allocator);
        allocator.destroy(self.root);
        allocator.free(self.trace_id);
    }
};

/// Configuration for trace manager
pub const Config = struct {
    max_completed_spans: usize = 10000,
    max_span_attributes: usize = 1000,
    max_span_events: usize = 100,
};

/// Correlation ID generator (UUID-like)
pub const CorrelationIdGenerator = struct {
    counter: u64,

    pub fn init() CorrelationIdGenerator {
        return CorrelationIdGenerator{
            .counter = 1,
        };
    }

    pub fn generate(self: *CorrelationIdGenerator) ![]const u8 {
        const id = self.counter;
        self.counter += 1;
        const time = std.time.nanoTimestamp();
        // Format: timestamp_counter (simplified, not a real UUID)
        return std.fmt.allocPrint(std.heap.page_allocator, "{d}_{d}", .{ time, id });
    }
};

// ==================== Tests ====================//

test "TraceManager init" {
    var manager = TraceManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.activeSpanCount());
    try std.testing.expectEqual(@as(usize, 0), manager.completedSpanCount());
}

test "TraceManager start and end span" {
    var manager = TraceManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const span = try manager.startSpan("test_span", .internal, null);
    try std.testing.expectEqual(@as(usize, 1), manager.activeSpanCount());

    try manager.endSpan(span, .ok);
    try std.testing.expectEqual(@as(usize, 0), manager.activeSpanCount());
    try std.testing.expectEqual(@as(usize, 1), manager.completedSpanCount());
}

test "TraceManager parent-child spans" {
    var manager = TraceManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const parent = try manager.startSpan("parent", .internal, null);
    const child = try manager.startSpan("child", .internal, parent.span_id);

    try manager.endSpan(child, .ok);
    try manager.endSpan(parent, .ok);

    try std.testing.expectEqual(@as(usize, 2), manager.completedSpanCount());

    // Check child has parent
    try std.testing.expect(child.parent_span_id != null);
    try std.testing.expect(std.mem.eql(
        u8,
        child.parent_span_id.?,
        parent.span_id.?,
    ));
}

test "TraceManager set attribute" {
    var manager = TraceManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const span = try manager.startSpan("test_span", .internal, null);
    try manager.setAttribute(span, "test_key", .{ .int = 42 });

    try std.testing.expectEqual(@as(i64, 42), span.attributes.get("test_key").?.int);
}

test "TraceManager record LLM call" {
    var manager = TraceManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const span = try manager.startSpan("llm_call", .client, null);
    try manager.recordLLMCall(span, "openai", "gpt-4", "test_function", 100, 50, 500);

    try std.testing.expect(span.attributes.get("llm.provider") != null);
    try std.testing.expectEqualStrings("openai", span.attributes.get("llm.provider").?.string);
}

test "TraceManager export JSON" {
    var manager = TraceManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const span = try manager.startSpan("test_span", .internal, null);
    try manager.endSpan(span, .ok);

    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(std.testing.allocator);

    try manager.exportJson(buffer.writer(std.testing.allocator));

    try std.testing.expect(buffer.items.len > 0);
    // Should contain "traces" and "span_id"
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"traces\"") != null);
}

test "TraceSpan getDurationNs" {
    var manager = TraceManager.init(std.testing.allocator, .{});
    defer manager.deinit();

    const span = try manager.startSpan("test_span", .internal, null);
    std.Thread.sleep(1 * std.time.ns_per_s); // 1 second
    try manager.endSpan(span, .ok);

    const duration = span.getDurationNs();
    try std.testing.expect(duration != null);
    try std.testing.expect(duration.? > 0);
}

test "AttributeValue copy" {
    const original = AttributeValue{ .string = "test" };
    var copy = try original.copy(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test", copy.string);
}

test "SpanEvent copy" {
    var original_attrs = std.StringHashMap(AttributeValue).init(std.testing.allocator);
    try original_attrs.put("key", AttributeValue{ .int = 42 });

    const original = SpanEvent{
        .name = "test_event",
        .timestamp_ns = 12345,
        .attributes = original_attrs,
    };

    var copy = try original.copy(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test_event", copy.name);
    try std.testing.expectEqual(@as(i64, 12345), copy.timestamp_ns);
}

test "CorrelationIdGenerator generate" {
    var gen = CorrelationIdGenerator.init();

    const id1 = try gen.generate();
    defer std.heap.page_allocator.free(id1);

    const id2 = try gen.generate();
    defer std.heap.page_allocator.free(id2);

    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}
