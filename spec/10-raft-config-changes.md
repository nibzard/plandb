# Raft Configuration Changes - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-raft-state.md](./10-raft-state.md), [10-raft-rpc.md](./10-raft-rpc.md)

## Purpose

This specification defines the safe mechanism for changing Raft cluster configuration (adding or removing nodes). Configuration changes use joint consensus to ensure safety during transitions.

## Configuration Overview

Raft uses joint consensus for configuration changes:
1. Phase 1: C_old,new - Joint consensus with both old and new configurations
2. Phase 2: C_new - New configuration only

This ensures safety by requiring agreement from both old and new configurations.

## Types

### Configuration

**Description**: Cluster configuration defining voting members.

**Fields**:
- nodes: Vec NodeId - List of voting member node IDs
- learners: Vec NodeId - List of non-voting learner node IDs

**Invariants**:
- nodes list is odd-sized (3, 5, or 7)
- No duplicate node IDs in nodes or learners
- learners and nodes are disjoint sets

### ConfigurationEntry

**Description**: Log entry for configuration change.

**Fields**:
- config_type: ConfigurationType - Type of configuration change
- old_config: Option Configuration - Old configuration (for joint consensus)
- new_config: Configuration - New configuration
- entering_joint: bool - True if entering joint consensus phase

### ConfigurationType

**Description**: Type of configuration change.

**Variants**:
- AddNode: Add new node to cluster
- RemoveNode: Remove node from cluster
- PromoteLearner: Promote learner to voting member
- DemoteToLearner: Demote voting member to learner

### ConfigurationState

**Description**: State of configuration change process.

**Fields**:
- phase: ConfigurationPhase - Current phase (Normal, Joint, New)
- pending_config: Option Configuration - Pending configuration not yet committed
- joint_config: Option (Configuration, Configuration) - Joint configuration during transition

**Phases**:
- Normal: Operating with single configuration
- Joint: Operating with joint consensus (C_old,new)
- New: Transitioned to new configuration (C_new)

## Functions

### add_node(&self, node_id: NodeId, address: String) -> Result

**Purpose**: Add new node to cluster as learner, then promote to voting member.

**Parameters**:
- node_id: NodeId - New node ID
- address: String - Network address of new node

**Algorithm**:
1. Validate node_id is not already in cluster
2. Create C_new with node added to learners list
3. Propose configuration entry with ConfigurationType::AddNode
4. Wait for entry to be committed
5. Send C_new to new node via bootstrap
6. Wait for new node to catch up
7. Create C_new with node moved from learners to nodes list
8. Propose configuration entry with ConfigurationType::PromoteLearner
9. Wait for entry to be committed
10. Return success

**Error Conditions**:
- AlreadyExists: Node already in cluster
- NotLeaderError: Not the leader
- CommitTimeout: Configuration entry not committed within timeout

**Concurrency**: Should be called sequentially (only one config change at a time).

### remove_node(&self, node_id: NodeId) -> Result

**Purpose**: Remove node from cluster.

**Parameters**:
- node_id: NodeId - Node ID to remove

**Algorithm**:
1. Validate node_id is in cluster
2. Create C_new with node removed from nodes or learners
3. Check if removal would leave cluster without majority
4. If removal is safe:
    a. Propose configuration entry with ConfigurationType::RemoveNode
    b. Wait for entry to be committed
    c. Notify removed node
    d. Return success
5. If removal is unsafe:
    a. Return error indicating insufficient nodes

**Error Conditions**:
- NotFound: Node not in cluster
- UnsafeRemoval: Removal would leave cluster without quorum
- NotLeaderError: Not the leader

**Concurrency**: Should be called sequentially.

### propose_configuration(&self, entry: ConfigurationEntry) -> Result

**Purpose**: Propose configuration change to Raft log.

**Parameters**:
- entry: ConfigurationEntry - Configuration entry to propose

**Algorithm**:
1. Check if state is Leader, return error if not
2. Check if no configuration change is in progress
3. If entering_joint is true:
    a. Create C_old,new joint configuration
    b. Create configuration entry with old_config = C_old, new_config = C_new
    c. Append to log
    d. Update configuration_state.phase to Joint
4. If entering_joint is false:
    a. Create configuration entry with new_config only
    b. Append to log
    c. Update configuration_state.phase to New
5. Wait for entry to be committed
6. Apply configuration to cluster
7. Return success

**Error Conditions**:
- NotLeaderError: Not the leader
- ConfigInProgress: Another configuration change is in progress
- IoError: Failed to append entry or apply configuration

**Concurrency**: Only one configuration change at a time.

### apply_configuration(&self, config: Configuration)

**Purpose**: Apply new configuration to cluster.

**Parameters**:
- config: Configuration - Configuration to apply

**Algorithm**:
1. Update cluster membership
2. If nodes changed:
    a. Recalculate majority
    b. Update peer list
3. If new node added:
    a. Create RPC client for new node
4. If node removed:
    a. Close RPC client for removed node
    b. Remove from replication state
5. Persist configuration to disk
6. Return success

**Concurrency**: Should be called with cluster lock held.

## Joint Consensus

### Phase 1: C_old,new (Entering Joint Consensus)

1. Leader creates joint configuration with both old and new nodes
2. Leader appends configuration entry to log
3. Entry is committed when both C_old and C_new majorities acknowledge
4. Cluster operates with joint configuration

### Phase 2: C_new (Exiting Joint Consensus)

1. Leader creates new configuration entry (C_new only)
2. Leader appends configuration entry to log
3. Entry is committed when C_new majority acknowledges
4. Cluster operates with new configuration only

### Safety Properties

**C_old,new Agreement**: Both old and new configurations must agree on entries during joint phase.

**Quorum Calculation**: During joint phase, quorum requires intersection of C_old and C_new majorities.

**No Divergence**: Joint consensus prevents two majorities from making independent decisions.

## Learner Nodes

Learners are non-voting cluster members that:
- Receive replicated log entries
- Serve read-only queries
- Do not participate in elections or quorum

### Adding Learner

1. Add node to learners list (single-phase configuration change)
2. Node receives log replication but does not vote
3. Monitor learner replication lag

### Promoting Learner

1. Move node from learners to nodes list (two-phase joint consensus)
2. Node becomes voting member
3. Cluster size increases, majority recalculated

### Demoting to Learner

1. Move node from nodes to learners list (two-phase joint consensus)
2. Node stops voting
3. Cluster size decreases, majority recalculated

## Rust Implementation Guidance

### Configuration Types

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Configuration {
    pub nodes: Vec<NodeId>,
    pub learners: Vec<NodeId>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ConfigurationType {
    AddNode,
    RemoveNode,
    PromoteLearner,
    DemoteToLearner,
}

#[derive(Debug, Clone)]
pub enum ConfigurationPhase {
    Normal,
    Joint { old: Configuration, new: Configuration },
    New { config: Configuration },
}
```

### Quorum Calculation

```rust
pub fn quorum_size(&self, config: &Configuration) -> usize {
    (config.nodes.len() / 2) + 1
}

pub fn is_quorum(&self, config: &Configuration, responses: HashSet<NodeId>) -> bool {
    let quorum = self.quorum_size(config);
    let voting_responses = responses.iter()
        .filter(|id| config.nodes.contains(id))
        .count();
    voting_responses >= quorum
}

pub fn is_joint_quorum(&self, old: &Configuration, new: &Configuration, responses: HashSet<NodeId>) -> bool {
    self.is_quorum(old, responses.clone()) && self.is_quorum(new, responses)
}
```

## Testing Strategy

Unit tests:
- Configuration validation
- Quorum calculation
- Joint consensus phase transitions

Integration tests:
- Add node to cluster
- Remove node from cluster
- Promote learner to voting member
- Joint consensus two-phase commit

Property-based tests:
- Configuration always has odd number of voting members
- Joint quorum always requires intersection of old and new majorities
- Learners never participate in quorum
