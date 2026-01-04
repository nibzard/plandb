# Public API Overview

## Purpose

The Public API layer provides the user-facing interface for NorthstarDB, exposing a clean, safe, and ergonomic API for database operations while hiding the complexity of the underlying storage, transaction, MVCC, and B+Tree systems. This layer is responsible for database lifecycle management (open, close), transaction creation (read and write), configuration management, and error handling. It serves as the single entry point for all database operations, ensuring consistent behavior and proper resource management across the entire system.

## API Design Philosophy

### Safety First

**Thread Safety Guarantees**: The database handle can be safely shared across threads
- Db implements Send + Sync, allowing concurrent access from multiple threads
- Read transactions implement Send + Sync, enabling parallel read operations
- Write transactions are !Send, enforcing single-threaded mutation
- All internal state protected by appropriate locks (RwLock, Mutex)
- No data races possible through the public API

**Lifetime Safety**: Rust's ownership system ensures proper resource cleanup
- Db owns all resources (file handles, memory, locks)
- Transactions borrow from Db, preventing use-after-close
- RAII pattern ensures automatic cleanup on scope exit
- No dangling pointers or use-after-free possible

**Error Handling**: All errors are explicit and recoverable
- Result<T, E> for all fallible operations
- No panics in the public API (except for programmer errors)
- Detailed error context for debugging
- Clear error recovery strategies documented

### Ergonomics

**Builder Pattern**: Configuration via fluent, type-safe API
- Db::builder() returns builder with chainable configuration methods
- Compile-time validation of configuration options
- Sensible defaults for all options
- Clear error messages for invalid configurations

**Transaction API**: Intuitive and familiar interface
- db.begin_read() for read-only transactions
- db.begin_write() for read-write transactions
- Transaction scopes via Rust blocks or explicit commit/rollback
- Read-your-writes semantics for write transactions

**Zero-Copy Where Possible**: Minimize allocations and copies
- Read operations return views into shared memory (Arc<[u8]>)
- Keys and values borrowed when possible
- Efficient range iteration via Iterator trait
- Batch operations to reduce overhead

### Performance Transparency

**Predictable Performance**: Consistent and documented performance characteristics
- O(log n) for point operations (get, put, delete)
- O(log n + k) for range scans (k = number of results)
- No hidden allocations or locks on hot paths
- Documented worst-case scenarios

**Configuration Tuning**: Expose performance knobs for advanced users
- Cache size configuration
- Page size selection
- WAL flush policy
- Snapshot retention policy

## User-Facing Types

### Db

**Description**: Main database handle representing an open database instance

**Responsibilities**:
- Database lifecycle management (open, close)
- Transaction creation (read and write)
- Configuration storage and validation
- Resource coordination (Pager, WAL, B+Tree, SnapshotRegistry)
- Statistics and monitoring

**Key Characteristics**:
- Thread-safe: Send + Sync
- Reference counted: Arc<Db> shared across threads
- Cloneable: Cheap handle duplication (Arc::clone)
- Not copyable: Explicit clone required
- Owned resources: File handles, memory, locks

**Public Interface**:
- Db::builder() - Create builder for configuration
- Db::open(path) - Open database with default configuration
- Db::open_with_config(path, config) - Open database with custom configuration
- db.begin_read() - Create read transaction (latest snapshot)
- db.begin_read_at(txn_id) - Create read transaction at historical snapshot
- db.begin_write() - Create write transaction
- db.close() - Explicit close (optional, Drop handles it)
- db.stats() - Get database statistics
- db.checkpoint() - Trigger manual checkpoint

### ReadTxn<'db>

**Description**: Read-only transaction with consistent snapshot view

**Responsibilities**:
- Snapshot capture and validation
- Read operation execution (get, scan)
- Snapshot isolation enforcement
- Resource cleanup on drop

**Key Characteristics**:
- Read-only: No mutation operations
- Snapshot isolation: Consistent view as of transaction start
- Thread-safe: Send + Sync (can move across threads)
- Non-blocking: Multiple readers proceed concurrently
- Borrowed from Db: Lifetime 'db ensures no use-after-close

**Public Interface**:
- txn.get(key) - Get value for key
- txn.scan(start, end) - Iterate over key range
- txn.commit() - Explicit release (optional)
- txn.rollback() - Explicit rollback (no-op for read txn)
- txn.id() - Get transaction ID
- txn.snapshot_lsn() - Get snapshot LSN

### WriteTxn<'db>

**Description**: Read-write transaction with mutation tracking and two-phase commit

**Responsibilities**:
- Mutation tracking (put, delete)
- Read-your-writes enforcement
- Conflict detection
- Two-phase commit coordination
- Rollback on error

**Key Characteristics**:
- Read-write: Supports get, scan, put, delete
- Exclusive write access: Only one write transaction at a time
- Not thread-safe: !Send (must remain on creating thread)
- Mutation buffering: Changes in memory until commit
- Two-phase commit: WAL → B+Tree → Meta page

**Public Interface**:
- txn.get(key) - Get value for key (sees own writes)
- txn.scan(start, end) - Iterate over key range
- txn.put(key, value) - Insert or update key-value pair
- txn.delete(key) - Delete key
- txn.commit() - Commit transaction
- txn.rollback() - Rollback transaction
- txn.id() - Get transaction ID
- txn.mutation_count() - Get number of pending mutations

### Config

**Description**: Database configuration options

**Responsibilities**:
- Store all configuration parameters
- Validate configuration consistency
- Provide sensible defaults
- Enable configuration serialization

**Key Characteristics**:
- Builder pattern for construction
- Compile-time and runtime validation
- Immutable after creation
- Cloneable for reuse

**Configuration Options**:
- Cache size (number of pages to cache)
- Page size (power of 2, 4KB-64KB)
- WAL size threshold (when to trigger checkpoint)
- Flush policy (immediate, batch, periodic)
- Snapshot retention (count-based or age-based)
- Auto checkpoint (enable/disable)
- Compression algorithm (none, lz4, zstd)

### Error

**Description**: Comprehensive error types for all failure modes

**Responsibilities**:
- Categorize all error conditions
- Provide detailed error context
- Enable error recovery strategies
- Support error logging and debugging

**Key Characteristics**:
- Structured errors with thiserror
- Error chaining for context
- Display and Debug implementations
- Downcasting for specific error handling

**Error Categories**:
- IoError: File I/O failures
- CorruptedData: Checksum failures, invalid data
- TransactionError: Transaction conflicts, validation failures
- ConfigError: Invalid configuration
- ResourceError: Out of memory, file handle exhaustion
- NotFoundError: Key not found, snapshot not found

### Stats

**Description**: Database statistics and monitoring information

**Responsibilities**:
- Track database metrics
- Provide performance insights
- Support health monitoring
- Enable capacity planning

**Key Metrics**:
- Cache hit rate
- Transaction throughput
- WAL size and flush rate
- B+Tree statistics (height, node count)
- Snapshot count and retention

## API Usage Patterns

### Basic Database Operations

**Opening a Database**:
```
1. Call Db::builder() to get builder
2. Chain configuration methods (optional)
3. Call build() to create Db handle
4. Handle potential errors (file not found, corrupted, permission denied)
```

**Reading Data**:
```
1. Call db.begin_read() to get ReadTxn
2. Call txn.get(key) or txn.scan(start, end)
3. Use returned values
4. Let txn drop (implicit close) or call txn.commit()
```

**Writing Data**:
```
1. Call db.begin_write() to get WriteTxn (blocks if writer active)
2. Perform mutations (txn.put, txn.delete)
3. Read own writes via txn.get, txn.scan
4. Call txn.commit() to persist or txn.rollback() to abort
5. Handle commit errors (conflict, I/O failure)
```

### Error Handling Patterns

**Recoverable Errors**:
- IoError: Retry or abort operation
- TransactionError: Retry transaction
- NotFoundError: Handle missing data gracefully
- ResourceError: Retry after backoff or reduce workload

**Fatal Errors**:
- CorruptedData: Database recovery required
- ConfigError: Fix configuration and restart
- Panic: Programmer error (bug in application)

### Concurrent Access Patterns

**Multiple Readers**:
- Create ReadTxn on multiple threads
- All readers proceed concurrently
- Each reader sees consistent snapshot
- No blocking between readers

**Single Writer**:
- Only one WriteTxn at a time
- begin_write() blocks until current writer finishes
- Writer proceeds without read interference
- Readers see snapshot from before writer start

**Mixed Workload**:
- Readers can run while writer is active
- Readers see pre-writer snapshot
- Writer commits atomically
- New readers see post-commit snapshot

## Integration Points

### With Pager

**Db uses Pager for**:
- Page allocation and deallocation
- Page I/O through cache
- Checkpoint coordination
- File handle management

**Db provides Pager with**:
- Cache size configuration
- Page size configuration
- Flush policy parameters
- Checkpoint trigger conditions

### With WAL

**Db uses WAL for**:
- Transaction commit records
- Crash recovery
- Log truncation coordination
- LSN allocation

**Db provides WAL with**:
- File path for WAL storage
- Flush policy configuration
- Size threshold for checkpointing
- Recovery mode on startup

### With B+Tree

**Db uses B+Tree for**:
- Key-value storage and retrieval
- Range scan operations
- Tree growth and shrink
- Root page ID tracking

**Db provides B+Tree with**:
- Page allocation through Pager
- Snapshot root page IDs
- Transaction context for operations
- Configuration parameters

### With SnapshotRegistry

**Db uses SnapshotRegistry for**:
- Tracking committed transactions
- Mapping transaction IDs to root page IDs
- Snapshot cleanup and retention
- Statistics and monitoring

**Db provides SnapshotRegistry with**:
- Registration calls on commit
- Cleanup trigger based on policy
- Configuration for retention
- Statistics aggregation

## Invariants

### Database-Level Invariants

1. **Single Database Instance**: Only one Db instance open per database file at a time
   - Enforced by file locking (exclusive lock on open)
   - Prevents concurrent modifications from multiple processes
   - Second open attempt fails with DatabaseInUse error

2. **Valid State**: Database is always in a valid state
   - All invariants satisfied after recovery completes
   - No partial commits visible to transactions
   - Checksums valid for all pages
   - B+Tree structure consistent

3. **Atomic Transitions**: State changes are atomic
   - Commit atomic via WAL
   - Rollback atomic via discard
   - Checkpoint atomic via meta page flip
   - Recovery atomic via WAL replay

### Transaction-Level Invariants

1. **Snapshot Isolation**: Readers see consistent snapshot
   - ReadTxn sees state as of snapshot LSN
   - No dirty reads from uncommitted transactions
   - No non-repeatable reads within transaction
   - Snapshot captured at transaction begin

2. **Write Serialization**: Only one writer at a time
   - Only one WriteTxn active at any time
   - begin_write() blocks until current writer commits/rolls back
   - Writer sees its own mutations (read-your-writes)
   - Mutations invisible to other transactions until commit

3. **Atomic Commit**: All mutations or none
   - Either all mutations persist or none do
   - Commit atomic via two-phase commit
   - Crash before commit → transaction not applied
   - Crash during commit → replay completes or aborts

### Resource Management Invariants

1. **No Resource Leaks**: All resources properly cleaned up
   - File handles closed on Db drop
   - Locks released on transaction drop
   - Memory freed when references dropped
   - WAL truncated after checkpoint

2. **Proper Ordering**: Operations happen in correct order
   - WAL flushed before B+Tree modified
   - Meta page flushed last
   - Locks acquired in consistent order
   - Resources released in reverse order

## Rust Implementation Guidance

### Module Structure

The public API module should be organized as follows:
```
northstar-core/
├── lib.rs              # Public API exports
├── db/
│   ├── mod.rs          # Db struct and lifecycle
│   ├── config.rs       # Config type and builder
│   ├── stats.rs        # Stats type and collectors
│   └── error.rs        # Error types and conversions
└── txn/
    ├── mod.rs          # Transaction traits and common types
    ├── read.rs         # ReadTxn implementation
    └── write.rs        # WriteTxn implementation
```

### Type Definitions

**Db**: Should use Arc for interior mutability
- Fields: Arc<RwLock<DbInner>> for concurrent access
- DbInner contains Pager, WAL, B+Tree, SnapshotRegistry
- Clone is cheap (Arc::clone)
- Send + Sync derived from Arc<RwLock<T>>

**ReadTxn**: Should borrow from Db
- Lifetime parameter 'db tied to Db borrow
- Fields: Arc<Db> (to keep Db alive), Snapshot LSN
- Send + Sync derived from Arc<Db>
- Iterator types for scan operations

**WriteTxn**: Should borrow from Db exclusively
- Lifetime parameter 'db tied to Db borrow
- Fields: Arc<Db>, WriteGuard, MutationBuffer
- !Send to enforce single-threaded access
- PhantomData to ensure lifetime correctness

**Config**: Should use builder pattern
- Struct with private fields
- Builder type with fluent API
- Default implementation
- Validation in builder.build()

**Error**: Should use thiserror
- Enum with variants for each error type
- #[source] attributes for error chaining
- Display implementations with helpful messages
- From implementations for std::io::Error

### Concurrency

**Db Concurrency**:
- Use RwLock<DbInner> for read-write locking
- Readers acquire shared lock (fast, concurrent)
- Writer acquires exclusive lock (blocks readers/writers)
- Interior mutability via Arc<RwLock<T>>
- Lock ordering: Pager → WAL → B+Tree → Registry (avoid deadlock)

**ReadTxn Concurrency**:
- No locks needed for read operations
- Snapshot provides immutable view
- Multiple ReadTxn can proceed concurrently
- Send + Sync allows cross-thread usage

**WriteTxn Concurrency**:
- Acquires exclusive write lock on begin_write()
- Holds lock until commit/rollback completes
- !Send ensures single-threaded access
- Mutation buffer local to transaction

### Key Decisions

**Arc<RwLock<DbInner>> vs Mutex<DbInner>**:
- Choose RwLock<DbInner> because reads are frequent
- Multiple readers can proceed concurrently
- Writers are rare, exclusive lock acceptable
- Tradeoff: Reader-writer lock overhead vs mutex contention

**Arc<Db> vs &'db Db for transactions**:
- Choose Arc<Db> because transactions need owned handle
- Allows transactions to outlive creating scope
- Enables flexible lifetime management
- Tradeoff: Arc overhead vs lifetime complexity

**Result<T, Error> vs Option<T> for operations**:
- Choose Result<T, Error> for all fallible operations
- Provides detailed error context
- Enables error recovery strategies
- Option only for truly optional values (not errors)

**Builder vs direct construction for Config**:
- Choose builder pattern for configuration
- Fluent, chainable API
- Compile-time and runtime validation
- Sensible defaults for all options
- Clear error messages for invalid config

### Implementation Notes

**Step 1: Database Open**
- Validate configuration
- Acquire exclusive file lock
- Open file handles (database, WAL)
- Initialize Pager with file handle
- Initialize WAL with recovery mode
- Replay WAL if needed
- Initialize B+Tree with root page ID
- Initialize SnapshotRegistry
- Return Arc<Db> handle

**Step 2: Transaction Begin**
- ReadTxn: Acquire shared lock, capture snapshot LSN, create ReadTxn
- WriteTxn: Acquire exclusive lock (blocking), allocate txn ID, create WriteTxn
- Both transactions register with Db for cleanup tracking
- Store transaction metadata for monitoring

**Step 3: Transaction Operations**
- ReadTxn.get: Look up key in B+Tree using snapshot root page ID
- WriteTxn.get: Check pending mutations, then B+Tree
- WriteTxn.put: Buffer mutation in memory
- WriteTxn.delete: Buffer deletion in memory
- All operations validate key/value size limits

**Step 4: Transaction Commit**
- WriteTxn.commit: Two-phase commit
  - Phase 1: Prepare (validate, build commit record)
  - Phase 2: Commit (WAL append, B+Tree apply, registry register, meta flush)
- ReadTxn.commit: No-op (no mutations to persist)
- Both transactions release locks and cleanup resources

**Step 5: Database Close**
- Explicit close: Release all resources, close file handles
- Implicit close: Drop trait calls close automatically
- Flush any pending changes
- Release file lock
- Cleanup memory

### Testing Strategy

**Unit tests needed for**:
- Db open with valid configuration
- Db open with invalid configuration (errors)
- Db open with corrupted database (recovery)
- Db close with active transactions
- Db close with no active transactions
- Transaction begin (read and write)
- Transaction operations (get, put, delete, scan)
- Transaction commit (success and failure)
- Transaction rollback
- Concurrent transactions (multiple readers, single writer)
- Error conditions (I/O errors, corruption, conflicts)

**Property tests for**:
- Snapshot isolation (readers don't see uncommitted changes)
- Write serialization (only one writer at a time)
- Atomic commit (all mutations or none)
- Read-your-writes (writer sees own mutations)
- Crash recovery (committed transactions survive)

**Integration scenarios**:
- Open database, perform operations, close, reopen, verify
- Concurrent workload (many readers, single writer)
- Crash during commit, recover, verify consistency
- Long-running transactions with snapshot retention
- Large transactions (many operations, large values)
- Configuration variations (cache sizes, page sizes, flush policies)

**Performance benchmarks**:
- Transaction begin/commit latency
- Read throughput (get operations)
- Write throughput (put operations)
- Scan performance (range queries)
- Concurrent reader scalability
- Writer throughput under contention
