//! Parallel Query Executor
//!
//! This module implements the main parallel query executor that coordinates
//! work distribution across Rayon thread pools.

use rayon::prelude::*;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::query_plan::parallel::context::ParallelContext;
use crate::query_plan::parallel::metrics::{
    ParallelExecutionMetrics, TaskTimer,
};
use crate::query_plan::parallel::scheduler::{ScheduleError, WorkScheduler, WorkSchedulerConfig};
use crate::query_plan::parallel::task::ParallelTask;
use crate::query_plan::types::QueryPlan;

/// Configuration for the parallel executor.
#[derive(Debug, Clone)]
pub struct ParallelExecutorConfig {
    /// Number of worker threads (0 = auto-detect based on CPU cores)
    pub num_workers: usize,
    /// Enable work-stealing between threads
    pub enable_work_stealing: bool,
    /// Minimum number of rows to consider parallelization
    pub min_rows_threshold: usize,
    /// Maximum number of parallel tasks
    pub max_parallel_tasks: usize,
    /// Enable metrics collection
    pub enable_metrics: bool,
}

impl Default for ParallelExecutorConfig {
    fn default() -> Self {
        Self {
            num_workers: 0, // Auto-detect
            enable_work_stealing: true,
            min_rows_threshold: 10_000,
            max_parallel_tasks: 1000,
            enable_metrics: true,
        }
    }
}

impl ParallelExecutorConfig {
    /// Creates a new executor configuration.
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the number of worker threads.
    pub fn with_num_workers(mut self, num_workers: usize) -> Self {
        self.num_workers = num_workers;
        self
    }

    /// Enables or disables work-stealing.
    pub fn with_work_stealing(mut self, enabled: bool) -> Self {
        self.enable_work_stealing = enabled;
        self
    }

    /// Sets the minimum rows threshold for parallelization.
    pub fn with_min_rows_threshold(mut self, threshold: usize) -> Self {
        self.min_rows_threshold = threshold;
        self
    }

    /// Sets the maximum number of parallel tasks.
    pub fn with_max_parallel_tasks(mut self, max: usize) -> Self {
        self.max_parallel_tasks = max;
        self
    }

    /// Enables or disables metrics collection.
    pub fn with_metrics(mut self, enabled: bool) -> Self {
        self.enable_metrics = enabled;
        self
    }

    /// Returns the effective number of workers.
    pub fn effective_workers(&self) -> usize {
        if self.num_workers == 0 {
            num_cpus::get()
        } else {
            self.num_workers
        }
    }
}

/// Parallel query executor using Rayon for work-stealing parallelism.
///
/// The executor coordinates parallel execution of query plans across
/// multiple CPU cores, handling task distribution, result collection,
/// and metrics tracking.
pub struct ParallelExecutor {
    /// Rayon thread pool for parallel execution
    thread_pool: Arc<rayon::ThreadPool>,
    /// Work scheduler for task distribution
    scheduler: WorkScheduler,
    /// Executor configuration
    config: ParallelExecutorConfig,
}

impl ParallelExecutor {
    /// Creates a new parallel executor with default configuration.
    pub fn new() -> Result<Self, ExecutorError> {
        Self::with_config(ParallelExecutorConfig::default())
    }

    /// Creates a new parallel executor with the given configuration.
    pub fn with_config(config: ParallelExecutorConfig) -> Result<Self, ExecutorError> {
        let num_workers = config.effective_workers();

        // Create Rayon thread pool
        let thread_pool = rayon::ThreadPoolBuilder::new()
            .num_threads(num_workers)
            .thread_name(|index| format!("northstar-worker-{}", index))
            .build()
            .map_err(|e| ExecutorError::ThreadPoolError(e.to_string()))?;

        // Create work scheduler
        let scheduler_config = WorkSchedulerConfig {
            num_workers,
            enable_work_stealing: config.enable_work_stealing,
            max_queue_size: config.max_parallel_tasks,
            task_timeout: Duration::from_secs(30),
        };
        let scheduler = WorkScheduler::with_config(scheduler_config);

        Ok(Self {
            thread_pool: Arc::new(thread_pool),
            scheduler,
            config,
        })
    }

    /// Returns the number of worker threads.
    pub fn num_workers(&self) -> usize {
        self.scheduler.num_workers()
    }

    /// Returns true if work-stealing is enabled.
    pub fn work_stealing_enabled(&self) -> bool {
        self.scheduler.work_stealing_enabled()
    }

    /// Returns a reference to the scheduler.
    pub fn scheduler(&self) -> &WorkScheduler {
        &self.scheduler
    }

    /// Executes a query plan in parallel.
    ///
    /// This method analyzes the query plan, identifies parallelizable
    /// operations, and executes them using the Rayon thread pool.
    pub fn execute(&self, plan: &QueryPlan) -> Result<ExecutionResult, ExecutorError> {
        let start = Instant::now();

        // Analyze the plan to determine if parallelization is beneficial
        let num_workers = self.num_workers();
        let (tasks, metrics_enabled) = self.plan_to_tasks(plan)?;

        if tasks.is_empty() {
            // No parallelizable operations, return empty result
            return Ok(ExecutionResult {
                rows_affected: 0,
                execution_time: start.elapsed(),
                metrics: None,
                parallelism_used: 1,
            });
        }

        // Schedule all tasks
        for task in &tasks {
            self.scheduler
                .schedule(task.clone())
                .map_err(ExecutorError::ScheduleError)?;
        }

        // Execute tasks in parallel
        let result = self.execute_parallel_tasks(tasks, metrics_enabled);

        let execution_time = start.elapsed();

        Ok(ExecutionResult {
            rows_affected: result.rows_affected,
            execution_time,
            metrics: result.metrics,
            parallelism_used: num_workers,
        })
    }

    /// Converts a query plan into parallel tasks.
    fn plan_to_tasks(
        &self,
        _plan: &QueryPlan,
    ) -> Result<(Vec<ParallelTask>, bool), ExecutorError> {
        // For now, return empty task list
        // This will be implemented when we integrate with actual query plans
        Ok((vec![], self.config.enable_metrics))
    }

    /// Executes a list of tasks in parallel using Rayon.
    fn execute_parallel_tasks(
        &self,
        tasks: Vec<ParallelTask>,
        collect_metrics: bool,
    ) -> PartialResult {
        let total_tasks = tasks.len();
        let scheduler = self.scheduler.clone();

        // Use Rayon to execute tasks in parallel
        let results: Vec<_> = self
            .thread_pool
            .install(|| {
                tasks
                    .into_par_iter()
                    .map(|task| {
                        let _timer = if collect_metrics {
                            Some(TaskTimer::new())
                        } else {
                            None
                        };

                        // Execute the task
                        let result = self.execute_task(task, &scheduler);

                        // Record completion
                        if result.is_ok() {
                            scheduler.record_completed();
                        } else {
                            scheduler.record_failed();
                        }

                        result
                    })
                    .collect()
            });

        // Collect results
        let mut rows_affected = 0;
        let mut metrics = None;

        if collect_metrics {
            let mut execution_metrics = ParallelExecutionMetrics::new();
            execution_metrics.num_workers = self.num_workers();
            execution_metrics.total_tasks = total_tasks;
            execution_metrics.completed_tasks = scheduler.completed_count();
            execution_metrics.failed_tasks = scheduler.failed_count();

            metrics = Some(execution_metrics);
        }

        for result in results {
            if let Ok(rows) = result {
                rows_affected += rows;
            }
        }

        PartialResult {
            rows_affected,
            metrics,
        }
    }

    /// Executes a single parallel task.
    fn execute_task(
        &self,
        task: ParallelTask,
        _scheduler: &WorkScheduler,
    ) -> Result<usize, ExecutorError> {
        match task {
            ParallelTask::Scan(scan_task) => self.execute_scan(scan_task),
            ParallelTask::Join(join_task) => self.execute_join(join_task),
            ParallelTask::Aggregate(agg_task) => self.execute_aggregate(agg_task),
            ParallelTask::Sort(sort_task) => self.execute_sort(sort_task),
        }
    }

    /// Executes a scan task.
    fn execute_scan(&self, _task: super::task::ScanTask) -> Result<usize, ExecutorError> {
        // Placeholder: In real implementation, this would scan the actual data
        // For now, return estimated rows
        Ok(100) // Placeholder
    }

    /// Executes a join task.
    fn execute_join(&self, _task: super::task::JoinTask) -> Result<usize, ExecutorError> {
        // Placeholder: In real implementation, this would perform the join
        Ok(50) // Placeholder
    }

    /// Executes an aggregate task.
    fn execute_aggregate(
        &self,
        _task: super::task::AggregateTask,
    ) -> Result<usize, ExecutorError> {
        // Placeholder: In real implementation, this would compute aggregates
        Ok(10) // Placeholder
    }

    /// Executes a sort task.
    fn execute_sort(&self, _task: super::task::SortTask) -> Result<usize, ExecutorError> {
        // Placeholder: In real implementation, this would perform sorting
        Ok(100) // Placeholder
    }

    /// Resets the executor state.
    pub fn reset(&self) {
        self.scheduler.reset();
    }

    /// Returns the current executor statistics.
    pub fn stats(&self) -> ExecutorStats {
        ExecutorStats {
            num_workers: self.num_workers(),
            work_stealing_enabled: self.work_stealing_enabled(),
            queue_size: self.scheduler.queue_size(),
            completed_tasks: self.scheduler.completed_count(),
            failed_tasks: self.scheduler.failed_count(),
            total_processed: self.scheduler.total_processed(),
        }
    }
}

impl Default for ParallelExecutor {
    fn default() -> Self {
        Self::new().unwrap()
    }
}

/// Result of parallel query execution.
#[derive(Debug)]
pub struct ExecutionResult {
    /// Number of rows affected by the query
    pub rows_affected: usize,
    /// Total execution time
    pub execution_time: Duration,
    /// Execution metrics (if enabled)
    pub metrics: Option<ParallelExecutionMetrics>,
    /// Degree of parallelism used
    pub parallelism_used: usize,
}

/// Partial result for internal use.
struct PartialResult {
    rows_affected: usize,
    metrics: Option<ParallelExecutionMetrics>,
}

/// Executor statistics.
#[derive(Debug, Clone)]
pub struct ExecutorStats {
    pub num_workers: usize,
    pub work_stealing_enabled: bool,
    pub queue_size: usize,
    pub completed_tasks: usize,
    pub failed_tasks: usize,
    pub total_processed: usize,
}

/// Errors that can occur during parallel execution.
#[derive(Debug, Clone)]
pub enum ExecutorError {
    /// Thread pool creation error
    ThreadPoolError(String),
    /// Task scheduling error
    ScheduleError(ScheduleError),
    /// Task execution error
    TaskError(String),
    /// Query too small for parallelization
    QueryTooSmall,
    /// Resource exhaustion
    ResourceExhausted,
}

impl std::fmt::Display for ExecutorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExecutorError::ThreadPoolError(msg) => write!(f, "Thread pool error: {}", msg),
            ExecutorError::ScheduleError(err) => write!(f, "Schedule error: {}", err),
            ExecutorError::TaskError(msg) => write!(f, "Task error: {}", msg),
            ExecutorError::QueryTooSmall => write!(f, "Query too small for parallelization"),
            ExecutorError::ResourceExhausted => write!(f, "Resources exhausted"),
        }
    }
}

impl std::error::Error for ExecutorError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_executor_config() {
        let config = ParallelExecutorConfig::default();
        assert_eq!(config.num_workers, 0);
        assert!(config.enable_work_stealing);
        assert_eq!(config.min_rows_threshold, 10_000);

        let config = config.with_num_workers(4);
        assert_eq!(config.num_workers, 4);
        assert_eq!(config.effective_workers(), 4);
    }

    #[test]
    fn test_executor_creation() {
        let executor = ParallelExecutor::new();
        assert!(executor.is_ok());

        let executor = executor.unwrap();
        assert!(executor.num_workers() > 0);
        assert!(executor.work_stealing_enabled());
    }

    #[test]
    fn test_executor_with_config() {
        let config = ParallelExecutorConfig::default().with_num_workers(2);
        let executor = ParallelExecutor::with_config(config);
        assert!(executor.is_ok());

        let executor = executor.unwrap();
        assert_eq!(executor.num_workers(), 2);
    }

    #[test]
    fn test_executor_stats() {
        let executor = ParallelExecutor::new().unwrap();
        let stats = executor.stats();

        assert_eq!(stats.num_workers, executor.num_workers());
        assert!(stats.work_stealing_enabled);
        assert_eq!(stats.completed_tasks, 0);
        assert_eq!(stats.failed_tasks, 0);
    }

    #[test]
    fn test_executor_reset() {
        let executor = ParallelExecutor::new().unwrap();
        executor.reset();

        let stats = executor.stats();
        assert_eq!(stats.completed_tasks, 0);
        assert_eq!(stats.failed_tasks, 0);
        assert_eq!(stats.queue_size, 0);
    }
}
