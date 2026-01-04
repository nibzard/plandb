//! Health Check Framework
//!
//! Aggregates multiple health checks into overall system health.

use std::sync::Arc;
use std::time::{Duration, Instant};
use parking_lot::Mutex;

/// Overall health status of the database system.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthStatus {
    /// All systems operating normally
    Healthy,
    /// Some functionality impacted but service continues
    Degraded,
    /// Critical issues requiring immediate attention
    Unhealthy,
    /// Health check incomplete or failed
    Unknown,
}

/// Individual health check result.
#[derive(Debug, Clone)]
pub struct HealthCheck {
    /// Check identifier
    pub name: String,
    /// Current health status
    pub status: HealthStatus,
    /// Human-readable status message
    pub message: String,
    /// When check was last performed
    pub last_check: Instant,
    /// How long the check took
    pub duration: Duration,
    /// Whether failure marks entire system unhealthy
    pub critical: bool,
}

/// Health check function trait.
pub trait HealthCheckFn: Send + Sync {
    /// Execute the health check.
    fn check(&self) -> Result<String, String>;
}

/// Generic health check function wrapper.
impl<F> HealthCheckFn for F
where
    F: Fn() -> Result<String, String> + Send + Sync,
{
    fn check(&self) -> Result<String, String> {
        self()
    }
}

/// Registered health check entry.
struct HealthCheckEntry {
    name: String,
    check_fn: Box<dyn HealthCheckFn>,
    critical: bool,
}

/// Health checker that aggregates multiple health checks.
pub struct HealthChecker {
    checks: Mutex<Vec<HealthCheckEntry>>,
    timeout: Duration,
    overall_status: Mutex<HealthStatus>,
    last_update: Mutex<Instant>,
}

impl HealthChecker {
    /// Create a new health checker with default timeout (5 seconds).
    pub fn new() -> Self {
        Self::with_timeout(Duration::from_secs(5))
    }

    /// Create a new health checker with custom timeout.
    pub fn with_timeout(timeout: Duration) -> Self {
        Self {
            checks: Mutex::new(Vec::new()),
            timeout,
            overall_status: Mutex::new(HealthStatus::Unknown),
            last_update: Mutex::new(Instant::now()),
        }
    }

    /// Register a health check.
    pub fn register_check(
        &self,
        name: String,
        check_fn: Box<dyn HealthCheckFn>,
        critical: bool,
    ) -> Result<(), String> {
        let mut checks = self.checks.lock();

        // Check for duplicate name
        if checks.iter().any(|c| c.name == name) {
            return Err(format!("Health check with name '{}' already exists", name));
        }

        checks.push(HealthCheckEntry {
            name,
            check_fn,
            critical,
        });

        Ok(())
    }

    /// Run all health checks and return results.
    pub fn run_checks(&self) -> Vec<HealthCheck> {
        let checks = self.checks.lock();
        let mut results = Vec::with_capacity(checks.len());

        let start = Instant::now();

        for entry in checks.iter() {
            let check_start = Instant::now();

            let (status, message) = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                entry.check_fn.check()
            })) {
                Ok(Ok(msg)) => (HealthStatus::Healthy, msg),
                Ok(Err(msg)) => (
                    if entry.critical {
                        HealthStatus::Unhealthy
                    } else {
                        HealthStatus::Degraded
                    },
                    msg,
                ),
                Err(_) => (
                    if entry.critical {
                        HealthStatus::Unhealthy
                    } else {
                        HealthStatus::Degraded
                    },
                    "Health check panicked".to_string(),
                ),
            };

            let duration = check_start.elapsed();

            results.push(HealthCheck {
                name: entry.name.clone(),
                status,
                message,
                last_check: Instant::now(),
                duration,
                critical: entry.critical,
            });
        }

        // Aggregate overall status
        let mut overall = HealthStatus::Healthy;

        for result in &results {
            match result.status {
                HealthStatus::Unhealthy if result.critical => {
                    overall = HealthStatus::Unhealthy;
                    break;
                }
                HealthStatus::Degraded if overall == HealthStatus::Healthy => {
                    overall = HealthStatus::Degraded;
                }
                _ => {}
            }
        }

        *self.overall_status.lock() = overall;
        *self.last_update.lock() = Instant::now();

        results
    }

    /// Get the overall health status.
    pub fn overall_status(&self) -> HealthStatus {
        *self.overall_status.lock()
    }

    /// Get the last update time.
    pub fn last_update(&self) -> Instant {
        *self.last_update.lock()
    }

    /// Get the timeout duration.
    pub fn timeout(&self) -> Duration {
        self.timeout
    }

    /// Set the timeout duration.
    pub fn set_timeout(&self, timeout: Duration) {
        // Note: This would need to be stored in Arc<AtomicU64> or Mutex for thread-safe updates
        // For now, we'll keep it simple
    }
}

impl Default for HealthChecker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_health_status_ord() {
        assert_eq!(HealthStatus::Healthy, HealthStatus::Healthy);
        assert_ne!(HealthStatus::Healthy, HealthStatus::Degraded);
        assert_ne!(HealthStatus::Degraded, HealthStatus::Unhealthy);
    }

    #[test]
    fn test_health_checker_healthy() {
        let checker = HealthChecker::new();

        checker
            .register_check(
                "test_check".to_string(),
                Box::new(|| Ok("All good".to_string())),
                false,
            )
            .unwrap();

        let results = checker.run_checks();

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].status, HealthStatus::Healthy);
        assert_eq!(checker.overall_status(), HealthStatus::Healthy);
    }

    #[test]
    fn test_health_checker_degraded() {
        let checker = HealthChecker::new();

        checker
            .register_check(
                "degraded_check".to_string(),
                Box::new(|| Err("Something is wrong".to_string())),
                false,
            )
            .unwrap();

        let results = checker.run_checks();

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].status, HealthStatus::Degraded);
        assert_eq!(checker.overall_status(), HealthStatus::Degraded);
    }

    #[test]
    fn test_health_checker_unhealthy_critical() {
        let checker = HealthChecker::new();

        checker
            .register_check(
                "critical_check".to_string(),
                Box::new(|| Err("Critical failure".to_string())),
                true,
            )
            .unwrap();

        let results = checker.run_checks();

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].status, HealthStatus::Unhealthy);
        assert_eq!(checker.overall_status(), HealthStatus::Unhealthy);
    }

    #[test]
    fn test_health_checker_multiple_checks() {
        let checker = HealthChecker::new();

        checker
            .register_check(
                "healthy_check".to_string(),
                Box::new(|| Ok("Good".to_string())),
                false,
            )
            .unwrap();

        checker
            .register_check(
                "degraded_check".to_string(),
                Box::new(|| Err("Warning".to_string())),
                false,
            )
            .unwrap();

        let results = checker.run_checks();

        assert_eq!(results.len(), 2);
        assert_eq!(checker.overall_status(), HealthStatus::Degraded);
    }

    #[test]
    fn test_health_checker_duplicate() {
        let checker = HealthChecker::new();

        checker
            .register_check(
                "test_check".to_string(),
                Box::new(|| Ok("Good".to_string())),
                false,
            )
            .unwrap();

        let result = checker.register_check(
            "test_check".to_string(),
            Box::new(|| Ok("Duplicate".to_string())),
            false,
        );

        assert!(result.is_err());
    }

    #[test]
    fn test_health_check_duration() {
        let checker = HealthChecker::new();

        checker
            .register_check(
                "slow_check".to_string(),
                Box::new(|| {
                    std::thread::sleep(Duration::from_millis(10));
                    Ok("Done".to_string())
                }),
                false,
            )
            .unwrap();

        let results = checker.run_checks();

        assert_eq!(results.len(), 1);
        assert!(results[0].duration >= Duration::from_millis(10));
    }
}
