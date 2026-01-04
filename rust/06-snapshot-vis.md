# Snapshot Visibility

## Purpose

Snapshot visibility is the core mechanism that enables Multi-Version Concurrency Control (MVCC) in NorthstarDB. It determines which transactions and their modifications are visible to a given snapshot, ensuring consistent reads without blocking concurrent writers. The visibility rules define how a snapshot calculates whether a committed transaction's changes should be included in queries, providing isolation guarantees that allow historical time-travel queries while maintaining serializable consistency.

## Core Concepts

### Snapshot Time

A snapshot represents the database state at a specific point in time, identified by its transaction ID. The snapshot time is the transaction ID assigned when the snapshot is created. All visibility decisions are made by comparing other transaction IDs against this snapshot time.

**Key Insight**: Transaction IDs are monotonically increasing, so they naturally encode ordering. If transaction A has ID 10 and transaction B has ID 20, then A committed before B. A snapshot with ID 15 should see A's changes but not B's.

### Commit Timestamp Tracking

Each transaction's commit time is recorded as its transaction ID. When a transaction commits, its transaction ID is permanently associated with all modifications it made. This association is stored in multiple places:

1. **Page Headers**: Each B+tree page header contains the `txn_id` of the transaction that last modified that page
2. **Commit Records**: The WAL commit record links the transaction ID with the new root page ID
3. **Snapshot Registry**: Maps transaction IDs to their root page IDs for snapshot lookup

### Visibility Determination

Visibility is calculated by comparing transaction IDs:
- A transaction is visible to a snapshot if its transaction ID is less than or equal to the snapshot's transaction ID
- Transactions with higher IDs committed after the snapshot was created and are not visible
- Transactions that were active (in-flight) or aborted are never visible to any snapshot

## Types

### VisibilityResult

**Description**: Represents the outcome of a visibility check for a single transaction or page modification.

**Variants**:
- `Visible` - The transaction's modifications are visible to this snapshot
- `NotVisible` - The transaction committed after the snapshot, or was aborted
- `InFlight` - The transaction was still active when the snapshot was created (never becomes visible)

**Invariants**:
- Only committed transactions can be `Visible`
- `InFlight` transactions transition to either `Visible` (if they commit with lower ID) or `NotVisible` (if they abort or commit with higher ID)
- Once a transaction is `Visible` to a snapshot, it remains `Visible` forever (snapshots are immutable)

### SnapshotVisibility

**Description**: Encapsulates the visibility calculation logic and context for a specific snapshot.

**Fields**:
- snapshot_txn_id: u64 - The transaction ID that defines this snapshot's point in time
- committed_txns: HashSet<u64> - Set of transaction IDs known to be committed (optimization cache)
- root_page_id: u64 - The B+tree root page ID for this snapshot

**Invariants**:
- snapshot_txn_id never changes after snapshot creation
- committed_txns is a subset of all committed transactions (may be incomplete for performance)
- root_page_id corresponds to snapshot_txn_id in the snapshot registry
- All visibility checks use snapshot_txn_id as the comparison baseline

## Functions

### is_visible(txn_id: u64, snapshot_txn_id: u64) -> bool

**Purpose**: Determine if a transaction with the given ID is visible to a snapshot.

**Parameters**:
- txn_id: The transaction ID to check for visibility
- snapshot_txn_id: The snapshot's transaction ID (point in time)

**Returns**: true if the transaction is visible, false otherwise

**Algorithm**:
1. If txn_id is 0 (initial/invalid transaction), return false
2. If txn_id is greater than snapshot_txn_id, return false (transaction committed after snapshot)
3. If txn_id equals snapshot_txn_id, return true (snapshot sees itself)
4. If txn_id is less than snapshot_txn_id, return true (transaction committed before snapshot)
5. Return the comparison result: txn_id <= snapshot_txn_id

**Error Conditions**: None (visibility is a pure calculation)

**Concurrency**: Read-only, thread-safe for concurrent access

### is_page_visible(page_txn_id: u64, snapshot_txn_id: u64) -> bool

**Purpose**: Determine if a B+tree page modification is visible to a snapshot.

**Parameters**:
- page_txn_id: The transaction ID stored in the page header (last modifier)
- snapshot_txn_id: The snapshot's transaction ID

**Returns**: true if the page is visible, false otherwise

**Algorithm**:
1. Use the same logic as is_visible: page_txn_id <= snapshot_txn_id
2. Return the comparison result

**Design Note**: Page visibility uses the same transaction ID comparison as transaction visibility. This uniformity simplifies the implementation.

**Concurrency**: Read-only, thread-safe

### get_visible_root(registry: &SnapshotRegistry, snapshot_txn_id: u64) -> Option<u64>

**Purpose**: Find the B+tree root page ID that represents the database state visible to a snapshot.

**Parameters**:
- registry: Reference to the snapshot registry containing historical snapshots
- snapshot_txn_id: The transaction ID for the snapshot

**Returns**: Some(root_page_id) if found, None if snapshot_txn_id is invalid

**Algorithm**:
1. Call registry.getSnapshotRoot(snapshot_txn_id)
2. If the registry returns a root page ID, return Some(root_page_id)
3. If the registry returns None (snapshot not found), return None
4. Handle the special case where snapshot_txn_id is greater than the current committed transaction:
   - Return the latest root page ID (read-your-latest semantics)

**Error Conditions**: None (Option handles missing snapshots)

**Concurrency**: Read-only access to snapshot registry

### should_include_mutation(mutation_txn_id: u64, snapshot_txn_id: u64) -> bool

**Purpose**: Determine if a mutation from a transaction should be included during B+tree traversal or WAL replay.

**Parameters**:
- mutation_txn_id: The transaction ID that created this mutation
- snapshot_txn_id: The snapshot's transaction ID

**Returns**: true if the mutation should be included, false to skip it

**Algorithm**:
1. Compare mutation_txn_id against snapshot_txn_id
2. If mutation_txn_id <= snapshot_txn_id, return true (include mutation)
3. Otherwise, return false (skip mutation - it's from a future transaction)

**Use Case**: During WAL replay for time-travel queries, or when reading page versions from storage.

**Concurrency**: Read-only, thread-safe

## Visibility Rules

### Basic Visibility Rule

**Core Rule**: A transaction T is visible to snapshot S if and only if T's transaction ID is less than or equal to S's transaction ID, AND T has successfully committed.

**Formula**: `visible(T, S) = (T.txn_id <= S.txn_id) AND (T.state == Committed)`

**Implications**:
- Historical snapshots see only transactions that committed before their creation
- Current snapshots see all committed transactions up to and including their own ID
- Future transactions (with higher IDs) are never visible to older snapshots

### Read-Your-Own-Writes

**Definition**: A transaction should see its own uncommitted mutations.

**Implementation**: Before checking B+tree visibility, check the transaction's write set:
1. If querying from within the same transaction that made the mutation, return the buffered value
2. Otherwise, proceed with normal visibility calculation

**Visibility Formula with Write-Your-Own-Writes**:
```
value = if my_txn.contains_key(key) {
    my_txn.get(key)  // Return my own uncommitted write
} else if page_txn_id <= snapshot_txn_id {
    btree_get(key)   // Page is visible, read from storage
} else {
    None             // Page not visible, key doesn't exist for this snapshot
}
```

**Note**: This rule primarily affects WriteTxn. ReadTxn never has its own writes.

### Read Committed vs Snapshot Isolation

**Read Committed**: Each query sees the latest committed transactions at query time.
- Snapshot is refreshed on each statement
- Different queries in same transaction may see different states
- Not the default in NorthstarDB

**Snapshot Isolation (Default)**: All queries in a transaction see the same snapshot.
- Snapshot is created once at transaction begin
- All queries use the same snapshot_txn_id
- Provides consistent historical view
- This is NorthstarDB's default isolation level

### Time-Travel Queries

**Definition**: Queries against historical snapshots explicitly specified by transaction ID.

**Use Cases**:
- Auditing: "What did the database look like yesterday?"
- Debugging: "What state caused this bug?"
- Analytics: "Trend analysis over time"

**Implementation**:
1. Call `begin_read_at(target_txn_id)` to create snapshot at specific transaction ID
2. Use the same visibility rules: only transactions with txn_id <= target_txn_id are visible
3. B+tree traversal starts from the root page ID registered for target_txn_id

**Example**: If current txn_id is 100, and you query snapshot at txn_id 50, you only see transactions 0-50, even though transactions 51-100 have committed.

## Visibility Edge Cases

### Concurrent Transactions

**Scenario**: Transaction A (txn_id 10) starts, Transaction B (txn_id 20) starts and commits, then A reads.

**Visibility**: A's snapshot has txn_id 10, which is less than B's txn_id 20.
- A does NOT see B's changes
- A sees the state as of when A began
- This is correct snapshot isolation behavior

### Aborted Transactions

**Rule**: Aborted transactions are never visible to any snapshot, regardless of transaction ID.

**Implementation**:
1. Aborted transactions never register snapshots
2. Their transaction IDs may have gaps (skipped numbers)
3. No root page ID is registered for aborted transaction IDs
4. Visibility check inherently fails because registry lookup returns None

**Recovery**: After crash, aborted transactions are simply not replayed, so they effectively never existed.

### In-Flight Transactions at Snapshot Creation

**Scenario**: Transaction A is active (not yet committed). Snapshot S is created with txn_id 15. Transaction A later commits with txn_id 12.

**Visibility**: Transaction A (txn_id 12) is visible to snapshot S (txn_id 15) because 12 <= 15.
- Even though A was in-flight when S was created, A committed with an earlier transaction ID
- This is possible if transactions allocate IDs at begin time but commit out of order
- The visibility rule based solely on transaction ID ordering handles this correctly

### Empty Transactions

**Scenario**: Transaction commits with zero mutations (no actual changes to B+tree).

**Visibility**: The transaction is visible (it committed), but has no effect on query results.
- Root page ID may be unchanged from previous transaction
- Snapshot registry still registers an entry (may reuse same root_page_id)
- Visibility calculations work correctly (no mutations to include or exclude)

### Single-Transaction Database

**Scenario**: Only one transaction has ever committed (txn_id 1). New snapshot is created at txn_id 1.

**Visibility**: Snapshot sees the initial transaction's changes.
- Genesis snapshot (txn_id 0) represents empty database
- Snapshot at txn_id 1 sees all changes from transaction 1
- This is the minimal non-trivial snapshot case

## Invariants

### Ordering Invariants
- Transaction IDs are strictly increasing over time
- For any two transactions A and B: if A committed before B, then A.txn_id < B.txn_id
- Snapshot visibility preserves this ordering: if A.txn_id < B.txn_id, then any snapshot with txn_id >= B.txn_id sees both A and B

### Consistency Invariants
- A snapshot always returns consistent results for repeated queries (no phantom reads)
- Once a transaction is visible to a snapshot, it remains visible forever (snapshot immutability)
- Two snapshots with the same txn_id always return identical query results

### Exclusivity Invariants
- A transaction is either visible, not visible, or in-flight relative to a given snapshot (mutually exclusive states)
- Aborted transactions are never visible to any snapshot
- Uncommitted (in-flight) transactions are only visible to themselves (read-your-own-writes)

### Registry Invariants
- The snapshot registry contains an entry for every committed transaction ID
- Genesis snapshot (txn_id 0) is always present
- Registry lookup returns None for non-existent or aborted transaction IDs

## Dependencies

### Uses
- TransactionId (task 1.4) - Transaction identifier type and ordering
- SnapshotRegistry (task 5.2) - Historical snapshot lookup by transaction ID
- PageHeader (task 2.1) - Page transaction ID for visibility checks
- CommitRecord (task 4.6) - Links transaction ID to root page ID

### Used By
- ReadTxn (task 4.3) - Get operations use visibility to filter results
- WriteTxn (task 4.4) - Read operations check write set before visibility
- B+tree traversal (task 4.5) - Page visibility determines which page versions to read
- Recovery (task 3.8) - WAL replay uses visibility to rebuild historical snapshots
- Time-travel queries (task 5.10) - Explicit historical snapshot creation

## Rust Implementation Guidance

### Module Structure

Visibility logic should be organized as:
```
src/snapshot/visibility.rs - Core visibility calculation functions
src/snapshot/mod.rs - Re-exports visibility functions
```

Public API:
```rust
pub fn is_visible(txn_id: u64, snapshot_txn_id: u64) -> bool;
pub fn is_page_visible(page_txn_id: u64, snapshot_txn_id: u64) -> bool;
```

### Type Definitions

**VisibilityResult** (optional, for structured results):
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VisibilityResult {
    Visible,
    NotVisible,
    InFlight,
}
```

**SnapshotVisibility** (encapsulates visibility context):
```rust
pub struct SnapshotVisibility {
    snapshot_txn_id: u64,
    committed_txns: HashSet<u64>,  // Cache of known committed transaction IDs
    root_page_id: u64,
}
```

### Implementation Notes

**Step 1: Core Visibility Function**
```rust
pub fn is_visible(txn_id: u64, snapshot_txn_id: u64) -> bool {
    // Invalid transaction ID (0) is never visible
    if txn_id == 0 {
        return false;
    }
    // Transaction is visible if it committed at or before snapshot time
    txn_id <= snapshot_txn_id
}
```

**Step 2: Page Visibility**
```rust
pub fn is_page_visible(page_txn_id: u64, snapshot_txn_id: u64) -> bool {
    is_visible(page_txn_id, snapshot_txn_id)
}
```

**Step 3: Get Visible Root**
```rust
pub fn get_visible_root(
    registry: &SnapshotRegistry,
    snapshot_txn_id: u64,
) -> Option<u64> {
    registry.getSnapshotRoot(snapshot_txn_id)
}
```

**Step 4: SnapshotVisibility Helper Methods**
```rust
impl SnapshotVisibility {
    pub fn new(snapshot_txn_id: u64, root_page_id: u64) -> Self {
        Self {
            snapshot_txn_id,
            committed_txns: HashSet::new(),
            root_page_id,
        }
    }

    pub fn is_visible(&self, txn_id: u64) -> bool {
        is_visible(txn_id, self.snapshot_txn_id)
    }

    pub fn is_page_visible(&self, page_txn_id: u64) -> bool {
        is_page_visible(page_txn_id, self.snapshot_txn_id)
    }

    pub fn root_page_id(&self) -> u64 {
        self.root_page_id
    }
}
```

### Key Decisions

**Pure Functions vs Methods**: Implement visibility as pure functions rather than methods on ReadTxn.
- Pure functions are easier to test and reason about
- Can be called from multiple contexts (recovery, validation, querying)
- No need to construct full ReadTxn just for visibility checks

**HashSet Cache**: The `committed_txns` cache in SnapshotVisibility is optional optimization.
- V0 implementation: Skip the cache, always use transaction ID comparison
- Future optimization: Cache committed transaction IDs for faster checks
- Cache invalidation: Must invalidate when new transactions commit

**No LSN-Based Visibility**: V0 uses only transaction ID for visibility, not LSN.
- LSN tracks log position, transaction ID tracks logical time
- Transaction ID ordering is sufficient for snapshot isolation
- Future: May add LSN-based visibility for point-in-time recovery

### Concurrency

**Read-Only Operations**: All visibility calculations are read-only.
- No locks needed for visibility checks
- Thread-safe to call from multiple concurrent readers
- Snapshot registry provides its own synchronization for lookups

**Immutable Snapshots**: Once created, snapshot visibility rules never change.
- SnapshotVisibility can be freely shared between threads
- Safe to store in Arc<SnapshotVisibility> for concurrent access
- No interior mutability needed

### Performance Considerations

**Hot Path**: Visibility checks are in the hot path for every read operation.
- `is_visible` must be extremely fast (single integer comparison)
- Avoid hashmap lookups or complex logic
- Inline the function to eliminate call overhead
- Compiler optimization: Mark with `#[inline]` attribute

**Branch Prediction**: The comparison `txn_id <= snapshot_txn_id` is predictable.
- Most pages in a B+tree are from older transactions (visible)
- Branch predictor will learn this pattern
- Consider using `likely`/`unlikely` hints if profiling shows benefit

**Cache Locality**: Transaction IDs are stored in page headers.
- Page header is already in cache when reading page
- No additional memory accesses needed for visibility check
- Single cache line contains both page data and transaction ID

### Testing Strategy

**Unit Tests Needed**:
- `visible_txn_before_snapshot` - Transaction with lower ID is visible
- `not_visible_txn_after_snapshot` - Transaction with higher ID is not visible
- `same_txn_visible_to_itself` - Transaction sees itself (txn_id == snapshot_txn_id)
- `genesis_not_visible_to_non_empty` - Genesis (0) not visible to non-empty snapshot
- `in_flight_not_visible` - In-flight transaction not visible to snapshot
- `aborted_not_visible` - Aborted transaction not visible to any snapshot
- `page_visibility_same_as_txn_visibility` - Page visibility uses same rule

**Property Tests**:
- `visibility_is_transitive` - If A visible to S and S visible to T, then A visible to T
- `visibility_is_total_order` - For any two txns, one is visible before/after the other
- `monotonic_visibility` - If txn visible to snapshot S, also visible to any snapshot T where T.txn_id > S.txn_id
- `snapshot_immutability` - Repeated queries to same snapshot return same results

**Integration Tests**:
- `concurrent_write_not_visible_to_old_reader` - Reader with old snapshot doesn't see concurrent commit
- `new_reader_sees_committed_state` - New reader after commit sees committed changes
- `time_travel_query` - Explicit historical snapshot returns correct state
- `read_your_own_writes` - Transaction sees its own uncommitted mutations

**Edge Cases**:
- `single_transaction_visibility` - Only one committed transaction
- `empty_database_snapshot` - Genesis snapshot with no committed transactions
- `transaction_out_of_order_commit` - Txn IDs allocated out of order
- `gap_in_transaction_ids` - Aborted transaction creates ID gap

**Performance Tests**:
- `visibility_check_latency` - Measure time per visibility check
- `visibility_in_read_path` - Measure overhead of visibility in get operations
- `cache_hit_rate` - If using committed_txns cache, measure hit rate

### Error Handling

**No Errors**: Visibility calculations are infallible.
- Always return bool (never Result<bool, Error>)
- Invalid transaction IDs return false (not an error, just not visible)
- Snapshot registry returns Option for missing snapshots (not an error)

**Recovery Context**: During recovery, visibility checks still work.
- Replaying WAL uses visibility to filter transactions
- Missing snapshots in registry are expected (aborted transactions)
- No special error handling needed
