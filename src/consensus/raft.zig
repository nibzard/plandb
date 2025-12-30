//! Raft state machine implementation per spec/raft_v1.md.
//!
//! Implements:
//! - Persistent state (current_term, voted_for, log)
//! - Volatile state (commit_index, last_applied, next_index, match_index)
//! - State transitions (Follower -> Candidate -> Leader)
//! - Leader election
//! - Log replication
//! - Snapshotting (Phase 3)

const std = @import("std");
const txn = @import("../txn.zig");
const config = @import("config.zig");
const snapshot_mod = @import("snapshot.zig");

/// Raft state machine role
pub const RaftState = enum {
    follower,
    candidate,
    leader,
};

/// Raft log entry - wraps commit record with Raft metadata
pub const LogEntry = struct {
    term: u64,
    index: u64,
    command: Command,

    pub const Command = union(enum) {
        normal: txn.CommitRecord,
        // TODO: config: ClusterConfig, // For Phase 4: Configuration Changes
    };

    /// Create log entry from commit record
    pub fn fromCommitRecord(term: u64, index: u64, record: txn.CommitRecord) LogEntry {
        return .{
            .term = term,
            .index = index,
            .command = .{ .normal = record },
        };
    }
};

/// Raft persistent state (survives restarts)
pub const RaftPersistentState = struct {
    current_term: u64 = 0,
    voted_for: ?u64 = null, // node_id
    log: std.ArrayList(LogEntry),

    pub fn init(allocator: std.mem.Allocator) RaftPersistentState {
        return .{
            .current_term = 0,
            .voted_for = null,
            .log = std.ArrayList(LogEntry).init(allocator),
        };
    }

    pub fn deinit(self: *RaftPersistentState) void {
        self.log.deinit();
    }

    /// Get last log index
    pub fn lastLogIndex(self: *const RaftPersistentState) u64 {
        if (self.log.items.len == 0) return 0;
        return self.log.items[self.log.items.len - 1].index;
    }

    /// Get last log term
    pub fn lastLogTerm(self: *const RaftPersistentState) u64 {
        if (self.log.items.len == 0) return 0;
        return self.log.items[self.log.items.len - 1].term;
    }

    /// Get log entry at index (1-indexed, 0 = dummy entry)
    pub fn getEntry(self: *const RaftPersistentState, index: u64) ?LogEntry {
        if (index == 0) return null;
        if (index > self.log.items.len) return null;
        return self.log.items[index - 1];
    }

    /// Append entry to log
    pub fn appendEntry(self: *RaftPersistentState, entry: LogEntry) !void {
        try self.log.append(entry);
    }

    /// Truncate log from index (exclusive - keeps entries before index)
    pub fn truncateFrom(self: *RaftPersistentState, index: u64) void {
        if (index >= self.log.items.len) return;
        self.log.shrinkRetainingCapacity(@intCast(index));
    }
};

/// Leader-only volatile state
pub const LeaderVolatileState = struct {
    commit_index: u64 = 0,
    last_applied: u64 = 0,
    next_index: std.AutoHashMap(u64, u64),
    match_index: std.AutoHashMap(u64, u64),

    pub fn init(allocator: std.mem.Allocator, peer_ids: []const u64, last_log_index: u64) !LeaderVolatileState {
        var next = std.AutoHashMap(u64, u64).init(allocator);
        var match = std.AutoHashMap(u64, u64).init(allocator);

        // Initialize next_index to last_log_index + 1 for all peers
        for (peer_ids) |peer_id| {
            try next.put(peer_id, last_log_index + 1);
            try match.put(peer_id, 0);
        }

        return .{
            .commit_index = 0,
            .last_applied = 0,
            .next_index = next,
            .match_index = match,
        };
    }

    pub fn deinit(self: *LeaderVolatileState) void {
        self.next_index.deinit();
        self.match_index.deinit();
    }
};

/// Follower volatile state
pub const FollowerVolatileState = struct {
    commit_index: u64 = 0,
    last_applied: u64 = 0,
};

/// Raft consensus state machine
pub const Raft = struct {
    allocator: std.mem.Allocator,
    config: config.RaftConfig,

    // State
    role: RaftState = .follower,
    persistent: RaftPersistentState,
    leader_state: ?LeaderVolatileState = null,
    follower_state: FollowerVolatileState = .{},

    // Leader ID (known leader)
    current_leader_id: ?u64 = null,

    // Voted peers in current election
    votes_received: std.AutoHashMap(u64, void),

    // Election timeout
    election_deadline_ms: u64 = 0,
    rng: std.Random.DefaultPrng,

    // Snapshot manager (Phase 3)
    snapshot_manager: snapshot_mod.SnapshotManager,

    // RPC handler callbacks
    on_send_request_vote: ?*const fn (peer_id: u64, args: RequestVoteArgs) anyerror!RequestVoteReply = null,
    on_send_append_entries: ?*const fn (peer_id: u64, args: AppendEntriesArgs) anyerror!AppendEntriesReply = null,
    on_send_install_snapshot: ?*const fn (peer_id: u64, args: InstallSnapshotArgs) anyerror!InstallSnapshotReply = null,
    on_apply_entry: ?*const fn (entry: LogEntry) anyerror!void = null,
    on_state_change: ?*const fn (old_role: RaftState, new_role: RaftState) void = null,
    on_install_snapshot: ?*const fn (snap: snapshot_mod.Snapshot) anyerror!void = null,

    const Self = @This();

    /// Initialize Raft state machine
    pub fn init(allocator: std.mem.Allocator, cfg: config.RaftConfig) !Self {
        try cfg.validate();

        var rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));

        return Self{
            .allocator = allocator,
            .config = cfg,
            .persistent = RaftPersistentState.init(allocator),
            .votes_received = std.AutoHashMap(u64, void).init(allocator),
            .rng = rng,
            .election_deadline_ms = timestampMs() + config.randomElectionTimeout(cfg, &rng),
            .snapshot_manager = snapshot_mod.SnapshotManager.init(allocator),
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        if (self.leader_state) |*state| {
            state.deinit();
        }
        self.persistent.deinit();
        self.votes_received.deinit();
        self.snapshot_manager.deinit();
    }

    /// Reset election timeout with randomized value
    pub fn resetElectionTimeout(self: *Self) void {
        self.election_deadline_ms = timestampMs() + config.randomElectionTimeout(self.config, &self.rng);
    }

    /// Check if election timeout has expired
    pub fn isElectionTimeoutExpired(self: *const Self) bool {
        const now = timestampMs();
        return now >= self.election_deadline_ms;
    }

    /// Transition to follower role
    pub fn becomeFollower(self: *Self, new_term: u64) !void {
        const old_role = self.role;
        self.role = .follower;

        // Update term if higher
        if (new_term > self.persistent.current_term) {
            self.persistent.current_term = new_term;
            self.persistent.voted_for = null;
        }

        // Clear leader state
        if (self.leader_state) |*state| {
            state.deinit();
            self.leader_state = null;
        }

        // Clear votes
        self.votes_received.clearRetainingCapacity();

        // Notify callback
        if (self.on_state_change) |cb| {
            cb(old_role, .follower);
        }
    }

    /// Transition to candidate role and start election
    pub fn becomeCandidate(self: *Self) !void {
        const old_role = self.role;
        self.role = .candidate;

        // Increment term
        self.persistent.current_term += 1;
        self.persistent.voted_for = self.config.node_id;

        // Clear votes and vote for self
        self.votes_received.clearRetainingCapacity();
        try self.votes_received.put(self.config.node_id, {});

        // Reset election timeout
        self.resetElectionTimeout();

        // Notify callback
        if (self.on_state_change) |cb| {
            cb(old_role, .candidate);
        }
    }

    /// Transition to leader role
    pub fn becomeLeader(self: *Self) !void {
        const old_role = self.role;
        self.role = .leader;

        // Initialize leader state
        var peer_ids = try self.allocator.alloc(u64, self.config.peers.len);
        defer self.allocator.free(peer_ids);
        for (self.config.peers, 0..) |peer, i| {
            peer_ids[i] = peer.id;
        }

        self.leader_state = try LeaderVolatileState.init(
            self.allocator,
            peer_ids,
            self.persistent.lastLogIndex(),
        );

        // Notify callback
        if (self.on_state_change) |cb| {
            cb(old_role, .leader);
        }
    }

    /// Tick - called periodically to handle timeouts
    pub fn tick(self: *Self) !void {
        if (self.isElectionTimeoutExpired() and self.role != .leader) {
            // Start election
            try self.startElection();
        }
    }

    /// Start leader election
    pub fn startElection(self: *Self) !void {
        // Transition to candidate
        try self.becomeCandidate();

        // Send RequestVote to all peers
        for (self.config.peers) |peer| {
            const args = RequestVoteArgs{
                .term = self.persistent.current_term,
                .candidate_id = self.config.node_id,
                .last_log_index = self.persistent.lastLogIndex(),
                .last_log_term = self.persistent.lastLogTerm(),
            };

            if (self.on_send_request_vote) |cb| {
                const reply = cb(peer.id, args) catch |err| {
                    std.log.warn("RequestVote to peer {} failed: {}", .{ peer.id, err });
                    continue;
                };
                try self.handleRequestVoteReply(peer.id, args, reply);
            }
        }
    }

    /// Handle RequestVote reply
    pub fn handleRequestVoteReply(
        self: *Self,
        peer_id: u64,
        args: RequestVoteArgs,
        reply: RequestVoteReply,
    ) !void {
        // Update term if reply has higher term
        if (reply.term > self.persistent.current_term) {
            try self.becomeFollower(reply.term);
            return;
        }

        // Only process if we're still candidate in the same term
        if (self.role != .candidate) return;
        if (self.persistent.current_term != args.term) return;

        // Count vote if granted
        if (reply.vote_granted) {
            try self.votes_received.put(peer_id, {});

            // Check if we won election
            if (self.votes_received.count() >= self.config.majority()) {
                try self.becomeLeader();
            }
        }
    }

    /// Propose new entry (leader only)
    pub fn propose(self: *Self, record: txn.CommitRecord) !u64 {
        if (self.role != .leader) return error.NotLeader;

        const index = self.persistent.lastLogIndex() + 1;
        const entry = LogEntry.fromCommitRecord(self.persistent.current_term, index, record);
        try self.persistent.appendEntry(entry);

        return index;
    }

    /// Update commit index if entry is committed by majority
    pub fn updateCommitIndex(self: *Self) !void {
        if (self.role != .leader) return;
        const leader_state = &self.leader_state.?;

        for (self.persistent.log.items) |entry| {
            if (entry.index <= leader_state.commit_index) continue;

            // Count how many peers have replicated this entry
            var replicated_count: u64 = 1; // Count leader
            for (leader_state.match_index.values()) |match_idx| {
                if (match_idx >= entry.index) replicated_count += 1;
            }

            // Commit if majority has replicated
            if (replicated_count >= self.config.majority()) {
                leader_state.commit_index = entry.index;
            }
        }

        // Apply committed entries
        try self.applyCommittedEntries();
    }

    /// Apply committed entries to state machine
    pub fn applyCommittedEntries(self: *Self) !void {
        const commit_idx = if (self.role == .leader)
            self.leader_state.?.commit_index
        else
            self.follower_state.commit_index;

        const last_applied = if (self.role == .leader)
            &self.leader_state.?.last_applied
        else
            &self.follower_state.last_applied;

        while (last_applied.* < commit_idx) : (last_applied.* += 1) {
            const index = last_applied.* + 1;
            const entry = self.persistent.getEntry(index) orelse continue;

            // Apply entry
            if (self.on_apply_entry) |cb| {
                try cb(entry);
            }
        }
    }

    /// Leader heartbeat and replication loop - call periodically
    pub fn leaderLoop(self: *Self) !void {
        if (self.role != .leader) return;

        const leader_state = &self.leader_state.?;

        // Send AppendEntries to all followers
        for (self.config.peers) |peer| {
            const next_idx = leader_state.next_index.get(peer.id) orelse 1;

            // Check if follower is too far behind - send snapshot instead
            if (self.snapshot_manager.getSnapshot()) |snap| {
                if (next_idx <= snap.last_included_index) {
                    // Follower needs snapshot
                    if (self.on_send_install_snapshot) |cb| {
                        const snap_size = snap.size();
                        const buffer = try self.allocator.alloc(u8, snap_size);
                        defer self.allocator.free(buffer);

                        var fbs = std.io.fixedBufferStream(buffer);
                        try snap.serialize(fbs.writer());

                        const snap_args = InstallSnapshotArgs{
                            .term = self.persistent.current_term,
                            .leader_id = self.config.node_id,
                            .last_included_index = snap.last_included_index,
                            .last_included_term = snap.last_included_term,
                            .snapshot = buffer,
                        };

                        const reply = cb(peer.id, snap_args) catch |err| {
                            std.log.warn("InstallSnapshot to peer {} failed: {}", .{ peer.id, err });
                            continue;
                        };

                        if (reply.term > self.persistent.current_term) {
                            try self.becomeFollower(reply.term);
                            return;
                        }

                        // Update next_index after successful snapshot
                        try leader_state.next_index.put(peer.id, snap.last_included_index + 1);
                        try leader_state.match_index.put(peer.id, snap.last_included_index);
                        continue;
                    }
                }
            }

            const prev_idx = if (next_idx > 1) next_idx - 1 else 0;
            const prev_entry = self.persistent.getEntry(prev_idx);
            const prev_term = if (prev_entry) |e| e.term else 0;

            // Collect entries to send
            var entries = std.ArrayList(LogEntry).init(self.allocator);
            defer entries.deinit();

            var i: u64 = next_idx;
            while (i <= self.persistent.lastLogIndex()) : (i += 1) {
                if (self.persistent.getEntry(i)) |entry| {
                    try entries.append(entry);
                }
            }

            const args = AppendEntriesArgs{
                .term = self.persistent.current_term,
                .leader_id = self.config.node_id,
                .prev_log_index = prev_idx,
                .prev_log_term = prev_term,
                .entries = entries.items,
                .leader_commit = leader_state.commit_index,
            };

            if (self.on_send_append_entries) |cb| {
                const reply = cb(peer.id, args) catch |err| {
                    std.log.warn("AppendEntries to peer {} failed: {}", .{ peer.id, err });
                    continue;
                };
                try self.handleAppendEntriesReply(peer.id, args, reply);
            }
        }

        // Update commit index
        try self.updateCommitIndex();
    }

    /// Handle AppendEntries reply from follower
    pub fn handleAppendEntriesReply(
        self: *Self,
        peer_id: u64,
        args: AppendEntriesArgs,
        reply: AppendEntriesReply,
    ) !void {
        if (self.role != .leader) return;
        const leader_state = &self.leader_state.?;

        // Update term if reply has higher term
        if (reply.term > self.persistent.current_term) {
            try self.becomeFollower(reply.term);
            return;
        }

        // If successful, update next_index and match_index
        if (reply.success) {
            if (args.entries.len > 0) {
                const last_entry_idx = args.entries[args.entries.len - 1].index;
                try leader_state.next_index.put(peer_id, last_entry_idx + 1);
                try leader_state.match_index.put(peer_id, last_entry_idx);
            }
        } else {
            // Log conflict - backtrack next_index
            if (reply.conflict_index) |conflict_idx| {
                try leader_state.next_index.put(peer_id, conflict_idx);
            } else {
                const next_idx = leader_state.next_index.get(peer_id) orelse 1;
                try leader_state.next_index.put(peer_id, @max(1, next_idx - 1));
            }
        }
    }

    /// Handle incoming RequestVote RPC
    pub fn handleRequestVote(self: *Self, args: RequestVoteArgs) !RequestVoteReply {
        // If term < current_term, reject
        if (args.term < self.persistent.current_term) {
            return RequestVoteReply{
                .term = self.persistent.current_term,
                .vote_granted = false,
            };
        }

        // If term > current_term, become follower
        if (args.term > self.persistent.current_term) {
            try self.becomeFollower(args.term);
        }

        // Check if we can grant vote
        const log_ok = (args.last_log_term > self.persistent.lastLogTerm()) or
            (args.last_log_term == self.persistent.lastLogTerm() and
            args.last_log_index >= self.persistent.lastLogIndex());

        const vote_ok = (self.persistent.voted_for == null) or
            (self.persistent.voted_for == args.candidate_id);

        if (vote_ok and log_ok) {
            self.persistent.voted_for = args.candidate_id;
            self.resetElectionTimeout();
            return RequestVoteReply{
                .term = self.persistent.current_term,
                .vote_granted = true,
            };
        }

        return RequestVoteReply{
            .term = self.persistent.current_term,
            .vote_granted = false,
        };
    }

    /// Handle incoming AppendEntries RPC
    pub fn handleAppendEntries(self: *Self, args: AppendEntriesArgs) !AppendEntriesReply {
        // If term < current_term, reject
        if (args.term < self.persistent.current_term) {
            return AppendEntriesReply{
                .term = self.persistent.current_term,
                .success = false,
            };
        }

        // If term > current_term, become follower
        if (args.term > self.persistent.current_term) {
            try self.becomeFollower(args.term);
        }

        // Update known leader
        self.current_leader_id = args.leader_id;

        // Reset election timeout on receiving valid heartbeat
        self.resetElectionTimeout();

        // Check log consistency at prev_log_index
        if (args.prev_log_index > 0) {
            const prev_entry = self.persistent.getEntry(args.prev_log_index);
            if (prev_entry == null or prev_entry.?.term != args.prev_log_term) {
                // Log conflict - provide hint for backtracking
                const conflict_term = if (prev_entry != null)
                    prev_entry.?.term
                else
                    0;

                // Find last entry with conflict_term
                var conflict_index: ?u64 = null;
                if (conflict_term > 0) {
                    var i: u64 = self.persistent.lastLogIndex();
                    while (i > 0) : (i -= 1) {
                        if (self.persistent.getEntry(i)) |entry| {
                            if (entry.term == conflict_term) {
                                conflict_index = i;
                                break;
                            }
                        }
                    }
                }

                return AppendEntriesReply{
                    .term = self.persistent.current_term,
                    .success = false,
                    .conflict_index = conflict_index,
                    .conflict_term = if (conflict_term > 0) conflict_term else null,
                };
            }
        }

        // Append new entries
        if (args.entries.len > 0) {
            // If existing entries conflict with new ones, delete existing
            var i: usize = 0;
            while (i < args.entries.len) {
                const new_index = args.prev_log_index + 1 + @as(u64, @intCast(i));
                if (self.persistent.log.items.len > new_index) {
                    if (self.persistent.log.items[@intCast(new_index - 1)].term != args.entries[i].term) {
                        // Truncate log from this point
                        self.persistent.truncateFrom(new_index);
                        break;
                    }
                }
                i += 1;
            }

            // Append new entries
            for (args.entries) |entry| {
                try self.persistent.appendEntry(entry);
            }
        }

        // Update commit index
        if (args.leader_commit > self.follower_state.commit_index) {
            self.follower_state.commit_index = @min(
                args.leader_commit,
                self.persistent.lastLogIndex(),
            );
        }

        // Apply committed entries
        try self.applyCommittedEntries();

        return AppendEntriesReply{
            .term = self.persistent.current_term,
            .success = true,
        };
    }

    // ==================== Phase 3: Snapshotting ====================

    /// Check if snapshot is needed (log exceeds threshold)
    pub fn needsSnapshot(self: *const Self) bool {
        if (self.persistent.log.items.len < 100) return false; // Minimum threshold
        return self.persistent.log.items.len >= self.config.snapshot_entry_threshold;
    }

    /// Create snapshot from current state (leader only)
    pub fn createSnapshot(self: *Self, last_committed_txn_id: u64, root_page_id: u64) !void {
        if (self.role != .leader) return error.NotLeader;

        const last_applied = if (self.role == .leader)
            self.leader_state.?.last_applied
        else
            self.follower_state.last_applied;

        if (last_applied == 0) return; // No entries applied yet

        const last_entry = self.persistent.getEntry(last_applied) orelse return;

        try self.snapshot_manager.createSnapshot(
            last_entry.index,
            last_entry.term,
            last_committed_txn_id,
            root_page_id,
        );
    }

    /// Truncate log up to snapshot index (after snapshot is persisted)
    pub fn truncateLogAfterSnapshot(self: *Self) !void {
        const snap_meta = self.snapshot_manager.getMetadata();
        if (snap_meta.last_included_index == 0) return;

        // Truncate log entries up to and including snapshot index
        const truncate_count = @as(usize, @intCast(snap_meta.last_included_index));
        if (truncate_count >= self.persistent.log.items.len) {
            // Keep dummy entry at index 0
            self.persistent.log.shrinkRetainingCapacity(0);
        } else {
            // Remove entries from beginning
            const remaining = self.persistent.log.items[truncate_count..];
            // Create new list with remaining entries
            var new_log = std.ArrayList(LogEntry).init(self.allocator);
            for (remaining) |entry| {
                try new_log.append(entry);
            }
            self.persistent.log.deinit();
            self.persistent.log = new_log;
        }

        // Adjust leader's next_index if needed
        if (self.role == .leader and self.leader_state != null) {
            for (self.config.peers) |peer| {
                const next_idx = self.leader_state.?.next_index.get(peer.id) orelse continue;
                if (next_idx <= snap_meta.last_included_index) {
                    try self.leader_state.?.next_index.put(peer.id, snap_meta.last_included_index + 1);
                }
            }
        }
    }

    /// Handle InstallSnapshot RPC from leader
    pub fn handleInstallSnapshot(self: *Self, args: InstallSnapshotArgs) !InstallSnapshotReply {
        // If term < current_term, reject
        if (args.term < self.persistent.current_term) {
            return InstallSnapshotReply{
                .term = self.persistent.current_term,
            };
        }

        // If term > current_term, become follower
        if (args.term > self.persistent.current_term) {
            try self.becomeFollower(args.term);
        }

        // Update known leader
        self.current_leader_id = args.leader_id;

        // Reset election timeout
        self.resetElectionTimeout();

        // Deserialize snapshot
        var fbs = std.io.fixedBufferStream(args.snapshot);
        const snap = try snapshot_mod.Snapshot.deserialize(fbs.reader(), self.allocator);
        defer snap.deinit(self.allocator);

        // Check if we already have a more recent snapshot
        if (self.snapshot_manager.hasSnapshotCovering(snap.last_included_index)) {
            return InstallSnapshotReply{
                .term = self.persistent.current_term,
            };
        }

        // Install snapshot
        try self.snapshot_manager.restoreFromSnapshot(snap);

        // Truncate log up to snapshot index
        if (snap.last_included_index > 0) {
            const truncate_idx = @as(usize, @intCast(snap.last_included_index));
            if (truncate_idx < self.persistent.log.items.len) {
                self.persistent.truncateFrom(snap.last_included_index);
            }
        }

        // Update commit index and last_applied
        const commit_idx = if (self.role == .leader)
            &self.leader_state.?.commit_index
        else
            &self.follower_state.commit_index;

        const last_applied = if (self.role == .leader)
            &self.leader_state.?.last_applied
        else
            &self.follower_state.last_applied;

        if (snap.last_included_index > commit_idx.*) {
            commit_idx.* = snap.last_included_index;
        }
        if (snap.last_included_index > last_applied.*) {
            last_applied.* = snap.last_included_index;
        }

        // Notify callback to apply snapshot to state machine
        if (self.on_install_snapshot) |cb| {
            try cb(snap);
        }

        return InstallSnapshotReply{
            .term = self.persistent.current_term,
        };
    }

    /// Send InstallSnapshot to lagging follower (leader only)
    pub fn sendSnapshotToFollower(self: *Self, peer_id: u64) !InstallSnapshotReply {
        if (self.role != .leader) return error.NotLeader;

        const snap = self.snapshot_manager.getSnapshot() orelse return error.NoSnapshot;

        // Serialize snapshot
        const snap_size = snap.size();
        const buffer = try self.allocator.alloc(u8, snap_size);
        defer self.allocator.free(buffer);

        var fbs = std.io.fixedBufferStream(buffer);
        try snap.serialize(fbs.writer());

        const args = InstallSnapshotArgs{
            .term = self.persistent.current_term,
            .leader_id = self.config.node_id,
            .last_included_index = snap.last_included_index,
            .last_included_term = snap.last_included_term,
            .snapshot = buffer,
        };

        if (self.on_send_install_snapshot) |cb| {
            return cb(peer_id, args);
        }

        return error.NoInstallSnapshotCallback;
    }
};

/// RequestVote RPC arguments
pub const RequestVoteArgs = struct {
    term: u64,
    candidate_id: u64,
    last_log_index: u64,
    last_log_term: u64,
};

/// RequestVote RPC reply
pub const RequestVoteReply = struct {
    term: u64,
    vote_granted: bool,
};

/// AppendEntries RPC arguments
pub const AppendEntriesArgs = struct {
    term: u64,
    leader_id: u64,
    prev_log_index: u64,
    prev_log_term: u64,
    entries: []const LogEntry,
    leader_commit: u64,
};

/// AppendEntries RPC reply
pub const AppendEntriesReply = struct {
    term: u64,
    success: bool,
    conflict_index: ?u64 = null,
    conflict_term: ?u64 = null,
};

/// InstallSnapshot RPC arguments (Phase 3)
pub const InstallSnapshotArgs = struct {
    term: u64,
    leader_id: u64,
    last_included_index: u64,
    last_included_term: u64,
    snapshot: []const u8,
};

/// InstallSnapshot RPC reply
pub const InstallSnapshotReply = struct {
    term: u64,
};

/// Get current timestamp in milliseconds
fn timestampMs() u64 {
    const ns = std.time.nanoTimestamp();
    return @intCast(@abs(ns) / 1_000_000);
}

// ==================== Unit Tests ====================

test "RaftPersistentState tracks log entries" {
    const allocator = std.testing.allocator;
    var state = RaftPersistentState.init(allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(u64, 0), state.lastLogIndex());
    try std.testing.expectEqual(@as(u64, 0), state.lastLogTerm());

    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const entry = LogEntry.fromCommitRecord(1, 1, record);
    try state.appendEntry(entry);

    try std.testing.expectEqual(@as(u64, 1), state.lastLogIndex());
    try std.testing.expectEqual(@as(u64, 1), state.lastLogTerm());
}

test "RaftPersistentState getEntry" {
    const allocator = std.testing.allocator;
    var state = RaftPersistentState.init(allocator);
    defer state.deinit();

    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const entry1 = LogEntry.fromCommitRecord(1, 1, record);
    const entry2 = LogEntry.fromCommitRecord(1, 2, record);

    try state.appendEntry(entry1);
    try state.appendEntry(entry2);

    try std.testing.expect(state.getEntry(0) == null);
    try std.testing.expect(state.getEntry(1).?.term == 1);
    try std.testing.expect(state.getEntry(2).?.index == 2);
    try std.testing.expect(state.getEntry(3) == null);
}

test "RaftPersistentState truncateFrom" {
    const allocator = std.testing.allocator;
    var state = RaftPersistentState.init(allocator);
    defer state.deinit();

    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    for (0..5) |i| {
        const entry = LogEntry.fromCommitRecord(1, @intCast(i + 1), record);
        try state.appendEntry(entry);
    }

    try std.testing.expectEqual(@as(usize, 5), state.log.items.len);

    // Truncate from index 3 (keeps entries 1-2)
    state.truncateFrom(3);
    try std.testing.expectEqual(@as(usize, 2), state.log.items.len);
    try std.testing.expectEqual(@as(u64, 2), state.lastLogIndex());
}

test "Raft initializes as follower" {
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

    var raft = try Raft.init(allocator, cfg);
    defer raft.deinit();

    try std.testing.expectEqual(RaftState.follower, raft.role);
    try std.testing.expectEqual(@as(u64, 0), raft.persistent.current_term);
    try std.testing.expect(raft.persistent.voted_for == null);
}

test "Raft becomeCandidate increments term" {
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

    var raft = try Raft.init(allocator, cfg);
    defer raft.deinit();

    try raft.becomeCandidate();

    try std.testing.expectEqual(RaftState.candidate, raft.role);
    try std.testing.expectEqual(@as(u64, 1), raft.persistent.current_term);
    try std.testing.expectEqual(@as(u64, 1), raft.persistent.voted_for.?);
    try std.testing.expectEqual(@as(usize, 1), raft.votes_received.count());
}

test "Raft transition follower -> leader" {
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

    var raft = try Raft.init(allocator, cfg);
    defer raft.deinit();

    try raft.becomeCandidate();
    try raft.becomeLeader();

    try std.testing.expectEqual(RaftState.leader, raft.role);
    try std.testing.expect(raft.leader_state != null);
    try std.testing.expectEqual(@as(u64, 1), raft.leader_state.?.commit_index);
}

test "Raft becomeFollower clears leader state" {
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

    var raft = try Raft.init(allocator, cfg);
    defer raft.deinit();

    try raft.becomeCandidate();
    try raft.becomeLeader();
    try raft.becomeFollower(2);

    try std.testing.expectEqual(RaftState.follower, raft.role);
    try std.testing.expectEqual(@as(u64, 2), raft.persistent.current_term);
    try std.testing.expect(raft.leader_state == null);
    try std.testing.expectEqual(@as(usize, 0), raft.votes_received.count());
}

test "Raft propose fails on non-leader" {
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

    var raft = try Raft.init(allocator, cfg);
    defer raft.deinit();

    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    try std.testing.expectError(error.NotLeader, raft.propose(record));
}

test "Raft propose succeeds on leader" {
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

    var raft = try Raft.init(allocator, cfg);
    defer raft.deinit();

    try raft.becomeCandidate();
    try raft.becomeLeader();

    const record = txn.CommitRecord{
        .txn_id = 1,
        .root_page_id = 2,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const index = try raft.propose(record);
    try std.testing.expectEqual(@as(u64, 1), index);
    try std.testing.expectEqual(@as(usize, 1), raft.persistent.log.items.len);
}

test "LeaderVolatileState initialization" {
    const allocator = std.testing.allocator;
    const peer_ids = [_]u64{ 2, 3, 4 };

    var state = try LeaderVolatileState.init(allocator, &peer_ids, 10);
    defer state.deinit();

    try std.testing.expectEqual(@as(u64, 0), state.commit_index);
    try std.testing.expectEqual(@as(u64, 0), state.last_applied);

    // next_index should be initialized to last_log_index + 1
    try std.testing.expectEqual(@as(u64, 11), state.next_index.get(2).?);
    try std.testing.expectEqual(@as(u64, 11), state.next_index.get(3).?);
    try std.testing.expectEqual(@as(u64, 11), state.next_index.get(4).?);

    // match_index should be initialized to 0
    try std.testing.expectEqual(@as(u64, 0), state.match_index.get(2).?);
}

test "LogEntry fromCommitRecord" {
    const record = txn.CommitRecord{
        .txn_id = 42,
        .root_page_id = 5,
        .mutations = &[_]txn.Mutation{},
        .checksum = 0,
    };

    const entry = LogEntry.fromCommitRecord(3, 7, record);

    try std.testing.expectEqual(@as(u64, 3), entry.term);
    try std.testing.expectEqual(@as(u64, 7), entry.index);
    try std.testing.expectEqual(@as(u64, 42), entry.command.normal.txn_id);
}
