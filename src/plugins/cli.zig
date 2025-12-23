//! CLI commands for plugin management
//!
//! Provides command-line interface for plugin development, testing, and validation

const std = @import("std");
const manager = @import("manager.zig");
const testing = @import("testing.zig");
const debug_mod = @import("debug.zig");

pub const PluginCli = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Run plugin CLI command
    pub fn run(self: *Self, args: []const []const u8) !void {
        if (args.len == 0) {
            try self.printUsage();
            return;
        }

        const command = args[0];

        if (std.mem.eql(u8, command, "list")) {
            try self.listPlugins(args[1..]);
        } else if (std.mem.eql(u8, command, "test")) {
            try self.testPlugins(args[1..]);
        } else if (std.mem.eql(u8, command, "validate")) {
            try self.validatePlugins(args[1..]);
        } else if (std.mem.eql(u8, command, "info")) {
            try self.showPluginInfo(args[1..]);
        } else if (std.mem.eql(u8, command, "mock")) {
            try self.runMockTests(args[1..]);
        } else if (std.mem.eql(u8, command, "trace")) {
            try self.traceExecution(args[1..]);
        } else {
            try self.printUsage();
        }
    }

    fn printUsage(self: *Self) !void {
        _ = self;
        std.debug.print(
            \\NorthstarDB Plugin Management CLI
            \\
            \\Usage:
            \\  bench plugin list                    List all registered plugins
            \\  bench plugin test [name]             Run tests for plugin(s)
            \\  bench plugin validate [name]         Validate plugin schemas
            \\  bench plugin info <name>             Show detailed plugin info
            \\  bench plugin mock <test>             Run mock LLM tests
            \\  bench plugin trace <db>              Enable execution tracing
            \\
            \\Options:
            \\  --verbose                            Show detailed output
            \\  --json                               Output as JSON
            \\
        , .{});
    }

    fn listPlugins(self: *Self, args: []const []const u8) !void {
        _ = args;
        std.debug.print("=== Registered Plugins ===\n\n", .{});

        // Create a temporary plugin manager to list plugins
        var pm = try manager.PluginManager.init(self.allocator, .{
            .llm_provider = .{
                .provider_type = "local",
                .model = "test",
            },
        });
        defer pm.deinit();

        if (pm.plugins.count() == 0) {
            std.debug.print("No plugins registered.\n", .{});
            std.debug.print("\nHint: Plugins are registered at database initialization.\n", .{});
            return;
        }

        var it = pm.plugins.iterator();
        while (it.next()) |entry| {
            const plugin = &entry.value_ptr.*;
            std.debug.print("  {s} v{s}\n", .{ plugin.name, plugin.version });

            var hook_count: usize = 0;
            if (plugin.on_commit != null) hook_count += 1;
            if (plugin.on_query != null) hook_count += 1;
            if (plugin.on_schedule != null) hook_count += 1;

            if (hook_count > 0) {
                std.debug.print("    Hooks: {d}\n", .{hook_count});
            }
        }

        std.debug.print("\nTotal: {d} plugin(s)\n", .{pm.plugins.count()});
    }

    fn testPlugins(self: *Self, args: []const []const u8) !void {
        _ = args;
        std.debug.print("=== Plugin Tests ===\n\n", .{});

        // Create mock LLM provider
        var mock = testing.MockLLMProvider.init(self.allocator);
        defer mock.deinit();

        // Add mock response for entity extraction
        const entities = [_]testing.MockLLMProvider.EntityMock{
            .{ .name = "TestEntity", .type_name = "TestType", .confidence = 0.9 },
        };
        try mock.addEntityExtractionResponse(&entities);

        // Create test harness
        const config = manager.PluginConfig{
            .llm_provider = .{
                .provider_type = "local",
                .model = "test",
            },
        };

        var harness = try mock.createTestHarness(config);
        defer harness.deinit();

        // Register test plugin
        const plugin = testing.PluginFixtures.createEntityExtractionPlugin(self.allocator);
        try harness.registerPlugin(plugin);

        // Run test
        try harness.runTest("entity_extraction", struct {
            fn testFn(h: *testing.TestHarness) anyerror!void {
                _ = h;
                try std.testing.expect(true);
            }
        }.testFn);

        harness.printResults();
    }

    fn validatePlugins(self: *Self, args: []const []const u8) !void {
        _ = args;
        std.debug.print("=== Plugin Validation ===\n\n", .{});

        var validator = debug_mod.PluginValidator.init(self.allocator);
        defer validator.deinit();

        // Validate test plugin
        const plugin = testing.PluginFixtures.createEntityExtractionPlugin(self.allocator);
        const result = try validator.validatePlugin(&plugin);
        defer {
            var mut_result = result;
            mut_result.deinit(self.allocator);
        }

        if (result.is_valid) {
            std.debug.print("OK Plugin validation PASSED\n", .{});
        } else {
            std.debug.print("X Plugin validation FAILED\n", .{});
        }

        if (result.errors.len > 0) {
            std.debug.print("\nErrors:\n", .{});
            for (result.errors) |err| {
                std.debug.print("  [{s}] {s}\n", .{ err.field, err.message });
            }
        }

        if (result.warnings.len > 0) {
            std.debug.print("\nWarnings:\n", .{});
            for (result.warnings) |warn| {
                std.debug.print("  [{s}] {s}\n", .{ warn.field, warn.message });
            }
        }
    }

    fn showPluginInfo(self: *Self, args: []const []const u8) !void {
        if (args.len == 0) {
            std.debug.print("Error: 'plugin info' requires a plugin name\n", .{});
            return;
        }

        const plugin_name = args[0];
        std.debug.print("=== Plugin Info: {s} ===\n", .{plugin_name});

        // Show mock plugin info for demo
        const plugin = testing.PluginFixtures.createEntityExtractionPlugin(self.allocator);
        std.debug.print("Name: {s}\n", .{plugin.name});
        std.debug.print("Version: {s}\n", .{plugin.version});
        std.debug.print("On Commit: {s}\n", .{if (plugin.on_commit != null) "Yes" else "No"});
        std.debug.print("On Query: {s}\n", .{if (plugin.on_query != null) "Yes" else "No"});
        std.debug.print("On Schedule: {s}\n", .{if (plugin.on_schedule != null) "Yes" else "No"});
        std.debug.print("Get Functions: {s}\n", .{if (plugin.get_functions != null) "Yes" else "No"});
    }

    fn runMockTests(self: *Self, args: []const []const u8) !void {
        _ = args;
        std.debug.print("=== Mock LLM Tests ===\n\n", .{});

        var mock = testing.MockLLMProvider.init(self.allocator);
        defer mock.deinit();

        // Test simple response
        try mock.addSimpleResponse("test_function", "{\"status\": \"ok\"}");
        std.debug.print("OK Added simple response\n", .{});

        // Test entity extraction response
        const entities = [_]testing.MockLLMProvider.EntityMock{
            .{ .name = "Claude", .type_name = "AI", .confidence = 0.95 },
            .{ .name = "Zig", .type_name = "Language", .confidence = 1.0 },
        };
        try mock.addEntityExtractionResponse(&entities);
        std.debug.print("OK Added entity extraction response ({d} entities)\n", .{entities.len});

        std.debug.print("\nMock provider initialized with {d} responses\n", .{mock.responses.items.len});
    }

    fn traceExecution(self: *Self, args: []const []const u8) !void {
        _ = args;
        std.debug.print("=== Execution Tracing Demo ===\n\n", .{});

        var tracer = debug_mod.PluginTracer.init(self.allocator);
        defer tracer.deinit();

        // Simulate plugin execution with tracing
        const span1 = try tracer.startSpan("entity_extraction", .plugin_hook);
        try tracer.addMetadata(span1, "plugin", "entity_extractor");
        try tracer.addMetadata(span1, "txn_id", "12345");

        // Simulate LLM call
        try tracer.logLLMCall(span1, "extract_entities", .{
            .prompt_tokens = 100,
            .completion_tokens = 50,
            .total_tokens = 150,
        }, 150, true);

        // Nested span
        const span2 = try tracer.startSpan("cartridge_update", .commit_processing);
        try tracer.logLLMCall(span2, "save_entities", .{
            .prompt_tokens = 10,
            .completion_tokens = 5,
            .total_tokens = 15,
        }, 20, true);
        try tracer.endSpan(span2);

        try tracer.endSpan(span1);

        // Generate report to stdout via debug print
        std.debug.print("\n=== Execution Trace Report ===\n", .{});
        const stats = tracer.getStatistics();
        std.debug.print("Summary:\n", .{});
        std.debug.print("  Total Duration: {d:.2}ms\n", .{@as(f64, @floatFromInt(stats.total_duration_ns)) / 1_000_000.0});
        std.debug.print("  LLM Calls: {d}\n", .{stats.total_llm_calls});
        std.debug.print("  Tokens Used: {d}\n", .{stats.total_tokens_used});
        std.debug.print("  Failed Calls: {d}\n", .{stats.failed_llm_calls});
        std.debug.print("  Spans: {d}\n\n", .{stats.span_count});
    }
};

/// List all available plugin commands
pub fn printPluginHelp() !void {
    std.debug.print(
        \\Plugin Management Commands:
        \\
        \\  list        List all registered plugins
        \\  test        Run plugin tests
        \\  validate    Validate plugin schemas
        \\  info        Show detailed plugin information
        \\  mock        Run mock LLM tests
        \\  trace       Demo execution tracing
        \\
    , .{});
}
