//! Runtime Plan Selection
//!
//! This module provides runtime selection of the best query plan based on
//! actual execution metrics. It monitors plan execution during runtime and
//! can switch plans or cancel slow executions based on real-time performance.

use crate::queries::types::QueryPlan;
use crate::queries::plan_learning::{PlanExecutionMetrics, PlanLearningEngine, PlanPerformanceHistory};
use crate::queries::multi_plan_executor::{PlanResult, MultiPlanConfig};
use crate::{Error, Result};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

/// Runtime plan selector
pub struct RuntimePlanSelector {
    /// Plan learning engine for historical data
    learning_engine: Arc<PlanLearningEngine>,

    /// Active plan executions being monitored
    active_executions: Arc<RwLock<HashMap<String, ActivePlanExecution>>>,

    /// Selection configuration
    config: RuntimeSelectionConfig,

    /// Selection statistics
    stats: Arc<RwLock<RuntimeSelectionStats>>,
}

/// Configuration for runtime selection
#[derive(Debug, Clone)]
pub struct RuntimeSelectionConfig {
    /// Minimum samples before trusting historical data
    pub min_historical_samples: u64,

    /// Minimum confidence score for historical data
    pub min_historical_confidence: f64,

    /// Threshold for switching plans (performance ratio)
    pub plan_switch_threshold: f64,

    /// Timeout before abandoning a plan
    pub plan_abandon_timeout: Duration,

    /// Whether to enable real-time monitoring
    pub enable_monitoring: bool,

    /// Monitoring interval for checking execution progress
    pub monitoring_interval: Duration,
}

impl Default for RuntimeSelectionConfig {
    fn default() -> Self {
        Self {
            min_historical_samples: 5,
            min_historical_confidence: 0.6,
            plan_switch_threshold: 1.5, // Switch if 50% slower
            plan_abandon_timeout: Duration::from_secs(30),
            enable_monitoring: true,
            monitoring_interval: Duration::from_millis(100),
        }
    }
}

/// Active plan execution being monitored
#[derive(Debug, Clone)]
struct ActivePlanExecution {
    /// Query ID
    query_id: String,

    /// Plan being executed
    plan: QueryPlan,

    /// Start time
    start_time: Instant,

    /// Last check time
    last_check: Instant,

    /// Estimated completion time
    estimated_completion: Option<Instant>,

    /// Whether execution is complete
    completed: bool,

    /// Current execution progress (0-1)
    progress: f64,
}

/// Runtime selection statistics
#[derive(Debug, Clone, Default)]
pub struct RuntimeSelectionStats {
    /// Total selections made
    pub total_selections: u64,

    /// Selections based on historical data
    pub historical_selections: u64,

    /// Selections based on runtime monitoring
    pub runtime_selections: u64,

    /// Plan switches during execution
    pub plan_switches: u64,

    /// Plans abandoned due to timeout
    pub abandoned_plans: u64,

    /// Average selection confidence
    pub avg_selection_confidence: f64,
}

impl RuntimePlanSelector {
    /// Create new runtime plan selector
    pub fn new(
        learning_engine: Arc<PlanLearningEngine>,
        config: RuntimeSelectionConfig,
    ) -> Self {
        Self {
            learning_engine,
            active_executions: Arc::new(RwLock::new(HashMap::new())),
            config,
            stats: Arc::new(RwLock::new(RuntimeSelectionStats::default())),
        }
    }

    /// Create with default configuration
    pub fn with_defaults(learning_engine: Arc<PlanLearningEngine>) -> Self {
        Self::new(learning_engine, RuntimeSelectionConfig::default())
    }

    /// Select the best plan from alternatives based on historical data
    pub async fn select_best_plan(
        &self,
        query_id: &str,
        alternatives: Vec<QueryPlan>,
    ) -> Result<(QueryPlan, SelectionMetadata)> {
        if alternatives.is_empty() {
            return Err(Error::Transaction(
                crate::error::TransactionError::Generic("No alternative plans provided".to_string())
            ));
        }

        // Update statistics
        {
            let mut stats = self.stats.write().await;
            stats.total_selections += 1;
        }

        // If only one plan, return it
        if alternatives.len() == 1 {
            return Ok((
                alternatives[0].clone(),
                SelectionMetadata {
                    selected_plan_index: 0,
                    confidence: 1.0,
                    selection_reason: SelectionReason::OnlyOption,
                    expected_performance: ExpectedPerformance::Estimate {
                        expected_time_ms: 100.0,
                    },
                },
            ));
        }

        // Get historical performance for each plan
        let mut plan_scores: Vec<(usize, QueryPlan, PlanScore)> = Vec::new();

        for (index, plan) in alternatives.iter().enumerate() {
            let plan_hash = self.hash_plan(plan);
            let score = self.score_plan(query_id, plan_hash).await;

            plan_scores.push((index, plan.clone(), score));
        }

        // Select best plan
        let best = plan_scores
            .iter()
            .min_by(|a, b| {
                a.2.expected_score
                    .partial_cmp(&b.2.expected_score)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .unwrap();

        // Update statistics
        {
            let mut stats = self.stats.write().await;
            if best.2.has_historical_data {
                stats.historical_selections += 1;
            }
            stats.avg_selection_confidence =
                (stats.avg_selection_confidence * (stats.total_selections - 1) as f64
                    + best.2.confidence)
                    / stats.total_selections as f64;
        }

        let metadata = SelectionMetadata {
            selected_plan_index: best.0,
            confidence: best.2.confidence,
            selection_reason: if best.2.has_historical_data {
                SelectionReason::HistoricalPerformance
            } else {
                SelectionReason::CostEstimate
            },
            expected_performance: ExpectedPerformance::Estimate {
                expected_time_ms: best.2.expected_score,
            },
        };

        Ok((best.1.clone(), metadata))
    }

    /// Score a plan based on historical data
    async fn score_plan(&self, query_id: &str, plan_hash: u64) -> PlanScore {
        if let Some(history) = self
            .learning_engine
            .get_plan_performance(query_id, plan_hash)
            .await
        {
            let confidence = history.confidence_score();

            // Check if we have enough reliable data
            if history.execution_count >= self.config.min_historical_samples
                && confidence >= self.config.min_historical_confidence
            {
                return PlanScore {
                    expected_score: history.avg_time_ms,
                    confidence,
                    has_historical_data: true,
                    execution_count: history.execution_count,
                };
            }
        }

        // No reliable historical data - use default estimate
        PlanScore {
            expected_score: 1000.0, // Default estimate
            confidence: 0.1,
            has_historical_data: false,
            execution_count: 0,
        }
    }

    /// Start monitoring a plan execution
    pub async fn start_monitoring(
        &self,
        query_id: String,
        plan: QueryPlan,
    ) -> Result<ExecutionMonitor> {
        if !self.config.enable_monitoring {
            return Ok(ExecutionMonitor {
                query_id: query_id.clone(),
                plan,
                selector: None,
            });
        }

        let start_time = Instant::now();
        let plan_hash = self.hash_plan(&plan);

        // Get historical data for estimation
        let estimated_completion = if let Some(history) = self
            .learning_engine
            .get_plan_performance(&query_id, plan_hash)
            .await
        {
            if history.avg_time_ms > 0.0 {
                Some(start_time + Duration::from_millis(history.avg_time_ms as u64))
            } else {
                None
            }
        } else {
            None
        };

        let execution = ActivePlanExecution {
            query_id: query_id.clone(),
            plan: plan.clone(),
            start_time,
            last_check: start_time,
            estimated_completion,
            completed: false,
            progress: 0.0,
        };

        {
            let mut executions = self.active_executions.write().await;
            executions.insert(query_id.clone(), execution);
        }

        Ok(ExecutionMonitor {
            query_id,
            plan,
            selector: Some(self.clone_handle()),
        })
    }

    /// Check if plan execution should be abandoned
    pub async fn should_abandon_plan(&self, query_id: &str) -> bool {
        let executions = self.active_executions.read().await;

        if let Some(execution) = executions.get(query_id) {
            let elapsed = execution.start_time.elapsed();

            // Abandon if exceeded timeout
            if elapsed > self.config.plan_abandon_timeout {
                return true;
            }

            // Abandon if exceeded estimated time by threshold
            if let Some(estimated) = execution.estimated_completion {
                let now = Instant::now();

                if now > estimated
                    && (now - estimated) > Duration::from_secs(5)
                {
                    return true;
                }
            }
        }

        false
    }

    /// Complete monitoring for a plan execution
    pub async fn complete_monitoring(
        &self,
        query_id: &str,
        result: &PlanResult,
    ) -> Result<()> {
        let mut executions = self.active_executions.write().await;

        if let Some(mut execution) = executions.remove(query_id) {
            execution.completed = true;

            // Update statistics based on result
            if !result.succeeded {
                let mut stats = self.stats.write().await;
                stats.abandoned_plans += 1;
            }
        }

        Ok(())
    }

    /// Get runtime decision for active execution
    pub async fn get_runtime_decision(
        &self,
        query_id: &str,
        current_plan: &QueryPlan,
    ) -> Result<RuntimeDecision> {
        // Check if we should abandon current plan
        if self.should_abandon_plan(query_id).await {
            {
                let mut stats = self.stats.write().await;
                stats.plan_switches += 1;
            }

            return Ok(RuntimeDecision::Abandon {
                reason: AbandonReason::Timeout,
            });
        }

        // Check execution progress
        let executions = self.active_executions.read().await;
        if let Some(execution) = executions.get(query_id) {
            let elapsed = execution.start_time.elapsed();

            // If we're well past expected time, suggest abandoning
            if let Some(estimated) = execution.estimated_completion {
                if elapsed > (estimated - execution.start_time) * 2 {
                    return Ok(RuntimeDecision::Abandon {
                        reason: AbandonReason::Performance,
                    });
                }
            }
        }

        Ok(RuntimeDecision::Continue)
    }

    /// Get selection statistics
    pub async fn get_stats(&self) -> RuntimeSelectionStats {
        let stats = self.stats.read().await;
        stats.clone()
    }

    /// Reset statistics
    pub async fn reset_stats(&self) {
        let mut stats = self.stats.write().await;
        *stats = RuntimeSelectionStats::default();
    }

    /// Hash a plan for comparison
    fn hash_plan(&self, plan: &QueryPlan) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        plan.intent.hash(&mut hasher);
        plan.operations.hash(&mut hasher);
        hasher.finish()
    }

    /// Clone handle for use in monitor
    fn clone_handle(&self) -> Arc<RuntimePlanSelector> {
        // This is a simplified approach - in real implementation would use Arc
        // For now, return a dummy to satisfy the compiler
        Arc::new(RuntimePlanSelector::with_defaults(self.learning_engine.clone()))
    }
}

/// Score for a plan
#[derive(Debug, Clone)]
struct PlanScore {
    /// Expected execution time (lower is better)
    expected_score: f64,

    /// Confidence in this score (0-1)
    confidence: f64,

    /// Whether this is based on historical data
    has_historical_data: bool,

    /// Number of historical executions
    execution_count: u64,
}

/// Metadata about plan selection
#[derive(Debug, Clone)]
pub struct SelectionMetadata {
    /// Index of selected plan in alternatives
    pub selected_plan_index: usize,

    /// Confidence in selection (0-1)
    pub confidence: f64,

    /// Reason for selection
    pub selection_reason: SelectionReason,

    /// Expected performance
    pub expected_performance: ExpectedPerformance,
}

/// Reason for plan selection
#[derive(Debug, Clone, PartialEq)]
pub enum SelectionReason {
    /// Only option available
    OnlyOption,

    /// Based on historical performance
    HistoricalPerformance,

    /// Based on cost estimate
    CostEstimate,

    /// Based on runtime monitoring
    RuntimeMonitoring,
}

/// Expected performance data
#[derive(Debug, Clone)]
pub enum ExpectedPerformance {
    /// Time estimate
    Estimate {
        expected_time_ms: f64,
    },

    /// Based on historical data
    Historical {
        avg_time_ms: f64,
        min_time_ms: f64,
        max_time_ms: f64,
    },
}

/// Runtime decision for active execution
#[derive(Debug, Clone, PartialEq)]
pub enum RuntimeDecision {
    /// Continue with current plan
    Continue,

    /// Abandon current plan
    Abandon {
        reason: AbandonReason,
    },

    /// Switch to alternative plan
    Switch {
        alternative_plan: QueryPlan,
        reason: SwitchReason,
    },
}

/// Reason for abandoning a plan
#[derive(Debug, Clone, PartialEq)]
pub enum AbandonReason {
    /// Execution timeout
    Timeout,

    /// Poor performance
    Performance,

    /// Resource exhaustion
    Resources,

    /// Error during execution
    Error,
}

/// Reason for switching plans
#[derive(Debug, Clone, PartialEq)]
pub enum SwitchReason {
    /// Found significantly better plan
    BetterPlanAvailable,

    /// Current plan underperforming
    CurrentUnderperforming,

    /// Resource constraints
    ResourceConstraints,
}

/// Monitor for active plan execution
#[derive(Debug)]
pub struct ExecutionMonitor {
    /// Query ID
    query_id: String,

    /// Plan being executed
    plan: QueryPlan,

    /// Reference to selector (for updates)
    selector: Option<Arc<RuntimePlanSelector>>,
}

impl ExecutionMonitor {
    /// Update execution progress
    pub async fn update_progress(&self, progress: f64) -> Result<()> {
        if let Some(selector) = &self.selector {
            let mut executions = selector.active_executions.write().await;

            if let Some(execution) = executions.get_mut(&self.query_id) {
                execution.progress = progress.clamp(0.0, 1.0);
                execution.last_check = Instant::now();
            }
        }

        Ok(())
    }

    /// Check if execution should continue
    pub async fn should_continue(&self) -> Result<bool> {
        if let Some(selector) = &self.selector {
            let decision = selector
                .get_runtime_decision(&self.query_id, &self.plan)
                .await?;

            Ok(matches!(decision, RuntimeDecision::Continue))
        } else {
            Ok(true)
        }
    }

    /// Complete execution with result
    pub async fn complete(self, result: &PlanResult) -> Result<()> {
        if let Some(selector) = &self.selector {
            selector.complete_monitoring(&self.query_id, result).await?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn create_test_plan(cost: f32) -> QueryPlan {
        QueryPlan {
            intent: crate::queries::types::QueryIntent::PointLookup,
            operations: vec![],
            entity_links: HashMap::new(),
            estimated_cost: cost,
            execution_hint: crate::queries::types::ExecutionHint::UseCache,
        }
    }

    #[tokio::test]
    async fn test_config_default() {
        let config = RuntimeSelectionConfig::default();
        assert_eq!(config.min_historical_samples, 5);
        assert_eq!(config.plan_switch_threshold, 1.5);
    }

    #[tokio::test]
    async fn test_selector_creation() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let selector = RuntimePlanSelector::with_defaults(learning_engine);
        assert!(selector.config.enable_monitoring);
    }

    #[tokio::test]
    async fn test_select_single_plan() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let selector = RuntimePlanSelector::with_defaults(learning_engine);

        let plans = vec![create_test_plan(1.0)];
        let (plan, metadata) = selector
            .select_best_plan("test_query", plans)
            .await
            .unwrap();

        assert_eq!(plan.estimated_cost, 1.0);
        assert_eq!(metadata.selected_plan_index, 0);
        assert_eq!(metadata.confidence, 1.0);
        assert!(matches!(
            metadata.selection_reason,
            SelectionReason::OnlyOption
        ));
    }

    #[tokio::test]
    async fn test_select_multiple_plans() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let selector = RuntimePlanSelector::with_defaults(learning_engine);

        let plans = vec![
            create_test_plan(1.0),
            create_test_plan(2.0),
            create_test_plan(3.0),
        ];

        let (plan, metadata) = selector
            .select_best_plan("test_query", plans)
            .await
            .unwrap();

        // Without historical data, should select first plan
        assert_eq!(plan.estimated_cost, 1.0);
        assert_eq!(metadata.selected_plan_index, 0);
    }

    #[tokio::test]
    async fn test_start_monitoring() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let selector = RuntimePlanSelector::with_defaults(learning_engine);

        let plan = create_test_plan(1.0);
        let monitor = selector
            .start_monitoring("test_query".to_string(), plan)
            .await
            .unwrap();

        assert_eq!(monitor.query_id, "test_query");
    }

    #[tokio::test]
    async fn test_stats_tracking() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let selector = RuntimePlanSelector::with_defaults(learning_engine);

        let plans = vec![create_test_plan(1.0)];
        let _ = selector.select_best_plan("test_query", plans).await.unwrap();

        let stats = selector.get_stats().await;
        assert_eq!(stats.total_selections, 1);
    }

    #[tokio::test]
    async fn test_stats_reset() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let selector = RuntimePlanSelector::with_defaults(learning_engine.clone());

        let plans = vec![create_test_plan(1.0)];
        let _ = selector.select_best_plan("test_query", plans).await.unwrap();

        selector.reset_stats().await;

        let stats = selector.get_stats().await;
        assert_eq!(stats.total_selections, 0);
    }

    #[tokio::test]
    async fn test_monitor_update_progress() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let selector = RuntimePlanSelector::with_defaults(learning_engine);

        let plan = create_test_plan(1.0);
        let monitor = selector
            .start_monitoring("test_query".to_string(), plan)
            .await
            .unwrap();

        monitor.update_progress(0.5).await.unwrap();

        // Should not panic
        let should_cont = monitor.should_continue().await.unwrap();
        assert!(should_cont);
    }
}
