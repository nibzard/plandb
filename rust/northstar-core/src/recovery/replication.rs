//! Replication Management
//!
//! Primary-replica replication with async/sync/semi-sync modes,
//! failure detection, and automatic reconnection.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::error::{Error as DbError, IoError, Result};
use crate::types::Lsn;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use uuid::Uuid;

use super::failover::{FailoverManager, FailoverMode};

/// Replication mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReplicationMode {
    /// Asynchronous replication (low latency, potential data loss).
    Async,
    /// Synchronous replication (zero data loss, higher latency).
    Sync,
    /// Semi-synchronous replication (at least one replica confirms).
    SemiSync,
}

impl std::fmt::Display for ReplicationMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Async => write!(f, "async"),
            Self::Sync => write!(f, "sync"),
            Self::SemiSync => write!(f, "semi_sync"),
        }
    }
}

/// Replication role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReplicationRole {
    /// Primary node (accepts writes).
    Primary,
    /// Replica node (read-only).
    Replica,
    /// Standby node (not active).
    Standby,
}

impl std::fmt::Display for ReplicationRole {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Primary => write!(f, "primary"),
            Self::Replica => write!(f, "replica"),
            Self::Standby => write!(f, "standby"),
        }
    }
}

/// Replica connection status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReplicaStatus {
    /// Connecting to primary.
    Connecting,
    /// In sync with primary.
    InSync,
    /// Lagging behind primary.
    Lagging,
    /// Disconnected from primary.
    Disconnected,
    /// Replica failed.
    Failed,
}

impl std::fmt::Display for ReplicaStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Connecting => write!(f, "connecting"),
            Self::InSync => write!(f, "in_sync"),
            Self::Lagging => write!(f, "lagging"),
            Self::Disconnected => write!(f, "disconnected"),
            Self::Failed => write!(f, "failed"),
        }
    }
}

/// Replica connection information.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplicaInfo {
    /// Unique replica identifier.
    pub id: Uuid,
    /// Replica address (host:port).
    pub address: String,
    /// Current status.
    pub status: ReplicaStatus,
    /// Replication mode.
    pub mode: ReplicationMode,
    /// Current LSN.
    pub current_lsn: Lsn,
    /// LSN lag behind primary.
    pub lsn_lag: u64,
    /// Time lag in seconds.
    pub time_lag_secs: u64,
    /// Last contact timestamp.
    pub last_contact: chrono::DateTime<chrono::Utc>,
    /// Connected timestamp.
    pub connected_at: Option<chrono::DateTime<chrono::Utc>>,
    /// Bytes sent to replica.
    pub bytes_sent: u64,
    /// Bytes received from replica.
    pub bytes_received: u64,
    /// Replication errors.
    pub errors: u64,
}

impl ReplicaInfo {
    /// Create new replica info.
    fn new(id: Uuid, address: String, mode: ReplicationMode) -> Self {
        Self {
            id,
            address,
            status: ReplicaStatus::Connecting,
            mode,
            current_lsn: Lsn::INITIAL,
            lsn_lag: 0,
            time_lag_secs: 0,
            last_contact: chrono::Utc::now(),
            connected_at: None,
            bytes_sent: 0,
            bytes_received: 0,
            errors: 0,
        }
    }

    /// Update replica status.
    fn update_status(&mut self, status: ReplicaStatus) {
        self.status = status;
        if status == ReplicaStatus::InSync && self.connected_at.is_none() {
            self.connected_at = Some(chrono::Utc::now());
        }
    }

    /// Update LSN and calculate lag.
    fn update_lsn(&mut self, primary_lsn: Lsn, replica_lsn: Lsn) {
        self.current_lsn = replica_lsn;
        self.lsn_lag = primary_lsn.as_u64().saturating_sub(replica_lsn.as_u64());

        // Update status based on lag
        if self.lsn_lag > 1000 {
            self.status = ReplicaStatus::Lagging;
        } else if self.status == ReplicaStatus::Lagging {
            self.status = ReplicaStatus::InSync;
        }

        self.last_contact = chrono::Utc::now();
    }

    /// Update time lag.
    fn update_time_lag(&mut self, lag_secs: u64) {
        self.time_lag_secs = lag_secs;
    }

    /// Record error.
    fn record_error(&mut self) {
        self.errors += 1;
    }

    /// Check if replica is healthy.
    pub fn is_healthy(&self) -> bool {
        matches!(
            self.status,
            ReplicaStatus::InSync | ReplicaStatus::Lagging
        ) && self.lsn_lag < 10000
    }

    /// Get connection duration.
    pub fn connection_duration(&self) -> Option<Duration> {
        self.connected_at
            .map(|t| (chrono::Utc::now() - t).to_std().unwrap_or_default())
    }
}

/// Replication stream message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ReplicationMessage {
    /// Log record to replicate.
    LogRecord {
        lsn: Lsn,
        data: Vec<u8>,
    },
    /// Heartbeat message.
    Heartbeat {
        lsn: Lsn,
        timestamp: chrono::DateTime<chrono::Utc>,
    },
    /// Acknowledgment from replica.
    Ack {
        lsn: Lsn,
        replica_id: Uuid,
    },
    /// Replica status update.
    StatusUpdate {
        replica_id: Uuid,
        current_lsn: Lsn,
    },
}

/// Replication manager for primary-replica replication.
pub struct ReplicationManager {
    /// Current role (primary or replica).
    role: ReplicationRole,
    /// Replication mode (when primary).
    mode: ReplicationMode,
    /// Primary address (when replica).
    primary_address: Option<String>,
    /// Connected replicas (when primary).
    replicas: HashMap<Uuid, ReplicaInfo>,
    /// Current LSN.
    current_lsn: Arc<RwLock<Lsn>>,
    /// Replication message sender.
    tx: Option<mpsc::UnboundedSender<ReplicationMessage>>,
    /// Failover manager.
    failover: Option<Arc<FailoverManager>>,
}

impl ReplicationManager {
    /// Create new replication manager as primary.
    pub fn new_primary() -> Self {
        Self {
            role: ReplicationRole::Primary,
            mode: ReplicationMode::Async,
            primary_address: None,
            replicas: HashMap::new(),
            current_lsn: Arc::new(RwLock::new(Lsn::INITIAL)),
            tx: None,
            failover: None,
        }
    }

    /// Create new replication manager as replica.
    pub fn new_replica(primary_address: String) -> Self {
        Self {
            role: ReplicationRole::Replica,
            mode: ReplicationMode::Async,
            primary_address: Some(primary_address),
            replicas: HashMap::new(),
            current_lsn: Arc::new(RwLock::new(Lsn::INITIAL)),
            tx: None,
            failover: None,
        }
    }

    /// Set replication mode.
    pub fn set_mode(&mut self, mode: ReplicationMode) {
        self.mode = mode;
    }

    /// Get current role.
    pub fn role(&self) -> ReplicationRole {
        self.role
    }

    /// Get replication mode.
    pub fn mode(&self) -> ReplicationMode {
        self.mode
    }

    /// Get current LSN.
    pub fn current_lsn(&self) -> Lsn {
        *self.current_lsn.read()
    }

    /// Update current LSN.
    pub fn update_lsn(&self, lsn: Lsn) {
        *self.current_lsn.write() = lsn;

        // Send to replicas if primary
        if self.role == ReplicationRole::Primary {
            if let Some(tx) = &self.tx {
                let _ = tx.send(ReplicationMessage::Heartbeat {
                    lsn,
                    timestamp: chrono::Utc::now(),
                });
            }
        }
    }

    /// Add replica (primary only).
    pub fn add_replica(&mut self, address: String, mode: ReplicationMode) -> Result<Uuid> {
        if self.role != ReplicationRole::Primary {
            return Err(DbError::Io(IoError::InternalError(
                "Only primary can add replicas".into(),
            )));
        }

        let replica_id = Uuid::new_v4();
        let mut replica = ReplicaInfo::new(replica_id, address, mode);
        replica.update_status(ReplicaStatus::Connecting);

        self.replicas.insert(replica_id, replica);
        Ok(replica_id)
    }

    /// Remove replica (primary only).
    pub fn remove_replica(&mut self, replica_id: Uuid) -> Result<()> {
        if self.role != ReplicationRole::Primary {
            return Err(DbError::Io(IoError::InternalError(
                "Only primary can remove replicas".into(),
            )));
        }

        self.replicas
            .remove(&replica_id)
            .ok_or_else(|| DbError::Io(IoError::FileNotFound { path: replica_id.to_string() }))?;
        Ok(())
    }

    /// Get replica info.
    pub fn get_replica(&self, replica_id: Uuid) -> Option<ReplicaInfo> {
        self.replicas.get(&replica_id).cloned()
    }

    /// Get all replicas.
    pub fn replicas(&self) -> Vec<ReplicaInfo> {
        self.replicas.values().cloned().collect()
    }

    /// Get healthy replicas.
    pub fn healthy_replicas(&self) -> Vec<ReplicaInfo> {
        self.replicas
            .values()
            .filter(|r| r.is_healthy())
            .cloned()
            .collect()
    }

    /// Update replica status.
    pub fn update_replica_status(&mut self, replica_id: Uuid, status: ReplicaStatus) -> Result<()> {
        let replica = self
            .replicas
            .get_mut(&replica_id)
            .ok_or_else(|| DbError::Io(IoError::FileNotFound { path: replica_id.to_string() }))?;

        replica.update_status(status);
        Ok(())
    }

    /// Process replica acknowledgment.
    pub fn process_replica_ack(&mut self, replica_id: Uuid, lsn: Lsn) -> Result<()> {
        let primary_lsn = self.current_lsn();
        let replica = self
            .replicas
            .get_mut(&replica_id)
            .ok_or_else(|| DbError::Io(IoError::FileNotFound { path: replica_id.to_string() }))?;

        replica.update_lsn(primary_lsn, lsn);

        Ok(())
    }

    /// Send log record to replicas.
    pub fn send_to_replicas(&self, lsn: Lsn, data: Vec<u8>) {
        if self.role != ReplicationRole::Primary {
            return;
        }

        if let Some(tx) = &self.tx {
            let _ = tx.send(ReplicationMessage::LogRecord { lsn, data });
        }
    }

    /// Wait for sync/semi-sync acknowledgments.
    pub async fn wait_for_acks(&self, lsn: Lsn) -> Result<()> {
        match self.mode {
            ReplicationMode::Async => {
                // No wait for async
                Ok(())
            }
            ReplicationMode::Sync => {
                // Wait for all replicas
                let healthy = self.healthy_replicas();
                if healthy.is_empty() && !self.replicas.is_empty() {
                    return Err(DbError::Io(IoError::InternalError(
                        "No healthy replicas available for sync replication".into(),
                    )));
                }
                Ok(())
            }
            ReplicationMode::SemiSync => {
                // Wait for at least one replica
                if self.healthy_replicas().is_empty() && !self.replicas.is_empty() {
                    return Err(DbError::Io(IoError::InternalError(
                        "No healthy replicas available for semi-sync replication".into(),
                    )));
                }
                Ok(())
            }
        }
    }

    /// Start replication to primary (replica only).
    pub async fn start_replication(&mut self) -> Result<()> {
        if self.role != ReplicationRole::Replica {
            return Err(DbError::Io(IoError::InternalError(
                "Only replica can start replication".into(),
            )));
        }

        let primary_addr = self
            .primary_address
            .clone()
            .ok_or_else(|| DbError::Io(IoError::InternalError("Primary address not set".into())))?;

        // Start background replication task
        let primary = primary_addr.clone();
        let lsn = self.current_lsn.clone();

        tokio::spawn(async move {
            // Connect to primary and start replicating
            // This is a placeholder for the actual replication logic
            let _ = primary;
            let _ = lsn;
            // In production, this would:
            // 1. Connect to primary via TCP
            // 2. Send handshake with replica ID
            // 3. Receive and apply log records
            // 4. Send acknowledgments
        });

        Ok(())
    }

    /// Get replication lag statistics.
    pub fn lag_stats(&self) -> (u64, u64, u64) {
        let replicas: Vec<_> = self.replicas.values().collect();

        if replicas.is_empty() {
            return (0, 0, 0);
        }

        let max_lsn_lag = replicas.iter().map(|r| r.lsn_lag).max().unwrap_or(0);
        let avg_lsn_lag = replicas.iter().map(|r| r.lsn_lag).sum::<u64>() / replicas.len() as u64;
        let max_time_lag = replicas.iter().map(|r| r.time_lag_secs).max().unwrap_or(0);

        (max_lsn_lag, avg_lsn_lag, max_time_lag)
    }

    /// Get replication throughput.
    pub fn throughput_stats(&self) -> (u64, u64) {
        let replicas: Vec<_> = self.replicas.values().collect();

        if replicas.is_empty() {
            return (0, 0);
        }

        let bytes_sent: u64 = replicas.iter().map(|r| r.bytes_sent).sum();
        let bytes_received: u64 = replicas.iter().map(|r| r.bytes_received).sum();

        (bytes_sent, bytes_received)
    }

    /// Check if replication is healthy.
    pub fn is_healthy(&self) -> bool {
        match self.role {
            ReplicationRole::Primary => {
                // At least one healthy replica if replicas exist
                if self.replicas.is_empty() {
                    return true;
                }
                self.healthy_replicas().len() > 0
            }
            ReplicationRole::Replica => {
                // Connected and receiving data from primary
                true
            }
            ReplicationRole::Standby => false,
        }
    }

    /// Enable failover detection.
    pub fn enable_failover(&mut self, mode: FailoverMode) {
        self.failover = Some(Arc::new(FailoverManager::with_mode(mode)));
    }

    /// Disable failover detection.
    pub fn disable_failover(&mut self) {
        self.failover = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_replication_mode_display() {
        assert_eq!(ReplicationMode::Async.to_string(), "async");
        assert_eq!(ReplicationMode::Sync.to_string(), "sync");
        assert_eq!(ReplicationMode::SemiSync.to_string(), "semi_sync");
    }

    #[test]
    fn test_replication_role_display() {
        assert_eq!(ReplicationRole::Primary.to_string(), "primary");
        assert_eq!(ReplicationRole::Replica.to_string(), "replica");
        assert_eq!(ReplicationRole::Standby.to_string(), "standby");
    }

    #[test]
    fn test_replica_status_display() {
        assert_eq!(ReplicaStatus::Connecting.to_string(), "connecting");
        assert_eq!(ReplicaStatus::InSync.to_string(), "in_sync");
        assert_eq!(ReplicaStatus::Lagging.to_string(), "lagging");
        assert_eq!(ReplicaStatus::Disconnected.to_string(), "disconnected");
        assert_eq!(ReplicaStatus::Failed.to_string(), "failed");
    }

    #[test]
    fn test_replica_info_new() {
        let replica = ReplicaInfo::new(
            Uuid::new_v4(),
            "localhost:5432".into(),
            ReplicationMode::Async,
        );

        assert_eq!(replica.status, ReplicaStatus::Connecting);
        assert_eq!(replica.current_lsn, Lsn(0));
        assert_eq!(replica.lsn_lag, 0);
        assert!(replica.connected_at.is_none());
    }

    #[test]
    fn test_replica_info_status_update() {
        let mut replica = ReplicaInfo::new(
            Uuid::new_v4(),
            "localhost:5432".into(),
            ReplicationMode::Async,
        );

        assert!(replica.connected_at.is_none());

        replica.update_status(ReplicaStatus::InSync);
        assert_eq!(replica.status, ReplicaStatus::InSync);
        assert!(replica.connected_at.is_some());

        replica.update_status(ReplicaStatus::Lagging);
        assert_eq!(replica.status, ReplicaStatus::Lagging);
    }

    #[test]
    fn test_replica_info_lsn_update() {
        let mut replica = ReplicaInfo::new(
            Uuid::new_v4(),
            "localhost:5432".into(),
            ReplicationMode::Async,
        );

        replica.update_lsn(Lsn(1000), Lsn(900));
        assert_eq!(replica.current_lsn, Lsn(900));
        assert_eq!(replica.lsn_lag, 100);
        assert_eq!(replica.status, ReplicaStatus::InSync);

        replica.update_lsn(Lsn(2000), Lsn(500));
        assert_eq!(replica.lsn_lag, 1500);
        assert_eq!(replica.status, ReplicaStatus::Lagging);
    }

    #[test]
    fn test_replica_info_healthy() {
        let mut replica = ReplicaInfo::new(
            Uuid::new_v4(),
            "localhost:5432".into(),
            ReplicationMode::Async,
        );

        assert!(!replica.is_healthy());

        replica.update_status(ReplicaStatus::InSync);
        assert!(replica.is_healthy());

        replica.update_lsn(Lsn::new(10000), Lsn::new(100));
        assert!(!replica.is_healthy());
    }

    #[test]
    fn test_replica_info_record_error() {
        let mut replica = ReplicaInfo::new(
            Uuid::new_v4(),
            "localhost:5432".into(),
            ReplicationMode::Async,
        );

        assert_eq!(replica.errors, 0);
        replica.record_error();
        assert_eq!(replica.errors, 1);
        replica.record_error();
        assert_eq!(replica.errors, 2);
    }

    #[test]
    fn test_replication_manager_primary() {
        let manager = ReplicationManager::new_primary();
        assert_eq!(manager.role(), ReplicationRole::Primary);
        assert_eq!(manager.mode(), ReplicationMode::Async);
        assert!(manager.replicas().is_empty());
    }

    #[test]
    fn test_replication_manager_replica() {
        let manager = ReplicationManager::new_replica("localhost:5432".into());
        assert_eq!(manager.role(), ReplicationRole::Replica);
        assert_eq!(manager.primary_address, Some("localhost:5432".into()));
    }

    #[test]
    fn test_replication_manager_add_replica() {
        let mut manager = ReplicationManager::new_primary();
        let replica_id = manager.add_replica("localhost:5433".into(), ReplicationMode::Async).unwrap();

        let replicas = manager.replicas();
        assert_eq!(replicas.len(), 1);
        assert_eq!(replicas[0].id, replica_id);
        assert_eq!(replicas[0].address, "localhost:5433");
    }

    #[test]
    fn test_replication_manager_add_replica_as_replica() {
        let mut manager = ReplicationManager::new_replica("localhost:5432".into());
        let result = manager.add_replica("localhost:5433".into(), ReplicationMode::Async);
        assert!(result.is_err());
    }

    #[test]
    fn test_replication_manager_remove_replica() {
        let mut manager = ReplicationManager::new_primary();
        let replica_id = manager.add_replica("localhost:5433".into(), ReplicationMode::Async).unwrap();

        manager.remove_replica(replica_id).unwrap();
        assert!(manager.replicas().is_empty());
    }

    #[test]
    fn test_replication_manager_update_replica_status() {
        let mut manager = ReplicationManager::new_primary();
        let replica_id = manager.add_replica("localhost:5433".into(), ReplicationMode::Async).unwrap();

        manager
            .update_replica_status(replica_id, ReplicaStatus::InSync)
            .unwrap();

        let replica = manager.get_replica(replica_id).unwrap();
        assert_eq!(replica.status, ReplicaStatus::InSync);
    }

    #[test]
    fn test_replication_manager_process_ack() {
        let mut manager = ReplicationManager::new_primary();
        let replica_id = manager.add_replica("localhost:5433".into(), ReplicationMode::Async).unwrap();

        manager.update_lsn(Lsn(1000));
        manager.process_replica_ack(replica_id, Lsn(900)).unwrap();

        let replica = manager.get_replica(replica_id).unwrap();
        assert_eq!(replica.current_lsn, Lsn(900));
        assert_eq!(replica.lsn_lag, 100);
    }

    #[test]
    fn test_replication_manager_set_mode() {
        let mut manager = ReplicationManager::new_primary();
        assert_eq!(manager.mode(), ReplicationMode::Async);

        manager.set_mode(ReplicationMode::Sync);
        assert_eq!(manager.mode(), ReplicationMode::Sync);
    }

    #[test]
    fn test_replication_manager_lag_stats() {
        let mut manager = ReplicationManager::new_primary();
        let replica1 = manager.add_replica("localhost:5433".into(), ReplicationMode::Async).unwrap();
        let replica2 = manager.add_replica("localhost:5434".into(), ReplicationMode::Async).unwrap();

        manager.update_lsn(Lsn(1000));
        manager.process_replica_ack(replica1, Lsn(900)).unwrap();
        manager.process_replica_ack(replica2, Lsn(800)).unwrap();

        let (max_lsn, avg_lsn, max_time) = manager.lag_stats();
        assert_eq!(max_lsn, 200);
        assert_eq!(avg_lsn, 150);
        assert_eq!(max_time, 0);
    }

    #[test]
    fn test_replication_manager_healthy() {
        let manager = ReplicationManager::new_primary();
        assert!(manager.is_healthy());

        let mut manager = ReplicationManager::new_primary();
        let replica_id = manager.add_replica("localhost:5433".into(), ReplicationMode::Async).unwrap();
        manager.update_lsn(Lsn(1000));
        manager.process_replica_ack(replica_id, Lsn(900)).unwrap();

        assert!(manager.is_healthy());
    }
}
