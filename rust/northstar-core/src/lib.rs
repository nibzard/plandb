//! NorthstarDB Core Database Engine
//!
//! This crate provides the embedded database engine including storage,
//! transactions, MVCC snapshots, and B+tree operations.

#![warn(missing_docs)]
#![warn(clippy::all)]

// Core modules
pub mod error;
pub mod page;
pub mod checksum;
pub mod types;

// Re-exports for convenience
pub use error::{DbError, Error, Result};
pub use page::{Page, PageHeader, PageType};
pub use types::{Lsn, PageId, TransactionId};
