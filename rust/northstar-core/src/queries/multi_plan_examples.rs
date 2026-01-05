//! Multi-Plan Execution Examples
//!
//! This module demonstrates how to use the multi-plan executor,
//! runtime selection, and budgeting features for Phase 19.

use crate::queries::{
    MultiPlanExecutor, MultiPlanConfig, RuntimePlanSelector, RuntimeSelectionConfig,
    PlanBudgetManager, BudgetAllocation, QueryPlan, QueryOperation,
    PlanLearningEngine, ExecutionHint,
};
use std::sync::Arc;
use std::time::Duration;

/// Example 1: Basic multi-plan execution
///
/// Demonstrates how to execute multiple query plans in parallel
/// and select the best-performing one.
pub async fn example_basic_multi_plan_execution() {
    // Create a plan learning engine
    let learning_engine = Arc::new(PlanLearningEngine::new());

    // Create multi-plan executor with default config
    let executor = MultiPlanExecutor::with_defaults(learning_engine.clone());

    // Create alternative query plans
    let plan1 = QueryPlan {
        intent: crate::queries::QueryIntent::PointLookup,
        operations: vec![
            QueryOperation::PointLookup { key: b"key1".to_vec() },
        ],
        entity_links: std::collections::HashMap::new(),
        estimated_cost: 1.0,
        execution_hint: ExecutionHint::UseIndex {
            index_name: "primary".to_string(),
        },
    };

    let plan2 = QueryPlan {
        intent: crate::queries::QueryIntent::PointLookup,
        operations: vec![
            QueryOperation::RangeScan {
                start: b"key1".to_vec(),
                end: b"key2".to_vec(),
            },
        ],
        entity_links: std::collections::HashMap::new(),
        estimated_cost: 5.0,
        execution_hint: ExecutionHint::UseCache,
    };

    let plans = vec![plan1, plan2];

    // Define executor function
    let executor_func = |plan: QueryPlan| async move {
        // Simulate query execution
        match plan.execution_hint {
            ExecutionHint::UseIndex { .. } => {
                tokio::time::sleep(Duration::from_millis(10)).await;
                Ok(vec![1, 2, 3])
            }
            _ => {
                tokio::time::sleep(Duration::from_millis(50)).await;
                Ok(vec![4, 5, 6])
            }
        }
    };

    // Execute best plan
    match executor.execute_best_plan("query_123".to_string(), plans, executor_func).await {
        Ok(result) => {
            println!("Best plan completed in {:?}", result.metrics.execution_time);
            println!("Rows processed: {}", result.metrics.rows_processed);
        }
        Err(e) => {
            eprintln!("Execution failed: {:?}", e);
        }
    }
}

/// Example 2: Runtime plan selection
///
/// Demonstrates how to use runtime selection to choose
/// the best plan based on historical performance.
pub async fn example_runtime_plan_selection() {
    let learning_engine = Arc::new(PlanLearningEngine::new());
    let selector = RuntimePlanSelector::with_defaults(learning_engine);

    // Create alternative plans
    let plans = vec![
        QueryPlan {
            intent: crate::queries::QueryIntent::RangeScan,
            operations: vec![],
            entity_links: std::collections::HashMap::new(),
            estimated_cost: 10.0,
            execution_hint: ExecutionHint::UseIndex {
                index_name: "idx1".to_string(),
            },
        },
        QueryPlan {
            intent: crate::queries::QueryIntent::RangeScan,
            operations: vec![],
            entity_links: std::collections::HashMap::new(),
            estimated_cost: 20.0,
            execution_hint: ExecutionHint::UseCache,
        },
    ];

    // Select best plan
    match selector.select_best_plan("query_456", plans).await {
        Ok((best_plan, metadata)) => {
            println!("Selected plan index: {}", metadata.selected_plan_index);
            println!("Confidence: {:.2}", metadata.confidence);
            println!("Reason: {:?}", metadata.selection_reason);
        }
        Err(e) => {
            eprintln!("Selection failed: {:?}", e);
        }
    }
}

/// Example 3: Budget allocation and resource management
///
/// Demonstrates how to allocate and manage resources for
/// multi-plan execution.
pub async fn example_budget_allocation() {
    let budget_manager = PlanBudgetManager::with_defaults();

    // Allocate budget for a high-priority query
    match budget_manager.allocate_budget("high_priority_query".to_string(), Some(8)).await {
        Ok(handle) => {
            println!("Allocated budget:");
            println!("  Time: {:?}", handle.allocation().time_budget);
            println!("  Memory: {} bytes", handle.allocation().memory_budget);
            println!("  CPU: {:.1}%", handle.allocation().cpu_quota * 100.0);
            println!("  Priority: {}", handle.allocation().priority);

            // Check resource usage during execution
            let usage = handle.create_tracker();
            let status = handle.check_budget(&usage);

            if status.can_continue {
                println!("Execution within budget");
            } else {
                println!("Budget exceeded!");
            }
        }
        Err(e) => {
            eprintln!("Budget allocation failed: {:?}", e);
        }
    }

    // Check overall utilization
    let utilization = budget_manager.get_utilization().await;
    println!("System utilization:");
    println!("  Memory: {:.1}%", utilization.memory_utilization * 100.0);
    println!("  CPU: {:.1}%", utilization.cpu_utilization * 100.0);
    println!("  Active allocations: {}", utilization.active_allocations);
}

/// Example 4: Custom multi-plan configuration
///
/// Demonstrates how to create custom configurations for
/// different execution scenarios.
pub fn example_custom_configuration() {
    // Conservative configuration (single plan, long timeout)
    let conservative_config = MultiPlanConfig::conservative();

    // Aggressive configuration (max parallelism, short timeout)
    let aggressive_config = MultiPlanConfig::aggressive();

    // Custom configuration
    let custom_config = MultiPlanConfig::new(
        4,                                      // max 4 concurrent plans
        Duration::from_secs(15),                // 15 second timeout
        200 * 1024 * 1024,                      // 200 MB memory
        150,                                    // 150ms cancellation threshold
    );

    println!("Conservative: max_concurrent={}", conservative_config.max_concurrent_plans);
    println!("Aggressive: max_concurrent={}", aggressive_config.max_concurrent_plans);
    println!("Custom: max_concurrent={}", custom_config.max_concurrent_plans);
}

/// Example 5: Integrated multi-plan execution with budgeting
///
/// Demonstrates a complete workflow combining multi-plan execution,
/// runtime selection, and budget management.
pub async fn example_integrated_execution() {
    let learning_engine = Arc::new(PlanLearningEngine::new());
    let selector = RuntimePlanSelector::with_defaults(learning_engine.clone());
    let budget_manager = PlanBudgetManager::with_defaults();

    // Step 1: Allocate budget
    let budget_handle = match budget_manager.allocate_budget("integrated_query".to_string(), Some(7)).await {
        Ok(handle) => handle,
        Err(e) => {
            eprintln!("Failed to allocate budget: {:?}", e);
            return;
        }
    };

    // Step 2: Create alternative plans
    let plans = vec![
        QueryPlan {
            intent: crate::queries::QueryIntent::SemanticSearch,
            operations: vec![],
            entity_links: std::collections::HashMap::new(),
            estimated_cost: 15.0,
            execution_hint: ExecutionHint::Parallelize,
        },
        QueryPlan {
            intent: crate::queries::QueryIntent::SemanticSearch,
            operations: vec![],
            entity_links: std::collections::HashMap::new(),
            estimated_cost: 25.0,
            execution_hint: ExecutionHint::UseCache,
        },
    ];

    // Step 3: Select best plan
    let (best_plan, metadata) = match selector.select_best_plan("integrated_query", plans).await {
        Ok(result) => result,
        Err(e) => {
            eprintln!("Plan selection failed: {:?}", e);
            return;
        }
    };

    println!("Selected plan with confidence: {:.2}", metadata.confidence);

    // Step 4: Execute with monitoring
    let executor = MultiPlanExecutor::with_defaults(learning_engine);
    let executor_func = |plan: QueryPlan| async move {
        // Simulate execution with budget awareness
        tokio::time::sleep(Duration::from_millis(100)).await;
        Ok(vec![1, 2, 3, 4, 5])
    };

    match executor.execute_best_plan("integrated_query".to_string(), vec![best_plan], executor_func).await {
        Ok(result) => {
            println!("Execution completed successfully");
            println!("Time: {:?}", result.metrics.execution_time);
            println!("Memory: {} bytes", result.metrics.memory_used_bytes);
        }
        Err(e) => {
            eprintln!("Execution failed: {:?}", e);
        }
    }

    // Budget is automatically released when budget_handle goes out of scope
}

/// Example 6: Monitoring active executions
///
/// Demonstrates how to monitor and manage active query executions.
pub async fn example_monitoring() {
    let learning_engine = Arc::new(PlanLearningEngine::new());
    let selector = RuntimePlanSelector::with_defaults(learning_engine);

    // Start monitoring a plan
    let plan = QueryPlan {
        intent: crate::queries::QueryIntent::PointLookup,
        operations: vec![],
        entity_links: std::collections::HashMap::new(),
        estimated_cost: 5.0,
        execution_hint: ExecutionHint::UseCache,
    };

    let monitor = match selector.start_monitoring("monitored_query".to_string(), plan).await {
        Ok(m) => m,
        Err(e) => {
            eprintln!("Failed to start monitoring: {:?}", e);
            return;
        }
    };

    // Update progress during execution
    monitor.update_progress(0.5).await.unwrap();

    // Check if execution should continue
    match monitor.should_continue().await {
        Ok(should_continue) => {
            if should_continue {
                println!("Execution progressing normally");
            } else {
                println!("Execution should be abandoned");
            }
        }
        Err(e) => {
            eprintln!("Monitoring check failed: {:?}", e);
        }
    }

    // Complete execution
    // monitor.complete(&result).await.unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_basic_example() {
        // This test demonstrates that the examples compile
        // In real usage, you would call these functions with actual data
        example_custom_configuration();
    }

    #[tokio::test]
    async fn test_budget_allocation() {
        let budget_manager = PlanBudgetManager::with_defaults();
        let handle = budget_manager.allocate_budget("test".to_string(), Some(5)).await;
        assert!(handle.is_ok());
    }

    #[tokio::test]
    async fn test_runtime_selection() {
        let learning_engine = Arc::new(PlanLearningEngine::new());
        let selector = RuntimePlanSelector::with_defaults(learning_engine);

        let plans = vec![
            QueryPlan {
                intent: crate::queries::QueryIntent::PointLookup,
                operations: vec![],
                entity_links: std::collections::HashMap::new(),
                estimated_cost: 1.0,
                execution_hint: ExecutionHint::UseCache,
            },
        ];

        let result = selector.select_best_plan("test", plans).await;
        assert!(result.is_ok());
    }
}
