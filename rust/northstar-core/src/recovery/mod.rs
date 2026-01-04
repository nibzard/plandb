//! Disaster Recovery System
//!
//! Comprehensive disaster recovery infrastructure including backup/restore,
//! point-in-time recovery, replication, and automatic failover for production
//! deployments with RPO <1 min and RTO <30 sec targets.

mod backup;
mod restore;
mod replication;
mod failover;

pub use backup::{
    Backup, BackupConfig, BackupManager, BackupStatus, BackupType, RetentionPolicy,
    ScheduleConfig,
};
pub use restore::{Recovery, RecoveryManager, RecoveryStatus, RecoveryType};
pub use replication::{ReplicaInfo, ReplicaStatus, ReplicationManager, ReplicationMode, ReplicationRole};
pub use failover::{Failover, FailoverManager, FailoverMode, FailoverStatus};

use std::sync::Arc;
use parking_lot::Mutex;

/// Create a new backup manager with default configuration.
pub fn backup_manager() -> Arc<Mutex<BackupManager>> {
    Arc::new(Mutex::new(BackupManager::new(BackupConfig::default())))
}

/// Create a new backup manager with custom configuration.
pub fn backup_manager_with_config(config: BackupConfig) -> Arc<Mutex<BackupManager>> {
    Arc::new(Mutex::new(BackupManager::new(config)))
}

/// Create a new recovery manager.
pub fn recovery_manager() -> Arc<Mutex<RecoveryManager>> {
    Arc::new(Mutex::new(RecoveryManager::new()))
}

/// Create a new replication manager for a primary node.
pub fn replication_primary() -> Arc<ReplicationManager> {
    Arc::new(ReplicationManager::new_primary())
}

/// Create a new replication manager for a replica node.
pub fn replication_replica(primary_addr: String) -> Arc<ReplicationManager> {
    Arc::new(ReplicationManager::new_replica(primary_addr))
}

/// Create a new failover manager with default heartbeat interval.
pub fn failover_manager() -> Arc<FailoverManager> {
    Arc::new(FailoverManager::new())
}

/// Create a new failover manager with custom heartbeat interval.
pub fn failover_manager_with_config(
    heartbeat_interval: std::time::Duration,
    missed_threshold: usize,
) -> Arc<FailoverManager> {
    Arc::new(FailoverManager::with_config(
        heartbeat_interval,
        missed_threshold,
    ))
}
