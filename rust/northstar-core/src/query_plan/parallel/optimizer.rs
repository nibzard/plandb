//! Parallel Query Optimizer
//!
//! This module implements cost-based decision making for when to parallelize
//! query operations based on data size, complexity, and available resources.

/// Decision on whether and how to parallelize a query.
#[derive(Debug, Clone, PartialEq)]
pub struct ParallelizationDecision {
    /// Whether to parallelize the query
    pub should_parallelize: bool,
    /// Number of workers to use
    pub num_workers: usize,
    /// Parallel strategy to employ
    pub strategy: ParallelStrategy,
    /// Estimated speedup factor
    pub estimated_speedup: f64,
    /// Reason for the decision
    pub reason: String,
}

impl ParallelizationDecision {
    /// Creates a decision to not parallelize.
    pub fn no_parallelization(reason: impl Into<String>) -> Self {
        Self {
            should_parallelize: false,
            num_workers: 1,
            strategy: ParallelStrategy::Serial,
            estimated_speedup: 1.0,
            reason: reason.into(),
        }
    }

    /// Creates a decision to parallelize with the given strategy.
    pub fn parallelize(
        num_workers: usize,
        strategy: ParallelStrategy,
        estimated_speedup: f64,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            should_parallelize: true,
            num_workers,
            strategy,
            estimated_speedup,
            reason: reason.into(),
        }
    }
}

/// Strategy for parallel execution.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ParallelStrategy {
    /// Execute serially (no parallelization)
    Serial,
    /// Partition data and process in parallel
    Partitioned,
    /// Pipeline parallelism (stages)
    Pipelined,
    /// Hybrid approach (partitioning + pipelining)
    Hybrid,
}

/// Cost-based optimizer for parallel query execution.
///
/// The optimizer analyzes query characteristics to determine whether
/// parallelization would be beneficial and which strategy to use.
#[derive(Debug, Clone)]
pub struct ParallelOptimizer {
    /// Minimum number of rows to consider parallelization
    min_rows_threshold: usize,
    /// Maximum degree of parallelism
    max_parallelism: usize,
    /// Overhead factor for parallelization (0.0 to 1.0)
    overhead_factor: f64,
    /// Minimum speedup to justify parallelization
    min_speedup_threshold: f64,
}

impl Default for ParallelOptimizer {
    fn default() -> Self {
        Self {
            min_rows_threshold: 10_000,
            max_parallelism: num_cpus::get(),
            overhead_factor: 0.1, // 10% overhead
            min_speedup_threshold: 1.2, // Need at least 20% speedup
        }
    }
}

impl ParallelOptimizer {
    /// Creates a new parallel optimizer with default settings.
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the minimum rows threshold.
    pub fn with_min_rows_threshold(mut self, threshold: usize) -> Self {
        self.min_rows_threshold = threshold;
        self
    }

    /// Sets the maximum parallelism.
    pub fn with_max_parallelism(mut self, max: usize) -> Self {
        self.max_parallelism = max;
        self
    }

    /// Sets the overhead factor.
    pub fn with_overhead_factor(mut self, factor: f64) -> Self {
        self.overhead_factor = factor.clamp(0.0, 1.0);
        self
    }

    /// Sets the minimum speedup threshold.
    pub fn with_min_speedup_threshold(mut self, threshold: f64) -> Self {
        self.min_speedup_threshold = threshold;
        self
    }

    /// Determines whether to parallelize based on row count and estimated cost.
    pub fn should_parallelize(
        &self,
        row_count: usize,
        estimated_cost: f64,
    ) -> ParallelizationDecision {
        // Check minimum threshold
        if row_count < self.min_rows_threshold {
            return ParallelizationDecision::no_parallelization(format!(
                "Row count {} below threshold {}",
                row_count, self.min_rows_threshold
            ));
        }

        // Calculate optimal number of workers
        let optimal_workers = self.calculate_optimal_workers(row_count, estimated_cost);

        // Estimate speedup
        let estimated_speedup = self.estimate_speedup(row_count, optimal_workers);

        // Check if speedup justifies overhead
        if estimated_speedup < self.min_speedup_threshold {
            return ParallelizationDecision::no_parallelization(format!(
                "Estimated speedup {:.2} below threshold {:.2}",
                estimated_speedup, self.min_speedup_threshold
            ));
        }

        // Determine strategy based on data size
        let strategy = self.select_strategy(row_count, estimated_cost);

        ParallelizationDecision::parallelize(
            optimal_workers,
            strategy,
            estimated_speedup,
            format!(
                "Parallelize with {} workers (speedup: {:.2}x)",
                optimal_workers, estimated_speedup
            ),
        )
    }

    /// Calculates the optimal number of workers for the given workload.
    fn calculate_optimal_workers(&self, row_count: usize, estimated_cost: f64) -> usize {
        // More workers for larger datasets
        // But bound by max parallelism
        let workers_by_rows = (row_count / 50_000).min(self.max_parallelism);
        let workers_by_cost = (estimated_cost.log2().ceil() as usize).min(self.max_parallelism);

        // Use the minimum of the two to avoid over-parallelization
        workers_by_rows.min(workers_by_cost).max(1)
    }

    /// Estimates the speedup factor for parallel execution.
    fn estimate_speedup(&self, row_count: usize, num_workers: usize) -> f64 {
        // Amdahl's Law: Speedup = 1 / ((1 - P) + P / N)
        // where P is the parallelizable fraction and N is the number of workers
        //
        // For query execution, we estimate P based on data size:
        // - Small queries: P = 0.3 (limited parallelizable portion)
        // - Medium queries: P = 0.6
        // - Large queries: P = 0.8 (highly parallelizable)

        let parallel_fraction = if row_count < 50_000 {
            0.3
        } else if row_count < 500_000 {
            0.6
        } else {
            0.8
        };

        let serial_fraction = 1.0 - parallel_fraction;
        let parallel_part = parallel_fraction / num_workers as f64;

        // Apply overhead factor
        let raw_speedup = 1.0 / (serial_fraction + parallel_part);
        raw_speedup * (1.0 - self.overhead_factor)
    }

    /// Selects the parallelization strategy based on query characteristics.
    fn select_strategy(&self, row_count: usize, _estimated_cost: f64) -> ParallelStrategy {
        // For very large datasets, use partitioned strategy
        if row_count > 1_000_000 {
            ParallelStrategy::Partitioned
        } else if row_count > 100_000 {
            // For medium datasets, use hybrid approach
            ParallelStrategy::Hybrid
        } else {
            // For smaller datasets, simple partitioning is fine
            ParallelStrategy::Partitioned
        }
    }

    /// Analyzes a join operation to determine parallelization strategy.
    pub fn analyze_join(
        &self,
        left_rows: usize,
        right_rows: usize,
        join_type: super::task::JoinType,
    ) -> ParallelizationDecision {
        let total_rows = left_rows + right_rows;

        if total_rows < self.min_rows_threshold {
            return ParallelizationDecision::no_parallelization(format!(
                "Join size {} below threshold",
                total_rows
            ));
        }

        // For joins, prefer hash-based parallelization
        let optimal_workers = self.calculate_optimal_workers(total_rows, total_rows as f64);
        let estimated_speedup = self.estimate_speedup(total_rows, optimal_workers);

        if estimated_speedup < self.min_speedup_threshold {
            return ParallelizationDecision::no_parallelization(
                "Insufficient estimated speedup for join".to_string(),
            );
        }

        let strategy = match join_type {
            super::task::JoinType::Inner => ParallelStrategy::Partitioned,
            _ => ParallelStrategy::Hybrid,
        };

        ParallelizationDecision::parallelize(
            optimal_workers,
            strategy,
            estimated_speedup,
            format!("Parallel {} join (speedup: {:.2}x)", join_type as usize, estimated_speedup),
        )
    }

    /// Analyzes an aggregation operation to determine parallelization strategy.
    pub fn analyze_aggregation(
        &self,
        input_rows: usize,
        num_groups: usize,
    ) -> ParallelizationDecision {
        if input_rows < self.min_rows_threshold {
            return ParallelizationDecision::no_parallelization(format!(
                "Aggregation input {} below threshold",
                input_rows
            ));
        }

        // Aggregations are highly parallelizable
        // Speedup depends on number of groups
        let group_factor = if num_groups > 0 {
            (input_rows as f64 / num_groups as f64).log10()
        } else {
            1.0
        };

        let optimal_workers = self.calculate_optimal_workers(input_rows, input_rows as f64);
        let estimated_speedup = self.estimate_speedup(input_rows, optimal_workers) * group_factor;

        if estimated_speedup < self.min_speedup_threshold {
            return ParallelizationDecision::no_parallelization(
                "Insufficient estimated speedup for aggregation".to_string(),
            );
        }

        ParallelizationDecision::parallelize(
            optimal_workers,
            ParallelStrategy::Partitioned,
            estimated_speedup,
            format!("Parallel aggregation (speedup: {:.2}x)", estimated_speedup),
        )
    }

    /// Analyzes a scan operation to determine parallelization strategy.
    pub fn analyze_scan(&self, table_rows: usize, page_count: usize) -> ParallelizationDecision {
        if table_rows < self.min_rows_threshold {
            return ParallelizationDecision::no_parallelization(format!(
                "Table size {} below threshold",
                table_rows
            ));
        }

        // Scans are highly parallelizable
        // More pages = more parallelization opportunities
        let page_factor = (page_count as f64 / 1000.0).min(2.0);

        let optimal_workers = self.calculate_optimal_workers(table_rows, page_count as f64);
        let estimated_speedup = self.estimate_speedup(table_rows, optimal_workers) * page_factor;

        if estimated_speedup < self.min_speedup_threshold {
            return ParallelizationDecision::no_parallelization(
                "Insufficient estimated speedup for scan".to_string(),
            );
        }

        ParallelizationDecision::parallelize(
            optimal_workers,
            ParallelStrategy::Partitioned,
            estimated_speedup,
            format!("Parallel table scan (speedup: {:.2}x)", estimated_speedup),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_optimizer_defaults() {
        let optimizer = ParallelOptimizer::default();
        assert_eq!(optimizer.min_rows_threshold, 10_000);
        assert!(optimizer.max_parallelism > 0);
        assert_eq!(optimizer.overhead_factor, 0.1);
    }

    #[test]
    fn test_no_parallelization_small_table() {
        let optimizer = ParallelOptimizer::default();
        let decision = optimizer.should_parallelize(1000, 10.0);

        assert!(!decision.should_parallelize);
        assert_eq!(decision.num_workers, 1);
        assert_eq!(decision.strategy, ParallelStrategy::Serial);
    }

    #[test]
    fn test_parallelize_large_table() {
        let optimizer = ParallelOptimizer::default();
        let decision = optimizer.should_parallelize(1_000_000, 1000.0);

        assert!(decision.should_parallelize);
        assert!(decision.num_workers > 1);
        assert!(decision.estimated_speedup > 1.0);
    }

    #[test]
    fn test_analyze_join() {
        let optimizer = ParallelOptimizer::default();
        let decision = optimizer.analyze_join(100_000, 100_000, crate::query_plan::parallel::JoinType::Inner);

        assert!(decision.should_parallelize);
        assert!(decision.num_workers > 1);
    }

    #[test]
    fn test_analyze_aggregation() {
        let optimizer = ParallelOptimizer::default();
        let decision = optimizer.analyze_aggregation(500_000, 1000);

        assert!(decision.should_parallelize);
        assert!(decision.num_workers > 1);
    }

    #[test]
    fn test_analyze_scan() {
        let optimizer = ParallelOptimizer::default();
        let decision = optimizer.analyze_scan(500_000, 5000);

        assert!(decision.should_parallelize);
        assert!(decision.num_workers > 1);
        assert_eq!(decision.strategy, ParallelStrategy::Partitioned);
    }

    #[test]
    fn test_estimate_speedup_scales_with_workers() {
        let optimizer = ParallelOptimizer::default();

        let speedup_2 = optimizer.estimate_speedup(1_000_000, 2);
        let speedup_4 = optimizer.estimate_speedup(1_000_000, 4);
        let speedup_8 = optimizer.estimate_speedup(1_000_000, 8);

        // Speedup should increase with more workers (but with diminishing returns)
        assert!(speedup_8 > speedup_4);
        assert!(speedup_4 > speedup_2);
        // Due to Amdahl's law, speedup_8 should be less than 2x speedup_4
        assert!(speedup_8 < speedup_4 * 2.0);
    }

    #[test]
    fn test_custom_threshold() {
        let optimizer = ParallelOptimizer::default().with_min_rows_threshold(100_000);
        let decision = optimizer.should_parallelize(50_000, 100.0);

        assert!(!decision.should_parallelize);
    }
}
