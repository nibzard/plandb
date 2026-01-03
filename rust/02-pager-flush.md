# Pager Flush Operation

## Purpose

The Pager flush operation ensures all in-memory data is durably persisted to stable storage. This specification details the write-through cache design, implicit flush behavior, explicit synchronization points, and recovery implications. The current implementation uses a write-through cache with no dirty page tracking, meaning explicit flush operations are simplified compared to traditional write-back cache designs.

## Write-Through Cache Design

### No Dirty Page Tracking

**Design Choice**: Cache is write-through, not write-back

**Behavior**:
- All writes go directly to storage via writePage
- Cache contains only clean (unmodified) pages
- No dirty page set or modified flag
- No write-back queue or flush queue

**Rationale**:
- Simplifies implementation (no dirty state to track)
- Prevents data loss on crash (no dirty pages in memory)
- Consistent with MVCC copy-on-write (new pages always written)
- Reduces complexity of cache management

**Implications**:
- Every write triggers immediate storage I/O
- No opportunity for write coalescing or batching
- Higher write latency but simpler consistency model
- Flush operations are trivial (no dirty pages to write)

### Cache Invalidation on Write

**Automatic Invalidation**: When writePage completes
- Page is removed from cache
- Next read loads fresh data from storage
- No window where cache and storage disagree

**Stale Data Prevention**:
- Caller cannot modify cached page in-place
- Copy-on-write creates new page version
- New version written via writePage
- Old version invalidated in cache

**Pinned Pages**:
- Pinned pages should not be written (caller error)
- If pinned page is written, cache entry removed
- Pin holders may read stale data from removed buffer
- Caller must unpin before modifying page

## Synchronization Points

### Implicit Flush Behavior

**Write-Through Semantics**: writePage implicitly flushes
- Data written to file descriptor
- May be buffered by OS page cache
- Not yet on stable storage (needs fsync)

**OS Buffering**:
- Written data may reside in OS page cache
- Power loss before fsync loses data
- fsync required for durability

**Explicit Sync Required**: For durability guarantees
- Call sync() after writePage for immediate durability
- Call commitSync() during transaction commit
- Multiple writes can be synced together (batching benefit)

### sync Function

**Purpose**: Flush OS page cache to stable storage

**Operation**:
- Call fsync on underlying file descriptor
- Blocks until all data is on disk
- Ensures durability of all prior writes

**File Storage**:
- Opens file and calls fsync
- May flush file metadata (depending on OS)
- Blocks until storage acknowledges writes

**Memory Storage**:
- No-op (no durable storage to flush)
- Used primarily for testing

**Usage Patterns**:
- Transaction commit (via commitSync)
- Manual checkpoint operation
- Database close operation
- Periodic durability checkpoint

### commitSync Function

**Purpose**: Final synchronization step for two-phase commit

**Preconditions**:
- All data pages have been written (via writePage)
- Commit record has been appended to log
- Log file has been fsynced

**Operation**:
- Calls sync() internally
- Ensures database file flush
- Completes commit durability

**Commit Ordering**:
1. Write commit record to log file
2. fsync log file (durable commit record)
3. Write meta page to database file
4. Call commitSync (fsync database file)

**Rationale**: Log-before-meta ensures recoverability
- Crash after step 2 but before 4: commit record exists, meta not updated
- Recovery replays commit record and updates meta
- Crash after step 4: both log and meta durable, fully committed

## Checkpoint Process

### No Explicit Checkpoint Operation

**Current Design**: Checkpoint is implicit in commit

**Behavior**:
- Each commit persists meta page
- Meta page points to latest root and transaction state
- No separate checkpoint thread or operation
- No fuzzy checkpointing or incremental checkpoint

**Rationale**:
- Simplifies implementation (no checkpoint coordinator)
- Write-through cache means no dirty pages to flush
- Meta page updates provide sufficient checkpointing
- MVCC allows old snapshots to coexist with new commits

**Recovery Process**:
- Read both meta pages on open
- Choose meta page with higher committed_txn_id
- Reconstruct state from chosen meta page
- No log replay needed (commit stream is separate)

### Future Checkpoint Extensions

**Potential Optimizations** (not implemented in V0):
- Periodic full checkpoint to truncate commit stream
- Fuzzy checkpointing to allow concurrent commits
- Incremental checkpointing for large databases
- Checkpoint compaction to reclaim space

**Current Alternative**:
- Commit stream grows indefinitely
- Old commit records can be archived
- Database can be compacted by rebuilding

## What Gets Persisted When

### WritePage Call

**Persisted Immediately**:
- Single page data (16KB for default page size)
- Page header with checksums
- Page payload (B+tree node, freelist, etc.)

**Not Yet Durable**:
- May be in OS page cache
- Lost on power failure before fsync

**Subsequent Sync**: Makes write durable
- fsync after writePage ensures page on disk
- Can batch multiple writes before single fsync
- Reduces fsync overhead (expensive operation)

### Transaction Commit

**Persisted in Order**:
1. Commit record appended to log file
2. fsync log file (durable commit record)
3. Meta page written to database file
4. fsync database file (durable meta update)

**Durability Guarantee**:
- After step 2: commit record recoverable even if crash
- After step 4: full commit durable, transaction persistent
- Crash before step 2: transaction lost (not committed)
- Crash between step 2 and 4: recovery replays from commit record

**All Modified Pages**:
- Data pages written during transaction (via putBtreeValue)
- Each page write invalidates cache entry
- All writes complete before commit begins
- No dirty pages remain after commit

### Database Close

**Persisted on Close**:
- All writes already completed (write-through cache)
- Cache discarded (no dirty pages to flush)
- File descriptor closed (OS flushes on close in some systems)

**No Explicit Flush Needed**:
- Write-through means all data already written
- Cache contains only clean pages
- close() deallocates cache and allocator

**Safe Shutdown**:
- Last commit already durable (fsync in commitSync)
- Subsequent operations would start new transactions
- No unsaved data on close

## Recovery Implications

### Crash Consistency

**Write-Through Benefits**:
- No dirty pages lost on crash
- All committed writes already on disk (after fsync)
- Recovery only needs to read meta pages
- No write-ahead log replay needed for B+tree

**Commit Stream**:
- Separate log file records all commits
- Used for commit stream replay and time-travel queries
- Not needed for B+tree recovery (meta page sufficient)

**Recovery Process**:
1. Open database file
2. Read both meta pages
3. Validate checksums
4. Choose meta with higher committed_txn_id
5. Load root page ID and freelist head
6. Open B+tree for queries

### No WAL Replay for B+tree

**Design Simplification**: WAL used for commit stream, not recovery

**Traditional Database**:
- WAL records all page modifications
- Recovery replays WAL to reconstruct dirty pages
- Checkpoint truncates WAL

**NorthstarDB V0**:
- Write-through cache means no dirty pages
- Meta page always points to consistent B+tree root
- Commit stream records transaction history
- Recovery reads meta page, not WAL

**Trade-offs**:
- Pro: Simpler recovery (no WAL replay logic)
- Pro: Faster recovery (just read meta page)
- Con: No uncommitted dirty page recovery (all lost)
- Con: Commit stream grows indefinitely

### Time-Travel and Snapshots

**Commit Stream Usage**:
- All commits recorded in separate log file
- Snapships reference committed_txn_id
- Queries can reconstruct historical state
- Used for time-travel and analytics

**Replay from Commit Stream**:
- Read commit records from log file
- Apply mutations to empty database
- Rebuild B+tree at specific transaction
- Enables querying historical data

**Not for Crash Recovery**:
- B+tree doesn't need WAL replay (meta page sufficient)
- Commit stream replay for feature support only
- Optional for databases that don't use time-travel

## Functions

### sync(&mut self) -> Result<(), Error>

**Purpose**: Flush OS page cache to stable storage

**Returns**: Empty tuple on success

**Algorithm**:
1. Check storage type
2. If file storage: call fsync on file descriptor
3. If memory storage: no-op
4. Return success

**Error Conditions**:
- IoError: fsync failed

**Usage**: Manual durability, batch write flushing, database close

### commitSync(&mut self, wal: &Wal) -> Result<(), Error>

**Purpose**: Final synchronization for two-phase commit

**Parameters**:
- wal: Write-ahead log reference (documentational, not called)

**Returns**: Empty tuple on success

**Algorithm**:
1. Call sync() to flush database file
2. Block until fsync completes
3. Return success

**Error Conditions**:
- IoError: fsync failed

**Usage**: Transaction commit, automatic durability

## Flush Optimization Strategies

### Batch Write Sync

**Current Pattern**: Write multiple pages, sync once

**Algorithm**:
1. Write page 1 (writePage, no sync)
2. Write page 2 (writePage, no sync)
3. Write page N (writePage, no sync)
4. Sync once (sync or commitSync)

**Benefit**: Amortizes fsync cost across multiple writes

**Trade-off**: Risk between writes (crash loses intermediate state)

**Commit Usage**: Transaction commits use this pattern
- Multiple B+tree page writes during transaction
- Single fsync at commit end (commitSync)

### Group Commit

**Potential Optimization** (not in V0):
- Batch multiple transactions' fsync calls
- amortize fsync cost across concurrent commits
- Reduces per-transaction sync overhead

**Implementation Requirements**:
- Commit queue to group transactions
- Timer or size threshold to trigger group flush
- Coordination between concurrent transactions

### Sync-On-Close

**Current Behavior**: close() does not explicitly sync

**Rationale**: Last commit already included fsync

**Future Enhancement**: Optional sync on close
- Ensures all buffered writes flushed
- Provides safety net for unexpected close
- May add latency to close operation

## Rust Implementation Guidance

### Module Structure

Flush operations integrated into Pager module:
- northstar_core::pager::Pager - Main struct with sync methods
- Methods: sync, commit_sync

### Type Definitions

**Sync Error Type**: Specific error for sync operations
```rust
#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("IO error during sync: {0}")]
    Io(#[from] std::io::Error),
}
```

### Sync Implementation

**Direct File Sync**: Use std::fs::File::sync_all or sync_data
```rust
impl Pager {
    pub fn sync(&self) -> Result<(), SyncError> {
        match &self.storage {
            Storage::File(file) => {
                file.sync_all()
                    .map_err(SyncError::Io)?;
            }
            Storage::Memory(_) => {
                // No-op for in-memory storage
            }
        }
        Ok(())
    }
}
```

**sync_all vs sync_data**:
- sync_all: Flushes data and metadata (slower, safer)
- sync_data: Flushes data only (faster, file size may be wrong)
- Recommended: sync_all for correctness

**Platform Differences**:
- Linux: fsync system call
- macOS: fsync similar semantics
- Windows: FlushFileBuffers

### Commit Sync Implementation

**Wrapper Around sync**:
```rust
impl Pager {
    pub fn commit_sync(&self, _wal: &Wal) -> Result<(), SyncError> {
        // Note: wal parameter used for documentation only
        // In V0, commit stream is separate and not synced here
        self.sync()
    }
}
```

**Rationale**: Future extension may coordinate with WAL sync

### Close Behavior

**No Explicit Sync on Close**:
```rust
impl Drop for Pager {
    fn drop(&mut self) {
        // Cache is write-through, no dirty pages to flush
        // Last commit already included fsync
        // Just cleanup resources
    }
}

impl Pager {
    pub fn close(mut self) {
        // Explicit close (consumes Pager)
        // No sync needed (write-through cache)
    }
}
```

### Testing Strategy

**Unit tests needed for**:
- sync succeeds on file storage
- sync is no-op on memory storage
- commit_sync calls sync internally
- multiple writes then single sync persists all data
- crash after sync recovers data
- crash before sync loses data (expected)

**Property tests for**:
- After sync, written pages readable on reopen
- After sync and crash, database state consistent
- Sync is idempotent (multiple syncs safe)

**Integration tests for**:
- Commit with sync survives crash
- Batch write pattern persists correctly
- Close after commit doesn't lose data
- Recovery after crash chooses correct meta page
