# Raft RPC - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-raft-state.md](./10-raft-state.md), [10-raft-overview.md](./10-raft-overview.md)

## Purpose

This specification defines the Remote Procedure Call (RPC) messages used for Raft consensus. All Raft communication is accomplished via these three RPC types, enabling leader election, log replication, and snapshot installation.

## RPC Types

### RequestVote RPC

Invoked by candidates to gather votes during leader election.

### AppendEntries RPC

Invoked by leader to replicate log entries to followers and to act as heartbeat.

### InstallSnapshot RPC

Invoked by leader to send snapshot to a follower that is too far behind.

## Types

### RequestVoteArgs

**Description**: Arguments sent with RequestVote RPC when candidate solicits votes.

**Fields**:
- term: u64 - Candidate's term
- candidate_id: NodeId - Candidate requesting vote
- last_log_index: u64 - Index of candidate's last log entry
- last_log_term: u64 - Term of candidate's last log entry

**Size**: 32 bytes

**Purpose**: Enable follower to determine if candidate's log is at least as up-to-date as follower's log.

### RequestVoteReply

**Description**: Response to RequestVote RPC.

**Fields**:
- term: u64 - Current term (for candidate to update itself)
- vote_granted: bool - True if candidate received vote

**Size**: 9 bytes

**Purpose**: Inform candidate whether vote was granted and provide current term for candidate to update if stale.

### AppendEntriesArgs

**Description**: Arguments sent with AppendEntries RPC (used for both log replication and heartbeat).

**Fields**:
- term: u64 - Leader's term
- leader_id: NodeId - So follower can redirect clients
- prev_log_index: u64 - Index of log entry immediately preceding new ones
- prev_log_term: u64 - Term of prev_log_index entry
- entries: Vec LogEntry - Log entries to store (empty for heartbeat)
- leader_commit: u64 - Leader's commit_index

**Size**: 40 bytes plus variable entries

**Purpose**: Replicate log entries to follower or send heartbeat.

### AppendEntriesReply

**Description**: Response to AppendEntries RPC.

**Fields**:
- term: u64 - Current term (for leader to update itself)
- success: bool - True if follower contained entry at prev_log_index
- conflict_index: Option u64 - Hint for log reconciliation (if success is false)
- conflict_term: Option u64 - Term of conflicting entry (if success is false)

**Size**: 17 bytes plus optional conflict fields

**Purpose**: Inform leader whether append succeeded and provide hints for log conflict resolution.

### InstallSnapshotArgs

**Description**: Arguments sent with InstallSnapshot RPC to send snapshot to follower.

**Fields**:
- term: u64 - Leader's term
- leader_id: NodeId - So follower can redirect clients
- last_included_index: u64 - Snapshot replaces all entries up to this index
- last_included_term: u64 - Term of last_included_index
- offset: u64 - Byte offset where chunk is positioned in snapshot file
- data: Vec u8 - Raw bytes of snapshot chunk (maximum size 1MB)
- done: bool - True if this is the last chunk

**Size**: 41 bytes plus variable data

**Purpose**: Stream snapshot to follower in chunks.

### InstallSnapshotReply

**Description**: Response to InstallSnapshot RPC.

**Fields**:
- term: u64 - Current term (for leader to update itself)

**Size**: 8 bytes

**Purpose**: Acknowledge snapshot chunk receipt and provide current term.

## RPC Handling

### RequestVote RPC Handler

**Invoked when**: Candidate sends RequestVote to solicit votes

**Receiver Algorithm** (follower or candidate):

1. If args.term is less than persistent_state.current_term:
    a. Return reply with term = current_term and vote_granted = false
2. If args.term is greater than persistent_state.current_term:
    a. Update persistent_state.current_term to args.term
    b. Reset persistent_state.voted_for to None
    c. Become follower
    d. Persist state
3. If args.term equals persistent_state.current_term:
    a. If persistent_state.voted_for is None or equal to args.candidate_id:
        i. Check if candidate's log is at least as up-to-date as receiver's log:
            - If args.last_log_term is greater than last_log_term(): Vote granted
            - If args.last_log_term equals last_log_term() and args.last_log_index is greater than or equal to last_log_index(): Vote granted
            - Otherwise: Vote not granted
        ii. If vote granted:
            - Set persistent_state.voted_for to args.candidate_id
            - Persist state
            - Return reply with term = current_term and vote_granted = true
        iii. Otherwise:
            - Return reply with term = current_term and vote_granted = false
    b. If persistent_state.voted_for is Some and not equal to args.candidate_id:
        i. Return reply with term = current_term and vote_granted = false

**Error Conditions**: None - errors returned as reply fields

**Concurrency**: Should be called with persistent state lock held.

### AppendEntries RPC Handler

**Invoked when**: Leader sends AppendEntries to replicate log or send heartbeat

**Receiver Algorithm** (follower):

1. If args.term is less than persistent_state.current_term:
    a. Return reply with term = current_term and success = false
2. If args.term is greater than persistent_state.current_term:
    a. Update persistent_state.current_term to args.term
    b. Become follower
    c. Persist state
3. If args.term equals persistent_state.current_term:
    a. Reply false if log does not contain entry at prev_log_index
    b. If args.prev_log_index is greater than 0:
        i. If persistent_state.log length is less than or equal to args.prev_log_index:
            - Return reply with term = current_term, success = false
            - Set conflict_index to last_log_index() + 1
            - Set conflict_term to 0
        ii. If term at args.prev_log_index does not equal args.prev_log_term:
            - Find last entry in log with term equal to args.prev_log_term
            - Return reply with term = current_term, success = false
            - Set conflict_index to found index
            - Set conflict_term to args.prev_log_term
    c. If existing entries conflict with new entries (same index but different terms):
        i. Delete all entries from conflict index onwards
        ii. Truncate log
    d. Append any new entries not already in log
    e. If args.leader_commit is greater than volatile_state.commit_index:
        i. Set volatile_state.commit_index to minimum of args.leader_commit and index of last new entry
        ii. Trigger log application if entries became commit-able
    f. Return reply with term = current_term and success = true

**Error Conditions**: None - errors returned as reply fields

**Concurrency**: Should be called with persistent state lock held.

### InstallSnapshot RPC Handler

**Invoked when**: Leader sends InstallSnapshot to bootstrap lagging follower

**Receiver Algorithm** (follower):

1. If args.term is less than persistent_state.current_term:
    a. Return reply with term = current_term
2. If args.term is greater than persistent_state.current_term:
    a. Update persistent_state.current_term to args.term
    b. Become follower
3. If args.term equals persistent_state.current_term:
    a. If this is first chunk (offset is 0):
        i. Create new snapshot file
        ii. Initialize snapshot metadata with last_included_index and last_included_term
    b. Append chunk data to snapshot file at offset
    c. If args.done is true:
        i. Validate snapshot checksum
        ii. Apply snapshot to state machine
        iii. Discard entire log up to last_included_index
        iv. Set volatile_state.commit_index to last_included_index
        v. Set volatile_state.last_applied to last_included_index
        vi. If log has entry with same index and term as snapshot, retain log entries after that point
        vii. Otherwise, discard entire log
    d. Return reply with term = current_term

**Error Conditions**:
- ChecksumError: Snapshot checksum validation failed
- IoError: Failed to write snapshot file or apply to state machine

**Concurrency**: Should be called with persistent state lock held.

## RPC Timeout Handling

### RequestVote Timeout

**Timeout**: RPC timeout configured in RaftConfig (default: 1000ms)

**Behavior on timeout**:
- Candidate assumes RPC lost
- Candidate retries sending RequestVote to same peer
- No change in candidate state

### AppendEntries Timeout

**Timeout**: RPC timeout configured in RaftConfig (default: 1000ms)

**Behavior on timeout**:
- Leader assumes RPC lost or follower unreachable
- Leader retries sending AppendEntries to same follower
- Leader decrements next_index for follower (optimistic backtracking)
- No change in leader state

### InstallSnapshot Timeout

**Timeout**: RPC timeout configured in RaftConfig (default: 10000ms, larger due to larger payload)

**Behavior on timeout**:
- Leader assumes RPC lost or follower unable to receive snapshot
- Leader restarts InstallSnapshot from beginning
- No change in leader state

## RPC Optimization

### Conflict Hints

AppendEntriesReply includes conflict_index and conflict_term to optimize log reconciliation:

1. When follower detects log mismatch, it finds the most recent conflicting entry
2. Follower sends conflict_index (position of conflict) and conflict_term (term at that position)
3. Leader uses conflict_term to quickly find the last entry with that term in its log
4. Leader sets next_index for follower to that position + 1
5. This reduces number of round-trips for reconciliation from O(N) to O(log N)

### Batch Replication

Leader batches log entries in single AppendEntries RPC:

1. Leader accumulates entries proposed since last AppendEntries
2. Leader sends batch when:
    a. Batch size reaches maximum (default: 100 entries)
    b. Heartbeat interval elapsed (default: 50ms)
    c. No new entries expected (idle)
3. Follower processes entire batch atomically

### Pipelining

Leader pipelines RPCs to followers for higher throughput:

1. Leader sends multiple AppendEntries RPCs without waiting for replies
2. Leader maintains sliding window of unacknowledged RPCs
3. When reply received, leader advances window
4. Window size limited to prevent overwhelming follower

## Rust Implementation Guidance

### RPC Definitions

Use tarpc for async RPC:

```rust
#[tarpc::service]
pub trait RaftRpc {
    async fn request_vote(args: RequestVoteArgs) -> RequestVoteReply;
    async fn append_entries(args: AppendEntriesArgs) -> AppendEntriesReply;
    async fn install_snapshot(args: InstallSnapshotArgs) -> InstallSnapshotReply;
}
```

### Struct Definitions

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestVoteArgs {
    pub term: u64,
    pub candidate_id: NodeId,
    pub last_log_index: u64,
    pub last_log_term: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestVoteReply {
    pub term: u64,
    pub vote_granted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppendEntriesArgs {
    pub term: u64,
    pub leader_id: NodeId,
    pub prev_log_index: u64,
    pub prev_log_term: u64,
    pub entries: Vec<LogEntry>,
    pub leader_commit: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppendEntriesReply {
    pub term: u64,
    pub success: bool,
    pub conflict_index: Option<u64>,
    pub conflict_term: Option<u64>,
}
```

### RPC Client

Use connection pool for efficient RPC:

```rust
pub struct RaftRpcClient {
    client: tarpc::rpc::Client,
}

impl RaftRpcClient {
    pub async fn request_vote(&self, args: RequestVoteArgs) -> Result<RequestVoteReply> {
        timeout(Duration::from_millis(self.config.rpc_timeout_ms), self.client.request_vote(args)).await?
    }
}
```

### RPC Server

Use tokio for async RPC server:

```rust`
pub struct RaftRpcServer {
    raft: Arc<RaftCore>,
}

impl RaftRpc for RaftRpcServer {
    async fn request_vote(self, _: context::Context, args: RequestVoteArgs) -> RequestVoteReply {
        self raft.handle_request_vote(args)
    }
}
```

### Error Handling

Define RPC-specific error types:

```rust
#[derive(Debug, thiserror::Error)]
pub enum RpcError {
    #[error("RPC timeout: {0}")]
    Timeout(String),

    #[error("RPC connection failed: {0}")]
    ConnectionFailed(String),

    #[error("RPC serialization error: {0}")]
    Serialization(String),
}
```

## Testing Strategy

Unit tests:
- Serialize and deserialize all RPC types
- Validate RPC argument fields
- Test timeout handling

Integration tests:
- End-to-end RPC communication
- RequestVote with various log states
- AppendEntries with log conflicts
- InstallSnapshot chunking

Property-based tests:
- All RPC types serialize and deserialize correctly
- RPC timeout always triggers retry
- Conflict hints always point to valid index
