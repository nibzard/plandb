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

- [ ] **3.6** Create `03-wal-encode.md`
  - **DESCRIBE**: Operation encoding format
  - **EXPLAIN**: Put operation encoding
  - **EXPLAIN**: Delete operation encoding
  - **DESCRIBE**: Varint encoding for lengths

- [ ] **3.7** Create `03-wal-decode.md`
  - **DESCRIBE**: Record decoding process
  - **EXPLAIN**: Error recovery on corruption
  - **DESCRIBE**: Partial read handling

- [ ] **3.8** Create `03-wal-truncate.md`
  - **DESCRIBE**: Truncation process
  - **EXPLAIN**: When truncation occurs
  - **DESCRIBE**: Coordination with Pager

- [ ] **3.9** Create `03-wal-replay.md`
  - **DESCRIBE**: Replay algorithm step-by-step
  - **EXPLAIN**: Error handling during replay
  - **LIST**: Recovery states

- [ ] **3.10** Create `03-wal-lsn.md`
  - **DESCRIBE**: LSN allocation
  - **EXPLAIN**: LSN persistence format
  - **DESCRIBE**: Gap detection

- [ ] **3.11** Create `03-wal-recovery.md`
  - **LIST**: Recovery states
  - **DESCRIBE**: State transitions
  - **EXPLAIN**: Corrupted WAL handling

- [ ] **3.12** Create `03-wal-tests.md`
  - **LIST**: Test scenarios (crash, corruption, etc.)
  - **DESCRIBE**: Crash simulation methods

---

## Phase 4: Transaction System (15 tasks)

- [ ] **4.1** Create `04-txn-overview.md`
  - **DESCRIBE**: Transaction semantics
  - **LIST**: Transaction types
  - **EXPLAIN**: ACID guarantees

- [ ] **4.2** Create `04-txn-context.md`
  - **LIST**: TransactionContext fields
  - **EXPLAIN**: Purpose of each field
  - **DESCRIBE**: Invariants

- [ ] **4.3** Create `04-read-txn.md`
  - **DESCRIBE**: ReadTxn implementation
  - **EXPLAIN**: Read-only guarantees
  - **LIST**: Required trait bounds (Send, Sync)

- [ ] **4.4** Create `04-write-txn.md`
  - **DESCRIBE**: WriteTxn implementation
  - **EXPLAIN**: Mutation tracking strategy
  - **DESCRIBE**: Transaction lifecycle

- [ ] **4.5** Create `04-txn-begin.md`
  - **DESCRIBE**: Transaction begin process
  - **EXPLAIN**: TxnId allocation

- [ ] **4.6** Create `04-txn-get.md`
  - **DESCRIBE**: Get operation read path
  - **EXPLAIN**: Read-your-writes implementation
  - **LIST**: Lookup order (snapshot, pending, btree)

- [ ] **4.7** Create `04-txn-put.md`
  - **DESCRIBE**: Put operation flow
  - **EXPLAIN**: Write buffering
  - **DESCRIBE**: Duplicate key handling

- [ ] **4.8** Create `04-txn-delete.md`
  - **DESCRIBE**: Delete operation
  - **EXPLAIN**: Tombstone handling

- [ ] **4.9** Create `04-txn-commit.md`
  - **DESCRIBE**: Two-phase commit steps
  - **EXPLAIN**: Atomicity guarantees
  - **LIST**: What happens in each phase

- [ ] **4.10** Create `04-txn-rollback.md`
  - **DESCRIBE**: Rollback process
  - **LIST**: Cleanup steps

- [ ] **4.11** Create `04-txn-conflict.md`
  - **DESCRIBE**: Conflict detection
  - **EXPLAIN**: Write-write conflict rules
  - **DESCRIBE**: Retry strategy

- [ ] **4.12** Create `04-txn-serialize.md`
  - **DESCRIBE**: CommitRecord serialization
  - **EXPLAIN**: Binary format

- [ ] **4.13** Create `04-txn-state.md`
  - **LIST**: TransactionState variants
  - **DESCRIBE**: Valid state transitions

- [ ] **4.14** Create `04-txn-concurrency.md`
  - **DESCRIBE**: Concurrent transaction handling
  - **EXPLAIN**: Visibility rules

- [ ] **4.15** Create `04-txn-tests.md`
  - **LIST**: Isolation level tests
  - **DESCRIBE**: Concurrency test patterns

---

## Phase 5: Snapshot/MVCC (10 tasks)

- [ ] **5.1** Create `05-snapshot-overview.md`
  - **DESCRIBE**: MVCC design
  - **EXPLAIN**: Snapshot purpose

- [ ] **5.2** Create `05-snapshot-registry.md`
  - **DESCRIBE**: SnapshotRegistry implementation
  - **EXPLAIN**: Snapshot bookkeeping

- [ ] **5.3** Create `05-snapshot-create.md`
  - **DESCRIBE**: Snapshot creation process
  - **EXPLAIN**: What gets captured

- [ ] **5.4** Create `05-snapshot-vis.md`
  - **DESCRIBE**: Visibility calculation
  - **EXPLAIN**: Commit timestamp tracking

- [ ] **5.5** Create `05-snapshot-cleanup.md`
  - **DESCRIBE**: Snapshot expiration
  - **EXPLAIN**: Garbage collection

- [ ] **5.6** Create `05-snapshot-state.md`
  - **LIST**: SnapshotState fields
  - **DESCRIBE**: LSN range tracking

- [ ] **5.7** Create `05-mvcc-isolation.md`
  - **DESCRIBE**: Isolation guarantees
  - **EXPLAIN**: Anomaly prevention

- [ ] **5.8** Create `05-mvcc-readers.md`
  - **DESCRIBE**: Reader handling
  - **EXPLAIN**: Reader scalability

- [ ] **5.9** Create `05-mvcc-serialization.md`
  - **DESCRIBE**: Snapshot persistence format

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
