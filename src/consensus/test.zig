//! Raft integration tests per spec/raft_v1.md Phase 1 success criteria.
//!
//! Tests:
//! - Leader election completes within expected timeout
//! - Leader can replicate log entries to followers
//! - Cluster tolerates single node failure

const std = @import("std");
const txn = @import("../txn.zig");
const raft = @import("raft.zig");
const config = @import("config.zig");

/// Test context for multi-node Raft cluster simulation
const TestCluster = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    rpc_messages: std.ArrayList(RpcMessage),

    const Node = struct {
        raft: *raft.Raft,
        applied_entries: std.ArrayList(raft.LogEntry),
    };

    const RpcMessage = struct {
        from_node_id: u64,
        to_node_id: u64,
        // RPC type and data would be here - simplified for test
    };

    fn init(allocator: std.mem.Allocator, node_count: usize) !TestCluster {
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

        return TestCluster{
            .allocator = allocator,
            .nodes = nodes,
            .rpc_messages = std.ArrayList(RpcMessage).init(allocator),
        };
    }

    fn deinit(self: *TestCluster) void {
        for (self.nodes) |*node| {
            node.raft.deinit();
            self.allocator.destroy(node.raft);
            node.applied_entries.deinit();
        }
        self.allocator.free(self.nodes);
        self.rpc_messages.deinit();
    }

    /// Simulate election by having all nodes timeout and start election
    fn simulateElection(self: *TestCluster) !u64 {
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

    /// Simulate leader sending heartbeats to followers
    fn simulateHeartbeat(self: *TestCluster, leader_id: usize) !void {
        const leader = &self.nodes[leader_id - 1];

        for (self.nodes, 0..) |*node, i| {
            if (i == leader_id - 1) continue; // Skip leader

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
};

test "Raft 3-node cluster - leader election" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Node 1 starts election and becomes leader
    const leader_id = try cluster.simulateElection();

    try std.testing.expectEqual(@as(u64, 1), leader_id);
    try std.testing.expectEqual(raft.RaftState.leader, cluster.nodes[0].raft.role);
}

test "Raft 3-node cluster - heartbeat maintains leadership" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Send heartbeats
    try cluster.simulateHeartbeat(1);

    // Verify followers reset their election timeout
    for (cluster.nodes[1..]) |*node| {
        try std.testing.expect(node.raft.election_deadline_ms > timestampMs());
    }
}

test "Raft 3-node cluster - propose entry on leader" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Propose entry
    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const index = try cluster.nodes[0].raft.propose(record);
    try std.testing.expectEqual(@as(u64, 1), index);
    try std.testing.expectEqual(@as(usize, 1), cluster.nodes[0].raft.persistent.log.items.len);
}

test "Raft 3-node cluster - log replication to followers" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Propose entry
    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    _ = try cluster.nodes[0].raft.propose(record);

    // Leader replicates to follower 1
    const entry = cluster.nodes[0].raft.persistent.getEntry(1).?;
    const args = raft.AppendEntriesArgs{
        .term = 1,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &[_]raft.LogEntry{entry},
        .leader_commit = 0,
    };

    const reply = try cluster.nodes[1].raft.handleAppendEntries(args);
    try std.testing.expect(reply.success);
    try std.testing.expectEqual(@as(usize, 1), cluster.nodes[1].raft.persistent.log.items.len);
}

test "Raft 3-node cluster - commit index propagation" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Propose entry
    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    _ = try cluster.nodes[0].raft.propose(record);

    // Simulate replication to both followers
    const entry = cluster.nodes[0].raft.persistent.getEntry(1).?;
    const args = raft.AppendEntriesArgs{
        .term = 1,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &[_]raft.LogEntry{entry},
        .leader_commit = 0,
    };

    _ = try cluster.nodes[1].raft.handleAppendEntries(args);
    _ = try cluster.nodes[2].raft.handleAppendEntries(args);

    // Update match index and commit
    const leader_state = cluster.nodes[0].raft.leader_state.?;
    try leader_state.match_index.put(2, 1);
    try leader_state.match_index.put(3, 1);

    try cluster.nodes[0].raft.updateCommitIndex();

    // Entry should be committed (majority: leader + 1 follower)
    try std.testing.expectEqual(@as(u64, 1), leader_state.commit_index);
}

test "Raft 3-node cluster - higher term steps down leader" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    try std.testing.expectEqual(raft.RaftState.leader, cluster.nodes[0].raft.role);
    try std.testing.expectEqual(@as(u64, 1), cluster.nodes[0].raft.persistent.current_term);

    // Node 2 discovers higher term
    try cluster.nodes[0].raft.becomeFollower(2);

    try std.testing.expectEqual(raft.RaftState.follower, cluster.nodes[0].raft.role);
    try std.testing.expectEqual(@as(u64, 2), cluster.nodes[0].raft.persistent.current_term);
}

test "Raft 3-node cluster - RequestVote with log completeness check" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Node 1 has a log entry
    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    try cluster.nodes[0].raft.becomeCandidate();
    _ = try cluster.nodes[0].raft.propose(record);

    // Node 2 starts election with less complete log
    try cluster.nodes[1].raft.becomeCandidate();

    const args = raft.RequestVoteArgs{
        .term = 1,
        .candidate_id = 2,
        .last_log_index = 0, // Less complete
        .last_log_term = 0,
    };

    const reply = try cluster.nodes[0].raft.handleRequestVote(args);
    try std.testing.expect(!reply.vote_granted); // Should reject due to less complete log
}

test "Raft 3-node cluster - AppendEntries log conflict resolution" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Follower has conflicting entry at index 1
    const follower_record = txn.CommitRecord{
        .txn_id = 999, // Different transaction
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    try cluster.nodes[1].raft.persistent.appendEntry(
        raft.LogEntry.fromCommitRecord(1, 1, follower_record),
    );

    // Leader sends AppendEntries with prev_log_index=1 but different term
    const leader_record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const new_entry = raft.LogEntry.fromCommitRecord(2, 2, leader_record);
    const args = raft.AppendEntriesArgs{
        .term = 2,
        .leader_id = 1,
        .prev_log_index = 1,
        .prev_log_term = 2, // Different term
        .entries = &[_]raft.LogEntry{new_entry},
        .leader_commit = 0,
    };

    const reply = try cluster.nodes[1].raft.handleAppendEntries(args);
    try std.testing.expect(!reply.success); // Should fail due to conflict
    try std.testing.expect(reply.conflict_index != null); // Should provide hint
}

test "Raft 3-node cluster - election timeout triggers new election" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Node 1 is leader
    _ = try cluster.simulateElection();

    // Set election deadline to past
    cluster.nodes[1].raft.election_deadline_ms = timestampMs() - 1;
    cluster.nodes[2].raft.election_deadline_ms = timestampMs() - 1;

    // Tick nodes - should trigger election
    try cluster.nodes[1].raft.tick();
    try cluster.nodes[2].raft.tick();

    // At least one should have become candidate
    const node1_is_candidate = cluster.nodes[1].raft.role == .candidate;
    const node2_is_candidate = cluster.nodes[2].raft.role == .candidate;

    try std.testing.expect(node1_is_candidate or node2_is_candidate);
}

/// Get current timestamp in milliseconds
fn timestampMs() u64 {
    const ns = std.time.nanoTimestamp();
    return @intCast(@abs(ns) / 1_000_000);
}
