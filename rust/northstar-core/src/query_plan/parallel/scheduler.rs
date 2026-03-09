//! Work Scheduler for Parallel Query Execution
//!
//! This module implements a work-stealing scheduler for distributing parallel
//! query tasks across worker threads using Rayon's thread pool.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::query_plan::parallel::task::ParallelTask;
use crossbeam::queue::SegQueue;

/// Configuration for the work scheduler.
#[derive(Debug, Clone)]
pub struct WorkSchedulerConfig {
    /// Number of worker threads (0 = auto-detect)
    pub num_workers: usize,
    /// Enable work-stealing between threads
    pub enable_work_stealing: bool,
    /// Maximum number of tasks in the queue
    pub max_queue_size: usize,
    /// Timeout for waiting on tasks
    pub task_timeout: Duration,
}

impl Default for WorkSchedulerConfig {
    fn default() -> Self {
        Self {
            num_workers: 0, // Auto-detect
            enable_work_stealing: true,
            max_queue_size: 10000,
            task_timeout: Duration::from_secs(30),
        }
    }
}

impl WorkSchedulerConfig {
    /// Creates a new scheduler configuration.
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

    /// Sets the maximum queue size.
    pub fn with_max_queue_size(mut self, size: usize) -> Self {
        self.max_queue_size = size;
        self
    }

    /// Sets the task timeout.
    pub fn with_task_timeout(mut self, timeout: Duration) -> Self {
        self.task_timeout = timeout;
        self
    }

    /// Returns the effective number of workers (auto-detect if 0).
    pub fn effective_workers(&self) -> usize {
        if self.num_workers == 0 {
            num_cpus::get()
        } else {
            self.num_workers
        }
    }
}

/// Work-stealing scheduler for parallel query execution.
///
/// The scheduler maintains a queue of tasks and distributes them to worker
/// threads using Rayon's work-stealing thread pool.
pub struct WorkScheduler {
    /// Task queue
    task_queue: Arc<SegQueue<ParallelTask>>,
    /// Number of worker threads
    num_workers: usize,
    /// Enable work-stealing
    work_stealing: bool,
    /// Configuration
    config: WorkSchedulerConfig,
    /// Number of tasks completed
    completed_tasks: Arc<AtomicUsize>,
    /// Number of tasks failed
    failed_tasks: Arc<AtomicUsize>,
}

impl WorkScheduler {
    /// Creates a new work scheduler with default configuration.
    pub fn new() -> Self {
        Self::with_config(WorkSchedulerConfig::default())
    }

    /// Creates a new work scheduler with the given configuration.
    pub fn with_config(config: WorkSchedulerConfig) -> Self {
        let num_workers = config.effective_workers();

        Self {
            task_queue: Arc::new(SegQueue::new()),
            num_workers,
            work_stealing: config.enable_work_stealing,
            config,
            completed_tasks: Arc::new(AtomicUsize::new(0)),
            failed_tasks: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Returns the number of worker threads.
    pub fn num_workers(&self) -> usize {
        self.num_workers
    }

    /// Returns true if work-stealing is enabled.
    pub fn work_stealing_enabled(&self) -> bool {
        self.work_stealing
    }

    /// Returns the number of tasks currently in the queue.
    pub fn queue_size(&self) -> usize {
        self.task_queue.len()
    }

    /// Returns true if the task queue is empty.
    pub fn is_empty(&self) -> bool {
        self.task_queue.is_empty()
    }

    /// Adds a task to the scheduler queue.
    pub fn schedule(&self, task: ParallelTask) -> Result<(), ScheduleError> {
        if self.task_queue.len() >= self.config.max_queue_size {
            return Err(ScheduleError::QueueFull);
        }

        self.task_queue.push(task);
        Ok(())
    }

    /// Adds multiple tasks to the scheduler queue.
    pub fn schedule_batch(&self, tasks: Vec<ParallelTask>) -> Result<(), ScheduleError> {
        for task in tasks {
            self.schedule(task)?;
        }
        Ok(())
    }

    /// Tries to pop a task from the queue.
    pub fn try_pop(&self) -> Option<ParallelTask> {
        self.task_queue.pop()
    }

    /// Waits for a task to become available.
    pub fn pop_task(&self) -> Option<ParallelTask> {
        let start = Instant::now();

        loop {
            if let Some(task) = self.try_pop() {
                return Some(task);
            }

            if start.elapsed() >= self.config.task_timeout {
                return None;
            }

            // Yield to other threads
            std::thread::yield_now();
        }
    }

    /// Returns the number of completed tasks.
    pub fn completed_count(&self) -> usize {
        self.completed_tasks.load(Ordering::Relaxed)
    }

    /// Returns the number of failed tasks.
    pub fn failed_count(&self) -> usize {
        self.failed_tasks.load(Ordering::Relaxed)
    }

    /// Increments the completed task counter.
    pub fn record_completed(&self) {
        self.completed_tasks.fetch_add(1, Ordering::Relaxed);
    }

    /// Increments the failed task counter.
    pub fn record_failed(&self) {
        self.failed_tasks.fetch_add(1, Ordering::Relaxed);
    }

    /// Returns the total number of tasks processed (completed + failed).
    pub fn total_processed(&self) -> usize {
        self.completed_count() + self.failed_count()
    }

    /// Clears all counters.
    pub fn clear_counters(&self) {
        self.completed_tasks.store(0, Ordering::Relaxed);
        self.failed_tasks.store(0, Ordering::Relaxed);
    }

    /// Clears the task queue.
    pub fn clear_queue(&self) {
        while self.try_pop().is_some() {
            // Discard tasks
        }
    }

    /// Resets the scheduler state.
    pub fn reset(&self) {
        self.clear_queue();
        self.clear_counters();
    }
}

impl Clone for WorkScheduler {
    fn clone(&self) -> Self {
        Self {
            task_queue: Arc::clone(&self.task_queue),
            num_workers: self.num_workers,
            work_stealing: self.work_stealing,
            config: self.config.clone(),
            completed_tasks: Arc::clone(&self.completed_tasks),
            failed_tasks: Arc::clone(&self.failed_tasks),
        }
    }
}

/// Errors that can occur during task scheduling.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScheduleError {
    /// Task queue is full
    QueueFull,
    /// Scheduler is shut down
    Shutdown,
    /// Task timeout
    Timeout,
}

impl std::fmt::Display for ScheduleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScheduleError::QueueFull => write!(f, "Task queue is full"),
            ScheduleError::Shutdown => write!(f, "Scheduler is shut down"),
            ScheduleError::Timeout => write!(f, "Task timeout"),
        }
    }
}

impl std::error::Error for ScheduleError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query_plan::parallel::task::{PagePartition, ScanTask};

    #[test]
    fn test_scheduler_config() {
        let config = WorkSchedulerConfig::default();
        assert_eq!(config.num_workers, 0);
        assert!(config.enable_work_stealing);

        let config = config.with_num_workers(4);
        assert_eq!(config.num_workers, 4);
        assert_eq!(config.effective_workers(), 4);

        let config = WorkSchedulerConfig::default().with_num_workers(0);
        assert!(config.effective_workers() > 0);
    }

    #[test]
    fn test_work_scheduler() {
        let scheduler = WorkScheduler::new();
        assert!(scheduler.is_empty());
        assert_eq!(scheduler.queue_size(), 0);

        let task = ParallelTask::Scan(ScanTask::new(
            1,
            0,
            PagePartition::new(0, 10),
            "test",
            100,
        ));

        assert!(scheduler.schedule(task.clone()).is_ok());
        assert!(!scheduler.is_empty());
        assert_eq!(scheduler.queue_size(), 1);

        let popped = scheduler.try_pop();
        assert!(popped.is_some());
        assert!(scheduler.is_empty());
    }

    #[test]
    fn test_schedule_batch() {
        let scheduler = WorkScheduler::new();

        let tasks = vec![
            ParallelTask::Scan(ScanTask::new(
                1,
                0,
                PagePartition::new(0, 10),
                "test",
                100,
            )),
            ParallelTask::Scan(ScanTask::new(
                2,
                1,
                PagePartition::new(10, 20),
                "test",
                100,
            )),
        ];

        assert!(scheduler.schedule_batch(tasks).is_ok());
        assert_eq!(scheduler.queue_size(), 2);
    }

    #[test]
    fn test_queue_size_limit() {
        let config = WorkSchedulerConfig::default().with_max_queue_size(2);
        let scheduler = WorkScheduler::with_config(config);

        let task = ParallelTask::Scan(ScanTask::new(
            1,
            0,
            PagePartition::new(0, 10),
            "test",
            100,
        ));

        assert!(scheduler.schedule(task.clone()).is_ok());
        assert!(scheduler.schedule(task.clone()).is_ok());
        assert_eq!(scheduler.schedule(task), Err(ScheduleError::QueueFull));
    }

    #[test]
    fn test_counters() {
        let scheduler = WorkScheduler::new();

        assert_eq!(scheduler.completed_count(), 0);
        assert_eq!(scheduler.failed_count(), 0);
        assert_eq!(scheduler.total_processed(), 0);

        scheduler.record_completed();
        scheduler.record_completed();
        scheduler.record_failed();

        assert_eq!(scheduler.completed_count(), 2);
        assert_eq!(scheduler.failed_count(), 1);
        assert_eq!(scheduler.total_processed(), 3);

        scheduler.clear_counters();
        assert_eq!(scheduler.completed_count(), 0);
        assert_eq!(scheduler.failed_count(), 0);
    }

    #[test]
    fn test_reset() {
        let scheduler = WorkScheduler::new();

        let task = ParallelTask::Scan(ScanTask::new(
            1,
            0,
            PagePartition::new(0, 10),
            "test",
            100,
        ));

        scheduler.schedule(task).unwrap();
        scheduler.record_completed();

        assert!(!scheduler.is_empty());
        assert_eq!(scheduler.completed_count(), 1);

        scheduler.reset();

        assert!(scheduler.is_empty());
        assert_eq!(scheduler.completed_count(), 0);
    }

    #[test]
    fn test_scheduler_clone() {
        let scheduler1 = WorkScheduler::new();
        let scheduler2 = scheduler1.clone();

        assert_eq!(scheduler1.num_workers(), scheduler2.num_workers());

        let task = ParallelTask::Scan(ScanTask::new(
            1,
            0,
            PagePartition::new(0, 10),
            "test",
            100,
        ));

        scheduler1.schedule(task).unwrap();

        // Both clones share the same queue
        assert_eq!(scheduler2.queue_size(), 1);
    }
}
