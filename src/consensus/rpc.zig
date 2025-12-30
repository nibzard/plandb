//! Raft RPC layer - network transport for Raft messages.
//!
//! Implements serialization and network transport for:
//! - RequestVote RPC (leader election)
//! - AppendEntries RPC (log replication/heartbeat)
//! - InstallSnapshot RPC (snapshot bootstrap)

const std = @import("std");
const raft = @import("raft.zig");
const txn = @import("../txn.zig");

/// RequestVote RPC arguments
pub const RequestVoteArgs = struct {
    term: u64,
    candidate_id: u64,
    last_log_index: u64,
    last_log_term: u64,

    const Self = @This();

    /// Serialize to byte stream
    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeInt(u64, self.candidate_id, .little);
        try writer.writeInt(u64, self.last_log_index, .little);
        try writer.writeInt(u64, self.last_log_term, .little);
    }

    /// Deserialize from byte stream
    pub fn deserialize(reader: anytype) !Self {
        const term = try reader.readInt(u64, .little);
        const candidate_id = try reader.readInt(u64, .little);
        const last_log_index = try reader.readInt(u64, .little);
        const last_log_term = try reader.readInt(u64, .little);

        return Self{
            .term = term,
            .candidate_id = candidate_id,
            .last_log_index = last_log_index,
            .last_log_term = last_log_term,
        };
    }

    /// Calculate serialized size
    pub fn size() usize {
        return 8 * 4; // 4 u64 fields
    }
};

/// RequestVote RPC reply
pub const RequestVoteReply = struct {
    term: u64,
    vote_granted: bool,

    const Self = @This();

    /// Serialize to byte stream
    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeByte(@intFromBool(self.vote_granted));
    }

    /// Deserialize from byte stream
    pub fn deserialize(reader: anytype) !Self {
        const term = try reader.readInt(u64, .little);
        const granted_byte = try reader.readByte();
        const vote_granted = granted_byte != 0;

        return Self{
            .term = term,
            .vote_granted = vote_granted,
        };
    }

    /// Calculate serialized size
    pub fn size() usize {
        return 8 + 1; // u64 + bool
    }
};

/// AppendEntries RPC arguments
pub const AppendEntriesArgs = struct {
    term: u64,
    leader_id: u64,
    prev_log_index: u64,
    prev_log_term: u64,
    leader_commit: u64,

    // Entries are serialized separately
    entry_count: u32 = 0,

    const Self = @This();

    /// Serialize header to byte stream (entries serialized separately)
    pub fn serializeHeader(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeInt(u64, self.leader_id, .little);
        try writer.writeInt(u64, self.prev_log_index, .little);
        try writer.writeInt(u64, self.prev_log_term, .little);
        try writer.writeInt(u32, self.entry_count, .little);
        try writer.writeInt(u64, self.leader_commit, .little);
    }

    /// Deserialize header from byte stream
    pub fn deserializeHeader(reader: anytype) !Self {
        const term = try reader.readInt(u64, .little);
        const leader_id = try reader.readInt(u64, .little);
        const prev_log_index = try reader.readInt(u64, .little);
        const prev_log_term = try reader.readInt(u64, .little);
        const entry_count = try reader.readInt(u32, .little);
        const leader_commit = try reader.readInt(u64, .little);

        return Self{
            .term = term,
            .leader_id = leader_id,
            .prev_log_index = prev_log_index,
            .prev_log_term = prev_log_term,
            .leader_commit = leader_commit,
            .entry_count = entry_count,
        };
    }

    /// Calculate header size (without entries)
    pub fn headerSize() usize {
        return 8 * 5 + 4; // 5 u64 + 1 u32
    }
};

/// Serialize LogEntry to byte stream for network transport
pub fn serializeLogEntry(entry: raft.LogEntry, writer: anytype) !void {
    try writer.writeInt(u64, entry.term, .little);
    try writer.writeInt(u64, entry.index, .little);

    // Serialize command type
    const cmd_type: u8 = switch (entry.command) {
        .normal => 0,
    };
    try writer.writeByte(cmd_type);

    // Serialize commit record
    const record = switch (entry.command) {
        .normal => |r| r,
    };
    try writer.writeInt(u64, record.txn_id, .little);
    try writer.writeInt(u64, record.root_page_id, .little);
    try writer.writeInt(u32, @intCast(record.mutations.len), .little);
    try writer.writeInt(u32, record.checksum, .little);

    // Serialize mutations
    for (record.mutations) |mutation| {
        switch (mutation) {
            .put => |p| {
                try writer.writeByte(0); // op_type = Put
                try writer.writeInt(u16, @intCast(p.key.len), .little);
                try writer.writeInt(u32, @intCast(p.value.len), .little);
                try writer.writeAll(p.key);
                try writer.writeAll(p.value);
            },
            .delete => |d| {
                try writer.writeByte(1); // op_type = Delete
                try writer.writeInt(u16, @intCast(d.key.len), .little);
                try writer.writeInt(u32, 0, .little);
                try writer.writeAll(d.key);
            },
        }
    }
}

/// Deserialize LogEntry from byte stream
pub fn deserializeLogEntry(reader: anytype, allocator: std.mem.Allocator) !raft.LogEntry {
    const term = try reader.readInt(u64, .little);
    const index = try reader.readInt(u64, .little);
    const cmd_type = try reader.readByte();

    if (cmd_type != 0) return error.UnsupportedCommandType;

    // Deserialize commit record
    const txn_id = try reader.readInt(u64, .little);
    const root_page_id = try reader.readInt(u64, .little);
    const mutation_count = try reader.readInt(u32, .little);
    const checksum = try reader.readInt(u32, .little);

    // Deserialize mutations
    var mutations = try std.ArrayList(txn.Mutation).initCapacity(allocator, mutation_count);
    errdefer {
        for (mutations.items) |m| {
            switch (m) {
                .put => |p| {
                    allocator.free(p.key);
                    allocator.free(p.value);
                },
                .delete => |d| allocator.free(d.key),
            }
        }
        mutations.deinit();
    }

    var i: u32 = 0;
    while (i < mutation_count) : (i += 1) {
        const op_type = try reader.readByte();
        const key_len = try reader.readInt(u16, .little);
        const val_len = try reader.readInt(u32, .little);

        const key = try allocator.alloc(u8, key_len);
        errdefer allocator.free(key);
        const bytes_read = try reader.readAll(key);
        if (bytes_read != key_len) return error.IncompleteKey;

        if (op_type == 0) {
            // Put
            const value = try allocator.alloc(u8, val_len);
            errdefer allocator.free(value);
            const val_bytes_read = try reader.readAll(value);
            if (val_bytes_read != val_len) return error.IncompleteValue;

            try mutations.append(allocator, txn.Mutation{ .put = .{ .key = key, .value = value } });
        } else {
            // Delete
            try mutations.append(allocator, txn.Mutation{ .delete = .{ .key = key } });
        }
    }

    const record = txn.CommitRecord{
        .txn_id = txn_id,
        .root_page_id = root_page_id,
        .mutations = mutations.toOwnedSlice(allocator),
        .checksum = checksum,
    };

    return raft.LogEntry{
        .term = term,
        .index = index,
        .command = .{ .normal = record },
    };
}

/// Serialize array of LogEntry to byte stream
pub fn serializeLogEntries(entries: []const raft.LogEntry, writer: anytype) !void {
    for (entries) |entry| {
        try serializeLogEntry(entry, writer);
    }
}

/// Deserialize array of LogEntry from byte stream
pub fn deserializeLogEntries(reader: anytype, allocator: std.mem.Allocator, count: u32) ![]raft.LogEntry {
    const entries = try allocator.alloc(raft.LogEntry, count);
    errdefer {
        for (entries) |*e| {
            if (e.command == .normal) {
                allocator.free(e.command.normal.mutations);
                for (e.command.normal.mutations) |m| {
                    switch (m) {
                        .put => |p| {
                            allocator.free(p.key);
                            allocator.free(p.value);
                        },
                        .delete => |d| allocator.free(d.key),
                    }
                }
            }
        }
        allocator.free(entries);
    }

    for (0..count) |i| {
        entries[i] = try deserializeLogEntry(reader, allocator);
    }

    return entries;
}

/// AppendEntries RPC reply
pub const AppendEntriesReply = struct {
    term: u64,
    success: bool,
    conflict_index: ?u64 = null,
    conflict_term: ?u64 = null,

    const Self = @This();

    /// Serialize to byte stream
    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeByte(@intFromBool(self.success));

        // Optional conflict fields
        const has_conflict = self.conflict_index != null;
        try writer.writeByte(@intFromBool(has_conflict));

        if (has_conflict) {
            try writer.writeInt(u64, self.conflict_index.?, .little);
            try writer.writeInt(u64, self.conflict_term.?, .little);
        }
    }

    /// Deserialize from byte stream
    pub fn deserialize(reader: anytype) !Self {
        const term = try reader.readInt(u64, .little);
        const success_byte = try reader.readByte();
        const success = success_byte != 0;

        const has_conflict_byte = try reader.readByte();
        const has_conflict = has_conflict_byte != 0;

        var conflict_index: ?u64 = null;
        var conflict_term: ?u64 = null;

        if (has_conflict) {
            conflict_index = try reader.readInt(u64, .little);
            conflict_term = try reader.readInt(u64, .little);
        }

        return Self{
            .term = term,
            .success = success,
            .conflict_index = conflict_index,
            .conflict_term = conflict_term,
        };
    }
};

/// InstallSnapshot RPC arguments
pub const InstallSnapshotArgs = struct {
    term: u64,
    leader_id: u64,
    last_included_index: u64,
    last_included_term: u64,
    snapshot_size: u64,

    const Self = @This();

    /// Serialize to byte stream (snapshot data sent separately)
    pub fn serializeHeader(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeInt(u64, self.leader_id, .little);
        try writer.writeInt(u64, self.last_included_index, .little);
        try writer.writeInt(u64, self.last_included_term, .little);
        try writer.writeInt(u64, self.snapshot_size, .little);
    }

    /// Calculate header size
    pub fn headerSize() usize {
        return 8 * 5; // 5 u64 fields
    }

    /// Deserialize from byte stream
    pub fn deserializeHeader(reader: anytype) !Self {
        const term = try reader.readInt(u64, .little);
        const leader_id = try reader.readInt(u64, .little);
        const last_included_index = try reader.readInt(u64, .little);
        const last_included_term = try reader.readInt(u64, .little);
        const snapshot_size = try reader.readInt(u64, .little);

        return Self{
            .term = term,
            .leader_id = leader_id,
            .last_included_index = last_included_index,
            .last_included_term = last_included_term,
            .snapshot_size = snapshot_size,
        };
    }
};

/// InstallSnapshot RPC reply
pub const InstallSnapshotReply = struct {
    term: u64,

    const Self = @This();

    /// Serialize to byte stream
    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.term, .little);
    }

    /// Deserialize from byte stream
    pub fn deserialize(reader: anytype) !Self {
        const term = try reader.readInt(u64, .little);
        return Self{ .term = term };
    }
};

/// RPC message type discriminator
pub const RpcMessageType = enum(u8) {
    request_vote = 1,
    request_vote_reply = 2,
    append_entries = 3,
    append_entries_reply = 4,
    install_snapshot = 5,
    install_snapshot_reply = 6,
};

/// RPC wrapper for network transport
pub const RpcMessage = struct {
    message_type: RpcMessageType,
    data: []const u8,

    const Self = @This();

    /// Serialize to byte stream
    pub fn serialize(self: @This(), writer: anytype) !void {
        try writer.writeByte(@intFromEnum(self.message_type));
        try writer.writeInt(u32, @intCast(self.data.len), .little);
        try writer.writeAll(self.data);
    }

    /// Deserialize from byte stream
    pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !Self {
        const type_val = try reader.readByte();
        const message_type = try std.meta.intToEnum(RpcMessageType, type_val);

        const data_len = try reader.readInt(u32, .little);
        const data = try allocator.alloc(u8, data_len);
        errdefer allocator.free(data);

        const bytes_read = try reader.readAll(data);
        if (bytes_read != data_len) return error.IncompleteMessage;

        return Self{
            .message_type = message_type,
            .data = data,
        };
    }
};

/// Raft RPC handler - implements RPC request processing
pub const RaftRpcHandler = struct {
    allocator: std.mem.Allocator,
    raft_impl: *raft.Raft,

    const Self = @This();

    /// Handle incoming RPC message
    pub fn handle(self: *Self, message: RpcMessage) ![]const u8 {
        const response_data = try self.allocator.alloc(u8, 4096); // Max response size
        errdefer self.allocator.free(response_data);

        var fbs = std.io.fixedBufferStream(response_data);
        const writer = fbs.writer();

        switch (message.message_type) {
            .request_vote => {
                const args = try RequestVoteArgs.deserialize(
                    &std.io.fixedBufferStream(message.data).reader(),
                );
                const reply = try self.handleRequestVote(args);
                try reply.serialize(writer);
                return response_data[0..fbs.pos];
            },
            .append_entries => {
                const args = try AppendEntriesArgs.deserializeHeader(
                    &std.io.fixedBufferStream(message.data).reader(),
                );
                const reply = try self.handleAppendEntries(args, message.data[AppendEntriesArgs.headerSize()..]);
                try reply.serialize(writer);
                return response_data[0..fbs.pos];
            },
            .install_snapshot => {
                const args = try InstallSnapshotArgs.deserializeHeader(
                    &std.io.fixedBufferStream(message.data).reader(),
                );
                // Snapshot data follows header
                const snapshot_data_offset = InstallSnapshotArgs.headerSize();
                const snapshot_data = if (message.data.len > snapshot_data_offset)
                    message.data[snapshot_data_offset..]
                else
                    &[_]u8{};
                const reply = try self.handleInstallSnapshot(args, snapshot_data);
                try reply.serialize(writer);
                return response_data[0..fbs.pos];
            },
            else => return error.UnsupportedRpcType,
        }
    }

    /// Handle RequestVote RPC
    fn handleRequestVote(self: *Self, args: RequestVoteArgs) !RequestVoteReply {
        // If term < current_term, reject
        if (args.term < self.raft_impl.persistent.current_term) {
            return RequestVoteReply{
                .term = self.raft_impl.persistent.current_term,
                .vote_granted = false,
            };
        }

        // If term > current_term, become follower
        if (args.term > self.raft_impl.persistent.current_term) {
            try self.raft_impl.becomeFollower(args.term);
        }

        // Check if we can grant vote
        const log_ok = (args.last_log_term > self.raft_impl.persistent.lastLogTerm()) or
            (args.last_log_term == self.raft_impl.persistent.lastLogTerm() and
            args.last_log_index >= self.raft_impl.persistent.lastLogIndex());

        const vote_ok = (self.raft_impl.persistent.voted_for == null) or
            (self.raft_impl.persistent.voted_for == args.candidate_id);

        if (vote_ok and log_ok) {
            self.raft_impl.persistent.voted_for = args.candidate_id;
            self.raft_impl.resetElectionTimeout();
            return RequestVoteReply{
                .term = self.raft_impl.persistent.current_term,
                .vote_granted = true,
            };
        }

        return RequestVoteReply{
            .term = self.raft_impl.persistent.current_term,
            .vote_granted = false,
        };
    }

    /// Handle AppendEntries RPC
    fn handleAppendEntries(self: *Self, args: AppendEntriesArgs, entries_data: []const u8) !AppendEntriesReply {
        // If term < current_term, reject
        if (args.term < self.raft_impl.persistent.current_term) {
            return AppendEntriesReply{
                .term = self.raft_impl.persistent.current_term,
                .success = false,
            };
        }

        // If term > current_term, become follower
        if (args.term > self.raft_impl.persistent.current_term) {
            try self.raft_impl.becomeFollower(args.term);
        }

        // Reset election timeout on receiving valid heartbeat
        self.raft_impl.resetElectionTimeout();

        // Check log consistency at prev_log_index
        if (args.prev_log_index > 0) {
            const prev_entry = self.raft_impl.persistent.getEntry(args.prev_log_index);
            if (prev_entry == null or prev_entry.?.term != args.prev_log_term) {
                // Log conflict - provide hint for backtracking
                const conflict_term = if (prev_entry != null)
                    prev_entry.?.term
                else
                    0;

                // Find last entry with conflict_term
                var conflict_index: ?u64 = null;
                if (conflict_term > 0) {
                    var i: u64 = self.raft_impl.persistent.lastLogIndex();
                    while (i > 0) : (i -= 1) {
                        if (self.raft_impl.persistent.getEntry(i)) |entry| {
                            if (entry.term == conflict_term) {
                                conflict_index = i;
                                break;
                            }
                        }
                    }
                }

                return AppendEntriesReply{
                    .term = self.raft_impl.persistent.current_term,
                    .success = false,
                    .conflict_index = conflict_index,
                    .conflict_term = if (conflict_term > 0) conflict_term else null,
                };
            }
        }

        // Parse entries from data
        var entries: []raft.LogEntry = &[_]raft.LogEntry{};
        if (args.entry_count > 0) {
            var fbs = std.io.fixedBufferStream(entries_data);
            const parsed = deserializeLogEntries(fbs.reader(), self.allocator, args.entry_count) catch |err| {
                std.log.warn("Failed to deserialize log entries: {}", .{err});
                return AppendEntriesReply{
                    .term = self.raft_impl.persistent.current_term,
                    .success = false,
                };
            };
            defer {
                for (parsed) |*e| {
                    if (e.command == .normal) {
                        self.allocator.free(e.command.normal.mutations);
                        for (e.command.normal.mutations) |m| {
                            switch (m) {
                                .put => |p| {
                                    self.allocator.free(p.key);
                                    self.allocator.free(p.value);
                                },
                                .delete => |d| self.allocator.free(d.key),
                            }
                        }
                    }
                }
                self.allocator.free(parsed);
            }
            entries = parsed;
        }

        // Build Raft AppendEntries args with entries
        const raft_args = raft.AppendEntriesArgs{
            .term = args.term,
            .leader_id = args.leader_id,
            .prev_log_index = args.prev_log_index,
            .prev_log_term = args.prev_log_term,
            .entries = entries,
            .leader_commit = args.leader_commit,
        };

        return try self.raft_impl.handleAppendEntries(raft_args);
    }

    /// Handle InstallSnapshot RPC
    fn handleInstallSnapshot(self: *Self, args: InstallSnapshotArgs, snapshot_data: []const u8) !InstallSnapshotReply {
        // Create InstallSnapshotArgs with full snapshot data
        const full_args = raft.InstallSnapshotArgs{
            .term = args.term,
            .leader_id = args.leader_id,
            .last_included_index = args.last_included_index,
            .last_included_term = args.last_included_term,
            .snapshot = snapshot_data,
        };

        return try self.raft_impl.handleInstallSnapshot(full_args);
    }
};

// ==================== Unit Tests ====================

test "RequestVoteArgs serialization roundtrip" {
    const args = RequestVoteArgs{
        .term = 5,
        .candidate_id = 2,
        .last_log_index = 10,
        .last_log_term = 5,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try args.serialize(fbs.writer());
    fbs.pos = 0;

    const parsed = try RequestVoteArgs.deserialize(fbs.reader());
    try std.testing.expectEqual(@as(u64, 5), parsed.term);
    try std.testing.expectEqual(@as(u64, 2), parsed.candidate_id);
    try std.testing.expectEqual(@as(u64, 10), parsed.last_log_index);
    try std.testing.expectEqual(@as(u64, 5), parsed.last_log_term);
}

test "RequestVoteReply serialization roundtrip" {
    const reply = RequestVoteReply{
        .term = 5,
        .vote_granted = true,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try reply.serialize(fbs.writer());
    fbs.pos = 0;

    const parsed = try RequestVoteReply.deserialize(fbs.reader());
    try std.testing.expectEqual(@as(u64, 5), parsed.term);
    try std.testing.expect(parsed.vote_granted);
}

test "AppendEntriesArgs header serialization roundtrip" {
    const args = AppendEntriesArgs{
        .term = 3,
        .leader_id = 1,
        .prev_log_index = 5,
        .prev_log_term = 2,
        .leader_commit = 7,
        .entry_count = 2,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try args.serializeHeader(fbs.writer());
    fbs.pos = 0;

    const parsed = try AppendEntriesArgs.deserializeHeader(fbs.reader());
    try std.testing.expectEqual(@as(u64, 3), parsed.term);
    try std.testing.expectEqual(@as(u64, 1), parsed.leader_id);
    try std.testing.expectEqual(@as(u64, 5), parsed.prev_log_index);
    try std.testing.expectEqual(@as(u64, 2), parsed.prev_log_term);
    try std.testing.expectEqual(@as(u64, 7), parsed.leader_commit);
    try std.testing.expectEqual(@as(u32, 2), parsed.entry_count);
}

test "AppendEntriesReply serialization roundtrip" {
    const reply = AppendEntriesReply{
        .term = 3,
        .success = false,
        .conflict_index = 4,
        .conflict_term = 2,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try reply.serialize(fbs.writer());
    fbs.pos = 0;

    const parsed = try AppendEntriesReply.deserialize(fbs.reader());
    try std.testing.expectEqual(@as(u64, 3), parsed.term);
    try std.testing.expect(!parsed.success);
    try std.testing.expectEqual(@as(u64, 4), parsed.conflict_index.?);
    try std.testing.expectEqual(@as(u64, 2), parsed.conflict_term.?);
}

test "InstallSnapshotArgs header serialization roundtrip" {
    const args = InstallSnapshotArgs{
        .term = 2,
        .leader_id = 1,
        .last_included_index = 100,
        .last_included_term = 2,
        .snapshot_size = 1024,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try args.serializeHeader(fbs.writer());
    fbs.pos = 0;

    const parsed = try InstallSnapshotArgs.deserializeHeader(fbs.reader());
    try std.testing.expectEqual(@as(u64, 2), parsed.term);
    try std.testing.expectEqual(@as(u64, 1), parsed.leader_id);
    try std.testing.expectEqual(@as(u64, 100), parsed.last_included_index);
    try std.testing.expectEqual(@as(u64, 2), parsed.last_included_term);
    try std.testing.expectEqual(@as(u64, 1024), parsed.snapshot_size);
}

test "InstallSnapshotReply serialization roundtrip" {
    const reply = InstallSnapshotReply{
        .term = 2,
    };

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try reply.serialize(fbs.writer());
    fbs.pos = 0;

    const parsed = try InstallSnapshotReply.deserialize(fbs.reader());
    try std.testing.expectEqual(@as(u64, 2), parsed.term);
}
