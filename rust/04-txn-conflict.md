# Transaction Conflict Detection

## Purpose

Conflict detection ensures transaction isolation and serializability by identifying when concurrent transactions interfere with each other. In NorthstarDB, conflict detection prevents anomalies like dirty writes, lost updates, and non-repeatable reads by validating transaction operations before commit. The conflict detection mechanism operates during the prepare phase of commit, checking whether mutations from the current transaction conflict with committed transactions from other writers. V0 uses a single-writer model that prevents write-write conflicts entirely, while future versions will support concurrent writers with sophisticated conflict detection and resolution strategies including retry with exponential backoff.

## Overview

### V0 Single-Writer Model

NorthstarDB V0 enforces a single-writer concurrency model where only one WriteTxn can exist at a time. This design eliminates write-write conflicts by preventing concurrent writers entirely. When an application attempts to begin a write transaction while another write transaction is active, the begin_write operation returns a WriteBusy error, indicating that the caller must retry later or abort the operation. The single-writer model simplifies the transaction system by removing the need for complex conflict detection logic while still providing snapshot isolation for concurrent readers.

### Future Multi-Writer Support

Future versions of NorthstarDB (Phase 7+) will support concurrent write transactions with full conflict detection. Multi-writer conflict detection will identify overlapping key ranges, detect write-write conflicts, and enforce serializability through validation during the prepare phase. Conflicts will be resolved through automatic retry with exponential backoff, transaction abort with error propagation, or optimistic concurrency control where conflicts are rare. The conflict detection system will be designed to extend naturally from the V0 single-writer foundation.

## V0 Single-Writer Conflict Prevention

### Single-Writer Enforcement

**Write Lock Mechanism**: Only one WriteTxn can exist at a time
- Write lock held for entire transaction lifetime
- begin_write acquires exclusive write lock
- commit or rollback releases write lock
- Next writer must wait for current writer to complete

**WriteBusy Error**: begin_write fails if writer already active
- Error returned immediately (no blocking)
- Caller must retry or abort
- No queuing or waiting for lock
- Application manages retry logic

**Rationale for Single-Writer**:
- Simplifies implementation (no conflict detection needed)
- Prevents write-write conflicts entirely
- Sufficient for many workloads (single-threaded or single-writer applications)
- Natural foundation for future multi-writer support

### V0 Conflict Categories

**Write-Write Conflicts**: Impossible in V0
- No concurrent writers exists
- Single-writer lock prevents overlapping write transactions
- No conflict detection required

**Read-Write Conflicts**: Prevented by snapshot isolation
- Readers use snapshots from before transaction began
- Writers do not affect active readers
- Readers never block writers
- Writers never block readers

**Phantom Conflicts**: Not applicable in V0
- No predicate locking (range queries not locked)
- Snapshot isolation prevents phantoms for existing keys
- Future versions may address phantom protection

### WriteBusy Error

**Error Type**: WriteBusy indicates writer already active

**When Returned**:
- Application calls begin_write while another WriteTxn exists
- Write lock is held by active transaction
- No blocking or waiting (fail-fast)

**Error Handling**:
```
match db.begin_write() {
    Ok(txn) => { /* Use transaction */ },
    Err(Error::WriteBusy) => {
        // Retry after delay
        sleep(Duration::from_millis(10));
        // Or abort operation
    },
    Err(e) => { /* Other errors */ },
}
```

**Application Responsibilities**:
- Implement retry logic with backoff
- Decide whether to retry or abort
- Manage retry delays and timeouts
- Handle WriteBusy errors gracefully

## Future Multi-Writer Conflict Detection

### Conflict Detection Overview

**Detection Timing**: Conflicts detected during prepare phase
- After all mutations buffered
- Before any writes to database
- Validation happens atomically
- Early detection before durability

**Detection Scope**: Check conflicts with transactions committed since snapshot
- Identify transactions committed after this transaction began
- Compare mutation sets for overlap
- Detect serializability violations
- Determine if retry needed

**Conflict Resolution**: Automatic retry or abort
- Retry: Begin new transaction, replay operations, retry commit
- Abort: Return error to application, let application decide
- Backoff: Exponential delay between retries
- Limits: Maximum retry attempts, timeout

### Write-Write Conflicts

**Definition**: Two transactions write to overlapping keys

**Conflict Detection Algorithm**:
1. Collect mutation keys from current transaction (all keys affected by put or delete)
2. Query transaction registry for transactions committed since snapshot
3. For each committed transaction, collect its mutation keys
4. Check for intersection between current keys and committed keys
5. If intersection exists, conflict detected

**Key Overlap Examples**:
- Transaction A: put("k1", "v1"), put("k2", "v2")
- Transaction B: put("k1", "v3"), delete("k3")
- Conflict: Both write to "k1"
- Resolution: One transaction must retry

**Non-Conflict Examples**:
- Transaction A: put("k1", "v1"), put("k2", "v2")
- Transaction B: put("k3", "v3"), put("k4", "v4")
- No conflict: Disjoint key sets
- Both can commit successfully

### Read-Write Conflicts

**Definition**: Transaction reads data that concurrent transaction modifies

**Snapshot Isolation Protection**: V0 prevents read-write conflicts
- Readers see snapshot from before transaction began
- Concurrent writes not visible to active readers
- Readers never block on writers
- Writers never block on readers

**Future Repeatable Read**: Detect when read key later modified
- Track keys read during transaction
- During prepare, check if read keys modified by committed transactions
- If modification detected, read-write conflict
- Transaction must retry to preserve repeatable read

**Example**:
```
Transaction A (txn_id=100): begin, get("k1") -> "v1", prepare
Transaction B (txn_id=101): begin, put("k1", "v2"), commit
Transaction A: Resume prepare, detect "k1" modified, conflict!
Transaction A: Rollback and retry
```

### Phantom Conflicts

**Definition**: Transaction reads range, concurrent transaction inserts key in range

**Predicate Locking**: Prevent phantoms by locking query ranges
- Scan operation locks range of keys scanned
- Insert into locked range detected as conflict
- Ensures repeatable range queries

**Future Implementation**:
- Track scan ranges during transaction
- During prepare, check if inserts fall within scanned ranges
- If insert detected, phantom conflict
- Transaction must retry

**Example**:
```
Transaction A: begin, scan("a" to "z") -> ["k1", "k2"], prepare
Transaction B: begin, put("k3", "v3"), commit
Transaction A: Resume prepare, detect "k3" in range, conflict!
Transaction A: Rollback and retry
```

## Conflict Detection Algorithm

### Prepare Phase Validation

**Step 1: Collect Transaction Mutations**
1. Iterate through pending_ops HashMap
2. Collect all keys from Put and Delete mutations
3. Store in local key set for conflict checking

**Step 2: Query Committed Transactions**
1. Query transaction registry for committed transactions
2. Filter to transactions with commit_lsn greater than snapshot LSN
3. These transactions committed after current transaction began
4. Collect mutation keys from each committed transaction

**Step 3: Detect Overlaps**
1. For each committed transaction's key set:
   - Compute intersection with current transaction's key set
   - If intersection non-empty, conflict detected
2. Collect all conflicting transactions
3. Determine conflict type (write-write, read-write, phantom)

**Step 4: Handle Conflicts**
1. If conflicts detected:
   - If retry policy allows: Rollback and signal retry
   - If retry exhausted: Abort with ConflictError
2. If no conflicts:
   - Proceed with commit (apply mutations, write WAL, update meta)

### Conflict Data Structures

**Mutation Key Set**: HashSet<Vec<u8>>
- Contains all keys mutated by transaction
- O(1) membership test for conflict detection
- Built from pending_ops during prepare

**Committed Transaction Registry**: HashMap<TransactionId, TransactionInfo>
- Tracks all committed transactions
- Contains mutation keys, commit LSN, snapshot LSN
- Queried during prepare for conflict detection

**Conflict Detection Result**: ConflictResult enum
- NoConflict: Proceed with commit
- ConflictDetected: Rollback and retry
- ConflictExhausted: Abort with error

## Retry Strategy

### Retry with Exponential Backoff

**Retry Policy Configuration**:
```
pub struct RetryPolicy {
    pub max_retries: usize,           // Maximum retry attempts (default: 5)
    pub initial_backoff_ms: u64,      // Initial delay (default: 10ms)
    pub max_backoff_ms: u64,          // Maximum delay (default: 1000ms)
    pub backoff_multiplier: f64,      // Backoff growth factor (default: 2.0)
}
```

**Exponential Backoff Algorithm**:
1. Start with initial_backoff_ms delay
2. After each retry, multiply delay by backoff_multiplier
3. Cap delay at max_backoff_ms
4. Wait for computed delay before retrying
5. Stop after max_retries attempts

**Backoff Sequence Example** (max_retries=5, initial=10ms, multiplier=2.0):
- Retry 1: Wait 10ms
- Retry 2: Wait 20ms
- Retry 3: Wait 40ms
- Retry 4: Wait 80ms
- Retry 5: Wait 160ms
- Total: 310ms over 5 retries

**Rationale for Exponential Backoff**:
- Gives conflicting transactions time to complete
- Reduces contention by spreading retry attempts
- Prevents retry storms (many transactions retrying simultaneously)
- Balances responsiveness (small initial delay) with persistence (exponential growth)

### Automatic Retry Logic

**Automatic Retry Flow**:
1. Application calls commit on transaction
2. During prepare, conflict detected
3. Transaction rolled back automatically
4. Wait for backoff delay
5. Begin new transaction
6. Replay all operations (put, delete, get)
7. Call commit again
8. Repeat until success or max_retries exhausted

**Replay Mechanism**:
- Transaction stores operation log (all puts, deletes)
- On retry, operations reapplied to new transaction
- get operations re-executed to validate state
- Application logic rerun transparently

**Limitations**:
- Replay must be deterministic (same operations in same order)
- External side effects (I/O, messages) may repeat
- Application must be idempotent for safe retry
- Non-deterministic operations prevent automatic retry

### Application-Managed Retry

**Manual Retry Pattern**:
```
let mut retries = 0;
loop {
    match db.begin_write() {
        Err(Error::WriteBusy) => {
            retries += 1;
            if retries >= MAX_RETRIES {
                return Err(Error::MaxRetriesExceeded);
            }
            sleep(backoff_delay(retries));
            continue;
        },
        Ok(mut txn) => {
            // Execute transaction logic
            txn.put(key, value)?;

            match txn.commit() {
                Err(Error::Conflict) => {
                    retries += 1;
                    if retries >= MAX_RETRIES {
                        return Err(Error::MaxRetriesExceeded);
                    }
                    sleep(backoff_delay(retries));
                    continue;
                },
                Ok(()) => return Ok(()),
                Err(e) => return Err(e),
            }
        }
    }
}
```

**Benefits of Manual Retry**:
- Application controls retry logic
- Can implement custom backoff strategies
- Can decide to abort based on business logic
- Can log and monitor retry attempts

**Drawbacks of Manual Retry**:
- More boilerplate code
- Error-prone (easy to forget retry logic)
- Inconsistent retry strategies across codebase

### Retry Limits and Timeouts

**Max Retries Limit**: Prevent infinite retry loops
- Default: 5 retry attempts
- Configurable per transaction or globally
- After limit, abort with MaxRetriesExceeded error
- Application must handle abort gracefully

**Timeout Mechanism**: Limit total transaction time
- Transaction timeout: Maximum duration for transaction+retries
- Retry timeout: Maximum duration spent retrying
- Abort on timeout to prevent starvation
- Application can decide to give up or continue

**Example Configuration**:
```
pub struct RetryConfig {
    pub max_retries: usize = 5,
    pub total_timeout_ms: u64 = 5000,   // 5 seconds total
    pub retry_timeout_ms: u64 = 1000,   // 1 second for retries
}
```

## Conflict Error Types

### ConflictError Enum

**Definition**: Structured error type for conflict scenarios

**Error Variants**:
```
pub enum ConflictError {
    WriteBusy,                    // V0: Writer already active
    WriteWriteConflict {           // Future: Concurrent writes to same key
        conflicting_txn_id: TransactionId,
        conflicting_keys: Vec<Vec<u8>>,
    },
    ReadWriteConflict {            // Future: Read key later modified
        conflicting_txn_id: TransactionId,
        modified_keys: Vec<Vec<u8>>,
    },
    PhantomConflict {              // Future: Range scan insert
        conflicting_txn_id: TransactionId,
        inserted_keys: Vec<Vec<u8>>,
        scan_range: (Vec<u8>, Vec<u8>),
    },
    SerializationFailure,          // Cannot serialize transactions
    MaxRetriesExceeded,           // Retry limit reached
    RetryTimeout,                 // Timeout during retry
}
```

### WriteBusy Error (V0)

**When Returned**: begin_write called while another WriteTxn active

**Error Information**: No additional context (simple boolean conflict)

**Handling Strategy**: Retry with delay
- Application must retry begin_write
- Recommended delay: 10-100ms
- No backoff needed (single failure, not persistent conflict)

**Example**:
```
loop {
    match db.begin_write() {
        Ok(txn) => break txn,
        Err(Error::WriteBusy) => {
            sleep(Duration::from_millis(10));
            continue;
        },
        Err(e) => return Err(e),
    }
}
```

### WriteWriteConflict Error (Future)

**When Returned**: prepare detects overlapping mutations with committed transaction

**Error Information**:
- conflicting_txn_id: ID of transaction that caused conflict
- conflicting_keys: List of keys that overlap

**Handling Strategy**: Automatic retry or manual abort
- Automatic: Transaction retried with new snapshot
- Manual: Application decides to abort or modify operations

**Example**:
```
match txn.commit() {
    Err(Error::Conflict(ConflictError::WriteWriteConflict { conflicting_txn_id, conflicting_keys })) => {
        log::warn!("Conflict with txn {} on keys {:?}", conflicting_txn_id, conflicting_keys);
        // Retry or abort
    },
    // ...
}
```

### SerializationFailure Error

**When Returned**: Cannot find serializable execution order

**Causes**:
- Cycle in serialization graph (transaction A waits for B, B waits for A)
- Too many conflicts preventing progress
- Deadlock in dependency graph

**Handling Strategy**: Abort with error
- Cannot automatically retry (deadlock)
- Application must resolve conflict
- May require changing transaction logic

## Performance Considerations

### Conflict Detection Overhead

**V0 Overhead**: Zero (no conflict detection)
- Single-writer prevents conflicts
- No validation needed during prepare
- Fast commit path

**Future Multi-Writer Overhead**: O(n × m) where n is committed transactions, m is mutations
- Build mutation key set: O(m)
- Query committed transactions: O(1) registry lookup
- Check intersections: O(n × m) worst case
- Optimizations: Indexing, Bloom filters, approximate checking

**Optimization Strategies**:
- Key indexing: Hash map for O(1) key lookup
- LSN range: Only check recent committed transactions
- Approximation: Bloom filter for fast negative checks
- Incremental validation: Check conflicts as mutations added (not just at prepare)

### Retry Storm Prevention

**Problem**: Many transactions conflicting simultaneously
- All transactions retry simultaneously
- Backoff not enough (all retry at same time)
- System thrashes, no progress

**Solutions**:
- Jittered backoff: Add random delay to exponential backoff
- Transaction prioritization: High priority transactions retry first
- Backoff cap: Limit maximum backoff to prevent long waits
- Admission control: Reject new transactions during high conflict

**Jittered Backoff Example**:
```
delay = base_delay * backoff_multiplier + random(0, base_delay / 2)
```

### Contention Hotspots

**Problem**: High conflict rate on popular keys
- Many transactions write same keys
- Conflicts common, retries frequent
- Throughput degraded

**Solutions**:
- Key partitioning: Divide hot keys across shards
- Batch operations: Reduce transaction count
- Application redesign: Reduce write contention
- Optimistic concurrency: Accept conflicts, retry efficiently

## Testing Requirements

### Unit Tests

**V0 Single-Writer Tests**:
- begin_write succeeds when no writer active
- begin_write returns WriteBusy when writer active
- commit releases write lock
- rollback releases write lock
- Next writer can begin after previous writer completes

**Conflict Detection Tests (Future)**:
- No conflict: Disjoint key sets commit successfully
- Write-write conflict: Overlapping keys detected, retry triggered
- Read-write conflict: Modified read key detected, retry triggered
- Phantom conflict: Range insert detected, retry triggered

**Retry Logic Tests**:
- Exponential backoff delays computed correctly
- Max retries enforced (abort after limit)
- Timeout enforced (abort after timeout)
- Jitter added to backoff (reduce retry storms)

### Integration Tests

**Concurrent Writer Tests**:
- Single writer: begin_write blocks second writer
- Writer completion: Second writer succeeds after first completes
- Writer rollback: Second writer succeeds after rollback

**Conflict Resolution Tests**:
- Retry success: Conflicting transaction retries and succeeds
- Retry failure: Conflicting transaction exhausts retries and aborts
- Multiple conflicts: Transaction survives multiple conflict cycles

**Performance Tests**:
- Low conflict rate: High throughput (few retries)
- High conflict rate: Lower throughput (many retries)
- Retry storm: System remains stable with jittered backoff

### Property Tests

**Idempotency Properties**:
- Same transaction retried produces same result
- Retry does not change transaction semantics

**Liveness Properties**:
- Eventually all transactions complete or abort
- No deadlock (with retry limits and timeouts)
- System makes progress even under high conflict

**Safety Properties**:
- No committed transactions conflict
- Serializability preserved
- No lost updates

### Hardening Tests

**Stress Tests**:
- Many concurrent writers: System stable
- High conflict rate: No livelock
- Retry storms: Jitter prevents synchronization

**Fuzzing Tests**:
- Random operation sequences: Conflict detection robust
- Random delays: Backoff logic correct
- Random conflict patterns: System handles all cases

## Rust Implementation Guidance

### V0 Single-Writer Implementation

**Write Lock Type**:
```
use std::sync::RwLock;

pub struct Db {
    inner: RwLock<DbInner>,
    // Other fields...
}
```

**begin_write Implementation**:
```
impl Db {
    pub fn begin_write(&self) -> Result<WriteTxn, Error> {
        // Try to acquire write lock
        let write_guard = self.inner.try_write()
            .map_err(|_| Error::WriteBusy)?;

        // Lock acquired, create transaction
        let txn = WriteTxn::new(self, write_guard);
        Ok(txn)
    }
}
```

**WriteBusy Error Definition**:
```
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Write transaction already active")]
    WriteBusy,

    // Other error variants...
}
```

### Future Conflict Detection Types

**ConflictError Enum**:
```
#[derive(Debug, thiserror::Error)]
pub enum ConflictError {
    #[error("Write transaction already active")]
    WriteBusy,

    #[error("Write-write conflict with txn {conflicting_txn_id} on keys: {conflicting_keys:?}")]
    WriteWriteConflict {
        conflicting_txn_id: TransactionId,
        conflicting_keys: Vec<Vec<u8>>,
    },

    #[error("Read-write conflict with txn {conflicting_txn_id}, keys modified: {modified_keys:?}")]
    ReadWriteConflict {
        conflicting_txn_id: TransactionId,
        modified_keys: Vec<Vec<u8>>,
    },

    #[error("Phantom conflict with txn {conflicting_txn_id}, scan range {:?} affected by inserts: {inserted_keys:?}")]
    PhantomConflict {
        conflicting_txn_id: TransactionId,
        scan_range: (Vec<u8>, Vec<u8>),
        inserted_keys: Vec<Vec<u8>>,
    },

    #[error("Serialization failure: cannot find serializable order")]
    SerializationFailure,

    #[error("Maximum retries ({0}) exceeded")]
    MaxRetriesExceeded(usize),

    #[error("Retry timeout after {0}ms")]
    RetryTimeout(u64),
}
```

**RetryPolicy Configuration**:
```
#[derive(Debug, Clone)]
pub struct RetryPolicy {
    pub max_retries: usize,
    pub initial_backoff_ms: u64,
    pub max_backoff_ms: u64,
    pub backoff_multiplier: f64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_retries: 5,
            initial_backoff_ms: 10,
            max_backoff_ms: 1000,
            backoff_multiplier: 2.0,
        }
    }
}
```

**Exponential Backoff Implementation**:
```
impl RetryPolicy {
    pub fn backoff_delay(&self, retry_attempt: usize) -> Duration {
        let base_ms = self.initial_backoff_ms;
        let delay_ms = (base_ms as f64 * self.backoff_multiplier.powi(retry_attempt as i32))
            .min(self.max_backoff_ms as f64) as u64;
        Duration::from_millis(delay_ms)
    }

    pub fn should_retry(&self, retry_attempt: usize) -> bool {
        retry_attempt < self.max_retries
    }
}
```

**Conflict Detection Function (Future)**:
```
impl WriteTxn {
    fn detect_conflicts(&self) -> Result<(), ConflictError> {
        // Collect mutation keys
        let mutation_keys: HashSet<Vec<u8>> = self.pending_ops.keys().cloned().collect();

        // Query committed transactions since snapshot
        let committed_txns = self.db.registry.get_committed_since(self.snapshot_lsn);

        // Check for conflicts
        for committed_txn in committed_txns {
            if let Some(conflict) = self.check_key_overlap(&mutation_keys, &committed_txn.keys) {
                return Err(ConflictError::WriteWriteConflict {
                    conflicting_txn_id: committed_txn.txn_id,
                    conflicting_keys: conflict,
                });
            }
        }

        Ok(())
    }

    fn check_key_overlap(&self, keys1: &HashSet<Vec<u8>>, keys2: &HashSet<Vec<u8>>) -> Option<Vec<Vec<u8>>> {
        let overlap: Vec<Vec<u8>> = keys1.intersection(keys2).cloned().collect();
        if overlap.is_empty() {
            None
        } else {
            Some(overlap)
        }
    }
}
```

### Automatic Retry Implementation (Future)

**Retry Loop**:
```
impl Db {
    pub fn write_with_retry<F, R>(&self, ops: F) -> Result<R, Error>
    where
        F: Fn(&mut WriteTxn) -> Result<R, Error>,
    {
        let policy = RetryPolicy::default();
        let mut retry_count = 0;

        loop {
            // Try to begin transaction
            let mut txn = match self.begin_write() {
                Ok(txn) => txn,
                Err(Error::WriteBusy) => {
                    if !policy.should_retry(retry_count) {
                        return Err(Error::Conflict(ConflictError::MaxRetriesExceeded(retry_count)));
                    }
                    let delay = policy.backoff_delay(retry_count);
                    sleep(delay);
                    retry_count += 1;
                    continue;
                },
                Err(e) => return Err(e),
            };

            // Execute operations
            let result = ops(&mut txn);

            // Try to commit
            match txn.commit() {
                Ok(()) => return result,
                Err(Error::Conflict(conflict)) => {
                    if !policy.should_retry(retry_count) {
                        return Err(Error::Conflict(conflict));
                    }
                    let delay = policy.backoff_delay(retry_count);
                    sleep(delay);
                    retry_count += 1;
                    continue;
                },
                Err(e) => return Err(e),
            }
        }
    }
}
```

**Usage Example**:
```
// Automatic retry with exponential backoff
db.write_with_retry(|txn| {
    txn.put(b"key1", b"value1")?;
    txn.put(b"key2", b"value2")?;
    txn.commit()
})?;
```

### Testing Implementation

**V0 WriteBusy Test**:
```
#[test]
fn test_write_busy() {
    let db = Db::open_in_memory();

    // First writer succeeds
    let txn1 = db.begin_write().unwrap();
    assert!(txn1.is_active());

    // Second writer fails with WriteBusy
    let result = db.begin_write();
    assert_eq!(result, Err(Error::WriteBusy));

    // Drop first writer, second writer succeeds
    drop(txn1);
    let txn2 = db.begin_write().unwrap();
    assert!(txn2.is_active());
}
```

**Conflict Detection Test (Future)**:
```
#[test]
fn test_write_write_conflict() {
    let db = Db::open_in_memory();

    // Transaction A begins and commits
    let mut txn_a = db.begin_write().unwrap();
    txn_a.put(b"key", b"value_a").unwrap();
    txn_a.commit().unwrap();

    // Transaction B begins and tries to commit same key
    let mut txn_b = db.begin_write().unwrap();
    txn_b.put(b"key", b"value_b").unwrap();
    let result = txn_b.commit();

    // Should detect conflict
    assert!(matches!(result, Err(Error::Conflict(ConflictError::WriteWriteConflict { .. }))));
}
```

**Retry Test (Future)**:
```
#[test]
fn test_retry_success() {
    let db = Db::open_in_memory();
    let policy = RetryPolicy { max_retries: 3, ..Default::default() };

    let retry_count = Arc::new(AtomicUsize::new(0));
    let retry_count_clone = retry_count.clone();

    db.write_with_retry_policy(&policy, |txn| {
        retry_count_clone.fetch_add(1, Ordering::SeqCst);
        txn.put(b"key", b"value")?;
        txn.commit()
    }).unwrap();

    // Should succeed after some retries
    assert!(retry_count.load(Ordering::SeqCst) <= policy.max_retries);
}
```

## Dependencies

- **Uses**:
  - WriteTxn type (transaction operations)
  - TransactionContext type (state and mutations)
  - TransactionState type (prepare phase)
  - TransactionId type (conflict reporting)
  - PendingOpsMap type (mutation keys)
  - Error types (WriteBusy, ConflictError)
  - RetryPolicy type (retry configuration)

- **Used By**:
  - begin_write (V0 single-writer enforcement)
  - commit (prepare phase conflict detection)
  - Application code (retry logic)
  - Testing (conflict injection)

## Related Specifications

- **Transaction Overview**: rust/04-txn-overview.md - ACID guarantees and concurrency model
- **WriteTxn**: rust/04-write-txn.md - Write transaction structure
- **Transaction Begin**: rust/04-txn-begin.md - Write lock acquisition
- **Transaction Commit**: rust/04-txn-commit.md - Prepare phase and conflict detection
- **Transaction Rollback**: rust/04-txn-rollback.md - Rollback on conflict
- **Semantics**: spec/semantics_v0.md - V0 single-writer model
