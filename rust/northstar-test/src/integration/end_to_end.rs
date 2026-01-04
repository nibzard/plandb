//! End-to-end workflow tests.
//!
//! Tests complete workflows spanning insert, query, and persistence.

use northstar_core::{db::Db, error::Result};
use std::time::Instant;

use super::{create_test_db, populate_db, TestContext};

/// Complete workflow: insert -> query -> verify.
#[test]
fn test_complete_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Phase 1: Insert data
    populate_db(&db, 200, "workflow-")?;

    // Phase 2: Query and verify
    let txn = db.begin_read()?;
    let value = txn.get(b"workflow-00000000")?;
    println!("Value for workflow-00000000: {:?}", value);
    assert!(value.is_some(), "Key workflow-00000000 should exist");

    // Phase 3: Verify multiple keys
    for i in 0..10 {
        let key = format!("workflow-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        println!("Value for {}: {:?}", key, result.is_some());
        assert!(result.is_some());
    }

    Ok(())
}

/// Write-read-verify workflow.
#[test]
fn test_write_read_verify_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write phase
    let mut write_txn = db.begin_write()?;
    for i in 0..100 {
        let key = format!("wrv-{:08x}", i);
        let value = format!("data-{}", i);
        write_txn.put(key.as_bytes(), value.as_bytes())?;
    }
    write_txn.commit()?;

    // Read phase
    let read_txn = db.begin_read()?;
    for i in 0..100 {
        let key = format!("wrv-{:08x}", i);
        let result = read_txn.get(key.as_bytes())?;
        assert!(result.is_some());
    }

    // Verify phase
    let result = read_txn.get(b"wrv-00000000")?;
    assert_eq!(result, Some(b"data-0".to_vec()));

    Ok(())
}

/// Update-read workflow.
#[test]
fn test_update_read_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Initial write
    populate_db(&db, 50, "update-")?;

    // Update phase
    let mut write_txn = db.begin_write()?;
    for i in 0..50 {
        let key = format!("update-{:08x}", i);
        let value = format!("updated-{}", i);
        write_txn.put(key.as_bytes(), value.as_bytes())?;
    }
    write_txn.commit()?;

    // Verify updates
    let read_txn = db.begin_read()?;
    let result = read_txn.get(b"update-00000000")?;
    assert_eq!(result, Some(b"updated-0".to_vec()));

    Ok(())
}

/// Delete-verify workflow.
#[test]
fn test_delete_verify_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write data
    populate_db(&db, 100, "delete-")?;

    // Delete phase
    let mut write_txn = db.begin_write()?;
    for i in 0..50 {
        let key = format!("delete-{:08x}", i);
        write_txn.delete(key.as_bytes())?;
    }
    write_txn.commit()?;

    // Verify deletions
    let read_txn = db.begin_read()?;

    let result = read_txn.get(b"delete-00000000")?;
    assert!(result.is_none());

    let result = read_txn.get(b"delete-00000050")?;
    assert!(result.is_some());

    Ok(())
}

/// Batch operations workflow.
#[test]
fn test_batch_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Batch insert
    for batch in 0..5 {
        let mut txn = db.begin_write()?;
        for i in 0..50 {
            let key = format!("batch-{:02}-{:08x}", batch, i);
            let value = format!("value-{}", batch * 50 + i);
            txn.put(key.as_bytes(), value.as_bytes())?;
        }
        txn.commit()?;
    }

    // Verify all batches
    let txn = db.begin_read()?;
    let mut found = 0;
    for batch in 0..5 {
        for i in 0..50 {
            let key = format!("batch-{:02}-{:08x}", batch, i);
            if txn.get(key.as_bytes())?.is_some() {
                found += 1;
            }
        }
    }

    assert_eq!(found, 250);

    Ok(())
}

/// Snapshot workflow.
#[test]
fn test_snapshot_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write initial data
    populate_db(&db, 50, "snap-")?;

    // Create snapshot and verify it exists
    let snapshot = db.snapshot()?;
    assert!(snapshot.txn_id().as_u64() >= 1); // After writes

    // Write more data
    populate_db(&db, 50, "newsnap-")?;

    // New snapshot should have higher txn_id
    let new_snapshot = db.snapshot()?;
    assert!(new_snapshot.txn_id().as_u64() > snapshot.txn_id().as_u64());

    // Current transaction should see all data
    let txn = db.begin_read()?;
    let value = txn.get(b"newsnap-00000000")?;
    assert!(value.is_some());

    Ok(())
}

/// Performance measurement workflow.
#[test]
fn test_performance_measurement_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Measure write performance
    let start = Instant::now();
    let mut txn = db.begin_write()?;
    for i in 0..500 {
        let key = format!("perf-{:08x}", i);
        let value = format!("value-{}", i);
        txn.put(key.as_bytes(), value.as_bytes())?;
    }
    txn.commit()?;
    let write_duration = start.elapsed();

    // Measure read performance
    let start = Instant::now();
    let txn = db.begin_read()?;
    for i in 0..500 {
        let key = format!("perf-{:08x}", i);
        txn.get(key.as_bytes())?;
    }
    let read_duration = start.elapsed();

    println!("Write performance: 500 ops in {:?}", write_duration);
    println!("Read performance: 500 ops in {:?}", read_duration);

    Ok(())
}

/// Data consistency workflow.
#[test]
fn test_data_consistency_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write data with specific values
    let mut txn = db.begin_write()?;
    for i in 0..100 {
        let key = format!("consistency-{:08x}", i);
        let value = format!("value-{}-checksum-{:08x}", i, i * 12345);
        txn.put(key.as_bytes(), value.as_bytes())?;
    }
    txn.commit()?;

    // Verify consistency
    let txn = db.begin_read()?;
    for i in 0..100 {
        let key = format!("consistency-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        assert!(result.is_some());

        let expected = format!("value-{}-checksum-{:08x}", i, i * 12345);
        assert_eq!(result, Some(expected.into_bytes()));
    }

    Ok(())
}

/// Large dataset workflow.
#[test]
fn test_large_dataset_workflow() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write large dataset
    let mut txn = db.begin_write()?;
    for i in 0..5000 {
        let key = format!("large-{:08x}", i);
        let value = format!("value-{}-data", i);
        txn.put(key.as_bytes(), value.as_bytes())?;
    }
    txn.commit()?;

    // Verify sample of data
    let txn = db.begin_read()?;

    // Check beginning, middle, and end
    let result = txn.get(b"large-00000000")?;
    assert!(result.is_some());

    let result = txn.get(b"large-00001388")?; // ~5000 in hex
    assert!(result.is_some());

    // Count total
    let mut count = 0;
    for i in 0..5000 {
        let key = format!("large-{:08x}", i);
        if txn.get(key.as_bytes())?.is_some() {
            count += 1;
        }
    }

    assert_eq!(count, 5000);

    Ok(())
}

#[cfg(test)]
mod test_helpers {
    use super::*;

    /// Helper to measure workflow latency.
    pub fn measure_workflow_latency<F, R>(f: F) -> (R, std::time::Duration)
    where
        F: FnOnce() -> R,
    {
        let start = std::time::Instant::now();
        let result = f();
        let duration = start.elapsed();
        (result, duration)
    }

    /// Helper to verify workflow completeness.
    pub fn verify_workflow_complete(db: &Db) -> Result<bool> {
        // Check that basic operations work
        let txn = db.begin_read()?;
        let _ = txn.get(b"test");

        let mut write_txn = db.begin_write()?;
        write_txn.put(b"workflow-test", b"ok")?;
        write_txn.commit()?;

        Ok(true)
    }
}
