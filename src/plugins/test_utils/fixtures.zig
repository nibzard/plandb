//! Test fixtures for entity extraction examples
//!
//! Provides sample data and configurations for testing entity extraction plugins

const std = @import("std");
const manager = @import("../manager.zig");
const llm_function = @import("../../llm/function.zig");

/// Sample text data for entity extraction testing
pub const SampleTexts = struct {
    /// Code-related text for extraction
    pub const code_sample =
        \\The Claude Code agent is an interactive CLI tool that helps users with software engineering tasks.
        \\It uses Zig for explicit memory management and provides AI-powered intelligence through plugins.
        \\

    /// Documentation text
    pub const docs_sample =
        \\NorthstarDB is a database built from scratch in Zig, designed for massive read concurrency.
        \\The core components include Pager, B+tree, MVCC snapshots, and the AI Plugin System.
        \\

    /// Mixed content with entities
    pub const mixed_sample =
        \\The system uses Claude Opus 4.5 for intelligent query planning.
        \\Zig 0.15.2 provides the foundation for explicit memory management.
        \\The benchmark harness runs on Linux with NVMe storage.
        \\

    /// Get all sample texts
    pub fn getAll() []const []const u8 {
        return &[_][]const u8{
            code_sample,
            docs_sample,
            mixed_sample,
        };
    }

    /// Get sample by name
    pub fn getByName(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "code")) return code_sample;
        if (std.mem.eql(u8, name, "docs")) return docs_sample;
        if (std.mem.eql(u8, name, "mixed")) return mixed_sample;
        return null;
    }
};

/// Expected entity extraction results
pub const ExpectedEntities = struct {
    pub const Entity = struct {
        name: []const u8,
        type_name: []const u8,
        confidence: f32,
    };

    /// Entities expected from code_sample
    pub const code_entities = [_]Entity{
        .{ .name = "Claude Code", .type_name = "Tool", .confidence = 0.95 },
        .{ .name = "Zig", .type_name = "Language", .confidence = 1.0 },
        .{ .name = "plugins", .type_name = "Component", .confidence = 0.9 },
    };

    /// Entities expected from docs_sample
    pub const docs_entities = [_]Entity{
        .{ .name = "NorthstarDB", .type_name = "Database", .confidence = 1.0 },
        .{ .name = "Zig", .type_name = "Language", .confidence = 1.0 },
        .{ .name = "Pager", .type_name = "Component", .confidence = 0.95 },
        .{ .name = "B+tree", .type_name = "Component", .confidence = 0.95 },
        .{ .name = "MVCC", .type_name = "Concept", .confidence = 0.95 },
    };

    /// Entities expected from mixed_sample
    pub const mixed_entities = [_]Entity{
        .{ .name = "Claude Opus 4.5", .type_name = "Model", .confidence = 0.95 },
        .{ .name = "Zig 0.15.2", .type_name = "Language", .confidence = 1.0 },
        .{ .name = "Linux", .type_name = "OS", .confidence = 1.0 },
        .{ .name = "NVMe", .type_name = "Storage", .confidence = 0.95 },
    };
};

/// Mock function schemas for entity extraction
pub const EntitySchemas = struct {
    /// Create entity extraction function schema
    pub fn createExtractionSchema(allocator: std.mem.Allocator) !llm_function.FunctionSchema {
        var params = llm_function.JSONSchema.init(.object);
        errdefer params.deinit(allocator);

        try params.setDescription(allocator, "Text content to extract entities from");

        var text_prop = llm_function.JSONSchema.init(.string);
        try text_prop.setDescription(allocator, "The text content");
        try params.setProperty(allocator, "text", text_prop);

        return llm_function.FunctionSchema.init(
            allocator,
            "extract_entities",
            "Extract named entities from text and classify them by type",
            params
        );
    }

    /// Create topic classification function schema
    pub fn createTopicSchema(allocator: std.mem.Allocator) !llm_function.FunctionSchema {
        var params = llm_function.JSONSchema.init(.object);
        errdefer params.deinit(allocator);

        try params.setDescription(allocator, "Content to classify into topics");

        var content_prop = llm_function.JSONSchema.init(.string);
        try content_prop.setDescription(allocator, "The content to classify");
        try params.setProperty(allocator, "content", content_prop);

        return llm_function.FunctionSchema.init(
            allocator,
            "classify_topics",
            "Classify content into topic categories",
            params
        );
    }

    /// Create relationship extraction function schema
    pub fn createRelationshipSchema(allocator: std.mem.Allocator) !llm_function.FunctionSchema {
        var params = llm_function.JSONSchema.init(.object);
        errdefer params.deinit(allocator);

        try params.setDescription(allocator, "Text to extract relationships from");

        var text_prop = llm_function.JSONSchema.init(.string);
        try text_prop.setDescription(allocator, "The text content");
        try params.setProperty(allocator, "text", text_prop);

        return llm_function.FunctionSchema.init(
            allocator,
            "extract_relationships",
            "Extract relationships between entities in text",
            params
        );
    }
};

/// Plugin configurations for testing
pub const TestPluginConfigs = struct {
    /// Standard development configuration
    pub fn developmentConfig() manager.PluginConfig {
        return .{
            .llm_provider = .{
                .provider_type = "local",
                .model = "test-model",
                .api_key = null,
                .endpoint = null,
            },
            .fallback_on_error = true,
            .performance_isolation = false,
            .max_llm_latency_ms = 5000,
            .cost_budget_per_hour = 0.0,
        };
    }

    /// Production configuration
    pub fn productionConfig(api_key: []const u8) manager.PluginConfig {
        return .{
            .llm_provider = .{
                .provider_type = "openai",
                .model = "gpt-4o",
                .api_key = api_key,
                .endpoint = null,
            },
            .fallback_on_error = false,
            .performance_isolation = true,
            .max_llm_latency_ms = 10000,
            .cost_budget_per_hour = 50.0,
        };
    }

    /// High-throughput configuration
    pub fn highThroughputConfig(api_key: []const u8) manager.PluginConfig {
        return .{
            .llm_provider = .{
                .provider_type = "anthropic",
                .model = "claude-3-5-sonnet-20241022",
                .api_key = api_key,
                .endpoint = null,
            },
            .fallback_on_error = true,
            .performance_isolation = true,
            .max_llm_latency_ms = 3000,
            .cost_budget_per_hour = 100.0,
        };
    }
};

/// Test scenarios for entity extraction
pub const ExtractionScenarios = struct {
    pub const Scenario = struct {
        name: []const u8,
        input_text: []const u8,
        expected_min_entities: usize,
        timeout_ms: u64,
    };

    /// Basic entity extraction scenario
    pub const basic = Scenario{
        .name = "basic_extraction",
        .input_text = "Zig is a programming language used for systems programming.",
        .expected_min_entities = 2,
        .timeout_ms = 5000,
    };

    /// Complex technical text scenario
    pub const technical = Scenario{
        .name = "technical_extraction",
        .input_text = SampleTexts.code_sample,
        .expected_min_entities = 3,
        .timeout_ms = 10000,
    };

    /// Multi-paragraph scenario
    pub const multi_paragraph = Scenario{
        .name = "multi_paragraph_extraction",
        .input_text = SampleTexts.mixed_sample,
        .expected_min_entities = 4,
        .timeout_ms = 10000,
    };

    /// Get all scenarios
    pub fn getAll() []const Scenario {
        return &[_]Scenario{
            basic,
            technical,
            multi_paragraph,
        };
    }
};

/// Performance benchmarks for entity extraction
pub const PerformanceBenchmarks = struct {
    pub const BenchmarkTarget = struct {
        name: []const u8,
        max_latency_ms: u64,
        min_accuracy: f32,
        max_tokens_per_call: u32,
    };

    /// Fast extraction targets (for high-throughput scenarios)
    pub const fast = BenchmarkTarget{
        .name = "fast_extraction",
        .max_latency_ms = 2000,
        .min_accuracy = 0.8,
        .max_tokens_per_call = 500,
    };

    /// Accurate extraction targets (for quality-focused scenarios)
    pub const accurate = BenchmarkTarget{
        .name = "accurate_extraction",
        .max_latency_ms = 10000,
        .min_accuracy = 0.95,
        .max_tokens_per_call = 2000,
    };

    /// Balanced extraction targets
    pub const balanced = BenchmarkTarget{
        .name = "balanced_extraction",
        .max_latency_ms = 5000,
        .min_accuracy = 0.9,
        .max_tokens_per_call = 1000,
    };
};

/// Validation utilities for entity extraction results
pub const ExtractionValidation = struct {
    /// Validate extracted entities against expected results
    pub fn validateEntities(
        extracted: []const ExpectedEntities.Entity,
        expected: []const ExpectedEntities.Entity,
        allocator: std.mem.Allocator
    ) !ValidationResult {
        var errors = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (errors.items) |err| allocator.free(err);
            errors.deinit();
        }

        var found_count: usize = 0;

        for (expected) |exp_entity| {
            var found = false;
            for (extracted) |ext_entity| {
                if (std.mem.eql(u8, exp_entity.name, ext_entity.name) and
                    std.mem.eql(u8, exp_entity.type_name, ext_entity.type_name))
                {
                    found = true;
                    found_count += 1;
                    break;
                }
            }

            if (!found) {
                try errors.append(try std.fmt.allocPrint(
                    allocator,
                    "Missing entity: {s} ({s})",
                    .{ exp_entity.name, exp_entity.type_name }
                ));
            }
        }

        const recall = if (expected.len > 0)
            @as(f32, @floatFromInt(found_count)) / @as(f32, @floatFromInt(expected.len))
        else
            1.0;

        return ValidationResult{
            .passed = errors.items.len == 0,
            .recall = recall,
            .found_count = found_count,
            .expected_count = expected.len,
            .extracted_count = extracted.len,
        };
    }

    pub const ValidationResult = struct {
        passed: bool,
        recall: f32,
        found_count: usize,
        expected_count: usize,
        extracted_count: usize,
    };
};

test "sample_texts_access" {
    const code = SampleTexts.getByName("code");
    try std.testing.expect(code != null);
    try std.testing.expect(code.?.len > 0);

    const invalid = SampleTexts.getByName("invalid");
    try std.testing.expect(invalid == null);
}

test "entity_schema_creation" {
    var schema = try EntitySchemas.createExtractionSchema(std.testing.allocator);
    defer schema.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("extract_entities", schema.name);
    try std.testing.expectEqualStrings("Extract named entities from text and classify them by type", schema.description);
}

test "extraction_validation" {
    const extracted = [_]ExpectedEntities.Entity{
        .{ .name = "Zig", .type_name = "Language", .confidence = 1.0 },
    };

    const expected = [_]ExpectedEntities.Entity{
        .{ .name = "Zig", .type_name = "Language", .confidence = 1.0 },
        .{ .name = "NorthstarDB", .type_name = "Database", .confidence = 1.0 },
    };

    const result = try ExtractionValidation.validateEntities(&extracted, &expected, std.testing.allocator);

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(usize, 1), result.found_count);
    try std.testing.expectEqual(@as(usize, 2), result.expected_count);
}

test "test_plugin_configs" {
    const dev = TestPluginConfigs.developmentConfig();
    try std.testing.expect(dev.performance_isolation == false);
    try std.testing.expect(dev.fallback_on_error == true);

    const prod = TestPluginConfigs.productionConfig("test-key");
    try std.testing.expect(prod.performance_isolation == true);
    try std.testing.expect(prod.fallback_on_error == false);
}
