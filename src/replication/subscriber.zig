//! Replication subscriber - receives and applies commit records from primary.
//!
//! The subscriber connects to a primary, pulls commit records, and applies them
//! to the local database. This implements the replica-side replication logic
//! per spec/replication_v1.md.

const std = @import("std");
const wal = @import("../wal.zig");
const txn = @import("../txn.zig");
const protocol = @import("protocol.zig");
const config = @import("config.zig");

/// Replication subscriber - receives commit records from primary
pub const ReplicationSubscriber = struct {
    allocator: std.mem.Allocator,
    local_wal: *wal.WriteAheadLog,
    cfg: config.ReplicaConfig,
    state: State,
    applied_lsn: u64,
    primary_lsn: u64,
    last_heartbeat_time_ms: u64,
    reconnect_attempts: u32,

    const Self = @This();

    /// Subscriber state machine per spec/replication_v1.md
    pub const State = enum {
        initializing,
        connecting,
        catchup,
        replicating,
        disconnected,
    };

    /// Create a new replication subscriber
    pub fn init(allocator: std.mem.Allocator, local_wal_handle: *wal.WriteAheadLog, cfg: config.ReplicaConfig) !Self {
        return Self{
            .allocator = allocator,
            .local_wal = local_wal_handle,
            .cfg = cfg,
            .state = .initializing,
            .applied_lsn = local_wal_handle.getCurrentLsn(),
            .primary_lsn = 0,
            .last_heartbeat_time_ms = 0,
            .reconnect_attempts = 0,
        };
    }

    /// Connect to primary and start replication
    pub fn connect(self: *Self) !void {
        self.state = .connecting;

        // Parse primary address
        const address = try std.net.Address.parseIp4(
            self.cfg.primary_address,
            try parsePort(self.cfg.primary_address),
        );

        // Connect to primary
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        // Send connect request
        var connect_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&connect_buf);

        const start_lsn = self.applied_lsn + 1;
        const connect_req = protocol.ConnectRequest{
            .replica_id = 1, // TODO: generate unique replica ID
            .start_lsn = start_lsn,
            .protocol_version = 1,
        };

        try connect_req.serialize(fbs.writer());
        _ = try stream.writeAll(fbs.getWritten());

        // Read accept response
        var response_buf: [256]u8 = undefined;
        const bytes_read = try stream.read(&response_buf);
        if (bytes_read == 0) return error.ConnectionClosed;

        var response_fbs = std.io.fixedBufferStream(response_buf[0..bytes_read]);
        const accept_resp = try protocol.AcceptResponse.deserialize(response_fbs.reader());

        self.primary_lsn = accept_resp.current_lsn;
        self.last_heartbeat_time_ms = timestampMs();
        self.reconnect_attempts = 0;

        if (self.applied_lsn < accept_resp.current_lsn) {
            self.state = .catchup;
        } else {
            self.state = .replicating;
        }
    }

    /// Receive and apply a single commit record from primary
    pub fn receiveAndApply(self: *Self, stream: std.net.Stream) !bool {
        if (self.state == .disconnected) return false;

        // Read message length first (simplified - real impl would have framing)
        var len_buf: [4]u8 = undefined;
        const len_bytes = try stream.read(&len_buf);
        if (len_bytes < 4) return false;

        const msg_len = std.mem.readInt(u32, &len_buf, .little);
        if (msg_len == 0) {
            // Heartbeat or empty message
            return true;
        }

        // Read message body
        const msg_buf = try self.allocator.alloc(u8, msg_len);
        defer self.allocator.free(msg_buf);

        const bytes_read = try stream.readAll(msg_buf);
        if (bytes_read < msg_len) return false;

        // Parse message
        var msg_fbs = std.io.fixedBufferStream(msg_buf);
        const message = try protocol.ReplicationMessage.deserialize(msg_fbs.reader(), self.allocator);
        defer {
            // Clean up commit record if present
            if (message.commit_record) |cr| {
                // Note: cr is a pointer to allocated memory
                // In real implementation, we'd properly clean up mutations
                _ = cr;
            }
        }

        switch (message.message_type) {
            .heartbeat => {
                self.last_heartbeat_time_ms = timestampMs();
                // Send ACK
                const ack = protocol.AckMessage{
                    .sequence = message.sequence,
                    .applied_lsn = self.applied_lsn,
                };
                var ack_buf: [32]u8 = undefined;
                var ack_fbs = std.io.fixedBufferStream(&ack_buf);
                try ack.serialize(ack_fbs.writer());
                _ = try stream.writeAll(ack_fbs.getWritten());
            },
            .commit_record => |cr| {
                if (cr) |record| {
                    // Apply commit record to local WAL
                    try self.applyCommitRecord(record.*);
                    self.applied_lsn = record.txn_id;

                    // Send ACK
                    const ack = protocol.AckMessage{
                        .sequence = message.sequence,
                        .applied_lsn = self.applied_lsn,
                    };
                    var ack_buf: [32]u8 = undefined;
                    var ack_fbs = std.io.fixedBufferStream(&ack_buf);
                    try ack.serialize(ack_fbs.writer());
                    _ = try stream.writeAll(ack_fbs.getWritten());
                }
            },
            .snapshot => {
                // Handle snapshot (for bootstrap)
                // TODO: implement snapshot application
            },
            .error_message => {
                // Handle error message
                return error.ReplicationError;
            },
        }

        return true;
    }

    /// Apply a commit record to the local WAL
    fn applyCommitRecord(self: *Self, commit_record: txn.CommitRecord) !void {
        // Append to local WAL
        _ = try self.local_wal.appendCommitRecord(commit_record);
        try self.local_wal.sync();
    }

    /// Handle disconnect and reconnect logic
    pub fn handleDisconnect(self: *Self) !void {
        self.state = .disconnected;

        if (self.cfg.max_reconnect_attempts > 0 and
           self.reconnect_attempts >= self.cfg.max_reconnect_attempts)
        {
            return error.MaxReconnectAttemptsExceeded;
        }

        // Exponential backoff
        const backoff_ms = self.cfg.reconnect_interval_ms * std.math.pow(u64, 2, @min(self.reconnect_attempts, 10));
        std.time.sleep(backoff_ms * 1_000_000); // Convert ms to ns

        self.reconnect_attempts += 1;
        self.state = .connecting;
    }

    /// Get current replication lag
    pub fn getReplicationLag(self: *const Self) u64 {
        if (self.primary_lsn >= self.applied_lsn) {
            return self.primary_lsn - self.applied_lsn;
        }
        return 0;
    }

    /// Check if replication is healthy (lag below target)
    pub fn isHealthy(self: *const Self) bool {
        return self.getReplicationLag() * 1000 / self.cfg.replication_lag_target_ms < 1000;
    }

    /// Check if heartbeat timeout has occurred
    pub fn isHeartbeatTimeout(self: *const Self) bool {
        const now = timestampMs();
        const elapsed = now - self.last_heartbeat_time_ms;
        // Use 5x heartbeat interval as timeout (per spec)
        return elapsed > 5000;
    }
};

/// Parse port from address string (simplified)
fn parsePort(address: []const u8) !u16 {
    // Find last colon
    const colon_idx = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress;
    const port_str = address[colon_idx + 1 ..];
    return std.fmt.parseInt(u16, port_str, 10);
}

/// Get current timestamp in milliseconds
fn timestampMs() u64 {
    const ns = std.time.nanoTimestamp();
    return @intCast(@abs(ns) / 1_000_000);
}

// ==================== Unit Tests ====================

test "ReplicationSubscriber init" {
    var test_wal = try wal.WriteAheadLog.create("test_subscriber_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_subscriber_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 1000,
        .bootstrap_on_start = false,
    };

    const subscriber = try ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    try std.testing.expectEqual(@as(u64, 0), subscriber.applied_lsn);
    try std.testing.expectEqual(ReplicationSubscriber.State.initializing, subscriber.state);
}

test "ReplicationSubscriber getReplicationLag" {
    var test_wal = try wal.WriteAheadLog.create("test_subscriber_lag_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_subscriber_lag_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 1000,
        .bootstrap_on_start = false,
    };

    var subscriber = try ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    subscriber.primary_lsn = 100;
    subscriber.applied_lsn = 90;

    const lag = subscriber.getReplicationLag();
    try std.testing.expectEqual(@as(u64, 10), lag);
}

test "ReplicationSubscriber isHealthy" {
    var test_wal = try wal.WriteAheadLog.create("test_subscriber_health_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_subscriber_health_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 1000,
        .bootstrap_on_start = false,
    };

    var subscriber = try ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    subscriber.primary_lsn = 100;
    subscriber.applied_lsn = 99; // 1 LSN lag = healthy

    try std.testing.expect(subscriber.isHealthy());

    subscriber.applied_lsn = 50; // 50 LSN lag = unhealthy
    try std.testing.expect(!subscriber.isHealthy());
}

test "parsePort valid" {
    try std.testing.expectEqual(@as(u16, 7233), try parsePort("127.0.0.1:7233"));
    try std.testing.expectEqual(@as(u16, 80), try parsePort("example.com:80"));
}

test "parsePort invalid" {
    try std.testing.expectError(error.InvalidAddress, parsePort("127.0.0.1"));
    try std.testing.expectError(error.InvalidAddress, parsePort("invalid"));
}
