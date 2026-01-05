//! Autonomous Optimization Manager for NorthstarDB.
//!
//! This module provides self-optimization capabilities for the database,
//! including automatic index management, cache warming, cache sizing,
//! data archival, storage compaction, and maintenance scheduling.

pub mod error;
pub mod types;
pub mod manager;
pub mod policy;
pub mod index;
pub mod cache;
pub mod maintenance;

// Re-exports for convenience
pub use error::{AutonomousError, AutonomousResult, OptimizationId};
pub use types::{
    OptimizationType, OptimizationCandidate, OptimizationResult,
    OptimizationReport, SystemState, OptimizationRecord, ScheduledTime,
    ApprovalMode, SafetyConstraints, RollbackManager,
};
pub use manager::AutonomousManager;
pub use policy::{PolicyEngine, IndexPolicy, CacheWarmingPolicy};
pub use index::IndexManager;
pub use cache::CacheOptimizer;
pub use maintenance::{MaintenanceScheduler, MaintenanceWindow};
