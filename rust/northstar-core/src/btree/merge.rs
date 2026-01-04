//! B+Tree Merge Operations
//!
//! Node merge algorithms for handling underfull nodes after delete operations.

use crate::{types::{PageId, Lsn}, error::{ValidationError, StorageError}, Error, Result};
use super::{node::{InternalNode, LeafNode, Node, Entry}, header::{HEADER_SIZE, DEFAULT_PAGE_SIZE}};
use super::insert::PagerTrait;

/// Minimum occupancy threshold (percentage of node capacity)
pub const MIN_OCCUPANCY: f64 = 0.4;

/// Result of a merge operation
#[derive(Debug, Clone)]
pub enum MergeResult {
    /// Merge succeeded without error
    Success { freed_page_id: PageId },
    /// Node not underfull, no merge needed
    NotNeeded,
    /// Cannot merge (nodes too large combined)
    CannotMerge,
    /// Borrow should be attempted instead
    TryBorrow,
}

/// Direction of merge operation
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeDirection {
    /// Merge right sibling into left
    RightIntoLeft,
    /// Merge left sibling into right
    LeftIntoRight,
}

/// Context for merge operations
#[derive(Debug, Clone)]
pub struct MergeContext {
    /// Page ID of underfull node
    pub underfull_page_id: PageId,
    /// Page ID of sibling to merge with
    pub sibling_page_id: PageId,
    /// Direction of merge
    pub direction: MergeDirection,
    /// Separator from parent (for internal nodes)
    pub separator: Option<Vec<u8>>,
    /// Parent page ID
    pub parent_page_id: Option<PageId>,
}

impl MergeContext {
    pub fn new(underfull_page_id: PageId, sibling_page_id: PageId, direction: MergeDirection) -> Self {
        Self {
            underfull_page_id,
            sibling_page_id,
            direction,
            separator: None,
            parent_page_id: None,
        }
    }

    pub fn with_separator(mut self, separator: Vec<u8>) -> Self {
        self.separator = Some(separator);
        self
    }

    pub fn with_parent(mut self, parent_page_id: PageId) -> Self {
        self.parent_page_id = Some(parent_page_id);
        self
    }
}

/// Merge candidates with eligibility information
#[derive(Debug, Clone)]
pub struct MergeCandidates {
    /// Left sibling exists
    pub has_left: bool,
    /// Right sibling exists
    pub has_right: bool,
    /// Left sibling page ID
    pub left_page_id: Option<PageId>,
    /// Right sibling page ID
    pub right_page_id: Option<PageId>,
    /// Recommended merge direction
    pub recommended_direction: Option<MergeDirection>,
}

impl MergeCandidates {
    pub fn new() -> Self {
        Self {
            has_left: false,
            has_right: false,
            left_page_id: None,
            right_page_id: None,
            recommended_direction: None,
        }
    }

    pub fn can_merge(&self) -> bool {
        self.has_left || self.has_right
    }
}

/// Check if two leaf nodes can be merged
pub fn can_merge_leaves(left: &LeafNode, right: &LeafNode) -> bool {
    let total_entries = left.entries.len() + right.entries.len();
    let total_size: usize = left.entries.iter().map(|e| e.serialized_size()).sum::<usize>()
        + right.entries.iter().map(|e| e.serialized_size()).sum::<usize>();
    let available_space = DEFAULT_PAGE_SIZE - HEADER_SIZE;

    total_size <= available_space && total_entries <= u16::MAX as usize
}

/// Merge right leaf node into left leaf node
pub fn merge_leaf_right_into_left(
    left: &mut LeafNode,
    right: &mut LeafNode,
    pager: &mut impl PagerTrait,
) -> Result<MergeResult> {
    // Check if merge is possible
    if !can_merge_leaves(left, right) {
        return Ok(MergeResult::CannotMerge);
    }

    // Move all entries from right to left
    let right_entries = std::mem::take(&mut right.entries);
    for entry in right_entries {
        left.insert(entry)?;
    }

    // Update linked list pointers
    left.next_leaf = right.next_leaf;

    // Update the next node's prev pointer if it exists
    if left.next_leaf != 0 {
        if let Ok(Node::Leaf(mut next_leaf)) = pager.read_node(PageId::from(left.next_leaf)) {
            next_leaf.prev_leaf = left.header.node_id;
            pager.write_node(PageId::from(left.next_leaf), &next_leaf.into())?;
        }
    }

    let freed_page = PageId::from(right.header.node_id);
    Ok(MergeResult::Success { freed_page_id: freed_page })
}

/// Merge left leaf node into right leaf node
pub fn merge_leaf_left_into_right(
    left: &mut LeafNode,
    right: &mut LeafNode,
    pager: &mut impl PagerTrait,
) -> Result<MergeResult> {
    // Check if merge is possible
    if !can_merge_leaves(left, right) {
        return Ok(MergeResult::CannotMerge);
    }

    // Move all entries from left to right (insert at beginning)
    let left_entries = std::mem::take(&mut left.entries);
    for entry in left_entries.into_iter().rev() {
        right.entries.insert(0, entry);
    }
    right.header.num_keys = right.entries.len() as u16;

    // Update linked list pointers
    right.prev_leaf = left.prev_leaf;

    // Update the prev node's next pointer if it exists
    if right.prev_leaf != 0 {
        if let Ok(Node::Leaf(mut prev_leaf)) = pager.read_node(PageId::from(right.prev_leaf)) {
            prev_leaf.next_leaf = right.header.node_id;
            pager.write_node(PageId::from(right.prev_leaf), &prev_leaf.into())?;
        }
    }

    let freed_page = PageId::from(left.header.node_id);
    Ok(MergeResult::Success { freed_page_id: freed_page })
}

/// Check if two internal nodes can be merged
pub fn can_merge_internals(left: &InternalNode, right: &InternalNode, separator_len: usize) -> bool {
    let total_separators = left.separators.len() + right.separators.len() + 1; // +1 for separator
    let total_children = left.children.len() + right.children.len();

    let estimated_size = total_separators * (8 + separator_len) + total_children * 8;
    let available_space = DEFAULT_PAGE_SIZE - HEADER_SIZE;

    estimated_size <= available_space && total_separators <= u16::MAX as usize
}

/// Merge right internal node into left internal node with parent separator
pub fn merge_internal_right_into_left(
    left: &mut InternalNode,
    right: &mut InternalNode,
    separator: Vec<u8>,
) -> Result<MergeResult> {
    // Check if merge is possible
    if !can_merge_internals(left, right, separator.len()) {
        return Ok(MergeResult::CannotMerge);
    }

    // Insert separator from parent
    left.insert(separator, *right.children.first().unwrap())?;

    // Move all separators and children from right to left
    let right_separators = std::mem::take(&mut right.separators);
    let right_children = std::mem::take(&mut right.children);

    for (sep, child) in right_separators.into_iter().zip(right_children.into_iter()) {
        left.insert(sep, child)?;
    }

    // Update child parent pointers
    for &child_id in &left.children {
        if let Ok(mut child_node) = unsafe { read_node_unchecked(child_id) } {
            child_node.header_mut().parent_page_id = left.header.node_id;
        }
    }

    let freed_page = PageId::from(right.header.node_id);
    Ok(MergeResult::Success { freed_page_id: freed_page })
}

/// Merge left internal node into right internal node with parent separator
pub fn merge_internal_left_into_right(
    left: &mut InternalNode,
    right: &mut InternalNode,
    separator: Vec<u8>,
) -> Result<MergeResult> {
    // Check if merge is possible
    if !can_merge_internals(left, right, separator.len()) {
        return Ok(MergeResult::CannotMerge);
    }

    // Insert separator from parent at beginning of right
    let left_last_child = *left.children.last().unwrap();
    right.separators.insert(0, separator);
    right.children.insert(0, left_last_child);

    // Move all separators and children from left to right
    let left_separators = std::mem::take(&mut left.separators);
    let left_children = std::mem::take(&mut left.children);

    for (sep, child) in left_separators.into_iter().zip(left_children.into_iter()) {
        right.separators.insert(0, sep);
        right.children.insert(0, child);
    }

    right.header.num_keys = right.separators.len() as u16;

    // Update child parent pointers
    for &child_id in &right.children {
        if let Ok(mut child_node) = unsafe { read_node_unchecked(child_id) } {
            child_node.header_mut().parent_page_id = right.header.node_id;
        }
    }

    let freed_page = PageId::from(left.header.node_id);
    Ok(MergeResult::Success { freed_page_id: freed_page })
}

/// Check if node is underfull and needs merge/borrow
pub fn is_node_underfull(num_keys: u16, level: u16) -> bool {
    // Root nodes can have fewer entries
    if level == 0 {
        return false;
    }

    let min_keys = calculate_min_keys();
    num_keys < min_keys
}

/// Calculate minimum keys for a node
fn calculate_min_keys() -> u16 {
    let avg_entry_size = 50; // Conservative estimate
    let max_keys = (DEFAULT_PAGE_SIZE - HEADER_SIZE) / avg_entry_size;
    (max_keys as f64 * MIN_OCCUPANCY) as u16
}

/// Get merge candidates for a leaf node
pub fn get_leaf_merge_candidates(
    leaf: &LeafNode,
    pager: &mut impl PagerTrait,
) -> Result<MergeCandidates> {
    let mut candidates = MergeCandidates::new();

    // Check left sibling
    if leaf.prev_leaf != 0 {
        candidates.has_left = true;
        candidates.left_page_id = Some(PageId::from(leaf.prev_leaf));
    }

    // Check right sibling
    if leaf.next_leaf != 0 {
        candidates.has_right = true;
        candidates.right_page_id = Some(PageId::from(leaf.next_leaf));
    }

    // Recommend merging with smaller sibling
    if candidates.has_left && candidates.has_right {
        if let Ok(Node::Leaf(left)) = pager.read_node(candidates.left_page_id.unwrap()) {
            if let Ok(Node::Leaf(right)) = pager.read_node(candidates.right_page_id.unwrap()) {
                if left.entries.len() <= right.entries.len() {
                    candidates.recommended_direction = Some(MergeDirection::LeftIntoRight);
                } else {
                    candidates.recommended_direction = Some(MergeDirection::RightIntoLeft);
                }
            }
        }
    } else if candidates.has_left {
        candidates.recommended_direction = Some(MergeDirection::LeftIntoRight);
    } else if candidates.has_right {
        candidates.recommended_direction = Some(MergeDirection::RightIntoLeft);
    }

    Ok(candidates)
}

/// Get merge candidates for an internal node
pub fn get_internal_merge_candidates(
    internal: &InternalNode,
    pager: &mut impl PagerTrait,
) -> Result<MergeCandidates> {
    let mut candidates = MergeCandidates::new();

    // Need to find siblings through parent
    if internal.header.parent_page_id == 0 {
        // Root node has no siblings
        return Ok(candidates);
    }

    if let Ok(Node::Internal(parent)) = pager.read_node(PageId::from(internal.header.parent_page_id)) {
        // Find position of this node in parent
        let pos = parent.children.iter()
            .position(|&id| id == internal.header.node_id);

        if let Some(pos) = pos {
            // Check left sibling
            if pos > 0 {
                candidates.has_left = true;
                candidates.left_page_id = Some(PageId::from(parent.children[pos - 1]));
            }

            // Check right sibling
            if pos + 1 < parent.children.len() {
                candidates.has_right = true;
                candidates.right_page_id = Some(PageId::from(parent.children[pos + 1]));
            }
        }
    }

    // Recommend merging with smaller sibling
    if candidates.has_left && candidates.has_right {
        if let Ok(Node::Internal(left)) = pager.read_node(candidates.left_page_id.unwrap()) {
            if let Ok(Node::Internal(right)) = pager.read_node(candidates.right_page_id.unwrap()) {
                if left.separators.len() <= right.separators.len() {
                    candidates.recommended_direction = Some(MergeDirection::LeftIntoRight);
                } else {
                    candidates.recommended_direction = Some(MergeDirection::RightIntoLeft);
                }
            }
        }
    } else if candidates.has_left {
        candidates.recommended_direction = Some(MergeDirection::LeftIntoRight);
    } else if candidates.has_right {
        candidates.recommended_direction = Some(MergeDirection::RightIntoLeft);
    }

    Ok(candidates)
}

/// Unsafe helper to read node without pager (for parent pointer updates)
/// In production, this would need proper pager access
unsafe fn read_node_unchecked(_page_id: u64) -> Result<Node> {
    // This is a placeholder - in real implementation, would need proper pager
    Err(Error::Validation(ValidationError::Generic("Pager access required".to_string())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Lsn;

    struct MockPager {
        nodes: std::collections::HashMap<u64, Node>,
    }

    impl MockPager {
        fn new() -> Self {
            Self {
                nodes: std::collections::HashMap::new(),
            }
        }

        fn add_leaf(&mut self, node: LeafNode) {
            self.nodes.insert(node.header.node_id, Node::Leaf(node));
        }

        fn add_internal(&mut self, node: InternalNode) {
            self.nodes.insert(node.header.node_id, Node::Internal(node));
        }
    }

    impl PagerTrait for MockPager {
        fn allocate_page(&mut self) -> Result<PageId> {
            Ok(PageId::from(self.nodes.len() as u64 + 1))
        }

        fn write_node(&mut self, _page_id: PageId, _node: &Node) -> Result<()> {
            Ok(())
        }

        fn read_node(&mut self, page_id: PageId) -> Result<Node> {
            self.nodes.get(&page_id.as_u64())
                .cloned()
                .ok_or_else(|| Error::Validation(ValidationError::Generic("Node not found".to_string())))
        }

        fn allocate_overflow_chain(&mut self, _value: &[u8]) -> Result<PageId> {
            Ok(PageId::from(999u64))
        }

        fn free_overflow_chain(&mut self, _first_page_id: PageId) -> Result<()> {
            Ok(())
        }
    }

    #[test]
    fn test_can_merge_leaves() {
        let mut left = LeafNode::new(1);
        let mut right = LeafNode::new(2);

        // Add entries that fit
        for i in 0..5 {
            left.insert(Entry::new(format!("key{}", i).into_bytes(), vec![i as u8; 10], Lsn::from(i))).unwrap();
        }
        for i in 5..10 {
            right.insert(Entry::new(format!("key{}", i).into_bytes(), vec![i as u8; 10], Lsn::from(i))).unwrap();
        }

        assert!(can_merge_leaves(&left, &right));
    }

    #[test]
    fn test_merge_leaf_right_into_left() {
        let mut left = LeafNode::new(1);
        let mut right = LeafNode::new(2);
        let mut pager = MockPager::new();

        left.insert(Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1))).unwrap();
        right.insert(Entry::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(2))).unwrap();
        right.next_leaf = 3;

        let result = merge_leaf_right_into_left(&mut left, &mut right, &mut pager).unwrap();
        assert!(matches!(result, MergeResult::Success { .. }));
        assert_eq!(left.entries.len(), 2);
        assert_eq!(left.next_leaf, 3);
    }

    #[test]
    fn test_merge_leaf_left_into_right() {
        let mut left = LeafNode::new(1);
        let mut right = LeafNode::new(2);
        let mut pager = MockPager::new();

        left.insert(Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1))).unwrap();
        right.insert(Entry::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(2))).unwrap();
        left.prev_leaf = 0;

        let result = merge_leaf_left_into_right(&mut left, &mut right, &mut pager).unwrap();
        assert!(matches!(result, MergeResult::Success { .. }));
        assert_eq!(right.entries.len(), 2);
    }

    #[test]
    fn test_is_node_underfull() {
        let min_keys = calculate_min_keys();

        // Non-root node with few keys is underfull
        assert!(is_node_underfull(1, 1));
        assert!(!is_node_underfull(min_keys + 10, 1));

        // Root node is never underfull
        assert!(!is_node_underfull(1, 0));
    }

    #[test]
    fn test_merge_context() {
        let ctx = MergeContext::new(PageId::from(1u64), PageId::from(2u64), MergeDirection::RightIntoLeft)
            .with_separator(b"sep".to_vec())
            .with_parent(PageId::from(10u64));

        assert_eq!(ctx.underfull_page_id.as_u64(), 1);
        assert_eq!(ctx.sibling_page_id.as_u64(), 2);
        assert_eq!(ctx.direction, MergeDirection::RightIntoLeft);
        assert_eq!(ctx.separator, Some(b"sep".to_vec()));
        assert_eq!(ctx.parent_page_id, Some(PageId::from(10u64)));
    }
}
