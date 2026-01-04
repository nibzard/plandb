//! Automatic Failover Management
//!
//! Heartbeat-based failure detection, automatic election,
//! and replica promotion for high availability.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::error::{Error as DbError, IoError, Result};
use crate::types::Lsn;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use uuid::Uuid;

use super::replication::{ReplicaInfo, ReplicaStatus, ReplicationManager, ReplicationRole};

/// Failover mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FailoverMode {
    /// Automatic failover on primary failure.
    Automatic,
    /// Manual failover triggered by operator.
    Manual,
    /// Planned failover with minimal downtime.
    Planned,
}

impl std::fmt::Display for FailoverMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Automatic => write!(f, "automatic"),
            Self::Manual => write!(f, "manual"),
            Self::Planned => write!(f, "planned"),
        }
    }
}

/// Failover status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FailoverStatus {
    /// Monitoring for primary failure.
    Monitoring,
    /// Detecting potential failure.
    DetectingFailure,
    /// Confirming primary is down.
    ConfirmingFailure,
    /// Electing new primary.
    ElectingNewPrimary,
    /// Promoting replica to primary.
    PromotingReplica,
    /// Updating client routing.
    UpdatingRouting,
    /// Failover completed successfully.
    Completed,
    /// Failover failed.
    Failed,
}

impl std::fmt::Display for FailoverStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Monitoring => write!(f, "monitoring"),
            Self::DetectingFailure => write!(f, "detecting_failure"),
            Self::ConfirmingFailure => write!(f, "confirming_failure"),
            Self::ElectingNewPrimary => write!(f, "electing_new_primary"),
            Self::PromotingReplica => write!(f, "promoting_replica"),
            Self::UpdatingRouting => write!(f, "updating_routing"),
            Self::Completed => write!(f, "completed"),
            Self::Failed => write!(f, "failed"),
        }
    }
}

/// Failover event metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Failover {
    /// Unique failover identifier.
    pub id: Uuid,
    /// Failover mode.
    pub mode: FailoverMode,
    /// Current status.
    pub status: FailoverStatus,
    /// Old primary ID.
    pub old_primary_id: Option<Uuid>,
    /// New primary ID.
    pub new_primary_id: Option<Uuid>,
    /// Failover triggered timestamp.
    pub triggered_at: chrono::DateTime<chrono::Utc>,
    /// Failover completed timestamp.
    pub completed_at: Option<chrono::DateTime<chrono::Utc>>,
    /// Total downtime in seconds.
    pub downtime_secs: u64,
    /// Estimated data loss in bytes (LSN difference).
    pub data_loss_bytes: u64,
    /// Trigger reason.
    pub reason: String,
    /// Error message if failover failed.
    pub error: Option<String>,
}

impl Failover {
    /// Create new failover event.
    fn new(mode: FailoverMode, reason: String) -> Self {
        Self {
            id: Uuid::new_v4(),
            mode,
            status: FailoverStatus::Monitoring,
            old_primary_id: None,
            new_primary_id: None,
            triggered_at: chrono::Utc::now(),
            completed_at: None,
            downtime_secs: 0,
            data_loss_bytes: 0,
            reason,
            error: None,
        }
    }

    /// Update failover status.
    fn update_status(&mut self, status: FailoverStatus) {
        self.status = status;
        if status == FailoverStatus::Completed {
            self.completed_at = Some(chrono::Utc::now());
            if let Some(completed) = self.completed_at {
                self.downtime_secs = (completed - self.triggered_at).num_seconds().max(0) as u64;
            }
        }
    }

    /// Set old and new primary IDs.
    fn set_primaries(&mut self, old_id: Uuid, new_id: Uuid) {
        self.old_primary_id = Some(old_id);
        self.new_primary_id = Some(new_id);
    }

    /// Mark failover as failed.
    fn mark_failed(&mut self, error: String) {
        self.status = FailoverStatus::Failed;
        self.error = Some(error);
        self.completed_at = Some(chrono::Utc::now());
    }

    /// Get failover duration.
    pub fn duration(&self) -> Option<Duration> {
        self.completed_at
            .map(|end| (end - self.triggered_at).to_std().unwrap_or_default())
    }
}

/// Heartbeat message for failure detection.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Heartbeat {
    /// Node ID sending heartbeat.
    pub node_id: Uuid,
    /// Current LSN.
    pub lsn: Lsn,
    /// Timestamp.
    pub timestamp: chrono::DateTime<chrono::Utc>,
    /// Node role.
    pub role: ReplicationRole,
}

impl Heartbeat {
    /// Create new heartbeat.
    fn new(node_id: Uuid, lsn: Lsn, role: ReplicationRole) -> Self {
        Self {
            node_id,
            lsn,
            timestamp: chrono::Utc::now(),
            role,
        }
    }

    /// Check if heartbeat is stale.
    fn is_stale(&self, timeout: Duration) -> bool {
        let age = chrono::Utc::now()
            .signed_duration_since(self.timestamp)
            .to_std()
            .unwrap_or(Duration::ZERO);
        age > timeout
    }
}

/// Failover manager for automatic failover detection and promotion.
pub struct FailoverManager {
    /// Failover mode.
    mode: FailoverMode,
    /// Heartbeat interval.
    heartbeat_interval: Duration,
    /// Number of missed heartbeats before triggering failover.
    missed_threshold: usize,
    /// Current failover event.
    current_failover: Option<Failover>,
    /// Failover history.
    failover_history: Vec<Failover>,
    /// Heartbeat tracker (node_id -> last heartbeat).
    heartbeats: HashMap<Uuid, Heartbeat>,
    /// Replication manager for promotion.
    replication: Option<Arc<ReplicationManager>>,
    /// Current node ID.
    node_id: Uuid,
    /// Is current node primary.
    is_primary: Arc<RwLock<bool>>,
}

impl FailoverManager {
    /// Create new failover manager with default settings.
    pub fn new() -> Self {
        Self {
            mode: FailoverMode::Automatic,
            heartbeat_interval: Duration::from_secs(5),
            missed_threshold: 6, // 30 seconds (6 * 5s)
            current_failover: None,
            failover_history: Vec::new(),
            heartbeats: HashMap::new(),
            replication: None,
            node_id: Uuid::new_v4(),
            is_primary: Arc::new(RwLock::new(false)),
        }
    }

    /// Create failover manager with custom configuration.
    pub fn with_config(heartbeat_interval: Duration, missed_threshold: usize) -> Self {
        Self {
            mode: FailoverMode::Automatic,
            heartbeat_interval,
            missed_threshold,
            current_failover: None,
            failover_history: Vec::new(),
            heartbeats: HashMap::new(),
            replication: None,
            node_id: Uuid::new_v4(),
            is_primary: Arc::new(RwLock::new(false)),
        }
    }

    /// Create failover manager with specific mode.
    pub fn with_mode(mode: FailoverMode) -> Self {
        Self {
            mode,
            ..Self::new()
        }
    }

    /// Set replication manager.
    pub fn set_replication(&mut self, replication: Arc<ReplicationManager>) {
        self.replication = Some(replication);
    }

    /// Set node ID.
    pub fn set_node_id(&mut self, node_id: Uuid) {
        self.node_id = node_id;
    }

    /// Set whether current node is primary.
    pub fn set_primary(&self, is_primary: bool) {
        *self.is_primary.write() = is_primary;
    }

    /// Get current failover mode.
    pub fn mode(&self) -> FailoverMode {
        self.mode
    }

    /// Get current failover status.
    pub fn current_failover(&self) -> Option<Failover> {
        self.current_failover.clone()
    }

    /// Get failover history.
    pub fn failover_history(&self) -> Vec<Failover> {
        self.failover_history.clone()
    }

    /// Process heartbeat from node.
    pub fn process_heartbeat(&mut self, heartbeat: Heartbeat) -> Result<()> {
        self.heartbeats.insert(heartbeat.node_id, heartbeat);
        Ok(())
    }

    /// Check for primary failure.
    pub fn detect_primary_failure(&mut self) -> bool {
        if *self.is_primary.read() {
            return false;
        }

        let timeout = self.heartbeat_interval * self.missed_threshold as u32;

        if let Some(replication) = &self.replication {
            // Check if we have any healthy replicas
            let replicas = replication.replicas();
            for replica in replicas {
                if let Some(last_heartbeat) = self.heartbeats.get(&replica.id) {
                    if last_heartbeat.is_stale(timeout) {
                        // Primary might be down
                        return self.confirm_primary_failure();
                    }
                }
            }
        }

        false
    }

    /// Confirm primary failure.
    fn confirm_primary_failure(&mut self) -> bool {
        // Require multiple missed heartbeats to avoid false positives
        let timeout = self.heartbeat_interval * (self.missed_threshold as u32 * 2);

        for heartbeat in self.heartbeats.values() {
            if heartbeat.role == ReplicationRole::Primary && !heartbeat.is_stale(timeout) {
                return false;
            }
        }

        true
    }

    /// Initiate automatic failover.
    pub fn initiate_failover(&mut self) -> Result<Uuid> {
        let mut failover = Failover::new(self.mode, "Primary failure detected".into());
        failover.update_status(FailoverStatus::DetectingFailure);
        let failover_id = failover.id;

        self.current_failover = Some(failover.clone());

        // Run failover process
        let result = self.perform_failover(&mut failover);

        match result {
            Ok(_) => {
                failover.update_status(FailoverStatus::Completed);
            }
            Err(e) => {
                failover.mark_failed(e.to_string());
            }
        }

        self.failover_history.push(failover.clone());
        self.current_failover = None;

        Ok(failover_id)
    }

    /// Perform failover election and promotion.
    fn perform_failover(&self, failover: &mut Failover) -> Result<()> {
        failover.update_status(FailoverStatus::ElectingNewPrimary);

        // Select most up-to-date replica
        let new_primary = self.elect_new_primary()?;

        failover.update_status(FailoverStatus::PromotingReplica);

        // Promote replica to primary
        self.promote_replica(&new_primary)?;

        failover.update_status(FailoverStatus::UpdatingRouting);

        // Update routing (DNS, service discovery)
        // In production, this would update DNS records or service registry
        failover.set_primaries(self.node_id, new_primary.id);

        Ok(())
    }

    /// Elect new primary from replicas.
    fn elect_new_primary(&self) -> Result<ReplicaInfo> {
        let replication = self
            .replication
            .as_ref()
            .ok_or_else(|| DbError::Io(IoError::InternalError("Replication manager not set".into())))?;

        let replicas = replication.healthy_replicas();
        if replicas.is_empty() {
            return Err(DbError::Io(IoError::InternalError("No healthy replicas available".into())));
        }

        // Select replica with highest LSN (least data loss)
        let elected = replicas
            .into_iter()
            .max_by_key(|r| r.current_lsn)
            .ok_or_else(|| DbError::Io(IoError::InternalError("Failed to elect new primary".into())))?;

        Ok(elected)
    }

    /// Promote replica to primary.
    fn promote_replica(&self, replica: &ReplicaInfo) -> Result<()> {
        // Update local state
        *self.is_primary.write() = true;

        // In production, this would:
        // 1. Stop replication from old primary
        // 2. Enable writes on new primary
        // 3. Notify other replicas to follow new primary
        // 4. Update configuration metadata

        Ok(())
    }

    /// Trigger manual failover.
    pub fn trigger_manual_failover(&mut self, reason: String) -> Result<Uuid> {
        let mut failover = Failover::new(FailoverMode::Manual, reason);
        failover.update_status(FailoverStatus::ElectingNewPrimary);
        let failover_id = failover.id;

        self.current_failover = Some(failover.clone());

        let result = self.perform_failover(&mut failover);

        match result {
            Ok(_) => {
                failover.update_status(FailoverStatus::Completed);
            }
            Err(e) => {
                failover.mark_failed(e.to_string());
            }
        }

        self.failover_history.push(failover.clone());
        self.current_failover = None;

        Ok(failover_id)
    }

    /// Start heartbeat monitoring task.
    pub async fn start_monitoring(&self) {
        let interval = self.heartbeat_interval;
        let is_primary = self.is_primary.clone();
        let node_id = self.node_id;
        let replication = self.replication.clone();

        tokio::spawn(async move {
            let mut timer = tokio::time::interval(interval);
            loop {
                timer.tick().await;

                // Send heartbeat if primary
                if *is_primary.read() {
                    if let Some(repl) = &replication {
                        let lsn = repl.current_lsn();
                        // Send heartbeat to all replicas
                        // In production, this would send over network
                    }
                }
            }
        });
    }

    /// Get failover statistics.
    pub fn failover_stats(&self) -> (usize, u64, u64) {
        let total_failovers = self.failover_history.len();
        let total_downtime: u64 = self.failover_history.iter().map(|f| f.downtime_secs).sum();
        let total_data_loss: u64 = self.failover_history.iter().map(|f| f.data_loss_bytes).sum();

        (total_failovers, total_downtime, total_data_loss)
    }

    /// Clear old failover history.
    pub fn clear_history(&mut self, keep_last_n: usize) {
        if self.failover_history.len() > keep_last_n {
            let start = self.failover_history.len() - keep_last_n;
            self.failover_history = self.failover_history.split_off(start);
        }
    }
}

impl Default for FailoverManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_failover_mode_display() {
        assert_eq!(FailoverMode::Automatic.to_string(), "automatic");
        assert_eq!(FailoverMode::Manual.to_string(), "manual");
        assert_eq!(FailoverMode::Planned.to_string(), "planned");
    }

    #[test]
    fn test_failover_status_display() {
        assert_eq!(FailoverStatus::Monitoring.to_string(), "monitoring");
        assert_eq!(FailoverStatus::DetectingFailure.to_string(), "detecting_failure");
        assert_eq!(FailoverStatus::Completed.to_string(), "completed");
    }

    #[test]
    fn test_heartbeat_new() {
        let node_id = Uuid::new_v4();
        let heartbeat = Heartbeat::new(node_id, Lsn(100), ReplicationRole::Primary);

        assert_eq!(heartbeat.node_id, node_id);
        assert_eq!(heartbeat.lsn, Lsn(100));
        assert_eq!(heartbeat.role, ReplicationRole::Primary);
    }

    #[test]
    fn test_heartbeat_is_stale() {
        let node_id = Uuid::new_v4();
        let mut heartbeat = Heartbeat::new(node_id, Lsn(100), ReplicationRole::Primary);

        // Fresh heartbeat is not stale
        assert!(!heartbeat.is_stale(Duration::from_secs(10)));

        // Old heartbeat is stale
        heartbeat.timestamp = chrono::Utc::now() - chrono::Duration::seconds(20);
        assert!(heartbeat.is_stale(Duration::from_secs(10)));
    }

    #[test]
    fn test_failover_new() {
        let failover = Failover::new(FailoverMode::Automatic, "Test".into());

        assert_eq!(failover.mode, FailoverMode::Automatic);
        assert_eq!(failover.status, FailoverStatus::Monitoring);
        assert_eq!(failover.reason, "Test");
        assert!(failover.old_primary_id.is_none());
        assert!(failover.new_primary_id.is_none());
    }

    #[test]
    fn test_failover_update_status() {
        let mut failover = Failover::new(FailoverMode::Automatic, "Test".into());

        failover.update_status(FailoverStatus::ElectingNewPrimary);
        assert_eq!(failover.status, FailoverStatus::ElectingNewPrimary);

        failover.update_status(FailoverStatus::Completed);
        assert_eq!(failover.status, FailoverStatus::Completed);
        assert!(failover.completed_at.is_some());
    }

    #[test]
    fn test_failover_set_primaries() {
        let mut failover = Failover::new(FailoverMode::Automatic, "Test".into());

        let old_id = Uuid::new_v4();
        let new_id = Uuid::new_v4();

        failover.set_primaries(old_id, new_id);
        assert_eq!(failover.old_primary_id, Some(old_id));
        assert_eq!(failover.new_primary_id, Some(new_id));
    }

    #[test]
    fn test_failover_mark_failed() {
        let mut failover = Failover::new(FailoverMode::Automatic, "Test".into());

        failover.mark_failed("Test error".into());
        assert_eq!(failover.status, FailoverStatus::Failed);
        assert_eq!(failover.error, Some("Test error".into()));
    }

    #[test]
    fn test_failover_duration() {
        let mut failover = Failover::new(FailoverMode::Automatic, "Test".into());

        assert!(failover.duration().is_none());

        failover.update_status(FailoverStatus::Completed);
        assert!(failover.duration().is_some());
    }

    #[test]
    fn test_failover_manager_new() {
        let manager = FailoverManager::new();
        assert_eq!(manager.mode(), FailoverMode::Automatic);
        assert_eq!(manager.heartbeat_interval, Duration::from_secs(5));
        assert_eq!(manager.missed_threshold, 6);
    }

    #[test]
    fn test_failover_manager_with_config() {
        let manager = FailoverManager::with_config(Duration::from_secs(10), 3);
        assert_eq!(manager.heartbeat_interval, Duration::from_secs(10));
        assert_eq!(manager.missed_threshold, 3);
    }

    #[test]
    fn test_failover_manager_with_mode() {
        let manager = FailoverManager::with_mode(FailoverMode::Manual);
        assert_eq!(manager.mode(), FailoverMode::Manual);
    }

    #[test]
    fn test_failover_manager_process_heartbeat() {
        let mut manager = FailoverManager::new();
        let node_id = Uuid::new_v4();
        let heartbeat = Heartbeat::new(node_id, Lsn(100), ReplicationRole::Primary);

        manager.process_heartbeat(heartbeat).unwrap();
        assert!(manager.heartbeats.contains_key(&node_id));
    }

    #[test]
    fn test_failover_manager_set_node_id() {
        let mut manager = FailoverManager::new();
        let node_id = Uuid::new_v4();
        manager.set_node_id(node_id);
        assert_eq!(manager.node_id, node_id);
    }

    #[test]
    fn test_failover_manager_set_primary() {
        let manager = FailoverManager::new();
        assert!(!manager.is_primary.read());

        manager.set_primary(true);
        assert!(manager.is_primary.read());

        manager.set_primary(false);
        assert!(!manager.is_primary.read());
    }

    #[test]
    fn test_failover_manager_failover_stats() {
        let manager = FailoverManager::new();
        let (total, downtime, data_loss) = manager.failover_stats();
        assert_eq!(total, 0);
        assert_eq!(downtime, 0);
        assert_eq!(data_loss, 0);
    }

    #[test]
    fn test_failover_manager_clear_history() {
        let mut manager = FailoverManager::new();

        // Add some failover history
        for _ in 0..10 {
            manager.failover_history.push(Failover::new(
                FailoverMode::Automatic,
                "Test".into(),
            ));
        }

        assert_eq!(manager.failover_history.len(), 10);

        manager.clear_history(5);
        assert_eq!(manager.failover_history.len(), 5);
    }
}
