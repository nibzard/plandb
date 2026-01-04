//! Reference Model Implementation
//!
//! This module provides a simple, correct in-memory database implementation
//! serving as an oracle for validating the production database implementation.
//!
//! # Purpose
//!
//! The reference model implements the same logical operations as the production
//! database but with simplified, easy-to-verify code. It serves as:
//! - A correctness oracle for property testing
//! - A source of truth for equivalence validation
//! - A reproducible test environment for fuzz testing
//!
//! # Architecture
//!
//! - In-memory storage using `BTreeMap` (simplified B+Tree)
//! - Single-threaded execution (no concurrency complexity)
//! - Simple snapshot system for historical state access
//! - JSON serialization for reproducible test failures
//!
//! # Modules
//!
//! - `tree`: In-memory B+Tree implementation
//! - `snapshot`: Historical state tracking
//! - `ops`: CRUD operations and transaction management
//! - `compare`: Equivalence checking with production DB
//! - `serialize`: Persistence for fuzz replay

pub mod tree;
pub mod snapshot;
pub mod ops;
pub mod compare;
pub mod serialize;

use crate::types::{Lsn, TransactionId};

use tree::RefTree;
use snapshot::SnapshotRegistry;
use ops::{TransactionManager, PendingTransaction, PendingMutation};

/// Reference model container
///
/// Holds the complete state of the reference database including:
/// - The main B+Tree for key-value storage
/// - Snapshot registry for historical state access
/// - Transaction manager for pending changes
/// - Current LSN for ordering
#[derive(Debug, Clone)]
pub struct RefModel {
    /// In-memory B+Tree storing key-value data
    tree: RefTree,
    /// Snapshot registry for time-travel queries
    snapshots: SnapshotRegistry,
    /// Active and committed transactions
    transactions: TransactionManager,
    /// Current log sequence number
    lsn: Lsn,
}

impl RefModel {
    /// Create a new empty reference model
    pub fn new() -> Self {
        Self {
            tree: RefTree::new(),
            snapshots: SnapshotRegistry::new(),
            transactions: TransactionManager::new(),
            lsn: Lsn::INITIAL,
        }
    }

    /// Get a value by key
    ///
    /// Returns `None` if the key does not exist or has been deleted.
    pub fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.tree.get(key)
    }

    /// Get a value by key at a specific snapshot LSN
    pub fn get_at(&self, key: &[u8], lsn: Lsn) -> Option<Vec<u8>> {
        if let Some(snapshot) = self.snapshots.get_state_at(lsn) {
            snapshot.get(key)
        } else {
            None
        }
    }

    /// Create a new transaction
    pub fn begin_txn(&mut self) -> TransactionId {
        self.transactions.begin_txn(self.lsn)
    }

    /// Insert or update a key-value pair within a transaction
    pub fn put(&mut self, txn_id: TransactionId, key: Vec<u8>, value: Vec<u8>) -> crate::Result<()> {
        self.transactions.put(txn_id, key, value)
    }

    /// Delete a key within a transaction
    pub fn delete(&mut self, txn_id: TransactionId, key: Vec<u8>) -> crate::Result<()> {
        self.transactions.delete(txn_id, key)
    }

    /// Commit a transaction
    ///
    /// Applies all pending changes and advances the LSN.
    pub fn commit(&mut self, txn_id: TransactionId) -> crate::Result<()> {
        let txn = self.transactions.get_txn(txn_id)?;

        // Apply all mutations to the tree
        for mutation in &txn.mutations {
            match mutation {
                PendingMutation::Put { key, value } => {
                    self.tree.put(key.clone(), value.clone(), self.lsn);
                }
                PendingMutation::Delete { key } => {
                    self.tree.delete(key);
                }
            }
        }

        // Advance LSN and mark as committed
        self.lsn = self.lsn.next().unwrap_or(self.lsn);
        self.transactions.commit(txn_id, self.lsn)?;

        Ok(())
    }

    /// Rollback a transaction
    ///
    /// Discards all pending changes.
    pub fn rollback(&mut self, txn_id: TransactionId) -> crate::Result<()> {
        self.transactions.rollback(txn_id)
    }

    /// Create a snapshot of the current state
    pub fn create_snapshot(&mut self) -> Lsn {
        let snapshot_lsn = self.lsn;
        let state = self.tree.clone();
        self.snapshots.add_snapshot(snapshot_lsn, state);
        snapshot_lsn
    }

    /// Get the current LSN
    pub fn current_lsn(&self) -> Lsn {
        self.lsn
    }

    /// Get all keys in the database
    pub fn keys(&self) -> Vec<Vec<u8>> {
        self.tree.keys()
    }

    /// Get the number of keys in the database
    pub fn len(&self) -> usize {
        self.tree.len()
    }

    /// Check if the database is empty
    pub fn is_empty(&self) -> bool {
        self.tree.is_empty()
    }
}

impl Default for RefModel {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_refmodel() {
        let model = RefModel::new();
        assert!(model.is_empty());
        assert_eq!(model.current_lsn(), Lsn::INITIAL);
    }

    #[test]
    fn test_simple_put_get() {
        let mut model = RefModel::new();
        let txn_id = model.begin_txn();

        model.put(txn_id, b"key".to_vec(), b"value".to_vec()).unwrap();
        assert!(model.get(b"key").is_none()); // Not committed yet

        model.commit(txn_id).unwrap();
        assert_eq!(model.get(b"key"), Some(b"value".to_vec()));
    }

    #[test]
    fn test_delete() {
        let mut model = RefModel::new();

        let txn_id = model.begin_txn();
        model.put(txn_id, b"key".to_vec(), b"value".to_vec()).unwrap();
        model.commit(txn_id).unwrap();

        assert_eq!(model.get(b"key"), Some(b"value".to_vec()));

        let txn_id2 = model.begin_txn();
        model.delete(txn_id2, b"key".to_vec()).unwrap();
        model.commit(txn_id2).unwrap();

        assert!(model.get(b"key").is_none());
    }

    #[test]
    fn test_rollback() {
        let mut model = RefModel::new();
        let txn_id = model.begin_txn();

        model.put(txn_id, b"key".to_vec(), b"value".to_vec()).unwrap();
        model.rollback(txn_id).unwrap();

        assert!(model.get(b"key").is_none());
    }

    #[test]
    fn test_snapshot() {
        let mut model = RefModel::new();

        let txn1 = model.begin_txn();
        model.put(txn1, b"key1".to_vec(), b"value1".to_vec()).unwrap();
        model.commit(txn1).unwrap();

        let snap1 = model.create_snapshot();

        let txn2 = model.begin_txn();
        model.put(txn2, b"key2".to_vec(), b"value2".to_vec()).unwrap();
        model.commit(txn2).unwrap();

        // Current state has both keys
        assert_eq!(model.get(b"key1"), Some(b"value1".to_vec()));
        assert_eq!(model.get(b"key2"), Some(b"value2".to_vec()));

        // Snapshot only has key1
        assert_eq!(model.get_at(b"key1", snap1), Some(b"value1".to_vec()));
        assert!(model.get_at(b"key2", snap1).is_none());
    }
}
