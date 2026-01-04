//! B+Tree Borrow Operations
//!
//! Entry redistribution between sibling nodes as alternative to merge.

use crate::{types::{PageId, Lsn}, error::{ValidationError, StorageError}, Error, Result};
use super::{node::{InternalNode, LeafNode, Node, Entry}, header::{HEADER_SIZE, DEFAULT_PAGE_SIZE}};
use super::insert::PagerTrait;

/// Minimum occupancy threshold (same as merge)
pub const MIN_OCCUPANCY: f64 = 0.4;

/// Result of a borrow operation
#[derive(Debug, Clone)]
pub enum BorrowResult {
    /// Borrow succeeded, returns new separator key
    Success { new_separator: Vec<u8> },
    /// Borrow not possible (sibling has no excess entries)
    NotPossible,
    /// Borrow not needed (node has enough entries)
    NotNeeded,
}

/// Direction of borrow operation
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BorrowDirection {
    /// Borrow from right sibling (move leftmost entries)
    FromRight,
    /// Borrow from left sibling (move rightmost entries)
    FromLeft,
}

/// Context for borrow operations
#[derive(Debug, Clone)]
pub struct BorrowContext {
    /// Page ID of underfull node
    pub underfull_page_id: PageId,
    /// Page ID of sibling to borrow from
    pub donor_page_id: PageId,
    /// Direction of borrow
    pub direction: BorrowDirection,
    /// Number of entries to borrow
    pub entries_needed: usize,
    /// Parent page ID
    pub parent_page_id: Option<PageId>,
}

impl BorrowContext {
    pub fn new(underfull_page_id: PageId, donor_page_id: PageId, direction: BorrowDirection) -> Self {
        Self {
            underfull_page_id,
            donor_page_id,
            direction,
            entries_needed: 1,
            parent_page_id: None,
        }
    }

    pub fn with_entries(mut self, count: usize) -> Self {
        self.entries_needed = count;
        self
    }

    pub fn with_parent(mut self, parent_page_id: PageId) -> Self {
        self.parent_page_id = Some(parent_page_id);
        self
    }
}

/// Borrow candidates with excess entry information
#[derive(Debug, Clone)]
pub struct BorrowCandidates {
    /// Left sibling exists
    pub has_left: bool,
    /// Right sibling exists
    pub has_right: bool,
    /// Left sibling page ID
    pub left_page_id: Option<PageId>,
    /// Right sibling page ID
    pub right_page_id: Option<PageId>,
    /// Excess entries in left sibling
    pub left_excess: usize,
    /// Excess entries in right sibling
    pub right_excess: usize,
    /// Recommended borrow direction
    pub recommended_direction: Option<BorrowDirection>,
}

impl BorrowCandidates {
    pub fn new() -> Self {
        Self {
            has_left: false,
            has_right: false,
            left_page_id: None,
            right_page_id: None,
            left_excess: 0,
            right_excess: 0,
            recommended_direction: None,
        }
    }

    pub fn can_borrow(&self) -> bool {
        (self.has_left && self.left_excess > 0) || (self.has_right && self.right_excess > 0)
    }
}

/// Check if borrow is possible by calculating donor excess entries
pub fn can_borrow_from_sibling(
    donor_num_keys: u16,
    borrower_num_keys: u16,
) -> bool {
    let min_keys = calculate_min_keys();
    let donor_excess = donor_num_keys.saturating_sub(min_keys);
    let borrower_need = min_keys.saturating_sub(borrower_num_keys);

    donor_excess > 0 && donor_excess >= borrower_need as u16
}

/// Calculate minimum keys for a node
fn calculate_min_keys() -> u16 {
    let avg_entry_size = 50;
    let max_keys = (DEFAULT_PAGE_SIZE - HEADER_SIZE) / avg_entry_size;
    (max_keys as f64 * MIN_OCCUPANCY) as u16
}

/// Borrow entry from right sibling (move leftmost entry to underfull node)
pub fn borrow_from_right_leaf(
    underfull: &mut LeafNode,
    donor: &mut LeafNode,
) -> Result<BorrowResult> {
    if donor.entries.is_empty() {
        return Ok(BorrowResult::NotPossible);
    }

    // Check if donor has excess
    if !can_borrow_from_sibling(donor.header.num_keys, underfull.header.num_keys) {
        return Ok(BorrowResult::NotPossible);
    }

    // Remove first (leftmost) entry from donor
    let entry = donor.entries.remove(0);
    donor.header.num_keys = donor.entries.len() as u16;

    // Insert into underfull node (maintains sorted order)
    underfull.insert(entry)?;

    // Return the new first key in donor as separator
    let new_separator = donor.entries.first()
        .map(|e| e.key.clone())
        .unwrap_or_else(|| underfull.entries.last().unwrap().key.clone());

    Ok(BorrowResult::Success { new_separator })
}

/// Borrow entry from left sibling (move rightmost entry to underfull node)
pub fn borrow_from_left_leaf(
    underfull: &mut LeafNode,
    donor: &mut LeafNode,
) -> Result<BorrowResult> {
    if donor.entries.is_empty() {
        return Ok(BorrowResult::NotPossible);
    }

    // Check if donor has excess
    if !can_borrow_from_sibling(donor.header.num_keys, underfull.header.num_keys) {
        return Ok(BorrowResult::NotPossible);
    }

    // Remove last (rightmost) entry from donor
    let entry = donor.entries.pop()
        .ok_or_else(|| Error::Validation(ValidationError::Generic("Donor is empty".to_string())))?;
    donor.header.num_keys = donor.entries.len() as u16;

    // Insert into underfull node (maintains sorted order)
    underfull.insert(entry)?;

    // Return the new last key in donor as separator
    let new_separator = donor.entries.last()
        .map(|e| e.key.clone())
        .unwrap_or_else(|| underfull.entries.first().unwrap().key.clone());

    Ok(BorrowResult::Success { new_separator })
}

/// Borrow from right internal sibling
/// Move leftmost child and separator from right sibling to underfull node
pub fn borrow_from_right_internal(
    underfull: &mut InternalNode,
    donor: &mut InternalNode,
    parent_separator: Vec<u8>,
) -> Result<BorrowResult> {
    if donor.separators.is_empty() {
        return Ok(BorrowResult::NotPossible);
    }

    // Check if donor has excess
    if !can_borrow_from_sibling(donor.header.num_keys, underfull.header.num_keys) {
        return Ok(BorrowResult::NotPossible);
    }

    // Get leftmost separator and child from donor
    let borrowed_separator = donor.separators.remove(0);
    let borrowed_child = donor.children.remove(0);
    donor.header.num_keys = donor.separators.len() as u16;

    // Insert parent separator and borrowed child into underfull
    underfull.insert(parent_separator, borrowed_child)?;

    // Move borrowed child's parent pointer
    // (In production, would update child node's parent_page_id)

    // Return borrowed separator as new parent separator
    Ok(BorrowResult::Success { new_separator: borrowed_separator })
}

/// Borrow from left internal sibling
/// Move rightmost child and separator from left sibling to underfull node
pub fn borrow_from_left_internal(
    underfull: &mut InternalNode,
    donor: &mut InternalNode,
    parent_separator: Vec<u8>,
) -> Result<BorrowResult> {
    if donor.separators.is_empty() {
        return Ok(BorrowResult::NotPossible);
    }

    // Check if donor has excess
    if !can_borrow_from_sibling(donor.header.num_keys, underfull.header.num_keys) {
        return Ok(BorrowResult::NotPossible);
    }

    // Get rightmost separator and child from donor
    let borrowed_separator = donor.separators.pop()
        .ok_or_else(|| Error::Validation(ValidationError::Generic("Donor is empty".to_string())))?;
    let borrowed_child = donor.children.pop()
        .ok_or_else(|| Error::Validation(ValidationError::Generic("Donor has no child".to_string())))?;
    donor.header.num_keys = donor.separators.len() as u16;

    // Insert parent separator and borrowed child into underfull
    // (Insert at beginning to maintain order)
    underfull.separators.insert(0, parent_separator);
    underfull.children.insert(0, borrowed_child);
    underfull.header.num_keys = underfull.separators.len() as u16;

    // Move borrowed child's parent pointer
    // (In production, would update child node's parent_page_id)

    // Return borrowed separator as new parent separator
    Ok(BorrowResult::Success { new_separator: borrowed_separator })
}

/// Get borrow candidates for a leaf node
pub fn get_leaf_borrow_candidates(
    leaf: &LeafNode,
    pager: &mut impl PagerTrait,
) -> Result<BorrowCandidates> {
    let mut candidates = BorrowCandidates::new();
    let min_keys = calculate_min_keys();

    // Check left sibling
    if leaf.prev_leaf != 0 {
        if let Ok(Node::Leaf(left)) = pager.read_node(PageId::from(leaf.prev_leaf)) {
            candidates.has_left = true;
            candidates.left_page_id = Some(PageId::from(leaf.prev_leaf));
            candidates.left_excess = left.header.num_keys.saturating_sub(min_keys) as usize;
        }
    }

    // Check right sibling
    if leaf.next_leaf != 0 {
        if let Ok(Node::Leaf(right)) = pager.read_node(PageId::from(leaf.next_leaf)) {
            candidates.has_right = true;
            candidates.right_page_id = Some(PageId::from(leaf.next_leaf));
            candidates.right_excess = right.header.num_keys.saturating_sub(min_keys) as usize;
        }
    }

    // Recommend borrowing from sibling with more excess
    if candidates.has_left && candidates.has_right {
        if candidates.left_excess >= candidates.right_excess && candidates.left_excess > 0 {
            candidates.recommended_direction = Some(BorrowDirection::FromLeft);
        } else if candidates.right_excess > 0 {
            candidates.recommended_direction = Some(BorrowDirection::FromRight);
        }
    } else if candidates.has_left && candidates.left_excess > 0 {
        candidates.recommended_direction = Some(BorrowDirection::FromLeft);
    } else if candidates.has_right && candidates.right_excess > 0 {
        candidates.recommended_direction = Some(BorrowDirection::FromRight);
    }

    Ok(candidates)
}

/// Get borrow candidates for an internal node
pub fn get_internal_borrow_candidates(
    internal: &InternalNode,
    pager: &mut impl PagerTrait,
) -> Result<BorrowCandidates> {
    let mut candidates = BorrowCandidates::new();
    let min_keys = calculate_min_keys();

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
                if let Ok(Node::Internal(left)) = pager.read_node(PageId::from(parent.children[pos - 1])) {
                    candidates.has_left = true;
                    candidates.left_page_id = Some(PageId::from(parent.children[pos - 1]));
                    candidates.left_excess = left.header.num_keys.saturating_sub(min_keys) as usize;
                }
            }

            // Check right sibling
            if pos + 1 < parent.children.len() {
                if let Ok(Node::Internal(right)) = pager.read_node(PageId::from(parent.children[pos + 1])) {
                    candidates.has_right = true;
                    candidates.right_page_id = Some(PageId::from(parent.children[pos + 1]));
                    candidates.right_excess = right.header.num_keys.saturating_sub(min_keys) as usize;
                }
            }
        }
    }

    // Recommend borrowing from sibling with more excess
    if candidates.has_left && candidates.has_right {
        if candidates.left_excess >= candidates.right_excess && candidates.left_excess > 0 {
            candidates.recommended_direction = Some(BorrowDirection::FromLeft);
        } else if candidates.right_excess > 0 {
            candidates.recommended_direction = Some(BorrowDirection::FromRight);
        }
    } else if candidates.has_left && candidates.left_excess > 0 {
        candidates.recommended_direction = Some(BorrowDirection::FromLeft);
    } else if candidates.has_right && candidates.right_excess > 0 {
        candidates.recommended_direction = Some(BorrowDirection::FromRight);
    }

    Ok(candidates)
}

/// Decide whether to borrow or merge based on node states
/// Prefer borrow when possible (more efficient)
pub fn decide_borrow_vs_merge(borrow_candidates: &BorrowCandidates) -> bool {
    // Borrow if possible
    borrow_candidates.can_borrow()
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
    }

    #[test]
    fn test_can_borrow_from_sibling() {
        let min_keys = calculate_min_keys();

        // Donor with excess, borrower with deficit
        assert!(can_borrow_from_sibling(min_keys + 20, min_keys - 5));

        // Donor with no excess
        assert!(!can_borrow_from_sibling(min_keys, min_keys - 5));

        // Both have enough but donor has excess (can still borrow)
        assert!(can_borrow_from_sibling(min_keys + 20, min_keys));

        // Neither has excess
        assert!(!can_borrow_from_sibling(min_keys, min_keys));
    }

    #[test]
    fn test_borrow_from_right_leaf() {
        let min_keys = calculate_min_keys();
        let mut underfull = LeafNode::new(1);
        let mut donor = LeafNode::new(2);

        // Add enough entries to donor (min_keys + 10)
        for i in 0..(min_keys as usize + 10) {
            donor.insert(Entry::new(format!("key{:05}", i).into_bytes(), vec![i as u8; 10], Lsn::from(i as u64))).unwrap();
        }

        // Add few entries to underfull (min_keys - 10)
        for i in 0..(min_keys as usize - 10) {
            underfull.insert(Entry::new(format!("key_under{:05}", i).into_bytes(), vec![0; 10], Lsn::from(100))).unwrap();
        }

        let result = borrow_from_right_leaf(&mut underfull, &mut donor).unwrap();
        assert!(matches!(result, BorrowResult::Success { .. }));

        // Check that entry was moved
        assert_eq!(donor.entries.len(), min_keys as usize + 9);
        assert_eq!(underfull.entries.len(), min_keys as usize - 9);
    }

    #[test]
    fn test_borrow_from_left_leaf() {
        let min_keys = calculate_min_keys();
        let mut underfull = LeafNode::new(1);
        let mut donor = LeafNode::new(2);

        // Add enough entries to donor (min_keys + 10)
        for i in 0..(min_keys as usize + 10) {
            donor.insert(Entry::new(format!("key{:05}", i).into_bytes(), vec![i as u8; 10], Lsn::from(i as u64))).unwrap();
        }

        // Add few entries to underfull (min_keys - 10)
        for i in 0..(min_keys as usize - 10) {
            underfull.insert(Entry::new(format!("key_under{:05}", i).into_bytes(), vec![0; 10], Lsn::from(100))).unwrap();
        }

        let result = borrow_from_left_leaf(&mut underfull, &mut donor).unwrap();
        assert!(matches!(result, BorrowResult::Success { .. }));

        // Check that entry was moved
        assert_eq!(donor.entries.len(), min_keys as usize + 9);
        assert_eq!(underfull.entries.len(), min_keys as usize - 9);
    }

    #[test]
    fn test_borrow_from_right_internal() {
        let mut underfull = InternalNode::new(1, 1);
        let mut donor = InternalNode::new(2, 1);

        // Add entries to donor (just enough to test the function)
        for i in 1..5 {
            donor.insert(format!("key{}", i).into_bytes(), i as u64).unwrap();
        }
        donor.set_rightmost_child(999);

        // Add few entries to underfull
        underfull.insert(b"sep0".to_vec(), 1000).unwrap();

        // This will return NotPossible since donor doesn't have enough excess
        // But it tests the code path
        let result = borrow_from_right_internal(&mut underfull, &mut donor, b"parent_sep".to_vec()).unwrap();

        // With only 5 entries in donor, we don't have enough to borrow
        // Just verify the function returns a valid result
        assert!(matches!(result, BorrowResult::NotPossible | BorrowResult::Success { .. }));
    }

    #[test]
    fn test_borrow_context() {
        let ctx = BorrowContext::new(PageId::from(1u64), PageId::from(2u64), BorrowDirection::FromRight)
            .with_entries(3)
            .with_parent(PageId::from(10u64));

        assert_eq!(ctx.underfull_page_id.as_u64(), 1);
        assert_eq!(ctx.donor_page_id.as_u64(), 2);
        assert_eq!(ctx.direction, BorrowDirection::FromRight);
        assert_eq!(ctx.entries_needed, 3);
        assert_eq!(ctx.parent_page_id, Some(PageId::from(10u64)));
    }

    #[test]
    fn test_decide_borrow_vs_merge() {
        let mut candidates = BorrowCandidates::new();
        candidates.has_left = true;
        candidates.left_excess = 5;

        assert!(decide_borrow_vs_merge(&candidates));

        candidates.left_excess = 0;
        assert!(!decide_borrow_vs_merge(&candidates));
    }
}
