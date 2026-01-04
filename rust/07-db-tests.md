# Database Integration Tests

## Purpose

This document describes comprehensive integration test scenarios for NorthstarDB, covering database lifecycle, transactions, concurrency, error handling, recovery, and performance characteristics. Integration tests verify that all components work together correctly and that the database behaves as expected in real-world usage patterns.

## Testing Philosophy

### Test Categories

**Unit Tests**: Test individual components in isolation
- Pager tests (cache, I/O, allocation)
- WAL tests (append, recovery, truncation)
- B+Tree tests (insert, delete, search, split)
- SnapshotRegistry tests (registration, cleanup)
- Transaction tests (get, put, delete, commit, rollback)

**Integration Tests**: Test components working together
- Database lifecycle (open, close, reopen)
- Transaction workflows (read, write, commit, rollback)
- Concurrency (multiple readers, single writer)
- Crash recovery (WAL replay, database recovery)
- End-to-end scenarios (realistic workloads)

**Property Tests**: Test invariants with randomized inputs
- Snapshot isolation preserved
- Write serialization enforced
- Atomic commit guaranteed
- No data loss on crash

**Hardening Tests**: Test resilience to failures
- Crash during commit
- Disk full during write
- Corrupted data recovery
- Resource exhaustion

**Benchmarks**: Measure performance
- Transaction throughput
- Read latency
- Write latency
- Scan performance
- Concurrent reader scalability

## Test Organization

### Directory Structure

```
northstar-core/tests/
├── integration/
│   ├── mod.rs
│   ├── lifecycle_tests.rs       # Open, close, reopen
│   ├── transaction_tests.rs     # Read/write transactions
│   ├── concurrency_tests.rs     # Concurrent operations
│   ├── recovery_tests.rs        # Crash recovery
│   ├── config_tests.rs          # Configuration validation
│   └── error_tests.rs           # Error handling
├── property/
│   ├── mod.rs
│   ├── isolation_tests.rs       # Snapshot isolation
│   ├── atomicity_tests.rs       # Atomic commit
│   └── durability_tests.rs      # Crash recovery
├── hardening/
│   ├── mod.rs
│   ├── crash_tests.rs           # Crash scenarios
│   ├── corruption_tests.rs      # Data corruption
│   └── resource_tests.rs        # Resource exhaustion
└── benchmarks/
    ├── mod.rs
    ├── throughput.rs            # Transaction throughput
    ├── latency.rs               # Operation latency
    └── concurrency.rs           # Concurrent operations
```

### Test Helpers

**Test Database Setup**:
```rust
pub fn setup_test_db(name: &str) -> (tempfile::NamedTempFile, Db) {
    let file = tempfile::named();
    let path = file.path();
    let db = Db::builder()
        .path(path)
        .cache_size(256)          // Small cache for tests
        .page_size(4096)          // Small pages for tests
        .build()
        .expect("test db open failed");
    (file, db)
}

pub fn cleanup_test_db(db: Db) -> Result<(), Error> {
    db.close()
}
```

**Test Data Generation**:
```rust
pub fn random_key(size: usize) -> Vec<u8> {
    use rand::Rng;
    let mut key = vec![0u8; size];
    rand::thread_rng().fill(&mut key[..]);
    key
}

pub fn random_value(size: usize) -> Vec<u8> {
    random_key(size)
}

pub fn generate_test_data(count: usize, key_size: usize, value_size: usize) -> Vec<(Vec<u8>, Vec<u8>)> {
    (0..count)
        .map(|_| (random_key(key_size), random_value(value_size)))
        .collect()
}
```

## Lifecycle Tests

### Test 1: Open New Database

**Description**: Verify opening a new database creates valid state

**Steps**:
1. Open non-existent database file
2. Verify database is open (is_open == true)
3. Verify file created on disk
4. Verify B+Tree initialized (empty tree)
5. Verify genesis snapshot exists (txn_id 0)

**Assertions**:
- Db::open succeeds
- File exists
- db.is_open() == true
- db.begin_read() succeeds (can create transaction)
- txn.get() returns NotFound for any key (empty database)

**Example**:
```rust
#[test]
fn test_open_new_database() {
    let (file, db) = setup_test_db("test_open_new");

    assert!(db.is_open());

    let txn = db.begin_read().unwrap();
    assert!(txn.get(b"key").is_err());

    db.close().unwrap();
    assert!(file.path().exists());
}
```

### Test 2: Close and Reopen

**Description**: Verify database persists across close and reopen

**Steps**:
1. Open new database
2. Write transaction: put key1=value1, key2=value2
3. Commit transaction
4. Close database
5. Reopen database
6. Read transaction: verify key1 and key2 exist

**Assertions**:
- Initial write succeeds
- Close succeeds
- Reopen succeeds
- Data persisted (key1, key2 found)
- No data loss

**Example**:
```rust
#[test]
fn test_close_and_reopen() {
    let file_path = "test_close_reopen.db";

    // Write data
    {
        let db = Db::open(file_path).unwrap();
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key1", b"value1").unwrap();
        txn.put(b"key2", b"value2").unwrap();
        txn.commit().unwrap();
        db.close().unwrap();
    }

    // Reopen and verify
    let db = Db::open(file_path).unwrap();
    let txn = db.begin_read().unwrap();
    assert_eq!(txn.get(b"key1").unwrap(), b"value1");
    assert_eq!(txn.get(b"key2").unwrap(), b"value2");

    db.close().unwrap();
    std::fs::remove_file(file_path).unwrap();
}
```

### Test 3: Multiple Close Calls (Idempotent)

**Description**: Verify multiple close calls are safe

**Steps**:
1. Open database
2. Call db.close() (first call)
3. Call db.close() again (second call)
4. Verify both succeed

**Assertions**:
- First close() returns Ok(())
- Second close() returns Ok(())
- Database is closed after first call
- No errors on second call

**Example**:
```rust
#[test]
fn test_close_is_idempotent() {
    let (file, db) = setup_test_db("test_close_idempotent");

    db.close().unwrap();
    db.close().unwrap();  // Should not error
}
```

### Test 4: Drop Closes Database

**Description**: Verify Drop trait closes database

**Steps**:
1. Open database
2. Drop Db handle (explicitly or via scope)
3. Verify file handle released (can delete file)

**Assertions**:
- Db drops without panic
- File handle closed (can delete file on Windows)
- Resources cleaned up

**Example**:
```rust
#[test]
fn test_drop_closes_database() {
    let file_path = "test_drop.db";

    {
        let db = Db::open(file_path).unwrap();
        // db drops here
    }

    // File should be closed, can delete
    std::fs::remove_file(file_path).unwrap();
}
```

## Transaction Tests

### Test 5: Read Transaction Get

**Description**: Verify read transaction can read committed data

**Steps**:
1. Open database
2. Write transaction: put key1=value1, commit
3. Read transaction: get key1
4. Verify value matches

**Assertions**:
- Write commit succeeds
- Read get succeeds
- Value matches what was written
- Snapshot isolation sees committed data

**Example**:
```rust
#[test]
fn test_read_transaction_get() {
    let (file, db) = setup_test_db("test_read_get");

    // Write data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key1", b"value1").unwrap();
        txn.commit().unwrap();
    }

    // Read data
    let txn = db.begin_read().unwrap();
    let value = txn.get(b"key1").unwrap();
    assert_eq!(value, b"value1");
}
```

### Test 6: Write Transaction Read-Your-Writes

**Description**: Verify write transaction sees its own writes

**Steps**:
1. Begin write transaction
2. Put key1=value1
3. Get key1 (should return value1)
4. Commit transaction

**Assertions**:
- put succeeds
- get returns value written in same transaction
- Read-your-writes enforced

**Example**:
```rust
#[test]
fn test_write_transaction_read_your_writes() {
    let (file, db) = setup_test_db("test_read_your_writes");

    let mut txn = db.begin_write().unwrap();
    txn.put(b"key1", b"value1").unwrap();
    let value = txn.get(b"key1").unwrap();
    assert_eq!(value, b"value1");
    txn.commit().unwrap();
}
```

### Test 7: Write Transaction Rollback

**Description**: Verify rollback discards mutations

**Steps**:
1. Begin write transaction
2. Put key1=value1
3. Rollback transaction
4. Begin read transaction
5. Get key1 (should return NotFound)

**Assertions**:
- put succeeds (buffered)
- rollback succeeds
- key1 not found (mutation discarded)
- No data persisted

**Example**:
```rust
#[test]
fn test_write_transaction_rollback() {
    let (file, db) = setup_test_db("test_rollback");

    let mut txn = db.begin_write().unwrap();
    txn.put(b"key1", b"value1").unwrap();
    txn.rollback().unwrap();

    let txn = db.begin_read().unwrap();
    assert!(txn.get(b"key1").is_err());
}
```

### Test 8: Scan Empty Range

**Description**: Verify scan on empty database returns empty iterator

**Steps**:
1. Open new database (empty)
2. Begin read transaction
3. Scan from "a" to "z"
4. Verify iterator yields no results

**Assertions**:
- scan succeeds
- Iterator returns no items
- next() returns None immediately

**Example**:
```rust
#[test]
fn test_scan_empty_range() {
    let (file, db) = setup_test_db("test_scan_empty");

    let txn = db.begin_read().unwrap();
    let iter = txn.scan(b"a", b"z").unwrap();
    assert!(iter.next().is_none());
}
```

### Test 9: Scan Populated Range

**Description**: Verify scan returns all keys in range

**Steps**:
1. Write transaction: put key1=value1, key2=value2, key3=value3
2. Commit
3. Read transaction: scan from key1 to key3
4. Verify iterator yields key1, key2, key3 in order

**Assertions**:
- scan succeeds
- Iterator returns all keys in range
- Keys returned in sorted order
- Values match written values

**Example**:
```rust
#[test]
fn test_scan_populated_range() {
    let (file, db) = setup_test_db("test_scan_populated");

    // Write data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key1", b"value1").unwrap();
        txn.put(b"key2", b"value2").unwrap();
        txn.put(b"key3", b"value3").unwrap();
        txn.commit().unwrap();
    }

    // Scan
    let txn = db.begin_read().unwrap();
    let iter = txn.scan(b"key1", b"key3").unwrap();

    let results: Vec<(Vec<u8>, Vec<u8>)> = iter.collect();
    assert_eq!(results.len(), 3);
    assert_eq!(results[0].0, b"key1");
    assert_eq!(results[1].0, b"key2");
    assert_eq!(results[2].0, b"key3");
}
```

## Concurrency Tests

### Test 10: Concurrent Readers

**Description**: Verify multiple read transactions can proceed concurrently

**Steps**:
1. Spawn 10 threads
2. Each thread opens read transaction
3. Each thread performs get operation
4. Verify all threads succeed

**Assertions**:
- All 10 readers created successfully
- All get operations succeed
- No blocking between readers
- All readers see consistent snapshot

**Example**:
```rust
#[test]
fn test_concurrent_readers() {
    use std::sync::Arc;
    use std::thread;

    let (file, db) = setup_test_db("test_concurrent_readers");
    let db = Arc::new(db);

    // Write test data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key1", b"value1").unwrap();
        txn.commit().unwrap();
    }

    // Spawn 10 concurrent readers
    let handles: Vec<_> = (0..10)
        .map(|_| {
            let db = Arc::clone(&db);
            thread::spawn(move || {
                let txn = db.begin_read().unwrap();
                txn.get(b"key1").unwrap()
            })
        })
        .collect();

    // Verify all succeed
    for handle in handles {
        let value = handle.join().unwrap();
        assert_eq!(value, b"value1");
    }
}
```

### Test 11: Single Writer Serialization

**Description**: Verify only one write transaction at a time

**Steps**:
1. Spawn thread 1: begin_write, sleep 100ms, commit
2. Spawn thread 2: begin_write immediately
3. Verify thread 2 blocks until thread 1 commits
4. Verify both transactions commit serially

**Assertions**:
- Thread 1 begins write immediately
- Thread 2 blocks on begin_write until thread 1 commits
- Both transactions commit successfully
- No write-write conflict

**Example**:
```rust
#[test]
fn test_single_writer_serialization() {
    use std::sync::Arc;
    use std::thread::{self, sleep};
    use std::time::Duration;

    let (file, db) = setup_test_db("test_writer_serialization");
    let db = Arc::new(db);

    // Thread 1: Long write transaction
    let db1 = Arc::clone(&db);
    let handle1 = thread::spawn(move || {
        let mut txn = db1.begin_write().unwrap();
        txn.put(b"key1", b"value1").unwrap();
        sleep(Duration::from_millis(100));
        txn.commit().unwrap();
    });

    // Thread 2: Should block until thread 1 commits
    let db2 = Arc::clone(&db);
    let handle2 = thread::spawn(move || {
        sleep(Duration::from_millis(10));  // Ensure thread 1 starts first
        let start = std::time::Instant::now();
        let mut txn = db2.begin_write().unwrap();
        let elapsed = start.elapsed();
        assert!(elapsed >= Duration::from_millis(90));  // Blocked for ~100ms
        txn.put(b"key2", b"value2").unwrap();
        txn.commit().unwrap();
    });

    handle1.join().unwrap();
    handle2.join().unwrap();
}
```

### Test 12: Readers Don't Block Writer

**Description**: Verify active readers don't block writer

**Steps**:
1. Spawn 10 readers (keep transactions open)
2. Spawn writer while readers active
3. Verify writer begins immediately (not blocked by readers)
4. Verify readers continue working

**Assertions**:
- Readers created successfully
- Writer starts without blocking (acquires write lock)
- Readers still have valid snapshots (pre-writer)
- Writer commits new snapshot
- Future readers see writer's changes

**Example**:
```rust
#[test]
fn test_readers_dont_block_writer() {
    use std::sync::{Arc, Mutex};
    use std::thread::{self, sleep};
    use std::time::Duration;

    let (file, db) = setup_test_db("test_readers_no_block");
    let db = Arc::new(db);
    let readers = Arc::new(Mutex::new(Vec::new()));

    // Write initial data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"old").unwrap();
        txn.commit().unwrap();
    }

    // Spawn readers
    let mut handles = vec![];
    for i in 0..10 {
        let db = Arc::clone(&db);
        let readers = Arc::clone(&readers);
        let handle = thread::spawn(move || {
            let txn = db.begin_read().unwrap();
            readers.lock().unwrap().push(txn.snapshot_lsn());
            sleep(Duration::from_millis(50));  // Keep txn open
            let value = txn.get(b"key").unwrap();
            assert_eq!(value, b"old");  // Sees pre-writer snapshot
        });
        handles.push(handle);
    }

    sleep(Duration::from_millis(10));  // Let readers start

    // Writer should not block
    let mut txn = db.begin_write().unwrap();
    txn.put(b"key", b"new").unwrap();
    txn.commit().unwrap();

    for handle in handles {
        handle.join().unwrap();
    }
}
```

## Recovery Tests

### Test 13: Clean Shutdown Recovery

**Description**: Verify database opens without recovery after clean shutdown

**Steps**:
1. Open database
2. Write transactions, commit
3. Close database (clean shutdown)
4. Reopen database
5. Verify no recovery needed (WAL empty)
6. Verify all data present

**Assertions**:
- Reopen succeeds
- No recovery (WAL empty)
- All committed transactions present
- Database consistent

**Example**:
```rust
#[test]
fn test_clean_shutdown_recovery() {
    let file_path = "test_clean_recovery.db";

    // Write data and close
    {
        let db = Db::open(file_path).unwrap();
        for i in 0..100 {
            let mut txn = db.begin_write().unwrap();
            txn.put(format!("key{}", i).as_bytes(), format!("value{}", i).as_bytes()).unwrap();
            txn.commit().unwrap();
        }
        db.close().unwrap();
    }

    // Reopen and verify
    let db = Db::open(file_path).unwrap();
    let txn = db.begin_read().unwrap();
    for i in 0..100 {
        let key = format!("key{}", i);
        let value = txn.get(key.as_bytes()).unwrap();
        assert_eq!(value, format!("value{}", i).as_bytes());
    }

    db.close().unwrap();
    std::fs::remove_file(file_path).unwrap();
}
```

### Test 14: Dirty Shutdown Recovery

**Description**: Verify WAL replay restores committed transactions

**Steps**:
1. Open database
2. Write 100 transactions, commit
3. Kill process without closing (dirty shutdown)
4. Reopen database
5. Verify WAL replay restores all 100 transactions
6. Verify all data present

**Assertions**:
- Reopen triggers recovery (WAL non-empty)
- All 100 transactions replayed
- All data present
- WAL truncated after recovery
- Database consistent

**Example**:
```rust
#[test]
fn test_dirty_shutdown_recovery() {
    let file_path = "test_dirty_recovery.db";

    // Write data
    {
        let db = Db::open(file_path).unwrap();
        for i in 0..100 {
            let mut txn = db.begin_write().unwrap();
            txn.put(format!("key{}", i).as_bytes(), format!("value{}", i).as_bytes()).unwrap();
            txn.commit().unwrap();
        }
        // Simulate crash: drop without close
        drop(db);
    }

    // Reopen (triggers recovery)
    let db = Db::open(file_path).unwrap();

    // Verify all data recovered
    let txn = db.begin_read().unwrap();
    for i in 0..100 {
        let key = format!("key{}", i);
        let value = txn.get(key.as_bytes()).unwrap();
        assert_eq!(value, format!("value{}", i).as_bytes());
    }

    db.close().unwrap();
    std::fs::remove_file(file_path).unwrap();
}
```

### Test 15: Partial Transaction Recovery

**Description**: Verify uncommitted transaction not replayed

**Steps**:
1. Open database
2. Write transaction A (put key1=value1), commit
3. Write transaction B (put key2=value2), do NOT commit
4. Simulate crash (drop without close)
5. Reopen database
6. Verify transaction A present
7. Verify transaction B absent (key2 not found)

**Assertions**:
- Recovery replays only committed transactions
- Transaction A present (key1 found)
- Transaction B absent (key2 not found)
- No partial commits

**Example**:
```rust
#[test]
fn test_partial_transaction_recovery() {
    let file_path = "test_partial_recovery.db";

    // Write committed transaction
    {
        let db = Db::open(file_path).unwrap();
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key1", b"value1").unwrap();
        txn.commit().unwrap();

        // Start uncommitted transaction
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key2", b"value2").unwrap();
        // Don't commit, simulate crash
        drop(db);
    }

    // Reopen (triggers recovery)
    let db = Db::open(file_path).unwrap();
    let txn = db.begin_read().unwrap();

    // Committed transaction present
    assert_eq!(txn.get(b"key1").unwrap(), b"value1");

    // Uncommitted transaction absent
    assert!(txn.get(b"key2").is_err());

    db.close().unwrap();
    std::fs::remove_file(file_path).unwrap();
}
```

## Configuration Tests

### Test 16: Invalid Configuration Rejected

**Description**: Verify invalid configuration returns ConfigError

**Test Cases**:
- cache_size not power of 2
- page_size not power of 2
- page_size out of range
- wal_size_threshold < 1MB
- flush policy invalid parameters
- retention policy invalid parameters
- compression unavailable

**Assertions**:
- DbBuilder::build() returns Err(ConfigError)
- Error message explains what's wrong
- Database not created

**Example**:
```rust
#[test]
fn test_invalid_cache_size() {
    let result = Db::builder()
        .path("test.db")
        .cache_size(100)  // Not power of 2
        .build();

    assert!(result.is_err());
    match result.unwrap_err() {
        Error::ConfigError(ConfigError::InvalidCacheSize { .. }) => {},
        _ => panic!("Expected InvalidCacheSize error"),
    }
}
```

### Test 17: Configuration Presets Work

**Description**: Verify all configuration presets open successfully

**Presets**:
- Memory-constrained preset
- Default preset
- High-performance preset
- Maximum durability preset
- Analytics preset

**Assertions**:
- Each preset configuration is valid
- Each preset opens successfully
- Database operational with each preset

**Example**:
```rust
#[test]
fn test_default_preset() {
    let (file, db) = setup_test_db("test_default_preset");
    assert!(db.is_open());
}
```

## Error Handling Tests

### Test 18: Key Not Found Error

**Description**: Verify reading non-existent key returns NotFoundError

**Steps**:
1. Open new database (empty)
2. Begin read transaction
3. Get non-existent key
4. Verify NotFoundError returned

**Assertions**:
- get returns Err(Error::NotFoundError(NotFoundError::Key))
- Error is correct variant
- Application can handle error

**Example**:
```rust
#[test]
fn test_key_not_found_error() {
    let (file, db) = setup_test_db("test_not_found");

    let txn = db.begin_read().unwrap();
    let result = txn.get(b"nonexistent");

    assert!(result.is_err());
    match result.unwrap_err() {
        Error::NotFoundError(NotFoundError::Key) => {},
        _ => panic!("Expected NotFoundError::Key"),
    }
}
```

### Test 19: Database In Use Error

**Description**: Verify opening database twice returns DatabaseInUse

**Steps**:
1. Process 1: Open database
2. Process 2: Open same database file
3. Verify process 2 gets DatabaseInUse error

**Assertions**:
- First open succeeds
- Second open returns Err(Error::DatabaseInUse)
- Error message helpful

**Note**: Requires multi-process test (skip in single-process tests)

### Test 20: Database Closed Error

**Description**: Verify operations on closed database return DatabaseClosed

**Steps**:
1. Open database
2. Close database
3. Try to begin transaction
4. Verify DatabaseClosed error

**Assertions**:
- close() succeeds
- begin_read() returns Err(Error::DatabaseClosed)
- Error message helpful

**Example**:
```rust
#[test]
fn test_database_closed_error() {
    let (file, db) = setup_test_db("test_closed");
    db.close().unwrap();

    let result = db.begin_read();
    assert!(result.is_err());
    match result.unwrap_err() {
        Error::DatabaseClosed => {},
        _ => panic!("Expected DatabaseClosed error"),
    }
}
```

## Property Tests

### Test 21: Snapshot Isolation Property

**Description**: Property test: readers never see uncommitted data

**Property**: For any sequence of concurrent transactions, readers see only committed state

**Test Strategy**:
- Use proptest to generate random transaction sequences
- Verify snapshot isolation invariant holds
- Test with various concurrency patterns

**Example**:
```rust
#[test]
fn prop_snapshot_isolation() {
    // Property: Readers never see uncommitted writes
    use proptest::prelude::*;

    proptest!(|(txn_seq in prop::collection::vec(any::<WriteOp>(), 1..100))| {
        // Run transaction sequence
        // Verify all read transactions see only committed writes
        // Assert invariant holds
    });
}
```

### Test 22: Atomic Commit Property

**Description**: Property test: commit is all-or-nothing

**Property**: For any write transaction, either all mutations present or none

**Test Strategy**:
- Generate random mutations
- Commit transaction
- Verify all keys present or all absent (never partial)

**Example**:
```rust
#[test]
fn prop_atomic_commit() {
    // Property: All mutations or none
    use proptest::prelude::*;

    proptest!(|(mutations in prop::collection::vec(any::<Mutation>(), 1..100))| {
        // Commit transaction
        // Verify either all mutations present or none
    });
}
```

### Test 23: No Data Loss on Crash Property

**Description**: Property test: committed transactions survive crash

**Property**: For any committed transaction, data persists across crash and recovery

**Test Strategy**:
- Generate random transaction sequence
- Simulate crash after each commit
- Recover and verify all committed transactions present

**Example**:
```rust
#[test]
fn prop_no_data_loss_on_crash() {
    // Property: Committed transactions survive crash
    use proptest::prelude::*;

    proptest!(|(txns in prop::collection::vec(any::<WriteTxn>(), 1..50))| {
        // Execute transactions
        // Simulate crash
        // Recover
        // Verify all committed transactions present
    });
}
```

## Hardening Tests

### Test 24: Crash During Commit

**Description**: Simulate crash during two-phase commit

**Crash Points**:
- After WAL append but before B+Tree apply
- During B+Tree apply
- After B+Tree apply but before meta page flush
- During meta page flush

**Verification**:
- Recovery completes transaction or rolls back
- No partial commit
- Database consistent

**Example**:
```rust
#[test]
fn test_crash_during_commit() {
    // Test crash at each point in two-phase commit
    // Use fault injection to simulate crash
    // Verify recovery handles correctly
}
```

### Test 25: Disk Full During Write

**Description**: Simulate disk full during database operation

**Scenarios**:
- Disk full during WAL append
- Disk full during page allocation
- Disk full during checkpoint

**Verification**:
- IoError::DiskFull returned
- Database not corrupted
- Can close and reopen

**Example**:
```rust
#[test]
fn test_disk_full_during_write() {
    // Use file size limit to simulate disk full
    // Verify error returned
    // Verify database consistent
}
```

### Test 26: Corrupted Page Detection

**Description**: Verify corrupted page checksum detected

**Steps**:
1. Write data
2. Corrupt page on disk (flip bits)
3. Reopen database
4. Verify CorruptedData::ChecksumMismatch error

**Assertions**:
- Error detected during read
- Corrupted page not used
- Error message includes page ID

**Example**:
```rust
#[test]
fn test_corrupted_page_detection() {
    // Write data
    // Manually corrupt page on disk
    // Reopen, expect ChecksumMismatch error
}
```

## Performance Benchmarks

### Benchmark 1: Read Throughput

**Description**: Measure sequential read throughput

**Workload**:
- Insert 1M keys
- Measure time to read all 1M keys
- Report reads/second

**Expected**: >100K reads/sec

**Example**:
```rust
#[bench]
fn bench_read_throughput(b: &mut Bencher) {
    let (file, db) = setup_test_db("bench_read_throughput");

    // Insert 1M keys
    // ...

    b.iter(|| {
        let txn = db.begin_read().unwrap();
        // Read all keys
    });
}
```

### Benchmark 2: Write Throughput

**Description**: Measure sequential write throughput

**Workload**:
- Measure time to commit 1K single-key transactions
- Report writes/second

**Expected**: >10K writes/sec (depends on flush policy)

**Example**:
```rust
#[bench]
fn bench_write_throughput(b: &mut Bencher) {
    let (file, db) = setup_test_db("bench_write_throughput");

    b.iter(|| {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.commit().unwrap();
    });
}
```

### Benchmark 3: Concurrent Reader Scalability

**Description**: Measure read throughput with concurrent readers

**Workload**:
- Insert 100K keys
- Spawn N concurrent readers (1, 2, 4, 8, 16)
- Each reader performs 10K reads
- Measure total throughput

**Expected**: Linear scaling up to CPU core count

**Example**:
```rust
#[bench]
fn bench_concurrent_readers(b: &mut Bencher) {
    // Test with 1, 2, 4, 8, 16 concurrent readers
    // Measure throughput scaling
}
```

## Test Execution

### Running Tests

**Unit Tests**:
```bash
cargo test
```

**Integration Tests**:
```bash
cargo test --test integration
```

**Property Tests**:
```bash
cargo test --test property
```

**Hardening Tests**:
```bash
cargo test --test hardening
```

**Benchmarks**:
```bash
cargo bench
```

### CI Requirements

**Required Tests for PR**:
- All unit tests pass
- All integration tests pass
- Property tests run for 10K iterations
- Hardening tests pass

**Performance Regression Checks**:
- Benchmarks run on every PR
- Compare against baseline
- Fail if >10% performance regression

**Coverage**:
- Aim for >80% code coverage
- Check with tarpaulin or similar tool

## Conclusion

This test suite comprehensively validates:
- Database lifecycle and persistence
- Transaction correctness and isolation
- Concurrency and thread safety
- Crash recovery and durability
- Error handling and edge cases
- Performance characteristics

Tests should be run continuously in CI and before every release.
