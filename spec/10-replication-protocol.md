# Replication Protocol - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-replication-overview.md](./10-replication-overview.md)

## Purpose

This specification defines the wire protocol for replication between primary and replica nodes in NorthstarDB. The protocol enables streaming of commit records with guaranteed delivery, ordering, and integrity validation.

## Protocol Design Goals

1. **Ordered Delivery**: Sequence numbers ensure in-order message delivery
2. **Integrity**: End-to-end checksums detect corruption in transit
3. **Backpressure**: Flow control prevents overwhelming replicas
4. **Versioning**: Protocol version enables compatibility negotiation
5. **Efficiency**: Compact binary format minimizes network overhead

## Protocol Layers

```
Application Layer: CommitRecord with replication metadata
      ↓
Message Layer: ReplicationMessage (version, type, sequence, payload)
      ↓
Framing Layer: Length-prefixed binary frames
      ↓
Transport Layer: TCP with TLS 1.3
```

## Types

### ProtocolVersion

**Description**: Protocol version for compatibility negotiation and evolution.

**Type**: u16

**Valid Values**:
- 1: Initial protocol version (current)

**Invariants**: Version must be greater than zero. Primary and replica must negotiate compatible version.

### MessageType

**Description**: Discriminant enum indicating the category of replication message.

**Type**: u8

**Variants**:
- 0: Heartbeat - Periodic keepalive with current LSN
- 1: CommitRecord - Actual commit record data
- 2: Snapshot - Full snapshot for bootstrap
- 3: Error - Error notification with error code

**Invariants**: Values 0 through 3 are valid. Future versions may add values 4 through 255.

### SequenceNumber

**Description**: Monotonically increasing sequence number for message ordering and acknowledgment.

**Type**: u64

**Properties**:
- Starts at zero for each connection
- Increments by one for each message sent
- Wraps around at maximum u64 value (handled by protocol)

**Invariants**: Sequence numbers strictly increase within a connection. Replica uses sequence to acknowledge receipt.

### Checksum

**Description**: Checksum value for end-to-end integrity validation of message payload.

**Type**: u64

**Algorithm**: CRC-64 (ISO variant)

**Coverage**: Checksum covers all message fields excluding the checksum field itself

**Invariants**: Checksum must validate on both sides. Mismatch triggers retransmission.

### HandshakeMessage

**Description**: Initial message sent by replica to establish connection and negotiate parameters.

**Fields**:
- protocol_version: u16 - Protocol version requested by replica
- replica_id: u64 - Unique identifier for this replica
- start_lsn: LSN - LSN to start replication from (zero for bootstrap)
- capabilities: u32 - Bit field of supported capabilities (reserved for future)

**Size**: 22 bytes

**Field Offsets**:
- Offset 0-1: protocol_version (u16, little-endian)
- Offset 2-9: replica_id (u64, little-endian)
- Offset 10-17: start_lsn (u64, little-endian)
- Offset 18-21: capabilities (u32, little-endian)

### AcceptMessage

**Description**: Response from primary accepting the connection and providing replication parameters.

**Fields**:
- protocol_version: u16 - Protocol version selected by primary (minimum of requested and supported)
- current_lsn: LSN - Current LSN on primary (for lag calculation)
- server_id: u64 - Unique identifier for primary server
- max_batch_size: u32 - Maximum batch size for commit records

**Size**: 22 bytes

**Field Offsets**:
- Offset 0-1: protocol_version (u16, little-endian)
- Offset 2-9: current_lsn (u64, little-endian)
- Offset 10-17: server_id (u64, little-endian)
- Offset 18-21: max_batch_size (u32, little-endian)

### HeartbeatMessage

**Description**: Periodic keepalive message sent by primary to maintain connection and provide current LSN.

**Fields**:
- current_lsn: LSN - Current LSN on primary
- timestamp_ms: u64 - Current timestamp on primary for clock synchronization

**Size**: 16 bytes

**Field Offsets**:
- Offset 0-7: current_lsn (u64, little-endian)
- Offset 8-15: timestamp_ms (u64, little-endian)

**Frequency**: Sent every 1 second by primary

**Timeout**: Replica expects message within 5 seconds or initiates reconnection

### CommitRecordMessage

**Description**: Message containing a commit record to be replicated.

**Fields**:
- lsn: LSN - Log sequence number of this commit record
- record_size: u32 - Size of commit record data in bytes
- record_data: ByteSlice - Serialized commit record (variable length)
- checksum: u64 - Checksum of record_data only

**Size**: 20 bytes plus record_size

**Field Offsets**:
- Offset 0-7: lsn (u64, little-endian)
- Offset 8-11: record_size (u32, little-endian)
- Offset 12 to (11+record_size): record_data (raw bytes)
- Offset (12+record_size) to (19+record_size): checksum (u64, little-endian)

**Maximum Size**: 1MB per commit record message

### SnapshotDataMessage

**Description**: Chunk of snapshot data sent during bootstrap protocol.

**Fields**:
- chunk_index: u32 - Index of this chunk in snapshot (starts at zero)
- total_chunks: u32 - Total number of chunks in snapshot
- chunk_size: u32 - Size of chunk_data in bytes
- chunk_data: ByteSlice - Snapshot chunk data (variable length)
- checksum: u64 - Checksum of chunk_data only

**Size**: 20 bytes plus chunk_size

**Field Offsets**:
- Offset 0-3: chunk_index (u32, little-endian)
- Offset 4-7: total_chunks (u32, little-endian)
- Offset 8-11: chunk_size (u32, little-endian)
- Offset 12 to (11+chunk_size): chunk_data (raw bytes)
- Offset (12+chunk_size) to (19+chunk_size): checksum (u64, little-endian)

**Maximum Chunk Size**: 1MB per chunk

### AckMessage

**Description**: Acknowledgment from replica to primary confirming receipt of messages.

**Fields**:
- sequence: u64 - Highest sequence number acknowledged
- applied_lsn: LSN - Highest LSN successfully applied to replica state machine
- lag_ms: u64 - Current replication lag in milliseconds (calculated by replica)

**Size**: 24 bytes

**Field Offsets**:
- Offset 0-7: sequence (u64, little-endian)
- Offset 8-15: applied_lsn (u64, little-endian)
- Offset 16-23: lag_ms (u64, little-endian)

**Frequency**: Sent by replica after each batch of messages received

### ErrorMessage

**Description**: Error notification sent when protocol error or corruption detected.

**Fields**:
- error_code: u16 - Error code indicating type of error
- message_length: u16 - Length of error message text
- message_text: String - Human-readable error message (variable length)

**Size**: 4 bytes plus message_length

**Field Offsets**:
- Offset 0-1: error_code (u16, little-endian)
- Offset 2-3: message_length (u16, little-endian)
- Offset 4 to (3+message_length): message_text (UTF-8 bytes)

**Error Codes**:
- 1001: VersionMismatch - Protocol version incompatible
- 1002: AuthenticationFailed - Replica authentication failed
- 1003: LsnNotFound - Requested LSN not available on primary
- 1004: ChecksumInvalid - Checksum validation failed
- 1005: BufferOverflow - Replication buffer exceeded capacity
- 1006: ReplicaLimit - Max replicas reached on primary

### FrameHeader

**Description**: Prefix for each message frame enabling message framing on stream.

**Fields**:
- frame_size: u32 - Total size of frame including header (maximum 16MB)
- message_type: u8 - MessageType discriminant
- flags: u8 - Bit field of message flags (reserved for future)
- sequence: u64 - Sequence number for ordering

**Size**: 15 bytes

**Field Offsets**:
- Offset 0-3: frame_size (u32, little-endian)
- Offset 4: message_type (u8)
- Offset 5: flags (u8)
- Offset 6-13: sequence (u64, little-endian)

**Flags**:
- Bit 0 (0x01): Compressed - Payload compressed with zstd
- Bit 1 (0x02): LastBatch - Last message in batch

## Protocol Flow

### Connection Establishment

**Replica initiates**:

1. Replica establishes TCP connection to primary (with TLS)
2. Replica sends HandshakeMessage
3. Replica waits for AcceptMessage or ErrorMessage

**Primary responds**:

1. Primary receives HandshakeMessage
2. Primary validates protocol_version (must be supported)
3. Primary checks replica whitelist (if enabled)
4. Primary assigns sequence starting at zero
5. Primary sends AcceptMessage or ErrorMessage on error

**Error handling**:
- If protocol_version unsupported, primary sends ErrorMessage with code 1001 and highest supported version
- If replica not in whitelist, primary sends ErrorMessage with code 1002
- If start_lsn not available, primary sends ErrorMessage with code 1003

### Message Exchange

**Primary to replica**:

1. Primary creates message payload based on MessageType
2. Primary calculates checksum for payload
3. Primary assigns sequence number (incrementing for each message)
4. Primary creates FrameHeader with message_type, flags, sequence
5. Primary sends FrameHeader followed by message payload
6. Primary tracks message per replica until acknowledgment received

**Replica receives**:

1. Replica reads FrameHeader (15 bytes)
2. Replica validates frame_size is within limits (maximum 16MB)
3. Replica reads message payload based on message_type
4. Replica validates checksum
5. Replica validates sequence is monotonically increasing
6. Replica processes message based on type
7. Replica sends AckMessage with highest sequence and applied_lsn

### Heartbeat Flow

**Primary sends heartbeat every 1 second**:

1. Primary creates HeartbeatMessage with current_lsn and timestamp
2. Primary sends heartbeat with next sequence number
3. Replica receives heartbeat and updates last_heartbeat timestamp
4. Replica calculates replication lag from current_lsn
5. Replica does not acknowledge heartbeat (unidirectional)

**Replica timeout detection**:

1. Replica tracks time since last message received
2. If timeout exceeded (5 seconds), replica initiates reconnection
3. Replica uses exponential backoff for reconnection attempts

### Acknowledgment Flow

**Replica acknowledges messages**:

1. Replica processes received messages (heartbeats, commit records)
2. Replica applies commit records to local state machine
3. Replica sends AckMessage after each batch or on flush interval
4. AckMessage includes highest sequence and applied_lsn
5. Replica calculates lag_ms from heartbeat timestamps

**Primary processes acknowledgment**:

1. Primary receives AckMessage from replica
2. Primary updates replica position tracking
3. Primary releases buffered messages acknowledged by all replicas
4. Primary monitors lag_ms for alerting

## Batch Processing

### Batching on Primary

**Primary batches commit records for efficiency**:

1. Primary accumulates commit records in batch buffer
2. Primary flushes batch when:
   - Batch size reaches max_batch_size (100 records or 1MB)
   - Flush interval elapsed (10 milliseconds maximum)
   - Explicit flush requested
3. Primary sends multiple CommitRecordMessage with same sequence increment
4. Primary sets LastBatch flag on final message in batch

### Processing on Replica

**Replica processes batch messages**:

1. Replica receives messages with sequence numbers
2. Replica accumulates messages until LastBatch flag set
3. Replica validates all messages in batch have sequential sequence numbers
4. Replica applies all commit records in batch atomically
5. Replica sends AckMessage with highest sequence from batch

## Compression

**Optional compression for large payloads**:

1. Primary checks if payload size exceeds compression threshold (64KB)
2. Primary compresses payload with zstd level 3
3. If compressed size smaller than original, set Compressed flag
4. Replica checks Compressed flag and decompresses before processing
5. Compression applied to CommitRecordMessage and SnapshotDataMessage

## Error Recovery

### Checksum Mismatch

**Replica detects checksum error**:

1. Replica validates checksum on message receipt
2. If checksum invalid, replica sends ErrorMessage with code 1004
3. Replica includes sequence number of corrupted message
4. Primary re-sends message with same sequence number
5. If checksum still invalid after 3 retries, replica requests bootstrap

### Sequence Number Gap

**Replica detects sequence gap**:

1. Replica expects sequence N but receives sequence N+2
2. Replica sends ErrorMessage with code 1007 (SequenceGap)
3. Replica includes expected sequence number
4. Primary re-sends missing messages
5. Replica waits for gap to be filled before processing higher sequences

### Buffer Overflow

**Primary detects buffer overflow**:

1. Primary replication buffer exceeds capacity threshold
2. Primary sends ErrorMessage with code 1005 to affected replicas
3. Primary pauses accepting new writes until buffer drained
4. Replica slows down acknowledgment to help drain buffer
5. Once buffer drained, primary resumes normal operation

## Rust Implementation Guidance

### Message Definitions

Use enums with explicit discriminant values:

```rust
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageType {
    Heartbeat = 0,
    CommitRecord = 1,
    Snapshot = 2,
    Error = 3,
}
```

### Serialization

Use byteorder crate for little-endian encoding:

- u16, u32, u64 fields encoded with to_le_bytes() and from_le_bytes()
- LSN type already has little-endian encoding from Phase 1
- FrameHeader requires manual serialization to avoid dependencies

### Checksum Calculation

Use crc crate for CRC-64:

```rust
use crc::Crc;
use crc::CRC_64_ISO;

const CHECKSUM_ALGO: Crc<u64> = Crc::<u64>::new(&CRC_64_ISO);

pub fn calculate_checksum(data: &[u8]) -> u64 {
    CHECKSUM_ALGO.checksum(data)
}
```

### Framing

Use tokio io utilities for framing:

- ReadU32 for frame_size
- ReadExact for FrameHeader
- ReadExact for message payload
- Take for limiting payload size

### Compression

Use zstd crate for compression:

```rust
use zstd::stream::{encode_all, decode_all};

pub fn compress(data: &[u8]) -> Result<Vec<u8>> {
    encode_all(data, 3) // Level 3 compression
}

pub fn decompress(data: &[u8]) -> Result<Vec<u8>> {
    decode_all(data)
}
```

### Error Handling

Define dedicated error types:

```rust
#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("Invalid frame size: {0}")]
    InvalidFrameSize(u32),

    #[error("Checksum mismatch at sequence {sequence}")]
    ChecksumMismatch { sequence: u64 },

    #[error("Sequence gap: expected {expected}, got {got}")]
    SequenceGap { expected: u64, got: u64 },

    #[error("Protocol version mismatch: requested {requested}, supported {supported}")]
    VersionMismatch { requested: u16, supported: u16 },

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
```

### Testing Strategy

Unit tests:
- Serialize and deserialize each message type
- Validate checksum calculation
- Test framing round-trip
- Verify sequence number monotonicity

Property-based tests:
- All messages serialize and deserialize correctly
- Checksums always validate for uncorrupted data
- Frame sizes never exceed maximum

Integration tests:
- End-to-end protocol handshake
- Batch processing with multiple commit records
- Error recovery (checksum mismatch, sequence gap)
- Compression and decompression

## Performance Considerations

### Zero-Copy

Use bytes::Bytes for message payloads:
- Enables zero-copy buffer sharing
- Reduces allocations for large payloads
- Supports reference counting for shared buffers

### Buffer Pooling

Maintain pool of pre-allocated buffers:
- Reuse buffers for messages of similar size
- Reduces allocation overhead
- Improves cache locality

### Batch Tuning

Default batch parameters:
- Max batch size: 100 commit records or 1MB
- Flush interval: 10 milliseconds
- Heartbeat interval: 1 second
- Acknowledgment interval: Every 10 messages or 100 milliseconds

Tune based on workload:
- High throughput: Increase batch size
- Low latency: Decrease flush interval
- Cross-region: Increase batch size and flush interval

## Security Considerations

### Transport Security

TLS 1.3 mandatory for all connections:
- Prevents eavesdropping on replication stream
- Ensures authentication of primary and replica
- Protects against man-in-the-middle attacks

### Replay Protection

Sequence numbers prevent replay attacks:
- Replica rejects duplicate sequence numbers
- Primary tracks highest acknowledged sequence per replica
- Timestamps in heartbeats detect stale data

### Resource Exhaustion

Frame size limits prevent resource exhaustion:
- Maximum frame size: 16MB
- Maximum message size: 1MB for commit records
- Maximum concurrent connections: Configurable per primary
