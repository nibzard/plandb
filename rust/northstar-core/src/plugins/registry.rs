//! Plugin Registry
//!
//! Manages plugin registration, lookup, and lifecycle.

use crate::error::{DbError, Error, Result};
use crate::plugins::types::*;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Plugin registry for managing registered plugins.
#[derive(Debug)]
pub struct PluginRegistry {
    /// Registered plugins by name (wrapped in RwLock for interior mutability)
    plugins: RwLock<HashMap<String, Arc<RwLock<dyn Plugin>>>>,

    /// Plugin metadata
    metadata: RwLock<HashMap<String, PluginInfo>>,

    /// Maximum number of plugins allowed
    max_plugins: usize,
}

impl PluginRegistry {
    /// Create new plugin registry.
    pub fn new(max_plugins: usize) -> Self {
        Self {
            plugins: RwLock::new(HashMap::new()),
            metadata: RwLock::new(HashMap::new()),
            max_plugins,
        }
    }

    /// Register a plugin.
    pub async fn register(&self, plugin: Arc<RwLock<dyn Plugin>>) -> Result<PluginInfo> {
        // Get plugin metadata
        let (name, version, deps) = {
            let plugin_guard = plugin.read().await;
            let name = plugin_guard.name().to_string();
            let version = plugin_guard.version().to_string();
            let deps = plugin_guard.dependencies().iter().map(|s| s.to_string()).collect::<Vec<_>>();
            drop(plugin_guard); // Release lock before continuing
            (name, version, deps)
        };

        // Check if already registered
        {
            let plugins = self.plugins.read().await;
            if plugins.contains_key(&name) {
                return Err(Error::Plugin(crate::error::PluginError::LoadFailed {
                    plugin: name.clone(),
                }));
            }

            // Check max plugins limit
            if plugins.len() >= self.max_plugins {
                return Err(Error::Plugin(crate::error::PluginError::ValidationError {
                    plugin: format!("maximum plugin limit ({}) reached", self.max_plugins),
                }));
            }
        }

        // Check dependencies
        {
            let plugins = self.plugins.read().await;
            for dep in deps.iter() {
                if !plugins.contains_key(dep.as_str()) {
                    return Err(Error::Plugin(crate::error::PluginError::ValidationError {
                        plugin: format!("'{}' depends on '{}' which is not registered", name, dep),
                    }));
                }
            }
        }

        // Add plugin
        {
            let mut plugins = self.plugins.write().await;
            plugins.insert(name.clone(), plugin);
        }

        // Create metadata
        let info = PluginInfo {
            name: name.clone(),
            version: version.clone(),
            enabled: true,
            hooks: Vec::new(),
            resource_usage: PluginResourceUsage {
                plugin_name: name.clone(),
                memory_bytes: 0,
                cpu_time_ns: 0,
                hook_execution_count: HashMap::new(),
                last_execution: HashMap::new(),
                error_count: 0,
            },
        };

        {
            let mut metadata = self.metadata.write().await;
            metadata.insert(name.clone(), info.clone());
        }

        tracing::info!(
            plugin_name = name,
            version,
            "Plugin registered"
        );

        Ok(info)
    }

    /// Unregister a plugin.
    pub async fn unregister(&self, name: &str) -> Result<Arc<RwLock<dyn Plugin>>> {
        // Remove plugin
        let plugin = {
            let mut plugins = self.plugins.write().await;
            plugins.remove(name).ok_or_else(|| {
                Error::Plugin(crate::error::PluginError::NotRegistered {
                    plugin: name.to_string(),
                })
            })?
        };

        // Remove metadata
        let mut metadata = self.metadata.write().await;
        metadata.remove(name);

        tracing::info!(plugin_name = name, "Plugin unregistered");

        Ok(plugin)
    }

    /// Get a plugin by name.
    pub async fn get(&self, name: &str) -> Option<Arc<RwLock<dyn Plugin>>> {
        let plugins = self.plugins.read().await;
        plugins.get(name).cloned()
    }

    /// Check if a plugin is registered.
    pub async fn contains(&self, name: &str) -> bool {
        let plugins = self.plugins.read().await;
        plugins.contains_key(name)
    }

    /// List all registered plugins.
    pub async fn list(&self) -> Vec<PluginInfo> {
        let metadata = self.metadata.read().await;
        metadata.values().cloned().collect()
    }

    /// Get plugin count.
    pub async fn count(&self) -> usize {
        let plugins = self.plugins.read().await;
        plugins.len()
    }

    /// Update plugin metadata.
    pub async fn update_metadata(&self, info: PluginInfo) {
        let mut metadata = self.metadata.write().await;
        metadata.insert(info.name.clone(), info);
    }

    /// Get plugin metadata.
    pub async fn get_metadata(&self, name: &str) -> Option<PluginInfo> {
        let metadata = self.metadata.read().await;
        metadata.get(name).cloned()
    }

    /// Enable a plugin.
    pub async fn enable(&self, name: &str) -> Result<()> {
        let mut metadata = self.metadata.write().await;
        let info = metadata
            .get_mut(name)
            .ok_or_else(|| Error::Plugin(crate::error::PluginError::NotRegistered {
                plugin: name.to_string(),
            }))?;

        info.enabled = true;

        tracing::info!(plugin_name = name, "Plugin enabled");
        Ok(())
    }

    /// Disable a plugin.
    pub async fn disable(&self, name: &str) -> Result<()> {
        let mut metadata = self.metadata.write().await;
        let info = metadata
            .get_mut(name)
            .ok_or_else(|| Error::Plugin(crate::error::PluginError::NotRegistered {
                plugin: name.to_string(),
            }))?;

        info.enabled = false;

        tracing::info!(plugin_name = name, "Plugin disabled");
        Ok(())
    }

    /// Check if a plugin is enabled.
    pub async fn is_enabled(&self, name: &str) -> bool {
        let metadata = self.metadata.read().await;
        metadata
            .get(name)
            .map(|info| info.enabled)
            .unwrap_or(false)
    }

    /// Update plugin resource usage.
    pub async fn update_resource_usage(&self, usage: PluginResourceUsage) {
        let mut metadata = self.metadata.write().await;
        if let Some(info) = metadata.get_mut(&usage.plugin_name) {
            info.resource_usage = usage;
        }
    }

    /// Get plugin resource usage.
    pub async fn get_resource_usage(&self, name: &str) -> Option<PluginResourceUsage> {
        let metadata = self.metadata.read().await;
        metadata.get(name).map(|info| info.resource_usage.clone())
    }

    /// Add hook registration to plugin metadata.
    pub async fn add_hook(&self, plugin_name: &str, hook: HookRegistration) {
        let mut metadata = self.metadata.write().await;
        if let Some(info) = metadata.get_mut(plugin_name) {
            info.hooks.push(hook);
        }
    }

    /// Clear all plugins (for testing).
    #[cfg(test)]
    pub async fn clear(&self) {
        let mut plugins = self.plugins.write().await;
        let mut metadata = self.metadata.write().await;
        plugins.clear();
        metadata.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;

    // Test plugin implementation
    #[derive(Debug)]
    struct TestPlugin {
        name: String,
        version: String,
    }

    #[async_trait]
    impl Plugin for TestPlugin {
        fn name(&self) -> &str {
            &self.name
        }

        fn version(&self) -> &str {
            &self.version
        }

        async fn on_init(&mut self, _context: &PluginContext) -> Result<()> {
            Ok(())
        }

        async fn on_commit(&mut self, _event: &CommitEvent) -> Result<()> {
            Ok(())
        }

        async fn on_query(&mut self, _event: &QueryEvent) -> Result<QueryResponse> {
            Ok(QueryResponse::PassThrough)
        }

        async fn on_schedule(&mut self, _event: &ScheduleEvent) -> Result<()> {
            Ok(())
        }

        async fn on_shutdown(&mut self) -> Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn test_plugin_registration() {
        let registry = PluginRegistry::new(10);

        let plugin = Arc::new(RwLock::new(TestPlugin {
            name: "test_plugin".to_string(),
            version: "1.0.0".to_string(),
        }));

        let info = registry.register(plugin).await.unwrap();

        assert_eq!(info.name, "test_plugin");
        assert_eq!(info.version, "1.0.0");
        assert!(info.enabled);

        assert!(registry.contains("test_plugin").await);
        assert_eq!(registry.count().await, 1);
    }

    #[tokio::test]
    async fn test_duplicate_registration() {
        let registry = PluginRegistry::new(10);

        let plugin1 = Arc::new(RwLock::new(TestPlugin {
            name: "test_plugin".to_string(),
            version: "1.0.0".to_string(),
        }));

        let plugin2 = Arc::new(RwLock::new(TestPlugin {
            name: "test_plugin".to_string(),
            version: "2.0.0".to_string(),
        }));

        registry.register(plugin1).await.unwrap();

        let result = registry.register(plugin2).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_max_plugins_limit() {
        let registry = PluginRegistry::new(2);

        let plugin1 = Arc::new(RwLock::new(TestPlugin {
            name: "plugin1".to_string(),
            version: "1.0.0".to_string(),
        }));

        let plugin2 = Arc::new(RwLock::new(TestPlugin {
            name: "plugin2".to_string(),
            version: "1.0.0".to_string(),
        }));

        let plugin3 = Arc::new(RwLock::new(TestPlugin {
            name: "plugin3".to_string(),
            version: "1.0.0".to_string(),
        }));

        registry.register(plugin1).await.unwrap();
        registry.register(plugin2).await.unwrap();

        let result = registry.register(plugin3).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_plugin_unregistration() {
        let registry = PluginRegistry::new(10);

        let plugin = Arc::new(RwLock::new(TestPlugin {
            name: "test_plugin".to_string(),
            version: "1.0.0".to_string(),
        }));

        registry.register(plugin).await.unwrap();

        let removed = registry.unregister("test_plugin").await.unwrap();
        let removed_guard = removed.read().await;
        assert_eq!(removed_guard.name(), "test_plugin");

        assert!(!registry.contains("test_plugin").await);
        assert_eq!(registry.count().await, 0);
    }

    #[tokio::test]
    async fn test_plugin_enable_disable() {
        let registry = PluginRegistry::new(10);

        let plugin = Arc::new(RwLock::new(TestPlugin {
            name: "test_plugin".to_string(),
            version: "1.0.0".to_string(),
        }));

        registry.register(plugin).await.unwrap();

        assert!(registry.is_enabled("test_plugin").await);

        registry.disable("test_plugin").await.unwrap();
        assert!(!registry.is_enabled("test_plugin").await);

        registry.enable("test_plugin").await.unwrap();
        assert!(registry.is_enabled("test_plugin").await);
    }

    #[tokio::test]
    async fn test_list_plugins() {
        let registry = PluginRegistry::new(10);

        let plugin1 = Arc::new(RwLock::new(TestPlugin {
            name: "plugin1".to_string(),
            version: "1.0.0".to_string(),
        }));

        let plugin2 = Arc::new(RwLock::new(TestPlugin {
            name: "plugin2".to_string(),
            version: "1.0.0".to_string(),
        }));

        registry.register(plugin1).await.unwrap();
        registry.register(plugin2).await.unwrap();

        let plugins = registry.list().await;
        assert_eq!(plugins.len(), 2);

        let names: Vec<_> = plugins.iter().map(|p| &p.name).collect();
        assert!(names.contains(&&"plugin1".to_string()));
        assert!(names.contains(&&"plugin2".to_string()));
    }

    #[tokio::test]
    async fn test_dependency_check() {
        // This test would need plugins with actual dependencies
        // For now, we just verify the dependency-free case works
        let registry = PluginRegistry::new(10);

        let plugin = Arc::new(RwLock::new(TestPlugin {
            name: "test_plugin".to_string(),
            version: "1.0.0".to_string(),
        }));

        // No dependencies, should succeed
        registry.register(plugin).await.unwrap();
    }
}
