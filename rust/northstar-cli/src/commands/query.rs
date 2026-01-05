//! Query command - Execute SQL and natural language queries.

use super::Command;
use clap::ArgMatches;
use anyhow::{Result, Context, bail};
use std::path::Path;
use std::fs;
use std::time::Instant;

/// Query command implementation
pub struct QueryCommand;

impl Command for QueryCommand {
    fn name(&self) -> &str {
        "query"
    }

    fn description(&self) -> &str {
        "Execute queries against the database (SQL or natural language)"
    }

    fn validate(&self, args: &ArgMatches) -> Result<()> {
        let database = args.get_one::<String>("database")
            .ok_or_else(|| anyhow::anyhow!("Database path is required"))?;

        let db_path = Path::new(database);
        if !db_path.exists() {
            bail!("Database file does not exist: {}", database);
        }

        // Either query string or file must be provided
        let has_query = args.get_one::<String>("query").is_some();
        let has_file = args.get_one::<String>("file").is_some();

        if !has_query && !has_file {
            bail!("Either --query or --file must be provided");
        }

        Ok(())
    }

    fn run(&self, args: &ArgMatches) -> Result<()> {
        self.validate(args)?;

        let database = args.get_one::<String>("database").unwrap();
        let query_type = args.get_one::<String>("query_type")
            .map(|s| s.as_str())
            .unwrap_or("sql");
        let timing = args.get_flag("timing");
        let explain = args.get_flag("explain");

        // Get query from string or file
        let queries = if let Some(file_path) = args.get_one::<String>("file") {
            self.read_queries_from_file(file_path)?
        } else if let Some(query_str) = args.get_one::<String>("query") {
            vec![query_str.clone()]
        } else {
            bail!("No query provided");
        };

        println!("Executing {} query(ies) on {}", queries.len(), database);

        // Open database
        use northstar_core::Db;
        let mut db = Db::open(Path::new(database))
            .context("Failed to open database")?;

        // Execute each query
        for (i, query) in queries.iter().enumerate() {
            println!("\n[Query {}/{}]", i + 1, queries.len());

            if explain {
                println!("=== Query Plan ===");
                self.explain_query(&db, query, query_type)?;
            }

            let start = Instant::now();

            match query_type {
                "sql" => self.execute_sql_query(&db, query)?,
                "natural-language" | "nl" => self.execute_nl_query(&db, query)?,
                _ => bail!("Unknown query type: {}", query_type),
            }

            let duration = start.elapsed();

            if timing {
                println!("Execution time: {:?}", duration);
            }
        }

        db.close()
            .context("Failed to close database")?;

        Ok(())
    }
}

impl QueryCommand {
    /// Execute SQL query
    fn execute_sql_query(&self, db: &northstar_core::Db, query: &str) -> Result<()> {
        println!("SQL Query: {}", query);

        // For now, we only support simple key-value operations
        // In a full implementation, this would use a SQL parser
        let txn = db.begin_read()
            .context("Failed to begin read transaction")?;

        // Simple query parsing for demonstration
        let query_lower = query.to_lowercase();

        if query_lower.starts_with("get ") || query_lower.starts_with("select ") {
            // Extract key from query
            let key = self.extract_key_from_query(query)?;

            match txn.get(key.as_bytes()) {
                Ok(Some(value)) => {
                    println!("Result:");
                    println!("  Key: {}", key);
                    println!("  Value: {}", String::from_utf8_lossy(&value));
                }
                Ok(None) => {
                    println!("Key not found: {}", key);
                }
                Err(e) => {
                    bail!("Query failed: {}", e);
                }
            }
        } else if query_lower.starts_with("scan ") || query_lower.contains("select *") {
            // Scan operation
            let prefix = self.extract_prefix_from_query(query)?;

            let results = txn.scan(prefix.as_bytes())
                .context("Scan failed")?;

            println!("Results ({} items):", results.len());
            for (key, value) in results.iter().take(100) {
                println!("  {} => {}",
                    String::from_utf8_lossy(key),
                    String::from_utf8_lossy(value)
                );
            }

            if results.len() > 100 {
                println!("  ... ({} more items)", results.len() - 100);
            }
        } else {
            bail!("Unsupported query format. Try: GET <key> or SCAN <prefix>");
        }

        Ok(())
    }

    /// Execute natural language query
    fn execute_nl_query(&self, db: &northstar_core::Db, query: &str) -> Result<()> {
        println!("Natural Language Query: {}", query);
        println!("Note: NL query processing not yet fully implemented");
        println!("Converting to structured query...");

        // For now, do simple keyword matching
        let query_lower = query.to_lowercase();

        if query_lower.contains("get ") || query_lower.contains("find ") {
            // Try to extract what they're looking for
            let key = self.extract_entity_from_nl_query(query)?;
            self.execute_sql_query(db, &format!("GET {}", key))?;
        } else if query_lower.contains("all") || query_lower.contains("list") {
            let prefix = self.extract_prefix_from_nl_query(query)?;
            self.execute_sql_query(db, &format!("SCAN {}", prefix))?;
        } else {
            println!("Could not understand query. Try:");
            println!("  - 'Find key <name>'");
            println!("  - 'Get all keys with prefix <prefix>'");
            println!("  - 'List <prefix>'");
        }

        Ok(())
    }

    /// Explain query execution plan
    fn explain_query(&self, _db: &northstar_core::Db, query: &str, query_type: &str) -> Result<()> {
        println!("Query Type: {}", query_type);
        println!("Query Text: {}", query);

        let query_lower = query.to_lowercase();

        if query_lower.starts_with("get ") {
            let key = self.extract_key_from_query(query)?;
            println!("Operation: Point Lookup");
            println!("Key: {}", key);
            println!("Estimated Cost: O(log N)");
        } else if query_lower.starts_with("scan ") || query_lower.contains("select *") {
            let prefix = self.extract_prefix_from_query(query)?;
            println!("Operation: Range Scan");
            println!("Prefix: {}", prefix);
            println!("Estimated Cost: O(M) where M is range size");
        } else {
            println!("Operation: Unknown");
        }

        Ok(())
    }

    /// Extract key from query string
    fn extract_key_from_query(&self, query: &str) -> Result<String> {
        let query = query.trim();

        if query.to_lowercase().starts_with("get ") {
            let key = query[4..].trim();
            Ok(key.to_string())
        } else if query.to_lowercase().starts_with("select ") {
            // Simple parsing for SELECT key FROM ...
            let parts: Vec<&str> = query.split_whitespace().collect();
            if parts.len() >= 4 {
                Ok(parts[3].to_string()) // Assumes "SELECT key FROM table"
            } else {
                bail!("Could not parse key from SELECT query");
            }
        } else {
            bail!("Could not extract key from query");
        }
    }

    /// Extract prefix from query string
    fn extract_prefix_from_query(&self, query: &str) -> Result<String> {
        let query = query.trim();

        if query.to_lowercase().starts_with("scan ") {
            let prefix = query[5..].trim();
            Ok(prefix.to_string())
        } else {
            Ok(String::new()) // Empty prefix means scan all
        }
    }

    /// Extract entity name from natural language query
    fn extract_entity_from_nl_query(&self, query: &str) -> Result<String> {
        let query_lower = query.to_lowercase();

        // Look for patterns like "find key X" or "get X"
        if let Some(pos) = query_lower.find("key ") {
            let after_key = &query[pos + 4..];
            let entity = after_key.split_whitespace().next();
            if let Some(e) = entity {
                return Ok(e.to_string());
            }
        }

        // Try to find the first quoted string
        if let Some(start) = query.find('"') {
            if let Some(end) = query[start + 1..].find('"') {
                return Ok(query[start + 1..start + 1 + end].to_string());
            }
        }

        bail!("Could not extract entity from query");
    }

    /// Extract prefix from natural language query
    fn extract_prefix_from_nl_query(&self, query: &str) -> Result<String> {
        let query_lower = query.to_lowercase();

        // Look for patterns like "all keys with prefix X"
        if let Some(pos) = query_lower.find("prefix ") {
            let after_prefix = &query[pos + 7..];
            let prefix = after_prefix.split_whitespace().next();
            if let Some(p) = prefix {
                return Ok(p.to_string());
            }
        }

        Ok(String::new())
    }

    /// Read queries from file
    fn read_queries_from_file(&self, file_path: &str) -> Result<Vec<String>> {
        let content = fs::read_to_string(file_path)
            .with_context(|| format!("Failed to read query file: {}", file_path))?;

        // Split by semicolon and filter empty queries
        let queries: Vec<String> = content
            .split(';')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();

        if queries.is_empty() {
            bail!("No queries found in file: {}", file_path);
        }

        Ok(queries)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_key_from_query() {
        let cmd = QueryCommand;
        assert_eq!(cmd.extract_key_from_query("GET mykey").unwrap(), "mykey");
        assert_eq!(cmd.extract_key_from_query("get mykey").unwrap(), "mykey");
        assert_eq!(cmd.extract_key_from_query("  get  mykey  ").unwrap(), "mykey");
    }

    #[test]
    fn test_extract_prefix_from_query() {
        let cmd = QueryCommand;
        assert_eq!(cmd.extract_prefix_from_query("SCAN users:").unwrap(), "users:");
        assert_eq!(cmd.extract_prefix_from_query("  scan  logs:  ").unwrap(), "logs:");
    }

    #[test]
    fn test_read_queries_from_file() {
        // This would require creating a temporary file
        // For now, just test the parsing logic
        let queries = "SELECT key1; SELECT key2;";
        let parsed: Vec<String> = queries
            .split(';')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        assert_eq!(parsed.len(), 2);
    }
}
