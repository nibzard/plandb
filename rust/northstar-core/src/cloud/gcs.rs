//! Google Cloud Storage Adapter
//!
//! Placeholder implementation for Google Cloud Storage integration.

use super::adapter::CloudStorageAdapter;
use super::types::{CloudStorageConfig, CloudError};

/// Google Cloud Storage adapter (placeholder).
///
/// This is a placeholder for future GCS integration.
pub struct GcsAdapter {
    config: CloudStorageConfig,
}

impl GcsAdapter {
    /// Create a new GCS adapter from configuration.
    pub fn new(config: CloudStorageConfig) -> Result<Self, CloudError> {
        config.validate()?;
        Ok(Self { config })
    }
}

impl CloudStorageAdapter for GcsAdapter {
    fn config(&self) -> &CloudStorageConfig {
        &self.config
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gcs_adapter_creation() {
        let gcs_config = super::super::types::GcsConfig::new("test-bucket")
            .with_credentials_json("{}");

        let config = CloudStorageConfig::new(super::super::types::CloudStorageProvider::Gcs)
            .with_gcs(gcs_config);

        let adapter = GcsAdapter::new(config);
        assert!(adapter.is_ok());
    }
}
