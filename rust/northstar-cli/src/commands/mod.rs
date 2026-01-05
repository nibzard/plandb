//! Command registry and trait definitions.
//!
//! All CLI commands implement the Command trait for consistent execution.

use clap::ArgMatches;
use anyhow::Result;
use std::collections::HashMap;

/// Command trait that all CLI operations must implement.
pub trait Command: Send + Sync {
    /// Command name (e.g., "backup", "query")
    fn name(&self) -> &str;

    /// Brief description for help text
    fn description(&self) -> &str;

    /// Execute the command with parsed arguments
    fn run(&self, args: &ArgMatches) -> Result<()>;

    /// Optional: Validate arguments before execution
    fn validate(&self, _args: &ArgMatches) -> Result<()> {
        Ok(())
    }
}

/// Registry of all available commands
pub struct CommandRegistry {
    commands: HashMap<String, Box<dyn Command>>,
}

impl CommandRegistry {
    /// Create a new command registry and register all commands
    pub fn new() -> Self {
        let mut registry = Self {
            commands: HashMap::new(),
        };

        // Register all commands
        registry.register(Box::new(backup::BackupCommand));
        registry.register(Box::new(restore::RestoreCommand));
        registry.register(Box::new(query::QueryCommand));
        registry.register(Box::new(import::ImportCommand));
        registry.register(Box::new(export::ExportCommand));
        registry.register(Box::new(config::ConfigCommand));
        registry.register(Box::new(stats::StatsCommand));

        registry
    }

    /// Register a command
    pub fn register(&mut self, command: Box<dyn Command>) {
        let name = command.name().to_string();
        self.commands.insert(name, command);
    }

    /// Get a command by name
    pub fn get(&self, name: &str) -> Option<&dyn Command> {
        self.commands.get(name).map(|c| c.as_ref())
    }

    /// List all registered command names
    pub fn list_commands(&self) -> Vec<String> {
        let mut names: Vec<String> = self.commands.keys().cloned().collect();
        names.sort();
        names
    }
}

impl Default for CommandRegistry {
    fn default() -> Self {
        Self::new()
    }
}

// Re-export all commands
pub mod backup;
pub mod restore;
pub mod query;
pub mod import;
pub mod export;
pub mod config;
pub mod stats;

