# NorthstarDB (working title)

A database built from scratch in **Zig** as a step-by-step educational project — with an explicit constraint:

> **Benchmarks and hardening tests are the source of truth.**

We start with a minimal, real database kernel (pager + B+tree + MVCC snapshots + crash safety). We grow it into a database designed for the next decade: **SSD-first**, **network-aware**, **replayable**, and able to serve **orchestrated AI coding agents** at scale.

This repository is meant to be both:

- a rigorous, learn-by-building database curriculum, and
- the seed of a future database that can replace duct-taped stacks (Redis + Postgres + S3 + vector DB + graph DB + custom glue).

---

## Table of contents

- [Why this exists](#why-this-exists)
- [The north star use case: orchestrated AI coding agents](#the-north-star-use-case-orchestrated-ai-coding-agents)
- [Project principles](#project-principles)
- [Non-goals (for sanity)](#non-goals-for-sanity)
- [Architecture overview](#architecture-overview)
  - [V0: embedded kernel](#v0-embedded-kernel)
  - [V1: time travel + commit stream](#v1-time-travel--commit-stream)
  - [V2: cartridges](#v2-cartridges)
  - [V3: distributed durability](#v3-distributed-durability)
- [Correctness model](#correctness-model)
- [Performance model](#performance-model)
- [Benchmarks: how we measure and gate](#benchmarks-how-we-measure-and-gate)
- [Hardening: how we break it on purpose](#hardening-how-we-break-it-on-purpose)
- [File format and compatibility](#file-format-and-compatibility)
- [Public API direction](#public-api-direction)
- [Repo layout](#repo-layout)
- [Milestones](#milestones)
- [Contributing](#contributing)
- [FAQ](#faq)
- [License](#license)

---

## Why this exists

Databases are often taught as either:

- **theory** (transactions, isolation levels, cost models), or
- **black-box usage** (install Postgres, add an index, tune a setting).

NorthstarDB is about closing the gap: understanding database systems by building them with rigor, and **keeping the project honest** with tests and performance contracts from day one.

The motivation is also practical: modern systems increasingly need database capabilities that are awkward to assemble with existing tools:

- **Massive concurrent reads** with consistent snapshots
- **Deterministic replay** (audit trails, debugging)
- **Time travel** queries
- **Hybrid workloads**: relational-ish + graph + vector
- **Datacenter reality**: durability and failover are distributed properties, not “fsync on one box”

---

## The north star use case: orchestrated AI coding agents

AI coding tools are becoming **orchestrated swarms**:

- 100s of parallel tasks (analyzers, rewriters, validators)
- long-running sessions (hours/days)
- distributed workers (cloud + local, multiple developers)
- huge working sets (entire repos, dependency graphs, embeddings, traces)
- deterministic replay requirements (“why did agent do this two hours ago?”)

This yields a database-shaped requirement list:

1. **Transactional state** (task claim + result update must be atomic)
2. **Temporal queries** (“show me state as of txn 12345”)
3. **Graph-relational hybrid** (code entities + dependency/call edges)
4. **Massive read concurrency** (100s–1000s of readers)
5. **Commit stream** for audit, CDC, replay
6. **Cartridges**: precomputed artifacts for hot query shapes (graph adjacency, HNSW, transitive closure)

NorthstarDB is built so that these use cases drive macrobenchmarks and feature priorities.

---

## Project principles

1. **Benchmarks are law.** We don’t “believe” perf claims; we prove them.
2. **Correctness is continuous.** Property tests and crash tests run from day one.
3. **Make invariants explicit.** Every module has documented invariants and validators.
4. **Pay coordination at commit, not on reads.** Snapshot reads must be cheap and scalable.
5. **State is derived; the log is truth.** The commit stream is the durable narrative; structures are materializations.
6. **Predictability beats cleverness.** Stable p99 is worth more than flashy peak throughput.
7. **No hidden costs.** Track allocations/op, bytes moved, amplification, and fsyncs/txn.
8. **Cartridges turn offline work into online speed.**
9. **Teachability is a feature.** This should be readable and explainable, not magic.
10. **Zig fits the mission.** Explicit memory, explicit errors, explicit performance.

---

## Non-goals (for sanity)

Early versions of NorthstarDB will not try to be everything at once.

V0/V1 non-goals:
- A full SQL engine (we may add a SQL layer later, but it’s not the kernel)
- Distributed consensus in Month 1 (we design the seam, not the full system)
- Multi-writer MVCC with no contention (we start with one writer, many readers)
- “Support every workload” (we pick clear target workloads and measure them)

---

## Architecture overview

### V0: embedded kernel

**Goal:** a minimal embedded database that is already “real” and durable.

Core components:
- **Pager**
  - fixed-size pages (initially 16KB)
  - page allocator/free list
  - checksums per page
  - meta pages A/B holding root pointer + txn id + checksum
- **Copy-on-write B+tree**
  - ordered KV store
  - point get/put/delete
  - range scans
  - validator for structural invariants (sorted keys, fanout, etc.)
- **MVCC snapshots**
  - many concurrent readers: lock-free snapshots
  - one writer: produces new root via COW
- **Crash safety**
  - commit writes new pages, then atomically flips meta root
  - reopen chooses latest valid meta page

This is LMDB-inspired in spirit, but implemented fresh with a future-oriented seam: **every commit emits a canonical record**.

### V1: time travel + commit stream

In V1, the commit stream becomes first-class:

- every transaction produces a **commit record**
- time travel means: `snapshot(txn_id)` is a stable view pointer
- replay tooling can rebuild materializations or reproduce behavior

**Design intent:** time travel is not bolted on with ad-hoc versioning; it is a natural consequence of the MVCC + commit stream design.

### V2: cartridges

A **cartridge** is a versioned artifact derived from the commit stream.

- built offline or in background
- memory-mapped or cached for fast hot queries
- explicitly invalidated/rebuilt when source tables change
- versioned by log position / txn id

Examples:
- `pending_tasks_by_type`: fast task queue selection (<1ms)
- call graph adjacency: `caller -> [callee...]`
- transitive dependency closure
- HNSW vector index for embeddings
- trace/session indexes for UI rendering

Cartridges are how we reach “graph DB speed” and “vector DB speed” without warping the core engine into a specialized snowflake.

### V3: distributed durability

Eventually, the durability boundary moves from local fsync to a replicated log:

- leader commits to distributed log (Raft/Paxos, sequencer + object store, etc.)
- replicas apply log to materialize state
- reads served locally; coordination paid at commit

The kernel is designed so the transition is evolutionary:
- embedded mode: log records exist but are local
- distributed mode: the same log records flow through replication

---

## Correctness model

### Transaction semantics (V0)
- **Atomicity:** a committed transaction is all-or-nothing.
- **Isolation:** snapshot reads see a stable snapshot root.
- **Durability (embedded):** once commit returns success, reopening after crash must show that commit.
- **Visibility:** readers see exactly the snapshot they opened; writers publish only at commit.
- **Determinism:** applying the same commit stream yields identical state.

### MVCC rules (Month 1 shape)
- Readers never block each other.
- One writer at a time (enforced by a write lock).
- Writer commits by producing a new root; readers keep old roots.

### Invariants are validated
Every layer has explicit validators used by tests and debug tooling:
- pager: page headers consistent, checksums valid
- btree: ordering, fanout, balanced depth, pointer sanity
- mvcc: snapshot roots monotonic, commit ids monotonic
- log: decode/encode round-trip, replay determinism

---

## Performance model

We treat performance like a contract, not vibes.

NorthstarDB measures:
- throughput (ops/sec)
- latency percentiles (p50/p95/p99/max)
- bytes read/written
- fsync counts (critical for commit)
- allocation count/bytes
- write amplification
- cache behavior (when available)

We explicitly distinguish:
- **hot path**: data in memory / page cache warm
- **cold path**: data on SSD / OS cache dropped
- **commit path**: includes fsync or durability boundary

---

## Benchmarks: how we measure and gate

NorthstarDB has two benchmark classes:

### 1) Microbenchmarks (CI gatekeepers)

These test “database physics” and run frequently:

Pager:
- open/close cost
- random page reads hot/cold
- write page without sync
- commit meta flip with fsync
- checksum cost

B+tree:
- sequential build
- point get hot/cold
- point updates with different txn batch sizes
- range scans
- deletes

MVCC:
- snapshot open/close
- many-readers scaling
- writer commit latency under read pressure
- conflict check overhead (even if single writer at first)

Log seam:
- commit record encode/decode
- append throughput
- replay throughput

CI gating is regression-based:
- fail if throughput drops >5%
- fail if p99 latency rises >10%
- fail if allocations/op rise >5% (where tracked)
- fail if fsyncs/op increase unexpectedly

Baseline files live in:
- `bench/baselines/ci/*.json`
- `bench/baselines/dev_nvme/*.json` (optional dashboard truth)

See: `spec/benchmarks_v0.md`.

### 2) Macrobenchmarks (scenario truth)

These simulate the real “agent orchestration” workload shapes:

- task queue creation + claims under many “agents”
- code graph ingestion + query mix
- time travel and historical snapshot checks
- cartridge build + serve

Macrobenches are run locally and/or nightly because they’re heavier, but they are what ultimately determines feature priority.

---

## Hardening: how we break it on purpose

A database is correct only if it survives the world: crashes, torn writes, corrupted files, and hostile inputs.

Hardening tests are run nightly (and on demand):

### Crash torture: random kill -9
A harness spawns a subprocess that:
- runs random transactions (seeded)
- is killed at random points (including mid-commit)
- is reopened and verified against a reference model

The correctness oracle is:

> The observed state must match **some prefix of the commit stream**.

### Torn write simulation
Inject partial page writes (first X bytes only), then crash.
Expected:
- checksum detects corruption
- DB recovers to the last valid meta root or fails with explicit corruption error
- never silently returns wrong data

### Short write / ENOSPC simulation
Force writes to fail.
Expected:
- clean error
- no meta flip to an invalid root

### Fuzzing decode paths
Fuzz:
- page decoding
- btree node parsing
- commit record decoding

Expectation:
- never crash
- never OOB
- always return explicit error

### Golden format compatibility
Golden DB files created by earlier commits must remain readable, or migrations must be explicit and tested.

See: `spec/hardening_v0.md`.

---

## File format and compatibility

We version the on-disk format early.

Key ideas:
- a small header and magic/version
- fixed page size (initially 16KB)
- checksum per page
- meta pages A/B:
  - contain root pointer + txn id + checksum + format version
  - commit flips between A/B so recovery can choose the latest valid one

Format docs live in:
- `spec/file_format_v0.md`

Compatibility policy:
- patch/minor versions preserve readability
- major changes require explicit migration tools + new golden files

---

## Public API direction

NorthstarDB begins as an embedded KV store. SQL/relational may be added later, but the kernel must remain useful without it.

### Conceptual API

```text
db = open(path, options)

rtxn = db.begin_read(snapshot = latest | txn_id)
value = rtxn.get(key)
iter = rtxn.scan(range)
rtxn.close()

wtxn = db.begin_write()
wtxn.put(key, value)
wtxn.del(key)
wtxn.commit()   # durable commit + canonical commit record
```

Design constraints implied by the API
	•	Read txns must be cheap to open.
	•	Iterators must be stable under snapshots.
	•	Commit must be atomic and recoverable.
	•	Commit must emit a replayable record even in embedded mode.

⸻

Repo layout

Planned structure:

.
├── src/
│   ├── core/              # PageId, TxnId, Lsn, slices, checksums, stats
│   ├── pager/             # file format, page IO, allocator, cache, meta pages
│   ├── btree/             # nodes, splits/merges, iterators, validation
│   ├── mvcc/              # snapshots, reader txns, writer txn, visibility rules
│   ├── log/               # commit records, encode/decode, replay engine
│   ├── db/                # public API glue
│   └── util/              # deterministic RNG, test helpers, invariants
│
├── bench/
│   ├── run.zig            # benchmark runner: JSON output, filters, repeats
│   ├── compare.zig        # baseline compare + CI gating
│   ├── suites/
│   │   ├── pager.zig
│   │   ├── btree.zig
│   │   ├── mvcc.zig
│   │   └── log.zig
│   └── baselines/
│       ├── ci/
│       └── dev_nvme/
│
├── hard/
│   ├── crash/             # subprocess killer + reopen verification
│   ├── io_faults/         # torn-write, short-write simulators
│   ├── fuzz/              # decode fuzzing + corpus
│   └── format/            # golden files + compatibility tests
│
├── spec/
│   ├── semantics_v0.md    # MVCC + txn semantics, conflict rules
│   ├── file_format_v0.md  # page layout, meta pages, checksums, versioning
│   ├── benchmarks_v0.md   # benchmark names, metrics, thresholds
│   └── hardening_v0.md    # crash/fuzz/fault plans and invariants
│
└── tools/
    ├── gen_synth_repo/    # synthetic dataset generator for macrobenches
    └── replay/            # replay + debugging tools


⸻

Milestones

Milestone 0 — North Star scaffolding
	•	benchmark runner + JSON schema stub
	•	baseline compare + CI gating
	•	reference in-memory model for correctness
	•	crash harness subprocess killer

Definition of done: tests and benches run even with stubbed DB components.

Milestone 1 — Pager
	•	open/create DB
	•	page allocation + free list
	•	checksums
	•	meta pages A/B with atomic root flip
	•	pager microbench suite green

Milestone 2 — B+tree
	•	point get/put/del
	•	range scans
	•	split/merge
	•	structural validator
	•	btree microbench suite green

Milestone 3 — MVCC snapshots
	•	many readers, single writer
	•	snapshot open/close microbench green
	•	writer commit under read load macrobench runs

Milestone 4 — Commit record format + replay
	•	canonical commit record emitted per commit
	•	encode/decode microbench green
	•	replay microbench green
	•	time-travel snapshot open benchmark green

Milestone 5 — First macrobench: agent task queue
	•	task creation + claim pattern
	•	no duplicates under concurrency
	•	crash recovery correctness under workload

Milestone 6 — First cartridge: pending_tasks_by_type
	•	offline build from commit stream
	•	memory-mapped artifact
	•	hot query latency improvements measured

⸻

Contributing

Contributions are welcome, but the workflow is strict:
	•	New feature requires:
	•	tests, and
	•	at least one benchmark that proves it doesn’t regress the system
	•	Hot-path changes require:
	•	benchmark evidence (before/after)
	•	File format changes require:
	•	updated spec/file_format_v0.md
	•	new golden files or explicit migrations

A great first contribution:
	•	implement one pager microbench
	•	add one hardening test
	•	write one invariant validator
	•	improve baseline compare ergonomics

⸻

FAQ

Why Zig?

Because this project is about being honest about memory, errors, and performance. Zig’s explicitness is a feature here.

Why start embedded?

Embedded keeps the learning loop tight: no network, no daemon ops, no distributed failure modes. But we design the commit stream seam so we can evolve into distributed durability later.

Why B+tree first?

It’s a proven, teachable ordered index. It gives us:
	•	point lookups
	•	range scans
	•	a clean path to secondary indexes and more complex query layers later

What about SQL?

SQL is a layer on top of a correct, fast storage engine. We may add a SQL layer later, but the kernel must stand on its own.

What are cartridges, in one sentence?

Precomputed, versioned artifacts derived from the commit stream that make specific query shapes extremely fast at runtime.

⸻

License

TBD. Pick early and keep it simple (MIT or Apache-2.0 are typical for systems projects).
