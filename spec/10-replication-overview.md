# Replication Overview - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: Phase 9 (AI Intelligence Layer) complete
**Related**: [replication_v1.md](./replication_v1.md) - Zig implementation reference

## Purpose

This specification defines the replication architecture for NorthstarDB in Rust, transforming it from a single-node embedded database into a distributed system with multi-region deployment capabilities. The design leverages the existing commit record and WAL infrastructure as the foundation for replication.

## Design Philosophy

The commit record is the seam that becomes replication. Every write already produces a sequential, checksummed record. We extend this to stream records across nodes. This ensures:

1. Smaller replication payload (logical operations vs full pages)
2. Deterministic replay (replica applies same operations)
3. Natural support for time-travel queries (replica has full history)

## Architecture Overview

### Primary-Replica Topology (v1.0)

The system uses a primary-replica topology where:
- Single primary accepts all writes
- Replicas serve read-only traffic
- Asynchronous replication with tunable consistency
- Manual failover in v1.0, automatic with Raft in v2.0

### Component Hierarchy

```
Primary Region:
- Write Transaction (single)
- Commit Log (WAL)
- Replication Publisher (streams commits)

Network:
- Streaming protocol (gRPC/QUIC)

Replica Region:
- Replication Subscriber (receives commits)
- Apply Engine (replay)
- MVCC Snapshots (read-only queries)
```

## Types

### ReplicationRole

**Description**: Defines whether a node operates as primary or replica in the replication topology.

**Variants**:
- Primary: Node accepts writes and streams commit log to replicas
- Replica: Node receives commit stream and serves read-only queries

**Invariants**: A node cannot be both primary and replica simultaneously.

### ReplicationMessage

**Description**: Wire format message sent between primary and replica.

**Fields**:
- version: u16 - Protocol version for compatibility negotiation (default: 1)
- message_type: MessageType - Enum indicating message category
- sequence: u64 - Monotonically increasing sequence number for ordering
- commit_record: Optional CommitRecord - Present for commit_record messages only
- checksum: u64 - Checksum for end-to-end integrity validation

**Size**: Approximately 32 bytes header plus variable payload

**MessageType Enum**:
- Heartbeat: Periodic keepalive with current LSN
- CommitRecord: Actual commit record data
- Snapshot: Full snapshot for bootstrap
- Error: Error notification with error code

### ReplicationConfig

**Description**: Configuration for replication behavior on a node.

**Fields**:
- role: ReplicationRole - Primary or Replica
- primary_config: Optional PrimaryConfig - Present when role is Primary
- replica_config: Optional ReplicaConfig - Present when role is Replica

**Invariants**: Exactly one of primary_config or replica_config must be present based on role.

### PrimaryConfig

**Description**: Configuration specific to primary node operation.

**Fields**:
- listen_address: String - Network address to bind for replica connections (e.g., "0.0.0.0:7233")
- max_replicas: u32 - Maximum number of concurrent replica connections (default: 10)
- replication_buffer_size: u64 - Size of in-memory buffer for commit records (default: 100MB)

**Validation**: listen_address must be a valid socket address, max_replicas must be between 1 and 100.

### ReplicaConfig

**Description**: Configuration specific to replica node operation.

**Fields**:
- primary_address: String - Address of primary node to connect to (e.g., "primary.example.com:7233")
- replication_lag_target_ms: u64 - Target maximum replication lag (default: 100ms)
- reconnect_interval_ms: u64 - Initial reconnect interval on disconnect (default: 1000ms)
- bootstrap_on_start: bool - Whether to bootstrap from snapshot on first start (default: false)

**Validation**: primary_address must be a valid socket address, lag targets must be between 10ms and 60000ms.

### ReplicaInfo

**Description**: Runtime state tracking for a connected replica.

**Fields**:
- replica_id: u64 - Unique identifier for this replica
- connected: bool - Current connection status
- last_ack_sequence: u64 - Highest sequence number acknowledged by replica
- replication_lag_ms: u64 - Current replication lag (primary_lsn - applied_lsn)
- connect_time: Option Instant - When replica connected
- last_heartbeat: Option Instant - Time of last heartbeat received

### ConnectionState

**Description**: State machine for replica connection lifecycle.

**States**:
- Disconnected: No active connection, attempting to reconnect
- Connecting: Establishing connection to primary
- Connected: Active connection, replicating normally
- Catchup: Resuming replication from last acknowledged position
- Error: Encountered non-recoverable error, requires intervention

## Functions

### Publisher::new(config: PrimaryConfig) -> Result<Publisher>

**Purpose**: Create a new replication publisher on the primary node.

**Parameters**:
- config: PrimaryConfig - Configuration for publisher behavior

**Returns**: Result wrapping Publisher instance

**Algorithm**:
1. Validate configuration (listen address, buffer size)
2. Create TCP listener at configured address
3. Allocate in-memory buffer for commit records
4. Initialize empty replica tracking map
5. Start background heartbeat task

**Error Conditions**:
- IoError: Failed to bind to listen address (address in use, permission denied)
- ConfigError: Invalid configuration parameters

**Concurrency**: Publisher is thread-safe, can be shared across threads with Arc.

### Publisher::publish(&self, record: CommitRecord) -> Result<()>

**Purpose**: Add a commit record to the replication stream for all connected replicas.

**Parameters**:
- record: CommitRecord - The commit record to replicate

**Returns**: Empty Result on success

**Algorithm**:
1. Calculate checksum for commit record
2. Create ReplicationMessage with commit_record variant
3. Add message to in-memory buffer
4. For each connected replica, send message asynchronously
5. Track sequence number per replica
6. Apply backpressure if buffer approaching capacity

**Error Conditions**:
- BufferOverflow: Replication buffer full, publishing paused
- IoError: Network error sending to replica

**Concurrency**: Safe to call concurrently from multiple write transactions.

### Publisher::send_heartbeat(&self) -> Result<()>

**Purpose**: Send periodic heartbeat messages to all connected replicas to maintain liveness.

**Returns**: Empty Result on success

**Algorithm**:
1. Create ReplicationMessage with heartbeat variant containing current LSN
2. Send to all connected replicas
3. Update last_heartbeat timestamp in ReplicaInfo
4. Check for replicas exceeding heartbeat timeout

**Error Conditions**: None - heartbeat failures are logged but don't return error

**Concurrency**: Safe to call concurrently, typically called by background task.

### Publisher::track_replica_position(&self, replica_id: u64, sequence: u64)

**Purpose**: Update the acknowledged sequence number for a specific replica.

**Parameters**:
- replica_id: u64 - Replica identifier
- sequence: u64 - Highest sequence number acknowledged

**Algorithm**:
1. Find replica in tracking map by ID
2. Update last_ack_sequence
3. Recalculate replication lag based on current LSN
4. Remove acknowledged records from buffer if all replicas have acknowledged

**Concurrency**: Safe to call concurrently.

### Subscriber::new(config: ReplicaConfig) -> Result<Subscriber>

**Purpose**: Create a new replication subscriber on a replica node.

**Parameters**:
- config: ReplicaConfig - Configuration for subscriber behavior

**Returns**: Result wrapping Subscriber instance

**Algorithm**:
1. Validate configuration (primary address, lag targets)
2. Resolve primary address to socket addresses
3. Initialize state machine to Disconnected
4. Create channel for receiving commit records
5. Start background reconnection task

**Error Conditions**:
- ConfigError: Invalid configuration parameters
- DnsError: Failed to resolve primary address

**Concurrency**: Subscriber is thread-safe, can be shared across threads with Arc.

### Subscriber::connect(&self) -> Result<()>

**Purpose**: Establish connection to primary and begin replication.

**Returns**: Empty Result on success

**Algorithm**:
1. Transition state to Connecting
2. Open TCP connection to primary_address
3. Send handshake message with replica_id and start_lsn
4. Receive acceptance message with current LSN and protocol version
5. Validate protocol version compatibility
6. Transition state to Connected
7. Start receive loop for incoming messages

**Error Conditions**:
- IoError: Failed to connect to primary (network error, timeout)
- ProtocolError: Handshake failed (version mismatch, authentication failed)
- LsnNotFoundError: Requested start LSN not available on primary

**Concurrency**: Should not be called concurrently with existing connection.

### Subscriber::receive(&self) -> Result<ReplicationMessage>

**Purpose**: Receive next message from replication stream.

**Returns**: Result wrapping ReplicationMessage

**Algorithm**:
1. Wait for message on network socket
2. Validate message checksum
3. Verify sequence number is monotonically increasing
4. Update last received sequence number
5. Return parsed message

**Error Conditions**:
- IoError: Network error or connection lost
- ChecksumError: Message checksum validation failed
- SequenceError: Sequence number not monotonically increasing

**Concurrency**: Safe to call from single consumer task only.

### Subscriber::apply(&self, record: CommitRecord) -> Result<()>

**Purpose**: Apply a received commit record to local state machine.

**Parameters**:
- record: CommitRecord - Commit record to apply

**Returns**: Empty Result on success

**Algorithm**:
1. Validate commit record checksum
2. Write commit record to local WAL
3. Apply transaction to MVCC state machine
4. Update applied LSN
5. Send acknowledgment to primary with sequence number
6. Check replication lag against target

**Error Conditions**:
- ChecksumError: Commit record checksum validation failed
- WalError: Failed to write to local WAL
- MvccError: Failed to apply to MVCC state machine

**Concurrency**: Safe to call sequentially, must preserve order.

### Subscriber::bootstrap(&self) -> Result<()>

**Purpose**: Bootstrap replica from full snapshot when too far behind or on initial setup.

**Returns**: Empty Result on success

**Algorithm**:
1. Send bootstrap request message to primary
2. Receive snapshot data in chunks
3. Validate snapshot checksum
4. Apply snapshot to local storage (pages, WAL, MVCC state)
5. Update local LSN to snapshot LSN
6. Resume normal replication from snapshot LSN

**Error Conditions**:
- IoError: Network error during snapshot transfer
- ChecksumError: Snapshot checksum validation failed
- StorageError: Failed to apply snapshot to local storage

**Concurrency**: Should not be called concurrently with normal replication.

### Subscriber::reconnect(&self) -> Result<()>

**Purpose**: Handle reconnection with exponential backoff after disconnect.

**Returns**: Empty Result on success

**Algorithm**:
1. Calculate backoff delay using exponential backoff formula
2. Wait for backoff period
3. Attempt to reconnect using connect()
4. On success, resume from last acknowledged LSN
5. On failure, increment backoff multiplier and retry
6. Give up after maximum retries and transition to Error state

**Error Conditions**:
- IoError: Failed to reconnect after maximum retries
- ErrorState: Transitioned to error state requiring intervention

**Concurrency**: Should not be called concurrently with other reconnection attempts.

## Consistency Model

### Write Path

1. Client writes to primary
2. Primary commits to local WAL (durability guaranteed)
3. Primary writes to in-memory replication buffer
4. Primary ACKs client (write committed)
5. Replication Publisher streams to replicas asynchronously

**Guarantee**: Writes are durable on primary before ACK. Replication lag is decoupled from write latency.

### Read Path

Read on Primary:
- Read from latest MVCC snapshot (strong consistency)

Read on Replica:
- Read from replica MVCC snapshot
- Snapshot timestamp is less than or equal to primary current timestamp
- Bounded staleness (tunable via replication lag target)

### Consistency Levels

| Level | Description | Use Case | Latency Impact |
|-------|-------------|----------|----------------|
| Strong | Read from primary | Critical data, financial | Low (single region) |
| Bounded Staleness | Read from replica with lag less than N milliseconds | Analytics, dashboards | Very low (local read) |
| Eventual | Read from any replica | Caching, non-critical | Near-zero |

### Replication Lag Tracking

Replica tracks replication lag as primary_lsn minus applied_lsn. Exceeding threshold triggers:
- Alert emission
- Optional read traffic rejection
- Auto-scaling of replica resources

Lag targets:
- Tight: Less than 10 milliseconds (same region)
- Normal: Less than 100 milliseconds (cross-region)
- Relaxed: Less than 1 second (cost-optimized)

## Failure Modes

### Network Partition

When replica loses connection to primary:

1. Replica detects heartbeat timeout (5 seconds default)
2. Transition state from Connected to Disconnected
3. Begin exponential backoff reconnection
4. Continue serving reads from stale data
5. Client applications decide whether to accept stale reads
6. On reconnection, transition to Catchup state
7. Resume from last acknowledged LSN
8. Transition back to Connected when caught up

### Primary Failure

Version 1.0 (Manual Failover):
1. Operator detects primary failure
2. Promote replica to primary with force flag
3. Update DNS or load balancer to point to new primary
4. Other replicas connect to new primary
5. Risk of data loss for unreplicated commits on failed primary
6. Split-brain risk if old primary recovers (operator responsibility)

Version 2.0 (Automatic with Raft):
- Raft consensus automatically elects new leader
- Replica state machine handles transition transparently
- No split-brain risk due to leader election guarantees

### Replica Failure

When replica crashes or falls behind:

1. Primary continues accepting writes
2. Primary tracks replica position in memory (reset on restart)
3. On recovery, replica resumes from last acknowledged LSN
4. If too far behind, replica triggers bootstrap protocol
5. No impact on primary or other replicas

### Corruption Detection

Commit record checksums validated at three points:
1. On Primary before writing to WAL (existing behavior)
2. On replication stream before sending to replica
3. On Replica before applying to local state

Corruption response:
1. Replica sends error message to primary
2. Primary re-sends the commit record
3. If corruption persists, replica requests bootstrap from earlier snapshot

## Integration Points

### Existing Infrastructure

| Component | Usage in Replication |
|-----------|---------------------|
| Commit Record | Unit of replication, reserved fields available for metadata |
| WAL | Source of truth for replication stream, publisher tails WAL |
| Replay Engine | Replica uses replay logic to apply commit records |
| MVCC Snapshots | Replica queries use local snapshots with bounded staleness |
| Checksums | End-to-end integrity validation from primary to replica |

### New Components

| Component | Responsibility |
|-----------|---------------|
| Replication Publisher | Streams commit records to connected replicas |
| Replication Subscriber | Pulls and applies commit records from primary |
| Replication Server | Handles replica connections, authentication, throttling |
| Replication Client | Manages connection to primary, reconnection, state machine |

## Rust Implementation Guidance

### Module Structure

```
northstar-replication/
├── src/
│   ├── lib.rs              # Public API exports
│   ├── publisher.rs        # Publisher implementation
│   ├── subscriber.rs       # Subscriber implementation
│   ├── protocol.rs         # Message types and serialization
│   ├── config.rs           # Configuration types
│   └── state.rs            # Connection state machine
├── Cargo.toml
```

### Concurrency Model

Use tokio for async I/O:
- Publisher uses Arc with tokio sync primitives for shared state
- Subscriber uses async channels for message passing
- Connection state machine uses tokio select for event handling

### Error Handling

Define dedicated error types:
- ReplicationError: Top-level error enum covering all failure modes
- IoError: Wrapper for std io::Error with context
- ProtocolError: Protocol version mismatch, invalid message format
- ChecksumError: Checksum validation failure

### Performance Considerations

Batching: Batch commit records for network efficiency
- Target batch size: 100 records or 1MB (whichever first)
- Flush interval: 10 milliseconds maximum

Zero-copy: Use bytes::Bytes for zero-copy buffer sharing

Backpressure: Apply backpressure when buffer approaching capacity
- Pause writes when buffer exceeds 80 percent capacity
- Resume when buffer drops below 60 percent

### Testing Strategy

Unit tests:
- Publisher buffer management
- Subscriber state machine transitions
- Checksum validation
- Configuration validation

Integration tests:
- End-to-end replication flow
- Network partition simulation
- Primary and replica failure scenarios

Property-based tests:
- Monotonic sequence numbers always maintained
- Checksums always validate on both sides
- Replication lag never exceeds target under normal operation

## Security Considerations

### Transport Security

TLS 1.3 required for all replication connections
- Certificate-based authentication
- Replica certificates signed by primary certificate authority
- Forward secrecy enabled

### Access Control

Replicas authenticate with client certificates
- Primary validates replica whitelist
- Optional mutual TLS for both directions

### Data at Rest

Replicas store data encrypted at rest
- Same encryption as primary
- WAL encryption maintained on replica

## Monitoring and Observability

### Key Metrics

| Metric | Type | Description | Alert Threshold |
|--------|------|-------------|-----------------|
| replication_lag_ms | Gauge | Lag between primary and replica | Greater than 500ms for more than 1 minute |
| replication_throughput_cps | Gauge | Commits replicated per second | Less than baseline times 0.5 |
| replication_error_rate | Counter | Replication errors (checksum, network) | Greater than 0.01 percent |
| replica_connected | Boolean | Replica connection status | False for more than 30 seconds |
| replication_buffer_bytes | Gauge | Primary replication buffer usage | Greater than 80 percent capacity |
| replica_apply_latency_ms | Histogram | Time for replica to apply commit | P99 greater than 10ms |

### Health Checks

Primary health:
- WAL write latency less than 10ms P99
- Replication buffer not full
- All replicas connected or expected number

Replica health:
- Replication lag below target
- No checksum errors in last hour
- Sufficient disk space for WAL and database

## Benchmark Targets

| Benchmark | Target | Notes |
|-----------|--------|-------|
| Replication Throughput | Greater than 100K commits per second | Single primary, single replica |
| Replication Lag (Same Region) | Less than 10ms P99 | 1 Gbps network |
| Replication Lag (Cross-Region) | Less than 100ms P99 | US-East to EU-West |
| Bootstrap Time | Less than 5 minutes per GB | Snapshot transfer plus apply |
| Failover Time (Manual) | Less than 60 seconds | Operator-driven promotion |
