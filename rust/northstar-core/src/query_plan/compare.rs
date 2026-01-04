//! Query Plan Comparison
//!
//! This module provides functionality to compare two query plans,
//! typically before and after optimization.

use crate::query_plan::error::{QueryPlanError, Result};
use crate::query_plan::types::{
    IndexSeekType, PlanComparison, PlanNode, PlanNodeType, QueryPlan, StructuralChangeType,
};
use std::collections::HashMap;

/// Compare two query plans and generate a comparison report
pub fn compare_plans(before: &QueryPlan, after: &QueryPlan) -> Result<PlanComparison> {
    // Verify both plans are for the same query
    if before.query_text != after.query_text {
        return Err(QueryPlanError::comparison(format!(
            "Queries do not match: '{}' vs '{}'",
            before.query_text, after.query_text
        )));
    }

    // Calculate cost and time improvements
    let cost_improvement = if before.total_cost > 0.0 {
        ((before.total_cost - after.total_cost) / before.total_cost) * 100.0
    } else {
        0.0
    };

    let time_improvement = if before.total_time_ms > 0.0 && after.total_time_ms > 0.0 {
        ((before.total_time_ms - after.total_time_ms) / before.total_time_ms) * 100.0
    } else {
        0.0
    };

    // Analyze structural changes
    let structural_change = analyze_structural_change(before, after);

    // Detect index usage changes
    let index_changes = detect_index_changes(before, after);

    // Detect join strategy changes
    let join_changes = detect_join_changes(before, after);

    // Generate insights
    let insights = generate_insights(before, after, &index_changes, &join_changes);

    Ok(PlanComparison {
        cost_improvement_pct: cost_improvement,
        time_improvement_pct: time_improvement,
        structural_change,
        index_changes,
        join_changes,
        insights,
    })
}

/// Analyze structural changes between two plans
fn analyze_structural_change(before: &QueryPlan, after: &QueryPlan) -> StructuralChangeType {
    let before_depth = before.depth();
    let after_depth = after.depth();
    let before_nodes = before.node_count();
    let after_nodes = after.node_count();

    if before_depth == after_depth && before_nodes == after_nodes {
        StructuralChangeType::Identical
    } else if after_depth < before_depth || after_nodes < before_nodes {
        StructuralChangeType::Simplified
    } else if after_depth > before_depth || after_nodes > before_nodes {
        StructuralChangeType::Complex
    } else {
        StructuralChangeType::Restructured
    }
}

/// Detect changes in index usage between two plans
fn detect_index_changes(before: &QueryPlan, after: &QueryPlan) -> Vec<crate::query_plan::types::IndexChange> {
    let mut changes = Vec::new();
    let before_indexes = collect_indexes(&before.plan_tree);
    let after_indexes = collect_indexes(&after.plan_tree);

    // Find tables where index usage changed
    let all_tables: std::collections::HashSet<_> =
        before_indexes.keys().chain(after_indexes.keys()).collect();

    for table_name in all_tables {
        let before_info = before_indexes.get(table_name);
        let after_info = after_indexes.get(table_name);

        match (before_info, after_info) {
            (Some(b), Some(a)) => {
                // Index changed
                if b.index_name != a.index_name || b.seek_type != a.seek_type {
                    changes.push(crate::query_plan::types::IndexChange {
                        table_name: table_name.clone(),
                        before_index: Some(b.index_name.clone()),
                        after_index: Some(a.index_name.clone()),
                        before_type: b.seek_type.clone(),
                        after_type: a.seek_type.clone(),
                        impact: assess_change_impact(b, a),
                    });
                }
            }
            (Some(b), None) => {
                // Index no longer used
                changes.push(crate::query_plan::types::IndexChange {
                    table_name: table_name.clone(),
                    before_index: Some(b.index_name.clone()),
                    after_index: None,
                    before_type: b.seek_type.clone(),
                    after_type: IndexSeekType::FullScan,
                    impact: crate::query_plan::types::ChangeImpact::Degraded,
                });
            }
            (None, Some(a)) => {
                // New index introduced
                changes.push(crate::query_plan::types::IndexChange {
                    table_name: table_name.clone(),
                    before_index: None,
                    after_index: Some(a.index_name.clone()),
                    before_type: IndexSeekType::FullScan,
                    after_type: a.seek_type.clone(),
                    impact: crate::query_plan::types::ChangeImpact::Improved,
                });
            }
            (None, None) => {}
        }
    }

    changes
}

/// Collect index information by table name from a plan tree
fn collect_indexes(
    node: &PlanNode,
) -> HashMap<String, &crate::query_plan::types::IndexInfo> {
    let mut indexes = HashMap::new();

    if let Some(ref table) = node.table_info {
        if let Some(ref index) = node.index_info {
            indexes.insert(table.table_name.clone(), index);
        }
    }

    for child in &node.children {
        indexes.extend(collect_indexes(child));
    }

    indexes
}

/// Assess the impact of an index change
fn assess_change_impact(
    before: &crate::query_plan::types::IndexInfo,
    after: &crate::query_plan::types::IndexInfo,
) -> crate::query_plan::types::ChangeImpact {
    // Point lookup is better than range scan
    match (&before.seek_type, &after.seek_type) {
        (_, IndexSeekType::PointLookup) => crate::query_plan::types::ChangeImpact::Improved,
        (IndexSeekType::PointLookup, _) => crate::query_plan::types::ChangeImpact::Degraded,
        (_, IndexSeekType::RangeScan) => crate::query_plan::types::ChangeImpact::Improved,
        (IndexSeekType::RangeScan, _) => crate::query_plan::types::ChangeImpact::Degraded,
        _ => crate::query_plan::types::ChangeImpact::Neutral,
    }
}

/// Detect changes in join strategies between two plans
fn detect_join_changes(before: &QueryPlan, after: &QueryPlan) -> Vec<crate::query_plan::types::JoinChange> {
    let mut changes = Vec::new();
    let before_joins = collect_joins(&before.plan_tree);
    let after_joins = collect_joins(&after.plan_tree);

    // Match joins by position and compare
    let max_joins = before_joins.len().max(after_joins.len());

    for i in 0..max_joins {
        let before_join = before_joins.get(i);
        let after_join = after_joins.get(i);

        match (before_join, after_join) {
            (Some(b), Some(a)) => {
                if b != a {
                    changes.push(crate::query_plan::types::JoinChange {
                        position: i as u32,
                        before_strategy: b.clone(),
                        after_strategy: a.clone(),
                        impact: assess_join_change_impact(b.clone(), a.clone()),
                    });
                }
            }
            (Some(b), None) => {
                changes.push(crate::query_plan::types::JoinChange {
                    position: i as u32,
                    before_strategy: b.clone(),
                    after_strategy: b.clone(),
                    impact: crate::query_plan::types::ChangeImpact::Neutral,
                });
            }
            (None, Some(a)) => {
                changes.push(crate::query_plan::types::JoinChange {
                    position: i as u32,
                    before_strategy: a.clone(),
                    after_strategy: a.clone(),
                    impact: crate::query_plan::types::ChangeImpact::Neutral,
                });
            }
            (None, None) => {}
        }
    }

    changes
}

/// Collect join strategies from a plan tree in order
fn collect_joins(node: &PlanNode) -> Vec<PlanNodeType> {
    let mut joins = Vec::new();

    if matches!(
        node.node_type,
        PlanNodeType::NestedLoopJoin | PlanNodeType::HashJoin | PlanNodeType::MergeJoin
    ) {
        joins.push(node.node_type.clone());
    }

    for child in &node.children {
        joins.extend(collect_joins(child));
    }

    joins
}

/// Assess the impact of a join strategy change
fn assess_join_change_impact(
    before: PlanNodeType,
    after: PlanNodeType,
) -> crate::query_plan::types::ChangeImpact {
    // Hash join is generally better than nested loop for large datasets
    match (before, after) {
        (_, PlanNodeType::HashJoin) => crate::query_plan::types::ChangeImpact::Improved,
        (PlanNodeType::HashJoin, _) => crate::query_plan::types::ChangeImpact::Degraded,
        (_, PlanNodeType::MergeJoin) => crate::query_plan::types::ChangeImpact::Improved,
        (PlanNodeType::MergeJoin, _) => crate::query_plan::types::ChangeImpact::Degraded,
        _ => crate::query_plan::types::ChangeImpact::Neutral,
    }
}

/// Generate human-readable insights about plan changes
fn generate_insights(
    before: &QueryPlan,
    after: &QueryPlan,
    index_changes: &[crate::query_plan::types::IndexChange],
    join_changes: &[crate::query_plan::types::JoinChange],
) -> Vec<String> {
    let mut insights = Vec::new();

    // Cost improvement insight
    let cost_improvement = ((before.total_cost - after.total_cost) / before.total_cost) * 100.0;
    if cost_improvement > 10.0 {
        insights.push(format!(
            "Cost reduced by {:.1}% ({:.2} -> {:.2})",
            cost_improvement, before.total_cost, after.total_cost
        ));
    } else if cost_improvement < -10.0 {
        insights.push(format!(
            "Cost increased by {:.1}% ({:.2} -> {:.2})",
            -cost_improvement, before.total_cost, after.total_cost
        ));
    }

    // Time improvement insight
    if before.total_time_ms > 0.0 && after.total_time_ms > 0.0 {
        let time_improvement =
            ((before.total_time_ms - after.total_time_ms) / before.total_time_ms) * 100.0;
        if time_improvement > 10.0 {
            insights.push(format!(
                "Execution time improved by {:.1}% ({:.2}ms -> {:.2}ms)",
                time_improvement, before.total_time_ms, after.total_time_ms
            ));
        } else if time_improvement < -10.0 {
            insights.push(format!(
                "Execution time degraded by {:.1}% ({:.2}ms -> {:.2}ms)",
                -time_improvement, before.total_time_ms, after.total_time_ms
            ));
        }
    }

    // Plan structure insight
    if before.depth() != after.depth() {
        let diff = after.depth() as i32 - before.depth() as i32;
        if diff < 0 {
            insights.push(format!("Plan depth reduced by {} levels", -diff));
        } else {
            insights.push(format!("Plan depth increased by {} levels", diff));
        }
    }

    if before.node_count() != after.node_count() {
        let diff = after.node_count() as i32 - before.node_count() as i32;
        if diff < 0 {
            insights.push(format!("Plan simplified: {} fewer nodes", -diff));
        } else {
            insights.push(format!("Plan complexity increased: {} more nodes", diff));
        }
    }

    // Index change insights
    for change in index_changes {
        match (&change.before_index, &change.after_index) {
            (Some(b), Some(a)) => {
                insights.push(format!(
                    "Index on '{}' changed from {} ({}) to {} ({})",
                    change.table_name, b, change.before_type, a, change.after_type
                ));
            }
            (None, Some(a)) => {
                insights.push(format!(
                    "New index '{}' ({}) introduced on '{}'",
                    a, change.after_type, change.table_name
                ));
            }
            (Some(b), None) => {
                insights.push(format!(
                    "Index '{}' ({}) on '{}' is no longer used",
                    b, change.before_type, change.table_name
                ));
            }
            (None, None) => {}
        }
    }

    // Join change insights
    for change in join_changes {
        if change.before_strategy != change.after_strategy {
            insights.push(format!(
                "Join strategy at position {} changed from {} to {}",
                change.position, change.before_strategy, change.after_strategy
            ));
        }
    }

    insights
}

/// Find the most expensive node according to a specific metric
pub fn find_most_expensive_node<'a>(
    plan: &'a QueryPlan,
    metric: &crate::query_plan::types::CostMetric,
) -> Option<&'a PlanNode> {
    find_most_expensive_node_recursive(&plan.plan_tree, metric)
}

/// Recursive helper to find the most expensive node
fn find_most_expensive_node_recursive<'a>(
    node: &'a PlanNode,
    metric: &crate::query_plan::types::CostMetric,
) -> Option<&'a PlanNode> {
    let mut most_expensive = node;
    let mut max_value = get_metric_value(node, metric);

    for child in &node.children {
        if let Some(child_most) = find_most_expensive_node_recursive(child, metric) {
            let child_value = get_metric_value(child_most, metric);
            if child_value > max_value {
                max_value = child_value;
                most_expensive = child_most;
            }
        }
    }

    if max_value > 0.0 {
        Some(most_expensive)
    } else {
        None
    }
}

/// Get the value of a specific metric for a node
fn get_metric_value(node: &PlanNode, metric: &crate::query_plan::types::CostMetric) -> f64 {
    match metric {
        crate::query_plan::types::CostMetric::ExecutionTime => node.actual_metrics.execution_time_ms,
        crate::query_plan::types::CostMetric::CpuTime => node.actual_metrics.cpu_time_ms,
        crate::query_plan::types::CostMetric::BlocksRead => node.actual_metrics.blocks_read as f64,
        crate::query_plan::types::CostMetric::RowsRead => node.actual_metrics.rows_read as f64,
        crate::query_plan::types::CostMetric::MemoryBytes => node.actual_metrics.memory_bytes as f64,
    }
}

/// Calculate the maximum depth of a query plan
pub fn calculate_plan_depth(plan: &QueryPlan) -> u32 {
    plan.depth()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query_plan::types::{
        ExecutionMetrics, IndexInfo, IndexSeekType, IndexType, JoinChange, PlanNode, PlanType,
        QueryPlan, TableInfo, TableType,
    };

    fn create_simple_plan() -> QueryPlan {
        let scan = PlanNode::new(1, PlanNodeType::TableScan, 1000.0)
            .with_table_info(TableInfo::new("users".to_string(), TableType::BTree, 100000))
            .with_metrics(ExecutionMetrics {
                rows_produced: 100000,
                rows_read: 100000,
                execution_time_ms: 45.0,
                ..Default::default()
            });

        QueryPlan::new(
            1,
            "SELECT * FROM users".to_string(),
            scan,
            PlanType::Actual,
        )
        .with_execution_time(45.0)
    }

    fn create_optimized_plan() -> QueryPlan {
        let index_info = IndexInfo::new(
            "idx_users_age".to_string(),
            IndexType::BTree,
            vec!["age".to_string()],
        )
        .with_seek_type(IndexSeekType::RangeScan)
        .with_estimated_rows(50000);

        let scan = PlanNode::new(1, PlanNodeType::IndexScan, 500.0)
            .with_table_info(TableInfo::new("users".to_string(), TableType::BTree, 100000))
            .with_index_info(index_info)
            .with_metrics(ExecutionMetrics {
                rows_produced: 50000,
                rows_read: 50000,
                execution_time_ms: 20.0,
                ..Default::default()
            });

        QueryPlan::new(
            2,
            "SELECT * FROM users".to_string(),
            scan,
            PlanType::Actual,
        )
        .with_execution_time(20.0)
    }

    #[test]
    fn test_compare_plans_cost_improvement() {
        let before = create_simple_plan();
        let after = create_optimized_plan();

        let comparison = compare_plans(&before, &after).unwrap();

        assert!(comparison.cost_improvement_pct > 40.0);
        assert!(comparison.time_improvement_pct > 40.0);
    }

    #[test]
    fn test_compare_plans_different_queries() {
        let before = create_simple_plan();
        let after = QueryPlan::new(
            2,
            "SELECT * FROM products".to_string(),
            before.plan_tree.clone(),
            PlanType::Estimated,
        );

        let result = compare_plans(&before, &after);
        assert!(result.is_err());
    }

    #[test]
    fn test_find_most_expensive_node() {
        let plan = create_simple_plan();

        let metric = crate::query_plan::types::CostMetric::ExecutionTime;
        let most_expensive = find_most_expensive_node(&plan, &metric);

        assert!(most_expensive.is_some());
        assert_eq!(most_expensive.unwrap().node_type, PlanNodeType::TableScan);
    }

    #[test]
    fn test_calculate_plan_depth() {
        let plan = create_simple_plan();
        assert_eq!(calculate_plan_depth(&plan), 1);
    }

    #[test]
    fn test_index_changes_detection() {
        let before = create_simple_plan();
        let after = create_optimized_plan();

        let comparison = compare_plans(&before, &after).unwrap();

        assert!(!comparison.index_changes.is_empty());
        assert_eq!(comparison.index_changes[0].table_name, "users");
    }

    #[test]
    fn test_insights_generation() {
        let before = create_simple_plan();
        let after = create_optimized_plan();

        let comparison = compare_plans(&before, &after).unwrap();

        assert!(!comparison.insights.is_empty());
        assert!(comparison
            .insights
            .iter()
            .any(|i| i.contains("Cost reduced") || i.contains("Execution time improved")));
    }

    #[test]
    fn test_structural_change_analysis() {
        let before = create_simple_plan();
        let after = create_optimized_plan();

        let comparison = compare_plans(&before, &after).unwrap();

        // Same structure, just different node type
        assert_eq!(
            comparison.structural_change,
            StructuralChangeType::Identical
        );
    }
}
