//! Hot Path Identification Types
//!
//! This module defines the core types for identifying and analyzing hot paths
//! in database operations, including hot queries, tables, indexes, pages, and
//! performance bottlenecks.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::types::PageId;

/// Comprehensive report analyzing hot paths across the entire database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotPathReport {
    /// Unique identifier for this report
    pub report_id: u64,
    /// When the report was generated
    pub generated_at: DateTime<Utc>,
    /// Start of data collection period
    pub analysis_period_start: DateTime<Utc>,
    /// End of data collection period
    pub analysis_period_end: DateTime<Utc>,
    /// Most frequently executed queries
    pub hot_queries: Vec<HotQuery>,
    /// Most accessed tables
    pub hot_tables: Vec<HotTable>,
    /// Most utilized indexes
    pub hot_indexes: Vec<HotIndex>,
    /// Most frequently accessed disk pages
    pub hot_pages: Vec<HotPage>,
    /// Most called stored procedures
    pub hot_procedures: Vec<HotProcedure>,
    /// Identified performance bottlenecks
    pub bottlenecks: Vec<Bottleneck>,
    /// Suggested optimizations
    pub optimization_opportunities: Vec<OptimizationOpportunity>,
}

impl HotPathReport {
    /// Create a new hot path report.
    pub fn new(
        report_id: u64,
        generated_at: DateTime<Utc>,
        analysis_period_start: DateTime<Utc>,
        analysis_period_end: DateTime<Utc>,
    ) -> Self {
        Self {
            report_id,
            generated_at,
            analysis_period_start,
            analysis_period_end,
            hot_queries: Vec::new(),
            hot_tables: Vec::new(),
            hot_indexes: Vec::new(),
            hot_pages: Vec::new(),
            hot_procedures: Vec::new(),
            bottlenecks: Vec::new(),
            optimization_opportunities: Vec::new(),
        }
    }

    /// Validate the report's invariants.
    pub fn validate(&self) -> Result<(), String> {
        if self.analysis_period_end < self.analysis_period_start {
            return Err("Analysis period end is before start".to_string());
        }

        let period_secs = (self.analysis_period_end - self.analysis_period_start).num_seconds();
        if period_secs < 60 {
            return Err("Analysis period is too short (minimum 1 minute)".to_string());
        }
        if period_secs > 90 * 24 * 60 * 60 {
            return Err("Analysis period is too long (maximum 90 days)".to_string());
        }

        // Check that vectors are sorted by impact score
        if !self.hot_queries.is_sorted_by(|a, b| a.impact_score >= b.impact_score) {
            return Err("Hot queries not sorted by impact score".to_string());
        }
        if !self.hot_tables.is_sorted_by(|a, b| a.impact_score >= b.impact_score) {
            return Err("Hot tables not sorted by impact score".to_string());
        }
        if !self.hot_indexes.is_sorted_by(|a, b| a.impact_score >= b.impact_score) {
            return Err("Hot indexes not sorted by impact score".to_string());
        }
        if !self.hot_pages.is_sorted_by(|a, b| a.impact_score >= b.impact_score) {
            return Err("Hot pages not sorted by impact score".to_string());
        }
        if !self.hot_procedures.is_sorted_by(|a, b| a.impact_score >= b.impact_score) {
            return Err("Hot procedures not sorted by impact score".to_string());
        }

        Ok(())
    }
}

/// Represents a query pattern that is executed frequently or consumes significant resources.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotQuery {
    /// Normalized query text (parameters removed)
    pub query_pattern: String,
    /// Hash of normalized query for grouping
    pub query_hash: u64,
    /// Number of times this query was executed
    pub execution_count: u64,
    /// Cumulative execution time
    pub total_execution_time_ms: f64,
    /// Average execution time per execution
    pub avg_execution_time_ms: f64,
    /// Fastest execution
    pub min_execution_time_ms: f64,
    /// Slowest execution
    pub max_execution_time_ms: f64,
    /// Median execution time
    pub p50_execution_time_ms: f64,
    /// 95th percentile execution time
    pub p95_execution_time_ms: f64,
    /// 99th percentile execution time
    pub p99_execution_time_ms: f64,
    /// Total rows returned across all executions
    pub rows_returned_total: u64,
    /// Average rows returned per execution
    pub rows_returned_avg: f64,
    /// Total rows scanned across all executions
    pub rows_read_total: u64,
    /// Total disk blocks read
    pub blocks_read_total: u64,
    /// Fraction of blocks served from cache
    pub cache_hit_ratio: f64,
    /// First time this query was observed
    pub first_seen: DateTime<Utc>,
    /// Most recent execution
    pub last_seen: DateTime<Utc>,
    /// Example of actual query with parameters
    pub sample_query_text: String,
    /// Combined measure of frequency and cost (0.0 to 100.0)
    pub impact_score: f64,
}

impl HotQuery {
    /// Validate the hot query's invariants.
    pub fn validate(&self) -> Result<(), String> {
        if self.execution_count == 0 {
            return Err("Execution count must be positive".to_string());
        }

        let expected_avg = self.total_execution_time_ms / self.execution_count as f64;
        if (self.avg_execution_time_ms - expected_avg).abs() > 0.01 {
            return Err(format!(
                "Avg execution time mismatch: expected {}, got {}",
                expected_avg, self.avg_execution_time_ms
            ));
        }

        if self.min_execution_time_ms > self.avg_execution_time_ms {
            return Err("Min execution time greater than avg".to_string());
        }

        if self.max_execution_time_ms < self.avg_execution_time_ms {
            return Err("Max execution time less than avg".to_string());
        }

        if self.p50_execution_time_ms > self.p95_execution_time_ms
            || self.p95_execution_time_ms > self.p99_execution_time_ms
        {
            return Err("Percentiles not monotonically increasing".to_string());
        }

        if !(0.0..=1.0).contains(&self.cache_hit_ratio) {
            return Err(format!("Cache hit ratio out of range: {}", self.cache_hit_ratio));
        }

        if self.last_seen < self.first_seen {
            return Err("Last seen before first seen".to_string());
        }

        if !(0.0..=100.0).contains(&self.impact_score) {
            return Err(format!("Impact score out of range: {}", self.impact_score));
        }

        Ok(())
    }
}

/// Identifies tables that experience high access frequency or large I/O volumes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotTable {
    /// Name of the table
    pub table_name: String,
    /// Schema containing the table
    pub schema_name: String,
    /// Number of times table was accessed (any operation)
    pub access_count: u64,
    /// Number of read operations
    pub read_count: u64,
    /// Number of write operations (insert, update, delete)
    pub write_count: u64,
    /// Total rows read from table
    pub rows_read_total: u64,
    /// Total rows written to table
    pub rows_written_total: u64,
    /// Total disk blocks read
    pub blocks_read_total: u64,
    /// Total disk blocks written
    pub blocks_written_total: u64,
    /// Fraction of reads that were sequential
    pub sequential_read_ratio: f64,
    /// Average rows touched per access
    pub avg_rows_per_access: f64,
    /// Current table size on disk
    pub table_size_bytes: u64,
    /// Fraction of table blocks served from cache
    pub cache_hit_ratio: f64,
    /// Number of full table scans
    pub table_scan_count: u64,
    /// Number of index-based accesses
    pub index_scan_count: u64,
    /// Combined measure of frequency and cost (0.0 to 100.0)
    pub impact_score: f64,
}

impl HotTable {
    /// Validate the hot table's invariants.
    pub fn validate(&self) -> Result<(), String> {
        if self.access_count != self.read_count + self.write_count {
            return Err(format!(
                "Access count mismatch: {} != {} + {}",
                self.access_count, self.read_count, self.write_count
            ));
        }

        if !(0.0..=1.0).contains(&self.sequential_read_ratio) {
            return Err(format!(
                "Sequential read ratio out of range: {}",
                self.sequential_read_ratio
            ));
        }

        if !(0.0..=1.0).contains(&self.cache_hit_ratio) {
            return Err(format!("Cache hit ratio out of range: {}", self.cache_hit_ratio));
        }

        if !(0.0..=100.0).contains(&self.impact_score) {
            return Err(format!("Impact score out of range: {}", self.impact_score));
        }

        Ok(())
    }
}

/// Identifies indexes that experience heavy usage or provide significant performance benefits.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotIndex {
    /// Name of the index
    pub index_name: String,
    /// Table containing the index
    pub table_name: String,
    /// Type of index
    pub index_type: IndexType,
    /// Columns in the index key
    pub indexed_columns: Vec<String>,
    /// Number of point lookup operations
    pub seek_count: u64,
    /// Number of range scan operations
    pub scan_count: u64,
    /// Total rows retrieved via index
    pub rows_returned_total: u64,
    /// Total index pages read
    pub index_pages_read: u64,
    /// Count of scans that didn't require table access
    pub index_only_scans: u64,
    /// Average index depth traversed per operation
    pub avg_seeks_per_scan: f64,
    /// Average selectivity (fraction of rows returned)
    pub selectivity_avg: f64,
    /// Fraction of index pages from cache
    pub cache_hit_ratio: f64,
    /// Current index size on disk
    pub index_size_bytes: u64,
    /// Number of index updates due to table modifications
    pub maintenance_operations: u64,
    /// Combined measure of frequency and benefit (0.0 to 100.0)
    pub impact_score: f64,
}

impl HotIndex {
    /// Validate the hot index's invariants.
    pub fn validate(&self) -> Result<(), String> {
        if !(0.0..=1.0).contains(&self.selectivity_avg) {
            return Err(format!("Selectivity out of range: {}", self.selectivity_avg));
        }

        if !(0.0..=1.0).contains(&self.cache_hit_ratio) {
            return Err(format!("Cache hit ratio out of range: {}", self.cache_hit_ratio));
        }

        if !(0.0..=100.0).contains(&self.impact_score) {
            return Err(format!("Impact score out of range: {}", self.impact_score));
        }

        Ok(())
    }
}

/// Type of index.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum IndexType {
    /// B+tree index
    BTree,
    /// Hash index
    Hash,
    /// GiST index
    GiST,
    /// GIN index
    GIN,
    /// BRIN index
    BRIN,
    /// Other index type
    Other,
}

/// Identifies specific database pages that are accessed extremely frequently.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotPage {
    /// Unique page identifier
    pub page_id: PageId,
    /// Type of page
    pub page_type: PageType,
    /// Table containing the page
    pub table_name: String,
    /// Number of times page was accessed
    pub access_count: u64,
    /// Average accesses per minute
    pub access_frequency_per_min: f64,
    /// Most recent access
    pub last_access_time: DateTime<Utc>,
    /// Oldest access in period
    pub first_access_time: DateTime<Utc>,
    /// Whether page is currently in memory cache
    pub is_currently_cached: bool,
    /// Number of times page was evicted from cache
    pub cache_evictions: u64,
    /// Average time page stays in cache when loaded
    pub avg_cache_residence_time_ms: f64,
    /// Measure of concurrent access attempts
    pub read_contention: f64,
    /// Combined measure of frequency and criticality (0.0 to 100.0)
    pub impact_score: f64,
}

impl HotPage {
    /// Validate the hot page's invariants.
    pub fn validate(&self) -> Result<(), String> {
        if self.access_count == 0 {
            return Err("Access count must be positive".to_string());
        }

        if self.access_frequency_per_min < 0.0 {
            return Err("Access frequency per min is negative".to_string());
        }

        if self.last_access_time < self.first_access_time {
            return Err("Last access before first access".to_string());
        }

        if !(0.0..=100.0).contains(&self.impact_score) {
            return Err(format!("Impact score out of range: {}", self.impact_score));
        }

        Ok(())
    }
}

/// Type of database page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PageType {
    /// Table data page
    DataPage,
    /// Index leaf level page
    IndexLeafPage,
    /// Index internal routing page
    InternalPage,
    /// Database metadata page
    MetadataPage,
    /// Overflow page for large values
    OverflowPage,
    /// Currently unused page
    FreePage,
}

/// Identifies stored procedures or functions that are called frequently.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotProcedure {
    /// Name of the procedure
    pub procedure_name: String,
    /// Schema containing the procedure
    pub schema_name: String,
    /// Number of times procedure was called
    pub invocation_count: u64,
    /// Cumulative execution time
    pub total_execution_time_ms: f64,
    /// Average execution time per call
    pub avg_execution_time_ms: f64,
    /// Fastest execution
    pub min_execution_time_ms: f64,
    /// Slowest execution
    pub max_execution_time_ms: f64,
    /// Total rows affected by procedure
    pub rows_affected_total: u64,
    /// Number of times procedure raised an error
    pub errors_count: u64,
    /// Average memory consumption per execution
    pub avg_memory_bytes: f64,
    /// Combined measure of frequency and cost (0.0 to 100.0)
    pub impact_score: f64,
}

impl HotProcedure {
    /// Validate the hot procedure's invariants.
    pub fn validate(&self) -> Result<(), String> {
        if self.invocation_count == 0 {
            return Err("Invocation count must be positive".to_string());
        }

        let expected_avg = self.total_execution_time_ms / self.invocation_count as f64;
        if (self.avg_execution_time_ms - expected_avg).abs() > 0.01 {
            return Err(format!(
                "Avg execution time mismatch: expected {}, got {}",
                expected_avg, self.avg_execution_time_ms
            ));
        }

        if self.min_execution_time_ms > self.avg_execution_time_ms {
            return Err("Min execution time greater than avg".to_string());
        }

        if !(0.0..=100.0).contains(&self.impact_score) {
            return Err(format!("Impact score out of range: {}", self.impact_score));
        }

        Ok(())
    }
}

/// Identifies a specific performance bottleneck limiting overall system throughput.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bottleneck {
    /// Unique identifier for this bottleneck
    pub bottleneck_id: u64,
    /// Category of bottleneck
    pub bottleneck_type: BottleneckType,
    /// Impact level
    pub severity: Severity,
    /// Human-readable description of the bottleneck
    pub description: String,
    /// Database component experiencing the bottleneck
    pub affected_component: String,
    /// Current measurement value
    pub current_value: f64,
    /// Threshold at which this is considered a bottleneck
    pub threshold_value: f64,
    /// Percentage by which current exceeds threshold
    pub excess_pct: f64,
    /// Estimated performance impact in milliseconds
    pub estimated_impact_ms: f64,
    /// Query patterns affected by this bottleneck
    pub affected_queries: Vec<String>,
    /// Suggested action to resolve bottleneck
    pub suggested_remediation: String,
    /// Whether system can automatically fix this
    pub can_auto_remediate: bool,
}

impl Bottleneck {
    /// Validate the bottleneck's invariants.
    pub fn validate(&self) -> Result<(), String> {
        if self.current_value < self.threshold_value {
            return Err("Current value below threshold".to_string());
        }

        if self.excess_pct < 0.0 {
            return Err("Excess percentage is negative".to_string());
        }

        if self.estimated_impact_ms < 0.0 {
            return Err("Estimated impact is negative".to_string());
        }

        Ok(())
    }
}

/// Category of performance bottleneck.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BottleneckType {
    /// CPU usage at capacity
    CpuSaturation,
    /// Disk I/O at capacity
    IoSaturation,
    /// Insufficient memory causing cache pressure
    MemoryPressure,
    /// High lock wait times
    LockContention,
    /// Network delays in distributed setup
    NetworkLatency,
    /// High cache miss rate causing I/O
    CacheMissRatio,
    /// Write-ahead log flush delays
    WriteLogFlush,
    /// Excessive full table scans
    TableScan,
    /// N+1 query pattern inefficiency
    NPlusOne,
    /// Missing index causing table scans
    MissingIndex,
    /// Index fragmentation causing poor performance
    FragmentedIndex,
    /// Data skew causing uneven workload distribution
    SkewedData,
}

impl std::fmt::Display for BottleneckType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BottleneckType::CpuSaturation => write!(f, "CPU Saturation"),
            BottleneckType::IoSaturation => write!(f, "I/O Saturation"),
            BottleneckType::MemoryPressure => write!(f, "Memory Pressure"),
            BottleneckType::LockContention => write!(f, "Lock Contention"),
            BottleneckType::NetworkLatency => write!(f, "Network Latency"),
            BottleneckType::CacheMissRatio => write!(f, "Cache Miss Ratio"),
            BottleneckType::WriteLogFlush => write!(f, "WAL Flush Delay"),
            BottleneckType::TableScan => write!(f, "Table Scan"),
            BottleneckType::NPlusOne => write!(f, "N+1 Query Pattern"),
            BottleneckType::MissingIndex => write!(f, "Missing Index"),
            BottleneckType::FragmentedIndex => write!(f, "Fragmented Index"),
            BottleneckType::SkewedData => write!(f, "Skewed Data"),
        }
    }
}

/// Severity level of a bottleneck.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Severity {
    /// Minor impact, optimization opportunity
    Low,
    /// Noticeable impact, should address
    Medium,
    /// Significant impact, address soon
    High,
    /// Severe impact, address immediately
    Critical,
}

/// Suggests a specific optimization that could improve performance.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OptimizationOpportunity {
    /// Unique identifier
    pub opportunity_id: u64,
    /// Category of optimization
    pub opportunity_type: OptimizationType,
    /// Brief title of the optimization
    pub title: String,
    /// Detailed description of the optimization
    pub description: String,
    /// Description of current behavior
    pub current_state: String,
    /// Description of optimized behavior
    pub proposed_state: String,
    /// Expected performance improvement (percentage)
    pub estimated_benefit_pct: f64,
    /// Implementation effort required
    pub effort_level: EffortLevel,
    /// Risk associated with implementing this optimization
    pub risk_level: RiskLevel,
    /// Tables, indexes, or queries affected
    pub affected_objects: Vec<String>,
    /// Steps to implement the optimization
    pub implementation_steps: Vec<String>,
    /// How to undo the optimization if needed
    pub rollback_plan: String,
}

impl OptimizationOpportunity {
    /// Validate the optimization opportunity's invariants.
    pub fn validate(&self) -> Result<(), String> {
        if !(0.0..=100.0).contains(&self.estimated_benefit_pct) {
            return Err(format!(
                "Estimated benefit out of range: {}",
                self.estimated_benefit_pct
            ));
        }

        Ok(())
    }
}

/// Category of optimization opportunity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OptimizationType {
    /// Add a new index to speed up queries
    CreateIndex,
    /// Remove an unused index to reduce overhead
    DropUnusedIndex,
    /// Rebuild a fragmented index
    RebuildIndex,
    /// Add caching hint for frequently accessed data
    AddCacheHint,
    /// Suggest query rewrite for better performance
    RewriteQuery,
    /// Partition a large table
    PartitionTable,
    /// Update table statistics for better optimizer plans
    UpdateStatistics,
    /// Pin a hot page in cache
    PinPage,
    /// Increase cache size
    IncreaseCache,
    /// Adjust lock configuration
    TuneLocks,
    /// Create a materialized view for expensive queries
    CreateMaterializedView,
}

/// Effort required to implement an optimization.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EffortLevel {
    /// Can be done in minutes with no downtime
    Trivial,
    /// Can be done in hours with minimal testing
    Low,
    /// Requires significant testing and planning
    Medium,
    /// Major change requiring extensive testing
    High,
    /// Architectural change, requires careful design
    Complex,
}

/// Risk associated with an optimization.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum RiskLevel {
    /// Very low risk, easily reversible
    Minimal,
    /// Low risk, well-understood change
    Low,
    /// Moderate risk, requires testing
    Medium,
    /// High risk, may have unintended consequences
    High,
    /// Significant risk, requires thorough validation
    VeryHigh,
}

/// Represents a pattern of data access observed across multiple queries.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccessPattern {
    /// Unique identifier
    pub pattern_id: u64,
    /// Category of access pattern
    pub pattern_type: AccessPatternType,
    /// Tables accessed in this pattern
    pub tables_involved: Vec<String>,
    /// Columns frequently accessed together
    pub columns_involved: Vec<String>,
    /// Columns commonly used for joins
    pub join_keys: Vec<String>,
    /// Columns frequently used in filters
    pub filter_columns: Vec<String>,
    /// Columns frequently used for ordering
    pub sort_columns: Vec<String>,
    /// Number of queries exhibiting this pattern
    pub query_count: u64,
    /// How often this pattern occurs
    pub frequency_per_hour: f64,
    /// Average latency of queries with this pattern
    pub avg_latency_ms: f64,
}

/// Type of access pattern.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AccessPatternType {
    /// Accessing rows in sequential order
    SequentialAccess,
    /// Random access patterns
    RandomAccess,
    /// Scanning ranges of data
    RangeScan,
    /// Individual row lookups
    PointLookup,
    /// N+1 query anti-pattern
    NPlusOne,
    /// Full table or index scans
    FullScan,
    /// Queries with many joins
    JoinHeavy,
    /// Queries with complex aggregations
    AggregationHeavy,
}

// Import Arc removed - using String instead for serde compatibility
