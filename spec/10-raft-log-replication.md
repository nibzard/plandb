# Raft Log Replication - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-raft-state.md](./10-raft-state.md), [10-raft-rpc.md](./10-raft-rpc.md)

## Purpose

This specification defines the log replication mechanism for Raft consensus. Once a leader is elected, it accepts client requests and replicates log entries to followers using AppendEntries RPC.

## Replication Overview

1. Leader receives client command (commit record)
2. Leader appends command to local log with current_term and next index
3. Leader sends AppendEntries RPC to all followers with new entry
4. Followers append entry to local logs
5. Leader waits for entry to be committed (majority replication)
6. Leader applies committed entry to state machine
7. Leader responds to client

## Types

### ReplicationState

**Description**: Per-follower replication state tracking.

**Fields**:
- next_index: u64 - Index of next log entry to send to this follower
- match_index: u64 - Index of highest log entry known to be replicated on this follower
- inflight_rpcs: Vec InflightRpc - RPCs sent but not yet acknowledged
- last_send: Instant - When last AppendEntries was sent
- last_heartbeat: Instant - When last heartbeat was sent

**Invariants**: match_index is less than next_index.

### InflightRpc

**Description**: Tracks AppendEntries RPC sent but not yet acknowledged.

**Fields**:
- sequence: u64 - RPC sequence number
- entries: Vec LogEntry - Entries in this RPC
- sent: Instant - When RPC was sent

## Functions

### replicate_entry(&self, entry: LogEntry) -> Result

**Purpose**: Replicate a new log entry to all followers.

**Parameters**:
- entry: LogEntry - Entry to replicate

**Returns**: Empty Result on success

**Algorithm**:
1. Check if state is Leader, return error if not
2. Append entry to local log (persistent_state.log.push(entry))
3. Persist log to WAL
4. For each follower:
    a. Add entry to replication buffer for that follower
    b. If buffer size reaches batch limit or heartbeat interval elapsed:
        i. Send AppendEntries RPC with buffered entries
        ii. Record in inflight_rpcs
5. Return success

**Error Conditions**:
- NotLeaderError: Not the leader
- IoError: Failed to append to log or send RPCs

**Concurrency**: Called by client write transactions.

### send_append_entries(&self, follower_id: NodeId)

**Purpose**: Send AppendEntries RPC to specific follower.

**Parameters**:
- follower_id: NodeId - Follower to send to

**Algorithm**:
1. Get replication_state for follower
2. Get next_index for follower
3. Determine entries to send:
    a. If next_index is greater than last_log_index(), send empty heartbeat
    b. Otherwise, send entries from next_index to last_log_index()
4. Create AppendEntriesArgs:
    a. term = current_term
    b. leader_id = own node_id
    c. prev_log_index = next_index - 1
    d. prev_log_term = term at prev_log_index (or 0 if prev_log_index is 0)
    e. entries = determined entries
    f. leader_commit = commit_index
5. Send RPC to follower
6. Update replication_state.last_send to current time
7. Add to inflight_rpcs

**Concurrency**: Called from heartbeat task or after entry replication.

### handle_append_entries_reply(&self, follower_id: NodeId, reply: AppendEntriesReply)

**Purpose**: Handle reply to AppendEntries RPC.

**Parameters**:
- follower_id: NodeId - Follower that sent reply
- reply: AppendEntriesReply - Reply from follower

**Algorithm**:
1. Check if state is Leader, return if not
2. Get replication_state for follower
3. Remove corresponding RPC from inflight_rpcs
4. If reply.term is greater than current_term:
    a. Step down (call step_down(reply.term))
    b. Return
5. If reply.success is true:
    a. Update follower match_index to (next_index - 1 + reply.entries.length)
    b. Update follower next_index to (last_log_index() + 1)
    c. Check if new entries allow advancing commit_index:
        i. For each uncommitted entry in order:
            - If entry replicated to majority (match_index >= entry.index for majority of followers):
                * Update commit_index to entry.index
                * Trigger log application
6. If reply.success is false:
    a. If reply.conflict_index is provided:
        i. Update follower next_index to reply.conflict_index
    b. If reply.conflict_term is provided:
        i. Find last entry in local log with reply.conflict_term
        ii. Update follower next_index to found index + 1
    c. If no conflict hints:
        i. Decrement follower next_index by 1 (backtracking)
    d. Send new AppendEntries with updated next_index

**Concurrency**: Called from RPC client task when reply received.

### update_commit_index(&self)

**Purpose**: Update commit_index based on replicated entries.

**Algorithm**:
1. For each entry from (commit_index + 1) to last_log_index():
    a. Count how many followers have match_index >= entry.index
    b. Add 1 for leader
    c. If count >= majority:
        i. Update commit_index to entry.index
        ii. Trigger log application
    d. Otherwise:
        i. Break (no higher index can be committed)

**Concurrency**: Called after handling AppendEntries reply.

### apply_log(&self)

**Purpose**: Apply committed log entries to state machine (background task).

**Algorithm**:
1. Enter infinite loop
2. While last_applied < commit_index:
    a. Get entry at (last_applied + 1)
    b. Apply entry.command to state machine (MVCC, B+tree)
    c. Update last_applied
    d. Persist last_applied to disk
3. Sleep for short interval (10ms)

**Concurrency**: Runs as dedicated background task.

## Safety Properties

### Log Matching Property

If two logs contain an entry with the same index and term, all preceding entries are identical.

**Proof**:
1. Leader creates at most one entry per index per term
2. Entries never change position in log
3. AppendEntries consistency check ensures property holds when appending

### Leader Completeness

If a log entry is committed in a term, it appears in the logs of all leaders for higher terms.

**Proof**: A candidate must have all committed entries to win election (RequestVote log comparison). Therefore, any elected leader has all committed entries.

### State Machine Safety

If a server has applied a log entry at index to its state machine, no other server will apply a different log entry at index.

**Proof**: Leader only commits entry at index if majority has replicated it. Any future leader must have that entry (Leader Completeness) and cannot overwrite it.

## Conflict Resolution

### Log Conflict Detection

Follower detects conflict when:
- prev_log_index does not exist in follower log, OR
- Entry at prev_log_index has different term

### Conflict Resolution with Hints

1. Follower detects conflict
2. Follower finds last entry with conflicting term
3. Follower sends conflict_index and conflict_term in reply
4. Leader uses conflict_term to find last entry with that term
5. Leader updates next_index to found position + 1
6. Leader retries AppendEntries

This reduces reconciliation from O(N) to O(log N) round-trips.

### Backtracking Fallback

If follower doesn't provide conflict hints (older version):
1. Leader decrements next_index by 1
2. Leader retries AppendEntries
3. Repeat until success or next_index reaches 0

## Optimization

### Batch Replication

Leader batches entries to reduce RPC overhead:
- Accumulate entries since last AppendEntries
- Flush when batch size reaches limit OR heartbeat interval elapsed
- Follower processes entire batch atomically

### Pipelining

Leader pipelines multiple RPCs:
- Send multiple AppendEntries without waiting for replies
- Maintain sliding window of unacknowledged RPCs
- Window size limits memory usage (default: 10)

### Leader-Lease

Leader maintains lease from majority:
- If leader receives acknowledgments from majority within heartbeat interval
- Leader can assume leadership for next heartbeat interval
- Enables read-only operations on leader without contacting followers

## Rust Implementation Guidance

### Replication State Management

```rust
pub struct ReplicationState {
    next_index: u64,
    match_index: u64,
    inflight_rpcs: Vec<InflightRpc>,
    last_send: Instant,
}
```

### Commit Index Update

```rust
fn update_commit_index(&self) {
    let majority = (self.peers.len() + 1) / 2 + 1;
    for index in (self.commit_index + 1)..=self.last_log_index() {
        let mut replicated = 1; // Leader
        for match_index in self.match_index.values() {
            if *match_index >= index {
                replicated += 1;
            }
        }
        if replicated >= majority {
            self.commit_index.store(index, Ordering::SeqCst);
        }
    }
}
```

## Testing Strategy

Unit tests:
- Log entry append and replication
- Commit index update calculation
- Conflict resolution with hints

Integration tests:
- End-to-end log replication from leader to follower
- Majority commit detection
- Conflict resolution and backtracking

Property-based tests:
- Commit index is monotonically increasing
- Committed entries appear on all nodes
- Log matching property holds
