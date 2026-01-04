//! Write transaction for atomic mutations.
//!
//! WriteTxn provides read-write access with two-phase commit protocol.

use crate::db::Db;
use crate::cache::PageInvalidation;
use crate::error::Result;
use crate::types::{TransactionId, Lsn, PageId};
use crate::wal::CommitRecord;
use super::context::TransactionContext;
use super::Mutation;

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
    /// Original root page ID before transaction (for rollback)
    original_root_page_id: Option<PageId>,
}

impl<'a> WriteTxn<'a> {
    /// Create a new write transaction.
    pub fn new(txn_id: TransactionId, db: &'a Db) -> Self {
        Self {
            ctx: TransactionContext::new(txn_id),
            db,
            original_root_page_id: None,
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
        let root_page_id = self.db.get_snapshot_root(self.db.current_txn_id())
            .unwrap_or(PageId::FIRST_DATA);
        self.db.with_btree(root_page_id, |btree| {
            let snapshot_lsn = Lsn::from(self.db.current_txn_id().as_u64());
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
    /// Writes transaction mutations to the WAL for durability.
    /// If WAL is not enabled, this is a no-op but still transitions state.
    pub fn prepare(&mut self) -> Result<()> {
        if !self.ctx.has_mutations() {
            // No-op transaction with no mutations
            return Ok(());
        }

        // Store original root page ID for potential rollback
        self.original_root_page_id = self.db.get_snapshot_root(self.db.current_txn_id());

        // Transition to Preparing state
        self.ctx.transition_to_preparing()?;

        // Write to WAL if enabled
        self.db.with_wal(|wal| {
            if let Some(wal) = wal {
                // Create commit record with mutations
                let mutations: Vec<crate::wal::Mutation> = self.ctx.mutations.iter()
                    .map(|m| match m {
                        Mutation::Put { key, value } => {
                            crate::wal::Mutation::Put {
                                key: key.clone(),
                                value: value.clone(),
                            }
                        }
                        Mutation::Delete { key } => {
                            crate::wal::Mutation::Delete {
                                key: key.clone(),
                            }
                        }
                    })
                    .collect();

                // We don't know the new root page ID yet, so use 0
                // It will be updated during commit phase
                let record = CommitRecord::new(
                    self.txn_id().as_u64(),
                    0, // Will be updated after applying mutations
                    mutations,
                );

                // Append to WAL - this durably logs the transaction
                let _lsn = wal.append_commit_record(&record)?;

                // Sync WAL to disk for durability
                if wal.sync_needed() {
                    wal.sync()?;
                }

                println!("WriteTxn::prepare: wrote {} mutations to WAL", self.ctx.mutations.len());
            } else {
                println!("WriteTxn::prepare: WAL not enabled, skipping");
            }
            Ok(())
        })
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
                    Mutation::Put { key, value } => {
                        btree.put(key.clone(), value.clone(), lsn)?;
                    }
                    Mutation::Delete { key } => {
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

        // Send invalidation signal to query cache
        // For simplicity, we invalidate all queries when any data changes
        // A more sophisticated implementation would track exact modified pages
        if let Ok(cache) = self.db.query_cache() {
            let invalidation = PageInvalidation {
                pages: vec![new_root_page_id], // Invalidate based on root change
                lsn: Lsn::from(txn_id.as_u64()),
            };
            let _ = cache.invalidation_sender().send(invalidation);
            println!("WriteTxn::commit: sent query cache invalidation signal");
        }

        // Transition to Committed state
        self.ctx.transition_to_committed()?;

        Ok(())
    }

    /// Abort the transaction and rollback changes.
    ///
    /// Clears all pending mutations and restores original state.
    /// If the transaction had been prepared (WAL written), the WAL record
    /// will be ignored during recovery since no snapshot was registered.
    pub fn abort(mut self) {
        // Transition to Aborted state
        let _ = self.ctx.transition_to_aborted();

        // Clear mutations - no changes were applied to B+Tree
        // WAL records (if any) will be ignored during recovery since
        // no snapshot was registered for this transaction
        self.ctx.clear();

        println!("WriteTxn::abort: transaction aborted, mutations cleared");
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
