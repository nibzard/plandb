//! Index Statistics Error Types
//!
//! Error types for index statistics collection and analysis.

use std::fmt;

/// Error type for index statistics operations
#[derive(Debug, Clone, PartialEq)]
pub enum IndexStatsError {
    /// Index not found in database
    IndexNotFound(String),

    /// Statistics collection not enabled or available
    StatsNotAvailable(String),

    /// Error during statistics collection
    CollectionError(String),

    /// Error during snapshot creation or retrieval
    SnapshotError(String),

    /// Error during trend analysis
    AnalysisError(String),

    /// Error during report generation
    ReportGenerationError(String),

    /// Invalid input or configuration
    InvalidInput(String),
}

impl fmt::Display for IndexStatsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IndexStatsError::IndexNotFound(name) => write!(f, "Index not found: {}", name),
            IndexStatsError::StatsNotAvailable(msg) => {
                write!(f, "Statistics not available: {}", msg)
            }
            IndexStatsError::CollectionError(msg) => {
                write!(f, "Statistics collection error: {}", msg)
            }
            IndexStatsError::SnapshotError(msg) => write!(f, "Snapshot error: {}", msg),
            IndexStatsError::AnalysisError(msg) => write!(f, "Analysis error: {}", msg),
            IndexStatsError::ReportGenerationError(msg) => {
                write!(f, "Report generation error: {}", msg)
            }
            IndexStatsError::InvalidInput(msg) => write!(f, "Invalid input: {}", msg),
        }
    }
}

impl std::error::Error for IndexStatsError {}

/// Result type for index statistics operations
pub type Result<T> = std::result::Result<T, IndexStatsError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_display() {
        assert_eq!(
            format!("{}", IndexStatsError::IndexNotFound("idx".to_string())),
            "Index not found: idx"
        );
        assert_eq!(
            format!("{}", IndexStatsError::StatsNotAvailable("disabled".to_string())),
            "Statistics not available: disabled"
        );
    }

    #[test]
    fn test_error_equality() {
        let err1 = IndexStatsError::IndexNotFound("idx".to_string());
        let err2 = IndexStatsError::IndexNotFound("idx".to_string());
        assert_eq!(err1, err2);
    }
}
