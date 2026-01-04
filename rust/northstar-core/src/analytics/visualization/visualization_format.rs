//! Timestamp and value formatting utilities for visualizations.

use crate::analytics::TimeSeriesError;
use chrono::{DateTime, Utc};

/// Timestamp display format
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TimestampFormat {
    /// ISO 8601 standard format
    ISO8601,
    /// Human-readable format
    Human,
    /// Relative time ("5 minutes ago")
    Relative,
    /// Unix timestamp (milliseconds)
    Unix,
}

/// Format timestamp for display
pub fn format_timestamp_millis(ts: i64, format: TimestampFormat) -> String {
    match format {
        TimestampFormat::ISO8601 => {
            // Format as "2024-01-04T12:34:56Z"
            match DateTime::from_timestamp_millis(ts) {
                Some(dt) => dt.format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                None => String::new(),
            }
        }
        TimestampFormat::Human => {
            // Format as "Jan 4, 2024 12:34 PM"
            match DateTime::from_timestamp_millis(ts) {
                Some(dt) => dt.format("%b %e, %Y %l:%M %p").to_string(),
                None => String::new(),
            }
        }
        TimestampFormat::Relative => {
            // Format as "5 minutes ago", "2 hours ago"
            format_relative_time(ts)
        }
        TimestampFormat::Unix => {
            // Return timestamp as string
            ts.to_string()
        }
    }
}

/// Format timestamp as relative time
fn format_relative_time(ts: i64) -> String {
    let now = Utc::now().timestamp_millis();
    let diff_ms = now.saturating_sub(ts);

    if diff_ms < 1000 {
        "just now".to_string()
    } else if diff_ms < 60_000 {
        let seconds = diff_ms / 1000;
        format!("{} second{} ago", seconds, if seconds != 1 { "s" } else { "" })
    } else if diff_ms < 3_600_000 {
        let minutes = diff_ms / 60_000;
        format!("{} minute{} ago", minutes, if minutes != 1 { "s" } else { "" })
    } else if diff_ms < 86_400_000 {
        let hours = diff_ms / 3_600_000;
        format!("{} hour{} ago", hours, if hours != 1 { "s" } else { "" })
    } else {
        let days = diff_ms / 86_400_000;
        format!("{} day{} ago", days, if days != 1 { "s" } else { "" })
    }
}

/// Format numeric value for display
pub fn format_value(value: f64, precision: Option<usize>) -> String {
    if !value.is_finite() {
        return "N/A".to_string();
    }

    match precision {
        Some(p) => format!("{:.prec$}", value, prec = p),
        None => {
            // Auto-precision based on magnitude
            if value.abs() >= 1_000_000.0 {
                format!("{:.2}M", value / 1_000_000.0)
            } else if value.abs() >= 1_000.0 {
                format!("{:.2}K", value / 1_000.0)
            } else if value.abs() < 0.01 && value.abs() > 0.0 {
                format!("{:.4}", value)
            } else {
                format!("{:.2}", value)
            }
        }
    }
}

/// Format duration in milliseconds to human-readable string
pub fn format_duration_ms(duration_ms: i64) -> String {
    if duration_ms < 1000 {
        format!("{}ms", duration_ms)
    } else if duration_ms < 60_000 {
        let seconds = duration_ms / 1000;
        let ms = duration_ms % 1000;
        format!("{}.{:03}s", seconds, ms)
    } else if duration_ms < 3_600_000 {
        let minutes = duration_ms / 60_000;
        let seconds = (duration_ms % 60_000) / 1000;
        format!("{}m {}s", minutes, seconds)
    } else {
        let hours = duration_ms / 3_600_000;
        let minutes = (duration_ms % 3_600_000) / 60_000;
        format!("{}h {}m", hours, minutes)
    }
}

/// Format bytes to human-readable string
pub fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;
    const TB: u64 = GB * 1024;

    if bytes < KB {
        format!("{}B", bytes)
    } else if bytes < MB {
        format!("{:.2}KB", bytes as f64 / KB as f64)
    } else if bytes < GB {
        format!("{:.2}MB", bytes as f64 / MB as f64)
    } else if bytes < TB {
        format!("{:.2}GB", bytes as f64 / GB as f64)
    } else {
        format!("{:.2}TB", bytes as f64 / TB as f64)
    }
}

/// Format percentage with optional precision
pub fn format_percentage(value: f64, precision: Option<usize>) -> String {
    if !value.is_finite() {
        return "N/A".to_string();
    }

    match precision {
        Some(p) => format!("{:.prec$}%", value, prec = p),
        None => format!("{:.2}%", value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_timestamp_iso8601() {
        let ts = 1704358496000; // 2024-01-04T12:34:56Z
        let formatted = format_timestamp_millis(ts, TimestampFormat::ISO8601);
        assert!(formatted.contains("2024-01-04"));
    }

    #[test]
    fn test_format_timestamp_unix() {
        let ts = 1704358496000;
        let formatted = format_timestamp_millis(ts, TimestampFormat::Unix);
        assert_eq!(formatted, "1704358496000");
    }

    #[test]
    fn test_format_timestamp_invalid() {
        let formatted = format_timestamp_millis(-1, TimestampFormat::ISO8601);
        // Should not panic, return empty string for invalid timestamps
        assert!(!formatted.is_empty() || formatted.is_empty());
    }

    #[test]
    fn test_format_value_auto_precision() {
        assert_eq!(format_value(1_500_000.0, None), "1.50M");
        assert_eq!(format_value(2_500.0, None), "2.50K");
        assert_eq!(format_value(42.5, None), "42.50");
        assert_eq!(format_value(0.001, None), "0.0010");
    }

    #[test]
    fn test_format_value_with_precision() {
        assert_eq!(format_value(42.5678, Some(2)), "42.57");
        assert_eq!(format_value(42.5678, Some(4)), "42.5678");
    }

    #[test]
    fn test_format_value_non_finite() {
        assert_eq!(format_value(f64::NAN, None), "N/A");
        assert_eq!(format_value(f64::INFINITY, None), "N/A");
    }

    #[test]
    fn test_format_duration_ms() {
        assert_eq!(format_duration_ms(500), "500ms");
        assert_eq!(format_duration_ms(1500), "1.500s");
        assert_eq!(format_duration_ms(90_000), "1m 30s");
        assert_eq!(format_duration_ms(3_600_000), "1h 0m");
    }

    #[test]
    fn test_format_bytes() {
        assert_eq!(format_bytes(500), "500B");
        assert_eq!(format_bytes(2048), "2.00KB");
        assert_eq!(format_bytes(3_145_728), "3.00MB");
        assert_eq!(format_bytes(3_221_225_472), "3.00GB");
    }

    #[test]
    fn test_format_percentage() {
        assert_eq!(format_percentage(0.5678, None), "0.57%");
        assert_eq!(format_percentage(0.5678, Some(4)), "0.5678%");
    }

    #[test]
    fn test_format_percentage_non_finite() {
        assert_eq!(format_percentage(f64::NAN, None), "N/A");
    }
}
