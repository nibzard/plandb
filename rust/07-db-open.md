# Database Opening Process

## Purpose

This document describes the complete process of opening a database, including configuration validation, file locking, component initialization, crash recovery, and error handling. The open process is the critical initialization phase that ensures the database is in a consistent state before any operations are performed.

## Open Process Overview

### High-Level Steps

**1. Configuration Validation**: Validate all configuration options before any I/O
**2. File Lock Acquisition**: Ensure exclusive access to database file
**3. File Handle Creation**: Open database and WAL files
**4. Pager Initialization**: Initialize page cache and storage layer
**5. WAL Initialization**: Open WAL and determine recovery mode
**6. Crash Recovery**: Replay WAL if needed (dirty shutdown)
**7. Component Assembly**: Initialize B+Tree and SnapshotRegistry
**8. Database Handle Creation**: Wrap components in DbInner and Db handle
**9. Return Success**: Provide Db handle to caller

### Open Modes

**New Database**: Database file does not exist
- Create new database file with empty B+Tree
- Initialize WAL
- Create genesis snapshot (txn_id 0)
- No recovery needed

**Existing Database (Clean Shutdown)**: Database file exists, meta page valid
- Open existing database file
- Load B+Tree root page ID from meta page
- Load SnapshotRegistry from persisted state
- No recovery needed if WAL empty

**Existing Database (Dirty Shutdown)**: Database file exists, WAL non-empty
- Open existing database file
- Replay WAL to restore committed transactions
- Rebuild SnapshotRegistry from replayed transactions
- Truncate WAL after successful replay
- Checkpoint if needed

## Detailed Open Algorithm

### Step 1: Configuration Validation

**Purpose**: Catch configuration errors before file I/O

**Validation Rules**:
1. Path is not None (must be set via builder.path())
2. Cache size is power of 2 and >= 16 pages
3. Page size is power of 2 and between 4096 and 65536
4. WAL size threshold is >= 1MB (1,048,576 bytes)
5. Flush policy is valid variant
6. Snapshot retention policy is valid (min_keep >= 1, max_age_seconds > 0)
7. Compression algorithm is available (compile-time feature check)

**Error Conditions**:
- Invalid cache size → ConfigError::InvalidCacheSize
- Invalid page size → ConfigError::InvalidPageSize
- Invalid WAL threshold → ConfigError::InvalidWalThreshold
- Invalid flush policy → ConfigError::InvalidFlushPolicy
- Invalid retention policy → ConfigError::InvalidRetentionPolicy
- Unavailable compression → ConfigError::CompressionUnavailable

**Validation Implementation**:
- Validate in builder.build() method
- Return Err(Error) with specific variant and context
- Provide clear error messages explaining what's wrong and how to fix

### Step 2: Path Resolution and File Lock Acquisition

**Purpose**: Ensure exclusive access to database file

**Steps**:
1. Resolve path to absolute path (canonicalize)
2. Create parent directories if they don't exist (create_dir_all)
3. Attempt to acquire exclusive file lock on database file
4. If lock acquisition fails, return DatabaseInUse error

**File Lock Details**:
- Platform-specific: flock on Unix, LockFileEx on Windows
- Lock scope: Entire file (exclusive lock)
- Lock duration: Held until Db.close() or Drop
- Lock behavior: Non-blocking (fail immediately if locked)
- Lock cleanup: Automatically released on process exit

**Error Conditions**:
- Path too long → ConfigError::PathTooLong
- Invalid path characters → ConfigError::InvalidPath
- Permission denied creating directories → IoError::PermissionDenied
- Lock held by another process → Error::DatabaseInUse
- Lock acquisition failed (system error) → IoError::LockError

**Implementation Notes**:
- Use fs2 crate or similar for cross-platform file locking
- Canonicalize path before lock acquisition
- Create parent directories with mode 0755 (rwxr-xr-x)
- Acquire lock on .lock file adjacent to database file (optional approach)

### Step 3: File Handle Creation

**Purpose**: Open database and WAL files for I/O

**Steps**:
1. Open database file with read-write permissions
2. Create file if it doesn't exist (O_CREAT)
3. Open WAL file with read-write permissions
4. Create WAL file if it doesn't exist

**File Open Flags**:
- Database file: O_RDWR | O_CREAT (read-write, create if not exists)
- WAL file: O_RDWR | O_CREAT (read-write, create if not exists)
- Platform-specific: O_NOATIME if available (reduce metadata updates)

**Error Conditions**:
- Permission denied → IoError::PermissionDenied
- Disk full → IoError::DiskFull
- Read-only filesystem → IoError::ReadOnly
- File too large → IoError::FileTooLarge
- System limit exceeded (open files) → IoError::SystemLimit

**Implementation Notes**:
- Use std::fs::OpenOptions for cross-platform file opening
- Set appropriate permissions (0600 for database, 0600 for WAL)
- Buffer writes for better performance ( BufWriter)
- Sync on parent directory after file creation (ensure directory entry persisted)

### Step 4: Detect Database State

**Purpose**: Determine if new database, clean shutdown, or dirty shutdown

**Steps**:
1. Check database file size
2. If size is 0 → new database
3. If size > 0 → read FileHeader from first page
4. Validate FileHeader magic and version
5. Check meta page A/B for current root page ID
6. Check WAL file size and last LSN

**Detection Logic**:
- File size == 0 bytes → New database
- File size > 0 but no valid header → CorruptedData
- File size > 0 with valid header → Existing database
- WAL size > 0 → Dirty shutdown (recovery needed)
- WAL size == 0 → Clean shutdown (no recovery needed)

**Error Conditions**:
- Invalid magic in FileHeader → CorruptedData::InvalidMagic
- Unsupported version → CorruptedData::UnsupportedVersion
- Checksum mismatch in FileHeader → CorruptedData::ChecksumMismatch
- Truncated file (partial page) → CorruptedData::TruncatedData
- Meta page corruption → CorruptedData::MetaPageCorrupt

**Implementation Notes**:
- Read first page (page 0) to get FileHeader
- Validate magic number: 0x4E53545244420000 "NSTRDB\0\0"
- Validate format version: 1 (current)
- Check meta page A (page 1) and meta page B (page 2)
- Use valid page with higher LSN as current meta page

### Step 5: Pager Initialization

**Purpose**: Initialize page cache and storage layer

**Steps**:
1. Create Pager with file handle and page size from config
2. Set cache size from config
3. Initialize buffer pool
4. Initialize free list
5. If new database, format database with header pages
6. If existing database, load FileHeader and validate

**Pager::new Parameters**:
- file: File (database file handle)
- page_size: usize (from config, default 16384)
- cache_size: usize (from config, default 1024 pages)

**New Database Initialization**:
- Write FileHeader to page 0
- Initialize meta page A (page 1) with root_page_id = NULL_PAGE_ID
- Initialize meta page B (page 2) with root_page_id = NULL_PAGE_ID
- Mark meta page A as current (meta_page_a.current = true)
- Allocate root page for B+Tree (page 3, first data page)
- Sync file (fsync) to persist initialization

**Existing Database Loading**:
- Read FileHeader from page 0
- Validate page_size matches config (error if mismatch)
- Read meta page A and B
- Determine current meta page (higher LSN or current flag)
- Load root_page_id from current meta page
- Initialize free list from FileHeader

**Error Conditions**:
- Page size mismatch → ConfigError::PageSizeMismatch
- FileHeader corruption → CorruptedData::FileHeaderCorrupt
- Meta page corruption → CorruptedData::MetaPageCorrupt
- Allocation failed → IoError::AllocationFailed

**See**: 02-pager-open.md for detailed Pager initialization specification

### Step 6: WAL Initialization

**Purpose**: Open WAL and determine if recovery is needed

**Steps**:
1. Open WAL file with file handle
2. Create WAL with recovery mode
3. Check WAL file size
4. If WAL size > 0 → recovery needed (dirty shutdown)
5. If WAL size == 0 → no recovery needed (clean shutdown)

**Wal::new Parameters**:
- file: File (WAL file handle)
- recovery_mode: RecoveryMode (Full, Checkpoint, None)

**Recovery Mode Determination**:
- WAL file exists and size > 0 → RecoveryMode::Full
- WAL file exists and size == 0 → RecoveryMode::None
- WAL file does not exist → Create new WAL file, RecoveryMode::None

**WAL State After Initialization**:
- WAL ready for append operations
- Last LSN determined from file scan
- Recovery ready if WAL non-empty

**Error Conditions**:
- WAL file corruption → CorruptedData::WalCorrupt
- WAL header invalid → CorruptedData::WalHeaderInvalid
- WAL truncated → CorruptedData::WalTruncated

**See**: 03-wal-open.md for detailed WAL initialization specification

### Step 7: Crash Recovery (if needed)

**Purpose**: Replay WAL to restore committed transactions

**Trigger**: WAL file size > 0 (dirty shutdown detected)

**Steps**:
1. Scan WAL from beginning to end
2. Validate checksums for each record
3. Collect all commit records (type = COMMIT)
4. Filter committed transactions (have complete commit record)
5. Sort transactions by LSN (apply in commit order)
6. For each committed transaction:
   a. Deserialize commit record
   b. Apply mutations to B+Tree (put, delete)
   c. Update SnapshotRegistry with new root page ID
7. After replay, truncate WAL to empty
8. Update meta page with latest root page ID
9. Sync file (fsync) to persist recovered state

**Recovery Statistics**:
- Transactions replayed (committed transactions found in WAL)
- Transactions skipped (incomplete or corrupted)
- Records processed (total WAL records scanned)
- Mutations applied (total put/delete operations)
- Recovery duration (milliseconds)

**Error Handling During Recovery**:
- Corrupted record → Skip record, log warning, continue
- Truncated WAL → Replay up to truncation point, stop
- Checksum mismatch → Skip record, log warning, continue
- Invalid operation → Skip operation, log warning, continue
- B+Tree update failed → Abort recovery, return RecoveryError

**Recovery Guarantees**:
- All committed transactions restored
- No partial commits applied (atomicity)
- Database in consistent state after recovery
- WAL truncated after successful recovery
- Meta page updated with current state

**Error Conditions**:
- Recovery failed → Error::RecoveryFailed
- B+Tree corruption during replay → CorruptedData::BTreeCorrupt
- Allocation failed during replay → IoError::AllocationFailed
- Too many corrupted records → Error::RecoveryFailed (WAL hopelessly corrupt)

**See**: 03-wal-recovery.md for detailed recovery specification
**See**: 06-btree-recovery.md for detailed B+Tree recovery specification

### Step 8: B+Tree Initialization

**Purpose**: Initialize B+Tree with root page ID

**Steps**:
1. Get root_page_id from meta page (or NULL_PAGE_ID if new database)
2. If root_page_id is NULL_PAGE_ID:
   a. Allocate new page for root node
   b. Initialize empty leaf node as root
   c. Set root_page_id to new page
   d. Update meta page with new root_page_id
3. Create B+Tree with root_page_id
4. B+Tree references Pager for I/O operations

**BTree::new Parameters**:
- pager: Arc<Pager>
- root_page_id: PageId
- snapshot_registry: Arc<RwLock<SnapshotRegistry>>

**New Database B+Tree**:
- Empty tree with single leaf node as root
- Root node has 0 entries
- Tree height = 1 (root is leaf)
- Ready for inserts and deletes

**Existing Database B+Tree**:
- Load root_page_id from meta page
- Tree structure already persisted
- Ready for operations without modification

**Error Conditions**:
- Root page not found → CorruptedData::RootPageNotFound
- Root page corrupted → CorruptedData::RootPageCorrupt
- Invalid root page type → CorruptedData::InvalidRootType

**See**: 06-btree-overview.md for detailed B+Tree specification

### Step 9: SnapshotRegistry Initialization

**Purpose**: Initialize snapshot registry for MVCC

**Steps**:
1. If new database:
   a. Create genesis snapshot (txn_id = 0)
   b. Set genesis root_page_id to current B+Tree root
   c. Initialize registry with only genesis snapshot
2. If existing database:
   a. Load SnapshotRegistry from persisted storage
   b. Validate all snapshots in registry
   c. Ensure genesis snapshot (txn_id = 0) exists
   d. Set current_txn_id to highest txn_id + 1
3. Set current_root_page_id to current B+Tree root

**SnapshotRegistry::init Parameters**:
- allocator: Pager reference (for page allocation validation)
- current_txn_id: u64 (loaded from registry or initialized to 1)
- current_root_page_id: PageId (from B+Tree)

**New Database Registry**:
- Genesis snapshot: txn_id = 0, root_page_id = current root
- No committed transactions yet
- Next transaction ID = 1

**Existing Database Registry**:
- Load persisted snapshots from disk
- Validate snapshot consistency
- Ensure monotonic txn_id sequence
- Next transaction ID = max(txn_id) + 1

**Error Conditions**:
- Genesis snapshot missing → CorruptedData::GenesisMissing
- Snapshot txn_id not monotonic → CorruptedData::InvalidSnapshotSequence
- Snapshot root page invalid → CorruptedData::InvalidSnapshotRoot

**See**: 05-snapshot-registry.md for detailed SnapshotRegistry specification

### Step 10: Component Assembly

**Purpose**: Assemble all components into DbInner and Db handle

**Steps**:
1. Create DbInner with all components:
   a. config: Config (validated)
   b. pager: Arc<Pager>
   c. wal: Arc<Wal>
   d. btree: BTree
   e. snapshot_registry: Arc<RwLock<SnapshotRegistry>>
   f. current_txn_id: AtomicU64 (initialized to next txn ID)
   g. current_root_page_id: AtomicU64 (initialized to current root)
   h. write_lock: Mutex::new(())
   i. stats: Arc<RwLock<DbStats>>
   j. is_open: AtomicBool::new(true)
   k. file_lock: Some(file_lock)
2. Wrap DbInner in Arc<RwLock<>>
3. Create Db handle with Arc<RwLock<DbInner>> and path
4. Return Ok(Db)

**DbInner Initialization**:
- All components owned by DbInner
- Arc wrapping for shared ownership
- RwLock wrapping for concurrent access
- Atomic types for lock-free counters

**Db Handle Creation**:
- inner: Arc<RwLock<DbInner>>
- path: PathBuf (absolute path to database file)
- Cloneable (Arc::clone)
- Send + Sync (thread-safe)

### Step 11: Return Success

**Purpose**: Provide Db handle to caller

**Return Value**: Ok(Db)

**Post-Conditions**:
- Database is open and operational
- All components initialized and consistent
- Recovery completed if needed
- File lock held exclusively
- Ready for transaction operations

## Open Options

### Db::open(path)

**Description**: Open database with default configuration

**Parameters**:
- path: P (implies AsRef<Path>)

**Behavior**:
- Uses Config::default() for all options
- Default cache_size: 1024 pages (16MB)
- Default page_size: 16384 bytes (16KB)
- Default wal_size_threshold: 100MB
- Default flush_policy: FlushPolicy::Batch
- Default snapshot_retention: RetentionPolicy::CountBased { min_keep: 100 }
- Default auto_checkpoint: true
- Default compression: Compression::None

**Use Case**: Quick database open with sensible defaults

**Example**:
```
let db = Db::open("mydb.ndb")?;
```

### Db::open_with_config(path, config)

**Description**: Open database with explicit configuration

**Parameters**:
- path: P (implies AsRef<Path>)
- config: Config (pre-built)

**Behavior**:
- Uses provided config for all options
- Config must be validated before passing
- No additional validation in open_with_config

**Use Case**: Reusing configuration across multiple databases

**Example**:
```
let config = Config::builder()
    .cache_size(2048)
    .page_size(32768)
    .build()?;
let db = Db::open_with_config("mydb.ndb", config)?;
```

### Db::builder().path(path).build()

**Description**: Open database with builder pattern

**Behavior**:
- Fluent API for configuration
- Validation in build() method
- Chainable configuration methods

**Use Case**: Custom configuration with compile-time validation

**Example**:
```
let db = Db::builder()
    .path("mydb.ndb")
    .cache_size(2048)
    .page_size(32768)
    .flush_policy(FlushPolicy::Immediate)
    .build()?;
```

## Error Handling

### Error Types

**ConfigError**: Configuration validation failed
- InvalidCacheSize: cache_size not power of 2 or < 16
- InvalidPageSize: page_size not power of 2 or not in range
- InvalidWalThreshold: wal_size_threshold < 1MB
- InvalidFlushPolicy: flush_policy variant invalid
- InvalidRetentionPolicy: retention_policy parameters invalid
- CompressionUnavailable: compression algorithm not compiled
- PathTooLong: path exceeds system limit
- InvalidPath: path contains invalid characters

**Error::DatabaseInUse**: File lock held by another process
- Cannot acquire exclusive file lock
- Another process has database open
- Wait for other process to close or check for stale lock

**IoError**: File I/O failed
- PermissionDenied: Insufficient permissions
- DiskFull: No space left on device
- ReadOnly: Read-only filesystem
- FileTooLarge: File size exceeds system limit
- SystemLimit: Too many open files
- LockError: File lock system call failed

**CorruptedData**: Database file is corrupted
- InvalidMagic: File header magic number incorrect
- UnsupportedVersion: File format version not supported
- ChecksumMismatch: Page checksum validation failed
- TruncatedData: File is partial (missing pages)
- FileHeaderCorrupt: File header is corrupted
- MetaPageCorrupt: Meta page is corrupted
- WalCorrupt: WAL file is corrupted
- WalHeaderInvalid: WAL header is invalid
- WalTruncated: WAL file is truncated
- BTreeCorrupt: B+Tree structure is corrupted
- RootPageNotFound: Root page ID not found in file
- RootPageCorrupt: Root page is corrupted
- InvalidRootType: Root node has invalid type
- GenesisMissing: Genesis snapshot missing from registry
- InvalidSnapshotSequence: Snapshot txn_ids not monotonic
- InvalidSnapshotRoot: Snapshot root page ID invalid

**Error::RecoveryFailed**: Crash recovery failed
- WAL too corrupted to recover
- B+Tree update failed during replay
- Too many corrupted records in WAL
- Allocation failed during replay

### Error Recovery Strategies

**ConfigError**: Fix configuration and retry
- Adjust cache_size to valid value
- Adjust page_size to valid value
- Adjust wal_size_threshold to valid value
- Choose different flush_policy or retention_policy
- Disable compression if not available

**Error::DatabaseInUse**: Wait or close other process
- Wait for other process to finish
- Check for stale lock (process crashed)
- Manually remove lock file if stale

**IoError**: Fix system conditions and retry
- Grant necessary permissions
- Free disk space
- Use read-write filesystem
- Increase system limits (ulimit)

**CorruptedData**: Restore from backup or reinitialize
- Restore from backup if available
- Reinitialize database (accept data loss)
- Attempt partial recovery if possible

**Error::RecoveryFailed**: Restore from backup or reinitialize
- WAL too corrupt → Restore from backup
- B+Tree corrupt → Restore from backup
- Last resort: Reinitialize database (total data loss)

## Performance Considerations

### Open Performance Factors

**Database Size**: Larger databases take longer to open
- File I/O for header and meta pages (constant time)
- SnapshotRegistry loading (O(N) where N = snapshot count)
- No full database scan (only metadata loaded)

**WAL Size**: Larger WAL takes longer to recover
- Replay time proportional to WAL size
- Recovery throughput: ~100K ops/sec
- 1GB WAL with 1M operations → ~10 seconds recovery

**Cache Size**: Larger cache increases memory usage
- Cache allocated during Pager initialization
- Memory = cache_size * page_size
- Default 1024 pages * 16KB = 16MB

**Page Size**: Larger pages reduce tree height but increase I/O granularity
- Smaller pages (4KB): Taller tree, more page reads
- Larger pages (64KB): Shorter tree, fewer page reads
- Default 16KB balances tree height and I/O

### Optimization Strategies

**Minimize Recovery Time**:
- Enable auto_checkpoint (reduces WAL size)
- Use FlushPolicy::Immediate (forces frequent checkpoints)
- Use smaller wal_size_threshold (more frequent checkpoints)

**Reduce Memory Footprint**:
- Use smaller cache_size
- Use smaller page_size
- Disable unnecessary features (compression)

**Faster Open for Read-Only Workloads**:
- Skip recovery if database opened read-only (future feature)
- Use read-only file handles (no lock needed)
- Open multiple read-only instances concurrently

## Invariants

### Pre-Open Invariants

1. **Valid Configuration**: All config options must be valid
   - Validation occurs before any I/O
   - Early failure prevents wasted work

2. **Path Resolved**: Path must be absolute and valid
   - Canonicalized to absolute path
   - Parent directories exist

3. **File Lock Available**: Exclusive lock must be acquirable
   - No other process has database open
   - Lock file can be created

### Post-Open Invariants

1. **Database Open**: is_open is true
   - All operations can proceed
   - Components are initialized

2. **Components Consistent**: All components reference each other correctly
   - Pager holds file handle
   - WAL holds WAL file handle
   - B+Tree references Pager
   - SnapshotRegistry references B+Tree roots
   - DbInner owns all components

3. **File Lock Held**: Exclusive lock on database file
   - Prevents concurrent opens
   - Released on close

4. **Recovery Complete**: WAL is empty (if recovery was needed)
   - All committed transactions replayed
   - Database in consistent state

5. **Genesis Snapshot**: SnapshotRegistry has txn_id 0
   - Root page ID valid
   - Always present

## Dependencies

### Open Process Uses

- **Config**: Validation and storage of configuration
- **Pager**: Page I/O and cache initialization
- **Wal**: WAL initialization and recovery
- **BTree**: Tree initialization
- **SnapshotRegistry**: Snapshot loading and initialization
- **FileLock**: File lock acquisition

### Open Process Used By

- **Db::open**: Entry point for default configuration
- **Db::open_with_config**: Entry point for explicit configuration
- **DbBuilder::build**: Entry point for builder pattern

## Rust Implementation Guidance

### Module Structure

```
northstar-core/src/db/
├── mod.rs          # Db, DbBuilder, open methods
├── open.rs         # Database opening logic (private module)
├── config.rs       # Config validation
└── error.rs        # Error types for open failures
```

### Type Definitions

**OpenContext**: Private struct for tracking open state
- path: PathBuf
- config: Config
- file_lock: Option<FileLock>
- db_file: Option<File>
- wal_file: Option<File>
- pager: Option<Arc<Pager>>
- wal: Option<Arc<Wal>>
- btree: Option<BTree>
- snapshot_registry: Option<Arc<RwLock<SnapshotRegistry>>>

**OpenResult**: Private enum for open result
- Success(Db)
- Recoverable(Error)
- Fatal(Error)

### Concurrency

**Open is Single-Threaded**:
- No concurrent opens allowed (file lock)
- Open completes before any operations
- No locks needed during open (exclusive access)

**Post-Open Concurrency**:
- Db handle is thread-safe (Send + Sync)
- Multiple threads can use Db concurrently
- begin_read() acquires shared lock
- begin_write() acquires exclusive lock

### Key Decisions

**Synchronous vs Asynchronous Open**:
- Choose synchronous open for simplicity
- Open is a one-time operation
- Asynchronous open adds complexity with minimal benefit
- Future: Consider async open for embedded async runtimes

**Eager vs Lazy Loading**:
- Choose eager loading for all components
- Pager, WAL, B+Tree, SnapshotRegistry all initialized during open
- Ensures database is fully operational before returning handle
- Tradeoff: Slower open vs immediate failures

**Strict vs Lenient Recovery**:
- Choose lenient recovery (skip corrupted records)
- Replay as much as possible
- Skip corrupted records with warnings
- Tradeoff: Potential data loss vs better recovery odds

### Implementation Notes

**Step 1: Configuration Validation**
- Validate in builder.build() before calling open_internal()
- Return Err(ConfigError) immediately on validation failure
- Provide detailed error messages for each validation rule

**Step 2: Path Resolution**
- Canonicalize path to absolute path
- Create parent directories with fs::create_dir_all()
- Handle race conditions (directory created by another process)

**Step 3: File Lock Acquisition**
- Use fs2::FileLock for cross-platform locking
- Create .lock file adjacent to database file
- Acquire exclusive lock with try_lock() (non-blocking)
- Return DatabaseInUse error immediately if lock held

**Step 4: File Handle Creation**
- Use std::fs::OpenOptions for cross-platform opening
- Open with read-write permissions
- Create file if not exists
- Set file permissions to 0600 (owner read-write only)

**Step 5: Database State Detection**
- Check file size with fs::metadata()
- Read FileHeader from first page
- Validate magic and version
- Check meta page A/B for current state
- Determine if new/clean/dirty shutdown

**Step 6: Component Initialization**
- Initialize components in dependency order:
  1. Pager (foundation)
  2. WAL (recovery)
  3. B+Tree (needs Pager)
  4. SnapshotRegistry (needs B+Tree roots)
- Each initialization may fail independently

**Step 7: Recovery (if needed)**
- Call Wal::recover() to scan WAL
- Collect commit records
- Replay mutations in LSN order
- Update B+Tree and SnapshotRegistry
- Truncate WAL after successful replay

**Step 8: Assembly**
- Create DbInner with all components
- Wrap in Arc<RwLock<>>
- Create Db handle
- Return Ok(Db)

### Testing Strategy

**Unit tests needed for**:
- Configuration validation (all invalid configurations)
- Path resolution and canonicalization
- File lock acquisition and release
- File handle creation (new and existing files)
- Database state detection (new, clean, dirty)
- Pager initialization (new and existing)
- WAL initialization (empty and non-empty)
- B+Tree initialization (empty and loaded)
- SnapshotRegistry initialization (genesis and loaded)
- Component assembly and Db creation

**Integration tests needed for**:
- Open new database
- Open existing database (clean shutdown)
- Open existing database (dirty shutdown, recovery)
- Open with corrupted database (error handling)
- Open with file lock held (DatabaseInUse error)
- Open with invalid configuration (ConfigError)
- Concurrent open attempts (only one succeeds)

**Property tests needed for**:
- Recovery preserves all committed transactions
- Recovery results in consistent database state
- Open is idempotent (close and reopen yields same state)
- File lock prevents concurrent opens

**Hardening tests needed for**:
- Crash during open (partial initialization)
- Corrupted file header
- Corrupted meta pages
- Corrupted WAL
- Disk full during open
- Permission denied during open
