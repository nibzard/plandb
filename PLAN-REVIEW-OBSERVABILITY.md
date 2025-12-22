# PLAN: Code Review + Observability as First-Class VCS Data

Date: 2025-12-22
Status: Draft
Owner: niko

## Goals

1. Make AI-assisted development *visible* to humans and other agents:
   - agent intent, review notes, decisions, and outcomes are queryable.
2. Treat code review + debugging + performance investigations as *versioned artifacts*.
3. Improve feedback loops: better observability → better agent actions → better codebase state.
4. Preserve NorthstarDB's core promise:
   - **log is truth**
   - deterministic replay
   - time travel queries
   - high read concurrency for many agents

## Non-Goals (for now)

- Replace GitHub UI fully.
- Store arbitrary huge trace dumps in the hot WAL path.
- Force a single canonical "review workflow" (keep it composable via plugins).

## Key Design Constraint

**Keep the core commit stream minimal and deterministic.**
Observability/review/agent-intent data must not degrade core commit latency.

Practical rule:
- Core WAL commit record: minimal metadata only (ids, timestamps, txn, optional small typed fields).
- Everything else: emitted as **typed events** via plugins and stored in dedicated "event streams" / cartridges with retention policies.

## High-Level Architecture

### A) Core (unchanged)
- MVCC, pager, B+tree, WAL, time travel snapshots

### B) Event Streams (new-ish concept)
Append-only records that are versioned and time-travel-compatible, but logically separate from the hot data path:
- `agent.session.started`
- `agent.operation`
- `review.note`
- `review.summary`
- `perf.sample`
- `perf.regression`
- `debug.session`
- `debug.snapshot`

These events are indexed into cartridges for fast queries.

### C) Cartridges (extended)
Precomputed structures for:
- review intelligence (intent explanations, change summaries, "similar changes")
- observability (perf trends, regressions, hot paths, error correlations)
- agent behavior (work attribution, success/failure rates, recurring patterns)

## Data Model

### Minimal metadata allowed in core commit record
- `actor_id` (human or agent)
- `session_id` (optional)
- `purpose` enum (optional: code_change, review_event, perf_event, debug_event)
- small typed tags (bounded size)

### Events (typed payloads)
Stored separately, indexed into cartridges.

Examples:

#### `review.note`
- author (agent/human)
- target (commit_id / file path / symbol / "PR-like" synthetic id)
- note text
- visibility (private-to-agent, team, public)
- references (links to commit ids, diffs, symbols)

#### `perf.sample`
- metric (latency, allocations, io, etc.)
- dimensions (query_name, codepath, build_id, machine_id)
- values + timestamp window
- correlation hints (commit range, sessions)

#### `debug.session`
- tool (lldb/gdb/python-external-debugger)
- breakpoints, stack summaries (bounded / sampled)
- references to commits and symbols

## API / Hook Changes

### Plugins: add agent + observability hooks
Add lifecycle hooks (names illustrative):

- `on_agent_session_start(ctx)`
- `on_agent_operation(ctx)`  (may emit events)
- `on_commit(ctx)`           (may emit events)
- `on_review_request(ctx)`   (generate review summaries/events)
- `on_perf_sample(ctx)`      (ingest perf metrics/events)

### DB: introduce an event append API
- `db.append_event(event_type, payload, metadata)`
- `db.query_events(...)`
- event stream is time-travel addressable ("as of txn/commit")

## Natural Language Queries (extend)

Add intents:
- code review explanation
- agent collaboration / attribution
- observability diagnosis
- regression hunting
- pattern discovery

Example NL queries:
- "Why did agent X change the btree split logic?"
- "Show all review notes related to commit 346902b."
- "Find regressions in range scan latency since last week."
- "Correlate crash reports with recent allocator changes."
- "Summarize debugging sessions for the memory leak issue."

## Implementation Plan

### Phase 1 — Foundations (minimal risk)
1. Add event append + storage primitive (append-only, bounded payloads).
2. Add plugin hooks for agent sessions + operations.
3. Add initial `CodeReviewCartridge`:
   - store/retrieve review notes
   - link notes to commits/files/symbols
4. Extend NL intent routing to map to structured queries over events/cartridges.

Deliverables:
- `PLAN-REVIEW-OBSERVABILITY.md` (this doc)
- `src/events/*` (event storage)
- `src/plugins/*` (new hooks)
- `src/cartridges/code_review.zig` (initial)

### Phase 2 — Observability Cartridges (feedback loop)
1. `ObservabilityCartridge` with:
   - metric ingestion (bounded)
   - regression detection (simple heuristics first)
   - correlation to commits/sessions
2. "hot path safety" enforcement:
   - event payload size limits
   - sampling / rate limiting
   - retention policies

Deliverables:
- `src/cartridges/observability.zig`
- `src/plugins/perf_analyzer.zig`
- docs for standard event schemas

### Phase 3 — Debugger Integrations
1. External debugger session capture (start with "import session summary").
2. Correlate debug artifacts to commits/symbols.
3. NL queries for "debug timeline".

Deliverables:
- `src/observability/code_review.zig` (extends Phase 1)
- `src/observability/debugger_interface.zig`
- event types: `debug.session`, `debug.snapshot`

### Phase 4 — Review-as-VCS Workflows
1. "PR-like" synthetic objects stored in DB:
   - a named branch/changeset
   - review state machine as events
2. Private notes for agents vs shared notes for team.
3. Deterministic review summaries stored as events.

Deliverables:
- `src/cartridges/review_workflows.zig`
- plugin: `src/plugins/review_state_machine.zig`
- schema for synthetic PR objects

## Performance & Safety

- Core commit latency must not regress measurably.
- Event ingestion must be bounded (size, rate).
- Sensitive data policy:
  - mark events as private/team/public
  - redact by default for debugger traces
- Reproducibility:
  - summaries should record model id + prompt hash (optional) but keep large text out of the core path.

## Open Questions

- Do we store events in the same WAL file format or separate log files?
- How do we do retention/compaction for event streams?
- What is the canonical "actor_id/session_id" scheme across agents?
- What is the minimal schema for symbol references (path + span vs stable ids)?

---

## Relationship to Existing Architecture

### How this complements PLAN-LIVING-DB.md

This plan extends the Living Database vision by providing **structured, versioned observability** without compromising core performance:

1. **Event Streams feed the Commit Stream**: Plugin hooks analyze events and can optionally surface insights back to core operations
2. **Cartridges unify both worlds**: Review insights and observability data become queryable alongside traditional structured memory cartridges
3. **Deterministic Function Calling**: LLM functions that generate review summaries or performance insights remain deterministic

### Integration with Current AI Foundation

The existing `src/llm/`, `src/plugins/`, `src/queries/`, and `src/cartridges/` structure already supports this architecture:

- **LLM Client**: Provides function calling for review summaries and performance analysis
- **Plugin Manager**: Already has hook infrastructure ready for extension
- **Natural Language Queries**: Intent system ready for review/observability extensions
- **Entity Cartridges**: Foundation for structured review and observability data

### Backward Compatibility

- Existing database operations unchanged
- Existing plugins continue to work
- New event streams are opt-in via configuration
- Natural language queries gracefully degrade when review/observability data unavailable