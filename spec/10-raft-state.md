# Raft State Management - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-raft-overview.md](./10-raft-overview.md)

## Purpose

This specification defines the Raft state types and management for NorthstarDB. State is divided into persistent state (must survive restarts) and volatile state (can be reconstructed after restart).

## State Overview

### Persistent State

State that must survive restarts and is written to disk before responding to RPCs:
- current_term: Latest term server has seen
- voted_for: CandidateId that received vote in current term
- log: Log entries (index, term, command)

### Volatile State on All Servers

State that is reconstructed after restart:
- commit_index: Index of highest log entry known to be committed
- last_applied: Index of highest log entry applied to state machine

### Volatile State on Leader

State that is only present on leader and reinitialized after election:
- next_index: For each server, index of next log entry to send
- match_index: For each server, index of highest log entry known to be replicated

## Types

### PersistentState

**Description**: Raft state that must persist across restarts.

**Fields**:
- current_term: u64 - Latest term server has seen (initialized to 0 on first boot, increases monotonically)
- voted_for: Option NodeId - CandidateId that received vote in current term (None if none)
- log: Vec LogEntry - Log entries (index 0 is first entry)

**Persistence**: Must be written to stable storage before responding to RPCs

**Invariants**:
- current_term is monotonically increasing
- voted_for must be cleared (set to None) when current_term increments
- log indices start at 1 (not 0)

### LogEntry

**Description**: A single entry in the Raft log.

**Fields**:
- term: u64 - Term when entry was received by leader
- index: u64 - Log index of this entry (starts at 1, monotonically increasing)
- command: CommitRecord - The actual command to apply to state machine

**Size**: 16 bytes (term + index) plus size of CommitRecord

**Invariants**:
- index is unique per entry within the log
- term is the term in which the leader received this entry
- index and term together uniquely identify an entry

### VolatileState

**Description**: Volatile state that is reinitialized on all servers after restart.

**Fields**:
- commit_index: u64 - Index of highest log entry known to be committed (initialized to 0, increases monotonically)
- last_applied: u64 - Index of highest log entry applied to state machine (initialized to 0, increases monotonically, never exceeds commit_index)

**Invariants**:
- commit_index is greater than or equal to last_applied
- Both are monotonically increasing
- last_applied never exceeds commit_index

### LeaderVolatileState

**Description**: Volatile state that is only present on leader and reinitialized after election.

**Fields**:
- next_index: HashMap NodeId, u64 - For each server, index of next log entry to send to that server (initialized to leader last log index + 1)
- match_index: HashMap NodeId, u64 - For each server, index of highest log entry known to be replicated on that server (initialized to 0)

**Invariants**:
- For each follower, next_index is greater than match_index
- next_index minus match_index is the number of entries pending replication
- match_index is less than or equal to leader commit_index

### FollowerVolatileState

**Description**: Volatile state specific to followers.

**Fields**:
- leader_id: Option NodeId - Current leader (None if no known leader)
- last_heartbeat: Option Instant - Time of last valid AppendEntries or heartbeat from leader

**Invariants**:
- leader_id is Some if and only if recent heartbeat received
- Election timeout is triggered if last_heartbeat exceeds timeout

### RaftLogSnapshot

**Description**: Snapshot of Raft log and state machine for log compaction.

**Fields**:
- last_included_index: u64 - Index of last log entry in snapshot
- last_included_term: u64 - Term of last_included_index
- data: ByteSlice - Serialized state machine snapshot
- config: Configuration - Cluster configuration at snapshot time
- checksum: u64 - Checksum of data field

**Size**: Variable (data size plus 32 bytes metadata)

**Invariants**:
- last_included_index is less than or equal to current log length
- last_included_term matches term of entry at last_included_index in log
- checksum validates data integrity

## Functions

### PersistentState::new() -> PersistentState

**Purpose**: Create new persistent state initialized for first boot.

**Returns**: PersistentState instance

**Algorithm**:
1. Set current_term to 0
2. Set voted_for to None
3. Initialize empty log (Vec::new())
4. Return PersistentState

**Concurrency**: Safe to call.

### PersistentState::load(path: &Path) -> Result PersistentState

**Purpose**: Load persistent state from disk.

**Parameters**:
- path: Path - Path to persistent state file

**Returns**: Result wrapping PersistentState

**Algorithm**:
1. Open file at path for reading
2. Deserialize state from file (bincode format)
3. Validate state invariants:
    a. current_term is reasonable (not excessively large)
    b. voted_for is None or valid NodeId
    c. log indices are sequential
4. Return validated state

**Error Conditions**:
- IoError: Failed to read file
- DeserializeError: Failed to deserialize state
- ValidationError: State invariants violated

**Concurrency**: Should not be called concurrently on same file.

### PersistentState::persist(&self, path: &Path) -> Result

**Purpose**: Write persistent state to disk atomically.

**Parameters**:
- path: Path - Path to persistent state file

**Returns**: Empty Result on success

**Algorithm**:
1. Validate state invariants
2. Serialize state to bytes (bincode format)
3. Calculate checksum of serialized bytes
4. Write to temporary file (path.tmp)
5. Sync temporary file to disk (fsync)
6. Rename temporary file to final path (atomic rename)
7. Return success

**Error Conditions**:
- IoError: Failed to write or sync file
- SerializationError: Failed to serialize state

**Concurrency**: Should be called with external synchronization (only one thread persisting at a time).

### PersistentState::current_term(&self) -> u64

**Purpose**: Get current term.

**Returns**: Current term number

**Concurrency**: Safe to call from any thread.

### PersistentState::set_current_term(&mut self, term: u64)

**Purpose**: Set current term (only if new term is greater).

**Parameters**:
- term: u64 - New term number

**Algorithm**:
1. If term is greater than current_term:
    a. Update current_term
    b. Reset voted_for to None
2. Return

**Invariants**: current_term is monotonically increasing

**Concurrency**: Should be called with external synchronization.

### PersistentState::vote_for(&mut self, node_id: NodeId, term: u64) -> Result

**Purpose**: Record vote for candidate in current term.

**Parameters**:
- node_id: NodeId - Candidate to vote for
- term: u64 - Term in which vote is cast

**Algorithm**:
1. If term is greater than current_term:
    a. Update current_term
    b. Reset voted_for to None
    c. Return error (caller should retry)
2. If term is less than current_term:
    a. Return error (term expired)
3. If voted_for is Some:
    a. Return error (already voted)
4. Set voted_for to Some(node_id)
5. Return success

**Error Conditions**:
- TermExpired: term is less than current_term
- AlreadyVoted: Already voted for different candidate in this term

**Concurrency**: Should be called with external synchronization.

### PersistentState::append_entry(&mut self, entry: LogEntry) -> Result

**Purpose**: Append entry to log.

**Parameters**:
- entry: LogEntry - Entry to append

**Algorithm**:
1. Validate entry:
    a. entry.index must equal current log length + 1
    b. entry.term must be greater than or equal to current_term
2. Append entry to log
3. Return success

**Error Conditions**:
- InvalidIndex: entry.index does not match expected next index
- InvalidTerm: entry.term is less than current_term

**Concurrency**: Should be called with external synchronization.

### PersistentState::truncate_log(&mut self, index: u64)

**Purpose**: Truncate log at index (remove entries from index onwards).

**Parameters**:
- index: u64 - Index to truncate at (entries after this are removed)

**Algorithm**:
1. If index is 0, clear entire log
2. If index is greater than log length, return error
3. Truncate log to keep entries 0 to index inclusive
4. Return success

**Error Conditions**:
- InvalidIndex: index is greater than log length

**Concurrency**: Should be called with external synchronization.

### PersistentState::get_entry(&self, index: u64) -> Option LogEntry

**Purpose**: Get log entry at index.

**Parameters**:
- index: u64 - Log index

**Returns**: LogEntry if found, None if index out of bounds

**Algorithm**:
1. If index is 0 or greater than log length, return None
2. Return entry at position (index - 1) (log is 0-indexed, indices are 1-indexed)

**Concurrency**: Safe to call from any thread.

### PersistentState::last_log_index(&self) -> u64

**Purpose**: Get index of last entry in log.

**Returns**: Log index (0 if log is empty)

**Concurrency**: Safe to call from any thread.

### PersistentState::last_log_term(&self) -> u64

**Purpose**: Get term of last entry in log.

**Returns**: Term number (0 if log is empty)

**Concurrency**: Safe to call from any thread.

### VolatileState::new() -> VolatileState

**Purpose**: Create new volatile state initialized to zero.

**Returns**: VolatileState instance

**Algorithm**:
1. Set commit_index to 0
2. Set last_applied to 0
3. Return VolatileState

**Concurrency**: Safe to call.

### VolatileState::advance_commit_index(&mut self, new_index: u64)

**Purpose**: Advance commit index to new value.

**Parameters**:
- new_index: u64 - New commit index

**Algorithm**:
1. If new_index is greater than commit_index:
    a. Update commit_index to new_index
2. Return

**Invariants**: commit_index is monotonically increasing

**Concurrency**: Should be called with external synchronization.

### VolatileState::advance_last_applied(&mut self, new_index: u64)

**Purpose**: Advance last applied index to new value.

**Parameters**:
- new_index: u64 - New last applied index

**Algorithm**:
1. If new_index is greater than last_applied and new_index is less than or equal to commit_index:
    a. Update last_applied to new_index
2. Return

**Invariants**: last_applied never exceeds commit_index

**Concurrency**: Should be called with external synchronization.

### LeaderVolatileState::new(peers: Vec NodeId, last_log_index: u64) -> LeaderVolatileState

**Purpose**: Create new leader volatile state initialized for election.

**Parameters**:
- peers: Vec NodeId - Peer node IDs
- last_log_index: u64 - Leader last log index

**Returns**: LeaderVolatileState instance

**Algorithm**:
1. Initialize empty next_index HashMap
2. Initialize empty match_index HashMap
3. For each peer in peers:
    a. Set next_index for peer to (last_log_index + 1)
    b. Set match_index for peer to 0
4. Return LeaderVolatileState

**Concurrency**: Safe to call.

### LeaderVolatileState::update_match_index(&mut self, node_id: NodeId, index: u64)

**Purpose**: Update match index for a follower.

**Parameters**:
- node_id: NodeId - Follower node ID
- index: u64 - Highest log entry replicated on follower

**Algorithm**:
1. If index is greater than current match_index for node:
    a. Update match_index for node to index
2. Return

**Concurrency**: Should be called with external synchronization.

### LeaderVolatileState::decrement_next_index(&mut self, node_id: NodeId)

**Purpose**: Decrement next index for a follower (log conflict backtracking).

**Parameters**:
- node_id: NodeId - Follower node ID

**Algorithm**:
1. Get current next_index for node
2. If next_index is greater than 1:
    a. Decrement next_index by 1
3. Return

**Concurrency**: Should be called with external synchronization.

### LeaderVolatileState::is_committed(&self, index: u64, majority: usize) -> bool

**Purpose**: Check if log entry at index is committed (replicated to majority).

**Parameters**:
- index: u64 - Log index to check
- majority: usize - Majority count (cluster size / 2 + 1)

**Returns**: True if entry is committed

**Algorithm**:
1. Initialize count to 1 (for leader)
2. For each match_index value:
    a. If match_index is greater than or equal to index, increment count
3. Return true if count is greater than or equal to majority

**Concurrency**: Safe to call from any thread.

## State Persistence Strategy

### Write-Ahead Log

The Raft log uses the existing Write-Ahead Log (WAL) infrastructure:
- Each LogEntry is written to WAL before being acknowledged
- WAL provides crash recovery for incomplete operations
- Checkpointing via snapshots truncates the WAL

### Snapshots

Snapshots compact the Raft log:
- Contain all state up to last_included_index
- Replace log entries up to last_included_index
- Allow new nodes to bootstrap quickly
- Prevent unbounded log growth

### Recovery

On restart, the state is recovered as follows:
1. Load PersistentState from disk (or initialize if first boot)
2. Reconstruct VolatileState (commit_index = min(persisted commit_index, last log index))
3. If leader, LeaderVolatileState is reinitialized (may need to send snapshots)
4. If follower, FollowerVolatileState is initialized (will discover leader via heartbeats)

## Rust Implementation Guidance

### Struct Definitions

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersistentState {
    pub current_term: u64,
    pub voted_for: Option<NodeId>,
    pub log: Vec<LogEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogEntry {
    pub term: u64,
    pub index: u64,
    pub command: CommitRecord,
}

#[derive(Debug, Clone)]
pub struct VolatileState {
    pub commit_index: u64,
    pub last_applied: u64,
}

#[derive(Debug, Clone)]
pub struct LeaderVolatileState {
    pub next_index: HashMap<NodeId, u64>,
    pub match_index: HashMap<NodeId, u64>,
}
```

### Atomic Operations

Use AtomicU64 for frequently accessed values:

```rust
pub struct RaftCore {
    current_term: Arc<AtomicU64>,
    commit_index: Arc<AtomicU64>,
    last_applied: Arc<AtomicU64>,
}
```

### Thread Safety

Use RwLock for less frequently accessed complex state:

```rust
pub struct RaftCore {
    persistent_state: Arc<RwLock<PersistentState>>,
    leader_state: Arc<RwLock<Option<LeaderVolatileState>>>,
}
```

### Serialization

Use bincode for efficient binary serialization:

```rust
let serialized = bincode::serialize(&persistent_state)?;
let checksum = crc64(&serialized);
```

## Testing Strategy

Unit tests:
- Persistent state creation and persistence
- Log entry append and truncation
- Volatile state advancement
- Leader state initialization and updates

Property-based tests:
- current_term is monotonically increasing
- commit_index is greater than or equal to last_applied
- next_index is greater than match_index for all followers

Integration tests:
- State persistence and recovery
- Snapshot creation and installation
- State reconstruction after restart
