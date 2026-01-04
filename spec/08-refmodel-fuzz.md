# Reference Model: Fuzz Integration

**Phase**: 8
**Task**: 8.7
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [Fuzz Testing Strategy](#fuzz-testing-strategy)
3. [Fuzz Input Format](#fuzz-input-format)
4. [Fuzz Harness](#fuzz-harness)
5. [Invariant Checking](#invariant-checking)
6. [Crash & Bug Detection](#crash--bug-detection)
7. [Coverage Guidance](#coverage-guidance)
8. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

Fuzz testing (fuzzing) automatically generates random inputs to find bugs, panics, and crashes in the reference model. By executing the reference model with thousands of random operation sequences, fuzz testing discovers:
- **Panic conditions**: Invalid operations that cause crashes
- **Invariant violations**: B+Tree or snapshot invariants broken
- **Edge cases**: Rare operation sequences that fail
- **Memory issues**: Leaks, use-after-free, buffer overflows

The reference model is particularly amenable to fuzzing because:
- **Fast execution**: In-memory operations are quick
- **Deterministic**: Same input always produces same output
- **Self-contained**: No external dependencies or I/O
- **Comprehensive invariants**: Many checkable properties

---

## Fuzz Testing Strategy

### Goals

#### 1. Crash Detection
Find any operations or operation sequences that cause panics or aborts.

#### 2. Invariant Violations
Detect violations of B+Tree, snapshot, or transaction invariants.

#### 3. Edge Cases
Exercise boundary conditions (empty tree, single node, overflow, etc.).

#### 4. Correctness Bugs
Find cases where operations produce incorrect results.

### Approach

#### Black-Box Fuzzing
- Treat reference model as black box
- Generate random operation sequences
- Execute and observe results
- No knowledge of internal structure

#### Structure-Aware Fuzzing
- Use knowledge of data structures
- Generate valid operations only
- Focus on likely bug locations
- More efficient than pure black-box

#### Hybrid Approach (Recommended)
- Start with black-box for broad coverage
- Add structure-aware guidance for edge cases
- Use coverage feedback to prioritize inputs

---

## Fuzz Input Format

### Operation Stream Encoding

Fuzz input is a byte stream encoding a sequence of operations. Each operation starts with an opcode byte followed by operation-specific data.

### Opcode Definitions

| Opcode | Name | Format | Description |
|--------|------|--------|-------------|
| 0x01 | PUT | [opcode] [key_len] [key] [val_len] [val] | Insert or update key |
| 0x02 | DELETE | [opcode] [key_len] [key] | Delete key |
| 0x03 | GET | [opcode] [key_len] [key] | Look up key (for validation, no effect) |
| 0x04 | COMMIT | [opcode] | Commit write transaction |
| 0x05 | ABORT | [opcode] | Abort write transaction |
| 0x06 | BEGIN_READ | [opcode] [txn_id] | Begin read on specific snapshot |
| 0x07 | BEGIN_WRITE | [opcode] | Begin write transaction |
| 0x08 | ITER | [opcode] [count] | Iterate next count entries |
| 0x09 | SCAN | [opcode] [start_len] [start] [end_len] [end] | Scan range |
| 0xFF | NOOP | [opcode] | No operation (for padding) |

### Field Encoding

#### key_len: u16
- 2 bytes, little-endian
- Range: 0 to 65535
- Truncated to max 4096 (practical limit)

#### val_len: u16
- 2 bytes, little-endian
- Range: 0 to 65535
- Truncated to max 1,048,576 (1MB, practical limit)

#### txn_id: u64
- 8 bytes, little-endian
- Range: 0 to 2^64 - 1
- Clamped to available snapshots

#### count: u16
- 2 bytes, little-endian
- Number of iterator steps

### Example Fuzz Input

```
Bytes (hex):
  07             // BEGIN_WRITE
  01 00 01 61 00 01 62  // PUT key="a", value="b"
  01 00 01 63 00 01 64  // PUT key="c", value="d"
  04             // COMMIT
  07             // BEGIN_WRITE
  02 00 01 61    // DELETE key="a"
  04             // COMMIT
  06 00 0000000000000001 // BEGIN_READ txn_id=1

Decoded operations:
  1. Begin write transaction
  2. Put ("a", "b")
  3. Put ("c", "d")
  4. Commit
  5. Begin write transaction
  6. Delete ("a")
  7. Commit
  8. Begin read on txn_id=1
```

### Input Generation Strategies

#### Random Bytes
- Generate completely random byte sequence
- Parse as operations (may produce invalid operations)
- High error rate but finds edge cases

#### Structure-Aware
- Generate valid operation sequences
- Respect operation semantics (e.g., COMMIT after BEGIN_WRITE)
- Lower error rate, better coverage of valid code paths

#### Mutational
- Start with valid seed input
- Apply random mutations (bit flips, byte inserts, deletes)
- Maintain partial validity
- Good for finding variations of working cases

---

## Fuzz Harness

### Harness Structure

### fuzz_target(input: &[u8])

**Purpose**: Entry point for fuzz testing. Parse input as operations and execute on reference model.

**Parameters**:
- **input**: Random byte stream from fuzzer

**Returns**: None (panics on bug or invariant violation)

**Algorithm**:

1. Initialize empty RefModel
2. Initialize operation index = 0
3. While operation_index < input.len():
   a. Parse next operation from input starting at operation_index
   b. If parse fails (insufficient bytes, invalid opcode):
      - Break (stop processing)
   c. Execute operation on RefModel:
      - If operation panics, let panic propagate (fuzzer catches it)
      - If operation returns error, ignore (expected for some random inputs)
      - If operation succeeds, continue
   d. After each operation, check invariants:
      - check_btree_invariants(model.current_state.tree)
      - check_snapshot_invariants(model.current_state)
      - check_model_invariants(model)
      - If any check fails, panic with details
   e. Advance operation_index by operation size
4. Return successfully

**Error Handling**:
- **Parse errors**: Stop processing (don't panic, invalid input is expected)
- **Operation errors**: Ignore (some random operations will fail, e.g., delete non-existent key)
- **Panic**: Let panic propagate to fuzzer (indicates bug)
- **Invariant violations**: Panic with diagnostic information

---

### Operation Parsing

### parse_operation(input: &[u8], offset: usize) -> Result<Operation, ParseError>

**Purpose**: Parse one operation from byte stream.

**Parameters**:
- **input**: Full input bytes
- **offset**: Starting position in input

**Returns**:
- **Ok(Operation)**: Parsed operation
- **Err(ParseError)**: Insufficient bytes or invalid opcode

**Algorithm**:

1. If offset >= input.len(), return Err(ParseError::UnexpectedEof)
2. opcode = input[offset]
3. Match opcode:
   - **0x01 (PUT)**:
     * If offset + 3 > input.len(), return Err
     * key_len = u16::from_le_bytes(input[offset+1..offset+3])
     * If offset + 3 + key_len + 2 > input.len(), return Err
     * key = input[offset+3..offset+3+key_len]
     * val_len = u16::from_le_bytes(input[offset+3+key_len..offset+3+key_len+2])
     * If offset + 3 + key_len + 2 + val_len > input.len(), return Err
     * val = input[offset+3+key_len+2..offset+3+key_len+2+val_len]
     * Return Ok(Operation::Put {key, val})
   - **0x02 (DELETE)**:
     * Similar parsing for key_len and key
     * Return Ok(Operation::Delete {key})
   - **Other opcodes**: Parse similarly
4. Return parsed operation

**Operation Size Calculation**:

- **PUT**: 1 (opcode) + 2 (key_len) + key_len + 2 (val_len) + val_len
- **DELETE**: 1 + 2 + key_len
- **GET**: 1 + 2 + key_len
- **COMMIT/ABORT/BEGIN_WRITE**: 1
- **BEGIN_READ**: 1 + 8 (txn_id)
- **ITER**: 1 + 2 (count)
- **SCAN**: 1 + 2 + start_len + 2 + end_len

---

### Operation Execution

### execute_operation(model: &mut RefModel, op: Operation)

**Purpose**: Execute one operation on the model.

**Parameters**:
- **model**: Mutable reference to RefModel
- **op**: Operation to execute

**Returns**: Result<(), OpError> (errors are ignored in fuzz harness)

**Algorithm**:

1. Match op:
   - **Operation::Put {key, value}**:
     * Get current write transaction (or begin one if none active)
     * Execute txn.put(key, value)
     * Ignore errors (duplicate key, etc.)
   - **Operation::Delete {key}**:
     * Get current write transaction
     * Execute txn.delete(key)
     * Ignore errors (key not found, etc.)
   - **Operation::Get {key}**:
     * Get current read transaction (or begin one on latest snapshot)
     * Execute txn.get(key)
     * Ignore result (just exercise the code path)
   - **Operation::Commit**:
     * If write transaction active, commit it
     * Clear active transaction reference
   - **Operation::Abort**:
     * If write transaction active, abort it
     * Clear active transaction reference
   - **Operation::BeginRead {txn_id}**:
     * Execute model.begin_read(txn_id)
     * Store read transaction for subsequent GET/ITER operations
   - **Operation::BeginWrite**:
     * Execute model.begin_write()
     * Store write transaction for subsequent PUT/DELETE operations
   - **Operation::Iter {count}**:
     * If read transaction active, iterate count entries
   - **Operation::Scan {start, end}**:
     * If read transaction active, scan range

**Transaction Management**:
- Fuzz harness tracks current active transaction (read or write)
- If operation requires transaction but none active, begin one automatically
- COMMIT/ABORT clear active transaction reference
- BEGIN_READ/BEGIN_WRITE replace active transaction

---

## Invariant Checking

### B+Tree Invariants

### check_btree_invariants(tree: &BTree)

**Purpose**: Verify all B+Tree invariants hold. Panic if any violated.

**Invariants Checked**:

1. **Balanced**: All root-to-leaf paths have same length
2. **Ordered**: In-order traversal produces sorted keys
3. **No duplicates**: Each key appears at most once
4. **Node capacity**: All nodes respect min/max children/entries
5. **Pointer consistency**: Internal node child pointers are valid
6. **Leaf linked list**: Doubly-linked list is consistent

**Algorithm**:

1. If tree is empty, return (trivially valid)
2. Check leaf depth:
   a. Traverse from root to leftmost leaf, record depth
   b. Traverse from root to rightmost leaf, verify depth same
   c. Optionally, check all leaves (expensive for large trees)
3. Check ordering:
   a. Perform in-order traversal
   b. Verify each key < next key
4. Check node capacities:
   a. Traverse all nodes
   b. For each internal node: verify 2 <= children.len() <= max_fanout
   c. For each leaf node: verify 1 <= entries.len() <= max_entries
5. Check pointer consistency:
   a. For each internal node, verify all children are valid nodes
6. Check leaf linked list:
   a. Traverse from leftmost to rightmost leaf
   b. Verify each leaf's next.prev points back to leaf
7. If all checks pass, return silently

**Panic Message**: Invariant name, node location (if applicable), details of violation

---

### Snapshot Invariants

### check_snapshot_invariants(snapshot: &SnapshotState)

**Purpose**: Verify snapshot invariants hold.

**Invariants Checked**:

1. **Immutable**: Snapshot is not modified (enforced by Rust type system)
2. **TxnId consistency**: txn_id matches parent's txn_id + 1 (except txn_id=0)
3. **Tree validity**: Tree passes all B+Tree invariants

**Algorithm**:

1. Call check_btree_invariants(snapshot.tree)
2. If snapshot.txn_id > 0:
   a. Verify snapshot.parent_txn_id == Some(snapshot.txn_id - 1)
3. Return

---

### Model Invariants

### check_model_invariants(model: &RefModel)

**Purpose**: Verify RefModel invariants hold.

**Invariants Checked**:

1. **Snapshot coherence**: current_state equals snapshots[current_txn_id]
2. **Transaction order**: txn_ids are sequential (no gaps)
3. **Derivation chain**: Each snapshot derives from previous
4. **Consistency**: All snapshots pass snapshot invariants

**Algorithm**:

1. Verify model.snapshots.contains_key(model.current_txn_id)
2. Verify Arc::ptr_eq(model.current_state, model.snapshots[model.current_txn_id])
3. For each (txn_id, snapshot) in model.snapshots:
   a. If txn_id > 0:
      - Verify snapshot.parent_txn_id == Some(txn_id - 1)
   b. Call check_snapshot_invariants(snapshot)
4. Verify model.min_retained_txn_id <= model.current_txn_id
5. Return

---

## Crash & Bug Detection

### Panic Conditions

The fuzz harness should panic (and fuzzer should catch) when:

#### 1. Invariant Violations
- B+Tree invariants fail (unbalanced, duplicate keys, etc.)
- Snapshot invariants fail (invalid parent_txn_id)
- Model invariants fail (gaps in history)

#### 2. Logic Errors
- Operation produces impossible state (e.g., count doesn't match actual entries)
- Index out of bounds (internal bug, not from invalid input)
- Null pointer dereference (memory corruption)

#### 3. Assertion Failures
- Any unreachable() reached (indicates logic error)
- Any assert! that fails (indicates bug)

#### 4. Resource Exhaustion
- Memory allocation failures (for reasonable input sizes)
- Stack overflow (deep recursion from malicious input)

### Error Conditions (Not Bugs)

These conditions should **NOT** cause panics:

- **Key not found**: Normal case for delete/get
- **Duplicate key**: Normal case for put (if disallowed, return error)
- **Invalid txn_id**: Return error, don't panic
- **Empty tree**: Valid state, operations handle gracefully
- **Transaction already committed**: Return error, don't panic

---

### Reproducible Test Cases

When fuzzer finds a crash, it should provide:
1. **Minimal input**: Smallest byte sequence that triggers crash
2. **Stack trace**: Crash location and call stack
3. **Diagnostic info**: State at crash time (if available)

To enable reproducibility:
- Make harness deterministic (no randomness, no timing dependencies)
- Log operations before executing (for debugging)
- Serialize state at crash (for post-mortem analysis)

---

## Coverage Guidance

### Code Coverage Goals

Aim for high coverage in critical areas:

#### B+Tree Operations (Target: >95%)
- All node types (internal, leaf)
- All operations (insert, delete, lookup, update)
- All edge cases (empty, single node, overflow, underflow)

#### Transaction Management (Target: >90%)
- All transaction types (read, write)
- All lifecycle states (active, committed, aborted)
- All error paths (already committed, invalid txn_id)

#### Iteration (Target: >90%)
- Forward, reverse, range iteration
- Empty tree, single element, many elements
- Iterator exhaustion

### Coverage-Guided Fuzzing

Use coverage feedback to prioritize inputs:

#### 1. Instrumentation
- Compile with coverage instrumentation (rustc -C instrument-coverage)
- Record which code paths execute for each input

#### 2. Coverage Metrics
- **Edge coverage**: Number of unique branches taken
- **Basic block coverage**: Number of basic blocks executed
- **Line coverage**: Percentage of lines executed

#### 3. Input Prioritization
- Prefer inputs that increase coverage
- Keep inputs that reach new code paths
- Mutate high-coverage inputs to find variants

### Edge Case Targets

Actively target these edge cases:

#### 1. Empty Tree
- First insert into empty tree
- Delete from empty tree (shouldn't crash)
- Iterate empty tree

#### 2. Single Node
- Insert until node overflows
- Delete until node underflows
- All operations on single-element tree

#### 3. Overflow/Underflow
- Insert to trigger split
- Delete to trigger merge
- Cascading splits/merges (multiple levels)

#### 4. Boundary Keys
- Minimum key length (0 bytes)
- Maximum key length (4096 bytes)
- Keys with special bytes (null, 0xFF)

#### 5. Transaction Boundaries
- Commit with no writes
- Commit after abort (should fail gracefully)
- Use transaction after commit (should fail gracefully)

---

## Rust Implementation Guidance

### Module Structure

Fuzz testing should be organized as:

```
ref_model/
├── fuzz/
│   ├── mod.rs              # Fuzz harness public API
│   ├── harness.rs          # Main fuzz_target function
│   ├── operations.rs       # Operation definitions and parsing
│   ├── invariants.rs       # Invariant checking functions
│   └── README.md           # Instructions for running fuzzer
└── tests/
    └── fuzz/
        ├── main.rs         # Fuzz driver entry point
        └── corpus/         # Seed inputs for fuzzing
```

### Type Definitions

#### Operation Enum

```rust
pub enum Operation {
    Put { key: Vec<u8>, value: Vec<u8> },
    Delete { key: Vec<u8> },
    Get { key: Vec<u8> },
    Commit,
    Abort,
    BeginRead { txn_id: u64 },
    BeginWrite,
    Iter { count: u16 },
    Scan { start: Vec<u8>, end: Vec<u8> },
    Noop,
}
```

**Benefits**:
- Type-safe operation representation
- Exhaustive pattern matching
- Clear operation semantics

### Fuzzing Frameworks

#### Recommended: libFuzzer with Rust Bindings

```rust
// In fuzz/fuzz_target.rs

#![no_main]

use libfuzzer_sys::fuzz_target;
use ref_model::fuzz::execute_fuzz_input;

fuzz_target(|data: &[u8]| {
    execute_fuzz_input(data);
});
```

**Benefits**:
- Industry-standard fuzzer
- Coverage-guided
- Fast execution
- Good crash minimization

#### Alternative: cargo-fuzz

```bash
cargo install cargo-fuzz
cargo fuzz init
cargo fuzz add fuzz_target
cargo fuzz run fuzz_target
```

**Benefits**:
- Integrated with Cargo
- Easy to use
- Good documentation

#### Alternative: AFL (American Fuzzy Lop)

```bash
cargo-afl -- cargo fuzz run fuzz_target
```

**Benefits**:
- Mature, battle-tested
- Good at finding deep bugs
- Works with compiled languages

### Concurrency

#### Fuzz Harness is Single-Threaded

```rust
fn execute_fuzz_input(input: &[u8]) {
    let mut model = RefModel::new();
    // Single-threaded execution
    // No concurrency concerns
}
```

**Benefits**:
- Deterministic execution
- Easier debugging
- Simpler crash analysis

### Key Decisions

#### Panic vs Return Error
**Decision**: Panic on invariant violations

**Reason**:
- Fuzzer catches panics as crashes
- Clear signal that bug was found
- Forces immediate investigation
- Errors are for expected failures (invalid input)

#### Input Size Limits
**Decision**: Limit input to 1MB

**Reason**:
- Prevent excessive memory usage
- Fuzzer more effective with smaller inputs
- Most bugs found with short sequences
- Can adjust if needed

#### Seed Corpus
**Decision**: Create seed corpus with valid operation sequences

**Reason**:
- Fuzzer starts from valid inputs
- Faster coverage of interesting code paths
- Includes typical usage patterns
- Mutations produce more valid inputs

### Implementation Notes

#### Step 1: Define Operation Format
Define opcodes and encoding:
- Create Operation enum
- Implement parse_operation
- Implement size calculation

#### Step 2: Implement Fuzz Harness
Create execute_fuzz_input:
- Parse byte stream
- Execute operations sequentially
- Manage active transaction state
- Return or panic on errors

#### Step 3: Add Invariant Checking
Implement check_*_invariants:
- check_btree_invariants
- check_snapshot_invariants
- check_model_invariants
- Call after each operation

#### Step 4: Integrate with Fuzzer
Set up fuzz target:
- Use libfuzzer-sys or cargo-fuzz
- Create fuzz_target function
- Add to build configuration

#### Step 5: Build Seed Corpus
Create initial inputs:
- Empty sequence
- Single operations of each type
- Typical usage patterns
- Edge cases (empty tree, overflow, etc.)

### Testing Strategy

#### Before Fuzzing

**Unit Tests**:
- Verify harness parses valid inputs correctly
- Verify harness rejects invalid opcodes
- Verify invariants catch violations

**Smoke Tests**:
- Run harness with empty input
- Run harness with simple valid sequence
- Verify no crashes on known-good inputs

#### During Fuzzing

**Monitor**:
- Crash rate (should decrease over time)
- Coverage increase (should plateau)
- Execution speed (iterations per second)

**Adjust**:
- Add seed inputs if coverage low
- Adjust timeouts if too slow
- Tune input size limits

#### After Fuzzing

**Analyze Crashes**:
- Reproduce each crash locally
- Minimize crashing input
- Fix root cause
- Add regression test

**Verify Fixes**:
- Re-run fuzzer with fix
- Verify crash no longer occurs
- Check for new crashes

---

## Summary

Fuzz integration provides:

- **Automated bug finding**: Randomized testing finds edge cases
- **Invariant validation**: Comprehensive checking after each operation
- **Crash detection**: Panics indicate bugs
- **Coverage guidance**: Prioritize inputs that explore new code paths
- **Reproducibility**: Minimized test cases for each crash

By integrating the reference model with a coverage-guided fuzzer, we can find deep bugs that manual testing would miss, ensuring the reference model is truly a **correctness oracle**.
