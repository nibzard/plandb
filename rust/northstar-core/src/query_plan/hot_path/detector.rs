//! Bottleneck Detector
//!
//! This module provides functionality to detect performance bottlenecks
//! by comparing current metrics against configured thresholds.

use super::types::*;
use super::error::{HotPathError, HotPathResult};

/// Bottleneck detection thresholds.
#[derive(Debug, Clone)]
pub struct BottleneckThresholds {
    /// CPU utilization threshold percentage
    pub cpu_threshold_pct: f64,
    /// Disk I/O latency threshold in milliseconds
    pub io_latency_threshold_ms: f64,
    /// Cache hit ratio threshold percentage
    pub cache_hit_threshold_pct: f64,
    /// Lock wait time threshold in milliseconds
    pub lock_wait_threshold_ms: f64,
    /// Write log flush time threshold in milliseconds
    pub wal_flush_threshold_ms: f64,
}

impl Default for BottleneckThresholds {
    fn default() -> Self {
        Self {
            cpu_threshold_pct: 85.0,
            io_latency_threshold_ms: 20.0,
            cache_hit_threshold_pct: 80.0,
            lock_wait_threshold_ms: 100.0,
            wal_flush_threshold_ms: 50.0,
        }
    }
}

/// Current system metrics for bottleneck detection.
#[derive(Debug, Clone)]
pub struct SystemMetrics {
    /// Current CPU utilization percentage
    pub cpu_utilization_pct: f64,
    /// Average disk I/O latency in milliseconds
    pub io_latency_ms: f64,
    /// Cache hit ratio percentage
    pub cache_hit_ratio_pct: f64,
    /// Average lock wait time in milliseconds
    pub avg_lock_wait_ms: f64,
    /// Average write-ahead log flush time in milliseconds
    pub avg_wal_flush_ms: f64,
    /// Memory usage percentage
    pub memory_usage_pct: f64,
    /// Network latency in milliseconds (for distributed setups)
    pub network_latency_ms: Option<f64>,
}

impl Default for SystemMetrics {
    fn default() -> Self {
        Self {
            cpu_utilization_pct: 0.0,
            io_latency_ms: 0.0,
            cache_hit_ratio_pct: 100.0,
            avg_lock_wait_ms: 0.0,
            avg_wal_flush_ms: 0.0,
            memory_usage_pct: 0.0,
            network_latency_ms: None,
        }
    }
}

/// Table scan statistics for detecting table scan bottlenecks.
#[derive(Debug, Clone)]
pub struct TableScanStats {
    /// Number of full table scans detected
    pub scan_count: u64,
    /// Total rows scanned
    pub total_rows_scanned: u64,
    /// Tables being scanned
    pub tables_scanned: Vec<String>,
}

/// Index usage statistics for detecting missing index bottlenecks.
#[derive(Debug, Clone)]
pub struct IndexUsageStats {
    /// Tables with high scan rates
    pub high_scan_tables: Vec<String>,
    /// Columns frequently used in filters without indexes
    pub missing_index_columns: Vec<(String, String)>, // (table, column)
}

/// Detect performance bottlenecks from system metrics.
///
/// # Arguments
/// * `metrics` - Current system metrics
/// * `thresholds` - Bottleneck detection thresholds
///
/// # Returns
/// Vector of detected bottlenecks sorted by severity
pub fn detect_bottlenecks(
    metrics: &SystemMetrics,
    thresholds: &BottleneckThresholds,
) -> HotPathResult<Vec<Bottleneck>> {
    let mut bottlenecks: Vec<Bottleneck> = Vec::new();
    let mut next_id = 1u64;

    // Check CPU saturation
    if metrics.cpu_utilization_pct > thresholds.cpu_threshold_pct {
        let excess_pct = ((metrics.cpu_utilization_pct - thresholds.cpu_threshold_pct)
            / thresholds.cpu_threshold_pct)
            * 100.0;
        bottlenecks.push(create_bottleneck(
            next_id,
            BottleneckType::CpuSaturation,
            classify_severity(excess_pct, 20.0, 50.0, 100.0),
            format!(
                "CPU utilization at {:.1}%, above threshold of {:.1}%",
                metrics.cpu_utilization_pct, thresholds.cpu_threshold_pct
            ),
            "System".to_string(),
            metrics.cpu_utilization_pct,
            thresholds.cpu_threshold_pct,
            excess_pct,
            estimate_cpu_impact(excess_pct),
            vec!["All queries".to_string()],
            "Consider scaling vertically, optimizing queries, or adding read replicas".to_string(),
            false,
        ));
        next_id += 1;
    }

    // Check I/O saturation
    if metrics.io_latency_ms > thresholds.io_latency_threshold_ms {
        let excess_pct = ((metrics.io_latency_ms - thresholds.io_latency_threshold_ms)
            / thresholds.io_latency_threshold_ms)
            * 100.0;
        bottlenecks.push(create_bottleneck(
            next_id,
            BottleneckType::IoSaturation,
            classify_severity(excess_pct, 25.0, 50.0, 100.0),
            format!(
                "Disk I/O latency at {:.1}ms, above threshold of {:.1}ms",
                metrics.io_latency_ms, thresholds.io_latency_threshold_ms
            ),
            "Storage".to_string(),
            metrics.io_latency_ms,
            thresholds.io_latency_threshold_ms,
            excess_pct,
            excess_pct * 2.0, // Rough estimate: each % adds 2ms latency
            vec!["I/O intensive queries".to_string()],
            "Consider faster storage, better indexing, or query optimization".to_string(),
            false,
        ));
        next_id += 1;
    }

    // Check cache miss ratio
    if metrics.cache_hit_ratio_pct < thresholds.cache_hit_threshold_pct {
        let deficit_pct = thresholds.cache_hit_threshold_pct - metrics.cache_hit_ratio_pct;
        let excess_pct = (deficit_pct / thresholds.cache_hit_threshold_pct) * 100.0;
        bottlenecks.push(create_bottleneck(
            next_id,
            BottleneckType::CacheMissRatio,
            classify_severity(excess_pct, 20.0, 40.0, 60.0),
            format!(
                "Cache hit ratio at {:.1}%, below threshold of {:.1}%",
                metrics.cache_hit_ratio_pct, thresholds.cache_hit_threshold_pct
            ),
            "Buffer Pool".to_string(),
            100.0 - metrics.cache_hit_ratio_pct,
            100.0 - thresholds.cache_hit_threshold_pct,
            excess_pct,
            excess_pct * 5.0, // Rough estimate
            vec!["All queries".to_string()],
            "Increase cache size or improve access patterns".to_string(),
            true,
        ));
        next_id += 1;
    }

    // Check lock contention
    if metrics.avg_lock_wait_ms > thresholds.lock_wait_threshold_ms {
        let excess_pct = ((metrics.avg_lock_wait_ms - thresholds.lock_wait_threshold_ms)
            / thresholds.lock_wait_threshold_ms)
            * 100.0;
        bottlenecks.push(create_bottleneck(
            next_id,
            BottleneckType::LockContention,
            classify_severity(excess_pct, 25.0, 50.0, 100.0),
            format!(
                "Average lock wait time at {:.1}ms, above threshold of {:.1}ms",
                metrics.avg_lock_wait_ms, thresholds.lock_wait_threshold_ms
            ),
            "Lock Manager".to_string(),
            metrics.avg_lock_wait_ms,
            thresholds.lock_wait_threshold_ms,
            excess_pct,
            excess_pct,
            vec!["Concurrent write queries".to_string()],
            "Consider reducing transaction duration, using optimistic locking, or schema changes".to_string(),
            false,
        ));
        next_id += 1;
    }

    // Check WAL flush times
    if metrics.avg_wal_flush_ms > thresholds.wal_flush_threshold_ms {
        let excess_pct = ((metrics.avg_wal_flush_ms - thresholds.wal_flush_threshold_ms)
            / thresholds.wal_flush_threshold_ms)
            * 100.0;
        bottlenecks.push(create_bottleneck(
            next_id,
            BottleneckType::WriteLogFlush,
            classify_severity(excess_pct, 30.0, 60.0, 100.0),
            format!(
                "WAL flush time at {:.1}ms, above threshold of {:.1}ms",
                metrics.avg_wal_flush_ms, thresholds.wal_flush_threshold_ms
            ),
            "Write-Ahead Log".to_string(),
            metrics.avg_wal_flush_ms,
            thresholds.wal_flush_threshold_ms,
            excess_pct,
            excess_pct * 0.5,
            vec!["Write queries".to_string()],
            "Consider faster disk for WAL, adjusting wal_buffers, or reducing checkpoint frequency".to_string(),
            true,
        ));
        next_id += 1;
    }

    // Check memory pressure
    if metrics.memory_usage_pct > 90.0 {
        let excess_pct = metrics.memory_usage_pct - 90.0;
        bottlenecks.push(create_bottleneck(
            next_id,
            BottleneckType::MemoryPressure,
            classify_severity(excess_pct, 10.0, 20.0, 30.0),
            format!(
                "Memory usage at {:.1}%, approaching capacity",
                metrics.memory_usage_pct
            ),
            "Memory".to_string(),
            metrics.memory_usage_pct,
            90.0,
            excess_pct,
            excess_pct * 10.0,
            vec!["Memory-intensive queries".to_string()],
            "Increase available memory or reduce work_mem settings".to_string(),
            false,
        ));
        next_id += 1;
    }

    // Check network latency (for distributed setups)
    if let Some(latency) = metrics.network_latency_ms {
        if latency > 50.0 {
            let excess_pct = ((latency - 50.0) / 50.0) * 100.0;
            bottlenecks.push(create_bottleneck(
                next_id,
                BottleneckType::NetworkLatency,
                classify_severity(excess_pct, 20.0, 40.0, 100.0),
                format!(
                    "Network latency at {:.1}ms, above threshold of 50ms",
                    latency
                ),
                "Network".to_string(),
                latency,
                50.0,
                excess_pct,
                excess_pct * 2.0,
                vec!["Distributed queries".to_string()],
                "Optimize network configuration or consider colocation".to_string(),
                false,
            ));
            next_id += 1;
        }
    }

    // Sort by severity
    bottlenecks.sort_by(|a, b| b.severity.partial_cmp(&a.severity).unwrap());

    Ok(bottlenecks)
}

/// Detect table scan bottlenecks.
///
/// # Arguments
/// * `stats` - Table scan statistics
/// * `threshold` - Minimum scan count to consider it a bottleneck
///
/// # Returns
/// Bottleneck if excessive table scans detected
pub fn detect_table_scan_bottleneck(
    stats: &TableScanStats,
    threshold: u64,
) -> Option<Bottleneck> {
    if stats.scan_count < threshold {
        return None;
    }

    let excess_pct = ((stats.scan_count - threshold) as f64 / threshold as f64) * 100.0;

    Some(create_bottleneck(
        1,
        BottleneckType::TableScan,
        classify_severity(excess_pct, 50.0, 100.0, 200.0),
        format!(
            "Detected {} full table scans affecting tables: {}",
            stats.scan_count,
            stats.tables_scanned.join(", ")
        ),
        "Query Executor".to_string(),
        stats.scan_count as f64,
        threshold as f64,
        excess_pct,
        excess_pct * stats.total_rows_scanned as f64 / 1_000_000.0, // Rough estimate
        stats.tables_scanned.clone(),
        "Create appropriate indexes or rewrite queries to use indexes".to_string(),
        false,
    ))
}

/// Detect missing index bottlenecks.
///
/// # Arguments
/// * `stats` - Index usage statistics
///
/// # Returns
/// Bottlenecks for missing indexes
pub fn detect_missing_index_bottlenecks(stats: &IndexUsageStats) -> Vec<Bottleneck> {
    let mut bottlenecks: Vec<Bottleneck> = Vec::new();
    let mut next_id = 1u64;

    for (table, column) in &stats.missing_index_columns {
        bottlenecks.push(create_bottleneck(
            next_id,
            BottleneckType::MissingIndex,
            Severity::High,
            format!(
                "Frequent filters on column {}.{} without index",
                table, column
            ),
            format!("Table {}", table),
            100.0, // Placeholder current value
            0.0,   // Placeholder threshold
            100.0, // 100% excess (no index exists)
            50.0,  // Estimated 50ms impact per query
            vec![format!(
                "SELECT * FROM {} WHERE {} = $LIT",
                table, column
            )],
            format!("CREATE INDEX ON {} ({})", table, column),
            true,
        ));
        next_id += 1;
    }

    bottlenecks
}

/// Create a bottleneck with the given parameters.
fn create_bottleneck(
    id: u64,
    bottleneck_type: BottleneckType,
    severity: Severity,
    description: String,
    affected_component: String,
    current_value: f64,
    threshold_value: f64,
    excess_pct: f64,
    estimated_impact_ms: f64,
    affected_queries: Vec<String>,
    suggested_remediation: String,
    can_auto_remediate: bool,
) -> Bottleneck {
    Bottleneck {
        bottleneck_id: id,
        bottleneck_type,
        severity,
        description,
        affected_component,
        current_value,
        threshold_value,
        excess_pct,
        estimated_impact_ms,
        affected_queries,
        suggested_remediation,
        can_auto_remediate,
    }
}

/// Classify severity based on how much threshold is exceeded.
fn classify_severity(excess_pct: f64, high: f64, very_high: f64, extreme: f64) -> Severity {
    if excess_pct >= extreme {
        Severity::Critical
    } else if excess_pct >= very_high {
        Severity::High
    } else if excess_pct >= high {
        Severity::Medium
    } else {
        Severity::Low
    }
}

/// Estimate CPU impact based on excess percentage.
fn estimate_cpu_impact(excess_pct: f64) -> f64 {
    // Rough estimate: each percent above threshold adds 5ms latency
    excess_pct * 5.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_cpu_bottleneck() {
        let metrics = SystemMetrics {
            cpu_utilization_pct: 95.0,
            ..Default::default()
        };
        let thresholds = BottleneckThresholds::default();

        let bottlenecks = detect_bottlenecks(&metrics, &thresholds).unwrap();
        assert_eq!(bottlenecks.len(), 1);
        assert_eq!(bottlenecks[0].bottleneck_type, BottleneckType::CpuSaturation);
        assert_eq!(bottlenecks[0].severity, Severity::High);
    }

    #[test]
    fn test_detect_io_bottleneck() {
        let metrics = SystemMetrics {
            io_latency_ms: 35.0,
            ..Default::default()
        };
        let thresholds = BottleneckThresholds::default();

        let bottlenecks = detect_bottlenecks(&metrics, &thresholds).unwrap();
        assert_eq!(bottlenecks.len(), 1);
        assert_eq!(bottlenecks[0].bottleneck_type, BottleneckType::IoSaturation);
    }

    #[test]
    fn test_detect_cache_miss_bottleneck() {
        let metrics = SystemMetrics {
            cache_hit_ratio_pct: 65.0,
            ..Default::default()
        };
        let thresholds = BottleneckThresholds::default();

        let bottlenecks = detect_bottlenecks(&metrics, &thresholds).unwrap();
        assert_eq!(bottlenecks.len(), 1);
        assert_eq!(
            bottlenecks[0].bottleneck_type,
            BottleneckType::CacheMissRatio
        );
    }

    #[test]
    fn test_no_bottlenecks() {
        let metrics = SystemMetrics {
            cpu_utilization_pct: 50.0,
            io_latency_ms: 10.0,
            cache_hit_ratio_pct: 95.0,
            ..Default::default()
        };
        let thresholds = BottleneckThresholds::default();

        let bottlenecks = detect_bottlenecks(&metrics, &thresholds).unwrap();
        assert!(bottlenecks.is_empty());
    }

    #[test]
    fn test_table_scan_bottleneck() {
        let stats = TableScanStats {
            scan_count: 100,
            total_rows_scanned: 1_000_000,
            tables_scanned: vec!["users".to_string(), "orders".to_string()],
        };

        let bottleneck = detect_table_scan_bottleneck(&stats, 50);
        assert!(bottleneck.is_some());
        assert_eq!(
            bottleneck.unwrap().bottleneck_type,
            BottleneckType::TableScan
        );
    }

    #[test]
    fn test_missing_index_bottleneck() {
        let stats = IndexUsageStats {
            high_scan_tables: vec!["users".to_string()],
            missing_index_columns: vec![
                ("users".to_string(), "email".to_string()),
                ("orders".to_string(), "user_id".to_string()),
            ],
        };

        let bottlenecks = detect_missing_index_bottlenecks(&stats);
        assert_eq!(bottlenecks.len(), 2);
        assert_eq!(
            bottlenecks[0].bottleneck_type,
            BottleneckType::MissingIndex
        );
    }

    #[test]
    fn test_bottleneck_validation() {
        let bottleneck = Bottleneck {
            bottleneck_id: 1,
            bottleneck_type: BottleneckType::CpuSaturation,
            severity: Severity::High,
            description: "CPU at 95%".to_string(),
            affected_component: "System".to_string(),
            current_value: 95.0,
            threshold_value: 85.0,
            excess_pct: 11.76,
            estimated_impact_ms: 58.8,
            affected_queries: vec!["All queries".to_string()],
            suggested_remediation: "Scale vertically".to_string(),
            can_auto_remediate: false,
        };

        assert!(bottleneck.validate().is_ok());
    }

    #[test]
    fn test_severity_classification() {
        assert_eq!(classify_severity(5.0, 20.0, 50.0, 100.0), Severity::Low);
        assert_eq!(classify_severity(25.0, 20.0, 50.0, 100.0), Severity::Medium);
        assert_eq!(classify_severity(60.0, 20.0, 50.0, 100.0), Severity::High);
        assert_eq!(classify_severity(120.0, 20.0, 50.0, 100.0), Severity::Critical);
    }

    #[test]
    fn test_multiple_bottlenecks_sorted() {
        let metrics = SystemMetrics {
            cpu_utilization_pct: 98.0,  // Critical
            io_latency_ms: 40.0,         // High
            cache_hit_ratio_pct: 60.0,   // Medium
            avg_lock_wait_ms: 150.0,     // High
            ..Default::default()
        };
        let thresholds = BottleneckThresholds::default();

        let bottlenecks = detect_bottlenecks(&metrics, &thresholds).unwrap();
        assert!(bottlenecks.len() > 1);
        // First should be highest severity
        assert_eq!(bottlenecks[0].severity, Severity::Critical);
    }
}
