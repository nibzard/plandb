//! Snapshot/MVCC module for NorthstarDB.
//!
//! This module provides Multi-Version Concurrency Control (MVCC) through
//! snapshot isolation, enabling many concurrent readers with single-writer
//! semantics.
//!
//! # Architecture
//!
//! The snapshot system consists of:
//! - **Registry**: Central authority managing all snapshots and their root page mappings
//! - **Snapshot**: Handle representing a consistent view of the database at a point in time
//! - **Visibility**: Determines which transactions are visible to a snapshot
//! - **Validation**: Ensures snapshot integrity and detects corruption
//! - **Cleanup**: Garbage collection for old snapshots and page reclaim
//! - **Concurrency**: Thread-safe operations using RwLock
//!
//! # Key Invariants
//!
//! 1. Genesis exists: txn_id 0 always maps to a valid root_page_id
//! 2. Monotonic current: current_txn_id never decreases
//! 3. Consistency: All registered snapshots have valid page IDs
//! 4. Valid page IDs: All root_page_id values >= 2 (first data page)
//! 5. Ordering: Newer snapshots have higher txn_id values
//! 6. No duplicates: No duplicate txn_id entries in the registry
//!
//! # Example
//!
//! ```rust
//! use northstar_core::{Pager, snap::{SnapshotRegistry, SnapshotOps}};
//!
//! # fn example() -> northstar_core::Result<()> {
//! let pager = Pager::create_memory()?;
//! let registry = SnapshotRegistry::new(pager);
//!
//! // Create a new snapshot
//! let snapshot = registry.snapshot()?;
//!
//! // Use snapshot for reads
//! let root_id = snapshot.root_page_id();
//!
//! // Snapshot auto-closes when dropped
//! drop(snapshot);
//! # Ok(())
//! # }
//! ```

mod registry;
mod snapshot;
mod visibility;
mod validation;
mod cleanup;
mod concurrency;

pub use registry::{SnapshotRegistry, SnapshotStats};
pub use snapshot::Snapshot;
pub use snapshot::SnapshotOps;
pub use visibility::{CommitTimestamps, Visibility, current_time_ms};
pub use validation::SnapshotValidator;
pub use cleanup::{SnapshotCleanup, CleanupConfig, CleanupStats};
pub use concurrency::SnapshotConcurrency;

use crate::{Pager, PageId, TransactionId, Result};
