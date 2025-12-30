//! Replication protocol message types.
//!
//! Defines the wire format for replication messages between primary and replicas
//! per spec/replication_v1.md.

const std = @import("std");
const txn = @import("../txn.zig");

/// Replication message wrapping commit records with metadata
pub const ReplicationMessage = struct {
    /// Protocol version for compatibility
    version: u16 = 1,

    /// Message type discriminator
    message_type: MessageType,

    /// Sequence number (monotonically increasing)
    sequence: u64,

    /// Original commit record (for commit_record messages)
    commit_record: ?*const txn.CommitRecord = null,

    /// Checksum for integrity (CRC32C of entire message except this field)
    checksum: u32 = 0,

    const Self = @This();

    /// Message types per spec/replication_v1.md
    pub const MessageType = enum(u8) {
        heartbeat = 0,        // Periodic keepalive
        commit_record = 1,    // Actual commit record
        snapshot = 2,         // Full snapshot for bootstrap
        error_message = 3,    // Error notification
        bootstrap_request = 4, // Request snapshot bootstrap
        bootstrap_data = 5,   // Snapshot data chunk
        bootstrap_complete = 6, // Bootstrap completion signal
    };

    /// Calculate message size for allocation
    pub fn calculateSerializedSize(self: @This()) usize {
        var size: usize = 2 + 1 + 8 + 4; // version + type + sequence + checksum
        switch (self.message_type) {
            .heartbeat => {},
            .commit_record => {
                if (self.commit_record) |record| {
                    size += self.calculateCommitRecordSize(record.*);
                }
            },
            .snapshot => {
                size += 8; // snapshot_lsn
            },
            .error_message => {
                size += 2 + 4; // error_code + error_message_len
            },
        }
        return size;
    }

    fn calculateCommitRecordSize(self: @This(), record: txn.CommitRecord) usize {
        _ = self;
        var size: usize = txn.CommitPayloadHeader.SIZE;
        for (record.mutations) |mutation| {
            switch (mutation) {
                .put => |p| {
                    size += 1 + 1 + 2 + 4 + p.key.len + p.value.len; // op header + data
                },
                .delete => |d| {
                    size += 1 + 1 + 2 + 4 + d.key.len; // op header + key
                },
            }
        }
        return size;
    }

    /// Serialize message to byte stream
    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u16, self.version, .little);
        try writer.writeByte(@intFromEnum(self.message_type));
        try writer.writeInt(u64, self.sequence, .little);

        // Write payload based on message type
        switch (self.message_type) {
            .heartbeat => {},
            .commit_record => {
                if (self.commit_record) |record| {
                    try self.serializeCommitRecord(writer, record.*);
                }
            },
            .snapshot => {
                // Snapshot messages will include snapshot data
                // For now, placeholder for bootstrap protocol
                try writer.writeInt(u64, 0, .little); // snapshot_lsn placeholder
            },
            .error_message => {
                // Error code and message placeholders
                try writer.writeInt(u16, 0, .little); // error_code
                try writer.writeInt(u32, 0, .little); // error_message_len
            },
            .bootstrap_request => {
                // Bootstrap request includes requested starting LSN
                try writer.writeInt(u64, 0, .little); // start_lsn placeholder
            },
            .bootstrap_data => {
                // Bootstrap data chunk - placeholder
                try writer.writeInt(u32, 0, .little); // chunk_size
                try writer.writeInt(u32, 0, .little); // chunk_index
                try writer.writeInt(u32, 0, .little); // total_chunks
            },
            .bootstrap_complete => {
                // Bootstrap completion includes final LSN
                try writer.writeInt(u64, 0, .little); // final_lsn
            },
        }

        // Calculate and write checksum
        const checksum = self.calculateChecksum();
        try writer.writeInt(u32, checksum, .little);
    }

    fn serializeCommitRecord(self: @This(), writer: anytype, record: txn.CommitRecord) !void {
        _ = self;
        // Write commit payload header
        const header = txn.CommitPayloadHeader{
            .commit_magic = 0x434D4954,
            .txn_id = record.txn_id,
            .root_page_id = record.root_page_id,
            .op_count = @intCast(record.mutations.len),
            .reserved = 0,
        };
        try header.serialize(writer);

        // Write mutations
        for (record.mutations) |mutation| {
            switch (mutation) {
                .put => |p| {
                    const op = txn.EncodedOperation{
                        .op_type = 0, // Put
                        .op_flags = 0,
                        .key_len = @intCast(p.key.len),
                        .val_len = @intCast(p.value.len),
                        .key_bytes = p.key,
                        .val_bytes = p.value,
                    };
                    try op.serialize(writer);
                },
                .delete => |d| {
                    const op = txn.EncodedOperation{
                        .op_type = 1, // Delete
                        .op_flags = 0,
                        .key_len = @intCast(d.key.len),
                        .val_len = 0,
                        .key_bytes = d.key,
                        .val_bytes = &[_]u8{},
                    };
                    try op.serialize(writer);
                },
            }
        }
    }

    /// Calculate checksum of message (excluding checksum field)
    fn calculateChecksum(self: @This()) u32 {
        var hasher = std.hash.Crc32.init();
        hasher.update(std.mem.asBytes(&self.version));
        hasher.update(std.mem.asBytes(&self.message_type));
        hasher.update(std.mem.asBytes(&self.sequence));
        // Note: payload checksum calculation would happen during serialization
        // For now, return placeholder
        return hasher.final();
    }

    /// Deserialize message from byte stream
    pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !Self {
        const version = try reader.readInt(u16, .little);
        if (version != 1) return error.UnsupportedProtocolVersion;

        const type_val = try reader.readByte();
        const message_type = try std.meta.intToEnum(MessageType, type_val);

        const sequence = try reader.readInt(u64, .little);

        var commit_record: ?*const txn.CommitRecord = null;

        switch (message_type) {
            .heartbeat => {},
            .commit_record => {
                // Read commit payload header
                const header = try txn.CommitPayloadHeader.deserialize(reader);

                // Read mutations
                const mutations = try allocator.alloc(txn.Mutation, header.op_count);
                errdefer {
                    // Cleanup on error
                    for (mutations[0..header.op_count]) |m| {
                        switch (m) {
                            .put => |p| {
                                allocator.free(p.key);
                                allocator.free(p.value);
                            },
                            .delete => |d| {
                                allocator.free(d.key);
                            },
                        }
                    }
                    allocator.free(mutations);
                }

                for (0..header.op_count) |i| {
                    const op_type = try reader.readByte();
                    const op_flags = try reader.readByte();
                    const key_len = try reader.readInt(u16, .little);
                    const val_len = try reader.readInt(u32, .little);

                    if (op_flags != 0) return error.InvalidOperationFlags;

                    const key = try allocator.dupe(u8, try reader.readBytesNoEof(key_len));

                    switch (op_type) {
                        0 => { // Put
                            const value = try allocator.dupe(u8, try reader.readBytesNoEof(val_len));
                            mutations[i] = txn.Mutation{ .put = .{ .key = key, .value = value } };
                        },
                        1 => { // Delete
                            if (val_len != 0) return error.DeleteHasValue;
                            mutations[i] = txn.Mutation{ .delete = .{ .key = key } };
                        },
                        else => return error.InvalidOperationType,
                    }
                }

                const record = try allocator.create(txn.CommitRecord);
                record.* = txn.CommitRecord{
                    .txn_id = header.txn_id,
                    .root_page_id = header.root_page_id,
                    .mutations = mutations,
                    .checksum = 0,
                };
                record.checksum = record.calculatePayloadChecksum();
                commit_record = record;
            },
            .snapshot => {
                _ = try reader.readInt(u64, .little); // snapshot_lsn
            },
            .error_message => {
                _ = try reader.readInt(u16, .little); // error_code
                const msg_len = try reader.readInt(u32, .little);
                if (msg_len > 0) {
                    _ = try reader.readBytesNoEof(msg_len); // error_message
                }
            },
            .bootstrap_request => {
                _ = try reader.readInt(u64, .little); // start_lsn
            },
            .bootstrap_data => {
                _ = try reader.readInt(u32, .little); // chunk_size
                _ = try reader.readInt(u32, .little); // chunk_index
                _ = try reader.readInt(u32, .little); // total_chunks
                // Data would follow - for now skip
            },
            .bootstrap_complete => {
                _ = try reader.readInt(u64, .little); // final_lsn
            },
        }

        const checksum = try reader.readInt(u32, .little);

        return Self{
            .version = version,
            .message_type = message_type,
            .sequence = sequence,
            .commit_record = commit_record,
            .checksum = checksum,
        };
    }
};

/// Connection request from replica to primary
pub const ConnectRequest = struct {
    replica_id: u64,
    start_lsn: u64,
    protocol_version: u16 = 1,

    const Self = @This();

    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.replica_id, .little);
        try writer.writeInt(u64, self.start_lsn, .little);
        try writer.writeInt(u16, self.protocol_version, .little);
    }

    pub fn deserialize(reader: anytype) !Self {
        const replica_id = try reader.readInt(u64, .little);
        const start_lsn = try reader.readInt(u64, .little);
        const protocol_version = try reader.readInt(u16, .little);
        return Self{
            .replica_id = replica_id,
            .start_lsn = start_lsn,
            .protocol_version = protocol_version,
        };
    }
};

/// Accept response from primary to replica
pub const AcceptResponse = struct {
    current_lsn: u64,
    protocol_version: u16 = 1,

    const Self = @This();

    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.current_lsn, .little);
        try writer.writeInt(u16, self.protocol_version, .little);
    }

    pub fn deserialize(reader: anytype) !Self {
        const current_lsn = try reader.readInt(u64, .little);
        const protocol_version = try reader.readInt(u16, .little);
        return Self{
            .current_lsn = current_lsn,
            .protocol_version = protocol_version,
        };
    }
};

/// Acknowledgment from replica to primary
pub const AckMessage = struct {
    sequence: u64,
    applied_lsn: u64,

    const Self = @This();

    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.sequence, .little);
        try writer.writeInt(u64, self.applied_lsn, .little);
    }

    pub fn deserialize(reader: anytype) !Self {
        const sequence = try reader.readInt(u64, .little);
        const applied_lsn = try reader.readInt(u64, .little);
        return Self{
            .sequence = sequence,
            .applied_lsn = applied_lsn,
        };
    }
};

/// Heartbeat message
pub const HeartbeatMessage = struct {
    current_lsn: u64,
    timestamp_ms: u64,

    const Self = @This();

    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.current_lsn, .little);
        try writer.writeInt(u64, self.timestamp_ms, .little);
    }

    pub fn deserialize(reader: anytype) !Self {
        const current_lsn = try reader.readInt(u64, .little);
        const timestamp_ms = try reader.readInt(u64, .little);
        return Self{
            .current_lsn = current_lsn,
            .timestamp_ms = timestamp_ms,
        };
    }
};

/// Bootstrap request from replica to primary
pub const BootstrapRequest = struct {
    replica_id: u64,
    start_lsn: u64,
    protocol_version: u16 = 1,

    const Self = @This();

    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.replica_id, .little);
        try writer.writeInt(u64, self.start_lsn, .little);
        try writer.writeInt(u16, self.protocol_version, .little);
    }

    pub fn deserialize(reader: anytype) !Self {
        const replica_id = try reader.readInt(u64, .little);
        const start_lsn = try reader.readInt(u64, .little);
        const protocol_version = try reader.readInt(u16, .little);
        return Self{
            .replica_id = replica_id,
            .start_lsn = start_lsn,
            .protocol_version = protocol_version,
        };
    }
};

/// Bootstrap data message from primary to replica
pub const BootstrapData = struct {
    snapshot_lsn: u64,
    chunk_index: u32,
    total_chunks: u32,
    data: []const u8,

    const Self = @This();

    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.snapshot_lsn, .little);
        try writer.writeInt(u32, self.chunk_index, .little);
        try writer.writeInt(u32, self.total_chunks, .little);
        try writer.writeInt(u32, @intCast(self.data.len), .little);
        try writer.writeAll(self.data);
    }

    pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !Self {
        const snapshot_lsn = try reader.readInt(u64, .little);
        const chunk_index = try reader.readInt(u32, .little);
        const total_chunks = try reader.readInt(u32, .little);
        const data_len = try reader.readInt(u32, .little);
        const data = try allocator.alloc(u8, data_len);
        errdefer allocator.free(data);
        _ = try reader.readAll(data);
        return Self{
            .snapshot_lsn = snapshot_lsn,
            .chunk_index = chunk_index,
            .total_chunks = total_chunks,
            .data = data,
        };
    }
};

/// Bootstrap complete message
pub const BootstrapComplete = struct {
    final_lsn: u64,
    success: bool,

    const Self = @This();

    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.final_lsn, .little);
        try writer.writeByte(@intFromBool(self.success));
    }

    pub fn deserialize(reader: anytype) !Self {
        const final_lsn = try reader.readInt(u64, .little);
        const success_byte = try reader.readByte();
        const success = success_byte != 0;
        return Self{
            .final_lsn = final_lsn,
            .success = success,
        };
    }
};

// ==================== Unit Tests ====================

test "ReplicationMessage heartbeat serialization" {
    const msg = ReplicationMessage{
        .version = 1,
        .message_type = .heartbeat,
        .sequence = 0,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try msg.serialize(fbs.writer());

    try std.testing.expectEqual(@as(usize, 15), fbs.pos); // 2+1+8+4
}

test "ReplicationMessage commit_record serialization" {
    const testing_alloc = std.testing.allocator;
    const mutations = try testing_alloc.alloc(txn.Mutation, 1);
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

    const key = try testing_alloc.dupe(u8, "test_key");
    const value = try testing_alloc.dupe(u8, "test_value");
    mutations[0] = txn.Mutation{ .put = .{ .key = key, .value = value } };

    var record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = mutations,
        .checksum = 0,
    };
    record.checksum = record.calculatePayloadChecksum();

    const msg = ReplicationMessage{
        .version = 1,
        .message_type = .commit_record,
        .sequence = 1,
        .commit_record = &record,
    };

    var buffer: [1000]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try msg.serialize(fbs.writer());

    try std.testing.expect(fbs.pos > txn.CommitPayloadHeader.SIZE);
}

test "ConnectRequest serialization roundtrip" {
    const request = ConnectRequest{
        .replica_id = 123,
        .start_lsn = 456,
        .protocol_version = 1,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try request.serialize(fbs.writer());
    fbs.pos = 0;

    const parsed = try ConnectRequest.deserialize(fbs.reader());
    try std.testing.expectEqual(@as(u64, 123), parsed.replica_id);
    try std.testing.expectEqual(@as(u64, 456), parsed.start_lsn);
}

test "AcceptResponse serialization roundtrip" {
    const response = AcceptResponse{
        .current_lsn = 789,
        .protocol_version = 1,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try response.serialize(fbs.writer());
    fbs.pos = 0;

    const parsed = try AcceptResponse.deserialize(fbs.reader());
    try std.testing.expectEqual(@as(u64, 789), parsed.current_lsn);
}

test "AckMessage serialization roundtrip" {
    const ack = AckMessage{
        .sequence = 100,
        .applied_lsn = 99,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try ack.serialize(fbs.writer());
    fbs.pos = 0;

    const parsed = try AckMessage.deserialize(fbs.reader());
    try std.testing.expectEqual(@as(u64, 100), parsed.sequence);
    try std.testing.expectEqual(@as(u64, 99), parsed.applied_lsn);
}
