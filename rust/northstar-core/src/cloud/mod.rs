//! Cloud Storage Adapters for NorthstarDB
//!
//! This module provides cloud storage integration for backups, snapshots,
//! and WAL archives. Supports AWS S3, Google Cloud Storage, Azure Blob Storage,
//! and local filesystem (for testing and hybrid deployments).
//!
//! # Architecture
//!
//! The cloud storage layer is organized into:
//! - **types**: Common configuration and error types
//! - **adapter**: Unified CloudStorageAdapter trait and implementations
//! - **backup**: CloudBackupManager for backup synchronization
//! - **retry**: Retry logic with exponential backoff for all operations
//! - **s3**: AWS S3 adapter
//! - **gcs**: Google Cloud Storage adapter
//! - **azure**: Azure Blob Storage adapter
//!
//! # Retry Strategy
//!
//! All cloud operations automatically use retry logic with exponential backoff
//! to handle transient failures:
//!
//! - **Exponential Backoff**: Delay doubles with each retry (base_delay * 2^attempt)
//! - **Full Jitter**: Random delays prevent thundering herd problems
//! - **Max Delay Caps**: Backoff capped to prevent excessive waits
//! - **Retryable Errors**: Only retry transient errors (network, 5xx, throttling)
//! - **Per-Operation Policies**: Different retry limits for upload, download, delete
//!
//! Example retry policies:
//! ```ignore
//! use northstar_core::cloud::RetryPolicy;
//!
//! // Upload: 5 attempts, 100ms base, 30s max
//! let upload_policy = RetryPolicy::upload();
//!
//! // Download: 10 attempts, 100ms base, 30s max (aggressive)
//! let download_policy = RetryPolicy::download();
//!
//! // Delete: 3 attempts, 200ms base, 10s max (conservative)
//! let delete_policy = RetryPolicy::delete();
//! ```
//!
//! # Example Usage
//!
//! ```ignore
//! use northstar_core::cloud::{CloudStorageConfig, CloudStorageProvider, S3Config};
//! use northstar_core::cloud::adapter::CloudStorageAdapter;
//! use northstar_core::cloud::backup::CloudBackupManager;
//!
//! // Configure S3 storage
//! let s3_config = S3Config::new("us-east-1", "my-backups")
//!     .with_access_key("AKIAIOSFODNN7EXAMPLE")
//!     .with_secret_key("secret");
//!
//! let config = CloudStorageConfig::new(CloudStorageProvider::AwsS3)
//!     .with_s3(s3_config);
//!
//! // Create adapter and upload backup
//! let adapter = S3Adapter::new(config)?;
//! let data = std::fs::read("backup.nbk")?;
//! adapter.upload("backups/2026-01-04/backup.nbk", data, None).await?;
//! ```

pub mod adapter;
pub mod s3;
pub mod gcs;
pub mod azure;
pub mod backup;
pub mod types;
pub mod retry;

// Re-export commonly used types
pub use types::{
    CloudStorageProvider, CloudError, CloudStorageConfig,
    S3Config, GcsConfig, AzureConfig,
    CloudLocation, CloudUploadProgress, CloudDownloadProgress,
    CloudBackupMetadata, CloudBackupStub,
};
pub use adapter::{CloudStorageAdapter, LocalAdapter};
pub use s3::S3Adapter;
pub use gcs::GcsAdapter;
pub use azure::AzureAdapter;
pub use backup::{CloudBackupManager, SyncReport};
pub use retry::{RetryPolicy, with_retry};
