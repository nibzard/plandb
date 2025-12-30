//! Plugin SDK for NorthstarDB custom plugin development
//!
//! Provides templates, scaffolding, and developer utilities for creating custom plugins

const std = @import("std");
const manager = @import("manager.zig");

/// Plugin template types for scaffolding
pub const PluginTemplate = enum {
    /// Entity extraction plugin - extracts entities from commits
    entity_extractor,
    /// Topic indexing plugin - indexes topics from content
    topic_indexer,
    /// Query optimization plugin - enhances query performance
    query_optimizer,
    /// Custom hook plugin - user-defined hooks
    custom_hook,
    /// Function provider plugin - provides AI functions
    function_provider,
    /// Full featured plugin - all hooks and functions
    full_featured,
};

/// Plugin scaffolding configuration
pub const ScaffoldConfig = struct {
    name: []const u8,
    version: []const u8 = "0.1.0",
    description: []const u8 = "",
    author: []const u8 = "",
    template: PluginTemplate,
    output_dir: []const u8,
    include_tests: bool = true,
    include_docs: bool = true,
};

/// Plugin scaffolder for generating plugin boilerplate
pub const PluginScaffolder = struct {
    allocator: std.mem.Allocator,
    config: ScaffoldConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ScaffoldConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Generate plugin from template
    pub fn generate(self: *Self) !void {
        // Create output directory
        const output_path = try std.fs.path.join(self.allocator, &.{
            self.config.output_dir, self.config.name
        });
        defer self.allocator.free(output_path);

        var dir = std.fs.cwd().makeOpenPath(output_path, .{}) catch |err| {
            std.log.err("Failed to create output directory: {s}", .{output_path});
            return err;
        };
        defer dir.close();

        // Generate plugin source file
        const source_code = try self.generatePluginSource();
        defer self.allocator.free(source_code);

        {
            const source_file = try dir.createFile("plugin.zig", .{ .read = true });
            defer source_file.close();
            try source_file.writeAll(source_code);
        }

        // Generate build.zig if requested
        if (self.config.include_tests) {
            const build_code = try self.generateBuildZig();
            defer self.allocator.free(build_code);

            {
                const build_file = try dir.createFile("build.zig", .{ .read = true });
                defer build_file.close();
                try build_file.writeAll(build_code);
            }
        }

        // Generate test file
        if (self.config.include_tests) {
            const test_code = try self.generateTestFile();
            defer self.allocator.free(test_code);

            {
                const test_file = try dir.createFile("plugin_test.zig", .{ .read = true });
                defer test_file.close();
                try test_file.writeAll(test_code);
            }
        }

        // Generate documentation
        if (self.config.include_docs) {
            const readme = try self.generateReadme();
            defer self.allocator.free(readme);

            {
                const readme_file = try dir.createFile("README.md", .{ .read = true });
                defer readme_file.close();
                try readme_file.writeAll(readme);
            }
        }

        // Generate manifest
        const manifest = try self.generateManifest();
        defer self.allocator.free(manifest);

        {
            const manifest_file = try dir.createFile("plugin.json", .{ .read = true });
            defer manifest_file.close();
            try manifest_file.writeAll(manifest);
        }

        std.log.info("Generated plugin '{s}' in {s}", .{ self.config.name, output_path });
    }

    fn generatePluginSource(self: *Self) ![]const u8 {
        return switch (self.config.template) {
            .entity_extractor => self.generateEntityExtractor(),
            .topic_indexer => self.generateTopicIndexer(),
            .query_optimizer => self.generateQueryOptimizer(),
            .custom_hook => self.generateCustomHook(),
            .function_provider => self.generateFunctionProvider(),
            .full_featured => self.generateFullFeatured(),
        };
    }

    fn generateEntityExtractor(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\//! {s} Plugin for NorthstarDB
            \\//!
            \\//! {s}
            \\//! Author: {s}
            \\//! Version: {s}
            \\
            \\const std = @import("std");
            \\const manager = @import("../manager.zig");
            \\const llm = @import("../../llm/types.zig");
            \\
            \\/// Plugin instance
            \\pub const plugin = manager.Plugin{{
            \\    .name = "{s}",
            \\    .version = "{s}",
            \\    .on_commit = onCommitHook,
            \\    .on_query = null,
            \\    .on_schedule = null,
            \\    .get_functions = getFunctions,
            \\    .on_agent_session_start = null,
            \\    .on_agent_operation = null,
            \\    .on_review_request = null,
            \\    .on_perf_sample = null,
            \\    .on_benchmark_complete = null,
            \\}};
            \\
            \\/// Hook called on each commit
            \\fn onCommitHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.CommitContext
            \\) anyerror!manager.PluginResult {{
            \\    _ = allocator;
            \\
            \\    // Extract entities from mutations
            \\    var entity_count: usize = 0;
            \\    for (ctx.mutations) |mutation| {{
            \\        // Process each mutation
            \\        _ = mutation;
            \\        entity_count += 1;
            \\    }}
            \\
            \\    return manager.PluginResult{{
            \\        .success = true,
            \\        .operations_processed = entity_count,
            \\        .cartridges_updated = 1, // Updated entity cartridge
            \\    }};
            \\}}
            \\
            \\/// Get function schemas for AI function calling
            \\fn getFunctions(allocator: std.mem.Allocator) []manager.FunctionSchema {{
            \\    _ = allocator;
            \\    const functions = [_]manager.FunctionSchema{{}};
            \\    return functions[0..];
            \\}}
            \\
            \\// Export plugin interface
            \\pub const Plugin = struct {{
            \\    pub fn init() manager.Plugin {{
            \\        return plugin;
            \\    }}
            \\}};
        , .{
            self.config.name,
            if (self.config.description.len > 0) self.config.description else "Entity extraction plugin",
            self.config.author,
            self.config.version,
            self.config.name,
            self.config.version,
        });
    }

    fn generateTopicIndexer(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\//! {s} Plugin for NorthstarDB
            \\//!
            \\//! {s}
            \\//! Author: {s}
            \\//! Version: {s}
            \\
            \\const std = @import("std");
            \\const manager = @import("../manager.zig");
            \\
            \\pub const plugin = manager.Plugin{{
            \\    .name = "{s}",
            \\    .version = "{s}",
            \\    .on_commit = onCommitHook,
            \\    .on_query = onQueryHook,
            \\    .on_schedule = null,
            \\    .get_functions = null,
            \\    .on_agent_session_start = null,
            \\    .on_agent_operation = null,
            \\    .on_review_request = null,
            \\    .on_perf_sample = null,
            \\    .on_benchmark_complete = null,
            \\}};
            \\
            \\fn onCommitHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.CommitContext
            \\) anyerror!manager.PluginResult {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\
            \\    // Index topics from commit content
            \\    return manager.PluginResult{{
            \\        .success = true,
            \\        .operations_processed = 1,
            \\        .cartridges_updated = 1, // Updated topic cartridge
            \\    }};
            \\}}
            \\
            \\fn onQueryHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.QueryContext
            \\) anyerror!?manager.QueryPlan {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\
            \\    // Enhance query with topic information
            \\    return null; // No special handling
            \\}}
            \\
            \\pub const Plugin = struct {{
            \\    pub fn init() manager.Plugin {{
            \\        return plugin;
            \\    }}
            \\}};
        , .{
            self.config.name,
            if (self.config.description.len > 0) self.config.description else "Topic indexing plugin",
            self.config.author,
            self.config.version,
            self.config.name,
            self.config.version,
        });
    }

    fn generateQueryOptimizer(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\//! {s} Plugin for NorthstarDB
            \\//!
            \\//! {s}
            \\//! Author: {s}
            \\//! Version: {s}
            \\
            \\const std = @import("std");
            \\const manager = @import("../manager.zig");
            \\
            \\pub const plugin = manager.Plugin{{
            \\    .name = "{s}",
            \\    .version = "{s}",
            \\    .on_commit = null,
            \\    .on_query = onQueryHook,
            \\    .on_schedule = onScheduleHook,
            \\    .get_functions = null,
            \\    .on_agent_session_start = null,
            \\    .on_agent_operation = null,
            \\    .on_review_request = null,
            \\    .on_perf_sample = null,
            \\    .on_benchmark_complete = null,
            \\}};
            \\
            \\fn onQueryHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.QueryContext
            \\) anyerror!?manager.QueryPlan {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\
            \\    // Analyze query and suggest optimizations
            \\    return manager.QueryPlan{{ .use_cartridge = .{{
            \\        .cartridge_type = .entity,
            \\        .query = "optimized_query",
            \\    }} }};
            \\}}
            \\
            \\fn onScheduleHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.ScheduleContext
            \\) anyerror!manager.MaintenanceTask {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\
            \\    // Schedule optimization tasks
            \\    return manager.MaintenanceTask{{
            \\        .task_name = "optimize_indexes",
            \\        .priority = 5,
            \\        .estimated_duration_ms = 1000,
            \\        .execute = executeOptimization,
            \\    }};
            \\}}
            \\
            \\fn executeOptimization(allocator: std.mem.Allocator) anyerror!void {{
            \\    _ = allocator;
            \\    // Perform optimization
            \\}}
            \\
            \\pub const Plugin = struct {{
            \\    pub fn init() manager.Plugin {{
            \\        return plugin;
            \\    }}
            \\}};
        , .{
            self.config.name,
            if (self.config.description.len > 0) self.config.description else "Query optimization plugin",
            self.config.author,
            self.config.version,
            self.config.name,
            self.config.version,
        });
    }

    fn generateCustomHook(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\//! {s} Plugin for NorthstarDB
            \\//!
            \\//! {s}
            \\//! Author: {s}
            \\//! Version: {s}
            \\
            \\const std = @import("std");
            \\const manager = @import("../manager.zig");
            \\
            \\pub const plugin = manager.Plugin{{
            \\    .name = "{s}",
            \\    .version = "{s}",
            \\    .on_commit = onCommitHook,
            \\    .on_query = onQueryHook,
            \\    .on_schedule = onScheduleHook,
            \\    .get_functions = null,
            \\    .on_agent_session_start = onAgentSessionStart,
            \\    .on_agent_operation = onAgentOperation,
            \\    .on_review_request = onReviewRequest,
            \\    .on_perf_sample = onPerfSample,
            \\    .on_benchmark_complete = onBenchmarkComplete,
            \\}};
            \\
            \\fn onCommitHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.CommitContext
            \\) anyerror!manager.PluginResult {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\    return manager.PluginResult{{
            \\        .success = true,
            \\        .operations_processed = 1,
            \\        .cartridges_updated = 0,
            \\    }};
            \\}}
            \\
            \\fn onQueryHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.QueryContext
            \\) anyerror!?manager.QueryPlan {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\    return null;
            \\}}
            \\
            \\fn onScheduleHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.ScheduleContext
            \\) anyerror!manager.MaintenanceTask {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\    @panic("Implement maintenance task");
            \\}}
            \\
            \\fn onAgentSessionStart(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.AgentSessionContext
            \\) anyerror!void {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\}}
            \\
            \\fn onAgentOperation(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.AgentOperationContext
            \\) anyerror!void {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\}}
            \\
            \\fn onReviewRequest(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.ReviewContext
            \\) anyerror!manager.PluginResult {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\    return manager.PluginResult{{
            \\        .success = true,
            \\        .operations_processed = 1,
            \\        .cartridges_updated = 0,
            \\    }};
            \\}}
            \\
            \\fn onPerfSample(
            \\    allocator: std.mem.Allocator,
    \\    ctx: manager.PerfSampleContext
            \\) anyerror!void {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\}}
            \\
            \\fn onBenchmarkComplete(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.BenchmarkCompleteContext
            \\) anyerror!void {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\}}
            \\
            \\pub const Plugin = struct {{
            \\    pub fn init() manager.Plugin {{
            \\        return plugin;
            \\    }}
            \\}};
        , .{
            self.config.name,
            if (self.config.description.len > 0) self.config.description else "Custom hook plugin",
            self.config.author,
            self.config.version,
            self.config.name,
            self.config.version,
        });
    }

    fn generateFunctionProvider(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\//! {s} Plugin for NorthstarDB
            \\//!
            \\//! {s}
            \\//! Author: {s}
            \\//! Version: {s}
            \\
            \\const std = @import("std");
            \\const manager = @import("../manager.zig");
            \\const llm_function = @import("../../llm/function.zig");
            \\
            \\pub const plugin = manager.Plugin{{
            \\    .name = "{s}",
            \\    .version = "{s}",
            \\    .on_commit = null,
            \\    .on_query = null,
            \\    .on_schedule = null,
            \\    .get_functions = getFunctions,
            \\    .on_agent_session_start = null,
            \\    .on_agent_operation = null,
            \\    .on_review_request = null,
            \\    .on_perf_sample = null,
            \\    .on_benchmark_complete = null,
            \\}};
            \\
            \\fn getFunctions(allocator: std.mem.Allocator) []manager.FunctionSchema {{
            \\    // Create function schemas for AI function calling
            \\    var functions = std.ArrayList(manager.FunctionSchema).init(allocator);
            \\
            \\    // Example: Add a custom function
            \\    // var params = llm_function.JSONSchema.init(.object);
            \\    // var schema = manager.FunctionSchema.init(
            \\    //     allocator,
            \\    //     "my_function",
            \\    //     "Description of what this function does",
            \\    //     params
            \\    // ) catch |err| {{
            \\    //     std.log.err("Failed to create function schema: {{}}", .{{err}});
            \\    //     return functions.items;
            \\    // }};
            \\    // functions.append(schema) catch |err| {{
            \\    //     std.log.err("Failed to append function: {{}}", .{{err}});
            \\    // }};
            \\
            \\    return functions.toOwnedSlice() catch &[_]manager.FunctionSchema{{}};
            \\}}
            \\
            \\pub const Plugin = struct {{
            \\    pub fn init() manager.Plugin {{
            \\        return plugin;
            \\    }}
            \\}};
        , .{
            self.config.name,
            if (self.config.description.len > 0) self.config.description else "Function provider plugin",
            self.config.author,
            self.config.version,
            self.config.name,
            self.config.version,
        });
    }

    fn generateFullFeatured(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\//! {s} Plugin for NorthstarDB
            \\//!
            \\//! Full-featured plugin with all hooks and functions
            \\//! Author: {s}
            \\//! Version: {s}
            \\
            \\const std = @import("std");
            \\const manager = @import("../manager.zig");
            \\const llm_function = @import("../../llm/function.zig");
            \\
            \\pub const plugin = manager.Plugin{{
            \\    .name = "{s}",
            \\    .version = "{s}",
            \\    .on_commit = onCommitHook,
            \\    .on_query = onQueryHook,
            \\    .on_schedule = onScheduleHook,
            \\    .get_functions = getFunctions,
            \\    .on_agent_session_start = onAgentSessionStart,
            \\    .on_agent_operation = onAgentOperation,
            \\    .on_review_request = onReviewRequest,
            \\    .on_perf_sample = onPerfSample,
            \\    .on_benchmark_complete = onBenchmarkComplete,
            \\}};
            \\
            \\// Commit hook - called on each database commit
            \\fn onCommitHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.CommitContext
            \\) anyerror!manager.PluginResult {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\    return manager.PluginResult{{
            \\        .success = true,
            \\        .operations_processed = 1,
            \\        .cartridges_updated = 0,
            \\    }};
            \\}}
            \\
            \\// Query hook - called to optimize or handle queries
            \\fn onQueryHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.QueryContext
            \\) anyerror!?manager.QueryPlan {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\    return null;
            \\}}
            \\
            \\// Schedule hook - called for maintenance tasks
            \\fn onScheduleHook(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.ScheduleContext
            \\) anyerror!manager.MaintenanceTask {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\    @panic("Implement maintenance task");
            \\}}
            \\
            \\// Agent session hook - called when agent session starts
            \\fn onAgentSessionStart(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.AgentSessionContext
            \\) anyerror!void {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\}}
            \\
            \\// Agent operation hook - called for each agent operation
            \\fn onAgentOperation(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.AgentOperationContext
            \\) anyerror!void {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\}}
            \\
            \\// Review request hook - called for code reviews
            \\fn onReviewRequest(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.ReviewContext
            \\) anyerror!manager.PluginResult {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\    return manager.PluginResult{{
            \\        .success = true,
            \\        .operations_processed = 1,
            \\        .cartridges_updated = 0,
            \\    }};
            \\}}
            \\
            \\// Performance sample hook - called for metrics
            \\fn onPerfSample(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.PerfSampleContext
            \\) anyerror!void {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\}}
            \\
            \\// Benchmark complete hook - called after benchmarks
            \\fn onBenchmarkComplete(
            \\    allocator: std.mem.Allocator,
            \\    ctx: manager.BenchmarkCompleteContext
            \\) anyerror!void {{
            \\    _ = allocator;
            \\    _ = ctx;
            \\}}
            \\
            \\// Get AI function schemas
            \\fn getFunctions(allocator: std.mem.Allocator) []manager.FunctionSchema {{
            \\    _ = allocator;
            \\    return &[_]manager.FunctionSchema{{}};
            \\}}
            \\
            \\pub const Plugin = struct {{
            \\    pub fn init() manager.Plugin {{
            \\        return plugin;
            \\    }}
            \\}};
        , .{
            self.config.name,
            self.config.author,
            self.config.version,
            self.config.name,
            self.config.version,
        });
    }

    fn generateBuildZig(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\//! Build configuration for {s} plugin
            \\
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {{
            \\    const target = b.standardTargetOptions(.{{}});
            \\    const optimize = b.standardOptimizeOption(.{{}});
            \\
            \\    const plugin_mod = b.addModule("{s}", .{{
            \\        .root_source_file = b.path("plugin.zig"),
            \\    }});
            \\
            \\    // Test executable
            \\    const tests = b.addTest(.{{
            \\        .root_source_file = b.path("plugin_test.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\
            \\    tests.root_module.addImport("manager", b.dependency("northstar_db", .{{}}.module("manager"));
            \\    tests.root_module.addImport("plugin", plugin_mod);
            \\
            \\    const run_tests = b.addRunArtifact(tests);
            \\    const test_step = b.step("test", "Run plugin tests");
            \\    test_step.dependOn(&run_tests.step);
            \\}}
        , .{ self.config.name, self.config.name });
    }

    fn generateTestFile(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\//! Tests for {s} plugin
            \\
            \\const std = @import("std");
            \\const testing = @import("../../plugins/testing.zig");
            \\const manager = @import("../manager.zig");
            \\
            \\test "plugin_initialization" {{
            \\    const plugin = @import("plugin.zig").plugin;
            \\    try std.testing.expectEqualStrings("{s}", plugin.name);
            \\    try std.testing.expectEqualStrings("{s}", plugin.version);
            \\}}
            \\
            \\test "plugin_commit_hook" {{
            \\    const plugin = @import("plugin.zig").plugin;
            \\
            \\    if (plugin.on_commit) |hook| {{
            \\        const ctx = testing.PluginFixtures.createMockCommitContext(std.testing.allocator);
            \\        defer ctx.deinit(std.testing.allocator);
            \\
            \\        const result = hook(std.testing.allocator, ctx) catch |err| {{
            \\            std.log.err("Commit hook failed: {{}}", .{{err}});
            \\            return err;
            \\        }};
            \\
            \\        try std.testing.expect(result.success);
            \\    }}
            \\}}
            \\
            \\test "plugin_validation" {{
            \\    const validator = @import("../../plugins/debug.zig").PluginValidator;
            \\    var v = validator.init(std.testing.allocator);
            \\    defer v.deinit();
            \\
            \\    const plugin = @import("plugin.zig").plugin;
            \\    const result = try v.validatePlugin(&plugin);
            \\    defer result.deinit(std.testing.allocator);
            \\
            \\    try std.testing.expect(result.is_valid);
            \\}}
        , .{ self.config.name, self.config.name, self.config.version });
    }

    fn generateReadme(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\# {s} Plugin
            \\
            \\{s}
            \\
            \\**Author:** {s}
            \\**Version:** {s}
            \\
            \\## Overview
            \\
            \\This is a custom plugin for NorthstarDB.
            \\
            \\## Installation
            \\
            \\1. Copy this plugin to your NorthstarDB plugins directory
            \\2. Register the plugin in your database initialization
            \\
            \\## Usage
            \\
            \\```zig
            \\const my_plugin = @import("./plugins/{s}/plugin.zig").plugin;
            \\try plugin_manager.register_plugin(my_plugin);
            \\```
            \\
            \\## Development
            \\
            \\### Build
            \\
            \\```bash
            \\zig build test
            \\```
            \\
            \\### Test
            \\
            \\```bash
            \\zig test plugin.zig
            \\```
            \\
            \\## Hooks
            \\
            \\This plugin implements the following hooks:
            \\
            \\- `on_commit`: Called on each commit
            \\- `on_query`: Called for query optimization
            \\- `on_schedule`: Called for maintenance tasks
            \\
            \\## License
            \\
            \\MIT
        , .{
            self.config.name,
            if (self.config.description.len > 0) self.config.description else "Custom plugin for NorthstarDB",
            self.config.author,
            self.config.version,
            self.config.name,
        });
    }

    fn generateManifest(self: *Self) ![]const u8 {
        const hooks = self.getTemplateHooks();

        // Build manifest as string directly (simpler than dealing with JSON API changes)
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(self.allocator);
        const writer = buffer.writer(self.allocator);

        try writer.print(
            \\{{
            \\  "name": "{s}",
            \\  "version": "{s}",
            \\  "description": "{s}",
            \\  "author": "{s}",
            \\  "template": "{s}",
            \\  "min_northstar_version": "0.1.0",
            \\  "hooks": [
        , .{
            self.config.name,
            self.config.version,
            if (self.config.description.len > 0) self.config.description else "Custom plugin",
            if (self.config.author.len > 0) self.config.author else "Unknown",
            @tagName(self.config.template),
        });

        for (hooks, 0..) |hook, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writer.print("    \"{s}\"", .{hook});
        }

        try writer.writeAll(
            \\  ],
            \\  "permissions": {
            \\    "llm_access": true,
            \\    "cartridge_write": true,
            \\    "network_access": false
            \\  }
            \\}
        );

        return buffer.toOwnedSlice(self.allocator);
    }

    fn getTemplateHooks(self: *Self) []const []const u8 {
        return switch (self.config.template) {
            .entity_extractor => &[_][]const u8{ "on_commit", "get_functions" },
            .topic_indexer => &[_][]const u8{ "on_commit", "on_query" },
            .query_optimizer => &[_][]const u8{ "on_query", "on_schedule" },
            .custom_hook => &[_][]const u8{ "on_commit", "on_query", "on_schedule", "on_agent_session_start", "on_agent_operation", "on_review_request", "on_perf_sample", "on_benchmark_complete" },
            .function_provider => &[_][]const u8{ "get_functions" },
            .full_featured => &[_][]const u8{ "on_commit", "on_query", "on_schedule", "get_functions", "on_agent_session_start", "on_agent_operation", "on_review_request", "on_perf_sample", "on_benchmark_complete" },
        };
    }
};

/// CLI command for scaffolding plugins
pub fn runScaffoldCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.log.err("Usage: plugin scaffold <name> <template> [options]", .{});
        std.log.err("Templates: entity_extractor, topic_indexer, query_optimizer, custom_hook, function_provider, full_featured", .{});
        return error.InvalidArguments;
    }

    const name = args[0];
    const template_str = args[1];

    const template = std.meta.stringToEnum(PluginTemplate, template_str) orelse {
        std.log.err("Unknown template: {s}", .{template_str});
        return error.InvalidTemplate;
    };

    var config = ScaffoldConfig{
        .name = name,
        .version = "0.1.0",
        .description = "",
        .author = "",
        .template = template,
        .output_dir = ".",
        .include_tests = true,
        .include_docs = true,
    };

    // Parse optional arguments
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) break;

        if (std.mem.eql(u8, args[i], "--output")) {
            config.output_dir = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--version")) {
            config.version = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--description")) {
            config.description = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--author")) {
            config.author = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--no-tests")) {
            config.include_tests = false;
            i -= 1; // No value for flag
        } else if (std.mem.eql(u8, args[i], "--no-docs")) {
            config.include_docs = false;
            i -= 1; // No value for flag
        }
    }

    var scaffolder = PluginScaffolder.init(allocator, config);
    try scaffolder.generate();
}

test "scaffolder_entity_extractor" {
    var scaffolder = PluginScaffolder.init(std.testing.allocator, .{
        .name = "test_entity_plugin",
        .version = "0.1.0",
        .description = "Test entity extractor",
        .author = "Test Author",
        .template = .entity_extractor,
        .output_dir = "/tmp",
        .include_tests = true,
        .include_docs = true,
    });

    const source = try scaffolder.generateEntityExtractor();
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "test_entity_plugin") != null);
}

test "scaffolder_manifest" {
    var scaffolder = PluginScaffolder.init(std.testing.allocator, .{
        .name = "test_plugin",
        .version = "1.0.0",
        .description = "Test",
        .author = "Author",
        .template = .entity_extractor,
        .output_dir = "/tmp",
    });

    const manifest = try scaffolder.generateManifest();
    defer std.testing.allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "test_plugin") != null);
}
