# Multi-Agent Session Correlation

## Purpose

Multi-agent session correlation enables tracking and analysis of interactions across multiple AI agents in orchestrated workflows. This component provides the infrastructure for correlating events, operations, and context across agent sessions, enabling end-to-end observability, debugging, and performance analysis of multi-agent AI systems.

## Core Concepts

### Agent Session

An agent session represents a sequence of operations performed by a single AI agent with a unique identifier. Sessions capture the temporal context of agent work, including start time, end time, parent relationships, and associated events.

### Correlation

Correlation links related operations across multiple agent sessions, enabling reconstruction of complete workflows that span multiple agents. This is essential for understanding cascading effects, debugging distributed issues, and analyzing system-wide performance.

### Causal Chain

A causal chain represents the sequence of cause-and-effect relationships between operations. By tracking parent-child relationships and cross-agent dependencies, we can reconstruct how a decision or event in one agent triggered downstream operations.

## Types

### AgentId

**Description**: Unique identifier for an AI agent

**Representation**: Newtype wrapper around `String`

**Format**: `{agent_type}:{instance_id}`

**Examples**:
- "coder:agent-001"
- "reviewer:agent-042"
- "planner:main"

**Invariants**: Contains exactly one colon separator

### SessionId

**Description**: Unique identifier for an agent session

**Representation**: Newtype wrapper around `String`

**Format**: `{agent_id}:{sequence}`

**Examples**:
- "coder:agent-001:session-123"
- "reviewer:agent-042:session-456"

**Invariants**: Contains at least two colon separators

### OperationId

**Description**: Unique identifier for an operation within a session

**Representation**: Newtype wrapper around `String`

**Format**: `{session_id}:op-{sequence}`

**Examples**:
- "coder:agent-001:session-123:op-1"
- "coder:agent-001:session-123:op-2"

**Invariants**: Contains "op-" prefix followed by numeric sequence

### CorrelationId

**Description**: Unique identifier for correlating related operations across sessions

**Representation**: Newtype wrapper around `String`

**Format**: UUID v4 or `{trace_id}:{span_id}`

**Examples**:
- "550e8400-e29b-41d4-a716-446655440000"
- "trace-abc123:span-def456"

**Invariants**: Either valid UUID format or contains colon separator

### AgentSession

**Description**: Complete agent session record

**Fields**:
- `session_id: SessionId` - Unique session identifier
- `agent_id: AgentId` - Agent that owns this session
- `parent_session_id: Option<SessionId>` - Parent session if this is a sub-session
- `root_session_id: Option<SessionId>` - Root session of this session tree
- `start_time: i64` - Session start timestamp (milliseconds)
- `end_time: Option<i64>` - Session end timestamp (None if ongoing)
- `status: SessionStatus` - Current session status
- `metadata: HashMap<String, String>` - Session metadata
- `tags: Vec<String>` - Session tags for grouping
- `operations: Vec<OperationId>` - Operations in this session

**Invariants**:
- `start_time > 0`
- `end_time` is None or `end_time > start_time`
- `parent_session_id` is None or refers to valid session
- `root_session_id` is None or refers to root ancestor

### SessionStatus

**Description**: Current status of agent session

**Variants**:
- `Pending` - Session created but not started
- `Running` - Session actively processing
- `Suspended` - Session paused (awaiting external input)
- `Completed` - Session finished successfully
- `Failed` - Session terminated with error
- `Cancelled` - Session cancelled by user or system

### Operation

**Description**: Single operation within a session

**Fields**:
- `operation_id: OperationId` - Unique operation identifier
- `session_id: SessionId` - Containing session
- `parent_operation_id: Option<OperationId>` - Parent operation if nested
- `correlation_id: CorrelationId` - Correlation ID for cross-session linking
- `operation_type: String` - Type of operation (e.g., "read", "write", "query")
- `start_time: i64` - Operation start timestamp
- `end_time: Option<i64>` - Operation end timestamp (None if ongoing)
- `status: OperationStatus` - Current operation status
- `result: Option<OperationResult>` - Operation result if completed
- `metadata: HashMap<String, String>` - Operation metadata
- `tags: Vec<String>` - Operation tags

**Invariants**:
- `start_time > 0`
- `end_time` is None or `end_time > start_time`
- `parent_operation_id` refers to operation in same session or None

### OperationStatus

**Description**: Current status of operation

**Variants**:
- `Pending` - Operation queued but not started
- `Running` - Operation in progress
- `Completed` - Operation finished successfully
- `Failed(ErrorInfo)` - Operation failed with error info
- `Cancelled` - Operation cancelled
- `Timeout` - Operation exceeded time limit

### ErrorInfo

**Description**: Error information for failed operations

**Fields**:
- `error_code: String` - Error code/identifier
- `error_message: String` - Human-readable error message
- `error_type: String` - Error type/category
- `stack_trace: Option<String>` - Optional stack trace
- `context: HashMap<String, String>` - Additional error context

### OperationResult

**Description**: Result of completed operation

**Fields**:
- `success: bool` - Whether operation succeeded
- `duration_ms: i64` - Operation duration in milliseconds
- `result_size_bytes: Option<usize>` - Size of result (if applicable)
- `result_count: Option<usize>` - Number of results (if applicable)
- `metadata: HashMap<String, String>` - Result metadata

**Invariants**:
- `duration_ms >= 0`

### CorrelationLink

**Description**: Link between correlated operations across sessions

**Fields**:
- `correlation_id: CorrelationId` - Correlation identifier
- `from_operation: OperationId` - Source operation
- `to_operation: OperationId` - Target operation
- `link_type: CorrelationLinkType` - Type of relationship
- `metadata: HashMap<String, String>` - Link metadata

**Invariants**:
- `from_operation != to_operation`

### CorrelationLinkType

**Description**: Type of correlation relationship

**Variants**:
- `ParentChild` - Direct parent-child relationship
- `Causal` - Cause-effect relationship
- `DataFlow` - Data passed between operations
- `Trigger` - One operation triggered another
- `Parallel` - Parallel operations in same workflow
- `Retry` - Retry of failed operation
- `Compensation` - Compensating operation (rollback, undo)

### SessionTree

**Description**: Hierarchical tree of related sessions

**Fields**:
- `root_session_id: SessionId` - Root session of tree
- `sessions: HashMap<SessionId, AgentSession>` - All sessions in tree
- `children: HashMap<SessionId, Vec<SessionId>>` - Parent-to-children mapping
- `depth: usize` - Maximum depth of tree

**Invariants**:
- `root_session_id` exists in `sessions`
- `sessions` is non-empty
- No cycles in parent-child relationships

### CorrelationGraph

**Description**: Graph of correlated operations across sessions

**Fields**:
- `nodes: HashMap<OperationId, Operation>` - All operations
- `edges: Vec<CorrelationLink>` - Correlation links
- `adjacency: HashMap<OperationId, Vec<OperationId>>` - Adjacency list
- `roots: Vec<OperationId>` - Root operations (no incoming edges)

**Invariants**:
- All edge endpoints exist in `nodes`
- `adjacency` keys match node operation IDs
- `roots` contains operations with no incoming edges

### WorkflowTrace

**Description**: Complete end-to-end workflow trace

**Fields**:
- `trace_id: CorrelationId` - Unique trace identifier
- `workflow_name: String` - Workflow name
- `root_operation: OperationId` - Root operation of workflow
- `operations: Vec<OperationId>` - All operations in trace
- `sessions: Vec<SessionId>` - All sessions involved
- `start_time: i64` - Trace start time
- `end_time: Option<i64>` - Trace end time
- `status: WorkflowStatus` - Trace status
- `metadata: HashMap<String, String>` - Trace metadata

**Invariants**:
- `operations` is non-empty
- `sessions` is non-empty
- `start_time > 0`
- `end_time` is None or `end_time > start_time`

### WorkflowStatus

**Description**: Status of workflow trace

**Variants**:
- `InProgress` - Workflow actively running
- `Completed` - All operations completed successfully
- `PartialFailure` - Some operations failed
- `Failed` - Workflow failed to complete
- `Cancelled` - Workflow cancelled

### SessionMetrics

**Description**: Metrics computed for a session

**Fields**:
- `session_id: SessionId` - Session identifier
- `operation_count: usize` - Total operations
- `completed_count: usize` - Completed operations
- `failed_count: usize` - Failed operations
- `total_duration_ms: i64` - Total session duration
- `avg_operation_duration_ms: f64` - Average operation duration
- `p50_duration_ms: f64` - Median operation duration
- `p95_duration_ms: f64` - 95th percentile duration
- `p99_duration_ms: f64` - 99th percentile duration

**Invariants**:
- `operation_count >= completed_count + failed_count`
- `total_duration_ms >= 0`
- All percentile values are non-negative

### CorrelationQuery

**Description**: Query for finding correlated operations

**Fields**:
- `correlation_id: Option<CorrelationId>` - Filter by correlation ID
- `session_id: Option<SessionId>` - Filter by session
- `agent_id: Option<AgentId>` - Filter by agent
- `time_range: Option<(i64, i64)>` - Time range filter
- `operation_type: Option<String>` - Filter by operation type
- `status: Option<OperationStatus>` - Filter by operation status
- `tags: Vec<String>` - Filter by tags (AND logic)
- `depth_limit: Option<usize>` - Limit traversal depth
- `limit: Option<usize>` - Maximum results

**Invariants**:
- `time_range` is None or `start < end`
- `limit` is None or `> 0`
- `depth_limit` is None or `> 0`

## Functions

### create_session(agent_id: AgentId, parent_session_id: Option<SessionId>) -> Result<AgentSession, Error>

**Purpose**: Create new agent session

**Parameters**:
- `agent_id: AgentId` - Agent creating this session
- `parent_session_id: Option<SessionId>` - Parent session if nested

**Returns**: `Result<AgentSession, Error>` - New session or error

**Algorithm**:
1. Generate unique session_id: "{agent_id}:session-{sequence}"
2. Determine root_session_id:
   a. If parent_session_id is None, root_session_id is session_id
   b. Otherwise, inherit root_session_id from parent
3. Set start_time to current timestamp
4. Set status to Pending
5. Initialize empty operations Vec and metadata HashMap
6. Create AgentSession with generated fields
7. Return session

**Error Conditions**:
- `InvalidParentSession`: When parent_session_id refers to non-existent session

**Concurrency**: Thread-safe if session ID generation is atomic

### start_session(session: &mut AgentSession) -> Result<(), Error>

**Purpose**: Mark session as started

**Parameters**:
- `session: &mut AgentSession` - Session to start

**Returns**: `Result<(), Error>` - Success or error

**Algorithm**:
1. Validate session status is Pending
2. Update status to Running
3. Set start_time to current timestamp
4. Return success

**Error Conditions**:
- `InvalidSessionState`: When session is not in Pending state

**Concurrency**: Requires exclusive access to session

### complete_session(session: &mut AgentSession) -> Result<(), Error>

**Purpose**: Mark session as completed

**Parameters**:
- `session: &mut AgentSession` - Session to complete

**Returns**: `Result<(), Error>` - Success or error

**Algorithm**:
1. Validate session status is Running or Suspended
2. Update status to Completed
3. Set end_time to current timestamp
4. Return success

**Error Conditions**:
- `InvalidSessionState`: When session is not Running or Suspended

**Concurrency**: Requires exclusive access to session

### create_operation(session_id: SessionId, operation_type: String, parent_operation_id: Option<OperationId>, correlation_id: CorrelationId) -> Result<Operation, Error>

**Purpose**: Create new operation in session

**Parameters**:
- `session_id: SessionId` - Containing session
- `operation_type: String` - Type of operation
- `parent_operation_id: Option<OperationId>` - Parent operation if nested
- `correlation_id: CorrelationId` - Correlation ID for cross-session linking

**Returns**: `Result<Operation, Error>` - New operation or error

**Algorithm**:
1. Generate unique operation_id: "{session_id}:op-{sequence}"
2. Set start_time to current timestamp
3. Set status to Pending
4. Initialize empty metadata HashMap and tags Vec
5. Create Operation with generated fields
6. Return operation

**Error Conditions**:
- `InvalidParentOperation`: When parent_operation_id refers to non-existent operation

**Concurrency**: Thread-safe if operation ID generation is atomic

### start_operation(operation: &mut Operation) -> Result<(), Error>

**Purpose**: Mark operation as started

**Parameters**:
- `operation: &mut Operation` - Operation to start

**Returns**: `Result<(), Error>` - Success or error

**Algorithm**:
1. Validate operation status is Pending
2. Update status to Running
3. Update start_time to current timestamp
4. Return success

**Error Conditions**:
- `InvalidOperationState`: When operation is not in Pending state

**Concurrency**: Requires exclusive access to operation

### complete_operation(operation: &mut Operation, result: OperationResult) -> Result<(), Error>

**Purpose**: Mark operation as completed with result

**Parameters**:
- `operation: &mut Operation` - Operation to complete
- `result: OperationResult` - Operation result

**Returns**: `Result<(), Error>` - Success or error

**Algorithm**:
1. Validate operation status is Running
2. Update status to Completed
3. Set end_time to current timestamp
4. Set result to provided result
5. Return success

**Error Conditions**:
- `InvalidOperationState`: When operation is not in Running state

**Concurrency**: Requires exclusive access to operation

### fail_operation(operation: &mut Operation, error: ErrorInfo) -> Result<(), Error>

**Purpose**: Mark operation as failed

**Parameters**:
- `operation: &mut Operation` - Operation to fail
- `error: ErrorInfo` - Error information

**Returns**: `Result<(), Error>` - Success or error

**Algorithm**:
1. Update status to Failed(error)
2. Set end_time to current timestamp
3. Return success

**Error Conditions**: None

**Concurrency**: Requires exclusive access to operation

### correlate_operations(from: OperationId, to: OperationId, link_type: CorrelationLinkType, correlation_id: CorrelationId) -> Result<CorrelationLink, Error>

**Purpose**: Create correlation link between two operations

**Parameters**:
- `from: OperationId` - Source operation
- `to: OperationId` - Target operation
- `link_type: CorrelationLinkType` - Type of relationship
- `correlation_id: CorrelationId` - Correlation identifier

**Returns**: `Result<CorrelationLink, Error>` - Correlation link or error

**Algorithm**:
1. Validate from and refer to valid operations
2. Validate from != to
3. Create CorrelationLink with provided fields
4. Initialize empty metadata HashMap
5. Return link

**Error Conditions**:
- `OperationNotFound`: When from or to operation doesn't exist
- `SelfCorrelation`: When from equals to

**Concurrency**: Requires exclusive access to correlation graph

### build_session_tree(sessions: HashMap<SessionId, AgentSession>) -> Result<SessionTree, Error>

**Purpose**: Build hierarchical tree from sessions

**Parameters**:
- `sessions: HashMap<SessionId, AgentSession>` - All sessions

**Returns**: `Result<SessionTree, Error>` - Session tree or error

**Algorithm**:
1. If sessions is empty, return error
2. Find root session (session with no parent or parent not in map)
3. Initialize children HashMap
4. For each session:
   a. If session has parent in sessions, add to parent's children list
5. Compute depth via traversal from root
6. Create SessionTree structure
7. Return tree

**Error Conditions**:
- `NoSessions`: When sessions HashMap is empty
- `CycleDetected`: When cycles exist in parent relationships

**Concurrency**: Read-only access to sessions, thread-safe

### trace_workflow(root_operation: OperationId, operations: HashMap<OperationId, Operation>, links: Vec<CorrelationLink>) -> Result<WorkflowTrace, Error>

**Purpose**: Trace complete workflow from root operation

**Parameters**:
- `root_operation: OperationId` - Root operation to trace from
- `operations: HashMap<OperationId, Operation>` - All operations
- `links: Vec<CorrelationLink>` - Correlation links

**Returns**: `Result<WorkflowTrace, Error>` - Workflow trace or error

**Algorithm**:
1. Validate root_operation exists in operations
2. Initialize workflow_trace with root operation
3. Build adjacency list from links
4. Perform BFS/DFS traversal from root:
   a. Follow all outgoing correlation links
   b. Add discovered operations to trace
   c. Track visited operations to avoid cycles
5. Collect all unique session IDs from operations
6. Determine time range from operation timestamps
7. Determine status from operation statuses
8. Return WorkflowTrace

**Error Conditions**:
- `RootOperationNotFound`: When root_operation doesn't exist
- `CycleDetected`: When cycles exist in correlation links

**Concurrency**: Read-only access to operations and links, thread-safe

### query_correlations(query: CorrelationQuery, operations: HashMap<OperationId, Operation>, links: Vec<CorrelationLink>) -> Vec<Operation>

**Purpose**: Query for correlated operations

**Parameters**:
- `query: CorrelationQuery` - Query specification
- `operations: HashMap<OperationId, Operation>` - All operations
- `links: Vec<CorrelationLink>` - Correlation links

**Returns**: `Vec<Operation>` - Matching operations

**Algorithm**:
1. Initialize candidate set with all operations
2. Filter by correlation_id if specified
3. Filter by session_id if specified
4. Filter by agent_id if specified (match session's agent_id)
5. Filter by time_range if specified (overlap with [start, end])
6. Filter by operation_type if specified
7. Filter by status if specified
8. Filter by tags if specified (all tags must match)
9. Apply depth limit by traversing from matching roots
10. Apply result limit
11. Return filtered operations

**Error Conditions**: None (returns empty Vec if no matches)

**Concurrency**: Read-only access to operations and links, thread-safe

### compute_session_metrics(session: &AgentSession, operations: &[Operation]) -> SessionMetrics

**Purpose**: Compute metrics for session

**Parameters**:
- `session: &AgentSession` - Session to analyze
- `operations: &[Operation]` - Operations in session

**Returns**: `SessionMetrics` - Computed metrics

**Algorithm**:
1. Collect durations from completed operations
2. Compute total_duration_ms: session.end_time - session.start_time
3. Compute counts:
   a. operation_count: operations.len()
   b. completed_count: operations with Completed status
   c. failed_count: operations with Failed status
4. If durations is non-empty:
   a. Compute avg_duration_ms: mean of durations
   b. Sort durations, compute percentiles (p50, p95, p99)
5. Otherwise, set avg and percentiles to 0.0
6. Return SessionMetrics

**Error Conditions**: None (returns zero metrics for empty session)

**Concurrency**: Read-only access to session and operations, thread-safe

### find_root_session(session: &AgentSession, sessions: &HashMap<SessionId, AgentSession>) -> Option<AgentSession>

**Purpose**: Find root session of session tree

**Parameters**:
- `session: &AgentSession` - Starting session
- `sessions: &HashMap<SessionId, AgentSession>` - All sessions

**Returns**: `Option<AgentSession>` - Root session or None if cycle detected

**Algorithm**:
1. Initialize current = session
2. Initialize visited HashSet
3. Loop:
   a. Add current.session_id to visited
   b. If current.parent_session_id is None, return Some(current)
   c. If parent_session_id in visited, return None (cycle)
   d. Look up parent_session_id in sessions
   e. If not found, return None (orphan)
   f. Set current = parent session
4. Return root session

**Error Conditions**: None (returns None on cycles or orphans)

**Concurrency**: Read-only access to sessions, thread-safe

### get_session_children(session_id: SessionId, sessions: &HashMap<SessionId, AgentSession>) -> Vec<AgentSession>

**Purpose**: Get direct children of session

**Parameters**:
- `session_id: SessionId` - Parent session
- `sessions: &HashMap<SessionId, AgentSession>` - All sessions

**Returns**: `Vec<AgentSession>` - Child sessions

**Algorithm**:
1. Initialize empty results Vec
2. For each session in sessions:
   a. If session.parent_session_id equals session_id, add to results
3. Return results

**Error Conditions**: None (returns empty Vec if no children)

**Concurrency**: Read-only access to sessions, thread-safe

### get_operation_chain(operation: &Operation, operations: &HashMap<OperationId, Operation>) -> Vec<Operation>

**Purpose**: Get chain of parent operations

**Parameters**:
- `operation: &Operation` - Starting operation
- `operations: &HashMap<OperationId, Operation>` - All operations

**Returns**: `Vec<Operation>` - Operation chain from root to operation

**Algorithm**:
1. Initialize chain Vec with operation
2. Initialize current = operation
3. Loop:
   a. If current.parent_operation_id is None, break
   b. Look up parent_operation_id in operations
   c. If not found, break (orphan)
   d. Prepend parent to chain
   e. Set current = parent
4. Return chain

**Error Conditions**: None (returns partial chain if orphans exist)

**Concurrency**: Read-only access to operations, thread-safe

### correlate_by_data_flow(from_operation: OperationId, to_operation: OperationId, data_description: String) -> Result<CorrelationLink, Error>

**Purpose**: Create data flow correlation between operations

**Parameters**:
- `from_operation: OperationId` - Source operation
- `to_operation: OperationId` - Target operation
- `data_description: String` - Description of data passed

**Returns**: `Result<CorrelationLink, Error>` - Correlation link or error

**Algorithm**:
1. Generate correlation_id as new UUID
2. Create CorrelationLink with DataFlow link_type
3. Add data_description to metadata
4. Return link

**Error Conditions**:
- `OperationNotFound`: When operations don't exist

**Concurrency**: Requires exclusive access to correlation graph

### generate_correlation_id() -> CorrelationId

**Purpose**: Generate new correlation ID

**Returns**: `CorrelationId` - New correlation ID

**Algorithm**:
1. Generate UUID v4
2. Wrap in CorrelationId newtype
3. Return correlation ID

**Error Conditions**: None (UUID generation is infallible)

**Concurrency**: Thread-safe (UUID is random)

### validate_session_tree(tree: &SessionTree) -> Result<(), Error>

**Purpose**: Validate session tree integrity

**Parameters**:
- `tree: &SessionTree` - Session tree to validate

**Returns**: `Result<(), Error>` - Success or validation error

**Algorithm**:
1. Validate root_session_id exists in sessions
2. Validate all parent references are valid
3. Validate no cycles exist (DFS traversal)
4. Validate depth is correct
5. Validate all children references are bidirectional
6. Return success or error

**Error Conditions**:
- `InvalidRoot`: When root_session_id doesn't exist
- `BrokenParentLink`: When parent reference is invalid
- `CycleDetected`: When cycles exist

**Concurrency**: Read-only access to tree, thread-safe

## Invariants

- Session IDs are unique and never reused
- Operation IDs are unique and never reused
- Correlation IDs are unique across the system
- Parent-child relationships are acyclic
- Session timestamps are monotonically increasing (start_time < end_time)
- Operation timestamps respect parent-child ordering (child start >= parent start)
- All operations belong to valid sessions
- All correlation links reference valid operations

## Dependencies

- **Uses**: Core types (Lsn, Timestamp), Entity types for agent tracking
- **Used by**: Workflow orchestration, debugging tools, analytics systems

## Rust Implementation Guidance

### Module Structure

The session correlation module should be organized as follows:

```
northstar-core/src/correlation/
  mod.rs              - Public API exports
  types.rs            - Core type definitions
  session.rs          - Session management
  operation.rs        - Operation tracking
  correlation.rs      - Correlation graph management
  tree.rs             - Session tree operations
  trace.rs            - Workflow tracing
  query.rs            - Correlation query engine
  metrics.rs          - Metrics computation
  validate.rs         - Validation functions
```

### Type Definitions

- **AgentId**: Newtype `struct AgentId(String)`
- **SessionId**: Newtype `struct SessionId(String)`
- **OperationId**: Newtype `struct OperationId(String)`
- **CorrelationId**: Newtype `struct CorrelationId(String)`
- **AgentSession**: Struct with session_id, agent_id, parent_session_id, timestamps, status
- **Operation**: Struct with operation_id, session_id, parent_operation_id, correlation_id, timestamps, status
- **CorrelationLink**: Struct with from_operation, to_operation, link_type, correlation_id

### Key Implementation Patterns

1. **ID Generation**: Use atomic counters for sequence numbers, combine with agent/instance IDs
2. **Graph Storage**: Use HashMap<OperationId, Operation> for nodes, Vec<CorrelationLink> for edges
3. **Tree Traversal**: Use iterative DFS/BFS to avoid stack overflow on deep trees
4. **Validation**: Perform cycle detection using visited sets during traversal
5. **Query Filtering**: Apply filters incrementally, early termination on depth limit

### Concurrency Model

- **Session Creation**: Use `Arc<RwLock<SessionRegistry>>` for shared session storage
- **Operation Tracking**: Each session has its own operations Vec, protected by RwLock
- **Correlation Graph**: Shared graph protected by RwLock for read-heavy workloads
- **ID Generation**: Use `AtomicU64` for sequence counters to ensure uniqueness

### Performance Considerations

1. **ID Generation**: Pre-allocate ID blocks to reduce contention on atomic counter
2. **Graph Traversal**: Use iterative algorithms with explicit stacks to avoid recursion
3. **Query Optimization**: Build indexes on frequently queried fields (agent_id, status)
4. **Cache Results**: Cache session trees and workflow traces to avoid recomputation
5. **Batch Operations**: Support batch correlation link creation for efficiency

### Key Decisions

- **ID Format**: String-based IDs with colon separators for readability and parsing
- **Correlation ID**: UUID v4 for guaranteed global uniqueness
- **Graph Storage**: Adjacency list representation (HashMap + Vec) for flexibility
- **Status Tracking**: Enum variants for type-safe state representation
- **Metadata**: HashMap<String, String> for extensibility without schema changes

### External Dependencies

- **uuid**: For UUID v4 generation of correlation IDs
- **serde**: For serialization of session and operation data
- **dashmap**: Optional, for concurrent HashMap performance
- **petgraph**: Optional, for graph algorithms (traversal, cycle detection)

### Testing Strategy

**Unit tests for**:
- Session creation and lifecycle (start, complete, fail)
- Operation creation and lifecycle
- Correlation link creation
- Session tree building from flat session list
- Workflow trace from root operation

**Property tests for**:
- ID uniqueness (no duplicate IDs ever generated)
- Tree acyclicity (no cycles in parent-child relationships)
- Timestamp monotonicity (start <= end, parent start <= child start)
- Query correctness (filters return correct subsets)

**Integration scenarios**:
- Multi-agent workflow tracing across sessions
- Correlation graph construction from real workflow
- Deep session tree traversal (100+ levels)
- High correlation link count (10k+ links)

**Stress tests**:
- Concurrent session creation (100 threads)
- Concurrent operation tracking (1000 operations/sec)
- Large correlation graph query performance

### Error Handling

- `InvalidSessionState`: When state transition is invalid
- `InvalidOperationState`: When operation state transition is invalid
- `OperationNotFound`: When referenced operation doesn't exist
- `SessionNotFound`: When referenced session doesn't exist
- `CycleDetected`: When cycles detected in tree or graph
- `SelfCorrelation`: When operation correlated to itself

Use `thiserror` crate for error types with derive macros.

### Implementation Notes

1. Implement `Display` for all ID types for debugging
2. Use `derive(Debug, Clone, PartialEq)` for data types
3. Implement `FromStr` for ID types for parsing from strings
4. Add builder pattern for AgentSession and Operation construction
5. Use `Arc<str>` for string deduplication in high-cardinality scenarios
6. Implement custom serializers for timestamp formatting

### Storage Considerations

- **Session Persistence**: Sessions should be persisted to database for historical analysis
- **Operation Archive**: Completed operations can be archived to cold storage
- **Correlation Retention**: Correlation links may be retained for audit purposes
- **Cleanup Policy**: Implement TTL-based cleanup for old sessions and operations

### Integration Points

- **Database**: Store sessions and operations in structured format (cartridges or tables)
- **Events**: Emit events for session lifecycle changes (created, started, completed)
- **Metrics**: Export session and operation metrics to monitoring systems
- **Tracing**: Integrate with distributed tracing systems (OpenTelemetry, Jaeger)
