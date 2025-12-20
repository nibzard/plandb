## Pager V0: Commit Protocol, IO Rules, and Free Space Policy

This document defines the pager behavior for NorthstarDB V0.

Goals:
- fixed-size pages with checksums
- crash-safe commits with atomic root publication
- deterministic recovery that selects last committed root
- page allocation and free space management

---

## 1) Page lifecycle

### 1.1 Immutability rule (COW)
Once a page is reachable from a committed root, it is **immutable**.
Writers never update a committed page in place.

Instead, writers:
- allocate new pages
- write new page contents
- update parent pointers by writing new parent pages, etc.
- finally publish a new root pointer in meta

This rule is the foundation of snapshot reads.

### 1.2 Temporary pages
Pages allocated during an uncommitted transaction are temporary.
If the process crashes, temporary pages may leak but must not affect correctness.

V0 may reclaim leaked pages via:
- rebuild freelist from committed graph at open, OR
- persistent freelist updates included in commit

V0 recommendation:
- Start with **rebuild freelist at open** for simplicity, then optimize once benchmarks demand it.

---

## 2) Commit protocol (V0 embedded)

A commit must either:
- appear fully after crash, or
- not appear at all

The protocol is:

1. Writer allocates and writes all new pages for updated tree
2. Writer ensures page checksums are written and valid
3. Writer writes commit log record (if used) and fsyncs it (see commit_record_v0)
4. Writer writes the chosen meta page (toggle A/B) with:
   - new `committed_txn_id`
   - new `root_page_id`
   - freelist pointer (if persisted)
   - `log_tail_lsn`
   - meta checksum
5. Writer fsyncs the DB file
6. Commit returns success

Meta write must be the last durable step.

---

## 3) Recovery algorithm

On open:
1. Read Meta A and Meta B
2. Validate each:
   - correct magic/version
   - checksum valid
   - internal consistency (page_size, etc.)
3. Choose meta with highest `committed_txn_id`
4. Set active root to `root_page_id`
5. Initialize pager cache and freelist:
   - if rebuild policy: traverse committed tree and mark pages in use
   - compute free pages as complement
6. Return DB ready

If neither meta page is valid => fail `Corrupt`.

---

## 4) Page cache rules (V0)

V0 may implement a simple page cache:
- bounded size
- keyed by PageId
- stores decoded header + payload pointer

Rules:
- cache must not return stale data (pages are immutable once committed, so this is easy)
- writer may hold private pages not visible to readers until commit
- cache eviction must not break readers (pinning, refcounts, or epoch scheme)

---

## 5) IO fault handling

Any IO error:
- aborts the current operation
- must not publish a new meta root
- returns explicit error

Out-of-space:
- commit fails
- must not publish new root
- temporary pages may leak; rebuild policy may reclaim later

Checksum mismatch on data page read:
- return `Corrupt`
- do not crash
- allow user to run diagnostic tooling later

---

## 6) Required tests

Unit:
- `pager_meta_toggle_commits_monotonic`
- `pager_recovery_selects_latest_valid_meta`
- `pager_no_partial_commit_visible_on_failed_fsync`

Hardening:
- kill during commit, reopen => state matches prefix of commits
- torn meta write => select the other meta or fail cleanly
- torn data page => detected by checksum