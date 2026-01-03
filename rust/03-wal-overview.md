# WAL Overview

## Purpose

The Write-Ahead Log (WAL) is NorthstarDB's append-only logging system that provides atomicity, durability, and crash recovery for all database transactions. The WAL guarantees that no committed transaction is ever lost, even if the system crashes immediately after commit. By writing transaction modifications to the WAL before applying them to the database file, the WAL enables recovery by replaying committed transactions and undoing uncommitted work. The WAL maintains a total ordering of all operations through monotonically increasing Log Sequence Numbers (LSNs), which support point-in-time recovery, replication, and consistent snapshots.

## Responsibilities

### Atomicity Enforcement

**Transaction Atomicity**: Ensure all-or-nothing execution of transactions
- Write all transaction operations to WAL before committing
- Guarantee that either all operations persist or none persist
- Support atomic commit across multiple page modifications
- Detect partial writes during recovery using checksums
- Reject transactions with incomplete WAL records

**Commit Atomicity**: Single atomic point for transaction commit
- Mark transaction commit with a special commit record
- Ensure commit record reaches stable storage before acknowledging
- Use write-ahead logging to guarantee durability before page modification
- Support rollback by aborting uncommitted transactions

### Durability Guarantees

**Write-Ahead Property**: Modifications must persist before application
- Write WAL records to stable storage before modifying database pages
- Force WAL to disk (fsync) before considering transaction committed
- Ensure ordering guarantees for concurrent writers
- Maintain durability across power failures and crashes

**Data Persistence**: Once committed, data survives any subsequent crash
- Flush WAL records to permanent storage before commit returns
- Use fsync or fdatasync to ensure data reaches disk platter
- Handle delayed allocation and write-back caching issues
- Validate persistence with checksum verification on recovery

### Crash Recovery

**Replay Process**: Restore database to consistent state after crash
- Scan WAL from last checkpoint to end of log
- Identify committed transactions by examining commit records
- Apply all committed transaction modifications to database pages
- Ignore or roll back uncommitted transaction modifications
- Rebuild free list and other metadata from replayed operations

**Checkpoint Coordination**: Reduce recovery time by truncating processed WAL
- Coordinate with Pager to flush dirty pages to storage
- Update metadata with checkpoint LSN (oldest needed WAL record)
- Truncate WAL files up to checkpoint LSN
- Ensure all pages before checkpoint are fully persisted
- Minimize WAL size while maintaining recovery ability

### Ordering and Consistency

**LSN Allocation**: Assign monotonically increasing identifiers to records
- Allocate next LSN on each WAL append operation
- Store LSN in record header for self-identification
- Use LSNs to determine operation order during recovery
- Track LSN gaps to detect corruption or truncation
- Support LSN-based range queries and iteration

**Operation Ordering**: Maintain total order of all database modifications
- Serialize all transaction operations through WAL append
- Preserve causal ordering within transactions
- Support concurrent writes with proper synchronization
- Enable time-travel queries using LSN ranges
- Facilitate replication by providing total order

### Log Lifecycle Management

**Append Operations**: Add new records to end of WAL
- Validate record format and checksums before writing
- Allocate LSN for new record
- Write record to WAL file at calculated offset
- Optionally flush to storage based on durability requirements
- Update WAL tail position and metadata

**Truncation**: Remove old WAL records that are no longer needed
- Verify all pages up to checkpoint LSN are persisted
- Truncate WAL file to remove records before checkpoint
- Reset WAL tail to checkpoint LSN
- Update metadata with new checkpoint position
- Reclaim disk space occupied by old records

**Rotation**: Manage WAL file growth and archival
- Create new WAL segment when current file reaches size limit
- Archive old segments for long-term storage or replication
- Maintain segment index for efficient record lookup
- Support time-based retention policies

## Public Functions

### WAL Lifecycle

**create(path: &[u8], allocator: Allocator) -> Result<Wal, Error>**
- **Purpose**: Create a new WAL file for a fresh database
- **Parameters**:
  - path: Filesystem path for WAL file (typically "database.wal")
  - allocator: Memory allocator for internal buffers and structures
- **Returns**: Initialized Wal instance ready for append operations
- **Behavior**:
  - Creates new WAL file with proper header and magic number
  - Initializes LSN counter to 0 (initial state)
  - Allocates internal buffers for record encoding
  - Prepares metadata tracking structures
  - Sets file permissions to prevent accidental deletion
- **Error Conditions**:
  - File creation failure (permissions, disk full, invalid path)
  - Allocation failure for internal structures
  - Disk I/O errors during initialization

**open(path: &[u8], allocator: Allocator) -> Result<Wal, Error>**
- **Purpose**: Open existing WAL file for recovery or continued operation
- **Parameters**:
  - path: Filesystem path to existing WAL file
  - allocator: Memory allocator for internal buffers
- **Returns**: Initialized Wal instance positioned for append
- **Behavior**:
  - Opens WAL file and validates header format
  - Scans file to determine current LSN and position
  - Validates checksums for all records during scan
  - Detects and reports corruption or torn writes
  - Positions file pointer at end for next append
  - Reconstructs metadata from scanned records
- **Error Conditions**:
  - File does not exist (caller should handle by creating new WAL)
  - Invalid WAL format or corrupted header
  - Checksum mismatch in any record
  - LSN gaps or non-monotonic LSN sequence
  - Disk I/O errors during scan

**close(&mut self)**
- **Purpose**: Close WAL file and release resources
- **Behavior**:
  - Flushes any buffered records to storage
  - Syncs file to ensure all writes reach disk
  - Closes file handle
  - Releases internal buffer memory
  - Frees allocator resources
- **Note**: WAL is unusable after close, any subsequent operations fail

### Record Management

**append(&mut self, txn_id: TxnId, operation: &Operation) -> Result<Lsn, Error>**
- **Purpose**: Append a single operation to WAL for a transaction
- **Parameters**:
  - txn_id: Transaction identifier this operation belongs to
  - operation: Operation to append (Put or Delete)
- **Returns**: LSN assigned to this record
- **Behavior**:
  - Allocates next LSN from monotonically increasing counter
  - Encodes operation into WAL record format
  - Calculates checksum for record header and payload
  - Writes record to WAL file at calculated offset
  - Does NOT force fsync (caller controls batching)
  - Updates WAL tail position
  - Returns LSN for caller to track
- **Error Conditions**:
  - LSN overflow (exhausted u64 space)
  - Encoding buffer too small for operation
  - Disk full or write error
  - Invalid operation format
  - WAL file handle closed or invalid

**append_batch(&mut self, operations: &[(TxnId, Operation)]) -> Result<Vec<Lsn>, Error>**
- **Purpose**: Efficiently append multiple operations in a single batch
- **Parameters**:
  - operations: Slice of (txn_id, operation) tuples to append
- **Returns**: Vector of LSNs assigned to each operation (same order as input)
- **Behavior**:
  - Allocates LSN range for all operations at once
  - Encodes all operations into contiguous buffer
  - Writes entire buffer in single write call
  - May optionally fsync after batch based on flag
  - Updates WAL tail position by total batch size
  - Returns LSNs for each operation in sequence
- **Error Conditions**:
  - LSN range overflow
  - Batch encoding exceeds maximum record size
  - Disk full during batch write
  - Partial batch write (detects via bytes written vs expected)
- **Performance Note**: Significantly more efficient than individual append calls for large transactions

**commit(&mut self, txn_id: TxnId) -> Result<Lsn, Error>**
- **Purpose**: Write commit record for transaction, making it durable
- **Parameters**:
  - txn_id: Transaction identifier to commit
- **Returns**: LSN of commit record
- **Behavior**:
  - Allocates next LSN for commit record
  - Encodes commit marker with transaction ID
  - Calculates checksum for commit record
  - Writes commit record to WAL
  - Forces fsync to ensure commit reaches stable storage
  - Updates WAL metadata
  - Returns LSN for checkpoint coordination
- **Error Conditions**:
  - Transaction ID not found or invalid
  - fsync failure (critical - transaction may be lost)
  - Disk full or write error
  - WAL file handle closed
- **Critical**: This function MUST fsync before returning to guarantee durability

**rollback(&mut self, txn_id: TxnId) -> Result<(), Error>**
- **Purpose**: Write rollback record for aborted transaction
- **Parameters**:
  - txn_id: Transaction identifier to roll back
- **Returns**: Empty tuple on success
- **Behavior**:
  - Allocates next LSN for rollback record
  - Encodes rollback marker with transaction ID
  - Writes rollback record to WAL (no fsync needed)
  - Updates WAL metadata to mark transaction as aborted
  - Transaction modifications ignored during recovery
- **Error Conditions**:
  - Transaction ID not found or already committed
  - Write error (non-critical for rollback)

### Recovery and Iteration

**scan_from(&mut self, start_lsn: Lsn) -> Result<RecordIterator, Error>**
- **Purpose**: Create iterator to scan WAL records starting from given LSN
- **Parameters**:
  - start_lsn: LSN to begin scanning from (exclusive)
- **Returns**: Iterator yielding decoded records
- **Behavior**:
  - Seeks WAL file to calculated offset for start_lsn
  - Validates that start_lsn exists in WAL (not beyond tail)
  - Creates iterator state machine for sequential reads
  - Iterator decodes records, validates checksums
  - Returns errors for corrupted records
- **Error Conditions**:
  - start_lsn beyond current WAL tail
  - start_lsn before WAL head (already truncated)
  - File seek error or invalid offset
  - Corrupted record at start position

**recover(&mut self, checkpoint_lsn: Lsn) -> Result<RecoveryResult, Error>**
- **Purpose**: Perform crash recovery by scanning and replaying WAL
- **Parameters**:
  - checkpoint_lsn: LSN of last checkpoint (start recovery from here)
- **Returns**: Recovery result with statistics and recovered transactions
- **Behavior**:
  - Scans WAL from checkpoint_lsn to end
  - Identifies all committed transactions (has commit record)
  - Collects all operations from committed transactions
  - Sorts operations by LSN to ensure correct order
  - Returns operations for caller to apply to database
  - Reports uncommitted transactions found
  - Validates LSN monotonicity during scan
  - Detects and reports corruption
- **Error Conditions**:
  - Checksum corruption in WAL records
  - LSN gap detected (missing records)
  - Non-monotonic LSN sequence
  - File read errors or truncated WAL
  - Incomplete transaction (has operations but no commit or rollback)

### Checkpoint and Truncation

**truncate(&mut self, checkpoint_lsn: Lsn) -> Result<(), Error>**
- **Purpose**: Truncate WAL up to checkpoint, removing unneeded records
- **Parameters**:
  - checkpoint_lsn: LSN up to which to truncate (exclusive)
- **Returns**: Empty tuple on success
- **Behavior**:
  - Validates that all pages before checkpoint_lsn are persisted
  - Seeks WAL file to offset corresponding to checkpoint_lsn
  - Truncates file to remove records before checkpoint
  - Updates WAL head position to checkpoint_lsn
  - Reclaims disk space
  - Updates metadata with new checkpoint position
- **Error Conditions**:
  - Checkpoint LSN beyond current WAL tail
  - Pages not fully persisted (caller must flush first)
  - File truncation failure
  - Disk full or filesystem error
- **Note**: Should be called after Pager flushes all dirty pages

**get_tail_lsn(&self) -> Lsn**
- **Purpose**: Get the LSN of the most recent record in WAL
- **Returns**: Current WAL tail LSN
- **Behavior**: Reads from cached metadata, no I/O

**get_head_lsn(&self) -> Lsn**
- **Purpose**: Get the oldest LSN still present in WAL (not truncated)
- **Returns**: Current WAL head LSN
- **Behavior**: Reads from cached metadata, no I/O

### Utility Functions

**fsync(&mut self) -> Result<(), Error>**
- **Purpose**: Force all buffered WAL writes to stable storage
- **Returns**: Empty tuple on success
- **Behavior**:
  - Calls fsync on WAL file handle
  - Blocks until data reaches disk platter
  - Ensures durability of all records up to tail
- **Error Conditions**:
  - fsync system call failure
  - Disk hardware error
  - File handle closed
- **Use Case**: Manual durability control for batched appends

**size(&self) -> u64**
- **Purpose**: Get current WAL file size in bytes
- **Returns**: File size in bytes
- **Behavior**: Reads from cached metadata or queries file system

**record_count(&self) -> u64**
- **Purpose**: Get total number of records in WAL
- **Returns**: Number of records (from head to tail)
- **Behavior**: Calculated from LSN range

## ACID Properties Enforced by WAL

### Atomicity

**All-or-Nothing Transactions**:
- Every transaction operation is appended to WAL before commit
- Commit record marks the atomic commit point
- During recovery, either all operations are replayed or none
- Incomplete transactions (no commit record) are ignored
- Rollback records explicitly abort transactions

**Failure Scenarios**:
- Crash before commit: Transaction not visible after recovery
- Crash during commit: Either commit record present (transaction visible) or absent (invisible)
- Crash after commit but before page write: Recovery replays from WAL
- Partial WAL write: Checksum detects corruption, record rejected

### Consistency

**Database State Invariants**:
- WAL preserves B+tree structure and constraints
- Primary key uniqueness enforced before WAL append
- Foreign key and other constraints validated before commit
- Checksums detect corruption that could violate invariants

**Recovery Consistency**:
- Replay operations in LSN order (same as original execution order)
- Reject inconsistent operations during recovery
- Validate all checksums before applying operations
- Detect and report violations of integrity constraints

### Isolation

**Transaction Isolation Levels**:
- WAL supports snapshot isolation through LSN tracking
- Readers can observe database state at specific LSN
- Write-write conflicts detected through transaction ID tracking
- Concurrent writes serialized through WAL append ordering

**Serializable Snapshot Isolation**:
- Assign LSN on commit, not on first operation
- Detect conflicts between concurrent transactions
- Abort transactions that would violate serializability
- Provide consistent view of database at commit LSN

### Durability

**Once Committed, Always Recoverable**:
- Commit record written to WAL before commit returns
- fsync ensures commit record reaches stable storage
- Crash recovery replays committed transactions from WAL
- Committed transactions survive power loss, OS crash, application crash

**Durability Failure Modes**:
- fsync failure: Return error to caller, transaction not committed
- Hardware corruption: Detected by checksums, WAL section rejected
- Disk full: Return error before commit, transaction aborted
- Filesystem bugs: Use write verification and checksums

## Invariants Maintained by WAL

### LSN Invariants

**Monotonicity**: LSN values always increase
- Each append receives LSN strictly greater than previous
- LSNs never repeat, never decrease, never have gaps
- LSN 0 is initial state, LSN 1 is first record
- LSN counter persists across WAL truncation (never resets)

**Ordering**: LSNs provide total order of all operations
- For any two records a and b: either LSN(a) < LSN(b) or LSN(a) > LSN(b)
- Operations applied in LSN order during recovery
- Causal ordering within transactions preserved
- Concurrent transactions serialized by LSN order

### Record Invariants

**Record Completeness**: Every record is complete or detectably corrupt
- Record header contains total length for validation
- Checksums cover header and payload
- Partial reads detected by checksum mismatch
- Torn writes rejected during recovery

**Record Validity**: All records in WAL are well-formed
- Operation type field is valid (Put or Delete)
- Key and value lengths match actual payload size
- Transaction ID references active transaction
- Checksum matches calculated value

### File Layout Invariants

**Append-Only Structure**: WAL only grows, never modifies existing data
- Records written sequentially at end of file
- No overwriting or in-place modifications
- Truncation only removes from front (old records)
- File position always increases during normal operation

**LSN to Offset Mapping**: LSN maps to unique file offset
- Given LSN, can calculate file offset (with variable-length encoding)
- Record headers allow forward scanning without index
- Checksums enable corruption detection during scan

### Crash Recovery Invariants

**Replay Produces Consistent State**: Recovery database state is consistent
- All committed transactions fully replayed
- No uncommitted transactions replayed
- Operations replayed in original LSN order
- B+tree invariants preserved during replay
- No orphaned or leaking pages after recovery

**Checkpoint Safety**: Checkpoint only when safe to truncate
- All pages modified before checkpoint LSN are persisted
- No transactions span checkpoint boundary
- Truncation preserves all records needed for recovery
- Recovery can start from checkpoint LSN and produce consistent state

## Module Structure

### Rust Module Organization

**northstar_core::wal**: Top-level WAL module
- **wal::wal**: Main Wal struct and lifecycle functions
- **wal::record**: LogRecord type and encoding/decoding
- **wal::iterator**: RecordIterator for sequential scanning
- **wal::recovery**: Recovery logic and state machine
- **wal::lsn**: LSN type and operations (defined in types module, re-exported)
- **wal::operation**: Operation encoding (Put, Delete)

**Module Hierarchy**:
```
northstar_core
└── wal
    ├── mod.rs (public exports)
    ├── wal.rs (Wal struct and main API)
    ├── record.rs (LogRecord, record header, checksums)
    ├── encode.rs (operation encoding, varint)
    ├── decode.rs (record decoding, validation)
    ├── iterator.rs (RecordIterator for scanning)
    ├── recovery.rs (recovery state machine, replay)
    └── truncate.rs (checkpoint coordination, truncation)
```

### Public API Surface

**Re-exports**: Main WAL module re-exports key types
- Wal (main struct)
- LogRecord (record type for iterator)
- Error types (WalError, etc.)
- Lsn (from types module)

**Usage Pattern**: Typical user code
```rust
use northstar_core::wal::Wal;

// Create or open WAL
let mut wal = Wal::create("data.wal", allocator)?;
// or
let mut wal = Wal::open("data.wal", allocator)?;

// Append operations
let lsn1 = wal.append(txn_id, operation1)?;
let lsn2 = wal.append(txn_id, operation2)?;

// Commit transaction (fsync)
let commit_lsn = wal.commit(txn_id)?;

// Recovery
let recovered = wal.recover(checkpoint_lsn)?;
for operation in recovered.operations {
    // Apply to database
}

// Truncate after checkpoint
wal.truncate(new_checkpoint_lsn)?;
```

### Dependencies

**Internal Dependencies**:
- types module for Lsn, TxnId, Operation types
- error module for Error and WalError types
- checksum module for CRC32C calculation
- Allocator from standard library for memory management

**External Dependencies**:
- Standard library file I/O (std::fs::File)
- Standard library path manipulation (std::path::Path)
- CRC32C library (crc32c or software implementation)

**Used By**:
- Transaction module for durability and recovery
- Pager module for checkpoint coordination
- Recovery module for crash recovery
- Higher-level database API

## Coordination with Pager

### Checkpoint Process

**Two-Phase Checkpoint**:
1. **WAL Scan**: WAL identifies all LSNs with modifications
2. **Pager Flush**: Pager flushes all dirty pages with LSN <= checkpoint
3. **WAL Truncate**: WAL truncates records up to checkpoint LSN
4. **Metadata Update**: Pager updates meta page with new checkpoint LSN

**Liveness Guarantees**:
- WAL never truncates records needed for recovery
- Pager flushes all pages before WAL truncates
- Checkpoint LSN always points to valid WAL record
- Recovery can always start from checkpoint LSN

### Write Ordering

**Before Transaction Commit**:
1. Append operations to WAL (assign LSNs)
2. Append commit record to WAL
3. fsync WAL (ensure durability)
4. Modify database pages
5. Update metadata
6. fsync database file (optional, for performance)

**During Recovery**:
1. Read checkpoint LSN from metadata
2. Scan WAL from checkpoint LSN
3. Replay committed transactions to database
4. Update metadata
5. Truncate WAL (if needed)
6. Resume normal operation

### Lock Coordination

**WAL-Pager Lock Ordering**:
1. Acquire WAL write lock (for append)
2. Append records to WAL
3. Release WAL lock
4. Acquire Pager lock (for page modification)
5. Apply modifications to pages
6. Release Pager lock

**Deadlock Prevention**:
- Always acquire WAL lock before Pager lock
- Never hold both locks simultaneously across I/O operations
- Use timeout or lock hierarchy to prevent cycles

## Performance Considerations

### Append Performance

**Batch Appends**:
- Use append_batch for multi-operation transactions
- Reduces fsync calls (one fsync per transaction, not per operation)
- Minimizes system call overhead
- Improves disk throughput with larger sequential writes

**Group Commit**:
- Multiple transactions can share single fsync
- Delay commit slightly to accumulate more transactions
- Reduces fsync frequency for high-throughput workloads
- Configurable commit delay (safety vs latency trade-off)

### I/O Patterns

**Sequential I/O**:
- WAL writes are always sequential append-only
- Optimizes for disk sequential write throughput
- Avoids seek overhead of random I/O
- Enables write-ahead logging performance benefits

**Buffer Management**:
- Use buffered I/O for record encoding
- Minimize memory allocations with re-usable buffers
- Align writes to disk block size (typically 4KB)
- Use vector I/O (writev) for multi-record batches

### Recovery Performance

**Checkpoint Frequency**:
- More frequent checkpoints reduce recovery time
- Trade-off: more checkpoints = more I/O overhead
- Typical strategy: checkpoint every N transactions or M minutes
- Adaptive checkpointing based on WAL size

**Parallel Recovery**:
- Scan WAL sequentially (single-threaded for I/O efficiency)
- Replay operations in parallel to multiple pages
- Validate that replay produces same final state
- Requires careful coordination and validation

## Error Handling

### Write Errors

**Disk Full**:
- Return error to caller before writing incomplete record
- Transaction fails before commit (safe)
- WAL remains consistent (no partial write)

**fsync Failure**:
- Critical error: transaction may not be durable
- Return error to caller, mark transaction as failed
- Caller may retry or abort
- WAL file may be corrupted (filesystem error)

**Partial Write**:
- Detect by checking bytes written vs expected
- Seek back to position before write
- Return error to caller
- WAL remains consistent

### Read Errors

**Checksum Mismatch**:
- Record is corrupt, reject during recovery
- Skip to next record (if format allows)
- If critical record (commit), recovery fails
- May indicate disk corruption or hardware failure

**LSN Gap**:
- Detected during sequential scan
- May indicate WAL truncation or corruption
- Recovery fails if gap spans committed transaction
- Requires administrator intervention or restore from backup

### Corruption Recovery

**Partial WAL Corruption**:
- Scan WAL from beginning to find first valid record
- If header corrupt, attempt recovery from record body
- If corruption in middle, recovery fails (no gaps allowed)
- May need to restore from backup or last known good state

**Torn Write Detection**:
- Checksum mismatch indicates incomplete write
- Power loss during write leaves partial record
- Reject record during recovery
- Previous record is last valid record

## Security Considerations

### File Permissions

**WAL File Access**:
- Restrictive permissions (read/write owner only)
- Prevent accidental deletion or modification
- Secure from unauthorized access
- Consistent with database file permissions

### Tamper Detection

**Checksum Validation**:
- Detect accidental corruption (hardware errors)
- Detect intentional tampering (malicious modification)
- Strong checksum (CRC32C) provides good protection
- Consider cryptographic hash for higher security (future)

### Audit Trail

**Immutable History**:
- WAL append-only structure provides tamper-evident log
- All modifications recorded with LSN and transaction ID
- Cannot rewrite history without detection
- Supports forensic analysis and auditing

## Future Extensions

### Compression

**Record Compression**:
- Compress operation payloads before writing
- Reduces WAL size for repetitive data
- Trade-off: CPU overhead vs disk savings
- Can be enabled per-database or per-transaction

### Encryption

**WAL Encryption**:
- Encrypt WAL records for data-at-rest protection
- Requires key management infrastructure
- May impact compression and recovery performance
- Optional feature for regulated industries

### Replication

**WAL Shipping**:
- Send WAL records to replica for replication
- Simple: send entire WAL file periodically
- Efficient: stream records as they are appended
- Supports asynchronous and synchronous replication

**Logical Decoding**:
- Decode WAL records into logical operations
- Send logical operations to replicas
- Supports heterogeneous replicas (different storage)
- Enables change data capture (CDC) and streaming integration
