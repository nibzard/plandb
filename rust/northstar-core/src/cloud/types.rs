//! Cloud Storage Types
//!
//! Common types and configurations for cloud storage providers.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fmt;

/// Cloud storage provider enumeration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CloudStorageProvider {
    /// Amazon S3 or S3-compatible storage (MinIO, Wasabi, etc.)
    AwsS3,
    /// Google Cloud Storage.
    Gcs,
    /// Azure Blob Storage.
    AzureBlob,
    /// Local filesystem (for testing and hybrid deployments).
    Local,
}

impl fmt::Display for CloudStorageProvider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AwsS3 => write!(f, "aws-s3"),
            Self::Gcs => write!(f, "gcs"),
            Self::AzureBlob => write!(f, "azure-blob"),
            Self::Local => write!(f, "local"),
        }
    }
}

/// Cloud storage operation errors.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloudError {
    /// Authentication failed or credentials expired.
    AuthenticationFailed(String),
    /// Bucket/container does not exist or no access.
    BucketNotFound(String),
    /// Object key does not exist.
    ObjectNotFound(String),
    /// Insufficient permissions for operation.
    PermissionDenied(String),
    /// Storage quota or request rate limit exceeded.
    QuotaExceeded(String),
    /// Network connectivity or DNS resolution failure.
    NetworkError(String),
    /// Operation exceeded configured timeout.
    Timeout(String),
    /// Malformed request or invalid parameters.
    InvalidRequest(String),
    /// Downloaded data checksum does not match expected.
    ChecksumMismatch { expected: String, actual: String },
    /// Upload was cancelled before completion.
    UploadCancelled,
    /// Provider-specific error.
    Other(String),
}

impl fmt::Display for CloudError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AuthenticationFailed(msg) => write!(f, "Authentication failed: {}", msg),
            Self::BucketNotFound(bucket) => write!(f, "Bucket not found: {}", bucket),
            Self::ObjectNotFound(key) => write!(f, "Object not found: {}", key),
            Self::PermissionDenied(msg) => write!(f, "Permission denied: {}", msg),
            Self::QuotaExceeded(msg) => write!(f, "Quota exceeded: {}", msg),
            Self::NetworkError(msg) => write!(f, "Network error: {}", msg),
            Self::Timeout(msg) => write!(f, "Timeout: {}", msg),
            Self::InvalidRequest(msg) => write!(f, "Invalid request: {}", msg),
            Self::ChecksumMismatch { expected, actual } => {
                write!(f, "Checksum mismatch: expected {}, got {}", expected, actual)
            }
            Self::UploadCancelled => write!(f, "Upload cancelled"),
            Self::Other(msg) => write!(f, "Cloud error: {}", msg),
        }
    }
}

impl std::error::Error for CloudError {}

impl CloudError {
    /// Determine if this error is retryable.
    ///
    /// Retryable errors are transient failures that may succeed on retry:
    /// - Network errors (connection refused, timeout, DNS failure)
    /// - HTTP 5xx responses (internal server errors)
    /// - Rate limiting (429, SlowDown)
    /// - Timeouts
    ///
    /// Non-retryable errors are permanent failures:
    /// - Authentication failures (401, 403)
    /// - Not found (404)
    /// - Invalid request (400)
    /// - Checksum mismatch
    /// - Upload cancelled
    pub fn is_retryable(&self) -> bool {
        match self {
            // Network issues are retryable
            CloudError::NetworkError(_) => true,

            // Timeouts are retryable
            CloudError::Timeout(_) => true,

            // Quota exceeded is retryable only if it's rate limiting
            CloudError::QuotaExceeded(msg) => {
                let msg_lower = msg.to_lowercase();
                msg_lower.contains("rate limit")
                    || msg_lower.contains("throttl")
                    || msg_lower.contains("429")
                    || msg_lower.contains("slowdown")
            }

            // Generic errors may be retryable if they indicate transient issues
            CloudError::Other(msg) => {
                let msg_lower = msg.to_lowercase();
                msg_lower.contains("rate limit")
                    || msg_lower.contains("throttling")
                    || msg_lower.contains("5")
                    || msg_lower.contains("timeout")
                    || msg_lower.contains("connection")
            }

            // All other errors are not retryable
            CloudError::AuthenticationFailed(_) => false,
            CloudError::BucketNotFound(_) => false,
            CloudError::ObjectNotFound(_) => false,
            CloudError::PermissionDenied(_) => false,
            CloudError::InvalidRequest(_) => false,
            CloudError::ChecksumMismatch { .. } => false,
            CloudError::UploadCancelled => false,
        }
    }
}

/// Configuration for AWS S3 or S3-compatible storage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct S3Config {
    /// AWS region (e.g., "us-east-1", "eu-west-1").
    pub region: String,
    /// S3 bucket name.
    pub bucket: String,
    /// Optional key prefix for namespacing (e.g., "northstar/backups/").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_prefix: Option<String>,
    /// Custom endpoint for S3-compatible storage (MinIO, Wasabi).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
    /// AWS access key ID.
    pub access_key_id: String,
    /// AWS secret access key.
    pub secret_access_key: String,
    /// Temporary session token for IAM roles.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_token: Option<String>,
    /// Maximum retry attempts (default: 3).
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,
    /// Request timeout in seconds (default: 30).
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
    /// Use path-style addressing (true for MinIO).
    #[serde(default)]
    pub use_path_style: bool,
}

fn default_max_retries() -> u32 { 3 }
fn default_timeout() -> u64 { 30 }

impl S3Config {
    /// Create a new S3 configuration.
    pub fn new(region: impl Into<String>, bucket: impl Into<String>) -> Self {
        Self {
            region: region.into(),
            bucket: bucket.into(),
            key_prefix: None,
            endpoint: None,
            access_key_id: String::new(),
            secret_access_key: String::new(),
            session_token: None,
            max_retries: 3,
            timeout_secs: 30,
            use_path_style: false,
        }
    }

    /// Set the access key ID.
    pub fn with_access_key(mut self, key_id: impl Into<String>) -> Self {
        self.access_key_id = key_id.into();
        self
    }

    /// Set the secret access key.
    pub fn with_secret_key(mut self, secret_key: impl Into<String>) -> Self {
        self.secret_access_key = secret_key.into();
        self
    }

    /// Set a custom endpoint (for S3-compatible storage).
    pub fn with_endpoint(mut self, endpoint: impl Into<String>) -> Self {
        self.endpoint = Some(endpoint.into());
        self
    }

    /// Set the key prefix.
    pub fn with_key_prefix(mut self, prefix: impl Into<String>) -> Self {
        self.key_prefix = Some(prefix.into());
        self
    }

    /// Enable path-style addressing.
    pub fn with_path_style(mut self, use_path_style: bool) -> Self {
        self.use_path_style = use_path_style;
        self
    }

    /// Validate the configuration.
    pub fn validate(&self) -> Result<(), CloudError> {
        if self.bucket.is_empty() {
            return Err(CloudError::InvalidRequest("Bucket name cannot be empty".into()));
        }
        if self.bucket.len() < 3 || self.bucket.len() > 63 {
            return Err(CloudError::InvalidRequest("Bucket name must be 3-63 characters".into()));
        }
        if self.region.is_empty() {
            return Err(CloudError::InvalidRequest("Region cannot be empty".into()));
        }
        Ok(())
    }
}

/// Configuration for Google Cloud Storage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GcsConfig {
    /// GCS bucket name.
    pub bucket: String,
    /// Optional key prefix for namespacing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_prefix: Option<String>,
    /// Path to service account JSON credentials file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credentials_path: Option<String>,
    /// Inline service account credentials JSON.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credentials_json: Option<String>,
    /// OAuth2 bearer token (for testing).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oauth_token: Option<String>,
    /// Maximum retry attempts (default: 3).
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,
    /// Request timeout in seconds (default: 30).
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
}

impl GcsConfig {
    /// Create a new GCS configuration.
    pub fn new(bucket: impl Into<String>) -> Self {
        Self {
            bucket: bucket.into(),
            key_prefix: None,
            credentials_path: None,
            credentials_json: None,
            oauth_token: None,
            max_retries: 3,
            timeout_secs: 30,
        }
    }

    /// Set the key prefix.
    pub fn with_key_prefix(mut self, prefix: impl Into<String>) -> Self {
        self.key_prefix = Some(prefix.into());
        self
    }

    /// Set credentials from a file path.
    pub fn with_credentials_path(mut self, path: impl Into<String>) -> Self {
        self.credentials_path = Some(path.into());
        self
    }

    /// Set credentials from inline JSON.
    pub fn with_credentials_json(mut self, json: impl Into<String>) -> Self {
        self.credentials_json = Some(json.into());
        self
    }

    /// Validate the configuration.
    pub fn validate(&self) -> Result<(), CloudError> {
        if self.bucket.is_empty() {
            return Err(CloudError::InvalidRequest("Bucket name cannot be empty".into()));
        }
        let has_credentials = self.credentials_path.is_some()
            || self.credentials_json.is_some()
            || self.oauth_token.is_some();
        if !has_credentials {
            return Err(CloudError::InvalidRequest(
                "At least one of credentials_path, credentials_json, or oauth_token must be provided".into()
            ));
        }
        Ok(())
    }
}

/// Configuration for Azure Blob Storage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AzureConfig {
    /// Azure storage account name.
    pub storage_account: String,
    /// Blob container name.
    pub container: String,
    /// Optional key prefix for namespacing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_prefix: Option<String>,
    /// Storage account access key.
    pub access_key: String,
    /// Shared Access Signature token.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sas_token: Option<String>,
    /// Custom endpoint (default: *.blob.core.windows.net).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
    /// Maximum retry attempts (default: 3).
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,
    /// Request timeout in seconds (default: 30).
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
}

impl AzureConfig {
    /// Create a new Azure configuration.
    pub fn new(storage_account: impl Into<String>, container: impl Into<String>) -> Self {
        Self {
            storage_account: storage_account.into(),
            container: container.into(),
            key_prefix: None,
            access_key: String::new(),
            sas_token: None,
            endpoint: None,
            max_retries: 3,
            timeout_secs: 30,
        }
    }

    /// Set the access key.
    pub fn with_access_key(mut self, key: impl Into<String>) -> Self {
        self.access_key = key.into();
        self
    }

    /// Set the SAS token.
    pub fn with_sas_token(mut self, token: impl Into<String>) -> Self {
        self.sas_token = Some(token.into());
        self
    }

    /// Set the key prefix.
    pub fn with_key_prefix(mut self, prefix: impl Into<String>) -> Self {
        self.key_prefix = Some(prefix.into());
        self
    }

    /// Validate the configuration.
    pub fn validate(&self) -> Result<(), CloudError> {
        if self.storage_account.is_empty() || self.storage_account.len() > 24 {
            return Err(CloudError::InvalidRequest("Storage account must be 3-24 characters".into()));
        }
        if self.container.is_empty() || self.container.len() > 63 {
            return Err(CloudError::InvalidRequest("Container name must be 3-63 characters".into()));
        }
        let has_auth = !self.access_key.is_empty() || self.sas_token.is_some();
        if !has_auth {
            return Err(CloudError::InvalidRequest(
                "Either access_key or sas_token must be provided".into()
            ));
        }
        Ok(())
    }
}

/// Unified configuration for any cloud storage provider.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudStorageConfig {
    /// Cloud storage provider.
    pub provider: CloudStorageProvider,
    /// S3 configuration (required when provider is AwsS3).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub s3: Option<S3Config>,
    /// GCS configuration (required when provider is Gcs).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gcs: Option<GcsConfig>,
    /// Azure configuration (required when provider is AzureBlob).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub azure: Option<AzureConfig>,
    /// Multipart upload part size in MB (default: 16).
    #[serde(default = "default_part_size")]
    pub upload_part_size_mb: usize,
    /// Maximum concurrent upload threads (default: 4).
    #[serde(default = "default_max_concurrent")]
    pub max_concurrent_uploads: usize,
    /// Download buffer size in MB (default: 16).
    #[serde(default = "default_part_size")]
    pub download_part_size_mb: usize,
}

fn default_part_size() -> usize { 16 }
fn default_max_concurrent() -> usize { 4 }

impl CloudStorageConfig {
    /// Create a new configuration for the given provider.
    pub fn new(provider: CloudStorageProvider) -> Self {
        Self {
            provider,
            s3: None,
            gcs: None,
            azure: None,
            upload_part_size_mb: 16,
            max_concurrent_uploads: 4,
            download_part_size_mb: 16,
        }
    }

    /// Set S3 configuration.
    pub fn with_s3(mut self, config: S3Config) -> Self {
        self.s3 = Some(config);
        self
    }

    /// Set GCS configuration.
    pub fn with_gcs(mut self, config: GcsConfig) -> Self {
        self.gcs = Some(config);
        self
    }

    /// Set Azure configuration.
    pub fn with_azure(mut self, config: AzureConfig) -> Self {
        self.azure = Some(config);
        self
    }

    /// Set upload concurrency.
    pub fn with_concurrency(mut self, max_concurrent: usize) -> Self {
        self.max_concurrent_uploads = max_concurrent.max(1).min(32);
        self
    }

    /// Validate the configuration.
    pub fn validate(&self) -> Result<(), CloudError> {
        // Validate provider-specific configuration
        match self.provider {
            CloudStorageProvider::AwsS3 => {
                let config = self.s3.as_ref()
                    .ok_or_else(|| CloudError::InvalidRequest("S3 configuration required for AwsS3 provider".into()))?;
                config.validate()?;
            }
            CloudStorageProvider::Gcs => {
                let config = self.gcs.as_ref()
                    .ok_or_else(|| CloudError::InvalidRequest("GCS configuration required for Gcs provider".into()))?;
                config.validate()?;
            }
            CloudStorageProvider::AzureBlob => {
                let config = self.azure.as_ref()
                    .ok_or_else(|| CloudError::InvalidRequest("Azure configuration required for AzureBlob provider".into()))?;
                config.validate()?;
            }
            CloudStorageProvider::Local => {
                // Local provider has no configuration
            }
        }

        // Validate multipart settings
        if self.upload_part_size_mb < 5 {
            return Err(CloudError::InvalidRequest("Upload part size must be >= 5 MB".into()));
        }
        if self.upload_part_size_mb > 5000 {
            return Err(CloudError::InvalidRequest("Upload part size must be <= 5000 MB".into()));
        }

        Ok(())
    }
}

/// Represents a specific location in cloud storage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudLocation {
    /// Provider and connection configuration.
    pub config: CloudStorageConfig,
    /// Storage key/object name within bucket/container.
    pub key: String,
    /// Object version (for versioned buckets).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_id: Option<String>,
}

impl CloudLocation {
    /// Create a new cloud location.
    pub fn new(config: CloudStorageConfig, key: impl Into<String>) -> Self {
        Self {
            config,
            key: key.into(),
            version_id: None,
        }
    }

    /// Set the version ID.
    pub fn with_version(mut self, version: impl Into<String>) -> Self {
        self.version_id = Some(version.into());
        self
    }
}

/// Progress tracking for ongoing uploads.
#[derive(Debug, Clone)]
pub struct CloudUploadProgress {
    /// Total bytes uploaded so far.
    pub bytes_uploaded: u64,
    /// Total bytes to upload (None if unknown).
    pub total_bytes: Option<u64>,
    /// Number of multipart parts completed.
    pub parts_completed: usize,
    /// Total number of parts (for multipart uploads).
    pub total_parts: usize,
    /// Upload start time.
    pub started_at: DateTime<Utc>,
    /// Bytes uploaded in current part.
    pub current_part_bytes: u64,
}

impl CloudUploadProgress {
    /// Create new upload progress.
    pub fn new(total_bytes: Option<u64>) -> Self {
        Self {
            bytes_uploaded: 0,
            total_bytes,
            parts_completed: 0,
            total_parts: 0,
            started_at: Utc::now(),
            current_part_bytes: 0,
        }
    }

    /// Get upload progress as a percentage (0-100).
    pub fn percent(&self) -> f64 {
        match self.total_bytes {
            Some(total) if total > 0 => (self.bytes_uploaded as f64 / total as f64) * 100.0,
            _ => 0.0,
        }
    }

    /// Get elapsed time since start.
    pub fn elapsed(&self) -> chrono::Duration {
        Utc::now().signed_duration_since(self.started_at)
    }
}

/// Progress tracking for ongoing downloads.
#[derive(Debug, Clone)]
pub struct CloudDownloadProgress {
    /// Total bytes downloaded so far.
    pub bytes_downloaded: u64,
    /// Total bytes to download (None if unknown).
    pub total_bytes: Option<u64>,
    /// Download start time.
    pub started_at: DateTime<Utc>,
    /// Bytes downloaded in current chunk.
    pub current_chunk_bytes: u64,
}

impl CloudDownloadProgress {
    /// Create new download progress.
    pub fn new(total_bytes: Option<u64>) -> Self {
        Self {
            bytes_downloaded: 0,
            total_bytes,
            started_at: Utc::now(),
            current_chunk_bytes: 0,
        }
    }

    /// Get download progress as a percentage (0-100).
    pub fn percent(&self) -> f64 {
        match self.total_bytes {
            Some(total) if total > 0 => (self.bytes_downloaded as f64 / total as f64) * 100.0,
            _ => 0.0,
        }
    }

    /// Get elapsed time since start.
    pub fn elapsed(&self) -> chrono::Duration {
        Utc::now().signed_duration_since(self.started_at)
    }
}

/// Extended backup metadata for cloud-stored backups.
///
/// This type is a simplified placeholder. In real implementation,
/// it would reference the Backup type from the recovery module.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudBackupMetadata {
    /// Base backup metadata (placeholder).
    pub backup: CloudBackupStub,
    /// Where the backup is stored in cloud.
    pub cloud_location: CloudLocation,
    /// Storage class (e.g., "STANDARD", "GLACIER", "ARCHIVE").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub storage_class: Option<String>,
    /// ETag of uploaded object (for integrity verification).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    /// Object version ID (for versioned buckets).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_id: Option<String>,
    /// Estimated upload cost in USD.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upload_cost_usd: Option<f64>,
    /// Estimated monthly storage cost in USD.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub storage_cost_per_month_usd: Option<f64>,
}

/// Simplified backup stub for cloud metadata.
///
/// Placeholder that represents the Backup type from recovery::backup module.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudBackupStub {
    /// Unique backup identifier.
    pub id: uuid::Uuid,
    /// Backup type (full, incremental, etc.).
    pub backup_type: String,
    /// Starting LSN of backup.
    pub start_lsn: u64,
    /// Ending LSN of backup.
    pub end_lsn: u64,
    /// Backup creation timestamp.
    pub created_at: DateTime<Utc>,
    /// Backup completion timestamp.
    pub completed_at: Option<DateTime<Utc>>,
    /// Previous backup ID (for incremental chains).
    pub previous_backup_id: Option<uuid::Uuid>,
    /// File size in bytes.
    pub size_bytes: u64,
    /// SHA-256 checksum of backup data.
    pub checksum: String,
    /// Backup file path.
    pub path: std::path::PathBuf,
    /// Compression level (0-9, none if None).
    pub compression_level: Option<u8>,
    /// Encrypted with AES-256-GCM.
    pub encrypted: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_s3_config_validation() {
        let config = S3Config::new("us-east-1", "my-bucket")
            .with_access_key("AKIAIOSFODNN7EXAMPLE")
            .with_secret_key("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
        assert!(config.validate().is_ok());

        let invalid = S3Config::new("", "my-bucket");
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_gcs_config_validation() {
        let config = GcsConfig::new("my-bucket")
            .with_credentials_json("{}");
        assert!(config.validate().is_ok());

        let invalid = GcsConfig::new("my-bucket");
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_azure_config_validation() {
        let config = AzureConfig::new("mystorageaccount", "my-container")
            .with_access_key("base64key==");
        assert!(config.validate().is_ok());

        let invalid = AzureConfig::new("st", "my-container");
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_cloud_storage_config_validation() {
        let s3_config = S3Config::new("us-east-1", "my-bucket")
            .with_access_key("key")
            .with_secret_key("secret");

        let config = CloudStorageConfig::new(CloudStorageProvider::AwsS3)
            .with_s3(s3_config);
        assert!(config.validate().is_ok());

        let invalid = CloudStorageConfig::new(CloudStorageProvider::AwsS3);
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_upload_progress() {
        let mut progress = CloudUploadProgress::new(Some(1000));
        progress.bytes_uploaded = 500;
        assert_eq!(progress.percent(), 50.0);
    }

    #[test]
    fn test_retryable_errors() {
        // Network errors are retryable
        assert!(CloudError::NetworkError("connection refused".into()).is_retryable());

        // Timeouts are retryable
        assert!(CloudError::Timeout("operation timed out".into()).is_retryable());

        // Rate limit errors are retryable
        assert!(CloudError::QuotaExceeded("rate limit exceeded".into()).is_retryable());
        assert!(CloudError::QuotaExceeded("SlowDown request".into()).is_retryable());
        assert!(CloudError::QuotaExceeded("429 Too Many Requests".into()).is_retryable());

        // Generic errors with transient keywords are retryable
        assert!(CloudError::Other("rate limit hit".into()).is_retryable());
        assert!(CloudError::Other("throttling request".into()).is_retryable());
        assert!(CloudError::Other("500 Internal Server Error".into()).is_retryable());
        assert!(CloudError::Other("connection reset".into()).is_retryable());
    }

    #[test]
    fn test_non_retryable_errors() {
        // Authentication failures are not retryable
        assert!(!CloudError::AuthenticationFailed("invalid credentials".into()).is_retryable());

        // Not found errors are not retryable
        assert!(!CloudError::ObjectNotFound("key not found".into()).is_retryable());

        // Permission denied is not retryable
        assert!(!CloudError::PermissionDenied("access denied".into()).is_retryable());

        // Invalid request is not retryable
        assert!(!CloudError::InvalidRequest("malformed XML".into()).is_retryable());

        // Checksum mismatch is not retryable
        assert!(!CloudError::ChecksumMismatch {
            expected: "abc123".into(),
            actual: "def456".into(),
        }.is_retryable());

        // Upload cancelled is not retryable
        assert!(!CloudError::UploadCancelled.is_retryable());

        // Generic errors without transient keywords are not retryable
        assert!(!CloudError::Other("permanent failure".into()).is_retryable());
    }

    #[test]
    fn test_quota_exceeded_retryable_detection() {
        // Rate limit errors are retryable
        assert!(CloudError::QuotaExceeded("Rate limit exceeded".into()).is_retryable());
        assert!(CloudError::QuotaExceeded("Throttling request".into()).is_retryable());
        assert!(CloudError::QuotaExceeded("429 Too Many Requests".into()).is_retryable());
        assert!(CloudError::QuotaExceeded("SlowDown error".into()).is_retryable());

        // Hard quota limits are not retryable
        assert!(!CloudError::QuotaExceeded("Storage quota full".into()).is_retryable());
        assert!(!CloudError::QuotaExceeded("Bucket size limit reached".into()).is_retryable());
    }
}
