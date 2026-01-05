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
//! # Multipart Upload
//!
//! Large files (>100MB) are automatically uploaded using multipart/block protocols:
//!
//! - **S3**: Multipart upload with 16MB parts (5MB min, 10,000 parts max)
//! - **GCS**: Resumable upload with 16MB chunks (5MB min)
//! - **Azure**: Block blob upload with 4MB blocks (4MB min, 50,000 blocks max)
//!
//! Multipart uploads provide:
//! - **Parallel uploads**: 4 concurrent parts by default (configurable)
//! - **Progress tracking**: Cumulative byte progress across all parts
//! - **Retry logic**: Each part retried independently with exponential backoff
//! - **Resumability**: Track uploaded parts for resume after interruption
//! - **Error handling**: Abort entire upload on critical failures
//!
//! Example with custom part size and concurrency:
//! ```ignore
//! use northstar_core::cloud::{CloudStorageConfig, CloudStorageProvider, S3Config};
//! use northstar_core::cloud::s3::S3Adapter;
//!
//! // Configure S3 with custom part size (32MB) and concurrency (8)
//! let s3_config = S3Config::new("us-east-1", "my-backups")
//!     .with_access_key("AKIAIOSFODNN7EXAMPLE")
//!     .with_secret_key("secret")
//!     .with_part_size(32 * 1024 * 1024); // 32MB parts
//!
//! let config = CloudStorageConfig::new(CloudStorageProvider::AwsS3)
//!     .with_s3(s3_config)
//!     .with_concurrency(8); // 8 concurrent uploads
//!
//! let adapter = S3Adapter::new(config).await?;
//!
//! // Upload large backup with progress callback
//! let data = std::fs::read("large-backup.nbk")?;
//! adapter.upload("backups/2026-01-05/large.nbk", &data, Some(Box::new(|uploaded, total| {
//!     println!("Progress: {}/{} bytes", uploaded, total.unwrap());
//! }))).await?;
//! ```
//!
//! # Example Usage
//!
//! ```ignore
//! use northstar_core::cloud::{CloudStorageConfig, CloudStorageProvider, S3Config};
//! use northstar_core::cloud::adapter::CloudStorageAdapter;
//! use northstar_core::cloud::backup::CloudBackupManager;
//!
//! // Configure S3 storage with encryption
//! let s3_config = S3Config::new("us-east-1", "my-backups")
//!     .with_access_key("AKIAIOSFODNN7EXAMPLE")
//!     .with_secret_key("secret");
//!
//! let encryption_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
//!
//! let config = CloudStorageConfig::new(CloudStorageProvider::AwsS3)
//!     .with_s3(s3_config)
//!     .with_encryption(encryption_key.to_string());
//!
//! // Create adapter and upload backup
//! let adapter = S3Adapter::new(config)?;
//! let data = std::fs::read("backup.nbk")?;
//! adapter.upload("backups/2026-01-04/backup.nbk", data, None).await?;
//! ```
//!
//! # Encryption at Rest
//!
//! Backup data can be encrypted with AES-256-GCM before uploading to cloud storage:
//!
//! - **Customer-provided key**: 256-bit key (64 hex chars) provided in config
//! - **Authenticated encryption**: GCM mode ensures integrity verification
//! - **Format**: [nonce: 12 bytes][tag: 16 bytes][encrypted data]
//! - **Key management**: Keys never logged or persisted by database
//!
//! Example with encryption:
//! ```ignore
//! use northstar_core::cloud::encrypt::{EncryptionConfig, encrypt_data};
//!
//! // Generate encryption key (save this securely!)
//! let key = northstar_core::cloud::encrypt::generate_encryption_key();
//! println!("Encryption key: {}", key);
//!
//! let config = EncryptionConfig::CustomerKey { key };
//!
//! // Encrypt backup data
//! let encrypted = encrypt_data(&backup_data, &config)?;
//!
//! // Upload encrypted data
//! adapter.upload("backup.enc", encrypted, None).await?;
//! ```

pub mod adapter;
pub mod s3;
pub mod gcs;
pub mod azure;
pub mod backup;
pub mod types;
pub mod retry;
pub mod encrypt;

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
pub use encrypt::{EncryptionConfig, encrypt_data, decrypt_data, encrypt_stream, decrypt_stream, generate_encryption_key};
