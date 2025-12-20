spec/hardening_v0.md

These are tests that must exist early and run nightly (or on demand).

1) Crash consistency torture (critical nightly)

hard/crash/random_kill_during_workload

Runner pattern:
	•	spawn subprocess
	•	run random txns (seeded)
	•	kill -9 at random times (including mid-commit)
	•	reopen
	•	verify against reference model: DB state == some prefix of commits

Must pass:
	•	0 silent corruptions
	•	recovery always completes or fails with explicit corruption error

Metrics recorded:
	•	recovery time p50/p99
	•	number of killed runs executed
	•	smallest “prefix mismatch” if detected (helps debugging)

2) Torn-write simulation (critical nightly)

hard/io/torn_page_write

Injector:
	•	simulate writing only first X bytes of a page, then crash
Expected:
	•	checksum detects it
	•	DB either rolls back to previous meta root or reports corruption cleanly (no undefined behavior)

3) Fuzz: page decode + node decode (critical nightly)

hard/fuzz/page_decode

hard/fuzz/btree_node_decode
	•	seed corpus: valid pages + mutated pages
	•	assert: never crash, never OOB, errors are clean

4) Format golden files (always-on)

hard/format/open_golden_v0
	•	open known DB created by an earlier commit
	•	verify enumerating keys matches expected hash

