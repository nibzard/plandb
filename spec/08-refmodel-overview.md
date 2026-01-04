# Reference Model Overview

**Phase**: 8
**Task**: 8.1
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [Purpose & Role](#purpose--role)
3. [Design Philosophy](#design-philosophy)
4. [Architecture Overview](#architecture-overview)
5. [Key Concepts](#key-concepts)
6. [Integration with Testing](#integration-with-testing)
7. [Comparison to Production Implementation](#comparison-to-production-implementation)
8. [Module Structure](#module-structure)
9. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

The Reference Model is a simplified, pure in-memory implementation of NorthstarDB's core data structures and operations. It serves as an **oracle of correctness** - a trusted implementation against which the production database is continuously tested.

### Core Principle

> **The reference model defines truth. Any divergence between the reference model and production implementation indicates a bug in production.**

The reference model prioritizes **correctness and clarity** over performance. It uses straightforward algorithms, simple data structures, and exhaustive validation to establish the expected behavior of all database operations.

---

## Purpose & Role

### Primary Use Cases

#### 1. Property-Based Testing
Generate random sequences of operations (puts, deletes, scans, commits) and verify that the production database produces identical results to the reference model.

#### 2. Equivalence Checking
After crash recovery, replay, or serialization, verify that the production database state matches the reference model's state at the same logical point in time.

#### 3. Edge Case Exploration
Test corner cases, boundary conditions, and rare operation sequences that might be missed by manual testing.

#### 4. Regression Prevention
Establish a baseline of correct behavior that must be maintained as the production implementation evolves.

#### 5. Semantic Documentation
The reference model serves as executable documentation of what the database **should** do, making the intended behavior explicit and testable.

### Non-Goals

- Performance optimization (production is faster)
- Efficient memory usage (reference model copies freely)
- Concurrency control (single-threaded, sequential operations)
- Disk persistence (in-memory only, with optional serialization for testing)

---

## Design Philosophy

### Core Principles

#### 1. Simplicity Over Performance
- Use standard library data structures (HashMap, BTreeMap, Vec)
- Prefer clear, obvious algorithms over optimized ones
- Avoid caching, batching, or lazy evaluation
- Copy data rather than managing shared references

#### 2. Explicit State
- All state is directly observable and inspectable
- No hidden invariants or implicit optimizations
- Every operation's effect is immediately visible in state
- Deterministic execution with no non-deterministic choices

#### 3. Comprehensive Validation
- Check all preconditions, postconditions, and invariants
- Validate all inputs explicitly
- Return detailed errors for all failure modes
- Enable exhaustive logging for debugging

#### 4. Independence
- No dependencies on production code
- Self-contained implementation
- Can be understood and maintained separately
- Serves as a clean-room specification

### Design Tradeoffs

| Decision | Rationale |
|----------|-----------|
| **In-memory B+Tree** | Simpler than disk-based structure; sufficient for testing logical correctness |
| **Full state snapshots** | Naive copying is fine for test workloads; easier to reason about than structural sharing |
| **Sequential operations** | No concurrency concerns; deterministic results; easier debugging |
| **Standard collections** | Well-tested, familiar, sufficient for correctness checking |
| **Explicit error handling** | All error paths tested; production must handle same cases |

---

## Architecture Overview

### High-Level Structure

The reference model consists of three main layers:

#### 1. Core Data Layer
- **B+Tree**: In-memory ordered map implementation
- **Snapshot State**: Complete key-value mapping at a point in time
- **Transaction Log**: Ordered sequence of committed operations

#### 2. Transaction Layer
- **Read Transaction**: Immutable view of a snapshot
- **Write Transaction**: Staged modifications buffer
- **Commit Processing**: Atomic application of writes to new snapshot

#### 3. Validation Layer
- **Equivalence Checker**: Compare two states for equality
- **Serializer**: Export state for comparison
- **Fuzz Integration**: Property test harness integration

### Component Relationships

```
┌─────────────────────────────────────────┐
│         Validation Layer                │
│  ┌──────────┐  ┌──────────┐  ┌───────┐ │
│  │ Equiv    │  │ Serialize│  │  Fuzz │ │
│  │ Checker  │  │          │  │  Harness│ │
│  └──────────┘  └──────────┘  └───────┘ │
└────────────┬────────────────────────────┘
             │
┌────────────┴────────────────────────────┐
│         Transaction Layer               │
│  ┌──────────┐  ┌──────────┐  ┌───────┐ │
│  │ Read     │  │ Write    │  │Commit │ │
│  │ Txn      │  │ Txn      │  │Logic  │ │
│  └──────────┘  └──────────┘  └───────┘ │
└────────────┬────────────────────────────┘
             │
┌────────────┴────────────────────────────┐
│         Core Data Layer                 │
│  ┌──────────┐  ┌──────────┐  ┌───────┐ │
│  │ B+Tree   │  │ Snapshot │  │  Log  │ │
│  │          │  │  State   │  │       │ │
│  └──────────┘  └──────────┘  └───────┘ │
└─────────────────────────────────────────┘
```

---

## Key Concepts

### 1. Snapshot State
A **snapshot state** represents the complete database state at a specific point in time:
- A mapping from keys to values
- All keys are ordered
- Each key maps to either a value or is deleted (tombstone)
- Snapshots are immutable once created
- Each successful commit creates a new snapshot

### 2. Transaction ID (TxnId)
A **TxnId** is a monotonically increasing integer that:
- Uniquely identifies a committed transaction
- Orders transactions in time
- Maps directly to a snapshot state
- Starts at 1 (transaction 0 is the empty initial state)

### 3. B+Tree Structure
The reference model uses a simplified B+Tree:
- Variable fanout (2-4 children for simplicity in testing)
- Internal nodes store separator keys
- Leaf nodes store key-value pairs
- All leaves at same depth
- No disk I/O, no page management
- In-memory node allocation

### 4. Operation Sequences
The reference model processes operations sequentially:
- Read operations observe current snapshot state
- Write operations stage changes in a buffer
- Commit atomically applies all staged changes
- Abort discards staged changes without effect

### 5. Determinism
Given an identical sequence of operations:
- The reference model always produces the same final state
- All intermediate snapshots are identical
- All error conditions are identical
- No non-deterministic choices (no concurrency, no I/O timing)

---

## Integration with Testing

### Property-Based Testing Workflow

#### 1. Test Generation
- Generate random operation sequences (puts, deletes, scans)
- Generate random keys and values
- Generate random commit/abort decisions
- Generate random time-travel queries

#### 2. Parallel Execution
- Execute operations on reference model
- Execute identical operations on production database
- Capture all return values and errors

#### 3. Equivalence Verification
- Compare final states for equality
- Compare all intermediate snapshots
- Compare all return values and errors
- Any difference is a test failure

### Fuzz Testing Integration

#### 1. Fuzz Input Format
- Byte sequence encoding of operations
- Operation type (put/delete/scan/commit/abort)
- Key length and bytes
- Value length and bytes

#### 2. Fuzz Harness
- Deserialize operations from fuzz input
- Execute on reference model only (fast execution)
- Check all invariants and error conditions
- Panic on any invariant violation

#### 3. Coverage Guidance
- Focus on edge cases (empty tree, single node, overflow)
- Test boundary conditions (max key size, tree height limits)
- Exercise all error paths (key not found, duplicate key)

---

## Comparison to Production Implementation

### Similarities (What Must Match)

| Aspect | Reference Model | Production |
|--------|----------------|------------|
| **API Surface** | Identical | Identical |
| **Key Ordering** | Bytes comparison | Bytes comparison |
| **Operation Semantics** | Put/delete/scan behave identically | Put/delete/scan behave identically |
| **Transaction Isolation** | Snapshot isolation | Snapshot isolation |
| **Error Conditions** | Same errors for same inputs | Same errors for same inputs |
| **State Transitions** | Same state changes for same ops | Same state changes for same ops |

### Differences (Intentional)

| Aspect | Reference Model | Production | Reason |
|--------|----------------|------------|--------|
| **Performance** | Slow (naive algorithms) | Fast (optimized) | Correctness vs performance |
| **Memory** | High (full copies) | Low (structural sharing) | Simplicity vs efficiency |
| **Concurrency** | None (sequential) | MVCC (concurrent readers) | Determinism vs scalability |
| **Persistence** | Optional (for testing) | Full (crash recovery) | In-memory vs durable |
| **B+Tree Fanout** | Small (2-4) | Large (50-200) | Testable vs efficient |
| **Disk I/O** | None | Pager system | Logic vs implementation |

### What Production Must Match

Production implementation is considered correct **if and only if**:
- All operations return identical values to reference model
- All error conditions match reference model
- Final database state matches reference model state
- All historical snapshots match reference model snapshots
- All committed operations are durable after recovery

---

## Module Structure

### Rust Module Organization

The reference model should be organized as follows:

```
ref_model/
├── mod.rs                 # Public API exports
├── btree/
│   ├── mod.rs            # B+Tree public interface
│   ├── node.rs           # Node types (internal/leaf)
│   ├── tree.rs           # Tree structure and operations
│   └── iter.rs           # Forward and reverse iterators
├── snapshot/
│   ├── mod.rs            # Snapshot public interface
│   ├── state.rs          # Snapshot state representation
│   └── history.rs        # Historical snapshot management
├── txn/
│   ├── mod.rs            # Transaction public interface
│   ├── read.rs           # Read transaction implementation
│   ├── write.rs          # Write transaction implementation
│   └── commit.rs         # Commit processing logic
├── validation/
│   ├── mod.rs            # Validation public interface
│   ├── equiv.rs          # Equivalence checking
│   └── serialize.rs      # State serialization
└── fuzz/
    ├── mod.rs            # Fuzz integration
    └── harness.rs        # Fuzz harness implementation
```

### Module Dependencies

```
fuzz/
  └──> validation/
        └──> snapshot/
              └──> txn/
                    └──> btree/
```

Lower-level modules (btree) must not depend on higher-level modules (txn, validation).

---

## Rust Implementation Guidance

### Module Structure

The Rust implementation should be organized as a separate crate (`ref_model`) with clear module boundaries:

- **btree module**: Core ordered map data structure
- **snapshot module**: State representation and history management
- **txn module**: Transaction operations and commit processing
- **validation module**: Equivalence checking and serialization
- **fuzz module**: Property test and fuzz harness integration

### Type Definitions

#### Use Standard Library Types
- **BTreeMap**: For ordered key-value storage in snapshot state
- **HashMap**: For transaction write buffers and metadata
- **Vec**: For ordered sequences and buffers
- **BTreeSet**: For ordered key sets when needed
- **Rc/Arc**: For shared ownership where structural sharing is beneficial

#### Custom Types
- **B+Tree nodes**: Custom enums for Internal vs Leaf nodes
- **Key/Value wrappers**: Newtype patterns for type safety
- **Error types**: Comprehensive enums for all failure modes

### Concurrency

#### Reference Model is Single-Threaded
- No need for Mutex, RwLock, or atomic types
- All operations are sequential and deterministic
- Simplifies reasoning and debugging
- Enables exhaustive testing without race conditions

#### Production Comparison
- Reference model runs in test harness sequentially
- Production runs with concurrent readers
- Equivalence checking accounts for serialization order
- Reference model establishes what the serialized result should be

### Key Decisions

#### B+Tree Implementation: Custom vs BTreeMap
**Decision**: Use custom B+Tree implementation

**Reason**:
- Must match production structure more closely
- Need to test node splitting, merging, and rebalancing
- BTreeMap hides too many implementation details
- Want to expose internal structure for validation

#### Snapshot Storage: Full Copy vs Structural Sharing
**Decision**: Use full copies (naive approach)

**Reason**:
- Simpler implementation and reasoning
- Test workloads are small enough that copying is acceptable
- Makes state comparison trivial (no graph traversal)
- Eliminates complexity of persistent data structures

#### Key/Value Types: Bytes vs Generic
**Decision**: Use concrete byte slice types

**Reason**:
- Production database works with bytes
- No need for generic type parameters in reference model
- Simplifies serialization and comparison
- Directly maps to on-disk format

### Implementation Notes

#### Step 1: Start with B+Tree
Implement the core B+Tree data structure first:
- Node types (Internal, Leaf)
- Basic operations (insert, lookup, delete)
- Tree maintenance (split, merge, rebalance)
- Iteration (forward, reverse, range)

#### Step 2: Add Snapshot Layer
Build state management on top of B+Tree:
- Snapshot state representation
- Historical snapshot storage
- Snapshot creation and cloning
- Time-travel query support

#### Step 3: Implement Transactions
Add transaction operations:
- Read transactions (immutable snapshot handle)
- Write transactions (staged write buffer)
- Commit processing (atomic state transition)
- Abort handling (discard buffer)

#### Step 4: Build Validation
Create equivalence checking infrastructure:
- State serialization (canonical form)
- Equivalence comparison algorithms
- Digest computation (hash of sorted entries)
- Diff generation for debugging

#### Step 5: Integrate Fuzz
Connect to property testing framework:
- Fuzz input parsing
- Operation execution from fuzz data
- Invariant checking and panic on violation
- Coverage reporting and reproduction

### Testing Strategy

#### Unit Tests Needed For
- B+Tree operations (insert, lookup, delete, split, merge)
- Snapshot creation and cloning
- Transaction commit and abort
- Iterator correctness (forward, reverse, range)
- Error handling (all error paths)

#### Property Tests For
- **Tree invariants**: All leaves same depth, keys ordered within nodes, separator keys correct
- **State equivalence**: Same operations produce same state
- **Operation idempotence**: Repeating same operations produces predictable results
- **Snapshot isolation**: Readers see consistent view despite concurrent writes (in production)
- **Replay determinism**: Same operation sequence always produces same final state

#### Integration Scenarios
- **Random operation sequences**: Generate 1000 random operations, verify state consistency
- **Crash recovery**: Serialize state, deserialize, verify equivalence
- **Time-travel queries**: Commit 100 transactions, query random historical snapshots
- **Boundary conditions**: Empty tree, single element, max depth, overflow scenarios

---

## Summary

The Reference Model is a **correctness oracle** for NorthstarDB. It provides:

- **Simplified implementation**: Straightforward algorithms, standard data structures
- **Comprehensive validation**: All operations tested for correctness
- **Deterministic behavior**: Same inputs always produce same outputs
- **Testing foundation**: Property tests, fuzz tests, equivalence checks

By implementing the reference model in Rust with clarity and simplicity, we establish a trusted baseline against which the production Zig implementation is continuously verified. Any divergence indicates a bug in production that must be fixed.

The reference model is not fast, not memory-efficient, and not concurrent - and that's exactly the point. It prioritizes **correctness above all else**, serving as the definition of what the database should do.
