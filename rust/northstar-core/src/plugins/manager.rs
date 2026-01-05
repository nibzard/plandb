//! Plugin Manager
//!
//! Coordinates plugin lifecycle, hook execution, and resource tracking.

use crate::error::{DbError, Error, Result};
use crate::plugins::hook::HookSystem;
use crate::plugins::registry::PluginRegistry;
use crate::plugins::types::*;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;
use tokio::task::JoinSet;

/// Plugin manager for coordinating plugin lifecycle and hook execution.
#[derive(Debug)]
pub struct PluginManager {
    /// Plugin registry
    registry: PluginRegistry,

    /// Hook system
    hook_system: Arc<HookSystem>,

    /// Resource tracker
    resource_tracker: Arc<RwLock<ResourceTracker>>,

    /// Manager configuration
    config: PluginManagerConfig,
}

/// Resource tracker for monitoring plugin resource usage.
#[derive(Debug)]
struct ResourceTracker {
    /// Per-plugin resource usage
    usage: HashMap<String, PluginResourceUsage>,
}

impl ResourceTracker {
    fn new() -> Self {
        Self {
            usage: HashMap::new(),
        }
    }

    fn record_execution(&mut self, plugin_name: &str, hook_type: HookType, duration: Duration) {
        let entry = self
            .usage
            .entry(plugin_name.to_string())
            .or_insert_with(|| PluginResourceUsage {
                plugin_name: plugin_name.to_string(),
                memory_bytes: 0,
                cpu_time_ns: 0,
                hook_execution_count: HashMap::new(),
                last_execution: HashMap::new(),
                error_count: 0,
            });

        // Update execution count
        *entry.hook_execution_count.entry(hook_type).or_insert(0) += 1;

        // Update last execution time
        entry.last_execution.insert(hook_type, chrono::Utc::now().timestamp_nanos_opt().unwrap());

        // Update CPU time (approximate with duration)
        entry.cpu_time_ns += duration.as_nanos() as u64;
    }

    fn record_error(&mut self, plugin_name: &str) {
        let entry = self
            .usage
            .entry(plugin_name.to_string())
            .or_insert_with(|| PluginResourceUsage {
                plugin_name: plugin_name.to_string(),
                memory_bytes: 0,
                cpu_time_ns: 0,
                hook_execution_count: HashMap::new(),
                last_execution: HashMap::new(),
                error_count: 0,
            });

        entry.error_count += 1;
    }

    fn get_usage(&self, plugin_name: &str) -> Option<PluginResourceUsage> {
        self.usage.get(plugin_name).cloned()
    }
}

impl PluginManager {
    /// Create new plugin manager.
    pub fn new(config: PluginManagerConfig) -> Self {
        Self {
            registry: PluginRegistry::new(config.max_plugins),
            hook_system: Arc::new(HookSystem::new()),
            resource_tracker: Arc::new(RwLock::new(ResourceTracker::new())),
            config,
        }
    }

    /// Register a plugin.
    pub async fn register(&self, plugin: Arc<RwLock<dyn Plugin>>) -> Result<PluginInfo> {
        // Get plugin name
        let name = {
            let plugin_guard = plugin.read().await;
            plugin_guard.name().to_string()
        };

        // Create plugin context
        let context = PluginContext {
            db_config: DbConfig {
                path: String::new(), // Would be populated from actual DB config
                max_cache_size: self.config.resource_quota.max_memory_bytes,
                wal_enabled: true,
                options: HashMap::new(),
            },
            plugin_config: serde_json::Value::Object(serde_json::Map::new()),
            resource_quota: self.config.resource_quota.clone(),
        };

        // Initialize plugin
        let start = Instant::now();
        let init_result = tokio::time::timeout(
            tokio::time::Duration::from_secs(5),
            async {
                let mut plugin_guard = plugin.write().await;
                plugin_guard.on_init(&context).await
            },
        )
        .await;

        let duration = start.elapsed();

        match init_result {
            Ok(Ok(())) => {
                tracing::info!(
                    plugin_name = name,
                    duration_ms = duration.as_millis(),
                    "Plugin initialized"
                );
            }
            Ok(Err(e)) => {
                return Err(Error::Plugin(crate::error::PluginError::ExecutionFailed {
                    plugin: name.clone(),
                    error: e.to_string(),
                }));
            }
            Err(_) => {
                return Err(Error::Plugin(crate::error::PluginError::ExecutionFailed {
                    plugin: name.clone(),
                    error: "initialization timeout".to_string(),
                }));
            }
        }

        // Register in registry
        let mut info = self.registry.register(plugin).await?;

        // Register hooks
        self.hook_system
            .register_hook(&name, HookType::OnInit, 0)
            .await?;
        self.hook_system
            .register_hook(&name, HookType::OnCommit, 0)
            .await?;
        self.hook_system
            .register_hook(&name, HookType::OnQuery, 0)
            .await?;
        self.hook_system
            .register_hook(&name, HookType::OnSchedule, 0)
            .await?;
        self.hook_system
            .register_hook(&name, HookType::OnShutdown, 0)
            .await?;

        info.hooks = self.hook_system.get_plugin_hooks(&name).await;

        Ok(info)
    }

    /// Unregister a plugin.
    pub async fn unregister(&self, name: &str) -> Result<()> {
        // Unregister hooks
        self.hook_system.unregister_hooks(name).await;

        // Remove from registry
        let _plugin = self.registry.unregister(name).await?;

        // Note: Plugin shutdown would be handled by the plugin being dropped
        tracing::info!(plugin_name = name, "Plugin unregistered");

        Ok(())
    }

    /// Get a plugin by name.
    pub async fn get_plugin(&self, name: &str) -> Option<Arc<RwLock<dyn Plugin>>> {
        self.registry.get(name).await
    }

    /// List all registered plugins.
    pub async fn list_plugins(&self) -> Vec<PluginInfo> {
        self.registry.list().await
    }

    /// Execute commit hooks across all plugins.
    pub async fn on_commit(&self, event: &CommitEvent) -> Vec<PluginResult> {
        let hooks = self.hook_system.get_hooks(HookType::OnCommit).await;
        let mut results = Vec::new();

        if self.config.enable_parallel_hooks {
            // Parallel execution
            let mut join_set = JoinSet::new();

            for hook in hooks {
                if !hook.enabled || self.hook_system.is_plugin_disabled(&hook.plugin_name).await {
                    continue;
                }

                let plugin = match self.registry.get(&hook.plugin_name).await {
                    Some(p) => p,
                    None => continue,
                };

                let event = event.clone();
                let hook_system = Arc::clone(&self.hook_system);
                let resource_tracker = self.resource_tracker.clone();

                join_set.spawn(async move {
                    let start = Instant::now();
                    let result = tokio::time::timeout(
                        tokio::time::Duration::from_millis(5000),
                        async {
                            let mut plugin_guard = plugin.write().await;
                            plugin_guard.on_commit(&event).await
                        },
                    )
                    .await;

                    let duration = start.elapsed();
                    let timestamp = chrono::Utc::now().timestamp_nanos_opt().unwrap();

                    let output = match result {
                        Ok(Ok(())) => Ok(HookOutput::Commit(())),
                        Ok(Err(e)) => {
                            hook_system.record_error(&hook.plugin_name, timestamp).await;
                            Err(e.to_string())
                        }
                        Err(_) => {
                            hook_system.record_error(&hook.plugin_name, timestamp).await;
                            Err("timeout".to_string())
                        }
                    };

                    // Update resource tracking
                    let mut tracker = resource_tracker.write().await;
                    tracker.record_execution(&hook.plugin_name, HookType::OnCommit, duration);

                    PluginResult {
                        plugin_name: hook.plugin_name,
                        hook_type: HookType::OnCommit,
                        duration,
                        result: output,
                    }
                });
            }

            while let Some(result) = join_set.join_next().await {
                if let Ok(plugin_result) = result {
                    results.push(plugin_result);
                }
            }
        } else {
            // Sequential execution
            for hook in hooks {
                if !hook.enabled || self.hook_system.is_plugin_disabled(&hook.plugin_name).await {
                    continue;
                }

                let plugin = match self.registry.get(&hook.plugin_name).await {
                    Some(p) => p,
                    None => continue,
                };

                let start = Instant::now();
                let result = tokio::time::timeout(
                    tokio::time::Duration::from_millis(5000),
                    async {
                        let mut plugin_guard = plugin.write().await;
                        plugin_guard.on_commit(event).await
                    },
                )
                .await;

                let duration = start.elapsed();
                let timestamp = chrono::Utc::now().timestamp_nanos_opt().unwrap();

                let output = match result {
                    Ok(Ok(())) => Ok(HookOutput::Commit(())),
                    Ok(Err(e)) => {
                        self.hook_system
                            .record_error(&hook.plugin_name, timestamp)
                            .await;
                        Err(e.to_string())
                    }
                    Err(_) => {
                        self.hook_system
                            .record_error(&hook.plugin_name, timestamp)
                            .await;
                        Err("timeout".to_string())
                    }
                };

                // Update resource tracking
                let mut tracker = self.resource_tracker.write().await;
                tracker.record_execution(&hook.plugin_name, HookType::OnCommit, duration);

                results.push(PluginResult {
                    plugin_name: hook.plugin_name,
                    hook_type: HookType::OnCommit,
                    duration,
                    result: output,
                });
            }
        }

        results
    }

    /// Execute query hooks and return first optimization.
    pub async fn on_query(&self, event: &QueryEvent) -> QueryResponse {
        let hooks = self.hook_system.get_hooks(HookType::OnQuery).await;

        for hook in hooks {
            if !hook.enabled || self.hook_system.is_plugin_disabled(&hook.plugin_name).await {
                continue;
            }

            let plugin = match self.registry.get(&hook.plugin_name).await {
                Some(p) => p,
                None => continue,
            };

            let start = Instant::now();
            let result = tokio::time::timeout(
                tokio::time::Duration::from_millis(500),
                async {
                    let mut plugin_guard = plugin.write().await;
                    plugin_guard.on_query(event).await
                },
            )
            .await;

            let duration = start.elapsed();
            let timestamp = chrono::Utc::now().timestamp_nanos_opt().unwrap();

            let output = match result {
                Ok(Ok(response)) => {
                    // Update resource tracking on success
                    let mut tracker = self.resource_tracker.write().await;
                    tracker.record_execution(&hook.plugin_name, HookType::OnQuery, duration);

                    // Return first non-PassThrough response
                    match response {
                        QueryResponse::PassThrough => continue,
                        other => return other,
                    }
                }
                Ok(Err(e)) => {
                    self.hook_system
                        .record_error(&hook.plugin_name, timestamp)
                        .await;
                    tracing::warn!(
                        plugin_name = hook.plugin_name,
                        error = %e,
                        "Query hook failed"
                    );
                    continue;
                }
                Err(_) => {
                    self.hook_system
                        .record_error(&hook.plugin_name, timestamp)
                        .await;
                    tracing::warn!(
                        plugin_name = hook.plugin_name,
                        "Query hook timeout"
                    );
                    continue;
                }
            };
        }

        // All plugins passed through or failed
        QueryResponse::PassThrough
    }

    /// Execute schedule hooks across all plugins.
    pub async fn on_schedule(&self, event: &ScheduleEvent) -> Vec<PluginResult> {
        let hooks = self.hook_system.get_hooks(HookType::OnSchedule).await;
        let mut results = Vec::new();

        // Similar to on_commit, but with longer timeout
        let mut join_set = JoinSet::new();

        for hook in hooks {
            if !hook.enabled || self.hook_system.is_plugin_disabled(&hook.plugin_name).await {
                continue;
            }

            let plugin = match self.registry.get(&hook.plugin_name).await {
                Some(p) => p,
                None => continue,
            };

            let event = event.clone();
            let hook_system = Arc::clone(&self.hook_system);
            let resource_tracker = self.resource_tracker.clone();
            let max_duration = event.resource_limits.max_duration;

            join_set.spawn(async move {
                let start = Instant::now();
                let result = tokio::time::timeout(max_duration, async {
                    let mut plugin_guard = plugin.write().await;
                    plugin_guard.on_schedule(&event).await
                })
                .await;

                let duration = start.elapsed();
                let timestamp = chrono::Utc::now().timestamp_nanos_opt().unwrap();

                let output = match result {
                    Ok(Ok(())) => Ok(HookOutput::Schedule(())),
                    Ok(Err(e)) => {
                        hook_system.record_error(&hook.plugin_name, timestamp).await;
                        Err(e.to_string())
                    }
                    Err(_) => {
                        hook_system.record_error(&hook.plugin_name, timestamp).await;
                        Err("timeout".to_string())
                    }
                };

                // Update resource tracking
                let mut tracker = resource_tracker.write().await;
                tracker.record_execution(&hook.plugin_name, HookType::OnSchedule, duration);

                PluginResult {
                    plugin_name: hook.plugin_name,
                    hook_type: HookType::OnSchedule,
                    duration,
                    result: output,
                }
            });
        }

        while let Some(result) = join_set.join_next().await {
            if let Ok(plugin_result) = result {
                results.push(plugin_result);
            }
        }

        results
    }

    /// Get plugin resource usage.
    pub async fn get_resource_usage(&self, plugin_name: &str) -> Option<PluginResourceUsage> {
        self.registry.get_resource_usage(plugin_name).await
    }

    /// Enable a plugin.
    pub async fn enable_plugin(&self, name: &str) -> Result<()> {
        self.registry.enable(name).await?;
        self.hook_system.enable_plugin(name).await;
        Ok(())
    }

    /// Disable a plugin.
    pub async fn disable_plugin(&self, name: &str) -> Result<()> {
        self.registry.disable(name).await?;
        self.hook_system.disable_plugin(name).await;
        Ok(())
    }
}

impl Default for PluginManager {
    fn default() -> Self {
        Self::new(PluginManagerConfig::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_plugin_manager_registration() {
        let manager = PluginManager::new(PluginManagerConfig::default());

        // Note: This test would need a mock plugin implementation
        // For now, we just verify the manager is created
        assert_eq!(manager.list_plugins().await.len(), 0);
    }

    #[tokio::test]
    async fn test_on_commit_empty() {
        let manager = PluginManager::new(PluginManagerConfig::default());

        let event = CommitEvent {
            txn_id: crate::types::TransactionId::new(1),
            lsn: crate::types::Lsn::new(1),
            mutations: Vec::new(),
            timestamp: chrono::Utc::now().timestamp_nanos_opt().unwrap(),
            metadata: HashMap::new(),
        };

        let results = manager.on_commit(&event).await;
        assert_eq!(results.len(), 0);
    }

    #[tokio::test]
    async fn test_on_query_passthrough() {
        let manager = PluginManager::new(PluginManagerConfig::default());

        let event = QueryEvent {
            query: "SELECT * FROM test".to_string(),
            query_type: QueryType::RangeScan,
            estimated_cost: 100.0,
            available_cartridges: Vec::new(),
            constraints: QueryConstraints {
                max_latency_ms: 1000,
                max_cost: 1000.0,
                prefer_accuracy: true,
            },
        };

        let response = manager.on_query(&event).await;
        assert!(matches!(response, QueryResponse::PassThrough));
    }
}
