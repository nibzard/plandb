# WAL Tests

## Purpose

WAL tests verify the correctness, robustness, and performance of the Write-Ahead Log implementation. Tests cover normal operations, edge cases, corruption scenarios, and crash recovery.

## Test Categories

### Unit Tests

Test individual functions and methods in isolation.

### Integration Tests

Test interactions between WAL and other components (Pager, B+tree, Transactions).

### Property-Based Tests

Use randomized inputs to verify invariants hold across all possible inputs.

### Hardening Tests

Simulate crashes, corruption, and adverse conditions to verify robustness.

### Performance Tests

Measure throughput, latency, and resource usage under various workloads.

### Crash Simulation Tests

Simulate process crashes at specific points to verify recovery works correctly.

## Test Scenarios

### Basic Operations

**Test: Create and Append**
- Create new WAL file
- Append single commit record
- Verify LSN is incremented
- Verify record can be read back

**Test: Append Multiple Records**
- Append 1000 commit records
- Verify LSN increments correctly
- Verify all records can be replayed
- Verify file size is correct

**Test: Read Existing WAL**
- Create WAL with records
- Close WAL
- Reopen WAL
- Verify current_lsn is recalculated correctly

**Test: Buffer Flush**
- Append records smaller than buffer
- Verify buffer fills
- Trigger flush by exceeding buffer size
- Verify data is written to file

**Test: Large Record Overflow**
- Append record larger than buffer size
- Verify record is written directly to file
- Verify record can be replayed

### Checksum Validation

**Test: Valid Header Checksum**
- Create record with valid header checksum
- Verify header validates successfully

**Test: Invalid Header Checksum**
- Corrupt header checksum in WAL file
- Attempt to replay WAL
- Verify corruption is detected
- Verify replay stops at corrupted record

**Test: Valid Payload Checksum**
- Create record with valid payload checksum
- Verify payload validates successfully

**Test: Invalid Payload Checksum**
- Corrupt payload data in WAL file
- Attempt to replay WAL
- Verify corruption is detected
- Verify corrupted record is skipped

### Record Encoding and Decoding

**Test: Put Operation Encoding**
- Create commit record with single Put operation
- Serialize to binary
- Deserialize from binary
- Verify original and deserialized match

**Test: Delete Operation Encoding**
- Create commit record with single Delete operation
- Serialize to binary
- Deserialize from binary
- Verify original and deserialized match

**Test: Multiple Operations Encoding**
- Create commit record with 100 operations (mixed Put and Delete)
- Serialize to binary
- Deserialize from binary
- Verify all operations are preserved

**Test: Key Size Limits**
- Create operation with key at MAX_KEY_SIZE (4KB)
- Verify encoding succeeds
- Create operation with key exceeding MAX_KEY_SIZE
- Verify encoding fails with KeyTooLarge error

**Test: Value Size Limits**
- Create operation with value at MAX_VALUE_SIZE (16MB)
- Verify encoding succeeds
- Create operation with value exceeding MAX_VALUE_SIZE
- Verify encoding fails with ValueTooLarge error

### Replay

**Test: Replay Empty WAL**
- Create empty WAL file
- Replay from LSN 1
- Verify no records are returned
- Verify last_lsn is 0

**Test: Replay Single Record**
- Append single commit record
- Replay WAL
- Verify one record is returned
- Verify record content matches

**Test: Replay Multiple Records**
- Append 100 commit records
- Replay WAL
- Verify all 100 records are returned
- Verify records are in correct order
- Verify last_lsn is 100

**Test: Replay From Middle**
- Append 100 commit records
- Replay from LSN 50
- Verify records 50-100 are returned (51 records)
- Verify records are in correct order

**Test: Replay With Checkpoint**
- Append 50 records
- Append checkpoint record
- Append 50 more records
- Replay from checkpoint
- Verify only last 50 records are replayed

**Test: Replay Past End**
- Append 10 records
- Replay from LSN 100
- Verify no records are returned
- Verify no error occurs

### Truncation

**Test: Truncate To Single Record**
- Append 100 records
- Truncate keeping only record 50
- Verify only record 50 remains
- Verify current_lsn is 1

**Test: Truncate To Last Record**
- Append 100 records
- Truncate keeping record 100
- Verify only record 100 remains
- Verify current_lsn is 1

**Test: Truncate To Nonexistent LSN**
- Append 100 records
- Truncate keeping record 200 (doesn't exist)
- Verify all records are removed
- Verify current_lsn is 0

**Test: Truncate Empty WAL**
- Create empty WAL
- Truncate to any LSN
- Verify WAL remains empty
- Verify no error occurs

### Corruption Handling

**Test: Corrupted Magic Number**
- Corrupt header magic in first record
- Attempt replay
- Verify corruption is detected
- Verify replay returns empty result

**Test: Corrupted Checksum**
- Corrupt header checksum
- Attempt replay
- Verify corruption is detected
- Verify replay stops at corruption

**Test: Truncated File**
- Truncate WAL file mid-record
- Attempt replay
- Verify incomplete record is detected
- Verify replay stops before incomplete record

**Test: Corrupted Payload**
- Corrupt payload bytes in a record
- Attempt replay
- Verify payload checksum fails
- Verify corrupted record is skipped
- Verify subsequent records are replayed

**Test: Garbage Data**
- Write random bytes to WAL file
- Attempt replay
- Verify corruption is detected immediately
- Verify no panic occurs

### Crash Simulation

**Test: Crash During Append**
- Start appending record
- Kill process before fsync
- Restart and recover
- Verify crashed transaction is not in WAL
- Verify WAL is consistent

**Test: Crash After Write Before Fsync**
- Append record to WAL
- Ensure write() succeeds but fsync() doesn't
- Kill process
- Restart and recover
- Verify record may or may not be present (depends on OS)

**Test: Crash During Checkpoint**
- Start checkpoint operation
- Kill process mid-checkpoint
- Restart and recover
- Verify database is consistent
- Verify WAL can be replayed from last valid checkpoint

**Test: Crash During Truncation**
- Start truncating WAL
- Kill process during truncation
- Restart and recover
- Verify WAL is either truncated or not (atomic operation)
- Verify WAL is consistent

### Concurrent Operations

**Test: Concurrent Appends**
- Spawn multiple threads
- Each thread appends records to same WAL
- Verify all records are present
- Verify LSNs are unique and sequential

**Test: Concurrent Read and Write**
- One thread appending records
- One thread replaying WAL
- Verify reader sees consistent snapshot
- Verify no race conditions occur

**Test: Concurrent Recovery Attempts**
- Attempt multiple recoveries simultaneously
- Verify only one succeeds
- Verify others fail or serialize

### Performance Tests

**Test: Append Throughput**
- Measure records appended per second
- Use 1KB records
- Target: > 10,000 records/sec on SSD

**Test: Large Record Throughput**
- Measure throughput with 1MB records
- Target: > 100 records/sec on SSD

**Test: Replay Performance**
- Append 100,000 records
- Measure time to replay all records
- Target: > 50,000 records/sec

**Test: Truncation Performance**
- Append 100,000 records
- Measure time to truncate to middle
- Target: < 1 second

**Test: Memory Usage**
- Monitor memory during various operations
- Verify no memory leaks
- Verify memory usage is bounded

## Property-Based Tests

### Invariant: LSN Monotonicity
- Generate random sequence of append operations
- Verify LSNs are strictly increasing
- Verify no gaps in LSN sequence

### Invariant: Checksum Validity
- Generate random commit records
- Calculate checksums
- Verify checksum validation passes
- Corrupt random bytes
- Verify checksum validation fails

### Invariant: Round-Trip Encoding
- Generate random commit records
- Serialize to binary
- Deserialize from binary
- Verify original equals deserialized

### Invariant: Replay Idempotency
- Generate random WAL state
- Replay WAL twice
- Verify both replays produce identical results

### Invariant: Append-Only
- Generate random WAL state
- Verify file position never decreases
- Verify records are never modified in place

## Hardening Tests

### Fuzzing

**Test: Random Input Fuzzing**
- Use fuzzer to generate random byte sequences
- Feed to WAL decoder
- Verify no panics occur
- Verify appropriate errors are returned

**Test: API Fuzzing**
- Use fuzzer to generate random API call sequences
- Call WAL operations with random parameters
- Verify no panics occur
- Verify invariants are maintained

### Stress Tests

**Test: High Append Rate**
- Append records as fast as possible
- Run for 1 hour
- Verify no errors occur
- Verify performance doesn't degrade

**Test: Large WAL**
- Append 10 million records
- Verify WAL can be opened and replayed
- Verify memory usage is reasonable
- Verify performance doesn't degrade

**Test: Rapid Open/Close**
- Open WAL, append one record, close
- Repeat 10,000 times
- Verify no resource leaks occur

### Resource Exhaustion

**Test: Out of Disk Space**
- Fill disk to near capacity
- Attempt to append record
- Verify appropriate error is returned
- Verify WAL is not corrupted

**Test: Out of Memory**
- Allocate memory until near exhaustion
- Attempt to replay WAL
- Verify appropriate error is returned
- Verify process doesn't crash

**Test: File Handle Exhaustion**
- Open many file handles
- Attempt to open WAL
- Verify appropriate error is returned
- Verify resource cleanup on error

## Test Implementation Guidance

### Rust Testing Framework

Use standard Rust testing tools:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_and_append() {
        // Test implementation
    }

    #[test]
    fn test_append_multiple_records() {
        // Test implementation
    }
}
```

### Property-Based Testing with Proptest

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn prop_lsn_monotonicity(ops in prop::collection::vec(any_operation(), 1..1000)) {
        // Test that LSNs are always increasing
    }

    #[test]
    fn prop_roundtrip_encoding(record in any_commit_record()) {
        // Test that encode/decode preserves data
    }
}
```

### Crash Simulation with Process Kill

```rust
#[test]
fn test_crash_during_append() {
    // Fork process
    // Child: Start append, kill mid-operation
    // Parent: Wait for child, verify recovery
}
```

### Corruption Simulation

```rust
#[test]
fn test_corrupted_magic() {
    let temp_dir = TempDir::new().unwrap();
    let wal_path = temp_dir.path().join("test.wal");

    // Create WAL with records
    let mut wal = WriteAheadLog::create(&wal_path).unwrap();
    wal.append_commit_record(test_record()).unwrap();
    wal.sync().unwrap();
    drop(wal);

    // Corrupt magic number
    let mut file = OpenOptions::new()
        .write(true)
        .open(&wal_path)
        .unwrap();
    file.seek(SeekFrom::Start(0)).unwrap();
    file.write_all(&[0xFF, 0xFF, 0xFF, 0xFF]).unwrap();
    drop(file);

    // Verify replay detects corruption
    let wal = WriteAheadLog::open(&wal_path).unwrap();
    let result = wal.replay_from(1, &allocator).unwrap();
    assert!(result.is_empty());
}
```

### Performance Testing with Criterion

```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion, BenchmarkId};

fn bench_append_throughput(c: &mut Criterion) {
    let mut group = c.benchmark_group("append");

    for size in [1024, 4096, 16384].iter() {
        group.bench_with_input(BenchmarkId::from_parameter(size), size, |b, &size| {
            let temp_dir = TempDir::new().unwrap();
            let wal_path = temp_dir.path().join("test.wal");
            let mut wal = WriteAheadLog::create(&wal_path).unwrap();
            let record = create_test_record(size);

            b.iter(|| {
                wal.append_commit_record(black_box(&record)).unwrap();
            });
        });
    }

    group.finish();
}

criterion_group!(benches, bench_append_throughput);
criterion_main!(benches);
```

## Test Organization

### Directory Structure

```
northstar_core/wal/tests/
├── mod.rs                    # Test module entry point
├── basic_tests.rs            # Basic operation tests
├── encoding_tests.rs         # Encoding/decoding tests
├── replay_tests.rs           # Replay tests
├── truncation_tests.rs       # Truncation tests
├── corruption_tests.rs       # Corruption handling tests
├── crash_tests.rs            # Crash simulation tests
├── concurrency_tests.rs      # Concurrent operation tests
├── property_tests.rs         # Property-based tests
└── hardening_tests.rs        # Hardening and fuzzing tests
```

### Test Utilities

Create reusable test helpers:

```rust
// test_utils.rs
pub fn create_test_wal() -> (TempDir, WriteAheadLog);
pub fn create_test_record(op_count: usize) -> CommitRecord;
pub fn corrupt_file_at(path: &Path, offset: usize, bytes: &[u8]);
pub fn verify_wal_consistent(wal: &WriteAheadLog) -> bool;
pub fn count_records_in_wal(wal: &WriteAheadLog) -> usize;
```

## CI/CD Integration

### Automated Testing

Run all tests in CI:

```bash
# Run unit tests
cargo test --lib

# Run integration tests
cargo test --test '*'

# Run property tests
cargo test --test property_tests

# Run with sanitizers
cargo test -- sanitize address
cargo test -- sanitize memory

# Run with coverage
cargo tarpaulin --out Xml
```

### Performance Regression Detection

Run benchmarks and compare against baseline:

```bash
cargo bench -- --save-baseline main

# After changes
cargo bench -- --baseline main
```

### Fuzzing in CI

Run fuzzers for limited time:

```bash
cargo fuzz run wal_decoder -- -max_total_time=60
```

## Test Metrics

Track these metrics:

- **Test coverage**: Target > 90% line coverage
- **Test execution time**: All tests should complete in < 5 minutes
- **Memory usage**: No test should leak memory
- **Flaky tests**: Zero tolerance for flaky tests
- **Performance**: Benchmarks should not regress by > 10%
