# MVCC Isolation Guarantees

## Purpose

MVCC isolation guarantees define the consistency properties that transactions can expect when operating concurrently in NorthstarDB. The isolation level determines which anomalies are prevented and which phenomena are allowed, directly affecting application correctness and behavior. NorthstarDB implements Snapshot Isolation with additional guarantees that prevent most concurrency anomalies while enabling high parallelism. This specification describes the isolation model, anomaly prevention mechanisms, guarantees provided, and phenomena that applications may encounter under concurrent workloads.

## Core Concepts

### Isolation Levels Overview

Database isolation levels define the degree to which concurrent transactions interfere with each other. The ANSI SQL standard defines four isolation levels, but real-world systems often implement variants that provide different guarantees. NorthstarDB V0 implements Snapshot Isolation with specific characteristics:

**Snapshot Isolation (SI)**: Each transaction reads from a consistent snapshot as of its start time
- Readers see only data committed before their transaction began
- Writers create new versions without overwriting current versions
- First-committer-wins for concurrent writes (single-writer in V0)
- Prevents dirty reads, non-repeatable reads, and lost updates
- Allows write skew in certain patterns

**NorthstarDB V0 Isolation Characteristics**:
- Single-writer concurrency eliminates write-write conflicts
- Snapshot-based reads provide repeatable reads
- MVCC versioning prevents dirty reads
- Serializability not guaranteed (write skew possible)
- Read-your-writes guaranteed for write transactions

### Isolation Guarantee Mechanisms

NorthstarDB provides isolation guarantees through multiple coordinated mechanisms:

**Snapshot Time**: Transaction ID at begin defines the visible universe
- Immutable snapshot for entire transaction lifetime
- Transaction ID comparison determines visibility
- Monotonic transaction IDs provide natural ordering

**Version Chains**: Multiple versions of each page coexist
- Older versions retained for active snapshots
- New versions created by writes
- Visibility calculation selects correct version

**Single Writer**: Only one WriteTxn can exist at a time
- Write lock prevents concurrent writers
- Eliminates write-write conflict detection
- Simplifies isolation enforcement

**Commit Atomicity**: Changes become visible atomically at commit
- All modifications applied simultaneously
- Root page ID update makes snapshot visible
- No intermediate states visible to other transactions

## Isolation Guarantees

### Guaranteed Properties

NorthstarDB V0 provides the following isolation guarantees to all transactions:

**Atomic Visibility**: Transactions see all-or-nothing of committed transactions
- A transaction is either fully visible or fully invisible
- No partial updates visible from concurrent transactions
- Committed transaction becomes visible atomically when its ID is registered

**Repeatable Reads**: Data read multiple times in a transaction never changes
- Snapshot is immutable after transaction begin
- Same query returns same results throughout transaction
- Concurrent modifications do not affect in-progress reads

**Read-Your-Writes**: Write transactions see their own modifications
- Read operations in WriteTxn see uncommitted changes
- Subsequent reads observe earlier writes in same transaction
- Enables read-modify-write patterns within transaction

**No Dirty Reads**: Uncommitted data never visible to other transactions
- Only committed transactions can be visible
- In-flight transactions never visible to snapshots
- Aborted transactions never become visible

**No Lost Updates**: Concurrent writes to same key do not overwrite each other
- Single-writer lock prevents concurrent writes
- Last committer wins with explicit serialization
- No write-write conflicts possible in V0

**Monotonic Reads**: Later transactions see all data seen by earlier transactions
- Transaction IDs are monotonically increasing
- Higher transaction IDs include all modifications from lower IDs
- Time always moves forward, never backward

### Isolation Level Formalization

NorthstarDB V0 provides isolation between Read Committed and Serializable:

**Stronger Than Read Committed**: Prevents non-repeatable reads
- Read Committed allows data to change between reads
- Snapshot Isolation guarantees repeatable reads
- Each read sees same snapshot throughout transaction

**Stronger Than Repeatable Read**: Prevents phantom reads for existing keys
- Repeatable Read allows phantoms in range queries
- Snapshot Isolation prevents phantoms for existing data
- Range scan results are stable for existing keys

**Weaker Than Serializable**: Allows write skew anomalies
- Serializable prevents all serialization anomalies
- Snapshot Isolation allows certain write skew patterns
- Two concurrent transactions may produce unserializable outcome

**Formal Guarantees**:
- All transactions read from a consistent snapshot at begin time
- Write transactions see their own writes in addition to snapshot
- No transaction observes uncommitted data from other transactions
- Concurrent non-overlapping write transactions serialize correctly
- Concurrent overlapping write transactions prevented (V0 single-writer)

## Anomaly Prevention

### Prevented Anomalies

NorthstarDB V0 prevents the following standard database anomalies:

**Dirty Reads**: Reading uncommitted data from another transaction
- Definition: Transaction T1 reads data written by T2 before T2 commits
- Prevention: Only committed transactions are visible to snapshots
- Mechanism: Visibility check requires committed transaction status
- Result: Dirty reads impossible in NorthstarDB

**Non-Repeatable Reads**: Data changes between reads in same transaction
- Definition: Transaction T1 reads key K, then reads K again and gets different value
- Prevention: Snapshot is immutable for entire transaction lifetime
- Mechanism: All reads use same root_page_id from transaction begin
- Result: Non-repeatable reads impossible in NorthstarDB

**Lost Updates**: Concurrent write transactions overwrite each other
- Definition: T1 and T2 both read K=5, T1 writes K=6, T2 writes K=7, final value 7 loses T1's update
- Prevention: Single-writer lock serializes write transactions
- Mechanism: Only one WriteTxn can exist at a time
- Result: Lost updates impossible in NorthstarDB V0

**Read Skew**: Inconsistent view of related items
- Definition: T1 reads X=10 and Y=10 (sum=20), T2 updates X=5 and Y=5 (sum=10), T1 reads X=5 (now sum=15)
- Prevention: Snapshot isolation provides consistent point-in-time view
- Mechanism: All reads see same snapshot, cannot see partial updates
- Result: Read skew prevented (all data from same point in time)

### Partially Prevented Anomalies

**Phantom Reads**: New keys appear in range scans
- Definition: T1 scans range [A, C], T2 inserts key B, T1 scans again and sees B
- NorthstarDB V0: Phantoms prevented for existing keys, new key inserts may appear in historical snapshots if snapshot time predates insert
- Mechanism: Snapshot sees all keys committed before snapshot time, including later-inserted keys if committed before snapshot
- Limitation: Range queries may see keys that were inserted after the snapshot time but before the scan
- Result: Phantoms possible for range scans but not for point operations on existing keys

### Allowed Anomalies

NorthstarDB V0 allows the following anomaly under specific concurrent patterns:

**Write Skew**: Concurrent updates to different keys based on same read
- Definition: T1 and T2 both read X=10 and Y=10, invariant X+Y >= 20, T1 updates X=5, T2 updates Y=5, both commit, final state X=5, Y=5 violates invariant
- Allowed in V0: Single-writer model prevents this specific pattern
- Multi-writer future: Write skew will be possible with Snapshot Isolation
- Prevention: Application-level constraints or serializable isolation level
- Result: Not applicable in V0 (single-writer prevents concurrency), future multi-writer may allow

## Isolation Semantics by Operation

### Read Transaction Isolation

**Begin Read**: Captures snapshot at current transaction ID
- Acquires shared lock on database
- Registers snapshot with current root_page_id
- All subsequent reads use this snapshot
- Never blocks other readers (shared lock)

**Get Operation**: Point lookup within snapshot
- Reads from B+tree at snapshot's root_page_id
- Returns value as of snapshot time
- Same key always returns same value (repeatable read)
- Unaffected by concurrent writes

**Range Scan**: Iterates over key range in snapshot
- Traverses B+tree from snapshot's root_page_id
- Returns all keys in range committed before snapshot
- Results are stable and repeatable
- Ordering consistent with snapshot

**End Read**: Releases snapshot and shared lock
- Decrement snapshot reference count
- Release shared lock
- Snapshot may be garbage collected later
- No side effects on database state

### Write Transaction Isolation

**Begin Write**: Acquires exclusive write lock
- Blocks if another writer active (WriteBusy error)
- Creates WriteTxn with read-your-writes semantics
- Snapshot includes all committed data
- No other writers can start during transaction

**Put Operation**: Creates new version of page
- Modifies B+tree in-place
- New page version tagged with transaction ID
- Read operations in same transaction see new version
- Other transactions do not see change until commit

**Get Operation**: Reads with write visibility
- Reads from B+tree including uncommitted modifications
- Sees values written earlier in same transaction
- Sees committed values from snapshot for unmodified keys
- Read-your-writes guarantee satisfied

**Delete Operation**: Marks key as deleted in new version
- Creates new page version with key removed
- Delete visible to subsequent reads in same transaction
- Not visible to other transactions until commit
- Tombstone may be added for tracking

**Commit Operation**: Atomically makes changes visible
- Writes commit record to WAL
- Updates snapshot registry with new root_page_id
- Releases exclusive write lock
- Changes become visible to future transactions

**Rollback Operation**: Discards all changes
- Discards modified page versions
- Does not update snapshot registry
- Releases exclusive write lock
- No changes become visible to any transaction

## Concurrent Operation Examples

### Example 1: Concurrent Readers

Two read transactions operating simultaneously:

**Timeline**:
- T1 (txn_id=100) begins read, captures snapshot
- T2 (txn_id=101) begins read, captures snapshot
- T1 reads key A, sees value as of txn_id=100
- T2 reads key A, sees value as of txn_id=101
- T1 reads key A again, same value as first read (repeatable)
- T2 reads key A again, same value as first read (repeatable)
- T1 ends read
- T2 ends read

**Guarantees**:
- T1 never sees data from transactions >100
- T2 never sees data from transactions >101
- T1 and T2 do not interfere with each other
- Both see consistent, repeatable data
- Neither blocks the other

### Example 2: Read During Write

Read transaction overlapping with write transaction:

**Timeline**:
- T1 (txn_id=100) begins read, captures snapshot
- T2 (txn_id=101) begins write, acquires write lock
- T1 reads key A, sees value as of txn_id=100
- T2 writes key A = new_value
- T2 reads key A, sees new_value (read-your-writes)
- T1 reads key A again, still sees old value (repeatable read)
- T2 commits, changes become visible at txn_id=101
- T1 reads key A again, still sees old value (snapshot immutable)
- T1 ends read
- Future transactions with txn_id >101 see new_value

**Guarantees**:
- T1 never sees T2's uncommitted write (no dirty read)
- T1 sees same value for A throughout transaction (repeatable read)
- T2 sees its own write (read-your-writes)
- T1's snapshot not affected by concurrent write
- T1 and T2 do not block each other

### Example 3: Write During Read Attempt

Write transaction prevents new write, allows reads:

**Timeline**:
- T1 (txn_id=100) begins write, acquires write lock
- Application attempts T2 begin_write
- begin_write returns WriteBusy error (T1 still active)
- Application begins read T3 (txn_id=100 for same snapshot)
- T1 writes key A = value1
- T3 reads key A, sees value as of txn_id=100 (before T1's write)
- T1 commits, changes visible at txn_id=101
- T3 continues, still sees snapshot at txn_id=100
- Application retries begin_write after T1 commits
- T2 (txn_id=102) begins write successfully

**Guarantees**:
- Only one write transaction at a time (single-writer)
- Read transactions can begin during write (use snapshot before write)
- Write prevents subsequent writes until commit
- Readers not blocked by writer
- Writer not blocked by readers

### Example 4: Concurrent Non-Overlapping Writes

Sequential writes with no key overlap:

**Timeline**:
- T1 (txn_id=100) begins write, acquires write lock
- T1 writes key A = value1
- T1 commits, releases write lock
- T2 (txn_id=101) begins write, acquires write lock
- T2 writes key B = value2
- T2 commits, releases write lock
- T3 (txn_id=102) begins read
- T3 reads key A, sees value1
- T3 reads key B, sees value2

**Guarantees**:
- Writes serialize correctly (T1 then T2)
- No lost updates (different keys, no conflict anyway)
- Both writes visible to future transactions
- Consistent snapshot includes both writes

### Example 5: Time-Travel Query

Read transaction explicitly requesting historical snapshot:

**Timeline**:
- T1 (txn_id=100) begins write
- T1 writes key A = value1
- T1 commits at txn_id=100
- T2 (txn_id=101) begins write
- T2 writes key A = value2
- T2 commits at txn_id=101
- Application requests snapshot at txn_id=100
- T3 begins read with explicit snapshot txn_id=100
- T3 reads key A, sees value1 (historical state)
- T4 begins read with current snapshot (txn_id=102)
- T4 reads key A, sees value2 (current state)

**Guarantees**:
- Historical snapshots remain accessible after cleanup policy
- Time-travel queries see past database state
- Current and historical queries do not interfere
- Cleanup respects retention policy and active references

## Isolation Testing

### Test Scenarios

Isolation guarantees must be validated through comprehensive testing:

**Repeatable Read Test**:
- Begin read transaction
- Read key K, record value
- Spawn concurrent transaction that writes K
- Wait for concurrent transaction to commit
- Read key K again in original transaction
- Assert both reads returned same value

**No Dirty Read Test**:
- Begin write transaction
- Write key K but do not commit
- Spawn concurrent read transaction
- Concurrent read attempts to get key K
- Assert read does not see uncommitted value
- Commit original write
- Spawn new read transaction
- Assert new read sees committed value

**Read-Your-Writes Test**:
- Begin write transaction
- Write key K = value1
- Read key K in same transaction
- Assert read returns value1
- Write key K = value2
- Read key K again
- Assert read returns value2
- Commit transaction

**Single-Writer Test**:
- Begin write transaction T1
- Spawn thread that attempts begin_write
- Assert begin_write returns WriteBusy
- Commit T1
- Retry begin_write in spawned thread
- Assert second begin_write succeeds

**Snapshot Consistency Test**:
- Begin read transaction T1, record snapshot txn_id
- Perform multiple writes in concurrent transaction T2
- Commit T2, record new txn_id
- In T1, read various keys
- Assert all reads return values from txn_id, not T2's txn_id
- Begin new read transaction T3
- Assert T3 sees T2's writes

## Rust Implementation Guidance

### Visibility Check Implementation

Visibility checking uses transaction ID comparison:

```rust
fn is_visible(txn_id: u64, snapshot_txn_id: u64) -> bool {
    // Invalid transaction never visible
    if txn_id == 0 {
        return false;
    }
    // Transaction committed after snapshot not visible
    if txn_id > snapshot_txn_id {
        return false;
    }
    // Transaction committed at or before snapshot is visible
    true
}
```

### Snapshot State Management

Maintain immutable snapshot references:

```rust
struct Snapshot {
    txn_id: u64,
    root_page_id: u64,
}
```

Each read transaction holds a snapshot that never changes, ensuring repeatable reads.

### Write Lock Implementation

Use RwLock for single-writer, multiple-reader concurrency:

```rust
struct Db {
    write_lock: RwLock<()>,
}

fn begin_read(&self) -> Result<ReadTxn> {
    let _guard = self.write_lock.read();
    // Capture snapshot, create ReadTxn
}

fn begin_write(&self) -> Result<WriteTxn> {
    // Try acquire write lock, return WriteBusy if fails
    match self.write_lock.try_write() {
        Some(guard) => Ok(/* create WriteTxn */),
        None => Err(Error::WriteBusy),
    }
}
```

### Read-Your-Writes Tracking

Write transactions track their own modifications:

```rust
struct WriteTxn {
    snapshot: Snapshot,
    pending_writes: HashMap<Vec<u8>, Vec<u8>>,
}

fn get(&self, key: &[u8]) -> Option<&[u8]> {
    // Check pending writes first (read-your-writes)
    if let Some(value) = self.pending_writes.get(key) {
        return Some(value);
    }
    // Fall back to snapshot read
    self.snapshot.get(key)
}
```

### Commit Atomicity

Ensure atomic snapshot registration:

```rust
fn commit(mut self) -> Result<()> {
    // Write commit record to WAL
    self.wal.append_commit_record(self.txn_id, self.root_page_id)?;
    // Flush WAL
    self.wal.flush()?;
    // Register snapshot (atomic)
    self.snapshot_registry.register(self.txn_id, self.root_page_id)?;
    // Release write lock
    drop(self.write_lock_guard);
    Ok(())
}
```

The WAL flush before snapshot registration ensures crash safety: if crash occurs before registration, transaction is not visible.

## Limitations and Future Work

### V0 Limitations

NorthstarDB V0 isolation has known limitations:

**No Concurrent Writers**: Only one write transaction at a time
- Limits write throughput
- Applications must handle WriteBusy errors
- Natural stepping stone to multi-writer support

**Write Skew Possible**: Not serializable in all cases
- Concurrent updates to different keys may violate invariants
- Application must enforce constraints or use locking
- Future serializable isolation level needed for strict correctness

**Phantom Protection Limited**: Range queries may see new keys
- Predicate locking not implemented
- Phantoms possible for range scans
- Future index-based phantom prevention needed

### Future Multi-Writer Isolation

Future versions will extend isolation guarantees:

**Concurrent Writers**: Multiple write transactions with conflict detection
- Detect write-write conflicts during prepare phase
- Automatic retry with exponential backoff
- Serializable isolation level option

**Serializable Snapshot Isolation (SSI)**: Prevent write skew
- Track read and write sets
- Detect dangerous structures
- Abort transactions that would violate serializability

**Predicate Locking**: Prevent phantoms in range queries
- Lock key ranges during scans
- Check conflicts on inserts
- Serializable range queries

## Summary

NorthstarDB V0 provides Snapshot Isolation with single-writer concurrency:

**Guarantees**:
- No dirty reads
- No non-repeatable reads
- No lost updates
- Read-your-writes for write transactions
- Repeatable reads for all transactions
- Monotonic reads

**Prevents**:
- Dirty reads (uncommitted data never visible)
- Non-repeatable reads (snapshot immutable)
- Lost updates (single-writer serialization)
- Read skew (consistent point-in-time view)

**Allows**:
- Write skew (not applicable in V0 single-writer)
- Phantoms (limited for range scans)
- Only one concurrent writer

**Implementation**:
- Transaction ID comparison for visibility
- Immutable snapshots for repeatable reads
- RwLock for reader-writer concurrency
- WAL flush before snapshot registration for atomicity
- Reference counting for snapshot lifecycle

**Testing**:
- Repeatable read scenarios
- Dirty read prevention
- Read-your-writes verification
- Single-writer enforcement
- Snapshot consistency validation
