## Reference Model V0 (Correctness Oracle)

This is a pure in-memory model used for:
- property tests
- crash/recovery equivalence checks
- replay determinism checks

The reference model defines the **truth** of V0 semantics.

---

## 1) Model state

- `current_txn_id: u64`
- `history: Map<u64, SnapshotState>`
- `latest: SnapshotState`

Where:
- `SnapshotState` is a mapping `Map<KeyBytes, ValueBytes>`.

In V0, snapshots are full copies in the reference model (not efficient; that's fine).
Alternatively, use persistent map/structural sharing in tests if needed.

---

## 2) Operations

### 2.1 begin_read(latest)
Returns a handle to `history[current_txn_id]`.

### 2.2 begin_read(txn_id)
Returns handle to `history[txn_id]` if present else `SnapshotNotFound`.

### 2.3 begin_write()
Returns a staged diff structure:
- `writes: Map<KeyBytes, Optional<ValueBytes>>`
  - Put => Some(value)
  - Del => None

### 2.4 commit()
Applies staged writes to a new snapshot:
1. `new_state = copy(history[current_txn_id])`
2. apply each staged op in order
3. `current_txn_id += 1`
4. `history[current_txn_id] = new_state`
5. return `current_txn_id`

### 2.5 abort()
Discards staged writes; no state changes.

---

## 3) Determinism checks

Given a sequence of transactions (each a sequence of ops), the model produces:
- deterministic snapshots per TxnId
- a deterministic digest per snapshot (e.g. sorted hash of all key/value pairs)

DB under test must match the digest of the model for all tested TxnIds.

---

## 4) Crash equivalence

Crash harness should treat the database state after recovery as matching:
- exactly `history[k]` for some `k <= last_successfully_committed_txn_id_observed`

That is, recovered state must match a **prefix** of commits.

---

## 5) Required property tests

- random sequences of `put/del/commit/abort`, compare to DB
- random time-travel queries after each commit
- random range scans, compare sorted outputs
- replay model:
  - encode commit records from DB
  - replay into empty model
  - compare digests at each TxnId