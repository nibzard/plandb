//! Entity Extractor Plugin Example
//!
//! This example demonstrates how to create a plugin that extracts structured entities
//! from database mutations using LLM function calling according to ai_plugins_v1.md

const std = @import("std");
const plugins = @import("../../../src/plugins/manager.zig");
const llm = @import("../../../src/llm/client.zig");

/// Entity Extractor Plugin
///
/// This plugin automatically extracts entities, topics, and relationships from
/// database mutations and stores them in structured memory cartridges.
pub const EntityExtractorPlugin = struct {
    const Self = @This();

    name: []const u8 = "entity_extractor",
    version: []const u8 = "1.0.0",
    llm_client: ?*llm.client.LLMProvider = null,
    entity_cartridge: ?*EntityCartridge = null,

    // Plugin interface implementation
    pub const PluginInterface = plugins.Plugin{
        .name = Self.name,
        .version = Self.version,
        .init = Self.init,
        .on_commit = Self.on_commit,
        .on_query = null, // This plugin doesn't handle queries
        .on_schedule = null, // This plugin doesn't do scheduled maintenance
        .cleanup = Self.cleanup,
    };

    pub fn init(config: plugins.PluginConfig) !void {
        std.log.info("Initializing Entity Extractor Plugin v{s}", .{Self.version});

        // Initialize LLM client from configuration
        // In a real implementation, this would use the config to create the appropriate client
        std.log.info("  LLM Provider: {s}", .{config.llm_provider.provider_type});
        std.log.info("  Model: {s}", .{config.llm_provider.model});

        // Initialize entity cartridge for storing extracted entities
        const entity_cartridge = try EntityCartridge.init(std.heap.page_allocator);
        // In real implementation, store this in the plugin instance
        _ = entity_cartridge;
    }

    pub fn on_commit(ctx: plugins.CommitContext) !plugins.PluginResult {
        std.log.info("Processing commit {} with {} mutations", .{ ctx.txn_id, ctx.mutations.len });

        var entities_extracted: usize = 0;
        var total_confidence: f32 = 0.0;

        // Process each mutation in the transaction
        for (ctx.mutations) |mutation| {
            std.log.debug("  Processing mutation: {}", .{mutation});

            // Extract entities from this mutation
            const extraction_result = try extract_entities_from_mutation(mutation);

            // Store extracted entities
            for (extraction_result.entities) |entity| {
                try store_entity_in_cartridge(entity, ctx.txn_id);
                entities_extracted += 1;
                total_confidence += entity.confidence;
            }

            // Store extracted topics
            for (extraction_result.topics) |topic| {
                try store_topic_in_cartridge(topic, ctx.txn_id);
            }

            // Store extracted relationships
            for (extraction_result.relationships) |relationship| {
                try store_relationship_in_cartridge(relationship, ctx.txn_id);
            }
        }

        const avg_confidence = if (entities_extracted > 0)
            total_confidence / @intToFloat(f32, entities_extracted)
        else
            0.0;

        std.log.info("  Extracted {} entities (avg confidence: {d:.2})", .{ entities_extracted, avg_confidence });

        return plugins.PluginResult{
            .success = true,
            .operations_processed = ctx.mutations.len,
            .cartridges_updated = 3, // entity, topic, and relationship cartridges
            .confidence = avg_confidence,
        };
    }

    pub fn cleanup() !void {
        std.log.info("Cleaning up Entity Extractor Plugin");
        // In real implementation, clean up resources here
    }

    // Helper function to extract entities from a single mutation
    fn extract_entities_from_mutation(mutation: Mutation) !ExtractionResult {
        // Create function call schema for entity extraction
        const function_schema = llm.client.FunctionSchema{
            .name = "extract_entities_and_topics",
            .description = "Extract structured entities, topics, and relationships from database mutations",
            .parameters = .{
                .type = .object,
                .properties = .{
                    .mutation = .{
                        .type = "object",
                        .description = "The database mutation to analyze",
                        .properties = .{
                            .operation = .{ .type = "string" },
                            .key = .{ .type = "string" },
                            .value = .{ .type = "string" },
                        },
                    },
                    .context = .{
                        .type = "string",
                        .description = "Context about the database operation",
                    },
                    .focus_areas = .{
                        .type = "array",
                        .items = .{ .type = "string" },
                        .description = "Specific areas to focus on (e.g., 'files', 'users', 'configuration')",
                    },
                },
                .required = &[_][]const u8{"mutation"},
            },
        };

        // Prepare parameters for the function call
        const params = llm.client.Value{
            .mutation = .{
                .operation = mutation.operation.toString(),
                .key = mutation.key,
                .value = mutation.value orelse "",
            },
            .context = "database key-value operation",
            .focus_areas = &[_]llm.client.Value{
                .{ .string = "entity identification" },
                .{ .string = "topic classification" },
                .{ .string = "relationship extraction" },
            },
        };

        // In a real implementation, this would call the actual LLM
        // For now, return a mock result
        return mock_extraction_result(mutation);
    }

    // Mock extraction result for demonstration
    fn mock_extraction_result(mutation: Mutation) !ExtractionResult {
        var entities = std.ArrayList(Entity).init(std.heap.page_allocator);
        var topics = std.ArrayList(Topic).init(std.heap.page_allocator);
        var relationships = std.ArrayList(Relationship).init(std.heap.page_allocator);

        // Extract entity based on key pattern
        if (std.mem.startsWith(u8, mutation.key, "file:")) {
            try entities.append(.{
                .id = EntityId{
                    .namespace = "file",
                    .local_id = mutation.key["file:".len..],
                },
                .type = .file,
                .attributes = std.StringHashMap(AttributeValue).init(std.heap.page_allocator),
                .confidence = 0.95,
            });

            try topics.append(.{
                .term = "filesystem",
                .confidence = 0.8,
            });

            try topics.append(.{
                .term = extract_file_extension(mutation.key),
                .confidence = 0.9,
            });
        }

        if (std.mem.startsWith(u8, mutation.key, "user:")) {
            try entities.append(.{
                .id = EntityId{
                    .namespace = "user",
                    .local_id = mutation.key["user:".len..],
                },
                .type = .person,
                .attributes = std.StringHashMap(AttributeValue).init(std.heap.page_allocator),
                .confidence = 0.9,
            });

            try topics.append(.{
                .term = "user_management",
                .confidence = 0.85,
            });
        }

        if (std.mem.startsWith(u8, mutation.key, "config:")) {
            try entities.append(.{
                .id = EntityId{
                    .namespace = "configuration",
                    .local_id = mutation.key["config:".len..],
                },
                .type = .topic,
                .attributes = std.StringHashMap(AttributeValue).init(std.heap.page_allocator),
                .confidence = 0.88,
            });

            try topics.append(.{
                .term = "settings",
                .confidence = 0.92,
            });
        }

        return ExtractionResult{
            .entities = entities.toOwnedSlice(),
            .topics = topics.toOwnedSlice(),
            .relationships = relationships.toOwnedSlice(),
            .confidence = 0.87,
        };
    }

    fn extract_file_extension(key: []const u8) []const u8 {
        if (std.mem.lastIndexOf(u8, key, '.')) |dot_index| {
            return key[dot_index + 1..];
        }
        return "unknown";
    }

    fn store_entity_in_cartridge(entity: Entity, txn_id: u64) !void {
        std.log.debug("    Storing entity: {s} ({s})", .{ entity.id.toString(), @tagName(entity.type) });
        // In real implementation, this would store in the entity cartridge
        _ = entity;
        _ = txn_id;
    }

    fn store_topic_in_cartridge(topic: Topic, txn_id: u64) !void {
        std.log.debug("    Storing topic: {s} (confidence: {d:.2})", .{ topic.term, topic.confidence });
        // In real implementation, this would store in the topic cartridge
        _ = topic;
        _ = txn_id;
    }

    fn store_relationship_in_cartridge(relationship: Relationship, txn_id: u64) !void {
        std.log.debug("    Storing relationship: {s} -> {s}", .{ relationship.source.toString(), relationship.target.toString() });
        // In real implementation, this would store in the relationship cartridge
        _ = relationship;
        _ = txn_id;
    }
};

// Supporting type definitions (simplified for example)
const Mutation = struct {
    operation: Operation,
    key: []const u8,
    value: ?[]const u8,

    pub fn toString(self: Mutation) []const u8 {
        return switch (self.operation) {
            .put => "PUT",
            .delete => "DELETE",
        };
    }

    pub const Operation = enum {
        put,
        delete,
    };
};

const EntityId = struct {
    namespace: []const u8,
    local_id: []const u8,

    pub fn toString(self: EntityId) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}:{s}", .{ self.namespace, self.local_id }) catch "";
    }
};

const EntityType = enum {
    file,
    person,
    topic,
    organization,
    custom,
};

const Entity = struct {
    id: EntityId,
    type: EntityType,
    attributes: std.StringHashMap(AttributeValue),
    confidence: f32,
};

const Topic = struct {
    term: []const u8,
    confidence: f32,
    entities: []EntityId, // Entities that mention this topic
};

const Relationship = struct {
    source: EntityId,
    target: EntityId,
    type: RelationshipType,
    confidence: f32,
};

const RelationshipType = enum {
    contains,
    references,
    depends_on,
    belongs_to,
    custom,
};

const AttributeValue = union {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

const ExtractionResult = struct {
    entities: []Entity,
    topics: []Topic,
    relationships: []Relationship,
    confidence: f32,
};

const EntityCartridge = struct {
    pub fn init(allocator: std.mem.Allocator) !EntityCartridge {
        _ = allocator;
        return error.NotImplemented;
    }
};

/// Demonstration of using the Entity Extractor Plugin
pub fn demonstrate_entity_extractor() !void {
    std.debug.print("Entity Extractor Plugin Demonstration\n");
    std.debug.print("===================================\n\n");

    // Create plugin configuration
    const config = plugins.PluginConfig{
        .llm_provider = .{
            .provider_type = "openai",
            .model = "gpt-4-turbo",
            .api_key = "your-api-key-here",
        },
        .fallback_on_error = true,
        .performance_isolation = true,
        .max_llm_latency_ms = 5000,
        .cost_budget_per_hour = 10.0,
    };

    // Initialize the plugin
    try EntityExtractorPlugin.init(config);

    // Create mock commit context
    const mutations = [_]Mutation{
        .{
            .operation = .put,
            .key = "file:src/main.zig",
            .value = "const x = 42;",
        },
        .{
            .operation = .put,
            .key = "user:alice",
            .value = "alice@example.com",
        },
        .{
            .operation = .put,
            .key = "config:theme",
            .value = "dark",
        },
        .{
            .operation = .delete,
            .key = "file:temp.tmp",
            .value = null,
        },
    };

    const ctx = plugins.CommitContext{
        .txn_id = 12345,
        .mutations = &mutations,
        .timestamp = std.time.timestamp(),
        .metadata = std.StringHashMap([]const u8).init(std.heap.page_allocator),
    };

    // Process the commit
    const result = try EntityExtractorPlugin.on_commit(ctx);

    std.debug.print("Plugin Execution Results:\n");
    std.debug.print("  Success: {}\n", .{result.success});
    std.debug.print("  Operations Processed: {}\n", .{result.operations_processed});
    std.debug.print("  Cartridges Updated: {}\n", .{result.cartridges_updated});
    std.debug.print("  Average Confidence: {d:.2}\n", .{result.confidence});

    // Cleanup
    try EntityExtractorPlugin.cleanup();
}

/// Integration test demonstrating the plugin in a realistic scenario
pub fn integration_test() !void {
    std.debug.print("\nIntegration Test\n");
    std.debug.print("================\n");

    // This would normally be called by the plugin manager
    // when the database processes commits

    const real_world_mutations = [_]Mutation{
        .{ .operation = .put, .key = "file:src/db.zig", .value = "pub const Db = struct { ... };" },
        .{ .operation = .put, .key = "file:src/pager.zig", .value = "pub const Pager = struct { ... };" },
        .{ .operation = .put, .key = "user:developer", .value = "dev@example.com" },
        .{ .operation = .put, .key = "config:database.path", .value = "/var/lib/northstar" },
        .{ .operation = .put, .key = "config:database.size", .value = "1GB" },
    };

    std.debug.print("Processing realistic commit with {} mutations:\n", .{real_world_mutations.len});

    for (real_world_mutations) |mutation| {
        std.debug.print("  {s} {s}\n", .{ mutation.toString(), mutation.key });

        const extraction_result = try EntityExtractorPlugin.mock_extraction_result(mutation);

        std.debug.print("    Extracted {} entities:\n", .{extraction_result.entities.len});
        for (extraction_result.entities) |entity| {
            std.debug.print("      - {s} ({s})\n", .{ entity.id.toString(), @tagName(entity.type) });
        }

        std.debug.print("    Extracted {} topics:\n", .{extraction_result.topics.len});
        for (extraction_result.topics) |topic| {
            std.debug.print("      - {s} (confidence: {d:.2})\n", .{ topic.term, topic.confidence });
        }
    }
}

test "entity_extractor_plugin" {
    // Test basic plugin functionality
    const config = plugins.PluginConfig{
        .llm_provider = .{
            .provider_type = "test",
            .model = "test-model",
        },
        .fallback_on_error = true,
        .performance_isolation = true,
    };

    // Test plugin initialization
    try EntityExtractorPlugin.init(config);

    // Test mock extraction
    const test_mutation = Mutation{
        .operation = .put,
        .key = "file:src/test.zig",
        .value = "const test = true;",
    };

    const result = try EntityExtractorPlugin.mock_extraction_result(test_mutation);
    try std.testing.expect(result.entities.len > 0);
    try std.testing.expect(EntityType.file == result.entities[0].type);
    try std.testing.expect(result.confidence > 0.5);

    // Test cleanup
    try EntityExtractorPlugin.cleanup();
}