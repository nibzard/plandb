//! Multi-Version Chain Management
//!
//! Handles MVCC version chains for concurrent access.

use crate::{types::Lsn, Result};
use std::collections::HashMap;

/// Version chain entry
#[derive(Debug, Clone)]
pub struct VersionedValue {
    /// Value bytes
    pub value: Vec<u8>,
    /// Log sequence number
    pub lsn: Lsn,
    /// Whether this is a deletion tombstone
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

    /// Check if this version is visible to a snapshot
    pub fn is_visible(&self, snapshot_lsn: Lsn) -> bool {
        self.lsn <= snapshot_lsn
    }
}

/// Version chain for a single key
#[derive(Debug, Clone)]
pub struct VersionChain {
    /// Versions from newest to oldest
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
    pub fn add_version(&mut self, version: VersionedValue) {
        // Add at front (newest first)
        self.versions.insert(0, version);

        // Limit chain length (keep only recent versions)
        if self.versions.len() > 10 {
            self.versions.truncate(10);
        }
    }

    /// Resolve value for a given snapshot LSN
    pub fn resolve(&self, snapshot_lsn: Lsn) -> Option<&VersionedValue> {
        for version in &self.versions {
            if version.is_visible(snapshot_lsn) {
                return Some(version);
            }
        }
        None
    }

    /// Get the latest version
    pub fn latest(&self) -> Option<&VersionedValue> {
        self.versions.first()
    }

    /// Get all versions
    pub fn all_versions(&self) -> &[VersionedValue] {
        &self.versions
    }

    /// Check if chain is empty
    pub fn is_empty(&self) -> bool {
        self.versions.is_empty()
    }

    /// Get the number of versions
    pub fn len(&self) -> usize {
        self.versions.len()
    }

    /// Remove versions older than a given LSN
    pub fn reclaim_old(&mut self, oldest_lsn: Lsn) -> usize {
        let original_len = self.versions.len();

        // Keep only versions newer than or equal to oldest_lsn
        self.versions.retain(|v| v.lsn >= oldest_lsn);

        original_len - self.versions.len()
    }
}

impl Default for VersionChain {
    fn default() -> Self {
        Self::new()
    }
}

/// Container for all version chains
#[derive(Debug, Clone, Default)]
pub struct VersionStore {
    /// Version chains keyed by key bytes
    chains: HashMap<Vec<u8>, VersionChain>,
}

impl VersionStore {
    /// Create a new version store
    pub fn new() -> Self {
        Self {
            chains: HashMap::new(),
        }
    }

    /// Add a version for a key
    pub fn add_version(&mut self, key: Vec<u8>, version: VersionedValue) {
        self.chains
            .entry(key)
            .or_insert_with(VersionChain::new)
            .add_version(version);
    }

    /// Resolve value for a key at a snapshot LSN
    pub fn resolve(&self, key: &[u8], snapshot_lsn: Lsn) -> Option<&VersionedValue> {
        self.chains.get(key)?.resolve(snapshot_lsn)
    }

    /// Get the latest version for a key
    pub fn latest(&self, key: &[u8]) -> Option<&VersionedValue> {
        self.chains.get(key)?.latest()
    }

    /// Check if a key exists (has any visible version)
    pub fn exists(&self, key: &[u8], snapshot_lsn: Lsn) -> bool {
        self.resolve(key, snapshot_lsn)
            .map(|v| !v.is_tombstone)
            .unwrap_or(false)
    }

    /// Mark a key as deleted (add tombstone)
    pub fn delete(&mut self, key: Vec<u8>, lsn: Lsn) {
        self.add_version(key, VersionedValue::tombstone(lsn));
    }

    /// Remove version chain for a key
    pub fn remove_chain(&mut self, key: &[u8]) -> bool {
        self.chains.remove(key).is_some()
    }

    /// Reclaim old versions for all keys
    pub fn reclaim_all(&mut self, oldest_lsn: Lsn) -> usize {
        let mut reclaimed = 0;
        for chain in self.chains.values_mut() {
            reclaimed += chain.reclaim_old(oldest_lsn);
        }
        reclaimed
    }

    /// Get the number of keys with version chains
    pub fn len(&self) -> usize {
        self.chains.len()
    }

    /// Check if store is empty
    pub fn is_empty(&self) -> bool {
        self.chains.is_empty()
    }

    /// Clear all version chains
    pub fn clear(&mut self) {
        self.chains.clear();
    }

    /// Get all keys with version chains
    pub fn keys(&self) -> impl Iterator<Item = &[u8]> {
        self.chains.keys().map(|k| k.as_slice())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_versioned_value() {
        let value = VersionedValue::new(b"data".to_vec(), Lsn::from(100));
        assert_eq!(value.value, b"data");
        assert_eq!(value.lsn, Lsn::from(100));
        assert!(!value.is_tombstone);

        let tombstone = VersionedValue::tombstone(Lsn::from(200));
        assert!(tombstone.is_tombstone);
        assert!(tombstone.value.is_empty());
    }

    #[test]
    fn test_versioned_value_visibility() {
        let value = VersionedValue::new(b"data".to_vec(), Lsn::from(100));

        // Visible to snapshots at or after LSN 100
        assert!(value.is_visible(Lsn::from(100)));
        assert!(value.is_visible(Lsn::from(150)));

        // Not visible to snapshots before LSN 100
        assert!(!value.is_visible(Lsn::from(50)));
        assert!(!value.is_visible(Lsn::from(99)));
    }

    #[test]
    fn test_version_chain() {
        let mut chain = VersionChain::new();

        // Add versions
        chain.add_version(VersionedValue::new(b"v1".to_vec(), Lsn::from(100)));
        chain.add_version(VersionedValue::new(b"v2".to_vec(), Lsn::from(200)));
        chain.add_version(VersionedValue::new(b"v3".to_vec(), Lsn::from(300)));

        assert_eq!(chain.len(), 3);

        // Resolve at different snapshots
        let snapshot_250 = Lsn::from(250);
        let resolved = chain.resolve(snapshot_250);
        assert!(resolved.is_some());
        assert_eq!(resolved.unwrap().value, b"v2"); // Newest visible at LSN 250

        let snapshot_50 = Lsn::from(50);
        let resolved = chain.resolve(snapshot_50);
        assert!(resolved.is_none()); // Nothing visible at LSN 50
    }

    #[test]
    fn test_version_chain_tombstone() {
        let mut chain = VersionChain::new();

        chain.add_version(VersionedValue::new(b"value".to_vec(), Lsn::from(100)));
        chain.add_version(VersionedValue::tombstone(Lsn::from(200)));

        // At LSN 150, value should be visible
        let resolved = chain.resolve(Lsn::from(150));
        assert!(resolved.is_some());
        assert!(!resolved.unwrap().is_tombstone);

        // At LSN 250, only tombstone is visible
        let resolved = chain.resolve(Lsn::from(250));
        assert!(resolved.is_some());
        assert!(resolved.unwrap().is_tombstone);
    }

    #[test]
    fn test_version_chain_reclaim() {
        let mut chain = VersionChain::new();

        for i in 1..=20 {
            chain.add_version(VersionedValue::new(
                format!("v{}", i).into_bytes(),
                Lsn::from(i as u64 * 10)
            ));
        }

        // Should be limited to 10 versions
        assert_eq!(chain.len(), 10);

        // Reclaim old versions (LSNs 110-200, reclaim LSNs < 150)
        let reclaimed = chain.reclaim_old(Lsn::from(150));
        assert!(reclaimed > 0);
        assert!(chain.len() < 10);
    }

    #[test]
    fn test_version_store() {
        let mut store = VersionStore::new();

        // Add versions for different keys
        store.add_version(
            b"key1".to_vec(),
            VersionedValue::new(b"value1".to_vec(), Lsn::from(100))
        );
        store.add_version(
            b"key2".to_vec(),
            VersionedValue::new(b"value2".to_vec(), Lsn::from(200))
        );

        assert_eq!(store.len(), 2);

        // Resolve keys
        let value = store.resolve(b"key1", Lsn::from(150));
        assert!(value.is_some());
        assert_eq!(value.unwrap().value, b"value1");

        // Non-existent key
        let value = store.resolve(b"key3", Lsn::from(250));
        assert!(value.is_none());
    }

    #[test]
    fn test_version_store_delete() {
        let mut store = VersionStore::new();

        store.add_version(
            b"key1".to_vec(),
            VersionedValue::new(b"value1".to_vec(), Lsn::from(100))
        );

        assert!(store.exists(b"key1", Lsn::from(150)));

        // Delete the key
        store.delete(b"key1".to_vec(), Lsn::from(200));

        // After delete, key should not exist
        assert!(!store.exists(b"key1", Lsn::from(250)));
    }

    #[test]
    fn test_version_store_reclaim() {
        let mut store = VersionStore::new();

        // Add multiple versions for multiple keys
        for key in 0..10 {
            for version in 0..10 {
                let key = format!("key{}", key);
                let value = format!("v{}", version);
                store.add_version(
                    key.into_bytes(),
                    VersionedValue::new(value.into_bytes(), Lsn::from(version as u64))
                );
            }
        }

        // Reclaim old versions
        let reclaimed = store.reclaim_all(Lsn::from(5));
        assert!(reclaimed > 0);

        // Old versions should be gone
        let resolved = store.resolve(b"key0", Lsn::from(3));
        assert!(resolved.is_none());
    }

    #[test]
    fn test_version_store_clear() {
        let mut store = VersionStore::new();

        store.add_version(
            b"key1".to_vec(),
            VersionedValue::new(b"value1".to_vec(), Lsn::from(100))
        );
        store.add_version(
            b"key2".to_vec(),
            VersionedValue::new(b"value2".to_vec(), Lsn::from(200))
        );

        assert_eq!(store.len(), 2);

        store.clear();
        assert_eq!(store.len(), 0);
        assert!(store.is_empty());
    }
}
