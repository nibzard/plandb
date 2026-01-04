//! Visibility calculation for MVCC.
//!
//! Determines which transactions are visible to a snapshot based on
//! commit timestamps and transaction IDs.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{TransactionId, Result, Error};

/// Commit timestamp tracking for transactions.
///
/// Tracks the commit time of each transaction to enable time-based
/// snapshot creation and visibility determination.
#[derive(Debug, Clone)]
pub struct CommitTimestamps {
    /// Mapping from transaction ID to commit timestamp (milliseconds since Unix epoch)
    timestamps: HashMap<TransactionId, u64>,
}

impl CommitTimestamps {
    /// Create a new empty commit timestamp tracker.
    #[inline]
    pub fn new() -> Self {
        Self {
            timestamps: HashMap::new(),
        }
    }

    /// Record the commit timestamp for a transaction.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID that committed
    /// * `timestamp_ms` - Commit timestamp in milliseconds since Unix epoch
    #[inline]
    pub fn record_commit(&mut self, txn_id: TransactionId, timestamp_ms: u64) {
        self.timestamps.insert(txn_id, timestamp_ms);
    }

    /// Record the commit timestamp for a transaction using current time.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID that committed
    #[inline]
    pub fn record_commit_now(&mut self, txn_id: TransactionId) {
        let timestamp_ms = current_time_ms();
        self.timestamps.insert(txn_id, timestamp_ms);
    }

    /// Get the commit timestamp for a transaction.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to look up
    ///
    /// # Returns
    ///
    /// Some(timestamp_ms) if the transaction has committed, None otherwise
    #[inline]
    pub fn get_commit_time(&self, txn_id: TransactionId) -> Option<u64> {
        self.timestamps.get(&txn_id).copied()
    }

    /// Check if a transaction has committed.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to check
    ///
    /// # Returns
    ///
    /// true if the transaction has a recorded commit timestamp
    #[inline]
    pub fn has_committed(&self, txn_id: TransactionId) -> bool {
        self.timestamps.contains_key(&txn_id)
    }

    /// Get the transaction ID at or before a given timestamp.
    ///
    /// Returns the most recent transaction that committed at or before
    /// the specified timestamp.
    ///
    /// # Arguments
    ///
    /// * `timestamp_ms` - Timestamp to search for
    ///
    /// # Returns
    ///
    /// Some(TransactionId) if a transaction is found, None otherwise
    pub fn get_txn_at_or_before(&self, timestamp_ms: u64) -> Option<TransactionId> {
        self.timestamps
            .iter()
            .filter(|(_, &ts)| ts <= timestamp_ms)
            .max_by_key(|(_, &ts)| ts)
            .map(|(&txn_id, _)| txn_id)
    }

    /// Get the transaction ID after a given timestamp.
    ///
    /// Returns the first transaction that committed after the specified
    /// timestamp.
    ///
    /// # Arguments
    ///
    /// * `timestamp_ms` - Timestamp to search from
    ///
    /// # Returns
    ///
    /// Some(TransactionId) if a transaction is found, None otherwise
    pub fn get_txn_after(&self, timestamp_ms: u64) -> Option<TransactionId> {
        self.timestamps
            .iter()
            .filter(|(_, &ts)| ts > timestamp_ms)
            .min_by_key(|(_, &ts)| ts)
            .map(|(&txn_id, _)| txn_id)
    }

    /// Remove timestamp entries for old transactions.
    ///
    /// Removes all timestamps for transactions with IDs less than
    /// the specified threshold.
    ///
    /// # Arguments
    ///
    /// * `min_txn_id` - Minimum transaction ID to keep
    pub fn cleanup_old(&mut self, min_txn_id: TransactionId) {
        self.timestamps.retain(|&txn_id, _| txn_id >= min_txn_id);
    }

    /// Get the number of tracked timestamps.
    #[inline]
    pub fn len(&self) -> usize {
        self.timestamps.len()
    }

    /// Check if no timestamps are tracked.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.timestamps.is_empty()
    }

    /// Clear all timestamps.
    #[inline]
    pub fn clear(&mut self) {
        self.timestamps.clear();
    }
}

impl Default for CommitTimestamps {
    fn default() -> Self {
        Self::new()
    }
}

/// MVCC visibility calculator.
///
/// Determines which transactions and their modifications are visible
/// to a snapshot based on transaction IDs and commit timestamps.
///
/// # Visibility Rules
///
/// 1. A transaction sees its own modifications
/// 2. A transaction sees modifications from committed transactions
///    with transaction ID <= snapshot's transaction ID
/// 3. A transaction does not see modifications from uncommitted transactions
/// 4. A transaction does not see modifications from future transactions
///    (transaction ID > snapshot's transaction ID)
#[derive(Debug, Clone)]
pub struct Visibility {
    /// Commit timestamp tracker for time-based queries
    timestamps: CommitTimestamps,
}

impl Visibility {
    /// Create a new visibility calculator.
    #[inline]
    pub fn new() -> Self {
        Self {
            timestamps: CommitTimestamps::new(),
        }
    }

    /// Create a visibility calculator with a timestamp tracker.
    #[inline]
    pub fn with_timestamps(timestamps: CommitTimestamps) -> Self {
        Self { timestamps }
    }

    /// Check if a transaction is visible to a snapshot.
    ///
    /// A transaction is visible if:
    /// - It has committed (has a timestamp record)
    /// - Its transaction ID <= snapshot's transaction ID
    ///
    /// # Arguments
    ///
    /// * `snapshot_txn_id` - Transaction ID of the snapshot
    /// * `txn_id` - Transaction ID to check visibility for
    ///
    /// # Returns
    ///
    /// true if the transaction is visible to the snapshot
    #[inline]
    pub fn is_txn_visible(
        &self,
        snapshot_txn_id: TransactionId,
        txn_id: TransactionId,
    ) -> bool {
        // Transaction must be committed and not in the future
        txn_id <= snapshot_txn_id && self.timestamps.has_committed(txn_id)
    }

    /// Check if a transaction's write is visible to a snapshot.
    ///
    /// Same as `is_txn_visible` but with a more semantic name for
    /// write operations.
    ///
    /// # Arguments
    ///
    /// * `snapshot_txn_id` - Transaction ID of the snapshot
    /// * `writer_txn_id` - Transaction ID that performed the write
    ///
    /// # Returns
    ///
    /// true if the write is visible to the snapshot
    #[inline]
    pub fn is_write_visible(
        &self,
        snapshot_txn_id: TransactionId,
        writer_txn_id: TransactionId,
    ) -> bool {
        self.is_txn_visible(snapshot_txn_id, writer_txn_id)
    }

    /// Get the snapshot transaction ID for a given time.
    ///
    /// Returns the transaction ID that represents the database state
    /// at the specified timestamp.
    ///
    /// # Arguments
    ///
    /// * `timestamp_ms` - Timestamp in milliseconds since Unix epoch
    ///
    /// # Returns
    ///
    /// Some(TransactionId) if a snapshot exists for that time, None otherwise
    pub fn get_snapshot_at_time(&self, timestamp_ms: u64) -> Option<TransactionId> {
        self.timestamps.get_txn_at_or_before(timestamp_ms)
    }

    /// Record a transaction commit.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID that committed
    /// * `timestamp_ms` - Commit timestamp in milliseconds since Unix epoch
    #[inline]
    pub fn record_commit(&mut self, txn_id: TransactionId, timestamp_ms: u64) {
        self.timestamps.record_commit(txn_id, timestamp_ms);
    }

    /// Record a transaction commit with current time.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID that committed
    #[inline]
    pub fn record_commit_now(&mut self, txn_id: TransactionId) {
        self.timestamps.record_commit_now(txn_id);
    }

    /// Get a reference to the commit timestamps.
    #[inline]
    pub fn timestamps(&self) -> &CommitTimestamps {
        &self.timestamps
    }

    /// Get a mutable reference to the commit timestamps.
    #[inline]
    pub fn timestamps_mut(&mut self) -> &mut CommitTimestamps {
        &mut self.timestamps
    }
}

impl Default for Visibility {
    fn default() -> Self {
        Self::new()
    }
}

/// Get the current time in milliseconds since Unix epoch.
///
/// # Returns
///
/// Current time in milliseconds
#[inline]
pub fn current_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Time went backwards")
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_commit_timestamps_new() {
        let timestamps = CommitTimestamps::new();
        assert!(timestamps.is_empty());
        assert_eq!(timestamps.len(), 0);
    }

    #[test]
    fn test_record_commit() {
        let mut timestamps = CommitTimestamps::new();

        timestamps.record_commit(TransactionId::new(1), 1000);
        assert_eq!(timestamps.len(), 1);
        assert_eq!(timestamps.get_commit_time(TransactionId::new(1)), Some(1000));
        assert!(timestamps.has_committed(TransactionId::new(1)));
        assert!(!timestamps.has_committed(TransactionId::new(2)));
    }

    #[test]
    fn test_record_commit_now() {
        let mut timestamps = CommitTimestamps::new();

        timestamps.record_commit_now(TransactionId::new(1));
        assert!(timestamps.has_committed(TransactionId::new(1)));

        let time = timestamps.get_commit_time(TransactionId::new(1)).unwrap();
        // Should be reasonably recent (within last second)
        let now = current_time_ms();
        assert!(time <= now);
        assert!(time > now - 1000);
    }

    #[test]
    fn test_multiple_commits() {
        let mut timestamps = CommitTimestamps::new();

        timestamps.record_commit(TransactionId::new(1), 1000);
        timestamps.record_commit(TransactionId::new(2), 2000);
        timestamps.record_commit(TransactionId::new(3), 3000);

        assert_eq!(timestamps.len(), 3);
        assert_eq!(timestamps.get_commit_time(TransactionId::new(1)), Some(1000));
        assert_eq!(timestamps.get_commit_time(TransactionId::new(2)), Some(2000));
        assert_eq!(timestamps.get_commit_time(TransactionId::new(3)), Some(3000));
    }

    #[test]
    fn test_get_txn_at_or_before() {
        let mut timestamps = CommitTimestamps::new();

        timestamps.record_commit(TransactionId::new(1), 1000);
        timestamps.record_commit(TransactionId::new(2), 2000);
        timestamps.record_commit(TransactionId::new(3), 3000);

        // Exact match
        assert_eq!(
            timestamps.get_txn_at_or_before(2000),
            Some(TransactionId::new(2))
        );

        // Between transactions
        assert_eq!(
            timestamps.get_txn_at_or_before(2500),
            Some(TransactionId::new(2))
        );

        // Before all transactions
        assert_eq!(timestamps.get_txn_at_or_before(500), None);

        // After all transactions
        assert_eq!(
            timestamps.get_txn_at_or_before(4000),
            Some(TransactionId::new(3))
        );
    }

    #[test]
    fn test_get_txn_after() {
        let mut timestamps = CommitTimestamps::new();

        timestamps.record_commit(TransactionId::new(1), 1000);
        timestamps.record_commit(TransactionId::new(2), 2000);
        timestamps.record_commit(TransactionId::new(3), 3000);

        // Exact match should return next one
        assert_eq!(
            timestamps.get_txn_after(2000),
            Some(TransactionId::new(3))
        );

        // Between transactions
        assert_eq!(
            timestamps.get_txn_after(2500),
            Some(TransactionId::new(3))
        );

        // Before all transactions
        assert_eq!(
            timestamps.get_txn_after(500),
            Some(TransactionId::new(1))
        );

        // After all transactions
        assert_eq!(timestamps.get_txn_after(4000), None);
    }

    #[test]
    fn test_cleanup_old() {
        let mut timestamps = CommitTimestamps::new();

        timestamps.record_commit(TransactionId::new(1), 1000);
        timestamps.record_commit(TransactionId::new(2), 2000);
        timestamps.record_commit(TransactionId::new(3), 3000);
        timestamps.record_commit(TransactionId::new(4), 4000);

        assert_eq!(timestamps.len(), 4);

        // Keep txn 3 and above
        timestamps.cleanup_old(TransactionId::new(3));
        assert_eq!(timestamps.len(), 2);
        assert!(!timestamps.has_committed(TransactionId::new(1)));
        assert!(!timestamps.has_committed(TransactionId::new(2)));
        assert!(timestamps.has_committed(TransactionId::new(3)));
        assert!(timestamps.has_committed(TransactionId::new(4)));
    }

    #[test]
    fn test_clear() {
        let mut timestamps = CommitTimestamps::new();

        timestamps.record_commit(TransactionId::new(1), 1000);
        timestamps.record_commit(TransactionId::new(2), 2000);
        assert_eq!(timestamps.len(), 2);

        timestamps.clear();
        assert!(timestamps.is_empty());
        assert_eq!(timestamps.len(), 0);
    }

    #[test]
    fn test_visibility_new() {
        let visibility = Visibility::new();
        assert_eq!(visibility.timestamps().len(), 0);
    }

    #[test]
    fn test_is_txn_visible() {
        let mut visibility = Visibility::new();

        // Record commits
        visibility.record_commit(TransactionId::new(1), 1000);
        visibility.record_commit(TransactionId::new(2), 2000);
        visibility.record_commit(TransactionId::new(3), 3000);

        // Snapshot at txn 3 should see txn 1, 2, 3
        assert!(visibility.is_txn_visible(TransactionId::new(3), TransactionId::new(1)));
        assert!(visibility.is_txn_visible(TransactionId::new(3), TransactionId::new(2)));
        assert!(visibility.is_txn_visible(TransactionId::new(3), TransactionId::new(3)));

        // Snapshot at txn 2 should see txn 1, 2 but not 3
        assert!(visibility.is_txn_visible(TransactionId::new(2), TransactionId::new(1)));
        assert!(visibility.is_txn_visible(TransactionId::new(2), TransactionId::new(2)));
        assert!(!visibility.is_txn_visible(TransactionId::new(2), TransactionId::new(3)));

        // Snapshot at txn 1 should see only txn 1
        assert!(visibility.is_txn_visible(TransactionId::new(1), TransactionId::new(1)));
        assert!(!visibility.is_txn_visible(TransactionId::new(1), TransactionId::new(2)));
        assert!(!visibility.is_txn_visible(TransactionId::new(1), TransactionId::new(3)));
    }

    #[test]
    fn test_is_txn_visible_uncommitted() {
        let visibility = Visibility::new();

        // No commits recorded
        // Even if txn_id <= snapshot_txn_id, it's not visible if not committed
        assert!(!visibility.is_txn_visible(TransactionId::new(5), TransactionId::new(3)));
    }

    #[test]
    fn test_is_write_visible() {
        let mut visibility = Visibility::new();

        visibility.record_commit(TransactionId::new(1), 1000);
        visibility.record_commit(TransactionId::new(2), 2000);

        // Should behave same as is_txn_visible
        assert!(visibility.is_write_visible(TransactionId::new(2), TransactionId::new(1)));
        assert!(visibility.is_write_visible(TransactionId::new(2), TransactionId::new(2)));
        assert!(!visibility.is_write_visible(TransactionId::new(1), TransactionId::new(2)));
    }

    #[test]
    fn test_get_snapshot_at_time() {
        let mut visibility = Visibility::new();

        visibility.record_commit(TransactionId::new(1), 1000);
        visibility.record_commit(TransactionId::new(2), 2000);
        visibility.record_commit(TransactionId::new(3), 3000);

        // At exact timestamp
        assert_eq!(
            visibility.get_snapshot_at_time(2000),
            Some(TransactionId::new(2))
        );

        // Between timestamps
        assert_eq!(
            visibility.get_snapshot_at_time(2500),
            Some(TransactionId::new(2))
        );

        // Before all
        assert_eq!(visibility.get_snapshot_at_time(500), None);

        // After all
        assert_eq!(
            visibility.get_snapshot_at_time(4000),
            Some(TransactionId::new(3))
        );
    }

    #[test]
    fn test_record_commit_now_visibility() {
        let mut visibility = Visibility::new();

        let before = current_time_ms();
        visibility.record_commit_now(TransactionId::new(1));
        let after = current_time_ms();

        let time = visibility.timestamps().get_commit_time(TransactionId::new(1)).unwrap();
        assert!(time >= before && time <= after);

        // Should be visible to a later snapshot
        assert!(visibility.is_txn_visible(TransactionId::new(1), TransactionId::new(1)));
        assert!(visibility.is_txn_visible(TransactionId::new(2), TransactionId::new(1)));
    }

    #[test]
    fn test_visibility_default() {
        let visibility = Visibility::default();
        assert_eq!(visibility.timestamps().len(), 0);
    }

    #[test]
    fn test_commit_timestamps_default() {
        let timestamps = CommitTimestamps::default();
        assert!(timestamps.is_empty());
    }

    #[test]
    fn test_current_time_ms_reasonable() {
        let time = current_time_ms();
        // Should be a reasonable timestamp (after 2020-01-01)
        assert!(time > 1577836800000);
        // Should be before 2030-01-01
        assert!(time < 1893456000000);
    }

    #[test]
    fn test_timestamps_mut() {
        let mut visibility = Visibility::new();

        visibility.timestamps_mut().record_commit(TransactionId::new(1), 1000);
        assert!(visibility.timestamps().has_committed(TransactionId::new(1)));
    }

    #[test]
    fn test_visibility_with_timestamps() {
        let mut timestamps = CommitTimestamps::new();
        timestamps.record_commit(TransactionId::new(1), 1000);
        timestamps.record_commit(TransactionId::new(2), 2000);

        let visibility = Visibility::with_timestamps(timestamps);

        assert!(visibility.is_txn_visible(TransactionId::new(2), TransactionId::new(1)));
        assert!(visibility.is_txn_visible(TransactionId::new(2), TransactionId::new(2)));
        assert!(!visibility.is_txn_visible(TransactionId::new(1), TransactionId::new(2)));
    }

    #[test]
    fn test_self_visibility() {
        let mut visibility = Visibility::new();

        // Transaction sees its own writes
        visibility.record_commit(TransactionId::new(5), 5000);
        assert!(visibility.is_txn_visible(TransactionId::new(5), TransactionId::new(5)));
    }

    #[test]
    fn test_future_transaction_not_visible() {
        let mut visibility = Visibility::new();

        visibility.record_commit(TransactionId::new(10), 10000);

        // Snapshot at txn 5 should not see txn 10
        assert!(!visibility.is_txn_visible(TransactionId::new(5), TransactionId::new(10)));

        // Snapshot at txn 10 should see txn 10
        assert!(visibility.is_txn_visible(TransactionId::new(10), TransactionId::new(10)));

        // Snapshot at txn 15 should see txn 10
        assert!(visibility.is_txn_visible(TransactionId::new(15), TransactionId::new(10)));
    }

    #[test]
    fn test_visibility_ordering() {
        let mut visibility = Visibility::new();

        // Record commits in order
        for i in 1..=10 {
            visibility.record_commit(TransactionId::new(i), i as u64 * 1000);
        }

        // Snapshot at txn 5 should see txns 1-5
        for i in 1..=5 {
            assert!(
                visibility.is_txn_visible(TransactionId::new(5), TransactionId::new(i)),
                "Txn {} should be visible to snapshot at txn 5",
                i
            );
        }

        // Snapshot at txn 5 should NOT see txns 6-10
        for i in 6..=10 {
            assert!(
                !visibility.is_txn_visible(TransactionId::new(5), TransactionId::new(i)),
                "Txn {} should NOT be visible to snapshot at txn 5",
                i
            );
        }
    }
}
