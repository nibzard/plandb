//! Export Formats
//!
//! Metrics exposition in Prometheus, OpenTelemetry, and JSON formats.

use super::registry::{Metric, MetricType, MetricValue, HistogramData, SummaryData, Bucket, Quantile};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

/// Export format type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    /// Prometheus text-based exposition format
    Prometheus,
    /// OpenTelemetry protocol (OTLP)
    OpenTelemetry,
    /// JSON array of metric objects
    Json,
}

/// Configuration for monitoring system behavior.
#[derive(Debug, Clone)]
pub struct MonitoringConfig {
    /// Whether monitoring is enabled
    pub enabled: bool,
    /// How often to collect metrics
    pub scrape_interval: Duration,
    /// How long to keep metric history
    pub retention_period: Duration,
    /// Maximum number of metrics
    pub max_metrics: usize,
    /// Whether to collect histogram data
    pub enable_histograms: bool,
    /// Default histogram buckets for latency
    pub default_latency_buckets: Vec<u64>,
    /// Enforce max unique label values
    pub enable_label_cardinality_limit: bool,
    /// Maximum unique label combinations per metric
    pub max_cardinality: usize,
    /// Format for metric export
    pub export_format: ExportFormat,
}

impl Default for MonitoringConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            scrape_interval: Duration::from_secs(15),
            retention_period: Duration::from_secs(86400), // 24 hours
            max_metrics: 10000,
            enable_histograms: true,
            default_latency_buckets: vec![
                10, 50, 100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000,
            ],
            enable_label_cardinality_limit: true,
            max_cardinality: 1000,
            export_format: ExportFormat::Prometheus,
        }
    }
}

/// Export metrics in Prometheus text format.
pub fn export_prometheus(metrics: &[Metric]) -> String {
    let mut output = String::new();

    for metric in metrics {
        // Add HELP comment if description present
        if !metric.description.is_empty() {
            output.push_str(&format!("# HELP {} {}\n", metric.name, metric.description));
        }

        // Add TYPE comment
        let type_name = match metric.metric_type {
            MetricType::Counter => "counter",
            MetricType::Gauge => "gauge",
            MetricType::Histogram => "histogram",
            MetricType::Summary => "summary",
        };
        output.push_str(&format!("# TYPE {} {}\n", metric.name, type_name));

        // Format labels
        let label_str = format_labels(&metric.labels);

        // Add metric value
        match &metric.value {
            MetricValue::Counter(c) => {
                output.push_str(&format!("{}{} {}\n", metric.name, label_str, c.get()));
            }
            MetricValue::Gauge(g) => {
                output.push_str(&format!("{}{} {}\n", metric.name, label_str, g.get()));
            }
            MetricValue::Histogram(h) => {
                let data = h.get();

                // Count
                output.push_str(&format!(
                    "{}_count{} {}\n",
                    metric.name,
                    label_str,
                    data.count
                ));

                // Sum
                output.push_str(&format!(
                    "{}_sum{} {}\n",
                    metric.name,
                    label_str,
                    data.sum
                ));

                // Buckets
                for bucket in &data.buckets {
                    let bucket_label = format!("{}le=\"{}\"", label_str.trim_end_matches('}'), bucket.upper_bound);
                    output.push_str(&format!(
                        "{}_bucket{{{}}} {}\n",
                        metric.name,
                        bucket_label.trim_start_matches('{'),
                        bucket.count
                    ));
                }

                // +Inf bucket
                output.push_str(&format!(
                    "{}_bucket{{{}le=\"+Inf\"}} {}\n",
                    metric.name,
                    label_str.trim_end_matches('}'),
                    data.count
                ));
            }
            MetricValue::Summary(s) => {
                let data = s.get();

                // Count
                output.push_str(&format!(
                    "{}_count{} {}\n",
                    metric.name,
                    label_str,
                    data.count
                ));

                // Sum
                output.push_str(&format!(
                    "{}_sum{} {}\n",
                    metric.name,
                    label_str,
                    data.sum
                ));

                // Quantiles
                for quantile in &data.quantiles {
                    let quantile_label = format!("{}quantile=\"{}\"", label_str.trim_end_matches('}'), quantile.phi);
                    output.push_str(&format!(
                        "{}{{{}}} {}\n",
                        metric.name,
                        quantile_label.trim_start_matches('{'),
                        quantile.value
                    ));
                }
            }
        }

        output.push('\n');
    }

    output
}

/// Export metrics in JSON format.
pub fn export_json(metrics: &[Metric]) -> String {
    let mut output = String::from("[");

    for (i, metric) in metrics.iter().enumerate() {
        if i > 0 {
            output.push(',');
        }

        output.push_str(&json_metric(metric));
    }

    output.push(']');
    output
}

/// Format a single metric as JSON.
fn json_metric(metric: &Metric) -> String {
    let labels_str = if metric.labels.is_empty() {
        "null".to_string()
    } else {
        let labels: Vec<String> = metric
            .labels
            .iter()
            .map(|(k, v)| format!("\"{}\":\"{}\"", k, v))
            .collect();
        format!("{{{}}}", labels.join(","))
    };

    let value_str = match &metric.value {
        MetricValue::Counter(c) => format!(r#"{{"type":"counter","value":{}}}"#, c.get()),
        MetricValue::Gauge(g) => format!(r#"{{"type":"gauge","value":{}}}"#, g.get()),
        MetricValue::Histogram(h) => json_histogram(h.get()),
        MetricValue::Summary(s) => json_summary(s.get()),
    };

    format!(
        r#"{{"name":"{}","description":"{}","metric_type":{:?},"labels":{},"value":{}}}"#,
        metric.name, metric.description, metric.metric_type, labels_str, value_str
    )
}

/// Format histogram data as JSON.
fn json_histogram(data: HistogramData) -> String {
    let buckets: Vec<String> = data
        .buckets
        .iter()
        .map(|b| format!(r#"{{"upper_bound":{},"count":{}}}"#, b.upper_bound, b.count))
        .collect();

    format!(
        r#"{{"type":"histogram","count":{},"sum":{},"min":{},"max":{},"buckets":[{}]}}"#,
        data.count,
        data.sum,
        data.min,
        data.max,
        buckets.join(",")
    )
}

/// Format summary data as JSON.
fn json_summary(data: SummaryData) -> String {
    let quantiles: Vec<String> = data
        .quantiles
        .iter()
        .map(|q| format!(r#"{{"phi":{},"value":{}}}"#, q.phi, q.value))
        .collect();

    format!(
        r#"{{"type":"summary","count":{},"sum":{},"quantiles":[{}]}}"#,
        data.count,
        data.sum,
        quantiles.join(",")
    )
}

/// Format metric labels as Prometheus label string.
fn format_labels(labels: &HashMap<String, String>) -> String {
    if labels.is_empty() {
        return String::new();
    }

    let label_str: Vec<String> = labels
        .iter()
        .map(|(k, v)| format!("{}=\"{}\"", k, v))
        .collect();

    format!("{{{}}}", label_str.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::monitoring::registry::{Counter, Gauge, Histogram, Metric};

    #[test]
    fn test_format_labels_empty() {
        let labels = HashMap::new();
        assert_eq!(format_labels(&labels), "");
    }

    #[test]
    fn test_format_labels_single() {
        let mut labels = HashMap::new();
        labels.insert("operation".to_string(), "read".to_string());
        assert_eq!(format_labels(&labels), r#"{operation="read"}"#);
    }

    #[test]
    fn test_format_labels_multiple() {
        let mut labels = HashMap::new();
        labels.insert("operation".to_string(), "read".to_string());
        labels.insert("table".to_string(), "users".to_string());
        let result = format_labels(&labels);
        assert!(result.contains(r#"operation="read""#));
        assert!(result.contains(r#"table="users""#));
    }

    #[test]
    fn test_export_prometheus_counter() {
        let counter = Arc::new(Counter::new(42));
        let metric = Metric {
            name: "test_counter".to_string(),
            description: "Test counter".to_string(),
            metric_type: MetricType::Counter,
            labels: HashMap::new(),
            value: MetricValue::Counter(counter),
            created_at: std::time::Instant::now(),
            updated_at: std::time::Instant::now(),
        };

        let output = export_prometheus(&[metric]);

        assert!(output.contains("# HELP test_counter Test counter"));
        assert!(output.contains("# TYPE test_counter counter"));
        assert!(output.contains("test_counter 42"));
    }

    #[test]
    fn test_export_prometheus_gauge() {
        let gauge = Arc::new(Gauge::new(100));
        let metric = Metric {
            name: "test_gauge".to_string(),
            description: "Test gauge".to_string(),
            metric_type: MetricType::Gauge,
            labels: HashMap::new(),
            value: MetricValue::Gauge(gauge),
            created_at: std::time::Instant::now(),
            updated_at: std::time::Instant::now(),
        };

        let output = export_prometheus(&[metric]);

        assert!(output.contains("# TYPE test_gauge gauge"));
        assert!(output.contains("test_gauge 100"));
    }

    #[test]
    fn test_export_prometheus_histogram() {
        let histogram = Arc::new(Histogram::with_buckets(&[10, 50, 100]));
        histogram.observe(25);
        histogram.observe(75);

        let metric = Metric {
            name: "test_histogram".to_string(),
            description: "Test histogram".to_string(),
            metric_type: MetricType::Histogram,
            labels: HashMap::new(),
            value: MetricValue::Histogram(histogram),
            created_at: std::time::Instant::now(),
            updated_at: std::time::Instant::now(),
        };

        let output = export_prometheus(&[metric]);

        assert!(output.contains("# TYPE test_histogram histogram"));
        assert!(output.contains("test_histogram_count 2"));
        assert!(output.contains("test_histogram_sum 100"));
        assert!(output.contains("test_histogram_bucket"));
    }

    #[test]
    fn test_export_json_counter() {
        let counter = Arc::new(Counter::new(42));
        let metric = Metric {
            name: "test_counter".to_string(),
            description: "Test counter".to_string(),
            metric_type: MetricType::Counter,
            labels: HashMap::new(),
            value: MetricValue::Counter(counter),
            created_at: std::time::Instant::now(),
            updated_at: std::time::Instant::now(),
        };

        let output = export_json(&[metric]);

        assert!(output.contains(r#""name":"test_counter""#));
        assert!(output.contains(r#""type":"counter""#));
        assert!(output.contains(r#""value":42"#));
    }

    #[test]
    fn test_export_json_gauge() {
        let gauge = Arc::new(Gauge::new(100));
        let metric = Metric {
            name: "test_gauge".to_string(),
            description: "Test gauge".to_string(),
            metric_type: MetricType::Gauge,
            labels: HashMap::new(),
            value: MetricValue::Gauge(gauge),
            created_at: std::time::Instant::now(),
            updated_at: std::time::Instant::now(),
        };

        let output = export_json(&[metric]);

        assert!(output.contains(r#""name":"test_gauge""#));
        assert!(output.contains(r#""type":"gauge""#));
        assert!(output.contains(r#""value":100"#));
    }

    #[test]
    fn test_monitoring_config_default() {
        let config = MonitoringConfig::default();

        assert!(config.enabled);
        assert_eq!(config.scrape_interval, Duration::from_secs(15));
        assert_eq!(config.max_metrics, 10000);
        assert!(config.enable_histograms);
        assert_eq!(config.export_format, ExportFormat::Prometheus);
    }
}
