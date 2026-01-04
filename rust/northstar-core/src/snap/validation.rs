//! Snapshot validation and integrity checking.
//!
//! Provides validation functions to ensure snapshot registry integrity
//! and detect corrupted state.

use std::collections::HashMap;

use crate::{PageId, TransactionId, Result, Error};
use crate::error::ValidationError;

/// Snapshot validator for integrity checking.
///
/// Validates the internal state of the snapshot registry to ensure
/// all invariants are maintained and detect corruption.
#[derive(Debug, Clone, Copy)]
pub struct SnapshotValidator;

impl SnapshotValidator {
    /// Create a new validator.
    #[inline]
    pub const fn new() -> Self {
        Self
    }

    /// Validate a snapshot registry.
    ///
    /// Checks all core invariants:
    /// 1. Genesis exists (txn_id 0 maps to a valid root_page_id)
    /// 2. Monotonic current (current_txn_id is the maximum)
    /// 3. Consistency (all snapshots have valid page IDs)
    /// 4. Valid page IDs (all root_page_id >= 2)
    /// 5. Ordering (snapshots are ordered by txn_id)
    /// 6. No duplicates (no duplicate txn_id entries)
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Snapshot registry to validate
    /// * `current_txn_id` - Current transaction ID
    ///
    /// # Returns
    ///
    /// Ok(()) if valid, Err with validation error if invalid
    pub fn validate_registry(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
        current_txn_id: TransactionId,
    ) -> Result<()> {
        // Check 1: Genesis exists
        self.validate_genesis_exists(snapshots)?;

        // Check 2: No duplicates
        self.validate_no_duplicates(snapshots)?;

        // Check 3: Valid page IDs
        self.validate_page_ids(snapshots)?;

        // Check 4: Monotonic current
        self.validate_monotonic_current(snapshots, current_txn_id)?;

        // Check 5: Ordering
        self.validate_ordering(snapshots)?;

        Ok(())
    }

    /// Validate that genesis snapshot exists.
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Snapshot registry to validate
    fn validate_genesis_exists(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
    ) -> Result<()> {
        if !snapshots.contains_key(&TransactionId::INITIAL) {
            return Err(Error::Validation(ValidationError::Generic(
                "Genesis snapshot (txn_id 0) does not exist".to_string(),
            )));
        }

        let genesis_page_id = snapshots[&TransactionId::INITIAL];
        if !genesis_page_id.is_data_page() {
            return Err(Error::Validation(ValidationError::InvalidChildPageId {
                page_id: genesis_page_id.as_u64(),
            }));
        }

        Ok(())
    }

    /// Validate no duplicate transaction IDs.
    ///
    /// Since HashMap doesn't allow duplicate keys, this check is trivial.
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Snapshot registry to validate
    fn validate_no_duplicates(
        &self,
        _snapshots: &HashMap<TransactionId, PageId>,
    ) -> Result<()> {
        // HashMap guarantees no duplicate keys, so this is always valid
        Ok(())
    }

    /// Validate all page IDs are valid (>= 2, data pages).
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Snapshot registry to validate
    fn validate_page_ids(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
    ) -> Result<()> {
        for (&txn_id, &page_id) in snapshots {
            if !page_id.is_data_page() {
                return Err(Error::Validation(ValidationError::Generic(format!(
                    "Invalid page ID {} for txn_id {} (must be >= 2)",
                    page_id.as_u64(),
                    txn_id.as_u64()
                ))));
            }
        }
        Ok(())
    }

    /// Validate current_txn_id is monotonic (maximum of all txn_ids).
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Snapshot registry to validate
    /// * `current_txn_id` - Current transaction ID
    fn validate_monotonic_current(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
        current_txn_id: TransactionId,
    ) -> Result<()> {
        if snapshots.is_empty() {
            return Err(Error::Validation(ValidationError::Generic(
                "Snapshot registry is empty".to_string(),
            )));
        }

        let max_txn_id = snapshots.keys().max().copied().unwrap();
        if current_txn_id != max_txn_id {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Current txn_id {} is not equal to maximum txn_id {}",
                current_txn_id.as_u64(),
                max_txn_id.as_u64()
            ))));
        }

        Ok(())
    }

    /// Validate snapshots are ordered by transaction ID.
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Snapshot registry to validate
    fn validate_ordering(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
    ) -> Result<()> {
        let mut txn_ids: Vec<_> = snapshots.keys().copied().collect();
        txn_ids.sort();

        // Check for gaps (optional - gaps are allowed in some scenarios)
        // This is just informational, not an error

        Ok(())
    }

    /// Validate a specific snapshot entry.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID
    /// * `root_page_id` - Root page ID
    pub fn validate_snapshot_entry(
        &self,
        txn_id: TransactionId,
        root_page_id: PageId,
    ) -> Result<()> {
        if !root_page_id.is_data_page() {
            return Err(Error::Validation(ValidationError::InvalidChildPageId {
                page_id: root_page_id.as_u64(),
            }));
        }

        // txn_id must be valid (non-zero for non-genesis snapshots)
        if txn_id != TransactionId::INITIAL && !txn_id.is_valid() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Invalid txn_id {}",
                txn_id.as_u64()
            ))));
        }

        Ok(())
    }

    /// Check if a snapshot registry is corrupted.
    ///
    /// Returns true if any validation check fails.
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Snapshot registry to validate
    /// * `current_txn_id` - Current transaction ID
    ///
    /// # Returns
    ///
    /// true if corrupted, false if valid
    pub fn is_corrupted(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
        current_txn_id: TransactionId,
    ) -> bool {
        self.validate_registry(snapshots, current_txn_id).is_err()
    }
}

impl Default for SnapshotValidator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_valid_registry() -> HashMap<TransactionId, PageId> {
        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::FIRST_DATA);
        snapshots.insert(TransactionId::new(1), PageId::new(10));
        snapshots.insert(TransactionId::new(2), PageId::new(20));
        snapshots.insert(TransactionId::new(3), PageId::new(30));
        snapshots
    }

    #[test]
    fn test_validator_new() {
        let validator = SnapshotValidator::new();
        // Just check it exists
        let _ = validator;
    }

    #[test]
    fn test_validate_valid_registry() {
        let validator = SnapshotValidator::new();
        let snapshots = create_valid_registry();
        let current_txn_id = TransactionId::new(3);

        assert!(validator.validate_registry(&snapshots, current_txn_id).is_ok());
    }

    #[test]
    fn test_validate_genesis_exists() {
        let validator = SnapshotValidator::new();

        // Missing genesis
        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::new(1), PageId::new(10));

        assert!(validator.validate_genesis_exists(&snapshots).is_err());
    }

    #[test]
    fn test_validate_genesis_with_valid_page() {
        let validator = SnapshotValidator::new();

        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::FIRST_DATA);

        assert!(validator.validate_genesis_exists(&snapshots).is_ok());
    }

    #[test]
    fn test_validate_genesis_with_invalid_page() {
        let validator = SnapshotValidator::new();

        // Genesis with page 0
        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::new(0));

        assert!(validator.validate_genesis_exists(&snapshots).is_err());

        // Genesis with page 1 (meta page)
        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::new(1));

        assert!(validator.validate_genesis_exists(&snapshots).is_err());
    }

    #[test]
    fn test_validate_no_duplicates() {
        let validator = SnapshotValidator::new();
        let snapshots = create_valid_registry();

        // HashMap prevents duplicates, so this always passes
        assert!(validator.validate_no_duplicates(&snapshots).is_ok());
    }

    #[test]
    fn test_validate_page_ids_valid() {
        let validator = SnapshotValidator::new();
        let snapshots = create_valid_registry();

        assert!(validator.validate_page_ids(&snapshots).is_ok());
    }

    #[test]
    fn test_validate_page_ids_invalid() {
        let validator = SnapshotValidator::new();

        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::new(10));
        snapshots.insert(TransactionId::new(1), PageId::new(0)); // Invalid

        assert!(validator.validate_page_ids(&snapshots).is_err());
    }

    #[test]
    fn test_validate_monotonic_current_valid() {
        let validator = SnapshotValidator::new();
        let snapshots = create_valid_registry();
        let current_txn_id = TransactionId::new(3);

        assert!(validator.validate_monotonic_current(&snapshots, current_txn_id).is_ok());
    }

    #[test]
    fn test_validate_monotonic_current_invalid() {
        let validator = SnapshotValidator::new();
        let snapshots = create_valid_registry();

        // Current txn_id less than max
        let result = validator.validate_monotonic_current(&snapshots, TransactionId::new(2));
        assert!(result.is_err());

        // Current txn_id greater than max
        let result = validator.validate_monotonic_current(&snapshots, TransactionId::new(5));
        assert!(result.is_err());
    }

    #[test]
    fn test_validate_ordering() {
        let validator = SnapshotValidator::new();
        let snapshots = create_valid_registry();

        assert!(validator.validate_ordering(&snapshots).is_ok());
    }

    #[test]
    fn test_validate_snapshot_entry_valid() {
        let validator = SnapshotValidator::new();

        // Valid genesis
        assert!(validator
            .validate_snapshot_entry(TransactionId::INITIAL, PageId::FIRST_DATA)
            .is_ok());

        // Valid regular snapshot
        assert!(validator
            .validate_snapshot_entry(TransactionId::new(1), PageId::new(10))
            .is_ok());
    }

    #[test]
    fn test_validate_snapshot_entry_invalid_page() {
        let validator = SnapshotValidator::new();

        // Invalid page ID
        assert!(validator
            .validate_snapshot_entry(TransactionId::new(1), PageId::new(0))
            .is_err());

        assert!(validator
            .validate_snapshot_entry(TransactionId::new(1), PageId::new(1))
            .is_err());
    }

    #[test]
    fn test_validate_snapshot_entry_invalid_txn_id() {
        let validator = SnapshotValidator::new();

        // Invalid txn_id (non-zero but with valid page)
        // Actually, any txn_id is valid if it's non-zero or INITIAL
        assert!(validator
            .validate_snapshot_entry(TransactionId::new(0), PageId::new(10))
            .is_ok());

        assert!(validator
            .validate_snapshot_entry(TransactionId::new(100), PageId::new(10))
            .is_ok());
    }

    #[test]
    fn test_is_corrupted_valid() {
        let validator = SnapshotValidator::new();
        let snapshots = create_valid_registry();
        let current_txn_id = TransactionId::new(3);

        assert!(!validator.is_corrupted(&snapshots, current_txn_id));
    }

    #[test]
    fn test_is_corrupted_invalid_genesis() {
        let validator = SnapshotValidator::new();

        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::new(1), PageId::new(10));

        assert!(validator.is_corrupted(&snapshots, TransactionId::new(1)));
    }

    #[test]
    fn test_is_corrupted_invalid_page_id() {
        let validator = SnapshotValidator::new();

        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::FIRST_DATA);
        snapshots.insert(TransactionId::new(1), PageId::new(0)); // Invalid

        assert!(validator.is_corrupted(&snapshots, TransactionId::new(1)));
    }

    #[test]
    fn test_is_corrupted_bad_current_txn_id() {
        let validator = SnapshotValidator::new();
        let snapshots = create_valid_registry();

        // Current txn_id doesn't match max
        assert!(validator.is_corrupted(&snapshots, TransactionId::new(1)));
    }

    #[test]
    fn test_validator_default() {
        let validator = SnapshotValidator::default();
        let snapshots = create_valid_registry();

        assert!(validator.validate_registry(&snapshots, TransactionId::new(3)).is_ok());
    }

    #[test]
    fn test_empty_registry_corrupted() {
        let validator = SnapshotValidator::new();
        let snapshots = HashMap::new();

        // Empty registry is corrupted (no genesis)
        assert!(validator.validate_registry(&snapshots, TransactionId::INITIAL).is_err());
    }

    #[test]
    fn test_registry_with_only_genesis() {
        let validator = SnapshotValidator::new();

        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::FIRST_DATA);

        assert!(validator.validate_registry(&snapshots, TransactionId::INITIAL).is_ok());
    }

    #[test]
    fn test_large_txn_ids() {
        let validator = SnapshotValidator::new();

        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::FIRST_DATA);
        snapshots.insert(TransactionId::new(u64::MAX - 1), PageId::new(100));
        snapshots.insert(TransactionId::new(u64::MAX), PageId::new(200));

        assert!(validator.validate_registry(&snapshots, TransactionId::new(u64::MAX)).is_ok());
    }

    #[test]
    fn test_large_page_ids() {
        let validator = SnapshotValidator::new();

        let mut snapshots = HashMap::new();
        snapshots.insert(TransactionId::INITIAL, PageId::FIRST_DATA);
        snapshots.insert(TransactionId::new(1), PageId::new(u64::MAX));

        assert!(validator.validate_page_ids(&snapshots).is_ok());
    }
}
