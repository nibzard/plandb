# Raft Consensus Overview - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-replication-overview.md](./10-replication-overview.md)
**Related**: [raft_v1.md](./raft_v1.md) - Zig implementation reference

## Purpose

This specification defines the Raft consensus algorithm integration for NorthstarDB in Rust, enabling automatic leader election, log replication consistency, and fault-tolerant failover. Raft transforms the single-primary replication topology into a distributed consensus group.

## Design Philosophy

The WAL is the Raft log. Every commit record is a Raft log entry. We minimize divergence between standalone and distributed modes by leveraging existing infrastructure:
- WAL becomes Raft log persistence
- Commit records become Raft log entry commands
- MVCC snapshots become Raft snapshots

## System Model

### Raft Consensus Group

A cluster of 3 to 7 nodes participating in consensus:
- Minimum 3 nodes (tolerates 1 failure)
- Recommended 5 nodes (tolerates 2 failures)
- Maximum 7 nodes (beyond this, consensus latency degrades)

### Node Roles

| Role | Responsibilities | Writes | Reads |
|------|-------------------|--------|-------|
| Leader | Accept writes, replicate log, handle heartbeats | Yes | Yes |
| Follower | Accept replicated log, serve reads, vote in elections | No | Yes (stale) |
| Candidate | Transient role during leader election | No | No |

### Key Design Decisions

1. **WAL as Raft Log**: The existing WAL becomes the Raft log. Each commit record is a Raft log entry with term and index fields added.

2. **Leader-Full Consistency**: Only the Raft leader accepts writes. Followers serve read-only queries from their local state machines.

3. **Joint Consensus**: Configuration changes use the Raft joint consensus approach for safety when adding or removing nodes.

4. **Single-Threaded Raft**: Each node runs Raft logic in a single event loop for simplicity and correctness.

5. **Snapshot-Based Compression**: Use existing MVCC snapshot infrastructure to create compact state machine snapshots and truncate the Raft log.

## Architecture

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

## Types

### NodeId

**Description**: Unique identifier for a node in the Raft cluster.

**Type**: u64

**Properties**:
- Must be unique across all nodes in cluster
- Assigned at configuration time
- Does not change during node lifetime

**Invariants**: NodeId must be greater than zero. No two nodes share the same NodeId.

### Term

**Description**: Raft term number, acts as a logical clock for the cluster.

**Type**: u64

**Properties**:
- Starts at zero
- Increments monotonically
- Changes on leader election
- Used for ordering and staleness detection

**Invariants**: Term is monotonically increasing. Higher term is more recent.

### LogIndex

**Description**: Index of a log entry in the Raft log.

**Type**: u64

**Properties**:
- Starts at zero
- Increments by one for each log entry
- Unique per entry within a term
- Used for log matching and consistency checks

**Invariants**: LogIndex is monotonically increasing within a log.

### ServerState

**Description**: Current state of a Raft node in the consensus protocol.

**Variants**:
- Follower: Node is following the leader, accepting replicated log entries
- Candidate: Node is campaigning for leadership, soliciting votes
- Leader: Node is the cluster leader, accepting writes and replicating log

**Transitions**:
- Follower to Candidate: On election timeout
- Candidate to Leader: On receiving majority of votes
- Candidate to Follower: On discovering higher term
- Leader to Follower: On discovering higher term

### RaftConfig

**Description**: Configuration for Raft consensus operation.

**Fields**:
- node_id: NodeId - Unique identifier for this node
- peers: Vec NodeInfo - Other nodes in the cluster
- election_timeout_min_ms: u64 - Minimum election timeout in milliseconds (default: 150, range: 50-500)
- election_timeout_max_ms: u64 - Maximum election timeout in milliseconds (default: 300, range: 100-1000)
- heartbeat_interval_ms: u64 - Interval between heartbeats in milliseconds (default: 50, range: 10-200)
- snapshot_entry_threshold: u64 - Log entries threshold before snapshot (default: 10000, range: 1000-100000)
- snapshot_size_threshold: u64 - Log size threshold in bytes before snapshot (default: 104857600, range: 1048576-1073741824)
- rpc_listen_address: String - Network address for RPC (e.g., "0.0.0.0:7234")
- rpc_timeout_ms: u64 - RPC timeout in milliseconds (default: 1000, range: 100-10000)

**Invariants**:
- election_timeout_min_ms must be less than election_timeout_max_ms
- election_timeout_min_ms must be much greater than heartbeat_interval_ms (recommended 3x ratio)
- Cluster size (node_id plus peers length) must be odd number between 3 and 7

### NodeInfo

**Description**: Information about a peer node in the cluster.

**Fields**:
- id: NodeId - Unique identifier for this node
- address: String - Network address for RPC (host:port)

**Invariants**: id must be unique across cluster. address must be resolvable.

### RaftCore

**Description**: Main Raft consensus instance managing all protocol state and operations.

**Fields**:
- config: Arc RaftConfig - Configuration for this Raft instance
- state: Arc Atomic ServerState - Current server state (Follower, Candidate, Leader)
- persistent_state: Arc RwLock PersistentState - Persistent Raft state
- volatile_state: Arc RwLock VolatileState - Volatile state for leader
- follower_state: Arc RwLock FollowerState - Volatile state for follower
- current_term: Arc AtomicU64 - Current term (cached for performance)
- voted_for: Arc Atomic Option NodeId - Who we voted for in current term
- commit_index: Arc AtomicU64 - Index of highest committed log entry
- last_applied: Arc AtomicU64 - Index of highest applied log entry
- rpc_server: Option RaftRpcServer - RPC server instance
- rpc_clients: HashMap NodeId, RaftRpcClient - RPC clients for each peer
- election_timer: Option JoinHandle - Background election timer task
- heartbeat_timer: Option JoinHandle - Background heartbeat task (leader only)
- apply_task: Option JoinHandle - Background log application task
- running: Arc AtomicBool - Flag indicating Raft is running
- event_sender: mpsc Sender RaftEvent - Channel for Raft events

**Invariants**: Only one of volatile_state or follower_state is active depending on server state.

### RaftEvent

**Description**: Events emitted by Raft for monitoring and observability.

**Variants**:
- TermChanged: Term number changed (old_term, new_term)
- StateChanged: Server state changed (old_state, new_state)
- LeaderElected: New leader elected (term, leader_id)
- LogCommitted: Log entry committed (index, term)
- SnapshotCreated: Snapshot created (last_included_index, last_included_term)
- PeerAdded: New peer added to cluster (peer_id)
- PeerRemoved: Peer removed from cluster (peer_id)
- ElectionTimeout: Election timeout occurred
- VoteRequested: Vote requested by candidate (candidate_id, term)
- VoteGranted: Vote granted to candidate (candidate_id, term)
- VoteRejected: Vote rejected for candidate (candidate_id, term, reason)

## Functions

### RaftCore::new(config: RaftConfig) -> Result RaftCore

**Purpose**: Create a new Raft consensus instance.

**Parameters**:
- config: RaftConfig - Configuration for Raft operation

**Returns**: Result wrapping RaftCore instance

**Algorithm**:
1. Validate configuration (cluster size, timeouts)
2. Load or initialize persistent state from disk
3. Initialize volatile state structures
4. Create RPC server and clients for each peer
5. Set initial state to Follower
6. Initialize current_term to zero or loaded from persistent state
7. Return RaftCore instance

**Error Conditions**:
- ConfigError: Invalid configuration parameters
- IoError: Failed to load persistent state
- RpcError: Failed to create RPC server or clients

**Concurrency**: Thread-safe via Arc and atomics.

### RaftCore::start(&self) -> Result

**Purpose**: Start the Raft consensus instance and begin participation in cluster.

**Algorithm**:
1. Set running flag to true
2. Start RPC server to accept incoming RPCs
3. Spawn background election timer task
4. Spawn background log application task
5. Convert to Follower state if not already
6. Return success

**Error Conditions**:
- IoError: Failed to start RPC server or background tasks
- RaftError: Failed to initialize state

**Concurrency**: Should be called once when starting node.

### RaftCore::step_down(&self, new_term: u64)

**Purpose**: Step down from leadership or candidacy when discovering a higher term.

**Parameters**:
- new_term: u64 - Higher term that caused step down

**Algorithm**:
1. Update current_term to new_term
2. Reset voted_for to None
3. Persist current_term and voted_for to disk
4. Transition state to Follower
5. If leader, stop heartbeat timer
6. Emit StateChanged event
7. Emit TermChanged event

**Concurrency**: Safe to call from any thread when higher term discovered.

### RaftCore::become_candidate(&self) -> Result

**Purpose**: Transition to Candidate state and start leader election.

**Algorithm**:
1. Check running flag, return error if not running
2. Increment current_term
3. Vote for self (set voted_for to own node_id)
4. Persist current_term and voted_for to disk
5. Transition state to Candidate
6. Reset election timer with new random timeout
7. Send RequestVote RPC to all peers
8. Emit StateChanged event
9. Emit VoteRequested event (self)
10. Return success

**Error Conditions**:
- NotRunningError: Raft instance not running
- IoError: Failed to persist state or send RPCs

**Concurrency**: Called from election timer task.

### RaftCore::become_leader(&self) -> Result

**Purpose**: Transition to Leader state after winning election.

**Algorithm**:
1. Check running flag, return error if not running
2. Transition state to Leader
3. Initialize leader volatile state:
    a. Set next_index for each peer to (last_log_index + 1)
    b. Set match_index for each peer to zero
4. Start heartbeat timer
5. Immediately send empty AppendEntries (heartbeat) to all peers
6. Emit StateChanged event
7. Emit LeaderElected event
8. Return success

**Error Conditions**:
- NotRunningError: Raft instance not running
- IoError: Failed to start heartbeat timer or send heartbeats

**Concurrency**: Called when majority of votes received.

### RaftCore::propose(&self, command: CommitRecord) -> Result

**Purpose**: Propose a new command (commit record) to the Raft log.

**Parameters**:
- command: CommitRecord - Command to replicate

**Returns**: Result wrapping log index where command was appended

**Algorithm**:
1. Check state is Leader, return error if not
2. Append entry to local log with current_term and next index
3. Persist log entry to WAL
4. Send AppendEntries RPC to all peers with new entry
5. Wait for entry to be committed (update_commit_index called)
6. Return log index

**Error Conditions**:
- NotLeaderError: This node is not the leader
- IoError: Failed to append to log or send RPCs

**Concurrency**: Called by client write transactions.

### RaftCore::shutdown(&self) -> Result

**Purpose**: Gracefully shutdown the Raft consensus instance.

**Algorithm**:
1. Set running flag to false
2. Stop election timer
3. Stop heartbeat timer (if leader)
4. Stop log application task
5. Stop RPC server
6. Persist current state to disk
7. Return success

**Error Conditions**: None - shutdown is best-effort

**Concurrency**: Should be called once when shutting down node.

## State Machine

### Follower State

**Responsiveness**: Responds to RPCs from candidates and leaders

**Timeouts**: Election timeout (randomized between min and max)

**Transitions**:
- To Candidate: On election timeout (no recent AppendEntries or heartbeat)
- To Follower: On discovering higher term

### Candidate State

**Responsiveness**: Campaigns for election, solicits votes

**Timeouts**: Election timeout (randomized between min and max)

**Transitions**:
- To Leader: On receiving majority of votes
- To Follower: On discovering higher term or on election timeout

### Leader State

**Responsiveness**: Accepts client proposals, replicates log to followers

**Timeouts**: Heartbeat interval (much shorter than election timeout)

**Transitions**:
- To Follower: On discovering higher term

## Safety Properties

### Election Safety

At most one leader can be elected for a given term.

**Proof**: A node votes for at most one candidate per term. Majority vote ensures split votes cannot both achieve majority.

### Log Matching Property

If two logs contain an entry with the same index and term, then all preceding entries are identical.

**Proof**: Leader creates at most one entry per index per term. Entries never change position in log. AppendEntries consistency check ensures property holds when appending.

### Leader Completeness

If a log entry is committed in a term, it appears in the logs of all leaders for higher terms.

**Proof**: A candidate must have all committed entries to win election (RequestVote log comparison). Therefore, any elected leader has all committed entries.

### State Machine Safety

If a server has applied a log entry at index to its state machine, no other server will apply a different log entry at index.

**Proof**: Leader only commits entry at index if majority has replicated it. Any future leader must have that entry (Leader Completeness) and cannot overwrite it.

## Integration Points

### Existing Infrastructure

| Component | Usage in Raft |
|-----------|---------------|
| Commit Record | Becomes Raft log entry command. Add term and index to header. |
| WAL | Raft log persistence. Append-only, checkpointed via snapshots. |
| MVCC Snapshots | State machine state. Snapshot is Raft snapshot. |
| Replay Engine | Apply committed log entries to state machine. |

### New Components

| Component | Responsibility |
|-----------|---------------|
| Raft Core | Raft state machine, leader election, log replication |
| RPC Layer | Network transport for Raft messages |
| Configuration | Cluster membership and joint consensus |
| Snapshot Manager | Create and install snapshots |

## Rust Implementation Guidance

### Module Structure

```
northstar-consensus/
├── src/
│   ├── lib.rs              # Public API exports
│   ├── raft.rs             # Raft core implementation
│   ├── state.rs            # Raft state types and management
│   ├── rpc.rs              # RPC layer and message types
│   ├── log.rs              # Raft log management
│   ├── snapshot.rs         # Snapshot creation and installation
│   ├── config.rs           # Configuration types
│   └── election.rs         # Leader election logic
├── Cargo.toml
```

### Concurrency Model

Use tokio for async I/O and Arc for shared state:

```rust
pub struct RaftCore {
    config: Arc<RaftConfig>,
    state: Arc<AtomicU8>, // Using u8 for ServerState
    current_term: Arc<AtomicU64>,
    voted_for: Arc<AtomicU64>, // Using 0 for None, node_id otherwise
    commit_index: Arc<AtomicU64>,
    last_applied: Arc<AtomicU64>,
    running: Arc<AtomicBool>,
}
```

### Timer Management

Use tokio time for randomized election timeout:

```rust
let timeout = random_range(config.election_timeout_min_ms, config.election_timeout_max_ms);
tokio::time::sleep(Duration::from_millis(timeout)).await;
```

### RPC Handling

Use tarpc for typed RPC:

```rust
#[tarpc::service]
pub trait RaftRpc {
    async fn request_vote(args: RequestVoteArgs) -> RequestVoteReply;
    async fn append_entries(args: AppendEntriesArgs) -> AppendEntriesReply;
    async fn install_snapshot(args: InstallSnapshotArgs) -> InstallSnapshotReply;
}
```

## Monitoring and Observability

### Key Metrics

| Metric | Type | Description |
|--------|------|-------------|
| raft_current_term | Gauge | Current term number |
| raft_state | Gauge | Current server state (0=Follower, 1=Candidate, 2=Leader) |
| raft_commit_index | Gauge | Index of highest committed log entry |
| raft_last_applied | Gauge | Index of highest applied log entry |
| raft_leader_elections_total | Counter | Total number of leader elections |
| raft_vote_requests_total | Counter | Total vote requests received |
| raft_log_size_bytes | Gauge | Size of Raft log in bytes |
| raft_log_entries_total | Gauge | Total number of log entries |

### Health Checks

Raft node is healthy if:
- State is Follower or Leader (not stuck in Candidate)
- Leader elected (no leader for more than 1 minute)
- Commit index advancing
- Replication lag within acceptable range

## Benchmark Targets

| Benchmark | Target | Notes |
|-----------|--------|-------|
| Leader Election | Less than 300ms P99 | Single network round-trip |
| Write Latency (Committed) | Less than 50ms P99 | Majority replication (2/3 nodes) |
| Write Throughput | Greater than 50K commits/sec | 3-node cluster, same region |
| Read Latency (Follower) | Less than 10ms P99 | Local read from stale data |
| Snapshot Creation | Less than 5 seconds | 1GB database |
| Snapshot Install | Less than 30 seconds | Network transfer plus apply |
| Recovery Time | Less than 60 seconds | Single node failure and rejoin |
