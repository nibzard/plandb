# Replication Publisher - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-replication-overview.md](./10-replication-overview.md), [10-replication-protocol.md](./10-replication-protocol.md)

## Purpose

This specification defines the Replication Publisher component running on the primary node. The Publisher is responsible for streaming commit records from the write-ahead log to all connected replicas, managing connections, tracking positions, and applying backpressure when needed.

## Component Overview

The Publisher acts as the source of truth for replication data flow:
1. Receives commit records from the WAL on write completion
2. Buffers commit records for replication to multiple replicas
3. Manages individual connections to each replica
4. Tracks per-replica positions for resumption after disconnect
5. Sends heartbeats for connection liveness
6. Applies backpressure when replicas fall behind

## Types

### Publisher

**Description**: Main publisher struct managing replication to all connected replicas.

**Fields**:
- config: Arc PrimaryConfig - Configuration for publisher behavior
- listener: TcpListener - TCP listener accepting replica connections
- buffer: ReplicationBuffer - In-memory buffer for commit records
- replicas: HashMap ReplicaId, ReplicaConnection - Map of connected replicas
- running: AtomicBool - Flag indicating publisher is running
- current_lsn: Arc AtomicU64 - Current LSN from WAL (shared with other components)
- sequence_counter: AtomicU64 - Counter for assigning sequence numbers per connection

**Invariants**: At most one publisher per primary node. Buffer capacity must not be exceeded during normal operation.

### ReplicaConnection

**Description**: Represents a single replica connection managed by the publisher.

**Fields**:
- replica_id: ReplicaId - Unique identifier for this replica
- socket: TcpStream - TCP socket for communication
- state: ConnectionState - Current connection state
- send_sequence: u64 - Next sequence number to send to this replica
- last_ack_sequence: u64 - Highest sequence acknowledged by this replica
- last_heartbeat_sent: Instant - Timestamp of last heartbeat sent
- last_ack_received: Instant - Timestamp of last acknowledgment received
- write_buffer: BytesMut - Buffer for pending writes to socket
- compression_enabled: bool - Whether compression is enabled for this connection

**Invariants**: send_sequence must be greater than or equal to last_ack_sequence. State must be Connected for normal message sending.

### ReplicationBuffer

**Description**: In-memory buffer holding commit records for replication.

**Fields**:
- records: VecDeque BufferedRecord - Queue of buffered commit records
- max_size: usize - Maximum buffer capacity in bytes
- current_size: usize - Current buffer usage in bytes
- low_watermark: usize - Threshold to resume after backpressure (60% of max)
- high_watermark: usize - Threshold to apply backpressure (80% of max)

**Invariants**: current_size must be less than or equal to max_size. Low watermark must be less than high watermark.

### BufferedRecord

**Description**: A commit record buffered for replication.

**Fields**:
- lsn: LSN - Log sequence number of this commit record
- sequence: u64 - Assigned sequence number for this replica
- record_bytes: Bytes - Serialized commit record
- checksum: u64 - Pre-calculated checksum for the record
- timestamp: Instant - When record was buffered

**Invariants**: checksum must match CRC-64 of record_bytes. LSN must be monotonically increasing within buffer.

### BackpressureState

**Description**: Indicates whether backpressure is being applied to writes.

**States**:
- Normal: Accepting all writes, buffer below high watermark
- Applying: Buffer exceeded high watermark, pausing new writes
- Relieving: Buffer dropped below low watermark after applying backpressure

## Functions

### Publisher::start(config: PrimaryConfig, current_lsn: Arc AtomicU64) -> Result Publisher

**Purpose**: Create and start the replication publisher on the primary node.

**Parameters**:
- config: PrimaryConfig - Configuration for publisher behavior
- current_lsn: Arc AtomicU64 - Shared atomic reference to current WAL LSN

**Returns**: Result wrapping Publisher instance

**Algorithm**:
1. Validate configuration parameters (listen address, buffer size)
2. Create TCP listener bound to configured address
3. Set socket options (TCP_NODELAY, SO_REUSEADDR)
4. Allocate ReplicationBuffer with configured capacity
5. Initialize empty replicas HashMap
6. Create atomic flags for running state
7. Spawn background heartbeat task
8. Spawn background connection accept task
9. Return Publisher instance

**Error Conditions**:
- IoError: Failed to bind to listen address or set socket options
- ConfigError: Invalid configuration parameters

**Concurrency**: Thread-safe via Arc and atomics. Can be shared across threads.

### Publisher::publish(&self, record: CommitRecord) -> Result

**Purpose**: Add a commit record to the replication stream for all connected replicas.

**Parameters**:
- record: CommitRecord - The commit record to replicate

**Returns**: Empty Result on success

**Algorithm**:
1. Check if backpressure state is Applying, return error if so
2. Serialize commit record to bytes
3. Calculate CRC-64 checksum of serialized bytes
4. Create BufferedRecord with LSN, pre-calculated checksum, and timestamp
5. Lock replication buffer mutex
6. Check if adding record would exceed buffer capacity
7. If capacity exceeded, transition to Applying backpressure state and return error
8. Add BufferedRecord to buffer queue
9. Update current_size
10. Unlock buffer mutex
11. For each connected replica in replicas HashMap:
    a. Assign next sequence number from replica send_sequence
    b. Create CommitRecordMessage with LSN and serialized record
    c. Add to replica write buffer
    d. Increment replica send_sequence
12. Check if buffer size exceeded high watermark, transition to Applying if so
13. Return success

**Error Conditions**:
- BufferOverflow: Replication buffer full, cannot publish (caller should retry)
- IoError: Network error adding to replica write buffer
- SerializationError: Failed to serialize commit record

**Concurrency**: Safe to call concurrently from multiple write transactions. Internally synchronized with mutex.

### Publisher::handle_replica(&self, socket: TcpStream, replica_id: ReplicaId) -> Result

**Purpose**: Accept and initialize a new replica connection.

**Parameters**:
- socket: TcpStream - Accepted TCP socket from replica
- replica_id: ReplicaId - Unique identifier for this replica

**Returns**: Empty Result on success

**Algorithm**:
1. Check if max_replicas limit reached, return error if so
2. Set socket options (TCP_NODELAY, keepalive)
3. Perform TLS handshake if enabled
4. Wait for HandshakeMessage from replica
5. Validate protocol version in handshake
6. Check replica_id against whitelist if configured
7. Create AcceptMessage with protocol version, current LSN, server_id
8. Send AcceptMessage to replica
9. Create ReplicaConnection with socket, state Connecting, send_sequence 0
10. Add connection to replicas HashMap
11. Spawn background task for this replica connection
12. Return success

**Error Conditions**:
- ReplicaLimit: Maximum replica connections reached
- ProtocolError: Handshake failed (version mismatch, invalid message)
- AuthenticationError: Replica not in whitelist or TLS handshake failed
- IoError: Network error during handshake

**Concurrency**: Safe to call concurrently when multiple replicas connect simultaneously.

### Publisher::send_heartbeats(&self)

**Purpose**: Send periodic heartbeat messages to all connected replicas (background task).

**Algorithm**:
1. Enter infinite loop with 1 second sleep interval
2. Check running flag, exit if false
3. For each replica in replicas HashMap:
    a. Check if state is Connected, skip if not
    b. Create HeartbeatMessage with current LSN and current timestamp
    c. Add heartbeat to replica write buffer
    d. Update last_heartbeat_sent timestamp
    e. Check if time since last_ack_received exceeds heartbeat timeout (5 seconds)
    f. If timeout exceeded, mark replica as stale and initiate reconnection
4. Sleep for 1 second
5. Repeat from step 2

**Error Conditions**: None - heartbeat failures are logged but don't return error

**Concurrency**: Runs as dedicated background task. Should not be called directly.

### Publisher::process_replica_connection(&self, replica_id: ReplicaId)

**Purpose**: Background task for sending messages to and receiving acknowledgments from a specific replica.

**Parameters**:
- replica_id: ReplicaId - Replica identifier for this connection

**Algorithm**:
1. Get replica connection from replicas HashMap
2. Enter infinite loop
3. Check if running flag is false or connection state is not Connected, break
4. Flush write buffer to socket:
    a. Lock replica write_buffer mutex
    b. Write all pending bytes to socket
    c. Clear write buffer
    d. Unlock mutex
5. Receive messages from replica:
    a. Read FrameHeader from socket
    b. Read message payload based on message_type
    c. Handle AckMessage:
        i. Update replica last_ack_sequence
        ii. Update replica last_ack_received timestamp
        iii. Update replication lag from lag_ms field
        iv. Call release_buffered_records() to free acknowledged records
    d. Handle ErrorMessage:
        i. Log error with replica_id and error_code
        ii. If error is ChecksumInvalid (1004), re-send affected messages
        iii. If error is SequenceGap (1007), re-send missing messages
    f. Handle other message types as needed
6. If connection error or timeout, transition to Disconnected state
7. Call ReplicaConnection::reconnect() to attempt reconnection
8. Repeat from step 3

**Error Conditions**:
- IoError: Connection lost or network error
- ProtocolError: Invalid message format or type

**Concurrency**: Each replica connection has dedicated background task. Tasks run concurrently.

### Publisher::release_buffered_records(&self, replica_id: ReplicaId, sequence: u64)

**Purpose**: Release buffered records that have been acknowledged by all replicas.

**Parameters**:
- replica_id: ReplicaId - Replica that sent acknowledgment
- sequence: u64 - Highest sequence acknowledged

**Algorithm**:
1. Lock replication buffer mutex
2. Iterate through buffered records in order
3. For each record, check if all replicas have acknowledged its sequence
4. Remove records acknowledged by all replicas from buffer
5. Update current_size
6. If buffer size dropped below low_watermark, transition to Relieving backpressure state
7. Unlock buffer mutex

**Concurrency**: Called from replica connection tasks when acknowledgments received.

### Publisher::track_replica_position(&self, replica_id: ReplicaId, ack: AckMessage)

**Purpose**: Update the acknowledged position and metrics for a specific replica.

**Parameters**:
- replica_id: ReplicaId - Replica identifier
- ack: AckMessage - Acknowledgment message from replica

**Algorithm**:
1. Get replica connection from replicas HashMap
2. Update replica last_ack_sequence to ack.sequence
3. Update replica last_ack_received to current time
4. Calculate replication lag from ack.lag_ms
5. If lag exceeds configured target, emit alert metric
6. Call release_buffered_records() with ack.sequence
7. Return updated replica info

**Concurrency**: Called from replica connection tasks when acknowledgments received.

### Publisher::shutdown(&self) -> Result

**Purpose**: Gracefully shutdown the publisher and all replica connections.

**Algorithm**:
1. Set running flag to false
2. Signal all background tasks to stop
3. For each replica in replicas HashMap:
    a. Send shutdown message if supported
    b. Close socket
    c. Wait for connection task to exit
4. Close TCP listener
5. Drain replication buffer
6. Return success

**Error Conditions**: None - shutdown is best-effort

**Concurrency**: Should be called once when shutting down primary node.

### ReplicaConnection::send_message(&mut self, message: ReplicationMessage) -> Result

**Purpose**: Add a message to the write buffer for this replica.

**Parameters**:
- message: ReplicationMessage - Message to send

**Algorithm**:
1. Serialize message to bytes using protocol framing
2. Lock write_buffer mutex
3. Append serialized bytes to write_buffer
4. Unlock mutex
5. Return success

**Concurrency**: Called from publisher when publishing records or sending heartbeats.

## State Machine

### Publisher Lifecycle States

**Initialization**:
- Created with config and listener
- Buffer allocated and empty
- No replicas connected

**Running**:
- Accepting new replica connections
- Publishing commit records to connected replicas
- Sending heartbeats
- Processing acknowledgments
- Applying backpressure if buffer full

**Shutdown**:
- Stop accepting new connections
- Drain buffer to all replicas
- Close existing connections
- Release resources

### Replica Connection States

**Connecting**: Handshake in progress
- Waiting for HandshakeMessage from replica
- Transition to Connected on successful handshake
- Transition to Error on handshake failure

**Connected**: Actively replicating
- Sending commit records and heartbeats
- Receiving acknowledgments
- Transition to Disconnected on network error
- Transition to Catchup on reconnection after disconnect

**Disconnected**: Connection lost, reconnecting
- Exponential backoff for reconnection
- Transition to Catchup when reconnected
- Transition to Error if max retries exceeded

**Catchup**: Resuming replication from last ack
- Send messages from last_ack_sequence + 1
- Transition to Connected when caught up
- Transition to Disconnected if connection lost during catchup

**Error**: Non-recoverable error
- Requires manual intervention
- No automatic transitions out of this state

## Rust Implementation Guidance

### Concurrency Model

Use tokio for async I/O and Arc for shared state:

```rust
pub struct Publisher {
    config: Arc<PrimaryConfig>,
    listener: TcpListener,
    buffer: Arc<Mutex<ReplicationBuffer>>,
    replicas: Arc<RwLock<HashMap<ReplicaId, ReplicaConnection>>>,
    running: Arc<AtomicBool>,
    current_lsn: Arc<AtomicU64>,
    sequence_counter: Arc<AtomicU64>,
}
```

### Backpressure Implementation

Use channel with bounded capacity for backpressure:

```rust
// In publish()
if buffer.is_full() {
    // Wait for space or return error immediately
    return Err(Error::BufferOverflow);
}
```

### Heartbeat Task

Use tokio time interval for periodic heartbeats:

```rust
let mut interval = tokio::time::interval(Duration::from_secs(1));
while running.load(Ordering::Relaxed) {
    interval.tick().await;
    send_heartbeats().await;
}
```

### Connection Per-Replica

Spawn dedicated task per replica connection:

```rust
for (replica_id, connection) in replicas.iter() {
    let replica = replica_id.clone();
    let conn = connection.clone();
    tokio::spawn(async move {
        process_replica_connection(replica, conn).await;
    });
}
```

### Error Handling

Define comprehensive error types:

```rust
#[derive(Debug, thiserror::Error)]
pub enum PublisherError {
    #[error("Buffer full, cannot publish")]
    BufferOverflow,

    #[error("Maximum replica connections reached: {0}")]
    ReplicaLimit(u32),

    #[error("Replica {0} not found")]
    ReplicaNotFound(ReplicaId),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Serialization(String),
}
```

### Performance Optimization

Batch write operations:
- Accumulate multiple messages in write_buffer
- Flush to socket in single write syscall
- Use writev for scatter-gather I/O

Zero-copy:
- Use bytes::Bytes for shared buffers
- Avoid copying commit record data
- Reference count shared payload across replicas

### Testing Strategy

Unit tests:
- Buffer management (add, remove, watermarks)
- Backpressure state transitions
- Sequence number assignment
- Checksum calculation

Integration tests:
- End-to-end publisher to single replica
- Multiple concurrent replicas
- Network partition simulation
- Backpressure application and relief

Property-based tests:
- Sequence numbers always monotonically increasing
- Buffer size never exceeds maximum
- All replicas receive same messages in same order

## Monitoring and Observability

### Key Metrics

| Metric | Type | Description |
|--------|------|-------------|
| replication_published_total | Counter | Total commit records published |
| replication_buffer_bytes | Gauge | Current buffer usage in bytes |
| replication_buffer_backpressure | Boolean | Whether backpressure is active |
| replica_connections | Gauge | Number of connected replicas |
| replica_send_latency_ms | Histogram | Latency to send message to replica |
| replica_ack_lag_ms | Histogram | Replication lag per replica |

### Health Checks

Publisher is healthy if:
- At least one replica connected (if configured)
- Buffer below high watermark
- No replicas in Error state
- Heartbeats being sent regularly

## Security Considerations

### Authentication

Validate replica identity during handshake:
- Check replica_id against whitelist
- Validate TLS client certificate
- Reject unauthorized connections

### Rate Limiting

Limit connection rate to prevent resource exhaustion:
- Maximum new connections per second
- Maximum connections from single source IP

### Resource Limits

Enforce per-replica resource limits:
- Maximum send buffer size per replica
- Maximum reconnection attempts per time window
- Connection timeout if idle for too long
