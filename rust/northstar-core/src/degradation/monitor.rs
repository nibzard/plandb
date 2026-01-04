//! Resource monitoring for degradation detection

use std::collections::VecDeque;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use super::state::{DegradationConfig, DegradationTrigger, DegradationLevel};

/// Snapshot of system resources at a point in time
#[derive(Debug, Clone)]
pub struct ResourceSnapshot {
    /// When snapshot was taken
    pub timestamp: Instant,
    /// Free memory percentage
    pub memory_free_percent: f64,
    /// Free disk percentage
    pub disk_free_percent: f64,
    /// CPU usage percentage
    pub cpu_usage_percent: f64,
    /// Free connection count
    pub connection_pool_free: u32,
    /// Current cache hit rate
    pub cache_hit_rate: f64,
    /// 99th percentile write latency
    pub write_latency_p99: Duration,
    /// 99th percentile read latency
    pub read_latency_p99: Duration,
}

impl ResourceSnapshot {
    /// Create a new resource snapshot
    pub fn new(
        memory_free_percent: f64,
        disk_free_percent: f64,
        cpu_usage_percent: f64,
        connection_pool_free: u32,
        cache_hit_rate: f64,
        write_latency_p99: Duration,
        read_latency_p99: Duration,
    ) -> Self {
        Self {
            timestamp: Instant::now(),
            memory_free_percent,
            disk_free_percent,
            cpu_usage_percent,
            connection_pool_free,
            cache_hit_rate,
            write_latency_p99,
            read_latency_p99,
        }
    }

    /// Validate snapshot values are within expected ranges
    pub fn validate(&self) -> bool {
        self.memory_free_percent >= 0.0 && self.memory_free_percent <= 100.0
            && self.disk_free_percent >= 0.0 && self.disk_free_percent <= 100.0
            && self.cpu_usage_percent >= 0.0 && self.cpu_usage_percent <= 100.0
            && self.cache_hit_rate >= 0.0 && self.cache_hit_rate <= 1.0
    }
}

/// Configured thresholds for resource monitoring
#[derive(Debug, Clone, Copy)]
pub struct ResourceThresholds {
    /// Warning threshold for memory (default: 20%)
    pub memory_warning_percent: f64,
    /// Critical threshold for memory (default: 10%)
    pub memory_critical_percent: f64,
    /// Warning threshold for disk (default: 10%)
    pub disk_warning_percent: f64,
    /// Critical threshold for disk (default: 5%)
    pub disk_critical_percent: f64,
    /// Warning threshold for CPU (default: 80%)
    pub cpu_warning_percent: f64,
    /// Critical threshold for CPU (default: 90%)
    pub cpu_critical_percent: f64,
    /// Warning threshold for latency (default: 500ms)
    pub latency_warning_ms: u64,
    /// Critical threshold for latency (default: 1000ms)
    pub latency_critical_ms: u64,
}

impl Default for ResourceThresholds {
    fn default() -> Self {
        Self {
            memory_warning_percent: 20.0,
            memory_critical_percent: 10.0,
            disk_warning_percent: 10.0,
            disk_critical_percent: 5.0,
            cpu_warning_percent: 80.0,
            cpu_critical_percent: 90.0,
            latency_warning_ms: 500,
            latency_critical_ms: 1000,
        }
    }
}

impl ResourceThresholds {
    /// Create new resource thresholds
    pub fn new() -> Self {
        Self::default()
    }

    /// Validate thresholds are sensible
    pub fn validate(&self) -> bool {
        self.memory_critical_percent <= self.memory_warning_percent
            && self.disk_critical_percent <= self.disk_warning_percent
            && self.cpu_critical_percent >= self.cpu_warning_percent
            && self.latency_critical_ms >= self.latency_warning_ms
            && self.memory_critical_percent > 0.0
            && self.disk_critical_percent > 0.0
    }
}

/// Monitors system resources and detects degradation triggers
#[derive(Debug)]
pub struct ResourceMonitor {
    /// Shared configuration
    pub config: Arc<DegradationConfig>,
    /// Current resource thresholds
    pub thresholds: ResourceThresholds,
    /// Recent resource history (max: 100 entries)
    pub history: VecDeque<ResourceSnapshot>,
    /// Maximum history size
    pub max_history_size: usize,
}

impl ResourceMonitor {
    /// Create a new resource monitor
    pub fn new(config: Arc<DegradationConfig>) -> Self {
        Self {
            config,
            thresholds: ResourceThresholds::default(),
            history: VecDeque::with_capacity(100),
            max_history_size: 100,
        }
    }

    /// Set resource thresholds
    pub fn with_thresholds(mut self, thresholds: ResourceThresholds) -> Self {
        self.thresholds = thresholds;
        self
    }

    /// Add a snapshot to history (maintains max size)
    pub fn add_snapshot(&mut self, snapshot: ResourceSnapshot) {
        if self.history.len() >= self.max_history_size {
            self.history.pop_front();
        }
        self.history.push_back(snapshot);
    }

    /// Get the most recent snapshot
    pub fn latest_snapshot(&self) -> Option<&ResourceSnapshot> {
        self.history.back()
    }

    /// Check consecutive conditions over history
    pub fn check_consecutive<F>(&self, count: usize, predicate: F) -> bool
    where
        F: Fn(&ResourceSnapshot) -> bool,
    {
        if self.history.len() < count {
            return false;
        }

        self.history
            .iter()
            .rev()
            .take(count)
            .all(predicate)
    }

    /// Get memory trend (positive = improving, negative = worsening)
    pub fn memory_trend(&self, window: usize) -> Option<f64> {
        if self.history.len() < window {
            return None;
        }

        let latest = self.history.back()?.memory_free_percent;
        let oldest = self.history.get(self.history.len() - window)?.memory_free_percent;
        Some(latest - oldest)
    }

    /// Get average metric over history
    pub fn average_metric<F>(&self, metric_fn: F) -> Option<f64>
    where
        F: Fn(&ResourceSnapshot) -> f64,
    {
        if self.history.is_empty() {
            return None;
        }

        let sum: f64 = self.history.iter().map(&metric_fn).sum();
        Some(sum / self.history.len() as f64)
    }
}

/// Check current resource usage and return active triggers
///
/// Note: This is a simplified implementation. In production, this would
/// integrate with actual system metrics from the monitoring system.
pub fn monitor_resources(
    monitor: Arc<ResourceMonitor>,
    snapshot: ResourceSnapshot,
) -> Vec<DegradationTrigger> {
    let mut triggers = Vec::new();

    let thresholds = &monitor.thresholds;

    // Memory pressure check
    if snapshot.memory_free_percent < thresholds.memory_critical_percent {
        triggers.push(DegradationTrigger::MemoryPressure);
    }

    // Disk space check
    if snapshot.disk_free_percent < thresholds.disk_critical_percent {
        triggers.push(DegradationTrigger::DiskSpaceLow);
    }

    // CPU saturation check (needs consecutive readings)
    // This is handled at a higher level with history analysis

    // Connection pool check
    if snapshot.connection_pool_free == 0 {
        triggers.push(DegradationTrigger::ConnectionPoolExhausted);
    }

    // Cache hit rate check
    if snapshot.cache_hit_rate < 0.5 {
        triggers.push(DegradationTrigger::CacheEvictionRateHigh);
    }

    // Write latency check
    if snapshot.write_latency_p99.as_millis() as u64 > thresholds.latency_critical_ms {
        triggers.push(DegradationTrigger::WriteLatencyHigh);
    }

    // Read latency check
    if snapshot.read_latency_p99.as_millis() as u64 > thresholds.latency_critical_ms {
        triggers.push(DegradationTrigger::ReadLatencyHigh);
    }

    triggers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resource_snapshot_validation() {
        let snapshot = ResourceSnapshot::new(
            50.0,
            50.0,
            50.0,
            10,
            0.9,
            Duration::from_millis(10),
            Duration::from_millis(5),
        );
        assert!(snapshot.validate());

        let invalid = ResourceSnapshot::new(
            150.0, // Invalid: > 100%
            50.0,
            50.0,
            10,
            0.9,
            Duration::from_millis(10),
            Duration::from_millis(5),
        );
        assert!(!invalid.validate());
    }

    #[test]
    fn test_resource_thresholds_default() {
        let thresholds = ResourceThresholds::default();
        assert!(thresholds.validate());
        assert_eq!(thresholds.memory_critical_percent, 10.0);
        assert_eq!(thresholds.disk_critical_percent, 5.0);
        assert_eq!(thresholds.cpu_critical_percent, 90.0);
    }

    #[test]
    fn test_resource_thresholds_validation() {
        let valid = ResourceThresholds::default();
        assert!(valid.validate());

        let invalid = ResourceThresholds {
            memory_critical_percent: 20.0, // Critical > Warning
            ..valid
        };
        assert!(!invalid.validate());
    }

    #[test]
    fn test_resource_monitor_history() {
        let config = Arc::new(DegradationConfig::default());
        let mut monitor = ResourceMonitor::new(config);

        // Add snapshots
        for i in 0..150 {
            monitor.add_snapshot(ResourceSnapshot::new(
                50.0,
                50.0,
                50.0,
                10,
                0.9,
                Duration::from_millis(10),
                Duration::from_millis(5),
            ));
        }

        // History should be bounded
        assert_eq!(monitor.history.len(), 100);
    }

    #[test]
    fn test_resource_monitor_latest() {
        let config = Arc::new(DegradationConfig::default());
        let mut monitor = ResourceMonitor::new(config);

        assert!(monitor.latest_snapshot().is_none());

        monitor.add_snapshot(ResourceSnapshot::new(
            50.0,
            50.0,
            50.0,
            10,
            0.9,
            Duration::from_millis(10),
            Duration::from_millis(5),
        ));

        assert!(monitor.latest_snapshot().is_some());
    }

    #[test]
    fn test_check_consecutive() {
        let config = Arc::new(DegradationConfig::default());
        let mut monitor = ResourceMonitor::new(config);

        // Add 5 snapshots with cpu_usage_percent > 80
        for _ in 0..5 {
            monitor.add_snapshot(ResourceSnapshot::new(
                50.0,
                50.0,
                85.0, // High CPU
                10,
                0.9,
                Duration::from_millis(10),
                Duration::from_millis(5),
            ));
        }

        // Check for 3 consecutive high CPU readings
        let result = monitor.check_consecutive(3, |s| s.cpu_usage_percent > 80.0);
        assert!(result);
    }

    #[test]
    fn test_memory_trend() {
        let config = Arc::new(DegradationConfig::default());
        let mut monitor = ResourceMonitor::new(config);

        // Add snapshots with improving memory
        for i in 0..10 {
            monitor.add_snapshot(ResourceSnapshot::new(
                10.0 + (i as f64), // Improving
                50.0,
                50.0,
                10,
                0.9,
                Duration::from_millis(10),
                Duration::from_millis(5),
            ));
        }

        let trend = monitor.memory_trend(5);
        assert!(trend.is_some());
        assert!(trend.unwrap() > 0.0); // Positive trend = improving
    }

    #[test]
    fn test_average_metric() {
        let config = Arc::new(DegradationConfig::default());
        let mut monitor = ResourceMonitor::new(config);

        for i in 0..10 {
            monitor.add_snapshot(ResourceSnapshot::new(
                i as f64 * 10.0,
                50.0,
                50.0,
                10,
                0.9,
                Duration::from_millis(10),
                Duration::from_millis(5),
            ));
        }

        let avg = monitor.average_metric(|s| s.memory_free_percent);
        assert!(avg.is_some());
        // Average of 0, 10, 20, ..., 90 = 45
        assert!((avg.unwrap() - 45.0).abs() < 0.1);
    }
}
