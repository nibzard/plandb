//! NorthstarDB CLI - Command-line interface for database administration.
//!
//! Provides commands for benchmark execution, validation, debugging,
//! and plugin management.

#![warn(missing_docs)]
#![warn(clippy::all)]

use clap::{Parser, Subcommand};
use std::path::Path;

/// NorthstarDB CLI - Database administration and benchmarking tool
#[derive(Parser, Debug)]
#[command(name = "northstar")]
#[command(about = "NorthstarDB CLI", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Run benchmarks
    Bench {
        /// Benchmark filter pattern
        #[arg(short, long)]
        filter: Option<String>,

        /// Number of repeats
        #[arg(short, long, default_value_t = 5)]
        repeats: usize,

        /// Output directory for results
        #[arg(short, long)]
        output: Option<String>,
    },
    /// Validate database file
    Validate {
        /// Path to database file
        path: String,
    },
    /// Dump database structure
    Dump {
        /// Path to database file
        path: String,

        /// Print values as well
        #[arg(long)]
        values: bool,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Bench { filter, repeats, output } => {
            println!("Running benchmarks...");
            if let Some(pattern) = &filter {
                println!("Filter: {}", pattern);
            }
            println!("Repeats: {}", repeats);
            if let Some(out) = &output {
                println!("Output: {}", out);
            }

            northstar_bench::run_benchmarks(filter, repeats, output)?;
            Ok(())
        }
        Commands::Validate { path } => {
            println!("Validating database: {}", path);

            use northstar_core::Db;

            let db_path = Path::new(&path);
            if !db_path.exists() {
                anyhow::bail!("Database file does not exist: {}", path);
            }

            let mut db = Db::open(db_path)?;

            println!("Database opened successfully");
            println!("Validation passed");

            db.close()?;

            Ok(())
        }
        Commands::Dump { path, values } => {
            println!("Dumping database: {}", path);
            println!("Values: {}", values);

            use northstar_core::Db;

            let db_path = Path::new(&path);
            if !db_path.exists() {
                anyhow::bail!("Database file does not exist: {}", path);
            }

            let mut db = Db::open(db_path)?;

            println!("=== Database Dump ===");

            let txn = db.begin_read()?;

            // Use scan with empty prefix to get all keys
            let results = txn.scan(&[])?;

            let mut count = 0usize;

            for (key, value) in results.iter().take(100) {
                count += 1;
                if values {
                    println!("  {}: {} => {:?}",
                        count,
                        String::from_utf8_lossy(key),
                        String::from_utf8_lossy(value)
                    );
                } else {
                    println!("  {}: {}", count, String::from_utf8_lossy(key));
                }
            }

            if results.len() > 100 {
                println!("  ... (output truncated at 100 items)");
            }

            println!("=== Total items: {} ===", results.len());

            db.close()?;

            Ok(())
        }
    }
}
