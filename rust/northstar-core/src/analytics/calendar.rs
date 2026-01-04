//! Calendar-aligned window utilities.

//! This module provides helper functions for working with calendar-aligned time windows,
//! including timezone handling and calendar arithmetic.

use crate::analytics::types::CalendarUnit;
use crate::analytics::{TimeSeriesError, TimeSeriesResult};
use chrono::{DateTime, Datelike, Timelike, TimeZone, Utc};

/// Get the start of a calendar period for a given timestamp
pub fn get_period_start(
    timestamp: i64,
    unit: CalendarUnit,
    timezone: &str,
) -> TimeSeriesResult<i64> {
    // For simplicity, using UTC. Full implementation would use chrono-tz
    let _ = timezone; // Would be used for timezone-aware calculations

    let dt = DateTime::<Utc>::from_timestamp_millis(timestamp)
        .ok_or_else(|| TimeSeriesError::ParseError("Invalid timestamp".to_string()))?;

    let start = match unit {
        CalendarUnit::Minute => {
            dt.with_second(0)
                .and_then(|d| d.with_nanosecond(0))
                .ok_or_else(|| TimeSeriesError::InvalidCalendarUnit("Minute".to_string()))?
        }
        CalendarUnit::Hour => dt
            .with_minute(0)
            .and_then(|d| d.with_second(0))
            .and_then(|d| d.with_nanosecond(0))
            .ok_or_else(|| TimeSeriesError::InvalidCalendarUnit("Hour".to_string()))?,
        CalendarUnit::Day => dt
            .with_hour(0)
            .and_then(|d| d.with_minute(0))
            .and_then(|d| d.with_second(0))
            .and_then(|d| d.with_nanosecond(0))
            .ok_or_else(|| TimeSeriesError::InvalidCalendarUnit("Day".to_string()))?,
        CalendarUnit::Week => {
            // Floor to Monday
            let weekday = dt.weekday().num_days_from_monday();
            dt.with_hour(0)
                .and_then(|d| d.with_minute(0))
                .and_then(|d| d.with_second(0))
                .and_then(|d| d.with_nanosecond(0))
                .and_then(|d| {
                    Some(DateTime::from_timestamp(d.timestamp() - weekday as i64 * 86400, 0).unwrap())
                })
                .ok_or_else(|| TimeSeriesError::InvalidCalendarUnit("Week".to_string()))?
        }
        CalendarUnit::Month => dt
            .with_day(1)
            .and_then(|d| d.with_hour(0))
            .and_then(|d| d.with_minute(0))
            .and_then(|d| d.with_second(0))
            .and_then(|d| d.with_nanosecond(0))
            .ok_or_else(|| TimeSeriesError::InvalidCalendarUnit("Month".to_string()))?,
        CalendarUnit::Quarter => {
            let quarter_start_month = ((dt.month() - 1) / 3) * 3 + 1;
            dt.with_month(quarter_start_month)
                .and_then(|d| d.with_day(1))
                .and_then(|d| d.with_hour(0))
                .and_then(|d| d.with_minute(0))
                .and_then(|d| d.with_second(0))
                .and_then(|d| d.with_nanosecond(0))
                .ok_or_else(|| TimeSeriesError::InvalidCalendarUnit("Quarter".to_string()))?
        }
        CalendarUnit::Year => dt
            .with_month(1)
            .and_then(|d| d.with_day(1))
            .and_then(|d| d.with_hour(0))
            .and_then(|d| d.with_minute(0))
            .and_then(|d| d.with_second(0))
            .and_then(|d| d.with_nanosecond(0))
            .ok_or_else(|| TimeSeriesError::InvalidCalendarUnit("Year".to_string()))?,
    };

    Ok(start.timestamp_millis())
}

/// Add calendar units to a timestamp
pub fn add_period(timestamp: i64, unit: CalendarUnit, count: usize) -> i64 {
    let dt = DateTime::<Utc>::from_timestamp_millis(timestamp).unwrap_or_default();

    match unit {
        CalendarUnit::Minute => dt + chrono::Duration::minutes(count as i64),
        CalendarUnit::Hour => dt + chrono::Duration::hours(count as i64),
        CalendarUnit::Day => dt + chrono::Duration::days(count as i64),
        CalendarUnit::Week => dt + chrono::Duration::weeks(count as i64),
        CalendarUnit::Month => {
            // Add months (approximate)
            let total_months = dt.month() as i32 + count as i32 - 1;
            let year = dt.year() + total_months / 12;
            let month = (total_months % 12) + 1;
            dt.with_month(month as u32)
                .and_then(|d| d.with_year(year))
                .unwrap_or(dt)
        }
        CalendarUnit::Quarter => {
            let total_quarters = (dt.month() - 1) as i32 / 3 + count as i32;
            let year = dt.year() + total_quarters / 4;
            let month = ((total_quarters % 4) * 3 + 1) as u32;
            dt.with_month(month)
                .and_then(|d| d.with_year(year))
                .unwrap_or(dt)
        }
        CalendarUnit::Year => dt.with_year(dt.year() + count as i32).unwrap_or(dt),
    }
    .timestamp_millis()
}

/// Validate IANA timezone string
pub fn validate_timezone(timezone: &str) -> TimeSeriesResult<()> {
    // Full implementation would use chrono-tz to validate
    // For now, just check basic format
    if timezone.is_empty() {
        return Err(TimeSeriesError::InvalidTimezone {
            timezone: timezone.to_string(),
        });
    }

    // Accept UTC and common timezones
    if timezone == "UTC" || timezone == "GMT" {
        return Ok(());
    }

    // Check for IANA format (Region/City)
    if timezone.contains('/') {
        let parts: Vec<&str> = timezone.split('/').collect();
        if parts.len() >= 2 {
            return Ok(());
        }
    }

    // For other timezones, assume valid (full impl would use chrono-tz)
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_period_start_minute() {
        let timestamp = 1614556800000 + 35000; // 2021-03-01 00:00:35.000
        let start = get_period_start(timestamp, CalendarUnit::Minute, "UTC").unwrap();

        assert_eq!(start, 1614556800000);
    }

    #[test]
    fn test_get_period_start_hour() {
        let timestamp = 1614556800000 + 123000; // 2021-03-01 00:02:03.000
        let start = get_period_start(timestamp, CalendarUnit::Hour, "UTC").unwrap();

        assert_eq!(start, 1614556800000);
    }

    #[test]
    fn test_get_period_start_day() {
        let timestamp = 1614556800000 + 3600000 * 5 + 123000; // 2021-03-01 05:02:03.000
        let start = get_period_start(timestamp, CalendarUnit::Day, "UTC").unwrap();

        assert_eq!(start, 1614556800000); // Should floor to midnight
    }

    #[test]
    fn test_add_period_minutes() {
        let timestamp = 1614556800000; // 2021-03-01 00:00:00.000
        let result = add_period(timestamp, CalendarUnit::Minute, 5);

        assert_eq!(result, 1614556800000 + 300000);
    }

    #[test]
    fn test_add_period_hours() {
        let timestamp = 1614556800000; // 2021-03-01 00:00:00.000
        let result = add_period(timestamp, CalendarUnit::Hour, 2);

        assert_eq!(result, 1614556800000 + 7200000);
    }

    #[test]
    fn test_add_period_days() {
        let timestamp = 1614556800000; // 2021-03-01 00:00:00.000
        let result = add_period(timestamp, CalendarUnit::Day, 7);

        assert_eq!(result, 1614556800000 + 86400000 * 7);
    }

    #[test]
    fn test_validate_timezone_utc() {
        assert!(validate_timezone("UTC").is_ok());
        assert!(validate_timezone("GMT").is_ok());
    }

    #[test]
    fn test_validate_timezone_iana() {
        assert!(validate_timezone("America/New_York").is_ok());
        assert!(validate_timezone("Europe/London").is_ok());
    }

    #[test]
    fn test_validate_timezone_empty() {
        assert!(validate_timezone("").is_err());
    }
}
