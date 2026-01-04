//! Window generation and manipulation for time-series aggregation.

use crate::analytics::types::{
    CalendarUnit, CalendarWindow, FillStrategy, FilterOperator, GroupBy, MergeStrategy,
    SessionWindow, SlidingWindow, TagFilter, TimeSeriesPoint, TimeUnit, TimeWindow, TumblingWindow,
    WindowType,
};
use crate::analytics::{TimeSeriesError, TimeSeriesResult};
use chrono::{DateTime, Datelike, Timelike, TimeZone, Utc};
use std::collections::HashMap;

/// Generate sequence of time windows for aggregation
pub fn generate_time_windows(start: i64, end: i64, window: &WindowType) -> Vec<TimeWindow> {
    if end <= start {
        return Vec::new();
    }

    match window {
        WindowType::Tumbling(config) => generate_tumbling_windows(start, end, config),
        WindowType::Sliding(config) => generate_sliding_windows(start, end, config),
        WindowType::Session(_) => Vec::new(), // Sessions determined from data
        WindowType::Calendar(config) => generate_calendar_windows(start, end, config),
    }
}

/// Generate tumbling (fixed-size non-overlapping) windows
fn generate_tumbling_windows(start: i64, end: i64, config: &TumblingWindow) -> Vec<TimeWindow> {
    let mut windows = Vec::new();

    // Align start to offset
    let aligned_start = ((start - config.offset_ms + config.size_ms - 1) / config.size_ms)
        * config.size_ms
        + config.offset_ms;

    let mut current = aligned_start;

    while current < end {
        let window_end = (current + config.size_ms).min(end);
        if let Ok(window) = TimeWindow::new(current, window_end) {
            windows.push(window);
        }
        current += config.size_ms;
    }

    windows
}

/// Generate sliding (overlapping) windows
fn generate_sliding_windows(start: i64, end: i64, config: &SlidingWindow) -> Vec<TimeWindow> {
    let mut windows = Vec::new();

    // Align start to offset
    let aligned_start = ((start - config.offset_ms + config.slide_ms - 1) / config.slide_ms)
        * config.slide_ms
        + config.offset_ms;

    let mut current = aligned_start;

    while current + config.size_ms <= end || current < end {
        let window_end = (current + config.size_ms).min(end);
        if window_end > current {
            if let Ok(window) = TimeWindow::new(current, window_end) {
                windows.push(window);
            }
        }
        current += config.slide_ms;
    }

    windows
}

/// Generate calendar-aligned windows
fn generate_calendar_windows(start: i64, end: i64, config: &CalendarWindow) -> Vec<TimeWindow> {
    let mut windows = Vec::new();

    // Parse timezone (default to UTC for simplicity, full implementation would use chrono-tz)
    let timezone = &config.timezone;

    let mut current = match align_to_calendar(start, config.unit, timezone) {
        Ok(ts) => ts,
        Err(_) => return Vec::new(),
    };

    while current < end {
        let next = advance_calendar(current, config.unit, config.count);
        let window_end = next.min(end);

        if let Ok(window) = TimeWindow::new(current, window_end) {
            windows.push(window);
        }

        current = next;
        if current >= end {
            break;
        }
    }

    windows
}

/// Align timestamp to calendar boundary (floor to unit)
pub fn align_to_calendar(timestamp: i64, unit: CalendarUnit, timezone: &str) -> TimeSeriesResult<i64> {
    // For simplicity, using UTC. Full implementation would use chrono-tz for timezone support
    let dt = DateTime::<Utc>::from_timestamp_millis(timestamp)
        .ok_or_else(|| TimeSeriesError::ParseError("Invalid timestamp".to_string()))?;

    let aligned = match unit {
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

    Ok(aligned.timestamp_millis())
}

/// Advance calendar timestamp by given units
fn advance_calendar(timestamp: i64, unit: CalendarUnit, count: usize) -> i64 {
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

/// Detect sessions in time-series based on activity gaps
pub fn detect_sessions(data: &[TimeSeriesPoint], gap_ms: i64) -> Vec<Vec<TimeSeriesPoint>> {
    if data.is_empty() {
        return Vec::new();
    }

    let mut sessions = Vec::new();
    let mut current_session = vec![data[0].clone()];
    let mut last_timestamp = data[0].timestamp;

    for point in data.iter().skip(1) {
        let gap = point.timestamp - last_timestamp;

        if gap > gap_ms {
            // Start new session
            if !current_session.is_empty() {
                sessions.push(current_session);
            }
            current_session = vec![point.clone()];
        } else {
            current_session.push(point.clone());
        }

        last_timestamp = point.timestamp;
    }

    if !current_session.is_empty() {
        sessions.push(current_session);
    }

    sessions
}

/// Merge multiple time-series into single series
pub fn merge_series(
    series: &[Vec<TimeSeriesPoint>],
    merge_strategy: MergeStrategy,
) -> Vec<TimeSeriesPoint> {
    if series.is_empty() {
        return Vec::new();
    }

    // Collect all points
    let mut all_points: Vec<TimeSeriesPoint> = series.iter().flatten().cloned().collect();

    // Sort by timestamp
    all_points.sort_by_key(|p| p.timestamp);

    // Merge overlapping timestamps
    let mut merged = Vec::new();
    let mut i = 0;

    while i < all_points.len() {
        let current = &all_points[i];
        let mut j = i + 1;

        // Find all points with same timestamp
        while j < all_points.len() && all_points[j].timestamp == current.timestamp {
            j += 1;
        }

        if j == i + 1 {
            // No overlap
            merged.push(current.clone());
        } else {
            // Merge overlapping points
            let overlapping = &all_points[i..j];
            let merged_point = merge_overlapping_points(overlapping, merge_strategy);
            merged.push(merged_point);
        }

        i = j;
    }

    merged
}

/// Merge overlapping points with same timestamp
fn merge_overlapping_points(
    points: &[TimeSeriesPoint],
    strategy: MergeStrategy,
) -> TimeSeriesPoint {
    if points.len() == 1 {
        return points[0].clone();
    }

    let timestamp = points[0].timestamp;
    let values: Vec<f64> = points.iter().map(|p| p.value).collect();

    let merged_value = match strategy {
        MergeStrategy::First => values[0],
        MergeStrategy::Last => values[values.len() - 1],
        MergeStrategy::Avg => values.iter().sum::<f64>() / values.len() as f64,
        MergeStrategy::Sum => values.iter().sum::<f64>(),
        MergeStrategy::Min => values
            .iter()
            .fold(f64::INFINITY, |a, &b| a.min(b)),
        MergeStrategy::Max => values
            .iter()
            .fold(f64::NEG_INFINITY, |a, &b| a.max(b)),
    };

    // Merge tags (use first non-empty tags)
    let merged_tags = points
        .iter()
        .find(|p| !p.tags.is_empty())
        .map(|p| p.tags.clone())
        .unwrap_or_default();

    TimeSeriesPoint {
        timestamp,
        value: merged_value,
        tags: merged_tags,
    }
}

/// Downsample time-series to lower resolution by aggregating points
pub fn downsample_series(
    data: &[TimeSeriesPoint],
    target_interval_ms: i64,
    function: &crate::analytics::types::AggregateFunction,
) -> Vec<TimeSeriesPoint> {
    if data.is_empty() {
        return Vec::new();
    }

    let mut windows = generate_tumbling_windows(
        data[0].timestamp,
        data.last().unwrap().timestamp + target_interval_ms,
        &TumblingWindow::new(target_interval_ms, 0).unwrap(),
    );

    if windows.is_empty() {
        return Vec::new();
    }

    let mut downsampled = Vec::new();

    for window in &windows {
        // Collect points in this window
        let window_points: Vec<&TimeSeriesPoint> = data
            .iter()
            .filter(|p| window.contains(p.timestamp))
            .collect();

        if !window_points.is_empty() {
            // Compute aggregate
            let value = match function {
                crate::analytics::types::AggregateFunction::Avg => {
                    window_points.iter().map(|p| p.value).sum::<f64>() / window_points.len() as f64
                }
                crate::analytics::types::AggregateFunction::Sum => {
                    window_points.iter().map(|p| p.value).sum()
                }
                crate::analytics::types::AggregateFunction::Min => {
                    window_points.iter().map(|p| p.value).fold(f64::INFINITY, |a, b| a.min(b))
                }
                crate::analytics::types::AggregateFunction::Max => {
                    window_points.iter().map(|p| p.value).fold(f64::NEG_INFINITY, |a, b| a.max(b))
                }
                crate::analytics::types::AggregateFunction::First => window_points[0].value,
                crate::analytics::types::AggregateFunction::Last => window_points.last().unwrap().value,
                crate::analytics::types::AggregateFunction::Count => window_points.len() as f64,
                _ => f64::NAN,
            };

            // Merge tags
            let merged_tags = window_points
                .iter()
                .flat_map(|p| p.tags.clone())
                .collect::<HashMap<_, _>>();

            downsampled.push(TimeSeriesPoint {
                timestamp: window.end,
                value,
                tags: merged_tags,
            });
        }
    }

    downsampled
}

/// Compute rate of change (per second/minute/hour) for counter metrics
pub fn compute_rate(data: &[TimeSeriesPoint], unit: TimeUnit) -> Vec<TimeSeriesPoint> {
    if data.len() < 2 {
        return Vec::new();
    }

    let mut rates = Vec::new();

    for window in data.windows(2) {
        let prev = &window[0];
        let curr = &window[1];

        let value_delta = curr.value - prev.value;

        // Handle counter resets
        let value_delta = if value_delta < 0.0 {
            // Assume counter reset, use current value
            curr.value
        } else {
            value_delta
        };

        let time_delta_ms = curr.timestamp - prev.timestamp;
        let time_delta_sec = time_delta_ms as f64 / 1000.0;

        let rate = match unit {
            TimeUnit::Second => value_delta / time_delta_sec,
            TimeUnit::Minute => value_delta / (time_delta_sec / 60.0),
            TimeUnit::Hour => value_delta / (time_delta_sec / 3600.0),
        };

        rates.push(TimeSeriesPoint {
            timestamp: curr.timestamp,
            value: rate,
            tags: curr.tags.clone(),
        });
    }

    rates
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analytics::types::AggregateFunction;

    #[test]
    fn test_generate_tumbling_windows() {
        let config = TumblingWindow::new(60000, 0).unwrap();
        let windows = generate_tumbling_windows(0, 300000, &config);

        assert_eq!(windows.len(), 5);
        assert_eq!(windows[0].start, 0);
        assert_eq!(windows[0].end, 60000);
        assert_eq!(windows[4].start, 240000);
        assert_eq!(windows[4].end, 300000);
    }

    #[test]
    fn test_generate_sliding_windows() {
        let config = SlidingWindow::new(120000, 60000, 0).unwrap();
        let windows = generate_sliding_windows(0, 300000, &config);

        assert_eq!(windows.len(), 5);
        assert_eq!(windows[0].start, 0);
        assert_eq!(windows[0].end, 120000);
        assert_eq!(windows[4].start, 240000);
        assert_eq!(windows[4].end, 300000);
    }

    #[test]
    fn test_align_to_calendar_minute() {
        let timestamp = 1614556800000 + 35000; // 2021-03-01 00:00:35.000
        let aligned = align_to_calendar(timestamp, CalendarUnit::Minute, "UTC").unwrap();

        assert_eq!(aligned, 1614556800000); // Should floor to minute boundary
    }

    #[test]
    fn test_align_to_calendar_hour() {
        let timestamp = 1614556800000 + 123000; // 2021-03-01 00:02:03.000
        let aligned = align_to_calendar(timestamp, CalendarUnit::Hour, "UTC").unwrap();

        assert_eq!(aligned, 1614556800000); // Should floor to hour boundary
    }

    #[test]
    fn test_detect_sessions() {
        let data = vec![
            TimeSeriesPoint::new(0, 1.0).unwrap(),
            TimeSeriesPoint::new(1000, 2.0).unwrap(),
            TimeSeriesPoint::new(5000, 3.0).unwrap(), // Gap of 4000ms
            TimeSeriesPoint::new(6000, 4.0).unwrap(),
        ];

        let sessions = detect_sessions(&data, 2000);

        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].len(), 2);
        assert_eq!(sessions[1].len(), 2);
    }

    #[test]
    fn test_merge_series() {
        let series1 = vec![
            TimeSeriesPoint::new(0, 1.0).unwrap(),
            TimeSeriesPoint::new(2000, 3.0).unwrap(),
        ];

        let series2 = vec![
            TimeSeriesPoint::new(1000, 2.0).unwrap(),
            TimeSeriesPoint::new(2000, 4.0).unwrap(),
        ];

        let merged = merge_series(&[series1, series2], MergeStrategy::Last);

        assert_eq!(merged.len(), 3);
        assert_eq!(merged[0].timestamp, 0);
        assert_eq!(merged[1].timestamp, 1000);
        assert_eq!(merged[2].timestamp, 2000);
        assert_eq!(merged[2].value, 4.0); // Last value
    }

    #[test]
    fn test_downsample_series() {
        let data = vec![
            TimeSeriesPoint::new(0, 1.0).unwrap(),
            TimeSeriesPoint::new(30000, 2.0).unwrap(),
            TimeSeriesPoint::new(60000, 3.0).unwrap(),
            TimeSeriesPoint::new(90000, 4.0).unwrap(),
        ];

        let downsampled = downsample_series(&data, 60000, &AggregateFunction::Avg);

        assert_eq!(downsampled.len(), 2);
        assert_eq!(downsampled[0].value, 1.5); // Average of first 2
        assert_eq!(downsampled[1].value, 3.5); // Average of last 2
    }

    #[test]
    fn test_compute_rate_per_second() {
        let data = vec![
            TimeSeriesPoint::new(0, 100.0).unwrap(),
            TimeSeriesPoint::new(5000, 150.0).unwrap(),
            TimeSeriesPoint::new(10000, 200.0).unwrap(),
        ];

        let rates = compute_rate(&data, TimeUnit::Second);

        assert_eq!(rates.len(), 2);
        assert!((rates[0].value - 10.0).abs() < 0.01); // 50 / 5 sec
        assert!((rates[1].value - 10.0).abs() < 0.01); // 50 / 5 sec
    }
}
