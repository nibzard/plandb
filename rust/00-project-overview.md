# NorthstarDB Rust Migration: Project Overview

## 1. Project Vision and Goals

### 1.1 What is NorthstarDB?

NorthstarDB is a database built from scratch, designed for **massive read concurrency** and **deterministic replay**. The project follows a strict principle: **benchmarks and tests are the source of truth**.

**Original Vision**: Transform from a traditional embedded database into a **"Living Database"** with AI-driven intelligence that autonomously maintains, optimizes, and understands its own data using structured memory cartridges.

**Rust Migration Goals**:
- Preserve all functional correctness and performance characteristics
- Leverage Rust's safety guarantees and ecosystem
- Maintain the "benchmarks as truth" philosophy
- Enable broader adoption through Rust's popularity in systems programming
- Port comprehensive AI intelligence layer to Rust

### 1.2 Design Principles (from Zig)

- **Test-Driven Development**: All features start with test definitions
- **Don't Repeat Yourself**: Single source of truth for each piece of logic
- **Keep It Simple, Stupid**: Choose the simplest working solution
- **Domain-Driven Design**: Clear ubiquitous language and bounded contexts
- **State is Derived; The Log is Truth**: Commit stream is the source of all database state
- **Pay Coordination at Commit, Not on Every Read**: MVCC snapshots for readers

### 1.3 Core Constraints

- No DB implementation changes unless benchmarks and tests are green
- Performance claims must be proven with reproducible benchmarks
- Correctness first, proven continuously with property tests
- AI operations must not degrade core database performance
- Database remains functional even when AI services are unavailable

---

## 2. Zig Source File Inventory

### 2.1 Core Database Components (9 files)

| Zig File | Purpose |
|----------|---------|
| `src/db.zig` | Public database API scaffold providing Db, ReadTxn, WriteTxn types with two-phase commit |
| `src/pager.zig` | B+tree page management, file I/O, and physical storage layer with checksum validation |
| `src/page_cache.zig` | LRU page cache with pinning support for snapshot readers to reduce I/O |
| `src/txn.zig` | Transaction scaffolding with two-phase commit plumbing, mutation tracking, and commit record serialization |
| `src/snapshot.zig` | MVCC snapshot registry mapping transaction IDs to root page IDs for concurrent readers |
| `src/wal.zig` | Write-ahead log with record framing, checksums, and append-only durability |
| `src/replay.zig` | Deterministic replay engine for rebuilding database state from commit records |
| `src/ref_model.zig` | In-memory reference model for testing with snapshot bookkeeping and operation replay |
| `src/ref_model_v2.zig` | Alternative reference model implementation |

### 2.2 Testing and Validation (5 files)

| Zig File | Purpose |
|----------|---------|
| `src/hardening.zig` | Crash consistency tests including torn write simulation and corruption handling |
| `src/fuzz.zig` | Fuzzing harness for B+tree decode operations with valid/mutated corpus |
| `src/property_based.zig` | Property-based testing framework for database invariants and crash equivalence |
| `src/validator.zig` | B+tree validator CLI utility for debugging and invariant checking |
| `src/metamorphic.zig` | Metamorphic testing utilities for database behavior verification |

### 2.3 Benchmark Framework (9 files)

| Zig File | Purpose |
|----------|---------|
| `src/main.zig` | CLI entry point and benchmark harness with plugin management support |
| `src/bench/runner.zig` | Benchmark execution framework with configurable repeats and metrics collection |
| `src/bench/types.zig` | Common benchmark types including results, profiles, configurations, and metrics |
| `src/bench/compare.zig` | Baseline comparison and regression detection with threshold enforcement |
| `src/bench/suite.zig` | Benchmark suite registration for micro, macro, and hardening test categories |
| `src/bench/document_history_bench.zig` | Document history tracking performance benchmarks |
| `src/bench/storage_efficiency_bench.zig` | Storage efficiency measurement benchmarks |
| `src/bench/temporal_history_bench.zig` | Temporal history query performance benchmarks |
| `src/bench/timeseries_telemetry_bench.zig` | Time-series telemetry processing benchmarks |
| `src/bench/downsampling_comparison_bench.zig` | Downsampling algorithm comparison benchmarks |

### 2.4 AI/LLM Infrastructure (6 files)

| Zig File | Purpose |
|----------|---------|
| `src/llm/client.zig` | Provider-agnostic LLM interface supporting OpenAI, Anthropic, and local models |
| `src/llm/types.zig` | LLM type definitions including function schemas and provider configurations |
| `src/llm/function.zig` | Function calling interface with schema validation and result handling |
| `src/llm/orchestrator.zig` | LLM orchestration with deterministic function calling behavior |
| `src/llm/orchestrator_optimizer.zig` | Query optimization using LLM analysis for performance improvements |
| `src/llm/providers/openai.zig` | OpenAI API client with security validation and certificate handling |
| `src/llm/providers/anthropic.zig` | Anthropic Claude API client integration |
| `src/llm/providers/local.zig` | Local model API client for self-hosted LLMs |

### 2.5 Plugin System (17 files)

| Zig File | Purpose |
|----------|---------|
| `src/plugins/manager.zig` | Plugin lifecycle management with resource tracking and quota enforcement |
| `src/plugins/cli.zig` | Plugin management CLI for listing, testing, and debugging plugins |
| `src/plugins/sdk.zig` | Plugin SDK for developers to create custom database plugins |
| `src/plugins/entity_extractor.zig` | Entity extraction from text using LLM function calling |
| `src/plugins/code_relationships.zig` | Code relationship analysis and graph construction |
| `src/plugins/context_summarizer.zig` | Context summarization for code and documentation |
| `src/plugins/performance_bottleneck.zig` | Performance analysis plugin for bottleneck detection |
| `src/plugins/security_vulnerability.zig` | Security scanning plugin for vulnerability detection |
| `src/plugins/marketplace.zig` | Plugin marketplace integration for discovering and installing plugins |
| `src/plugins/embedding_generator.zig` | Embedding generation plugin for semantic search capabilities |
| `src/plugins/semantic_diff.zig` | Semantic code diff and comparison plugin |
| `src/plugins/query_profiler.zig` | Query performance profiling and optimization plugin |
| `src/plugins/perf_analyzer.zig` | Performance analysis plugin with detailed metrics |
| `src/plugins/debug.zig` | Debug utilities plugin for database introspection |
| `src/plugins/security.zig` | Security enforcement plugin for database access control |
| `src/plugins/packaging.zig` | Plugin packaging and distribution utilities |
| `src/plugins/testing.zig` | Plugin testing framework and utilities |

### 2.6 Structured Memory Cartridges (11 files)

| Zig File | Purpose |
|----------|---------|
| `src/cartridges/structured_memory.zig` | Entity-topic-relationship storage format for AI-extracted structured memory |
| `src/cartridges/admin.zig` | Administrative cartridge for database management tasks |
| `src/cartridges/pending_tasks.zig` | Task queue cartridge for agent-based task management |
| `src/cartridges/embeddings.zig` | Vector embedding storage and similarity search cartridge |
| `src/cartridges/temporal.zig` | Temporal data storage and time-series analysis cartridge |
| `src/cartridges/doc_history.zig` | Document history tracking and versioning cartridge |
| `src/cartridges/rebuild.zig` | Cartridge rebuilding and maintenance utilities |
| `src/cartridges/observability.zig` | Observability metrics and monitoring cartridge |
| `src/cartridges/entity.zig` | Entity management and relationship mapping cartridge |
| `src/cartridges/format.zig` | Cartridge format serialization and validation |
| `src/cartridges/migration.zig` | Cartridge migration and version upgrade utilities |

### 2.7 Query System (9 files)

| Zig File | Purpose |
|----------|---------|
| `src/queries/analytics.zig` | Advanced analytics query processing and aggregation |
| `src/queries/cache_warming.zig` | Query result caching and pre-warming strategies |
| `src/queries/natural_language.zig` | Natural language query processing and semantic understanding |
| `src/queries/optimizer.zig` | Query optimization with cost-based and rule-based strategies |
| `src/queries/patterns.zig` | Common query patterns and template utilities |
| `src/queries/planner.zig` | Query planning and execution strategy selection |
| `src/queries/prediction.zig` | Predictive query optimization using LLM analysis |
| `src/queries/predictive_optimizer.zig` | AI-powered predictive query optimizer |
| `src/queries/results.zig` | Query result processing and streaming utilities |
| `src/queries/router.zig` | Query routing based on type and optimization requirements |
| `src/queries/topic_based.zig` | Topic-based query organization and retrieval |

### 2.8 Autonomy and Self-Optimization (6 files)

| Zig File | Purpose |
|----------|---------|
| `src/autonomy/archival.zig` | Automatic data archival and tiered storage management |
| `src/autonomy/cartridge_builder.zig` | Automatic cartridge building from database patterns |
| `src/autonomy/patterns.zig` | Pattern detection and analysis for autonomous optimization |
| `src/autonomy/regression_detection.zig` | Performance regression detection and alerting |
| `src/autonomy/temporal_retention.zig` | Temporal data retention policy management |
| `src/autonomy/tiered_storage.zig` | Tiered storage management with automatic migration |

### 2.9 Observability and Monitoring (4 files)

| Zig File | Purpose |
|----------|---------|
| `src/observability/debug.zig` | Debug utilities and runtime introspection |
| `src/observability/index.zig` | Observability data indexing and query acceleration |
| `src/observability/metrics.zig` | Metrics collection and time-series storage |
| `src/observability/tracing.zig` | Distributed tracing for database operations |

### 2.10 Event System (3 files)

| Zig File | Purpose |
|----------|---------|
| `src/events/types.zig` | Event type definitions and schema definitions |
| `src/events/storage.zig` | Event persistence and replay storage |
| `src/events/index.zig` | Event indexing and fast lookup capabilities |

### 2.11 Security, Compliance, and Configuration (6 files)

| Zig File | Purpose |
|----------|---------|
| `src/security/ai_security.zig` | AI-specific security validation and prompt injection protection |
| `src/compliance/audit.zig` | Audit logging and compliance tracking |
| `src/feature_flags/ai_toggle.zig` | Feature flag management for AI capabilities |
| `src/migrations/vanilla.zig` | Database schema migration utilities |
| `src/cost/management.zig` | Cost management and budget tracking for AI operations |

### 2.12 Replication and Consensus (12 files)

| Zig File | Purpose |
|----------|---------|
| `src/replication/config.zig` | Replication configuration management |
| `src/replication/hardening.zig` | Replication system hardening and testing |
| `src/replication/index.zig` | Replication index management for conflict resolution |
| `src/replication/publisher.zig` | Change data capture and publishing |
| `src/replication/protocol.zig` | Replication protocol implementation |
| `src/replication/subscriber.zig` | Subscription management for replicated data |
| `src/replication/test.zig` | Replication system testing utilities |
| `src/consensus/config.zig` | Raft consensus configuration management |
| `src/consensus/hardening.zig` | Raft system hardening and testing |
| `src/consensus/index.zig` | Raft state machine indexing and querying |
| `src/consensus/raft.zig` | Raft consensus algorithm implementation |
| `src/consensus/rpc.zig` | Raft RPC communication protocol |
| `src/consensus/snapshot.zig` | Raft snapshot management and transfer |
| `src/consensus/test.zig` | Raft consensus testing utilities |

### 2.13 Visualization and Dashboards (2 files)

| Zig File | Purpose |
|----------|---------|
| `src/dashboards/builder.zig` | Dashboard building and visualization generation |
| `src/visualizations/generators.zig` | Visualization generators for data presentation |

**Total: 110+ Zig source files organized into 18 distinct categories**

---

## 3. Rust Project Structure Decision

### 3.1 Decision: Cargo Workspace with Multiple Crates

**Chosen Structure**: **Cargo Workspace**

#### Rationale

1. **Clear Separation of Concerns**
   - Each bounded context (DDD principle) becomes its own crate
   - Enforces modularity and prevents circular dependencies
   - Matches the existing Zig directory structure

2. **Independent Testing and Benchmarking**
   - Each crate can have its own test suite
   - Benchmark isolation mirrors the Zig approach
   - CI can run tests in parallel per crate

3. **Selective Dependency Management**
   - Core crate has minimal dependencies (like Zig)
   - AI features can opt-in to HTTP clients, JSON libraries
   - Users can disable AI features with feature flags

4. **Phased Migration**
   - Can port core functionality first
   - AI layer can be developed incrementally
   - Each crate can be validated independently

5. **Ecosystem Alignment**
   - Binary crate for CLI (`northstar-cli`)
   - Library crate for embedding (`northstar-core`)
   - Feature flags for optional capabilities

### 3.2 Workspace Structure

```
northstar-rust/
├── Cargo.toml                 # Workspace root
├── Cargo.lock                 # Locked dependency versions
├── benches/                   # Workspace-level benchmarks
│   └── cargo.toml config forCriterion
├── northstar-core/            # Core database engine
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── db.rs              # Db, ReadTxn, WriteTxn
│       ├── pager.rs           # Page allocation, I/O
│       ├── page_cache.rs      # LRU cache with pinning
│       ├── txn.rs             # Two-phase commit
│       ├── snapshot.rs        # MVCC snapshots
│       ├── wal.rs             # Write-ahead log
│       └── replay.rs          # Deterministic replay
├── northstar-btree/           # B+tree implementation (optional split)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── node.rs            # B+tree node structures
│       ├── tree.rs            # B+tree operations
│       └── cursor.rs          # Traversal and cursors
├── northstar-llm/             # LLM integration (feature-gated)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── client.rs          # Provider-agnostic interface
│       ├── function.rs        # Function calling
│       ├── orchestrator.rs    # LLM orchestration
│       └── providers/
│           ├── mod.rs
│           ├── openai.rs
│           ├── anthropic.rs
│           └── local.rs
├── northstar-plugins/         # Plugin system (feature-gated)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── manager.rs         # Plugin lifecycle
│       ├── sdk.rs             # Plugin SDK
│       └── plugins/
│           ├── mod.rs
│           ├── entity_extractor.rs
│           ├── code_relationships.rs
│           └── context_summarizer.rs
├── northstar-cartridges/      # Structured memory (feature-gated)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── structured_memory.rs
│       ├── entity.rs
│       ├── embeddings.rs
│       ├── temporal.rs
│       └── format.rs
├── northstar-queries/         # Query system (feature-gated)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── planner.rs
│       ├── natural_language.rs
│       ├── optimizer.rs
│       └── router.rs
├── northstar-autonomy/        # Self-optimization (feature-gated)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── archival.rs
│       ├── cartridge_builder.rs
│       └── regression_detection.rs
├── northstar-replication/     # Replication (feature-gated)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── publisher.rs
│       ├── subscriber.rs
│       └── protocol.rs
├── northstar-consensus/       # Raft consensus (feature-gated)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── raft.rs
│       ├── rpc.rs
│       └── snapshot.rs
├── northstar-observability/   # Monitoring (feature-gated)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── metrics.rs
│       ├── tracing.rs
│       └── debug.rs
├── northstar-test/            # Testing utilities
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── hardening.rs       # Crash consistency tests
│       ├── fuzz.rs            # Fuzzing harnesses
│       ├── property_based.rs  # Property-based testing
│       └── ref_model.rs       # Reference model
├── northstar-bench/           # Benchmark harness
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── runner.rs          # Benchmark execution
│       ├── suite.rs           # Benchmark definitions
│       ├── types.rs           # Benchmark types
│       └── compare.rs         # Baseline comparison
└── northstar-cli/             # CLI application
    ├── Cargo.toml
    └── src/
        └── main.rs            # CLI entry point
```

### 3.3 Feature Flags

```toml
[features]
default = ["core"]
core = []                      # Minimal embedded database
full = ["core", "llm", "plugins", "cartridges", "queries"]
ai = ["llm", "plugins", "cartridges", "queries"]
distributed = ["replication", "consensus"]
observability = ["metrics", "tracing"]

# Individual feature toggles
llm = ["dep:northstar-llm"]
plugins = ["dep:northstar-plugins"]
cartridges = ["dep:northstar-cartridges"]
queries = ["dep:northstar-queries"]
autonomy = ["dep:northstar-autonomy"]
replication = ["dep:northstar-replication"]
consensus = ["dep:northstar-consensus"]
metrics = ["dep:northstar-observability"]
tracing = ["dep:northstar-observability"]
```

---

## 4. Zig to Rust Module Mapping

### 4.1 Core Database Layer

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/db.zig` | `northstar-core` | `db` |
| `src/pager.zig` | `northstar-core` | `pager` |
| `src/page_cache.zig` | `northstar-core` | `page_cache` |
| `src/txn.zig` | `northstar-core` | `txn` |
| `src/snapshot.zig` | `northstar-core` | `snapshot` |
| `src/wal.zig` | `northstar-core` | `wal` |
| `src/replay.zig` | `northstar-core` | `replay` |
| `src/ref_model.zig` | `northstar-test` | `ref_model` |
| `src/ref_model_v2.zig` | `northstar-test` | `ref_model_v2` |

### 4.2 B+Tree Implementation

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| *(embedded in pager)* | `northstar-btree` | `tree`, `node`, `cursor` |

### 4.3 Testing and Validation

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/hardening.zig` | `northstar-test` | `hardening` |
| `src/fuzz.zig` | `northstar-test` | `fuzz` |
| `src/property_based.zig` | `northstar-test` | `property_based` |
| `src/validator.zig` | `northstar-cli` | `commands::validate` |
| `src/metamorphic.zig` | `northstar-test` | `metamorphic` |

### 4.4 Benchmark Framework

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/main.zig` | `northstar-cli` | `main` |
| `src/bench/runner.zig` | `northstar-bench` | `runner` |
| `src/bench/types.zig` | `northstar-bench` | `types` |
| `src/bench/compare.zig` | `northstar-bench` | `compare` |
| `src/bench/suite.zig` | `northstar-bench` | `suite` |
| `src/bench/*.zig` | `northstar-bench` | `benches::*` |

### 4.5 LLM Integration

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/llm/client.zig` | `northstar-llm` | `client` |
| `src/llm/types.zig` | `northstar-llm` | `types` |
| `src/llm/function.zig` | `northstar-llm` | `function` |
| `src/llm/orchestrator.zig` | `northstar-llm` | `orchestrator` |
| `src/llm/orchestrator_optimizer.zig` | `northstar-llm` | `orchestrator::optimizer` |
| `src/llm/providers/openai.zig` | `northstar-llm` | `providers::openai` |
| `src/llm/providers/anthropic.zig` | `northstar-llm` | `providers::anthropic` |
| `src/llm/providers/local.zig` | `northstar-llm` | `providers::local` |

### 4.6 Plugin System

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/plugins/manager.zig` | `northstar-plugins` | `manager` |
| `src/plugins/cli.zig` | `northstar-cli` | `commands::plugins` |
| `src/plugins/sdk.zig` | `northstar-plugins` | `sdk` |
| `src/plugins/entity_extractor.zig` | `northstar-plugins` | `plugins::entity_extractor` |
| `src/plugins/code_relationships.zig` | `northstar-plugins` | `plugins::code_relationships` |
| `src/plugins/context_summarizer.zig` | `northstar-plugins` | `plugins::context_summarizer` |
| `src/plugins/*.zig` | `northstar-plugins` | `plugins::*` |

### 4.7 Cartridges

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/cartridges/structured_memory.zig` | `northstar-cartridges` | `structured_memory` |
| `src/cartridges/entity.zig` | `northstar-cartridges` | `entity` |
| `src/cartridges/embeddings.zig` | `northstar-cartridges` | `embeddings` |
| `src/cartridges/temporal.zig` | `northstar-cartridges` | `temporal` |
| `src/cartridges/doc_history.zig` | `northstar-cartridges` | `doc_history` |
| `src/cartridges/format.zig` | `northstar-cartridges` | `format` |
| `src/cartridges/*.zig` | `northstar-cartridges` | `*` |

### 4.8 Query System

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/queries/planner.zig` | `northstar-queries` | `planner` |
| `src/queries/natural_language.zig` | `northstar-queries` | `natural_language` |
| `src/queries/optimizer.zig` | `northstar-queries` | `optimizer` |
| `src/queries/router.zig` | `northstar-queries` | `router` |
| `src/queries/*.zig` | `northstar-queries` | `*` |

### 4.9 Autonomy

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/autonomy/archival.zig` | `northstar-autonomy` | `archival` |
| `src/autonomy/cartridge_builder.zig` | `northstar-autonomy` | `cartridge_builder` |
| `src/autonomy/regression_detection.zig` | `northstar-autonomy` | `regression_detection` |
| `src/autonomy/*.zig` | `northstar-autonomy` | `*` |

### 4.10 Observability

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/observability/metrics.zig` | `northstar-observability` | `metrics` |
| `src/observability/tracing.zig` | `northstar-observability` | `tracing` |
| `src/observability/debug.zig` | `northstar-observability` | `debug` |
| `src/observability/*.zig` | `northstar-observability` | `*` |

### 4.11 Replication and Consensus

| Zig File | Rust Crate | Rust Module |
|----------|------------|-------------|
| `src/replication/*.zig` | `northstar-replication` | `*` |
| `src/consensus/*.zig` | `northstar-consensus` | `*` |

---

## 5. Build System Translation Strategy

### 5.1 Zig build.zig → Cargo.toml

#### Current Zig Build System
- Single binary: `bench` executable
- Test targets embedded in source files
- No external dependencies (currently)
- Benchmarks defined in code via comptime registration

#### Rust Cargo Translation

**Workspace Root (`Cargo.toml`)**:
```toml
[workspace]
members = [
    "northstar-core",
    "northstar-btree",
    "northstar-llm",
    "northstar-plugins",
    "northstar-cartridges",
    "northstar-queries",
    "northstar-autonomy",
    "northstar-replication",
    "northstar-consensus",
    "northstar-observability",
    "northstar-test",
    "northstar-bench",
    "northstar-cli",
]

[workspace.package]
version = "0.1.0"
edition = "2021"
license = "MIT OR Apache-2.0"
repository = "https://github.com/northstar-db/northstar-rust"

[workspace.dependencies]
# Core dependencies
tokio = { version = "1.40", features = ["full"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
bytes = "1.7"
thiserror = "1.0"
anyhow = "1.0"

# Benchmarking
criterion = { version = "0.5", features = ["html_reports"] }

# Testing
proptest = "1.5"
quickcheck = "1.0"

# Feature-gated dependencies
reqwest = { version = "0.12", optional = true }
async-trait = { version = "0.1", optional = true }
```

### 5.2 Benchmark Harness Integration

**Zig**: `zig build run -- run [options]`
**Rust**: `cargo run --release --bench <benchname>`

#### Benchmark Organization

1. **Criterion Benchmarks** (microbenchmarks):
   - Located in `northstar-core/benches/`
   - Run with `cargo bench --package northstar-core`

2. **Custom Benchmark Harness** (macro benchmarks):
   - Implemented in `northstar-bench`
   - Replicates Zig's custom runner
   - Supports JSON output and baseline comparison

3. **Benchmark Suits**:
   ```rust
   // northstar-bench/src/suite.rs
   use northstar_bench::{BenchmarkSuite, BenchmarkRegistry};

   pub fn register_benchmarks(registry: &mut BenchmarkRegistry) {
       // Suite A: Pager/Storage primitives
       registry.register::<pager_open_close>();
       registry.register::<pager_read_write>();
       registry.register::<pager_checksum>();

       // Suite B: B+tree core
       registry.register::<btree_point_get_put>();
       registry.register::<btree_range_scan>();
       registry.register::<btree_delete>();

       // Suite C: MVCC snapshots
       registry.register::<mvcc_readers_scaling>();
       registry.register::<mvcc_conflict_detection>();

       // Suite D: Time-travel/commit stream
       registry.register::<record_append>();
       registry.register::<record_replay>();
   }
   ```

### 5.3 Test Organization

**Zig**: Tests embedded in source files
**Rust**: Separate test modules + integration tests

#### Structure
```
northstar-core/
├── src/
│   ├── lib.rs
│   ├── db.rs
│   └── db_test.rs           # Unit tests (#[cfg(test)])
└── tests/
    └── integration_test.rs  # Integration tests
```

### 5.4 Feature Flags for Optional Components

```toml
# northstar-core/Cargo.toml
[features]
default = []
llm = ["dep:northstar-llm"]
plugins = ["dep:northstar-plugins"]
cartridges = ["dep:northstar-cartridges"]
queries = ["dep:northstar-queries"]
autonomy = ["dep:northstar-autonomy"]

[dependencies]
northstar-llm = { path = "../northstar-llm", optional = true }
northstar-plugins = { path = "../northstar-plugins", optional = true }
# ... etc
```

### 5.5 Build Profiles

```toml
[profile.dev]
opt-level = 0              # Fast compiles for development

[profile.release]
opt-level = 3              # Maximum optimization
lto = true                 # Link-time optimization
codegen-units = 1          # Single codegen unit for better optimization

[profile.bench]
inherits = "release"
```

### 5.6 CI/CD Integration

**Zig**: `zig build test` → **Rust**: `cargo test --all-features`
**Zig**: `zig build run -- run --suite micro` → **Rust**: `cargo bench --bench micro`

CI workflows will:
1. Run `cargo test --all-features` (all tests)
2. Run `cargo test --no-default-features` (core only)
3. Run `cargo bench` (performance regression)
4. Compare against baseline (like Zig's `compare` subcommand)

---

## 6. Migration Phases

### Phase 0: Project Setup (Current Phase)
- [x] 00-project-overview.md (this document)
- [ ] 01-cargo-workspace.md
- [ ] 02-dependencies.md
- [ ] 03-feature-flags.md

### Phase 1: Core Database
- Port `northstar-core` (pager, txn, wal, snapshot, replay)
- Port `northstar-btree` (B+tree implementation)
- Port `northstar-test` (reference model, hardening tests)

### Phase 2: Benchmark Framework
- Port `northstar-bench` (runner, suite, types, compare)
- Port `northstar-cli` (main entry point)
- Establish baseline performance metrics

### Phase 3: AI Intelligence Layer
- Port `northstar-llm` (client, function calling, providers)
- Port `northstar-plugins` (manager, SDK, entity extractor)
- Port `northstar-cartridges` (structured memory)

### Phase 4: Query and Autonomy
- Port `northstar-queries` (planner, NL, optimizer)
- Port `northstar-autonomy` (archival, cartridge builder)

### Phase 5: Distributed Systems
- Port `northstar-replication` (pub/sub, protocol)
- Port `northstar-consensus` (Raft implementation)

### Phase 6: Observability and Tooling
- Port `northstar-observability` (metrics, tracing)
- Complete CLI integration

---

## 7. Next Steps

1. **Review and approve this document** - Ensure team alignment on structure
2. **Create `01-cargo-workspace.md`** - Specify Cargo.toml configuration
3. **Create `02-dependencies.md`** - List all external crates to use
4. **Create `03-feature-flags.md`** - Define feature flag strategy
5. **Begin Phase 1** - Start porting core database components

---

*This document serves as the master plan for the NorthstarDB Rust migration. All subsequent specification documents should reference this structure for consistency.*
