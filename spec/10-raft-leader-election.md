# Raft Leader Election - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-raft-state.md](./10-raft-state.md), [10-raft-rpc.md](./10-raft-rpc.md)

## Purpose

This specification defines the leader election mechanism for Raft consensus. Leader election ensures that a cluster can recover from leader failure and maintain availability.

## Election Overview

Raft uses a heartbeat mechanism to trigger leader election:
1. Followers wait for election timeout before becoming candidates
2. Candidates increment term and vote for themselves
3. Candidates solicit votes from all peers
4. First candidate to receive majority of votes becomes leader
5. Leader sends periodic heartbeats to prevent new elections

## Types

### ElectionState

**Description**: State tracking for election process.

**Fields**:
- votes_received: HashSet NodeId - Set of nodes that have voted for this candidate
- votes_granted: u32 - Number of votes granted (includes self-vote)
- election_start: Instant - When election started
- vote_requests: HashMap NodeId, bool - Status of vote requests to each peer

**Invariants**:
- votes_received includes own node_id (self-vote)
- votes_granted equals votes_received length

### ElectionTimer

**Description**: Manages randomized election timeout.

**Fields**:
- timeout_min_ms: u64 - Minimum timeout in milliseconds
- timeout_max_ms: u64 - Maximum timeout in milliseconds
- last_reset: Instant - When timer was last reset
- current_timeout: Duration - Current randomized timeout

**Invariants**:
- timeout_min_ms is less than timeout_max_ms
- current_timeout is between timeout_min_ms and timeout_max_ms

## Functions

### start_election(&self) -> Result

**Purpose**: Begin leader election process by transitioning to candidate state.

**Algorithm**:
1. Check if state is Follower, return error if not
2. Increment persistent_state.current_term
3. Set persistent_state.voted_for to own node_id
4. Persist state to disk
5. Transition state to Candidate
6. Initialize ElectionState:
    a. Add own node_id to votes_received
    b. Set votes_granted to 1
7. Reset election timer with new randomized timeout
8. For each peer in cluster:
    a. Send RequestVote RPC with:
        i. term = current_term
        ii. candidate_id = own node_id
        iii. last_log_index = last_log_index()
        iv. last_log_term = last_log_term()
    b. Track vote request in election_state.vote_requests
9. Emit ElectionStarted event
10. Return success

**Error Conditions**:
- NotFollowerError: Current state is not Follower
- IoError: Failed to persist state or send RPCs

**Concurrency**: Called from election timer task when timeout expires.

### handle_request_vote(&self, args: RequestVoteArgs) -> RequestVoteReply

**Purpose**: Handle incoming RequestVote RPC from candidate.

**Parameters**:
- args: RequestVoteArgs - Vote request from candidate

**Returns**: RequestVoteReply with vote decision

**Algorithm**:
1. Lock persistent_state
2. If args.term is less than persistent_state.current_term:
    a. Return reply with term = current_term and vote_granted = false
3. If args.term is greater than persistent_state.current_term:
    a. Update persistent_state.current_term to args.term
    b. Reset persistent_state.voted_for to None
    c. Become follower (transition state)
    d. Persist state
    e. Reset election timer
    f. Continue to step 5
4. If args.term equals persistent_state.current_term:
    a. If persistent_state.voted_for is None or equals args.candidate_id:
        i. Check if candidate's log is at least as up-to-date as receiver's log:
            - If args.last_log_term is greater than last_log_term(): Vote granted
            - If args.last_log_term equals last_log_term() and args.last_log_index is greater than or equal to last_log_index(): Vote granted
            - Otherwise: Vote not granted
        ii. If vote granted:
            - Set persistent_state.voted_for to args.candidate_id
            - Persist state
            - Emit VoteGranted event with args.candidate_id
            - Return reply with term = current_term and vote_granted = true
        iii. Otherwise:
            - Emit VoteRejected event with args.candidate_id and reason
            - Return reply with term = current_term and vote_granted = false
    b. If persistent_state.voted_for is Some and not equal to args.candidate_id:
        i. Emit VoteRejected event with args.candidate_id and reason "already voted"
        ii. Return reply with term = current_term and vote_granted = false

**Concurrency**: Safe to call from RPC handler thread.

### handle_request_vote_reply(&self, peer_id: NodeId, reply: RequestVoteReply)

**Purpose**: Handle reply to RequestVote RPC sent to peer.

**Parameters**:
- peer_id: NodeId - Peer that sent reply
- reply: RequestVoteReply - Vote reply from peer

**Algorithm**:
1. Check if state is Candidate, return if not
2. Update vote_requests for peer_id to received
3. If reply.term is greater than persistent_state.current_term:
    a. Step down (call step_down(reply.term))
    b. Return
4. If reply.vote_granted is true:
    a. Add peer_id to votes_received
    b. Increment votes_granted
    c. Emit VoteGranted event for peer_id
    d. Check if votes_granted is greater than or equal to majority:
        i. If yes, become leader (call become_leader())
5. Return

**Concurrency**: Called from RPC client task when reply received.

### become_leader(&self) -> Result

**Purpose**: Transition to leader state after winning election.

**Algorithm**:
1. Check if state is Candidate, return error if not
2. Transition state to Leader
3. Initialize LeaderVolatileState:
    a. For each peer, set next_index to (last_log_index() + 1)
    b. For each peer, set match_index to 0
4. Start heartbeat timer
5. Immediately send empty AppendEntries (heartbeat) to all peers
6. Emit LeaderElected event
7. Return success

**Error Conditions**:
- NotCandidateError: Current state is not Candidate
- IoError: Failed to start heartbeat timer or send heartbeats

**Concurrency**: Called from handle_request_vote_reply when majority achieved.

### step_down(&self, new_term: u64)

**Purpose**: Step down from leadership or candidacy when discovering higher term.

**Parameters**:
- new_term: u64 - Higher term that caused step down

**Algorithm**:
1. If new_term is less than or equal to persistent_state.current_term:
    a. Return (no action needed)
2. Update persistent_state.current_term to new_term
3. Reset persistent_state.voted_for to None
4. Persist state to disk
5. Transition state to Follower
6. If leader, stop heartbeat timer
7. Reset election timer
8. Emit StateChanged event
9. Emit TermChanged event

**Concurrency**: Safe to call from any thread when higher term discovered.

### reset_election_timer(&self)

**Purpose**: Reset election timer with new randomized timeout.

**Algorithm**:
1. Generate random timeout between election_timeout_min_ms and election_timeout_max_ms
2. Update timer.current_timeout to generated value
3. Update timer.last_reset to current time
4. Restart timer

**Concurrency**: Should be called with timer lock held.

### check_election_timeout(&self) -> bool

**Purpose**: Check if election timeout has expired.

**Returns**: True if timeout expired

**Algorithm**:
1. Calculate elapsed time since timer.last_reset
2. Return true if elapsed time is greater than timer.current_timeout

**Concurrency**: Safe to call from any thread.

## Randomized Election Timeout

### Purpose

Randomized timeout prevents vote splitting when multiple followers become candidates simultaneously.

### Algorithm

1. Generate random value r between 0 and 1
2. Calculate timeout as election_timeout_min_ms + r * (election_timeout_max_ms - election_timeout_min_ms)
3. Use timeout for current election cycle

### Example

Given:
- election_timeout_min_ms = 150
- election_timeout_max_ms = 300

Generated timeouts:
- Node 1: 187ms
- Node 2: 234ms
- Node 3: 156ms
- Node 4: 289ms

Node 3 times out first, becomes candidate, wins election before other nodes time out.

## Vote Granting Rules

A follower grants vote to candidate if:
1. Candidate's term is at least as high as follower's term
2. Follower has not voted in this term OR voted for this candidate
3. Candidate's log is at least as up-to-date as follower's log

### Log Comparison

Log A is more up-to-date than log B if:
1. Last entry term of A is greater than last entry term of B, OR
2. Last entry terms are equal AND last entry index of A is greater than or equal to B

This ensures candidates with more complete logs win elections.

## Safety Properties

### Election Safety

At most one leader can be elected per term.

**Proof**: A node votes for at most one candidate per term (voted_for). Majority vote ensures split votes cannot both achieve majority.

### Leader Completeness

If a log entry is committed in a term, it appears in the logs of all leaders for higher terms.

**Proof**: A candidate must have all committed entries to win election (log comparison rule). Therefore, any elected leader has all committed entries.

## Rust Implementation Guidance

### Timer Management

```rust
pub struct ElectionTimer {
    timeout_min: Duration,
    timeout_max: Duration,
    last_reset: Instant,
    current_timeout: Duration,
}

impl ElectionTimer {
    pub fn reset(&mut self) {
        let range = self.timeout_max - self.timeout_min;
        let random_ms = fastrand::u64(0..range.as_millis() as u64);
        self.current_timeout = self.timeout_min + Duration::from_millis(random_ms);
        self.last_reset = Instant::now();
    }

    pub fn expired(&self) -> bool {
        self.last_reset.elapsed() >= self.current_timeout
    }
}
```

### Random Number Generation

Use fastrand for fast random number generation:
- Lightweight and fast
- Thread-safe
- No external dependencies

### Vote Tracking

```rust
pub struct ElectionState {
    votes_received: HashSet<NodeId>,
    vote_requests: HashMap<NodeId, bool>,
}

impl ElectionState {
    pub fn is_majority(&self, cluster_size: usize) -> bool {
        self.votes_received.len() >= (cluster_size / 2 + 1)
    }
}
```

## Testing Strategy

Unit tests:
- Vote granting rules with various log states
- Log comparison correctness
- Randomized timeout generation

Integration tests:
- Single election
- Split vote resolution
- Step down on higher term discovery

Property-based tests:
- Only one leader per term
- Election completes within timeout range
- Vote always granted to most up-to-date candidate
