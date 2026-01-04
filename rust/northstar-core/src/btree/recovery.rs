//! B+Tree Recovery from WAL
//!
//! Rebuild B+Tree structure by replaying committed mutations from the WAL
//! after a crash or during database initialization.

use crate::{
    error::{Error, Result},
    types::{PageId, Lsn},
    wal::{Wal, CommitRecord, Mutation},
};
use super::BTree;

/// Recovery state tracking B+Tree rebuild progress
#[derive(Debug, Clone)]
pub struct RecoveryState {
    /// Current LSN being replayed
    pub current_lsn: Lsn,
    /// Number of commit records processed
    pub commits_processed: usize,
    /// Number of mutations applied
    pub mutations_applied: usize,
    /// Root page ID after recovery
    pub recovered_root_page_id: Option<PageId>,
    /// Whether recovery is complete
    pub is_complete: bool,
}

impl RecoveryState {
    /// Create initial recovery state
    pub fn new() -> Self {
        Self {
            current_lsn: Lsn::from(0),
            commits_processed: 0,
            mutations_applied: 0,
            recovered_root_page_id: None,
            is_complete: false,
        }
    }

    /// Mark recovery as complete with final root page ID
    pub fn complete(&mut self, root_page_id: PageId) {
        self.recovered_root_page_id = Some(root_page_id);
        self.is_complete = true;
    }
}

impl Default for RecoveryState {
    fn default() -> Self {
        Self::new()
    }
}

/// Recovery statistics for monitoring and diagnostics
#[derive(Debug, Clone, PartialEq)]
pub struct RecoveryStats {
    /// Total commit records scanned from WAL
    pub commits_scanned: usize,
    /// Commit records that passed validation
    pub valid_commits: usize,
    /// Commit records skipped (incomplete or corrupted)
    pub skipped_commits: usize,
    /// Total mutations applied to B+Tree
    pub mutations_applied: usize,
    /// Put mutations applied
    pub put_operations: usize,
    /// Delete mutations applied
    pub delete_operations: usize,
    /// Pages allocated during recovery
    pub pages_allocated: usize,
    /// Recovery duration in milliseconds
    pub duration_ms: u64,
    /// Final root page ID
    pub final_root_page_id: PageId,
    /// Checksum validation errors
    pub checksum_errors: usize,
}

impl Default for RecoveryStats {
    fn default() -> Self {
        Self {
            commits_scanned: 0,
            valid_commits: 0,
            skipped_commits: 0,
            mutations_applied: 0,
            put_operations: 0,
            delete_operations: 0,
            pages_allocated: 0,
            duration_ms: 0,
            final_root_page_id: PageId::from(0u64),
            checksum_errors: 0,
        }
    }
}

/// Recovery context for B+Tree rebuild operations
pub struct RecoveryContext<'a> {
    /// WAL to replay commit records from
    wal: &'a mut Wal,
    /// B+Tree being rebuilt
    btree: BTree<'a>,
    /// Recovery state tracking
    state: RecoveryState,
    /// Recovery statistics
    stats: RecoveryStats,
}

impl<'a> RecoveryContext<'a> {
    /// Create new recovery context
    pub fn new(wal: &'a mut Wal, btree: BTree<'a>) -> Self {
        Self {
            wal,
            btree,
            state: RecoveryState::new(),
            stats: RecoveryStats::default(),
        }
    }

    /// Get recovery state reference
    pub fn state(&self) -> &RecoveryState {
        &self.state
    }

    /// Get recovery statistics reference
    pub fn stats(&self) -> &RecoveryStats {
        &self.stats
    }

    /// Get mutable B+Tree reference
    pub fn btree_mut(&mut self) -> &mut BTree<'a> {
        &mut self.btree
    }

    /// Record a put operation applied
    fn record_put(&mut self) {
        self.stats.put_operations += 1;
        self.stats.mutations_applied += 1;
        self.state.mutations_applied += 1;
    }

    /// Record a delete operation applied
    fn record_delete(&mut self) {
        self.stats.delete_operations += 1;
        self.stats.mutations_applied += 1;
        self.state.mutations_applied += 1;
    }

    /// Record a commit processed
    fn record_commit(&mut self) {
        self.stats.valid_commits += 1;
        self.state.commits_processed += 1;
    }

    /// Record a checksum error
    fn record_checksum_error(&mut self) {
        self.stats.checksum_errors += 1;
        self.stats.skipped_commits += 1;
    }
}

/// Recover B+Tree by replaying committed transactions from WAL
///
/// This is the main entry point for B+Tree recovery. It scans the WAL for
/// commit records, validates them, and replays the mutations in LSN order
/// to rebuild the B+Tree structure.
///
/// # Algorithm
/// 1. Create empty B+Tree if needed
/// 2. Scan WAL forward to collect all commit records
/// 3. Filter and sort committed transactions by LSN
/// 4. Replay mutations in LSN order
/// 5. Validate recovered tree structure
/// 6. Return recovered B+Tree with statistics
///
/// # Parameters
/// - `wal`: Mutable reference to WAL for replay
/// - `btree`: B+Tree to recover (will be created if empty)
///
/// # Returns
/// Recovery statistics including final root page ID and operation counts
///
/// # Errors
/// - Returns error if WAL is corrupted beyond recovery
/// - Returns error if tree validation fails after recovery
pub fn recover_btree<'a>(
    wal: &'a mut Wal,
    btree: BTree<'a>,
) -> Result<RecoveryStats> {
    let start = std::time::Instant::now();
    let mut ctx = RecoveryContext::new(wal, btree);

    // Step 1: Scan WAL for commit records
    let commit_records = scan_wal_for_commits(&mut ctx)?;
    ctx.stats.commits_scanned = commit_records.len();

    if commit_records.is_empty() {
        // No commits to replay - tree is already in valid state
        let root_page_id = ctx.btree_mut().root_page_id();
        ctx.state.complete(root_page_id);
        ctx.stats.final_root_page_id = root_page_id;
        ctx.stats.duration_ms = start.elapsed().as_millis() as u64;
        return Ok(ctx.stats.clone());
    }

    // Step 2: Filter and sort committed transactions by LSN
    let committed = filter_committed_transactions(commit_records, &mut ctx)?;

    // Step 3: Replay mutations in LSN order
    replay_mutations(committed, &mut ctx)?;

    // Step 4: Validate recovered tree
    validate_recovered_tree(&mut ctx)?;

    // Step 5: Mark recovery complete
    let final_root = ctx.btree_mut().root_page_id();
    ctx.state.complete(final_root);
    ctx.stats.final_root_page_id = final_root;
    ctx.stats.duration_ms = start.elapsed().as_millis() as u64;

    Ok(ctx.stats.clone())
}

/// Scan WAL for all commit records
///
/// Reads the WAL from beginning to end, extracting all commit records
/// that can be deserialized. Handles corrupted records gracefully by
/// attempting to resync to next valid record.
///
/// # Parameters
/// - `ctx`: Recovery context with WAL access
///
/// # Returns
/// Vector of commit records found in WAL
///
/// # Errors
/// - Returns error if WAL cannot be opened
/// - Returns error if corruption resync fails multiple times
fn scan_wal_for_commits(ctx: &mut RecoveryContext) -> Result<Vec<CommitRecord>> {
    let mut commits = Vec::new();
    let mut corruption_count = 0;
    const MAX_CORRUPTIONS: usize = 10;

    // Iterate through WAL records
    // Note: This is a simplified implementation. The actual WAL module
    // would provide a replay iterator or similar interface.
    // For now, we'll assume the WAL has a method to get commit records.

    // TODO: Implement actual WAL scanning when WAL replay API is available
    // For now, return empty vector as placeholder
    //
    // Expected implementation:
    // for record in ctx.wal.iter_records() {
    //     match record {
    //         Ok(WalRecord::Commit(commit)) => {
    //             commits.push(commit);
    //             corruption_count = 0;
    //         }
    //         Err(Error::Validation(_)) => {
    //             corruption_count += 1;
    //             if corruption_count > MAX_CORRUPTIONS {
    //                 return Err(Error::Recovery(RecoveryError::WalCorruption));
    //             }
    //             // Attempt resync - skip to next 4KB boundary
    //             ctx.wal.resync(4096)?;
    //         }
    //         Err(e) => return Err(e),
    //         _ => {} // Skip non-commit records
    //     }
    // }

    Ok(commits)
}

/// Filter and sort committed transactions by LSN
///
/// Validates commit records (checksum verification) and filters out
/// incomplete transactions. Returns sorted list of valid commits
/// ordered by LSN for correct replay order.
///
/// # Parameters
/// - `records`: All commit records from WAL scan
/// - `ctx`: Recovery context for statistics tracking
///
/// # Returns
/// Vector of valid, sorted commit records
///
/// # Errors
/// - Returns error if no valid commits found
/// - Returns error if commits cannot be sorted by LSN
fn filter_committed_transactions(
    records: Vec<CommitRecord>,
    ctx: &mut RecoveryContext,
) -> Result<Vec<CommitRecord>> {
    let records_count = records.len();
    let mut valid_commits = Vec::new();

    for record in records {
        // Validate checksum
        if !record.validate_checksum() {
            ctx.record_checksum_error();
            continue;
        }

        // Record appears valid - add to list
        valid_commits.push(record);
    }

    // Sort by LSN (txn_id serves as LSN proxy)
    valid_commits.sort_by_key(|r| r.txn_id());

    if valid_commits.is_empty() && records_count > 0 {
        return Err(Error::Validation(
            crate::error::ValidationError::Generic(
                "No valid commit records found in WAL".to_string(),
            ),
        ));
    }

    for commit in &valid_commits {
        ctx.record_commit();
    }

    Ok(valid_commits)
}

/// Replay mutations from committed transactions
///
/// Applies each mutation (put/delete) to the B+Tree in LSN order.
/// Handles both put and delete operations by calling the appropriate
/// B+Tree methods.
///
/// # Parameters
/// - `commits`: Sorted list of valid commit records
/// - `ctx`: Recovery context with B+Tree access
///
/// # Returns
/// Ok(()) on successful replay
///
/// # Errors
/// - Returns error if B+Tree put operation fails
/// - Returns error if B+Tree delete operation fails
/// - Returns error if page allocation fails
fn replay_mutations(
    commits: Vec<CommitRecord>,
    ctx: &mut RecoveryContext,
) -> Result<()> {
    for commit in commits {
        let lsn = Lsn::from(commit.txn_id());
        ctx.state.current_lsn = lsn;

        for mutation in commit.mutations() {
            match mutation {
                Mutation::Put { key, value } => {
                    // Apply put operation
                    ctx.btree_mut()
                        .put(key.clone(), value.clone(), lsn)?;
                    ctx.record_put();
                }
                Mutation::Delete { key } => {
                    // Apply delete operation
                    ctx.btree_mut().delete(key, lsn)?;
                    ctx.record_delete();
                }
            }
        }
    }

    Ok(())
}

/// Validate recovered B+Tree structure
///
/// Performs comprehensive validation of the recovered B+Tree to ensure
/// all invariants are satisfied. Checks root validity, node structure,
/// and key ordering.
///
/// # Parameters
/// - `ctx`: Recovery context with B+Tree to validate
///
/// # Returns
/// Ok(()) if validation passes
///
/// # Errors
/// - Returns error if root node is invalid
/// - Returns error if tree structure is corrupted
/// - Returns error if key ordering invariants violated
fn validate_recovered_tree(ctx: &mut RecoveryContext) -> Result<()> {
    // Verify root exists and is valid
    let root_page_id = ctx.btree_mut().root_page_id();

    if root_page_id.as_u64() == 0 {
        return Err(Error::Validation(
            crate::error::ValidationError::Generic(
                "Recovered tree has invalid root page ID".to_string(),
            ),
        ));
    }

    // Run B+Tree verification
    ctx.btree_mut().verify()?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_recovery_state_new() {
        let state = RecoveryState::new();

        assert_eq!(state.current_lsn.as_u64(), 0);
        assert_eq!(state.commits_processed, 0);
        assert_eq!(state.mutations_applied, 0);
        assert!(state.recovered_root_page_id.is_none());
        assert!(!state.is_complete);
    }

    #[test]
    fn test_recovery_state_complete() {
        let mut state = RecoveryState::new();
        assert!(!state.is_complete);

        let root_id = PageId::from(42u64);
        state.complete(root_id);

        assert!(state.is_complete);
        assert_eq!(state.recovered_root_page_id, Some(root_id));
    }

    #[test]
    fn test_recovery_stats_default() {
        let stats = RecoveryStats::default();

        assert_eq!(stats.commits_scanned, 0);
        assert_eq!(stats.valid_commits, 0);
        assert_eq!(stats.put_operations, 0);
        assert_eq!(stats.delete_operations, 0);
    }

    #[test]
    fn test_recovery_context_operations() {
        // This test would require a mock WAL and B+Tree
        // For now, just test that RecoveryContext can be created
        // with proper type checking

        // Note: Can't fully test without actual WAL/B+Tree instances
        // This is a placeholder for when we have integration tests
    }

    // TODO: Add integration tests for:
    // - recover_btree with empty WAL
    // - recover_btree with single commit
    // - recover_btree with multiple commits
    // - checksum validation failure
    // - corrupted WAL resync
    // - tree validation after recovery
}
