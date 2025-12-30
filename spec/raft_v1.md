# Raft Consensus v1.0 Specification

**Status**: Draft
**Version**: 1.0
**Last Updated**: 2025-12-30
**Dependencies**: [replication_v1.md](./replication_v1.md), [commit_record_v0.md](./commit_record_v0.md), [semantics_v0.md](./semantics_v0.md)

## Overview

This specification defines the Raft consensus algorithm integration for NorthstarDB, enabling automatic leader election, log replication consistency, and fault-tolerant failover. Raft transforms the single-primary replication topology into a distributed consensus group.

**Design Philosophy**: Leverage existing commit record infrastructure as Raft's log. The WAL is the Raft log; commit records are Raft log entries. Minimize divergence between standalone and distributed modes.

## Table of Contents

1. [Architecture](#architecture)
2. [Raft State Machine](#raft-state-machine)
3. [Leader Election](#leader-election)
4. [Log Replication](#log-replication)
5. [Safety](#safety)
6. [Configuration Changes](#configuration-changes)
7. [Snapshotting](#snapshotting)
8. [Implementation Phases](#implementation-phases)
9. [Integration Points](#integration-points)

## Architecture

### System Model

```
                    Raft Consensus Group (3 or 5 nodes)
┌─────────────────────────────────────────────────────────────────┐
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐│
│  │ Node 1  │  │ Node 2  │  │ Node 3  │  │ Node 4  │  │ Node 5  ││
│  │ Leader  │  │Follower │  │Follower │  │Follower │  │Follower ││
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘│
│       │            │            │            │            │    │
│       └────────────┴────────────┴────────────┴────────────┘     │
│                         Raft RPC Layer                          │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                     NorthstarDB Storage                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────────────────────┐  │
│  │   WAL    │    │ MVCC     │    │      B+Tree              │  │
│  │ (Raft    │    │ Snapshots│    │      (State Machine)     │  │
│  │  Log)    │    │          │    │                          │  │
│  └──────────┘    └──────────┘    └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **WAL as Raft Log**: The existing WAL (`src/wal.zig`) becomes the Raft log. Each commit record is a Raft log entry with the added `term` and `index` fields.

2. **Leader-Full Consistency**: Only the Raft leader accepts writes. Followers serve read-only queries from their local state machines.

3. **Joint Consensus**: Configuration changes (adding/removing nodes) use the Raft joint consensus approach for safety.

4. **Single-Threaded Raft**: Each node runs Raft logic in a single event loop for simplicity and correctness.

5. **Snapshot-Based Compression**: Instead of truncating the Raft log, we use the existing MVCC snapshot infrastructure to create compact state machine snapshots.

### Node Roles

| Role | Responsibilities | Writes | Reads |
|------|-------------------|--------|-------|
| **Leader** | Accept writes, replicate log, handle heartbeats | Yes | Yes |
| **Follower** | Accept replicated log, serve reads, vote in elections | No | Yes (stale) |
| **Candidate** | Transient role during leader election | No | No |

## Raft State Machine

### Persistent State

```zig
const RaftPersistentState = struct {
    // Current term (increases monotonically)
    current_term: u64,

    // Candidate that received vote in current term
    voted_for: ?u64, // node_id

    // Log entries (index -> entry)
    // Each entry: {term, command: CommitRecord}
    log: std.ArrayList(LogEntry),
};

const LogEntry = struct {
    term: u64,
    index: u64,
    command: CommitRecord,
};
```

### Volatile State

```zig
const RaftVolatileState = struct {
    // Leader-only: index of highest log entry known to be committed
    commit_index: u64 = 0,

    // Leader-only: index of highest log entry applied to state machine
    last_applied: u64 = 0,

    // Leader-only: for each follower, index of next log entry to send
    next_index: std.AutoHashMap(u64, u64),

    // Leader-only: for each follower, highest log entry known to be replicated
    match_index: std.AutoHashMap(u64, u64),
};
```

### Follower Volatile State

```zig
const FollowerState = struct {
    // Index of highest log entry to apply
    commit_index: u64 = 0,
    last_applied: u64 = 0,
};
```

### State Transitions

```
Follower ──election timeout──▶ Candidate ──receives majority votes──▶ Leader
    ▲                            │                                      │
    │                            └─────────discover higher term────────┘
    │                                   or election timeout
    │
    └─────────discover higher term (RequestVote with higher term)
```

## Leader Election

### Election Timeout

- **Randomized**: Each follower randomized timeout in [150ms, 300ms]
- **Jitter**: Prevents vote splitting in partitions
- **Reset**: On receiving valid AppendEntries RPC

### RequestVote RPC

```zig
const RequestVoteArgs = struct {
    term: u64,              // Candidate's term
    candidate_id: u64,       // Candidate requesting vote
    last_log_index: u64,     // Index of candidate's last log entry
    last_log_term: u64,      // Term of candidate's last log entry
};

const RequestVoteReply = struct {
    term: u64,              // Current term (for candidate to update)
    vote_granted: bool,     // True if candidate received vote
};
```

### RequestVote Rules

**Candidate**:
1. Increment `current_term`
2. Vote for self
3. Send RequestVote to all nodes
4. Become leader if receive majority votes

**Follower** (on receiving RequestVote):
```zig
fn requestVote(args: RequestVoteArgs) RequestVoteReply {
    if (args.term < persistent_state.current_term) {
        return .{ .term = persistent_state.current_term, .vote_granted = false };
    }

    if (args.term > persistent_state.current_term) {
        persistent_state.current_term = args.term;
        persistent_state.voted_for = null;
        becomeFollower();
    }

    // Grant vote if:
    // 1. Haven't voted yet OR voted for this candidate
    // 2. Candidate's log is at least as up-to-date as ours
    const log_ok = (args.last_log_term > lastLogTerm()) or
                   (args.last_log_term == lastLogTerm() and args.last_log_index >= lastLogIndex());

    const vote_ok = (persistent_state.voted_for == null) or
                    (persistent_state.voted_for == args.candidate_id);

    if (vote_ok and log_ok) {
        persistent_state.voted_for = args.candidate_id;
        return .{ .term = persistent_state.current_term, .vote_granted = true };
    }

    return .{ .term = persistent_state.current_term, .vote_granted = false };
}
```

### Election Safety

**Property**: At most one leader per term

**Proof**: A node votes for at most one candidate per term. Majority vote ensures split votes cannot both achieve majority.

## Log Replication

### AppendEntries RPC

```zig
const AppendEntriesArgs = struct {
    term: u64,                  // Leader's term
    leader_id: u64,             // Leader's ID (followers can redirect clients)
    prev_log_index: u64,        // Index of log entry immediately preceding new ones
    prev_log_term: u64,         // Term of prev_log_index entry
    entries: []const LogEntry,  // Log entries to store (empty for heartbeat)
    leader_commit: u64,         // Leader's commit_index
};

const AppendEntriesReply = struct {
    term: u64,                  // Current term (for leader to update)
    success: bool,              // True if follower contained entry at prev_log_index
    conflict_index: ?u64 = null, // Optional: hint for log reconciliation
    conflict_term: ?u64 = null,
};
```

### AppendEntries Rules (Follower)

```zig
fn appendEntries(args: AppendEntriesArgs) AppendEntriesReply {
    if (args.term < persistent_state.current_term) {
        return .{ .term = persistent_state.current_term, .success = false };
    }

    if (args.term > persistent_state.current_term) {
        persistent_state.current_term = args.term;
        becomeFollower();
    }

    // Reply false if log doesn't contain prev_log_index entry
    if (args.prev_log_index > 0) {
        if (persistent_state.log.items.len <= args.prev_log_index) {
            return .{ .term = persistent_state.current_term, .success = false };
        }
        if (persistent_state.log.items[args.prev_log_index].term != args.prev_log_term) {
            // Optimized conflict resolution
            const conflict_term = persistent_state.log.items[args.prev_log_index].term;
            const conflict_index = findLastEntryWithTerm(conflict_term);
            return .{
                .term = persistent_state.current_term,
                .success = false,
                .conflict_index = conflict_index,
                .conflict_term = conflict_term,
            };
        }
    }

    // Append new entries
    if (args.entries.len > 0) {
        // If existing entries conflict with new ones, delete existing
        var i: u64 = 0;
        while (i < args.entries.len) : (i += 1) {
            const new_index = args.prev_log_index + 1 + i;
            if (persistent_state.log.items.len > new_index) {
                if (persistent_state.log.items[new_index].term != args.entries[i].term) {
                    // Truncate log from this point
                    persistent_state.log.shrinkRetainingCapacity(new_index);
                    break;
                }
            }
        }
        // Append new entries
        try persistent_state.log.appendSlice(args.entries);
    }

    // Update commit index
    if (args.leader_commit > commit_index) {
        commit_index = @min(args.leader_commit, @as(u64, @intCast(persistent_state.log.items.len - 1)));
    }

    return .{ .term = persistent_state.current_term, .success = true };
}
```

### AppendEntries Rules (Leader)

```zig
fn leaderLoop() !void {
    while (true) {
        // Send heartbeats (empty AppendEntries) to all followers
        for (peers.items) |peer| {
            const next_idx = next_index.get(peer.id) orelse 1;
            const prev_idx = if (next_idx > 1) next_idx - 1 else 0;
            const prev_term = if (prev_idx > 0) persistent_state.log.items[prev_idx].term else 0;

            const args = AppendEntriesArgs{
                .term = persistent_state.current_term,
                .leader_id = node_id,
                .prev_log_index = prev_idx,
                .prev_log_term = prev_term,
                .entries = &[_]LogEntry{}, // Empty for heartbeat
                .leader_commit = commit_index,
            };

            if (try sendRPC(peer, args)) |reply| {
                if (reply.success) {
                    next_index.put(peer.id, next_idx + 1);
                    match_index.put(peer.id, prev_idx);
                } else {
                    // Follower log mismatch, backtrack
                    if (reply.conflict_index) |idx| {
                        next_index.put(peer.id, idx);
                    } else {
                        next_index.put(peer.id, @max(1, next_idx - 1));
                    }
                }
            }
        }

        // Update commit index if majority has replicated
        updateCommitIndex();

        // Apply committed entries to state machine
        applyCommittedEntries();

        std.time.sleep(heartbeat_interval); // 50ms
    }
}

fn updateCommitIndex() void {
    for (persistent_state.log.items[(commit_index + 1)..]) |entry| {
        var replicated_count: u64 = 1; // Count leader

        for (match_index.values()) |idx| {
            if (idx >= entry.index) replicated_count += 1;
        }

        if (replicated_count >= majority) {
            commit_index = entry.index;
        }
    }
}
```

## Safety

### Log Matching Property

**Theorem**: If two logs contain an entry with the same index and term, then all preceding entries are identical.

**Proof**:
1. Leader creates at most one entry per index per term
2. Entries never change position in log
3. AppendEntries consistency check ensures property holds when appending

### Leader Completeness

**Theorem**: If a log entry is committed in a term, it appears in the logs of all leaders for higher terms.

**Proof**: A candidate must have all committed entries to win election (RequestVote log comparison). Therefore, any elected leader has all committed entries.

### State Machine Safety

**Theorem**: If a server has applied a log entry at index `i` to its state machine, no other server will apply a different log entry at index `i`.

**Proof**: Leader only commits entry at index `i` if majority has replicated it. Any future leader must have that entry (Leader Completeness) and cannot overwrite it.

## Configuration Changes

### Cluster Membership

Nodes in Raft cluster:
- **Minimum**: 3 nodes (tolerates 1 failure)
- **Recommended**: 5 nodes (tolerates 2 failures)
- **Maximum**: 7 nodes (beyond this, consensus latency degrades)

### Joint Consensus

Phase 1: **C_old, new** (joint consensus)
- Leader proposes configuration `C_old,new`
- Both old and new configurations must agree
- Log entries replicated to both old and new nodes

Phase 2: **C_new** (new configuration)
- Leader transitions to `C_new`
- Only new configuration required for decisions

```zig
const Configuration = struct {
    nodes: []const u64, // Node IDs
};

const LogEntry = struct {
    term: u64,
    index: u64,
    command: union(enum) {
        normal: CommitRecord,
        config: Configuration,
    },
};
```

### Adding a Node

```
1. New node starts as learner (receives log but doesn't vote)
2. Admin triggers config change: add node to cluster
3. Leader creates joint consensus entry: C_old,new
4. Wait for joint consensus to commit
5. Leader creates new config entry: C_new
6. Wait for new config to commit
7. New node becomes full voting member
```

### Removing a Node

```
1. Admin triggers config change: remove node
2. Leader creates joint consensus entry: C_old,new
3. Wait for joint consensus to commit
4. Leader creates new config entry: C_new
5. Wait for new config to commit
6. Removed node shuts down or becomes learner
```

## Snapshotting

### When to Snapshot

Trigger snapshot when log exceeds threshold:
- `log.len > snapshot_threshold` (default: 10,000 entries)
- OR `log.size_bytes > snapshot_size_threshold` (default: 100MB)

### Snapshot Format

```zig
const Snapshot = struct {
    last_included_index: u64,
    last_included_term: u64,
    config: Configuration, // Latest configuration at snapshot time

    // State machine snapshot (existing MVCC snapshot)
    state_machine: MVCCSnapshot,

    // Checksum for integrity
    checksum: u64,
};
```

### Snapshot Installation

```zig
const InstallSnapshotArgs = struct {
    term: u64,
    leader_id: u64,
    last_included_index: u64,
    last_included_term: u64,
    snapshot: []const u8, // Serialized snapshot data
};

const InstallSnapshotReply = struct {
    term: u64,
};
```

**Follower** (on receiving InstallSnapshot):
1. Create new snapshot file
2. Discard entire log up to `last_included_index`
3. Apply snapshot to state machine
4. Reply with success

**Leader** (on success):
1. Update `next_index` for this follower
2. Continue replication from `last_included_index + 1`

## Implementation Phases

### Phase 1: Core Raft (Weeks 1-3)

**Deliverables**:
- [ ] Raft state machine (Follower, Candidate, Leader)
- [ ] RequestVote RPC implementation
- [ ] AppendEntries RPC implementation
- [ ] Leader election with randomized timeout
- [ ] Basic integration tests (3-node cluster)

**Success Criteria**:
- Leader election completes within 300ms (single election timeout)
- Leader can replicate log entries to followers
- Cluster tolerates single node failure

### Phase 2: Log Replication (Weeks 4-5)

**Deliverables**:
- [ ] Leader append entries to local WAL
- [ ] Leader replicate entries to followers
- [ ] Commit index propagation
- [ ] State machine application (MVCC snapshot updates)
- [ ] Log conflict resolution and backtracking

**Success Criteria**:
- Write committed by majority becomes visible on all nodes
- No divergence in state machines across nodes
- Recovery from network partition reconciles logs correctly

### Phase 3: Snapshotting (Week 6)

**Deliverables**:
- [ ] Snapshot creation from MVCC state
- [ ] InstallSnapshot RPC
- [ ] Log truncation after snapshot
- [ ] Snapshot-based bootstrap for new nodes

**Success Criteria**:
- Snapshot size < 10% of full log for typical workload
- New node can bootstrap from snapshot in < 30 seconds
- Snapshot doesn't affect ongoing replication

### Phase 4: Configuration Changes (Week 7)

**Deliverables**:
- [ ] Joint consensus implementation
- [ ] Add node operation
- [ ] Remove node operation
- [ ] Learner mode (non-voting member)

**Success Criteria**:
- Can add node to 3-node cluster without downtime
- Can remove node from 5-node cluster without downtime
- Configuration changes maintain safety throughout

### Phase 5: Robustness (Weeks 8-9)

**Deliverables**:
- [ ] Hardening tests (network partitions, node crashes)
- [ ] Chaos engineering (random failures, packet loss)
- [ ] Benchmark suite for Raft throughput
- [ ] Performance optimization (batching, pipelining)

**Success Criteria**:
- Cluster tolerates 2 simultaneous node failures (5-node cluster)
- No data loss in any failure scenario
- Raft throughput > 50K commits/sec

## Integration Points

### Existing Infrastructure

| Component | Integration with Raft |
|-----------|----------------------|
| **Commit Record** (`src/commit_record.zig`) | Becomes Raft log entry command. Add `term` and `index` to header. |
| **WAL** (`src/wal.zig`) | Raft log persistence. Append-only, checkpointed via snapshots. |
| **MVCC Snapshots** (`src/mvcc.zig`) | State machine state. Snapshot is Raft snapshot. |
| **Replay Engine** (`src/replay.zig`) | Apply committed log entries to state machine. |

### New Components

| Component | Responsibility |
|-----------|---------------|
| **Raft Core** (`src/consensus/raft.zig`) | Raft state machine, leader election, log replication |
| **RPC Layer** (`src/consensus/rpc.zig`) | Network transport for Raft messages |
| **Configuration** (`src/consensus/config.zig`) | Cluster membership and joint consensus |
| **Snapshot Manager** (`src/consensus/snapshot.zig`) | Create and install snapshots |

### Configuration

```zig
const RaftConfig = struct {
    node_id: u64,                     // This node's ID
    peers: []const NodeInfo,          // Cluster members

    // Timing
    election_timeout_min_ms: u64 = 150,
    election_timeout_max_ms: u64 = 300,
    heartbeat_interval_ms: u64 = 50,

    // Thresholds
    snapshot_entry_threshold: u64 = 10_000,
    snapshot_size_threshold: u64 = 100 * 1024 * 1024, // 100MB

    // Transport
    rpc_listen_address: []const u8, // e.g., "0.0.0.0:7234"
};

const NodeInfo = struct {
    id: u64,
    address: []const u8, // Host:port
};
```

## Benchmark Targets

| Benchmark | Target | Notes |
|-----------|--------|-------|
| Leader Election | < 300ms p99 | Single network round-trip |
| Write Latency (Committed) | < 50ms p99 | Majority replication (2/3 nodes) |
| Write Throughput | > 50K commits/sec | 3-node cluster, same region |
| Read Latency (Follower) | < 10ms p99 | Local read from stale data |
| Snapshot Creation | < 5 sec | 1GB database |
| Snapshot Install | < 30 sec | Network transfer + apply |
| Recovery Time | < 60 sec | Single node failure and rejoin |

## Failure Scenarios

### Network Partition

**Scenario**: 3-node cluster, leader isolated from majority

```
Before:
  [Leader L1]───[Follower L2]───[Follower L3]

Partition:
  [Leader L1]          [Follower L2]───[Follower L3]
  (minority)              majority elects L2
```

**Behavior**:
1. L1 loses contact with L2, L3 (heartbeat timeout)
2. L2 and L3 can communicate, L2 becomes leader in new term
3. L1 (old leader) steps down when discovering higher term
4. No data loss: L2's log contains all committed entries

### Node Crash and Recovery

**Scenario**: Leader crashes, followers elect new leader

```
Before:
  [Leader L1]───[Follower L2]───[Follower L3]

Crash:
  [Leader X]     [Follower L2]───[Follower L3]

Recovery:
  [Follower L1]──[Leader L2]────[Follower L3]
```

**Behavior**:
1. L2 and L3 detect leader failure (heartbeat timeout)
2. L2 and L3 start election, L2 wins (arbitrary but deterministic)
3. L1 recovers, becomes follower, installs snapshot from L2
4. L1 catches up via log replication

### Split Brain Prevention

**Guarantee**: Raft's leader election and log replication ensure at most one leader per term.

**Mechanism**:
- Majority vote required for election
- Leader completeness property ensures new leader has all committed entries
- No two leaders can both claim majority support

## Security Considerations

### Transport Security

- **TLS 1.3** required for all Raft RPC traffic
- Certificate-based authentication between nodes
- Network isolation recommended (VPC, private subnets)

### Access Control

- Only cluster members can participate in consensus
- Admin API for configuration changes (authenticated separately)
- Learner mode for non-voting read replicas

## Future Work (Post-v1.0)

1. **WAL Optimization**: Use Raft log directly as WAL (single write)
2. **Read-Index Optimization**: Safely serve linearizable reads from followers
3. **Pre-Vote**: Prevent disconnected nodes from disrupting cluster
4. **Witness Nodes**: Low-cost voting-only nodes for quorum
5. **Multi-Region Raft**: Cross-datacenter consensus with latency awareness

## Appendix

### A. Raft RPC Summary

| RPC | Direction | Purpose |
|-----|-----------|---------|
| RequestVote | Candidate → All | Solicit votes in election |
| AppendEntries | Leader → All | Replicate log / heartbeat |
| InstallSnapshot | Leader → All | Bootstrap lagging follower |

### B. State Machine Diagram

```
                +------------------+
                |     Follower     |
                +------------------+
                 |  ^              |  ^
                 |  |              |  | (AppendEntries)
                 |  |              |  |
(election      v  |  (higher       v  |
 timeout)         |   term)          |
                +------------------+
                |    Candidate    |
                +------------------+
                 |  ^              |
(majority      v  |  (higher       |
 votes)          |   term)         |
                +------------------+
                |      Leader     |
                +------------------+
```

### C. Error Codes

| Code | Name | Description |
|------|------|-------------|
| 2001 | ERR_RAFT_TERM_MISMATCH | RPC term lower than local term |
| 2002 | ERR_RAFT_LOG_CONFLICT | Follower log conflicts with leader |
| 2003 | ERR_RAFT_NOT_LEADER | Client attempted write on follower |
| 2004 | ERR_RAFT_NO_LEADER | Cluster has no elected leader |
| 2005 | ERR_RAFT_SNAPSHOT_INCOMPATIBLE | Snapshot term/index mismatch |

---

**Document History**:
- 2025-12-30: Initial draft (v1.0)
