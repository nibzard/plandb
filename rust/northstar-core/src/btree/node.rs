//! B+Tree Node Structures
//!
//! Internal and leaf node implementations for the B+Tree.

use crate::{types::{Lsn, PageId}, error::{ValidationError, StorageError}, Error, Result};
use super::header::{NodeHeader, NodeType, NodeFlags, HEADER_SIZE, DEFAULT_PAGE_SIZE};

/// Maximum key length in bytes
pub const MAX_KEY_LENGTH: usize = 255;

/// Maximum inline value length in bytes
pub const MAX_INLINE_VALUE_LENGTH: usize = 65535;

/// Marker for overflow values in value_len field
pub const OVERFLOW_VALUE_MARKER: u16 = 0xFFFF;

/// Key-value entry in a leaf node
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Key bytes
    pub key: Vec<u8>,
    /// Value bytes (inline) or overflow page ID
    pub value: Vec<u8>,
    /// Log sequence number for MVCC
    pub lsn: Lsn,
}

impl Entry {
    /// Calculate the size of this entry when serialized
    pub fn serialized_size(&self) -> usize {
        // key_len (1) + key + value_len (2) + value + lsn (8)
        1 + self.key.len() + 2 + self.value.len() + 8
    }

    /// Create a new entry
    pub fn new(key: Vec<u8>, value: Vec<u8>, lsn: Lsn) -> Self {
        Entry { key, value, lsn }
    }
}

/// Internal node (branch node) for routing searches
#[derive(Debug, Clone)]
pub struct InternalNode {
    /// Node header
    pub header: NodeHeader,
    /// Separator keys (keys that divide child ranges)
    pub separators: Vec<Vec<u8>>,
    /// Child page IDs (one more than separators)
    pub children: Vec<u64>,
}

impl InternalNode {
    /// Create a new internal node
    pub fn new(page_id: u64, level: u16) -> Self {
        let header = NodeHeader::new(NodeType::Internal, page_id.into(), level);
        Self {
            header,
            separators: Vec::new(),
            children: Vec::new(),
        }
    }

    /// Add a separator key and child pointer
    pub fn insert(&mut self, separator: Vec<u8>, child_id: u64) -> Result<()> {
        let entry_size = 1 + separator.len() + 8; // key_len + key + child_ptr

        if !self.header.has_space(entry_size) {
            return Err(Error::Storage(StorageError::Pager("Internal node".to_string())));
        }

        // Find insertion position (maintain sorted order)
        let pos = self.separators
            .binary_search_by(|probe| probe.as_slice().cmp(separator.as_slice()))
            .unwrap_or_else(|pos| pos);

        self.separators.insert(pos, separator);
        self.children.insert(pos, child_id);

        self.header.num_keys = self.separators.len() as u16;
        self.header.free_space = self.header.free_space.saturating_sub(entry_size as u16);
        self.header.set_flag(NodeFlags::DIRTY);
        self.header.increment_generation();

        Ok(())
    }

    /// Set the rightmost child pointer
    pub fn set_rightmost_child(&mut self, child_id: u64) {
        if self.children.len() <= self.separators.len() {
            self.children.push(child_id);
        } else {
            *self.children.last_mut().unwrap() = child_id;
        }
    }

    /// Get child pointer for a given key (binary search)
    pub fn find_child(&self, key: &[u8]) -> u64 {
        let pos = self.separators
            .binary_search_by(|probe| probe.as_slice().cmp(key))
            .unwrap_or_else(|pos| pos);

        // In B+Tree, if key matches a separator, go to the right child
        // This is because all actual keys are stored in leaf nodes
        if pos < self.separators.len() && self.separators[pos] == key {
            self.children[pos + 1]
        } else {
            self.children[pos]
        }
    }

    /// Calculate actual free space
    pub fn calculate_free_space(&self) -> u16 {
        let used: usize = self.separators.iter().map(|k| 1 + k.len()).sum::<usize>()
            + self.children.len() * 8;
        (DEFAULT_PAGE_SIZE - HEADER_SIZE - used) as u16
    }

    /// Validate node invariants
    pub fn validate(&self) -> Result<()> {
        // Check separators are sorted
        for i in 1..self.separators.len() {
            if self.separators[i] <= self.separators[i-1] {
                return Err(Error::Validation(ValidationError::Generic("Separators not sorted".to_string())));
            }
        }

        // Check children count = separators + 1
        if self.children.len() != self.separators.len() + 1 {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Children count mismatch: {} != {} + 1",
                    self.children.len(), self.separators.len())
            )));
        }

        // Check free space consistency
        let calculated_free = self.calculate_free_space();
        let header_free_space = self.header.free_space;
        if (header_free_space as i32 - calculated_free as i32).abs() > 10 {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Free space mismatch: header={}, calculated={}",
                    header_free_space, calculated_free)
            )));
        }

        Ok(())
    }

    /// Check if node is full (needs split)
    pub fn needs_split(&self, threshold: f64) -> bool {
        let total_space = (DEFAULT_PAGE_SIZE - HEADER_SIZE) as f64;
        let header_free_space = self.header.free_space;
        let used_space = total_space - header_free_space as f64;
        (used_space / total_space) >= threshold
    }
}

/// Leaf node containing key-value pairs
#[derive(Debug, Clone)]
pub struct LeafNode {
    /// Node header
    pub header: NodeHeader,
    /// Key-value entries
    pub entries: Vec<Entry>,
    /// Next leaf page ID in linked list (0 if none)
    pub next_leaf: u64,
    /// Previous leaf page ID in linked list (0 if none)
    pub prev_leaf: u64,
}

impl LeafNode {
    /// Create a new leaf node
    pub fn new(page_id: u64) -> Self {
        let mut header = NodeHeader::new(NodeType::Leaf, page_id.into(), 0);
        // Account for linked list pointers (16 bytes: next_leaf + prev_leaf)
        header.free_space = header.free_space.saturating_sub(16);
        Self {
            header,
            entries: Vec::new(),
            next_leaf: 0,
            prev_leaf: 0,
        }
    }

    /// Insert or update an entry
    pub fn insert(&mut self, entry: Entry) -> Result<bool> {
        let entry_size = entry.serialized_size();

        if !self.header.has_space(entry_size) {
            return Err(Error::Storage(StorageError::Pager("Leaf node".to_string())));
        }

        // Check if key already exists
        let pos = self.entries
            .binary_search_by(|probe| probe.key.as_slice().cmp(entry.key.as_slice()))
            .unwrap_or_else(|pos| pos);

        let is_update = pos < self.entries.len() && self.entries[pos].key == entry.key;

        if is_update {
            // Update existing entry (calculate size delta)
            let old_size = self.entries[pos].serialized_size();
            self.entries[pos] = entry;
            let size_delta = entry_size as i32 - old_size as i32;
            self.header.free_space = self.header.free_space.saturating_sub(size_delta as u16);
        } else {
            // Insert new entry
            self.entries.insert(pos, entry);
            self.header.num_keys = self.entries.len() as u16;
            self.header.free_space = self.header.free_space.saturating_sub(entry_size as u16);
        }

        self.header.set_flag(NodeFlags::DIRTY);
        self.header.increment_generation();

        Ok(is_update)
    }

    /// Find entry by key (binary search)
    pub fn find(&self, key: &[u8]) -> Option<&Entry> {
        let result = self.entries.binary_search_by(|probe| probe.key.as_slice().cmp(key));

        if let Err(pos) = result {
            println!("    LeafNode::find key={:?} not found", std::str::from_utf8(key).unwrap_or("<binary>"));
            if pos < self.entries.len() {
                println!("      Closest key at position {}: {:?}", pos, std::str::from_utf8(&self.entries[pos].key).unwrap_or("<binary>"));
            } else if pos > 0 && self.entries.len() > 0 {
                println!("      Last key at position {}: {:?}", pos - 1, std::str::from_utf8(&self.entries[pos - 1].key).unwrap_or("<binary>"));
            }
            return None;
        }

        let pos = result.ok()?;
        Some(&self.entries[pos])
    }

    /// Remove entry by key
    pub fn remove(&mut self, key: &[u8]) -> Result<Option<Entry>> {
        let pos = self.entries
            .binary_search_by(|probe| probe.key.as_slice().cmp(key))
            .ok();

        if let Some(pos) = pos {
            let entry = self.entries.remove(pos);
            let entry_size = entry.serialized_size();
            self.header.num_keys = self.entries.len() as u16;
            self.header.free_space += entry_size as u16;
            self.header.set_flag(NodeFlags::DIRTY);
            self.header.increment_generation();

            // Check if underfull
            let min_entries = ((DEFAULT_PAGE_SIZE - HEADER_SIZE) / 100) as u16; // Approximate
            if self.header.is_underfull(min_entries) {
                self.header.set_flag(NodeFlags::UNDERFULL);
            }

            Ok(Some(entry))
        } else {
            Ok(None)
        }
    }

    /// Calculate actual free space
    pub fn calculate_free_space(&self) -> u16 {
        let used: usize = self.entries.iter().map(|e| e.serialized_size()).sum();
        // Account for linked list pointers (16 bytes at end of page)
        (DEFAULT_PAGE_SIZE - HEADER_SIZE - 16 - used) as u16
    }

    /// Validate node invariants
    pub fn validate(&self) -> Result<()> {
        // Check keys are sorted
        for i in 1..self.entries.len() {
            if self.entries[i].key <= self.entries[i-1].key {
                return Err(Error::Validation(ValidationError::Generic("Keys not sorted".to_string())));
            }
        }

        // Check entry count matches
        let header_num_keys = self.header.num_keys;
        if self.entries.len() != header_num_keys as usize {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Entry count mismatch: {} != {}",
                    self.entries.len(), header_num_keys)
            )));
        }

        // Check free space consistency
        let calculated_free = self.calculate_free_space();
        let header_free_space = self.header.free_space;
        if (header_free_space as i32 - calculated_free as i32).abs() > 10 {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Free space mismatch: header={}, calculated={}",
                    header_free_space, calculated_free)
            )));
        }

        Ok(())
    }

    /// Check if node is full (needs split)
    pub fn needs_split(&self, threshold: f64) -> bool {
        let total_space = (DEFAULT_PAGE_SIZE - HEADER_SIZE) as f64;
        let header_free_space = self.header.free_space;
        let used_space = total_space - header_free_space as f64;
        (used_space / total_space) >= threshold
    }
}

/// Node enumeration for type-safe operations
#[derive(Debug, Clone)]
pub enum Node {
    Internal(InternalNode),
    Leaf(LeafNode),
}

impl Node {
    /// Get the node header
    pub fn header(&self) -> &NodeHeader {
        match self {
            Node::Internal(node) => &node.header,
            Node::Leaf(node) => &node.header,
        }
    }

    /// Get mutable reference to header
    pub fn header_mut(&mut self) -> &mut NodeHeader {
        match self {
            Node::Internal(node) => &mut node.header,
            Node::Leaf(node) => &mut node.header,
        }
    }

    /// Check if node is internal
    pub fn is_internal(&self) -> bool {
        matches!(self, Node::Internal(_))
    }

    /// Check if node is leaf
    pub fn is_leaf(&self) -> bool {
        matches!(self, Node::Leaf(_))
    }

    /// Convert to internal node
    pub fn as_internal(&self) -> Option<&InternalNode> {
        match self {
            Node::Internal(node) => Some(node),
            _ => None,
        }
    }

    /// Convert to leaf node
    pub fn as_leaf(&self) -> Option<&LeafNode> {
        match self {
            Node::Leaf(node) => Some(node),
            _ => None,
        }
    }

    /// Validate node invariants
    pub fn validate(&self) -> Result<()> {
        match self {
            Node::Internal(node) => node.validate(),
            Node::Leaf(node) => node.validate(),
        }
    }
}

impl From<InternalNode> for Node {
    fn from(node: InternalNode) -> Self {
        Node::Internal(node)
    }
}

impl From<LeafNode> for Node {
    fn from(node: LeafNode) -> Self {
        Node::Leaf(node)
    }
}

impl Node {
    /// Serialize node to bytes
    pub fn to_bytes(&self) -> Vec<u8> {
        match self {
            Node::Internal(node) => {
                let mut bytes = vec![0u8; DEFAULT_PAGE_SIZE];

                // Write header
                let header_bytes = unsafe {
                    std::slice::from_raw_parts(
                        &node.header as *const NodeHeader as *const u8,
                        HEADER_SIZE
                    )
                };
                bytes[0..HEADER_SIZE].copy_from_slice(header_bytes);

                // Write separators and children
                let mut offset = HEADER_SIZE;
                for (sep, child) in node.separators.iter().zip(node.children.iter()) {
                    // Write separator key length and key
                    bytes[offset] = sep.len() as u8;
                    offset += 1;
                    bytes[offset..offset + sep.len()].copy_from_slice(sep);
                    offset += sep.len();

                    // Write child pointer
                    bytes[offset..offset + 8].copy_from_slice(&child.to_le_bytes());
                    offset += 8;
                }

                // Write last child pointer if exists
                if node.children.len() > node.separators.len() {
                    let last_child = node.children.last().unwrap();
                    bytes[offset..offset + 8].copy_from_slice(&last_child.to_le_bytes());
                }

                // Calculate and write checksum at offset 28 (correct field location)
                let checksum = node.header.calculate_checksum(&bytes);
                bytes[28..32].copy_from_slice(&checksum.to_le_bytes());

                bytes
            }
            Node::Leaf(node) => {
                let mut bytes = vec![0u8; DEFAULT_PAGE_SIZE];

                // Write header
                let header_bytes = unsafe {
                    std::slice::from_raw_parts(
                        &node.header as *const NodeHeader as *const u8,
                        HEADER_SIZE
                    )
                };
                bytes[0..HEADER_SIZE].copy_from_slice(header_bytes);

                // Write entries
                let mut offset = HEADER_SIZE;
                for entry in &node.entries {
                    // Write key length and key
                    bytes[offset] = entry.key.len() as u8;
                    offset += 1;
                    bytes[offset..offset + entry.key.len()].copy_from_slice(&entry.key);
                    offset += entry.key.len();

                    // Write value length and value
                    let value_len = entry.value.len() as u16;
                    bytes[offset..offset + 2].copy_from_slice(&value_len.to_le_bytes());
                    offset += 2;
                    bytes[offset..offset + entry.value.len()].copy_from_slice(&entry.value);
                    offset += entry.value.len();

                    // Write LSN
                    bytes[offset..offset + 8].copy_from_slice(&entry.lsn.as_u64().to_le_bytes());
                    offset += 8;
                }

                // Write linked list pointers at the end of the page (last 16 bytes)
                // This avoids overwriting header fields
                bytes[DEFAULT_PAGE_SIZE - 16..DEFAULT_PAGE_SIZE - 8].copy_from_slice(&node.next_leaf.to_le_bytes());
                bytes[DEFAULT_PAGE_SIZE - 8..DEFAULT_PAGE_SIZE].copy_from_slice(&node.prev_leaf.to_le_bytes());

                // Calculate and write checksum at offset 28 (correct field location)
                let checksum = node.header.calculate_checksum(&bytes);
                bytes[28..32].copy_from_slice(&checksum.to_le_bytes());

                bytes
            }
        }
    }

    /// Deserialize node from bytes
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < HEADER_SIZE {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Node bytes too short: {} < {}", bytes.len(), HEADER_SIZE)
            )));
        }

        // Read header
        let header = unsafe {
            (bytes.as_ptr() as *const NodeHeader).read_unaligned()
        };

        header.validate(PageId::from(header.node_id))?;

        let node_type = header.get_node_type()
            .ok_or_else(|| Error::Validation(ValidationError::Generic(
                format!("Invalid node type: {}", header.node_type)
            )))?;

        match node_type.base_type() {
            NodeType::Internal => {
                let mut separators = Vec::new();
                let mut children = Vec::new();
                let mut offset = HEADER_SIZE;

                // Read separators and children (up to num_keys)
                for _ in 0..header.num_keys {
                    // Read separator key
                    let key_len = bytes[offset] as usize;
                    offset += 1;
                    let key = bytes[offset..offset + key_len].to_vec();
                    offset += key_len;

                    // Read child pointer
                    let child_bytes = bytes[offset..offset + 8].try_into()
                        .unwrap_or_else(|_| [0u8; 8]);
                    let child = u64::from_le_bytes(child_bytes);
                    offset += 8;

                    separators.push(key);
                    children.push(child);
                }

                // Read last child pointer
                if offset + 8 <= bytes.len() {
                    let child_bytes = bytes[offset..offset + 8].try_into()
                        .unwrap_or_else(|_| [0u8; 8]);
                    let last_child = u64::from_le_bytes(child_bytes);
                    children.push(last_child);
                }

                let mut internal_node = InternalNode {
                    header,
                    separators,
                    children,
                };

                Ok(Node::Internal(internal_node))
            }
            NodeType::Leaf => {
                let mut entries = Vec::new();
                let mut offset = HEADER_SIZE;

                // Read entries
                for _ in 0..header.num_keys {
                    // Read key
                    let key_len = bytes[offset] as usize;
                    offset += 1;
                    let key = bytes[offset..offset + key_len].to_vec();
                    offset += key_len;

                    // Read value
                    let value_len_bytes = bytes[offset..offset + 2].try_into()
                        .unwrap_or_else(|_| [0u8; 2]);
                    let value_len = u16::from_le_bytes(value_len_bytes) as usize;
                    offset += 2;
                    let value = bytes[offset..offset + value_len].to_vec();
                    offset += value_len;

                    // Read LSN
                    let lsn_bytes = bytes[offset..offset + 8].try_into()
                        .unwrap_or_else(|_| [0u8; 8]);
                    let lsn = Lsn::from(u64::from_le_bytes(lsn_bytes));
                    offset += 8;

                    entries.push(Entry { key, value, lsn });
                }

                // Read linked list pointers from the end of the page (last 16 bytes)
                let next_leaf_bytes = bytes[DEFAULT_PAGE_SIZE - 16..DEFAULT_PAGE_SIZE - 8].try_into()
                    .unwrap_or_else(|_| [0u8; 8]);
                let next_leaf = u64::from_le_bytes(next_leaf_bytes);

                let prev_leaf_bytes = bytes[DEFAULT_PAGE_SIZE - 8..DEFAULT_PAGE_SIZE].try_into()
                    .unwrap_or_else(|_| [0u8; 8]);
                let prev_leaf = u64::from_le_bytes(prev_leaf_bytes);

                let mut leaf_node = LeafNode {
                    header,
                    entries,
                    next_leaf,
                    prev_leaf,
                };

                Ok(Node::Leaf(leaf_node))
            }
            _ => Err(Error::Validation(ValidationError::Generic(
                "Unsupported node type".to_string()
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_internal_node_creation() {
        let node = InternalNode::new(42, 1);
        let num_keys = node.header.num_keys;
        assert_eq!(num_keys, 0);
        assert_eq!(node.children.len(), 0);
        assert_eq!(node.separators.len(), 0);
    }

    #[test]
    fn test_internal_node_insert() {
        let mut node = InternalNode::new(42, 1);

        node.insert(b"key1".to_vec(), 10).unwrap();
        node.insert(b"key2".to_vec(), 11).unwrap();
        node.set_rightmost_child(12);

        assert_eq!(node.separators.len(), 2);
        assert_eq!(node.children.len(), 3);
        assert_eq!(node.find_child(b"key0"), 10);
        assert_eq!(node.find_child(b"key1"), 11);
        assert_eq!(node.find_child(b"key3"), 12);
    }

    #[test]
    fn test_internal_node_validation() {
        let mut node = InternalNode::new(42, 1);
        node.insert(b"key1".to_vec(), 10).unwrap();
        node.set_rightmost_child(11);

        assert!(node.validate().is_ok());

        // Mess up the ordering
        node.separators = vec![b"key2".to_vec(), b"key1".to_vec()];
        assert!(node.validate().is_err());
    }

    #[test]
    fn test_leaf_node_creation() {
        let node = LeafNode::new(42);
        let num_keys = node.header.num_keys;
        assert_eq!(num_keys, 0);
        assert_eq!(node.entries.len(), 0);
    }

    #[test]
    fn test_leaf_node_insert() {
        let mut node = LeafNode::new(42);

        let entry1 = Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1));
        let entry2 = Entry::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(2));

        assert!(!node.insert(entry1.clone()).unwrap());
        assert!(!node.insert(entry2.clone()).unwrap());
        assert_eq!(node.entries.len(), 2);

        // Update existing key
        let entry1_updated = Entry::new(b"key1".to_vec(), b"value1_updated".to_vec(), Lsn::from(3));
        assert!(node.insert(entry1_updated).unwrap());
        assert_eq!(node.entries.len(), 2);
    }

    #[test]
    fn test_leaf_node_find() {
        let mut node = LeafNode::new(42);

        let entry1 = Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1));
        node.insert(entry1).unwrap();

        assert!(node.find(b"key1").is_some());
        assert!(node.find(b"key2").is_none());
    }

    #[test]
    fn test_leaf_node_remove() {
        let mut node = LeafNode::new(42);

        let entry1 = Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1));
        node.insert(entry1).unwrap();

        let removed = node.remove(b"key1").unwrap();
        assert!(removed.is_some());
        assert_eq!(node.entries.len(), 0);

        let removed_again = node.remove(b"key1").unwrap();
        assert!(removed_again.is_none());
    }

    #[test]
    fn test_leaf_node_validation() {
        let mut node = LeafNode::new(42);

        let entry1 = Entry::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1));
        let entry2 = Entry::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(2));
        node.insert(entry1).unwrap();
        node.insert(entry2).unwrap();

        assert!(node.validate().is_ok());

        // Mess up the ordering
        node.entries.swap(0, 1);
        assert!(node.validate().is_err());
    }

    #[test]
    fn test_entry_serialized_size() {
        let entry = Entry::new(
            b"test_key".to_vec(),
            b"test_value".to_vec(),
            Lsn::from(1)
        );

        // key_len(1) + key(8) + value_len(2) + value(10) + lsn(8) = 29
        assert_eq!(entry.serialized_size(), 29);
    }

    #[test]
    fn test_node_enum() {
        let internal = InternalNode::new(1, 1);
        let leaf = LeafNode::new(2);

        let node1: Node = internal.into();
        let node2: Node = leaf.into();

        assert!(node1.is_internal());
        assert!(node2.is_leaf());
        assert!(node1.as_internal().is_some());
        assert!(node1.as_leaf().is_none());
        assert!(node2.as_leaf().is_some());
        assert!(node2.as_internal().is_none());
    }
}
