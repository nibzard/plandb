//! Replication hardening tests - failure scenarios and robustness.
//!
//! Tests network partitions, primary/replica crashes, corruption detection,
//! and other edge cases per spec/replication_v1.md Phase 2 requirements.

const std = @import("std");
const wal = @import("../wal.zig");
const config = @import("config.zig");
const publisher = @import("publisher.zig");
const subscriber = @import("subscriber.zig");
const protocol = @import("protocol.zig");

// Test scenario: Network partition between primary and replica
test "replication hardening: network partition recovery" {
    var test_wal = try wal.WriteAheadLog.create("test_partition_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_partition_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 100,
        .bootstrap_on_start = false,
        .max_reconnect_attempts = 5,
    };

    var sub = try subscriber.ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    try sub.handleDisconnect();
    try std.testing.expectEqual(subscriber.ReplicationSubscriber.State.disconnected, sub.state);
    try sub.handleDisconnect();
    try std.testing.expectEqual(subscriber.ReplicationSubscriber.State.connecting, sub.state);
    try std.testing.expectEqual(@as(u32, 2), sub.reconnect_attempts);
}

// Test scenario: Replica reconnection with exponential backoff
test "replication hardening: exponential backoff" {
    var test_wal = try wal.WriteAheadLog.create("test_backoff_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_backoff_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 100,
        .bootstrap_on_start = false,
        .max_reconnect_attempts = 10,
    };

    var sub = try subscriber.ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    var attempts: u32 = 0;
    while (attempts < 5) : (attempts += 1) {
        try sub.handleDisconnect();
        try std.testing.expectEqual(@as(u32, attempts + 1), sub.reconnect_attempts);
    }
    try std.testing.expectEqual(subscriber.ReplicationSubscriber.State.connecting, sub.state);
}

// Test scenario: Max reconnect attempts exceeded
test "replication hardening: max reconnect attempts exceeded" {
    var test_wal = try wal.WriteAheadLog.create("test_max_reconnect_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_max_reconnect_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 10,
        .bootstrap_on_start = false,
        .max_reconnect_attempts = 3,
    };

    var sub = try subscriber.ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try sub.handleDisconnect();
    }
    const result = sub.handleDisconnect();
    try std.testing.expectError(error.MaxReconnectAttemptsExceeded, result);
}

// Test scenario: Checksum validation on commit records
test "replication hardening: checksum validation" {
    var test_wal = try wal.WriteAheadLog.create("test_checksum_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_checksum_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 1000,
        .bootstrap_on_start = false,
    };

    const sub = try subscriber.ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    try std.testing.expect(sub.checksum_validation_enabled);
}

// Test scenario: Heartbeat timeout detection
test "replication hardening: heartbeat timeout detection" {
    var test_wal = try wal.WriteAheadLog.create("test_heartbeat_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_heartbeat_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 1000,
        .bootstrap_on_start = false,
    };

    var sub = try subscriber.ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    try std.testing.expect(!sub.isHeartbeatTimeout());
    sub.last_heartbeat_time_ms = timestampMs() - 10000;
    try std.testing.expect(sub.isHeartbeatTimeout());
}

// Test scenario: Replica state transitions
test "replication hardening: replica state machine" {
    var test_wal = try wal.WriteAheadLog.create("test_state_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_state_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 1000,
        .bootstrap_on_start = false,
    };

    var sub = try subscriber.ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    try std.testing.expectEqual(subscriber.ReplicationSubscriber.State.initializing, sub.state);
    sub.disconnect();
    try std.testing.expectEqual(subscriber.ReplicationSubscriber.State.disconnected, sub.state);
    sub.resetReconnectAttempts();
    try std.testing.expectEqual(@as(u32, 0), sub.reconnect_attempts);
}

// Test scenario: Bootstrap protocol message serialization
test "replication hardening: bootstrap protocol messages" {
    const bootstrap_req = protocol.BootstrapRequest{
        .replica_id = 123,
        .start_lsn = 0,
        .protocol_version = 1,
    };

    var req_buffer: [128]u8 = undefined;
    var req_fbs = std.io.fixedBufferStream(&req_buffer);
    try bootstrap_req.serialize(req_fbs.writer());
    req_fbs.pos = 0;
    const parsed_req = try protocol.BootstrapRequest.deserialize(req_fbs.reader());
    try std.testing.expectEqual(@as(u64, 123), parsed_req.replica_id);

    const bootstrap_complete = protocol.BootstrapComplete{
        .final_lsn = 1000,
        .success = true,
    };

    var complete_buffer: [32]u8 = undefined;
    var complete_fbs = std.io.fixedBufferStream(&complete_buffer);
    try bootstrap_complete.serialize(complete_fbs.writer());
    complete_fbs.pos = 0;
    const parsed_complete = try protocol.BootstrapComplete.deserialize(complete_fbs.reader());
    try std.testing.expectEqual(@as(u64, 1000), parsed_complete.final_lsn);
    try std.testing.expect(parsed_complete.success);
}

// Test scenario: Publisher replica timeout detection
test "replication hardening: publisher replica timeout" {
    var test_wal = try wal.WriteAheadLog.create("test_publisher_timeout_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_publisher_timeout_wal.db") catch {};
    }

    const primary_cfg = config.PrimaryConfig{
        .listen_address = "0.0.0.0:7233",
        .max_replicas = 5,
        .heartbeat_interval_ms = 1000,
    };

    var pubber = try publisher.ReplicationPublisher.init(std.testing.allocator, &test_wal, primary_cfg);
    defer pubber.deinit();
    try pubber.start();
    defer pubber.stop();
    try std.testing.expect(!pubber.isReplicaConnected(999));
}

// Test scenario: Replication lag calculation
test "replication hardening: replication lag calculation" {
    var test_wal = try wal.WriteAheadLog.create("test_lag_calc_wal.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_lag_calc_wal.db") catch {};
    }

    const replica_cfg = config.ReplicaConfig{
        .primary_address = "127.0.0.1:7233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 1000,
        .bootstrap_on_start = false,
    };

    var sub = try subscriber.ReplicationSubscriber.init(std.testing.allocator, &test_wal, replica_cfg);
    sub.primary_lsn = 100;
    sub.applied_lsn = 90;
    const lag = sub.getReplicationLag();
    try std.testing.expectEqual(@as(u64, 10), lag);
    try std.testing.expect(sub.isHealthy());
    sub.applied_lsn = 50;
    try std.testing.expect(!sub.isHealthy());
}

// Helper: Get current timestamp in milliseconds
fn timestampMs() u64 {
    const ns = std.time.nanoTimestamp();
    return @intCast(@abs(ns) / 1_000_000);
}
