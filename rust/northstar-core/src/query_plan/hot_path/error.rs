//! Hot Path Error Types
//!
//! This module defines error types specific to hot path identification and analysis.

use std::fmt;

/// Errors that can occur during hot path identification and analysis.
#[derive(Debug, Clone)]
pub enum HotPathError {
    /// Time period for analysis is invalid or too large.
    InvalidPeriod(String),

    /// Required statistics not available for the requested period.
    StatsNotAvailable(String),

    /// Internal query to statistics tables failed.
    QueryError(String),

    /// SQL query parsing or normalization failed.
    QueryNormalizationError(String),

    /// Error generating hot path report.
    ReportGenerationError(String),

    /// Error detecting bottlenecks.
    BottleneckDetectionError(String),

    /// Error generating optimization suggestions.
    SuggestionError(String),
}

impl fmt::Display for HotPathError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HotPathError::InvalidPeriod(msg) => write!(f, "Invalid analysis period: {}", msg),
            HotPathError::StatsNotAvailable(msg) => {
                write!(f, "Statistics not available: {}", msg)
            }
            HotPathError::QueryError(msg) => write!(f, "Query error: {}", msg),
            HotPathError::QueryNormalizationError(msg) => {
                write!(f, "Query normalization error: {}", msg)
            }
            HotPathError::ReportGenerationError(msg) => {
                write!(f, "Report generation error: {}", msg)
            }
            HotPathError::BottleneckDetectionError(msg) => {
                write!(f, "Bottleneck detection error: {}", msg)
            }
            HotPathError::SuggestionError(msg) => write!(f, "Suggestion error: {}", msg),
        }
    }
}

impl std::error::Error for HotPathError {}

/// Result type for hot path operations.
pub type HotPathResult<T> = Result<T, HotPathError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_display() {
        let err = HotPathError::InvalidPeriod("period too long".to_string());
        assert_eq!(
            format!("{}", err),
            "Invalid analysis period: period too long"
        );
    }

    #[test]
    fn test_error_downcast() {
        let err = HotPathError::QueryNormalizationError("parse error".to_string());
        let dyn_err: Box<dyn std::error::Error> = err.into();
        assert_eq!(dyn_err.to_string(), "Query normalization error: parse error");
    }
}
