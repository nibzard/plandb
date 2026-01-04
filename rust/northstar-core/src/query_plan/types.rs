//! Query Plan Visualization Types
//!
//! This module defines the core types for representing and visualizing
//! query execution plans in NorthstarDB.

use serde::{Deserialize, Serialize};
use std::fmt;

/// Unique identifier for a query plan node
pub type NodeId = u64;

/// Unique identifier for a query
pub type QueryId = u64;

/// Cost value from the query optimizer
pub type Cost = f64;

/// Operation type within a query execution plan
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PlanNodeType {
    /// Sequential scan of all rows in a table
    TableScan,
    /// Ordered scan using an index with optional range bounds
    IndexScan,
    /// Direct lookup by index key (single row or few rows)
    IndexSeek,
    /// Application of predicate conditions to filter rows
    Filter,
    /// Join using nested loop algorithm
    NestedLoopJoin,
    /// Join using hash-based aggregation
    HashJoin,
    /// Join using sorted merge algorithm
    MergeJoin,
    /// Grouping and aggregation operations
    Aggregate,
    /// Explicit sorting operation
    Sort,
    /// Restriction of result set size
    Limit,
    /// Selection and transformation of columns
    Projection,
    /// Combination of result sets
    Union,
    /// Intersection of result sets
    Intersect,
    /// Set difference operation
    Except,
}

impl fmt::Display for PlanNodeType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlanNodeType::TableScan => write!(f, "TableScan"),
            PlanNodeType::IndexScan => write!(f, "IndexScan"),
            PlanNodeType::IndexSeek => write!(f, "IndexSeek"),
            PlanNodeType::Filter => write!(f, "Filter"),
            PlanNodeType::NestedLoopJoin => write!(f, "NestedLoopJoin"),
            PlanNodeType::HashJoin => write!(f, "HashJoin"),
            PlanNodeType::MergeJoin => write!(f, "MergeJoin"),
            PlanNodeType::Aggregate => write!(f, "Aggregate"),
            PlanNodeType::Sort => write!(f, "Sort"),
            PlanNodeType::Limit => write!(f, "Limit"),
            PlanNodeType::Projection => write!(f, "Projection"),
            PlanNodeType::Union => write!(f, "Union"),
            PlanNodeType::Intersect => write!(f, "Intersect"),
            PlanNodeType::Except => write!(f, "Except"),
        }
    }
}

/// Type of comparison or logical operation in a predicate
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PredicateOperator {
    /// Exact equality match (=)
    Equal,
    /// Inequality match (!=)
    NotEqual,
    /// Strict less than (<)
    LessThan,
    /// Less than or equal (<=)
    LessThanOrEqual,
    /// Strict greater than (>)
    GreaterThan,
    /// Greater than or equal (>=)
    GreaterThanOrEqual,
    /// Pattern matching with wildcards
    Like,
    /// Membership test in a set
    In,
    /// Test for null values
    IsNull,
    /// Range test (inclusive lower and upper bounds)
    Between,
    /// Logical conjunction of two predicates
    And,
    /// Logical disjunction of two predicates
    Or,
    /// Logical negation of a predicate
    Not,
}

impl fmt::Display for PredicateOperator {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PredicateOperator::Equal => write!(f, "="),
            PredicateOperator::NotEqual => write!(f, "!="),
            PredicateOperator::LessThan => write!(f, "<"),
            PredicateOperator::LessThanOrEqual => write!(f, "<="),
            PredicateOperator::GreaterThan => write!(f, ">"),
            PredicateOperator::GreaterThanOrEqual => write!(f, ">="),
            PredicateOperator::Like => write!(f, "LIKE"),
            PredicateOperator::In => write!(f, "IN"),
            PredicateOperator::IsNull => write!(f, "IS NULL"),
            PredicateOperator::Between => write!(f, "BETWEEN"),
            PredicateOperator::And => write!(f, "AND"),
            PredicateOperator::Or => write!(f, "OR"),
            PredicateOperator::Not => write!(f, "NOT"),
        }
    }
}

/// Constant value in a predicate expression
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum LiteralValue {
    /// Null value
    Null,
    /// Boolean value
    Boolean(bool),
    /// 64-bit integer
    Integer(i64),
    /// Floating point value
    Float(f64),
    /// String value
    String(String),
}

/// Filter condition or predicate applied to data
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Predicate {
    /// Name of the column being filtered
    pub column_name: String,
    /// Comparison or logical operator
    pub operator: PredicateOperator,
    /// Constant value being compared against
    pub value: LiteralValue,
    /// Whether predicate can use an index (search argument able)
    pub is_sargable: bool,
}

impl Predicate {
    /// Create a new predicate
    pub fn new(column_name: String, operator: PredicateOperator, value: LiteralValue, is_sargable: bool) -> Self {
        Self {
            column_name,
            operator,
            value,
            is_sargable,
        }
    }
}

/// Type of table storage
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TableType {
    /// Heap-organized table (unordered)
    Heap,
    /// B+tree organized table (ordered by primary key)
    BTree,
    /// Column-oriented storage
    Columnar,
}

impl fmt::Display for TableType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TableType::Heap => write!(f, "heap"),
            TableType::BTree => write!(f, "btree"),
            TableType::Columnar => write!(f, "columnar"),
        }
    }
}

/// Metadata about table access operations
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TableInfo {
    /// Name of the table being accessed
    pub table_name: String,
    /// Type of table
    pub table_type: TableType,
    /// Optimizer's estimate of rows to be read
    pub estimated_rows: u64,
    /// Actual rows read during execution
    pub actual_rows: u64,
    /// Whether access is sequential or random
    pub is_sequential: bool,
}

impl TableInfo {
    /// Create new table info
    pub fn new(table_name: String, table_type: TableType, estimated_rows: u64) -> Self {
        Self {
            table_name,
            table_type,
            estimated_rows,
            actual_rows: 0,
            is_sequential: false,
        }
    }

    /// Set actual rows read
    pub fn with_actual_rows(mut self, rows: u64) -> Self {
        self.actual_rows = rows;
        self
    }

    /// Mark as sequential access
    pub fn with_sequential(mut self, sequential: bool) -> Self {
        self.is_sequential = sequential;
        self
    }
}

/// Type of index
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum IndexType {
    /// B+tree index (ordered)
    BTree,
    /// Hash index (equality only)
    Hash,
    /// Full-text search index
    FullText,
    /// GiST (generalized search tree)
    GiST,
}

impl fmt::Display for IndexType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IndexType::BTree => write!(f, "btree"),
            IndexType::Hash => write!(f, "hash"),
            IndexType::FullText => write!(f, "fulltext"),
            IndexType::GiST => write!(f, "gist"),
        }
    }
}

/// Describes how an index is accessed during query execution
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum IndexSeekType {
    /// Direct lookup by exact key (most efficient)
    PointLookup,
    /// Scan over a range of keys
    RangeScan,
    /// Scan using key prefix (partial key match)
    PrefixScan,
    /// Scan entire index (least efficient)
    FullScan,
    /// Multiple point lookups combined
    MultiSeek,
}

impl fmt::Display for IndexSeekType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IndexSeekType::PointLookup => write!(f, "point"),
            IndexSeekType::RangeScan => write!(f, "range"),
            IndexSeekType::PrefixScan => write!(f, "prefix"),
            IndexSeekType::FullScan => write!(f, "full"),
            IndexSeekType::MultiSeek => write!(f, "multi"),
        }
    }
}

/// Metadata about index usage during query execution
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexInfo {
    /// Name of the index being used
    pub index_name: String,
    /// Type of index
    pub index_type: IndexType,
    /// Columns comprising the index key
    pub index_columns: Vec<String>,
    /// Whether this is the primary key index
    pub is_primary: bool,
    /// Whether index enforces uniqueness
    pub is_unique: bool,
    /// Whether index covers all query columns (no table access needed)
    pub is_covering: bool,
    /// Type of index operation performed
    pub seek_type: IndexSeekType,
    /// Estimated rows to be read from index
    pub rows_estimated: u64,
    /// Actual rows read from index
    pub rows_actual: u64,
    /// Number of levels traversed in index
    pub index_depth: u32,
}

impl IndexInfo {
    /// Create new index info
    pub fn new(index_name: String, index_type: IndexType, index_columns: Vec<String>) -> Self {
        Self {
            index_name,
            index_type,
            index_columns,
            is_primary: false,
            is_unique: false,
            is_covering: false,
            seek_type: IndexSeekType::PointLookup,
            rows_estimated: 0,
            rows_actual: 0,
            index_depth: 0,
        }
    }

    /// Mark as primary key index
    pub fn with_primary(mut self, primary: bool) -> Self {
        self.is_primary = primary;
        self
    }

    /// Mark as unique index
    pub fn with_unique(mut self, unique: bool) -> Self {
        self.is_unique = unique;
        self
    }

    /// Mark as covering index
    pub fn with_covering(mut self, covering: bool) -> Self {
        self.is_covering = covering;
        self
    }

    /// Set seek type
    pub fn with_seek_type(mut self, seek_type: IndexSeekType) -> Self {
        self.seek_type = seek_type;
        self
    }

    /// Set estimated rows
    pub fn with_estimated_rows(mut self, rows: u64) -> Self {
        self.rows_estimated = rows;
        self
    }

    /// Set actual rows read
    pub fn with_actual_rows(mut self, rows: u64) -> Self {
        self.rows_actual = rows;
        self
    }

    /// Set index depth
    pub fn with_index_depth(mut self, depth: u32) -> Self {
        self.index_depth = depth;
        self
    }
}

/// Runtime statistics collected during query execution
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ExecutionMetrics {
    /// Number of rows output by this node
    pub rows_produced: u64,
    /// Number of rows read from child nodes
    pub rows_read: u64,
    /// Wall-clock time spent in this node (milliseconds)
    pub execution_time_ms: f64,
    /// CPU time consumed by this node (milliseconds)
    pub cpu_time_ms: f64,
    /// Number of disk blocks or pages read
    pub blocks_read: u64,
    /// Number of blocks served from cache
    pub blocks_cache_hit: u64,
    /// Peak memory usage during execution (bytes)
    pub memory_bytes: u64,
    /// Bytes written to disk due to memory pressure
    pub spill_bytes: u64,
}

impl ExecutionMetrics {
    /// Create new execution metrics with defaults
    pub fn new() -> Self {
        Self::default()
    }

    /// Calculate cache hit ratio
    pub fn cache_hit_ratio(&self) -> f64 {
        if self.blocks_read == 0 {
            0.0
        } else {
            self.blocks_cache_hit as f64 / self.blocks_read as f64
        }
    }

    /// Calculate rows filtered ratio
    pub fn filter_ratio(&self) -> f64 {
        if self.rows_read == 0 {
            0.0
        } else {
            self.rows_produced as f64 / self.rows_read as f64
        }
    }
}

/// Distinguishes between estimated plans and actual plans
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PlanType {
    /// Plan generated by optimizer without execution
    Estimated,
    /// Plan populated with real execution metrics
    Actual,
    /// Partially executed plan with some estimated and some actual metrics
    Hybrid,
}

impl fmt::Display for PlanType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlanType::Estimated => write!(f, "estimated"),
            PlanType::Actual => write!(f, "actual"),
            PlanType::Hybrid => write!(f, "hybrid"),
        }
    }
}

/// Controls how much effort the optimizer spends on plan generation
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum OptimizationLevel {
    /// Fast planning with minimal optimization
    Minimal,
    /// Balance between planning time and plan quality
    Standard,
    /// Exhaustive search for optimal plan (expensive)
    Full,
    /// Dynamically adjust based on query complexity
    Adaptive,
}

impl fmt::Display for OptimizationLevel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            OptimizationLevel::Minimal => write!(f, "minimal"),
            OptimizationLevel::Standard => write!(f, "standard"),
            OptimizationLevel::Full => write!(f, "full"),
            OptimizationLevel::Adaptive => write!(f, "adaptive"),
        }
    }
}

/// Represents a single operation within a query execution plan
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanNode {
    /// Unique identifier for this node within the plan
    pub node_id: NodeId,
    /// The type of operation this node performs
    pub node_type: PlanNodeType,
    /// Query optimizer's estimated cost for this operation
    pub estimated_cost: Cost,
    /// Actual runtime metrics collected during execution
    pub actual_metrics: ExecutionMetrics,
    /// Child nodes that provide input to this operation
    pub children: Vec<PlanNode>,
    /// Filters or conditions applied at this node
    pub predicates: Vec<Predicate>,
    /// Metadata for table access operations
    pub table_info: Option<TableInfo>,
    /// Metadata for index usage operations
    pub index_info: Option<IndexInfo>,
}

impl PlanNode {
    /// Create a new plan node
    pub fn new(node_id: NodeId, node_type: PlanNodeType, estimated_cost: Cost) -> Self {
        Self {
            node_id,
            node_type,
            estimated_cost,
            actual_metrics: ExecutionMetrics::default(),
            children: Vec::new(),
            predicates: Vec::new(),
            table_info: None,
            index_info: None,
        }
    }

    /// Add a child node
    pub fn with_child(mut self, child: PlanNode) -> Self {
        self.children.push(child);
        self
    }

    /// Add multiple children
    pub fn with_children(mut self, children: Vec<PlanNode>) -> Self {
        self.children.extend(children);
        self
    }

    /// Set execution metrics
    pub fn with_metrics(mut self, metrics: ExecutionMetrics) -> Self {
        self.actual_metrics = metrics;
        self
    }

    /// Add a predicate
    pub fn with_predicate(mut self, predicate: Predicate) -> Self {
        self.predicates.push(predicate);
        self
    }

    /// Set table info
    pub fn with_table_info(mut self, info: TableInfo) -> Self {
        self.table_info = Some(info);
        self
    }

    /// Set index info
    pub fn with_index_info(mut self, info: IndexInfo) -> Self {
        self.index_info = Some(info);
        self
    }

    /// Calculate total cost including all children
    pub fn total_cost(&self) -> Cost {
        let children_cost: Cost = self.children.iter().map(|c| c.total_cost()).sum();
        self.estimated_cost + children_cost
    }

    /// Count total nodes in subtree
    pub fn count_nodes(&self) -> u32 {
        let child_count: u32 = self.children.iter().map(|c| c.count_nodes()).sum();
        1 + child_count
    }

    /// Find maximum depth of subtree
    pub fn max_depth(&self) -> u32 {
        if self.children.is_empty() {
            1
        } else {
            1 + self.children.iter().map(|c| c.max_depth()).max().unwrap_or(0)
        }
    }
}

/// Complete query execution plan
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryPlan {
    /// Unique identifier for the query
    pub query_id: QueryId,
    /// Original SQL or query language text
    pub query_text: String,
    /// Root node of the plan tree
    pub plan_tree: PlanNode,
    /// Whether plan is estimated or actual
    pub plan_type: PlanType,
    /// Optimizer's total estimated cost
    pub total_cost: Cost,
    /// Total actual execution time
    pub total_time_ms: f64,
    /// When the plan was generated (Unix timestamp)
    pub created_at: i64,
    /// Aggressiveness of optimization applied
    pub optimization_level: OptimizationLevel,
}

impl QueryPlan {
    /// Create a new query plan
    pub fn new(query_id: QueryId, query_text: String, plan_tree: PlanNode, plan_type: PlanType) -> Self {
        let total_cost = plan_tree.total_cost();
        Self {
            query_id,
            query_text,
            plan_tree,
            plan_type,
            total_cost,
            total_time_ms: 0.0,
            created_at: chrono::Utc::now().timestamp(),
            optimization_level: OptimizationLevel::Standard,
        }
    }

    /// Set actual execution time
    pub fn with_execution_time(mut self, time_ms: f64) -> Self {
        self.total_time_ms = time_ms;
        self
    }

    /// Set optimization level
    pub fn with_optimization_level(mut self, level: OptimizationLevel) -> Self {
        self.optimization_level = level;
        self
    }

    /// Calculate plan depth
    pub fn depth(&self) -> u32 {
        self.plan_tree.max_depth()
    }

    /// Count total nodes
    pub fn node_count(&self) -> u32 {
        self.plan_tree.count_nodes()
    }

    /// Find maximum branching factor
    pub fn max_branching(&self) -> u32 {
        fn max_branching_node(node: &PlanNode) -> u32 {
            let child_max = node.children.iter().map(max_branching_node).max().unwrap_or(0);
            child_max.max(node.children.len() as u32)
        }
        max_branching_node(&self.plan_tree)
    }
}

/// Defines output formats for query plan visualization
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum VisualizationFormat {
    /// Plain text hierarchical representation
    Text,
    /// Structured JSON format
    Json,
    /// Graphviz DOT format
    Dot,
    /// Interactive HTML visualization
    Html,
    /// Markdown table format
    Markdown,
}

impl fmt::Display for VisualizationFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VisualizationFormat::Text => write!(f, "text"),
            VisualizationFormat::Json => write!(f, "json"),
            VisualizationFormat::Dot => write!(f, "dot"),
            VisualizationFormat::Html => write!(f, "html"),
            VisualizationFormat::Markdown => write!(f, "markdown"),
        }
    }
}

/// Cost metric type for finding expensive nodes
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum CostMetric {
    /// Wall-clock time (ms)
    ExecutionTime,
    /// CPU consumption (ms)
    CpuTime,
    /// Disk I/O operations
    BlocksRead,
    /// Data volume processed
    RowsRead,
    /// Peak memory usage
    MemoryBytes,
}

/// Qualitative assessment of a plan change
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ChangeImpact {
    /// Change resulted in better performance
    Improved,
    /// Change resulted in worse performance
    Degraded,
    /// No significant performance impact
    Neutral,
}

/// Categorizes the type of structural difference between plans
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum StructuralChangeType {
    /// Plans are structurally the same
    Identical,
    /// After plan has fewer nodes or less depth
    Simplified,
    /// After plan has more nodes (possible for complex queries)
    Complex,
    /// Same complexity but different organization
    Restructured,
}

/// Describes a change in index usage between two plans
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexChange {
    /// Table whose index usage changed
    pub table_name: String,
    /// Index used in before plan
    pub before_index: Option<String>,
    /// Index used in after plan
    pub after_index: Option<String>,
    /// Type of index operation before
    pub before_type: IndexSeekType,
    /// Type of index operation after
    pub after_type: IndexSeekType,
    /// Whether change improved, degraded, or neutral
    pub impact: ChangeImpact,
}

/// Describes a change in join strategy between two plans
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JoinChange {
    /// Position of the join in the plan
    pub position: u32,
    /// Join strategy used in before plan
    pub before_strategy: PlanNodeType,
    /// Join strategy used in after plan
    pub after_strategy: PlanNodeType,
    /// Whether change improved, degraded, or neutral
    pub impact: ChangeImpact,
}

/// Summary of differences between two query plans
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanComparison {
    /// Percentage reduction in total cost
    pub cost_improvement_pct: f64,
    /// Percentage reduction in execution time
    pub time_improvement_pct: f64,
    /// How the plan structure changed
    pub structural_change: StructuralChangeType,
    /// Differences in index usage
    pub index_changes: Vec<IndexChange>,
    /// Differences in join strategies
    pub join_changes: Vec<JoinChange>,
    /// Human-readable observations about improvements
    pub insights: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_plan_node_creation() {
        let node = PlanNode::new(1, PlanNodeType::TableScan, 1000.0);
        assert_eq!(node.node_id, 1);
        assert_eq!(node.node_type, PlanNodeType::TableScan);
        assert_eq!(node.estimated_cost, 1000.0);
        assert!(node.children.is_empty());
    }

    #[test]
    fn test_plan_node_builder() {
        let child = PlanNode::new(2, PlanNodeType::IndexSeek, 100.0);
        let node = PlanNode::new(1, PlanNodeType::Filter, 500.0)
            .with_child(child)
            .with_predicate(Predicate::new(
                "age".to_string(),
                PredicateOperator::GreaterThan,
                LiteralValue::Integer(25),
                true,
            ));

        assert_eq!(node.children.len(), 1);
        assert_eq!(node.predicates.len(), 1);
    }

    #[test]
    fn test_plan_node_cost() {
        let child1 = PlanNode::new(2, PlanNodeType::IndexSeek, 100.0);
        let child2 = PlanNode::new(3, PlanNodeType::IndexSeek, 150.0);
        let node = PlanNode::new(1, PlanNodeType::Filter, 500.0)
            .with_children(vec![child1, child2]);

        assert_eq!(node.total_cost(), 750.0);
    }

    #[test]
    fn test_plan_node_depth() {
        let leaf = PlanNode::new(3, PlanNodeType::IndexSeek, 100.0);
        let middle = PlanNode::new(2, PlanNodeType::Filter, 500.0).with_child(leaf);
        let root = PlanNode::new(1, PlanNodeType::TableScan, 1000.0).with_child(middle);

        assert_eq!(root.max_depth(), 3);
    }

    #[test]
    fn test_query_plan_creation() {
        let plan_tree = PlanNode::new(1, PlanNodeType::TableScan, 1000.0);
        let plan = QueryPlan::new(
            1,
            "SELECT * FROM users".to_string(),
            plan_tree,
            PlanType::Estimated,
        );

        assert_eq!(plan.query_id, 1);
        assert_eq!(plan.plan_type, PlanType::Estimated);
        assert_eq!(plan.total_cost, 1000.0);
    }

    #[test]
    fn test_execution_metrics_ratios() {
        let metrics = ExecutionMetrics {
            rows_produced: 80,
            rows_read: 100,
            blocks_read: 1000,
            blocks_cache_hit: 800,
            ..Default::default()
        };

        assert!((metrics.cache_hit_ratio() - 0.8).abs() < 0.01);
        assert!((metrics.filter_ratio() - 0.8).abs() < 0.01);
    }

    #[test]
    fn test_predicate_display() {
        assert_eq!(format!("{}", PredicateOperator::Equal), "=");
        assert_eq!(format!("{}", PredicateOperator::GreaterThan), ">");
        assert_eq!(format!("{}", PredicateOperator::Like), "LIKE");
    }

    #[test]
    fn test_index_info_builder() {
        let info = IndexInfo::new(
            "idx_users_age".to_string(),
            IndexType::BTree,
            vec!["age".to_string()],
        )
        .with_primary(false)
        .with_unique(true)
        .with_seek_type(IndexSeekType::RangeScan)
        .with_estimated_rows(1000)
        .with_index_depth(3);

        assert_eq!(info.index_name, "idx_users_age");
        assert!(!info.is_primary);
        assert!(info.is_unique);
        assert_eq!(info.seek_type, IndexSeekType::RangeScan);
    }
}
