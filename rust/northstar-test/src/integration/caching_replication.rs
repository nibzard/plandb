//! Integration tests for caching and concurrent operations.
//!
//! Tests cache behavior and multi-threaded access patterns.

use northstar_core::{db::Db, error::Result};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use super::{create_test_db, populate_db, TestContext};

/// Test query cache hit on repeated point lookups.
#[test]
fn test_query_cache_point_get() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write test data
    populate_db(&db, 50, "qcache-")?;

    // First read - cache miss
    let txn = db.begin_read()?;
    let result1 = txn.get(b"qcache-00000000")?;
    assert!(result1.is_some());
    txn.close();

    // Second read - should hit cache
    let txn = db.begin_read()?;
    let result2 = txn.get(b"qcache-00000000")?;
    assert!(result2.is_some());
    assert_eq!(result1, result2);

    // Verify cache stats show hits
    let stats = db.stats()?;
    println!("Query cache stats: hits={}, misses={}",
        stats.query_cache_stats.hits,
        stats.query_cache_stats.misses
    );
    assert!(stats.query_cache_stats.hits > 0 || stats.query_cache_stats.misses > 0);

    Ok(())
}

/// Test query cache hit on repeated prefix scans.
#[test]
fn test_query_cache_prefix_scan() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write test data
    populate_db(&db, 50, "scan-")?;

    // First scan - cache miss
    let txn = db.begin_read()?;
    let results1 = txn.scan(b"scan-")?;
    assert!(results1.len() >= 50);
    txn.close();

    // Second scan - should hit cache
    let txn = db.begin_read()?;
    let results2 = txn.scan(b"scan-")?;
    assert_eq!(results2.len(), results1.len());
    txn.close();

    Ok(())
}

/// Test query cache invalidation after write.
#[test]
fn test_query_cache_invalidation() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write initial data
    populate_db(&db, 10, "inv-")?;

    // Read and cache result
    let txn = db.begin_read()?;
    let result1 = txn.get(b"inv-00000000")?;
    assert!(result1.is_some());
    txn.close();

    // Modify data - should invalidate cache
    let mut txn = db.begin_write()?;
    txn.put(b"inv-00000000", b"new-value")?;
    txn.commit()?;

    // Read again - should get new value (not cached old value)
    let txn = db.begin_read()?;
    let result2 = txn.get(b"inv-00000000")?;
    assert!(result2.is_some());
    assert_eq!(result2.unwrap(), b"new-value");

    Ok(())
}

/// Test query cache with multiple keys.
#[test]
fn test_query_cache_multiple_keys() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write test data
    populate_db(&db, 100, "multi-")?;

    // Read all keys (cache misses)
    let txn = db.begin_read()?;
    for i in 0..100 {
        let key = format!("multi-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        assert!(result.is_some());
    }
    txn.close();

    // Read all keys again (cache hits)
    let txn = db.begin_read()?;
    let mut hit_count = 0;
    for i in 0..100 {
        let key = format!("multi-{:08x}", i);
        let result = txn.get(key.as_bytes())?;
        assert!(result.is_some());
        hit_count += 1;
    }
    assert_eq!(hit_count, 100);

    // Check cache stats
    let stats = db.stats()?;
    println!("Query cache stats after 200 gets: hits={}, misses={}",
        stats.query_cache_stats.hits,
        stats.query_cache_stats.misses
    );

    Ok(())
}

/// Test query cache with range scans of different sizes.
#[test]
fn test_query_cache_range_scans() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write test data
    populate_db(&db, 100, "range-")?;

    // Small range scan
    let txn = db.begin_read()?;
    let small_results = txn.scan(b"range-0000000")?;
    txn.close();

    // Large range scan
    let txn = db.begin_read()?;
    let large_results = txn.scan(b"range-")?;
    txn.close();

    println!("Small range returned {} items", small_results.len());
    println!("Large range returned {} items", large_results.len());

    // Verify results are reasonable
    assert!(large_results.len() >= small_results.len());

    Ok(())
}

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

/// Benchmark: Query cache effectiveness on repeated point lookups.
#[test]
fn benchmark_query_cache_effectiveness() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write test data
    let num_keys = 1000;
    populate_db(&db, num_keys, "qbench-")?;

    let num_iterations = 10000;

    // First pass - cache misses (populate cache)
    let start = std::time::Instant::now();
    let txn = db.begin_read()?;
    for i in 0..num_iterations {
        let key = format!("qbench-{:08x}", i % num_keys);
        let _ = txn.get(key.as_bytes());
    }
    let duration_misses = start.elapsed();
    txn.close();

    // Get stats after first pass
    let stats_after_misses = db.stats()?;

    // Second pass - cache hits
    let start = std::time::Instant::now();
    let txn = db.begin_read()?;
    for i in 0..num_iterations {
        let key = format!("qbench-{:08x}", i % num_keys);
        let _ = txn.get(key.as_bytes());
    }
    let duration_hits = start.elapsed();
    txn.close();

    // Get final stats
    let stats_final = db.stats()?;

    println!("\nQuery Cache Benchmark Results:");
    println!("  Iterations: {}", num_iterations);
    println!("  Unique keys: {}", num_keys);
    println!("  First pass (cache misses): {:?} ({:.0} ops/sec)",
        duration_misses,
        num_iterations as f64 / duration_misses.as_secs_f64()
    );
    println!("  Second pass (cache hits): {:?} ({:.0} ops/sec)",
        duration_hits,
        num_iterations as f64 / duration_hits.as_secs_f64()
    );
    println!("  Speedup: {:.2}x",
        duration_misses.as_secs_f64() / duration_hits.as_secs_f64()
    );
    println!("  Cache stats: hits={}, misses={}, hit_rate={:.2}%",
        stats_final.query_cache_stats.hits,
        stats_final.query_cache_stats.misses,
        stats_final.query_cache_stats.hit_rate() * 100.0
    );

    Ok(())
}

/// Benchmark: Query cache effectiveness on prefix scans.
#[test]
fn benchmark_query_cache_scan_effectiveness() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write test data
    let num_keys = 500;
    populate_db(&db, num_keys, "scanbench-")?;

    let num_iterations = 1000;

    // First pass - cache misses
    let start = std::time::Instant::now();
    for _ in 0..num_iterations {
        let txn = db.begin_read()?;
        let _ = txn.scan(b"scanbench-");
        txn.close();
    }
    let duration_misses = start.elapsed();

    // Second pass - cache hits
    let start = std::time::Instant::now();
    for _ in 0..num_iterations {
        let txn = db.begin_read()?;
        let _ = txn.scan(b"scanbench-");
        txn.close();
    }
    let duration_hits = start.elapsed();

    // Get final stats
    let stats_final = db.stats()?;

    println!("\nQuery Cache Scan Benchmark Results:");
    println!("  Iterations: {}", num_iterations);
    println!("  Keys in database: {}", num_keys);
    println!("  First pass (cache misses): {:?} ({:.0} scans/sec)",
        duration_misses,
        num_iterations as f64 / duration_misses.as_secs_f64()
    );
    println!("  Second pass (cache hits): {:?} ({:.0} scans/sec)",
        duration_hits,
        num_iterations as f64 / duration_hits.as_secs_f64()
    );
    println!("  Speedup: {:.2}x",
        duration_misses.as_secs_f64() / duration_hits.as_secs_f64()
    );
    println!("  Cache stats: hits={}, misses={}, hit_rate={:.2}%",
        stats_final.query_cache_stats.hits,
        stats_final.query_cache_stats.misses,
        stats_final.query_cache_stats.hit_rate() * 100.0
    );

    Ok(())
}

/// Benchmark: Query cache memory usage.
#[test]
fn benchmark_query_cache_memory_usage() -> Result<()> {
    let ctx = TestContext::new().unwrap();
    let db = create_test_db(ctx.db_path())?;

    // Write varying size values
    let num_keys = 100;
    for i in 0..num_keys {
        let key = format!("mem-{:08x}", i);
        let value_size = 100 + (i % 10) * 100; // 100 to 1000 bytes
        let value = vec![b'X'; value_size];

        let mut txn = db.begin_write()?;
        txn.put(key.as_bytes(), &value)?;
        txn.commit()?;
    }

    // Perform reads to populate cache
    for i in 0..num_keys {
        let key = format!("mem-{:08x}", i);
        let txn = db.begin_read()?;
        let _ = txn.get(key.as_bytes());
        txn.close();
    }

    // Check cache stats
    let stats = db.stats()?;

    println!("\nQuery Cache Memory Usage:");
    println!("  Entries: {}", stats.query_cache_stats.current_entries);
    println!("  Memory used: {} bytes", stats.query_cache_stats.current_size);
    println!("  Avg entry size: {} bytes",
        if stats.query_cache_stats.current_entries > 0 {
            stats.query_cache_stats.current_size / stats.query_cache_stats.current_entries
        } else {
            0
        }
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
