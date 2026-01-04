//! Integration tests for query patterns and database operations.
//!
//! Tests various query patterns and access scenarios.

use northstar_core::{db::Db, error::Result};
use rand::seq::SliceRandom;
use std::time::Instant;

use super::{create_test_db, populate_db, TestContext};

/// Test sequential key access pattern.
#[test]
fn test_sequential_access_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 100, "seq-")?;

    let txn = db.begin_read()?;
    for i in 0..100 {
        let key = format!("seq-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        assert!(result.is_some());
    }

    Ok(())
}

/// Test random key access pattern.
#[test]
fn test_random_access_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 100, "rand-")?;

    let mut keys: Vec<usize> = (0..100).collect();
    keys.shuffle(&mut rand::thread_rng());

    let txn = db.begin_read()?;
    for i in keys {
        let key = format!("rand-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        assert!(result.is_some());
    }

    Ok(())
}

/// Test range query pattern.
#[test]
fn test_range_query_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 100, "range-")?;

    let txn = db.begin_read()?;
    let mut found = 0;

    // Query a range of keys
    for i in 25..50 {
        let key = format!("range-{:08x}", i);
        if txn.get(key.as_bytes())?.is_some() {
            found += 1;
        }
    }

    assert_eq!(found, 25);

    Ok(())
}

/// Test repeated access to same keys (hot spot pattern).
#[test]
fn test_hotspot_access_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 100, "hot-")?;

    // Repeatedly access same 10 keys
    let txn = db.begin_read()?;
    for _ in 0..100 {
        for i in 0..10 {
            let key = format!("hot-{:08x}", i);
            let result = txn.get(key.as_bytes())?;
            assert!(result.is_some());
        }
    }

    Ok(())
}

/// Test write-then-read pattern.
#[test]
fn test_write_then_read_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write data
    let mut write_txn = db.begin_write()?;
    for i in 0..50 {
        let key = format!("wr-{:08x}", i);
        let value = format!("value-{}", i);
        write_txn.put(key.as_bytes(), value.as_bytes())?;
    }
    write_txn.commit()?;

    // Read back
    let read_txn = db.begin_read()?;
    for i in 0..50 {
        let key = format!("wr-{:08x}", i);
        let result = read_txn.get(key.as_bytes())?;
        assert!(result.is_some());
    }

    Ok(())
}

/// Test batch insert pattern.
#[test]
fn test_batch_insert_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    let batch_size = 100;
    let num_batches = 5;

    for batch in 0..num_batches {
        let mut txn = db.begin_write()?;
        for i in 0..batch_size {
            let key = format!("batch{:02}-{:08x}", batch, i);
            let value = format!("value-{:08x}", batch * batch_size + i);
            txn.put(key.as_bytes(), value.as_bytes())?;
        }
        txn.commit()?;
    }

    // Verify all data
    let txn = db.begin_read()?;
    let mut total_found = 0;
    for batch in 0..num_batches {
        for i in 0..batch_size {
            let key = format!("batch{:02}-{:08x}", batch, i);
            if txn.get(key.as_bytes())?.is_some() {
                total_found += 1;
            }
        }
    }

    assert_eq!(total_found, batch_size * num_batches);

    Ok(())
}

/// Test update pattern.
#[test]
fn test_update_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Initial write
    populate_db(&db, 50, "update-")?;

    // Update keys
    let mut txn = db.begin_write()?;
    for i in 0..50 {
        let key = format!("update-{:08x}", i);
        let value = format!("updated-{}", i);
        txn.put(key.as_bytes(), value.as_bytes())?;
    }
    txn.commit()?;

    // Verify updates
    let txn = db.begin_read()?;
    let result = txn.get(b"update-00000000")?;
    assert_eq!(result, Some(b"updated-0".to_vec()));

    Ok(())
}

/// Test delete pattern.
#[test]
fn test_delete_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 50, "delete-")?;

    // Delete some keys
    let mut txn = db.begin_write()?;
    for i in 0..25 {
        let key = format!("delete-{:08x}", i);
        txn.delete(key.as_bytes())?;
    }
    txn.commit()?;

    // Verify deletions
    let txn = db.begin_read()?;

    let result = txn.get(b"delete-00000000")?;
    assert!(result.is_none());

    let result = txn.get(b"delete-00000030")?;
    assert!(result.is_some());

    Ok(())
}

/// Test large value pattern.
#[test]
fn test_large_value_pattern() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write large values
    let large_value = vec![b'X'; 100_000]; // 100KB

    let mut txn = db.begin_write()?;
    for i in 0..10 {
        let key = format!("large-{:08x}", i);
        txn.put(key.as_bytes(), &large_value)?;
    }
    txn.commit()?;

    // Read back
    let txn = db.begin_read()?;
    let result = txn.get(b"large-00000000")?;
    assert!(result.is_some());
    assert_eq!(result.unwrap().len(), 100_000);

    Ok(())
}

/// Benchmark: Sequential read performance.
#[test]
fn benchmark_sequential_reads() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 1000, "seqread-")?;

    let start = Instant::now();
    let num_reads = 1000;

    let txn = db.begin_read()?;
    for i in 0..num_reads {
        let key = format!("seqread-{:08x}", i);
        txn.get(key.as_bytes())?;
    }

    let duration = start.elapsed();
    let ops_per_sec = num_reads as f64 / duration.as_secs_f64();

    println!(
        "Sequential reads: {} ops in {:?} ({:.0} ops/sec)",
        num_reads, duration, ops_per_sec
    );

    Ok(())
}

/// Benchmark: Random read performance.
#[test]
fn benchmark_random_reads() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 1000, "randread-")?;

    let mut keys: Vec<usize> = (0..1000).collect();
    keys.shuffle(&mut rand::thread_rng());

    let start = Instant::now();
    let num_reads = 1000;

    let txn = db.begin_read()?;
    for i in keys {
        let key = format!("randread-{:08x}", i);
        txn.get(key.as_bytes())?;
    }

    let duration = start.elapsed();
    let ops_per_sec = num_reads as f64 / duration.as_secs_f64();

    println!(
        "Random reads: {} ops in {:?} ({:.0} ops/sec)",
        num_reads, duration, ops_per_sec
    );

    Ok(())
}

/// Benchmark: Mixed workload performance.
#[test]
fn benchmark_mixed_workload() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 500, "mixed-")?;

    let start = Instant::now();
    let num_ops = 500;

    for i in 0..num_ops {
        if i % 3 == 0 {
            // Read
            let txn = db.begin_read()?;
            let key = format!("mixed-{:08x}", i % 500);
            txn.get(key.as_bytes())?;
        } else if i % 3 == 1 {
            // Write
            let mut txn = db.begin_write()?;
            let key = format!("mixed-write-{:08x}", i);
            txn.put(key.as_bytes(), b"value")?;
            txn.commit()?;
        } else {
            // Update
            let mut txn = db.begin_write()?;
            let key = format!("mixed-{:08x}", i % 500);
            txn.put(key.as_bytes(), b"updated")?;
            txn.commit()?;
        }
    }

    let duration = start.elapsed();
    let ops_per_sec = num_ops as f64 / duration.as_secs_f64();

    println!(
        "Mixed workload: {} ops in {:?} ({:.0} ops/sec)",
        num_ops, duration, ops_per_sec
    );

    Ok(())
}

#[cfg(test)]
mod test_helpers {
    use super::*;

    /// Helper to measure query execution time.
    pub fn measure_query_time<F, R>(f: F) -> (R, std::time::Duration)
    where
        F: FnOnce() -> R,
    {
        let start = Instant::now();
        let result = f();
        let duration = start.elapsed();
        (result, duration)
    }
}
