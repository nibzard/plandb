# Snapshot Cleanup

## Purpose

Snapshot cleanup is the garbage collection mechanism that prevents unbounded growth of the snapshot registry in NorthstarDB's MVCC system. As transactions commit and new snapshots are created, the registry accumulates historical snapshot entries that consume memory and must eventually be reclaimed. The cleanup system safely removes expired snapshots while preserving those still needed by active readers, time-travel queries, or recovery operations. This ensures long-running database stability without manual intervention.

## Core Concepts

### Snapshot Lifecycle

A snapshot progresses through several lifecycle stages from creation to eventual cleanup:

1. **Creation**: Snapshot is registered when a transaction commits, allocating an entry in the snapshot registry
2. **Active Use**: One or more readers hold references to the snapshot through read transactions or explicit snapshot handles
3. **Idle but Retained**: No active readers, but snapshot is kept based on retention policy (age or count limits)
4. **Eligible for Cleanup**: Snapshot exceeds retention thresholds and no readers reference it
5. **Cleanup**: Registry entry is removed, memory is freed, and the snapshot becomes inaccessible for new queries

### Retention Policy

NorthstarDB uses a dual-parameter retention policy that balances memory efficiency with time-travel query capabilities:

- **keep_txns**: Age-based retention - keeps snapshots from the last N committed transactions regardless of how many snapshots exist
- **keep_count**: Count-based retention - keeps at least the M most recent snapshots regardless of their transaction age

Both parameters work together: a snapshot is retained if EITHER condition is satisfied. This prevents scenarios where a burst of transactions could prune all recent snapshots, or where long gaps between transactions could retain ancient history.

### Reference Counting

Each snapshot maintains a reference count tracking how many active readers hold handles to it. The reference count serves as a hard constraint: snapshots with non-zero reference counts are NEVER eligible for cleanup, regardless of retention policy. This prevents use-after-free bugs where cleanup could remove a snapshot while a reader is still using it.

### Cleanup Safety

Cleanup operations must coordinate with concurrent readers and writers to maintain consistency:

- **Readers in progress**: Their snapshots must remain valid throughout their lifetime
- **New snapshot creation**: Must not race with cleanup removing the snapshot they just acquired
- **Historical queries**: Time-travel queries depend on historical snapshots remaining accessible
- **Recovery operations**: Crash recovery may need to replay transactions and rebuild snapshots

## Types

### CleanupPolicy

**Description**: Configuration parameters controlling snapshot garbage collection behavior

**Fields**:
- keep_txns: u64 - Minimum number of recent transactions to retain by age (0 means no age-based limit)
- keep_count: usize - Minimum number of snapshots to retain by count (default 10-100 depending on workload)

**Invariants**:
- keep_count is always at least 1 (genesis snapshot must be preserved)
- keep_txns can be 0 (unlimited age retention) or positive
- Both parameters apply simultaneously (AND logic for eligibility, OR logic for retention)

**Default Values**:
- keep_txns: 1000 (retain last 1000 transactions)
- keep_count: 10 (retain at least 10 most recent snapshots)

### CleanupStats

**Description**: Statistics from a cleanup operation for monitoring and diagnostics

**Fields**:
- snapshots_before: usize - Number of snapshots in registry before cleanup
- snapshots_after: usize - Number of snapshots remaining after cleanup
- snapshots_removed: usize - Number of snapshots removed during cleanup
- oldest_retained_txn: Option<u64> - Oldest transaction ID still in registry after cleanup
- newest_retained_txn: u64 - Newest transaction ID (always current_txn_id)
- bytes_freed: usize - Estimated memory freed by cleanup

**Invariants**:
- snapshots_after = snapshots_before - snapshots_removed
- snapshots_after is at least keep_count (if non-zero)
- oldest_retained_txn is always Some (at least genesis snapshot exists)
- bytes_freed is approximate (depends on HashMap implementation)

### SnapshotGcState

**Description**: Internal state tracking for garbage collection coordinator

**Fields**:
- last_cleanup_txn_id: u64 - Transaction ID at which last cleanup ran
- last_cleanup_time: Option<Instant> - Timestamp of last cleanup (if tracked)
- cleanup_count: u64 - Total number of cleanup operations performed
- snapshots_cleaned_total: u64 - Cumulative snapshots removed across all cleanups

**Invariants**:
- last_cleanup_txn_id is monotonically increasing (cleanup only moves forward)
- cleanup_count increments on each cleanup operation
- snapshots_cleaned_total is sum of all snapshots_removed across cleanups

## Functions

### shouldCleanupSnapshot(txn_id: u64, current_txn_id: u64, policy: CleanupPolicy, active_snapshots: HashSet<u64>) -> bool

**Purpose**: Determine if a specific snapshot is eligible for garbage collection

**Parameters**:
- txn_id: Transaction ID of the snapshot to check
- current_txn_id: Most recent committed transaction ID in the registry
- policy: CleanupPolicy containing keep_txns and keep_count parameters
- active_snapshots: Set of transaction IDs with non-zero reference counts

**Returns**: true if snapshot can be safely removed, false if must be retained

**Algorithm**:
1. Check if txn_id is in active_snapshots set:
   - If present, return false (snapshot has active readers, must retain)
2. Check if txn_id is 0 (genesis snapshot):
   - If yes, return false (never remove genesis snapshot)
3. Calculate position_from_latest:
   - position_from_latest = current_txn_id - txn_id
   - If calculation would underflow (txn_id > current_txn_id), return false (future snapshot, invalid state)
4. Check keep_count constraint:
   - If position_from_latest < policy.keep_count, return false (within recent count, must retain)
5. Check keep_txns constraint:
   - If policy.keep_txns is 0, skip age check (no age limit)
   - Calculate cutoff_txn_id = current_txn_id - policy.keep_txns
   - If txn_id >= cutoff_txn_id, return false (within age window, must retain)
6. If all checks pass (not active, not genesis, outside count window, outside age window):
   - Return true (eligible for cleanup)

**Error Conditions**: None (pure calculation function)

**Concurrency**: Read-only, thread-safe for concurrent access

**Design Note**: This function encapsulates the core cleanup policy logic and can be called from cleanup operations or monitoring code.

### cleanupSnapshots(registry: &mut SnapshotRegistry, policy: CleanupPolicy, active_snapshots: &HashSet<u64>) -> Result<CleanupStats, Error>

**Purpose**: Execute garbage collection on the snapshot registry, removing eligible snapshots

**Parameters**:
- registry: Mutable reference to snapshot registry
- policy: CleanupPolicy defining retention thresholds
- active_snapshots: Set of transaction IDs currently referenced by active readers

**Returns**: CleanupStats with operation results

**Algorithm**:
1. Initialize CleanupStats:
   - snapshots_before = registry.snapshots.count()
   - snapshots_removed = 0
2. If snapshots_before <= policy.keep_count:
   - Return stats with 0 removed (nothing to clean up, below minimum count)
3. Calculate age cutoff:
   - If policy.keep_txns > 0 AND registry.current_txn_id > policy.keep_txns:
     - cutoff_txn_id = registry.current_txn_id - policy.keep_txns
   - Else:
     - cutoff_txn_id = 0 (no age-based pruning)
4. Collect transaction IDs to remove:
   - Create empty vector txn_ids_to_remove
   - Iterate through registry.snapshots.entries():
     - For each (txn_id, root_page_id):
       - Check eligibility using shouldCleanupSnapshot()
       - If eligible, append txn_id to txn_ids_to_remove
5. Remove marked snapshots:
   - For each txn_id in txn_ids_to_remove:
     - Remove entry from registry.snapshots HashMap
     - Increment snapshots_removed
6. Update CleanupStats:
   - snapshots_after = registry.snapshots.count()
   - bytes_freed = snapshots_removed * ESTIMATED_BYTES_PER_SNAPSHOT
   - Calculate oldest_retained_txn by iterating remaining entries
   - newest_retained_txn = registry.current_txn_id
7. Return CleanupStats

**Error Conditions**:
- AllocationFailed: Vector allocation for removal list fails
- CorruptedRegistry: Registry invariants violated during iteration

**Concurrency**: Must be externally synchronized (single cleanup operation at a time)

**Design Notes**:
- Two-pass approach (collect then remove) avoids iterator invalidation issues
- Genesis snapshot (txn_id 0) is protected by shouldCleanupSnapshot check
- ESTIMATED_BYTES_PER_SNAPSHOT is typically 32-40 bytes depending on HashMap implementation
- Consider using retain() method for more idiomatic Rust implementation

### registerActiveSnapshot(registry: &SnapshotRegistry, active_snapshots: &mut HashSet<u64>, txn_id: u64)

**Purpose**: Mark a snapshot as actively used by incrementing its reference count

**Parameters**:
- registry: Reference to snapshot registry (for validation)
- active_snapshots: Mutable set of active snapshot transaction IDs
- txn_id: Transaction ID to register as active

**Returns**: Unit

**Algorithm**:
1. Validate that snapshot exists:
   - Check registry.hasSnapshot(txn_id)
   - If false, panic or return error (invalid operation)
2. Insert txn_id into active_snapshots HashSet:
   - If already present, this is a no-op (already registered)
3. Return success

**Error Conditions**:
- InvalidSnapshot: txn_id does not exist in registry

**Concurrency**: Must synchronize with cleanup operations (typically uses same lock as registry)

**Design Note**: This is typically called when a ReadTxn is created or a SnapshotHandle is cloned.

### unregisterActiveSnapshot(active_snapshots: &mut HashSet<u64>, txn_id: u64)

**Purpose**: Mark a snapshot as no longer used by decrementing its reference count

**Parameters**:
- active_snapshots: Mutable set of active snapshot transaction IDs
- txn_id: Transaction ID to unregister

**Returns**: Unit

**Algorithm**:
1. Remove txn_id from active_snapshots HashSet:
   - Use HashSet.remove() which returns true if present, false if absent
   - If not present, this is a no-op (already unregistered)
2. Return success

**Error Conditions**: None (idempotent operation)

**Concurrency**: Must synchronize with cleanup operations

**Design Note**: This is typically called when a ReadTxn is dropped or a SnapshotHandle is destroyed. After unregistering, the snapshot becomes eligible for cleanup (if retention policy allows).

### getActiveSnapshotCount(active_snapshots: &HashSet<u64>) -> usize

**Purpose**: Get the current number of active snapshots (for monitoring)

**Parameters**:
- active_snapshots: Set of active snapshot transaction IDs

**Returns**: Count of active snapshots

**Algorithm**:
1. Return active_snapshots.len()

**Error Conditions**: None

**Concurrency**: Read-only, thread-safe

### scheduleBackgroundCleanup(gc_state: &mut SnapshotGcState, registry: &SnapshotRegistry, policy: CleanupPolicy) -> Option<Duration>

**Purpose**: Determine if background cleanup should run and when

**Parameters**:
- gc_state: Garbage collection state tracking
- registry: Snapshot registry to check
- policy: CleanupPolicy containing thresholds

**Returns**: Some(duration) until next cleanup, or None if cleanup should run immediately

**Algorithm**:
1. Calculate snapshot_growth:
   - current_count = registry.snapshots.count()
   - baseline_count = policy.keep_count * 2 (target maximum before aggressive cleanup)
   - If current_count > baseline_count, return None (cleanup needed now)
2. Check time-based trigger:
   - If gc_state.last_cleanup_time is None, return None (never cleaned up, run now)
   - elapsed = current_time - gc_state.last_cleanup_time
   - If elapsed > CLEANUP_INTERVAL (default 60 seconds), return None (time for periodic cleanup)
3. Check transaction-based trigger:
   - txn_since_cleanup = registry.current_txn_id - gc_state.last_cleanup_txn_id
   - If txn_since_cleanup > CLEANUP_TXN_THRESHOLD (default 100), return None (enough new transactions)
4. Calculate time until next cleanup:
   - time_until_trigger = CLEANUP_INTERVAL - elapsed
   - Return Some(time_until_trigger)

**Error Conditions**: None (scheduling logic only)

**Concurrency**: Read-only access to gc_state and registry

**Design Note**: This enables automatic background garbage collection without manual intervention.

## Cleanup Strategies

### Conservative Cleanup (Default)

**Policy**: keep_txns = 1000, keep_count = 10

**Characteristics**:
- Retains snapshots from last 1000 committed transactions
- Always keeps at least 10 most recent snapshots regardless of age
- Suitable for general-purpose workloads with moderate time-travel query needs
- Balances memory efficiency with historical access

**Use Cases**:
- Production databases with typical query patterns
- Applications needing recent historical data (hours to days depending on commit rate)
- Systems where memory overhead is a concern but not critical

### Aggressive Cleanup

**Policy**: keep_txns = 100, keep_count = 5

**Characteristics**:
- Retains only last 100 transactions
- Keeps minimum 5 snapshots
- Frequent cleanup reduces memory overhead
- Limits time-travel query range

**Use Cases**:
- High-throughput workloads with minimal time-travel needs
- Memory-constrained environments
- Write-heavy applications where historical reads are rare

### Lazy Cleanup

**Policy**: keep_txns = 0, keep_count = 100

**Characteristics**:
- No age-based limit (unlimited time retention)
- Count-based limit only (keep last 100 snapshots)
- Cleanup only triggers when snapshot count exceeds threshold
- Suitable for bursty workloads with long gaps

**Use Cases**:
- Development and testing environments
- Analytics workloads needing deep time-travel
- Databases with infrequent commits

### Disabled Cleanup

**Policy**: keep_txns = 0, keep_count = 0 or very large value

**Characteristics**:
- Snapshots never expire
- Memory grows unbounded (eventually exhausts memory)
- Only appropriate for special scenarios

**Use Cases**:
- Debugging memory behavior (intentional leak)
- Very short-lived database instances
- Manual cleanup management (external script triggers cleanup)

## Cleanup Coordination

### Cleanup During Active Operations

**Challenge**: Cleanup must not remove snapshots that are actively in use

**Solution**: Reference counting via active_snapshots HashSet
- When a reader acquires a snapshot, its txn_id is added to active_snapshots
- Cleanup checks this set and skips any snapshots present in it
- When reader completes, txn_id is removed from active_snapshots
- Next cleanup cycle can then remove the snapshot

**Concurrency**: Use RwLock for registry:
- Cleanup acquires exclusive write lock
- Readers acquire shared read locks
- Reference count updates require write lock (brief critical section)

### Cleanup and Snapshot Creation Race

**Challenge**: New snapshot creation must not race with cleanup removing it

**Solution**: Registration happens before cleanup eligibility check
- When creating a new snapshot:
  1. Acquire registry write lock
  2. Insert snapshot into registry
  3. Insert snapshot txn_id into active_snapshots
  4. Release registry write lock
- Cleanup cannot remove snapshot because it is in active_snapshots
- When snapshot is no longer needed, it is removed from active_snapshots

**Design Note**: This ensures newly created snapshots are protected by default until explicitly released.

### Cleanup and Recovery Coordination

**Challenge**: Crash recovery rebuilds snapshot registry and must not conflict with cleanup

**Solution**: Recovery is a special mode with cleanup disabled
- During database open with recovery:
  1. Cleanup is temporarily disabled (gc_state.cleanup_paused = true)
  2. WAL is replayed and snapshots are reconstructed
  3. Once recovery completes, cleanup is re-enabled
- This prevents cleanup from removing snapshots before recovery finishes reading them

**Alternative**: Recovery can explicitly populate active_snapshots with all recovered snapshots, then release them as transactions complete.

## Performance Considerations

### Cleanup Frequency

**Too Frequent** (every transaction):
- Wastes CPU cycles scanning registry
- Lock contention with concurrent readers
- Minimal benefit (few snapshots to clean)

**Too Infrequent** (never or hours apart):
- Registry grows unbounded
- Memory waste
- HashMap lookup degradation (more entries to scan)

**Recommended**: Every 100-1000 transactions OR every 60 seconds, whichever comes first
- Balances overhead with memory management
- Can be tuned based on commit rate and memory constraints

### Cleanup Cost

**Time Complexity**: O(n) where n is number of snapshots in registry
- Must scan entire registry to find eligible snapshots
- HashMap iteration is fast but scales with entry count
- Removal operation is O(1) per entry

**Space Complexity**: O(k) where k is number of snapshots to remove
- Need to store list of transaction IDs to remove
- Temporary allocation proportional to removal count
- Alternative: use retain() method for in-place filtering

**Optimization**: Batch cleanup operations
- Instead of cleaning after every transaction, clean periodically
- Amortizes cleanup cost over many transactions
- Reduces lock contention

### Memory Overhead

**Per Snapshot**: Approximately 32-40 bytes
- HashMap entry overhead (key pointer, value pointer, hash)
- Transaction ID (8 bytes u64)
- Root page ID (8 bytes u64)
- HashMap internal metadata

**Total Overhead Calculation**:
- 1000 snapshots: 32-40 KB
- 10000 snapshots: 320-400 KB
- 100000 snapshots: 3.2-4 MB

**Guideline**: For typical workloads, keep total snapshot overhead under 10 MB
- This translates to roughly 250,000-300,000 snapshots maximum
- Default policy of 1000 transactions keeps overhead at ~40 KB

## Invariants

### Safety Invariants
- Genesis snapshot (txn_id 0) is never removed by cleanup
- Snapshots with non-zero reference counts (in active_snapshots) are never removed
- Cleanup never removes the current snapshot (current_txn_id)
- Cleanup only removes snapshots older than both keep_txns and keep_count thresholds

### Liveness Invariants
- If policy.keep_count > 0, cleanup always leaves at least keep_count snapshots
- If policy.keep_txns > 0, cleanup always retains snapshots from last keep_txns transactions
- Cleanup eventually removes all snapshots that exceed retention policy
- Newer snapshots (higher transaction IDs) are retained over older snapshots

### Consistency Invariants
- Snapshot registry remains consistent after cleanup (no orphaned references)
- Reference counts (active_snapshots) remain consistent with actual readers
- Cleanup operations are idempotent (running twice in a row is safe)
- Cleanup does not affect visibility calculations (already computed snapshots remain valid)

## Dependencies

### Uses
- SnapshotRegistry (task 5.2) - Provides snapshot storage and iteration
- SnapshotStats (task 5.2) - Registry statistics for monitoring
- HashSet<u64> - Active snapshot tracking via reference counts

### Used By
- Db (main database API) - Coordinates periodic cleanup
- ReadTxn (task 4.3) - Registers/unregisters snapshots on creation/drop
- WriteTxn (task 4.4) - Registers/unregisters snapshots on creation/drop
- Background GC thread - Scheduled cleanup operations
- Monitoring tools - Cleanup statistics reporting

## Rust Implementation Guidance

### Module Structure

Cleanup logic should be organized as follows:
```
src/snapshot/cleanup.rs - Core cleanup algorithms and types
src/snapshot/mod.rs - Re-exports cleanup functions
```

Public API:
```rust
pub struct CleanupPolicy { /* fields */ }
pub struct CleanupStats { /* fields */ }
pub fn cleanupSnapshots(...) -> Result<CleanupStats, Error>;
```

### Type Definitions

**CleanupPolicy struct**:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CleanupPolicy {
    pub keep_txns: u64,     // Age-based retention
    pub keep_count: usize,  // Count-based retention
}

impl Default for CleanupPolicy {
    fn default() -> Self {
        Self {
            keep_txns: 1000,
            keep_count: 10,
        }
    }
}
```

**CleanupStats struct**:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CleanupStats {
    pub snapshots_before: usize,
    pub snapshots_after: usize,
    pub snapshots_removed: usize,
    pub oldest_retained_txn: Option<u64>,
    pub newest_retained_txn: u64,
    pub bytes_freed: usize,
}
```

**SnapshotGcState struct**:
```rust
pub struct SnapshotGcState {
    last_cleanup_txn_id: u64,
    last_cleanup_time: Option<Instant>,
    cleanup_count: u64,
    snapshots_cleaned_total: u64,
}
```

### Key Decisions

**Reference Counting**: Use HashSet<u64> for active_snapshots
- Simple and efficient for tracking active snapshots
- O(1) insert, remove, and contains operations
- No reference counting needed (presence means count >= 1)
- Alternative: HashMap<u64, usize> for true reference counts (if multiple handles per snapshot)

**Cleanup Triggering**: Manual vs Automatic
- Manual: Application calls cleanup explicitly (simple, predictable)
- Automatic: Background thread runs cleanup periodically (complex, automatic)
- Recommendation: Start with manual cleanup, add background thread based on workload
- Hybrid: Automatic cleanup with manual override option

**Lock Strategy**: Cleanup coordination with readers
- Option 1: RwLock<SnapshotRegistry> - Simple, conservative locking
- Option 2: RCU (Read-Copy-Update) - Complex, better read scalability
- Option 3: Epoch-based reclamation - Complex, no global locks
- Recommendation: Start with RwLock, optimize if profiling shows contention

### Implementation Notes

**Step 1: shouldCleanupSnapshot function**
```rust
fn shouldCleanupSnapshot(
    txn_id: u64,
    current_txn_id: u64,
    policy: CleanupPolicy,
    active_snapshots: &HashSet<u64>,
) -> bool {
    // Active snapshots are always retained
    if active_snapshots.contains(&txn_id) {
        return false;
    }

    // Never remove genesis snapshot
    if txn_id == 0 {
        return false;
    }

    // Calculate position from latest (handle underflow)
    let position_from_latest = current_txn_id.saturating_sub(txn_id);

    // Check count-based retention
    if position_from_latest < policy.keep_count as u64 {
        return false;
    }

    // Check age-based retention (if enabled)
    if policy.keep_txns > 0 {
        let cutoff_txn_id = current_txn_id.saturating_sub(policy.keep_txns);
        if txn_id >= cutoff_txn_id {
            return false;
        }
    }

    // Snapshot is eligible for cleanup
    true
}
```

**Step 2: cleanupSnapshots function**
```rust
fn cleanupSnapshots(
    registry: &mut SnapshotRegistry,
    policy: CleanupPolicy,
    active_snapshots: &HashSet<u64>,
) -> Result<CleanupStats, Error> {
    let snapshots_before = registry.snapshots.len();

    // Early exit if below minimum count
    if snapshots_before <= policy.keep_count {
        return Ok(CleanupStats {
            snapshots_before,
            snapshots_after: snapshots_before,
            snapshots_removed: 0,
            oldest_retained_txn: registry.snapshots.keys().min().copied(),
            newest_retained_txn: registry.current_txn_id,
            bytes_freed: 0,
        });
    }

    // Calculate age cutoff
    let cutoff_txn_id = if policy.keep_txns > 0 {
        registry.current_txn_id.saturating_sub(policy.keep_txns)
    } else {
        0
    };

    // Collect transaction IDs to remove
    let mut removed_count = 0;
    registry.snapshots.retain(|&txn_id, _| {
        let should_keep = !shouldCleanupSnapshot(txn_id, registry.current_txn_id, policy, active_snapshots);
        if !should_keep {
            removed_count += 1;
        }
        should_keep
    });

    let snapshots_after = registry.snapshots.len();
    let oldest_retained_txn = registry.snapshots.keys().min().copied();

    Ok(CleanupStats {
        snapshots_before,
        snapshots_after,
        snapshots_removed: removed_count,
        oldest_retained_txn,
        newest_retained_txn: registry.current_txn_id,
        bytes_freed: removed_count * ESTIMATED_BYTES_PER_SNAPSHOT,
    })
}
```

**Step 3: Reference counting integration**
- When ReadTxn is created: insert txn_id into active_snapshots
- When ReadTxn is dropped: remove txn_id from active_snapshots
- Use Drop trait for automatic cleanup

**Step 4: Background cleanup (optional)**
- Spawn thread with periodic sleep
- On wakeup: check if cleanup needed
- If needed: acquire lock, run cleanup, release lock
- Shutdown signal to terminate thread gracefully

### Concurrency

**Lock Granularity**:
- Cleanup requires exclusive access to registry (write lock)
- Readers require shared access (read lock)
- Reference count updates require exclusive access (but very brief)

**Deadlock Prevention**:
- Always lock registry before active_snapshots (consistent lock ordering)
- Keep reference count updates very short (just HashSet insert/remove)
- Never hold locks while calling user code or doing I/O

**Lock Contention**:
- Cleanup should be infrequent (every 100-1000 transactions)
- Cleanup is fast (O(n) but n is small with proper policy)
- Readers run concurrently with each other (shared locks)
- Single writer at a time (exclusivity for writes and cleanup)

### Testing Strategy

**Unit Tests Needed**:
- shouldCleanupSnapshot with various policy combinations
- Cleanup with empty registry
- Cleanup with only genesis snapshot
- Cleanup removing all non-genesis snapshots
- Cleanup preserving active snapshots
- Cleanup respecting keep_count parameter
- Cleanup respecting keep_txns parameter
- Genesis snapshot is never removed
- Current snapshot is never removed
- Active snapshots are never removed

**Property Tests**:
- cleanup_invariant: After cleanup, remaining snapshots always satisfy retention policy
- monotonically_decreasing: Registry size never increases during cleanup
- idempotency: Running cleanup twice in a row is safe and second run removes nothing
- genesis_preserved: Genesis snapshot (txn_id 0) always exists after cleanup
- active_preserved: Snapshots in active_snapshots always survive cleanup

**Integration Tests**:
- Concurrent cleanup with readers
- Cleanup with long-running transactions
- Cleanup with rapid snapshot creation
- Background cleanup thread behavior
- Memory reclamation verification

**Edge Cases**:
- Cleanup with keep_count larger than registry size (should remove nothing)
- Cleanup with keep_txns of 0 (no age limit)
- Cleanup with keep_txns larger than current_txn_id (keep all)
- Registry with gaps in transaction IDs (aborted transactions)
- Very large registry (10000+ snapshots) performance
- Cleanup running while snapshot is being created

**Stress Tests**:
- Continuous cleanup with concurrent workload
- Rapid snapshot creation and cleanup cycles
- Memory leak verification (no unbounded growth with cleanup enabled)
- Cleanup during crash recovery simulation

### Error Handling

**Recoverable Errors**:
- AllocationFailed: Temporary allocation failure during cleanup
  - Action: Return error to caller, can retry later
- RegistryCorrupted: Inconsistent registry state detected
  - Action: Log error, return error, may require database restart

**Unrecoverable/Panic**:
- Cleanup removing active snapshot (should never happen if logic correct)
- Cleanup removing genesis snapshot (violation of core invariant)
- Negative snapshot count after cleanup (corrupted state)

**Error Recovery**:
- If cleanup fails, registry remains in previous state (no partial cleanup)
- Next cleanup attempt can retry
- Consider backoff strategy if cleanup fails repeatedly

**Logging and Monitoring**:
- Log cleanup operations with stats (before, after, removed)
- Alert if cleanup fails repeatedly
- Track cleanup frequency and duration
- Monitor registry size growth trend
