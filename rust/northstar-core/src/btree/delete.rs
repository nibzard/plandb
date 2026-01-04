//! B+Tree Delete Operations
//!
//! Delete logic and merge/borrow handling.

use crate::{types::{PageId, Lsn}, error::{ValidationError, StorageError}, Error, Result};
use crate::btree::overflow::{ValueStorage, OVERFLOW_VALUE_MARKER};
use super::{node::{InternalNode, LeafNode, Node}, header::{HEADER_SIZE, DEFAULT_PAGE_SIZE}};

/// Minimum occupancy threshold (percentage of node capacity)
pub const MIN_OCCUPANCY: f64 = 0.4;

/// Result of a delete operation
#[derive(Debug, Clone)]
pub enum DeleteResult {
    /// Delete succeeded without reorganization
    Success,
    /// Delete caused node to become underfull
    Underfull { page_id: PageId },
    /// Delete caused nodes to merge
    Merged { freed_page_id: PageId },
}

/// Delete entry from leaf node
pub fn delete_from_leaf(
    node: &mut LeafNode,
    key: &[u8],
) -> Result<DeleteResult> {
    let removed = node.remove(key)?;

    if removed.is_some() {
        // Check if node is now underfull
        let min_entries = calculate_min_leaf_entries();
        if node.header.is_underfull(min_entries) {
            return Ok(DeleteResult::Underfull {
                page_id: PageId::from(node.header.node_id),
            });
        }
    }

    Ok(DeleteResult::Success)
}

/// Delete separator from internal node
pub fn delete_from_internal(
    node: &mut InternalNode,
    separator: &[u8],
    child_id: u64,
) -> Result<DeleteResult> {
    // Find separator position
    let pos = node.separators
        .binary_search_by(|probe| probe.as_slice().cmp(separator))
        .unwrap_or_else(|pos| pos);

    if pos < node.separators.len() && node.separators[pos] == separator {
        // Remove separator and corresponding child
        node.separators.remove(pos);
        node.children.remove(pos);

        node.header.num_keys = node.separators.len() as u16;
        node.header.free_space += (1 + separator.len() + 8) as u16;
        node.header.set_flag(0x00000002); // UNDERFULL flag

        // Check if node is now underfull
        let min_entries = calculate_min_internal_entries();
        if node.header.num_keys < min_entries {
            return Ok(DeleteResult::Underfull {
                page_id: PageId::from(node.header.node_id),
            });
        }
    }

    Ok(DeleteResult::Success)
}

/// Merge two leaf nodes
pub fn merge_leaf_nodes(
    left: &mut LeafNode,
    right: &mut LeafNode,
) -> Result<()> {
    // Check if combined entries fit
    let total_entries = left.entries.len() + right.entries.len();
    let total_size: usize = left.entries.iter().map(|e| e.serialized_size()).sum::<usize>()
        + right.entries.iter().map(|e| e.serialized_size()).sum::<usize>();
    let available_space = DEFAULT_PAGE_SIZE - HEADER_SIZE;

    if total_size > available_space {
        return Err(Error::Storage(StorageError::Pager("Merged nodes would exceed capacity".to_string())));
    }

    // Move all entries from right to left
    for entry in right.entries.drain(..) {
        left.insert(entry)?;
    }

    // Update linked list
    left.next_leaf = right.next_leaf;

    Ok(())
}

/// Merge two internal nodes
pub fn merge_internal_nodes(
    left: &mut InternalNode,
    right: &mut InternalNode,
    separator: Vec<u8>,
) -> Result<()> {
    // Add separator from parent
    left.insert(separator, *right.children.first().unwrap())?;

    // Move all separators and children from right to left
    let right_separators = std::mem::take(&mut right.separators);
    let right_children = std::mem::take(&mut right.children);

    for (sep, child) in right_separators.into_iter().zip(right_children.into_iter()) {
        left.insert(sep, child)?;
    }

    Ok(())
}

/// Borrow entry from sibling to fill underfull node
pub fn borrow_from_leaf_sibling(
    underfull: &mut LeafNode,
    sibling: &mut LeafNode,
    is_left_sibling: bool,
) -> Result<Vec<u8>> {
    if is_left_sibling {
        // Borrow last entry from left sibling
        let entry = sibling.entries.pop()
            .ok_or_else(|| Error::Validation(ValidationError::Generic("Left sibling is empty".to_string())))?;

        let separator = entry.key.clone();
        underfull.insert(entry)?;

        Ok(separator)
    } else {
        // Borrow first entry from right sibling
        if sibling.entries.is_empty() {
            return Err(Error::Validation(ValidationError::Generic("Right sibling is empty".to_string())));
        }
        let entry = sibling.entries.remove(0);

        let separator = entry.key.clone();
        underfull.insert(entry)?;

        Ok(separator)
    }
}

/// Calculate minimum entries for a leaf node
fn calculate_min_leaf_entries() -> u16 {
    // Approximately 40% of capacity
    let avg_entry_size = 100; // Rough estimate
    let max_entries = (DEFAULT_PAGE_SIZE - HEADER_SIZE) / avg_entry_size;
    (max_entries as f64 * MIN_OCCUPANCY) as u16
}

/// Calculate minimum entries for an internal node
fn calculate_min_internal_entries() -> u16 {
    // Approximately 40% of capacity
    let avg_entry_size = 20; // Rough estimate (key + pointer)
    let max_entries = (DEFAULT_PAGE_SIZE - HEADER_SIZE) / avg_entry_size;
    (max_entries as f64 * MIN_OCCUPANCY) as u16
}

/// Check if an entry value is stored as overflow
pub fn is_entry_overflow(entry: &crate::btree::node::Entry) -> bool {
    // An entry is overflow if value.len() == 10 and first 2 bytes are 0xFFFF
    if entry.value.len() == 10 {
        let marker = u16::from_le_bytes([entry.value[0], entry.value[1]]);
        marker == OVERFLOW_VALUE_MARKER
    } else {
        false
    }
}

/// Get the overflow page ID from an entry
///
/// Returns None if the value is inline, Some(page_id) if overflow.
pub fn get_entry_overflow_page_id(entry: &crate::btree::node::Entry) -> Option<PageId> {
    if is_entry_overflow(entry) {
        // Decode the overflow reference to get the page ID
        if let Ok(ValueStorage::Overflow(page_id)) = ValueStorage::decode(&entry.value) {
            Some(page_id)
        } else {
            None
        }
    } else {
        None
    }
}

/// Track overflow pages for cleanup after MVCC safety
///
/// This should be called when deleting entries with overflow values.
/// The overflow pages are not immediately freed but tracked for later
/// reclamation after all snapshots have released the LSN.
pub fn track_overflow_for_cleanup(
    entry: &crate::btree::node::Entry,
    cleanup_list: &mut Vec<PageId>,
) {
    if let Some(page_id) = get_entry_overflow_page_id(entry) {
        cleanup_list.push(page_id);
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Lsn;
    use crate::btree::node::Entry;

    #[test]
    fn test_delete_from_leaf() {
        let mut node = LeafNode::new(1);
        let entry = Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100));
        node.insert(entry).unwrap();

        let result = delete_from_leaf(&mut node, b"key1").unwrap();
        // After deleting the only entry, node is underfull
        assert!(matches!(result, DeleteResult::Underfull { .. }));
        assert_eq!(node.entries.len(), 0);
    }

    #[test]
    fn test_delete_from_leaf_not_found() {
        let mut node = LeafNode::new(1);
        let result = delete_from_leaf(&mut node, b"key1").unwrap();
        assert!(matches!(result, DeleteResult::Success));
    }

    #[test]
    fn test_merge_leaf_nodes() {
        let mut left = LeafNode::new(1);
        let mut right = LeafNode::new(2);

        left.insert(Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100))).unwrap();
        right.insert(Entry::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(200))).unwrap();
        right.next_leaf = 3;

        merge_leaf_nodes(&mut left, &mut right).unwrap();

        assert_eq!(left.entries.len(), 2);
        assert_eq!(left.next_leaf, 3);
    }

    #[test]
    fn test_borrow_from_sibling() {
        let mut underfull = LeafNode::new(1);
        let mut sibling = LeafNode::new(2);

        sibling.insert(Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100))).unwrap();

        let separator = borrow_from_leaf_sibling(&mut underfull, &mut sibling, true).unwrap();
        assert_eq!(separator, b"key1");
        assert_eq!(underfull.entries.len(), 1);
        assert_eq!(sibling.entries.len(), 0);
    }

    #[test]
    fn test_is_entry_overflow_inline() {
        let inline_value = ValueStorage::Inline(b"inline value".to_vec()).encode();
        let entry = Entry::new(b"key".to_vec(), inline_value, Lsn::from(1));

        assert!(!is_entry_overflow(&entry));
    }

    #[test]
    fn test_is_entry_overflow_overflow() {
        let overflow_ref = ValueStorage::Overflow(PageId::new(42)).encode();
        let entry = Entry::new(b"key".to_vec(), overflow_ref, Lsn::from(1));

        assert!(is_entry_overflow(&entry));
    }

    #[test]
    fn test_get_entry_overflow_page_id_inline() {
        let inline_value = ValueStorage::Inline(b"inline value".to_vec()).encode();
        let entry = Entry::new(b"key".to_vec(), inline_value, Lsn::from(1));

        assert_eq!(get_entry_overflow_page_id(&entry), None);
    }

    #[test]
    fn test_get_entry_overflow_page_id_overflow() {
        let overflow_ref = ValueStorage::Overflow(PageId::new(123)).encode();
        let entry = Entry::new(b"key".to_vec(), overflow_ref, Lsn::from(1));

        assert_eq!(get_entry_overflow_page_id(&entry), Some(PageId::new(123)));
    }

    #[test]
    fn test_track_overflow_for_cleanup_inline() {
        let inline_value = ValueStorage::Inline(b"inline value".to_vec()).encode();
        let entry = Entry::new(b"key".to_vec(), inline_value, Lsn::from(1));

        let mut cleanup_list = Vec::new();
        track_overflow_for_cleanup(&entry, &mut cleanup_list);

        assert_eq!(cleanup_list.len(), 0);
    }

    #[test]
    fn test_track_overflow_for_cleanup_overflow() {
        let overflow_ref = ValueStorage::Overflow(PageId::new(456)).encode();
        let entry = Entry::new(b"key".to_vec(), overflow_ref, Lsn::from(1));

        let mut cleanup_list = Vec::new();
        track_overflow_for_cleanup(&entry, &mut cleanup_list);

        assert_eq!(cleanup_list.len(), 1);
        assert_eq!(cleanup_list[0], PageId::new(456));
    }
}
