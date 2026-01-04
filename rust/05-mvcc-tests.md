# MVCC Tests

## Purpose

The MVCC tests specification defines comprehensive testing requirements for validating Multi-Version Concurrency Control functionality in NorthstarDB. Tests ensure snapshot correctness, isolation guarantees, reader lifecycle management, serialization/deserialization, and crash recovery. The test specification covers unit tests for individual snapshot operations, integration tests for MVCC workflows, property-based tests for invariant validation, hardening tests for crash resilience, and performance benchmarks for concurrency targets.

## Overview

### Testing Philosophy

**Tests Are Source of Truth**: MVCC behavior must be validated through comprehensive testing
- All isolation guarantees proven with reproducible tests
- No MVCC implementation changes unless tests pass
- Hardening tests must pass nightly
- CI gates on regression: -5% throughput, +10% p99 latency

**Test-Driven Development**: Red-Green-Refactor cycle
- Write failing test first
- Implement minimum to pass test
- Refactor for clarity
- Lock in with regression baselines

**Comprehensive Coverage**: Test all MVCC behaviors
- Happy path: Normal snapshot operations succeed
- Error paths: Errors handled correctly
- Edge cases: Boundary conditions validated
- Concurrency: Multiple readers interact correctly
- Isolation: Guarantees maintained under concurrent operations

### Test Categories

**Unit Tests**: Test individual snapshot operations
- Snapshot registry operations (init, register, lookup, cleanup)
- Visibility calculation logic
- Reader lifecycle (begin, operations, close/drop)
- Reference counting
- Serialization and deserialization
- Error handling

**Integration Tests**: Test MVCC workflows and scenarios
- Complete snapshot workflows (create → use → cleanup)
- Concurrent reader interactions
- Reader-writer coordination
- Crash recovery workflows
- Time-travel query scenarios
- WAL integration for persistence

**Property Tests**: Test invariants hold for all inputs
- Monotonicity: Transaction IDs never decrease
- Uniqueness: No duplicate transaction IDs
- Isolation: Readers see consistent snapshots
- Idempotency: Operations repeat safely
- Determinism: Same input produces same output

**Hardening Tests**: Test system resilience under adverse conditions
- Crash simulation during snapshot operations
- Corruption detection and handling
- Fuzzing with random inputs
- Stress testing with high concurrency
- Resource exhaustion scenarios

**Performance Tests**: Test throughput and latency targets
- Snapshot creation throughput (snapshots per second)
- Read throughput (queries per second)
- Concurrent reader scalability (10,000+ readers)
- Snapshot cleanup performance
- Serialization/deserialization performance

## Unit Tests

### Snapshot Registry Tests

**Test: Initialize Registry with Genesis**
```
fn test_init_registry_genesis() {
    let registry = SnapshotRegistry::init(allocator, 0, 1);

    assert_eq!(registry.current_txn_id(), 0);
    assert_eq!(registry.current_root_page_id(), 1);
    assert_eq!(registry.total_snapshots(), 1);
    assert!(registry.has_snapshot(0));
    assert_eq!(registry.get_snapshot_root(0), Some(1));
}
```
Validates: Registry initializes with genesis snapshot

**Test: Initialize Registry with Non-Zero Transaction**
```
fn test_init_registry_nonzero_txn() {
    let registry = SnapshotRegistry::init(allocator, 100, 42);

    assert_eq!(registry.current_txn_id(), 100);
    assert_eq!(registry.current_root_page_id(), 42);
    assert!(registry.has_snapshot(100));
}
```
Validates: Registry initializes at arbitrary transaction ID

**Test: Register New Snapshot**
```
fn test_register_snapshot() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);

    registry.register_snapshot(1, 5).unwrap();

    assert_eq!(registry.current_txn_id(), 1);
    assert_eq!(registry.current_root_page_id(), 5);
    assert!(registry.has_snapshot(1));
    assert_eq!(registry.get_snapshot_root(1), Some(5));
}
```
Validates: Snapshot registration updates registry state

**Test: Register Snapshot with Monotonic TXN ID**
```
fn test_register_snapshot_monotonic() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);

    registry.register_snapshot(10, 5).unwrap();
    registry.register_snapshot(20, 10).unwrap();

    assert_eq!(registry.current_txn_id(), 20);
    assert_eq!(registry.total_snapshots(), 3); // genesis + 2
}
```
Validates: Transaction IDs are monotonic

**Test: Register Snapshot with Stale TXN ID is No-Op**
```
fn test_register_snapshot_stale() {
    let mut registry = SnapshotRegistry::init(allocator, 100, 42);

    let current_txn = registry.current_txn_id();
    registry.register_snapshot(50, 99).unwrap(); // Stale

    // No change
    assert_eq!(registry.current_txn_id(), current_txn);
    assert_eq!(registry.current_root_page_id(), 42);
}
```
Validates: Stale transaction IDs are ignored

**Test: Get Snapshot Root for Existing Transaction**
```
fn test_get_snapshot_root_exists() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(10, 5).unwrap();

    assert_eq!(registry.get_snapshot_root(10), Some(5));
}
```
Validates: Lookup returns correct root page ID

**Test: Get Snapshot Root for Missing Transaction**
```
fn test_get_snapshot_root_missing() {
    let registry = SnapshotRegistry::init(allocator, 0, 1);

    assert_eq!(registry.get_snapshot_root(999), None);
}
```
Validates: Missing transactions return None

**Test: Get Snapshot Root for Future Transaction Returns Current**
```
fn test_get_snapshot_root_future() {
    let registry = SnapshotRegistry::init(allocator, 100, 42);

    // Future transaction ID returns current snapshot
    assert_eq!(registry.get_snapshot_root(999), Some(42));
}
```
Validates: Future transaction IDs return latest snapshot

**Test: Get Latest Snapshot**
```
fn test_get_latest_snapshot() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(10, 5).unwrap();

    assert_eq!(registry.get_latest_snapshot(), 5);
}
```
Validates: Latest snapshot retrieval works

**Test: Has Snapshot for Existing Transaction**
```
fn test_has_snapshot_exists() {
    let registry = SnapshotRegistry::init(allocator, 100, 42);

    assert!(registry.has_snapshot(100));
}
```
Validates: has_snapshot returns true for existing

**Test: Has Snapshot for Missing Transaction**
```
fn test_has_snapshot_missing() {
    let registry = SnapshotRegistry::init(allocator, 100, 42);

    assert!(!registry.has_snapshot(99));
    assert!(!registry.has_snapshot(101)); // Future
}
```
Validates: has_snapshot returns false for missing

**Test: Cleanup Old Snapshots by Age**
```
fn test_cleanup_old_snapshots_age() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(100, 5).unwrap();
    registry.register_snapshot(200, 10).unwrap();
    registry.register_snapshot(300, 15).unwrap();

    // Keep last 100 transactions
    let removed = registry.cleanup_old_snapshots(100, 0).unwrap();

    assert_eq!(removed, 1); // txn 100 removed
    assert!(!registry.has_snapshot(100));
    assert!(registry.has_snapshot(200));
    assert!(registry.has_snapshot(300));
}
```
Validates: Age-based cleanup removes old snapshots

**Test: Cleanup Old Snapshots by Count**
```
fn test_cleanup_old_snapshots_count() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);
    for i in 1..=10 {
        registry.register_snapshot(i * 10, i + 1).unwrap();
    }

    // Keep last 3 snapshots
    let removed = registry.cleanup_old_snapshots(0, 3).unwrap();

    assert_eq!(removed, 7); // Removed 7 of 10 non-genesis snapshots
    assert!(registry.has_snapshot(0)); // Genesis preserved
}
```
Validates: Count-based cleanup preserves recent snapshots

**Test: Cleanup Preserves Genesis**
```
fn test_cleanup_preserves_genesis() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(10, 5).unwrap();

    // Aggressive cleanup
    let removed = registry.cleanup_old_snapshots(0, 0).unwrap();

    assert!(registry.has_snapshot(0)); // Genesis always preserved
}
```
Validates: Genesis snapshot (txn_id 0) never removed

**Test: Get Registry Statistics**
```
fn test_get_stats() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(100, 5).unwrap();
    registry.register_snapshot(200, 10).unwrap();

    let stats = registry.get_stats();

    assert_eq!(stats.total_snapshots, 3);
    assert_eq!(stats.current_txn_id, 200);
    assert_eq!(stats.oldest_txn_id, 0);
    assert_eq!(stats.newest_txn_id, 200);
}
```
Validates: Statistics accurately reflect registry state

### Visibility Calculation Tests

**Test: Visible Transaction at Snapshot Time**
```
fn test_visible_at_snapshot() {
    let snapshot_txn_id = 100;
    let data_txn_id = 50;

    assert!(is_visible(data_txn_id, snapshot_txn_id));
}
```
Validates: Older transactions visible to snapshot

**Test: Invisible Transaction After Snapshot**
```
fn test_invisible_after_snapshot() {
    let snapshot_txn_id = 100;
    let data_txn_id = 150;

    assert!(!is_visible(data_txn_id, snapshot_txn_id));
}
```
Validates: Newer transactions invisible to snapshot

**Test: Transaction at Exact Snapshot Time Visible**
```
fn test_visible_exact_snapshot() {
    let snapshot_txn_id = 100;
    let data_txn_id = 100;

    assert!(is_visible(data_txn_id, snapshot_txn_id));
}
```
Validates: Same transaction ID visible

**Test: Invalid Transaction Never Visible**
```
fn test_invalid_txn_never_visible() {
    let snapshot_txn_id = 100;
    let invalid_txn_id = 0;

    assert!(!is_visible(invalid_txn_id, snapshot_txn_id));
}
```
Validates: Transaction ID 0 never visible

### Reader Lifecycle Tests

**Test: Begin Read Creates Snapshot**
```
fn test_begin_read_creates_snapshot() {
    let db = Db::open_in_memory();

    let reader = db.begin_read().unwrap();

    assert!(reader.is_active());
    assert_eq!(reader.txn_id(), TransactionId::new(1));
}
```
Validates: Read transaction initializes with snapshot

**Test: Begin Read At Specific Transaction**
```
fn test_begin_read_at() {
    let db = Db::open_in_memory();

    // Create snapshot at txn 100
    let mut writer = db.begin_write().unwrap();
    for i in 0..10 {
        writer.put(&[i as u8], b"data").unwrap();
    }
    writer.commit().unwrap();

    let reader = db.begin_read_at(TransactionId::new(11)).unwrap();

    assert_eq!(reader.txn_id(), TransactionId::new(11));
}
```
Validates: Can begin read at historical transaction

**Test: Begin Read At Invalid Transaction Returns Error**
```
fn test_begin_read_at_invalid() {
    let db = Db::open_in_memory();

    let result = db.begin_read_at(TransactionId::new(999));

    assert_eq!(result, Err(Error::TransactionNotFound { txn_id: 999 }));
}
```
Validates: Invalid transaction ID returns error

**Test: Get Operation Returns Correct Value**
```
fn test_get_returns_value() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value").unwrap();
        writer.commit().unwrap();
    }

    let reader = db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), Some(b"value".to_vec()));
}
```
Validates: Get returns committed data

**Test: Get Returns None for Missing Key**
```
fn test_get_missing_key() {
    let db = Db::open_in_memory();
    let reader = db.begin_read().unwrap();

    assert_eq!(reader.get(b"nonexistent"), None);
}
```
Validates: Missing keys return None

**Test: Scan Returns Keys in Range**
```
fn test_scan_range() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"a", b"1").unwrap();
        writer.put(b"b", b"2").unwrap();
        writer.put(b"c", b"3").unwrap();
        writer.commit().unwrap();
    }

    let reader = db.begin_read().unwrap();
    let results: Vec<_> = reader.scan(b"a"..=b"c").collect();

    assert_eq!(results.len(), 3);
}
```
Validates: Scan returns all keys in range

**Test: Scan Returns Keys in Sorted Order**
```
fn test_scan_sorted() {
    let db = Db::open_in_memory();

    // Seed data out of order
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"c", b"3").unwrap();
        writer.put(b"a", b"1").unwrap();
        writer.put(b"b", b"2").unwrap();
        writer.commit().unwrap();
    }

    let reader = db.begin_read().unwrap();
    let keys: Vec<_> = reader.scan(b""..b"~")
        .map(|(k, _)| k)
        .collect();

    assert_eq!(keys, vec![b"a".to_vec(), b"b".to_vec(), b"c".to_vec()]);
}
```
Validates: Scan returns sorted results

**Test: Close Reader Prevents Operations**
```
fn test_close_prevents_operations() {
    let db = Db::open_in_memory();
    let mut reader = db.begin_read().unwrap();

    reader.close().unwrap();

    assert_eq!(reader.get(b"key"), Err(Error::TransactionClosed));
}
```
Validates: Closed transaction rejects operations

**Test: Drop Decrements Reference Count**
```
fn test_drop_decrements_ref_count() {
    let db = Db::open_in_memory();

    {
        let reader = db.begin_read().unwrap();
        // Ref count incremented
    }
    // Ref count decremented on drop

    // Verify cleanup eligible
    let registry = db.snapshot_registry();
    let entry = registry.get_entry(1);
    assert_eq!(entry.ref_count(), 0);
}
```
Validates: Drop trait decrements reference count

**Test: Clone Increments Reference Count**
```
fn test_clone_increments_ref_count() {
    let db = Db::open_in_memory();
    let reader1 = db.begin_read().unwrap();

    let ref_count_before = db.snapshot_registry().get_entry(1).ref_count();
    let reader2 = reader1.clone();
    let ref_count_after = db.snapshot_registry().get_entry(1).ref_count();

    assert_eq!(ref_count_after, ref_count_before + 1);
}
```
Validates: Clone increments reference count

### Reference Counting Tests

**Test: Reference Count Increment**
```
fn test_ref_count_increment() {
    let registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(10, 5).unwrap();

    let entry = registry.get_entry(10);
    let before = entry.ref_count();

    entry.increment_ref();

    assert_eq!(entry.ref_count(), before + 1);
}
```
Validates: Increment increases reference count

**Test: Reference Count Decrement**
```
fn test_ref_count_decrement() {
    let registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(10, 5).unwrap();

    let entry = registry.get_entry(10);
    entry.increment_ref();
    let before = entry.ref_count();

    let is_last = entry.decrement_ref();

    assert_eq!(entry.ref_count(), before - 1);
    assert!(!is_last); // Still has refs
}
```
Validates: Decrement decreases reference count

**Test: Last Decrement Returns True**
```
fn test_last_decrement_returns_true() {
    let registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(10, 5).unwrap();

    let entry = registry.get_entry(10);
    entry.increment_ref();

    let is_last = entry.decrement_ref();

    assert!(is_last);
}
```
Validates: Final decrement returns true

### Serialization Tests

**Test: Serialize Snapshot Registry**
```
fn test_serialize_registry() {
    let registry = SnapshotRegistry::init(allocator, 0, 1);
    registry.register_snapshot(100, 5).unwrap();
    registry.register_snapshot(200, 10).unwrap();

    let bytes = serialize(&registry).unwrap();

    assert!(bytes.len() >= 72); // At least header size
}
```
Validates: Registry serializes to bytes

**Test: Deserialize Snapshot Registry**
```
fn test_deserialize_registry() {
    let original = SnapshotRegistry::init(allocator, 100, 42);
    let bytes = serialize(&original).unwrap();

    let restored = deserialize(&bytes).unwrap();

    assert_eq!(restored.current_txn_id(), 100);
    assert_eq!(restored.current_root_page_id(), 42);
}
```
Validates: Bytes deserialize back to registry

**Test: Round-Trip Serialization**
```
fn test_roundtrip_serialization() {
    let original = SnapshotRegistry::init(allocator, 0, 1);
    original.register_snapshot(100, 5).unwrap();
    original.register_snapshot(200, 10).unwrap();

    let bytes = serialize(&original).unwrap();
    let restored = deserialize(&bytes).unwrap();

    assert_eq!(restored.current_txn_id(), original.current_txn_id());
    assert_eq!(restored.total_snapshots(), original.total_snapshots());
}
```
Validates: Serialization preserves all data

**Test: Invalid Magic Number Detected**
```
fn test_invalid_magic_detected() {
    let mut bytes = vec![0u8; 100];

    let result = deserialize(&bytes);

    assert_eq!(result, Err(Error::InvalidMagic { found: 0, expected: 0x4E53544D54535054 }));
}
```
Validates: Magic number validation works

**Test: Invalid Checksum Detected**
```
fn test_invalid_checksum_detected() {
    let mut bytes = create_valid_serialization();
    // Corrupt checksum
    bytes[12] ^= 0xFF;

    let result = deserialize(&bytes);

    assert_eq!(result, Err(Error::ChecksumMismatch { .. }));
}
```
Validates: Checksum validation detects corruption

**Test: Truncated Data Detected**
```
fn test_truncated_data_detected() {
    let bytes = vec![0u8; 50]; // Too small

    let result = deserialize(&bytes);

    assert_eq!(result, Err(Error::TruncatedData { .. }));
}
```
Validates: Size validation detects truncation

## Integration Tests

### Complete Snapshot Workflows

**Test: Begin-Read-Commit Workflow**
```
fn test_workflow_begin_read_commit() {
    let db = Db::open_in_memory();

    // Begin read
    let reader = db.begin_read().unwrap();

    // Perform reads
    assert_eq!(reader.get(b"key"), None);

    // End read
    reader.close().unwrap();

    // Verify cleanup
    assert!(reader.is_closed());
}
```
Validates: Complete read workflow

**Test: Time-Travel Query Workflow**
```
fn test_workflow_time_travel() {
    let db = Db::open_in_memory();

    // Create multiple snapshots
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value1").unwrap();
        writer.commit().unwrap(); // txn 1
    }

    let txn_id_1 = db.current_txn_id();

    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value2").unwrap();
        writer.commit().unwrap(); // txn 2
    }

    // Query historical state
    let reader = db.begin_read_at(txn_id_1).unwrap();
    assert_eq!(reader.get(b"key"), Some(b"value1".to_vec()));

    // Query current state
    let reader2 = db.begin_read().unwrap();
    assert_eq!(reader2.get(b"key"), Some(b"value2".to_vec()));
}
```
Validates: Time-travel queries work

**Test: Snapshot Cleanup Workflow**
```
fn test_workflow_snapshot_cleanup() {
    let db = Db::open_in_memory();

    // Create many snapshots
    for i in 0..100 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&[i as u8], b"data").unwrap();
        writer.commit().unwrap();
    }

    // Trigger cleanup
    db.cleanup_snapshots(10, 5).unwrap();

    // Verify cleanup occurred
    let stats = db.snapshot_stats();
    assert!(stats.total_snapshots <= 6); // Genesis + 5 recent
}
```
Validates: Snapshot cleanup workflow

### Concurrent Reader Tests

**Test: Multiple Concurrent Readers**
```
fn test_concurrent_readers() {
    let db = Arc::new(Db::open_in_memory());

    // Seed data
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value").unwrap();
        writer.commit().unwrap();
    }

    // Spawn many readers
    let handles: Vec<_> = (0..100)
        .map(|_| {
            let db = db.clone();
            thread::spawn(move || {
                let reader = db.begin_read().unwrap();
                reader.get(b"key")
            })
        })
        .collect();

    // All readers succeed
    for handle in handles {
        let result = handle.join().unwrap();
        assert_eq!(result, Some(b"value".to_vec()));
    }
}
```
Validates: Multiple readers operate concurrently

**Test: Readers During Writer**
```
fn test_readers_during_writer() {
    let db = Arc::new(Db::open_in_memory());

    // Seed initial data
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value1").unwrap();
        writer.commit().unwrap();
    }

    // Begin writer
    let mut writer = db.begin_write().unwrap();
    writer.put(b"key", b"value2").unwrap(); // Uncommitted

    // Spawn readers during active writer
    let db_clone = db.clone();
    let handle = thread::spawn(move || {
        let reader = db_clone.begin_read().unwrap();
        reader.get(b"key")
    });

    // Reader sees old value
    let result = handle.join().unwrap();
    assert_eq!(result, Some(b"value1".to_vec()));

    writer.commit().unwrap();
}
```
Validates: Readers not blocked by writer

**Test: Reader Scalability**
```
fn test_reader_scalability() {
    let db = Arc::new(Db::open_in_memory());

    // Spawn 10,000 readers
    let handles: Vec<_> = (0..10_000)
        .map(|_| {
            let db = db.clone();
            thread::spawn(move || {
                let reader = db.begin_read().unwrap();
                // Perform some reads
                reader.get(b"key")
            })
        })
        .collect();

    // All readers complete without deadlock
    for handle in handles {
        handle.join().unwrap();
    }
}
```
Validates: System supports 10,000+ concurrent readers

### Reader-Writer Coordination Tests

**Test: Writer Excludes Second Writer**
```
fn test_writer_exclusion() {
    let db = Db::open_in_memory();

    let writer1 = db.begin_write().unwrap();

    // Second writer fails
    let result = db.begin_write();
    assert_eq!(result, Err(Error::WriteBusy));

    drop(writer1);

    // Second writer now succeeds
    let writer2 = db.begin_write().unwrap();
    assert!(writer2.is_active());
}
```
Validates: Single-writer enforcement

**Test: Readers See Consistent Snapshot**
```
fn test_readers_consistent_snapshot() {
    let db = Arc::new(Db::open_in_memory());

    // Seed data
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key1", b"value1").unwrap();
        writer.commit().unwrap();
    }

    // Begin reader
    let db_clone = db.clone();
    let reader_handle = thread::spawn(move || {
        let reader = db_clone.begin_read().unwrap();
        (reader, db_clone)
    });

    // Modify data
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key2", b"value2").unwrap();
        writer.commit().unwrap();
    }

    // Reader still sees old snapshot
    let (reader, _) = reader_handle.join().unwrap();
    assert_eq!(reader.get(b"key1"), Some(b"value1".to_vec()));
    assert_eq!(reader.get(b"key2"), None); // Doesn't see new key
}
```
Validates: Snapshot isolation for readers

### Crash Recovery Tests

**Test: Recover Snapshot Registry**
```
fn test_recover_snapshot_registry() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Create snapshots
    for i in 0..10 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&[i as u8], b"data").unwrap();
        writer.commit().unwrap();
    }

    drop(db);

    // Recover
    let recovered_db = Db::open(&db_path).unwrap();

    // Verify registry restored
    assert_eq!(recovered_db.current_txn_id(), TransactionId::new(10));
    assert!(recovered_db.has_snapshot(TransactionId::new(5)));
}
```
Validates: Snapshot registry persists across restart

**Test: Rebuild Registry from WAL if Snapshot Corrupt**
```
fn test_rebuild_from_wal() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Create transactions
    for i in 0..10 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&[i as u8], b"data").unwrap();
        writer.commit().unwrap();
    }

    drop(db);

    // Corrupt snapshot data
    corrupt_snapshot_file(&db_path);

    // Recovery should rebuild from WAL
    let recovered_db = Db::open(&db_path).unwrap();

    assert_eq!(recovered_db.current_txn_id(), TransactionId::new(10));
}
```
Validates: WAL rebuilds registry if snapshot corrupt

**Test: Snapshot Data Persists After Crash**
```
fn test_snapshot_persists_after_crash() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Create snapshot
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value").unwrap();
        writer.commit().unwrap();
    }

    let snapshot_txn_id = db.current_txn_id();
    drop(db);

    // Simulate crash and recover
    let recovered_db = Db::open(&db_path).unwrap();

    // Can query historical snapshot
    let reader = recovered_db.begin_read_at(snapshot_txn_id).unwrap();
    assert_eq!(reader.get(b"key"), Some(b"value".to_vec()));
}
```
Validates: Historical snapshots recoverable

### WAL Integration Tests

**Test: Commit Registers Snapshot in WAL**
```
fn test_commit_registers_snapshot_wal() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value").unwrap();
        writer.commit().unwrap();
    }

    // Verify snapshot in WAL
    let wal = db.wal();
    let records = wal.read_all().unwrap();

    assert!(!records.is_empty());
    assert_eq!(records[0].txn_id, TransactionId::new(1));
}
```
Validates: Commits recorded in WAL

**Test: WAL Replay Reconstructs Snapshots**
```
fn test_wal_replay_snapshots() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Create transactions
    for i in 0..10 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&[i as u8], b"data").unwrap();
        writer.commit().unwrap();
    }

    // Delete snapshot file (force WAL replay)
    std::fs::remove_file(db_path.join("snapshots.dat"));

    // Recovery replays WAL
    let recovered_db = Db::open(&db_path).unwrap();

    assert_eq!(recovered_db.current_txn_id(), TransactionId::new(10));
}
```
Validates: WAL replay reconstructs snapshot registry

## Property Tests

### Monotonicity Properties

**Property: Transaction IDs Never Decrease**
```
#[quickcheck]
fn prop_txn_id_monotonic(ops: Vec<TestOp>) -> bool {
    let db = Db::open_in_memory();
    let mut last_txn_id = 0;

    for op in ops {
        match op {
            TestOp::Commit => {
                let mut writer = db.begin_write().unwrap();
                writer.put(b"key", b"value").unwrap();
                writer.commit().unwrap();

                let current_txn_id = db.current_txn_id().as_u64();
                if current_txn_id < last_txn_id {
                    return false;
                }
                last_txn_id = current_txn_id;
            }
            _ => {}
        }
    }

    true
}
```
Validates: Transaction IDs monotonically increase

**Property: Root Page IDs Change Only on Commit**
```
fn prop_root_page_stable_between_commits() -> bool {
    let db = Db::open_in_memory();

    let root1 = db.current_root_page_id();

    // Begin transaction but don't commit
    let _writer = db.begin_write().unwrap();
    let root2 = db.current_root_page_id();

    drop(writer);

    let root3 = db.current_root_page_id();

    root1 == root2 && root2 == root3
}
```
Validates: Root page ID stable between commits

### Isolation Properties

**Property: Repeatable Read**
```
fn prop_repeatable_read(operations: Vec<WriteOp>) -> bool {
    let db = Arc::new(Db::open_in_memory());

    // Seed initial data
    {
        let mut writer = db.begin_write().unwrap();
        for (i, op) in operations.iter().enumerate() {
            writer.put(&[i as u8], &op.value).unwrap();
        }
        writer.commit().unwrap();
    }

    let reader = db.begin_read().unwrap();

    // Spawn concurrent writer
    let db_clone = db.clone();
    let handle = thread::spawn(move || {
        let mut writer = db_clone.begin_write().unwrap();
        writer.put(b"new_key", b"new_value").unwrap();
        writer.commit().unwrap();
    });

    handle.join().unwrap();

    // Reader still sees same data
    for (i, _) in operations.iter().enumerate() {
        let key = [i as u8];
        let first_read = reader.get(&key);
        let second_read = reader.get(&key);

        if first_read != second_read {
            return false;
        }
    }

    true
}
```
Validates: Same query returns same results throughout transaction

**Property: No Dirty Reads**
```
fn prop_no_dirty_reads() -> bool {
    let db = Arc::new(Db::open_in_memory());

    // Seed data
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"old_value").unwrap();
        writer.commit().unwrap();
    }

    // Begin writer but don't commit
    let mut writer = db.begin_write().unwrap();
    writer.put(b"key", b"new_value").unwrap();

    // Reader shouldn't see uncommitted change
    let reader = db.begin_read().unwrap();
    let result = reader.get(b"key");

    result == Some(b"old_value".to_vec())
}
```
Validates: Uncommitted data never visible

### Reference Counting Properties

**Property: Ref Count Equals Active Readers**
```
fn prop_ref_count_equals_readers() -> bool {
    let db = Arc::new(Db::open_in_memory());

    let mut readers = Vec::new();

    for _ in 0..10 {
        let reader = db.begin_read().unwrap();
        readers.push(reader);
    }

    let registry = db.snapshot_registry();
    let entry = registry.get_entry(db.current_txn_id());

    entry.ref_count() == readers.len()
}
```
Validates: Reference count matches active reader count

**Property: Ref Count Decrements on Drop**
```
fn prop_ref_count_decrements_on_drop() -> bool {
    let db = Db::open_in_memory();

    let reader1 = db.begin_read().unwrap();
    let reader2 = reader1.clone();

    let registry = db.snapshot_registry();
    let entry = registry.get_entry(db.current_txn_id());

    let before = entry.ref_count();

    drop(reader1);

    let after = entry.ref_count();

    after == before - 1
}
```
Validates: Drop correctly decrements reference count

### Cleanup Properties

**Property: Cleanup Never Removes Genesis**
```
#[quickcheck]
fn prop_cleanup_preserves_genesis(snapshots: Vec<u64>) -> bool {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);

    for &txn_id in &snapshots {
        registry.register_snapshot(txn_id, txn_id + 1).unwrap();
    }

    // Aggressive cleanup
    let _ = registry.cleanup_old_snapshots(0, 0);

    // Genesis always preserved
    registry.has_snapshot(0)
}
```
Validates: Genesis snapshot never removed by cleanup

**Property: Cleanup Respects Minimum Count**
```
fn prop_cleanup_respects_min_count(snapshots: usize) -> bool {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);

    for i in 1..=snapshots {
        registry.register_snapshot(i as u64 * 10, i as u64 + 1).unwrap();
    }

    let keep_count = 5;
    registry.cleanup_old_snapshots(0, keep_count).unwrap();

    // At least keep_count snapshots remain (including genesis)
    registry.total_snapshots() >= keep_count + 1
}
```
Validates: Cleanup preserves minimum number of snapshots

## Hardening Tests

### Crash Simulation Tests

**Test: Crash During Snapshot Write**
```
fn test_crash_during_snapshot_write() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Create snapshot
    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value").unwrap();
        writer.commit().unwrap();
    }

    // Simulate crash during snapshot write
    inject_failure_during_snapshot_write();
    drop(db);

    // Recovery should detect incomplete write
    let result = Db::open(&db_path);

    // Either succeeds (write completed) or recovers from WAL
    assert!(result.is_ok());
}
```
Validates: Incomplete snapshot writes handled

**Test: Crash During Cleanup**
```
fn test_crash_during_cleanup() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Create many snapshots
    for i in 0..100 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&[i as u8], b"data").unwrap();
        writer.commit().unwrap();
    }

    // Inject crash during cleanup
    inject_failure_during_cleanup();
    drop(db);

    // Recovery should succeed
    let recovered_db = Db::open(&db_path).unwrap();

    // Registry should be consistent
    let stats = recovered_db.snapshot_stats();
    assert!(stats.total_snapshots >= 1); // At least genesis
}
```
Validates: Crash during cleanup doesn't corrupt registry

**Test: Crash with Active Readers**
```
fn test_crash_with_active_readers() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Create reader
    let reader = db.begin_read().unwrap();

    // Crash (simulated by drop)
    drop(db);
    drop(reader);

    // Recovery should succeed
    let recovered_db = Db::open(&db_path).unwrap();

    // Old readers gone, new readers can start
    let new_reader = recovered_db.begin_read().unwrap();
    assert!(new_reader.is_active());
}
```
Validates: Active readers don't prevent recovery

### Corruption Detection Tests

**Test: Detect Corrupt Snapshot Magic**
```
fn test_detect_corrupt_snapshot_magic() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value").unwrap();
        writer.commit().unwrap();
    }

    drop(db);

    // Corrupt snapshot magic
    corrupt_snapshot_magic(&db_path);

    // Recovery should detect corruption and rebuild from WAL
    let recovered_db = Db::open(&db_path).unwrap();

    assert!(recovered_db.current_txn_id().as_u64() >= 1);
}
```
Validates: Magic number validation detects corruption

**Test: Detect Corrupt Snapshot Checksum**
```
fn test_detect_corrupt_snapshot_checksum() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    {
        let mut writer = db.begin_write().unwrap();
        writer.put(b"key", b"value").unwrap();
        writer.commit().unwrap();
    }

    drop(db);

    // Corrupt checksum
    corrupt_snapshot_checksum(&db_path);

    // Recovery should detect and handle
    let result = Db::open(&db_path);

    // Should rebuild from WAL
    assert!(result.is_ok());
}
```
Validates: Checksum validation detects corruption

**Test: Detect Truncated Snapshot File**
```
fn test_detect_truncated_snapshot() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    for i in 0..10 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&[i as u8], b"data").unwrap();
        writer.commit().unwrap();
    }

    drop(db);

    // Truncate snapshot file
    truncate_snapshot_file(&db_path, 50);

    // Recovery should detect truncation
    let result = Db::open(&db_path);

    assert!(result.is_ok());
}
```
Validates: Truncation detected and handled

### Fuzzing Tests

**Test: Fuzz Snapshot Registry Operations**
```
fn test_fuzz_registry_operations() {
    let mut rng = StdRng::from_entropy();
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);

    for _ in 0..1000 {
        match rng.gen_range(0..4) {
            0 => {
                // Register random snapshot
                let txn_id = rng.gen_range(1..10000);
                let root_id = rng.gen_range(1..10000);
                let _ = registry.register_snapshot(txn_id, root_id);
            }
            1 => {
                // Get random snapshot
                let txn_id = rng.gen_range(0..10000);
                let _ = registry.get_snapshot_root(txn_id);
            }
            2 => {
                // Cleanup with random parameters
                let keep_txns = rng.gen_range(0..1000);
                let keep_count = rng.gen_range(0..100);
                let _ = registry.cleanup_old_snapshots(keep_txns, keep_count);
            }
            3 => {
                // Check has snapshot
                let txn_id = rng.gen_range(0..10000);
                let _ = registry.has_snapshot(txn_id);
            }
            _ => unreachable!(),
        }
    }

    // Registry should still be valid
    let stats = registry.get_stats();
    assert!(stats.total_snapshots >= 1);
}
```
Validates: Random operations don't corrupt state

**Test: Fuzz Serialization Input**
```
fn test_fuzz_serialization_input() {
    let mut rng = StdRng::from_entropy();

    for _ in 0..1000 {
        // Generate random bytes
        let size = rng.gen_range(0..10000);
        let bytes: Vec<u8> = (0..size).map(|_| rng.gen()).collect();

        // Attempt deserialization
        let result = deserialize(&bytes);

        // Should not panic
        match result {
            Ok(_) | Err(_) => {}
        }
    }
}
```
Validates: Invalid input doesn't cause panics

### Stress Tests

**Test: High Snapshot Creation Rate**
```
fn test_high_snapshot_rate() {
    let db = Db::open_in_memory();

    for i in 0..10000 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&i.to_le_bytes(), b"data").unwrap();
        writer.commit().unwrap();
    }

    // Registry should handle 10k snapshots
    let stats = db.snapshot_stats();
    assert_eq!(stats.total_snapshots, 10001); // genesis + 10k
}
```
Validates: System handles high snapshot creation rate

**Test: Large Snapshot Registry**
```
fn test_large_snapshot_registry() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);

    // Create 100,000 snapshots
    for i in 1..100_000 {
        registry.register_snapshot(i, i + 1).unwrap();
    }

    // Operations should still work
    assert_eq!(registry.get_snapshot_root(50_000), Some(50_001));

    // Cleanup should complete
    let removed = registry.cleanup_old_snapshots(10_000, 1000).unwrap();
    assert!(removed > 0);
}
```
Validates: Large registries handled correctly

**Test: Cleanup Under Load**
```
fn test_cleanup_under_load() {
    let db = Arc::new(Db::open_in_memory());

    // Create many snapshots
    for i in 0..1000 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&i.to_le_bytes(), b"data").unwrap();
        writer.commit().unwrap();
    }

    // Spawn cleanup thread
    let db_clone = db.clone();
    let cleanup_handle = thread::spawn(move || {
        db_clone.cleanup_snapshots(100, 10).unwrap();
    });

    // Spawn reader threads
    let reader_handles: Vec<_> = (0..100)
        .map(|_| {
            let db = db.clone();
            thread::spawn(move || {
                let reader = db.begin_read().unwrap();
                reader.get(b"key")
            })
        })
        .collect();

    // All operations should complete
    cleanup_handle.join().unwrap();
    for handle in reader_handles {
        handle.join().unwrap();
    }
}
```
Validates: Cleanup works under concurrent load

## Performance Tests

### Snapshot Creation Throughput

**Test: Snapshot Creation Rate**
```
fn bench_snapshot_creation_throughput() {
    let db = Db::open_in_memory();

    let start = Instant::now();

    for i in 0..10_000 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&i.to_le_bytes(), b"data").unwrap();
        writer.commit().unwrap();
    }

    let duration = start.elapsed();
    let throughput = 10_000.0 / duration.as_secs_f64();

    println!("Snapshot creation: {} snapshots/sec", throughput);

    // Target: > 10,000 snapshots/sec
    assert!(throughput > 10_000.0);
}
```
Validates: Snapshot creation meets throughput target

**Test: Snapshot Creation Latency (P50, P99)**
```
fn bench_snapshot_creation_latency() {
    let db = Db::open_in_memory();

    let mut latencies = Vec::new();

    for i in 0..1000 {
        let start = Instant::now();
        let mut writer = db.begin_write().unwrap();
        writer.put(&[i as u8], b"data").unwrap();
        writer.commit().unwrap();
        latencies.push(start.elapsed());
    }

    latencies.sort();
    let p50 = latencies[latencies.len() / 2];
    let p99 = latencies[(latencies.len() * 99) / 100];

    println!("Snapshot creation P50: {:?}, P99: {:?}", p50, p99);

    // Targets: P50 < 100μs, P99 < 1ms
    assert!(p50 < Duration::from_micros(100));
    assert!(p99 < Duration::from_millis(1));
}
```
Validates: Snapshot creation latency meets targets

### Read Performance

**Test: Read Throughput**
```
fn bench_read_throughput() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut writer = db.begin_write().unwrap();
        for i in 0..10_000 {
            writer.put(&i.to_le_bytes(), b"data").unwrap();
        }
        writer.commit().unwrap();
    }

    let start = Instant::now();

    for i in 0..100_000 {
        let reader = db.begin_read().unwrap();
        let _ = reader.get(&[i as u8]);
    }

    let duration = start.elapsed();
    let throughput = 100_000.0 / duration.as_secs_f64();

    println!("Read throughput: {} reads/sec", throughput);

    // Target: > 100,000 reads/sec
    assert!(throughput > 100_000.0);
}
```
Validates: Read throughput meets target

**Test: Concurrent Reader Throughput**
```
fn bench_concurrent_reader_throughput() {
    let db = Arc::new(Db::open_in_memory());

    // Seed data
    {
        let mut writer = db.begin_write().unwrap();
        for i in 0..1000 {
            writer.put(&i.to_le_bytes(), b"data").unwrap();
        }
        writer.commit().unwrap();
    }

    let start = Instant::now();

    let handles: Vec<_> = (0..100)
        .map(|i| {
            let db = db.clone();
            thread::spawn(move || {
                for j in 0..1000 {
                    let reader = db.begin_read().unwrap();
                    let _ = reader.get(&[(i * 1000 + j) as u8]);
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    let duration = start.elapsed();
    let throughput = 100_000.0 / duration.as_secs_f64();

    println!("Concurrent read throughput: {} reads/sec", throughput);

    // Target: Scales linearly with reader count
    assert!(throughput > 50_000.0);
}
```
Validates: Concurrent reader throughput scales

### Cleanup Performance

**Test: Cleanup Performance**
```
fn bench_cleanup_performance() {
    let db = Db::open_in_memory();

    // Create many snapshots
    for i in 0..10_000 {
        let mut writer = db.begin_write().unwrap();
        writer.put(&i.to_le_bytes(), b"data").unwrap();
        writer.commit().unwrap();
    }

    let start = Instant::now();
    db.cleanup_snapshots(100, 10).unwrap();
    let duration = start.elapsed();

    println!("Cleanup 10k snapshots: {:?}", duration);

    // Target: < 100ms for 10k snapshots
    assert!(duration < Duration::from_millis(100));
}
```
Validates: Cleanup performance meets target

### Serialization Performance

**Test: Serialization Performance**
```
fn bench_serialization_performance() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);

    // Create 10,000 snapshots
    for i in 1..10_000 {
        registry.register_snapshot(i, i + 1).unwrap();
    }

    let start = Instant::now();
    let bytes = serialize(&registry).unwrap();
    let duration = start.elapsed();

    println!("Serialize 10k snapshots: {:?}", duration);
    println!("Serialized size: {} bytes", bytes.len());

    // Target: < 50ms for 10k snapshots
    assert!(duration < Duration::from_millis(50));
}
```
Validates: Serialization performance meets target

**Test: Deserialization Performance**
```
fn bench_deserialization_performance() {
    let mut registry = SnapshotRegistry::init(allocator, 0, 1);

    // Create 10,000 snapshots
    for i in 1..10_000 {
        registry.register_snapshot(i, i + 1).unwrap();
    }

    let bytes = serialize(&registry).unwrap();

    let start = Instant::now();
    let restored = deserialize(&bytes).unwrap();
    let duration = start.elapsed();

    println!("Deserialize 10k snapshots: {:?}", duration);

    assert_eq!(restored.total_snapshots(), 10_000);

    // Target: < 100ms for 10k snapshots
    assert!(duration < Duration::from_millis(100));
}
```
Validates: Deserialization performance meets target

## Test Organization

### Test File Structure

**Module Organization**:
```
northstar_core/
├── snapshot/
│   ├── mod.rs
│   ├── registry_tests.rs      # Snapshot registry tests
│   ├── visibility_tests.rs    # Visibility calculation tests
│   ├── reader_tests.rs        # Reader lifecycle tests
│   ├── refcount_tests.rs      # Reference counting tests
│   ├── serialization_tests.rs # Serialization tests
│   ├── concurrency_tests.rs   # Concurrent reader tests
│   ├── recovery_tests.rs      # Crash recovery tests
│   └── benchmarks.rs          # Performance benchmarks
```

### Test Utilities

**Test Helpers**:
```
mod test_helpers {
    pub fn create_test_registry() -> SnapshotRegistry {
        // Create registry with test data
    }

    pub fn create_test_snapshots(count: usize) -> SnapshotRegistry {
        // Create registry with N snapshots
    }

    pub fn corrupt_snapshot_magic(path: &PathBuf) {
        // Corrupt magic number for testing
    }

    pub fn corrupt_snapshot_checksum(path: &PathBuf) {
        // Corrupt checksum for testing
    }

    pub fn truncate_snapshot_file(path: &PathBuf, size: usize) {
        // Truncate file for testing
    }

    pub fn inject_failure_during_snapshot_write() {
        // Simulate crash during write
    }
}
```

### Test Execution

**Run All Tests**:
```bash
cargo test --package northstar-core --lib snapshot
```

**Run Specific Test Category**:
```bash
cargo test --package northstar-core --lib snapshot::tests::registry
cargo test --package northstar-core --lib snapshot::tests::concurrency
```

**Run Benchmarks**:
```bash
cargo test --package northstar-core --lib --release snapshot::benchmarks
```

**Run Property Tests**:
```bash
cargo test --package northstar-core --lib snapshot::proptest
```

## CI/CD Integration

### Continuous Integration

**Test Pipeline**:
1. **Unit Tests**: Fast feedback (< 5 minutes)
2. **Integration Tests**: Medium feedback (< 15 minutes)
3. **Property Tests**: Medium feedback (< 10 minutes)
4. **Hardening Tests**: Slow feedback (< 30 minutes, nightly)
5. **Benchmarks**: Regression checks (< 20 minutes)

**Regression Gates**:
- Snapshot creation throughput: -5% threshold
- Read throughput: -5% threshold
- Snapshot creation latency P99: +10% threshold
- Test failures: Block merge

### Test Coverage

**Target Coverage**: 90%+ line coverage for snapshot module
- Use tarpaulin or similar tool
- Coverage report generated on CI
- Uncovered code reviewed and justified

## Dependencies

- **Uses**:
  - All MVCC specifications (tasks 5.1-5.9)
  - Test frameworks (built-in Rust test, quickcheck, proptest)
  - Benchmark utilities (criterion)
  - Test helpers and fixtures

- **Validates**:
  - Snapshot registry correctness
  - Visibility calculation accuracy
  - Reader lifecycle management
  - Reference counting correctness
  - Serialization/deserialization
  - Isolation guarantees
  - Crash recovery
  - Performance targets

## Related Specifications

- **Snapshot Registry**: rust/05-snapshot-registry.md - Registry operations under test
- **Visibility Calculation**: rust/05-snapshot-vis.md - Visibility logic under test
- **MVCC Isolation**: rust/05-mvcc-isolation.md - Isolation guarantees being tested
- **Reader Handling**: rust/05-mvcc-readers.md - Reader lifecycle under test
- **Serialization**: rust/05-mvcc-serialization.md - Serialization under test
- **Semantics**: spec/semantics_v0.md - MVCC semantics being validated
