---
title: LLM Integration API
description: Provider-agnostic interface for integrating with OpenAI, Anthropic, and local LLM providers with deterministic function calling.
---

import { Card, Cards } from '@astrojs/starlight/components';

The LLM integration layer provides a unified interface for interacting with different LLM providers while maintaining deterministic function calling behavior. This enables NorthstarDB's AI intelligence features including entity extraction, semantic understanding, and autonomous optimization.

<Cards>
  <Card title="Provider Agnostic" icon="layers">
    Single interface for OpenAI, Anthropic, and local models.
  </Card>
  <Card title="Function Calling" icon="code">
    Deterministic JSON Schema-based function invocation.
  </Card>
  <Card title="Smart Routing" icon="route">
    Automatic provider selection with cost/quality optimization.
  </Card>
</Cards>

## Overview

The LLM integration API consists of three main modules:

- **`llm/client`** - Provider-agnostic client interface
- **`llm/function`** - Function schema and JSON Schema generation
- **`llm/orchestrator`** - Multi-model routing and failover

## Creating a Provider

### `llm.createProvider`

Create an LLM provider from configuration.

```zig
const llm = @import("northstar/llm");

// Create OpenAI provider
var openai_provider = try llm.createProvider(
    allocator,
    "openai",
    .{
        .api_key = "sk-...",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
        .timeout_ms = 30000,
        .max_retries = 3,
    }
);
defer llm.LLMProvider.deinit(&openai_provider, allocator);

// Create Anthropic provider
var anthropic_provider = try llm.createProvider(
    allocator,
    "anthropic",
    .{
        .api_key = "sk-ant-...",
        .model = "claude-3-opus-20240229",
        .base_url = "https://api.anthropic.com",
    }
);
defer llm.LLMProvider.deinit(&anthropic_provider, allocator);

// Create local provider
var local_provider = try llm.createProvider(
    allocator,
    "local",
    .{
        .api_key = "",
        .model = "llama-2-7b",
        .base_url = "http://localhost:11434",
    }
);
defer llm.LLMProvider.deinit(&local_provider, allocator);
```

**Parameters:**
- `allocator: std.mem.Allocator` - Memory allocator
- `provider_type: []const u8` - One of: `"openai"`, `"anthropic"`, `"local"`
- `config: ProviderConfig` - Provider configuration

**Returns:** `!LLMProvider`

**Errors:**
- `InvalidProviderType` - Unknown provider type
- `InvalidConfiguration` - Invalid config values
- `OutOfMemory` - Allocator failure

---

## Defining Function Schemas

### `function.FunctionSchema.init`

Create a function schema for LLM function calling.

```zig
const function = llm.function;

// Define parameter schema
var params = function.JSONSchema.init(.object);
try params.addRequired(allocator, "text");
try params.setProperty(allocator, "text", function.JSONSchema.init(.string));
defer params.deinit(allocator);

// Create function schema
var schema = try function.FunctionSchema.init(
    allocator,
    "extract_entities",
    "Extract named entities from text",
    params
);
defer schema.deinit(allocator);
```

**Complex schema example:**

```zig
// Create object schema with nested properties
var params = function.JSONSchema.init(.object);
try params.setDescription(allocator, "User profile data");

// Add string property
var name_schema = function.JSONSchema.init(.string);
try name_schema.setDescription(allocator, "Full name");
try params.setProperty(allocator, "name", name_schema);

// Add number property
var age_schema = function.JSONSchema.init(.integer);
try age_schema.setDescription(allocator, "Age in years");
try params.setProperty(allocator, "age", age_schema);

// Add array property
var tags_schema = function.JSONSchema.init(.array);
var tag_item = function.JSONSchema.init(.string);
tags_schema.items = &tag_item;
try params.setProperty(allocator, "tags", tags_schema);

// Mark required fields
try params.addRequired(allocator, "name");
try params.addRequired(allocator, "age");

defer params.deinit(allocator);

var schema = try function.FunctionSchema.init(
    allocator,
    "create_user_profile",
    "Create a user profile",
    params
);
defer schema.deinit(allocator);
```

---

### `function.FunctionSchema.toOpenAIFormat`

Convert schema to OpenAI function format.

```zig
const openai_json = try schema.toOpenAIFormat(allocator);
defer {
    // Clean up JSON object
    if (openai_json == .object) {
        var it = openai_json.object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        openai_json.object.deinit();
    }
}

// Use with OpenAI API
```

---

### `function.FunctionSchema.toAnthropicFormat`

Convert schema to Anthropic tool format.

```zig
const anthropic_json = try schema.toAnthropicFormat(allocator);
defer {
    // Clean up JSON object
    if (anthropic_json == .object) {
        var it = anthropic_json.object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        anthropic_json.object.deinit();
    }
}

// Use with Anthropic API
```

---

## Calling Functions

### `provider.call_function`

Invoke a function through the LLM provider.

```zig
// Prepare parameters as JSON
const params = std.json.Value{
    .object = &std.json.ObjectMap.init(allocator),
};
try params.object.put("text", .{ .string = "Alice visited Paris last year" });

// Call function
var result = try provider.call_function(
    schema,
    params,
    allocator
);
defer result.deinit(allocator);

std.debug.print("Function: {s}\n", .{result.function_name});
std.debug.print("Arguments: {}\n", .{result.arguments});
std.debug.print("Provider: {s}\n", .{result.provider});
std.debug.print("Model: {s}\n", .{result.model});

if (result.tokens_used) |usage| {
    std.debug.print("Tokens: {}/{}\n", .{
        usage.prompt_tokens,
        usage.completion_tokens
    });
}
```

**Returns:** `!FunctionResult`

**FunctionResult fields:**
- `function_name: []const u8` - Name of called function
- `arguments: Value` - Function arguments as JSON
- `raw_response: []const u8` - Raw LLM response
- `provider: []const u8` - Provider name
- `model: []const u8` - Model name
- `tokens_used: ?TokenUsage` - Token usage if available

---

## Multi-Model Orchestration

### `orchestrator.Orchestrator.init`

Create an orchestrator for intelligent provider routing.

```zig
const orchestrator = llm.orchestrator;

var orc = try orchestrator.Orchestrator.init(allocator, .{
    .default_strategy = .balanced,
    .enable_failover = true,
    .max_retries = 3,
    .retry_delay_ms = 1000,
    .failure_threshold = 5,
});
defer orc.deinit();
```

**RoutingConfig options:**
- `default_strategy` - Cost/quality/latency/balanced
- `enable_failover` - Automatic failover on failure
- `max_retries` - Retry attempts
- `retry_delay_ms` - Delay between retries
- `failure_threshold` - Failures before marking unavailable

---

### `orc.registerProvider`

Register a provider with routing configuration.

```zig
// Register high-quality provider
try orc.registerProvider("gpt4", &gpt4_provider, .{
    .priority = 10,
    .quality_score = 95,
    .cost_multiplier = 2.0,
    .supported_tasks = &[_]orchestrator.TaskType{
        .complex_reasoning,
        .security_analysis,
    },
});

// Register cost-optimized provider
try orc.registerProvider("haiku", &haiku_provider, .{
    .priority = 5,
    .quality_score = 75,
    .cost_multiplier = 0.1,
    .supported_tasks = &[_]orchestrator.TaskType{
        .simple_extraction,
        .summarization,
    },
});
```

---

### `orc.callFunction`

Execute a function call with intelligent routing.

```zig
var result = try orc.callFunction(
    .simple_extraction,
    .normal,
    .cost_optimized,
    schema,
    params,
    allocator
);
defer result.deinit(allocator);

// Orchestrator automatically:
// - Classifies the task
// - Selects best provider
// - Handles retries and failover
// - Tracks health and performance
```

**Parameters:**
- `task_type: TaskType` - simple_extraction, complex_reasoning, etc.
- `priority: TaskPriority` - low, normal, high, critical
- `strategy: ?RoutingStrategy` - Override default strategy
- `schema: FunctionSchema` - Function schema
- `params: Value` - Function parameters

---

## Provider Health Monitoring

### `orc.getProviderHealth`

Check health status of a provider.

```zig
const health = orc.getProviderHealth("gpt4");
if (health) |h| {
    switch (h) {
        .healthy => std.log.info("Provider healthy", .{}),
        .degraded => std.log.warn("Provider degraded", .{}),
        .unavailable => std.log.err("Provider unavailable", .{}),
    }
}
```

---

### `orc.getAllProviderStatuses`

Get status of all registered providers.

```zig
const statuses = try orc.getAllProviderStatuses();
defer {
    for (statuses) |*s| s.deinit(allocator);
    allocator.free(statuses);
}

for (statuses) |status| {
    std.debug.print("{s}: {} - {} requests, {} failures, {:.1}ms avg\n", .{
        status.name,
        status.health,
        status.request_count,
        status.failure_count,
        status.avg_latency_ms,
    });
}
```

---

### `orc.resetProviderHealth`

Reset provider health after maintenance.

```zig
try orc.resetProviderHealth("gpt4");
// Provider is now marked as healthy
```

---

## Task Classification

### `Orchestrator.classifyTask`

Automatically classify task type from function schema.

```zig
const task_type = orchestrator.Orchestrator.classifyTask(schema);

switch (task_type) {
    .simple_extraction => std.log.info("Simple extraction task", .{}),
    .complex_reasoning => std.log.info("Complex reasoning task", .{}),
    .security_analysis => std.log.info("Security analysis task", .{}),
    .summarization => std.log.info("Summarization task", .{}),
    .general => std.log.info("General task", .{}),
}
```

Classification is based on function name patterns:
- `security`, `vulnerability`, `analyze` → security_analysis
- `summarize`, `compress`, `digest` → summarization
- `plan`, `optimize`, `reason` → complex_reasoning
- `extract`, `parse`, `detect` → simple_extraction

---

## Complete Examples

### Entity Extraction with Function Calling

```zig
fn extractEntities(
    allocator: std.mem.Allocator,
    provider: *llm.LLMProvider,
    text: []const u8
) !void {
    // Define function schema
    var params = llm.function.JSONSchema.init(.object);
    try params.setProperty(allocator, "text", llm.function.JSONSchema.init(.string));
    defer params.deinit(allocator);

    var schema = try llm.function.FunctionSchema.init(
        allocator,
        "extract_entities",
        "Extract named entities (people, places, organizations)",
        params
    );
    defer schema.deinit(allocator);

    // Prepare parameters
    var params_obj = std.json.ObjectMap.init(allocator);
    try params_obj.put("text", .{ .string = text });

    // Call function
    var result = try provider.call_function(
        schema,
        .{ .object = params_obj },
        allocator
    );
    defer result.deinit(allocator);

    // Process results
    std.debug.print("Entities: {}\n", .{result.arguments});
}
```

### Multi-Provider Setup with Failover

```zig
fn setupMultiProvider(allocator: std.mem.Allocator) !orchestrator.Orchestrator {
    // Create providers
    var gpt4 = try llm.createProvider(allocator, "openai", .{
        .api_key = "sk-...",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
    });
    defer llm.LLMProvider.deinit(&gpt4, allocator);

    var haiku = try llm.createProvider(allocator, "anthropic", .{
        .api_key = "sk-ant-...",
        .model = "claude-3-haiku",
        .base_url = "https://api.anthropic.com",
    });
    defer llm.LLMProvider.deinit(&haiku, allocator);

    // Setup orchestrator
    var orc = try orchestrator.Orchestrator.init(allocator, .{
        .default_strategy = .balanced,
        .enable_failover = true,
        .max_retries = 3,
    });
    errdefer orc.deinit();

    // Register providers
    try orc.registerProvider("gpt4", &gpt4, .{
        .priority = 10,
        .quality_score = 95,
        .cost_multiplier = 2.0,
    });

    try orc.registerProvider("haiku", &haiku, .{
        .priority = 5,
        .quality_score = 75,
        .cost_multiplier = 0.1,
    });

    return orc;
}
```

### Cost-Optimized Extraction

```zig
fn costOptimizedExtraction(
    orc: *orchestrator.Orchestrator,
    schema: function.FunctionSchema,
    text: []const u8,
    allocator: std.mem.Allocator
) !void {
    // Prepare parameters
    var params_obj = std.json.ObjectMap.init(allocator);
    try params_obj.put("text", .{ .string = text });

    // Use cost-optimized routing
    var result = try orc.callFunction(
        .simple_extraction,
        .low,
        .cost_optimized,  // Prefer cheapest provider
        schema,
        .{ .object = params_obj },
        allocator
    );
    defer result.deinit(allocator);

    std.debug.print("Result from {s}: {}\n", .{
        result.provider,
        result.arguments
    });
}
```

### Quality-Optimized Reasoning

```zig
fn qualityOptimizedReasoning(
    orc: *orchestrator.Orchestrator,
    schema: function.FunctionSchema,
    query: []const u8,
    allocator: std.mem.Allocator
) !void {
    var params_obj = std.json.ObjectMap.init(allocator);
    try params_obj.put("query", .{ .string = query });

    // Use quality-optimized routing for complex task
    var result = try orc.callFunction(
        .complex_reasoning,
        .high,
        .quality_optimized,  // Prefer best quality
        schema,
        .{ .object = params_obj },
        allocator
    );
    defer result.deinit(allocator);

    std.debug.print("Reasoning result: {}\n", .{result.arguments});
}
```

---

## Error Handling

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `ProviderUnavailable` | Provider down or timed out | Failover or retry |
| `QuotaExceeded` | API quota limit | Switch providers |
| `InvalidResponse` | Malformed LLM response | Retry with validation |
| `SchemaValidationFailed` | Function result invalid | Check schema definition |

### Retry Pattern

```zig
fn callWithRetry(
    provider: *llm.LLMProvider,
    schema: function.FunctionSchema,
    params: std.json.Value,
    max_retries: u32,
    allocator: std.mem.Allocator
) !llm.types.FunctionResult {
    var retry: u32 = 0;
    while (retry < max_retries) : (retry += 1) {
        const result = provider.call_function(schema, params, allocator);

        if (result) |r| {
            return r;
        } else |err| {
            std.log.warn("Attempt {} failed: {}", .{retry, err});

            if (retry == max_retries - 1) {
                return err;
            }

            // Exponential backoff
            std.time.sleep(@as(u64, 1) << @as(u6, @intCast(retry)) * 100_000_000);
        }
    }

    return error.MaxRetriesExceeded;
}
```

---

## Reference Summary

### Core Types

| Type | Description |
|------|-------------|
| `LLMProvider` | Provider union (openai, anthropic, local) |
| `FunctionSchema` | Function definition for LLM calling |
| `JSONSchema` | JSON Schema type definitions |
| `FunctionResult` | Result from function call |
| `ProviderConfig` | Provider configuration |
| `TokenUsage` | Token usage information |

### Client Methods

| Method | Description |
|--------|-------------|
| `createProvider(allocator, type, config)` | Create LLM provider |
| `provider.call_function(schema, params)` | Call function through provider |
| `provider.validate_response(response)` | Validate function result |
| `provider.get_capabilities()` | Get provider capabilities |
| `provider.deinit()` | Clean up provider |
| `provider.name()` | Get provider name |

### Function Schema Methods

| Method | Description |
|--------|-------------|
| `FunctionSchema.init(allocator, name, desc, params)` | Create function schema |
| `schema.toOpenAIFormat(allocator)` | Convert to OpenAI format |
| `schema.toAnthropicFormat(allocator)` | Convert to Anthropic format |
| `schema.deinit(allocator)` | Clean up schema |

### Orchestrator Methods

| Method | Description |
|--------|-------------|
| `Orchestrator.init(allocator, config)` | Create orchestrator |
| `orc.registerProvider(name, provider, config)` | Register provider |
| `orc.unregisterProvider(name)` | Unregister provider |
| `orc.callFunction(task, priority, strategy, ...)` | Execute with routing |
| `orc.getProviderHealth(name)` | Check provider health |
| `orc.getAllProviderStatuses()` | Get all provider statuses |
| `orc.resetProviderHealth(name)` | Reset provider health |
| `Orchestrator.classifyTask(schema)` | Classify task type |

### Enums

| Enum | Values |
|------|--------|
| `TaskType` | simple_extraction, complex_reasoning, security_analysis, summarization, general |
| `TaskPriority` | low, normal, high, critical |
| `RoutingStrategy` | cost_optimized, quality_optimized, balanced, latency_optimized |
| `ProviderHealth` | healthy, degraded, unavailable |

See also:
- [Plugin System API](./cartridges.md) - Plugin hooks for AI features
- [Db API](./db.md) - Database with plugin attachment
- [Commit Stream](../concepts/commit-stream.md) - How AI hooks integrate with commits
