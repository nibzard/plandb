# AI Development Guide

This guide covers developing AI intelligence features for NorthstarDB's Living Database capabilities.

## Overview

NorthstarDB's AI intelligence layer enables:
- **Structured Memory Extraction**: Automatically extract entities, topics, and relationships
- **Natural Language Queries**: Query by intent instead of syntax
- **Autonomous Optimization**: Database self-maintenance and performance tuning
- **Plugin Ecosystem**: Extensible AI functions for domain-specific intelligence

## Architecture Overview

```
Commit Stream → AI Plugin System → Structured Memory Cartridges → Intelligent Queries
```

### Key Components

1. **LLM Client** (`src/llm/`) - Provider-agnostic interface
2. **Plugin System** (`src/plugins/`) - Lifecycle management and hooks
3. **Structured Memory** (`src/cartridges/`) - Entity/topic/relationship storage
4. **Query Processing** (`src/queries/`) - Natural language to structured queries

## Getting Started with AI Development

### Prerequisites

- Basic understanding of Zig programming language
- Familiarity with database concepts
- API access to LLM provider (OpenAI, Anthropic, or local models)

### Development Environment

```bash
# Clone and build
git clone https://github.com/your-org/northstar-db.git
cd northstar-db
zig build
zig build test
```

### Configuration

Create `ai_config.json`:

```json
{
  "plugins": [
    {
      "name": "entity_extractor",
      "enabled": true,
      "config": {
        "llm_provider": "openai",
        "model": "gpt-4-turbo",
        "confidence_threshold": 0.8
      }
    }
  ],
  "llm_providers": {
    "openai": {
      "api_key": "your-openai-api-key",
      "model": "gpt-4-turbo",
      "base_url": "https://api.openai.com/v1"
    }
  }
}
```

## Plugin Development

### Basic Plugin Structure

```zig
const std = @import("std");
const plugins = @import("../plugins/manager.zig");

pub const MyAIClientPlugin = struct {
    name: []const u8 = "my_ai_client",
    version: []const u8 = "1.0.0",

    // Plugin lifecycle
    pub fn init(config: plugins.PluginConfig) !void {
        // Initialize plugin with configuration
        _ = config;
        std.log.info("Initializing {s} plugin", .{MyAIClientPlugin.name});
    }

    pub fn on_commit(ctx: plugins.CommitContext) !plugins.PluginResult {
        // Process database commits
        std.log.info("Processing commit {any}", .{ctx.txn_id});

        // Extract entities from mutations
        for (ctx.mutations) |mutation| {
            const entities = try extract_entities(mutation);
            try store_entities(entities);
        }

        return plugins.PluginResult{
            .success = true,
            .operations_processed = ctx.mutations.len,
            .cartridges_updated = 1,
            .confidence = 0.95,
        };
    }

    pub fn cleanup() !void {
        std.log.info("Cleaning up {s} plugin", .{MyAIClientPlugin.name});
    }

    // Helper functions
    fn extract_entities(mutation: Mutation) ![]Entity {
        _ = mutation;
        return error.NotImplemented; // Implement your logic
    }

    fn store_entities(entities: []Entity) !void {
        _ = entities;
        return error.NotImplemented; // Implement your logic
    }
};

// Plugin registration
const plugin_interface = plugins.Plugin{
    .name = MyAIClientPlugin.name,
    .version = MyAIClientPlugin.version,
    .init = MyAIClientPlugin.init,
    .on_commit = MyAIClientPlugin.on_commit,
    .cleanup = MyAIClientPlugin.cleanup,
};
```

### Entity Extraction Plugin

```zig
pub const EntityExtractorPlugin = struct {
    llm_client: *llm.client.LLMProvider,

    pub fn init(config: plugins.PluginConfig) !void {
        // Initialize LLM client
        llm_client = try createLLMClient(config);
    }

    pub fn on_commit(ctx: plugins.CommitContext) !plugins.PluginResult {
        var entities_extracted: usize = 0;

        for (ctx.mutations) |mutation| {
            // Call LLM to extract entities
            const function_call = llm.client.FunctionSchema{
                .name = "extract_entities_and_topics",
                .description = "Extract structured entities from database mutations",
                .parameters = .{
                    .type = .object,
                    .properties = .{
                        .mutations = .{
                            .type = .array,
                            .items = .{ .type = "object" },
                        },
                        .context = .{
                            .type = "string",
                            .description = "Database operation context",
                        },
                    },
                },
            };

            const params = llm.client.Value{
                .mutations = mutation,
                .context = "database schema changes",
            };

            const result = try llm_client.call_function(function_call, params);
            entities_extracted += result.entities.len;

            // Store extracted entities in structured memory cartridges
            try store_extracted_entities(result.entities);
        }

        return plugins.PluginResult{
            .success = true,
            .operations_processed = ctx.mutations.len,
            .cartridges_updated = entities_extracted,
            .confidence = calculate_average_confidence(ctx.mutations),
        };
    }
};
```

### Query Optimization Plugin

```zig
pub const QueryOptimizerPlugin = struct {
    pub fn on_query(ctx: plugins.QueryContext) !plugins.QueryPlan {
        // Analyze natural language query
        const intent = analyze_query_intent(ctx.query);

        // Generate optimal execution plan
        const plan = plugins.QueryPlan{
            .primary_intent = intent,
            .entity_queries = generate_entity_queries(ctx, intent),
            .topic_queries = generate_topic_queries(ctx, intent),
            .relationship_queries = generate_relationship_queries(ctx, intent),
        };

        // Apply optimizations based on available cartridges
        try optimize_for_available_cartridges(&plan, ctx.available_cartridges);

        // Apply performance constraints
        try apply_performance_constraints(&plan, ctx.performance_constraints);

        return plan;
    }

    fn analyze_query_intent(query: []const u8) QueryIntent {
        // Use keyword analysis or LLM for intent classification
        if (std.mem.indexOf(u8, query, "what")) |_| {
            return .entity_lookup;
        }
        if (std.mem.indexOf(u8, query, "find")) |_| {
            return .relationship_traversal;
        }
        return .entity_lookup; // Default
    }
};
```

## Structured Memory Development

### Entity Cartridge Operations

```zig
const cartridges = @import("../cartridges/entity.zig");

pub fn demonstrate_entity_operations() !void {
    var gpa = std.heap.page_allocator;
    var cartridge = try cartridges.EntityCartridge.init(gpa);
    defer cartridge.deinit();

    // Add entities
    const file_entity = cartridges.EntityId{
        .namespace = "file",
        .local_id = "src/main.zig",
    };

    const attributes = [_]cartridges.Attribute{
        .{
            .key = "size",
            .value = .{ .integer = 1024 },
            .confidence = 1.0,
            .source = "filesystem",
        },
        .{
            .key = "language",
            .value = .{ .string = "zig" },
            .confidence = 0.95,
            .source = "file_extension",
        },
    };

    try cartridge.add_entity(file_entity, .file, &attributes, 12345);

    // Query entities
    const filters = [_]cartridges.AttributeFilter{
        .{
            .key = "language",
            .operator = .equals,
            .value = .{ .string = "zig" },
        },
    };

    var iterator = cartridge.query_entities(.file, &filters);
    while (iterator.next()) |entity_id| {
        const entity = cartridge.get_entity(entity_id).?;
        std.debug.print("Found entity: {s}\n", .{entity_id.local_id});
    }
}
```

### Topic Index Operations

```zig
// Topic cartridge for semantic search
pub fn demonstrate_topic_indexing() !void {
    var gpa = std.heap.page_allocator;
    var topic_cartridge = try TopicCartridge.init(gpa);
    defer topic_cartridge.deinit();

    // Add documents with topics
    const doc1 = EntityId{ .namespace = "doc", .local_id = "design_doc" };
    const doc2 = EntityId{ .namespace = "doc", .local_id = "api_reference" };

    // Index terms from documents
    const doc1_terms = [_]TermFrequency{
        .{ .term = "database", .frequency = 5 },
        .{ .term = "performance", .frequency = 3 },
        .{ .term = "zig", .frequency = 4 },
    };

    const doc2_terms = [_]TermFrequency{
        .{ .term = "api", .frequency = 6 },
        .{ .term = "function", .frequency = 4 },
        .{ .term = "zig", .frequency = 2 },
    };

    try topic_cartridge.add_entity_terms(doc1, &doc1_terms, 100);
    try topic_cartridge.add_entity_terms(doc2, &doc2_terms, 101);

    // Search by topic
    const query = TopicQuery{
        .terms = &[_]QueryTerm{
            .{ .term = "zig", .boost = 1.0 },
            .{ .term = "performance", .boost = 1.5 },
        },
        .operators = &[_]QueryOperator{ .and },
    };

    const results = try topic_cartridge.search_entities_by_topic(query, 10);
    for (results) |result| {
        std.debug.print("Found: {s} (score: {d:.2})\n", .{ result.entity.id.local_id, result.score });
    }
}
```

## Natural Language Query Development

### Query Processing Pipeline

```zig
const queries = @import("../queries/natural_language.zig");

pub fn demonstrate_natural_language_queries() !void {
    var gpa = std.heap.page_allocator;

    // Initialize NLP processor with LLM client
    var llm_client = try create_test_llm_client();
    var nlp = try queries.NaturalLanguageProcessor.init(gpa, &llm_client);
    defer nlp.deinit();

    // Define query context
    const context = queries.QueryContext{
        .available_cartridges = &[_]CartridgeType{ .entity, .topic, .relationship },
        .performance_constraints = .{
            .max_latency_ms = 1000,
            .max_cost = 0.10,
            .prefer_accuracy = true,
        },
    };

    // Process natural language queries
    const queries_to_process = [_][]const u8{
        "What files are related to database performance?",
        "Show me all zig files larger than 1KB",
        "Find the person who modified the btree implementation",
    };

    for (queries_to_process) |query| {
        std.debug.print("Processing: {s}\n", .{query});

        const result = try nlp.process_query(query, context);

        std.debug.print("Results:\n");
        for (result.primary_results) |primary| {
            std.debug.print("  - {s}\n", .{primary.data});
        }

        for (result.semantic_results) |semantic| {
            std.debug.print("  - Semantic: {s} (similarity: {d:.2})\n", .{
                semantic.entity,
                semantic.semantic_similarity
            });
        }
    }
}
```

## Testing AI Features

### Unit Testing for Plugins

```zig
test "entity_extractor_plugin" {
    const config = PluginConfig{
        .llm_provider = .{
            .provider_type = "test",
            .model = "test-model",
        },
    };

    var plugin = EntityExtractorPlugin{};
    try plugin.init(config);

    const test_mutations = [_]Mutation{
        .{
            .operation = .put,
            .key = "file:main.zig",
            .value = "const x = 42;",
        },
    };

    const ctx = CommitContext{
        .txn_id = 12345,
        .mutations = &test_mutations,
        .timestamp = std.time.timestamp(),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    };

    const result = try plugin.on_commit(ctx);
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.operations_processed);
}

test "natural_language_processing" {
    const test_llm_client = create_mock_llm_client();
    var nlp = try NaturalLanguageProcessor.init(std.testing.allocator, &test_llm_client);
    defer nlp.deinit();

    const context = QueryContext{
        .available_cartridges = &[_]CartridgeType{},
        .performance_constraints = .{
            .max_latency_ms = 1000,
            .max_cost = 0.01,
            .prefer_accuracy = false,
        },
    };

    const result = try nlp.process_query("find all files", context);
    try testing.expect(result.primary_results.len > 0);
}
```

### Integration Testing

```zig
test "ai_pipeline_integration" {
    var gpa = std.heap.page_allocator;

    // Set up complete AI pipeline
    var llm_client = try create_test_llm_client();
    var plugin_manager = try PluginManager.init(gpa, test_config);
    defer plugin_manager.deinit();

    // Register test plugins
    try plugin_manager.register_plugin(create_test_plugin());

    // Simulate database operations with AI processing
    var db = try Db.open(gpa);
    defer db.close();

    var wtxn = try db.beginWrite();
    try wtxn.put("test:file", "test content");
    const txn_id = try wtxn.commit();

    // Verify AI processing occurred
    const rtxn = try db.beginReadLatest();
    defer rtxn.close();

    // Check that entities were extracted and stored
    const entity = rtxn.get_entity("file:test_file");
    try testing.expect(entity != null);
}
```

## Performance Considerations

### Caching Strategies

```zig
pub const CachingLLMClient = struct {
    base_client: llm.client.LLMProvider,
    cache: std.StringHashMap(FunctionResult),
    cache_ttl: u64,

    pub fn call_function(
        self: *CachingLLMClient,
        schema: llm.client.FunctionSchema,
        params: llm.client.Value
    ) !llm.client.FunctionResult {
        // Generate cache key
        const cache_key = try generate_cache_key(schema, params);

        // Check cache first
        if (self.cache.get(cache_key)) |cached_result| {
            if (!is_expired(cached_result.timestamp, self.cache_ttl)) {
                return cached_result.result;
            }
        }

        // Call actual function
        const result = try self.base_client.call_function(schema, params);

        // Cache the result
        try self.cache.put(cache_key, .{
            .result = result,
            .timestamp = std.time.timestamp(),
        });

        return result;
    }
};
```

### Batching Operations

```zig
pub const BatchProcessor = struct {
    batch_size: usize,
    pending_operations: std.ArrayList(Operation),
    llm_client: llm.client.LLMProvider,

    pub fn add_operation(self: *BatchProcessor, operation: Operation) !void {
        try self.pending_operations.append(operation);

        if (self.pending_operations.items.len >= self.batch_size) {
            try self.flush_batch();
        }
    }

    pub fn flush_batch(self: *BatchProcessor) !void {
        if (self.pending_operations.items.len == 0) return;

        // Combine operations into single LLM call
        const batch_result = try self.process_batch(self.pending_operations.items);

        // Distribute results back to operations
        try self.distribute_results(batch_result);

        self.pending_operations.clear();
    }
};
```

## Debugging AI Features

### Logging and Observability

```zig
pub const AIOperationsLogger = struct {
    operations_log: std.ArrayList(AIOperationLog),

    pub fn log_function_call(
        self: *AIOperationsLogger,
        function_name: []const u8,
        params: llm.client.Value,
        result: llm.client.FunctionResult,
        duration_ms: u64
    ) !void {
        const log_entry = AIOperationLog{
            .timestamp = std.time.timestamp(),
            .operation_type = .function_call,
            .function_name = function_name,
            .input_size = estimate_size(params),
            .output_size = estimate_size(result),
            .duration_ms = duration_ms,
            .success = true,
        };

        try self.operations_log.append(log_entry);
    }

    pub fn analyze_performance(self: *AIOperationsLogger) PerformanceReport {
        var total_duration: u64 = 0;
        var operation_count: usize = 0;
        var error_count: usize = 0;

        for (self.operations_log.items) |log| {
            total_duration += log.duration_ms;
            operation_count += 1;
            if (!log.success) error_count += 1;
        }

        return PerformanceReport{
            .average_latency_ms = @intToFloat(f64, total_duration) / @intToFloat(f64, operation_count),
            .total_operations = operation_count,
            .error_rate = @intToFloat(f64, error_count) / @intToFloat(f64, operation_count),
        };
    }
};
```

## Best Practices

### 1. Error Handling

Always handle AI operation failures gracefully:

```zig
const result = llm_client.call_function(schema, params) catch |err| switch (err) {
    error.LLMTimeout => {
        // Retry with timeout
        return retry_with_timeout(schema, params);
    },
    error.LLMQuotaExceeded => {
        // Fall back to cached results
        return get_cached_result(schema, params);
    },
    else => {
        // Log error and use fallback
        log_error("AI function call failed", err);
        return fallback_operation(schema, params);
    },
};
```

### 2. Resource Management

Implement proper cleanup and resource limits:

```zig
const AIResourceManager = struct {
    max_concurrent_requests: usize,
    active_requests: usize,
    memory_limit_mb: u32,

    pub fn acquire_resource(self: *AIResourceManager) !ResourceToken {
        if (self.active_requests >= self.max_concurrent_requests) {
            return error.ResourceExhausted;
        }

        if (get_memory_usage_mb() > self.memory_limit_mb) {
            return error.MemoryLimitExceeded;
        }

        self.active_requests += 1;
        return ResourceToken{ .id = generate_token_id() };
    }

    pub fn release_resource(self: *AIResourceManager, token: ResourceToken) void {
        _ = token;
        self.active_requests -= 1;
    }
};
```

### 3. Configuration Management

Use structured configuration with defaults:

```zig
const AIConfig = struct {
    llm_provider: LLMProviderConfig,
    plugins: []PluginConfig,
    performance: PerformanceConfig,
    security: SecurityConfig,

    pub fn load_from_file(path: []const u8) !AIConfig {
        const config_file = try std.fs.cwd().openFile(path, .{});
        defer config_file.close();

        const contents = try config_file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024);
        defer std.heap.page_allocator.free(contents);

        return parse_config(contents);
    }

    pub fn with_defaults() AIConfig {
        return AIConfig{
            .llm_provider = .{
                .provider_type = "openai",
                .model = "gpt-4-turbo",
                .timeout_ms = 30000,
            },
            .plugins = &[_]PluginConfig{},
            .performance = .{
                .max_concurrent_requests = 5,
                .cache_ttl_seconds = 3600,
            },
            .security = .{
                .require_https = true,
                .validate_responses = true,
            },
        };
    }
};
```

## Contributing to AI Features

When contributing AI features to NorthstarDB:

1. **Write Tests**: Include comprehensive unit and integration tests
2. **Performance Impact**: Benchmark AI features and ensure they don't degrade database performance
3. **Documentation**: Document new functions and their parameters
4. **Error Handling**: Implement robust error handling and fallbacks
5. **Configuration**: Make features configurable with sensible defaults

### Development Workflow

```bash
# Create feature branch
git checkout -b feature/ai-entity-extraction

# Write tests first
zig test src/ai/entity_extraction.zig

# Implement feature
# Edit src/ai/entity_extraction.zig

# Run full test suite
zig build test

# Run benchmarks
zig build run -- run --suite micro --filter "ai/"

# Submit PR with tests and documentation
git push origin feature/ai-entity-extraction
```

This guide provides a foundation for developing AI intelligence features for NorthstarDB. For more specific examples, see the examples in the `docs/examples/` directory.