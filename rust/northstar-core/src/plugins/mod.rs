//! Plugin System
//!
//! Event-driven plugin architecture for extending database functionality.
//! Provides hooks into commits, queries, and scheduled maintenance tasks
//! while maintaining performance isolation and graceful degradation.

pub mod types;
pub mod hook;
pub mod registry;
pub mod manager;

// Re-exports for convenience
pub use types::{
    Plugin,
    PluginContext,
    PluginConfig,
    PluginInfo,
    PluginResult,
    PluginResourceUsage,
    CommitEvent,
    Mutation,
    MutationType,
    QueryEvent,
    QueryType,
    QueryResponse,
    QueryPlan,
    QueryConstraints,
    ScheduleEvent,
    TimeWindow,
    ResourceLimits,
    HookType,
    HookRegistration,
    HookOutput,
    ResourceQuota,
    DbConfig,
    CartridgeType,
    QueryResult,
    ResultRow,
    ColumnValue,
    ResultMetadata,
};

pub use manager::PluginManager;
pub use registry::PluginRegistry;
pub use hook::HookSystem;
