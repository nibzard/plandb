//! Plugin System Types
//!
//! Defines the core plugin trait and associated types for the plugin system.

use crate::error::{DbError, Result};
use crate::types::{Lsn, TransactionId};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;

/// Plugin trait that all plugins must implement.
///
/// Plugins are event-driven components that hook into database operations
/// such as commits, queries, and scheduled maintenance tasks.
#[async_trait::async_trait]
pub trait Plugin: Send + Sync + std::fmt::Debug {
    /// Returns the unique name of this plugin.
    fn name(&self) -> &str;

    /// Returns the version of this plugin.
    fn version(&self) -> &str;

    /// Returns list of plugin dependencies (optional).
    ///
    /// Default implementation returns empty slice (no dependencies).
    fn dependencies(&self) -> &[&str] {
        &[]
    }

    /// Called when plugin is registered with the database.
    ///
    /// This is where plugins should:
    /// - Validate their configuration
    /// - Initialize external connections (LLM providers, etc.)
    /// - Allocate resources within their quota
    ///
    /// # Errors
    ///
    /// Returns error if initialization fails. Plugin will not be registered.
    async fn on_init(&mut self, context: &PluginContext) -> Result<()>;

    /// Called after each transaction commit.
    ///
    /// This hook is asynchronous and non-blocking. Plugins can use this to:
    /// - Extract entities and topics from mutations
    /// - Update structured memory cartridges
    /// - Analyze performance impact
    ///
    /// # Errors
    ///
    /// Errors are logged but don't affect the committed transaction.
    async fn on_commit(&mut self, event: &CommitEvent) -> Result<()>;

    /// Called before query execution for optimization.
    ///
    /// This hook is synchronous (blocking) but has a tight timeout.
    /// Plugins can use this to:
    /// - Optimize query plans
    /// - Rewrite queries for better performance
    /// - Return cached results
    ///
    /// # Errors
    ///
    /// On error or timeout, query executes as-is (PassThrough).
    async fn on_query(&mut self, event: &QueryEvent) -> Result<QueryResponse>;

    /// Called periodically for maintenance tasks.
    ///
    /// This hook is asynchronous and runs in the background.
    /// Plugins can use this to:
    /// - Build/update structured memory cartridges
    /// - Analyze usage patterns
    /// - Perform maintenance tasks
    ///
    /// # Errors
    ///
    /// Errors are logged. Task is retried on next schedule.
    async fn on_schedule(&mut self, event: &ScheduleEvent) -> Result<()>;

    /// Called during database graceful shutdown.
    ///
    /// Plugins should:
    /// - Flush any pending updates
    /// - Close external connections
    /// - Release allocated resources
    ///
    /// # Errors
    ///
    /// Cleanup is best-effort. Shutdown continues even if this fails.
    async fn on_shutdown(&mut self) -> Result<()>;
}

/// Context provided to plugins during initialization.
#[derive(Debug, Clone)]
pub struct PluginContext {
    /// Database configuration
    pub db_config: DbConfig,

    /// Plugin-specific configuration (JSON)
    pub plugin_config: serde_json::Value,

    /// Resource quota for this plugin
    pub resource_quota: ResourceQuota,
}

/// Database configuration subset exposed to plugins.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DbConfig {
    /// Database file path
    pub path: String,

    /// Maximum page cache size in bytes
    pub max_cache_size: u64,

    /// Whether WAL is enabled
    pub wal_enabled: bool,

    /// Additional configuration options
    pub options: HashMap<String, String>,
}

/// Resource quota for a plugin.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceQuota {
    /// Maximum memory allocation in bytes
    pub max_memory_bytes: u64,

    /// Maximum CPU usage as percentage (0.0-100.0)
    pub max_cpu_percent: f64,

    /// Maximum number of concurrent operations
    pub max_concurrent_operations: usize,
}

impl Default for ResourceQuota {
    fn default() -> Self {
        Self {
            max_memory_bytes: 100 * 1024 * 1024, // 100MB
            max_cpu_percent: 10.0,
            max_concurrent_operations: 5,
        }
    }
}

/// Event emitted after a transaction commit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitEvent {
    /// Transaction ID
    pub txn_id: TransactionId,

    /// Log sequence number
    pub lsn: Lsn,

    /// Mutations performed in this transaction
    pub mutations: Vec<Mutation>,

    /// Commit timestamp (Unix nanoseconds)
    pub timestamp: i64,

    /// Additional metadata
    pub metadata: HashMap<String, String>,
}

/// A single database mutation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Mutation {
    /// Mutation type
    pub op_type: MutationType,

    /// Table or collection name
    pub table: String,

    /// Key that was modified
    pub key: Vec<u8>,

    /// New value (for SET operations)
    pub value: Option<Vec<u8>>,

    /// Old value (for UPDATE operations)
    pub old_value: Option<Vec<u8>>,
}

/// Type of mutation operation.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum MutationType {
    /// Insert a new key-value pair
    Insert,

    /// Update an existing key-value pair
    Update,

    /// Delete a key-value pair
    Delete,
}

/// Event emitted before query execution.
#[derive(Debug, Clone)]
pub struct QueryEvent {
    /// Query string or natural language query
    pub query: String,

    /// Type of query
    pub query_type: QueryType,

    /// Estimated execution cost
    pub estimated_cost: f64,

    /// Available structured memory cartridges
    pub available_cartridges: Vec<CartridgeType>,

    /// Query performance constraints
    pub constraints: QueryConstraints,
}

/// Query type classification.
#[derive(Debug, Clone, Copy)]
pub enum QueryType {
    /// Point lookup (single key)
    PointGet,

    /// Range scan (multiple keys)
    RangeScan,

    /// Natural language query
    NaturalLanguage,

    /// Semantic search query
    SemanticSearch,
}

/// Structured memory cartridge type.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum CartridgeType {
    /// Entity cartridge
    Entity,

    /// Topic cartridge
    Topic,

    /// Relationship cartridge
    Relationship,

    /// Custom cartridge type
    Custom(String),
}

/// Query performance constraints.
#[derive(Debug, Clone)]
pub struct QueryConstraints {
    /// Maximum acceptable latency in milliseconds
    pub max_latency_ms: u64,

    /// Maximum acceptable cost
    pub max_cost: f64,

    /// Prefer accuracy over speed
    pub prefer_accuracy: bool,
}

/// Response from query optimization hook.
#[derive(Debug, Clone)]
pub enum QueryResponse {
    /// No optimization, execute query as-is
    PassThrough,

    /// Optimized query plan
    Optimize(QueryPlan),

    /// Return cached/pre-computed result directly
    Intercept(QueryResult),
}

/// Optimized query plan.
#[derive(Debug, Clone)]
pub struct QueryPlan {
    /// Optimized query string
    pub query: String,

    /// Estimated cost after optimization
    pub estimated_cost: f64,

    /// Plan explanation (human-readable)
    pub explanation: String,

    /// Cartridges to use
    pub cartridges: Vec<CartridgeType>,
}

/// Query result (for interception).
#[derive(Debug, Clone)]
pub struct QueryResult {
    /// Result rows
    pub rows: Vec<ResultRow>,

    /// Result metadata
    pub metadata: ResultMetadata,
}

/// A single query result row.
#[derive(Debug, Clone)]
pub struct ResultRow {
    /// Column values
    pub columns: Vec<ColumnValue>,
}

/// Column value.
#[derive(Debug, Clone)]
pub enum ColumnValue {
    /// Null value
    Null,

    /// Boolean value
    Bool(bool),

    /// Integer value
    Integer(i64),

    /// Float value
    Float(f64),

    /// String value
    String(String),

    /// Byte array value
    Bytes(Vec<u8>),
}

/// Query result metadata.
#[derive(Debug, Clone)]
pub struct ResultMetadata {
    /// Number of rows returned
    pub row_count: usize,

    /// Execution time in nanoseconds
    pub execution_time_ns: u64,

    /// Whether result was from cache
    pub cached: bool,
}

/// Event emitted for scheduled maintenance.
#[derive(Debug, Clone)]
pub struct ScheduleEvent {
    /// Schedule ID
    pub schedule_id: String,

    /// Interval between executions
    pub interval: Duration,

    /// Maintenance window
    pub window: TimeWindow,

    /// Resource limits for this execution
    pub resource_limits: ResourceLimits,
}

/// Time window for scheduled task.
#[derive(Debug, Clone)]
pub struct TimeWindow {
    /// Window start time
    pub start: DateTime<Utc>,

    /// Window end time
    pub end: DateTime<Utc>,
}

/// Resource limits for a scheduled task.
#[derive(Debug, Clone)]
pub struct ResourceLimits {
    /// Maximum memory allocation in bytes
    pub max_memory_bytes: u64,

    /// Maximum CPU usage as percentage
    pub max_cpu_percent: f64,

    /// Maximum execution duration
    pub max_duration: Duration,
}

/// Result from plugin hook execution.
#[derive(Debug, Clone)]
pub struct PluginResult {
    /// Plugin name
    pub plugin_name: String,

    /// Hook type that was executed
    pub hook_type: HookType,

    /// Execution duration
    pub duration: Duration,

    /// Success or error message
    pub result: std::result::Result<HookOutput, String>,
}

/// Output from successful hook execution.
#[derive(Debug, Clone)]
pub enum HookOutput {
    /// Commit hook output
    Commit(()),

    /// Query hook output
    Query(QueryResponse),

    /// Schedule hook output
    Schedule(()),
}

/// Hook type identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HookType {
    /// Initialization hook
    OnInit,

    /// Commit hook
    OnCommit,

    /// Query hook
    OnQuery,

    /// Schedule hook
    OnSchedule,

    /// Shutdown hook
    OnShutdown,
}

/// Plugin registration information.
#[derive(Debug, Clone)]
pub struct PluginInfo {
    /// Plugin name
    pub name: String,

    /// Plugin version
    pub version: String,

    /// Whether plugin is enabled
    pub enabled: bool,

    /// Hook registrations
    pub hooks: Vec<HookRegistration>,

    /// Resource usage
    pub resource_usage: PluginResourceUsage,
}

/// Hook registration details.
#[derive(Debug, Clone)]
pub struct HookRegistration {
    /// Plugin name
    pub plugin_name: String,

    /// Hook type
    pub hook_type: HookType,

    /// Execution priority (higher = earlier)
    pub priority: i32,

    /// Whether hook is enabled
    pub enabled: bool,
}

/// Plugin resource usage statistics.
#[derive(Debug, Clone)]
pub struct PluginResourceUsage {
    /// Plugin name
    pub plugin_name: String,

    /// Current memory usage in bytes
    pub memory_bytes: u64,

    /// Total CPU time in nanoseconds
    pub cpu_time_ns: u64,

    /// Hook execution counts
    pub hook_execution_count: HashMap<HookType, u64>,

    /// Last execution timestamp per hook
    pub last_execution: HashMap<HookType, i64>,

    /// Total error count
    pub error_count: u64,
}

/// Plugin manager configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginManagerConfig {
    /// Maximum number of plugins
    pub max_plugins: usize,

    /// Default timeout for hook execution
    pub default_hook_timeout_ms: u64,

    /// Enable parallel hook execution
    pub enable_parallel_hooks: bool,

    /// Resource quota for plugins
    pub resource_quota: ResourceQuota,
}

impl Default for PluginManagerConfig {
    fn default() -> Self {
        Self {
            max_plugins: 10,
            default_hook_timeout_ms: 5000,
            enable_parallel_hooks: true,
            resource_quota: ResourceQuota::default(),
        }
    }
}

/// Plugin-specific configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginConfig {
    /// Plugin name
    pub name: String,

    /// Whether plugin is enabled
    pub enabled: bool,

    /// Hook execution priority
    pub priority: i32,

    /// Plugin-specific configuration (JSON)
    pub config: serde_json::Value,
}
