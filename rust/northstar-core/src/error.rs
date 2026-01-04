//! Error types for NorthstarDB.
//!
//! Comprehensive error hierarchy using thiserror for clear error reporting.

use thiserror::Error;

/// Result type alias for NorthstarDB operations
pub type Result<T> = std::result::Result<T, Error>;

/// Top-level database error
#[derive(Error, Debug)]
pub enum Error {
    /// I/O error
    #[error("I/O error: {0}")]
    Io(#[from] IoError),

    /// Validation error
    #[error("Validation error: {0}")]
    Validation(#[from] ValidationError),

    /// Protocol error
    #[error("Protocol error: {0}")]
    Protocol(#[from] ProtocolError),

    /// Concurrency error
    #[error("Concurrency error: {0}")]
    Concurrency(#[from] ConcurrencyError),

    /// Transaction error
    #[error("Transaction error: {0}")]
    Transaction(#[from] TransactionError),

    /// Storage error
    #[error("Storage error: {0}")]
    Storage(#[from] StorageError),

    /// LLM/AI error
    #[error("LLM error: {0}")]
    Llm(#[from] LlmError),

    /// Plugin error
    #[error("Plugin error: {0}")]
    Plugin(#[from] PluginError),

    /// Cartridge error
    #[error("Cartridge error: {0}")]
    Cartridge(#[from] CartridgeError),

    /// Consensus error
    #[error("Consensus error: {0}")]
    Consensus(#[from] ConsensusError),

    /// Replication error
    #[error("Replication error: {0}")]
    Replication(#[from] ReplicationError),

    /// Feature flag error
    #[error("Feature error: {0}")]
    Feature(#[from] FeatureError),

    /// Rate limit error
    #[error("Rate limit: {0}")]
    RateLimit(#[from] RateLimitError),

    /// Size limit error
    #[error("Size limit exceeded: {0}")]
    SizeLimit(#[from] SizeLimitError),
}

/// I/O errors
#[derive(Error, Debug)]
pub enum IoError {
    #[error("File not found: {path}")]
    FileNotFound { path: String },

    #[error("Permission denied: {path}")]
    PermissionDenied { path: String },

    #[error("File too small: {path} (size: {size} bytes, expected at least {expected})")]
    FileTooSmall { path: String, size: u64, expected: u64 },

    #[error("I/O error: {0}")]
    Generic(#[from] std::io::Error),

    #[error("Incomplete key data")]
    IncompleteKey,

    #[error("Incomplete value data")]
    IncompleteValue,

    #[error("Incomplete message data")]
    IncompleteMessage,

    #[error("Incomplete snapshot data")]
    IncompleteSnapshotData,

    #[error("Internal error: {0}")]
    InternalError(String),

    #[error("Not file-based database")]
    NotFileBased,

    #[error("Log path not set")]
    LogPathNotSet,
}

/// Validation errors
#[derive(Error, Debug)]
pub enum ValidationError {
    #[error("Checksum mismatch (expected: {expected}, got: {actual})")]
    ChecksumMismatch { expected: u32, actual: u32 },

    #[error("B+tree corrupted at page {page_id}")]
    CorruptBtree { page_id: u64 },

    #[error("Data corrupted")]
    CorruptedData,

    #[error("Invalid commit magic (expected: 0x{expected:08x}, got: 0x{actual:08x})")]
    InvalidCommitMagic { expected: u32, actual: u32 },

    #[error("Invalid magic number (expected: 0x{expected:08x}, got: 0x{actual:08x})")]
    InvalidMagic { expected: u32, actual: u32 },

    #[error("Invalid header size (expected: {expected}, got: {actual})")]
    InvalidHeaderSize { expected: usize, actual: usize },

    #[error("Invalid operation flags: {flags}")]
    InvalidOperationFlags { flags: u8 },

    #[error("Invalid operation type: {type_val}")]
    InvalidOperationType { type_val: u8 },

    #[error("Invalid reserved field (must be 0, got: {value})")]
    InvalidReservedField { value: u32 },

    #[error("Too many operations: {count} (max: {max})")]
    TooManyOperations { count: u32, max: u32 },

    #[error("Validation failed: {0}")]
    Generic(String),

    #[error("Cycle detected at page {page_id}")]
    CycleDetected { page_id: u64 },

    #[error("Invalid page type: {page_type}")]
    InvalidPageType { page_type: u8 },

    #[error("Invalid B+tree magic")]
    InvalidBtreeMagic,

    #[error("Keys not sorted")]
    KeysNotSorted,

    #[error("Invalid leaf level: {level}")]
    InvalidLeafLevel { level: u16 },

    #[error("Invalid internal level: {level}")]
    InvalidInternalLevel { level: u16 },

    #[error("Leaves not at same depth")]
    LeavesNotSameDepth,

    #[error("Invalid child page ID: {page_id}")]
    InvalidChildPageId { page_id: u64 },

    #[error("Tree is empty")]
    TreeEmpty,

    #[error("Duplicate keys found")]
    DuplicateKeys,

    #[error("Header checksum mismatch (expected: {expected}, got: {actual})")]
    HeaderChecksumMismatch { expected: u32, actual: u32 },

    #[error("Payload length invalid: {len} bytes (max: {max})")]
    PayloadLengthInvalid { len: u32, max: u32 },

    #[error("Unsupported version: {major}.{minor}.{patch}")]
    UnsupportedVersion { major: u16, minor: u8, patch: u8 },

    #[error("Key length mismatch (expected: {expected}, got: {actual})")]
    KeyLengthMismatch { expected: u16, actual: usize },

    #[error("Value length mismatch (expected: {expected}, got: {actual})")]
    ValueLengthMismatch { expected: u32, actual: usize },

    #[error("Delete operation has value")]
    DeleteHasValue,
}

/// Protocol errors
#[derive(Error, Debug)]
pub enum ProtocolError {
    #[error("Unsupported version: {major}.{minor}.{patch}")]
    UnsupportedVersion { major: u8, minor: u8, patch: u8 },

    #[error("Invalid JSON structure: {0}")]
    InvalidJsonStructure(String),

    #[error("JSON parse error: {0}")]
    JsonParseError(#[from] serde_json::Error),

    #[error("Unsupported command type: {command}")]
    UnsupportedCommandType { command: u32 },

    #[error("Unknown cartridge type: {type_}")]
    UnknownCartridgeType { type_: String },

    #[error("Invalid commit record")]
    InvalidCommitRecord,
}

/// Concurrency errors
#[derive(Error, Debug)]
pub enum ConcurrencyError {
    #[error("Write busy: another write transaction is active")]
    WriteBusy,

    #[error("Transaction not active")]
    TransactionNotActive,

    #[error("Transaction not in preparing state")]
    TransactionNotPreparing,

    #[error("Task already claimed")]
    AlreadyClaimed,
}

/// Transaction errors
#[derive(Error, Debug)]
pub enum TransactionError {
    #[error("Snapshot not found: txn_id {txn_id}")]
    SnapshotNotFound { txn_id: u64 },

    #[error("Iterator not supported for in-memory databases (use scan)")]
    InMemoryIteratorNotSupported,

    #[error("Put operation has no value")]
    PutHasNoValue,

    #[error("Delete operation has value")]
    DeleteHasValue,

    #[error("Key length mismatch (expected: {expected}, got: {actual})")]
    KeyLengthMismatch { expected: u16, actual: usize },

    #[error("Value length mismatch (expected: {expected}, got: {actual})")]
    ValueLengthMismatch { expected: u32, actual: usize },
}

/// Storage errors
#[derive(Error, Debug)]
pub enum StorageError {
    #[error("Pager error: {0}")]
    Pager(String),

    #[error("Page allocation failed")]
    PageAllocationFailed,

    #[error("Invalid page ID: {page_id}")]
    InvalidPageId { page_id: u64 },

    #[error("Page corrupted: {page_id}")]
    PageCorrupted { page_id: u64 },

    #[error("WAL error: {0}")]
    Wal(String),

    #[error("WAL replay failed: {0}")]
    ReplayFailed(String),

    #[error("WAL truncate failed")]
    TruncateFailed,
}

/// LLM/AI errors
#[derive(Error, Debug)]
pub enum LlmError {
    #[error("Provider unavailable: {provider}")]
    ProviderUnavailable { provider: String },

    #[error("Request timeout after {timeout_ms}ms")]
    Timeout { timeout_ms: u32 },

    #[error("Quota exceeded for provider: {provider}")]
    QuotaExceeded { provider: String },

    #[error("Invalid response from provider: {provider}")]
    InvalidResponse { provider: String },

    #[error("Invalid function schema: {0}")]
    InvalidFunctionSchema(String),

    #[error("Invalid parameters: {0}")]
    InvalidParameters(String),

    #[error("Schema validation failed: {0}")]
    SchemaValidationFailed(String),

    #[error("Network error: {0}")]
    NetworkError(String),

    #[error("HTTP error: {status}")]
    HttpError { status: u16 },

    #[error("Rate limit exceeded")]
    RateLimitError,

    #[error("Missing API key for provider: {provider}")]
    MissingApiKey { provider: String },

    #[error("Invalid configuration: {0}")]
    InvalidConfiguration(String),
}

/// Plugin errors
#[derive(Error, Debug)]
pub enum PluginError {
    #[error("Plugin load failed: {plugin}")]
    LoadFailed { plugin: String },

    #[error("Plugin validation failed: {plugin}")]
    ValidationError { plugin: String },

    #[error("Plugin execution failed: {plugin}: {error}")]
    ExecutionFailed { plugin: String, error: String },

    #[error("Plugin not registered: {plugin}")]
    NotRegistered { plugin: String },

    #[error("Hook execution failed: {plugin}.{hook}")]
    HookExecutionFailed { plugin: String, hook: String },
}

/// Cartridge errors
#[derive(Error, Debug)]
pub enum CartridgeError {
    #[error("Cartridge not found: {name}")]
    NotFound { name: String },

    #[error("Wrong cartridge type (expected: {expected}, got: {actual}")]
    WrongType { expected: String, actual: String },

    #[error("Invalid cartridge type: {type_}")]
    InvalidType { type_: String },

    #[error("Invalid task offset: {offset}")]
    InvalidTaskOffset { offset: u64 },

    #[error("Invalid task data")]
    InvalidTaskData,

    #[error("Missing required feature: {feature}")]
    MissingRequiredFeature { feature: String },

    #[error("Cartridge needs rebuild")]
    NeedsRebuild,

    #[error("Too many patterns (max: {max})")]
    TooManyPatterns { max: u32 },

    #[error("Invalid mutation type: {type_}")]
    InvalidMutationType { type_: String },

    #[error("Entity not found: {entity_id}")]
    EntityNotFound { entity_id: String },

    #[error("Invalid entity ID format: {id}")]
    InvalidEntityIdFormat { id: String },

    #[error("Invalid attribute type: {type_val}")]
    InvalidAttributeType { type_val: u8 },

    #[error("Dimension mismatch (expected: {expected}, got: {actual})")]
    DimensionMismatch { expected: usize, actual: usize },

    #[error("Not implemented: {feature}")]
    NotImplemented { feature: String },
}

/// Consensus errors
#[derive(Error, Debug)]
pub enum ConsensusError {
    #[error("Term mismatch (current: {current}, received: {received})")]
    TermMismatch { current: u64, received: u64 },

    #[error("Log conflict at index {index}")]
    LogConflict { index: u64 },

    #[error("Not leader (current role: {role})")]
    NotLeader { role: String },

    #[error("No leader elected")]
    NoLeader,

    #[error("Snapshot incompatible")]
    SnapshotIncompatible,

    #[error("RPC failed: {0}")]
    RpcFailed(String),

    #[error("Election timeout")]
    ElectionTimeout,

    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),

    #[error("Duplicate node ID: {node_id}")]
    DuplicateNodeId { node_id: u64 },

    #[error("Invalid election timeout (min: {min_ms}ms, max: {max_ms}ms)")]
    InvalidElectionTimeout { min_ms: u32, max_ms: u32 },

    #[error("Heartbeat interval too large: {interval_ms}ms (max: {max_ms}ms)")]
    HeartbeatTooLarge { interval_ms: u32, max_ms: u32 },

    #[error("Too few peers: {count} (min: {min})")]
    TooFewPeers { count: usize, min: usize },

    #[error("Node already exists: {node_id}")]
    NodeAlreadyExists { node_id: u64 },

    #[error("Node not found: {node_id}")]
    NodeNotFound { node_id: u64 },

    #[error("Cannot remove leader")]
    CannotRemoveLeader,

    #[error("Config change already in progress")]
    ConfigChangeInProgress,

    #[error("No pending config change")]
    NoPendingConfigChange,

    #[error("No snapshot available")]
    NoSnapshot,

    #[error("No install snapshot callback configured")]
    NoInstallSnapshotCallback,
}

/// Replication errors
#[derive(Error, Debug)]
pub enum ReplicationError {
    #[error("Publisher unavailable: {publisher}")]
    PublisherUnavailable { publisher: String },

    #[error("Subscriber error: {0}")]
    Subscriber(String),

    #[error("Sequencer unavailable")]
    SequencerUnavailable,

    #[error("Offset not found: {offset}")]
    OffsetNotFound { offset: u64 },

    #[error("Batch too large: {size} bytes (max: {max})")]
    BatchTooLarge { size: usize, max: usize },
}

/// Feature flag errors
#[derive(Error, Debug)]
pub enum FeatureError {
    #[error("Feature not found: {feature}")]
    NotFound { feature: String },

    #[error("Invalid percentage: {percent} (must be 0-100)")]
    InvalidPercentage { percent: usize },

    #[error("Experiment not found: {experiment}")]
    ExperimentNotFound { experiment: String },

    #[error("Experiment disabled: {experiment}")]
    ExperimentDisabled { experiment: String },

    #[error("No variant available for experiment: {experiment}")]
    NoVariantAvailable { experiment: String },
}

/// Rate limiting error
#[derive(Error, Debug)]
pub enum RateLimitError {
    #[error("Rate limit exceeded")]
    RateLimited,
}

/// Size limit errors
#[derive(Error, Debug)]
pub enum SizeLimitError {
    #[error("Key too large: {size} bytes (max: {max})")]
    KeyTooLarge { size: usize, max: usize },

    #[error("Value too large: {size} bytes (max: {max})")]
    ValueTooLarge { size: usize, max: usize },

    #[error("Buffer too small: {size} bytes (need at least {needed})")]
    BufferTooSmall { size: usize, needed: usize },
}

/// Convenience alias for database errors
pub type DbError = Error;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_display() {
        let err = ValidationError::InvalidMagic {
            expected: 0x4E534442,
            actual: 0xDEADBEEF,
        };
        assert!(err.to_string().contains("Invalid magic number"));
    }

    #[test]
    fn test_io_error_from_std_io() {
        let std_err = std::io::Error::new(std::io::ErrorKind::NotFound, "test");
        let io_err: IoError = std_err.into();
        assert!(matches!(io_err, IoError::Generic(_)));
    }

    #[test]
    fn test_json_error_conversion() {
        let json_err = serde_json::from_str::<serde_json::Value>("invalid").unwrap_err();
        let proto_err: ProtocolError = json_err.into();
        assert!(matches!(proto_err, ProtocolError::JsonParseError(_)));
    }

    #[test]
    fn test_error_chain() {
        let err = Error::Validation(ValidationError::InvalidMagic {
            expected: 0x1234,
            actual: 0x5678,
        });
        assert!(matches!(err, Error::Validation(ValidationError::InvalidMagic { .. })));
    }
}
