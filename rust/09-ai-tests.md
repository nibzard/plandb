# AI Intelligence Layer - Testing Strategy

## Purpose

Comprehensive testing strategy for AI components including event system, plugin system, LLM integration, and cartridges. Defines test patterns, mocking strategies, and validation approaches.

## Test Categories

### 1. Unit Tests

Test individual components in isolation.

#### Event System Tests

**Event Types Validation**:
- EventHeader validation with valid and oversized payloads
- EventType round-trip serialization
- EventVisibility ordering
- TimeWindow validation (start <= end)

**Event Storage Tests**:
- EventStore creation and initialization
- Single event append and retrieval
- Event query with various filter combinations
- Session and actor event retrieval
- Time-travel queries with timestamp ranges
- Index persistence across reopen
- Compaction removes old events
- Corruption handling

**Event Manager Tests**:
- Record agent session start
- Record agent operation
- Record review note
- Record performance sample
- Query events with filters
- Session event retrieval
- Actor event retrieval

#### Plugin System Tests

**Plugin Manager Tests**:
- Plugin manager initialization
- Plugin registration
- Duplicate plugin rejection
- Plugin lifecycle (init, cleanup)
- Function registration
- Function lookup

**Hook Execution Tests**:
- Execute on_commit hooks (no plugins)
- Execute on_commit hooks with single plugin
- Execute on_commit hooks with multiple plugins
- Hook error handling
- Async execution with performance isolation
- Sync execution without performance isolation

**Resource Tracker Tests**:
- Token bucket refill
- Token consumption
- Quota enforcement
- Usage statistics

#### LLM Provider Tests

**Provider Factory Tests**:
- Create OpenAI provider
- Create Anthropic provider
- Create local provider
- Invalid provider type error

**URL Validation Tests**:
- Valid HTTPS URLs accepted
- HTTP URLs rejected (except localhost)
- Private IP ranges blocked
- Localhost allowed for development

**Function Calling Tests**:
- Function schema validation
- Parameter validation
- Response parsing
- Token usage tracking

#### Function Schema Tests

**Schema Construction Tests**:
- Create string schema
- Create object schema with properties
- Create array schema with items
- Add required fields
- Add enum values

**Schema Validation Tests**:
- Validate string against schema
- Validate number against schema
- Validate object with required fields
- Validate array items
- Enum validation
- Type mismatch errors
- Missing required field errors

**Provider Format Tests**:
- Convert to OpenAI format
- Convert to Anthropic format
- JSON serialization

#### Cartridge Tests

**Code Review Cartridge Tests**:
- Add review note
- Get reviews by target type
- Get commit reviews
- Get file reviews
- Get symbol reviews
- Get reviews by author
- Date range queries
- Empty result handling

**Observability Cartridge Tests**:
- Record counter metric
- Record gauge metric
- Record timing metric
- Metric query with filters
- Aggregation queries
- Baseline computation
- Regression detection
- Rate limit enforcement
- Token bucket refill/consumption

#### Natural Language Query Tests

**Query Conversion Tests**:
- Topic search queries
- Review explanation queries
- Review notes queries
- Agent activity queries
- Observability queries
- Regression hunt queries

**Rule-Based Fallback Tests**:
- "files about X" pattern
- "show review" pattern
- "what did agent" pattern
- "regression since" pattern

### 2. Integration Tests

Test multiple components working together.

#### Event + Plugin Integration

**Plugin Hook Event Recording**:
- Plugin records events via EventManager
- Events persisted to EventStore
- Events retrievable after plugin execution

#### LLM + Plugin Integration

**Function Calling Through Plugins**:
- Plugin registers function schema
- Plugin calls function via LLMProvider
- Response validated and parsed
- Resource usage tracked

#### Cartridge + Event Integration

**Cartridge Persistence via Events**:
- Cartridge stores data as events
- Data retrievable from events
- Index maintained correctly

#### Query + Cartridge Integration

**Query Execution Against Cartridges**:
- NL query converted to structured query
- Query executed against cartridge
- Results formatted and returned

### 3. Property-Based Tests

Test invariants with randomly generated inputs.

**Event System Properties**:
- Event ID uniqueness and monotonicity
- Index consistency with events file
- Round-trip: append -> query -> verify payload

**Plugin System Properties**:
- Plugin isolation (one failure doesn't affect others)
- Resource quota accuracy

**Function Schema Properties**:
- Round-trip: schema -> JSON -> schema
- Validation: valid values pass, invalid values fail
- Deep clone produces equivalent schema

**Token Bucket Properties**:
- Tokens never exceed capacity
- Refill rate is constant
- Consumption is atomic

### 4. Mock Implementations

#### Mock LLM Provider

**Purpose**: Test plugin and query system without real LLM calls

**Implementation**:
```rust
struct MockLLMProvider {
    responses: Vec<FunctionResult>,
    call_count: Arc<AtomicUsize>,
}

impl LLMProvider for MockLLMProvider {
    fn call_function(&self, schema: FunctionSchema, params: Value) -> Result<FunctionResult, Error> {
        self.call_count.fetch_add(1, Ordering::SeqCst);
        // Return predefined response
    }
}
```

**Usage**:
- Plugin testing with predictable LLM responses
- Query conversion testing
- Error simulation

#### Mock Event Manager

**Purpose**: Test plugins and cartridges without real event storage

**Implementation**:
```rust
struct MockEventManager {
    events: Arc<Mutex<Vec<EventResult>>>,
}

impl EventManager for MockEventManager {
    fn record_review_note(&self, ...) -> Result<u64, Error> {
        // Store in memory
    }
}
```

### 5. Test Utilities

**Event Builder**:
```rust
struct EventBuilder {
    event_type: EventType,
    actor_id: u64,
    timestamp: i64,
    // ...
}

impl EventBuilder {
    fn build(self) -> EventHeader { /* ... */ }
}
```

**Plugin Test Helper**:
```rust
struct TestPlugin {
    name: String,
    on_commit_calls: Arc<AtomicUsize>,
}

impl Plugin for TestPlugin {
    // Track calls, return predictable results
}
```

**Query Test Helper**:
```rust
fn test_conversion(input: &str, expected_intent: QueryIntent) {
    let converter = NLToQueryConverter::new(mock_llm());
    let result = converter.convert(input).unwrap();
    assert_eq!(result.query.unwrap().intent, expected_intent);
}
```

### 6. Performance Tests

**Event Store Performance**:
- Append throughput (events/sec)
- Query latency (p50, p95, p99)
- Index build time
- Compaction speed

**Plugin Execution Performance**:
- Hook execution latency
- Parallel hook execution
- Resource overhead

**Query Conversion Performance**:
- NL to structured conversion latency
- Rule-based fallback latency

### 7. Hardening Tests

**Crash Recovery**:
- Event store recovery after crash
- Index rebuild from events file
- Plugin state recovery

**Corruption Handling**:
- Corrupt event record handling
- Corrupt index recovery
- Invalid payload handling

**Resource Exhaustion**:
- OOM handling
- Disk full handling
- Network timeout handling

## Test Organization

### Directory Structure

```
northstar-ai/tests/
  unit/
    events/
      types_test.rs
      storage_test.rs
      manager_test.rs
    plugins/
      manager_test.rs
      resource_test.rs
    llm/
      provider_test.rs
      function_test.rs
    cartridges/
      code_review_test.rs
      observability_test.rs
    queries/
      nl_converter_test.rs
  integration/
    plugin_events_test.rs
    llm_plugin_test.rs
    cartridge_query_test.rs
  property/
    events_property_test.rs
    schema_property_test.rs
  mocks/
    mock_llm.rs
    mock_events.rs
  perf/
    event_store_bench.rs
    plugin_hook_bench.rs
  hardening/
    crash_recovery_test.rs
    corruption_test.rs
```

## Test Configuration

**Test Databases**:
- In-memory for unit tests
- Temporary files for integration tests
- Cleaned up after each test

**LLM Mocking**:
- Use mock providers for unit tests
- Optional real provider for integration tests (with feature flag)

**Concurrency Testing**:
- Use `rayon` for parallel test execution
- `tokio::test` for async tests

## Dependencies

- **Testing**: `proptest` for property tests, `mockall` for mocking
- **Assertions**: `pretty_assertions` for better error messages
- **Performance**: `criterion` for benchmarks

## Rust Implementation Guidance

### Test Module Structure

Each source file should have a `#[cfg(test)]` module with unit tests.

Integration tests go in `tests/` directory.

### Mock Patterns

Use `mockall` for trait mocking:

```rust
#[automock]
trait LLMProvider {
    fn call_function(&self, schema: FunctionSchema, params: Value) -> Result<FunctionResult, Error>;
}
```

### Property Testing

Use `proptest` for property-based tests:

```rust
proptest! {
    #[test]
    fn test_event_id_monotonic(ids in prop::collection::vec(any::<u64>(), 1..100)) {
        // Test that IDs are monotonically increasing
    }
}
```

### Test Fixtures

Create shared fixtures in `tests/common/mod.rs`:

```rust
pub fn test_event_store() -> EventStore {
    // Create temporary event store for testing
}

pub fn mock_llm_provider() -> MockLLMProvider {
    // Create mock provider
}
```

### Coverage

Use `tarpaulin` for code coverage:

```bash
cargo tarpaulin --out Html --verbose
```

Target: 80%+ coverage for critical paths.
