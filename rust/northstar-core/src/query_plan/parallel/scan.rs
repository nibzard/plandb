//! Parallel Scan Operations
//!
//! This module implements parallel table and index scans with range partitioning
//! and dynamic scheduling for optimal load balancing.

use crate::query_plan::parallel::task::{PagePartition, ScanTask};

/// Configuration for parallel scan operations.
#[derive(Debug, Clone)]
pub struct ParallelScanConfig {
    /// Minimum number of rows to consider parallel scan
    pub min_rows_threshold: usize,
    /// Number of rows per batch
    pub batch_size: usize,
    /// Number of partitions per worker
    pub partitions_per_worker: usize,
    /// Enable dynamic scheduling
    pub enable_dynamic_scheduling: bool,
}

impl Default for ParallelScanConfig {
    fn default() -> Self {
        Self {
            min_rows_threshold: 10_000,
            batch_size: 1000,
            partitions_per_worker: 2,
            enable_dynamic_scheduling: true,
        }
    }
}

impl ParallelScanConfig {
    /// Creates a new parallel scan configuration.
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the minimum rows threshold.
    pub fn with_min_rows_threshold(mut self, threshold: usize) -> Self {
        self.min_rows_threshold = threshold;
        self
    }

    /// Sets the batch size.
    pub fn with_batch_size(mut self, size: usize) -> Self {
        self.batch_size = size;
        self
    }

    /// Sets the number of partitions per worker.
    pub fn with_partitions_per_worker(mut self, count: usize) -> Self {
        self.partitions_per_worker = count;
        self
    }

    /// Enables or disables dynamic scheduling.
    pub fn with_dynamic_scheduling(mut self, enabled: bool) -> Self {
        self.enable_dynamic_scheduling = enabled;
        self
    }
}

/// Parallel table scan operation with range partitioning.
///
/// The scan divides the table into page ranges and creates multiple
/// scan tasks that can be executed in parallel by worker threads.
#[derive(Debug, Clone)]
pub struct ParallelScan {
    /// Table identifier
    pub table_id: String,
    /// Total number of rows in the table
    pub table_rows: usize,
    /// Total number of pages in the table
    pub page_count: usize,
    /// Page ranges to scan
    pub partitions: Vec<PagePartition>,
    /// Scan configuration
    pub config: ParallelScanConfig,
}

impl ParallelScan {
    /// Creates a new parallel scan for the given table.
    pub fn new(
        table_id: impl Into<String>,
        table_rows: usize,
        page_count: usize,
        num_workers: usize,
    ) -> Self {
        let config = ParallelScanConfig::default();
        let partitions = Self::create_partitions(table_rows, page_count, num_workers, &config);

        Self {
            table_id: table_id.into(),
            table_rows,
            page_count,
            partitions,
            config,
        }
    }

    /// Creates a parallel scan with custom configuration.
    pub fn with_config(
        table_id: impl Into<String>,
        table_rows: usize,
        page_count: usize,
        num_workers: usize,
        config: ParallelScanConfig,
    ) -> Self {
        let partitions = Self::create_partitions(table_rows, page_count, num_workers, &config);

        Self {
            table_id: table_id.into(),
            table_rows,
            page_count,
            partitions,
            config,
        }
    }

    /// Creates page partitions for parallel scanning.
    fn create_partitions(
        table_rows: usize,
        page_count: usize,
        num_workers: usize,
        config: &ParallelScanConfig,
    ) -> Vec<PagePartition> {
        if table_rows < config.min_rows_threshold {
            // Don't partition small tables
            return vec![PagePartition::new(0, page_count as u64)];
        }

        // Create partitions based on workers and partitions_per_worker
        let num_partitions = num_workers * config.partitions_per_worker;
        let pages_per_partition = (page_count / num_partitions).max(1);

        let mut partitions = Vec::with_capacity(num_partitions);
        let mut current_page = 0;

        while current_page < page_count {
            let end_page = (current_page + pages_per_partition).min(page_count);
            partitions.push(PagePartition::new(current_page as u64, end_page as u64));
            current_page = end_page;
        }

        partitions
    }

    /// Returns the number of partitions.
    pub fn partition_count(&self) -> usize {
        self.partitions.len()
    }

    /// Returns true if the table is large enough for parallel scanning.
    pub fn should_parallelize(&self) -> bool {
        self.table_rows >= self.config.min_rows_threshold && self.partition_count() > 1
    }

    /// Creates scan tasks for all partitions.
    pub fn create_scan_tasks(&self) -> Vec<ScanTask> {
        self.partitions
            .iter()
            .enumerate()
            .map(|(index, partition)| {
                let estimated_rows = (self.table_rows / self.partition_count())
                    .max(1)
                    .min(partition.count() as usize * 100); // Rough estimate

                ScanTask::new(
                    index,
                    index,
                    *partition,
                    self.table_id.clone(),
                    estimated_rows,
                )
                .with_batch_size(self.config.batch_size)
            })
            .collect()
    }

    /// Splits a partition into smaller chunks for dynamic scheduling.
    pub fn split_partition(&self, partition: &PagePartition, num_chunks: usize) -> Vec<PagePartition> {
        if partition.is_empty() || num_chunks <= 1 {
            return vec![*partition];
        }

        let pages_per_chunk = partition.count() / num_chunks as u64;
        let mut chunks = Vec::with_capacity(num_chunks);
        let mut current = partition.start;

        while current < partition.end {
            let end = (current + pages_per_chunk).min(partition.end);
            chunks.push(PagePartition::new(current, end));
            current = end;
        }

        // Ensure we cover the entire range
        if let Some(last) = chunks.last_mut() {
            last.end = partition.end;
        }

        chunks
    }

    /// Returns an estimate of rows per partition.
    pub fn rows_per_partition(&self) -> usize {
        if self.partition_count() > 0 {
            self.table_rows / self.partition_count()
        } else {
            self.table_rows
        }
    }

    /// Returns an estimate of pages per partition.
    pub fn pages_per_partition(&self) -> f64 {
        if self.partition_count() > 0 {
            self.page_count as f64 / self.partition_count() as f64
        } else {
            self.page_count as f64
        }
    }

    /// Updates the scan configuration.
    pub fn with_scan_config(mut self, config: ParallelScanConfig) -> Self {
        self.partitions = Self::create_partitions(
            self.table_rows,
            self.page_count,
            self.partition_count(),
            &config,
        );
        self.config = config;
        self
    }

    /// Returns the estimated memory usage per worker.
    pub fn estimated_memory_per_worker(&self, row_size_bytes: usize) -> usize {
        let rows_per_worker = self.rows_per_partition();
        let batch_memory = self.config.batch_size * row_size_bytes;
        let total_memory = rows_per_worker * row_size_bytes;

        // Return the larger of batch memory or a fraction of total memory
        batch_memory.max(total_memory / self.partition_count())
    }

    /// Returns the estimated scan time in milliseconds.
    pub fn estimated_scan_time_ms(&self, pages_per_ms: f64) -> f64 {
        self.page_count as f64 / pages_per_ms
    }

    /// Returns the estimated parallel scan time in milliseconds.
    pub fn estimated_parallel_scan_time_ms(
        &self,
        pages_per_ms: f64,
        num_workers: usize,
    ) -> f64 {
        let sequential_time = self.estimated_scan_time_ms(pages_per_ms);
        // Apply Amdahl's law approximation
        let parallelizable = 0.85; // 85% of scan work is parallelizable
        let speedup = 1.0 / ((1.0 - parallelizable) + (parallelizable / num_workers as f64));
        sequential_time / speedup
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scan_config() {
        let config = ParallelScanConfig::default();
        assert_eq!(config.min_rows_threshold, 10_000);
        assert_eq!(config.batch_size, 1000);

        let config = config.with_min_rows_threshold(100_000);
        assert_eq!(config.min_rows_threshold, 100_000);
    }

    #[test]
    fn test_parallel_scan_creation() {
        let scan = ParallelScan::new("users", 100_000, 1000, 4);

        assert_eq!(scan.table_id, "users");
        assert_eq!(scan.table_rows, 100_000);
        assert_eq!(scan.page_count, 1000);
        assert!(scan.partition_count() > 1);
    }

    #[test]
    fn test_should_parallelize() {
        let small_scan = ParallelScan::new("small", 1000, 10, 4);
        assert!(!small_scan.should_parallelize());

        let large_scan = ParallelScan::new("large", 100_000, 1000, 4);
        assert!(large_scan.should_parallelize());
    }

    #[test]
    fn test_create_scan_tasks() {
        let scan = ParallelScan::new("users", 100_000, 1000, 4);
        let tasks = scan.create_scan_tasks();

        assert_eq!(tasks.len(), scan.partition_count());

        for task in &tasks {
            assert_eq!(task.table_id, "users");
            assert!(task.estimated_rows > 0);
        }
    }

    #[test]
    fn test_split_partition() {
        let scan = ParallelScan::new("users", 100_000, 1000, 4);
        let partition = PagePartition::new(0, 1000);

        let chunks = scan.split_partition(&partition, 4);
        assert_eq!(chunks.len(), 4);

        // Verify all chunks are non-overlapping and cover the full range
        let mut total_pages = 0;
        for (i, chunk) in chunks.iter().enumerate() {
            assert!(!chunk.is_empty());
            total_pages += chunk.count();

            if i > 0 {
                assert_eq!(chunk.start, chunks[i - 1].end);
            }
        }

        assert_eq!(total_pages, 1000);
    }

    #[test]
    fn test_rows_per_partition() {
        let scan = ParallelScan::new("users", 100_000, 1000, 4);
        let rows_per_partition = scan.rows_per_partition();

        assert!(rows_per_partition > 0);
        assert!(rows_per_partition <= 100_000);
    }

    #[test]
    fn test_pages_per_partition() {
        let scan = ParallelScan::new("users", 100_000, 1000, 4);
        let pages_per_partition = scan.pages_per_partition();

        assert!(pages_per_partition > 0.0);
        assert!(pages_per_partition <= 1000.0);
    }

    #[test]
    fn test_estimated_memory_per_worker() {
        let scan = ParallelScan::new("users", 100_000, 1000, 4);
        let memory = scan.estimated_memory_per_worker(100); // 100 bytes per row

        assert!(memory > 0);
    }

    #[test]
    fn test_estimated_scan_time() {
        let scan = ParallelScan::new("users", 100_000, 1000, 4);

        let sequential_time = scan.estimated_scan_time_ms(10.0);
        let parallel_time = scan.estimated_parallel_scan_time_ms(10.0, 4);

        assert!(sequential_time > 0.0);
        assert!(parallel_time < sequential_time); // Parallel should be faster
    }

    #[test]
    fn test_page_partition() {
        let partition = PagePartition::new(10, 20);

        assert_eq!(partition.start, 10);
        assert_eq!(partition.end, 20);
        assert_eq!(partition.count(), 10);
        assert!(!partition.is_empty());

        let (left, right) = partition.split();
        assert_eq!(left.start, 10);
        assert_eq!(left.end, 15);
        assert_eq!(right.start, 15);
        assert_eq!(right.end, 20);
    }

    #[test]
    fn test_partition_iteration() {
        let partition = PagePartition::new(10, 15);
        let pages: Vec<u64> = partition.iter().collect();

        assert_eq!(pages, vec![10, 11, 12, 13, 14]);
    }

    #[test]
    fn test_empty_partition() {
        let partition = PagePartition::new(10, 10);
        assert!(partition.is_empty());
        assert_eq!(partition.count(), 0);
    }

    #[test]
    fn test_with_scan_config() {
        let config = ParallelScanConfig::default().with_min_rows_threshold(50_000);
        let scan = ParallelScan::new("users", 100_000, 1000, 4);
        let scan = scan.with_scan_config(config.clone());

        assert_eq!(scan.config.min_rows_threshold, 50_000);
    }
}
