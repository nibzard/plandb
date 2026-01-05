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
pub mod txn;
pub mod snap;
pub mod btree;
pub mod db;
pub mod refmodel;
pub mod events;
pub mod replication;
pub mod cache;
pub mod analytics;
pub mod query_plan;
pub mod monitoring;
pub mod degradation;
pub mod recovery;
pub mod cloud;
pub mod plugins;
pub mod cartridges;
pub mod autonomous;

// AI Intelligence Layer (feature-gated)
#[cfg(any(feature = "llm-openai", feature = "llm-anthropic", feature = "llm-local"))]
pub mod llm;

#[cfg(any(feature = "llm-openai", feature = "llm-anthropic", feature = "llm-local"))]
pub mod queries;

// Re-exports for convenience
pub use error::{DbError, Error, Result};
pub use page::{Page, PageHeader, PageType};
pub use types::{Lsn, PageId, TransactionId};
pub use pager::Pager;
pub use wal::Wal;
pub use db::Db;
pub use txn::{ReadTxn, WriteTxn};
pub use refmodel::RefModel;

// Replication exports
pub use replication::{
    config::{PrimaryConfig, ReplicaConfig, ReplicationConfig, ReplicationRole},
    error::{ReplicationError, ReplicationResult},
    protocol::{MessageType, ReplicationMessage},
    state::{ConnectionState, ReplicaInfo},
    PROTOCOL_VERSION,
};
