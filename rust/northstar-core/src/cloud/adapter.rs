//! Cloud Storage Adapter Trait
//!
//! Defines the unified interface for cloud storage providers.

use super::types::{CloudStorageConfig};

/// Cloud storage adapter trait (simplified placeholder).
///
/// This is a placeholder trait for future cloud storage integration.
/// The full implementation will support S3, GCS, Azure, and local filesystem.
pub trait CloudStorageAdapter: Send + Sync {
    /// Get the configuration for this adapter.
    fn config(&self) -> &CloudStorageConfig;
}

/// Local filesystem adapter placeholder.
pub struct LocalAdapter {
    config: CloudStorageConfig,
    _base_dir: std::path::PathBuf,
}

impl LocalAdapter {
    /// Create a new local adapter.
    pub fn new(config: CloudStorageConfig, base_dir: impl AsRef<std::path::Path>) -> Self {
        Self {
            config,
            _base_dir: base_dir.as_ref().to_path_buf(),
        }
    }
}

impl CloudStorageAdapter for LocalAdapter {
    fn config(&self) -> &CloudStorageConfig {
        &self.config
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_local_adapter_creation() {
        let config = CloudStorageConfig::new(super::super::types::CloudStorageProvider::Local);
        let adapter = LocalAdapter::new(config, std::env::temp_dir());
        assert_eq!(adapter.config().provider, super::super::types::CloudStorageProvider::Local);
    }
}
