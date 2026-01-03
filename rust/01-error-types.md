# Error Types Specification

## Purpose

This specification catalogs all error types used across the NorthstarDB codebase and provides guidance for implementing them in Rust using `thiserror`. Error types are foundational to the database design:

1. **Common Error Language**: Establishes terminology for all error conditions
2. **thiserror Foundation**: Defines the error handling strategy for entire codebase
3. **Error Recovery Strategy**: Documents which errors are recoverable vs fatal
4. **Testing Requirements**: Shows what error conditions must be tested

## Error Categories

### 1. I/O Errors

Errors related to file system operations, disk I/O, and storage management.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `FileNotFound` | Database or WAL file does not exist on open | `pager.zig`, `wal.zig` | Yes (create new) |
| `PermissionDenied` | Insufficient permissions for file operation | `cartridges/format.zig` | No |
| `FileTooSmall` | File size too small to contain valid header | `cartridges/pending_tasks.zig` | No |
| `IOError` | Generic I/O failure during read/write | `cartridges/pending_tasks.zig` | Retry-able |
| `IncompleteKey` | RPC key data truncated | `consensus/rpc.zig` | No |
| `IncompleteValue` | RPC value data truncated | `consensus/rpc.zig` | No |
| `IncompleteMessage` | RPC message data truncated | `consensus/rpc.zig` | No |
| `IncompleteSnapshotData` | Snapshot data truncated during read | `consensus/snapshot.zig` | No |
| `InternalError` | Internal inconsistency error | `db.zig` | No |
| `NotFileBased` | Operation requires file-based DB | `db.zig` | No |
| `LogPathNotSet` | Log file path not configured | `db.zig` | No |
| `PayloadTooSmall` | WAL payload too small to deserialize | `wal.zig` | No |
| `PayloadTruncated` | WAL payload truncated during read | `wal.zig` | No |

### 2. Validation Errors

Errors related to data integrity, checksums, and validation failures.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `ChecksumMismatch` | CRC32/CRC32C checksum validation failed | `wal.zig`, `cartridges/format.zig` | No (corruption) |
| `InvalidChecksum` | Generic checksum validation failure | `wal.zig`, `txn.zig` | No (corruption) |
| `CorruptBtree` | B+tree structure corruption detected | `pager.zig`, `db.zig` | No (corruption) |
| `CorruptedData` | General data corruption | `cartridges/format.zig` | No (corruption) |
| `InvalidCommitMagic` | Commit record magic number mismatch | `txn.zig` | No (corruption) |
| `InvalidMagic` | Magic number mismatch (generic) | `cartridges/format.zig` | No (corruption) |
| `InvalidHeaderSize` | Header size validation failed | `wal.zig`, `cartridges/pending_tasks.zig` | No (corruption) |
| `InvalidOperationFlags` | Operation flags invalid for version | `txn.zig` | No (corruption) |
| `InvalidOperationType` | Unknown operation type in log | `wal.zig` | No (corruption) |
| `InvalidReservedField` | Reserved field non-zero | `txn.zig` | No (corruption) |
| `TooManyOperations` | Operation count exceeds limit | `txn.zig` | No |
| `ValidationError` | Generic validation failure | `validator.zig` | Depends |
| `CycleDetected` | Cycle in B+tree structure | `validator.zig` | No (corruption) |
| `InvalidPageType` | Page type not recognized | `validator.zig` | No (corruption) |
| `InvalidBtreeMagic` | B+tree magic number mismatch | `validator.zig` | No (corruption) |
| `KeysNotSorted` | B+tree keys not in sorted order | `validator.zig` | No (corruption) |
| `InvalidLeafLevel` | B+tree leaf at wrong level | `validator.zig` | No (corruption) |
| `InvalidInternalLevel` | B+tree internal node at wrong level | `validator.zig` | No (corruption) |
| `LeavesNotSameDepth` | B+tree leaves at inconsistent depths | `validator.zig` | No (corruption) |
| `InvalidChildPageId` | B+tree child page ID invalid | `validator.zig` | No (corruption) |
| `TreeEmpty` | Tree validation on empty tree | `validator.zig` | Warning |
| `DuplicateKeys` | Duplicate keys found in B+tree | `validator.zig` | No (corruption) |
| `MetamorphicTestFailed` | Metamorphic test inconsistency | `metamorphic.zig` | No (test failure) |

### 3. Protocol Errors

Errors related to format, versioning, and protocol violations.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `UnsupportedVersion` | Version too new to read | `cartridges/format.zig`, `consensus/index.zig` | No (upgrade required) |
| `InvalidJsonStructure` | JSON parsing failed | `llm/types.zig` | Depends |
| `JsonParseError` | JSON parse error | `llm/types.zig` | Depends |
| `UnsupportedCommandType` | Unknown RPC command type | `consensus/rpc.zig` | No |
| `UnknownCartridgeType` | Unknown cartridge type identifier | `cartridges/format.zig` | No |
| `InvalidCommitRecord` | Commit record structure invalid | `txn.zig` | No |

### 4. Concurrency Errors

Errors related to concurrent access and locking.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `WriteBusy` | Write transaction already active | `db.zig` | Yes (retry) |
| `TransactionNotActive` | Operation on non-active transaction | `txn.zig` | No |
| `TransactionNotPreparing` | Commit called without prepare | `txn.zig` | No |
| `AlreadyClaimed` | Task already claimed by agent | `cartridges/pending_tasks.zig` | Yes (query state) |

### 5. Transaction Errors

Errors related to transaction operations.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `SnapshotNotFound` | Requested snapshot does not exist | `db.zig` | No |
| `InMemoryIteratorNotSupported` | Iterator not supported for in-memory DB | `db.zig` | No (use scan) |
| `PutHasNoValue` | Put operation with empty value | `wal.zig` | No |
| `DeleteHasValue` | Delete operation with value present | `txn.zig` | No |
| `KeyLengthMismatch` | Key length does not match declared | `txn.zig` | No |
| `ValueLengthMismatch` | Value length does not match declared | `txn.zig` | No |

### 6. Size Limit Errors

Errors related to size limits and bounds checking.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `KeyTooLarge` | Key size exceeds MAX_KEY_SIZE (4KB) | `txn.zig`, `wal.zig` | No |
| `ValueTooLarge` | Value size exceeds MAX_VALUE_SIZE (16MB) | `txn.zig`, `wal.zig` | No |
| `BufferTooSmall` | Read buffer too small for value | `db.zig` | Retry with larger buffer |
| `PayloadTooLarge` | Metric payload exceeds max size | `cartridges/observability.zig` | No |

### 7. LLM / AI Errors

Errors related to LLM provider operations and AI features.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `ProviderUnavailable` | LLM provider not reachable | `llm/types.zig` | Yes (retry) |
| `Timeout` | LLM request timeout | `llm/types.zig` | Yes (retry) |
| `QuotaExceeded` | API quota exhausted | `llm/types.zig` | No (wait) |
| `InvalidResponse` | Invalid response from provider | `llm/types.zig` | Yes (retry) |
| `InvalidFunctionSchema` | Function schema invalid | `llm/types.zig` | No |
| `InvalidParameters` | Function parameters invalid | `llm/types.zig` | No |
| `SchemaValidationFailed` | Schema validation failed | `llm/types.zig` | No |
| `NetworkError` | Generic network error | `llm/types.zig` | Yes (retry) |
| `HttpError` | HTTP protocol error | `llm/types.zig` | Yes (retry) |
| `RateLimitError` | API rate limit exceeded | `llm/types.zig` | Yes (backoff) |
| `MissingApiKey` | API key not configured | `llm/types.zig` | No |
| `InvalidConfiguration` | LLM configuration invalid | `llm/types.zig` | No |

### 8. WAL / Log Errors

Errors specific to write-ahead log operations.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `WALError` | Generic WAL error | `wal.zig` | Depends |
| `ReplayError` | WAL replay failed | `wal.zig` | Depends |
| `TruncateFailed` | WAL truncation failed | `wal.zig` | No |

### 9. Pager / Storage Errors

Errors related to pager and page-level operations.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `PagerError` | Generic pager error | `pager.zig` | Depends |
| `PageAllocationFailed` | Failed to allocate page | `pager.zig` | No (disk full) |
| `InvalidPageId` | Page ID out of valid range | `pager.zig` | No |
| `PageCorrupted` | Page checksum failed | `pager.zig` | No (corruption) |

### 10. Plugin Errors

Errors related to the AI plugin system.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `PluginLoadFailed` | Failed to load plugin | `plugins/manager.zig` | No |
| `PluginValidationError` | Plugin validation failed | `plugins/manager.zig` | No |
| `PluginExecutionFailed` | Plugin execution error | `db.zig`, `plugins/manager.zig` | Logged, does not fail commit |
| `PluginNotRegistered` | Plugin not found in registry | `plugins/manager.zig` | No |
| `HookExecutionFailed` | Plugin hook execution failed | `plugins/manager.zig` | Logged, does not fail commit |

### 11. Cartridge Errors

Errors related to structured memory cartridges.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `CartridgeNotFound` | Cartridge not registered | `cartridges/admin.zig` | No |
| `WrongCartridgeType` | Cartridge type mismatch | `cartridges/pending_tasks.zig` | No |
| `InvalidCartridgeType` | Cartridge type invalid | `cartridges/format.zig` | No |
| `InvalidTaskOffset` | Task offset in cartridge invalid | `cartridges/pending_tasks.zig` | No (corruption) |
| `InvalidTaskData` | Task data in cartridge invalid | `cartridges/pending_tasks.zig` | No (corruption) |
| `MissingRequiredFeature` | Cartridge lacks required feature | `cartridges/format.zig` | No |
| `NeedsRebuild` | Cartridge needs rebuild | `cartridges/format.zig` | Yes (trigger rebuild) |
| `TooManyPatterns` | Too many invalidation patterns | `cartridges/format.zig` | No |
| `InvalidMutationType` | Invalid mutation type for pattern | `cartridges/format.zig` | No |
| `EntityNotFound` | Entity ID not found | `cartridges/entity.zig` | Yes (check exists) |
| `InvalidEntityIdFormat` | Entity ID format invalid | `cartridges/entity.zig`, `cartridges/structured_memory.zig` | No |
| `InvalidAttributeType` | Attribute type code invalid | `cartridges/structured_memory.zig` | No |
| `DimensionMismatch` | Vector dimension mismatch | `cartridges/embeddings.zig` | No |
| `NotImplemented` | Feature not yet implemented | `cartridges/entity.zig`, `cartridges/rebuild.zig`, `cartridges/migration.zig` | No |

### 12. Consensus / Raft Errors

Errors related to distributed consensus.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `RaftError` | Generic Raft error | `consensus/index.zig` | Depends |
| `TermMismatch` | Raft term mismatch | `consensus/index.zig` | Yes (retry) |
| `LogConflict` | Raft log conflict detected | `consensus/index.zig` | Yes (retry) |
| `NotLeader` | Operation requires leader role | `consensus/index.zig`, `consensus/raft.zig` | Yes (redirect) |
| `NoLeader` | No leader currently elected | `consensus/index.zig` | Yes (retry) |
| `SnapshotIncompatible` | Snapshot version incompatible | `consensus/index.zig` | No |
| `RPCFailed` | RPC communication failed | `consensus/index.zig` | Yes (retry) |
| `ElectionTimeout` | Election timed out | `consensus/index.zig` | Yes (retry) |
| `InvalidConfig` | Raft configuration invalid | `consensus/index.zig`, `consensus/config.zig` | No |
| `DuplicateNodeId` | Duplicate node ID in cluster config | `consensus/config.zig` | No |
| `InvalidElectionTimeout` | Election timeout range invalid | `consensus/config.zig` | No |
| `HeartbeatTooLarge` | Heartbeat interval too large | `consensus/config.zig` | No |
| `TooFewPeers` | Insufficient peers for quorum | `consensus/config.zig` | No |
| `NodeAlreadyExists` | Node ID already in cluster | `consensus/raft.zig` | No |
| `NodeNotFound` | Node ID not in cluster | `consensus/raft.zig` | No |
| `CannotRemoveLeader` | Cannot remove leader from cluster | `consensus/raft.zig` | No |
| `ConfigChangeInProgress` | Config change already in progress | `consensus/raft.zig` | No |
| `NoPendingConfigChange` | No pending config change to complete | `consensus/raft.zig` | No |
| `NoSnapshot` | No snapshot available | `consensus/raft.zig` | Yes (create one) |
| `NoInstallSnapshotCallback` | No callback for install snapshot | `consensus/raft.zig` | No (config error) |

### 13. Replication Errors

Errors related to log-based replication.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `ReplicationError` | Generic replication error | `replication/index.zig` | Depends |
| `PublisherUnavailable` | Publisher not reachable | `replication/subscriber.zig` | Yes (retry) |
| `SubscriberError` | Generic subscriber error | `replication/subscriber.zig` | Depends |
| `SequencerUnavailable` | Sequencer not reachable | `replication/publisher.zig` | Yes (retry) |
| `OffsetNotFound` | Log offset not found | `replication/subscriber.zig` | Yes (seek) |
| `BatchTooLarge` | Replication batch exceeds limit | `replication/protocol.zig` | No (split) |

### 14. Feature Flag Errors

Errors related to feature flag system.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `FeatureNotFound` | Feature flag not found | `feature_flags/ai_toggle.zig` | No |
| `InvalidPercentage` | Percentage value invalid (0-100 required) | `feature_flags/ai_toggle.zig` | No |
| `ExperimentNotFound` | Experiment not found | `feature_flags/ai_toggle.zig` | No |
| `ExperimentDisabled` | Experiment is disabled | `feature_flags/ai_toggle.zig` | No |
| `NoVariantAvailable` | No variant for assignment | `feature_flags/ai_toggle.zig` | Yes (fallback) |

### 15. Rate Limiting Errors

Errors related to rate limiting.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `RateLimited` | Rate limit exceeded | `cartridges/observability.zig` | Yes (backoff) |

### 16. Migration Errors

Errors related to data migration.

| Error Name | Description | Source | Recoverable |
|------------|-------------|--------|-------------|
| `MigrationError` | Generic migration error | `migrations/vanilla.zig` | Depends |
| `VersionTooOld` | Database version too old to migrate | `migrations/vanilla.zig` | No |
| `VersionTooNew` | Database version too new (downgrade) | `migrations/vanilla.zig` | No |
| `UnsupportedVersion` | Unsupported format version | `cartridges/migration.zig` | No |
| `CorruptData` | Data corruption detected during migration | `cartridges/migration.zig` | No |

## Rust Implementation Guidance

### Module Structure

```
northwind/
├── src/
│   └── error/
│       ├── mod.rs          // Re-exports
│       ├── io.rs           // I/O errors
│       ├── validation.rs   // Validation errors
│       ├── protocol.rs     // Protocol errors
│       ├── concurrency.rs  // Concurrency errors
│       ├── transaction.rs  // Transaction errors
│       ├── storage.rs      // Pager/WAL errors
│       ├── llm.rs          // LLM errors
│       ├── plugin.rs       // Plugin errors
│       ├── cartridge.rs    // Cartridge errors
│       ├── consensus.rs    // Raft errors
│       ├── replication.rs  // Replication errors
│       └── feature.rs      // Feature flag errors
```

### Type Definitions

Using `thiserror`, the error hierarchy should be:

```rust
use thiserror::Error;

/// Top-level database error
#[derive(Error, Debug)]
pub enum DbError {
    #[error("I/O error: {0}")]
    Io(#[from] IoError),

    #[error("Validation error: {0}")]
    Validation(#[from] ValidationError),

    #[error("Protocol error: {0}")]
    Protocol(#[from] ProtocolError),

    #[error("Concurrency error: {0}")]
    Concurrency(#[from] ConcurrencyError),

    #[error("Transaction error: {0}")]
    Transaction(#[from] TransactionError),

    #[error("Storage error: {0}")]
    Storage(#[from] StorageError),

    #[error("LLM error: {0}")]
    Llm(#[from] LlmError),

    #[error("Plugin error: {0}")]
    Plugin(#[from] PluginError),

    #[error("Cartridge error: {0}")]
    Cartridge(#[from] CartridgeError),

    #[error("Consensus error: {0}")]
    Consensus(#[from] ConsensusError),

    #[error("Replication error: {0}")]
    Replication(#[from] ReplicationError),
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

    #[error("Invalid operation type: {type}")]
    InvalidOperationType { type: u8 },

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

    #[error("Unknown cartridge type: {type}")]
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

/// LLM errors
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

    #[error("Invalid cartridge type: {type}")]
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

    #[error("Invalid mutation type: {type}")]
    InvalidMutationType { type_: String },

    #[error("Entity not found: {entity_id}")]
    EntityNotFound { entity_id: String },

    #[error("Invalid entity ID format: {id}")]
    InvalidEntityIdFormat { id: String },

    #[error("Invalid attribute type: {type}")]
    InvalidAttributeType { type_: u8 },

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
```

### Error Conversion Patterns

```rust
// Converting std::io::Error to IoError
impl From<std::io::Error> for IoError {
    fn from(err: std::io::Error) -> Self {
        match err.kind() {
            std::io::ErrorKind::NotFound => IoError::FileNotFound {
                path: String::from("unknown"), // Update with context
            },
            std::io::ErrorKind::PermissionDenied => IoError::PermissionDenied {
                path: String::from("unknown"),
            },
            _ => IoError::Generic(err),
        }
    }
}

// Adding context to errors
use error::{IoError, ValidationError};

fn read_page(page_id: u64) -> Result<Vec<u8>, DbError> {
    let path = format!("data/page_{}.dat", page_id);
    std::fs::read(&path)
        .map_err(|e| IoError::FileNotFound { path }.into())
}

fn validate_checksum(data: &[u8], expected: u32) -> Result<(), DbError> {
    let actual = crc32c::crc32c(data);
    if actual != expected {
        return Err(ValidationError::ChecksumMismatch { expected, actual }.into());
    }
    Ok(())
}
```

### Context Preservation

```rust
use std::path::PathBuf;

#[derive(Error, Debug)]
pub enum IoError {
    #[error("Failed to open database at {path}: {source}")]
    OpenFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("Failed to read page {page_id} from {path}: {source}")]
    ReadPageFailed {
        path: PathBuf,
        page_id: u64,
        #[source]
        source: std::io::Error,
    },
}
```

### Concurrency Considerations

All error types should be:
- **Send**: Safe to send between threads
- **Sync**: Safe to share between threads
- **'static**: No borrowed data

```rust
// All thiserror derives are Send + Sync + 'static
// String and owned types satisfy this
// Avoid using &str, &[u8], or other borrowed data in errors
```

### Testing Requirements

Each error variant should have:
1. **Unit test** verifying error condition triggers
2. **Integration test** verifying error propagates correctly
3. **Recovery test** if error is recoverable

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_checksum_mismatch() {
        let data = b"corrupted data";
        let expected = 12345;
        let result = validate_checksum(data, expected);
        assert!(matches!(
            result,
            Err(DbError::Validation(
                ValidationError::ChecksumMismatch { actual, .. }
            )) if actual == crc32c::crc32c(data)
        ));
    }

    #[test]
    fn test_write_busy_retry() {
        // Setup database with active write
        let db = Db::open_in_memory();
        let w1 = db.begin_write().unwrap();

        // Second write should fail with WriteBusy
        let w2_result = db.begin_write();
        assert!(matches!(
            w2_result,
            Err(DbError::Concurrency(
                ConcurrencyError::WriteBusy
            ))
        ));

        // After commit, should succeed
        w1.commit().unwrap();
        let w3 = db.begin_write().unwrap();
        assert!(w3.is_ok());
    }
}
```

## Error Recovery Strategy

| Error Type | Recovery Strategy |
|------------|-------------------|
| **I/O Errors** | Retry with exponential backoff for network/transient errors |
| **Validation Errors** | No recovery - indicates corruption |
| **Protocol Errors** | No recovery - requires upgrade/reconfiguration |
| **Concurrency Errors** | Retry operation after delay |
| **Transaction Errors** | Rollback and retry with different txn_id |
| **LLM Errors** | Retry with backoff, fall back to default behavior |
| **Plugin Errors** | Log error, continue without plugin |
| **Cartridge Errors** | Rebuild cartridge if needed |
| **Consensus Errors** | Retry with term update |
| **Replication Errors** | Seek to valid offset, retry |
| **Feature Errors** | Use default variant/value |

## Summary Statistics

| Category | Error Count |
|----------|-------------|
| I/O | 13 |
| Validation | 25 |
| Protocol | 6 |
| Concurrency | 4 |
| Transaction | 6 |
| Size Limits | 4 |
| LLM/AI | 12 |
| WAL/Log | 3 |
| Pager/Storage | 4 |
| Plugin | 5 |
| Cartridge | 15 |
| Consensus/Raft | 23 |
| Replication | 5 |
| Feature Flags | 5 |
| Rate Limiting | 1 |
| Migration | 5 |
| **Total** | **131** |
