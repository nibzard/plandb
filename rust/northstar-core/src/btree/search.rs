//! B+Tree Search Operations
//!
//! Tree traversal and key lookup functionality.

use crate::{types::PageId, Result};
use super::node::{InternalNode, LeafNode, Node, Entry};

/// Result of a search operation
#[derive(Debug, Clone, PartialEq)]
pub enum SearchResult {
    /// Key found with associated value and LSN
    Found { value: Vec<u8>, lsn: u64 },
    /// Key not found
    NotFound,
    /// Need to traverse to child page
    Traverse { child_id: PageId },
    /// Need to follow sibling pointer
    FollowSibling { sibling_id: PageId },
}

impl SearchResult {
    /// Check if search found the key
    pub fn is_found(&self) -> bool {
        matches!(self, SearchResult::Found { .. })
    }

    /// Check if search should continue traversing
    pub fn should_traverse(&self) -> bool {
        matches!(self, SearchResult::Traverse { .. })
    }

    /// Get the child page ID if this is a traverse result
    pub fn child_id(&self) -> Option<PageId> {
        match self {
            SearchResult::Traverse { child_id } => Some(*child_id),
            SearchResult::FollowSibling { sibling_id } => Some(*sibling_id),
            _ => None,
        }
    }

    /// Get the value if found
    pub fn value(&self) -> Option<&[u8]> {
        match self {
            SearchResult::Found { value, .. } => Some(value),
            _ => None,
        }
    }
}

/// Search context for tracking path through tree
#[derive(Debug, Clone)]
pub struct SearchContext {
    /// Path from root to current node (page IDs)
    pub path: Vec<PageId>,
    /// Indices within each node
    pub indices: Vec<usize>,
}

impl SearchContext {
    /// Create a new search context
    pub fn new() -> Self {
        Self {
            path: Vec::new(),
            indices: Vec::new(),
        }
    }

    /// Push a node to the path
    pub fn push(&mut self, page_id: PageId, index: usize) {
        self.path.push(page_id);
        self.indices.push(index);
    }

    /// Pop the last node from the path
    pub fn pop(&mut self) -> Option<(PageId, usize)> {
        if self.path.is_empty() {
            None
        } else {
            let page_id = self.path.pop().unwrap();
            let index = self.indices.pop().unwrap();
            Some((page_id, index))
        }
    }

    /// Get the parent page ID
    pub fn parent(&self) -> Option<PageId> {
        if self.path.len() >= 2 {
            Some(self.path[self.path.len() - 2])
        } else {
            None
        }
    }

    /// Clear the context
    pub fn clear(&mut self) {
        self.path.clear();
        self.indices.clear();
    }
}

impl Default for SearchContext {
    fn default() -> Self {
        Self::new()
    }
}

/// Search within an internal node
pub fn search_internal(node: &InternalNode, key: &[u8]) -> SearchResult {
    let child_id = node.find_child(key);
    SearchResult::Traverse {
        child_id: PageId::from(child_id),
    }
}

/// Search within a leaf node
pub fn search_leaf(node: &LeafNode, key: &[u8], snapshot_lsn: u64) -> SearchResult {
    if let Some(entry) = node.find(key) {
        // For MVCC: only return if entry LSN <= snapshot LSN
        if entry.lsn.as_u64() <= snapshot_lsn {
            SearchResult::Found {
                value: entry.value.clone(),
                lsn: entry.lsn.as_u64(),
            }
        } else {
            SearchResult::NotFound
        }
    } else {
        SearchResult::NotFound
    }
}

/// Search for a key in a node
pub fn search_node(node: &Node, key: &[u8], snapshot_lsn: u64) -> SearchResult {
    match node {
        Node::Internal(internal) => search_internal(internal, key),
        Node::Leaf(leaf) => search_leaf(leaf, key, snapshot_lsn),
    }
}

/// Binary search for key position in sorted array
pub fn binary_search_keys(keys: &[Vec<u8>], key: &[u8]) -> usize {
    keys.binary_search_by(|probe| probe.as_slice().cmp(key))
        .unwrap_or_else(|pos| pos)
}

/// Binary search for insertion position in leaf entries
pub fn binary_search_entries(entries: &[Entry], key: &[u8]) -> usize {
    entries.binary_search_by(|probe| probe.key.as_slice().cmp(key))
        .unwrap_or_else(|pos| pos)
}

/// Find position to insert separator in internal node
pub fn find_separator_position(separators: &[Vec<u8>], separator: &[u8]) -> usize {
    separators.binary_search_by(|probe| probe.as_slice().cmp(separator))
        .unwrap_or_else(|pos| pos)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Lsn;

    #[test]
    fn test_search_context() {
        let mut ctx = SearchContext::new();

        ctx.push(PageId::from(1), 0);
        ctx.push(PageId::from(2), 1);
        ctx.push(PageId::from(3), 2);

        assert_eq!(ctx.path.len(), 3);
        assert_eq!(ctx.parent(), Some(PageId::from(2)));

        let (page_id, index) = ctx.pop().unwrap();
        assert_eq!(page_id, PageId::from(3));
        assert_eq!(index, 2);
        assert_eq!(ctx.parent(), Some(PageId::from(1)));
    }

    #[test]
    fn test_search_internal() {
        let mut node = InternalNode::new(1, 1);
        node.insert(b"key1".to_vec(), 10).unwrap();
        node.insert(b"key2".to_vec(), 11).unwrap();
        node.set_rightmost_child(12);

        let result = search_internal(&node, b"key0");
        assert!(matches!(result, SearchResult::Traverse { child_id } if child_id.as_u64() == 10));

        let result = search_internal(&node, b"key1");
        assert!(matches!(result, SearchResult::Traverse { child_id } if child_id.as_u64() == 11));

        let result = search_internal(&node, b"key3");
        assert!(matches!(result, SearchResult::Traverse { child_id } if child_id.as_u64() == 12));
    }

    #[test]
    fn test_search_leaf_found() {
        let mut node = LeafNode::new(1);
        let entry = Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100));
        node.insert(entry).unwrap();

        let result = search_leaf(&node, b"key1", 150);
        assert!(result.is_found());
        assert_eq!(result.value(), Some(&b"value1"[..]));
    }

    #[test]
    fn test_search_leaf_not_found() {
        let node = LeafNode::new(1);

        let result = search_leaf(&node, b"key1", 100);
        assert!(!result.is_found());
        assert!(matches!(result, SearchResult::NotFound));
    }

    #[test]
    fn test_search_leaf_snapshot_isolation() {
        let mut node = LeafNode::new(1);
        let entry = Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100));
        node.insert(entry).unwrap();

        // Snapshot before entry LSN should not see it
        let result = search_leaf(&node, b"key1", 50);
        assert!(!result.is_found());

        // Snapshot at or after entry LSN should see it
        let result = search_leaf(&node, b"key1", 100);
        assert!(result.is_found());

        let result = search_leaf(&node, b"key1", 150);
        assert!(result.is_found());
    }

    #[test]
    fn test_binary_search_keys() {
        let keys = vec![
            b"apple".to_vec(),
            b"banana".to_vec(),
            b"cherry".to_vec(),
        ];

        assert_eq!(binary_search_keys(&keys, b"apple"), 0);
        assert_eq!(binary_search_keys(&keys, b"banana"), 1);
        assert_eq!(binary_search_keys(&keys, b"cherry"), 2);

        // Not found - returns insertion position
        assert_eq!(binary_search_keys(&keys, b"apricot"), 1);
        assert_eq!(binary_search_keys(&keys, b"aa"), 0);
        assert_eq!(binary_search_keys(&keys, b"z"), 3);
    }

    #[test]
    fn test_search_result_helpers() {
        let found = SearchResult::Found {
            value: b"value".to_vec(),
            lsn: 100,
        };
        assert!(found.is_found());
        assert!(!found.should_traverse());
        assert_eq!(found.child_id(), None);
        assert_eq!(found.value(), Some(&b"value"[..]));

        let traverse = SearchResult::Traverse {
            child_id: PageId::from(42),
        };
        assert!(!traverse.is_found());
        assert!(traverse.should_traverse());
        assert_eq!(traverse.child_id(), Some(PageId::from(42)));
    }
}
