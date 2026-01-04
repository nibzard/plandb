//! Comprehensive cache performance benchmarks
//!
//! Measures cache hit rate improvement, L1/L2 cache performance,
//! and prefetch effectiveness under various access patterns.

use northstar_core::cache::{
    Cache, CacheConfig, CachePolicy, PageCache, PrefetchManager, PrefetchPriority,
    SequentialScanDetector,
};
use northstar_core::page::PAGE_SIZE;
use northstar_core::types::PageId;
use std::time::{Duration, Instant};

/// Benchmark configuration
const NUM_PAGES: usize = 10000;
const NUM_OPERATIONS: usize = 100000;
const WARMUP_OPS: usize = 1000;

/// Main benchmark runner
fn main() {
    println!("=== NorthstarDB Cache Performance Benchmarks ===\n");

    // L1 Page Cache Benchmarks
    println!("--- L1 Page Cache Benchmarks ---");
    bench_page_cache_sequential();
    bench_page_cache_random();
    bench_page_cache_mixed();
    bench_page_cache_eviction_policies();
    bench_page_cache_concurrent_access();

    // Prefetch Benchmarks
    println!("\n--- Prefetch Effectiveness Benchmarks ---");
    bench_prefetch_sequential_scan();
    bench_prefetch_index_traversal();
    bench_sequential_scan_detector();

    // Cache Comparison
    println!("\n--- Cache Comparison Benchmarks ---");
    bench_cached_vs_uncached();
    bench_hit_rate_improvement();

    println!("\n=== All Benchmarks Complete ===");
}

/// Benchmark sequential access pattern (high locality)
fn bench_page_cache_sequential() {
    println!("Sequential Access Pattern:");
    println!("  Populating cache with {} pages...", NUM_PAGES);

    let cache = PageCache::new();

    // Populate cache
    for i in 0..NUM_PAGES {
        let page_id = PageId::new(i as u64);
        let page_data = vec![i as u8; PAGE_SIZE];
        cache.put(page_id, &page_data).unwrap();
        cache.unpin(page_id);
    }

    // Warmup
    for i in 0..WARMUP_OPS {
        let page_id = PageId::new((i % NUM_PAGES) as u64);
        let _ = cache.get(page_id);
    }

    // Benchmark sequential access
    let start = Instant::now();
    let mut ops = 0;

    for _ in 0..10 {
        for i in 0..NUM_PAGES {
            let page_id = PageId::new(i as u64);
            if cache.get(page_id).is_some() {
                ops += 1;
            }
        }
    }

    let duration = start.elapsed();
    let stats = cache.stats();

    println!("  Operations: {}", ops);
    println!("  Duration: {:?}", duration);
    println!("  Throughput: {:.2} ops/sec", ops as f64 / duration.as_secs_f64());
    println!("  Hit rate: {:.2}%", stats.hit_rate * 100.0);
    println!("  Hits: {}", stats.hits);
    println!("  Misses: {}", stats.misses);
    println!();
}

/// Benchmark random access pattern (low locality)
fn bench_page_cache_random() {
    use std::collections::HashSet;

    println!("Random Access Pattern:");

    let cache = PageCache::new();

    // Populate cache with subset of pages
    let cache_size = NUM_PAGES / 10;
    for i in 0..cache_size {
        let page_id = PageId::new(i as u64);
        let page_data = vec![i as u8; PAGE_SIZE];
        cache.put(page_id, &page_data).unwrap();
        cache.unpin(page_id);
    }

    // Warmup
    for i in 0..WARMUP_OPS {
        let page_id = PageId::new((i % cache_size) as u64);
        let _ = cache.get(page_id);
    }

    // Benchmark random access
    let start = Instant::now();
    let mut ops = 0;
    let mut accessed = HashSet::new();

    for i in 0..NUM_OPERATIONS {
        let page_id = PageId::new((i % NUM_PAGES) as u64);
        if cache.get(page_id).is_some() {
            ops += 1;
            accessed.insert(page_id);
        }
    }

    let duration = start.elapsed();
    let stats = cache.stats();

    println!("  Operations: {}", NUM_OPERATIONS);
    println!("  Duration: {:?}", duration);
    println!("  Throughput: {:.2} ops/sec", NUM_OPERATIONS as f64 / duration.as_secs_f64());
    println!("  Hit rate: {:.2}%", stats.hit_rate * 100.0);
    println!("  Hits: {}", stats.hits);
    println!("  Misses: {}", stats.misses);
    println!("  Unique pages accessed: {}", accessed.len());
    println!();
}

/// Benchmark mixed access pattern (zipfian distribution)
fn bench_page_cache_mixed() {
    println!("Mixed Access Pattern (80/20 Rule):");

    let cache = PageCache::new();

    // Populate cache with working set
    let working_set = NUM_PAGES / 5;
    for i in 0..working_set {
        let page_id = PageId::new(i as u64);
        let page_data = vec![i as u8; PAGE_SIZE];
        cache.put(page_id, &page_data).unwrap();
        cache.unpin(page_id);
    }

    // Warmup
    for i in 0..WARMUP_OPS {
        let page_id = PageId::new((i % working_set) as u64);
        let _ = cache.get(page_id);
    }

    // Benchmark with 80/20 distribution (80% of accesses to 20% of pages)
    let start = Instant::now();
    let mut ops = 0;

    for i in 0..NUM_OPERATIONS {
        // 80% of accesses to working set
        let page_id = if i % 10 < 8 {
            PageId::new((i % working_set) as u64)
        } else {
            PageId::new(((i % NUM_PAGES) + working_set) as u64)
        };

        if cache.get(page_id).is_some() {
            ops += 1;
        }
    }

    let duration = start.elapsed();
    let stats = cache.stats();

    println!("  Operations: {}", NUM_OPERATIONS);
    println!("  Duration: {:?}", duration);
    println!("  Throughput: {:.2} ops/sec", NUM_OPERATIONS as f64 / duration.as_secs_f64());
    println!("  Hit rate: {:.2}%", stats.hit_rate * 100.0);
    println!("  Hits: {}", stats.hits);
    println!("  Misses: {}", stats.misses);
    println!();
}

/// Benchmark different eviction policies
fn bench_page_cache_eviction_policies() {
    println!("Eviction Policy Comparison:");

    let policies = vec![
        ("LRU", CachePolicy::Lru),
        ("LFU", CachePolicy::Lfu),
        ("ARC", CachePolicy::Arc),
        ("FIFO", CachePolicy::Fifo),
    ];

    for (name, policy) in policies {
        let config = CacheConfig {
            max_entries: 1000,
            policy,
            ..Default::default()
        };

        let cache: Cache<PageId, Vec<u8>> = Cache::with_config(config);

        // Insert more pages than cache capacity
        for i in 0..2000 {
            let page_id = PageId::new(i);
            let page_data = vec![i as u8; 1024];
            cache.put(page_id, page_data, 1024).unwrap();
        }

        // Access pattern that favors first 500 pages
        let start = Instant::now();
        for i in 0..NUM_OPERATIONS {
            let page_id = PageId::new((i % 500) as u64);
            let _ = cache.get(&page_id);
        }
        let duration = start.elapsed();

        let stats = cache.stats();

        println!("  {}:", name);
        println!("    Hit rate: {:.2}%", stats.hit_rate * 100.0);
        println!("    Throughput: {:.2} ops/sec", NUM_OPERATIONS as f64 / duration.as_secs_f64());
        println!("    Evictions: {}", stats.evictions);
    }

    println!();
}

/// Benchmark concurrent access
fn bench_page_cache_concurrent_access() {
    use std::sync::Arc;
    use std::thread;

    println!("Concurrent Access Benchmark:");

    let cache = Arc::new(PageCache::new());
    let num_threads = 8;
    let ops_per_thread = NUM_OPERATIONS / num_threads;

    // Populate cache
    for i in 0..NUM_PAGES {
        let page_id = PageId::new(i as u64);
        let page_data = vec![i as u8; PAGE_SIZE];
        cache.put(page_id, &page_data).unwrap();
        cache.unpin(page_id);
    }

    // Spawn threads
    let start = Instant::now();
    let mut handles = vec![];

    for t in 0..num_threads {
        let cache = Arc::clone(&cache);
        let handle = thread::spawn(move || {
            let mut _ops = 0;
            for i in 0..ops_per_thread {
                let page_id = PageId::new(((i + t * 1000) % NUM_PAGES) as u64);
                if cache.get(page_id).is_some() {
                    _ops += 1;
                }
            }
            _ops
        });
        handles.push(handle);
    }

    let total_ops: usize = handles.into_iter().map(|h| h.join().unwrap()).sum();
    let duration = start.elapsed();
    let stats = cache.stats();

    println!("  Threads: {}", num_threads);
    println!("  Operations: {}", total_ops);
    println!("  Duration: {:?}", duration);
    println!("  Throughput: {:.2} ops/sec", total_ops as f64 / duration.as_secs_f64());
    println!("  Hit rate: {:.2}%", stats.hit_rate * 100.0);
    println!();
}

/// Benchmark prefetch effectiveness for sequential scans
fn bench_prefetch_sequential_scan() {
    println!("Prefetch Sequential Scan Effectiveness:");

    let cache = PageCache::new();
    let prefetch_mgr = PrefetchManager::new();

    // Populate cache
    for i in 0..100 {
        let page_id = PageId::new(i);
        let page_data = vec![i as u8; PAGE_SIZE];
        cache.put(page_id, &page_data).unwrap();
        cache.unpin(page_id);
    }

    // Simulate sequential scan with prefetch
    let start = Instant::now();

    for i in 0..100 {
        let page_id = PageId::new(i);

        // Submit prefetch request for next page
        if i < 99 {
            let next_page = PageId::new(i + 1);
            prefetch_mgr.prefetch_page(next_page, PrefetchPriority::Normal);
        }

        // Access current page
        let _ = cache.get(page_id);
    }

    let duration = start.elapsed();

    println!("  Pages scanned: 100");
    println!("  Duration: {:?}", duration);
    println!("  Avg latency per page: {:?}", duration / 100);
    println!();
}

/// Benchmark prefetch for index traversal
fn bench_prefetch_index_traversal() {
    println!("Prefetch Index Traversal Effectiveness:");

    let cache = PageCache::new();
    let prefetch_mgr = PrefetchManager::new();

    // Simulate B+Tree index traversal
    // Root page at 0, children at 1-10, leaves at 100-200
    let root = PageId::new(0);
    let children: Vec<PageId> = (1..=10).map(PageId::new).collect();
    let leaves: Vec<PageId> = (100..=200).map(PageId::new).collect();

    // Populate all pages
    for page_id in children.iter().chain(leaves.iter()).chain(std::iter::once(&root)) {
        let page_data = vec![page_id.as_u64() as u8; PAGE_SIZE];
        cache.put(*page_id, &page_data).unwrap();
        cache.unpin(*page_id);
    }

    let start = Instant::now();

    // Simulate index lookups with prefetch
    for _ in 0..100 {
        // Access root
        let _ = cache.get(root);

        // Prefetch and access child
        let child = children[0];
        prefetch_mgr.prefetch_page(child, PrefetchPriority::High);
        let _ = cache.get(child);

        // Prefetch and access leaf
        let leaf = leaves[0];
        prefetch_mgr.prefetch_page(leaf, PrefetchPriority::High);
        let _ = cache.get(leaf);
    }

    let duration = start.elapsed();

    println!("  Index lookups: 100");
    println!("  Duration: {:?}", duration);
    println!("  Avg latency per lookup: {:?}", duration / 100);
    println!();
}

/// Benchmark sequential scan detector
fn bench_sequential_scan_detector() {
    println!("Sequential Scan Detector:");

    let mut detector = SequentialScanDetector::new();

    // Non-sequential access
    let detected = detector.record_access(PageId::new(10));
    assert!(!detected, "Should not detect after single access");

    let detected = detector.record_access(PageId::new(5));
    assert!(!detected, "Should not detect after non-sequential access");

    // Sequential access
    detector.reset();
    for i in 1..=10 {
        let detected = detector.record_access(PageId::new(i));
        if i >= 4 {
            assert!(detected, "Should detect sequential scan after threshold");
        }
    }

    // Reset after non-sequential
    let detected = detector.record_access(PageId::new(100));
    assert!(!detected, "Should reset after non-sequential access");

    println!("  Sequential scan detection: PASS");
    println!("  Threshold behavior: PASS");
    println!("  Reset behavior: PASS");
    println!();
}

/// Benchmark cached vs uncached performance
fn bench_cached_vs_uncached() {
    println!("Cached vs Uncached Performance:");

    // Cached version
    let cache = PageCache::new();
    for i in 0..100 {
        let page_id = PageId::new(i);
        let page_data = vec![i as u8; PAGE_SIZE];
        cache.put(page_id, &page_data).unwrap();
        cache.unpin(page_id);
    }

    let start = Instant::now();
    for _ in 0..10000 {
        let page_id = PageId::new((rand::random::<usize>() % 100) as u64);
        let _ = cache.get(page_id);
    }
    let cached_duration = start.elapsed();

    // Uncached version (simulate disk read)
    let uncached_time = Duration::from_micros(100); // Assume 100us per disk read

    println!("  Cached throughput: {:.2} ops/sec", 10000.0 / cached_duration.as_secs_f64());
    println!("  Uncached throughput: {:.2} ops/sec", 1.0 / uncached_time.as_secs_f64());
    println!(
        "  Speedup: {:.2}x",
        uncached_time.as_secs_f64() / cached_duration.as_secs_f64() / 10000.0
    );
    println!();
}

/// Benchmark hit rate improvement
fn bench_hit_rate_improvement() {
    println!("Cache Hit Rate Improvement:");

    let cache_sizes = vec![100usize, 500, 1000, 5000];

    println!("  Cache Size | Hit Rate | Evictions");
    println!("  -----------|----------|-----------");

    for size in cache_sizes {
        let config = CacheConfig {
            max_entries: size,
            ..Default::default()
        };
        let cache: Cache<PageId, Vec<u8>> = Cache::with_config(config);

        // Insert 10x cache capacity
        for i in 0..(size * 10) as u64 {
            let page_id = PageId::new(i);
            let page_data = vec![i as u8; 1024];
            cache.put(page_id, page_data, 1024).unwrap();
        }

        // Access first 20% of pages repeatedly
        for _ in 0..1000 {
            for i in 0..(size * 2) as u64 {
                let page_id = PageId::new(i);
                let _ = cache.get(&page_id);
            }
        }

        let stats = cache.stats();
        println!(
            "  {:10} | {:7.2}% | {}",
            size,
            stats.hit_rate * 100.0,
            stats.evictions
        );
    }

    println!();
}
