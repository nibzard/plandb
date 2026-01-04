# MVCC Reader Handling

## Purpose

MVCC reader handling defines how NorthstarDB manages concurrent read transactions, enabling massive read scalability without blocking writers or other readers. This specification describes reader lifecycle management, synchronization mechanisms, reader-writer coordination, and performance optimizations that enable thousands of concurrent readers with minimal overhead. The reader handling design is fundamental to NorthstarDB's goal of supporting orchestrated AI coding agents with massive concurrent access.

## Core Concepts

### Reader Philosophy

NorthstarDB implements **lock-free readers** through MVCC snapshots:
- Readers acquire snapshots, not locks
- Snapshots provide immutable, consistent views
- Readers never block other readers
- Readers never block writers
- Writers never block readers
- Zero coordination between concurrent readers

### Reader Types

NorthstarDB supports two categories of readers:

**Snapshot Readers (ReadTxn)**: Explicit transaction with begin/end
- Created via `db.begin_read()` or `db.begin_read_at(txn_id)`
- Explicit lifetime management (must drop or close)
- Participate in snapshot reference counting
- Guaranteed consistent view for entire transaction duration
- Suitable for: multi-operation queries, analytics, batch processing

**Snapshot Handles (Snapshot)**: Lightweight reference
- Created via `db.snapshot()` or `db.snapshot_at(txn_id)`
- Can be cloned and passed between threads
- Implicit lifetime via reference counting
- Used internally by ReadTxn
- Suitable for: repeated reads, shared contexts, caching

### Scalability Goals

NorthstarDB targets extreme read concurrency:
- **Target**: 10,000+ concurrent readers on modern hardware
- **Overhead**: ~100 bytes per active reader
- **Contention**: Zero reader-reader contention
- **Latency**: O(1) snapshot creation, O(log N) point lookup

## Reader Lifecycle

### Reader Creation

**Method 1: Begin Read Transaction**

Function: `db.begin_read() -> Result<ReadTxn>`

**Creation Process**:

**Step 1**: Acquire shared access to snapshot registry
- Use RwLock read guard or atomic operations
- Multiple readers can acquire simultaneously
- Does not block other readers

**Step 2**: Capture current database state
- Read current transaction ID from registry
- Read current root page ID from registry
- Values are guaranteed to be consistent (from same atomic update)

**Step 3**: Create snapshot handle
- Allocate ReadTxn structure
- Store captured transaction ID
- Store captured root page ID
- Store database reference (Arc for lifetime management)

**Step 4**: Register snapshot reference
- Atomically increment reference count in snapshot registry
- Prevents garbage collection while reader exists
- Uses atomic fetch_add operation

**Step 5**: Release shared access
- Drop read guard on registry
- Reader now operates independently

**Step 6**: Return ReadTxn to caller
- Caller can now perform get/scan operations
- All reads see consistent snapshot

**Performance**: O(1) time complexity, ~100 bytes memory allocation

---

**Method 2: Begin Read at Transaction**

Function: `db.begin_read_at(txn_id: TransactionId) -> Result<ReadTxn>`

**Creation Process**:

**Step 1**: Validate transaction ID
- Check if txn_id exists in snapshot registry
- Return error if not found (TransactionNotFound)
- Return error if txn_id is in future (TransactionInFuture)

**Step 2**: Acquire shared access to registry
- Same as Method 1, RwLock read guard

**Step 3**: Look up root page for transaction
- Query registry for txn_id -> root_page_id mapping
- Retrieve root_page_id associated with requested transaction

**Step 4**: Create and register snapshot handle
- Same as Method 1, Steps 3-5

**Step 5**: Return ReadTxn to caller

**Use Case**: Time-travel queries, historical analysis, point-in-time recovery

---

### Active Reading Phase

**Get Operation**: Point lookup

```rust
read_txn.get(key: &[u8]) -> Result<Option<&[u8]>>
```

**Process**:
1. Traverse B+tree starting from snapshot's root_page_id
2. Perform binary search within nodes for key
3. Return value if found, None if not found
4. Page visibility implicit (all pages reachable from root are valid for snapshot)

**Guarantees**:
- Same key always returns same value (repeatable read)
- Unaffected by concurrent writes
- No locks acquired during read
- Multiple readers can read same key simultaneously without contention

**Performance**: O(log N) where N is number of keys

---

**Range Scan Operation**: Iterate over key range

```rust
read_txn.scan(range: Range) -> Iterator<Item = Result<(Key, Value)>>
```

**Process**:
1. Traverse B+tree to find start of range
2. Create iterator from snapshot's root_page_id
3. Yield key-value pairs in sorted order
4. Stop at end of range

**Guarantees**:
- Stable results: scan returns same set of keys if repeated
- Sorted order: results in lexicographic order
- No phantoms: will not see keys inserted after snapshot
- Concurrent scans do not interfere

**Performance**: O(K + log N) where K is number of keys in range

---

**Concurrent Reading**: Multiple readers operating simultaneously

**Scenario**: 1,000 threads each with ReadTxn, all performing get/scan operations

**Behavior**:
- No locks between readers
- No coordination required
- Each reader traverses B+tree independently
- Page cache may be shared (read-only access)
- Zero reader-reader contention

**Synchronization**: Only during snapshot creation, not during reads

**Performance**: Linear scalability with reader count

---

### Reader Termination

**Explicit Close**: `read_txn.close() -> Result<()>`

**Process**:
1. Mark ReadTxn as closed (set flag)
2. Future operations return error (TransactionClosed)
3. Decrement snapshot reference count
4. Resources released

**Use Case**: Early termination of long-lived reader

---

**Implicit Drop**: ReadTxn goes out of scope

**Process** (via Drop trait):
1. Rust calls Drop implementation
2. Decrement snapshot reference count in registry
3. If reference count reaches zero, transaction eligible for cleanup
4. Release database Arc reference
5. Memory freed

**Guarantee**: Reference counting ensures cleanup happens exactly once

---

**Clone**: Creating additional reader handles

```rust
let reader2 = reader1.clone();
```

**Process**:
1. Create new ReadTxn pointing to same snapshot
2. Increment snapshot reference count
3. Both handles share same underlying snapshot state
4. Each handle independently tracks its own closed state

**Use Case**: Passing reader to multiple threads, shared context

---

## Reader Synchronization

### Snapshot Registry Locking

**Data Structure**: Snapshot registry protected by RwLock

**Lock Hierarchy**:

**Read Lock (Shared)**:
- Acquired by: Snapshot creation, snapshot lookup
- Held by: Multiple readers simultaneously
- Blocks on: Registry write operations (commit, cleanup)
- Duration: Microseconds (registry lookup only)

**Write Lock (Exclusive)**:
- Acquired by: Transaction commit, snapshot cleanup
- Blocks on: All readers during critical section
- Duration: Microseconds (registry update only)

**Contention Analysis**:
- Reads far outnumber writes (typical workload: 95% reads, 5% writes)
- Write operations are brief (registry update only)
- Reader blocking during commit is minimal (microseconds)
- Lock-free reads after snapshot acquisition

**Alternative**: Lock-free atomic registry (future optimization)
- Use atomic operations for reference counting
- Use lock-free HashMap for snapshot entries
- Eliminates reader blocking entirely
- Increases implementation complexity

---

### Reference Counting

**Purpose**: Track how many readers reference each transaction

**Location**: In snapshot registry entry

**Type**: AtomicUsize (lock-free operations)

**Operations**:

**Increment**: When reader is created
```rust
entry.ref_count.fetch_add(1, Ordering::AcqRel);
```

**Decrement**: When reader is dropped
```rust
let last_ref = entry.ref_count.fetch_sub(1, Ordering::AcqRel) == 1;
```

**Read**: When cleanup checks eligibility
```rust
if entry.ref_count.load(Ordering::Acquire) == 0 {
    // Eligible for cleanup
}
```

**Memory Ordering**: AcqRel ensures proper synchronization
- Increment: Changes visible before reader observes snapshot
- Decrement: Cleanup sees final state after all readers done

---

### Page Cache Coordination

**Read-Only Page Access**:
- Readers access page cache during B+tree traversal
- Pages are immutable once committed
- Multiple readers can access same page simultaneously
- No locks required for page reads

**Cache Line Contention**:
- Multiple readers reading same cache line is fine
- Read-only access, no modifications
- Hardware cache coherence handles synchronization
- Potential issue: false sharing if readers write nearby locations

**Optimization**: Per-reader page pinning
- Reader pins page in cache during traversal
- Prevents eviction during active use
- Released when reader completes operation
- Reduces cache churn under high concurrency

---

## Reader-Writer Coordination

### Single-Writer Model

**Invariant**: At most one WriteTxn can exist at a time

**Enforcement**:
```rust
fn begin_write(&self) -> Result<WriteTxn> {
    // Try acquire write lock
    match self.write_lock.try_write() {
        Some(guard) => Ok(WriteTxn::new(guard)),
        None => Err(Error::WriteBusy),
    }
}
```

**Effect on Readers**:
- Readers acquire shared lock (read guard)
- Writer acquires exclusive lock (write guard)
- RwLock ensures mutual exclusion
- Readers and writer cannot hold locks simultaneously

**Behavior**:
- Reader creation during write: Blocks briefly until commit completes
- Active readers during write: Continue unaffected (already have snapshot)
- Writer during active readers: Waits for all read guards to drop (brief)

---

### Non-Blocking Readers

**Key Property**: Readers never block active reads

**Mechanism**:
1. Reader acquires snapshot via shared lock (microseconds)
2. Reader releases lock immediately
3. Reader performs all reads without holding any lock
4. Writer can commit concurrently with active readers
5. Readers see old snapshot, writer creates new snapshot
6. Both make progress simultaneously

**Timeline Example**:
```
Time T0: Reader R1 begins read, acquires snapshot at txn_id=100
Time T1: R1 releases shared lock
Time T2: Writer W1 begins write, acquires exclusive lock
Time T3: R1 performs get(key) - no lock held, proceeds
Time T4: W1 commits, registers snapshot at txn_id=101
Time T5: W1 releases exclusive lock
Time T6: R1 performs another get(key) - no lock held, proceeds
Time T7: R1 sees data as of txn_id=100 (repeatable read)
Time T8: R1 ends read
```

**Result**: R1 never blocked, W1 never blocked, both made progress

---

### Writer Prevents New Writers

**Effect**: begin_write returns WriteBusy if writer active

**Behavior**:
- Application must handle WriteBusy error
- Options: Retry with backoff, queue write, return error to user
- Natural serialization of writes

**Impact on Readers**: None
- Readers can continue to be created
- New readers see snapshot before current write
- Readers after write see snapshot including write

---

## Reader Performance Considerations

### Read-Heavy Workloads

**Scenario**: Analytics queries, batch processing, report generation

**Characteristics**:
- Many concurrent readers (100-10,000)
- Long-lived transactions (seconds to minutes)
- Range scans and point reads
- Minimal or no writes

**Optimization Strategies**:

**Strategy 1: Snapshot Sharing**
- Multiple readers can share same snapshot if created at same time
- Clone existing ReadTxn instead of creating new one
- Reduces registry contention
- Shares reference count increment

**Strategy 2: Page Cache Warming**
- Pre-load frequently accessed pages
- Reduces I/O during concurrent reads
- Batch readers can benefit from cache warming by first reader

**Strategy 3: Read-Ahead**
- Anticipate page accesses during range scan
- Prefetch next pages before current page exhausted
- Hides I/O latency
- Parallelizes I/O and computation

**Strategy 4: Iterator Caching**
- Reuse iterators across operations
- Avoid repeated B+tree traversal
- Cache intermediate traversal state

---

### Write-Heavy Workloads

**Scenario**: High write throughput, minimal reads

**Characteristics**:
- Frequent writes (writes serialized)
- Occasional short-lived reads
- Snapshots quickly become stale
- High cleanup rate

**Optimization Strategies**:

**Strategy 1: Snapshot Expiration**
- Aggressive cleanup of old snapshots
- Keep minimal history (e.g., last 10 transactions)
- Reduces memory overhead
- Limits time-travel capability

**Strategy 2: Short-Lived Readers**
- Encourage explicit close when done
- Use RAII patterns for automatic cleanup
- Avoid holding snapshots longer than necessary
- Reduces reference count duration

**Strategy 3: Batch Reads**
- Accumulate read operations
- Perform as single batch transaction
- Reduces number of snapshots created
- Amortizes snapshot acquisition cost

---

### Mixed Workloads

**Scenario**: Concurrent reads and writes at high rates

**Characteristics**:
- Many readers (10-1,000 concurrent)
- Frequent writes (10-100 per second)
- Diverse query patterns
- Balance between freshness and performance

**Optimization Strategies**:

**Strategy 1: Reader Partitioning**
- Separate read-only replicas from primary
- Readers use replica for queries
- Writer uses primary for writes
- Asynchronous replication from primary to replica
- Eliminates reader-writer lock contention

**Strategy 2: Adaptive Locking**
- Use RwLock for low concurrency (< 100 readers)
- Switch to lock-free atomics for high concurrency (> 100 readers)
- Runtime profiling to detect contention
- Dynamic adaptation to workload

**Strategy 3: Pessimistic Snapshot Creation**
- Pre-allocate snapshot registry entries
- Batch snapshot creation operations
- Reduce lock acquisitions
- Amortize synchronization overhead

---

## Concurrency Edge Cases

### Reader During Database Close

**Scenario**: Database closing while readers active

**Behavior**:
1. Application calls `db.close()`
2. Database waits for all readers to complete (graceful shutdown)
3. New readers rejected with DatabaseClosed error
4. Active readers continue until they naturally complete
5. Once all readers done, database releases resources

**Alternative**: Forced close
- Application sets timeout
- Readers interrupted after timeout
- Incomplete reads return error
- Database closes regardless of active readers

**Implementation**: Use Arc for shared database reference
- Readers hold Arc<DbInner>
- Database close drops its Arc
- Readers keep DbInner alive until dropped
- Final reader drop triggers actual resource cleanup

---

### Snapshot During Crash Recovery

**Scenario**: Readers active when process crashes

**Behavior**:
1. Crash occurs, process terminates
2. Active readers lost (no cleanup possible)
3. On restart, recovery rebuilds snapshot registry from WAL
4. Old snapshot handles no longer exist
5. New readers start from recovered state

**Invariants**:
- Crash does not corrupt database (atomic writes, fsync)
- Recovery brings database to consistent state
- No orphaned readers after restart
- Snapshot registry reconstructed from commit records

---

### Snapshot Cleanup Contention

**Scenario**: Cleanup running while readers active

**Behavior**:
1. Cleanup thread scans snapshot registry
2. Checks reference count for each transaction
3. Skips transactions with ref_count > 0
4. Removes transactions with ref_count == 0
5. Readers incrementing ref concurrently prevent cleanup

**Race Condition**: Reader increments ref_count after cleanup checks
1. Cleanup reads ref_count = 0
2. Reader increments ref_count to 1
3. Cleanup removes transaction entry
4. Reader now has handle to removed entry

**Prevention**: Double-check or deferred cleanup
1. Cleanup marks entry as "eligible for removal"
2. Actual removal happens later
3. If ref_count increments, remove "eligible" mark
4. Only actually remove if still eligible

---

## Reader Statistics and Monitoring

### Metrics to Track

**Active Readers**:
- Current number of active ReadTxn handles
- Histogram of reader lifetime
- Peak concurrent readers

**Snapshot Statistics**:
- Number of snapshots in registry
- Oldest snapshot transaction ID
- Newest snapshot transaction ID
- Snapshot age distribution

**Performance Metrics**:
- Snapshot creation latency (p50, p99)
- Get operation latency (p50, p99)
- Range scan latency by size (p50, p99)
- Pages read per operation

**Contention Metrics**:
- Registry lock wait time
- Reader blocking events (should be zero for reads)
- Writer wait time for readers to complete

### Monitoring Interface

```rust
struct ReaderStats {
    active_readers: usize,
    oldest_snapshot_txn_id: TransactionId,
    newest_snapshot_txn_id: TransactionId,
    total_snapshots: usize,
    avg_reader_lifetime_ms: u64,
    peak_concurrent_readers: usize,
}
```

## Rust Implementation Guidance

### ReadTxn Structure

```rust
pub struct ReadTxn {
    /// Transaction ID defining the snapshot boundary
    txn_id: TransactionId,

    /// Root page of B+tree for this snapshot
    root_page_id: PageId,

    /// Database reference (keeps database alive)
    db: Arc<DbInner>,

    /// Whether this transaction has been closed
    closed: AtomicBool,
}

impl ReadTxn {
    /// Create new read transaction at current snapshot
    pub fn begin(db: Arc<DbInner>) -> Result<Self> {
        // Acquire registry read lock
        let registry = db.snapshot_registry.read()?;

        // Capture current state
        let txn_id = registry.current_txn_id();
        let root_page_id = registry.current_root_page_id();

        // Register reference
        registry.increment_ref(txn_id)?;

        // Create transaction
        Ok(Self {
            txn_id,
            root_page_id,
            db,
            closed: AtomicBool::new(false),
        })
    }

    /// Begin read at specific transaction
    pub fn begin_at(db: Arc<DbInner>, txn_id: TransactionId) -> Result<Self> {
        // Acquire registry read lock
        let registry = db.snapshot_registry.read()?;

        // Look up transaction
        let entry = registry.get(txn_id)
            .ok_or(Error::TransactionNotFound { txn_id })?;

        let root_page_id = entry.root_page_id();

        // Register reference
        entry.increment_ref()?;

        Ok(Self {
            txn_id,
            root_page_id,
            db,
            closed: AtomicBool::new(false),
        })
    }

    /// Get value for key
    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>> {
        if self.closed.load(Ordering::Acquire) {
            return Err(Error::TransactionClosed);
        }

        // Traverse B+tree from root_page_id
        self.db.btree.get(self.root_page_id, key)
    }

    /// Scan range of keys
    pub fn scan(&self, range: Range) -> Result<ScanIterator> {
        if self.closed.load(Ordering::Acquire) {
            return Err(Error::TransactionClosed);
        }

        Ok(ScanIterator::new(
            self.db.clone(),
            self.root_page_id,
            range,
        ))
    }

    /// Explicitly close transaction
    pub fn close(self) -> Result<()> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Err(Error::TransactionClosed);
        }

        // Decrement ref count via Drop
        drop(self);
        Ok(())
    }
}

impl Clone for ReadTxn {
    fn clone(&self) -> Self {
        // Increment reference count
        let registry = self.db.snapshot_registry.read().unwrap();
        registry.increment_ref(self.txn_id).unwrap();

        Self {
            txn_id: self.txn_id,
            root_page_id: self.root_page_id,
            db: Arc::clone(&self.db),
            closed: AtomicBool::new(false),
        }
    }
}

impl Drop for ReadTxn {
    fn drop(&mut self) {
        // Decrement reference count
        let registry = self.db.snapshot_registry.read().unwrap();
        let entry = registry.get(self.txn_id);

        if let Some(entry) = entry {
            let last_ref = entry.decrement_ref();
            if last_ref {
                // Signal cleanup for this transaction
                self.db.snapshot_registry.queue_for_cleanup(self.txn_id);
            }
        }
    }
}
```

### Concurrency Strategy

**RwLock for Snapshot Registry**:

```rust
pub struct SnapshotRegistry {
    snapshots: RwLock<HashMap<TransactionId, RegistryEntry>>,
    current_txn_id: AtomicU64,
}

impl SnapshotRegistry {
    pub fn read(&self) -> Result<RwLockReadGuard<HashMap<TransactionId, RegistryEntry>>> {
        self.snapshots.read().map_err(|_| Error::PoisonedLock)
    }

    pub fn write(&self) -> Result<RwLockWriteGuard<HashMap<TransactionId, RegistryEntry>>> {
        self.snapshots.write().map_err(|_| Error::PoisonedLock)
    }
}
```

**Atomic Reference Counting**:

```rust
pub struct RegistryEntry {
    root_page_id: PageId,
    ref_count: AtomicUsize,
}

impl RegistryEntry {
    pub fn increment_ref(&self) {
        self.ref_count.fetch_add(1, Ordering::AcqRel);
    }

    pub fn decrement_ref(&self) -> bool {
        self.ref_count.fetch_sub(1, Ordering::AcqRel) == 1
    }
}
```

### Performance Optimization

**Lock-Free Snapshot Creation (Future)**:

```rust
// Use atomic operations instead of RwLock
pub struct LockFreeSnapshotRegistry {
    snapshots: Atomic<HashMap<TransactionId, RegistryEntry>>,
}
```

**Read-Copy-Update (RCU) Pattern**:

```rust
// Readers see immutable snapshot of registry
// Writers create new version and swap atomically
// Old version freed after all readers complete
```

## Testing Strategy

### Unit Tests

**Reader Creation**:
- Test begin_read creates snapshot at current transaction
- Test begin_read_at creates snapshot at specific transaction
- Test begin_read_at returns error for invalid transaction
- Test begin_read_at returns error for future transaction

**Reader Operations**:
- Test get returns correct value for existing key
- Test get returns None for non-existent key
- Test scan returns all keys in range
- Test scan returns keys in sorted order
- Test scan is repeatable (same results if called again)

**Reader Lifecycle**:
- Test close prevents further operations
- Test close returns error if already closed
- Test clone increments reference count
- Test drop decrements reference count
- Test last drop triggers cleanup

**Concurrency**:
- Test multiple readers can operate simultaneously
- Test readers do not block each other
- Test readers continue during write commit
- Test writer blocks second writer
- Test readers do not block writer

### Property Tests

**Snapshot Immutability**:
- Property: Same query returns same results throughout transaction
- Test: Random operations, repeat queries, verify consistency

**Reference Counting**:
- Property: After N clones, reference count increased by N
- Test: Clone transaction multiple times, verify count

**Concurrent Reads**:
- Property: Concurrent readers see consistent snapshots
- Test: Spawn many readers, verify no data races

**Reader-Writer Isolation**:
- Property: Reader never sees uncommitted writes
- Test: Read during write, verify old values

### Integration Tests

**High Concurrency**:
- Test: 10,000 concurrent readers performing operations
- Verify: No deadlocks, no crashes, acceptable latency

**Long-Lived Readers**:
- Test: Readers active for minutes while writes occur
- Verify: Readers see consistent snapshots, writes succeed

**Crash Recovery**:
- Test: Kill process during active reads
- Verify: Recovery produces consistent state

## Summary

NorthstarDB reader handling enables massive read concurrency through MVCC snapshots:

**Key Properties**:
- Lock-free readers (no locks during reads)
- Readers never block readers
- Readers never block writers
- Writers never block readers
- O(1) snapshot creation
- O(log N) point lookup
- Linear scalability with reader count

**Implementation**:
- Immutable snapshots via transaction ID
- Reference counting for lifecycle
- RwLock for registry protection
- Atomic operations for ref counts
- Arc for shared database reference

**Performance**:
- ~100 bytes per active reader
- Zero reader-reader contention
- Minimal reader-writer contention
- Microsecond-level snapshot acquisition
- Support for 10,000+ concurrent readers

**Testing**:
- Unit tests for lifecycle and operations
- Property tests for invariants
- Concurrency tests for scalability
- Integration tests for real-world scenarios
