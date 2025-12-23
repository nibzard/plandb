//! AI operations metrics collection and export
//!
//! Provides comprehensive metrics collection for AI operations:
//! - LLM call metrics (latency, tokens, cost, success rate)
//! - Plugin execution metrics (timing, resource usage)
//! - Entity extraction metrics (accuracy, throughput)
//! - Query performance metrics (AI vs traditional)
//! - OpenMetrics/Prometheus export support

const std = @import("std");

/// Metrics collector for AI operations
pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    registry: std.StringHashMap(Metric),
    counters: std.StringHashMap(Counter),
    gauges: std.StringHashMap(Gauge),
    histograms: std.StringHashMap(Histogram),
    config: Config,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        var registry = std.StringHashMap(Metric).init(allocator);
        var counters = std.StringHashMap(Counter).init(allocator);
        var gauges = std.StringHashMap(Gauge).init(allocator);
        var histograms = std.StringHashMap(Histogram).init(allocator);

        // Initialize standard AI metrics
        try Self.initStandardMetrics(allocator, &registry, &counters, &gauges, &histograms);

        return MetricsCollector{
            .allocator = allocator,
            .registry = registry,
            .counters = counters,
            .gauges = gauges,
            .histograms = histograms,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.registry.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Metric deinit is a no-op for standard types
        }
        self.registry.deinit();

        var it2 = self.counters.iterator();
        while (it2.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.counters.deinit();

        var it3 = self.gauges.iterator();
        while (it3.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.gauges.deinit();

        var it4 = self.histograms.iterator();
        while (it4.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.histograms.deinit();
    }

    /// Record an LLM call
    pub fn recordLLMCall(self: *Self, call: LLMCallMetrics) !void {
        // Increment total calls counter
        if (self.counters.getPtr("ai_llm_calls_total")) |counter| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "provider", .value = call.provider },
                .{ .name = "model", .value = call.model },
                .{ .name = "status", .value = if (call.success) "success" else "error" },
            });
            defer self.allocator.free(key);
            counter.incWithLabel(key, 1);
        }

        // Record latency
        if (self.histograms.getPtr("ai_llm_latency_ms")) |hist| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "provider", .value = call.provider },
                .{ .name = "model", .value = call.model },
            });
            defer self.allocator.free(key);
            try hist.observeWithLabel(key, call.latency_ms);
        }

        // Record token usage
        if (self.counters.getPtr("ai_llm_tokens_total")) |counter| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "provider", .value = call.provider },
                .{ .name = "type", .value = "prompt" },
            });
            defer self.allocator.free(key);
            counter.incWithLabel(key, call.input_tokens);

            const key2 = try self.formatLabelKey(&[_]Label{
                .{ .name = "provider", .value = call.provider },
                .{ .name = "type", .value = "completion" },
            });
            defer self.allocator.free(key2);
            counter.incWithLabel(key2, call.output_tokens);
        }

        // Record cost
        if (self.counters.getPtr("ai_llm_cost_usd")) |counter| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "provider", .value = call.provider },
            });
            defer self.allocator.free(key);
            // Cost is stored as microdollars to maintain integer precision
            const cost_microdollars = @as(u64, @intFromFloat(call.cost * 1_000_000.0));
            counter.incWithLabel(key, cost_microdollars);
        }

        // Update active calls gauge
        if (self.gauges.getPtr("ai_llm_active_calls")) |gauge| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "provider", .value = call.provider },
            });
            defer self.allocator.free(key);
            gauge.decWithLabel(key, 1);
        }
    }

    /// Mark start of LLM call
    pub fn startLLMCall(self: *Self, provider: []const u8, model: []const u8) !void {
        _ = model;
        if (self.gauges.getPtr("ai_llm_active_calls")) |gauge| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "provider", .value = provider },
            });
            defer self.allocator.free(key);
            gauge.incWithLabel(key, 1);
        }
    }

    /// Record plugin execution
    pub fn recordPluginExecution(self: *Self, exec: PluginExecutionMetrics) !void {
        if (self.counters.getPtr("ai_plugin_executions_total")) |counter| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "plugin", .value = exec.plugin_name },
                .{ .name = "hook", .value = exec.hook_type },
                .{ .name = "status", .value = if (exec.success) "success" else "error" },
            });
            defer self.allocator.free(key);
            counter.incWithLabel(key, 1);
        }

        if (self.histograms.getPtr("ai_plugin_execution_ms")) |hist| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "plugin", .value = exec.plugin_name },
                .{ .name = "hook", .value = exec.hook_type },
            });
            defer self.allocator.free(key);
            try hist.observeWithLabel(key, exec.duration_ms);
        }

        if (exec.llm_calls > 0) {
            if (self.histograms.getPtr("ai_plugin_llm_calls")) |hist| {
                const key = try self.formatLabelKey(&[_]Label{
                    .{ .name = "plugin", .value = exec.plugin_name },
                });
                defer self.allocator.free(key);
                try hist.observeWithLabel(key, @floatFromInt(exec.llm_calls));
            }
        }
    }

    /// Record entity extraction
    pub fn recordEntityExtraction(self: *Self, ext: EntityExtractionMetrics) !void {
        if (self.counters.getPtr("ai_entity_extractions_total")) |counter| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "entity_type", .value = ext.entity_type },
                .{ .name = "confidence_level", .value = ext.confidenceLevel() },
            });
            defer self.allocator.free(key);
            counter.incWithLabel(key, 1);
        }

        if (self.gauges.getPtr("ai_entity_accuracy")) |gauge| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "entity_type", .value = ext.entity_type },
            });
            defer self.allocator.free(key);
            gauge.setWithLabel(key, ext.accuracy);
        }
    }

    /// Record query performance
    pub fn recordQuery(self: *Self, query: QueryMetrics) !void {
        if (self.counters.getPtr("ai_queries_total")) |counter| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "type", .value = if (query.is_ai_powered) "ai" else "traditional" },
                .{ .name = "status", .value = if (query.success) "success" else "error" },
            });
            defer self.allocator.free(key);
            counter.incWithLabel(key, 1);
        }

        if (self.histograms.getPtr("ai_query_latency_ms")) |hist| {
            const key = try self.formatLabelKey(&[_]Label{
                .{ .name = "type", .value = if (query.is_ai_powered) "ai" else "traditional" },
            });
            defer self.allocator.free(key);
            try hist.observeWithLabel(key, query.latency_ms);
        }

        if (query.is_ai_powered and query.rows_scanned > 0) {
            if (self.gauges.getPtr("ai_query_scan_ratio")) |gauge| {
                const ratio = @as(f64, @floatFromInt(query.rows_returned)) / @as(f64, @floatFromInt(query.rows_scanned));
                gauge.set(ratio);
            }
        }
    }

    /// Export metrics in OpenMetrics format
    pub fn exportOpenMetrics(self: *const Self, writer: anytype) !void {
        // Export counters
        var counter_it = self.counters.iterator();
        while (counter_it.next()) |entry| {
            try writer.print("# TYPE {s} counter\n", .{entry.key_ptr.*});
            try entry.value_ptr.exportOpenMetrics(writer, entry.key_ptr.*);
        }

        // Export gauges
        var gauge_it = self.gauges.iterator();
        while (gauge_it.next()) |entry| {
            try writer.print("# TYPE {s} gauge\n", .{entry.key_ptr.*});
            try entry.value_ptr.exportOpenMetrics(writer, entry.key_ptr.*);
        }

        // Export histograms
        var hist_it = self.histograms.iterator();
        while (hist_it.next()) |entry| {
            try writer.print("# TYPE {s} histogram\n", .{entry.key_ptr.*});
            try entry.value_ptr.exportOpenMetrics(writer, entry.key_ptr.*);
        }
    }

    /// Export metrics as JSON
    pub fn exportJson(self: *const Self, writer: anytype) !void {
        try writer.writeByte('{');

        var first = true;

        // Export counters
        var counter_it = self.counters.iterator();
        while (counter_it.next()) |entry| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("\"{s}\":", .{entry.key_ptr.*});
            try entry.value_ptr.exportJson(writer);
        }

        // Export gauges
        var gauge_it = self.gauges.iterator();
        while (gauge_it.next()) |entry| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("\"{s}\":", .{entry.key_ptr.*});
            try entry.value_ptr.exportJson(writer);
        }

        // Export histograms
        var hist_it = self.histograms.iterator();
        while (hist_it.next()) |entry| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("\"{s}\":", .{entry.key_ptr.*});
            try entry.value_ptr.exportJson(writer);
        }

        try writer.writeByte('}');
    }

    /// Get metric snapshot
    pub fn snapshot(self: *const Self) !MetricsSnapshot {
        var counters_snapshot = std.StringHashMap(u64).init(self.allocator);
        var gauges_snapshot = std.StringHashMap(f64).init(self.allocator);

        var counter_it = self.counters.iterator();
        while (counter_it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            try counters_snapshot.put(key, entry.value_ptr.get());
        }

        var gauge_it = self.gauges.iterator();
        while (gauge_it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            try gauges_snapshot.put(key, entry.value_ptr.get());
        }

        return MetricsSnapshot{
            .counters = counters_snapshot,
            .gauges = gauges_snapshot,
            .timestamp_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000))),
        };
    }

    fn initStandardMetrics(
        allocator: std.mem.Allocator,
        registry: *std.StringHashMap(Metric),
        counters: *std.StringHashMap(Counter),
        gauges: *std.StringHashMap(Gauge),
        histograms: *std.StringHashMap(Histogram),
    ) !void {
        _ = registry;
        // LLM Call Metrics
        try counters.put(try allocator.dupe(u8, "ai_llm_calls_total"), Counter.init(allocator));
        try counters.put(try allocator.dupe(u8, "ai_llm_tokens_total"), Counter.init(allocator));
        try counters.put(try allocator.dupe(u8, "ai_llm_cost_usd"), Counter.init(allocator));
        try gauges.put(try allocator.dupe(u8, "ai_llm_active_calls"), Gauge.init(allocator));
        try histograms.put(try allocator.dupe(u8, "ai_llm_latency_ms"), try Histogram.init(allocator, &[_]f64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000 }));

        // Plugin Metrics
        try counters.put(try allocator.dupe(u8, "ai_plugin_executions_total"), Counter.init(allocator));
        try histograms.put(try allocator.dupe(u8, "ai_plugin_execution_ms"), try Histogram.init(allocator, &[_]f64{ 1, 5, 10, 25, 50, 100, 500, 1000 }));
        try histograms.put(try allocator.dupe(u8, "ai_plugin_llm_calls"), try Histogram.init(allocator, &[_]f64{ 1, 2, 5, 10 }));

        // Entity Extraction Metrics
        try counters.put(try allocator.dupe(u8, "ai_entity_extractions_total"), Counter.init(allocator));
        try gauges.put(try allocator.dupe(u8, "ai_entity_accuracy"), Gauge.init(allocator));

        // Query Metrics
        try counters.put(try allocator.dupe(u8, "ai_queries_total"), Counter.init(allocator));
        try histograms.put(try allocator.dupe(u8, "ai_query_latency_ms"), try Histogram.init(allocator, &[_]f64{ 1, 5, 10, 25, 50, 100, 500, 1000, 5000 }));
        try gauges.put(try allocator.dupe(u8, "ai_query_scan_ratio"), Gauge.init(allocator));
    }

    fn formatLabelKey(self: *Self, labels: []const Label) ![]const u8 {
        var buf = std.ArrayList(u8){};
        for (labels) |label| {
            if (buf.items.len > 0) try buf.append(self.allocator, ',');
            try buf.appendSlice(self.allocator, label.name);
            try buf.append(self.allocator, '=');
            try buf.appendSlice(self.allocator, label.value);
        }
        return buf.toOwnedSlice(self.allocator);
    }
};

/// Counter metric (monotonically increasing)
pub const Counter = struct {
    allocator: std.mem.Allocator,
    value: u64,
    labeled_values: std.StringHashMap(u64),

    pub fn init(allocator: std.mem.Allocator) Counter {
        return Counter{
            .allocator = allocator,
            .value = 0,
            .labeled_values = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Counter) void {
        var it = self.labeled_values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.labeled_values.deinit();
    }

    pub fn inc(self: *Counter, amount: u64) void {
        self.value += amount;
    }

    pub fn incWithLabel(self: *Counter, label: []const u8, amount: u64) void {
        const label_copy = self.allocator.dupe(u8, label) catch return;
        var should_free = true;
        defer if (should_free) self.allocator.free(label_copy);

        // Get the current value if it exists
        const old_value = self.labeled_values.get(label);
        const new_value = if (old_value) |v| v + amount else amount;

        // Use fetchPut to insert the new value (takes ownership of the key)
        const old_entry = self.labeled_values.fetchPut(label_copy, new_value) catch return;
        if (old_entry) |kv| {
            // Free the old key
            self.allocator.free(kv.key);
        } else {
            // Key was inserted successfully, don't free the label_copy
            should_free = false;
        }
        self.value += amount;
    }

    pub fn get(self: *const Counter) u64 {
        return self.value;
    }

    pub fn exportOpenMetrics(self: *const Counter, writer: anytype, name: []const u8) !void {
        if (self.labeled_values.count() == 0) {
            try writer.print("{s} {d}\n", .{ name, self.value });
        } else {
            var it = self.labeled_values.iterator();
            while (it.next()) |entry| {
                try writer.print("{s}{{{s}}} {d}\n", .{ name, entry.key_ptr.*, entry.value_ptr.* });
            }
        }
    }

    pub fn exportJson(self: *const Counter, writer: anytype) !void {
        try writer.print("{{\"value\":{d}", .{self.value});
        if (self.labeled_values.count() > 0) {
            try writer.writeAll(",\"labeled\":{");
            var first = true;
            var it = self.labeled_values.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.print("\"{s}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try writer.writeByte('}');
        }
        try writer.writeByte('}');
    }
};

/// Gauge metric (can go up or down)
pub const Gauge = struct {
    allocator: std.mem.Allocator,
    value: f64,
    labeled_values: std.StringHashMap(f64),

    pub fn init(allocator: std.mem.Allocator) Gauge {
        return Gauge{
            .allocator = allocator,
            .value = 0,
            .labeled_values = std.StringHashMap(f64).init(allocator),
        };
    }

    pub fn deinit(self: *Gauge) void {
        var it = self.labeled_values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.labeled_values.deinit();
    }

    pub fn set(self: *Gauge, value: f64) void {
        self.value = value;
    }

    pub fn inc(self: *Gauge, amount: f64) void {
        self.value += amount;
    }

    pub fn dec(self: *Gauge, amount: f64) void {
        self.value -= amount;
    }

    pub fn setWithLabel(self: *Gauge, label: []const u8, value: f64) void {
        const label_copy = self.allocator.dupe(u8, label) catch return;
        var should_free = true;
        defer if (should_free) self.allocator.free(label_copy);

        const old_entry = self.labeled_values.fetchPut(label_copy, value) catch return;
        if (old_entry) |kv| {
            self.allocator.free(kv.key);
        } else {
            should_free = false;
        }
    }

    pub fn incWithLabel(self: *Gauge, label: []const u8, amount: f64) void {
        const label_copy = self.allocator.dupe(u8, label) catch return;
        var should_free = true;
        defer if (should_free) self.allocator.free(label_copy);

        const old_value = self.labeled_values.get(label);
        const new_value = if (old_value) |v| v + amount else amount;

        const old_entry = self.labeled_values.fetchPut(label_copy, new_value) catch return;
        if (old_entry) |kv| {
            self.allocator.free(kv.key);
        } else {
            should_free = false;
        }
        self.value += amount;
    }

    pub fn decWithLabel(self: *Gauge, label: []const u8, amount: f64) void {
        const label_copy = self.allocator.dupe(u8, label) catch return;
        var should_free = true;
        defer if (should_free) self.allocator.free(label_copy);

        const old_value = self.labeled_values.get(label);
        const new_value = if (old_value) |v| v - amount else -amount;

        const old_entry = self.labeled_values.fetchPut(label_copy, new_value) catch return;
        if (old_entry) |kv| {
            self.allocator.free(kv.key);
        } else {
            should_free = false;
        }
        self.value -= amount;
    }

    pub fn get(self: *const Gauge) f64 {
        return self.value;
    }

    pub fn exportOpenMetrics(self: *const Gauge, writer: anytype, name: []const u8) !void {
        if (self.labeled_values.count() == 0) {
            try writer.print("{s} {d:.6}\n", .{ name, self.value });
        } else {
            var it = self.labeled_values.iterator();
            while (it.next()) |entry| {
                try writer.print("{s}{{{s}}} {d:.6}\n", .{ name, entry.key_ptr.*, entry.value_ptr.* });
            }
        }
    }

    pub fn exportJson(self: *const Gauge, writer: anytype) !void {
        try writer.print("{{\"value\":{d:.6}", .{self.value});
        if (self.labeled_values.count() > 0) {
            try writer.writeAll(",\"labeled\":{");
            var first = true;
            var it = self.labeled_values.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.print("\"{s}\":{d:.6}", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try writer.writeByte('}');
        }
        try writer.writeByte('}');
    }
};

/// Histogram metric with buckets
pub const Histogram = struct {
    allocator: std.mem.Allocator,
    buckets: []const f64,
    counts: std.ArrayList(u64),
    sum: f64,
    count: u64,

    pub fn init(allocator: std.mem.Allocator, buckets: []const f64) !Histogram {
        var counts = std.ArrayList(u64){};
        try counts.appendNTimes(allocator, 0, buckets.len + 1);
        return Histogram{
            .allocator = allocator,
            .buckets = try allocator.dupe(f64, buckets),
            .counts = counts,
            .sum = 0,
            .count = 0,
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.buckets);
        self.counts.deinit(self.allocator);
    }

    pub fn observe(self: *Histogram, value: f64) !void {
        self.sum += value;
        self.count += 1;

        for (self.buckets, 0..) |bucket, i| {
            if (value <= bucket) {
                self.counts.items[i] += 1;
            }
        }
        // +Inf bucket
        self.counts.items[self.counts.items.len - 1] += 1;
    }

    pub fn observeWithLabel(self: *Histogram, label: []const u8, value: f64) !void {
        _ = label;
        try self.observe(value);
    }

    pub fn exportOpenMetrics(self: *const Histogram, writer: anytype, name: []const u8) !void {
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |bucket, i| {
            cumulative += self.counts.items[i];
            try writer.print("{s}_bucket{{le=\"{d:.1}\"}} {d}\n", .{ name, bucket, cumulative });
        }
        try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ name, self.count });
        try writer.print("{s}_sum {d:.6}\n", .{ name, self.sum });
        try writer.print("{s}_count {d}\n", .{ name, self.count });
    }

    pub fn exportJson(self: *const Histogram, writer: anytype) !void {
        try writer.print("{{\"sum\":{d:.6},\"count\":{d},\"buckets\":[", .{ self.sum, self.count });
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |bucket, i| {
            if (i > 0) try writer.writeByte(',');
            cumulative += self.counts.items[i];
            try writer.print("{{\"le\":{d:.1},\"count\":{d}}}", .{ bucket, cumulative });
        }
        try writer.print("],\"+Inf\":{d}}}", .{self.count});
    }
};

// ==================== Types ====================

pub const Label = struct {
    name: []const u8,
    value: []const u8,
};

pub const Metric = struct {
    name: []const u8,
    help: ?[]const u8,
    metric_type: MetricType,

    pub fn deinit(self: *Metric, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.help) |h| allocator.free(h);
    }

    pub const MetricType = enum {
        counter,
        gauge,
        histogram,
        summary,
    };
};

pub const Config = struct {
    // Export config
    export_interval_ms: u64 = 60000, // 1 minute
    retention_hours: u32 = 24, // Keep 24 hours of history

    // Histogram defaults
    default_latency_buckets: []const f64 = &[_]f64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000 },
    default_size_buckets: []const f64 = &[_]f64{ 100, 1000, 10000, 100000, 1000000 },
};

pub const MetricsSnapshot = struct {
    counters: std.StringHashMap(u64),
    gauges: std.StringHashMap(f64),
    timestamp_ms: u64,

    pub fn deinit(self: *MetricsSnapshot) void {
        var it = self.counters.iterator();
        while (it.next()) |entry| {
            self.counters.allocator.free(entry.key_ptr.*);
        }
        self.counters.deinit();

        var it2 = self.gauges.iterator();
        while (it2.next()) |entry| {
            self.gauges.allocator.free(entry.key_ptr.*);
        }
        self.gauges.deinit();
    }
};

pub const LLMCallMetrics = struct {
    provider: []const u8,
    model: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cost: f64,
    latency_ms: f64,
    success: bool,
};

pub const PluginExecutionMetrics = struct {
    plugin_name: []const u8,
    hook_type: []const u8, // "on_commit", "on_query", "on_schedule"
    duration_ms: f64,
    llm_calls: u64,
    success: bool,
};

pub const EntityExtractionMetrics = struct {
    entity_type: []const u8,
    accuracy: f32,
    count: u32,

    pub fn confidenceLevel(self: *const EntityExtractionMetrics) []const u8 {
        if (self.accuracy >= 0.9) return "high";
        if (self.accuracy >= 0.7) return "medium";
        return "low";
    }
};

pub const QueryMetrics = struct {
    is_ai_powered: bool,
    latency_ms: f64,
    rows_scanned: u64,
    rows_returned: u64,
    success: bool,
};

// ==================== Tests ====================//

test "MetricsCollector init" {
    var collector = try MetricsCollector.init(std.testing.allocator, .{});
    defer collector.deinit();

    try std.testing.expectEqual(@as(usize, 6), collector.counters.count());
    try std.testing.expectEqual(@as(usize, 3), collector.gauges.count());
    try std.testing.expectEqual(@as(usize, 4), collector.histograms.count());
}

test "MetricsCollector record LLM call" {
    var collector = try MetricsCollector.init(std.testing.allocator, .{});
    defer collector.deinit();

    try collector.startLLMCall("openai", "gpt-4");

    const call = LLMCallMetrics{
        .provider = "openai",
        .model = "gpt-4",
        .input_tokens = 100,
        .output_tokens = 50,
        .cost = 0.01,
        .latency_ms = 500,
        .success = true,
    };

    try collector.recordLLMCall(call);

    const total_calls = collector.counters.get("ai_llm_calls_total").?;
    try std.testing.expectEqual(@as(u64, 1), total_calls.get());
}

test "MetricsCollector record plugin execution" {
    var collector = try MetricsCollector.init(std.testing.allocator, .{});
    defer collector.deinit();

    const exec = PluginExecutionMetrics{
        .plugin_name = "test_plugin",
        .hook_type = "on_commit",
        .duration_ms = 100,
        .llm_calls = 2,
        .success = true,
    };

    try collector.recordPluginExecution(exec);

    const total_executions = collector.counters.get("ai_plugin_executions_total").?;
    try std.testing.expectEqual(@as(u64, 1), total_executions.get());
}

test "MetricsCollector record entity extraction" {
    var collector = try MetricsCollector.init(std.testing.allocator, .{});
    defer collector.deinit();

    const ext = EntityExtractionMetrics{
        .entity_type = "task",
        .accuracy = 0.95,
        .count = 10,
    };

    try collector.recordEntityExtraction(ext);

    const total_extractions = collector.counters.get("ai_entity_extractions_total").?;
    try std.testing.expectEqual(@as(u64, 1), total_extractions.get());
}

test "MetricsCollector record query" {
    var collector = try MetricsCollector.init(std.testing.allocator, .{});
    defer collector.deinit();

    const query = QueryMetrics{
        .is_ai_powered = true,
        .latency_ms = 50,
        .rows_scanned = 1000,
        .rows_returned = 100,
        .success = true,
    };

    try collector.recordQuery(query);

    const total_queries = collector.counters.get("ai_queries_total").?;
    try std.testing.expectEqual(@as(u64, 1), total_queries.get());
}

test "Counter inc" {
    var counter = Counter.init(std.testing.allocator);
    defer counter.deinit();

    counter.inc(5);
    try std.testing.expectEqual(@as(u64, 5), counter.get());

    counter.inc(3);
    try std.testing.expectEqual(@as(u64, 8), counter.get());
}

test "Gauge set" {
    var gauge = Gauge.init(std.testing.allocator);
    defer gauge.deinit();

    gauge.set(10.5);
    try std.testing.expectEqual(@as(f64, 10.5), gauge.get());

    gauge.inc(5.5);
    try std.testing.expectEqual(@as(f64, 16.0), gauge.get());

    gauge.dec(3.0);
    try std.testing.expectEqual(@as(f64, 13.0), gauge.get());
}

test "Histogram observe" {
    var histogram = try Histogram.init(std.testing.allocator, &[_]f64{ 10, 50, 100 });
    defer histogram.deinit();

    try histogram.observe(5);
    try histogram.observe(25);
    try histogram.observe(75);
    try histogram.observe(150);

    try std.testing.expectEqual(@as(u64, 4), histogram.count);
}

test "MetricsCollector snapshot" {
    var collector = try MetricsCollector.init(std.testing.allocator, .{});
    defer collector.deinit();

    const call = LLMCallMetrics{
        .provider = "openai",
        .model = "gpt-4",
        .input_tokens = 100,
        .output_tokens = 50,
        .cost = 0.01,
        .latency_ms = 500,
        .success = true,
    };

    try collector.startLLMCall("openai", "gpt-4");
    try collector.recordLLMCall(call);

    var snapshot = try collector.snapshot();
    defer snapshot.deinit();

    try std.testing.expect(snapshot.counters.count() > 0);
}

test "EntityExtractionMetrics confidenceLevel" {
    const high = EntityExtractionMetrics{
        .entity_type = "task",
        .accuracy = 0.95,
        .count = 1,
    };
    try std.testing.expectEqualStrings("high", high.confidenceLevel());

    const medium = EntityExtractionMetrics{
        .entity_type = "task",
        .accuracy = 0.75,
        .count = 1,
    };
    try std.testing.expectEqualStrings("medium", medium.confidenceLevel());

    const low = EntityExtractionMetrics{
        .entity_type = "task",
        .accuracy = 0.5,
        .count = 1,
    };
    try std.testing.expectEqualStrings("low", low.confidenceLevel());
}
