//! Natural Language Query Planner
//!
//! This module provides intelligent natural language to query translation,
//! enabling users to query NorthstarDB using plain English instead of
//! structured query syntax. It leverages LLM function calling and the
//! entity/topic cartridges for semantic understanding.

pub mod types;
pub mod planner;
pub mod entity_linker;
pub mod optimizer;
pub mod cache;
pub mod adaptive_cost;
pub mod plan_learning;
pub mod stats_optimizer;
pub mod multi_plan_executor;
pub mod runtime_selection;
pub mod plan_budgeting;

// Examples module (only compiled when examples feature is enabled)
#[cfg(feature = "examples")]
pub mod multi_plan_examples;

// Re-exports for convenience
pub use types::{
    QueryIntent, QueryPlan, QueryOperation,
    AggregationType, TraversalDirection, CartridgeType, LookupType,
    FilterOperator, ExecutionHint, Explanation, RankedEntity,
};
pub use planner::{QueryPlanner, QueryPlannerConfig};
pub use entity_linker::{EntityLinker, EntityLinkerConfig};
pub use optimizer::{QueryOptimizer, ResultRanker};
pub use cache::{
    QueryCacheIntegration, QueryCacheConfig, QueryPlanKey, CachedPlan,
    QueryFrequency, CachePriority, CommitInvalidation, QueryCacheIntegrationStats,
    QueryFrequencySummary,
};
pub use adaptive_cost::{
    AdaptiveCostModel, ExecutionStats, LearnedParameters, CostModelStats,
};
pub use plan_learning::{
    PlanLearningEngine, PlanExecutionMetrics, PlanPerformanceHistory,
    PlanComparison, PlanLearningStats,
};
pub use stats_optimizer::{
    StatisticsOptimizer, ColumnStatistics, HistogramBucket,
    CorrelationStatistics,
};
pub use multi_plan_executor::{
    MultiPlanExecutor, MultiPlanConfig, PlanResult, MultiPlanExecutorStats,
};
pub use runtime_selection::{
    RuntimePlanSelector, RuntimeSelectionConfig, SelectionMetadata,
    RuntimeDecision, ExecutionMonitor,
    SelectionReason, ExpectedPerformance, AbandonReason, SwitchReason,
};
pub use plan_budgeting::{
    PlanBudgetManager, ResourcePool, BudgetAllocation, BudgetHandle,
    ResourceUsage, BudgetCompliance, BudgetStatus, ResourceUtilization,
};
