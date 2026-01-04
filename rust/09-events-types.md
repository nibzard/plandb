# Event Types for AI Intelligence Layer

## Purpose

Defines typed events for AI agent tracking, code review, observability, and debugging. Events are versioned, time-travel-compatible, and logically separate from the hot database commit path to avoid performance impact on core operations.

## Types

### EventType

**Description**: Enumeration of all event types in the system

**Variants**:
- `AgentSessionStarted(u16 = 0x1000)`: Agent session initialization event
- `AgentSessionEnded(u16 = 0x1001)`: Agent session termination event
- `AgentOperation(u16 = 0x1002)`: Individual operation within a session
- `ReviewNote(u16 = 0x2000)`: Human or AI-generated review note
- `ReviewSummary(u16 = 0x2001)`: Generated summary of reviews
- `PerfSample(u16 = 0x3000)`: Performance metric sample point
- `PerfRegression(u16 = 0x3001)`: Detected performance regression
- `DebugSession(u16 = 0x4000)`: Debugging session event
- `DebugSnapshot(u16 = 0x4001)`: Debug state snapshot
- `VcsCommit(u16 = 0x5000)`: Version control commit event
- `VcsBranch(u16 = 0x5001)`: Branch operation event

**Invariants**:
- Event type values are unique 16-bit integers
- Event types are organized by category (agent, review, performance, debug, vcs)
- Upper 4 bits indicate category (0x1xxx for agent, 0x2xxx for review, etc.)

**Size**: 2 bytes (u16)

### EventVisibility

**Description**: Access control level for events

**Variants**:
- `Private(u8 = 0)`: Visible only to the creating agent
- `Team(u8 = 1)`: Shared within team/context
- `Public(u8 = 2)`: Publicly visible

**Invariants**: Visibility levels are ordered (private < team < public) for filtering

**Size**: 1 byte (u8)

### EventHeader

**Description**: Metadata header for all events

**Fields**:
- `event_id: u64` - Unique monotonically increasing event identifier
- `event_type: EventType` - Type identifier for this event
- `timestamp: i64` - Unix nanosecond timestamp
- `actor_id: u64` - Agent or human identifier who created this event
- `session_id: Option<u64>` - Optional session identifier for grouping
- `visibility: EventVisibility` - Access control level
- `payload_len: u32` - Size of payload in bytes

**Size**: 31 bytes total (8 + 2 + 8 + 8 + 1 + 1 + 8 + 1 + 2 padding + 4)

**Alignment**: 8-byte aligned for u64 fields

**Invariants**:
- `payload_len` must not exceed MAX_EVENT_PAYLOAD_SIZE (1MB default)
- `event_id` is assigned by the event store, not the caller
- `timestamp` is typically set at event creation time
- `session_id` is null for events not associated with a session

**Validation**: EventHeader.validate() returns error if payload exceeds maximum

### AgentSessionStarted

**Description**: Payload for agent session initialization

**Fields**:
- `agent_id: u64` - Unique identifier for the agent
- `agent_version: String` - Version string of the agent software
- `session_purpose: String` - Human-readable purpose of this session
- `metadata: HashMap<String, String>` - Additional key-value metadata

**Invariants**:
- `agent_version` and `session_purpose` are non-empty strings
- `metadata` keys are non-empty strings
- Total serialized size must fit within MAX_EVENT_PAYLOAD_SIZE

### AgentOperation

**Description**: Payload for individual agent operations

**Fields**:
- `operation_type: String` - Type of operation (e.g., "commit", "query", "analyze")
- `operation_id: u64` - Unique identifier for this operation
- `target_type: String` - Type of target (e.g., "file", "symbol", "cartridge")
- `target_id: String` - Identifier of the target (path, symbol name, etc.)
- `status: String` - Operation status (e.g., "started", "completed", "failed")
- `duration_ns: Option<i64>` - Optional duration in nanoseconds
- `metadata: HashMap<String, String>` - Additional key-value metadata

**Invariants**:
- `operation_type`, `target_type`, `target_id`, `status` are non-empty
- `duration_ns` is present only for completed operations
- Status values follow lifecycle: started -> (completed|failed)

### ReviewNote

**Description**: Payload for code review notes

**Fields**:
- `author: u64` - Agent or human ID who created the review
- `target_type: String` - Type of target being reviewed ("commit", "file", "symbol", "pr")
- `target_id: String` - Identifier of the target (hash, path, etc.)
- `note_text: String` - Review note content
- `visibility: EventVisibility` - Who can see this review
- `references: Vec<String>` - IDs of related items
- `created_at: i64` - Unix nanosecond timestamp

**Invariants**:
- `note_text` is non-empty
- `target_type` must be one of: "commit", "file", "symbol", "pr"
- `references` can be empty
- `created_at` is typically set by the system

### ReviewSummary

**Description**: Payload for AI-generated review summaries

**Fields**:
- `generator_id: u64` - Agent ID that generated the summary
- `target_type: String` - Type of target being summarized
- `target_id: String` - Identifier of the target
- `summary_text: String` - Generated summary content
- `confidence: f32` - Confidence score 0.0 to 1.0
- `model_id: String` - LLM model used for generation
- `prompt_hash: Option<String>` - Optional prompt identifier for reproducibility
- `created_at: i64` - Unix nanosecond timestamp

**Invariants**:
- `confidence` is in range [0.0, 1.0]
- `summary_text` is non-empty
- `model_id` identifies the LLM used

### PerfSample

**Description**: Payload for performance metric samples

**Fields**:
- `metric_name: String` - Name of the metric (e.g., "latency", "throughput")
- `dimensions: HashMap<String, String>` - Metric dimensions (query_name, codepath, etc.)
- `value: f64` - Metric value
- `unit: String` - Unit of measurement (e.g., "ms", "ops/sec")
- `timestamp_window: TimeWindow` - Time range this sample represents
- `correlation_hints: CorrelationHints` - Hints for correlating with commits/sessions

**Invariants**:
- `metric_name` and `unit` are non-empty
- `dimensions` can be empty
- `timestamp_window.start <= timestamp_window.end`

### TimeWindow

**Description**: Time range for metric aggregation

**Fields**:
- `start: i64` - Start of window in nanoseconds
- `end: i64` - End of window in nanoseconds

**Size**: 16 bytes

### CorrelationHints

**Description**: Hints for correlating metrics with other events

**Fields**:
- `commit_range: Option<String>` - Commit range (e.g., "abc123..def456")
- `session_ids: Vec<u64>` - Related session IDs

**Invariants**:
- `commit_range` format is "start_hash..end_hash" when present
- `session_ids` can be empty

### PerfRegression

**Description**: Payload for detected performance regressions

**Fields**:
- `metric_name: String` - Name of the regressed metric
- `baseline_value: f64` - Baseline value before regression
- `current_value: f64` - Current value showing regression
- `regression_percent: f32` - Percentage of regression
- `severity: String` - Severity level ("minor", "moderate", "severe")
- `detected_at: i64` - When regression was detected
- `likely_cause: Option<String>` - Suspected cause
- `correlated_commits: Vec<String>` - Commits correlated with regression

**Invariants**:
- `regression_percent > 0`
- `severity` is one of: "minor", "moderate", "severe"
- `correlated_commits` can be empty

### DebugSession

**Description**: Payload for debugging session events

**Fields**:
- `tool: String` - Debugger tool name ("lldb", "gdb", "python-debugger")
- `session_id: u64` - Unique session identifier
- `breakpoints: Vec<Breakpoint>` - Active breakpoints
- `stack_summary: Option<String>` - Optional sampled stack trace
- `references: DebugReferences` - Related commit IDs and symbol names

**Invariants**:
- `tool` is non-empty
- `breakpoints` can be empty

### Breakpoint

**Description**: Breakpoint definition

**Fields**:
- `file_path: String` - Path to source file
- `line: u32` - Line number (1-indexed)
- `condition: Option<String>` - Optional breakpoint condition
- `hit_count: u32` - Number of times breakpoint was hit

**Invariants**:
- `file_path` is non-empty
- `line >= 1`

### DebugReferences

**Description**: References for debugging session

**Fields**:
- `commit_ids: Vec<String>` - Related commit hashes
- `symbol_names: Vec<String>` - Related symbol names

**Invariants**: Both vectors can be empty

### VcsCommit

**Description**: Payload for version control commit events

**Fields**:
- `commit_hash: String` - Full commit hash
- `author_id: u64` - Author identifier
- `commit_message: String` - Commit message text
- `changed_files: Vec<String>` - List of changed file paths
- `parent_commits: Vec<String>` - Parent commit hashes
- `branch: String` - Branch name
- `timestamp: i64` - Commit timestamp

**Invariants**:
- `commit_hash` and `branch` are non-empty
- `changed_files` and `parent_commits` can be empty

### EventFilter

**Description**: Query filter for event searches

**Fields**:
- `event_types: Option<Vec<EventType>>` - Filter by event types
- `actor_id: Option<u64>` - Filter by actor
- `session_id: Option<u64>` - Filter by session
- `start_time: Option<i64>` - Filter events after this time
- `end_time: Option<i64>` - Filter events before this time
- `visibility_min: Option<EventVisibility>` - Minimum visibility level
- `target_type: Option<String>` - Filter by target type (for reviews)
- `target_id: Option<String>` - Filter by target ID (for reviews)
- `limit: Option<usize>` - Maximum number of results

**Invariants**:
- All fields are optional
- If `start_time` and `end_time` are both set, `start_time <= end_time`
- `limit` restricts result size but does not guarantee that many results

### EventResult

**Description**: Query result containing header and payload

**Fields**:
- `header: EventHeader` - Event metadata
- `payload: Vec<u8>` - Serialized payload data

**Invariants**:
- `payload.len() == header.payload_len`
- Caller must deserialize payload based on `header.event_type`

## Constants

### MAX_EVENT_PAYLOAD_SIZE

**Value**: 1,048,576 bytes (1 MB)

**Purpose**: Maximum size for event payloads

**Configurability**: Can be overridden in EventStore configuration

## Functions

### EventHeader::validate(&self) -> Result<(), Error>

**Purpose**: Validates event header constraints

**Returns**: Ok(()) if valid, Err(Error::PayloadTooLarge) if payload exceeds maximum

**Algorithm**:
1. Check if `self.payload_len > MAX_EVENT_PAYLOAD_SIZE`
2. If exceeded, return error
3. Otherwise return success

## Serialization Format

All event payloads are serialized using length-prefixed encoding:

1. For strings: u32 length prefix + UTF-8 bytes
2. For optional values: u8 presence flag + value if present
3. For maps/vectors: u32 count + entries
4. For integers: little-endian encoding
5. For floats: IEEE 754 binary representation

Example AgentSessionStarted payload:
```
[u32: agent_version_len][u8...: agent_version]
[u32: session_purpose_len][u8...: session_purpose]
[u32: metadata_count]
  For each entry:
    [u32: key_len][u8...: key]
    [u32: value_len][u8...: value]
```

## Dependencies

- **Uses**: None (core types)
- **Used by**: EventStore, EventManager, plugin system

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/
  events/
    mod.rs          - Public re-exports
    types.rs        - All type definitions
    storage.rs      - Event storage backend
    manager.rs      - High-level event API
```

### Type Definitions

- **EventType**: Use `#[repr(u16)] enum` with explicit discriminants
- **EventVisibility**: Use `#[repr(u8)] enum` with explicit discriminants
- **EventHeader**: Use `#[repr(C)] struct` for predictable layout
- **String fields**: Use `String` for owned, `&str` for borrowed
- **Optional fields**: Use `Option<T>` with `#[serde(skip_serializing_if = "Option::is_none")]`

### Concurrency

- Event types are `Send + Sync` if all fields are `Send + Sync`
- String and HashMap are `Send + Sync` in Rust
- No interior mutability in event types

### Key Decisions

- **Enum vs String for EventType**: Use enum for type safety and exhaustive matching
- **u64 for IDs**: Use explicit newtype pattern (`EventId(u64)`) for type safety
- **HashMap for metadata**: Use `std::collections::HashMap<String, String>` for flexibility
- **i64 for timestamps**: Use nanosecond precision for consistency

### Implementation Notes

1. Create derive macros for `Debug`, `Clone`, `Serialize`, `Deserialize`
2. Implement `Default` for `EventFilter` with all `None` values
3. Use `thiserror` for validation errors
4. Consider builder pattern for complex event construction
5. Use `#[non_exhaustive]` on enums to allow future additions

### Testing Strategy

**Unit tests needed for**:
- EventHeader validation with valid and oversized payloads
- EventType round-trip serialization
- EventVisibility ordering (private < team < public)
- TimeWindow validation (start <= end)

**Property tests for**:
- Round-trip serialization/deserialization for all event types
- Payload size limits are enforced

**Integration scenarios**:
- Event creation through EventManager
- Query with multiple filter conditions
- Time-travel queries with timestamp ranges
