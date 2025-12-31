//! Raft consensus benchmark suite per spec/raft_v1.md Phase 5.
//!
//! Benchmarks:
//! - Leader election latency
//! - Write throughput (committed)
//! - Write latency (end-to-end)
//! - Read latency (follower)
//! - Snapshot creation/install performance
//! - Recovery time after failure

const std = @import("std");
const types = @import("types.zig");
const raft = @import("../consensus/raft.zig");
const config = @import("../consensus/config.zig");
const txn = @import("../txn.zig");

/// Test cluster for Raft benchmarks
const TestCluster = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    leader_id: u64 = 0,

    const Node = struct {
        raft: *raft.Raft,
        applied_count: u64 = 0,
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
        }

        return TestCluster{
            .allocator = allocator,
            .nodes = nodes,
        };
    }

    fn deinit(self: *TestCluster) void {
        for (self.nodes) |*node| {
            node.raft.deinit();
            self.allocator.destroy(node.raft);
        }
        self.allocator.free(self.nodes);
    }

    /// Elect first node as leader
    fn electLeader(self: *TestCluster) !void {
        // First node becomes candidate
        try self.nodes[0].raft.becomeCandidate();

        // Simulate other nodes granting votes
        for (self.nodes[1..]) |*node| {
            const args = raft.RequestVoteArgs{
                .term = 1,
                .candidate_id = 1,
                .last_log_index = 0,
                .last_log_term = 0,
            };

            const reply = try node.raft.handleRequestVote(args);
            if (reply.vote_granted) {
                try self.nodes[0].raft.handleRequestVoteReply(
                    node.raft.config.node_id,
                    args,
                    reply,
                );
            }
        }

        // Transition to leader
        try self.nodes[0].raft.becomeLeader();
        self.leader_id = 1;
    }

    /// Simulate log replication from leader to follower
    fn replicateToFollowers(self: *TestCluster) !void {
        if (self.leader_id == 0) return error.NotLeader;

        const leader_idx = @as(usize, @intCast(self.leader_id - 1));
        const leader = self.nodes[leader_idx].raft;

        const leader_state = leader.leader_state orelse return error.NotLeader;

        for (self.nodes, 0..) |*node, i| {
            if (i == leader_idx) continue;

            const next_idx = leader_state.next_index.get(node.raft.config.node_id) orelse 1;

            // Collect entries to send
            var entries_list = std.array_list.Managed(raft.LogEntry).init(self.allocator);
            defer entries_list.deinit();

            var idx: u64 = next_idx;
            while (idx <= leader.persistent.lastLogIndex()) : (idx += 1) {
                if (leader.persistent.getEntry(idx)) |entry| {
                    try entries_list.append(entry);
                }
            }

            const prev_idx = if (next_idx > 1) next_idx - 1 else 0;
            const prev_entry = leader.persistent.getEntry(prev_idx);
            const prev_term = if (prev_entry) |e| e.term else 0;

            const args = raft.AppendEntriesArgs{
                .term = leader.persistent.current_term,
                .leader_id = leader.config.node_id,
                .prev_log_index = prev_idx,
                .prev_log_term = prev_term,
                .entries = entries_list.items,
                .leader_commit = leader_state.commit_index,
            };

            const reply = try node.raft.handleAppendEntries(args);
            _ = try leader.handleAppendEntriesReply(
                node.raft.config.node_id,
                args,
                reply,
            );
        }
    }
};

// ==================== Leader Election Benchmarks ====================

pub fn benchRaftLeaderElection(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Measure time from start to leader elected
    var timer = try std.time.Timer.start();
    const start_ns = timer.lap();

    try cluster.electLeader();

    const end_ns = timer.read();
    const duration_ns = end_ns - start_ns;

    // Verify leader elected
    std.debug.assert(cluster.nodes[0].raft.role == .leader);

    return types.Results{
        .ops_total = 1, // 1 election
        .duration_ns = duration_ns,
        .ops_per_sec = @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(duration_ns)),
        .latency_ns = .{
            .p50 = duration_ns,
            .p95 = duration_ns,
            .p99 = duration_ns,
            .max = duration_ns,
        },
        .bytes = .{
            .read_total = 0,
            .write_total = 1024, // Approx
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = 0,
            .alloc_bytes = 0,
        },
        .notes = null,
    };
}

pub fn benchRaftLeaderElectionRepeated(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const iterations = 100;
    var latencies = std.array_list.Managed(u64).init(allocator);
    defer latencies.deinit();

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    for (0..iterations) |_| {
        // Reset all nodes to follower
        for (cluster.nodes) |*node| {
            try node.raft.becomeFollower(0);
        }

        var timer = try std.time.Timer.start();
        const start_ns = timer.lap();

        try cluster.electLeader();

        const end_ns = timer.read();
        try latencies.append(end_ns - start_ns);
    }

    // Calculate percentiles
    std.sort.insertion(u64, latencies.items, {}, comptime std.sort.asc(u64));
    const p50_idx = latencies.items.len / 2;
    const p95_idx = latencies.items.len * 95 / 100;
    const p99_idx = latencies.items.len * 99 / 100;

    return types.Results{
        .ops_total = iterations,
        .duration_ns = 0, // Not meaningful for repeated
        .ops_per_sec = 0,
        .latency_ns = .{
            .p50 = latencies.items[p50_idx],
            .p95 = latencies.items[p95_idx],
            .p99 = latencies.items[p99_idx],
            .max = latencies.items[latencies.items.len - 1],
        },
        .bytes = .{
            .read_total = 0,
            .write_total = 0,
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = 0,
            .alloc_bytes = 0,
        },
        .notes = null,
    };
}

// ==================== Write Throughput Benchmarks ====================

pub fn benchRaftWriteThroughputSingleLeader(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const entry_count = 10000;
    var cluster = try TestCluster.init(allocator, 5);
    defer cluster.deinit();

    try cluster.electLeader();
    const leader = cluster.nodes[0].raft;

    var timer = try std.time.Timer.start();
    const start_ns = timer.lap();

    // Propose entries
    for (0..entry_count) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 100),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };
        _ = try leader.propose(record);
    }

    // Simulate replication to majority
    var leader_state = leader.leader_state.?;
    for (cluster.nodes[1..3]) |*node| { // Replicate to 2 followers (majority)
        try leader_state.match_index.put(node.raft.config.node_id, entry_count);
    }
    try leader.updateCommitIndex();

    const end_ns = timer.read();
    const duration_ns = end_ns - start_ns;

    return types.Results{
        .ops_total = entry_count,
        .duration_ns = duration_ns,
        .ops_per_sec = (@as(f64, @floatFromInt(entry_count)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
            @as(f64, @floatFromInt(duration_ns)),
        .latency_ns = .{
            .p50 = duration_ns / entry_count,
            .p95 = duration_ns / entry_count,
            .p99 = duration_ns / entry_count,
            .max = duration_ns / entry_count,
        },
        .bytes = .{
            .read_total = 0,
            .write_total = entry_count * 128, // Approx entry size
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = entry_count,
            .alloc_bytes = entry_count * 256,
        },
        .notes = null,
    };
}

pub fn benchRaftWriteThroughputBatched(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const batch_size = 100;
    const batch_count = 100;
    const total_entries = batch_size * batch_count;

    var cluster = try TestCluster.init(allocator, 5);
    defer cluster.deinit();

    try cluster.electLeader();
    const leader = cluster.nodes[0].raft;

    var timer = try std.time.Timer.start();
    const start_ns = timer.lap();

    // Propose entries in batches
    for (0..batch_count) |batch| {
        for (0..batch_size) |i| {
            const idx = batch * batch_size + i;
            const record = txn.CommitRecord{
                .txn_id = @intCast(idx + 1),
                .root_page_id = @intCast(idx + 100),
                .mutations = &[_]txn.Mutation{},
                .checksum = 0,
            };
            _ = try leader.propose(record);
        }

        // Simulate batch replication
        var leader_state = leader.leader_state.?;
        for (cluster.nodes[1..3]) |*node| {
            try leader_state.match_index.put(node.raft.config.node_id, (batch + 1) * batch_size);
        }
        try leader.updateCommitIndex();
    }

    const end_ns = timer.read();
    const duration_ns = end_ns - start_ns;

    return types.Results{
        .ops_total = total_entries,
        .duration_ns = duration_ns,
        .ops_per_sec = (@as(f64, @floatFromInt(total_entries)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
            @as(f64, @floatFromInt(duration_ns)),
        .latency_ns = .{
            .p50 = duration_ns / total_entries,
            .p95 = duration_ns / total_entries,
            .p99 = duration_ns / total_entries,
            .max = duration_ns / total_entries,
        },
        .bytes = .{
            .read_total = 0,
            .write_total = total_entries * 128,
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = total_entries,
            .alloc_bytes = total_entries * 256,
        },
        .notes = null,
    };
}

// ==================== Write Latency Benchmarks ====================

pub fn benchRaftWriteLatencyEndToEnd(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const iterations = 1000;
    var latencies = std.array_list.Managed(u64).init(allocator);
    defer latencies.deinit();

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    try cluster.electLeader();

    for (0..iterations) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 100),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };

        var timer = try std.time.Timer.start();
        const start_ns = timer.lap();

        // Propose entry
        _ = try cluster.nodes[0].raft.propose(record);

        // Simulate replication to majority (1 follower)
        var leader_state = cluster.nodes[0].raft.leader_state.?;
        try leader_state.match_index.put(2, i + 1);
        try cluster.nodes[0].raft.updateCommitIndex();

        const end_ns = timer.read();
        try latencies.append(end_ns - start_ns);
    }

    // Calculate percentiles
    std.sort.insertion(u64, latencies.items, {}, comptime std.sort.asc(u64));
    const p50_idx = latencies.items.len / 2;
    const p95_idx = latencies.items.len * 95 / 100;
    const p99_idx = latencies.items.len * 99 / 100;

    return types.Results{
        .ops_total = iterations,
        .duration_ns = 0,
        .ops_per_sec = 0,
        .latency_ns = .{
            .p50 = latencies.items[p50_idx],
            .p95 = latencies.items[p95_idx],
            .p99 = latencies.items[p99_idx],
            .max = latencies.items[latencies.items.len - 1],
        },
        .bytes = .{
            .read_total = 0,
            .write_total = iterations * 128,
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = iterations,
            .alloc_bytes = iterations * 256,
        },
        .notes = null,
    };
}

// ==================== Read Latency Benchmarks ====================

pub fn benchRaftReadLatencyFollower(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const iterations = 10000;
    var latencies = std.array_list.Managed(u64).init(allocator);
    defer latencies.deinit();

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    try cluster.electLeader();

    // Write some entries
    for (0..100) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 100),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };
        _ = try cluster.nodes[0].raft.propose(record);
    }

    // Replicate to followers
    try cluster.replicateToFollowers();

    const follower = &cluster.nodes[1];

    // Measure read latency from follower
    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();
        const start_ns = timer.lap();

        // Read from follower's log (simulates local read)
        _ = follower.raft.persistent.getEntry(@intCast(@mod(std.time.nanoTimestamp(), 100) + 1));

        const end_ns = timer.read();
        try latencies.append(end_ns - start_ns);
    }

    // Calculate percentiles
    std.sort.insertion(u64, latencies.items, {}, comptime std.sort.asc(u64));
    const p50_idx = latencies.items.len / 2;
    const p95_idx = latencies.items.len * 95 / 100;
    const p99_idx = latencies.items.len * 99 / 100;

    return types.Results{
        .ops_total = iterations,
        .duration_ns = 0,
        .ops_per_sec = 0,
        .latency_ns = .{
            .p50 = latencies.items[p50_idx],
            .p95 = latencies.items[p95_idx],
            .p99 = latencies.items[p99_idx],
            .max = latencies.items[latencies.items.len - 1],
        },
        .bytes = .{
            .read_total = iterations * 64,
            .write_total = 0,
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = 0,
            .alloc_bytes = 0,
        },
        .notes = null,
    };
}

// ==================== Snapshot Benchmarks ====================

pub fn benchRaftSnapshotCreation(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const entry_count = 100000;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    try cluster.electLeader();
    const leader = cluster.nodes[0].raft;

    // Create entries to snapshot
    for (0..entry_count) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 100),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };
        _ = try leader.propose(record);
    }

    // Mark as applied
    var leader_state = leader.leader_state.?;
    for (cluster.nodes[1..]) |*node| {
        try leader_state.match_index.put(node.raft.config.node_id, entry_count);
    }
    try leader.updateCommitIndex();
    leader_state.last_applied = entry_count;

    // Measure snapshot creation
    var timer = try std.time.Timer.start();
    const start_ns = timer.lap();

    try leader.createSnapshot(entry_count, 100000);

    const end_ns = timer.read();
    const duration_ns = end_ns - start_ns;

    const snap = leader.snapshot_manager.getSnapshot();

    return types.Results{
        .ops_total = 1,
        .duration_ns = duration_ns,
        .ops_per_sec = 0,
        .latency_ns = .{
            .p50 = duration_ns,
            .p95 = duration_ns,
            .p99 = duration_ns,
            .max = duration_ns,
        },
        .bytes = .{
            .read_total = if (snap) |s| s.size() else 0,
            .write_total = if (snap) |s| s.size() else 0,
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = 1,
            .alloc_bytes = if (snap) |s| s.size() else 0,
        },
        .notes = null,
    };
}

pub fn benchRaftSnapshotInstall(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const entry_count = 100000;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    try cluster.electLeader();
    const leader = cluster.nodes[0].raft;
    const follower = &cluster.nodes[1];

    // Create entries and snapshot on leader
    for (0..entry_count) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 100),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };
        _ = try leader.propose(record);
    }

    var leader_state = leader.leader_state.?;
    for (cluster.nodes[1..]) |*node| {
        try leader_state.match_index.put(node.raft.config.node_id, entry_count);
    }
    try leader.updateCommitIndex();
    leader_state.last_applied = entry_count;

    try leader.createSnapshot(entry_count, 100000);
    const snap = leader.snapshot_manager.getSnapshot().?;

    // Serialize snapshot
    const snap_size = snap.size();
    const buffer = try allocator.alloc(u8, snap_size);
    defer allocator.free(buffer);

    var fbs = std.io.fixedBufferStream(buffer);
    try snap.serialize(fbs.writer());

    // Measure snapshot install on follower
    var timer = try std.time.Timer.start();
    const start_ns = timer.lap();

    const args = raft.InstallSnapshotArgs{
        .term = leader.persistent.current_term,
        .leader_id = leader.config.node_id,
        .last_included_index = snap.last_included_index,
        .last_included_term = snap.last_included_term,
        .snapshot = buffer,
    };

    _ = try follower.raft.handleInstallSnapshot(args);

    const end_ns = timer.read();
    const duration_ns = end_ns - start_ns;

    return types.Results{
        .ops_total = 1,
        .duration_ns = duration_ns,
        .ops_per_sec = 0,
        .latency_ns = .{
            .p50 = duration_ns,
            .p95 = duration_ns,
            .p99 = duration_ns,
            .max = duration_ns,
        },
        .bytes = .{
            .read_total = snap_size,
            .write_total = snap_size,
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = 1,
            .alloc_bytes = snap_size,
        },
        .notes = null,
    };
}

// ==================== Recovery Benchmarks ====================

pub fn benchRaftRecoveryTime(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const entry_count = 10000;

    var cluster = try TestCluster.init(allocator, 5);
    defer cluster.deinit();

    try cluster.electLeader();
    const leader = cluster.nodes[0].raft;

    // Create entries
    for (0..entry_count) |i| {
        const record = txn.CommitRecord{
            .txn_id = @intCast(i + 1),
            .root_page_id = @intCast(i + 100),
            .mutations = &[_]txn.Mutation{},
            .checksum = 0,
        };
        _ = try leader.propose(record);
    }

    // Replicate to all followers
    try cluster.replicateToFollowers();

    // Simulate node 3 failure and recovery
    const failed_node = &cluster.nodes[2];

    // Node becomes follower with higher term (simulating crash recovery)
    try failed_node.raft.becomeFollower(leader.persistent.current_term + 1);

    var timer = try std.time.Timer.start();
    const start_ns = timer.lap();

    // Node discovers current leader and catches up
    failed_node.raft.current_leader_id = leader.config.node_id;
    failed_node.raft.resetElectionTimeout();

    // Simulate log catchup
    const catchup_count = @as(u64, @intCast(leader.persistent.lastLogIndex()));
    for (0..catchup_count) |i| {
        if (leader.persistent.getEntry(i + 1)) |entry| {
            try failed_node.raft.persistent.appendEntry(entry);
        }
    }

    const end_ns = timer.read();
    const duration_ns = end_ns - start_ns;

    return types.Results{
        .ops_total = catchup_count,
        .duration_ns = duration_ns,
        .ops_per_sec = (@as(f64, @floatFromInt(catchup_count)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
            @as(f64, @floatFromInt(duration_ns)),
        .latency_ns = .{
            .p50 = duration_ns / catchup_count,
            .p95 = duration_ns / catchup_count,
            .p99 = duration_ns / catchup_count,
            .max = duration_ns,
        },
        .bytes = .{
            .read_total = catchup_count * 128,
            .write_total = catchup_count * 128,
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = catchup_count,
            .alloc_bytes = catchup_count * 256,
        },
        .notes = null,
    };
}

// ==================== Heartbeat Benchmarks ====================

pub fn benchRaftHeartbeatOverhead(allocator: std.mem.Allocator, cfg: types.Config) anyerror!types.Results {
    _ = cfg;
    const heartbeat_count = 1000;

    var cluster = try TestCluster.init(allocator, 5);
    defer cluster.deinit();

    try cluster.electLeader();
    _ = cluster.nodes[0].raft; // Leader is implicit in replicateToFollowers

    var timer = try std.time.Timer.start();
    const start_ns = timer.lap();

    // Send heartbeats
    for (0..heartbeat_count) |_| {
        try cluster.replicateToFollowers();
    }

    const end_ns = timer.read();
    const duration_ns = end_ns - start_ns;

    return types.Results{
        .ops_total = heartbeat_count * 4, // 4 followers per heartbeat
        .duration_ns = duration_ns,
        .ops_per_sec = (@as(f64, @floatFromInt(heartbeat_count * 4)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
            @as(f64, @floatFromInt(duration_ns)),
        .latency_ns = .{
            .p50 = duration_ns / (heartbeat_count * 4),
            .p95 = duration_ns / (heartbeat_count * 4),
            .p99 = duration_ns / (heartbeat_count * 4),
            .max = duration_ns,
        },
        .bytes = .{
            .read_total = 0,
            .write_total = heartbeat_count * 256, // Empty heartbeat size
        },
        .io = .{
            .fsync_count = 0,
        },
        .alloc = .{
            .alloc_count = 0,
            .alloc_bytes = 0,
        },
        .notes = null,
    };
}
