//! B+Tree Node Header
//!
//! Fixed-size metadata structure that appears at the start of every B+Tree node.
//! Provides identification, validation, and state information.

use crate::{checksum, types::PageId, error::{ValidationError, StorageError}, Error, Result};
use std::fmt;

/// Magic number for B+Tree nodes (ASCII "NSTR")
pub const NODE_MAGIC: u32 = 0x4E535452;

/// Node header size in bytes
pub const HEADER_SIZE: usize = std::mem::size_of::<NodeHeader>();

/// Default page size (16KB)
pub const DEFAULT_PAGE_SIZE: usize = 16384;

/// Node type enumeration
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeType {
    /// Internal (branch) node with separator keys and child pointers
    Internal = 1,
    /// Leaf node containing key-value pairs
    Leaf = 2,
    /// Internal node that is also the tree root
    RootInternal = 3,
    /// Leaf node that is also the tree root
    RootLeaf = 4,
}

impl NodeType {
    /// Create NodeType from u8 value
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            1 => Some(NodeType::Internal),
            2 => Some(NodeType::Leaf),
            3 => Some(NodeType::RootInternal),
            4 => Some(NodeType::RootLeaf),
            _ => None,
        }
    }

    /// Check if this node type is a root node
    pub fn is_root(self) -> bool {
        matches!(self, NodeType::RootInternal | NodeType::RootLeaf)
    }

    /// Check if this node type is a leaf node
    pub fn is_leaf(self) -> bool {
        matches!(self, NodeType::Leaf | NodeType::RootLeaf)
    }

    /// Check if this node type is an internal node
    pub fn is_internal(self) -> bool {
        matches!(self, NodeType::Internal | NodeType::RootInternal)
    }

    /// Get the base node type (without root flag)
    pub fn base_type(self) -> NodeType {
        match self {
            NodeType::RootInternal => NodeType::Internal,
            NodeType::RootLeaf => NodeType::Leaf,
            other => other,
        }
    }
}

/// Node flag bit values
pub struct NodeFlags;

impl NodeFlags {
    pub const DIRTY: u32 = 0x00000001;
    pub const UNDERFULL: u32 = 0x00000002;
    pub const OVERFLOW: u32 = 0x00000004;
    pub const COMPRESSED: u32 = 0x00000008;
    pub const DELETED: u32 = 0x00000010;
    pub const SPLIT_PENDING: u32 = 0x00000020;
    pub const MERGE_PENDING: u32 = 0x00000040;
}

/// B+Tree node header
///
/// Fixed-size metadata structure that prefixes every B+Tree node.
/// Must match exact binary layout for on-disk compatibility.
#[repr(C, packed)]
#[derive(Clone)]
pub struct NodeHeader {
    /// Magic number (0x4E535452 = "NSTR")
    pub magic: u32,
    /// Node type (1=Internal, 2=Leaf, 3=RootInternal, 4=RootLeaf)
    pub node_type: u8,
    /// Is root flag (0=normal, 1=root)
    pub is_root: u8,
    /// Number of keys/entries in the node
    pub num_keys: u16,
    /// Parent node page ID (0 if root)
    pub parent_page_id: u64,
    /// Right sibling page ID (0 if none)
    pub right_sibling_page_id: u64,
    /// Free bytes available in node body
    pub free_space: u16,
    /// Tree level (0=leaf)
    pub level: u16,
    /// CRC32C checksum of node contents
    pub checksum: u32,
    /// Node state flags
    pub flags: u32,
    /// Node version counter
    pub generation: u64,
    /// Reserved for future use
    pub reserved: u64,
    /// Page ID (must match page address)
    pub node_id: u64,
}

impl NodeHeader {
    /// Create a new node header
    pub fn new(node_type: NodeType, page_id: PageId, level: u16) -> Self {
        let is_root = node_type.is_root();
        Self {
            magic: NODE_MAGIC,
            node_type: node_type as u8,
            is_root: if is_root { 1 } else { 0 },
            num_keys: 0,
            parent_page_id: 0,
            right_sibling_page_id: 0,
            free_space: (DEFAULT_PAGE_SIZE - HEADER_SIZE) as u16,
            level,
            checksum: 0,
            flags: 0,
            generation: 1,
            reserved: 0,
            node_id: page_id.as_u64(),
        }
    }

    /// Validate the header
    pub fn validate(&self, page_id: PageId) -> Result<()> {
        // Check magic number
        if self.magic != NODE_MAGIC {
            return Err(Error::Validation(ValidationError::InvalidMagic {
                expected: NODE_MAGIC,
                actual: self.magic,
            }));
        }

        // Check node type
        let node_type = NodeType::from_u8(self.node_type)
            .ok_or_else(|| Error::Validation(ValidationError::Generic(format!("Invalid node type: {}", self.node_type))))?;

        // Check is_root consistency
        let is_root_flag = self.is_root != 0;
        if node_type.is_root() != is_root_flag {
            return Err(Error::Validation(ValidationError::Generic(
                "Node type is_root flag inconsistency".to_string()
            )));
        }

        // Check parent_page_id for root nodes
        if is_root_flag && self.parent_page_id != 0 {
            return Err(Error::Validation(ValidationError::Generic(
                "Root node has non-zero parent".to_string()
            )));
        }

        // Check level for leaf nodes
        if node_type.is_leaf() && self.level != 0 {
            return Err(Error::Validation(ValidationError::InvalidLeafLevel {
                level: self.level,
            }));
        }

        // Check reserved field
        if self.reserved != 0 {
            return Err(Error::Validation(ValidationError::InvalidReservedField {
                value: self.reserved as u32,
            }));
        }

        // Check node_id matches
        let node_id = self.node_id;
        if node_id != page_id.as_u64() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Node ID mismatch: header={}, page={}",
                node_id,
                page_id.as_u64()
            ))));
        }

        Ok(())
    }

    /// Get the node type
    pub fn get_node_type(&self) -> Option<NodeType> {
        NodeType::from_u8(self.node_type)
    }

    /// Check if this is a root node
    pub fn is_root_node(&self) -> bool {
        self.is_root != 0
    }

    /// Check if node has sufficient space for an entry
    pub fn has_space(&self, entry_size: usize) -> bool {
        self.free_space as usize >= entry_size
    }

    /// Check if node is below minimum occupancy
    pub fn is_underfull(&self, min_entries: u16) -> bool {
        !self.is_root_node() && self.num_keys < min_entries
    }

    /// Check if a flag is set
    pub fn has_flag(&self, flag: u32) -> bool {
        (self.flags & flag) != 0
    }

    /// Set a flag
    pub fn set_flag(&mut self, flag: u32) {
        self.flags |= flag;
    }

    /// Clear a flag
    pub fn clear_flag(&mut self, flag: u32) {
        self.flags &= !flag;
    }

    /// Calculate checksum for node data
    pub fn calculate_checksum(&self, node_bytes: &[u8]) -> u32 {
        checksum::crc32c(node_bytes)
    }

    /// Verify checksum
    pub fn verify_checksum(&self, node_bytes: &[u8]) -> bool {
        let calculated = self.calculate_checksum(node_bytes);
        calculated == self.checksum
    }

    /// Increment generation counter
    pub fn increment_generation(&mut self) {
        self.generation = self.generation.wrapping_add(1);
    }
}

impl fmt::Debug for NodeHeader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Copy packed fields to local variables to avoid unaligned references
        let magic = self.magic;
        let num_keys = self.num_keys;
        let parent_page_id = self.parent_page_id;
        let right_sibling_page_id = self.right_sibling_page_id;
        let free_space = self.free_space;
        let level = self.level;
        let checksum = self.checksum;
        let flags = self.flags;
        let generation = self.generation;
        let node_id = self.node_id;

        f.debug_struct("NodeHeader")
            .field("magic", &format_args!("0x{:08X}", magic))
            .field("node_type", &self.get_node_type())
            .field("is_root", &self.is_root_node())
            .field("num_keys", &num_keys)
            .field("parent_page_id", &PageId::from(parent_page_id))
            .field("right_sibling", &PageId::from(right_sibling_page_id))
            .field("free_space", &free_space)
            .field("level", &level)
            .field("checksum", &format_args!("0x{:08X}", checksum))
            .field("flags", &format_args!("0x{:08X}", flags))
            .field("generation", &generation)
            .field("node_id", &PageId::from(node_id))
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_header_size() {
        assert_eq!(std::mem::size_of::<NodeHeader>(), HEADER_SIZE);
    }

    #[test]
    fn test_node_type_from_u8() {
        assert_eq!(NodeType::from_u8(1), Some(NodeType::Internal));
        assert_eq!(NodeType::from_u8(2), Some(NodeType::Leaf));
        assert_eq!(NodeType::from_u8(3), Some(NodeType::RootInternal));
        assert_eq!(NodeType::from_u8(4), Some(NodeType::RootLeaf));
        assert_eq!(NodeType::from_u8(99), None);
    }

    #[test]
    fn test_node_type_properties() {
        assert!(NodeType::Internal.is_internal());
        assert!(!NodeType::Internal.is_leaf());
        assert!(!NodeType::Internal.is_root());

        assert!(NodeType::Leaf.is_leaf());
        assert!(!NodeType::Leaf.is_internal());
        assert!(!NodeType::Leaf.is_root());

        assert!(NodeType::RootInternal.is_internal());
        assert!(!NodeType::RootInternal.is_leaf());
        assert!(NodeType::RootInternal.is_root());

        assert!(NodeType::RootLeaf.is_leaf());
        assert!(!NodeType::RootLeaf.is_internal());
        assert!(NodeType::RootLeaf.is_root());
    }

    #[test]
    fn test_header_creation() {
        let page_id = PageId::from(42u64);
        let header = NodeHeader::new(NodeType::Leaf, page_id, 0);

        let magic = header.magic;
        let node_type = header.node_type;
        let is_root = header.is_root;
        let num_keys = header.num_keys;
        let free_space = header.free_space;
        let level = header.level;
        let node_id = header.node_id;

        assert_eq!(magic, NODE_MAGIC);
        assert_eq!(node_type, NodeType::Leaf as u8);
        assert_eq!(is_root, 0);
        assert_eq!(num_keys, 0);
        assert_eq!(free_space as usize, DEFAULT_PAGE_SIZE - HEADER_SIZE);
        assert_eq!(level, 0);
        assert_eq!(node_id, page_id.as_u64());
    }

    #[test]
    fn test_header_validation() {
        let page_id = PageId::from(42u64);
        let mut header = NodeHeader::new(NodeType::Leaf, page_id, 0);

        // Valid header should pass
        assert!(header.validate(page_id).is_ok());

        // Invalid magic should fail
        header.magic = 0xDEADBEEF;
        assert!(header.validate(page_id).is_err());

        // Reset and test node_id mismatch
        header = NodeHeader::new(NodeType::Leaf, page_id, 0);
        header.node_id = 999;
        assert!(header.validate(page_id).is_err());
    }

    #[test]
    fn test_flag_operations() {
        let mut header = NodeHeader::new(NodeType::Leaf, PageId::from(1u64), 0);

        assert!(!header.has_flag(NodeFlags::DIRTY));
        header.set_flag(NodeFlags::DIRTY);
        assert!(header.has_flag(NodeFlags::DIRTY));
        header.clear_flag(NodeFlags::DIRTY);
        assert!(!header.has_flag(NodeFlags::DIRTY));
    }

    #[test]
    fn test_space_checking() {
        let header = NodeHeader::new(NodeType::Leaf, PageId::from(1u64), 0);

        assert!(header.has_space(100));
        assert!(header.has_space(DEFAULT_PAGE_SIZE - HEADER_SIZE));
        assert!(!header.has_space(DEFAULT_PAGE_SIZE - HEADER_SIZE + 1));
    }

    #[test]
    fn test_underfull_checking() {
        let mut header = NodeHeader::new(NodeType::Leaf, PageId::from(1u64), 0);
        header.num_keys = 1;

        // Root nodes are never underfull
        header.is_root = 1;
        assert!(!header.is_underfull(10));

        // Non-root with too few entries
        header.is_root = 0;
        assert!(header.is_underfull(10));
        assert!(!header.is_underfull(1));
    }

    #[test]
    fn test_generation_increment() {
        let mut header = NodeHeader::new(NodeType::Leaf, PageId::from(1u64), 0);
        let initial = header.generation;

        header.increment_generation();
        let generation = header.generation;
        assert_eq!(generation, initial + 1);
    }
}
