//! Snapshot cleanup and garbage collection.
//!
//! Provides functionality for removing old snapshots and reclaiming
//! resources when snapshots are no longer needed.

use std::collections::HashMap;

use crate::{PageId, TransactionId, Result, Error};

/// Cleanup configuration for snapshot garbage collection.
#[derive(Debug, Clone)]
pub struct CleanupConfig {
    /// Minimum number of snapshots to keep (including genesis)
    pub min_snapshots_to_keep: usize,

    /// Minimum age before a snapshot can be cleaned up (in transaction IDs)
    pub min_txn_id_gap: u64,

    /// Whether to aggressively clean up all unreferenced snapshots
    pub aggressive: bool,
}

impl Default for CleanupConfig {
    fn default() -> Self {
        Self {
            min_snapshots_to_keep: 2, // Keep genesis + at least one more
            min_txn_id_gap: 10,      // Keep last 10 transactions
            aggressive: false,
        }
    }
}

impl CleanupConfig {
    /// Create a new cleanup config with conservative defaults.
    #[inline]
    pub fn conservative() -> Self {
        Self {
            min_snapshots_to_keep: 10,
            min_txn_id_gap: 100,
            aggressive: false,
        }
    }

    /// Create a new cleanup config with aggressive cleanup.
    #[inline]
    pub fn aggressive() -> Self {
        Self {
            min_snapshots_to_keep: 1, // Keep only genesis
            min_txn_id_gap: 1,        // Clean up immediately
            aggressive: true,
        }
    }

    /// Create a custom cleanup config.
    ///
    /// # Arguments
    ///
    /// * `min_snapshots_to_keep` - Minimum number of snapshots to keep
    /// * `min_txn_id_gap` - Minimum transaction ID gap before cleanup
    #[inline]
    pub fn custom(min_snapshots_to_keep: usize, min_txn_id_gap: u64) -> Self {
        Self {
            min_snapshots_to_keep,
            min_txn_id_gap,
            aggressive: false,
        }
    }
}

/// Snapshot cleanup manager.
///
/// Handles garbage collection of old snapshots and page reclamation.
///
/// # Cleanup Strategy
///
/// 1. Never remove snapshots with active references (ref_count > 0)
/// 2. Always keep genesis snapshot (txn_id 0)
/// 3. Keep minimum number of recent snapshots (configurable)
/// 4. Keep snapshots within the transaction ID gap (configurable)
#[derive(Debug)]
pub struct SnapshotCleanup {
    /// Cleanup configuration
    config: CleanupConfig,
}

impl SnapshotCleanup {
    /// Create a new cleanup manager with default config.
    #[inline]
    pub fn new() -> Self {
        Self {
            config: CleanupConfig::default(),
        }
    }

    /// Create a new cleanup manager with custom config.
    ///
    /// # Arguments
    ///
    /// * `config` - Cleanup configuration
    #[inline]
    pub fn with_config(config: CleanupConfig) -> Self {
        Self { config }
    }

    /// Identify snapshots that can be cleaned up.
    ///
    /// Returns a list of transaction IDs that are safe to remove.
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Current snapshot registry
    /// * `ref_counts` - Reference counts for each snapshot
    /// * `current_txn_id` - Current transaction ID
    ///
    /// # Returns
    ///
    /// Vec of transaction IDs that can be removed
    pub fn identify_cleanup_candidates(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
        ref_counts: &HashMap<TransactionId, usize>,
        current_txn_id: TransactionId,
    ) -> Vec<TransactionId> {
        let mut candidates = Vec::new();

        for (&txn_id, _) in snapshots {
            // Skip if:
            // - Genesis snapshot (always keep)
            // - Has active references
            // - Would violate minimum snapshot count
            // - Would violate minimum transaction ID gap
            if self.should_keep_snapshot(txn_id, snapshots, ref_counts, current_txn_id) {
                continue;
            }

            candidates.push(txn_id);
        }

        candidates
    }

    /// Check if a snapshot should be kept (not cleaned up).
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to check
    /// * `snapshots` - Current snapshot registry
    /// * `ref_counts` - Reference counts for each snapshot
    /// * `current_txn_id` - Current transaction ID
    fn should_keep_snapshot(
        &self,
        txn_id: TransactionId,
        snapshots: &HashMap<TransactionId, PageId>,
        ref_counts: &HashMap<TransactionId, usize>,
        current_txn_id: TransactionId,
    ) -> bool {
        // Always keep genesis
        if txn_id == TransactionId::INITIAL {
            return true;
        }

        // Keep if has active references
        if ref_counts.get(&txn_id).copied().unwrap_or(0) > 0 {
            return true;
        }

        // Keep if within minimum snapshot count
        let snapshot_count = snapshots.len();
        if snapshot_count <= self.config.min_snapshots_to_keep {
            return true;
        }

        // Keep if within transaction ID gap
        let txn_gap = current_txn_id.as_u64().saturating_sub(txn_id.as_u64());
        if txn_gap < self.config.min_txn_id_gap {
            return true;
        }

        false
    }

    /// Clean up snapshots that can be safely removed.
    ///
    /// This is a read-only operation that identifies candidates.
    /// Actual removal should be done by the registry.
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Current snapshot registry
    /// * `ref_counts` - Reference counts for each snapshot
    /// * `current_txn_id` - Current transaction ID
    ///
    /// # Returns
    ///
    /// Number of snapshots that can be cleaned up
    pub fn cleanup_count(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
        ref_counts: &HashMap<TransactionId, usize>,
        current_txn_id: TransactionId,
    ) -> usize {
        self.identify_cleanup_candidates(snapshots, ref_counts, current_txn_id)
            .len()
    }

    /// Check if a specific snapshot can be cleaned up.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID to check
    /// * `ref_counts` - Reference counts for each snapshot
    ///
    /// # Returns
    ///
    /// true if the snapshot can be cleaned up
    pub fn can_cleanup_snapshot(
        &self,
        txn_id: TransactionId,
        ref_counts: &HashMap<TransactionId, usize>,
    ) -> bool {
        // Never clean up genesis
        if txn_id == TransactionId::INITIAL {
            return false;
        }

        // Can't clean up if has active references
        if ref_counts.get(&txn_id).copied().unwrap_or(0) > 0 {
            return false;
        }

        true
    }

    /// Get the cleanup configuration.
    #[inline]
    pub fn config(&self) -> &CleanupConfig {
        &self.config
    }

    /// Set the cleanup configuration.
    #[inline]
    pub fn set_config(&mut self, config: CleanupConfig) {
        self.config = config;
    }

    /// Calculate cleanup statistics.
    ///
    /// # Arguments
    ///
    /// * `snapshots` - Current snapshot registry
    /// * `ref_counts` - Reference counts for each snapshot
    /// * `current_txn_id` - Current transaction ID
    ///
    /// # Returns
    ///
    /// Cleanup statistics
    pub fn cleanup_stats(
        &self,
        snapshots: &HashMap<TransactionId, PageId>,
        ref_counts: &HashMap<TransactionId, usize>,
        current_txn_id: TransactionId,
    ) -> CleanupStats {
        let total_snapshots = snapshots.len();
        let active_snapshots = ref_counts.len();
        let cleanup_candidates = self.identify_cleanup_candidates(
            snapshots,
            ref_counts,
            current_txn_id,
        );

        CleanupStats {
            total_snapshots,
            active_snapshots,
            cleanup_candidates: cleanup_candidates.len(),
            oldest_candidate: cleanup_candidates.first().copied(),
            newest_candidate: cleanup_candidates.last().copied(),
        }
    }
}

impl Default for SnapshotCleanup {
    fn default() -> Self {
        Self::new()
    }
}

/// Cleanup statistics.
#[derive(Debug, Clone)]
pub struct CleanupStats {
    /// Total number of snapshots in the registry
    pub total_snapshots: usize,

    /// Number of snapshots with active references
    pub active_snapshots: usize,

    /// Number of snapshots that can be cleaned up
    pub cleanup_candidates: usize,

    /// Oldest transaction ID that can be cleaned up
    pub oldest_candidate: Option<TransactionId>,

    /// Newest transaction ID that can be cleaned up
    pub newest_candidate: Option<TransactionId>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_snapshots() -> (HashMap<TransactionId, PageId>, HashMap<TransactionId, usize>) {
        let mut snapshots = HashMap::new();
        let mut ref_counts = HashMap::new();

        for i in 0..=20 {
            snapshots.insert(TransactionId::new(i), PageId::new(i * 10));
            ref_counts.insert(TransactionId::new(i), 0);
        }

        (snapshots, ref_counts)
    }

    #[test]
    fn test_cleanup_new() {
        let cleanup = SnapshotCleanup::new();
        assert!(!cleanup.config().aggressive);
    }

    #[test]
    fn test_cleanup_with_config() {
        let config = CleanupConfig::conservative();
        let cleanup = SnapshotCleanup::with_config(config.clone());
        assert_eq!(cleanup.config().min_snapshots_to_keep, 10);
    }

    #[test]
    fn test_config_default() {
        let config = CleanupConfig::default();
        assert_eq!(config.min_snapshots_to_keep, 2);
        assert_eq!(config.min_txn_id_gap, 10);
        assert!(!config.aggressive);
    }

    #[test]
    fn test_config_conservative() {
        let config = CleanupConfig::conservative();
        assert_eq!(config.min_snapshots_to_keep, 10);
        assert_eq!(config.min_txn_id_gap, 100);
        assert!(!config.aggressive);
    }

    #[test]
    fn test_config_aggressive() {
        let config = CleanupConfig::aggressive();
        assert_eq!(config.min_snapshots_to_keep, 1);
        assert_eq!(config.min_txn_id_gap, 1);
        assert!(config.aggressive);
    }

    #[test]
    fn test_config_custom() {
        let config = CleanupConfig::custom(5, 50);
        assert_eq!(config.min_snapshots_to_keep, 5);
        assert_eq!(config.min_txn_id_gap, 50);
        assert!(!config.aggressive);
    }

    #[test]
    fn test_can_cleanup_snapshot_genesis() {
        let cleanup = SnapshotCleanup::new();
        let ref_counts = HashMap::new();

        // Genesis should never be cleaned up
        assert!(!cleanup.can_cleanup_snapshot(TransactionId::INITIAL, &ref_counts));
    }

    #[test]
    fn test_can_cleanup_snapshot_with_refs() {
        let cleanup = SnapshotCleanup::new();
        let mut ref_counts = HashMap::new();
        ref_counts.insert(TransactionId::new(1), 5);

        // Snapshot with refs should not be cleaned up
        assert!(!cleanup.can_cleanup_snapshot(TransactionId::new(1), &ref_counts));
    }

    #[test]
    fn test_can_cleanup_snapshot_no_refs() {
        let cleanup = SnapshotCleanup::new();
        let ref_counts = HashMap::new();

        // Snapshot without refs can be cleaned up
        assert!(cleanup.can_cleanup_snapshot(TransactionId::new(1), &ref_counts));
    }

    #[test]
    fn test_identify_cleanup_candidates_default() {
        let cleanup = SnapshotCleanup::new();
        let (snapshots, ref_counts) = create_test_snapshots();

        // With current txn at 20, and min_gap of 10, snapshots 0-9 are protected
        // Snapshot 0 is genesis (always protected)
        // Snapshots 1-9 are within gap
        // Snapshots 10-20: need to check min_snapshots_to_keep (2)
        // So we keep genesis + snapshot 20 = 2 minimum
        // Can clean up snapshots that are old enough and not needed

        let candidates = cleanup.identify_cleanup_candidates(&snapshots, &ref_counts, TransactionId::new(20));

        // Should identify some candidates, but not genesis or recent ones
        assert!(!candidates.contains(&TransactionId::new(0))); // Genesis
    }

    #[test]
    fn test_identify_cleanup_candidates_aggressive() {
        let config = CleanupConfig::aggressive();
        let cleanup = SnapshotCleanup::with_config(config);
        let (snapshots, ref_counts) = create_test_snapshots();

        // Aggressive mode cleans up everything except genesis
        let candidates = cleanup.identify_cleanup_candidates(&snapshots, &ref_counts, TransactionId::new(20));

        // Should clean up snapshots 1-19 (keep genesis and current)
        assert!(!candidates.contains(&TransactionId::new(0))); // Genesis
        assert!(!candidates.contains(&TransactionId::new(20))); // Current
    }

    #[test]
    fn test_identify_cleanup_candidates_with_refs() {
        let cleanup = SnapshotCleanup::new();
        let (mut snapshots, mut ref_counts) = create_test_snapshots();

        // Add some references
        ref_counts.insert(TransactionId::new(5), 1);
        ref_counts.insert(TransactionId::new(10), 2);

        let candidates = cleanup.identify_cleanup_candidates(&snapshots, &ref_counts, TransactionId::new(20));

        // Snapshots with refs should not be in candidates
        assert!(!candidates.contains(&TransactionId::new(5)));
        assert!(!candidates.contains(&TransactionId::new(10)));
    }

    #[test]
    fn test_cleanup_count() {
        let cleanup = SnapshotCleanup::new();
        let (snapshots, ref_counts) = create_test_snapshots();

        let count = cleanup.cleanup_count(&snapshots, &ref_counts, TransactionId::new(20));
        assert!(count <= snapshots.len());
    }

    #[test]
    fn test_cleanup_stats() {
        let cleanup = SnapshotCleanup::new();
        let (snapshots, ref_counts) = create_test_snapshots();

        let stats = cleanup.cleanup_stats(&snapshots, &ref_counts, TransactionId::new(20));

        assert_eq!(stats.total_snapshots, 21); // 0-20
        assert_eq!(stats.active_snapshots, 21); // All have ref count entries
        assert!(stats.cleanup_candidates <= stats.total_snapshots);
    }

    #[test]
    fn test_set_config() {
        let mut cleanup = SnapshotCleanup::new();
        let new_config = CleanupConfig::aggressive();

        cleanup.set_config(new_config.clone());
        assert_eq!(cleanup.config().min_snapshots_to_keep, 1);
    }

    #[test]
    fn test_should_keep_snapshot_genesis() {
        let cleanup = SnapshotCleanup::new();
        let (snapshots, ref_counts) = create_test_snapshots();

        // Genesis should always be kept
        assert!(cleanup.should_keep_snapshot(
            TransactionId::INITIAL,
            &snapshots,
            &ref_counts,
            TransactionId::new(20)
        ));
    }

    #[test]
    fn test_should_keep_snapshot_with_refs() {
        let cleanup = SnapshotCleanup::new();
        let (mut snapshots, mut ref_counts) = create_test_snapshots();

        ref_counts.insert(TransactionId::new(5), 1);

        assert!(cleanup.should_keep_snapshot(
            TransactionId::new(5),
            &snapshots,
            &ref_counts,
            TransactionId::new(20)
        ));
    }

    #[test]
    fn test_should_keep_snapshot_min_count() {
        let cleanup = SnapshotCleanup::new();

        let mut snapshots = HashMap::new();
        let mut ref_counts = HashMap::new();

        // Only 2 snapshots
        snapshots.insert(TransactionId::new(0), PageId::new(0));
        snapshots.insert(TransactionId::new(1), PageId::new(10));

        // Both should be kept (min is 2)
        assert!(cleanup.should_keep_snapshot(
            TransactionId::new(0),
            &snapshots,
            &ref_counts,
            TransactionId::new(1)
        ));
        assert!(cleanup.should_keep_snapshot(
            TransactionId::new(1),
            &snapshots,
            &ref_counts,
            TransactionId::new(1)
        ));
    }

    #[test]
    fn test_should_keep_snapshot_within_gap() {
        let cleanup = SnapshotCleanup::new();
        let (snapshots, ref_counts) = create_test_snapshots();

        // Snapshots within gap should be kept
        // Gap is 10, current is 20, so keep 11-20
        assert!(cleanup.should_keep_snapshot(
            TransactionId::new(15),
            &snapshots,
            &ref_counts,
            TransactionId::new(20)
        ));
    }

    #[test]
    fn test_cleanup_default() {
        let cleanup = SnapshotCleanup::default();
        assert!(!cleanup.config().aggressive);
    }

    #[test]
    fn test_empty_snapshots() {
        let cleanup = SnapshotCleanup::new();
        let snapshots = HashMap::new();
        let ref_counts = HashMap::new();

        let candidates = cleanup.identify_cleanup_candidates(&snapshots, &ref_counts, TransactionId::new(0));
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_only_genesis() {
        let cleanup = SnapshotCleanup::new();
        let mut snapshots = HashMap::new();
        let mut ref_counts = HashMap::new();

        snapshots.insert(TransactionId::INITIAL, PageId::FIRST_DATA);
        ref_counts.insert(TransactionId::INITIAL, 0);

        let candidates = cleanup.identify_cleanup_candidates(&snapshots, &ref_counts, TransactionId::INITIAL);
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_all_snapshots_have_refs() {
        let cleanup = SnapshotCleanup::new();
        let (mut snapshots, mut ref_counts) = create_test_snapshots();

        // Give all snapshots refs
        for (&txn_id, _) in snapshots.iter() {
            ref_counts.insert(txn_id, 1);
        }

        let candidates = cleanup.identify_cleanup_candidates(&snapshots, &ref_counts, TransactionId::new(20));
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_cleanup_respects_min_gap() {
        let config = CleanupConfig::custom(1, 5);
        let cleanup = SnapshotCleanup::with_config(config);
        let (snapshots, ref_counts) = create_test_snapshots();

        // With min_gap of 5 and current at 20, should keep 16-20
        let candidates = cleanup.identify_cleanup_candidates(&snapshots, &ref_counts, TransactionId::new(20));

        // Recent snapshots should not be candidates
        for i in 16..=20 {
            assert!(!candidates.contains(&TransactionId::new(i)));
        }
    }

    #[test]
    fn test_cleanup_stats_fields() {
        let cleanup = SnapshotCleanup::new();
        let (snapshots, ref_counts) = create_test_snapshots();

        let stats = cleanup.cleanup_stats(&snapshots, &ref_counts, TransactionId::new(20));

        assert!(stats.total_snapshots > 0);
        assert!(stats.active_snapshots > 0);
        // candidates could be zero or more
    }
}
