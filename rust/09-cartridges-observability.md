# Observability Cartridge Specification

## Purpose

Stores performance metrics, detects regressions, and provides time-series aggregation for database observability. Enforces rate limiting and implements hot-path safety to avoid impacting core database performance.

## Types

### ObservabilityCartridge

**Description**: Main cartridge for metrics and observability

**Fields**:
- `allocator: Allocator` - Memory allocator
- `event_manager: EventManager` - Event manager for persistence
- `max_payload_size: u32` - Maximum metric payload size
- `token_bucket: TokenBucket` - Rate limiting for metric ingestion
- `metric_index: HashMap<String, Vec<MetricIndexEntry>>` - In-memory index for queries

**Invariants**:
- Event manager valid for lifetime
- Token bucket enforces ingestion limits
- Index kept in sync with persisted events

### MetricType (Enum)

**Description**: Type of metric

**Variants**:
- `Counter` - Monotonically increasing counter
- `Gauge` - Point-in-time value
- `Histogram` - Distribution of values
- `Timing` - Duration measurement

### Metric

**Description**: Single metric data point

**Fields**:
- `metric_name: String` - Metric identifier
- `metric_type: MetricType` - Type of metric
- `dimensions: HashMap<String, String>` - Metric labels/dimensions
- `value: f64` - Metric value
- `unit: String` - Unit of measurement
- `timestamp: i64` - When metric was recorded

**Invariants**:
- `metric_name` is non-empty
- `unit` is non-empty
- For Counter: `value >= 0`
- For Gauge: any `value`
- For Histogram: `value` is a bucket value
- For Timing: `value >= 0`

### MetricIndexEntry

**Description**: Index entry for fast metric lookups

**Fields**:
- `event_id: u64` - Associated event ID
- `timestamp: i64` - Metric timestamp
- `dimensions: HashMap<String, String>` - Metric dimensions

### TokenBucket

**Description**: Rate limiter using token bucket algorithm

**Fields**:
- `capacity: u64` - Maximum tokens
- `tokens: u64` - Current available tokens
- `last_refill: i64` - Last refill timestamp
- `refill_rate: u64` - Tokens added per second

**Invariants**:
- `0 <= tokens <= capacity`
- `refill_rate > 0`

### RateLimitState

**Description**: Per-metric rate limiting state

**Fields**:
- `last_emitted: i64` - Last time metric was emitted
- `emission_count: u64` - Number of emissions in window

### Baseline

**Description**: Performance baseline for regression detection

**Fields**:
- `metric_name: String` - Metric name
- `baseline_value: f64` - Baseline value
- `sample_count: u64` - Number of samples
- `std_dev: f64` - Standard deviation
- `timestamp: i64` - When baseline was computed

### RegressionDetectionConfig

**Description**: Configuration for regression detection

**Fields**:
- `throughput_threshold_percent: f32` - Throughput regression % (default 5.0)
- `latency_threshold_percent: f32` - Latency regression % (default 10.0)
- `min_samples: u32` - Minimum samples for detection (default 10)

### RegressionAlert

**Description**: Alert for detected regression

**Fields**:
- `metric_name: String` - Regressed metric
- `baseline_value: f64` - Baseline value
- `current_value: f64` - Current value
- `regression_percent: f32` - Percentage regression
- `severity: AlertSeverity` - Alert severity
- `detected_at: i64` - Detection timestamp
- `likely_cause: Option<String>` - Suspected cause

### AlertSeverity (Enum)

**Description**: Severity level for alerts

**Variants**:
- `Minor` - Small regression, monitor
- `Moderate` - Significant regression, investigate
- `Severe` - Major regression, immediate action

## Functions

### ObservabilityCartridge::new(event_manager: EventManager, config: ObservabilityConfig) -> Self

**Purpose**: Create new observability cartridge

**Algorithm**:
1. Create token bucket with config refill rate
2. Initialize empty metric index
3. Return cartridge instance

### ObservabilityCartridge::record_metric(&mut self, metric: Metric) -> Result<(), Error>

**Purpose**: Record a metric sample

**Algorithm**:
1. Check token bucket for rate limit
2. If no tokens, return throttled error
3. Consume one token
4. Serialize metric as event
5. Record via event_manager.recordPerfSample()
6. Update metric index
7. Return success

**Error Conditions**:
- `Error::RateLimitExceeded`: Ingestion rate too high
- `Error::PayloadTooLarge`: Metric size exceeds maximum

### ObservabilityCartridge::record_counter(&mut self, name: &str, value: f64, unit: &str, dimensions: HashMap<String, String>) -> Result<(), Error>

**Purpose**: Record a counter metric

**Algorithm**: Create Metric with Counter type, delegate to record_metric()

### ObservabilityCartridge::record_gauge(&mut self, name: &str, value: f64, unit: &str, dimensions: HashMap<String, String>) -> Result<(), Error>

**Purpose**: Record a gauge metric

**Algorithm**: Create Metric with Gauge type, delegate to record_metric()

### ObservabilityCartridge::record_timing(&mut self, name: &str, duration_ns: i64, dimensions: HashMap<String, String>) -> Result<(), Error>

**Purpose**: Record a timing metric

**Algorithm**: Create Metric with Timing type, delegate to record_metric()

### ObservabilityCartridge::query_metrics(&self, filter: MetricFilter) -> Result<Vec<Metric>, Error>

**Purpose**: Query metrics with filter

**Algorithm**:
1. Use metric index for efficient lookup
2. Query events from event manager
3. Deserialize metrics from payloads
4. Filter by query conditions
5. Return matching metrics

### MetricFilter

**Description**: Filter for metric queries

**Fields**:
- `metric_name: Option<String>` - Filter by name
- `dimensions: Option<HashMap<String, String>>` - Filter by dimensions
- `start_time: Option<i64>` - Filter by start time
- `end_time: Option<i64>` - Filter by end time
- `metric_type: Option<MetricType>` - Filter by type
- `limit: Option<usize>` - Limit results

### ObservabilityCartridge::aggregate_metrics(&self, metric_name: &str, aggregation: AggregationType, window: TimeWindow) -> Result<Vec<AggregateResult>, Error>

**Purpose**: Aggregate metrics over time window

**Algorithm**:
1. Query metrics in time range
2. Group by aggregation bucket size
3. Apply aggregation function (sum, avg, min, max, percentile)
4. Return aggregate results

### AggregationType (Enum)

**Description**: Type of aggregation

**Variants**:
- `Sum` - Sum of values
- `Avg` - Average of values
- `Min` - Minimum value
- `Max` - Maximum value
- `P50` - 50th percentile
- `P95` - 95th percentile
- `P99` - 99th percentile

### TimeWindow

**Description**: Time range for aggregation

**Fields**:
- `start: i64` - Start timestamp
- `end: i64` - End timestamp
- `bucket_size: Duration` - Bucket size for grouping

### AggregateResult

**Description**: Result of metric aggregation

**Fields**:
- `timestamp: i64` - Bucket timestamp
- `value: f64` - Aggregated value
- `sample_count: u64` - Number of samples

### ObservabilityCartridge::detect_regression(&self, metric_name: &str, current_value: f64, baseline: &Baseline, config: &RegressionDetectionConfig) -> Option<RegressionAlert>

**Purpose**: Detect performance regression

**Algorithm**:
1. Calculate percent change: `(current - baseline) / baseline * 100`
2. Determine severity based on thresholds
3. If change exceeds threshold, create alert
4. Return alert or None

**Severity Logic**:
- If metric_name contains "latency" or "p99":
  - Severe: regression > latency_threshold * 2
  - Moderate: regression > latency_threshold
  - Minor: regression > latency_threshold / 2
- If metric_name contains "throughput" or "ops":
  - Severe: regression < -(throughput_threshold * 2)
  - Moderate: regression < -throughput_threshold
  - Minor: regression < -(throughput_threshold / 2)

### ObservabilityCartridge::compute_baseline(&self, metric_name: &str, samples: &[Metric]) -> Baseline

**Purpose**: Compute baseline from samples

**Algorithm**:
1. Calculate mean of all values
2. Calculate standard deviation
3. Return Baseline with statistics

### ObservabilityCartridge::check_rate_limit(&mut self, metric_name: &str) -> Result<(), Error>

**Purpose**: Check if metric can be emitted (rate limiting)

**Algorithm**:
1. Get or create rate limit state for metric
2. Check if emissions exceed limit
3. Return error if throttled
4. Update emission count

### TokenBucket::refill(&mut self, now: i64)

**Purpose**: Refill tokens based on elapsed time

**Algorithm**:
1. Calculate elapsed seconds since last_refill
2. Add tokens: elapsed * refill_rate
3. Cap at capacity
4. Update last_refill

### TokenBucket::try_consume(&mut self, tokens: u64) -> bool

**Purpose**: Try to consume tokens

**Algorithm**:
1. Refill based on current time
2. If sufficient tokens, subtract and return true
3. Otherwise return false

## Hot Path Safety

To avoid impacting core database performance:

1. **Sampling**: Drop high-frequency metrics when overloaded
2. **Rate limiting**: Enforce per-metric limits via token bucket
3. **Async flushing**: Write metrics asynchronously
4. **Bounded payloads**: Limit metric payload size (4KB default)
5. **Graceful degradation**: Continue operating if metric ingestion fails

## Dependencies

- **Uses**: Event system, performance monitoring
- **Used by**: Plugin system, performance analyzer

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/cartridges/
  observability.rs    - ObservabilityCartridge implementation
```

### Type Definitions

- **MetricType**: Enum with variants
- **Metric**: Struct with HashMap for dimensions
- **TokenBucket**: Struct for rate limiting
- **Baseline**: Struct with statistics

### Concurrency

- **ObservabilityCartridge**: Use `Mutex` for internal state
- Token bucket operations must be atomic
- Metric index: Use `DashMap` for concurrent access

### Key Decisions

- **Rate limiting**: Per-metric token buckets for fairness
- **Indexing**: In-memory HashMap for fast queries
- **Storage**: Delegated to event system

### Implementation Notes**

1. Use `atomic` types for token bucket counters
2. Implement `Default` for RegressionDetectionConfig
3. Add `derive(Debug, Clone)` for data types
4. Use `chrono` or `time` crate for timestamp handling

### Testing Strategy

**Unit tests for**:
- Metric recording and retrieval
- Token bucket refill and consumption
- Baseline computation
- Regression detection thresholds
- Rate limit enforcement

**Property tests for**:
- Token bucket never exceeds capacity
- Regression detection with synthetic data

**Integration scenarios**:
- High-frequency metric ingestion
- Large-scale aggregation queries
