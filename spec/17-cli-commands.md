# CLI Tool Expansion

**Phase**: 17
**Task**: 17.0
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2026-01-05

## Table of Contents
1. [Introduction](#introduction)
2. [CLI Architecture](#cli-architecture)
3. [Command Structure](#command-structure)
4. [Essential Commands](#essential-commands)
5. [Output Formatting](#output-formatting)
6. [Error Handling](#error-handling)
7. [Shell Completion](#shell-completion)
8. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

This specification describes the expansion of the NorthstarDB CLI tool from a basic benchmark runner into a comprehensive database administration interface. The expanded CLI provides essential operations for database management, data manipulation, and system monitoring.

### Goals

1. **Comprehensive Operations**: Support all common database administration tasks
2. **User-Friendly**: Intuitive command structure with clear help text
3. **Automation-Ready**: JSON output modes and proper exit codes
4. **Extensible**: Easy to add new commands following established patterns
5. **Cloud Integration**: Leverage Phase 16 cloud adapters for backup operations

### Design Principles

- **Command Pattern**: Each operation implements the `Command` trait
- **Clap v4**: Declarative argument parsing with derive macros
- **Async Support**: All IO operations use tokio for non-blocking execution
- **Error Handling**: Clear, actionable error messages with proper exit codes
- **Output Modes**: Support human-readable and machine-readable formats

---

## CLI Architecture

### Command Trait

All commands implement a common trait for consistent execution:

```rust
use clap::ArgMatches;
use anyhow::Result;

pub trait Command: Send + Sync {
    /// Command name (e.g., "backup", "query")
    fn name(&self) -> &str;

    /// Brief description for help text
    fn description(&self) -> &str;

    /// Execute the command with parsed arguments
    fn run(&self, args: &ArgMatches) -> Result<()>;

    /// Optional: Validate arguments before execution
    fn validate(&self, args: &ArgMatches) -> Result<()> {
        Ok(())
    }
}
```

### Command Registry

Commands are registered in a central module:

```rust
pub struct CommandRegistry {
    commands: HashMap<String, Box<dyn Command>>,
}

impl CommandRegistry {
    pub fn new() -> Self {
        let mut registry = Self {
            commands: HashMap::new(),
        };

        // Register all commands
        registry.register(Box::new(BackupCommand));
        registry.register(Box::new(RestoreCommand));
        registry.register(Box::new(QueryCommand));
        // ... etc

        registry
    }

    pub fn register(&mut self, command: Box<dyn Command>) {
        let name = command.name().to_string();
        self.commands.insert(name, command);
    }

    pub fn get(&self, name: &str) -> Option<&dyn Command> {
        self.commands.get(name).map(|c| c.as_ref())
    }
}
```

### Main Entry Point

The CLI uses clap's derive API for subcommand parsing:

```rust
use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(name = "northstar")]
#[command(about = "NorthstarDB CLI", long_about = None)]
struct Cli {
    /// Global output format
    #[arg(short, long, global = true)]
    format: Option<OutputFormat>,

    /// Database path (global override)
    #[arg(short, long, global = true)]
    database: Option<String>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Backup(BackupArgs),
    Restore(RestoreArgs),
    Query(QueryArgs),
    Import(ImportArgs),
    Export(ExportArgs),
    Config(ConfigArgs),
    Stats(StatsArgs),
    Server(ServerArgs),
    Bench(BenchArgs),
    Validate(ValidateArgs),
}
```

---

## Command Structure

### Argument Parsing Conventions

1. **Short opts**: Single character (e.g., `-f`, `-o`)
2. **Long opts**: Descriptive names (e.g., `--format`, `--output`)
3. **Positional args**: Required values (e.g., database path)
4. **Subcommands**: Nested operations (e.g., `config set`, `config get`)

### Common Arguments

All commands support these global options:

```rust
#[derive(ValueEnum, Clone, Debug)]
pub enum OutputFormat {
    Json,
    Table,
    Plain,
}
```

- `-f, --format <FORMAT>`: Output format (json, table, plain)
- `-d, --database <PATH>`: Database file path
- `-v, --verbose`: Increase verbosity (can be used multiple times)
- `-q, --quiet`: Suppress non-error output
- `--color <WHEN>`: Color output (auto, always, never)

---

## Essential Commands

### 1. Backup Command

Create database backups to local files or cloud storage.

```rust
#[derive(Parser, Debug)]
pub struct BackupArgs {
    /// Database path
    #[arg(short, long)]
    database: String,

    /// Backup destination path or URI
    #[arg(short, long)]
    destination: String,

    /// Backup type
    #[arg(short, long, value_enum)]
    backup_type: BackupType,

    /// Compression level (0-9, default: 6)
    #[arg(short, long, default_value_t = 6)]
    compression: u32,

    /// Encrypt backup
    #[arg(long)]
    encrypt: bool,

    /// Description for backup metadata
    #[arg(long)]
    description: Option<String>,

    /// Cloud provider (s3, gcs, azure)
    #[arg(long, value_enum)]
    provider: Option<CloudProvider>,

    /// Bucket name for cloud backups
    #[arg(long)]
    bucket: Option<String>,

    /// Verify backup after creation
    #[arg(long)]
    verify: bool,
}

#[derive(ValueEnum, Clone, Debug)]
pub enum BackupType {
    Full,
    Incremental,
}

#[derive(ValueEnum, Clone, Debug)]
pub enum CloudProvider {
    Aws,
    Gcp,
    Azure,
}
```

**Examples**:

```bash
# Local full backup
northstar backup -d mydb.db -o /backups/mydb-full.bak --type full

# Local incremental backup
northstar backup -d mydb.db -o /backups/inc.bak --type incremental

# Cloud backup to S3
northstar backup -d mydb.db -o s3://my-bucket/backups/db.bak \
    --provider aws --bucket my-bucket --encrypt

# Local backup with verification
northstar backup -d mydb.db -o backup.bak --verify
```

**Implementation Notes**:
- Full backups copy entire database file
- Incremental backups use Phase 15.3 cloud adapters
- Encryption uses Phase 16.6 encryption module
- Verification reopens backup and validates checksums
- Cloud uploads use multipart upload for large files

### 2. Restore Command

Restore database from backup.

```rust
#[derive(Parser, Debug)]
pub struct RestoreArgs {
    /// Source backup path or URI
    #[arg(short, long)]
    source: String,

    /// Target database path
    #[arg(short, long)]
    target: String,

    /// Force overwrite existing database
    #[arg(long)]
    force: bool,

    /// Decrypt backup
    #[arg(long)]
    decrypt: bool,

    /// Encryption key (if not using default)
    #[arg(long)]
    key: Option<String>,

    /// Verify backup before restore
    #[arg(long)]
    verify: bool,

    /// Cloud provider for cloud backups
    #[arg(long, value_enum)]
    provider: Option<CloudProvider>,
}
```

**Examples**:

```bash
# Restore from local backup
northstar restore -s backup.bak -t restored.db

# Force overwrite existing database
northstar restore -s backup.bak -t mydb.db --force

# Restore from S3
northstar restore -s s3://bucket/backup.bak -t mydb.db \
    --provider aws --decrypt

# Restore with verification
northstar restore -s backup.bak -t mydb.db --verify
```

**Implementation Notes**:
- Validates target doesn't exist unless `--force` is set
- Downloads from cloud using Phase 16 adapters
- Decrypts if backup was encrypted
- Verifies checksums before applying
- Uses atomic write to prevent corruption

### 3. Query Command

Execute queries against the database (SQL or natural language).

```rust
#[derive(Parser, Debug)]
pub struct QueryArgs {
    /// Database path
    #[arg(short, long)]
    database: String,

    /// Query string
    #[arg(short, long)]
    query: String,

    /// Query type
    #[arg(short, long, value_enum)]
    query_type: QueryType,

    /// Output format
    #[arg(short, long, value_enum)]
    format: OutputFormat,

    /// Execute multiple queries from file
    #[arg(long)]
    file: Option<String>,

    /// Timing information
    #[arg(long)]
    timing: bool,

    /// Explain query plan
    #[arg(long)]
    explain: bool,
}

#[derive(ValueEnum, Clone, Debug)]
pub enum QueryType {
    Sql,
    NaturalLanguage,
}
```

**Examples**:

```bash
# SQL query
northstar query -d mydb.db -q "SELECT * FROM users WHERE age > 30" \
    --type sql --format table

# Natural language query
northstar query -d mydb.db -q "Find all users older than 30" \
    --type natural-language --format json

# Query with timing
northstar query -d mydb.db -q "SELECT COUNT(*) FROM logs" \
    --timing

# Explain query plan
northstar query -d mydb.db -q "SELECT * FROM users WHERE name = 'Alice'" \
    --explain

# Batch queries from file
northstar query -d mydb.db --file queries.sql
```

**Implementation Notes**:
- SQL queries use Phase 9 query planner
- Natural language uses Phase 9.5 NL planner
- Output formats: JSON array, table, plain text
- Timing shows wall-clock time and I/O statistics
- Explain shows query execution plan

### 4. Import Command

Import data from CSV or JSON files.

```rust
#[derive(Parser, Debug)]
pub struct ImportArgs {
    /// Database path
    #[arg(short, long)]
    database: String,

    /// Source file path
    #[arg(short, long)]
    source: String,

    /// Input format
    #[arg(short, long, value_enum)]
    format: ImportFormat,

    /// Target key prefix (e.g., "users:")
    #[arg(short, long)]
    prefix: String,

    /// Batch size for writes
    #[arg(short, long, default_value_t = 1000)]
    batch_size: usize,

    /// Create transaction per batch
    #[arg(long)]
    batch_transactions: bool,

    /// Continue on error
    #[arg(long)]
    continue_on_error: bool,

    /// Show progress
    #[arg(long)]
    progress: bool,
}

#[derive(ValueEnum, Clone, Debug)]
pub enum ImportFormat {
    Csv,
    Json,
    JsonLines,
}
```

**Examples**:

```bash
# Import CSV with prefix
northstar import -d mydb.db -s users.csv --format csv \
    --prefix "users:" --batch-size 500

# Import JSON
northstar import -d mydb.db -s data.json --format json \
    --prefix "data:"

# Import JSON Lines (one JSON object per line)
northstar import -d mydb.db -s logs.jsonl --format json-lines \
    --prefix "logs:"

# Import with progress bar
northstar import -d mydb.db -s large.csv --format csv \
    --prefix "data:" --progress
```

**Implementation Notes**:
- CSV: First row is header, subsequent rows are data
- JSON: Array of objects, each object becomes a key-value pair
- JSON Lines: One JSON object per line, more memory efficient
- Batching uses Phase 15.2 bulk operations
- Progress bar uses indicatif crate
- Continues on error if flag set, reports errors at end

### 5. Export Command

Export data to CSV or JSON files.

```rust
#[derive(Parser, Debug)]
pub struct ExportArgs {
    /// Database path
    #[arg(short, long)]
    database: String,

    /// Output file path
    #[arg(short, long)]
    output: String,

    /// Output format
    #[arg(short, long, value_enum)]
    format: ExportFormat,

    /// Key prefix filter
    #[arg(short, long)]
    prefix: Option<String>,

    /// Scan limit (0 = unlimited)
    #[arg(short, long, default_value_t = 0)]
    limit: usize,

    /// Export values (not just keys)
    #[arg(long)]
    values: bool,

    /// Pretty print JSON
    #[arg(long)]
    pretty: bool,
}

#[derive(ValueEnum, Clone, Debug)]
pub enum ExportFormat {
    Csv,
    Json,
    JsonLines,
}
```

**Examples**:

```bash
# Export all keys to JSON
northstar export -d mydb.db -o export.json --format json --values

# Export with prefix filter
northstar export -d mydb.db -o users.json --format json \
    --prefix "users:" --values

# Export to CSV
northstar export -d mydb.db -o data.csv --format csv \
    --prefix "data:" --values

# Export limited results
northstar export -d mydb.db -o sample.json --format json \
    --limit 1000 --values

# Export pretty JSON
northstar export -d mydb.db -o export.json --format json \
    --values --pretty
```

**Implementation Notes**:
- Scans database using prefix filter
- CSV exports include key and value columns
- JSON format creates array of objects
- JSON Lines creates one JSON object per line
- Limit prevents memory issues on large exports

### 6. Config Command

Manage database configuration.

```rust
#[derive(Parser, Debug)]
pub struct ConfigArgs {
    #[command(subcommand)]
    action: ConfigAction,
}

#[derive(Subcommand, Debug)]
pub enum ConfigAction {
    /// List all configuration
    List {
        /// Database path
        #[arg(short, long)]
        database: String,
    },

    /// Get configuration value
    Get {
        /// Database path
        #[arg(short, long)]
        database: String,

        /// Configuration key
        key: String,
    },

    /// Set configuration value
    Set {
        /// Database path
        #[arg(short, long)]
        database: String,

        /// Configuration key
        key: String,

        /// Configuration value
        value: String,
    },

    /// Reset configuration to default
    Reset {
        /// Database path
        #[arg(short, long)]
        database: String,

        /// Configuration key (or 'all' for everything)
        key: String,
    },

    /// Validate configuration
    Validate {
        /// Database path
        #[arg(short, long)]
        database: String,
    },
}
```

**Examples**:

```bash
# List all configuration
northstar config list -d mydb.db

# Get specific value
northstar config get -d mydb.db cache_size_mb

# Set value
northstar config set -d mydb.db cache_size_mb 256

# Reset to default
northstar config reset -d mydb.db cache_size_mb

# Reset all configuration
northstar config reset -d mydb.db all

# Validate configuration
northstar config validate -d mydb.db
```

**Implementation Notes**:
- Configuration stored in database metadata
- List shows all keys and values
- Get retrieves single value
- Set updates value and validates
- Reset removes key or all keys
- Validate checks all values

### 7. Stats Command

Show database statistics and metrics.

```rust
#[derive(Parser, Debug)]
pub struct StatsArgs {
    /// Database path
    #[arg(short, long)]
    database: String,

    /// Statistics category
    #[arg(short, long, value_enum)]
    category: StatsCategory,

    /// Output format
    #[arg(short, long, value_enum)]
    format: OutputFormat,

    /// Watch mode (refresh interval in seconds)
    #[arg(short, long)]
    watch: Option<u64>,

    /// Export metrics to file
    #[arg(long)]
    export: Option<String>,
}

#[derive(ValueEnum, Clone, Debug)]
pub enum StatsCategory {
    All,
    Storage,
    Performance,
    Cache,
    Queries,
}
```

**Examples**:

```bash
# Show all statistics
northstar stats -d mydb.db --category all

# Show storage statistics
northstar stats -d mydb.db --category storage

# Show query performance
northstar stats -d mydb.db --category queries --format json

# Watch mode (refresh every 5 seconds)
northstar stats -d mydb.db --category all --watch 5

# Export metrics
northstar stats -d mydb.db --category all \
    --export metrics.json
```

**Implementation Notes**:
- Storage stats: file size, page count, fragmentation
- Performance stats: read/write latency, throughput
- Cache stats: hit rate, eviction count, memory usage
- Query stats: execution time, row counts, cache hits
- Watch mode clears screen and refreshes
- Export writes JSON to file

### 8. Server Command

Start database server (for future client-server mode).

```rust
#[derive(Parser, Debug)]
pub struct ServerArgs {
    /// Database path
    #[arg(short, long)]
    database: String,

    /// Listen address
    #[arg(short, long, default_value = "127.0.0.1:6789")]
    address: String,

    /// TLS certificate
    #[arg(long)]
    cert: Option<String>,

    /// TLS key
    #[arg(long)]
    key: Option<String>,

    /// Require authentication
    #[arg(long)]
    auth: bool,

    /// Maximum connections
    #[arg(short, long, default_value_t = 100)]
    max_connections: usize,

    /// Log level
    #[arg(long, default_value = "info")]
    log_level: String,
}
```

**Examples**:

```bash
# Start server with defaults
northstar server -d mydb.db

# Start with custom address
northstar server -d mydb.db -a 0.0.0.0:6789

# Start with TLS
northstar server -d mydb.db \
    --cert server.crt --key server.key

# Start with authentication
northstar server -d mydb.db --auth
```

**Implementation Notes**:
- Placeholder for future client-server implementation
- Will use tokio for async networking
- TLS support for encrypted connections
- Authentication for secure access
- Connection pooling and rate limiting

---

## Output Formatting

### Output Modes

#### 1. Plain Mode

Human-readable text output:

```
=== Database Statistics ===
Database: mydb.db
File size: 1.2 GB
Total pages: 30,720
Fragmentation: 3.2%

=== Performance ===
Read latency (p50): 45 μs
Read latency (p99): 230 μs
Write latency (p50): 120 μs
Write latency (p99): 540 μs
```

#### 2. Table Mode

Formatted table output:

```
+---------+------------+----------+
| Key     | Size       | Version  |
+---------+------------+----------+
| user:1  | 1.2 KB     | 5        |
| user:2  | 0.8 KB     | 3        |
| user:3  | 2.1 KB     | 7        |
+---------+------------+----------+
```

Uses comfy-table or similar crate.

#### 3. JSON Mode

Machine-readable JSON output:

```json
{
  "database": "mydb.db",
  "file_size": 1288490188,
  "total_pages": 30720,
  "fragmentation": 0.032,
  "performance": {
    "read_latency_p50_us": 45,
    "read_latency_p99_us": 230,
    "write_latency_p50_us": 120,
    "write_latency_p99_us": 540
  }
}
```

### Output Selection

Commands default to:
- `query`: table mode (for SQL), json mode (for NL)
- `stats`: plain mode
- `export`: determined by format flag
- All others: plain mode

Global `--format` flag overrides defaults.

### Color Output

Colors controlled by `--color` flag:
- `auto`: Detect terminal support (default)
- `always`: Always use colors
- `never`: Never use colors

Colors used for:
- Errors: red
- Warnings: yellow
- Success: green
- Info: blue
- Dim: gray for metadata

---

## Error Handling

### Exit Codes

Standard exit codes:
- `0`: Success
- `1`: General error
- `2`: Invalid arguments
- `3`: Database not found
- `4`: Database corrupted
- `5`: Permission denied
- `6`: Network error
- `7`: Backup/restore error
- `8`: Configuration error

### Error Messages

Errors provide:
1. Clear description of what failed
2. Context (database path, operation, etc.)
3. Suggested fix (when applicable)
4. Stack trace in verbose mode

Examples:

```
Error: Database file not found: /path/to/db.db

  The specified database file does not exist or is not accessible.

  Suggestions:
  - Check the file path is correct
  - Verify you have read permissions
  - Use 'northstar validate' to check file integrity
```

```
Error: Backup failed: Insufficient space

  The target location has only 500 MB free, but 1.2 GB is required.

  Suggestions:
  - Free up disk space
  - Choose a different destination
  - Use incremental backup to reduce size
```

### Error Handling Strategy

```rust
use anyhow::{Context, Result, bail, anyhow};

pub fn run_backup(args: &BackupArgs) -> Result<()> {
    // Validate preconditions
    if !args.database.exists() {
        bail!(ErrorCodes::DatabaseNotFound as i32,
              "Database not found: {}", args.database);
    }

    // Provide context
    let backup = create_backup(&args.destination)
        .context("Failed to create backup file")?;

    // Chain errors
    compress_backup(&backup, args.compression)
        .context("Failed during compression")?;

    Ok(())
}
```

---

## Shell Completion

### Generating Completions

Support bash, zsh, fish, and elvish:

```bash
# Generate completions
northstar generate-completion bash
northstar generate-completion zsh
northstar generate-completion fish
northstar generate-completion elvish
```

Clap's generate feature automatically creates completion scripts.

### Installation

#### Bash
```bash
# System-wide
northstar generate-completion bash > /etc/bash_completion.d/northstar

# User-specific
northstar generate-completion bash > ~/.bash_completion
source ~/.bash_completion
```

#### Zsh
```bash
# Add to fpath
northstar generate-completion zsh > ~/.zsh/completion/_northstar

# In .zshrc
fpath=(~/.zsh/completion $fpath)
autoload -U compinit && compinit
```

#### Fish
```bash
northstar generate-completion fish > ~/.config/fish/completions/northstar.fish
```

### Completion Features

Completions provide:
- Subcommand names
- File paths (with validation)
- Existing directories for `--output`
- Configuration keys for `config get/set`
- Enum values for flags
- Database files in current directory

Example completions:
```bash
northstar ba<tab>        # Completes to "backup"
northstar backup -d my<tab>  # Completes to "mydb.db"
northstar config set -d db.db cache_<tab>  # Shows cache options
```

---

## Rust Implementation Guidance

### Project Structure

```
northstar-cli/
├── Cargo.toml
└── src/
    ├── main.rs              # Entry point and CLI parsing
    ├── commands/
    │   ├── mod.rs           # Command registry
    │   ├── backup.rs        # Backup command
    │   ├── restore.rs       # Restore command
    │   ├── query.rs         # Query command
    │   ├── import.rs        # Import command
    │   ├── export.rs        # Export command
    │   ├── config.rs        # Config command
    │   ├── stats.rs         # Stats command
    │   └── server.rs        # Server command
    ├── format/
    │   ├── mod.rs           # Output formatting
    │   ├── plain.rs         # Plain text output
    │   ├── table.rs         # Table output
    │   └── json.rs          # JSON output
    └── error.rs             # Error handling
```

### Dependencies

Update `Cargo.toml`:

```toml
[dependencies]
northstar-core = { path = "../northstar-core" }
northstar-bench = { path = "../northstar-bench" }

# CLI
clap = { version = "4.5", features = ["derive"] }
anyhow = { workspace = true }
thiserror = { workspace = true }

# Async
tokio = { workspace = true, features = ["full"] }

# Serialization
serde = { workspace = true }
serde_json = { workspace = true }

# Output formatting
comfy-table = "7.1"
indicatif = "0.17"

# Cloud storage (optional)
aws-config = { version = "1.1", optional = true }
aws-sdk-s3 = { version = "1.14", optional = true }
google-cloud-sdk = { version = "0.1", optional = true }

[features]
default = []
s3 = ["aws-config", "aws-sdk-s3"]
gcs = ["google-cloud-sdk"]
all-clouds = ["s3", "gcs"]
```

### Implementation Checklist

1. **Command Trait**
   - [ ] Define `Command` trait
   - [ ] Implement `CommandRegistry`
   - [ ] Add error handling

2. **Backup Command**
   - [ ] Implement local backup
   - [ ] Implement cloud backup (S3, GCS, Azure)
   - [ ] Add encryption support
   - [ ] Add verification

3. **Restore Command**
   - [ ] Implement local restore
   - [ ] Implement cloud restore
   - [ ] Add decryption support
   - [ ] Add validation

4. **Query Command**
   - [ ] SQL query support
   - [ ] Natural language query support
   - [ ] Output formatting
   - [ ] Timing and explain

5. **Import Command**
   - [ ] CSV import
   - [ ] JSON import
   - [ ] JSON Lines import
   - [ ] Batching support

6. **Export Command**
   - [ ] CSV export
   - [ ] JSON export
   - [ ] JSON Lines export
   - [ ] Prefix filtering

7. **Config Command**
   - [ ] List configuration
   - [ ] Get/set values
   - [ ] Reset configuration
   - [ ] Validate configuration

8. **Stats Command**
   - [ ] Storage statistics
   - [ ] Performance metrics
   - [ ] Cache statistics
   - [ ] Query statistics
   - [ ] Watch mode

9. **Output Formatting**
   - [ ] Plain text formatter
   - [ ] Table formatter
   - [ ] JSON formatter
   - [ ] Color support

10. **Error Handling**
    - [ ] Exit codes
    - [ ] Error messages
    - [ ] Context information
    - [ ] Verbose mode

11. **Shell Completion**
    - [ ] Generate completion scripts
    - [ ] Install instructions
    - [ ] Dynamic completions

12. **Testing**
    - [ ] Unit tests for each command
    - [ ] Integration tests
    - [ ] Error case testing

### Testing Strategy

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_backup_restore() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir.path().join("test.db");
        let backup_path = temp_dir.path().join("backup.bak");

        // Create test database
        let mut db = Db::create(&db_path).unwrap();
        let mut txn = db.begin_write().unwrap();
        txn.put(b"key1", b"value1").unwrap();
        txn.commit().unwrap();
        db.close().unwrap();

        // Test backup
        let args = BackupArgs {
            database: db_path.to_str().unwrap().to_string(),
            destination: backup_path.to_str().unwrap().to_string(),
            // ...
        };

        let cmd = BackupCommand;
        cmd.run(&args).await.unwrap();

        // Verify backup exists
        assert!(backup_path.exists());

        // Test restore
        let restore_path = temp_dir.path().join("restored.db");
        let restore_args = RestoreArgs {
            source: backup_path.to_str().unwrap().to_string(),
            target: restore_path.to_str().unwrap().to_string(),
            // ...
        };

        let restore_cmd = RestoreCommand;
        restore_cmd.run(&restore_args).await.unwrap();

        // Verify restored database
        let mut restored_db = Db::open(&restore_path).unwrap();
        let txn = restored_db.begin_read().unwrap();
        let value = txn.get(b"key1").unwrap();
        assert_eq!(value, Some(b"value1".to_vec()));
    }
}
```

### Documentation

Add comprehensive help text:

```rust
/// Create database backups to local files or cloud storage
///
/// The backup command creates consistent snapshots of the database
/// that can be used for disaster recovery or data migration.
///
/// # Examples
///
/// ## Local backup
/// ```bash
/// northstar backup -d mydb.db -o backup.bak --type full
/// ```
///
/// ## Cloud backup to S3
/// ```bash
/// northstar backup -d mydb.db -o s3://bucket/backup.bak \
///     --provider aws --bucket my-bucket
/// ```
///
/// # Backup Types
///
/// - **full**: Complete copy of database
/// - **incremental**: Only changes since last backup
#[derive(Parser, Debug)]
pub struct BackupArgs {
    // ...
}
```

---

## Success Criteria

Phase 17 is complete when:

1. All 8 commands are implemented and functional
2. Commands support all specified flags and options
3. Output formatting works for all three modes
4. Error messages are clear and actionable
5. Exit codes follow conventions
6. Shell completions generate correctly
7. All commands have comprehensive help text
8. Integration tests validate end-to-end workflows
9. Code compiles without warnings
10. Documentation is complete

---

## Estimated Effort

- **Specification**: 500 lines
- **Command implementations**: ~2,000 lines
- **Output formatting**: ~600 lines
- **Error handling**: ~400 lines
- **Tests**: ~1,500 lines
- **Total**: ~5,000 lines

Estimated implementation time: 2-3 days
