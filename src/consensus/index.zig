//! Consensus module - Raft implementation for NorthstarDB.
//!
//! This module implements the Raft consensus algorithm per spec/raft_v1.md.
//! It enables automatic leader election, log replication consistency, and
//! fault-tolerant failover.
//!
//! Architecture:
//! - Leader: Accepts writes, replicates log, handles heartbeats
//! - Follower: Accepts replicated log, serves reads, votes in elections
//! - Candidate: Transient role during leader election
//!
//! Key Design:
//! - WAL as Raft Log: Existing commit records become Raft log entries
//! - Leader-Full Consistency: Only leader accepts writes
//! - Single-Threaded Raft: Each node runs Raft in single event loop

const std = @import("std");

pub const raft = @import("raft.zig");
pub const rpc = @import("rpc.zig");
pub const config = @import("config.zig");
const _test = @import("test.zig");

// Re-export main types
pub const Raft = raft.Raft;
pub const RaftConfig = config.RaftConfig;
pub const NodeRole = config.NodeRole;
pub const RaftState = raft.RaftState;
pub const LogEntry = raft.LogEntry;
pub const RaftPersistentState = raft.RaftPersistentState;
pub const RequestVoteArgs = rpc.RequestVoteArgs;
pub const RequestVoteReply = rpc.RequestVoteReply;
pub const AppendEntriesArgs = rpc.AppendEntriesArgs;
pub const AppendEntriesReply = rpc.AppendEntriesReply;
pub const InstallSnapshotArgs = rpc.InstallSnapshotArgs;
pub const InstallSnapshotReply = rpc.InstallSnapshotReply;

// Error set
pub const RaftError = error{
    TermMismatch,
    LogConflict,
    NotLeader,
    NoLeader,
    SnapshotIncompatible,
    RPCFailed,
    ElectionTimeout,
    InvalidConfig,
};
