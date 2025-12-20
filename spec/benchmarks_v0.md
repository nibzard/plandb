spec/benchmarks_v0.md

1) Profiles and rules

Hardware profiles (declared in JSON output)

Bench runner must include:
	•	profile.name: ci | dev_nvme
	•	cpu_model, core_count, ram_gb
	•	os, fs, zig_version, build_mode
	•	db.page_size, db.checksum, db.sync_mode

Profiles
	•	ci: cheap runner, stable-ish.
	•	dev_nvme: your “truth machine” (local NVMe SSD, release mode).

Measurement rules (applies to every bench)

Each benchmark run must output:
	•	ops_total, duration_ns, ops_per_sec
	•	latency_ns: p50, p95, p99, max
	•	bytes: read_total, write_total
	•	io: fsync_count, fdatasync_count, mmap_faults (if available)
	•	alloc: alloc_count, alloc_bytes (at least in debug/profiling builds)
	•	errors_total
	•	seed (if randomized)

Warmup: 1–3 seconds (or N ops) not counted in results.

Variability rule: if coefficient of variation > 10% across 5 repeats, mark as unstable and don’t gate CI until fixed.

⸻

2) Baselines and CI gating

Baseline storage

Store baselines in repo under:
	•	bench/baselines/ci/<bench_name>.json
	•	bench/baselines/dev_nvme/<bench_name>.json (optional, used for dashboards)

Baseline JSON includes the full output + git SHA.

CI gating thresholds (Month 1)

Bench marked as critical fails PR if median regresses beyond:
	•	Throughput: -5% or worse vs baseline
	•	Latency p99: +10% or worse vs baseline
	•	Allocations/op: +5% or worse vs baseline (where tracked)
	•	fsync/op: any increase fails unless expected and approved

A PR may include a bench/allow_regression.json with justification + new baseline SHA, but that file should be rare and reviewed.

⸻

3) Month 1 benchmark suites

Month 1 is: pager + B+tree + MVCC snapshots + commit meta (embedded mode, single writer).

Suite A: Pager / Storage primitives (critical)

bench/pager/open_close_empty

Goal: opening DB is cheap, deterministic.
	•	Setup: empty DB file
	•	Workload: open+close 10k times
	•	Metrics: ops/sec, p99 open latency
	•	Dev goal: p99 open+close < 200µs
	•	CI gate: regression only (no absolute)

bench/pager/read_page_random_16k_hot
	•	Setup: DB with 1M pages; page cache warmed (touch all)
	•	Workload: random reads of pages (no checksum verify toggle version too)
	•	Metrics: p50/p99 read latency, ops/sec
	•	Dev goal: p50 < 5µs, p99 < 20µs (in-memory hot path)
	•	CI gate: regression

bench/pager/read_page_random_16k_cold
	•	Setup: same DB; drop caches (best-effort) OR use a file larger than RAM on dev_nvme
	•	Workload: random reads
	•	Metrics: p50/p99, bytes read, ops/sec
	•	Dev goal: p50 < 200µs, p99 < 1ms
	•	CI gate: regression only (CI machines vary too much)

bench/pager/write_new_page_16k_no_sync
	•	Setup: create new pages only (append / freelist alloc)
	•	Workload: write N pages without fsync
	•	Metrics: throughput MB/s, CPU time per page, allocs/op
	•	Dev goal: sustain > 500 MB/s writes (sequential-ish)
	•	CI gate: regression

bench/pager/commit_meta_fsync

This is the “commit cost” anchor for Month 1.
	•	Setup: empty txn that only updates meta page(s)
	•	Workload: commit 10k times
	•	Metrics: commit latency p50/p99, fsync/commit
	•	Must: fsync_count == commits (Month 1, before group commit)
	•	Dev goal: p50 < 2ms, p99 < 10ms (NVMe reality)
	•	CI gate: regression + fsync correctness

bench/pager/checksum_verify_16k
	•	Setup: random pages in memory
	•	Workload: verify checksum N times
	•	Metrics: ns/page, p99
	•	Dev goal: < 300ns per page verify (ballpark; depends on algo)
	•	CI gate: regression

⸻

Suite B: B+tree core (critical)

All B+tree benches should be parameterized by:
	•	key_size = 16B
	•	value_size = 128B (plus variants below)
	•	records = 1M (and 100k in CI if time constrained)
	•	page_size = 16KB

bench/btree/build_sequential_insert_1m
	•	Workload: insert 1M ascending keys in single writer txn batches
	•	Metrics: build time, write amplification (bytes written / logical bytes)
	•	Dev goal: build 1M keys in < 10s (first cut), then drive down
	•	CI gate: regression

bench/btree/point_get_hot_1m
	•	Setup: tree built, cache warmed
	•	Workload: random point gets
	•	Metrics: p50/p99, ops/sec
	•	Dev goal: p50 < 2µs, p99 < 10µs
	•	CI gate: regression

bench/btree/point_get_cold_1m
	•	Setup: cold-ish
	•	Workload: random gets
	•	Metrics: p50/p99; bytes read/op
	•	Dev goal: p50 < 300µs, p99 < 2ms
	•	CI gate: regression only

bench/btree/point_put_update_10pct_hot
	•	Setup: existing 1M keys
	•	Workload: update values for hot 10% of keys; commit each txn of size K
	•	Params: txn_size = 1, 10, 100 updates per commit
	•	Metrics: commits/sec, p99 commit latency, bytes written/op
	•	Dev goal: show benefit of batching:
	•	txn_size 100 should give ≥ 10× throughput vs txn_size 1
	•	CI gate: regression and batching monotonicity (see below)

Batching monotonicity rule: throughput(txn_size=100) must be > throughput(txn_size=10) > throughput(txn_size=1). If not, something is structurally wrong.

bench/btree/range_scan_1k_rows_hot
	•	Workload: pick random start key, scan next 1000
	•	Metrics: rows/sec, p99 per-scan latency
	•	Dev goal: p99 scan < 200µs hot
	•	CI gate: regression

bench/btree/delete_10pct
	•	Workload: delete 100k keys
	•	Metrics: total time, tree health invariants (validated)
	•	Dev goal: correctness first; perf regression gated
	•	CI gate: regression

Required variants (not all critical in CI)
	•	value_size=0 (keys-only)
	•	value_size=4KB (forces overflow/large payload path)

⸻

Suite C: MVCC snapshots (critical)

Month 1 target: many readers + single writer.

bench/mvcc/snapshot_open_close
	•	Workload: open snapshot txn repeatedly
	•	Metrics: ns/op
	•	Dev goal: p99 < 5µs
	•	CI gate: regression

bench/mvcc/readers_256_point_get_hot
	•	Setup: 256 reader threads (or async tasks), 1 writer idle
	•	Workload: each reader does point_get loop on its snapshot
	•	Metrics: aggregate ops/sec, per-thread p99
	•	Dev goal: scale to at least 16× single-thread throughput by 256 readers (you’ll be CPU-limited; the shape matters)
	•	CI gate: regression (lower thread count in CI if needed)

bench/mvcc/writer_commits_with_readers_128
	•	Setup: 128 readers continuously reading; 1 writer committing
	•	Workload: writer commits txns of size 100 updates
	•	Metrics: writer p99 commit latency, reader p99 get latency
	•	Dev goals:
	•	Reader p99 must not degrade by > 2× vs no-writer case
	•	Writer p99 < 20ms under read pressure
	•	CI gate: regression

bench/mvcc/conflict_detection_basic

(Yes, even with single writer: you want the machinery measured.)
	•	Workload: attempt to commit with a known conflict vs no conflict
	•	Metrics: ns/commit check, error rate
	•	Dev goal: conflict check overhead < 10% of commit CPU time (hot path)
	•	CI gate: regression

⸻

Suite D: Time-travel / commit stream seam (critical)

Even if Month 1 is “meta pages + COW”, define the canonical commit record now.

bench/log/append_commit_record
	•	Workload: append N commit records to log file/buffer
	•	Metrics: records/sec, bytes/sec, allocs/record
	•	Dev goal: > 200k records/sec in-memory encoding (first cut)
	•	CI gate: regression

bench/log/replay_into_memtable
	•	Workload: read log and rebuild an in-memory map of latest values
	•	Metrics: records/sec, total replay time
	•	Dev goal: replay 1M records < 2s
	•	CI gate: regression

bench/timetravel/open_snapshot_by_txn
	•	Workload: open snapshot at random historical txn ids
	•	Metrics: p50/p99 latency
	•	Dev goal: p99 < 50µs (should be pointer/root lookup, not replay)
	•	CI gate: regression

⸻
