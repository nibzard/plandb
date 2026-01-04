//! B+Tree Implementation
//!
//! This module provides the B+Tree index structure for NorthstarDB, implementing
//! ordered key-value storage with MVCC support, efficient range scans, and
//! crash-safe operations through WAL integration.

pub mod header;
pub mod node;
pub mod tree;
pub mod search;
pub mod insert;
pub mod delete;
pub mod merge;
pub mod borrow;
pub mod scan;
pub mod version;
pub mod overflow;

// Re-exports for convenience
pub use header::{NodeHeader, NodeType, NodeFlags};
pub use node::{Node, InternalNode, LeafNode, Entry};
pub use tree::BTree;
pub use search::SearchResult;
pub use scan::ScanIter;
pub use overflow::{OverflowPage, ValueStorage, OVERFLOW_MAGIC, INLINE_THRESHOLD,
                  MAX_VALUE_SIZE, OVERFLOW_DATA_SIZE, OVERFLOW_VALUE_MARKER};
