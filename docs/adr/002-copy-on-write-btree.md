# ADR-002: Copy-on-Write B+tree Strategy

**Status**: Accepted

**Date**: 2025-12-28

## Context

NorthstarDB needs an ordered key-value store that supports:

1. **Crash-safe updates**: Partial writes must not corrupt the tree
2. **MVCC snapshots**: Multiple tree versions must coexist
3. **Efficient scans**: Range queries for AI agent data access
4. **Predictable performance**: No sudden degradation from rebalancing

Traditional B-tree approaches:
- **In-place updates**: Crashes can corrupt internal nodes
- **Linked structures**: Complex recovery, hard to version
- **Append-only logs**: Terrible range scan performance

## Decision

NorthstarDB uses a **copy-on-write (COW) B+tree**:

### Core Design

1. **Path copy**: Updating a key copies all nodes from root to leaf
2. **Immutable pages**: Once written, pages never change
3. **Structural sharing**: Unmodified nodes shared between versions
4. **Atomic root switch**: New version published via meta page update

### Update Path

```
Before update (root at page 10):
[10] -> [20] -> [30: A=1, B=2]

Update A=3:
- Copy leaf [30] -> [31: A=3, B=2]
- Copy internal [20] -> [21] (update child pointer to 31)
- Copy root [10] -> [11] (update child pointer to 21)
- New root: 11, old root: 10 (still valid for old snapshots)
```

### Page Structure

```zig
// Common node header
const NodeHeader = struct {
    magic: u32 = 0x42545245,  // "BTRE"
    level: u16,                // 0 = leaf, >0 = internal
    key_count: u16,
    right_sibling: u64,        // For range scans
    checksum: u32,
};

// Leaf node: sorted key-value pairs
const LeafNode = struct {
    header: NodeHeader,
    entries: []Entry,
};

// Internal node: separator keys + child pointers
const InternalNode = struct {
    header: NodeHeader,
    separators: []Key,
    children: []u64,  // PageIds
};
```

### Split Strategy

When a node overflows:
1. Allocate new page(s)
2. Split entries evenly
3. Copy parent node with updated separator
4. Propagate up to root (may create new level)

### Key Benefits

- **Crash safety**: Partial updates simply fail; old tree intact
- **Versioning**: Multiple roots coexist without copying entire tree
- **Concurrency**: Readers never block (immutable pages)
- **Recovery**: Rebuild freelist from committed root only

## Consequences

### Positive

- **Crash safety**: Atomic commits via root switch
- **MVCC support**: Perfect fit with snapshot isolation
- **Fast scans**: B+tree leaf linkage enables efficient ranges
- **Simple recovery**: Only committed root is valid
- **Predictable performance**: No in-place rebalancing contention

### Negative

- **Write amplification**: Update copies O(height) pages
- **Fragmentation**: Old pages consume space until GC
- **Split costs**: New root level requires copying entire path
- **Freelist complexity**: Must track pages from all versions

### Mitigations

- **Write amplification**: Acceptable for read-heavy AI workloads
- **Fragmentation**: Freelist rebuild on open
- **Split costs**: Large page size (16KB) reduces tree height
- **Freelist complexity**: Simple freelist in V0, optimized later

## Related Specifications

- `spec/file_format_v0.md` - B+tree page format specification
- `spec/semantics_v0.md` - B+tree invariants and validation
- `src/pager.zig` - Page allocation and COW operations

## Alternatives Considered

1. **In-place B-tree**: Rejected due to crash complexity
2. **Append-only log**: Rejected due to scan performance
3. **LSM tree**: Rejected due to read amplification
4. **B-link tree**: Rejected due to complexity for V0

## Performance Characteristics

- **Point lookup**: O(height) = O(log_512(N)) for 16KB pages
- **Range scan**: O(K + height) where K = results
- **Insert/Delete**: O(height) pages copied
- **Space overhead**: ~2x for random updates (amortized better for sequential)
