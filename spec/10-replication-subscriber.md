# Replication Subscriber - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-replication-overview.md](./10-replication-overview.md), [10-replication-protocol.md](./10-replication-protocol.md)

## Purpose

This specification defines the Replication Subscriber component running on replica nodes. The Subscriber is responsible for connecting to the primary, receiving commit records, applying them to the local state machine, and handling reconnection with exponential backoff.

## Component Overview

The Subscriber acts as the consumer of replication data:
1. Establishes connection to primary with handshake protocol
2. Receives commit records and heartbeats from primary
3. Applies commit records to local WAL and MVCC state machine
4. Sends acknowledgments to primary
5. Tracks replication lag and health
6. Handles reconnection with exponential backpow
7. Supports bootstrap from snapshot for new or lagging replicas

## Types

### Subscriber

**Description**: Main subscriber struct managing replication from primary.

**Fields**:
- config: Arc ReplicaConfig - Configuration for subscriber behavior
- connection: Option ReplicaConnection - Active connection to primary (if connected)
- state: Arc Atomic ConnectionState - Current connection state
- applied_lsn: Arc AtomicU64 - Highest LSN applied to local state machine
- running: Arc AtomicBool - Flag indicating subscriber is running
- event_sender: mpsc Sender SubscriberEvent - Channel for subscriber events
- apply_queue: mpsc Receiver CommitRecord - Channel for received commit records to apply

**Invariants**: At most one subscriber per replica node. applied_lsn must be monotonically increasing.

### ReplicaConnection

**Description**: Represents the connection from replica to primary.

**Fields**:
- socket: TcpStream - TCP socket for communication with primary
- primary_id: u64 - Unique identifier for primary server
- protocol_version: u16 - Negotiated protocol version
- current_primary_lsn: u64 - Current LSN on primary (from heartbeats)
- receive_sequence: u64 - Next sequence number expected from primary
- last_received: Instant - Timestamp of last message received
- last_heartbeat: Instant - Timestamp of last heartbeat received
- read_buffer: BytesMut - Buffer for incoming data
- write_buffer: BytesMut - Buffer for outgoing data

**Invariants**: receive_sequence must be monotonically increasing. Socket must be connected when state is Connected.

### ConnectionState

**Description**: State machine for subscriber connection lifecycle.

**States**:
- Disconnected: No active connection, attempting to reconnect
- Connecting: Establishing connection to primary
- Connected: Active connection, receiving and applying messages
- Catchup: Resuming replication from last acknowledged position
- Bootstrapping: Receiving snapshot from primary
- Error: Encountered non-recoverable error, requires intervention

**Transitions**:
- Disconnected to Connecting: On reconnection attempt
- Connecting to Connected: On successful handshake
- Connecting to Bootstrapping: If bootstrap required
- Connected to Disconnected: On connection loss
- Connected to Catchup: On reconnection after disconnect
- Catchup to Connected: When caught up to primary
- Bootstrapping to Connected: On successful snapshot application
- Any to Error: On non-recoverable error

### BootstrapState

**Description**: State for tracking bootstrap progress from snapshot.

**Fields**:
- snapshot_lsn: LSN - LSN of snapshot being received
- chunks_received: u32 - Number of chunks received
- total_chunks: u32 - Total number of chunks in snapshot
- snapshot_file: Option File - File handle for snapshot data
- checksum: u64 - Running checksum of snapshot data

**Invariants**: chunks_received must be less than or equal to total_chunks.

### ReconnectState

**Description**: State for exponential backoff reconnection.

**Fields**:
- attempt: u32 - Current reconnection attempt number
- max_attempts: u32 - Maximum attempts before giving up
- base_delay_ms: u64 - Base delay in milliseconds
- max_delay_ms: u64 - Maximum delay in milliseconds
- last_attempt: Option Instant - Timestamp of last reconnection attempt

**Invariants**: attempt must be less than or equal to max_attempts. Delay must not exceed max_delay_ms.

### SubscriberEvent

**Description**: Events emitted by subscriber for monitoring.

**Variants**:
- Connected: Successfully connected to primary
- Disconnected: Connection lost (includes reason)
- BootstrapProgress: Bootstrap progress update (chunk, total)
- BootstrapComplete: Bootstrap completed successfully
- LagWarning: Replication lag exceeded threshold (current_lag, target_lag)
- Error: Error occurred (error description)

## Functions

### Subscriber::new(config: ReplicaConfig) -> Result Subscriber

**Purpose**: Create a new replication subscriber on a replica node.

**Parameters**:
- config: ReplicaConfig - Configuration for subscriber behavior

**Returns**: Result wrapping Subscriber instance

**Algorithm**:
1. Validate configuration parameters (primary address, lag targets)
2. Resolve primary address to socket addresses
3. Create channels for events and apply queue
4. Initialize state to Disconnected
5. Initialize applied_lsn to zero or load from persistent storage
6. Create atomic flags for running state
7. Return Subscriber instance

**Error Conditions**:
- ConfigError: Invalid configuration parameters
- DnsError: Failed to resolve primary address

**Concurrency**: Thread-safe via Arc and atomics. Can be shared across threads.

### Subscriber::start(&self) -> Result

**Purpose**: Start the subscriber and begin replication.

**Algorithm**:
1. Set running flag to true
2. Spawn background reconnection task
3. Spawn background apply task
4. Call connect() to establish initial connection
5. Return success

**Error Conditions**:
- IoError: Failed to start background tasks or initial connection

**Concurrency**: Should be called once when starting replica node.

### Subscriber::connect(&self) -> Result

**Purpose**: Establish connection to primary and begin replication.

**Algorithm**:
1. Transition state to Connecting
2. Resolve primary address if not already resolved
3. Create TCP socket and connect to primary
4. Set socket options (TCP_NODELAY, keepalive)
5. Perform TLS handshake if enabled
6. Create HandshakeMessage with protocol_version, replica_id, start_lsn
7. Serialize and send handshake message
8. Wait for AcceptMessage response
9. Validate protocol version in response
10. Check if start_lsn is available on primary
11. If start_lsn not available (error code 1003), transition to Bootstrapping
12. Create ReplicaConnection with socket, state Connected, receive_sequence 0
13. Set connection field
14. Spawn background receive task for this connection
15. Emit Connected event
16. Return success

**Error Conditions**:
- IoError: Failed to connect to primary (network error, timeout)
- ProtocolError: Handshake failed (version mismatch, invalid message)
- AuthenticationError: TLS handshake failed or replica rejected
- LsnNotFoundError: Requested start LSN not available on primary

**Concurrency**: Should not be called concurrently with existing connection.

### Subscriber::receive_loop(&self, connection: ReplicaConnection)

**Purpose**: Background task for receiving messages from primary.

**Parameters**:
- connection: ReplicaConnection - Active connection to primary

**Algorithm**:
1. Enter infinite loop
2. Check running flag and connection state, exit if not running or not Connected
3. Read FrameHeader from socket
4. Validate frame_size is within limits (maximum 16MB)
5. Read message payload based on message_type in header
6. Validate sequence number is monotonically increasing
7. Update connection receive_sequence
8. Update connection last_received timestamp
9. Handle message based on message_type:
    a. Heartbeat:
        i. Update connection current_primary_lsn
        ii. Update connection last_heartbeat timestamp
        iii. Calculate replication lag
        iv. If lag exceeds target, emit LagWarning event
    b. CommitRecord:
        i. Validate checksum
        ii. Deserialize CommitRecord from payload
        iii. Send to apply queue channel
    c. Snapshot:
        i. Delegate to handle_snapshot_chunk()
    d. Error:
        i. Log error with error_code
        ii. Handle specific error codes
10. Send AckMessage with applied_lsn and current lag
11. Repeat from step 2

**Error Conditions**:
- IoError: Connection lost or network error
- ChecksumError: Message checksum validation failed
- SequenceError: Sequence number not monotonically increasing

**Concurrency**: Runs as dedicated background task per connection.

### Subscriber::handle_snapshot_chunk(&self, message: SnapshotDataMessage) -> Result

**Purpose**: Handle a chunk of snapshot data during bootstrap.

**Parameters**:
- message: SnapshotDataMessage - Snapshot chunk message

**Algorithm**:
1. Check if state is Bootstrapping, transition if not
2. Initialize BootstrapState if first chunk
3. Validate chunk_index matches chunks_received
4. Validate chunk checksum
5. Append chunk data to snapshot file
6. Update running checksum
7. Increment chunks_received
8. Emit BootstrapProgress event with progress
9. If chunks_received equals total_chunks:
    a. Validate final checksum matches expected
    b. Apply snapshot to local storage
    c. Update applied_lsn to snapshot_lsn
    d. Close snapshot file
    e. Transition state to Connected
    f. Emit BootstrapComplete event
10. Return success

**Error Conditions**:
- ChecksumError: Snapshot chunk checksum validation failed
- IoError: Failed to write snapshot data to file

**Concurrency**: Called from receive_loop when snapshot messages received.

### Subscriber::apply_loop(&self)

**Purpose**: Background task for applying received commit records to local state machine.

**Algorithm**:
1. Enter infinite loop
2. Check running flag, exit if false
3. Wait for commit record on apply queue channel
4. Validate commit record checksum
5. Write commit record to local WAL
6. Apply transaction to MVCC state machine
7. Update applied_lsn atomically
8. Return success to caller (implicitly acknowledges to primary via next AckMessage)

**Error Conditions**:
- ChecksumError: Commit record checksum validation failed
- WalError: Failed to write to local WAL
- MvccError: Failed to apply to MVCC state machine

**Concurrency**: Runs as dedicated background task. Processes records sequentially to preserve order.

### Subscriber::reconnect_loop(&self)

**Purpose**: Background task for handling reconnection with exponential backoff.

**Algorithm**:
1. Initialize ReconnectState with attempt 0, base_delay from config
2. Enter infinite loop
3. Check running flag, exit if false
4. Check if connection state is Connected, sleep and retry if so
5. Check if connection state is Error, exit without retrying
6. Calculate delay using exponential backoff formula:
    delay = min(base_delay * 2^attempt, max_delay_ms)
7. Add random jitter of plus or minus 10 percent to delay
8. Sleep for calculated delay
9. Increment attempt counter
10. Update ReconnectState last_attempt timestamp
11. Call connect() to attempt reconnection
12. If connect() succeeds:
    a. Reset attempt counter to 0
    b. Transition state to Catchup or Connected
    c. Continue from step 3
13. If connect() fails:
    a. Log error with attempt number
    b. Check if attempt exceeds max_attempts
    c. If exceeded, transition state to Error and exit
    d. Emit Disconnected event
    e. Continue from step 6

**Error Conditions**:
- MaxAttemptsExceeded: Failed to reconnect after maximum attempts

**Concurrency**: Runs as dedicated background task. Should not be called directly.

### Subscriber::bootstrap(&self) -> Result

**Purpose**: Initiate bootstrap from snapshot when too far behind or on initial setup.

**Algorithm**:
1. Transition state to Bootstrapping
2. Update start_lsn to zero in config
3. Close existing connection if any
4. Call connect() to establish new connection
5. Connection will automatically request bootstrap since start_lsn is zero
6. Wait for BootstrapComplete event or timeout
7. Return success on bootstrap complete

**Error Conditions**:
- IoError: Failed to establish connection or receive snapshot
- TimeoutError: Bootstrap did not complete within timeout

**Concurrency**: Should not be called concurrently with normal replication.

### Subscriber::shutdown(&self) -> Result

**Purpose**: Gracefully shutdown the subscriber.

**Algorithm**:
1. Set running flag to false
2. Signal all background tasks to stop
3. Close connection if established
4. Drain apply queue
5. Wait for background tasks to exit
6. Return success

**Error Conditions**: None - shutdown is best-effort

**Concurrency**: Should be called once when shutting down replica node.

## State Machine

### Subscriber Lifecycle States

**Disconnected**:
- No active connection to primary
- Reconnect loop running with exponential backoff
- Continue serving reads from stale data

**Connecting**:
- Attempting to establish TCP connection
- Performing TLS handshake
- Sending and receiving handshake messages

**Connected**:
- Actively receiving commit records and heartbeats
- Applying commit records to local state machine
- Sending acknowledgments to primary

**Catchup**:
- Reconnected after disconnect
- Receiving messages from last acknowledged position
- Once caught up, transition to Connected

**Bootstrapping**:
- Receiving snapshot from primary
- Applying snapshot to local storage
- Will transition to Connected when complete

**Error**:
- Non-recoverable error occurred
- No automatic recovery
- Requires manual intervention

## Rust Implementation Guidance

### Concurrency Model

Use tokio for async I/O and Arc for shared state:

```rust
pub struct Subscriber {
    config: Arc<ReplicaConfig>,
    connection: Arc<Mutex<Option<ReplicaConnection>>>,
    state: Arc<AtomicU8>, // Using u8 for ConnectionState
    applied_lsn: Arc<AtomicU64>,
    running: Arc<AtomicBool>,
    event_sender: mpsc::Sender<SubscriberEvent>,
    apply_queue: mpsc::Receiver<CommitRecord>,
}
```

### State Management

Use AtomicU8 for ConnectionState with explicit conversions:

```rust
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionState {
    Disconnected = 0,
    Connecting = 1,
    Connected = 2,
    Catchup = 3,
    Bootstrapping = 4,
    Error = 5,
}
```

### Channel Configuration

Use bounded channels for backpressure:

```rust
let (apply_sender, apply_receiver) = mpsc::channel(1000);
```

### Reconnection Backoff

Calculate exponential backoff with jitter:

```rust
fn calculate_delay(attempt: u32, base_ms: u64, max_ms: u64) -> Duration {
    let exponential = base_ms * 2_u64.pow(attempt.min(20));
    let capped = exponential.min(max_ms);
    let jitter = (capped as f64 * 0.1 * rand::random::<f64>()) as u64;
    Duration::from_millis(capped.saturating_add(jitter))
}
```

### Error Handling

Define comprehensive error types:

```rust
#[derive(Debug, thiserror::Error)]
pub enum SubscriberError {
    #[error("Connection lost: {0}")]
    ConnectionLost(String),

    #[error("Handshake failed: {0}")]
    HandshakeFailed(String),

    #[error("Checksum mismatch at LSN {lsn}")]
    ChecksumMismatch { lsn: u64 },

    #[error("LSN not found on primary: {lsn}")]
    LsnNotFound { lsn: u64 },

    #[error("Maximum reconnection attempts exceeded")]
    MaxAttemptsExceeded,

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
```

### Performance Optimization

Zero-copy:
- Use bytes::Bytes for received commit records
- Avoid copying data between channels

Batch acknowledgment:
- Send AckMessage after processing multiple records
- Reduces network round-trips

Parallel apply:
- Spawn multiple apply tasks for independent records
- Requires careful ordering guarantees

### Testing Strategy

Unit tests:
- State machine transitions
- Exponential backoff calculation
- Checksum validation
- Sequence number validation

Integration tests:
- End-to-end primary to replica replication
- Reconnection after network partition
- Bootstrap from snapshot
- Lag calculation and alerting

Property-based tests:
- Sequence numbers always monotonically increasing
- applied_lsn never decreases
- State transitions always valid

## Monitoring and Observability

### Key Metrics

| Metric | Type | Description |
|--------|------|-------------|
| replication_received_total | Counter | Total commit records received |
| replication_applied_total | Counter | Total commit records applied |
| replication_lag_ms | Gauge | Current replication lag in milliseconds |
| replication_lag_target_ms | Gauge | Target replication lag threshold |
| subscriber_state | Gauge | Current connection state (as number) |
| reconnection_attempts | Counter | Total reconnection attempts |
| bootstrap_progress | Gauge | Bootstrap progress (0.0 to 1.0) |

### Health Checks

Subscriber is healthy if:
- State is Connected or Catchup
- Replication lag below target
- Received message within last 5 seconds
- No checksum errors in last hour

## Security Considerations

### Authentication

Validate primary identity during handshake:
- Verify primary certificate if TLS enabled
- Validate primary_id against expected value
- Reject connections from untrusted primaries

### Resource Limits

Enforce resource limits to prevent exhaustion:
- Maximum apply queue size
- Maximum snapshot file size
- Maximum reconnection attempts

### Data Integrity

Validate all incoming data:
- Checksum validation for all messages
- Sequence number validation
- Frame size limits
