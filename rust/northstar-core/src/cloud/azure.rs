//! Azure Blob Storage Adapter
//!
//! Placeholder implementation for Azure Blob Storage integration.

use super::adapter::CloudStorageAdapter;
use super::types::{CloudStorageConfig, CloudError};

/// Azure Blob Storage adapter (placeholder).
///
/// This is a placeholder for future Azure integration.
pub struct AzureAdapter {
    config: CloudStorageConfig,
}

impl AzureAdapter {
    /// Create a new Azure adapter from configuration.
    pub fn new(config: CloudStorageConfig) -> Result<Self, CloudError> {
        config.validate()?;
        Ok(Self { config })
    }
}

impl CloudStorageAdapter for AzureAdapter {
    fn config(&self) -> &CloudStorageConfig {
        &self.config
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_azure_adapter_creation() {
        let azure_config = super::super::types::AzureConfig::new("mystorageaccount", "my-container")
            .with_access_key("base64key==");

        let config = CloudStorageConfig::new(super::super::types::CloudStorageProvider::AzureBlob)
            .with_azure(azure_config);

        let adapter = AzureAdapter::new(config);
        assert!(adapter.is_ok());
    }
}
