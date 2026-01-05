//! Error types for autonomous optimization.

use std::io;

/// Result type for autonomous operations.
pub type AutonomousResult<T> = Result<T, AutonomousError>;

/// Errors that can occur during autonomous optimization.
#[derive(Debug, thiserror::Error)]
pub enum AutonomousError {
    /// Optimization not found in history
    #[error("Optimization not found: {0}")]
    OptimizationNotFound(OptimizationId),

    /// Invalid optimization candidate
    #[error("Invalid optimization candidate: {0}")]
    InvalidCandidate(String),

    /// Safety constraint violation
    #[error("Safety constraint violation: {0}")]
    SafetyViolation(String),

    /// Optimization execution failed
    #[error("Optimization execution failed: {0}")]
    ExecutionFailed(String),

    /// Rollback failed
    #[error("Rollback failed: {0}")]
    RollbackFailed(String),

    /// Maintenance window not available
    #[error("Maintenance window not available")]
    MaintenanceWindowNotAvailable,

    /// Resource limit exceeded
    #[error("Resource limit exceeded: {0}")]
    ResourceLimitExceeded(String),

    /// Performance regression detected
    #[error("Performance regression detected: {percent:.2}% degradation")]
    PerformanceRegression { percent: f64 },

    /// Approval required
    #[error("Approval required for optimization: {0}")]
    ApprovalRequired(String),

    /// IO error
    #[error("IO error: {0}")]
    Io(#[from] io::Error),

    /// Usage analytics error
    #[error("Usage analytics error: {0}")]
    UsageAnalyticsError(String),

    /// Cache error
    #[error("Cache error: {0}")]
    CacheError(String),

    /// B+tree error
    #[error("B+tree error: {0}")]
    BTreeError(String),
}

/// Unique identifier for optimizations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize, PartialOrd, Ord)]
pub struct OptimizationId(pub u64);

impl std::fmt::Display for OptimizationId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "opt-{}", self.0)
    }
}

impl OptimizationId {
    pub fn new(id: u64) -> Self {
        Self(id)
    }

    pub fn as_u64(self) -> u64 {
        self.0
    }
}
