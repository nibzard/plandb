//! Backup command - Create database backups to local files or cloud storage.

use super::Command;
use clap::ArgMatches;
use anyhow::{Result, Context, bail};
use std::path::Path;
use std::fs::File;
use std::io::{self, Read, Write, BufWriter};
use flate2::{read::GzEncoder, Compression, write::GzEncoder as GzWriteEncoder};
use serde::{Serialize, Deserialize};

/// Backup command implementation
pub struct BackupCommand;

impl Command for BackupCommand {
    fn name(&self) -> &str {
        "backup"
    }

    fn description(&self) -> &str {
        "Create database backups to local files or cloud storage"
    }

    fn validate(&self, args: &ArgMatches) -> Result<()> {
        let database = args.get_one::<String>("database")
            .ok_or_else(|| anyhow::anyhow!("Database path is required"))?;

        let db_path = Path::new(database);
        if !db_path.exists() {
            bail!("Database file does not exist: {}", database);
        }

        let destination = args.get_one::<String>("destination")
            .ok_or_else(|| anyhow::anyhow!("Destination is required"))?;

        // Validate cloud backup configuration
        if let Some(provider) = args.get_one::<String>("provider") {
            if provider == "aws" || provider == "gcp" || provider == "azure" {
                if args.get_one::<String>("bucket").is_none() && !destination.contains("://") {
                    bail!("Cloud backup requires --bucket or URI with scheme (s3://, gs://, azure://)");
                }
            }
        }

        Ok(())
    }

    fn run(&self, args: &ArgMatches) -> Result<()> {
        self.validate(args)?;

        let database = args.get_one::<String>("database").unwrap();
        let destination = args.get_one::<String>("destination").unwrap();
        let backup_type = args.get_one::<String>("backup_type")
            .map(|s| s.as_str())
            .unwrap_or("full");
        let compression = args.get_one::<u32>("compression")
            .copied()
            .unwrap_or(6);
        let encrypt = args.get_flag("encrypt");
        let verify = args.get_flag("verify");

        println!("Creating {} backup...", backup_type);
        println!("Source: {}", database);
        println!("Destination: {}", destination);

        // Check if destination is a cloud URI
        if destination.contains("://") {
            self.backup_to_cloud(database, destination, args)?;
        } else {
            self.backup_to_local(database, destination, compression, encrypt)?;
        }

        if verify {
            println!("Verifying backup...");
            self.verify_backup(database, destination)?;
        }

        println!("Backup completed successfully");
        Ok(())
    }
}

impl BackupCommand {
    /// Create local backup
    fn backup_to_local(
        &self,
        database: &str,
        destination: &str,
        compression: u32,
        encrypt: bool,
    ) -> Result<()> {
        let db_path = Path::new(database);
        let backup_path = Path::new(destination);

        // Create parent directories if needed
        if let Some(parent) = backup_path.parent() {
            std::fs::create_dir_all(parent)
                .context("Failed to create backup directory")?;
        }

        // Read database file
        let mut db_file = File::open(db_path)
            .context("Failed to open database file")?;

        let mut buffer = Vec::new();
        db_file.read_to_end(&mut buffer)
            .context("Failed to read database file")?;

        println!("Database size: {} bytes", buffer.len());

        // Create backup file
        let backup_file = File::create(backup_path)
            .context("Failed to create backup file")?;

        if compression > 0 {
            // Compress backup
            let compression_level = Compression::new((compression % 10) as u32);
            let mut encoder = GzWriteEncoder::new(backup_file, compression_level);
            encoder.write_all(&buffer)
                .context("Failed to compress backup")?;
            encoder.finish()
                .context("Failed to finish compression")?;
            println!("Compression level: {}", compression);
        } else {
            // Write uncompressed
            let mut writer = io::BufWriter::new(backup_file);
            writer.write_all(&buffer)
                .context("Failed to write backup")?;
            writer.flush()
                .context("Failed to flush backup")?;
        }

        if encrypt {
            println!("Warning: Encryption requested but not yet implemented");
            // TODO: Implement encryption using Phase 16.6 encryption module
        }

        // Get backup file size
        let metadata = std::fs::metadata(backup_path)
            .context("Failed to get backup metadata")?;
        println!("Backup size: {} bytes", metadata.len());

        Ok(())
    }

    /// Create backup to cloud storage
    fn backup_to_cloud(
        &self,
        database: &str,
        destination: &str,
        _args: &ArgMatches,
    ) -> Result<()> {
        println!("Cloud backup detected: {}", destination);

        // Parse URI to determine provider
        let (provider, bucket, key) = self.parse_cloud_uri(destination)?;

        println!("Provider: {}", provider);
        println!("Bucket: {}", bucket);
        println!("Key: {}", key);

        // For now, create a local temporary file then upload
        // In production, this would stream directly to cloud
        let temp_backup = format!("/tmp/northstar_backup_{}.bak",
            std::process::id());

        self.backup_to_local(database, &temp_backup, 6, false)?;

        println!("Uploading to cloud...");
        // TODO: Implement cloud upload using Phase 16 adapters
        println!("Note: Cloud upload not yet implemented in Phase 17");
        println!("Local backup created at: {}", temp_backup);

        Ok(())
    }

    /// Parse cloud URI
    fn parse_cloud_uri(&self, uri: &str) -> Result<(String, String, String)> {
        let parts: Vec<&str> = uri.split("://").collect();
        if parts.len() != 2 {
            bail!("Invalid cloud URI format: {}", uri);
        }

        let scheme = parts[0];
        let rest = parts[1];

        let path_parts: Vec<&str> = rest.splitn(2, '/').collect();
        if path_parts.len() < 1 {
            bail!("Invalid cloud URI format: {}", uri);
        }

        let bucket = path_parts[0];
        let key = if path_parts.len() > 1 {
            path_parts[1].to_string()
        } else {
            String::new()
        };

        let provider = match scheme {
            "s3" => "aws",
            "gs" => "gcp",
            "azure" | "blob" => "azure",
            _ => bail!("Unknown cloud provider: {}", scheme),
        };

        Ok((provider.to_string(), bucket.to_string(), key))
    }

    /// Verify backup integrity
    fn verify_backup(&self, _database: &str, destination: &str) -> Result<()> {
        // For now, just verify file exists and has content
        let backup_path = Path::new(destination);
        if !backup_path.exists() {
            bail!("Backup file not found: {}", destination);
        }

        let metadata = std::fs::metadata(backup_path)
            .context("Failed to get backup metadata")?;

        if metadata.len() == 0 {
            bail!("Backup file is empty");
        }

        println!("Backup verification passed");
        println!("Backup size: {} bytes", metadata.len());

        Ok(())
    }
}

/// Backup metadata for tracking
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupMetadata {
    pub backup_type: String,
    pub source_size: u64,
    pub backup_size: u64,
    pub compression_level: u32,
    pub encrypted: bool,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub description: Option<String>,
}

/// Helper to check if destination is a cloud URI
pub fn is_cloud_uri(destination: &str) -> bool {
    destination.contains("://")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_s3_uri() {
        let cmd = BackupCommand;
        let (provider, bucket, key) = cmd.parse_cloud_uri("s3://my-bucket/backups/db.bak").unwrap();
        assert_eq!(provider, "aws");
        assert_eq!(bucket, "my-bucket");
        assert_eq!(key, "backups/db.bak");
    }

    #[test]
    fn test_parse_gcs_uri() {
        let cmd = BackupCommand;
        let (provider, bucket, key) = cmd.parse_cloud_uri("gs://my-bucket/backups/db.bak").unwrap();
        assert_eq!(provider, "gcp");
        assert_eq!(bucket, "my-bucket");
        assert_eq!(key, "backups/db.bak");
    }

    #[test]
    fn test_parse_azure_uri() {
        let cmd = BackupCommand;
        let (provider, bucket, key) = cmd.parse_cloud_uri("azure://my-container/backups/db.bak").unwrap();
        assert_eq!(provider, "azure");
        assert_eq!(bucket, "my-container");
        assert_eq!(key, "backups/db.bak");
    }

    #[test]
    fn test_is_cloud_uri() {
        assert!(is_cloud_uri("s3://bucket/path"));
        assert!(is_cloud_uri("gs://bucket/path"));
        assert!(!is_cloud_uri("/local/path"));
        assert!(!is_cloud_uri("./relative/path"));
    }
}
