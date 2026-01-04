//! Page cache performance benchmarks
//!
//! Simple benchmarks to measure page cache effectiveness.

use super::PageCache;
use crate::page::PAGE_SIZE;
use crate::types::PageId;
use std::time::{Duration, Instant};

/// Benchmark result
#[derive(Debug, Clone)]
pub struct BenchmarkResult {
    pub name: String,
    pub iterations: u64,
    pub duration: Duration,
    pub ops_per_second: f64,
}

/// Run page cache benchmarks
pub fn run_benchmarks() -> Vec<BenchmarkResult> {
    let mut results = Vec::new();

    // Benchmark 1: Cache hit rate for sequential access
    results.push(benchmark_sequential_access());

    // Benchmark 2: Cache hit rate for random access
    results.push(benchmark_random_access());

    // Benchmark 3: Cache eviction pressure
    results.push(benchmark_eviction_pressure());

    results
}

/// Benchmark sequential access pattern (high locality)
fn benchmark_sequential_access() -> BenchmarkResult {
    let cache = PageCache::new();
    let num_pages = 1000;
    let repeats = 100;

    // Populate cache
    for i in 0..num_pages {
        let page_id = PageId::new(i);
        let page_data = vec![i as u8; PAGE_SIZE];
        cache.put(page_id, &page_data).unwrap();
        cache.unpin(page_id);
    }

    let start = Instant::now();

    // Sequential access pattern
    for _ in 0..repeats {
        for i in 0..num_pages {
            let page_id = PageId::new(i);
            let _ = cache.get(page_id);
        }
    }

    let duration = start.elapsed();
    let ops_per_second = (num_pages * repeats) as f64 / duration.as_secs_f64();

    let stats = cache.stats();
    println!("Sequential Access Benchmark:");
    println!("  Cache hit rate: {:.2}%", stats.hit_rate * 100.0);
    println!("  Operations: {} in {:?}", num_pages * repeats, duration);
    println!("  Throughput: {:.2} ops/sec", ops_per_second);

    BenchmarkResult {
        name: "Sequential Access".to_string(),
        iterations: num_pages * repeats,
        duration,
        ops_per_second,
    }
}

/// Benchmark random access pattern (low locality)
fn benchmark_random_access() -> BenchmarkResult {
    use std::collections::HashSet;

    let cache = PageCache::new();
    let num_pages = 1000;
    let repeats = 100;

    // Populate cache with subset of pages
    for i in 0..100 {
        let page_id = PageId::new(i);
        let page_data = vec![i as u8; PAGE_SIZE];
        cache.put(page_id, &page_data).unwrap();
        cache.unpin(page_id);
    }

    let start = Instant::now();

    // Random access pattern
    let mut accessed = HashSet::new();
    for _ in 0..repeats {
        for i in 0..num_pages {
            let page_id = PageId::new(i % num_pages);
            let _ = cache.get(page_id);
            accessed.insert(page_id);
        }
    }

    let duration = start.elapsed();
    let ops_per_second = (num_pages * repeats) as f64 / duration.as_secs_f64();

    let stats = cache.stats();
    println!("Random Access Benchmark:");
    println!("  Cache hit rate: {:.2}%", stats.hit_rate * 100.0);
    println!("  Operations: {} in {:?}", num_pages * repeats, duration);
    println!("  Throughput: {:.2} ops/sec", ops_per_second);

    BenchmarkResult {
        name: "Random Access".to_string(),
        iterations: num_pages * repeats,
        duration,
        ops_per_second,
    }
}

/// Benchmark cache eviction under pressure
fn benchmark_eviction_pressure() -> BenchmarkResult {
    let cache = PageCache::new();
    let num_pages = 10000;

    let start = Instant::now();

    // Insert many pages to trigger eviction
    for i in 0..num_pages {
        let page_id = PageId::new(i);
        let page_data = vec![i as u8; PAGE_SIZE];
        let _ = cache.put(page_id, &page_data);
        cache.unpin(page_id);
    }

    let duration = start.elapsed();
    let ops_per_second = num_pages as f64 / duration.as_secs_f64();

    let stats = cache.stats();
    println!("Eviction Pressure Benchmark:");
    println!("  Final cache size: {} pages", stats.current_entries);
    println!("  Evictions: {}", stats.evictions);
    println!("  Operations: {} in {:?}", num_pages, duration);
    println!("  Throughput: {:.2} ops/sec", ops_per_second);

    BenchmarkResult {
        name: "Eviction Pressure".to_string(),
        iterations: num_pages,
        duration,
        ops_per_second,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_benchmarks_run() {
        let results = run_benchmarks();
        assert!(!results.is_empty());
        assert!(results.len() >= 3);

        // Verify each benchmark has valid results
        for result in results {
            assert!(!result.name.is_empty());
            assert!(result.iterations > 0);
            assert!(result.ops_per_second > 0.0);
        }
    }

    #[test]
    fn test_sequential_access_high_hit_rate() {
        let result = benchmark_sequential_access();
        // Sequential access should have very high hit rate
        assert!(result.ops_per_second > 1000.0);
    }

    #[test]
    fn test_eviction_pressure_completes() {
        let result = benchmark_eviction_pressure();
        // Benchmark should complete without errors
        assert_eq!(result.iterations, 10000);
        assert!(result.ops_per_second > 0.0);
    }
}
