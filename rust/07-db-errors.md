# Database Errors

## Purpose

This document describes all error types that can occur in NorthstarDB, their causes, when they occur, recovery strategies, and implementation guidance. Errors are categorized by severity, recoverability, and the operation that produces them.

## Error Design Philosophy

### Error Principles

**Explicit Errors**: All errors are explicit, not silent
- No silent failures or ignored errors
- Result<T, Error> for all fallible operations
- Application must handle errors explicitly

**Structured Errors**: Errors carry context, not just messages
- Error types with fields explaining what went wrong
- Error chaining for context ([source] attribute)
- Display implementations with helpful messages

**Recoverable vs Fatal**: Distinguish between recoverable and fatal errors
- Recoverable: Retry or workaround possible (IoError, TransactionError)
- Fatal: Requires database recovery or restart (CorruptedData)

**Actionable Messages**: Error messages explain what to do
- What went wrong
- Why it went wrong
- How to fix it

### Error Categories

**1. Configuration Errors**: Invalid configuration before open
- Severity: Fatal (database cannot open)
- Recovery: Fix configuration and retry
- Example: Invalid cache size, page size mismatch

**2. I/O Errors**: File system failures
- Severity: Recoverable (transient) or Fatal (permanent)
- Recovery: Retry, fix filesystem, or restore from backup
- Example: Permission denied, disk full

**3. Corruption Errors**: Data corruption detected
- Severity: Fatal (database inconsistent)
- Recovery: Restore from backup or attempt repair
- Example: Checksum mismatch, invalid magic

**4. Transaction Errors**: Transaction operation failures
- Severity: Recoverable (retry transaction)
- Recovery: Retry transaction with backoff
- Example: Conflict, validation failure

**5. Resource Errors**: Resource exhaustion
- Severity: Recoverable (wait or reduce workload)
- Recovery: Wait, free resources, or increase capacity
- Example: Out of memory, too many open files

**6. Usage Errors**: API misuse or invalid operations
- Severity: Recoverable (fix application code)
- Recovery: Fix application logic
- Example: Key not found, snapshot not found

## Error Type Hierarchy

```
Error (enum)
├── ConfigError (configuration validation failed)
├── IoError (I/O operation failed)
├── CorruptedData (data corruption detected)
├── TransactionError (transaction operation failed)
├── ResourceError (resource exhausted)
├── NotFoundError (requested entity not found)
├── DatabaseInUse (file lock held by another process)
├── DatabaseClosed (operation on closed database)
├── LockTimeout (failed to acquire lock)
└── RecoveryError (crash recovery failed)
```

## Detailed Error Types

### 1. ConfigError

**Description**: Configuration validation failed

**Severity**: Fatal (database cannot open)

**When It Occurs**:
- DbBuilder::build() validates configuration
- Db::open_with_config() validates config
- Any configuration option validation

**Variants**:

**ConfigError::PathNotSet**:
- Cause: builder.path() not called
- When: DbBuilder::build() called without path
- Example: `Db::builder().build()?`
- Recovery: Call .path("db.ndb") before .build()

**ConfigError::InvalidCacheSize { provided, min, max, reason }**:
- Cause: cache_size not power of 2 or < 16 or > 1,048,576
- When: builder.cache_size() with invalid value
- Example: `.cache_size(100)` (not power of 2)
- Recovery: Use power of 2 in range [16, 1,048,576]

**ConfigError::InvalidPageSize { provided, min, max, reason }**:
- Cause: page_size not power of 2 or not in [4096, 65536]
- When: builder.page_size() with invalid value
- Example: `.page_size(10000)` (not power of 2)
- Recovery: Use power of 2 in range [4096, 65536]

**ConfigError::PageSizeMismatch { config, database }**:
- Cause: Config page_size doesn't match existing database
- When: Opening database with different page_size
- Example: Database created with 16KB pages, config specifies 32KB
- Recovery: Use correct page_size matching database

**ConfigError::InvalidWalThreshold { provided, min, max }**:
- Cause: wal_size_threshold < 1MB
- When: builder.wal_size_threshold() with invalid value
- Example: `.wal_size_threshold(500_000)` (less than 1MB)
- Recovery: Use threshold >= 1,048,576 (1MB)

**ConfigError::InvalidFlushPolicy { policy, reason }**:
- Cause: Flush policy parameters invalid
- When: builder.flush_policy() with invalid parameters
- Example: `FlushPolicy::Batch { max_batch_ms: 0 }`
- Recovery: Use valid policy parameters

**ConfigError::InvalidRetentionPolicy { policy, reason }**:
- Cause: Snapshot retention policy invalid
- When: builder.snapshot_retention() with invalid parameters
- Example: `RetentionPolicy::CountBased { min_keep: 0 }`
- Recovery: Use valid policy parameters

**ConfigError::CompressionUnavailable { algorithm }**:
- Cause: Compression algorithm not compiled
- When: builder.compression() with unavailable algorithm
- Example: `.compression(Compression::Lz4)` without lz4 feature
- Recovery: Enable feature flag or use Compression::None

**Example**:
```rust
let db = Db::builder()
    .cache_size(100)  // Invalid: not power of 2
    .build();

// Error: ConfigError::InvalidCacheSize {
//     provided: 100,
//     min: 16,
//     max: 1048576,
//     reason: "must be power of 2 and >= 16"
// }
```

### 2. IoError

**Description**: File I/O operation failed

**Severity**: Recoverable (transient) or Fatal (permanent)

**When It Occurs**:
- Opening database file
- Reading or writing pages
- Flushing WAL or database file
- Closing file handles

**Variants**:

**IoError::PermissionDenied**:
- Cause: Insufficient permissions for file operation
- When: Opening file without read/write permissions
- Example: Database file owned by root, current user cannot write
- Recovery: Fix file permissions (chmod 600 db.ndb)

**IoError::DiskFull**:
- Cause: No space left on device
- When: Writing page, appending to WAL, checkpoint
- Example: Disk full during WAL append
- Recovery: Free disk space and retry operation

**IoError::ReadOnly**:
- Cause: Filesystem mounted read-only
- When: Attempting to write to database file
- Example: Database on read-only mounted filesystem
- Recovery: Remount read-write or move database to writable filesystem

**IoError::FileTooLarge**:
- Cause: File size exceeds system limit
- When: Growing database file beyond limit (e.g., 2TB on 32-bit)
- Example: Database grows beyond filesystem maximum file size
- Recovery: Use filesystem with larger file size limit, partition database

**IoError::SystemLimit**:
- Cause: System resource limit exceeded
- When: Too many open files, out of file descriptors
- Example: Process limit of 1024 open files exceeded
- Recovery: Increase ulimit (ulimit -n 4096)

**IoError::LockError**:
- Cause: File locking system call failed
- When: Acquiring or releasing file lock
- Example: Lock filesystem not supported (NFS)
- Recovery: Use supported filesystem or check lock mechanism

**IoError::SyncFailed**:
- Cause: fsync failed to persist data
- When: Syncing file to disk
- Example: Disk error during fsync
- Recovery: Check disk health, retry operation

**IoError::CloseFailed**:
- Cause: File handle close failed
- When: Closing database or WAL file
- Example: OS error during close
- Recovery: OS will cleanup on process exit, check filesystem

**IoError::AllocationFailed**:
- Cause: Page allocation failed (disk full or filesystem error)
- When: Allocating new page in database file
- Example: Extending database file fails
- Recovery: Free disk space, check filesystem

**Example**:
```rust
let db = Db::open("/readonly/db.ndb)?;

// Error: IoError::PermissionDenied {
//     path: "/readonly/db.ndb",
//     operation: "open",
//     details: "Read-only file system"
// }
```

### 3. CorruptedData

**Description**: Data corruption detected by checksums or validation

**Severity**: Fatal (database inconsistent)

**When It Occurs**:
- Reading page with invalid checksum
- Loading corrupted FileHeader or meta page
- Recovering from corrupted WAL
- B+Tree traversal detects invalid structure

**Variants**:

**CorruptedData::InvalidMagic**:
- Cause: File header magic number incorrect
- When: Reading FileHeader from page 0
- Example: Opening non-NorthstarDB file as database
- Recovery: Verify correct file, restore from backup if database corrupted

**CorruptedData::UnsupportedVersion**:
- Cause: File format version not supported by this binary
- When: Reading FileHeader with unsupported version
- Example: Database created by future version (version 2, binary supports version 1)
- Recovery: Upgrade database software or downgrade database (if possible)

**CorruptedData::ChecksumMismatch**:
- Cause: Page checksum validation failed
- When: Reading page from Pager
- Example: Page corrupted on disk (bit rot, disk error)
- Recovery: Restore from backup or attempt repair

**CorruptedData::TruncatedData**:
- Cause: File is partial (missing pages)
- When: Reading beyond end of file
- Example: Database file truncated (incomplete copy)
- Recovery: Restore from backup

**CorruptedData::FileHeaderCorrupt**:
- Cause: File header is corrupted
- When: Reading FileHeader from page 0
- Example: File header invalid or unreadable
- Recovery: Restore from backup or check file integrity

**CorruptedData::MetaPageCorrupt**:
- Cause: Meta page (A or B) is corrupted
- When: Reading meta page for root page ID
- Example: Both meta pages A and B corrupted
- Recovery: Restore from backup

**CorruptedData::WalCorrupt**:
- Cause: WAL file is corrupted
- When: Scanning WAL during recovery
- Example: WAL record with invalid checksum
- Recovery: Truncate WAL at corruption point, replay up to corruption

**CorruptedData::WalHeaderInvalid**:
- Cause: WAL header is invalid
- When: Reading WAL header during open
- Example: WAL header magic or version incorrect
- Recovery: Delete WAL file and rely on checkpointed data

**CorruptedData::WalTruncated**:
- Cause: WAL file is truncated (partial record)
- When: Reading WAL during recovery
- Example: WAL file cut off mid-record
- Recovery: Replay up to truncation point, discard partial record

**CorruptedData::BTreeCorrupt**:
- Cause: B+Tree structure is corrupted
- When: Traversing tree during operation or recovery
- Example: Node references invalid page, node order violated
- Recovery: Restore from backup (repair may be possible)

**CorruptedData::RootPageNotFound**:
- Cause: Root page ID not found in database file
- When: Loading B+Tree root page
- Example: Meta page references non-existent page
- Recovery: Restore from backup

**CorruptedData::RootPageCorrupt**:
- Cause: Root page is corrupted
- When: Reading root page from database
- Example: Root page checksum mismatch, invalid type
- Recovery: Restore from backup

**CorruptedData::InvalidRootType**:
- Cause: Root node has invalid node type
- When: Validating root node during open
- Example: Root is internal node but should be leaf (empty tree)
- Recovery: Restore from backup

**CorruptedData::GenesisMissing**:
- Cause: Genesis snapshot (txn_id 0) missing from registry
- When: Loading SnapshotRegistry
- Example: Registry corrupted, genesis snapshot lost
- Recovery: Restore from backup

**CorruptedData::InvalidSnapshotSequence**:
- Cause: Snapshot transaction IDs not monotonic
- When: Loading SnapshotRegistry
- Example: txn_ids out of order (1, 3, 2)
- Recovery: Restore from backup

**CorruptedData::InvalidSnapshotRoot**:
- Cause: Snapshot root page ID invalid
- When: Loading snapshot from registry
- Example: Root page ID doesn't exist or is corrupted
- Recovery: Restore from backup

**Example**:
```rust
let db = Db::open("corrupted.ndb")?;

// Error: CorruptedData::ChecksumMismatch {
//     page_id: 42,
//     expected: 0x12345678,
//     found: 0x87654321,
//     context: "reading page during B+Tree search"
// }
```

### 4. TransactionError

**Description**: Transaction operation failed

**Severity**: Recoverable (retry transaction)

**When It Occurs**:
- Write transaction commit detects conflict
- Transaction validation fails
- Transaction exceeds limits

**Variants**:

**TransactionError::Conflict**:
- Cause: Write-write conflict detected
- When: Write transaction commits with conflicting mutations
- Example: Two transactions modify same key concurrently
- Recovery: Retry transaction with backoff

**TransactionError::SerializationFailure**:
- Cause: Write transaction serialization failed
- When: Transaction commit cannot serialize
- Example: Too many conflicts, serialization retry limit exceeded
- Recovery: Retry transaction later

**TransactionError::ValidationFailed { reason }**:
- Cause: Transaction validation failed
- When: Committing transaction with invalid state
- Example: Key size exceeds limit, value size exceeds limit
- Recovery: Fix transaction data and retry

**TransactionError::KeyTooLarge { size, limit }**:
- Cause: Key size exceeds maximum
- When: Writing key larger than MAX_KEY_SIZE (e.g., 4KB)
- Example: Writing 8KB key
- Recovery: Use smaller key

**TransactionError::ValueTooLarge { size, limit }**:
- Cause: Value size exceeds maximum
- When: Writing value larger than MAX_VALUE_SIZE (e.g., 16MB - page overhead)
- Example: Writing 20MB value
- Recovery: Use smaller value or split into multiple keys

**TransactionError::TooManyMutations { count, limit }**:
- Cause: Transaction mutation limit exceeded
- When: Transaction has too many put/delete operations
- Example: Single transaction with 1M mutations
- Recovery: Split into multiple transactions

**TransactionError::ReadOnly**:
- Cause: Write operation on read transaction
- When: Calling put or delete on ReadTxn
- Example: `read_txn.put(key, value)`
- Recovery: Use WriteTxn for mutations

**TransactionError::AlreadyClosed**:
- Cause: Operation on closed transaction
- When: Using transaction after commit/rollback
- Example: `txn.commit(); txn.get(key)`
- Recovery: Create new transaction

**Example**:
```rust
let mut txn = db.begin_write()?;
txn.put(b"key", b"value");
txn.commit()?;

// Another txn commits same key concurrently:
// Error: TransactionError::Conflict {
//     txn_id: 5,
//     conflicting_key: b"key",
//     hint: "retry transaction after backoff"
// }
```

### 5. ResourceError

**Description**: Resource exhaustion or limitation

**Severity**: Recoverable (wait or reduce workload)

**When It Occurs**:
- Out of memory
- Too many open files
- Lock acquisition timeout

**Variants**:

**ResourceError::OutOfMemory**:
- Cause: Memory allocation failed
- When: Allocating cache, transaction state, B+Tree nodes
- Example: OS refuses memory allocation (OOM)
- Recovery: Reduce cache_size, close other processes, add RAM

**ResourceError::TooManyOpenFiles**:
- Cause: System file descriptor limit exceeded
- When: Opening database or WAL file
- Example: Process limit of 1024 files exceeded
- Recovery: Increase ulimit, reduce open files

**ResourceError::LockTimeout**:
- Cause: Failed to acquire lock within timeout
- When: Acquiring write lock or close lock
- Example: Lock held by stuck thread
- Recovery: Increase timeout, check for deadlock, restart process

**ResourceError::CacheFull**:
- Cause: Page cache full and eviction failed
- When: Reading new page into full cache
- Example: All pages pinned, no evictable pages
- Recovery: Increase cache_size, reduce workload

**ResourceError::WalFull**:
- Cause: WAL file size limit exceeded
- When: Appending to WAL
- Example: WAL exceeds filesystem size
- Recovery: Trigger checkpoint, free disk space

**Example**:
```rust
let db = Db::builder()
    .cache_size(1_000_000)  // Too large for available memory
    .path("db.ndb")
    .build()?;

// Error: ResourceError::OutOfMemory {
//     requested: 16_384_000_000,  // 1M pages * 16KB
//     available: 8_589_934_592,   // 8GB
//     hint: "reduce cache_size"
// }
```

### 6. NotFoundError

**Description**: Requested entity not found

**Severity**: Recoverable (handle gracefully)

**When It Occurs**:
- Reading non-existent key
- Accessing non-existent snapshot

**Variants**:

**NotFoundError::Key**:
- Cause: Key not found in database
- When: Reading key that doesn't exist
- Example: `txn.get(b"nonexistent")`
- Recovery: Handle missing key (return default, insert key)

**NotFoundError::Snapshot { txn_id }**:
- Cause: Snapshot not found in registry
- When: Calling begin_read_at() with non-existent txn_id
- Example: `db.begin_read_at(999)` (snapshot 999 doesn't exist)
- Recovery: Use valid txn_id, use begin_read() for latest

**Example**:
```rust
let txn = db.begin_read()?;
match txn.get(b"missing") {
    Err(Error::NotFoundError(Error::NotFoundError::Key)) => {
        println!("Key not found, using default");
    }
    Err(e) => return Err(e),
    Ok(value) => println!("Found: {:?}", value),
}
```

### 7. DatabaseInUse

**Description**: File lock held by another process

**Severity**: Fatal (cannot open)

**When It Occurs**:
- Opening database already open by another process
- File lock acquisition fails

**Cause**:
- Another process has database open
- Stale lock file from crashed process
- Lock mechanism not supported (NFS)

**Example**:
```rust
// Process 1:
let db1 = Db::open("db.ndb")?;

// Process 2:
let db2 = Db::open("db.ndb")?;

// Error: DatabaseInUse {
//     path: "db.ndb",
//     holder: "process 12345",
//     hint: "close other process or remove stale lock file"
// }
```

**Recovery**:
- Close other process holding lock
- Remove stale lock file if process crashed
- Check filesystem lock support

### 8. DatabaseClosed

**Description**: Operation on closed database

**Severity**: Recoverable (reopen database)

**When It Occurs**:
- Operation after db.close()
- Operation after Db dropped
- Read transaction after database closed

**Cause**:
- Application called db.close()
- Database handle dropped
- Background operation after close

**Example**:
```rust
let db = Db::open("db.ndb")?;
db.close()?;

let txn = db.begin_read()?;

// Error: DatabaseClosed {
//     operation: "begin_read",
//     hint: "database is closed, reopen to continue operations"
// }
```

**Recovery**:
- Reopen database with Db::open()
- Check application logic (why operating on closed db?)

### 9. LockTimeout

**Description**: Failed to acquire lock within timeout

**Severity**: Recoverable (retry with longer timeout)

**When It Occurs**:
- begin_write() blocked by long-running write
- close() blocked by active operations

**Cause**:
- Write transaction taking too long
- Deadlock (should not happen with correct lock ordering)
- Lock holder thread stuck or crashed

**Example**:
```rust
let db = Db::open("db.ndb")?;
let writer1 = db.begin_write()?;

// In another thread, with timeout:
let writer2 = db.begin_write();  // Blocks forever

// With timeout (future feature):
let writer2 = db.begin_write_with_timeout(Duration::from_secs(5))?;

// Error: LockTimeout {
//     lock_type: "write_lock",
//     timeout: 5 seconds,
//     holder: "txn_id 42",
//     hint: "wait for current write transaction to complete"
// }
```

**Recovery**:
- Wait longer
- Check for stuck transaction
- Check for deadlock

### 10. RecoveryError

**Description**: Crash recovery failed

**Severity**: Fatal (database inconsistent)

**When It Occurs**:
- Opening database after crash
- WAL replay fails
- B+Tree recovery fails

**Variants**:

**RecoveryError::WalTooCorrupt**:
- Cause: WAL too corrupted to recover
- When: Too many corrupted records during recovery
- Example: 50% of WAL records corrupted
- Recovery: Restore from backup

**RecoveryError::BTreeRecoveryFailed**:
- Cause: B+Tree recovery failed
- When: Rebuilding B+Tree from WAL fails
- Example: Invalid page references during replay
- Recovery: Restore from backup

**RecoveryError::AllocationFailed**:
- Cause: Page allocation failed during recovery
- When: Allocating page during WAL replay
- Example: Disk full during recovery
- Recovery: Free disk space and retry recovery

**Example**:
```rust
let db = Db::open("crashed.ndb")?;

// Error: RecoveryError::WalTooCorrupt {
//     total_records: 1000,
//     corrupted_records: 600,
//     threshold: 0.5,  // 50%
//     hint: "WAL too corrupted, restore from backup"
// }
```

## Error Handling Patterns

### Pattern 1: Retry with Backoff

**For**: IoError, TransactionError::Conflict, LockTimeout

```rust
use std::time::Duration;
use std::thread;

fn retry_transaction<F, T>(mut f: F) -> Result<T, Error>
where
    F: FnMut() -> Result<T, Error>,
{
    let mut attempts = 0;
    let max_attempts = 5;

    loop {
        match f() {
            Ok(value) => return Ok(value),
            Err(Error::TransactionError(TransactionError::Conflict)) if attempts < max_attempts => {
                attempts += 1;
                let backoff = Duration::from_millis(100 * 2_u64.pow(attempts));
                thread::sleep(backoff);
            }
            Err(e) => return Err(e),
        }
    }
}
```

### Pattern 2: Graceful Degradation

**For**: NotFoundError::Key

```rust
fn get_or_default(db: &Db, key: &[u8], default: Vec<u8>) -> Result<Vec<u8>, Error> {
    let txn = db.begin_read()?;
    match txn.get(key) {
        Ok(value) => Ok(value),
        Err(Error::NotFoundError(NotFoundError::Key)) => Ok(default),
        Err(e) => Err(e),
    }
}
```

### Pattern 3: Fatal Error Handling

**For**: CorruptedData, RecoveryError

```rust
fn open_or_restore(path: &str) -> Result<Db, Error> {
    match Db::open(path) {
        Ok(db) => Ok(db),
        Err(Error::CorruptedData(e)) => {
            eprintln!("Database corrupted: {:?}", e);
            eprintln!("Restoring from backup...");
            restore_from_backup(path)?;
            Db::open(path)
        }
        Err(e) => Err(e),
    }
}
```

### Pattern 4: Context Propagation

**For**: All errors

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("database error: {0}")]
    Database(#[from] Error),

    #[error("configuration error: {0}")]
    Config(String),
}

fn open_database(path: &str) -> Result<Db, AppError> {
    let db = Db::open(path).map_err(AppError::Database)?;
    Ok(db)
}
```

## Rust Implementation Guidance

### Error Type Definition

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("configuration error: {0}")]
    ConfigError(#[from] ConfigError),

    #[error("I/O error: {0}")]
    IoError(#[from] IoError),

    #[error("corrupted data: {0}")]
    CorruptedData(#[from] CorruptedData),

    #[error("transaction error: {0}")]
    TransactionError(#[from] TransactionError),

    #[error("resource error: {0}")]
    ResourceError(#[from] ResourceError),

    #[error("not found: {0}")]
    NotFoundError(#[from] NotFoundError),

    #[error("database in use by another process")]
    DatabaseInUse,

    #[error("database is closed")]
    DatabaseClosed,

    #[error("lock acquisition timeout")]
    LockTimeout,

    #[error("recovery failed: {0}")]
    RecoveryError(#[from] RecoveryError),
}
```

### Sub-Error Types

**ConfigError**:
```rust
#[derive(Debug, Error, PartialEq, Clone)]
pub enum ConfigError {
    #[error("path not set")]
    PathNotSet,

    #[error("invalid cache size: {provided} (min: {min}, max: {max}, reason: {reason})")]
    InvalidCacheSize { provided: usize, min: usize, max: usize, reason: String },

    #[error("invalid page size: {provided} (min: {min}, max: {max}, reason: {reason})")]
    InvalidPageSize { provided: usize, min: usize, max: usize, reason: String },

    #[error("page size mismatch: config={config}, database={database}")]
    PageSizeMismatch { config: usize, database: usize },

    #[error("invalid WAL threshold: {provided} (min: {min})")]
    InvalidWalThreshold { provided: u64, min: u64, max: u64 },

    #[error("invalid flush policy: {policy:?} (reason: {reason})")]
    InvalidFlushPolicy { policy: FlushPolicy, reason: String },

    #[error("invalid retention policy: {policy:?} (reason: {reason})")]
    InvalidRetentionPolicy { policy: RetentionPolicy, reason: String },

    #[error("compression algorithm {algorithm:?} unavailable")]
    CompressionUnavailable { algorithm: Compression },
}
```

**IoError**:
```rust
#[derive(Debug, Error)]
pub enum IoError {
    #[error("permission denied: {path} ({operation})")]
    PermissionDenied { path: String, operation: String },

    #[error("disk full")]
    DiskFull,

    #[error("read-only filesystem")]
    ReadOnly,

    #[error("file too large")]
    FileTooLarge,

    #[error("system limit exceeded")]
    SystemLimit,

    #[error("lock error: {0}")]
    LockError(#[source] std::io::Error),

    #[error("sync failed")]
    SyncFailed,

    #[error("close failed")]
    CloseFailed,

    #[error("allocation failed")]
    AllocationFailed,
}

impl From<std::io::Error> for IoError {
    fn from(err: std::io::Error) -> Self {
        match err.kind() {
            std::io::ErrorKind::PermissionDenied => IoError::PermissionDenied {
                path: String::new(),  // Set by caller
                operation: "unknown".into(),
            },
            std::io::ErrorKind::StorageFull => IoError::DiskFull,
            _ => IoError::LockError(err),
        }
    }
}
```

**CorruptedData**:
```rust
#[derive(Debug, Error, Clone, PartialEq)]
pub enum CorruptedData {
    #[error("invalid magic number")]
    InvalidMagic,

    #[error("unsupported version")]
    UnsupportedVersion,

    #[error("checksum mismatch on page {page_id} (expected {expected:x}, found {found:x})")]
    ChecksumMismatch { page_id: u64, expected: u32, found: u32 },

    #[error("truncated data")]
    TruncatedData,

    #[error("file header corrupt")]
    FileHeaderCorrupt,

    #[error("meta page corrupt")]
    MetaPageCorrupt,

    #[error("WAL corrupt")]
    WalCorrupt,

    #[error("WAL header invalid")]
    WalHeaderInvalid,

    #[error("WAL truncated")]
    WalTruncated,

    #[error("B+Tree corrupt")]
    BTreeCorrupt,

    #[error("root page not found")]
    RootPageNotFound,

    #[error("root page corrupt")]
    RootPageCorrupt,

    #[error("invalid root type")]
    InvalidRootType,

    #[error("genesis snapshot missing")]
    GenesisMissing,

    #[error("invalid snapshot sequence")]
    InvalidSnapshotSequence,

    #[error("invalid snapshot root")]
    InvalidSnapshotRoot,
}
```

### Error Testing

**Unit Tests**:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_display() {
        let err = Error::ConfigError(ConfigError::PathNotSet);
        assert_eq!(format!("{}", err), "configuration error: path not set");
    }

    #[test]
    fn test_error_source() {
        let io_err = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "access denied");
        let err = Error::IoError(io_err.into());
        assert!(err.source().is_some());
    }

    #[test]
    fn test_config_error_validation() {
        let err = ConfigError::InvalidCacheSize {
            provided: 100,
            min: 16,
            max: 1048576,
            reason: "must be power of 2".into(),
        };
        let msg = format!("{}", err);
        assert!(msg.contains("100"));
        assert!(msg.contains("power of 2"));
    }
}
```

### Error Documentation

**Best Practices**:
- Include context in error messages
- Provide actionable hints
- Chain errors with #[source]
- Implement Display for user-friendly messages
- Implement Debug for developer details

**Example Error Message**:
```
Error: TransactionError::Conflict

Transaction 42 conflicted with transaction 41 on key "user:123"

Caused by:
  Write-write conflict detected during commit

Hint: Retry transaction 42 with exponential backoff
```

## Testing Strategy

**Unit Tests Needed For**:
- All error types construct correctly
- Error Display implementations produce helpful messages
- Error chaining preserves context
- Error conversions (From implementations) work correctly

**Integration Tests Needed For**:
- Invalid configuration returns ConfigError
- File system errors return IoError
- Corrupted database returns CorruptedData
- Transaction conflict returns TransactionError
- Lock timeout returns LockTimeout

**Property Tests Needed For**:
- All errors can be constructed and displayed
- Error round-trip (deserialize -> Error -> serialize)
- Error equality works correctly (where applicable)

**Hardening Tests Needed For**:
- Corrupt file header → CorruptedData::InvalidMagic
- Corrupt page checksum → CorruptedData::ChecksumMismatch
- Disk full during write → IoError::DiskFull
- Permission denied → IoError::PermissionDenied
- Concurrent writes → TransactionError::Conflict (one wins, one conflicts)
