# Roadmap TODOs

Priority legend: 🔴 P0 (critical) · 🟠 P1 (high) · 🟡 P2 (medium) · 🟢 P3 (low)

## Phase 0 — North Star Scaffolding
- [ ] 🔴 Emit per-repeat JSON files (no aggregation) with stable filenames
- [ ] 🔴 Compute coefficient of variation across repeats and mark stability
- [ ] 🔴 Add suite-level gating command that fails on any critical regression
- [ ] 🟠 Validate outputs against `bench/results.schema.json` before write/compare
- [ ] 🟠 Implement `bench --list` to enumerate benchmarks and suites
- [ ] 🟠 Add `--warmup-ops` and `--warmup-ns` honoring in runner
- [ ] 🟠 Persist run metadata (CPU model/FS/RAM) robustly across OSes
- [ ] 🟡 Baseline discovery: compare entire output dir vs baseline dir
- [ ] 🟡 Document harness usage, filters, baselines, and JSON layout

## Phase 1 — Pager (V0)
- [ ] 🔴 Define page header and meta structs per `spec/file_format_v0.md`
- [ ] 🔴 Implement CRC32C and page checksum verify API
- [ ] 🔴 Implement Meta A/B encode/decode, checksum, and atomic toggle
- [ ] 🔴 Implement `open()` recovery: choose highest valid meta, else Corrupt
- [ ] 🟠 Implement page allocator (rebuild-on-open freelist policy)
- [ ] 🟠 Implement page read/write with checksums and bounds checks
- [ ] 🟠 Implement embedded commit protocol and fsync ordering
- [ ] 🔴 Add microbench `bench/pager/open_close_empty`
- [ ] 🟠 Add microbench `bench/pager/read_page_random_16k_hot`
- [ ] 🟡 Add microbench `bench/pager/read_page_random_16k_cold` (best-effort cache drop)
- [ ] 🔴 Add microbench `bench/pager/commit_meta_fsync` with fsync correctness assert
- [ ] 🟠 Hardening: torn meta write detected and rolls back to prior meta
- [ ] 🟡 Golden file: empty DB v0 opens and validates

## Phase 2 — B+tree
- [ ] 🔴 Implement leaf slotted-page encode/decode + structural validator
- [ ] 🔴 Implement internal node (separators + child pointers)
- [ ] 🔴 Implement get/put/del with COW up the path
- [ ] 🟠 Implement split/merge + right-sibling pointer
- [ ] 🟠 Implement iterator and range scan API
- [ ] 🔴 Add microbench `bench/btree/build_sequential_insert_1m`
- [ ] 🔴 Add microbench `bench/btree/point_get_hot_1m`
- [ ] 🟠 Add microbench `bench/btree/range_scan_1k_rows_hot`
- [ ] 🟠 Fuzz: node decode (valid and mutated corpora)
- [ ] 🟡 CLI validator: dump/verify tree invariants

## Phase 3 — MVCC
- [ ] 🔴 Implement snapshot registry (TxnId ➜ root) and latest snapshot API
- [ ] 🔴 Enforce single-writer lock with explicit `WriteBusy` error
- [ ] 🟠 Ensure read-your-writes within a write txn
- [ ] 🔴 Add microbench `bench/mvcc/snapshot_open_close`
- [ ] 🟠 Add microbench `bench/mvcc/readers_256_point_get_hot` (parameterized N)
- [ ] 🟠 Add microbench `bench/mvcc/writer_commits_with_readers_128`
- [ ] 🟠 Property tests: snapshot immutability and time-travel correctness
- [ ] 🟡 Simple page cache with pinning/epochs for readers

## Phase 4 — Commit Record + Replay
- [ ] 🔴 Implement record header/trailer framing and CRCs per `spec/commit_record_v0.md`
- [ ] 🔴 Implement commit payload encode/decode (Put/Del) with limits
- [ ] 🔴 Append to separate `.log` and fsync before meta flip
- [ ] 🔴 Implement replay engine to rebuild in-memory KV deterministically
- [ ] 🔴 Add microbench `bench/log/append_commit_record`
- [ ] 🔴 Add microbench `bench/log/replay_into_memtable`
- [ ] 🟠 Hardening: torn/short log record detection and clean recovery
- [ ] 🟠 Tooling: `tools/logdump` to inspect/verify records

## Phase 5 — Macrobench: Task Queue
- [ ] 🔴 Define key layout and invariants for tasks and claims
- [ ] 🔴 Implement claim txn semantics (no duplicates under concurrency)
- [ ] 🟠 Build workload driver with M “agents” issuing claims
- [ ] 🟠 Add macrobench scenario + baselines (ci/dev_nvme)
- [ ] 🟠 Crash harness: prefix-check vs reference model after reopen
- [ ] 🟡 Export scenario metrics (p50/p99 claim latency, dup rate, fsyncs/op)

## Phase 6 — Cartridge 1: `pending_tasks_by_type`
- [ ] 🔴 Define cartridge format/versioning and invalidation policy
- [ ] 🔴 Build cartridge from commit stream (offline) deterministically
- [ ] 🟠 Memory-map artifact and serve hot lookups
- [ ] 🟠 Macrobench demonstrating latency improvement vs baseline scan
- [ ] 🟡 Add rebuild triggers and admin introspection API

## Infrastructure & CI
- [ ] 🔴 CI: run unit/property + microbenches (trimmed) and gate regressions
- [ ] 🔴 Thresholds: throughput (-5%), p99 (+10%), alloc/op (+5%), fsync/op (no increase)
- [ ] 🟠 Nightly: hardening suite + macrobenches + baseline refresh
- [ ] 🟠 Command: `bench capture-baseline --profile ci|dev_nvme`
- [ ] 🟡 Contributor guide: “tests + bench evidence” requirements
- [ ] 🟡 Docs: cross-link specs and invariants to code validators

## Output & Reporting
- [ ] 🟠 Emit per-benchmark JSON under `bench/<name>.json` (done) — add tests
- [ ] 🟠 Implement suite summary report and pass/fail counts
- [ ] 🟡 Optional CSV export for quick spreadsheet analysis
