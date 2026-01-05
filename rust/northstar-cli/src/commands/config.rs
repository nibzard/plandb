//! Config command - Manage database configuration.

use super::Command;
use clap::ArgMatches;
use anyhow::{Result, Context, bail};
use std::path::Path;
use std::collections::HashMap;

/// Config command implementation
pub struct ConfigCommand;

impl Command for ConfigCommand {
    fn name(&self) -> &str {
        "config"
    }

    fn description(&self) -> &str {
        "Manage database configuration"
    }

    fn run(&self, args: &ArgMatches) -> Result<()> {
        // Config uses subcommands
        let action = args.subcommand();

        match action {
            Some(("list", sub_args)) => self.config_list(sub_args),
            Some(("get", sub_args)) => self.config_get(sub_args),
            Some(("set", sub_args)) => self.config_set(sub_args),
            Some(("reset", sub_args)) => self.config_reset(sub_args),
            Some(("validate", sub_args)) => self.config_validate(sub_args),
            _ => {
                bail!("Invalid config subcommand. Use: list, get, set, reset, validate")
            }
        }
    }
}

impl ConfigCommand {
    /// List all configuration
    fn config_list(&self, args: &ArgMatches) -> Result<()> {
        let database = args.get_one::<String>("database")
            .ok_or_else(|| anyhow::anyhow!("Database path is required"))?;

        let db_path = Path::new(database);
        if !db_path.exists() {
            bail!("Database file does not exist: {}", database);
        }

        println!("=== Configuration for {} ===", database);

        // For now, show default configuration
        // In a full implementation, this would read from database metadata
        let config = self.get_default_config();

        println!("\nCache Settings:");
        println!("  cache_size_mb: {}", config.get("cache_size_mb").unwrap_or(&"128".to_string()));
        println!("  cache_ttl_seconds: {}", config.get("cache_ttl_seconds").unwrap_or(&"300".to_string()));

        println!("\nStorage Settings:");
        println!("  page_size_bytes: {}", config.get("page_size_bytes").unwrap_or(&"4096".to_string()));
        println!("  max_file_size_gb: {}", config.get("max_file_size_gb").unwrap_or(&"1024".to_string()));

        println!("\nTransaction Settings:");
        println!("  max_mutations_per_txn: {}", config.get("max_mutations_per_txn").unwrap_or(&"10000".to_string()));
        println!("  txn_timeout_seconds: {}", config.get("txn_timeout_seconds").unwrap_or(&"30".to_string()));

        println!("\nLogging Settings:");
        println!("  log_level: {}", config.get("log_level").unwrap_or(&"info".to_string()));
        println!("  log_file: {}", config.get("log_file").unwrap_or(&"".to_string()));

        Ok(())
    }

    /// Get configuration value
    fn config_get(&self, args: &ArgMatches) -> Result<()> {
        let database = args.get_one::<String>("database")
            .ok_or_else(|| anyhow::anyhow!("Database path is required"))?;

        let key = args.get_one::<String>("key")
            .ok_or_else(|| anyhow::anyhow!("Configuration key is required"))?;

        let db_path = Path::new(database);
        if !db_path.exists() {
            bail!("Database file does not exist: {}", database);
        }

        // Get configuration value
        let config = self.get_default_config();
        let value = config.get(key);

        match value {
            Some(v) => println!("{} = {}", key, v),
            None => bail!("Configuration key not found: {}", key),
        }

        Ok(())
    }

    /// Set configuration value
    fn config_set(&self, args: &ArgMatches) -> Result<()> {
        let database = args.get_one::<String>("database")
            .ok_or_else(|| anyhow::anyhow!("Database path is required"))?;

        let key = args.get_one::<String>("key")
            .ok_or_else(|| anyhow::anyhow!("Configuration key is required"))?;

        let value = args.get_one::<String>("value")
            .ok_or_else(|| anyhow::anyhow!("Configuration value is required"))?;

        let db_path = Path::new(database);
        if !db_path.exists() {
            bail!("Database file does not exist: {}", database);
        }

        println!("Setting configuration:");
        println!("  Database: {}", database);
        println!("  Key: {}", key);
        println!("  Value: {}", value);

        // Validate configuration
        self.validate_config_value(key, value)?;

        // For now, just display what would be set
        // In a full implementation, this would write to database metadata
        println!("Note: Configuration persistence not yet implemented");
        println!("Configuration will reset to defaults on restart");

        Ok(())
    }

    /// Reset configuration to default
    fn config_reset(&self, args: &ArgMatches) -> Result<()> {
        let database = args.get_one::<String>("database")
            .ok_or_else(|| anyhow::anyhow!("Database path is required"))?;

        let key = args.get_one::<String>("key")
            .ok_or_else(|| anyhow::anyhow!("Configuration key is required"))?;

        let db_path = Path::new(database);
        if !db_path.exists() {
            bail!("Database file does not exist: {}", database);
        }

        if key == "all" {
            println!("Resetting all configuration to defaults...");
            println!("Note: Configuration persistence not yet implemented");
        } else {
            println!("Resetting configuration key '{}' to default", key);
            // Validate that key exists
            let config = self.get_default_config();
            if !config.contains_key(key) {
                bail!("Configuration key not found: {}", key);
            }
            println!("Note: Configuration persistence not yet implemented");
        }

        Ok(())
    }

    /// Validate configuration
    fn config_validate(&self, args: &ArgMatches) -> Result<()> {
        let database = args.get_one::<String>("database")
            .ok_or_else(|| anyhow::anyhow!("Database path is required"))?;

        let db_path = Path::new(database);
        if !db_path.exists() {
            bail!("Database file does not exist: {}", database);
        }

        println!("Validating configuration...");

        let config = self.get_default_config();
        let mut errors = Vec::new();

        for (key, value) in &config {
            if let Err(e) = self.validate_config_value(key, value) {
                errors.push(format!("{}: {}", key, e));
            }
        }

        if errors.is_empty() {
            println!("Configuration is valid");
        } else {
            println!("Configuration validation failed:");
            for error in &errors {
                println!("  - {}", error);
            }
            bail!("Configuration validation failed with {} error(s)", errors.len());
        }

        Ok(())
    }

    /// Get default configuration values
    fn get_default_config(&self) -> HashMap<String, String> {
        let mut config = HashMap::new();

        // Cache settings
        config.insert("cache_size_mb".to_string(), "128".to_string());
        config.insert("cache_ttl_seconds".to_string(), "300".to_string());

        // Storage settings
        config.insert("page_size_bytes".to_string(), "4096".to_string());
        config.insert("max_file_size_gb".to_string(), "1024".to_string());

        // Transaction settings
        config.insert("max_mutations_per_txn".to_string(), "10000".to_string());
        config.insert("txn_timeout_seconds".to_string(), "30".to_string());

        // Logging settings
        config.insert("log_level".to_string(), "info".to_string());
        config.insert("log_file".to_string(), "".to_string());

        config
    }

    /// Validate a configuration value
    fn validate_config_value(&self, key: &str, value: &str) -> Result<()> {
        match key {
            "cache_size_mb" => {
                let size = value.parse::<usize>()
                    .map_err(|_| anyhow::anyhow!("Invalid cache size: {}", value))?;
                if size < 1 || size > 65536 {
                    bail!("Cache size must be between 1 and 65536 MB");
                }
            }
            "cache_ttl_seconds" => {
                let ttl = value.parse::<u64>()
                    .map_err(|_| anyhow::anyhow!("Invalid TTL: {}", value))?;
                if ttl > 86400 {
                    bail!("TTL must not exceed 86400 seconds (24 hours)");
                }
            }
            "page_size_bytes" => {
                let size = value.parse::<usize>()
                    .map_err(|_| anyhow::anyhow!("Invalid page size: {}", value))?;
                if size != 4096 {
                    bail!("Page size must be 4096 bytes (currently fixed)");
                }
            }
            "max_mutations_per_txn" => {
                let max = value.parse::<usize>()
                    .map_err(|_| anyhow::anyhow!("Invalid max mutations: {}", value))?;
                if max < 1 || max > 1000000 {
                    bail!("Max mutations must be between 1 and 1000000");
                }
            }
            "txn_timeout_seconds" => {
                let timeout = value.parse::<u64>()
                    .map_err(|_| anyhow::anyhow!("Invalid timeout: {}", value))?;
                if timeout > 3600 {
                    bail!("Timeout must not exceed 3600 seconds (1 hour)");
                }
            }
            "log_level" => {
                let valid_levels = vec!["off", "error", "warn", "info", "debug", "trace"];
                if !valid_levels.contains(&value.as_ref()) {
                    bail!("Invalid log level: {}. Must be one of: {}",
                        value, valid_levels.join(", "));
                }
            }
            _ => {
                bail!("Unknown configuration key: {}", key);
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_cache_size() {
        let cmd = ConfigCommand;
        assert!(cmd.validate_config_value("cache_size_mb", "128").is_ok());
        assert!(cmd.validate_config_value("cache_size_mb", "0").is_err());
        assert!(cmd.validate_config_value("cache_size_mb", "100000").is_err());
    }

    #[test]
    fn test_validate_log_level() {
        let cmd = ConfigCommand;
        assert!(cmd.validate_config_value("log_level", "info").is_ok());
        assert!(cmd.validate_config_value("log_level", "debug").is_ok());
        assert!(cmd.validate_config_value("log_level", "invalid").is_err());
    }
}
