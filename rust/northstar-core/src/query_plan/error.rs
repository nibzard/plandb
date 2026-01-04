//! Query Plan Error Types
//!
//! This module defines error types specific to query plan visualization.

use thiserror::Error;

/// Result type for query plan operations
pub type Result<T> = std::result::Result<T, QueryPlanError>;

/// Errors that can occur during query plan generation and visualization
#[derive(Error, Debug)]
pub enum QueryPlanError {
    /// Query text contains syntax errors
    #[error("Parse error: {0}")]
    ParseError(String),

    /// Query references non-existent tables or columns
    #[error("Validation error: {0}")]
    ValidationError(String),

    /// Optimizer cannot generate a valid plan
    #[error("Planning error: {0}")]
    PlanningError(String),

    /// Plan structure is invalid
    #[error("Invalid plan structure: {0}")]
    InvalidPlan(String),

    /// Visualization rendering failed
    #[error("Visualization error: {0}")]
    VisualizationError(String),

    /// JSON serialization/deserialization failed
    #[error("JSON error: {0}")]
    JsonError(#[from] serde_json::Error),

    /// Plan comparison failed
    #[error("Comparison error: {0}")]
    ComparisonError(String),
}

impl QueryPlanError {
    /// Create a parse error
    pub fn parse(msg: impl Into<String>) -> Self {
        Self::ParseError(msg.into())
    }

    /// Create a validation error
    pub fn validation(msg: impl Into<String>) -> Self {
        Self::ValidationError(msg.into())
    }

    /// Create a planning error
    pub fn planning(msg: impl Into<String>) -> Self {
        Self::PlanningError(msg.into())
    }

    /// Create an invalid plan error
    pub fn invalid_plan(msg: impl Into<String>) -> Self {
        Self::InvalidPlan(msg.into())
    }

    /// Create a visualization error
    pub fn visualization(msg: impl Into<String>) -> Self {
        Self::VisualizationError(msg.into())
    }

    /// Create a comparison error
    pub fn comparison(msg: impl Into<String>) -> Self {
        Self::ComparisonError(msg.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_creation() {
        let err = QueryPlanError::parse("syntax error near 'FROM'");
        assert!(matches!(err, QueryPlanError::ParseError(_)));
        assert!(err.to_string().contains("syntax error"));
    }

    #[test]
    fn test_error_display() {
        let err = QueryPlanError::validation("column 'foo' does not exist");
        assert_eq!(err.to_string(), "Validation error: column 'foo' does not exist");
    }
}
