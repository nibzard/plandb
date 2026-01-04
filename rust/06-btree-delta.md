# B+Tree Delta Layer - Uncommitted Change Tracking

## Purpose

The delta layer provides a mechanism for tracking uncommitted changes made by a write transaction before they are durably persisted to the B+Tree. This isolation ensures that concurrent readers see a consistent snapshot of the database without blocking on ongoing writes, and that failed transactions can be rolled back without corrupting the tree structure. The delta layer acts as a write-ahead buffer that accumulates mutations and applies them atomically to the B+Tree during commit.

## Types

### DeltaLayer

**Description**: In-memory buffer storing all mutations performed by a single write transaction. Maintains changes in a form that can be quickly applied, rolled back, or queried for transaction-local reads (read-your-writes).

**Structure**:
- **mutations** (HashMap<Key, MutationEntry>): Map from key to mutation entry
- **size** (usize): Total bytes occupied by mutations (for size limiting)
- **operation_count** (usize): Number of operations in transaction (for limiting)

**Invariants**:
- Every key appears at most once in mutations map
- operation_count equals mutations.len()
- size equals sum of all mutation entry sizes
- All mutations have transaction-local LSN (not yet persisted)
- Read operations consult delta layer before B+Tree

### MutationEntry

**Description**: Single mutation recorded in delta layer. Represents the intent to insert, update, or delete a key-value pair.

**Variants**:
- **Put**: Insert or update key with new value
- **Delete**: Remove key from tree (tombstone)

**Put Variant Fields**:
- **key** (Vec<u8>): Mutated key
- **value** (Vec<u8>): New value (inline or overflow reference)
- **lsn** (Lsn): Transaction's temporary LSN
- **size** (usize): Total bytes occupied (key + value + overhead)

**Delete Variant Fields**:
- **key** (Vec<u8>): Key to delete
- **lsn** (Lsn): Transaction's temporary LSN
- **size** (usize): Bytes occupied (key + overhead, no value)

**Invariants**:
- Exactly one variant present per entry
- key length <= MAX_KEY_SIZE (255 bytes)
- For Put: value length <= MAX_VALUE_SIZE (16MB)
- lsn is monotonically increasing within transaction
- size accurately reflects storage requirements

### DeltaStats

**Description**: Statistics about delta layer state, useful for monitoring and size management.

**Fields**:
- **mutation_count** (usize): Total number of mutations
- **put_count** (usize): Number of Put mutations
- **delete_count** (usize): Number of Delete mutations
- **total_size** (usize): Total bytes occupied by all mutations
- **largest_mutation** (usize): Size of largest single mutation
- **average_mutation_size** (f64): Mean mutation size

**Invariants**:
- mutation_count equals put_count + delete_count
- total_size equals sum of all mutation entry sizes
- average_mutation_size equals total_size / mutation_count (if mutation_count > 0)

## Delta Layer Operations

### Delta Initialization

**create_delta_layer() -> DeltaLayer**

**Purpose**: Initialize empty delta layer for new write transaction

**Algorithm**:
1. Allocate empty HashMap for mutations
2. Initialize size to 0
3. Initialize operation_count to 0
4. Return DeltaLayer structure

**Returns**: Empty DeltaLayer ready to record mutations

**Error Conditions**: None (initialization always succeeds)

**Complexity**: O(1)

**Use Case**: Called at start of every write transaction

### Record Mutation

**record_put(delta: DeltaLayer, key: &[u8], value: &[u8], lsn: Lsn) -> Result<(), DeltaError>**

**Purpose**: Record a Put mutation in delta layer

**Algorithm**:
1. Validate key length <= MAX_KEY_SIZE
2. Validate value length <= MAX_VALUE_SIZE
3. Calculate mutation_size = key.len() + value.len() + OVERHEAD
4. Check if key already exists in delta.mutations:
   a. If exists and is Put: subtract old mutation size from delta.size
   b. If exists and is Delete: subtract old mutation size from delta.size
   c. Remove old entry
5. Create new MutationEntry::Put with key, value, lsn, size
6. Insert into delta.mutations
7. Add mutation_size to delta.size
8. Increment delta.operation_count
9. Check if delta.operation_count > MAX_OPERATIONS_PER_TXN
   a. If yes, return TooManyOperations error
10. Check if delta.size > MAX_DELTA_SIZE
    a. If yes, return DeltaTooLarge error
11. Return Ok(())

**Returns**: Ok(()) if mutation recorded, Err(DeltaError) if validation fails

**Error Conditions**:
- KeyTooLarge: key exceeds MAX_KEY_SIZE
- ValueTooLarge: value exceeds MAX_VALUE_SIZE
- TooManyOperations: operation count exceeds limit
- DeltaTooLarge: total delta size exceeds limit

**Complexity**: O(1) average (HashMap insert), O(n) worst case (rare hash collision)

**Use Case**: Called during transaction.put() operation

**Note**: Last-write-wins semantics within transaction (duplicate keys overwrite previous mutation)

**record_delete(delta: DeltaLayer, key: &[u8], lsn: Lsn) -> Result<(), DeltaError>**

**Purpose**: Record a Delete mutation in delta layer

**Algorithm**:
1. Validate key length <= MAX_KEY_SIZE
2. Calculate mutation_size = key.len() + OVERHEAD (no value for delete)
3. Check if key already exists in delta.mutations:
   a. If exists: subtract old mutation size from delta.size
   b. Remove old entry
4. Create new MutationEntry::Delete with key, lsn, size
5. Insert into delta.mutations
6. Add mutation_size to delta.size
7. Increment delta.operation_count
8. Check if delta.operation_count > MAX_OPERATIONS_PER_TXN
   a. If yes, return TooManyOperations error
9. Return Ok(())

**Returns**: Ok(()) if mutation recorded, Err(DeltaError) if validation fails

**Error Conditions**:
- KeyTooLarge: key exceeds MAX_KEY_SIZE
- TooManyOperations: operation count exceeds limit

**Complexity**: O(1) average

**Use Case**: Called during transaction.delete() operation

**Note**: Delete takes precedence over prior Put for same key within transaction

### Delta Lookup

**get_from_delta(delta: DeltaLayer, key: &[u8]) -> Option<MutationEntry>**

**Purpose**: Look up key in delta layer (for transaction-local reads)

**Algorithm**:
1. Check if key exists in delta.mutations
2. If exists, return Some(mutation_entry)
3. If not exists, return None

**Returns**: Some(entry) if key has pending mutation, None otherwise

**Complexity**: O(1) average (HashMap lookup)

**Use Case**: Called during transaction.get() to implement read-your-writes

**Integration**:
- Caller first checks delta layer
- If not found in delta, consult B+Tree
- If found in delta as Delete, return KeyNotFound
- If found in delta as Put, return value (without reading B+Tree)

### Delta Statistics

**calculate_delta_stats(delta: DeltaLayer) -> DeltaStats**

**Purpose**: Compute statistics about delta layer state

**Algorithm**:
1. Initialize counters: put_count = 0, delete_count = 0, total_size = delta.size
2. Iterate through delta.mutations:
   a. For each entry, if entry is Put: increment put_count
   b. For each entry, if entry is Delete: increment delete_count
3. Calculate mutation_count = put_count + delete_count
4. Find largest_mutation = max(entry.size for entry in delta.mutations)
5. Calculate average_mutation_size = total_size / mutation_count (if mutation_count > 0, else 0)
6. Return DeltaStats with all calculated fields

**Returns**: DeltaStats structure

**Complexity**: O(n) where n = number of mutations (must scan all)

**Use Case**: Monitoring, size limit enforcement, telemetry

## Delta Application to B+Tree

### Apply Delta

**apply_delta(btree: BTree, delta: DeltaLayer, commit_lsn: Lsn) -> Result<(), Error>**

**Purpose**: Atomically apply all delta mutations to B+Tree during commit

**Algorithm**:
1. Sort delta mutations by key (for deterministic B+Tree traversal)
2. Begin transaction-level atomic operation:
   a. For each mutation in delta.mutations (in key order):
      i. If mutation is Put:
         - Call btree.put(mutation.key, mutation.value, commit_lsn)
         - If put fails, abort entire apply operation
      ii. If mutation is Delete:
         - Call btree.delete(mutation.key, commit_lsn)
         - If delete fails, abort entire apply operation
   b. After all mutations applied successfully:
      i. Update tree metadata (new root_page_id if changed)
      ii. Return Ok(())
3. If any mutation application fails:
   a. Return error to caller
   b. Caller responsible for rollback (B+Tree not modified if error mid-apply)

**Returns**: Ok(()) if all mutations applied, Err(Error) if any mutation fails

**Error Conditions**:
- IOError: B+Tree I/O operation failed
- CorruptionError: B+Tree structure corrupted
- AllocationFailed: Pager cannot allocate new nodes
- NodeFull: Cannot split nodes (space exhausted)

**Complexity**: O(n * log t) where n = mutation count, t = tree size

**Transaction Safety**:
- All mutations applied with same commit_lsn
- Either all mutations apply or none apply (atomicity)
- Failures mid-apply leave B+Tree in consistent state (changes not persisted)

**Optimization**: Sort mutations by key for efficient B+Tree traversal (minimize node reads)

### Rollback Delta

**rollback_delta(delta: DeltaLayer)**

**Purpose**: Discard delta layer without applying to B+Tree

**Algorithm**:
1. Drop delta.mutations HashMap (releases all key and value buffers)
2. Delta layer memory reclaimed by Rust allocator
3. No B+Tree modifications made

**Returns**: None (void)

**Error Conditions**: None (rollback cannot fail)

**Complexity**: O(n) where n = number of mutations (HashMap deallocation)

**Use Case**: Called on transaction rollback or commit failure

**Memory Management**: Rust's Drop trait automatically frees delta layer memory

## Delta and Transaction Integration

### Write Transaction Flow with Delta

**Full Write Transaction Lifecycle**:

1. **Begin Transaction**:
   a. Create empty DeltaLayer
   b. Acquire write lock on B+Tree
   c. Assign transaction ID

2. **Execute Operations** (user code):
   a. For each put(key, value): call record_put(delta, key, value, lsn)
   b. For each delete(key): call record_delete(delta, key, lsn)
   c. For each get(key): call get_from_delta(delta, key), fallback to B+Tree

3. **Prepare Commit**:
   a. Validate all mutations (size, count, key/value limits)
   b. Check for conflicts with other committed transactions
   c. Calculate final commit LSN

4. **Commit**:
   a. Write commit record to WAL (with all mutations serialized)
   b. fsync WAL to disk
   c. Apply delta mutations to B+Tree: apply_delta(btree, delta, commit_lsn)
   d. Write updated tree metadata to file
   e. fsync file metadata
   f. Delta layer no longer needed, dropped

5. **Rollback** (if error or user abort):
   a. Discard delta layer (no B+Tree modifications)
   b. Release write lock
   c. Transaction aborted

**Delta Layer Role**:
- Buffers writes before persistent storage
- Enables read-your-writes within transaction
- Supports rollback without B+Tree modifications
- Batches mutations for efficient commit

### Read-Your-Writes

**Purpose**: Ensure transaction sees its own uncommitted writes

**Algorithm**:
1. User calls transaction.get(key):
   a. Check delta layer: get_from_delta(delta, key)
   b. If found as Put: return value (transaction-local write visible)
   c. If found as Delete: return NotFound (transaction-local delete visible)
   d. If not found: fallback to B+Tree lookup with snapshot LSN

**Guarantee**: Operations within transaction observe previous operations in same transaction

**Example**:
1. transaction.put("key1", "value1")  // Recorded in delta
2. transaction.get("key1")            // Returns "value1" from delta
3. transaction.delete("key1")         // Updates delta to Delete
4. transaction.get("key1")            // Returns NotFound (delta Delete)

**Importance**: Critical for multi-statement transactions and consistency

### Delta Size Limits

**MAX_OPERATIONS_PER_TXN**:
- **Value**: 1000 operations
- **Rationale**: Prevents unbounded transaction size
- **Enforcement**: Check during record_put/record_delete
- **Error**: Return TooManyOperations if exceeded

**MAX_DELTA_SIZE**:
- **Value**: 16MB (16,777,216 bytes)
- **Rationale**: Prevents single transaction from exhausting memory
- **Enforcement**: Check cumulative size during record_put/record_delete
- **Error**: Return DeltaTooLarge if exceeded

**Calculation**:
- Each mutation: key (up to 255) + value (up to 16MB) + overhead (~32 bytes)
- Worst case: 1 mutation with 16MB value
- Typical case: 1000s of small mutations (key + value ~100 bytes each)

## Delta Layer and WAL

### Delta Serialization

**serialize_delta(delta: DeltaLayer) -> Vec<u8>**

**Purpose**: Convert delta layer to byte stream for WAL commit record

**Algorithm**:
1. Allocate buffer for serialized delta
2. Write operation_count (u32) to buffer
3. For each mutation in delta.mutations (in key-sorted order):
   a. Write mutation_type (u8): 1 for Put, 2 for Delete
   b. Write key_length (u8)
   c. Write key_bytes
   d. If mutation is Put:
      i. Write value_length (u32)
      ii. Write value_bytes
   e. If mutation is Delete:
      i. Write value_length = 0 (sentinel)
4. Return complete buffer

**Binary Format**:
```
Offset  Size    Field              Description
------  ----    -----              -----------
0       4       operation_count    Number of mutations
4       1       mutation_type_1    1=Put, 2=Delete
5       1       key_len_1          Key length (0-255)
6       N       key_bytes_1        Key data (N = key_len_1)
6+N     4       value_len_1        Value length (0 for Delete)
10+N    M       value_bytes_1      Value data (M = value_len_1)
...     ...     ...               ... (repeat for each mutation)
--      --      --                 --
Total:  variable
```

**Returns**: Serialized byte array

**Use Case**: Create commit record payload for WAL

**Integration**: Called by transaction.commit() before WAL append

### Delta Deserialization

**deserialize_delta(data: &[u8]) -> Result<DeltaLayer, DeltaError>**

**Purpose**: Reconstruct delta layer from WAL commit record (recovery)

**Algorithm**:
1. Validate data length >= 4 (minimum for operation_count)
2. Read operation_count from first 4 bytes
3. Initialize empty DeltaLayer
4. Initialize cursor = offset 4
5. For i in 0..operation_count:
   a. Read mutation_type (u8)
   b. Read key_len (u8)
   c. Read key_bytes (key_len bytes)
   d. If mutation_type == 1 (Put):
      i. Read value_len (u32)
      ii. Read value_bytes (value_len bytes)
      iii. Create MutationEntry::Put
   e. If mutation_type == 2 (Delete):
      i. Read value_len (u32), must be 0
      ii. Create MutationEntry::Delete
   f. Insert entry into delta.mutations
   g. Advance cursor by entry size
6. Return reconstructed DeltaLayer

**Returns**: DeltaLayer with all mutations

**Error Conditions**:
- TruncatedData: Not enough bytes to read entry
- InvalidMutationType: mutation_type not 1 or 2
- InvalidDeleteValue: Delete has non-zero value_len
- KeyError: Key length exceeds MAX_KEY_SIZE
- ValueError: Value length exceeds MAX_VALUE_SIZE

**Complexity**: O(n) where n = operation_count

**Use Case**: Rebuild delta layer during WAL recovery for replay

**Integration**: Called by recovery system when scanning commit records

## Delta Layer Optimization

### Mutation Batching

**Purpose**: Reduce overhead by applying multiple mutations to same node in one operation

**Algorithm**:
1. Group mutations by target B+Tree node
2. Sort mutations within each node by key
3. For each node:
   a. Read node once from Pager
   b. Apply all mutations targeting that node
   c. Write node once to Pager
4. Benefit: O(1) I/O per node instead of O(mutations) I/O

**Effectiveness**:
- High for random mutations spread across tree (many mutations per node)
- Low for sequential mutations (one mutation per node)
- Typical workload: 2-10x I/O reduction

**Implementation Complexity**: Requires tracking which mutations target which nodes during B+Tree traversal

### Delta Compression

**Purpose**: Reduce memory footprint of delta layer

**Algorithm**:
1. Identify mutations with common key prefixes
2. Store common prefix once
3. For each mutation, store only unique suffix
4. Reconstruct full keys during application

**Benefit**:
- 10-30% space reduction for structured keys (e.g., user_id + timestamp)
- Enables larger transactions within size limits

**Drawback**:
- Added CPU overhead for compression/decompression
- Implementation complexity

### Deferred Large Value Copy

**Purpose**: Avoid copying large values into delta layer if possible

**Algorithm**:
1. For large values (threshold: >1MB):
   a. Store reference to original value location instead of copying
   b. Mark mutation as "deferred copy"
2. During delta application:
   a. Detect deferred copy mutations
   b. Copy value from source location at application time
3. Benefit: Reduced memory usage for large value transactions

**Tradeoff**:
- Pro: Lower memory overhead
- Con: Value must remain valid until commit (lifetime complexity)

## Rust Implementation Guidance

### Module Structure

Define delta layer types in:
- `northstar_core::tree::delta::DeltaLayer` - Delta layer structure
- `northstar_core::tree::delta::MutationEntry` - Mutation entry types
- `northstar_core::tree::delta::DeltaError` - Delta layer errors

### Type Definitions

**DeltaLayer Structure**:
```rust
use std::collections::HashMap;

pub struct DeltaLayer {
    mutations: HashMap<Vec<u8>, MutationEntry>,
    size: usize,
    operation_count: usize,
}

impl DeltaLayer {
    pub fn new() -> Self {
        Self {
            mutations: HashMap::new(),
            size: 0,
            operation_count: 0,
        }
    }
}
```

**MutationEntry Enum**:
```rust
pub enum MutationEntry {
    Put {
        key: Vec<u8>,
        value: Vec<u8>,
        lsn: Lsn,
        size: usize,
    },
    Delete {
        key: Vec<u8>,
        lsn: Lsn,
        size: usize,
    },
}
```

**DeltaError Enum**:
```rust
#[derive(Debug, thiserror::Error)]
pub enum DeltaError {
    #[error("key too large: {len} bytes (max: {max})")]
    KeyTooLarge { len: usize, max: usize },

    #[error("value too large: {len} bytes (max: {max})")]
    ValueTooLarge { len: usize, max: usize },

    #[error("too many operations in transaction: {count} (max: {max})")]
    TooManyOperations { count: usize, max: usize },

    #[error("delta size too large: {size} bytes (max: {max})")]
    DeltaTooLarge { size: usize, max: usize },

    #[error("truncated delta data during deserialization")]
    TruncatedData,

    #[error("invalid mutation type: {0}")]
    InvalidMutationType(u8),
}
```

### Delta Operations Implementation

**Record Put Mutation**:
```rust
impl DeltaLayer {
    pub fn record_put(
        &mut self,
        key: &[u8],
        value: &[u8],
        lsn: Lsn,
    ) -> Result<(), DeltaError> {
        const MAX_KEY_SIZE: usize = 255;
        const MAX_VALUE_SIZE: usize = 16_777_215;
        const MAX_OPERATIONS: usize = 1000;
        const MAX_DELTA_SIZE: usize = 16_777_216;
        const OVERHEAD: usize = 32; // key_len + value_len + lsn + metadata

        // Validate
        if key.len() > MAX_KEY_SIZE {
            return Err(DeltaError::KeyTooLarge {
                len: key.len(),
                max: MAX_KEY_SIZE,
            });
        }
        if value.len() > MAX_VALUE_SIZE {
            return Err(DeltaError::ValueTooLarge {
                len: value.len(),
                max: MAX_VALUE_SIZE,
            });
        }

        // Check limits
        if self.operation_count >= MAX_OPERATIONS {
            return Err(DeltaError::TooManyOperations {
                count: self.operation_count,
                max: MAX_OPERATIONS,
            });
        }

        // Calculate size
        let mutation_size = key.len() + value.len() + OVERHEAD;
        if self.size + mutation_size > MAX_DELTA_SIZE {
            return Err(DeltaError::DeltaTooLarge {
                size: self.size + mutation_size,
                max: MAX_DELTA_SIZE,
            });
        }

        // Remove old entry if exists (last-write-wins)
        if let Some(old_entry) = self.mutations.remove(key.as_ref()) {
            self.size -= old_entry.size();
        }

        // Insert new entry
        let entry = MutationEntry::Put {
            key: key.to_vec(),
            value: value.to_vec(),
            lsn,
            size: mutation_size,
        };
        self.mutations.insert(key.to_vec(), entry);
        self.size += mutation_size;
        self.operation_count += 1;

        Ok(())
    }
}

impl MutationEntry {
    pub fn size(&self) -> usize {
        match self {
            MutationEntry::Put { size, .. } => *size,
            MutationEntry::Delete { size, .. } => *size,
        }
    }
}
```

**Delta Lookup**:
```rust
impl DeltaLayer {
    pub fn get(&self, key: &[u8]) -> Option<&MutationEntry> {
        self.mutations.get(key)
    }

    pub fn contains(&self, key: &[u8]) -> bool {
        self.mutations.contains_key(key)
    }
}
```

**Delta Application**:
```rust
pub fn apply_delta(
    btree: &mut BTree,
    delta: DeltaLayer,
    commit_lsn: Lsn,
) -> Result<(), TreeError> {
    // Sort mutations by key for efficient traversal
    let mut sorted_mutations: Vec<_> = delta.mutations.into_iter().collect();
    sorted_mutations.sort_by(|a, b| a.0.cmp(b.0));

    // Apply each mutation
    for (key, entry) in sorted_mutations {
        match entry {
            MutationEntry::Put { value, .. } => {
                btree.put(&key, &value, commit_lsn)?;
            }
            MutationEntry::Delete { .. } => {
                btree.delete(&key, commit_lsn)?;
            }
        }
    }

    Ok(())
}
```

### Delta Serialization

**Serialize Delta for WAL**:
```rust
impl DeltaLayer {
    pub fn serialize(&self) -> Vec<u8> {
        let mut buffer = Vec::new();

        // Write operation count
        buffer.extend_from_slice(&(self.mutations.len() as u32).to_le_bytes());

        // Sort mutations by key for deterministic serialization
        let mut sorted: Vec<_> = self.mutations.iter().collect();
        sorted.sort_by(|a, b| a.0.cmp(b.0));

        // Write each mutation
        for (key, entry) in sorted {
            match entry {
                MutationEntry::Put { value, .. } => {
                    buffer.push(1u8); // Put type
                    buffer.push(key.len() as u8);
                    buffer.extend_from_slice(key);
                    buffer.extend_from_slice(&(value.len() as u32).to_le_bytes());
                    buffer.extend_from_slice(value);
                }
                MutationEntry::Delete { .. } => {
                    buffer.push(2u8); // Delete type
                    buffer.push(key.len() as u8);
                    buffer.extend_from_slice(key);
                    buffer.extend_from_slice(&0u32.to_le_bytes()); // value_len = 0
                }
            }
        }

        buffer
    }
}
```

**Deserialize Delta from WAL**:
```rust
impl DeltaLayer {
    pub fn deserialize(data: &[u8]) -> Result<Self, DeltaError> {
        use std::io::{Cursor, Read};

        let mut cursor = Cursor::new(data);
        let mut delta = DeltaLayer::new();

        // Read operation count
        let mut op_count_bytes = [0u8; 4];
        cursor.read_exact(&mut op_count_bytes)
            .map_err(|_| DeltaError::TruncatedData)?;
        let op_count = u32::from_le_bytes(op_count_bytes) as usize;

        // Read each mutation
        for _ in 0..op_count {
            // Mutation type
            let mut type_byte = [0u8; 1];
            cursor.read_exact(&mut type_byte)
                .map_err(|_| DeltaError::TruncatedData)?;
            let mutation_type = type_byte[0];

            // Key length and bytes
            let mut key_len_byte = [0u8; 1];
            cursor.read_exact(&mut key_len_byte)
                .map_err(|_| DeltaError::TruncatedData)?;
            let key_len = key_len_byte[0] as usize;

            let mut key_bytes = vec![0u8; key_len];
            cursor.read_exact(&mut key_bytes)
                .map_err(|_| DeltaError::TruncatedData)?;

            // Value length
            let mut value_len_bytes = [0u8; 4];
            cursor.read_exact(&mut value_len_bytes)
                .map_err(|_| DeltaError::TruncatedData)?;
            let value_len = u32::from_le_bytes(value_len_bytes) as usize;

            match mutation_type {
                1 => {
                    // Put: read value bytes
                    let mut value_bytes = vec![0u8; value_len];
                    cursor.read_exact(&mut value_bytes)
                        .map_err(|_| DeltaError::TruncatedData)?;

                    let entry = MutationEntry::Put {
                        key: key_bytes,
                        value: value_bytes,
                        lsn: Lsn::from(0), // Set during recovery
                        size: 0, // Recalculate if needed
                    };
                    delta.mutations.insert(entry.key().clone(), entry);
                }
                2 => {
                    // Delete: value_len must be 0
                    if value_len != 0 {
                        return Err(DeltaError::InvalidDeleteValue);
                    }

                    let entry = MutationEntry::Delete {
                        key: key_bytes,
                        lsn: Lsn::from(0), // Set during recovery
                        size: 0,
                    };
                    delta.mutations.insert(entry.key().clone(), entry);
                }
                _ => {
                    return Err(DeltaError::InvalidMutationType(mutation_type));
                }
            }

            delta.operation_count += 1;
        }

        Ok(delta)
    }
}
```

### Testing Strategy

**Unit tests needed for**:
- Delta layer initialization
- Record Put mutation (valid and invalid)
- Record Delete mutation (valid and invalid)
- Delta lookup (key found, not found)
- Delta size limit enforcement
- Operation count limit enforcement
- Last-write-wins semantics (duplicate keys)

**Property tests for**:
- Serialization round-trip: deserialize(serialize(delta)) == delta
- Size calculation accurate
- Operation count accurate
- Invariants preserved after all operations

**Integration scenarios**:
- Transaction with multiple puts and deletes
- Read-your-writes correctness
- Delta application to B+Tree
- Rollback discards delta without B+Tree changes
- WAL commit record creation with serialized delta

**Stress tests**:
- Maximum operations (1000)
- Maximum delta size (16MB)
- Large value mutations (16MB)
- Many small mutations (1000s of bytes each)

## Invariants

### Delta Layer Invariants
1. operation_count equals mutations.len()
2. size equals sum of all mutation entry sizes
3. No duplicate keys in mutations map (last-write-wins)
4. All mutations have transaction-local LSN (not yet committed)
5. operation_count <= MAX_OPERATIONS_PER_TXN
6. size <= MAX_DELTA_SIZE

### Mutation Entry Invariants
1. Put entry has non-empty key and non-empty value
2. Delete entry has non-empty key and no value
3. Key length <= MAX_KEY_SIZE for all entries
4. For Put entries, value length <= MAX_VALUE_SIZE
5. entry.size accurately reflects storage requirements

### Delta Application Invariants
1. All mutations applied with same commit_lsn
2. Mutations applied in key-sorted order
3. Either all mutations apply or none apply (atomicity)
4. Failed application leaves B+Tree unchanged

## Dependencies

**Uses**:
- Error types module (for DeltaError)
- Key and value types (for key and value validation)
- Lsn type (for mutation LSN tagging)
- HashMap from standard library (for mutation storage)
- B+Tree module (for delta application)

**Used By**:
- Write transactions (mutation tracking)
- Transaction commit (delta application and serialization)
- Transaction rollback (delta discard)
- WAL recovery (delta deserialization and replay)
- Transaction get operations (read-your-writes)

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design
- **06-btree-insert.md**: Insert operations that apply delta mutations
- **06-btree-delete.md**: Delete operations that apply delta mutations
- **04-txn-*.md**: Transaction system integration with delta layer
- **03-wal-*.md**: WAL integration for delta persistence
- **04-txn-commit.md**: Commit process applying delta to B+Tree
- **04-txn-rollback.md**: Rollback discarding delta
