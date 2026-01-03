# WAL Structure Specification

## Purpose

The Wal struct is the core Write-Ahead Log implementation for NorthstarDB. It manages an append-only log file that stores all transaction modifications before they are applied to the database. The Wal struct provides atomicity and durability guarantees by writing operations to stable storage before acknowledging commits. It tracks the current Log Sequence Number (LSN), manages internal buffering for efficient I/O, and coordinates with the Pager for checkpointing and truncation. The Wal struct is the single source of truth for all database modifications and enables crash recovery by replaying committed transactions.

## Types

### Wal

**Description**: Main Write-Ahead Log structure that manages log file, buffering, and LSN tracking. The Wal struct is responsible for creating, opening, appending to, and truncating the WAL file. It maintains internal state to track the current LSN, file position, and write buffering for efficient I/O operations.

**Fields**:

- **file**: File handle - The underlying file handle for the WAL log file. This is the OS file descriptor used for all read and write operations. The file is opened in read-write mode and remains open for the lifetime of the Wal instance. Visibility: private. Invariant: file handle is always valid when Wal is in open state, closed when Wal is dropped or closed explicitly.

- **current_lsn**: u64 - The LSN of the most recently appended record. This counter increases monotonically with each append operation and represents the highest LSN currently in the WAL. LSN 0 indicates no records have been written. Visibility: public read-only via accessor. Invariant: current_lsn never decreases, always increases by 1 with each append, persists across WAL truncation (does not reset).

- **buffer**: Byte slice - Internal write buffer for batched I/O operations. This buffer accumulates WAL records before flushing to disk, reducing the number of system calls. The buffer improves throughput by coalescing small writes into larger, sequential writes. Visibility: private. Invariant: buffer is always allocated with fixed size (64KB), contents are only valid between buffer_pos and buffer.len(), buffer is flushed before direct writes.

- **buffer_pos**: usize - Current write position within the internal buffer. This index tracks where the next record should be written in the buffer. When buffer_pos plus record size exceeds buffer length, the buffer is flushed to disk. Visibility: private. Invariant: buffer_pos is always less than or equal to buffer length, buffer_pos is 0 immediately after flush, buffer_pos increases monotonically between flushes.

- **sync_needed**: Boolean flag indicating whether buffered data needs to be synchronized to stable storage. This flag tracks whether the WAL has unflushed or unsynced data that has not reached durable storage. Visibility: private. Invariant: sync_needed is true when buffer contains data not yet synced, sync_needed is false immediately after sync operation completes.

- **allocator**: Memory allocator - Allocator used for internal buffer allocation and temporary allocations during encoding. This allocator manages all memory owned by the Wal struct, including the write buffer and temporary buffers for record serialization. Visibility: private. Invariant: allocator is always valid, all allocations from allocator are freed before Wal is dropped.

- **file_pos**: usize - Current file position for appending new data. This tracks the end of the WAL file in bytes, representing where the next write should occur. Visibility: private. Invariant: file_pos equals the actual file size, file_pos increases monotonically, file_pos matches the sum of all records written.

**Size**: Not applicable (heap-allocated struct with variable-size fields)

**Alignment**: Natural alignment for the platform (no special requirements)

**Invariants**:
- File handle is valid when Wal is open, closed when Wal is dropped
- current_lsn is monotonic (never decreases)
- buffer_pos never exceeds buffer length
- sync_needed accurately reflects unflushed data state
- file_pos equals the actual file size
- All LSNs in the file are sequential from 1 to current_lsn
- No gaps exist in the LSN sequence
- All records have valid checksums when written

### WalConfig

**Description**: Configuration parameters controlling WAL behavior and performance trade-offs. WalConfig defines immutable settings that affect WAL I/O patterns, durability guarantees, and resource usage.

**Fields**:

- **buffer_size**: usize - Size of internal write buffer in bytes. Larger buffers reduce system call overhead but increase memory usage. Typical values range from 64KB to 1MB. Default: 64KB (65536 bytes). Invariant: buffer_size is at least 4096 (one page), buffer_size is a multiple of page size.

- **sync_strategy**: SyncStrategy enum - Durability strategy controlling when fsync is called. Determines the trade-off between durability and latency. Default: SyncStrategy::OnCommit. Invariant: sync_strategy is always one of the defined variants, never changes after Wal creation.

- **autocheckpoint_threshold**: usize - Number of records after which automatic checkpoint is suggested. This is a hint to the higher-level transaction system to trigger checkpointing. Default: 10000 records. Invariant: threshold is positive, zero disables autocheckpoint suggestions.

- **max_wal_size**: usize - Maximum WAL file size before rotation is recommended. When the WAL file exceeds this size, the implementation may suggest creating a new WAL segment. Default: 100MB (104857600 bytes). Invariant: max_wal_size is at least the buffer size.

**Invariants**:
- All configuration values are positive
- buffer_size is page-aligned (multiple of 4096)
- sync_strategy is valid
- Configuration is immutable after Wal creation

### SyncStrategy

**Description**: Enum defining when WAL data is synchronized to stable storage (fsync). This controls the durability vs latency trade-off for transaction commits.

**Variants**:
- **OnCommit**: Synchronize WAL on every commit operation. Provides maximum durability at the cost of higher latency. This is the default and safest mode.
- **Batch**: Accumulate multiple commits before synchronizing. Improves throughput but risks losing the most recent commits on crash.
- **None**: Never automatically synchronize. Caller must explicitly call sync. Maximum performance but requires manual durability management.

**Invariants**:
- Once chosen, sync strategy does not change
- OnCommit mode always calls fsync before commit returns
- Batch mode calls fsync after N commits (configurable)
- None mode never calls fsync automatically

### WalState

**Description**: Internal state machine tracking the operational status of the Wal instance. The state ensures that operations are only performed when the WAL is in a valid state.

**Variants**:
- **Closed**: WAL is not open, file handle is invalid. No operations are valid except open. This is the initial state before creation and the state after close.
- **Open**: WAL is open and ready for normal operations. Append, sync, truncate, and scan operations are valid.
- **Recovering**: WAL is being opened and scanned for crash recovery. Transitional state during open operation. Only read operations are valid.
- **Error**: WAL encountered an unrecoverable error. Most operations are invalid. WAL should be closed and recreated.

**Invariants**:
- State transitions are one-way (Closed -> Open -> Error -> Closed)
- Recovering state is only transitional during open
- Only Open state allows modifications (append, truncate)
- Error state prevents all operations except close

### ReplayResult

**Description**: Result structure returned by WAL recovery operations. Contains the list of recovered commit records along with metadata about the recovery process.

**Fields**:

- **commit_records**: Dynamic array of CommitRecord - All committed transactions found during WAL replay. These records contain the mutations that need to be applied to the database. Visibility: public. Invariant: all records have valid checksums, all records have commit LSN greater than checkpoint LSN, records are in LSN order.

- **last_lsn**: u64 - The highest LSN found during replay. This represents the tail of the WAL after recovery completes. Visibility: public. Invariant: last_lsn is greater than or equal to checkpoint LSN, last_lsn equals the number of valid records found.

- **last_checkpoint_txn_id**: u64 - Transaction ID of the last checkpoint record found. Used by the Pager to update metadata. Visibility: public. Invariant: txn_id is 0 if no checkpoint found, txn_id matches a committed transaction.

- **truncate_lsn**: Optional u64 - If present, the LSN up to which the WAL should be truncated. This comes from cartridge meta records. Visibility: public. Invariant: truncate_lsn is within the valid LSN range, truncate_lsn is greater than or equal to last checkpoint.

**Invariants**:
- commit_records may be empty (no committed transactions)
- last_lsn is 0 only if WAL is empty
- truncate_lsn is None if no truncation request found
- All commit records have valid checksums

### RecordHeader

**Description**: Fixed-size header that precedes every WAL record. The header contains metadata for identifying, validating, and interpreting the record. Each record in the WAL begins with this header structure.

**Fields**:

- **magic**: u32 - Magic number for record identification (0x4C4F4752 = "LOGR"). This 4-byte value validates that the data is a valid WAL record. Invariant: magic is always 0x4C4F4752 in valid records.

- **record_version**: u16 - Record format version. Allows format evolution while maintaining backward compatibility. Invariant: record_version is 0 for V0 format.

- **record_type**: u16 - Type of record (commit=0, checkpoint=1, cartridge_meta=2). Indicates how to interpret the payload. Invariant: record_type is one of the defined valid types (0, 1, 2).

- **header_len**: u16 - Length of the header in bytes. Fixed at 40 bytes for V0 format. Invariant: header_len is 40 in V0, allows future expansion.

- **flags**: u16 - Bit flags for record attributes. Bit 1 indicates payload contains inline values. Invariant: only defined flag bits are set, reserved bits are zero in V0.

- **txn_id**: u64 - Transaction identifier associated with this record. Links records to transactions. Invariant: txn_id is valid for the record type, 0 for non-transactional records.

- **prev_lsn**: u64 - LSN of the previous record in the WAL. Enables forward scanning and validation. Invariant: prev_lsn is current_lsn at time of append, 0 for first record.

- **payload_len**: u32 - Length of the record payload in bytes. Specifies how many bytes follow the header. Invariant: payload_len is non-negative, payload_len plus header fits within file.

- **header_crc32c**: u32 - CRC32C checksum of the header fields. Detects header corruption. Invariant: checksum matches calculated value, checksum field is zero during calculation.

- **payload_crc32c**: u32 - CRC32C checksum of the payload data. Detects payload corruption. Invariant: checksum matches calculated value of payload bytes.

**Size**: 40 bytes (4+2+2+2+2+8+8+4+4+4)

**Alignment**: 4-byte aligned (natural for u32 fields)

**Invariants**:
- Magic number is always "LOGR" (0x4C4F4752)
- Header checksum validates all header fields
- Payload checksum validates the payload data
- Payload length is consistent with actual data
- Record version is supported by the implementation
- Flags only use defined bits

### RecordTrailer

**Description**: Fixed-size trailer that follows every WAL record. The trailer provides a second validation point and allows backward scanning of the WAL.

**Fields**:

- **magic2**: u32 - Second magic number for trailer identification (0x52474F4C = "RGOL", "LOGR" reversed). Invariant: magic2 is always 0x52474F4C in valid records.

- **total_len**: u32 - Total length of the entire record (header + payload + trailer). Used for backward scanning and validation. Invariant: total_len equals header_len + payload_len + trailer size.

- **trailer_crc32c**: u32 - CRC32C checksum of trailer fields. Detects trailer corruption. Invariant: checksum matches calculated value, checksum field is zero during calculation.

**Size**: 12 bytes (4+4+4)

**Alignment**: 4-byte aligned

**Invariants**:
- Magic2 is always "RGOL" (0x52474F4C)
- Total length is consistent with header and payload
- Trailer checksum validates correctly
- Trailer immediately follows payload

### RecordType

**Description**: Enum defining the types of records stored in the WAL. Each record type has a specific payload format and semantics.

**Variants**:
- **Commit** (value 0): Transaction commit record containing mutations. This is the most common record type, storing all key-value operations from a transaction.
- **Checkpoint** (value 1): Checkpoint marker record. Indicates that all pages before a certain LSN have been persisted and the WAL can be truncated.
- **CartridgeMeta** (value 2): AI memory cartridge metadata record. Stores structured memory information for the AI intelligence layer.

**Invariants**:
- Record type values are stable and never reused
- Unknown record types should be rejected during recovery
- Record type determines payload format

## Functions

### open(path: &[u8], allocator: Allocator) -> Result<Wal, Error>

**Purpose**: Open an existing WAL file for recovery or continued operation. Scans the file to determine the current LSN and validate all records.

**Parameters**:
- path: Byte slice containing the filesystem path to the WAL file
- allocator: Memory allocator for internal buffers

**Returns**: Initialized Wal instance positioned for append

**Algorithm**:
1. Open file at path in read-write mode
2. Get current file size
3. If file size is greater than zero, scan entire file to find highest LSN
4. During scan, validate checksums of all records
5. If any record fails validation, return corruption error
6. Allocate internal buffer (64KB)
7. Initialize Wal struct with file, current_lsn, buffer, and file position
8. Position file pointer at end for next append

**Error Conditions**:
- FileNotFound: File does not exist at path
- PermissionDenied: Insufficient permissions to open file
- InvalidChecksum: Corrupted record found during scan
- InvalidMagic: WAL header has wrong magic number
- AllocationFailed: Buffer allocation failed

**Concurrency**: Single-threaded during open, caller must ensure no other threads access the WAL during open

### create(path: &[u8], allocator: Allocator) -> Result<Wal, Error>

**Purpose**: Create a new WAL file for a fresh database. Initializes empty WAL with LSN starting at 0.

**Parameters**:
- path: Byte slice containing the filesystem path for the new WAL file
- allocator: Memory allocator for internal buffers

**Returns**: Initialized Wal instance ready for first append

**Algorithm**:
1. Create new file at path, truncate if exists
2. Open file in read-write mode
3. Allocate internal buffer (64KB)
4. Initialize Wal struct with current_lsn = 0, buffer_pos = 0, file_pos = 0
5. Return Wal instance ready for append

**Error Conditions**:
- PermissionDenied: Cannot create file at path
- DiskFull: Insufficient space to create file
- AllocationFailed: Buffer allocation failed

**Concurrency**: Single-threaded during create, caller must ensure no other threads access the WAL during create

### close(&mut self)

**Purpose**: Close WAL file and release all resources. Ensures all buffered data is flushed before closing.

**Algorithm**:
1. Flush any remaining data in buffer to disk
2. Call fsync to ensure all writes reach stable storage
3. Close file handle
4. Free internal buffer memory
5. Mark Wal as closed (state becomes Closed)

**Error Conditions**: Errors are swallowed during close (best-effort cleanup)

**Concurrency**: Not thread-safe, caller must ensure exclusive access

### append_commit_record(&mut self, record: CommitRecord) -> Result<u64, Error>

**Purpose**: Append a commit record containing transaction mutations to the WAL. This is the primary method for persisting transaction changes.

**Parameters**:
- record: Commit record containing transaction ID, root page ID, and mutations

**Returns**: LSN assigned to this record

**Algorithm**:
1. Validate record checksum (reject if invalid)
2. Serialize commit record into byte buffer
3. Calculate payload CRC32C checksum
4. Create RecordHeader with commit type, transaction ID, previous LSN
5. Calculate header CRC32C checksum
6. Call internal append_record_with_trailer with header and serialized data
7. Increment current_lsn
8. Return new LSN to caller

**Error Conditions**:
- InvalidChecksum: Record checksum validation failed
- EncodingFailed: Serialization failed
- DiskFull: Write operation failed
- LsnOverflow: LSN counter would exceed u64::MAX

**Concurrency**: Caller must ensure exclusive write access during append

### sync(&mut self) -> Result<(), Error>

**Purpose**: Force all buffered WAL writes to stable storage. Ensures durability of all records up to current LSN.

**Algorithm**:
1. If buffer has data (buffer_pos > 0), flush buffer to disk
2. Call fsync on file handle
3. Block until data reaches disk platter
4. Clear sync_needed flag
5. Return success

**Error Conditions**:
- IoError: fsync system call failed
- DiskError: Hardware error preventing sync

**Concurrency**: Caller must ensure exclusive access during sync

### get_current_lsn(&self) -> u64

**Purpose**: Get the LSN of the most recent record in the WAL.

**Returns**: Current LSN value

**Algorithm**: Return current_lsn field directly (no I/O)

**Concurrency**: Thread-safe for reads if no concurrent writes

### replay_from(&mut self, start_lsn: u64, allocator: Allocator) -> Result<ReplayResult, Error>

**Purpose**: Scan WAL from a given LSN and recover all commit records. Used for crash recovery to replay committed transactions.

**Parameters**:
- start_lsn: LSN to begin scanning from (exclusive)
- allocator: Allocator for allocating recovered records

**Returns**: ReplayResult containing all committed transactions and metadata

**Algorithm**:
1. Seek file to beginning (offset 0)
2. Initialize result structure with empty commit_records list
3. Iterate through records sequentially
4. For each record, read and validate header
5. Validate header and payload checksums
6. Skip records with LSN less than start_lsn
7. For commit records (type 0), deserialize and add to result
8. For checkpoint records (type 1), update last_checkpoint_txn_id
9. For cartridge_meta records (type 2), update truncate_lsn
10. Stop when file end is reached or invalid record found
11. Return result with all recovered commit records

**Error Conditions**:
- ChecksumMismatch: Corrupted record found
- LsnGap: Non-sequential LSNs detected
- InvalidRecord: Record format is invalid
- AllocationFailed: Cannot allocate memory for results

**Concurrency**: Not thread-safe, caller must ensure exclusive access

### truncate(&mut self, keep_lsn: u64) -> Result<(), Error>

**Purpose**: Truncate WAL up to a specific LSN, removing old records that are no longer needed for recovery. Called after checkpoint to reclaim disk space.

**Parameters**:
- keep_lsn: LSN up to which to truncate (exclusive - records with LSN >= keep_lsn are kept)

**Algorithm**:
1. Flush any buffered data
2. Sync to ensure all data is on disk
3. Scan file from beginning to find record with LSN = keep_lsn
4. Once found, truncate file at that position
5. If keep_lsn not found (beyond current tail), truncate entire file
6. Rescan file to update current_lsn
7. Reset file position to new end
8. Return success

**Error Conditions**:
- InvalidLsn: keep_lsn is beyond current WAL tail
- TruncateFailed: File truncation operation failed
- IoError: Disk I/O error during operation

**Concurrency**: Not thread-safe, caller must ensure exclusive access

## Invariants

### Structural Invariants

**File Handle Validity**: The file handle is always valid when Wal is in Open state
- File is opened in read-write mode
- File handle is closed when Wal is dropped or explicitly closed
- All operations check file handle validity before use

**Buffer Consistency**: Internal buffer state is always consistent
- buffer_pos never exceeds buffer length
- Buffer contents between 0 and buffer_pos contain valid data
- Buffer is flushed before direct file writes bypass buffer
- Buffer is reset (buffer_pos = 0) after flush

**LSN Monotonicity**: LSN counter always increases
- current_lsn never decreases
- LSN increments by exactly 1 for each append
- LSN never resets, even after WAL truncation
- LSN sequence is contiguous with no gaps

### Data Integrity Invariants

**Checksum Validation**: All records have valid checksums when written
- Header CRC32C covers all header fields
- Payload CRC32C covers all payload bytes
- Trailer CRC32C covers all trailer fields
- Checksum fields are zeroed during calculation

**Magic Number Verification**: All records have valid magic numbers
- Header magic is always "LOGR" (0x4C4F4752)
- Trailer magic is always "RGOL" (0x52474F4C)
- Magic numbers are validated on read
- Invalid magic numbers cause read failure

**Record Completeness**: Records are either complete or detectably corrupt
- Payload length matches actual data size
- Total length in trailer matches header + payload + trailer
- Incomplete records are detected by checksum mismatch
- Truncated records are detected by length validation

### Operational Invariants

**Append-Only**: WAL never modifies existing data
- All writes are at end of file
- No in-place modifications of existing records
- file_pos always increases during normal operation
- Truncation only removes from beginning

**Durability Tracking**: sync_needed accurately reflects unflushed state
- sync_needed is set when data is written to buffer
- sync_needed is cleared after successful sync
- Buffer flush does not clear sync_needed (only fsync does)
- Caller can check sync_needed to determine if sync is required

**Position Tracking**: file_pos always matches actual file size
- file_pos equals file size when buffer is empty
- file_pos equals file size minus buffer_pos when buffer has data
- file_pos is updated after each flush
- file_pos is updated after each direct write

## Dependencies

**Uses**:
- types module for Lsn, TxnId types
- txn module for CommitRecord, Mutation types
- error module for Error, WalError types
- checksum module for CRC32C calculation
- Standard library file I/O (std::fs::File)
- Standard library allocator for memory management

**Used by**:
- Transaction module for commit durability
- Pager module for checkpoint coordination
- Recovery module for crash recovery
- Higher-level database API

## Rust Implementation Guidance

### Module Structure

The Wal struct and related types should be organized as follows:

```
northstar_core::wal
├── mod.rs (public exports)
├── wal.rs (Wal struct and main API)
├── header.rs (RecordHeader, RecordTrailer)
├── config.rs (WalConfig, SyncStrategy, WalState)
├── replay.rs (ReplayResult, recovery logic)
└── record.rs (RecordType enum)
```

### Type Definitions

**Wal Struct**: Use heap-allocated fields for buffer and file handle
```rust
pub struct Wal {
    file: std::fs::File,
    current_lsn: u64,
    buffer: Vec<u8>,  // Fixed-size buffer
    buffer_pos: usize,
    sync_needed: bool,
    file_pos: usize,
}
```

**Buffer Allocation**: Pre-allocate buffer with exact capacity
```rust
let buffer = Vec::with_capacity(config.buffer_size);
```

**RecordHeader**: Use #[repr(C)] for binary format compatibility
```rust
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RecordHeader {
    pub magic: u32,
    pub record_version: u16,
    pub record_type: u16,
    pub header_len: u16,
    pub flags: u16,
    pub txn_id: u64,
    pub prev_lsn: u64,
    pub payload_len: u32,
    pub header_crc32c: u32,
    pub payload_crc32c: u32,
}
```

**RecordTrailer**: Use #[repr(C)] for binary format compatibility
```rust
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RecordTrailer {
    pub magic2: u32,
    pub total_len: u32,
    pub trailer_crc32c: u32,
}
```

### Concurrency

**Pattern**: Wal is NOT thread-safe by design
- Use Mutex<Wal> if concurrent access is needed
- Higher-level transaction layer manages locking
- Single writer assumption simplifies implementation
- Readers can use separate Wal instance for scanning

**Future Enhancement**: Consider RwLock for read-heavy workloads
- Multiple readers can scan WAL concurrently
- Single writer for append operations
- Use RwLock<Wal> for read-write lock pattern

### Key Decisions

**Owned Buffer vs Arena**: Use Vec<u8> for buffer ownership
- Simpler lifetime management
- Easy to resize if needed (though fixed in V0)
- Clear ownership semantics

**Buffer Size**: 64KB default balances throughput and memory
- Large enough to amortize system call overhead
- Small enough to avoid excessive memory usage
- Page-aligned (16 x 4KB pages)

**Checksum Algorithm**: CRC32C provides good error detection
- Fast hardware acceleration on modern CPUs
- Standard for storage systems
- Catches single-bit and multi-bit errors

**LSN as u64**: Direct u64 field instead of Lsn wrapper
- Simpler arithmetic for increment
- Can convert to Lsn type at API boundaries
- Matches on-disk format (raw u64)

### Implementation Notes

1. **Buffer Flush Strategy**: Flush buffer when record doesn't fit
   - Calculate record size before encoding
   - If buffer_pos + record_size > buffer.len(), flush first
   - For records larger than buffer, write directly to file

2. **Direct Write for Large Records**: Bypass buffer for oversized records
   - If record size exceeds buffer capacity, write directly
   - Use pwrite_all with file_pos for atomic write
   - Update file_pos after write completes

3. **LSN Allocation**: Increment after successful append
   - Allocate LSN (current_lsn + 1) before encoding
   - Write record with allocated LSN
   - Update current_lsn only after write succeeds
   - On error, do not increment current_lsn

4. **Checksum Calculation**: Zero checksum field during calculation
   - Create temporary copy with checksum field set to 0
   - Calculate CRC32C over the zeroed copy
   - Store result in checksum field
   - Reader validates with same algorithm

5. **Recovery Scanning**: Use pread for sequential scan without affecting file_pos
   - Read header at each position
   - Validate header checksum
   - Calculate next position from header + payload + trailer
   - Stop on invalid record or end of file

6. **Truncation Safety**: Sync before truncating
   - Flush all buffered data
   - Call fsync to ensure data reaches disk
   - Seek to truncate position
   - Call set_len() to truncate file
   - Verify file size after truncate

### Testing Strategy

**Unit tests needed for**:
- Wal::create creates new WAL with LSN 0
- Wal::open finds correct current_lsn from existing file
- append_commit_record increments LSN correctly
- Buffer flushes correctly when full
- Direct write works for oversized records
- sync() calls fsync and clears sync_needed
- get_current_lsn returns correct value
- replay_from recovers all commit records
- replay_from stops at checksum error
- truncate removes records before keep_lsn
- truncate preserves records after keep_lsn
- close flushes and syncs before closing

**Property tests for**:
- LSN sequence is contiguous (no gaps) after multiple appends
- Checksum validation rejects corrupted records
- Round-trip write/read produces identical records
- Truncate + recover produces same state as original
- Buffer flush preserves all data
- Multiple commits produce sequential LSNs

**Integration scenarios**:
- Create WAL, append 1000 records, close, reopen, verify LSN
- Append records, crash (kill process), recover, verify data
- Append records, truncate, reopen, verify only kept records
- Concurrent writes (if using Mutex) produce valid LSN sequence
- Large transaction (many mutations) writes correctly
- Recovery after power failure (simulate with truncation)
