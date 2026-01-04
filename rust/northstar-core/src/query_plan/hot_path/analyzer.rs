//! Hot Path Analyzer
//!
//! This module provides functionality to identify hot paths in database operations,
//! including hot queries, tables, indexes, and pages.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use crate::types::PageId;

use super::types::*;
use super::error::{HotPathError, HotPathResult};
use super::normalizer::{normalize_query, query_hash};

/// Configuration for hot path analysis.
#[derive(Debug, Clone)]
pub struct AnalyzerConfig {
    /// Weight for frequency in impact score (0.0 to 1.0)
    pub frequency_weight: f64,
    /// Weight for cost in impact score (0.0 to 1.0)
    pub cost_weight: f64,
    /// Minimum executions to be considered hot
    pub min_executions: u64,
    /// Maximum number of results to return
    pub limit: usize,
}

impl Default for AnalyzerConfig {
    fn default() -> Self {
        Self {
            frequency_weight: 0.6,
            cost_weight: 0.4,
            min_executions: 10,
            limit: 100,
        }
    }
}

/// Represents a single query execution record.
#[derive(Debug, Clone)]
pub struct QueryExecution {
    /// Original query text
    pub query_text: String,
    /// Execution time in milliseconds
    pub execution_time_ms: f64,
    /// Rows returned
    pub rows_returned: u64,
    /// Rows scanned
    pub rows_read: u64,
    /// Blocks read from disk
    pub blocks_read: u64,
    /// Cache hits
    pub cache_hits: u64,
    /// Total cache attempts
    pub cache_attempts: u64,
    /// Timestamp of execution
    pub timestamp: DateTime<Utc>,
}

/// Represents table access statistics.
#[derive(Debug, Clone)]
pub struct TableAccessStats {
    /// Table name
    pub table_name: String,
    /// Schema name
    pub schema_name: String,
    /// Read operations
    pub read_count: u64,
    /// Write operations
    pub write_count: u64,
    /// Rows read
    pub rows_read_total: u64,
    /// Rows written
    pub rows_written_total: u64,
    /// Blocks read
    pub blocks_read_total: u64,
    /// Blocks written
    pub blocks_written_total: u64,
    /// Sequential reads
    pub sequential_reads: u64,
    /// Table size in bytes
    pub table_size_bytes: u64,
    /// Cache hits
    pub cache_hits: u64,
    /// Cache attempts
    pub cache_attempts: u64,
    /// Table scans
    pub table_scan_count: u64,
    /// Index scans
    pub index_scan_count: u64,
}

/// Represents page access statistics.
#[derive(Debug, Clone)]
pub struct PageAccessStats {
    /// Page ID
    pub page_id: PageId,
    /// Page type
    pub page_type: PageType,
    /// Table name
    pub table_name: String,
    /// Access count
    pub access_count: u64,
    /// First access
    pub first_access: DateTime<Utc>,
    /// Last access
    pub last_access: DateTime<Utc>,
    /// Is currently cached
    pub is_cached: bool,
    /// Cache evictions
    pub cache_evictions: u64,
    /// Average cache residence time
    pub avg_residence_time_ms: f64,
    /// Read contention
    pub read_contention: f64,
}

/// Calculate impact score combining frequency and cost.
///
/// # Arguments
/// * `frequency` - Number of times the operation occurred
/// * `cost` - Total resource consumption (e.g., time in milliseconds)
/// * `config` - Analyzer configuration
///
/// # Returns
/// Impact score from 0.0 to 100.0
pub fn calculate_impact_score(frequency: u64, cost: f64, config: &AnalyzerConfig) -> f64 {
    let frequency_score = (100.0_f64).min(((frequency + 1) as f64).log10() * 20.0);
    let cost_score = (100.0_f64).min((cost + 1.0).log10() * 20.0);

    let impact = (frequency_score * config.frequency_weight) + (cost_score * config.cost_weight);
    impact.min(100.0)
}

/// Identify hot queries from execution records.
///
/// # Arguments
/// * `executions` - Query execution records
/// * `config` - Analyzer configuration
///
/// # Returns
/// Vector of HotQuery sorted by impact score
pub fn identify_hot_queries(
    executions: Vec<QueryExecution>,
    config: &AnalyzerConfig,
) -> HotPathResult<Vec<HotQuery>> {
    if executions.is_empty() {
        return Ok(Vec::new());
    }

    // Group by normalized query hash
    let mut groups: HashMap<u64, Vec<QueryExecution>> = HashMap::new();
    for exec in &executions {
        let normalized = normalize_query(&exec.query_text)?;
        let hash = query_hash(&normalized);
        groups.entry(hash).or_default().push(exec.clone());
    }

    let mut hot_queries: Vec<HotQuery> = Vec::new();

    for (hash, group) in groups {
        // Filter by minimum executions
        if group.len() < config.min_executions as usize {
            continue;
        }

        // Calculate statistics
        let execution_count = group.len() as u64;
        let mut execution_times: Vec<f64> = group.iter().map(|e| e.execution_time_ms).collect();
        execution_times.sort_by(|a, b| a.partial_cmp(b).unwrap());

        let total_execution_time_ms: f64 = execution_times.iter().sum();
        let avg_execution_time_ms = total_execution_time_ms / execution_count as f64;
        let min_execution_time_ms = execution_times.first().copied().unwrap_or(0.0);
        let max_execution_time_ms = execution_times.last().copied().unwrap_or(0.0);

        // Calculate percentiles
        let p50_execution_time_ms = percentile(&execution_times, 50);
        let p95_execution_time_ms = percentile(&execution_times, 95);
        let p99_execution_time_ms = percentile(&execution_times, 99);

        let rows_returned_total: u64 = group.iter().map(|e| e.rows_returned).sum();
        let rows_returned_avg = rows_returned_total as f64 / execution_count as f64;
        let rows_read_total: u64 = group.iter().map(|e| e.rows_read).sum();
        let blocks_read_total: u64 = group.iter().map(|e| e.blocks_read).sum();

        let cache_hits: u64 = group.iter().map(|e| e.cache_hits).sum();
        let cache_attempts: u64 = group.iter().map(|e| e.cache_attempts).sum();
        let cache_hit_ratio = if cache_attempts > 0 {
            cache_hits as f64 / cache_attempts as f64
        } else {
            1.0
        };

        let mut timestamps: Vec<DateTime<Utc>> = group.iter().map(|e| e.timestamp).collect();
        timestamps.sort();
        let first_seen = timestamps.first().copied().unwrap_or_else(Utc::now);
        let last_seen = timestamps.last().copied().unwrap_or_else(Utc::now);

        let sample_query_text = group.first().map(|e| e.query_text.clone()).unwrap_or_default();
        let query_pattern = normalize_query(&sample_query_text)?;

        let impact_score = calculate_impact_score(execution_count, total_execution_time_ms, config);

        hot_queries.push(HotQuery {
            query_pattern,
            query_hash: hash,
            execution_count,
            total_execution_time_ms,
            avg_execution_time_ms,
            min_execution_time_ms,
            max_execution_time_ms,
            p50_execution_time_ms,
            p95_execution_time_ms,
            p99_execution_time_ms,
            rows_returned_total,
            rows_returned_avg,
            rows_read_total,
            blocks_read_total,
            cache_hit_ratio,
            first_seen,
            last_seen,
            sample_query_text,
            impact_score,
        });
    }

    // Sort by impact score descending
    hot_queries.sort_by(|a, b| b.impact_score.partial_cmp(&a.impact_score).unwrap());

    // Limit results
    hot_queries.truncate(config.limit);

    Ok(hot_queries)
}

/// Identify hot tables from access statistics.
///
/// # Arguments
/// * `stats` - Table access statistics
/// * `config` - Analyzer configuration
///
/// # Returns
/// Vector of HotTable sorted by impact score
pub fn identify_hot_tables(
    stats: Vec<TableAccessStats>,
    config: &AnalyzerConfig,
) -> HotPathResult<Vec<HotTable>> {
    let mut hot_tables: Vec<HotTable> = Vec::new();

    for stat in stats {
        let access_count = stat.read_count + stat.write_count;
        if access_count < config.min_executions {
            continue;
        }

        let sequential_read_ratio = if stat.blocks_read_total > 0 {
            stat.sequential_reads as f64 / stat.blocks_read_total as f64
        } else {
            0.0
        };

        let avg_rows_per_access = if access_count > 0 {
            stat.rows_read_total as f64 / access_count as f64
        } else {
            0.0
        };

        let cache_hit_ratio = if stat.cache_attempts > 0 {
            stat.cache_hits as f64 / stat.cache_attempts as f64
        } else {
            1.0
        };

        // Calculate impact score
        let frequency_score = (100.0_f64).min(((access_count + 1) as f64).log10() * 20.0);
        let io_score = (100.0_f64)
            .min(((stat.blocks_read_total + stat.blocks_written_total + 1) as f64).log10() * 20.0);
        let cache_inefficiency = 100.0 - (cache_hit_ratio * 100.0);
        let scan_score = if access_count > 0 {
            ((stat.table_scan_count as f64 / access_count as f64) * 100.0).min(100.0)
        } else {
            0.0
        };

        let impact_score = (frequency_score * 0.4)
            + (io_score * 0.3)
            + (cache_inefficiency * 0.2)
            + (scan_score * 0.1);

        hot_tables.push(HotTable {
            table_name: stat.table_name,
            schema_name: stat.schema_name,
            access_count,
            read_count: stat.read_count,
            write_count: stat.write_count,
            rows_read_total: stat.rows_read_total,
            rows_written_total: stat.rows_written_total,
            blocks_read_total: stat.blocks_read_total,
            blocks_written_total: stat.blocks_written_total,
            sequential_read_ratio,
            avg_rows_per_access,
            table_size_bytes: stat.table_size_bytes,
            cache_hit_ratio,
            table_scan_count: stat.table_scan_count,
            index_scan_count: stat.index_scan_count,
            impact_score: impact_score.min(100.0),
        });
    }

    // Sort by impact score descending
    hot_tables.sort_by(|a, b| b.impact_score.partial_cmp(&a.impact_score).unwrap());

    // Limit results
    hot_tables.truncate(config.limit);

    Ok(hot_tables)
}

/// Identify hot pages from access statistics.
///
/// # Arguments
/// * `stats` - Page access statistics
/// * `config` - Analyzer configuration
///
/// # Returns
/// Vector of HotPage sorted by impact score
pub fn identify_hot_pages(
    stats: Vec<PageAccessStats>,
    config: &AnalyzerConfig,
) -> HotPathResult<Vec<HotPage>> {
    let mut hot_pages: Vec<HotPage> = Vec::new();

    for stat in stats {
        if stat.access_count < config.min_executions {
            continue;
        }

        let duration_secs = (stat.last_access - stat.first_access).num_seconds().max(60) as f64;
        let access_frequency_per_min = (stat.access_count as f64 / duration_secs) * 60.0;

        // Calculate impact score
        let frequency_score = (100.0_f64).min(((stat.access_count + 1) as f64).log10() * 20.0);
        let eviction_score = (100.0_f64).min(((stat.cache_evictions + 1) as f64).log10() * 20.0);
        let contention_score = stat.read_contention.min(100.0);

        let impact_score = (frequency_score * 0.5) + (eviction_score * 0.3) + (contention_score * 0.2);

        hot_pages.push(HotPage {
            page_id: stat.page_id,
            page_type: stat.page_type,
            table_name: stat.table_name,
            access_count: stat.access_count,
            access_frequency_per_min,
            last_access_time: stat.last_access,
            first_access_time: stat.first_access,
            is_currently_cached: stat.is_cached,
            cache_evictions: stat.cache_evictions,
            avg_cache_residence_time_ms: stat.avg_residence_time_ms,
            read_contention: stat.read_contention,
            impact_score: impact_score.min(100.0),
        });
    }

    // Sort by impact score descending
    hot_pages.sort_by(|a, b| b.impact_score.partial_cmp(&a.impact_score).unwrap());

    // Limit results
    hot_pages.truncate(config.limit);

    Ok(hot_pages)
}

/// Calculate percentile from sorted data.
fn percentile(sorted_data: &[f64], percentile: u8) -> f64 {
    if sorted_data.is_empty() {
        return 0.0;
    }

    let index = ((percentile as f64 / 100.0) * sorted_data.len() as f64).floor() as usize;
    sorted_data.get(index).copied().unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_impact_score_calculation() {
        let config = AnalyzerConfig::default();

        // High frequency, low cost
        let score1 = calculate_impact_score(1000, 10.0, &config);
        // Low frequency, high cost
        let score2 = calculate_impact_score(10, 1000.0, &config);

        // Frequency weighted more than cost
        assert!(score1 > score2);
    }

    #[test]
    fn test_identify_hot_queries_empty() {
        let executions = Vec::new();
        let config = AnalyzerConfig::default();
        let result = identify_hot_queries(executions, &config).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_identify_hot_queries_grouping() {
        let executions = vec![
            QueryExecution {
                query_text: "SELECT * FROM users WHERE age > 25".to_string(),
                execution_time_ms: 1.0,
                rows_returned: 10,
                rows_read: 100,
                blocks_read: 5,
                cache_hits: 4,
                cache_attempts: 5,
                timestamp: Utc::now(),
            },
            QueryExecution {
                query_text: "SELECT * FROM users WHERE age > 30".to_string(),
                execution_time_ms: 1.5,
                rows_returned: 15,
                rows_read: 150,
                blocks_read: 7,
                cache_hits: 6,
                cache_attempts: 7,
                timestamp: Utc::now(),
            },
        ];

        let mut config = AnalyzerConfig::default();
        config.min_executions = 2;

        let result = identify_hot_queries(executions, &config).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].execution_count, 2);
    }

    #[test]
    fn test_identify_hot_tables() {
        let stats = vec![TableAccessStats {
            table_name: "users".to_string(),
            schema_name: "public".to_string(),
            read_count: 1000,
            write_count: 100,
            rows_read_total: 50000,
            rows_written_total: 5000,
            blocks_read_total: 1000,
            blocks_written_total: 100,
            sequential_reads: 800,
            table_size_bytes: 1024 * 1024,
            cache_hits: 900,
            cache_attempts: 1000,
            table_scan_count: 10,
            index_scan_count: 1090,
        }];

        let config = AnalyzerConfig::default();
        let result = identify_hot_tables(stats, &config).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].table_name, "users");
        assert_eq!(result[0].access_count, 1100);
    }

    #[test]
    fn test_hot_query_validation() {
        let query = HotQuery {
            query_pattern: Arc::from("SELECT * FROM users WHERE age > $LIT"),
            query_hash: 123,
            execution_count: 100,
            total_execution_time_ms: 500.0,
            avg_execution_time_ms: 5.0,
            min_execution_time_ms: 1.0,
            max_execution_time_ms: 10.0,
            p50_execution_time_ms: 4.0,
            p95_execution_time_ms: 8.0,
            p99_execution_time_ms: 9.0,
            rows_returned_total: 1000,
            rows_returned_avg: 10.0,
            rows_read_total: 5000,
            blocks_read_total: 250,
            cache_hit_ratio: 0.9,
            first_seen: Utc::now(),
            last_seen: Utc::now(),
            sample_query_text: "SELECT * FROM users WHERE age > 25".to_string(),
            impact_score: 85.5,
        };

        assert!(query.validate().is_ok());
    }

    #[test]
    fn test_hot_table_validation() {
        let table = HotTable {
            table_name: "users".to_string(),
            schema_name: "public".to_string(),
            access_count: 1100,
            read_count: 1000,
            write_count: 100,
            rows_read_total: 50000,
            rows_written_total: 5000,
            blocks_read_total: 1000,
            blocks_written_total: 100,
            sequential_read_ratio: 0.8,
            avg_rows_per_access: 45.45,
            table_size_bytes: 1024 * 1024,
            cache_hit_ratio: 0.9,
            table_scan_count: 10,
            index_scan_count: 1090,
            impact_score: 92.1,
        };

        assert!(table.validate().is_ok());
    }

    #[test]
    fn test_percentile_calculation() {
        let data = vec
![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0];
        assert_eq!(percentile(&data, 50), 5.0);
        assert_eq!(percentile(&data, 95), 10.0);
    }
}
