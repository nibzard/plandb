# Disaster Recovery

## Purpose

Comprehensive disaster recovery system for NorthstarDB that provides data backup, point-in-time recovery, replication, and failover capabilities. The system ensures data durability across failures (disk corruption, node crashes, region outages) with configurable recovery point objectives (RPO) and recovery time objectives (RTO). Supports both single-node recovery (from local backups) and multi-node recovery (from replicas).

## Types

### BackupType

**Description**: Type of backup operation.

**Variants**:
- `Full` - Complete database backup (all data, metadata, logs)
- `Incremental` - Backup of changes since last backup (log records only)
- `Differential` - Backup of changes since last full backup
- `Snapshot` - Point-in-time filesystem snapshot

**Default**: `Incremental` for scheduled backups, `Full` for weekly backups

### BackupStatus

**Description**: Current status of a backup operation.

**Variants**:
- `Pending` - Backup queued, not started
- `InProgress` - Backup actively running
- `Completed` - Backup finished successfully
- `Failed` - Backup failed with error
- `Cancelled` - Backup cancelled by user

### Backup

**Description**: Metadata about a backup operation and its result.

**Fields**:
- `id: Uuid` - Unique backup identifier
- `backup_type: BackupType` - Type of backup
- `status: BackupStatus` - Current status
- `started_at: Instant` - When backup started
- `completed_at: Option<Instant>` - When backup completed (None if in progress)
- `size_bytes: u64` - Size of backup in bytes
- `path: PathBuf` - Path to backup file
- `checksum: String` - SHA-256 checksum of backup file
- `lsn_start: Lsn` - Starting log sequence number
- `lsn_end: Lsn` - Ending log sequence number
- `previous_backup_id: Option<Uuid>` - Previous backup for incremental chain
- `error: Option<String>` - Error message if failed

**Size**: ~256 bytes (metadata only)
**Invariants**:
- `completed_at` is None if status is `Pending` or `InProgress`
- `completed_at` is Some if status is `Completed` or `Failed`
- `lsn_end` >= `lsn_start`
- `previous_backup_id` is Some for `Incremental` backups

### BackupConfig

**Description**: Configuration for backup operations.

**Fields**:
- `enabled: bool` - Whether automatic backups are enabled (default: true)
- `backup_directory: PathBuf` - Directory for backup storage (default: "./backups")
- `retention_count: usize` - Number of backups to retain (default: 10)
- `retention_period: Duration` - Minimum age before backup deletion (default: 7 days)
- `schedule: BackupSchedule` - Automatic backup schedule
- `compression: bool` - Whether to compress backups (default: true)
- `compression_level: u32` - Compression level 0-9 (default: 6)
- `encryption: bool` - Whether to encrypt backups (default: false)
- `encryption_key_path: Option<PathBuf>` - Path to encryption key
- `max_backup_size_bytes: Option<u64>` - Max backup size before warning (None = no limit)
- `verify_after_backup: bool` - Verify backup integrity after creation (default: true)

**BackupSchedule**:
- `full_interval: Duration` - Interval between full backups (default: 7 days)
- `incremental_interval: Duration` - Interval between incremental backups (default: 1 hour)
- `backup_window_start: Option<NaiveTime>` - Start of backup window (None = any time)
- `backup_window_end: Option<NaiveTime>` - End of backup window (None = any time)

**Invariants**:
- `retention_count` >= 1
- `retention_period` >= 1 hour
- `full_interval` >= `incremental_interval`
- `compression_level` in range 0-9
- `backup_window_end` > `backup_window_start` if both present

### RecoveryType

**Description**: Type of recovery operation.

**Variants**:
- `FullRestore` - Restore from full backup
- `PointInTime` - Recover to specific point in time using backup + logs
- `IncrementalRestore` - Restore incremental backup chain
- `ReplicaPromote` - Promote replica to primary

### RecoveryStatus

**Description**: Current status of a recovery operation.

**Variants**:
- `Preparing` - Preparing for recovery (validating backup, stopping database)
- `Restoring` - Actively restoring data
- `ReplayingLogs` - Replaying transaction logs
- `Validating` - Validating recovered data
- `Completed` - Recovery finished successfully
- `Failed` - Recovery failed with error

### Recovery

**Description**: Metadata about a recovery operation and its result.

**Fields**:
- `id: Uuid` - Unique recovery identifier
- `recovery_type: RecoveryType` - Type of recovery
- `status: RecoveryStatus` - Current status
- `backup_id: Uuid` - Backup being recovered from
- `target_lsn: Option<Lsn>` - Target LSN for point-in-time recovery (None = latest)
- `target_time: Option<DateTime<Utc>>` - Target time for point-in-time recovery (None = latest)
- `started_at: Instant` - When recovery started
- `completed_at: Option<Instant>` - When recovery completed (None if in progress)
- `recovered_bytes: u64` - Number of bytes recovered
- `log_records_replayed: u64` - Number of log records replayed
- `error: Option<String>` - Error message if failed

**Size**: ~256 bytes (metadata only)
**Invariants**:
- `target_lsn` is None or >= backup `lsn_start`
- `target_time` is None or >= backup `started_at`
- `completed_at` is None if status is `Preparing`, `Restoring`, or `ReplayingLogs`
- `completed_at` is Some if status is `Completed` or `Failed`

### ReplicationMode

**Description**: Replication mode for primary-replica setup.

**Variants**:
- `Async` - Asynchronous replication (primary acks before replica writes)
- `Sync` - Synchronous replication (primary waits for replica ack)
- `SemiSync` - Semi-synchronous replication (primary waits for at least one replica)

**Default**: `Async` for low latency, `Sync` for high durability

### ReplicationRole

**Description**: Role of this node in replication setup.

**Variants**:
- `Primary` - Primary node accepting writes
- `Replica` - Replica node receiving replicated data
- `Standby` - Standby node not receiving data (for manual failover)

### ReplicaStatus

**Description**: Status of a replica node.

**Variants**:
- `Connecting` - Establishing connection to primary
- `InSync` - Replica is in sync with primary
- `Lagging` - Replica is behind primary
- `Disconnected` - Replica is disconnected from primary
- `Failed` - Replica has failed

### ReplicaInfo

**Description**: Information about a replica node.

**Fields**:
- `id: Uuid` - Unique replica identifier
- `address: String` - Network address of replica
- `status: ReplicaStatus` - Current status
- `current_lsn: Lsn` - Current log sequence number on replica
- `lag_bytes: u64` - Bytes behind primary
- `lag_seconds: u64` - Seconds behind primary
- `last_contact: Instant` - Last successful contact with replica
- `replication_mode: ReplicationMode` - Configured replication mode

**Size**: ~128 bytes
**Invariants**:
- `lag_bytes` is 0 if status is `InSync`
- `current_lsn` <= primary LSN
- `last_contact` is never in the future

### ReplicationConfig

**Description**: Configuration for replication.

**Fields**:
- `enabled: bool` - Whether replication is enabled (default: false)
- `role: ReplicationRole` - Role of this node
- `mode: ReplicationMode` - Replication mode (default: Async)
- `primary_address: Option<String>` - Address of primary (None if this is primary)
- `replica_addresses: Vec<String>` - Addresses of replicas
- `heartbeat_interval: Duration` - Heartbeat interval (default: 5 seconds)
- `heartbeat_timeout: Duration` - Heartbeat timeout (default: 30 seconds)
- `max_lag_bytes: u64` - Maximum allowed lag before marking lagging (default: 1GB)
- `max_lag_seconds: u64` - Maximum allowed lag in seconds (default: 60 seconds)
- `batch_size: u64` - Replication batch size in bytes (default: 1MB)
- `send_buffer_size: u64` - Send buffer size (default: 10MB)

**Invariants**:
- `heartbeat_interval` >= 1 second
- `heartbeat_timeout` >= `heartbeat_interval`
- `max_lag_bytes` >= 0
- `max_lag_seconds` >= 0
- `batch_size` <= `send_buffer_size`

### FailoverMode

**Description**: Type of failover operation.

**Variants**:
- `Automatic` - Automatic failover when primary fails
- `Manual` - Manual failover triggered by administrator
- `Planned` - Planned failover for maintenance

### FailoverStatus

**Description**: Status of a failover operation.

**Variants**:
- `DetectingFailure` - Detecting primary failure
- `ElectingNewPrimary` - Electing new primary among replicas
- `PromotingReplica` - Promoting replica to primary role
- `RedirectingClients` - Redirecting clients to new primary
- `Completed` - Failover completed successfully
- `Failed` - Failover failed with error

### Failover

**Description**: Metadata about a failover operation and its result.

**Fields**:
- `id: Uuid` - Unique failover identifier
- `mode: FailoverMode` - Type of failover
- `status: FailoverStatus` - Current status
- `old_primary_id: Uuid` - ID of old primary
- `new_primary_id: Option<Uuid>` - ID of new primary (None if not elected yet)
- `started_at: Instant` - When failover started
- `completed_at: Option<Instant>` - When failover completed (None if in progress)
- `downtime_seconds: u64` - Seconds of downtime during failover
- `data_loss_bytes: Option<u64>` - Estimated data loss in bytes (None = none)
- `error: Option<String>` - Error message if failed

**Size**: ~256 bytes (metadata only)
**Invariants**:
- `new_primary_id` is None if status is `DetectingFailure`
- `new_primary_id` is Some if status is `PromotingReplica` or later
- `completed_at` is None if status is not `Completed` or `Failed`
- `downtime_seconds` is 0 if status is `Completed` with no actual failover

### BackupManager

**Description**: Manages backup creation, retention, and deletion.

**Fields**:
- `config: Arc<BackupConfig>` - Shared configuration
- `backups: Vec<Backup>` - Registry of all backups
- `current_backup: Option<Backup>` - Currently running backup
- `last_full_backup: Option<Uuid>` - Last full backup ID
- `scheduler: Option<JoinHandle<()>>` - Background scheduler handle

**Size**: Variable (backup metadata, typically <10MB)
**Invariants**:
- `backups` sorted by `started_at` descending (newest first)
- Only one backup in `InProgress` status at a time
- Incremental backups reference valid `previous_backup_id`

### RecoveryManager

**Description**: Manages recovery operations from backups.

**Fields**:
- `config: Arc<BackupConfig>` - Shared configuration
- `recovery_history: Vec<Recovery>` - History of recovery operations
- `current_recovery: Option<Recovery>` - Currently running recovery
- `backup_manager: Arc<BackupManager>` - Reference to backup manager

**Size**: Variable (recovery metadata, typically <1MB)
**Invariants**:
- `recovery_history` sorted by `started_at` descending
- Only one recovery in progress at a time
- `current_recovery` is None if no recovery in progress

### ReplicationManager

**Description**: Manages replication between primary and replicas.

**Fields**:
- `config: Arc<ReplicationConfig>` - Shared configuration
- `replicas: HashMap<Uuid, ReplicaInfo>` - Registered replicas
- `role: ReplicationRole` - Current role of this node
- `replication_task: Option<JoinHandle<()>>` - Background replication task
- `heartbeat_task: Option<JoinHandle<()>>` - Background heartbeat task
- `current_lsn: Lsn` - Current log sequence number
- `replicated_lsn: Lsn` - Latest replicated LSN

**Size**: Variable (replica metadata, typically <1MB per replica)
**Invariants**:
- `replicated_lsn` <= `current_lsn`
- At most one primary in replica set
- `role` is `Primary` if this node is the primary

### FailoverManager

**Description**: Manages automatic failover to replicas.

**Fields**:
- `config: Arc<ReplicationConfig>` - Shared configuration
- `replication_manager: Arc<ReplicationManager>` - Reference to replication manager
- `failover_history: Vec<Failover>` - History of failover operations
- `current_failover: Option<Failover>` - Currently running failover
- `failure_detection_threshold: u32` - Number of missed heartbeats before failover (default: 6)
- `election_timeout: Duration` - Timeout for primary election (default: 10 seconds)

**Size**: Variable (failover metadata, typically <1MB)
**Invariants**:
- `failover_history` sorted by `started_at` descending
- Only one failover in progress at a time
- `failure_detection_threshold` >= 1

## Functions

### create_full_backup(manager: Arc<BackupManager>, db: Arc<Db>) -> Result<Uuid>

**Purpose**: Create a full database backup.

**Parameters**:
- `manager` - Backup manager
- `db` - Database to backup

**Returns**: `Result<Uuid>` - Backup ID on success

**Algorithm**:
1. Check if another backup is in progress, return error if so
2. Create new `Backup` with `Full` type, `Pending` status, generated UUID
3. Acquire database write lock (prevent concurrent writes)
4. Update backup status to `InProgress`, set `started_at` to now
5. Get current LSN from database
6. Create backup file path: `{backup_directory}/full_{uuid}_{timestamp}.backup`
7. Copy database file to backup location
8. Calculate SHA-256 checksum of backup file
9. If `config.compression` enabled:
   a. Compress backup file using configured compression level
10. If `config.encryption` enabled:
   a. Read encryption key from `config.encryption_key_path`
   b. Encrypt backup file using AES-256-GCM
11. Get backup file size
12. Update backup with `lsn_start`, `lsn_end`, `size_bytes`, `checksum`, `path`
13. If `config.verify_after_backup` enabled:
   a. Verify backup file integrity using checksum
   b. Return error if verification fails
14. Update backup status to `Completed`, set `completed_at` to now
15. Store backup in `manager.backups`
16. Update `manager.last_full_backup`
17. Release database write lock
18. Return backup UUID

**Error Conditions**:
- `BackupInProgress`: Another backup is running
- `IoError`: File system error during backup
- `ChecksumMismatch`: Backup verification failed
- `InsufficientSpace`: Not enough disk space for backup

**Concurrency**: Requires database write lock (blocks all operations)

### create_incremental_backup(manager: Arc<BackupManager>, db: Arc<Db>, base_backup_id: Uuid) -> Result<Uuid>

**Purpose**: Create an incremental backup from last backup.

**Parameters**:
- `manager` - Backup manager
- `db` - Database to backup
- `base_backup_id` - Base backup ID (None = use most recent)

**Returns**: `Result<Uuid>` - Backup ID on success

**Algorithm**:
1. Check if another backup is in progress, return error if so
2. Find base backup in `manager.backups` by ID or use most recent
3. Get current LSN from database
4. Calculate log records to backup: `base_backup.lsn_end` to current LSN
5. If no new log records, return error (nothing to backup)
6. Create new `Backup` with `Incremental` type, `Pending` status
7. Acquire database write lock
8. Update backup status to `InProgress`, set `started_at` to now
9. Set `previous_backup_id` to base backup ID
10. Create backup file path: `{backup_directory}/incremental_{uuid}_{timestamp}.backup`
11. Extract log records from WAL between `lsn_start` and `lsn_end`
12. Write log records to backup file
13. Calculate SHA-256 checksum of backup file
14. If `config.compression` enabled, compress backup file
15. If `config.encryption` enabled, encrypt backup file
16. Get backup file size
17. Update backup with metadata
18. If `config.verify_after_backup` enabled, verify backup
19. Update backup status to `Completed`, set `completed_at` to now
20. Store backup in `manager.backups`
21. Release database write lock
22. Return backup UUID

**Error Conditions**:
- `BackupInProgress`: Another backup is running
- `BaseBackupNotFound`: Base backup ID not found
- `NoNewData`: No log records to backup
- `IoError`: File system error during backup

**Concurrency**: Requires database write lock

### restore_backup(manager: Arc<BackupManager>, recovery: Arc<RecoveryManager>, backup_id: Uuid, target_path: PathBuf) -> Result<Uuid>

**Purpose**: Restore database from backup.

**Parameters**:
- `manager` - Backup manager
- `recovery` - Recovery manager
- `backup_id` - Backup to restore from
- `target_path` - Path for restored database

**Returns**: `Result<Uuid>` - Recovery operation ID

**Algorithm**:
1. Find backup in `manager.backups` by ID, return error if not found
2. Create new `Recovery` with `FullRestore` type, `Preparing` status
3. Set `backup_id` to provided backup ID
4. Set `started_at` to now
5. If backup is `Incremental`:
   a. Recursively find base full backup using `previous_backup_id`
   b. Validate all backups in chain exist
6. Acquire database exclusive lock (prevent all access)
7. Shutdown database if running
8. Update recovery status to `Restoring`
9. If backup is `Incremental`:
   a. Restore full backup first
   b. For each incremental backup in chain:
      i. Decrypt backup file if encrypted
      ii. Decompress backup file if compressed
      iii. Replay log records onto restored database
10. If backup is `Full`:
   a. Decrypt backup file if encrypted
   b. Decompress backup file if compressed
   c. Copy backup file to `target_path`
11. Update recovery status to `Validating`
12. Validate restored database:
   a. Open database at `target_path`
   b. Run checksum validation on all pages
   c. Verify B+Tree consistency
13. If validation fails, return error
14. Update recovery status to `Completed`, set `completed_at` to now
15. Update `recovered_bytes` from backup metadata
16. Store recovery in `recovery.recovery_history`
17. Release database exclusive lock
18. Return recovery UUID

**Error Conditions**:
- `BackupNotFound`: Backup ID not found
- `BackupChainBroken`: Incremental backup chain incomplete
- `RestoreFailed`: Restore operation failed
- `ValidationFailed`: Restored database validation failed
- `InsufficientSpace`: Not enough disk space for restore

**Concurrency**: Blocks all database operations

### point_in_time_recovery(manager: Arc<BackupManager>, recovery: Arc<RecoveryManager>, backup_id: Uuid, target_lsn: Lsn) -> Result<Uuid>

**Purpose**: Recover database to specific point in time.

**Parameters**:
- `manager` - Backup manager
- `recovery` - Recovery manager
- `backup_id` - Base backup ID
- `target_lsn` - Target log sequence number

**Returns**: `Result<Uuid>` - Recovery operation ID

**Algorithm**:
1. Find backup in `manager.backups` by ID, return error if not found
2. Validate `target_lsn` >= backup `lsn_start`, return error if not
3. Create new `Recovery` with `PointInTime` type, `Preparing` status
4. Set `backup_id`, `target_lsn` to provided values
5. Set `started_at` to now
6. Acquire database exclusive lock
7. Shutdown database if running
8. Update recovery status to `Restoring`
9. Restore base backup (full or incremental chain) to temp location
10. Update recovery status to `ReplayingLogs`
11. Initialize log position to backup `lsn_end`
12. While log position < `target_lsn`:
   a. Read next log record from WAL
   b. If log record LSN > `target_lsn`, break
   c. Replay log record onto restored database
   d. Increment `log_records_replayed`
   e. Update log position
13. Update recovery status to `Validating`
14. Validate recovered database at `target_lsn`
15. If validation fails, return error
16. Update recovery status to `Completed`, set `completed_at` to now
17. Store recovery in `recovery.recovery_history`
18. Release database exclusive lock
19. Return recovery UUID

**Error Conditions**:
- `BackupNotFound`: Backup ID not found
- `InvalidLsn`: Target LSN before backup start or after current LSN
- `LogGapMissing`: WAL gap detected, cannot replay
- `ValidationFailed`: Recovered database validation failed

**Concurrency**: Blocks all database operations

### start_replication(manager: Arc<ReplicationManager>, db: Arc<Db>) -> Result<()>

**Purpose**: Start replication process.

**Parameters**:
- `manager` - Replication manager
- `db` - Database to replicate

**Returns**: `Result<()>` - Success or error

**Algorithm**:
1. Check if `manager.role` is `Primary`, return error if not
2. For each replica in `manager.replicas`:
   a. Establish TCP connection to replica address
   b. Send handshake with current LSN
   c. Receive replica acknowledgment
   d. Update replica status to `InSync`
3. Create background replication task
4. In replication loop:
   a. Wait for new transaction commit (get new LSN)
   b. Read log records since last `replicated_lsn`
   c. For each replica:
      i. Check replication mode
      ii. If `Sync` or `SemiSync`:
          - Send log records to replica
          - Wait for acknowledgment
          - If timeout, mark replica as `Lagging`
      iii. If `Async`:
          - Queue log records for replica
          - Send in background
      iv. Update `replicated_lsn` when all required replicas ack
5. Monitor replica health via heartbeat task
6. Return success

**Error Conditions**:
- `NotPrimary`: This node is not the primary
- `ConnectionFailed`: Failed to connect to replica
- `ReplicationFailed`: Replication stream failed

**Concurrency**: Background task, non-blocking

### replicate_from_primary(manager: Arc<ReplicationManager>, db: Arc<Db>) -> Result<()>

**Purpose**: Start receiving replication from primary (replica side).

**Parameters**:
- `manager` - Replication manager
- `db` - Database to update

**Returns**: `Result<()>` - Success or error

**Algorithm**:
1. Check if `manager.role` is `Replica`, return error if not
2. Connect to `config.primary_address`
3. Send handshake with current LSN
4. Receive primary acknowledgment with current LSN
5. Update replica status to `InSync`
6. In replication loop:
   a. Receive log records from primary
   b. For each log record:
      i. Verify log record LSN > `current_lsn`
      ii. Apply log record to local database
      iii. Update `current_lsn`
      iv. Calculate lag: `primary_lsn - current_lsn`
   c. Send acknowledgment to primary
   d. Update lag metrics
   e. If lag > `config.max_lag_bytes`, update status to `Lagging`
   f. If lag <= threshold, update status to `InSync`
7. Handle disconnection:
   a. Update status to `Disconnected`
   b. Attempt reconnection with exponential backoff
   c. Update status to `InSync` on reconnection
8. Return success when explicitly stopped

**Error Conditions**:
- `NotReplica`: This node is not a replica
- `PrimaryUnreachable`: Cannot connect to primary
- `ApplyFailed`: Failed to apply log record

**Concurrency**: Background task, non-blocking

### detect_primary_failure(manager: Arc<FailoverManager>) -> bool

**Purpose**: Detect if primary has failed.

**Parameters**:
- `manager` - Failover manager

**Returns**: `bool` - True if primary failed

**Algorithm**:
1. Get `replication_manager.replicas`
2. For each replica:
   a. Calculate time since `last_contact`
   b. If `last_contact` > `config.heartbeat_timeout`:
      i. Increment missed heartbeat count
   c. Else:
      i. Reset missed heartbeat count
3. If missed heartbeat count >= `failure_detection_threshold`:
   a. Return true (primary failed)
4. Return false (primary healthy)

**Error Conditions**: None (assume primary healthy on error)

**Concurrency**: Thread-safe via replication manager read lock

### initiate_failover(manager: Arc<FailoverManager>) -> Result<Uuid>

**Purpose**: Initiate failover to elect new primary.

**Parameters**:
- `manager` - Failover manager

**Returns**: `Result<Uuid>` - Failover operation ID

**Algorithm**:
1. Confirm primary failure via `detect_primary_failure`
2. Create new `Failover` with `Automatic` mode, `DetectingFailure` status
3. Set `old_primary_id` to current primary ID
4. Set `started_at` to now
5. Update failover status to `ElectingNewPrimary`
6. Get list of candidates from `replication_manager.replicas`
7. Filter candidates:
   a. Keep only replicas with `InSync` or `Lagging` status
   b. Sort by `current_lsn` descending (most up-to-date first)
   c. Sort by `lag_bytes` ascending (least lag first)
8. Select best candidate as new primary
9. Update failover with `new_primary_id`
10. Update failover status to `PromotingReplica`
11. Send promote command to selected replica
12. Wait for replica to acknowledge promotion
13. Update failover status to `RedirectingClients`
14. Update DNS or service discovery to point to new primary
15. Update failover status to `Completed`, set `completed_at` to now
16. Calculate `downtime_seconds` from `started_at` to `completed_at`
17. Estimate `data_loss_bytes` from new primary lag
18. Store failover in `manager.failover_history`
19. Return failover UUID

**Error Conditions**:
- `NoCandidatesFound`: No eligible replicas for promotion
- `PromotionFailed`: Replica failed to promote
- `UpdateFailed`: Failed to update client routing

**Concurrency**: Blocks during election and promotion

## Invariants

- Backup file checksum always matches file contents
- Incremental backup chain is unbroken (all ancestors exist)
- Recovery operations are sequential (only one at a time)
- Replicated LSN never exceeds current LSN
- Only one primary in replica set
- Failover selects most up-to-date replica
- Backups are retained per retention policy
- Encrypted backups require valid key for restore

## Dependencies

- **Uses**:
  - `crate::db` - For database access during backup/restore
  - `crate::pager` - For page-level backup operations
  - `crate::log` - For WAL reading and replay
  - `crate::monitoring` - For replication metrics
- **Used by**:
  - `crate::main` - For CLI backup/restore/replication commands
  - Database core - For automatic backup scheduling

## Rust Implementation Guidance

### Module Structure

The Rust module should be organized as follows:

```
src/recovery/
├── mod.rs              # Public exports and module initialization
├── backup.rs           # Backup creation and management
├── restore.rs          # Restore operations
├── replication.rs      # Primary-replica replication
├── failover.rs         # Automatic failover
└── config.rs           # Configuration for all recovery components
```

### Type Definitions

- **Backup**: Should use `struct` with all metadata fields
- **BackupManager**: Should use `Vec<Backup>` for backup registry
- **ReplicationManager**: Should use `HashMap<Uuid, ReplicaInfo>` for replicas
- **FailoverManager**: Should use `Arc<ReplicationManager>` for coordination

### Concurrency

- **Pattern**: Use `Mutex` for backup manager (infrequent writes)
- **Pattern**: Use `RwLock` for replication manager (frequent reads, writes during failover)
- **Pattern**: Use `tokio::sync::mpsc` for async replication streaming
- **Pattern**: Use `tokio::task::JoinSet` for managing background tasks

### Key Decisions

- **Compression**: Use `flate2` with `Compression` level setting
- **Encryption**: Use `aes-gcm` for authenticated encryption
- **Replication Protocol**: Use custom binary protocol over TCP
- **Election Algorithm**: Use simple LSN-based selection (not Raft/Paxos)
- **Storage**: Use local filesystem for backups (future: cloud storage)

### Implementation Notes

Step 1: Implement backup types and configuration
Step 2: Build backup manager with full backup support
Step 3: Add incremental backup with chain tracking
Step 4: Implement restore operations (full and point-in-time)
Step 5: Add compression and encryption support
Step 6: Build replication manager with primary and replica modes
Step 7: Implement automatic failover detection and promotion
Step 8: Add background scheduler for automatic backups
Step 9: Integrate with monitoring system for metrics

### Testing Strategy

**Unit tests needed for**:
- Backup creation and metadata tracking
- Incremental backup chain validation
- Restore from full backup
- Point-in-time recovery with log replay
- Replication streaming from primary to replica
- Primary failure detection
- Failover election and promotion
- Backup retention policy enforcement

**Property tests for**:
- Backup checksum always matches file contents
- Incremental chain is always unbroken
- Replicated LSN never exceeds primary LSN
- Point-in-time recovery LSN is exact

**Integration scenarios**:
- Full backup and restore cycle
- Incremental backup chain restore
- Point-in-time recovery to various LSNs
- Replication with primary failure
- Automatic failover to replica
- Backup retention and deletion
- Encrypted backup restore
- Compressed backup restore
