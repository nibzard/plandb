# Graceful Degradation

## Purpose

Graceful degradation system for NorthstarDB that enables continued operation under adverse conditions (resource exhaustion, external service failures, high load). The system automatically detects degraded conditions, activates fallback modes, maintains partial functionality, and recovers automatically when conditions improve. Goal is to prevent catastrophic failures and provide predictable behavior even under stress.

## Types

### DegradationLevel

**Description**: Current operating level of the database system.

**Variants**:
- `Full` - All functionality available, normal operation
- `Reduced` - Some features limited but core operations work
- `Minimal` - Critical operations only, best-effort service
- `Maintenance` - Read-only mode, writes rejected
- `Emergency` - Safe shutdown in progress

**Transitions**:
- `Full` -> `Reduced` (resource pressure detected)
- `Reduced` -> `Minimal` (pressure increases)
- `Minimal` -> `Emergency` (critical thresholds exceeded)
- `Emergency` -> `Full` (after recovery and validation)
- Any level can recover toward `Full` when conditions improve

### DegradationTrigger

**Description**: Event or condition that triggers degradation mode change.

**Variants**:
- `MemoryPressure` - Available memory below threshold (default: <10% free)
- `DiskSpaceLow` - Disk space below threshold (default: <5% free)
- `CpuSaturation` - CPU usage sustained above threshold (default: >90% for 30 seconds)
- `ConnectionPoolExhausted` - No available connections (default: 0 free for 5 seconds)
- `CacheEvictionRateHigh` - Cache evictions exceed insertions (default: 2:1 ratio)
- `WriteLatencyHigh` - Write latency above threshold (default: >1000ms p99)
- `ReadLatencyHigh` - Read latency above threshold (default: >500ms p99)
- `ExternalServiceUnavailable` - AI plugin or external service down
- `ManualOverride` - Administrator-triggered degradation

### DegradationAction

**Description**: Action taken when entering a degradation level.

**Variants**:
- `ReduceCacheSize` - Shrink cache to free memory (target: 50% reduction)
- `DisableBackgroundTasks` - Pause maintenance, compaction, statistics
- `ThrottleWrites` - Rate-limit write operations (target: 50% reduction)
- `RejectNonCriticalQueries` - Return error for non-essential reads
- `SwitchToReadOnly` - Reject all write operations
- `FlushCaches` - Clear all caches to free memory
- `ReduceConnectionPool` - Close idle connections (target: 50% reduction)
- `DisableAiFeatures` - Turn off AI plugin system
- `EnableFastPath` - Use optimized code paths bypassing safety checks

### DegradationPolicy

**Description**: Policy defining triggers and actions for degradation levels.

**Fields**:
- `level: DegradationLevel` - Policy level
- `triggers: Vec<DegradationTrigger>` - Conditions that trigger this level
- `actions: Vec<DegradationAction>` - Actions to take when entering this level
- `recovery_conditions: Vec<RecoveryCondition>` - Conditions to exit this level
- `min_duration: Duration` - Minimum time to stay in level (default: 30 seconds) to prevent flapping
- `max_duration: Option<Duration>` - Maximum time before forced action (None = no limit)

**RecoveryCondition**:
- `metric_name: String` - Metric to monitor (e.g., "memory_free_percent")
- `threshold: f64` - Value that indicates recovery
- `duration: Duration` - How long condition must hold (default: 60 seconds)

**Invariants**:
- `min_duration` >= 1 second
- `max_duration` > `min_duration` if present
- Cannot transition directly from `Full` to `Emergency` (must go through intermediate levels)

### DegradationState

**Description**: Current state of the degradation system.

**Fields**:
- `current_level: DegradationLevel` - Current operating level
- `previous_level: DegradationLevel` - Previous level (for recovery tracking)
- `level_since: Instant` - When current level was entered
- `active_triggers: Vec<DegradationTrigger>` - Triggers that caused current level
- `active_actions: Vec<DegradationAction>` - Actions currently in effect
- `recovery_attempt_count: u32` - Number of recovery attempts made
- `last_transition: Instant` - When last level change occurred
- `flap_count: u32` - Number of rapid level changes (indicates instability)

**Invariants**:
- `level_since` is never in the future
- `last_transition` >= `level_since`
- `recovery_attempt_count` is monotonically increasing
- `flap_count` increases when level changes within `min_duration` of previous change

### ResourceMonitor

**Description**: Monitors system resources and detects degradation triggers.

**Fields**:
- `config: Arc<DegradationConfig>` - Shared configuration
- `current_state: Arc<RwLock<DegradationState>>` - Current degradation state
- `poll_interval: Duration` - How often to check resources (default: 5 seconds)
- `history: VecDeque<ResourceSnapshot>` - Recent resource history (max: 100 entries)
- `thresholds: ResourceThresholds` - Configured thresholds for each resource

**ResourceSnapshot**:
- `timestamp: Instant` - When snapshot was taken
- `memory_free_percent: f64` - Free memory percentage
- `disk_free_percent: f64` - Free disk percentage
- `cpu_usage_percent: f64` - CPU usage percentage
- `connection_pool_free: u32` - Free connection count
- `cache_hit_rate: f64` - Current cache hit rate
- `write_latency_p99: Duration` - 99th percentile write latency
- `read_latency_p99: Duration` - 99th percentile read latency

**ResourceThresholds**:
- `memory_warning_percent: f64` - Warning threshold (default: 20%)
- `memory_critical_percent: f64` - Critical threshold (default: 10%)
- `disk_warning_percent: f64` - Warning threshold (default: 10%)
- `disk_critical_percent: f64` - Critical threshold (default: 5%)
- `cpu_warning_percent: f64` - Warning threshold (default: 80%)
- `cpu_critical_percent: f64` - Critical threshold (default: 90%)
- `latency_warning_ms: u64` - Warning threshold (default: 500ms)
- `latency_critical_ms: u64` - Critical threshold (default: 1000ms)

**Size**: ~100KB (100 snapshots x ~1KB each)
**Invariants**:
- `history` never exceeds 100 entries
- All percentages in range 0.0 to 100.0
- Critical thresholds <= warning thresholds

### DegradationConfig

**Description**: Configuration for degradation behavior.

**Fields**:
- `enabled: bool` - Whether degradation is enabled (default: true)
- `policies: Vec<DegradationPolicy>` - Ordered policies for each level
- `monitoring_interval: Duration` - Resource monitoring interval (default: 5 seconds)
- `flap_threshold: u32` - Max level changes before marking unstable (default: 5 in 5 minutes)
- `auto_recovery: bool` - Whether to auto-recover (default: true)
- `recovery_check_interval: Duration` - How often to check recovery (default: 30 seconds)
- `emergency_shutdown_timeout: Duration` - Max time in emergency before forced shutdown (default: 60 seconds)

**Invariants**:
- `monitoring_interval` >= 1 second
- `recovery_check_interval` >= `monitoring_interval`
- `emergency_shutdown_timeout` >= 10 seconds

### FallbackMode

**Description**: Active fallback mode for specific subsystems.

**Variants**:
- `CacheDisabled` - Caching disabled, direct access only
- `AiDisabled` - AI features disabled, basic operations only
- `BackgroundTasksPaused` - Maintenance tasks paused
- `WriteThrottled` - Writes rate-limited
- `ReadThrottled` - Reads rate-limited
- `QueryOptimizationDisabled` - Skip query optimization, use simple plans
- `IndexSeekDisabled` - Full table scan instead of index usage
- `CompressionDisabled` - Skip compression to save CPU

### FallbackManager

**Description**: Manages active fallback modes and coordinates transitions.

**Fields**:
- `active_modes: HashSet<FallbackMode>` - Currently active fallbacks
- `transition_history: VecDeque<TransitionEvent>` - Recent mode changes (max: 50 entries)
- `config: Arc<DegradationConfig>` - Shared configuration

**TransitionEvent**:
- `mode: FallbackMode` - Mode that changed
- `activated: bool` - True if activated, false if deactivated
- `timestamp: Instant` - When transition occurred
- `trigger: DegradationTrigger` - What caused the transition

**Size**: ~50KB (50 events x ~1KB each)
**Invariants**:
- `transition_history` never exceeds 50 entries
- Conflicting fallback modes are never both active (e.g., CacheDisabled and CacheDisabled)

### CircuitBreaker

**Description**: Circuit breaker pattern for external service calls (AI plugins, remote storage).

**Fields**:
- `state: CircuitState` - Current circuit state
- `failure_count: u32` - Consecutive failures
- `success_count: u32` - Consecutive successes (for recovery)
- `last_failure_time: Option<Instant>` - When last failure occurred
- `last_success_time: Option<Instant>` - When last success occurred
- `open_threshold: u32` - Failures before opening circuit (default: 5)
- `half_open_attempts: u32` - Attempts to make in half-open state (default: 3)
- `timeout: Duration` - How long to stay open before trying again (default: 60 seconds)

**CircuitState**:
- `Closed` - Normal operation, requests pass through
- `Open` - Circuit tripped, requests fail immediately
- `HalfOpen` - Testing if service recovered, limited requests allowed

**Invariants**:
- `failure_count` >= 0
- `success_count` >= 0
- `open_threshold` >= 1
- `timeout` >= 1 second
- Transition `Closed` -> `Open` when `failure_count` >= `open_threshold`
- Transition `Open` -> `HalfOpen` after `timeout` expires
- Transition `HalfOpen` -> `Closed` on `success_count` >= `half_open_attempts`
- Transition `HalfOpen` -> `Open` on any failure

### Throttler

**Description**: Rate limiter for operation throttling under load.

**Fields**:
- `rate_limit: u64` - Operations per second limit (0 = no limit)
- `burst_size: u64` - Allowed burst capacity (default: 10% of rate_limit)
- `current_tokens: f64` - Available tokens (decreases on operation, refills over time)
- `last_refill: Instant` - When tokens were last refilled
- `rejected_count: AtomicU64` - Total rejected operations
- `accepted_count: AtomicU64` - Total accepted operations

**Size**: ~64 bytes
**Invariants**:
- `rate_limit` >= 0
- `burst_size` <= `rate_limit` when `rate_limit` > 0
- `current_tokens` in range [0.0, `burst_size` as f64]
- `rejected_count` + `accepted_count` = total operations attempted
- Tokens refill at `rate_limit / 1 second` rate

## Functions

### monitor_resources(monitor: Arc<ResourceMonitor>) -> Vec<DegradationTrigger>

**Purpose**: Check current resource usage and return active triggers.

**Parameters**:
- `monitor` - Resource monitor with configuration

**Returns**: `Vec<DegradationTrigger>` - Detected triggers (empty if none)

**Algorithm**:
1. Create empty triggers vector
2. Get current resource snapshot:
   a. Read memory info from system (free memory, total memory)
   b. Read disk info (free space, total space)
   c. Read CPU usage (process and system)
   d. Read connection pool stats
   e. Read cache stats from metrics registry
   f. Read latency metrics (p99 write, p99 read)
3. Append snapshot to `history`
4. Compare each metric against thresholds:
   a. If `memory_free_percent` < `memory_critical_percent`:
      - Append `MemoryPressure` to triggers
   b. If `disk_free_percent` < `disk_critical_percent`:
      - Append `DiskSpaceLow` to triggers
   c. If `cpu_usage_percent` > `cpu_critical_percent` for 3 consecutive snapshots:
      - Append `CpuSaturation` to triggers
   d. If `connection_pool_free` == 0 for 3 consecutive snapshots:
      - Append `ConnectionPoolExhausted` to triggers
   e. If `cache_hit_rate` < 0.5 for 5 consecutive snapshots:
      - Append `CacheEvictionRateHigh` to triggers
   f. If `write_latency_p99` > `latency_critical_ms`:
      - Append `WriteLatencyHigh` to triggers
   g. If `read_latency_p99` > `latency_critical_ms`:
      - Append `ReadLatencyHigh` to triggers
5. Return triggers vector

**Error Conditions**: None (errors logged, continue with partial data)

**Concurrency**: Thread-safe via monitor config lock

### evaluate_degradation_level(state: Arc<RwLock<DegradationState>>, triggers: Vec<DegradationTrigger>, config: Arc<DegradationConfig>) -> DegradationLevel

**Purpose**: Determine appropriate degradation level based on active triggers.

**Parameters**:
- `state` - Current degradation state
- `triggers` - Active degradation triggers
- `config` - Degradation configuration with policies

**Returns**: `DegradationLevel` - Recommended level

**Algorithm**:
1. Get current level from state
2. Check if any triggers present:
   a. If no triggers:
      - Return `Full` (recovery possible)
3. If triggers present:
   a. Check for emergency triggers:
      - If `MemoryPressure` with <5% free:
         - Return `Emergency`
      - If `DiskSpaceLow` with <2% free:
         - Return `Emergency`
   b. Check for minimal triggers:
      - If `MemoryPressure` with <10% free:
         - Return `Minimal`
      - If `CpuSaturation` with >95% CPU:
         - Return `Minimal`
   c. Check for reduced triggers:
      - If any trigger present:
         - Return `Reduced`
4. Enforce min_duration:
   a. Get `level_since` from current state
   b. Calculate time in current level
   c. If time < `min_duration` from policy:
      - Return current level (prevent flapping)
5. Return calculated level

**Error Conditions**: None

**Concurrency**: Thread-safe via state read lock

### execute_degradation_actions(level: DegradationLevel, actions: Vec<DegradationAction>, fallback_manager: Arc<FallbackManager>, db: Arc<Db>)

**Purpose**: Execute actions for entering a degradation level.

**Parameters**:
- `level` - Target degradation level
- `actions` - Actions to execute
- `fallback_manager` - Fallback mode manager
- `db` - Database handle for action execution

**Returns**: None

**Algorithm**:
1. For each action in `actions`:
   a. Match action type:
      - `ReduceCacheSize`:
         i. Call `db.page_cache().set_max_size(current_size / 2)`
         ii. Record fallback activation
      - `DisableBackgroundTasks`:
         i. Call `db.pause_background_tasks()`
         ii. Record fallback activation
      - `ThrottleWrites`:
         i. Get current write rate from metrics
         ii. Call `db.set_write_rate_limit(current_rate / 2)`
         iii. Record fallback activation
      - `RejectNonCriticalQueries`:
         i. Set query rejection flag in db config
         ii. Record fallback activation
      - `SwitchToReadOnly`:
         i. Call `db.set_read_only(true)`
         ii. Record fallback activation
      - `FlushCaches`:
         i. Call `db.page_cache().flush_all()`
         ii. Call `db.node_cache().flush_all()`
         iii. Record fallback activation
      - `ReduceConnectionPool`:
         i. Call `db.connection_pool().set_max_size(current_size / 2)`
         ii. Record fallback activation
      - `DisableAiFeatures`:
         i. Call `db.ai_plugin_manager().disable_all()`
         ii. Record fallback activation
      - `EnableFastPath`:
         i. Set fast_path flag in db config
         ii. Record fallback activation
   b. Log action execution with result
2. Update degradation state with new level

**Error Conditions**:
- Action failures are logged but do not prevent subsequent actions
- Failed actions are retried on next evaluation cycle

**Concurrency**: Actions execute sequentially under state lock

### check_recovery_conditions(state: Arc<RwLock<DegradationState>>, monitor: Arc<ResourceMonitor>, config: Arc<DegradationConfig>) -> bool

**Purpose**: Check if recovery conditions are met for current degradation level.

**Parameters**:
- `state` - Current degradation state
- `monitor` - Resource monitor for current metrics
- `config` - Degradation configuration with policies

**Returns**: `bool` - True if recovery is possible

**Algorithm**:
1. Get current level and policy from config
2. Get current resource snapshot from monitor
3. For each `recovery_condition` in policy:
   a. Look up metric value from snapshot
   b. Compare against threshold:
      - If `threshold` is minimum acceptable (e.g., memory_percent):
         - Check if metric >= threshold
      - If `threshold` is maximum acceptable (e.g., cpu_percent):
         - Check if metric <= threshold
   c. If condition not met, return false (not ready for recovery)
4. Check minimum duration:
   a. Get `level_since` from state
   b. Calculate time in current level
   c. If time < policy `min_duration`, return false
5. All conditions met, return true

**Error Conditions**: None (assume conditions not met on error)

**Concurrency**: Thread-safe via state and monitor read locks

### recover_to_full(state: Arc<RwLock<DegradationState>>, fallback_manager: Arc<FallbackManager>, db: Arc<Db>)

**Purpose**: Execute recovery actions to return to full operation.

**Parameters**:
- `state` - Current degradation state
- `fallback_manager` - Fallback mode manager
- `db` - Database handle

**Returns**: None

**Algorithm**:
1. Get current level from state
2. For each fallback in `fallback_manager.active_modes`:
   a. Deactivate fallback:
      - `CacheDisabled`:
         i. Call `db.page_cache().set_max_size(original_size)`
         ii. Call `db.node_cache().set_max_size(original_size)`
      - `AiDisabled`:
         i. Call `db.ai_plugin_manager().enable_all()`
      - `BackgroundTasksPaused`:
         i. Call `db.resume_background_tasks()`
      - `WriteThrottled`:
         i. Call `db.set_write_rate_limit(0)` (remove limit)
      - `ReadThrottled`:
         i. Call `db.set_read_rate_limit(0)` (remove limit)
      - `QueryOptimizationDisabled`:
         i. Clear query optimization disable flag
      - `IndexSeekDisabled`:
         i. Clear index seek disable flag
      - `CompressionDisabled`:
         i. Enable compression
   b. Remove from active modes
3. Set state level to `Full`
4. Reset `recovery_attempt_count` to 0
5. Log recovery completion

**Error Conditions**:
- Recovery failures are logged and partially recovered state is maintained

**Concurrency**: Recovery executes under state write lock

### circuit_breaker_call(breaker: Arc<CircuitBreaker>, operation: impl FnOnce() -> Result<T>) -> Result<T>

**Purpose**: Execute operation through circuit breaker with failure tracking.

**Parameters**:
- `breaker` - Circuit breaker instance
- `operation` - Operation to execute (closure)

**Returns**: `Result<T>` - Operation result or error

**Algorithm**:
1. Check circuit state:
   a. If `Open`:
      i. Check if `timeout` has expired since `last_failure_time`
      ii. If expired, transition to `HalfOpen` and reset `success_count`
      iii. If not expired, return `CircuitOpenError`
   b. If `HalfOpen`:
      i. Check if `success_count` >= `half_open_attempts`
      ii. If yes, transition to `Closed`
2. Execute `operation()`:
   a. If operation succeeds:
      i. Increment `success_count`
      ii. Update `last_success_time` to now
      iii. If in `HalfOpen` state, check if should transition to `Closed`
      iv. Return success result
   b. If operation fails:
      i. Increment `failure_count`
      ii. Update `last_failure_time` to now
      iii. If `failure_count` >= `open_threshold`:
          - Transition to `Open` state
      iv. Return failure result

**Error Conditions**:
- `CircuitOpenError`: Circuit is open, operation rejected

**Concurrency**: Thread-safe via atomic operations

### throttler_acquire(throttler: Arc<Throttler>, cost: u64) -> bool

**Purpose**: Attempt to acquire tokens for operation.

**Parameters**:
- `throttler` - Throttler instance
- `cost` - Token cost of operation (default: 1)

**Returns**: `bool` - True if operation allowed, false if rejected

**Algorithm**:
1. Calculate time elapsed since `last_refill`
2. Calculate tokens to add: `elapsed.as_secs_f64() * rate_limit / 1.0`
3. Add tokens to `current_tokens`, cap at `burst_size`
4. Update `last_refill` to now
5. Check if `current_tokens` >= `cost`:
   a. If yes:
      i. Subtract `cost` from `current_tokens`
      ii. Increment `accepted_count`
      iii. Return true
   b. If no:
      i. Increment `rejected_count`
      ii. Return false
3. Return result

**Error Conditions**: None

**Concurrency**: Thread-safe via atomic operations on counter and CAS loop on token count

## Invariants

- Degradation level changes respect min_duration to prevent flapping
- Recovery conditions must be met for min duration before level increase
- Circuit breaker transitions respect configured thresholds
- Throttler token count never exceeds burst_size
- Resource history never exceeds configured max size
- Fallback modes are deactivated in reverse order of activation
- Emergency level triggers safe shutdown within timeout

## Dependencies

- **Uses**:
  - `crate::monitoring` - For metric collection and thresholds
  - `crate::db` - For database operations to throttle/disable
  - `crate::cache` - For cache size manipulation
  - `crate::ai` - For AI plugin disable/enable
  - `crate::pager` - For background task control
- **Used by**:
  - `crate::main` - For CLI degradation commands
  - Database core - For automatic degradation under load

## Rust Implementation Guidance

### Module Structure

The Rust module should be organized as follows:

```
src/degradation/
├── mod.rs              # Public exports and module initialization
├── state.rs            # Degradation state and levels
├── monitor.rs          # Resource monitoring
├── fallback.rs         # Fallback mode management
├── circuit_breaker.rs  # Circuit breaker implementation
├── throttler.rs        # Rate limiting implementation
└── policy.rs           # Policy evaluation and execution
```

### Type Definitions

- **DegradationLevel**: Should use `enum` with variants for each level
- **DegradationState**: Should use `RwLock` for concurrent read/write access
- **ResourceMonitor**: Should use `VecDeque` for bounded history
- **CircuitBreaker**: Should use `AtomicU32` for failure/success counts
- **Throttler**: Should use `AtomicU64` for token count with CAS loop

### Concurrency

- **Pattern**: Use `RwLock` for degradation state (frequent reads, infrequent writes)
- **Pattern**: Use `AtomicU64` for circuit breaker counters (lock-free updates)
- **Pattern**: Use `Mutex` for throttler token bucket (single writer, multiple readers)
- **Pattern**: Use `crossbeam::channel::unbounded()` for trigger delivery to evaluation loop

### Key Decisions

- **Vec vs VecDeque**: Use `VecDeque` for history to allow efficient pop from front
- **HashMap vs HashSet**: Use `HashSet<FallbackMode>` for active modes (no associated data)
- **Channel Type**: Use `crossbeam::channel` for async trigger delivery
- **Circuit Breaker State**: Use `AtomicU8` with manual state encoding for lock-free transitions

### Implementation Notes

Step 1: Implement core degradation types (Level, Trigger, Action, State)
Step 2: Build resource monitor with system metrics collection
Step 3: Implement policy evaluation and action execution
Step 4: Add fallback mode manager with activation/deactivation
Step 5: Implement circuit breaker for external service protection
Step 6: Add throttler for rate limiting
Step 7: Integrate with monitoring system for metric-based triggers

### Testing Strategy

**Unit tests needed for**:
- Resource monitoring and trigger detection
- Degradation level evaluation with various trigger combinations
- Action execution and fallback mode activation
- Circuit breaker state transitions (closed, open, half-open)
- Throttler token acquisition and refill
- Recovery condition checking

**Property tests for**:
- Min_duration enforcement prevents rapid level changes
- Token count never exceeds burst_size
- Circuit breaker failure/success counts accurate
- Resource history bounded by max size

**Integration scenarios**:
- Full degradation cycle: Full -> Reduced -> Minimal -> Full
- Circuit breaker with intermittent failures
- Throttler under sustained high load
- Multiple simultaneous degradation triggers
- Recovery during sustained degraded conditions
