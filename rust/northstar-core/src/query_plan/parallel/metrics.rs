//! Parallel Execution Metrics
//!
//! This module provides metrics collection for parallel query execution,
//! tracking performance statistics across worker threads.

use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::RwLock;

/// Metrics collected during parallel query execution.
#[derive(Debug, Clone)]
pub struct ParallelExecutionMetrics {
    /// Total execution time
    pub total_time: Duration,
    /// Number of worker threads used
    pub num_workers: usize,
    /// Total number of tasks executed
    pub total_tasks: usize,
    /// Number of completed tasks
    pub completed_tasks: usize,
    /// Number of failed tasks
    pub failed_tasks: usize,
    /// Per-task type metrics
    pub task_metrics: TaskMetrics,
    /// Work-stealing metrics
    pub work_stealing: WorkStealingMetrics,
    /// Memory usage statistics
    pub memory_usage: MemoryMetrics,
}

impl ParallelExecutionMetrics {
    /// Creates a new metrics instance.
    pub fn new() -> Self {
        Self {
            total_time: Duration::ZERO,
            num_workers: 0,
            total_tasks: 0,
            completed_tasks: 0,
            failed_tasks: 0,
            task_metrics: TaskMetrics::default(),
            work_stealing: WorkStealingMetrics::default(),
            memory_usage: MemoryMetrics::default(),
        }
    }

    /// Returns the task completion rate (tasks per second).
    pub fn completion_rate(&self) -> f64 {
        let seconds = self.total_time.as_secs_f64();
        if seconds > 0.0 {
            self.completed_tasks as f64 / seconds
        } else {
            0.0
        }
    }

    /// Returns the success rate (0.0 to 1.0).
    pub fn success_rate(&self) -> f64 {
        if self.total_tasks > 0 {
            self.completed_tasks as f64 / self.total_tasks as f64
        } else {
            1.0
        }
    }

    /// Returns the parallelism efficiency (speedup / num_workers).
    pub fn efficiency(&self) -> f64 {
        if self.num_workers > 0 {
            // This is a simplified calculation
            // Real efficiency would compare against serial execution time
            self.completion_rate() / self.num_workers as f64
        } else {
            0.0
        }
    }

    /// Formats the metrics as a human-readable string.
    pub fn format(&self) -> String {
        format!(
            "Parallel Execution Metrics:\n\
             - Total time: {:.2}s\n\
             - Workers: {}\n\
             - Tasks: {}/{} completed\n\
             - Success rate: {:.1}%\n\
             - Completion rate: {:.1} tasks/s\n\
             - Memory usage: {}\n\
             - Work stolen: {}",
            self.total_time.as_secs_f64(),
            self.num_workers,
            self.completed_tasks,
            self.total_tasks,
            self.success_rate() * 100.0,
            self.completion_rate(),
            bytesize::to_string(self.memory_usage.peak_bytes as f64, None),
            self.work_stealing.stolen_tasks,
        )
    }
}

impl Default for ParallelExecutionMetrics {
    fn default() -> Self {
        Self::new()
    }
}

/// Metrics for different task types.
#[derive(Debug, Clone, Default)]
pub struct TaskMetrics {
    /// Number of scan tasks
    pub scan_tasks: usize,
    /// Number of join tasks
    pub join_tasks: usize,
    /// Number of aggregate tasks
    pub aggregate_tasks: usize,
    /// Number of sort tasks
    pub sort_tasks: usize,
    /// Total time spent on scan tasks
    pub scan_time: Duration,
    /// Total time spent on join tasks
    pub join_time: Duration,
    /// Total time spent on aggregate tasks
    pub aggregate_time: Duration,
    /// Total time spent on sort tasks
    pub sort_time: Duration,
}

impl TaskMetrics {
    /// Records a task execution.
    pub fn record_task(&mut self, task_type: &str, duration: Duration) {
        match task_type {
            "scan" => {
                self.scan_tasks += 1;
                self.scan_time += duration;
            }
            "join" => {
                self.join_tasks += 1;
                self.join_time += duration;
            }
            "aggregate" => {
                self.aggregate_tasks += 1;
                self.aggregate_time += duration;
            }
            "sort" => {
                self.sort_tasks += 1;
                self.sort_time += duration;
            }
            _ => {}
        }
    }

    /// Returns the total number of tasks.
    pub fn total_tasks(&self) -> usize {
        self.scan_tasks + self.join_tasks + self.aggregate_tasks + self.sort_tasks
    }

    /// Returns the average time per task type.
    pub fn average_time(&self, task_type: &str) -> Option<Duration> {
        let (count, total) = match task_type {
            "scan" => (self.scan_tasks, self.scan_time),
            "join" => (self.join_tasks, self.join_time),
            "aggregate" => (self.aggregate_tasks, self.aggregate_time),
            "sort" => (self.sort_tasks, self.sort_time),
            _ => return None,
        };

        if count > 0 {
            Some(total / count as u32)
        } else {
            None
        }
    }
}

/// Work-stealing metrics.
#[derive(Debug, Clone, Default)]
pub struct WorkStealingMetrics {
    /// Number of tasks stolen from other threads
    pub stolen_tasks: usize,
    /// Number of times a thread had to steal
    pub steal_attempts: usize,
    /// Number of successful steals
    pub successful_steals: usize,
}

impl WorkStealingMetrics {
    /// Records a steal attempt.
    pub fn record_steal(&mut self, success: bool) {
        self.steal_attempts += 1;
        if success {
            self.successful_steals += 1;
            self.stolen_tasks += 1;
        }
    }

    /// Returns the steal success rate.
    pub fn success_rate(&self) -> f64 {
        if self.steal_attempts > 0 {
            self.successful_steals as f64 / self.steal_attempts as f64
        } else {
            0.0
        }
    }
}

/// Memory usage metrics.
#[derive(Debug, Clone, Default)]
pub struct MemoryMetrics {
    /// Current memory usage in bytes
    pub current_bytes: usize,
    /// Peak memory usage in bytes
    pub peak_bytes: usize,
    /// Memory allocated per worker
    pub per_worker_bytes: usize,
}

impl MemoryMetrics {
    /// Updates the current memory usage.
    pub fn update_current(&mut self, bytes: usize) {
        self.current_bytes = bytes;
        if bytes > self.peak_bytes {
            self.peak_bytes = bytes;
        }
    }

    /// Returns the memory overhead as a percentage of peak.
    pub fn overhead_percent(&self) -> f64 {
        if self.peak_bytes > 0 {
            ((self.current_bytes as f64 - self.peak_bytes as f64) / self.peak_bytes as f64) * 100.0
        } else {
            0.0
        }
    }
}

/// A helper struct for formatting byte sizes.
mod bytesize {
    pub fn to_string(bytes: f64, _options: Option<()>) -> String {
        const UNITS: &[&str] = &["B", "KB", "MB", "GB", "TB"];
        let mut size = bytes;
        let mut unit_index = 0;

        while size >= 1024.0 && unit_index < UNITS.len() - 1 {
            size /= 1024.0;
            unit_index += 1;
        }

        format!("{:.2} {}", size, UNITS[unit_index])
    }
}

/// A timer for measuring task execution time.
pub struct TaskTimer {
    start: Instant,
}

impl TaskTimer {
    /// Creates a new timer.
    pub fn new() -> Self {
        Self {
            start: Instant::now(),
        }
    }

    /// Returns the elapsed time.
    pub fn elapsed(&self) -> Duration {
        self.start.elapsed()
    }
}

impl Default for TaskTimer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parallel_execution_metrics() {
        let metrics = ParallelExecutionMetrics::new();

        assert_eq!(metrics.total_tasks, 0);
        assert_eq!(metrics.completed_tasks, 0);
        assert_eq!(metrics.success_rate(), 1.0); // No tasks means 100% success
    }

    #[test]
    fn test_completion_rate() {
        let mut metrics = ParallelExecutionMetrics::new();
        metrics.total_time = Duration::from_secs(2);
        metrics.completed_tasks = 100;

        assert!((metrics.completion_rate() - 50.0).abs() < 0.01);
    }

    #[test]
    fn test_success_rate() {
        let mut metrics = ParallelExecutionMetrics::new();
        metrics.total_tasks = 100;
        metrics.completed_tasks = 80;
        metrics.failed_tasks = 20;

        assert!((metrics.success_rate() - 0.8).abs() < 0.01);
    }

    #[test]
    fn test_task_metrics() {
        let mut metrics = TaskMetrics::default();

        metrics.record_task("scan", Duration::from_millis(100));
        metrics.record_task("scan", Duration::from_millis(200));
        metrics.record_task("join", Duration::from_millis(300));

        assert_eq!(metrics.scan_tasks, 2);
        assert_eq!(metrics.join_tasks, 1);
        assert_eq!(metrics.total_tasks(), 3);

        let avg_scan = metrics.average_time("scan").unwrap();
        assert_eq!(avg_scan, Duration::from_millis(150));
    }

    #[test]
    fn test_work_stealing_metrics() {
        let mut metrics = WorkStealingMetrics::default();

        metrics.record_steal(true);
        metrics.record_steal(false);
        metrics.record_steal(true);

        assert_eq!(metrics.steal_attempts, 3);
        assert_eq!(metrics.successful_steals, 2);
        assert_eq!(metrics.stolen_tasks, 2);
        assert!((metrics.success_rate() - 0.666).abs() < 0.01);
    }

    #[test]
    fn test_memory_metrics() {
        let mut metrics = MemoryMetrics::default();

        metrics.update_current(1024);
        metrics.update_current(2048);
        metrics.update_current(1024);

        assert_eq!(metrics.current_bytes, 1024);
        assert_eq!(metrics.peak_bytes, 2048);
    }

    #[test]
    fn test_task_timer() {
        let timer = TaskTimer::new();
        std::thread::sleep(Duration::from_millis(10));
        let elapsed = timer.elapsed();

        assert!(elapsed >= Duration::from_millis(10));
    }

    #[test]
    fn test_metrics_format() {
        let mut metrics = ParallelExecutionMetrics::new();
        metrics.total_time = Duration::from_secs(5);
        metrics.num_workers = 4;
        metrics.total_tasks = 100;
        metrics.completed_tasks = 95;
        metrics.failed_tasks = 5;
        metrics.memory_usage.peak_bytes = 1024 * 1024; // 1 MB

        let formatted = metrics.format();
        assert!(formatted.contains("5.00s"));
        assert!(formatted.contains("95"));
        assert!(formatted.contains("1.00 MB"));
    }
}
