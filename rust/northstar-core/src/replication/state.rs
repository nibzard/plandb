//! Replication state types for connection lifecycle and replica tracking.
//!
//! Defines the state machine for replica connections and runtime state
//! tracking for connected replicas.

use serde::{Deserialize, Serialize};
use std::time::Instant;

/// State machine for replica connection lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ConnectionState {
    /// No active connection, attempting to reconnect.
    Disconnected,

    /// Establishing connection to primary.
    Connecting,

    /// Active connection, replicating normally.
    Connected,

    /// Resuming replication from last acknowledged position.
    Catchup,

    /// Encountered non-recoverable error, requires intervention.
    Error,
}

impl ConnectionState {
    /// Returns true if this state represents an active connection.
    pub const fn is_connected(&self) -> bool {
        matches!(self, Self::Connected | Self::Catchup)
    }

    /// Returns true if this state allows sending data.
    pub const fn can_send(&self) -> bool {
        matches!(self, Self::Connected | Self::Catchup)
    }

    /// Returns true if this state allows receiving data.
    pub const fn can_receive(&self) -> bool {
        matches!(self, Self::Connected | Self::Catchup)
    }

    /// Returns true if this state requires reconnection.
    pub const fn needs_reconnect(&self) -> bool {
        matches!(self, Self::Disconnected | Self::Error)
    }

    /// Returns true if this state is a terminal error state.
    pub const fn is_terminal(&self) -> bool {
        matches!(self, Self::Error)
    }
}

impl Default for ConnectionState {
    fn default() -> Self {
        Self::Disconnected
    }
}

/// Runtime state tracking for a connected replica.
#[derive(Debug, Clone, Serialize)]
pub struct ReplicaInfo {
    /// Unique identifier for this replica.
    pub replica_id: u64,

    /// Current connection status.
    pub connected: bool,

    /// Highest sequence number acknowledged by replica.
    pub last_ack_sequence: u64,

    /// Current replication lag (primary_lsn - applied_lsn) in milliseconds.
    pub replication_lag_ms: u64,

    /// When replica connected (None if not connected).
    #[serde(skip)]
    pub connect_time: Option<Instant>,

    /// Time of last heartbeat received (None if never received).
    #[serde(skip)]
    pub last_heartbeat: Option<Instant>,

    /// Current connection state.
    pub state: ConnectionState,

    /// Number of bytes sent to this replica.
    pub bytes_sent: u64,

    /// Number of messages sent to this replica.
    pub messages_sent: u64,

    /// Number of errors encountered with this replica.
    pub error_count: u64,
}

impl ReplicaInfo {
    /// Create a new replica info with the given ID.
    pub fn new(replica_id: u64) -> Self {
        Self {
            replica_id,
            connected: false,
            last_ack_sequence: 0,
            replication_lag_ms: 0,
            connect_time: None,
            last_heartbeat: None,
            state: ConnectionState::Disconnected,
            bytes_sent: 0,
            messages_sent: 0,
            error_count: 0,
        }
    }

    /// Mark this replica as connected.
    pub fn mark_connected(&mut self) {
        self.connected = true;
        self.state = ConnectionState::Connected;
        self.connect_time = Some(Instant::now());
        self.error_count = 0;
    }

    /// Mark this replica as disconnected.
    pub fn mark_disconnected(&mut self) {
        self.connected = false;
        self.state = ConnectionState::Disconnected;
        self.connect_time = None;
        self.last_heartbeat = None;
    }

    /// Mark this replica as in catchup mode.
    pub fn mark_catchup(&mut self) {
        self.state = ConnectionState::Catchup;
    }

    /// Mark this replica as in error state.
    pub fn mark_error(&mut self) {
        self.connected = false;
        self.state = ConnectionState::Error;
    }

    /// Update the last acknowledged sequence number.
    pub fn update_ack_sequence(&mut self, sequence: u64) {
        self.last_ack_sequence = sequence;
    }

    /// Update the replication lag.
    pub fn update_lag(&mut self, lag_ms: u64) {
        self.replication_lag_ms = lag_ms;
    }

    /// Record a heartbeat from this replica.
    pub fn record_heartbeat(&mut self) {
        self.last_heartbeat = Some(Instant::now());
    }

    /// Record bytes sent to this replica.
    pub fn record_bytes_sent(&mut self, bytes: u64) {
        self.bytes_sent += bytes;
    }

    /// Record a message sent to this replica.
    pub fn record_message_sent(&mut self) {
        self.messages_sent += 1;
    }

    /// Record an error with this replica.
    pub fn record_error(&mut self) {
        self.error_count += 1;
    }

    /// Check if the replica has exceeded the heartbeat timeout.
    pub fn heartbeat_timeout(&self, timeout_secs: u64) -> bool {
        if let Some(last) = self.last_heartbeat {
            last.elapsed().as_secs() > timeout_secs
        } else {
            true // No heartbeat received yet
        }
    }

    /// Get the duration since connection.
    pub fn connected_duration(&self) -> Option<std::time::Duration> {
        self.connect_time.map(|t| t.elapsed())
    }

    /// Get the duration since last heartbeat.
    pub fn last_heartbeat_age(&self) -> Option<std::time::Duration> {
        self.last_heartbeat.map(|t| t.elapsed())
    }

    /// Check if replication lag exceeds the target.
    pub fn lag_exceeds_target(&self, target_ms: u64) -> bool {
        self.replication_lag_ms > target_ms
    }
}

impl Default for ReplicaInfo {
    fn default() -> Self {
        Self::new(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_connection_state_methods() {
        assert!(ConnectionState::Connected.is_connected());
        assert!(ConnectionState::Catchup.is_connected());
        assert!(!ConnectionState::Disconnected.is_connected());
        assert!(!ConnectionState::Connecting.is_connected());
        assert!(!ConnectionState::Error.is_connected());

        assert!(ConnectionState::Connected.can_send());
        assert!(ConnectionState::Catchup.can_send());
        assert!(!ConnectionState::Disconnected.can_send());

        assert!(ConnectionState::Connected.can_receive());
        assert!(ConnectionState::Catchup.can_receive());
        assert!(!ConnectionState::Error.can_receive());

        assert!(ConnectionState::Disconnected.needs_reconnect());
        assert!(ConnectionState::Error.needs_reconnect());
        assert!(!ConnectionState::Connected.needs_reconnect());

        assert!(ConnectionState::Error.is_terminal());
        assert!(!ConnectionState::Disconnected.is_terminal());
    }

    #[test]
    fn test_connection_state_default() {
        assert_eq!(ConnectionState::default(), ConnectionState::Disconnected);
    }

    #[test]
    fn test_replica_info_new() {
        let info = ReplicaInfo::new(123);
        assert_eq!(info.replica_id, 123);
        assert!(!info.connected);
        assert_eq!(info.last_ack_sequence, 0);
        assert_eq!(info.replication_lag_ms, 0);
        assert!(info.connect_time.is_none());
        assert!(info.last_heartbeat.is_none());
        assert_eq!(info.state, ConnectionState::Disconnected);
        assert_eq!(info.bytes_sent, 0);
        assert_eq!(info.messages_sent, 0);
        assert_eq!(info.error_count, 0);
    }

    #[test]
    fn test_replica_info_mark_connected() {
        let mut info = ReplicaInfo::new(1);
        info.mark_connected();

        assert!(info.connected);
        assert_eq!(info.state, ConnectionState::Connected);
        assert!(info.connect_time.is_some());
        assert_eq!(info.error_count, 0);
    }

    #[test]
    fn test_replica_info_mark_disconnected() {
        let mut info = ReplicaInfo::new(1);
        info.mark_connected();
        info.mark_disconnected();

        assert!(!info.connected);
        assert_eq!(info.state, ConnectionState::Disconnected);
        assert!(info.connect_time.is_none());
        assert!(info.last_heartbeat.is_none());
    }

    #[test]
    fn test_replica_info_mark_catchup() {
        let mut info = ReplicaInfo::new(1);
        info.mark_catchup();

        assert_eq!(info.state, ConnectionState::Catchup);
        assert!(info.state.is_connected());
    }

    #[test]
    fn test_replica_info_mark_error() {
        let mut info = ReplicaInfo::new(1);
        info.mark_connected();
        info.mark_error();

        assert!(!info.connected);
        assert_eq!(info.state, ConnectionState::Error);
        assert!(info.state.is_terminal());
    }

    #[test]
    fn test_replica_info_update_ack_sequence() {
        let mut info = ReplicaInfo::new(1);
        info.update_ack_sequence(100);
        assert_eq!(info.last_ack_sequence, 100);

        info.update_ack_sequence(200);
        assert_eq!(info.last_ack_sequence, 200);
    }

    #[test]
    fn test_replica_info_update_lag() {
        let mut info = ReplicaInfo::new(1);
        info.update_lag(50);
        assert_eq!(info.replication_lag_ms, 50);
        assert!(!info.lag_exceeds_target(100));

        info.update_lag(150);
        assert_eq!(info.replication_lag_ms, 150);
        assert!(info.lag_exceeds_target(100));
    }

    #[test]
    fn test_replica_info_record_heartbeat() {
        let mut info = ReplicaInfo::new(1);
        assert!(info.last_heartbeat.is_none());

        info.record_heartbeat();
        assert!(info.last_heartbeat.is_some());
        assert!(info.last_heartbeat_age().is_some());
    }

    #[test]
    fn test_replica_info_record_metrics() {
        let mut info = ReplicaInfo::new(1);

        info.record_bytes_sent(1024);
        assert_eq!(info.bytes_sent, 1024);

        info.record_bytes_sent(2048);
        assert_eq!(info.bytes_sent, 3072);

        info.record_message_sent();
        assert_eq!(info.messages_sent, 1);

        info.record_message_sent();
        assert_eq!(info.messages_sent, 2);

        info.record_error();
        assert_eq!(info.error_count, 1);

        info.record_error();
        assert_eq!(info.error_count, 2);
    }

    #[test]
    fn test_replica_info_heartbeat_timeout() {
        let mut info = ReplicaInfo::new(1);

        // No heartbeat means timeout
        assert!(info.heartbeat_timeout(5));

        // Recent heartbeat means no timeout
        info.record_heartbeat();
        assert!(!info.heartbeat_timeout(5));

        // Old heartbeat means timeout
        // Note: This test would need to manipulate time, so we just check the logic
        assert!(!info.heartbeat_timeout(100)); // 100 second timeout, should be fine
    }

    #[test]
    fn test_replica_info_connected_duration() {
        let mut info = ReplicaInfo::new(1);

        assert!(info.connected_duration().is_none());

        info.mark_connected();
        assert!(info.connected_duration().is_some());

        let duration = info.connected_duration().unwrap();
        assert!(duration.as_secs() < 1); // Should be very recent
    }

    #[test]
    fn test_replica_info_default() {
        let info = ReplicaInfo::default();
        assert_eq!(info.replica_id, 0);
    }
}
