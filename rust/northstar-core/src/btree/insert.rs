//! B+Tree Insert Operations
//!
//! Insert logic and split handling.

use crate::{types::{PageId, Lsn}, error::{FeatureError, ValidationError, StorageError}, Error, Result};
use super::{node::{InternalNode, LeafNode, Node, Entry}, header::{NodeHeader, NodeFlags}, overflow::{OverflowPage, ValueStorage, INLINE_THRESHOLD, MAX_VALUE_SIZE, OVERFLOW_VALUE_MARKER}};

/// Split threshold (percentage of node capacity)
pub const SPLIT_THRESHOLD: f64 = 0.8;

/// Result of an insert operation
#[derive(Debug, Clone)]
pub enum InsertResult {
    /// Insert succeeded without split
    Success,
    /// Insert caused node split, returns new page ID and separator key
    Split { new_page_id: PageId, separator: Vec<u8> },
}

/// Insert entry into leaf node
pub fn insert_into_leaf(
    node: &mut LeafNode,
    entry: Entry,
    pager: &mut impl PagerTrait,
) -> Result<InsertResult> {
    // Check if node would be full after insert
    let would_be_full = !node.header.has_space(entry.serialized_size());

    // Try to insert
    let is_update = node.insert(entry)?;

    // If it's an update or node wasn't full, we're done
    if is_update || !would_be_full {
        return Ok(InsertResult::Success);
    }

    // Node is full after insert - split the node
    if node.needs_split(SPLIT_THRESHOLD) {
        let (new_node, separator) = split_leaf_node(node, pager)?;
        return Ok(InsertResult::Split {
            new_page_id: PageId::from(new_node.header.node_id),
            separator,
        });
    }

    Ok(InsertResult::Success)
}

/// Insert separator into internal node
pub fn insert_into_internal(
    node: &mut InternalNode,
    separator: Vec<u8>,
    child_id: u64,
    pager: &mut impl PagerTrait,
) -> Result<InsertResult> {
    // Check if node would be full after insert
    let would_be_full = !node.header.has_space(1 + separator.len() + 8);

    // Try to insert
    node.insert(separator, child_id)?;

    // If node wasn't full before insert, we're done
    if !would_be_full {
        return Ok(InsertResult::Success);
    }

    // Node is full after insert - split the node
    if node.needs_split(SPLIT_THRESHOLD) {
        let (new_node, separator) = split_internal_node(node, pager)?;
        return Ok(InsertResult::Split {
            new_page_id: PageId::from(new_node.header.node_id),
            separator,
        });
    }

    Ok(InsertResult::Success)
}

/// Split a leaf node into two nodes
pub fn split_leaf_node(
    node: &LeafNode,
    pager: &mut impl PagerTrait,
) -> Result<(LeafNode, Vec<u8>)> {
    // Calculate split point
    let split_point = node.entries.len() / 2;

    // Allocate new page
    let new_page_id = pager.allocate_page()?;

    // Create new leaf node
    let mut new_node = LeafNode::new(new_page_id.as_u64());

    // Move entries to new node
    for entry in node.entries[split_point..].to_vec() {
        new_node.insert(entry)?;
    }

    // Update linked list
    new_node.next_leaf = node.next_leaf;
    new_node.prev_leaf = node.header.node_id;

    // Get separator key (first key in new node)
    let separator = new_node.entries.first()
        .map(|e| e.key.clone())
        .ok_or_else(|| Error::Validation(ValidationError::Generic("Split leaf has no entries".to_string())))?;

    Ok((new_node, separator))
}

/// Split an internal node into two nodes
pub fn split_internal_node(
    node: &InternalNode,
    pager: &mut impl PagerTrait,
) -> Result<(InternalNode, Vec<u8>)> {
    // Calculate split point
    let split_point = node.separators.len() / 2;

    // Allocate new page
    let new_page_id = pager.allocate_page()?;

    // Create new internal node at same level
    let mut new_node = InternalNode::new(new_page_id.as_u64(), node.header.level);

    // Move separators and children to new node
    for (sep, child) in node.separators[split_point..].iter().zip(node.children[split_point+1..].iter()) {
        new_node.insert(sep.clone(), *child)?;
    }
    new_node.set_rightmost_child(*node.children.last().unwrap());

    // Get separator to promote (the separator at split point)
    let separator = node.separators[split_point].clone();

    Ok((new_node, separator))
}

/// Trait for pager operations needed by insert
pub trait PagerTrait {
    fn allocate_page(&mut self) -> Result<PageId>;
    fn write_node(&mut self, page_id: PageId, node: &Node) -> Result<()>;
    fn read_node(&mut self, page_id: PageId) -> Result<Node>;

    // Overflow page management
    fn allocate_overflow_chain(&mut self, value: &[u8]) -> Result<PageId>;
    fn free_overflow_chain(&mut self, first_page_id: PageId) -> Result<()>;
}

// Implement PagerTrait for Pager directly
impl PagerTrait for crate::pager::Pager {
    fn allocate_page(&mut self) -> Result<PageId> {
        self.allocate_page()
    }

    fn write_node(&mut self, page_id: PageId, node: &Node) -> Result<()> {
        self.write_btree_node(page_id, node)
    }

    fn read_node(&mut self, page_id: PageId) -> Result<Node> {
        self.read_btree_node(page_id)
    }

    fn allocate_overflow_chain(&mut self, value: &[u8]) -> Result<PageId> {
        self.allocate_overflow_chain(value)
    }

    fn free_overflow_chain(&mut self, first_page_id: PageId) -> Result<()> {
        self.free_overflow_chain(first_page_id)
    }
}

// Implement PagerTrait for references to Pager (for backwards compatibility)
impl<'a> PagerTrait for &'a mut crate::pager::Pager {
    fn allocate_page(&mut self) -> Result<PageId> {
        crate::pager::Pager::allocate_page(self)
    }

    fn write_node(&mut self, page_id: PageId, node: &Node) -> Result<()> {
        crate::pager::Pager::write_btree_node(self, page_id, node)
    }

    fn read_node(&mut self, page_id: PageId) -> Result<Node> {
        crate::pager::Pager::read_btree_node(self, page_id)
    }

    fn allocate_overflow_chain(&mut self, value: &[u8]) -> Result<PageId> {
        crate::pager::Pager::allocate_overflow_chain(self, value)
    }

    fn free_overflow_chain(&mut self, first_page_id: PageId) -> Result<()> {
        crate::pager::Pager::free_overflow_chain(self, first_page_id)
    }
}

/// Prepare an entry value for storage - converts to overflow if needed
pub fn prepare_entry_value(
    key: Vec<u8>,
    value: Vec<u8>,
    lsn: Lsn,
    pager: &mut impl PagerTrait,
) -> Result<Entry> {
    // Validate value size
    if value.len() > MAX_VALUE_SIZE {
        return Err(Error::Validation(ValidationError::Generic(
            format!("Value too large: {} bytes (max {})", value.len(), MAX_VALUE_SIZE)
        )));
    }

    // Check if we should store inline or use overflow
    if OverflowPage::should_store_inline(value.len()) {
        // Store inline value
        Ok(Entry::new(key, value, lsn))
    } else {
        // Allocate overflow page chain
        let overflow_page_id = pager.allocate_overflow_chain(&value)?;

        // Encode overflow reference as value
        let overflow_ref = ValueStorage::Overflow(overflow_page_id).encode();

        Ok(Entry::new(key, overflow_ref, lsn))
    }
}

/// Check if an entry value is stored as overflow
pub fn is_overflow_value(entry: &Entry) -> bool {
    // An entry is overflow if value.len() == 10 and first 2 bytes are 0xFFFF
    if entry.value.len() == 10 {
        let marker = u16::from_le_bytes([entry.value[0], entry.value[1]]);
        marker == OVERFLOW_VALUE_MARKER
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockPager;

    impl PagerTrait for MockPager {
        fn allocate_page(&mut self) -> Result<PageId> {
            Ok(PageId::from(999u64))
        }

        fn write_node(&mut self, _page_id: PageId, _node: &Node) -> Result<()> {
            Ok(())
        }

        fn read_node(&mut self, _page_id: PageId) -> Result<Node> {
            Err(Error::Validation(ValidationError::Generic("MockPager does not support read_node".to_string())))
        }

        fn allocate_overflow_chain(&mut self, _value: &[u8]) -> Result<PageId> {
            Ok(PageId::from(888u64))
        }

        fn free_overflow_chain(&mut self, _first_page_id: PageId) -> Result<()> {
            Ok(())
        }
    }

    #[test]
    fn test_insert_into_leaf() {
        let mut node = LeafNode::new(1);
        let mut pager = MockPager;

        let entry = Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100));
        let result = insert_into_leaf(&mut node, entry, &mut pager).unwrap();
        assert!(matches!(result, InsertResult::Success));
    }

    #[test]
    fn test_insert_into_internal() {
        let mut node = InternalNode::new(1, 1);
        let mut pager = MockPager;

        let result = insert_into_internal(
            &mut node,
            b"key1".to_vec(),
            10,
            &mut pager
        ).unwrap();
        assert!(matches!(result, InsertResult::Success));
    }

    #[test]
    fn test_prepare_entry_value_inline() {
        let mut pager = MockPager;

        // Small value should be stored inline
        let entry = prepare_entry_value(
            b"key".to_vec(),
            b"small value".to_vec(),
            Lsn::from(1),
            &mut pager
        ).unwrap();

        assert!(!is_overflow_value(&entry));
        assert_eq!(entry.value, b"small value");
    }

    #[test]
    fn test_prepare_entry_value_overflow() {
        let mut pager = MockPager;

        // Large value should trigger overflow
        let large_value = vec![42u8; INLINE_THRESHOLD + 1];
        let entry = prepare_entry_value(
            b"key".to_vec(),
            large_value.clone(),
            Lsn::from(1),
            &mut pager
        ).unwrap();

        assert!(is_overflow_value(&entry));
        assert_eq!(entry.value.len(), 10); // Overflow reference size
    }

    #[test]
    fn test_prepare_entry_value_too_large() {
        let mut pager = MockPager;

        // Value exceeding MAX_VALUE_SIZE should fail
        let too_large = vec![0u8; MAX_VALUE_SIZE + 1];
        let result = prepare_entry_value(
            b"key".to_vec(),
            too_large,
            Lsn::from(1),
            &mut pager
        );

        assert!(result.is_err());
    }

    #[test]
    fn test_is_overflow_value_inline() {
        let entry = Entry::new(
            b"key".to_vec(),
            b"inline value".to_vec(),
            Lsn::from(1)
        );

        assert!(!is_overflow_value(&entry));
    }

    #[test]
    fn test_is_overflow_value_overflow() {
        let overflow_ref = ValueStorage::Overflow(PageId::new(42)).encode();
        let entry = Entry::new(
            b"key".to_vec(),
            overflow_ref,
            Lsn::from(1)
        );

        assert!(is_overflow_value(&entry));
    }
}
