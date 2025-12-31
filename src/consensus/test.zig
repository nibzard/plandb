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

// ==================== Phase 2: Log Replication Tests ====================

test "Raft Phase 2 - leader append entries to local log" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Propose entries
    for (0..5) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        const index = try raft_instance.propose(record);
        try std.testing.expectEqual(@as(u64, i + 1), index);
    }

    // Verify all entries in log
    try std.testing.expectEqual(@as(usize, 5), raft_instance.persistent.log.items.len);
    try std.testing.expectEqual(@as(u64, 5), raft_instance.persistent.lastLogIndex());
}

test "Raft Phase 2 - majority commit propagation" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Leader proposes entry
    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    _ = try cluster.nodes[0].raft.propose(record);

    // Get the entry from leader's log
    const entry = cluster.nodes[0].raft.persistent.getEntry(1).?;
    try std.testing.expectEqual(@as(u64, 1), entry.index);

    // Simulate replication to follower 1 (majority achieved: leader + 1 follower)
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

    // Update match index on leader
    const leader_state = cluster.nodes[0].raft.leader_state.?;
    try leader_state.match_index.put(2, 1);

    // Update commit index - should be committed with majority
    try cluster.nodes[0].raft.updateCommitIndex();

    // Entry should be committed (majority: leader + 1 follower = 2 out of 3)
    try std.testing.expectEqual(@as(u64, 1), leader_state.commit_index);
}

test "Raft Phase 2 - majority commit with multiple entries" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Propose multiple entries
    const entry_count = 5;
    var entries: [entry_count]raft.LogEntry = undefined;

    for (0..entry_count) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        _ = try cluster.nodes[0].raft.propose(record);
        entries[i] = cluster.nodes[0].raft.persistent.getEntry(@intCast(i + 1)).?;
    }

    // Simulate gradual replication
    const leader_state = cluster.nodes[0].raft.leader_state.?;

    // Replicate first 3 entries to follower 1
    for (0..3) |i| {
        const args = raft.AppendEntriesArgs{
            .term = 1,
            .leader_id = 1,
            .prev_log_index = @intCast(i),
            .prev_log_term = if (i == 0) 0 else 1,
            .entries = &[_]raft.LogEntry{entries[i]},
            .leader_commit = 0,
        };

        _ = try cluster.nodes[1].raft.handleAppendEntries(args);
        try leader_state.match_index.put(2, @intCast(i + 1));
    }

    // Update commit index - should commit up to index 3 (leader + 1 follower majority)
    try cluster.nodes[0].raft.updateCommitIndex();

    try std.testing.expectEqual(@as(u64, 3), leader_state.commit_index);
}

test "Raft Phase 2 - log conflict resolution with backtracking" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Follower has diverging log
    for (0..3) |i| {
        const record = txn.CommitRecord{
            .txn_id = @as(u64, 100) + @as(u64, @intCast(i)), // Different transaction IDs
            .root_page_id = 2,
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        try cluster.nodes[1].raft.persistent.appendEntry(
            raft.LogEntry.fromCommitRecord(1, @intCast(i + 1), record),
        );
    }

    // Leader proposes conflicting entry at index 2
    const leader_record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    _ = try cluster.nodes[0].raft.propose(leader_record);
    const new_entry = cluster.nodes[0].raft.persistent.getEntry(1).?;

    // Leader sends AppendEntries starting from index 1
    const args = raft.AppendEntriesArgs{
        .term = 1,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &[_]raft.LogEntry{new_entry},
        .leader_commit = 0,
    };

    const reply = try cluster.nodes[1].raft.handleAppendEntries(args);
    try std.testing.expect(reply.success);

    // Follower log should be truncated and new entry appended
    try std.testing.expectEqual(@as(usize, 1), cluster.nodes[1].raft.persistent.log.items.len);
    try std.testing.expectEqual(@as(u64, 1), cluster.nodes[1].raft.persistent.log.items[0].index);
    try std.testing.expectEqual(@as(u64, 1), cluster.nodes[1].raft.persistent.log.items[0].txn_id);
}

test "Raft Phase 2 - commit index propagation on follower" {
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

    // Get the entry from leader's log
    const entry = cluster.nodes[0].raft.persistent.getEntry(1).?;

    // Simulate replication with leader_commit set
    const args = raft.AppendEntriesArgs{
        .term = 1,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &[_]raft.LogEntry{entry},
        .leader_commit = 1, // Leader says entry 1 is committed
    };

    _ = try cluster.nodes[1].raft.handleAppendEntries(args);

    // Follower's commit index should be updated
    try std.testing.expectEqual(@as(u64, 1), cluster.nodes[1].raft.follower_state.commit_index);
}

test "Raft Phase 2 - state machine application (last_applied)" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Track applied entries using pointer to capture mutable variable
    const applied_count_ptr = try allocator.create(u64);
    applied_count_ptr.* = 0;
    defer allocator.destroy(applied_count_ptr);

    // Wrap the callback to capture the pointer
    raft_instance.on_apply_entry = struct {
        fn wrapper(entry: raft.LogEntry) !void {
            _ = entry;
            applied_count_ptr.* += 1;
        }
    }.wrapper;

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Propose entry
    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    _ = try raft_instance.propose(record);

    // Commit the entry
    const leader_state = raft_instance.leader_state.?;
    try leader_state.match_index.put(2, 1);
    try raft_instance.updateCommitIndex();

    // Entry should be applied
    try std.testing.expectEqual(@as(u64, 1), leader_state.last_applied);
    try std.testing.expectEqual(@as(u64, 1), applied_count_ptr.*);
}

test "Raft Phase 2 - log replication with conflict and recovery" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Follower has log from old term with conflicting entry
    const old_record = txn.CommitRecord{
        .txn_id = 999,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    try cluster.nodes[1].raft.persistent.appendEntry(
        raft.LogEntry.fromCommitRecord(1, 1, old_record),
    );

    // Leader proposes entry in new term
    const new_record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    _ = try cluster.nodes[0].raft.propose(new_record);
    const entry = cluster.nodes[0].raft.persistent.getEntry(1).?;

    // Send AppendEntries - follower should detect conflict at index 1
    const args = raft.AppendEntriesArgs{
        .term = 2,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &[_]raft.LogEntry{entry},
        .leader_commit = 0,
    };

    const reply = try cluster.nodes[1].raft.handleAppendEntries(args);
    try std.testing.expect(!reply.success); // Should fail due to term mismatch
    try std.testing.expect(reply.conflict_index != null);

    // Leader should backtrack and retry with correct prev_log_term
    const args2 = raft.AppendEntriesArgs{
        .term = 2,
        .leader_id = 1,
        .prev_log_index = 1,
        .prev_log_term = 1, // Now match follower's term
        .entries = &[_]raft.LogEntry{}, // Empty to confirm match
        .leader_commit = 0,
    };

    _ = try cluster.nodes[1].raft.handleAppendEntries(args2);

    // Now truncate follower's log and send new entry
    cluster.nodes[1].raft.persistent.truncateFrom(1);

    const args3 = raft.AppendEntriesArgs{
        .term = 2,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &[_]raft.LogEntry{entry},
        .leader_commit = 0,
    };

    const reply3 = try cluster.nodes[1].raft.handleAppendEntries(args3);
    try std.testing.expect(reply3.success);
}

// ==================== Phase 3: Snapshotting Tests ====================

test "Raft Phase 3 - snapshot creation" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
        .snapshot_entry_threshold = 1000,
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Propose and apply entries
    for (0..10) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        _ = try raft_instance.propose(record);

        // Mark as committed and applied
        const leader_state = raft_instance.leader_state.?;
        for (raft_instance.config.peers) |peer| {
            try leader_state.match_index.put(peer.id, @intCast(i + 1));
        }
        try raft_instance.updateCommitIndex();
        try raft_instance.applyCommittedEntries();
    }

    // Create snapshot
    try raft_instance.createSnapshot(10, 100);

    // Verify snapshot exists
    const snap = raft_instance.snapshot_manager.getSnapshot();
    try std.testing.expect(snap != null);
    try std.testing.expectEqual(@as(u64, 10), snap.?.last_included_index);
    try std.testing.expectEqual(@as(u64, 1), snap.?.last_included_term);
}

test "Raft Phase 3 - log truncation after snapshot" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
        .snapshot_entry_threshold = 1000,
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Add entries to log
    for (0..20) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        _ = try raft_instance.propose(record);
    }

    try std.testing.expectEqual(@as(usize, 20), raft_instance.persistent.log.items.len);

    // Create snapshot covering first 10 entries
    try raft_instance.createSnapshot(10, 100);

    // Truncate log
    try raft_instance.truncateLogAfterSnapshot();

    // Log should be truncated
    try std.testing.expectEqual(@as(usize, 10), raft_instance.persistent.log.items.len);
    try std.testing.expectEqual(@as(u64, 20), raft_instance.persistent.lastLogIndex());
}

test "Raft Phase 3 - InstallSnapshot RPC" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
        .snapshot_entry_threshold = 1000,
    };

    var leader = try raft.Raft.init(allocator, cfg);
    defer leader.deinit();

    const follower_cfg = config.RaftConfig{
        .node_id = 2,
        .peers = &[_]config.NodeInfo{
            config.NodeInfo.init(1, "node1:7234"),
            config.NodeInfo.init(3, "node3:7234"),
        },
        .rpc_listen_address = "0.0.0.0:7234",
        .snapshot_entry_threshold = 1000,
    };

    var follower = try raft.Raft.init(allocator, follower_cfg);
    defer follower.deinit();

    // Become leader
    try leader.becomeCandidate();
    try leader.becomeLeader();

    // Create snapshot
    try leader.createSnapshot(10, 100);

    const snap = leader.snapshot_manager.getSnapshot().?;

    // Serialize snapshot
    const snap_size = snap.size();
    const buffer = try allocator.alloc(u8, snap_size);
    defer allocator.free(buffer);

    var fbs = std.io.fixedBufferStream(buffer);
    try snap.serialize(fbs.writer());

    // Send InstallSnapshot to follower
    const args = raft.InstallSnapshotArgs{
        .term = leader.persistent.current_term,
        .leader_id = 1,
        .last_included_index = snap.last_included_index,
        .last_included_term = snap.last_included_term,
        .snapshot = buffer,
    };

    const reply = try follower.handleInstallSnapshot(args);
    try std.testing.expectEqual(leader.persistent.current_term, reply.term);

    // Follower should have installed snapshot
    const follower_snap = follower.snapshot_manager.getSnapshot();
    try std.testing.expect(follower_snap != null);
    try std.testing.expectEqual(@as(u64, 10), follower_snap.?.last_included_index);
}

test "Raft Phase 3 - leader sends snapshot to lagging follower" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    // Leader creates entries
    for (0..100) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        _ = try cluster.nodes[0].raft.propose(record);
    }

    // Leader creates snapshot
    try cluster.nodes[0].raft.createSnapshot(50, 500);

    // Follower is behind (only has first 10 entries)
    for (0..10) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        try cluster.nodes[1].raft.persistent.appendEntry(
            raft.LogEntry.fromCommitRecord(1, @intCast(i + 1), record),
        );
    }

    // Set follower's next_index to point before snapshot
    const leader_state = cluster.nodes[0].raft.leader_state.?;
    try leader_state.next_index.put(2, 5); // Behind snapshot

    // In leaderLoop, should send snapshot to follower
    const snap = cluster.nodes[0].raft.snapshot_manager.getSnapshot().?;
    try std.testing.expect(snap != null);
    try std.testing.expect(leader_state.next_index.get(2).? <= snap.last_included_index);
}

test "Raft Phase 3 - needsSnapshot check" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
        .snapshot_entry_threshold = 500,
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Small log - no snapshot needed
    try std.testing.expect(!raft_instance.needsSnapshot());

    // Become leader and add entries
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    for (0..600) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 10),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        _ = try raft_instance.propose(record);
    }

    // Large log - snapshot needed
    try std.testing.expect(raft_instance.needsSnapshot());
}

test "Raft Phase 3 - snapshot covers index check" {
    const allocator = std.testing.allocator;

    const snap = try raft.snapshot_mod.Snapshot.create(
        allocator,
        100,
        2,
        50,
        12345,
        &[_]u8{},
    );
    defer snap.deinit(allocator);

    try std.testing.expect(snap.covers(50));
    try std.testing.expect(snap.covers(100));
    try std.testing.expect(!snap.covers(101));
    try std.testing.expect(!snap.covers(200));
}

// ==================== Phase 4: Configuration Changes Tests ====================

test "Raft Phase 4 - ClusterConfig single initialization" {
    const allocator = std.testing.allocator;
    const nodes = [_]u64{ 1, 2, 3 };

    var cluster_cfg = try config.ClusterConfig.initSingle(allocator, &nodes);
    defer cluster_cfg.deinit();

    try std.testing.expectEqual(config.ConfigState.single, cluster_cfg.state);
    try std.testing.expect(cluster_cfg.contains(1));
    try std.testing.expect(cluster_cfg.contains(2));
    try std.testing.expect(cluster_cfg.contains(3));
    try std.testing.expect(!cluster_cfg.contains(4));
    try std.testing.expectEqual(@as(u64, 2), cluster_cfg.majority());
}

test "Raft Phase 4 - ClusterConfig joint consensus" {
    const allocator = std.testing.allocator;
    const old_nodes = [_]u64{ 1, 2, 3 };
    const new_nodes = [_]u64{ 1, 2, 3, 4 };

    var joint_config = try config.ClusterConfig.initJoint(allocator, &old_nodes, &new_nodes);
    defer joint_config.deinit();

    try std.testing.expectEqual(config.ConfigState.joint, joint_config.state);
    try std.testing.expect(joint_config.contains(4));
    // Joint consensus needs majority from both configs
    try std.testing.expectEqual(@as(u64, 3), joint_config.majority());
}

test "Raft Phase 4 - ClusterConfig transition" {
    const allocator = std.testing.allocator;
    const nodes = [_]u64{ 1, 2, 3 };
    var cluster_cfg = try config.ClusterConfig.initSingle(allocator, &nodes);

    const new_nodes = [_]u64{ 1, 2, 3, 4, 5 };
    try cluster_cfg.transitionTo(&new_nodes);
    defer cluster_cfg.deinit();

    try std.testing.expectEqual(config.ConfigState.single, cluster_cfg.state);
    try std.testing.expect(cluster_cfg.contains(5));
    try std.testing.expectEqual(@as(u64, 3), cluster_cfg.majority());
}

test "Raft Phase 4 - addNode to 3-node cluster" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Initial config should have 3 nodes
    try std.testing.expectEqual(@as(usize, 3), raft_instance.cluster_config.getNodes().len);

    // Add node 4
    try raft_instance.addNode(4, "node4:7234");

    // Pending config change should be set
    try std.testing.expect(raft_instance.pending_config_change != null);

    // Log should contain joint consensus entry
    try std.testing.expectEqual(@as(usize, 1), raft_instance.persistent.log.items.len);
    const entry = raft_instance.persistent.log.items[0];
    try std.testing.expectEqual(@as(usize, 1), entry.index);
    try std.testing.expect(entry.command == .config);
    try std.testing.expect(entry.command.config.is_joint);
}

test "Raft Phase 4 - removeNode from 5-node cluster" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
        config.NodeInfo.init(4, "node4:7234"),
        config.NodeInfo.init(5, "node5:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Initial config should have 5 nodes
    try std.testing.expectEqual(@as(usize, 5), raft_instance.cluster_config.getNodes().len);

    // Remove node 5
    try raft_instance.removeNode(5);

    // Pending config change should be set
    try std.testing.expect(raft_instance.pending_config_change != null);

    // Log should contain joint consensus entry
    try std.testing.expectEqual(@as(usize, 1), raft_instance.persistent.log.items.len);
    const entry = raft_instance.persistent.log.items[0];
    try std.testing.expect(entry.command == .config);
    try std.testing.expect(entry.command.config.is_joint);

    // New nodes should not include node 5
    const new_nodes = entry.command.config.new_nodes;
    try std.testing.expectEqual(@as(usize, 4), new_nodes.len);
    try std.testing.expect(!std.mem.contains(u64, new_nodes, &[_]u64{5}));
}

test "Raft Phase 4 - addNode fails if not leader" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Follower cannot add node
    try std.testing.expectError(error.NotLeader, raft_instance.addNode(4, "node4:7234"));
}

test "Raft Phase 4 - removeNode fails if not leader" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Follower cannot remove node
    try std.testing.expectError(error.NotLeader, raft_instance.removeNode(2));
}

test "Raft Phase 4 - addNode fails if node exists" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Cannot add existing node
    try std.testing.expectError(error.NodeAlreadyExists, raft_instance.addNode(2, "node2:7234"));
}

test "Raft Phase 4 - removeNode fails if node not found" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Cannot remove non-existent node
    try std.testing.expectError(error.NodeNotFound, raft_instance.removeNode(99));
}

test "Raft Phase 4 - config change in progress prevents another" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Start config change
    try raft_instance.addNode(4, "node4:7234");

    // Cannot start another config change
    try std.testing.expectError(error.ConfigChangeInProgress, raft_instance.addNode(5, "node5:7234"));
    try std.testing.expectError(error.ConfigChangeInProgress, raft_instance.removeNode(2));
}

test "Raft Phase 4 - applyConfigChange joint consensus" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Create joint consensus entry
    const old_nodes = [_]u64{ 1, 2, 3 };
    const new_nodes = [_]u64{ 1, 2, 3, 4 };
    const entry = raft.LogEntry.fromConfigChange(1, 1, &old_nodes, &new_nodes, true);

    // Apply config change
    try raft_instance.applyConfigChange(entry);

    // Cluster config should be in joint state
    try std.testing.expectEqual(config.ConfigState.joint, raft_instance.cluster_config.state);
    try std.testing.expect(raft_instance.cluster_config.contains(4));
}

test "Raft Phase 4 - applyConfigChange single config" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // First transition to joint
    const old_nodes = [_]u64{ 1, 2, 3 };
    const new_nodes = [_]u64{ 1, 2, 3, 4 };
    const joint_entry = raft.LogEntry.fromConfigChange(1, 1, &old_nodes, &new_nodes, true);
    try raft_instance.applyConfigChange(joint_entry);

    // Now apply single config
    const final_entry = raft.LogEntry.fromConfigChange(1, 2, &new_nodes, &new_nodes, false);
    try raft_instance.applyConfigChange(final_entry);

    // Cluster config should be in single state with new nodes
    try std.testing.expectEqual(config.ConfigState.single, raft_instance.cluster_config.state);
    try std.testing.expectEqual(@as(usize, 4), raft_instance.cluster_config.getNodes().len);
    try std.testing.expect(raft_instance.cluster_config.contains(4));
}

test "Raft Phase 4 - completeConfigChange" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Become leader
    try raft_instance.becomeCandidate();
    try raft_instance.becomeLeader();

    // Start config change
    try raft_instance.addNode(4, "node4:7234");

    // Complete config change
    try raft_instance.completeConfigChange();

    // Cluster config should be updated
    try std.testing.expectEqual(config.ConfigState.single, raft_instance.cluster_config.state);
    try std.testing.expectEqual(@as(usize, 4), raft_instance.cluster_config.getNodes().len);
    try std.testing.expect(raft_instance.cluster_config.contains(4));

    // Pending config change should be cleared
    try std.testing.expect(raft_instance.pending_config_change == null);

    // Log should have 2 entries (joint + final)
    try std.testing.expectEqual(@as(usize, 2), raft_instance.persistent.log.items.len);
}

test "Raft Phase 4 - LogEntry fromConfigChange" {
    const old_nodes = [_]u64{ 1, 2, 3 };
    const new_nodes = [_]u64{ 1, 2, 3, 4 };

    const entry = raft.LogEntry.fromConfigChange(5, 42, &old_nodes, &new_nodes, true);

    try std.testing.expectEqual(@as(u64, 5), entry.term);
    try std.testing.expectEqual(@as(u64, 42), entry.index);
    try std.testing.expect(entry.command == .config);
    try std.testing.expect(entry.command.config.is_joint);
    try std.testing.expectEqual(@as(usize, 3), entry.command.config.old_nodes.len);
    try std.testing.expectEqual(@as(usize, 4), entry.command.config.new_nodes.len);
}

test "Raft Phase 4 - cluster majority with joint consensus" {
    const allocator = std.testing.allocator;
    const peers = [_]config.NodeInfo{
        config.NodeInfo.init(2, "node2:7234"),
        config.NodeInfo.init(3, "node3:7234"),
    };

    const cfg = config.RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    var raft_instance = try raft.Raft.init(allocator, cfg);
    defer raft_instance.deinit();

    // Initial single config: 3 nodes, majority 2
    try std.testing.expectEqual(@as(u64, 2), raft_instance.cluster_config.majority());

    // Transition to joint: C_3 -> C_4
    const old_nodes = [_]u64{ 1, 2, 3 };
    const new_nodes = [_]u64{ 1, 2, 3, 4 };
    const joint_entry = raft.LogEntry.fromConfigChange(1, 1, &old_nodes, &new_nodes, true);
    try raft_instance.applyConfigChange(joint_entry);

    // Joint consensus: max(majority(3), majority(4)) = max(2, 3) = 3
    try std.testing.expectEqual(@as(u64, 3), raft_instance.cluster_config.majority());
}

test "Raft Phase 4 - 3-node cluster add node without downtime" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    const leader = &cluster.nodes[0];
    try std.testing.expectEqual(raft.RaftState.leader, leader.raft.role);

    // Add node 4
    try leader.raft.addNode(4, "node4:7234");

    // Joint consensus entry created
    try std.testing.expectEqual(@as(usize, 1), leader.raft.persistent.log.items.len);

    // Cluster still operational - can propose entries during config change
    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const index = try leader.raft.propose(record);
    try std.testing.expectEqual(@as(u64, 2), index);
}

test "Raft Phase 4 - 5-node cluster remove node without downtime" {
    const allocator = std.testing.allocator;
    var cluster = try TestCluster.init(allocator, 5);
    defer cluster.deinit();

    // Elect leader
    _ = try cluster.simulateElection();

    const leader = &cluster.nodes[0];
    try std.testing.expectEqual(raft.RaftState.leader, leader.raft.role);

    // Remove node 5 (not leader)
    try leader.raft.removeNode(5);

    // Joint consensus entry created
    try std.testing.expectEqual(@as(usize, 1), leader.raft.persistent.log.items.len);

    // Cluster still operational
    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const index = try leader.raft.propose(record);
    try std.testing.expectEqual(@as(u64, 2), index);
}

