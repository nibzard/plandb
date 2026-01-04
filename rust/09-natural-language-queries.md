# Natural Language Query Planning for AI Intelligence Layer

## Purpose

Converts natural language queries into structured database queries. Uses LLM function calling for deterministic extraction with rule-based fallback for common patterns. Supports topic search, review queries, agent activity tracking, and observability queries.

## Types

### QueryIntent (Enum)

**Description**: Intent classification for queries

**Variants**:
- `TopicSearch` - Search entities/topics by keywords
- `ReviewExplain` - Explain code changes/review notes
- `ReviewNotes` - Get review notes for a target
- `AgentActivity` - Query agent operations/sessions
- `Observability` - Performance/telemetry queries
- `RegressionHunt` - Find performance regressions
- `Unknown` - Intent could not be determined

### NLToQueryConverter

**Description**: Main converter for NL to structured queries

**Fields**:
- `allocator: Allocator` - Memory allocator
- `llm_provider: LLMProvider` - LLM for function calling
- `function_schema: FunctionSchema` - Schema for query extraction

**Invariants**:
- LLM provider is valid for lifetime
- Function schema matches LLM expected format

### ConversionResult

**Description**: Result from query conversion

**Fields**:
- `success: bool` - Conversion succeeded
- `error_message: Option<String>` - Error message if failed
- `query: Option<StructuredQuery>` - Extracted query
- `clarifications: Vec<String>` - Questions to ask user

### StructuredQuery

**Description**: Parsed structured query

**Fields**:
- `intent: QueryIntent` - Query intent
- `topic_query: Option<TopicQuery>` - Topic search query
- `review_query: Option<ReviewQuery>` - Review query
- `agent_query: Option<AgentQuery>` - Agent activity query
- `observability_query: Option<ObservabilityQuery>` - Observability query
- `confidence: f32` - Confidence in extraction (0.0 to 1.0)

**Invariants**:
- Exactly one query type is Some based on intent
- `confidence` in range [0.0, 1.0]

### TopicQuery

**Description**: Topic-based search query

**Fields**:
- `keywords: Vec<String>` - Search keywords
- `entity_types: Vec<String>` - Entity types to search
- `scope_filter: Option<ScopeFilter>` - Scope restriction

### ScopeFilter

**Description**: Scope restriction for queries

**Fields**:
- `file_path: Option<String>` - Limit to file path
- `symbol_path: Option<String>` - Limit to symbol path
- `commit_range: Option<String>` - Limit to commit range
- `time_range: Option<TimeRange>` - Limit to time range

### TimeRange

**Description**: Time range for queries

**Fields**:
- `start: Option<i64>` - Start timestamp
- `end: Option<i64>` - End timestamp

### ReviewQuery

**Description**: Query for review notes

**Fields**:
- `target_type: String` - Type of target ("commit", "file", "symbol")
- `target_id: Option<String>` - Specific target ID
- `author_id: Option<u64>` - Filter by author
- `severity: Option<String>` - Filter by severity
- `date_range: Option<TimeRange>` - Filter by date
- `include_explanation: bool` - Include LLM explanation

### AgentQuery

**Description**: Query for agent activity

**Fields**:
- `agent_id: Option<u64>` - Specific agent ID
- `session_id: Option<u64>` - Specific session ID
- `operation_type: Option<String>` - Filter by operation type
- `time_range: Option<TimeRange>` - Filter by time
- `include_summary: bool` - Include session summary

### ObservabilityQuery

**Description**: Query for observability data

**Fields**:
- `metric_name: String` - Metric name
- `aggregation: AggregationType` - Aggregation function
- `time_range: TimeRange` - Query time range
- `dimensions: HashMap<String, String>` - Metric dimensions
- `compare_baseline: bool` - Compare to baseline
- `detect_regressions: bool` - Detect regressions

## Functions

### NLToQueryConverter::new(llm_provider: LLMProvider) -> Result<Self, Error>

**Purpose**: Create new converter

**Algorithm**:
1. Build query extraction function schema
2. Create converter with LLM provider
3. Return instance

### NLToQueryConverter::convert(&mut self, natural_query: &str) -> Result<ConversionResult, Error>

**Purpose**: Convert NL query to structured query

**Algorithm**:
1. Build parameters: {"query": natural_query}
2. Call LLM with function calling
3. Validate response
4. Extract structured query from result
5. Return ConversionResult

**Error Conditions**:
- `Error::LLMUnavailable`: LLM provider not responding
- `Error::InvalidResponse`: Response doesn't match schema

### NLToQueryConverter::convert_with_fallback(&mut self, natural_query: &str) -> Result<ConversionResult, Error>

**Purpose**: Convert with rule-based fallback

**Algorithm**:
1. Try LLM-based conversion
2. On error or failure, fall back to rule-based
3. Return first successful result

### NLToQueryConverter::rule_based_convert(&mut self, input: &str) -> Result<ConversionResult, Error>

**Purpose**: Rule-based conversion for common patterns

**Algorithm**:
1. Convert input to lowercase
2. Match against known patterns:
   - "why did...change" -> ReviewExplain
   - "explain commit" -> ReviewExplain
   - "show review" -> ReviewNotes
   - "what did agent" -> AgentActivity
   - "regression" -> RegressionHunt
   - "performance/latency/throughput" -> Observability
   - "files about X" -> TopicSearch
3. Extract parameters from input
4. Build appropriate query
5. Return ConversionResult

### build_review_explain_query(&self, input: &str) -> Result<ConversionResult, Error>

**Purpose**: Build review explanation query

**Algorithm**:
1. Extract target (commit, file, symbol) from input
2. Create ReviewQuery with include_explanation=true
3. Return ConversionResult with query

### build_review_notes_query(&self, input: &str) -> Result<ConversionResult, Error>

**Purpose**: Build review notes query

**Algorithm**:
1. Extract target type and ID from input
2. Create ReviewQuery
3. Return ConversionResult with query

### build_agent_activity_query(&self, input: &str) -> Result<ConversionResult, Error>

**Purpose**: Build agent activity query

**Algorithm**:
1. Extract agent ID or "agent" keyword
2. Extract operation type if present
3. Create AgentQuery with include_summary=true
4. Return ConversionResult with query

### build_regression_hunt_query(&self, input: &str) -> Result<ConversionResult, Error>

**Purpose**: Build regression hunting query

**Algorithm**:
1. Extract metric name from input
2. Create ObservabilityQuery with detect_regressions=true
3. Return ConversionResult with query

### build_observability_query(&self, input: &str) -> Result<ConversionResult, Error>

**Purpose**: Build observability query

**Algorithm**:
1. Extract metric name, aggregation, time range
2. Create ObservabilityQuery
3. Return ConversionResult with query

### build_simple_query(&self, topic: &str, entity_type: Option<&str>) -> Result<ConversionResult, Error>

**Purpose**: Build simple topic search query

**Algorithm**:
1. Create TopicQuery with keywords from topic
2. Add entity type filter if specified
3. Return ConversionResult with query

### extract_phrase_after(input: &str, keyword: &str) -> Option<String>

**Purpose**: Extract phrase after keyword

**Algorithm**:
1. Find keyword in input
2. Extract text after keyword
3. Trim whitespace
4. Return phrase or None

## Function Schema for LLM

The LLM function schema for query extraction:

```json
{
  "name": "extract_query",
  "description": "Extract a structured query from natural language",
  "parameters": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "Natural language query"
      }
    },
    "required": ["query"]
  }
}
```

Expected response format:

```json
{
  "intent": "topic_search | review_explain | review_notes | agent_activity | observability | regression_hunt",
  "keywords": ["keyword1", "keyword2"],
  "target_type": "commit | file | symbol",
  "target_id": "specific identifier",
  "metric_name": "metric name",
  "aggregation": "sum | avg | min | max",
  "author_id": 123,
  "time_range": {
    "start": 1234567890,
    "end": 1234567890
  }
}
```

## Query Execution

### QueryExecutor

**Description**: Executes structured queries against database

**Fields**:
- `db: Db` - Database instance
- `cartridges: Cartridges` - Cartridge manager

**Methods**:
- `execute(&self, query: StructuredQuery) -> Result<QueryResult, Error>` - Execute query
- `explain(&self, query: StructuredQuery) -> Result<String, Error>` - Explain query plan

### QueryResult

**Description**: Result from query execution

**Fields**:
- `rows: Vec<QueryRow>` - Result rows
- `metadata: QueryMetadata` - Query metadata
- `explanation: Option<String>` - LLM explanation

## Dependencies

- **Uses**: LLM provider, cartridge system
- **Used by**: Plugin system, query API

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/queries/
  mod.rs              - Public API
  natural_language.rs - NLToQueryConverter
  planner.rs          - Query planner
  executor.rs         - Query executor
```

### Type Definitions

- **QueryIntent**: Enum with variants
- **StructuredQuery**: Enum with variant per query type or struct with Option fields
- **ConversionResult**: Struct with success/error states
- **Scope, TimeRange**: Structs with Option fields

### Concurrency

- **NLToQueryConverter**: Not thread-safe (uses allocator)
- Use `Arc<Mutex<NLToQueryConverter>>` for shared access
- LLM calls are async, use `tokio::spawn` if needed

### Key Decisions

- **Fallback strategy**: Rule-based for common patterns, LLM for complex
- **Query format**: Use enum variants for type-safe queries
- **Error handling**: Return ConversionResult with error details

### Implementation Notes

1. Use `regex` crate for pattern matching
2. Implement `FromStr` for QueryIntent
3. Add tracing for conversion steps
4. Cache common patterns

### Testing Strategy

**Unit tests for**:
- Intent classification
- Keyword extraction
- Time range parsing
- Target ID extraction

**Integration tests**:
- LLM-based conversion with mock responses
- Rule-based fallback
- End-to-end query execution

**Property tests**:
- Round-trip: query -> structured -> string
