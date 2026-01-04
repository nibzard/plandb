//! Optimization Suggester
//!
//! This module provides functionality to generate optimization suggestions
//! based on hot path analysis.

use super::types::*;
use super::error::{HotPathError, HotPathResult};

/// Generate optimization suggestions based on hot path analysis.
///
/// # Arguments
/// * `report` - Hot path report containing identified hot spots
///
/// # Returns
/// Vector of optimization opportunities with actionable suggestions
pub fn suggest_optimizations(report: &HotPathReport) -> Vec<OptimizationOpportunity> {
    let mut opportunities: Vec<OptimizationOpportunity> = Vec::new();
    let mut next_id = 1u64;

    // Analyze hot queries for missing index opportunities
    for query in &report.hot_queries {
        if let Some(opp) = suggest_index_for_query(query, next_id) {
            opportunities.push(opp);
            next_id += 1;
        }
    }

    // Analyze hot indexes for consolidation opportunities
    for (i, index1) in report.hot_indexes.iter().enumerate() {
        for index2 in report.hot_indexes.iter().skip(i + 1) {
            if index1.table_name == index2.table_name {
                if let Some(opp) = suggest_index_consolidation(index1, index2, next_id) {
                    opportunities.push(opp);
                    next_id += 1;
                }
            }
        }
    }

    // Analyze hot indexes for unused index opportunities
    for index in &report.hot_indexes {
        if index.maintenance_operations > 0 && index.seek_count + index.scan_count == 0 {
            let opp = suggest_drop_unused_index(index, next_id);
            opportunities.push(opp);
            next_id += 1;
        }
    }

    // Analyze hot pages for cache optimization
    for page in &report.hot_pages {
        if page.cache_evictions > page.access_count / 2 {
            let opp = suggest_pin_hot_page(page, next_id);
            opportunities.push(opp);
            next_id += 1;
        }
    }

    // Analyze bottlenecks for remediation opportunities
    for bottleneck in &report.bottlenecks {
        if let Some(opp) = suggest_bottleneck_remediation(bottleneck, next_id) {
            opportunities.push(opp);
            next_id += 1;
        }
    }

    // Analyze hot tables for partitioning opportunities
    for table in &report.hot_tables {
        if table.table_size_bytes > 1024 * 1024 * 1024 && table.access_count > 10000 {
            let opp = suggest_table_partitioning(table, next_id);
            opportunities.push(opp);
            next_id += 1;
        }
    }

    // Sort by estimated benefit
    opportunities.sort_by(|a, b| {
        b.estimated_benefit_pct
            .partial_cmp(&a.estimated_benefit_pct)
            .unwrap()
    });

    opportunities
}

/// Suggest creating an index for a hot query pattern.
fn suggest_index_for_query(query: &HotQuery, id: u64) -> Option<OptimizationOpportunity> {
    // Check if query pattern looks like a point lookup with filter
    let query_lower = query.query_pattern.to_lowercase();

    // Simple heuristics for index opportunities
    let has_where_clause = query_lower.contains("where");
    let has_join = query_lower.contains("join");
    let has_order_by = query_lower.contains("order by");

    if !has_where_clause && !has_join && !has_order_by {
        return None;
    }

    // Estimate benefit based on query patterns
    let estimated_benefit = if has_where_clause {
        calculate_index_benefit(query)
    } else {
        10.0
    };

    // Extract table and column from query pattern (simplified)
    let description = if has_where_clause {
        format!(
            "Query '{}' executes {} times with avg latency {:.1}ms. Consider adding index on filter columns.",
            query.query_pattern, query.execution_count, query.avg_execution_time_ms
        )
    } else {
        format!(
            "Query '{}' executes {} times. Consider optimizing access patterns.",
            query.query_pattern, query.execution_count
        )
    };

    Some(OptimizationOpportunity {
        opportunity_id: id,
        opportunity_type: OptimizationType::CreateIndex,
        title: format!("Add index for hot query pattern"),
        description,
        current_state: format!("Query performs full scan or inefficient lookup"),
        proposed_state: format!("Query uses index for fast point or range lookup"),
        estimated_benefit_pct: estimated_benefit,
        effort_level: EffortLevel::Low,
        risk_level: RiskLevel::Low,
        affected_objects: vec
![query.query_pattern.to_string()],
        implementation_steps: vec
![
            "Identify filter columns in WHERE clause".to_string(),
            "Check existing indexes on those columns".to_string(),
            "Create index if not present".to_string(),
            "Monitor query performance after index creation".to_string(),
        ],
        rollback_plan: "DROP INDEX index_name".to_string(),
    })
}

/// Calculate estimated benefit of adding an index.
fn calculate_index_benefit(query: &HotQuery) -> f64 {
    // Higher benefit for:
    // - High execution frequency
    // - High rows read (table scans)
    // - Low cache hit ratio (inefficient access)

    let frequency_score = (query.execution_count as f64).log10().min(5.0) * 10.0;
    let scan_score = if query.rows_read_total > query.rows_returned_total * 10 {
        30.0
    } else {
        10.0
    };
    let cache_penalty = (1.0 - query.cache_hit_ratio) * 20.0;

    (frequency_score + scan_score + cache_penalty).min(80.0)
}

/// Suggest consolidating overlapping indexes.
fn suggest_index_consolidation(
    index1: &HotIndex,
    index2: &HotIndex,
    id: u64,
) -> Option<OptimizationOpportunity> {
    // Check if indexes share columns
    let mut shared_columns: Vec<&String> = index1
        .indexed_columns
        .iter()
        .filter(|c| index2.indexed_columns.contains(c))
        .collect();

    if shared_columns.is_empty() {
        return None;
    }

    shared_columns.sort();
    shared_columns.dedup();

    let estimated_benefit = ((index1.impact_score + index2.impact_score) / 2.0 * 0.3).min(40.0);

    Some(OptimizationOpportunity {
        opportunity_id: id,
        opportunity_type: OptimizationType::CreateIndex,
        title: format!("Consolidate overlapping indexes on {}", index1.table_name),
        description: format!(
            "Indexes {} and {} on table {} share columns: {:?}. Consider consolidating into a composite index.",
            index1.index_name, index2.index_name, index1.table_name, shared_columns
        ),
        current_state: format!("Multiple indexes with overlapping columns"),
        proposed_state: format!("Single composite index covering all use cases"),
        estimated_benefit_pct: estimated_benefit,
        effort_level: EffortLevel::Medium,
        risk_level: RiskLevel::Medium,
        affected_objects: vec
![
            index1.table_name.clone(),
            index1.index_name.clone(),
            index2.index_name.clone(),
        ],
        implementation_steps: vec
![
            "Analyze query patterns using both indexes".to_string(),
            "Design composite index covering all patterns".to_string(),
            "Create new composite index".to_string(),
            "Verify query performance".to_string(),
            "Drop old indexes".to_string(),
        ],
        rollback_plan: "Recreate original indexes and drop composite index".to_string(),
    })
}

/// Suggest dropping an unused index.
fn suggest_drop_unused_index(index: &HotIndex, id: u64) -> OptimizationOpportunity {
    let estimated_benefit = ((index.maintenance_operations as f64).log10() * 10.0).min(25.0);

    OptimizationOpportunity {
        opportunity_id: id,
        opportunity_type: OptimizationType::DropUnusedIndex,
        title: format!("Drop unused index {}", index.index_name),
        description: format!(
            "Index {} has {} maintenance operations but zero seeks or scans. Consider dropping to reduce overhead.",
            index.index_name, index.maintenance_operations
        ),
        current_state: format!("Index maintained but never used for queries"),
        proposed_state: format!("Index removed, reducing write overhead"),
        estimated_benefit_pct: estimated_benefit,
        effort_level: EffortLevel::Trivial,
        risk_level: RiskLevel::Minimal,
        affected_objects: vec
![index.table_name.clone()
, index.index_name.clone()],
        implementation_steps: vec
![
            "Verify index is not used by any queries".to_string(),
            "Drop index using DROP INDEX".to_string(),
            "Monitor write performance improvement".to_string(),
        ],
        rollback_plan: format!("Recreate index: CREATE INDEX {} ON {} ({})", index.index_name, index.table_name, index.indexed_columns.join(", ")),
    }
}

/// Suggest pinning a hot page in cache.
fn suggest_pin_hot_page(page: &HotPage, id: u64) -> OptimizationOpportunity {
    let estimated_benefit = ((page.cache_evictions as f64).log10() * 15.0).min(30.0);

    OptimizationOpportunity {
        opportunity_id: id,
        opportunity_type: OptimizationType::PinPage,
        title: format!("Pin hot page {} in cache", page.page_id),
        description: format!(
            "Page {} accessed {} times/min with {} evictions. Pinning in cache would reduce I/O.",
            page.page_id, page.access_frequency_per_min as i64, page.cache_evictions
        ),
        current_state: format!("Page frequently evicted and reloaded from disk"),
        proposed_state: format!("Page pinned in buffer pool cache"),
        estimated_benefit_pct: estimated_benefit,
        effort_level: EffortLevel::Trivial,
        risk_level: RiskLevel::Minimal,
        affected_objects: vec
![format!("{}:{}", page.table_name, page.page_id)]
,
        implementation_steps: vec
![
            format!("Add page {} to pin list in configuration", page.page_id),
            "Reload database configuration".to_string(),
            "Monitor cache hit ratio improvement".to_string(),
        ],
        rollback_plan: "Remove page from pin list and reload configuration".to_string(),
    }
}

/// Suggest remediation for a bottleneck.
fn suggest_bottleneck_remediation(
    bottleneck: &Bottleneck,
    id: u64,
) -> Option<OptimizationOpportunity> {
    let (op_type, effort, risk) = match bottleneck.bottleneck_type {
        BottleneckType::CacheMissRatio => (
            OptimizationType::IncreaseCache,
            EffortLevel::Low,
            RiskLevel::Minimal,
        ),
        BottleneckType::TableScan | BottleneckType::MissingIndex => (
            OptimizationType::CreateIndex,
            EffortLevel::Low,
            RiskLevel::Low,
        ),
        BottleneckType::FragmentedIndex => (
            OptimizationType::RebuildIndex,
            EffortLevel::Low,
            RiskLevel::Low,
        ),
        BottleneckType::WriteLogFlush => (
            OptimizationType::TuneLocks,
            EffortLevel::Low,
            RiskLevel::Low,
        ),
        _ => return None,
    };

    let estimated_benefit = bottleneck.excess_pct.min(60.0);

    Some(OptimizationOpportunity {
        opportunity_id: id,
        opportunity_type: op_type,
        title: format!("Resolve {}: {}", bottleneck.bottleneck_type, bottleneck.affected_component),
        description: format!(
            "{}: {}",
            bottleneck.description, bottleneck.suggested_remediation
        ),
        current_state: format!("{:.1}% above threshold", bottleneck.excess_pct),
        proposed_state: format!("Within normal thresholds"),
        estimated_benefit_pct: estimated_benefit,
        effort_level: effort,
        risk_level: risk,
        affected_objects: bottleneck.affected_queries.clone(),
        implementation_steps: if bottleneck.can_auto_remediate {
            vec
![format!("Apply recommended remediation: {}", bottleneck.suggested_remediation)
]
        } else {
            vec
![
                "Review bottleneck details".to_string(),
                format!("Implement: {}", bottleneck.suggested_remediation),
                "Monitor metrics after implementation".to_string(),
            ]
        },
        rollback_plan: "Revert configuration changes if performance degrades".to_string(),
    })
}

/// Suggest partitioning a large hot table.
fn suggest_table_partitioning(table: &HotTable, id: u64) -> OptimizationOpportunity {
    let estimated_benefit = ((table.table_size_bytes as f64).log10() * 8.0).min(50.0);

    OptimizationOpportunity {
        opportunity_id: id,
        opportunity_type: OptimizationType::PartitionTable,
        title: format!("Consider partitioning large table {}", table.table_name),
        description: format!(
            "Table {} is {}MB with {} accesses. Partitioning could improve query performance and maintenance.",
            table.table_name,
            table.table_size_bytes / (1024 * 1024),
            table.access_count
        ),
        current_state: format!("Large table requiring full scans for many queries"),
        proposed_state: format!("Partitioned table enabling partition pruning"),
        estimated_benefit_pct: estimated_benefit,
        effort_level: EffortLevel::High,
        risk_level: RiskLevel::Medium,
        affected_objects: vec
![table.table_name.clone()
],
        implementation_steps: vec
![
            "Analyze access patterns to determine partition key".to_string(),
            "Choose partition strategy (range, list, hash)".to_string(),
            "Create partitioned table".to_string(),
            "Migrate data from old table".to_string(),
            "Update application queries".to_string(),
            "Drop old table".to_string(),
        ],
        rollback_plan: "Restore from backup or migrate data back to unpartitioned table".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    #[test]
    fn test_benefit_calculation() {
        let query = HotQuery {
            query_pattern: "SELECT * FROM users WHERE email = $LIT".to_string(),
            query_hash: 123,
            execution_count: 10000,
            total_execution_time_ms: 50000.0,
            avg_execution_time_ms: 5.0,
            min_execution_time_ms: 1.0,
            max_execution_time_ms: 20.0,
            p50_execution_time_ms: 4.0,
            p95_execution_time_ms: 10.0,
            p99_execution_time_ms: 15.0,
            rows_returned_total: 10000,
            rows_returned_avg: 1.0,
            rows_read_total: 1000000,
            blocks_read_total: 5000,
            cache_hit_ratio: 0.7,
            first_seen: Utc::now(),
            last_seen: Utc::now(),
            sample_query_text: "SELECT * FROM users WHERE email = 'test@example.com'".to_string(),
            impact_score: 90.0,
        };

        let benefit = calculate_index_benefit(&query);
        // Should calculate benefit based on high frequency, high scan ratio, low cache hit
        assert!(benefit > 30.0);
    }

    #[test]
    fn test_suggest_drop_unused_index() {
        let index = HotIndex {
            index_name: "unused_idx".to_string(),
            table_name: "users".to_string(),
            index_type: IndexType::BTree,
            indexed_columns: vec
!["email".to_string()
],
            seek_count: 0,
            scan_count: 0,
            rows_returned_total: 0,
            index_pages_read: 0,
            index_only_scans: 0,
            avg_seeks_per_scan: 0.0,
            selectivity_avg: 0.0,
            cache_hit_ratio: 0.0,
            index_size_bytes: 1024,
            maintenance_operations: 1000,
            impact_score: 0.0,
        };

        let opp = suggest_drop_unused_index(&index, 1);
        assert_eq!(opp.opportunity_type, OptimizationType::DropUnusedIndex);
        assert_eq!(opp.effort_level, EffortLevel::Trivial);
        assert_eq!(opp.risk_level, RiskLevel::Minimal);
    }

    #[test]
    fn test_suggest_pin_hot_page() {
        let page = HotPage {
            page_id: crate::types::PageId::new(100),
            page_type: PageType::DataPage,
            table_name: "users".to_string(),
            access_count: 1000,
            access_frequency_per_min: 50.0,
            last_access_time: Utc::now(),
            first_access_time: Utc::now(),
            is_currently_cached: false,
            cache_evictions: 600,
            avg_cache_residence_time_ms: 100.0,
            read_contention: 5.0,
            impact_score: 85.0,
        };

        let opp = suggest_pin_hot_page(&page, 1);
        assert_eq!(opp.opportunity_type, OptimizationType::PinPage);
        assert!(opp.description.contains("50"));
    }

    #[test]
    fn test_optimization_validation() {
        let opp = OptimizationOpportunity {
            opportunity_id: 1,
            opportunity_type: OptimizationType::CreateIndex,
            title: "Add index".to_string(),
            description: "Test".to_string(),
            current_state: "Current".to_string(),
            proposed_state: "Proposed".to_string(),
            estimated_benefit_pct: 35.0,
            effort_level: EffortLevel::Low,
            risk_level: RiskLevel::Low,
            affected_objects: vec
!["users".to_string()
],
            implementation_steps: vec
!["Step 1".to_string()
],
            rollback_plan: "DROP INDEX".to_string(),
        };

        assert!(opp.validate().is_ok());
    }

    #[test]
    fn test_benefit_calculation_with_arc() {
        let query = HotQuery {
            query_pattern: "SELECT * FROM users WHERE email = $LIT".to_string(),
            query_hash: 123,
            execution_count: 10000,
            total_execution_time_ms: 50000.0,
            avg_execution_time_ms: 5.0,
            min_execution_time_ms: 1.0,
            max_execution_time_ms: 20.0,
            p50_execution_time_ms: 4.0,
            p95_execution_time_ms: 10.0,
            p99_execution_time_ms: 15.0,
            rows_returned_total: 10000,
            rows_returned_avg: 1.0,
            rows_read_total: 1000000,
            blocks_read_total: 5000,
            cache_hit_ratio: 0.7,
            first_seen: Utc::now(),
            last_seen: Utc::now(),
            sample_query_text: "SELECT * FROM users WHERE email = 'test@example.com'".to_string(),
            impact_score: 90.0,
        };

        let benefit = calculate_index_benefit(&query);
        // Should calculate benefit based on high frequency, high scan ratio, low cache hit
        assert!(benefit > 30.0);
    }
}
