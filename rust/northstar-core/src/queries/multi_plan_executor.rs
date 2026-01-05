//! Multi-Plan Query Executor
//!
//! This module provides parallel execution of multiple query plans with
//! runtime selection of the best-performing plan. It executes multiple
//! alternative plans concurrently and returns results from the fastest
//! completing plan, while cancelling slower plans.

use crate::queries::types::QueryPlan;
use crate::queries::plan_learning::{PlanExecutionMetrics, PlanLearningEngine};
use crate::{Error, Result};
use std::sync::Arc;
use std::time::{Duration, SystemTime, Instant};
use tokio::sync::{RwLock, Semaphore};
use tokio::task::JoinHandle;
use tokio::time::timeout;

/// Configuration for multi-plan execution
#[derive(Debug, Clone)]
pub struct MultiPlanConfig {
    /// Maximum number of plans to execute concurrently
    pub max_concurrent_plans: usize,

    /// Timeout per plan execution
    pub plan_timeout: Duration,

    /// Maximum memory quota per plan (bytes)
    pub max_memory_bytes: u64,

    /// Threshold for cancelling slower plans (ms)
    pub cancellation_threshold_ms: u64,

    /// Whether to enable parallel execution
    pub enable_parallel: bool,
}

impl Default for MultiPlanConfig {
    fn default() -> Self {
        Self {
            max_concurrent_plans: 3,
            plan_timeout: Duration::from_secs(30),
            max_memory_bytes: 100 * 1024 * 1024, // 100 MB
            cancellation_threshold_ms: 100,
            enable_parallel: true,
        }
    }
}

impl MultiPlanConfig {
    /// Create with custom parameters
    pub fn new(
        max_concurrent_plans: usize,
        plan_timeout: Duration,
        max_memory_bytes: u64,
        cancellation_threshold_ms: u64,
    ) -> Self {
        Self {
            max_concurrent_plans: max_concurrent_plans.max(1),
            plan_timeout,
            max_memory_bytes,
            cancellation_threshold_ms,
            enable_parallel: true,
        }
    }

    /// Create conservative config (single plan execution)
    pub fn conservative() -> Self {
        Self {
            max_concurrent_plans: 1,
            plan_timeout: Duration::from_secs(60),
            max_memory_bytes: 50 * 1024 * 1024,
            cancellation_threshold_ms: 500,
            enable_parallel: false,
        }
    }

    /// Create aggressive config (max parallelism)
    pub fn aggressive() -> Self {
        Self {
            max_concurrent_plans: 5,
            plan_timeout: Duration::from_secs(10),
            max_memory_bytes: 200 * 1024 * 1024,
            cancellation_threshold_ms: 50,
            enable_parallel: true,
        }
    }
}

/// Result from a single plan execution
#[derive(Debug, Clone)]
pub struct PlanResult {
    /// Plan that produced this result
    pub plan: QueryPlan,

    /// Execution metrics
    pub metrics: PlanExecutionMetrics,

    /// Whether execution completed successfully
    pub succeeded: bool,

    /// Error message if execution failed
    pub error: Option<String>,
}

impl PlanResult {
    /// Create successful result
    pub fn success(plan: QueryPlan, metrics: PlanExecutionMetrics) -> Self {
        Self {
            plan,
            metrics,
            succeeded: true,
            error: None,
        }
    }

    /// Create failed result
    pub fn failure(plan: QueryPlan, error: String) -> Self {
        Self {
            plan,
            metrics: PlanExecutionMetrics {
                query_id: String::new(),
                plan_hash: 0,
                execution_time: Duration::ZERO,
                rows_processed: 0,
                memory_used_bytes: 0,
                timestamp: SystemTime::now(),
                succeeded: false,
            },
            succeeded: false,
            error: Some(error),
        }
    }

    /// Get execution score (lower is better)
    pub fn score(&self) -> f64 {
        self.metrics.execution_score()
    }
}

/// Multi-plan executor
pub struct MultiPlanExecutor {
    /// Plan learning engine for ranking plans
    learning_engine: Arc<PlanLearningEngine>,

    /// Execution configuration
    config: MultiPlanConfig,

    /// Resource semaphore for concurrency control
    resource_semaphore: Arc<Semaphore>,
}

impl MultiPlanExecutor {
    /// Create new multi-plan executor
    pub fn new(learning_engine: Arc<PlanLearningEngine>, config: MultiPlanConfig) -> Self {
        let resource_semaphore = Arc::new(Semaphore::new(config.max_concurrent_plans));

        Self {
            learning_engine,
            config,
            resource_semaphore,
        }
    }

    /// Create with default configuration
    pub fn with_defaults(learning_engine: Arc<PlanLearningEngine>) -> Self {
        Self::new(learning_engine, MultiPlanConfig::default())
    }

    /// Execute multiple plans and return the best result
    pub async fn execute_best_plan<F, Fut>(
        &self,
        query_id: String,
        plans: Vec<QueryPlan>,
        executor_func: F,
    ) -> Result<PlanResult>
    where
        F: Fn(QueryPlan) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = Result<Vec<u8>>> + Send + 'static,
    {
        if plans.is_empty() {
            return Err(Error::Transaction(
                crate::error::TransactionError::Generic("No plans provided".to_string())
            ));
        }

        // Sort plans by historical performance
        let sorted_plans = self.rank_plans_by_history(query_id.clone(), plans).await?;

        // Limit to max concurrent plans
        let plans_to_execute: Vec<QueryPlan> = sorted_plans
            .into_iter()
            .take(self.config.max_concurrent_plans)
            .collect();

        if !self.config.enable_parallel || plans_to_execute.len() == 1 {
            // Single plan execution
            return self.execute_single_plan(query_id, &plans_to_execute[0], executor_func).await;
        }

        // Parallel execution with cancellation
        self.execute_plans_parallel(query_id, plans_to_execute, executor_func)
            .await
    }

    /// Rank plans by historical performance
    async fn rank_plans_by_history(
        &self,
        query_id: String,
        mut plans: Vec<QueryPlan>,
    ) -> Result<Vec<QueryPlan>> {
        // Get historical performance for each plan
        let mut plan_scores: Vec<(QueryPlan, f64)> = Vec::new();

        for plan in &plans {
            let plan_hash = self.hash_plan(plan);

            if let Some(history) = self
                .learning_engine
                .get_plan_performance(&query_id, plan_hash)
                .await
            {
                // Use average execution time as score (lower is better)
                // If confidence is low, add penalty to encourage exploration
                let confidence = history.confidence_score();
                let score = if confidence > 0.5 {
                    history.avg_time_ms
                } else {
                    // Add exploration bonus for low-confidence plans
                    history.avg_time_ms * (1.0 - confidence * 0.5)
                };

                plan_scores.push((plan.clone(), score));
            } else {
                // No history - give it a neutral score
                plan_scores.push((plan.clone(), 1000.0));
            }
        }

        // Sort by score (ascending - best plans first)
        plan_scores.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));

        // Extract sorted plans
        let sorted: Vec<QueryPlan> = plan_scores.into_iter().map(|(p, _)| p).collect();

        Ok(sorted)
    }

    /// Execute a single plan
    async fn execute_single_plan<F, Fut>(
        &self,
        query_id: String,
        plan: &QueryPlan,
        executor_func: F,
    ) -> Result<PlanResult>
    where
        F: Fn(QueryPlan) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = Result<Vec<u8>>> + Send,
    {
        let start = Instant::now();
        let plan_clone = plan.clone();

        let result = timeout(self.config.plan_timeout, executor_func(plan_clone)).await;

        let execution_time = start.elapsed();
        let plan_hash = self.hash_plan(plan);

        let metrics = PlanExecutionMetrics {
            query_id: query_id.clone(),
            plan_hash,
            execution_time,
            rows_processed: 0, // Will be filled by executor
            memory_used_bytes: 0, // Will be filled by executor
            timestamp: SystemTime::now(),
            succeeded: result.is_ok(),
        };

        match result {
            Ok(Ok(_)) => {
                // Record successful execution
                let _ = self
                    .learning_engine
                    .record_execution(query_id, metrics.clone())
                    .await;

                Ok(PlanResult::success(plan.clone(), metrics))
            }
            Ok(Err(e)) => {
                let error_msg = format!("Execution error: {}", e);
                Ok(PlanResult::failure(plan.clone(), error_msg))
            }
            Err(_) => {
                let error_msg = format!("Timeout after {:?}", self.config.plan_timeout);
                Ok(PlanResult::failure(plan.clone(), error_msg))
            }
        }
    }

    /// Execute multiple plans in parallel with cancellation
    async fn execute_plans_parallel<F, Fut>(
        &self,
        query_id: String,
        plans: Vec<QueryPlan>,
        executor_func: F,
    ) -> Result<PlanResult>
    where
        F: Fn(QueryPlan) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = Result<Vec<u8>>> + Send + 'static,
    {
        let mut handles: Vec<JoinHandle<(QueryPlan, Result<PlanResult>)>> = Vec::new();
        let query_id = Arc::new(query_id);
        let learning_engine = self.learning_engine.clone();
        let resource_semaphore = self.resource_semaphore.clone();
        let plan_timeout = self.config.plan_timeout;
        let config = self.config.clone();

        // Spawn tasks for each plan
        for plan in plans {
            let query_id_clone = query_id.clone();
            let learning_engine_clone = learning_engine.clone();
            let semaphore_clone = resource_semaphore.clone();
            let plan_clone = plan.clone();
            let executor_func_clone = &executor_func;

            let handle = tokio::spawn(async move {
                // Acquire semaphore permit
                let _permit = semaphore_clone.acquire().await.unwrap();

                let start = Instant::now();
                let plan_hash = MultiPlanExecutor::hash_plan_static(&plan_clone);
                let query_id_str = query_id_clone.as_ref().clone();

                // Execute with timeout
                let result = timeout(plan_timeout, executor_func_clone(plan_clone.clone())).await;

                let execution_time = start.elapsed();

                let metrics = PlanExecutionMetrics {
                    query_id: query_id_str.clone(),
                    plan_hash,
                    execution_time,
                    rows_processed: 0,
                    memory_used_bytes: 0,
                    timestamp: SystemTime::now(),
                    succeeded: result.is_ok(),
                };

                let plan_result = match result {
                    Ok(Ok(_)) => {
                        // Record successful execution
                        let _ = learning_engine_clone
                            .record_execution(query_id_str.clone(), metrics.clone())
                            .await;
                        PlanResult::success(plan_clone.clone(), metrics)
                    }
                    Ok(Err(e)) => PlanResult::failure(
                        plan_clone.clone(),
                        format!("Execution error: {}", e),
                    ),
                    Err(_) => PlanResult::failure(
                        plan_clone,
                        format!("Timeout after {:?}", plan_timeout),
                    ),
                };

                (plan_clone, Ok(plan_result))
            });

            handles.push(handle);
        }

        // Wait for first successful result
        let cancellation_threshold = Duration::from_millis(self.config.cancellation_threshold_ms);

        // Wait for results with cancellation logic
        let mut completed_results: Vec<PlanResult> = Vec::new();
        let mut remaining_handles = handles;

        while !remaining_handles.is_empty() {
            // Wait for at least one result
            if let Some(result) = tokio::task::spawn_blocking(move || {
                tokio::runtime::Handle::try_current().unwrap().block_on(async {
                    // Wait for first handle to complete
                    futures::future::select_all(remaining_handles).await.0
                })
            })
            .await
            .unwrap()
            {
                match result {
                    Ok((plan, Ok(plan_result))) => {
                        if plan_result.succeeded {
                            // We got a successful result!
                            // Cancel remaining tasks if threshold exceeded
                            let elapsed = plan_result.metrics.execution_time;

                            if completed_results.is_empty()
                                || elapsed < cancellation_threshold
                            {
                                // First success or within threshold - return immediately
                                return Ok(plan_result);
                            }
                        }

                        completed_results.push(plan_result);
                    }
                    Ok((_, Err(e))) => {
                        // Task failed
                        eprintln!("Plan execution task failed: {:?}", e);
                    }
                    Err(e) => {
                        // Task join failed
                        eprintln!("Failed to join task: {:?}", e);
                    }
                }
            }

            // Remove completed handle
            remaining_handles = remaining_handles
                .into_iter()
                .filter(|h| !h.is_finished())
                .collect();
        }

        // If we get here, return best result among completed
        if let Some(best) = completed_results
            .into_iter()
            .filter(|r| r.succeeded)
            .min_by_key(|r| r.metrics.execution_time)
        {
            Ok(best)
        } else {
            // All plans failed
            Ok(PlanResult::failure(
                QueryPlan {
                    intent: crate::queries::types::QueryIntent::PointLookup,
                    operations: vec![],
                    entity_links: std::collections::HashMap::new(),
                    estimated_cost: 0.0,
                    execution_hint: crate::queries::types::ExecutionHint::UseCache,
                },
                "All plans failed".to_string(),
            ))
        }
    }

    /// Calculate hash of a plan for comparison
    fn hash_plan(&self, plan: &QueryPlan) -> u64 {
        Self::hash_plan_static(plan)
    }

    /// Static helper to hash a plan
    fn hash_plan_static(plan: &QueryPlan) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        plan.intent.hash(&mut hasher);
        plan.operations.hash(&mut hasher);
        hasher.finish()
    }

    /// Get execution statistics
    pub async fn get_stats(&self) -> MultiPlanExecutorStats {
        let learning_stats = self.learning_engine.get_stats().await;

        MultiPlanExecutorStats {
            total_executions: learning_stats.total_queries,
            parallel_executions: learning_stats.total_comparisons,
            avg_concurrent_plans: self.config.max_concurrent_plans as f64,
            cancellation_rate: 0.0, // Would need to track this
            timeout_rate: 0.0,      // Would need to track this
        }
    }
}

/// Statistics for multi-plan executor
#[derive(Debug, Clone)]
pub struct MultiPlanExecutorStats {
    /// Total queries executed
    pub total_executions: u64,

    /// Number of parallel executions
    pub parallel_executions: u64,

    /// Average number of concurrent plans
    pub avg_concurrent_plans: f64,

    /// Rate of plan cancellations (0-1)
    pub cancellation_rate: f64,

    /// Rate of timeouts (0-1)
    pub timeout_rate: f64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::queries::types::{QueryIntent, QueryOperation, ExecutionHint};
    use std::collections::HashMap;

    #[tokio::test]
    async fn test_config_default() {
        let config = MultiPlanConfig::default();
        assert_eq!(config.max_concurrent_plans, 3);
        assert_eq!(config.plan_timeout, Duration::from_secs(30));
    }

    #[tokio::test]
    async fn test_config_conservative() {
        let config = MultiPlanConfig::conservative();
        assert_eq!(config.max_concurrent_plans, 1);
        assert!(!config.enable_parallel);
    }

    #[tokio::test]
    async fn test_config_aggressive() {
        let config = MultiPlanConfig::aggressive();
        assert_eq!(config.max_concurrent_plans, 5);
        assert!(config.enable_parallel);
    }

    #[tokio::test]
    async fn test_plan_result_success() {
        let plan = QueryPlan {
            intent: QueryIntent::PointLookup,
            operations: vec![],
            entity_links: HashMap::new(),
            estimated_cost: 1.0,
            execution_hint: ExecutionHint::UseCache,
        };

        let metrics = PlanExecutionMetrics {
            query_id: "test".to_string(),
            plan_hash: 123,
            execution_time: Duration::from_millis(100),
            rows_processed: 10,
            memory_used_bytes: 1024,
            timestamp: SystemTime::now(),
            succeeded: true,
        };

        let result = PlanResult::success(plan.clone(), metrics);
        assert!(result.succeeded);
        assert!(result.error.is_none());
    }

    #[tokio::test]
    async fn test_plan_result_failure() {
        let plan = QueryPlan {
            intent: QueryIntent::PointLookup,
            operations: vec![],
            entity_links: HashMap::new(),
            estimated_cost: 1.0,
            execution_hint: ExecutionHint::UseCache,
        };

        let result = PlanResult::failure(plan, "test error".to_string());
        assert!(!result.succeeded);
        assert_eq!(result.error.unwrap(), "test error");
    }

    #[tokio::test]
    async fn test_plan_hash() {
        let plan1 = QueryPlan {
            intent: QueryIntent::PointLookup,
            operations: vec![QueryOperation::PointLookup { key: vec![1, 2, 3] }],
            entity_links: HashMap::new(),
            estimated_cost: 1.0,
            execution_hint: ExecutionHint::UseCache,
        };

        let plan2 = QueryPlan {
            intent: QueryIntent::PointLookup,
            operations: vec![QueryOperation::PointLookup { key: vec![1, 2, 3] }],
            entity_links: HashMap::new(),
            estimated_cost: 1.0,
            execution_hint: ExecutionHint::UseCache,
        };

        let hash1 = MultiPlanExecutor::hash_plan_static(&plan1);
        let hash2 = MultiPlanExecutor::hash_plan_static(&plan2);

        assert_eq!(hash1, hash2);
    }

    #[tokio::test]
    async fn test_executor_creation() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let config = MultiPlanConfig::default();

        let executor = MultiPlanExecutor::new(learning_engine, config);
        assert_eq!(executor.config.max_concurrent_plans, 3);
    }

    #[tokio::test]
    async fn test_single_plan_execution() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let executor = MultiPlanExecutor::with_defaults(learning_engine);

        let plan = QueryPlan {
            intent: QueryIntent::PointLookup,
            operations: vec![],
            entity_links: HashMap::new(),
            estimated_cost: 1.0,
            execution_hint: ExecutionHint::UseCache,
        };

        let executor_func = |p: QueryPlan| async move {
            Ok(vec![1, 2, 3])
        };

        let result = executor
            .execute_single_plan("test_query".to_string(), &plan, executor_func)
            .await
            .unwrap();

        assert!(result.succeeded);
    }
}
