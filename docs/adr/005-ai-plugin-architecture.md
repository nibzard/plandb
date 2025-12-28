# ADR-005: AI Plugin Architecture

**Status**: Accepted

**Date**: 2025-12-28

## Context

NorthstarDB's "Living Database" vision requires **extensible AI intelligence** without modifying core database code:

1. **Provider agnosticism**: Support OpenAI, Anthropic, local models interchangeably
2. **Function calling**: Deterministic operations instead of fuzzy embeddings
3. **Plugin extensibility**: Third-party developers can add intelligence
4. **Performance isolation**: AI operations must not degrade core DB performance
5. **Graceful degradation**: Database remains functional without AI services

Key requirements:
- **Hook system**: Commit/query/maintenance triggers for plugin execution
- **Function registry**: LLM-callable functions for structured extraction
- **Async execution**: Parallel plugin execution with timeouts
- **Error boundaries**: Plugin failures don't crash database

## Decision

NorthstarDB uses a **function-calling plugin architecture** with explicit hooks and provider abstraction:

### Core Design

1. **Plugin manager**: Central registry for plugins and function schemas
2. **Hook system**: on_commit, on_query, on_schedule lifecycle events
3. **LLM abstraction**: Provider-agnostic client interface
4. **Function calling**: JSON Schema for deterministic operations

### Plugin Interface

```zig
const Plugin = struct {
    name: []const u8,
    version: []const u8,

    // Lifecycle hooks
    on_commit: ?*const fn(allocator, CommitContext) anyerror!PluginResult,
    on_query: ?*const fn(allocator, QueryContext) anyerror!?QueryPlan,
    on_schedule: ?*const fn(allocator, ScheduleContext) anyerror!MaintenanceTask,
    get_functions: ?*const fn(allocator) []FunctionSchema,
};
```

### Hook System

**on_commit**: Analyze mutations and update cartridges
- Called after each successful transaction
- Receives TxnId, mutations, timestamp, metadata
- Async execution with timeout enforcement
- Plugins build entity/topic/relationship cartridges

**on_query**: Optimize query execution
- Called for natural language queries
- Returns QueryPlan (use_cartridge, use_llm, use_hybrid)
- Plugins can intercept and route queries

**on_schedule**: Autonomous maintenance
- Called during maintenance windows
- Returns MaintenanceTask for autonomous optimization
- Plugins trigger cartridge rebuilds, archival, etc.

### Function Schema System

```zig
const FunctionSchema = struct {
    name: []const u8,
    description: []const u8,
    parameters: JSONSchema,  // Validates LLM function calls
};

// Example: Entity extraction function
const extract_entities = FunctionSchema{
    .name = "extract_entities_and_topics",
    .description = "Extract structured entities from database mutations",
    .parameters = .{
        .type = .object,
        .properties = .{
            .mutations = {.type = .array},
            .context = {.type = .string},
        },
    },
};
```

### LLM Provider Abstraction

```zig
const LLMProvider = union(enum) {
    openai: OpenAIProvider,
    anthropic: AnthropicProvider,
    local: LocalProvider,

    // Common interface
    fn call_function(provider, schema, params) !FunctionResult;
    fn chat_completion(provider, messages) !ChatResponse;
};
```

### Performance Isolation

```zig
pub fn execute_on_commit_hooks(manager, ctx) !PluginExecutionResult {
    // Spawn each plugin in separate thread
    for (plugins) |plugin| {
        spawn_thread(plugin.on_commit, ctx, timeout_ms);
    }

    // Collect results with error isolation
    var errors: []PluginErrorInfo = [];
    for (results) |result| {
        if (result.failed) {
            errors.append(error);  // Continue on failure
        }
    }

    return PluginExecutionResult{ .errors = errors };
}
```

## Consequences

### Positive

- **Extensibility**: Third-party plugins without core changes
- **Provider agnosticism**: Switch LLM providers via config
- **Deterministic**: Function calling produces consistent results
- **Performance isolation**: AI operations don't block database
- **Graceful degradation**: DB works even if all plugins fail

### Negative

- **Complexity**: Plugin system adds architectural overhead
- **Debugging**: Plugin errors harder to trace than monolithic code
- **Version management**: Plugin API must remain stable
- **Testing**: Must test plugin isolation and error boundaries

### Mitigations

- **Complexity**: Clear plugin API, comprehensive documentation
- **Debugging**: Observability hooks, plugin error logging
- **Version management**: Semantic versioning, deprecation policy
- **Testing**: Plugin test harness, mock LLM providers

## Related Specifications

- `src/plugins/manager.zig` - Plugin manager implementation
- `src/llm/client.zig` - Provider-agnostic LLM client
- `src/llm/function.zig` - Function schema system
- `PLAN-LIVING-DB.md` - AI intelligence roadmap

## Plugin Examples

### Entity Extractor Plugin
- **Hook**: on_commit
- **Function**: extract_entities_and_topics
- **Output**: Updates entity cartridge

### Query Router Plugin
- **Hook**: on_query
- **Function**: analyze_query_intent
- **Output**: Routes to optimal cartridge

### Performance Optimizer Plugin
- **Hook**: on_schedule
- **Function**: detect_hot_patterns
- **Output**: Triggers cartridge rebuilds

## Alternatives Considered

1. **Monolithic AI**: Rejected (hard to extend, provider lock-in)
2. **Embeddings only**: Rejected (non-deterministic, fuzzy results)
3. **External AI service**: Rejected (violates embedded database principle)
4. **No plugin system**: Rejected (can't support third-party extensions)
