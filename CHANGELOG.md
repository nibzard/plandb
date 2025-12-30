# Changelog

All notable changes to NorthstarDB will be documented in this file.

## [0.1.0] - 2025-12-30

### 🎉 Initial Release - Living Database Complete

This is the first production-ready release of NorthstarDB, a "Living Database" built from scratch in Zig with AI intelligence capabilities.

### Core Database (Phases 0-5)
- **Pager System**: Single file storage with page allocation, IO, checksum (crc32c), and meta pages
- **B+tree**: Copy-on-write ordered KV store with efficient point operations and range scans
- **MVCC Snapshots**: Many readers, single writer with massive read concurrency
- **Crash Safety**: Atomic root/meta switch with deterministic recovery
- **Commit Stream**: Canonical commit record format for every transaction
- **Time Travel**: Query historical snapshots cheaply with `AS OF txn_id`

### Cartridges System (Phase 6)
- **Pending Tasks Cartridge**: `pending_tasks_by_type` index for <1ms task claims
- **Semantic Embeddings**: Vector similarity with HNSW index
- **Temporal History**: Time-series entity state with field-level delta computation
- **Document Version History**: Diff + annotated history for document tracking

### Living Database AI Intelligence (Phase 7)
- **LLM Plugin System**: Provider-agnostic interface (OpenAI, Anthropic, local models)
- **Function Calling**: Deterministic AI operations over embeddings
- **Structured Memory Cartridges**:
  - Entity extraction and storage
  - Topic-based indexing with back-pointers
  - Relationship graph with traversal operations
- **Natural Language Queries**: Query by intent like "what performance optimizations did niko make to the btree?"
- **Autonomous Maintenance**: Self-optimizing database based on usage patterns
- **Performance Analyzer**: Automatic metric collection and regression detection

### Observability & Review (Phase 9)
- **Event System**: Append-only event log with bounded payloads for agent sessions
- **Plugin Hooks**: session_start, session_end, operation_start, operation_end
- **Code Review Cartridge**: Store/retrieve review notes linked to commits and files
- **Observability Cartridge**: Metric ingestion (counter, gauge, histogram, timing)
- **Regression Detection**: Baseline comparison with configurable thresholds
- **Time-Series Analytics**: Aggregation queries with efficient bucketing
- **Visualization Generators**: JSON for Chart.js, D3, Vega
- **Query Profiler**: Per-query execution tracking and hot path identification
- **Dashboard Builder**: Template-based dashboard generation with HTML/JSON export

### Documentation Platform (Phase 8)
Complete documentation site with:
- Getting started guide (5-minute quick start)
- API reference with auto-generated docs
- Architecture documentation
- Performance troubleshooting guide
- Corruption recovery procedures
- FAQ and community resources
- Deployed to GitHub Pages with CI/CD

### Examples
5 complete working examples:
- **Basic KV Store**: Core CRUD operations
- **Task Queue System**: Persistent job queue with workers
- **Document Repository**: Full-text searchable storage
- **Time-Series Telemetry**: Metrics database with aggregation
- **AI-Powered Knowledge Base**: Semantic graph with LLM integration
- **Real LLM Integration**: End-to-end example with OpenAI API

### Testing & Quality
- **Microbenchmark Suite**: 30+ benchmarks testing database physics
- **Macrobenchmark Suite**: Real-world workload simulations
- **Hardening Tests**: Crash recovery, torn writes, fuzzing
- **CI/CD**: Automated testing on every commit

### Performance (CI profile)
- Hot point get: p50 ~ single-digit µs, p99 in tens of µs
- Commit meta fsync: p50 few ms, p99 under ~10-20ms
- Snapshot open: microseconds
- Entity lookup: <1ms for 1M entities (RAM-resident)
- Topic search: <10ms for complex boolean queries

### Technical Stack
- **Language**: Zig 0.15.2
- **License**: Custom restrictive license (see LICENSE)
- **Platform**: Linux (planned: macOS, Windows)

### Known Limitations
- Single writer (MVCC readers scale, writer serializes)
- Linux-only (platform-specific IO optimizations)
- No distributed replication yet (Phase 10+)

### Next Steps
Future releases will focus on:
- Multi-region replication
- Production hardening and security audit
- Extended platform support (macOS, Windows)
- Advanced AI features and plugin ecosystem

---

### Contributors
- niko (creator and lead developer)

### Links
- Documentation: https://northstardb.dev
- GitHub: https://github.com/niko/plandb
