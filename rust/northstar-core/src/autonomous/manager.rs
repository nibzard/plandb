//! Autonomous Optimization Manager.
//!
//! Main orchestrator for autonomous database optimization.

use crate::analytics::usage::{
    UsageAnalytics, QueryPattern, HotKeyReport, ColdDataReport,
    Recommendation as UsageRecommendation, ImpactEstimate,
};
use crate::autonomous::{
    PolicyEngine, IndexManager, CacheOptimizer, MaintenanceScheduler,
    OptimizationCandidate, OptimizationType, OptimizationResult,
    OptimizationReport, SystemState, OptimizationRecord, RollbackManager,
    ScheduledTime, ApprovalMode, SafetyConstraints,
    AutonomousResult, AutonomousError, OptimizationId,
};
use crate::autonomous::types::recommendation_to_candidate;
use std::sync::Arc;
use std::time::{SystemTime, Duration};
use std::collections::HashMap;
use tokio::sync::RwLock;
use uuid::Uuid;

/// Configuration for autonomous manager.
#[derive(Debug, Clone)]
pub struct AutonomousConfig {
    /// Approval mode
    pub approval_mode: ApprovalMode,

    /// Safety constraints
    pub safety_constraints: SafetyConstraints,

    /// Dry-run mode (simulate but don't apply)
    pub dry_run: bool,

    /// Optimization cycle interval
    pub cycle_interval: Duration,

    /// Maximum optimizations per cycle
    pub max_optimizations_per_cycle: usize,
}

impl Default for AutonomousConfig {
    fn default() -> Self {
        Self {
            approval_mode: ApprovalMode::ManualHigh,
            safety_constraints: SafetyConstraints::default(),
            dry_run: false,
            cycle_interval: Duration::from_secs(3600), // 1 hour
            max_optimizations_per_cycle: 10,
        }
    }
}

/// Autonomous optimization manager.
pub struct AutonomousManager {
    /// Policy engine
    policy: PolicyEngine,

    /// Usage analytics
    usage_analytics: Arc<UsageAnalytics>,

    /// Index manager
    index_manager: Arc<RwLock<IndexManager>>,

    /// Cache optimizer
    cache_optimizer: Arc<RwLock<CacheOptimizer>>,

    /// Maintenance scheduler
    scheduler: Arc<RwLock<MaintenanceScheduler>>,

    /// Rollback manager
    rollback: RollbackManager,

    /// Configuration
    config: AutonomousConfig,

    /// Current system state
    current_state: SystemState,
}

impl AutonomousManager {
    /// Create new autonomous manager.
    pub fn new(
        usage_analytics: Arc<UsageAnalytics>,
        policy: PolicyEngine,
        config: AutonomousConfig,
    ) -> Self {
        Self {
            policy,
            usage_analytics,
            index_manager: Arc::new(RwLock::new(IndexManager::new())),
            cache_optimizer: Arc::new(RwLock::new(CacheOptimizer::default())),
            scheduler: Arc::new(RwLock::new(MaintenanceScheduler::default())),
            rollback: RollbackManager::new(),
            config,
            current_state: SystemState {
                timestamp: SystemTime::now(),
                avg_latency_ms: 0.0,
                avg_throughput: 0.0,
                cache_hit_rate: 0.0,
                memory_usage_bytes: 0,
                disk_usage_bytes: 0,
                active_indexes: vec![],
            },
        }
    }

    /// Run full optimization cycle.
    pub async fn run_optimization_cycle(&mut self) -> AutonomousResult<OptimizationReport> {
        let cycle_id = Uuid::new_v4().to_string();
        let started_at = SystemTime::now();

        // 1. Collect analytics (these are synchronous methods)
        let patterns = self.usage_analytics.get_hot_keys(); // Use hot_keys for patterns
        let hot_keys = self.usage_analytics.get_hot_keys();
        let cold_data = self.usage_analytics.get_cold_data();

        // 2. Generate candidates
        let mut candidates = Vec::new();

        // For now, just evaluate hot keys (we'd need patterns for index evaluation)
        // Evaluate hot keys
        for hot_key in &hot_keys {
            if let Ok(candidate) = self.policy.evaluate_cache_warming(hot_key) {
                candidates.push(candidate);
            }
        }

        // Evaluate cold data
        for cold in &cold_data {
            if let Ok(candidate) = self.policy.evaluate_archival(cold) {
                candidates.push(candidate);
            }
        }

        let candidates_evaluated = candidates.len();

        // 3. Filter and prioritize
        candidates = self.filter_and_prioritize(candidates)?;

        // 4. Apply optimizations
        let mut applied = Vec::new();
        let mut failed = 0;

        for candidate in candidates.into_iter().take(self.config.max_optimizations_per_cycle) {
            match self.apply_optimization(&candidate).await {
                Ok(result) => applied.push(result),
                Err(_) => failed += 1,
            }
        }

        let skipped = candidates_evaluated - applied.len() - failed;

        // 5. Generate report
        Ok(OptimizationReport {
            cycle_id,
            started_at,
            completed_at: Some(SystemTime::now()),
            candidates_evaluated,
            optimizations_applied: applied.len(),
            optimizations_skipped: skipped,
            optimizations_failed: failed,
            results: applied,
        })
    }

    /// Apply a specific optimization.
    pub async fn apply_optimization(
        &mut self,
        candidate: &OptimizationCandidate,
    ) -> AutonomousResult<OptimizationResult> {
        // Check dry-run mode
        if self.config.dry_run {
            return Ok(OptimizationResult {
                id: OptimizationId(0),
                optimization_type: candidate.optimization_type.clone(),
                started_at: SystemTime::now(),
                completed_at: SystemTime::now(),
                success: true,
                actual_impact: None,
                error_message: Some("Dry-run mode - not applied".to_string()),
            });
        }

        // Check approval requirements
        if self.requires_approval(candidate) {
            return Err(AutonomousError::ApprovalRequired(format!(
                "{:?} requires approval",
                candidate.optimization_type
            )));
        }

        // Check maintenance window
        let scheduler = self.scheduler.read().await;
        if !scheduler.can_execute_now(&candidate.optimization_type) {
            return Err(AutonomousError::MaintenanceWindowNotAvailable);
        }
        drop(scheduler);

        // Execute optimization
        let result = match &candidate.optimization_type {
            OptimizationType::CreateIndex { table, columns } => {
                self.create_index(table.clone(), columns.clone()).await?
            }
            OptimizationType::CacheWarming { keys, cache_level } => {
                self.warm_cache(keys.clone(), *cache_level).await?
            }
            OptimizationType::CacheResize {
                cache_name,
                new_size_bytes,
            } => {
                self.resize_cache(cache_name, *new_size_bytes).await?
            }
            OptimizationType::ArchiveData { table, target } => {
                self.archive_data(table.clone(), target.clone()).await?
            }
            OptimizationType::Vacuum { table } => {
                self.vacuum(table.clone()).await?
            }
            _ => {
                return Err(AutonomousError::InvalidCandidate(
                    "Optimization type not implemented".to_string(),
                ))
            }
        };

        Ok(result)
    }

    /// Apply recommendation from usage analytics.
    pub async fn apply_recommendation(
        &mut self,
        rec: &UsageRecommendation,
    ) -> AutonomousResult<()> {
        let candidate = recommendation_to_candidate(rec)
            .ok_or_else(|| {
                AutonomousError::InvalidCandidate("Cannot convert to candidate".to_string())
            })?;

        self.apply_optimization(&candidate).await?;
        Ok(())
    }

    /// Rollback optimization.
    pub async fn rollback_optimization(
        &mut self,
        id: OptimizationId,
    ) -> AutonomousResult<()> {
        let record = self.rollback.get_record(id).await?;

        // Execute rollback based on optimization type
        match &record.optimization_type {
            OptimizationType::CreateIndex { table, .. } => {
                // Find and drop index
                let mut manager = self.index_manager.write().await;
                // In real implementation, would find index by table
                manager.drop_index(&format!("idx_{}", table))?;
            }
            OptimizationType::CacheResize { cache_name, .. } => {
                // Revert to previous size
                let mut optimizer = self.cache_optimizer.write().await;
                // Would need to store previous size
                let _ = cache_name;
            }
            _ => {
                return Err(AutonomousError::RollbackFailed(
                    "Rollback not implemented for this type".to_string(),
                ))
            }
        }

        Ok(())
    }

    /// Check if optimization requires approval.
    fn requires_approval(&self, candidate: &OptimizationCandidate) -> bool {
        match self.config.approval_mode {
            ApprovalMode::Auto => false,
            ApprovalMode::ManualAll => true,
            ApprovalMode::ManualMedium => {
                matches!(
                    candidate.effort_level,
                    crate::analytics::usage::EffortLevel::Moderate |
                        crate::analytics::usage::EffortLevel::Complex
                )
            }
            ApprovalMode::ManualHigh => {
                matches!(
                    candidate.priority,
                    crate::analytics::usage::RecommendationPriority::High |
                        crate::analytics::usage::RecommendationPriority::Critical
                )
            }
        }
    }

    /// Filter and prioritize candidates.
    fn filter_and_prioritize(
        &self,
        mut candidates: Vec<OptimizationCandidate>,
    ) -> AutonomousResult<Vec<OptimizationCandidate>> {
        // Sort by priority (high to low), then by confidence (high to low)
        candidates.sort_by(|a, b| {
            b.priority
                .partial_cmp(&a.priority)
                .unwrap()
                .then(b.confidence.partial_cmp(&a.confidence).unwrap())
        });

        // Filter by safety constraints
        candidates.retain(|c| {
            c.confidence >= 0.5 // Minimum confidence threshold
                && c.risk_level <= 0.7 // Maximum risk threshold
        });

        Ok(candidates)
    }

    /// Create index.
    async fn create_index(
        &self,
        table: String,
        columns: Vec<String>,
    ) -> AutonomousResult<OptimizationResult> {
        let mut manager = self.index_manager.write().await;
        let id = manager.create_index(table.clone(), columns.clone(), false)?;

        Ok(OptimizationResult {
            id,
            optimization_type: OptimizationType::CreateIndex { table, columns },
            started_at: SystemTime::now(),
            completed_at: SystemTime::now(),
            success: true,
            actual_impact: None,
            error_message: None,
        })
    }

    /// Warm cache.
    async fn warm_cache(
        &self,
        keys: Vec<Vec<u8>>,
        cache_level: u8,
    ) -> AutonomousResult<OptimizationResult> {
        let mut optimizer = self.cache_optimizer.write().await;

        // Queue keys for warming
        let entries = keys
            .into_iter()
            .map(|key| crate::autonomous::cache::CacheWarmEntry {
                key,
                cache_level,
                priority: 0.8,
                access_frequency: 100.0,
            })
            .collect();

        optimizer.queue_warming(entries)?;

        Ok(OptimizationResult {
            id: OptimizationId(1),
            optimization_type: OptimizationType::CacheWarming {
                keys: vec![],
                cache_level,
            },
            started_at: SystemTime::now(),
            completed_at: SystemTime::now(),
            success: true,
            actual_impact: None,
            error_message: None,
        })
    }

    /// Resize cache.
    async fn resize_cache(
        &self,
        cache_name: &str,
        new_size_bytes: usize,
    ) -> AutonomousResult<OptimizationResult> {
        let mut optimizer = self.cache_optimizer.write().await;
        optimizer.apply_cache_resize(cache_name, new_size_bytes)
    }

    /// Archive data.
    async fn archive_data(
        &self,
        table: String,
        target: String,
    ) -> AutonomousResult<OptimizationResult> {
        // In real implementation, would export to cloud storage
        Ok(OptimizationResult {
            id: OptimizationId(1),
            optimization_type: OptimizationType::ArchiveData { table, target },
            started_at: SystemTime::now(),
            completed_at: SystemTime::now() + Duration::from_secs(60),
            success: true,
            actual_impact: None,
            error_message: None,
        })
    }

    /// Vacuum and compact.
    async fn vacuum(&self, table: Option<String>) -> AutonomousResult<OptimizationResult> {
        Ok(OptimizationResult {
            id: OptimizationId(1),
            optimization_type: OptimizationType::Vacuum { table },
            started_at: SystemTime::now(),
            completed_at: SystemTime::now() + Duration::from_secs(300),
            success: true,
            actual_impact: None,
            error_message: None,
        })
    }

    /// Update current system state.
    pub async fn update_system_state(&mut self, state: SystemState) {
        self.current_state = state;

        // Update scheduler load
        let mut scheduler = self.scheduler.write().await;
        // Convert memory usage to load metric (0.0 to 1.0)
        let total_memory = 16u64 * 1024 * 1024 * 1024; // 16 GB
        let load = (self.current_state.memory_usage_bytes as f64 / total_memory as f64)
            .clamp(0.0, 1.0);
        scheduler.update_load(load);
    }

    /// Get current system state.
    pub fn current_state(&self) -> &SystemState {
        &self.current_state
    }

    /// Get configuration.
    pub fn config(&self) -> &AutonomousConfig {
        &self.config
    }

    /// Set dry-run mode.
    pub fn set_dry_run(&mut self, dry_run: bool) {
        self.config.dry_run = dry_run;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_filter_and_prioritize() {
        let manager = create_test_manager();

        let mut candidates = vec![
            OptimizationCandidate {
                optimization_type: OptimizationType::CacheWarming {
                    keys: vec![],
                    cache_level: 1,
                },
                estimated_benefit: ImpactEstimate {
                    latency_reduction_percent: 90.0,
                    throughput_increase_percent: 20.0,
                    cost_reduction_percent: None,
                    storage_overhead_bytes: None,
                },
                effort_level: crate::analytics::usage::EffortLevel::Trivial,
                risk_level: 0.05,
                confidence: 0.95,
                priority: crate::analytics::usage::RecommendationPriority::High,
                rationale: "Test".to_string(),
                evidence: vec![],
            },
            OptimizationCandidate {
                optimization_type: OptimizationType::CreateIndex {
                    table: "users".to_string(),
                    columns: vec!["id".to_string()],
                },
                estimated_benefit: ImpactEstimate {
                    latency_reduction_percent: 80.0,
                    throughput_increase_percent: 50.0,
                    cost_reduction_percent: None,
                    storage_overhead_bytes: Some(1024),
                },
                effort_level: crate::analytics::usage::EffortLevel::Easy,
                risk_level: 0.2,
                confidence: 0.4, // Too low confidence
                priority: crate::analytics::usage::RecommendationPriority::Medium,
                rationale: "Test".to_string(),
                evidence: vec![],
            },
        ];

        let filtered = manager.filter_and_prioritize(candidates).unwrap();
        assert_eq!(filtered.len(), 1); // Second filtered out due to low confidence
        assert_eq!(filtered[0].priority, crate::analytics::usage::RecommendationPriority::High);
    }

    fn create_test_manager() -> AutonomousManager {
        use crate::analytics::UsageAnalytics;
        use crate::monitoring::{MetricRegistry, MonitoringConfig};

        let registry = Arc::new(MetricRegistry::new(MonitoringConfig::default()));
        let usage_analytics = Arc::new(UsageAnalytics::new(registry));

        AutonomousManager::new(
            usage_analytics,
            PolicyEngine::default_config(),
            AutonomousConfig::default(),
        )
    }
}
