# AI Integration Example - Living Database

End-to-end demonstration of NorthstarDB's AI intelligence layer with mock and real LLM options.

## Overview

This example validates the complete AI workflow:
1. Plugin system initialization
2. Entity extraction from commits
3. Natural language query processing
4. Autonomous optimization detection

## Running

### Mock LLM Example (No API Key Required)
```bash
cd examples/integration
zig build run
```

### Real LLM Example (Requires API Key)
```bash
cd examples/integration
OPENAI_API_KEY=sk-... zig build run-real
# Optionally specify model: OPENAI_MODEL=gpt-4o-mini zig build run-real
```

**Note**: The real LLM example (`ai_living_db_real.zig`) is currently a stub that demonstrates the structure. Actual OpenAI API integration requires updating the HTTP client code to Zig 0.15.2 API. See the code for details on this blocker.

### Tests
```bash
# Mock LLM tests
zig test examples/integration/ai_living_db.zig

# Real LLM tests
zig test examples/integration/ai_living_db_real.zig
```

## What It Demonstrates

### Step 1: Plugin System Initialization
- Creates PluginManager with local provider config
- Registers EntityExtractorPlugin
- Attaches plugin manager to database

### Step 2: Commit Sample Data
- Writes sample key-value pairs
- Triggers on_commit hooks for each
- Demonstrates plugin execution lifecycle

### Step 3: LLM Entity Extraction
- Reads all committed data
- **Mock**: Simulates LLM function calling (no API)
- **Real**: Would call OpenAI API for entity extraction (stubbed pending Zig 0.15.2 HTTP migration)
- Stores extracted entities in cartridge format

### Step 4: Natural Language Query
- Processes semantic queries
- Demonstrates query plan generation
- Returns ranked results from entity cartridge

### Step 5: Autonomous Optimization
- Detects optimization opportunities
- Suggests performance improvements
- Stores suggestions for review

### Step 6: Validation & Metrics
- Verifies data integrity
- Reports performance metrics
- Confirms living database status

## Expected Output (Mock LLM)

```
==============================
  NorthstarDB: Living Database Demo
  End-to-End AI Integration Example
==============================

============================================================
STEP 1: Initializing Living Database
============================================================
  Database initialized successfully
  Ready for AI-powered operations

============================================================
STEP 2: Committing Sample Data
============================================================
  Committed [1]: doc:architecture = "NorthstarDB is an embedded..."
  ...
  Committed 5 key-value pairs

============================================================
STEP 3: LLM-Based Entity Extraction (Mock)
============================================================
  Extracted: NorthstarDB (Technology) confidence=0.95
  Extracted: Zig (Language) confidence=1.00
  ...

  Extraction complete:
    Total entities extracted: 25
    Total tokens used: 2750
    LLM calls made: 5

============================================================
STEP 4: Natural Language Query Processing
============================================================
  ...

============================================================
STEP 5: Autonomous Optimization Detection
============================================================
  Detected 3 optimization opportunities:
    [1] Create entity name index for faster lookups
    ...

============================================================
STEP 6: Validation & Performance Metrics
============================================================
  Living Database Status: ACTIVE (Mock LLM)
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│               Living Database Integration                │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─────────────┐      ┌──────────────────┐            │
│  │   Db API    │─────▶│ PluginManager    │            │
│  │             │      │ - entity_extractor│            │
│  └─────────────┘      └──────────────────┘            │
│         │                        │                     │
│         ▼                        ▼                     │
│  ┌─────────────┐      ┌──────────────────┐            │
│  │  Key/Value  │      │ LLMProvider      │            │
│  │  Storage    │      │ (mock or real)   │            │
│  └─────────────┘      └──────────────────┘            │
│         │                        │                     │
│         ▼                        ▼                     │
│  ┌─────────────┐      ┌──────────────────┐            │
│  │  Entity     │      │  Extracted       │            │
│  │  Cartridge  │◀─────│  Entities        │            │
│  └─────────────┘      └──────────────────┘            │
│                                                         │
│  Query Flow:                                           │
│  NL Query → Semantic Analysis → Entity Lookup → Results│
└─────────────────────────────────────────────────────────┘
```

## Key Files

- `ai_living_db.zig` - Mock LLM demo (fully functional)
- `ai_living_db_real.zig` - Real LLM demo stub (requires Zig 0.15.2 HTTP migration)
- `src/plugins/manager.zig` - Plugin system
- `src/plugins/entity_extractor.zig` - Entity extraction plugin
- `src/llm/client.zig` - LLM provider interface
- `src/llm/function.zig` - Function calling utilities

## Data Model

### Entity Cartridge Format
```
cartridge:entity:<type>:<name> → {
  "name": "...",
  "type": "...",
  "confidence": 0.95
}
```

### Optimization Suggestions
```
ai:optimization:<id> → {
  "pattern": "...",
  "suggestion": "...",
  "confidence": 0.92
}
```

## Zig 0.15.2 Migration Note

The real LLM example (`ai_living_db_real.zig`) is currently stubbed because:

1. The `std.http.Client` API changed significantly in Zig 0.15.2
2. The existing provider code in `src/llm/providers/*.zig` also needs migration
3. Key changes:
   - `request()` now takes a `RequestOptions` struct instead of separate headers parameter
   - `ArrayList.init()` became `array_list.Managed.init()`
   - `toOwnedSlice(allocator)` became `toOwnedSlice()`

To complete the real LLM integration:
1. Migrate `src/llm/providers/openai.zig` to Zig 0.15.2 HTTP API
2. Update `ai_living_db_real.zig` to use the migrated provider
3. Test with actual OpenAI API calls

## Production Differences

This demo uses mock LLM for testing. In production:

1. Replace `MockLLMProvider` with real provider:
   ```zig
   const config = PluginConfig{
       .llm_provider = .{
           .provider_type = "openai",  // or "anthropic"
           .model = "gpt-4o-mini",
           .api_key = "sk-...",
       },
   };
   ```

2. Enable performance isolation for async plugin execution

3. Configure cost budgets and rate limits

4. Implement error handling and retry logic for API calls

## Next Steps

- See `ai_knowledge_base/` for production patterns
- Review `docs/ai_plugins_v1.md` for plugin API
- Check `docs/ai_cartridges_v1.md` for memory formats
- Migrate HTTP client code to Zig 0.15.2 API
