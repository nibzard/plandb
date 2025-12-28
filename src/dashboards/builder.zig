//! Dashboard generation system for NorthstarDB observability
//!
//! Provides template-based dashboard configuration and generation:
//! - Template-based dashboard config
//! - Auto-generated dashboards from event types
//! - Custom dashboard builder API
//! - Export as HTML/JSON

const std = @import("std");
const analytics = @import("../queries/analytics.zig");
const visualizations = @import("../visualizations/generators.zig");

/// Dashboard widget type
pub const WidgetType = enum {
    line_chart,
    bar_chart,
    pie_chart,
    heatmap,
    histogram,
    metric_card,
    table,
    markdown,
};

/// Dashboard widget configuration
pub const Widget = struct {
    widget_id: []const u8,
    widget_type: WidgetType,
    title: []const u8,
    x: u32, // Grid position
    y: u32,
    width: u32,
    height: u32,
    data_source: DataSource,
    display_options: std.StringHashMap([]const u8),

    pub fn deinit(self: Widget, allocator: std.mem.Allocator) void {
        allocator.free(self.widget_id);
        allocator.free(self.title);
        self.data_source.deinit(allocator);

        var it = self.display_options.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.display_options.deinit();
    }

    pub const DataSource = union(enum) {
        metric_query: MetricQueryConfig,
        aggregation: AggregationQueryConfig,
        custom: []const u8,

        pub fn deinit(self: DataSource, allocator: std.mem.Allocator) void {
            switch (self) {
                .metric_query => |mq| mq.deinit(allocator),
                .aggregation => |aq| aq.deinit(allocator),
                .custom => |s| allocator.free(s),
            }
        }
    };

    pub const MetricQueryConfig = struct {
        metric_name: []const u8,
        time_range_ms: u64,
        aggregation: []const analytics.AggregationFunc,

        pub fn deinit(self: MetricQueryConfig, allocator: std.mem.Allocator) void {
            allocator.free(self.metric_name);
            allocator.free(self.aggregation);
        }
    };

    pub const AggregationQueryConfig = struct {
        query: analytics.AggregationQuery,

        pub fn deinit(self: AggregationQueryConfig, allocator: std.mem.Allocator) void {
            self.query.deinit(allocator);
        }
    };
};

/// Dashboard layout configuration
pub const LayoutConfig = struct {
    columns: u32 = 12,
    row_height: u32 = 60, // pixels
    margin: u32 = 16,
};

/// Dashboard configuration
pub const Dashboard = struct {
    dashboard_id: []const u8,
    name: []const u8,
    description: []const u8,
    widgets: []const Widget,
    layout: LayoutConfig,
    refresh_interval_ms: u64,
    tags: []const []const u8,

    pub fn deinit(self: Dashboard, allocator: std.mem.Allocator) void {
        allocator.free(self.dashboard_id);
        allocator.free(self.name);
        allocator.free(self.description);
        for (self.widgets) |*w| w.deinit(allocator);
        allocator.free(self.widgets);
        for (self.tags) |t| allocator.free(t);
        allocator.free(self.tags);
    }
};

/// Dashboard template
pub const DashboardTemplate = struct {
    template_id: []const u8,
    name: []const u8,
    description: []const u8,
    widgets: []const WidgetTemplate,
    layout: LayoutConfig,

    pub fn deinit(self: DashboardTemplate, allocator: std.mem.Allocator) void {
        allocator.free(self.template_id);
        allocator.free(self.name);
        allocator.free(self.description);
        for (self.widgets) |*w| w.deinit(allocator);
        allocator.free(self.widgets);
    }
};

/// Widget template (placeholder that becomes concrete widget)
pub const WidgetTemplate = struct {
    widget_type: WidgetType,
    title_pattern: []const u8,
    width: u32,
    height: u32,
    data_pattern: DataPattern,

    pub fn deinit(self: WidgetTemplate, allocator: std.mem.Allocator) void {
        allocator.free(self.title_pattern);
        self.data_pattern.deinit(allocator);
    }

    pub const DataPattern = union(enum) {
        metric_by_type: []const u8, // "metric_{type}"
        aggregation_by_metric: []const u8,
        all_events_of_type: []const u8,

        pub fn deinit(self: DataPattern, allocator: std.mem.Allocator) void {
            switch (self) {
                .metric_by_type => |s| allocator.free(s),
                .aggregation_by_metric => |s| allocator.free(s),
                .all_events_of_type => |s| allocator.free(s),
            }
        }
    };
};

/// Rendered dashboard output
pub const RenderedDashboard = struct {
    format: ExportFormat,
    content: []const u8,

    pub fn deinit(self: RenderedDashboard, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }

    pub const ExportFormat = enum {
        html,
        json,
        markdown,
    };
};

/// Dashboard builder
pub const DashboardBuilder = struct {
    allocator: std.mem.Allocator,
    analytics_engine: *analytics.AnalyticsEngine,
    viz_generator: *visualizations.VisualizationGenerator,
    templates: std.StringHashMap(DashboardTemplate),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        analytics_engine: *analytics.AnalyticsEngine,
        viz_generator: *visualizations.VisualizationGenerator,
    ) !Self {
        var builder = Self{
            .allocator = allocator,
            .analytics_engine = analytics_engine,
            .viz_generator = viz_generator,
            .templates = std.StringHashMap(DashboardTemplate).init(allocator),
        };

        try builder.registerDefaultTemplates();

        return builder;
    }

    pub fn deinit(self: *Self) void {
        var it = self.templates.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.templates.deinit();
    }

    /// Create a new dashboard from scratch
    pub fn createDashboard(
        self: *Self,
        dashboard_id: []const u8,
        name: []const u8,
        description: []const u8,
        config: DashboardConfig,
    ) !Dashboard {
        var widgets = std.ArrayList(Widget).init(self.allocator, {};

        for (config.widgets) |widget_config| {
            var display_options = std.StringHashMap([]const u8).init(self.allocator);

            const data_source = try self.createDataSource(widget_config.data_pattern);

            const widget = Widget{
                .widget_id = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ dashboard_id, widgets.items.len }),
                .widget_type = widget_config.widget_type,
                .title = try self.allocator.dupe(u8, widget_config.title),
                .x = widget_config.x,
                .y = widget_config.y,
                .width = widget_config.width,
                .height = widget_config.height,
                .data_source = data_source,
                .display_options = display_options,
            };

            try widgets.append(widget);
        }

        var tags = std.ArrayList([]const u8).init(self.allocator, {};
        for (config.tags) |t| {
            try tags.append(try self.allocator.dupe(u8, t));
        }

        return Dashboard{
            .dashboard_id = try self.allocator.dupe(u8, dashboard_id),
            .name = try self.allocator.dupe(u8, name),
            .description = try self.allocator.dupe(u8, description),
            .widgets = try widgets.toOwnedSlice(),
            .layout = config.layout orelse LayoutConfig{},
            .refresh_interval_ms = config.refresh_interval_ms orelse 30000,
            .tags = try tags.toOwnedSlice(),
        };
    }

    /// Create dashboard from template
    pub fn createFromTemplate(
        self: *Self,
        template_id: []const u8,
        dashboard_id: []const u8,
        name: []const u8,
        substitutions: std.StringHashMap([]const u8),
    ) !Dashboard {
        const template = self.templates.get(template_id) orelse return error.TemplateNotFound;

        var widgets = std.ArrayList(Widget).init(self.allocator, {};

        for (template.widgets) |widget_template| {
            const title = try self.substitute(widget_template.title_pattern, &substitutions);

            var display_options = std.StringHashMap([]const u8).init(self.allocator);

            const data_source = try self.createDataSourceFromPattern(widget_template.data_pattern, &substitutions);

            const widget = Widget{
                .widget_id = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ dashboard_id, widgets.items.len }),
                .widget_type = widget_template.widget_type,
                .title = title,
                .x = 0,
                .y = @as(u32, @intCast(widgets.items.len)) * widget_template.height,
                .width = widget_template.width,
                .height = widget_template.height,
                .data_source = data_source,
                .display_options = display_options,
            };

            try widgets.append(widget);
        }

        return Dashboard{
            .dashboard_id = try self.allocator.dupe(u8, dashboard_id),
            .name = try self.allocator.dupe(u8, name),
            .description = try self.allocator.dupe(u8, template.description),
            .widgets = try widgets.toOwnedSlice(),
            .layout = template.layout,
            .refresh_interval_ms = 30000,
            .tags = &.{},
        };
    }

    /// Auto-generate dashboard for event type
    pub fn generateForEventType(
        self: *Self,
        event_type: []const u8,
        dashboard_id: []const u8,
    ) !Dashboard {
        var widgets = std.ArrayList(Widget).init(self.allocator, {};

        // Add time-series chart
        {
            const title = try std.fmt.allocPrint(self.allocator, "{s} over time", .{event_type});

            var data_map = std.StringHashMap([]const u8).init(self.allocator);
            try data_map.put("metric", try self.allocator.dupe(u8, event_type));

            const data_source = Widget.DataSource{
                .aggregation = .{
                    .query = undefined, // Would build from event type
                },
            };

            const widget = Widget{
                .widget_id = try std.fmt.allocPrint(self.allocator, "{s}_timeseries", .{dashboard_id}),
                .widget_type = .line_chart,
                .title = title,
                .x = 0,
                .y = 0,
                .width = 12,
                .height = 6,
                .data_source = data_source,
                .display_options = data_map,
            };

            try widgets.append(widget);
        }

        // Add histogram
        {
            const title = try std.fmt.allocPrint(self.allocator, "{s} distribution", .{event_type});

            var data_map = std.StringHashMap([]const u8).init(self.allocator);

            const data_source = Widget.DataSource{
                .custom = try self.allocator.dupe(u8, event_type),
            };

            const widget = Widget{
                .widget_id = try std.fmt.allocPrint(self.allocator, "{s}_histogram", .{dashboard_id}),
                .widget_type = .histogram,
                .title = title,
                .x = 0,
                .y = 6,
                .width = 6,
                .height = 4,
                .data_source = data_source,
                .display_options = data_map,
            };

            try widgets.append(widget);
        }

        return Dashboard{
            .dashboard_id = try self.allocator.dupe(u8, dashboard_id),
            .name = try std.fmt.allocPrint(self.allocator, "{s} Dashboard", .{event_type}),
            .description = try std.fmt.allocPrint(self.allocator, "Auto-generated dashboard for {s}", .{event_type}),
            .widgets = try widgets.toOwnedSlice(),
            .layout = LayoutConfig{},
            .refresh_interval_ms = 30000,
            .tags = &.{},
        };
    }

    /// Render dashboard to exportable format
    pub fn renderDashboard(
        self: *Self,
        dashboard: Dashboard,
        format: RenderedDashboard.ExportFormat,
    ) !RenderedDashboard {
        const content = switch (format) {
            .html => try self.renderHTML(dashboard),
            .json => try self.renderJSON(dashboard),
            .markdown => try self.renderMarkdown(dashboard),
        };

        return RenderedDashboard{
            .format = format,
            .content = content,
        };
    }

    fn renderHTML(self: *Self, dashboard: Dashboard) ![]const u8 {
        var html = std.ArrayList(u8).init(self.allocator, {};

        try html.appendSlice("<!DOCTYPE html>\n");
        try html.appendSlice("<html>\n<head>\n");
        try html.appendSlice("<title>");
        try html.appendSlice(dashboard.name);
        try html.appendSlice("</title>\n");
        try html.appendSlice("<script src=\"https://cdn.jsdelivr.net/npm/chart.js\"></script>\n");
        try html.appendSlice("<style>\n");
        try html.appendSlice(".dashboard { display: grid; grid-template-columns: repeat(12, 1fr); gap: 16px; padding: 16px; }\n");
        try html.appendSlice(".widget { background: #fff; border: 1px solid #ddd; border-radius: 8px; padding: 16px; }\n");
        try html.appendSlice(".widget-title { font-weight: bold; margin-bottom: 8px; }\n");
        try html.appendSlice("</style>\n");
        try html.appendSlice("</head>\n<body>\n");
        try html.appendSlice("<div class=\"dashboard\">\n");

        for (dashboard.widgets) |widget| {
            try html.appendSlice("<div class=\"widget\" style=\"grid-column: span ");
            try std.fmt.formatInt(widget.width, .{}, .lower, html.writer());
            try html.appendSlice(";\">\n");
            try html.appendSlice("<div class=\"widget-title\">");
            try html.appendSlice(widget.title);
            try html.appendSlice("</div>\n");
            try html.appendSlice("<canvas id=\"");
            try html.appendSlice(widget.widget_id);
            try html.appendSlice("\"></canvas>\n");
            try html.appendSlice("</div>\n");
        }

        try html.appendSlice("</div>\n");
        try html.appendSlice("</body>\n</html>");

        return html.toOwnedSlice();
    }

    fn renderJSON(self: *Self, dashboard: Dashboard) ![]const u8 {
        _ = self;
        _ = dashboard;
        return error.NotImplemented;
    }

    fn renderMarkdown(self: *Self, dashboard: Dashboard) ![]const u8 {
        _ = self;
        _ = dashboard;
        return error.NotImplemented;
    }

    fn registerDefaultTemplates(self: *Self) !void {
        // Default performance dashboard template
        var widgets = std.ArrayList(WidgetTemplate).init(self.allocator, {};

        try widgets.append(.{
            .widget_type = .line_chart,
            .title_pattern = "Latency over Time",
            .width = 12,
            .height = 6,
            .data_pattern = .{ .metric_by_type = try self.allocator.dupe(u8, "latency") },
        });

        try widgets.append(.{
            .widget_type = .metric_card,
            .title_pattern = "Total Operations",
            .width = 4,
            .height = 3,
            .data_pattern = .{ .metric_by_type = try self.allocator.dupe(u8, "operations_total") },
        });

        const template = DashboardTemplate{
            .template_id = try self.allocator.dupe(u8, "default_performance"),
            .name = try self.allocator.dupe(u8, "Default Performance Dashboard"),
            .description = try self.allocator.dupe(u8, "Standard performance monitoring dashboard"),
            .widgets = try widgets.toOwnedSlice(),
            .layout = LayoutConfig{},
        };

        try self.templates.put(try self.allocator.dupe(u8, "default_performance"), template);
    }

    fn substitute(self: *Self, pattern: []const u8, subs: *const std.StringHashMap([]const u8)) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator, {};
        var i: usize = 0;

        while (i < pattern.len) {
            if (i + 1 < pattern.len and pattern[i] == '{' and pattern[i + 1] == '}') {
                // Find closing }
                const start = i + 2;
                var end = start;
                while (end < pattern.len and pattern[end] != '}') : (end += 1) {}

                if (end < pattern.len) {
                    const key = pattern[start..end];
                    if (subs.get(key)) |value| {
                        try result.appendSlice(value);
                    }
                    i = end + 1;
                    continue;
                }
            }

            try result.append(pattern[i]);
            i += 1;
        }

        return result.toOwnedSlice();
    }

    fn createDataSource(self: *Self, pattern: DataPattern) !Widget.DataSource {
        _ = self;
        _ = pattern;
        return Widget.DataSource{
            .custom = try self.allocator.dupe(u8, "placeholder"),
        };
    }

    fn createDataSourceFromPattern(
        self: *Self,
        pattern: WidgetTemplate.DataPattern,
        subs: *const std.StringHashMap([]const u8),
    ) !Widget.DataSource {
        _ = subs;
        return switch (pattern) {
            .metric_by_type => |s| Widget.DataSource{
                .custom = try self.allocator.dupe(u8, s),
            },
            .aggregation_by_metric => |s| Widget.DataSource{
                .custom = try self.allocator.dupe(u8, s),
            },
            .all_events_of_type => |s| Widget.DataSource{
                .custom = try self.allocator.dupe(u8, s),
            },
        };
    }
};

/// Widget configuration for dashboard builder
pub const WidgetConfig = struct {
    widget_type: WidgetType,
    title: []const u8,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    data_pattern: DataPattern,
};

pub const DataPattern = struct {
    pattern_type: PatternType,
    value: []const u8,

    pub const PatternType = enum {
        metric,
        aggregation,
        custom,
    };
};

/// Dashboard creation configuration
pub const DashboardConfig = struct {
    widgets: []const WidgetConfig,
    layout: ?LayoutConfig = null,
    refresh_interval_ms: ?u64 = null,
    tags: []const []const u8 = &.{},
};

// Tests
test "DashboardBuilder.init" {
    const allocator = std.testing.allocator;

    const engine = try analytics.AnalyticsEngine.init(
        allocator,
        undefined,
        .{},
    );
    defer engine.deinit();

    const viz = try visualizations.VisualizationGenerator.init(allocator, &engine);
    defer _ = viz;

    const builder = try DashboardBuilder.init(allocator, &engine, &viz);
    defer builder.deinit();

    try std.testing.expect(builder.templates.count() > 0);
}
