//! Query Plan Visualization Module
//!
//! This module provides comprehensive query plan visualization capabilities
//! for NorthstarDB, including multiple output formats and plan comparison.
//!
//! # Features
//!
//! - **Multiple visualization formats**: Text, JSON, DOT (Graphviz), HTML, Markdown
//! - **Plan comparison**: Compare plans before and after optimization
//! - **Cost analysis**: Find expensive nodes by various metrics
//! - **Interactive HTML**: Self-contained HTML with collapsible nodes
//!
//! # Example
//!
//! ```no_run
//! use northstar::query_plan::{visualize_plan, VisualizationFormat};
//!
//! // Generate text visualization
//! let text = visualize_plan(&plan, VisualizationFormat::Text).unwrap();
//! println!("{}", text);
//!
//! // Generate HTML visualization
//! let html = visualize_plan(&plan, VisualizationFormat::Html).unwrap();
//! std::fs::write("plan.html", html).unwrap();
//! ```

mod cache;
mod compare;
mod error;
mod types;
mod visualize;

pub mod hot_path;
pub mod index_stats;

pub use cache::{
    CachedPlan, InvalidationStrategy, PlanCache, PlanCacheConfig, PlanCacheError, PlanCacheStats,
};
pub use compare::{
    calculate_plan_depth, compare_plans, find_most_expensive_node,
};
pub use error::{QueryPlanError, Result};
pub use types::{
    Cost, CostMetric, ChangeImpact, ExecutionMetrics, IndexChange, IndexInfo, IndexSeekType,
    IndexType, JoinChange, LiteralValue, NodeId, OptimizationLevel, PlanComparison, PlanNode,
    PlanNodeType, PlanType, Predicate, PredicateOperator, QueryId, QueryPlan, StructuralChangeType,
    TableInfo, TableType, VisualizationFormat,
};
pub use visualize::{visualize_plan, visualize_plan_dot, visualize_plan_html, visualize_plan_json,
    visualize_plan_markdown, visualize_plan_text};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query_plan::types::{PlanType, TableType};

    fn create_test_plan() -> QueryPlan {
        let scan = PlanNode::new(1, PlanNodeType::TableScan, 1000.0)
            .with_table_info(TableInfo::new(
                "users".to_string(),
                TableType::BTree,
                100000,
            ))
            .with_metrics(ExecutionMetrics {
                rows_produced: 100000,
                rows_read: 100000,
                execution_time_ms: 45.2,
                ..Default::default()
            });

        let filter = PlanNode::new(2, PlanNodeType::Filter, 500.0)
            .with_child(scan)
            .with_predicate(Predicate::new(
                "age".to_string(),
                PredicateOperator::GreaterThan,
                LiteralValue::Integer(25),
                true,
            ))
            .with_metrics(ExecutionMetrics {
                rows_produced: 30000,
                rows_read: 100000,
                execution_time_ms: 12.1,
                ..Default::default()
            });

        QueryPlan::new(
            1,
            "SELECT * FROM users WHERE age > 25".to_string(),
            filter,
            PlanType::Actual,
        )
        .with_execution_time(57.3)
    }

    #[test]
    fn test_module_integration() {
        let plan = create_test_plan();

        // Test all visualization formats
        let text = visualize_plan_text(&plan);
        assert!(text.contains("Query Plan"));

        let json = visualize_plan_json(&plan);
        assert!(json.is_ok());

        let dot = visualize_plan_dot(&plan);
        assert!(dot.contains("digraph"));

        let html = visualize_plan_html(&plan);
        assert!(html.contains("<!DOCTYPE html>"));

        let md = visualize_plan_markdown(&plan);
        assert!(md.contains("# Query Plan"));
    }

    #[test]
    fn test_plan_analysis() {
        let plan = create_test_plan();

        assert_eq!(calculate_plan_depth(&plan), 2);
        assert_eq!(plan.node_count(), 2);

        let metric = &CostMetric::ExecutionTime;
        let most_expensive = find_most_expensive_node(&plan, metric);
        assert!(most_expensive.is_some());
    }

    #[test]
    fn test_plan_comparison() {
        let before = create_test_plan();
        let after = QueryPlan::new(
            2,
            before.query_text.clone(),
            before.plan_tree.clone(),
            PlanType::Actual,
        )
        .with_execution_time(40.0);

        let comparison = compare_plans(&before, &after).unwrap();
        assert_eq!(comparison.structural_change, StructuralChangeType::Identical);
    }
}
