# Replication Configuration - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-replication-overview.md](./10-replication-overview.md)

## Purpose

This specification defines the configuration types and validation for replication components. Configuration covers both primary and replica roles, including network settings, buffer sizes, timeouts, and operational parameters.

## Types

### ReplicationConfig

**Description**: Top-level configuration for replication, specifying role and role-specific settings.

**Fields**:
- role: ReplicationRole - Whether this node operates as primary or replica
- primary_config: Option Box PrimaryConfig - Present when role is Primary
- replica_config: Option Box ReplicaConfig - Present when role is Replica

**Size**: 1 byte (discriminant) plus role-specific config size

**Invariants**: Exactly one of primary_config or replica_config must be present based on role. Both cannot be Some or None simultaneously.

### ReplicationRole

**Description**: Enum defining the operational role of the node in replication topology.

**Variants**:
- Primary: Node accepts writes and streams commit log to replicas
- Replica: Node receives commit stream from primary and serves read-only queries

**Invariants**: Role is fixed at startup and cannot be changed without restart.

### PrimaryConfig

**Description**: Configuration specific to primary node operation.

**Fields**:
- listen_address: String - Network address to bind for replica connections (e.g., "0.0.0.0:7233")
- max_replicas: u32 - Maximum number of concurrent replica connections (default: 10, range: 1-100)
- replication_buffer_size: u64 - Size of in-memory buffer for commit records in bytes (default: 104857600, range: 1048576-1073741824)
- heartbeat_interval_ms: u64 - Interval between heartbeat messages in milliseconds (default: 1000, range: 100-10000)
- heartbeat_timeout_ms: u64 - Timeout before replica considered stale in milliseconds (default: 5000, range: 1000-60000)
- batch_size: u32 - Maximum number of commit records per batch (default: 100, range: 1-10000)
- batch_flush_interval_ms: u64 - Maximum time before flushing batch in milliseconds (default: 10, range: 1-1000)
- enable_compression: bool - Whether to enable zstd compression for payloads (default: true)
- compression_threshold_bytes: u32 - Minimum payload size to trigger compression (default: 65536, range: 1024-1048576)
- tls_enabled: bool - Whether TLS is required for connections (default: true)
- tls_cert_path: Option String - Path to TLS certificate file (required if tls_enabled)
- tls_key_path: Option String - Path to TLS private key file (required if tls_enabled)
- tls_ca_path: Option String - Path to TLS CA certificate for client verification
- replica_whitelist: Option Vec String - List of allowed replica identifiers (if None, allow all)
- connection_rate_limit: u32 - Maximum new connections per second (default: 10, range: 1-1000)

**Size**: Approximately 200 bytes depending on string lengths

**Invariants**:
- listen_address must be a valid socket address (IP:port)
- max_replicas must be between 1 and 100 inclusive
- replication_buffer_size must be between 1MB and 1GB inclusive, power of 2 recommended
- heartbeat_timeout_ms must be greater than heartbeat_interval_ms
- batch_flush_interval_ms must be less than heartbeat_timeout_ms
- If tls_enabled is true, tls_cert_path and tls_key_path must be Some

### ReplicaConfig

**Description**: Configuration specific to replica node operation.

**Fields**:
- primary_address: String - Address of primary node to connect to (e.g., "primary.example.com:7233")
- replica_id: u64 - Unique identifier for this replica (default: random, range: 1-18446744073709551615)
- replication_lag_target_ms: u64 - Target maximum replication lag in milliseconds (default: 100, range: 10-60000)
- reconnect_interval_ms: u64 - Initial reconnect interval in milliseconds (default: 1000, range: 100-60000)
- reconnect_max_attempts: u32 - Maximum reconnection attempts before giving up (default: 10, range: 1-1000)
- reconnect_max_delay_ms: u64 - Maximum exponential backoff delay in milliseconds (default: 60000, range: 5000-600000)
- bootstrap_on_start: bool - Whether to bootstrap from snapshot on first start (default: false)
- bootstrap_timeout_secs: u64 - Maximum time to wait for bootstrap completion in seconds (default: 3600, range: 60-86400)
- apply_queue_size: u32 - Size of queue for received commit records awaiting application (default: 1000, range: 100-100000)
- enable_compression: bool - Whether to accept compressed payloads from primary (default: true)
- tls_enabled: bool - Whether TLS is required for connection (default: true)
- tls_cert_path: Option String - Path to TLS client certificate file (if mutual TLS)
- tls_key_path: Option String - Path to TLS client private key file (if mutual TLS)
- tls_ca_path: Option String - Path to TLS CA certificate for server verification
- primary_server_id: Option u64 - Expected primary server identifier (if Some, validate on connect)

**Size**: Approximately 200 bytes depending on string lengths

**Invariants**:
- primary_address must be a valid socket address or resolvable hostname
- replica_id must be unique across all replicas
- reconnect_max_delay_ms must be greater than reconnect_interval_ms
- bootstrap_timeout_secs must be sufficient for expected database size
- If tls_enabled is true, tls_ca_path must be Some

### ReplicaInfo

**Description**: Runtime state tracking for a connected replica (used by primary).

**Fields**:
- replica_id: u64 - Unique identifier for this replica
- connected: bool - Current connection status
- last_ack_sequence: u64 - Highest sequence number acknowledged by replica
- current_lsn: LSN - Current LSN acknowledged by replica
- replication_lag_ms: u64 - Current replication lag in milliseconds
- connect_time: Option Instant - When replica connected
- last_heartbeat: Option Instant - Time of last heartbeat sent to replica
- last_ack_received: Option Instant - Time of last acknowledgment received from replica

**Invariants**:
- If connected is true, connect_time must be Some
- last_ack_sequence must be monotonically increasing
- current_lsn must be less than or equal to primary current LSN

### BufferWatermarks

**Description**: Watermarks for buffer management and backpressure.

**Fields**:
- low_watermark_percent: u8 - Threshold to resume after backpressure (default: 60, range: 10-90)
- high_watermark_percent: u8 - Threshold to apply backpressure (default: 80, range: 20-95)

**Size**: 2 bytes

**Invariants**: low_watermark_percent must be less than high_watermark_percent

## Functions

### ReplicationConfig::validate(&self) -> Result

**Purpose**: Validate configuration parameters and relationships.

**Returns**: Empty Result on success, error on validation failure

**Algorithm**:
1. Match on role:
    a. Primary:
        i. Validate primary_config is Some
        ii. Validate primary_config contents using PrimaryConfig::validate()
    b. Replica:
        i. Validate replica_config is Some
        ii. Validate replica_config contents using ReplicaConfig::validate()
2. Return success or validation error

**Error Conditions**:
- ConfigError: Mismatch between role and config presence
- ValidationError: Role-specific validation failed

**Concurrency**: Safe to call from any thread.

### PrimaryConfig::validate(&self) -> Result

**Purpose**: Validate primary-specific configuration parameters.

**Returns**: Empty Result on success

**Algorithm**:
1. Validate listen_address is a valid socket address
2. Validate max_replicas is between 1 and 100
3. Validate replication_buffer_size is between 1MB and 1GB
4. Validate heartbeat_timeout_ms is greater than heartbeat_interval_ms
5. Validate batch_flush_interval_ms is less than heartbeat_timeout_ms
6. If tls_enabled is true:
    a. Validate tls_cert_path is Some
    b. Validate tls_key_path is Some
    c. Validate certificate files exist and are readable
7. Validate replica_whitelist (if present) contains valid replica IDs
8. Validate connection_rate_limit is positive
9. Return success

**Error Conditions**:
- InvalidAddress: listen_address is not a valid socket address
- InvalidRange: Parameter outside valid range
- MissingRequiredField: Required TLS field missing when tls_enabled
- FileNotFound: TLS certificate file does not exist

**Concurrency**: Safe to call from any thread.

### ReplicaConfig::validate(&self) -> Result

**Purpose**: Validate replica-specific configuration parameters.

**Returns**: Empty Result on success

**Algorithm**:
1. Validate primary_address is a valid socket address or hostname
2. Validate replica_id is greater than zero
3. Validate reconnect_max_delay_ms is greater than reconnect_interval_ms
4. Validate reconnect_max_attempts is positive
5. Validate bootstrap_timeout_secs is at least 60 seconds
6. Validate apply_queue_size is at least 100
7. If tls_enabled is true:
    a. Validate tls_ca_path is Some
    b. Validate CA file exists and is readable
8. Return success

**Error Conditions**:
- InvalidAddress: primary_address is not a valid address
- InvalidRange: Parameter outside valid range
- MissingRequiredField: Required TLS field missing when tls_enabled
- FileNotFound: TLS CA file does not exist

**Concurrency**: Safe to call from any thread.

### PrimaryConfig::buffer_watermarks(&self) -> BufferWatermarks

**Purpose**: Calculate buffer watermark thresholds based on buffer size.

**Returns**: BufferWatermarks with calculated thresholds

**Algorithm**:
1. Create BufferWatermarks with default percentages
2. Calculate low_watermark_bytes as (replication_buffer_size * low_watermark_percent) / 100
3. Calculate high_watermark_bytes as (replication_buffer_size * high_watermark_percent) / 100
4. Return BufferWatermarks

**Concurrency**: Safe to call from any thread.

### ReplicaConfig::calculate_reconnect_delay(&self, attempt: u32) -> Duration

**Purpose**: Calculate exponential backoff delay for reconnection attempt.

**Parameters**:
- attempt: u32 - Reconnection attempt number (0-indexed)

**Returns**: Duration to wait before next reconnection attempt

**Algorithm**:
1. Calculate exponential delay as reconnect_interval_ms * 2^attempt
2. Cap exponential delay at reconnect_max_delay_ms
3. Add random jitter of plus or minus 10 percent
4. Return Duration from milliseconds

**Example**:
- Attempt 0: 1000ms plus or minus 100ms
- Attempt 1: 2000ms plus or minus 200ms
- Attempt 2: 4000ms plus or minus 400ms
- Attempt 3: 8000ms plus or minus 800ms
- ...

**Concurrency**: Safe to call from any thread.

### ReplicationConfig::from_file(path: &Path) -> Result ReplicationConfig

**Purpose**: Load configuration from TOML file.

**Parameters**:
- path: Path - Path to configuration file

**Returns**: Result wrapping ReplicationConfig

**Algorithm**:
1. Read file contents
2. Parse TOML format
3. Deserialize into ReplicationConfig struct
4. Validate configuration using validate()
5. Return validated config

**Error Conditions**:
- IoError: Failed to read file
- ParseError: Invalid TOML syntax
- ValidationError: Configuration validation failed

**Concurrency**: Should not be called concurrently on same file.

### ReplicationConfig::to_file(&self, path: &Path) -> Result

**Purpose**: Save configuration to TOML file.

**Parameters**:
- path: Path - Path to write configuration file

**Returns**: Empty Result on success

**Algorithm**:
1. Validate configuration using validate()
2. Serialize to TOML format
3. Write to file atomically (write to temp file, then rename)
4. Return success

**Error Conditions**:
- IoError: Failed to write file
- SerializationError: Failed to serialize config

**Concurrency**: Should not be called concurrently on same file.

## Rust Implementation Guidance

### Struct Definitions

Use serde for serialization and validation:

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReplicationConfig {
    pub role: ReplicationRole,
    #[serde(flatten)]
    pub role_config: RoleConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RoleConfig {
    Primary(Box<PrimaryConfig>),
    Replica(Box<ReplicaConfig>),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct PrimaryConfig {
    pub listen_address: String,
    pub max_replicas: u32,
    pub replication_buffer_size: u64,
    // ... other fields
}

impl Default for PrimaryConfig {
    fn default() -> Self {
        Self {
            listen_address: "0.0.0.0:7233".to_string(),
            max_replicas: 10,
            replication_buffer_size: 100 * 1024 * 1024, // 100MB
            // ... other defaults
        }
    }
}
```

### Validation

Use validator crate for declarative validation:

```rust
use validator::Validate;

#[derive(Validate)]
pub struct PrimaryConfig {
    #[validate(range(min = 1, max = 100))]
    pub max_replicas: u32,

    #[validate(range(min = 1048576, max = 1073741824))]
    pub replication_buffer_size: u64,

    // ... other fields with validation
}
```

### Hot Reload

Use notify crate for file watching:

```rust
use notify::{Watcher, RecursiveMode, watcher};

fn watch_config(path: &Path) -> Result<impl Watcher> {
    let (tx, rx) = std::sync::mpsc::channel();
    let mut watcher = watcher(tx, Duration::from_secs(1))?;
    watcher.watch(path, RecursiveMode::NonRecursive)?;
    Ok(watcher)
}
```

### Error Handling

Define comprehensive error types:

```rust
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("Invalid address: {0}")]
    InvalidAddress(String),

    #[error("Value out of range: {field} must be between {min} and {max}")]
    InvalidRange { field: String, min: u64, max: u64 },

    #[error("Missing required field: {0}")]
    MissingRequiredField(String),

    #[error("File not found: {0}")]
    FileNotFound(String),

    #[error("Parse error: {0}")]
    ParseError(String),

    #[error("Validation failed: {0}")]
    ValidationError(String),
}
```

### Testing Strategy

Unit tests:
- Validate all default values
- Test validation with valid and invalid inputs
- Test watermark calculations
- Test exponential backoff calculation

Integration tests:
- Load config from file
- Save config to file
- Hot reload functionality

Property-based tests:
- All configs loaded from file validate successfully
- Exponential backoff always produces valid delays
- Watermarks always within buffer size

## Configuration File Example

### Primary Config (TOML)

```toml
role = "Primary"

listen_address = "0.0.0.0:7233"
max_replicas = 10
replication_buffer_size = 104857600  # 100MB

heartbeat_interval_ms = 1000
heartbeat_timeout_ms = 5000

batch_size = 100
batch_flush_interval_ms = 10

enable_compression = true
compression_threshold_bytes = 65536  # 64KB

tls_enabled = true
tls_cert_path = "/etc/northstar/primary.crt"
tls_key_path = "/etc/northstar/primary.key"
tls_ca_path = "/etc/northstar/ca.crt"

replica_whitelist = ["replica-1", "replica-2", "replica-3"]
connection_rate_limit = 10
```

### Replica Config (TOML)

```toml
role = "Replica"

primary_address = "primary.example.com:7233"
replica_id = 1

replication_lag_target_ms = 100

reconnect_interval_ms = 1000
reconnect_max_attempts = 10
reconnect_max_delay_ms = 60000  # 60 seconds

bootstrap_on_start = false
bootstrap_timeout_secs = 3600  # 1 hour

apply_queue_size = 1000

enable_compression = true

tls_enabled = true
tls_ca_path = "/etc/northstar/ca.crt"
primary_server_id = 42
```

## Monitoring and Observability

### Config Metrics

| Metric | Type | Description |
|--------|------|-------------|
| config_reload_total | Counter | Number of configuration reloads |
| config_reload_errors_total | Counter | Number of configuration reload errors |
| config_validation_errors_total | Counter | Number of validation errors |

### Health Checks

Configuration is valid if:
- All required fields present
- All values within valid ranges
- TLS certificate files exist and are readable
- listen_address can be bound to (for primary)
- primary_address can be resolved (for replica)
