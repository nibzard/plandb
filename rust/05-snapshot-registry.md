# Snapshot Registry

## Purpose

The SnapshotRegistry is the central bookkeeping component for Multi-Version Concurrency Control (MVCC) in NorthstarDB. It maintains a mapping from committed transaction IDs to their corresponding B+tree root page IDs, enabling multiple concurrent readers to access consistent historical snapshots of the database while writes continue. The registry enables time-travel queries, provides snapshot isolation guarantees, and supports garbage collection of old snapshots to manage memory and storage overhead.

## Core Concepts

### Snapshot Definition

A snapshot represents a complete, consistent view of the database at a specific point in time, identified by a transaction ID. Each snapshot maps to a B+tree root page ID, which serves as the entry point for all reads at that transaction version.

**Key Insight**: In a B+tree-based storage engine, each committed transaction creates a new root page (either modified during the transaction or the same as before). The root page ID uniquely identifies the database state at that transaction.

### Registry Invariants

1. **Monotonic Transaction IDs**: Transaction IDs always increase. Newer transactions have higher IDs.
2. **Genesis Snapshot**: Transaction ID 0 always exists and represents the initial empty database state.
3. **Root Page Stability**: A root page ID for a given transaction ID never changes.
4. **Latest Snapshot**: The registry tracks the current (most recent) committed transaction.
5. **No Gaps**: The registry may not contain every transaction ID (some commits may not create new snapshots), but queried IDs always resolve to a valid root.

## Types

### SnapshotRegistry

**Description**: Main registry structure mapping transaction IDs to root page IDs
**Fields**:
- allocator: Allocator - Memory allocator for internal hashmap storage
- snapshots: HashMap<u64, u64> - Map from transaction ID to root page ID
- current_txn_id: u64 - Highest committed transaction ID (monotonically increasing)
- current_root_page_id: u64 - Root page ID for the current transaction

**Invariants**:
- snapshots always contains at least the genesis entry (0 -> initial_root_page_id)
- current_txn_id is always the maximum key in snapshots hashmap
- current_root_page_id always equals snapshots[current_txn_id]
- snapshots hashmap keys are transaction IDs (monotonically increasing values)
- snapshots hashmap values are valid page IDs (non-zero for non-empty databases)

### SnapshotStats

**Description**: Statistics about the snapshot registry state
**Fields**:
- total_snapshots: usize - Total number of snapshots tracked (including genesis)
- current_txn_id: u64 - Most recent committed transaction ID
- oldest_txn_id: u64 - Oldest transaction ID still in registry (usually 0 for genesis)
- newest_txn_id: u64 - Newest transaction ID (same as current_txn_id)

**Size**: 32 bytes (4 u64 fields on 64-bit platform, usize is 8 bytes)

**Invariants**:
- oldest_txn_id <= newest_txn_id == current_txn_id
- total_snapshots >= 1 (at least genesis)
- newest_txn_id is the maximum key in snapshots

## Functions

### init(allocator: Allocator, initial_txn_id: u64, initial_root_page_id: u64) -> Result<SnapshotRegistry, Error>

**Purpose**: Initialize a new snapshot registry with initial state
**Parameters**:
- allocator: Memory allocator for hashmap storage
- initial_txn_id: Starting committed transaction ID (typically 0 for new database, recovered value for existing)
- initial_root_page_id: Root page ID corresponding to initial_txn_id

**Returns**: Initialized SnapshotRegistry

**Algorithm**:
1. Create empty HashMap<u64, u64> with provided allocator
2. Insert genesis snapshot entry: key=0, value=initial_root_page_id
3. If initial_txn_id > 0, insert entry for initial_txn_id -> initial_root_page_id
4. Set current_txn_id = initial_txn_id
5. Set current_root_page_id = initial_root_page_id
6. Return initialized SnapshotRegistry

**Error Conditions**:
- AllocationFailed: HashMap allocation fails

**Concurrency**: Single-threaded initialization (typically during database open)

### deinit(&mut self)

**Purpose**: Clean up registry resources and free allocated memory
**Parameters**: None (self reference)
**Returns**: Unit

**Algorithm**:
1. Destroy snapshots HashMap (frees all internal allocations)
2. Registry struct is dropped

**Error Conditions**: None (cleanup must not panic)

**Concurrency**: Must not be called concurrently with any other registry operations

### registerSnapshot(&mut self, txn_id: u64, root_page_id: u64) -> Result<(), Error>

**Purpose**: Register a new committed transaction snapshot
**Parameters**:
- txn_id: Committed transaction ID (must be newer than current_txn_id)
- root_page_id: B+tree root page ID for this transaction

**Returns**: Unit on success

**Algorithm**:
1. Check if txn_id > self.current_txn_id, return early if not (no-op for old/stale txn_ids)
2. Insert (txn_id, root_page_id) into snapshots HashMap
3. Update self.current_txn_id = txn_id
4. Update self.current_root_page_id = root_page_id
5. Return success

**Error Conditions**:
- AllocationFailed: HashMap insertion fails

**Concurrency**: Must be externally synchronized (typically called by single writer during commit)

**Design Note**: The no-op behavior for old txn_ids is important for idempotency and recovery scenarios.

### getSnapshotRoot(&self, txn_id: u64) -> Option<u64>

**Purpose**: Get the root page ID for a specific transaction snapshot
**Parameters**:
- txn_id: Transaction ID to query

**Returns**: Some(root_page_id) if found, None for non-existent snapshots

**Algorithm**:
1. If txn_id > self.current_txn_id:
   - Return Some(self.current_root_page_id) (latest snapshot for future queries)
2. Otherwise:
   - Look up txn_id in snapshots HashMap
   - Return Some(root_page_id) if found
   - Return None if not found

**Error Conditions**: None (Option handles missing snapshots)

**Concurrency**: Read-only, safe for concurrent access with other reads

**Design Note**: Returning current snapshot for future txn_ids enables "read latest" semantics for time-travel queries.

### getLatestSnapshot(&self) -> u64

**Purpose**: Get the most recent snapshot root page ID
**Parameters**: None (self reference)
**Returns**: Current root page ID

**Algorithm**:
1. Return self.current_root_page_id

**Error Conditions**: None (registry always has a current snapshot)

**Concurrency**: Read-only, safe for concurrent access

### getCurrentTxnId(&self) -> u64

**Purpose**: Get the current committed transaction ID
**Parameters**: None (self reference)
**Returns**: Current transaction ID

**Algorithm**:
1. Return self.current_txn_id

**Error Conditions**: None

**Concurrency**: Read-only, safe for concurrent access

### hasSnapshot(&self, txn_id: u64) -> bool

**Purpose**: Check if a snapshot exists for the given transaction ID
**Parameters**:
- txn_id: Transaction ID to check

**Returns**: true if snapshot exists, false otherwise

**Algorithm**:
1. If txn_id > self.current_txn_id, return false (future snapshots don't exist)
2. Return snapshots.contains(txn_id)

**Error Conditions**: None

**Concurrency**: Read-only, safe for concurrent access

### cleanupOldSnapshots(&mut self, keep_txns: u64, keep_count: usize) -> Result<usize, Error>

**Purpose**: Garbage collection for old snapshots to free memory
**Parameters**:
- keep_txns: Minimum number of recent transactions to keep by age (0 = no age limit)
- keep_count: Minimum number of recent snapshots to keep regardless of age (protects N most recent)

**Returns**: Number of snapshots removed

**Algorithm**:
1. If snapshots.count() <= keep_count, return 0 (nothing to clean up)
2. Calculate cutoff_txn_id:
   - If self.current_txn_id > keep_txns: cutoff = self.current_txn_id - keep_txns
   - Else: cutoff = 0 (keep all by age)
3. Collect transaction IDs to remove:
   - Iterate through all snapshots entries
   - Skip genesis (txn_id == 0)
   - Calculate position_from_latest = self.current_txn_id - txn_id
   - If position_from_latest >= keep_count AND (keep_txns == 0 OR txn_id < cutoff):
     - Mark for removal
4. Remove marked transaction IDs from snapshots HashMap
5. Return count of removed entries

**Error Conditions**:
- AllocationFailed: Temporary allocation for removal list fails

**Concurrency**: Must be externally synchronized (pause new snapshots during cleanup)

**Design Notes**:
- Two-parameter strategy provides flexible cleanup policies
- keep_count ensures minimum number of snapshots for time-travel queries
- keep_txns enables age-based cleanup to bound snapshot history
- Genesis snapshot (txn_id 0) is never removed
- Example: cleanupOldSnapshots(100, 10) keeps snapshots from last 100 transactions OR at least 10 most recent

### getStats(&self) -> SnapshotStats

**Purpose**: Get statistics about registry state for monitoring
**Parameters**: None (self reference)
**Returns**: SnapshotStats with current metrics

**Algorithm**:
1. Initialize oldest_txn_id = self.current_txn_id, newest_txn_id = 0
2. Iterate through snapshots entries:
   - Update oldest_txn_id = min(oldest_txn_id, entry.txn_id)
   - Update newest_txn_id = max(newest_txn_id, entry.txn_id)
3. Return SnapshotStats:
   - total_snapshots = snapshots.count()
   - current_txn_id = self.current_txn_id
   - oldest_txn_id (calculated)
   - newest_txn_id (calculated)

**Error Conditions**: None

**Concurrency**: Read-only, safe for concurrent access

## Invariants

1. **Genesis Exists**: Transaction ID 0 is always present in snapshots
2. **Monotonic Current**: current_txn_id never decreases
3. **Current Consistency**: current_root_page_id always equals snapshots[current_txn_id]
4. **Valid Page IDs**: All root_page_id values are valid (non-zero for non-empty trees)
5. **Transaction Ordering**: Registered transaction IDs are strictly increasing
6. **No Duplicate Entries**: Each transaction ID appears at most once in snapshots

## Dependencies

- **Uses**: std::collections::HashMap (or equivalent concurrent hash map)
- **Used by**: Db (main database API), ReadTxn (for snapshot lookup), commit logic (for registration)

## Rust Implementation Guidance

### Module Structure

The Rust module should be organized as follows:
- Module name: snapshot
- Main file: src/snapshot/mod.rs or src/snapshot.rs
- Re-export in main database module: northstar_core::snapshot

### Type Definitions

**SnapshotRegistry struct**:
```rust
pub struct SnapshotRegistry {
    allocator: Allocator,
    snapshots: HashMap<u64, u64>,
    current_txn_id: u64,
    current_root_page_id: u64,
}
```

**Choice**: Use std::collections::HashMap for single-threaded scenarios
**Alternative**: Consider dashmap::DashMap for concurrent access if needed
**Reasoning**: Most operations are single-writer (registerSnapshot, cleanup), multiple readers

**Concurrency Strategy**:
- Option 1: Wrap entire SnapshotRegistry in RwLock<T> for simple concurrent access
- Option 2: Use Arc<SnapshotRegistry> with interior mutability via RwLock
- Option 3: Use dashmap::DashMap for lock-free reads (more complex, better read scalability)

**Recommended**: Start with RwLock<SnapshotRegistry> for simplicity, optimize later if needed.

### Key Decisions

**HashMap Choice**: std::collections::HashMap vs HashMapFX (fixed-size)
- Use std::collections::HashMap for flexibility
- Consider with_capacity for initial sizing (start with 16-32 entries)

**Allocation Error Handling**:
- HashMap operations (insert, with_capacity) can allocate
- Use Result return types for operations that can fail
- Consider fallible allocation APIs if available in your environment

**Cleanup Strategy**:
- cleanupOldSnapshots should not require additional allocations if possible
- Collect keys to remove first, then batch remove (two-pass approach)
- Alternative: retain() method on HashMap for filtering

### Implementation Notes

**Step 1: HashMap Initialization**
- Use HashMap::with_capacity(16) for initial registry
- Pre-allocate to avoid resizing during snapshot registration

**Step 2: Snapshot Registration**
- check for monotonic txn_id before inserting (early return if stale)
- Use HashMap::insert which overwrites existing entries (idempotent)
- Update current_* fields after successful insertion

**Step 3: Snapshot Lookup**
- Use HashMap::get for O(1) lookup
- Return Option<u64> for missing snapshots
- Special case: future txn_ids return current snapshot (not None)

**Step 4: Cleanup Implementation**
- Use retain() method for efficient filtering:
  ```rust
  self.snapshots.retain(|&txn_id, _| {
      txn_id == 0 || // keep genesis
      (self.current_txn_id - txn_id) < keep_count as u64 || // within keep_count
      txn_id >= cutoff_txn_id // within keep_txns age
  });
  ```
- Alternative: drain_filter() if available (stable Rust 1.78+)

**Step 5: Statistics**
- Single pass through HashMap for min/max calculation
- Use Iterator::min_by and Iterator::max_by for clarity

### Testing Strategy

**Unit tests needed for**:
- Initialization with zero and non-zero initial_txn_id
- Register snapshot with monotonic IDs
- Register snapshot with non-monotonic IDs (should be no-op)
- Get snapshot root for existing, missing, and future txn_ids
- Cleanup with various keep_txns and keep_count combinations
- Genesis snapshot preservation during cleanup
- Statistics accuracy

**Property tests for**:
- Monotonicity: current_txn_id never decreases
- Uniqueness: No duplicate transaction IDs
- Lookup consistency: getSnapshotRoot returns expected values
- Cleanup invariants: Genesis always preserved, minimum count/age respected

**Integration scenarios**:
- Database open with existing snapshots
- Transaction commit registration
- Time-travel query resolution
- Long-running reader with snapshot retention
- Garbage collection during active workload

**Edge cases**:
- Empty registry (only genesis)
- Single snapshot beyond genesis
- Very large registry (10000+ snapshots)
- Cleanup removing all non-genesis snapshots
- Query for transaction ID exactly at boundaries
- Overflow scenarios (unlikely with u64 but document)

### Performance Considerations

**Read Path** (getSnapshotRoot, getLatestSnapshot, getCurrentTxnId, hasSnapshot):
- HashMap lookup: O(1) average, O(n) worst case with hash collisions
- No allocations in hot path
- Cache-friendly: key and value are u64 (16 bytes total)

**Write Path** (registerSnapshot):
- HashMap insertion: O(1) average
- One allocation on HashMap resize
- Resize amortized over many insertions

**Cleanup Path** (cleanupOldSnapshots):
- Full HashMap scan: O(n) where n is snapshot count
- Should be called infrequently (background job)
- Can be optimized with BTreeMap if needed for range-based cleanup

**Memory Overhead**:
- Per entry: 16 bytes (key + value) + HashMap overhead (ptr + hash)
- Estimated: ~32-40 bytes per snapshot
- 1000 snapshots ~ 32-40 KB (acceptable overhead)

### Error Handling

**Recoverable Errors**:
- AllocationFailed: Return error, caller decides retry/abort
- NotFound: Return Option/Result for missing snapshots

**Unrecoverable/Panic**:
- Corrupted internal state: Panic to expose bugs
- Invariant violations: Panic with debug assertion

**Error Recovery**:
- Allocation failures: Log and retry or return error to caller
- Missing snapshots: Return None, let caller handle (e.g., begin_read_at fails)
