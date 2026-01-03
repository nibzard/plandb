# Pager Tests

## Purpose

The Pager tests specification defines comprehensive test coverage areas, test scenarios, and property-based test requirements for the pager module. Tests ensure correctness of page I/O, cache behavior, free list management, validation logic, and concurrency safety. The testing strategy combines unit tests for individual functions, integration tests for multi-step workflows, and property-based tests for invariant verification.

## Test Coverage Areas

### Page I/O Operations

**Read Operations**:
- Read valid page from storage
- Read non-existent page (out of bounds)
- Read with buffer too small (error case)
- Read page with invalid checksum
- Read page with invalid magic number
- Read page with page ID mismatch

**Write Operations**:
- Write valid page to storage
- Write beyond current file size (extend)
- Write with buffer too small (error case)
- Write with invalid page structure
- Write with page ID mismatch
- Write page then read back (round-trip)

**Sync Operations**:
- Sync after write persists data
- Sync on memory storage (no-op)
- Multiple syncs are idempotent

### Cache Behavior

**Cache Hit**:
- Read cached page returns immediately
- Cache hit does not trigger I/O
- Cache hit updates LRU position
- Cache hit increments pin count

**Cache Miss**:
- Cache miss triggers storage read
- Cache miss populates cache
- Cache miss is slower than cache hit
- Cache miss followed by hit

**Cache Eviction**:
- Eviction when page limit exceeded
- Eviction when byte limit exceeded
- LRU page evicted first
- Pinned pages not evicted
- All pages pinned exceeds capacity

**Cache Invalidation**:
- Write invalidates cache entry
- Remove explicitly evicts page
- Clear removes unpinned pages only
- Unpin allows subsequent eviction

### Free List Management

**Page Allocation**:
- Allocate from free list (reuse)
- Allocate when free list empty (extend)
- Allocate prefers lowest page ID
- Allocate updates last_allocated_page

**Free Pages**:
- Free page added to free list
- Free page sorted in free list
- Free meta page rejected (error)
- Free duplicate page handled

**Free List Rebuild**:
- Rebuild identifies reachable pages
- Rebuild marks meta pages as in use
- Rebuild builds correct free list
- Rebuild handles empty database

### Validation Logic

**Checksum Validation**:
- Valid checksum passes
- Invalid header checksum detected
- Invalid page checksum detected
- Checksum calculation correct

**Magic Number Validation**:
- Valid PAGE_MAGIC accepted
- Invalid magic rejected
- Valid META_MAGIC accepted
- Invalid META_MAGIC rejected

**Page Validation**:
- Valid page passes all checks
- Invalid payload length detected
- Unsupported version rejected
- Page type validation

**Meta Page Selection**:
- Valid meta A and B: choose higher txn_id
- One valid meta: choose valid one
- Both invalid: return error
- Torn write detected (choose complete write)

### Concurrency Safety

**Lock Behavior**:
- Multiple readers can hold read lock
- Writer excludes all readers
- Try_lock returns None if lock unavailable
- Lock released on guard drop

**Atomic Operations**:
- Atomic increment thread-safe
- Compare-and-swap succeeds/fails correctly
- Memory ordering respected

**Concurrent Access**:
- Concurrent reads don't interfere
- Concurrent writes serialized correctly
- Mixed read/write workload safe

## Test Scenarios

### Unit Test Scenarios

**ReadPage Tests**:
1. Read first page (meta A) from newly created database
2. Read page beyond file size returns error
3. Read page with exactly page_size buffer succeeds
4. Read page with smaller buffer returns error
5. Read corrupted page (invalid checksum) returns error

**WritePage Tests**:
1. Write page to existing location succeeds
2. Write page to new location (extending file) succeeds
3. Write with invalid checksum returns error before write
4. Write page then read returns same data
5. Concurrent writes to different pages safe

**Cache Tests**:
1. Cache miss on first read
2. Cache hit on second read
3. Cache invalidated after write
4. Pinned page not evicted when cache full
5. Unpin allows eviction
6. LRU eviction when capacity exceeded

**Free List Tests**:
1. Allocate returns page from free list
2. Allocate extends file when free list empty
3. Free page added to free list
4. Free list maintained in sorted order
5. Free meta page returns error

### Integration Test Scenarios

**Database Open/Close**:
1. Open non-existent file creates new database
2. Open existing file reads meta pages
3. Open corrupted file returns error
4. Close releases all resources
5. Reopen after close sees persisted data

**Transaction Commit**:
1. Commit persists data across close/open
2. Commit with sync survives crash
3. Commit without sync lost on crash
4. Meta page updated correctly after commit
5. Committed transaction ID increases

**B+Tree Operations**:
1. Insert key-value pair persists
2. Update key persists new value
3. Delete key removes from storage
4. Range scan returns correct keys
5. Split creates new pages correctly

**Crash Recovery**:
1. Crash before commit: transaction lost
2. Crash after commit: transaction durable
3. Crash during write: torn write detected
4. Recovery chooses correct meta page
5. Recovery rebuilds free list correctly

### Property-Based Test Scenarios

**Round-Trip Properties**:
- Write page then read returns identical data
- Serialize then deserialize preserves value
- Encode then decode produces original structure

**Invariant Properties**:
- Free list always sorted
- Cache size never exceeds capacity (unless all pinned)
- Page ID in header matches requested ID
- Checksums always validate for valid pages

**Monotonicity Properties**:
- Transaction IDs always increase
- Allocated page IDs never decrease
- last_allocated_page always increases or stays same

**Idempotency Properties**:
- Sync is idempotent (multiple calls safe)
- Unpin is idempotent (can call multiple times)
- Close is idempotent (or consumes self)

## Property-Based Test Requirements

### Test Generators

**Page ID Generator**:
- Generate valid page IDs (0 to reasonable maximum)
- Generate invalid page IDs (very large values)
- Generate edge cases (0, 1, max value)

**Buffer Generator**:
- Generate valid page buffers (correct size, valid checksums)
- Generate invalid buffers (wrong size, bad checksums)
- Generate edge cases (empty, maximum size)

**Key-Value Generator**:
- Generate random keys (various lengths)
- Generate random values (various lengths)
- Generate empty keys and values (edge cases)

**Transaction Generator**:
- Generate random sequences of operations
- Generate valid mutations (put, delete)
- Generate invalid mutations (oversized keys/values)

### Invariant Verification

**Cache Invariants**:
- All entries in hash map are in LRU list
- LRU list contains all hash map entries
- Pin count never negative
- Sum of page sizes equals current_bytes (approximately)

**Free List Invariants**:
- Free list sorted in ascending order
- No duplicate page IDs in free list
- No meta page IDs (0 or 1) in free list
- All page IDs less than file size

**Page Invariants**:
- Page ID in header matches requested ID
- Payload length fits within page
- Checksums validate correctly
- Magic number matches expected value

### Shrink Strategies

**Minimal Counterexample**: Find smallest failing case

**Strategies**:
- Reduce page ID to minimum value that fails
- Shorten buffers to minimum size that fails
- Reduce number of operations in sequence
- Shrink key/value lengths to minimum

**Example**:
- Original failure: Insert 1000 keys, read fails on key 789
- Shrunk: Insert 2 keys, read fails on second key
- Minimal: Single insert then read fails

## Test Organization

### Unit Tests

**Location**: Tests in same module as code (Rust convention)

**Naming**: test_<function>_<scenario>
- test_read_page_valid_page_succeeds
- test_write_page_invalid_checksum_returns_error
- test_cache_hit_returns_immediately

**Structure**:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_read_page_valid_page_succeeds() {
        // Test implementation
    }
}
```

### Integration Tests

**Location**: tests/ directory or separate integration test file

**Naming**: test_<workflow>_scenario
- test_database_open_creates_new_file
- test_transaction_commit_persists_data
- test_crash_recovery_chooses_correct_meta

**Structure**:
```rust
// tests/pager_integration.rs
use northstar_core::pager::Pager;

#[test]
fn test_database_open_creates_new_file() {
    // Test implementation
}
```

### Property-Based Tests

**Library**: use proptest crate

**Location**: In module test or separate proptest file

**Structure**:
```rust
#[cfg(test)]
mod proptest_tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn test_round_trip_page(page_id in 0u64..10000) {
            // Test with generated page_id
        }
    }
}
```

## Rust Implementation Guidance

### Test Framework

**Built-in**: Rust's built-in test framework
```rust
#[cfg(test)]
mod tests {
    #[test]
    fn test_something() {
        assert_eq!(2 + 2, 4);
    }
}
```

**Run tests**: cargo test

### Property-Based Testing

**Library**: proptest crate

**Add to dev-dependencies**:
```toml
[dev-dependencies]
proptest = "1.0"
```

**Example**:
```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn test_roundtrip(page_id in any::<u64>()) {
        // Generate random page_id
        // Test round-trip behavior
    }
}
```

### Concurrency Testing

**Library**: Use std::thread for spawning threads

**Example**:
```rust
#[test]
fn test_concurrent_reads() {
    let pager = Arc::new(RwLock::new(Pager::open(&path)?));

    let handles: Vec<_> = (0..10)
        .map(|_| {
            let pager = Arc::clone(&pager);
            thread::spawn(move || {
                let pager = pager.read().unwrap();
                pager.read_page(1, &mut buffer)
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap()?;
    }
}
```

### Stress Testing

**Pattern**: Run many operations with multiple threads

**Example**:
```rust
#[test]
#[ignore]  // Run with --ignored flag
fn test_stress_concurrent_operations() {
    let pager = Arc::new(RwLock::new(Pager::open(&path)?));

    let handles: Vec<_> = (0..100)
        .map(|i| {
            let pager = Arc::clone(&pager);
            thread::spawn(move || {
                for j in 0..1000 {
                    pager.put(&format!("key{}{}", i, j), &format!("value{}", j));
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }
}
```

### Coverage Measurement

**Tool**: tarpaulin or cargo-llvm-cov

**Run**: cargo tarpaulin --out Html

**Goal**: High coverage for pager module
- Aim for >90% line coverage
- Test all error paths
- Test all edge cases
