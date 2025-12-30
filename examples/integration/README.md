# AI Integration Example - Living Database

End-to-end demonstration of NorthstarDB's AI intelligence layer with mock LLM for deterministic testing.

## Overview

This example validates the complete AI workflow:
1. Plugin system initialization
2. Entity extraction from commits
3. Natural language query processing
4. Autonomous optimization detection

## Running

```bash
# From project root
zig run examples/integration/ai_living_db.zig

# Run tests
zig test examples/integration/ai_living_db.zig
```

## What It Demonstrates

### Step 1: Plugin System Initialization
- Creates PluginManager with local provider config
- Registers EntityExtractorPlugin
- Attaches plugin manager to database

### Step 2: Commit Sample Data
- Writes 5 sample key-value pairs
- Triggers on_commit hooks for each
- Demonstrates plugin execution lifecycle

### Step 3: LLM Entity Extraction
- Reads all committed data
- Simulates LLM function calling (mock, no API)
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

## Expected Output

```
==============================
  NorthstarDB: Living Database Demo
  End-to-End AI Integration Example
==============================

============================================================
STEP 1: Initializing AI Plugin System
============================================================
  Plugin system initialized
  Registered plugins: entity_extractor
  Plugin manager attached to database

============================================================
STEP 2: Committing Sample Data
============================================================
  Committed [1]: doc:architecture = "NorthstarDB is an embedded..."
  Plugins executed: 1, Success: true
  ...
  Committed 5 key-value pairs

============================================================
STEP 3: LLM-Based Entity Extraction
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

  Query 1: "What database is written in Zig?"
    Found 5 results:
      - cartridge:entity:Technology:NorthstarDB: {"name":"NorthstarDB"...}
      ...

============================================================
STEP 5: Autonomous Optimization Detection
============================================================
  Detected 3 optimization opportunities:
    [1] Create entity name index for faster lookups
        Pattern: frequent_entity_lookups
        Confidence: 0.92
    ...

============================================================
STEP 6: Validation & Performance Metrics
============================================================
  Database State:
    Total entities stored: 25
    LLM calls made: 5

  Integrity Checks:
    [PASS] All entities stored with confidence >= 0.7
    [PASS] Plugin hooks executed successfully
    [PASS] Semantic query system operational
    [PASS] Autonomous optimization detection active

  Living Database Status: ACTIVE

==============================
  Demo Complete!
==============================
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
│  │  Key/Value  │      │  MockLLMProvider │            │
│  │  Storage    │      │  (no API calls)  │            │
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

- `ai_living_db.zig` - Main demo implementation
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

## Testing

The example includes embedded tests:

```bash
# Run all tests
zig test examples/integration/ai_living_db.zig

# Specific test
zig test examples/integration/ai_living_db.zig --test-filter living_database_demo_full_run
```

## Production Differences

This demo uses mock LLM for testing. In production:

1. Replace `MockLLMProvider` with real provider:
   ```zig
   const config = PluginConfig{
       .llm_provider = .{
           .provider_type = "openai",  // or "anthropic"
           .model = "gpt-4-turbo",
           .api_key = "sk-...",
       },
   };
   ```

2. Enable performance isolation for async plugin execution

3. Configure cost budgets and rate limits

## Next Steps

- See `ai_knowledge_base/` for production patterns
- Review `docs/ai_plugins_v1.md` for plugin API
- Check `docs/ai_cartridges_v1.md` for memory formats
