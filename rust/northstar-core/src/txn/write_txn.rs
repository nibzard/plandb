//! Write transaction for atomic mutations.
//!
//! WriteTxn provides read-write access with two-phase commit protocol.

use crate::db::Db;
use crate::error::Result;
use crate::types::{TransactionId, Lsn};
use super::context::TransactionContext;

/// Write transaction with two-phase commit protocol.
///
/// Provides atomic mutations with two-phase commit:
/// 1. Prepare phase: write mutations to WAL
/// 2. Commit phase: apply mutations to B+Tree
pub struct WriteTxn<'a> {
    /// Transaction context tracking state and mutations.
    pub ctx: TransactionContext,
    /// Reference to database for operations.
    pub db: &'a Db,
}

impl<'a> WriteTxn<'a> {
    /// Create a new write transaction.
    pub fn new(txn_id: TransactionId, db: &'a Db) -> Self {
        Self {
            ctx: TransactionContext::new(txn_id),
            db,
        }
    }

    /// Get the transaction ID.
    pub const fn txn_id(&self) -> TransactionId {
        self.ctx.txn_id
    }

    /// Check if transaction is active.
    pub const fn is_active(&self) -> bool {
        self.ctx.is_active()
    }

    /// Check if transaction is preparing (commit in progress).
    pub const fn is_preparing(&self) -> bool {
        self.ctx.is_preparing()
    }

    /// Check if transaction is committed.
    pub const fn is_committed(&self) -> bool {
        self.ctx.is_committed()
    }

    /// Check if transaction is aborted.
    pub const fn is_aborted(&self) -> bool {
        self.ctx.is_aborted()
    }

    /// Get a value by key, seeing own writes if applicable.
    ///
    /// Implements read-your-own-writes: checks transaction's mutations first,
    /// then falls back to reading from the committed database state.
    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>> {
        // First check if we have a pending mutation for this key
        if let Some(mutation) = self.ctx.find_mutation(key) {
            // Return the value if it's a Put, None if it's a Delete
            return Ok(mutation.get_value().map(|v| v.to_vec()));
        }

        // Fall back to reading from the database at latest snapshot
        self.db.with_btree(self.db.get_snapshot_root(self.db.current_txn_id()).unwrap_or(crate::PageId::FIRST_DATA), |btree| {
            let snapshot_lsn = crate::types::Lsn::from(self.db.current_txn_id().as_u64());
            btree.get(key, snapshot_lsn)
        })
    }

    /// Insert or update a key-value pair.
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        self.ctx.put(key, value)
    }

    /// Delete a key from the database.
    pub fn delete(&mut self, key: &[u8]) -> Result<()> {
        self.ctx.delete(key)
    }

    /// Get number of mutations in this transaction.
    pub const fn mutation_count(&self) -> usize {
        self.ctx.mutation_count
    }

    /// Check if transaction has any mutations.
    pub const fn has_mutations(&self) -> bool {
        self.ctx.mutation_count > 0
    }

    /// Prepare phase: write mutations to WAL.
    ///
    /// TODO: Implement WAL integration
    pub fn prepare(&mut self) -> Result<()> {
        if !self.ctx.has_mutations() {
            // No-op transaction with no mutations
            return Ok(());
        }

        // Transition to Preparing state
        self.ctx.transition_to_preparing()?;

        // TODO: Write to WAL
        Ok(())
    }

    /// Commit phase: apply mutations to database.
    ///
    /// Applies all buffered mutations to the B+Tree atomically.
    /// After successful commit, a new snapshot is registered.
    pub fn commit(mut self) -> Result<()> {
        // Must be in Preparing state
        if !self.is_preparing() {
            // Try to prepare if not already prepared
            self.prepare()?;
        }

        // If no mutations, just transition to committed
        if !self.ctx.has_mutations() {
            self.ctx.transition_to_committed()?;
            return Ok(());
        }

        // Apply mutations to B+Tree and get new root page ID
        let txn_id = self.txn_id();
        let mutations = std::mem::take(&mut self.ctx.mutations);

        println!("WriteTxn::commit: txn_id={}, mutations={}", txn_id.as_u64(), mutations.len());

        let new_root_page_id = self.db.apply_mutations(|btree| {
            // Apply each mutation with this transaction's LSN
            let lsn = Lsn::from(txn_id.as_u64());

            for mutation in &mutations {
                match mutation {
                    super::Mutation::Put { key, value } => {
                        btree.put(key.clone(), value.clone(), lsn)?;
                    }
                    super::Mutation::Delete { key } => {
                        btree.delete(key, lsn)?;
                    }
                }
            }

            Ok(())
        })?;

        println!("WriteTxn::commit: new_root_page_id={}", new_root_page_id.as_u64());

        // Register new snapshot with updated root page ID
        // This also persists the transaction state to meta pages
        self.db.register_snapshot(txn_id, new_root_page_id)?;

        // Transition to Committed state
        self.ctx.transition_to_committed()?;

        Ok(())
    }

    /// Abort the transaction and rollback changes.
    ///
    /// TODO: Implement rollback with page restoration
    pub fn abort(mut self) {
        // Transition to Aborted state
        let _ = self.ctx.transition_to_aborted();

        // TODO: Free allocated pages, restore modified pages

        // Clear mutations
        self.ctx.clear();
    }

    /// Close the transaction and release resources.
    pub fn close(self) {}
}

// WriteTxn is NOT Send or Sync because:
// - It provides exclusive access for mutations
// - Only one write transaction should exist at a time
// - Sharing or sending would violate these invariants

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_write_txn_creation() {
        // This test requires a Db reference, which we don't have yet
        // For now, we'll skip this test or create a mock Db later
    }

    #[test]
    fn test_write_txn_mutations() {
        // This test requires a Db reference, which we don't have yet
    }
}
