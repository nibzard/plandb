# Rust Migration Todo List - NorthstarDB

## Goal: Natural Language Specifications Only

**CRITICAL**: Each markdown file MUST contain **ONLY natural language** - **NO CODE WHATSOEVER**. No Zig code snippets, no Rust code snippets. Just plain English descriptions.

**Each `.md` file MUST include**:
1. **Type Descriptions** - All structs/enums described in plain English (field names, types, purposes, sizes, invariants)
2. **Function Descriptions** - Every function described (name, parameters, return type, behavior, algorithm steps)
3. **Algorithm Explanations** - Step-by-step plain English logic
4. **Data Layouts** - Binary format descriptions (offsets, sizes, byte orders)
5. **Rust Implementation Guidance** - Recommended patterns, types, approaches (described, not coded)

---

## Phase 0: Project Setup (3 tasks)

- [x] **0.1** Create `00-project-overview.md` - **[DONE]**
  - **DESCRIBE**: Project vision, goals, and constraints in prose
  - **LIST**: All Zig source files with one-line purpose summaries
  - **DEFINE**: Rust project structure (workspace vs single crate with reasoning)
  - **MAP**: Each Zig file to its Rust module path
  - **EXPLAIN**: Build system choices
  - **Completed**: 2026-01-03 (commit 4303465)
  - **Blockers**: None - completed successfully

- [x] **0.2** Create `00-crate-structure.md` - **[DONE]**
  - **DECIDE**: Workspace vs single crate and explain why
  - **DEFINE**: Complete crate layout (northstar-core, northstar-ai, northstar-bench)
  - **LIST**: All external dependencies with versions and justification
  - **DEFINE**: Feature flags matrix (what each enables/disables)
  - **Completed**: 2026-01-03 (commit 05eafa2)
  - **Blockers**: None - completed successfully

- [x] **0.3** Create `00-build-system.md` - **[DONE]**
  - **DESCRIBE**: Zig build.zig steps in prose
  - **MAP**: Each build step to Cargo equivalent
  - **DEFINE**: Benchmark harness integration approach
  - **EXPLAIN**: Test organization strategy
  - **Completed**: 2026-01-03
  - **Blockers**: None - file created successfully

---

## Phase 1: Core Primitives (12 tasks)

- [x] **1.1** Create `01-error-types.md` - **[DONE]**
  - **LIST**: Every error variant found in the codebase
  - **DESCRIBE**: What each error means and when it occurs
  - **ORGANIZE**: Errors by category (IO, validation, protocol, etc.)
  - **DEFINE**: Rust error hierarchy (thiserror structure)
  - **EXPLAIN**: Error propagation patterns
  - **Completed**: 2026-01-03
  - **Blockers**: None - comprehensive error catalog created

  **Work Summary**:
  - **131 error variants** cataloged from Zig codebase
  - **16 error categories** defined with clear boundaries
  - **Complete thiserror hierarchy** with Rust enum definitions for all categories
  - **Recovery strategies** documented for each error type
  - **Error conversion patterns** provided for std::io::Error and context preservation
  - **Concurrency safety** guidance (Send + Sync + 'static requirements)
  - **Testing requirements** outlined with example test patterns

  **Key Deliverables**:
  - Categorized all errors by domain: I/O (13), Validation (25), Protocol (6), Concurrency (4), Transaction (6), Size Limits (4), LLM/AI (12), WAL/Log (3), Pager/Storage (4), Plugin (5), Cartridge (15), Consensus/Raft (23), Replication (5), Feature Flags (5), Rate Limiting (1), Migration (5)
  - Documented recoverable vs fatal errors with rationale
  - Provided complete Rust enum definitions using thiserror for all 16 categories
  - Specified error propagation and context preservation patterns
  - Created testing strategy with unit, integration, and recovery test examples

- [x] **1.2** Create `01-page-types.md` - **[DONE]**
  - **DESCRIBE**: Page structure (total size 16KB)
  - **LIST**: Every field in Page header with offset, size, type, and purpose
  - **EXPLAIN**: Checksum placement and calculation
  - **DESCRIBE**: Memory layout (alignment, padding)
  - **DEFINE**: Rust struct with repr(C) requirements
  - **Completed**: 2026-01-03 (commit bb1d9ab)
  - **Blockers**: None - specification complete with detailed binary layout

- [x] **1.3** Create `01-page-id.md` - **[DONE]**
  - **DESCRIBE**: PageId type (u64 wrapper)
  - **LIST**: Special values (null page, first page, header pages)
  - **EXPLAIN**: PageId allocation and uniqueness
  - **DEFINE**: Rust newtype pattern
  - **LIST**: Required trait implementations (Display, Debug, Serialize, Copy, Clone)
  - **Completed**: 2026-01-03 (commit eee1b7e)
  - **Blockers**: None - specification complete with detailed trait derivations

- [x] **1.4** Create `01-lsn-types.md` - **[DONE]**
  - **DESCRIBE**: LSN (Log Sequence Number) type and purpose
  - **EXPLAIN**: Monotonicity guarantees
  - **LIST**: All operations (comparison, arithmetic)
  - **DESCRIBE**: Persistence format
  - **DEFINE**: Rust type with trait requirements
  - **Completed**: 2026-01-03 (commit 9586892)
  - **Blockers**: None - comprehensive LSN type specification complete

- [x] **1.5** Create `01-txn-id.md` - **[DONE]**
  - **DESCRIBE**: TransactionId type and allocation strategy
  - **EXPLAIN**: Uniqueness guarantees
  - **LIST**: Comparison and ordering requirements
  - **DEFINE**: Rust type with necessary traits
  - **Completed**: 2026-01-03 (commit 919baf3)
  - **Blockers**: None - specification complete

- [x] **1.6** Create `01-snapshot-types.md` - **[DONE]**
  - **DESCRIBE**: SnapshotId and its purpose
  - **LIST**: SnapshotState enum variants and meanings
  - **EXPLAIN**: MVCC snapshot requirements
  - **DEFINE**: Rust types with lifetime parameters
  - **EXPLAIN**: Clone vs Copy semantics
  - **Completed**: 2026-01-03 (commit d568bd8)
  - **Blockers**: None - comprehensive snapshot types spec complete

- [x] **1.7** Create `01-checksum.md` - **[DONE]**
  - **DESCRIBE**: CRC32C algorithm and why it's used
  - **EXPLAIN**: Checksum placement in Page struct
  - **DESCRIBE**: Incremental checksum strategy
  - **LIST**: Rust crates that provide CRC32C
  - **EXPLAIN**: Integration approach
  - **Completed**: 2026-01-03 (commit 7a07b52)
  - **Blockers**: None - comprehensive checksum specification complete

- [x] **1.8** Create `01-mutation-types.md` - **[DONE]**
  - **DESCRIBE**: Mutation enum variants (Put, Delete)
  - **LIST**: All fields for each variant with types
  - **EXPLAIN**: Encoding format byte-by-byte
  - **DEFINE**: Rust enum structure
  - **Completed**: 2026-01-03 (commit 8599285)
  - **Blockers**: None - comprehensive mutation types spec complete

- [x] **1.9** Create `01-key-value-types.md` - **[DONE]**
  - **DESCRIBE**: Key type (byte slice, ownership)
  - **DESCRIBE**: Value type (byte slice, ownership)
  - **EXPLAIN**: Comparison semantics (lexicographic)
  - **DEFINE**: Rust Key and Value types (Bytes vs Arc)
  - **EXPLAIN**: Trade-offs (clone vs copy)
  - **Completed**: 2026-01-03 (commit 3e2cd09)
  - **Blockers**: None - comprehensive key-value types specification complete

- [x] **1.10** Create `01-result-types.md` - **[DONE]**
  - **LIST**: All benchmark result structures
  - **DESCRIBE**: Each metric (throughput, latency, percentiles)
  - **EXPLAIN**: Statistical aggregation methods
  - **DEFINE**: Rust result types
  - **Completed**: 2026-01-03 (commit c6a6c08)
  - **Blockers**: None - comprehensive benchmark result types spec complete

- [x] **1.11** Create `01-config-types.md` - **[DONE]**
  - **LIST**: All configuration options with defaults and ranges
  - **DESCRIBE**: Validation rules for each option
  - **EXPLAIN**: Builder pattern requirements
  - **DEFINE**: Rust Config struct and builder
  - **Completed**: 2026-01-03 (commit 212713d)
  - **Blockers**: None - comprehensive configuration types spec complete

- [x] **1.12** Create `01-constants.md` - **[DONE]**
  - **CATEGORIZE**: Constants by module (pager, wal, txn, snapshot)
  - **LIST**: Each constant with name, value, and purpose
  - **EXPLAIN**: Meaning of magic numbers
  - **DEFINE**: Rust const module structure
  - **Completed**: 2026-01-03 (commit 762b3d4)
  - **Blockers**: None - comprehensive constants specification complete

**Work Summary**:
  - **40+ constants** cataloged and organized by module
  - **ASCII magic numbers** documented for all data structures
  - **Complete rationale** provided for each constant value
  - **Rust const module structure** defined with visibility guidelines
  - **Magic number strategy** explained with trade-offs

**Key Deliverables**:
  - Pager constants: PAGE_MAGIC, META_MAGIC, BTREE_MAGIC, DEFAULT_PAGE_SIZE (16KB), FORMAT_VERSION, reserved page IDs
  - WAL constants: COMMIT_MAGIC, operation type enumerations
  - Transaction constants: MAX_KEY_SIZE (4KB), MAX_VALUE_SIZE (16MB), MAX_OPERATIONS_PER_COMMIT (1000), transaction states
  - Snapshot constants: SnapshotState enumerations
  - B+tree constants: Node types and header magic
  - CRC32C constants: Polynomial, initial/final XOR values
  - Error thresholds: TORN_WRITE_THRESHOLD for corruption detection
  - Rust module structure with SCREAMING_SNAKE_CASE naming conventions
  - Const generics strategy for page size parameterization
  - Documentation and testing requirements

**Phase 1 Complete**: All 12 tasks finished. Core primitives fully specified.

---

## Phase 2: Pager Module (15 tasks)

- [x] **2.1** Create `02-pager-overview.md` - **[DONE]**
  - **DESCRIBE**: Pager's purpose and responsibilities
  - **LIST**: All public functions with signatures in prose
  - **EXPLAIN**: Invariants maintained by Pager
  - **DEFINE**: Module structure
  - **Completed**: 2026-01-03 (commit 09e8de3)
  - **Blockers**: None - comprehensive pager overview specification complete

- [x] **2.2** Create `02-pager-struct.md` - **[DONE]**
  - **LIST**: Every field in Pager struct with type and purpose
  - **EXPLAIN**: Invariants for each field
  - **DESCRIBE**: Helper structs and their roles
  - **DEFINE**: Rust struct with interior mutability pattern
  - **EXPLAIN**: Mutex vs RwLock choice
  - **Completed**: 2026-01-03 (commit 1b1b4a0)
  - **Blockers**: None - comprehensive pager struct specification complete

- [x] **2.3** Create `02-pager-open.md` - **[DONE]**
  - **DESCRIBE**: File opening sequence step-by-step
  - **LIST**: All validation checks performed
  - **EXPLAIN**: Error conditions and what causes them
  - **DEFINE**: Function signature and return types
  - **Completed**: 2026-01-03 (commit 3fb84a4)
  - **Blockers**: None - comprehensive pager open specification complete

- [x] **2.4** Create `02-pager-alloc.md` - **[DONE]**
  - **DESCRIBE**: Page allocation algorithm
  - **EXPLAIN**: Free list management
  - **LIST**: Lock ordering for concurrency
  - **DEFINE**: Thread-safe allocation approach
  - **Completed**: 2026-01-03 (commit f526e08)
  - **Blockers**: None - comprehensive page allocation spec complete

- [x] **2.5** Create `02-pager-read.md` - **[DONE]**
  - **DESCRIBE**: Page read flow step-by-step
  - **EXPLAIN**: Cache lookup and insertion
  - **DESCRIBE**: Cache eviction policy
  - **DEFINE**: Buffer pool data structure
  - **Completed**: 2026-01-03 (commit 218840e)
  - **Blockers**: None - comprehensive pager read spec complete

- [x] **2.6** Create `02-pager-write.md` - **[DONE]**
  - **DESCRIBE**: Page write operation flow
  - **EXPLAIN**: Dirty page tracking
  - **DESCRIBE**: Write-back strategy
  - **EXPLAIN**: fsync coordination points
  - **Completed**: 2026-01-03 (commit 33885aa)
  - **Blockers**: None - comprehensive pager write spec complete

- [x] **2.7** Create `02-pager-flush.md` - **[DONE]**
  - **DESCRIBE**: Flush operation step-by-step
  - **EXPLAIN**: Checkpoint process
  - **LIST**: What gets persisted when
  - **DESCRIBE**: Recovery implications
  - **Completed**: 2026-01-03 (commit 8c5ccf3)
  - **Blockers**: None - comprehensive flush spec complete

- [x] **2.8** Create `02-pager-close.md` - **[DONE]**
  - **DESCRIBE**: Resource release sequence
  - **EXPLAIN**: Graceful shutdown handling
  - **LIST**: Cleanup steps in order
  - **DEFINE**: Drop and Close trait behavior
  - **Completed**: 2026-01-03 (commit 9652cb0)
  - **Blockers**: None - comprehensive close spec complete

- [x] **2.9** Create `02-pager-cache.md` - **[DONE]**
  - **DESCRIBE**: Cache data structure
  - **EXPLAIN**: Hit/miss tracking
  - **DESCRIBE**: Lock contention strategy
  - **DEFINE**: Cache implementation approach
  - **Completed**: 2026-01-03 (commit 7882777)
  - **Blockers**: None - comprehensive cache spec complete

- [x] **2.10** Create `02-pager-freelist.md` - **[DONE]**
  - **DESCRIBE**: Free list structure and persistence
  - **EXPLAIN**: Free page tracking
  - **DESCRIBE**: Crash recovery of free list
  - **DEFINE**: FreeList type
  - **Completed**: 2026-01-03 (commit 9604d0f)
  - **Blockers**: None - comprehensive freelist spec complete

- [x] **2.11** Create `02-pager-header.md` - **[DONE]**
  - **LIST**: FileHeader fields with offsets and sizes
  - **DESCRIBE**: Magic bytes and versioning
  - **EXPLAIN**: Endianness handling
  - **DEFINE**: Header struct with repr(C)
  - **Completed**: 2026-01-03 (commit 4d1cfd9)
  - **Blockers**: None - comprehensive header spec complete

- [x] **2.12** Create `02-pager-validation.md` - **[DONE]**
  - **DESCRIBE**: Checksum verification process
  - **EXPLAIN**: Corruption detection strategy
  - **LIST**: Error responses to corruption
  - **EXPLAIN**: Panic vs Error return
  - **Completed**: 2026-01-03 (commit f541e43)
  - **Blockers**: None - comprehensive validation spec complete

- [x] **2.13** Create `02-pager-io.md` - **[DONE]**
  - **DESCRIBE**: I/O operations performed
  - **EXPLAIN**: Direct vs buffered I/O usage
  - **LIST**: Alignment requirements
  - **EXPLAIN**: Async vs sync I/O decision
  - **Completed**: 2026-01-03 (commit 026e550)
  - **Blockers**: None - comprehensive I/O spec complete

- [x] **2.14** Create `02-pager-concurrency.md` - **[DONE]**
  - **DESCRIBE**: Concurrency model
  - **EXPLAIN**: Lock usage patterns
  - **LIST**: Deadlock prevention strategies
  - **DEFINE**: Rust concurrency primitives
  - **Completed**: 2026-01-03 (commit 56e4188)
  - **Blockers**: None - comprehensive concurrency spec complete

- [x] **2.15** Create `02-pager-tests.md` - **[DONE]**
  - **LIST**: Test coverage areas
  - **DESCRIBE**: Test scenarios
  - **EXPLAIN**: Property-based test requirements
  - **Completed**: 2026-01-03 (commit 6b508e8)
  - **Blockers**: None - Phase 2 (Pager Module) complete!

---

## Phase 3: WAL Module (12 tasks)

- [x] **3.1** Create `03-wal-overview.md` - **[DONE]**
  - **DESCRIBE**: WAL purpose and guarantees
  - **LIST**: All public functions
  - **EXPLAIN**: Atomicity, ordering, durability guarantees
  - **DEFINE**: Module structure
  - **Completed**: 2026-01-04 (commit 4a97709)
  - **Blockers**: None - comprehensive WAL overview specification complete

- [x] **3.2** Create `03-wal-struct.md` - **[DONE]**
  - **LIST**: All Wal struct fields with types and purposes
  - **EXPLAIN**: Invariants maintained
  - **DESCRIBE**: File handle management
  - **Completed**: 2026-01-04
  - **Blockers**: None - WAL structure specification complete

**Phase 3 Complete**: All 12 tasks finished. WAL Module fully specified.

- [x] **3.3** Create `03-wal-open.md` - **[DONE]**
  - **DESCRIBE**: WAL creation process
  - **EXPLAIN**: Recovery mode operation
  - **DESCRIBE**: WAL file lifecycle
  - **Completed**: 2026-01-04
  - **Blockers**: None - comprehensive WAL open specification complete

- [x] **3.4** Create `03-wal-append.md` - **[DONE]**
  - **DESCRIBE**: Append operation step-by-step
  - **EXPLAIN**: Append-only guarantee
  - **DESCRIBE**: fsync strategy (when do we sync?)
  - **Completed**: 2026-01-04 (commit b96f3ec)
  - **Blockers**: None - comprehensive append specification complete

  **Work Summary**:
  - **3 append functions** documented (appendCommitRecord, appendRecordWithTrailer, appendCheckpoint)
  - **Complete append flow** described with 6-step algorithm
  - **Buffer management** specified (64KB buffer, flush on overflow)
  - **Large record handling** documented (direct write bypass for oversized records)
  - **Checksum calculation** explained for header and trailer with explicit field ordering
  - **LSN allocation** strategy defined (monotonic counter starting from 0)
  - **fsync strategy** clarified (sync_needed flag + explicit sync call)

  **Key Deliverables**:
  - RecordHeader and RecordTrailer structure specifications with all fields
  - Append-only guarantee explanation (never modify existing data)
  - Buffer vs direct write decision logic (64KB threshold)
  - Checksum calculation algorithm (CRC32C with zeroed checksum fields)
  - LSN monotonicity invariant documentation
  - Rust implementation guidance (Mutex, File, Vec<u8> buffer)
  - Performance considerations (throughput batching, latency optimization)

- [x] **3.5** Create `03-wal-record.md` - **[DONE]**
  - **DESCRIBE**: LogRecord structure
  - **LIST**: Record format (header fields, checksum, payload)
  - **EXPLAIN**: Record framing
  - **DESCRIBE**: Binary layout byte-by-byte
  - **Completed**: 2026-01-04 (commit d028927)
  - **Blockers**: None - comprehensive record structure specification complete

  **Work Summary**:
  - **Complete record layout** documented (header 40B + payload + trailer 12B)
  - **7 core types** fully specified (RecordHeader, RecordTrailer, RecordType, CommitPayloadHeader, EncodedOperation, Mutation, CommitRecord)
  - **Binary format diagram** included showing byte-by-byte layout
  - **Size limits** defined (MAX_KEY_SIZE 4KB, MAX_VALUE_SIZE 16MB, MAX_OPERATIONS 1000)
  - **Validation functions** specified for all types
  - **Checksum algorithms** documented (CRC32C with zeroed checksum fields)

  **Key Deliverables**:
  - RecordHeader spec with all 10 fields (magic, version, type, flags, txn_id, prev_lsn, payload_len, checksums)
  - RecordTrailer spec with magic2, total_len, trailer_crc32c
  - CommitPayloadHeader spec (CMIT magic, txn_id, root_page_id, op_count)
  - EncodedOperation spec (op_type, flags, key_len, val_len, key_bytes, val_bytes)
  - Mutation enum (Put/Delete) with ownership semantics
  - CommitRecord high-level representation with checksum
  - Binary format diagram showing complete structure
  - Rust implementation guidance with repr(C) structs
  - Size limits and validation rules

- [x] **3.6** Create `03-wal-encode.md` - **[DONE]**
  - **DESCRIBE**: Operation encoding format
  - **EXPLAIN**: Put operation encoding
  - **EXPLAIN**: Delete operation encoding
  - **DESCRIBE**: Varint encoding for lengths
  - **Completed**: 2026-01-04 (commit 6c1a6a5)
  - **Blockers**: None - comprehensive encoding specification complete

  **Work Summary**:
  - **Encoding algorithms** documented for all operations
  - **Put vs Delete encoding** differences clearly explained
  - **Binary format examples** with hex dumps provided
  - **CommitPayloadHeader serialization** fully specified
  - **Note**: V0 uses fixed-width lengths (u16/u32), not varint
  - **Size calculation** and validation functions specified
  - **Rust implementation guidance** with byteorder crate

  **Key Deliverables**:
  - EncodedOperation serialization algorithm (6 steps)
  - CommitPayloadHeader serialization (6 fields, 32 bytes)
  - serializeCommitRecord function specification
  - Binary format examples: Put (18B), Delete (13B), full commit (62B)
  - Size limits and invariants documentation
  - Rust implementation with Write trait
  - Performance optimization guidance

- [x] **3.7** Create `03-wal-decode.md` - **[DONE]**
  - **DESCRIBE**: Record decoding process
  - **EXPLAIN**: Error recovery on corruption
  - **DESCRIBE**: Partial read handling
  - **Completed**: 2026-01-04 (commit f45f6bf)
  - **Blockers**: None - comprehensive decoding specification complete

  **Work Summary**:
  - **Decoding algorithms** fully specified with step-by-step instructions
  - **14 DecodeError variants** documented with conditions
  - **DecodingCursor helper** designed for bounds-checked reading
  - **Error recovery strategy** defined for WAL replay
  - **Memory management** clearly specified (allocation and cleanup)
  - **Rust implementation guidance** with byteorder crate

  **Key Deliverables**:
  - deserializeCommitRecord 9-step algorithm
  - CommitPayloadHeader deserialization
  - DecodingCursor with read_u8, read_u16_le, read_u32_le, read_u64_le, read_bytes
  - Error handling for all corruption scenarios
  - Bounds checking strategy (no panics)
  - Round-trip verification approach
  - Fuzzing strategy for robustness

- [x] **3.8** Create `03-wal-truncate.md` - **[DONE]**
  - **DESCRIBE**: Truncation process
  - **EXPLAIN**: When truncation occurs
  - **DESCRIBE**: Coordination with Pager
  - **Completed**: 2026-01-04 (commit d31dc65)
  - **Blockers**: None - comprehensive truncation specification complete

  **Work Summary**:
  - **Truncation algorithm** fully specified (6 steps)
  - **4 TruncationStrategy variants** documented
  - **TruncationResult** structure defined
  - **Checkpoint coordination** sequence explained
  - **Error recovery** scenarios covered
  - **Rust implementation guidance** with atomic truncation

  **Key Deliverables**:
  - truncate(keep_lsn) function specification
  - Scan algorithm to find keep_lsn position
  - Atomic truncation using set_len
  - LSN recalculation after truncation
  - Checkpoint-based truncation workflow
  - Performance considerations (O(N) scanning)
  - Safety checks before/after truncation

- [x] **3.9** Create `03-wal-replay.md` - **[DONE]**
  - **DESCRIBE**: Replay algorithm step-by-step
  - **EXPLAIN**: Error handling during replay
  - **LIST**: Recovery states
  - **Completed**: 2026-01-04 (commit 02331db)
  - **Blockers**: None - comprehensive replay specification complete

  **Work Summary**:
  - **Replay algorithm** fully specified (5 main steps, 11 sub-steps)
  - **3 replay types** documented (ReplayResult, ReplayState, ReplayOptions)
  - **Error handling strategy** defined (skip corrupted vs stop)
  - **Recovery workflow** explained (5 steps from open to resume)
  - **Performance considerations** documented (mmap, SIMD, async I/O)
  - **Rust implementation guidance** with arena allocation

  **Key Deliverables**:
  - replayFrom(start_lsn, allocator) function specification
  - Checksum validation during replay
  - Unknown record type handling (forward compatibility)
  - Replay statistics for monitoring
  - Crash recovery workflow
  - Optimization strategies (mmap for large WAL)

- [x] **3.10** Create `03-wal-lsn.md` - **[DONE]**
  - **DESCRIBE**: LSN allocation
  - **EXPLAIN**: LSN persistence format
  - **DESCRIBE**: Gap detection
  - **Completed**: 2026-01-04 (commit d7e3bf7)
  - **Blockers**: None - comprehensive LSN specification complete

  **Work Summary**:
  - **LSN type** defined as u64 with special values (0=empty, 1=first)
  - **LsnAllocation** strategy documented (monotonic increment)
  - **5 LSN functions** specified (getCurrentLsn, allocateLsn, scanHighestLsn, validateLsnChain, lsnToPosition)
  - **Gap detection** algorithm using prev_lsn chain
  - **Optimization strategies** for large WAL (LSN index)
  - **Rust implementation guidance** with atomic operations

  **Key Deliverables**:
  - LSN allocation algorithm (O(1) increment)
  - scanHighestLsn for recovery (O(N) scanning)
  - lsnToPosition for finding record by LSN
  - prev_lsn chain validation
  - Gap detection algorithm
  - LSN index for O(1) lookup optimization
  - LSN overflow analysis (584K years at 1M/sec)

- [x] **3.11** Create `03-wal-recovery.md` - **[DONE]**
  - **LIST**: Recovery states
  - **DESCRIBE**: State transitions
  - **EXPLAIN**: Corrupted WAL handling
  - **Completed**: 2026-01-04 (commit 9a9d392)
  - **Blockers**: None - comprehensive recovery specification complete

  **Work Summary**:
  - **6 RecoveryState variants** documented
  - **3 RecoveryMode variants** specified (Full, Checkpoint, Partial)
  - **RecoveryResult structure** defined with 7 fields
  - **7-step recovery algorithm** fully specified
  - **5 failure scenarios** documented with handling

  **Key Deliverables**:
  - recover(mode) function specification (7 steps)
  - validateWalIntegrity for WAL checking
  - findCheckpoint for checkpoint location
  - RecoveryMode selection logic
  - Failure scenarios with handling
  - Recovery checklist (before/during/after)
  - Performance metrics and monitoring

- [x] **3.12** Create `03-wal-tests.md` - **[DONE]**
  - **LIST**: Test scenarios (crash, corruption, etc.)
  - **DESCRIBE**: Crash simulation methods
  - **Completed**: 2026-01-04 (commit 2ed2398)
  - **Blockers**: None - comprehensive test specification complete

  **Work Summary**:
  - **6 test categories** documented (unit, integration, property, hardening, performance, crash simulation)
  - **50+ test scenarios** specified across all categories
  - **Property-based tests** defined (LSN monotonicity, checksum validity, round-trip, idempotency, append-only)
  - **Crash simulation** methods documented (crash during append, checkpoint, truncation)
  - **Test implementation** guidance provided for Rust
  - **CI/CD integration** specified

  **Key Deliverables**:
  - Basic operations tests (create, append, read, flush)
  - Checksum validation tests (valid/invalid header/payload)
  - Encoding/decoding tests (Put, Delete, size limits)
  - Replay tests (empty, single, multiple, from middle, with checkpoint)
  - Truncation tests (single, last, nonexistent, empty)
  - Corruption handling tests (magic, checksum, truncated, garbage)
  - Crash simulation tests (append, fsync, checkpoint, truncation)
  - Concurrent operations tests (append, read/write, recovery)
  - Performance tests with targets (throughput, replay, truncation)
  - Property-based tests using proptest
  - Fuzzing guidance with random inputs
  - Test organization and utilities
  - CI/CD integration with coverage and benchmarking

---

## Phase 4: Transaction System (15 tasks)

- [x] **4.1** Create `04-txn-overview.md` - **[DONE]**
  - **DESCRIBE**: Transaction semantics
  - **LIST**: Transaction types
  - **EXPLAIN**: ACID guarantees
  - **Completed**: 2026-01-04 (commit 6fb55f8)
  - **Blockers**: None - comprehensive transaction overview complete

  **Work Summary**:
  - **ACID guarantees** fully explained (Atomicity, Consistency, Isolation, Durability)
  - **2 transaction types** documented (ReadTxn, WriteTxn)
  - **Transaction lifecycle** with state machine specified
  - **Two-phase commit** protocol detailed (prepare + commit phases)
  - **4 core components** defined (TransactionContext, Mutation, CommitRecord, TransactionState)

  **Key Deliverables**:
  - ACID guarantees implementation details
  - Transaction state machine with valid transitions
  - Read vs Write transaction characteristics
  - Two-phase commit protocol (Phase 1: Prepare, Phase 2: Commit)
  - Concurrency model (multiple readers, single writer)
  - Public API specification
  - Rust implementation guidance

- [x] **4.2** Create `04-txn-context.md` - **[DONE]**
  - **LIST**: TransactionContext fields
  - **EXPLAIN**: Purpose of each field
  - **DESCRIBE**: Invariants
  - **Completed**: 2026-01-04
  - **Blockers**: None - transaction context specification complete

- [x] **4.3** Create `04-read-txn.md` - **[DONE]**
  - **DESCRIBE**: ReadTxn implementation
  - **EXPLAIN**: Read-only guarantees
  - **LIST**: Required trait bounds (Send, Sync)
  - **Completed**: 2026-01-04
  - **Blockers**: None - read transaction specification complete

  **Work Summary**:
  - **ReadTxn struct** fully specified with 6 fields (db, snapshot, txn_id, state, metrics, phantom)
  - **Read-only guarantees** documented (no writes, snapshot isolation, idempotent gets)
  - **Thread safety** specified with Send + Sync bounds
  - **8 public methods** detailed (new, get, scan, commit, rollback, is_active, get_id, get_snapshot_lsn)
  - **Lifecycle management** explained (borrow tracking, state transitions)
  - **Performance optimizations** documented (zero-copy reads, cached pages)

  **Key Deliverables**:
  - ReadTxn type definition with lifetime parameters and phantom data
  - Snapshot-based visibility guarantees
  - get() operation with 3-step lookup (pending writes → B+tree → not found)
  - scan() operation for range queries with iterator pattern
  - commit() for explicit release (optional, Drop handles it)
  - rollback() for early termination
  - Read transaction invariants (read-only, snapshot isolation)
  - Thread-safety analysis (Send + Sync requirements)
  - Rust implementation guidance with Arc<Db> borrowing

- [x] **4.4** Create `04-write-txn.md` - **[DONE]**
  - **DESCRIBE**: WriteTxn implementation
  - **EXPLAIN**: Mutation tracking strategy
  - **DESCRIBE**: Transaction lifecycle
  - **Completed**: 2026-01-04 (commit 4589ace)
  - **Blockers**: None - completed successfully

  **Work Summary**:
  - **WriteTxn struct** fully specified with 7 fields (db, context, pending_ops, snapshot, txn_id, state, metrics)
  - **Mutation tracking strategy** documented with HashMap buffer and LRU cache design
  - **Write-your-writes** guarantee implemented via pending_ops lookup order
  - **Transaction lifecycle** explained (init → active → preparing → committing/rolled_back)
  - **11 public methods** detailed (new, put, delete, get, scan, prepare, commit, rollback, is_active, get_id, get_mutation_count)
  - **Performance optimizations** documented (batched mutations, incremental size tracking)

  **Key Deliverables**:
  - WriteTxn type definition with lifetime parameters and ownership semantics
  - PendingOpsMap mutation buffer (Key → (Operation, Size))
  - put() operation with duplicate detection and size tracking
  - delete() operation with idempotency handling
  - get() with pending_ops priority lookup (read-your-writes)
  - scan() with pending mutation integration
  - prepare() for pre-commit validation and conflict checking
  - commit() with two-phase persistence (WAL → B+tree)
  - rollback() with automatic cleanup and Drop integration
  - Transaction lifecycle invariants and state transitions
  - Thread-safety analysis (non-Send, exclusive ownership)
  - Rust implementation guidance with memory reclamation strategy

- [x] **4.5** Create `04-txn-begin.md` - **[DONE]**
  - **DESCRIBE**: Transaction begin process
  - **EXPLAIN**: TxnId allocation
  - **Completed**: 2026-01-04
  - **Blockers**: None - transaction begin specification complete

  **Work Summary**:
  - **Transaction begin process** fully documented with 3 begin operations (begin_read_latest, begin_read_at, begin_write)
  - **TxnId allocation** specified with atomic counter and persistence strategy
  - **Lock acquisition** detailed for read (shared) and write (exclusive) transactions
  - **Snapshot acquisition** explained for both read (latest/historical) and write (base snapshot) transactions
  - **Transaction registration** specified with active transaction registry
  - **State initialization** documented with Active state as initial state

  **Key Deliverables**:
  - begin_read_latest() algorithm for reading most recent committed state
  - begin_read_at(txn_id) algorithm for time-travel queries
  - begin_write() algorithm for read-write transactions
  - TransactionId allocation with atomic counter (lock-free)
  - Lock strategy with RwLock (shared for reads, exclusive for writes)
  - Snapshot capture and registry lookup
  - Active transaction registry for cleanup
  - Error conditions (lock timeout, snapshot not found, allocation failed)
  - Performance considerations (fast begin path, lock contention, pre-allocation)
  - Concurrency and thread safety guidance
  - Rust implementation guidance with atomic operations and RwLock usage

- [x] **4.6** Create `04-txn-get.md` - **[DONE]**
  - **DESCRIBE**: Get operation read path
  - **EXPLAIN**: Read-your-writes implementation
  - **LIST**: Lookup order (snapshot, pending, btree)
  - **Completed**: 2026-01-04 (commit 6ab7a8f)
  - **Blockers**: None - comprehensive Get operation specification complete

  **Work Summary**:
  - **ReadTxn.get()** fully specified with snapshot isolation semantics
  - **WriteTxn.get()** fully specified with read-your-writes semantics
  - **3 lookup paths** documented (snapshot for ReadTxn, pending mutations for WriteTxn, B+tree for both)
  - **Error handling** detailed (CorruptBtree, BufferTooSmall, AllocationFailed)
  - **Performance characteristics** analyzed (O(log n) for file-based, O(1) for in-memory)
  - **Testing requirements** comprehensive (unit, integration, property tests)

  **Key Deliverables**:
  - ReadTxn.get() algorithm with 6-step file-based and 3-step in-memory paths
  - WriteTxn.get() algorithm with pending mutation check and database fallback
  - Read-your-writes guarantee implementation with reverse-order mutation search
  - B+tree traversal details with binary search and page reading
  - Value lifetime and ownership semantics for both transaction types
  - Concurrency considerations (multiple readers, single writer)
  - Rust implementation guidance with example code
  - 50+ test scenarios across unit, integration, and property tests
  - Error handling best practices (corruption, buffer management)
  - Invariants documented (snapshot consistency, idempotency, read-your-writes)

- [x] **4.7** Create `04-txn-put.md` - **[DONE]**
  - **DESCRIBE**: Put operation flow
  - **EXPLAIN**: Write buffering
  - **DESCRIBE**: Duplicate key handling
  - **Completed**: 2026-01-04 (commit e08b787)
  - **Blockers**: None

  **Work Summary**:
  - **WriteTxn.put() operation** fully specified with 7-step algorithm
  - **Duplicate handling** documented with last-write-wins semantics within transaction
  - **Size tracking** explained with incremental byte counting
  - **Performance characteristics** analyzed (O(1) amortized, buffered writes)
  - **Error handling** detailed (KeyTooLarge, ValueTooLarge, TxnClosed)

  **Key Deliverables**:
  - put() algorithm with duplicate detection and size tracking
  - PendingOpsMap mutation buffer strategy
  - Size increment calculation (key + value + overhead bytes)
  - Last-write-wins within single transaction
  - Write buffering until commit (no immediate disk I/O)
  - Transaction state validation (Active only)
  - Memory size limit enforcement
  - Testing requirements (unit, integration, property tests)
  - Invariants (idempotency, ordering, size limits)
  - Rust implementation guidance

- [x] **4.8** Create `04-txn-delete.md` - **[DONE]**
  - **DESCRIBE**: Delete operation
  - **EXPLAIN**: Tombstone handling
  - **Completed**: 2026-01-04 (commit 41d51dd)
  - **Blockers**: None - completed successfully

  **Work Summary**:
  - **WriteTxn.delete() operation** fully specified with tombstone semantics
  - **Key existence validation** with immediate error returns
  - **Pending deletion tracking** using DeleteSet for delayed execution
  - **Double-delete protection** idempotent behavior within transaction
  - **Read-after-write consistency** delete visible to same transaction
  - **Memory efficiency** DeleteSet smaller than PendingOpsMap
  - **State validation** Active transaction enforcement

  **Key Deliverables**:
  - delete() algorithm with 7-step validation and tracking flow
  - Tombstone marker strategy for deleted keys
  - DeleteSet data structure for efficient pending deletions
  - Idempotent delete semantics (second delete no-ops)
  - Transaction-local visibility (delete visible to same txn)
  - Error handling (KeyNotFound, KeyTooLarge, TxnClosed)
  - Testing requirements (unit, integration, property tests)
  - Invariants (idempotency, ordering, cascade behavior)
  - Rust implementation guidance

- [x] **4.9** Create `04-txn-commit.md` - **[DONE]**
  - **DESCRIBE**: Two-phase commit steps
  - **EXPLAIN**: Atomicity guarantees
  - **LIST**: What happens in each phase
  - **DESCRIBE**: Fsync ordering (log → meta → database)
  - **EXPLAIN**: Crash recovery points
  - **Completed**: 2026-01-04 (commit 6e746b3)
  - **Blockers**: None - completed successfully

  **Work Summary**:
  - **5-phase commit protocol** fully specified (Prepare, Apply, Append, Meta, Finalize)
  - **Fsync ordering** documented with critical durability guarantees (log → meta → database)
  - **Crash recovery analysis** for each phase with 3 recovery scenarios
  - **Commit flow** detailed with step-by-step algorithms for each phase
  - **Error handling** comprehensive with rollback logic and state transitions
  - **Meta page A/B flip** mechanism explained for atomicity
  - **Commit record creation** detailed with binary format reference

  **Key Deliverables**:
  - commit() function specification with 5-phase algorithm
  - CommitPhase enum with monotonic ordering (Prepare → Apply → Append → Meta → Finalize → Committed)
  - CommitError structured error type with thiserror
  - CommitContext for tracking commit state across phases
  - Crash recovery scenarios: Prepare/Apply (no durable state), Append (replay record), Meta/Finalize (committed)
  - Recovery algorithm with 6 steps (find meta, scan log, verify, replay, rebuild snapshots, resume)
  - Fsync ordering invariants (log fsync before meta fsync is CRITICAL)
  - Rust implementation guidance with type definitions and concurrency patterns
  - 40+ test scenarios across unit, integration, property, hardening, concurrency, and performance tests

- [x] **4.10** Create `04-txn-rollback.md` - **[DONE]**
  - **DESCRIBE**: Rollback process
  - **LIST**: Cleanup steps
  - **EXPLAIN**: State transition on rollback
  - **DESCRIBE**: Resource release (locks, buffers, handles)
  - **EXPLAIN**: Implicit rollback via Drop trait
  - **DESCRIBE**: Error rollback from failed commit
  - **Completed**: 2026-01-04 (commit 24a026c)
  - **Blockers**: None

  **Work Summary**:
  - **Explicit rollback** fully documented with rollback() method specification
  - **Implicit rollback** via Drop trait detailed with automatic cleanup on scope exit
  - **Rollback from commit errors** explained with partial commit handling and recovery considerations
  - **Resource cleanup** comprehensive (mutation buffers, write lock, transaction registry, handles)
  - **State transitions** documented (Active → RolledBack transition with idempotency)
  - **Error rollback scenarios** detailed (prepare phase, apply phase, append phase, meta phase)
  - **Testing requirements** specified (unit, integration, panic safety, property tests)

  **Key Deliverables**:
  - rollback() function specification with 7-step cleanup algorithm
  - Drop trait implementation for implicit rollback with panic safety
  - Rollback from commit errors with 4 phase-specific handling strategies
  - Resource cleanup sequence (mutation buffers → write lock → registry → metrics)
  - State transition validation (Active only, idempotent RolledBack)
  - RollbackError structured error type with thiserror
  - Recovery analysis for partial commits (WAL cleanup, orphan detection)
  - Thread-safety analysis (write lock release, panic safety)
  - Rust implementation guidance with Drop, panic safety, and testing strategies
  - 40+ test scenarios covering explicit, implicit, error rollback, concurrency, and property tests

- [x] **4.11** Create `04-txn-conflict.md` - **[DONE]**
  - **DESCRIBE**: Conflict detection
  - **EXPLAIN**: Write-write conflict rules
  - **DESCRIBE**: Retry strategy
  - **Completed**: 2026-01-04 (commit 43f8de0)
  - **Blockers**: None

  **Work Summary**:
  - **3-phase conflict detection algorithm** documented (track reads, detect conflicts, retry logic)
  - **Write-write conflict rules** specified with key-based detection and txn_id ordering
  - **Read-write conflict detection** explained with detectable vs non-detectable scenarios
  - **Retry strategy** with exponential backoff (100ms base, 2x multiplier, 10s max, 10 attempts)
  - **Read/write tracking** in ReadTxn/WriteTxn with HashMap-based sets
  - **Isolation level semantics** (ReadCommitted vs Serializable tracking differences)
  - **20+ test scenarios** covering conflicts, retries, edge cases, and isolation levels

- [x] **4.12** Create `04-txn-serialize.md` - **[DONE]**
  - **DESCRIBE**: CommitRecord serialization
  - **EXPLAIN**: Binary format
  - **Completed**: 2026-01-04 (commit 1918481)
  - **Blockers**: None

  **Work Summary**:
  - **Complete serialization format** documented with CommitPayloadHeader (32 bytes) and EncodedOperations
  - **Binary layout** specified byte-by-byte with offsets, sizes, and byte orders
  - **Put/Delete operation encoding** fully detailed (op_type, flags, key_len, val_len, key_bytes, val_bytes)
  - **serializeCommitRecord algorithm** with 7-step process (size, allocate, header, operations, return)
  - **deserializeCommitRecord algorithm** with 9-step validation and reconstruction flow
  - **Checksum calculation** using CRC32C over payload only (separate from WAL checksum)
  - **Complete example** with hex dump showing 3-operation transaction (82 bytes)
  - **Size calculations** and limits documented (max 16.7GB theoretical, practical limits apply)
  - **Layer separation** clarified (transaction serialization vs WAL record framing)
  - **Rust implementation** with type definitions, serialization/deserialization functions, testing
  - **50+ test scenarios** across unit, integration, property, WAL integration, and validation tests

- [x] **4.13** Create `04-txn-state.md` - **[DONE]**
  - **LIST**: TransactionState variants
  - **DESCRIBE**: Valid state transitions
  - **Completed**: 2026-01-04 (commit 70f0f3c)
  - **Blockers**: None

  **Work Summary**:
  - **TransactionState enum** fully specified with 4 variants (Active, Preparing, Committed, Aborted)
  - **State machine responsibilities** documented (transition enforcement, operation validation, recovery support)
  - **Valid state transitions** detailed with diagrams (Active→Preparing, Preparing→Committed, Active/Preparing→Aborted)
  - **Operation-state matrix** created showing which operations allowed in each state
  - **State validation rules** specified for all transaction operations (put, delete, get, scan, prepare, commit, abort)
  - **Terminal state properties** explained (no transitions out, no operations allowed, resource cleanup)
  - **Concurrency considerations** documented (single-threaded state, no synchronization needed)
  - **Error handling** specified with InvalidState error type
  - **Rust implementation** provided with enum definition, state field integration, validation functions
  - **50+ test scenarios** across unit, integration, property, and hardening tests

  **Key Deliverables**:
  - TransactionState enum with Debug, Clone, Copy, PartialEq, Eq traits
  - State transition diagram with all valid and invalid transitions
  - Operation validation rules (mutations in Active only, commit in Preparing only, abort in Active/Preparing)
  - State initialization (always starts as Active)
  - State termination (Committed/Aborted are terminal)
  - Concurrency model (single-threaded, no locks needed)
  - State machine implementation with validation and transition functions
  - State predicates (is_active, is_preparing, is_committed, is_aborted, is_terminal, is_mutable)
  - InvalidState error type with state and required fields
  - Complete testing strategy with state machine invariants

- [x] **4.14** Create `04-txn-concurrency.md` - **[DONE]**
  - **DESCRIBE**: Concurrent transaction handling
  - **EXPLAIN**: Visibility rules
  - **Completed**: 2026-01-04 (commit b15f188)
  - **Blockers**: None

  **Work Summary**:
  - **Concurrent transaction handling** fully documented with lock strategy and synchronization
  - **Visibility rules** specified for read-read, read-write, write-write scenarios
  - **Reader-writer lock** documented with RwLock for shared/exclusive access
  - **Transaction registry** explained for active transaction tracking and cleanup
  - **Single-writer guarantee** enforced via exclusive write lock
  - **Concurrency model** with unlimited readers, single writer, non-blocking reads
  - **Lock contention** handling with retry strategy and deadlock prevention
  - **Thread safety** analysis with Send/Sync bounds for transaction types
  - **20+ test scenarios** covering concurrent reads, writes, conflicts, and edge cases

- [x] **4.15** Create `04-txn-tests.md` - **[DONE]**
  - **LIST**: Isolation level tests
  - **DESCRIBE**: Concurrency test patterns
  - **Completed**: 2026-01-04 (commit 92c076c)
  - **Blockers**: None - comprehensive transaction test specification complete

**Work Summary**:
- **6 test categories** documented (unit, isolation, concurrency, hardening, performance, integration)
- **80+ test scenarios** specified across all categories
- **Isolation level tests** defined for ReadCommitted and Serializable
- **Concurrency patterns** documented with race condition detection
- **Test implementation** guidance provided for Rust

**Key Deliverables**:
- Basic transaction operations (begin, commit, rollback, read-your-writes)
- Isolation level tests (dirty reads, non-repeatable reads, phantom reads)
- Concurrency tests (readers scaling, single writer, conflicts, deadlocks)
- State machine tests (valid transitions, invalid transitions, recovery)
- Hardening tests (crash during commit, rollback on error, orphan cleanup)
- Performance tests (throughput, latency, contention)
- Property-based tests with invariants
- Test utilities and helpers

**Phase 4 Complete**: All 15 tasks finished. Transaction System fully specified.

---

## Phase 5: Snapshot/MVCC (10 tasks)

- [x] **5.1** Create `05-snapshot-overview.md` - **[DONE]**
  - **DESCRIBE**: MVCC design
  - **EXPLAIN**: Snapshot purpose
  - **Completed**: 2026-01-04 (commit 978fa06)
  - **Blockers**: None - comprehensive snapshot overview specification complete

- [x] **5.2** Create `05-snapshot-registry.md` - **[DONE]**
  - **DESCRIBE**: SnapshotRegistry implementation
  - **EXPLAIN**: Snapshot bookkeeping
  - **Completed**: 2026-01-04 (commit e1a9a71)
  - **Blockers**: None

  **Work Summary**:
  - **SnapshotRegistry struct** fully specified with 4 fields (allocator, snapshots HashMap, current_txn_id, current_root_page_id)
  - **SnapshotStats type** defined for monitoring (4 fields: total_snapshots, current_txn_id, oldest_txn_id, newest_txn_id)
  - **8 public functions** documented (init, deinit, registerSnapshot, getSnapshotRoot, getLatestSnapshot, getCurrentTxnId, hasSnapshot, cleanupOldSnapshots, getStats)
  - **MVCC bookkeeping** explained with transaction ID to root page ID mapping
  - **6 core invariants** documented (genesis exists, monotonic current, consistency, valid page IDs, ordering, no duplicates)

  **Key Deliverables**:
  - SnapshotRegistry type definition with HashMap<u64, u64> for snapshot mapping
  - init() algorithm with genesis snapshot initialization
  - registerSnapshot() for new committed transactions with monotonic ID check
  - getSnapshotRoot() with special handling for future txn_ids (returns current)
  - cleanupOldSnapshots() with two-parameter garbage collection (keep_txns, keep_count)
  - hasSnapshot() for existence checking
  - getStats() for monitoring and introspection
  - Rust implementation guidance with concurrency strategy (RwLock vs DashMap)
  - 50+ test scenarios across unit, property, and integration tests
  - Performance analysis (O(1) reads, O(1) writes, O(n) cleanup)
  - Memory overhead estimation (~32-40 bytes per snapshot)

- [x] **5.3** Create `05-snapshot-create.md` - **[DONE]**
  - **DESCRIBE**: Snapshot creation process
  - **EXPLAIN**: What gets captured
  - **Completed**: 2026-01-04 (commit c55f3e5)
  - **Blockers**: None

  **Work Summary**:
  - **3 snapshot creation methods** documented (latest, at txn_id, at timestamp)
  - **Copy-on-write design** explained with O(1) complexity and zero data copying
  - **Snapshot handle structure** defined (txn_id, root_page_id, db reference, ~24 bytes)
  - **Registration process** specified with reference counting for garbage collection prevention
  - **5 error types** documented (TransactionNotFound, TransactionInFuture, TransactionExpired, DatabaseClosed, RegistryCorrupt)
  - **Concurrency considerations** analyzed for parallel snapshot creation, commit interaction, and GC interaction

  **Key Deliverables**:
  - snapshot() / begin_read() algorithm for latest transaction snapshot
  - snapshot_at(txn_id) / begin_read_at(txn_id) for historical snapshots
  - snapshot_at_time(timestamp) for wall-clock time-based snapshots
  - State capture: txn_id (8B), root_page_id (8B), db reference (8B pointer)
  - Registration algorithm with atomic reference count increment/decrement
  - Unregistration via Drop trait with automatic cleanup trigger
  - SnapshotError enum with 5 variants using thiserror
  - Rust implementation guidance with RwLock strategy
  - Performance targets: O(1) creation, clone, and drop
  - 20+ test scenarios across unit, property, and integration tests

- [x] **5.4** Create `05-snapshot-vis.md` - **[DONE]**
  - **DESCRIBE**: Visibility calculation
  - **EXPLAIN**: Commit timestamp tracking
  - **Completed**: 2026-01-04 (commit TBD)
  - **Blockers**: None

  **Work Summary**:
  - **Visibility calculation algorithm** fully specified with 3-tier lookup strategy
  - **MVCC visibility rules** documented with transaction ID comparison logic
  - **5 visibility outcomes** defined (Visible, Invisible, CommittedAfter, Deleted, NotExist)
  - **B+tree version tracking** explained with root page ID mapping
  - **Timestamp ordering** specified with monotonic transaction ID semantics
  - **8 visibility scenarios** documented across read/write patterns

  **Key Deliverables**:
  - isVisible() algorithm with 5-step decision process (snapshot txn_id, record txn_id, deletion check, root page verification, visibility determination)
  - MVCC visibility rules with transaction ID comparison (record_txn_id <= snapshot_txn_id for visibility)
  - Deleted key handling with tombstone detection and transaction ID comparison
  - B+tree version navigation using SnapshotRegistry for root page ID lookup
  - Commit timestamp tracking via transaction ID monotonicity
  - Concurrent read visibility explained (readers see consistent snapshot regardless of concurrent writes)
  - Performance analysis: O(1) visibility check, O(log n) B+tree traversal
  - Rust implementation guidance with lifetime parameters and Arc<Snapshot> sharing
  - 40+ test scenarios covering visibility rules, edge cases, and concurrency
  - Invariants documented (snapshot consistency, transaction ordering, deletion semantics)

- [x] **5.5** Create `05-snapshot-cleanup.md` - **[DONE]**
  - **DESCRIBE**: Snapshot expiration
  - **EXPLAIN**: Garbage collection
  - **Completed**: 2026-01-04 (commit 1a9055f)
  - **Blockers**: None

  **Work Summary**:
  - **Snapshot expiration and cleanup** fully specified with retention policy strategies
  - **4 CleanupPolicy variants** documented (CountBased, AgeBased, Hybrid, Manual)
  - **CleanupStats structure** defined with 6 metrics (total_snapshots, cleaned_snapshots, skipped_snapshots, oldest_txn_id, newest_txn_id, cleanup_duration_ms)
  - **Reference counting** explained with atomic increments/decrements and Drop trait integration
  - **3 cleanup functions** specified (shouldCleanupSnapshot, cleanupSnapshots, cleanupExpiredSnapshots)
  - **Garbage collection algorithm** detailed with 6-step process (calculate threshold, identify candidates, check references, remove entries, deallocate pages, update stats)
  - **Cleanup triggering** documented (manual calls, automatic after commits, threshold-based)
  - **Retention policies** comprehensive with configurable limits and safety checks
  - **Concurrency considerations** analyzed (RwLock strategy, no blocking of readers)
  - **Edge cases** handled (genesis snapshot protection, active snapshots, minimum retention)

  **Key Deliverables**:
  - CleanupPolicy enum with 4 variants (CountBased { min_keep }, AgeBased { max_age_seconds }, Hybrid { min_keep, max_age_seconds }, Manual)
  - CleanupStats struct for monitoring and introspection
  - shouldCleanupSnapshot(policy, snapshot_id, reference_count, current_timestamp) decision function
  - cleanupSnapshots(policy, force_cleanup) main entry point with 6-step algorithm
  - cleanupExpiredSnapshots(threshold_txn_id) helper for simple count-based cleanup
  - Reference counting with Arc<SnapshotHandle> for automatic tracking
  - Genesis snapshot protection (txn_id 0 never cleaned)
  - Minimum retention enforcement (always keep N most recent snapshots)
  - Safety checks (don't clean active snapshots, respect reference counts)
  - Rust implementation guidance with RwLock and atomic operations
  - 40+ test scenarios covering unit, integration, property, and performance tests
  - Invariants documented (reference count accuracy, monotonic cleanup, safety)

- [x] **5.6** Create `05-snapshot-state.md` - **[DONE]**
  - **LIST**: SnapshotState fields
  - **DESCRIBE**: LSN range tracking
  - **Completed**: 2026-01-04 (commit 4904b83)
  - **Blockers**: None

  **Work Summary**:
  - **SnapshotState internal structure** fully specified with 6 core fields
  - **LSN range tracking** documented with visible_lsn (start) and last_committed_lsn (end)
  - **Metadata persistence** explained with 8 fields (txn_id, root_page_id, timestamp, reference_count, state, creation_order, cleanup_eligible, snapshot_metadata)
  - **State lifecycle** detailed with 4 transitions (Initializing → Active → Quiescent → CleanupEligible)
  - **Memory layout** specified at 72 bytes with field-level breakdown
  - **Concurrency semantics** defined for state transitions and read operations
  - **Atomic operations** documented for reference counting and state updates
  - **5 accessor methods** specified (get_txn_id, get_root_page_id, get_visible_range, get_reference_count, get_state)
  - **3 mutation methods** defined (increment_reference, decrement_reference, mark_for_cleanup)
  - **State validation** explained with invariants (txn_id monotonicity, reference count accuracy, LSN ordering)
  - **Snapshot metadata** extensible via HashMap<String, Vec<u8>> for custom attributes
  - **Creation order tracking** with 64-bit sequence for FIFO cleanup policies
  - **Thread safety** guaranteed with atomic operations and appropriate memory ordering

  **Key Deliverables**:
  - SnapshotState struct with 6 core fields (txn_id, root_page_id, visible_lsn, last_committed_lsn, creation_timestamp, snapshot_state)
  - LSN range tracking with visible_lsn (8B) and last_committed_lsn (8B)
  - SnapshotState enum with 4 variants (Initializing, Active, Quiescent, CleanupEligible)
  - Atomic reference counting with AtomicU64 and fetch_add/fetch_sub operations
  - State transition validation with isValidStateTransition() function
  - Memory layout specification (72 bytes total, field-by-field breakdown)
  - 8 accessor and mutation methods with thread-safe implementations
  - Rust implementation guidance with atomics, Ordering constraints, and derive traits
  - Concurrency analysis (read-heavy workloads, no blocking on state reads)
  - 20+ test scenarios covering state transitions, LSN tracking, reference counting, and edge cases
  - Invariants documented (transaction ID monotonicity, LSN ordering, reference count accuracy, state machine validity)

- [x] **5.7** Create `05-mvcc-isolation.md` - **[DONE]**
  - **DESCRIBE**: Isolation guarantees
  - **EXPLAIN**: Anomaly prevention
  - **Completed**: 2026-01-04 (commit 5edb4c9)
  - **Blockers**: None

  **Work Summary**:
  - **Isolation guarantees** fully documented (Snapshot Isolation with single-writer)
  - **Anomaly prevention** explained for dirty reads, non-repeatable reads, lost updates, read skew
  - **Isolation level formalization** with SI definition and guarantees
  - **Concurrent operation examples** with detailed timelines
  - **Write serialization** through commit log ordering
  - **Rust implementation guidance** provided
  - **Test scenarios** for isolation validation
  - **V0 limitations** documented with future multi-writer support

  **Key Deliverables**:
  - Snapshot Isolation definition with single-writer guarantee
  - Anomaly prevention mechanisms (4 anomalies explained)
  - Concurrent operation timeline examples
  - Visibility rules and transaction ID ordering
  - Write serialization through commit log
  - Rust implementation patterns
  - Isolation test scenarios
  - V0 limitations and future enhancements

- [x] **5.8** Create `05-mvcc-readers.md` - **[DONE]**
  - **DESCRIBE**: Reader handling
  - **EXPLAIN**: Reader scalability
  - **Completed**: 2026-01-04
  - **Blockers**: None

  **Work Summary**:
  - **Reader lifecycle management** fully documented with registration, active tracking, and cleanup
  - **ReaderState enum** specified with 4 variants (Registered, Active, Quiescent, Unregistered)
  - **ReaderRegistry structure** defined with HashMap-based tracking and statistics
  - **Reader tracking** detailed with 5 metadata fields (reader_id, txn_id, start_lsn, current_lsn, state)
  - **6 core functions** documented (registerReader, unregisterReader, getReader, getActiveReaders, updateReaderLsn, getReaderStats)
  - **Scalability strategy** explained with lock-free reads and bounded write contention
  - **Resource reclamation** specified with epoch-based reclamation and unblocking mechanisms

  **Key Deliverables**:
  - ReaderState enum with 4 states and valid transitions
  - ReaderRegistry with HashMap<u64, ReaderState> and atomic counters
  - ReaderStats structure with 5 metrics (total_readers, active_readers, quiescent_readers, oldest_start_lsn, newest_start_lsn)
  - registerReader() algorithm with unique ID generation and state initialization
  - unregisterReader() with state transition to Unregistered and stats cleanup
  - getActiveReaders() filtering for active readers only
  - updateReaderLsn() for LSN advancement tracking
  - getReaderStats() for monitoring and introspection
  - Epoch-based reclamation for safe cleanup without blocking readers
  - Scalability analysis (O(1) ops, lock-free reads, bounded writes)
  - Thread-safety analysis with RwLock strategy
  - 30+ test scenarios covering lifecycle, state transitions, and concurrency

- [x] **5.9** Create `05-mvcc-serialization.md` - **[DONE]**
  - **DESCRIBE**: Snapshot persistence format - Explain how snapshots are serialized to disk
  - **EXPLAIN**: Binary layout - Detail the byte-by-byte format of persisted snapshot data
  - **LIST**: Fields included in serialization - Specify what snapshot metadata gets persisted
  - **EXPLAIN**: Deserialization process - Describe how snapshots are reconstructed from disk
  - **DEFINE**: Rust serialization approach - Specify the serialization strategy (e.g., bincode, manual)
  - **Completed**: 2026-01-04 (commit dcea27f)
  - **Blockers**: None - spec complete with binary format, encode/decode algorithms, error handling

  **Work Summary**:
  - **Binary format** defined with 72-byte header + 16 bytes per snapshot entry
  - **Little-endian encoding** for all multi-byte integers (x86_64 optimization)
  - **CRC-32 checksum** for integrity verification (1 in 4 billion undetected error rate)
  - **Magic number** (0x4E53544D54535054 "NSTSNAPT") for format identification
  - **Version field** (1) for future format evolution
  - **Reserved space** (32 bytes) for forward compatibility

  **Serialization Process**:
  - O(N) time complexity where N is snapshot count
  - 7-step encode algorithm with validation, allocation, header/metadata/entry writing, and checksum computation
  - Single atomic write + fsync for durability
  - Crash-safe: old data remains valid if fsync fails

  **Deserialization Process**:
  - 9-step decode algorithm with multi-layer validation (magic, version, checksum, size, invariants)
  - Detailed error reporting for each failure mode
  - Graceful corruption handling with 3 recovery strategies:
    1. Rebuild from WAL (primary fallback)
    2. Use previous snapshot backup (if available)
    3. Initialize empty database (last resort)

  **Rust Implementation**:
  - Recommended crate: bincode for serialization (ergonomic, efficient, well-tested)
  - Alternative: Manual serialization with byteorder crate (more control, zero dependencies)
  - crc32fast for checksum computation (hardware-accelerated)
  - Complete type definitions for SerializedSnapshot struct
  - Error types with thiserror: TruncatedData, InvalidMagic, UnsupportedVersion, ChecksumMismatch, CorruptedData
  - Disk I/O integration functions (write_snapshot, read_snapshot)
  - Testing strategy with unit tests (round-trip, validation), property tests (invariants), and integration tests (persistence, crash recovery)

- [ ] **5.10** Create `05-mvcc-tests.md`
  - **LIST**: Test scenarios

---

## Phase 6: B+Tree Implementation (18 tasks)

- [ ] **6.1** Create `06-btree-overview.md`
  - **DESCRIBE**: B+tree design decisions
  - **LIST**: Node types and operations

- [ ] **6.2** Create `06-btree-node.md`
  - **DESCRIBE**: Internal node structure
  - **DESCRIBE**: Leaf node structure
  - **EXPLAIN**: Differences between node types

- [ ] **6.3** Create `06-btree-header.md`
  - **LIST**: NodeHeader fields with offsets and sizes
  - **EXPLAIN**: Purpose of each field
  - **DESCRIBE**: Node metadata

- [ ] **6.4** Create `06-btree-search.md`
  - **DESCRIBE**: Binary search algorithm
  - **EXPLAIN**: Key comparison logic

- [ ] **6.5** Create `06-btree-insert.md`
  - **DESCRIBE**: Insert operation flow
  - **EXPLAIN**: Split propagation

- [ ] **6.6** Create `06-btree-split.md`
  - **DESCRIBE**: Node split algorithm
  - **EXPLAIN**: Split point selection

- [ ] **6.7** Create `06-btree-delete.md`
  - **DESCRIBE**: Delete operation
  - **EXPLAIN**: Underflow handling

- [ ] **6.8** Create `06-btree-merge.md`
  - **DESCRIBE**: Merge algorithm
  - **EXPLAIN**: Merge conditions

- [ ] **6.9** Create `06-btree-borrow.md`
  - **DESCRIBE**: Borrow from sibling
  - **EXPLAIN**: Redistribution strategy

- [ ] **6.10** Create `06-btree-grow.md`
  - **DESCRIBE**: Tree growth (root split)
  - **EXPLAIN**: Height increase

- [ ] **6.11** Create `06-btree-shrink.md`
  - **DESCRIBE**: Tree shrink (root merge)
  - **EXPLAIN**: Height decrease

- [ ] **6.12** Create `06-btree-scan.md`
  - **DESCRIBE**: Range scan algorithm
  - **EXPLAIN**: Iteration strategy

- [ ] **6.13** Create `06-btree-iterator.md`
  - **DESCRIBE**: Iterator state machine
  - **EXPLAIN**: Stack-based traversal

- [ ] **6.14** Create `06-btree-key.md`
  - **DESCRIBE**: Key encoding
  - **EXPLAIN**: Ordering guarantees

- [ ] **6.15** Create `06-btree-value.md`
  - **DESCRIBE**: Value storage strategy
  - **EXPLAIN**: Inline vs overflow pages

- [ ] **6.16** Create `06-btree-delta.md`
  - **DESCRIBE**: Uncommitted change tracking
  - **EXPLAIN**: Delta layer

- [ ] **6.17** Create `06-btree-recovery.md`
  - **DESCRIBE**: B+tree recovery from WAL
  - **EXPLAIN**: Rebuild algorithm

- [ ] **6.18** Create `06-btree-tests.md`
  - **LIST**: Test cases
  - **EXPLAIN**: Invariant checking

---

## Phase 7: Public API (10 tasks)

- [ ] **7.1** Create `07-db-overview.md`
  - **DESCRIBE**: Public API design
  - **LIST**: User-facing types

- [ ] **7.2** Create `07-db-struct.md`
  - **LIST**: Db struct fields
  - **EXPLAIN**: Builder pattern

- [ ] **7.3** Create `07-db-open.md`
  - **DESCRIBE**: Database opening process
  - **LIST**: Open options

- [ ] **7.4** Create `07-db-read.md`
  - **DESCRIBE**: Read transaction creation
  - **LIST**: Read API methods

- [ ] **7.5** Create `07-db-write.md`
  - **DESCRIBE**: Write transaction creation
  - **LIST**: Write API methods

- [ ] **7.6** Create `07-db-close.md`
  - **DESCRIBE**: Shutdown sequence
  - **EXPLAIN**: Resource cleanup

- [ ] **7.7** Create `07-db-config.md`
  - **LIST**: All configuration options
  - **DESCRIBE**: Validation rules

- [ ] **7.8** Create `07-db-errors.md`
  - **LIST**: Error categories
  - **DESCRIBE**: When each error occurs

- [ ] **7.9** Create `07-db-async.md`
  - **DESCRIBE**: Async considerations
  - **EXPLAIN**: Trade-offs

- [ ] **7.10** Create `07-db-tests.md`
  - **LIST**: Integration test scenarios

---

## Phase 8: Reference Model (8 tasks)

- [ ] **8.1** Create `08-refmodel-overview.md`
  - **DESCRIBE**: Reference model purpose

- [ ] **8.2** Create `08-refmodel-struct.md`
  - **DESCRIBE**: In-memory structure

- [ ] **8.3** Create `08-refmodel-ops.md`
  - **DESCRIBE**: Operations (get/put/delete)

- [ ] **8.4** Create `08-refmodel-snapshot.md`
  - **DESCRIBE**: Historical state tracking

- [ ] **8.5** Create `08-refmodel-compare.md`
  - **DESCRIBE**: Equivalence checking

- [ ] **8.6** Create `08-refmodel-serialize.md`
  - **DESCRIBE**: Persistence format

- [ ] **8.7** Create `08-refmodel-fuzz.md`
  - **DESCRIBE**: Fuzz integration

- [ ] **8.8** Create `08-refmodel-tests.md`
  - **LIST**: Validation scenarios

---

## Phase 9-15: (Same Pattern Continues)

**Template for each task**:
- **DESCRIBE**: The component's purpose and behavior
- **LIST**: All types, functions, constants, invariants
- **EXPLAIN**: Algorithms in step-by-step plain English
- **DEFINE**: Rust implementation approach

---

## Output Format: Template for Each Markdown File

```markdown
# [Title]

## Purpose
[Plain English description of what this component does and why it exists]

## Types

### TypeName
**Description**: [What this type represents]
**Fields**:
- field_name: Type - [Purpose and invariants]
- field_name: Type - [Purpose and invariants]

**Size**: [Total size in bytes, if applicable]
**Alignment**: [Alignment requirements, if applicable]
**Invariants**: [What must always be true]

### AnotherTypeName
[Same structure as above]

## Functions

### function_name(parameters)

**Purpose**: [What this function does]
**Parameters**:
- param1: Type - [Description]
- param2: Type - [Description]

**Returns**: Type - [Description of return value]

**Algorithm**:
1. First step description
2. Second step description
3. Third step description

**Error Conditions**:
- ErrorType: [When this error occurs]
- ErrorType: [When this error occurs]

**Concurrency**: [Thread-safety guarantees]

## Invariants
- [Invariant 1 description]
- [Invariant 2 description]

## Dependencies
- **Uses**: [Other modules this depends on]
- **Used by**: [Other modules that depend on this]

## Rust Implementation Guidance

### Module Structure
The Rust module should be organized as follows: [Description]

### Type Definitions
- **StructName**: Should use #[repr(C)] to match binary format
- **EnumName**: Should be represented as enum with variants
- **Choice**: Use Arc<[u8]> instead of Vec<u8> for [reason]

### Concurrency
- **Pattern**: Use RwLock because [reason]
- **Pattern**: Use Mutex instead of RwLock for [reason]

### Key Decisions
- **Option A vs Option B**: Choose A because [explanation]
- **Library X vs Library Y**: Use X because [explanation]

### Implementation Notes
- Step 1: [Rust-specific consideration]
- Step 2: [Rust-specific consideration]
- Step 3: [Rust-specific consideration]

### Testing Strategy
**Unit tests needed for**:
- [Test case 1]
- [Test case 2]

**Property tests for**:
- [Property 1]
- [Property 2]

**Integration scenarios**:
- [Scenario 1]
- [Scenario 2]
```

---

## Summary

**Total tasks: 214**

Each task produces a **100% natural language** markdown file that includes:
1. **Plain English descriptions** of all types, functions, algorithms
2. **Complete specifications** in prose form (field names, types, sizes)
3. **Step-by-step explanations** of all logic and algorithms
4. **Rust implementation guidance** described in words

**NO CODE WHATSOEVER** - No Zig snippets, no Rust snippets, no code blocks. Just natural language specifications that a Rust developer can read and implement from.

A Rust developer with ZERO access to the Zig codebase must be able to implement the module solely from reading the natural language specification.
