//! Read transaction for consistent snapshot reads.
//!
//! ReadTxn provides read-only access to a consistent snapshot of the database.

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
    pub db: &'a crate::Db,
}

impl<'a> ReadTxn<'a> {
    /// Create a new read transaction at the specified snapshot.
    pub fn new(txn_id: TransactionId, root_page_id: PageId, db: &'a crate::Db) -> Self {
        Self {
            txn_id,
            root_page_id,
            db,
        }
    }

    /// Get a value by key from this snapshot.
    ///
    /// TODO: Implement B+tree lookup
    pub fn get(&self, _key: &[u8]) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }

    /// Scan all keys with the given prefix.
    ///
    /// TODO: Implement prefix scan
    pub fn scan(&self, _prefix: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
        Ok(Vec::new())
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
