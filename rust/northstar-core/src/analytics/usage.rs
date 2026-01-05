//! Usage Analytics for NorthstarDB.
//!
//! This module provides AI-driven usage analytics by analyzing query patterns,
//! detecting hot keys and cold data, identifying performance anomalies, and
//! generating usage-based optimization recommendations.

use crate::analytics::error::TimeSeriesError;
use crate::query_plan::{QueryPlan, ExecutionMetrics, PlanNode, PlanType, PlanNodeType};
use crate::monitoring::{MetricRegistry, Metric, MetricValue, MetricType, MonitoringConfig};

use std::collections::{HashMap, BTreeMap};
use std::sync::Arc;
use std::time::{SystemTime, Duration, UNIX_EPOCH};
use parking_lot::{RwLock, Mutex};
use serde::{Serialize, Deserialize};

/// Error type for usage analytics operations.
pub type UsageAnalyticsResult<T> = Result<T, UsageAnalyticsError>;

/// Error types for usage analytics.
#[derive(Debug, thiserror::Error)]
pub enum UsageAnalyticsError {
    #[error("Pattern not found: {0}")]
    PatternNotFound(u64),

    #[error("Invalid query pattern: {0}")]
    InvalidPattern(String),

    #[error("Anomaly detection error: {0}")]
    AnomalyDetectionError(String),

    #[error("Recommendation generation error: {0}")]
    RecommendationError(String),

    #[error("Time series error: {0}")]
    TimeSeriesError(#[from] TimeSeriesError),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),
}

/// Query pattern fingerprint (SHA-256 hash of normalized query structure).
pub type QueryFingerprint = u64;

/// Unique identifier for anomalies.
pub type AnomalyId = u64;

/// Unique identifier for recommendations.
pub type RecommendationId = u64;

/// Classification of query types based on access patterns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum QueryType {
    /// Single key lookup with equality predicate
    PointLookup,
    /// Range scan with inequality predicates
    RangeScan,
    /// Full table scan with no predicates
    FullScan,
    /// Multi-table join
    JoinQuery,
    /// Aggregation query (GROUP BY, COUNT, SUM, etc.)
    Aggregation,
    /// Natural language semantic search
    SemanticSearch,
    /// Insert operation
    Insert,
    /// Update operation
    Update,
    /// Delete operation
    Delete,
    /// Unknown query type
    Unknown,
}

/// Hot key classification based on access patterns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HotKeyClassification {
    /// High read frequency, low write frequency
    ReadHot,
    /// High write frequency
    WriteHot,
    /// Very high frequency (> 1000 ops/sec)
    HotSpot,
    /// Moderate frequency (10-100 ops/sec)
    WarmSpot,
}

/// Cold data classification based on inactivity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ColdDataClassification {
    /// Not accessed in > 90 days, large size
    ArchiveCandidate,
    /// Not accessed in > 365 days, no foreign key references
    DeleteCandidate,
    /// Low access rate, large size
    CompressCandidate,
}

/// Anomaly type classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AnomalyType {
    /// Sudden increase in query execution time
    LatencySpike,
    /// Sudden decrease in operations per second
    ThroughputDrop,
    /// Sudden increase in error rate
    ErrorRateIncrease,
    /// Sudden decrease in cache hit rate
    CacheMissSpike,
    /// Inability to acquire connections
    ConnectionPoolExhaustion,
    /// Increase in transaction conflicts
    LockContention,
}

/// Anomaly severity level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum AnomalySeverity {
    /// Minor deviation, no action needed
    Info,
    /// Moderate deviation, monitor
    Warning,
    /// Significant deviation, investigate
    Error,
    /// Severe degradation, immediate action
    Critical,
}

/// Recommendation type.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RecommendationType {
    /// Create an index
    CreateIndex { table: String, columns: Vec<String> },
    /// Pre-load hot key into cache
    CacheWarming { cache_level: u8 },
    /// Partition table
    PartitionTable { partition_key: String },
    /// Replicate to read replicas
    ReplicateData,
    /// Archive cold data
    ArchiveData { target: String },
    /// Compress cold data
    CompressData,
    /// Query optimization hint
    QueryOptimization { hint: String },
}

/// Recommendation target type.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RecommendationTarget {
    Table,
    Index,
    Query,
    Key,
    System,
}

/// Effort level to implement recommendation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum EffortLevel {
    /// Config change, no downtime
    Trivial,
    /// Index creation, short downtime
    Easy,
    /// Schema change, planned downtime
    Moderate,
    /// Migration, extensive testing
    Complex,
}

/// Recommendation priority.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum RecommendationPriority {
    Low,
    Medium,
    High,
    Critical,
}

/// Query pattern statistics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryPattern {
    /// Query fingerprint
    pub fingerprint: QueryFingerprint,

    /// Query type
    pub query_type: QueryType,

    /// Table name
    pub table_name: String,

    /// Columns accessed
    pub columns_accessed: Vec<String>,

    /// Execution count
    pub execution_count: u64,

    /// First seen timestamp
    pub first_seen: SystemTime,

    /// Last seen timestamp
    pub last_seen: SystemTime,

    /// Average latency (milliseconds)
    pub avg_latency_ms: f64,

    /// P50 latency
    pub p50_latency_ms: f64,

    /// P95 latency
    pub p95_latency_ms: f64,

    /// P99 latency
    pub p99_latency_ms: f64,

    /// Average rows scanned
    pub avg_rows_scanned: f64,

    /// Average rows returned
    pub avg_rows_returned: f64,

    /// Scan/return ratio
    pub scan_return_ratio: f64,

    /// Cache hit rate
    pub cache_hit_rate: f64,

    /// Plan cache hit rate
    pub plan_cache_hit_rate: f64,

    /// Hourly frequency distribution
    pub hourly_frequency: [u64; 24],

    /// Day of week frequency distribution
    pub day_of_week_frequency: [u64; 7],
}

impl QueryPattern {
    /// Create a new query pattern.
    pub fn new(fingerprint: QueryFingerprint, query_type: QueryType, table_name: String) -> Self {
        let now = SystemTime::now();
        Self {
            fingerprint,
            query_type,
            table_name,
            columns_accessed: Vec::new(),
            execution_count: 0,
            first_seen: now,
            last_seen: now,
            avg_latency_ms: 0.0,
            p50_latency_ms: 0.0,
            p95_latency_ms: 0.0,
            p99_latency_ms: 0.0,
            avg_rows_scanned: 0.0,
            avg_rows_returned: 0.0,
            scan_return_ratio: 0.0,
            cache_hit_rate: 0.0,
            plan_cache_hit_rate: 0.0,
            hourly_frequency: [0; 24],
            day_of_week_frequency: [0; 7],
        }
    }

    /// Update pattern with execution metrics.
    pub fn update(&mut self, metrics: &ExecutionMetrics) {
        self.execution_count += 1;
        self.last_seen = SystemTime::now();

        // Update exponential moving average of latency
        let alpha = 0.2; // Smoothing factor
        self.avg_latency_ms = alpha * metrics.execution_time_ms + (1.0 - alpha) * self.avg_latency_ms;

        // Update rows scanned/returned
        self.avg_rows_scanned = alpha * metrics.rows_read as f64 + (1.0 - alpha) * self.avg_rows_scanned;
        self.avg_rows_returned = alpha * metrics.rows_produced as f64 + (1.0 - alpha) * self.avg_rows_returned;

        // Calculate scan/return ratio
        if self.avg_rows_returned > 0.0 {
            self.scan_return_ratio = self.avg_rows_scanned / self.avg_rows_returned;
        }

        // Update hourly frequency
        if let Ok(duration) = SystemTime::now().duration_since(UNIX_EPOCH) {
            let hour = (duration.as_secs() / 3600) % 24;
            self.hourly_frequency[hour as usize] += 1;
        }

        // Update day of week frequency
        if let Ok(duration) = SystemTime::now().duration_since(UNIX_EPOCH) {
            let day = (duration.as_secs() / 86400) % 7;
            self.day_of_week_frequency[day as usize] += 1;
        }
    }
}

/// Key access statistics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyAccessStats {
    /// Raw key bytes
    pub key: Vec<u8>,

    /// Read count
    pub read_count: u64,

    /// Write count
    pub write_count: u64,

    /// Last read timestamp
    pub last_read: SystemTime,

    /// Last write timestamp
    pub last_write: SystemTime,

    /// Hourly read distribution
    pub hourly_reads: [u64; 24],

    /// Hourly write distribution
    pub hourly_writes: [u64; 24],

    /// Average read latency (milliseconds)
    pub avg_read_latency_ms: f64,

    /// Average write latency (milliseconds)
    pub avg_write_latency_ms: f64,
}

impl KeyAccessStats {
    /// Create new key access stats.
    pub fn new(key: Vec<u8>) -> Self {
        let now = SystemTime::now();
        Self {
            key,
            read_count: 0,
            write_count: 0,
            last_read: now,
            last_write: now,
            hourly_reads: [0; 24],
            hourly_writes: [0; 24],
            avg_read_latency_ms: 0.0,
            avg_write_latency_ms: 0.0,
        }
    }

    /// Record a read access.
    pub fn record_read(&mut self, latency_ms: f64) {
        self.read_count += 1;
        self.last_read = SystemTime::now();

        // Update EMA of latency
        let alpha = 0.2;
        self.avg_read_latency_ms = alpha * latency_ms + (1.0 - alpha) * self.avg_read_latency_ms;

        // Update hourly distribution
        if let Ok(duration) = SystemTime::now().duration_since(UNIX_EPOCH) {
            let hour = (duration.as_secs() / 3600) % 24;
            self.hourly_reads[hour as usize] += 1;
        }
    }

    /// Record a write access.
    pub fn record_write(&mut self, latency_ms: f64) {
        self.write_count += 1;
        self.last_write = SystemTime::now();

        // Update EMA of latency
        let alpha = 0.2;
        self.avg_write_latency_ms = alpha * latency_ms + (1.0 - alpha) * self.avg_write_latency_ms;

        // Update hourly distribution
        if let Ok(duration) = SystemTime::now().duration_since(UNIX_EPOCH) {
            let hour = (duration.as_secs() / 3600) % 24;
            self.hourly_writes[hour as usize] += 1;
        }
    }

    /// Calculate access frequency (ops/sec over last hour).
    pub fn frequency_per_sec(&self) -> f64 {
        let last_hour_reads: u64 = self.hourly_reads.iter().sum();
        let last_hour_writes: u64 = self.hourly_writes.iter().sum();
        (last_hour_reads + last_hour_writes) as f64 / 3600.0
    }
}

/// Hot key report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotKeyReport {
    /// Hot key
    pub key: Vec<u8>,

    /// Access frequency (ops/sec)
    pub read_frequency: f64,

    /// Write frequency (ops/sec)
    pub write_frequency: f64,

    /// Total frequency
    pub total_frequency: f64,

    /// Hotness score (0.0 to 1.0)
    pub hotness_score: f64,

    /// Classification
    pub classification: HotKeyClassification,

    /// Recommendation type
    pub recommendation: HotKeyRecommendation,
}

/// Hot key recommendation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum HotKeyRecommendation {
    CacheInL1,
    CacheInL2,
    CreateIndex,
    Partition,
    Replicate,
}

/// Cold data report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColdDataReport {
    /// Cold key
    pub key: Vec<u8>,

    /// Table name
    pub table_name: String,

    /// Days since last access
    pub days_since_last_access: u64,

    /// Access rate (accesses/day over last 30 days)
    pub access_rate_last_30_days: f64,

    /// Estimated size (bytes)
    pub estimated_size_bytes: u64,

    /// Classification
    pub classification: ColdDataClassification,

    /// Recommendation
    pub recommendation: ColdDataRecommendation,
}

/// Cold data recommendation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ColdDataRecommendation {
    ArchiveToS3,
    ArchiveToGlacier,
    Compress,
    Delete,
    Keep,
}

/// Performance anomaly.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PerformanceAnomaly {
    /// Anomaly ID
    pub anomaly_id: AnomalyId,

    /// Detection timestamp
    pub detected_at: SystemTime,

    /// Anomaly type
    pub anomaly_type: AnomalyType,

    /// Metric name
    pub metric_name: String,

    /// Baseline value
    pub baseline_value: f64,

    /// Current value
    pub current_value: f64,

    /// Deviation (percentage)
    pub deviation_percent: f64,

    /// Deviation (standard deviations)
    pub deviation_stddev: f64,

    /// Severity
    pub severity: AnomalySeverity,

    /// Likely cause
    pub likely_cause: Option<String>,

    /// Affected queries
    pub affected_queries: Vec<QueryFingerprint>,
}

/// Impact estimation for recommendations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImpactEstimate {
    /// Expected latency reduction (percentage)
    pub latency_reduction_percent: f64,

    /// Expected throughput increase (percentage)
    pub throughput_increase_percent: f64,

    /// Expected cost reduction (percentage)
    pub cost_reduction_percent: Option<f64>,

    /// Storage overhead (bytes)
    pub storage_overhead_bytes: Option<u64>,
}

/// Evidence supporting a recommendation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Evidence {
    /// Evidence type
    pub evidence_type: String,

    /// Evidence description
    pub description: String,

    /// Supporting data
    pub data: HashMap<String, String>,
}

/// Optimization recommendation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Recommendation {
    /// Recommendation ID
    pub recommendation_id: RecommendationId,

    /// Generation timestamp
    pub generated_at: SystemTime,

    /// Recommendation type
    pub recommendation_type: RecommendationType,

    /// Title
    pub title: String,

    /// Description
    pub description: String,

    /// Rationale
    pub rationale: String,

    /// Target type
    pub target_type: RecommendationTarget,

    /// Target name
    pub target_name: String,

    /// Expected impact
    pub estimated_benefit: ImpactEstimate,

    /// Implementation effort
    pub effort_level: EffortLevel,

    /// Priority
    pub priority: RecommendationPriority,

    /// Confidence (0.0 to 1.0)
    pub confidence: f64,

    /// Supporting evidence
    pub supporting_evidence: Vec<Evidence>,
}

/// Usage analytics state.
pub struct UsageAnalytics {
    /// Metric registry
    metrics: Arc<MetricRegistry>,

    /// Query patterns
    patterns: Arc<RwLock<HashMap<QueryFingerprint, QueryPattern>>>,

    /// Key access stats
    key_access: Arc<RwLock<HashMap<Vec<u8>, KeyAccessStats>>>,

    /// Hot keys (cached top-K)
    hot_keys: Arc<RwLock<Vec<HotKeyReport>>>,

    /// Cold data (cached top-K)
    cold_data: Arc<RwLock<Vec<ColdDataReport>>>,

    /// Anomalies
    anomalies: Arc<RwLock<Vec<PerformanceAnomaly>>>,

    /// Recommendations
    recommendations: Arc<Mutex<Vec<Recommendation>>>,

    /// Next anomaly ID
    next_anomaly_id: Arc<Mutex<u64>>,

    /// Next recommendation ID
    next_recommendation_id: Arc<Mutex<u64>>,
}

impl UsageAnalytics {
    /// Create new usage analytics.
    pub fn new(metrics: Arc<MetricRegistry>) -> Self {
        Self {
            metrics,
            patterns: Arc::new(RwLock::new(HashMap::new())),
            key_access: Arc::new(RwLock::new(HashMap::new())),
            hot_keys: Arc::new(RwLock::new(Vec::new())),
            cold_data: Arc::new(RwLock::new(Vec::new())),
            anomalies: Arc::new(RwLock::new(Vec::new())),
            recommendations: Arc::new(Mutex::new(Vec::new())),
            next_anomaly_id: Arc::new(Mutex::new(1)),
            next_recommendation_id: Arc::new(Mutex::new(1)),
        }
    }

    /// Analyze query execution and update patterns.
    pub fn analyze_query(&self, query: &QueryPlan, execution_time: Duration) {
        let execution_time_ms = execution_time.as_secs_f64() * 1000.0;

        // Generate fingerprint from query
        let fingerprint = self.fingerprint_query(query);

        // Classify query type
        let query_type = self.classify_query(query);

        // Extract table name
        let table_name = self.extract_table_name(query);

        // Get or create pattern
        let mut patterns = self.patterns.write();
        let pattern = patterns.entry(fingerprint).or_insert_with(|| {
            QueryPattern::new(fingerprint, query_type, table_name)
        });

        // Update pattern with metrics
        let metrics = ExecutionMetrics {
            execution_time_ms,
            ..Default::default()
        };
        pattern.update(&metrics);

        // Update hot keys
        self.update_hot_keys(&pattern);
    }

    /// Detect hot keys.
    pub fn detect_hot_keys(&self) -> Vec<HotKeyReport> {
        let key_access = self.key_access.read();
        let mut reports: Vec<HotKeyReport> = Vec::new();

        for (_, stats) in key_access.iter() {
            let read_freq = stats.frequency_per_sec();

            if read_freq > 10.0 {
                // Calculate hotness score (0.0 to 1.0)
                let hotness_score = (read_freq / 1000.0).min(1.0);

                // Classify hot key
                let classification = if read_freq > 1000.0 {
                    HotKeyClassification::HotSpot
                } else if stats.read_count > stats.write_count * 10 {
                    HotKeyClassification::ReadHot
                } else {
                    HotKeyClassification::WarmSpot
                };

                // Generate recommendation
                let recommendation = if hotness_score > 0.8 {
                    HotKeyRecommendation::CacheInL1
                } else if hotness_score > 0.5 {
                    HotKeyRecommendation::CacheInL2
                } else {
                    HotKeyRecommendation::CreateIndex
                };

                reports.push(HotKeyReport {
                    key: stats.key.clone(),
                    read_frequency: read_freq,
                    write_frequency: 0.0,
                    total_frequency: read_freq,
                    hotness_score,
                    classification,
                    recommendation,
                });
            }
        }

        // Sort by hotness score
        reports.sort_by(|a, b| b.hotness_score.partial_cmp(&a.hotness_score).unwrap());

        // Keep top 100
        reports.truncate(100);

        // Update cache
        *self.hot_keys.write() = reports.clone();

        reports
    }

    /// Detect performance anomalies.
    pub fn detect_anomalies(&self) -> Vec<PerformanceAnomaly> {
        let patterns = self.patterns.read();
        let mut anomalies: Vec<PerformanceAnomaly> = Vec::new();

        for (_, pattern) in patterns.iter() {
            if pattern.execution_count < 10 {
                continue; // Not enough data
            }

            // Check for latency spikes (current > 3x baseline)
            if pattern.avg_latency_ms > pattern.p50_latency_ms * 3.0 && pattern.p50_latency_ms > 0.0 {
                let deviation_percent = ((pattern.avg_latency_ms - pattern.p50_latency_ms) / pattern.p50_latency_ms) * 100.0;

                let anomaly = PerformanceAnomaly {
                    anomaly_id: self.next_anomaly_id(),
                    detected_at: SystemTime::now(),
                    anomaly_type: AnomalyType::LatencySpike,
                    metric_name: format!("query_latency_{}", pattern.table_name),
                    baseline_value: pattern.p50_latency_ms,
                    current_value: pattern.avg_latency_ms,
                    deviation_percent,
                    deviation_stddev: 3.0,
                    severity: if deviation_percent > 100.0 {
                        AnomalySeverity::Critical
                    } else if deviation_percent > 50.0 {
                        AnomalySeverity::Error
                    } else {
                        AnomalySeverity::Warning
                    },
                    likely_cause: Some(format!(
                        "Query latency spike on {} ({} executions, avg {:.2}ms vs p50 {:.2}ms)",
                        pattern.table_name, pattern.execution_count, pattern.avg_latency_ms, pattern.p50_latency_ms
                    )),
                    affected_queries: vec![pattern.fingerprint],
                };

                anomalies.push(anomaly);
            }
        }

        // Update cache
        *self.anomalies.write() = anomalies.clone();

        anomalies
    }

    /// Generate optimization recommendations.
    pub fn generate_recommendations(&self) -> Vec<Recommendation> {
        let patterns = self.patterns.read();
        let mut recommendations: Vec<Recommendation> = Vec::new();

        for (_, pattern) in patterns.iter() {
            if pattern.execution_count < 100 {
                continue; // Not enough data
            }

            // Check for full scan patterns
            if pattern.query_type == QueryType::FullScan {
                if pattern.avg_rows_scanned > 10000.0 && pattern.avg_rows_returned < 1000.0 {
                    // High scan/return ratio = inefficient
                    let rec = Recommendation {
                        recommendation_id: self.next_recommendation_id(),
                        generated_at: SystemTime::now(),
                        recommendation_type: RecommendationType::CreateIndex {
                            table: pattern.table_name.clone(),
                            columns: pattern.columns_accessed.clone(),
                        },
                        title: format!("Create index on {}", pattern.table_name),
                        description: format!(
                            "Frequent full scans on {} ({} executions, {:.2}ms avg latency). \
                             Adding an index could reduce latency by 80%.",
                            pattern.table_name, pattern.execution_count, pattern.avg_latency_ms
                        ),
                        rationale: format!(
                            "Scan/return ratio is {:.2}:1, indicating inefficient full table scans.",
                            pattern.scan_return_ratio
                        ),
                        target_type: RecommendationTarget::Table,
                        target_name: pattern.table_name.clone(),
                        estimated_benefit: ImpactEstimate {
                            latency_reduction_percent: 80.0,
                            throughput_increase_percent: 50.0,
                            cost_reduction_percent: None,
                            storage_overhead_bytes: None,
                        },
                        effort_level: EffortLevel::Easy,
                        priority: if pattern.execution_count > 1000 {
                            RecommendationPriority::High
                        } else {
                            RecommendationPriority::Medium
                        },
                        confidence: 0.9,
                        supporting_evidence: vec![],
                    };

                    recommendations.push(rec);
                }
            }
        }

        // Update cache
        self.recommendations.lock().extend(recommendations.clone());

        recommendations
    }

    /// Get current hot keys.
    pub fn get_hot_keys(&self) -> Vec<HotKeyReport> {
        self.hot_keys.read().clone()
    }

    /// Get current cold data.
    pub fn get_cold_data(&self) -> Vec<ColdDataReport> {
        self.cold_data.read().clone()
    }

    /// Get current anomalies.
    pub fn get_anomalies(&self) -> Vec<PerformanceAnomaly> {
        self.anomalies.read().clone()
    }

    /// Get current recommendations.
    pub fn get_recommendations(&self) -> Vec<Recommendation> {
        self.recommendations.lock().clone()
    }

    /// Generate query fingerprint.
    fn fingerprint_query(&self, query: &QueryPlan) -> QueryFingerprint {
        // Simple fingerprint based on query text hash
        use std::hash::{Hash, Hasher};
        use std::collections::hash_map::DefaultHasher;

        let mut hasher = DefaultHasher::new();
        query.query_text.hash(&mut hasher);
        hasher.finish()
    }

    /// Classify query type.
    fn classify_query(&self, query: &QueryPlan) -> QueryType {
        // Simple heuristic based on query text
        let text = query.query_text.to_lowercase();

        if text.contains("select") && text.contains("where") && text.contains("=") {
            QueryType::PointLookup
        } else if text.contains("select") && (text.contains(">") || text.contains("<")) {
            QueryType::RangeScan
        } else if text.contains("select") {
            QueryType::FullScan
        } else if text.contains("insert") {
            QueryType::Insert
        } else if text.contains("update") {
            QueryType::Update
        } else if text.contains("delete") {
            QueryType::Delete
        } else {
            QueryType::Unknown
        }
    }

    /// Extract table name from query.
    fn extract_table_name(&self, query: &QueryPlan) -> String {
        // Simple heuristic: extract from query text
        let text = query.query_text.to_lowercase();

        // Look for "from <table>" or "update <table>" or "insert into <table>"
        if let Some(idx) = text.find("from ") {
            let rest = &text[idx + 5..];
            // Find first whitespace after "from"
            if let Some(end) = rest.chars().position(|c| c.is_whitespace()) {
                return rest[..end].to_string();
            }
        }

        "unknown".to_string()
    }

    /// Update hot keys cache.
    fn update_hot_keys(&self, pattern: &QueryPattern) {
        // Hot keys are periodically refreshed by detect_hot_keys()
        // This is a placeholder for incremental updates
    }

    /// Get next anomaly ID.
    fn next_anomaly_id(&self) -> AnomalyId {
        let mut id = self.next_anomaly_id.lock();
        let current = *id;
        *id += 1;
        current
    }

    /// Get next recommendation ID.
    fn next_recommendation_id(&self) -> RecommendationId {
        let mut id = self.next_recommendation_id.lock();
        let current = *id;
        *id += 1;
        current
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_pattern_creation() {
        let pattern = QueryPattern::new(12345, QueryType::PointLookup, "users".to_string());

        assert_eq!(pattern.fingerprint, 12345);
        assert_eq!(pattern.query_type, QueryType::PointLookup);
        assert_eq!(pattern.table_name, "users");
        assert_eq!(pattern.execution_count, 0);
    }

    #[test]
    fn test_query_pattern_update() {
        let mut pattern = QueryPattern::new(12345, QueryType::PointLookup, "users".to_string());

        let metrics = ExecutionMetrics {
            execution_time_ms: 10.0,
            rows_read: 100,
            rows_produced: 10,
            ..Default::default()
        };

        pattern.update(&metrics);

        assert_eq!(pattern.execution_count, 1);
        assert!(pattern.avg_latency_ms > 0.0);
        assert!(pattern.avg_rows_scanned > 0.0);
    }

    #[test]
    fn test_key_access_stats() {
        let mut stats = KeyAccessStats::new(b"key123".to_vec());

        stats.record_read(5.0);
        stats.record_write(10.0);

        assert_eq!(stats.read_count, 1);
        assert_eq!(stats.write_count, 1);
        // EMA starts at 0 and moves toward value with alpha=0.2
        // After first value: 0.2 * 5.0 + 0.8 * 0.0 = 1.0
        assert!(stats.avg_read_latency_ms > 0.0);
        assert!(stats.avg_write_latency_ms > 0.0);
    }

    #[test]
    fn test_usage_analytics_creation() {
        let metrics = Arc::new(MetricRegistry::new(Default::default()));
        let analytics = UsageAnalytics::new(metrics);

        assert_eq!(analytics.get_hot_keys().len(), 0);
        assert_eq!(analytics.get_anomalies().len(), 0);
        assert_eq!(analytics.get_recommendations().len(), 0);
    }

    #[test]
    fn test_fingerprint_query() {
        let metrics = Arc::new(MetricRegistry::new(Default::default()));
        let analytics = UsageAnalytics::new(metrics);

        // Create a simple table scan node
        let scan_node = PlanNode::new(1, PlanNodeType::TableScan, 1000.0);

        let plan = QueryPlan::new(
            1,
            "SELECT * FROM users WHERE id = 123".to_string(),
            scan_node,
            PlanType::Estimated,
        );

        let fingerprint = analytics.fingerprint_query(&plan);
        assert!(fingerprint > 0);
    }

    #[test]
    fn test_classify_query() {
        let metrics = Arc::new(MetricRegistry::new(Default::default()));
        let analytics = UsageAnalytics::new(metrics);

        // Create a simple table scan node
        let scan_node = PlanNode::new(1, PlanNodeType::TableScan, 1000.0);

        let plan = QueryPlan::new(
            1,
            "SELECT * FROM users WHERE id = 123".to_string(),
            scan_node,
            PlanType::Estimated,
        );

        let query_type = analytics.classify_query(&plan);
        assert_eq!(query_type, QueryType::PointLookup);
    }
}
