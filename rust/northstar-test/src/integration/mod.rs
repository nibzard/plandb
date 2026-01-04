//! Integration tests for NorthstarDB.
//!
//! This module provides comprehensive integration tests that validate
//! interactions between multiple phases and components of the system.

pub mod caching_replication;
pub mod analytics_query;
pub mod disaster_recovery;
pub mod stress_tests;
pub mod end_to_end;

// Common test utilities
pub mod common;

pub use common::*;
