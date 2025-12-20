## Semantics V0: Embedded MVCC, Single Writer, Many Readers

This document defines the **observable behavior** of NorthstarDB V0.
Everything in the implementation must be testable against this spec.

V0 scope:
- Embedded database (single process, single file)
- Many concurrent readers, **single writer**
- MVCC snapshots: readers never block
- Copy-on-write (COW) updates: writer creates a new root per commit
- Crash safety via atomic meta page switch
- Canonical commit record emitted per successful commit (local-only in V0)

Non-goals:
- Multi-writer concurrency
- Distributed replication/consensus
- Full SQL semantics (V0 is an ordered KV store)

---

## 1) Definitions

### 1.1 Data Model
V0 exposes an **ordered key/value store**:
- `Key`: arbitrary bytes, compared lexicographically
- `Value`: arbitrary bytes (can be empty)
- Keys are unique within a snapshot.

### 1.2 Transaction IDs
- `TxnId` is a monotonically increasing unsigned integer.
- `TxnId = 0` denotes the empty genesis state (new DB file).

### 1.3 Snapshots
A snapshot is a read-only view associated with:
- `snapshot.txn_id`: the TxnId visible to this snapshot
- `snapshot.root`: a pointer to the B+tree root for that TxnId

Snapshots are immutable: once opened, a snapshot never changes.

### 1.4 Commit Stream Record
Each successful writer commit must emit a canonical record `CommitRecord` describing the commit:
- It must be sufficient to deterministically reproduce the committed state when applied in order.
- In V0 the record is persisted locally (e.g., an append-only file segment or reserved region).

The commit stream is the seam that becomes replication later.

---

## 2) Public Operations

### 2.1 Open / Close
`open(path, options)`:
- If file does not exist, creates a new DB with a valid genesis meta state.
- If file exists, recovers to the latest valid committed state per meta pages.
- If corruption is detected in recovery, `open` fails with explicit error (`Corrupt`, `UnsupportedFormat`, etc.), never undefined behavior.

`close()`:
- Releases resources; must not implicitly commit.

### 2.2 Read Transactions
`begin_read(snapshot = latest | txn_id)` returns `ReadTxn`:

- `latest`: snapshot at the most recent committed TxnId.
- `txn_id`: snapshot at exactly that TxnId if available; otherwise error `SnapshotNotFound` (policy: we can support gaps later; V0 is strict).

ReadTxn operations:
- `get(key) -> ?value`
- `scan(range) -> iterator` (stable under snapshot)

ReadTxn must be:
- lock-free with respect to other readers
- not blocked by writer except for minimal metadata access (implementation detail), but semantically it must behave as if instantaneous at begin.

### 2.3 Write Transactions
`begin_write()` returns `WriteTxn`.

V0 rule: at most one `WriteTxn` may be active at a time.
- If a write txn already exists, `begin_write()` returns `WriteBusy` (or blocks if configured; V0 default should be explicit error to keep behavior simple and testable).

WriteTxn operations:
- `put(key, value)`
- `del(key)`
- `commit() -> TxnId`
- `abort()`

Semantics:
- Writes are isolated from readers until commit.
- A commit publishes a new TxnId with a new root.

---

## 3) Isolation Level

V0 provides **snapshot isolation for reads** with a single writer.

Because only one writer exists at a time, classic write-write conflicts do not occur in V0, but the semantics should still be defined in a way that naturally extends.

### 3.1 Read Rules
- A ReadTxn observes the exact committed state as of `snapshot.txn_id`.
- It must not see partial effects of a concurrent write txn.
- It must not be affected by later commits after it begins.

### 3.2 Write Rules
- Within a write txn, reads (if supported internally) should observe the txn's own writes (read-your-writes).
- A commit publishes all writes atomically.

### 3.3 Phantom and Range Semantics
- Range scans in a snapshot see a stable set of keys for that snapshot.
- No phantoms can appear within a single ReadTxn because the snapshot is immutable.

---

## 4) Atomicity and Durability

### 4.1 Atomicity
A successful commit has all-or-nothing visibility:
- After commit returns success, any subsequent `begin_read(latest)` must include the committed changes.
- If commit fails, none of its changes are visible.

### 4.2 Durability (Embedded V0)
When `commit()` returns success, the committed TxnId must survive process crash and OS reboot, assuming the underlying filesystem honors `fsync` semantics.

Durability contract is satisfied by:
- writing all new pages
- writing the new meta page (A or B) that points to the new root and includes checksum
- calling `fsync` (or equivalent) on the database file (and any commit stream file, if separate), in the correct order

V0 does not claim durability if the OS lies about fsync or storage is faulty; those are out of scope.

---

## 5) Time Travel

### 5.1 Snapshot by TxnId
`begin_read(txn_id)` must return the state exactly as of that TxnId.

How it is implemented is not mandated by semantics, but V0 expects:
- meta pages track the latest TxnId
- a mapping from TxnId -> root pointer exists (can be a meta history, a side index, or derived from commit stream)
- if history is limited, it must fail explicitly once history is truncated

### 5.2 Deterministic Replay
Given:
- an initial genesis state, and
- a sequence of `CommitRecord`s in order,
replaying them must yield the same final state as the DB reports at the corresponding TxnIds.

This is the core determinism invariant needed for agent replay/debugging later.

---

## 6) Error Model

Errors are part of the spec. They must be stable and testable.

Recommended error set (not exhaustive):
- `WriteBusy` (another writer active)
- `SnapshotNotFound` (requested txn not available)
- `Corrupt` (checksum failure, invalid structure)
- `IoError` (read/write/fsync failures)
- `OutOfSpace`
- `UnsupportedFormat`
- `InvalidArgument`

Rules:
- Corruption must never cause crashes or UB.
- Errors must not leave DB in a partially committed visible state.

---

## 7) Validation and Invariants

### 7.1 Meta Invariants
- TxnId monotonic increasing by 1 (or strictly increasing; choose one and enforce)
- Meta page checksum must validate before being used
- Exactly one meta page is chosen as the latest valid commit at open:
  - If both valid, pick the higher TxnId
  - If neither valid, fail `Corrupt`

### 7.2 B+tree Invariants
(Implementation-specific but validator must enforce)
- Keys sorted in each node
- Correct separators and child ranges
- Balanced depth across leaves (B+tree property)
- No dangling PageIds
- Node checksums valid

### 7.3 Commit Record Invariants
- `CommitRecord` decode/encode round-trips
- Commit record references must be internally consistent (counts, lengths)
- Records are applied strictly in TxnId order

---

## 8) Required Tests (Mapping)

These are the minimum required tests for semantics V0:

### Unit tests
- `txn_atomicity_visible_after_commit`
- `txn_abort_invisible`
- `snapshot_immutable_under_concurrent_writer`
- `range_scan_stable_in_snapshot`
- `meta_recovery_picks_latest_valid`

### Property tests (reference model)
- Random sequences of put/del/commit/abort compared to in-memory reference
- Random time-travel queries compared to reference snapshots

### Crash tests (subprocess kill)
- Kill at random points during write txn and during commit
- After reopen, state equals a prefix of committed txns
- No silent corruption

---

## 9) Notes on Extension (Future Compatibility)

This spec intentionally aligns with future upgrades:
- Multi-writer: add conflict checks (write-write conflicts) without changing reader semantics.
- Distributed log: commit stream becomes the durability boundary; meta root becomes materialized state pointer.
- Cartridges: derived artifacts subscribe to commit stream; semantics remain unchanged.