//! Snapshot System
//!
//! Historical state tracking for time-travel queries and MVCC validation.

use crate::types::Lsn;
use super::tree::RefTree;
use std::collections::HashMap;

/// Snapshot of database state at a specific LSN
///
/// Contains a complete copy of the database state at the moment
/// the snapshot was created.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    /// Snapshot identifier (matches the LSN when created)
    pub id: Lsn,
    /// Complete database state at this LSN
    pub state: RefTree,
}

impl Snapshot {
    /// Create a new snapshot
    pub fn new(id: Lsn, state: RefTree) -> Self {
        Self { id, state }
    }

    /// Get a value by key from this snapshot
    pub fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.state.get(key)
    }

    /// Get all keys in this snapshot
    pub fn keys(&self) -> Vec<Vec<u8>> {
        self.state.keys()
    }

    /// Check if the snapshot is empty
    pub fn is_empty(&self) -> bool {
        self.state.is_empty()
    }

    /// Get the number of keys in the snapshot
    pub fn len(&self) -> usize {
        self.state.len()
    }
}

/// Snapshot registry for managing historical states
///
/// Maintains a collection of snapshots indexed by their LSN.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotRegistry {
    /// Map from LSN to snapshot state
    pub(in crate::refmodel) snapshots: HashMap<Lsn, RefTree>,
    /// Maximum number of snapshots to retain
    max_snapshots: usize,
}

impl SnapshotRegistry {
    /// Create a new empty snapshot registry
    pub fn new() -> Self {
        Self {
            snapshots: HashMap::new(),
            max_snapshots: 100,
        }
    }

    /// Set the maximum number of snapshots to retain
    pub fn with_max_snapshots(mut self, max: usize) -> Self {
        self.max_snapshots = max;
        self
    }

    /// Add a snapshot at the given LSN
    pub fn add_snapshot(&mut self, lsn: Lsn, state: RefTree) {
        self.snapshots.insert(lsn, state);

        // Prune old snapshots if we exceed the limit
        while self.snapshots.len() > self.max_snapshots {
            // Remove the oldest snapshot (smallest LSN)
            let oldest = *self.snapshots.keys().min().unwrap();
            self.snapshots.remove(&oldest);
        }
    }

    /// Get the snapshot state at a specific LSN
    ///
    /// Returns `None` if no snapshot exists at that LSN.
    pub fn get_state_at(&self, lsn: Lsn) -> Option<&RefTree> {
        self.snapshots.get(&lsn)
    }

    /// Remove a snapshot at the given LSN
    pub fn remove_snapshot(&mut self, lsn: Lsn) -> Option<RefTree> {
        self.snapshots.remove(&lsn)
    }

    /// Get the number of snapshots stored
    pub fn len(&self) -> usize {
        self.snapshots.len()
    }

    /// Check if the registry is empty
    pub fn is_empty(&self) -> bool {
        self.snapshots.is_empty()
    }

    /// Clear all snapshots
    pub fn clear(&mut self) {
        self.snapshots.clear();
    }

    /// Get all snapshot LSNs in sorted order
    pub fn snapshot_lsns(&mut self) -> Vec<Lsn> {
        let mut lsns: Vec<Lsn> = self.snapshots.keys().copied().collect();
        lsns.sort();
        lsns
    }

    /// Get the most recent snapshot (highest LSN)
    pub fn latest_snapshot(&self) -> Option<(Lsn, &RefTree)> {
        self.snapshots
            .iter()
            .max_by_key(|(lsn, _)| *lsn)
            .map(|(lsn, state)| (*lsn, state))
    }

    /// Get the oldest snapshot (lowest LSN)
    pub fn oldest_snapshot(&self) -> Option<(Lsn, &RefTree)> {
        self.snapshots
            .iter()
            .min_by_key(|(lsn, _)| *lsn)
            .map(|(lsn, state)| (*lsn, state))
    }

    /// Merge another registry into this one
    pub fn merge(&mut self, other: SnapshotRegistry) {
        for (lsn, state) in other.snapshots {
            self.snapshots.entry(lsn).or_insert(state);
        }

        // Prune if necessary
        while self.snapshots.len() > self.max_snapshots {
            if let Some(&oldest) = self.snapshots.keys().min() {
                self.snapshots.remove(&oldest);
            }
        }
    }
}

impl Default for SnapshotRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_registry() {
        let registry = SnapshotRegistry::new();
        assert!(registry.is_empty());
        assert_eq!(registry.len(), 0);
    }

    #[test]
    fn test_add_snapshot() {
        let mut registry = SnapshotRegistry::new();
        let tree = RefTree::new();

        registry.add_snapshot(Lsn::from(1), tree.clone());
        assert_eq!(registry.len(), 1);
        assert!(registry.get_state_at(Lsn::from(1)).is_some());
    }

    #[test]
    fn test_get_state_at() {
        let mut registry = SnapshotRegistry::new();

        let mut tree1 = RefTree::new();
        tree1.put(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1));
        registry.add_snapshot(Lsn::from(1), tree1);

        let mut tree2 = RefTree::new();
        tree2.put(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(2));
        registry.add_snapshot(Lsn::from(2), tree2);

        let state1 = registry.get_state_at(Lsn::from(1));
        let state2 = registry.get_state_at(Lsn::from(2));

        assert_eq!(state1.unwrap().get(b"key1"), Some(b"value1".to_vec()));
        assert_eq!(state2.unwrap().get(b"key2"), Some(b"value2".to_vec()));
    }

    #[test]
    fn test_remove_snapshot() {
        let mut registry = SnapshotRegistry::new();
        let tree = RefTree::new();

        registry.add_snapshot(Lsn::from(1), tree.clone());
        assert_eq!(registry.len(), 1);

        registry.remove_snapshot(Lsn::from(1));
        assert_eq!(registry.len(), 0);
        assert!(registry.get_state_at(Lsn::from(1)).is_none());
    }

    #[test]
    fn test_max_snapshots_limit() {
        let mut registry = SnapshotRegistry::new().with_max_snapshots(3);

        for i in 1..=5 {
            let tree = RefTree::new();
            registry.add_snapshot(Lsn::from(i), tree);
        }

        // Should only keep the 3 most recent snapshots
        assert_eq!(registry.len(), 3);
        assert!(registry.get_state_at(Lsn::from(1)).is_none());
        assert!(registry.get_state_at(Lsn::from(2)).is_none());
        assert!(registry.get_state_at(Lsn::from(3)).is_some());
        assert!(registry.get_state_at(Lsn::from(4)).is_some());
        assert!(registry.get_state_at(Lsn::from(5)).is_some());
    }

    #[test]
    fn test_snapshot_lsns() {
        let mut registry = SnapshotRegistry::new();

        for i in 1..=3 {
            let tree = RefTree::new();
            registry.add_snapshot(Lsn::from(i), tree);
        }

        let lsns = registry.snapshot_lsns();
        assert_eq!(lsns, vec![Lsn::from(1), Lsn::from(2), Lsn::from(3)]);
    }

    #[test]
    fn test_latest_oldest_snapshot() {
        let mut registry = SnapshotRegistry::new();

        let mut tree1 = RefTree::new();
        tree1.put(b"old".to_vec(), b"data".to_vec(), Lsn::from(1));
        registry.add_snapshot(Lsn::from(1), tree1);

        let mut tree2 = RefTree::new();
        tree2.put(b"new".to_vec(), b"data".to_vec(), Lsn::from(2));
        registry.add_snapshot(Lsn::from(2), tree2);

        let (oldest_lsn, oldest_state) = registry.oldest_snapshot().unwrap();
        assert_eq!(oldest_lsn, Lsn::from(1));
        assert_eq!(oldest_state.get(b"old"), Some(b"data".to_vec()));

        let (latest_lsn, latest_state) = registry.latest_snapshot().unwrap();
        assert_eq!(latest_lsn, Lsn::from(2));
        assert_eq!(latest_state.get(b"new"), Some(b"data".to_vec()));
    }

    #[test]
    fn test_merge() {
        let mut registry1 = SnapshotRegistry::new();
        let tree1 = RefTree::new();
        registry1.add_snapshot(Lsn::from(1), tree1);

        let mut registry2 = SnapshotRegistry::new();
        let tree2 = RefTree::new();
        registry2.add_snapshot(Lsn::from(2), tree2);

        registry1.merge(registry2);

        assert_eq!(registry1.len(), 2);
        assert!(registry1.get_state_at(Lsn::from(1)).is_some());
        assert!(registry1.get_state_at(Lsn::from(2)).is_some());
    }

    #[test]
    fn test_snapshot() {
        let mut tree = RefTree::new();
        tree.put(b"key".to_vec(), b"value".to_vec(), Lsn::from(1));

        let snapshot = Snapshot::new(Lsn::from(1), tree.clone());
        assert_eq!(snapshot.id, Lsn::from(1));
        assert_eq!(snapshot.get(b"key"), Some(b"value".to_vec()));
        assert_eq!(snapshot.len(), 1);
        assert!(!snapshot.is_empty());
    }

    #[test]
    fn test_clear() {
        let mut registry = SnapshotRegistry::new();
        let tree = RefTree::new();

        registry.add_snapshot(Lsn::from(1), tree.clone());
        registry.add_snapshot(Lsn::from(2), tree.clone());

        assert_eq!(registry.len(), 2);

        registry.clear();
        assert_eq!(registry.len(), 0);
        assert!(registry.is_empty());
    }
}
