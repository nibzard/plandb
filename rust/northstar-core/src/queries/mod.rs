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

// Re-exports for convenience
pub use types::{
    QueryIntent, QueryPlan, QueryOperation,
    AggregationType, TraversalDirection, CartridgeType, LookupType,
    FilterOperator, ExecutionHint, Explanation, RankedEntity,
};
pub use planner::{QueryPlanner, QueryPlannerConfig};
pub use entity_linker::{EntityLinker, EntityLinkerConfig};
pub use optimizer::{QueryOptimizer, ResultRanker};
