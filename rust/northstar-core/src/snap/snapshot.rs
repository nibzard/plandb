//! Snapshot handle - represents a consistent view of the database.
//!
//! Snapshots provide MVCC read isolation by capturing the database state
//! at a specific point in time (transaction ID).

use std::sync::Arc;
use std::fmt;

use crate::{Pager, PageId, TransactionId, Result, Error};

/// Snapshot handle representing a consistent database view.
///
/// Snapshots are reference-counted and automatically decrement their
/// reference count when dropped. A snapshot can be cloned to create
/// additional references to the same database view.
///
/// # Lifecycle
///
/// 1. Created via `SnapshotRegistry::snapshot()` or related methods
/// 2. Used for read operations (returns root_page_id for B+tree traversal)
/// 3. Can be cloned to create additional references
/// 4. Automatically cleaned up when last reference is dropped
///
/// # Thread Safety
///
/// Snapshots can be safely cloned and shared across threads.
/// All operations are O(1).
#[derive(Clone)]
pub struct Snapshot {
    /// Inner snapshot data (reference counted for sharing)
    inner: Arc<SnapshotInner>,
}

/// Inner snapshot data.
///
/// Shared among all cloned references to the same snapshot.
struct SnapshotInner {
    /// Transaction ID for this snapshot
    txn_id: TransactionId,

    /// Root page ID for this snapshot's database view
    root_page_id: PageId,
    // Note: We don't store a direct registry reference to avoid circular dependencies.
    // The registry tracks ref counts externally.
}

impl Snapshot {
    /// Create a new snapshot.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID for this snapshot
    /// * `root_page_id` - Root page ID for this snapshot's view
    ///
    /// # Returns
    ///
    /// A new Snapshot handle
    pub(crate) fn new(txn_id: TransactionId, root_page_id: PageId) -> Self {
        Self {
            inner: Arc::new(SnapshotInner {
                txn_id,
                root_page_id,
            }),
        }
    }

    /// Get the transaction ID for this snapshot.
    ///
    /// # Returns
    ///
    /// The transaction ID that identifies this snapshot's point in time
    #[inline]
    pub fn txn_id(&self) -> TransactionId {
        self.inner.txn_id
    }

    /// Get the root page ID for this snapshot.
    ///
    /// # Returns
    ///
    /// The root page ID that should be used for B+tree traversal
    #[inline]
    pub fn root_page_id(&self) -> PageId {
        self.inner.root_page_id
    }

    /// Check if this is the genesis snapshot (txn_id 0).
    ///
    /// # Returns
    ///
    /// true if this is the initial snapshot, false otherwise
    #[inline]
    pub fn is_genesis(&self) -> bool {
        self.inner.txn_id == TransactionId::INITIAL
    }

    /// Check if this snapshot is newer than another.
    ///
    /// # Arguments
    ///
    /// * `other` - Another snapshot to compare with
    ///
    /// # Returns
    ///
    /// true if this snapshot has a higher transaction ID
    #[inline]
    pub fn is_newer_than(&self, other: &Snapshot) -> bool {
        self.inner.txn_id > other.inner.txn_id
    }

    /// Check if this snapshot is older than another.
    ///
    /// # Arguments
    ///
    /// * `other` - Another snapshot to compare with
    ///
    /// # Returns
    ///
    /// true if this snapshot has a lower transaction ID
    #[inline]
    pub fn is_older_than(&self, other: &Snapshot) -> bool {
        self.inner.txn_id < other.inner.txn_id
    }

    /// Get the reference count for this snapshot.
    ///
    /// Returns the number of active references to this snapshot.
    ///
    /// # Returns
    ///
    /// The current reference count
    #[inline]
    pub fn ref_count(&self) -> usize {
        Arc::strong_count(&self.inner)
    }

    /// Check if this is the only reference to the snapshot.
    ///
    /// # Returns
    ///
    /// true if this is the sole reference, false if shared
    #[inline]
    pub fn is_unique(&self) -> bool {
        Arc::strong_count(&self.inner) == 1
    }
}

impl fmt::Debug for Snapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Snapshot")
            .field("txn_id", &self.inner.txn_id)
            .field("root_page_id", &self.inner.root_page_id)
            .field("ref_count", &self.ref_count())
            .finish()
    }
}

impl fmt::Display for Snapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Snapshot(txn_id={}, root_page_id={}, refs={})",
            self.inner.txn_id.as_u64(),
            self.inner.root_page_id.as_u64(),
            self.ref_count()
        )
    }
}

impl PartialEq for Snapshot {
    fn eq(&self, other: &Self) -> bool {
        self.inner.txn_id == other.inner.txn_id
            && self.inner.root_page_id == other.inner.root_page_id
    }
}

impl Eq for Snapshot {}

/// Snapshot creation operations.
///
/// Extension trait for `SnapshotRegistry` to provide snapshot creation methods.
pub trait SnapshotOps {
    /// Create a snapshot at the latest transaction.
    ///
    /// Returns a snapshot representing the current state of the database.
    ///
    /// # Errors
    ///
    /// Returns an error if no snapshots are registered.
    fn snapshot(&self) -> Result<Snapshot>;

    /// Create a snapshot at a specific transaction ID.
    ///
    /// Returns a snapshot representing the database state after the
    /// specified transaction committed.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID for the snapshot
    ///
    /// # Errors
    ///
    /// Returns an error if the transaction ID doesn't exist.
    fn snapshot_at(&self, txn_id: TransactionId) -> Result<Snapshot>;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_snapshot() -> Snapshot {
        Snapshot::new(TransactionId::FIRST, PageId::new(10))
    }

    #[test]
    fn test_snapshot_creation() {
        let snapshot = create_test_snapshot();

        assert_eq!(snapshot.txn_id(), TransactionId::FIRST);
        assert_eq!(snapshot.root_page_id(), PageId::new(10));
    }

    #[test]
    fn test_snapshot_genesis() {
        let genesis = Snapshot::new(TransactionId::INITIAL, PageId::FIRST_DATA);
        assert!(genesis.is_genesis());

        let snapshot = create_test_snapshot();
        assert!(!snapshot.is_genesis());
    }

    #[test]
    fn test_snapshot_comparison() {
        let older = Snapshot::new(TransactionId::new(1), PageId::new(10));
        let newer = Snapshot::new(TransactionId::new(2), PageId::new(20));

        assert!(newer.is_newer_than(&older));
        assert!(older.is_older_than(&newer));
        assert!(!newer.is_older_than(&older));
        assert!(!older.is_newer_than(&newer));
    }

    #[test]
    fn test_snapshot_equality() {
        let snap1 = Snapshot::new(TransactionId::new(1), PageId::new(10));
        let snap2 = Snapshot::new(TransactionId::new(1), PageId::new(10));
        let snap3 = Snapshot::new(TransactionId::new(2), PageId::new(10));

        assert_eq!(snap1, snap2);
        assert_ne!(snap1, snap3);
    }

    #[test]
    fn test_snapshot_clone() {
        let snapshot = create_test_snapshot();

        // Initially unique
        assert!(snapshot.is_unique());
        assert_eq!(snapshot.ref_count(), 1);

        // Clone
        let cloned = snapshot.clone();

        // Now shared
        assert!(!snapshot.is_unique());
        assert!(!cloned.is_unique());
        assert_eq!(snapshot.ref_count(), 2);
        assert_eq!(cloned.ref_count(), 2);

        // Same data
        assert_eq!(snapshot.txn_id(), cloned.txn_id());
        assert_eq!(snapshot.root_page_id(), cloned.root_page_id());

        // Drop original
        drop(snapshot);

        // Now unique (only one reference left)
        assert!(cloned.is_unique());
        assert_eq!(cloned.ref_count(), 1);

        // Drop clone
        drop(cloned);

        // Now would be 0, but we can't check after drop
    }

    #[test]
    fn test_snapshot_debug() {
        let snapshot = create_test_snapshot();
        let debug_str = format!("{:?}", snapshot);
        assert!(debug_str.contains("Snapshot"));
        assert!(debug_str.contains("txn_id"));
        assert!(debug_str.contains("root_page_id"));
        assert!(debug_str.contains("ref_count"));
    }

    #[test]
    fn test_snapshot_display() {
        let snapshot = create_test_snapshot();
        let display_str = format!("{}", snapshot);
        assert!(display_str.contains("Snapshot"));
        assert!(display_str.contains("txn_id=1"));
        assert!(display_str.contains("root_page_id=10"));
        assert!(display_str.contains("refs=1"));
    }

    #[test]
    fn test_multiple_clones() {
        let snapshot = create_test_snapshot();
        assert_eq!(snapshot.ref_count(), 1);

        let clone1 = snapshot.clone();
        assert_eq!(snapshot.ref_count(), 2);

        let clone2 = clone1.clone();
        assert_eq!(snapshot.ref_count(), 3);

        let clone3 = snapshot.clone();
        assert_eq!(snapshot.ref_count(), 4);

        drop(clone1);
        assert_eq!(snapshot.ref_count(), 3);

        drop(clone2);
        assert_eq!(snapshot.ref_count(), 2);

        drop(clone3);
        assert_eq!(snapshot.ref_count(), 1);
    }

    #[test]
    fn test_snapshot_thread_safe() {
        use std::thread;
        use std::sync::Arc;

        let snapshot = Arc::new(create_test_snapshot());
        let mut handles = vec![];

        // Spawn threads that clone the snapshot
        for _ in 0..10 {
            let snap = Arc::clone(&snapshot);
            handles.push(thread::spawn(move || {
                // Each thread accesses the snapshot
                let txn_id = snap.txn_id();
                let root_id = snap.root_page_id();
                (txn_id, root_id)
            }));
        }

        // All threads should succeed
        for handle in handles {
            let (txn_id, root_id) = handle.join().unwrap();
            assert_eq!(txn_id, TransactionId::FIRST);
            assert_eq!(root_id, PageId::new(10));
        }

        // Original should still be valid
        assert_eq!(snapshot.txn_id(), TransactionId::FIRST);
    }

    #[test]
    fn test_snapshot_same_txn_id_different_root() {
        let snap1 = Snapshot::new(TransactionId::new(1), PageId::new(10));
        let snap2 = Snapshot::new(TransactionId::new(1), PageId::new(20));

        // Same txn_id but different root - not equal
        assert_ne!(snap1, snap2);
        assert_eq!(snap1.txn_id(), snap2.txn_id());
        assert_ne!(snap1.root_page_id(), snap2.root_page_id());
    }

    #[test]
    fn test_zero_txn_id() {
        let snapshot = Snapshot::new(TransactionId::INITIAL, PageId::FIRST_DATA);
        assert_eq!(snapshot.txn_id().as_u64(), 0);
        assert!(snapshot.is_genesis());
    }

    #[test]
    fn test_large_txn_id() {
        let large_id = TransactionId::new(u64::MAX);
        let snapshot = Snapshot::new(large_id, PageId::new(100));

        assert_eq!(snapshot.txn_id(), large_id);
        assert_eq!(snapshot.txn_id().as_u64(), u64::MAX);
    }

    #[test]
    fn test_large_page_id() {
        let large_page = PageId::new(u64::MAX);
        let snapshot = Snapshot::new(TransactionId::FIRST, large_page);

        assert_eq!(snapshot.root_page_id(), large_page);
        assert_eq!(snapshot.root_page_id().as_u64(), u64::MAX);
    }

    #[test]
    fn test_ref_count_accuracy() {
        let snapshot = create_test_snapshot();
        assert_eq!(snapshot.ref_count(), 1);

        {
            let _clone1 = snapshot.clone();
            assert_eq!(snapshot.ref_count(), 2);

            {
                let _clone2 = snapshot.clone();
                let _clone3 = snapshot.clone();
                assert_eq!(snapshot.ref_count(), 4);
            }

            assert_eq!(snapshot.ref_count(), 2);
        }

        assert_eq!(snapshot.ref_count(), 1);
    }

    #[test]
    fn test_comparison_edge_cases() {
        let snap0 = Snapshot::new(TransactionId::new(0), PageId::new(10));
        let snap1 = Snapshot::new(TransactionId::new(1), PageId::new(20));
        let snap_max = Snapshot::new(TransactionId::new(u64::MAX), PageId::new(30));

        assert!(snap1.is_newer_than(&snap0));
        assert!(snap0.is_older_than(&snap1));
        assert!(snap_max.is_newer_than(&snap1));
        assert!(snap1.is_older_than(&snap_max));

        // Same txn_id
        let snap1_copy = Snapshot::new(TransactionId::new(1), PageId::new(20));
        assert!(!snap1.is_newer_than(&snap1_copy));
        assert!(!snap1.is_older_than(&snap1_copy));
    }
}
