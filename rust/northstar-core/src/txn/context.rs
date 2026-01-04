//! Transaction context for tracking transaction state.
//!
//! TransactionContext tracks all information for an active transaction
//! including mutations, page tracking, and lifecycle state.

use std::collections::HashMap;
use std::time::SystemTime;

use crate::error::{Result, SizeLimitError, ValidationError};
use crate::types::{PageId, TransactionId, Lsn};
use super::state::TransactionState;
use super::Mutation;
use super::{MAX_KEY_SIZE, MAX_OPERATIONS_PER_COMMIT, MAX_VALUE_SIZE};

/// Context for tracking transaction state and mutations.
pub struct TransactionContext {
    /// Unique transaction identifier.
    pub txn_id: TransactionId,
    /// Parent transaction ID (always 0 in V0, no nesting).
    pub parent_txn_id: TransactionId,
    /// Current state in transaction lifecycle.
    pub state: TransactionState,
    /// Ordered list of all mutations in this transaction.
    pub mutations: Vec<Mutation>,
    /// Number of mutations (cached for performance).
    pub mutation_count: usize,
    /// Pages allocated during this transaction.
    pub allocated_pages: Vec<PageId>,
    /// Before-images of modified pages for rollback.
    pub modified_pages: HashMap<PageId, Vec<u8>>,
    /// Transaction start timestamp (nanoseconds).
    pub start_timestamp_ns: u64,
    /// WAL position where commit record was written.
    pub commit_lsn: Option<Lsn>,
}

impl TransactionContext {
    /// Create a new transaction context in Active state.
    pub fn new(txn_id: TransactionId) -> Self {
        Self {
            txn_id,
            parent_txn_id: TransactionId::INITIAL,
            state: TransactionState::Active,
            mutations: Vec::new(),
            mutation_count: 0,
            allocated_pages: Vec::new(),
            modified_pages: HashMap::new(),
            start_timestamp_ns: Self::current_timestamp_ns(),
            commit_lsn: None,
        }
    }

    /// Get current timestamp in nanoseconds.
    fn current_timestamp_ns() -> u64 {
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0)
    }

    /// Check if transaction is in Active state.
    pub const fn is_active(&self) -> bool {
        self.state.is_active()
    }

    /// Check if transaction is in Preparing state.
    pub const fn is_preparing(&self) -> bool {
        self.state.is_preparing()
    }

    /// Check if transaction is in Committed state.
    pub const fn is_committed(&self) -> bool {
        self.state.is_committed()
    }

    /// Check if transaction is in Aborted state.
    pub const fn is_aborted(&self) -> bool {
        self.state.is_aborted()
    }

    /// Add a Put mutation to the transaction.
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        // Check state
        self.state.validate_mutation()?;

        // Check mutation limit
        if self.mutation_count >= MAX_OPERATIONS_PER_COMMIT {
            return Err(ValidationError::Generic(format!(
                "Too many mutations: {} (max: {})",
                self.mutation_count,
                MAX_OPERATIONS_PER_COMMIT
            ))
            .into());
        }

        // Validate key
        if key.is_empty() {
            return Err(ValidationError::Generic("Key cannot be empty".to_string()).into());
        }

        if key.len() > MAX_KEY_SIZE {
            return Err(SizeLimitError::KeyTooLarge {
                size: key.len(),
                max: MAX_KEY_SIZE,
            }
            .into());
        }

        // Validate value
        if value.len() > MAX_VALUE_SIZE {
            return Err(SizeLimitError::ValueTooLarge {
                size: value.len(),
                max: MAX_VALUE_SIZE,
            }
            .into());
        }

        // Add mutation
        self.mutations.push(Mutation::put(key.to_vec(), value.to_vec()));
        self.mutation_count += 1;

        Ok(())
    }

    /// Add a Delete mutation to the transaction.
    pub fn delete(&mut self, key: &[u8]) -> Result<()> {
        // Check state
        self.state.validate_mutation()?;

        // Check mutation limit
        if self.mutation_count >= MAX_OPERATIONS_PER_COMMIT {
            return Err(ValidationError::Generic(format!(
                "Too many mutations: {} (max: {})",
                self.mutation_count,
                MAX_OPERATIONS_PER_COMMIT
            ))
            .into());
        }

        // Validate key
        if key.is_empty() {
            return Err(ValidationError::Generic("Key cannot be empty".to_string()).into());
        }

        if key.len() > MAX_KEY_SIZE {
            return Err(SizeLimitError::KeyTooLarge {
                size: key.len(),
                max: MAX_KEY_SIZE,
            }
            .into());
        }

        // Add mutation
        self.mutations.push(Mutation::delete(key.to_vec()));
        self.mutation_count += 1;

        Ok(())
    }

    /// Track a page allocated during this transaction.
    pub fn track_allocated_page(&mut self, page_id: PageId) {
        self.allocated_pages.push(page_id);
    }

    /// Store a before-image of a modified page.
    pub fn track_modified_page(&mut self, page_id: PageId, before_image: Vec<u8>) {
        self.modified_pages.insert(page_id, before_image);
    }

    /// Get number of mutations in transaction.
    pub const fn mutation_count(&self) -> usize {
        self.mutation_count
    }

    /// Check if transaction has any mutations.
    pub const fn has_mutations(&self) -> bool {
        self.mutation_count > 0
    }

    /// Get total size of all mutations in bytes.
    pub fn total_mutation_size(&self) -> usize {
        self.mutations.iter().map(|m| m.size()).sum()
    }

    /// Transition to Preparing state.
    pub fn transition_to_preparing(&mut self) -> Result<()> {
        self.state.transition_to_preparing()
    }

    /// Transition to Committed state.
    pub fn transition_to_committed(&mut self) -> Result<()> {
        self.state.transition_to_committed()
    }

    /// Transition to Aborted state.
    pub fn transition_to_aborted(&mut self) -> Result<()> {
        self.state.transition_to_aborted()
    }

    /// Clear all mutations and page tracking (for rollback).
    pub fn clear(&mut self) {
        self.mutations.clear();
        self.mutation_count = 0;
        self.allocated_pages.clear();
        self.modified_pages.clear();
    }

    /// Get transaction duration in nanoseconds.
    pub fn duration_ns(&self) -> u64 {
        let now = Self::current_timestamp_ns();
        now.saturating_sub(self.start_timestamp_ns)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_context_creation() {
        let ctx = TransactionContext::new(TransactionId::new(1));

        assert_eq!(ctx.txn_id.as_u64(), 1);
        assert!(ctx.is_active());
        assert!(!ctx.is_preparing());
        assert!(!ctx.is_committed());
        assert!(!ctx.is_aborted());
        assert!(!ctx.has_mutations());
        assert_eq!(ctx.mutation_count(), 0);
    }

    #[test]
    fn test_put_mutation() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));

        assert!(ctx.put(b"key", b"value").is_ok());
        assert!(ctx.has_mutations());
        assert_eq!(ctx.mutation_count(), 1);
        assert_eq!(ctx.total_mutation_size(), 8); // 3 + 5
    }

    #[test]
    fn test_delete_mutation() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));

        assert!(ctx.delete(b"key").is_ok());
        assert!(ctx.has_mutations());
        assert_eq!(ctx.mutation_count(), 1);
    }

    #[test]
    fn test_empty_key_rejected() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));

        assert!(ctx.put(b"", b"value").is_err());
        assert!(ctx.delete(b"").is_err());
    }

    #[test]
    fn test_key_too_large() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));
        let large_key = vec![0u8; MAX_KEY_SIZE + 1];

        assert!(ctx.put(&large_key, b"value").is_err());
        assert!(ctx.delete(&large_key).is_err());
    }

    #[test]
    fn test_value_too_large() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));
        let large_value = vec![0u8; MAX_VALUE_SIZE + 1];

        assert!(ctx.put(b"key", &large_value).is_err());
    }

    #[test]
    fn test_mutation_limit() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));

        for _ in 0..MAX_OPERATIONS_PER_COMMIT {
            assert!(ctx.put(b"key", b"value").is_ok());
        }

        // One more should fail
        assert!(ctx.put(b"key", b"value").is_err());
    }

    #[test]
    fn test_page_tracking() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));

        ctx.track_allocated_page(PageId::new(10));
        ctx.track_allocated_page(PageId::new(11));

        assert_eq!(ctx.allocated_pages.len(), 2);
        assert_eq!(ctx.allocated_pages[0], PageId::new(10));
        assert_eq!(ctx.allocated_pages[1], PageId::new(11));
    }

    #[test]
    fn test_modified_page_tracking() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));
        let before_image = vec![0u8; 4096];

        ctx.track_modified_page(PageId::new(10), before_image.clone());

        assert_eq!(ctx.modified_pages.len(), 1);
        assert_eq!(ctx.modified_pages.get(&PageId::new(10)), Some(&before_image));
    }

    #[test]
    fn test_state_transitions() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));

        // Active -> Preparing
        assert!(ctx.transition_to_preparing().is_ok());
        assert!(ctx.is_preparing());

        // Preparing -> Committed
        assert!(ctx.transition_to_committed().is_ok());
        assert!(ctx.is_committed());

        // Cannot transition from terminal state
        assert!(ctx.transition_to_aborted().is_err());
    }

    #[test]
    fn test_abort() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));

        assert!(ctx.put(b"key", b"value").is_ok());
        assert!(ctx.has_mutations());

        assert!(ctx.transition_to_aborted().is_ok());
        assert!(ctx.is_aborted());

        // Clear mutations after abort
        ctx.clear();
        assert!(!ctx.has_mutations());
    }

    #[test]
    fn test_no_mutations_after_prepare() {
        let mut ctx = TransactionContext::new(TransactionId::new(1));

        assert!(ctx.transition_to_preparing().is_ok());

        // Cannot add mutations after prepare
        assert!(ctx.put(b"key", b"value").is_err());
        assert!(ctx.delete(b"key").is_err());
    }

    #[test]
    fn test_duration() {
        let ctx = TransactionContext::new(TransactionId::new(1));

        std::thread::sleep(std::time::Duration::from_millis(10));
        let duration = ctx.duration_ns();

        assert!(duration >= 10_000_000); // At least 10ms
    }
}
