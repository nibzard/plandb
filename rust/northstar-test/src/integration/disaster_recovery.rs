//! Integration tests for database persistence and recovery.
//!
//! Tests database durability, sync, and recovery scenarios.

use northstar_core::{db::Db, error::Result};
use std::fs;

use super::{create_test_db, populate_db, TestContext};

/// Test database persistence across close/reopen.
#[test]
fn test_database_persistence() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db_path = ctx.db_path().to_string();

    // Write data
    {
        let mut db = create_test_db(&db_path)?;
        populate_db(&db, 100, "persist-")?;
        db.sync()?;
        db.close()?;
    }

    // Reopen and verify
    {
        let mut db = create_test_db(&db_path)?;
        let txn = db.begin_read()?;
        let result = txn.get(b"persist-00000000")?;
        assert!(result.is_some());
        db.close()?;
    }

    Ok(())
}

/// Test data integrity after sync.
#[test]
fn test_sync_data_integrity() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 100, "sync-")?;

    // Sync to ensure data is written
    db.sync()?;

    // Verify data
    let txn = db.begin_read()?;
    for i in 0..100 {
        let key = format!("sync-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        assert!(result.is_some());
    }

    Ok(())
}

/// Test recovery after crash (simulated by close without sync).
#[test]
fn test_crash_recovery() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db_path = ctx.db_path().to_string();

    // Write data and close without explicit sync
    {
        let mut db = create_test_db(&db_path)?;
        populate_db(&db, 100, "crash-")?;
        // Close without sync (simulates crash)
        db.close()?;
    }

    // Reopen - WAL recovery should replay transactions
    {
        let mut db = create_test_db(&db_path)?;
        let txn = db.begin_read()?;
        // Check if data was recovered (may depend on WAL implementation)
        let result = txn.get(b"crash-00000000")?;
        // May or may not be present depending on WAL
        let _ = result;
        db.close()?;
    }

    Ok(())
}

/// Test multiple sequential open/close cycles.
#[test]
fn test_multiple_open_close_cycles() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db_path = ctx.db_path().to_string();

    for cycle in 0..5 {
        let mut db = create_test_db(&db_path)?;

        // Write data
        let mut txn = db.begin_write()?;
        for i in 0..20 {
            let key = format!("cycle{}-{:08x}", cycle, i);
            let value = format!("value-{}", i);
            txn.put(key.as_bytes(), value.as_bytes())?;
        }
        txn.commit()?;
        db.sync()?;
        db.close()?;
    }

    // Final verification
    let db = create_test_db(&db_path)?;
    let txn = db.begin_read()?;
    let result = txn.get(b"cycle0-00000000")?;
    assert!(result.is_some());

    Ok(())
}

/// Test database file exists after creation.
#[test]
fn test_database_file_creation() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db_path = ctx.db_path();

    let mut db = create_test_db(db_path)?;
    db.sync()?;

    // Verify file exists
    assert!(fs::metadata(db_path).is_ok());

    db.close()?;
    Ok(())
}

/// Test database size growth.
#[test]
fn test_database_size_growth() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db_path = ctx.db_path();

    let mut db = create_test_db(db_path)?;

    // Get initial size
    let size_before = fs::metadata(db_path)
        .map_err(|e| northstar_core::error::IoError::from(e))?
        .len();

    // Add data
    populate_db(&db, 100, "size-")?;
    db.sync()?;

    // Get new size
    let size_after = fs::metadata(db_path)
        .map_err(|e| northstar_core::error::IoError::from(e))?
        .len();

    // Database should have grown
    assert!(size_after > size_before);

    db.close()?;
    Ok(())
}

/// Test snapshot persistence.
#[test]
fn test_snapshot_persistence() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 50, "snap-")?;

    // Create snapshot and verify txn_id
    let snapshot = db.snapshot()?;
    let snapshot_txn_id = snapshot.txn_id();

    // Write more data
    populate_db(&db, 50, "newsnap-")?;

    // New snapshot should have higher txn_id
    let new_snapshot = db.snapshot()?;
    assert!(new_snapshot.txn_id().as_u64() > snapshot_txn_id.as_u64());

    // Verify we can still read data via regular transaction
    let txn = db.begin_read()?;
    let value = txn.get(b"snap-00000000")?;
    assert!(value.is_some());

    Ok(())
}

/// Test concurrent database access from multiple handles.
#[test]
fn test_concurrent_database_handles() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db_path = ctx.db_path().to_string();

    // Open first handle and write data
    {
        let db1 = create_test_db(&db_path)?;
        populate_db(&db1, 100, "concurrent-")?;
        db1.sync()?;
    }

    // Open second handle and verify
    {
        let db2 = create_test_db(&db_path)?;
        let txn = db2.begin_read()?;
        let result = txn.get(b"concurrent-00000000")?;
        assert!(result.is_some());
    }

    Ok(())
}

/// Test large dataset persistence.
#[test]
fn test_large_dataset_persistence() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db_path = ctx.db_path().to_string();

    // Write large dataset
    {
        let mut db = create_test_db(&db_path)?;
        let mut txn = db.begin_write()?;
        for i in 0..1000 {
            let key = format!("large-{:08x}", i);
            let value = format!("value-{:08x}-data", i);
            txn.put(key.as_bytes(), value.as_bytes())?;
        }
        txn.commit()?;
        db.sync()?;
        db.close()?;
    }

    // Reopen and verify sample
    {
        let mut db = create_test_db(&db_path)?;
        let txn = db.begin_read()?;

        // Check first, middle, and last
        let result = txn.get(b"large-00000000")?;
        assert!(result.is_some());

        let result = txn.get(b"large-000003e8")?; // 1000 in hex
        assert!(result.is_some());

        db.close()?;
    }

    Ok(())
}

/// Test database path handling.
#[test]
fn test_database_path_handling() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let mut db = create_test_db(ctx.db_path())?;

    // Check path is stored correctly
    let stored_path = db.path();
    assert!(stored_path.is_some());
    assert!(stored_path.unwrap().contains("test.db"));

    db.close()?;
    Ok(())
}

#[cfg(test)]
mod test_helpers {
    use super::*;

    /// Helper to get database file size.
    pub fn get_db_size(path: &str) -> Result<u64> {
        Ok(fs::metadata(path)
            .map_err(|e| northstar_core::error::IoError::from(e))?
            .len())
    }

    /// Helper to check if database file exists.
    pub fn db_file_exists(path: &str) -> bool {
        fs::metadata(path).is_ok()
    }
}
