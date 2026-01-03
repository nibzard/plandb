# NorthstarDB Rust Migration: Crate Structure and Dependencies

## Purpose

This document provides a comprehensive specification of the Cargo workspace structure for NorthstarDB. It defines the complete crate layout, inter-crate dependencies, external dependency matrix, and feature flag strategy. The structure prioritizes modular design, phased migration, and selective feature enablement.

---

## Crate Architecture Decision

### Decision: Cargo Workspace with Multiple Crates

#### Why a Workspace Instead of Single Crate

**Single crate approach would**:
- Mix core database code with AI features, violating domain boundaries
- Force all users to compile AI dependencies even for embedded use
- Make phased migration difficult
- Increase compilation times for all use cases
- Violate Domain-Driven Design bounded contexts principle

**Workspace approach provides**:
1. Clear domain separation matching Zig structure
2. Independent testing and benchmarking per crate
3. Selective dependency management through feature flags
4. Phased migration path (core first, AI later)
5. Parallel compilation in CI
6. Minimal binary size for embedded users
7. Ecosystem alignment (library + binary crates)

#### Trade-offs and Mitigations

**Workspace complexity**: More complex build configuration
- Mitigation: Workspace-level dependency consolidation in root Cargo.toml

**Version synchronization**: Multiple crates must stay in sync
- Mitigation: Workspace inheritance for version, edition, license

**Circular dependency risk**: Crates depending on each other
- Mitigation: Strict layering enforced by dependency graph

---

## Crate Layout and Purpose

### Layer 1: Foundational Crates (No Internal Dependencies)

#### northstar-core

**Purpose**: Core embedded database engine providing storage, transactions, and MVCC

**Responsibilities**:
- B+tree page management and allocation
- Page cache with LRU eviction and reader pinning
- Write-ahead log with append-only durability
- Two-phase commit transactions
- MVCC snapshot registry for concurrent readers
- Deterministic replay from commit stream

**Public API Surface**:
- Database opening and configuration
- Read transaction creation and lifecycle
- Write transaction creation and mutation operations
- Commit and rollback operations
- Snapshot creation and querying
- Error types for all failure modes

**Target Users**: Embedded application developers, library authors

**Size Estimate**: 5,000-8,000 lines of Rust

---

#### northstar-btree

**Purpose**: B+tree data structure implementation extracted from pager for testability

**Responsibilities**:
- Internal node structure and operations
- Leaf node structure and operations
- Binary search within nodes
- Node split and merge algorithms
- Tree traversal and cursor management
- Key encoding and comparison

**Dependencies**: northstar-core (for PageId and basic types)

**Public API Surface**:
- Tree creation and initialization
- Point lookup operations
- Range scan operations
- Insert and delete operations
- Cursor-based iteration

**Rationale for Separation**: B+tree is complex enough to warrant independent testing and potential reuse

**Size Estimate**: 2,000-3,000 lines of Rust

---

### Layer 2: Testing and Benchmarking Infrastructure

#### northstar-test

**Purpose**: Testing utilities and validation frameworks

**Responsibilities**:
- In-memory reference model for equivalence testing
- Crash consistency test harness
- Fuzzing harness integration
- Property-based testing utilities
- Metamorphic testing framework

**Dependencies**: northstar-core (for types being tested)

**Public API Surface**:
- Reference model operations matching core API
- Crash simulation utilities
- Property test generators
- Test case builders

**Target Users**: Database developers, CI systems

**Size Estimate**: 1,500-2,500 lines of Rust

---

#### northstar-bench

**Purpose**: Benchmark execution framework and metrics collection

**Responsibilities**:
- Benchmark runner with configurable repeats
- Metrics collection (throughput, latency, percentiles)
- JSON result output and persistence
- Baseline comparison and regression detection
- Benchmark suite registration and organization

**Dependencies**: northstar-core (for database operations being benchmarked)

**Public API Surface**:
- Benchmark suite registration macro
- Benchmark execution configuration
- Result aggregation and statistics
- Baseline comparison utilities

**Target Users**: Performance engineers, CI systems

**Size Estimate**: 1,000-2,000 lines of Rust

---

### Layer 3: AI Intelligence Layer (Feature-Gated)

#### northstar-llm

**Purpose**: Provider-agnostic LLM client interface

**Responsibilities**:
- Unified client interface for multiple LLM providers
- Function calling schema validation and execution
- Request orchestration and retry logic
- Response parsing and error handling
- Provider-specific implementations

**Dependencies**:
- northstar-core (for persistence of LLM configurations)
- External HTTP clients (reqwest)
- External JSON libraries (serde_json)

**Public API Surface**:
- Client creation and configuration
- Chat completion requests
- Function calling registration
- Streaming response handling

**Feature Flag**: llm (default off)

**Target Users**: AI application developers

**Size Estimate**: 2,000-3,000 lines of Rust

---

#### northstar-plugins

**Purpose**: Plugin system for extensible database capabilities

**Responsibilities**:
- Plugin lifecycle management (load, initialize, shutdown)
- Plugin SDK for third-party development
- Resource quotas and security isolation
- Built-in plugins (entity extraction, code analysis, etc.)
- Plugin marketplace integration

**Dependencies**:
- northstar-core (for database access)
- northstar-llm (for LLM-based plugins, optional)
- northstar-cartridges (for structured memory, optional)

**Public API Surface**:
- Plugin manager API
- Plugin trait definition
- Plugin discovery and loading
- Built-in plugin implementations

**Feature Flag**: plugins (default off, implies llm)

**Target Users**: Plugin developers, power users

**Size Estimate**: 3,000-5,000 lines of Rust

---

#### northstar-cartridges

**Purpose**: Structured memory cartridges for AI-extracted knowledge

**Responsibilities**:
- Entity-topic-relationship storage format
- Cartridge serialization and validation
- Embedding vector storage (optional)
- Temporal data versioning
- Cartridge maintenance and rebuilding

**Dependencies**:
- northstar-core (for persistence)
- northstar-llm (for entity extraction, optional)

**Public API Surface**:
- Cartridge creation and querying
- Entity and relationship management
- Temporal history access
- Cartridge format validation

**Feature Flag**: cartridges (default off)

**Target Users**: AI application developers

**Size Estimate**: 2,500-4,000 lines of Rust

---

#### northstar-queries

**Purpose**: Natural language query processing and optimization

**Responsibilities**:
- Natural language query parsing
- Semantic query planning
- Cost-based optimization
- Query routing to appropriate storage
- Predictive query optimization using LLMs

**Dependencies**:
- northstar-core (for data access)
- northstar-llm (for semantic understanding)
- northstar-cartridges (for semantic search)

**Public API Surface**:
- Query execution API
- Query plan inspection
- Optimization hints

**Feature Flag**: queries (default off, implies llm, cartridges)

**Target Users**: Application developers

**Size Estimate**: 2,000-3,500 lines of Rust

---

#### northstar-autonomy

**Purpose**: Self-optimization and autonomous maintenance

**Responsibilities**:
- Automatic data archival
- Cartridge building from patterns
- Performance regression detection
- Temporal retention policy enforcement
- Tiered storage management

**Dependencies**:
- northstar-core (for database operations)
- northstar-cartridges (for structured memory)
- northstar-llm (for pattern analysis)

**Public API Surface**:
- Autonomy policy configuration
- Task scheduling and execution
- Regression alerting

**Feature Flag**: autonomy (default off, implies llm, cartridges)

**Target Users**: Database administrators

**Size Estimate**: 1,500-2,500 lines of Rust

---

### Layer 4: Distributed Systems (Feature-Gated)

#### northstar-replication

**Purpose**: Change data capture and data replication

**Responsibilities**:
- WAL-based change capture
- Replication stream publishing
- Subscription management
- Conflict resolution
- Replication protocol implementation

**Dependencies**: northstar-core (for WAL access)

**Public API Surface**:
- Replication configuration
- Publisher and subscriber APIs
- Replication status monitoring

**Feature Flag**: replication (default off)

**Target Users**: Distributed database operators

**Size Estimate**: 2,000-3,000 lines of Rust

---

#### northstar-consensus

**Purpose**: Raft consensus algorithm for distributed coordination

**Responsibilities**:
- Raft leader election
- Log replication
- Snapshot transfer
- RPC protocol for node communication
- State machine persistence

**Dependencies**: northstar-core (for log persistence)

**Public API Surface**:
- Raft node configuration
- Cluster membership changes
- Consensus status inspection

**Feature Flag**: consensus (default off)

**Target Users**: Distributed database operators

**Size Estimate**: 3,000-4,000 lines of Rust

---

### Layer 5: Observability (Feature-Gated)

#### northstar-observability

**Purpose**: Metrics collection, distributed tracing, and debugging

**Responsibilities**:
- Metrics collection and aggregation
- Distributed tracing integration
- Debug utilities and introspection
- Performance profiling

**Dependencies**: northstar-core (for instrumentation points)

**Public API Surface**:
- Metrics registration and reporting
- Span creation and context propagation
- Debug query API

**Feature Flags**: metrics, tracing (default off)

**Target Users**: Operators, developers

**Size Estimate**: 1,000-2,000 lines of Rust

---

### Layer 6: User-Facing Tools

#### northstar-cli

**Purpose**: Command-line interface for database administration

**Responsibilities**:
- Database file inspection
- Benchmark execution
- Plugin management
- Validation and debugging commands
- Configuration management

**Dependencies**: All feature-gated crates (as optional dependencies)

**Public API Surface**: CLI commands only

**Target Users**: Database administrators, developers

**Size Estimate**: 1,500-3,000 lines of Rust

---

## Dependency Graph

### Crate Dependency Matrix

```
northstar-cli
    +-- northstar-core (required)
    +-- northstar-llm (optional, via llm feature)
    +-- northstar-plugins (optional, via plugins feature)
    +-- northstar-cartridges (optional, via cartridges feature)
    +-- northstar-queries (optional, via queries feature)
    +-- northstar-autonomy (optional, via autonomy feature)
    +-- northstar-replication (optional, via replication feature)
    +-- northstar-consensus (optional, via consensus feature)
    +-- northstar-observability (optional, via observability feature)
    +-- northstar-bench (for benchmark commands)

northstar-bench
    +-- northstar-core

northstar-test
    +-- northstar-core

northstar-btree
    +-- northstar-core (for PageId, basic types)

northstar-observability
    +-- northstar-core

northstar-autonomy
    +-- northstar-core
    +-- northstar-cartridges
    +-- northstar-llm

northstar-queries
    +-- northstar-core
    +-- northstar-cartridges
    +-- northstar-llm

northstar-cartridges
    +-- northstar-core
    +-- northstar-llm (optional)

northstar-plugins
    +-- northstar-core
    +-- northstar-llm (optional)
    +-- northstar-cartridges (optional)

northstar-llm
    +-- northstar-core

northstar-replication
    +-- northstar-core

northstar-consensus
    +-- northstar-core

northstar-core (no internal dependencies)
```

### Dependency Layering Rules

1. **No circular dependencies**: Enforced by Cargo workspace
2. **Layered architecture**: Lower layers never depend on higher layers
3. **Feature-gated dependencies**: Optional features only enabled when requested
4. **Core minimalism**: northstar-core has no internal dependencies

---

## External Dependencies Matrix

### Core Dependencies (Required by All Crates)

#### tokio (version 1.40+)

**Purpose**: Async runtime for I/O operations

**Features Used**:
- full: Enables all tokio features (fs, net, time, macros, sync)

**Used By**: All crates requiring async I/O

**Justification**:
- Industry standard async runtime
- Comprehensive feature set
- Excellent ecosystem integration
- Mature and well-maintained

**Version Constraint**: 1.40 (compatible with Rust 2021 edition)

---

#### serde (version 1.0+)

**Purpose**: Serialization framework for configuration and data formats

**Features Used**:
- derive: Enables derive macros for Serialize/Deserialize

**Used By**: All crates for serialization

**Justification**:
- De facto standard for Rust serialization
- Zero-cost abstraction
- Excellent performance
- Wide format support

---

#### serde_json (version 1.0+)

**Purpose**: JSON serialization for LLM APIs, configuration files, benchmarks

**Used By**: LLM client, configuration management, benchmark output

**Justification**:
- Standard JSON library in Rust
- Excellent performance
- Minimal dependencies

---

#### bytes (version 1.7+)

**Purpose**: Byte buffer manipulation for efficient I/O

**Used By**: Pager, WAL, network protocols

**Justification**:
- Zero-copy byte operations
- Reference counted for cheap cloning
- Standard in async ecosystem

---

#### thiserror (version 1.0+)

**Purpose**: Error type definitions with derive macros

**Used By**: All crates for error types

**Justification**:
- Clean error type definitions
- Excellent Display integration
- Source code tracking
- Minimal boilerplate

---

#### anyhow (version 1.0+)

**Purpose**: Error handling in application code (CLI, tests)

**Used By**: CLI, test harnesses, benchmarks

**Justification**:
- Simple error handling for non-library code
- Excellent error chain display
- Minimal boilerplate

---

### Testing Dependencies

#### proptest (version 1.5+)

**Purpose**: Property-based testing framework

**Used By**: northstar-test, all crate test suites

**Justification**:
- Mature property testing
- Excellent shrinking
- Easy strategy definition
- Proven in production

---

#### quickcheck (version 1.0+)

**Purpose**: Alternative property-based testing

**Used By**: Fuzzing harnesses

**Justification**:
- Complementary to proptest
- Different generation strategies
- Industry standard

---

### Benchmarking Dependencies

#### criterion (version 0.5+)

**Purpose**: Statistical benchmarking framework

**Features Used**:
- html_reports: Generates HTML benchmark reports

**Used By**: All crates for microbenchmarks

**Justification**:
- Gold standard for Rust benchmarking
- Statistical rigor
- HTML output for visualization
- Baseline comparison built-in

---

### LLM and HTTP Dependencies (Feature-Gated)

#### reqwest (version 0.12+, optional)

**Purpose**: HTTP client for LLM API calls

**Features Used**:
- json: JSON serialization support
- rustls-tls: TLS implementation without OpenSSL

**Used By**: northstar-llm

**Justification**:
- Modern async HTTP client
- Excellent error handling
- JSON integration
- Flexible timeout configuration

**Feature Flag**: llm (implies reqwest)

---

#### async-trait (version 0.1+, optional)

**Purpose**: Async trait support for plugin system

**Used By**: northstar-plugins, northstar-llm

**Justification**:
- Enables async methods in traits
- Required for plugin interface
- Stable and well-tested

**Feature Flag**: plugins, llm

---

### Database-Specific Dependencies

#### crc32c (version 0.6+)

**Purpose**: CRC32C checksum algorithm for page validation

**Used By**: northstar-core (pager, WAL)

**Justification**:
- Hardware-accelerated on supported platforms
- Required for compatibility with Zig format
- Fallback to software implementation

---

#### std (required)

**Purpose**: Rust standard library

**Justification**: Core functionality requires std (no no_std target)

---

### Observability Dependencies (Feature-Gated)

#### tracing (version 0.1+, optional)

**Purpose**: Distributed tracing instrumentation

**Features Used**:
- attributes: Macro-based span creation

**Used By**: northstar-observability, instrumented crates

**Justification**:
- Modern tracing framework
- Structured logging
- Span context propagation
- Async-aware

**Feature Flag**: tracing

---

#### tracing-subscriber (version 0.3+, optional)

**Purpose**: Tracing log collection and formatting

**Used By**: CLI, test harnesses

**Justification**:
- Standard subscriber implementation
- Multiple output formats
- Filtering support

**Feature Flag**: tracing

---

#### metrics (version 0.22+, optional)

**Purpose**: Metrics aggregation interface

**Used By**: northstar-observability

**Justification**:
- Vendor-agnostic metrics API
- Multiple exporter support
- No-op when disabled

**Feature Flag**: metrics

---

### CLI Dependencies

#### clap (version 4.5+)

**Purpose**: Command-line argument parsing

**Features Used**:
- derive: Derive macro for argument parsing

**Used By**: northstar-cli

**Justification**:
- Modern derive API
- Excellent help text generation
- Subcommand support
- Argument validation

---

#### anyhow (version 1.0+)

**Purpose**: Error handling in CLI application

**Used By**: northstar-cli (already listed in core)

---

## Feature Flags Specification

### Workspace-Level Features

These features are defined in the workspace root and inherited by member crates.

#### Feature: default

**Definition**: Empty feature, enables nothing

**Rationale**: Forces explicit feature selection, prevents accidental bloat

**Composition**: None

---

#### Feature: core

**Definition**: Minimal embedded database without AI features

**Enables**: Nothing (northstar-core is always available)

**Use Case**: Embedded applications needing only storage

**Binary Size Impact**: Minimal

**Compilation Time**: Fastest

---

#### Feature: ai

**Definition**: All AI intelligence features

**Enables**: llm, plugins, cartridges, queries, autonomy

**Use Case**: Applications using AI features

**Binary Size Impact**: +2-3 MB

**Compilation Time**: +30-50%

**Dependencies**: All AI-layer crates

---

#### Feature: full

**Definition**: All features including distributed systems

**Enables**: core, llm, plugins, cartridges, queries, autonomy, replication, consensus, observability

**Use Case**: Production deployments needing all capabilities

**Binary Size Impact**: +4-5 MB

**Compilation Time**: +50-70%

**Dependencies**: All crates

---

#### Feature: distributed

**Definition**: Distributed database capabilities

**Enables**: replication, consensus

**Use Case**: Multi-node deployments

**Binary Size Impact**: +1-2 MB

**Compilation Time**: +20-30%

**Dependencies**: Replication and consensus crates

---

#### Feature: observability

**Definition**: Monitoring and debugging capabilities

**Enables**: metrics, tracing

**Use Case**: Production deployments requiring observability

**Binary Size Impact**: +500 KB

**Compilation Time**: +10-15%

**Dependencies**: Observability crate

---

### Individual Feature Toggles

#### Feature: llm

**Definition**: LLM client and function calling

**Enables**:
- northstar-llm crate compilation
- reqwest dependency
- async-trait dependency
- LLM client API in northstar-core

**Use Case**: Direct LLM integration without plugins

**Dependencies**:
- tokio (already enabled)
- reqwest
- async-trait

**Implications**:
- Requires network connectivity at runtime
- Increases binary size by HTTP client code
- Enables LLM provider configuration

---

#### Feature: plugins

**Definition**: Plugin system and built-in plugins

**Enables**:
- northstar-plugins crate compilation
- Plugin manager API
- Built-in plugin implementations

**Use Case**: Extensible database with custom plugins

**Dependencies**:
- llm (auto-implied)
- northstar-llm

**Implications**:
- Enables dynamic loading of plugin code
- Requires LLM for many built-in plugins
- Increases attack surface (dynamic code)

---

#### Feature: cartridges

**Definition**: Structured memory cartridges

**Enables**:
- northstar-cartridges crate compilation
- Entity-topic-relationship storage
- Cartridge maintenance operations

**Use Case**: AI-extracted structured memory

**Dependencies**:
- northstar-core (always)
- llm (optional, for entity extraction)

**Implications**:
- Adds cartridge storage overhead
- Enables semantic search capabilities
- Requires cartridge indexing

---

#### Feature: queries

**Definition**: Natural language query processing

**Enables**:
- northstar-queries crate compilation
- Query planning and optimization
- Semantic query routing

**Use Case**: Natural language database queries

**Dependencies**:
- llm (required)
- cartridges (required)

**Implications**:
- Enables natural language interface
- Requires LLM for query understanding
- Adds query planning overhead

---

#### Feature: autonomy

**Definition**: Self-optimization and autonomous maintenance

**Enables**:
- northstar-autonomy crate compilation
- Automatic archival
- Regression detection
- Cartridge building

**Use Case**: Set-and-forget deployments

**Dependencies**:
- llm (required)
- cartridges (required)

**Implications**:
- Enables background tasks
- Increases write amplification
- Requires LLM for pattern analysis

---

#### Feature: replication

**Definition**: Change data capture and replication

**Enables**:
- northstar-replication crate compilation
- Replication streaming
- Subscription management

**Use Case**: Multi-node read replicas

**Dependencies**:
- northstar-core (always)

**Implications**:
- Enables distributed reads
- Adds replication protocol overhead
- Requires network configuration

---

#### Feature: consensus

**Definition**: Raft consensus for distributed coordination

**Enables**:
- northstar-consensus crate compilation
- Raft leader election
- Log replication

**Use Case**: Multi-node fault tolerance

**Dependencies**:
- northstar-core (always)

**Implications**:
- Enables distributed writes
- Adds consensus protocol overhead
- Requires quorum configuration

---

#### Feature: metrics

**Definition**: Metrics collection and export

**Enables**:
- metrics crate in northstar-observability
- Metric registration and aggregation

**Use Case**: Production monitoring

**Dependencies**:
- northstar-observability (partial)

**Implications**:
- Enables metric export
- Adds minimal runtime overhead
- Requires metrics exporter

---

#### Feature: tracing

**Definition**: Distributed tracing instrumentation

**Enables**:
- tracing crate in northstar-observability
- Span creation and propagation

**Use Case**: Request tracing and debugging

**Dependencies**:
- northstar-observability (partial)

**Implications**:
- Enables distributed tracing
- Adds span allocation overhead
- Requires tracing collector

---

## Feature Compatibility Matrix

### Valid Feature Combinations

| Feature Set | Features Enabled | Use Case | Binary Size | Compile Time |
|-------------|------------------|----------|-------------|--------------|
| core | (none) | Embedded minimal | Baseline | Baseline |
| llm | llm | Direct LLM access | +500 KB | +10% |
| ai | llm, plugins, cartridges, queries, autonomy | AI features | +3 MB | +50% |
| distributed | replication, consensus | Multi-node | +2 MB | +30% |
| observability | metrics, tracing | Monitoring | +500 KB | +10% |
| full | all features | Production complete | +5 MB | +70% |

### Feature Dependency Resolution

1. **plugins** implies **llm** (plugins need LLM client)
2. **queries** implies **llm** and **cartridges** (queries need semantic search)
3. **autonomy** implies **llm** and **cartridges** (autonomy needs structured memory)
4. **distributed** combines **replication** and **consensus** (distributed needs both)
5. **observability** combines **metrics** and **tracing** (observability needs both)

### Invalid Feature Combinations

These combinations should produce compile errors:

- **queries** without **cartridges**: Queries need semantic search
- **queries** without **llm**: Queries need LLM for understanding
- **autonomy** without **cartridges**: Autonomy needs structured memory
- **plugins** without **llm**: Most plugins need LLM (enforced by code)

---

## Build Implications

### Minimal Build (core only)

**Command**: `cargo build --release --no-default-features`

**Included Crates**:
- northstar-core
- northstar-btree
- northstar-test
- northstar-bench

**Excluded Crates**:
- All AI layer crates
- All distributed system crates
- All observability crates

**Binary Size**: ~2 MB stripped

**Compilation Time**: ~2 minutes on modern hardware

**Use Case**: Embedded databases in resource-constrained environments

---

### Full Build (all features)

**Command**: `cargo build --release --all-features`

**Included Crates**: All 15 crates

**Binary Size**: ~7 MB stripped

**Compilation Time**: ~4 minutes on modern hardware

**Use Case**: Production deployments with full capabilities

---

### AI Features Build

**Command**: `cargo build --release --features ai`

**Included Crates**: Core + AI layer

**Binary Size**: ~5 MB stripped

**Compilation Time**: ~3 minutes on modern hardware

**Use Case**: AI-powered applications

---

### Distributed Build

**Command**: `cargo build --release --features distributed`

**Included Crates**: Core + Replication + Consensus

**Binary Size**: ~4 MB stripped

**Compilation Time**: ~2.5 minutes on modern hardware

**Use Case**: Multi-node deployments

---

## Per-Crate Feature Flags

### northstar-core

```toml
[features]
default = []
llm = ["dep:northstar-llm"]
plugins = ["dep:northstar-plugins"]
cartridges = ["dep:northstar-cartridges"]
queries = ["dep:northstar-queries"]
autonomy = ["dep:northstar-autonomy"]
replication = ["dep:northstar-replication"]
consensus = ["dep:northstar-consensus"]
observability = ["dep:northstar-observability"]
```

**Rationale**: Feature flags in northstar-core only enable optional APIs that depend on feature-gated crates. Core functionality remains available without any features.

---

### northstar-cli

```toml
[features]
default = ["core"]
core = []
ai = ["llm", "plugins", "cartridges", "queries", "autonomy"]
distributed = ["replication", "consensus"]
observability = ["metrics", "tracing"]
full = ["ai", "distributed", "observability"]

llm = ["dep:northstar-llm"]
plugins = ["dep:northstar-plugins"]
cartridges = ["dep:northstar-cartridges"]
queries = ["dep:northstar-queries"]
autonomy = ["dep:northstar-autonomy"]
replication = ["dep:northstar-replication"]
consensus = ["dep:northstar-consensus"]
metrics = ["dep:northstar-observability/metrics"]
tracing = ["dep:northstar-observability/tracing"]
```

**Rationale**: CLI mirrors workspace features for consistency. Individual features enable respective CLI commands.

---

### northstar-observability

```toml
[features]
default = []
metrics = ["dep:metrics"]
tracing = ["dep:tracing", "dep:tracing-subscriber"]
full = ["metrics", "tracing"]
```

**Rationale**: Metrics and tracing are independent. Both can be enabled together for full observability.

---

## Migration Path

### Phase 1: Core Functionality

**Features Implemented**: core (default)

**Crates Implemented**:
- northstar-core
- northstar-btree
- northstar-test
- northstar-bench

**Validation**:
- All Zig benchmarks pass with equivalent performance
- All hardening tests pass
- Reference model equivalence verified

---

### Phase 2: AI Layer

**Features Implemented**: llm, cartridges, queries, autonomy, plugins

**Crates Implemented**:
- northstar-llm
- northstar-cartridges
- northstar-queries
- northstar-autonomy
- northstar-plugins

**Validation**:
- LLM function calling works across providers
- Entity extraction produces correct cartridges
- Natural language queries return correct results
- Plugin system loads and executes plugins

---

### Phase 3: Distributed Systems

**Features Implemented**: replication, consensus

**Crates Implemented**:
- northstar-replication
- northstar-consensus

**Validation**:
- Replication streams data correctly
- Raft consensus achieves consistency
- Multi-node deployments work correctly

---

### Phase 4: Observability and Tooling

**Features Implemented**: metrics, tracing

**Crates Implemented**:
- northstar-observability
- northstar-cli (complete)

**Validation**:
- Metrics export correctly
- Tracing spans propagate
- CLI commands work across all features

---

## Rust Implementation Guidance

### Workspace Configuration

**File**: `Cargo.toml` (workspace root)

**Required Sections**:
- `[workspace]` with members list
- `[workspace.package]` for shared metadata
- `[workspace.dependencies]` for consolidated dependencies
- `[profile.release]` for optimization settings
- `[profile.bench]` for benchmark configuration

**Key Settings**:
- Use workspace inheritance for version, edition, license
- Consolidate all external dependencies at workspace level
- Define feature flags at workspace level for consistency

---

### Per-Crate Configuration

**Required in Each `Cargo.toml`**:

1. **Package Inheritance**:
   ```toml
   [package]
   version.workspace = true
   edition.workspace = true
   license.workspace = true
   ```

2. **Dependency Inheritance**:
   ```toml
   [dependencies]
   tokio = { workspace = true }
   serde = { workspace = true }
   ```

3. **Feature Flag Definition**:
   ```toml
   [features]
   default = []
   llm = ["dep:northstar-llm"]
   ```

4. **Optional Dependencies**:
   ```toml
   [dependencies]
   northstar-llm = { path = "../northstar-llm", optional = true }
   ```

---

### Build Profile Recommendations

**Release Profile**:
- `opt-level = 3`: Maximum optimization
- `lto = true`: Link-time optimization
- `codegen-units = 1`: Single codegen unit for better optimization
- `strip = true`: Strip symbols for smaller binaries

**Bench Profile**:
- Inherit from release
- Add `debug = true`: Keep debug info for profiling

**Dev Profile**:
- `opt-level = 0`: Fast compilation
- Keep debug info for development

---

### CI/CD Integration

**Test Commands**:
1. `cargo test --workspace --no-default-features`: Test core only
2. `cargo test --workspace --all-features`: Test all features
3. `cargo test --workspace --features ai`: Test AI layer

**Benchmark Commands**:
1. `cargo bench --workspace`: Run all benchmarks
2. `cargo bench --package northstar-core`: Core benchmarks only

**Clippy Checks**:
1. `cargo clippy --workspace --all-targets`: Lint all code
2. `cargo clippy --workspace --all-features -- -D warnings`: Fail on warnings

---

## Summary

This crate structure provides:

1. **Clear Domain Separation**: Each crate represents a bounded context
2. **Phased Migration**: Can implement and validate incrementally
3. **Selective Dependencies**: Only compile what you use
4. **Minimal Core**: Embedded use case requires no AI dependencies
5. **Feature Richness**: Full-featured builds enable all capabilities
6. **Performance**: Optimized build profiles for production use
7. **Testability**: Each crate can be tested independently
8. **Ecosystem Alignment**: Library + binary crate pattern

**Next Steps**:
1. Create `00-build-system.md` to specify Cargo build configuration
2. Begin Phase 1 core crate implementation
3. Establish benchmark baseline before feature additions
