//! Common utilities for integration tests.

use northstar_core::{db::Db, error::Result};
use tempfile::TempDir;

/// Test context that holds database instances and temp directories.
pub struct TestContext {
    /// Temporary directory for test files.
    pub temp_dir: TempDir,
    /// Path to the test database file.
    pub db_path: String,
}

impl TestContext {
    /// Create a new test context.
    pub fn new() -> std::io::Result<Self> {
        let temp_dir = TempDir::new()?;
        let db_path = temp_dir.path().join("test.db").to_string_lossy().to_string();
        Ok(Self { temp_dir, db_path })
    }

    /// Get database path.
    pub fn db_path(&self) -> &str {
        &self.db_path
    }
}

/// Create a test database with default configuration.
pub fn create_test_db(path: &str) -> Result<Db> {
    Db::open(path)
}

/// Generate test key-value pairs.
pub fn generate_test_kv(count: usize, prefix: &str) -> Vec<(Vec<u8>, Vec<u8>)> {
    (0..count)
        .map(|i| {
            let key = format!("{}{:08x}", prefix, i);
            let value = format!("value-{:08x}", i);
            (key.into_bytes(), value.into_bytes())
        })
        .collect()
}

/// Helper to populate database with test data.
pub fn populate_db(db: &Db, count: usize, prefix: &str) -> Result<()> {
    let test_data = generate_test_kv(count, prefix);
    let mut txn = db.begin_write()?;

    for (key, value) in test_data {
        txn.put(&key, &value)?;
    }

    txn.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_context_creation() {
        let ctx = TestContext::new().unwrap();
        assert!(ctx.temp_dir.path().exists());
        assert!(ctx.db_path().contains("test.db"));
    }
}
