//! AWS S3 Cloud Adapter Integration Tests
//!
//! Tests the AWS S3 cloud adapter implementation for backup and restore operations.
//! Covers basic operations, error handling, data integrity, and performance.

use std::time::Duration;
use std::path::Path;
use anyhow::Result;
use northstar_core::cloud::{
    CloudError,
    s3::S3Provider,
};

/// Test configuration
struct TestConfig {
    bucket_name: String,
    region: String,
    access_key: Option<String>,
    secret_key: Option<String>,
    endpoint: Option<String>,
}

impl TestConfig {
    fn from_env() -> Self {
        Self {
            bucket_name: std::env::var("AWS_TEST_BUCKET")
                .unwrap_or_else(|_| "northstar-test-12345".to_string()),
            region: std::env::var("AWS_REGION")
                .unwrap_or_else(|_| "us-east-1".to_string()),
            access_key: std::env::var("AWS_ACCESS_KEY_ID").ok(),
            secret_key: std::env::var("AWS_SECRET_ACCESS_KEY").ok(),
            endpoint: std::env::var("AWS_ENDPOINT").ok(),
        }
    }

    fn is_configured(&self) -> bool {
        self.access_key.is_some() && self.secret_key.is_some()
    }
}

/// Create test data file
fn create_test_file(path: &Path, size_mb: usize) -> Result<String> {
    use std::io::Write;
    use sha2::{Sha256, Digest};
    
    let mut file = std::fs::File::create(path)?;
    let size_bytes = size_mb * 1024 * 1024;
    
    // Generate deterministic test data
    for i in 0..(size_bytes / 1024) {
        let record = format!("RECORD-{:010}: [", i);
        file.write_all(record.as_bytes())?;
        
        for j in 0..1000 {
            let byte = ((i * j) % 256) as u8;
            file.write_all(&[byte])?;
        }
        
        file.write_all(b"]\n")?;
    }
    
    file.flush()?;
    
    // Calculate checksum
    let mut hasher = Sha256::new();
    let mut file_reader = std::fs::File::open(path)?;
    let mut buffer = [0u8; 8192];
    
    loop {
        let n = std::io::Read::read(&mut file_reader, &mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    
    Ok(format!("{:x}", hasher.finalize()))
}

/// Verify two files have identical checksums
fn verify_files_equal(path1: &Path, path2: &Path) -> Result<bool> {
    let checksum1 = create_test_file(path1, 0)?;
    let checksum2 = create_test_file(path2, 0)?;
    Ok(checksum1 == checksum2)
}

/// TC1: Single File Upload/Download (AWS S3)
#[tokio::test]
#[ignore] // Requires AWS credentials or mock server
async fn tc1_aws_single_file_upload_download() -> Result<()> {
    let config = TestConfig::from_env();
    
    if !config.is_configured() {
        println!("⚠️  Skipping: AWS credentials not configured");
        println!("   Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY to run");
        return Ok(());
    }
    
    println!("\n=== TC1: AWS S3 Single File Upload/Download ===\n");
    
    // Create provider
    let provider = S3Provider::new(
        &config.bucket_name,
        &config.region,
        config.access_key.as_deref(),
        config.secret_key.as_deref(),
        config.endpoint.as_deref(),
    )?;
    
    // Create test directory
    let temp_dir = std::env::temp_dir().join(format!("northstar-cloud-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&temp_dir)?;
    
    // Step 1: Create 10MB test file
    println!("Creating 10MB test file...");
    let test_file = temp_dir.join("test-single-10mb.db");
    let checksum = create_test_file(&test_file, 10)?;
    let size = std::fs::metadata(&test_file)?.len();
    println!("  Created: test-single-10mb.db ({})", format_bytes(size));
    println!("  Checksum: {}", checksum);
    
    // Step 2: Upload to S3
    println!("\nUploading to S3...");
    let key = "test-single-10mb.db";
    let start = std::time::Instant::now();
    provider.upload_file(key, &test_file, None).await?;
    let upload_time = start.elapsed();
    println!("  Upload time: {:.2}s", upload_time.as_secs_f64());
    
    // Step 3: Verify file exists
    println!("\nVerifying file exists...");
    let exists = provider.file_exists(key).await?;
    println!("  File exists: {}", exists);
    assert!(exists);
    
    // Step 4: Download file
    println!("\nDownloading from S3...");
    let download_path = temp_dir.join("downloaded.db");
    let start = std::time::Instant::now();
    provider.download_file(key, &download_path).await?;
    let download_time = start.elapsed();
    println!("  Download time: {:.2}s", download_time.as_secs_f64());
    
    // Step 5: Verify checksums match
    println!("\nVerifying data integrity...");
    let download_checksum = create_test_file(&download_path, 0)?;
    assert_eq!(checksum, download_checksum, "Checksums should match");
    println!("  Checksums match: {}", checksum);
    
    // Step 6: Delete file
    println!("\nDeleting from S3...");
    provider.delete_file(key).await?;
    println!("  Deleted successfully");
    
    // Step 7: Verify deletion
    let exists_after = provider.file_exists(key).await?;
    assert!(!exists_after);
    
    // Cleanup
    std::fs::remove_dir_all(temp_dir)?;
    
    println!("\n✅ TC1 PASSED\n");
    Ok(())
}

/// Format bytes to human-readable
fn format_bytes(bytes: u64) -> String {
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
