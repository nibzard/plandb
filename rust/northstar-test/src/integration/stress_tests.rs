//! Stress tests for high concurrency scenarios.
//!
//! Tests system stability and performance under extreme load.

use northstar_core::{db::Db, error::Result};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use super::{create_test_db, populate_db, TestContext};

/// Test high concurrent read workload.
#[test]
fn test_high_concurrent_reads() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 1000, "read-")?;

    let num_readers = 50;
    let reads_per_reader = 100;

    let handles: Vec<_> = (0..num_readers)
        .map(|_| {
            let db_clone = db.clone();
            thread::spawn(move || {
                let txn = db_clone.begin_read().unwrap();
                for i in 0..reads_per_reader {
                    let key = format!("read-{:08x}", i % 1000);
                    let _ = txn.get(key.as_bytes());
                }
                true
            })
        })
        .collect();

    for handle in handles {
        assert!(handle.join().unwrap());
    }

    Ok(())
}

/// Test concurrent read/write mix.
#[test]
fn test_concurrent_read_write_mix() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 500, "mix-")?;

    let success_count = Arc::new(Mutex::new(0));
    let mut handles = vec![];

    // Writer threads
    for w in 0..5 {
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
    for _ in 0..25 {
        let db_clone = db.clone();
        let success = Arc::clone(&success_count);
        handles.push(thread::spawn(move || {
            for i in 0..100 {
                let key = format!("mix-{:08x}", i % 500);
                if let Ok(txn) = db_clone.begin_read() {
                    if txn.get(key.as_bytes()).is_ok() {
                        *success.lock().unwrap() += 1;
                    }
                }
            }
        }));
    }

    for handle in handles {
        handle.join().unwrap();
    }

    let total = *success_count.lock().unwrap();
    println!("Concurrent R/W: {} successful operations", total);
    assert!(total > 0);

    Ok(())
}

/// Test memory pressure under load.
#[test]
fn test_memory_pressure() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write large values
    let large_value = vec![b'X'; 1024 * 1024]; // 1MB

    let mut txn = db.begin_write()?;
    for i in 0..50 {
        let key = format!("large-{:08x}", i);
        txn.put(key.as_bytes(), &large_value)?;
    }
    txn.commit()?;

    // Read concurrently
    let num_readers = 10;
    let handles: Vec<_> = (0..num_readers)
        .map(|_| {
            let db_clone = db.clone();
            thread::spawn(move || {
                let txn = db_clone.begin_read().unwrap();
                for i in 0..50 {
                    let key = format!("large-{:08x}", i);
                    let _ = txn.get(key.as_bytes());
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    Ok(())
}

/// Test rapid open/close cycles.
#[test]
fn test_rapid_open_close_cycles() -> Result<()> {
    for cycle in 0..10 {
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

/// Test long-running transaction stability.
#[test]
fn test_long_running_transaction() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    populate_db(&db, 100, "long-")?;

    // Start long-running read transaction
    let long_txn = db.begin_read()?;

    // Perform writes while transaction is open
    for _ in 0..10 {
        let mut write_txn = db.begin_write()?;
        for i in 0..10 {
            let key = format!("new-{:08x}", i);
            write_txn.put(key.as_bytes(), b"value")?;
        }
        write_txn.commit()?;
    }

    // Long-running transaction should still see consistent snapshot
    let value = long_txn.get(b"long-00000000")?;
    assert!(value.is_some());

    Ok(())
}

/// Benchmark: Throughput under increasing load.
#[test]
fn benchmark_throughput_scaling() -> Result<()> {
    let concurrency_levels = vec![1, 5, 10, 20];
    let ops_per_task = 50;

    println!("\nThroughput Scaling Benchmark:");
    println!("Concurrency | Ops/sec | Total Ops");
    println!("------------|---------|----------");

    for concurrency in concurrency_levels {
        let ctx = TestContext::new().unwrap();
        let db = create_test_db(ctx.db_path())?;
        populate_db(&db, 500, "scale-")?;

        let start = Instant::now();

        let handles: Vec<_> = (0..concurrency)
            .map(|_| {
                let db_clone = db.clone();
                thread::spawn(move || {
                    let txn = db_clone.begin_read().unwrap();
                    for i in 0..ops_per_task {
                        let key = format!("scale-{:08x}", i % 500);
                        let _ = txn.get(key.as_bytes());
                    }
                })
            })
            .collect();

        for handle in handles {
            handle.join().unwrap();
        }

        let duration = start.elapsed();
        let total_ops = concurrency * ops_per_task;
        let ops_per_sec = total_ops as f64 / duration.as_secs_f64();

        println!(
            "{:^11} | {:^7.0} | {:^9}",
            concurrency, ops_per_sec, total_ops
        );
    }

    Ok(())
}

#[cfg(test)]
mod test_helpers {
    use super::*;

    /// Helper to verify system stability after stress test.
    pub fn verify_stability(db: &Db) -> Result<bool> {
        // Try basic operations
        let txn = db.begin_read()?;
        let _ = txn.get(b"test");

        let mut write_txn = db.begin_write()?;
        write_txn.put(b"stability-test", b"ok")?;
        write_txn.commit()?;

        Ok(true)
    }
}
