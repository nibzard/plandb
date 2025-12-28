# ADR-003: Commit Stream Format

**Status**: Accepted

**Date**: 2025-12-28

## Context

NorthstarDB's vision requires **deterministic replay** of all transactions:

1. **AI agent debugging**: Reproduce exact state for bug analysis
2. **Replication foundation**: Future multi-node replication needs change log
3. **Cartridge builds**: AI plugins replay commits to extract knowledge
4. **Time travel**: Audit trails and historical analysis

Key requirements:
- **Sufficient for replay**: Records must contain all information to reconstruct state
- **Append-only**: Immutable log for easy replication and archival
- **Crash-safe**: Must survive process crashes
- **Efficient scanning**: Plugins need to process entire stream

## Decision

NorthstarDB uses a **canonical commit record format** in an append-only log:

### Core Design

1. **One record per commit**: Each successful transaction emits exactly one record
2. **Operation-based**: Records list mutations (put/delete), not page diffs
3. **Canonical encoding**: Schema-agnostic binary format with framing
4. **Append-only storage**: Sequential writes, no in-place modifications

### Record Structure

```zig
const CommitRecord = struct {
    // Header (fixed size)
    magic: u32 = 0x434f4d54,        // "COMT"
    version: u16 = 0,
    flags: u16,
    txn_id: u64,
    timestamp_ms: u64,

    // Mutation count
    mutation_count: u32,

    // Mutations (variable length)
    mutations: []Mutation,

    // Trailer
    checksum: u32,                   // CRC32C of entire record
};

const Mutation = struct {
    op_type: u8,                     // 0 = put, 1 = delete
    key_len: u32,
    val_len: u32,                    // 0 for delete
    key: []u8,
    value: []u8,                     // empty for delete
};
```

### Framing Format

```
[Magic:4][Version:2][Flags:2][TxnId:8][Timestamp:8][MutationCount:4]
[Mutation1][Mutation2]...[MutationN]
[Checksum:4]
```

Each mutation:
```
[OpType:1][KeyLen:4][ValLen:4][Key:KeyLen][Value:ValLen]
```

### Storage Options

V0 supports either:
- **Option A**: Separate `<db>.log` file (simpler append ordering)
- **Option B**: Reserved log pages in main DB file (single file)

### Commit Protocol

1. Begin write transaction
2. Apply mutations to B+tree builder (creates new pages)
3. Build commit record from mutation list
4. Write all new B+tree pages
5. Append commit record to log
6. Update meta page with new root and LSN
7. fsync both files

### Replay Protocol

To replay to TxnId T:
1. Scan commit stream from start
2. Apply each record with txn_id <= T
3. Reconstruct B+tree state
4. Result must match snapshot at T

## Consequences

### Positive

- **Deterministic replay**: Operation log enables exact reconstruction
- **Replication-ready**: Append-only format perfect for streaming replicas
- **AI-friendly**: Plugins can process stream to build knowledge cartridges
- **Debugging**: Exact transaction history for bug analysis
- **Audit trail**: Complete history of all changes

### Negative

- **Write amplification**: Changes recorded twice (B+tree + log)
- **Log growth**: Requires archival/compaction for long-running databases
- **Replay cost**: Rebuilding state requires scanning entire log
- **Format evolution**: Schema changes require migration logic

### Mitigations

- **Write amplification**: Acceptable tradeoff for determinism
- **Log growth**: Log compaction in future releases
- **Replay cost**: Snapshotting + incremental replay
- **Format evolution**: Version field + backward compatibility

## Related Specifications

- `spec/semantics_v0.md` - Commit record semantics
- `src/replay.zig` - Replay implementation
- `src/wal.zig` - Write-ahead log implementation
- `PLAN-LIVING-DB.md` - AI plugin use of commit stream

## Alternatives Considered

1. **Page-based WAL**: Rejected (page diffs not portable across formats)
2. **Diff-based log**: Rejected (complex schema dependencies)
3. **Event sourcing**: Rejected (too high-level for storage engine)
4. **No commit log**: Rejected (cannot support deterministic replay)

## Future Extensions

- **Compression**: Snappy/LZ4 for large commit records
- **Batching**: Multiple commits per log segment
- **Indexing**: Optional index by entity/topic for fast replay
- **Replication**: Network protocol for streaming commits
