//! Metric Registry and Types
//!
//! Centralized metric storage with thread-safe concurrent access.

use super::{MonitoringConfig, ExportFormat};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use parking_lot::RwLock;
use regex::Regex;
use std::sync::OnceLock;

/// Metric type enumeration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MetricType {
    /// Monotonically increasing value (e.g., total operations, bytes read)
    Counter,
    /// Current value that can increase or decrease (e.g., active connections, memory usage)
    Gauge,
    /// Distribution of values (e.g., request latencies, row counts)
    Histogram,
    /// Count and sum with optional quantiles (e.g., query durations)
    Summary,
}

/// Metric value wrapper.
#[derive(Debug, Clone)]
pub enum MetricValue {
    Counter(Arc<Counter>),
    Gauge(Arc<Gauge>),
    Histogram(Arc<Histogram>),
    Summary(Arc<Summary>),
}

/// Generic metric metadata and value.
#[derive(Debug, Clone)]
pub struct Metric {
    /// Unique metric identifier
    pub name: String,
    /// Human-readable description
    pub description: String,
    /// Type of metric
    pub metric_type: MetricType,
    /// Key-value pairs for dimensionality
    pub labels: HashMap<String, String>,
    /// Current value
    pub value: MetricValue,
    /// When metric was first registered
    pub created_at: Instant,
    /// When metric was last updated
    pub updated_at: Instant,
}

/// Counter metric - monotonically increasing value.
#[derive(Debug)]
pub struct Counter {
    inner: Arc<CounterInner>,
}

#[derive(Debug)]
struct CounterInner {
    value: AtomicU64,
    updated_at: RwLock<Instant>,
}

impl Clone for Counter {
    fn clone(&self) -> Self {
        Self { inner: Arc::clone(&self.inner) }
    }
}

impl Counter {
    /// Create a new counter with initial value.
    pub fn new(initial: u64) -> Self {
        Self {
            inner: Arc::new(CounterInner {
                value: AtomicU64::new(initial),
                updated_at: RwLock::new(Instant::now()),
            }),
        }
    }

    /// Increment the counter by a value.
    pub fn inc(&self, value: u64) {
        self.inner.value.fetch_add(value, Ordering::Relaxed);
        *self.inner.updated_at.write() = Instant::now();
    }

    /// Get the current counter value.
    pub fn get(&self) -> u64 {
        self.inner.value.load(Ordering::Relaxed)
    }

    /// Get the last update time.
    pub fn updated_at(&self) -> Instant {
        *self.inner.updated_at.read()
    }
}

/// Gauge metric - current value that can increase or decrease.
#[derive(Debug)]
pub struct Gauge {
    inner: Arc<GaugeInner>,
}

#[derive(Debug)]
struct GaugeInner {
    value: AtomicI64,
    updated_at: RwLock<Instant>,
}

impl Clone for Gauge {
    fn clone(&self) -> Self {
        Self { inner: Arc::clone(&self.inner) }
    }
}

impl Gauge {
    /// Create a new gauge with initial value.
    pub fn new(initial: i64) -> Self {
        Self {
            inner: Arc::new(GaugeInner {
                value: AtomicI64::new(initial),
                updated_at: RwLock::new(Instant::now()),
            }),
        }
    }

    /// Set the gauge to a specific value.
    pub fn set(&self, value: i64) {
        self.inner.value.store(value, Ordering::Relaxed);
        *self.inner.updated_at.write() = Instant::now();
    }

    /// Increment the gauge by a value.
    pub fn inc(&self, value: i64) {
        self.inner.value.fetch_add(value, Ordering::Relaxed);
        *self.inner.updated_at.write() = Instant::now();
    }

    /// Decrement the gauge by a value.
    pub fn dec(&self, value: i64) {
        self.inner.value.fetch_sub(value, Ordering::Relaxed);
        *self.inner.updated_at.write() = Instant::now();
    }

    /// Get the current gauge value.
    pub fn get(&self) -> i64 {
        self.inner.value.load(Ordering::Relaxed)
    }

    /// Get the last update time.
    pub fn updated_at(&self) -> Instant {
        *self.inner.updated_at.read()
    }
}

/// Histogram bucket with count.
#[derive(Debug, Clone)]
pub struct Bucket {
    /// Upper bound of this bucket (inclusive)
    pub upper_bound: u64,
    /// Number of observations <= upper_bound
    pub count: u64,
}

/// Histogram data with configurable buckets.
#[derive(Debug, Clone)]
pub struct HistogramData {
    /// Total number of observations
    pub count: u64,
    /// Sum of all observed values
    pub sum: u64,
    /// Pre-configured buckets with counts
    pub buckets: Vec<Bucket>,
    /// Minimum observed value
    pub min: u64,
    /// Maximum observed value
    pub max: u64,
}

/// Histogram metric - distribution of values.
#[derive(Debug)]
pub struct Histogram {
    inner: Arc<HistogramInner>,
}

#[derive(Debug)]
struct HistogramInner {
    count: AtomicU64,
    sum: AtomicU64,
    buckets: Vec<BucketEntry>,
    min: AtomicU64,
    max: AtomicU64,
    updated_at: RwLock<Instant>,
}

#[derive(Debug)]
struct BucketEntry {
    upper_bound: u64,
    count: AtomicU64,
}

impl Clone for Histogram {
    fn clone(&self) -> Self {
        Self { inner: Arc::clone(&self.inner) }
    }
}

impl Histogram {
    /// Create a new histogram with default buckets.
    pub fn new() -> Self {
        Self::with_buckets(&MonitoringConfig::default().default_latency_buckets)
    }

    /// Create a new histogram with custom buckets.
    pub fn with_buckets(buckets: &[u64]) -> Self {
        let bucket_entries = buckets.iter().map(|&b| BucketEntry {
            upper_bound: b,
            count: AtomicU64::new(0),
        }).collect();

        Self {
            inner: Arc::new(HistogramInner {
                count: AtomicU64::new(0),
                sum: AtomicU64::new(0),
                buckets: bucket_entries,
                min: AtomicU64::new(u64::MAX),
                max: AtomicU64::new(0),
                updated_at: RwLock::new(Instant::now()),
            }),
        }
    }

    /// Record a value observation.
    pub fn observe(&self, value: u64) {
        self.inner.count.fetch_add(1, Ordering::Relaxed);
        self.inner.sum.fetch_add(value, Ordering::Relaxed);

        // Update min
        let mut current_min = self.inner.min.load(Ordering::Relaxed);
        while value < current_min {
            match self.inner.min.compare_exchange_weak(
                current_min, value, Ordering::Relaxed, Ordering::Relaxed
            ) {
                Ok(_) => break,
                Err(new_min) => current_min = new_min,
            }
        }

        // Update max
        let mut current_max = self.inner.max.load(Ordering::Relaxed);
        while value > current_max {
            match self.inner.max.compare_exchange_weak(
                current_max, value, Ordering::Relaxed, Ordering::Relaxed
            ) {
                Ok(_) => break,
                Err(new_max) => current_max = new_max,
            }
        }

        // Update buckets
        for bucket in &self.inner.buckets {
            if value <= bucket.upper_bound {
                bucket.count.fetch_add(1, Ordering::Relaxed);
            }
        }

        *self.inner.updated_at.write() = Instant::now();
    }

    /// Get the current histogram data.
    pub fn get(&self) -> HistogramData {
        let count = self.inner.count.load(Ordering::Relaxed);
        let sum = self.inner.sum.load(Ordering::Relaxed);
        let min = self.inner.min.load(Ordering::Relaxed);
        let max = self.inner.max.load(Ordering::Relaxed);

        let buckets = self.inner.buckets.iter().map(|b| Bucket {
            upper_bound: b.upper_bound,
            count: b.count.load(Ordering::Relaxed),
        }).collect();

        HistogramData { count, sum, buckets, min, max }
    }

    /// Get the last update time.
    pub fn updated_at(&self) -> Instant {
        *self.inner.updated_at.read()
    }
}

/// Quantile with value.
#[derive(Debug, Clone)]
pub struct Quantile {
    /// Quantile rank (0.0 to 1.0)
    pub phi: f64,
    /// Computed quantile value
    pub value: u64,
}

/// Summary data with quantiles.
#[derive(Debug, Clone)]
pub struct SummaryData {
    /// Total number of observations
    pub count: u64,
    /// Sum of all observed values
    pub sum: u64,
    /// Pre-configured quantiles with values
    pub quantiles: Vec<Quantile>,
}

/// Summary metric - count and sum with quantiles.
#[derive(Debug)]
pub struct Summary {
    inner: Arc<SummaryInner>,
}

#[derive(Debug)]
struct SummaryInner {
    count: AtomicU64,
    sum: AtomicU64,
    quantiles: Vec<QuantileEntry>,
    updated_at: RwLock<Instant>,
}

#[derive(Debug)]
struct QuantileEntry {
    phi: f64,
    value: AtomicU64,
}

impl Clone for Summary {
    fn clone(&self) -> Self {
        Self { inner: Arc::clone(&self.inner) }
    }
}

impl Summary {
    /// Create a new summary with default quantiles.
    pub fn new() -> Self {
        Self::with_quantiles(&[0.5, 0.9, 0.95, 0.99])
    }

    /// Create a new summary with custom quantiles.
    pub fn with_quantiles(quantiles: &[f64]) -> Self {
        let quantile_entries = quantiles.iter().map(|&q| QuantileEntry {
            phi: q,
            value: AtomicU64::new(0),
        }).collect();

        Self {
            inner: Arc::new(SummaryInner {
                count: AtomicU64::new(0),
                sum: AtomicU64::new(0),
                quantiles: quantile_entries,
                updated_at: RwLock::new(Instant::now()),
            }),
        }
    }

    /// Observe a value (simplified - updates all quantiles).
    pub fn observe(&self, value: u64) {
        self.inner.count.fetch_add(1, Ordering::Relaxed);
        self.inner.sum.fetch_add(value, Ordering::Relaxed);

        // Update all quantiles (simplified approach)
        for quantile in &self.inner.quantiles {
            quantile.value.store(value, Ordering::Relaxed);
        }

        *self.inner.updated_at.write() = Instant::now();
    }

    /// Get the current summary data.
    pub fn get(&self) -> SummaryData {
        let count = self.inner.count.load(Ordering::Relaxed);
        let sum = self.inner.sum.load(Ordering::Relaxed);

        let quantiles = self.inner.quantiles.iter().map(|q| Quantile {
            phi: q.phi,
            value: q.value.load(Ordering::Relaxed),
        }).collect();

        SummaryData { count, sum, quantiles }
    }

    /// Get the last update time.
    pub fn updated_at(&self) -> Instant {
        *self.inner.updated_at.read()
    }
}

/// Error types for metric registration.
#[derive(Debug, thiserror::Error)]
pub enum MetricError {
    #[error("Metric with name '{0}' already exists")]
    MetricExists(String),
    #[error("Invalid metric name '{0}': must match ^[a-z_][a-z0-9_]*$")]
    InvalidName(String),
    #[error("Registry full: maximum {0} metrics reached")]
    RegistryFull(usize),
    #[error("Invalid buckets: must be sorted in ascending order")]
    InvalidBuckets,
}

/// Central metric registry.
pub struct MetricRegistry {
    metrics: RwLock<HashMap<String, Metric>>,
    config: MonitoringConfig,
    scrape_count: AtomicU64,
}

impl MetricRegistry {
    /// Create a new metric registry.
    pub fn new(config: MonitoringConfig) -> Self {
        Self {
            metrics: RwLock::new(HashMap::new()),
            config,
            scrape_count: AtomicU64::new(0),
        }
    }

    /// Validate metric name format.
    fn validate_name(name: &str) -> Result<(), MetricError> {
        static NAME_REGEX: OnceLock<Regex> = OnceLock::new();
        let regex = NAME_REGEX.get_or_init(|| {
            Regex::new(r"^[a-z_][a-z0-9_]*$").unwrap()
        });

        if !regex.is_match(name) {
            return Err(MetricError::InvalidName(name.to_string()));
        }
        Ok(())
    }

    /// Register a counter metric.
    pub fn register_counter(
        &self,
        name: String,
        description: String,
        labels: HashMap<String, String>,
    ) -> Result<Arc<Counter>, MetricError> {
        Self::validate_name(&name)?;

        let mut metrics = self.metrics.write();
        if metrics.len() >= self.config.max_metrics {
            return Err(MetricError::RegistryFull(self.config.max_metrics));
        }

        if metrics.contains_key(&name) {
            return Err(MetricError::MetricExists(name));
        }

        let counter = Arc::new(Counter::new(0));
        let now = Instant::now();

        metrics.insert(name.clone(), Metric {
            name: name.clone(),
            description,
            metric_type: MetricType::Counter,
            labels,
            value: MetricValue::Counter(Arc::clone(&counter)),
            created_at: now,
            updated_at: now,
        });

        Ok(counter)
    }

    /// Register a gauge metric.
    pub fn register_gauge(
        &self,
        name: String,
        description: String,
        labels: HashMap<String, String>,
    ) -> Result<Arc<Gauge>, MetricError> {
        Self::validate_name(&name)?;

        let mut metrics = self.metrics.write();
        if metrics.len() >= self.config.max_metrics {
            return Err(MetricError::RegistryFull(self.config.max_metrics));
        }

        if metrics.contains_key(&name) {
            return Err(MetricError::MetricExists(name));
        }

        let gauge = Arc::new(Gauge::new(0));
        let now = Instant::now();

        metrics.insert(name.clone(), Metric {
            name: name.clone(),
            description,
            metric_type: MetricType::Gauge,
            labels,
            value: MetricValue::Gauge(Arc::clone(&gauge)),
            created_at: now,
            updated_at: now,
        });

        Ok(gauge)
    }

    /// Register a histogram metric.
    pub fn register_histogram(
        &self,
        name: String,
        description: String,
        labels: HashMap<String, String>,
        buckets: Option<Vec<u64>>,
    ) -> Result<Arc<Histogram>, MetricError> {
        Self::validate_name(&name)?;

        let mut metrics = self.metrics.write();
        if metrics.len() >= self.config.max_metrics {
            return Err(MetricError::RegistryFull(self.config.max_metrics));
        }

        if metrics.contains_key(&name) {
            return Err(MetricError::MetricExists(name));
        }

        let bucket_bounds = buckets.unwrap_or_else(|| self.config.default_latency_buckets.clone());

        // Validate buckets are sorted
        for i in 1..bucket_bounds.len() {
            if bucket_bounds[i] <= bucket_bounds[i - 1] {
                return Err(MetricError::InvalidBuckets);
            }
        }

        let histogram = Arc::new(Histogram::with_buckets(&bucket_bounds));
        let now = Instant::now();

        metrics.insert(name.clone(), Metric {
            name: name.clone(),
            description,
            metric_type: MetricType::Histogram,
            labels,
            value: MetricValue::Histogram(Arc::clone(&histogram)),
            created_at: now,
            updated_at: now,
        });

        Ok(histogram)
    }

    /// Register a summary metric.
    pub fn register_summary(
        &self,
        name: String,
        description: String,
        labels: HashMap<String, String>,
    ) -> Result<Arc<Summary>, MetricError> {
        Self::validate_name(&name)?;

        let mut metrics = self.metrics.write();
        if metrics.len() >= self.config.max_metrics {
            return Err(MetricError::RegistryFull(self.config.max_metrics));
        }

        if metrics.contains_key(&name) {
            return Err(MetricError::MetricExists(name));
        }

        let summary = Arc::new(Summary::new());
        let now = Instant::now();

        metrics.insert(name.clone(), Metric {
            name: name.clone(),
            description,
            metric_type: MetricType::Summary,
            labels,
            value: MetricValue::Summary(Arc::clone(&summary)),
            created_at: now,
            updated_at: now,
        });

        Ok(summary)
    }

    /// Get all metrics.
    pub fn get_all(&self) -> Vec<Metric> {
        let metrics = self.metrics.read();
        metrics.values().cloned().collect()
    }

    /// Get the number of scrape operations performed.
    pub fn scrape_count(&self) -> u64 {
        self.scrape_count.load(Ordering::Relaxed)
    }

    /// Increment the scrape counter.
    pub fn inc_scrape_count(&self) {
        self.scrape_count.fetch_add(1, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_counter_increment() {
        let counter = Counter::new(0);
        assert_eq!(counter.get(), 0);

        counter.inc(5);
        assert_eq!(counter.get(), 5);

        counter.inc(10);
        assert_eq!(counter.get(), 15);
    }

    #[test]
    fn test_gauge_set() {
        let gauge = Gauge::new(0);
        assert_eq!(gauge.get(), 0);

        gauge.set(100);
        assert_eq!(gauge.get(), 100);

        gauge.inc(50);
        assert_eq!(gauge.get(), 150);

        gauge.dec(25);
        assert_eq!(gauge.get(), 125);
    }

    #[test]
    fn test_histogram_observe() {
        let histogram = Histogram::new();

        histogram.observe(100);
        histogram.observe(500);
        histogram.observe(1000);

        let data = histogram.get();
        assert_eq!(data.count, 3);
        assert_eq!(data.sum, 1600);
        assert_eq!(data.min, 100);
        assert_eq!(data.max, 1000);
    }

    #[test]
    fn test_registry_register_counter() {
        let config = MonitoringConfig::default();
        let registry = MetricRegistry::new(config);

        let counter = registry.register_counter(
            "test_counter".to_string(),
            "Test counter".to_string(),
            HashMap::new(),
        ).unwrap();

        counter.inc(42);
        assert_eq!(counter.get(), 42);
    }

    #[test]
    fn test_registry_duplicate_metric() {
        let config = MonitoringConfig::default();
        let registry = MetricRegistry::new(config);

        registry.register_counter(
            "test_counter".to_string(),
            "Test counter".to_string(),
            HashMap::new(),
        ).unwrap();

        let result = registry.register_counter(
            "test_counter".to_string(),
            "Duplicate".to_string(),
            HashMap::new(),
        );

        assert!(matches!(result, Err(MetricError::MetricExists(_))));
    }

    #[test]
    fn test_registry_invalid_name() {
        let config = MonitoringConfig::default();
        let registry = MetricRegistry::new(config);

        let result = registry.register_counter(
            "Invalid-Name".to_string(),
            "Invalid name".to_string(),
            HashMap::new(),
        );

        assert!(matches!(result, Err(MetricError::InvalidName(_))));
    }

    #[test]
    fn test_histogram_buckets() {
        let histogram = Histogram::with_buckets(&[10, 50, 100]);

        histogram.observe(5);
        histogram.observe(25);
        histogram.observe(75);

        let data = histogram.get();
        assert_eq!(data.count, 3);

        // First bucket (<=10) should have 1 observation
        assert_eq!(data.buckets[0].count, 1);

        // Second bucket (<=50) should have 2 observations
        assert_eq!(data.buckets[1].count, 2);

        // Third bucket (<=100) should have 3 observations
        assert_eq!(data.buckets[2].count, 3);
    }
}
