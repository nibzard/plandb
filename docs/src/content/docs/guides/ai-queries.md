---
title: AI Queries Guide
description: Learn how to use natural language queries with NorthstarDB's AI-powered query system.
---

import { Card, Cards } from '@astrojs/starlight/components';

NorthstarDB's AI query system enables natural language queries that automatically convert to optimized structured queries using LLM function calling. This guide shows you how to set up and use AI queries effectively.

<Cards>
  <Card title="Natural Language" icon="message-square">
    Query in plain English, no SQL required.
  </Card>
  <Card title="Deterministic" icon="check-circle">
    Function calling ensures structured, reproducible results.
  </Card>
  <Card title="Smart Routing" icon="route">
    Automatically selects optimal cartridges for each query.
  </Card>
</Cards>

## Overview

The AI query system consists of three main components:

1. **NLToQueryConverter** - Converts natural language to structured topic queries
2. **QueryPlanner** - Creates optimized execution plans
3. **Cartridge-based execution** - Routes queries to appropriate cartridges

```zig
const queries = @import("northstar/queries");
const llm = @import("northstar/llm");

// Setup LLM provider
var provider = try llm.createProvider(allocator, "openai", .{
    .api_key = "sk-...",
    .model = "gpt-4",
    .base_url = "https://api.openai.com/v1",
});
defer llm.LLMProvider.deinit(&provider, allocator);

// Create query converter
var converter = try queries.NLToQueryConverter.init(allocator, &provider);
defer converter.deinit();

// Convert natural language query
const result = try converter.convert("files about database performance");
defer result.deinit(allocator);

if (result.success) {
    const query = result.query.?;
    // Execute query...
}
```

## Setting Up AI Queries

### 1. Configure LLM Provider

First, set up an LLM provider for function calling:

```zig
const std = @import("std");
const llm = @import("northstar/llm");

pub fn setupLLM(allocator: std.mem.Allocator) !llm.LLMProvider {
    // Choose your provider
    const provider_type = "openai"; // or "anthropic", "local"

    const config = llm.types.ProviderConfig{
        .api_key = "your-api-key",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
        .timeout_ms = 30000,
        .max_retries = 3,
    };

    return try llm.createProvider(allocator, provider_type, config);
}
```

**Provider options:**
- **OpenAI**: GPT-4, GPT-4 Turbo - Best for complex queries
- **Anthropic**: Claude 3 Opus/Sonnet - Excellent at structured output
- **Local**: Llama, Mistral - No API costs, lower latency

### 2. Initialize Query Converter

```zig
const queries = @import("northstar/queries");

pub fn initQuerySystem(
    allocator: std.mem.Allocator,
    provider: *llm.LLMProvider
) !queries.NLToQueryConverter {
    return try queries.NLToQueryConverter.init(allocator, provider);
}
```

## Natural Language Queries

### Basic Topic Search

The simplest queries search for topics across all entities:

```zig
var converter = try queries.NLToQueryConverter.init(allocator, &provider);
defer converter.deinit();

// Single topic
const result1 = try converter.convert("database");
defer result1.deinit(allocator);

// Multiple topics
const result2 = try converter.convert("database and performance");
defer result2.deinit(allocator);
```

### Entity-Type Scoped Queries

Search within specific entity types:

```zig
// Find files about a topic
const result1 = try converter.convert("files about database");
defer result1.deinit(allocator);

// Find functions related to btree
const result2 = try converter.convert("functions for btree operations");
defer result2.deinit(allocator);

// Find commits mentioning security
const result3 = try converter.convert("commits about security");
defer result3.deinit(allocator);
```

### Relationship Queries

Query entity relationships and connections:

```zig
// Find connected entities
const result1 = try converter.convert("files connected to main.zig");
defer result1.deinit(allocator);

// Find dependencies
const result2 = try converter.convert("files that import utils.zig");
defer result2.deinit(allocator);

// Find related code
const result3 = try converter.convert("code related to authentication");
defer result3.deinit(allocator);
```

## Query Planning

### Automatic Plan Generation

The query planner automatically generates optimized execution plans:

```zig
const queries = @import("northstar/queries");

var planner = try queries.QueryPlanner.init(allocator, &provider);
defer planner.deinit();

// Generate execution plan
const plan_result = try planner.planQuery("files about database");
defer plan_result.deinit(allocator);

if (plan_result.success) {
    const plan = plan_result.plan.?;

    std.debug.print("Query type: {}\n", .{@tagName(plan.query_type)});
    std.debug.print("Steps: {}\n", .{plan.steps.len});
    std.debug.print("Confidence: {.2}\n", .{plan.confidence});

    // Execute plan...
}
```

### Plan with Fallback

Use rule-based planning as fallback when LLM is unavailable:

```zig
// Try LLM, fallback to rules
const plan_result = try planner.planWithFallback("files about database");
defer plan_result.deinit(allocator);

// Always returns a plan (rule-based if LLM fails)
if (plan_result.success) {
    const plan = plan_result.plan.?;
    // Execute plan...
}
```

## Executing Queries

### Topic-Based Search

Execute a topic search query:

```zig
const cartridges = @import("northstar/cartridges");

// Convert natural language
const result = try converter.convert("database performance");
defer result.deinit(allocator);

if (result.success) {
    const query = result.query.?;

    // Open topic cartridge
    var cartridge = try cartridges.TopicCartridge.open(
        allocator,
        "topics.cartridge",
    );
    defer cartridge.deinit();

    // Execute search
    var search_results = try cartridge.searchByTopic(
        query.terms,
        query.limit
    );
    defer {
        for (search_results.items) |*r| {
            allocator.free(r.entity_id.namespace);
            allocator.free(r.entity_id.local_id);
        }
        search_results.deinit(allocator);
    }

    // Process results
    for (search_results.items) |item| {
        std.debug.print("{s}:{s} (score: {.2})\n", .{
            item.entity_id.namespace,
            item.entity_id.local_id,
            item.score,
        });
    }
}
```

### Hybrid Queries

Combine topic search with entity filters:

```zig
// Query with filters
const result = try converter.convert("files about database with high confidence");
defer result.deinit(allocator);

if (result.success) {
    const query = result.query.?;

    // Apply filters during search
    for (query.filters) |filter| {
        switch (filter.filter_type) {
            .confidence => {
                if (filter.numeric_value) |min_conf| {
                    std.debug.print("Min confidence: {.2}\n", .{min_conf});
                }
            },
            .entity_type => {
                if (filter.string_value) |type| {
                    std.debug.print("Entity type: {s}\n", .{type});
                }
            },
            else => {},
        }
    }
}
```

## Advanced Queries

### Temporal Filters

Query data at specific points in time:

```zig
// Query with time filters
const result = try converter.convert("files about database before transaction 100");
defer result.deinit(allocator);

if (result.success) {
    const query = result.query.?;

    // Apply temporal filters
    for (query.filters) |filter| {
        if (filter.filter_type == .before_txn) {
            if (filter.numeric_value) |txn_id| {
                std.debug.print("Before transaction: {}\n", .{txn_id});
                // Query snapshot at txn_id...
            }
        }
    }
}
```

### Confidence Thresholds

Filter results by confidence level:

```zig
const result = try converter.convert("high confidence matches for security");
defer result.deinit(allocator);

if (result.success) {
    const query = result.query.?;

    // Filter by confidence during execution
    const min_confidence = query.min_confidence;

    var filtered_results = std.ArrayList(SearchResult).init(allocator);

    for (all_results) |result| {
        if (result.confidence >= min_confidence) {
            try filtered_results.append(result);
        }
    }
}
```

## Error Handling

### Handle LLM Failures

```zig
const result = try converter.convertWithFallback("database");
defer result.deinit(allocator);

if (!result.success) {
    if (result.error_message) |msg| {
        std.log.err("Query conversion failed: {s}\n", .{msg});
    }

    // Use rule-based fallback
    const fallback_result = try converter.ruleBasedConvert("database");
    defer fallback_result.deinit(allocator);

    if (fallback_result.success) {
        // Use fallback query
        const query = fallback_result.query.?;
        // Execute...
    }
}
```

### Validate Query Results

```zig
const result = try converter.convert("complex query here");
defer result.deinit(allocator);

if (result.success) {
    if (result.query) |*query| {
        // Validate query parameters
        if (query.terms.len == 0) {
            std.log.warn("No terms extracted from query\n", .{});
            return error.InvalidQuery;
        }

        if (query.limit > 1000) {
            std.log.warn("Query limit too high: {}\n", .{query.limit});
            // Cap the limit
            const adjusted_query = try query.withLimit(1000);
            defer adjusted_query.deinit(allocator);
        }
    }
}
```

## Complete Example

Here's a complete example of an AI-powered search system:

```zig
const std = @import("std");
const db = @import("northstar");
const llm = @import("northstar/llm");
const queries = @import("northstar/queries");
const cartridges = @import("northstar/cartridges");

/// AI-powered search system
pub const AISearchSystem = struct {
    allocator: std.mem.Allocator,
    llm_provider: llm.LLMProvider,
    converter: queries.NLToQueryConverter,
    planner: queries.QueryPlanner,
    topic_cartridge: cartridges.TopicCartridge,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !@This() {
        // Setup LLM provider
        var provider = try llm.createProvider(allocator, "openai", .{
            .api_key = api_key,
            .model = "gpt-4",
            .base_url = "https://api.openai.com/v1",
        });

        errdefer provider.deinit(allocator);

        // Initialize converter
        var converter = try queries.NLToQueryConverter.init(allocator, &provider);
        errdefer converter.deinit();

        // Initialize planner
        var planner = try queries.QueryPlanner.init(allocator, &provider);
        errdefer planner.deinit();

        // Open topic cartridge
        var cartridge = try cartridges.TopicCartridge.open(
            allocator,
            "topics.cartridge",
        );

        return @This(){
            .allocator = allocator,
            .llm_provider = provider,
            .converter = converter,
            .planner = planner,
            .topic_cartridge = cartridge,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.converter.deinit();
        self.planner.deinit();
        self.topic_cartridge.deinit();
        self.llm_provider.deinit(self.allocator);
    }

    /// Search using natural language
    pub fn search(self: *@This(), natural_query: []const u8) !SearchResults {
        // Convert to structured query
        const convert_result = try self.converter.convertWithFallback(natural_query);
        defer convert_result.deinit(self.allocator);

        if (!convert_result.success) {
            return error.QueryConversionFailed;
        }

        const query = convert_result.query.?;

        // Execute topic search
        var results = try self.topic_cartridge.searchByTopic(
            query.terms,
            query.limit
        );

        // Apply filters
        var filtered = try self.applyFilters(query, results.items);
        results.items = filtered;

        return results;
    }

    /// Apply query filters to results
    fn applyFilters(
        self: *@This(),
        query: queries.TopicQuery,
        items: []cartridges.SearchResult
    ) ![]cartridges.SearchResult {
        _ = self;

        var filtered = std.ArrayList(cartridges.SearchResult).init(self.allocator);

        for (items) |item| {
            var include = true;

            // Apply filters
            for (query.filters) |filter| {
                if (!self.matchesFilter(item, filter)) {
                    include = false;
                    break;
                }
            }

            if (include) {
                // Copy item for new list
                const copy = try self.allocator.create(cartridges.SearchResult);
                copy.* = item;
                try filtered.append(copy);
            }
        }

        return filtered.toOwnedSlice();
    }

    /// Check if result matches filter
    fn matchesFilter(
        self: *@This(),
        item: cartridges.SearchResult,
        filter: queries.ScopeFilter
    ) bool {
        _ = self;

        return switch (filter.filter_type) {
            .confidence => if (filter.numeric_value) |min_conf|
                item.score >= min_conf
            else
                true,

            .entity_type => if (filter.string_value) |type_str|
                std.mem.eql(u8, @tagName(item.entity_type), type_str)
            else
                true,

            else => true,
        };
    }
};

pub const SearchResults = struct {
    items: []cartridges.SearchResult,

    pub fn deinit(self: *SearchResults, allocator: std.mem.Allocator) void {
        for (self.items) |*item| {
            allocator.free(item.entity_id.namespace);
            allocator.free(item.entity_id.local_id);
        }
        allocator.free(self.items);
    }
};

/// Usage example
pub fn exampleSearch() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize search system
    var search = try AISearchSystem.init(allocator, "your-api-key");
    defer search.deinit();

    // Perform natural language search
    const results = try search.search("files about database performance");
    defer results.deinit(allocator);

    // Display results
    std.debug.print("Found {} results:\n", .{results.items.len});
    for (results.items) |item| {
        std.debug.print("  {s}:{s}\n", .{
            item.entity_id.namespace,
            item.entity_id.local_id,
        });
    }
}
```

## Best Practices

### 1. Always Use Fallbacks

```zig
// Good: Use fallback
const result = try converter.convertWithFallback(query);
defer result.deinit(allocator);

// Bad: No fallback
const result = try converter.convert(query);
```

### 2. Validate Results

```zig
if (result.success) {
    if (result.query) |*query| {
        // Validate query has required fields
        if (query.terms.len == 0) {
            return error.NoTermsInQuery;
        }
    }
}
```

### 3. Cache Common Queries

```zig
// Cache frequently used queries
var query_cache = std.StringHashMap(queries.TopicQuery).init(allocator);

const cached = query_cache.get("files about database");
if (cached) |query| {
    // Use cached query
} else {
    // Convert and cache
    const result = try converter.convert("files about database");
    // ... cache result
}
```

### 4. Set Timeouts

```zig
const config = llm.types.ProviderConfig{
    .api_key = "sk-...",
    .model = "gpt-4",
    .base_url = "https://api.openai.com/v1",
    .timeout_ms = 5000,  // 5 second timeout
    .max_retries = 2,
};
```

## Performance Tips

1. **Use rule-based fallbacks** - Faster than LLM for common patterns
2. **Batch queries** - Convert multiple queries in parallel
3. **Cache queries** - Reuse converted queries
4. **Choose fast providers** - Local models for low latency
5. **Limit result sets** - Use smaller limits for faster responses

## Next Steps

- [LLM Integration API](../reference/llm.md) - LLM provider setup
- [Cartridges Usage](./cartridges-usage.md) - Cartridge-based queries
- [Topic Cartridge](../reference/cartridges.md) - Topic search details
- [Performance Tuning](./performance-tuning.md) - Optimize query performance
