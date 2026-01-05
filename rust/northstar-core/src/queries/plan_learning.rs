//! Plan Learning and Adaptation
//!
//! This module provides functionality to learn from query plan executions
//! and automatically adapt to better performing plans. It tracks plan
//! performance over time and can switch to alternative plans when
//! they prove superior.

use crate::queries::types::QueryPlan;
use crate::{Error, Result};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::RwLock;

/// Performance metrics for a query plan execution
#[derive(Debug, Clone)]
pub struct PlanExecutionMetrics {
    /// Unique identifier for the query
    pub query_id: String,
    /// Hash of the plan (for comparing alternative plans)
    pub plan_hash: u64,
    /// Total execution time
    pub execution_time: Duration,
    /// Total rows processed
    pub rows_processed: u64,
    /// Memory used in bytes
    pub memory_used_bytes: u64,
    /// Timestamp of execution
    pub timestamp: SystemTime,
    /// Whether execution succeeded
    pub succeeded: bool,
}

impl PlanExecutionMetrics {
    /// Calculate execution score (lower is better)
    pub fn execution_score(&self) -> f64 {
        if !self.succeeded {
            return f64::INFINITY;
        }

        // Score combines time and memory usage
        let time_score = self.execution_time.as_millis() as f64;
        let memory_score = (self.memory_used_bytes as f64) / 1024.0; // KB

        time_score + memory_score * 0.001
    }
}

/// Performance history for a specific query plan
#[derive(Debug, Clone)]
pub struct PlanPerformanceHistory {
    /// Plan hash
    pub plan_hash: u64,
    /// Number of executions
    pub execution_count: u64,
    /// Total execution time across all runs
    pub total_time_ms: f64,
    /// Average execution time
    pub avg_time_ms: f64,
    /// Minimum execution time observed
    pub min_time_ms: f64,
    /// Maximum execution time observed
    pub max_time_ms: f64,
    /// Standard deviation of execution times
    pub std_dev_ms: f64,
    /// Success rate (0-1)
    pub success_rate: f64,
    /// Last execution timestamp
    pub last_execution: SystemTime,
    /// First execution timestamp
    pub first_execution: SystemTime,
}

impl PlanPerformanceHistory {
    /// Create new history entry from metrics
    pub fn from_metrics(metrics: &PlanExecutionMetrics) -> Self {
        let time_ms = metrics.execution_time.as_millis() as f64;

        Self {
            plan_hash: metrics.plan_hash,
            execution_count: 1,
            total_time_ms: time_ms,
            avg_time_ms: time_ms,
            min_time_ms: time_ms,
            max_time_ms: time_ms,
            std_dev_ms: 0.0,
            success_rate: if metrics.succeeded { 1.0 } else { 0.0 },
            last_execution: metrics.timestamp,
            first_execution: metrics.timestamp,
        }
    }

    /// Update history with new metrics
    pub fn update(&mut self, metrics: &PlanExecutionMetrics) {
        let time_ms = metrics.execution_time.as_millis() as f64;
        let old_avg = self.avg_time_ms;

        self.execution_count += 1;
        self.total_time_ms += time_ms;
        self.avg_time_ms = self.total_time_ms / self.execution_count as f64;
        self.min_time_ms = self.min_time_ms.min(time_ms);
        self.max_time_ms = self.max_time_ms.max(time_ms);
        self.last_execution = metrics.timestamp;

        // Update success rate with exponential moving average
        let current_success = if metrics.succeeded { 1.0 } else { 0.0 };
        self.success_rate = self.success_rate * 0.9 + current_success * 0.1;

        // Update standard deviation (Welford's method)
        if self.execution_count > 1 {
            let delta = time_ms - old_avg;
            let delta2 = time_ms - self.avg_time_ms;
            let variance = (self.std_dev_ms * self.std_dev_ms * (self.execution_count - 2) as f64
                + delta * delta2)
                / (self.execution_count - 1) as f64;
            self.std_dev_ms = variance.sqrt();
        }
    }

    /// Calculate stability score (0-1, higher = more stable)
    pub fn stability_score(&self) -> f64 {
        if self.execution_count < 2 || self.max_time_ms == self.min_time_ms {
            return 1.0;
        }

        // Coefficient of variation (normalized std dev)
        let cv = if self.avg_time_ms > 0.0 {
            self.std_dev_ms / self.avg_time_ms
        } else {
            0.0
        };

        // Convert to stability score (inverse of CV)
        (1.0 - cv.min(1.0)).max(0.0)
    }

    /// Calculate confidence score (0-1)
    pub fn confidence_score(&self) -> f64 {
        // Based on execution count and stability
        let count_factor = (self.execution_count as f64 / 50.0).min(1.0);
        let stability_factor = self.stability_score();

        count_factor * 0.6 + stability_factor * 0.4
    }
}

/// Plan comparison result
#[derive(Debug, Clone)]
pub struct PlanComparison {
    /// Whether the alternative plan is better
    pub is_better: bool,
    /// Performance improvement factor (1.0 = same, 2.0 = 2x better)
    pub improvement_factor: f64,
    /// Confidence in the comparison (0-1)
    pub confidence: f64,
    /// Estimated time savings in milliseconds
    pub estimated_savings_ms: f64,
}

/// Plan learning engine
pub struct PlanLearningEngine {
    /// Performance history per query and plan
    performance_history: Arc<RwLock<HashMap<String, HashMap<u64, PlanPerformanceHistory>>>>,

    /// Minimum executions before making plan decisions
    min_executions: u64,

    /// Minimum performance improvement to switch plans (percentage)
    min_improvement_pct: f64,

    /// Maximum history entries per query
    max_plans_per_query: usize,
}

impl PlanLearningEngine {
    /// Create new plan learning engine
    pub fn new() -> Self {
        Self {
            performance_history: Arc::new(RwLock::new(HashMap::new())),
            min_executions: 5,
            min_improvement_pct: 10.0,
            max_plans_per_query: 10,
        }
    }

    /// Create with custom configuration
    pub fn with_config(
        min_executions: u64,
        min_improvement_pct: f64,
        max_plans_per_query: usize,
    ) -> Self {
        Self {
            performance_history: Arc::new(RwLock::new(HashMap::new())),
            min_executions,
            min_improvement_pct: min_improvement_pct.max(1.0),
            max_plans_per_query,
        }
    }

    /// Record plan execution metrics
    pub async fn record_execution(&self, metrics: PlanExecutionMetrics) -> Result<()> {
        let mut history = self.performance_history.write().await;

        let query_plans = history
            .entry(metrics.query_id.clone())
            .or_insert_with(HashMap::new);

        if let Some(existing) = query_plans.get_mut(&metrics.plan_hash) {
            existing.update(&metrics);
        } else {
            // Trim if too many plans
            if query_plans.len() >= self.max_plans_per_query {
                // Remove worst performing plan
                if let Some((&worst_hash, _)) = query_plans
                    .iter()
                    .min_by(|a, b| {
                        a.1.avg_time_ms
                            .partial_cmp(&b.1.avg_time_ms)
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                {
                    query_plans.remove(&worst_hash);
                }
            }

            query_plans
                .insert(metrics.plan_hash, PlanPerformanceHistory::from_metrics(&metrics));
        }

        Ok(())
    }

    /// Get the best plan for a query
    pub async fn get_best_plan(&self, query_id: &str) -> Option<u64> {
        let history = self.performance_history.read().await;

        if let Some(query_plans) = history.get(query_id) {
            // Filter by minimum executions
            let qualified: Vec<_> = query_plans
                .iter()
                .filter(|(_, h)| h.execution_count >= self.min_executions)
                .collect();

            if qualified.is_empty() {
                return None;
            }

            // Find plan with best average performance
            let best = qualified
                .into_iter()
                .min_by(|a, b| {
                    a.1.avg_time_ms
                        .partial_cmp(&b.1.avg_time_ms)
                        .unwrap_or(std::cmp::Ordering::Equal)
                });

            best.map(|(hash, _)| *hash)
        } else {
            None
        }
    }

    /// Compare two alternative plans
    pub async fn compare_plans(
        &self,
        query_id: &str,
        plan_a_hash: u64,
        plan_b_hash: u64,
    ) -> Result<PlanComparison> {
        let history = self.performance_history.read().await;

        let query_plans = history
            .get(query_id)
            .ok_or_else(|| Error::invalid_input("Query not found"))?;

        let plan_a = query_plans
            .get(&plan_a_hash)
            .ok_or_else(|| Error::invalid_input("Plan A not found"))?;

        let plan_b = query_plans
            .get(&plan_b_hash)
            .ok_or_else(|| Error::invalid_input("Plan B not found"))?;

        // Only compare if both have sufficient executions
        if plan_a.execution_count < self.min_executions
            || plan_b.execution_count < self.min_executions
        {
            return Ok(PlanComparison {
                is_better: false,
                improvement_factor: 1.0,
                confidence: 0.0,
                estimated_savings_ms: 0.0,
            });
        }

        // Calculate improvement
        let avg_a = plan_a.avg_time_ms;
        let avg_b = plan_b.avg_time_ms;

        let is_better = avg_b < avg_a;
        let improvement_factor = if avg_a > 0.0 { avg_a / avg_b.max(1.0) } else { 1.0 };
        let estimated_savings_ms = avg_a - avg_b;

        // Calculate confidence based on execution counts and stability
        let confidence_a = plan_a.confidence_score();
        let confidence_b = plan_b.confidence_score();
        let confidence = (confidence_a + confidence_b) / 2.0;

        Ok(PlanComparison {
            is_better: is_better && (improvement_factor - 1.0) * 100.0 >= self.min_improvement_pct,
            improvement_factor,
            confidence,
            estimated_savings_ms,
        })
    }

    /// Get performance history for a plan
    pub async fn get_plan_history(
        &self,
        query_id: &str,
        plan_hash: u64,
    ) -> Option<PlanPerformanceHistory> {
        let history = self.performance_history.read().await;
        history.get(query_id)?.get(&plan_hash).cloned()
    }

    /// Get all plans for a query
    pub async fn get_all_plans(&self, query_id: &str) -> Vec<(u64, PlanPerformanceHistory)> {
        let history = self.performance_history.read().await;

        if let Some(query_plans) = history.get(query_id) {
            query_plans.iter().map(|(h, p)| (*h, p.clone())).collect()
        } else {
            Vec::new()
        }
    }

    /// Get statistics about the learning engine
    pub async fn get_stats(&self) -> PlanLearningStats {
        let history = self.performance_history.read().await;

        let total_queries = history.len();
        let total_plans: usize = history.values().map(|p| p.len()).sum();

        let learned_queries = history
            .values()
            .filter(|plans| {
                plans.iter().any(|(_, h)| h.execution_count >= self.min_executions)
            })
            .count();

        PlanLearningStats {
            total_queries,
            total_plans,
            queries_with_learned_plans: learned_queries,
            min_executions_threshold: self.min_executions,
            min_improvement_threshold_pct: self.min_improvement_pct,
        }
    }

    /// Reset history for a specific query
    pub async fn reset_query(&self, query_id: &str) {
        let mut history = self.performance_history.write().await;
        history.remove(query_id);
    }

    /// Reset all history
    pub async fn reset_all(&self) {
        let mut history = self.performance_history.write().await;
        history.clear();
    }

    /// Generate plan hash from query plan
    pub fn hash_plan(plan: &QueryPlan) -> u64 {
        use std::hash::{Hash, Hasher};
        use std::collections::hash_map::DefaultHasher;

        let mut hasher = DefaultHasher::new();

        // Hash the operations
        for op in &plan.operations {
            std::mem::discriminant(op).hash(&mut hasher);
        }

        // Hash the execution hint
        std::mem::discriminant(&plan.execution_hint).hash(&mut hasher);

        hasher.finish()
    }
}

impl Default for PlanLearningEngine {
    fn default() -> Self {
        Self::new()
    }
}

/// Statistics about the plan learning engine
#[derive(Debug, Clone)]
pub struct PlanLearningStats {
    /// Total number of queries tracked
    pub total_queries: usize,
    /// Total number of plans across all queries
    pub total_plans: usize,
    /// Number of queries with learned plans
    pub queries_with_learned_plans: usize,
    /// Minimum executions threshold
    pub min_executions_threshold: u64,
    /// Minimum improvement threshold
    pub min_improvement_threshold_pct: f64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::queries::types::{ExecutionHint, QueryIntent};
    use std::time::Duration;

    fn create_test_plan(hash_seed: u64) -> QueryPlan {
        QueryPlan {
            intent: QueryIntent::PointLookup,
            operations: vec![],
            entity_links: HashMap::new(),
            estimated_cost: 10.0,
            execution_hint: ExecutionHint::UseCache,
        }
    }

    fn create_test_metrics(
        query_id: &str,
        plan_hash: u64,
        time_ms: u64,
        succeeded: bool,
    ) -> PlanExecutionMetrics {
        PlanExecutionMetrics {
            query_id: query_id.to_string(),
            plan_hash,
            execution_time: Duration::from_millis(time_ms),
            rows_processed: 100,
            memory_used_bytes: 1024,
            timestamp: SystemTime::now(),
            succeeded,
        }
    }

    #[tokio::test]
    async fn test_record_execution() {
        let engine = PlanLearningEngine::new();

        let metrics = create_test_metrics("query_1", 123, 100, true);
        engine.record_execution(metrics).await.unwrap();

        let history = engine.get_plan_history("query_1", 123).await;
        assert!(history.is_some());
        assert_eq!(history.unwrap().execution_count, 1);
    }

    #[tokio::test]
    async fn test_multiple_executions() {
        let engine = PlanLearningEngine::new();

        for i in 0..5 {
            let metrics = create_test_metrics("query_1", 123, 100 + i * 10, true);
            engine.record_execution(metrics).await.unwrap();
        }

        let history = engine.get_plan_history("query_1", 123).await.unwrap();
        assert_eq!(history.execution_count, 5);
        assert_eq!(history.min_time_ms, 100.0);
        assert_eq!(history.max_time_ms, 140.0);
    }

    #[tokio::test]
    async fn test_best_plan_selection() {
        let engine = PlanLearningEngine::with_config(3, 10.0, 10);

        // Record executions for plan A (slower)
        for _ in 0..5 {
            let metrics = create_test_metrics("query_1", 111, 100, true);
            engine.record_execution(metrics).await.unwrap();
        }

        // Record executions for plan B (faster)
        for _ in 0..5 {
            let metrics = create_test_metrics("query_1", 222, 50, true);
            engine.record_execution(metrics).await.unwrap();
        }

        let best = engine.get_best_plan("query_1").await;
        assert_eq!(best, Some(222));
    }

    #[tokio::test]
    async fn test_plan_comparison() {
        let engine = PlanLearningEngine::with_config(3, 10.0, 10);

        // Plan A: 100ms average
        for _ in 0..5 {
            let metrics = create_test_metrics("query_1", 111, 100, true);
            engine.record_execution(metrics).await.unwrap();
        }

        // Plan B: 50ms average (2x better)
        for _ in 0..5 {
            let metrics = create_test_metrics("query_1", 222, 50, true);
            engine.record_execution(metrics).await.unwrap();
        }

        let comparison = engine.compare_plans("query_1", 111, 222).await.unwrap();

        assert!(comparison.is_better);
        assert!((comparison.improvement_factor - 2.0).abs() < 0.1);
        assert!(comparison.estimated_savings_ms > 0);
    }

    #[tokio::test]
    async fn test_stability_score() {
        let mut history = PlanPerformanceHistory::from_metrics(&create_test_metrics(
            "query",
            123,
            100,
            true,
        ));

        // Add consistent executions
        for _ in 0..10 {
            let metrics = create_test_metrics("query", 123, 100, true);
            history.update(&metrics);
        }

        // Should be very stable
        let stability = history.stability_score();
        assert!(stability > 0.9);
    }

    #[tokio::test]
    async fn test_confidence_score() {
        let mut history = PlanPerformanceHistory::from_metrics(&create_test_metrics(
            "query",
            123,
            100,
            true,
        ));

        // Low confidence initially
        assert!(history.confidence_score() < 0.5);

        // Add more executions
        for _ in 0..50 {
            let metrics = create_test_metrics("query", 123, 100, true);
            history.update(&metrics);
        }

        // Higher confidence with more data
        assert!(history.confidence_score() > 0.5);
    }

    #[tokio::test]
    async fn test_execution_score() {
        let metrics = PlanExecutionMetrics {
            query_id: "query".to_string(),
            plan_hash: 123,
            execution_time: Duration::from_millis(100),
            rows_processed: 1000,
            memory_used_bytes: 1024 * 1024, // 1MB
            timestamp: SystemTime::now(),
            succeeded: true,
        };

        let score = metrics.execution_score();
        assert!(score > 100.0); // At least the time component
        assert!(score < 200.0); // Memory adds a small amount
    }

    #[tokio::test]
    async fn test_failed_execution_infinite_score() {
        let metrics = PlanExecutionMetrics {
            query_id: "query".to_string(),
            plan_hash: 123,
            execution_time: Duration::from_millis(100),
            rows_processed: 1000,
            memory_used_bytes: 1024,
            timestamp: SystemTime::now(),
            succeeded: false, // Failed
        };

        assert_eq!(metrics.execution_score(), f64::INFINITY);
    }

    #[tokio::test]
    async fn test_reset_query() {
        let engine = PlanLearningEngine::new();

        let metrics = create_test_metrics("query_1", 123, 100, true);
        engine.record_execution(metrics).await.unwrap();

        engine.reset_query("query_1").await;

        let history = engine.get_plan_history("query_1", 123).await;
        assert!(history.is_none());
    }

    #[tokio::test]
    async fn test_min_improvement_threshold() {
        let engine = PlanLearningEngine::with_config(3, 50.0, 10); // Need 50% improvement

        // Plan A: 100ms
        for _ in 0..5 {
            let metrics = create_test_metrics("query_1", 111, 100, true);
            engine.record_execution(metrics).await.unwrap();
        }

        // Plan B: 60ms (40% better, not enough)
        for _ in 0..5 {
            let metrics = create_test_metrics("query_1", 222, 60, true);
            engine.record_execution(metrics).await.unwrap();
        }

        let comparison = engine.compare_plans("query_1", 111, 222).await.unwrap();

        // Should not be better due to threshold
        assert!(!comparison.is_better);
    }
}
