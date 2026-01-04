# Reference Model: Validation Scenarios

**Phase**: 8
**Task**: 8.8
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [Unit Test Scenarios](#unit-test-scenarios)
3. [Property Test Scenarios](#property-test-scenarios)
4. [Integration Test Scenarios](#integration-test-scenarios)
5. [Regression Test Scenarios](#regression-test-scenarios)
6. [Performance Test Scenarios](#performance-test-scenarios)
7. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

This specification describes comprehensive test scenarios for validating the reference model implementation. These scenarios ensure correctness, uncover edge cases, and provide confidence that the reference model is a trustworthy oracle.

Tests are organized into categories:
- **Unit tests**: Validate individual functions and data structures
- **Property tests**: Verify invariants hold for random inputs
- **Integration tests**: Validate end-to-end workflows
- **Regression tests**: Prevent bugs from reappearing
- **Performance tests**: Ensure acceptable performance (non-critical for reference model)

---

## Unit Test Scenarios

### B+Tree Tests

#### 1. Empty Tree Operations

**Purpose**: Verify operations on empty tree behave correctly.

**Test Cases**:

1. **Insert first element**
   - Insert ("a", "value1") into empty tree
   - Verify: tree.count == 1
   - Verify: lookup("a") returns Some("value1")
   - Verify: tree.height == 1 (root is leaf)

2. **Lookup in empty tree**
   - Lookup "x" in empty tree
   - Verify: returns None (not error)

3. **Delete from empty tree**
   - Delete "x" from empty tree
   - Verify: returns Ok(None) (no-op, not error)
   - Verify: tree still empty

4. **Iterate empty tree**
   - Create forward iterator on empty tree
   - Verify: iterator.next() returns None immediately
   - Verify: reverse iterator also empty

---

#### 2. Single Node Operations

**Purpose**: Verify operations when all data fits in one node.

**Test Cases**:

1. **Insert up to capacity**
   - Insert MAX_ENTRIES key-value pairs
   - Verify: tree.count == MAX_ENTRIES
   - Verify: tree.height == 1 (still single level)
   - Verify: all keys found via lookup

2. **Insert beyond capacity (overflow)**
   - Insert MAX_ENTRIES + 1 key-value pairs
   - Verify: tree splits into two leaf nodes
   - Verify: tree.height == 2 (new internal root)
   - Verify: all keys found via lookup
   - Verify: in-order traversal produces sorted keys

3. **Delete from single node**
   - Start with 10 entries in single node
   - Delete middle entry
   - Verify: tree.count == 9
   - Verify: deleted key not found
   - Verify: other keys still present
   - Verify: node not merged (still >= min_entries)

4. **Delete causing underflow**
   - Start with min_entries entries
   - Delete one entry
   - Verify: node doesn't underflow (may merge or borrow)
   - Verify: tree structure valid

---

#### 3. Multi-Level Operations

**Purpose**: Verify operations with multiple tree levels.

**Test Cases**:

1. **Insert causing cascading splits**
   - Insert enough keys to cause multiple splits
   - Verify: each split produces valid tree
   - Verify: tree height increases appropriately
   - Verify: all keys found after all inserts
   - Verify: invariants maintained throughout

2. **Delete causing cascading merges**
   - Build tree with height >= 3
   - Delete keys to cause multiple merges
   - Verify: each merge produces valid tree
   - Verify: tree height decreases appropriately
   - Verify: remaining keys still found
   - Verify: invariants maintained throughout

3. **Lookup in multi-level tree**
   - Build tree with height 5
   - Lookup keys at various levels (root, internal, leaf)
   - Verify: correct values returned
   - Verify: lookup path length == tree.height

4. **Range scan in multi-level tree**
   - Build tree with 1000 keys distributed across levels
   - Scan range [200, 400)
   - Verify: exactly 200 keys returned
   - Verify: keys in sorted order
   - Verify: all keys in range

---

#### 4. B+Tree Invariants

**Purpose**: Verify all invariants hold after various operations.

**Test Cases**:

1. **Balanced invariant**
   - Perform 1000 random inserts and deletes
   - After each operation, verify: all root-to-leaf paths same length
   - Verify: tree.height matches path length

2. **Ordered invariant**
   - Perform 1000 random inserts
   - Verify: in-order traversal produces sorted keys
   - Verify: no duplicate keys

3. **Capacity invariant**
   - After each insert, verify: no node exceeds max_entries / max_fanout
   - After each delete, verify: no node under min entries/children

4. **Pointer consistency**
   - After each operation, verify: all child pointers valid
   - Verify: leaf linked list consistent (next/prev pointers)

---

### Snapshot Tests

#### 1. Snapshot Creation

**Test Cases**:

1. **Initial snapshot**
   - Verify: RefModel starts with snapshot at txn_id 0
   - Verify: snapshot.tree is empty
   - Verify: snapshot.parent_txn_id is None

2. **Snapshot after commit**
   - Insert key "a", commit
   - Verify: new snapshot created with txn_id 1
   - Verify: snapshot.tree contains "a"
   - Verify: snapshot.parent_txn_id is Some(0)

3. **Multiple snapshots**
   - Commit 10 transactions with different writes
   - Verify: 11 snapshots exist (0 through 10)
   - Verify: each snapshot derived from previous
   - Verify: each snapshot has correct state

4. **Snapshot independence**
   - Get snapshot at txn_id 5
   - Commit more transactions (txn_id 6, 7, 8)
   - Verify: snapshot at txn_id 5 unchanged
   - Verify: snapshots are immutable

---

#### 2. Time-Travel Queries

**Test Cases**:

1. **Read at specific historical point**
   - Commit sequence: put "a"=1, put "b"=2, put "c"=3
   - Read at txn_id 1: verify only "a" exists
   - Read at txn_id 2: verify "a" and "b" exist
   - Read at txn_id 3: verify all three exist

2. **Historical scan**
   - Insert 100 keys in 10 transactions (10 keys each)
   - Scan range at txn_id 5
   - Verify: exactly 50 keys returned
   - Verify: keys match expected state at txn_id 5

3. **Non-existent snapshot**
   - Attempt to read at txn_id 999 (doesn't exist)
   - Verify: returns Err(SnapshotNotFound)

---

### Transaction Tests

#### 1. Read Transactions

**Test Cases**:

1. **Basic read**
   - Insert keys, commit
   - Begin read transaction
   - Get keys, verify correct values
   - Verify: snapshot unchanged

2. **Multiple concurrent reads**
   - Create 10 read transactions on same snapshot
   - Verify: all see identical state
   - Verify: operations don't interfere

3. **Read after write**
   - Begin write, insert "a"
   - Begin read (before commit)
   - Verify: read doesn't see "a" (snapshot isolation)

4. **Read after commit**
   - Begin write, insert "a", commit
   - Begin read
   - Verify: read sees "a"

---

#### 2. Write Transactions

**Test Cases**:

1. **Basic write**
   - Begin write transaction
   - Put ("a", "value1")
   - Put ("b", "value2")
   - Commit
   - Verify: both keys in new snapshot

2. **Write isolation**
   - Begin write, put "a" (not committed)
   - Begin another write, put "b"
   - Commit both
   - Verify: second write doesn't see first's uncommitted "a"
   - Verify: final snapshot has both keys (from both commits)

3. **Abort discard**
   - Begin write, put "a", put "b"
   - Abort
   - Verify: snapshot unchanged, no keys added

4. **Multiple operations**
   - Begin write
   - Put "a", delete "a", put "a" (last write wins)
   - Commit
   - Verify: "a" exists with value from last put

---

#### 3. Transaction Errors

**Test Cases**:

1. **Use after commit**
   - Begin write, put "a", commit
   - Attempt to put "b" on same transaction
   - Verify: returns Err(AlreadyCommitted)

2. **Use after abort**
   - Begin write, put "a", abort
   - Attempt to commit
   - Verify: returns Err(AlreadyCommitted)

3. **Double commit**
   - Begin write, commit
   - Attempt to commit again
   - Verify: returns Err(AlreadyCommitted)

---

## Property Test Scenarios

### 1. Round-Trip Properties

**Purpose**: Verify operations are reversible and consistent.

**Properties**:

1. **Insert then lookup**
   - For any key-value: insert, then lookup
   - Property: lookup returns Some(value)

2. **Insert then delete then lookup**
   - For any key: insert, delete, lookup
   - Property: lookup returns None

3. **Update then lookup**
   - For any key-value1-value2: insert(key, value1), update(key, value2), lookup
   - Property: lookup returns Some(value2)

4. **Serialize then deserialize**
   - For any state: serialize to bytes, deserialize
   - Property: original state == deserialized state

---

### 2. Idempotence Properties

**Purpose**: Verify repeating operations produces predictable results.

**Properties**:

1. **Delete idempotence**
   - For any key: delete(key) twice
   - Property: second delete also returns Ok(None)

2. **Update same value**
   - For any key-value: update(key, value) twice
   - Property: final value is value (idempotent)

3. **Snapshot immutability**
   - For any snapshot: read same key multiple times
   - Property: always returns same value

---

### 3. Ordering Properties

**Purpose**: Verify operations maintain ordering invariants.

**Properties**:

1. **Iteration order**
   - For any set of inserts: collect keys via iterator
   - Property: keys are in sorted order

2. **Reverse iteration order**
   - For any state: reverse iterator
   - Property: keys in strictly descending order

3. **Range subset**
   - For any state and range [a, b]: collect range keys, collect all keys
   - Property: range_keys subset of all_keys
   - Property: all range keys satisfy a <= key < b

---

### 4. State Transition Properties

**Purpose**: Verify state transitions are valid.

**Properties**:

1. **Count consistency**
   - After N inserts and M deletes (where deleted keys exist): count == N - M
   - Property: tree.count matches actual entries

2. **Monotonic txn_id**
   - For sequence of commits: txn_id strictly increasing
   - Property: each new txn_id == previous + 1

3. **Snapshot derivation**
   - For any committed txn: snapshot derives from parent
   - Property: snapshot == parent.tree + writes

---

### 5. Conjunction Properties

**Purpose**: Verify relationships between operations.

**Properties**:

1. **Get vs contains**
   - For any state and key: get(key) == Some(value) iff contains(key) == true

2. **Insert vs update**
   - For new key: insert == update (both add key)
   - For existing key: insert may fail, update succeeds

3. **Count vs iteration**
   - For any state: count == number of elements from iterator
   - Property: tree.count == iterator.collect().len()

---

## Integration Test Scenarios

### 1. Complex Operation Sequences

**Test Cases**:

1. **Mixed operations**
   - Generate sequence: 1000 random puts, deletes, updates
   - Verify: final state matches expected (track manually)
   - Verify: all invariants hold after each operation

2. **Transaction boundaries**
   - Generate sequence with commits, aborts, interleaved reads
   - Verify: committed writes visible after commit
   - Verify: aborted writes never visible
   - Verify: reads see correct snapshots

3. **Time-travel validation**
   - Commit 100 transactions with different keys
   - For each txn_id 0..100:
     - Create read transaction
     - Verify all reads match expected state at that txn_id

---

### 2. Cross-Process Validation

**Test Cases**:

1. **Serialize-transfer-deserialize**
   - Process A: Create state, serialize to bytes
   - Transfer bytes to process B
   - Process B: Deserialize bytes
   - Verify: states equivalent

2. **Baseline comparison**
   - Process A: Run workload, serialize result
   - Save to file as baseline
   - Process B: Run same workload, serialize result
   - Compare bytes to baseline
   - Verify: identical

---

### 3. Production Comparison

**Test Cases**:

1. **Operation-by-operation comparison**
   - Generate random operation sequence
   - Execute on reference model
   - Execute on production database
   - After each operation: compare states
   - Verify: identical at each step

2. **Final state comparison**
   - Generate 10000 random operations
   - Execute on both implementations
   - Serialize both states
   - Compare bytes
   - Verify: identical

3. **Error handling comparison**
   - Generate operations that should fail (invalid txn_id, etc.)
   - Execute on both
   - Verify: same errors returned

---

### 4. Crash Recovery Validation

**Test Cases**:

1. **Log replay**
   - Commit 100 transactions, capture commit log
   - Create empty reference model
   - Replay log from txn_id 0 to 50
   - Verify: state at txn_id 50 matches original
   - Continue replay to 100
   - Verify: final state matches

2. **Partial recovery**
   - Commit 100 transactions
   - Simulate crash at txn_id 73 (during commit)
   - Verify: recovered state matches txn_id 72 (last complete)
   - Verify: txn_id 73 not applied

---

## Regression Test Scenarios

### 1. Historical Bugs

**Purpose**: Ensure fixed bugs don't reappear.

**Approach**:
- For each bug found, add test case that would have caught it
- Name test after bug (e.g., `test_bug_123_split_corruption`)
- Include minimal reproduction case

**Examples**:

1. **Node split corruption bug** (hypothetical)
   - Insert specific keys that caused split bug
   - Verify: tree structure valid after split

2. **Delete merge bug** (hypothetical)
   - Perform specific delete sequence that caused merge bug
   - Verify: tree structure valid after merge

3. **Snapshot derivation bug** (hypothetical)
   - Commit specific writes that caused derivation bug
   - Verify: child snapshot derives correctly from parent

---

### 2. Baseline Regression

**Purpose**: Prevent behavior changes over time.

**Test Cases**:

1. **Fixed operation sequence**
   - Define static sequence of 100 operations
   - Serialize final state
   - Store as baseline
   - On each test run: compare to baseline
   - Fail if different

2. **Digest regression**
   - For set of standard workloads:
     - Run workload
     - Compute digest
     - Compare to stored digest
     - Fail if different

---

### 3. Upgrade Testing

**Purpose**: Verify reference model upgrades don't break compatibility.

**Test Cases**:

1. **Format compatibility**
   - Deserialize snapshots from old format
   - Verify: correctly loaded
   - Serialize back to current format
   - Verify: logically equivalent

2. **API compatibility**
   - Run old test suite against new version
   - Verify: all tests pass
   - Verify: no API breaking changes

---

## Performance Test Scenarios

**Note**: Performance is not critical for reference model, but tests ensure reasonable performance for testing.

### 1. Scalability Tests

**Test Cases**:

1. **Large dataset**
   - Insert 1,000,000 keys
   - Verify: completes in reasonable time (< 10 seconds)
   - Verify: lookup time acceptable (< 1ms per lookup)

2. **Deep tree**
   - Insert enough keys to create height 10 tree
   - Verify: operations scale logarithmically

3. **Large keys/values**
   - Insert keys with 1KB keys, 1MB values
   - Verify: operations complete successfully
   - Verify: serialization/deserialization works

---

### 2. Memory Usage Tests

**Test Cases**:

1. **Memory growth**
   - Insert 100,000 keys
   - Measure memory usage
   - Verify: linear growth (no leaks)

2. **Snapshot memory**
   - Create 1000 snapshots (each with 100 keys)
   - Verify: memory usage reasonable
   - Verify: cleanup reduces memory

---

### 3. Concurrent Read Performance

**Test Cases**:

1. **Read scalability**
   - Create snapshot with 1,000,000 keys
   - Spawn 100 concurrent read transactions
   - Verify: all complete without blocking
   - Verify: no data races (thread sanitizer)

---

## Rust Implementation Guidance

### Test Organization

```
ref_model/
├── tests/
│   ├── unit/
│   │   ├── btree_tests.rs       # B+Tree unit tests
│   │   ├── snapshot_tests.rs    # Snapshot unit tests
│   │   └── txn_tests.rs         # Transaction unit tests
│   ├── property/
│   │   ├── round_trip.rs        # Round-trip properties
│   │   ├── invariants.rs        # Invariant properties
│   │   └── ordering.rs          # Ordering properties
│   ├── integration/
│   │   ├── complex_sequences.rs # Complex operation sequences
│   │   ├── cross_process.rs     # Cross-process validation
│   │   └── production_compare.rs # Production comparison
│   ├── regression/
│   │   ├── bug_XXX.rs           # Historical bug tests
│   │   └── baselines/           # Baseline data files
│   └── performance/
│       ├── scalability.rs       # Scalability tests
│       └── memory.rs            # Memory usage tests
└── fuzz/
    └── fuzz_tests.rs            # Fuzz integration tests
```

### Test Frameworks

#### Unit Tests
Use built-in Rust testing:
```rust
#[cfg(test)]
mod tests {
    #[test]
    fn test_empty_tree() {
        // Test implementation
    }
}
```

#### Property Tests
Use proptest crate:
```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn test_insert_then_lookup(key in any::<Vec<u8>>(), value in any::<Vec<u8>>()) {
        // Property test implementation
    }
}
```

#### Integration Tests
Use standard integration tests in `tests/` directory.

### Running Tests

```bash
# Run all tests
cargo test

# Run unit tests only
cargo test --lib

# Run specific test
cargo test test_empty_tree

# Run property tests
cargo test --test proptests

# Run with sanitizers
cargo test --release
RUSTFLAGS="-Z sanitizer=thread" cargo test
```

### Coverage

```bash
# Generate coverage report
cargo install cargo-tarpaulin
cargo tarpaulin --out Html

# View coverage in browser
# Opens html report with percentage coverage
```

### Continuous Integration

Add to CI pipeline:
1. Run all tests on every commit
2. Run property tests with multiple iterations
3. Run fuzz tests for fixed duration
4. Check coverage threshold (>90%)
5. Run performance regression tests

---

## Summary

Comprehensive test scenarios ensure:

- **Correctness**: All operations behave as specified
- **Robustness**: Edge cases and errors handled properly
- **Reliability**: No crashes or panics on valid inputs
- **Consistency**: Invariants maintained across all operations
- **Compatibility**: Works with production implementation
- **Regression**: Bugs don't reappear

The reference model with this test suite serves as a **trusted oracle**, providing confidence that the production implementation behaves correctly.
