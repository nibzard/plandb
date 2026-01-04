//! Cache error types

use std::fmt;

/// Cache operation errors
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CacheError {
    /// Entry size exceeds maximum cache size
    EntryTooLarge { size: usize, max_size: usize },

    /// Cache is full and cannot evict (all entries pinned)
    CacheFull,

    /// Lock was poisoned (concurrent access bug)
    Poisoned,

    /// Invalid configuration
    InvalidConfig(String),

    /// Write-back failed
    WriteBackFailed,
}

impl fmt::Display for CacheError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EntryTooLarge { size, max_size } => write!(
                f,
                "Entry size {} exceeds maximum cache size {}",
                size, max_size
            ),
            Self::CacheFull => write!(f, "Cache is full and cannot evict entries"),
            Self::Poisoned => write!(f, "Cache lock was poisoned"),
            Self::InvalidConfig(msg) => write!(f, "Invalid cache configuration: {}", msg),
            Self::WriteBackFailed => write!(f, "Failed to write back dirty entry"),
        }
    }
}

impl std::error::Error for CacheError {}

/// Result type for cache operations
pub type CacheResult<T> = Result<T, CacheError>;
