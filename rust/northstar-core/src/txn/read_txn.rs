//! Read transaction for consistent snapshot reads.
//!
//! ReadTxn provides read-only access to a consistent snapshot of the database.

use crate::db::Db;
use crate::error::Result;
use crate::types::{PageId, TransactionId};

/// Read-only transaction providing consistent snapshot reads.
///
/// TODO: This is a placeholder implementation. Full implementation needs:
/// - Snapshot state integration
/// - B+tree read operations
/// - Iterator support
pub struct ReadTxn<'a> {
    /// Transaction identifier for this snapshot.
    pub txn_id: TransactionId,
    /// B+tree root page ID for this snapshot.
    pub root_page_id: PageId,
    /// Reference to database for operations.
    pub db: &'a Db,
}

impl<'a> ReadTxn<'a> {
    /// Create a new read transaction at the specified snapshot.
    pub fn new(txn_id: TransactionId, root_page_id: PageId, db: &'a Db) -> Self {
        Self {
            txn_id,
            root_page_id,
            db,
        }
    }

    /// Get a value by key from this snapshot.
    ///
    /// Performs a B+tree lookup using this transaction's snapshot.
    /// Returns None if the key doesn't exist.
    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>> {
        println!("ReadTxn::get: txn_id={}, root_page_id={}, key={:?}", self.txn_id.as_u64(), self.root_page_id.as_u64(), std::str::from_utf8(key).unwrap_or("<binary>"));
        let result = self.db.with_btree(self.root_page_id, |btree| {
            let snapshot_lsn = crate::types::Lsn::from(self.txn_id.as_u64());
            println!("  snapshot_lsn={}", snapshot_lsn.as_u64());
            btree.get(key, snapshot_lsn)
        })?;
        println!("ReadTxn::get: result={:?}", result.is_some());
        Ok(result)
    }

    /// Scan all keys with the given prefix.
    ///
    /// Returns all key-value pairs where keys start with the prefix.
    pub fn scan(&self, prefix: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
        self.db.with_btree(self.root_page_id, |btree| {
            let snapshot_lsn = crate::types::Lsn::from(self.txn_id.as_u64());

            // Scan from prefix to next possible prefix (prefix + 0xFF...)
            let start = Some(prefix);
            let mut end_prefix = prefix.to_vec();
            end_prefix.push(0xFF);
            let end = Some(end_prefix.as_slice());

            let iter = btree.scan(start, end, snapshot_lsn)?;

            // Collect all items from the iterator
            let mut results = Vec::new();
            for item in iter {
                results.push((item.key, item.value));
            }
            Ok(results)
        })
    }

    /// Close the transaction and release resources.
    pub fn close(self) {}

    /// Check if transaction is still active (not closed).
    pub const fn is_active(&self) -> bool {
        true
    }
}

// SAFETY: ReadTxn can be safely sent between threads
// because all operations are immutable reads.
unsafe impl<'a> Send for ReadTxn<'a> {}

// SAFETY: ReadTxn can be safely shared between threads
// because all operations take &self (immutable reference).
unsafe impl<'a> Sync for ReadTxn<'a> {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_read_txn_creation() {
        // This test requires a Db reference, which we don't have yet
        // For now, we'll skip this test or create a mock Db later
    }
}
