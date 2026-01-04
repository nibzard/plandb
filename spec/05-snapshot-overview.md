# Snapshot & MVCC Overview

**Phase**: 5
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [MVCC Design Philosophy](#mvcc-design-philosophy)
3. [Snapshot Purpose & Use Cases](#snapshot-purpose--use-cases)
4. [Architecture](#architecture)
5. [Snapshot Lifecycle](#snapshot-lifecycle)
6. [Integration with Transaction System](#integration-with-transaction-system)
7. [Key Invariants & Guarantees](#key-invariants--guarantees)
8. [Module Structure](#module-structure)
9. [Public API](#public-api)
10. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

NorthstarDB uses Multi-Version Concurrency Control (MVCC) to provide **consistent snapshots** of the database at specific points in time. This enables:

- **Concurrent readers**: Multiple transactions read simultaneously without blocking
- **Time-travel queries**: Query historical states of the database
- **Snapshot isolation**: Each transaction sees a consistent view from its start time
- **Zero-copy reads**: Readers operate on immutable versions

### Core Principle

> **The log is the source of truth. Snapshots are derived, consistent views of that truth at specific LSNs.**

A snapshot captures the database state at a particular **Log Sequence Number (LSN)**, representing the commit order of transactions. Readers operating on a snapshot see exactly the state as of that LSN - no more, no less.

---

## MVCC Design Philosophy

### Goals

1. **Never block readers**: Reads proceed concurrently with writes
2. **Deterministic views**: Same snapshot → same results, always
3. **Bounded memory**: Old versions are reclaimable
4. **Crash consistent**: Snapshots survive restarts via the commit log
5. **Simple API**: One snapshot handle, infinite reads

### Non-Goals

- Write-write concurrency (single writer initially)
- Multi-master replication
- Distributed transactions
- Schema versioning (handled separately)

### Design Tradeoffs

| Decision | Rationale |
|----------|-----------|
| **Snapshot per transaction** | Simpler than per-statement snapshots; aligns with serializable isolation |
| **LSN-based versioning** | Naturally ordered; integrates with commit log; enables time-travel |
| **Immutable versions** | Zero-copy reads; no locking required; safe concurrent access |
| **Eager cleanup** | Reclaim old versions immediately after last reader releases; no background GC needed |

---

## Snapshot Purpose & Use Cases

### Primary Use Cases

#### 1. Transactional Consistency
```rust
let txn = db.begin_write()?;
txn.put("key1", "value1")?;
txn.put("key2", "value2")?;
txn.commit()?;  // All changes atomic at this LSN

// Reader sees either:
// - State before both puts (snapshot < LSN)
// - State after both puts (snapshot ≥ LSN)
// NEVER: key1 updated but key2 not
```

#### 2. Concurrent Readers
```rust
// Reader 1: Long-running analytics
let snap1 = db.snapshot(lsn_1000)?;
let mut iter = snap1.iter();
// ... process millions of records ...

// Reader 2: Real-time queries
let snap2 = db.snapshot(lsn_1050)?;
let value = snap2.get("current_key")?;

// Both readers see consistent views, no blocking
```

#### 3. Time-Travel Queries
```rust
// Query state at specific historical point
let snapshot = db.snapshot_at_time(timestamp)?;
for record in snapshot.iter() {
    println!("{:?}", record);  // Exactly as of that timestamp
}

// Compare two points in time
let snap_before = db.snapshot(lsn_before)?;
let snap_after = db.snapshot(lsn_after)?;
let diff = snap_after.diff(&snap_before)?;
```

#### 4. Backup & Export
```rust
// Consistent backup without blocking writes
let snap = db.snapshot(lsn_latest)?;
let backup_file = File::create("backup.db")?;
snap.export_to(backup_file)?;  // Zero-copy, no writes blocked
```

---

## Architecture

### Three-Layer Design

```
┌─────────────────────────────────────────┐
│         Application Layer               │
│  (ReadTxn, WriteTxn, Db)               │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│         Snapshot Layer                  │
│  - Snapshot creation/management         │
│  - Version resolution                   │
│  - Reader reference counting            │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│         Storage Layer                   │
│  - Pager (page allocation, IO)          │
│  - B+Tree (multi-version storage)       │
│  - Commit Log (LSN ordering)            │
└─────────────────────────────────────────┘
```

### Component Interaction

```
Db::begin_write()
    │
    ├─► Allocate new TxnId
    │
    └─► Create WriteTxn
            │
            ├─► Buffer writes in memory
            │
WriteTxn::commit()
    │
    ├─► Allocate LSN
    │
    ├─► Append to commit log
    │
    └─► Apply to B+Tree as new version
            │
            └─► Mark transaction as committed

Db::snapshot(lsn)
    │
    ├─► Get current LSN if lsn == None
    │
    ├─► Create Snapshot handle
    │
    └─► Track reader reference
```

---

## Snapshot Lifecycle

### Creation

1. **LSN Selection**
   - `db.snapshot()` → Use latest committed LSN
   - `db.snapshot(lsn)` → Use specific historical LSN
   - `db.snapshot_at_time(t)` → Resolve timestamp to LSN via log index

2. **Handle Creation**
   - Allocate `Snapshot` struct with LSN
   - Increment global reader count for this LSN
   - Return handle to caller

### Usage

3. **Read Operations**
   - All reads pass through snapshot
   - Version resolution: find newest version ≤ snapshot LSN
   - Zero-copy: reference pages directly, no copies

4. **Reference Tracking**
   - Each snapshot holds "claim" on LSN
   - B+Tree cannot reclaim versions with active readers
   - Reference count prevents premature cleanup

### Destruction

5. **Snapshot Drop**
   - Decrement reader count for LSN
   - If count reaches zero: signal reclaimable
   - B+Tree can now free old versions

### Lifecycle Diagram

```
CREATE ──► ACTIVE ──► DROPPED
  │           │          │
  │           │          └─► Reclaim versions
  │           │
  │           └─► Reads reference this LSN
  │
  └─► Allocate LSN, increment readers
```

---

## Integration with Transaction System

### WriteTxn Integration

```rust
impl WriteTxn {
    fn commit(mut self) -> Result<Lsn> {
        // 1. Allocate LSN for this transaction
        let lsn = db.log.reserve_lsn()?;

        // 2. Serialize transaction record
        let record = TxnRecord {
            lsn,
            writes: self.buffered_writes,
        };

        // 3. Append to commit log (durable)
        db.log.append(record)?;

        // 4. Apply changes to B+Tree as new version
        for (key, value) in self.buffered_writes {
            tree.insert_version(key, value, lsn)?;
        }

        // 5. Mark committed (visible to snapshots ≥ this LSN)
        self.committed = true;

        Ok(lsn)
    }
}
```

### ReadTxn Integration

```rust
impl ReadTxn {
    fn new(db: &Db, lsn: Lsn) -> Result<Self> {
        // 1. Create snapshot at specified LSN
        let snapshot = db.snapshot(lsn)?;

        // 2. Bind all reads to this snapshot
        Ok(Self {
            snapshot,
            _phantom: PhantomData,
        })
    }

    fn get(&self, key: &[u8]) -> Result<Option<Value>> {
        // Read through snapshot - sees only versions ≤ snapshot LSN
        self.snapshot.get(key)
    }
}
```

### LSN Allocation & Ordering

- **LSN = Log Sequence Number**: Monotonically increasing counter
- **One LSN per committed transaction**: Defines total order
- **Snapshot visibility**: Snapshot at LSN X sees all commits with LSN ≤ X
- **Transaction ID vs LSN**:
  - TxnId: Unique identifier for transaction (may not commit)
  - LSN: Assigned only on commit (defines visibility)

---

## Key Invariants & Guarantees

### Invariants

1. **LSN Monotonicity**: LSNs never decrease; each commit gets strictly greater LSN
2. **Snapshot Immutability**: Once created, snapshot's LSN never changes
3. **Version Ordering**: For any key, versions are strictly ordered by LSN
4. **Visibility Rule**: Snapshot at LSN X sees version V if V.lsn ≤ X and no newer version ≤ X exists
5. **Reference Safety**: Versions cannot be dropped while any snapshot references them

### Guarantees

#### Consistency
- **Snapshot isolation**: Transaction sees consistent database state as of its start LSN
- **No phantom reads**: Range scans return same results on repeated calls
- **Atomic visibility**: All changes from a transaction become visible at exactly one LSN

#### Concurrency
- **Readers never block writers**: Snapshots read old versions; writes create new versions
- **Writers never block readers**: Readers continue on old versions while writer commits
- **Readers never block readers**: Multiple snapshots operate concurrently without coordination

#### Performance
- **Zero-copy reads**: Snapshots reference data in-place; no clones needed
- **Bounded memory**: Old versions reclaimed immediately after last reader drops
- **No read locks**: Absolutely zero synchronization during read operations

#### Durability
- **Crash recovery**: After restart, snapshots can be recreated from commit log
- **Time-travel**: Historical snapshots available as long as versions exist in storage

---

## Module Structure

### Rust Modules

```
src/
├── snapshot/
│   ├── mod.rs              # Public API exports
│   ├── snapshot.rs         # Snapshot struct, lifecycle management
│   ├── version.rs          # Version resolution logic
│   ├── manager.rs          # Snapshot creation, reference counting
│   └── tests.rs            # Unit tests
│
├── txn/
│   ├── mod.rs
│   ├── read.rs             # ReadTxn (uses Snapshot)
│   ├── write.rs            # WriteTxn (commits create new versions)
│   └── id.rs               # TxnId, Lsn types
│
└── storage/
    ├── pager.rs
    ├── tree.rs             # Multi-version B+Tree
    └── log.rs              # Commit log, LSN allocation
```

### Key Data Structures

```rust
/// Snapshot handle - represents database state at specific LSN
pub struct Snapshot {
    lsn: Lsn,
    db: Arc<DbInner>,
}

/// Multi-version value in B+Tree
struct VersionedValue {
    lsn: Lsn,
    value: Vec<u8>,
    older: Option<Box<VersionedValue>>,  // Linked list of versions
}

/// Snapshot manager tracks active readers
struct SnapshotManager {
    readers: BTreeMap<Lsn, AtomicUsize>,  // Reference counts per LSN
}
```

---

## Public API

### Db API

```rust
impl Db {
    /// Create snapshot at latest committed LSN
    pub fn snapshot(&self) -> Result<Snapshot>;

    /// Create snapshot at specific historical LSN
    pub fn snapshot_at_lsn(&self, lsn: Lsn) -> Result<Snapshot>;

    /// Create snapshot closest to given timestamp
    pub fn snapshot_at_time(&self, timestamp: SystemTime) -> Result<Snapshot>;

    /// Get current latest LSN
    pub fn latest_lsn(&self) -> Lsn;
}

impl Clone for Snapshot {
    /// Clone creates new reference to same LSN
    fn clone(&self) -> Self;
}
```

### Snapshot API

```rust
impl Snapshot {
    /// Point lookup - returns value visible to this snapshot
    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>>;

    /// Range scan - returns iterator over snapshot's view
    pub fn iter(&self) -> Result<SnapshotIter>;

    /// Get this snapshot's LSN
    pub fn lsn(&self) -> Lsn;

    /// Check if key exists in this snapshot
    pub fn contains_key(&self, key: &[u8]) -> Result<bool>;
}

impl IntoIterator for Snapshot {
    type IntoIter = SnapshotIter;
}

pub struct SnapshotIter {
    snapshot: Snapshot,
    cursor: TreeCursor,
}
```

### ReadTxn API (reuses Snapshot)

```rust
impl Db {
    /// Begin read transaction at current LSN
    pub fn begin_read(&self) -> Result<ReadTxn>;

    /// Begin read transaction at specific LSN (time-travel)
    pub fn begin_read_at(&self, lsn: Lsn) -> Result<ReadTxn>;
}

impl ReadTxn {
    pub fn get(&self, key: &[u8]) -> Result<Option<Value>>;
    pub fn iter(&self) -> Result<TxnIter>;
    pub fn lsn(&self) -> Lsn;
}
```

---

## Rust Implementation Guidance

### Phase 5 Tasks Breakdown

This overview establishes the foundation. Subsequent tasks will implement:

1. **Task 5.2**: `Snapshot` struct and lifecycle management
2. **Task 5.3**: Version resolution logic (find correct version for LSN)
3. **Task 5.4**: Snapshot manager and reference counting
4. **Task 5.5**: Integration with B+Tree multi-version storage
5. **Task 6.X**: B+Tree implementation details (Phase 6)

### Implementation Priorities

#### High Priority
- **Correct reference counting**: Memory leaks or use-after-free unacceptable
- **LSN allocation**: Must be crash-safe and monotonic
- **Version lookup**: O(log n) or better; no linear scans

#### Medium Priority
- **Time-travel index**: Efficient timestamp → LSN mapping
- **Snapshot cloning**: Cheap handle duplication
- **Iterator invalidation**: Safe concurrent modification

#### Low Priority
- **Snapshot statistics**: Track active snapshots, memory usage
- **Debug visibility**: Inspector tools for internal state
- **Performance tuning**: Cache-friendly layouts, prefetching

### Memory Safety Considerations

```rust
// ✅ SAFE: Snapshot holds Arc, preventing premature cleanup
pub struct Snapshot {
    db: Arc<DbInner>,  // Keeps DB alive
    lsn: Lsn,
}

// ✅ SAFE: Reference counting prevents use-after-free
impl SnapshotManager {
    fn register(&self, lsn: Lsn) {
        self.readers.entry(lsn)
            .or_insert_with(|| AtomicUsize::new(0))
            .fetch_add(1, Ordering::AcqRel);
    }

    fn unregister(&self, lsn: Lsn) {
        let count = self.readers.get(&lsn)
            .unwrap()
            .fetch_sub(1, Ordering::AcqRel);
        if count == 1 {
            // Last reader - signal reclaimable
            self.notify_reclaimable(lsn);
        }
    }
}

// ✅ SAFE: Iterators borrow snapshot, cannot outlive it
pub struct SnapshotIter<'a> {
    snapshot: &'a Snapshot,
    cursor: TreeCursor,
}
```

### Concurrency Strategy

```rust
// Single Writer (Commit Log)
struct CommitLog {
    next_lsn: AtomicU64,  // Single writer, atomic allocation
}

// Multiple Readers (Snapshots)
struct Snapshot {
    lsn: Lsn,  // Immutable after creation
}

// Zero Coordination Required
// - Readers never access next_lsn
// - Writer never touches snapshot state
// - Only synchronization: atomic reference counts
```

### Testing Strategy

See [spec/hardening_v0.md](./hardening_v0.md) for comprehensive test plans:

1. **Unit Tests**: Per-module logic (version resolution, refcounting)
2. **Integration Tests**: End-to-end snapshot workflows
3. **Concurrent Stress**: Many readers + single writer
4. **Crash Recovery**: Kill process mid-commit, verify recovery
5. **Memory Safety**: Valgrind, ASAN, Miri for Rust

---

## Appendix

### Related Specifications

- [04-transaction-system.md](./04-transaction-system.md) - Transaction API that uses snapshots
- [06-btree-overview.md](./06-btree-overview.md) - Multi-version B+Tree storage
- [semantics_v0.md](./semantics_v0.md) - Formal MVCC semantics

### Terminology

| Term | Definition |
|------|------------|
| **LSN** | Log Sequence Number - monotonically increasing, assigned on commit |
| **Snapshot** | Immutable view of database at specific LSN |
| **Version** | Value with associated LSN, stored in B+Tree |
| **TxnId** | Unique transaction identifier (pre-commit) |
| **Visibility** | Whether a version is included in snapshot's view |
| **Reclaim** | Free old versions after all readers release |

### Open Questions

1. **Snapshot time-to-live**: Should old snapshots be auto-expired? (Decision: No, app-controlled)
2. **Version chain length**: Limit historical versions per key? (Decision: Compaction in Phase 6)
3. **LSN overflow**: What happens when u64 LSN wraps? (Decision: 2^64 commits is effectively infinite)

---

**Next**: [Task 5.2 - Snapshot Lifecycle Management](../rust/todo-rust.md#task-52)