//! B+Tree Structure
//!
//! Main B+Tree implementation with top-level operations.

use crate::{pager::Pager, types::{PageId, Lsn}, error::ValidationError, Error, Result};
use super::{
    node::{Node, InternalNode, LeafNode, Entry},
    search::{SearchResult, SearchContext},
    insert::{InsertResult, insert_into_leaf, insert_into_internal},
    delete::{DeleteResult, delete_from_leaf},
    scan::{ScanIter, ScanState, ScanItem, ScanDirection},
    header::NodeType,
};

/// B+Tree index structure
pub struct BTree {
    /// Pager for node I/O
    pager: Pager,
    /// Root page ID
    root_page_id: PageId,
    /// Tree height (0 = root is leaf)
    height: u16,
    /// Number of leaf nodes
    leaf_count: usize,
    /// Number of internal nodes
    internal_count: usize,
}

impl BTree {
    /// Create a new B+Tree instance
    pub fn new(pager: Pager, root_page_id: PageId) -> Result<Self> {
        // Load root node to determine height and type
        let root_node = pager.read_page(root_page_id)?;

        let (height, is_leaf) = match root_node.header().get_node_type() {
            Some(NodeType::Leaf) | Some(NodeType::RootLeaf) => (0, true),
            Some(NodeType::Internal) | Some(NodeType::RootInternal) => {
                (root_node.header().level, false)
            },
            None => return Err(Error::Validation(ValidationError::Generic)("Invalid root node type".to_string())),
        };

        Ok(Self {
            pager,
            root_page_id,
            height,
            leaf_count: if is_leaf { 1 } else { 0 },
            internal_count: if !is_leaf { 1 } else { 0 },
        })
    }

    /// Create a new empty B+Tree
    pub fn create(mut pager: Pager) -> Result<Self> {
        // Allocate root page (leaf node)
        let root_page_id = pager.allocate_page()?;
        let root_node = LeafNode::new(root_page_id.as_u64());
        pager.write_page(root_page_id, &root_node)?;

        Ok(Self {
            pager,
            root_page_id,
            height: 0,
            leaf_count: 1,
            internal_count: 0,
        })
    }

    /// Get a value by key
    pub fn get(&self, key: &[u8], snapshot_lsn: Lsn) -> Result<Option<Vec<u8>>> {
        let mut current_page_id = self.root_page_id;
        let mut ctx = SearchContext::new();

        // Traverse from root to leaf
        loop {
            let node = self.pager.read_page(current_page_id)?;

            match node {
                Node::Internal(internal) => {
                    // Find child to traverse
                    let child_id = internal.find_child(key);
                    ctx.push(current_page_id, 0);
                    current_page_id = PageId::from(child_id);
                }
                Node::Leaf(leaf) => {
                    // Search for key in leaf
                    if let Some(entry) = leaf.find(key) {
                        if entry.lsn <= snapshot_lsn {
                            return Ok(Some(entry.value.clone()));
                        }
                    }
                    return Ok(None);
                }
            }
        }
    }

    /// Insert or update a key-value pair
    pub fn put(&mut self, key: Vec<u8>, value: Vec<u8>, lsn: Lsn) -> Result<()> {
        let entry = Entry::new(key.clone(), value, lsn);

        // If tree is empty (root is empty leaf), just insert
        let root_node = self.pager.read_page(self.root_page_id)?;
        if let Some(leaf) = root_node.as_leaf() {
            if leaf.entries.is_empty() {
                let mut leaf = leaf.clone();
                leaf.insert(entry)?;
                self.pager.write_page(self.root_page_id, &leaf)?;
                return Ok(());
            }
        }

        // Traverse to find insertion leaf
        let mut current_page_id = self.root_page_id;
        let mut path: Vec<(PageId, Node)> = Vec::new();

        loop {
            let node = self.pager.read_page(current_page_id)?;
            path.push((current_page_id, node.clone()));

            match node {
                Node::Internal(internal) => {
                    let child_id = internal.find_child(&key);
                    current_page_id = PageId::from(child_id);
                }
                Node::Leaf(leaf) => {
                    let mut leaf = leaf.clone();

                    // Try to insert
                    match insert_into_leaf(&mut leaf, entry, &mut self.pager)? {
                        InsertResult::Success => {
                            self.pager.write_page(current_page_id, &leaf)?;
                            return Ok(());
                        }
                        InsertResult::Split { new_page_id, separator } => {
                            // Propagate split up the tree
                            self.propagate_split(path, separator, new_page_id)?;
                            return Ok(());
                        }
                    }
                }
            }
        }
    }

    /// Delete a key-value pair
    pub fn delete(&mut self, key: &[u8], lsn: Lsn) -> Result<()> {
        // Traverse to find deletion leaf
        let mut current_page_id = self.root_page_id;
        let mut path: Vec<(PageId, Node)> = Vec::new();

        loop {
            let node = self.pager.read_page(current_page_id)?;
            path.push((current_page_id, node.clone()));

            match node {
                Node::Internal(internal) => {
                    let child_id = internal.find_child(key);
                    current_page_id = PageId::from(child_id);
                }
                Node::Leaf(leaf) => {
                    let mut leaf = leaf.clone();

                    // Try to delete
                    match delete_from_leaf(&mut leaf, key)? {
                        DeleteResult::Success => {
                            self.pager.write_page(current_page_id, &leaf)?;
                            return Ok(());
                        }
                        DeleteResult::Underfull { .. } | DeleteResult::Merged { .. } => {
                            // Handle underflow/merge
                            self.pager.write_page(current_page_id, &leaf)?;
                            // TODO: Implement merge/borrow logic
                            return Ok(());
                        }
                    }
                }
            }
        }
    }

    /// Create a range scan iterator
    pub fn scan(
        &self,
        start: Option<&[u8]>,
        end: Option<&[u8]>,
        snapshot_lsn: Lsn,
    ) -> Result<ScanIter> {
        // Find starting leaf
        let start_page = if let Some(start_key) = start {
            self.find_leaf_for_key(start_key)?
        } else {
            self.find_leftmost_leaf()?
        };

        // Collect all items in range (simplified - in production would stream)
        let mut items = Vec::new();
        let mut current_page_id = start_page;

        while current_page_id.as_u64() != 0 {
            let node = self.pager.read_page(current_page_id)?;

            if let Some(leaf) = node.as_leaf() {
                for entry in &leaf.entries {
                    // Check if entry is within range
                    if let Some(start_key) = start {
                        if entry.key < start_key {
                            continue;
                        }
                    }

                    if let Some(end_key) = end {
                        if entry.key >= end_key {
                            current_page_id = PageId::from(0); // Stop
                            break;
                        }
                    }

                    if entry.lsn <= snapshot_lsn {
                        items.push(ScanItem::new(
                            entry.key.clone(),
                            entry.value.clone(),
                            entry.lsn,
                        ));
                    }
                }

                current_page_id = PageId::from(leaf.next_leaf);
            } else {
                break;
            }
        }

        Ok(ScanIter::forward(items, end.map(|k| k.to_vec()), snapshot_lsn))
    }

    /// Get tree statistics
    pub fn statistics(&self) -> TreeStats {
        TreeStats {
            height: self.height,
            leaf_count: self.leaf_count,
            internal_count: self.internal_count,
            root_page_id: self.root_page_id,
        }
    }

    /// Verify tree invariants
    pub fn verify(&self) -> Result<()> {
        // Verify root exists
        let root = self.pager.read_page(self.root_page_id)?;

        // Verify root is valid
        root.validate()?;

        // TODO: Add more thorough verification
        Ok(())
    }

    /// Propagate split up the tree
    fn propagate_split(
        &mut self,
        mut path: Vec<(PageId, Node)>,
        separator: Vec<u8>,
        new_child_id: PageId,
    ) -> Result<()> {
        while let Some((page_id, node)) = path.pop() {
            match node {
                Node::Internal(mut internal) => {
                    // Try to insert separator
                    match insert_into_internal(
                        &mut internal,
                        separator.clone(),
                        new_child_id.as_u64(),
                        &mut self.pager,
                    )? {
                        InsertResult::Success => {
                            self.pager.write_page(page_id, &internal)?;
                            return Ok(());
                        }
                        InsertResult::Split { new_page_id, separator: new_sep } => {
                            self.pager.write_page(page_id, &internal)?;
                            separator = new_sep;
                            new_child_id = new_page_id;
                        }
                    }
                }
                Node::Leaf(_) => {
                    // Root split - grow tree height
                    return self.grow_tree(separator, new_child_id);
                }
            }
        }

        Ok(())
    }

    /// Grow tree by creating new root
    fn grow_tree(&mut self, separator: Vec<u8>, right_child: PageId) -> Result<()> {
        // Allocate new root page
        let new_root_id = self.pager.allocate_page()?;
        let mut new_root = InternalNode::new(new_root_id.as_u64(), self.height + 1);

        // Insert old root and new node as children
        new_root.children.push(self.root_page_id.as_u64());
        new_root.separators.push(separator);
        new_root.children.push(right_child.as_u64());
        new_root.header.num_keys = 1;

        // Update old root to not be root
        let old_root = self.pager.read_page(self.root_page_id)?;
        let mut old_root = old_root.clone();
        old_root.header_mut().is_root = 0;
        old_root.header_mut().parent_page_id = new_root_id.as_u64();
        self.pager.write_page(self.root_page_id, old_root.as_ref().as_leaf().unwrap())?;

        // Write new root
        self.pager.write_page(new_root_id, &new_root)?;

        // Update tree state
        self.root_page_id = new_root_id;
        self.height += 1;
        self.internal_count += 1;

        Ok(())
    }

    /// Find leaf node containing a key
    fn find_leaf_for_key(&self, key: &[u8]) -> Result<PageId> {
        let mut current_page_id = self.root_page_id;

        loop {
            let node = self.pager.read_page(current_page_id)?;

            match node {
                Node::Internal(internal) => {
                    let child_id = internal.find_child(key);
                    current_page_id = PageId::from(child_id);
                }
                Node::Leaf(_) => {
                    return Ok(current_page_id);
                }
            }
        }
    }

    /// Find leftmost leaf node
    fn find_leftmost_leaf(&self) -> Result<PageId> {
        let mut current_page_id = self.root_page_id;

        loop {
            let node = self.pager.read_page(current_page_id)?;

            match node {
                Node::Internal(internal) => {
                    let leftmost = *internal.children.first()
                        .ok_or_else(|| Error::Validation(ValidationError::Generic)("Internal node has no children".to_string()))?;
                    current_page_id = PageId::from(leftmost);
                }
                Node::Leaf(_) => {
                    return Ok(current_page_id);
                }
            }
        }
    }
}

/// Tree statistics
#[derive(Debug, Clone, PartialEq)]
pub struct TreeStats {
    /// Tree height (0 = single level)
    pub height: u16,
    /// Number of leaf nodes
    pub leaf_count: usize,
    /// Number of internal nodes
    pub internal_count: usize,
    /// Root page ID
    pub root_page_id: PageId,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pager::Pager;

    // Note: These are simplified tests. In a real scenario, we'd need
    // to set up a proper Pager implementation with temporary storage.

    #[test]
    fn test_tree_stats() {
        let stats = TreeStats {
            height: 2,
            leaf_count: 10,
            internal_count: 3,
            root_page_id: PageId::from(1),
        };

        assert_eq!(stats.height, 2);
        assert_eq!(stats.leaf_count, 10);
    }
}
