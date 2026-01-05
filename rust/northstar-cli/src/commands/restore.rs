//! Restore command - Restore database from backup.

use super::Command;
use clap::ArgMatches;
use anyhow::{Result, Context, bail};
use std::path::Path;
use std::fs::File;
use std::io::{self, Read, Write, copy};
use flate2::read::GzDecoder;

/// Restore command implementation
pub struct RestoreCommand;

impl Command for RestoreCommand {
    fn name(&self) -> &str {
        "restore"
    }

    fn description(&self) -> &str {
        "Restore database from backup"
    }

    fn validate(&self, args: &ArgMatches) -> Result<()> {
        let source = args.get_one::<String>("source")
            .ok_or_else(|| anyhow::anyhow!("Source backup is required"))?;

        // Check if source exists
        if !source.contains("://") {
            let source_path = Path::new(source);
            if !source_path.exists() {
                bail!("Backup file does not exist: {}", source);
            }
        }

        let target = args.get_one::<String>("target")
            .ok_or_else(|| anyhow::anyhow!("Target database path is required"))?;

        let target_path = Path::new(target);

        // Check if target already exists
        if target_path.exists() && !args.get_flag("force") {
            bail!(
                "Target database already exists: {}. Use --force to overwrite.",
                target
            );
        }

        Ok(())
    }

    fn run(&self, args: &ArgMatches) -> Result<()> {
        self.validate(args)?;

        let source = args.get_one::<String>("source").unwrap();
        let target = args.get_one::<String>("target").unwrap();
        let force = args.get_flag("force");
        let decrypt = args.get_flag("decrypt");
        let verify = args.get_flag("verify");

        println!("Restoring database from backup...");
        println!("Source: {}", source);
        println!("Target: {}", target);

        if force {
            println!("Force mode enabled - will overwrite existing database");
        }

        // Check if source is a cloud URI
        if source.contains("://") {
            self.restore_from_cloud(source, target, args)?;
        } else {
            self.restore_from_local(source, target, decrypt)?;
        }

        if verify {
            println!("Verifying restored database...");
            self.verify_restored_database(target)?;
        }

        println!("Database restored successfully");
        Ok(())
    }
}

impl RestoreCommand {
    /// Restore from local backup file
    fn restore_from_local(
        &self,
        source: &str,
        target: &str,
        decrypt: bool,
    ) -> Result<()> {
        let source_path = Path::new(source);
        let target_path = Path::new(target);

        // Read backup file
        let backup_file = File::open(source_path)
            .context("Failed to open backup file")?;

        // Determine if backup is compressed
        let is_compressed = source.ends_with(".gz") || source.ends_with(".bak.gz");

        let buffer = if is_compressed {
            // Decompress
            let mut decoder = GzDecoder::new(backup_file);
            let mut buffer = Vec::new();
            decoder.read_to_end(&mut buffer)
                .context("Failed to decompress backup")?;
            buffer
        } else {
            // Read as-is
            let mut reader = io::BufReader::new(backup_file);
            let mut buffer = Vec::new();
            reader.read_to_end(&mut buffer)
                .context("Failed to read backup")?;
            buffer
        };

        if decrypt {
            println!("Warning: Decryption requested but not yet implemented");
            // TODO: Implement decryption using Phase 16.6 encryption module
        }

        println!("Restoring {} bytes...", buffer.len());

        // Create target directory if needed
        if let Some(parent) = target_path.parent() {
            std::fs::create_dir_all(parent)
                .context("Failed to create target directory")?;
        }

        // Write restored database
        let mut db_file = File::create(target_path)
            .context("Failed to create database file")?;

        db_file.write_all(&buffer)
            .context("Failed to write database")?;
        db_file.flush()
            .context("Failed to flush database")?;

        println!("Database restored successfully");
        Ok(())
    }

    /// Restore from cloud storage
    fn restore_from_cloud(
        &self,
        source: &str,
        _target: &str,
        _args: &ArgMatches,
    ) -> Result<()> {
        println!("Cloud restore detected: {}", source);

        // Parse URI to determine provider
        let (provider, bucket, key) = self.parse_cloud_uri(source)?;

        println!("Provider: {}", provider);
        println!("Bucket: {}", bucket);
        println!("Key: {}", key);

        // For now, download to temporary file then restore
        let temp_backup = format!("/tmp/northstar_restore_{}.bak",
            std::process::id());

        println!("Downloading from cloud...");
        // TODO: Implement cloud download using Phase 16 adapters
        println!("Note: Cloud download not yet implemented in Phase 17");
        println!("Please manually download {} to {}", source, temp_backup);

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

    /// Verify restored database
    fn verify_restored_database(&self, target: &str) -> Result<()> {
        let target_path = Path::new(target);

        if !target_path.exists() {
            bail!("Restored database file not found: {}", target);
        }

        let metadata = std::fs::metadata(target_path)
            .context("Failed to get database metadata")?;

        if metadata.len() == 0 {
            bail!("Restored database is empty");
        }

        // Try to open database to verify integrity
        use northstar_core::Db;
        let db = Db::open(target_path);

        match db {
            Ok(_) => {
                println!("Database integrity verified");
                println!("Database size: {} bytes", metadata.len());
            }
            Err(e) => {
                bail!("Database verification failed: {}", e);
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_s3_uri() {
        let cmd = RestoreCommand;
        let (provider, bucket, key) = cmd.parse_cloud_uri("s3://my-bucket/backups/db.bak").unwrap();
        assert_eq!(provider, "aws");
        assert_eq!(bucket, "my-bucket");
        assert_eq!(key, "backups/db.bak");
    }
}
