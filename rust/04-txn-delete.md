# Transaction Delete Operation

## Purpose

The Delete operation removes a key-value pair from the database within a transaction. Delete is the write primitive for data removal, enabling applications to mark keys for deletion with atomic commit semantics. Like Put, Delete operations are buffered in memory within the transaction's pending mutation buffer, ensuring atomicity (all deletes succeed or none), enabling rollback capability, and providing read-your-writes semantics where deleted keys are immediately invisible to subsequent operations within the same transaction. The Delete operation uses tombstone semantics to represent deletions, ensuring that deleted keys override existing values and persist correctly through commit.

## Overview

### WriteTxn.delete()

WriteTxn.delete() marks a key for deletion by staging a Delete mutation in the transaction's pending mutation buffer. The operation does not immediately remove the key from the database; instead, it creates a tombstone that will be applied during commit. This buffering enables atomicity, rollback capability, and read-your-writes semantics where deleted keys return None for subsequent get operations. Delete operations are validated for key size limits, checked for transaction state, and integrated with the mutation tracking system using tombstone semantics that override both pending puts and existing database values.

### ReadTxn Write Exclusion

ReadTxn does not support delete operations. Read transactions are strictly read-only to ensure snapshot isolation and prevent accidental mutations. Attempting to call delete on a ReadTxn returns an error, as the ReadTxn type lacks the mutation buffer and transaction context required for staging deletions. Applications must begin a WriteTxn to perform delete operations.

## WriteTxn.delete() Operation

### Purpose

Mark a key for deletion by staging a Delete mutation (tombstone) in the transaction's pending mutation buffer.

### Signature

```
WriteTxn.delete(key: &[u8]) -> Result<(), Error>
```

### Parameters

**key**: Byte slice representing the key to delete
- Must be non-empty (zero-length keys are invalid)
- Must not exceed MAX_KEY_SIZE (4096 bytes)
- Compared lexicographically for ordering
- Binary safe (may contain any byte values including null bytes)
- Ownership: Key bytes are copied into transaction context

### Return Value

**Ok(())**: Delete operation successfully staged in mutation buffer
- Delete mutation (tombstone) added to pending operations
- Size tracking updated
- Mutation count adjusted (incremented or unchanged for duplicates)
- Key copied into transaction-owned memory

**Err(Error)**: Delete operation failed
- ValidationError: Key violates size constraints
- InvalidState: Transaction not in Active state
- TooManyMutations: Mutation count exceeds maximum allowed
- AllocationFailed: Memory allocation failed for key copy

### Algorithm

#### Step 1: Transaction State Validation

1. **Check Transaction State**: Verify transaction.state equals TransactionState::Active
   - If state is Preparing, return InvalidState error (no mutations after prepare)
   - If state is Committed, return InvalidState error (transaction complete)
   - If state is Aborted, return InvalidState error (transaction rolled back)
2. **Verify Mutation Capacity**: Check mutation_count less than MAX_OPERATIONS_PER_COMMIT
   - If limit exceeded, return TooManyMutations error
   - Prevents unbounded mutation buffer growth
   - Forces transaction commit before adding more mutations

#### Step 2: Input Validation

3. **Validate Key Non-Empty**: Check key.len() greater than 0
   - If key is empty, return KeyEmpty error
   - Empty keys are not supported in B+tree structure
4. **Validate Key Size**: Check key.len() less than or equal to MAX_KEY_SIZE
   - If key too large, return KeyTooLarge error
   - Prevents oversized keys from exceeding B+tree node capacity

#### Step 3: Existing Mutation Check

5. **Check Existing Pending Mutation**: Search pending_ops for existing entry with same key
   - Use HashMap lookup to find existing operation for key
   - If existing mutation is Delete, this delete is a no-op (idempotency)
   - If existing mutation is Put, remove Put mutation (delete overrides put)
   - If no existing mutation, proceed with Delete insertion

#### Step 4: Handle Idempotency (Duplicate Delete)

6. **Check for Existing Delete**: If existing mutation is already Delete
   - Return Ok(()) immediately without modifying buffer
   - Delete is idempotent: deleting same key twice has same effect as once
   - No size tracking changes (no new mutation added)
   - No mutation count increment (buffer unchanged)

#### Step 5: Handle Delete After Put

7. **Remove Overridden Put Mutation**: If existing mutation is Put
   - Remove Put mutation from pending_ops HashMap
   - Subtract Put mutation size from total_mutation_size
   - Decrement mutation_count (replacement, not addition)
   - Delete takes precedence over previous Put

#### Step 6: Stage Delete Mutation

8. **Allocate Key Copy**: Create owned Vec<u8> from key slice
   - Copies key bytes into transaction-owned memory
   - Ensures key data valid after caller's buffer is dropped
   - Allocation uses transaction's allocator
   - If allocation fails, return AllocationFailed error
9. **Create Delete Mutation**: Instantiate Mutation::Delete variant
   - Store owned key vector
   - Mutation type indicates deletion operation
   - No value payload in Delete mutation

#### Step 7: Integrate with Mutation Buffer

10. **Add to Pending Operations**: Insert mutation into pending_ops HashMap
    - HashMap key: hash of key bytes
    - HashMap value: (Mutation, Size) tuple where Mutation is Delete
    - Size is key.len() only (no value bytes in delete)
11. **Update Size Tracking**: Add delete mutation size to total_mutation_size
    - Delete size is key length only (smaller than Put)
    - Tracks total bytes buffered in transaction
    - Helps detect memory pressure before commit
12. **Increment Mutation Count**: Increment mutation_count by one
    - Tracks number of operations in transaction
    - Checked against MAX_OPERATIONS_PER_COMMIT limit
    - Used for commit statistics and validation

#### Step 8: Update Metrics

13. **Track Delete Operation**: Update transaction metrics
    - Increment delete_operations_count in metrics
    - Record timestamp for performance monitoring
    - Track cumulative delete keys length

### Tombstone Semantics

**Definition**: A Delete mutation is a tombstone that marks a key as deleted, overriding any existing value and making the key invisible to subsequent read operations.

**Tombstone Representation**:
- Mutation::Delete variant in pending_ops
- Contains only key bytes (no value payload)
- Serves as marker that key should not exist

**Tombstone Visibility**:
- get("key") returns None when Delete mutation exists in buffer
- scan operations skip keys with Delete mutations
- Tombstone overrides both pending puts and database values
- Consistent view: Deleted keys invisible within transaction

**Tombstone Persistence**:
- Delete mutations serialized to WAL during commit
- B+tree removal applied during commit phase
- Tombstone becomes actual key removal in database
- After commit, key permanently deleted (unless resurrected by later transaction)

### Idempotency Guarantees

**Delete Idempotency**: Calling delete multiple times for same key has same effect as calling once

**Implementation**:
- First delete: Adds Delete mutation to buffer
- Second delete: Detects existing Delete mutation, returns immediately (no-op)
- Third delete: Same as second, no change to buffer
- Final state: Key marked for deletion regardless of duplicate delete calls

**Benefits**:
- Application can call delete without checking if key exists
- Simplifies error handling (no "key not found" error for delete)
- Consistent with set-semantic deletion (deleting empty set is no-op)
- Reduces mutation count by avoiding duplicate entries

**Comparison with Put**:
- Put is NOT idempotent: put("key", "v1") then put("key", "v2") results in value "v2"
- Delete IS idempotent: delete("key") then delete("key") results in single deletion
- Put replaces value on duplicate; delete no-ops on duplicate

### Mutation Ordering

**Delete After Put**: Delete overrides Put
1. put("key", "value") stages Put mutation
2. delete("key") replaces Put with Delete mutation
3. Buffer contains only Delete mutation
4. get("key") returns None (tombstone)
5. On commit, key deleted (not inserted)

**Put After Delete**: Put overrides Delete
1. delete("key") stages Delete mutation
2. put("key", "value") replaces Delete with Put mutation
3. Buffer contains only Put mutation
4. get("key") returns "value"
5. On commit, key inserted (not deleted)

**Delete After Delete**: Idempotent no-op
1. delete("key") stages Delete mutation
2. delete("key") detects existing Delete, returns immediately
3. Buffer contains only one Delete mutation
4. Mutation count unchanged
5. get("key") returns None

**Chronological Ordering**: Most recent operation for key wins
- Mutations for same key processed in order received
- Last operation determines final state in buffer
- Commit applies final mutation for each key
- Intermediate mutations overridden by later operations

### Mutation Buffer Structure

**PendingOpsMap Type**: HashMap<Vec<u8>, (Mutation, usize)>

**HashMap Key**: Owned byte vector of key bytes
- Used for hash-based lookup (O(1) average)
- Enables fast duplicate detection for idempotency
- Owned data ensures lifetime safety

**HashMap Value for Delete**: (Mutation::Delete, usize)
- Mutation: Delete variant with owned key data
- Size: usize representing key length only (no value bytes)
- Size used for memory tracking and commit planning

**Delete Mutation Size**: key_len only
- Smaller than Put mutation (no value bytes)
- Includes overhead: HashMap entry plus enum overhead
- Tracked in total_mutation_size

**Buffer Growth**: HashMap grows dynamically as mutations added
- Delete mutations consume less memory than Put mutations
- Shared growth characteristics with Put operations
- No manual capacity management required

### Memory Allocation Strategy

**Key Copy**:
- Delete copies key bytes into transaction-owned memory
- Original slice can be dropped after delete returns
- No borrowed data in mutation buffer
- Safe to stage deletions from temporary buffers

**No Value Allocation**: Delete has no value payload
- Only key bytes allocated
- Smaller memory footprint than Put
- Faster allocation (single allocation vs two for Put)

**Allocation Failure Handling**:
- If key allocation fails, return AllocationFailed error
- Transaction remains valid after failed allocation
- Application can retry or rollback

**Memory Tracking**:
- Delete size is key length only
- total_mutation_size includes delete mutation sizes
- Helps detect memory pressure before commit
- Monitored for memory-based limits (future feature)

### Error Conditions

**KeyEmpty**: Key has zero length
- When: Application attempts delete with empty key slice
- Effect: delete returns immediately with KeyEmpty error
- Recovery: Application must use non-empty key
- Rationale: Empty keys not supported by B+tree structure

**KeyTooLarge**: Key size exceeds MAX_KEY_SIZE (4096 bytes)
- When: Application attempts delete with oversized key
- Effect: delete returns immediately with KeyTooLarge error
- Recovery: Application must use smaller key or different key design
- Rationale: Large keys exceed B+tree node capacity and reduce fanout

**InvalidState**: Transaction not in Active state
- When: Application calls delete after prepare, commit, or rollback
- Effect: delete returns InvalidState error
- Recovery: Application must begin new transaction
- State transitions causing InvalidState:
  - Active → Preparing (prepare called)
  - Active → Aborted (rollback called)
  - Preparing → Committed (commit called)

**TooManyMutations**: Mutation count exceeds MAX_OPERATIONS_PER_COMMIT (1000)
- When: Application attempts more than limit operations in one transaction
- Effect: delete returns TooManyMutations error
- Recovery: Application must commit and begin new transaction
- Rationale: Prevents unbounded buffer growth and enables commit batching

**AllocationFailed**: Memory allocation failed for key copy
- When: Out of memory during key copy operation
- Effect: delete returns AllocationFailed error
- Recovery: Application must free memory or rollback
- Transaction Safety: Transaction remains valid, can retry or rollback

### Invariants

**Mutation Buffer Consistency**:
- pending_ops contains all mutations staged but not committed
- Each key in pending_ops maps to exactly one mutation
- Mutation count equals number of entries in pending_ops
- total_mutation_size equals sum of sizes in pending_ops

**State Validity**:
- Mutations only accepted in Active state
- No mutations allowed after prepare called
- No mutations allowed after commit
- No mutations allowed after rollback

**Memory Safety**:
- All key data owned by transaction
- No borrowed data in mutation buffer
- Original slices can be dropped after delete returns
- Mutation data valid until transaction commit or rollback

**Tombstone Semantics**:
- Delete creates tombstone in pending_ops
- Tombstone visible to subsequent get operations (returns None)
- Tombstone visible to scan operations (key skipped)
- Tombstone overrides both pending puts and database values

**Idempotency**:
- Duplicate delete for same key is no-op
- Buffer unchanged on duplicate delete
- Mutation count unchanged on duplicate delete
- Size tracking unchanged on duplicate delete

### Performance Characteristics

**Time Complexity**:
- Validation: O(1) constant time checks
- Duplicate detection: O(1) average HashMap lookup
- Mutation insertion: O(1) average HashMap insert
- Key copy: O(k) where k is key length
- Overall: O(k) for copying key bytes

**Space Complexity**:
- Mutation buffer: O(m × k_avg) where m is mutation count (smaller than Put due to no values)
- Per-mutation overhead: HashMap entry overhead plus mutation enum
- Memory growth: Linear with number of unique keys deleted

**Comparison with Put**:
- Faster: Single allocation (key) vs two (key and value)
- Less memory: No value bytes stored
- Same complexity: O(k) vs O(k + v) for Put
- Idempotent: Duplicate detection avoids redundant entries

**Optimization Considerations**:
- HashMap provides O(1) duplicate detection (vs O(n) linear search)
- Idempotency avoids redundant entries for duplicate deletes
- Smaller memory footprint enables more deletes per transaction
- Size tracking enables memory pressure detection before commit

## Concurrency Considerations

### Single-Writer Design

**Exclusive Mutation Access**: Only one WriteTxn active at a time
- Writer lock held for entire transaction lifetime
- No concurrent mutation of pending_ops
- No synchronization needed within delete operation
- Safe to access pending_ops without locks

**Thread Safety of Delete Operation**:
- pending_ops HashMap local to transaction
- No shared mutable state between threads
- Mutation count and size tracking local to transaction
- No atomic operations required

**Lock Coordination**:
- Begin write: Acquires exclusive writer lock
- Delete operation: No locks (already have writer lock)
- Commit or rollback: Releases writer lock
- Next write transaction: Must wait for lock

### Delete Visibility Thread Safety

**Single-Threaded Mutation**: Tombstone visibility works within single transaction
- Mutation buffer not shared across threads
- Delete and get operations in same transaction serialized by caller
- No race conditions within transaction
- Transaction state transitions protected by lifetime and type system

### Future Concurrency (Post-V0)

**Potential Multi-Writer Scenarios**:
- Concurrent transactions on different data ranges
- Partitioned locking for reduced contention
- Conflict detection for overlapping deletes

**Current Guidance**: V0 assumes single writer, no concurrent mutation buffer access

## Tombstone Handling Mechanics

### Buffer Purpose

**Atomicity**: Tombstone enables all-or-nothing deletion
- Deletions staged in memory until commit
- Commit applies all deletions atomically
- Rollback discards all tombstones
- No partial deletion of database

**Rollback Capability**: Tombstone buffer enables undo
- Rollback discards entire tombstone buffer
- No database modifications if transaction rolled back
- Clean abort without residual effects

**Read-Your-Writes**: Tombstone enables intra-transaction delete visibility
- Deleted keys invisible to subsequent operations
- No database read required for tombstone visibility
- Consistent view within transaction

### Tombstone Lifecycle

**Creation**: delete() creates tombstone in buffer
- Tombstone is Delete mutation variant
- Contains only key bytes
- Marked for deletion but not yet removed from database

**Visibility**: get() and scan() respect tombstones
- get("deleted_key") returns None
- scan skips deleted keys
- Tombstone overrides database values
- Tombstone overrides pending puts

**Persistence**: Commit applies tombstone to database
- Delete mutation serialized to WAL
- B+tree removal operation executed
- Key physically removed from database
- Tombstone discarded after commit

**Expiration**: Tombstone removed after commit
- Mutation buffer cleared
- Tombstone no longer needed
- Deletion permanent in database

### Tombstone vs Put Mutation

**Size Difference**:
- Put mutation: key_len plus value_len bytes
- Delete mutation: key_len only (no value)
- Delete smaller: Enables more deletes per transaction

**Semantic Difference**:
- Put mutation: Key exists with value
- Delete mutation: Key marked for removal
- Put overrides: Replaces existing value or delete
- Delete overrides: Removes existing put or database value

**Visibility Difference**:
- Put mutation: get returns value
- Delete mutation: get returns None
- Put creates: Key visible after commit
- Delete removes: Key invisible after commit

## Interaction with Other Operations

### Delete followed by Get

**Tombstone Visibility**: Get returns None for deleted key
1. delete("key") creates tombstone in buffer
2. get("key") checks pending_ops first
3. Get finds Delete mutation, returns None
4. No database lookup performed
5. Consistent view: Application sees own delete

### Delete followed by Delete (Same Key)

**Idempotency**: Second delete is no-op
1. delete("key") stages tombstone
2. delete("key") detects existing tombstone
3. Second delete returns immediately (no changes)
4. Buffer unchanged (single tombstone)
5. Mutation count unchanged

### Delete followed by Put

**Put Overrides Delete**: Put replaces tombstone
1. delete("key") stages tombstone
2. put("key", "value") replaces tombstone with Put mutation
3. Buffer contains Put mutation only
4. get("key") returns "value"
5. Key inserted on commit (not deleted)

### Put followed by Delete

**Delete Overrides Put**: Delete replaces Put mutation
1. put("key", "value") stages Put mutation
2. delete("key") replaces Put with tombstone
3. Buffer contains Delete mutation only
4. get("key") returns None
5. Key deleted on commit (not inserted)

### Delete followed by Scan

**Scan Integration**: Scan skips deleted keys
1. delete("key") stages tombstone
2. scan("prefix", "key2") checks pending_ops during iteration
3. Scan skips "key" if in range
4. Merged view: Tombstone removes key from iteration
5. Consistent iteration: Deleted keys not returned

### Delete followed by Prepare

**Prepare Locks Buffer**: No mutations after prepare
1. delete("key") succeeds (transaction Active)
2. prepare() serializes mutations to WAL
3. delete("key2") fails (transaction Preparing)
4. Buffer frozen after prepare
5. No further mutations allowed

### Delete on Non-Existent Key

**Silent Success**: Deleting non-existent key succeeds
1. delete("nonexistent") stages tombstone
2. Tombstone added to buffer (no database check)
3. get("nonexistent") returns None
4. Commit: Delete operation applied to B+tree
5. Result: No-op (key not in database)
6. Rationale: Simplifies application logic (no need to check existence)

## Comparison: Delete vs Put Operations

### Similarities

**Both Use Mutation Buffer**:
- Operations staged in pending_ops HashMap
- Buffered until commit for atomicity
- Subject to same validation rules
- Same state machine constraints

**Both Support Read-Your-Writes**:
- Mutations visible to subsequent operations
- No commit required for intra-transaction visibility
- Consistent view within transaction

**Both Have Size Limits**:
- Key validation: MAX_KEY_SIZE (4096 bytes)
- Mutation count limit: MAX_OPERATIONS_PER_COMMIT (1000)
- State validation: Active state only

**Both Enable Rollback**:
- Mutations discarded on rollback
- No database modifications until commit
- Clean abort capability

### Differences

**Payload**:
- Put: key plus value (two allocations)
- Delete: key only (one allocation)
- Delete smaller memory footprint

**Semantics**:
- Put: Key exists with value (insert or update)
- Delete: Key marked for removal (tombstone)
- Put creates; Delete removes

**Get Visibility**:
- Put: get returns Some(value)
- Delete: get returns None
- Put shows value; Delete hides key

**Idempotency**:
- Put: NOT idempotent (put then put replaces value)
- Delete: IS idempotent (delete then delete is no-op)
- Put changes value; Delete no-ops on duplicate

**Behavior on Non-Existent Key**:
- Put: Inserts key (creates new entry)
- Delete: Stages tombstone (no-op if key not in database)
- Both succeed regardless of prior existence

**Memory Usage**:
- Put: O(k + v) per mutation
- Delete: O(k) per mutation (smaller)
- Delete enables more operations per transaction

## Testing Requirements

### Unit Tests

**Basic Delete Operations**:
- delete with existing key successfully stages tombstone
- delete returns Ok on success
- delete increments mutation count
- delete updates total_mutation_size correctly
- delete copies key into owned memory
- delete mutation size is key_len only (no value)

**Validation Tests**:
- delete with empty key returns KeyEmpty error
- delete with oversized key returns KeyTooLarge error
- delete with MAX_KEY_SIZE key succeeds
- delete has no value parameter (compilation error if value provided)

**State Validation Tests**:
- delete after prepare returns InvalidState error
- delete after commit returns InvalidState error
- delete after rollback returns InvalidState error
- delete in Active state succeeds

**Mutation Limit Tests**:
- delete with MAX_OPERATIONS_PER_COMMIT mutations succeeds
- delete with MAX_OPERATIONS_PER_COMMIT plus 1 mutations fails (TooManyMutations)

**Idempotency Tests**:
- delete followed by delete for same key is no-op
- duplicate delete does not increment mutation count
- duplicate delete does not change size tracking
- buffer contains single Delete mutation after duplicate deletes

**Interaction with Put Tests**:
- delete after put replaces put mutation
- put after delete replaces delete mutation
- delete then get returns None
- put then delete then get returns None
- delete then put then get returns value

**Read-Your-Writes Tests**:
- delete followed by get returns None
- delete followed by scan skips deleted key
- multiple deletes all visible to gets
- delete on non-existent key returns None on get

**Memory Allocation Tests**:
- delete with allocation failure returns AllocationFailed error
- delete allocates only key (no value allocation)
- delete memory usage smaller than put

### Integration Tests

**Transaction Workflow Tests**:
- begin, delete, commit: Key removed from database
- begin, delete, rollback: Key still in database
- begin, delete, get, commit: Read-your-writes before commit
- begin, put, delete, commit: Delete overrides put
- begin, delete, put, commit: Put overrides delete

**Multiple Delete Tests**:
- Multiple deletes for different keys: All applied on commit
- Multiple deletes for same key: Idempotent (no-op on duplicates)
- Interleaved deletes and puts: Correct semantics
- Large number of deletes (near limit): All succeed, then limit enforced

**Non-Existent Key Tests**:
- delete non-existent key: Succeeds (tombstone staged)
- delete then commit: No database change (key never existed)
- delete then get then commit: Returns None throughout

**Concurrency Tests**:
- Concurrent readers not blocked by delete (readers use old snapshots)
- Next writer waits for current writer (exclusive lock)
- Single transaction: No race conditions in delete

### Property Tests

**Idempotency Properties**:
- delete after delete for same key results in single tombstone
- Mutation count unchanged after duplicate delete
- Size tracking unchanged after duplicate delete
- Final state is key deleted regardless of duplicate count

**Commutativity Properties**:
- Order of deletes for different keys does not affect final state
- All keys deleted after commit
- No keys remain in database

**Ordering Properties**:
- put then delete for same key results in delete
- delete then put for same key results in put
- Last operation wins

**Size Tracking Properties**:
- total_mutation_size equals sum of all mutation sizes
- Delete size is key_len only (no value component)
- Delete size smaller than put size for same key

**State Machine Properties**:
- deletes only accepted in Active state
- prepare transition freezes mutation buffer
- commit or rollback ends transaction

### Hardening Tests

**Stress Tests**:
- Rapid delete operations: System remains stable
- Many delete operations: Limit enforced, no crashes
- Large keys: Validation handles all cases

**Crash Recovery Tests**:
- Delete before crash: Key not deleted if not committed
- Delete after prepare before crash: Recovery applies delete if commit record in WAL
- Delete without commit before crash: Database state unchanged

**Fuzzing Tests**:
- Random key sizes: Validation handles all cases
- Random operation sequences: Invariants maintained
- Random delete/put ordering: Correct semantics

## Error Handling Best Practices

### Validation First

**Check Before Mutating**: Validate inputs before modifying state
1. Check transaction state first (cheapest check)
2. Check mutation count limit (fast integer compare)
3. Check key size (fast length check)
4. Allocate key copy (most expensive, done last)

**Early Return on Error**: Return immediately on validation failure
- No state modified before validation complete
- Transaction remains valid after error
- Application can retry or rollback

### Idempotency Handling

**Detect Existing Delete**: Check buffer for existing tombstone
- HashMap lookup O(1) average
- Early return if Delete mutation exists
- No buffer modification
- Consistent idempotency guarantee

**No Error for Non-Existent Key**: Delete always succeeds if key valid
- No database lookup required
- No "key not found" error
- Simplifies application logic

### Allocation Failure Handling

**Clean Failure**: Allocation failure does not modify state
- Return error to application
- Transaction remains valid
- Application can retry or rollback

### State Enforcement

**Type System Guarantees**: Use Rust type system to prevent invalid state
- TransactionContext not accessible after commit
- WriteTxn consume on commit
- Compiler prevents use-after-commit

**Runtime Checks**: Validate state in delete operation
- Even if type system bypassed, runtime check catches error
- Defensive programming for safety

## Rust Implementation Guidance

### WriteTxn.delete() Method

**Function Signature**:
```
impl<'a> WriteTxn<'a> {
    pub fn delete(&mut self, key: &[u8]) -> Result<(), Error> {
        // Implementation follows algorithm described above
    }
}
```

**Key Implementation Steps**:
1. Check self.txn_ctx.state equals TransactionState::Active
2. Check self.txn_ctx.mutation_count less than MAX_OPERATIONS_PER_COMMIT
3. Validate key non-empty and size limit
4. Check pending_ops for existing mutation with same key
5. If existing mutation is Delete, return Ok(()) immediately (idempotency)
6. If existing mutation is Put, remove and update size tracking
7. Allocate key copy: Vec::from(key)
8. Create Mutation::Delete { key }
9. Insert into pending_ops HashMap
10. Update total_mutation_size (key length only)
11. Increment mutation_count
12. Update metrics

**Error Handling Pattern**:
```
match self.delete(key) {
    Ok(()) => { /* Tombstone staged, continue */ },
    Err(Error::KeyEmpty) => { /* Handle empty key */ },
    Err(Error::InvalidState) => { /* Transaction closed, begin new */ },
    Err(e) => { /* Other error, handle or rollback */ },
}
```

### Constants and Limits

**Size Limits**:
```
pub const MAX_KEY_SIZE: usize = 4096; // 4KB
pub const MAX_OPERATIONS_PER_COMMIT: usize = 1000;
```

**Note**: Delete has no value size limit (no value parameter)

### HashMap Usage

**PendingOpsMap Type**:
```
use std::collections::HashMap;

type PendingOpsMap = HashMap<Vec<u8>, (Mutation, usize)>;
```

**HashMap Key**: Owned Vec<u8> of key bytes
- Enables hash-based O(1) lookup
- Owned data ensures lifetime safety
- Hash computed on key bytes

**HashMap Value for Delete**: (Mutation::Delete, usize)
- Mutation: Delete variant with owned key data
- usize: Size in bytes (key length only, no value)

**Entry API for Idempotency and Replacement**:
```
use std::collections::hash_map::Entry;

match self.pending_ops.entry(key.to_vec()) {
    Entry::Vacant(entry) => {
        // No existing mutation, insert new delete
        let size = key.len();
        entry.insert((Mutation::Delete { key }, size));
        self.total_mutation_size += size;
        self.mutation_count += 1;
    }
    Entry::Occupied(entry) => {
        match entry.get().0 {
            Mutation::Delete { .. } => {
                // Existing delete, idempotent no-op
                return Ok(());
            }
            Mutation::Put { .. } => {
                // Existing put, replace with delete
                let old_size = entry.get().1;
                let new_size = key.len();
                entry.insert((Mutation::Delete { key }, new_size));
                self.total_mutation_size += new_size - old_size;
                // mutation_count unchanged (replacement, not addition)
            }
        }
    }
}
```

### Mutation Enum

**Delete Variant**:
```
pub enum Mutation {
    Put { key: Vec<u8>, value: Vec<u8> },
    Delete { key: Vec<u8> },
}
```

**Pattern Matching**: Handle both variants in operations
- get: Returns value for Put, None for Delete
- commit: Applies Put or removal for Delete
- size calculation: Different for Put vs Delete

### Memory Safety

**Owned Data Pattern**: Copy key into owned Vec
```
let owned_key: Vec<u8> = key.to_vec();
```

**Lifetime Independence**: Mutation data valid after caller drops
- Caller can drop original slice after delete returns
- Transaction owns mutation data
- No dangling references

**No Value Allocation**: Delete only allocates key
- Single allocation vs two for Put
- Smaller memory footprint
- Faster execution

**Drop Safety**: Mutations dropped when transaction dropped
- Rust Drop trait frees key vectors
- HashMap dropped, releasing all mutations
- No manual cleanup required

### Performance Optimizations

**Reserve Capacity**: Pre-allocate HashMap for expected mutations
```
self.pending_ops = HashMap::with_capacity(100);
```

**Avoid Rehashing**: Reduce resizing overhead
- Estimate average mutation count
- Reserve capacity at transaction begin
- Trade-off: Memory vs performance

**Idempotency Check**: Early return avoids buffer modification
- O(1) HashMap lookup
- No size tracking changes
- No count changes
- Faster than duplicate Put handling

### Metrics and Observability

**Track Delete Operations**:
```
self.metrics.delete_operations_count += 1;
self.metrics.bytes_deleted += key.len() as u64;
```

**Exposing Metrics**:
```
impl WriteTxn {
    pub fn mutation_count(&self) -> usize {
        self.txn_ctx.mutation_count
    }

    pub fn total_mutation_size(&self) -> usize {
        self.total_mutation_size
    }
}
```

### Testing Implementation

**Unit Test Example**:
```
#[test]
fn test_delete_basic() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    // Delete key
    txn.delete(b"key").unwrap();
    assert_eq!(txn.mutation_count(), 1);

    // Verify tombstone visibility
    assert_eq!(txn.get(b"key"), None);

    // Idempotency: delete again
    txn.delete(b"key").unwrap();
    assert_eq!(txn.mutation_count(), 1); // Unchanged (idempotent)
}
```

**Idempotency Test Example**:
```
#[test]
fn test_delete_idempotent() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.delete(b"key").unwrap();
    assert_eq!(txn.mutation_count(), 1);

    // Duplicate delete: no-op
    txn.delete(b"key").unwrap();
    assert_eq!(txn.mutation_count(), 1); // Count unchanged

    // Third delete: still no-op
    txn.delete(b"key").unwrap();
    assert_eq!(txn.mutation_count(), 1);
}
```

**Delete After Put Test Example**:
```
#[test]
fn test_delete_after_put() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.put(b"key", b"value").unwrap();
    assert_eq!(txn.mutation_count(), 1);

    // Delete overrides put
    txn.delete(b"key").unwrap();
    assert_eq!(txn.mutation_count(), 1); // Count unchanged (replacement)

    // Verify tombstone
    assert_eq!(txn.get(b"key"), None);
}
```

**Put After Delete Test Example**:
```
#[test]
fn test_put_after_delete() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.delete(b"key").unwrap();

    // Put overrides delete
    txn.put(b"key", b"value").unwrap();
    assert_eq!(txn.mutation_count(), 1); // Count unchanged (replacement)

    // Verify put visible
    assert_eq!(txn.get(b"key"), Some(b"value".to_vec()));
}
```

## Dependencies

- **Uses**:
  - WriteTxn type (mutation operations)
  - TransactionContext type (state and mutation tracking)
  - Mutation type (Delete variant)
  - TransactionState type (Active state check)
  - PendingOpsMap type (mutation buffer)
  - Error types (validation and state errors)
  - Constants (MAX_KEY_SIZE, MAX_OPERATIONS_PER_COMMIT)

- **Used By**:
  - Application code (delete operations)
  - Transaction integration (delete before commit)
  - Testing (mutation verification)
  - Cleanup operations (data removal)

## Related Specifications

- **WriteTxn**: rust/04-write-txn.md - Write transaction structure and mutation tracking
- **Transaction Put**: rust/04-txn-put.md - Put operation specification (complementary write operation)
- **TransactionContext**: rust/04-txn-context.md - Transaction state and mutation buffer
- **Transaction Get**: rust/04-txn-get.md - Read operation with tombstone visibility
- **Transaction Commit**: rust/04-txn-commit.md - Applying buffered mutations to database
- **Semantics**: spec/semantics_v0.md - ACID guarantees and delete semantics
