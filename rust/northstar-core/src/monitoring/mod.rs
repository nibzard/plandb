//! Monitoring and Alerting System
//!
//! Comprehensive monitoring infrastructure providing real-time visibility into
//! database health, performance, and resource utilization with minimal overhead.

mod registry;
mod health;
mod alert;
mod export;

pub use registry::{MetricRegistry, Metric, MetricType, MetricValue, HistogramData, SummaryData};
pub use health::{HealthChecker, HealthStatus, HealthCheck, HealthCheckFn};
pub use alert::{AlertEngine, Alert, AlertRule, AlertSeverity, AlertCondition};
pub use export::{export_prometheus, export_json, ExportFormat, MonitoringConfig};

use std::sync::Arc;
use parking_lot::RwLock;
use std::time::Instant;

/// Create a new metric registry with default configuration.
pub fn registry() -> Arc<MetricRegistry> {
    Arc::new(MetricRegistry::new(MonitoringConfig::default()))
}

/// Create a new metric registry with custom configuration.
pub fn registry_with_config(config: MonitoringConfig) -> Arc<MetricRegistry> {
    Arc::new(MetricRegistry::new(config))
}

/// Create a new health checker with default timeout.
pub fn health_checker() -> Arc<HealthChecker> {
    Arc::new(HealthChecker::new())
}

/// Create a new health checker with custom timeout.
pub fn health_checker_with_timeout(timeout: std::time::Duration) -> Arc<HealthChecker> {
    Arc::new(HealthChecker::with_timeout(timeout))
}

/// Create a new alert engine.
pub fn alert_engine() -> Arc<AlertEngine> {
    Arc::new(AlertEngine::new())
}
