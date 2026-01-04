# B+Tree Test Specification

## Purpose

This specification defines comprehensive test coverage for the B+Tree implementation. Tests ensure correctness, performance, and robustness of all B+Tree operations. The test suite includes unit tests for individual components, integration tests for complete workflows, property-based tests for invariant validation, and stress tests for edge cases and failure scenarios.

## Test Categories

### Unit Tests

**Purpose**: Test individual functions and data structures in isolation

**Scope**:
- Node structure validation
- Key encoding and comparison
- Value encoding (inline and overflow)
- Binary search operations
- Node split and merge algorithms
- Delta layer operations

**Execution**: Fast, milliseconds per test, run frequently during development

### Integration Tests

**Purpose**: Test complete B+Tree operations end-to-end

**Scope**:
- Insert, update, delete operations
- Point lookups and range scans
- Multi-level tree operations
- Transaction integration
- WAL integration
- Recovery workflows

**Execution**: Moderate speed, seconds per test, run on every commit

### Property-Based Tests

**Purpose**: Validate invariants hold for random inputs using generative testing

**Scope**:
- B+Tree structural invariants
- Ordering guarantees
- Idempotency properties
- Round-trip encoding/decoding
- Recovery determinism

**Execution**: Slower, minutes per test, run nightly or before releases

### Hardening Tests

**Purpose**: Ensure robustness under adversarial conditions and corruption

**Scope**:
- Crash simulation
- Data corruption handling
- Invalid input rejection
- Resource exhaustion
- Concurrent operations

**Execution**: Variable speed, run nightly or in CI

### Performance Tests

**Purpose**: Verify operation latency and throughput meet requirements

**Scope**:
- Point lookup latency
- Insert throughput
- Delete throughput
- Range scan throughput
- Tree build performance
- Recovery performance

**Execution**: Slower, minutes per test, run before releases

## Unit Test Specifications

### Node Structure Tests

**test_node_header_validation()**
- **Purpose**: Verify NodeHeader validation logic
- **Test Cases**:
  - Valid header with correct magic passes
  - Invalid magic number fails
  - Invalid node_type fails
  - Checksum mismatch fails
  - Reserved field non-zero fails
- **Expected**: Validation accepts valid headers, rejects invalid

**test_internal_node_capacity()**
- **Purpose**: Verify internal node capacity calculations
- **Test Cases**:
  - Empty node (0 separators)
  - Half-full node
  - Full node (max separators)
  - Overfull node (trigger split)
- **Expected**: Capacity calculations accurate

**test_leaf_node_capacity()**
- **Purpose**: Verify leaf node capacity calculations
- **Test Cases**:
  - Empty node (0 entries)
  - Half-full node
  - Full node (max entries)
  - Overfull node (trigger split)
- **Expected**: Capacity calculations accurate

**test_node_checksum()**
- **Purpose**: Verify checksum calculation and verification
- **Test Cases**:
  - Checksum of empty node
  - Checksum of full node
  - Checksum changes after modification
  - Checksum verification detects single-bit flip
- **Expected**: Checksums detect all single-bit errors

### Key Encoding Tests

**test_key_encoding_round_trip()**
- **Purpose**: Verify key encoding/decoding preserves data
- **Test Cases**:
  - Empty key
  - Small key (1-10 bytes)
  - Medium key (100 bytes)
  - Large key (255 bytes)
  - Keys with null bytes
  - Keys with all byte values (0x00-0xFF)
- **Expected**: decode(encode(key)) == key for all cases

**test_key_comparison()**
- **Purpose**: Verify key comparison ordering
- **Test Cases**:
  - Equal keys compare equal
  - Different keys compare lexicographically
  - Prefix key < longer key (e.g., "abc" < "abcd")
  - Byte value comparison (0x00 < 0xFF)
  - Reverse comparison correctness
- **Expected**: Comparisons match memcmp semantics

**test_key_validation()**
- **Purpose**: Verify key size limits enforced
- **Test Cases**:
  - Valid key (255 bytes) accepted
  - Invalid key (256 bytes) rejected
  - Empty key (0 bytes) accepted
- **Expected**: Validation accepts valid keys, rejects oversized

### Value Encoding Tests

**test_inline_value_encoding()**
- **Purpose**: Verify inline value encoding/decoding
- **Test Cases**:
  - Empty value
  - Small value (10 bytes)
  - Medium value (1000 bytes)
  - Large inline value (2000 bytes)
- **Expected**: decode(encode(value)) == value

**test_overflow_value_encoding()**
- **Purpose**: Verify overflow value reference encoding
- **Test Cases**:
  - Encode overflow marker (0xFFFF) + page ID
  - Decode returns correct page ID
  - Inline values never encode as overflow
- **Expected**: Overflow markers correctly distinguishable

**test_value_size_limits()**
- **Purpose**: Verify value size validation
- **Test Cases**:
  - Valid inline value (2000 bytes) accepted
  - Valid overflow value (16MB) accepted
  - Invalid value (16MB + 1) rejected
- **Expected**: Size limits correctly enforced

### Binary Search Tests

**test_binary_search_internal_node()**
- **Purpose**: Verify binary search on internal node separators
- **Test Cases**:
  - Key found in separators
  - Key between separators (return left child)
  - Key < all separators (return first child)
  - Key > all separators (return last child)
  - Empty node (no separators)
- **Expected**: Correct child index returned for all cases

**test_binary_search_leaf_node()**
- **Purpose**: Verify binary search on leaf node entries
- **Test Cases**:
  - Exact key match found
  - Key not found (between entries)
  - Key not found (less than all)
  - Key not found (greater than all)
  - Empty node
  - Duplicate keys (multiple versions)
- **Expected**: Correct entry index or None returned

### Node Split Tests

**test_leaf_node_split()**
- **Purpose**: Verify leaf node split algorithm
- **Test Cases**:
  - Split at half point
  - Verify both nodes have valid entries
  - Verify linked list pointers updated
  - Verify separator key promoted
  - Verify checksums updated
- **Expected**: Split produces two valid nodes

**test_internal_node_split()**
- **Purpose**: Verify internal node split algorithm
- **Test Cases**:
  - Split at half point
  - Verify child pointers redistributed
  - Verify separator promoted
  - Verify parent pointers updated
  - Verify checksums updated
- **Expected**: Split produces two valid internal nodes

**test_root_split()**
- **Purpose**: Verify root split grows tree
- **Test Cases**:
  - Split leaf root
  - Split internal root
  - Verify tree height increases by 1
  - Verify new root created
  - Verify old root linked to new root
- **Expected**: Root split increases height correctly

### Node Merge Tests

**test_leaf_node_merge()**
- **Purpose**: Verify leaf node merge algorithm
- **Test Cases**:
  - Merge right into left
  - Merge left into right
  - Verify entries combined
  - Verify linked list pointers updated
  - Verify freed node deallocated
- **Expected**: Merge produces single valid node

**test_internal_node_merge()**
- **Purpose**: Verify internal node merge algorithm
- **Test Cases**:
  - Merge siblings with parent separator
  - Verify child pointers combined
  - Verify separator removed from parent
  - Verify parent pointers updated
- **Expected**: Merge produces single valid internal node

**test_root_merge()**
- **Purpose**: Verify root merge shrinks tree
- **Test Cases**:
  - Merge root with single child
  - Verify tree height decreases by 1
  - Verify child promoted to root
  - Verify old root freed
- **Expected**: Root merge decreases height correctly

### Delta Layer Tests

**test_delta_record_put()**
- **Purpose**: Verify delta layer Put mutation tracking
- **Test Cases**:
  - Record single Put mutation
  - Record multiple Put mutations
  - Duplicate key overwrites previous (last-write-wins)
  - Size limit enforced
  - Operation count limit enforced
- **Expected**: Mutations tracked correctly, limits enforced

**test_delta_record_delete()**
- **Purpose**: Verify delta layer Delete mutation tracking
- **Test Cases**:
  - Record single Delete mutation
  - Delete after Put (replace entry)
  - Delete after Delete (replace entry)
- **Expected**: Delete mutations tracked correctly

**test_delta_serialization()**
- **Purpose**: Verify delta layer serialization
- **Test Cases**:
  - Serialize empty delta
  - Serialize delta with Puts
  - Serialize delta with Deletes
  - Serialize delta with both
  - Deserialize produces identical delta
- **Expected**: Round-trip serialization preserves delta

## Integration Test Specifications

### Basic Operations Tests

**test_insert_and_retrieve()**
- **Purpose**: Verify basic insert and get operations
- **Test Cases**:
  - Insert single key, retrieve same key
  - Insert multiple keys, retrieve each
  - Insert keys in random order, verify sorted
  - Retrieve non-existent key returns NotFound
- **Expected**: All inserted keys retrievable, ordering correct

**test_update_existing_key()**
- **Purpose**: Verify key update creates new version
- **Test Cases**:
  - Insert key with value1
  - Update key with value2
  - Retrieve key, get value2 (latest)
  - Old version still accessible with older LSN
- **Expected**: Updates create new versions, latest returned by default

**test_delete_key()**
- **Purpose**: Verify delete operation
- **Test Cases**:
  - Insert key, delete key, retrieve returns NotFound
  - Delete non-existent key returns error
  - Delete creates tombstone visible to same transaction
  - Old versions still accessible with older LSN
- **Expected**: Deletes create tombstones, key not found after delete

**test_range_scan()**
- **Purpose**: Verify range scan functionality
- **Test Cases**:
  - Scan empty range (no results)
  - Scan full range (all keys)
  - Scan partial range (subset of keys)
  - Scan with non-existent start key
  - Scan with non-existent end key
  - Verify results in sorted order
  - Verify reverse scan returns reverse order
- **Expected**: Range scans return correct keys in order

### Tree Growth Tests

**test_tree_growth_via_inserts()**
- **Purpose**: Verify tree grows correctly as keys inserted
- **Test Cases**:
  - Insert 100 keys, verify height 1
  - Insert 10,000 keys, verify height 2-3
  - Insert 1,000,000 keys, verify height 3-4
  - Verify all keys retrievable after growth
  - Verify tree invariants hold after growth
- **Expected**: Tree height increases appropriately, invariants maintained

**test_leaf_split_cascade()**
- **Purpose**: Verify leaf splits cascade up tree
- **Test Cases**:
  - Insert keys until leaf split
  - Continue inserting until parent split
  - Continue inserting until root split
  - Verify tree height increased
  - Verify all keys retrievable
- **Expected**: Splits propagate correctly, tree remains valid

### Tree Shrink Tests

**test_tree_shrink_via_deletes()**
- **Purpose**: Verify tree shrinks correctly as keys deleted
- **Test Cases**:
  - Build tree with height 3
  - Delete keys until root merge
  - Verify height decreased to 2
  - Delete more keys until another root merge
  - Verify height decreased to 1
  - Verify remaining keys retrievable
- **Expected**: Tree height decreases appropriately, invariants maintained

**test_empty_tree()**
- **Purpose**: Verify deleting all keys returns to empty tree
- **Test Cases**:
  - Build tree with many keys
  - Delete all keys
  - Verify tree has single empty leaf node
  - Verify height 0
- **Expected**: Empty tree has single empty root leaf

### Transaction Integration Tests

**test_transaction_commit()**
- **Purpose**: Verify committed transaction persists
- **Test Cases**:
  - Begin transaction, insert keys, commit
  - Close and reopen database
  - Verify all keys present
  - Verify WAL contains commit record
- **Expected**: Committed changes persist across restart

**test_transaction_rollback()**
- **Purpose**: Verify rolled back transaction discards changes
- **Test Cases**:
  - Begin transaction, insert keys
  - Rollback transaction
  - Verify keys not present in tree
  - Verify WAL does not contain commit record
- **Expected**: Rolled back changes discarded

**test_read_your_writes()**
- **Purpose**: Verify transaction sees its own uncommitted writes
- **Test Cases**:
  - Begin transaction
  - Insert key1
  - Get key1 within same transaction → returns value
  - Delete key1
  - Get key1 within same transaction → NotFound
  - Commit transaction
- **Expected**: Operations within transaction observe previous operations

### Recovery Tests

**test_recovery_from_checkpoint()**
- **Purpose**: Verify recovery from checkpoint
- **Test Cases**:
  - Create database, insert keys, create checkpoint
  - Insert more keys, do NOT checkpoint
  - Simulate crash (close without checkpoint)
  - Reopen database (triggers recovery)
  - Verify all keys present (checkpoint + post-checkpoint)
- **Expected**: Recovery restores all committed data

**test_recovery_from_wal()**
- **Purpose**: Verify recovery replays WAL correctly
- **Test Cases**:
  - Create database, insert keys (txn1)
  - Insert more keys (txn2), commit
  - Begin txn3 but do not commit
  - Simulate crash
  - Reopen database
  - Verify txn1 and txn2 keys present
  - Verify txn3 keys not present (uncommitted)
- **Expected**: Recovery replays committed transactions only

**test_recovery_after_corruption()**
- **Purpose**: Verify recovery handles corrupted WAL
- **Test Cases**:
  - Create database with WAL
  - Corrupt WAL file (flip random bits)
  - Attempt recovery
  - Verify recovery either succeeds (resync) or fails gracefully
- **Expected**: Corruption detected and handled

## Property-Based Test Specifications

### Invariant Tests

**test_tree_invariants_property()**
- **Purpose**: Verify all B+Tree invariants hold for arbitrary operations
- **Property**: For any sequence of inserts and deletes, tree invariants hold
- **Test Generation**:
  - Generate random sequence of 1000 operations (insert/delete)
  - Generate random keys (uniform distribution)
  - Generate random values (uniform size)
  - Apply operations to tree
  - After each operation, verify invariants:
    - All leaf nodes at same depth
    - Keys sorted within nodes
    - Keys sorted across levels
    - Parent pointers consistent
    - Sibling pointers consistent
    - All nodes between min and max occupancy
- **Expected**: All invariants always hold

**test_search_correctness_property()**
- **Purpose**: Verify search finds key iff key exists
- **Property**: For any set of inserted keys, search returns value for existing keys, NotFound for others
- **Test Generation**:
  - Generate random set of 100 keys
  - Insert all keys into tree
  - For each inserted key: search returns value
  - For 100 random non-inserted keys: search returns NotFound
- **Expected**: Search correctness 100%

**test_ordering_property()**
- **Purpose**: Verify range scan returns keys in sorted order
- **Property**: For any tree, range scan returns keys in ascending order
- **Test Generation**:
  - Generate random set of 1000 keys
  - Insert keys in random order
  - Perform full range scan (min to max)
  - Verify results sorted ascending
- **Expected**: Scan results always sorted

### Idempotency Tests

**test_insert_idempotency_property()**
- **Purpose**: Verify inserting same key twice creates two versions
- **Property**: Inserting key K with value V1, then K with value V2, both versions accessible
- **Test Generation**:
  - Generate random key
  - Insert key with value1
  - Insert key with value2 (same key)
  - Retrieve with snapshot LSN >= second insert → returns value2
  - Retrieve with snapshot LSN between inserts → returns value1
- **Expected**: Both versions accessible with appropriate LSN

**test_delete_idempotency_property()**
- **Purpose**: Verify deleting same key twice is idempotent
- **Property**: Delete key K, then delete K again, second delete no-ops
- **Test Generation**:
  - Generate random key
  - Insert key
  - Delete key (creates tombstone)
  - Delete key again (should be idempotent)
  - Verify tree state identical after both deletes
- **Expected**: Second delete has no effect

### Round-Trip Tests

**test_key_encoding_round_trip_property()**
- **Purpose**: Verify key encoding preserves all keys
- **Property**: For any random key, decode(encode(key)) == key
- **Test Generation**:
  - Generate 1000 random keys (random length 0-255, random bytes)
  - For each key: encode, decode, compare with original
- **Expected**: 100% round-trip success

**test_value_encoding_round_trip_property()**
- **Purpose**: Verify value encoding preserves all values
- **Property**: For any random value, decode(encode(value)) == value
- **Test Generation**:
  - Generate 1000 random values (random length 0-16MB, random bytes)
  - For each value: encode, decode, compare with original
- **Expected**: 100% round-trip success

### Recovery Determinism Tests

**test_recovery_determinism_property()**
- **Purpose**: Verify replaying same WAL produces identical tree
- **Property**: For any WAL file, recovering twice produces identical B+Tree
- **Test Generation**:
  - Generate random sequence of 100 transactions
  - Apply transactions to create WAL
  - Recover from WAL (build tree1)
  - Recover from WAL again (build tree2)
  - Compare tree1 and tree2 (same structure, same data)
- **Expected**: Identical trees from same WAL

## Hardening Test Specifications

### Crash Simulation Tests

**test_crash_during_insert()**
- **Purpose**: Verify database consistent after crash during insert
- **Test Cases**:
  - Insert 1000 keys
  - Simulate crash (kill process) at random point
  - Reopen database
  - Verify tree valid (no corruption)
  - Verify keys before crash present
  - Verify keys after crash either present or absent (transactional)
- **Expected**: No corruption, committed data present

**test_crash_during_split()**
- **Purpose**: Verify database consistent after crash during node split
- **Test Cases**:
  - Insert keys until leaf split imminent
  - Simulate crash during split operation
  - Reopen database
  - Verify either split completed or not started (atomic)
  - Verify tree valid
- **Expected**: No partial splits, tree consistent

**test_crash_during_commit()**
- **Purpose**: Verify commit atomicity across crash
- **Test Cases**:
  - Begin transaction, insert 100 keys
  - Simulate crash during commit (after WAL write, before tree update)
  - Reopen database (recovery runs)
  - Verify recovery replays transaction
  - Verify all 100 keys present
- **Expected**: Committed transactions recovered

**test_crash_before_commit()**
- **Purpose**: Verify uncommitted transaction discarded
- **Test Cases**:
  - Begin transaction, insert 100 keys
  - Simulate crash before commit
  - Reopen database
  - Verify none of the 100 keys present
- **Expected**: Uncommitted data discarded

### Corruption Handling Tests

**test_corrupted_node_checksum()**
- **Purpose**: Verify checksum corruption detected
- **Test Cases**:
  - Create tree with 100 keys
  - Corrupt random node (flip bits in data)
  - Attempt to read corrupted node
  - Verify ChecksumError returned
  - Verify corruption not silently ignored
- **Expected**: All checksum corruptions detected

**test_corrupted_magic_number()**
- **Purpose**: Verify magic number corruption detected
- **Test Cases**:
  - Create tree
  - Corrupt node magic number
  - Attempt to read node
  - Verify InvalidMagic error returned
- **Expected**: Magic corruptions detected

**test_torn_write_detection()**
- **Purpose**: Verify detection of incomplete page writes
- **Test Cases**:
  - Insert keys
  - Simulate torn write (write only first half of page)
  - Attempt to read torn page
  - Verify checksum mismatch detected
- **Expected**: Torn writes detected via checksum

### Invalid Input Tests

**test_oversized_key()**
- **Purpose**: Verify oversized key rejected
- **Test Cases**:
  - Attempt to insert key with 256 bytes
  - Verify KeyTooLarge error
  - Verify tree unchanged
- **Expected**: Oversized keys rejected

**test_oversized_value()**
- **Purpose**: Verify oversized value rejected
- **Test Cases**:
  - Attempt to insert value with 16MB + 1 bytes
  - Verify ValueTooLarge error
  - Verify tree unchanged
- **Expected**: Oversized values rejected

**test_invalid_snapshot_lsn()**
- **Purpose**: Verify invalid LSN rejected
- **Test Cases**:
  - Attempt read with LSN from future
  - Attempt read with LSN = 0
  - Verify appropriate error or behavior
- **Expected**: Invalid LSNs handled

### Resource Exhaustion Tests

**test_out_of_memory()**
- **Purpose**: Verify graceful handling of OOM
- **Test Cases**:
  - Insert millions of keys until memory exhausted
  - Verify allocation failure error returned
  - Verify database not corrupted
- **Expected**: OOM results in error, not corruption

**test_disk_full()**
- **Purpose**: Verify graceful handling of disk full
- **Test Cases**:
  - Fill disk until allocation fails
  - Attempt insert
  - Verify AllocationFailed error
  - Verify WAL integrity maintained
- **Expected**: Disk full results in error, WAL valid

## Performance Test Specifications

### Latency Benchmarks

**benchmark_point_lookup()**
- **Purpose**: Measure point lookup latency
- **Workload**:
  - Tree with 1M keys (8-byte keys, 8-byte values)
  - 10,000 random lookups
  - Measure median, p95, p99 latency
- **Targets** (16KB pages, height 3):
  - Median: < 10 microseconds
  - p95: < 20 microseconds
  - p99: < 50 microseconds

**benchmark_insert()**
- **Purpose**: Measure insert latency
- **Workload**:
  - Insert 10,000 keys into empty tree
  - Random keys, 8-byte keys, 8-byte values
  - Measure per-insert latency
- **Targets**:
  - Median: < 50 microseconds
  - p95: < 100 microseconds
  - p99: < 500 microseconds (includes splits)

**benchmark_delete()**
- **Purpose**: Measure delete latency
- **Workload**:
  - Tree with 10,000 keys
  - Delete 1,000 random keys
  - Measure per-delete latency
- **Targets**:
  - Median: < 50 microseconds
  - p95: < 100 microseconds
  - p99: < 500 microseconds (includes merges)

**benchmark_range_scan()**
- **Purpose**: Measure range scan throughput
- **Workload**:
  - Tree with 1M keys
  - Scan range of 10,000 keys
  - Measure keys returned per second
- **Targets**:
  - Throughput: > 1M keys/second
  - Latency per key: < 1 microsecond

### Throughput Benchmarks

**benchmark_random_write_throughput()**
- **Purpose**: Measure sustained insert throughput
- **Workload**:
  - Insert 1M random keys (8-byte)
  - 8-byte values
  - Measure keys inserted per second
- **Targets**:
  - Throughput: > 100K keys/second
  - Sustained over 1M inserts

**benchmark_sequential_write_throughput()**
- **Purpose**: Measure sequential insert throughput
- **Workload**:
  - Insert 1M sequential keys
  - Measure keys inserted per second
- **Targets**:
  - Throughput: > 200K keys/second (better locality)

**benchmark_mixed_workload()**
- **Purpose**: Measure throughput under realistic workload
- **Workload**:
  - 70% inserts (new keys)
  - 20% updates (existing keys)
  - 10% deletes
  - 1M total operations
  - Measure operations per second
- **Targets**:
  - Throughput: > 50K operations/second

### Tree Build Performance

**benchmark_bulk_load()**
- **Purpose**: Measure time to build tree from sorted input
- **Workload**:
  - Load 1M sorted keys into tree
  - Measure total time
- **Targets**:
  - Time: < 10 seconds for 1M keys

**benchmark_random_load()**
- **Purpose**: Measure time to build tree from random input
- **Workload**:
  - Load 1M random keys into tree
  - Measure total time
- **Targets**:
  - Time: < 30 seconds for 1M keys (includes splits)

### Recovery Performance

**benchmark_recovery_from_wal()**
- **Purpose**: Measure recovery time from WAL
- **Workload**:
  - Database with 1M keys
  - WAL with 10K committed transactions
  - Crash and reopen (triggers recovery)
  - Measure recovery time
- **Targets**:
  - Recovery time: < 5 seconds
  - Recovery rate: > 2K transactions/second

**benchmark_checkpoint_recovery()**
- **Purpose**: Measure checkpoint-based recovery time
- **Workload**:
  - Database with checkpoint + 1000 post-checkpoint transactions
  - Crash and reopen
  - Measure recovery time
- **Targets**:
  - Recovery time: < 1 second (much faster than full WAL replay)

## Invariant Checking Functions

### verify_tree_invariants(btree: BTree) -> Result<(), InvariantError>

**Purpose**: Comprehensive tree invariant verification

**Algorithm**:
1. **Verify Root Valid**:
   a. root_page_id != 0
   b. Root node exists and is valid
2. **Verify Balance**: All leaves at same depth
3. **Verify Ordering**:
   a. Keys sorted within each node
   b. Keys sorted across levels (separators correct)
4. **Verify Pointers**:
   a. Parent pointers consistent
   b. Sibling pointers consistent (leaf linked list)
   c. Child pointers valid (all nodes reachable)
5. **Verify Occupancy**:
   a. All nodes (except root) at minimum occupancy
   b. All nodes at maximum capacity
6. **Verify Checksums**: All node checksums valid
7. **Verify Counts**: node count, entry count accurate

**Returns**: Ok(()) if all invariants hold, Err(InvariantError) with details

### verify_node_invariants(node: Node) -> Result<(), NodeError>

**Purpose**: Verify single node invariants

**Algorithm**:
1. **Verify Header**: magic, node_type, checksum valid
2. **Verify Ordering**: Keys in strictly increasing order
3. **Verify Capacity**: num_keys within valid range
4. **Verify Pointers**: child/next/prev pointers valid
5. **Verify Space**: free_space calculation accurate

**Returns**: Ok(()) if node valid, Err(NodeError) with details

## Rust Implementation Guidance

### Test Organization

**Directory Structure**:
```
src/tree/tests/
├── mod.rs                 # Test module entry point
├── node_tests.rs          # Node structure tests
├── key_tests.rs           # Key encoding tests
├── value_tests.rs         # Value encoding tests
├── search_tests.rs        # Search operation tests
├── insert_tests.rs        # Insert operation tests
├── delete_tests.rs        # Delete operation tests
├── scan_tests.rs          # Range scan tests
├── delta_tests.rs         # Delta layer tests
├── recovery_tests.rs      # Recovery tests
└── property_tests.rs      # Property-based tests
```

**Test Harness**: Use Rust's built-in test framework:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_node_header_validation() {
        // Test implementation
    }
}
```

### Property-Based Testing

**Recommended Crate**: `proptest` for Rust

**Example Property Test**:
```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn test_key_round_trip(key in any::<Vec<u8>>) {
        // Limit key size to 255 bytes
        let key: Vec<u8> = key.into_iter().take(255).collect();
        let encoded = encode_key(&key);
        let decoded = decode_key(&encoded).unwrap();
        prop_assert_eq!(key, decoded);
    }
}
```

### Hardening Test Infrastructure

**Crash Simulation**:
```rust
#[test]
fn test_crash_during_insert() {
    // Create database
    let db = create_test_database();

    // Insert keys
    insert_keys(&db, 1000);

    // Simulate crash (don't close, just drop)
    drop(db);

    // Reopen (triggers recovery)
    let db = open_test_database();

    // Verify invariants
    db.verify_tree_invariants().unwrap();

    // Verify data
    verify_keys_present(&db, 1000);
}
```

**Corruption Injection**:
```rust
#[test]
fn test_corrupted_node_checksum() {
    let mut db = create_test_database();
    insert_keys(&db, 100);

    // Corrupt a node
    let page_id = db.get_root_page_id();
    let mut page = db.pager.get_page_mut(page_id).unwrap();
    page.data[100] ^= 0xFF; // Flip a bit

    // Attempt to read corrupted node
    let result = db.get(b"key1");

    // Verify error detected
    assert!(matches!(result, Err(Error::ChecksumMismatch)));
}
```

### Performance Test Infrastructure

**Criterion Benchmarks**: Use `criterion` crate for Rust:
```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion};

fn bench_point_lookup(c: &mut Criterion) {
    let db = create_test_database_with_1m_keys();
    let key = random_key();

    c.bench_function("point_lookup", |b| {
        b.iter(|| {
            black_box(db.get(black_box(&key)).unwrap())
        })
    });
}

criterion_group!(benches, bench_point_lookup);
criterion_main!(benches);
```

### Continuous Integration

**Test Categories**:
1. **Unit Tests**: Run on every commit (fast, < 1 minute)
2. **Integration Tests**: Run on every commit (moderate, < 5 minutes)
3. **Property Tests**: Run nightly (slow, < 30 minutes)
4. **Hardening Tests**: Run nightly (moderate, < 10 minutes)
5. **Performance Tests**: Run before releases (slow, < 1 hour)

**CI Configuration**:
```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - run: cargo test --lib --bins

  integration-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - run: cargo test --test '*'

  property-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - run: cargo test --release --features proptest
```

## Dependencies

**Uses**:
- B+Tree implementation (all components)
- Pager module (node I/O)
- WAL module (recovery tests)
- Error types (error verification)
- Test frameworks (proptest, criterion)

**Used By**:
- Continuous integration (automated test execution)
- Pre-release validation (comprehensive testing)
- Regression detection (catch bugs early)

## Related Specifications

- **06-btree-overview.md**: B+Tree structure and invariants
- **06-btree-node.md**: Node structure tests
- **06-btree-search.md**: Search operation tests
- **06-btree-insert.md**: Insert operation tests
- **06-btree-delete.md**: Delete operation tests
- **06-btree-split.md**: Split algorithm tests
- **06-btree-merge.md**: Merge algorithm tests
- **06-btree-delta.md**: Delta layer tests
- **06-btree-recovery.md**: Recovery tests
