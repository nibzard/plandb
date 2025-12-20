## Commit Record V0 (Local Commit Stream)

This document specifies the **canonical commit record** format emitted by NorthstarDB V0.

The commit record is a foundational seam:
- In V0, it is persisted locally and used for replay/debugging/time-travel tools.
- In later versions, it becomes the replication payload for distributed durability.

Design goals:
- Robust sequential scanning (length framing + checksum)
- Forward compatibility (versioning + reserved fields)
- Deterministic replay (records fully describe state changes in order)
- Efficient encoding (minimal overhead, friendly to streaming)

Non-goals (V0):
- Advanced compression
- Encryption (can be layered later)
- Multi-stream sharding

---

## 1) Terminology

- `TxnId`: monotonically increasing commit number.
- `LSN` (Log Sequence Number): byte offset of a record within the commit log stream.
- `CommitLog`: the append-only byte stream holding records.

---

## 2) Storage options

NorthstarDB supports either:
- **Option A:** separate file `<db_path>.log`
- **Option B:** embedded log region inside the main DB file

V0 recommendation: **Option A** (separate `.log`) to simplify append and fsync ordering.
The rest of this spec is independent of storage choice.

---

## 3) Record framing (binary)

Every record is self-framed so readers can scan forward and resync after corruption.

### 3.1 Overview

+——————+
| RecordHeader      |
+——————+
| Payload bytes     |
+——————+
| RecordTrailer     |
+——————+

- Header includes size, version, txn id, and checksum fields.
- Trailer repeats the size (and optionally checksum) to support reverse scanning and faster resync.

All integers are little-endian.

### 3.2 RecordHeader

Fields:

- `magic` (u32) = `0x4C4F4752`  // ASCII "LOGR"
- `record_version` (u16) = 0
- `record_type` (u16)
  - 0 = `Commit`
  - 1 = `Checkpoint` (optional in V0; reserved)
  - 2 = `CartridgeMeta` (reserved)
- `header_len` (u16)  // bytes of header, allows extension
- `flags` (u16)
  - bit0: payload is compressed (V0: must be 0)
  - bit1: payload contains inline values (V0: 1)
- `txn_id` (u64)  // TxnId of this record
- `prev_lsn` (u64) // LSN of previous record start (0 for first)
- `payload_len` (u32) // number of payload bytes
- `header_crc32c` (u32) // checksum of header fields with this set to 0
- `payload_crc32c` (u32) // checksum of payload bytes

Header size in V0: 4+2+2+2+2+8+8+4+4+4 = 40 bytes.

Rules:
- `magic` must match or reader treats stream as out of sync
- `payload_len` must be within configured max (defense against corruption)
- `header_crc32c` and `payload_crc32c` must validate before applying payload

### 3.3 Payload format: Commit record V0

Payload begins with a commit payload header, then a sequence of operations.

#### CommitPayloadHeader

- `commit_magic` (u32) = `0x434D4954` // "CMIT"
- `txn_id` (u64) // repeated for payload sanity
- `root_page_id` (u64) // new committed root for this txn (may be 0)
- `op_count` (u32) // number of operations
- `reserved` (u32) // must be 0 in V0

#### Operations

Operations are applied in order. V0 uses only `Put` and `Del`.

Each op:

- `op_type` (u8)
  - 0 = `Put`
  - 1 = `Del`
- `op_flags` (u8)  // V0 must be 0
- `key_len` (u16)
- `val_len` (u32)  // only for Put; for Del must be 0
- `key_bytes` (key_len bytes)
- `val_bytes` (val_len bytes) // only for Put

Rules:
- Keys are arbitrary bytes; recommended max key size is configurable (e.g. 4KB)
- Values are arbitrary bytes; recommended max value size is configurable (e.g. 16MB)
- For deterministic replay, op ordering is exactly the writer's logical order
  - Optionally normalize later, but V0 should preserve order for debugging

Notes:
- Storing full key/value mutations in the log may duplicate data relative to COW pages.
- That is acceptable in V0 because the commit stream is for determinism and auditability.
- Future versions can add compression or references (content addressing).

### 3.4 RecordTrailer

- `magic2` (u32) = `0x52474F4C` // "RGOL" (LOGR reversed)
- `total_len` (u32) // header_len + payload_len + trailer_len
- `trailer_crc32c` (u32) // checksum of trailer fields with this set to 0

Trailer size in V0: 12 bytes.

---

## 4) Append rules and durability ordering

To satisfy embedded durability semantics:

### 4.1 Commit ordering (V0, separate .log)
A successful `WriteTxn.commit()` must ensure:

1. Encode commit record bytes
2. Append record to `<db>.log`
3. `fsync(<db>.log)`  (or fdatasync)  **before** publishing new meta root
4. Write all new pages to `<db>` (if not already flushed)
5. Write new meta page (A/B) pointing to `root_page_id` and referencing `log_tail_lsn`
6. `fsync(<db>)`
7. Return success with new `TxnId`

This ensures:
- the log contains the record for any committed TxnId
- meta root never points to a state that lacks a corresponding durable record
- crash recovery can always find a consistent commit point

### 4.2 If log is embedded in main file
If log and pages share a file, ordering still matters:
- log record bytes must be durable before meta root flip
- meta root flip must be the last durable step
Implementation must document exact fsync barriers.

---

## 5) Recovery rules

On `open()`:
1. Select latest valid meta page (A/B) by checksum and highest `committed_txn_id`
2. Read `log_tail_lsn` from meta
3. Optionally verify that commit stream up to `log_tail_lsn` is readable and includes matching `txn_id` and `root_page_id`
4. If mismatch:
   - either treat as corruption (`Corrupt`)
   - or roll back to last consistent point (future enhancement; V0 may keep strict)

---

## 6) Replay rules

Replay engine reads records sequentially and applies operations to a target state.

Determinism requirements:
- Applying Commit records in `txn_id` order yields identical visible state.
- Any decode or checksum failure must abort replay with explicit error.

Replay should support:
- full rebuild to latest
- rebuild to specific `txn_id`
- "explain" mode that prints or hashes applied operations for debugging

---

## 7) Required tests

Unit tests:
- `log_encode_decode_roundtrip`
- `log_scan_forward_multiple_records`
- `log_checksum_detects_corruption`
- `log_replay_matches_reference_model`

Property tests:
- random transaction sequences, encode to log, replay, compare to reference

Hardening:
- kill during append: either record absent or fully valid (no half-visible commit)
- torn-write in log: must be detected; recovery must not accept phantom commit

---

## 8) Extension points

Future versions may add:
- compression (flagged in header)
- encryption
- content-addressed values (op references instead of inline bytes)
- checkpoints (materialization points to speed up replay)
- multiple streams or partitioned logs

Compatibility rule:
- readers must reject unknown major `record_version` with explicit error