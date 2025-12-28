# ADR-006: Single-Writer Concurrency Model

**Status**: Accepted

**Date**: 2025-12-28

## Context

NorthstarDB targets **massive read concurrency** for AI agent orchestration, with a specific design constraint:

1. **Embedded database**: Single process, single file (V0)
2. **Read-heavy workload**: AI agents run hundreds of concurrent queries
3. **Write-light workload**: Commits are infrequent relative to reads
4. **Deterministic commit stream**: Single serialized write order simplifies replay

Multi-writer approaches considered:
- **Optimistic concurrency**: Retry storms under high contention
- **Pessimistic locking**: Complex deadlock detection
- **Sharded writing**: Adds complexity for embedded use case

## Decision

NorthstarDB V0 uses a **single-writer, many-reader (SWMR) concurrency model**:

### Core Design

1. **At most one WriteTxn active**: `begin_write()` returns error if writer busy
2. **Lock-free reads**: Multiple concurrent ReadTxn with zero contention
3. **Atomic root switch**: Commit publishes new version without blocking readers
4. **Serialized writes**: Single writer guarantees total commit order

### API Behavior

```zig
// Write transaction
pub fn beginWrite(db: *Db) WriteBusyError!WriteTxn {
    if (db.active_writer != null) {
        return error.WriteBusy;  // Explicit error, no blocking
    }
    db.active_writer = WriteTxn.init(...);
    return db.active_writer.?;
}

// Read transaction (never blocks)
pub fn beginRead(db: *Db) ReadTxn {
    return ReadTxn{
        .snapshot = db.latest_snapshot,
        // No lock needed: snapshot is immutable
    };
}
```

### Commit Protocol

1. Writer allocates new pages for modifications
2. Build new B+tree root from updates
3. Append commit record to log
4. Atomically update meta page (toggle A/B)
5. Readers with old snapshots continue unaffected
6. New readers see latest committed state

### Coordination Point

- **Commit time**: Only coordination is at commit (fsync, meta update)
- **Read path**: Zero coordination, readers never block
- **Writer conflict**: Second writer gets explicit `WriteBusy` error

### Error Handling

```zig
const WriteBusyError = error{
    WriteBusy,  // Another writer active
};

// Application can handle appropriately:
// - Retry with backoff
// - Queue write for later
// - Return error to user
```

## Consequences

### Positive

- **Simple implementation**: No deadlock detection, no conflict resolution
- **Lock-free reads**: Perfect for AI agent workloads (hundreds of concurrent queries)
- **Deterministic commit stream**: Single writer = total order = easy replay
- **Predictable performance**: No retry storms, no lock contention
- **Correctness**: Single writer eliminates write-write conflicts

### Negative

- **Write throughput limited**: One commit at a time (acceptable for write-light workloads)
- **Writer bottleneck**: High write frequency requires queuing or retry
- **Not suitable for write-heavy**: V0 not designed for high write concurrency

### Mitigations

- **Write throughput**: Acceptable for AI workloads (read-heavy, write-light)
- **Writer bottleneck**: Applications can batch writes or implement queues
- **Future upgrade**: V1 can add multi-writer without changing reader semantics

## Related Specifications

- `spec/semantics_v0.md` - Single-writer semantics
- `src/db.zig:280` - WriteBusy error implementation
- `src/txn.zig` - Transaction implementation

## Upgrade Path to Multi-Writer

V0 design enables V1 multi-writer extension:

1. **Conflict detection**: Add write-write conflict checks at commit
2. **Lock-free readers preserved**: MVCC snapshot isolation unchanged
3. **Backward compatibility**: Single-writer databases work unchanged

```zig
// V1 multi-writer extension
pub fn beginWriteV1(db: *Db) WriteTxn {
    return WriteTxn{
        .snapshot = db.beginRead(),  // Read snapshot
        .conflict_set = HashSet(Key).init(...),
    };
}

pub fn commitV1(txn: *WriteTxn) !TxnId {
    // Detect conflicts with concurrent commits
    if (hasConflicts(txn)) {
        return error.WriteConflict;
    }
    // Same V0 commit protocol
}
```

## Workload Characterization

### AI Agent Orchestration (Target Workload)
- **Reads**: ~1000 queries per second (semantic searches, entity lookups)
- **Writes**: ~10 commits per second (code changes, task updates)
- **Read/Write Ratio**: 100:1
- **Single Writer Suitability**: Perfect fit

### Write-Heavy Workloads (Not Target)
- **High-frequency writes**: >100 commits per second
- **Batch imports**: Large bulk write operations
- **Multi-user writes**: Concurrent write transactions
- **Single Writer Suitability**: Poor fit, use V1 multi-writer

## Alternatives Considered

1. **Multi-writer with locking**: Rejected (complex, deadlocks)
2. **Optimistic concurrency**: Rejected (retry storms, unpredictable latency)
3. **Append-only log**: Rejected (terrible range scan performance)
4. **Sharded writers**: Rejected (too complex for V0 embedded DB)

## Performance Characteristics

- **Read concurrency**: Unlimited (lock-free, zero coordination)
- **Write throughput**: Limited by commit serialization
- **Commit latency**: O(log N) for B+tree update + fsync
- **Reader-writer contention**: Zero (readers use immutable snapshots)
