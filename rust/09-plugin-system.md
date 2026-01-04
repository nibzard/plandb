# Plugin System for AI Intelligence Layer

## Purpose

Manages plugin lifecycle, registration, and execution for extending NorthstarDB with AI capabilities. Plugins provide hooks for commit processing, query optimization, scheduled maintenance, and event-based operations. The system enforces performance isolation, resource quotas, and graceful degradation.

## Types

### PluginManager

**Description**: Central registry and executor for all plugins

**Fields**:
- `allocator: Allocator` - Memory allocator
- `plugins: HashMap<String, Plugin>` - Registered plugins by name
- `llm_provider: Box<dyn LLMProvider>` - LLM client for function calling
- `function_registry: HashMap<String, FunctionSchema>` - Registered function schemas
- `config: PluginConfig` - Plugin system configuration
- `event_manager: Option<&EventManager>` - Optional event manager for observability
- `resource_tracker: ResourceTracker` - AI operation quota tracking

**Invariants**:
- Plugin names are unique
- Function registry contains all functions from all plugins
- LLM provider is valid for lifetime of manager

### Plugin

**Description**: Trait/interface for extensible plugins

**Fields** (function pointers):
- `name: String` - Plugin identifier
- `version: String` - Semantic version
- `on_commit: Option<HookFn<CommitContext, PluginResult>>` - Post-commit hook
- `on_commit_streaming: Option<HookFn<StreamingCommitContext, StreamingPluginResult>>` - Real-time commit hook
- `on_query: Option<HookFn<QueryContext, Option<QueryPlan>>>` - Query optimization hook
- `on_schedule: Option<HookFn<ScheduleContext, MaintenanceTask>>` - Maintenance scheduling hook
- `get_functions: Option<fn() -> Vec<FunctionSchema>>` - Function schema provider
- `on_agent_session_start: Option<HookFn<AgentSessionContext, ()>>` - Agent lifecycle hook
- `on_agent_operation: Option<HookFn<AgentOperationContext, ()>>` - Agent operation hook
- `on_review_request: Option<HookFn<ReviewContext, PluginResult>>` - Review generation hook
- `on_perf_sample: Option<HookFn<PerfSampleContext, ()>>` - Performance sample hook
- `on_benchmark_complete: Option<HookFn<BenchmarkCompleteContext, ()>>` - Benchmark completion hook

**Lifecycle Methods**:
- `init(&mut self, alloc: Allocator, config: PluginConfig) -> Result<(), Error>` - Initialize plugin
- `cleanup(&mut self, alloc: Allocator) -> Result<(), Error>` - Cleanup resources

### PluginConfig

**Description**: Configuration for plugin system behavior

**Fields**:
- `llm_provider: LLMProviderConfig` - LLM provider settings
- `fallback_on_error: bool` - Continue execution if plugin fails (default true)
- `performance_isolation: bool` - Run plugins in parallel with timeouts (default true)
- `max_llm_latency_ms: u64` - Maximum LLM call timeout (default 5000)
- `cost_budget_per_hour: f64` - Maximum AI spend per hour (default 10.0)

### LLMProviderConfig

**Description**: LLM provider connection settings

**Fields**:
- `provider_type: String` - Provider name ("openai", "anthropic", "local")
- `model: String` - Model identifier
- `api_key: Option<String>` - API key (optional for local models)
- `endpoint: Option<String>` - Custom endpoint URL (optional)

### ResourceTracker

**Description**: Tracks AI operation quotas and usage

**Fields**:
- `budget_per_hour: f64` - Cost budget per hour
- `tokens_used_this_hour: u64` - Token counter
- `hour_start: i128` - Nanosecond timestamp of hour start
- `request_count_this_hour: u64` - Request counter
- `max_requests_per_hour: u64` - Request limit (default 1000)

**Invariants**:
- Counters reset when hour elapses
- Quota checked before operations

### ResourceUsage

**Description**: Current resource usage statistics

**Fields**:
- `tokens_used: u64` - Tokens used this hour
- `requests_made: u64` - Requests made this hour
- `budget_remaining: f64` - Remaining budget
- `hour_progress_minutes: f64` - Minutes into current hour

### FunctionSchema

**Description**: Schema for LLM function calling

**Fields**:
- `name: String` - Function identifier
- `description: String` - Function description for LLM
- `parameters: JSONSchema` - Parameter validation schema

### PluginResult

**Description**: Result from plugin hook execution

**Fields**:
- `success: bool` - Operation succeeded
- `operations_processed: usize` - Number of operations performed
- `cartridges_updated: usize` - Number of cartridges modified
- `confidence: f32` - Confidence score 0.0 to 1.0

### StreamingPluginResult

**Description**: Result from streaming hook (runs during commit)

**Fields**:
- `success: bool` - Operation succeeded
- `entities_extracted: usize` - Number of entities extracted
- `processing_latency_ns: u64` - Processing time in nanoseconds
- `throttled: bool` - Processing was throttled due to backpressure

### PluginExecutionResult

**Description**: Aggregate result from executing all plugin hooks

**Fields**:
- `total_plugins_executed: usize` - Number of plugins that ran
- `errors: Vec<PluginErrorInfo>` - Errors from failed plugins
- `success: bool` - All plugins succeeded

### PluginErrorInfo

**Description**: Error with plugin context

**Fields**:
- `plugin_name: String` - Plugin that failed
- `err: Error` - Error that occurred

## Context Types

### CommitContext

**Description**: Context passed to on_commit hooks

**Fields**:
- `txn_id: u64` - Transaction identifier
- `mutations: Vec<Mutation>` - Committed mutations
- `timestamp: i64` - Commit timestamp
- `metadata: HashMap<String, String>` - Additional metadata

### StreamingCommitContext

**Description**: Context for on_commit_streaming hooks (runs before WAL fsync)

**Fields**:
- `txn_id: u64` - Transaction identifier
- `mutations: Vec<Mutation>` - Mutations being committed
- `timestamp: i64` - Commit timestamp
- `metadata: HashMap<String, String>` - Additional metadata
- `on_entity_extracted: Option<Callback>` - Stream callback for incremental results

### QueryContext

**Description**: Context passed to on_query hooks

**Fields**:
- `query: String` - User query text
- `user_intent: Option<QueryIntent>` - Parsed intent
- `available_cartridges: Vec<CartridgeType>` - Available cartridge types
- `performance_constraints: QueryConstraints` - Performance requirements

### AgentSessionContext

**Description**: Context for on_agent_session_start hook

**Fields**:
- `agent_id: u64` - Agent identifier
- `agent_version: String` - Agent version string
- `session_purpose: String` - Session purpose description
- `metadata: HashMap<String, String>` - Additional metadata
- `event_manager: Option<&EventManager>` - Event manager for logging

### AgentOperationContext

**Description**: Context for on_agent_operation hook

**Fields**:
- `agent_id: u64` - Agent identifier
- `session_id: u64` - Session identifier
- `operation_type: String` - Operation type
- `operation_id: u64` - Operation identifier
- `target_type: String` - Target type
- `target_id: String` - Target identifier
- `status: String` - Operation status
- `duration_ns: Option<i64>` - Operation duration
- `metadata: HashMap<String, String>` - Additional metadata
- `event_manager: Option<&EventManager>` - Event manager for logging

### ReviewContext

**Description**: Context for on_review_request hook

**Fields**:
- `target_type: String` - Type of target ("commit", "file", "symbol", "pr")
- `target_id: String` - Target identifier
- `author: u64` - Review author ID
- `visibility: EventVisibility` - Review visibility
- `references: Vec<String>` - Related item references
- `event_manager: Option<&EventManager>` - Event manager for logging

### PerfSampleContext

**Description**: Context for on_perf_sample hook

**Fields**:
- `agent_id: u64` - Agent identifier
- `metric_name: String` - Metric name
- `dimensions: HashMap<String, String>` - Metric dimensions
- `value: f64` - Metric value
- `unit: String` - Unit of measurement
- `window_start: i64` - Time window start
- `window_end: i64` - Time window end
- `correlation_commit_range: Option<String>` - Correlated commit range
- `correlation_session_ids: Vec<u64>` - Correlated session IDs
- `event_manager: Option<&EventManager>` - Event manager for logging

### BenchmarkCompleteContext

**Description**: Context for on_benchmark_complete hook

**Fields**:
- `benchmark_name: String` - Benchmark name
- `ops_per_sec: f64` - Throughput
- `p50_latency_ns: u64` - Median latency
- `p95_latency_ns: u64` - 95th percentile latency
- `p99_latency_ns: u64` - 99th percentile latency
- `max_latency_ns: u64` - Maximum latency
- `repeat_index: u32` - Repeat number
- `repeat_count: u32` - Total repeats
- `duration_ns: u64` - Benchmark duration
- `bytes_read: u64` - Bytes read
- `bytes_written: u64` - Bytes written
- `fsync_count: u64` - Fsync operations
- `alloc_count: u64` - Allocations
- `alloc_bytes: u64` - Bytes allocated
- `git_sha: String` - Git commit SHA
- `git_branch: String` - Git branch
- `profile_name: String` - Build profile
- `event_manager: Option<&EventManager>` - Event manager for logging

## Functions

### PluginManager::new(config: PluginConfig) -> Result<Self, Error>

**Purpose**: Create new plugin manager with LLM provider

**Algorithm**:
1. Create LLM provider from config
2. Initialize empty plugin registry
3. Initialize empty function registry
4. Initialize resource tracker with budget
5. Return manager instance

**Error Conditions**:
- `Error::LLMInitFailed`: LLM provider creation failed

### PluginManager::register_plugin(&mut self, plugin: Plugin) -> Result<(), Error>

**Purpose**: Register a plugin with the manager

**Algorithm**:
1. Duplicate plugin name for storage
2. Initialize plugin with config
3. If plugin provides functions, register each
4. Store plugin in registry

**Error Conditions**:
- `Error::PluginInitFailed`: Plugin initialization failed
- `Error::DuplicatePlugin`: Plugin name already exists

### PluginManager::register_function(&mut self, schema: FunctionSchema) -> Result<(), Error>

**Purpose**: Register a function schema for LLM calling

**Algorithm**:
1. Duplicate schema name for storage
2. Clone schema for storage
3. Insert into function registry

### PluginManager::execute_on_commit_hooks(&mut self, ctx: CommitContext) -> Result<PluginExecutionResult, Error>

**Purpose**: Execute all on_commit hooks (async or sync based on config)

**Algorithm** (async mode):
1. Collect all plugins with on_commit hooks
2. If no hooks, return empty result
3. Spawn thread for each hook with timeout
4. Wait for all threads to complete
5. Collect results and errors
6. Return aggregate result

**Algorithm** (sync mode):
1. Iterate through all plugins
2. For each with on_commit hook, execute synchronously
3. Collect errors on failure
4. Return aggregate result

### PluginManager::execute_on_commit_streaming(&mut self, ctx: StreamingCommitContext) -> Result<StreamingStats, Error>

**Purpose**: Execute streaming hooks during commit (before WAL fsync)

**Algorithm**:
1. Record start time
2. Iterate through all plugins with streaming hooks
3. Execute each hook, catching errors (best-effort)
4. Aggregate entities extracted
5. Calculate latency
6. Return stats

**Note**: Errors are logged but don't fail the commit

### PluginManager::call_function(&mut self, name: &str, params: Value) -> Result<FunctionResult, Error>

**Purpose**: Call a registered function via LLM provider

**Algorithm**:
1. Find function schema by name
2. Validate parameters against schema
3. Check resource quota
4. Call LLM provider
5. Record resource usage
6. Return result

**Error Conditions**:
- `Error::FunctionNotFound`: Function not in registry
- `Error::InvalidParameters`: Parameters don't match schema
- `Error::ResourceQuotaExceeded`: Quota limits exceeded

### ResourceTracker::check_quota(&mut self) -> Result<(), Error>

**Purpose**: Check if operation is within quota limits

**Algorithm**:
1. Check if hour has elapsed, reset counters if so
2. Check request count against limit
3. Return error if exceeded
4. Return success otherwise

### ResourceTracker::record_usage(&mut self, tokens: u32) -> Result<(), Error>

**Purpose**: Record resource usage after operation

**Algorithm**:
1. Check if hour has elapsed, reset counters if so
2. Add tokens to token counter
3. Increment request counter
4. Return success

## Dependencies

- **Uses**: Event types, LLM provider interface
- **Used by**: Database core (for hooks), AI operations

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/plugins/
  mod.rs          - Public API
  manager.rs      - PluginManager
  trait.rs        - Plugin trait
  context.rs      - Context types
  registry.rs     - Function registry
  resource.rs     - ResourceTracker
```

### Type Definitions

- **Plugin**: Use trait object `Box<dyn Plugin>` for dynamic dispatch
- **Hook functions**: Use `fn` or `Box<dyn Fn(...) -> Result<_>>` for function pointers
- **Context types**: Use structs with lifetimes for borrowed data

### Concurrency

- **PluginManager**: Use `Mutex<PluginManager>` for thread-safe access
- **Hook execution**: Use `rayon` for parallel thread spawning
- **Timeout**: Use `tokio::time::timeout` or `std::thread::spawn` with timeout

### Key Decisions

- **Trait vs Struct**: Use trait for Plugin interface to allow dynamic loading
- **Error handling**: Use `anyhow::Error` for plugin errors with context
- **Function registry**: Use `HashMap<String, Arc<FunctionSchema>>` for shared schemas

### Implementation Notes

1. Implement `Drop` for PluginManager to cleanup all plugins
2. Use `Arc<str>` for string deduplication
3. Implement `Clone` for context types where needed
4. Add tracing spans for hook execution observability

### Testing Strategy

**Unit tests for**:
- Plugin registration and initialization
- Hook execution (sync and async)
- Resource quota enforcement
- Function calling with validation

**Property tests for**:
- Plugin isolation (one plugin failure doesn't affect others)
- Resource quota accuracy

**Integration scenarios**:
- Multiple plugins with hooks
- LLM provider integration
- Event manager integration
