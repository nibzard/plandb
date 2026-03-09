//! Parallel Query Execution Module
//!
//! This module provides parallel query execution capabilities for NorthstarDB,
//! enabling concurrent execution of query plan sub-tasks across multiple CPU cores.
//!
//! # Features
//!
//! - **Parallel Scan**: Range-partitioned table scans with dynamic scheduling
//! - **Parallel Join**: Parallel hash join with build/probe phases
//! - **Parallel Aggregate**: Partial aggregates with parallel merge
//! - **Cost-based Decision**: Automatic parallelization based on query cost
//!
//! # Architecture
//!
//! ```text
//! Query Plan
//!     │
//!     ▼
//! Parallel Planner (identifies parallelizable ops)
//!     │
//!     ├─► Parallel Scan (table/index partitioned)
//!     ├─► Parallel Join (partitioned hash join)
//!     ├─► Parallel Aggregate (partial aggregates + merge)
//!     └─► Result Collector (concurrent aggregation)
//!     │
//!     ▼
//! Work Scheduler (Rayon-based work-stealing)
//!     │
//!     ├─► Thread Pool (num_workers = num_cores)
//!     ├─► Task Queue (work-stealing deque)
//!     └─► Result Collector (concurrent aggregation)
//!     │
//!     ▼
//! Coordinator (merge partial results)
//! ```
//!
//! # Example
//!
//! ```no_run
//! use northstar::query_plan::parallel::{ParallelExecutor, ParallelConfig};
//!
//! let executor = ParallelExecutor::new(ParallelConfig::default());
//! let result = executor.execute_parallel(plan).await?;
//! ```

mod context;
mod executor;
mod metrics;
mod optimizer;
mod scan;
mod scheduler;
mod task;

pub use context::{ParallelContext, ThreadLocalState};
pub use executor::{ParallelExecutor, ParallelExecutorConfig};
pub use metrics::{
    ParallelExecutionMetrics, TaskMetrics, WorkStealingMetrics,
};
pub use optimizer::{
    ParallelizationDecision, ParallelOptimizer, ParallelStrategy,
};
pub use scan::{
    ParallelScan, ParallelScanConfig,
};
pub use scheduler::{WorkScheduler, WorkSchedulerConfig};
pub use task::{
    AggregateTask, JoinTask, JoinType, JoinStrategy, PagePartition, ParallelTask, ScanTask, SortTask,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_module_exists() {
        // Basic smoke test to ensure module compiles
        let config = ParallelExecutorConfig::default();
        assert_eq!(config.num_workers, 0); // 0 means auto-detect
    }

    #[test]
    fn test_parallel_optimizer() {
        let optimizer = ParallelOptimizer::default();
        let decision = optimizer.should_parallelize(
            1_000_000, // rows
            10.0,      // estimated_cost
        );

        // Should recommend parallelization for large tables
        assert!(decision.should_parallelize);
        assert!(decision.num_workers > 1);
    }

    #[test]
    fn test_parallel_scan_config() {
        let config = ParallelScanConfig::default();
        assert!(config.min_rows_threshold > 0);
        assert!(config.batch_size > 0);
    }
}
