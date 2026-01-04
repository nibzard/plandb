# Transaction System Tests

## Purpose

The transaction system test specification defines comprehensive testing requirements for validating transaction correctness, isolation, durability, and concurrency. Tests ensure ACID guarantees are maintained, edge cases are handled correctly, and the system behaves predictably under various conditions including crashes, corruption, and high contention. The test specification covers unit tests for individual operations, integration tests for transaction workflows, property-based tests for invariant validation, hardening tests for crash recovery, and performance benchmarks for throughput and latency targets.

## Overview

### Testing Philosophy

**Tests Are Source of Truth**: Benchmarks and tests validate database behavior
- All claims must be proven with reproducible tests
- No DB implementation changes unless tests pass
- Hardening tests must pass nightly
- CI gates on regression: -5% throughput, +10% p99 latency

**Test-Driven Development**: Red-Green-Refactor cycle
- Write failing test first
- Implement minimum to pass test
- Refactor for clarity
- Lock in with regression baselines

**Comprehensive Coverage**: Test all transaction behaviors
- Happy path: Normal operations succeed
- Error paths: Errors handled correctly
- Edge cases: Boundary conditions validated
- Concurrency: Multiple transactions interact correctly
- Durability: Crashes handled correctly

### Test Categories

**Unit Tests**: Test individual functions and operations
- Transaction lifecycle operations (begin, commit, rollback)
- Mutation operations (put, delete, get)
- State machine transitions
- Serialization and deserialization
- Error handling

**Integration Tests**: Test transaction workflows and scenarios
- Complete transaction workflows (begin → mutations → commit)
- Concurrent transaction interactions
- Crash recovery workflows
- WAL integration
- B+tree integration

**Property Tests**: Test invariants hold for all inputs
- Idempotency: Operations repeat safely
- Commutativity: Order independence properties
- Serializability: Isolation guarantees
- Determinism: Same input produces same output

**Hardening Tests**: Test system resilience under adverse conditions
- Crash simulation during various phases
- Corruption detection and handling
- Fuzzing with random inputs
- Stress testing with high load

**Performance Tests**: Test throughput and latency targets
- Read throughput (queries per second)
- Write throughput (transactions per second)
- Commit latency (time to persist)
- Read latency (query response time)

## Unit Tests

### Transaction Lifecycle Tests

**Test: Begin Read Transaction**
```
fn test_begin_read() {
    let db = Db::open_in_memory();

    let txn = db.begin_read().unwrap();

    assert!(txn.is_active());
    assert_eq!(txn.txn_id(), TransactionId::new(1));
    assert_eq!(txn.root_page_id(), PageId::new(INITIAL_ROOT));
}
```
Validates: Read transaction initializes correctly with snapshot

**Test: Begin Write Transaction**
```
fn test_begin_write() {
    let db = Db::open_in_memory();

    let txn = db.begin_write().unwrap();

    assert!(txn.is_active());
    assert_eq!(txn.txn_id(), TransactionId::new(1));
    assert!(txn.pending_ops().is_empty());
}
```
Validates: Write transaction initializes correctly with empty mutation buffer

**Test: Begin Write Fails When Writer Active**
```
fn test_begin_write_busy() {
    let db = Db::open_in_memory();

    let txn1 = db.begin_write().unwrap();
    let result = db.begin_write();

    assert_eq!(result, Err(Error::WriteBusy));
}
```
Validates: Single-writer enforcement

**Test: Commit Transaction**
```
fn test_commit() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.put(b"key", b"value").unwrap();
    txn.commit().unwrap();

    assert!(!txn.is_active());
    assert!(txn.is_committed());
}
```
Validates: Commit transitions state to Committed

**Test: Rollback Transaction**
```
fn test_rollback() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.put(b"key", b"value").unwrap();
    txn.rollback().unwrap();

    assert!(!txn.is_active());
    assert!(txn.is_aborted());

    // Verify data not in database
    let reader = db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), None);
}
```
Validates: Rollback discards mutations

**Test: Implicit Rollback on Drop**
```
fn test_implicit_rollback() {
    let db = Db::open_in_memory();

    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        // txn dropped here without commit
    }

    // Verify data not in database
    let reader = db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), None);
}
```
Validates: Drop trait performs implicit rollback

### Mutation Operation Tests

**Test: Put Then Get**
```
fn test_put_get() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.put(b"key", b"value").unwrap();
    assert_eq!(txn.get(b"key"), Some(b"value".to_vec()));
}
```
Validates: Read-your-writes for put

**Test: Delete Then Get**
```
fn test_delete_get() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.commit().unwrap();
    }

    // Delete and verify
    let mut txn = db.begin_write().unwrap();
    txn.delete(b"key").unwrap();
    assert_eq!(txn.get(b"key"), None);
}
```
Validates: Delete creates tombstone visible to get

**Test: Put Overrides Previous Put**
```
fn test_put_overrides() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.put(b"key", b"value1").unwrap();
    txn.put(b"key", b"value2").unwrap();
    assert_eq!(txn.get(b"key"), Some(b"value2".to_vec()));
    assert_eq!(txn.mutation_count(), 1); // Replacement, not addition
}
```
Validates: Last-write-wins semantics

**Test: Delete Overrides Put**
```
fn test_delete_overrides_put() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.put(b"key", b"value").unwrap();
    txn.delete(b"key").unwrap();
    assert_eq!(txn.get(b"key"), None);
}
```
Validates: Delete removes pending put

**Test: Put Overrides Delete**
```
fn test_put_overrides_delete() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.delete(b"key").unwrap();
    txn.put(b"key", b"value").unwrap();
    assert_eq!(txn.get(b"key"), Some(b"value".to_vec()));
}
```
Validates: Put resurrects deleted key

**Test: Delete Idempotency**
```
fn test_delete_idempotent() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.delete(b"key").unwrap();
    txn.delete(b"key").unwrap();
    txn.delete(b"key").unwrap();

    assert_eq!(txn.mutation_count(), 1); // Only one mutation
}
```
Validates: Duplicate deletes are no-ops

### State Machine Tests

**Test: Valid State Transitions**
```
fn test_state_transitions() {
    let db = Db::open_in_memory();

    // Active → Preparing → Committed
    let mut txn = db.begin_write().unwrap();
    assert!(txn.is_active());

    txn.prepare().unwrap();
    assert!(txn.is_preparing());

    txn.commit().unwrap();
    assert!(txn.is_committed());

    // Active → Aborted
    let mut txn2 = db.begin_write().unwrap();
    assert!(txn2.is_active());

    txn2.rollback().unwrap();
    assert!(txn2.is_aborted());
}
```
Validates: All valid state transitions work

**Test: Invalid State Transitions**
```
fn test_invalid_transitions() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.commit().unwrap(); // Committed

    // Operations after commit fail
    assert!(matches!(txn.put(b"key", b"value"), Err(Error::InvalidState { .. })));
    assert!(matches!(txn.commit(), Err(Error::InvalidState { .. })));
}
```
Validates: Invalid transitions return errors

**Test: Operations After Rollback**
```
fn test_operations_after_rollback() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.rollback().unwrap();

    // Operations after rollback fail
    assert!(matches!(txn.put(b"key", b"value"), Err(Error::InvalidState { .. })));
    assert!(matches!(txn.delete(b"key"), Err(Error::InvalidState { .. })));
}
```
Validates: Terminal states reject operations

### Serialization Tests

**Test: Serialize CommitRecord**
```
fn test_serialize_commit_record() {
    let record = CommitRecord {
        txn_id: TransactionId::new(100),
        root_page_id: PageId::new(42),
        mutations: vec![
            Mutation::Put { key: b"user:1".to_vec(), value: b"Alice".to_vec() },
            Mutation::Delete { key: b"user:2".to_vec() },
        ],
        checksum: 0,
    };

    let serialized = serialize_commit_record(&record).unwrap();

    // Verify header
    assert_eq!(&serialized[0..4], b"CMIT");
    assert_eq!(u64::from_le_bytes(serialized[4..12].try_into().unwrap()), 100);
    assert_eq!(u32::from_le_bytes(serialized[24..28].try_into().unwrap()), 2);
}
```
Validates: CommitRecord serializes correctly

**Test: Deserialize CommitRecord**
```
fn test_deserialize_commit_record() {
    let serialized = create_test_payload(); // Helper to create valid payload

    let record = deserialize_commit_record(&serialized).unwrap();

    assert_eq!(record.txn_id, TransactionId::new(100));
    assert_eq!(record.mutations.len(), 2);
}
```
Validates: CommitRecord deserializes correctly

**Test: Round-Trip Serialization**
```
fn test_round_trip_serialization() {
    let original = CommitRecord {
        txn_id: TransactionId::new(100),
        root_page_id: PageId::new(42),
        mutations: create_test_mutations(),
        checksum: 0,
    };

    let serialized = serialize_commit_record(&original).unwrap();
    let deserialized = deserialize_commit_record(&serialized).unwrap();

    assert_eq!(deserialized.txn_id, original.txn_id);
    assert_eq!(deserialized.mutations, original.mutations);
}
```
Validates: Serialization preserves data

### Error Handling Tests

**Test: Key Too Large**
```
fn test_key_too_large() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    let large_key = vec![0u8; MAX_KEY_SIZE + 1];
    let result = txn.put(&large_key, b"value");

    assert_eq!(result, Err(Error::KeyTooLarge));
}
```
Validates: Key size validation

**Test: Value Too Large**
```
fn test_value_too_large() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    let large_value = vec![0u8; MAX_VALUE_SIZE + 1];
    let result = txn.put(b"key", &large_value);

    assert_eq!(result, Err(Error::ValueTooLarge));
}
```
Validates: Value size validation

**Test: Empty Key**
```
fn test_empty_key() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    let result = txn.put(b"", b"value");

    assert_eq!(result, Err(Error::KeyEmpty));
}
```
Validates: Empty key rejection

**Test: Too Many Mutations**
```
fn test_too_many_mutations() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    for i in 0..MAX_OPERATIONS_PER_COMMIT {
        txn.put(&[i as u8], b"value").unwrap();
    }

    let result = txn.put(b"extra", b"value");
    assert_eq!(result, Err(Error::TooManyMutations));
}
```
Validates: Mutation count limit

## Integration Tests

### Complete Transaction Workflows

**Test: Begin-Put-Commit Workflow**
```
fn test_workflow_begin_put_commit() {
    let db = Db::open_in_memory();

    // Begin transaction
    let mut txn = db.begin_write().unwrap();

    // Perform mutations
    txn.put(b"key1", b"value1").unwrap();
    txn.put(b"key2", b"value2").unwrap();
    txn.delete(b"key3").unwrap();

    // Commit
    txn.commit().unwrap();

    // Verify data persisted
    let reader = db.begin_read().unwrap();
    assert_eq!(reader.get(b"key1"), Some(b"value1".to_vec()));
    assert_eq!(reader.get(b"key2"), Some(b"value2".to_vec()));
    assert_eq!(reader.get(b"key3"), None);
}
```
Validates: Complete write workflow

**Test: Begin-Put-Rollback Workflow**
```
fn test_workflow_begin_put_rollback() {
    let db = Db::open_in_memory();

    // Seed initial data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"old_value").unwrap();
        txn.commit().unwrap();
    }

    // Begin transaction and modify
    let mut txn = db.begin_write().unwrap();
    txn.put(b"key", b"new_value").unwrap();
    txn.rollback().unwrap();

    // Verify original data unchanged
    let reader = db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), Some(b"old_value".to_vec()));
}
```
Validates: Rollback discards changes

**Test: Prepare-Commit Two-Phase Workflow**
```
fn test_two_phase_commit() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();
    txn.put(b"key", b"value").unwrap();

    // Phase 1: Prepare
    txn.prepare().unwrap();
    assert!(txn.is_preparing());

    // Phase 2: Commit
    txn.commit().unwrap();
    assert!(txn.is_committed());

    // Verify data persisted
    let reader = db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), Some(b"value".to_vec()));
}
```
Validates: Two-phase commit protocol

### Concurrent Transaction Tests

**Test: Concurrent Readers**
```
fn test_concurrent_readers() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.commit().unwrap();
    }

    // Multiple concurrent readers
    let reader1 = db.begin_read().unwrap();
    let reader2 = db.begin_read().unwrap();
    let reader3 = db.begin_read().unwrap();

    // All readers can read
    assert_eq!(reader1.get(b"key"), Some(b"value".to_vec()));
    assert_eq!(reader2.get(b"key"), Some(b"value".to_vec()));
    assert_eq!(reader3.get(b"key"), Some(b"value".to_vec()));
}
```
Validates: Multiple readers proceed without blocking

**Test: Reader During Active Writer**
```
fn test_reader_during_writer() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value1").unwrap();
        txn.commit().unwrap();
    }

    // Begin writer
    let mut writer = db.begin_write().unwrap();
    writer.put(b"key", b"value2").unwrap(); // Uncommitted

    // Begin reader during active writer
    let reader = db.begin_read().unwrap();

    // Reader sees old value (not writer's uncommitted change)
    assert_eq!(reader.get(b"key"), Some(b"value1".to_vec()));

    // Writer commits
    writer.commit().unwrap();

    // Reader still sees old value (snapshot isolation)
    assert_eq!(reader.get(b"key"), Some(b"value1".to_vec()));
}
```
Validates: Snapshot isolation for readers

**Test: Writer Exclusion**
```
fn test_writer_exclusion() {
    let db = Db::open_in_memory();

    let writer1 = db.begin_write().unwrap();

    // Second writer fails
    let result = db.begin_write();
    assert_eq!(result, Err(Error::WriteBusy));

    // Drop first writer
    drop(writer1);

    // Second writer now succeeds
    let writer2 = db.begin_write().unwrap();
    assert!(writer2.is_active());
}
```
Validates: Single-writer enforcement

### Crash Recovery Tests

**Test: Recover Committed Transaction**
```
fn test_recover_committed() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Begin transaction and commit
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.commit().unwrap();
    }

    // Simulate crash and recover
    drop(db);
    let mut recovered_db = Db::open(&db_path).unwrap();

    // Verify data recovered
    let reader = recovered_db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), Some(b"value".to_vec()));
}
```
Validates: Committed transactions durable after crash

**Test: Discard Uncommitted Transaction**
```
fn test_discard_uncommitted() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Begin transaction but crash before commit
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        // Crash here (drop without commit)
    }

    // Simulate crash and recover
    drop(db);
    let recovered_db = Db::open(&db_path).unwrap();

    // Verify data not persisted
    let reader = recovered_db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), None);
}
```
Validates: Uncommitted transactions discarded after crash

**Test: Recover After Prepare Phase**
```
fn test_recover_after_prepare() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Begin transaction, prepare, crash before commit
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.prepare().unwrap(); // WAL written
        // Crash here (drop without commit)
    }

    // Simulate crash and recover
    drop(db);
    let mut recovered_db = Db::open(&db_path).unwrap();

    // WAL replay should complete transaction
    let reader = recovered_db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), Some(b"value".to_vec()));
}
```
Validates: WAL replay completes prepared transactions

### WAL Integration Tests

**Test: WAL Record Append and Read**
```
fn test_wal_append_read() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Write transaction (appends to WAL)
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.commit().unwrap();
    }

    // Verify WAL record exists
    let wal = db.wal();
    let records = wal.read_all().unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].txn_id, TransactionId::new(1));
}
```
Validates: WAL records written during commit

**Test: WAL Checksum Validation**
```
fn test_wal_checksum() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Write transaction
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.commit().unwrap();
    }

    // Corrupt WAL record
    corrupt_wal_file(&db_path);

    // Recovery should detect corruption
    let result = Db::open(&db_path);
    assert!(matches!(result, Err(Error::CorruptWal { .. })));
}
```
Validates: WAL checksum detects corruption

## Property Tests

### Idempotency Properties

**Property: Put Idempotency with Same Value**
```
#[quickcheck]
fn prop_put_same_value_idempotent(key: Vec<u8>, value: Vec<u8>) {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.put(&key, &value).unwrap();
    txn.put(&key, &value).unwrap();

    assert_eq!(txn.get(&key), Some(value.clone()));
    assert_eq!(txn.mutation_count(), 1); // Replacement, not addition
}
```
Validates: Putting same key-value pair twice is idempotent

**Property: Delete Idempotency**
```
#[quickcheck]
fn prop_delete_idempotent(key: Vec<u8>) {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.delete(&key).unwrap();
    txn.delete(&key).unwrap();
    txn.delete(&key).unwrap();

    assert_eq!(txn.mutation_count(), 1); // Only one mutation
}
```
Validates: Deleting same key multiple times is idempotent

**Property: Rollback Idempotency**
```
fn test_rollback_idempotent() {
    let db = Db::open_in_memory();
    let mut txn = db.begin_write().unwrap();

    txn.rollback().unwrap();
    txn.rollback().unwrap();
    txn.rollback().unwrap();

    assert!(txn.is_aborted()); // Still aborted
}
```
Validates: Rollback can be called multiple times safely

### Serializability Properties

**Property: Concurrent Transactions Serialize**
```
fn test_concurrent_transactions_serialize() {
    let db = Db::open_in_memory();

    // Transaction A: Put key1
    let mut txn_a = db.begin_write().unwrap();
    txn_a.put(b"key1", b"value_a").unwrap();
    txn_a.commit().unwrap();

    // Transaction B: Put key2
    let mut txn_b = db.begin_write().unwrap();
    txn_b.put(b"key2", b"value_b").unwrap();
    txn_b.commit().unwrap();

    // Final state: Both keys present (serializable)
    let reader = db.begin_read().unwrap();
    assert_eq!(reader.get(b"key1"), Some(b"value_a".to_vec()));
    assert_eq!(reader.get(b"key2"), Some(b"value_b".to_vec()));
}
```
Validates: Concurrent transactions produce serializable outcome

**Property: Snapshot Isolation Consistency**
```
fn test_snapshot_isolation_consistency() {
    let db = Db::open_in_memory();

    // Transaction A: Put key, commit
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value1").unwrap();
        txn.commit().unwrap();
    }

    // Transaction B: Begin read (snapshot at txn A)
    let reader = db.begin_read().unwrap();

    // Transaction C: Put key, commit
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value2").unwrap();
        txn.commit().unwrap();
    }

    // Reader still sees value1 (snapshot isolation)
    assert_eq!(reader.get(b"key"), Some(b"value1".to_vec()));
}
```
Validates: Snapshot isolation provides consistent view

### Determinism Properties

**Property: Same Input Produces Same Output**
```
fn test_deterministic_serialization() {
    let record = CommitRecord {
        txn_id: TransactionId::new(100),
        root_page_id: PageId::new(42),
        mutations: vec![
            Mutation::Put { key: b"key".to_vec(), value: b"value".to_vec() },
        ],
        checksum: 0,
    };

    let serialized1 = serialize_commit_record(&record).unwrap();
    let serialized2 = serialize_commit_record(&record).unwrap();

    assert_eq!(serialized1, serialized2); // Deterministic
}
```
Validates: Serialization is deterministic (no randomness)

## Hardening Tests

### Crash Simulation Tests

**Test: Crash During Active Transaction**
```
fn test_crash_during_active_transaction() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Begin transaction but crash before any durable writes
    {
        let _txn = db.begin_write().unwrap();
        // Crash here
    }

    // Recover
    let recovered_db = Db::open(&db_path).unwrap();

    // Database should be consistent (no partial transaction)
    let reader = recovered_db.begin_read().unwrap();
    assert_eq!(reader.get(b"any_key"), None);
}
```
Validates: Active transaction lost on crash (no WAL written)

**Test: Crash During Prepare**
```
fn test_crash_during_prepare() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Simulate crash during WAL write
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        // Inject failure during prepare (WAL write)
        inject_wal_failure();
        let _ = txn.prepare();
    }

    // Recover (WAL write incomplete, ignored)
    let recovered_db = Db::open(&db_path).unwrap();
    let reader = recovered_db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), None); // Transaction not recovered
}
```
Validates: Incomplete WAL writes ignored during recovery

**Test: Crash During Commit**
```
fn test_crash_during_commit() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Prepare succeeds, crash during B+tree apply
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.prepare().unwrap(); // WAL written
        // Crash here (before B+tree apply)
    }

    // Recover (WAL replay completes transaction)
    let recovered_db = Db::open(&db_path).unwrap();
    let reader = recovered_db.begin_read().unwrap();
    assert_eq!(reader.get(b"key"), Some(b"value".to_vec())); // Replayed
}
```
Validates: WAL replay completes transactions after prepare

### Corruption Detection Tests

**Test: Detect Corrupt WAL Magic**
```
fn test_detect_corrupt_wal_magic() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Corrupt WAL magic number
    corrupt_wal_magic(&db_path);

    // Recovery should detect corruption
    let result = Db::open(&db_path);
    assert!(matches!(result, Err(Error::CorruptWal { .. })));
}
```
Validates: WAL magic number validation

**Test: Detect Corrupt Payload**
```
fn test_detect_corrupt_payload() {
    let db_path = create_temp_db();
    let mut db = Db::open(&db_path).unwrap();

    // Write transaction
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.commit().unwrap();
    }

    // Corrupt payload checksum
    corrupt_payload_checksum(&db_path);

    // Recovery should detect corruption
    let result = Db::open(&db_path);
    assert!(matches!(result, Err(Error::CorruptWal { .. })));
}
```
Validates: Payload checksum detects corruption

### Fuzzing Tests

**Test: Fuzz Random Keys and Values**
```
fn test_fuzz_random_keys_values() {
    let mut rng = StdRng::from_entropy();
    let db = Db::open_in_memory();

    for _ in 0..1000 {
        let key = random_bytes(&mut rng, 1..MAX_KEY_SIZE);
        let value = random_bytes(&mut rng, 0..MAX_VALUE_SIZE);

        let mut txn = db.begin_write().unwrap();
        txn.put(&key, &value).unwrap();
        txn.commit().unwrap();

        // Verify
        let reader = db.begin_read().unwrap();
        assert_eq!(reader.get(&key), Some(value));
    }
}
```
Validates: System handles various key/value sizes

**Test: Fuzz Random Operation Sequences**
```
fn test_fuzz_random_operations() {
    let mut rng = StdRng::from_entropy();
    let db = Db::open_in_memory();

    let keys: Vec<Vec<u8>> = (0..100)
        .map(|_| random_bytes(&mut rng, 1..MAX_KEY_SIZE))
        .collect();

    for _ in 0..1000 {
        let mut txn = db.begin_write().unwrap();

        // Random operations
        for _ in 0..10 {
            let key = &keys[rng.gen_range(0..keys.len())];
            match rng.gen_range(0..3) {
                0 => { txn.put(key, b"value").unwrap(); }
                1 => { txn.delete(key).unwrap(); }
                2 => { let _ = txn.get(key); }
                _ => unreachable!(),
            }
        }

        txn.commit().unwrap();
    }

    // Database should be consistent
    let reader = db.begin_read().unwrap();
    // Verify no corruption errors
}
```
Validates: Random operation sequences don't corrupt state

### Stress Tests

**Test: High Concurrency Stress**
```
fn test_high_concurrency_stress() {
    let db = Arc::new(Db::open_in_memory());
    let handles: Vec<_> = (0..10)
        .map(|_| {
            let db = db.clone();
            thread::spawn(move || {
                for i in 0..100 {
                    let mut txn = db.begin_write().unwrap();
                    txn.put(format!("key{}", i).as_bytes(), b"value").unwrap();
                    txn.commit().unwrap();
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    // All transactions should have committed
    let reader = db.begin_read().unwrap();
    let count = reader.scan(b""..b"~").count();
    assert_eq!(count, 1000); // 10 threads × 100 ops
}
```
Validates: System stable under high concurrency

**Test: Large Transaction Stress**
```
fn test_large_transaction_stress() {
    let db = Db::open_in_memory();

    let mut txn = db.begin_write().unwrap();

    // Maximum mutations
    for i in 0..MAX_OPERATIONS_PER_COMMIT {
        txn.put(format!("key{}", i).as_bytes(), b"value").unwrap();
    }

    txn.commit().unwrap();

    // Verify all mutations persisted
    let reader = db.begin_read().unwrap();
    for i in 0..MAX_OPERATIONS_PER_COMMIT {
        assert_eq!(reader.get(format!("key{}", i).as_bytes()), Some(b"value".to_vec()));
    }
}
```
Validates: Maximum transaction size handled correctly

## Performance Tests

### Throughput Benchmarks

**Test: Read Throughput**
```
fn bench_read_throughput() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut txn = db.begin_write().unwrap();
        for i in 0..10000 {
            txn.put(format!("key{}", i).as_bytes(), b"value").unwrap();
        }
        txn.commit().unwrap();
    }

    // Benchmark reads
    let start = Instant::now();
    for i in 0..10000 {
        let reader = db.begin_read().unwrap();
        let _ = reader.get(format!("key{}", i).as_bytes());
    }
    let duration = start.elapsed();

    let throughput = 10000.0 / duration.as_secs_f64();
    println!("Read throughput: {} ops/sec", throughput);

    // Target: > 100,000 reads/sec
    assert!(throughput > 100_000.0);
}
```
Validates: Read throughput meets target

**Test: Write Throughput**
```
fn bench_write_throughput() {
    let db = Db::open_in_memory();

    let start = Instant::now();
    for i in 0..1000 {
        let mut txn = db.begin_write().unwrap();
        txn.put(format!("key{}", i).as_bytes(), b"value").unwrap();
        txn.commit().unwrap();
    }
    let duration = start.elapsed();

    let throughput = 1000.0 / duration.as_secs_f64();
    println!("Write throughput: {} txn/sec", throughput);

    // Target: > 10,000 transactions/sec
    assert!(throughput > 10_000.0);
}
```
Validates: Write throughput meets target

### Latency Benchmarks

**Test: Read Latency (P50, P99)**
```
fn bench_read_latency() {
    let db = Db::open_in_memory();

    // Seed data
    {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();
        txn.commit().unwrap();
    }

    let mut latencies = Vec::new();

    for _ in 0..10000 {
        let start = Instant::now();
        let reader = db.begin_read().unwrap();
        let _ = reader.get(b"key");
        latencies.push(start.elapsed());
    }

    latencies.sort();
    let p50 = latencies[latencies.len() / 2];
    let p99 = latencies[(latencies.len() * 99) / 100];

    println!("Read P50: {:?}, P99: {:?}", p50, p99);

    // Targets: P50 < 1ms, P99 < 10ms
    assert!(p50 < Duration::from_millis(1));
    assert!(p99 < Duration::from_millis(10));
}
```
Validates: Read latency meets targets

**Test: Commit Latency**
```
fn bench_commit_latency() {
    let db = Db::open_in_memory();

    let mut latencies = Vec::new();

    for _ in 0..1000 {
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key", b"value").unwrap();

        let start = Instant::now();
        txn.commit().unwrap();
        latencies.push(start.elapsed());
    }

    latencies.sort();
    let p50 = latencies[latencies.len() / 2];
    let p99 = latencies[(latencies.len() * 99) / 100];

    println!("Commit P50: {:?}, P99: {:?}", p50, p99);

    // Targets: P50 < 10ms, P99 < 100ms
    assert!(p50 < Duration::from_millis(10));
    assert!(p99 < Duration::from_millis(100));
}
```
Validates: Commit latency meets targets

## Test Organization

### Test File Structure

**Module Organization**:
```
northstar_core/
├── txn/
│   ├── mod.rs
│   ├── tests.rs              # Transaction lifecycle tests
│   ├── mutation_tests.rs      # Put/delete/get tests
│   ├── state_tests.rs         # State machine tests
│   ├── serialization_tests.rs # Serialization tests
│   ├── concurrency_tests.rs   # Concurrent transaction tests
│   ├── recovery_tests.rs      # Crash recovery tests
│   └── benchmarks.rs          # Performance benchmarks
```

### Test Utilities

**Test Helpers**:
```
mod test_helpers {
    pub fn create_temp_db() -> PathBuf {
        // Create temporary database file
        // Return path for cleanup
    }

    pub fn corrupt_wal_file(path: &PathBuf) {
        // Corrupt WAL file for testing
    }

    pub fn inject_wal_failure() {
        // Inject WAL failure for crash simulation
    }

    pub fn random_bytes(rng: &mut StdRng, range: Range<usize>) -> Vec<u8> {
        // Generate random bytes for fuzzing
    }
}
```

### Test Execution

**Run All Tests**:
```bash
cargo test --package northstar-core --lib
```

**Run Specific Test Category**:
```bash
cargo test --package northstar-core --lib txn::tests::lifecycle
cargo test --package northstar-core --lib txn::tests::concurrency
```

**Run Benchmarks**:
```bash
cargo test --package northstar-core --lib --release txn::benchmarks
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
- Throughput: -5% threshold (alert on degradation)
- Latency P99: +10% threshold (alert on degradation)
- Test failures: Block merge

### Test Coverage

**Target Coverage**: 90%+ line coverage for transaction module
- Use tarpaulin or similar tool
- Coverage report generated on CI
- Uncovered code reviewed and justified

## Dependencies

- **Uses**:
  - All transaction specifications (tasks 4.1-4.14)
  - Test frameworks (built-in Rust test, quickcheck, proptest)
  - Benchmark utilities (criterion)
  - Test helpers and fixtures

- **Validates**:
  - Transaction correctness
  - ACID guarantees
  - Concurrency behavior
  - Crash recovery
  - Performance targets

## Related Specifications

- **Transaction Overview**: rust/04-txn-overview.md - ACID guarantees being tested
- **Transaction Operations**: rust/04-txn-{put,delete,get,commit,rollback}.md - Operations under test
- **Transaction State**: rust/04-txn-state.md - State machine being tested
- **Transaction Concurrency**: rust/04-txn-concurrency.md - Concurrent behavior under test
- **Semantics**: spec/semantics_v0.md - Transaction semantics being validated
