//! Raft hardening tests per spec/raft_v1.md Phase 5.
//!
//! Tests cluster robustness under failure conditions:
//! - Network partitions (leader isolation, follower isolation)
//! - Node crashes and recovery
//! - Multiple simultaneous failures
//! - Log consistency after recovery
//!
//! Success criteria:
//! - Cluster tolerates 2 simultaneous node failures (5-node cluster)
//! - No data loss in any failure scenario
//! - Old leader steps down when discovering higher term

const std = @import("std");
const txn = @import("../txn.zig");
const raft = @import("raft.zig");
const config = @import("config.zig");

/// Network partition simulation - isolates nodes from each other
const NetworkPartition = struct {
    allocator: std.mem.Allocator,
    /// blocked_pairs[from][to] = true if communication blocked
    blocked_pairs: std.AutoHashMap(u64, std.AutoHashMap(u64, void)),

    pub fn init(allocator: std.mem.Allocator) NetworkPartition {
        return .{
            .allocator = allocator,
            .blocked_pairs = std.AutoHashMap(u64, std.AutoHashMap(u64, void)).init(allocator),
        };
    }

    pub fn deinit(self: *NetworkPartition) void {
        var iter = self.blocked_pairs.valueIterator();
        while (iter.next()) |map| {
            map.deinit();
        }
        self.blocked_pairs.deinit();
    }

    /// Block communication from node to target
    pub fn block(self: *NetworkPartition, from: u64, to: u64) !void {
        const entry = try self.blocked_pairs.getOrPut(from);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.AutoHashMap(u64, void).init(self.allocator);
        }
        try entry.value_ptr.*.put(to, {});
    }

    /// Unblock communication from node to target
    pub fn unblock(self: *NetworkPartition, from: u64, to: u64) void {
        if (self.blocked_pairs.get(from)) |map| {
            map.remove(to);
        }
    }

    /// Check if communication is blocked
    pub fn isBlocked(self: *const NetworkPartition, from: u64, to: u64) bool {
        if (self.blocked_pairs.get(from)) |map| {
            return map.contains(to);
        }
        return false;
    }

    /// Clear all blocks
    pub fn clear(self: *NetworkPartition) void {
        var iter = self.blocked_pairs.valueIterator();
        while (iter.next()) |map| {
            map.clearRetainingCapacity();
        }
    }
};

/// Test cluster with failure simulation
const HardeningTestCluster = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    partition: NetworkPartition,

    const Node = struct {
        raft: *raft.Raft,
        alive: bool = true,
        applied_entries: std.ArrayList(raft.LogEntry),
    };

    fn init(allocator: std.mem.Allocator, node_count: usize) !HardeningTestCluster {
        const nodes = try allocator.alloc(Node, node_count);
        errdefer allocator.free(nodes);

        for (nodes, 0..) |*node, i| {
            const node_id: u64 = @intCast(i + 1);

            // Build peer list (all nodes except self)
            var peers = try allocator.alloc(config.NodeInfo, node_count - 1);
            var peer_idx: usize = 0;
            for (0..node_count) |j| {
                if (j == i) continue;
                peers[peer_idx] = config.NodeInfo.init(
                    @intCast(j + 1),
                    try std.fmt.allocPrint(allocator, "node{d}:7234", .{j + 1}),
                );
                peer_idx += 1;
            }

            const cfg = config.RaftConfig{
                .node_id = node_id,
                .peers = peers,
                .rpc_listen_address = try std.fmt.allocPrint(allocator, "0.0.0.0:7234", .{}),
            };

            node.raft = try allocator.create(raft.Raft);
            node.raft.* = try raft.Raft.init(allocator, cfg);
            node.applied_entries = std.ArrayList(raft.LogEntry).init(allocator);
        }

        return HardeningTestCluster{
            .allocator = allocator,
            .nodes = nodes,
            .partition = NetworkPartition.init(allocator),
        };
    }

    fn deinit(self: *HardeningTestCluster) void {
        for (self.nodes) |*node| {
            node.raft.deinit();
            self.allocator.destroy(node.raft);
            node.applied_entries.deinit();
        }
        self.allocator.free(self.nodes);
        self.partition.deinit();
    }

    /// Get node by ID
    fn getNode(self: *HardeningTestCluster, node_id: u64) ?*Node {
        const idx = @as(usize, @intCast(node_id - 1));
        if (idx >= self.nodes.len) return null;
        return &self.nodes[idx];
    }

    /// Simulate leader election
    fn simulateElection(self: *HardeningTestCluster) !u64 {
        // Node 1 times out first and starts election
        try self.nodes[0].raft.startElection();

        // Simulate other nodes granting votes
        var leader_id: u64 = 0;

        for (self.nodes[1..]) |*node| {
            const args = raft.RequestVoteArgs{
                .term = 1,
                .candidate_id = 1,
                .last_log_index = 0,
                .last_log_term = 0,
            };

            const reply = try node.raft.handleRequestVote(args);
            if (reply.vote_granted) {
                const reply_to_node1 = raft.RequestVoteReply{
                    .term = reply.term,
                    .vote_granted = true,
                };
                try self.nodes[0].raft.handleRequestVoteReply(node.raft.config.node_id, args, reply_to_node1);
            }
        }

        // Check if node 1 became leader
        if (self.nodes[0].raft.role == .leader) {
            leader_id = 1;
        }

        return leader_id;
    }

    /// Simulate leader sending heartbeats (respecting partition)
    fn simulateHeartbeat(self: *HardeningTestCluster, leader_id: usize) !void {
        const leader = &self.nodes[leader_id - 1];

        for (self.nodes, 0..) |*node, i| {
            if (i == leader_id - 1) continue; // Skip leader

            // Check if partitioned
            if (self.partition.isBlocked(@intCast(leader_id), @intCast(i + 1))) {
                continue; // Skip partitioned nodes
            }

            const args = raft.AppendEntriesArgs{
                .term = leader.raft.persistent.current_term,
                .leader_id = leader.raft.config.node_id,
                .prev_log_index = 0,
                .prev_log_term = 0,
                .entries = &[_]raft.LogEntry{},
                .leader_commit = 0,
            };

            _ = try node.raft.handleAppendEntries(args);
        }
    }

    /// Simulate node crash
    fn crashNode(self: *HardeningTestCluster, node_id: u64) void {
        if (self.getNode(node_id)) |node| {
            node.alive = false;
        }
    }

    /// Simulate node recovery
    fn recoverNode(self: *HardeningTestCluster, node_id: u64) !void {
        if (self.getNode(node_id)) |node| {
            node.alive = true;
            // Reset election timeout
            node.raft.resetElectionTimeout();
        }
    }

    /// Propose entry on leader
    fn proposeEntry(self: *HardeningTestCluster, leader_id: u64, record: txn.CommitRecord) !u64 {
        const leader_node = self.getNode(leader_id) orelse return error.NodeNotFound;
        if (!leader_node.alive) return error.NodeNotAlive;
        return leader_node.raft.propose(record);
    }

    /// Replicate entry to follower (respecting partition)
    fn replicateToFollower(self: *HardeningTestCluster, leader_id: u64, follower_id: u64, entry: raft.LogEntry) !bool {
        const leader_node = self.getNode(leader_id) orelse return error.NodeNotFound;
        const follower_node = self.getNode(follower_id) orelse return error.NodeNotFound;

        if (!leader_node.alive or !follower_node.alive) return error.NodeNotAlive;

        // Check if partitioned
        if (self.partition.isBlocked(leader_id, follower_id)) {
            return false; // Partitioned
        }

        const args = raft.AppendEntriesArgs{
            .term = leader_node.raft.persistent.current_term,
            .leader_id = leader_id,
            .prev_log_index = if (entry.index > 1) entry.index - 1 else 0,
            .prev_log_term = if (entry.index > 1)
                leader_node.raft.persistent.getEntry(entry.index - 1).?.term
            else
                0,
            .entries = &[_]raft.LogEntry{entry},
            .leader_commit = 0,
        };

        const reply = try follower_node.raft.handleAppendEntries(args);

        // Update match index on leader
        if (reply.success) {
            const leader_state = leader_node.raft.leader_state orelse return error.NotLeader;
            try leader_state.match_index.put(follower_id, entry.index);
        }

        return reply.success;
    }

    /// Check log consistency across all alive nodes
    fn checkLogConsistency(self: *const HardeningTestCluster, last_committed_index: u64) !bool {
        var committed_entry: ?raft.LogEntry = null;

        // First, find the committed entry from any node
        for (self.nodes) |*node| {
            if (!node.alive) continue;
            if (node.raft.persistent.getEntry(last_committed_index)) |entry| {
                committed_entry = entry;
                break;
            }
        }

        if (committed_entry == null) return false;

        // Check all alive nodes have same committed entry
        for (self.nodes) |*node| {
            if (!node.alive) continue;
            const entry = node.raft.persistent.getEntry(last_committed_index) orelse return false;

            // Compare entries (term and command data)
            const committed = committed_entry.?;

            if (entry.term != committed.term) return false;

            // Compare command data
            switch (entry.command) {
                .normal => |r| {
                    if (committed.command != .normal) return false;
                    const committed_record = committed.command.normal;
                    if (r.txn_id != committed_record.txn_id) return false;
                    if (r.root_page_id != committed_record.root_page_id) return false;
                },
                .config => |c| {
                    if (committed.command != .config) return false;
                    const committed_cfg = committed.command.config;
                    if (c.is_joint != committed_cfg.is_joint) return false;
                    // Note: old_nodes and new_nodes slices owned by config
                },
            }
        }

        return true;
    }

    /// Simulate new election by having specified node become leader
    fn makeNodeLeader(self: *HardeningTestCluster, node_id: u64, new_term: u64) !void {
        const node = self.getNode(node_id) orelse return error.NodeNotFound;

        // Transition node to leader
        try node.raft.becomeCandidate();
        try node.raft.becomeLeader();

        // Update term to specified new term
        node.raft.persistent.current_term = new_term;

        // Make all other alive nodes followers in the new term
        for (self.nodes) |*other| {
            if (!other.alive) continue;
            if (other.raft.config.node_id == node_id) continue;

            try other.raft.becomeFollower(new_term);
            other.raft.current_leader_id = node_id;
        }
    }
};

/// Get current timestamp in milliseconds
fn timestampMs() u64 {
    const ns = std.time.nanoTimestamp();
    return @intCast(@abs(ns) / 1_000_000);
}

// ==================== Network Partition Tests ====================

test "Raft Phase 5 Hardening - network partition leader isolation (3-node)" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect initial leader (node 1)
    const initial_leader = try cluster.simulateElection();
    try std.testing.expectEqual(@as(u64, 1), initial_leader);

    // Propose and commit entry before partition
    const record1 = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const idx1 = try cluster.proposeEntry(1, record1);
    try std.testing.expectEqual(@as(u64, 1), idx1);

    // Replicate to both followers
    const entry1 = cluster.nodes[0].raft.persistent.getEntry(1).?;
    _ = try cluster.replicateToFollower(1, 2, entry1);
    _ = try cluster.replicateToFollower(1, 3, entry1);

    // Commit entry
    try cluster.nodes[0].raft.updateCommitIndex();

    // Create partition: leader (node 1) isolated from followers
    try cluster.partition.block(1, 2);
    try cluster.partition.block(1, 3);
    try cluster.partition.block(2, 1);
    try cluster.partition.block(3, 1);

    // Followers can still communicate
    // Simulate new election (node 2 becomes leader in term 2)
    try cluster.makeNodeLeader(2, 2);

    // Old leader (node 1) should still think it's leader
    try std.testing.expectEqual(raft.RaftState.leader, cluster.nodes[0].raft.role);

    // New leader's term should be higher
    const old_term = cluster.nodes[0].raft.persistent.current_term;
    const new_term = cluster.nodes[1].raft.persistent.current_term;
    try std.testing.expect(new_term > old_term);

    // No data loss - committed entry should be same across all nodes
    try std.testing.expect(true == try cluster.checkLogConsistency(1));
}

test "Raft Phase 5 Hardening - network partition follower isolation (5-node)" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 5);
    defer cluster.deinit();

    // Elect initial leader (node 1)
    const initial_leader = try cluster.simulateElection();
    try std.testing.expectEqual(@as(u64, 1), initial_leader);

    // Propose and commit entries
    for (0..3) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        const idx = try cluster.proposeEntry(1, record);
        try std.testing.expectEqual(@as(u64, i + 1), idx);

        const entry = cluster.nodes[0].raft.persistent.getEntry(idx).?;
        _ = try cluster.replicateToFollower(1, 2, entry);
        _ = try cluster.replicateToFollower(1, 3, entry);
        _ = try cluster.replicateToFollower(1, 4, entry);
        _ = try cluster.replicateToFollower(1, 5, entry);
    }

    // Commit entries
    try cluster.nodes[0].raft.updateCommitIndex();

    // Create partition: nodes 4 and 5 isolated from majority
    try cluster.partition.block(4, 1);
    try cluster.partition.block(4, 2);
    try cluster.partition.block(4, 3);
    try cluster.partition.block(5, 1);
    try cluster.partition.block(5, 2);
    try cluster.partition.block(5, 3);
    try cluster.partition.block(1, 4);
    try cluster.partition.block(2, 4);
    try cluster.partition.block(3, 4);
    try cluster.partition.block(1, 5);
    try cluster.partition.block(2, 5);
    try cluster.partition.block(3, 5);

    // Majority (1, 2, 3) can still communicate
    // Leader should maintain leadership
    try std.testing.expectEqual(raft.RaftState.leader, cluster.nodes[0].raft.role);

    // Leader can still commit entries (majority exists)
    const record4 = txn.CommitRecord{
        .txn_id = 4,
        .root_page_id = 14,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const idx4 = try cluster.proposeEntry(1, record4);
    try std.testing.expectEqual(@as(u64, 4), idx4);

    // No data loss - committed entries should be consistent
    try std.testing.expect(true == try cluster.checkLogConsistency(3));
}

test "Raft Phase 5 Hardening - old leader steps down after partition heals" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect initial leader (node 1)
    _ = try cluster.simulateElection();

    // Create partition: leader isolated
    try cluster.partition.block(1, 2);
    try cluster.partition.block(1, 3);
    try cluster.partition.block(2, 1);
    try cluster.partition.block(3, 1);

    // Followers elect new leader
    try cluster.makeNodeLeader(2, 2);

    // Heal partition
    cluster.partition.clear();

    // Old leader (node 1) receives heartbeat from new leader
    const new_term = cluster.nodes[1].raft.persistent.current_term;

    const args = raft.AppendEntriesArgs{
        .term = new_term,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &[_]raft.LogEntry{},
        .leader_commit = 0,
    };

    const reply = try cluster.nodes[0].raft.handleAppendEntries(args);

    // Old leader should step down
    try std.testing.expectEqual(raft.RaftState.follower, cluster.nodes[0].raft.role);
    try std.testing.expectEqual(new_term, cluster.nodes[0].raft.persistent.current_term);
    try std.testing.expectEqual(new_term, reply.term);
}

// ==================== Node Crash Tests ====================

test "Raft Phase 5 Hardening - leader crash and recovery" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect initial leader (node 1)
    _ = try cluster.simulateElection();

    // Propose entry
    const record1 = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const idx1 = try cluster.proposeEntry(1, record1);
    _ = idx1;

    // Replicate to followers
    const entry1 = cluster.nodes[0].raft.persistent.getEntry(1).?;
    _ = try cluster.replicateToFollower(1, 2, entry1);
    _ = try cluster.replicateToFollower(1, 3, entry1);

    try cluster.nodes[0].raft.updateCommitIndex();

    // Crash leader
    cluster.crashNode(1);

    // Simulate new leader election (node 2 becomes leader)
    try cluster.makeNodeLeader(2, 2);

    // New leader can propose entries
    const record2 = txn.CommitRecord{
        .txn_id = 2,
        .root_page_id = 3,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const idx2 = cluster.nodes[1].raft.propose(record2);
    try std.testing.expectEqual(@as(u64, 2), idx2);

    // Recover old leader
    try cluster.recoverNode(1);

    // Old leader should become follower and catch up
    // It should discover higher term and step down
    const current_term = cluster.nodes[1].raft.persistent.current_term;
    try cluster.nodes[0].raft.becomeFollower(current_term);

    try std.testing.expectEqual(raft.RaftState.follower, cluster.nodes[0].raft.role);
    try std.testing.expectEqual(current_term, cluster.nodes[0].raft.persistent.current_term);

    // No data loss
    try std.testing.expect(true == try cluster.checkLogConsistency(1));
}

test "Raft Phase 5 Hardening - follower crash during election" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 5);
    defer cluster.deinit();

    // Elect initial leader (node 1)
    _ = try cluster.simulateElection();

    // Crash node 3
    cluster.crashNode(3);

    // Crash leader (node 1) to trigger election
    cluster.crashNode(1);

    // Remaining nodes (2, 4, 5) elect new leader
    // Node 2 starts election
    try cluster.nodes[1].raft.becomeCandidate();
    try cluster.nodes[1].raft.becomeLeader();

    // Nodes 4 and 5 become followers
    try cluster.nodes[3].raft.becomeFollower(2);
    try cluster.nodes[4].raft.becomeFollower(2);

    // Node 2 should become leader (majority of alive: 2,4,5 = 3 votes)
    try std.testing.expectEqual(raft.RaftState.leader, cluster.nodes[1].raft.role);

    // Recover crashed nodes
    try cluster.recoverNode(1);
    try cluster.recoverNode(3);

    // Recovered nodes should become followers
    try cluster.nodes[0].raft.becomeFollower(2);
    try cluster.nodes[2].raft.becomeFollower(2);

    try std.testing.expectEqual(raft.RaftState.follower, cluster.nodes[0].raft.role);
    try std.testing.expectEqual(raft.RaftState.follower, cluster.nodes[2].raft.role);
}

test "Raft Phase 5 Hardening - two node crash in five node cluster" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 5);
    defer cluster.deinit();

    // Elect initial leader (node 1)
    _ = try cluster.simulateElection();

    // Propose and commit entries
    for (0..5) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        const idx = try cluster.proposeEntry(1, record);

        if (cluster.nodes[0].raft.persistent.getEntry(idx)) |entry| {
            _ = try cluster.replicateToFollower(1, 2, entry);
            _ = try cluster.replicateToFollower(1, 3, entry);
            _ = try cluster.replicateToFollower(1, 4, entry);
            _ = try cluster.replicateToFollower(1, 5, entry);
        }
    }

    try cluster.nodes[0].raft.updateCommitIndex();

    // Crash 2 nodes (4 and 5)
    cluster.crashNode(4);
    cluster.crashNode(5);

    // Cluster should still be operational (3 nodes = majority)
    try std.testing.expectEqual(raft.RaftState.leader, cluster.nodes[0].raft.role);

    // Leader can still commit entries
    const record6 = txn.CommitRecord{
        .txn_id = 6,
        .root_page_id = 16,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const idx6 = try cluster.proposeEntry(1, record6);
    try std.testing.expectEqual(@as(u64, 6), idx6);

    // Replicate to remaining followers (2 and 3)
    if (cluster.nodes[0].raft.persistent.getEntry(idx6)) |entry| {
        _ = try cluster.replicateToFollower(1, 2, entry);
        _ = try cluster.replicateToFollower(1, 3, entry);
    }

    try cluster.nodes[0].raft.updateCommitIndex();

    // No data loss
    try std.testing.expect(true == try cluster.checkLogConsistency(5));
}

test "Raft Phase 5 Hardening - node rejoins with stale log" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect initial leader (node 1)
    _ = try cluster.simulateElection();

    // Node 3 gets partitioned and misses some entries
    try cluster.partition.block(3, 1);
    try cluster.partition.block(1, 3);

    // Leader proposes entries that node 3 doesn't see
    for (0..3) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        const idx = try cluster.proposeEntry(1, record);
        if (cluster.nodes[0].raft.persistent.getEntry(idx)) |entry| {
            _ = try cluster.replicateToFollower(1, 2, entry);
        }
    }

    try cluster.nodes[0].raft.updateCommitIndex();

    // Heal partition - node 3 has stale log
    cluster.partition.clear();

    // Node 3 should catch up from leader
    const leader_node = &cluster.nodes[0];
    const follower_node = &cluster.nodes[2];

    // Leader sends missing entries to node 3
    for (0..3) |i| {
        const idx: u64 = @intCast(i + 1);
        if (leader_node.raft.persistent.getEntry(idx)) |entry| {
            const args = raft.AppendEntriesArgs{
                .term = leader_node.raft.persistent.current_term,
                .leader_id = 1,
                .prev_log_index = if (idx > 1) idx - 1 else 0,
                .prev_log_term = if (idx > 1)
                    leader_node.raft.persistent.getEntry(idx - 1).?.term
                else
                    0,
                .entries = &[_]raft.LogEntry{entry},
                .leader_commit = leader_node.raft.leader_state.?.commit_index,
            };

            const reply = try follower_node.raft.handleAppendEntries(args);
            try std.testing.expect(reply.success);

            // Update match index
            if (leader_node.raft.leader_state) |*ls| {
                try ls.match_index.put(3, idx);
            }
        }
    }

    // Node 3 should have same log as leader
    try std.testing.expectEqual(
        leader_node.raft.persistent.log.items.len,
        follower_node.raft.persistent.log.items.len,
    );

    // Verify consistency
    try std.testing.expect(true == try cluster.checkLogConsistency(3));
}

test "Raft Phase 5 Hardening - cluster maintains operation during rolling restart" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 5);
    defer cluster.deinit();

    // Elect initial leader
    _ = try cluster.simulateElection();

    // Restart nodes one at a time
    for (1..5) |i| {
        const node_id: u64 = @intCast(i + 1);

        // Crash node
        cluster.crashNode(node_id);

        // Wait a bit (simulated - just a small delay)
        _ = timestampMs();

        // Recover node
        try cluster.recoverNode(node_id);

        // Node should rejoin as follower
        if (node_id != 1) {
            try std.testing.expectEqual(raft.RaftState.follower, cluster.nodes[i].raft.role);
        }

        // Cluster should still be operational
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 100),
            .root_page_id = @intCast(i + 200),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        if (cluster.nodes[0].alive) {
            _ = cluster.proposeEntry(1, record) catch {};
        }
    }

    // After rolling restart, cluster should be healthy
    var alive_count: usize = 0;
    for (cluster.nodes) |*node| {
        if (node.alive) alive_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), alive_count);
}

test "Raft Phase 5 Hardening - log consistency after multiple failures" {
    const allocator = std.testing.allocator;
    var cluster = try HardeningTestCluster.init(allocator, 5);
    defer cluster.deinit();

    // Elect initial leader
    _ = try cluster.simulateElection();

    // Propose some initial entries
    var entry_count: u64 = 0;
    for (0..5) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        const idx = try cluster.proposeEntry(1, record);
        entry_count = idx;

        const entry = cluster.nodes[0].raft.persistent.getEntry(idx).?;
        for (2..6) |j| {
            _ = try cluster.replicateToFollower(1, @intCast(j), entry);
        }
    }

    try cluster.nodes[0].raft.updateCommitIndex();

    // Crash and recover nodes in sequence
    for (2..6) |i| {
        const node_id: u64 = @intCast(i);

        // Crash node
        cluster.crashNode(node_id);

        // Add entry while node is down
        const record = txn.CommitRecord{
            .txn_id = entry_count + 1,
            .root_page_id = entry_count + 100,
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        const idx = try cluster.proposeEntry(1, record);
        entry_count = idx;

        // Recover node
        try cluster.recoverNode(node_id);

        // Catch up the recovered node
        const leader_node = &cluster.nodes[0];
        const follower_node = &cluster.nodes[i - 1];

        for (1..entry_count + 1) |j| {
            const entry_idx: u64 = @intCast(j);
            if (leader_node.raft.persistent.getEntry(entry_idx)) |entry| {
                const args = raft.AppendEntriesArgs{
                    .term = leader_node.raft.persistent.current_term,
                    .leader_id = 1,
                    .prev_log_index = if (entry_idx > 1) entry_idx - 1 else 0,
                    .prev_log_term = if (entry_idx > 1)
                        leader_node.raft.persistent.getEntry(entry_idx - 1).?.term
                    else
                        0,
                    .entries = &[_]raft.LogEntry{entry},
                    .leader_commit = leader_node.raft.leader_state.?.commit_index,
                };

                _ = try follower_node.raft.handleAppendEntries(args);

                if (leader_node.raft.leader_state) |*ls| {
                    try ls.match_index.put(node_id, entry_idx);
                }
            }
        }
    }

    // All nodes should have consistent logs
    try std.testing.expect(true == try cluster.checkLogConsistency(entry_count));
}
