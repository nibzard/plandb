//! Concurrency control for snapshot operations.
//!
//! Provides thread-safe access to snapshot registry using RwLock for
//! many-reader single-writer concurrency.

use std::sync::RwLock;
use std::collections::HashMap;

use crate::{TransactionId, PageId};

/// Thread-safe wrapper for snapshot registry data.
///
/// Uses RwLock to allow many concurrent readers while ensuring
/// exclusive access for writers.
#[derive(Debug)]
pub struct SnapshotConcurrency {
    /// Inner registry data protected by RwLock
    inner: RwLock<RegistryData>,
}

/// Internal registry data structure.
#[derive(Debug)]
struct RegistryData {
    /// Mapping from transaction_id to root_page_id
    snapshots: HashMap<TransactionId, PageId>,

    /// Current transaction ID (monotonically increasing)
    current_txn_id: TransactionId,

    /// Reference counts for each snapshot
    ref_counts: HashMap<TransactionId, usize>,
}

impl SnapshotConcurrency {
    /// Create a new concurrent registry.
    ///
    /// # Panics
    ///
    /// Panics if the RwLock is poisoned (should never happen in normal operation).
    #[inline]
    pub fn new(genesis_page_id: PageId) -> Self {
        Self::with_txn_id(genesis_page_id, TransactionId::INITIAL)
    }

    /// Create a new concurrent registry with a specific starting transaction ID.
    ///
    /// This is used when reopening a database to restore the persisted transaction state.
    ///
    /// # Panics
    ///
    /// Panics if the RwLock is poisoned (should never happen in normal operation).
    #[inline]
    pub fn with_txn_id(genesis_page_id: PageId, current_txn_id: TransactionId) -> Self {
        let mut snapshots = HashMap::new();
        // For recovered databases, we only have the latest snapshot
        snapshots.insert(current_txn_id, genesis_page_id);

        let ref_counts = HashMap::new(); // Start with no active snapshot handles

        Self {
            inner: RwLock::new(RegistryData {
                snapshots,
                current_txn_id,
                ref_counts,
            }),
        }
    }

    /// Read snapshot data with shared lock.
    ///
    /// Returns a read guard that provides access to the snapshot registry.
    /// Multiple readers can hold read guards simultaneously.
    ///
    /// # Panics
    ///
    /// Panics if the RwLock is poisoned.
    #[inline]
    pub fn read(&self) -> std::sync::RwLockReadGuard<RegistryData> {
        self.inner.read().expect("RwLock poisoned")
    }

    /// Write snapshot data with exclusive lock.
    ///
    /// Returns a write guard that provides mutable access to the snapshot registry.
    /// Only one writer can hold a write guard, and no readers can access while
    /// a write guard is held.
    ///
    /// # Panics
    ///
    /// Panics if the RwLock is poisoned.
    #[inline]
    pub fn write(&self) -> std::sync::RwLockWriteGuard<RegistryData> {
        self.inner.write().expect("RwLock poisoned")
    }

    /// Get the root page ID for a transaction (read lock).
    ///
    /// Returns None if the transaction ID is not registered.
    #[inline]
    pub fn get_snapshot_root(&self, txn_id: TransactionId) -> Option<PageId> {
        self.read().snapshots.get(&txn_id).copied()
    }

    /// Get the current transaction ID (read lock).
    #[inline]
    pub fn get_current_txn_id(&self) -> TransactionId {
        self.read().current_txn_id
    }

    /// Check if a snapshot exists (read lock).
    #[inline]
    pub fn has_snapshot(&self, txn_id: TransactionId) -> bool {
        self.read().snapshots.contains_key(&txn_id)
    }

    /// Get the latest snapshot (read lock).
    ///
    /// Returns the most recent transaction ID and its root page ID.
    #[inline]
    pub fn get_latest_snapshot(&self) -> Option<(TransactionId, PageId)> {
        let data = self.read();
        let txn_id = data.current_txn_id;
        data.snapshots.get(&txn_id).map(|&page_id| (txn_id, page_id))
    }

    /// Increment reference count for a snapshot (write lock).
    ///
    /// Returns the new reference count.
    #[inline]
    pub fn increment_ref_count(&self, txn_id: TransactionId) -> usize {
        let mut data = self.write();
        let count = data.ref_counts.entry(txn_id).or_insert(0);
        *count += 1;
        *count
    }

    /// Decrement reference count for a snapshot (write lock).
    ///
    /// Returns the new reference count, or None if the transaction ID was not found.
    #[inline]
    pub fn decrement_ref_count(&self, txn_id: TransactionId) -> Option<usize> {
        let mut data = self.write();
        if let Some(count) = data.ref_counts.get_mut(&txn_id) {
            *count = count.saturating_sub(1);
            let new_count = *count;
            if new_count == 0 {
                data.ref_counts.remove(&txn_id);
                return Some(0);
            }
            return Some(new_count);
        }
        None
    }

    /// Get reference count for a snapshot (read lock).
    #[inline]
    pub fn get_ref_count(&self, txn_id: TransactionId) -> usize {
        self.read().ref_counts.get(&txn_id).copied().unwrap_or(0)
    }

    /// Register a new snapshot (write lock).
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID
    /// * `root_page_id` - Root page ID for this snapshot
    #[inline]
    pub fn register(&self, txn_id: TransactionId, root_page_id: PageId) {
        let mut data = self.write();
        data.snapshots.insert(txn_id, root_page_id);
        data.ref_counts.insert(txn_id, 0); // Start with 0 refs, increment when Snapshot is created
        if txn_id > data.current_txn_id {
            data.current_txn_id = txn_id;
        }
    }

    /// Get all snapshots (read lock).
    #[inline]
    pub fn get_all_snapshots(&self) -> HashMap<TransactionId, PageId> {
        self.read().snapshots().clone()
    }

    /// Get reference counts (read lock).
    #[inline]
    pub fn get_ref_counts(&self) -> HashMap<TransactionId, usize> {
        self.read().ref_counts().clone()
    }

    /// Get snapshot count (read lock).
    #[inline]
    pub fn get_snapshot_count(&self) -> usize {
        self.read().snapshot_count()
    }
}

impl RegistryData {
    /// Get the root page ID for a transaction.
    #[inline]
    pub fn get_root(&self, txn_id: TransactionId) -> Option<PageId> {
        self.snapshots.get(&txn_id).copied()
    }

    /// Get the current transaction ID.
    #[inline]
    pub fn current(&self) -> TransactionId {
        self.current_txn_id
    }

    /// Check if a snapshot exists.
    #[inline]
    pub fn has_snapshot(&self, txn_id: TransactionId) -> bool {
        self.snapshots.contains_key(&txn_id)
    }

    /// Register a new snapshot.
    #[inline]
    pub fn register(&mut self, txn_id: TransactionId, root_page_id: PageId) {
        self.snapshots.insert(txn_id, root_page_id);
        self.ref_counts.insert(txn_id, 1);
        if txn_id > self.current_txn_id {
            self.current_txn_id = txn_id;
        }
    }

    /// Remove a snapshot.
    #[inline]
    pub fn remove(&mut self, txn_id: TransactionId) -> Option<PageId> {
        self.ref_counts.remove(&txn_id);
        self.snapshots.remove(&txn_id)
    }

    /// Get all snapshot entries.
    #[inline]
    pub fn snapshots(&self) -> &HashMap<TransactionId, PageId> {
        &self.snapshots
    }

    /// Get snapshot count.
    #[inline]
    pub fn snapshot_count(&self) -> usize {
        self.snapshots.len()
    }

    /// Get all reference counts.
    #[inline]
    pub fn ref_counts(&self) -> &HashMap<TransactionId, usize> {
        &self.ref_counts
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_concurrency_init() {
        let concurrency = SnapshotConcurrency::new(PageId::FIRST_DATA);
        assert_eq!(concurrency.get_current_txn_id(), TransactionId::INITIAL);
        assert_eq!(
            concurrency.get_snapshot_root(TransactionId::INITIAL),
            Some(PageId::FIRST_DATA)
        );
    }

    #[test]
    fn test_read_operations() {
        let concurrency = SnapshotConcurrency::new(PageId::FIRST_DATA);

        // Test get_snapshot_root
        assert_eq!(
            concurrency.get_snapshot_root(TransactionId::INITIAL),
            Some(PageId::FIRST_DATA)
        );
        assert_eq!(concurrency.get_snapshot_root(TransactionId::FIRST), None);

        // Test has_snapshot
        assert!(concurrency.has_snapshot(TransactionId::INITIAL));
        assert!(!concurrency.has_snapshot(TransactionId::FIRST));

        // Test get_latest_snapshot
        let (txn_id, page_id) = concurrency.get_latest_snapshot().unwrap();
        assert_eq!(txn_id, TransactionId::INITIAL);
        assert_eq!(page_id, PageId::FIRST_DATA);
    }

    #[test]
    fn test_ref_count_operations() {
        let concurrency = SnapshotConcurrency::new(PageId::FIRST_DATA);

        // Genesis starts with ref count 0 (no entry in HashMap)
        assert_eq!(concurrency.get_ref_count(TransactionId::INITIAL), 0);

        // Increment ref count
        assert_eq!(concurrency.increment_ref_count(TransactionId::INITIAL), 1);
        assert_eq!(concurrency.get_ref_count(TransactionId::INITIAL), 1);

        // Increment again
        assert_eq!(concurrency.increment_ref_count(TransactionId::INITIAL), 2);
        assert_eq!(concurrency.get_ref_count(TransactionId::INITIAL), 2);

        // Decrement ref count
        assert_eq!(concurrency.decrement_ref_count(TransactionId::INITIAL), Some(1));
        assert_eq!(concurrency.get_ref_count(TransactionId::INITIAL), 1);

        // Decrement to zero removes entry
        assert_eq!(concurrency.decrement_ref_count(TransactionId::INITIAL), Some(0));
        assert_eq!(concurrency.get_ref_count(TransactionId::INITIAL), 0);
    }

    #[test]
    fn test_write_operations() {
        let concurrency = SnapshotConcurrency::new(PageId::FIRST_DATA);

        let mut data = concurrency.write();

        // Register new snapshot
        data.register(TransactionId::FIRST, PageId::new(10));
        assert_eq!(data.current(), TransactionId::FIRST);
        assert_eq!(data.get_root(TransactionId::FIRST), Some(PageId::new(10)));

        // Check snapshot count
        assert_eq!(data.snapshot_count(), 2);

        // Remove snapshot
        let removed = data.remove(TransactionId::FIRST);
        assert_eq!(removed, Some(PageId::new(10)));
        assert_eq!(data.snapshot_count(), 1);
    }

    #[test]
    fn test_concurrent_readers() {
        use std::sync::Arc;
        use std::thread;

        let concurrency = Arc::new(SnapshotConcurrency::new(PageId::FIRST_DATA));
        let mut handles = vec![];

        // Spawn multiple readers
        for _ in 0..10 {
            let c = Arc::clone(&concurrency);
            handles.push(thread::spawn(move || {
                c.get_current_txn_id()
            }));
        }

        // All readers should succeed
        for handle in handles {
            let txn_id = handle.join().unwrap();
            assert_eq!(txn_id, TransactionId::INITIAL);
        }
    }

    #[test]
    fn test_concurrent_writer() {
        use std::sync::Arc;
        use std::thread;

        let concurrency = Arc::new(SnapshotConcurrency::new(PageId::FIRST_DATA));
        let c = Arc::clone(&concurrency);

        // Spawn writer thread
        let handle = thread::spawn(move || {
            let mut data = c.write();
            data.register(TransactionId::FIRST, PageId::new(10));
            data.current()
        });

        let new_txn_id = handle.join().unwrap();
        assert_eq!(new_txn_id, TransactionId::FIRST);
        assert_eq!(concurrency.get_current_txn_id(), TransactionId::FIRST);
    }

    #[test]
    fn test_ref_count_saturating_sub() {
        let concurrency = SnapshotConcurrency::new(PageId::FIRST_DATA);

        // Increment first to create the entry
        assert_eq!(concurrency.increment_ref_count(TransactionId::INITIAL), 1);

        // Decrement should work
        assert_eq!(concurrency.decrement_ref_count(TransactionId::INITIAL), Some(0));

        // Decrementing 0 removes the entry and returns None
        assert_eq!(concurrency.decrement_ref_count(TransactionId::INITIAL), None);

        // Further decrements return None
        assert_eq!(concurrency.decrement_ref_count(TransactionId::INITIAL), None);
        assert_eq!(concurrency.get_ref_count(TransactionId::INITIAL), 0);
    }

    #[test]
    fn test_unknown_transaction_ref_count() {
        let concurrency = SnapshotConcurrency::new(PageId::FIRST_DATA);

        // Unknown transaction should have ref count 0
        assert_eq!(concurrency.get_ref_count(TransactionId::FIRST), 0);
        assert_eq!(concurrency.decrement_ref_count(TransactionId::FIRST), None);
    }
}
