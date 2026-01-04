//! L2 Node Cache - caches decoded B+Tree nodes for faster traversal.
//!
//! NodeCache provides in-memory caching of decoded B+Tree nodes (InternalNode and LeafNode)
//! to accelerate tree traversal by avoiding repeated deserialization from page cache.
//!
//! ## MVCC Correctness
//!
//! Nodes are versioned by LSN to support MVCC snapshots. The same page_id may have
//! multiple cached versions at different LSNs, allowing concurrent transactions to
//! see consistent node states without blocking each other.
//!
//! ## Composite Key
//!
//! NodeKey = (page_id, lsn) - uniquely identifies a node version. Different transactions
//! with different snapshot LSNs will access different node versions even for the same
//! page.
//!
//! ## Dependency Management
//!
//! Node cache entries are derived from page cache. When a page is evicted from page cache,
//! all dependent node cache entries must be invalidated. This is tracked via an
//! invalidation channel.

use crate::btree::node::Node;
use crate::cache::types::{CacheConfig, CachePolicy, CacheSnapshot};
use crate::cache::{Cache, CacheError};
use crate::types::{Lsn, PageId};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;

/// Default node cache capacity (64MB for decoded nodes)
const DEFAULT_MAX_BYTES: usize = 64 * 1024 * 1024;

/// Composite key for node cache entries
///
/// Combines page_id and lsn to uniquely identify a node version.
/// This allows MVCC correctness - different transactions see different
/// node versions for the same page based on their snapshot LSN.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NodeKey {
    /// Page identifier
    pub page_id: PageId,
    /// Log sequence number (version)
    pub lsn: Lsn,
}

impl NodeKey {
    /// Create a new node key
    pub fn new(page_id: PageId, lsn: Lsn) -> Self {
        Self { page_id, lsn }
    }
}

/// Node cache with LSN-versioned entries and page dependency tracking
///
/// Caches decoded B+Tree nodes (InternalNode and LeafNode) to reduce deserialization
/// overhead during tree traversal. Uses composite key (page_id, lsn) for MVCC correctness.
pub struct NodeCache {
    /// Sharded cache by (page_id, lsn) key
    cache: Cache<NodeKey, Node>,
    /// Configuration
    config: CacheConfig,
    /// Mapping from page_id to all node versions (for invalidation)
    page_versions: Arc<Mutex<HashMap<PageId, std::collections::HashSet<NodeKey>>>>,
}

impl NodeCache {
    /// Create a new node cache with default configuration
    pub fn new() -> Self {
        let mut config = CacheConfig::default();
        config.max_size = DEFAULT_MAX_BYTES;
        config.max_entries = DEFAULT_MAX_BYTES / 4096; // Approx 4KB per node
        config.policy = CachePolicy::Arc; // Adaptive Replacement Cache

        Self::with_config(config)
    }

    /// Create a new node cache with custom configuration
    pub fn with_config(config: CacheConfig) -> Self {
        let cache = Cache::with_config(config.clone());
        let page_versions = Arc::new(Mutex::new(HashMap::new()));

        Self {
            cache,
            config,
            page_versions,
        }
    }

    /// Get a node from cache
    ///
    /// Returns the node if found at the exact (page_id, lsn) version.
    /// Increments access stats on cache hit.
    pub fn get(&self, page_id: PageId, lsn: Lsn) -> Option<Node> {
        let key = NodeKey::new(page_id, lsn);
        self.cache.get(&key)
    }

    /// Insert a decoded node into cache
    ///
    /// Calculates node size, triggers eviction if needed, and tracks
    /// the page dependency for invalidation.
    pub fn put(&self, page_id: PageId, lsn: Lsn, node: Node) -> Result<(), CacheError> {
        let key = NodeKey::new(page_id, lsn);

        // Calculate node size (estimate based on node type)
        let size = self.estimate_node_size(&node);

        // Insert into cache
        self.cache.put(key.clone(), node, size)?;

        // Track page version mapping
        let mut versions = self.page_versions.lock();
        versions.entry(page_id).or_default().insert(key);

        Ok(())
    }

    /// Invalidate all node versions for a page
    ///
    /// Called when a page is modified or evicted from page cache.
    /// Removes all cached versions of the page at any LSN.
    /// No write-back needed - nodes are derived read-only data.
    ///
    /// Returns the number of entries removed.
    pub fn invalidate(&self, page_id: PageId) -> usize {
        let mut versions = self.page_versions.lock();
        let removed = versions.remove(&page_id);

        if let Some(keys) = removed {
            let count = keys.len();
            // Remove each version from cache
            for key in keys {
                self.cache.invalidate(&key);
            }
            count
        } else {
            0
        }
    }

    /// Pin a node to prevent eviction during traversal
    ///
    /// Returns true if node was found and pinned.
    pub fn pin(&self, page_id: PageId, lsn: Lsn) -> bool {
        let key = NodeKey::new(page_id, lsn);
        self.cache.pin(&key)
    }

    /// Unpin a node
    ///
    /// Returns true if node was found and unpinned.
    pub fn unpin(&self, page_id: PageId, lsn: Lsn) -> bool {
        let key = NodeKey::new(page_id, lsn);
        self.cache.unpin(&key)
    }

    /// Clear all unpinned entries from cache
    ///
    /// Returns statistics about cleared entries.
    pub fn clear(&self) -> crate::cache::types::ClearResult {
        // Clear page version mapping
        self.page_versions.lock().clear();
        self.cache.clear()
    }

    /// Get cache statistics snapshot
    pub fn stats(&self) -> CacheSnapshot {
        self.cache.stats()
    }

    /// Estimate the in-memory size of a node
    ///
    /// This is an approximation for cache accounting. Actual size varies
    /// based on node structure (keys count, entries count, etc.).
    fn estimate_node_size(&self, node: &Node) -> usize {
        match node {
            Node::Internal(internal) => {
                // Base size + separators + children
                let base = std::mem::size_of::<Node>();
                let separators: usize = internal.separators.iter().map(|k| k.len()).sum();
                let children = internal.children.len() * 8;
                base + separators + children
            }
            Node::Leaf(leaf) => {
                // Base size + entries
                let base = std::mem::size_of::<Node>();
                let entries: usize = leaf.entries.iter()
                    .map(|e| e.key.len() + e.value.len())
                    .sum();
                base + entries
            }
        }
    }

    /// Get the number of cached versions for a page
    pub fn version_count(&self, page_id: PageId) -> usize {
        let versions = self.page_versions.lock();
        versions.get(&page_id).map(|s| s.len()).unwrap_or(0)
    }
}

impl Default for NodeCache {
    fn default() -> Self {
        Self::new()
    }
}

impl Clone for NodeCache {
    fn clone(&self) -> Self {
        // Note: This creates a new cache sharing the same page version tracking
        // In practice, NodeCache should be wrapped in Arc for shared access
        Self {
            cache: Cache::with_config(self.config.clone()),
            config: self.config.clone(),
            page_versions: Arc::clone(&self.page_versions),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::btree::node::{InternalNode, LeafNode, Entry};
    use crate::cache::types::CachePolicy;

    #[test]
    fn test_node_key_creation() {
        let page_id = PageId::new(42);
        let lsn = Lsn::new(100);
        let key = NodeKey::new(page_id, lsn);

        assert_eq!(key.page_id, page_id);
        assert_eq!(key.lsn, lsn);
    }

    #[test]
    fn test_node_key_equality() {
        let key1 = NodeKey::new(PageId::new(42), Lsn::new(100));
        let key2 = NodeKey::new(PageId::new(42), Lsn::new(100));
        let key3 = NodeKey::new(PageId::new(42), Lsn::new(101));
        let key4 = NodeKey::new(PageId::new(43), Lsn::new(100));

        assert_eq!(key1, key2);
        assert_ne!(key1, key3); // Different LSN
        assert_ne!(key1, key4); // Different page_id
    }

    #[test]
    fn test_node_key_hash() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let key1 = NodeKey::new(PageId::new(42), Lsn::new(100));
        let key2 = NodeKey::new(PageId::new(42), Lsn::new(100));
        let key3 = NodeKey::new(PageId::new(42), Lsn::new(101));

        let mut hasher1 = DefaultHasher::new();
        let mut hasher2 = DefaultHasher::new();
        let mut hasher3 = DefaultHasher::new();

        key1.hash(&mut hasher1);
        key2.hash(&mut hasher2);
        key3.hash(&mut hasher3);

        // Same keys should have same hash
        assert_eq!(hasher1.finish(), hasher2.finish());
        // Different keys should (likely) have different hashes
        assert_ne!(hasher1.finish(), hasher3.finish());
    }

    #[test]
    fn test_node_cache_new() {
        let cache = NodeCache::new();
        let stats = cache.stats();
        assert_eq!(stats.current_entries, 0);
    }

    #[test]
    fn test_node_cache_put_get() {
        let cache = NodeCache::new();
        let page_id = PageId::new(42);
        let lsn = Lsn::new(100);

        // Create a leaf node
        let mut leaf = LeafNode::new(page_id.as_u64());
        let entry = Entry::new(b"key1".to_vec(), b"value1".to_vec(), lsn);
        leaf.insert(entry).unwrap();
        let node: Node = leaf.into();

        // Insert and retrieve
        cache.put(page_id, lsn, node.clone()).unwrap();

        let retrieved = cache.get(page_id, lsn);
        assert!(retrieved.is_some());
        match retrieved.unwrap() {
            Node::Leaf(retrieved_leaf) => {
                assert_eq!(retrieved_leaf.entries.len(), 1);
                assert_eq!(retrieved_leaf.entries[0].key, b"key1");
            }
            _ => panic!("Expected leaf node"),
        }
    }

    #[test]
    fn test_node_cache_mvcc_versions() {
        let cache = NodeCache::new();
        let page_id = PageId::new(42);
        let lsn1 = Lsn::new(100);
        let lsn2 = Lsn::new(200);

        // Create two versions of the same page
        let mut leaf1 = LeafNode::new(page_id.as_u64());
        leaf1.insert(Entry::new(b"key1".to_vec(), b"value1".to_vec(), lsn1)).unwrap();

        let mut leaf2 = LeafNode::new(page_id.as_u64());
        leaf2.insert(Entry::new(b"key2".to_vec(), b"value2".to_vec(), lsn2)).unwrap();

        let node1: Node = leaf1.into();
        let node2: Node = leaf2.into();

        // Insert both versions
        cache.put(page_id, lsn1, node1).unwrap();
        cache.put(page_id, lsn2, node2).unwrap();

        // Both versions should be accessible
        assert!(cache.get(page_id, lsn1).is_some());
        assert!(cache.get(page_id, lsn2).is_some());

        // Version count should be 2
        assert_eq!(cache.version_count(page_id), 2);
    }

    #[test]
    fn test_node_cache_invalidate() {
        let cache = NodeCache::new();
        let page_id = PageId::new(42);
        let lsn1 = Lsn::new(100);
        let lsn2 = Lsn::new(200);

        // Insert multiple versions
        let mut leaf1 = LeafNode::new(page_id.as_u64());
        leaf1.insert(Entry::new(b"key1".to_vec(), b"value1".to_vec(), lsn1)).unwrap();

        let mut leaf2 = LeafNode::new(page_id.as_u64());
        leaf2.insert(Entry::new(b"key2".to_vec(), b"value2".to_vec(), lsn2)).unwrap();

        cache.put(page_id, lsn1, leaf1.into()).unwrap();
        cache.put(page_id, lsn2, leaf2.into()).unwrap();

        assert_eq!(cache.version_count(page_id), 2);

        // Invalidate all versions
        let removed = cache.invalidate(page_id);
        assert_eq!(removed, 2);

        // All versions should be gone
        assert!(cache.get(page_id, lsn1).is_none());
        assert!(cache.get(page_id, lsn2).is_none());
        assert_eq!(cache.version_count(page_id), 0);
    }

    #[test]
    fn test_node_cache_pin_unpin() {
        let cache = NodeCache::new();
        let page_id = PageId::new(42);
        let lsn = Lsn::new(100);

        let mut leaf = LeafNode::new(page_id.as_u64());
        leaf.insert(Entry::new(b"key1".to_vec(), b"value1".to_vec(), lsn)).unwrap();

        cache.put(page_id, lsn, leaf.into()).unwrap();

        // Pin the node
        assert!(cache.pin(page_id, lsn));

        // Unpin the node
        assert!(cache.unpin(page_id, lsn));

        // Pin non-existent node
        assert!(!cache.pin(PageId::new(999), Lsn::new(999)));
    }

    #[test]
    fn test_node_cache_clear() {
        let cache = NodeCache::new();

        // Add multiple nodes
        for i in 0..5 {
            let page_id = PageId::new(i);
            let lsn = Lsn::new(100 + i as u64);
            let mut leaf = LeafNode::new(page_id.as_u64());
            leaf.insert(Entry::new(format!("key{}", i).into_bytes(), vec![1], lsn)).unwrap();
            cache.put(page_id, lsn, leaf.into()).unwrap();
        }

        let stats = cache.stats();
        assert!(stats.current_entries > 0);

        // Clear all
        let result = cache.clear();
        assert!(result.entries_cleared > 0);
        assert_eq!(cache.stats().current_entries, 0);
    }

    #[test]
    fn test_node_cache_stats() {
        let cache = NodeCache::new();
        let page_id = PageId::new(42);
        let lsn = Lsn::new(100);

        let mut leaf = LeafNode::new(page_id.as_u64());
        leaf.insert(Entry::new(b"key1".to_vec(), b"value1".to_vec(), lsn)).unwrap();

        cache.put(page_id, lsn, leaf.into()).unwrap();

        // Hit - increments hits counter
        cache.get(page_id, lsn);

        // Note: Misses are not tracked in the current CacheShard implementation
        // get() returns early on miss without recording

        let stats = cache.stats();
        assert_eq!(stats.hits, 1);
        // Miss tracking is not implemented in CacheShard
        assert_eq!(stats.misses, 0);
        // Hit rate with 0 misses would be 1.0 (or undefined)
        assert!((stats.hit_rate - 1.0).abs() < 0.01);
    }

    #[test]
    fn test_node_cache_with_custom_config() {
        let mut config = CacheConfig::default();
        config.max_size = 1024 * 1024; // 1MB
        config.policy = CachePolicy::Lru;

        let cache = NodeCache::with_config(config);
        let stats = cache.stats();
        assert_eq!(stats.current_entries, 0);
    }

    #[test]
    fn test_node_cache_internal_node() {
        let cache = NodeCache::new();
        let page_id = PageId::new(42);
        let lsn = Lsn::new(100);

        // Create an internal node
        let mut internal = InternalNode::new(page_id.as_u64(), 1);
        internal.insert(b"sep1".to_vec(), 10).unwrap();
        internal.insert(b"sep2".to_vec(), 11).unwrap();
        internal.set_rightmost_child(12);

        let node: Node = internal.into();
        cache.put(page_id, lsn, node).unwrap();

        let retrieved = cache.get(page_id, lsn);
        assert!(retrieved.is_some());
        match retrieved.unwrap() {
            Node::Internal(retrieved_internal) => {
                assert_eq!(retrieved_internal.separators.len(), 2);
                assert_eq!(retrieved_internal.children.len(), 3);
            }
            _ => panic!("Expected internal node"),
        }
    }
}
