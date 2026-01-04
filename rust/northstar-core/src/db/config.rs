//! Database configuration options.
//!
//! Provides configuration for database behavior including WAL settings,
//! cache sizes, and other tunable parameters.

/// Configuration options for the database.
///
/// # Example
///
/// ```rust
/// use northstar_core::db::DbConfigBuilder;
///
/// let config = DbConfigBuilder::new()
///     .enable_wal(true)
///     .build();
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct DbConfig {
    /// Enable Write-Ahead Log for durability
    pub enable_wal: bool,

    /// Cache size in number of pages (0 = unlimited)
    pub cache_size_pages: usize,

    /// Sync WAL after each commit (false = fsync batching)
    pub sync_on_commit: bool,

    /// Auto-checkpoint interval (0 = manual only)
    pub auto_checkpoint_interval_bytes: u64,
}

impl Default for DbConfig {
    fn default() -> Self {
        Self {
            enable_wal: true,
            cache_size_pages: 1000,
            sync_on_commit: true,
            auto_checkpoint_interval_bytes: 0,
        }
    }
}

/// Builder for creating database configuration.
///
/// # Example
///
/// ```rust
/// use northstar_core::db::DbConfigBuilder;
///
/// let config = DbConfigBuilder::new()
///     .enable_wal(true)
///     .cache_size_pages(2000)
///     .sync_on_commit(false)
///     .build();
/// ```
#[derive(Debug, Clone, Default)]
pub struct DbConfigBuilder {
    config: DbConfig,
}

impl DbConfigBuilder {
    /// Create a new builder with default configuration.
    pub fn new() -> Self {
        Self {
            config: DbConfig::default(),
        }
    }

    /// Enable or disable Write-Ahead Log.
    ///
    /// When enabled, all writes are logged before being applied to the database,
    /// providing durability and crash recovery.
    pub fn enable_wal(mut self, enable: bool) -> Self {
        self.config.enable_wal = enable;
        self
    }

    /// Set the cache size in number of pages.
    ///
    /// A value of 0 means unlimited cache (subject to available memory).
    pub fn cache_size_pages(mut self, size: usize) -> Self {
        self.config.cache_size_pages = size;
        self
    }

    /// Set whether to sync WAL after each commit.
    ///
    /// When true, guarantees durability but may impact performance.
    /// When false, uses fsync batching for better throughput.
    pub fn sync_on_commit(mut self, sync: bool) -> Self {
        self.config.sync_on_commit = sync;
        self
    }

    /// Set the auto-checkpoint interval in bytes.
    ///
    /// When non-zero, the WAL will be automatically checkpointed after
    /// this many bytes have been written. A value of 0 means manual
    /// checkpointing only.
    pub fn auto_checkpoint_interval_bytes(mut self, bytes: u64) -> Self {
        self.config.auto_checkpoint_interval_bytes = bytes;
        self
    }

    /// Build the configuration.
    pub fn build(self) -> DbConfig {
        self.config
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = DbConfig::default();
        assert!(config.enable_wal);
        assert_eq!(config.cache_size_pages, 1000);
        assert!(config.sync_on_commit);
        assert_eq!(config.auto_checkpoint_interval_bytes, 0);
    }

    #[test]
    fn test_builder_default() {
        let config = DbConfigBuilder::new().build();
        assert_eq!(config, DbConfig::default());
    }

    #[test]
    fn test_builder_enable_wal() {
        let config = DbConfigBuilder::new()
            .enable_wal(false)
            .build();

        assert!(!config.enable_wal);
    }

    #[test]
    fn test_builder_cache_size() {
        let config = DbConfigBuilder::new()
            .cache_size_pages(5000)
            .build();

        assert_eq!(config.cache_size_pages, 5000);
    }

    #[test]
    fn test_builder_sync_on_commit() {
        let config = DbConfigBuilder::new()
            .sync_on_commit(false)
            .build();

        assert!(!config.sync_on_commit);
    }

    #[test]
    fn test_builder_auto_checkpoint() {
        let config = DbConfigBuilder::new()
            .auto_checkpoint_interval_bytes(1024 * 1024)
            .build();

        assert_eq!(config.auto_checkpoint_interval_bytes, 1024 * 1024);
    }

    #[test]
    fn test_builder_chaining() {
        let config = DbConfigBuilder::new()
            .enable_wal(false)
            .cache_size_pages(2000)
            .sync_on_commit(false)
            .auto_checkpoint_interval_bytes(1024)
            .build();

        assert!(!config.enable_wal);
        assert_eq!(config.cache_size_pages, 2000);
        assert!(!config.sync_on_commit);
        assert_eq!(config.auto_checkpoint_interval_bytes, 1024);
    }

    #[test]
    fn test_config_clone() {
        let config = DbConfigBuilder::new()
            .cache_size_pages(3000)
            .build();

        let config2 = config.clone();
        assert_eq!(config, config2);
    }
}
