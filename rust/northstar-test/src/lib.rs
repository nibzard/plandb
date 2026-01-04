//! NorthstarDB testing utilities.
//!
//! This crate provides testing frameworks including reference models,
//! property-based testing, crash consistency tests, and fuzzing harnesses.

#![warn(missing_docs)]
#![warn(clippy::all)]

// Re-exports
pub use northstar_core;

// Integration tests
pub mod integration;

// TODO: Add test utilities
// - Reference model for equivalence testing
// - Crash consistency test harness
// - Property-based testing utilities
// - Fuzzing harness integration
