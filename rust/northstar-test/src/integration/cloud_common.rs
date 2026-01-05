//! Common utilities for cloud adapter integration tests
//!
//! Provides shared test harness, mock server setup, test data generation,
//! and verification utilities for AWS S3, Google Cloud Storage, and Azure Blob Storage.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use std::fs::File;
use std::io::{Read, Write};
use std::sync::Arc;
use tokio::sync::RwLock;
use sha2::{Sha256, Digest};
use anyhow::{Result, Context};
use northstar_core::cloud::{CloudProvider, CloudConfig, BackupMetadata};

/// Test harness for cloud integration tests
pub struct CloudTestHarness {
    /// Cloud provider being tested
    pub provider: Arc<CloudProvider>,
    /// Test configuration
    pub config: CloudConfig,
    /// Temporary directory for test files
    pub temp_dir: PathBuf,
    /// Test files created during setup
    pub test_files: Arc<RwLock<Vec<TestFile>>>,
}

/// Information about a test file
#[derive(Debug, Clone)]
pub struct TestFile {
    /// Local path to the file
    pub path: PathBuf,
    /// Original size in bytes
    pub size: u64,
    /// SHA-256 checksum
    pub checksum: String,
    /// Remote key name in cloud storage
    pub key: String,
}

impl CloudTestHarness {
    /// Create a new test harness for the specified provider
    pub async fn new(provider: CloudProvider, config: CloudConfig) -> Result<Self> {
        // Create temporary directory
        let temp_dir = std::env::temp_dir().join(format!("northstar-cloud-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&temp_dir)?;

        let provider = Arc::new(provider);

        Ok(Self {
            provider,
            config,
            temp_dir,
            test_files: Arc::new(RwLock::new(Vec::new())),
        })
    }

    /// Create a test database file of specified size
    pub async fn create_test_db(&self, name: &str, size_mb: usize) -> Result<TestFile> {
        let path = self.temp_dir.join(name);
        let size_bytes = size_mb * 1024 * 1024;

        // Generate deterministic test data
        let mut file = File::create(&path)?;
        let mut data = Vec::with_capacity(1024 * 1024); // 1MB buffer

        // Fill with pattern: "RECORD-{i}: [random data]\n"
        for i in 0..(size_bytes / 1024) {
            let record = format!("RECORD-{:010}: [", i);
            file.write_all(record.as_bytes())?;

            // Write ~1KB of pseudo-random data
            for j in 0..1000 {
                let byte = ((i * j) % 256) as u8;
                file.write_all(&[byte])?;
            }

            file.write_all(b"]\n")?;
        }

        file.flush()?;

        // Calculate checksum
        let checksum = Self::calculate_checksum(&path)?;

        let test_file = TestFile {
            path,
            size: size_bytes as u64,
            checksum,
            key: name.to_string(),
        };

        self.test_files.write().await.push(test_file.clone());

        Ok(test_file)
    }

    /// Calculate SHA-256 checksum of a file
    pub fn calculate_checksum(path: &Path) -> Result<String> {
        let mut file = File::open(path)?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 8192];

        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            hasher.update(&buffer[..n]);
        }

        Ok(format!("{:x}", hasher.finalize()))
    }

    /// Verify two files have identical checksums
    pub async fn verify_checksum(file1: &Path, file2: &Path) -> Result<bool> {
        let checksum1 = Self::calculate_checksum(file1)?;
        let checksum2 = Self::calculate_checksum(file2)?;

        Ok(checksum1 == checksum2)
    }

    /// Measure execution time of an async operation
    pub async fn measure_time<F, T>(f: F) -> (T, Duration)
    where
        F: std::future::Future<Output = T>,
    {
        let start = Instant::now();
        let result = f.await;
        let elapsed = start.elapsed();

        (result, elapsed)
    }

    /// Upload a test file to cloud storage
    pub async fn upload_test_file(&self, test_file: &TestFile) -> Result<BackupMetadata> {
        let metadata = self.provider
            .upload_file(
                &test_file.key,
                &test_file.path,
                None
            )
            .await?;

        Ok(metadata)
    }

    /// Download a file from cloud storage
    pub async fn download_test_file(&self, key: &str, dest_path: &Path) -> Result<()> {
        self.provider
            .download_file(key, dest_path)
            .await?;

        Ok(())
    }

    /// Check if a file exists in cloud storage
    pub async fn file_exists(&self, key: &str) -> Result<bool> {
        self.provider.file_exists(key).await
    }

    /// Delete a file from cloud storage
    pub async fn delete_file(&self, key: &str) -> Result<()> {
        self.provider.delete_file(key).await
    }

    /// List all files in the test bucket
    pub async fn list_files(&self) -> Result<Vec<String>> {
        self.provider.list_files().await
    }

    /// Clean up test files from local filesystem
    pub async fn cleanup_local(&self) -> Result<()> {
        if self.temp_dir.exists() {
            std::fs::remove_dir_all(&self.temp_dir)?;
        }
        Ok(())
    }

    /// Clean up all test files from cloud storage
    pub async fn cleanup_cloud(&self) -> Result<()> {
        let files = self.list_files().await?;

        for file in files {
            // Only delete files with our test prefix
            if file.starts_with("test-") || file.starts_with("cloud-test-") {
                self.delete_file(&file).await?;
            }
        }

        Ok(())
    }
}

impl Drop for CloudTestHarness {
    fn drop(&mut self) {
        // Best-effort cleanup
        let _ = std::fs::remove_dir_all(&self.temp_dir);
    }
}

/// Assert that two files have identical checksums
pub fn assert_files_equal(path1: &Path, path2: &Path) -> Result<()> {
    let checksum1 = CloudTestHarness::calculate_checksum(path1)?;
    let checksum2 = CloudTestHarness::calculate_checksum(path2)?;

    if checksum1 != checksum2 {
        anyhow::bail!(
            "Checksum mismatch:\n  File1: {}\n  File2: {}\n  Expected: {}\n  Got: {}",
            path1.display(),
            path2.display(),
            checksum1,
            checksum2
        );
    }

    Ok(())
}

/// Assert that a duration is within expected bounds
pub fn assert_duration_within(actual: Duration, min: Duration, max: Duration) -> Result<()> {
    if actual < min {
        anyhow::bail!(
            "Operation too fast: {:?} < {:?}",
            actual, min
        );
    }

    if actual > max {
        anyhow::bail!(
            "Operation too slow: {:?} > {:?}",
            actual, max
        );
    }

    Ok(())
}

/// Convert bytes to human-readable format
pub fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}

/// Convert duration to human-readable format
pub fn format_duration(duration: Duration) -> String {
    let secs = duration.as_secs_f64();

    if secs >= 60.0 {
        format!("{:.2} min", secs / 60.0)
    } else if secs >= 1.0 {
        format!("{:.2} s", secs)
    } else {
        format!("{:.0} ms", secs * 1000.0)
    }
}

/// Calculate throughput in bytes/second
pub fn calculate_throughput(bytes: u64, duration: Duration) -> f64 {
    let secs = duration.as_secs_f64();
    if secs > 0.0 {
        bytes as f64 / secs
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_checksum_calculation() {
        // Create a test file
        let temp_dir = std::env::temp_dir();
        let test_file = temp_dir.join("test-checksum.txt");

        let mut file = File::create(&test_file).unwrap();
        file.write_all(b"Hello, World!").unwrap();
        file.flush().unwrap();

        // Calculate checksum
        let checksum = CloudTestHarness::calculate_checksum(&test_file).unwrap();

        // Should match known SHA-256 of "Hello, World!"
        assert_eq!(checksum, "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f");

        // Cleanup
        std::fs::remove_file(&test_file).unwrap();
    }

    #[test]
    fn test_format_bytes() {
        assert_eq!(format_bytes(500), "500 B");
        assert_eq!(format_bytes(2048), "2.00 KB");
        assert_eq!(format_bytes(5 * 1024 * 1024), "5.00 MB");
        assert_eq!(format_bytes(2 * 1024 * 1024 * 1024), "2.00 GB");
    }

    #[test]
    fn test_format_duration() {
        assert_eq!(format_duration(Duration::from_millis(500)), "500 ms");
        assert_eq!(format_duration(Duration::from_secs(5)), "5.00 s");
        assert_eq!(format_duration(Duration::from_secs(120)), "2.00 min");
    }

    #[test]
    fn test_calculate_throughput() {
        let throughput = calculate_throughput(10 * 1024 * 1024, Duration::from_secs(2));
        assert!((throughput - 5_242_880.0).abs() < 1.0); // ~5 MB/s
    }
}
