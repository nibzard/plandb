//! Snapshot registry - central authority for managing MVCC snapshots.
//!
//! The registry maintains a mapping from transaction IDs to root page IDs,
//! enabling consistent snapshots of the database at different points in time.

use std::collections::HashMap;

use crate::{Pager, PageId, TransactionId, Result, Error};
use crate::error::{ValidationError, TransactionError};
use super::Snapshot;
use super::concurrency::SnapshotConcurrency;

/// Statistics about the snapshot registry.
#[derive(Debug, Clone, PartialEq)]
pub struct SnapshotStats {
    /// Number of snapshots currently registered
    pub snapshot_count: usize,

    /// Current transaction ID
    pub current_txn_id: u64,

    /// Number of snapshots with active references
    pub active_snapshots: usize,

    /// Oldest transaction ID with an active reference
    pub oldest_active_txn: Option<u64>,
}

/// Snapshot registry for MVCC.
///
/// The registry is the central authority for managing all snapshots in the
/// database. It maintains the mapping from transaction IDs to root page IDs,
/// tracks reference counts, and provides cleanup functionality.
///
/// # Invariants
///
/// 1. **Genesis exists**: txn_id 0 always maps to a valid root_page_id
/// 2. **Monotonic current**: current_txn_id never decreases
/// 3. **Consistency**: All registered snapshots have valid page IDs
/// 4. **Valid page IDs**: All root_page_id values >= 2 (first data page)
/// 5. **Ordering**: Newer snapshots have higher txn_id values
/// 6. **No duplicates**: No duplicate txn_id entries in the registry
pub struct SnapshotRegistry {
    /// Concurrency control for thread-safe operations
    concurrency: SnapshotConcurrency,

    /// Pager for page allocation and I/O
    pager: Pager,
}

impl SnapshotRegistry {
    /// Initialize a new snapshot registry.
    ///
    /// Creates a registry with the initial (genesis) snapshot at transaction ID 0,
    /// pointing to the specified root page ID.
    ///
    /// # Arguments
    ///
    /// * `pager` - Pager for page I/O operations
    ///
    /// # Returns
    ///
    /// A new SnapshotRegistry instance
    ///
    /// # Example
    ///
    /// ```rust
    /// use northstar_core::{Pager, snap::SnapshotRegistry};
    ///
    /// # fn example() -> northstar_core::Result<()> {
    /// let pager = Pager::create_memory()?;
    /// let registry = SnapshotRegistry::new(pager);
    /// # Ok(())
    /// # }
    /// ```
    pub fn new(pager: Pager) -> Self {
        Self {
            concurrency: SnapshotConcurrency::new(PageId::FIRST_DATA),
            pager,
        }
    }

    /// Initialize with a specific genesis page ID.
    ///
    /// # Arguments
    ///
    /// * `pager` - Pager for page I/O operations
    /// * `genesis_page_id` - Root page ID for the initial snapshot
    pub fn with_genesis(pager: Pager, genesis_page_id: PageId) -> Self {
        Self {
            concurrency: SnapshotConcurrency::new(genesis_page_id),
            pager,
        }
    }

    /// Register a new snapshot.
    ///
    /// Associates a transaction ID with a root page ID, creating a new
    /// snapshot that represents the database state after that transaction.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID for this snapshot
    /// * `root_page_id` - Root page ID representing the database state
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - The page ID is invalid (< 2, not a data page)
    /// - A snapshot with this txn_id already exists
    /// - The transaction ID is not monotonically increasing
    ///
    /// # Example
    ///
    /// ```rust
    /// use northstar_core::{Pager, PageId, TransactionId, snap::SnapshotRegistry};
    ///
    /// # fn example() -> northstar_core::Result<()> {
    /// let pager = Pager::create_memory()?;
    /// let registry = SnapshotRegistry::new(pager);
    ///
    /// registry.register_snapshot(TransactionId::FIRST, PageId::new(10))?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn register_snapshot(&self, txn_id: TransactionId, root_page_id: PageId) -> Result<()> {
        // Validate page ID
        if !root_page_id.is_data_page() {
            return Err(Error::Validation(ValidationError::InvalidChildPageId {
                page_id: root_page_id.as_u64(),
            }));
        }

        let current_txn_id = self.concurrency.get_current_txn_id();

        // Check for duplicate transaction ID
        if self.concurrency.has_snapshot(txn_id) {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Snapshot already exists for txn_id {}", txn_id.as_u64()),
            )));
        }

        // Ensure monotonic transaction IDs
        if txn_id <= current_txn_id {
            return Err(Error::Validation(ValidationError::Generic(
                format!("txn_id {} is not greater than current {}", txn_id.as_u64(), current_txn_id.as_u64()),
            )));
        }

        // Register the snapshot
        self.concurrency.register(txn_id, root_page_id);

        Ok(())
    }

    /// Get the root page ID for a snapshot.
    ///
    /// Returns the root page ID associated with the given transaction ID,
    /// or None if the snapshot doesn't exist.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to look up
    ///
    /// # Returns
    ///
    /// Some(PageId) if the snapshot exists, None otherwise
    pub fn get_snapshot_root(&self, txn_id: TransactionId) -> Option<PageId> {
        self.concurrency.get_snapshot_root(txn_id)
    }

    /// Get the latest snapshot.
    ///
    /// Returns the most recent snapshot (highest transaction ID) and its
    /// associated root page ID.
    ///
    /// # Returns
    ///
    /// Some((TransactionId, PageId)) if at least one snapshot exists,
    /// None otherwise (should never happen in practice)
    pub fn get_latest_snapshot(&self) -> Option<(TransactionId, PageId)> {
        self.concurrency.get_latest_snapshot()
    }

    /// Get the current transaction ID.
    ///
    /// Returns the highest transaction ID that has been registered.
    pub fn get_current_txn_id(&self) -> TransactionId {
        self.concurrency.get_current_txn_id()
    }

    /// Check if a snapshot exists.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to check
    ///
    /// # Returns
    ///
    /// true if the snapshot exists, false otherwise
    pub fn has_snapshot(&self, txn_id: TransactionId) -> bool {
        self.concurrency.has_snapshot(txn_id)
    }

    /// Get all registered snapshots.
    ///
    /// Returns a clone of the snapshot registry map. This is a read-only
    /// snapshot of the current state.
    ///
    /// # Returns
    ///
    /// HashMap mapping transaction IDs to root page IDs
    pub fn get_all_snapshots(&self) -> HashMap<TransactionId, PageId> {
        self.concurrency.get_all_snapshots()
    }

    /// Get registry statistics.
    ///
    /// Returns statistics about the current state of the snapshot registry.
    pub fn get_stats(&self) -> SnapshotStats {
        let snapshot_count = self.concurrency.get_snapshot_count();
        let current_txn_id = self.concurrency.get_current_txn_id();
        let ref_counts = self.concurrency.get_ref_counts();

        // Count only snapshots with active references (ref_count > 0)
        let active_snapshots = ref_counts.values().filter(|&&count| count > 0).count();
        let oldest_active_txn = ref_counts
            .iter()
            .filter(|(_, &count)| count > 0)
            .min_by_key(|(txn_id, _)| *txn_id)
            .map(|(id, _)| id.as_u64());

        SnapshotStats {
            snapshot_count,
            current_txn_id: current_txn_id.as_u64(),
            active_snapshots,
            oldest_active_txn,
        }
    }

    /// Increment reference count for a snapshot.
    ///
    /// Called when a Snapshot handle is created or cloned.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to increment reference count for
    ///
    /// # Returns
    ///
    /// The new reference count
    pub(super) fn increment_ref(&self, txn_id: TransactionId) -> usize {
        self.concurrency.increment_ref_count(txn_id)
    }

    /// Decrement reference count for a snapshot.
    ///
    /// Called when a Snapshot handle is dropped. When the reference count
    /// reaches zero, the snapshot becomes eligible for cleanup.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to decrement reference count for
    ///
    /// # Returns
    ///
    /// The new reference count, or None if the transaction ID was not found
    pub(super) fn decrement_ref(&self, txn_id: TransactionId) -> Option<usize> {
        self.concurrency.decrement_ref_count(txn_id)
    }

    /// Get reference count for a snapshot.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to get reference count for
    ///
    /// # Returns
    ///
    /// The current reference count (0 if not found)
    pub fn get_ref_count(&self, txn_id: TransactionId) -> usize {
        self.concurrency.get_ref_count(txn_id)
    }

    /// Get a reference to the pager.
    pub(crate) fn pager(&self) -> &Pager {
        &self.pager
    }

    /// Get a mutable reference to the pager.
    pub(crate) fn pager_mut(&mut self) -> &mut Pager {
        &mut self.pager
    }

    /// Close the registry and release the pager.
    pub(crate) fn close(&mut self) -> Result<()> {
        self.pager.close()
    }

    /// Sync pager data to stable storage.
    pub(crate) fn sync(&self) -> Result<()> {
        self.pager.sync()
    }

    /// Apply mutations to the B+Tree and return the new root page ID.
    ///
    /// This method takes a closure that receives a mutable B+Tree reference
    /// and applies mutations. After the mutations are applied, the new root
    /// page ID is returned for snapshot registration.
    ///
    /// # Arguments
    ///
    /// * `f` - Closure that takes `&mut BTree` and applies mutations
    ///
    /// # Returns
    ///
    /// The new root page ID after mutations are applied
    pub(crate) fn apply_mutations<F>(&mut self, f: F) -> Result<PageId>
    where
        F: FnOnce(&mut crate::btree::BTree) -> Result<()>,
    {
        // Get the current root page ID
        let root_page_id = self
            .get_latest_snapshot()
            .map(|(_, id)| id)
            .ok_or_else(|| Error::Transaction(TransactionError::SnapshotNotFound { txn_id: 0 }))?;

        // Create a BTree with a mutable reference to the pager
        // BTree now borrows the pager instead of owning it
        let mut btree = crate::btree::BTree::new(&mut self.pager, root_page_id)?;

        // Apply mutations
        f(&mut btree)?;

        // Get the new root page ID
        let new_root_page_id = btree.root_page_id();

        Ok(new_root_page_id)
    }

    /// Execute a read-only operation on the B+Tree at a specific snapshot.
    ///
    /// # Arguments
    ///
    /// * `root_page_id` - Root page ID for the snapshot to read
    /// * `f` - Function to execute with B+Tree access
    ///
    /// # Returns
    ///
    /// The result of the function
    pub(crate) fn with_btree<F, R>(&mut self, root_page_id: PageId, f: F) -> Result<R>
    where
        F: FnOnce(&mut crate::btree::BTree) -> Result<R>,
    {
        // Create a BTree with a mutable reference to the pager
        let mut btree = crate::btree::BTree::new(&mut self.pager, root_page_id)?;

        // Execute the read operation
        f(&mut btree)
    }
}

impl super::SnapshotOps for SnapshotRegistry {
    fn snapshot(&self) -> Result<Snapshot> {
        let (txn_id, root_page_id) = self
            .get_latest_snapshot()
            .ok_or_else(|| Error::Transaction(TransactionError::SnapshotNotFound { txn_id: 0 }))?;

        // Increment reference count
        self.increment_ref(txn_id);

        Ok(Snapshot::new(txn_id, root_page_id))
    }

    fn snapshot_at(&self, txn_id: TransactionId) -> Result<Snapshot> {
        let root_page_id = self
            .get_snapshot_root(txn_id)
            .ok_or_else(|| Error::Transaction(TransactionError::SnapshotNotFound { txn_id: txn_id.as_u64() }))?;

        // Increment reference count
        self.increment_ref(txn_id);

        Ok(Snapshot::new(txn_id, root_page_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_registry() -> SnapshotRegistry {
        let pager = Pager::create_memory().unwrap();
        SnapshotRegistry::new(pager)
    }

    #[test]
    fn test_registry_init() {
        let registry = create_test_registry();

        // Genesis snapshot should exist
        assert!(registry.has_snapshot(TransactionId::INITIAL));
        assert_eq!(
            registry.get_snapshot_root(TransactionId::INITIAL),
            Some(PageId::FIRST_DATA)
        );

        // Current txn ID should be INITIAL (0)
        assert_eq!(registry.get_current_txn_id(), TransactionId::INITIAL);

        // Latest snapshot should be genesis
        let (txn_id, page_id) = registry.get_latest_snapshot().unwrap();
        assert_eq!(txn_id, TransactionId::INITIAL);
        assert_eq!(page_id, PageId::FIRST_DATA);
    }

    #[test]
    fn test_register_snapshot() {
        let registry = create_test_registry();

        // Register first snapshot
        registry
            .register_snapshot(TransactionId::FIRST, PageId::new(10))
            .unwrap();

        // Verify registration
        assert!(registry.has_snapshot(TransactionId::FIRST));
        assert_eq!(
            registry.get_snapshot_root(TransactionId::FIRST),
            Some(PageId::new(10))
        );

        // Current txn ID should advance
        assert_eq!(registry.get_current_txn_id(), TransactionId::FIRST);

        // Latest snapshot should be the new one
        let (txn_id, page_id) = registry.get_latest_snapshot().unwrap();
        assert_eq!(txn_id, TransactionId::FIRST);
        assert_eq!(page_id, PageId::new(10));
    }

    #[test]
    fn test_register_multiple_snapshots() {
        let registry = create_test_registry();

        // Register multiple snapshots
        registry
            .register_snapshot(TransactionId::new(1), PageId::new(10))
            .unwrap();
        registry
            .register_snapshot(TransactionId::new(2), PageId::new(20))
            .unwrap();
        registry
            .register_snapshot(TransactionId::new(3), PageId::new(30))
            .unwrap();

        // All should be registered
        assert!(registry.has_snapshot(TransactionId::new(0)));
        assert!(registry.has_snapshot(TransactionId::new(1)));
        assert!(registry.has_snapshot(TransactionId::new(2)));
        assert!(registry.has_snapshot(TransactionId::new(3)));

        // Current should be the last one
        assert_eq!(registry.get_current_txn_id(), TransactionId::new(3));
    }

    #[test]
    fn test_register_invalid_page_id() {
        let registry = create_test_registry();

        // Page ID 0 (null/invalid)
        let result = registry.register_snapshot(TransactionId::FIRST, PageId::new(0));
        assert!(result.is_err());

        // Page ID 1 (meta page)
        let result = registry.register_snapshot(TransactionId::FIRST, PageId::new(1));
        assert!(result.is_err());
    }

    #[test]
    fn test_register_duplicate_txn_id() {
        let registry = create_test_registry();

        // Register first snapshot
        registry
            .register_snapshot(TransactionId::FIRST, PageId::new(10))
            .unwrap();

        // Try to register with same txn_id
        let result = registry.register_snapshot(TransactionId::FIRST, PageId::new(20));
        assert!(result.is_err());
    }

    #[test]
    fn test_register_non_monotonic() {
        let registry = create_test_registry();

        // Register txn 1
        registry
            .register_snapshot(TransactionId::new(1), PageId::new(10))
            .unwrap();

        // Try to register txn 0 (already exists, and not monotonic)
        let result = registry.register_snapshot(TransactionId::new(0), PageId::new(20));
        assert!(result.is_err());

        // Try to register txn 1 again (duplicate)
        let result = registry.register_snapshot(TransactionId::new(1), PageId::new(30));
        assert!(result.is_err());
    }

    #[test]
    fn test_get_snapshot_root_not_found() {
        let registry = create_test_registry();

        // Non-existent snapshot should return None
        assert_eq!(registry.get_snapshot_root(TransactionId::new(999)), None);
    }

    #[test]
    fn test_get_all_snapshots() {
        let registry = create_test_registry();

        // Register some snapshots
        registry
            .register_snapshot(TransactionId::new(1), PageId::new(10))
            .unwrap();
        registry
            .register_snapshot(TransactionId::new(2), PageId::new(20))
            .unwrap();

        // Get all snapshots
        let all = registry.get_all_snapshots();
        assert_eq!(all.len(), 3); // genesis + 2 registered
        assert_eq!(all.get(&TransactionId::new(0)), Some(&PageId::new(2)));
        assert_eq!(all.get(&TransactionId::new(1)), Some(&PageId::new(10)));
        assert_eq!(all.get(&TransactionId::new(2)), Some(&PageId::new(20)));
    }

    #[test]
    fn test_ref_count_operations() {
        let registry = create_test_registry();

        // Genesis starts with ref count 0 (no Snapshot handles yet)
        assert_eq!(registry.get_ref_count(TransactionId::INITIAL), 0);

        // Increment
        assert_eq!(registry.increment_ref(TransactionId::INITIAL), 1);
        assert_eq!(registry.get_ref_count(TransactionId::INITIAL), 1);

        // Increment again
        assert_eq!(registry.increment_ref(TransactionId::INITIAL), 2);
        assert_eq!(registry.get_ref_count(TransactionId::INITIAL), 2);

        // Decrement
        assert_eq!(registry.decrement_ref(TransactionId::INITIAL), Some(1));
        assert_eq!(registry.get_ref_count(TransactionId::INITIAL), 1);

        // Decrement to zero
        assert_eq!(registry.decrement_ref(TransactionId::INITIAL), Some(0));
        assert_eq!(registry.get_ref_count(TransactionId::INITIAL), 0);

        // Decrement below zero
        assert_eq!(registry.decrement_ref(TransactionId::INITIAL), None);
        assert_eq!(registry.get_ref_count(TransactionId::INITIAL), 0);
    }

    #[test]
    fn test_stats() {
        let registry = create_test_registry();

        // Initial stats
        let stats = registry.get_stats();
        assert_eq!(stats.snapshot_count, 1);
        assert_eq!(stats.current_txn_id, 0);
        assert_eq!(stats.active_snapshots, 0);
        assert_eq!(stats.oldest_active_txn, None);

        // Register some snapshots
        registry
            .register_snapshot(TransactionId::new(1), PageId::new(10))
            .unwrap();
        registry
            .register_snapshot(TransactionId::new(2), PageId::new(20))
            .unwrap();

        let stats = registry.get_stats();
        assert_eq!(stats.snapshot_count, 3);
        assert_eq!(stats.current_txn_id, 2);

        // Add some references
        registry.increment_ref(TransactionId::INITIAL);
        registry.increment_ref(TransactionId::new(1));

        let stats = registry.get_stats();
        assert_eq!(stats.active_snapshots, 2);
        assert_eq!(stats.oldest_active_txn, Some(0));
    }

    #[test]
    fn test_with_custom_genesis() {
        let pager = Pager::create_memory().unwrap();
        let registry = SnapshotRegistry::with_genesis(pager, PageId::new(100));

        // Genesis should be at custom page ID
        assert_eq!(
            registry.get_snapshot_root(TransactionId::INITIAL),
            Some(PageId::new(100))
        );
    }

    #[test]
    fn test_monotonic_txn_id_enforcement() {
        let registry = create_test_registry();

        // Register 1, 2, 3 in order
        registry
            .register_snapshot(TransactionId::new(1), PageId::new(10))
            .unwrap();
        registry
            .register_snapshot(TransactionId::new(2), PageId::new(20))
            .unwrap();
        registry
            .register_snapshot(TransactionId::new(3), PageId::new(30))
            .unwrap();

        // Try to go backwards
        let result = registry.register_snapshot(TransactionId::new(2), PageId::new(40));
        assert!(result.is_err());

        // Current should still be 3
        assert_eq!(registry.get_current_txn_id(), TransactionId::new(3));
    }

    #[test]
    fn test_concurrent_registration() {
        use std::sync::Arc;
        use std::thread;

        let registry = Arc::new(create_test_registry());
        let mut handles = vec![];

        // Spawn threads to register snapshots
        for i in 1..=10 {
            let r = Arc::clone(&registry);
            handles.push(thread::spawn(move || {
                r.register_snapshot(TransactionId::new(i as u64), PageId::new(i as u64 * 10))
            }));
        }

        // All registrations should fail because they're trying to register
        // concurrently without coordination (the first one wins, others fail)
        let mut success_count = 0;
        for handle in handles {
            if handle.join().unwrap().is_ok() {
                success_count += 1;
            }
        }

        // At least one should succeed
        assert!(success_count >= 1);
    }

    #[test]
    fn test_page_id_validation() {
        let registry = create_test_registry();

        // Test various invalid page IDs
        let invalid_ids = vec![PageId::new(0), PageId::new(1)];

        for invalid_id in invalid_ids {
            let result = registry.register_snapshot(TransactionId::FIRST, invalid_id);
            assert!(result.is_err(), "Should reject page ID {:?}", invalid_id);
        }

        // Valid page IDs should work
        let valid_ids = vec![PageId::new(2), PageId::new(10), PageId::new(100), PageId::new(u64::MAX)];

        for valid_id in valid_ids {
            let result = registry.register_snapshot(TransactionId::FIRST, valid_id);
            // First one succeeds, others fail due to duplicate txn_id
            if registry.get_current_txn_id() == TransactionId::INITIAL {
                assert!(result.is_ok(), "Should accept page ID {:?}", valid_id);
            }
        }
    }
}
