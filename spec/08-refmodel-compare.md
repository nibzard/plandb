# Reference Model: Equivalence Checking

**Phase**: 8
**Task**: 8.5
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [Equivalence Concepts](#equivalence-concepts)
3. [State Comparison](#state-comparison)
4. [Digest Computation](#digest-computation)
5. [Diff Generation](#diff-generation)
6. [Production Validation](#production-validation)
7. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

Equivalence checking is the process of verifying that two database states (typically the reference model and the production implementation) represent identical data. This is the core mechanism for **correctness validation** - proving that the production database behaves exactly as specified.

Equivalence checking operates at multiple levels:
- **Structural equivalence**: Same B+Tree structure
- **Logical equivalence**: Same key-value mappings
- **Digest equivalence**: Same hash of all data
- **Operational equivalence**: Same results for all operations

---

## Equivalence Concepts

### Structural Equivalence

### Definition

Two B+Trees are **structurally equivalent** if they have:
- Identical node structure (same height, same fanout at each level)
- Identical keys in each node at same positions
- Identical child pointers at same positions

### Purpose

Structural equivalence is primarily useful for:
- Debugging implementation differences
- Verifying node split/merge logic
- Testing tree maintenance algorithms

### Limitations

Structural equivalence is **too strict** for general validation:
- Different B+Tree implementations may have different fanout
- Node splitting algorithms may produce different structures
- Same logical data can be arranged differently
- Production may optimize differently than reference model

### When to Use

- **During development**: Compare structures to find bugs
- **For unit tests**: Verify specific tree operations
- **Not for CI**: Too brittle for continuous validation

---

### Logical Equivalence

### Definition

Two database states are **logically equivalent** if they contain:
- Exactly the same set of keys
- Each key maps to the same value in both states
- No keys present in one but not the other

### Purpose

Logical equivalence is the **primary validation mechanism**:
- Tests if two databases store identical data
- Independent of implementation details
- Captures the essential correctness property

### Checking Method

To verify logical equivalence:
1. Iterate through all keys in state A
2. For each key, verify value is identical in state B
3. Iterate through all keys in state B
4. Verify no extra keys exist in B that aren't in A

### When to Use

- **All correctness validation**: Primary check for production vs reference
- **Property tests**: Verify operations produce correct state
- **Replay verification**: Confirm recovered state matches expected

---

### Digest Equivalence

### Definition

Two states are **digest equivalent** if they produce the same cryptographic hash.

### Digest Algorithm

Digest computation follows these steps:
1. Collect all key-value pairs from the state
2. Sort entries by key (deterministic ordering)
3. Serialize entries to bytes in canonical format
4. Compute cryptographic hash (e.g., SHA-256)
5. Return hash as digest

### Purpose

Digest equivalence provides:
- **Fast comparison**: Compare 32-byte hashes instead of full state
- **Regression detection**: Digests can be stored as baselines
- **Crash verification**: Compare recovered state digest to expected

### Limitations

- **Collision risk**: Different states could theoretically have same digest (negligible with SHA-256)
- **One-way**: Can't determine what changed, only that something did
- **No debugging**: Digest doesn't indicate where difference is

### When to Use

- **CI gates**: Compare digests in automated testing
- **Baseline storage**: Store digests as expected results
- **Quick validation**: Fast equivalence check before detailed comparison

---

### Operational Equivalence

### Definition

Two implementations are **operationally equivalent** if, given the same sequence of operations:
- All return values match exactly
- All errors match exactly
- All timing constraints (if applicable) match
- Final states are logically equivalent

### Purpose

Operational equivalence tests:
- **API compatibility**: Same inputs produce same outputs
- **Error handling**: Same error conditions
- **Observable behavior**: User-visible results match

### Checking Method

1. Generate random operation sequence
2. Execute on reference model, capture all results
3. Execute on production database, capture all results
4. Compare results line-by-line
5. If any mismatch, report as test failure

### When to Use

- **Property tests**: Comprehensive validation of operations
- **Fuzz testing**: Find edge cases where behavior diverges
- **Regression prevention**: Ensure changes don't break behavior

---

## State Comparison

### Full State Comparison

### compare_states(left: &SnapshotState, right: &SnapshotState) -> Result<bool, CompareError>

**Purpose**: Check if two snapshots are logically equivalent (same key-value mappings).

**Parameters**:
- **left**: First snapshot to compare
- **right**: Second snapshot to compare

**Returns**:
- **Ok(true)**: Snapshots are logically equivalent
- **Ok(false)**: Snapshots differ
- **Err(CompareError)**: Error during comparison

**Algorithm**:

1. Check if both trees have same count:
   a. If left.tree.count != right.tree.count, return Ok(false)
2. Iterate through all entries in left.tree:
   a. For each (key, value) in left:
      - Look up key in right.tree
      - If not found, return Ok(false)
      - If found, compare values:
        * If values differ, return Ok(false)
3. Iterate through all entries in right.tree:
   a. For each (key, value) in right:
      - Look up key in left.tree
      - If not found, return Ok(false) (redundant but safe)
4. If all checks passed, return Ok(true)

**Error Conditions**:
- **CompareError::IterationFailed**: Error during tree iteration
- **CompareError::ComparisonFailed**: Internal comparison error

**Complexity**:
- **Time**: O(N) where N is number of keys (must check all keys)
- **Space**: O(1) (no allocation, just traversal)

**Invariants**:
- If returns true, states are identical
- If returns false, states differ (but doesn't say how)
- Symmetric: compare_states(a, b) == compare_states(b, a)
- Reflexive: compare_states(a, a) always returns true

---

### Quick State Comparison

### compare_digests(left: &SnapshotState, right: &SnapshotState) -> Result<bool, CompareError>

**Purpose**: Quickly compare snapshots using pre-computed digests.

**Parameters**:
- **left**: First snapshot to compare
- **right**: Second snapshot to compare

**Returns**:
- **Ok(true)**: Digests match (states likely equivalent)
- **Ok(false)**: Digests differ (states definitely different)
- **Err(CompareError)**: Error during digest computation

**Algorithm**:

1. Compute digest of left.snapshot (or use cached if available)
2. Compute digest of right.snapshot (or use cached if available)
3. Compare digests byte-by-byte
4. Return Ok(digests are equal)

**Error Conditions**:
- **CompareError::DigestFailed**: Error computing digest

**Complexity**:
- **Time**: O(N) to compute digests (if not cached), O(1) if cached
- **Space**: O(N) for serialization during digest computation

**Invariants**:
- If digests differ, states definitely differ
- If digests match, states almost certainly equivalent (collision probability negligible)
- Faster than full comparison if digests cached

---

### Subset Comparison

### is_subset(subset: &SnapshotState, superset: &SnapshotState) -> Result<bool, CompareError>

**Purpose**: Check if all keys in subset exist in superset with same values.

**Parameters**:
- **subset**: Potential subset state
- **superset**: Potential superset state

**Returns**:
- **Ok(true)**: subset is a subset of superset
- **Ok(false)**: subset has keys/values not in superset
- **Err(CompareError)**: Error during comparison

**Algorithm**:

1. Iterate through all entries in subset.tree:
   a. For each (key, value) in subset:
      - Look up key in superset.tree
      - If not found, return Ok(false)
      - If found, compare values:
        * If values differ, return Ok(false)
2. If all checks passed, return Ok(true)

**Error Conditions**:
- **CompareError::IterationFailed**: Error during tree iteration

**Complexity**:
- **Time**: O(S) where S is number of keys in subset
- **Space**: O(1)

**Invariants**:
- Doesn't check if superset has extra keys
- Useful for verifying partial progress (e.g., after crash recovery)
- superset.count >= subset.count if returns true

---

## Digest Computation

### Digest Structure

### Digest: [u8; 32]

**Description**: 256-bit cryptographic hash (SHA-256) of serialized state.

**Invariants**:
- Deterministic: Same state always produces same digest
- Collision-resistant: Different states almost certainly produce different digests
- Fixed-size: Always 32 bytes regardless of state size

### Serialization Format

Before hashing, state must be serialized to canonical format:

1. **Header**: Fixed-size metadata
   - count: u64 (number of key-value pairs)
   - version: u32 (format version for compatibility)

2. **Entries**: Repeated for each key-value pair in sorted order
   - key_length: u32
   - key_bytes: [u8; key_length]
   - value_length: u32
   - value_bytes: [u8; value_length]

3. **Ordering**: Entries sorted by key (lexicographic byte comparison)

**Example**:
```
State: {("a", "1"), ("b", "2")}
Serialized: [count=2, version=1, key_len=1, "a", value_len=1, "1", key_len=1, "b", value_len=1, "2"]
Digest: SHA256(serialized)
```

---

### Digest Computation

### compute_digest(state: &SnapshotState) -> Result<Digest, DigestError>

**Purpose**: Compute cryptographic digest of snapshot state.

**Parameters**:
- **state**: Snapshot state to digest

**Returns**:
- **Ok(Digest)**: 32-byte hash of state
- **Err(DigestError)**: Error during serialization or hashing

**Algorithm**:

1. Create hasher (SHA-256):
   a. hasher = Sha256::new()
2. Serialize header:
   a. Update hasher with state.tree.count as u64 (little-endian)
   b. Update hasher with format version as u32
3. Serialize entries in sorted order:
   a. For each (key, value) in state.tree.iter() (ascending):
      - Update hasher with key.len() as u32
      - Update hasher with key bytes
      - Update hasher with value.len() as u32
      - Update hasher with value bytes
4. Finalize hash:
   a. digest = hasher.finalize()
   b. Return digest as [u8; 32]

**Error Conditions**:
- **DigestError::SerializationFailed**: Error during serialization
- **DigestError::HashFailed**: Error during hashing (shouldn't occur with SHA-256)

**Complexity**:
- **Time**: O(N log N) for iteration + sorting (though B+Tree already sorted)
- **Space**: O(1) for hasher (streaming, no full serialization needed)

**Invariants**:
- Same state always produces same digest
- Digests are 32 bytes
- Different states almost certainly produce different digests

---

### Incremental Digest

### IncrementalDigest: Struct

**Description**: Digest that can be updated incrementally as operations are applied.

**Fields**:
- **base_digest**: Digest - Digest of base state
- **writes**: BTreeMap<KeyBytes, Option<ValueBytes>> - Modifications to apply

**Purpose**:
- Avoid recomputing full digest for small changes
- Useful for comparing states during transaction processing

**Limitations**:
- Still requires O(W) work where W is number of writes
- Complexity may not be worth it (full digest is simple)
- Not recommended for initial implementation

---

## Diff Generation

### Diff Structure

### StateDiff: Struct

**Description**: Detailed difference between two snapshot states.

**Fields**:

#### added: BTreeSet<KeyBytes>

**Description**: Keys present in right state but not in left state.

**Invariants**:
- All keys in added are in right but not left
- No overlap with removed or modified

#### removed: BTreeSet<KeyBytes>

**Description**: Keys present in left state but not in right state.

**Invariants**:
- All keys in removed are in left but not right
- No overlap with added or modified

#### modified: BTreeMap<KeyBytes, (ValueBytes, ValueBytes)>

**Description**: Keys present in both states with different values.

**Fields**:
- **Key**: The key that differs
- **Value**: (left_value, right_value) tuple

**Invariants**:
- Key exists in both left and right
- left_value != right_value
- No overlap with added or removed

---

### Generate Diff

### generate_diff(left: &SnapshotState, right: &SnapshotState) -> Result<StateDiff, DiffError>

**Purpose**: Generate detailed difference between two snapshots.

**Parameters**:
- **left**: First snapshot (before state)
- **right**: Second snapshot (after state)

**Returns**:
- **Ok(StateDiff)**: Detailed difference
- **Err(DiffError)**: Error during comparison

**Algorithm**:

1. Initialize empty StateDiff {
   a. added: BTreeSet::new()
   b. removed: BTreeSet::new()
   c. modified: BTreeMap::new()
   }
2. Iterate through all entries in left.tree:
   a. For each (key, left_value) in left:
      - Look up key in right.tree
      - If not found:
        * diff.removed.insert(key.clone())
      - If found with right_value:
        * If left_value != right_value:
          - diff.modified.insert(key.clone(), (left_value, right_value))
3. Iterate through all entries in right.tree:
   a. For each (key, right_value) in right:
      - Look up key in left.tree
      - If not found:
        * diff.added.insert(key.clone())
4. Return diff

**Error Conditions**:
- **DiffError::IterationFailed**: Error during tree iteration

**Complexity**:
- **Time**: O(N + M) where N is keys in left, M is keys in right
- **Space**: O(D) where D is number of differences (added + removed + modified)

**Invariants**:
- Union of added, removed, modified keys covers all differences
- No key appears in more than one of added, removed, modified
- If diff is empty (no differences), states are equivalent

---

### Pretty Print Diff

### format_diff(diff: &StateDiff) -> String

**Purpose**: Generate human-readable description of differences.

**Parameters**:
- **diff**: StateDiff to format

**Returns**:
- **String**: Human-readable diff

**Algorithm**:

1. Build string with sections:
   a. "Added X keys:" list all added keys (with values)
   b. "Removed Y keys:" list all removed keys (with old values)
   c. "Modified Z keys:" list all modified keys (with old and new values)
2. Format each section with key and value bytes (hex or escaped)
3. Return formatted string

**Example Output**:
```
Added 2 keys:
  + "key1": "value1"
  + "key2": "value2"
Removed 1 key:
  - "key3": "old_value"
Modified 1 key:
  ~ "key4": "old" -> "new"
```

**Complexity**:
- **Time**: O(D) where D is number of differences
- **Space**: O(D * K) where K is average key/value length

---

## Production Validation

### Validation Workflow

### validate_production(ref_model: &RefModel, prod_db: &ProductionDb) -> Result<ValidationReport, ValidationError>

**Purpose**: Comprehensive validation of production database against reference model.

**Parameters**:
- **ref_model**: Reference model with expected state
- **prod_db**: Production database to validate

**Returns**:
- **Ok(ValidationReport)**: Detailed validation results
- **Err(ValidationError)**: Error during validation

**ValidationReport Fields**:
- **states_equivalent**: bool - Whether states match
- **digest_match**: bool - Whether digests match
- **diff**: Option<StateDiff> - Detailed differences if any
- **errors**: Vec<ValidationError> - List of validation errors

**Algorithm**:

1. Get current state from both:
   a. ref_snapshot = ref_model.current_state
   b. prod_snapshot = prod_db.snapshot()
2. Compare digests:
   a. ref_digest = compute_digest(ref_snapshot)?
   b. prod_digest = compute_digest(prod_snapshot)?
   c. digest_match = (ref_digest == prod_digest)
3. If digests match:
   a. Return ValidationReport {
      * states_equivalent: true,
      * digest_match: true,
      * diff: None,
      * errors: vec![]
      }
4. If digests differ:
   a. diff = generate_diff(ref_snapshot, prod_snapshot)?
   b. Return ValidationReport {
      * states_equivalent: false,
      * digest_match: false,
      * diff: Some(diff),
      * errors: vec![]
      }
5. If any errors during comparison:
   a. Return ValidationReport with errors populated

**Error Conditions**:
- **ValidationError::StateInaccessible**: Cannot retrieve state from database
- **ValidationError::ComparisonFailed**: Error during comparison

**Complexity**:
- **Time**: O(N) for digest computation, O(N) for diff if needed
- **Space**: O(N) for diff generation

**Invariants**:
- If states_equivalent is true, production is correct
- If states_equivalent is false, production has bugs
- digest_match true implies states_equivalent true (barring hash collision)

---

### Property Test Validation

### validate_sequence(ops: Vec<Operation>) -> Result<(), PropertyTestError>

**Purpose**: Execute operation sequence on both implementations and verify results match.

**Parameters**:
- **ops**: Sequence of operations to execute

**Returns**:
- **Ok(())**: All results matched, states equivalent
- **Err(PropertyTestError)**: Results differed or error occurred

**Operation Enum**:
```rust
enum Operation {
    Put { key: KeyBytes, value: ValueBytes },
    Delete { key: KeyBytes },
    Get { key: KeyBytes },
    Commit,
    Abort,
    // ...
}
```

**Algorithm**:

1. Initialize ref_model and prod_db to empty states
2. For each operation in ops:
   a. Execute on ref_model, capture result
   b. Execute on prod_db, capture result
   c. Compare results:
      - If results differ (different value or different error):
        * Return Err(PropertyTestError::Mismatch {
            * operation: index,
            * ref_result: captured,
            * prod_result: captured
          })
3. After all operations, compare final states:
   a. ref_state = ref_model.current_state
   b. prod_state = prod_db.snapshot()
   c. If not states_equivalent(ref_state, prod_state)?:
      - Return Err(PropertyTestError::StateMismatch)
4. Return Ok(())

**Error Conditions**:
- **PropertyTestError::Mismatch**: Operation produced different results
- **PropertyTestError::StateMismatch**: Final states differ
- **PropertyTestError::ExecutionFailed**: Error during execution

**Complexity**:
- **Time**: O(P * (log N) + N) where P is number of operations, N is final state size
- **Space**: O(N) for final state comparison

**Invariants**:
- If returns Ok, production behaves identically to reference model
- First mismatching operation is reported (fails fast)
- Comprehensive validation of operations and state

---

### Replay Validation

### validate_replay(log: &CommitLog, expected_model: &RefModel) -> Result<(), ReplayError>

**Purpose**: Replay commit log into empty model and verify matches expected state.

**Parameters**:
- **log**: Commit log from production database
- **expected_model**: Reference model with expected state

**Returns**:
- **Ok(())**: Replayed state matches expected
- **Err(ReplayError)**: Replay produced different state

**Algorithm**:

1. Create empty replay_model: RefModel::new()
2. For each commit record in log:
   a. Extract writes from commit record
   b. Create write transaction on replay_model
   c. Apply all writes
   d. Commit transaction
3. Compare replay_model.current_state to expected_model.current_state:
   a. If not equivalent:
      - diff = generate_diff(replay_state, expected_state)?
      - Return Err(ReplayError::StateMismatch { diff })
4. Return Ok(())

**Error Conditions**:
- **ReplayError::InvalidLog**: Log format error
- **ReplayError::StateMismatch**: Replayed state doesn't match expected

**Complexity**:
- **Time**: O(C * W * log N) where C is number of commits, W is writes per commit
- **Space**: O(N) for final state

**Invariants**:
- If returns Ok, log replay produces correct state
- Useful for crash recovery validation

---

## Rust Implementation Guidance

### Module Structure

Equivalence checking should be organized as:

```
ref_model/
├── validation/
│   ├── mod.rs              # Public API
│   ├── compare.rs          # State comparison functions
│   ├── digest.rs           # Digest computation
│   ├── diff.rs             # Diff generation and formatting
│   └── validate.rs         # Production validation
└── tests/
    └── property_tests.rs   # Property test implementations
```

### Type Definitions

#### Use Newtypes for Clarity

```rust
pub struct Digest([u8; 32]);

pub struct StateDiff {
    pub added: BTreeSet<KeyBytes>,
    pub removed: BTreeSet<KeyBytes>,
    pub modified: BTreeMap<KeyBytes, (ValueBytes, ValueBytes)>,
}

pub struct ValidationReport {
    pub states_equivalent: bool,
    pub digest_match: bool,
    pub diff: Option<StateDiff>,
    pub errors: Vec<ValidationError>,
}
```

**Benefits**:
- Type safety (can't confuse digest with raw bytes)
- Clear API (Digest vs [u8; 32])
- Encapsulation (can add methods to types)

#### Use Trait Objects for Flexibility

```rust
pub trait StateComparer {
    fn compare(&self, left: &SnapshotState, right: &SnapshotState) -> Result<bool, CompareError>;
}

pub struct FullComparer;
pub struct DigestComparer;
pub struct QuickComparer; // Check count first, then digest
```

**Benefits**:
- Pluggable comparison strategies
- Easy to add new comparison methods
- Testable in isolation

### Concurrency

#### Comparison is Read-Only

```rust
fn compare_states(left: &SnapshotState, right: &SnapshotState) -> Result<bool, CompareError> {
    // Only reads, no modifications
    // Safe to call concurrently
}
```

**Benefits**:
- Can compare snapshots while database is in use
- No locking needed
- Safe concurrent validation

### Key Decisions

#### Hash Algorithm: SHA-256 vs BLAKE3
**Decision**: Use SHA-256

**Reason**:
- Widely available in standard libraries
- Sufficient collision resistance for testing
- 32-byte digest is manageable size
- BLAKE3 faster but not critical for reference model

#### Diff Storage: In-Memory vs Streamed
**Decision**: Store diff in memory

**Reason**:
- Test workloads are small (differences fit in memory)
- Simpler implementation
- Easier to test and debug
- Can switch to streaming if needed

#### Validation: Strict vs Lenient
**Decision**: Strict validation (any difference is failure)

**Reason**:
- Correctness is paramount
- No room for "close enough"
- Clear pass/fail criteria
- Tests must be deterministic

### Implementation Notes

#### Step 1: Implement Digest Computation
Start with compute_digest:
- Use sha2 crate for SHA-256
- Serialize state to canonical format
- Update hasher incrementally
- Test with known vectors

#### Step 2: Implement State Comparison
Add comparison functions:
- compare_states: Full key-value comparison
- compare_digests: Quick hash comparison
- is_subset: Subset checking

#### Step 3: Implement Diff Generation
Build diff utilities:
- generate_diff: Create StateDiff
- format_diff: Human-readable output
- Pretty printing for debugging

#### Step 4: Implement Validation
Add production validation:
- validate_production: Comprehensive check
- validate_sequence: Property test validation
- validate_replay: Log replay validation

### Testing Strategy

#### Unit Tests Needed For

**Digest Computation**:
- Empty state produces same digest
- Same state produces same digest (determinism)
- Different states produce different digests
- Canonical format is correct

**State Comparison**:
- Equivalent states return true
- Different states return false
- Subset checking works correctly
- Comparison is symmetric and reflexive

**Diff Generation**:
- Added keys detected
- Removed keys detected
- Modified keys detected
- No overlap between added/removed/modified

**Validation**:
- Correct production passes validation
- Incorrect production fails with detailed diff
- Property tests catch divergences

#### Property Tests For

**Digest Determinism**:
- Same state hashed multiple times produces same digest
- Different operations producing same state have same digest

**Comparison Correctness**:
- If compare_states returns true, all keys have same values
- If compare_states returns false, at least one difference exists

**Diff Correctness**:
- Applying diff to left produces right
- Diff is minimal (no redundant entries)

#### Integration Scenarios

**Full Validation Pipeline**:
- Generate 1000 random operations
- Execute on reference and production
- Validate all intermediate results
- Validate final state equivalence

**Crash Recovery Validation**:
- Commit 100 transactions
- Simulate crash at random points
- Replay log to recovery point
- Validate state matches expected

**Regression Testing**:
- Store reference digests for known workloads
- Run workload on production
- Compare digests
- Fail if different

---

## Summary

Equivalence checking provides:

- **Multiple comparison methods**: Structural, logical, digest, operational
- **Fast validation**: Digest comparison for quick checks
- **Detailed debugging**: Diff generation shows exact differences
- **Comprehensive validation**: Property tests verify all operations
- **Production validation**: Ensure production matches reference model

This is the **core correctness mechanism** - proving that the production database behaves exactly as specified by the reference model.
