//! Replication error types.
//!
//! Defines errors that can occur during replication operations.

use std::io;

/// Errors that can occur during replication operations.
#[derive(Debug, thiserror::Error)]
pub enum ReplicationError {
    /// I/O error during network or file operations.
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),

    /// Configuration error.
    #[error("Configuration error: {0}")]
    Config(String),

    /// Protocol version mismatch.
    #[error("Protocol version mismatch: expected {expected}, got {actual}")]
    ProtocolVersionMismatch {
        expected: u16,
        actual: u16,
    },

    /// Invalid message format.
    #[error("Invalid message format: {0}")]
    InvalidMessage(String),

    /// Checksum validation failed.
    #[error("Checksum validation failed")]
    ChecksumError,

    /// Sequence number not monotonically increasing.
    #[error("Sequence error: expected {expected}, got {actual}")]
    SequenceError {
        expected: u64,
        actual: u64,
    },

    /// Connection lost.
    #[error("Connection lost: {reason}")]
    ConnectionLost { reason: String },

    /// Connection timeout.
    #[error("Connection timeout after {timeout_ms}ms")]
    ConnectionTimeout { timeout_ms: u64 },

    /// Handshake failed.
    #[error("Handshake failed: {reason}")]
    HandshakeFailed { reason: String },

    /// Authentication failed.
    #[error("Authentication failed: {reason}")]
    AuthenticationFailed { reason: String },

    /// LSN not found on primary.
    #[error("LSN {lsn} not found on primary")]
    LsnNotFound { lsn: u64 },

    /// Replication buffer overflow.
    #[error("Replication buffer overflow: {size} bytes exceeds capacity {capacity}")]
    BufferOverflow {
        size: u64,
        capacity: u64,
    },

    /// Replication lag exceeds target.
    #[error("Replication lag {lag_ms}ms exceeds target {target_ms}ms")]
    LagExceeded {
        lag_ms: u64,
        target_ms: u64,
    },

    /// Bootstrap failed.
    #[error("Bootstrap failed: {reason}")]
    BootstrapFailed { reason: String },

    /// Maximum reconnect attempts exceeded.
    #[error("Maximum reconnect attempts exceeded: {attempts}")]
    MaxReconnectAttemptsExceeded { attempts: u32 },

    /// Replica not found.
    #[error("Replica {replica_id} not found")]
    ReplicaNotFound { replica_id: u64 },

    /// Primary not available.
    #[error("Primary not available: {reason}")]
    PrimaryNotAvailable { reason: String },

    /// Network partition detected.
    #[error("Network partition detected: {details}")]
    NetworkPartition { details: String },

    /// Corrupted data detected.
    #[error("Corrupted data: {details}")]
    CorruptedData { details: String },
}

impl ReplicationError {
    /// Create a configuration error.
    pub fn config(msg: impl Into<String>) -> Self {
        Self::Config(msg.into())
    }

    /// Create a protocol version mismatch error.
    pub fn protocol_version_mismatch(expected: u16, actual: u16) -> Self {
        Self::ProtocolVersionMismatch { expected, actual }
    }

    /// Create an invalid message error.
    pub fn invalid_message(msg: impl Into<String>) -> Self {
        Self::InvalidMessage(msg.into())
    }

    /// Create a sequence error.
    pub fn sequence_error(expected: u64, actual: u64) -> Self {
        Self::SequenceError { expected, actual }
    }

    /// Create a connection lost error.
    pub fn connection_lost(reason: impl Into<String>) -> Self {
        Self::ConnectionLost {
            reason: reason.into(),
        }
    }

    /// Create a connection timeout error.
    pub fn connection_timeout(timeout_ms: u64) -> Self {
        Self::ConnectionTimeout { timeout_ms }
    }

    /// Create a handshake failed error.
    pub fn handshake_failed(reason: impl Into<String>) -> Self {
        Self::HandshakeFailed {
            reason: reason.into(),
        }
    }

    /// Create an authentication failed error.
    pub fn authentication_failed(reason: impl Into<String>) -> Self {
        Self::AuthenticationFailed {
            reason: reason.into(),
        }
    }

    /// Create an LSN not found error.
    pub fn lsn_not_found(lsn: u64) -> Self {
        Self::LsnNotFound { lsn }
    }

    /// Create a buffer overflow error.
    pub fn buffer_overflow(size: u64, capacity: u64) -> Self {
        Self::BufferOverflow { size, capacity }
    }

    /// Create a lag exceeded error.
    pub fn lag_exceeded(lag_ms: u64, target_ms: u64) -> Self {
        Self::LagExceeded { lag_ms, target_ms }
    }

    /// Create a bootstrap failed error.
    pub fn bootstrap_failed(reason: impl Into<String>) -> Self {
        Self::BootstrapFailed {
            reason: reason.into(),
        }
    }

    /// Create a max reconnect attempts exceeded error.
    pub fn max_reconnect_attempts_exceeded(attempts: u32) -> Self {
        Self::MaxReconnectAttemptsExceeded { attempts }
    }

    /// Create a replica not found error.
    pub fn replica_not_found(replica_id: u64) -> Self {
        Self::ReplicaNotFound { replica_id }
    }

    /// Create a primary not available error.
    pub fn primary_not_available(reason: impl Into<String>) -> Self {
        Self::PrimaryNotAvailable {
            reason: reason.into(),
        }
    }

    /// Create a network partition error.
    pub fn network_partition(details: impl Into<String>) -> Self {
        Self::NetworkPartition {
            details: details.into(),
        }
    }

    /// Create a corrupted data error.
    pub fn corrupted_data(details: impl Into<String>) -> Self {
        Self::CorruptedData {
            details: details.into(),
        }
    }

    /// Create an I/O error.
    pub fn io_error(msg: impl Into<String>) -> Self {
        Self::Io(io::Error::new(io::ErrorKind::Other, msg.into()))
    }

    /// Create a handshake timeout error.
    pub fn handshake_timeout(timeout_secs: u64) -> Self {
        Self::HandshakeFailed {
            reason: format!("Timeout after {}s", timeout_secs),
        }
    }

    /// Create a connection failed error.
    pub fn connection_failed(addr: String, reason: String) -> Self {
        Self::PrimaryNotAvailable {
            reason: format!("Failed to connect to {}: {}", addr, reason),
        }
    }

    /// Create a protocol error.
    pub fn protocol_error(msg: impl Into<String>) -> Self {
        Self::InvalidMessage(msg.into())
    }

    /// Create a not connected error.
    pub fn not_connected() -> Self {
        Self::ConnectionLost {
            reason: "Not connected to primary".to_string(),
        }
    }

    /// Create a remote error.
    pub fn remote_error(msg: String) -> Self {
        Self::PrimaryNotAvailable {
            reason: format!("Remote error: {}", msg),
        }
    }

    /// Create a version mismatch error.
    pub fn version_mismatch(actual: u16, expected: u16) -> Self {
        Self::ProtocolVersionMismatch { expected, actual }
    }

    /// Create a channel closed error.
    pub fn channel_closed(msg: impl Into<String>) -> Self {
        Self::ConnectionLost {
            reason: msg.into(),
        }
    }

    /// Create a checksum validation error.
    pub fn checksum_error() -> Self {
        Self::ChecksumError
    }

    /// Check if this error is retryable.
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            Self::ConnectionLost { .. }
                | Self::ConnectionTimeout { .. }
                | Self::Io(_)
                | Self::NetworkPartition { .. }
        )
    }

    /// Check if this error is a terminal error.
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::AuthenticationFailed { .. }
                | Self::MaxReconnectAttemptsExceeded { .. }
                | Self::CorruptedData { .. }
        )
    }
}

/// Result type for replication operations.
pub type Result<T> = std::result::Result<T, ReplicationError>;

/// Alias for Result type for convenience.
pub type ReplicationResult<T> = Result<T>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_creation() {
        let err = ReplicationError::config("invalid config");
        assert!(matches!(err, ReplicationError::Config(_)));

        let err = ReplicationError::protocol_version_mismatch(1, 2);
        assert!(matches!(err, ReplicationError::ProtocolVersionMismatch { .. }));

        let err = ReplicationError::invalid_message("bad format");
        assert!(matches!(err, ReplicationError::InvalidMessage(_)));
    }

    #[test]
    fn test_error_is_retryable() {
        assert!(ReplicationError::connection_lost("test").is_retryable());
        assert!(ReplicationError::connection_timeout(1000).is_retryable());
        assert!(ReplicationError::Io(io::Error::new(io::ErrorKind::ConnectionReset, "test")).is_retryable());
        assert!(ReplicationError::network_partition("test").is_retryable());

        assert!(!ReplicationError::ChecksumError.is_retryable());
        assert!(!ReplicationError::Config("test".to_string()).is_retryable());
    }

    #[test]
    fn test_error_is_terminal() {
        assert!(ReplicationError::authentication_failed("test").is_terminal());
        assert!(ReplicationError::max_reconnect_attempts_exceeded(10).is_terminal());
        assert!(ReplicationError::corrupted_data("test").is_terminal());

        assert!(!ReplicationError::connection_lost("test").is_terminal());
        assert!(!ReplicationError::ChecksumError.is_terminal());
    }

    #[test]
    fn test_error_display() {
        let err = ReplicationError::Config("invalid value".to_string());
        assert_eq!(err.to_string(), "Configuration error: invalid value");

        let err = ReplicationError::protocol_version_mismatch(1, 2);
        assert!(err.to_string().contains("expected 1"));
        assert!(err.to_string().contains("got 2"));

        let err = ReplicationError::ChecksumError;
        assert_eq!(err.to_string(), "Checksum validation failed");
    }

    #[test]
    fn test_sequence_error() {
        let err = ReplicationError::sequence_error(100, 99);
        assert!(matches!(err, ReplicationError::SequenceError { expected: 100, actual: 99 }));
        assert!(err.to_string().contains("expected 100"));
        assert!(err.to_string().contains("got 99"));
    }

    #[test]
    fn test_buffer_overflow() {
        let err = ReplicationError::buffer_overflow(200, 100);
        assert!(matches!(err, ReplicationError::BufferOverflow { size: 200, capacity: 100 }));
        assert!(err.to_string().contains("200 bytes"));
        assert!(err.to_string().contains("capacity 100"));
    }

    #[test]
    fn test_lag_exceeded() {
        let err = ReplicationError::lag_exceeded(150, 100);
        assert!(matches!(err, ReplicationError::LagExceeded { lag_ms: 150, target_ms: 100 }));
        assert!(err.to_string().contains("150ms"));
        assert!(err.to_string().contains("target 100ms"));
    }

    #[test]
    fn test_replica_not_found() {
        let err = ReplicationError::replica_not_found(123);
        assert!(matches!(err, ReplicationError::ReplicaNotFound { replica_id: 123 }));
        assert!(err.to_string().contains("Replica 123"));
    }

    #[test]
    fn test_lsn_not_found() {
        let err = ReplicationError::lsn_not_found(456);
        assert!(matches!(err, ReplicationError::LsnNotFound { lsn: 456 }));
        assert!(err.to_string().contains("LSN 456"));
    }
}
