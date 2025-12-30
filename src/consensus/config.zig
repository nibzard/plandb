//! Raft configuration types.
//!
//! Defines configuration for Raft consensus per spec/raft_v1.md.

const std = @import("std");

/// Node role in Raft cluster
pub const NodeRole = enum {
    follower,  // Default role, receives replicated log
    candidate,  // Transient role during election
    leader,    // Accepts writes, replicates log
};

/// Node information for cluster membership
pub const NodeInfo = struct {
    id: u64,
    address: []const u8, // Host:port

    pub fn init(id: u64, address: []const u8) NodeInfo {
        return .{
            .id = id,
            .address = address,
        };
    }
};

/// Cluster configuration
pub const ClusterConfig = struct {
    nodes: []const u64, // Node IDs

    /// Get majority count (quorum)
    pub fn majority(self: @This()) u64 {
        return @divTrunc(self.nodes.len, 2) + 1;
    }

    /// Check if node ID is in cluster
    pub fn contains(self: @This(), node_id: u64) bool {
        for (self.nodes) |id| {
            if (id == node_id) return true;
        }
        return false;
    }
};

/// Raft configuration
pub const RaftConfig = struct {
    /// This node's ID
    node_id: u64,

    /// Cluster peers (excluding self)
    peers: []const NodeInfo,

    /// Timing configuration
    election_timeout_min_ms: u64 = 150,
    election_timeout_max_ms: u64 = 300,
    heartbeat_interval_ms: u64 = 50,

    /// Snapshot thresholds
    snapshot_entry_threshold: u64 = 10_000,
    snapshot_size_threshold: u64 = 100 * 1024 * 1024, // 100MB

    /// RPC listen address
    rpc_listen_address: []const u8,

    /// Create Raft config
    pub fn init(
        allocator: std.mem.Allocator,
        node_id: u64,
        peers: []const NodeInfo,
        rpc_listen_address: []const u8,
    ) !RaftConfig {
        // Copy peer addresses to allocator-owned memory
        const owned_peers = try allocator.dupe(NodeInfo, peers);
        errdefer allocator.free(owned_peers);

        for (owned_peers, 0..) |*peer, i| {
            peer.address = try allocator.dupe(u8, peer.address);
            errdefer {
                // Cleanup previous allocations on error
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    allocator.free(owned_peers[j].address);
                }
            }
        }

        return RaftConfig{
            .node_id = node_id,
            .peers = owned_peers,
            .rpc_listen_address = try allocator.dupe(u8, rpc_listen_address),
        };
    }

    /// Get cluster node IDs (self + peers)
    pub fn getClusterNodes(self: @This(), allocator: std.mem.Allocator) ![]const u64 {
        const nodes = try allocator.alloc(u64, self.peers.len + 1);
        nodes[0] = self.node_id;
        for (self.peers, 0..) |peer, i| {
            nodes[i + 1] = peer.id;
        }
        return nodes;
    }

    /// Get majority (quorum) count
    pub fn majority(self: @This()) u64 {
        return @divTrunc(self.peers.len, 2) + 1;
    }

    /// Validate configuration
    pub fn validate(self: @This()) !void {
        // Check for duplicate node IDs
        var seen = std.AutoHashMap(u64, void).init(std.heap.page_allocator);
        defer seen.deinit();

        try seen.put(self.node_id, {});
        for (self.peers) |peer| {
            if (seen.get(peer.id) != null) {
                return error.DuplicateNodeId;
            }
            try seen.put(peer.id, {});
        }

        // Validate timing
        if (self.election_timeout_min_ms >= self.election_timeout_max_ms) {
            return error.InvalidElectionTimeout;
        }

        if (self.heartbeat_interval_ms >= self.election_timeout_min_ms) {
            return error.HeartbeatTooLarge;
        }

        // Need at least 2 peers for 3-node cluster
        if (self.peers.len < 2) {
            return error.TooFewPeers;
        }
    }

    /// Cleanup allocated resources
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.rpc_listen_address);
        for (self.peers) |peer| {
            allocator.free(peer.address);
        }
        allocator.free(self.peers);
    }
};

/// Generate randomized election timeout
pub fn randomElectionTimeout(config: RaftConfig, rng: *std.Random.DefaultPrng) u64 {
    const range = config.election_timeout_max_ms - config.election_timeout_min_ms;
    return config.election_timeout_min_ms + rng.random().uintAtMost(u64, range);
}

// ==================== Unit Tests ====================

test "NodeInfo creation" {
    const node = NodeInfo.init(1, "localhost:7234");
    try std.testing.expectEqual(@as(u64, 1), node.id);
    try std.testing.expectEqualStrings("localhost:7234", node.address);
}

test "ClusterConfig majority calculation" {
    const nodes = [_]u64{ 1, 2, 3 };
    const config = ClusterConfig{ .nodes = &nodes };
    try std.testing.expectEqual(@as(u64, 2), config.majority());

    const nodes5 = [_]u64{ 1, 2, 3, 4, 5 };
    const config5 = ClusterConfig{ .nodes = &nodes5 };
    try std.testing.expectEqual(@as(u64, 3), config5.majority());
}

test "ClusterConfig contains" {
    const nodes = [_]u64{ 1, 2, 3 };
    const config = ClusterConfig{ .nodes = &nodes };
    try std.testing.expect(config.contains(1));
    try std.testing.expect(config.contains(3));
    try std.testing.expect(!config.contains(4));
}

test "RaftConfig majority" {
    const peers = [_]NodeInfo{
        NodeInfo.init(2, "node2:7234"),
        NodeInfo.init(3, "node3:7234"),
    };

    const config = RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
        .election_timeout_min_ms = 150,
        .election_timeout_max_ms = 300,
        .heartbeat_interval_ms = 50,
    };

    try std.testing.expectEqual(@as(u64, 2), config.majority());
}

test "RaftConfig validation - valid config" {
    const peers = [_]NodeInfo{
        NodeInfo.init(2, "node2:7234"),
        NodeInfo.init(3, "node3:7234"),
    };

    const config = RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
        .election_timeout_min_ms = 150,
        .election_timeout_max_ms = 300,
        .heartbeat_interval_ms = 50,
    };

    try config.validate();
}

test "RaftConfig validation - duplicate node ID" {
    const peers = [_]NodeInfo{
        NodeInfo.init(2, "node2:7234"),
        NodeInfo.init(2, "node3:7234"), // Duplicate ID
    };

    const config = RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    try std.testing.expectError(error.DuplicateNodeId, config.validate());
}

test "RaftConfig validation - too few peers" {
    const peers = [_]NodeInfo{
        NodeInfo.init(2, "node2:7234"),
    };

    const config = RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
    };

    try std.testing.expectError(error.TooFewPeers, config.validate());
}

test "randomElectionTimeout produces values in range" {
    const peers = [_]NodeInfo{
        NodeInfo.init(2, "node2:7234"),
        NodeInfo.init(3, "node3:7234"),
    };

    const config = RaftConfig{
        .node_id = 1,
        .peers = &peers,
        .rpc_listen_address = "0.0.0.0:7234",
        .election_timeout_min_ms = 150,
        .election_timeout_max_ms = 300,
    };

    var rng = std.Random.DefaultPrng.init(42);
    for (0..100) |_| {
        const timeout = randomElectionTimeout(config, &rng);
        try std.testing.expect(timeout >= 150);
        try std.testing.expect(timeout <= 300);
    }
}
