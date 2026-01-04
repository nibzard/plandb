# Transaction Concurrency

## Purpose

Transaction concurrency defines how multiple transactions interact simultaneously, ensuring isolation and consistency while maximizing parallelism. NorthstarDB uses Multi-Version Concurrency Control (MVCC) to enable concurrent readers without blocking, while serializing writers through an exclusive write lock. The concurrency model defines visibility rules (which data each transaction can see), locking strategies (when transactions block or proceed), and isolation guarantees (how transactions interfere with each other). V0 implements snapshot isolation with single-writer concurrency, providing high read throughput and simple write serialization.

## Overview

### Concurrency Model

**MVCC with Snapshot Isolation**: Readers never block, single writer
- Multiple ReadTxn instances can exist simultaneously
- Only one WriteTxn can exist at a time
- Readers use snapshots from transaction begin time
- Writer uses current database state with write locking

**V0 Concurrency Characteristics**:
- Unbounded concurrent readers (no reader limit)
- Single concurrent writer (exclusive write lock)
- Readers never block writers (snapshots isolated)
- Writers never block readers (readers use old snapshots)
- Writers block subsequent writers (write serialization)

**Future Multi-Writer Support** (Phase 7+):
- Concurrent writers with conflict detection
- Optimistic concurrency control
- Automatic retry on conflicts
- Serializable isolation levels

### Concurrency Goals

**Maximize Parallelism**: Enable as many concurrent operations as possible
- Multiple readers accessing same data simultaneously
- Readers proceed without waiting for writers
- Writers proceed without waiting for readers

**Ensure Isolation**: Prevent transactions from interfering with each other
- Readers see consistent snapshot (not affected by concurrent writes)
- Writers see their own writes (read-your-writes)
- Committed writes become visible to future transactions

**Prevent Anomalies**: Avoid isolation violations
- No dirty reads (read uncommitted data)
- No non-repeatable reads (data changes during transaction)
- No phantoms (new keys appear in range scans)
- No lost updates (concurrent writes overwrite each other)

## Concurrent Read Transactions

### Multiple Readers

**Unbounded Reader Concurrency**: No limit on concurrent ReadTxn instances
- Application can begin unlimited read transactions
- Each reader acquires shared read lock
- Shared locks allow multiple concurrent holders
- No reader blocks another reader

**Shared Lock Acquisition**: begin_read acquires shared lock
- Lock type: RwLock read lock (shared)
- Acquisition: Non-blocking or blocking (implementation choice)
- Holding: Lock held for entire transaction lifetime
- Release: Lock released when ReadTxn dropped

**Reader-Reader Interaction**: No conflicts, no blocking
- Readers do not interfere with each other
- Each reader has independent snapshot
- Readers can access same data simultaneously
- No coordination needed between readers

### Reader Snapshots

**Snapshot Capture**: Each reader captures snapshot at begin time
- Snapshot identified by root_page_id
- Snapshot represents database state at specific point in time
- All reads use same root_page_id (consistent view)
- Snapshot never changes during transaction lifetime

**Snapshot Isolation**: Readers isolated from concurrent writes
- Reader sees only data committed before its snapshot
- Concurrent writes not visible to reader
- Reader view stable and consistent
- No need for locks during reads

**Time Travel Queries**: Readers can query historical state
- begin_read_at(txn_id) reads from historical transaction
- Snapshot from past transaction state
- Useful for auditing, versioning, analysis
- Historical reads not affected by current state

### Reader Lifecycle

**Begin Read Transaction**:
```
let txn1 = db.begin_read()?; // Snapshot at txn_id 100, root_page_id 42
let txn2 = db.begin_read()?; // Snapshot at txn_id 101, root_page_id 45
```
- Each reader gets snapshot from begin time
- Snapshots may differ if writes occurred between begins
- Both readers can operate concurrently

**Read Operations**:
```
let value1 = txn1.get(b"key")?; // Reads from root_page_id 42
let value2 = txn2.get(b"key")?; // Reads from root_page_id 45
```
- Each reader reads from its own snapshot
- Concurrent reads do not block each other
- Different snapshots may return different values

**Commit/Release**:
```
drop(txn1); // Releases shared lock
```
- Lock released when transaction dropped
- Other readers unaffected
- Snapshot no longer needed

## Concurrent Write Transactions

### Single Writer Model

**Exclusive Write Access**: Only one WriteTxn can exist at a time
- Write lock type: RwLock write lock (exclusive)
- begin_write acquires exclusive write lock
- Only one writer can hold lock at a time
- Writers are serialized (execute one at a time)

**Writer Lock Acquisition**:
```
let txn1 = db.begin_write()?; // Acquires write lock
let txn2 = db.begin_write()?; // BLOCKS or returns WriteBusy error
```
- First writer acquires lock successfully
- Second writer blocked or rejected (implementation choice)
- NorthstarDB V0: Returns WriteBusy error immediately (non-blocking)

**Writer Lock Duration**: Lock held for entire transaction lifetime
- Acquired at begin_write
- Held during all mutation operations (put, delete)
- Held during commit process
- Released on commit or rollback (or Drop)

**Writer Lock Release**:
```
drop(txn1); // Commit or rollback, then release write lock
```
- Lock released after commit or rollback
- Next writer can now acquire lock
- No writer starvation (fair lock acquisition)

### Write Serialization

**Sequential Execution**: Writers execute one at a time
- Writer 1: begin_write, put/delete, commit, release lock
- Writer 2: begin_write (after Writer 1 releases), put/delete, commit, release lock
- No concurrent writes
- No write-write conflicts

**Write Ordering**: Writers ordered by lock acquisition
- First to acquire lock writes first
- Deterministic ordering based on lock timing
- No priority or preemption
- FIFO ordering for fair access

**Write Contention**: High write contention reduces throughput
- Many writers waiting for single lock
- Each writer waits for previous writer to complete
- Contention increases with write frequency
- Solution: Reduce write frequency, batch operations, or move to multi-writer model (future)

## Mixed Read-Write Concurrency

### Readers During Active Writer

**Readers Never Block**: Readers proceed during active write transaction
- Writer holds exclusive write lock
- Readers acquire shared read lock (compatible with write lock in some RwLock implementations)
- OR readers use snapshot from before writer began (NorthstarDB approach)
- Readers never wait for writer to complete

**Reader Snapshot Selection**: Readers see pre-writer state
- Reader begins during active writer: Gets snapshot from before writer began
- Reader snapshot does not include writer's uncommitted mutations
- Reader sees consistent state without writer's changes
- Writer does not block reader

**Example Timeline**:
```
T1: Writer begins (txn_id 100, snapshot root=50)
T2: Writer puts "key" = "value1" (pending, not committed)
T3: Reader begins (txn_id 101, snapshot root=50) // Uses snapshot before writer's commit
T4: Reader gets "key" -> returns value from root=50 (not "value1")
T5: Writer commits (new root=51)
T6: Reader gets "key" -> still returns value from root=50 (snapshot isolation)
T7: Reader drops, lock released
```

### Writer During Active Readers

**Writer Never Blocks Readers**: Writer does not affect existing readers
- Readers hold snapshots from before writer began
- Writer mutations not visible to existing readers
- Readers continue using old snapshots
- No coordination needed

**Writer Blocks New Readers**: (Implementation choice)
- Option 1: New readers blocked until writer completes (pessimistic)
- Option 2: New readers use snapshot from before writer (optimistic, NorthstarDB V0)
- NorthstarDB V0: New readers get snapshot from before writer, proceed immediately

**Example Timeline**:
```
T1: Reader1 begins (txn_id 100, snapshot root=50)
T2: Writer begins (txn_id 101, acquires write lock, snapshot root=50)
T3: Reader2 begins (txn_id 102, snapshot root=50) // Proceeds immediately, uses snapshot before writer
T4: Writer puts "key" = "value1" (pending)
T5: Reader1 gets "key" -> value from root=50 (not affected by writer)
T6: Reader2 gets "key" -> value from root=50 (not affected by writer)
T7: Writer commits (new root=51)
T8: Reader3 begins (txn_id 103, snapshot root=51) // Sees writer's committed changes
```

### Concurrent Read-Write Properties

**No Blocking**: Readers and writers never block each other
- Readers proceed during active writer
- Writer proceeds during active readers
- Lock compatibility: Shared locks compatible with write lock (for readers)
- OR lock independence: Readers use snapshots, don't need lock (NorthstarDB approach)

**Snapshot Isolation**: Each transaction sees consistent snapshot
- Readers see snapshot from begin time
- Writer sees snapshot from begin time
- Concurrent transactions do not affect each other's view
- No dirty reads, no non-repeatable reads

**Write Exclusion**: Only one writer at a time
- Writers serialized by exclusive lock
- No concurrent writes
- No write-write conflicts
- Simple and predictable

## Visibility Rules

### Read Visibility

**Reader Sees**: Only data committed before snapshot
- Snapshot captured at begin_read or begin_read_at
- All transactions committed before snapshot txn_id are visible
- Transaction committed at snapshot txn_id is visible
- Transactions committed after snapshot txn_id are not visible

**Visibility Calculation**:
```
visible = committed_txn.txn_id <= snapshot.txn_id
```

**Example**:
```
Transaction 90: Put "key" = "value1", commit
Transaction 95: Put "key" = "value2", commit
Transaction 100: Put "key" = "value3", commit

Reader at txn_id 97: Sees "value2" (txn 95), does NOT see "value3" (txn 100)
Reader at txn_id 100: Sees "value3" (txn 100)
```

### Write Visibility

**Writer Sees**: Database state at begin time + own mutations
- Snapshot captured at begin_write
- All transactions committed before snapshot visible
- Writer's own mutations visible via read-your-writes
- Other concurrent writers' mutations not visible (only one writer exists)

**Read-Your-Writes**: Writer sees own mutations immediately
```
txn.put("key", "value1")?; // Mutation staged
let value = txn.get("key")?; // Returns "value1" (from pending mutations)
```
- get() checks pending mutations before database
- Own mutations visible without commit
- Enables consistent intra-transaction view

**Other Writers**: Not applicable in V0 (single writer)
- Future: Concurrent writers' mutations not visible until committed
- Future: Conflict detection on overlapping mutations
- Future: Retry or abort on conflicts

### Commit Visibility

**Committed Writes Become Visible**: After commit, other transactions see changes
- Committed transaction txn_id recorded
- Future readers with snapshot >= committed txn_id see changes
- Future writers see changes in their snapshot

**Visibility Timeline**:
```
T1: Writer begins (txn_id 100, snapshot root=50)
T2: Reader1 begins (txn_id 101, snapshot root=50)
T3: Writer puts "key" = "value1"
T4: Writer commits (txn_id 100, new root=51)
T5: Reader2 begins (txn_id 102, snapshot root=51)
T6: Reader1 gets "key" -> returns value from root=50 (does not see writer's commit)
T7: Reader2 gets "key" -> returns "value1" from root=51 (sees writer's commit)
```

## Isolation Guarantees

### Snapshot Isolation

**Definition**: Each transaction sees snapshot from commit time
- Transaction sees database state as of specific point in time
- Concurrent changes not visible
- No locks needed for reads
- High concurrency possible

**Properties**:
- **No Dirty Reads**: Transaction never reads uncommitted data
- **No Non-Repeatable Reads**: Repeated reads return same value
- **No Lost Updates**: Writes serialized (single writer)
- **Phantoms Possible**: New keys may appear in range scans (future concern)

**V0 Implementation**: Snapshot isolation via MVCC
- Each transaction has snapshot txn_id
- Reads use snapshot root_page_id
- Writes serialized by exclusive lock
- Simple and efficient

### Read Committed vs Snapshot Isolation

**Read Committed** (Not implemented in V0):
- Each statement sees latest committed data
- Different statements in same transaction may see different data
- Non-repeatable reads possible
- Lower isolation level

**Snapshot Isolation** (V0 default):
- Entire transaction sees same snapshot
- All statements see same data
- Non-repeatable reads prevented
- Higher isolation level

**Serializable** (Future):
- Transactions appear to execute serially
- Phantom reads prevented
- Highest isolation level
- May require conflict detection and retry

### Anomaly Prevention

**Dirty Read Prevention**: Never read uncommitted data
- Uncommitted mutations not visible to other transactions
- Only committed data visible to snapshots
- Writer's own mutations visible (read-your-writes)
- No dirty reads possible

**Non-Repeatable Read Prevention**: Same data returned on repeat reads
- Snapshot never changes during transaction
- Repeated get operations return same value
- Concurrent writes do not affect snapshot
- Non-repeatable reads prevented

**Lost Update Prevention**: Concurrent writes don't overwrite each other
- Single writer serializes writes
- No concurrent writers in V0
- No lost updates possible
- Future: Conflict detection prevents lost updates

**Phantom Read Prevention**: (Future) Range scans consistent
- Future: Predicate locking or snapshot ranges
- V0: Not addressed (range scans may see new keys)
- Future: Serializable isolation prevents phantoms

## Lock Strategy

### Read Lock: RwLock Read Lock

**Lock Type**: Shared lock (RwLock read guard)
- Multiple readers can hold lock simultaneously
- Readers do not block each other
- Compatible with other readers

**Acquisition**: begin_read acquires shared lock
- Blocking or non-blocking (implementation choice)
- NorthstarDB V0: Blocking (wait if lock unavailable)
- Alternative: Non-blocking with error return

**Duration**: Lock held for entire transaction lifetime
- Acquired at begin_read
- Held during all read operations
- Released on Drop (transaction end)

**Purpose**: Prevent writer from starting while readers active
- Writer acquires exclusive lock (requires no readers)
- Readers block writer acquisition
- OR readers use snapshots, writer proceeds independently (NorthstarDB approach)

### Write Lock: RwLock Write Lock

**Lock Type**: Exclusive lock (RwLock write guard)
- Only one writer can hold lock
- Writer blocks all other lock acquisitions
- Not compatible with readers or writers

**Acquisition**: begin_write acquires exclusive lock
- Non-blocking in V0 (returns WriteBusy error immediately)
- Alternative: Blocking (wait for lock)
- Alternative: Try-lock with timeout

**Duration**: Lock held for entire transaction lifetime
- Acquired at begin_write
- Held during all mutation operations
- Held during commit process
- Released on commit, rollback, or Drop

**Purpose**: Serialize writers, prevent concurrent writes
- Only one writer active at a time
- No write-write conflicts
- Simple and predictable

### Lock Compatibility

**Compatibility Matrix**:
|          | Reader | Writer |
|----------|--------|--------|
| Reader   | ✓      | ✗      |
| Writer   | ✗      | ✗      |

Legend:
- ✓: Compatible (can coexist)
- ✗: Incompatible (cannot coexist)

**Reader-Reader**: Compatible
- Multiple readers can hold shared locks simultaneously
- No blocking between readers

**Reader-Writer**: Incompatible (traditional RwLock)
- Readers block writer (writer waits for readers)
- Writer blocks readers (readers wait for writer)

**Writer-Writer**: Incompatible
- Only one writer can hold exclusive lock
- Writers serialized

**NorthstarDB V0 Variation**: Readers independent of writer
- Readers use snapshots, don't require shared lock
- Writer acquires exclusive lock for write serialization
- Readers and writer proceed concurrently
- Snapshot isolation provides correctness without reader-writer locking

## Lock Acquisition Patterns

### Non-Blocking begin_write

**V0 Behavior**: begin_write returns WriteBusy error if writer active
```
loop {
    match db.begin_write() {
        Ok(txn) => {
            // Use transaction
            txn.put(b"key", b"value")?;
            txn.commit()?;
            break;
        }
        Err(Error::WriteBusy) => {
            // Retry after delay
            sleep(Duration::from_millis(10));
            continue;
        }
        Err(e) => return Err(e),
    }
}
```

**Benefits**:
- No blocking (application has control)
- Application manages retry logic
- Can implement custom backoff strategies
- Predictable behavior (no surprise waits)

**Drawbacks**:
- More boilerplate code
- Application must handle retry
- Potential for busy-wait loop if not careful

### Blocking begin_write (Alternative)

**Alternative Behavior**: begin_write blocks until lock available
```
let txn = db.begin_write()?; // Blocks if writer active
txn.put(b"key", b"value")?;
txn.commit()?;
```

**Benefits**:
- Simpler application code
- No retry logic needed
- Automatic waiting

**Drawbacks**:
- Unpredictable blocking duration
- Potential for deadlocks if not careful
- Less control over concurrency

### Recommended Pattern

**V0 Recommendation**: Non-blocking with exponential backoff
```
let mut retries = 0;
loop {
    match db.begin_write() {
        Ok(txn) => {
            // Execute transaction logic
            return txn.commit();
        }
        Err(Error::WriteBusy) if retries < MAX_RETRIES => {
            retries += 1;
            let delay = exponential_backoff(retries);
            sleep(delay);
        }
        Err(e) => return Err(e),
    }
}
```

## Contention Handling

### Write Contention

**Problem**: Many writers competing for single lock
- High write frequency
- Long-running transactions
- Throughput degraded

**Symptoms**:
- Frequent WriteBusy errors
- High retry rate
- Low write throughput

**Solutions**:
1. **Reduce Write Frequency**: Batch operations, reduce transaction count
2. **Shorten Transactions**: Commit more frequently, reduce work per transaction
3. **Exponential Backoff**: Spread retry attempts over time
4. **Multi-Writer Model**: Future support for concurrent writers with conflict detection

### Read Contention

**Problem**: Many readers overwhelming system
- High read frequency
- Long-running read transactions
- Snapshot accumulation

**Symptoms**:
- High memory usage (many snapshots retained)
- Slow cleanup of old snapshots
- Reduced write throughput (snapshots prevent page reuse)

**Solutions**:
1. **Limit Read Duration**: Shorten read transactions, commit sooner
2. **Snapshot Cleanup**: Aggressively clean up old snapshots
3. **Read-Your-Writes Cache**: Cache recent reads to reduce transaction count
4. **Read Replicas**: Distribute read load across multiple database instances

### Mixed Contention

**Problem**: Readers and writers competing for resources
- High read and write frequency
- Snapshots prevent page reuse
- Write throughput degraded

**Symptoms**:
- Writer slowed by snapshot retention
- Memory pressure from accumulated snapshots
- Reduced overall throughput

**Solutions**:
1. **Snapshot Isolation**: Readers use snapshots, don't block writers (already implemented)
2. **Snapshot Expiration**: Time out old snapshots, force readers to retry
3. **Priority Queuing**: Prioritize writers or readers based on policy
4. **Separate Read/Write Paths**: Optimize read and write paths independently

## Performance Considerations

### Reader Scalability

**Linear Reader Scaling**: Readers scale linearly with CPU cores
- No reader-reader blocking
- Each reader independent
- Throughput increases with core count
- Limited by memory and I/O bandwidth

**Snapshot Overhead**: Each reader retains snapshot
- Memory: Snapshot metadata (root_page_id, txn_id)
- Page retention: Pages in snapshot cannot be freed
- Cleanup overhead: Tracking which snapshots are active
- Trade-off: Concurrency vs memory usage

**Read Throughput**: High throughput possible
- Parallel reads across multiple cores
- No blocking between readers
- Limited by disk I/O and page cache hit rate

### Writer Throughput

**Single Writer Throughput**: Limited by transaction duration
- Writer serializes all writes
- Throughput = 1 / average transaction duration
- Long transactions reduce throughput
- Short transactions increase throughput

**Write Optimization**: Reduce transaction duration
- Batch operations into fewer transactions
- Reduce work per transaction
- Optimize commit path (WAL, B+tree, meta updates)
- Use faster storage (SSD vs HDD)

### Concurrency Metrics

**Metrics to Track**:
- Active reader count
- Active writer count (0 or 1)
- Reader wait time (time to acquire read lock)
- Writer wait time (time to acquire write lock, WriteBusy frequency)
- Transaction duration (read and write)
- Snapshot retention time
- Commit rate
- Abort rate

**Performance Targets**:
- Reader wait time: < 1ms (ideally 0ms)
- Writer wait time: < 10ms (WriteBusy retries)
- Transaction duration: < 100ms (writes), < 1s (reads)
- Snapshot retention: < 5s (cleanup old snapshots)

## Testing Requirements

### Unit Tests

**Concurrent Reader Tests**:
- Multiple readers begin simultaneously: All succeed
- Readers access same data: No blocking, consistent snapshots
- Readers access different data: No blocking, independent snapshots
- Readers drop in various orders: No resource leaks

**Single Writer Tests**:
- Single writer begins and commits: Succeeds
- Writer sees own mutations: Read-your-writes
- Writer commits: Changes visible to future transactions
- Writer rollback: Changes not visible to any transaction

**Concurrent Read-Write Tests**:
- Reader begins during active writer: Proceeds immediately
- Writer begins during active readers: Proceeds immediately
- Reader does not see writer's uncommitted mutations: Snapshot isolation
- Reader does not see writer's committed mutations if snapshot older: Snapshot isolation

**Lock Acquisition Tests**:
- begin_write returns WriteBusy when writer active
- begin_write succeeds after previous writer commits
- begin_write succeeds after previous writer rollbacks
- Multiple begin_write calls: Only first succeeds, others return WriteBusy

### Integration Tests

**Snapshot Isolation Tests**:
- Reader sees consistent snapshot throughout transaction
- Concurrent writer does not affect reader's view
- Repeated reads return same value
- Writer's committed changes not visible to reader with older snapshot

**Visibility Tests**:
- Reader at txn_id N sees only transactions <= N
- Reader at txn_id N does not see transactions > N
- Writer sees own mutations immediately
- Writer's mutations visible to future readers after commit

**Contention Tests**:
- High read concurrency: No blocking, scalable throughput
- High write contention: WriteBusy errors, serialization
- Mixed read-write: Readers and writers proceed independently

### Property Tests

**Isolation Properties**:
- No dirty reads: No transaction reads uncommitted data
- No non-repeatable reads: Repeated reads return same value
- No lost updates: Single writer serializes all writes
- Readers never block: Reader always proceeds immediately

**State Machine Properties**:
- Multiple readers can exist simultaneously
- Only one writer can exist at a time
- Reader state independent of writer state
- Writer state independent of reader state

**Visibility Properties**:
- Reader visibility determined by snapshot txn_id
- Writer visibility includes own mutations
- Committed changes visible to future transactions
- Uncommitted changes not visible to other transactions

### Hardening Tests

**Stress Tests**:
- Many concurrent readers: System stable, no crashes
- Rapid writer retries: System stable, no deadlocks
- Long-running readers: Memory managed correctly, snapshots cleaned up
- Rapid reader churn: No resource leaks

**Crash Recovery Tests**:
- Crash during active read transaction: Recovery ignores uncommitted state
- Crash during active write transaction: Recovery replays WAL if commit record present
- Crash after commit: Changes durable, visible after recovery

**Fuzzing Tests**:
- Random read/write interleaving: Invariants maintained
- Random transaction durations: System stable
- Random commit/abort patterns: No resource leaks

## Rust Implementation Guidance

### RwLock Usage

**Db Struct with RwLock**:
```
use std::sync::RwLock;

pub struct Db {
    inner: RwLock<DbInner>,
    // Other fields...
}

pub struct DbInner {
    root_page_id: PageId,
    pager: Pager,
    wal: Wal,
    // Other fields...
}
```

**begin_read Implementation**:
```
impl Db {
    pub fn begin_read(&self) -> Result<ReadTxn, Error> {
        let read_guard = self.inner.read().map_err(|_| Error::LockPoisoned)?;
        let root_page_id = read_guard.root_page_id;
        let txn_id = read_guard.current_txn_id();

        Ok(ReadTxn {
            db: self,
            root_page_id,
            txn_id,
            _read_guard: read_guard, // Holds shared lock
        })
    }
}
```

**begin_write Implementation**:
```
impl Db {
    pub fn begin_write(&self) -> Result<WriteTxn, Error> {
        // Try to acquire write lock (non-blocking)
        let write_guard = self.inner.try_write()
            .map_err(|_| Error::WriteBusy)?;

        let root_page_id = write_guard.root_page_id;
        let txn_id = write_guard.allocate_txn_id();

        Ok(WriteTxn {
            db: self,
            txn_id,
            root_page_id,
            state: TransactionState::Active,
            pending_ops: HashMap::new(),
            _write_guard: write_guard, // Holds exclusive lock
        })
    }
}
```

### Transaction Lifetime Management

**ReadTxn with Read Guard**:
```
pub struct ReadTxn<'a> {
    db: &'a Db,
    root_page_id: PageId,
    txn_id: TransactionId,
    _read_guard: RwLockReadGuard<'a, DbInner>, // Underscore = held for drop
}
```

**WriteTxn with Write Guard**:
```
pub struct WriteTxn<'a> {
    db: &'a Db,
    txn_id: TransactionId,
    root_page_id: PageId,
    state: TransactionState,
    pending_ops: HashMap<Vec<u8>, (Mutation, usize)>,
    _write_guard: RwLockWriteGuard<'a, DbInner>, // Underscore = held for drop
}
```

**Drop Trait for Lock Release**:
```
impl<'a> Drop for ReadTxn<'a> {
    fn drop(&mut self) {
        // _read_guard dropped here, releasing shared lock
    }
}

impl<'a> Drop for WriteTxn<'a> {
    fn drop(&mut self) {
        // Implicit rollback if not committed
        if self.state != TransactionState::Committed {
            self.rollback_internal();
        }
        // _write_guard dropped here, releasing exclusive lock
    }
}
```

### Error Types

**WriteBusy Error**:
```
#[derive(Debug, thiserror::Error)]
#[error("Write transaction already active")]
pub struct WriteBusy;
```

**LockPoisoned Error**:
```
#[derive(Debug, thiserror::Error)]
#[error("Lock poisoned (panic while held)")]
pub struct LockPoisoned;
```

### Testing Implementation

**Concurrent Readers Test**:
```
#[test]
fn test_concurrent_readers() {
    let db = Db::open_in_memory();

    // Begin multiple readers
    let reader1 = db.begin_read().unwrap();
    let reader2 = db.begin_read().unwrap();
    let reader3 = db.begin_read().unwrap();

    // All readers active simultaneously
    assert!(reader1.is_active());
    assert!(reader2.is_active());
    assert!(reader3.is_active());

    // Readers can read concurrently
    // (In real test, use threads to verify parallelism)
}
```

**Single Writer Test**:
```
#[test]
fn test_single_writer() {
    let db = Db::open_in_memory();

    // First writer succeeds
    let writer1 = db.begin_write().unwrap();
    assert!(writer1.is_active());

    // Second writer fails with WriteBusy
    let result = db.begin_write();
    assert!(matches!(result, Err(Error::WriteBusy)));

    // Drop first writer, second writer succeeds
    drop(writer1);
    let writer2 = db.begin_write().unwrap();
    assert!(writer2.is_active());
}
```

**Read-Write Concurrency Test**:
```
#[test]
fn test_read_write_concurrency() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value0").unwrap();
        txn.commit().unwrap();
    }

    // Begin writer
    let mut writer = db.begin_write().unwrap();
    writer.put(b"key", b"value1").unwrap(); // Uncommitted

    // Begin reader during active writer
    let reader = db.begin_read().unwrap();

    // Reader sees old value (not writer's uncommitted mutation)
    assert_eq!(reader.get(b"key"), Some(b"value0".to_vec()));

    // Writer commits
    writer.commit().unwrap();

    // Reader still sees old value (snapshot isolation)
    assert_eq!(reader.get(b"key"), Some(b"value0".to_vec()));

    // New reader sees committed value
    let reader2 = db.begin_read().unwrap();
    assert_eq!(reader2.get(b"key"), Some(b"value1".to_vec()));
}
```

## Dependencies

- **Uses**:
  - ReadTxn type (concurrent readers)
  - WriteTxn type (single writer)
  - TransactionState type (state management)
  - TransactionId type (snapshot identification)
  - PageId type (root page for snapshots)
  - RwLock type (concurrency control)

- **Used By**:
  - Application code (concurrent transaction usage)
  - Transaction begin (lock acquisition)
  - Transaction commit/rollback (lock release)
  - Testing (concurrency scenarios)

## Related Specifications

- **Transaction Overview**: rust/04-txn-overview.md - ACID guarantees and isolation levels
- **Read Transaction**: rust/04-read-txn.md - Reader lifecycle and snapshots
- **Write Transaction**: rust/04-write-txn.md - Writer lifecycle and mutations
- **Transaction Begin**: rust/04-txn-begin.md - Lock acquisition and snapshot capture
- **Transaction State**: rust/04-txn-state.md - State machine and transitions
- **Semantics**: spec/semantics_v0.md - Concurrency model and isolation guarantees
