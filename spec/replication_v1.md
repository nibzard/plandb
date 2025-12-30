# Replication v1.0 Specification

**Status**: Draft
**Version**: 1.0
**Last Updated**: 2025-12-30
**Dependencies**: [commit_record_v0.md](./commit_record_v0.md), [semantics_v0.md](./semantics_v0.md)

## Overview

This specification defines the replication architecture for NorthstarDB, transforming it from a single-node embedded database into a distributed system with multi-region deployment capabilities. The design leverages the existing commit record and WAL infrastructure as the foundation for replication.

**Design Philosophy**: The commit record is "the seam that becomes replication." Every write already produces a sequential, checksummed record - we extend this to stream records across nodes.

## Table of Contents

1. [Architecture](#architecture)
2. [Replication Topologies](#replication-topologies)
3. [Consistency Model](#consistency-model)
4. [Protocol Specification](#protocol-specification)
5. [Failure Modes](#failure-modes)
6. [Integration Points](#integration-points)
7. [Implementation Phases](#implementation-phases)
8. [Monitoring and Observability](#monitoring-and-observability)

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         Primary Region                           │
│  ┌──────────────┐    ┌───────────────┐    ┌──────────────────┐  │
│  │   Write Txn  │───▶│  Commit Log   │───▶│  Replication     │  │
│  │   (Single)   │    │  (WAL)        │    │  Publisher       │  │
│  └──────────────┘    └───────────────┘    └────────┬─────────┘  │
│                                                  │             │
└──────────────────────────────────────────────────┼─────────────┘
                                                   │ Network
                                                   │ (Streaming)
                                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Replica Region                          │
│  ┌─────────────────┐              ┌──────────────────────────┐ │
│  │   Replication   │◀─────────────┤  Network Stream          │ │
│  │   Subscriber    │              │  (gRPC/QUIC)             │ │
│  └────────┬────────┘              └──────────────────────────┘ │
│           │                                                     │
│           ▼                                                     │
│  ┌─────────────────┐    ┌──────────────────────────────────┐  │
│  │   Apply Engine  │───▶│  Local MVCC Snapshots            │  │
│  │   (Replay)      │    │  (Read-Only Queries)             │  │
│  └─────────────────┘    └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Primary-Replica Topology (v1.0)**: Single primary accepts writes, replicas are read-only. Simplifies consistency model and leverages existing single-writer design.

2. **Log-Based Replication**: Replicate the commit log, not the page files. This ensures:
   - Smaller replication payload (logical operations vs full pages)
   - Deterministic replay (replica applies same operations)
   - Natural support for time-travel queries (replica has full history)

3. **Asynchronous Streaming**: Replicas tail the commit log with configurable lag tolerance. Enables geo-distribution with local reads.

4. **Pull-Based**: Replicas pull from primary rather than primary pushing. Simplifies failure recovery and backpressure handling.

## Replication Topologies

### Phase 1: Primary-Replica (v1.0)

```
Primary (US-East) ──┬──▶ Replica (US-West)
                    │
                    ├──▶ Replica (EU-West)
                    │
                    └──▶ Replica (AP-South)
```

**Characteristics**:
- Single primary accepts all writes
- Replicas serve read-only traffic
- Async replication with tunable consistency
- Manual failover (v1.0), automatic (v2.0 with Raft)

### Phase 2: Multi-Primary with Conflict Resolution (v2.0)

```
Primary (US-East) ◀─▶ Primary (EU-West)        (Active-Active)
        │                       │
        └──────▶ Conflict Resolution ◀───────┘
```

**Characteristics**:
- Multiple writable primaries
- Last-Writer-Wins (LWW) or CRDT-based conflict resolution
- Higher write throughput at cost of complexity

**Note**: v1.0 specification focuses on Phase 1 (Primary-Replica).

## Consistency Model

### Write Path

```
1. Client writes to primary
2. Primary commits to local WAL (durability guaranteed)
3. Primary writes to in-memory replication buffer
4. Primary ACKs client (write committed)
5. Replication Publisher streams to replicas (async)
```

**Guarantee**: Writes are durable on primary before ACK. Replication lag is decoupled from write latency.

### Read Path

```
Read on Primary:
├─▶ Read from latest MVCC snapshot (strong consistency)

Read on Replica:
├─▶ Read from replica's MVCC snapshot
├─▶ Snapshot timestamp <= primary's current timestamp
└─▶ Bounded staleness (tunable via replication lag target)
```

### Consistency Levels

| Level | Description | Use Case | Latency Impact |
|-------|-------------|----------|----------------|
| **Strong** | Read from primary | Critical data, financial | Low (single region) |
| **Bounded Staleness** | Read from replica with lag < N ms | Analytics, dashboards | Very low (local read) |
| **Eventual** | Read from any replica | Caching, non-critical | Near-zero |

### Replication Lag

**Target**: Configurable per-replica:
- **Tight**: < 10ms (same region)
- **Normal**: < 100ms (cross-region)
- **Relaxed**: < 1s (cost-optimized)

**Implementation**: Replica tracks `replicationLag = primaryLsn - appliedLsn`. Exceeding threshold triggers:
- Alert
- Read traffic rejection (optional)
- Auto-scaling of replica resources

## Protocol Specification

### Replication Stream Format

The replication stream wraps commit records with metadata:

```zig
const ReplicationMessage = struct {
    // Protocol version for compatibility
    version: u16 = 1,

    // Message type
    message_type: enum(u8) {
        heartbeat = 0,      // Periodic keepalive
        commit_record = 1,  // Actual commit record
        snapshot = 2,       // Full snapshot for bootstrap
        error = 3,          // Error notification
    },

    // Sequence number (monotonically increasing)
    sequence: u64,

    // Original commit record (for commit_record messages)
    commit_record: ?CommitRecord,

    // Checksum for integrity
    checksum: u64,
};
```

### Connection Establishment

```
1. Replica connects to Primary:CONNECT{replica_id, start_lsn}
2. Primary validates and responds:ACCEPT{current_lsn, protocol_version}
3. Primary starts streaming commit records from start_lsn
4. Replica acknowledges each message:ACK{sequence}
5. Primary tracks replica position for resume after disconnect
```

### Heartbeat Protocol

- Primary sends heartbeat every 1 second
- Replica expects message within 5 seconds or initiates reconnect
- Heartbeat includes `currentLsn` for lag calculation

### Bootstrap Protocol

For new replicas or replicas far behind:

```
1. Replica requests bootstrap:BOOTSTRAP_REQUEST
2. Primary creates snapshot (via existing snapshot infrastructure)
3. Primary streams snapshot:SNAPSHOT_DATA{pages, metadata}
4. Replica applies snapshot to local storage
5. Primary resumes replication from snapshot LSN:RESUME_REPLICATION{lsn}
```

## Failure Modes

### Network Partition

**Scenario**: Replica loses connection to primary

```
Replica State Machine:
CONNECTED ──▶ DISCONNECTED (detected via heartbeat timeout)
    │                │
    │                ▼
    │          RECONNECTING (exponential backoff: 1s, 2s, 4s...)
    │                │
    │                ▼
    └────────────────│
                     │
               CONNECTION_RESTORED
                     │
                     ▼
               CATCHUP (resume from last ACKed LSN)
                     │
                     ▼
               CONNECTED
```

**Behavior**:
- Replica continues serving reads from stale data
- Client applications decide whether to accept stale reads
- Replica buffers incoming connection attempts (no thundering herd)

### Primary Failure

**Scenario**: Primary crashes or becomes unavailable

```
v1.0 (Manual Failover):
1. Operator detects primary failure
2. Promote replica to primary: PROMOTE{force=true}
3. Update DNS/load balancer to point to new primary
4. Other replicas connect to new primary

v2.0 (Automatic with Raft):
- Raft consensus automatically elects new leader
- Replica state machine handles transition transparently
```

**v1.0 Limitations**:
- Manual intervention required
- Potential data loss (unreplicated commits on failed primary)
- Split-brain risk if old primary recovers (operator responsibility)

### Replica Failure

**Scenario**: Replica crashes or falls behind

**Behavior**:
- Primary continues accepting writes
- Primary tracks replica position in memory (reset on restart)
- On recovery, replica resumes from last ACKed LSN
- If too far behind, replica triggers bootstrap

### Corruption Detection

Commit record checksums are validated:
- **On Primary**: Before writing to WAL (existing behavior)
- **On Replication Stream**: Before sending to replica
- **On Replica**: Before applying to local state

**Corruption Response**:
1. Replica sends ERROR message to primary
2. Primary re-sends the commit record
3. If corruption persists, replica requests bootstrap from earlier snapshot

## Integration Points

### Existing Infrastructure

| Component | Usage in Replication |
|-----------|---------------------|
| **Commit Record** (`src/commit_record.zig`) | Unit of replication. Reserved fields available for replication metadata. |
| **WAL** (`src/wal.zig`) | Source of truth for replication stream. Publisher tails the WAL. |
| **Replay Engine** (`src/replay.zig`) | Replica uses replay logic to apply commit records. |
| **MVCC Snapshots** | Replica queries use local snapshots (bounded staleness). |
| **Checksums** | End-to-end integrity validation (primary → network → replica). |

### New Components

| Component | Responsibility |
|-----------|---------------|
| **Replication Publisher** (`src/replication/publisher.zig`) | Streams commit records to connected replicas. |
| **Replication Subscriber** (`src/replication/subscriber.zig`) | Pulls and applies commit records from primary. |
| **Replication Server** (`src/replication/server.zig`) | Handles replica connections, authentication, throttling. |
| **Replication Client** (`src/replication/client.zig`) | Manages connection to primary, reconnection, state machine. |

### Configuration

```zig
const ReplicationConfig = struct {
    // Role: "primary" or "replica"
    role: enum { primary, replica },

    // Primary-specific
    primary: ?struct {
        listen_address: []const u8, // e.g., "0.0.0.0:7233"
        max_replicas: u32 = 10,
        replication_buffer_size: u64 = 1024 * 1024 * 100, // 100MB
    } = null,

    // Replica-specific
    replica: ?struct {
        primary_address: []const u8, // e.g., "primary.example.com:7233"
        replication_lag_target_ms: u64 = 100,
        reconnect_interval_ms: u64 = 1000,
        bootstrap_on_start: bool = false,
    } = null,
};
```

## Implementation Phases

### Phase 1: Core Infrastructure (Weeks 1-2)

**Deliverables**:
- [ ] Protocol specification (this document)
- [ ] Publisher implementation (tail WAL, stream to replicas)
- [ ] Subscriber implementation (connect, receive, apply)
- [ ] Basic integration tests (single primary, single replica)

**Success Criteria**:
- Single replica can successfully replicate commit records from primary
- Replica can serve read-only queries from replicated data

### Phase 2: Robustness (Weeks 3-4)

**Deliverables**:
- [ ] Heartbeat and reconnection logic
- [ ] Bootstrap protocol for new replicas
- [ ] Checksum validation on replication path
- [ ] Hardening tests (network partition, primary crash, replica crash)

**Success Criteria**:
- Replica automatically reconnects after network failure
- Replica can bootstrap from scratch and catch up
- No data corruption in failure scenarios

### Phase 3: Multi-Replica (Weeks 5-6)

**Deliverables**:
- [ ] Support for multiple replicas per primary
- [ ] Replication position tracking per replica
- [ ] Per-replica lag monitoring
- [ ] Load balancing of read traffic across replicas

**Success Criteria**:
- Primary can replicate to 10+ replicas simultaneously
- Each replica can operate independently with different lag targets

### Phase 4: Observability (Week 7)

**Deliverables**:
- [ ] Metrics: replication lag, throughput, error rate
- [ ] Alerting: lag exceeded, replica disconnected, corruption detected
- [ ] Dashboard: replica health, replication graph visualization
- [ ] Distributed tracing integration

**Success Criteria**:
- Operator can monitor replication health in real-time
- Alerts fire before SLA violations occur

### Phase 5: Performance Optimization (Week 8)

**Deliverables**:
- [ ] Batch commit records for network efficiency
- [ ] Compression for cross-region replication
- [ ] Zero-copy optimizations (mmap for replication buffer)
- [ ] Benchmark suite for replication throughput

**Success Criteria**:
- Replication throughput > 100K commits/sec on same hardware as baseline
- Cross-region replication (US-East → EU-West) < 50ms p99 latency

## Monitoring and Observability

### Key Metrics

| Metric | Type | Description | Alert Threshold |
|--------|------|-------------|-----------------|
| `replication_lag_ms` | Gauge | Lag between primary and replica | > 500ms for > 1min |
| `replication_throughput_cps` | Gauge | Commits replicated per second | < baseline * 0.5 |
| `replication_error_rate` | Counter | Replication errors (checksum, network) | > 0.01% |
| `replica_connected` | Boolean | Replica connection status | false for > 30s |
| `replication_buffer_bytes` | Gauge | Primary replication buffer usage | > 80% capacity |
| `replica_apply_latency_ms` | Histogram | Time for replica to apply commit | p99 > 10ms |

### Distributed Tracing

Each replicated write traced as:
```
Write Txn (Primary) → Commit Log → Replication Publisher → Network →
Replication Subscriber → Apply Engine (Replica) → MVCC Snapshot
```

Trace includes:
- LSN assigned at primary
- Timestamps at each hop
- Replication lag calculation
- Error annotations if any

### Health Checks

**Primary Health**:
- WAL write latency < 10ms p99
- Replication buffer not full
- All replicas connected (or expected number)

**Replica Health**:
- Replication lag below target
- No checksum errors in last hour
- Sufficient disk space for WAL + DB

## Security Considerations

### Transport Security

- **TLS 1.3** required for all replication connections
- Certificate-based authentication (replica certificates signed by primary CA)
- Forward secrecy enabled

### Access Control

- Replicas authenticate with client certificates
- Primary validates replica whitelist
- Optional: Mutual TLS for both directions

### Data at Rest

- Replicas store data encrypted at rest (same as primary)
- WAL encryption maintained on replica

## Future Work (Post-v1.0)

1. **Raft Consensus Integration**: Automatic failover, strong consistency guarantees
2. **Multi-Master Replication**: Active-active topology with conflict resolution
3. **Sharding**: Partition data across multiple primary-replica groups
4. **Change Data Capture (CDC)**: Expose replication stream to external consumers
5. **Cross-Cloud Replication**: Replicate across AWS, GCP, Azure for redundancy

## Appendix

### A. Replication State Machine

```
[Primary State Machine]
INITIALIZING → LISTENING → REPLICATING → SHUTTING_DOWN → TERMINATED

[Replica State Machine]
INITIALIZING → CONNECTING → CATCHUP → REPLICATING →
    (DISCONNECTED on error) → CONNECTING
```

### B. Error Codes

| Code | Name | Description |
|------|------|-------------|
| 1001 | ERR_VERSION_MISMATCH | Protocol version incompatible |
| 1002 | ERR_AUTH_FAILED | Replica authentication failed |
| 1003 | ERR_LSN_NOT_FOUND | Requested LSN not available (need bootstrap) |
| 1004 | ERR_CHECKSUM_INVALID | Commit record checksum validation failed |
| 1005 | ERR_BUFFER_OVERFLOW | Replication buffer exceeded capacity |
| 1006 | ERR_REPLICA_LIMIT | Max replicas reached on primary |

### C. Benchmark Targets

| Benchmark | Target | Notes |
|-----------|--------|-------|
| Replication Throughput | > 100K commits/sec | Single primary, single replica |
| Replication Lag (Same Region) | < 10ms p99 | 1 Gbps network |
| Replication Lag (Cross-Region) | < 100ms p99 | US-East → EU-West |
| Bootstrap Time | < 5 min per GB | Snapshot transfer + apply |
| Failover Time (Manual) | < 60 seconds | Operator-driven promotion |

---

**Document History**:
- 2025-12-30: Initial draft (v1.0)
