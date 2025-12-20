## File Format V0: Single-File Embedded Store

This document specifies the on-disk format for NorthstarDB V0.

Goals:
- Crash-safe commits using atomic meta page switch
- Fast open: find latest valid root quickly
- Explicit corruption detection (checksums)
- Versioned format for compatibility

Non-goals:
- Cross-version schema migrations beyond metadata
- Multi-file sharding (V0 uses one file)

---

## 1) High-level layout

A V0 database file is a sequence of fixed-size pages.

- `page_size`: 16,384 bytes (16KB) default in V0
- Page IDs are 64-bit (though V0 may store within 32-bit range)

### Reserved pages
- Page 0: **Meta A**
- Page 1: **Meta B**
- Page 2..N: allocated for btree nodes, freelist structures, commit stream region (optional), etc.

V0 chooses between Meta A and Meta B at open.

---

## 2) Page header

Each page begins with a header. All multi-byte fields are little-endian.

Recommended header (example; keep stable once implemented):

- `magic` (u32): `0x4E534442`  // "NSDB"
- `format_version` (u16): `0`
- `page_type` (u8): enum
  - 0 = meta
  - 1 = btree_internal
  - 2 = btree_leaf
  - 3 = freelist
  - 4 = log_segment (optional in V0)
- `flags` (u8)
- `page_id` (u64)
- `txn_id` (u64): TxnId at which this page was written (for debugging/validation)
- `payload_len` (u32): bytes used after header
- `header_crc32c` (u32): checksum of header fields (excluding this checksum)
- `page_crc32c` (u32): checksum of entire page with this field zeroed (or checksum over payload; pick one and document)

The remainder is payload bytes.

Rules:
- `payload_len` must be <= (page_size - header_size)
- Checksums must validate before trusting any contents.

---

## 3) Meta page layout (Meta A / Meta B)

Meta pages store the durable commit point.

Meta payload fields (recommended):
- `meta_magic` (u32): `0x4D455441` // "META"
- `format_version` (u16): `0`
- `page_size` (u16): 16384
- `committed_txn_id` (u64)
- `root_page_id` (u64)  // 0 means empty tree
- `freelist_head_page_id` (u64) // 0 if none
- `log_tail_lsn` (u64) // last durable commit record position (if log separate/embedded)
- `meta_crc32c` (u32) // checksum of meta payload (excluding this checksum)

Commit protocol must ensure:
1. Write all newly allocated pages for the transaction
2. Ensure commit record (if any) is durable (if it's part of durability in V0)
3. Write the chosen meta page (toggle A/B) with new `committed_txn_id` and `root_page_id`
4. `fsync` database file (and commit record file if separate) such that the new meta becomes durable

Open protocol:
- Read Meta A and Meta B
- Validate checksums + internal consistency
- Choose the valid meta with the highest `committed_txn_id`
- If neither valid => `Corrupt`

---

## 4) B+tree node pages

V0 uses a B+tree (or B+tree-like) structure stored in pages.

### 4.1 Common node payload fields
- `node_magic` (u32): `0x42545245` // "BTRE"
- `level` (u16): 0 for leaf, >0 for internal
- `key_count` (u16)
- `right_sibling` (u64): PageId of right sibling (0 if none). Optional but recommended to support future B-link style concurrency.
- `reserved`…

### 4.2 Leaf node payload
Leaf stores sorted keys and associated values (or value references).
Two common encodings:
- **Slotted page**: offset table + variable-length key/value in payload area
- **Prefix compression**: for keys, optional later

V0 recommendation (simpler, robust):
- Slotted page with:
  - fixed header
  - `slot[i]` = offset to entry
  - entry = `key_len (u16)`, `val_len (u32)`, key bytes, value bytes

Rules:
- Keys must be strictly increasing within leaf
- Leaf capacity constraints must be enforced
- For range scans, leaf may optionally include `next_leaf` pointer (can reuse `right_sibling`)

### 4.3 Internal node payload
Internal stores separator keys and child pointers:
- `child_count = key_count + 1`
- entries:
  - `child_page_id` array
  - separator keys array or slotted encoding
Rules:
- separators define non-overlapping ranges
- child pointers must be valid PageIds
- all children at `level-1`

---

## 5) Free list / page allocation

V0 needs a way to allocate new pages and reuse old pages.

Recommended approach:
- A freelist stored as one or more pages (`page_type=freelist`)
- Metadata pointer in meta page: `freelist_head_page_id`

Freelist encoding options:
- linked list of free PageIds (simple)
- bitmap (compact)
- append-only free log (simple, rebuildable)

V0 should prioritize:
- simplicity + correctness + testability

Crash rules:
- Since commits are COW, pages referenced by the committed root are immutable.
- Pages allocated in an uncommitted transaction are not reachable and can be reclaimed on recovery by:
  - rebuilding freelist from committed graph, or
  - persisting freelist updates atomically as part of commit

Pick one policy and document it; V0 can start with rebuild-on-open if acceptable for DB size (benchmarks should tell you when it stops being acceptable).

---

## 6) Commit record storage (V0)

V0 must emit a canonical commit record per commit. Storage options:

### Option A: Separate file `<db>.log`
Pros: simpler append, easier fsync ordering
Cons: two-file management

### Option B: Reserved log pages inside main DB file
Pros: single file
Cons: more complex allocation, potential write contention

Either is acceptable in V0 as long as:
- records are durable at commit success
- replay tools can read records sequentially

At minimum, a commit record includes:
- `txn_id`
- a description sufficient to reconstruct (e.g., list of key mutations) OR a content-addressed root description
- checksum
- length framing (so scanning is robust)

---

## 7) Compatibility and versioning

Format compatibility rules:
- `format_version` is checked at open.
- Unknown newer major version => `UnsupportedFormat`.
- Backward-compatible changes must be accompanied by new validators and golden files.

Golden file tests:
- `hard/format/open_golden_v0` must open and verify known content hash.

---

## 8) Corruption handling policy

- Any checksum failure in meta page => ignore that meta page
- Any checksum failure in referenced data page during operation:
  - return `Corrupt` error
  - do not crash, do not return wrong data
- Provide a diagnostic tool later that can scan and report corrupt pages

---

## 9) Required format tests (Mapping)

Unit tests:
- `format_meta_roundtrip_encode_decode`
- `format_page_checksum_detects_flip`
- `format_open_prefers_highest_valid_meta`
- `format_btree_validator_rejects_unsorted_keys`

Hardening:
- torn-write injection on meta page must not produce a "phantom commit"
- torn-write injection on data page must be detected by checksum