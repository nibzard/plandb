# ADR-001: MVCC Snapshot Isolation Design

**Status**: Accepted

**Date**: 2025-12-28

## Context

NorthstarDB targets **massive read concurrency** for AI agent orchestration workloads. Key requirements:

1. **Never-blocking readers**: AI coding agents run hundreds of concurrent queries
2. **Deterministic replay**: Every transaction must be reproducible from the commit stream
3. **Time-travel queries**: Agents need to inspect historical state at any TxnId
4. **Crash safety**: Process crashes must not corrupt the database

Traditional approaches considered:
- **Read-write locks**: Readers block each other, unacceptable for AI workloads
- **Optimistic concurrency control**: Retry storms under high contention
- **Single-version with locks**: Cannot support time-travel queries

## Decision

NorthstarDB uses **Multi-Version Concurrency Control (MVCC) with snapshot isolation**:

### Core Design

1. **Immutable snapshots**: Each read transaction gets a stable view at a specific TxnId
2. **Copy-on-write writes**: Writer creates new versions, never modifies existing pages
3. **Atomic root switch**: Commit publishes new root by updating meta page atomically
4. **Version chain**: Each TxnId maps to a B+tree root pointer

### Implementation

```zig
// Snapshot structure
const Snapshot = struct {
    txn_id: u64,
    root_page_id: u64,
    // Immutable: all reads through this snapshot see same state
};

// Read transaction
const ReadTxn = struct {
    snapshot: Snapshot,
    // All reads use snapshot.root_page_id
    // No locks needed: pages are immutable
};

// Write transaction
const WriteTxn = struct {
    builder: BtreeBuilder,  // Creates new pages
    // On commit: atomically switch meta.root to new root
};
```

### Commit Protocol

1. Writer allocates new pages for modifications
2. Write all new pages to disk
3. Write commit record to log
4. Update meta page (toggle A/B) with new root and TxnId
5. fsync to make durable

### Open Protocol

1. Read both meta pages (A and B)
2. Validate checksums
3. Choose meta with highest valid TxnId
4. Load root and serve queries

## Consequences

### Positive

- **Lock-free reads**: Hundreds of concurrent readers with zero contention
- **Time travel**: Historical queries via `begin_read(txn_id)`
- **Crash safety**: Atomic meta page switch provides all-or-nothing commits
- **Deterministic replay**: Commit stream + MVCC enables exact state reconstruction
- **Simple reasoning**: Immutability eliminates whole class of concurrency bugs

### Negative

- **Write amplification**: Each update creates new pages (COW overhead)
- **Garbage collection**: Old versions need cleanup (freelist management)
- **Space amplification**: Multiple versions coexist until GC
- **Complex recovery**: Must rebuild version mapping after crash

### Mitigations

- **Write amplification**: Acceptable for AI workloads (read-heavy, write-light)
- **Garbage collection**: Freelist rebuild on open, async GC in future
- **Space amplification**: Page-level compression in future
- **Complex recovery**: Reference model validates correctness

## Related Specifications

- `spec/semantics_v0.md` - Snapshot isolation semantics
- `spec/file_format_v0.md` - Meta page format and atomic switch
- `src/snapshot.zig` - Snapshot implementation
- `src/txn.zig` - Transaction implementation

## Alternatives Considered

1. **Lock-based concurrency**: Rejected due to reader blocking
2. **Optimistic concurrency**: Rejected due to retry storms
3. **Append-only log**: Rejected due to scan performance
4. **Single version in-memory**: Rejected due to no time travel
