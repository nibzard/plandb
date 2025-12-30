# Observability Event Schemas

This document describes the standard event types and their schemas for the NorthstarDB Observability system. These events are used by plugins, cartridges, and the event system to track performance, regressions, and other observability data.

## Event Types

### Agent Lifecycle Events

#### `agent_session_started` (0x1000)

Emitted when an agent starts a new session.

**Fields:**
- `agent_id: u64` - Unique identifier for the agent
- `agent_version: string` - Version string of the agent
- `session_purpose: string` - Description of why the session was started
- `metadata: map<string, string>` - Additional key-value metadata

**Example:**
```json
{
  "event_type": "agent_session_started",
  "timestamp": 1704067200000000000,
  "agent_id": 1,
  "payload": {
    "agent_version": "1.0.0",
    "session_purpose": "code_review",
    "metadata": {
      "hostname": "dev-machine-1",
      "workspace": "/path/to/project"
    }
  }
}
```

#### `agent_session_ended` (0x1001)

Emitted when an agent session ends.

**Fields:**
- `agent_id: u64` - Unique identifier for the agent
- `session_id: u64` - Session identifier

#### `agent_operation` (0x1002)

Emitted when an agent performs an operation (read, write, query, etc.).

**Fields:**
- `agent_id: u64` - Agent identifier
- `session_id: u64` - Session identifier
- `operation_type: string` - Type of operation ("commit", "query", "analyze", etc.)
- `operation_id: u64` - Unique operation identifier
- `target_type: string` - Type of target ("file", "symbol", "cartridge")
- `target_id: string` - Identifier of the target
- `status: string` - Operation status ("started", "completed", "failed")
- `duration_ns: i64?` - Optional duration in nanoseconds
- `metadata: map<string, string>` - Additional metadata

**Example:**
```json
{
  "event_type": "agent_operation",
  "timestamp": 1704067200000001000,
  "agent_id": 1,
  "session_id": 100,
  "payload": {
    "operation_type": "read",
    "operation_id": 1,
    "target_type": "btree",
    "target_id": "user_key",
    "status": "completed",
    "duration_ns": 5000000,
    "metadata": {
      "commit_range": "abc123..def456"
    }
  }
}
```

### Review Events

#### `review_note` (0x2000)

Stores a review note linked to a code artifact.

**Fields:**
- `author: u64` - Agent or human ID who created the note
- `target_type: string` - Type of target ("commit", "file", "symbol", "pr")
- `target_id: string` - Identifier of the target
- `note_text: string` - The review note content
- `visibility: enum` - "private", "team", or "public"
- `references: string[]` - IDs of related items
- `created_at: i64` - Unix nanosecond timestamp

**Example:**
```json
{
  "event_type": "review_note",
  "timestamp": 1704067200000002000,
  "actor_id": 42,
  "visibility": "team",
  "payload": {
    "target_type": "commit",
    "target_id": "abc123",
    "note_text": "This commit introduces a potential race condition",
    "references": ["commit:abc123", "file:src/main.zig"]
  }
}
```

#### `review_summary` (0x2001)

Generated summary of code changes using AI.

**Fields:**
- `generator_id: u64` - Agent ID that generated the summary
- `target_type: string` - Type of target
- `target_id: string` - Target identifier
- `summary_text: string` - Generated summary
- `confidence: f32` - Confidence score (0.0 to 1.0)
- `model_id: string` - LLM model used
- `prompt_hash: string?` - Optional prompt identifier
- `created_at: i64` - Timestamp

### Performance Events

#### `perf_sample` (0x3000)

Records a performance metric sample.

**Fields:**
- `metric_name: string` - Name of the metric (e.g., "latency_p99_ns", "throughput")
- `dimensions: map<string, string>` - Metric dimensions for filtering
- `value: f64` - Metric value
- `unit: string` - Unit of measurement ("ms", "ops/sec", "ns", etc.)
- `timestamp_window: {start: i64, end: i64}` - Time window for the sample
- `correlation_hints: {commit_range: string?, session_ids: u64[]}` - Correlation data

**Example:**
```json
{
  "event_type": "perf_sample",
  "timestamp": 1704067200000003000,
  "payload": {
    "metric_name": "latency_p99_ns",
    "dimensions": {
      "benchmark": "btree_point_get",
      "profile": "ci",
      "mode": "read"
    },
    "value": 1000.0,
    "unit": "ns",
    "timestamp_window": {
      "start": 1704067200000000000,
      "end": 1704067200000003000
    },
    "correlation_hints": {
      "commit_range": "abc123..def456",
      "session_ids": [100, 101]
    }
  }
}
```

**Common Metric Names:**
- `benchmark_ops_per_sec` - Benchmark throughput
- `benchmark_p99_latency_ns` - P99 latency for benchmarks
- `benchmark_throughput` - General throughput metric
- `operation_latency_ms` - Operation latency in milliseconds
- `fsync_count` - Number of fsync operations
- `alloc_count` - Number of allocations
- `alloc_bytes` - Total bytes allocated

#### `perf_regression` (0x3001)

Emitted when a performance regression is detected.

**Fields:**
- `metric_name: string` - Name of the regressed metric
- `baseline_value: f64` - Previous baseline value
- `current_value: f64` - Current (regressed) value
- `regression_percent: f32` - Percentage of regression
- `severity: string` - "minor", "moderate", or "severe"
- `detected_at: i64` - Detection timestamp
- `likely_cause: string?` - Optional suspected cause
- `correlated_commits: string[]` - Related commit hashes

**Example:**
```json
{
  "event_type": "perf_regression",
  "timestamp": 1704067200000004000,
  "payload": {
    "metric_name": "p99_latency_ns",
    "baseline_value": 1000.0,
    "current_value": 1150.0,
    "regression_percent": 15.0,
    "severity": "moderate",
    "detected_at": 1704067200000004000,
    "likely_cause": "New btree split logic",
    "correlated_commits": ["abc123", "def456"]
  }
}
```

**Severity Levels:**
- `minor` - Regression < 20%
- `moderate` - Regression 20% to 50%
- `severe` - Regression > 50%

### Debug Events

#### `debug_session` (0x4000)

Records a debugging session.

**Fields:**
- `tool: string` - Debugger tool ("lldb", "gdb", "python-debugger")
- `session_id: u64` - Unique session identifier
- `breakpoints: Breakpoint[]` - Breakpoints set during session
- `stack_summary: string?` - Optional sampled stack trace
- `references: {commit_ids: string[], symbol_names: string[]}` - Related items

**Breakpoint:**
```zig
struct {
  file_path: string,
  line: u32,
  condition: string?,
  hit_count: u32,
}
```

#### `debug_snapshot` (0x4001)

Snapshot of debug state at a point in time.

### VCS Events

#### `vcs_commit` (0x5000)

Records VCS commit information.

**Fields:**
- `commit_hash: string` - Commit SHA
- `author_id: u64` - Author identifier
- `commit_message: string` - Commit message
- `changed_files: string[]` - List of changed files
- `parent_commits: string[]` - Parent commit SHAs
- `branch: string` - Branch name
- `timestamp: i64` - Commit timestamp

#### `vcs_branch` (0x5001)

Records branch information.

## Event Visibility Levels

Events support three visibility levels:

1. **private** - Only visible to the creating agent
2. **team** - Shared within a team
3. **public** - Publicly visible

## Event Storage

Events are stored in append-only event files with the following structure:

```
[EventHeader(24)][Payload(N)][Trailer(8)]
```

- **EventHeader**: Contains event_id, event_type, timestamp, actor_id, payload_len
- **Payload**: Event-specific data (max 1MB by default)
- **Trailer**: Magic number ("EVNT") + total length for validation

## Hot Path Safety

To prevent performance degradation:

- **Payload size limit**: 1MB max per event (configurable)
- **Rate limiting**: Per-metric token bucket rate limiting (default: 1000/sec)
- **Sampling**: Configurable sampling rate (1.0 = no sampling)
- **Retention**: Automatic compaction of old events (default: 7 days)

## Usage Examples

### Recording a Performance Sample

```zig
// Using EventManager
var dimensions = std.StringHashMap([]const u8).init(allocator);
try dimensions.put("benchmark", "btree_point_get");
try dimensions.put("mode", "read");

try event_manager.recordPerfSample(
    "latency_p99_ns",
    1000.0,
    "ns",
    dimensions,
    "abc123..def456",  // commit_range
    &[_]u64{100},       // session_ids
);
```

### Querying Events

```zig
// Query all performance samples in a time range
const samples = try event_manager.query(.{
    .event_types = &[_]EventType{.perf_sample},
    .start_time = start_time,
    .end_time = end_time,
    .limit = 100,
});

// Query by session
const session_events = try event_manager.getSessionEvents(session_id);

// Query by actor
const agent_events = try event_manager.getActorEvents(agent_id, 50);
```

### Using Observability Cartridge

```zig
// Initialize cartridge with config
const config = ObservabilityCartridge.Config{
    .max_metric_payload_size = 4096,
    .sampling_rate = 1.0,  // No sampling
    .rate_limit_per_sec = 100,
};

var cartridge = try ObservabilityCartridge.init(
    allocator,
    &event_manager,
    config,
);
defer cartridge.deinit();

// Record a metric
var dimensions = DimensionMap{ .map = std.StringHashMap([]const u8).init(allocator) };
try dimensions.map.put("operation", "read");

try cartridge.recordMetric(
    "latency_ms",
    5.2,
    "ms",
    dimensions,
    .{ .commit_range = null, .session_ids = &[_]u64{} },
);

// Detect regressions
const alerts = try cartridge.detectRegressions("latency_ms", 10.0);
defer {
    for (alerts) |*a| a.deinit(allocator);
    allocator.free(alerts);
}

for (alerts) |alert| {
    std.log.warn("Regression detected: {s} degraded by {d:.1}%%", .{
        alert.metric_name,
        alert.regression_percent,
    });
}
```

## Integration with Benchmark Runner

The benchmark runner can emit completion events through the `on_benchmark_complete` hook:

```zig
// In perf_analyzer plugin
fn on_benchmark_complete(
    allocator: std.mem.Allocator,
    ctx: BenchmarkCompleteContext
) !void {
    // Record ops/sec metric
    try event_manager.recordPerfSample(
        "benchmark_ops_per_sec",
        ctx.ops_per_sec,
        "ops/sec",
        dimensions,
        commit_range,
        &[_]u64{},
    );

    // Record p99 latency metric
    try event_manager.recordPerfSample(
        "benchmark_p99_latency_ns",
        ctx.p99_latency_ns,
        "ns",
        dimensions,
        commit_range,
        &[_]u64{},
    );
}
```

## Regression Detection

Regression detection uses the following heuristics:

1. **Throughput regression**: Current value < baseline * 0.95 (5% degradation)
2. **Latency regression**: Current value > baseline * 1.10 (10% increase)
3. **P99 regression**: Current value > baseline * 1.15 (15% increase)
4. **Error rate regression**: Current value > baseline * 1.5 (50% increase)

## See Also

- [PLAN-REVIEW-OBSERVABILITY.md](../PLAN-REVIEW-OBSERVABILITY.md) - Overall design
- [src/events/types.zig](../src/events/types.zig) - Event type definitions
- [src/cartridges/observability.zig](../src/cartridges/observability.zig) - Observability cartridge
- [src/plugins/perf_analyzer.zig](../src/plugins/perf_analyzer.zig) - Performance analyzer plugin
