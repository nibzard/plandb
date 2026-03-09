//! Parallel Task Definitions
//!
//! This module defines the various parallel task types that can be executed
//! in the parallel query execution framework.

use std::sync::Arc;

// Simple expression type for parallel tasks
// In a real implementation, this would reference the actual expression type
#[derive(Debug, Clone)]
pub struct Expression {
    // Placeholder for expression
}

#[derive(Debug, Clone)]
pub struct Predicate {
    pub complexity_factor: f64,
}

impl Predicate {
    pub fn complexity_factor(&self) -> f64 {
        self.complexity_factor
    }
}

/// A parallel task that can be executed by a worker thread.
#[derive(Debug, Clone)]
pub enum ParallelTask {
    /// Table or index scan task
    Scan(ScanTask),
    /// Join operation task
    Join(JoinTask),
    /// Aggregation task
    Aggregate(AggregateTask),
    /// Sort operation task
    Sort(SortTask),
}

impl ParallelTask {
    /// Returns the task type identifier for metrics.
    pub fn task_type(&self) -> &'static str {
        match self {
            ParallelTask::Scan(_) => "scan",
            ParallelTask::Join(_) => "join",
            ParallelTask::Aggregate(_) => "aggregate",
            ParallelTask::Sort(_) => "sort",
        }
    }

    /// Estimates the computational cost of this task.
    pub fn estimated_cost(&self) -> f64 {
        match self {
            ParallelTask::Scan(task) => task.estimated_cost(),
            ParallelTask::Join(task) => task.estimated_cost(),
            ParallelTask::Aggregate(task) => task.estimated_cost(),
            ParallelTask::Sort(task) => task.estimated_cost(),
        }
    }
}

/// A table or index scan task operating on a partition of data.
#[derive(Debug, Clone)]
pub struct ScanTask {
    /// Unique identifier for this scan task
    pub task_id: usize,
    /// Partition identifier
    pub partition_id: usize,
    /// Page range to scan
    pub page_range: PagePartition,
    /// Optional predicate to filter rows
    pub predicate: Option<Predicate>,
    /// Table identifier
    pub table_id: String,
    /// Estimated number of rows in this partition
    pub estimated_rows: usize,
    /// Batch size for reading pages
    pub batch_size: usize,
}

impl ScanTask {
    /// Creates a new scan task.
    pub fn new(
        task_id: usize,
        partition_id: usize,
        page_range: PagePartition,
        table_id: impl Into<String>,
        estimated_rows: usize,
    ) -> Self {
        Self {
            task_id,
            partition_id,
            page_range,
            predicate: None,
            table_id: table_id.into(),
            estimated_rows,
            batch_size: 1000,
        }
    }

    /// Sets the predicate for this scan task.
    pub fn with_predicate(mut self, predicate: Predicate) -> Self {
        self.predicate = Some(predicate);
        self
    }

    /// Sets the batch size for reading pages.
    pub fn with_batch_size(mut self, batch_size: usize) -> Self {
        self.batch_size = batch_size;
        self
    }

    /// Estimates the cost of this scan task.
    pub fn estimated_cost(&self) -> f64 {
        let base_cost = self.estimated_rows as f64 * 0.001; // Base I/O cost
        let filter_cost = self.predicate.as_ref().map_or(0.0, |p| {
            // Add cost for evaluating predicate
            self.estimated_rows as f64 * p.complexity_factor()
        });
        base_cost + filter_cost
    }

    /// Returns the start page of this scan task.
    pub fn start_page(&self) -> u64 {
        self.page_range.start
    }

    /// Returns the end page of this scan task.
    pub fn end_page(&self) -> u64 {
        self.page_range.end
    }

    /// Returns the number of pages in this partition.
    pub fn page_count(&self) -> u64 {
        self.page_range.count()
    }
}

/// A partition of pages to be scanned.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PagePartition {
    /// Start page number (inclusive)
    pub start: u64,
    /// End page number (exclusive)
    pub end: u64,
}

impl PagePartition {
    /// Creates a new page partition.
    pub fn new(start: u64, end: u64) -> Self {
        assert!(end > start, "End page must be greater than start page");
        Self { start, end }
    }

    /// Returns the number of pages in this partition.
    pub fn count(&self) -> u64 {
        self.end - self.start
    }

    /// Returns true if this partition is empty.
    pub fn is_empty(&self) -> bool {
        self.start >= self.end
    }

    /// Splits this partition into two roughly equal parts.
    pub fn split(&self) -> (PagePartition, PagePartition) {
        let mid = self.start + self.count() / 2;
        (
            PagePartition::new(self.start, mid),
            PagePartition::new(mid, self.end),
        )
    }

    /// Creates a range iterator over this partition's pages.
    pub fn iter(&self) -> impl Iterator<Item = u64> {
        self.start..self.end
    }
}

/// A join operation task working on partitioned data.
#[derive(Debug, Clone)]
pub struct JoinTask {
    /// Unique identifier for this join task
    pub task_id: usize,
    /// Partition identifier
    pub partition_id: usize,
    /// Join type (inner, left, right, full)
    pub join_type: JoinType,
    /// Join condition
    pub condition: Expression,
    /// Build side task (left input)
    pub build_task: Arc<ParallelTask>,
    /// Probe side task (right input)
    pub probe_task: Arc<ParallelTask>,
    /// Estimated number of rows in build partition
    pub estimated_build_rows: usize,
    /// Estimated number of rows in probe partition
    pub estimated_probe_rows: usize,
    /// Join strategy to use
    pub strategy: JoinStrategy,
}

impl JoinTask {
    /// Creates a new join task.
    pub fn new(
        task_id: usize,
        partition_id: usize,
        join_type: JoinType,
        condition: Expression,
        build_task: Arc<ParallelTask>,
        probe_task: Arc<ParallelTask>,
        estimated_build_rows: usize,
        estimated_probe_rows: usize,
    ) -> Self {
        // Select strategy based on estimated sizes
        let strategy = if estimated_build_rows < 10000 {
            JoinStrategy::Broadcast
        } else {
            JoinStrategy::HashJoin
        };

        Self {
            task_id,
            partition_id,
            join_type,
            condition,
            build_task,
            probe_task,
            estimated_build_rows,
            estimated_probe_rows,
            strategy,
        }
    }

    /// Sets the join strategy explicitly.
    pub fn with_strategy(mut self, strategy: JoinStrategy) -> Self {
        self.strategy = strategy;
        self
    }

    /// Estimates the cost of this join task.
    pub fn estimated_cost(&self) -> f64 {
        match self.strategy {
            JoinStrategy::HashJoin => {
                // Build cost: O(build_rows)
                // Probe cost: O(build_rows + probe_rows)
                let build_cost = self.estimated_build_rows as f64 * 0.01;
                let probe_cost = (self.estimated_build_rows + self.estimated_probe_rows) as f64 * 0.01;
                build_cost + probe_cost
            }
            JoinStrategy::NestedLoop => {
                // O(build_rows * probe_rows)
                (self.estimated_build_rows * self.estimated_probe_rows) as f64 * 0.001
            }
            JoinStrategy::Broadcast => {
                // Broadcast small table to all workers
                let broadcast_cost = self.estimated_build_rows as f64 * 0.001;
                let probe_cost = (self.estimated_build_rows + self.estimated_probe_rows) as f64 * 0.01;
                broadcast_cost + probe_cost
            }
        }
    }
}

/// The type of join operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum JoinType {
    /// Inner join (default)
    Inner,
    /// Left outer join
    Left,
    /// Right outer join
    Right,
    /// Full outer join
    Full,
}

/// The strategy to use for executing the join.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum JoinStrategy {
    /// Build hash table on build side, probe with probe side
    HashJoin,
    /// Nested loop join (for small tables or complex conditions)
    NestedLoop,
    /// Broadcast small table to all workers
    Broadcast,
}

/// An aggregation task computing partial aggregates.
#[derive(Debug, Clone)]
pub struct AggregateTask {
    /// Unique identifier for this aggregate task
    pub task_id: usize,
    /// Partition identifier
    pub partition_id: usize,
    /// Group by expressions
    pub group_by: Vec<Expression>,
    /// Aggregate functions to compute
    pub aggregates: Vec<AggregateFunction>,
    /// Input task to aggregate
    pub input_task: Arc<ParallelTask>,
    /// Estimated number of input rows
    pub estimated_input_rows: usize,
    /// Whether this is a partial (map) or final (reduce) aggregation
    pub phase: AggregatePhase,
}

impl AggregateTask {
    /// Creates a new aggregation task.
    pub fn new(
        task_id: usize,
        partition_id: usize,
        group_by: Vec<Expression>,
        aggregates: Vec<AggregateFunction>,
        input_task: Arc<ParallelTask>,
        estimated_input_rows: usize,
        phase: AggregatePhase,
    ) -> Self {
        Self {
            task_id,
            partition_id,
            group_by,
            aggregates,
            input_task,
            estimated_input_rows,
            phase,
        }
    }

    /// Estimates the cost of this aggregation task.
    pub fn estimated_cost(&self) -> f64 {
        // Cost: O(input_rows) for grouping and aggregation
        let aggregation_cost = self.estimated_input_rows as f64 * 0.005;
        // Add overhead for hashing group keys
        let hash_cost = self.group_by.len() as f64 * self.estimated_input_rows as f64 * 0.001;
        aggregation_cost + hash_cost
    }

    /// Returns true if this is a partial aggregation task.
    pub fn is_partial(&self) -> bool {
        matches!(self.phase, AggregatePhase::Partial)
    }

    /// Returns true if this is a final aggregation task.
    pub fn is_final(&self) -> bool {
        matches!(self.phase, AggregatePhase::Final)
    }
}

/// The phase of aggregation (partial or final).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AggregatePhase {
    /// Partial aggregation (map phase)
    Partial,
    /// Final aggregation (reduce phase)
    Final,
}

/// An aggregate function to compute.
#[derive(Debug, Clone)]
pub enum AggregateFunction {
    /// COUNT(*) or COUNT(expression)
    Count { expression: Option<Expression> },
    /// SUM(expression)
    Sum { expression: Expression },
    /// AVG(expression)
    Avg { expression: Expression },
    /// MIN(expression)
    Min { expression: Expression },
    /// MAX(expression)
    Max { expression: Expression },
}

impl AggregateFunction {
    /// Returns the name of this aggregate function.
    pub fn name(&self) -> &'static str {
        match self {
            AggregateFunction::Count { .. } => "COUNT",
            AggregateFunction::Sum { .. } => "SUM",
            AggregateFunction::Avg { .. } => "AVG",
            AggregateFunction::Min { .. } => "MIN",
            AggregateFunction::Max { .. } => "MAX",
        }
    }

    /// Returns true if this aggregate function is commutative (can be parallelized).
    pub fn is_commutative(&self) -> bool {
        matches!(
            self,
            AggregateFunction::Count { .. }
                | AggregateFunction::Sum { .. }
                | AggregateFunction::Min { .. }
                | AggregateFunction::Max { .. }
        )
    }
}

/// A sort task operating on a partition of data.
#[derive(Debug, Clone)]
pub struct SortTask {
    /// Unique identifier for this sort task
    pub task_id: usize,
    /// Partition identifier
    pub partition_id: usize,
    /// Sort expressions (order by)
    pub sort_exprs: Vec<SortExpression>,
    /// Input task to sort
    pub input_task: Arc<ParallelTask>,
    /// Estimated number of input rows
    pub estimated_input_rows: usize,
    /// Whether this is a partial or final sort
    pub phase: SortPhase,
}

impl SortTask {
    /// Creates a new sort task.
    pub fn new(
        task_id: usize,
        partition_id: usize,
        sort_exprs: Vec<SortExpression>,
        input_task: Arc<ParallelTask>,
        estimated_input_rows: usize,
        phase: SortPhase,
    ) -> Self {
        Self {
            task_id,
            partition_id,
            sort_exprs,
            input_task,
            estimated_input_rows,
            phase,
        }
    }

    /// Estimates the cost of this sort task.
    pub fn estimated_cost(&self) -> f64 {
        // Sort cost: O(n log n)
        let n = self.estimated_input_rows as f64;
        let comparisons = n * n.log2().max(1.0);
        let comparison_cost = comparisons * 0.0001;
        // Add memory overhead for sorting
        let memory_cost = n * 0.00001;
        comparison_cost + memory_cost
    }

    /// Returns true if this is a partial sort task.
    pub fn is_partial(&self) -> bool {
        matches!(self.phase, SortPhase::Partial)
    }

    /// Returns true if this is a final merge task.
    pub fn is_final(&self) -> bool {
        matches!(self.phase, SortPhase::FinalMerge)
    }
}

/// A sort expression with direction.
#[derive(Debug, Clone)]
pub struct SortExpression {
    /// The expression to sort by
    pub expression: Expression,
    /// Whether to sort ascending (true) or descending (false)
    pub ascending: bool,
    /// Null position (first or last)
    pub nulls_first: bool,
}

/// The phase of sorting (partial or final merge).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SortPhase {
    /// Partial sort of a partition
    Partial,
    /// Final merge of sorted partitions
    FinalMerge,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_page_partition() {
        let partition = PagePartition::new(10, 20);
        assert_eq!(partition.start, 10);
        assert_eq!(partition.end, 20);
        assert_eq!(partition.count(), 10);
        assert!(!partition.is_empty());

        let (left, right) = partition.split();
        assert_eq!(left.start, 10);
        assert_eq!(left.end, 15);
        assert_eq!(right.start, 15);
        assert_eq!(right.end, 20);
    }

    #[test]
    fn test_scan_task() {
        let partition = PagePartition::new(0, 100);
        let task = ScanTask::new(1, 0, partition, "users", 10000);

        assert_eq!(task.task_id, 1);
        assert_eq!(task.partition_id, 0);
        assert_eq!(task.start_page(), 0);
        assert_eq!(task.end_page(), 100);
        assert_eq!(task.page_count(), 100);
        assert!(task.estimated_cost() > 0.0);
    }

    #[test]
    fn test_join_task() {
        let left_scan = ParallelTask::Scan(ScanTask::new(
            1,
            0,
            PagePartition::new(0, 10),
            "users",
            1000,
        ));
        let right_scan = ParallelTask::Scan(ScanTask::new(
            2,
            0,
            PagePartition::new(0, 20),
            "orders",
            2000,
        ));

        let join = JoinTask::new(
            3,
            0,
            JoinType::Inner,
            Expression {}, // Placeholder
            Arc::new(left_scan),
            Arc::new(right_scan),
            1000,
            2000,
        );

        assert_eq!(join.task_id, 3);
        assert_eq!(join.join_type, JoinType::Inner);
        assert!(join.estimated_cost() > 0.0);
    }

    #[test]
    fn test_aggregate_function() {
        let count = AggregateFunction::Count {
            expression: None,
        };
        assert_eq!(count.name(), "COUNT");
        assert!(count.is_commutative());

        let sum = AggregateFunction::Sum {
            expression: Expression {}, // Placeholder
        };
        assert_eq!(sum.name(), "SUM");
        assert!(sum.is_commutative());
    }

    #[test]
    fn test_parallel_task_type() {
        let scan = ParallelTask::Scan(ScanTask::new(
            1,
            0,
            PagePartition::new(0, 10),
            "users",
            1000,
        ));
        assert_eq!(scan.task_type(), "scan");
        assert!(scan.estimated_cost() > 0.0);
    }

    #[test]
    fn test_sort_expression() {
        let sort_expr = SortExpression {
            expression: Expression {}, // Placeholder
            ascending: true,
            nulls_first: true,
        };

        assert!(sort_expr.ascending);
        assert!(sort_expr.nulls_first);
    }

    #[test]
    fn test_aggregate_phase() {
        let partial_agg = AggregateTask::new(
            1,
            0,
            vec![],
            vec![AggregateFunction::Count { expression: None }],
            Arc::new(ParallelTask::Scan(ScanTask::new(
                1,
                0,
                PagePartition::new(0, 10),
                "users",
                1000,
            ))),
            1000,
            AggregatePhase::Partial,
        );

        assert!(partial_agg.is_partial());
        assert!(!partial_agg.is_final());
    }

    #[test]
    fn test_sort_phase() {
        let partial_sort = SortTask::new(
            1,
            0,
            vec![SortExpression {
                expression: Expression {}, // Placeholder
                ascending: true,
                nulls_first: true,
            }],
            Arc::new(ParallelTask::Scan(ScanTask::new(
                1,
                0,
                PagePartition::new(0, 10),
                "users",
                1000,
            ))),
            1000,
            SortPhase::Partial,
        );

        assert!(partial_sort.is_partial());
        assert!(!partial_sort.is_final());
    }
}
