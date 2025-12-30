//! Replication configuration types.
//!
//! Defines configuration for primary and replica roles per spec/replication_v1.md.

const std = @import("std");

/// Replication role (primary or replica)
pub const ReplicationRole = enum {
    primary,  // Accepts writes and replicates to replicas
    replica,  // Read-only, receives replication from primary
};

/// Replication configuration
pub const ReplicationConfig = struct {
    /// Role: "primary" or "replica"
    role: ReplicationRole,

    /// Primary-specific configuration
    primary: ?PrimaryConfig = null,

    /// Replica-specific configuration
    replica: ?ReplicaConfig = null,

    /// Create a primary configuration
    pub fn initPrimary(listen_address: []const u8) ReplicationConfig {
        return ReplicationConfig{
            .role = .primary,
            .primary = PrimaryConfig{
                .listen_address = listen_address,
                .max_replicas = 10,
                .replication_buffer_size = 100 * 1024 * 1024, // 100MB
            },
            .replica = null,
        };
    }

    /// Create a replica configuration
    pub fn initReplica(primary_address: []const u8) ReplicationConfig {
        return ReplicationConfig{
            .role = .replica,
            .primary = null,
            .replica = ReplicaConfig{
                .primary_address = primary_address,
                .replication_lag_target_ms = 100,
                .reconnect_interval_ms = 1000,
                .bootstrap_on_start = false,
            },
        };
    }

    /// Validate configuration
    pub fn validate(self: @This()) !void {
        switch (self.role) {
            .primary => {
                if (self.primary == null) return error.MissingPrimaryConfig;
                if (self.replica) |_| return error.ReplicaConfigOnPrimary;
            },
            .replica => {
                if (self.replica == null) return error.MissingReplicaConfig;
                if (self.primary) |_| return error.PrimaryConfigOnReplica;
            },
        }
    }
};

/// Primary-specific configuration
pub const PrimaryConfig = struct {
    /// Address to listen on (e.g., "0.0.0.0:7233")
    listen_address: []const u8,

    /// Maximum number of replicas to serve
    max_replicas: u32 = 10,

    /// Replication buffer size in bytes
    replication_buffer_size: u64 = 100 * 1024 * 1024, // 100MB

    /// Heartbeat interval in milliseconds
    heartbeat_interval_ms: u64 = 1000,

    /// Connection timeout in milliseconds
    connection_timeout_ms: u64 = 30000,
};

/// Replica-specific configuration
pub const ReplicaConfig = struct {
    /// Primary's address (e.g., "primary.example.com:7233")
    primary_address: []const u8,

    /// Target replication lag in milliseconds
    replication_lag_target_ms: u64 = 100,

    /// Reconnect interval in milliseconds
    reconnect_interval_ms: u64 = 1000,

    /// Whether to bootstrap on start
    bootstrap_on_start: bool = false,

    /// Connection timeout in milliseconds
    connection_timeout_ms: u64 = 30000,

    /// Maximum reconnect attempts before giving up (0 = infinite)
    max_reconnect_attempts: u32 = 0,
};

/// Replica state tracking (on primary)
pub const ReplicaState = struct {
    replica_id: u64,
    last_ack_sequence: u64,
    last_ack_lsn: u64,
    last_heartbeat_time_ms: u64,
    connected: bool,

    pub fn init(replica_id: u64) ReplicaState {
        const now = timestampMs();
        return ReplicaState{
            .replica_id = replica_id,
            .last_ack_sequence = 0,
            .last_ack_lsn = 0,
            .last_heartbeat_time_ms = now,
            .connected = true,
        };
    }

    /// Check if replica has timed out
    pub fn isTimedOut(self: @This(), timeout_ms: u64) bool {
        const now = timestampMs();
        const elapsed = now - self.last_heartbeat_time_ms;
        return elapsed > timeout_ms;
    }

    /// Get replication lag (current LSN - applied LSN)
    pub fn getReplicationLag(self: @This(), current_lsn: u64) u64 {
        if (current_lsn >= self.last_ack_lsn) {
            return current_lsn - self.last_ack_lsn;
        }
        return 0;
    }
};

/// Get current timestamp in milliseconds
fn timestampMs() u64 {
    // Use std.time.nanoTimestamp and convert to ms
    const ns = std.time.nanoTimestamp();
    return @intCast(@abs(ns) / 1_000_000);
}

// ==================== Unit Tests ====================

test "ReplicationConfig.primary creates valid config" {
    const config = ReplicationConfig.initPrimary("0.0.0.0:7233");
    try std.testing.expectEqual(ReplicationRole.primary, config.role);
    try std.testing.expect(config.primary != null);
    try std.testing.expect(config.replica == null);
    try config.validate();
}

test "ReplicationConfig.replica creates valid config" {
    const config = ReplicationConfig.initReplica("primary.example.com:7233");
    try std.testing.expectEqual(ReplicationRole.replica, config.role);
    try std.testing.expect(config.primary == null);
    try std.testing.expect(config.replica != null);
    try config.validate();
}

test "ReplicaState tracks replication lag" {
    var state = ReplicaState.init(1);
    state.last_ack_lsn = 90;
    const current_lsn: u64 = 100;
    const lag = state.getReplicationLag(current_lsn);
    try std.testing.expectEqual(@as(u64, 10), lag);
}

test "ReplicaState detects timeout" {
    var state = ReplicaState.init(1);
    // Set heartbeat to 10 seconds ago
    state.last_heartbeat_time_ms = timestampMs() - 10000;
    const timed_out = state.isTimedOut(5000);
    try std.testing.expect(timed_out);
}
