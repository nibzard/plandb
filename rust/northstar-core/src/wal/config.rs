//! WAL configuration and state types
//!
//! Configuration parameters controlling WAL behavior and performance trade-offs.

/// Default WAL buffer size (64KB)
pub const DEFAULT_BUFFER_SIZE: usize = 64 * 1024;

/// Minimum buffer size (4KB - one page)
pub const MIN_BUFFER_SIZE: usize = 4 * 1024;

/// Default autocheckpoint threshold (number of records)
pub const DEFAULT_AUTOCHECKPOINT_THRESHOLD: usize = 10_000;

/// Default maximum WAL file size before rotation (100MB)
pub const DEFAULT_MAX_WAL_SIZE: usize = 100 * 1024 * 1024;

/// WAL sync strategy - controls when fsync is called
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncStrategy {
    /// Synchronize WAL on every commit operation
    /// Provides maximum durability at the cost of higher latency
    OnCommit,

    /// Accumulate multiple commits before synchronizing
    /// Improves throughput but risks losing the most recent commits on crash
    Batch,

    /// Never automatically synchronize
    /// Caller must explicitly call sync for durability
    None,
}

impl Default for SyncStrategy {
    fn default() -> Self {
        SyncStrategy::OnCommit
    }
}

/// WAL internal state machine
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalState {
    /// WAL is not open, file handle is invalid
    /// No operations are valid except create/open
    Closed,

    /// WAL is open and ready for normal operations
    /// Append, sync, truncate, and scan operations are valid
    Open,

    /// WAL is being opened and scanned for crash recovery
    /// Transitional state during open operation
    Recovering,

    /// WAL encountered an unrecoverable error
    /// Most operations are invalid, WAL should be closed and recreated
    Error,
}

impl WalState {
    /// Check if the WAL is in a state that allows modifications
    pub const fn allows_modifications(&self) -> bool {
        matches!(self, WalState::Open)
    }

    /// Check if the WAL is in a state that allows reads
    pub const fn allows_reads(&self) -> bool {
        matches!(self, WalState::Open | WalState::Recovering)
    }

    /// Check if the WAL is open (ready for use)
    pub const fn is_open(&self) -> bool {
        matches!(self, WalState::Open)
    }

    /// Check if the WAL is closed
    pub const fn is_closed(&self) -> bool {
        matches!(self, WalState::Closed)
    }
}

/// WAL configuration parameters
#[derive(Debug, Clone)]
pub struct WalConfig {
    /// Size of internal write buffer in bytes
    /// Larger buffers reduce system call overhead but increase memory usage
    pub buffer_size: usize,

    /// Durability strategy controlling when fsync is called
    pub sync_strategy: SyncStrategy,

    /// Number of records after which automatic checkpoint is suggested
    /// Zero disables autocheckpoint suggestions
    pub autocheckpoint_threshold: usize,

    /// Maximum WAL file size before rotation is recommended
    pub max_wal_size: usize,
}

impl Default for WalConfig {
    fn default() -> Self {
        WalConfig {
            buffer_size: DEFAULT_BUFFER_SIZE,
            sync_strategy: SyncStrategy::default(),
            autocheckpoint_threshold: DEFAULT_AUTOCHECKPOINT_THRESHOLD,
            max_wal_size: DEFAULT_MAX_WAL_SIZE,
        }
    }
}

impl WalConfig {
    /// Create a new WalConfig with default values
    pub fn new() -> Self {
        Self::default()
    }

    /// Set buffer size
    ///
    /// # Panics
    /// Panics if buffer_size is less than MIN_BUFFER_SIZE or not page-aligned
    pub fn with_buffer_size(mut self, buffer_size: usize) -> Self {
        assert!(
            buffer_size >= MIN_BUFFER_SIZE,
            "Buffer size must be at least {} bytes",
            MIN_BUFFER_SIZE
        );
        assert!(
            buffer_size % MIN_BUFFER_SIZE == 0,
            "Buffer size must be page-aligned (multiple of {} bytes)",
            MIN_BUFFER_SIZE
        );
        self.buffer_size = buffer_size;
        self
    }

    /// Set sync strategy
    pub fn with_sync_strategy(mut self, strategy: SyncStrategy) -> Self {
        self.sync_strategy = strategy;
        self
    }

    /// Set autocheckpoint threshold
    ///
    /// Zero disables autocheckpoint suggestions
    pub fn with_autocheckpoint_threshold(mut self, threshold: usize) -> Self {
        self.autocheckpoint_threshold = threshold;
        self
    }

    /// Set maximum WAL file size
    pub fn with_max_wal_size(mut self, size: usize) -> Self {
        assert!(
            size >= self.buffer_size,
            "Max WAL size must be at least buffer size"
        );
        self.max_wal_size = size;
        self
    }

    /// Validate configuration
    pub fn validate(&self) -> Result<(), String> {
        if self.buffer_size < MIN_BUFFER_SIZE {
            return Err(format!(
                "Buffer size too small (minimum {} bytes)",
                MIN_BUFFER_SIZE
            ));
        }

        if self.buffer_size % MIN_BUFFER_SIZE != 0 {
            return Err("Buffer size must be page-aligned".to_string());
        }

        if self.max_wal_size < self.buffer_size {
            return Err("Max WAL size must be at least buffer size".to_string());
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = WalConfig::default();

        assert_eq!(config.buffer_size, DEFAULT_BUFFER_SIZE);
        assert_eq!(config.sync_strategy, SyncStrategy::OnCommit);
        assert_eq!(
            config.autocheckpoint_threshold,
            DEFAULT_AUTOCHECKPOINT_THRESHOLD
        );
        assert_eq!(config.max_wal_size, DEFAULT_MAX_WAL_SIZE);
    }

    #[test]
    fn test_config_builder() {
        let config = WalConfig::new()
            .with_buffer_size(128 * 1024)
            .with_sync_strategy(SyncStrategy::Batch)
            .with_autocheckpoint_threshold(5000)
            .with_max_wal_size(200 * 1024 * 1024);

        assert_eq!(config.buffer_size, 128 * 1024);
        assert_eq!(config.sync_strategy, SyncStrategy::Batch);
        assert_eq!(config.autocheckpoint_threshold, 5000);
        assert_eq!(config.max_wal_size, 200 * 1024 * 1024);
    }

    #[test]
    fn test_config_validate() {
        let config = WalConfig::default();
        assert!(config.validate().is_ok());

        // Buffer size too small
        let config = WalConfig {
            buffer_size: 1024,
            ..Default::default()
        };
        assert!(config.validate().is_err());

        // Buffer size not page-aligned
        let config = WalConfig {
            buffer_size: 5000,
            ..Default::default()
        };
        assert!(config.validate().is_err());

        // Max size smaller than buffer
        let config = WalConfig {
            buffer_size: 64 * 1024,
            max_wal_size: 32 * 1024,
            ..Default::default()
        };
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_wal_state() {
        assert!(WalState::Open.allows_modifications());
        assert!(!WalState::Closed.allows_modifications());
        assert!(!WalState::Recovering.allows_modifications());
        assert!(!WalState::Error.allows_modifications());

        assert!(WalState::Open.allows_reads());
        assert!(!WalState::Closed.allows_reads());
        assert!(WalState::Recovering.allows_reads());
        assert!(!WalState::Error.allows_reads());
    }

    #[test]
    #[should_panic(expected = "Buffer size must be at least")]
    fn test_buffer_size_to_small_panics() {
        WalConfig::new().with_buffer_size(1024);
    }

    #[test]
    #[should_panic(expected = "Buffer size must be page-aligned")]
    fn test_buffer_size_not_aligned_panics() {
        WalConfig::new().with_buffer_size(5000);
    }

    #[test]
    #[should_panic(expected = "Max WAL size must be at least buffer size")]
    fn test_max_size_too_small_panics() {
        WalConfig::new().with_buffer_size(64 * 1024).with_max_wal_size(32 * 1024);
    }
}
