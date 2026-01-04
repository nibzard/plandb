# Index Usage Statistics

## Purpose

Index Usage Statistics provides comprehensive tracking and analysis of index performance and effectiveness within the database. This module enables database administrators and automated systems to understand which indexes are being used, how efficiently they are performing, and which indexes might be candidates for removal or optimization. By tracking index access patterns, selectivity, and maintenance costs, the system can make data-driven decisions about index management and query optimization.

## Types

### IndexUsageStats

**Description**: Aggregated statistics for a single index over a time period. Represents the complete picture of how an index is being utilized by the workload.

**Fields**:
- index_name: String - Name of the index
- table_name: String - Table containing the indexed columns
- index_type: IndexType - Type of index (B+tree, hash, bitmap, etc.)
- indexed_columns: Vec<String> - Column names comprising the index key
- is_unique: bool - Whether index enforces uniqueness constraint
- is_primary: bool - Whether this is the primary key index
- period_start: Timestamp - Start of statistics collection period
- period_end: Timestamp - End of statistics collection period
- access_stats: IndexAccessStats - Access pattern metrics
- efficiency_metrics: IndexEfficiencyMetrics - Performance indicators
- size_stats: IndexSizeStats - Storage and memory footprint
- maintenance_stats: IndexMaintenanceStats - Write amplification and overhead

**Invariants**:
- period_end is after period_start
- indexed_columns vector is non-empty
- is_primary implies is_unique

### IndexAccessStats

**Description**: Tracks how frequently and in what ways the index is accessed during query execution.

**Fields**:
- total_seeks: u64 - Number of index point lookups (single row retrieval)
- total_scans: u64 - Number of index range scans
- total_full_scans: u64 - Number of times entire index was scanned
- rows_returned: u64 - Total rows retrieved via this index
- rows_read: u64 - Total index entries read (may exceed rows_returned)
- index_only_scans: u64 - Scans that didn't require table access (covering index)
- result_lookups: u64 - Table lookups needed after index scan (non-covering)
- unique_queries: u64 - Approximate count of distinct queries using this index
- last_access_time: Option<Timestamp> - Most recent time index was used
- access_frequency_per_hour: f64 - Average accesses per hour in period

**Invariants**:
- rows_returned is less than or equal to rows_read
- index_only_scans plus result_lookups equals total_scans
- total_seeks, total_scans, total_full_scans are non-negative
- access_frequency_per_hour is non-negative

### IndexEfficiencyMetrics

**Description**: Measures how effective the index is at reducing work compared to alternatives like table scans.

**Fields**:
- selectivity_avg: f64 - Average fraction of rows returned per query (0.0 to 1.0)
- selectivity_stddev: f64 - Standard deviation of selectivity
- avg_rows_per_scan: f64 - Average rows read per scan operation
- p50_rows_per_scan: f64 - Median rows per scan
- p95_rows_per_scan: f64 - 95th percentile rows per scan
- p99_rows_per_scan: f64 - 99th percentile rows per scan
- pages_read_per_scan_avg: f64 - Average index pages read per scan
- index_depth: u32 - Number of levels in index tree
- avg_seeks_per_query: f64 - Average index seeks required per query
- cache_hit_ratio: f64 - Fraction of index pages served from cache (0.0 to 1.0)

**Invariants**:
- selectivity_avg is between 0.0 and 1.0
- selectivity_stddev is non-negative
- p50_rows_per_scan is less than or equal to p95_rows_per_scan
- p95_rows_per_scan is less than or equal to p99_rows_per_scan
- cache_hit_ratio is between 0.0 and 1.0

### IndexSizeStats

**Description**: Tracks the storage and memory footprint of the index.

**Fields**:
- total_pages: u64 - Total pages allocated to index
- leaf_pages: u64 - Number of leaf-level pages containing data
- internal_pages: u64 - Number of internal routing pages
- total_size_bytes: u64 - Total disk space consumed by index
- avg_leaf_fill_pct: f64 - Average fill percentage of leaf pages
- avg_internal_fill_pct: f64 - Average fill percentage of internal pages
- fragmentation_pct: f64 - Percentage of wasted space due to fragmentation
- cache_pages: u64 - Number of index pages currently in cache
- cache_memory_bytes: u64 - Memory used for cached index pages

**Invariants**:
- total_pages equals leaf_pages plus internal_pages
- total_size_bytes is non-negative
- avg_leaf_fill_pct and avg_internal_fill_pct are between 0.0 and 100.0
- fragmentation_pct is between 0.0 and 100.0

### IndexMaintenanceStats

**Description**: Tracks the cost of maintaining the index during write operations.

**Fields**:
- inserts_handled: u64 - Number of insert operations that required index updates
- updates_handled: u64 - Number of update operations that required index updates
- deletes_handled: u64 - Number of delete operations that required index updates
- pages_split: u64 - Number of page splits caused by index inserts
- pages_merged: u64 - Number of page merges from index deletes
- avg_insert_time_us: f64 - Average microseconds per index insert
- avg_delete_time_us: f64 - Average microseconds per index delete
- write_amplification: f64 - Ratio of index pages written to table pages written
- maintenance_overhead_pct: f64 - Percentage of total write time spent on index

**Invariants**:
- All counter values are non-negative
- write_amplification is non-negative
- maintenance_overhead_pct is between 0.0 and 100.0

### IndexUsageSnapshot

**Description**: Point-in-time capture of index usage statistics. Snapshots are taken at regular intervals to enable trend analysis.

**Fields**:
- snapshot_id: u64 - Unique identifier for this snapshot
- captured_at: Timestamp - When the snapshot was taken
- index_stats: Vec<IndexUsageStats> - Statistics for all indexes at this moment

### IndexUsageTrend

**Description**: Analysis of how index usage changes over time based on multiple snapshots.

**Fields**:
- index_name: String - Name of the index
- table_name: String - Table containing the index
- trend_direction: TrendDirection - Whether usage is increasing, decreasing, or stable
- access_rate_change_pct: f64 - Percentage change in access frequency
- selectivity_trend: SelectivityTrend - How selectivity is changing
- efficiency_trend: EfficiencyTrend - How efficiency is changing
- recommended_action: Option<RecommendedAction> - Suggested action based on trend
- confidence: f64 - Statistical confidence in trend analysis (0.0 to 1.0)

**Invariants**:
- confidence is between 0.0 and 1.0

### TrendDirection

**Description**: Qualitative classification of usage trends.

**Variants**:
- Increasing - Index usage is growing over time
- Decreasing - Index usage is declining over time
- Stable - Index usage remains consistent
- Volatile - Index usage fluctuates unpredictably

### SelectivityTrend

**Description**: How the selectivity of index queries is changing.

**Variants**:
- Improving - Queries are returning fewer rows (more selective)
- Degraded - Queries are returning more rows (less selective)
- Stable - Selectivity remains consistent

### EfficiencyTrend

**Description**: How the overall efficiency of the index is changing.

**Variants**:
- Improving - Cache hit ratio improving, scan times decreasing
- Degraded - Cache hit ratio declining, scan times increasing
- Stable - Performance remains consistent

### RecommendedAction

**Description**: Action to consider based on index usage analysis.

**Variants**:
- Keep - Index is valuable, maintain as-is
- Drop - Index is unused, consider dropping to reduce overhead
- Rebuild - Index is fragmented, rebuild to improve performance
- ModifyColumns - Adjust indexed columns based on query patterns
- CreateComposite - Combine with other indexes into composite index
- SplitComposite - Break composite index into separate indexes
- ResizePages - Adjust page size for better fit
- NoAction - No clear recommendation

### UnusedIndexReport

**Description**: Report identifying indexes that have seen little to no usage over a time period.

**Fields**:
- report_id: u64 - Unique identifier for the report
- period_start: Timestamp - Start of analysis period
- period_end: Timestamp - End of analysis period
- unused_indexes: Vec<UnusedIndexInfo> - List of potentially unused indexes
- total_unused_indexes: usize - Count of unused indexes
- potential_savings_bytes: u64 - Disk space that could be reclaimed
- potential_savings_overhead_pct: f64 - Percentage reduction in write overhead

### UnusedIndexInfo

**Description**: Details about a specific unused index.

**Fields**:
- index_name: String - Name of the index
- table_name: String - Table containing the index
- index_type: IndexType - Type of index
- indexed_columns: Vec<String> - Columns in index key
- total_accesses: u64 - Number of times index was accessed (should be low)
- days_since_last_access: u64 - Days since index was last used
- size_bytes: u64 - Current size on disk
- maintenance_cost_pct: f64 - Percentage of total index maintenance overhead
- drop_safety: DropSafety - Confidence that index can be safely dropped

### DropSafety

**Description**: Assessment of how safe it is to drop an index.

**Variants**:
- Safe - Index has not been used in the analysis period
- Caution - Index has rare usage, may be needed for specific queries
- Risky - Index is used for uncommon but critical queries
- Required - Index is needed for constraints (primary key, unique)

### IndexComparisonReport

**Description**: Compares multiple indexes on the same table to identify redundancy or opportunities for consolidation.

**Fields**:
- report_id: u64 - Unique identifier
- table_name: String - Table being analyzed
- indexes: Vec<IndexName> - Indexes being compared
- overlapping_indexes: Vec<IndexOverlap> - Pairs of indexes with significant overlap
- consolidation_opportunities: Vec<ConsolidationOpportunity> - Potential index merges
- redundant_indexes: Vec<RedundantIndex> - Indexes that are subsets of others

### IndexOverlap

**Description**: Describes overlap between two indexes.

**Fields**:
- index_a: String - First index name
- index_b: String - Second index name
- shared_columns: Vec<String> - Columns present in both indexes
- overlap_type: OverlapType - Nature of the overlap
- combined_usage: u64 - Total accesses across both indexes
- individual_usage_a: u64 - Accesses to index A only
- individual_usage_b: u64 - Accesses to index B only

### OverlapType

**Description**: How two indexes overlap.

**Variants**:
- Identical - Indexes have exactly the same columns
- Prefix - One index columns are a prefix of the other
- Partial - Indexes share some but not all columns
- None - No column overlap

### ConsolidationOpportunity

**Description**: Suggests combining multiple indexes into a more efficient single index.

**Fields**:
- proposed_index_columns: Vec<String> - Suggested composite index columns
- replaces_indexes: Vec<String> - Indexes that could be replaced
- estimated_benefit_pct: f64 - Expected reduction in maintenance overhead
- covers_queries: u64 - Number of queries that would use the consolidated index
- risk_assessment: ConsolidationRisk - Potential downsides

### ConsolidationRisk

**Description**: Risk level of index consolidation.

**Variants**:
- Low - Clear benefit with minimal risk
- Medium - Some queries may become slower
- High - Significant performance regression risk for some queries

## Functions

### collect_index_stats(conn: &Connection, index_name: &str) -> Result<IndexUsageStats>

**Purpose**: Gather current statistics for a specific index by querying internal statistics tables and runtime counters.

**Parameters**:
- conn: Active database connection for querying stats
- index_name: Name of the index to analyze

**Returns**: IndexUsageStats with all metrics populated for the current collection period

**Algorithm**:
1. Query internal index metadata table to get index definition (columns, type, uniqueness)
2. Query runtime counters for access statistics (seeks, scans, rows returned)
3. Query page allocation tables for size statistics (pages, size, fragmentation)
4. Query write-ahead log or mutation counters for maintenance statistics
5. Calculate derived metrics (selectivity, cache hit ratio, averages)
6. Populate and return complete IndexUsageStats structure

**Error Conditions**:
- IndexNotFoundError: Specified index does not exist
- StatsNotAvailableError: Statistics collection not enabled
- QueryError: Internal query to stats tables failed

**Concurrency**: Reads from statistics tables, safe for concurrent calls

### collect_all_index_stats(conn: &Connection) -> Result<Vec<IndexUsageStats>>

**Purpose**: Gather statistics for all indexes in the database in a single operation for comprehensive analysis.

**Parameters**:
- conn: Active database connection

**Returns**: Vector of IndexUsageStats, one for each index in the database

**Algorithm**:
1. Query list of all indexes from schema metadata
2. For each index, call collect_index_stats
3. Collect all results into a vector
4. Sort by table name and index name for consistent ordering
5. Return complete vector

**Concurrency**: Reads from statistics tables, safe for concurrent calls

### take_snapshot(conn: &Connection) -> Result<IndexUsageSnapshot>

**Purpose**: Create a point-in-time snapshot of all index statistics for trend analysis and historical comparison.

**Parameters**:
- conn: Active database connection

**Returns**: IndexUsageSnapshot containing statistics for all indexes

**Algorithm**:
1. Generate unique snapshot identifier using timestamp and counter
2. Capture current timestamp as snapshot time
3. Call collect_all_index_stats to gather current stats
4. Wrap stats in IndexUsageSnapshot structure with metadata
5. Persist snapshot to statistics history table
6. Return snapshot structure

**Concurrency**: Creates new snapshot, safe for concurrent calls

### analyze_usage_trend(index_name: &str, snapshots: Vec<IndexUsageSnapshot>) -> Result<IndexUsageTrend>

**Purpose**: Analyze multiple snapshots over time to identify trends in index usage, selectivity, and efficiency.

**Parameters**:
- index_name: Name of the index to analyze
- snapshots: Ordered vector of historical snapshots (oldest to newest)

**Returns**: IndexUsageTrend with analysis results and recommendations

**Algorithm**:
1. Extract stats for the specified index from each snapshot
2. Calculate linear regression of access frequency over time
3. Classify trend direction based on regression slope (increasing, decreasing, stable)
4. Analyze selectivity changes across snapshots
5. Compare cache hit ratios and scan times
6. Calculate statistical confidence based on variance and sample count
7. Determine recommended action based on combined trend signals
8. Return IndexUsageTrend structure

**Trend Classification**:
- Increasing: slope > threshold (e.g., +10% change)
- Decreasing: slope < -threshold
- Stable: -threshold <= slope <= threshold
- Volatile: variance > stability_threshold

**Concurrency**: Read-only analysis, safe for concurrent calls

### generate_unused_index_report(conn: &Connection, min_days_unused: u64, min_accesses: u64) -> Result<UnusedIndexReport>

**Purpose**: Identify indexes that have seen little or no usage over a recent time period, indicating potential candidates for removal.

**Parameters**:
- conn: Active database connection
- min_days_unused: Minimum days since last access to be considered unused
- min_accesses: Maximum total accesses in period to be considered unused

**Returns**: UnusedIndexReport listing all indexes meeting the unused criteria

**Algorithm**:
1. Collect all index statistics for the analysis period
2. Filter indexes where total_accesses is less than min_accesses
3. For each candidate, calculate days since last access
4. Filter to indexes where days_since_last_access >= min_days_unused
5. For each unused index, calculate size and maintenance overhead
6. Classify drop safety based on constraint usage
7. Sum total potential savings in bytes and overhead percentage
8. Return complete UnusedIndexReport

**Safety Classification**:
- Safe: No accesses in period, not a required constraint
- Caution: Fewer than 10 accesses in period
- Risky: Rare usage but may be for critical periodic jobs
- Required: Primary key or unique constraint index

**Concurrency**: Read-only analysis, safe for concurrent calls

### compare_indexes(conn: &Connection, table_name: &str) -> Result<IndexComparisonReport>

**Purpose**: Analyze all indexes on a specific table to identify redundancy, overlap, and consolidation opportunities.

**Parameters**:
- conn: Active database connection
- table_name: Name of table to analyze

**Returns**: IndexComparisonReport with overlap and consolidation analysis

**Algorithm**:
1. Query all indexes defined on the specified table
2. For each pair of indexes, compare column sets:
   - Identify identical indexes (exact column match)
   - Identify prefix relationships (one is prefix of other)
   - Calculate column overlap percentage
3. Analyze usage patterns for overlapping indexes
4. Identify consolidation opportunities:
   - Combine frequently co-used indexes into composite
   - Replace low-usage single-column indexes with multi-column
5. Detect redundant indexes (one index is subset of another)
6. Assess risks and benefits of each consolidation
7. Return comprehensive IndexComparisonReport

**Concurrency**: Read-only analysis, safe for concurrent calls

### calculate_index_efficiency_score(stats: &IndexUsageStats) -> f64

**Purpose**: Compute a single numerical score (0.0 to 100.0) representing the overall efficiency and value of an index.

**Parameters**:
- stats: Index usage statistics to score

**Returns**: Efficiency score from 0.0 (inefficient) to 100.0 (highly efficient)

**Algorithm**:
1. Calculate usage component: normalize access frequency to 0-40 points
2. Calculate selectivity component: lower selectivity is better, 0-30 points
3. Calculate efficiency component: cache hit ratio and scan speed, 0-20 points
4. Calculate size component: smaller indexes are better, 0-10 points
5. Sum components for final score
6. Return score in range 0.0 to 100.0

**Scoring Formula**:
```
usage_score = min(40, (accesses_per_hour / 100) * 40)
selectivity_score = min(30, (1.0 - avg_selectivity) * 30)
efficiency_score = cache_hit_ratio * 15 + (1.0 / avg_rows_per_scan) * 5
size_score = max(0, 10 - (log(size_bytes) / log(2)) / 10)
total_score = usage_score + selectivity_score + efficiency_score + size_score
```

**Concurrency**: Pure function, safe for concurrent calls

### format_index_stats_text(stats: &IndexUsageStats) -> String

**Purpose**: Generate human-readable text report of index statistics for terminal output or log files.

**Parameters**:
- stats: Index usage statistics to format

**Returns**: Multi-line string with formatted statistics

**Algorithm**:
1. Start with header line showing index name and table
2. Display index type and columns
3. Format access statistics section with labels and values
4. Format efficiency metrics with appropriate precision
5. Format size and storage statistics
6. Format maintenance overhead statistics
7. Include calculated efficiency score
8. Return complete formatted string

**Output Format Example**:
```
Index: idx_users_email on Table: users
Type: B+tree, Columns: [email], Unique: Yes

Access Statistics:
  Total seeks: 15,432
  Total scans: 2,145
  Rows returned: 18,234
  Index-only scans: 1,234 (57%)
  Last accessed: 2026-01-04 10:23:45

Efficiency Metrics:
  Avg selectivity: 0.0001 (excellent)
  Avg rows per scan: 8.5
  Cache hit ratio: 94.2%
  Index depth: 3 levels

Size Statistics:
  Total pages: 1,234
  Total size: 9.8 MB
  Avg page fill: 78%
  Fragmentation: 12%

Maintenance Overhead:
  Inserts handled: 45,678
  Avg insert time: 45 μs
  Write amplification: 1.3x
  Maintenance overhead: 8.5%

Efficiency Score: 87.3 / 100
```

**Concurrency**: Pure function, safe for concurrent calls

### format_unused_report_text(report: &UnusedIndexReport) -> String

**Purpose**: Generate text summary of unused indexes with actionable recommendations.

**Parameters**:
- report: Unused index report to format

**Returns**: Multi-line string with formatted report

**Algorithm**:
1. Start with report header including time period
2. Display summary: total unused indexes, potential savings
3. For each unused index, show details:
   - Index name and table
   - Columns and size
   - Usage statistics (accesses, days since last use)
   - Safety classification and recommendation
4. Include summary statistics at end
5. Return formatted string

**Concurrency**: Pure function, safe for concurrent calls

## Invariants

- All counter values are monotonically increasing within a collection period
- Selectivity values are always between 0.0 and 1.0
- Percentage values are between 0.0 and 100.0
- Timestamps are in monotonically increasing order within a snapshot series
- Index names are unique within a table
- Every index has at least one indexed column

## Dependencies

- **Uses**: Schema metadata, Runtime statistics counters, Page allocation tables, Write-ahead log
- **Used by**: Database CLI, Monitoring systems, Automated index management tools, Performance analysis utilities

## Rust Implementation Guidance

### Module Structure

The Rust module should be organized as follows:

```
northstar-core/src/index_stats/
├── mod.rs              - Module exports and public API
├── types.rs            - IndexUsageStats, AccessStats, EfficiencyMetrics, etc.
├── collector.rs        - Statistics collection functions
├── analyzer.rs         - Trend analysis and comparison logic
├── reporter.rs         - Report generation (unused indexes, comparisons)
├── formatter.rs        - Text and JSON output formatting
└── error.rs            - Statistics-specific error types
```

### Type Definitions

- **IndexUsageStats**: Large struct with many fields, consider using builder pattern
- **IndexAccessStats**: Plain struct with counters, use Default trait for initialization
- **TrendDirection**: enum with variants for Increasing/Decreasing/Stable/Volatile
- **Choice**: Use Arc<str> instead of String for index names and column names (reused across structs)

### Concurrency

- **Pattern**: Stats collection reads from internal tables, use read transactions
- **Pattern**: Snapshot creation should be atomic, use consistent snapshot isolation
- **Pattern**: Analysis functions are pure and can run concurrently on shared data
- **Pattern**: Use RwLock for in-memory stats caches that are updated periodically

### Key Decisions

- **Statistics Storage**: Store raw counters in internal table, compute derived metrics on-demand
- **Snapshot Retention**: Keep snapshots for configurable period (default 90 days), archive older ones
- **Collection Frequency**: Update counters on every operation, aggregate periodically (every minute)
- **Trend Analysis**: Use linear regression for simple trends, consider more sophisticated models for complex patterns
- **Unused Thresholds**: Make thresholds configurable via database options

### Implementation Notes

1. **Step 1: Define core types** in types.rs
   - Start with IndexUsageStats and nested metric structs
   - Implement Default trait for all stats types
   - Add Debug and Display traits for debugging

2. **Step 2: Implement statistics collection** in collector.rs
   - Add instrumentation to index access operations in the index module
   - Increment counters on every index seek, scan, and modification
   - Flush counters to stats table periodically
   - Implement collect_index_stats and collect_all_index_stats

3. **Step 3: Build snapshot system**
   - Create internal table for snapshot storage
   - Implement take_snapshot to capture current state
   - Add snapshot retention policy to delete old snapshots
   - Query snapshots by time range

4. **Step 4: Implement trend analysis** in analyzer.rs
   - Extract time series from snapshots
   - Implement linear regression function
   - Classify trends based on slope and variance
   - Calculate confidence intervals
   - Generate actionable recommendations

5. **Step 5: Build unused index detection** in reporter.rs
   - Implement generate_unused_index_report
   - Query access statistics over time period
   - Classify drop safety based on constraint checks
   - Calculate potential savings accurately

6. **Step 6: Implement index comparison**
   - Build compare_indexes function
   - Detect identical, prefix, and overlapping column sets
   - Identify consolidation opportunities
   - Assess risks of index changes

7. **Step 7: Add text formatting** in formatter.rs
   - Implement format_index_stats_text with aligned columns
   - Implement format_unused_report_text with sections
   - Add JSON serialization using serde
   - Support multiple output formats

### Testing Strategy

**Unit tests needed for**:
- Statistics collection accuracy (counters increment correctly)
- Efficiency score calculation for various index patterns
- Trend classification accuracy with synthetic data
- Unused index detection with various usage patterns
- Index overlap detection for different column combinations
- Text formatting output verification

**Property tests for**:
- Efficiency score is always between 0.0 and 100.0
- Total accesses equals sum of seeks and scans
- Selectivity is between 0.0 and 1.0
- Trend direction classification is consistent
- Overlap detection is symmetric (overlap(A,B) == overlap(B,A))

**Integration scenarios**:
- Collect real statistics from index operations
- Compare snapshots before and after index changes
- Validate unused index report against actual query logs
- Test consolidation recommendations with realistic workloads

### Performance Considerations

- Statistics collection should add minimal overhead (<1%) to index operations
- Counter updates should be lock-free or use low-contention locks
- Snapshot creation should not block normal operations
- Trend analysis scales linearly with number of snapshots
- Large indexes may take longer to collect, consider sampling

### Error Handling

- StatsCollectionError for failures in gathering statistics
- SnapshotError for snapshot storage failures
- AnalysisError for trend analysis computation errors
- ReportGenerationError for report creation failures
- Use thiserror crate for clean error definitions
- All errors implement std::error::Error

### Configuration Options

- stats_collection_enabled: bool - Enable/disable statistics collection
- stats_retention_days: u32 - How long to keep raw statistics
- snapshot_interval_secs: u64 - How often to create snapshots
- unused_index_min_days: u64 - Minimum days to consider index unused
- unused_index_min_accesses: u64 - Maximum accesses to still be considered unused
- trend_analysis_min_snapshots: u32 - Minimum snapshots required for trend analysis
