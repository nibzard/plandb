# Db Struct and Builder Pattern

## Purpose

This document describes the internal structure of the Db type, the builder pattern for database construction, and the field-by-field breakdown of all components that constitute a running database instance. The Db struct serves as the central coordinator for all database operations, managing the lifecycle and coordination of Pager, WAL, B+Tree, SnapshotRegistry, and configuration.

## Db Struct Fields

### DbInner

**Description**: Internal state of the database, protected by RwLock for concurrent access

**Purpose**: Contains all mutable and immutable state required for database operations. Wrapped in Arc<RwLock<>> to allow thread-safe shared access across multiple database handles.

**Fields**:

**config: Config**
- Type: Config (immutable, owned)
- Purpose: Stores database configuration parameters
- Invariants: Validated and immutable after database open
- Size: ~128 bytes (all config options)
- Access: Read-only after initialization

**pager: Pager**
- Type: Arc<Pager>
- Purpose: Manages page allocation, I/O, and caching
- Invariants: Initialized with valid file handle, cache configured
- Lifetime: Entire database lifetime
- Coordination: Db calls pager methods, Pager triggers WAL flushes

**wal: Wal**
- Type: Arc<Wal>
- Purpose: Write-ahead log for transaction durability
- Invariants: Open with valid file handle, recovery complete
- Lifetime: Entire database lifetime
- Coordination: Transaction commits append to WAL, WAL triggers Pager flushes

**btree: BTree**
- Type: BTree
- Purpose: Ordered key-value storage structure
- Invariants: Valid root page ID, tree structure consistent
- Lifetime: Entire database lifetime
- Coordination: Uses Pager for I/O, receives root page ID from SnapshotRegistry

**snapshot_registry: SnapshotRegistry**
- Type: Arc<RwLock<SnapshotRegistry>>
- Purpose: Tracks transaction IDs to root page ID mappings for MVCC
- Invariants: Genesis snapshot (txn_id 0) always present
- Lifetime: Entire database lifetime
- Coordination: Updated on commit, queried on transaction begin

**current_txn_id: AtomicU64**
- Type: std::sync::atomic::AtomicU64
- Purpose: Monotonically increasing transaction ID counter
- Invariants: Starts at 1, increments on each transaction begin
- Access: Lock-free atomic operations (fetch_add)
- Coordination: Provides unique IDs for WriteTxn and ReadTxn

**current_root_page_id: AtomicU64**
- Type: std::sync::atomic::AtomicU64
- Purpose: Tracks the current (latest) B+Tree root page ID
- Invariants: Updated atomically on commit, always valid
- Access: Lock-free atomic operations (load, store)
- Coordination: Updated by WriteTxn commit, read by ReadTxn begin

**write_lock: Mutex<()>**
- Type: Mutex<()> (empty value, used only for locking)
- Purpose: Ensures only one WriteTxn at a time
- Invariants: Locked by active WriteTxn, unlocked otherwise
- Coordination: begin_write() acquires, commit/rollback releases
- Why Mutex over RwLock: Only one writer, no read capability needed

**stats: DbStats**
- Type: Arc<RwLock<DbStats>>
- Purpose: Collects and exposes database statistics
- Invariants: Thread-safe access via RwLock
- Coordination: Updated by various operations, queried by stats() method

**is_open: AtomicBool**
- Type: std::sync::atomic::AtomicBool
- Purpose: Tracks database open/closed state
- Invariants: true when open, false when closed
- Coordination: Set to false on close, checked before operations

**file_lock: Option<FileLock>**
- Type: Option<platform-specific file lock type>
- Purpose: Ensures single-process access to database file
- Invariants: Some(lock) when open, None when closed
- Coordination: Acquired on open, released on close
- Platform-specific: flock on Unix, LockFileEx on Windows

### Db

**Description**: Public-facing database handle, wraps Arc<RwLock<DbInner>>

**Purpose**: Provides thread-safe, reference-counted handle to database internals. Clone is cheap (Arc::clone), allowing multiple handles to the same database.

**Fields**:

**inner: Arc<RwLock<DbInner>>**
- Type: Arc<RwLock<DbInner>>
- Purpose: Shared ownership of database state with interior mutability
- Invariants: Always valid for lifetime of Db handle
- Thread-safety: Send + Sync derived from Arc<RwLock<T>>
- Clone behavior: Arc::clone increments reference count

**path: PathBuf**
- Type: std::path::PathBuf
- Purpose: Stores path to database file for diagnostics and locking
- Invariants: Valid filesystem path, immutable after open
- Usage: Error messages, file lock acquisition, recovery

**Size**: Approximately 48 bytes for Arc pointer + path overhead

**Traits**:
- Clone: Increments Arc reference count (cheap)
- Send + Sync: Thread-safe for concurrent access
- Debug: Display database path and state

## Builder Pattern

### DbBuilder

**Description**: Builder type for fluent database configuration

**Purpose**: Provides type-safe, ergonomic configuration API with validation and sensible defaults.

**Fields**:

**config: Config**
- Type: Config
- Purpose: Accumulates configuration options
- Default: Config::default() provides sensible defaults
- Validation: Occurs in build() method

**path: Option<PathBuf>**
- Type: Option<std::path::PathBuf>
- Purpose: Stores database file path
- Default: None (must be set via path() method)
- Validation: Must be Some before build()

### Builder Methods

**pub fn new() -> Self**
- Purpose: Create new builder with default configuration
- Returns: DbBuilder instance
- Default config: Applied automatically
- Example: Db::builder().path("db.ndb").build()

**pub fn path<P: AsRef<Path>>(mut self, path: P) -> Self**
- Purpose: Set database file path
- Parameter: path - Path to database file (implements AsRef<Path>)
- Returns: Self for chaining
- Validation: Deferred until build()
- Example: .path("/data/mydb.ndb")

**pub fn cache_size(mut self, size: usize) -> Self**
- Purpose: Set page cache size in number of pages
- Parameter: size - Number of pages to cache
- Returns: Self for chaining
- Default: 1024 pages (16MB with 16KB pages)
- Validation: Must be power of 2, >= 16
- Example: .cache_size(2048) // 32MB cache

**pub fn page_size(mut self, size: usize) -> Self**
- Purpose: Set database page size
- Parameter: size - Page size in bytes
- Returns: Self for chaining
- Default: 16384 (16KB)
- Validation: Must be power of 2, between 4096 and 65536
- Constraints: Cannot change after database created
- Example: .page_size(32768) // 32KB pages

**pub fn wal_size_threshold(mut self, size: u64) -> Self**
- Purpose: Set WAL size threshold for automatic checkpoint
- Parameter: size - WAL size in bytes
- Returns: Self for chaining
- Default: 100MB
- Validation: Must be >= 1MB
- Effect: Checkpoint triggered when WAL exceeds this size
- Example: .wal_size_threshold(50_000_000) // 50MB

**pub fn flush_policy(mut self, policy: FlushPolicy) -> Self**
- Purpose: Set WAL flush policy
- Parameter: policy - FlushPolicy enum variant
- Returns: Self for chaining
- Default: FlushPolicy::Batch
- Options: Immediate (every write), Batch (buffer then flush), Periodic (time-based)
- Example: .flush_policy(FlushPolicy::Immediate)

**pub fn snapshot_retention(mut self, policy: RetentionPolicy) -> Self**
- Purpose: Set snapshot retention policy for garbage collection
- Parameter: policy - RetentionPolicy enum variant
- Returns: Self for chaining
- Default: RetentionPolicy::CountBased { min_keep: 100 }
- Options: CountBased, AgeBased, Hybrid, Manual
- Example: .snapshot_retention(RetentionPolicy::AgeBased { max_age_seconds: 3600 })

**pub fn auto_checkpoint(mut self, enabled: bool) -> Self**
- Purpose: Enable or disable automatic checkpointing
- Parameter: enabled - true to enable, false to disable
- Returns: Self for chaining
- Default: true
- Effect: When true, checkpoint triggered by WAL size threshold
- Example: .auto_checkpoint(false) // Manual checkpoint only

**pub fn compression(mut self, algo: Compression) -> Self**
- Purpose: Set compression algorithm for values
- Parameter: algo - Compression enum variant
- Returns: Self for chaining
- Default: Compression::None
- Options: None, Lz4, Zstd, Snappy
- Effect: Compresses values before storage, decompresses on read
- Example: .compression(Compression::Lz4)

**pub fn build(self) -> Result<Db, Error>**
- Purpose: Build and open database with configured options
- Returns: Ok(Db) on success, Err(Error) on failure
- Validation steps:
  1. Path is set (None → ConfigError)
  2. Cache size is power of 2 and >= 16
  3. Page size is power of 2 and in valid range
  4. WAL size threshold is >= 1MB
  5. Flush policy is compatible with configuration
  6. Snapshot retention policy is valid
  7. Compression algorithm is available
- Open steps:
  1. Acquire exclusive file lock
  2. Open database file (create if not exists)
  3. Open WAL file
  4. Initialize Pager with file handle and page size
  5. Initialize WAL with recovery mode
  6. Replay WAL if needed
  7. Initialize B+Tree with root page ID from meta page
  8. Initialize SnapshotRegistry from persisted state
  9. Initialize DbInner with all components
  10. Wrap in Arc<RwLock<>>
  11. Return Db handle
- Error conditions:
  - Path not set: ConfigError
  - File lock held by another process: DatabaseInUse
  - Permission denied: IoError
  - Corrupted database: CorruptedData
  - Recovery failed: RecoveryError

## Helper Types

### Config

**Description**: Immutable configuration container

**Fields**:
- cache_size: usize (default: 1024)
- page_size: usize (default: 16384)
- wal_size_threshold: u64 (default: 100_000_000)
- flush_policy: FlushPolicy (default: Batch)
- snapshot_retention: RetentionPolicy (default: CountBased { min_keep: 100 })
- auto_checkpoint: bool (default: true)
- compression: Compression (default: None)

**Validation**:
- cache_size: power of 2, >= 16
- page_size: power of 2, 4096-65536
- wal_size_threshold: >= 1_048_576 (1MB)
- flush_policy: valid variant
- snapshot_retention: valid variant with sensible parameters
- compression: available at compile-time

### FlushPolicy

**Description**: WAL flush strategy

**Variants**:
- Immediate: Flush every WAL append (maximum durability, minimum throughput)
- Batch { max_batch_ms: u64 }: Buffer up to max_batch_ms milliseconds (balanced)
- Periodic { interval_ms: u64 }: Flush every interval_ms milliseconds (maximum throughput)

### RetentionPolicy

**Description**: Snapshot garbage collection policy

**Variants**:
- CountBased { min_keep: usize }: Keep at least min_keep snapshots
- AgeBased { max_age_seconds: u64 }: Keep snapshots newer than max_age_seconds
- Hybrid { min_keep: usize, max_age_seconds: u64 }: Keep at least min_keep and newer than max_age
- Manual: No automatic cleanup, user triggers manually

### Compression

**Description**: Value compression algorithm

**Variants**:
- None: No compression
- Lz4: LZ4 fast compression (compile-time feature flag)
- Zstd: Zstandard compression (compile-time feature flag)
- Snappy: Snappy compression (compile-time feature flag)

### DbStats

**Description**: Database statistics

**Fields**:
- cache_hits: u64 (number of cache hits)
- cache_misses: u64 (number of cache misses)
- transactions_committed: u64 (total committed transactions)
- transactions_rolled_back: u64 (total rolled back transactions)
- wal_size_bytes: u64 (current WAL file size)
- wal_flushes: u64 (number of WAL flushes)
- btree_height: u32 (current B+Tree height)
- btree_nodes: u64 (total B+Tree nodes)
- snapshot_count: u64 (current snapshot count)
- active_readers: u32 (current active read transactions)
- active_writer: bool (is a write transaction active?)

## Db Methods

### Construction

**pub fn builder() -> DbBuilder**
- Purpose: Create builder for database configuration
- Returns: DbBuilder with default configuration
- Example: let db = Db::builder().path("db.ndb").build()?

**pub fn open<P: AsRef<Path>>(path: P) -> Result<Db, Error>**
- Purpose: Open database with default configuration
- Parameter: path - Path to database file
- Returns: Ok(Db) on success, Err(Error) on failure
- Convenience method for Db::builder().path(path).build()

**pub fn open_with_config<P: AsRef<Path>>(path: P, config: Config) -> Result<Db, Error>**
- Purpose: Open database with explicit configuration
- Parameter: path - Path to database file
- Parameter: config - Pre-built Config
- Returns: Ok(Db) on success, Err(Error) on failure
- Use case: Reusing configuration across multiple databases

### Transaction Creation

**pub fn begin_read(&self) -> Result<ReadTxn, Error>**
- Purpose: Create read transaction on latest snapshot
- Returns: ReadTxn capturing current database state
- Lock acquisition: Shared lock on DbInner (fast, concurrent)
- Error conditions: DatabaseClosed, LockTimeout
- Example: let txn = db.begin_read()?
- See: 07-db-read.md for detailed ReadTxn specification

**pub fn begin_read_at(&self, txn_id: TransactionId) -> Result<ReadTxn, Error>**
- Purpose: Create read transaction at historical snapshot
- Parameter: txn_id - Transaction ID to read from
- Returns: ReadTxn capturing state at txn_id
- Lock acquisition: Shared lock on DbInner
- Error conditions: DatabaseClosed, SnapshotNotFound (if txn_id not in registry)
- Use case: Time-travel queries, historical analysis
- Example: let txn = db.begin_read_at(old_txn_id)?
- See: 07-db-read.md for detailed ReadTxn specification

**pub fn begin_write(&self) -> Result<WriteTxn, Error>**
- Purpose: Create write transaction
- Returns: WriteTxn with exclusive write access
- Lock acquisition: Exclusive lock on DbInner (blocks until current writer finishes)
- Error conditions: DatabaseClosed, LockTimeout
- Blocking behavior: Waits until current WriteTxn commits/rolls back
- Example: let mut txn = db.begin_write()?
- See: 07-db-write.md for detailed WriteTxn specification

### Database Operations

**pub fn checkpoint(&self) -> Result<(), Error>**
- Purpose: Trigger manual checkpoint
- Operation: Flush dirty pages, truncate WAL, update meta page
- Lock acquisition: Exclusive lock (blocks all operations)
- Error conditions: DatabaseClosed, IoError, ChecksumError
- Use case: Explicit checkpoint before backup, shutdown
- Example: db.checkpoint()?
- See: 02-pager-flush.md for detailed checkpoint specification

**pub fn close(&self) -> Result<(), Error>**
- Purpose: Explicitly close database
- Operation: Flush any pending changes, release file lock, close handles
- Lock acquisition: Exclusive lock
- Idempotent: Multiple calls safe (subsequent calls are no-ops)
- Error conditions: IoError during flush
- Cleanup: Sets is_open to false, releases resources
- Example: db.close()?
- Note: Drop trait also calls close automatically

**pub fn stats(&self) -> DbStats**
- Purpose: Get current database statistics
- Returns: DbStats copy
- Lock acquisition: Shared lock for reading
- Example: let stats = db.stats(); println!("Cache hit rate: {:.2}%", stats.cache_hit_rate())
- Thread-safety: Safe to call concurrently with other operations

### Clone and Drop

**pub fn clone(&self) -> Db**
- Purpose: Create new handle to same database
- Returns: New Db handle (Arc::clone of inner)
- Cost: Cheap (atomic increment of reference count)
- Use case: Share database across threads
- Example: let db2 = db.clone();
- Note: Both handles refer to same database state

**pub fn drop(&mut self)**
- Purpose: Cleanup when last handle dropped
- Operation: Calls close() if not already closed
- Idempotent: Safe to drop already-closed database
- Blocking: Waits for in-flight operations to complete
- Resource release: File handles, locks, memory
- Note: Implicitly called when Db goes out of scope

## Invariants

### Db Invariants

1. **Valid Inner State**: DbInner is always valid when Db exists
   - All components (Pager, WAL, B+Tree, SnapshotRegistry) initialized
   - Configuration is validated
   - File lock is held

2. **Open State**: is_open reflects actual database state
   - true: Database is open and operational
   - false: Database is closed, operations return DatabaseClosed error
   - Transition only from true to false (never reopen)

3. **Exclusive File Lock**: Only one Db instance per database file
   - File lock acquired on open
   - Second open attempt fails with DatabaseInUse
   - Lock released on close

4. **Atomic Root Page ID**: current_root_page_id updated atomically
   - Written only by WriteTxn commit
   - Read by ReadTxn begin
   - Atomic operations prevent torn reads

5. **Monotonic Transaction IDs**: current_txn_id increments atomically
   - Starts at 1 (0 reserved for genesis snapshot)
   - Increment on each transaction begin
   - Never decreases or repeats

6. **Single Writer**: write_lock ensures only one WriteTxn
   - begin_write() acquires Mutex
   - commit/rollback releases Mutex
   - begin_write() blocks until Mutex available

### DbBuilder Invariants

1. **Path Required**: path must be Some before build()
   - build() returns ConfigError if path is None
   - Enforced at build time, not construction time

2. **Valid Configuration**: All config options validated at build()
   - cache_size: power of 2, >= 16
   - page_size: power of 2, 4096-65536
   - wal_size_threshold: >= 1MB
   - Other options validated for consistency

3. **Immutable After Build**: Builder consumed by build()
   - Cannot reuse builder after build()
   - Prevents accidental misconfiguration

## Dependencies

### Db Uses

- **Pager**: Page I/O, allocation, caching
- **Wal**: Write-ahead log, commit records, recovery
- **BTree**: Key-value storage, search, insert, delete
- **SnapshotRegistry**: Transaction ID to root page ID mapping
- **Config**: Configuration storage and validation
- **Error**: Error types for all operations

### Db Used By

- **ReadTxn**: Borrows Db for snapshot and operations
- **WriteTxn**: Borrows Db exclusively for mutations
- **Application Code**: Creates and clones Db handles for database operations

## Rust Implementation Guidance

### Module Structure

```
northstar-core/src/db/
├── mod.rs          # Db, DbBuilder, DbInner definitions
├── config.rs       # Config, FlushPolicy, RetentionPolicy, Compression
├── stats.rs        # DbStats and statistics collection
└── error.rs        # Db-specific error variants
```

### Type Definitions

**DbInner**: Should be private struct with public fields
- All components as Arc<> for shared ownership
- Atomic types for lock-free counters
- RwLock and Mutex for synchronization
- pub(crate) visibility for testing

**Db**: Should be public struct with private inner field
- Wraps Arc<RwLock<DbInner>>
- Derives Clone for cheap handle duplication
- Implements Send + Sync

**DbBuilder**: Should be public struct with builder methods
- Consumes self in each setter for chaining
- build() consumes self
- Validates configuration in build(), not setters

### Concurrency

**Lock Ordering** (to avoid deadlock):
1. DbInner RwLock (outermost)
2. write_lock Mutex (for WriteTxn)
3. Pager internal locks
4. WAL internal locks
5. SnapshotRegistry RwLock

**Lock Strategy**:
- begin_read(): Shared lock on DbInner (fast)
- begin_write(): Exclusive lock on DbInner + write_lock Mutex (blocking)
- stats(): Shared lock on DbInner (fast)
- checkpoint(): Exclusive lock on DbInner (blocks all)
- close(): Exclusive lock on DbInner (blocks all)

### Key Decisions

**Arc<RwLock<DbInner>> vs Arc<Mutex<DbInner>>**:
- Choose RwLock because reads are frequent
- Multiple readers can proceed concurrently
- Writers are rare, exclusive lock acceptable
- Tradeoff: RwLock overhead vs Mutex simplicity

**AtomicU64 for counters vs protected by lock**:
- Choose AtomicU64 for txn_id and root_page_id
- Lock-free reads and writes
- Avoids lock contention on hot path
- Tradeoff: Atomic operations cost vs mutex overhead

**Mutex<()> for write_lock vs RwLock<()>**:
- Choose Mutex because only exclusive access needed
- Simpler than RwLock for single-writer case
- No readers of write_lock
- Tradeoff: Mutex simplicity vs RwLock flexibility

### Implementation Notes

**Step 1: Builder Construction**
- Create DbBuilder with default Config
- Store None for path (must be set)
- All other fields from Config::default()

**Step 2: Builder Configuration**
- Each setter consumes and returns Self
- Store values in Config fields
- No validation in setters (deferred to build())
- Allow fluent chaining: .cache_size(2048).page_size(32768)

**Step 3: Builder Validation**
- Validate all fields in build()
- Return ConfigError with details on validation failure
- Clear error messages for each validation rule
- Check path is Some before any other validation

**Step 4: Database Open**
- Acquire exclusive file lock on database file
- Open database file (create if not exists, open existing otherwise)
- Open WAL file
- Initialize Pager with file handle and page size from config
- Initialize WAL with WAL file, recovery mode
- Replay WAL if recovery needed
- Get root page ID from Pager meta page or initialize new tree
- Initialize SnapshotRegistry (load from disk or create genesis)
- Initialize DbInner with all components
- Wrap in Arc<RwLock<>>
- Create Db handle and return Ok(Db)

**Step 5: Transaction Begin**
- ReadTxn: Acquire shared lock on DbInner, capture current_root_page_id, create ReadTxn
- WriteTxn: Acquire exclusive lock on DbInner, acquire write_lock, allocate txn_id, create WriteTxn
- Both: Store Arc<Db> clone in transaction for lifetime management

**Step 6: Database Close**
- Acquire exclusive lock on DbInner
- Set is_open to false
- Flush any pending changes
- Release file lock
- Close file handles
- Drop components (Pager, WAL, etc.)
- Return Ok(())

### Testing Strategy

**Unit tests needed for**:
- DbBuilder with valid configuration
- DbBuilder with invalid configuration (all validation rules)
- Db::open with new database
- Db::open with existing database
- Db::open with corrupted database
- Db::open with file lock held by another process
- Db.clone() creates independent handle
- Db.drop() calls close()
- Db.begin_read() creates ReadTxn
- Db.begin_write() creates WriteTxn (blocks if writer active)
- Db.checkpoint() triggers checkpoint
- Db.stats() returns current statistics
- Db.close() is idempotent

**Property tests for**:
- Builder validation covers all invalid configurations
- Multiple Db handles refer to same database
- begin_read() proceeds concurrently
- begin_write() blocks until current writer finishes
- close() prevents further operations
- File lock prevents concurrent opens

**Integration scenarios**:
- Open database, perform operations, close, reopen, verify persistence
- Builder configuration affects database behavior (cache size, page size)
- Multiple threads using cloned Db handles
- Checkpoint reduces WAL size
- Stats reflect actual database activity
