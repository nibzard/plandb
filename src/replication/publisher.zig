//! Replication publisher - streams commit records from WAL to replicas.
//!
//! The publisher tails the WAL and streams commit records to connected replicas.
//! This implements the primary-side replication logic per spec/replication_v1.md.

const std = @import("std");
const wal = @import("../wal.zig");
const protocol = @import("protocol.zig");
const config = @import("config.zig");

/// Connected replica state
const ReplicaConnection = struct {
    replica_id: u64,
    start_lsn: u64,
    last_ack_sequence: u64,
    state: config.ReplicaState,
    writer: ?std.net.Stream.Writer = null,
    stream: ?std.net.Stream = null,

    /// Check if checksum validation is enabled for this replica
    checksum_enabled: bool = true,

    /// Get the stream for this connection
    fn getStream(self: *ReplicaConnection) ?std.net.Stream {
        return self.stream;
    }
};

/// Replication publisher - streams commit records to replicas
pub const ReplicationPublisher = struct {
    allocator: std.mem.Allocator,
    wal: *wal.WriteAheadLog,
    cfg: config.PrimaryConfig,
    replicas: std.ArrayList(ReplicaConnection),
    next_sequence: u64,
    running: bool,
    lock: std.Thread.Mutex,

    const Self = @This();

    /// Create a new replication publisher
    pub fn init(allocator: std.mem.Allocator, wal_handle: *wal.WriteAheadLog, cfg: config.PrimaryConfig) !Self {
        return Self{
            .allocator = allocator,
            .wal = wal_handle,
            .cfg = cfg,
            .replicas = .{}, // Empty ArrayList
            .next_sequence = 1,
            .running = false,
            .lock = std.Thread.Mutex{},
        };
    }

    /// Clean up publisher resources
    pub fn deinit(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.replicas.items) |*replica| {
            replica.state.connected = false;
        }
        self.replicas.deinit(self.allocator);
    }

    /// Start the publisher (begin streaming)
    pub fn start(self: *Self) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.running) return error.AlreadyStarted;
        self.running = true;
    }

    /// Stop the publisher
    pub fn stop(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.running = false;
    }

    /// Add a replica connection
    pub fn addReplica(self: *Self, replica_id: u64, start_lsn: u64, stream: std.net.Stream) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.replicas.items.len >= self.cfg.max_replicas) {
            return error.TooManyReplicas;
        }

        const conn = ReplicaConnection{
            .replica_id = replica_id,
            .start_lsn = start_lsn,
            .last_ack_sequence = 0,
            .state = config.ReplicaState.init(replica_id),
            .writer = stream.writer(),
            .stream = stream,
            .checksum_enabled = true,
        };

        try self.replicas.append(conn);
    }

    /// Remove a replica connection
    pub fn removeReplica(self: *Self, replica_id: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.replicas.items, 0..) |*replica, i| {
            if (replica.replica_id == replica_id) {
                replica.state.connected = false;
                _ = self.replicas.orderedRemove(i);
                break;
            }
        }
    }

    /// Handle acknowledgment from replica
    pub fn handleAck(self: *Self, replica_id: u64, sequence: u64, applied_lsn: u64) !void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.replicas.items) |*replica| {
            if (replica.replica_id == replica_id) {
                replica.last_ack_sequence = sequence;
                replica.state.last_ack_lsn = applied_lsn;
                replica.state.last_heartbeat_time_ms = timestampMs();
                return;
            }
        }
        return error.ReplicaNotFound;
    }

    /// Publish a commit record to all replicas
    pub fn publishCommitRecord(self: *Self, commit_record: *const std.ArrayList(u8)) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (!self.running) return;

        const sequence = self.next_sequence;
        self.next_sequence += 1;

        // Send to each connected replica
        var i: usize = 0;
        while (i < self.replicas.items.len) {
            const replica = &self.replicas.items[i];
            if (!replica.state.connected) {
                // Remove disconnected replicas
                _ = self.replicas.orderedRemove(i);
                continue;
            }

            if (replica.writer) |writer| {
                // Send heartbeat/commit record message
                // For now, we'll send a simple notification
                // Full implementation would use ReplicationMessage serialization
                _ = writer;
                _ = sequence;
                _ = commit_record;
            }

            i += 1;
        }
    }

    /// Send heartbeat to all replicas
    pub fn sendHeartbeat(self: *Self) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const current_lsn = self.wal.getCurrentLsn();

        var i: usize = 0;
        while (i < self.replicas.items.len) {
            const replica = &self.replicas.items[i];
            if (!replica.state.connected) {
                _ = self.replicas.orderedRemove(i);
                continue;
            }

            if (replica.writer) |writer| {
                const heartbeat = protocol.HeartbeatMessage{
                    .current_lsn = current_lsn,
                    .timestamp_ms = timestampMs(),
                };

                // Serialize heartbeat with length prefix
                var buffer: [64]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buffer);

                // Write message length
                const heartbeat_size = 16; // 8 bytes current_lsn + 8 bytes timestamp
                try writer.writeInt(u32, heartbeat_size, .little);

                // Serialize heartbeat
                try heartbeat.serialize(fbs.writer());

                // Write heartbeat data
                _ = writer.writeAll(fbs.getWritten()) catch |err| {
                    // Send error - mark replica as disconnected
                    std.log.warn("Failed to send heartbeat to replica {}: {}", .{ replica.replica_id, err });
                    replica.state.connected = false;
                    _ = self.replicas.orderedRemove(i);
                    continue;
                };
            }

            i += 1;
        }

        // Check for timed out replicas (5x heartbeat interval)
        const heartbeat_timeout = self.cfg.heartbeat_interval_ms * 5;
        i = 0;
        while (i < self.replicas.items.len) {
            const replica = &self.replicas.items[i];
            if (replica.state.isTimedOut(heartbeat_timeout)) {
                std.log.warn("Replica {} timed out after {}ms", .{ replica.replica_id, heartbeat_timeout });
                replica.state.connected = false;
                _ = self.replicas.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Check if a specific replica is connected
    pub fn isReplicaConnected(self: *const Self, replica_id: u64) bool {
        for (self.replicas.items) |*replica| {
            if (replica.replica_id == replica_id) {
                return replica.state.connected;
            }
        }
        return false;
    }

    /// Get current replication lag for a replica
    pub fn getReplicaLag(self: *const Self, replica_id: u64) !u64 {
        for (self.replicas.items) |*replica| {
            if (replica.replica_id == replica_id) {
                const current_lsn = self.wal.getCurrentLsn();
                return replica.state.getReplicationLag(current_lsn);
            }
        }
        return error.ReplicaNotFound;
    }

    /// Get number of connected replicas
    pub fn getReplicaCount(self: *const Self) usize {
        return self.replicas.items.len;
    }
};

/// Get current timestamp in milliseconds
fn timestampMs() u64 {
    const ns = std.time.nanoTimestamp();
    return @intCast(@abs(ns) / 1_000_000);
}

// ==================== Unit Tests ====================

test "ReplicationPublisher init and start" {
    var test_wal = try wal.WriteAheadLog.create("test_publisher_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_publisher_wal.db") catch {};
    }

    const primary_cfg = config.PrimaryConfig{
        .listen_address = "0.0.0.0:7233",
        .max_replicas = 5,
    };

    var publisher = try ReplicationPublisher.init(std.testing.allocator, &test_wal, primary_cfg);
    defer publisher.deinit();

    try publisher.start();
    try std.testing.expect(publisher.running);

    publisher.stop();
    try std.testing.expect(!publisher.running);
}

test "ReplicationPublisher replica management" {
    var test_wal = try wal.WriteAheadLog.create("test_replica_mgmt_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_replica_mgmt_wal.db") catch {};
    }

    const primary_cfg = config.PrimaryConfig{
        .listen_address = "0.0.0.0:7233",
        .max_replicas = 5,
    };

    var publisher = try ReplicationPublisher.init(std.testing.allocator, &test_wal, primary_cfg);
    defer publisher.deinit();

    try publisher.start();
    defer publisher.stop();

    // Note: actual connection testing would require real network sockets
    // For now we test the state management
    try std.testing.expectEqual(@as(usize, 0), publisher.getReplicaCount());
}

test "ReplicationPublisher handleAck" {
    var test_wal = try wal.WriteAheadLog.create("test_ack_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_ack_wal.db") catch {};
    }

    const primary_cfg = config.PrimaryConfig{
        .listen_address = "0.0.0.0:7233",
        .max_replicas = 5,
    };

    var publisher = try ReplicationPublisher.init(std.testing.allocator, &test_wal, primary_cfg);
    defer publisher.deinit();

    try publisher.start();
    defer publisher.stop();

    // Ack for non-existent replica should fail
    const ack_result = publisher.handleAck(999, 1, 10);
    try std.testing.expectError(error.ReplicaNotFound, ack_result);
}

test "ReplicationPublisher getReplicaLag" {
    var test_wal = try wal.WriteAheadLog.create("test_lag_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_lag_wal.db") catch {};
    }

    // Append a commit record to get LSN > 0
    const txn = @import("../txn.zig");
    const mutations = [_]txn.Mutation{
        txn.Mutation{ .put = .{ .key = "test", .value = "value" } },
    };
    var record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 1,
        .mutations = &mutations,
        .checksum = 0,
    };
    record.checksum = record.calculatePayloadChecksum();
    _ = try test_wal.appendCommitRecord(record);

    const primary_cfg = config.PrimaryConfig{
        .listen_address = "0.0.0.0:7233",
        .max_replicas = 5,
    };

    var publisher = try ReplicationPublisher.init(std.testing.allocator, &test_wal, primary_cfg);
    defer publisher.deinit();

    try publisher.start();
    defer publisher.stop();

    // Lag for non-existent replica should fail
    const lag_result = publisher.getReplicaLag(999);
    try std.testing.expectError(error.ReplicaNotFound, lag_result);
}
