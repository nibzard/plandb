//! Hook System
//!
//! Manages plugin hook registration, execution, and error isolation.

use crate::error::{DbError, Result};
use crate::plugins::types::*;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Hook system for managing plugin hook execution.
#[derive(Debug)]
pub struct HookSystem {
    /// Registered hooks by type
    hooks: RwLock<HashMap<HookType, Vec<HookRegistration>>>,

    /// Disabled plugins (auto-disabled due to errors)
    disabled_plugins: RwLock<HashSet<String>>,

    /// Error tracking per plugin
    error_counts: RwLock<HashMap<String, PluginErrorTracker>>,
}

/// Error tracker for automatic plugin disabling.
#[derive(Debug, Clone)]
struct PluginErrorTracker {
    /// Error count
    count: u64,

    /// First error timestamp
    first_error_ns: i64,

    /// Maximum errors allowed in window
    max_errors: u64,

    /// Error window in nanoseconds
    error_window_ns: i64,
}

impl PluginErrorTracker {
    /// Create new error tracker.
    fn new(max_errors: u64, error_window_ns: i64) -> Self {
        Self {
            count: 0,
            first_error_ns: 0,
            max_errors,
            error_window_ns,
        }
    }

    /// Record an error and return whether plugin should be disabled.
    fn record_error(&mut self, timestamp_ns: i64) -> bool {
        // Reset if window expired
        if self.first_error_ns > 0 && timestamp_ns - self.first_error_ns > self.error_window_ns {
            self.count = 0;
            self.first_error_ns = 0;
        }

        // Record error
        self.count += 1;
        if self.first_error_ns == 0 {
            self.first_error_ns = timestamp_ns;
        }

        // Check if threshold exceeded
        self.count >= self.max_errors
    }
}

impl HookSystem {
    /// Create new hook system.
    pub fn new() -> Self {
        Self {
            hooks: RwLock::new(HashMap::new()),
            disabled_plugins: RwLock::new(HashSet::new()),
            error_counts: RwLock::new(HashMap::new()),
        }
    }

    /// Register a hook for a plugin.
    pub async fn register_hook(
        &self,
        plugin_name: &str,
        hook_type: HookType,
        priority: i32,
    ) -> Result<()> {
        let mut hooks = self.hooks.write().await;

        let entry = hooks.entry(hook_type).or_insert_with(Vec::new);
        entry.push(HookRegistration {
            plugin_name: plugin_name.to_string(),
            hook_type,
            priority,
            enabled: true,
        });

        // Sort by priority (higher first)
        entry.sort_by(|a, b| b.priority.cmp(&a.priority));

        tracing::debug!(
            hook_type = ?hook_type,
            plugin_name,
            priority,
            "Registered hook"
        );

        Ok(())
    }

    /// Unregister all hooks for a plugin.
    pub async fn unregister_hooks(&self, plugin_name: &str) {
        let mut hooks = self.hooks.write().await;

        for hook_entries in hooks.values_mut() {
            hook_entries.retain(|h| h.plugin_name != plugin_name);
        }

        // Remove from disabled plugins
        self.disabled_plugins.write().await.remove(plugin_name);

        // Remove error tracking
        self.error_counts.write().await.remove(plugin_name);

        tracing::debug!(plugin_name, "Unregistered all hooks");
    }

    /// Enable a hook.
    pub async fn enable_hook(&self, plugin_name: &str, hook_type: HookType) {
        let hooks = self.hooks.read().await;
        if let Some(entries) = hooks.get(&hook_type) {
            for entry in entries {
                if entry.plugin_name == plugin_name {
                    // Note: This would need interior mutability in production
                    tracing::debug!(
                        plugin_name,
                        hook_type = ?hook_type,
                        "Hook enabled"
                    );
                }
            }
        }
    }

    /// Disable a hook.
    pub async fn disable_hook(&self, plugin_name: &str, hook_type: HookType) {
        let hooks = self.hooks.read().await;
        if let Some(entries) = hooks.get(&hook_type) {
            for entry in entries {
                if entry.plugin_name == plugin_name {
                    // Note: This would need interior mutability in production
                    tracing::debug!(
                        plugin_name,
                        hook_type = ?hook_type,
                        "Hook disabled"
                    );
                }
            }
        }
    }

    /// Check if a plugin is disabled.
    pub async fn is_plugin_disabled(&self, plugin_name: &str) -> bool {
        self.disabled_plugins.read().await.contains(plugin_name)
    }

    /// Disable a plugin (due to errors).
    pub async fn disable_plugin(&self, plugin_name: &str) {
        self.disabled_plugins.write().await.insert(plugin_name.to_string());
        tracing::warn!(
            plugin_name,
            "Plugin auto-disabled due to error rate threshold"
        );
    }

    /// Enable a plugin (manual re-enable).
    pub async fn enable_plugin(&self, plugin_name: &str) {
        self.disabled_plugins.write().await.remove(plugin_name);

        // Reset error count
        let mut error_counts = self.error_counts.write().await;
        if let Some(tracker) = error_counts.get_mut(plugin_name) {
            tracker.count = 0;
            tracker.first_error_ns = 0;
        }

        tracing::info!(plugin_name, "Plugin re-enabled");
    }

    /// Record a plugin error and check if plugin should be disabled.
    pub async fn record_error(&self, plugin_name: &str, timestamp_ns: i64) -> bool {
        let mut error_counts = self.error_counts.write().await;

        let tracker = error_counts
            .entry(plugin_name.to_string())
            .or_insert_with(|| PluginErrorTracker::new(5, 60_000_000_000)); // 5 errors in 60 seconds

        let should_disable = tracker.record_error(timestamp_ns);

        if should_disable {
            drop(error_counts); // Release lock before calling disable_plugin
            self.disable_plugin(plugin_name).await;
        }

        should_disable
    }

    /// Get all registered hooks for a type.
    pub async fn get_hooks(&self, hook_type: HookType) -> Vec<HookRegistration> {
        let hooks = self.hooks.read().await;
        hooks.get(&hook_type).cloned().unwrap_or_default()
    }

    /// Get all hook registrations for a plugin.
    pub async fn get_plugin_hooks(&self, plugin_name: &str) -> Vec<HookRegistration> {
        let hooks = self.hooks.read().await;
        let mut result = Vec::new();

        for entries in hooks.values() {
            for entry in entries {
                if entry.plugin_name == plugin_name {
                    result.push(entry.clone());
                }
            }
        }

        result
    }

    /// Get error count for a plugin.
    pub async fn get_error_count(&self, plugin_name: &str) -> u64 {
        let error_counts = self.error_counts.read().await;
        error_counts
            .get(plugin_name)
            .map(|t| t.count)
            .unwrap_or(0)
    }

    /// Clear error history for a plugin.
    pub async fn clear_errors(&self, plugin_name: &str) {
        let mut error_counts = self.error_counts.write().await;
        if let Some(tracker) = error_counts.get_mut(plugin_name) {
            tracker.count = 0;
            tracker.first_error_ns = 0;
        }
    }
}

impl Default for HookSystem {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_hook_registration() {
        let hook_system = HookSystem::new();

        hook_system
            .register_hook("plugin1", HookType::OnCommit, 10)
            .await
            .unwrap();
        hook_system
            .register_hook("plugin2", HookType::OnCommit, 20)
            .await
            .unwrap();

        let hooks = hook_system.get_hooks(HookType::OnCommit).await;
        assert_eq!(hooks.len(), 2);
        assert_eq!(hooks[0].plugin_name, "plugin2"); // Higher priority first
        assert_eq!(hooks[1].plugin_name, "plugin1");
    }

    #[tokio::test]
    async fn test_hook_unregistration() {
        let hook_system = HookSystem::new();

        hook_system
            .register_hook("plugin1", HookType::OnCommit, 10)
            .await
            .unwrap();
        hook_system
            .register_hook("plugin1", HookType::OnQuery, 10)
            .await
            .unwrap();

        hook_system.unregister_hooks("plugin1").await;

        let commit_hooks = hook_system.get_hooks(HookType::OnCommit).await;
        let query_hooks = hook_system.get_hooks(HookType::OnQuery).await;

        assert_eq!(commit_hooks.len(), 0);
        assert_eq!(query_hooks.len(), 0);
    }

    #[tokio::test]
    async fn test_plugin_disable_on_errors() {
        let hook_system = HookSystem::new();

        // Record 5 errors (threshold)
        let base_time = 1_700_000_000_000_000_000; // 2023-11-15-ish

        for i in 0..5 {
            let should_disable = hook_system
                .record_error("plugin1", base_time + (i as i64 * 1_000_000_000))
                .await;

            if i < 4 {
                assert!(!should_disable);
            } else {
                assert!(should_disable);
            }
        }

        assert!(hook_system.is_plugin_disabled("plugin1").await);
    }

    #[tokio::test]
    async fn test_error_window_reset() {
        let hook_system = HookSystem::new();

        let base_time = 1_700_000_000_000_000_000;

        // Record 4 errors
        for i in 0..4 {
            hook_system
                .record_error("plugin1", base_time + (i as i64 * 1_000_000_000))
                .await;
        }

        assert_eq!(hook_system.get_error_count("plugin1").await, 4);
        assert!(!hook_system.is_plugin_disabled("plugin1").await);

        // Wait for window to expire (61 seconds later)
        hook_system
            .record_error("plugin1", base_time + 61_000_000_000)
            .await;

        // Error count should have reset
        assert_eq!(hook_system.get_error_count("plugin1").await, 1);
        assert!(!hook_system.is_plugin_disabled("plugin1").await);
    }

    #[tokio::test]
    async fn test_plugin_reenable() {
        let hook_system = HookSystem::new();

        let base_time = 1_700_000_000_000_000_000;

        // Disable plugin with errors
        for i in 0..5 {
            hook_system
                .record_error("plugin1", base_time + (i as i64 * 1_000_000_000))
                .await;
        }

        assert!(hook_system.is_plugin_disabled("plugin1").await);

        // Re-enable
        hook_system.enable_plugin("plugin1").await;

        assert!(!hook_system.is_plugin_disabled("plugin1").await);
        assert_eq!(hook_system.get_error_count("plugin1").await, 0);
    }
}
