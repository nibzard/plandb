//! Query execution engine for time-series aggregation.

use crate::analytics::aggregate::aggregate_window;
use crate::analytics::types::{
    FillStrategy, GroupBy, MultiSeriesTimeSeriesResult, TagFilter, TimeSeriesAggregate,
    TimeSeriesPoint, TimeSeriesQuery, TimeSeriesQueryResult, WindowType,
};
use crate::analytics::{generate_time_windows, TimeSeriesError, TimeSeriesResult as AnalyticsResult};
use std::collections::HashMap;

/// Execute time-series aggregation query on data points
pub fn execute_time_series_query(
    query: TimeSeriesQuery,
    data: &[TimeSeriesPoint],
) -> AnalyticsResult<TimeSeriesQueryResult> {
    // Validate query
    if query.end_time <= query.start_time {
        return Err(TimeSeriesError::InvalidTimeRange {
            start: query.start_time,
            end: query.end_time,
        });
    }

    // Filter data by time range and tag filters
    let filtered_data: Vec<&TimeSeriesPoint> = data
        .iter()
        .filter(|p| {
            p.timestamp >= query.start_time
                && p.timestamp < query.end_time
                && query.tag_filters.iter().all(|f| f.matches(p))
        })
        .collect();

    let total_points = filtered_data.len();

    // Generate time windows
    let windows = generate_time_windows(query.start_time, query.end_time, &query.window);
    let windows_generated = windows.len();

    // Apply aggregates for each window
    let mut aggregates = Vec::new();
    let mut empty_windows = 0;
    let mut previous_value: Option<f64> = None;

    for window in &windows {
        // Collect points in this window
        let window_points: Vec<&TimeSeriesPoint> = filtered_data
            .iter()
            .filter(|p| window.contains(p.timestamp))
            .cloned()
            .collect();

        // Compute aggregates for each function
        for function in &query.functions {
            let value = if window_points.is_empty() {
                empty_windows += 1;
                apply_fill_strategy(previous_value, &query.fill_strategy)
            } else {
                let points: Vec<TimeSeriesPoint> = window_points.iter().cloned().cloned().collect();
                let agg = aggregate_window(&points, function);
                previous_value = Some(agg);
                agg
            };

            // Skip if fill strategy is None and value is NaN
            if matches!(query.fill_strategy, FillStrategy::None) && value.is_nan() {
                continue;
            }

            // Merge tags from window points
            let merged_tags = window_points
                .iter()
                .flat_map(|p| p.tags.clone())
                .collect::<HashMap<_, _>>();

            aggregates.push(TimeSeriesAggregate {
                window: window.clone(),
                function: function.clone(),
                value,
                count: window_points.len(),
                tags: merged_tags,
            });
        }
    }

    // Apply limit
    if let Some(limit) = query.limit {
        aggregates.truncate(limit);
    }

    Ok(TimeSeriesQueryResult {
        aggregates,
        total_points,
        windows_generated,
        empty_windows,
        query,
    })
}

/// Determine aggregate value for empty window using fill strategy
pub fn apply_fill_strategy(previous_value: Option<f64>, strategy: &FillStrategy) -> f64 {
    match strategy {
        FillStrategy::None => f64::NAN,
        FillStrategy::Zero => 0.0,
        FillStrategy::Null => f64::NAN,
        FillStrategy::Previous => previous_value.unwrap_or(f64::NAN),
        FillStrategy::Linear => previous_value.unwrap_or(f64::NAN), // Full impl would interpolate
        FillStrategy::Fixed(v) => *v,
    }
}

/// Group data points by tag combinations for multi-series aggregation
pub fn group_by_tags(
    query: &TimeSeriesQuery,
    data: &[TimeSeriesPoint],
    group_by: &GroupBy,
) -> AnalyticsResult<HashMap<String, Vec<TimeSeriesPoint>>> {
    let mut grouped: HashMap<String, Vec<TimeSeriesPoint>> = HashMap::new();

    // Filter data by time range and tag filters first
    let filtered_data: Vec<&TimeSeriesPoint> = data
        .iter()
        .filter(|p| {
            p.timestamp >= query.start_time
                && p.timestamp < query.end_time
                && query.tag_filters.iter().all(|f| f.matches(p))
        })
        .collect();

    for point in filtered_data {
        // Determine group key
        let group_key = if group_by.all {
            // Use all tags
            let mut pairs: Vec<_> = point.tags.iter().collect();
            pairs.sort_by_key(|&(k, _)| k);
            pairs
                .iter()
                .map(|&(k, v)| format!("{}={}", k, v))
                .collect::<Vec<_>>()
                .join(",")
        } else {
            // Use specified tags
            group_by
                .tags
                .iter()
                .map(|tag| {
                    let value = point.tags.get(tag).map(|v| v.as_str()).unwrap_or("");
                    format!("{}={}", tag, value)
                })
                .collect::<Vec<_>>()
                .join(",")
        };

        grouped
            .entry(group_key)
            .or_insert_with(Vec::new)
            .push(point.clone());
    }

    Ok(grouped)
}

/// Execute time-series query with grouping by tag dimensions
pub fn execute_grouped_time_series_query(
    query: TimeSeriesQuery,
    data: &[TimeSeriesPoint],
    group_by: GroupBy,
) -> AnalyticsResult<MultiSeriesTimeSeriesResult> {
    // Group data by tags
    let grouped_data = group_by_tags(&query, data, &group_by)?;

    // Execute query for each group
    let mut series = HashMap::new();

    for (group_key, group_data) in grouped_data {
        // Clone the query for this group
        let group_query = query.clone();

        // Execute query on group data
        match execute_time_series_query(group_query, &group_data) {
            Ok(result) => {
                series.insert(group_key, result);
            }
            Err(e) => {
                return Err(e);
            }
        }
    }

    Ok(MultiSeriesTimeSeriesResult {
        series,
        group_by,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analytics::types::*;
    use std::collections::HashMap;

    fn make_point(timestamp: i64, value: f64) -> TimeSeriesPoint {
        TimeSeriesPoint::new(timestamp, value).unwrap()
    }

    fn make_tagged_point(timestamp: i64, value: f64, tags: HashMap<String, String>) -> TimeSeriesPoint {
        TimeSeriesPoint::with_tags(timestamp, value, tags).unwrap()
    }

    #[test]
    fn test_execute_simple_query() {
        let data = vec![
            make_point(0, 1.0),
            make_point(30000, 2.0),
            make_point(60000, 3.0),
            make_point(90000, 4.0),
        ];

        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let query = TimeSeriesQuery::new(0, 120000, window, vec![AggregateFunction::Sum]).unwrap();

        let result = execute_time_series_query(query, &data).unwrap();

        assert_eq!(result.total_points, 4);
        assert_eq!(result.windows_generated, 2);
        assert_eq!(result.aggregates.len(), 2);
        assert_eq!(result.aggregates[0].value, 3.0); // 1 + 2
        assert_eq!(result.aggregates[1].value, 7.0); // 3 + 4
    }

    #[test]
    fn test_execute_query_with_filter() {
        let mut tags1 = HashMap::new();
        tags1.insert("host".to_string(), "server1".to_string());
        let mut tags2 = HashMap::new();
        tags2.insert("host".to_string(), "server2".to_string());

        let data = vec![
            make_tagged_point(0, 1.0, tags1.clone()),
            make_tagged_point(30000, 2.0, tags1),
            make_tagged_point(60000, 3.0, tags2.clone()),
            make_tagged_point(90000, 4.0, tags2),
        ];

        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let tag_filter = TagFilter::new("host".to_string(), FilterOperator::Equal, "server1".to_string());
        let query = TimeSeriesQuery::new(0, 120000, window, vec![AggregateFunction::Sum])
            .unwrap()
            .with_tag_filter(tag_filter);

        let result = execute_time_series_query(query, &data).unwrap();

        assert_eq!(result.total_points, 2);
        assert_eq!(result.aggregates[0].value, 3.0); // Only server1 points
    }

    #[test]
    fn test_execute_query_with_fill_zero() {
        let data = vec![
            make_point(0, 1.0),
            make_point(60000, 3.0),
        ];

        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let query = TimeSeriesQuery::new(0, 180000, window, vec![AggregateFunction::Sum])
            .unwrap()
            .with_fill_strategy(FillStrategy::Zero);

        let result = execute_time_series_query(query, &data).unwrap();

        assert_eq!(result.aggregates.len(), 3);
        assert_eq!(result.aggregates[0].value, 1.0);
        assert_eq!(result.aggregates[1].value, 3.0);
        assert_eq!(result.aggregates[2].value, 0.0); // Empty window filled with zero
    }

    #[test]
    fn test_execute_query_with_limit() {
        let data = vec![
            make_point(0, 1.0),
            make_point(60000, 2.0),
            make_point(120000, 3.0),
        ];

        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let query = TimeSeriesQuery::new(0, 180000, window, vec![AggregateFunction::Sum])
            .unwrap()
            .with_limit(2);

        let result = execute_time_series_query(query, &data).unwrap();

        assert_eq!(result.aggregates.len(), 2);
    }

    #[test]
    fn test_group_by_tags() {
        let mut tags1 = HashMap::new();
        tags1.insert("host".to_string(), "server1".to_string());
        tags1.insert("region".to_string(), "us-east".to_string());
        let mut tags2 = HashMap::new();
        tags2.insert("host".to_string(), "server2".to_string());
        tags2.insert("region".to_string(), "us-west".to_string());

        let data = vec![
            make_tagged_point(0, 1.0, tags1.clone()),
            make_tagged_point(60000, 2.0, tags1),
            make_tagged_point(0, 3.0, tags2.clone()),
            make_tagged_point(60000, 4.0, tags2),
        ];

        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let query = TimeSeriesQuery::new(0, 120000, window, vec![AggregateFunction::Sum]).unwrap();
        let group_by = GroupBy::new(vec!["host".to_string()], false).unwrap();

        let grouped = group_by_tags(&query, &data, &group_by).unwrap();

        assert_eq!(grouped.len(), 2);
        assert!(grouped.contains_key("host=server1"));
        assert!(grouped.contains_key("host=server2"));
    }

    #[test]
    fn test_execute_grouped_query() {
        let mut tags1 = HashMap::new();
        tags1.insert("host".to_string(), "server1".to_string());
        let mut tags2 = HashMap::new();
        tags2.insert("host".to_string(), "server2".to_string());

        let data = vec![
            make_tagged_point(0, 1.0, tags1.clone()),
            make_tagged_point(60000, 2.0, tags1),
            make_tagged_point(0, 3.0, tags2.clone()),
            make_tagged_point(60000, 4.0, tags2),
        ];

        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let query = TimeSeriesQuery::new(0, 120000, window, vec![AggregateFunction::Sum]).unwrap();
        let group_by = GroupBy::new(vec!["host".to_string()], false).unwrap();

        let result = execute_grouped_time_series_query(query, &data, group_by).unwrap();

        assert_eq!(result.series.len(), 2);
    }

    #[test]
    fn test_execute_query_invalid_range() {
        let data = vec![make_point(0, 1.0)];

        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let query_result = TimeSeriesQuery::new(1000, 0, window, vec![AggregateFunction::Sum]);

        // Query construction should fail for invalid range
        assert!(query_result.is_err());
    }

    #[test]
    fn test_apply_fill_strategy() {
        assert_eq!(apply_fill_strategy(None, &FillStrategy::Zero), 0.0);
        assert!(apply_fill_strategy(None, &FillStrategy::Null).is_nan());
        assert_eq!(apply_fill_strategy(Some(5.0), &FillStrategy::Previous), 5.0);
        assert_eq!(apply_fill_strategy(None, &FillStrategy::Fixed(42.0)), 42.0);
    }

    #[test]
    fn test_execute_empty_query() {
        let data: Vec<TimeSeriesPoint> = vec![];

        let window = WindowType::Tumbling(TumblingWindow::new(60000, 0).unwrap());
        let query = TimeSeriesQuery::new(0, 120000, window, vec![AggregateFunction::Sum]).unwrap();

        let result = execute_time_series_query(query, &data).unwrap();

        assert_eq!(result.total_points, 0);
        assert_eq!(result.aggregates.len(), 0);
    }

    #[test]
    fn test_execute_sliding_window_query() {
        let data = vec![
            make_point(0, 1.0),
            make_point(30000, 2.0),
            make_point(60000, 3.0),
            make_point(90000, 4.0),
        ];

        let window = WindowType::Sliding(SlidingWindow::new(60000, 30000, 0).unwrap());
        let query = TimeSeriesQuery::new(0, 120000, window, vec![AggregateFunction::Sum]).unwrap();

        let result = execute_time_series_query(query, &data).unwrap();

        assert_eq!(result.windows_generated, 4);
    }
}
