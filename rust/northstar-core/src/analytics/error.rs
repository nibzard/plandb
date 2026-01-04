//! Error types for time-series analytics operations.

use thiserror::Error;

/// Result type alias for time-series operations
pub type TimeSeriesResult<T> = std::result::Result<T, TimeSeriesError>;

/// Time-series analytics errors
#[derive(Error, Debug)]
pub enum TimeSeriesError {
    /// Invalid time range (end_time <= start_time)
    #[error("Invalid time range: end_time ({end}) <= start_time ({start})")]
    InvalidTimeRange { start: i64, end: i64 },

    /// Invalid window configuration
    #[error("Invalid window configuration: {0}")]
    InvalidWindow(String),

    /// Invalid tag filter
    #[error("Invalid tag filter: {0}")]
    InvalidTagFilter(String),

    /// Invalid timezone
    #[error("Invalid timezone: {timezone}")]
    InvalidTimezone { timezone: String },

    /// Invalid group by configuration
    #[error("Invalid group by: {0}")]
    InvalidGroupBy(String),

    /// Parse error
    #[error("Parse error: {0}")]
    ParseError(String),

    /// Invalid calendar unit
    #[error("Invalid calendar unit: {0}")]
    InvalidCalendarUnit(String),

    /// Regex error
    #[error("Regex error: {0}")]
    RegexError(#[from] regex::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_display() {
        let err = TimeSeriesError::InvalidTimeRange { start: 0, end: -1 };
        assert!(err.to_string().contains("Invalid time range"));
    }

    #[test]
    fn test_invalid_window() {
        let err = TimeSeriesError::InvalidWindow("negative size".to_string());
        assert!(err.to_string().contains("negative size"));
    }

    #[test]
    fn test_invalid_timezone() {
        let err = TimeSeriesError::InvalidTimezone {
            timezone: "Invalid/Timezone".to_string(),
        };
        assert!(err.to_string().contains("Invalid/Timezone"));
    }
}
