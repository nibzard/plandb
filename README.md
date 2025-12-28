# NorthstarDB (working title)

A database built from scratch in **Zig** as a step-by-step educational project — with a hard constraint: **benchmarks and hardening tests are the source of truth**.

We start with a minimal, real database kernel (pager + B+tree + MVCC snapshots + crash safety). We grow it into a **"Living Database"** that autonomously maintains, optimizes, and understands its own data using AI intelligence.

**Core Capabilities:**
- **Massive read concurrency** (orchestrated AI coding agents, swarms, IDE copilots)
- **Deterministic replay** (commit stream as an audit log)
- **Time travel** (query historical snapshots cheaply)
- **Cartridges** (offline-built, hot-path artifacts that make graph/vector queries fast)
- **🆕 AI Intelligence** (structured memory cartridges, natural language queries, autonomous optimization)
- **Cloud reality** (durability and coordination move to replicated logs over time)

This repo is deliberately designed so you can learn database internals by building one — and then keep going until it becomes the intelligent database foundation for AI agent orchestration.

---

## Why this database exists

Modern AI coding systems are moving from “one assistant in one editor” to **orchestrated swarms**:

- 100s of parallel tasks (analysis, refactor, test gen, security scans)
- Long-running sessions (hours/days)
- Distributed workers (cloud + local, multiple devs)
- Huge working sets (whole repos, dependency graphs, traces, embeddings)
- Need for replayable decisions (“why did agent X do this?”)

Existing databases each miss important pieces:

- Embedded stores often have **single-writer bottlenecks** or limited replay
- Server DBs add operational overhead and don’t naturally fit “commit stream + snapshots”
- Graph/vector systems are specialized; you end up duct-taping 4–6 components

**NorthstarDB** is an attempt to unify the essential primitives:

1. **MVCC snapshots** for massive read concurrency
2. **Commit stream** as the durable audit log (CDC + replay)
3. **Time travel** as a first-class query mode
4. **Cartridges** for precomputed hot paths (graph adjacency, HNSW, transitive closure)
5. **🆕 Structured Memory** - AI-extracted entities, topics, and relationships for semantic understanding
6. **🆕 Natural Language Queries** - Ask "what performance optimizations did niko make to the btree?"
7. **🆕 Autonomous Optimization** - Database maintains and optimizes itself based on usage patterns
8. A growth path from **embedded → replicated/distributed → intelligent**

---

## Project principles (the manifesto)

1. **Benchmarks are law.** Performance changes only count if the benchmark suite agrees.
2. **Correctness first, proven continuously.** Property tests + crash tests run from day one.
3. **State is derived; the log is truth.** Data structures are rebuildable from the commit stream.
4. **Pay coordination at commit, not on every read.** Snapshot reads are always cheap.
5. **Make performance visible.** Every subsystem ships with counters and microbenchmarks.
6. **Predictable > clever.** Tail latency matters more than peak throughput.
7. **No hidden costs.** We track allocations/op and bytes moved in all hot paths.
8. **Cartridges turn offline compute into online speed.**
9. **Teachability is a feature.** Invariants are documented, tested, and explainable.
10. **Zig fits the mission.** Explicit memory, explicit errors, explicit performance.

---

## What we’re building (phases)

### Phase 1 — The DB kernel (Month 1 scope)
A minimal embedded database that is already “real”:

- **Single file** storage format
- **Pager** (page allocation, IO, checksum, meta pages)
- **Copy-on-write B+tree** (ordered KV store)
- **MVCC snapshots**
  - many readers, single writer (initially)
- **Crash safety**
  - atomic root/meta switch
  - deterministic recovery
- **Commit record format**
  - a canonical commit stream emitted for every transaction (even embedded mode)

This is the minimal base that supports time-travel and the “log seam” that later becomes replication.

### Phase 2 — Time travel & replay
- `AS OF txn_id` snapshots
- replay tooling
- deterministic reproductions of historical decisions

### Phase 3 — Cartridges
Offline-built, versioned artifacts derived from the commit stream:

- graph adjacency (call graph out/in)
- transitive closure (dependency closure)
- vector index (HNSW)
- task queue hot index (`pending_tasks_by_type`)
- query plan cache cartridges (later)

Cartridges are “read-optimized materializations” with explicit invalidation and versioning.

### Phase 4 — Distributed durability (optional)
- leader commits to a replicated log
- replicas materialize state from the log
- reads served locally, coordination paid at commit

### Phase 5 — Living Database: AI Intelligence (Month 7-12)
**Transform into an intelligent database that understands and optimizes itself:**

- **Structured Memory Cartridges** - AI-extracted entities, topics, relationships from commit stream
- **Natural Language Interface** - Query by intent: "show me all database corruption fixes"
- **Autonomous Maintenance** - Automatic context summarization, relationship discovery, optimization
- **Plugin Ecosystem** - Extensible AI functions for domain-specific intelligence
- **Provider Agnostic** - OpenAI, Anthropic, local models with deterministic function calling

*See [PLAN-LIVING-DB.md](./PLAN-LIVING-DB.md) for complete architecture and implementation roadmap*

**Timeline:**
- **Months 1-6**: Core database functionality (kernel, time travel, cartridges)
- **Months 7-12**: AI intelligence layer (structured memory, intelligent queries, autonomy)

---

## Core use case: database for orchestrated AI coding agents

This is the guiding scenario for macrobenchmarks and feature prioritization:

- task queues, claims, retries
- codebase knowledge graph (files/functions/edges)
- embeddings + semantic search
- trace/audit log of agent actions
- collaboration (many sessions, optimistic conflict checks)
- deterministic replay for debugging

The database should eventually make “agent state + knowledge + coordination” simpler than a duct-taped stack of Redis + Postgres + S3 + vector DB + graph DB.

---

## Repo layout (planned)

.
├── src/
│   ├── core/              # common types: PageId, TxnId, Lsn, slices, checksums
│   ├── pager/             # file format, page cache, allocator, meta pages
│   ├── btree/             # nodes, splits, iterators, validation
│   ├── mvcc/              # snapshots, reader txns, writer txn
│   ├── log/               # commit record encode/decode, replay engine
│   ├── db/                # public API, transactions, iterators
│   └── util/              # testing helpers, deterministic RNG, stats
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
│   ├── crash/             # subprocess killer, crash/reopen verification
│   ├── io_faults/         # torn-write, short-write simulators
│   ├── fuzz/              # page/node decode fuzzing + corpus
│   └── format/            # golden files + compatibility checks
│
├── spec/
│   ├── benchmarks_v0.md   # benchmark names, metrics, thresholds (Month 1)
│   ├── hardening_v0.md    # crash/fuzz/fault plans and invariants
│   ├── file_format_v0.md  # on-disk layout: pages, meta pages, checksums
│   └── semantics_v0.md    # MVCC + txn semantics + conflict rules
│
└── tools/
├── gen_synth_repo/    # synthetic dataset generator for macrobenches
└── replay/            # replay + debugging utilities

---

## Examples

Complete, working example projects demonstrating NorthstarDB features:

| Example | Description | Use Case |
|---------|-------------|----------|
| [Basic KV Store](examples/basic_kv/) | Core CRUD operations | Learning basics, config storage |
| [Task Queue System](examples/task_queue/) | Persistent job queue with workers | Background processing, async workflows |
| [Document Repository](examples/document_repo/) | Full-text searchable storage | Content management, knowledge bases |
| [Time-Series Telemetry](examples/time_series/) | Metrics database with aggregation | Monitoring, IoT, analytics |
| [AI-Powered Knowledge Base](examples/ai_knowledge_base/) | Semantic graph with LLM integration | Knowledge graphs, semantic search |

**Quick start:**
```bash
cd examples/basic_kv
zig build run
```

**Interactive examples:** See the [Examples Guide](https://northstardb.dev/guides/examples) in the documentation.

---

## The North Star: benchmarks & hardening

We do not “claim performance.” We **prove it** with reproducible runs.

### Two benchmark classes

#### 1) Microbenchmarks (run in CI)
These test “database physics”:

- pager page read/write cost (hot/cold)
- checksum cost
- btree point-get / point-put / range scan
- MVCC snapshot open / readers scaling
- commit record encode/decode and replay

They gate regressions.

#### 2) Macrobenchmarks (nightly / local)
These simulate the real target workloads:

- task queue creation + claims by 100–1000 “agents”
- code graph ingestion + query mix
- time-travel + replay under heavy commit volume
- cartridge build + serve latency (offline build cost vs online win)

### Hardening tests (nightly)
These are correctness torture racks:

- random kill -9 during workload, reopen and verify
- torn-page write simulation
- short-write simulation
- fuzz decode: page parsing + btree node parsing
- format golden files: compatibility across versions

**If hardening fails, development stops until it’s fixed.**

---

## Month 1 benchmark targets (summary)

Month 1 is about shape and regression control more than bragging rights.
Absolute numbers depend on machine and will evolve; we still track them.

Key targets (dev_nvme profile):
- **hot point get:** p50 ~ single-digit µs, p99 in tens of µs
- **commit meta fsync:** p50 a few ms, p99 under ~10–20ms
- **snapshot open:** microseconds
- **batching must win:** txn_size=100 must massively outperform txn_size=1

CI gates are regression-based (e.g., -5% throughput / +10% p99 latency).

See: `spec/benchmarks_v0.md`.

---

## API direction (initial)

We start with an embedded KV API that can grow into SQL/relational:

```text
db.open(path, options)

txn = db.begin_read(snapshot = latest | txn_id)
val = txn.get(key)
iter = txn.scan(prefix or range)
txn.commit() / txn.abort()

wtxn = db.begin_write()
wtxn.put(key, val)
wtxn.del(key)
wtxn.commit()  # emits commit record, updates meta root atomically
```

Internally, everything is designed so:
	•	readers are lock-free snapshots
	•	writer builds a new root (COW)
	•	commit produces a canonical record (the future replication seam)

⸻

Cartridges (design intent)

A cartridge is a versioned, offline-built artifact derived from the commit stream.

Properties:
	•	rebuildable deterministically from log position N
	•	memory-map friendly, fast to load (<10ms)
	•	optimized for specific query shapes

Examples:
	•	pending_tasks_by_type index for <1ms “claim next task”
	•	call graph adjacency list
	•	transitive dependency closure
	•	HNSW vector index for embeddings

Cartridges give you “graph DB speed” and “vector DB speed” without turning the core engine into a pile of specialized code paths. They are explicit, testable, and benchmarked.

⸻

Development workflow

The rule of three
	1.	Write/extend a benchmark or hardening test
	2.	Implement the smallest change to pass
	3.	Lock it in with regression baselines

How performance work happens here
	•	microbench → profile → change → microbench again
	•	if the benchmark suite doesn’t improve or stay stable, the change doesn’t ship

⸻

Status

This project is early-stage and intentionally methodical.
The first milestone is getting spec/benchmarks_v0.md and spec/hardening_v0.md to “green” with a real pager + btree + MVCC skeleton.

⸻

Contributing

We welcome contributions, but the bar is simple:
	•	New feature = new tests + new benchmarks
	•	Changes that impact hot paths must include benchmark evidence
	•	Format changes must include migration/golden file updates

If you’re new to databases or Zig: start by improving one benchmark, one invariant, or one hardening test. That’s the fastest way to learn.

⸻

License

NorthstarDB is released under a custom restrictive license (see [LICENSE](./LICENSE)).

**Permitted Uses:**
- ✅ Educational and research use
- ✅ Internal business applications
- ✅ Open source contribution
- ✅ Non-AI commercial applications

**Prohibited Uses:**
- ❌ AI model training and development
- ❌ Commercial AI training services
- ❌ Military and government applications
- ❌ Use in competing AI database systems

**Why this license?** These restrictions protect NorthstarDB's unique AI intelligence innovations while allowing legitimate educational, research, and traditional database uses.

