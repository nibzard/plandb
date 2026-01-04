# Distributed System Testing Framework

**Phase**: 10
**Task**: 10.13
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2026-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [Cluster Testing Framework](#cluster-testing-framework)
3. [Leader Election Tests](#leader-election-tests)
4. [Log Replication Tests](#log-replication-tests)
5. [Network Partition Tests](#network-partition-tests)
6. [Crash Recovery Tests](#crash-recovery-tests)
7. [Bootstrap Tests](#bootstrap-tests)
8. [Configuration Change Tests](#configuration-change-tests)
9. [Hardening Tests](#hardening-tests)
10. [Long-Running Tests](#long-running-tests)
11. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

This specification describes comprehensive test scenarios for validating the distributed system implementation of NorthstarDB. These scenarios ensure correctness, safety, and fault tolerance across multi-node clusters.

Tests are organized into categories:
- **Unit tests**: Validate individual Raft and replication components
- **Cluster tests**: Validate multi-node behavior and coordination
- **Fault injection tests**: Validate behavior under failures and partitions
- **Hardening tests**: Chaos engineering and stress testing
- **Long-running tests**: Validate stability and resource management over time

### Testing Philosophy

Distributed systems require different testing approaches than single-node systems:
- **Determinism**: Use controlled scheduling and mock time for reproducible tests
- **Fault injection**: Systematically inject failures at every layer
- **Invariants**: Verify safety properties (no split-brain, log consistency)
- **Liveness**: Verify eventual convergence and recovery

### Test Categories

1. **Happy Path**: Normal operation without failures
2. **Fault Tolerance**: Single and multiple node failures
3. **Network Faults**: Partitions, message delays, reordering
4. **Timing Faults**: Clock skew, election timeouts, heartbeat intervals
5. **Configuration Changes**: Adding and removing nodes
6. **Recovery**: Crash recovery and snapshot restoration
7. **Stress**: High load during faults
8. **Chaos**: Random combinations of faults

---

## Cluster Testing Framework

### Multi-Node Cluster Setup

The test framework provides utilities for creating and managing in-memory clusters for deterministic testing.

#### Cluster Configuration

**Purpose**: Define cluster topology and node roles.

**Fields**:
- node_count: u32 - Number of nodes in cluster (3, 5, or 7)
- initial_leader: Option<NodeId> - Optional predetermined leader
- election_timeout_ms: u64 - Timeout before triggering election
- heartbeat_interval_ms: u64 - Heartbeat frequency from leader
- replication_factor: u32 - Required acknowledgments for commit

#### Cluster Lifecycle

**Creation**:
1. Create N nodes with unique NodeIds
2. Initialize each node with empty WAL and state machine
3. Establish network connections between all nodes
4. Optionally designate initial leader or trigger election
5. Wait for cluster to reach stable state

**Shutdown**:
1. Gracefully stop all nodes
2. Verify no uncommitted log entries
3. Verify all nodes have consistent state

### Mock Network Layer

**Purpose**: Control network behavior for fault injection.

**Capabilities**:
- Message delivery (direct, delayed, reordered, dropped)
- Network partition (isolate subsets of nodes)
- Bandwidth throttling
- Duplicate message delivery

**Interface**:
- send(from: NodeId, to: NodeId, message: Bytes)
- partition(nodes: Vec<NodeId>) - Create isolated partition
- heal() - Restore full connectivity
- set_delay(ms: u64) - Add artificial delay
- set_drop_rate(rate: f64) - Drop percentage of messages

### Deterministic Time

**Purpose**: Control time for reproducible election and timeout behavior.

**Interface**:
- advance_ms(duration: u64) - Advance mock clock
- set_time(timestamp: u64) - Set absolute time
- trigger_timer(node_id: NodeId, timer_id: TimerId) - Trigger specific timer

**Usage**:
- All nodes use mock time instead of system clock
- Tests advance time deterministically to trigger events
- Enables reproducible election scenarios

### Test Assertions

Helper functions for verifying distributed invariants:

**State consistency**:
- assert_log_consistent(nodes: Vec<NodeId>) - All nodes have same committed log
- assert_term_consistent(nodes: Vec<NodeId>) - All nodes agree on current term
- assert_leader_unique(nodes: Vec<NodeId>) - Exactly one leader exists

**Safety properties**:
- assert_no_split_brain(cluster: &Cluster) - No two leaders in same term
- assert_log_matching(property: LogProperty) - Log prefix matching property
- assert_state_machine_match(nodes: Vec<NodeId>) - All state machines identical

**Liveness properties**:
- assert_leader_elected(timeout_ms: u64) - Leader exists within timeout
- assert_log_committed(index: Index, timeout_ms: u64) - Entry committed by timeout

---

## Leader Election Tests

### Single Candidate Election

**Purpose**: Verify basic leader election with single candidate.

**Test Steps**:
1. Start cluster of 3 nodes with no initial leader
2. Nodes start as followers
3. Wait for election timeout
4. One node becomes candidate, votes for self
5. Verify candidate wins election (receives majority votes)
6. Verify candidate transitions to leader
7. Verify other nodes transition to follower
8. Verify leader starts sending heartbeats

**Assertions**:
- Exactly one leader exists
- All nodes agree on leader term
- Leader heartbeats received by followers
- No leader election timeout occurs

---

### Multiple Candidates Election

**Purpose**: Verify election resolves when multiple nodes become candidates simultaneously.

**Test Steps**:
1. Start cluster of 5 nodes
2. Simulate election timeout on 3 nodes simultaneously
3. All 3 become candidates and request votes
4. First candidate to receive majority votes wins
5. Other candidates step down upon receiving higher-term heartbeats
6. Verify cluster converges to single leader

**Assertions**:
- Exactly one leader exists after convergence
- All nodes agree on term
- Losing candidates transition to follower
- No split-brain occurs
- Election completes within reasonable time

---

### Term Change Election

**Purpose**: Verify election after leader failure triggers term increment.

**Test Steps**:
1. Start cluster with established leader in term 1
2. Inject failure on leader (crash or partition)
3. Followers detect leader timeout (no heartbeats)
4. One follower becomes candidate in term 2
5. Candidate wins election
6. Verify new leader has term 2
7. Restart old leader
8. Verify old leader discovers higher term, steps down

**Assertions**:
- Term increments monotonically
- New leader has higher term than old
- Old leader recognizes new leader
- Cluster remains consistent through transition

---

### Leader Re-election

**Purpose**: Verify leader can be re-elected after stepping down.

**Test Steps**:
1. Start cluster with leader in term T
2. Leader voluntarily steps down (becomes follower)
3. Trigger new election
4. Previous leader becomes candidate again
5. Verify it wins election in term T+1
6. Verify cluster accepts leader

**Assertions**:
- Previous leader can win election
- Term increments appropriately
- No voting conflicts occur

---

### Minimum Quorum Election

**Purpose**: Verify election requires majority quorum.

**Test Scenarios**:

1. **Two of three nodes**:
   - Start 3-node cluster
   - Partition one node
   - Remaining 2 nodes can elect leader
   - Verify leader serves writes

2. **One of three nodes**:
   - Start 3-node cluster
   - Partition two nodes
   - Single node cannot elect leader (no majority)
   - Verify no leader elected, cluster unavailable

3. **Three of five nodes**:
   - Start 5-node cluster
   - Partition two nodes
   - Remaining 3 nodes can elect leader
   - Verify minority partition cannot elect leader

**Assertions**:
- Majority quorum required for election
- Minority partition remains unavailable
- Cluster recovers when partition heals

---

## Log Replication Tests

### Single Entry Replication

**Purpose**: Verify single log entry replicated to majority.

**Test Steps**:
1. Start 3-node cluster with leader
2. Client writes single entry to leader
3. Leader appends entry to local log
4. Leader sends AppendEntries RPC to followers
5. Followers append entry to local logs
6. Leader receives acknowledgments from majority
7. Leader commits entry (applies to state machine)
8. Followers apply entry upon next AppendEntries

**Assertions**:
- Entry present on all nodes
- All nodes have same index and term
- State machines identical across nodes
- Commit index advances correctly

---

### Batch Entry Replication

**Purpose**: Verify multiple entries replicated efficiently.

**Test Steps**:
1. Start 5-node cluster with leader
2. Client writes 100 entries sequentially
3. Leader batches entries in AppendEntries
4. Followers receive and append batch
5. Leader tracks replication progress per node
6. Commit index advances as majority reached
7. All followers eventually catch up

**Assertions**:
- All 100 entries present on all nodes
- Log indices consistent across nodes
- No gaps in log sequence
- Batch replication more efficient than individual

---

### Catch-Up Replication

**Purpose**: Verify lagging follower catches up to leader.

**Test Steps**:
1. Start 3-node cluster with leader
2. Write 100 entries on leader
3. Partition follower for 50 entries
4. Follower falls behind (has 50, leader has 100)
5. Heal partition
6. Leader sends missing entries via AppendEntries
7. Follower catches up to index 100
8. Follower applies missing entries

**Assertions**:
- Follower receives all missing entries
- No duplicate entries on follower
- Follower log matches leader after catch-up
- State machines eventually consistent

---

### Missing Entry Detection

**Purpose**: Verify leader detects and corrects missing entries on follower.

**Test Steps**:
1. Start 3-node cluster with leader
2. Write 10 entries, all replicated
3. Simulate log corruption on follower (delete entry 5)
4. Leader sends AppendEntries with prev_log_index=9, prev_log_term=T
5. Follower detects mismatch at prev_log_index
6. Follower returns failure indicating conflict
7. Leader decrements next_index for follower
8. Leader retries with earlier index
9. Process repeats until matching prefix found
10. Leader sends missing entries from match point
11. Follower appends missing entries

**Assertions**:
- Follower detects log mismatch
- Leader correctly identifies conflict point
- Missing entries resent and applied
- Final logs consistent

---

### Concurrent Write Conflicts

**Purpose**: Verify write conflicts resolved correctly.

**Test Steps**:
1. Start 3-node cluster with leader A (term 1)
2. Partition leader A from followers
3. Followers elect new leader B (term 2)
4. Client writes entry X to leader A (old)
5. Client writes entry Y to leader B (new)
6. Heal partition
7. Leader A discovers higher term, steps down
8. Leader A's uncommitted entry X discarded
9. Leader B's entry Y committed
10. Node A receives entry Y from leader B

**Assertions**:
- Old leader's uncommitted writes discarded
- New leader's writes committed
- No conflicting commits
- All nodes converge to same log

---

## Network Partition Tests

### Leader Partition

**Purpose**: Verify cluster continues when leader isolated.

**Test Steps**:
1. Start 5-node cluster with leader
2. Partition leader (isolate from all followers)
3. Followers detect leader timeout
4. Followers elect new leader from majority
5. Old leader isolated, cannot commit writes
6. Client writes to old leader timeout or fail
7. Client writes to new leader succeed
8. Heal partition
9. Old leader discovers higher term, steps down
10. Old leader catches up to new log

**Assertions**:
- Minority partition unavailable for writes
- Majority partition elects new leader
- No split-brain (two leaders in same term)
- Old leader yields to new leader
- Cluster converges after healing

---

### Minority Partition

**Purpose**: Verify minority partition cannot elect leader.

**Test Steps**:
1. Start 5-node cluster with leader
2. Partition 2 nodes (minority) from 3 nodes (majority)
3. Majority partition continues with existing leader
4. Minority partition times out, attempts election
5. Minority partition cannot reach majority
6. Minority partition remains follower-only
7. Verify writes succeed on majority
8. Verify writes fail on minority
9. Heal partition
10. Minority nodes catch up

**Assertions**:
- Minority partition cannot elect leader
- Majority partition continues operating
- No commits on minority
- Minority catches up after healing

---

### Split-Brain Prevention

**Purpose**: Verify Raft prevents split-brain scenario.

**Test Scenarios**:

1. **Simultaneous elections**:
   - Start 5-node cluster
   - Partition into 2-2-1 (three partitions)
   - Two partitions each attempt election
   - Verify neither reaches majority (need 3 votes)
   - Verify no leader elected in either partition
   - Heal partition, verify single leader emerges

2. **Equal partition**:
   - Start 4-node cluster
   - Partition into 2-2
   - Neither partition can reach majority
   - Verify cluster unavailable for writes
   - Add fifth node, verify election succeeds

**Assertions**:
- Raft election rules prevent split-brain
- Majority quorum required
- No two leaders in same term

---

### Asymmetric Partition

**Purpose**: Verify behavior with uneven network partitions.

**Test Steps**:
1. Start 5-node cluster with leader node 1
2. Create asymmetric partition:
   - Node 1 can only reach node 2
   - Nodes 2-5 fully connected
3. Verify node 1 isolated (cannot reach majority)
4. Nodes 2-5 elect new leader (node 3)
5. Verify old leader (node 1) isolated
6. Client writes to nodes 2-5 succeed
7. Client writes to node 1 fail
8. Heal partition
9. Node 1 discovers higher term, steps down

**Assertions**:
- Partial connectivity treated as partition
- Leader requires majority connectivity
- Cluster continues with new leader

---

### Partition During Catch-Up

**Purpose**: Verify catch-up behavior interrupted by partition.

**Test Steps**:
1. Start 5-node cluster with leader
2. Write 100 entries
3. Partition follower after 50 entries received
4. Follower has 50, leader has 100
5. Restart follower
6. Follower requests missing entries
7. During catch-up, partition again
8. Catch-up resumes after healing
9. Verify follower eventually consistent

**Assertions**:
- Catch-up resilient to partitions
- Follower retries after partition
- No corruption from partial catch-up

---

## Crash Recovery Tests

### Leader Crash

**Purpose**: Verify cluster recovers from leader crash.

**Test Steps**:
1. Start 3-node cluster with leader (node 1)
2. Write 50 entries, all committed
3. Crash leader node (kill process)
4. Followers detect leader timeout
5. Followers elect new leader (node 2)
6. Write 50 more entries on new leader
7. Restart old leader (node 1)
8. Old leader discovers higher term, becomes follower
9. Old leader receives missing entries via AppendEntries
10. Old leader applies entries to state machine

**Assertions**:
- New leader elected within timeout
- No data loss during transition
- Old leader rejoins as follower
- Old leader catches up completely
- All nodes consistent after recovery

---

### Follower Crash

**Purpose**: Verify cluster tolerates follower crash.

**Test Steps**:
1. Start 5-node cluster with leader
2. Write 100 entries
3. Crash follower node
4. Leader detects follower timeout (AppendEntries fails)
5. Cluster continues with 4 nodes
6. Write 50 more entries (committed on 3 remaining)
7. Restart crashed follower
8. Follower requests catch-up
9. Leader sends missing entries
10. Follower catches up and applies

**Assertions**:
- Cluster continues operating without follower
- Writes committed on remaining majority
- Restarted follower catches up
- No data loss

---

### Majority Crash

**Purpose**: Verify cluster unavailable when majority crashes.

**Test Steps**:
1. Start 5-node cluster with leader
2. Crash 3 nodes (majority)
3. Remaining 2 nodes cannot elect leader
4. Verify no leader exists
5. Client writes timeout or fail
6. Restart 2 crashed nodes
7. Cluster has 4 nodes (majority)
8. New election succeeds
9. Cluster recovers

**Assertions**:
- Majority required for availability
- Cluster unavailable without majority
- Recovery when majority restored

---

### Crash During Replication

**Purpose**: Verify log consistency when node crashes during replication.

**Test Steps**:
1. Start 3-node cluster with leader
2. Leader sends AppendEntries with 10 entries
3. Follower receives and appends 5 entries
4. Follower crashes before acknowledging
5. Leader considers replication failed
6. Leader retries AppendEntries to follower
7. Follower restarts
8. Leader sends AppendEntries with prev_log_index for entry 5
9. Follower acknowledges existing entries
10. Leader sends entries 6-10
11. Follower catches up

**Assertions**:
- No duplicate entries on follower
- Log consistent after recovery
- Leader correctly tracks replication state

---

### Crash With Uncommitted Entries

**Purpose**: Verify uncommitted entries handled correctly after crash.

**Test Steps**:
1. Start 3-node cluster with leader
2. Leader writes 10 entries
3. Entries replicated to 1 follower only
4. Leader crashes before majority acknowledgment
5. Remaining follower (2 nodes) elect new leader
6. Verify uncommitted entries not applied
7. Verify new leader's log may not include uncommitted entries
8. Cluster continues without those entries

**Assertions**:
- Uncommitted entries not committed after crash
- No partial commit of entry
- Cluster consistency maintained

---

### Disk Failure Recovery

**Purpose**: Verify recovery from disk corruption.

**Test Scenarios**:

1. **WAL corruption**:
   - Start 3-node cluster
   - Write 100 entries
   - Corrupt WAL on follower
   - Follower detects corruption on restart
   - Follower requests snapshot from leader
   - Follower restores from snapshot
   - Follower catches up with new entries

2. **Snapshot corruption**:
   - Start cluster with snapshots
   - Corrupt snapshot file on node
   - Node detects corruption on load
   - Node requests full log replay from leader

**Assertions**:
- Corruption detected
- Recovery mechanism succeeds
- No incorrect state applied

---

## Bootstrap Tests

### New Cluster Bootstrap

**Purpose**: Verify bootstrapping new cluster from scratch.

**Test Steps**:
1. Create 3 empty nodes (no WAL, no state machine)
2. Configure cluster with node IDs and peers
3. Start all nodes simultaneously
4. Nodes elect leader
5. Verify cluster operational
6. Write entries, verify replication

**Assertions**:
- Empty nodes form cluster
- Leader elected successfully
- Replication functional
- No prior state required

---

### Bootstrap From Snapshot

**Purpose**: Verify new node bootstraps from snapshot.

**Test Steps**:
1. Start 3-node cluster, write 1000 entries
2. Create snapshot on leader
3. Add new node 4 to configuration
4. Node 4 requests bootstrap
5. Leader sends snapshot to node 4
6. Node 4 restores snapshot (state machine + log)
7. Node 4 begins receiving new entries
8. Verify node 4 catches up completely

**Assertions**:
- Snapshot transfer succeeds
- State machine restored correctly
- Log includes snapshot entries
- Node catches up to leader

---

### Bootstrap During Load

**Purpose**: Verify bootstrap works while cluster under load.

**Test Steps**:
1. Start 3-node cluster
2. Begin continuous write workload (100 writes/sec)
3. Add new node 4
4. Node 4 requests bootstrap
5. Leader sends snapshot while accepting writes
6. Node 4 restores snapshot
7. Node 4 catches up to current log
8. Verify no writes lost during bootstrap

**Assertions**:
- Snapshot creation non-blocking
- Bootstrap completes under load
- All writes applied to new node
- No disruption to existing workload

---

### Partial Bootstrap Failure

**Purpose**: Verify bootstrap retry on failure.

**Test Steps**:
1. Start 3-node cluster with snapshot
2. Add new node 4
3. Node 4 requests snapshot
4. Leader sends snapshot
5. Network fails during transfer
6. Node 4 detects incomplete snapshot
7. Node 4 retries bootstrap
8. Leader resends snapshot
9. Bootstrap succeeds

**Assertions**:
- Bootstrap failure detected
- Retry mechanism works
- No corruption from partial transfer

---

### Lagging Bootstrap

**Purpose**: Verify node with stale snapshot bootstraps correctly.

**Test Steps**:
1. Start 3-node cluster, write 100 entries, create snapshot
2. Write 100 more entries (leader at index 200)
3. Add node 4 with old snapshot (index 100)
4. Node 4 attempts to bootstrap
5. Node 4 detects snapshot stale (last_included_index < leader.commit_index)
6. Node 4 requests new snapshot
7. Leader sends current snapshot
8. Node 4 applies and catches up

**Assertions**:
- Stale snapshot detected
- New snapshot requested
- Node receives current state

---

## Configuration Change Tests

### Add Single Node

**Purpose**: Verify safely adding node to cluster.

**Test Steps**:
1. Start 3-node cluster (nodes 1, 2, 3)
2. Initiate configuration change to add node 4
3. Cluster enters joint consensus (C_old + C_new)
4. Joint configuration committed and replicated
5. Cluster transitions to C_new (nodes 1, 2, 3, 4)
6. Node 4 fully integrated
7. Verify all nodes agree on new configuration
8. Verify writes replicated to node 4

**Assertions**:
- Joint consensus prevents availability loss
- Configuration change committed safely
- New node receives all log entries
- No split-brain during transition

---

### Remove Single Node

**Purpose**: Verify safely removing node from cluster.

**Test Steps**:
1. Start 5-node cluster (nodes 1-5)
2. Initiate configuration change to remove node 5
3. Cluster enters joint consensus (C_old + C_new)
4. Joint configuration committed
5. Cluster transitions to C_new (nodes 1-4)
6. Node 5 stops receiving heartbeats
7. Node 5 shuts down gracefully
8. Verify remaining cluster operational

**Assertions**:
- Removed node excluded from replication
- Removed node steps down gracefully
- Remaining cluster continues
- Configuration change atomic

---

### Replace Node

**Purpose**: Verify replacing failed node with new node.

**Test Steps**:
1. Start 3-node cluster (nodes 1, 2, 3)
2. Node 3 crashes
3. Add new node 4 (replacement)
4. Cluster enters joint consensus
5. Joint configuration committed
6. Cluster transitions to new config (nodes 1, 2, 4)
7. Node 4 bootstraps from snapshot
8. Node 3 removed from configuration
9. Verify cluster operational with 3 nodes

**Assertions**:
- Failed node replaced safely
- New node bootstraps correctly
- Cluster maintains majority
- No availability loss

---

### Concurrent Configuration Changes

**Purpose**: Verify only one configuration change at a time.

**Test Steps**:
1. Start 3-node cluster
2. Initiate configuration change to add node 4
3. Cluster enters joint consensus (not yet committed)
4. Attempt to add node 5
5. Verify second request rejected or queued
6. First configuration change completes
7. Second configuration change proceeds
8. Verify both changes applied sequentially

**Assertions**:
- Concurrent changes prevented
- Configuration changes serialized
- No inconsistent state

---

### Configuration Change During Leader Election

**Purpose**: Verify config change safe during election.

**Test Steps**:
1. Start 5-node cluster with leader
2. Initiate configuration change (add node 6)
3. Enter joint consensus
4. Leader crashes before joint committed
5. Followers detect timeout, elect new leader
6. New leader has joint configuration
7. New leader completes joint consensus
8. Configuration change completes

**Assertions**:
- Configuration change survives election
- New leader completes transition
- No lost configuration state

---

### Multiple Sequential Changes

**Purpose**: Verify multiple configuration changes work.

**Test Steps**:
1. Start 3-node cluster (1, 2, 3)
2. Add node 4, wait for completion
3. Add node 5, wait for completion
4. Remove node 2, wait for completion
5. Add node 6, wait for completion
6. Verify final configuration (1, 3, 4, 5, 6)
7. Verify all nodes agree
8. Verify replication works correctly

**Assertions**:
- Sequential changes succeed
- Each change completes before next
- Final configuration correct

---

## Hardening Tests

### Chaos Testing

**Purpose**: Verify cluster resilience under random faults.

**Test Approach**:
1. Start 7-node cluster
2. Run continuous write workload
3. Chaos agent randomly injects faults:
   - Random node crashes (1-2 nodes at a time)
   - Network partitions (split into 2-3 groups)
   - Message delays (random delay 0-100ms)
   - Message drops (5% drop rate)
   - Clock skew (advance some nodes faster)
4. Run for 1 hour of simulated time
5. Verify no data corruption
6. Verify cluster always recovers
7. Verify no split-brain occurs

**Assertions**:
- Safety properties maintained throughout
- Cluster recovers from all faults
- No permanent inconsistencies

---

### Message Reordering

**Purpose**: Verify correct behavior with reordered messages.

**Test Steps**:
1. Start 3-node cluster with leader
2. Leader sends 100 AppendEntries messages
3. Network randomly reorders messages
4. Followers process out-of-order
5. Verify followers handle reordering:
   - Reject stale prev_log entries
   - Request missing entries
   - Process in correct order
6. Verify all entries eventually applied

**Assertions**:
- Log consistency maintained
- Reordering handled correctly
- No corruption from out-of-order delivery

---

### Duplicate Message Handling

**Purpose**: Verify idempotency of duplicate messages.

**Test Steps**:
1. Start 3-node cluster with leader
2. Leader sends AppendEntries (entries 1-10)
3. Network duplicates messages
4. Follower receives same AppendEntries twice
5. Verify follower handles gracefully:
   - Detects duplicate entries (same index)
   - Idempotently applies (no double apply)
   - Acknowledges duplicate request
6. Verify log consistent (no duplicates)

**Assertions**:
- Duplicate messages don't corrupt state
- RPCs are idempotent
- Log consistency maintained

---

### Clock Skew

**Purpose**: Verify tolerance for clock differences between nodes.

**Test Steps**:
1. Start 5-node cluster
2. Skew clocks:
   - Node 1: +0ms (reference)
   - Node 2: +50ms ahead
   - Node 3: +100ms ahead
   - Node 4: -50ms behind
   - Node 5: -100ms behind
3. Trigger election timeout
4. Verify election completes correctly
5. Verify heartbeats handled correctly
6. Verify no spurious elections from clock skew

**Assertions**:
- Clock skew tolerated
- Election timeout randomized to prevent skew-induced elections
- No incorrect timeouts

---

### Resource Exhaustion

**Purpose**: Verify behavior under resource constraints.

**Test Scenarios**:

1. **Memory pressure**:
   - Start 3-node cluster
   - Write large entries (1MB each)
   - Fill memory until allocations fail
   - Verify cluster continues operation
   - Verify graceful degradation

2. **File descriptor exhaustion**:
   - Start cluster with many connections
   - Exhaust file descriptors
   - Verify new connections rejected gracefully
   - Verify existing connections unaffected

3. **Disk full**:
   - Fill disk on follower
   - Attempt to replicate entries
   - Verify replication fails gracefully
   - Verify retry mechanism

**Assertions**:
- Resource exhaustion handled gracefully
- No crashes from resource limits
- Appropriate errors returned

---

### Malformed Message Handling

**Purpose**: Verify robustness to invalid messages.

**Test Scenarios**:

1. **Invalid RPC type**:
   - Send RPC with unknown type
   - Verify rejected or ignored

2. **Truncated message**:
   - Send incomplete AppendEntries
   - Verify rejected, requested resent

3. **Invalid checksum**:
   - Send message with corrupted checksum
   - Verify rejected

4. **Negative indices**:
   - Send AppendEntries with negative prev_log_index
   - Verify rejected

5. **Term regression**:
   - Send RPC with lower term
   - Verify rejected or step down

**Assertions**:
- Malformed messages rejected
- No crashes or panics
- Appropriate error responses

---

### Adversarial Testing

**Purpose**: Verify robustness to malicious nodes.

**Test Scenarios**:

1. **Byzantine leader**:
   - Leader sends conflicting entries to different followers
   - Followers detect mismatch via prev_log checks
   - Followers reject inconsistent entries

2. **Split-vote attack**:
   - Malicious node votes for multiple candidates
   - Candidates verify vote granted once per term
   - Attack prevented

3. **Fake leader**:
   - Node claims leadership without winning election
   - Followers verify leader via term and heartbeats
   - Fake leader ignored

**Assertions**:
- Raft safety properties prevent Byzantine behavior
- Malicious nodes cannot corrupt cluster
- Verification at every step

---

## Long-Running Tests

### Stability Test

**Purpose**: Verify cluster stability over extended operation.

**Test Steps**:
1. Start 5-node cluster
2. Run continuous workload:
   - 100 writes per second
   - 1000 reads per second
   - Random configuration changes (every 5 minutes)
   - Random node restarts (every 10 minutes)
3. Run for 24 hours of simulated time
4. Monitor:
   - Memory usage (no leaks)
   - Log growth (snapshotting working)
   - Election count (no thrashing)
   - Response latency (no degradation)
5. Verify cluster healthy at end

**Assertions**:
- No memory leaks
- No log growth without bounds
- Stable performance
- No resource exhaustion

---

### Log Compaction

**Purpose**: Verify snapshotting prevents unbounded log growth.

**Test Steps**:
1. Start 3-node cluster
2. Write 1,000,000 entries
3. Configure snapshot at intervals of 100,000 entries
4. Verify snapshots created periodically
5. Verify log truncated after snapshot
6. Verify disk usage bounded
7. Verify old snapshots cleaned up
8. Restart node, verify loaded from latest snapshot

**Assertions**:
- Snapshots created at configured interval
- Log truncated appropriately
- Disk usage bounded
- Snapshot restore functional

---

### Snapshot Transfer Under Load

**Purpose**: Verify snapshot transfer works under load.

**Test Steps**:
1. Start 3-node cluster
2. Write 100,000 entries
3. Create snapshot (10MB)
4. Add new node 4
5. Node 4 requests snapshot transfer
6. During transfer, continue write workload (1000 writes/sec)
7. Verify snapshot transfer completes
8. Verify node 4 catches up to current log
9. Verify no writes lost during transfer

**Assertions**:
- Snapshot transfer non-blocking
- All writes applied to new node
- Transfer completes under load

---

### Repeated Crash Recovery

**Purpose**: Verify cluster withstands frequent crashes.

**Test Steps**:
1. Start 5-node cluster
2. Run workload
3. Every 30 seconds:
   - Crash random node
   - Wait 10 seconds
   - Restart node
   - Verify node catches up
4. Repeat for 100 iterations
5. Verify cluster healthy throughout
6. Verify no data corruption

**Assertions**:
- Repeated crashes handled correctly
- Recovery succeeds every time
- No accumulated state corruption

---

### High Availability

**Purpose**: Verify cluster remains available during faults.

**Test Metrics**:
- **Availability percentage**: Target 99.9% uptime
- **Mean time to recovery**: Target < 5 seconds
- **Data loss**: Zero data loss

**Test Steps**:
1. Start 5-node cluster
2. Run continuous write workload
3. Inject faults at random intervals:
   - Single node crash (every 2 minutes)
   - Network partition (every 5 minutes)
   - Leader crash (every 10 minutes)
4. Measure:
   - Write availability (percentage of time writes accepted)
   - Recovery time after each fault
   - Data loss (committed entries lost)
5. Run for 1 hour of simulated time

**Assertions**:
- Writes available > 99% of time
- Recovery within timeout
- Zero committed data loss

---

## Rust Implementation Guidance

### Test Organization

```
raft/
├── tests/
│   ├── cluster/
│   │   ├── mod.rs                    # Cluster test module
│   │   ├── framework.rs              # Test framework (MockCluster, MockNetwork)
│   │   ├── election.rs               # Leader election tests
│   │   ├── replication.rs            # Log replication tests
│   │   ├── partition.rs              # Network partition tests
│   │   ├── crash.rs                  # Crash recovery tests
│   │   ├── bootstrap.rs              # Bootstrap tests
│   │   ├── config_change.rs          # Configuration change tests
│   │   └── long_running.rs           # Long-running stability tests
│   ├── hardening/
│   │   ├── mod.rs                    # Hardening test module
│   │   ├── chaos.rs                  # Chaos testing
│   │   ├── fault_injection.rs        # Fault injection utilities
│   │   ├── malformed.rs              # Malformed message tests
│   │   └── adversarial.rs            # Adversarial/Byzantine tests
│   └── invariants/
│       ├── mod.rs                    # Invariant checking module
│       ├── log_consistency.rs        # Log consistency invariants
│       ├── safety.rs                 # Safety properties
│       └── liveness.rs               # Liveness properties
└── fuzz/
    └── raft_fuzz.rs                  # Fuzz tests for Raft implementation
```

### Mock Cluster Implementation

**Core structs**:

```rust
pub struct MockCluster {
    nodes: BTreeMap<NodeId, MockNode>,
    network: MockNetwork,
    time: MockTime,
}

impl MockCluster {
    pub fn new(config: ClusterConfig) -> Self;
    pub fn start(&mut self);
    pub fn advance_time(&mut self, duration: Duration);
    pub fn partition(&mut self, nodes: Vec<NodeId>);
    pub fn heal(&mut self);
    pub fn get_leader(&self) -> Option<NodeId>;
    pub fn assert_consistent(&self);
}

pub struct MockNetwork {
    messages: VecDeque<(NodeId, NodeId, RaftRpc)>,
    partitions: HashSet<HashSet<NodeId>>,
    drop_rate: f64,
    delay: Duration,
}

impl MockNetwork {
    pub fn send(&mut self, from: NodeId, to: NodeId, msg: RaftRpc);
    pub fn deliver(&mut self) -> Vec<RpcDelivery>;
    pub fn partition(&mut self, nodes: Vec<NodeId>);
    pub fn set_drop_rate(&mut self, rate: f64);
}

pub struct MockTime {
    current_time: u64,
    timers: BTreeMap<NodeId, Vec<Timer>>,
}

impl MockTime {
    pub fn advance(&mut self, duration: Duration);
    pub fn trigger_timers(&mut self) -> Vec<TimerEvent>;
}
```

### Deterministic Execution

**Key principle**: All tests must be deterministic and reproducible.

**Approach**:
1. Use mock time (never use system clock in tests)
2. Use mock network (control message delivery)
3. Use seeded random number generators
4. Avoid real concurrency in tests (use single-threaded event loop)
5. Process events in deterministic order

**Example**:
```rust
#[test]
fn test_election_timeout() {
    let mut cluster = MockCluster::new(3);
    cluster.start();

    // Advance time to trigger election
    cluster.advance_time(Duration::from_millis(150));

    // Process all resulting messages
    cluster.process_messages();

    // Verify election result
    assert_eq!(cluster.get_leader(), Some(node_id));
}
```

### Property-Based Testing

Use proptest for invariant verification:

```rust
proptest! {
    #[test]
    fn prop_log_matching(ops in vec(arb_operation(), 1..100)) {
        let mut cluster = MockCluster::new(5);
        cluster.start();

        for op in ops {
            cluster.apply_operation(op);
            cluster.process_messages();
        }

        // Verify log matching property
        cluster.assert_log_consistent();
    }
}
```

### Fault Injection Utilities

```rust
pub struct FaultInjector {
    cluster: Weak<MockCluster>,
}

impl FaultInjector {
    pub fn crash_random_node(&mut self);
    pub fn partition_random(&mut self);
    pub fn drop_messages(&mut self, rate: f64);
    pub fn delay_messages(&mut self, duration: Duration);
    pub fn corrupt_message(&mut self);
}
```

### Invariant Checkers

```rust
pub trait InvariantChecker {
    fn check(&self, cluster: &MockCluster) -> Result<(), InvariantViolation>;
}

pub struct LogMatchingInvariant;
impl InvariantChecker for LogMatchingInvariant {
    fn check(&self, cluster: &MockCluster) -> Result<(), InvariantViolation> {
        // Verify log matching property
        // If two logs have same entry at same index,
        // all preceding entries must be identical
    }
}

pub struct LeaderCompletenessInvariant;
impl InvariantChecker for LeaderCompletenessInvariant {
    fn check(&self, cluster: &MockCluster) -> Result<(), InvariantViolation> {
        // If entry committed in term T,
        // all leaders in terms > T have that entry
    }
}
```

### Running Tests

```bash
# Run all distributed tests
cargo test --test cluster

# Run specific test suite
cargo test --test cluster -- election

# Run with logging
RUST_LOG=debug cargo test --test cluster

# Run property tests
cargo test --test cluster -- properties

# Run fuzz tests
cargo fuzz run raft_fuzz

# Run long-running tests (excluded from normal test runs)
cargo test --test cluster -- --ignored --test-threads=1
```

### Continuous Integration

CI requirements for distributed tests:
1. All cluster tests must pass on every commit
2. Property tests run with multiple iterations (1000 cases)
3. Fuzz tests run for 1 hour in CI
4. Long-running tests run nightly
5. Coverage threshold > 90% for Raft implementation

### Test Isolation

Each test must:
1. Create fresh cluster (no shared state between tests)
2. Clean up resources (files, ports) after completion
3. Use unique temporary directories for file operations
4. Randomize election timeouts to avoid port conflicts
5. Run concurrently with other tests (no shared globals)

### Performance Expectations

While performance is secondary to correctness in tests:
- Single election completes within 100ms simulated time
- 1000 entries replicate within 1 second simulated time
- Snapshot transfer of 10MB completes within 5 seconds
- Cluster recovers from single node crash within 5 seconds

### Debugging Failed Tests

When distributed tests fail:
1. Enable debug logging to see message flow
2. Dump cluster state (term, log index, role per node)
3. Check invariants (which safety property violated?)
4. Reproduce deterministically (same seed, same operations)
5. Add assertions at failure point to catch earlier
6. Use replay: capture operation sequence, replay in debugger

---

## Summary

Comprehensive distributed testing ensures:

- **Safety**: No split-brain, no data corruption, log consistency
- **Liveness**: Elections complete, cluster recovers, progress made
- **Fault tolerance**: Tolerates crashes, partitions, message loss
- **Stability**: Long-running operation without degradation
- **Correctness**: Raft invariants maintained under all conditions

The test framework provides confidence that the distributed implementation is production-ready and can handle real-world failures gracefully.
