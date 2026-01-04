# Transaction Put Operation

## Purpose

The Put operation writes or updates a key-value pair within a transaction. Put is the fundamental write primitive in NorthstarDB transactions, enabling applications to insert new keys, update existing values, and stage mutations until commit. Put operations are buffered in memory within the transaction context, providing atomicity at commit time and enabling read-your-writes semantics for subsequent operations within the same transaction. The Put operation validates input, tracks mutation size, and integrates with the transaction's pending mutation buffer to ensure efficient commit processing.

## Overview

### WriteTxn.put()

WriteTxn.put() inserts or updates a key-value pair in the transaction's pending mutation buffer. The operation does not immediately write to the database; instead, it stages the mutation for atomic application during commit. This buffering enables atomicity (all writes succeed or none), rollback capability (discard uncommitted mutations), and read-your-writes semantics (subsequent get operations see pending puts). Put operations are validated for key and value size limits, checked for transaction state, and integrated with the mutation tracking system for efficient commit serialization.

### ReadTxn Write Exclusion

ReadTxn does not support put operations. Read transactions are strictly read-only to ensure snapshot isolation and prevent accidental mutations. Attempting to call put on a ReadTxn returns an error, as the ReadTxn type lacks the mutation buffer and transaction context required for staging writes. Applications must begin a WriteTxn to perform put operations.

## WriteTxn.put() Operation

### Purpose

Insert or update a key-value pair in the transaction's pending mutation buffer, staging the change for atomic commit.

### Signature

```
WriteTxn.put(key: &[u8], value: &[u8]) -> Result<(), Error>
```

### Parameters

**key**: Byte slice representing the key to insert or update
- Must be non-empty (zero-length keys are invalid)
- Must not exceed MAX_KEY_SIZE (4096 bytes)
- Compared lexicographically for ordering
- Binary safe (may contain any byte values including null bytes)
- Ownership: Key bytes are copied into transaction context

**value**: Byte slice representing the value to associate with the key
- May be empty (zero-length values are valid)
- Must not exceed MAX_VALUE_SIZE (16 MB)
- Binary safe (may contain any byte values)
- Ownership: Value bytes are copied into transaction context

### Return Value

**Ok(())**: Put operation successfully staged in mutation buffer
- Mutation added to pending operations
- Size tracking updated
- Mutation count incremented
- Key-value pair copied into transaction-owned memory

**Err(Error)**: Put operation failed
- ValidationError: Key or value violates size constraints
- InvalidState: Transaction not in Active state
- TooManyMutations: Mutation count exceeds maximum allowed
- AllocationFailed: Memory allocation failed for key/value copy

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
5. **Validate Value Size**: Check value.len() less than or equal to MAX_VALUE_SIZE
   - If value too large, return ValueTooLarge error
   - Prevents memory exhaustion from large values

#### Step 3: Duplicate Key Handling

6. **Check Existing Pending Mutation**: Search pending_ops for existing entry with same key
   - Use HashMap lookup to find existing operation for key
   - If found, remove existing mutation from buffer (last-write-wins)
   - Subtract size of existing mutation from size tracking
   - Decrement mutation_count if mutation was replaced (not appended)
7. **Last-Write-Wins Semantics**: Most recent put for a key wins
   - If key previously put in same transaction, old value is replaced
   - If key previously deleted in same transaction, delete is overridden
   - Only one mutation per key in pending_ops at any time

#### Step 4: Stage Mutation

8. **Allocate Key Copy**: Create owned Vec<u8> from key slice
   - Copies key bytes into transaction-owned memory
   - Ensures key data valid after caller's buffer is dropped
   - Allocation uses transaction's allocator
   - If allocation fails, return AllocationFailed error
9. **Allocate Value Copy**: Create owned Vec<u8> from value slice
   - Copies value bytes into transaction-owned memory
   - Ensures value data valid after caller's buffer is dropped
   - Allocation uses transaction's allocator
   - If allocation fails, free key copy and return AllocationFailed error
10. **Create Put Mutation**: Instantiate Mutation::Put variant
    - Store owned key vector
    - Store owned value vector
    - Mutation type indicates insert or update operation

#### Step 5: Integrate with Mutation Buffer

11. **Add to Pending Operations**: Insert mutation into pending_ops HashMap
    - HashMap key: hash of key bytes
    - HashMap value: (Mutation, Size) tuple
    - Size is key.len() plus value.len() for memory tracking
12. **Update Size Tracking**: Add new mutation size to total_mutation_size
    - Tracks total bytes buffered in transaction
    - Used for memory management and commit planning
    - Helps detect memory pressure before commit
13. **Increment Mutation Count**: Increment mutation_count by one
    - Tracks number of operations in transaction
    - Checked against MAX_OPERATIONS_PER_COMMIT limit
    - Used for commit statistics and validation

#### Step 6: Update Metrics

14. **Track Write Operation**: Update transaction metrics
    - Increment put_operations_count in metrics
    - Record timestamp for performance monitoring
    - Track cumulative bytes written (key plus value length)

### Read-Your-Writes Guarantee

**Definition**: A put operation is immediately visible to subsequent get operations within the same transaction, even before commit.

**Implementation**:
- Mutation added to pending_ops before put returns
- Subsequent get calls check pending_ops first
- Get returns pending value without database lookup
- No commit required for intra-transaction visibility

**Example Sequence**:
1. Transaction begins
2. put("a", "v1") called, mutation staged in buffer
3. get("a") called, returns "v1" from pending_ops (not database)
4. put("a", "v2") called, replaces previous mutation
5. get("a") called, returns "v2" (latest write)
6. commit called, mutations applied to database atomically

### Duplicate Key Handling Strategy

**Last-Write-Wins Semantics**: Most recent put operation for a given key wins

**Implementation**:
- HashMap ensures only one entry per key
- New put overwrites previous put or delete for same key
- Size tracking accounts for replacement (old size removed, new size added)
- Mutation count reflects total operations, not unique keys

**Scenarios**:
1. **Put followed by Put for same key**: Second put replaces first
   - First mutation removed from buffer
   - First mutation size subtracted from total
   - Second mutation added
   - Second mutation size added to total
   - Net result: Only second mutation in buffer

2. **Delete followed by Put for same key**: Put overrides delete
   - Delete mutation removed from buffer
   - Delete size subtracted from total
   - Put mutation added
   - Put size added to total
   - Net result: Key exists with new value

3. **Put followed by Delete for same key**: Delete overrides put
   - Put mutation removed from buffer
   - Put size subtracted from total
   - Delete mutation added
   - Delete size (key length only) added to total
   - Net result: Key marked for deletion

### Mutation Buffer Structure

**PendingOpsMap Type**: HashMap<Vec<u8>, (Mutation, usize)>

**HashMap Key**: Owned byte vector of key bytes
- Used for hash-based lookup (O(1) average)
- Enables fast duplicate detection
- Owned data ensures lifetime safety

**HashMap Value**: Tuple of (Mutation, Size)
- Mutation: Enum variant (Put or Delete) with owned data
- Size: usize representing key_len plus value_len (for Put) or key_len only (for Delete)
- Size used for memory tracking and commit planning

**Buffer Growth**: HashMap grows dynamically as mutations added
- Initial capacity: Small (e.g., 16 entries) to reduce memory overhead
- Resize on capacity threshold: HashMap automatically resizes
- No manual capacity management required

### Memory Allocation Strategy

**Key and Value Copies**:
- Put copies key and value bytes into transaction-owned memory
- Original slices can be dropped after put returns
- No borrowed data in mutation buffer
- Safe to stage mutations from temporary buffers

**Allocation Failure Handling**:
- If key allocation fails, return AllocationFailed error
- If value allocation fails after key success, free key and return error
- Transaction remains valid after failed allocation
- Application can retry with smaller data or rollback

**Memory Tracking**:
- total_mutation_size tracks all buffered bytes
- Helps detect memory pressure
- Used for commit planning (large mutations may require flush)
- Monitored for memory-based limits (future feature)

### Error Conditions

**KeyEmpty**: Key has zero length
- When: Application attempts put with empty key slice
- Effect: put returns immediately with KeyEmpty error
- Recovery: Application must use non-empty key
- Rationale: Empty keys not supported by B+tree structure

**KeyTooLarge**: Key size exceeds MAX_KEY_SIZE (4096 bytes)
- When: Application attempts put with oversized key
- Effect: put returns immediately with KeyTooLarge error
- Recovery: Application must use smaller key or different key design
- Rationale: Large keys exceed B+tree node capacity and reduce fanout

**ValueTooLarge**: Value size exceeds MAX_VALUE_SIZE (16 MB)
- When: Application attempts put with oversized value
- Effect: put returns immediately with ValueTooLarge error
- Recovery: Application must use smaller value or chunk data
- Rationale: Prevents memory exhaustion and enables efficient commit

**InvalidState**: Transaction not in Active state
- When: Application calls put after prepare, commit, or rollback
- Effect: put returns InvalidState error
- Recovery: Application must begin new transaction
- State transitions causing InvalidState:
  - Active → Preparing (prepare called)
  - Active → Aborted (rollback called)
  - Preparing → Committed (commit called)

**TooManyMutations**: Mutation count exceeds MAX_OPERATIONS_PER_COMMIT (1000)
- When: Application attempts more than limit operations in one transaction
- Effect: put returns TooManyMutations error
- Recovery: Application must commit and begin new transaction
- Rationale: Prevents unbounded buffer growth and enables commit batching

**AllocationFailed**: Memory allocation failed for key or value copy
- When: Out of memory during copy operation
- Effect: put returns AllocationFailed error
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
- All key and value data owned by transaction
- No borrowed data in mutation buffer
- Original slices can be dropped after put returns
- Mutation data valid until transaction commit or rollback

**Read-Your-Writes**:
- Put visible to subsequent get in same transaction
- Put visible to subsequent scan in same transaction
- Put takes precedence over database value
- Most recent put for key wins

### Performance Characteristics

**Time Complexity**:
- Validation: O(1) constant time checks
- Duplicate detection: O(1) average HashMap lookup
- Mutation insertion: O(1) average HashMap insert
- Key and value copy: O(k + v) where k is key length, v is value length
- Overall: O(k + v) for copying key and value bytes

**Space Complexity**:
- Mutation buffer: O(m × (k_avg + v_avg)) where m is mutation count
- Per-mutation overhead: HashMap entry overhead plus mutation enum
- Memory growth: Linear with number of unique keys mutated

**Optimization Considerations**:
- HashMap provides O(1) duplicate detection (vs O(n) linear search)
- Owned data enables safe lifetime management without borrow checker complexity
- Size tracking enables memory pressure detection before commit
- Batch operations (future) can reduce per-mutation overhead

## Concurrency Considerations

### Single-Writer Design

**Exclusive Mutation Access**: Only one WriteTxn active at a time
- Writer lock held for entire transaction lifetime
- No concurrent mutation of pending_ops
- No synchronization needed within put operation
- Safe to access pending_ops without locks

**Thread Safety of Put Operation**:
- pending_ops HashMap local to transaction
- No shared mutable state between threads
- Mutation count and size tracking local to transaction
- No atomic operations required

**Lock Coordination**:
- Begin write: Acquires exclusive writer lock
- Put operation: No locks (already have writer lock)
- Commit or rollback: Releases writer lock
- Next write transaction: Must wait for lock

### Read-Your-Writes Thread Safety

**Single-Threaded Mutation**: Read-your-writes works within single transaction
- Mutation buffer not shared across threads
- Get and put operations in same transaction serialized by caller
- No race conditions within transaction
- Transaction state transitions protected by lifetime and type system

### Future Concurrency (Post-V0)

**Potential Multi-Writer Scenarios**:
- Concurrent transactions on different data ranges
- Partitioned locking for reduced contention
- Optimistic concurrency control with conflict detection

**Current Guidance**: V0 assumes single writer, no concurrent mutation buffer access

## Write Buffering Mechanics

### Buffer Purpose

**Atomicity**: Buffer enables all-or-nothing commit
- Mutations staged in memory until commit
- Commit applies all mutations atomically
- Rollback discards all mutations
- No partial application to database

**Rollback Capability**: Buffer enables undo
- Rollback discards entire mutation buffer
- No database modifications if transaction rolled back
- Clean abort without residual effects

**Read-Your-Writes**: Buffer enables intra-transaction visibility
- Mutations visible to subsequent operations
- No database read required for pending writes
- Consistent view within transaction

### Buffer Management

**Memory Allocation**:
- Mutations stored in HashMap for efficient lookup
- Key and value bytes copied into owned Vec
- No borrowed data from application
- Allocation using transaction allocator

**Capacity Management**:
- No hard capacity limit on buffered bytes
- Soft limit via MAX_OPERATIONS_PER_COMMIT (mutation count)
- total_mutation_size tracks bytes for monitoring
- Large mutations may trigger memory pressure handling (future)

**Eviction Policy**: No eviction
- All mutations retained until commit or rollback
- Buffer grows monotonically during transaction
- Trade-off: Memory usage for atomicity and rollback

### Size Tracking

**Per-Mutation Size Calculation**:
- Put mutation: key_len plus value_len
- Delete mutation: key_len only (no value)
- Size excludes HashMap overhead and enum overhead
- Size used for memory tracking and commit planning

**Total Mutation Size**:
- Sum of all mutation sizes in buffer
- Incremented on each put or delete
- Decremented on duplicate replacement (old size removed)
- Used for commit planning (large buffers may require flush)

**Monitoring**:
- Applications can query total_mutation_size
- Helps detect memory pressure
- Enables proactive commit for large transactions
- Used for performance analysis

## Interaction with Other Operations

### Put followed by Get

**Read-Your-Writes**: Get returns pending put value
1. put("key", "value") stages mutation in buffer
2. get("key") checks pending_ops first
3. Get returns "value" from buffer (not database)
4. No database lookup performed
5. Consistent view: Application sees own write

### Put followed by Put (Same Key)

**Last-Write-Wins**: Second put replaces first
1. put("key", "value1") stages mutation
2. put("key", "value2") replaces first mutation
3. Buffer contains only second mutation
4. get("key") returns "value2"
5. Only second mutation written on commit

### Put followed by Delete

**Delete Overrides Put**: Delete removes pending put
1. put("key", "value") stages mutation
2. delete("key") replaces put mutation with delete
3. Buffer contains delete mutation only
4. get("key") returns None (tombstone)
5. Key deleted on commit (not inserted)

### Put followed by Scan

**Scan Integration**: Scan includes pending puts
1. put("key", "value") stages mutation
2. scan("prefix", "key2") checks pending_ops during iteration
3. Scan returns "key" with "value" if in range
4. Merged view: Pending mutations plus database state
5. Consistent iteration: All mutations visible

### Put followed by Prepare

**Prepare Locks Buffer**: No mutations after prepare
1. put("key", "value") succeeds (transaction Active)
2. prepare() serializes mutations to WAL
3. put("key2", "value2") fails (transaction Preparing)
4. Buffer frozen after prepare
5. No further mutations allowed

## Testing Requirements

### Unit Tests

**Basic Put Operations**:
- put with new key successfully stages mutation
- put with existing key replaces previous mutation
- put returns Ok on success
- put increments mutation count
- put updates total_mutation_size correctly
- put copies key and value into owned memory

**Validation Tests**:
- put with empty key returns KeyEmpty error
- put with oversized key returns KeyTooLarge error
- put with oversized value returns ValueTooLarge error
- put with MAX_KEY_SIZE key succeeds
- put with MAX_VALUE_SIZE value succeeds
- put with empty value succeeds (zero-length values valid)

**State Validation Tests**:
- put after prepare returns InvalidState error
- put after commit returns InvalidState error
- put after rollback returns InvalidState error
- put in Active state succeeds

**Mutation Limit Tests**:
- put with MAX_OPERATIONS_PER_COMMIT mutations succeeds
- put with MAX_OPERATIONS_PER_COMMIT plus 1 mutations fails (TooManyMutations)
- put after replacing mutation still respects count limit

**Duplicate Handling Tests**:
- put followed by put for same key replaces first mutation
- put after delete for same key overrides delete
- put followed by delete for same key allows delete to override
- duplicate put updates size tracking correctly (old size removed, new added)

**Read-Your-Writes Tests**:
- put followed by get returns pending value
- put followed by scan includes pending mutation
- put followed by put for same key returns latest value on get
- multiple puts for different keys all visible to gets

**Memory Allocation Tests**:
- put with allocation failure returns AllocationFailed error
- put with large allocation succeeds (system has memory)
- put copies data correctly (original buffer can be dropped)

### Integration Tests

**Transaction Workflow Tests**:
- begin, put, commit: Mutation applied to database
- begin, put, rollback: Mutation discarded
- begin, put, get, commit: Read-your-writes before commit
- begin, put, prepare, commit: Two-phase commit workflow
- begin, put, prepare, rollback: Rollback after prepare

**Multiple Put Tests**:
- Multiple puts for different keys: All applied on commit
- Multiple puts for same key: Last write wins
- Interleaved puts and deletes: Correct semantics
- Large number of puts (near limit): All succeed, then limit enforced

**Concurrency Tests**:
- Concurrent readers not blocked by put (readers use old snapshots)
- Next writer waits for current writer (exclusive lock)
- Single transaction: No race conditions in put

### Property Tests

**Idempotency Properties**:
- put after put for same key results in single mutation
- Final value is last value written
- Size tracking reflects final mutation size

**Commutativity Properties**:
- Order of puts for different keys does not affect final state
- All keys present in database after commit
- Each key has correct value from last put

**Size Tracking Properties**:
- total_mutation_size equals sum of all mutation sizes
- Duplicate replacement correctly updates total size
- Size after rollback equals zero

**State Machine Properties**:
- puts only accepted in Active state
- prepare transition freezes mutation buffer
- commit or rollback ends transaction

### Hardening Tests

**Stress Tests**:
- Rapid put operations: System remains stable
- Large values: Memory management handles correctly
- Many mutations: Limit enforced, no crashes

**Crash Recovery Tests**:
- Put before crash: Mutation not in database if not committed
- Put after prepare before crash: Recovery applies mutation if commit record in WAL
- Put without commit before crash: Database state unchanged

**Fuzzing Tests**:
- Random key sizes: Validation handles all cases
- Random value sizes: Validation handles all cases
- Random operation sequences: Invariants maintained

## Error Handling Best Practices

### Validation First

**Check Before Mutating**: Validate inputs before modifying state
1. Check transaction state first (cheapest check)
2. Check mutation count limit (fast integer compare)
3. Check key and value sizes (fast length checks)
4. Allocate copies (most expensive, done last)

**Early Return on Error**: Return immediately on validation failure
- No state modified before validation complete
- Transaction remains valid after error
- Application can retry or rollback

### Allocation Failure Handling

**Rollback on Failure**: Clean up partial allocations
- If value allocation fails after key success, free key
- Return error to application
- Transaction state unchanged (mutation not added)

**Retry Strategy**: Application choice
- Retry with smaller data
- Rollback and free memory
- Abort operation

### State Enforcement

**Type System Guarantees**: Use Rust type system to prevent invalid state
- TransactionContext not accessible after commit
- WriteTxn consume on commit
- Compiler prevents use-after-commit

**Runtime Checks**: Validate state in put operation
- Even if type system bypassed, runtime check catches error
- Defensive programming for safety

## Rust Implementation Guidance

### WriteTxn.put() Method

**Function Signature**:
```
impl<'a> WriteTxn<'a> {
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), Error> {
        // Implementation follows algorithm described above
    }
}
```

**Key Implementation Steps**:
1. Check self.txn_ctx.state equals TransactionState::Active
2. Check self.txn_ctx.mutation_count less than MAX_OPERATIONS_PER_COMMIT
3. Validate key non-empty and size limit
4. Validate value size limit
5. Check pending_ops for existing mutation with same key
6. If exists, remove and update size tracking
7. Allocate key copy: Vec::from(key)
8. Allocate value copy: Vec::from(value)
9. Create Mutation::Put { key, value }
10. Insert into pending_ops HashMap
11. Update total_mutation_size
12. Increment mutation_count
13. Update metrics

**Error Handling Pattern**:
```
match self.put(key, value) {
    Ok(()) => { /* Mutation staged, continue */ },
    Err(Error::KeyEmpty) => { /* Handle empty key */ },
    Err(Error::InvalidState) => { /* Transaction closed, begin new */ },
    Err(e) => { /* Other error, handle or rollback */ },
}
```

### Constants and Limits

**Size Limits**:
```
pub const MAX_KEY_SIZE: usize = 4096; // 4KB
pub const MAX_VALUE_SIZE: usize = 16 * 1024 * 1024; // 16MB
pub const MAX_OPERATIONS_PER_COMMIT: usize = 1000;
```

**Rationale for Limits**:
- MAX_KEY_SIZE: Fits in B+tree node, enables good fanout
- MAX_VALUE_SIZE: Prevents memory exhaustion, enables efficient commit
- MAX_OPERATIONS_PER_COMMIT: Prevents unbounded buffer growth

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

**HashMap Value**: (Mutation, usize) tuple
- Mutation: Operation enum with owned data
- usize: Size in bytes (key_len plus value_len for Put)

**Entry API for Duplicate Handling**:
```
use std::collections::hash_map::Entry;

match self.pending_ops.entry(key.to_vec()) {
    Entry::Vacant(entry) => {
        // No existing mutation, insert new
        let size = key.len() + value.len();
        entry.insert((Mutation::Put { key, value }, size));
        self.total_mutation_size += size;
    }
    Entry::Occupied(mut entry) => {
        // Existing mutation, replace (last-write-wins)
        let old_size = entry.get().1;
        let new_size = key.len() + value.len();
        entry.insert((Mutation::Put { key, value }, new_size));
        self.total_mutation_size += new_size - old_size;
    }
}
```

### Memory Safety

**Owned Data Pattern**: Copy key and value into owned Vec
```
let owned_key: Vec<u8> = key.to_vec();
let owned_value: Vec<u8> = value.to_vec();
```

**Lifetime Independence**: Mutation data valid after caller drops
- Caller can drop original slices after put returns
- Transaction owns mutation data
- No dangling references

**Drop Safety**: Mutations dropped when transaction dropped
- Rust Drop trait frees key and value vectors
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

**Bulk Operations**: Future optimization for batch puts
- Accept iterator of (key, value) pairs
- Reserve once, insert all
- Reduce per-put overhead

### Metrics and Observability

**Track Put Operations**:
```
self.metrics.put_operations_count += 1;
self.metrics.bytes_written += (key.len() + value.len()) as u64;
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
fn test_put_basic() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    // Put new key
    txn.put(b"key", b"value").unwrap();
    assert_eq!(txn.mutation_count(), 1);

    // Put same key (replace)
    txn.put(b"key", b"value2").unwrap();
    assert_eq!(txn.mutation_count(), 1); // Count unchanged (replacement)

    // Verify read-your-writes
    assert_eq!(txn.get(b"key"), Some(b"value2".to_vec()));
}
```

**Validation Test Example**:
```
#[test]
fn test_put_empty_key() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    let result = txn.put(b"", b"value");
    assert_eq!(result, Err(Error::KeyEmpty));
}
```

## Dependencies

- **Uses**:
  - WriteTxn type (mutation operations)
  - TransactionContext type (state and mutation tracking)
  - Mutation type (Put variant)
  - TransactionState type (Active state check)
  - PendingOpsMap type (mutation buffer)
  - Error types (validation and state errors)
  - Constants (MAX_KEY_SIZE, MAX_VALUE_SIZE, MAX_OPERATIONS_PER_COMMIT)

- **Used By**:
  - Application code (write operations)
  - Batch operations (multiple puts)
  - Transaction integration (put before commit)
  - Testing (mutation verification)

## Related Specifications

- **WriteTxn**: rust/04-write-txn.md - Write transaction structure and mutation tracking
- **TransactionContext**: rust/04-txn-context.md - Transaction state and mutation buffer
- **Transaction Begin**: rust/04-txn-begin.md - Transaction initialization and buffer setup
- **Transaction Get**: rust/04-txn-get.md - Read operation with pending mutation visibility
- **Transaction Commit**: rust/04-txn-commit.md - Applying buffered mutations to database
- **Semantics**: spec/semantics_v0.md - ACID guarantees and write semantics
