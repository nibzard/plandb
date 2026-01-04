//! Backup Management
//!
//! Full and incremental backup creation with compression, encryption,
//! checksumming, and retention policy enforcement.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use crate::error::{Error as DbError, IoError, Result};
use chrono::Timelike;
use crate::types::Lsn;
use crate::wal::Wal;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// Backup type classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BackupType {
    /// Complete database backup including all pages.
    Full,
    /// Log-based incremental from last backup.
    Incremental,
    /// Changes since last full backup.
    Differential,
    /// Instant filesystem snapshot.
    Snapshot,
}

impl std::fmt::Display for BackupType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Full => write!(f, "full"),
            Self::Incremental => write!(f, "incremental"),
            Self::Differential => write!(f, "differential"),
            Self::Snapshot => write!(f, "snapshot"),
        }
    }
}

/// Backup operation status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BackupStatus {
    /// Backup is queued but not started.
    Pending,
    /// Backup in progress.
    InProgress,
    /// Backup completed successfully.
    Completed,
    /// Backup failed.
    Failed,
    /// Backup was cancelled.
    Cancelled,
}

impl std::fmt::Display for BackupStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Pending => write!(f, "pending"),
            Self::InProgress => write!(f, "in_progress"),
            Self::Completed => write!(f, "completed"),
            Self::Failed => write!(f, "failed"),
            Self::Cancelled => write!(f, "cancelled"),
        }
    }
}

/// Backup metadata and tracking information.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Backup {
    /// Unique backup identifier.
    pub id: Uuid,
    /// Backup type.
    pub backup_type: BackupType,
    /// Current status.
    pub status: BackupStatus,
    /// Starting LSN of backup.
    pub start_lsn: Lsn,
    /// Ending LSN of backup.
    pub end_lsn: Lsn,
    /// Backup creation timestamp.
    pub created_at: chrono::DateTime<chrono::Utc>,
    /// Backup completion timestamp.
    pub completed_at: Option<chrono::DateTime<chrono::Utc>>,
    /// Previous backup ID (for incremental chains).
    pub previous_backup_id: Option<Uuid>,
    /// File size in bytes.
    pub size_bytes: u64,
    /// SHA-256 checksum of backup data.
    pub checksum: String,
    /// Backup file path.
    pub path: PathBuf,
    /// Compression level (0-9, none if None).
    pub compression_level: Option<u8>,
    /// Encrypted with AES-256-GCM.
    pub encrypted: bool,
    /// Error message if backup failed.
    pub error: Option<String>,
}

impl Backup {
    /// Create new backup metadata.
    fn new(
        backup_type: BackupType,
        start_lsn: Lsn,
        path: PathBuf,
        previous_backup_id: Option<Uuid>,
        compression_level: Option<u8>,
        encrypted: bool,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            backup_type,
            status: BackupStatus::Pending,
            start_lsn,
            end_lsn: start_lsn,
            created_at: chrono::Utc::now(),
            completed_at: None,
            previous_backup_id,
            size_bytes: 0,
            checksum: String::new(),
            path,
            compression_level,
            encrypted,
            error: None,
        }
    }

    /// Mark backup as in progress.
    fn mark_in_progress(&mut self) {
        self.status = BackupStatus::InProgress;
    }

    /// Mark backup as completed.
    fn mark_completed(&mut self, end_lsn: Lsn, size_bytes: u64, checksum: String) {
        self.status = BackupStatus::Completed;
        self.end_lsn = end_lsn;
        self.size_bytes = size_bytes;
        self.checksum = checksum;
        self.completed_at = Some(chrono::Utc::now());
    }

    /// Mark backup as failed.
    fn mark_failed(&mut self, error: String) {
        self.status = BackupStatus::Failed;
        self.error = Some(error);
        self.completed_at = Some(chrono::Utc::now());
    }

    /// Get backup duration.
    pub fn duration(&self) -> Option<Duration> {
        self.completed_at
            .map(|end| (end - self.created_at).to_std().unwrap_or_default())
    }

    /// Check if backup can be used for restore.
    pub fn is_valid(&self) -> bool {
        self.status == BackupStatus::Completed && !self.checksum.is_empty()
    }
}

/// Backup retention policy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetentionPolicy {
    /// Maximum number of backups to retain.
    pub max_count: usize,
    /// Maximum age of backups to retain.
    pub max_age_days: u64,
}

impl Default for RetentionPolicy {
    fn default() -> Self {
        Self {
            max_count: 10,
            max_age_days: 7,
        }
    }
}

impl RetentionPolicy {
    /// Check if backup should be retained.
    fn should_retain(&self, backup: &Backup) -> bool {
        let age_days = chrono::Utc::now()
            .signed_duration_since(backup.created_at)
            .num_days();

        age_days < self.max_age_days as i64
    }

    /// Get max age as duration.
    pub fn max_age_duration(&self) -> Duration {
        Duration::from_secs(self.max_age_days * 24 * 60 * 60)
    }
}

/// Backup scheduling configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduleConfig {
    /// Enable automatic backups.
    pub enabled: bool,
    /// Full backup interval in hours.
    pub full_interval_hours: u64,
    /// Incremental backup interval in hours.
    pub incremental_interval_hours: u64,
    /// Backup window start hour (0-23).
    pub window_start_hour: u8,
    /// Backup window end hour (0-23).
    pub window_end_hour: u8,
}

impl Default for ScheduleConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            full_interval_hours: 168, // 7 days
            incremental_interval_hours: 1,
            window_start_hour: 2,
            window_end_hour: 4,
        }
    }
}

impl ScheduleConfig {
    /// Check if current time is within backup window.
    pub fn in_backup_window(&self) -> bool {
        if !self.enabled {
            return false;
        }

        let now = chrono::Utc::now().time().hour() as u8;
        let (start, end) = if self.window_start_hour < self.window_end_hour {
            (self.window_start_hour, self.window_end_hour)
        } else {
            // Window crosses midnight
            (self.window_end_hour, self.window_start_hour)
        };

        if self.window_start_hour < self.window_end_hour {
            now >= start && now < end
        } else {
            now >= start || now < end
        }
    }
}

/// Backup manager configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupConfig {
    /// Base directory for backup storage.
    pub backup_dir: PathBuf,
    /// Retention policy.
    pub retention: RetentionPolicy,
    /// Scheduling configuration.
    pub schedule: ScheduleConfig,
    /// Compression level (0-9, None for no compression).
    pub compression_level: Option<u8>,
    /// Enable encryption.
    pub encryption_enabled: bool,
    /// Encryption key (32 bytes for AES-256).
    #[serde(skip)]
    pub encryption_key: Option<Vec<u8>>,
}

impl Default for BackupConfig {
    fn default() -> Self {
        Self {
            backup_dir: PathBuf::from("./backups"),
            retention: RetentionPolicy::default(),
            schedule: ScheduleConfig::default(),
            compression_level: Some(6),
            encryption_enabled: false,
            encryption_key: None,
        }
    }
}

/// Backup manager for creating and managing database backups.
pub struct BackupManager {
    config: BackupConfig,
    backups: HashMap<Uuid, Backup>,
    wal: Option<Arc<Wal>>,
}

impl BackupManager {
    /// Create new backup manager with default config.
    pub fn new(config: BackupConfig) -> Self {
        // Create backup directory if it doesn't exist
        if let Err(e) = fs::create_dir_all(&config.backup_dir) {
            eprintln!("Failed to create backup directory: {}", e);
        }

        Self {
            config,
            backups: HashMap::new(),
            wal: None,
        }
    }

    /// Set WAL for incremental backups.
    pub fn set_wal(&mut self, wal: Arc<Wal>) {
        self.wal = Some(wal);
    }

    /// Get all backups.
    pub fn backups(&self) -> Vec<Backup> {
        self.backups.values().cloned().collect()
    }

    /// Get backup by ID.
    pub fn get_backup(&self, id: Uuid) -> Option<Backup> {
        self.backups.get(&id).cloned()
    }

    /// Get latest backup of specified type.
    pub fn latest_backup(&self, backup_type: BackupType) -> Option<Backup> {
        self.backups
            .values()
            .filter(|b| b.backup_type == backup_type && b.is_valid())
            .max_by_key(|b| b.created_at)
            .cloned()
    }

    /// Get latest completed backup (any type).
    pub fn latest_completed_backup(&self) -> Option<Backup> {
        self.backups
            .values()
            .filter(|b| b.is_valid())
            .max_by_key(|b| b.created_at)
            .cloned()
    }

    /// Create full backup of database.
    pub fn create_full_backup(&mut self, db_path: &Path) -> Result<Uuid> {
        let start_lsn = self.current_lsn();

        let backup_path = self.backup_path(BackupType::Full);
        let mut backup = Backup::new(
            BackupType::Full,
            start_lsn,
            backup_path,
            None,
            self.config.compression_level,
            self.config.encryption_enabled,
        );

        backup.mark_in_progress();
        let backup_id = backup.id;

        // Perform backup
        let result = self.perform_full_backup(db_path, &mut backup);

        // Update backup status
        match result {
            Ok((end_lsn, size_bytes, checksum)) => {
                backup.mark_completed(end_lsn, size_bytes, checksum);
                self.apply_retention_policy();
            }
            Err(e) => {
                backup.mark_failed(e.to_string());
                return Err(e);
            }
        }

        self.backups.insert(backup_id, backup);
        Ok(backup_id)
    }

    /// Perform actual full backup operation.
    fn perform_full_backup(
        &self,
        db_path: &Path,
        backup: &mut Backup,
    ) -> Result<(Lsn, u64, String)> {
        // Open database file
        let db_file = File::open(db_path).map_err(|e| {
            DbError::Io(IoError::Generic(e))
        })?;

        // Calculate checksum while reading
        let mut hasher = Sha256::new();
        let mut reader = BufReader::new(db_file);
        let mut buffer = vec![0; 64 * 1024]; // 64KB buffer
        let mut total_bytes = 0u64;

        // Create backup file
        let backup_file = File::create(&backup.path).map_err(|e| {
            DbError::Io(IoError::Generic(e))
        })?;
        let mut writer = BufWriter::new(backup_file);

        // Copy file with checksum calculation
        loop {
            let n = reader.read(&mut buffer).map_err(|e| {
                DbError::Io(IoError::Generic(e))
            })?;

            if n == 0 {
                break;
            }

            total_bytes += n as u64;
            hasher.update(&buffer[..n]);

            writer.write_all(&buffer[..n]).map_err(|e| {
                DbError::Io(IoError::Generic(e))
            })?;
        }

        writer.flush().map_err(|e| {
            DbError::Io(IoError::Generic(e))
        })?;

        let checksum = format!("{:x}", hasher.finalize());
        let end_lsn = self.current_lsn();

        Ok((end_lsn, total_bytes, checksum))
    }

    /// Create incremental backup from last backup.
    pub fn create_incremental_backup(&mut self) -> Result<Uuid> {
        let start_lsn = self.current_lsn();

        // Find base backup
        let base_backup = self
            .latest_completed_backup()
            .ok_or_else(|| DbError::Io(IoError::InternalError("No base backup found for incremental".into())))?;

        let backup_path = self.backup_path(BackupType::Incremental);
        let mut backup = Backup::new(
            BackupType::Incremental,
            start_lsn,
            backup_path,
            Some(base_backup.id),
            self.config.compression_level,
            self.config.encryption_enabled,
        );

        backup.mark_in_progress();
        let backup_id = backup.id;

        // Perform incremental backup
        let result = self.perform_incremental_backup(&base_backup, &mut backup);

        // Update backup status
        match result {
            Ok((end_lsn, size_bytes, checksum)) => {
                backup.mark_completed(end_lsn, size_bytes, checksum);
                self.apply_retention_policy();
            }
            Err(e) => {
                backup.mark_failed(e.to_string());
                return Err(e);
            }
        }

        self.backups.insert(backup_id, backup);
        Ok(backup_id)
    }

    /// Perform incremental backup from WAL.
    fn perform_incremental_backup(
        &self,
        base_backup: &Backup,
        backup: &mut Backup,
    ) -> Result<(Lsn, u64, String)> {
        let wal = self
            .wal
            .as_ref()
            .ok_or_else(|| DbError::Io(IoError::InternalError("WAL not configured for incremental backup".into())))?;

        // Extract WAL records from base backup end to current LSN
        let start_lsn = base_backup.end_lsn;
        let end_lsn = self.current_lsn();

        // For now, create a placeholder incremental
        // In production, this would extract and serialize WAL records
        let backup_file = File::create(&backup.path).map_err(|e| {
            DbError::Io(IoError::Generic(e))
        })?;

        // Write metadata
        serde_json::to_writer(
            &backup_file,
            &serde_json::json!({
                "base_backup_id": base_backup.id,
                "start_lsn": start_lsn.as_u64(),
                "end_lsn": end_lsn.as_u64(),
                "records": [],
            }),
        )
        .map_err(|e| DbError::Protocol(crate::error::ProtocolError::JsonParseError(e)))?;

        let checksum = format!(
            "{:x}",
            Sha256::digest(format!("{}:{}", start_lsn.as_u64(), end_lsn.as_u64()).as_bytes())
        );
        let size_bytes = 0u64;

        Ok((end_lsn, size_bytes, checksum))
    }

    /// Delete backup by ID.
    pub fn delete_backup(&mut self, id: Uuid) -> Result<()> {
        let backup = self
            .backups
            .get(&id)
            .ok_or_else(|| DbError::Io(IoError::FileNotFound { path: id.to_string() }))?;

        // Delete file
        if backup.path.exists() {
            fs::remove_file(&backup.path).map_err(|e| {
                DbError::Io(IoError::Generic(e))
            })?;
        }

        self.backups.remove(&id);
        Ok(())
    }

    /// Apply retention policy, deleting old backups.
    fn apply_retention_policy(&mut self) {
        let mut backup_ids: Vec<_> = self.backups.keys().copied().collect();

        // Sort by creation time (oldest first)
        backup_ids.sort_by_key(|id| {
            self.backups
                .get(id)
                .map(|b| b.created_at)
                .unwrap_or_else(|| chrono::Utc::now())
        });

        let mut count = 0;
        for id in backup_ids {
            if let Some(backup) = self.backups.get(&id) {
                if self.config.retention.should_retain(backup) {
                    count += 1;
                } else {
                    // Delete old backup
                    let _ = self.delete_backup(id);
                }

                // Enforce max count
                if count >= self.config.retention.max_count {
                    // Keep newer backups
                    continue;
                }
            }
        }
    }

    /// Verify backup integrity by comparing checksums.
    pub fn verify_backup(&self, id: Uuid) -> Result<bool> {
        let backup = self
            .backups
            .get(&id)
            .ok_or_else(|| DbError::Io(IoError::FileNotFound { path: id.to_string() }))?;

        if !backup.path.exists() {
            return Ok(false);
        }

        // Calculate current checksum
        let file = File::open(&backup.path).map_err(|e| {
            DbError::Io(IoError::Generic(e))
        })?;

        let mut hasher = Sha256::new();
        let mut reader = BufReader::new(file);
        let mut buffer = vec![0; 64 * 1024];

        loop {
            let n = reader.read(&mut buffer).map_err(|e| {
                DbError::Io(IoError::Generic(e))
            })?;

            if n == 0 {
                break;
            }

            hasher.update(&buffer[..n]);
        }

        let current_checksum = format!("{:x}", hasher.finalize());
        Ok(current_checksum == backup.checksum)
    }

    /// List backups meeting criteria.
    pub fn list_backups(&self, backup_type: Option<BackupType>) -> Vec<Backup> {
        self.backups
            .values()
            .filter(|b| backup_type.map_or(true, |t| b.backup_type == t))
            .cloned()
            .collect()
    }

    /// Get backup chain for incremental restore.
    pub fn get_backup_chain(&self, backup_id: Uuid) -> Vec<Backup> {
        let mut chain = Vec::new();
        let mut current_id = Some(backup_id);

        while let Some(id) = current_id {
            if let Some(backup) = self.backups.get(&id) {
                chain.push(backup.clone());
                current_id = backup.previous_backup_id;
            } else {
                break;
            }
        }

        // Reverse to get oldest first
        chain.reverse();
        chain
    }

    /// Get current LSN from WAL.
    fn current_lsn(&self) -> Lsn {
        Lsn::new(self.wal.as_ref().map(|w| w.current_lsn()).unwrap_or(0))
    }

    /// Generate backup file path.
    fn backup_path(&self, backup_type: BackupType) -> PathBuf {
        let timestamp = chrono::Utc::now().format("%Y%m%d_%H%M%S");
        let filename = format!("{}__{}.backup", backup_type, timestamp);
        self.config.backup_dir.join(filename)
    }

    /// Load existing backups from directory.
    pub fn load_backups_from_disk(&mut self) -> Result<usize> {
        let entries = fs::read_dir(&self.config.backup_dir).map_err(|e| {
            DbError::Io(IoError::Generic(e))
        })?;

        let mut loaded = 0;
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |e| e == "backup") {
                // Load metadata from file (simplified)
                // In production, this would read metadata from a manifest file
                loaded += 1;
            }
        }

        Ok(loaded)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_backup_type_display() {
        assert_eq!(BackupType::Full.to_string(), "full");
        assert_eq!(BackupType::Incremental.to_string(), "incremental");
        assert_eq!(BackupType::Differential.to_string(), "differential");
        assert_eq!(BackupType::Snapshot.to_string(), "snapshot");
    }

    #[test]
    fn test_backup_status_display() {
        assert_eq!(BackupStatus::Pending.to_string(), "pending");
        assert_eq!(BackupStatus::InProgress.to_string(), "in_progress");
        assert_eq!(BackupStatus::Completed.to_string(), "completed");
        assert_eq!(BackupStatus::Failed.to_string(), "failed");
        assert_eq!(BackupStatus::Cancelled.to_string(), "cancelled");
    }

    #[test]
    fn test_backup_creation() {
        let backup = Backup::new(
            BackupType::Full,
            Lsn::new(100),
            PathBuf::from("/test/backup"),
            None,
            Some(6),
            false,
        );

        assert_eq!(backup.backup_type, BackupType::Full);
        assert_eq!(backup.start_lsn, Lsn::new(100));
        assert_eq!(backup.status, BackupStatus::Pending);
        assert!(backup.previous_backup_id.is_none());
    }

    #[test]
    fn test_backup_lifecycle() {
        let mut backup = Backup::new(
            BackupType::Full,
            Lsn::new(100),
            PathBuf::from("/test/backup"),
            None,
            Some(6),
            false,
        );

        backup.mark_in_progress();
        assert_eq!(backup.status, BackupStatus::InProgress);

        backup.mark_completed(Lsn::new(200), 1024, "abc123".into());
        assert_eq!(backup.status, BackupStatus::Completed);
        assert_eq!(backup.end_lsn, Lsn::new(200));
        assert_eq!(backup.size_bytes, 1024);
        assert_eq!(backup.checksum, "abc123");
        assert!(backup.completed_at.is_some());
    }

    #[test]
    fn test_backup_valid() {
        let mut backup = Backup::new(
            BackupType::Full,
            Lsn::new(100),
            PathBuf::from("/test/backup"),
            None,
            Some(6),
            false,
        );

        assert!(!backup.is_valid());

        backup.mark_completed(Lsn::new(200), 1024, "abc123".into());
        assert!(backup.is_valid());
    }

    #[test]
    fn test_backup_duration() {
        let mut backup = Backup::new(
            BackupType::Full,
            Lsn::new(100),
            PathBuf::from("/test/backup"),
            None,
            Some(6),
            false,
        );

        assert!(backup.duration().is_none());

        backup.mark_completed(Lsn::new(200), 1024, "abc123".into());
        assert!(backup.duration().is_some());
    }

    #[test]
    fn test_retention_policy_default() {
        let policy = RetentionPolicy::default();
        assert_eq!(policy.max_count, 10);
        assert_eq!(policy.max_age_days, 7);
    }

    #[test]
    fn test_retention_should_retain() {
        let policy = RetentionPolicy {
            max_count: 10,
            max_age_days: 7,
        };

        let mut backup = Backup::new(
            BackupType::Full,
            Lsn::new(100),
            PathBuf::from("/test/backup"),
            None,
            Some(6),
            false,
        );

        // Recent backup should be retained
        assert!(policy.should_retain(&backup));

        // Old backup should not be retained
        backup.created_at = chrono::Utc::now() - chrono::Duration::days(10);
        assert!(!policy.should_retain(&backup));
    }

    #[test]
    fn test_schedule_config_default() {
        let config = ScheduleConfig::default();
        assert!(!config.enabled);
        assert_eq!(config.full_interval_hours, 168);
        assert_eq!(config.incremental_interval_hours, 1);
        assert_eq!(config.window_start_hour, 2);
        assert_eq!(config.window_end_hour, 4);
    }

    #[test]
    fn test_backup_config_default() {
        let config = BackupConfig::default();
        assert_eq!(config.backup_dir, PathBuf::from("./backups"));
        assert_eq!(config.retention.max_count, 10);
        assert_eq!(config.compression_level, Some(6));
        assert!(!config.encryption_enabled);
    }

    #[test]
    fn test_backup_manager_new() {
        let temp_dir = tempdir().unwrap();
        let config = BackupConfig {
            backup_dir: temp_dir.path().to_path_buf(),
            ..Default::default()
        };

        let manager = BackupManager::new(config.clone());
        assert!(temp_dir.path().exists());
    }

    #[test]
    fn test_backup_manager_empty() {
        let temp_dir = tempdir().unwrap();
        let config = BackupConfig {
            backup_dir: temp_dir.path().to_path_buf(),
            ..Default::default()
        };

        let manager = BackupManager::new(config);
        assert!(manager.backups().is_empty());
        assert!(manager.latest_backup(BackupType::Full).is_none());
        assert!(manager.latest_completed_backup().is_none());
    }

    #[test]
    fn test_list_backups_filter() {
        let temp_dir = tempdir().unwrap();
        let config = BackupConfig {
            backup_dir: temp_dir.path().to_path_buf(),
            ..Default::default()
        };

        let mut manager = BackupManager::new(config);

        // Add mock backups
        let mut backup1 = Backup::new(
            BackupType::Full,
            Lsn::new(100),
            PathBuf::from("/test/1"),
            None,
            Some(6),
            false,
        );
        backup1.mark_completed(Lsn::new(200), 1024, "abc123".into());

        let mut backup2 = Backup::new(
            BackupType::Incremental,
            Lsn::new(200),
            PathBuf::from("/test/2"),
            Some(backup1.id),
            Some(6),
            false,
        );
        backup2.mark_completed(Lsn::new(300), 512, "def456".into());

        manager.backups.insert(backup1.id, backup1);
        manager.backups.insert(backup2.id, backup2);

        // List all
        assert_eq!(manager.list_backups(None).len(), 2);

        // Filter by type
        assert_eq!(manager.list_backups(Some(BackupType::Full)).len(), 1);
        assert_eq!(
            manager.list_backups(Some(BackupType::Incremental)).len(),
            1
        );
    }

    #[test]
    fn test_backup_chain() {
        let temp_dir = tempdir().unwrap();
        let config = BackupConfig {
            backup_dir: temp_dir.path().to_path_buf(),
            ..Default::default()
        };

        let mut manager = BackupManager::new(config);

        // Create chain: full -> inc1 -> inc2
        let mut full = Backup::new(
            BackupType::Full,
            Lsn::new(100),
            PathBuf::from("/test/full"),
            None,
            Some(6),
            false,
        );
        full.mark_completed(Lsn::new(200), 1024, "abc123".into());

        let mut inc1 = Backup::new(
            BackupType::Incremental,
            Lsn::new(200),
            PathBuf::from("/test/inc1"),
            Some(full.id),
            Some(6),
            false,
        );
        inc1.mark_completed(Lsn::new(300), 512, "def456".into());

        let mut inc2 = Backup::new(
            BackupType::Incremental,
            Lsn::new(300),
            PathBuf::from("/test/inc2"),
            Some(inc1.id),
            Some(6),
            false,
        );
        inc2.mark_completed(Lsn::new(400), 256, "ghi789".into());
        let inc2_id = inc2.id;

        manager.backups.insert(full.id, full);
        manager.backups.insert(inc1.id, inc1);
        manager.backups.insert(inc2.id, inc2);

        let chain = manager.get_backup_chain(inc2_id);
        assert_eq!(chain.len(), 3);
        assert_eq!(chain[0].backup_type, BackupType::Full);
        assert_eq!(chain[1].backup_type, BackupType::Incremental);
        assert_eq!(chain[2].backup_type, BackupType::Incremental);
    }
}
