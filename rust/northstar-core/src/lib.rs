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
pub mod pager;
pub mod wal;

// Re-exports for convenience
pub use error::{DbError, Error, Result};
pub use page::{Page, PageHeader, PageType};
pub use types::{Lsn, PageId, TransactionId};
pub use pager::Pager;
pub use wal::Wal;
