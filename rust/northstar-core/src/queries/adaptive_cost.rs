//! Adaptive Query Cost Model
//!
//! This module provides an adaptive cost model that learns from actual
//! query execution to improve cost estimates over time. It maintains
//! statistics about plan performance and adjusts cost predictions
//! based on historical data.

use crate::queries::types::{QueryOperation, QueryPlan};
use crate::{Error, Result};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::RwLock;

/// Execution statistics for a query operation
#[derive(Debug, Clone)]
pub struct ExecutionStats {
    /// Operation type identifier
    pub op_type: String,
    /// Actual execution time in milliseconds
    pub actual_time_ms: f64,
    /// Actual rows produced
    pub actual_rows: u64,
    /// Estimated time (from cost model)
    pub estimated_time_ms: f64,
    /// Estimated rows
    pub estimated_rows: u64,
    /// Timestamp of execution
    pub timestamp: SystemTime,
}

impl ExecutionStats {
    /// Calculate prediction error as a percentage
    pub fn prediction_error_pct(&self) -> f64 {
        if self.estimated_time_ms > 0.0 {
            ((self.actual_time_ms - self.estimated_time_ms).abs() / self.estimated_time_ms) * 100.0
        } else {
            0.0
        }
    }

    /// Calculate row estimate error as a percentage
    pub fn row_estimate_error_pct(&self) -> f64 {
        if self.estimated_rows > 0 {
            let actual = self.actual_rows as f64;
            let estimated = self.estimated_rows as f64;
            ((actual - estimated).abs() / estimated) * 100.0
        } else {
            0.0
        }
    }
}

/// Learned cost parameters for an operation type
#[derive(Debug, Clone)]
pub struct LearnedParameters {
    /// Base cost multiplier (learned from execution)
    pub cost_multiplier: f64,
    /// Row estimate adjustment factor
    pub row_adjustment_factor: f64,
    /// Number of samples this is based on
    pub sample_count: u64,
    /// Average prediction error
    pub avg_error_pct: f64,
    /// Confidence score (0-1)
    pub confidence: f64,
}

impl Default for LearnedParameters {
    fn default() -> Self {
        Self {
            cost_multiplier: 1.0,
            row_adjustment_factor: 1.0,
            sample_count: 0,
            avg_error_pct: 0.0,
            confidence: 0.0,
        }
    }
}

/// Adaptive cost model
pub struct AdaptiveCostModel {
    /// Learned parameters per operation type
    learned_params: Arc<RwLock<HashMap<String, LearnedParameters>>>,

    /// Execution history (circular buffer)
    execution_history: Arc<RwLock<Vec<ExecutionStats>>>,

    /// Maximum history size
    max_history_size: usize,

    /// Minimum samples before learning
    min_samples: u64,

    /// Learning rate (0-1, lower = slower adaptation)
    learning_rate: f64,
}

impl AdaptiveCostModel {
    /// Create new adaptive cost model
    pub fn new() -> Self {
        Self {
            learned_params: Arc::new(RwLock::new(HashMap::new())),
            execution_history: Arc::new(RwLock::new(Vec::new())),
            max_history_size: 10_000,
            min_samples: 10,
            learning_rate: 0.1,
        }
    }

    /// Create with custom configuration
    pub fn with_config(
        max_history_size: usize,
        min_samples: u64,
        learning_rate: f64,
    ) -> Self {
        Self {
            learned_params: Arc::new(RwLock::new(HashMap::new())),
            execution_history: Arc::new(RwLock::new(Vec::new())),
            max_history_size,
            min_samples,
            learning_rate: learning_rate.clamp(0.01, 1.0),
        }
    }

    /// Estimate cost using adaptive model
    pub async fn estimate_cost(
        &self,
        operation: &QueryOperation,
        base_cost: f64,
    ) -> Result<f64> {
        let op_type = self.get_operation_type(operation);
        let params = self.learned_params.read().await;

        if let Some(learned) = params.get(&op_type) {
            if learned.sample_count >= self.min_samples && learned.confidence > 0.5 {
                // Use learned parameters
                let adjusted_cost = base_cost * learned.cost_multiplier;
                return Ok(adjusted_cost);
            }
        }

        // Fall back to base cost
        Ok(base_cost)
    }

    /// Estimate row count using adaptive model
    pub async fn estimate_rows(
        &self,
        operation: &QueryOperation,
        base_estimate: u64,
    ) -> Result<u64> {
        let op_type = self.get_operation_type(operation);
        let params = self.learned_params.read().await;

        if let Some(learned) = params.get(&op_type) {
            if learned.sample_count >= self.min_samples && learned.confidence > 0.5 {
                // Use learned adjustment factor
                let adjusted_rows = (base_estimate as f64 * learned.row_adjustment_factor) as u64;
                return Ok(adjusted_rows.max(1));
            }
        }

        Ok(base_estimate)
    }

    /// Record execution statistics
    pub async fn record_execution(&self, stats: ExecutionStats) -> Result<()> {
        let mut history = self.execution_history.write().await;

        // Add to history
        history.push(stats.clone());

        // Trim if necessary
        if history.len() > self.max_history_size {
            history.drain(0..history.len() - self.max_history_size);
        }

        drop(history);

        // Update learned parameters
        self.update_learned_params().await?;

        Ok(())
    }

    /// Update learned parameters from recent history
    async fn update_learned_params(&self) -> Result<()> {
        let history = self.execution_history.read().await;
        let mut params = self.learned_params.write().await;

        // Group by operation type
        let mut grouped: HashMap<String, Vec<&ExecutionStats>> = HashMap::new();
        for stats in history.iter() {
            grouped
                .entry(stats.op_type.clone())
                .or_insert_with(Vec::new)
                .push(stats);
        }

        // Update parameters for each operation type
        for (op_type, executions) in grouped {
            if executions.len() < self.min_samples as usize {
                continue;
            }

            // Calculate average cost multiplier
            let total_cost_mult: f64 = executions
                .iter()
                .map(|e| {
                    if e.estimated_time_ms > 0.0 {
                        e.actual_time_ms / e.estimated_time_ms
                    } else {
                        1.0
                    }
                })
                .sum();

            let avg_cost_mult = total_cost_mult / executions.len() as f64;

            // Calculate average row adjustment factor
            let total_row_adj: f64 = executions
                .iter()
                .map(|e| {
                    if e.estimated_rows > 0 {
                        (e.actual_rows as f64) / (e.estimated_rows as f64)
                    } else {
                        1.0
                    }
                })
                .sum();

            let avg_row_adj = total_row_adj / executions.len() as f64;

            // Calculate average error
            let avg_error: f64 = executions
                .iter()
                .map(|e| e.prediction_error_pct())
                .sum::<f64>() / executions.len() as f64;

            // Calculate confidence (inverse of error, capped)
            let confidence = (100.0 - avg_error.min(99.0)) / 100.0;

            // Get existing parameters or create new
            let existing = params.get(&op_type).cloned().unwrap_or_default();

            // Apply learning rate
            let new_cost_mult = if existing.sample_count > 0 {
                existing.cost_multiplier * (1.0 - self.learning_rate)
                    + avg_cost_mult * self.learning_rate
            } else {
                avg_cost_mult
            };

            let new_row_adj = if existing.sample_count > 0 {
                existing.row_adjustment_factor * (1.0 - self.learning_rate)
                    + avg_row_adj * self.learning_rate
            } else {
                avg_row_adj
            };

            let new_params = LearnedParameters {
                cost_multiplier: new_cost_mult.clamp(0.1, 10.0),
                row_adjustment_factor: new_row_adj.clamp(0.1, 10.0),
                sample_count: existing.sample_count + executions.len() as u64,
                avg_error_pct: if existing.sample_count > 0 {
                    existing.avg_error_pct * (1.0 - self.learning_rate) + avg_error * self.learning_rate
                } else {
                    avg_error
                },
                confidence,
            };

            params.insert(op_type, new_params);
        }

        Ok(())
    }

    /// Get learned parameters for an operation type
    pub async fn get_learned_params(&self, op_type: &str) -> Option<LearnedParameters> {
        let params = self.learned_params.read().await;
        params.get(op_type).cloned()
    }

    /// Get all learned parameters
    pub async fn get_all_params(&self) -> HashMap<String, LearnedParameters> {
        let params = self.learned_params.read().await;
        params.clone()
    }

    /// Reset learning for a specific operation type
    pub async fn reset_operation(&self, op_type: &str) {
        let mut params = self.learned_params.write().await;
        params.remove(op_type);
    }

    /// Reset all learning
    pub async fn reset_all(&self) {
        let mut params = self.learned_params.write().await;
        params.clear();

        let mut history = self.execution_history.write().await;
        history.clear();
    }

    /// Get statistics about the model
    pub async fn get_stats(&self) -> CostModelStats {
        let params = self.learned_params.read().await;
        let history = self.execution_history.read().await;

        let total_samples = params.values().map(|p| p.sample_count).sum();
        let avg_confidence = if params.is_empty() {
            0.0
        } else {
            params.values().map(|p| p.confidence).sum::<f64>() / params.len() as f64
        };

        CostModelStats {
            total_operation_types: params.len(),
            total_samples,
            avg_confidence,
            history_size: history.len(),
            learned_operations: params
                .iter()
                .filter(|(_, p)| p.sample_count >= self.min_samples)
                .map(|(k, _)| k.clone())
                .collect(),
        }
    }

    /// Get operation type identifier for a query operation
    fn get_operation_type(&self, operation: &QueryOperation) -> String {
        match operation {
            QueryOperation::PointLookup { .. } => "point_lookup".to_string(),
            QueryOperation::EntityLookup { lookup_type, .. } => {
                format!("entity_lookup_{:?}", lookup_type)
            }
            QueryOperation::Filter { .. } => "filter".to_string(),
            QueryOperation::RelationshipTraversal { max_depth, .. } => {
                format!("traversal_depth_{}", max_depth)
            }
            QueryOperation::RangeScan { .. } => "range_scan".to_string(),
            QueryOperation::Aggregate { aggregation_type, .. } => {
                format!("aggregate_{:?}", aggregation_type)
            }
            QueryOperation::Sort { .. } => "sort".to_string(),
            QueryOperation::Limit { .. } => "limit".to_string(),
        }
    }
}

impl Default for AdaptiveCostModel {
    fn default() -> Self {
        Self::new()
    }
}

/// Statistics about the cost model
#[derive(Debug, Clone)]
pub struct CostModelStats {
    /// Total number of operation types tracked
    pub total_operation_types: usize,
    /// Total number of execution samples
    pub total_samples: u64,
    /// Average confidence across all operations
    pub avg_confidence: f64,
    /// Current size of execution history
    pub history_size: usize,
    /// Operations with sufficient learning
    pub learned_operations: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_cost_model_creation() {
        let model = AdaptiveCostModel::new();
        let stats = model.get_stats().await;

        assert_eq!(stats.total_operation_types, 0);
        assert_eq!(stats.total_samples, 0);
        assert_eq!(stats.history_size, 0);
    }

    #[tokio::test]
    async fn test_record_execution() {
        let model = AdaptiveCostModel::new();

        let stats = ExecutionStats {
            op_type: "point_lookup".to_string(),
            actual_time_ms: 5.0,
            actual_rows: 1,
            estimated_time_ms: 2.0,
            estimated_rows: 1,
            timestamp: SystemTime::now(),
        };

        model.record_execution(stats).await.unwrap();

        let model_stats = model.get_stats().await;
        assert_eq!(model_stats.history_size, 1);
    }

    #[tokio::test]
    async fn test_learning_threshold() {
        let model = AdaptiveCostModel::with_config(1000, 5, 0.1);

        // Record fewer than min_samples
        for i in 0..4 {
            let stats = ExecutionStats {
                op_type: "point_lookup".to_string(),
                actual_time_ms: 5.0,
                actual_rows: 1,
                estimated_time_ms: 2.0,
                estimated_rows: 1,
                timestamp: SystemTime::now(),
            };
            model.record_execution(stats).await.unwrap();
        }

        // Should not have learned yet
        let params = model.get_learned_params("point_lookup").await;
        assert!(params.is_none());

        // Add one more to reach threshold
        let stats = ExecutionStats {
            op_type: "point_lookup".to_string(),
            actual_time_ms: 5.0,
            actual_rows: 1,
            estimated_time_ms: 2.0,
            estimated_rows: 1,
            timestamp: SystemTime::now(),
        };
        model.record_execution(stats).await.unwrap();

        // Should have learned now
        let params = model.get_learned_params("point_lookup").await;
        assert!(params.is_some());
        assert!(params.unwrap().sample_count >= 5);
    }

    #[tokio::test]
    async fn test_cost_estimation() {
        let model = AdaptiveCostModel::with_config(1000, 3, 0.5);

        // Train the model
        for _ in 0..5 {
            let stats = ExecutionStats {
                op_type: "point_lookup".to_string(),
                actual_time_ms: 10.0,
                actual_rows: 1,
                estimated_time_ms: 2.0,
                estimated_rows: 1,
                timestamp: SystemTime::now(),
            };
            model.record_execution(stats).await.unwrap();
        }

        // Estimate cost should be adjusted
        let base_cost = 2.0;
        let estimated = model
            .estimate_cost(&QueryOperation::PointLookup { key: vec![] }, base_cost)
            .await
            .unwrap();

        // Should be higher than base cost due to learning
        assert!(estimated > base_cost);
    }

    #[tokio::test]
    async fn test_prediction_error() {
        let stats = ExecutionStats {
            op_type: "test".to_string(),
            actual_time_ms: 10.0,
            actual_rows: 100,
            estimated_time_ms: 5.0,
            estimated_rows: 50,
            timestamp: SystemTime::now(),
        };

        let error_pct = stats.prediction_error_pct();
        assert!((error_pct - 100.0).abs() < 0.01); // 100% error

        let row_error = stats.row_estimate_error_pct();
        assert!((row_error - 100.0).abs() < 0.01); // 100% error
    }

    #[tokio::test]
    async fn test_history_trimming() {
        let model = AdaptiveCostModel::with_config(5, 10, 0.1);

        // Add 10 entries
        for i in 0..10 {
            let stats = ExecutionStats {
                op_type: format!("op_{}", i % 3),
                actual_time_ms: 5.0,
                actual_rows: 1,
                estimated_time_ms: 2.0,
                estimated_rows: 1,
                timestamp: SystemTime::now(),
            };
            model.record_execution(stats).await.unwrap();
        }

        let model_stats = model.get_stats().await;
        assert_eq!(model_stats.history_size, 5); // Should be trimmed to max
    }

    #[tokio::test]
    async fn test_reset_operation() {
        let model = AdaptiveCostModel::with_config(1000, 3, 0.1);

        // Train
        for _ in 0..5 {
            let stats = ExecutionStats {
                op_type: "point_lookup".to_string(),
                actual_time_ms: 5.0,
                actual_rows: 1,
                estimated_time_ms: 2.0,
                estimated_rows: 1,
                timestamp: SystemTime::now(),
            };
            model.record_execution(stats).await.unwrap();
        }

        // Reset
        model.reset_operation("point_lookup").await;

        // Should be gone
        let params = model.get_learned_params("point_lookup").await;
        assert!(params.is_none());
    }
}
