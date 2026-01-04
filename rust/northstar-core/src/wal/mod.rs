//! WAL (Write-Ahead Log) module
//!
//! Provides append-only logging for transaction durability and crash recovery.

mod config;
mod header;
mod record;
mod wal;

// Re-export main types
pub use wal::Wal;

// Re-export config types
pub use config::{SyncStrategy, WalConfig, WalState};

// Re-export header types
pub use header::{RecordHeader, RecordFlags, RecordTrailer, RecordType};

// Re-export record types
pub use record::{
    CommitPayloadHeader, CommitRecord, EncodedOperation, Mutation, OperationType,
    COMMIT_HEADER_SIZE, COMMIT_MAGIC, MAX_KEY_SIZE, MAX_OPERATIONS_PER_COMMIT,
    MAX_VALUE_SIZE,
};

// Re-export header constants
pub use header::{HEADER_SIZE, RECORD_MAGIC, TRAILER_MAGIC, TRAILER_SIZE};
