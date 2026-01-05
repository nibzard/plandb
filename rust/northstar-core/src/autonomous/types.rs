//! Core types for autonomous optimization.

use crate::analytics::usage::{
    QueryPattern, HotKeyReport, ColdDataReport, Recommendation,
    ImpactEstimate, Evidence, EffortLevel, RecommendationPriority,
};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{SystemTime, Duration};
use serde::{Serialize, Deserialize};

/// Approval mode for optimizations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ApprovalMode {
    /// Auto-approve all optimizations
    Auto,
    /// Require manual approval for medium and high risk
    ManualMedium,
    /// Require manual approval for high risk only
    ManualHigh,
    /// Require manual approval for all optimizations
    ManualAll,
}

/// Safety constraints for optimizations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SafetyConstraints {
    /// Maximum allowed latency regression (default: 10%)
    pub max_latency_regression: f64,

    /// Maximum allowed throughput regression (default: 10%)
    pub max_throughput_regression: f64,

    /// Maximum storage overhead as percentage of DB size (default: 10%)
    pub max_storage_overhead_percent: f64,

    /// Maximum CPU usage during optimization (default: 50%)
    pub max_cpu_usage_percent: f64,

    /// Maximum optimization duration (default: 1 hour)
    pub max_optimization_duration: Duration,

    /// Require dry-run before applying
    pub require_dry_run: bool,
}

impl Default for SafetyConstraints {
    fn default() -> Self {
        Self {
            max_latency_regression: 0.10,
            max_throughput_regression: 0.10,
            max_storage_overhead_percent: 0.10,
            max_cpu_usage_percent: 0.50,
            max_optimization_duration: Duration::from_secs(3600),
            require_dry_run: false,
        }
    }
}

/// System state snapshot for rollback.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemState {
    /// Snapshot timestamp
    pub timestamp: SystemTime,

    /// Average query latency (ms)
    pub avg_latency_ms: f64,

    /// Average throughput (ops/sec)
    pub avg_throughput: f64,

    /// Cache hit rate
    pub cache_hit_rate: f64,

    /// Memory usage (bytes)
    pub memory_usage_bytes: u64,

    /// Disk usage (bytes)
    pub disk_usage_bytes: u64,

    /// Active indexes
    pub active_indexes: Vec<String>,
}

/// Optimization type.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum OptimizationType {
    /// Create index
    CreateIndex { table: String, columns: Vec<String> },

    /// Drop index
    DropIndex { table: String, index_name: String },

    /// Cache warming
    CacheWarming { keys: Vec<Vec<u8>>, cache_level: u8 },

    /// Cache resizing
    CacheResize { cache_name: String, new_size_bytes: usize },

    /// Data archival
    ArchiveData { table: String, target: String },

    /// Data compression
    CompressData { table: String },

    /// Vacuum and compaction
    Vacuum { table: Option<String> },

    /// Query plan optimization
    OptimizeQueryPlan { query_id: u64 },
}

/// Optimization candidate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OptimizationCandidate {
    /// Optimization type
    pub optimization_type: OptimizationType,

    /// Estimated impact
    pub estimated_benefit: ImpactEstimate,

    /// Effort level
    pub effort_level: EffortLevel,

    /// Risk level (0.0 to 1.0)
    pub risk_level: f64,

    /// Confidence score (0.0 to 1.0)
    pub confidence: f64,

    /// Priority
    pub priority: RecommendationPriority,

    /// Rationale
    pub rationale: String,

    /// Supporting evidence
    pub evidence: Vec<Evidence>,
}

/// Result of optimization execution.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OptimizationResult {
    /// Optimization ID
    pub id: super::error::OptimizationId,

    /// Optimization type
    pub optimization_type: OptimizationType,

    /// Start time
    pub started_at: SystemTime,

    /// End time
    pub completed_at: SystemTime,

    /// Success status
    pub success: bool,

    /// Actual impact
    pub actual_impact: Option<SystemState>,

    /// Error message (if failed)
    pub error_message: Option<String>,
}

/// Scheduled time for optimization.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ScheduledTime {
    /// Execute immediately
    Now,
    /// Execute at specific time
    At(SystemTime),
    /// Execute during next maintenance window
    NextMaintenanceWindow,
}

/// Optimization report for a full cycle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OptimizationReport {
    /// Cycle ID (UUID)
    pub cycle_id: String,

    /// Cycle start time
    pub started_at: SystemTime,

    /// Cycle end time
    pub completed_at: Option<SystemTime>,

    /// Number of candidates evaluated
    pub candidates_evaluated: usize,

    /// Number of optimizations applied
    pub optimizations_applied: usize,

    /// Number of optimizations skipped
    pub optimizations_skipped: usize,

    /// Number of optimizations failed
    pub optimizations_failed: usize,

    /// Optimization results
    pub results: Vec<OptimizationResult>,
}

/// Record for rollback capability.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OptimizationRecord {
    /// Optimization ID
    pub id: super::error::OptimizationId,

    /// Optimization type
    pub optimization_type: OptimizationType,

    /// Pre-optimization state
    pub before_state: SystemState,

    /// Post-optimization state
    pub after_state: Option<SystemState>,

    /// Applied timestamp
    pub applied_at: SystemTime,

    /// Rollback function name (for logging)
    pub rollback_fn: String,
}

/// Rollback manager for optimization history.
#[derive(Debug, Clone)]
pub struct RollbackManager {
    /// Optimization history
    history: Arc<tokio::sync::RwLock<BTreeMap<super::error::OptimizationId, OptimizationRecord>>>,
}

impl RollbackManager {
    /// Create new rollback manager.
    pub fn new() -> Self {
        Self {
            history: Arc::new(tokio::sync::RwLock::new(BTreeMap::new())),
        }
    }

    /// Record optimization for potential rollback.
    pub async fn record_optimization(
        &self,
        record: OptimizationRecord,
    ) -> super::AutonomousResult<()> {
        let mut history = self.history.write().await;
        history.insert(record.id, record);
        Ok(())
    }

    /// Get optimization record.
    pub async fn get_record(
        &self,
        id: super::error::OptimizationId,
    ) -> super::AutonomousResult<OptimizationRecord> {
        let history = self.history.read().await;
        history
            .get(&id)
            .cloned()
            .ok_or(super::AutonomousError::OptimizationNotFound(id))
    }

    /// List all optimization records.
    pub async fn list_records(&self) -> Vec<OptimizationRecord> {
        let history = self.history.read().await;
        history.values().cloned().collect()
    }

    /// Remove old records (older than specified duration).
    pub async fn cleanup_old_records(&self, older_than: Duration) -> usize {
        let mut history = self.history.write().await;
        let cutoff = SystemTime::now() - older_than;
        let before = history.len();

        history.retain(|_, record| record.applied_at > cutoff);

        before - history.len()
    }
}

impl Default for RollbackManager {
    fn default() -> Self {
        Self::new()
    }
}

/// Convert recommendation to optimization candidate.
pub fn recommendation_to_candidate(rec: &Recommendation) -> Option<OptimizationCandidate> {
    let optimization_type = match &rec.recommendation_type {
        crate::analytics::usage::RecommendationType::CreateIndex { table, columns } => {
            OptimizationType::CreateIndex {
                table: table.clone(),
                columns: columns.clone(),
            }
        }
        crate::analytics::usage::RecommendationType::CacheWarming { cache_level } => {
            // Need to extract keys from recommendation context
            return None;
        }
        crate::analytics::usage::RecommendationType::ArchiveData { target } => {
            // Need to extract table from recommendation
            return None;
        }
        _ => return None,
    };

    Some(OptimizationCandidate {
        optimization_type,
        estimated_benefit: rec.estimated_benefit.clone(),
        effort_level: rec.effort_level,
        risk_level: 1.0 - rec.confidence,
        confidence: rec.confidence,
        priority: rec.priority,
        rationale: rec.rationale.clone(),
        evidence: rec.supporting_evidence.clone(),
    })
}
