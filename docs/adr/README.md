# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records (ADRs) for NorthstarDB. ADRs document significant architectural decisions, their context, and consequences.

## ADR Template

```markdown
# ADR-XXX: [Title]

**Status**: Accepted | Proposed | Deprecated | Superseded

**Date**: YYYY-MM-DD

**Context**
[What is the issue that we're seeing that is motivating this decision or change?]

**Decision**
[What is the change that we're proposing and/or doing?]

**Consequences**
[What becomes easier or more difficult to do because of this change?]
- Positive: ...
- Negative: ...
```

## Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| ADR-001 | MVCC Snapshot Isolation Design | Accepted | 2025-12-28 |
| ADR-002 | Copy-on-Write B+tree Strategy | Accepted | 2025-12-28 |
| ADR-003 | Commit Stream Format | Accepted | 2025-12-28 |
| ADR-004 | Cartridge Artifact Format | Accepted | 2025-12-28 |
| ADR-005 | AI Plugin Architecture | Accepted | 2025-12-28 |
| ADR-006 | Single-Writer Concurrency Model | Accepted | 2025-12-28 |

## Process

1. Create a new ADR by copying the template
2. Fill in the context, decision, and consequences
3. Set status to "Proposed" and discuss with team
4. Update status to "Accepted" when consensus reached
5. Reference ADRs in code comments and specs
