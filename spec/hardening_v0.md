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
	•	smallest "prefix mismatch" if detected (helps debugging)

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

---

## Code Validator Cross-References

### Hardening Test Functions

| Test Category | Validator Function | Source File | Test Name |
|---------------|-------------------|-------------|-----------|
| Crash Torture | `crashHarnessTaskQueue` | src/hardening.zig:445 | "crash harness task queue" |
| Torn Write Header | `hardeningTornWriteHeader` | src/hardening.zig:35 | "torn write header" |
| Torn Write Payload | `hardeningTornWritePayload` | src/hardening.zig:85 | "torn write payload" |
| Missing Trailer | `hardeningShortWriteMissingTrailer` | src/hardening.zig:140 | "missing trailer" |
| Mixed Records | `hardeningMixedValidCorruptRecords` | src/hardening.zig:191 | "mixed valid corrupt records" |
| Invalid Magic | `hardeningInvalidMagicNumber` | src/hardening.zig:272 | "invalid magic number" |
| Golden File | `goldenFileEmptyDbV0` | src/hardening.zig:775 | "golden file: empty DB v0" |

### Concurrency Tests

| Test | Validator Function | Source File | Test Name |
|------|-------------------|-------------|-----------|
| Many Readers One Writer | `concurrencyManyReadersOneWriter` | src/hardening.zig:954 | "concurrency: many readers one writer" |
| Snapshot Isolation | `concurrencySnapshotIsolation` | src/hardening.zig:1059 | "concurrency: snapshot isolation invariants" |
| Forced Yields Stress | `concurrencyForcedYieldsStress` | src/hardening.zig:1163 | "concurrency: forced yields stress" |
| Read Write Stress | `concurrencyReadWriteStress` | src/hardening.zig:1238 | "concurrency: read write stress" |

### Spec Document Links

- **Correctness Contracts**: spec/correctness_contracts_v0.md → DU-001, DU-002 contracts
- **File Format**: spec/file_format_v0.md → corruption handling policy
- **Semantics**: spec/semantics_v0.md → crash recovery rules
- **Commit Record**: spec/commit_record_v0.md → torn-write detection

### Related Test Files

- `src/hardening.zig` - All hardening test implementations
- `src/property_based.zig` - Crash equivalence property tests
- `src/ref_model.zig` - Reference model for verification
- `src/fuzz.zig` - Fuzzing harness for format validators

### Test Orchestration

Run all hardening tests:
```bash
zig test src/hardening.zig
```

Run specific test:
```zig test
zig test src/hardening.zig --test "crash harness task queue"
```

Nightly CI execution: `.github/workflows/nightly.yml`

