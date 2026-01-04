//! In-Memory B+Tree Implementation
//!
//! A simplified B+Tree using `BTreeMap` as the underlying storage.
//! This provides correct semantics without the complexity of disk persistence.

use crate::types::Lsn;
use std::collections::{BTreeMap, HashMap};
use std::vec::Vec;

/// Versioned value with MVCC support
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionedValue {
    /// Value bytes
    pub value: Vec<u8>,
    /// Log sequence number
    pub lsn: Lsn,
    /// Whether this is a tombstone (deleted)
    pub is_tombstone: bool,
}

impl VersionedValue {
    /// Create a new versioned value
    pub fn new(value: Vec<u8>, lsn: Lsn) -> Self {
        Self {
            value,
            lsn,
            is_tombstone: false,
        }
    }

    /// Create a tombstone (deleted value)
    pub fn tombstone(lsn: Lsn) -> Self {
        Self {
            value: Vec::new(),
            lsn,
            is_tombstone: true,
        }
    }

    /// Check if this version is visible at a given snapshot LSN
    pub fn is_visible(&self, snapshot_lsn: Lsn) -> bool {
        self.lsn <= snapshot_lsn
    }
}

/// Version chain for a single key
///
/// Stores all historical versions of a key for MVCC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionChain {
    versions: Vec<VersionedValue>,
}

impl VersionChain {
    /// Create a new empty version chain
    pub fn new() -> Self {
        Self {
            versions: Vec::new(),
        }
    }

    /// Add a new version to the chain
    ///
    /// Versions are stored in LSN order (oldest first).
    pub fn add_version(&mut self, version: VersionedValue) {
        // Find insertion point to maintain LSN order
        let pos = self
            .versions
            .binary_search_by(|v| v.lsn.cmp(&version.lsn))
            .unwrap_or_else(|pos| pos);

        self.versions.insert(pos, version);

        // Keep only recent versions (prune old ones)
        if self.versions.len() > 100 {
            self.versions.remove(0);
        }
    }

    /// Resolve value for a given snapshot LSN
    ///
    /// Returns the newest version visible at the snapshot LSN.
    pub fn resolve(&self, snapshot_lsn: Lsn) -> Option<&VersionedValue> {
        self.versions
            .iter()
            .rev()
            .find(|v| v.is_visible(snapshot_lsn))
    }

    /// Get the latest version
    pub fn latest(&self) -> Option<&VersionedValue> {
        self.versions.last()
    }

    /// Get all versions
    pub fn all_versions(&self) -> &[VersionedValue] {
        &self.versions
    }

    /// Check if the chain is empty
    pub fn is_empty(&self) -> bool {
        self.versions.is_empty()
    }

    /// Mark a key as deleted at the given LSN
    pub fn delete(&mut self, lsn: Lsn) {
        self.add_version(VersionedValue::tombstone(lsn));
    }

    /// Get the number of versions
    pub fn len(&self) -> usize {
        self.versions.len()
    }
}

impl Default for VersionChain {
    fn default() -> Self {
        Self::new()
    }
}

/// In-memory B+Tree
///
/// Uses `BTreeMap` for ordered storage with per-key version chains for MVCC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefTree {
    /// Key -> version chain mapping
    chains: BTreeMap<Vec<u8>, VersionChain>,
}

impl RefTree {
    /// Create a new empty reference tree
    pub fn new() -> Self {
        Self {
            chains: BTreeMap::new(),
        }
    }

    /// Get a value by key
    ///
    /// Returns the latest visible value, or `None` if:
    /// - The key does not exist
    /// - The latest version is a tombstone (deleted)
    pub fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.chains
            .get(key)
            .and_then(|chain| chain.latest())
            .filter(|v| !v.is_tombstone)
            .map(|v| v.value.clone())
    }

    /// Insert or update a key-value pair
    pub fn put(&mut self, key: Vec<u8>, value: Vec<u8>, lsn: Lsn) {
        let chain = self.chains.entry(key).or_default();
        chain.add_version(VersionedValue::new(value, lsn));
    }

    /// Delete a key
    ///
    /// Adds a tombstone marker at the given LSN.
    pub fn delete(&mut self, key: &[u8]) {
        if let Some(chain) = self.chains.get_mut(key) {
            // Use a high LSN for the tombstone (will be set during commit)
            chain.delete(Lsn::new(u64::MAX));
        }
    }

    /// Get all keys in sorted order
    pub fn keys(&self) -> Vec<Vec<u8>> {
        self.chains.keys().cloned().collect()
    }

    /// Get the number of keys in the tree
    pub fn len(&self) -> usize {
        self.chains.len()
    }

    /// Check if the tree is empty
    pub fn is_empty(&self) -> bool {
        self.chains.is_empty()
    }

    /// Range scan: get all keys in the range [start, end)
    pub fn range(&self, start: &[u8], end: &[u8]) -> Vec<(Vec<u8>, Vec<u8>)> {
        // Filter keys within range manually since BTreeMap range doesn't work with &[u8]
        self.iter()
            .into_iter()
            .filter(|(key, _)| key.as_slice() >= start && key.as_slice() < end)
            .collect()
    }

    /// Get all key-value pairs
    pub fn iter(&self) -> Vec<(Vec<u8>, Vec<u8>)> {
        self.chains
            .iter()
            .filter_map(|(key, chain)| {
                chain
                    .latest()
                    .filter(|v| !v.is_tombstone)
                    .map(|v| (key.clone(), v.value.clone()))
            })
            .collect()
    }

    /// Merge another tree into this one
    ///
    /// Used for snapshot restoration and state comparison.
    pub fn merge(&mut self, other: RefTree) {
        for (key, chain) in other.chains {
            let self_chain = self.chains.entry(key).or_default();
            for version in chain.all_versions() {
                self_chain.add_version(version.clone());
            }
        }
    }

    /// Compute a hash of the current state
    ///
    /// Used for equivalence checking and regression detection.
    pub fn compute_hash(&self) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        for (key, chain) in &self.chains {
            if let Some(latest) = chain.latest() {
                if !latest.is_tombstone {
                    key.hash(&mut hasher);
                    latest.value.hash(&mut hasher);
                    latest.lsn.as_u64().hash(&mut hasher);
                }
            }
        }
        hasher.finish()
    }
}

impl Default for RefTree {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_tree() {
        let tree = RefTree::new();
        assert!(tree.is_empty());
        assert_eq!(tree.len(), 0);
    }

    #[test]
    fn test_put_get() {
        let mut tree = RefTree::new();
        tree.put(b"key".to_vec(), b"value".to_vec(), Lsn::from(1));
        assert_eq!(tree.get(b"key"), Some(b"value".to_vec()));
    }

    #[test]
    fn test_update() {
        let mut tree = RefTree::new();
        tree.put(b"key".to_vec(), b"value1".to_vec(), Lsn::from(1));
        tree.put(b"key".to_vec(), b"value2".to_vec(), Lsn::from(2));
        assert_eq!(tree.get(b"key"), Some(b"value2".to_vec()));
    }

    #[test]
    fn test_delete() {
        let mut tree = RefTree::new();
        tree.put(b"key".to_vec(), b"value".to_vec(), Lsn::from(1));
        assert_eq!(tree.get(b"key"), Some(b"value".to_vec()));

        tree.delete(b"key");
        assert!(tree.get(b"key").is_none());
    }

    #[test]
    fn test_version_chain() {
        let mut chain = VersionChain::new();
        chain.add_version(VersionedValue::new(b"v1".to_vec(), Lsn::from(100)));
        chain.add_version(VersionedValue::new(b"v2".to_vec(), Lsn::from(200)));
        chain.add_version(VersionedValue::new(b"v3".to_vec(), Lsn::from(300)));

        // Latest version
        assert_eq!(chain.latest().unwrap().value, b"v3");

        // Resolve at different LSNs
        assert_eq!(chain.resolve(Lsn::from(150)).unwrap().value, b"v1");
        assert_eq!(chain.resolve(Lsn::from(250)).unwrap().value, b"v2");
        assert_eq!(chain.resolve(Lsn::from(350)).unwrap().value, b"v3");
    }

    #[test]
    fn test_tombstone() {
        let mut chain = VersionChain::new();
        chain.add_version(VersionedValue::new(b"value".to_vec(), Lsn::from(100)));
        chain.delete(Lsn::from(200));

        // Before delete
        assert!(chain.resolve(Lsn::from(150)).is_some());
        assert_eq!(chain.resolve(Lsn::from(150)).unwrap().value, b"value");

        // After delete
        assert!(chain.resolve(Lsn::from(250)).unwrap().is_tombstone);
    }

    #[test]
    fn test_range_scan() {
        let mut tree = RefTree::new();
        tree.put(b"a".to_vec(), b"1".to_vec(), Lsn::from(1));
        tree.put(b"b".to_vec(), b"2".to_vec(), Lsn::from(1));
        tree.put(b"c".to_vec(), b"3".to_vec(), Lsn::from(1));
        tree.put(b"d".to_vec(), b"4".to_vec(), Lsn::from(1));

        let range = tree.range(b"b", b"d");
        assert_eq!(range.len(), 2);
        assert_eq!(range[0], (b"b".to_vec(), b"2".to_vec()));
        assert_eq!(range[1], (b"c".to_vec(), b"3".to_vec()));
    }

    #[test]
    fn test_compute_hash() {
        let mut tree1 = RefTree::new();
        tree1.put(b"key".to_vec(), b"value".to_vec(), Lsn::from(1));

        let mut tree2 = RefTree::new();
        tree2.put(b"key".to_vec(), b"value".to_vec(), Lsn::from(1));

        assert_eq!(tree1.compute_hash(), tree2.compute_hash());

        tree2.put(b"key".to_vec(), b"different".to_vec(), Lsn::from(2));
        assert_ne!(tree1.compute_hash(), tree2.compute_hash());
    }

    #[test]
    fn test_merge() {
        let mut tree1 = RefTree::new();
        tree1.put(b"a".to_vec(), b"1".to_vec(), Lsn::from(1));

        let mut tree2 = RefTree::new();
        tree2.put(b"b".to_vec(), b"2".to_vec(), Lsn::from(1));

        tree1.merge(tree2);

        assert_eq!(tree1.get(b"a"), Some(b"1".to_vec()));
        assert_eq!(tree1.get(b"b"), Some(b"2".to_vec()));
    }

    #[test]
    fn test_iter() {
        let mut tree = RefTree::new();
        tree.put(b"c".to_vec(), b"3".to_vec(), Lsn::from(1));
        tree.put(b"a".to_vec(), b"1".to_vec(), Lsn::from(1));
        tree.put(b"b".to_vec(), b"2".to_vec(), Lsn::from(1));

        let items = tree.iter();
        assert_eq!(items.len(), 3);
        assert_eq!(items[0], (b"a".to_vec(), b"1".to_vec()));
        assert_eq!(items[1], (b"b".to_vec(), b"2".to_vec()));
        assert_eq!(items[2], (b"c".to_vec(), b"3".to_vec()));
    }
}
