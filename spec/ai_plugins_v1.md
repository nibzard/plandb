# AI Plugins v1 Specification

**Version**: 1.0
**Date**: 2025-12-22
**Status**: Draft

## Overview

This specification defines the AI plugin system for NorthstarDB, enabling deterministic AI intelligence through function calling while maintaining provider agnosticism.

## Design Goals

1. **Deterministic Operations**: Function calling over embeddings for predictable results
2. **Provider Agnosticism**: Support OpenAI, Anthropic, and local models interchangeably
3. **Performance Isolation**: AI operations must not degrade core database performance
4. **Graceful Degradation**: Database remains functional when AI services are unavailable
5. **Type Safety**: Strong typing for all AI operations and data exchanges

## Architecture

### Plugin System Components

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Plugin Manager│◄──►│  Function Schema │◄──►│  LLM Providers  │
│   (Lifecycle)    │    │  (Type Safety)    │    │ (OpenAI/Anthropic)│
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Hook System   │    │  Result Cache    │    │  Error Handling  │
│   (Events)      │    │  (Optimization)   │    │  (Fallbacks)     │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

## Plugin Interface

### Plugin Lifecycle

```zig
const PluginLifecycle = struct {
    name: []const u8,
    version: []const u8,
    dependencies: [][]const u8,

    // Lifecycle callbacks
    init: *const fn(config: PluginConfig) anyerror!void,
    on_commit: ?*const fn(ctx: CommitContext) anyerror!PluginResult,
    on_query: ?*const fn(ctx: QueryContext) anyerror!QueryPlan,
    on_schedule: ?*const fn(ctx: ScheduleContext) anyerror!MaintenanceTask,
    cleanup: *const fn() anyerror!void,
};

const CommitContext = struct {
    txn_id: u64,
    mutations: []Mutation,
    timestamp: i64,
    metadata: HashMap([]const u8, []const u8),
};

const QueryContext = struct {
    query: []const u8,
    user_intent: ?QueryIntent,
    available_cartridges: []CartridgeType,
    performance_constraints: QueryConstraints,
};

const ScheduleContext = struct {
    maintenance_window: TimeWindow,
    usage_stats: UsageStatistics,
    resource_limits: ResourceLimits,
};
```

### Function Schema Definition

```zig
const FunctionSchema = struct {
    name: []const u8,
    description: []const u8,
    parameters: JSONSchema,
    returns: JSONSchema,
    examples: []FunctionExample,

    const JSONSchema = struct {
        type: SchemaType,
        properties: HashMap([]const u8, JSONSchema),
        required: [][]const u8,
        additional_properties: bool,
    };

    const FunctionExample = struct {
        input: Value,
        output: Value,
        description: []const u8,
    };
};
```

## Standard Plugin Functions

### Entity Extraction Function

**Function Name**: `extract_entities_and_topics`

**Description**: Extract structured entities and topics from database mutations

**Schema**:
```json
{
  "name": "extract_entities_and_topics",
  "description": "Extract structured entities, topics, and relationships from database mutations",
  "parameters": {
    "type": "object",
    "properties": {
      "mutations": {
        "type": "array",
        "items": {"$ref": "#/definitions/Mutation"},
        "description": "Database mutations to analyze"
      },
      "context": {
        "type": "string",
        "description": "Context information about the operation type"
      },
      "focus_areas": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Specific areas to focus extraction on"
      }
    },
    "required": ["mutations"]
  },
  "returns": {
    "type": "object",
    "properties": {
      "entities": {
        "type": "array",
        "items": {"$ref": "#/definitions/Entity"}
      },
      "topics": {
        "type": "array",
        "items": {"$ref": "#/definitions/Topic"}
      },
      "relationships": {
        "type": "array",
        "items": {"$ref": "#/definitions/Relationship"}
      },
      "confidence": {
        "type": "number",
        "minimum": 0.0,
        "maximum": 1.0
      }
    }
  }
}
```

**Example Usage**:
```zig
const result = try plugin_manager.call_function(
    "extract_entities_and_topics",
    .{
        .mutations = mutations,
        .context = "database schema changes",
        .focus_areas = &[_][]const u8{"performance", "btree"}
    }
);
```

### Query Optimization Function

**Function Name**: `optimize_query_plan`

**Description**: Analyze natural language queries and create optimized execution plans

**Schema**:
```json
{
  "name": "optimize_query_plan",
  "description": "Convert natural language queries to optimized database execution plans",
  "parameters": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "Natural language query to optimize"
      },
      "available_cartridges": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Available structured memory cartridges"
      },
      "performance_constraints": {
        "type": "object",
        "properties": {
          "max_latency_ms": {"type": "number"},
          "max_cost": {"type": "number"},
          "prefer_accuracy": {"type": "boolean"}
        }
      }
    },
    "required": ["query"]
  }
}
```

### Usage Pattern Analysis Function

**Function Name**: `analyze_usage_patterns`

**Description**: Analyze database usage patterns and recommend optimizations

**Schema**:
```json
{
  "name": "analyze_usage_patterns",
  "description": "Analyze usage patterns and recommend autonomous optimizations",
  "parameters": {
    "type": "object",
    "properties": {
      "query_log": {
        "type": "array",
        "items": {"$ref": "#/definitions/QueryLogEntry"},
        "description": "Recent query history"
      },
      "access_patterns": {
        "type": "array",
        "items": {"$ref": "#/definitions/AccessPattern"}
      },
      "performance_metrics": {
        "type": "object",
        "description": "Current performance metrics"
      }
    },
    "required": ["query_log"]
  }
}
```

## LLM Provider Interface

### Provider Abstraction

```zig
const LLMProvider = struct {
    name: []const u8,
    capabilities: ProviderCapabilities,

    // Core interface
    call_function: *const fn(schema: FunctionSchema, params: Value) anyerror!FunctionResult,
    call_function_stream: *const fn(schema: FunctionSchema, params: Value) anyerror!FunctionStream,
    validate_response: *const fn(response: FunctionResult) anyerror!ValidationResult,

    // Provider-specific configuration
    config: ProviderConfig,
};

const ProviderCapabilities = struct {
    max_tokens: u32,
    supports_streaming: bool,
    supports_function_calling: bool,
    supports_parallel_calls: bool,
    pricing_model: PricingModel,
};
```

### OpenAI Provider

```zig
const OpenAIProvider = struct {
    client: HttpClient,
    model: []const u8,
    api_key: []const u8,

    pub fn call_function(provider: *const LLMProvider, schema: FunctionSchema, params: Value) !FunctionResult {
        // Convert schema to OpenAI function calling format
        const openai_functions = try convert_to_openai_functions(schema);

        // Make API call
        const response = try provider.client.post("/chat/completions", .{
            .model = provider.model,
            .messages = @import("std").json.Value{
                .role = "user",
                .content = try format_function_call_prompt(schema, params),
            },
            .functions = openai_functions,
            .function_call = .{"name" = schema.name},
        });

        // Parse and validate response
        return parse_openai_function_response(response);
    }
};
```

### Local Model Provider

```zig
const LocalModelProvider = struct {
    model_path: []const u8,
    runtime: ModelRuntime,

    pub fn call_function(provider: *const LLMProvider, schema: FunctionSchema, params: Value) !FunctionResult {
        // Load local model if not already loaded
        const model = try provider.runtime.load_model(provider.model_path);

        // Format prompt for function calling
        const prompt = try format_local_function_prompt(schema, params);

        // Generate response
        const response = try model.generate(prompt, .{
            .max_tokens = schema.max_tokens,
            .temperature = 0.1, // Low temperature for deterministic results
            .stop_sequences = &[_][]const u8{"</function_call>"}
        });

        // Parse structured response
        return parse_local_function_response(response);
    }
};
```

## Plugin Development

### Plugin Template

```zig
const MyPlugin = struct {
    const PLUGIN_NAME = "my_custom_plugin";
    const PLUGIN_VERSION = "1.0.0";

    var config: PluginConfig = undefined;
    var llm_client: LLMClient = undefined;

    pub fn init(plugin_config: PluginConfig) !void {
        config = plugin_config;
        llm_client = try LLMClient.init(config.llm_provider);
    }

    pub fn on_commit(ctx: CommitContext) !PluginResult {
        // Custom analysis logic
        const analysis = try llm_client.call_function(
            "my_custom_analysis",
            .{
                .mutations = ctx.mutations,
                .context = get_context(ctx),
            }
        );

        // Process results and update cartridges
        try update_custom_cartridges(analysis);

        return PluginResult{
            .success = true,
            .operations_processed = ctx.mutations.len,
            .cartridges_updated = 1,
        };
    }

    pub fn cleanup() !void {
        try llm_client.deinit();
    }
};

// Plugin registration
const plugin_interface = PluginLifecycle{
    .name = MyPlugin.PLUGIN_NAME,
    .version = MyPlugin.PLUGIN_VERSION,
    .init = MyPlugin.init,
    .on_commit = MyPlugin.on_commit,
    .cleanup = MyPlugin.cleanup,
};
```

### Plugin Configuration

```json
{
  "plugins": [
    {
      "name": "entity_extractor",
      "enabled": true,
      "config": {
        "llm_provider": "openai",
        "model": "gpt-4-turbo",
        "batch_size": 100,
        "confidence_threshold": 0.8
      }
    },
    {
      "name": "query_optimizer",
      "enabled": true,
      "config": {
        "llm_provider": "anthropic",
        "model": "claude-3-opus",
        "cache_ttl": 3600,
        "max_concurrent_requests": 5
      }
    }
  ],
  "global_settings": {
    "fallback_on_error": true,
    "performance_isolation": true,
    "max_llm_latency_ms": 5000,
    "cost_budget_per_hour": 10.0
  }
}
```

## Error Handling and Fallbacks

### Error Types

```zig
const PluginError = error{
    // LLM Provider Errors
    LLMProviderUnavailable,
    LLMTimeout,
    LLMQuotaExceeded,
    LLMInvalidResponse,

    // Plugin Execution Errors
    PluginInitializationFailed,
    PluginExecutionFailed,
    InvalidPluginConfiguration,

    // Schema Errors
    InvalidFunctionSchema,
    InvalidParameters,
    SchemaValidationFailed,

    // Performance Errors
    OperationTimeout,
    ResourceExhausted,
    PerformanceIsolationViolation,
};
```

### Fallback Strategies

```zig
const FallbackStrategy = union {
    no_fallback: void,
    cached_result: CachedResult,
    alternative_provider: AlternativeProvider,
    simplified_operation: SimplifiedOperation,
    skip_operation: void,
};

pub fn execute_with_fallback(
    plugin: *const PluginLifecycle,
    operation: Operation,
    fallback: FallbackStrategy
) !Result {
    return operation.execute() catch |err| switch (fallback) {
        .cached_result => |cached| cached.get_result(),
        .alternative_provider => |alt| try execute_with_provider(alt.provider),
        .simplified_operation => |simple| try simple.execute(),
        .skip_operation => Result.skipped,
        .no_fallback => err,
    };
}
```

## Performance Requirements

### Latency Requirements

- **Function Call Latency**: <500ms (including LLM response time)
- **Plugin Initialization**: <5s
- **Fallback Activation**: <100ms
- **Provider Switching**: <200ms

### Throughput Requirements

- **Concurrent Function Calls**: Support 10+ parallel requests
- **Batch Processing**: 100+ operations per batch when possible
- **Cache Hit Rate**: >80% for repetitive queries

### Resource Limits

- **Memory Usage**: <100MB per plugin
- **CPU Usage**: <10% of total system resources
- **Network Bandwidth**: <1MB/s for LLM API calls

## Security Considerations

### Input Validation

- All function parameters validated against JSON schemas
- SQL injection prevention for query functions
- Rate limiting per plugin and per user

### Data Privacy

- Sensitive data filtering before LLM calls
- Option for on-premises LLM providers
- Data anonymization capabilities

### Access Control

- Plugin-specific permissions
- Function-level access control
- Audit logging for all AI operations

## Testing Requirements

### Unit Testing

- Plugin interface compliance tests
- Function schema validation tests
- Error handling and fallback tests

### Integration Testing

- LLM provider compatibility tests
- Performance isolation tests
- End-to-end plugin workflow tests

### Performance Testing

- Latency and throughput benchmarks
- Resource usage monitoring
- Fallback mechanism testing

## Migration and Compatibility

### Version Compatibility

- Plugin API versioning
- Backward compatibility requirements
- Migration path for plugin updates

### Provider Migration

- Export/import plugin configurations
- Zero-downtime provider switching
- Consistent response format across providers

---

## Implementation Status

**Current Phase**: Design Specification
**Next Phase**: Core Implementation
**Target Completion**: Month 8 of development roadmap

## References

- [PLAN-LIVING-DB.md](../PLAN-LIVING-DB.md) - Overall AI intelligence architecture
- [structured_memory_v1.md](./structured_memory_v1.md) - Structured memory cartridge format
- [living_db_semantics.md](./living_db_semantics.md) - AI-augmented transaction semantics