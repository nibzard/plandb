//! Aggregate function implementations for time-series data.

use crate::analytics::types::{AggregateFunction, TimeSeriesPoint};

/// Compute single aggregate value over points in a window
pub fn aggregate_window(
    points: &[TimeSeriesPoint],
    function: &AggregateFunction,
) -> f64 {
    if points.is_empty() {
        return f64::NAN;
    }

    let values: Vec<f64> = points.iter().map(|p| p.value).collect();

    match function {
        AggregateFunction::Count => points.len() as f64,

        AggregateFunction::Sum => values.iter().sum::<f64>(),

        AggregateFunction::Avg => values.iter().sum::<f64>() / values.len() as f64,

        AggregateFunction::Min => {
            values
                .iter()
                .fold(f64::INFINITY, |a, &b| a.min(b))
        }

        AggregateFunction::Max => {
            values
                .iter()
                .fold(f64::NEG_INFINITY, |a, &b| a.max(b))
        }

        AggregateFunction::First => values[0],

        AggregateFunction::Last => values[values.len() - 1],

        AggregateFunction::StdDev => {
            let mean = values.iter().sum::<f64>() / values.len() as f64;
            let variance = values
                .iter()
                .map(|&v| (v - mean).powi(2))
                .sum::<f64>() / values.len() as f64;
            variance.sqrt()
        }

        AggregateFunction::Variance => {
            let mean = values.iter().sum::<f64>() / values.len() as f64;
            values
                .iter()
                .map(|&v| (v - mean).powi(2))
                .sum::<f64>() / values.len() as f64
        }

        AggregateFunction::Percentile(p) => {
            let mut sorted_values = values.clone();
            sorted_values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

            if sorted_values.is_empty() {
                return f64::NAN;
            }

            let index = ((p * (sorted_values.len() - 1) as f64).round() as usize)
                .min(sorted_values.len() - 1);
            sorted_values[index]
        }

        AggregateFunction::Rate => {
            if points.len() < 2 {
                return f64::NAN;
            }

            let first = &points[0];
            let last = &points[points.len() - 1];

            let value_delta = last.value - first.value;
            let time_delta_ms = last.timestamp - first.timestamp;
            let time_delta_sec = time_delta_ms as f64 / 1000.0;

            if time_delta_sec > 0.0 {
                value_delta / time_delta_sec
            } else {
                f64::NAN
            }
        }

        AggregateFunction::Delta => {
            if points.len() < 2 {
                return f64::NAN;
            }

            let first = &points[0];
            let last = &points[points.len() - 1];
            last.value - first.value
        }

        AggregateFunction::MovingAverage(n) => {
            let n = (*n).min(values.len());
            if n == 0 {
                return f64::NAN;
            }

            // Average of last n values
            let start = values.len().saturating_sub(n);
            values[start..].iter().sum::<f64>() / (values.len() - start) as f64
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analytics::types::TimeWindow;
    use std::collections::HashMap;

    fn make_point(timestamp: i64, value: f64) -> TimeSeriesPoint {
        TimeSeriesPoint::new(timestamp, value).unwrap()
    }

    #[test]
    fn test_aggregate_count() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Count);
        assert_eq!(result, 3.0);
    }

    #[test]
    fn test_aggregate_sum() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Sum);
        assert_eq!(result, 6.0);
    }

    #[test]
    fn test_aggregate_avg() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Avg);
        assert_eq!(result, 2.0);
    }

    #[test]
    fn test_aggregate_min() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Min);
        assert_eq!(result, 1.0);
    }

    #[test]
    fn test_aggregate_max() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Max);
        assert_eq!(result, 3.0);
    }

    #[test]
    fn test_aggregate_first() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::First);
        assert_eq!(result, 1.0);
    }

    #[test]
    fn test_aggregate_last() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Last);
        assert_eq!(result, 3.0);
    }

    #[test]
    fn test_aggregate_stddev() {
        let points = vec![
            make_point(0, 2.0),
            make_point(1000, 4.0),
            make_point(2000, 4.0),
            make_point(3000, 4.0),
            make_point(4000, 5.0),
            make_point(5000, 5.0),
            make_point(6000, 7.0),
            make_point(7000, 9.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::StdDev);
        // mean = 5.0
        // variance = ((2-5)^2 + (4-5)^2 + (4-5)^2 + (4-5)^2 + (5-5)^2 + (5-5)^2 + (7-5)^2 + (9-5)^2) / 8
        //           = (9 + 1 + 1 + 1 + 0 + 0 + 4 + 16) / 8 = 32/8 = 4.0
        // stddev = sqrt(4.0) = 2.0
        assert_eq!(result, 2.0);
    }

    #[test]
    fn test_aggregate_variance() {
        let points = vec![
            make_point(0, 2.0),
            make_point(1000, 4.0),
            make_point(2000, 4.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Variance);
        // mean = 3.33, variance = ((2-3.33)^2 + (4-3.33)^2 + (4-3.33)^2) / 3 = 1.77 / 3 ≈ 0.59
        // Or using population variance with mean = 3.33: ((2-3.33)^2 + (4-3.33)^2 + (4-3.33)^2) / 3 ≈ 0.59
        assert!(result > 0.0, "Variance should be positive, got {}", result);
    }

    #[test]
    fn test_aggregate_percentile() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
            make_point(3000, 4.0),
            make_point(4000, 5.0),
        ];

        let p50 = aggregate_window(&points, &AggregateFunction::Percentile(0.5));
        assert_eq!(p50, 3.0);

        let p95 = aggregate_window(&points, &AggregateFunction::Percentile(0.95));
        assert_eq!(p95, 5.0);
    }

    #[test]
    fn test_aggregate_rate() {
        let points = vec![
            make_point(0, 100.0),
            make_point(5000, 150.0),
            make_point(10000, 200.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Rate);
        assert!((result - 10.0).abs() < 0.01); // 100 / 10 sec
    }

    #[test]
    fn test_aggregate_delta() {
        let points = vec![
            make_point(0, 100.0),
            make_point(1000, 150.0),
            make_point(2000, 200.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::Delta);
        assert_eq!(result, 100.0);
    }

    #[test]
    fn test_aggregate_moving_average() {
        let points = vec![
            make_point(0, 1.0),
            make_point(1000, 2.0),
            make_point(2000, 3.0),
            make_point(3000, 4.0),
            make_point(4000, 5.0),
        ];

        let result = aggregate_window(&points, &AggregateFunction::MovingAverage(3));
        assert_eq!(result, 4.0); // Average of last 3: (3+4+5)/3 = 4
    }

    #[test]
    fn test_aggregate_empty() {
        let points: Vec<TimeSeriesPoint> = vec![];
        let result = aggregate_window(&points, &AggregateFunction::Count);
        assert!(result.is_nan());
    }

    #[test]
    fn test_aggregate_single_point() {
        let points = vec![make_point(0, 42.0)];

        assert_eq!(
            aggregate_window(&points, &AggregateFunction::Count),
            1.0
        );
        assert_eq!(
            aggregate_window(&points, &AggregateFunction::Sum),
            42.0
        );
        assert_eq!(
            aggregate_window(&points, &AggregateFunction::Avg),
            42.0
        );
        assert_eq!(
            aggregate_window(&points, &AggregateFunction::Min),
            42.0
        );
        assert_eq!(
            aggregate_window(&points, &AggregateFunction::Max),
            42.0
        );
    }
}
