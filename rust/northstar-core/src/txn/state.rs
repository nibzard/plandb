//! Transaction state machine.
//!
//! Defines the states a transaction can be in during its lifecycle
//! and enforces valid state transitions.

use crate::error::{Error, Result, ValidationError};
use serde::{Deserialize, Serialize};

/// Transaction lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransactionState {
    /// Transaction is active and accepting mutations.
    Active,
    /// Transaction is in commit process (WAL written, applying to database).
    Preparing,
    /// Transaction successfully committed (terminal state).
    Committed,
    /// Transaction was rolled back (terminal state).
    Aborted,
}

impl TransactionState {
    /// Check if this state allows mutations.
    pub const fn allows_mutations(&self) -> bool {
        matches!(self, Self::Active)
    }

    /// Check if this state allows prepare.
    pub const fn allows_prepare(&self) -> bool {
        matches!(self, Self::Active)
    }

    /// Check if this state allows commit.
    pub const fn allows_commit(&self) -> bool {
        matches!(self, Self::Preparing)
    }

    /// Check if this state allows abort.
    pub const fn allows_abort(&self) -> bool {
        matches!(self, Self::Active | Self::Preparing)
    }

    /// Check if this is a terminal state (no transitions out).
    pub const fn is_terminal(&self) -> bool {
        matches!(self, Self::Committed | Self::Aborted)
    }

    /// Check if transaction is active.
    pub const fn is_active(&self) -> bool {
        matches!(self, Self::Active)
    }

    /// Check if transaction is preparing.
    pub const fn is_preparing(&self) -> bool {
        matches!(self, Self::Preparing)
    }

    /// Check if transaction is committed.
    pub const fn is_committed(&self) -> bool {
        matches!(self, Self::Committed)
    }

    /// Check if transaction is aborted.
    pub const fn is_aborted(&self) -> bool {
        matches!(self, Self::Aborted)
    }

    /// Validate that a mutation operation is allowed in this state.
    pub fn validate_mutation(&self) -> Result<()> {
        if !self.allows_mutations() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Cannot mutate in {:?} state",
                self
            ))));
        }
        Ok(())
    }

    /// Validate that prepare is allowed in this state.
    pub fn validate_prepare(&self) -> Result<()> {
        if !self.allows_prepare() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Cannot prepare in {:?} state",
                self
            ))));
        }
        Ok(())
    }

    /// Validate that commit is allowed in this state.
    pub fn validate_commit(&self) -> Result<()> {
        if !self.allows_commit() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Cannot commit in {:?} state",
                self
            ))));
        }
        Ok(())
    }

    /// Validate that abort is allowed in this state.
    pub fn validate_abort(&self) -> Result<()> {
        if !self.allows_abort() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Cannot abort in {:?} state",
                self
            ))));
        }
        Ok(())
    }

    /// Transition to Preparing state.
    pub fn transition_to_preparing(&mut self) -> Result<()> {
        self.validate_prepare()?;
        *self = Self::Preparing;
        Ok(())
    }

    /// Transition to Committed state.
    pub fn transition_to_committed(&mut self) -> Result<()> {
        self.validate_commit()?;
        *self = Self::Committed;
        Ok(())
    }

    /// Transition to Aborted state.
    pub fn transition_to_aborted(&mut self) -> Result<()> {
        self.validate_abort()?;
        *self = Self::Aborted;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_state_active() {
        let state = TransactionState::Active;
        assert!(state.allows_mutations());
        assert!(state.allows_prepare());
        assert!(!state.allows_commit());
        assert!(state.allows_abort());
        assert!(!state.is_terminal());
        assert!(state.is_active());
    }

    #[test]
    fn test_state_preparing() {
        let state = TransactionState::Preparing;
        assert!(!state.allows_mutations());
        assert!(!state.allows_prepare());
        assert!(state.allows_commit());
        assert!(state.allows_abort());
        assert!(!state.is_terminal());
        assert!(state.is_preparing());
    }

    #[test]
    fn test_state_committed() {
        let state = TransactionState::Committed;
        assert!(!state.allows_mutations());
        assert!(!state.allows_prepare());
        assert!(!state.allows_commit());
        assert!(!state.allows_abort());
        assert!(state.is_terminal());
        assert!(state.is_committed());
    }

    #[test]
    fn test_state_aborted() {
        let state = TransactionState::Aborted;
        assert!(!state.allows_mutations());
        assert!(!state.allows_prepare());
        assert!(!state.allows_commit());
        assert!(!state.allows_abort());
        assert!(state.is_terminal());
        assert!(state.is_aborted());
    }

    #[test]
    fn test_state_transitions() {
        let mut state = TransactionState::Active;

        // Active -> Preparing
        assert!(state.transition_to_preparing().is_ok());
        assert_eq!(state, TransactionState::Preparing);

        // Preparing -> Committed
        assert!(state.transition_to_committed().is_ok());
        assert_eq!(state, TransactionState::Committed);

        // Cannot transition from terminal state
        assert!(state.transition_to_preparing().is_err());
        assert!(state.transition_to_aborted().is_err());
    }

    #[test]
    fn test_state_abort() {
        let mut state = TransactionState::Active;
        assert!(state.transition_to_aborted().is_ok());
        assert_eq!(state, TransactionState::Aborted);

        // Cannot transition from terminal state
        assert!(state.transition_to_aborted().is_err());
    }

    #[test]
    fn test_state_validation() {
        let state = TransactionState::Active;
        assert!(state.validate_mutation().is_ok());
        assert!(state.validate_prepare().is_ok());
        assert!(state.validate_commit().is_err());
        assert!(state.validate_abort().is_ok());

        let state = TransactionState::Preparing;
        assert!(state.validate_mutation().is_err());
        assert!(state.validate_prepare().is_err());
        assert!(state.validate_commit().is_ok());
        assert!(state.validate_abort().is_ok());
    }
}
