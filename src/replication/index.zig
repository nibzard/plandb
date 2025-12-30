//! Replication module - primary-replica replication for NorthstarDB.
//!
//! This module implements log-based replication per spec/replication_v1.md.
//! It transforms the commit record (the seam) into a streaming replication protocol.
//!
//! Architecture:
//! - Primary: Writes to local WAL, Publisher streams to replicas
//! - Replica: Subscriber pulls from primary, applies to local WAL
//! - Pull-based: Replicas initiate connection and manage reconnection
//! - Asynchronous: Writes ACK on primary before replication

const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const config = @import("config.zig");
pub const publisher = @import("publisher.zig");
pub const subscriber = @import("subscriber.zig");
pub const hardening = @import("hardening.zig");

// Re-export main types
pub const ReplicationMessage = protocol.ReplicationMessage;
pub const ReplicationConfig = config.ReplicationConfig;
pub const ReplicationRole = config.ReplicationRole;
pub const PrimaryConfig = config.PrimaryConfig;
pub const ReplicaConfig = config.ReplicaConfig;
pub const ReplicaState = config.ReplicaState;
pub const ReplicationPublisher = publisher.ReplicationPublisher;
pub const ReplicationSubscriber = subscriber.ReplicationSubscriber;

pub const ConnectRequest = protocol.ConnectRequest;
pub const AcceptResponse = protocol.AcceptResponse;
pub const AckMessage = protocol.AckMessage;
pub const HeartbeatMessage = protocol.HeartbeatMessage;
pub const BootstrapRequest = protocol.BootstrapRequest;
pub const BootstrapData = protocol.BootstrapData;
pub const BootstrapComplete = protocol.BootstrapComplete;

// Convenience constructors
pub const initPrimary = config.ReplicationConfig.initPrimary;
pub const initReplica = config.ReplicationConfig.initReplica;
