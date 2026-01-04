//! NorthstarDB benchmark framework.
//!
//! Provides benchmark execution, metrics collection, and baseline comparison.

#![warn(missing_docs)]
#![warn(clippy::all)]

use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};
use serde::{Serialize, Deserialize};

// Re-exports
pub use northstar_core;

/// Benchmark result metrics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BenchmarkMetrics {
    /// Total operations performed.
    pub ops_total: u64,
    /// Total duration in nanoseconds.
    pub duration_ns: u64,
    /// Operations per second.
    pub ops_per_sec: f64,
    /// Latency percentiles (in nanoseconds).
    pub latency: LatencyMetrics,
    /// Bytes read/written.
    pub io: IoMetrics,
    /// Allocation statistics.
    pub alloc: AllocMetrics,
}

/// Latency metrics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LatencyMetrics {
    /// p50 latency (nanoseconds).
    pub p50: u64,
    /// p95 latency (nanoseconds).
    pub p95: u64,
    /// p99 latency (nanoseconds).
    pub p99: u64,
    /// Max latency (nanoseconds).
    pub max: u64,
}

/// I/O metrics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IoMetrics {
    /// Total bytes read.
    pub bytes_read: u64,
    /// Total bytes written.
    pub bytes_written: u64,
}

/// Allocation metrics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AllocMetrics {
    /// Number of allocations.
    pub alloc_count: u64,
    /// Total bytes allocated.
    pub alloc_bytes: u64,
}

/// Benchmark result for a single repeat.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BenchmarkResult {
    /// Benchmark name.
    pub name: String,
    /// Repeat index (0-based).
    pub repeat_index: usize,
    /// Metrics collected.
    pub metrics: BenchmarkMetrics,
}

/// Benchmark function signature.
pub type BenchmarkFn = fn() -> Result<BenchmarkMetrics, BenchmarkError>;

/// Registered benchmark.
pub struct Benchmark {
    /// Benchmark name.
    pub name: String,
    /// Benchmark function.
    pub func: BenchmarkFn,
}

/// Benchmark registry.
pub struct BenchmarkRegistry {
    /// Registered benchmarks.
    benchmarks: Vec<Benchmark>,
}

impl BenchmarkRegistry {
    /// Create a new benchmark registry.
    pub fn new() -> Self {
        Self {
            benchmarks: Vec::new(),
        }
    }

    /// Register a benchmark.
    pub fn register(&mut self, name: impl Into<String>, func: BenchmarkFn) {
        self.benchmarks.push(Benchmark {
            name: name.into(),
            func,
        });
    }

    /// Get all registered benchmarks.
    pub fn benchmarks(&self) -> &[Benchmark] {
        &self.benchmarks
    }

    /// Filter benchmarks by pattern.
    pub fn filter(&self, pattern: &str) -> Vec<&Benchmark> {
        self.benchmarks
            .iter()
            .filter(|b| b.name.contains(pattern))
            .collect()
    }
}

impl Default for BenchmarkRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// Benchmark runner configuration.
#[derive(Debug, Clone)]
pub struct RunnerConfig {
    /// Number of repeats.
    pub repeats: usize,
    /// Optional filter pattern.
    pub filter: Option<String>,
    /// Optional output directory.
    pub output_dir: Option<String>,
}

impl Default for RunnerConfig {
    fn default() -> Self {
        Self {
            repeats: 5,
            filter: None,
            output_dir: None,
        }
    }
}

/// Benchmark runner.
pub struct BenchmarkRunner {
    /// Registry of benchmarks.
    registry: BenchmarkRegistry,
    /// Configuration.
    config: RunnerConfig,
}

impl BenchmarkRunner {
    /// Create a new benchmark runner.
    pub fn new(registry: BenchmarkRegistry, config: RunnerConfig) -> Self {
        Self { registry, config }
    }

    /// Run all benchmarks.
    pub fn run(&self) -> Result<Vec<BenchmarkResult>, BenchmarkError> {
        let benchmarks = if let Some(filter) = &self.config.filter {
            self.registry.filter(filter)
        } else {
            self.registry.benchmarks().iter().collect()
        };

        let mut results = Vec::new();

        for bench in benchmarks {
            println!("\nRunning benchmark: {}", bench.name);

            for repeat in 0..self.config.repeats {
                print!("  Repeat {}/{}... ", repeat + 1, self.config.repeats);
                std::io::stdout().flush().ok();

                let start = Instant::now();
                let metrics = (bench.func)()?;
                let duration = start.elapsed();

                print!("DONE ({} ops, {:.2} ops/sec)\n",
                    metrics.ops_total,
                    metrics.ops_per_sec
                );

                results.push(BenchmarkResult {
                    name: bench.name.clone(),
                    repeat_index: repeat,
                    metrics,
                });
            }
        }

        Ok(results)
    }

    /// Write results to JSON file.
    pub fn write_results(&self, results: &[BenchmarkResult]) -> std::io::Result<()> {
        if let Some(output_dir) = &self.config.output_dir {
            let path = Path::new(output_dir);
            std::fs::create_dir_all(path)?;

            let json = serde_json::to_string_pretty(results)?;
            std::fs::write(path.join("results.json"), json)?;

            println!("\nResults written to: {}/results.json", output_dir);
        }

        Ok(())
    }
}

/// Benchmark error type.
#[derive(Debug)]
pub enum BenchmarkError {
    /// I/O error.
    Io(std::io::Error),
    /// Database error.
    Db(northstar_core::Error),
    /// Benchmark failed.
    BenchmarkFailed(String),
}

impl From<std::io::Error> for BenchmarkError {
    fn from(err: std::io::Error) -> Self {
        Self::Io(err)
    }
}

impl From<northstar_core::Error> for BenchmarkError {
    fn from(err: northstar_core::Error) -> Self {
        Self::Db(err)
    }
}

impl std::fmt::Display for BenchmarkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "I/O error: {}", e),
            Self::Db(e) => write!(f, "Database error: {}", e),
            Self::BenchmarkFailed(msg) => write!(f, "Benchmark failed: {}", msg),
        }
    }
}

impl std::error::Error for BenchmarkError {}

/// Timer helper for measuring operation latency.
pub struct Timer {
    start: Instant,
}

impl Timer {
    /// Start a new timer.
    pub fn start() -> Self {
        Self {
            start: Instant::now(),
        }
    }

    /// Get elapsed time in nanoseconds.
    pub fn elapsed_ns(&self) -> u64 {
        self.start.elapsed().as_nanos() as u64
    }
}

/// Helper to compute percentiles from sorted samples.
pub fn compute_percentiles(samples: &mut [u64]) -> LatencyMetrics {
    if samples.is_empty() {
        return LatencyMetrics {
            p50: 0,
            p95: 0,
            p99: 0,
            max: 0,
        };
    }

    samples.sort();

    let len = samples.len();
    let p50 = samples[len * 50 / 100];
    let p95 = samples[len * 95 / 100];
    let p99 = samples[len * 99 / 100];
    let max = *samples.last().unwrap_or(&0);

    LatencyMetrics { p50, p95, p99, max }
}

// Built-in benchmarks

/// Benchmark: Sequential insert into B+Tree.
pub fn bench_btree_sequential_insert() -> Result<BenchmarkMetrics, BenchmarkError> {
    use northstar_core::Db;
    use tempfile::TempDir;

    let num_ops = 1_000u64; // Reduced for faster testing

    let temp_dir = TempDir::new()?;
    let db_path = temp_dir.path().join("bench.db");

    let mut db = Db::open(&db_path)?;

    let mut latencies = Vec::with_capacity(num_ops as usize);
    let timer = Timer::start();

    for i in 0..num_ops {
        let key = format!("key-{:08x}", i);
        let value = vec![0u8; 100]; // 100-byte values

        let op_start = Timer::start();
        {
            let mut txn = db.begin_write()?;
            txn.put(key.as_bytes(), &value)?;
            txn.commit()?;
        }
        latencies.push(op_start.elapsed_ns());
    }

    let duration = timer.elapsed_ns();

    // Compute metrics
    let latency = compute_percentiles(&mut latencies);
    let ops_per_sec = (num_ops as f64 * 1_000_000_000.0) / (duration as f64);

    db.close()?;

    Ok(BenchmarkMetrics {
        ops_total: num_ops,
        duration_ns: duration,
        ops_per_sec,
        latency,
        io: IoMetrics {
            bytes_read: 0,
            bytes_written: num_ops * 100, // Approximate
        },
        alloc: AllocMetrics {
            alloc_count: 0,
            alloc_bytes: 0,
        },
    })
}

/// Benchmark: Point get from B+Tree.
pub fn bench_btree_point_get() -> Result<BenchmarkMetrics, BenchmarkError> {
    use northstar_core::Db;
    use tempfile::TempDir;

    let num_ops = 10_000u64; // Reduced for faster testing

    let temp_dir = TempDir::new()?;
    let db_path = temp_dir.path().join("bench.db");

    let mut db = Db::open(&db_path)?;

    // First, populate the database
    {
        let mut txn = db.begin_write()?;
        for i in 0..1_000 {
            let key = format!("key-{:08x}", i);
            let value = vec![0u8; 100];
            txn.put(key.as_bytes(), &value)?;
        }
        txn.commit()?;
    }

    let mut latencies = Vec::with_capacity(num_ops as usize);
    let timer = Timer::start();

    for i in 0..num_ops {
        let key_idx = i % 1_000;
        let key = format!("key-{:08x}", key_idx);

        let op_start = Timer::start();
        {
            let txn = db.begin_read()?;
            let _value = txn.get(key.as_bytes())?;
        }
        latencies.push(op_start.elapsed_ns());
    }

    let duration = timer.elapsed_ns();

    // Compute metrics
    let latency = compute_percentiles(&mut latencies);
    let ops_per_sec = (num_ops as f64 * 1_000_000_000.0) / (duration as f64);

    db.close()?;

    Ok(BenchmarkMetrics {
        ops_total: num_ops,
        duration_ns: duration,
        ops_per_sec,
        latency,
        io: IoMetrics {
            bytes_read: num_ops * 100,
            bytes_written: 0,
        },
        alloc: AllocMetrics {
            alloc_count: 0,
            alloc_bytes: 0,
        },
    })
}

/// Get the default benchmark registry with built-in benchmarks.
pub fn default_registry() -> BenchmarkRegistry {
    let mut registry = BenchmarkRegistry::new();

    registry.register("btree/sequential_insert", bench_btree_sequential_insert);
    registry.register("btree/point_get", bench_btree_point_get);

    registry
}

/// Run benchmarks with default configuration.
pub fn run_benchmarks(filter: Option<String>, repeats: usize, output_dir: Option<String>) -> Result<(), BenchmarkError> {
    let registry = default_registry();

    let config = RunnerConfig {
        repeats,
        filter,
        output_dir,
    };

    let runner = BenchmarkRunner::new(registry, config);
    let results = runner.run()?;
    runner.write_results(&results)?;

    println!("\n=== Summary ===");
    println!("Total results: {}", results.len());

    Ok(())
}
