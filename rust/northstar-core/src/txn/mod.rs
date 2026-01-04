//! Transaction system for NorthstarDB.
//!
//! Provides ACID guarantees through read and write transactions with
//! snapshot isolation and two-phase commit.

mod context;
mod state;
mod mutation;
mod commit;
mod read_txn;
mod write_txn;

pub use context::TransactionContext;
pub use state::TransactionState;
pub use mutation::Mutation;
pub use commit::CommitRecord;
pub use read_txn::ReadTxn;
pub use write_txn::WriteTxn;

// Maximum sizes and limits
pub const MAX_KEY_SIZE: usize = 4096;
pub const MAX_VALUE_SIZE: usize = 16 * 1024 * 1024; // 16MB
pub const MAX_OPERATIONS_PER_COMMIT: usize = 1000;
