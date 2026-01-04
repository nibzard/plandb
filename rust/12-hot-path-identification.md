# Hot Path Identification

## Purpose

Hot Path Identification analyzes query execution patterns to discover frequently accessed data, commonly executed operations, and performance-critical code paths within the database. This module enables the database to automatically identify bottlenecks, optimize access patterns, and guide performance tuning efforts. By tracking execution frequency, resource consumption, and access patterns, the system can pinpoint hot spots that benefit most from optimization efforts such as caching, indexing, or algorithm improvements.

## Types

### HotPathReport

**Description**: Comprehensive report analyzing hot paths across the entire database or a specific schema. Identifies the most frequently accessed and resource-intensive operations.

**Fields**:
- report_id: u64 - Unique identifier for this report
- generated_at: Timestamp - When the report was generated
- analysis_period_start: Timestamp - Start of data collection period
- analysis_period_end: Timestamp - End of data collection period
- hot_queries: Vec<HotQuery> - Most frequently executed queries
- hot_tables: Vec<HotTable> - Most accessed tables
- hot_indexes: Vec<HotIndex> - Most utilized indexes
- hot_pages: Vec<HotPage> - Most frequently accessed disk pages
- hot_procedures: Vec<HotProcedure> - Most called stored procedures
- bottlenecks: Vec<Bottleneck> - Identified performance bottlenecks
- optimization_opportunities: Vec<OptimizationOpportunity> - Suggested optimizations

**Invariants**:
- analysis_period_end is after analysis_period_start
- All result vectors are sorted by impact (highest first)
- Total analysis period is reasonable (at least 1 minute, at most 90 days)

### HotQuery

**Description**: Represents a query pattern that is executed frequently or consumes significant resources.

**Fields**:
- query_pattern: String - Normalized query text (parameters removed)
- query_hash: u64 - Hash of normalized query for grouping
- execution_count: u64 - Number of times this query was executed
- total_execution_time_ms: f64 - Cumulative execution time
- avg_execution_time_ms: f64 - Average execution time per execution
- min_execution_time_ms: f64 - Fastest execution
- max_execution_time_ms: f64 - Slowest execution
- p50_execution_time_ms: f64 - Median execution time
- p95_execution_time_ms: f64 - 95th percentile execution time
- p99_execution_time_ms: f64 - 99th percentile execution time
- rows_returned_total: u64 - Total rows returned across all executions
- rows_returned_avg: f64 - Average rows returned per execution
- rows_read_total: u64 - Total rows scanned across all executions
- blocks_read_total: u64 - Total disk blocks read
- cache_hit_ratio: f64 - Fraction of blocks served from cache
- first_seen: Timestamp - First time this query was observed
- last_seen: Timestamp - Most recent execution
- sample_query_text: String - Example of actual query with parameters
- impact_score: f64 - Combined measure of frequency and cost (0.0 to 100.0)

**Invariants**:
- execution_count is positive
- avg_execution_time_ms equals total_execution_time_ms divided by execution_count
- min_execution_time_ms is less than or equal to avg_execution_time_ms
- max_execution_time_ms is greater than or equal to avg_execution_time_ms
- p50 <= p95 <= p99 execution times
- cache_hit_ratio is between 0.0 and 1.0
- last_seen is after first_seen

### HotTable

**Description**: Identifies tables that experience high access frequency or large I/O volumes.

**Fields**:
- table_name: String - Name of the table
- schema_name: String - Schema containing the table
- access_count: u64 - Number of times table was accessed (any operation)
- read_count: u64 - Number of read operations
- write_count: u64 - Number of write operations (insert, update, delete)
- rows_read_total: u64 - Total rows read from table
- rows_written_total: u64 - Total rows written to table
- blocks_read_total: u64 - Total disk blocks read
- blocks_written_total: u64 - Total disk blocks written
- sequential_read_ratio: f64 - Fraction of reads that were sequential
- avg_rows_per_access: f64 - Average rows touched per access
- table_size_bytes: u64 - Current table size on disk
- cache_hit_ratio: f64 - Fraction of table blocks served from cache
- table_scan_count: u64 - Number of full table scans
- index_scan_count: u64 - Number of index-based accesses
- impact_score: f64 - Combined measure of frequency and cost (0.0 to 100.0)

**Invariants**:
- access_count equals read_count plus write_count
- sequential_read_ratio is between 0.0 and 1.0
- cache_hit_ratio is between 0.0 and 1.0

### HotIndex

**Description**: Identifies indexes that experience heavy usage or provide significant performance benefits.

**Fields**:
- index_name: String - Name of the index
- table_name: String - Table containing the index
- index_type: IndexType - Type of index (B+tree, hash, etc.)
- indexed_columns: Vec<String> - Columns in the index key
- seek_count: u64 - Number of point lookup operations
- scan_count: u64 - Number of range scan operations
- rows_returned_total: u64 - Total rows retrieved via index
- index_pages_read: u64 - Total index pages read
- index_only_scans: u64 - Count of scans that didn't require table access
- avg_seeks_per_scan: f64 - Average index depth traversed per operation
- selectivity_avg: f64 - Average selectivity (fraction of rows returned)
- cache_hit_ratio: f64 - Fraction of index pages from cache
- index_size_bytes: u64 - Current index size on disk
- maintenance_operations: u64 - Number of index updates due to table modifications
- impact_score: f64 - Combined measure of frequency and benefit (0.0 to 100.0)

**Invariants**:
- All counter values are non-negative
- selectivity_avg is between 0.0 and 1.0
- cache_hit_ratio is between 0.0 and 1.0

### HotPage

**Description**: Identifies specific database pages that are accessed extremely frequently, indicating potential for pinning in cache or optimizing access patterns.

**Fields**:
- page_id: PageId - Unique page identifier
- page_type: PageType - Type of page (data, index, metadata, etc.)
- table_name: String - Table containing the page
- access_count: u64 - Number of times page was accessed
- access_frequency_per_min: f64 - Average accesses per minute
- last_access_time: Timestamp - Most recent access
- first_access_time: Timestamp - Oldest access in period
- is_currently_cached: bool - Whether page is currently in memory cache
- cache_evictions: u64 - Number of times page was evicted from cache
- avg_cache_residence_time_ms: f64 - Average time page stays in cache when loaded
- read_contention: f64 - Measure of concurrent access attempts
- impact_score: f64 - Combined measure of frequency and criticality (0.0 to 100.0)

**Invariants**:
- access_count is positive
- access_frequency_per_min is non-negative
- last_access_time is after first_access_time

### PageType

**Description**: Type of database page.

**Variants**:
- DataPage - Table data page
- IndexLeafPage - Index leaf level page
- InternalPage - Index internal routing page
- MetadataPage - Database metadata page
- OverflowPage - Overflow page for large values
- FreePage - Currently unused page

### HotProcedure

**Description**: Identifies stored procedures or functions that are called frequently or consume significant resources.

**Fields**:
- procedure_name: String - Name of the procedure
- schema_name: String - Schema containing the procedure
- invocation_count: u64 - Number of times procedure was called
- total_execution_time_ms: f64 - Cumulative execution time
- avg_execution_time_ms: f64 - Average execution time per call
- min_execution_time_ms: f64 - Fastest execution
- max_execution_time_ms: f64 - Slowest execution
- rows_affected_total: u64 - Total rows affected by procedure
- errors_count: u64 - Number of times procedure raised an error
- avg_memory_bytes: f64 - Average memory consumption per execution
- impact_score: f64 - Combined measure of frequency and cost (0.0 to 100.0)

**Invariants**:
- invocation_count is positive
- avg_execution_time_ms equals total_execution_time_ms divided by invocation_count
- min_execution_time_ms is less than or equal to avg_execution_time_ms

### Bottleneck

**Description**: Identifies a specific performance bottleneck limiting overall system throughput.

**Fields**:
- bottleneck_id: u64 - Unique identifier for this bottleneck
- bottleneck_type: BottleneckType - Category of bottleneck
- severity: Severity - Impact level (Low, Medium, High, Critical)
- description: String - Human-readable description of the bottleneck
- affected_component: String - Database component experiencing the bottleneck
- current_value: f64 - Current measurement value
- threshold_value: f64 - Threshold at which this is considered a bottleneck
- excess_pct: f64 - Percentage by which current exceeds threshold
- estimated_impact_ms: f64 - Estimated performance impact in milliseconds
- affected_queries: Vec<String> - Query patterns affected by this bottleneck
- suggested_remediation: String - Suggested action to resolve bottleneck
- can_auto_remediate: bool - Whether system can automatically fix this

### BottleneckType

**Description**: Category of performance bottleneck.

**Variants**:
- CpuSaturation - CPU usage at capacity
- IoSaturation - Disk I/O at capacity
- MemoryPressure - Insufficient memory causing cache pressure
- LockContention - High lock wait times
- NetworkLatency - Network delays in distributed setup
- CacheMissRatio - High cache miss rate causing I/O
- WriteLogFlush - Write-ahead log flush delays
- TableScan - Excessive full table scans
- NPlusOne - N+1 query pattern inefficiency
- MissingIndex - Missing index causing table scans
- FragmentedIndex - Index fragmentation causing poor performance
- SkewedData - Data skew causing uneven workload distribution

### Severity

**Description**: Severity level of a bottleneck.

**Variants**:
- Low - Minor impact, optimization opportunity
- Medium - Noticeable impact, should address
- High - Significant impact, address soon
- Critical - Severe impact, address immediately

### OptimizationOpportunity

**Description**: Suggests a specific optimization that could improve performance based on hot path analysis.

**Fields**:
- opportunity_id: u64 - Unique identifier
- opportunity_type: OptimizationType - Category of optimization
- title: String - Brief title of the optimization
- description: String - Detailed description of the optimization
- current_state: String - Description of current behavior
- proposed_state: String - Description of optimized behavior
- estimated_benefit_pct: f64 - Expected performance improvement (percentage)
- effort_level: EffortLevel - Implementation effort required
- risk_level: RiskLevel - Risk associated with implementing this optimization
- affected_objects: Vec<String> - Tables, indexes, or queries affected
- implementation_steps: Vec<String> - Steps to implement the optimization
- rollback_plan: String - How to undo the optimization if needed

### OptimizationType

**Description**: Category of optimization opportunity.

**Variants**:
- CreateIndex - Add a new index to speed up queries
- DropUnusedIndex - Remove an unused index to reduce overhead
- RebuildIndex - Rebuild a fragmented index
- AddCacheHint - Add caching hint for frequently accessed data
- RewriteQuery - Suggest query rewrite for better performance
- PartitionTable - Partition a large table
- UpdateStatistics - Update table statistics for better optimizer plans
- PinPage - Pin a hot page in cache
- IncreaseCache - Increase cache size
- TuneLocks - Adjust lock configuration
- CreateMaterializedView - Create a materialized view for expensive queries

### EffortLevel

**Description**: Effort required to implement an optimization.

**Variants**:
- Trivial - Can be done in minutes with no downtime
- Low - Can be done in hours with minimal testing
- Medium - Requires significant testing and planning
- High - Major change requiring extensive testing
- Complex - Architectural change, requires careful design

### RiskLevel

**Description**: Risk associated with an optimization.

**Variants**:
- Minimal - Very low risk, easily reversible
- Low - Low risk, well-understood change
- Medium - Moderate risk, requires testing
- High - High risk, may have unintended consequences
- VeryHigh - Significant risk, requires thorough validation

### AccessPattern

**Description**: Represents a pattern of data access observed across multiple queries.

**Fields**:
- pattern_id: u64 - Unique identifier
- pattern_type: AccessPatternType - Category of access pattern
- tables_involved: Vec<String> - Tables accessed in this pattern
- columns_involved: Vec<String> - Columns frequently accessed together
- join_keys: Vec<String> - Columns commonly used for joins
- filter_columns: Vec<String> - Columns frequently used in filters
- sort_columns: Vec<String> - Columns frequently used for ordering
- query_count: u64 - Number of queries exhibiting this pattern
- frequency_per_hour: f64 - How often this pattern occurs
- avg_latency_ms: f64 - Average latency of queries with this pattern

### AccessPatternType

**Description**: Type of access pattern.

**Variants**:
- SequentialAccess - Accessing rows in sequential order
- RandomAccess - Random access patterns
- RangeScan - Scanning ranges of data
- PointLookup - Individual row lookups
- NPlusOne - N+1 query anti-pattern
- FullScan - Full table or index scans
- JoinHeavy - Queries with many joins
- AggregationHeavy - Queries with complex aggregations

## Functions

### generate_hot_path_report(conn: &Connection, period_start: Timestamp, period_end: Timestamp) -> Result<HotPathReport>

**Purpose**: Generate comprehensive hot path analysis for a specific time period.

**Parameters**:
- conn: Active database connection
- period_start: Start of analysis period
- period_end: End of analysis period

**Returns**: Complete HotPathReport with all hot paths and optimization opportunities

**Algorithm**:
1. Validate time period is reasonable duration and range
2. Query query execution log for all queries in period
3. Normalize queries and group by query_hash
4. Calculate statistics for each query pattern (frequency, latency, resource usage)
5. Query table access statistics from system tables
6. Query index usage statistics from index stats module
7. Query page access patterns from cache manager
8. Query stored procedure invocation statistics
9. Identify bottlenecks by comparing metrics against thresholds
10. Generate optimization opportunities based on patterns
11. Calculate impact scores for all identified items
12. Sort all result vectors by impact score (descending)
13. Return complete HotPathReport

**Error Conditions**:
- InvalidPeriodError: Time period is invalid or too large
- StatsNotAvailableError: Required statistics not collected for period
- QueryError: Internal query to statistics tables failed

**Concurrency**: Reads statistics tables, safe for concurrent calls

### identify_hot_queries(conn: &Connection, limit: usize) -> Result<Vec<HotQuery>>

**Purpose**: Identify the top N hottest queries by combined frequency and resource consumption.

**Parameters**:
- conn: Active database connection
- limit: Maximum number of hot queries to return

**Returns**: Vector of HotQuery sorted by impact score (descending)

**Algorithm**:
1. Query query execution log for all executed queries
2. Normalize each query by removing literal parameters
3. Compute hash of normalized query for grouping
4. Group executions by query_hash
5. For each group, calculate:
   - Execution count
   - Total, average, min, max, p50, p95, p99 execution times
   - Total and average rows returned and read
   - Total blocks read and cache hit ratio
6. Calculate impact score: (frequency_score * 0.6) + (cost_score * 0.4)
   - frequency_score = min(100, log10(execution_count) * 20)
   - cost_score = min(100, log10(total_time) * 20)
7. Sort by impact score descending
8. Return top N results

**Concurrency**: Read-only analysis, safe for concurrent calls

### identify_hot_tables(conn: &Connection, limit: usize) -> Result<Vec<HotTable>>

**Purpose**: Identify the most frequently accessed tables.

**Parameters**:
- conn: Active database connection
- limit: Maximum number of hot tables to return

**Returns**: Vector of HotTable sorted by impact score

**Algorithm**:
1. Query table access statistics from system tables
2. For each table, calculate:
   - Total access count (reads + writes)
   - Rows read and written
   - Blocks read and written
   - Sequential vs random read ratio
   - Cache hit ratio
3. Calculate impact score:
   - Access frequency component (40%)
   - I/O volume component (30%)
   - Cache inefficiency component (20%)
   - Table scan component (10%)
4. Sort by impact score descending
5. Return top N results

**Concurrency**: Read-only analysis, safe for concurrent calls

### identify_hot_indexes(conn: &Connection, limit: usize) -> Result<Vec<HotIndex>>

**Purpose**: Identify the most heavily utilized indexes.

**Parameters**:
- conn: Active database connection
- limit: Maximum number of hot indexes to return

**Returns**: Vector of HotIndex sorted by impact score

**Algorithm**:
1. Query index usage statistics from index stats module
2. For each index, calculate:
   - Seek and scan counts
   - Total rows returned
   - Index pages read
   - Cache hit ratio
   - Average selectivity
3. Calculate impact score:
   - Usage frequency component (40%)
   - Efficiency component (30%)
   - Selectivity component (20%)
   - Cache effectiveness component (10%)
4. Sort by impact score descending
5. Return top N results

**Concurrency**: Read-only analysis, safe for concurrent calls

### identify_hot_pages(conn: &Connection, limit: usize) -> Result<Vec<HotPage>>

**Purpose**: Identify specific pages accessed extremely frequently, candidates for cache pinning.

**Parameters**:
- conn: Active database connection
- limit: Maximum number of hot pages to return

**Returns**: Vector of HotPage sorted by impact score

**Algorithm**:
1. Query page access statistics from cache manager
2. For each page, calculate:
   - Access count and frequency
   - Cache eviction count
   - Average cache residence time
   - Read contention level
3. Calculate impact score:
   - Access frequency component (50%)
   - Cache eviction component (30%) - high evictions indicate it should be pinned
   - Contention component (20%)
4. Sort by impact score descending
5. Return top N results

**Concurrency**: Read-only analysis, safe for concurrent calls

### detect_bottlenecks(conn: &Connection) -> Result<Vec<Bottleneck>>

**Purpose**: Automatically detect performance bottlenecks by comparing current metrics against thresholds.

**Parameters**:
- conn: Active database connection

**Returns**: Vector of detected Bottleneck sorted by severity

**Algorithm**:
1. Query current system metrics:
   - CPU utilization percentage
   - Disk I/O queue depth and latency
   - Memory usage and cache hit ratio
   - Lock wait times
   - Write log flush times
2. Compare each metric against configured threshold
3. If metric exceeds threshold, create bottleneck entry
4. Calculate severity based on how much threshold is exceeded
5. For query-specific bottlenecks (table scans, missing indexes):
   - Analyze query execution plans
   - Identify expensive operations
   - Check for appropriate indexes
6. Generate remediation suggestions for each bottleneck
7. Sort by severity (Critical, High, Medium, Low)
8. Return detected bottlenecks

**Bottleneck Thresholds** (configurable):
- CPU utilization: 85%
- Disk I/O latency: 20ms
- Cache hit ratio: below 80%
- Lock wait time: 100ms
- Write log flush time: 50ms

**Concurrency**: Read-only analysis, safe for concurrent calls

### suggest_optimizations(report: &HotPathReport) -> Vec<OptimizationOpportunity>

**Purpose**: Generate optimization suggestions based on hot path analysis.

**Parameters**:
- report: Hot path report containing identified hot spots

**Returns**: Vector of OptimizationOpportunity with actionable suggestions

**Algorithm**:
1. Analyze hot queries for missing index opportunities:
   - Identify queries with table scans on filtered columns
   - Check if indexes exist on filter columns
   - Suggest creating indexes if missing
2. Analyze hot indexes for consolidation:
   - Identify overlapping indexes on same tables
   - Suggest composite indexes to reduce maintenance
3. Analyze hot pages for cache optimization:
   - Suggest pinning frequently accessed pages
   - Suggest increasing cache size if high eviction rate
4. Analyze query patterns for rewrite opportunities:
   - Detect N+1 query patterns
   - Detect redundant subqueries
   - Suggest query rewrites
5. Analyze table access for partitioning:
   - Identify large tables with skewed access
   - Suggest partitioning strategies
6. For each opportunity, estimate:
   - Expected benefit percentage
   - Implementation effort
   - Risk level
7. Sort by expected benefit descending
8. Return optimization suggestions

**Concurrency**: Pure function, safe for concurrent calls

### normalize_query(query: &str) -> String

**Purpose**: Convert a query with literal values into a parameterized pattern for grouping similar queries.

**Parameters**:
- query: Original SQL query text

**Returns**: Normalized query with literals replaced by placeholders

**Algorithm**:
1. Parse the query into an abstract syntax tree
2. Traverse the AST and identify literal values:
   - String literals
   - Numeric literals
   - Date/time literals
   - Boolean literals
3. Replace each literal with a placeholder (e.g., $1, $2, $3)
4. Preserve all other query structure (table names, column names, operators)
5. Return normalized query string

**Example**:
- Input: "SELECT * FROM users WHERE age > 25 AND name = 'Alice'"
- Output: "SELECT * FROM users WHERE age > $1 AND name = $2"

**Concurrency**: Pure function, safe for concurrent calls

### calculate_impact_score(frequency: u64, cost: f64) -> f64

**Purpose**: Compute an impact score combining frequency of operation and its resource cost.

**Parameters**:
- frequency: Number of times the operation occurred
- cost: Total resource consumption (e.g., time in milliseconds)

**Returns**: Impact score from 0.0 to 100.0

**Algorithm**:
1. Calculate frequency score using logarithmic scale:
   - frequency_score = min(100, log10(frequency + 1) * 20)
2. Calculate cost score using logarithmic scale:
   - cost_score = min(100, log10(cost + 1) * 20)
3. Combine with weighted average:
   - impact = (frequency_score * 0.6) + (cost_score * 0.4)
4. Return impact score

**Concurrency**: Pure function, safe for concurrent calls

### identify_access_patterns(conn: &Connection) -> Result<Vec<AccessPattern>>

**Purpose**: Identify common access patterns across queries to guide optimization strategies.

**Parameters**:
- conn: Active database connection

**Returns**: Vector of identified AccessPattern

**Algorithm**:
1. Query normalized query execution history
2. For each query, extract:
   - Tables accessed
   - Columns referenced (in SELECT, WHERE, JOIN, ORDER BY)
   - Join columns
   - Filter columns
   - Sort columns
3. Group queries by similar access patterns using clustering
4. For each pattern cluster, calculate:
   - Tables commonly accessed together
   - Columns commonly accessed together
   - Frequency of pattern occurrence
   - Average latency
5. Classify pattern type (Sequential, Random, RangeScan, etc.)
6. Return identified patterns

**Concurrency**: Read-only analysis, safe for concurrent calls

### format_hot_path_report_text(report: &HotPathReport) -> String

**Purpose**: Generate human-readable text report of hot path analysis.

**Parameters**:
- report: Hot path report to format

**Returns**: Multi-line string with formatted report

**Algorithm**:
1. Create report header with analysis period and generation time
2. For each section (queries, tables, indexes, pages, procedures):
   - Print section header
   - For each item in section (top 10):
     - Print name and impact score
     - Print key metrics (frequency, latency, resource usage)
     - Print optimization hint if applicable
3. Print bottlenecks section sorted by severity
4. Print optimization opportunities section
5. Print summary statistics
6. Return formatted string

**Output Format Example**:
```
HOT PATH ANALYSIS REPORT
Period: 2026-01-01 to 2026-01-04
Generated: 2026-01-04 15:30:00

TOP HOT QUERIES
1. SELECT * FROM users WHERE email = $1 (Impact: 95.3)
   Executions: 45,231 | Avg time: 2.3ms | Rows: 1
   Optimization: Consider adding index on email if not exists

2. SELECT * FROM orders WHERE user_id = $1 (Impact: 87.2)
   Executions: 38,456 | Avg time: 15.8ms | Rows: 12
   Optimization: Index on user_id exists, consider covering index

TOP HOT TABLES
1. Table: users (Impact: 92.1)
   Accesses: 125,432 | Reads: 118,234 | Writes: 7,198
   Cache hit ratio: 94.5%

BOTTLENECKS
[CRITICAL] Cache Miss Ratio: Current 62%, Threshold 80%
   Impact: Queries are 40% slower due to cache misses
   Remediation: Increase cache size or improve access patterns

OPTIMIZATION OPPORTUNITIES
1. Create index on orders(status, created_at)
   Benefit: 35% improvement on order status queries
   Effort: Low | Risk: Low
```

**Concurrency**: Pure function, safe for concurrent calls

## Invariants

- All counter values are non-negative
- Impact scores are between 0.0 and 100.0
- Percentages are between 0.0 and 100.0
- Timestamps in reports are monotonically increasing
- All result vectors are sorted by impact score descending
- HotQuery avg times equal total divided by count
- Bottleneck severity levels are consistent with excess_pct

## Dependencies

- **Uses**: Query execution log, Index usage statistics, Cache manager statistics, Schema metadata, System metrics collector
- **Used by**: Database CLI, Monitoring dashboards, Automated optimization systems, Performance analysis tools

## Rust Implementation Guidance

### Module Structure

The Rust module should be organized as follows:

```
northstar-core/src/hot_path/
├── mod.rs              - Module exports and public API
├── types.rs            - HotPathReport, HotQuery, HotTable, etc.
├── analyzer.rs         - Hot path identification logic
├── detector.rs         - Bottleneck detection
├── suggester.rs        - Optimization suggestion generation
├── normalizer.rs       - Query normalization
├── reporter.rs         - Report generation and formatting
└── error.rs            - Hot path-specific error types
```

### Type Definitions

- **HotPathReport**: Large struct with multiple vectors, consider builder pattern
- **HotQuery**: Use struct with many numeric fields, Default trait for initialization
- **BottleneckType**: enum with variants for different bottleneck categories
- **Choice**: Use Arc<str> instead of String for query patterns and identifiers (reused across queries)

### Concurrency

- **Pattern**: Report generation reads from statistics tables, use read transactions
- **Pattern**: Query normalization is pure, safe for concurrent execution
- **Pattern**: Impact score calculation is pure function, no locks needed
- **Pattern**: Use RwLock for in-memory hot path cache that updates periodically

### Key Decisions

- **Query Normalization**: Parse queries using SQL parser library, replace literals with placeholders
- **Impact Score Formula**: Weighted combination of frequency and cost, configurable weights
- **Bottleneck Thresholds**: Make thresholds configurable via database options
- **Report Retention**: Keep reports for configurable period (default 30 days)
- **Analysis Frequency**: Update hot path data periodically (default every 5 minutes)

### Implementation Notes

1. **Step 1: Define core types** in types.rs
   - Start with HotPathReport and nested types (HotQuery, HotTable, HotIndex, HotPage)
   - Implement Default trait for all types
   - Add Debug and Display traits for debugging

2. **Step 2: Implement query normalization** in normalizer.rs
   - Integrate SQL parser library (e.g., sqlparser-rs)
   - Parse query to AST
   - Traverse AST and replace literals with placeholders
   - Implement normalize_query function
   - Add tests for various query types

3. **Step 3: Build hot query identification** in analyzer.rs
   - Query execution log for query history
   - Normalize and group queries by hash
   - Calculate statistics for each group (percentiles, averages)
   - Implement identify_hot_queries

4. **Step 4: Implement hot table/index/page identification**
   - Query respective statistics tables
   - Calculate impact scores
   - Implement identify_hot_tables, identify_hot_indexes, identify_hot_pages

5. **Step 5: Build bottleneck detection** in detector.rs
   - Query current system metrics
   - Compare against thresholds
   - Classify severity levels
   - Generate remediation suggestions
   - Implement detect_bottlenecks

6. **Step 6: Implement optimization suggestion** in suggester.rs
   - Analyze hot paths for optimization opportunities
   - Check for missing indexes
   - Identify consolidation opportunities
   - Implement suggest_optimizations

7. **Step 7: Add report generation** in reporter.rs
   - Implement generate_hot_path_report orchestrating all analysis
   - Implement format_hot_path_report_text
   - Add JSON serialization using serde
   - Support multiple output formats

### Testing Strategy

**Unit tests needed for**:
- Query normalization for various SQL patterns
- Impact score calculation with various frequency/cost combinations
- Bottleneck detection with synthetic metrics
- Hot query identification with synthetic execution logs
- Optimization suggestion generation logic
- Text formatting output verification

**Property tests for**:
- Impact score is always between 0.0 and 100.0
- Normalized queries contain no literal values
- Bottleneck severity matches threshold excess
- Hot queries are sorted by impact score descending
- Report contains all required sections

**Integration scenarios**:
- Generate real hot path reports from query execution logs
- Validate bottleneck detection against known performance issues
- Test optimization suggestions with realistic workloads
- Compare reports before and after optimizations

### Performance Considerations

- Query normalization should be fast (<1ms per query)
- Hot path analysis scales linearly with number of unique queries
- Report generation for large datasets (>1M queries) may take time
- Consider sampling for very large analysis periods
- Cache normalized queries to avoid re-parsing
- Periodic aggregation reduces analysis cost

### Error Handling

- HotPathAnalysisError for failures in hot path identification
- QueryNormalizationError for SQL parsing failures
- StatsNotAvailableError when required statistics not collected
- ReportGenerationError for report creation failures
- Use thiserror crate for clean error definitions
- All errors implement std::error::Error

### Configuration Options

- hot_path_analysis_enabled: bool - Enable/disable hot path tracking
- analysis_interval_secs: u64 - How often to update hot path data
- report_retention_days: u32 - How long to keep generated reports
- bottleneck_cpu_threshold_pct: f64 - CPU utilization threshold for bottleneck
- bottleneck_io_latency_threshold_ms: f64 - I/O latency threshold
- bottleneck_cache_hit_threshold_pct: f64 - Cache hit ratio threshold
- hot_query_min_executions: u64 - Minimum executions to be considered hot
- impact_frequency_weight: f64 - Weight for frequency in impact score (default 0.6)
- impact_cost_weight: f64 - Weight for cost in impact score (default 0.4)
