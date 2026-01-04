# Monitoring and Alerting

## Purpose

Comprehensive monitoring and alerting system for NorthstarDB that provides real-time visibility into database health, performance, and resource utilization. The system collects metrics at multiple layers (system, database, operations), exposes them via a unified API, and triggers alerts when thresholds are exceeded. Monitoring is designed for production environments with minimal performance overhead (target: less than 1% CPU impact).

## Types

### MetricType

**Description**: Enumeration of metric types supported by the monitoring system.

**Variants**:
- `Counter` - Monotonically increasing value (e.g., total operations, bytes read)
- `Gauge` - Current value that can increase or decrease (e.g., active connections, memory usage)
- `Histogram` - Distribution of values (e.g., request latencies, row counts)
- `Summary` - Count and sum with optional quantiles (e.g., query durations)

**Default**: `Counter` for operation counts, `Histogram` for latency measurements

### Metric

**Description**: Generic metric wrapper storing metadata and current value.

**Fields**:
- `name: String` - Unique metric identifier (e.g., "db_operations_total", "cache_hit_rate")
- `description: String` - Human-readable description
- `metric_type: MetricType` - Type of metric
- `labels: HashMap<String, String>` - Key-value pairs for dimensionality (e.g., "operation": "read")
- `value: MetricValue` - Current value based on metric type
- `created_at: Instant` - When metric was first registered
- `updated_at: Instant` - When metric was last updated

**Invariants**:
- `name` must be unique within the registry
- `name` must match regex `^[a-z_][a-z0-9_]*$` (snake_case, alphanumeric + underscores)
- `labels` must not exceed 10 dimensions
- `updated_at` is never older than `created_at`

### MetricValue

**Description**: Union type holding different metric value representations.

**Variants**:
- `Counter(u64)` - Single counter value
- `Gauge(i64)` - Single gauge value (signed for decrease support)
- `Histogram(HistogramData)` - Distribution with buckets
- `Summary(SummaryData)` - Count, sum, and quantiles

### HistogramData

**Description**: Histogram implementation with configurable buckets for distribution tracking.

**Fields**:
- `count: u64` - Total number of observations
- `sum: u64` - Sum of all observed values
- `buckets: Vec<Bucket>` - Pre-configured buckets with counts
- `min: u64` - Minimum observed value
- `max: u64` - Maximum observed value

**Bucket**:
- `upper_bound: u64` - Upper bound of this bucket (inclusive)
- `count: u64` - Number of observations <= upper_bound

**Default Buckets** (for latency in microseconds):
- `[10, 50, 100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000]`

**Invariants**:
- `buckets` are sorted in ascending order
- `count` in each bucket is monotonically increasing
- Last bucket count equals total `count`

### SummaryData

**Description**: Summary with online algorithm for quantile calculation.

**Fields**:
- `count: u64` - Total number of observations
- `sum: u64` - Sum of all observed values
- `quantiles: Vec<Quantile>` - Pre-configured quantiles with values

**Quantile**:
- `phi: f64` - Quantile rank (0.0 to 1.0, e.g., 0.5 for median, 0.99 for p99)
- `value: u64` - Computed quantile value

**Default Quantiles**: `[0.5, 0.9, 0.95, 0.99]`

**Invariants**:
- `phi` values are in range (0.0, 1.0)
- `quantiles` sorted by `phi` ascending
- `value` is interpolated if no exact observation matches

### MetricRegistry

**Description**: Central registry storing all metrics and providing lookup/iteration.

**Fields**:
- `metrics: RwLock<HashMap<String, Metric>>` - Protected metric storage
- `config: Arc<MonitoringConfig>` - Shared configuration
- `collectors: Vec<Box<dyn MetricCollector>>` - Pluggable metric collectors
- `scrape_count: AtomicU64` - Number of scrape operations performed

**Size**: Variable (typically <1MB for metric metadata, values stored separately)
**Invariants**:
- Metric names are unique within registry
- All metrics have valid `name` and `metric_type`
- `scrape_count` is monotonically increasing

### HealthStatus

**Description**: Overall health status of the database system.

**Variants**:
- `Healthy` - All systems operating normally
- `Degraded` - Some functionality impacted but service continues
- `Unhealthy` - Critical issues requiring immediate attention
- `Unknown` - Health check incomplete or failed

### HealthCheck

**Description**: Individual health check with result and metadata.

**Fields**:
- `name: String` - Check identifier (e.g., "disk_space", "pager_connection")
- `status: HealthStatus` - Current health status
- `message: String` - Human-readable status message
- `last_check: Instant` - When check was last performed
- `duration: Duration` - How long the check took
- `critical: bool` - Whether failure marks entire system unhealthy

**Invariants**:
- `critical == true` implies `status != Healthy` triggers alert
- `duration` is typically < 100ms for non-blocking checks

### HealthChecker

**Description**: Aggregates multiple health checks into overall system health.

**Fields**:
- `checks: Vec<Box<dyn HealthCheckFn>>` - Registered health checks
- `timeout: Duration` - Maximum time per check (default: 5 seconds)
- `overall_status: HealthStatus` - Aggregated status
- `last_update: Instant` - When status was last calculated

**Invariants**:
- Any critical check failing sets `overall_status` to `Unhealthy`
- All checks passing sets `overall_status` to `Healthy`
- `last_update` never in the future

### AlertSeverity

**Description**: Severity levels for alerts.

**Variants**:
- `Info` - Informational, no action required
- `Warning` - Potentially problematic, monitor closely
- `Critical` - Immediate action required
- `Emergency` - System failure in progress

### Alert

**Description**: Alert event triggered when threshold exceeded.

**Fields**:
- `id: Uuid` - Unique alert identifier
- `severity: AlertSeverity` - Alert severity level
- `title: String` - Short alert title
- `description: String` - Detailed description
- `metric_name: String` - Metric that triggered alert
- `current_value: f64` - Current metric value
- `threshold: f64` - Threshold that was exceeded
- `triggered_at: Instant` - When alert was triggered
- `resolved_at: Option<Instant>` - When alert was resolved (None if active)
- `labels: HashMap<String, String>` - Dimensional labels

**Invariants**:
- `id` is unique across all alerts
- `resolved_at` is None for active alerts
- `resolved_at` is always after `triggered_at` when present

### AlertRule

**Description**: Rule defining when to trigger alerts for a metric.

**Fields**:
- `id: Uuid` - Unique rule identifier
- `name: String` - Human-readable rule name
- `metric_name: String` - Metric to monitor
- `condition: AlertCondition` - Trigger condition
- `threshold: f64` - Threshold value
- `duration: Duration` - How long condition must persist (default: 0, immediate)
- `severity: AlertSeverity` - Alert severity
- `enabled: bool` - Whether rule is active
- `cooldown: Duration` - Minimum time between alerts for this rule (default: 5 minutes)

**AlertCondition**:
- `GreaterThan` - Value > threshold
- `LessThan` - Value < threshold
- `Equals` - Value == threshold
- `NotEquals` - Value != threshold
- `RateAbove` - Rate of change > threshold per second
- `RateBelow` - Rate of change < threshold per second

**Invariants**:
- `duration` >= 0
- `cooldown` >= 1 second
- Only one alert per rule per `cooldown` period

### MonitoringConfig

**Description**: Configuration for monitoring system behavior.

**Fields**:
- `enabled: bool` - Whether monitoring is enabled (default: true)
- `scrape_interval: Duration` - How often to collect metrics (default: 15 seconds)
- `retention_period: Duration` - How long to keep metric history (default: 24 hours)
- `max_metrics: usize` - Maximum number of metrics (default: 10,000)
- `enable_histograms: bool` - Whether to collect histogram data (default: true)
- `default_latency_buckets: Vec<u64>` - Default histogram buckets for latency
- `enable_label_cardinality_limit: bool` - Enforce max unique label values (default: true)
- `max_cardinality: usize` - Maximum unique label combinations per metric (default: 1000)
- `export_format: ExportFormat` - Format for metric export (default: Prometheus)

**ExportFormat**:
- `Prometheus` - Prometheus text-based exposition format
- `OpenTelemetry` - OpenTelemetry protocol (OTLP)
- `Json` - JSON array of metric objects

**Invariants**:
- `scrape_interval` >= 1 second
- `retention_period` >= 1 minute
- `max_metrics` >= 100

## Functions

### register_counter(name: String, description: String, labels: HashMap<String, String>) -> Result<Arc<Counter>>

**Purpose**: Register a new counter metric in the registry.

**Parameters**:
- `name` - Unique metric name (snake_case)
- `description` - Human-readable description
- `labels` - Initial label dimensions

**Returns**: `Arc<Counter>` - Thread-safe handle to the counter

**Algorithm**:
1. Validate `name` matches required regex pattern
2. Check if metric with `name` already exists in registry, return error if duplicate
3. Create new `Counter` with initial value 0
4. Wrap in `Arc` for thread-safe sharing
5. Store in registry `metrics` map
6. Return `Arc` pointer

**Error Conditions**:
- `MetricExists`: Metric with this name already registered
- `InvalidName`: Name does not match regex pattern
- `RegistryFull`: Maximum number of metrics reached

**Concurrency**: Thread-safe via registry `RwLock`

### register_gauge(name: String, description: String, labels: HashMap<String, String>) -> Result<Arc<Gauge>>

**Purpose**: Register a new gauge metric in the registry.

**Parameters**:
- `name` - Unique metric name
- `description` - Human-readable description
- `labels` - Initial label dimensions

**Returns**: `Arc<Gauge>` - Thread-safe handle to the gauge

**Algorithm**:
1. Validate `name` matches required regex pattern
2. Check for duplicate metric name in registry
3. Create new `Gauge` with initial value 0
4. Wrap in `Arc` for thread-safe sharing
5. Store in registry `metrics` map
6. Return `Arc` pointer

**Error Conditions**:
- `MetricExists`: Metric with this name already registered
- `InvalidName`: Name does not match regex pattern
- `RegistryFull`: Maximum number of metrics reached

**Concurrency**: Thread-safe via registry `RwLock`

### register_histogram(name: String, description: String, labels: HashMap<String, String>, buckets: Option<Vec<u64>>) -> Result<Arc<Histogram>>

**Purpose**: Register a new histogram metric with custom or default buckets.

**Parameters**:
- `name` - Unique metric name
- `description` - Human-readable description
- `labels` - Initial label dimensions
- `buckets` - Optional custom bucket boundaries (None = use defaults)

**Returns**: `Arc<Histogram>` - Thread-safe handle to the histogram

**Algorithm**:
1. Validate `name` matches required regex pattern
2. Check for duplicate metric name in registry
3. Use provided `buckets` or default latency buckets from config
4. Validate `buckets` are sorted in ascending order
5. Create new `Histogram` with zeroed bucket counts
6. Wrap in `Arc` for thread-safe sharing
7. Store in registry `metrics` map
8. Return `Arc` pointer

**Error Conditions**:
- `MetricExists`: Metric with this name already registered
- `InvalidName`: Name does not match regex pattern
- `InvalidBuckets`: Buckets not sorted or empty
- `RegistryFull`: Maximum number of metrics reached

**Concurrency**: Thread-safe via registry `RwLock`

### counter_inc(counter: Arc<Counter>, value: u64, labels: Option<HashMap<String, String>>)

**Purpose**: Increment a counter metric by a value.

**Parameters**:
- `counter` - Counter handle from registration
- `value` - Amount to increment by (default: 1)
- `labels` - Optional additional label dimensions

**Returns**: None

**Algorithm**:
1. Acquire atomic write access to counter value
2. Add `value` to current counter value
3. Update `updated_at` timestamp to now
4. Merge provided `labels` with existing labels
5. Check cardinality limit, reject if exceeded
6. Release atomic access

**Error Conditions**:
- `CardinalityExceeded`: Too many unique label combinations

**Concurrency**: Thread-safe via atomic operations

### gauge_set(gauge: Arc<Gauge>, value: i64, labels: Option<HashMap<String, String>>)

**Purpose**: Set a gauge metric to a specific value.

**Parameters**:
- `gauge` - Gauge handle from registration
- `value` - New gauge value (can be negative)
- `labels` - Optional additional label dimensions

**Returns**: None

**Algorithm**:
1. Acquire atomic write access to gauge value
2. Set gauge value to `value`
3. Update `updated_at` timestamp to now
4. Merge provided `labels` with existing labels
5. Check cardinality limit, reject if exceeded
6. Release atomic access

**Error Conditions**:
- `CardinalityExceeded`: Too many unique label combinations

**Concurrency**: Thread-safe via atomic operations

### histogram_observe(histogram: Arc<Histogram>, value: u64, labels: Option<HashMap<String, String>>)

**Purpose**: Record a value observation in a histogram.

**Parameters**:
- `histogram` - Histogram handle from registration
- `value` - Observed value to record
- `labels` - Optional additional label dimensions

**Returns**: None

**Algorithm**:
1. Acquire atomic write access to histogram data
2. Increment `count` by 1
3. Add `value` to `sum`
4. Update `min` if `value` < current `min`
5. Update `max` if `value` > current `max`
6. For each bucket with `upper_bound` >= `value`, increment bucket `count`
7. Update `updated_at` timestamp to now
8. Merge provided `labels` with existing labels
9. Check cardinality limit, reject if exceeded
10. Release atomic access

**Error Conditions**:
- `CardinalityExceeded`: Too many unique label combinations

**Concurrency**: Thread-safe via atomic operations

### scrape_metrics(registry: Arc<MetricRegistry>) -> String

**Purpose**: Export all metrics in configured format for external scraping.

**Parameters**:
- `registry` - Metric registry to scrape

**Returns**: `String` - Formatted metric data

**Algorithm**:
1. Acquire read lock on registry `metrics` map
2. Increment `scrape_count` atomically
3. For each metric in registry:
   a. Format metric name, description, type
   b. Format metric value based on `metric_type`
   c. Format label dimensions
   d. Append to output string
4. Release read lock
5. Return formatted string

**Error Conditions**: None (errors handled by returning partial data)

**Concurrency**: Thread-safe via registry read lock

### register_health_check(name: String, check_fn: Box<dyn HealthCheckFn>, critical: bool)

**Purpose**: Register a health check function.

**Parameters**:
- `name` - Unique health check identifier
- `check_fn` - Function that performs the check
- `critical` - Whether failure marks system unhealthy

**Returns**: None

**Algorithm**:
1. Validate `name` is unique among registered checks
2. Wrap `check_fn` in health check wrapper
3. Append to `health_checker.checks` vector
4. Store `critical` flag in wrapper

**Error Conditions**:
- `DuplicateCheck`: Health check with this name exists

**Concurrency**: Thread-safe via internal mutex

### run_health_checks(checker: Arc<HealthChecker>) -> Vec<HealthCheck>

**Purpose**: Execute all registered health checks and return results.

**Parameters**:
- `checker` - Health checker to run

**Returns**: `Vec<HealthCheck>` - Results from all checks

**Algorithm**:
1. Create empty results vector
2. For each registered check:
   a. Record start time
   b. Execute check function with timeout
   c. Record end time and calculate duration
   d. Create `HealthCheck` result with status, message, timing
   e. Append to results vector
3. Aggregate overall status:
   a. If any critical check failed, set `overall_status` to `Unhealthy`
   b. Else if any non-critical check failed, set to `Degraded`
   c. Else set to `Healthy`
4. Update `last_update` timestamp
5. Return results vector

**Error Conditions**: None (errors captured in individual check results)

**Concurrency**: Thread-safe via checker mutex

### register_alert_rule(rule: AlertRule) -> Result<Uuid>

**Purpose**: Register a new alert rule.

**Parameters**:
- `rule` - Alert rule to register

**Returns**: `Uuid` - Assigned rule identifier

**Algorithm**:
1. Generate new UUID for rule
2. Validate rule fields (metric exists, threshold valid)
3. Store rule in alert engine
4. Return generated UUID

**Error Conditions**:
- `MetricNotFound`: Referenced metric does not exist
- `InvalidThreshold`: Threshold value is invalid

**Concurrency**: Thread-safe via alert engine mutex

### evaluate_alert_rules(registry: Arc<MetricRegistry>, engine: Arc<AlertEngine>) -> Vec<Alert>

**Purpose**: Evaluate all alert rules and trigger new alerts if conditions met.

**Parameters**:
- `registry` - Metric registry for current values
- `engine` - Alert engine with registered rules

**Returns**: `Vec<Alert>` - Newly triggered alerts

**Algorithm**:
1. Create empty alerts vector
2. For each enabled rule in engine:
   a. Look up current metric value from registry
   b. Evaluate condition (greater than, less than, etc.)
   c. Check if condition true
   d. If true:
      i. Check if rule in cooldown period (compare last alert time)
      ii. If not in cooldown:
          - Create new `Alert` with current timestamp
          - Append to alerts vector
          - Record alert time for cooldown tracking
3. Return alerts vector

**Error Conditions**: None (errors logged, not returned)

**Concurrency**: Thread-safe via registry read lock and engine mutex

### export_prometheus(registry: Arc<MetricRegistry>) -> String

**Purpose**: Export metrics in Prometheus text format.

**Parameters**:
- `registry` - Metric registry to export

**Returns**: `String` - Prometheus-formatted metrics

**Algorithm**:
1. Start output with "# TYPE metric_name metric_type" comments
2. For each metric:
   a. Output HELP comment if description present
   b. Output TYPE declaration
   c. Format labels as '{label1="value1",label2="value2"}'
   d. Output "metric_name{labels} value" line
   e. For histograms, output bucket lines with "_bucket" suffix
   f. For summaries, output quantile lines with "_quantile" suffix
3. Return complete output string

**Error Conditions**: None

**Concurrency**: Thread-safe via registry read lock

## Invariants

- Metric names are unique within registry
- Metric names match snake_case regex pattern
- Counter values are monotonically increasing
- Histogram buckets are sorted ascending
- Health checks complete within timeout period
- Alert rules respect cooldown period
- Cardinatility limits enforced to prevent memory blowout
- Scrape operations never block writes for more than 100ms

## Dependencies

- **Uses**:
  - `crate::db` - For database-level metrics
  - `crate::pager` - For pager-level metrics
  - `crate::btree` - For B+Tree-level metrics
  - `crate::mvcc` - For MVCC-level metrics
- **Used by**:
  - `crate::main` - For CLI monitoring commands
  - External monitoring systems (Prometheus, Grafana) via scrape endpoint

## Rust Implementation Guidance

### Module Structure

The Rust module should be organized as follows:

```
src/monitoring/
├── mod.rs              # Public exports and module initialization
├── metrics.rs          # Metric types and registry
├── health.rs           # Health check framework
├── alerts.rs           # Alert engine and rules
├── export.rs           # Export formats (Prometheus, OTLP, JSON)
└── collector.rs        # Pluggable metric collectors
```

### Type Definitions

- **Metric**: Should use `enum MetricValue` for different metric type representations
- **MetricRegistry**: Should use `RwLock<HashMap<String, Metric>>` for concurrent access
- **AtomicU64 / AtomicI64**: Use for counter and gauge values to avoid lock contention
- **Histogram**: Should store buckets in `Vec<(u64, AtomicU64)>` for thread-safe updates

### Concurrency

- **Pattern**: Use `RwLock` for registry reads (scrapes) and writes (registration)
- **Pattern**: Use `AtomicU64` for metric values to allow lock-free increments
- **Pattern**: Use `crossbeam::channel` for async alert delivery
- **Pattern**: Use `dashmap::DashMap` for high-contention label cardinality tracking

### Key Decisions

- **Arc vs Rc**: Use `Arc` for metric handles shared across threads
- **HashMap vs DashMap**: Use `DashMap` for label cardinality tracking (high write contention)
- **Channel Type**: Use `crossbeam::channel::bounded(1000)` for alert delivery
- **Histogram Algorithm**: Use fixed buckets (not reservoir sampling) for predictable memory

### Implementation Notes

Step 1: Start with core metric types (Counter, Gauge, Histogram) and registry
Step 2: Implement atomic operations for lock-free metric updates
Step 3: Add health check framework with timeout support
Step 4: Implement alert engine with rule evaluation and cooldowns
Step 5: Add export formats (Prometheus priority, then JSON)
Step 6: Implement cardinality limiting to prevent metric explosion

### Testing Strategy

**Unit tests needed for**:
- Metric registration and duplicate detection
- Counter increment and gauge set operations
- Histogram bucket counting and percentile calculation
- Health check execution and timeout handling
- Alert rule evaluation and cooldown enforcement
- Prometheus export formatting

**Property tests for**:
- Counter monotonicity (never decreases)
- Histogram bucket sums equal total count
- Alert cooldown periods respected

**Integration scenarios**:
- Scrape endpoint under concurrent metric updates
- Health check with hanging check function (timeout)
- Alert rule evaluation with rapid metric changes
- Cardinality limit enforcement with high-dimensional labels
