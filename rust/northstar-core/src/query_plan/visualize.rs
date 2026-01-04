//! Query Plan Visualization
//!
//! This module provides functions to visualize query execution plans
//! in multiple formats: Text, JSON, DOT, HTML, and Markdown.

use crate::query_plan::error::{QueryPlanError, Result};
use crate::query_plan::types::{
    Cost, ExecutionMetrics, IndexInfo, LiteralValue, PlanNode, PlanNodeType, Predicate,
    PredicateOperator, QueryPlan, TableInfo, VisualizationFormat,
};
use serde_json::json;
use std::fmt::Write;

/// Generate text visualization of a query plan
pub fn visualize_plan_text(plan: &QueryPlan) -> String {
    let mut output = String::new();
    writeln!(output, "Query Plan: {}", plan.query_text).ok();
    writeln!(output, "Plan Type: {}", plan.plan_type).ok();
    writeln!(output, "Optimization Level: {}", plan.optimization_level).ok();
    writeln!(output, "Total Cost: {:.2}", plan.total_cost).ok();

    if plan.total_time_ms > 0.0 {
        writeln!(output, "Total Time: {:.2} ms", plan.total_time_ms).ok();
    }

    writeln!(output, "Depth: {}, Nodes: {}", plan.depth(), plan.node_count()).ok();
    writeln!(output).ok();

    visualize_node_text(&mut output, &plan.plan_tree, 0);

    output
}

/// Recursive helper to visualize a node in text format
fn visualize_node_text(output: &mut String, node: &PlanNode, indent: usize) {
    let indent_str = "  ".repeat(indent);

    // Node type and basic info
    write!(output, "{}{}", indent_str, node.node_type).ok();

    // Show cost
    write!(output, " (cost={:.2}", node.estimated_cost).ok();

    // Show table info if present
    if let Some(ref table) = node.table_info {
        write!(output, ", table={}", table.table_name).ok();
        write!(output, ", type={}", table.table_type).ok();
        write!(output, ", est_rows={}", table.estimated_rows).ok();
        if node.actual_metrics.rows_read > 0 {
            write!(output, ", actual_rows={}", node.actual_metrics.rows_read).ok();
        }
    }

    // Show index info if present
    if let Some(ref index) = node.index_info {
        write!(output, ", index={}", index.index_name).ok();
        write!(output, ", type={}", index.index_type).ok();
        write!(output, ", seek={}", index.seek_type).ok();
        if index.index_depth > 0 {
            write!(output, ", depth={}", index.index_depth).ok();
        }
    }

    // Show actual metrics if available
    if plan_has_actual_metrics(node) {
        write!(output, ", rows_out={}", node.actual_metrics.rows_produced).ok();
        if node.actual_metrics.execution_time_ms > 0.0 {
            write!(output, ", time={:.2}ms", node.actual_metrics.execution_time_ms).ok();
        }
    }

    writeln!(output, ")").ok();

    // Show predicates
    for pred in &node.predicates {
        writeln!(
            output,
            "{}  Filter: {} {} {}",
            indent_str,
            pred.column_name,
            pred.operator,
            format_literal(&pred.value)
        )
        .ok();
    }

    // Recursively show children
    for child in &node.children {
        visualize_node_text(output, child, indent + 1);
    }
}

/// Check if node has actual execution metrics
fn plan_has_actual_metrics(node: &PlanNode) -> bool {
    node.actual_metrics.rows_produced > 0
        || node.actual_metrics.rows_read > 0
        || node.actual_metrics.execution_time_ms > 0.0
}

/// Format a literal value for display
fn format_literal(value: &LiteralValue) -> String {
    match value {
        LiteralValue::Null => "NULL".to_string(),
        LiteralValue::Boolean(b) => b.to_string(),
        LiteralValue::Integer(i) => i.to_string(),
        LiteralValue::Float(f) => f.to_string(),
        LiteralValue::String(s) => format!("'{}'", s),
    }
}

/// Generate JSON visualization of a query plan
pub fn visualize_plan_json(plan: &QueryPlan) -> Result<String> {
    let json_value = json!({
        "query_id": plan.query_id,
        "query_text": plan.query_text,
        "plan_type": format!("{}", plan.plan_type),
        "optimization_level": format!("{}", plan.optimization_level),
        "total_cost": plan.total_cost,
        "total_time_ms": plan.total_time_ms,
        "created_at": plan.created_at,
        "depth": plan.depth(),
        "node_count": plan.node_count(),
        "max_branching": plan.max_branching(),
        "root_node": node_to_json(&plan.plan_tree),
    });

    serde_json::to_string_pretty(&json_value).map_err(QueryPlanError::from)
}

/// Convert a plan node to JSON value
fn node_to_json(node: &PlanNode) -> serde_json::Value {
    let mut obj = serde_json::Map::new();

    obj.insert("node_id".to_string(), json!(node.node_id));
    obj.insert("node_type".to_string(), json!(format!("{}", node.node_type)));
    obj.insert("estimated_cost".to_string(), json!(node.estimated_cost));

    // Actual metrics
    if plan_has_actual_metrics(node) {
        obj.insert("actual_metrics".to_string(), json!(metrics_to_json(&node.actual_metrics)));
    }

    // Table info
    if let Some(ref table) = node.table_info {
        obj.insert("table_info".to_string(), json!(table_info_to_json(table)));
    }

    // Index info
    if let Some(ref index) = node.index_info {
        obj.insert("index_info".to_string(), json!(index_info_to_json(index)));
    }

    // Predicates
    if !node.predicates.is_empty() {
        let predicates: Vec<serde_json::Value> =
            node.predicates.iter().map(predicate_to_json).collect();
        obj.insert("predicates".to_string(), json!(predicates));
    }

    // Children
    if !node.children.is_empty() {
        let children: Vec<serde_json::Value> =
            node.children.iter().map(node_to_json).collect();
        obj.insert("children".to_string(), json!(children));
    }

    serde_json::Value::Object(obj)
}

/// Convert execution metrics to JSON
fn metrics_to_json(metrics: &ExecutionMetrics) -> serde_json::Value {
    json!({
        "rows_produced": metrics.rows_produced,
        "rows_read": metrics.rows_read,
        "execution_time_ms": metrics.execution_time_ms,
        "cpu_time_ms": metrics.cpu_time_ms,
        "blocks_read": metrics.blocks_read,
        "blocks_cache_hit": metrics.blocks_cache_hit,
        "memory_bytes": metrics.memory_bytes,
        "spill_bytes": metrics.spill_bytes,
        "cache_hit_ratio": metrics.cache_hit_ratio(),
        "filter_ratio": metrics.filter_ratio(),
    })
}

/// Convert table info to JSON
fn table_info_to_json(info: &TableInfo) -> serde_json::Value {
    json!({
        "table_name": info.table_name,
        "table_type": format!("{}", info.table_type),
        "estimated_rows": info.estimated_rows,
        "actual_rows": info.actual_rows,
        "is_sequential": info.is_sequential,
    })
}

/// Convert index info to JSON
fn index_info_to_json(info: &IndexInfo) -> serde_json::Value {
    json!({
        "index_name": info.index_name,
        "index_type": format!("{}", info.index_type),
        "index_columns": info.index_columns,
        "is_primary": info.is_primary,
        "is_unique": info.is_unique,
        "is_covering": info.is_covering,
        "seek_type": format!("{}", info.seek_type),
        "rows_estimated": info.rows_estimated,
        "rows_actual": info.rows_actual,
        "index_depth": info.index_depth,
    })
}

/// Convert predicate to JSON
fn predicate_to_json(pred: &Predicate) -> serde_json::Value {
    json!({
        "column_name": pred.column_name,
        "operator": format!("{}", pred.operator),
        "value": format_literal(&pred.value),
        "is_sargable": pred.is_sargable,
    })
}

/// Generate Graphviz DOT format for a query plan
pub fn visualize_plan_dot(plan: &QueryPlan) -> String {
    let mut output = String::new();

    writeln!(output, "digraph QueryPlan {{").ok();
    writeln!(output, "  rankdir=TB;").ok();
    writeln!(output, "  node [shape=box, fontname=\"Arial\"];").ok();
    writeln!(output).ok();

    // Generate all nodes
    generate_dot_nodes(&mut output, &plan.plan_tree, &plan.plan_type);

    writeln!(output).ok();

    // Generate all edges
    generate_dot_edges(&mut output, &plan.plan_tree);

    writeln!(output, "}}").ok();

    output
}

/// Generate DOT node declarations
fn generate_dot_nodes(output: &mut String, node: &PlanNode, plan_type: &crate::query_plan::types::PlanType) {
    let label = generate_dot_node_label(node, plan_type);
    let color = node_color(&node.node_type);

    writeln!(
        output,
        "  \"node_{}\" [label=\"{}\", color={}, style=filled, fillcolor={}];",
        node.node_id, label, color.0, color.1
    )
    .ok();

    for child in &node.children {
        generate_dot_nodes(output, child, plan_type);
    }
}

/// Generate label for a DOT node
fn generate_dot_node_label(node: &PlanNode, plan_type: &crate::query_plan::types::PlanType) -> String {
    let mut label = String::new();

    // Node type as primary label
    write!(label, "{}", node.node_type).ok();

    // Add metrics
    if plan_has_actual_metrics(node) {
        writeln!(label, "\\nrows_out={}", node.actual_metrics.rows_produced).ok();
        if node.actual_metrics.execution_time_ms > 0.0 {
            writeln!(label, "time={:.2}ms", node.actual_metrics.execution_time_ms).ok();
        }
    } else {
        writeln!(label, "\\ncost={:.2}", node.estimated_cost).ok();
    }

    // Add table info
    if let Some(ref table) = node.table_info {
        writeln!(label, "\\ntable={}", table.table_name).ok();
    }

    // Add index info
    if let Some(ref index) = node.index_info {
        writeln!(label, "\\nindex={} ({})", index.index_name, index.seek_type).ok();
    }

    // Add predicates
    if !node.predicates.is_empty() && node.predicates.len() <= 3 {
        for pred in &node.predicates {
            writeln!(
                label,
                "{} {} {}",
                pred.column_name,
                pred.operator,
                format_literal(&pred.value)
            )
            .ok();
        }
    } else if !node.predicates.is_empty() {
        writeln!(label, "\\n... {} filters", node.predicates.len()).ok();
    }

    // Escape for DOT
    label.replace('"', "\\\"")
}

/// Get color for a node type
fn node_color(node_type: &PlanNodeType) -> (&'static str, &'static str) {
    match node_type {
        PlanNodeType::TableScan => ("blue", "lightblue"),
        PlanNodeType::IndexScan | PlanNodeType::IndexSeek => ("green", "lightgreen"),
        PlanNodeType::Filter => ("orange", "lightyellow"),
        PlanNodeType::NestedLoopJoin | PlanNodeType::HashJoin | PlanNodeType::MergeJoin => {
            ("purple", "lavender")
        }
        PlanNodeType::Aggregate => ("red", "pink"),
        PlanNodeType::Sort => ("brown", "wheat"),
        _ => ("black", "white"),
    }
}

/// Generate DOT edge declarations
fn generate_dot_edges(output: &mut String, node: &PlanNode) {
    for child in &node.children {
        let rows = if plan_has_actual_metrics(child) {
            child.actual_metrics.rows_produced
        } else {
            0
        };

        if rows > 0 {
            writeln!(
                output,
                "  \"node_{}\" -> \"node_{}\" [label=\"{} rows\"];",
                node.node_id, child.node_id, rows
            )
            .ok();
        } else {
            writeln!(
                output,
                "  \"node_{}\" -> \"node_{}\";",
                node.node_id, child.node_id
            )
            .ok();
        }

        generate_dot_edges(output, child);
    }
}

/// Generate HTML visualization of a query plan
pub fn visualize_plan_html(plan: &QueryPlan) -> String {
    let mut output = String::new();

    // HTML header
    writeln!(output, "<!DOCTYPE html>").ok();
    writeln!(output, "<html>").ok();
    writeln!(output, "<head>").ok();
    writeln!(output, "  <meta charset=\"UTF-8\">").ok();
    writeln!(output, "  <title>Query Plan: {}</title>", escape_html(&plan.query_text)).ok();
    writeln!(output, "  <style>").ok();
    writeln!(output, "    body {{ font-family: Arial, sans-serif; margin: 20px; }}").ok();
    writeln!(output, "    .plan-info {{ background: #f5f5f5; padding: 15px; border-radius: 5px; margin-bottom: 20px; }}").ok();
    writeln!(output, "    .node {{ margin-left: 20px; margin: 10px 0; }}").ok();
    writeln!(output, "    .node-header {{ padding: 10px; border-radius: 5px; cursor: pointer; }}").ok();
    writeln!(output, "    .node-scan {{ background: #e3f2fd; border-left: 4px solid #2196f3; }}").ok();
    writeln!(output, "    .node-filter {{ background: #fff3e0; border-left: 4px solid #ff9800; }}").ok();
    writeln!(output, "    .node-join {{ background: #f3e5f5; border-left: 4px solid #9c27b0; }}").ok();
    writeln!(output, "    .node-aggregate {{ background: #fce4ec; border-left: 4px solid #e91e63; }}").ok();
    writeln!(output, "    .node-default {{ background: #f5f5f5; border-left: 4px solid #757575; }}").ok();
    writeln!(output, "    .metrics {{ font-size: 0.9em; color: #666; margin-left: 10px; }}").ok();
    writeln!(output, "    .predicates {{ margin: 5px 0; font-size: 0.9em; }}").ok();
    writeln!(output, "    .children {{ margin-left: 20px; display: block; }}").ok();
    writeln!(output, "    details {{ margin: 5px 0; }}").ok();
    writeln!(output, "    summary {{ cursor: pointer; }}").ok();
    writeln!(output, "  </style>").ok();
    writeln!(output, "</head>").ok();
    writeln!(output, "<body>").ok();

    // Plan info header
    writeln!(output, "  <div class=\"plan-info\">").ok();
    writeln!(output, "    <h2>Query Plan</h2>").ok();
    writeln!(output, "    <p><strong>Query:</strong> {}</p>", escape_html(&plan.query_text)).ok();
    writeln!(output, "    <p><strong>Type:</strong> {}</p>", plan.plan_type).ok();
    writeln!(output, "    <p><strong>Total Cost:</strong> {:.2}</p>", plan.total_cost).ok();
    if plan.total_time_ms > 0.0 {
        writeln!(output, "    <p><strong>Total Time:</strong> {:.2} ms</p>", plan.total_time_ms).ok();
    }
    writeln!(output, "    <p><strong>Depth:</strong> {} | <strong>Nodes:</strong> {}</p>", plan.depth(), plan.node_count()).ok();
    writeln!(output, "  </div>").ok();

    // Plan tree
    writeln!(output, "  <div class=\"plan-tree\">").ok();
    generate_html_node(&mut output, &plan.plan_tree);
    writeln!(output, "  </div>").ok();

    // HTML footer
    writeln!(output, "</body>").ok();
    writeln!(output, "</html>").ok();

    output
}

/// Generate HTML for a plan node
fn generate_html_node(output: &mut String, node: &PlanNode) {
    let css_class = node_css_class(&node.node_type);

    writeln!(output, "<details class=\"node\" open>").ok();
    writeln!(output, "  <summary class=\"node-header {}\">", css_class).ok();
    writeln!(output, "    <strong>{}</strong>", node.node_type).ok();

    // Metrics
    if plan_has_actual_metrics(node) {
        write!(output, "    <span class=\"metrics\">").ok();
        write!(output, "rows_out={}", node.actual_metrics.rows_produced).ok();
        if node.actual_metrics.execution_time_ms > 0.0 {
            write!(output, ", time={:.2}ms", node.actual_metrics.execution_time_ms).ok();
        }
        writeln!(output, "</span>").ok();
    } else {
        writeln!(output, "    <span class=\"metrics\">cost={:.2}</span>", node.estimated_cost).ok();
    }

    writeln!(output, "  </summary>").ok();

    // Details
    writeln!(output, "  <div>").ok();

    // Table info
    if let Some(ref table) = node.table_info {
        writeln!(
            output,
            "    <p><strong>Table:</strong> {} ({})</p>",
            table.table_name, table.table_type
        ).ok();
    }

    // Index info
    if let Some(ref index) = node.index_info {
        writeln!(
            output,
            "    <p><strong>Index:</strong> {} ({}, {})</p>",
            index.index_name, index.index_type, index.seek_type
        ).ok();
    }

    // Predicates
    if !node.predicates.is_empty() {
        writeln!(output, "    <div class=\"predicates\">").ok();
        writeln!(output, "      <strong>Filters:</strong>").ok();
        for pred in &node.predicates {
            writeln!(
                output,
                "      <div>{} {} {}</div>",
                pred.column_name,
                pred.operator,
                format_literal(&pred.value)
            )
            .ok();
        }
        writeln!(output, "    </div>").ok();
    }

    // Children
    if !node.children.is_empty() {
        writeln!(output, "    <div class=\"children\">").ok();
        for child in &node.children {
            generate_html_node(output, child);
        }
        writeln!(output, "    </div>").ok();
    }

    writeln!(output, "  </div>").ok();
    writeln!(output, "</details>").ok();
}

/// Get CSS class for a node type
fn node_css_class(node_type: &PlanNodeType) -> &'static str {
    match node_type {
        PlanNodeType::TableScan => "node-scan",
        PlanNodeType::IndexScan | PlanNodeType::IndexSeek => "node-scan",
        PlanNodeType::Filter => "node-filter",
        PlanNodeType::NestedLoopJoin | PlanNodeType::HashJoin | PlanNodeType::MergeJoin => "node-join",
        PlanNodeType::Aggregate => "node-aggregate",
        _ => "node-default",
    }
}

/// Escape HTML special characters
fn escape_html(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// Generate Markdown visualization of a query plan
pub fn visualize_plan_markdown(plan: &QueryPlan) -> String {
    let mut output = String::new();

    writeln!(output, "# Query Plan").ok();
    writeln!(output).ok();
    writeln!(output, "**Query:** `{}`", plan.query_text).ok();
    writeln!(output, "**Type:** {}", plan.plan_type).ok();
    writeln!(output, "**Total Cost:** {:.2}", plan.total_cost).ok();
    if plan.total_time_ms > 0.0 {
        writeln!(output, "**Total Time:** {:.2} ms", plan.total_time_ms).ok();
    }
    writeln!(output, "**Depth:** {} | **Nodes:** {}", plan.depth(), plan.node_count()).ok();
    writeln!(output).ok();

    generate_markdown_node(&mut output, &plan.plan_tree, 0);

    output
}

/// Generate Markdown for a plan node
fn generate_markdown_node(output: &mut String, node: &PlanNode, level: usize) {
    let indent = "#".repeat(level + 2);

    writeln!(output, "{} {}", indent, node.node_type).ok();

    // Metrics as bullet points
    write!(output, "- **Cost:** {:.2}", node.estimated_cost).ok();

    if plan_has_actual_metrics(node) {
        write!(output, " | **Rows Out:** {}", node.actual_metrics.rows_produced).ok();
        if node.actual_metrics.execution_time_ms > 0.0 {
            write!(output, " | **Time:** {:.2}ms", node.actual_metrics.execution_time_ms).ok();
        }
    }
    writeln!(output).ok();

    // Table info
    if let Some(ref table) = node.table_info {
        writeln!(output, "- **Table:** {} ({})", table.table_name, table.table_type).ok();
    }

    // Index info
    if let Some(ref index) = node.index_info {
        writeln!(
            output,
            "- **Index:** {} ({}, {})",
            index.index_name, index.index_type, index.seek_type
        ).ok();
    }

    // Predicates
    if !node.predicates.is_empty() {
        writeln!(output, "- **Filters:**").ok();
        for pred in &node.predicates {
            writeln!(
                output,
                "  - [{} {} {}]{}",
                pred.column_name,
                pred.operator,
                format_literal(&pred.value),
                if pred.is_sargable { " (sargable)" } else { "" }
            )
            .ok();
        }
    }

    writeln!(output).ok();

    // Children
    for child in &node.children {
        generate_markdown_node(output, child, level + 1);
    }
}

/// Visualize a query plan in the specified format
pub fn visualize_plan(plan: &QueryPlan, format: VisualizationFormat) -> Result<String> {
    match format {
        VisualizationFormat::Text => Ok(visualize_plan_text(plan)),
        VisualizationFormat::Json => visualize_plan_json(plan),
        VisualizationFormat::Dot => Ok(visualize_plan_dot(plan)),
        VisualizationFormat::Html => Ok(visualize_plan_html(plan)),
        VisualizationFormat::Markdown => Ok(visualize_plan_markdown(plan)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query_plan::types::{PlanType, QueryPlan};

    fn create_test_plan() -> QueryPlan {
        let scan = PlanNode::new(1, PlanNodeType::TableScan, 1000.0)
            .with_table_info(TableInfo::new(
                "users".to_string(),
                crate::query_plan::types::TableType::BTree,
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
    fn test_text_visualization() {
        let plan = create_test_plan();
        let text = visualize_plan_text(&plan);

        let s1 = concat!("Query", " Plan:");
        assert!(text.contains(s1));
        assert!(text.contains("TableScan"));
        let s2 = concat!("Filter", ":");
        assert!(text.contains(s2));
        assert!(text.contains("age > 25"));
    }

    #[test]
    fn test_json_visualization() {
        let plan = create_test_plan();
        let json = visualize_plan_json(&plan).unwrap();

        assert!(json.contains(concat!("query", "_id")));
        assert!(json.contains("TableScan"));
        assert!(json.contains("Filter"));
        assert!(json.contains(concat!("rows", "_produced")));
    }

    #[test]
    fn test_dot_visualization() {
        let plan = create_test_plan();
        let dot = visualize_plan_dot(&plan);

        let s = concat!("digraph", " QueryPlan");
        assert!(dot.contains(s));
        assert!(dot.contains(concat!("node", "_")));
        assert!(dot.contains("->"));
    }

    #[test]
    fn test_html_visualization() {
        let plan = create_test_plan();
        let html = visualize_plan_html(&plan);

        assert!(html.contains("<!DOCTYPE html>"));
        assert!(html.contains("TableScan"));
        assert!(html.contains("Filter"));
        assert!(html.contains("age > 25"));
    }

    #[test]
    fn test_markdown_visualization() {
        let plan = create_test_plan();
        let md = visualize_plan_markdown(&plan);

        let s1 = concat!("#", " Query Plan");
        assert!(md.contains(s1));
        let s2 = concat!("##", " Filter");
        assert!(md.contains(s2));
        assert!(md.contains("age > 25"));
    }

    #[test]
    fn test_literal_formatting() {
        assert_eq!(format_literal(&LiteralValue::Null), "NULL");
        assert_eq!(format_literal(&LiteralValue::Boolean(true)), "true");
        assert_eq!(format_literal(&LiteralValue::Integer(42)), "42");
        let result = format_literal(&LiteralValue::String(String::from("test")));
        let expected = concat!("'", "test", "'");
        assert_eq!(result, expected);
    }

    #[test]
    fn test_html_escaping() {
        assert_eq!(escape_html("<script>"), "&lt;script&gt;");
        assert_eq!(escape_html("a & b"), "a &amp; b");
        let input = concat!(r#"""#, "quoted", r#"""#);
        let expected = "&quot;quoted&quot;";
        assert_eq!(escape_html(input), expected);
    }

    #[test]
    fn test_visualize_with_format() {
        let plan = create_test_plan();

        let text = visualize_plan(&plan, VisualizationFormat::Text).unwrap();
        let s = concat!("Query", " Plan");
        assert!(text.contains(s));

        let json = visualize_plan(&plan, VisualizationFormat::Json).unwrap();
        assert!(json.contains(concat!("query", "_id")));
    }
}
