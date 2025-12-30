# Leader Election and Failover v1.0 Specification

**Status**: Draft
**Version**: 1.0
**Last Updated**: 2025-12-30
**Dependencies**: [raft_v1.md](./raft_v1.md), [replication_v1.md](./replication_v1.md), [dist_transactions_v1.md](./dist_transactions_v1.md)

## Overview

This specification defines leader election and failover mechanisms for NorthstarDB distributed deployments. The design builds on Raft consensus while adding operational considerations for automated failover, leader transfer, and split-brain prevention.

**Design Philosophy**: Leader election should be fast, deterministic, and observable. Operators retain control over failover decisions while automation handles common failure scenarios.

## Table of Contents

1. [Architecture](#architecture)
2. [Leader Election](#leader-election)
3. [Failover Detection](#failover-detection)
4. [Automated Failover](#automated-failover)
5. [Manual Failover](#manual-failover)
6. [Leader Transfer](#leader-transfer)
7. [Split-Brain Prevention](#split-brain-prevention)
8. [Implementation Phases](#implementation-phases)

## Architecture

### System Model

```
┌─────────────────────────────────────────────────────────────────┐
│                     Raft Consensus Group                        │
│                                                                  │
│   ┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐│
│   │ Node 1  │      │ Node 2  │      │ Node 3  │      │ Node 4  ││
│   │ Leader  │──────│Follower │──────│Follower │──────│Follower ││
│   └────┬────┘      └────┬────┘      └────┬────┘      └────┬────┘│
│        │                │                │                │     │
│        └────────────────┴────────────────┴────────────────┘     │
│                         Heartbeat Network                        │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Health Monitor                              │
│  - Tracks leader liveness via heartbeats                        │
│  - Monitors participant health                                  │
│  - Triggers elections on leader failure                         │
│  - Notifies operators of failover events                        │
└─────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Raft-Based Elections**: Leader election uses Raft's RequestVote protocol. No custom election logic.

2. **Fast Failover**: Election timeout configured for sub-second failover (150-300ms randomized).

3. **Quorum Awareness**: Nodes track cluster membership and only vote for candidates with up-to-date logs.

4. **Operator Override**: Manual failover API allows operators to trigger elections when needed (maintenance, rolling upgrades).

5. **Observability**: Every election and failover event logged with metrics for debugging.

## Leader Election

### Raft Election Protocol

Leader election follows standard Raft (see `raft_v1.md`). Key aspects:

**Election Timeout**:
- Randomized per node: `base_timeout + random(0, jitter)`
- Default: `base = 150ms`, `jitter = 150ms` (range: 150-300ms)
- Reset on receiving valid AppendEntries (heartbeat)

**Election Trigger**:
- Follower hasn't received heartbeat within `election_timeout`
- Follower transitions to Candidate
- Increments `current_term`, votes for self
- Sends RequestVote to all nodes

**Vote Granting Rules**:
```zig
fn grantVote(args: RequestVoteArgs) bool {
    // Reject if term is older
    if (args.term < current_term) return false;

    // Update term if newer
    if (args.term > current_term) {
        current_term = args.term;
        voted_for = null;
        becomeFollower();
    }

    // Grant vote if:
    // 1. Haven't voted OR already voted for this candidate
    // 2. Candidate's log is at least as up-to-date
    const log_ok = (args.last_log_term > lastLogTerm()) or
                   (args.last_log_term == lastLogTerm() and
                    args.last_log_index >= lastLogIndex());

    const vote_ok = (voted_for == null) or (voted_for == args.candidate_id);

    return vote_ok and log_ok;
}
```

### Election States

```
            ┌──────────────────┐
            │     FOLLOWER     │
            └────────┬─────────┘
                     │ (election timeout)
                     ▼
            ┌──────────────────┐
            │    CANDIDATE     │
            └────────┬─────────┘
                     │ (majority votes)
                     ▼
            ┌──────────────────┐
            │     LEADER       │
            └────────┬─────────┘
                     │ (higher term discovered)
                     ▼
            ┌──────────────────┐
            │     FOLLOWER     │
            └──────────────────┘
```

### Priority-Based Elections (Optional Enhancement)

**Use Case**: Prefer certain nodes as leaders (e.g., nodes in primary region)

**Mechanism**: Extend RequestVote with `priority` field:
```zig
const RequestVoteArgs = struct {
    term: u64,
    candidate_id: u64,
    last_log_index: u64,
    last_log_term: u64,
    priority: u8 = 0, // Higher = preferred (optional)
};
```

**Vote Strategy**:
- If all logs equal, vote for higher priority
- Ensures leader in preferred region when possible

**Risk**: Can delay elections if high-priority node is unavailable

## Failover Detection

### Health Monitoring

**Leader Liveness**:
- Followers track last heartbeat timestamp
- Timeout = `election_timeout * 2` (conservative)
- Timeout triggers: Log warning, monitor metrics

**Participant Health**:
- Leader tracks last successful AppendEntries to each follower
- Timeout = `heartbeat_interval * 10` (500ms default)
- Unhealthy followers excluded from replication quorum

### Failure Detection

```
Follower (Node 2):
    last_heartbeat = now()
    while (true) {
        sleep(100ms)
        if (now() - last_heartbeat > election_timeout) {
            triggerElection()
            break
        }
    }

Leader (Node 1):
    for each follower f:
        f.last_contact = now()
    while (true) {
        sleep(heartbeat_interval)
        for each follower f:
            sendHeartbeat(f)
            if (now() - f.last_contact > failure_timeout) {
                markUnhealthy(f)
                alert(f, "follower_unresponsive")
            }
    }
```

### Failure Scenarios

| Scenario | Detection Time | Recovery Action |
|----------|----------------|-----------------|
| Leader crash | 150-300ms | Followers start election |
| Network partition | 150-300ms | Partitioned minority steps down |
| Leader hang (CPU/deadlock) | 300-600ms | Followers start election |
| Partial network loss | 150-300ms | Unreachable nodes excluded |

## Automated Failover

### Failover Process

```
Timeline:
  T0: Leader fails (crash, partition, hang)
  T1: Followers detect failure (election timeout)
  T2: Followers transition to Candidate, start election
  T3: Candidate wins majority votes, becomes Leader
  T4: New Leader sends first heartbeat
  T5: Cluster stabilized (election complete)

Total: T5 - T0 ≈ 150-300ms (single election round)
```

### Client Failover

**Client Behavior**:
- Client maintains connection to leader
- On RPC failure: Refresh leader via `GET /leader` endpoint
- Retry operation against new leader
- Idempotent operations safe to retry

**Leader Discovery API**:
```zig
const LeaderInfo = struct {
    leader_id: u64,
    leader_address: []const u8, // "host:port"
    term: u64,
};

fn getCurrentLeader(cluster: []const NodeInfo) !LeaderInfo {
    // Query all nodes, return highest-term leader
    var best_leader: ?LeaderInfo = null;
    for (cluster) |node| {
        const info = rpc.getLeader(node.address) catch continue;
        if (best_leader == null or info.term > best_leader.?.term) {
            best_leader = info;
        }
    }
    return best_leader orelse error.NoLeader;
}
```

### Graceful Degradation

**Read-Only Mode**:
- If no leader elected, cluster serves stale reads from followers
- Writes rejected with error: `ERR_NO_LEADER`
- Clients can retry after timeout

**Partial Availability**:
- Minority partition continues serving reads (if data not stale)
- Majority partition elects new leader, serves writes
- Partition healing: Minority rolls back uncommitted entries, rejoins

## Manual Failover

### Use Cases

- **Planned Maintenance**: Transfer leadership before upgrading node
- **Rolling Upgrades**: Sequentially transfer leader across cluster
- **Operational Drift**: Move leader to preferred region/cloud
- **Recovery**: Force election if automatic failover stuck

### Leader Transfer API

```zig
const TransferLeadershipArgs = struct {
    target_leader_id: u64, // Node ID of desired new leader
    timeout_ms: u64 = 30000, // Max time to wait for transfer
};

const TransferLeadershipResult = struct {
    success: bool,
    message: []const u8,
    old_leader_id: u64,
    new_leader_id: u64,
};
```

### Transfer Protocol

```
Current Leader (L)          Target Leader (T)           Other Followers
     │                            │                            │
     │  TransferLeadership(T)     │                            │
     │────────────────────────────│                            │
     │                            │                            │
     │  Check: T has all logs     │                            │
     │  Wait for T to catch up    │                            │
     │  (if needed)               │                            │
     │  ────────────────────────>│                            │
     │                            │                            │
     │  Timeout: L stops sending   │                            │
     │  heartbeats                 │                            │
     │                            │                            │
     │  T starts election         │                            │
     │  (higher term guaranteed)  │                            │
     │  ───────────────────────────────────────────────────────>│
     │                            │                            │
     │                            │  RequestVote               │
     │                            │<───────────────────────────│
     │                            │                            │
     │                            │  Vote granted              │
     │                            │────────────────────────────>│
     │                            │                            │
     │  T becomes leader          │                            │
     │  L becomes follower        │                            │
     │<────────────────────────────│                            │
     │                            │                            │
```

### Safety Properties

**Log Transfer**: Current leader ensures target has all committed logs before timing out.

**Term Bump**: Target starts election with higher term, guaranteeing election win.

**No Split-Brain**: Old leader steps down before new leader takes over (no overlap).

## Leader Transfer

### Planned Leadership Transfer

**Scenario**: Move leader from Node 1 to Node 2

**Steps**:
1. Verify Node 2 is healthy and up-to-date
2. If Node 2 is behind, replicate missing entries
3. Node 1 sends `TransferLeadership` to Node 2
4. Node 1 stops sending heartbeats, steps down
5. Node 2 starts election, becomes leader
6. Clients discover new leader via API

**Timeout Handling**:
- If Node 2 doesn't become leader within timeout, Node 1 resumes leadership
- Prevents permanent leaderlessness if transfer fails

### Emergency Leadership Transfer

**Scenario**: Force transfer even if target not fully caught up

**Risk**: Target may not have all committed entries, requires truncation on old leader

**API**:
```zig
const EmergencyTransferArgs = struct {
    target_leader_id: u64,
    force: bool = true, // Bypass log consistency check
};
```

**Use with Caution**: Can lead to data loss if old leader had unreplicated commits

## Split-Brain Prevention

### Root Causes

- **Network Partition**: Cluster splits into minority/majority components
- **Clock Skew**: Nodes disagree on term numbers
- **Duplicate Votes**: Bug in vote granting logic
- **Manual Intervention**: Operator incorrectly forces leadership

### Prevention Mechanisms

**1. Quorum Requirement**:
- Majority vote required for election
- Both partitions can't achieve majority simultaneously
- Example: 5-node cluster, partition 3-2 → only 3-node side can elect

**2. Term Monotonicity**:
- Term only increases, never decreases
- Higher term always wins
- Prevents old leader from "reclaiming" leadership

**3. Lease Mechanism** (optional enhancement):
- Leader renews lease with quorum every heartbeat interval
- If lease expires, leader steps down
- Prevents stale leader from serving writes

**4. External Coordination** (for critical deployments):
- Use distributed lock service (etcd, ZooKeeper)
- Leader must hold lock to serve writes
- Eliminates split-brain at cost of external dependency

### Split-Brain Detection

**Symptoms**:
- Two nodes claiming leadership with different terms
- Clients observing divergent data
- Metrics showing multiple leaders

**Detection**:
```zig
fn detectSplitBrain(cluster: []const NodeInfo) bool {
    var leaders: std.ArrayList(LeaderInfo) = init();
    for (cluster) |node| {
        const info = rpc.getStatus(node.address) catch continue;
        if (info.state == .Leader) {
            leaders.append(info);
        }
    }
    return leaders.items.len > 1;
}
```

**Recovery**:
1. Identify higher-term leader (legitimate)
2. Lower-term leader steps down immediately
3. Lower-term leader truncates uncommitted log entries
4. Lower-term leader rejoins cluster as follower

## Implementation Phases

### Phase 1: Core Election (Weeks 1-2)

**Deliverables**:
- [ ] Raft RequestVote implementation
- [ ] Candidate state machine
- [ ] Vote granting logic with log comparison
- [ ] Randomized election timeout
- [ ] Basic election tests (3-node cluster)

**Success Criteria**:
- Single leader elected per term
- Election completes within 300ms (single round)
- Vote safety: Only candidate with up-to-date log wins

### Phase 2: Failover Detection (Weeks 3-4)

**Deliverables**:
- [ ] Leader liveness monitoring (heartbeat timeout)
- [ ] Participant health tracking
- [ ] Failure alerts and metrics
- [ ] Client leader discovery API
- [ ] Hardening tests (leader crash, partition)

**Success Criteria**:
- Leader failure detected within 300ms
- Followers automatically start election
- Clients discover new leader within 100ms

### Phase 3: Manual Failover (Weeks 5-6)

**Deliverables**:
- [ ] Leader transfer API
- [ ] Log consistency verification
- [ ] Timeout handling
- [ ] Admin CLI for failover
- [ ] Integration tests (planned transfer)

**Success Criteria**:
- Can transfer leadership without data loss
- Transfer completes within 5 seconds
- Failed transfer recovers gracefully

### Phase 4: Observability (Week 7)

**Deliverables**:
- [ ] Election metrics (count, duration,成功率)
- [ ] Failover metrics (trigger, duration)
- [ ] Leader transfer metrics (count, success rate)
- [ ] Alerting (multiple leaders, failed election)
- [ ] Dashboard visualization

**Success Criteria**:
- All elections logged with term, candidates, votes
- Failed elections trigger alerts
- Operators can trace election timeline

### Phase 5: Production Hardening (Weeks 8-9)

**Deliverables**:
- [ ] Chaos engineering (random failures, partitions)
- [ ] Load testing during elections
- [ ] Split-brain detection and recovery
- [ ] Long-running stability tests
- [ ] Documentation and runbooks

**Success Criteria**:
- 99.9% of elections succeed within 1 second
- No split-brain in 1000+ chaos iterations
- Cluster remains available during single-node failure

## Integration Points

### Existing Infrastructure

| Component | Integration |
|-----------|-------------|
| **Raft Core** (`src/consensus/raft.zig`) | Election protocol, vote granting |
| **RPC Layer** (`src/consensus/rpc.zig`) | RequestVote/AppendEntries transport |
| **Health Monitor** (`src/health/monitor.zig`) | Liveness tracking, failure detection |
| **Metrics** (`src/metrics/collector.zig`) | Election/failover metrics |

### New Components

| Component | Responsibility |
|-----------|---------------|
| **Election Driver** (`src/consensus/election.zig`) | Election state machine, timeout management |
| **Failover Manager** (`src/consensus/failover.zig`) | Automated failover orchestration |
| **Transfer Handler** (`src/consensus/transfer.zig`) | Manual leadership transfer |
| **Split-Brain Detector** (`src/consensus/splitbrain.zig`) | Detect and resolve split-brain |

### Configuration

```zig
const ElectionConfig = struct {
    // Timing
    election_timeout_min_ms: u64 = 150,
    election_timeout_max_ms: u64 = 300,
    heartbeat_interval_ms: u64 = 50,

    // Failover
    enable_auto_failover: bool = true,
    failover_detection_timeout_ms: u64 = 300,

    // Leader transfer
    transfer_timeout_ms: u64 = 30000,
    transfer_log_sync: bool = true, // Wait for log sync before transfer

    // Split-brain prevention
    enable_lease: bool = false, // Optional lease mechanism
    lease_renewal_interval_ms: u64 = 50,

    // Priority (optional)
    enable_priority: bool = false,
    node_priority: u8 = 0, // Higher = preferred
};
```

## Benchmark Targets

| Benchmark | Target | Notes |
|-----------|--------|-------|
| Election Time (Single Round) | < 300ms p99 | 3-node cluster, same region |
| Election Time (With Retry) | < 600ms p99 | Two rounds needed |
| Failover Detection | < 300ms | Leader crash detection |
| Client Leader Discovery | < 100ms | Query cluster for leader |
| Leader Transfer | < 5 seconds | Planned transfer, log sync |
| Unavailability Window | < 500ms | Time between leader failure and new leader |

## Failure Scenarios

### Scenario 1: Leader Crash

```
Initial:  [Leader L1]──[Follower L2]──[Follower L3]

Failure:  L1 crashes (process killed)

Detection: L2, L3 detect heartbeat timeout (150-300ms)

Election:  L2, L3 transition to Candidate
           L2 wins election (arbitrary but deterministic)

Recovery:  L2 sends heartbeats to L1, L3
           L3 acknowledges, becomes follower
           L1 (if recovered) discovers higher term, becomes follower

Result:    L2 is new leader, cluster stable
```

### Scenario 2: Network Partition

```
Initial:  [L1]──[L2]──[L3]──[L4]──[L5]

Partition: ──X──  (L1, L2 separated from L3, L4, L5)

Minority:  L1, L2 (can't achieve majority)
           - L1 continues as leader but can't commit
           - L2 times out, starts election
           - Neither can win (no quorum)

Majority:   L3, L4, L5
           - L3 wins election, becomes leader
           - L4, L5 follow L3

Healing:   Partition restored
           - L1, L2 discover higher term (L3)
           - L1, L2 become followers, truncate uncommitted entries
           - Cluster unified under L3

Result:    No split-brain, majority partition available
```

### Scenario 3: Leader Hang

```
Initial:  [Leader L1]──[Follower L2]──[Follower L3]

Failure:  L1 enters infinite loop (CPU deadlock)

Detection: L2, L3 detect heartbeat timeout (L1 not sending)

Election:  L2, L3 start election
           L2 wins, becomes leader

Conflict:  L1 wakes up, sends stale heartbeats (old term)

Resolution: L2, L3 reject stale heartbeats (term mismatch)
            L1 discovers higher term, steps down

Result:    L2 is leader, L1 demoted to follower
```

## Security Considerations

### Transport Security

- **TLS 1.3** for all election RPC traffic
- Certificate-based node authentication
- Network isolation (VPC, private subnets)

### Access Control

- Admin API for manual failover requires authentication
- Operator audit logging for all manual interventions
- Role-based access: operators can trigger failover, clients cannot

### DoS Protection

- Rate limiting on RequestVote (prevent election spam)
- Exponential backoff on repeated election failures
- Circuit breaker for failing nodes

## Observability

### Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `election_count` | Counter | Total elections initiated |
| `election_duration_ms` | Histogram | Time from election start to leader established |
| `election_success_rate` | Gauge | Percentage of elections that succeeded |
| `failover_count` | Counter | Total failovers triggered |
| `leader_transfer_count` | Counter | Total manual leader transfers |
| `split_brain_detected` | Counter | Split-brain events detected |
| `current_leader_id` | Gauge | Current leader node ID |
| `current_term` | Gauge | Current Raft term |

### Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| `election_failed` | Election success rate < 90% (5min) | Warning |
| `multiple_leaders` | Split-brain detected | Critical |
| `leader_unavailable` | No leader for > 30 seconds | Critical |
| `failover_rate_high` | > 5 failovers per hour | Warning |

### Logging

Every election event logged with:
- Term number
- Candidate IDs
- Vote breakdown (who voted for whom)
- Election duration
- Result (success/failure)

## Future Work (Post-v1.0)

1. **Priority-Based Elections**: Prefer nodes by region, capacity, or latency
2. **Lease-Based Safety**: Leader lease with automatic expiration
3. **Pre-Vote**: Prevent disconnected nodes from disrupting cluster
4. **Witness Nodes**: Low-cost voting-only nodes for edge deployments
5. **Multi-Region Elections**: Latency-aware leader placement

## Appendix

### A. State Machine Diagram

```
┌─────────────┐     heartbeat      ┌─────────────┐
│  FOLLOWER   │<───────────────────│   LEADER    │
└──────┬──────┘                    └──────┬──────┘
       │                                  │
       │ election timeout                 │ higher term
       ▼                                  ▼
┌─────────────┐     majority     ┌─────────────┐
│  CANDIDATE  │─────────────────>│   LEADER    │
└─────────────┘      votes       └─────────────┘
       │
       │ higher term discovered
       ▼
┌─────────────┐
│  FOLLOWER   │
└─────────────┘
```

### B. Message Sequence (Election)

```
L1 (Leader)     L2 (Follower)    L3 (Follower)    L4 (Follower)    L5 (Follower)
     │                │                 │                 │                 │
     │   [Crashes]    │                 │                 │                 │
     X                │                 │                 │                 │
                      │                 │                 │                 │
                      │  [Timeout]      │                 │                 │
                      ▼                 │                 │                 │
                   CANDIDATE           │                 │                 │
                      │                 │                 │                 │
                      │ RequestVote     │                 │                 │
                      │────────────────────────────────────────────────────>│
                      │                 │                 │                 │
                      │<────────────────────────────────────────────────────│
                      │  Vote YES       │                 │                 │
                      │                 │                 │                 │
                      │ [2/5 votes]     │                 │                 │
                      │ [Not majority]  │                 │                 │
                      │                 │                 │                 │
                      │  [Timeout]      │                 │                 │
                      │  [Retry]        │                 │                 │
                      │                 │                 │                 │
                      │ RequestVote     │                 │                 │
                      │────────────────────────────────────────────────────>│
                      │                 │                 │                 │
                      │<────────────────────────────────────────────────────│
                      │  Vote YES (3)   │ Vote YES (4)    │                 │
                      │                 │                 │                 │
                      │ [3/5 votes]     │                 │                 │
                      │ [Majority!]     │                 │                 │
                      ▼                 │                 │                 │
                   LEADER              │                 │                 │
                      │                 │                 │                 │
                      │  Heartbeat      │                 │                 │
                      │────────────────────────────────────────────────────>│
                      │                 │                 │                 │
                      │                 ▼                 ▼                 ▼
                      │             FOLLOWER         FOLLOWER         FOLLOWER
```

### C. Error Codes

| Code | Name | Description |
|------|------|-------------|
| 4001 | ERR_ELECTION_FAILED | Failed to win election after retries |
| 4002 | ERR_NO_LEADER | No leader elected in cluster |
| 4003 | ERR_LEADER_TRANSFER_FAILED | Leadership transfer timeout |
| 4004 | ERR_SPLIT_BRAIN | Multiple leaders detected |
| 4005 | ERR_TERM_STALE | Attempted to use stale term number |
| 4006 | ERR_VOTE_DENIED | Vote request denied (log behind) |

---

**Document History**:
- 2025-12-30: Initial draft (v1.0)
