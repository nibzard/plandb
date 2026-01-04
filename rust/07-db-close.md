# Database Close Process

## Purpose

This document describes the complete database shutdown sequence, including explicit close via API call, implicit close via Drop trait, resource cleanup, transaction termination, and persistence guarantees. The close process ensures all data is safely persisted, resources are properly released, and the database is left in a consistent state for future reopening.

## Close Process Overview

### High-Level Steps

**1. Close Initiation**: Either explicit db.close() call or implicit Drop
**2. State Validation**: Check if already closed, verify no active operations
**3. Operation Drain**: Wait for in-flight operations to complete
**4. Final Checkpoint**: Flush dirty pages and truncate WAL
**5. Transaction Cleanup**: Rollback any active write transaction
**6. Component Shutdown**: Close Pager, WAL, B+Tree, SnapshotRegistry
**7. File Handle Release**: Close database and WAL file handles
**8. File Lock Release**: Release exclusive file lock
**9. State Update**: Mark database as closed (is_open = false)
**10. Resource Cleanup**: Drop all Arc references and free memory

### Close Triggers

**Explicit Close**: Application calls db.close()
- Immediate shutdown initiation
- Returns Result<(), Error> (can fail)
- Allows application to handle close errors
- Recommended for graceful shutdown

**Implicit Close**: Db handle dropped (RAII)
- Automatic cleanup when Db goes out of scope
- Cannot return errors (panic on serious errors)
- Fallback for resource cleanup
- May log errors but cannot propagate them

## Detailed Close Algorithm

### Step 1: Close Initiation and State Validation

**Purpose**: Determine close type and validate current state

**Steps**:
1. Check if already closed (is_open == false)
2. If already closed, return Ok(()) immediately (idempotent)
3. Acquire exclusive lock on DbInner (blocks all operations)
4. Check is_open again (double-checked locking)

**State Validation**:
- is_open == true → Proceed with close
- is_open == false → Return Ok(()) (already closed)
- Lock acquisition timeout → Return Error::LockTimeout

**Error Conditions**:
- LockTimeout: Cannot acquire exclusive lock within timeout
- Note: Other threads may hold shared locks (readers) or exclusive locks (writer)

**Implementation Notes**:
- Use RwLock::try_write_for() with timeout (e.g., 30 seconds)
- Double-check is_open after acquiring lock (another thread may have closed)
- Idempotent: Multiple close() calls are safe

### Step 2: Operation Drain

**Purpose**: Wait for in-flight operations to complete

**Steps**:
1. Check for active write transaction (write_lock is_locked)
2. If write transaction active:
   a. Log warning (write transaction not committed/rolled back)
   b. Force rollback of write transaction
   c. Discard all mutations
   d. Release write_lock
3. Check for active read transactions (via stats.active_readers)
4. Wait for active readers to complete (optional, with timeout)
5. If timeout, proceed with close (readers will encounter DatabaseClosed error)

**Write Transaction Rollback**:
- Discard mutation buffer
- Release write_lock Mutex
- Update stats (transactions_rolled_back += 1)
- Do NOT write rollback record to WAL (transaction never committed)

**Read Transaction Handling**:
- Option A: Wait for readers to finish (graceful)
  - Use condition variable or timeout loop
  - Check stats.active_readers == 0
  - Timeout after 30 seconds
- Option B: Proceed immediately (forceful)
  - Readers will get DatabaseClosed error on next operation
  - Resources cleaned up when readers drop
  - Faster close, but rude to active readers

**Implementation Choice**:
- Use Option A (wait with timeout) for explicit close()
- Use Option B (forceful) for implicit Drop (cannot wait indefinitely)

**Error Conditions**:
- LockTimeout: Cannot force rollback write transaction
- Note: Close proceeds even if readers still active (after timeout)

### Step 3: Final Checkpoint

**Purpose**: Ensure all dirty pages are flushed and WAL is truncated

**Steps**:
1. Check if WAL has uncheckpointed records
2. If WAL non-empty:
   a. Trigger checkpoint operation
   b. Flush all dirty pages to database file
   c. Truncate WAL to empty
   d. Update meta page with current root page ID
   e. Sync database file (fsync)
3. If WAL empty, skip checkpoint

**Checkpoint Operation**:
- Call Pager::checkpoint() to flush dirty pages
- Call Wal::truncate() to empty WAL file
- Call Pager::update_meta_page() to persist current state
- Call Pager::sync() to fsync database file

**Error Handling**:
- Checkpoint failure → Log error, continue close (best-effort)
- WAL truncate failure → Log error, continue close
- Meta page update failure → Return Err(Error) (critical)
- File sync failure → Return Err(Error) (critical)

**Persistence Guarantees**:
- All committed transactions persisted before close returns
- WAL empty after successful close
- Meta page reflects latest database state
- Database file in consistent state for reopening

**See**: 02-pager-flush.md for detailed checkpoint specification

### Step 4: Component Shutdown

**Purpose**: Shutdown all components in reverse dependency order

**Shutdown Order** (reverse of initialization):
1. B+Tree (no explicit shutdown, drop reference)
2. SnapshotRegistry (persist state if needed, drop reference)
3. WAL (close file handle, truncate if needed)
4. Pager (flush cache, close file handle)

**Component Cleanup**:

**B+Tree**:
- No explicit shutdown (no owned resources)
- Drop BTree reference (Arc::clone drops to 0)
- No persistence needed (state in Pager pages)

**SnapshotRegistry**:
- Optional: Persist registry to disk for faster open
- Drop Arc<RwLock<SnapshotRegistry>> reference
- If persistence enabled, serialize to file before drop

**WAL**:
- Call Wal::close() to:
  a. Sync WAL file (if non-empty)
  b. Close WAL file handle
  c. Release WAL internal locks
- Drop Arc<Wal> reference

**Pager**:
- Call Pager::close() to:
  a. Flush all dirty pages (if not checkpointed)
  b. Drop cache (free memory)
  c. Sync database file
  d. Close database file handle
  e. Release Pager internal locks
- Drop Arc<Pager> reference

**Error Conditions**:
- WAL close failure → Log error, continue
- Pager close failure → Return Err(Error) (critical)
- File sync failure → Return Err(Error) (critical)

### Step 5: File Handle Release

**Purpose**: Close all file handles

**Steps**:
1. Close WAL file handle (done in WAL::close())
2. Close database file handle (done in Pager::close())
3. Verify all file handles closed

**File Handle Types**:
- Database file: std::fs::File
- WAL file: std::fs::File
- Lock file: (optional) fs2::FileLock

**Error Conditions**:
- File handle close failure (OS error) → Log error, continue
- OS will cleanup file handles on process exit

### Step 6: File Lock Release

**Purpose**: Release exclusive file lock, allowing other processes to open database

**Steps**:
1. Drop FileLock object (or call unlock())
2. OS releases file lock immediately
3. Database file available for other processes

**File Lock Behavior**:
- Lock released automatically when FileLock dropped
- OS guarantees lock cleanup on process exit
- No other process can acquire lock until released

**Platform-Specific**:
- Unix: flock lock released on close
- Windows: LockFileEx lock released on close
- Cross-platform: fs2 crate handles cleanup

### Step 7: State Update

**Purpose**: Mark database as closed, prevent future operations

**Steps**:
1. Set is_open.store(false, Ordering::SeqCst)
2. Release exclusive lock on DbInner
3. Log database closed event

**State Transition**:
- is_open: true → false (one-way transition, never reopen)
- Database handle exists but operations return DatabaseClosed error
- Resources released, handles invalid

### Step 8: Resource Cleanup

**Purpose**: Free all memory and Arc references

**Steps**:
1. Drop DbInner (all component Arcs)
2. Arc reference counts decrement
3. If reference count reaches 0, components dropped
4. Memory freed

**Arc Reference Cleanup**:
- DbInner dropped
- Arc<Pager>, Arc<Wal>, Arc<RwLock<SnapshotRegistry>> dropped
- If Db is the last owner, components fully dropped
- Memory freed to allocator

**Note**: This step happens automatically when DbInner is dropped

### Step 9: Return Success

**Purpose**: Indicate close completed successfully

**Return Value**: Ok(())

**Post-Conditions**:
- Database is closed (is_open == false)
- All file handles closed
- File lock released
- Memory freed
- Future operations return DatabaseClosed error

## Close Methods

### Db::close()

**Description**: Explicit close method

**Signature**:
```rust
pub fn close(&self) -> Result<(), Error>
```

**Behavior**:
- Acquires exclusive lock on DbInner (blocking)
- Waits for in-flight operations (with timeout)
- Performs final checkpoint
- Closes all components
- Releases file lock
- Sets is_open to false
- Returns Ok(()) on success, Err(Error) on failure

**Error Conditions**:
- LockTimeout: Cannot acquire exclusive lock
- IoError: File sync or close failed
- ChecksumError: Checksum validation during checkpoint
- DatabaseClosed: Already closed (returns Ok(()), not error)

**Example**:
```rust
let db = Db::open("mydb.ndb")?;
// ... use database ...
db.close()?;  // Explicit close, handle errors
```

**Use Cases**:
- Graceful shutdown (handle errors)
- Explicit resource cleanup
- Ensure data persisted before exit
- Close before moving/deleting database file

### Db::drop()

**Description**: Implicit close via Drop trait

**Signature**:
```rust
impl Drop for Db {
    fn drop(&mut self) {
        // Attempt close, log errors, cannot propagate
    }
}
```

**Behavior**:
- Checks if already closed (is_open == false)
- If not closed, attempts close
- Logs errors but cannot return them
- Forceful close (does not wait for readers)
- Best-effort resource cleanup

**Error Handling**:
- Errors logged only (e.g., eprintln! or log::error)
- Cannot panic (except for serious bugs)
- Cannot return Result (Drop trait)

**Example**:
```rust
{
    let db = Db::open("mydb.ndb")?;
    // ... use database ...
}  // db.drop() called automatically here
```

**Use Cases**:
- RAII cleanup (automatic on scope exit)
- Fallback when application forgets to call close()
- Emergency cleanup during panic/unwind

**Important**: Prefer explicit close() for error handling

## Close Scenarios

### Scenario 1: Normal Close (No Active Transactions)

**Steps**:
1. Application calls db.close()
2. Acquire exclusive lock (immediate)
3. is_open == true, proceed
4. No active transactions, skip drain
5. Perform final checkpoint
6. Close components (WAL, Pager)
7. Release file lock
8. Set is_open = false
9. Return Ok(())

**Duration**: ~100ms (checkpoint flush)
**Result**: Clean close, all data persisted

### Scenario 2: Close with Active Write Transaction

**Steps**:
1. Application calls db.close()
2. Acquire exclusive lock (waits for write lock release)
3. is_open == true, proceed
4. Active write transaction detected
5. Force rollback write transaction:
   - Discard mutations
   - Release write_lock
   - Log warning
6. Perform final checkpoint
7. Close components
8. Release file lock
9. Set is_open = false
10. Return Ok(())

**Duration**: ~100ms + wait for write lock
**Result**: Write transaction rolled back, data lost

### Scenario 3: Close with Active Read Transactions

**Steps**:
1. Application calls db.close()
2. Acquire exclusive lock (blocks until readers release shared locks)
3. Wait up to 30 seconds for readers to finish
4. Log warning if readers still active
5. Proceed with close (forceful)
6. Close components
7. Release file lock
8. Set is_open = false
9. Return Ok(())
10. Readers encounter DatabaseClosed error on next operation

**Duration**: Up to 30 seconds waiting for readers
**Result**: Readers error out, database closed

### Scenario 4: Close During Checkpoint

**Steps**:
1. Auto-checkpoint in progress (background thread)
2. Application calls db.close()
3. Acquire exclusive lock (waits for checkpoint to complete)
4. Checkpoint completes
5. Close proceeds (skip redundant checkpoint)
6. Close components
7. Release file lock
8. Set is_open = false
9. Return Ok(())

**Duration**: Checkpoint time + close time
**Result**: Clean close, checkpoint completed

### Scenario 5: Close After Panic

**Steps**:
1. Thread panics during transaction
2. Write transaction lock released (Mutex guard dropped)
3. Db handle still valid (other threads unaffected)
4. Application calls db.close() (or Drop)
5. Proceed with normal close (panic already handled)
6. Close components
7. Release file lock
8. Set is_open = false
9. Return Ok(())

**Duration**: Normal close time
**Result**: Clean close, panic isolated

### Scenario 6: Implicit Close (Drop)

**Steps**:
1. Db handle goes out of scope
2. Rust calls db.drop()
3. Check if already closed
4. If not closed, attempt close:
   a. Acquire exclusive lock (try_lock, no wait)
   b. If lock unavailable, log warning, return (cannot block in Drop)
   c. Force rollback active write transaction
   d. Skip waiting for readers (forceful close)
   e. Best-effort checkpoint (may fail silently)
   f. Close components (may fail silently)
   g. Release file lock
   h. Set is_open = false
5. Log any errors

**Duration**: Immediate (no waiting)
**Result**: Best-effort close, errors logged

## Resource Cleanup Details

### Memory Cleanup

**Cache Memory**:
- Pager cache dropped (Vec<Page> or LRU map)
- All page allocations freed
- Memory returned to allocator

**Transaction State**:
- Write transaction mutation buffer dropped
- Read transaction snapshot metadata dropped
- All allocations freed

**Component State**:
- B+Tree state dropped (no owned allocations)
- SnapshotRegistry dropped (freed)
- WAL state dropped (buffers freed)

**Arc Reference Counts**:
- DbInner: Decrements to 0, dropped
- Pager: Decrements, may drop if last reference
- WAL: Decrements, may drop if last reference
- SnapshotRegistry: Decrements, may drop if last reference

### File Handle Cleanup

**Database File**:
- std::fs::File closed
- OS releases file descriptor
- Directory entry persisted

**WAL File**:
- std::fs::File closed
- OS releases file descriptor
- WAL file persists (empty after checkpoint)

**Lock File** (if used):
- FileLock dropped
- OS releases lock
- Lock file may be deleted (optional)

### Thread Cleanup

**Background Threads** (if any):
- Auto-checkpoint thread (future feature)
- Flusher thread (if using background flush)
- Threads signaled to stop
- Threads joined on close
- Thread resources freed

**Note**: Current design has no background threads (all operations synchronous)

## Error Handling

### Close Errors

**LockTimeout**: Cannot acquire exclusive lock
- Cause: Another thread holding lock indefinitely
- Action: Wait longer or use forceful close
- Result: Close fails, database remains open
- Recovery: Retry close or terminate process

**IoError::SyncFailed**: File sync failed
- Cause: Disk error, filesystem issue
- Action: Log error, continue close (best-effort)
- Result: Data may not be fully persisted
- Recovery: Check filesystem, run recovery on next open

**IoError::CloseFailed**: File handle close failed
- Cause: OS error, file handle issue
- Action: Log error, continue close
- Result: OS will cleanup on process exit
- Recovery: OS cleanup on exit

**ChecksumError**: Checksum validation failed during checkpoint
- Cause: Data corruption
- Action: Log error, abort close
- Result: Close fails, database remains open
- Recovery: Investigate corruption, restore from backup

### Error Propagation

**Explicit Close (db.close())**:
- All errors returned as Result<(), Error>
- Application can handle errors appropriately
- May retry close, abort, or terminate

**Implicit Close (Drop)**:
- Errors logged only (eprintln!, log::error)
- Cannot return Result (Drop trait limitation)
- Best-effort cleanup
- Application cannot handle errors

## Persistence Guarantees

### Before Close Returns

**On Successful Close (Ok(()))**:
- All committed transactions persisted to database file
- WAL truncated to empty
- Meta page updated with current root page ID
- Database file synced (fsync)
- Database in consistent state
- Safe to reopen immediately

**On Failed Close (Err(Error))**:
- Some data may not be persisted
- WAL may not be truncated
- Database may be in intermediate state
- Recovery required on next open
- May need to restore from backup

### Crash Before Close

**If Application Crashes Before Close**:
- Uncommitted transactions lost (not in WAL)
- Committed transactions recovered via WAL replay
- Database recovered on next open
- No data loss for committed transactions
- Recovery restores consistent state

**If System Crashes Before Close**:
- Same as application crash
- OS file handles closed
- WAL replay on next open
- Recovery restores committed transactions

## Invariants

### Pre-Close Invariants

1. **Database Open**: is_open is true
   - Database is operational
   - Components are initialized
   - Operations can proceed

2. **File Lock Held**: Exclusive lock on database file
   - Prevents concurrent opens
   - Single database instance

3. **Components Initialized**: All components valid
   - Pager, WAL, B+Tree, SnapshotRegistry initialized
   - Arc references valid

### Post-Close Invariants

1. **Database Closed**: is_open is false
   - No operations can proceed
   - Future operations return DatabaseClosed error

2. **File Lock Released**: No lock held
   - Other processes can open database
   - File available for reopening

3. **File Handles Closed**: All files closed
   - Database file closed
   - WAL file closed
   - OS resources released

4. **Memory Freed**: Arc references dropped
   - DbInner dropped
   - Components dropped (if last reference)
   - Memory returned to allocator

5. **Persistent State**: Database file consistent
   - All committed transactions persisted
   - Meta page valid
   - Recoverable state

## Concurrency Considerations

### Close vs Active Operations

**Close Blocking**:
- close() acquires exclusive lock (blocks all operations)
- Active readers must finish (release shared locks)
- Active writer must finish (release write lock)
- New operations blocked until close completes

**Close vs Readers**:
- Readers hold shared lock on DbInner
- close() waits for exclusive lock (readers must finish)
- After close, readers get DatabaseClosed error
- Readers must handle error gracefully

**Close vs Writer**:
- Writer holds write_lock and exclusive lock on DbInner
- close() waits for both locks
- Writer may be in middle of commit
- Close waits for commit to complete or timeout

**Close vs Auto-Checkpoint**:
- If background checkpoint in progress, close waits
- Checkpoint acquires exclusive lock
- Close acquires same lock after checkpoint
- Close may skip redundant checkpoint

### Thread Safety

**close() Thread-Safety**:
- Can be called from any thread with Db handle
- Exclusive lock ensures only one close in progress
- Multiple concurrent close calls: one wins, others see is_open == false

**Drop Thread-Safety**:
- Drop called by thread that owns Db handle
- If Db shared across threads (Arc), last drop triggers cleanup
- No coordination needed (Rust ownership system)

## Dependencies

### Close Process Uses

- **DbInner**: State and component access
- **Pager**: Cache flush, file close, sync
- **WAL**: WAL close, truncate
- **SnapshotRegistry**: Optional persistence
- **FileLock**: Lock release
- **AtomicBool**: is_open state

### Close Process Used By

- **Db::close()**: Explicit close entry point
- **Db::drop()**: Implicit close entry point
- **Application Code**: Graceful shutdown

## Rust Implementation Guidance

### Module Structure

```
northstar-core/src/db/
├── mod.rs          # Db, DbInner, close methods
├── close.rs        # Close logic (private module)
└── error.rs        # Close error variants
```

### Type Definitions

**CloseOptions**: (future) Options for close behavior
- wait_for_readers: bool (default: true)
- reader_timeout: Duration (default: 30 seconds)
- force_checkpoint: bool (default: true)
- on_error: CloseErrorAction (Log, Panic, Ignore)

**CloseErrorAction**: Error handling strategy
- Log: Log error, continue close
- Panic: Panic on error (for testing)
- Ignore: Silently ignore error (for Drop)

### Concurrency

**Lock Strategy**:
- Acquire RwLock::write() on DbInner (exclusive lock)
- Use try_write_for() with timeout (avoid infinite wait)
- Force rollback write transaction if needed
- Do not wait indefinitely for readers

**Error Handling**:
- Explicit close: Return Result<(), Error>
- Implicit close: Log errors, do not panic
- Use ? operator for error propagation in close()
- Use unwrap_or_else() in drop() with logging

### Key Decisions

**Synchronous vs Asynchronous Close**:
- Choose synchronous close for simplicity
- Close is rare operation, blocking acceptable
- Asynchronous close adds complexity
- Future: Consider async close for async runtimes

**Wait vs Force for Readers**:
- Choose wait with timeout for explicit close()
- Choose force (no wait) for implicit Drop
- Tradeoff: Graceful vs fast close
- Timeout prevents hanging on buggy readers

**Checkpoint on Close**:
- Always checkpoint on close (if WAL non-empty)
- Ensures WAL empty, data persisted
- Tradeoff: Slower close vs clean state
- Future: Add option to skip checkpoint

**Panic on Error in Drop**:
- Never panic in Drop (Rust best practice)
- Log errors instead
- Best-effort cleanup
- OS cleanup on process exit

### Implementation Notes

**Step 1: State Validation**
```rust
fn close(&self) -> Result<(), Error> {
    // Check if already closed
    if !self.is_open.load(Ordering::Acquire) {
        return Ok(());  // Idempotent
    }

    // Acquire exclusive lock with timeout
    let inner = self.inner.try_write_for(Duration::from_secs(30))
        .ok_or(Error::LockTimeout)?;

    // Double-check is_open
    if !self.is_open.load(Ordering::Acquire) {
        return Ok(());  // Another thread closed
    }

    // ... proceed with close
}
```

**Step 2: Operation Drain**
```rust
// Force rollback write transaction if active
if inner.write_lock.try_lock().is_ok() {
    // No active writer, lock acquired and released
    drop(inner.write_lock);
} else {
    // Active writer, force rollback
    log::warn!("Active write transaction during close, rolling back");
    // Write transaction will be rolled back when lock released
}
```

**Step 3: Final Checkpoint**
```rust
// Checkpoint if WAL non-empty
let wal_size = inner.wal.size()?;
if wal_size > 0 {
    log::info!("Performing final checkpoint");
    inner.pager.checkpoint()?;
    inner.wal.truncate()?;
    inner.pager.update_meta_page(inner.current_root_page_id.load(Ordering::Acquire))?;
    inner.pager.sync()?;
}
```

**Step 4: Component Shutdown**
```rust
// Close WAL
inner.wal.close()?;

// Close Pager (flushes cache, closes file)
inner.pager.close()?;

// Components dropped automatically when DbInner dropped
```

**Step 5: State Update**
```rust
// Mark as closed
self.is_open.store(false, Ordering::SeqCst);

// Log close
log::info!("Database closed: {}", self.path.display());
```

**Step 6: Drop Implementation**
```rust
impl Drop for Db {
    fn drop(&mut self) {
        if self.is_open.load(Ordering::Acquire) {
            // Attempt close, ignore errors
            if let Err(e) = self.close_internal() {
                eprintln!("Error closing database: {}", e);
            }
        }
    }
}
```

### Testing Strategy

**Unit tests needed for**:
- close() on already closed database (idempotent)
- close() with no active transactions
- close() with active write transaction (rollback)
- close() with active read transactions (wait or force)
- close() during checkpoint
- close() with WAL non-empty (checkpoint)
- close() with WAL empty (skip checkpoint)
- close() error handling (sync failure, close failure)
- Drop triggers close
- Multiple concurrent close() calls

**Integration tests needed for**:
- Close and reopen database (persistence)
- Close with committed transactions (verify persisted)
- Close with uncommitted transaction (verify lost)
- Close during write operation
- Close with multiple readers
- Force close (kill process) and reopen
- Close on corrupted database

**Property tests needed for**:
- Close is idempotent (multiple calls safe)
- Close after close returns Ok(())
- Closed database rejects all operations
- Database consistent after close and reopen

**Hardening tests needed for**:
- Close during commit (partial state)
- Close with disk full
- Close with permission denied
- Close with file lock stolen
- Close during recovery
- Panic during close
