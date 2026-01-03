# Transaction Get Operation

## Purpose

The Get operation retrieves a value by key from a transaction, providing different semantics for read and write transactions. For ReadTxn, Get provides snapshot isolation by reading from a fixed point in time. For WriteTxn, Get implements read-your-writes semantics by checking pending mutations before consulting the database. The Get operation is the fundamental read primitive, supporting point lookups with consistent visibility guarantees.

## Overview

### ReadTxn.get()

ReadTxn.get() performs a snapshot-based lookup that always reads from the transaction's fixed snapshot. All reads within a ReadTxn see the same database state, regardless of concurrent writers or subsequent commits. The snapshot is identified by txn_id and root_page_id, ensuring time-travel queries and historical reads return consistent results.

### WriteTxn.get()

WriteTxn.get() implements read-your-writes semantics by checking the transaction's pending mutations before consulting the database. If a key was modified within the current transaction, Get returns the pending value (or null if deleted). Otherwise, Get reads from the committed database state. This ensures the transaction always sees its own writes, even before commit.

## ReadTxn.get() Operation

### Purpose

Retrieve a value by key from a read-only transaction's snapshot, providing snapshot isolation guarantees.

### Signature

```
ReadTxn.get(key: &[u8]) -> Option<Value>
```

### Parameters

**key**: Byte slice representing the key to look up
- Must be non-empty
- Must not exceed MAX_KEY_SIZE (4096 bytes)
- Compared lexicographically with stored keys

### Return Value

**Some(Value)**: Key exists in the snapshot
- Value is an owned byte vector allocated from the transaction's allocator
- Value may be empty (zero-length)
- Value lifetime is independent of the transaction

**None**: Key does not exist in the snapshot
- Key was never inserted
- Key was deleted before the snapshot's txn_id
- Key is outside the snapshot's visibility

### Algorithm

#### File-Based Databases

1. **Check Database Type**: Verify pager exists (file-based database)
2. **Allocate Temporary Buffer**: Create stack buffer for value read
3. **B+Tree Lookup**:
   - Call `pager.getBtreeValueAtRoot(key, buffer, root_page_id)`
   - Use snapshot's root_page_id, NOT current database root
   - Traverses B+tree from snapshot root to find key
4. **Handle Errors**:
   - CorruptBtree: Return None (database corruption treated as not found)
   - BufferTooSmall: Return None (value too large for buffer)
   - Other errors: Return None
5. **Allocate Value Copy**:
   - If value found, allocate copy from transaction allocator
   - Copy value bytes into allocated memory
   - Return allocated value
6. **Return None** if key not found

#### In-Memory Databases

1. **Check Database Type**: Verify pager is null (in-memory database)
2. **Snapshot Lookup**:
   - Call `snapshot.get(key)` on SnapshotState
   - Direct hash map lookup in in-memory state
3. **Return Value**:
   - If found, return value reference (no allocation needed)
   - If not found, return None

### Key Comparison

**Lexicographic Byte Ordering**:
- Keys compared as byte sequences
- Standard lexicographic ordering (memcmp semantics)
- Shorter keys sort before longer keys if they are prefix
- Example: "abc" < "abcd" < "abd"

**Binary Safe**:
- Keys may contain any byte values including null bytes
- No UTF-8 validation required
- No termination characters

### Error Conditions

**CorruptBtree**:
- B+tree checksum validation failed
- Page structure invalid
- Pointer corruption detected
- **Behavior**: Returns None (key treated as not found)

**BufferTooSmall**:
- Value size exceeds temporary buffer capacity
- Fixed buffer too small for large values
- **Behavior**: Returns None (caller should retry with larger buffer if needed)

**AllocationFailed**:
- Memory allocation failed for value copy
- Out of memory condition
- **Behavior**: Returns None (no memory for value copy)

### Invariants

**Snapshot Consistency**:
- All reads use same txn_id and root_page_id
- Snapshot never changes during transaction lifetime
- Concurrent writes do not affect reads
- Later commits do not affect reads

**Idempotency**:
- Same key always returns same value within transaction
- Multiple get() calls return identical results
- No side effects from get() operation

**Key Not Found**:
- get() returns None for non-existent keys
- Not an error condition
- Distinguishes between "never existed" and "deleted before snapshot"

## WriteTxn.get() Operation

### Purpose

Retrieve a value by key from a write transaction, implementing read-your-writes semantics by checking pending mutations first.

### Signature

```
WriteTxn.get(key: &[u8]) -> Option<Value>
```

### Parameters

**key**: Byte slice representing the key to look up
- Must be non-empty
- Must not exceed MAX_KEY_SIZE (4096 bytes)
- Compared lexicographically with stored keys

### Return Value

**Some(Value)**: Key exists with pending write or in database
- Value is from pending mutation if key was modified
- Value is from database if no pending mutation
- Value may be empty (zero-length)

**None**: Key does not exist or was deleted
- Key was never inserted
- Key was deleted in this transaction (pending delete)
- Key was deleted before transaction began

### Algorithm

#### Check Pending Mutations

1. **Query Transaction Context**:
   - Call `txn_ctx.getPendingMutation(key)`
   - Searches mutations vector in reverse order (most recent first)
2. **Handle Pending Put**:
   - If Mutation::Put found for key
   - Return the pending value from mutation
   - Skip database lookup (read-your-writes)
3. **Handle Pending Delete**:
   - If Mutation::Delete found for key
   - Return None (key marked for deletion)
   - Skip database lookup (tombstone in pending ops)

#### Database Lookup (No Pending Mutation)

4. **File-Based Databases**:
   - If pager exists, call `pager.getBtreeValue(key, buffer)`
   - Use current database root (not snapshot root)
   - Returns committed value or None
5. **In-Memory Databases**:
   - Check inner.writes hash map for key
   - If found, return value (may be null if deleted)
   - Otherwise, query current snapshot from model
   - Call `model.beginRead(current_txn_id).get(key)`

### Read-Your-Writes Semantics

**Definition**: A transaction always sees its own writes, even before commit.

**Implementation**:
- Pending mutations checked before database lookup
- Most recent mutation for key takes precedence
- Put overrides previous Put or Delete
- Delete overrides previous Put

**Example**:
```
txn.put("a", "v1")
assert(txn.get("a") == Some("v1"))  // Sees own write

txn.put("a", "v2")
assert(txn.get("a") == Some("v2"))  // Sees latest write

txn.delete("a")
assert(txn.get("a") == None)  // Sees own delete
```

### Mutation Buffer Search

**Reverse Order Search**:
- Search mutations vector from end to beginning
- Most recent mutation for key wins
- O(m) where m = number of mutations
- Linear search acceptable for small mutation counts

**Key Matching**:
- Compare key bytes with mutation keys
- First match in reverse order returned
- No early termination (must check all mutations)

### Invariants

**Read-Your-Writes**:
- Transaction sees all its own writes
- Pending changes visible immediately
- Commit not required for visibility within transaction

**Consistency with Commit**:
- get() before commit matches get() after commit
- Pending mutations become visible to other transactions on commit
- Same value visible throughout transaction lifetime

**Delete Visibility**:
- Pending delete returns None
- Delete treated as tombstone in pending ops
- Does not fall through to database lookup

## Value Lifetime and Ownership

### ReadTxn.get() Ownership

**Allocated Values**:
- Value is allocated from transaction's allocator
- Caller owns returned value
- Value valid after transaction closed
- Caller must free value explicitly

**Memory Safety**:
- Value copy independent of transaction state
- Transaction drop does not invalidate value
- No dangling references

### WriteTxn.get() Ownership

**Pending Mutation Values**:
- Returns reference to pending mutation value
- Value owned by TransactionContext
- Valid until transaction commit or rollback
- Caller should copy if needed beyond transaction lifetime

**Database Values**:
- Same semantics as ReadTxn.get()
- Allocated from appropriate allocator
- Caller owns returned value

## B+Tree Traversal Details

### Traversal Algorithm

1. **Start at Root**: Begin at root_page_id (snapshot root for ReadTxn)
2. **Node Type Check**:
   - **Leaf Node**: Search keys array for target key
   - **Internal Node**: Search separators, select child pointer
3. **Binary Search**: Use binary search within node keys/separators
4. **Child Traversal**: For internal nodes, recurse to selected child
5. **Leaf Lookup**: At leaf, check if key exists
6. **Return Value**: If found, return value pointer; otherwise None

### Page Reading

**Buffer Management**:
- Use stack-allocated temporary buffer
- Avoid heap allocation for small values
- Buffer size: 4096 bytes (typical page size)
- Larger values require heap allocation

**Checksum Validation**:
- Each page has checksum for integrity
- Checksum validated before reading
- Corrupt pages return CorruptBtree error

### Error Handling

**CorruptBtree**:
- Checksum failure on page read
- Invalid page structure
- Pointer corruption
- **Action**: Return None, log error

**BufferTooSmall**:
- Value exceeds buffer capacity
- Large value (>4KB) stored
- **Action**: Return None, caller should retry with larger buffer

**PageNotFound**:
- PageId does not exist in pager
- Freed or never allocated
- **Action**: Return None, treat as not found

## In-Memory Lookup Details

### SnapshotState Lookup

**Hash Map Access**:
- Direct hash map lookup by key bytes
- O(1) average case complexity
- No traversal overhead
- Returns value reference or None

**Reference Model**:
- SnapshotState wraps HashMap<Vec<u8>, Vec<u8>>
- Keys and values owned by SnapshotState
- References returned directly without copy

### WriteTxn In-Memory Lookup

**Two-Level Check**:
1. Check writes HashMap (pending mutations)
2. Check model snapshot (committed state)
3. Return first match

**Current Snapshot**:
- Query model at current_txn_id
- Returns most recent committed state
- Snapshot isolation for read-your-writes

## Concurrency Considerations

### ReadTxn Concurrency

**Multiple Readers**:
- Unlimited concurrent ReadTxn instances
- No blocking between readers
- Each reader has independent snapshot
- No locks required for get() operations

**Writer Coordination**:
- Readers not blocked by active writer
- New readers wait for writer to complete commit
- FIFO ordering prevents starvation
- Readers use snapshot root, not current root

### WriteTxn Concurrency

**Single Writer**:
- Only one WriteTxn active at a time
- Writer lock held during transaction
- get() does not block on locks
- Pending mutations local to transaction

**Read-Your-Writes Thread Safety**:
- Mutation buffer local to transaction
- No concurrent access to pending mutations
- Safe to check without synchronization

## Performance Characteristics

### ReadTxn.get() Complexity

**File-Based**:
- B+tree height: O(log n) where n = number of keys
- Page reads: One I/O per level
- Binary search within node: O(log b) where b = branching factor
- Memory allocation: O(v) where v = value size

**In-Memory**:
- Hash map lookup: O(1) average
- Worst case: O(n) with hash collisions
- No I/O overhead
- No allocation (returns reference)

### WriteTxn.get() Complexity

**Pending Mutation Check**:
- Linear search mutations: O(m) where m = mutation count
- m typically small (<1000)
- Reverse search stops at first match
- Early termination on key match

**Database Lookup**:
- Same complexity as ReadTxn.get() if no pending mutation

## Testing Requirements

### Unit Tests

**ReadTxn.get()**:
- get() returns value for existing key
- get() returns None for non-existent key
- get() returns consistent value across multiple calls
- get() uses correct snapshot root (not current root)
- get() handles deleted keys correctly (returns None)
- get() works for both file-based and in-memory databases
- get() handles corruption gracefully (returns None)
- get() handles buffer too small gracefully (returns None)

**WriteTxn.get()**:
- get() sees pending put mutations
- get() sees pending delete mutations (returns None)
- get() returns database value when no pending mutation
- get() implements read-your-writes correctly
- get() handles multiple mutations for same key (latest wins)
- get() handles put then delete (returns None)
- get() handles delete then put (returns new value)
- get() works for both file-based and in-memory databases

### Integration Tests

**Snapshot Isolation**:
- ReadTxn does not see concurrent writer changes
- ReadTxn sees same values throughout lifetime
- Multiple ReadTxn instances have independent snapshots
- Old snapshots remain valid after commits

**Read-Your-Writes**:
- WriteTxn sees own puts before commit
- WriteTxn sees own deletes before commit
- WriteTxn.get() consistent before and after commit
- Multiple mutations for same key handled correctly

**Time Travel**:
- ReadTxn at old txn_id sees historical state
- get() returns correct values for historical snapshot
- Historical reads not affected by later writes

### Property Tests

**Idempotency**:
- Multiple get() calls return same result
- get() does not modify transaction state
- get() does not modify database

**Consistency**:
- ReadTxn.get() results consistent with scan results
- WriteTxn.get() results consistent after commit
- Snapshot state consistent with B+tree state

## Error Handling Best Practices

### Corruption Handling

**Detect Corruption**:
- Validate page checksums
- Check node structure invariants
- Validate pointer ranges

**Graceful Degradation**:
- Return None on corruption (not error)
- Log corruption for debugging
- Do not crash or panic
- Allow operation to continue

### Buffer Management

**Temporary Buffer**:
- Use stack allocation for small values
- Avoid heap allocation when possible
- Fixed size buffer (4KB typical)

**Large Values**:
- Detect when value exceeds buffer
- Return BufferTooSmall error
- Caller should retry with larger buffer
- Alternative: allocate heap buffer directly

## Rust Implementation Guidance

### ReadTxn.get() Implementation

```rust
impl<'a> ReadTxn<'a> {
    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, Error> {
        // Validate key
        if key.is_empty() {
            return Err(Error::KeyEmpty);
        }
        if key.len() > MAX_KEY_SIZE {
            return Err(Error::KeyTooLarge);
        }

        // File-based database: B+tree lookup
        if let Some(pager) = &self.db.pager {
            // Use snapshot's root page ID
            match pager.btree_get_at_root(key, self.root_page_id) {
                Ok(Some(value)) => {
                    // Allocate owned copy of value
                    let value_copy = value.to_vec();
                    return Ok(Some(value_copy));
                }
                Ok(None) => return Ok(None),
                Err(Error::CorruptBtree) => {
                    // Log corruption, treat as not found
                    return Ok(None);
                }
                Err(Error::BufferTooSmall) => {
                    // Value too large for buffer
                    return Ok(None);
                }
                Err(e) => return Err(e),
            }
        }

        // In-memory database: snapshot lookup
        Ok(self.snapshot.get(key).map(|v| v.to_vec()))
    }
}
```

### WriteTxn.get() Implementation

```rust
impl<'a> WriteTxn<'a> {
    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, Error> {
        // Validate key
        if key.is_empty() {
            return Err(Error::KeyEmpty);
        }
        if key.len() > MAX_KEY_SIZE {
            return Err(Error::KeyTooLarge);
        }

        // Check pending mutations first (read-your-writes)
        if let Some(pending) = self.txn_ctx.get_pending_mutation(key) {
            return Ok(match pending {
                PendingMutation::Put { value } => Some(value.clone()),
                PendingMutation::Delete => None,
            });
        }

        // No pending mutation, check database
        // File-based database: B+tree lookup
        if let Some(pager) = &self.db.pager {
            return pager.btree_get(key);
        }

        // In-memory database: check writes then snapshot
        if let Some(value) = self.inner.writes.get(key) {
            return Ok(value.clone());
        }

        let snapshot = self.inner.model.begin_read_latest()?;
        Ok(snapshot.get(key).map(|v| v.to_vec()))
    }
}
```

### TransactionContext.get_pending_mutation()

```rust
impl TransactionContext {
    pub fn get_pending_mutation(&self, key: &[u8]) -> Option<PendingMutation> {
        // Search mutations in reverse order (most recent first)
        for mutation in self.mutations.iter().rev() {
            match mutation {
                Mutation::Put { key: k, value } => {
                    if k == key {
                        return Some(PendingMutation::Put { value: value.clone() });
                    }
                }
                Mutation::Delete { key: k } => {
                    if k == key {
                        return Some(PendingMutation::Delete);
                    }
                }
            }
        }
        None
    }
}

enum PendingMutation {
    Put { value: Vec<u8> },
    Delete,
}
```

### Constants

```rust
pub const MAX_KEY_SIZE: usize = 4096;
pub const MAX_VALUE_SIZE: usize = 16 * 1024 * 1024; // 16MB
pub const DEFAULT_BUFFER_SIZE: usize = 4096; // 4KB
```

## Dependencies

- **Uses**:
  - ReadTxn type (snapshot-based reads)
  - WriteTxn type (read-your-writes)
  - TransactionContext type (pending mutations)
  - SnapshotState type (in-memory snapshot)
  - PageId type (B+tree root identifier)
  - B+tree operations (traversal and lookup)

- **Used By**:
  - Application code (point lookups)
  - Query layer (single key reads)
  - Scan operations (prefix iteration)
  - Transaction semantics validation

## Related Specifications

- **ReadTxn**: rust/04-read-txn.md - Read transaction structure and snapshot management
- **WriteTxn**: rust/04-write-txn.md - Write transaction structure and mutation tracking
- **TransactionContext**: rust/04-txn-context.md - Transaction state and pending mutation handling
- **Transaction Begin**: rust/04-txn-begin.md - Transaction initialization and snapshot assignment
- **Semantics**: spec/semantics_v0.md - MVCC and snapshot isolation requirements
