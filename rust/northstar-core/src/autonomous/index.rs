//! Automatic Index Management.
//!
//! Automatically creates, modifies, and drops indexes based on query patterns.

use crate::autonomous::{
    OptimizationType, OptimizationResult, SystemState,
    AutonomousResult, AutonomousError, OptimizationId,
};
use std::time::{SystemTime, Duration};
use std::collections::HashMap;

/// Index metadata.
#[derive(Debug, Clone)]
pub struct IndexMetadata {
    /// Index name
    pub name: String,

    /// Table name
    pub table: String,

    /// Columns in index
    pub columns: Vec<String>,

    /// Is unique index
    pub is_unique: bool,

    /// Index size in bytes
    pub size_bytes: u64,

    /// Created at
    pub created_at: SystemTime,

    /// Last used timestamp
    pub last_used_at: Option<SystemTime>,

    /// Usage count
    pub usage_count: u64,
}

/// Index creation progress.
#[derive(Debug, Clone)]
pub struct IndexProgress {
    /// Index name
    pub index_name: String,

    /// Progress percentage (0.0 to 1.0)
    pub progress: f64,

    /// Started at
    pub started_at: SystemTime,

    /// Estimated completion
    pub estimated_completion: SystemTime,
}

/// Automatic index manager.
pub struct IndexManager {
    /// Active indexes
    indexes: HashMap<String, IndexMetadata>,

    /// In-progress index creations
    in_progress: HashMap<String, IndexProgress>,
}

impl IndexManager {
    /// Create new index manager.
    pub fn new() -> Self {
        Self {
            indexes: HashMap::new(),
            in_progress: HashMap::new(),
        }
    }

    /// Check if index exists.
    pub fn index_exists(&self, table: &str, columns: &[String]) -> bool {
        self.indexes.values().any(|idx| {
            idx.table == table
                && idx.columns.len() == columns.len()
                && idx.columns.iter().zip(columns.iter()).all(|(a, b)| a == b)
        })
    }

    /// Get index by name.
    pub fn get_index(&self, name: &str) -> Option<&IndexMetadata> {
        self.indexes.get(name)
    }

    /// List all indexes.
    pub fn list_indexes(&self) -> Vec<&IndexMetadata> {
        self.indexes.values().collect()
    }

    /// Create index (start async operation).
    pub fn create_index(
        &mut self,
        table: String,
        columns: Vec<String>,
        is_unique: bool,
    ) -> AutonomousResult<OptimizationId> {
        // Check if index already exists
        if self.index_exists(&table, &columns) {
            return Err(AutonomousError::InvalidCandidate(
                "Index already exists".to_string(),
            ));
        }

        // Generate index name
        let index_name = format!("idx_{}_{}", table, columns.join("_"));

        // Create index metadata
        let metadata = IndexMetadata {
            name: index_name.clone(),
            table: table.clone(),
            columns: columns.clone(),
            is_unique,
            size_bytes: 0, // Will be updated after creation
            created_at: SystemTime::now(),
            last_used_at: None,
            usage_count: 0,
        };

        // Start index creation
        let progress = IndexProgress {
            index_name: index_name.clone(),
            progress: 0.0,
            started_at: SystemTime::now(),
            estimated_completion: SystemTime::now() + Duration::from_secs(300), // 5 minutes
        };

        self.in_progress.insert(index_name.clone(), progress);

        // Simulate async creation (in real implementation, this would be background task)
        let id = OptimizationId(1); // Would be actual ID
        Ok(id)
    }

    /// Drop index.
    pub fn drop_index(&mut self, index_name: &str) -> AutonomousResult<()> {
        if !self.indexes.contains_key(index_name) {
            return Err(AutonomousError::OptimizationNotFound(OptimizationId(0)));
        }

        self.indexes.remove(index_name);
        Ok(())
    }

    /// Update index usage.
    pub fn update_index_usage(&mut self, index_name: &str) {
        if let Some(index) = self.indexes.get_mut(index_name) {
            index.last_used_at = Some(SystemTime::now());
            index.usage_count += 1;
        }
    }

    /// Find unused indexes (not used in > 30 days).
    pub fn find_unused_indexes(&self, days_threshold: u64) -> Vec<String> {
        let threshold = SystemTime::now() - Duration::from_secs(days_threshold * 86400);

        self.indexes
            .values()
            .filter(|idx| {
                idx.last_used_at
                    .map(|last| last < threshold)
                    .unwrap_or(true)
            })
            .map(|idx| idx.name.clone())
            .collect()
    }

    /// Estimate index size.
    pub fn estimate_index_size(&self, table_size_bytes: u64, num_columns: usize) -> u64 {
        // Rough estimate: 20% of table size per column
        (table_size_bytes as f64 * 0.2 * num_columns as f64) as u64
    }

    /// Simulate index creation progress (for testing).
    pub fn update_progress(&mut self, index_name: &str, progress: f64) {
        if let Some(p) = self.in_progress.get_mut(index_name) {
            p.progress = progress.clamp(0.0, 1.0);

            // If complete, move to active indexes
            if p.progress >= 1.0 {
                if let Some(progress) = self.in_progress.remove(index_name) {
                    let metadata = IndexMetadata {
                        name: index_name.to_string(),
                        table: String::new(), // Would be from context
                        columns: vec![],
                        is_unique: false,
                        size_bytes: 0,
                        created_at: progress.started_at,
                        last_used_at: None,
                        usage_count: 0,
                    };
                    self.indexes.insert(index_name.to_string(), metadata);
                }
            }
        }
    }

    /// Get in-progress indexes.
    pub fn in_progress_indexes(&self) -> Vec<&IndexProgress> {
        self.in_progress.values().collect()
    }
}

impl Default for IndexManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_index_creation() {
        let mut manager = IndexManager::new();

        let result = manager.create_index(
            "users".to_string(),
            vec!["id".to_string()],
            false,
        );

        assert!(result.is_ok());
        assert!(!manager.in_progress_indexes().is_empty());
    }

    #[test]
    fn test_index_exists() {
        let mut manager = IndexManager::new();

        assert!(!manager.index_exists("users", &["id".to_string()]));

        let _ = manager.create_index("users".to_string(), vec!["id".to_string()], false);
        // Still doesn't exist because it's in progress
        assert!(!manager.index_exists("users", &["id".to_string()]));
    }

    #[test]
    fn test_find_unused_indexes() {
        let mut manager = IndexManager::new();

        // Add an old unused index
        let metadata = IndexMetadata {
            name: "idx_old".to_string(),
            table: "users".to_string(),
            columns: vec!["id".to_string()],
            is_unique: false,
            size_bytes: 1024,
            created_at: SystemTime::now() - Duration::from_secs(86400 * 100),
            last_used_at: Some(SystemTime::now() - Duration::from_secs(86400 * 60)),
            usage_count: 10,
        };

        manager.indexes.insert("idx_old".to_string(), metadata);

        let unused = manager.find_unused_indexes(30);
        assert_eq!(unused.len(), 1);
        assert_eq!(unused[0], "idx_old");
    }

    #[test]
    fn test_estimate_index_size() {
        let manager = IndexManager::new();

        let size = manager.estimate_index_size(1_000_000_000, 1); // 1GB table, 1 column
        assert_eq!(size, 200_000_000); // 200MB index

        let size = manager.estimate_index_size(1_000_000_000, 3); // 1GB table, 3 columns
        assert_eq!(size, 600_000_000); // 600MB index
    }
}
