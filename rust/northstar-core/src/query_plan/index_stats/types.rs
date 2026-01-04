//! Index Usage Statistics Types
//!
//! Core data structures for tracking and analyzing index performance.

use serde::{Deserialize, Serialize};

/// Type of index structure
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum IndexType {
    /// B+tree index (default, ordered)
    BTree,
    /// Hash index (equality lookups only)
    Hash,
    /// Bitmap index (low-cardinality columns)
    Bitmap,
    /// Full-text search index
    FullText,
    /// GiST (Generalized Search Tree)
    GiST,
    /// GIN (Generalized Inverted Index)
    GIN,
    /// SP-GiST (Space-partitioned GiST)
    SPGiST,
    /// BRIN (Block Range Index)
    BRIN,
}

impl Default for IndexType {
    fn default() -> Self {
        IndexType::BTree
    }
}

impl std::fmt::Display for IndexType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            IndexType::BTree => write!(f, "B+tree"),
            IndexType::Hash => write!(f, "Hash"),
            IndexType::Bitmap => write!(f, "Bitmap"),
            IndexType::FullText => write!(f, "Full-text"),
            IndexType::GiST => write!(f, "GiST"),
            IndexType::GIN => write!(f, "GIN"),
            IndexType::SPGiST => write!(f, "SP-GiST"),
            IndexType::BRIN => write!(f, "BRIN"),
        }
    }
}

/// Aggregated statistics for a single index over a time period
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexUsageStats {
    /// Name of the index
    pub index_name: String,
    /// Table containing the indexed columns
    pub table_name: String,
    /// Type of index
    pub index_type: IndexType,
    /// Column names comprising the index key
    pub indexed_columns: Vec<String>,
    /// Whether index enforces uniqueness constraint
    pub is_unique: bool,
    /// Whether this is the primary key index
    pub is_primary: bool,
    /// Start of statistics collection period (Unix timestamp)
    pub period_start: u64,
    /// End of statistics collection period (Unix timestamp)
    pub period_end: u64,
    /// Access pattern metrics
    pub access_stats: IndexAccessStats,
    /// Performance indicators
    pub efficiency_metrics: IndexEfficiencyMetrics,
    /// Storage and memory footprint
    pub size_stats: IndexSizeStats,
    /// Write amplification and overhead
    pub maintenance_stats: IndexMaintenanceStats,
}

impl IndexUsageStats {
    /// Validate invariants
    pub fn validate(&self) -> Result<(), String> {
        if self.period_end <= self.period_start {
            return Err("period_end must be after period_start".to_string());
        }
        if self.indexed_columns.is_empty() {
            return Err("indexed_columns cannot be empty".to_string());
        }
        if self.is_primary && !self.is_unique {
            return Err("is_primary implies is_unique".to_string());
        }

        self.access_stats.validate()?;
        self.efficiency_metrics.validate()?;
        self.size_stats.validate()?;
        self.maintenance_stats.validate()?;

        Ok(())
    }

    /// Calculate the duration of the statistics collection period in seconds
    pub fn period_duration_secs(&self) -> u64 {
        self.period_end - self.period_start
    }

    /// Calculate the duration of the statistics collection period in hours
    pub fn period_duration_hours(&self) -> f64 {
        self.period_duration_secs() as f64 / 3600.0
    }
}

/// Tracks how frequently and in what ways the index is accessed
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct IndexAccessStats {
    /// Number of index point lookups (single row retrieval)
    pub total_seeks: u64,
    /// Number of index range scans
    pub total_scans: u64,
    /// Number of times entire index was scanned
    pub total_full_scans: u64,
    /// Total rows retrieved via this index
    pub rows_returned: u64,
    /// Total index entries read (may exceed rows_returned)
    pub rows_read: u64,
    /// Scans that didn't require table access (covering index)
    pub index_only_scans: u64,
    /// Table lookups needed after index scan (non-covering)
    pub result_lookups: u64,
    /// Approximate count of distinct queries using this index
    pub unique_queries: u64,
    /// Most recent time index was used (Unix timestamp)
    pub last_access_time: Option<u64>,
    /// Average accesses per hour in period
    pub access_frequency_per_hour: f64,
}

impl IndexAccessStats {
    /// Validate invariants
    pub fn validate(&self) -> Result<(), String> {
        if self.rows_returned > self.rows_read {
            return Err("rows_returned cannot exceed rows_read".to_string());
        }
        if self.total_seeks + self.total_scans != self.index_only_scans + self.result_lookups {
            // This is expected during aggregation, so we just track totals
        }
        if self.access_frequency_per_hour < 0.0 {
            return Err("access_frequency_per_hour cannot be negative".to_string());
        }
        Ok(())
    }

    /// Calculate total index operations (seeks + scans)
    pub fn total_operations(&self) -> u64 {
        self.total_seeks + self.total_scans
    }

    /// Calculate the percentage of scans that were index-only
    pub fn index_only_scan_pct(&self) -> f64 {
        if self.total_scans == 0 {
            return 0.0;
        }
        (self.index_only_scans as f64 / self.total_scans as f64) * 100.0
    }
}

/// Measures how effective the index is at reducing work
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct IndexEfficiencyMetrics {
    /// Average fraction of rows returned per query (0.0 to 1.0)
    pub selectivity_avg: f64,
    /// Standard deviation of selectivity
    pub selectivity_stddev: f64,
    /// Average rows read per scan operation
    pub avg_rows_per_scan: f64,
    /// Median rows per scan
    pub p50_rows_per_scan: f64,
    /// 95th percentile rows per scan
    pub p95_rows_per_scan: f64,
    /// 99th percentile rows per scan
    pub p99_rows_per_scan: f64,
    /// Average index pages read per scan
    pub pages_read_per_scan_avg: f64,
    /// Number of levels in index tree
    pub index_depth: u32,
    /// Average index seeks required per query
    pub avg_seeks_per_query: f64,
    /// Fraction of index pages served from cache (0.0 to 1.0)
    pub cache_hit_ratio: f64,
}

impl IndexEfficiencyMetrics {
    /// Validate invariants
    pub fn validate(&self) -> Result<(), String> {
        if !(0.0..=1.0).contains(&self.selectivity_avg) {
            return Err("selectivity_avg must be between 0.0 and 1.0".to_string());
        }
        if self.selectivity_stddev < 0.0 {
            return Err("selectivity_stddev cannot be negative".to_string());
        }
        if self.p50_rows_per_scan > self.p95_rows_per_scan {
            return Err("p50_rows_per_scan cannot exceed p95_rows_per_scan".to_string());
        }
        if self.p95_rows_per_scan > self.p99_rows_per_scan {
            return Err("p95_rows_per_scan cannot exceed p99_rows_per_scan".to_string());
        }
        if !(0.0..=1.0).contains(&self.cache_hit_ratio) {
            return Err("cache_hit_ratio must be between 0.0 and 1.0".to_string());
        }
        Ok(())
    }

    /// Get selectivity rating as a human-readable label
    pub fn selectivity_rating(&self) -> &'static str {
        if self.selectivity_avg < 0.001 {
            "excellent"
        } else if self.selectivity_avg < 0.01 {
            "very good"
        } else if self.selectivity_avg < 0.1 {
            "good"
        } else if self.selectivity_avg < 0.5 {
            "fair"
        } else {
            "poor"
        }
    }
}

/// Tracks the storage and memory footprint of the index
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct IndexSizeStats {
    /// Total pages allocated to index
    pub total_pages: u64,
    /// Number of leaf-level pages containing data
    pub leaf_pages: u64,
    /// Number of internal routing pages
    pub internal_pages: u64,
    /// Total disk space consumed by index in bytes
    pub total_size_bytes: u64,
    /// Average fill percentage of leaf pages
    pub avg_leaf_fill_pct: f64,
    /// Average fill percentage of internal pages
    pub avg_internal_fill_pct: f64,
    /// Percentage of wasted space due to fragmentation
    pub fragmentation_pct: f64,
    /// Number of index pages currently in cache
    pub cache_pages: u64,
    /// Memory used for cached index pages in bytes
    pub cache_memory_bytes: u64,
}

impl IndexSizeStats {
    /// Validate invariants
    pub fn validate(&self) -> Result<(), String> {
        if self.total_pages != self.leaf_pages + self.internal_pages {
            return Err("total_pages must equal leaf_pages + internal_pages".to_string());
        }
        if !(0.0..=100.0).contains(&self.avg_leaf_fill_pct) {
            return Err("avg_leaf_fill_pct must be between 0.0 and 100.0".to_string());
        }
        if !(0.0..=100.0).contains(&self.avg_internal_fill_pct) {
            return Err("avg_internal_fill_pct must be between 0.0 and 100.0".to_string());
        }
        if !(0.0..=100.0).contains(&self.fragmentation_pct) {
            return Err("fragmentation_pct must be between 0.0 and 100.0".to_string());
        }
        Ok(())
    }

    /// Format size in human-readable format (e.g., "9.8 MB")
    pub fn format_size(&self) -> String {
        const KB: u64 = 1024;
        const MB: u64 = 1024 * KB;
        const GB: u64 = 1024 * MB;

        if self.total_size_bytes >= GB {
            format!("{:.1} GB", self.total_size_bytes as f64 / GB as f64)
        } else if self.total_size_bytes >= MB {
            format!("{:.1} MB", self.total_size_bytes as f64 / MB as f64)
        } else if self.total_size_bytes >= KB {
            format!("{:.1} KB", self.total_size_bytes as f64 / KB as f64)
        } else {
            format!("{} B", self.total_size_bytes)
        }
    }
}

/// Tracks the cost of maintaining the index during write operations
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct IndexMaintenanceStats {
    /// Number of insert operations that required index updates
    pub inserts_handled: u64,
    /// Number of update operations that required index updates
    pub updates_handled: u64,
    /// Number of delete operations that required index updates
    pub deletes_handled: u64,
    /// Number of page splits caused by index inserts
    pub pages_split: u64,
    /// Number of page merges from index deletes
    pub pages_merged: u64,
    /// Average microseconds per index insert
    pub avg_insert_time_us: f64,
    /// Average microseconds per index delete
    pub avg_delete_time_us: f64,
    /// Ratio of index pages written to table pages written
    pub write_amplification: f64,
    /// Percentage of total write time spent on index
    pub maintenance_overhead_pct: f64,
}

impl IndexMaintenanceStats {
    /// Validate invariants
    pub fn validate(&self) -> Result<(), String> {
        if self.write_amplification < 0.0 {
            return Err("write_amplification cannot be negative".to_string());
        }
        if !(0.0..=100.0).contains(&self.maintenance_overhead_pct) {
            return Err("maintenance_overhead_pct must be between 0.0 and 100.0".to_string());
        }
        Ok(())
    }

    /// Calculate total write operations
    pub fn total_writes(&self) -> u64 {
        self.inserts_handled + self.updates_handled + self.deletes_handled
    }
}

/// Point-in-time capture of index usage statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexUsageSnapshot {
    /// Unique identifier for this snapshot
    pub snapshot_id: u64,
    /// When the snapshot was taken (Unix timestamp)
    pub captured_at: u64,
    /// Statistics for all indexes at this moment
    pub index_stats: Vec<IndexUsageStats>,
}

impl IndexUsageSnapshot {
    /// Create a new snapshot
    pub fn new(snapshot_id: u64, captured_at: u64, index_stats: Vec<IndexUsageStats>) -> Self {
        Self {
            snapshot_id,
            captured_at,
            index_stats,
        }
    }

    /// Get statistics for a specific index by name
    pub fn get_index_stats(&self, index_name: &str) -> Option<&IndexUsageStats> {
        self.index_stats
            .iter()
            .find(|stats| stats.index_name == index_name)
    }

    /// Get all indexes for a specific table
    pub fn get_table_indexes(&self, table_name: &str) -> Vec<&IndexUsageStats> {
        self.index_stats
            .iter()
            .filter(|stats| stats.table_name == table_name)
            .collect()
    }

    /// Count the number of indexes in the snapshot
    pub fn index_count(&self) -> usize {
        self.index_stats.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_index_type_display() {
        assert_eq!(format!("{}", IndexType::BTree), "B+tree");
        assert_eq!(format!("{}", IndexType::Hash), "Hash");
        assert_eq!(format!("{}", IndexType::Bitmap), "Bitmap");
    }

    #[test]
    fn test_index_access_stats_operations() {
        let stats = IndexAccessStats {
            total_seeks: 100,
            total_scans: 50,
            index_only_scans: 30,
            rows_returned: 1000,
            rows_read: 1200,
            ..Default::default()
        };

        assert_eq!(stats.total_operations(), 150);
        assert_eq!(stats.index_only_scan_pct(), 60.0);
    }

    #[test]
    fn test_index_access_stats_zero_scans() {
        let stats = IndexAccessStats {
            total_scans: 0,
            index_only_scans: 0,
            ..Default::default()
        };

        assert_eq!(stats.index_only_scan_pct(), 0.0);
    }

    #[test]
    fn test_efficiency_metrics_ratings() {
        let excellent = IndexEfficiencyMetrics {
            selectivity_avg: 0.0001,
            ..Default::default()
        };
        assert_eq!(excellent.selectivity_rating(), "excellent");

        let poor = IndexEfficiencyMetrics {
            selectivity_avg: 0.6,
            ..Default::default()
        };
        assert_eq!(poor.selectivity_rating(), "poor");
    }

    #[test]
    fn test_size_stats_formatting() {
        let stats = IndexSizeStats {
            total_size_bytes: 1024,
            ..Default::default()
        };
        assert!(stats.format_size().contains("KB"));

        let stats = IndexSizeStats {
            total_size_bytes: 10_270_604,
            ..Default::default()
        };
        assert!(stats.format_size().contains("MB"));
    }

    #[test]
    fn test_maintenance_stats_total_writes() {
        let stats = IndexMaintenanceStats {
            inserts_handled: 100,
            updates_handled: 50,
            deletes_handled: 25,
            ..Default::default()
        };

        assert_eq!(stats.total_writes(), 175);
    }

    #[test]
    fn test_snapshot_queries() {
        let stats1 = IndexUsageStats {
            index_name: "idx1".to_string(),
            table_name: "users".to_string(),
            ..create_test_stats_base()
        };

        let stats2 = IndexUsageStats {
            index_name: "idx2".to_string(),
            table_name: "orders".to_string(),
            ..create_test_stats_base()
        };

        let snapshot = IndexUsageSnapshot::new(1, 1000, vec![stats1, stats2]);

        assert_eq!(snapshot.index_count(), 2);
        assert!(snapshot.get_index_stats("idx1").is_some());
        assert!(snapshot.get_index_stats("idx2").is_some());
        assert!(snapshot.get_index_stats("idx3").is_none());
        assert_eq!(snapshot.get_table_indexes("users").len(), 1);
        assert_eq!(snapshot.get_table_indexes("orders").len(), 1);
    }

    #[test]
    fn test_index_usage_stats_validation() {
        let stats = create_test_stats_base();

        // Valid stats should pass
        assert!(stats.validate().is_ok());

        // Invalid period
        let mut invalid = stats.clone();
        invalid.period_end = invalid.period_start - 100;
        assert!(invalid.validate().is_err());

        // Empty columns
        let mut invalid = stats.clone();
        invalid.indexed_columns = vec![];
        assert!(invalid.validate().is_err());

        // Primary without unique
        let mut invalid = stats.clone();
        invalid.is_primary = true;
        invalid.is_unique = false;
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_index_usage_stats_period_duration() {
        let stats = IndexUsageStats {
            period_start: 1000,
            period_end: 5000,
            ..create_test_stats_base()
        };

        assert_eq!(stats.period_duration_secs(), 4000);
        assert!((stats.period_duration_hours() - 1.111).abs() < 0.01);
    }

    fn create_test_stats_base() -> IndexUsageStats {
        IndexUsageStats {
            index_name: "test_idx".to_string(),
            table_name: "test_table".to_string(),
            index_type: IndexType::BTree,
            indexed_columns: vec!["col1".to_string()],
            is_unique: true,
            is_primary: false,
            period_start: 1000,
            period_end: 2000,
            access_stats: Default::default(),
            efficiency_metrics: Default::default(),
            size_stats: Default::default(),
            maintenance_stats: Default::default(),
        }
    }
}
