# Distributed Transactions v1.0 Specification

**Status**: Draft
**Version**: 1.0
**Last Updated**: 2025-12-30
**Dependencies**: [raft_v1.md](./raft_v1.md), [replication_v1.md](./replication_v1.md), [semantics_v0.md](./semantics_v0.md)

## Overview

This specification defines distributed transaction coordination for NorthstarDB, enabling atomic and isolated transactions that span multiple partitions and nodes. The design extends the single-node MVCC architecture to a distributed setting while maintaining ACID guarantees.

**Design Philosophy**: Distributed transactions are a necessary evil. Use single-partition transactions when possible; employ distributed transactions only when business logic requires cross-partition atomicity. Optimize for the single-partition fast path.

## Table of Contents

1. [Architecture](#architecture)
2. [Transaction Model](#transaction-model)
3. [Two-Phase Commit Protocol](#two-phase-commit-protocol)
4. [Concurrency Control](#concurrency-control)
5. [Failure Handling](#failure-handling)
6. [Performance Optimizations](#performance-optimizations)
7. [Implementation Phases](#implementation-phases)

## Architecture

### System Model

```
┌─────────────────────────────────────────────────────────────────┐
│                     Transaction Coordinator                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Txn Coordinator (per-client or per-partition leader)   │  │
│  │  - Transaction lifecycle management                     │  │
│  │  - Two-phase commit orchestration                       │  │
│  │  - Deadlock detection                                   │  │
│  └───────────────┬──────────────────────────────────────────┘  │
└──────────────────┼─────────────────────────────────────────────┘
                   │
         ┌─────────┴─────────┐
         │                   │
         ▼                   ▼
┌─────────────────┐  ┌─────────────────┐
│  Partition A    │  │  Partition B    │
│  (Raft Group 1) │  │  (Raft Group 2) │
│  ┌───────────┐  │  │  ┌───────────┐  │
│  │ Participant│  │  │  │ Participant│  │
│  │   (Local   │  │  │  │   (Local   │  │
│  │   MVCC)    │  │  │  │   MVCC)    │  │
│  └───────────┘  │  │  └───────────┘  │
└─────────────────┘  └─────────────────┘
```

### Key Design Decisions

1. **Coordinator Selection**: Transaction coordinator is the leader of the participant partition where the transaction begins. Avoids single point of failure.

2. **Presumed Abort**: Transactions are assumed aborted until commit vote succeeds. Reduces logging in abort case.

3. **Optimistic Concurrency Control**: Use MVCC version checks at prepare time. Deadlocks detected via wait-for graph and resolved by aborting youngest transaction.

4. **Single-Phase Fast Path**: If transaction touches single partition, skip distributed protocol entirely (existing single-node MVCC).

5. **Best-Effort Recovery**: In-doubt transactions resolved by querying participants. No separate transaction log (uses Raft log).

## Transaction Model

### Transaction Identifiers

```zig
const DistributedTxnId = struct {
    // Coordinator's node ID
    coordinator_id: u64,

    // Monotonically increasing sequence number per coordinator
    sequence: u64,

    // Timestamp for ordering and debugging
    timestamp_ms: u64,
};

fn format(self: DistributedTxnId) []const u8 {
    return std.fmt.format("{x}-{x}-{x}", .{
        self.coordinator_id, self.sequence, self.timestamp_ms,
    });
}
```

### Transaction States

```
                          ┌───────────┐
                          │   ACTIVE  │
                          └─────┬─────┘
                                │
                 ┌──────────────┴──────────────┐
                 │                             │
        (prepare succeeds)            (prepare fails / abort)
                 │                             │
                 ▼                             ▼
          ┌─────────────┐                 ┌──────────┐
          │  PREPARING  │                 │  ABORTED │
          └──────┬──────┘                 └────┬─────┘
                 │                             │
        (all votes yes)                (any vote no / timeout)
                 │                             │
                 ▼                             ▼
          ┌─────────────┐                 ┌──────────┐
          │  COMMITTING │                 │  ABORTED │
          └──────┬──────┘                 └──────────┘
                 │
                 ▼
          ┌─────────────┐
          │ COMMITTED   │
          └─────────────┘
```

### Transaction Scope

```zig
const TransactionScope = struct {
    txn_id: DistributedTxnId,

    // Participating partitions (node IDs)
    participants: []const u64,

    // Read set (for conflict detection)
    read_set: std.ArrayList(Key),

    // Write set (keys to modify)
    write_set: std.ArrayList(Key),

    // Isolation level
    isolation: IsolationLevel,

    // Timeout (ms)
    timeout_ms: u64,
};

const IsolationLevel = enum {
    read_committed,   // Can't read uncommitted data
    repeatable_read,  // Snapshot isolation (default)
    serializable,     // Full serializability (requires conflict detection)
};
```

## Two-Phase Commit Protocol

### Phase 1: Prepare

**Coordinator → Participants**: `PREPARE{txn_id, read_set, write_set}`

**Participant** (on receiving PREPARE):
1. Acquire locks on write_set keys (exclusive)
2. Validate read_set keys haven't changed (MVCC version check)
3. Write prepare record to local log: `PREPARE{txn_id, participants}`
4. Reply: `VOTE{txn_id, vote: YES/NO}`

**Validation Logic**:
```zig
fn validateReadSet(txn: *Transaction) !bool {
    for (txn.read_set.items) |key| {
        const current_version = try MVCC.getVersion(key);
        if (current_version.timestamp > txn.snapshot.timestamp) {
            return false; // Concurrent modification detected
        }
    }
    return true;
}
```

**Coordinator** (on collecting votes):
- If **all votes YES**: Transition to COMMITTING, send `COMMIT{txn_id}`
- If **any vote NO** or **timeout**: Transition to ABORTED, send `ABORT{txn_id}`

### Phase 2: Commit/Rollback

**Coordinator → Participants**: `COMMIT{txn_id}` or `ABORT{txn_id}`

**Participant** (on receiving COMMIT):
1. Apply write_set to local MVCC state
2. Write commit record to local log: `COMMIT{txn_id}`
3. Release locks
4. Reply: `ACK{txn_id}`

**Participant** (on receiving ABORT):
1. Write abort record to local log: `ABORT{txn_id}`
2. Release locks
3. Discard write_set
4. Reply: `ACK{txn_id}`

**Coordinator** (on receiving ACKs):
- Wait for all ACKs (or handle failures via recovery)
- Transaction complete

### Protocol Messages

```zig
const PrepareRequest = struct {
    txn_id: DistributedTxnId,
    coordinator_id: u64,
    read_set: []const Key,
    write_set: []const Key,
    snapshot: MVCCSnapshot,
    timeout_ms: u64,
};

const VoteResponse = struct {
    txn_id: DistributedTxnId,
    participant_id: u64,
    vote: enum { yes, no },
    reason: ?[]const u8 = null, // If vote == no
};

const CommitRequest = struct {
    txn_id: DistributedTxnId,
    decision: enum { commit, abort },
};
```

### Single-Partition Optimization

If transaction touches single partition:
- Coordinator is also participant
- Skip network round-trips
- Use existing single-node MVCC commit path
- **Benefit**: Latency comparable to single-node transactions

## Concurrency Control

### Locking Protocol

**Write Locks**:
- Acquired during prepare phase
- Exclusive locks (only one transaction can hold)
- Released after commit/abort decision

**Lock Table**:
```zig
const LockTable = struct {
    locks: std.AutoHashMap(Key, LockEntry),

    const LockEntry = struct {
        holder: DistributedTxnId,
        waiters: std.ArrayList(DistributedTxnId),
        granted_at: u64, // Timestamp
    };

    fn acquire(table: *LockTable, key: Key, txn_id: DistributedTxnId) !bool {
        const entry = table.locks.get(key);
        if (entry == null) {
            try table.locks.put(key, .{
                .holder = txn_id,
                .waiters = std.ArrayList(DistributedTxnId).init(allocator),
                .granted_at = getCurrentTimestamp(),
            });
            return true;
        }
        if (entry.?.holder == txn_id) {
            return true; // Already hold lock
        }
        // Add to wait queue (potential deadlock)
        try entry.?.waiters.append(txn_id);
        return false;
    }
};
```

### Deadlock Detection

**Wait-For Graph**:
- Nodes: Transactions
- Edges: T1 → T2 if T1 waits for lock held by T2
- Cycle = Deadlock

**Detection Algorithm**:
```zig
fn detectDeadlock(wait_for: *const WaitForGraph) ?DistributedTxnId {
    var visited = std.AutoHashMap(DistributedTxnId, void).init(allocator);
    var rec_stack = std.AutoHashMap(DistributedTxnId, void).init(allocator);

    for (wait_for.nodes.items) |txn| {
        if (!visited.contains(txn)) {
            if (dfsCycle(txn, wait_for, &visited, &rec_stack)) {
                return txn; // Return transaction in cycle
            }
        }
    }
    return null;
}

fn dfsCycle(
    txn: DistributedTxnId,
    wait_for: *const WaitForGraph,
    visited: *std.AutoHashMap(DistributedTxnId, void),
    rec_stack: *std.AutoHashMap(DistributedTxnId, void),
) bool {
    visited.put(txn, {}) catch {};
    rec_stack.put(txn, {}) catch {};

    for (wait_for.getNeighbors(txn)) |neighbor| {
        if (!visited.contains(neighbor)) {
            if (dfsCycle(neighbor, wait_for, visited, rec_stack)) {
                return true;
            }
        } else if (rec_stack.contains(neighbor)) {
            return true; // Back edge = cycle
        }
    }

    _ = rec_stack.remove(txn);
    return false;
}
```

**Deadlock Resolution**:
- Victim selection: Youngest transaction (most recent timestamp)
- Alternative: Transaction touching fewest keys
- Coordinator sends `ABORT{txn_id}` to victim
- Victim releases locks, unblocking waiters

### Conflict Detection (Serializable Isolation)

**Write Skew Prevention**:
- Track `read_set` × `write_set` conflicts
- Example: T1 reads X, writes Y; T2 reads Y, writes X
- Both validate read sets independently but create anomaly

**Detection**:
- Build dependency graph: T1 → T2 if T2's write_set overlaps T1's read_set
- Serialize topologically; if cycle exists, abort one transaction

## Failure Handling

### Coordinator Failure During Prepare

**Scenario**: Coordinator crashes after sending PREPARE but before collecting all votes

**Participant State**: `PREPARED` (locks held, waiting for decision)

**Recovery**:
1. New coordinator elected (Raft)
2. Scan Raft log for `PREPARE` records
3. For each in-doubt transaction, query participants
4. If any participant voted NO: Abort
5. If all voted YES: Commit (presumed commit)
6. Send decision to all participants

### Coordinator Failure During Commit

**Scenario**: Coordinator crashes after sending COMMIT but before receiving ACKs

**Participant State**: `COMMITTING` (decision received, applying changes)

**Recovery**:
1. Participants replay Raft log, discover `COMMIT` record
2. Apply changes (idempotent)
3. Send ACK to new coordinator
4. Transaction completes despite coordinator failure

### Participant Failure During Prepare

**Scenario**: Participant crashes before voting

**Coordinator Behavior**:
1. Timeout waiting for vote
2. Assume NO vote (pessimistic)
3. Send ABORT to other participants
4. Transaction aborted

**Participant Recovery**:
1. Replay Raft log, find `PREPARE` record
2. No decision recorded: Rollback (release locks)
3. Decision recorded: Apply decision

### Participant Failure During Commit

**Scenario**: Participant crashes after voting YES but before applying commit

**Coordinator Behavior**:
1. Timeout waiting for ACK
2. Retry COMMIT to participant
3. If still failing: Mark participant as down, continue
4. Transaction considered committed from coordinator's perspective

**Participant Recovery**:
1. Replay Raft log, find `COMMIT` record
2. Apply changes, release locks
3. Send ACK to coordinator
4. Transaction completes

### Network Partition

**Scenario**: Coordinator and participants partitioned

**Behavior**:
- Raft ensures coordinator has quorum access
- If coordinator can't reach quorum: Step down, abort in-flight transactions
- Participants timeout waiting for decision, query other participants

**Recovery**:
- Partition healed: Recovered coordinator resolves in-doubt transactions
- Orphaned transactions: Background cleanup job scans for `PREPARE` records older than timeout

## Performance Optimizations

### Batching

**Prepare Batching**:
- Coordinator batches prepare requests to same participant
- Single network round-trip for multiple transactions
- Applies to high-throughput scenarios

**Commit Batching**:
- Coordinator batches commit decisions to participants
- Reduces control message overhead

### Pipelining

**Non-Blocking Prepare**:
- Send prepare to all participants in parallel
- Don't wait for response before sending next request
- Benefit: Commit latency ≈ max(participant latency) not sum

### Early Lock Release

**Read-Only Transactions**:
- No write locks needed
- Skip prepare phase entirely
- Return immediately after reading snapshot

**Single-Participant Transactions**:
- Skip distributed protocol
- Use single-node MVCC path
- **Benefit**: 10-100x lower latency

### Speculative Execution

**Optimistic Apply**:
- Participant speculatively applies write_set during prepare
- If abort: Rollback using undo log
- If commit: Changes already applied, skip apply phase
- **Risk**: Wasted work on abort

**Use Case**: Low conflict workloads, high abort rate acceptable

### Caching

**Participant Metadata Cache**:
- Cache participant addresses and partition assignments
- Reduce lookup overhead for repeated transactions

**Transaction Metadata Cache**:
- Cache in-flight transaction state
- Avoid disk reads for recovery

## Implementation Phases

### Phase 1: Core Protocol (Weeks 1-3)

**Deliverables**:
- [ ] Transaction coordinator implementation
- [ ] Prepare/Commit/Abort RPC messages
- [ ] Participant state machine
- [ ] Basic two-phase commit logic
- [ ] Integration tests (2-node, single transaction)

**Success Criteria**:
- Distributed transaction commits atomically across 2 partitions
- Abort rolls back all participants
- Single-partition transactions take fast path

### Phase 2: Failure Handling (Weeks 4-5)

**Deliverables**:
- [ ] Coordinator failure recovery
- [ ] Participant failure recovery
- [ ] In-doubt transaction resolution
- [ ] Hardening tests (crash during each phase)

**Success Criteria**:
- No lost commits despite coordinator crash
- No orphaned locks after participant crash
- Recovery completes within 30 seconds

### Phase 3: Concurrency Control (Weeks 6-7)

**Deliverables**:
- [ ] Lock manager (exclusive locks)
- [ ] Deadlock detection (wait-for graph)
- [ ] Deadlock resolution (abort victim)
- [ ] Serializable isolation conflict detection

**Success Criteria**:
- No deadlocks in high-concurrency workload
- Deadlock detection overhead < 5% CPU
- Serializable isolation prevents write skew

### Phase 4: Performance Optimization (Weeks 8-9)

**Deliverables**:
- [ ] Prepare/commit batching
- [ ] Pipelined prepare requests
- [ ] Single-participant fast path
- [ ] Benchmark suite for distributed transactions

**Success Criteria**:
- 2PC overhead < 20% compared to single-partition
- Distributed transaction throughput > 10K txn/sec
- p99 latency < 100ms (2 partitions, same region)

### Phase 5: Advanced Features (Week 10)

**Deliverables**:
- [ ] Read-only transactions (no locks)
- [ ] Speculative execution (optimistic apply)
- [ ] Adaptive timeout tuning
- [ ] Observability (transaction tracing)

**Success Criteria**:
- Read-only transactions add < 1ms overhead
- Speculative execution improves throughput by > 20% in low-conflict workloads
- End-to-end transaction tracing enabled

## Integration Points

### Existing Infrastructure

| Component | Integration |
|-----------|-------------|
| **MVCC Snapshots** (`src/mvcc.zig`) | Snapshot isolation for read_set validation |
| **Commit Records** (`src/commit_record.zig`) | Persist PREPARE/COMMIT/ABORT decisions |
| **WAL** (`src/wal.zig`) | Participant decision logging |
| **Raft** (`src/consensus/raft.zig`) | Coordinator failure recovery |
| **Replication** (`src/replication/`) | Cross-region transaction propagation |

### New Components

| Component | Responsibility |
|-----------|---------------|
| **Coordinator** (`src/dist/txn_coordinator.zig`) | Two-phase commit orchestration |
| **Participant** (`src/dist/txn_participant.zig`) | Local transaction execution |
| **Lock Manager** (`src/dist/lock_manager.zig`) | Distributed lock acquisition |
| **Deadlock Detector** (`src/dist/deadlock_detector.zig`) | Wait-for graph analysis |
| **Recovery** (`src/dist/recovery.zig`) | In-doubt transaction resolution |

### Configuration

```zig
const DistributedTxnConfig = struct {
    // Coordinator settings
    coordinator: struct {
        prepare_timeout_ms: u64 = 5000,
        commit_timeout_ms: u64 = 10000,
        max_in_flight: u32 = 1000,
        enable_batching: bool = true,
        batch_size: u32 = 10,
        batch_timeout_ms: u64 = 5,
    },

    // Participant settings
    participant: struct {
        lock_timeout_ms: u64 = 30000,
        enable_speculative: bool = false,
        speculative_undo_log: bool = true,
    },

    // Deadlock detection
    deadlock: struct {
        enabled: bool = true,
        detection_interval_ms: u64 = 100,
        victim_selection: enum { youngest, smallest, random } = .youngest,
    },
};
```

## Benchmark Targets

| Benchmark | Target | Notes |
|-----------|--------|-------|
| Single-Partition Txn | < 5ms p99 | Fast path, same as single-node |
| 2-Partition Txn (Same Region) | < 50ms p99 | 2PC overhead |
| 2-Partition Txn (Cross-Region) | < 200ms p99 | Network latency dominates |
| Distributed Txn Throughput | > 10K txn/sec | 3 partitions, same region |
| Deadlock Detection Overhead | < 5% CPU | High-concurrency workload |
| Recovery Time | < 30 sec | In-doubt transaction resolution |
| Abort Latency | < 10ms p99 | Single round-trip |

## Failure Scenarios

### Scenario 1: Coordinator Crash During Prepare

```
Initial state:
  Coordinator sends PREPARE to P1, P2, P3
  P1 votes YES, P2 votes YES, P3 crashes

Failure:
  Coordinator crashes before collecting P3's vote

Recovery:
  New coordinator queries P1, P2, P3
  P3 recovers, finds no PREPARE record, votes NO (timeout)
  Transaction aborted
```

### Scenario 2: Participant Crash During Commit

```
Initial state:
  Coordinator collects YES votes from all
  Sends COMMIT to P1, P2, P3
  P1, P2 commit, P3 crashes

Failure:
  P3 crashes before applying commit

Recovery:
  P3 replays Raft log, finds COMMIT record
  Applies changes, releases locks
  Transaction committed
```

### Scenario 3: Network Partition

```
Initial state:
  Coordinator and P1 in partition A
  P2, P3 in partition B

Failure:
  Partition occurs during prepare phase
  Coordinator can't reach P2, P3

Recovery:
  Coordinator times out, assumes NO votes
  Sends ABORT to P1
  Partition heals: P2, P3 roll back PREPARE state
  Transaction aborted
```

## Security Considerations

### Transport Security

- **TLS 1.3** for all 2PC messages
- Certificate-based participant authentication
- Network isolation (VPC, private subnets)

### Access Control

- Authorization checked at coordinator (before prepare)
- Participants validate coordinator identity
- Audit logging for all distributed transactions

### DoS Protection

- Rate limiting on prepare requests
- Per-participant timeout queues
- Circuit breaker for failing participants

## Future Work (Post-v1.0)

1. **3-Phase Commit**: Reduce blocking window (requires presumed commit)
2. **Sagas**: Long-running transactions with compensating actions
3. **Multi-Version Concurrency**: Optimistic distributed transactions
4. **Adaptive Partitioning**: Dynamically rebalance data based on transaction patterns
5. **Predictive Routing**: Route transactions to minimize cross-partition calls

## Appendix

### A. State Machine Details

```
Coordinator States:
  ACTIVE → PREPARING → COMMITTING/ABORTED → COMMITTED/ABORTED

Participant States:
  ACTIVE → PREPARED → COMMITTING/ABORTED → COMMITTED/ABORTED
```

### B. Message Sequence Diagram

```
Client          Coordinator          P1              P2              P3
  │                  │                │               │               │
  │ begin txn        │                │               │               │
  │─────────────────>│                │               │               │
  │                  │                │               │               │
  │ write(k1, v1)    │                │               │               │
  │─────────────────>│                │               │               │
  │                  │                │               │               │
  │ write(k2, v2)    │                │               │               │
  │─────────────────>│                │               │               │
  │                  │                │               │               │
  │ commit           │                │               │               │
  │─────────────────>│                │               │               │
  │                  │ PREPARE        │               │               │
  │                  │───────────────>│               │               │
  │                  │ PREPARE                       │               │
  │                  │───────────────────────────────>│               │
  │                  │ PREPARE                                       │
  │                  │──────────────────────────────────────────────>│
  │                  │                │               │               │
  │                  │ VOTE(YES)      │               │               │
  │                  │<───────────────│               │               │
  │                  │ VOTE(YES)                      │               │
  │                  │<───────────────────────────────│               │
  │                  │ VOTE(YES)                                      │
  │                  │<──────────────────────────────────────────────│
  │                  │                │               │               │
  │                  │ COMMIT         │               │               │
  │                  │───────────────>│               │               │
  │                  │ COMMIT                         │               │
  │                  │───────────────────────────────>│               │
  │                  │ COMMIT                                         │
  │                  │──────────────────────────────────────────────>│
  │                  │                │               │               │
  │                  │ ACK            │               │               │
  │                  │<───────────────│               │               │
  │                  │ ACK                            │               │
  │                  │<───────────────────────────────│               │
  │                  │ ACK                                            │
  │                  │<──────────────────────────────────────────────│
  │                  │                │               │               │
  │ committed         │                │               │               │
  │<─────────────────│                │               │               │
```

### C. Error Codes

| Code | Name | Description |
|------|------|-------------|
| 3001 | ERR_TXN_TIMEOUT | Transaction timed out during prepare/commit |
| 3002 | ERR_TXN_ABORTED | Transaction aborted (deadlock, conflict) |
| 3003 | ERR_TXN_PREPARE_FAILED | Participant vote NO |
| 3004 | ERR_TXN_LOCK_UNAVAILABLE | Lock acquisition failed |
| 3005 | ERR_TXN_DEADLOCK | Deadlock detected, transaction aborted |
| 3006 | ERR_TXN_COORDINATOR_DOWN | Coordinator unavailable |
| 3007 | ERR_TXN_PARTICIPANT_DOWN | Participant unavailable |

---

**Document History**:
- 2025-12-30: Initial draft (v1.0)
