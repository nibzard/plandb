//! Integration tests for replication module.
//!
//! Tests the primary-replica replication flow per spec/replication_v1.md.

const std = @import("std");
const wal = @import("../wal.zig");
const txn = @import("../txn.zig");
const replication = @import("index.zig");

test "Integration: primary replica basic replication" {
    const testing_alloc = std.testing.allocator;

    // Create primary WAL
    var primary_wal = try wal.WriteAheadLog.create("test_primary_replication.db", std.testing.allocator);
    defer {
        primary_wal.deinit();
        std.fs.cwd().deleteFile("test_primary_replication.db") catch {};
    }

    // Create replica WAL
    var replica_wal = try wal.WriteAheadLog.create("test_replica_replication.db", std.testing.allocator);
    defer {
        replica_wal.deinit();
        std.fs.cwd().deleteFile("test_replica_replication.db") catch {};
    }

    // Create publisher on primary
    const primary_cfg = replication.PrimaryConfig{
        .listen_address = "127.0.0.1:17233",
        .max_replicas = 10,
        .heartbeat_interval_ms = 1000,
    };

    var publisher = try replication.ReplicationPublisher.init(testing_alloc, &primary_wal, primary_cfg);
    defer publisher.deinit();

    try publisher.start();
    defer publisher.stop();

    // Create subscriber on replica
    const replica_cfg = replication.ReplicaConfig{
        .primary_address = "127.0.0.1:17233",
        .replication_lag_target_ms = 100,
        .reconnect_interval_ms = 100,
        .bootstrap_on_start = false,
    };

    var subscriber = try replication.ReplicationSubscriber.init(testing_alloc, &replica_wal, replica_cfg);

    // Write a commit record to primary
    const mutations = try testing_alloc.alloc(txn.Mutation, 2);
    defer {
        for (mutations) |m| {
            switch (m) {
                .put => |p| {
                    testing_alloc.free(p.key);
                    testing_alloc.free(p.value);
                },
                .delete => |d| {
                    testing_alloc.free(d.key);
                },
            }
        }
        testing_alloc.free(mutations);
    }

    mutations[0] = txn.Mutation{ .put = .{
        .key = try testing_alloc.dupe(u8, "key1"),
        .value = try testing_alloc.dupe(u8, "value1"),
    }};
    mutations[1] = txn.Mutation{ .put = .{
        .key = try testing_alloc.dupe(u8, "key2"),
        .value = try testing_alloc.dupe(u8, "value2"),
    }};

    var record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = mutations,
        .checksum = 0,
    };
    record.checksum = record.calculatePayloadChecksum();

    // Append to primary WAL
    const lsn = try primary_wal.appendCommitRecord(record);
    try primary_wal.sync();

    try std.testing.expectEqual(@as(u64, 1), lsn);

    // Verify subscriber state
    try std.testing.expectEqual(@as(u64, 0), subscriber.applied_lsn);
    try std.testing.expectEqual(replication.ReplicationSubscriber.State.initializing, subscriber.state);

    // In a full integration test with actual network sockets, we would:
    // 1. Start a listener on primary
    // 2. Connect subscriber to primary
    // 3. Stream commit records
    // 4. Verify replica receives and applies records

    // For now, we test the state management without actual network
    subscriber.primary_lsn = 1;
    subscriber.applied_lsn = 0;

    const lag = subscriber.getReplicationLag();
    try std.testing.expectEqual(@as(u64, 1), lag);
}

test "Integration: protocol message roundtrip" {
    // Test heartbeat message serialization/deserialization
    const heartbeat = replication.HeartbeatMessage{
        .current_lsn = 100,
        .timestamp_ms = 12345,
    };

    var buffer: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try heartbeat.serialize(fbs.writer());

    fbs.pos = 0;
    const parsed = try replication.HeartbeatMessage.deserialize(fbs.reader());
    try std.testing.expectEqual(@as(u64, 100), parsed.current_lsn);
    try std.testing.expectEqual(@as(u64, 12345), parsed.timestamp_ms);

    // Test ACK message
    const ack = replication.AckMessage{
        .sequence = 50,
        .applied_lsn = 49,
    };

    var ack_buffer: [32]u8 = undefined;
    var ack_fbs = std.io.fixedBufferStream(&ack_buffer);
    try ack.serialize(ack_fbs.writer());

    ack_fbs.pos = 0;
    const parsed_ack = try replication.AckMessage.deserialize(ack_fbs.reader());
    try std.testing.expectEqual(@as(u64, 50), parsed_ack.sequence);
    try std.testing.expectEqual(@as(u64, 49), parsed_ack.applied_lsn);
}

test "Integration: config validation" {
    // Test primary config
    const primary_cfg = replication.initPrimary("0.0.0.0:7233");
    try std.testing.expectEqual(replication.ReplicationRole.primary, primary_cfg.role);
    try primary_cfg.validate();

    // Test replica config
    const replica_cfg = replication.initReplica("primary.example.com:7233");
    try std.testing.expectEqual(replication.ReplicationRole.replica, replica_cfg.role);
    try replica_cfg.validate();

    // Test invalid configs
    {
        var invalid_primary = replication.initPrimary("0.0.0.0:7233");
        invalid_primary.replica = replication.ReplicaConfig{
            .primary_address = "invalid",
            .replication_lag_target_ms = 100,
            .reconnect_interval_ms = 1000,
            .bootstrap_on_start = false,
        };
        try std.testing.expectError(error.ReplicaConfigOnPrimary, invalid_primary.validate());
    }

    {
        var invalid_replica = replication.initReplica("primary:7233");
        invalid_replica.primary = replication.PrimaryConfig{
            .listen_address = "invalid",
            .max_replicas = 10,
        };
        try std.testing.expectError(error.PrimaryConfigOnReplica, invalid_replica.validate());
    }
}

test "Integration: replica state tracking" {
    // Test replica state initialization
    var state = replication.ReplicaState.init(1);
    try std.testing.expectEqual(@as(u64, 1), state.replica_id);
    try std.testing.expect(state.connected);

    // Test replication lag calculation
    state.last_ack_lsn = 90;
    const current_lsn: u64 = 100;
    const lag = state.getReplicationLag(current_lsn);
    try std.testing.expectEqual(@as(u64, 10), lag);

    // Test timeout detection
    state.last_heartbeat_time_ms = timestampMs() - 10000;
    try std.testing.expect(state.isTimedOut(5000));
}

test "Integration: publisher replica management" {
    const testing_alloc = std.testing.allocator;

    var test_wal = try wal.WriteAheadLog.create("test_publisher_mgmt.db", std.testing.allocator);
    defer {
        test_wal.deinit();
        std.fs.cwd().deleteFile("test_publisher_mgmt.db") catch {};
    }

    const primary_cfg = replication.PrimaryConfig{
        .listen_address = "0.0.0.0:17234",
        .max_replicas = 5,
    };

    var publisher = try replication.ReplicationPublisher.init(testing_alloc, &test_wal, primary_cfg);
    defer publisher.deinit();

    try publisher.start();
    defer publisher.stop();

    try std.testing.expectEqual(@as(usize, 0), publisher.getReplicaCount());

    // Test ack handling for non-existent replica
    const ack_err = publisher.handleAck(999, 1, 10);
    try std.testing.expectError(error.ReplicaNotFound, ack_err);

    // Test lag retrieval for non-existent replica
    const lag_err = publisher.getReplicaLag(999);
    try std.testing.expectError(error.ReplicaNotFound, lag_err);
}

/// Get current timestamp in milliseconds
fn timestampMs() u64 {
    const ns = std.time.nanoTimestamp();
    return @intCast(@abs(ns) / 1_000_000);
}
