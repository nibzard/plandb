//! Debug logging and tracing for plugin execution
//!
//! Provides execution tracing, timing/cost tracking, and validation for plugins

const std = @import("std");
const manager = @import("manager.zig");
const llm_types = @import("../llm/types.zig");

/// Debug tracer for plugin execution
pub const PluginTracer = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(TraceEvent),
    current_span: ?*TraceSpan,
    root_spans: std.ArrayList(*TraceSpan),
    enabled: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .events = std.ArrayList(TraceEvent).init(allocator),
            .current_span = null,
            .root_spans = std.ArrayList(*TraceSpan).init(allocator),
            .enabled = true,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.events.items) |*e| e.deinit(self.allocator);
        self.events.deinit();

        for (self.root_spans.items) |span| {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }
        self.root_spans.deinit();
    }

    /// Enable/disable tracing
    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Start a new trace span
    pub fn startSpan(self: *Self, name: []const u8, span_type: SpanType) !*TraceSpan {
        if (!self.enabled) {
            return &globalDummySpan;
        }

        const span = try self.allocator.create(TraceSpan);
        span.* = TraceSpan{
            .name = try self.allocator.dupe(u8, name),
            .span_type = span_type,
            .start_time = std.time.nanoTimestamp(),
            .end_time = null,
            .parent = self.current_span,
            .children = std.ArrayList(*TraceSpan).init(self.allocator),
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
            .llm_calls = std.ArrayList(LLMCallInfo).init(self.allocator),
        };

        if (self.current_span) |parent| {
            try parent.children.append(span);
        } else {
            try self.root_spans.append(span);
        }

        self.current_span = span;

        try self.events.append(.{
            .timestamp = span.start_time,
            .event_type = .span_start,
            .span_name = try self.allocator.dupe(u8, name),
        });

        return span;
    }

    /// End the current trace span
    pub fn endSpan(self: *Self, span: *TraceSpan) !void {
        if (!self.enabled or span == &globalDummySpan) return;

        span.end_time = std.time.nanoTimestamp();

        try self.events.append(.{
            .timestamp = span.end_time.?,
            .event_type = .span_end,
            .span_name = try self.allocator.dupe(u8, span.name),
        });

        if (self.current_span == span) {
            self.current_span = span.parent;
        }
    }

    /// Log an LLM call within current span
    pub fn logLLMCall(
        self: *Self,
        span: *TraceSpan,
        function_name: []const u8,
        tokens_used: llm_types.TokenUsage,
        duration_ms: u64,
        success: bool
    ) !void {
        if (!self.enabled or span == &globalDummySpan) return;

        try span.llm_calls.append(.{
            .function_name = try self.allocator.dupe(u8, function_name),
            .tokens_used = tokens_used,
            .duration_ms = duration_ms,
            .success = success,
        });

        try self.events.append(.{
            .timestamp = std.time.nanoTimestamp(),
            .event_type = if (success) .llm_call_success else .llm_call_error,
            .span_name = try self.allocator.dupe(u8, span.name),
            .llm_function = try self.allocator.dupe(u8, function_name),
        });
    }

    /// Add metadata to current span
    pub fn addMetadata(self: *Self, span: *TraceSpan, key: []const u8, value: []const u8) !void {
        if (!self.enabled or span == &globalDummySpan) return;

        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try span.metadata.put(key_copy, value_copy);
    }

    /// Get execution statistics
    pub fn getStatistics(self: *const Self) ExecutionStatistics {
        var total_duration_ns: u64 = 0;
        var total_llm_calls: usize = 0;
        var total_tokens: u64 = 0;
        var failed_calls: usize = 0;

        for (self.root_spans.items) |span| {
            total_duration_ns += span.getDuration();
            total_llm_calls += span.llm_calls.items.len;

            for (span.llm_calls.items) |call| {
                total_tokens += call.tokens_used.total_tokens;
                if (!call.success) failed_calls += 1;
            }
        }

        return .{
            .total_duration_ns = total_duration_ns,
            .total_llm_calls = total_llm_calls,
            .total_tokens_used = total_tokens,
            .failed_llm_calls = failed_calls,
            .span_count = self.root_spans.items.len,
        };
    }

    /// Generate trace report
    pub fn generateReport(self: *const Self, writer: anytype) !void {
        try writer.print("=== Plugin Execution Trace Report ===\n\n", .{});

        const stats = self.getStatistics();
        try writer.print("Summary:\n", .{});
        try writer.print("  Total Duration: {d:.2}ms\n", .{@as(f64, @floatFromInt(stats.total_duration_ns)) / 1_000_000.0});
        try writer.print("  LLM Calls: {d}\n", .{stats.total_llm_calls});
        try writer.print("  Tokens Used: {d}\n", .{stats.total_tokens_used});
        try writer.print("  Failed Calls: {d}\n", .{stats.failed_llm_calls});
        try writer.print("  Spans: {d}\n\n", .{stats.span_count});

        for (self.root_spans.items) |span| {
            try self.printSpan(span, writer, 0);
        }
    }

    fn printSpan(self: *const Self, span: *const TraceSpan, writer: anytype, depth: usize) !void {
        const indent = "  " ** depth;
        const duration = span.getDuration();
        const duration_ms = @as(f64, @floatFromInt(duration)) / 1_000_000.0;

        try writer.print("{s}[{s}] {d:.2}ms", .{ indent, span.name, duration_ms });

        if (span.llm_calls.items.len > 0) {
            try writer.print(" ({d} LLM calls", .{span.llm_calls.items.len});
            var total_tokens: u64 = 0;
            for (span.llm_calls.items) |call| {
                total_tokens += call.tokens_used.total_tokens;
            }
            try writer.print(", {d} tokens)", .{total_tokens});
        }
        try writer.print("\n", .{});

        if (span.metadata.count() > 0) {
            var it = span.metadata.iterator();
            while (it.next()) |entry| {
                try writer.print("{s}  {s}: {s}\n", .{ indent, entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        for (span.llm_calls.items) |call| {
            const status = if (call.success) "OK" else "ERR";
            try writer.print("{s}  [{s}] {s} ({d} tokens, {d}ms)\n", .{
                indent, status, call.function_name, call.tokens_used.total_tokens, call.duration_ms
            });
        }

        for (span.children.items) |child| {
            try self.printSpan(child, writer, depth + 1);
        }
    }

    /// Export trace as JSON
    pub fn exportJson(self: *const Self, writer: anytype) !void {
        try writer.writeByte('{');
        try writer.writeAll("\"spans\":[");

        for (self.root_spans.items, 0..) |span, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeSpanJson(span, writer);
        }

        try writer.writeAll("]}");
    }

    fn writeSpanJson(self: *const Self, span: *const TraceSpan, writer: anytype) !void {
        try writer.writeByte('{');
        try writer.print("\"name\":\"{s}\",\"type\":\"{s}\",\"duration_ns\":{d},\"children\":[", .{
            span.name, @tagName(span.span_type), span.getDuration()
        });

        for (span.children.items, 0..) |child, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeSpanJson(child, writer);
        }

        try writer.writeAll("],\"llm_calls\":[");

        for (span.llm_calls.items, 0..) |call, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print(
                \\{{"function":"{s}","tokens":{d},"duration_ms":{d},"success":{}}}
            , .{ call.function_name, call.tokens_used.total_tokens, call.duration_ms, call.success });
        }

        try writer.writeAll("]}");
    }
};

/// Dummy span for when tracing is disabled
var globalDummySpan = TraceSpan{
    .name = "dummy",
    .span_type = .plugin_hook,
    .start_time = 0,
    .end_time = null,
    .parent = null,
    .children = undefined,
    .metadata = undefined,
    .llm_calls = undefined,
};

/// Trace span representing a plugin execution
pub const TraceSpan = struct {
    name: []const u8,
    span_type: SpanType,
    start_time: i64,
    end_time: ?i64,
    parent: ?*TraceSpan,
    children: std.ArrayList(*TraceSpan),
    metadata: std.StringHashMap([]const u8),
    llm_calls: std.ArrayList(LLMCallInfo),

    pub fn deinit(self: *TraceSpan, allocator: std.mem.Allocator) void {
        allocator.free(self.name);

        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit();

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();

        for (self.llm_calls.items) |*call| {
            allocator.free(call.function_name);
        }
        self.llm_calls.deinit();
    }

    pub fn getDuration(self: *const TraceSpan) u64 {
        if (self.end_time) |end| {
            return @intCast(end - self.start_time);
        }
        return 0;
    }
};

pub const SpanType = enum {
    plugin_hook,
    llm_call,
    commit_processing,
    query_processing,
    validation,
};

pub const LLMCallInfo = struct {
    function_name: []const u8,
    tokens_used: llm_types.TokenUsage,
    duration_ms: u64,
    success: bool,
};

pub const TraceEvent = struct {
    timestamp: i64,
    event_type: EventType,
    span_name: []const u8,
    llm_function: ?[]const u8 = null,

    pub fn deinit(self: *TraceEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.span_name);
        if (self.llm_function) |func| allocator.free(func);
    }

    pub const EventType = enum {
        span_start,
        span_end,
        llm_call_success,
        llm_call_error,
    };
};

pub const ExecutionStatistics = struct {
    total_duration_ns: u64,
    total_llm_calls: usize,
    total_tokens_used: u64,
    failed_llm_calls: usize,
    span_count: usize,
};

/// Plugin validator for schema compliance
pub const PluginValidator = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ValidationError),
    warnings: std.ArrayList(ValidationWarning),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .errors = std.ArrayList(ValidationError).init(allocator),
            .warnings = std.ArrayList(ValidationWarning).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.errors.items) |*err| err.deinit(self.allocator);
        self.errors.deinit();

        for (self.warnings.items) |*warn| warn.deinit(self.allocator);
        self.warnings.deinit();
    }

    /// Validate a plugin against schema requirements
    pub fn validatePlugin(self: *Self, plugin: *const manager.Plugin) !ValidationResult {
        self.errors.clearRetainingCapacity();
        self.warnings.clearRetainingCapacity();

        // Validate plugin name
        if (plugin.name.len == 0) {
            try self.errors.append(.{
                .field = "name",
                .message = try self.allocator.dupe(u8, "Plugin name cannot be empty"),
            });
        }

        // Validate version format (basic semver check)
        if (!self.isValidSemVer(plugin.version)) {
            try self.warnings.append(.{
                .field = "version",
                .message = try self.allocator.dupe(u8, "Version does not follow semantic versioning"),
            });
        }

        // Ensure at least one hook is defined
        if (plugin.on_commit == null and plugin.on_query == null and plugin.on_schedule == null and plugin.get_functions == null) {
            try self.warnings.append(.{
                .field = "hooks",
                .message = try self.allocator.dupe(u8, "Plugin defines no hooks or functions"),
            });
        }

        return ValidationResult{
            .is_valid = self.errors.items.len == 0,
            .errors = try self.allocator.dupe(ValidationError, self.errors.items),
            .warnings = try self.allocator.dupe(ValidationWarning, self.warnings.items),
        };
    }

    /// Validate function schema
    pub fn validateFunctionSchema(self: *Self, schema: *const manager.FunctionSchema) !ValidationResult {
        self.errors.clearRetainingCapacity();
        self.warnings.clearRetainingCapacity();

        if (schema.name.len == 0) {
            try self.errors.append(.{
                .field = "name",
                .message = try self.allocator.dupe(u8, "Function name cannot be empty"),
            });
        }

        if (schema.description.len == 0) {
            try self.warnings.append(.{
                .field = "description",
                .message = try self.allocator.dupe(u8, "Function has no description"),
            });
        }

        // Check parameter schema validity
        if (schema.parameters.type != .object) {
            try self.errors.append(.{
                .field = "parameters",
                .message = try self.allocator.dupe(u8, "Parameters must be of type 'object'"),
            });
        }

        return ValidationResult{
            .is_valid = self.errors.items.len == 0,
            .errors = try self.allocator.dupe(ValidationError, self.errors.items),
            .warnings = try self.allocator.dupe(ValidationWarning, self.warnings.items),
        };
    }

    fn isValidSemVer(self: *Self, version: []const u8) bool {
        _ = self;
        // Basic semver pattern: X.Y.Z
        var parts = std.mem.splitScalar(u8, version, '.');
        var count: usize = 0;
        while (parts.next()) |part| {
            count += 1;
            if (part.len == 0) return false;
            for (part) |c| {
                if (c < '0' or c > '9') return false;
            }
        }
        return count == 3;
    }
};

pub const ValidationResult = struct {
    is_valid: bool,
    errors: []const ValidationError,
    warnings: []const ValidationWarning,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        for (self.errors) |*err| err.deinit(allocator);
        allocator.free(self.errors);

        for (self.warnings) |*warn| warn.deinit(allocator);
        allocator.free(self.warnings);
    }
};

pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,

    pub fn deinit(self: *ValidationError, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        allocator.free(self.message);
    }
};

pub const ValidationWarning = struct {
    field: []const u8,
    message: []const u8,

    pub fn deinit(self: *ValidationWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        allocator.free(self.message);
    }
};

test "plugin_tracer_basic" {
    var tracer = PluginTracer.init(std.testing.allocator);
    defer tracer.deinit();

    const span = try tracer.startSpan("test_span", .plugin_hook);
    try tracer.addMetadata(span, "test_key", "test_value");
    try tracer.endSpan(span);

    try std.testing.expectEqual(@as(usize, 1), tracer.root_spans.items.len);
    try std.testing.expectEqual(@as(usize, 1), tracer.root_spans.items[0].metadata.count());
}

test "plugin_tracer_statistics" {
    var tracer = PluginTracer.init(std.testing.allocator);
    defer tracer.deinit();

    const span = try tracer.startSpan("test_span", .plugin_hook);
    try tracer.logLLMCall(span, "test_function", .{
        .prompt_tokens = 10,
        .completion_tokens = 5,
        .total_tokens = 15,
    }, 100, true);
    try tracer.endSpan(span);

    const stats = tracer.getStatistics();
    try std.testing.expectEqual(@as(usize, 1), stats.total_llm_calls);
    try std.testing.expectEqual(@as(u64, 15), stats.total_tokens_used);
}

test "plugin_validator_valid_plugin" {
    var validator = PluginValidator.init(std.testing.allocator);
    defer validator.deinit();

    const plugin = manager.Plugin{
        .name = "test_plugin",
        .version = "1.0.0",
        .on_commit = null,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
    };

    const result = try validator.validatePlugin(&plugin);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_valid);
}

test "plugin_validator_invalid_plugin" {
    var validator = PluginValidator.init(std.testing.allocator);
    defer validator.deinit();

    const plugin = manager.Plugin{
        .name = "",
        .version = "invalid",
        .on_commit = null,
        .on_query = null,
        .on_schedule = null,
        .get_functions = null,
    };

    const result = try validator.validatePlugin(&plugin);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.errors.len > 0);
}

test "plugin_validator_function_schema" {
    var validator = PluginValidator.init(std.testing.allocator);
    defer validator.deinit();

    const llm_function = @import("../llm/function.zig");
    var params = llm_function.JSONSchema.init(.object);
    defer params.deinit(std.testing.allocator);

    const schema = try manager.FunctionSchema.init(
        std.testing.allocator,
        "test_function",
        "A test function",
        params
    );
    defer schema.deinit(std.testing.allocator);

    const result = try validator.validateFunctionSchema(&schema);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_valid);
}
