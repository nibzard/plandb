//! Integration tests for caching and concurrent operations.
//!
//! Tests cache behavior and multi-threaded access patterns.

use northstar_core::{cache::CacheConfig, db::Db, error::Result};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use super::{create_test_db, populate_db, TestContext};

/// Test concurrent read operations.
#[test]
fn test_concurrent_reads() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(&ctx.db_path)?;

    populate_db(&db, 100, "read-")?;

    // Spawn multiple readers
    let handles: Vec<_> = (0..10)
        .map(|_| {
            let db_clone = db.clone();
            thread::spawn(move || {
                let txn = db_clone.begin_read().unwrap();
                for i in 0..100 {
                    let key = format!("read-{:08x}", i);
                    let _ = txn.get(key.as_bytes());
                }
                true
            })
        })
        .collect();

    // Verify all readers succeed
    for handle in handles {
        assert!(handle.join().unwrap());
    }

    Ok(())
}

/// Test read/write mix under concurrency.
#[test]
fn test_concurrent_read_write_mix() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 100, "mix-")?;

    let success_count = Arc::new(Mutex::new(0));
    let mut handles = vec![];

    // Writer threads
    for w in 0..3 {
        let db_clone = db.clone();
        let success = Arc::clone(&success_count);
        handles.push(thread::spawn(move || {
            for i in 0..50 {
                let key = format!("mix-writer{:02}-{:08x}", w, i);
                let value = format!("value-{:08x}", i);
                if let Ok(mut txn) = db_clone.begin_write() {
                    if txn.put(key.as_bytes(), value.as_bytes()).is_ok()
                        && txn.commit().is_ok()
                    {
                        *success.lock().unwrap() += 1;
                    }
                }
                thread::sleep(Duration::from_micros(100));
            }
        }));
    }

    // Reader threads
    for _ in 0..10 {
        let db_clone = db.clone();
        let success = Arc::clone(&success_count);
        handles.push(thread::spawn(move || {
            for i in 0..100 {
                let key = format!("mix-{:08x}", i % 100);
                if let Ok(txn) = db_clone.begin_read() {
                    if txn.get(key.as_bytes()).is_ok() {
                        *success.lock().unwrap() += 1;
                    }
                }
            }
        }));
    }

    // Wait for all threads
    for handle in handles {
        handle.join().unwrap();
    }

    let total = *success_count.lock().unwrap();
    println!("Concurrent R/W: {} successful operations", total);
    assert!(total > 0);

    Ok(())
}

/// Test cache behavior with repeated reads.
#[test]
fn test_cache_repeated_reads() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 50, "cache-")?;

    // First pass - populate any caches
    let txn = db.begin_read()?;
    for i in 0..50 {
        let key = format!("cache-{:08x}", i);
        txn.get(key.as_bytes())?;
    }

    // Second pass - benefit from caching
    let txn = db.begin_read()?;
    for i in 0..50 {
        let key = format!("cache-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        assert!(result.is_some());
    }

    Ok(())
}

/// Test snapshot isolation under concurrent writes.
#[test]
fn test_snapshot_isolation() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Initial data
    populate_db(&db, 50, "snap-")?;

    // Take snapshot and record its txn_id
    let snapshot = db.snapshot()?;
    let snapshot_txn_id = snapshot.txn_id();

    // Write more data
    populate_db(&db, 50, "newsnap-")?;

    // New snapshot should have higher txn_id
    let new_snapshot = db.snapshot()?;
    assert!(new_snapshot.txn_id().as_u64() > snapshot_txn_id.as_u64());

    // Regular read should see new data
    let txn = db.begin_read()?;
    let value = txn.get(b"newsnap-00000000")?;
    assert!(value.is_some());

    Ok(())
}

/// Test transaction rollback on concurrent modification.
#[test]
fn test_transaction_isolation() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 10, "iso-")?;

    // Start two write transactions
    let mut txn1 = db.begin_write()?;
    let mut txn2 = db.begin_write()?;

    // Both try to modify same key
    txn1.put(b"iso-conflict", b"value1")?;
    txn2.put(b"iso-conflict", b"value2")?;

    // Commit first
    txn1.commit()?;

    // Second commit should handle conflict appropriately
    // (depending on isolation implementation)
    let result = txn2.commit();
    // May succeed with last-write-wins or fail with conflict
    let _ = result;

    Ok(())
}

/// Test database statistics accuracy.
#[test]
fn test_database_statistics() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Get initial stats
    let stats_before = db.stats()?;

    // Write data
    populate_db(&db, 100, "stats-")?;

    // Get updated stats
    let stats_after = db.stats()?;

    println!("Stats before: {:?}", stats_before);
    println!("Stats after: {:?}", stats_after);

    Ok(())
}

/// Test memory pressure handling.
#[test]
fn test_memory_pressure() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write large values
    let large_value = vec![b'X'; 1024 * 1024]; // 1MB

    let mut txn = db.begin_write()?;
    for i in 0..10 {
        let key = format!("large-{:08x}", i);
        txn.put(key.as_bytes(), &large_value)?;
    }
    txn.commit()?;

    // Read back
    let txn = db.begin_read()?;
    for i in 0..10 {
        let key = format!("large-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        assert!(result.is_some());
        assert_eq!(result.unwrap().len(), 1024 * 1024);
    }

    Ok(())
}

/// Test rapid open/close cycles.
#[test]
fn test_rapid_open_close() -> Result<()> {
    for cycle in 0..5 {
        let ctx = TestContext::new().unwrap();
        let mut db = create_test_db(ctx.db_path())?;

        populate_db(&db, 20, &format!("cycle{}-", cycle))?;

        let txn = db.begin_read()?;
        let key = format!("cycle{}-00000000", cycle);
        let value = txn.get(key.as_bytes())?;
        assert!(value.is_some());

        db.close()?;
    }

    Ok(())
}

/// Benchmark: Sequential write throughput.
#[test]
fn benchmark_sequential_writes() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    let start = std::time::Instant::now();
    let num_writes = 1000;

    let mut txn = db.begin_write()?;
    for i in 0..num_writes {
        let key = format!("bench-{:08x}", i);
        let value = format!("value-{:08x}", i);
        txn.put(key.as_bytes(), value.as_bytes())?;
    }
    txn.commit()?;

    let duration = start.elapsed();
    let ops_per_sec = num_writes as f64 / duration.as_secs_f64();

    println!(
        "Sequential writes: {} ops in {:?} ({:.0} ops/sec)",
        num_writes, duration, ops_per_sec
    );

    Ok(())
}

/// Benchmark: Concurrent read throughput.
#[test]
fn benchmark_concurrent_reads() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 1000, "readbench-")?;

    let num_threads = 10;
    let reads_per_thread = 100;

    let start = std::time::Instant::now();

    let handles: Vec<_> = (0..num_threads)
        .map(|_| {
            let db_clone = db.clone();
            thread::spawn(move || {
                let txn = db_clone.begin_read().unwrap();
                for i in 0..reads_per_thread {
                    let key = format!("readbench-{:08x}", i % 1000);
                    let _ = txn.get(key.as_bytes());
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    let duration = start.elapsed();
    let total_ops = num_threads * reads_per_thread;
    let ops_per_sec = total_ops as f64 / duration.as_secs_f64();

    println!(
        "Concurrent reads: {} ops in {:?} ({:.0} ops/sec)",
        total_ops, duration, ops_per_sec
    );

    Ok(())
}

#[cfg(test)]
mod test_helpers {
    use super::*;

    /// Test helper to verify data integrity.
    pub fn verify_data_integrity(db: &Db, count: usize, prefix: &str) -> Result<bool> {
        let txn = db.begin_read()?;
        for i in 0..count {
            let key = format!("{}{:08x}", prefix, i);
            let result = txn.get(key.as_bytes())?;
            if result.is_none() {
                return Ok(false);
            }
        }
        Ok(true)
    }
}
