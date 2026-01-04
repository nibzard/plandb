# Transaction Rollback Operation

## Purpose

The Rollback operation aborts an active transaction, discarding all pending mutations and releasing all resources held by the transaction. Rollback is the safety mechanism that ensures atomicity by preventing partial application of mutations. Rollback can be invoked explicitly by the application via the rollback() method or implicitly when the WriteTxn is dropped (goes out of scope). The rollback operation guarantees that no mutations become visible to other transactions, all resources are cleaned up, the write lock is released, and the transaction state transitions to Aborted. Rollback is idempotent, meaning multiple calls to rollback are safe and have no additional effect beyond the first rollback.

## Overview

### WriteTxn.rollback()

WriteTxn.rollback() explicitly aborts an active transaction, discarding all staged mutations and releasing all resources. Rollback can be called at any point during the transaction lifecycle, including before any mutations, after some mutations, or even during a failed commit operation. The rollback operation ensures that no changes become permanent, no resources are leaked, and the database state remains unchanged from before the transaction began. Rollback transitions the transaction state to Aborted and invalidates the transaction handle, preventing any further operations.

### Implicit Rollback via Drop

WriteTxn implements the Drop trait to provide automatic rollback when the transaction goes out of scope without explicit commit or rollback. This implicit rollback provides a safety net, ensuring that uncommitted transactions are automatically aborted even if the application forgets to call rollback or panics. The Drop implementation performs the same cleanup as explicit rollback but cannot return errors, relying on Rust's drop guarantees to ensure cleanup completes.

### Rollback from Failed Commit

Rollback may be called as part of error handling during a failed commit operation. If commit fails at any phase, the transaction may be left in an indeterminate state with some durable writes (WAL records, meta page updates). Rollback from commit errors does not undo durable writes (they remain for crash recovery), but it does release in-memory resources and invalidates the transaction handle. This ensures that recovery can replay or rollback the durable state consistently.

## Explicit Rollback Operation

### Purpose

Explicitly abort a transaction, discarding all pending mutations and releasing all resources.

### Signature

```
WriteTxn.rollback(&mut self) -> Result<(), Error>
```

### Return Value

**Ok(())**: Transaction successfully rolled back
- All pending mutations discarded
- All resources released
- Transaction state transitioned to Aborted
- Transaction handle invalidated

**Err(Error)**: Rollback failed (should not happen in practice)
- Transaction may be partially cleaned up
- Resources may not be fully released
- Transaction state undefined (should be treated as aborted)

**Note**: Rollback should not fail in practice. The Error return type is for consistency with other operations and extreme edge cases (e.g., filesystem errors during cleanup that cannot be recovered from).

### Algorithm

#### Step 1: State Validation

1. **Check Current State**: Verify transaction state
   - If state is Aborted, return Ok(()) immediately (idempotency)
   - If state is Committed, return InvalidState error (cannot rollback committed transaction)
   - If state is Active or Preparing, proceed with rollback

#### Step 2: Clear Mutation Buffer

2. **Discard Pending Mutations**: Clear all mutations from pending_ops
   - Drop all Put and Delete mutations in buffer
   - Mutations never applied to database (atomicity preserved)
   - HashMap cleared, all owned key-value data dropped
   - Rust's Drop trait frees mutation memory automatically

3. **Reset Size Tracking**: Set total_mutation_size to zero
   - All mutation bytes discarded
   - Size tracking reset to initial state

4. **Reset Mutation Count**: Set mutation_count to zero
   - No mutations remain in buffer
   - Count reset to initial state

#### Step 3: Release Write Lock

5. **Release Writer Lock**: Release exclusive access to database
   - Lock held since begin_write
   - Allows next write transaction to proceed
   - Prevents deadlock from abandoned transactions
   - Lock release is infallible (always succeeds)

#### Step 4: Invalidate Transaction Handle

6. **Transition State**: Set transaction.state to TransactionState::Aborted
   - Terminal state (no further transitions possible)
   - Prevents any further operations on this transaction
   - State change indicates transaction completed without commit

7. **Clear Transaction Context**: Drop TransactionContext reference
   - Transaction data released
   - Context cleaned up by Rust's Drop trait

#### Step 5: Update Metrics

8. **Record Rollback**: Update transaction metrics
   - Increment rollback_count in database metrics
   - Record timestamp for performance monitoring
   - Track rollback reason (explicit vs implicit vs error)

#### Step 6: Return Success

9. **Return Ok(())**: Indicate successful rollback
- Transaction fully cleaned up
- All resources released
- No mutations applied to database
- Database state unchanged

### State Transitions

**From Active State**:
- Transaction accepting mutations
- Rollback transitions: Active → Aborted
- All mutations in buffer discarded
- Write lock released
- Normal rollback path

**From Preparing State** (commit in progress):
- Transaction in first phase of commit
- Mutations may be serialized to WAL
- Rollback transitions: Preparing → Aborted
- Pending mutations cleared
- WAL records remain (durable, ignored during recovery)
- Write lock released
- Recovery will ignore uncommitted WAL records

**From Committed State**:
- Transaction already committed
- Rollback returns InvalidState error
- Cannot rollback committed transaction
- State is terminal (no rollback possible)

**From Aborted State**:
- Transaction already rolled back
- Rollback returns Ok(()) immediately (idempotency)
- No state change
- No additional cleanup needed

## Implicit Rollback via Drop

### Purpose

Automatically rollback transaction when WriteTxn goes out of scope without explicit commit or rollback.

### Trigger Conditions

**Scope Exit**: WriteTxn dropped when variable goes out of scope
```
{
    let mut txn = db.begin_write()?;
    txn.put(b"key", b"value")?;
    // Scope ends without commit or rollback
    // Drop trait called, implicit rollback executed
} // txn dropped here
```

**Early Return**: Function returns before commit
```
fn update_data(db: &Db) -> Result<()> {
    let mut txn = db.begin_write()?;
    txn.put(b"key", b"value")?;
    if some_condition {
        return Ok(()); // Early return, txn dropped, rollback executed
    }
    txn.commit()?;
    Ok(())
}
```

**Panic**: Transaction not explicitly committed before panic
- Panic unwinding drops all stack variables
- WriteTxn Drop trait executed during unwind
- Rollback cleanup performed (best-effort)

**Override Commit**: If commit called before drop, Drop detects this
- Transaction state is Committed
- Drop implementation checks state before rolling back
- No rollback performed if already committed

### Drop Implementation Algorithm

1. **Check Transaction State**:
   - If state is Committed, return immediately (no rollback needed)
   - If state is Aborted, return immediately (already rolled back)
   - If state is Active or Preparing, proceed with rollback

2. **Perform Rollback**: Execute rollback logic
   - Clear mutation buffer
   - Reset size tracking
   - Release write lock
   - Transition state to Aborted

3. **Ignore Errors**: Drop cannot return errors
   - Cleanup best-effort (should always succeed)
   - Errors logged but not propagated
   - Resource cleanup prioritized

### Drop Guarantees

**Cleanup Execution**: Rust guarantees Drop runs even on panic
- Panic unwinding drops all stack variables
- Drop trait executed during unwind
- Rollback cleanup performed before stack cleanup

**No Double Rollback**: Drop checks state before rolling back
- If explicit rollback already called, state is Aborted
- Drop detects Aborted state, returns immediately
- No double cleanup, no use-after-free

**Commit Override**: If commit succeeded, Drop does nothing
- Transaction state is Committed after successful commit
- Drop detects Committed state, returns immediately
- No rollback of committed transaction

### Drop vs Explicit Rollback

**Explicit Rollback**:
- Application calls rollback() directly
- Can return errors (though rare)
- Application can handle rollback errors
- Explicit intent, clearer code

**Implicit Rollback (Drop)**:
- Automatic cleanup on scope exit
- Cannot return errors
- Best-effort cleanup (should always succeed)
- Safety net for forgotten rollback

**Recommendation**: Use explicit rollback for clarity and error handling
- Explicit rollback makes intent clear
- Errors can be handled appropriately
- Drop still provides safety net if explicit rollback forgotten

## Rollback from Failed Commit

### Commit Failure Scenarios

**Prepare Phase Failure**:
- Conflict detected during validation
- Mutation count or size limits exceeded
- WAL append failed (disk error)
- Transaction state: Active (not yet prepared)
- Rollback: Normal rollback from Active state

**Apply Phase Failure**:
- B+tree operation failed (corruption, allocation failure)
- Page write failed (I/O error)
- Transaction state: Preparing (WAL written, B+tree apply failed)
- Rollback: Clear mutation buffer, leave WAL records for recovery

**Meta Phase Failure**:
- Meta page write failed (I/O error)
- Database sync failed (fsync error)
- Transaction state: Preparing (WAL and B+tree applied, meta not updated)
- Rollback: Leave durable state (WAL, B+tree), release resources

**Finalize Phase Failure**:
- Snapshot registration failed
- Transaction state: Preparing (all durable writes complete, finalization failed)
- Rollback: Transaction considered committed (durable writes present)

### Rollback Strategy for Durable State

**Principle**: Do not undo durable writes during rollback
- Durable writes (WAL, B+tree pages, meta page) remain on disk
- Rollback only clears in-memory state and releases resources
- Crash recovery will determine transaction fate from durable state

**Rationale**:
- Undoing durable writes is complex and error-prone
- WAL records may be partially written (cannot safely truncate)
- B+tree pages may be partially written (cannot safely revert)
- Recovery process designed to handle partial commit state

**Recovery Handling**:
- Uncommitted WAL records: Ignored during recovery (no valid commit record)
- Committed WAL records: Replayed during recovery to rebuild state
- Orphaned B+tree pages: Cleaned up by page allocator
- Meta page inconsistency: Detected and corrected by recovery

### Rollback Algorithm from Commit Error

1. **Clear Mutation Buffer**: Discard all pending mutations
   - In-memory mutations no longer needed
   - Durable state (WAL, B+tree) contains mutation data

2. **Release Write Lock**: Allow next transaction to proceed
   - Prevents deadlock from failed transaction
   - Other transactions can make progress

3. **Transition State**: Set state to Aborted
   - Even if durable writes present, transaction aborted from application perspective
   - Recovery determines actual fate from durable state

4. **Return Error**: Propagate commit error to caller
   - Application aware of commit failure
   - Application can retry or handle error

5. **Do NOT Modify Durable State**: No attempt to undo WAL, B+tree, or meta writes
   - Durable state left as-is for recovery
   - Recovery process handles consistency

## Resource Cleanup

### Mutation Buffer Cleanup

**HashMap Drop**:
- pending_ops HashMap dropped
- All key-value pairs dropped
- Rust's Drop trait frees all owned Vec<u8> data
- No memory leaks

**Mutation Counters**:
- mutation_count reset to zero
- total_mutation_size reset to zero
- No residual tracking state

### Transaction Context Cleanup

**TransactionContext Drop**:
- Context reference dropped
- Rust's reference counting handles cleanup if shared
- No manual memory management

**Transaction Metrics**:
- Metrics recorded before cleanup
- Database statistics updated
- Performance data preserved

### Write Lock Release

**Lock Release Mechanism**:
- RwLock write guard dropped
- Lock automatically released
- Next write transaction can acquire lock
- No deadlock from abandoned transactions

**Lock Release Guarantees**:
- Release always succeeds (infallible)
- Cannot fail (no I/O or external dependencies)
- Rust type system ensures guard dropped

### Transaction Handle Invalidation

**State Transition to Aborted**:
- Transaction enters terminal state
- No further operations possible
- Any subsequent operation returns InvalidState error

**Handle Lifetime**:
- Transaction variable may still exist (not dropped)
- But transaction is invalid (state is Aborted)
- Operations on invalid transaction return errors

**Preventing Use-After-Rollback**:
- State check on every operation
- InvalidState error for operations after rollback
- Compiler cannot prevent use-after-rollback (runtime check)

## Idempotency

### Definition

Rollback is idempotent: calling rollback multiple times has the same effect as calling once.

### Idempotency Implementation

**First Rollback**:
- State transition: Active → Aborted
- Mutation buffer cleared
- Write lock released
- Resources cleaned up
- Returns Ok(())

**Second Rollback**:
- State check: Already Aborted
- Returns Ok(()) immediately
- No state change
- No additional cleanup
- No errors

**Subsequent Rollbacks**:
- Same as second rollback
- Always return Ok(())
- Always safe to call

### Idempotency Benefits

**Defensive Programming**: Application can call rollback multiple times safely
- No need to track if rollback already called
- No double-free or use-after-free issues
- Simplifies error handling

**Drop Compatibility**: Drop trait can call rollback safely
- If explicit rollback already called, Drop detects Aborted state
- Drop returns immediately, no double cleanup
- Explicit and implicit rollback coexist safely

**Retry Logic**: Application can retry operations with rollback in error path
- First error handler calls rollback
- Second error handler also calls rollback (defensive)
- Both succeed, no problems

## Error Handling

### Rollback Success

**Ok(())**: Rollback completed successfully
- All mutations discarded
- All resources released
- Transaction state is Aborted
- No changes to database

### Rollback Failure (Theoretical)

**Err(Error)**: Rollback failed (should not happen)
- Possible causes: Filesystem errors during cleanup (extremely rare)
- Transaction state may be partially cleaned up
- Resources may not be fully released
- Database state may be inconsistent

**Handling Rollback Failure**:
- Log error for debugging
- Treat transaction as aborted (cannot continue)
- Application may need to restart database
- Consider this a catastrophic error

### Invalid State Errors

**Rollback Committed Transaction**:
- Error: InvalidState
- When: Application calls rollback after successful commit
- Handling: Application logic error (commit should be final operation)
- Recovery: Transaction already committed, no rollback possible

**Commit After Rollback**:
- Error: InvalidState
- When: Application calls commit after rollback
- Handling: Application should check transaction state before commit
- Recovery: Begin new transaction and retry operations

## Concurrency Considerations

### Single-Writer Lock Release

**Lock Release During Rollback**:
- Write lock held during transaction lifetime
- Rollback releases lock
- Next write transaction can proceed immediately
- No deadlock from abandoned transactions

**Lock Ordering**:
- Acquired during begin_write
- Released during rollback or commit
- Always released (even on panic via Drop)
- Guarantees forward progress

### Reader Isolation

**Readers Unaffected by Rollback**:
- Readers use snapshots from before transaction began
- Rollback does not affect existing snapshots
- Readers continue until snapshot released
- New readers see pre-transaction state

**No Visibility to Rolled Back Mutations**:
- Pending mutations never visible to other transactions
- Rollback discards mutations before any visibility
- Other transactions see database state as if transaction never happened

### Concurrent Writer Blocking

**Writer Blocking During Transaction**:
- Only one write transaction at a time
- Next writer waits for current transaction to complete
- Rollback releases writer lock
- Next writer unblocked and can proceed

**No Writer Starvation**:
- Rollback always releases lock
- Lock not held indefinitely
- Fair lock acquisition (FIFO)
- All writers eventually make progress

## Performance Characteristics

### Time Complexity

**Mutation Buffer Cleanup**:
- HashMap drop: O(n) where n is mutation count
- Each mutation dropped: O(1) per mutation
- Overall: O(n) for dropping all mutations

**Lock Release**:
- RwLock write guard drop: O(1)
- Atomic operation, very fast

**State Transition**:
- State variable assignment: O(1)
- Single atomic write

**Overall Rollback Complexity**: O(n) where n is mutation count
- Dominated by mutation buffer cleanup
- Dropping mutations is fast (memory freed)
- No disk I/O (mutations never written to database)

### Space Complexity

**Memory Reclamation**:
- All mutation memory freed during rollback
- HashMap capacity freed
- Key and value vectors freed
- Transaction context freed

**Memory Overhead During Rollback**:
- Temporary: Drop trait executes, freeing memory
- No additional allocation during rollback
- Memory usage decreases during rollback

### Comparison with Commit

**Rollback vs Commit Performance**:
- Rollback: O(n) memory operations, no disk I/O
- Commit: O(n) memory operations plus disk I/O (WAL, B+tree, meta, fsync)
- Rollback much faster than commit (no disk writes)
- Trade-off: Commit provides durability, rollback provides atomicity

## Testing Requirements

### Unit Tests

**Basic Rollback Tests**:
- rollback after single put: Mutation discarded
- rollback after multiple puts: All mutations discarded
- rollback after delete: Tombstone discarded
- rollback after mixed puts and deletes: All discarded
- rollback returns Ok on success

**Idempotency Tests**:
- rollback called twice: Second call is no-op
- rollback called multiple times: All return Ok
- rollback after explicit rollback: Returns Ok immediately
- drop after explicit rollback: Does nothing (state already Aborted)

**State Validation Tests**:
- rollback in Active state: Succeeds, transitions to Aborted
- rollback in Preparing state: Succeeds, transitions to Aborted
- rollback in Committed state: Returns InvalidState error
- rollback in Aborted state: Returns Ok immediately (idempotency)

**Resource Cleanup Tests**:
- rollback releases write lock: Next transaction can begin
- rollback clears mutation buffer: Buffer empty after rollback
- rollback resets size tracking: Size zero after rollback
- rollback resets mutation count: Count zero after rollback

**Implicit Rollback Tests**:
- drop without commit: Implicit rollback executed
- drop after explicit rollback: No double rollback
- drop after commit: No rollback (state Committed)
- drop during panic: Rollback executed during unwind

**Database State Tests**:
- rollback after put: Key not in database
- rollback after delete: Key still in database (delete not applied)
- rollback after scan: Database unchanged
- commit then query: Committed data visible, rolled back data not visible

### Integration Tests

**Transaction Workflow Tests**:
- begin, rollback: No mutations applied
- begin, put, rollback: Mutation discarded
- begin, put, commit, rollback (error): Rollback rejected (InvalidState)
- begin, put, rollback, query: Data not in database

**Error Handling Tests**:
- rollback from commit error: Durable state remains, resources released
- rollback from prepare phase: Normal rollback
- rollback from apply phase: WAL records remain
- rollback from meta phase: WAL and B+tree remain

**Concurrent Transaction Tests**:
- rollback while readers active: Readers unaffected
- rollback while next writer waiting: Next writer unblocked
- rapid rollback cycles: No deadlocks, no resource leaks

### Property Tests

**Idempotency Properties**:
- rollback after rollback has same effect as single rollback
- State is Aborted after first rollback
- Subsequent rollbacks do not change state

**Atomicity Properties**:
- After rollback, database state unchanged from before transaction
- No partial mutations visible
- All mutations or none visible (none in case of rollback)

**Resource Cleanup Properties**:
- After rollback, write lock released
- After rollback, mutation buffer empty
- After rollback, transaction state is Aborted

**State Machine Properties**:
- rollback from Active or Preparing transitions to Aborted
- rollback from Aborted is no-op
- rollback from Committed returns error

### Hardening Tests

**Stress Tests**:
- Many mutations then rollback: All discarded, no leaks
- Rapid rollback cycles: System stable
- Large mutations then rollback: Memory freed

**Crash Recovery Tests**:
- Rollback before crash: No recovery needed (no durable state)
- Crash during rollback (unlikely): Recovery cleans up any partial state

**Panic Tests**:
- Panic during transaction: Drop ensures rollback
- Panic during rollback (unlikely): Cleanup best-effort

## Rust Implementation Guidance

### Explicit Rollback Method

**Function Signature**:
```
impl<'a> WriteTxn<'a> {
    pub fn rollback(&mut self) -> Result<(), Error> {
        // Implementation follows algorithm described above
    }
}
```

**Key Implementation Steps**:
1. Check self.txn_ctx.state
2. If Aborted, return Ok(()) immediately (idempotency)
3. If Committed, return InvalidState error
4. Clear self.pending_ops (HashMap cleared by Rust)
5. Reset self.total_mutation_size to 0
6. Reset self.mutation_count to 0
7. Release write lock (drop guard)
8. Set self.txn_ctx.state to TransactionState::Aborted
9. Update metrics
10. Return Ok(())

**Error Handling Pattern**:
```
match txn.rollback() {
    Ok(()) => { /* Transaction rolled back */ },
    Err(Error::InvalidState) => { /* Already committed or invalid state */ },
    Err(e) => { /* Catastrophic error, log and possibly restart */ },
}
```

### Drop Trait Implementation

**Drop Signature**:
```
impl<'a> Drop for WriteTxn<'a> {
    fn drop(&mut self) {
        // Check state, rollback if needed
        // Cannot return errors (drop signature)
    }
}
```

**Drop Implementation**:
```
impl<'a> Drop for WriteTxn<'a> {
    fn drop(&mut self) {
        // Only rollback if not already committed or aborted
        if self.txn_ctx.state == TransactionState::Active ||
           self.txn_ctx.state == TransactionState::Preparing {
            // Perform rollback (best-effort, ignore errors)
            let _ = self.rollback_internal();
        }
        // If already Committed or Aborted, do nothing
    }
}
```

**Internal Rollback (Used by Both)**:
```
impl<'a> WriteTxn<'a> {
    fn rollback_internal(&mut self) -> Result<(), Error> {
        // Same logic as public rollback
        // Called by both rollback() and Drop
    }

    pub fn rollback(&mut self) -> Result<(), Error> {
        self.rollback_internal()
    }
}
```

### State Management

**TransactionState Enum**:
```
pub enum TransactionState {
    Active,
    Preparing,
    Committed,
    Aborted,
}
```

**State Check Pattern**:
```
match self.txn_ctx.state {
    TransactionState::Aborted => return Ok(()), // Idempotency
    TransactionState::Committed => return Err(Error::InvalidState),
    TransactionState::Active | TransactionState::Preparing => {
        // Proceed with rollback
    }
}
```

### Resource Cleanup

**Automatic Cleanup via Rust**:
```
// HashMap cleared automatically when dropped
self.pending_ops = HashMap::new(); // Explicit clear or let Drop handle it

// Write guard dropped automatically
// Write lock released when guard dropped

// Transaction context dropped automatically
```

**Explicit Cleanup (Optional)**:
```
// Clear mutation buffer explicitly
self.pending_ops.clear();
self.total_mutation_size = 0;
self.mutation_count = 0;

// Note: Rust Drop trait also handles cleanup
// Explicit clear is optional but makes intent clear
```

### Write Lock Management

**Lock Guard Pattern**:
```
struct WriteTxn<'a> {
    db: &'a Db,
    _write_guard: RwLockWriteGuard<'a, DbInner>, // underscore = no direct access
    // Other fields...
}
```

**Automatic Lock Release**:
- _write_guard field holds write lock
- Guard dropped when WriteTxn dropped
- Lock automatically released on guard drop
- No manual lock release needed

### Idempotency Implementation

**State Check for Idempotency**:
```
pub fn rollback(&mut self) -> Result<(), Error> {
    // Check if already rolled back
    if self.txn_ctx.state == TransactionState::Aborted {
        return Ok(()); // Idempotent: already rolled back
    }

    // Perform rollback...
    self.txn_ctx.state = TransactionState::Aborted;
    Ok(())
}
```

### Metrics and Observability

**Track Rollback Operations**:
```
// In rollback method
self.db.metrics.rollback_count += 1;
self.db.metrics.last_rollback_timestamp = Some(timestamp());

// Track rollback reason
match reason {
    RollbackReason::Explicit => { /* ... */ },
    RollbackReason::Implicit => { /* ... */ },
    RollbackReason::Error => { /* ... */ },
}
```

### Testing Implementation

**Unit Test Example**:
```
#[test]
fn test_rollback_basic() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.put(b"key", b"value").unwrap();
    assert_eq!(txn.mutation_count(), 1);

    txn.rollback().unwrap();

    // Verify mutation cleared
    // Verify lock released (can begin new transaction)
    let mut txn2 = db.begin_write().unwrap(); // Should succeed
}
```

**Idempotency Test Example**:
```
#[test]
fn test_rollback_idempotent() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.put(b"key", b"value").unwrap();

    txn.rollback().unwrap();
    txn.rollback().unwrap(); // Second rollback: no-op
    txn.rollback().unwrap(); // Third rollback: no-op

    // All succeed, no errors
}
```

**Implicit Rollback Test Example**:
```
#[test]
fn test_implicit_rollback() {
    let db = Db::open_in_memory();

    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        // txn dropped here without commit or rollback
    } // Drop trait executed

    // Verify data not in database
    let reader = db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), None);
}
```

**Rollback After Commit Error Test**:
```
#[test]
fn test_rollback_from_commit_error() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.put(b"key", b"value").unwrap();

    // Simulate commit error (e.g., inject failure)
    // Commit should fail, rollback resources
    let result = txn.commit();
    assert!(result.is_err());

    // Transaction should be aborted (or in error state)
    // Resources released, can begin new transaction
    let mut txn2 = db.begin_write().unwrap(); // Should succeed
}
```

## Dependencies

- **Uses**:
  - WriteTxn type (transaction operations)
  - TransactionContext type (state management)
  - TransactionState type (state transitions)
  - PendingOpsMap type (mutation buffer)
  - RwLockWriteGuard type (write lock management)
  - Error types (InvalidState error)

- **Used By**:
  - Application code (explicit abort)
  - Drop trait (implicit rollback)
  - Commit error handling (rollback from failure)
  - Testing (cleanup between tests)

## Related Specifications

- **WriteTxn**: rust/04-write-txn.md - Write transaction structure and mutation tracking
- **Transaction Commit**: rust/04-txn-commit.md - Commit operation and rollback from commit errors
- **TransactionContext**: rust/04-txn-context.md - Transaction state and lifecycle
- **Transaction Begin**: rust/04-txn-begin.md - Transaction initialization and lock acquisition
- **Semantics**: spec/semantics_v0.md - ACID atomicity guarantees
