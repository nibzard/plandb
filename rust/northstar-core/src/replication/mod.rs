//! Replication module for NorthstarDB distributed features.
//!
//! This module provides primary-replica replication capabilities, allowing
//! NorthstarDB to scale reads across multiple nodes while maintaining
//! write consistency through a single primary.
//!
//! # Architecture
//!
//! - **Primary Node**: Accepts all writes and streams commit records to replicas
//! - **Replica Node**: Receives commit records and serves read-only queries
//! - **Publisher**: Streams commit records from primary to replicas
//! - **Subscriber**: Receives and applies commit records on replica
//!
//! # Example
//!
//! ```rust,no_run
//! use northstar_core::replication::{ReplicationRole, ReplicationConfig, PrimaryConfig};
//!
//! // Configure as primary
//! let config = ReplicationConfig::primary(
//!     "0.0.0.0:7233".to_string(),
//!     10, // max_replicas
//! );
//! ```

pub mod config;
pub mod error;
pub mod frame;
pub mod handlers;
pub mod protocol;
pub mod state;

// Re-exports
pub use config::{PrimaryConfig, ReplicaConfig, ReplicationConfig, ReplicationRole};
pub use error::ReplicationError;
pub use frame::{FrameHeader, FrameReader, FrameWriter};
pub use handlers::{HandshakeHandler, HeartbeatHandler, CommitRecordHandler, SnapshotHandler, ErrorHandler};
pub use protocol::{MessageType, ReplicationMessage};
pub use state::{ConnectionState, ReplicaInfo};

/// Current replication protocol version.
pub const PROTOCOL_VERSION: u16 = 1;

/// Default replication buffer size (100MB).
pub const DEFAULT_BUFFER_SIZE: u64 = 100 * 1024 * 1024;

/// Default maximum number of replicas.
pub const DEFAULT_MAX_REPLICAS: u32 = 10;

/// Default heartbeat interval in seconds.
pub const DEFAULT_HEARTBEAT_INTERVAL_SECS: u64 = 5;

/// Default replication lag target in milliseconds.
pub const DEFAULT_LAG_TARGET_MS: u64 = 100;

/// Default reconnect interval in milliseconds.
pub const DEFAULT_RECONNECT_INTERVAL_MS: u64 = 1000;

/// Maximum reconnect attempts before giving up.
pub const MAX_RECONNECT_ATTEMPTS: u32 = 10;

/// Buffer high watermark percentage (for backpressure).
pub const BUFFER_HIGH_WATERMARK_PCT: u64 = 80;

/// Buffer low watermark percentage (for backpressure).
pub const BUFFER_LOW_WATERMARK_PCT: u64 = 60;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_protocol_version() {
        assert_eq!(PROTOCOL_VERSION, 1);
    }

    #[test]
    fn test_default_constants() {
        assert_eq!(DEFAULT_BUFFER_SIZE, 100 * 1024 * 1024);
        assert_eq!(DEFAULT_MAX_REPLICAS, 10);
        assert_eq!(DEFAULT_HEARTBEAT_INTERVAL_SECS, 5);
        assert_eq!(DEFAULT_LAG_TARGET_MS, 100);
        assert_eq!(DEFAULT_RECONNECT_INTERVAL_MS, 1000);
    }

    #[test]
    fn test_watermark_constants() {
        assert_eq!(BUFFER_HIGH_WATERMARK_PCT, 80);
        assert_eq!(BUFFER_LOW_WATERMARK_PCT, 60);
        assert!(BUFFER_HIGH_WATERMARK_PCT > BUFFER_LOW_WATERMARK_PCT);
    }
}
