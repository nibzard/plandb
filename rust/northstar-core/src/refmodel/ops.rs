//! CRUD Operations and Transaction Management
//!
//! Provides transaction semantics and mutation handling for the reference model.

use crate::{types::TransactionId, Error, Result, error::TransactionError};
use crate::types::Lsn;

/// Pending mutation within a transaction
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PendingMutation {
    /// Insert or update a key-value pair
    Put { key: Vec<u8>, value: Vec<u8> },
    /// Delete a key
    Delete { key: Vec<u8> },
}

impl PendingMutation {
    /// Get the key affected by this mutation
    pub fn key(&self) -> &[u8] {
        match self {
            PendingMutation::Put { key, .. } => key,
            PendingMutation::Delete { key } => key,
        }
    }

    /// Get the value if this is a Put mutation
    pub fn get_value(&self) -> Option<&[u8]> {
        match self {
            PendingMutation::Put { value, .. } => Some(value),
            PendingMutation::Delete { .. } => None,
        }
    }

    /// Check if this mutation affects the given key
    pub fn affects_key(&self, key: &[u8]) -> bool {
        self.key() == key
    }
}

/// Pending transaction state
///
/// Holds all mutations that have been applied within a transaction
/// but not yet committed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingTransaction {
    /// Transaction ID
    pub id: TransactionId,
    /// Pending mutations
    pub mutations: Vec<PendingMutation>,
    /// Start LSN (snapshot LSN for reads)
    pub start_lsn: Lsn,
    /// Whether the transaction is committed
    pub committed: bool,
}

impl PendingTransaction {
    /// Create a new pending transaction
    pub fn new(id: TransactionId, start_lsn: Lsn) -> Self {
        Self {
            id,
            mutations: Vec::new(),
            start_lsn,
            committed: false,
        }
    }

    /// Add a put mutation
    pub fn add_put(&mut self, key: Vec<u8>, value: Vec<u8>) {
        self.mutations.push(PendingMutation::Put { key, value });
    }

    /// Add a delete mutation
    pub fn add_delete(&mut self, key: Vec<u8>) {
        self.mutations.push(PendingMutation::Delete { key });
    }

    /// Get the latest value for a key from pending mutations
    pub fn get_pending(&self, key: &[u8]) -> Option<Option<&[u8]>> {
        self.mutations
            .iter()
            .rev()
            .find(|m| m.affects_key(key))
            .map(|m| m.get_value())
    }

    /// Check if this transaction is active (not committed)
    pub fn is_active(&self) -> bool {
        !self.committed
    }

    /// Get the number of pending mutations
    pub fn len(&self) -> usize {
        self.mutations.len()
    }

    /// Check if there are no pending mutations
    pub fn is_empty(&self) -> bool {
        self.mutations.is_empty()
    }
}

/// Transaction manager
///
/// Manages active and committed transactions for the reference model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransactionManager {
    /// Active transactions
    active_transactions: Vec<PendingTransaction>,
    /// Next transaction ID to allocate
    next_txn_id: TransactionId,
}

impl TransactionManager {
    /// Create a new transaction manager
    pub fn new() -> Self {
        Self {
            active_transactions: Vec::new(),
            next_txn_id: TransactionId::FIRST,
        }
    }

    /// Begin a new transaction
    pub fn begin_txn(&mut self, current_lsn: Lsn) -> TransactionId {
        let txn_id = self.next_txn_id;
        self.next_txn_id = self.next_txn_id.next().unwrap_or(self.next_txn_id);

        let txn = PendingTransaction::new(txn_id, current_lsn);
        self.active_transactions.push(txn);

        txn_id
    }

    /// Get a transaction by ID
    pub fn get_txn(&self, txn_id: TransactionId) -> Result<&PendingTransaction> {
        self.active_transactions
            .iter()
            .find(|t| t.id == txn_id)
            .ok_or_else(|| Error::Transaction(TransactionError::Generic(format!("Transaction {} not found", txn_id.as_u64()))))
    }

    /// Get a mutable transaction by ID
    pub fn get_txn_mut(&mut self, txn_id: TransactionId) -> Result<&mut PendingTransaction> {
        self.active_transactions
            .iter_mut()
            .find(|t| t.id == txn_id)
            .ok_or_else(|| Error::Transaction(TransactionError::Generic(format!("Transaction {} not found", txn_id.as_u64()))))
    }

    /// Put a key-value pair within a transaction
    pub fn put(&mut self, txn_id: TransactionId, key: Vec<u8>, value: Vec<u8>) -> Result<()> {
        let txn = self.get_txn_mut(txn_id)?;
        if txn.committed {
            return Err(Error::Transaction(TransactionError::Generic(format!("Transaction {} already committed", txn_id.as_u64()))));
        }
        txn.add_put(key, value);
        Ok(())
    }

    /// Delete a key within a transaction
    pub fn delete(&mut self, txn_id: TransactionId, key: Vec<u8>) -> Result<()> {
        let txn = self.get_txn_mut(txn_id)?;
        if txn.committed {
            return Err(Error::Transaction(TransactionError::Generic(format!("Transaction {} already committed", txn_id.as_u64()))));
        }
        txn.add_delete(key);
        Ok(())
    }

    /// Commit a transaction
    pub fn commit(&mut self, txn_id: TransactionId, _commit_lsn: Lsn) -> Result<()> {
        let txn = self.get_txn_mut(txn_id)?;
        if txn.committed {
            return Err(Error::Transaction(TransactionError::Generic(format!("Transaction {} already committed", txn_id.as_u64()))));
        }
        txn.committed = true;
        Ok(())
    }

    /// Rollback a transaction
    pub fn rollback(&mut self, txn_id: TransactionId) -> Result<()> {
        let index = self
            .active_transactions
            .iter()
            .position(|t| t.id == txn_id)
            .ok_or_else(|| Error::Transaction(TransactionError::Generic(format!("Transaction {} not found", txn_id.as_u64()))))?;

        let txn = &self.active_transactions[index];
        if txn.committed {
            return Err(Error::Transaction(TransactionError::Generic(format!("Transaction {} already committed", txn_id.as_u64()))));
        }

        self.active_transactions.remove(index);
        Ok(())
    }

    /// Clean up committed transactions
    pub fn cleanup(&mut self) {
        self.active_transactions
            .retain(|t| !t.committed);
    }

    /// Get the number of active transactions
    pub fn active_count(&self) -> usize {
        self.active_transactions.iter().filter(|t| t.is_active()).count()
    }

    /// Get all active transaction IDs
    pub fn active_txn_ids(&self) -> Vec<TransactionId> {
        self.active_transactions
            .iter()
            .filter(|t| t.is_active())
            .map(|t| t.id)
            .collect()
    }
}

impl Default for TransactionManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_transaction_manager_new() {
        let mgr = TransactionManager::new();
        assert_eq!(mgr.active_count(), 0);
    }

    #[test]
    fn test_begin_txn() {
        let mut mgr = TransactionManager::new();
        let txn_id = mgr.begin_txn(Lsn::INITIAL);

        assert_eq!(txn_id, TransactionId::FIRST);
        assert_eq!(mgr.active_count(), 1);
    }

    #[test]
    fn test_put_get() {
        let mut mgr = TransactionManager::new();
        let txn_id = mgr.begin_txn(Lsn::INITIAL);

        mgr.put(txn_id, b"key".to_vec(), b"value".to_vec())
            .unwrap();

        let txn = mgr.get_txn(txn_id).unwrap();
        assert_eq!(txn.len(), 1);
        assert_eq!(txn.get_pending(b"key"), Some(Some(b"value".as_slice())));
    }

    #[test]
    fn test_delete() {
        let mut mgr = TransactionManager::new();
        let txn_id = mgr.begin_txn(Lsn::INITIAL);

        mgr.delete(txn_id, b"key".to_vec()).unwrap();

        let txn = mgr.get_txn(txn_id).unwrap();
        assert_eq!(txn.len(), 1);
        assert_eq!(txn.get_pending(b"key"), Some(None));
    }

    #[test]
    fn test_commit() {
        let mut mgr = TransactionManager::new();
        let txn_id = mgr.begin_txn(Lsn::INITIAL);

        mgr.put(txn_id, b"key".to_vec(), b"value".to_vec())
            .unwrap();
        mgr.commit(txn_id, Lsn::from(1)).unwrap();

        let txn = mgr.get_txn(txn_id).unwrap();
        assert!(txn.committed);
    }

    #[test]
    fn test_commit_twice_fails() {
        let mut mgr = TransactionManager::new();
        let txn_id = mgr.begin_txn(Lsn::INITIAL);

        mgr.commit(txn_id, Lsn::from(1)).unwrap();

        let result = mgr.commit(txn_id, Lsn::from(2));
        assert!(result.is_err());
    }

    #[test]
    fn test_rollback() {
        let mut mgr = TransactionManager::new();
        let txn_id = mgr.begin_txn(Lsn::INITIAL);

        mgr.put(txn_id, b"key".to_vec(), b"value".to_vec())
            .unwrap();
        assert_eq!(mgr.active_count(), 1);

        mgr.rollback(txn_id).unwrap();
        assert_eq!(mgr.active_count(), 0);
    }

    #[test]
    fn test_rollback_committed_fails() {
        let mut mgr = TransactionManager::new();
        let txn_id = mgr.begin_txn(Lsn::INITIAL);

        mgr.commit(txn_id, Lsn::from(1)).unwrap();

        let result = mgr.rollback(txn_id);
        assert!(result.is_err());
    }

    #[test]
    fn test_get_txn_not_found() {
        let mgr = TransactionManager::new();
        let result = mgr.get_txn(TransactionId::from(999));
        assert!(matches!(result, Err(Error::Transaction(_))));
    }

    #[test]
    fn test_cleanup() {
        let mut mgr = TransactionManager::new();
        let txn1 = mgr.begin_txn(Lsn::INITIAL);
        let txn2 = mgr.begin_txn(Lsn::INITIAL);

        mgr.commit(txn1, Lsn::from(1)).unwrap();

        mgr.cleanup();

        assert_eq!(mgr.active_count(), 1);
        assert!(mgr.get_txn(txn1).is_err());
        assert!(mgr.get_txn(txn2).is_ok());
    }

    #[test]
    fn test_active_txn_ids() {
        let mut mgr = TransactionManager::new();
        let txn1 = mgr.begin_txn(Lsn::INITIAL);
        let txn2 = mgr.begin_txn(Lsn::INITIAL);

        mgr.commit(txn2, Lsn::from(1)).unwrap();

        let ids = mgr.active_txn_ids();
        assert_eq!(ids.len(), 1);
        assert_eq!(ids[0], txn1);
    }

    #[test]
    fn test_pending_mutation_key() {
        let put = PendingMutation::Put {
            key: b"test".to_vec(),
            value: b"value".to_vec(),
        };
        assert_eq!(put.key(), b"test");

        let delete = PendingMutation::Delete {
            key: b"test".to_vec(),
        };
        assert_eq!(delete.key(), b"test");
    }

    #[test]
    fn test_pending_mutation_affects_key() {
        let put = PendingMutation::Put {
            key: b"test".to_vec(),
            value: b"value".to_vec(),
        };
        assert!(put.affects_key(b"test"));
        assert!(!put.affects_key(b"other"));
    }

    #[test]
    fn test_pending_transaction_new() {
        let txn = PendingTransaction::new(TransactionId::from(1), Lsn::INITIAL);
        assert_eq!(txn.id, TransactionId::from(1));
        assert!(txn.is_active());
        assert!(txn.is_empty());
    }

    #[test]
    fn test_pending_transaction_add_put() {
        let mut txn = PendingTransaction::new(TransactionId::from(1), Lsn::INITIAL);
        txn.add_put(b"key".to_vec(), b"value".to_vec());
        assert_eq!(txn.len(), 1);
    }

    #[test]
    fn test_pending_transaction_get_pending() {
        let mut txn = PendingTransaction::new(TransactionId::from(1), Lsn::INITIAL);
        assert_eq!(txn.get_pending(b"key"), None);

        txn.add_put(b"key".to_vec(), b"value".to_vec());
        assert_eq!(txn.get_pending(b"key"), Some(Some(b"value".as_slice())));

        txn.add_delete(b"key".to_vec());
        assert_eq!(txn.get_pending(b"key"), Some(None));
    }

    #[test]
    fn test_sequential_txn_ids() {
        let mut mgr = TransactionManager::new();
        let txn1 = mgr.begin_txn(Lsn::INITIAL);
        let txn2 = mgr.begin_txn(Lsn::INITIAL);
        let txn3 = mgr.begin_txn(Lsn::INITIAL);

        assert_eq!(txn1, TransactionId::from(1));
        assert_eq!(txn2, TransactionId::from(2));
        assert_eq!(txn3, TransactionId::from(3));
    }
}
