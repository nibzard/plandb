# WAL Open Operation

## Purpose

The WAL open operation is responsible for opening an existing Write-Ahead Log file, validating its integrity, determining the current Log Sequence Number (LSN), and positioning the WAL for continued operation or crash recovery. This operation handles detection of recovery mode, validation of existing records, scanning to find the highest LSN, and preparing the WAL state for appending new records or replaying existing ones. The open process must handle various error conditions gracefully, including corrupted files, missing files, checksum mismatches, and incomplete records from crashes.

## File Opening Sequence

### Step 1: Path Validation

**Parse Path**: Examine the provided path string to verify it's a valid filesystem path

**Path Validation**:
- Path is not empty
- Path is within maximum length limits
- Path characters are valid for the filesystem
- Path is properly formatted (no invalid sequences)

**Special Case Detection**: No special cases for WAL (unlike Pager's :memory:)
- WAL always requires a file path
- No in-memory WAL mode in V0

**Rationale**: WAL is always file-based for durability, even if database is in-memory

### Step 2: Open File Handle

**Open File**: Open the WAL file with read-write access

**File Open Parameters**:
- Path from parameter
- Mode: Read and write access required
- Create: Do not create if does not exist (only open existing)
- Share mode: Platform-dependent (typically allow sharing)

**Error Conditions**:
- File does not exist: Return file not found error (caller should create new WAL)
- Permission denied: Return permission error
- Directory instead of file: Return inappropriate file type error
- Already open by exclusive process: Return sharing violation

**Success**: File handle is valid and positioned at start of file

**Rationale**: Read-write access needed for both recovery scanning and future appends

### Step 3: Query File Size

**Get File Size**: Determine total size of WAL file in bytes

**Purpose**: Used to detect empty WAL and size-based validation

**Operation**: Query file end position (seek to end, tell position)

**Validation**: File size is reasonable
- File size may be zero (newly created WAL with no records)
- File size may be any positive value
- File size is used in subsequent scanning logic

**Rationale**: Empty WAL is valid (LSN 0, no records), non-empty needs scanning

### Step 4: Check for Empty WAL

**Empty Detection**: Determine if WAL file has any records

**Check**: If file size equals zero, WAL is empty

**Behavior for Empty WAL**:
- Set current_lsn to 0 (no records written)
- Skip file scanning (no records to validate)
- Position file pointer at beginning
- Initialize buffer as empty
- Return WAL instance ready for first append

**Rationale**: Empty WAL is valid initial state, no recovery needed

**Success**: WAL is open with LSN 0, ready for first record

### Step 5: Scan WAL for Highest LSN (Non-Empty WAL)

**Scan Operation**: Scan entire WAL file to find highest LSN and validate records

**Scanning Process**:
- Seek to beginning of file (offset 0)
- Initialize file_pos to 0
- Initialize current_lsn to 0
- Loop while file_pos < file_size:
  - Read RecordHeader at file_pos
  - Validate header magic number (0x4C4F4752 = "LOGR")
  - Validate header checksum
  - Extract payload_len from header
  - Calculate record_size = RecordHeader.SIZE + payload_len + RecordTrailer.SIZE
  - Validate file_pos + record_size <= file_size (record fits in file)
  - Read payload at file_pos + RecordHeader.SIZE
  - Validate payload checksum against header.payload_crc32c
  - Read RecordTrailer at file_pos + RecordHeader.SIZE + payload_len
  - Validate trailer magic number (0x52474F4C = "RGOL")
  - Validate trailer checksum
  - Increment current_lsn (this record is valid)
  - Update file_pos += record_size
  - Continue to next record

**Validation Checks**:
- Header magic number must be "LOGR"
- Header checksum must validate
- Trailer magic number must be "RGOL"
- Trailer checksum must validate
- Payload checksum must match header
- Record must fit within file bounds
- LSN sequence is contiguous (1, 2, 3, ...)

**Error Handling**:
- Invalid magic: Return corruption error
- Checksum mismatch: Return corruption error
- Record exceeds file bounds: Return corruption error
- Incomplete record at end: Stop scanning, return last valid LSN

**Success**: current_lsn contains the highest valid LSN found

**Rationale**: Scanning validates all records and determines WAL state

### Step 6: Detect Recovery Mode

**Recovery Detection**: Determine if WAL needs recovery processing

**Detection Logic**:
- Recovery is needed if WAL has records (current_lsn > 0)
- Recovery is needed if database may not have applied all WAL records
- Recovery is triggered by caller based on WAL state

**Recovery Indicators**:
- WAL has records but database page state is unknown
- Checkpoint LSN in database is less than WAL tail LSN
- Previous shutdown was not clean (no shutdown marker)

**Behavior**:
- WAL open operation does NOT perform recovery itself
- WAL open operation validates records and returns current LSN
- Caller (Db layer) decides whether to call recover()
- WAL is positioned for append or recovery as caller chooses

**Rationale**: Separation of concerns - WAL handles file operations, caller handles recovery logic

### Step 7: Allocate Internal Buffer

**Buffer Allocation**: Allocate write buffer for efficient I/O

**Allocation**:
- Allocate buffer with size 64KB (65536 bytes)
- Use aligned allocation if available for I/O efficiency
- Initialize buffer_pos to 0 (empty buffer)
- Store allocator reference for later deallocation

**Buffer Configuration**:
- Fixed size: 64KB (configurable in future versions)
- Alignment: Natural alignment or page-aligned
- Initial state: Empty (buffer_pos = 0)

**Error Conditions**:
- Allocation failed: Return allocation error
- Out of memory: Return out-of-memory error

**Success**: Buffer is allocated and ready for writes

**Rationale**: Buffering improves throughput by batching small writes

### Step 8: Initialize WAL State

**State Initialization**: Create Wal struct with all fields

**Field Initialization**:
- file: Set to opened file handle
- current_lsn: Set to value from scan (0 if empty, highest LSN if non-empty)
- buffer: Set to allocated buffer from Step 7
- buffer_pos: Set to 0 (empty buffer)
- sync_needed: Set to false (no unflushed data yet)
- allocator: Set to allocator from parameter
- file_pos: Set to file size (position for next append)

**Invariants**: All fields are valid and consistent at this point

**State**: WAL is in Open state, ready for operations

### Step 9: Position File Pointer

**File Positioning**: Move file pointer to end for next append

**Seek Operation**: Seek to file size (end of file)

**Purpose**: Prepare for next append operation

**Behavior**:
- File pointer is at end of file
- Next write will append new record
- File position matches file_pos field

**Rationale**: WAL is append-only, always write at end

### Step 10: Return WAL Instance

**Complete**: Return fully initialized WAL instance to caller

**State**: WAL is ready for use
- File handle is open and positioned at end
- current_lsn reflects highest record in WAL
- Buffer is allocated and empty
- All records have been validated
- WAL can be used for append or recovery operations

**Caller Options**:
- Begin appending new records
- Call replay_from() for crash recovery
- Call truncate() if checkpoint completed
- Close WAL if shutting down

## Validation Checks

### File Existence and Accessibility

**Check**: WAL file must exist at specified path

**Validation**:
- File open operation succeeds
- Path refers to a regular file (not directory)
- File has read permission
- File has write permission

**Failure**: Return appropriate file system error

**Note**: Caller is responsible for creating WAL if file doesn't exist

### File Size Validation

**Check**: File size must be reasonable

**Validation**:
- File size is zero or positive
- File size may be zero (empty WAL is valid)
- File size is used to determine if scanning is needed

**Failure**: Return file system error if size query fails

### Magic Number Validation

**Check**: Record headers must contain correct magic number

**Validation**:
- First 4 bytes of record header equal 0x4C4F4752 ("LOGR")
- Trailer magic equals 0x52474F4C ("RGOL")

**Failure**: Return corruption error

### Checksum Validation

**Check**: All checksums must be valid

**Validation**:
- Header checksum recalculated and matches stored value
- Payload checksum recalculated and matches stored value
- Trailer checksum recalculated and matches stored value
- All checksums use CRC32C algorithm

**Failure**: Return corruption error

### Record Completeness Validation

**Check**: All records must be complete within file bounds

**Validation**:
- Record header + payload + trailer fits within file
- No truncated records at end of file
- Payload length matches actual data size

**Failure**: Stop scanning at incomplete record, return last valid LSN

### LSN Sequence Validation

**Check**: LSNs must be contiguous and monotonic

**Validation**:
- LSNs increase by 1 for each record (1, 2, 3, ...)
- No gaps in LSN sequence
- No duplicate LSNs

**Failure**: Return corruption error (gap detected)

## Error Conditions

### File System Errors

**File Not Found**: WAL file does not exist at specified path
- **Cause**: File was deleted, never created, or wrong path
- **Error**: File not found error from OS
- **Recovery**: Caller should create new WAL with Wal::create()

**Permission Denied**: Insufficient permissions to access file
- **Cause**: Read or write permission not granted
- **Error**: Permission denied error from OS
- **Recovery**: User must fix file permissions

**Inappropriate File Type**: Path refers to directory or special file
- **Cause**: Path is a directory, symbolic link, or device file
- **Error**: Inappropriate file type error from OS
- **Recovery**: User must provide correct file path

**Sharing Violation**: File is locked exclusively by another process
- **Cause**: Another process has exclusive access
- **Error**: Platform-specific sharing violation error
- **Recovery**: Close other process or open in shared mode

### Corruption Errors

**Invalid Magic Number**: Record header magic number is wrong
- **Cause**: File is not a valid WAL or is corrupted
- **Detection**: First 4 bytes don't match 0x4C4F4752
- **Error**: Invalid magic error
- **Recovery**: WAL is corrupt, cannot recover; restore from backup or create new WAL

**Checksum Mismatch**: Record checksum doesn't match
- **Cause**: Record header, payload, or trailer was corrupted
- **Detection**: Recalculated checksum differs from stored value
- **Error**: Checksum mismatch error
- **Recovery**: WAL is corrupt from this point forward; earlier records may be valid

**Incomplete Record**: Record at end of file is truncated
- **Cause**: System crashed during WAL write
- **Detection**: Record header + payload + trailer exceeds file size
- **Error**: Not an error - treat as end of valid WAL
- **Recovery**: Use last complete record as WAL tail; lost data is after that record

**LSN Gap**: Non-contiguous LSN sequence detected
- **Cause**: WAL file was truncated or records are missing
- **Detection**: LSNs are not sequential (1, 2, 3, ...)
- **Error**: LSN gap error
- **Recovery**: WAL is corrupt; cannot guarantee consistency

### Allocation Errors

**Buffer Allocation Failed**: Cannot allocate internal buffer
- **Cause**: Out of memory or allocator failure
- **Error**: Allocation error
- **Recovery**: System out of memory; free memory or increase available memory

## Recovery Mode Operation

### Recovery Detection

**When Recovery is Needed**:
- WAL exists and has records (current_lsn > 0)
- Database may not have applied all WAL records
- Previous shutdown was not clean
- Checkpoint LSN is less than WAL tail LSN

**How WAL Detects Recovery**:
- WAL open does NOT automatically trigger recovery
- WAL open validates records and returns current LSN
- Caller (Db layer) compares WAL LSN with database state
- Caller decides whether recovery is needed

**Rationale**: Separation of concerns - WAL handles file, caller handles recovery

### Recovery Steps (Caller Responsibility)

**Step 1: Determine Checkpoint LSN**
- Read database meta page to get last checkpoint LSN
- Checkpoint LSN indicates where recovery should start
- If checkpoint LSN is 0, recover from beginning of WAL

**Step 2: Replay WAL from Checkpoint**
- Call Wal::replay_from(checkpoint_lsn) to get committed transactions
- Replay collects all commit records after checkpoint LSN
- Only committed transactions are included
- Uncommitted transactions are ignored

**Step 3: Apply Transactions to Database**
- For each recovered commit record, apply mutations to database
- Update B+tree with put and delete operations
- Update database pages in memory
- Ensure all operations are applied in LSN order

**Step 4: Flush Database Pages**
- After replay, flush all dirty pages to disk
- Ensure database state is persistent
- Sync database file to disk

**Step 5: Update Checkpoint LSN**
- Update database meta page with new checkpoint LSN
- Checkpoint LSN should equal WAL tail LSN
- Write meta page to disk (both copies)
- Sync database file

**Step 6: Truncate WAL (Optional)**
- After database is persisted, WAL can be truncated
- Truncate up to new checkpoint LSN
- Reclaims disk space
- WAL is now ready for new appends

### Clean Shutdown Detection

**How to Detect Clean Shutdown**:
- During normal shutdown, write a shutdown marker to WAL
- Shutdown marker is a special record type (future extension)
- On open, check if shutdown marker exists at end of WAL
- If marker present, shutdown was clean (no recovery needed)
- If marker absent, shutdown was dirty (recovery needed)

**Current V0 Behavior**:
- No shutdown marker in V0 format
- Caller uses heuristics to determine recovery need
- Compare checkpoint LSN with WAL tail LSN
- If different, recovery is needed

**Future Enhancement**:
- Add shutdown marker record type
- Write shutdown marker on clean close
- Validate shutdown marker on open
- Skip recovery if marker present

## WAL File Lifecycle

### Creation

**When WAL Files are Created**:
- When a new database is created (Db::create)
- When a database is opened without existing WAL
- Explicitly by caller when needed

**Creation Process**:
- Wal::create() creates new empty WAL file
- File is truncated if it exists
- LSN starts at 0
- File is ready for first append

**File Naming Conventions**:
- Default: Database path with ".wal" extension
- Example: "mydb.db" -> "mydb.db.wal"
- Caller can specify custom path
- WAL file must be in same directory as database for atomic rename operations

**Directory Structure Requirements**:
- WAL file directory must exist
- Directory must have write permission
- Sufficient disk space for WAL growth
- Same filesystem as database file (for atomic operations)

### Growth

**How WAL Files Grow**:
- Each append increases file size
- Records are appended to end of file
- File grows monotonically during normal operation
- No in-place modifications

**Growth Rate**:
- Each commit record adds header + payload + trailer
- Typical record size: 40 (header) + mutation_size + 12 (trailer)
- For 1000 operations: ~52KB + operation data
- WAL can grow to hundreds of MB or GB

**Monitoring WAL Size**:
- Caller should monitor WAL file size
- Trigger checkpoint when WAL exceeds threshold
- Typical threshold: 10MB to 100MB
- Prevents unbounded WAL growth

### Checkpointing and Truncation

**When WAL Files are Truncated**:
- After checkpoint completes successfully
- All database pages up to checkpoint LSN are persisted
- Caller explicitly calls Wal::truncate(checkpoint_lsn)
- Reclaims disk space by removing old records

**Checkpoint Coordination**:
1. Caller identifies checkpoint LSN
2. Caller flushes all database pages with LSN <= checkpoint
3. Caller updates database meta page with new checkpoint LSN
4. Caller syncs database file
5. Caller calls Wal::truncate(checkpoint_lsn)
6. WAL truncates file up to checkpoint LSN
7. Disk space is reclaimed

**Truncation Process**:
- Flush any buffered WAL data
- Sync WAL to disk
- Scan WAL to find record at checkpoint LSN
- Truncate file at that position
- Rescan to update current_lsn
- WAL is now smaller but still consistent

**Relationship to Pager Checkpoints**:
- Pager manages database page checkpointing
- WAL manages log truncation
- Coordination: Pager flushes pages, then WAL truncates
- Checkpoint LSN is written to database meta page
- Ensures recovery can start from checkpoint

### Cleanup

**When WAL Files are Cleaned Up**:
- WAL is never deleted during normal operation
- WAL persists across database open/close cycles
- WAL is deleted only when database is deleted
- Caller may delete WAL after closing database (not recommended)

**Cleanup on Database Close**:
- WAL is NOT deleted on close
- WAL remains for next open
- WAL enables recovery if crash occurs between close and next open
- Caller may manually delete WAL if desired

**Cleanup on Database Deletion**:
- Caller deletes both database file and WAL file
- Both files should be deleted together
- Deleting WAL but not database loses recovery capability
- Deleting database but not WAL leaves orphaned WAL

**Cleanup After Checkpoint**:
- Truncation removes old records but keeps file
- File is not deleted, just made smaller
- File continues to exist for new appends
- Only records are removed, not the file itself

## Function Signatures

### open(path: &[u8], allocator: Allocator) -> Result<Wal, Error>

**Parameters**:

**path**: Reference to path string or bytes
- **Type**: String slice or byte slice
- **Purpose**: Specifies WAL file location
- **Constraints**: Must be valid file path, no special cases
- **Ownership**: Borrowed from caller (not copied)

**allocator**: Memory allocator for internal allocations
- **Type**: Memory allocator (Allocator in Zig, lifetime/bounds in Rust)
- **Purpose**: Used for allocating internal buffer
- **Constraints**: Must be valid and usable for WAL lifetime
- **Ownership**: Borrowed reference

**Return Type**:

**Success**: Returns initialized Wal instance
- **Type**: Result<Wal, Error> in Rust
- **Value**: Fully initialized WAL ready for append or recovery
- **State**: All fields valid, file positioned at end, buffer allocated

**Error**: Returns appropriate error type
- **Type**: Error enum variant
- **Value**: Specific error indicating what went wrong
- **Categories**:
  - File system errors (not found, permission denied)
  - Corruption errors (invalid magic, checksums)
  - Allocation errors (out of memory)

**Method Signature (Prose)**:

The open function is a static method or associated function on the Wal type. It takes a path reference and an allocator reference as parameters. It returns a result type containing either the initialized Wal or an error. The function does not take self as a parameter (it constructs new Wal instances). The function opens an existing WAL file, scans to validate records and find the current LSN, and returns a WAL instance ready for use.

## Rust Implementation Guidance

### Function Definition

**Static Method**: Define as associated function on Wal

**Signature Pattern**:
- Takes &str or &[u8] for path
- Takes allocator parameter (either lifetime parameter or generic bound)
- Returns Result<Wal, Error>

**Naming**: Use conventional Rust naming (open not Open)

### Error Type Definition

**WAL Error Enum**: Define comprehensive error types

**Error Categories**:
- File system errors (NotFound, PermissionDenied, InappropriateFileType)
- Corruption errors (InvalidMagic, ChecksumMismatch, LsnGap)
- Allocation errors (AllocationFailed)

**Implementation**: Use thiserror crate for clean error definitions

### Path Handling

**String Type**: Use std::path::PathBuf or AsRef<Path>

**File Opening**: Use std::fs::OpenOptions with read().write() (no create())

**Special Cases**: None for WAL (unlike Pager)

### Buffer Management

**Fixed Size Buffer**: Use Vec with capacity
```rust
let mut buffer = Vec::with_capacity(64 * 1024);
buffer.resize(64 * 1024, 0);
```

**Alignment**: Consider page-aligned allocation for I/O efficiency

### Scanning Logic

**Helper Function**: Extract scan logic into separate function
```rust
fn scan_highest_lsn(file: &File) -> Result<u64, Error>
```

**Scanning Process**:
- Use pread for reading without affecting file position
- Validate each record completely
- Return last valid LSN or error on corruption
- Handle incomplete final record gracefully

### Recovery Detection

**No Auto-Recovery**: Wal::open does NOT perform recovery
- Returns WAL with current_lsn set
- Caller decides whether to call replay_from()
- Separation of concerns

**Caller Responsibility**:
- Compare checkpoint LSN with WAL LSN
- Call recovery if needed
- Apply recovered transactions to database

### Checkpoint Coordination

**Not Implemented in open**: Checkpoint coordination is caller's responsibility
- Wal::open validates and positions WAL
- Caller calls Pager::checkpoint() to flush pages
- Caller calls Wal::truncate() to reclaim space
- Coordination happens at higher layer

### Resource Cleanup

**RAII Pattern**: Ensure proper cleanup on error paths
- Use Drop trait or explicit close method
- Close file handle if initialization fails after file open
- Deallocate buffer if allocation fails later

**Error Path Cleanup**: If initialization fails partway through
- Close file handle if opened
- Deallocate buffer if allocated
- Release resources in reverse order of acquisition

### Testing Strategy

**Unit Tests Needed**:
- Wal::open returns LSN 0 for empty WAL
- Wal::open scans and finds correct LSN for WAL with records
- Wal::open returns error for non-existent file
- Wal::open validates magic numbers correctly
- Wal::open detects checksum mismatches
- Wal::open handles incomplete final record
- Wal::open detects LSN gaps
- Wal::open positions file pointer at end

**Integration Scenarios**:
- Create WAL, append records, close, reopen, verify LSN
- Append records, close, reopen, verify all records valid
- Corrupt WAL file, verify open returns error
- Create WAL with records, simulate crash (truncate), reopen
- Test recovery mode detection by caller

**Property Tests**:
- Round-trip: append records, close, open, verify same state
- LSN monotonicity after multiple open/close cycles
- Checksum validation rejects all corruption patterns
- Empty WAL remains empty after open/close

### Implementation Notes

1. **File Position After Open**: Always position at end
   - After scanning completes, seek to end of file
   - Next append operation writes at end
   - File position matches file_pos field

2. **Buffer State**: Buffer is initially empty
   - buffer_pos is 0 after open
   - No data is buffered from existing WAL
   - Buffer is used only for new appends

3. **Scanning Efficiency**: Use pread for non-destructive reads
   - pread does not affect file position
   - Can scan without disturbing append position
   - Seek to end after scanning completes

4. **Error Recovery**: No partial recovery on error
   - If any record is corrupt, return error
   - Caller must handle corrupt WAL
   - No attempt to skip corrupt records in V0
   - Future: may attempt partial recovery

5. **LSN Allocation**: LSN starts from existing count
   - If WAL has 100 records, current_lsn is 100
   - Next append will use LSN 101
   - LSN never resets
   - LSN persists across open/close cycles

## Invariants

### File Handle Invariants

**Valid File Handle**: File handle is always valid when Wal is open
- File is opened in read-write mode
- File handle is closed when Wal is dropped
- All operations check file handle validity

### LSN Invariants

**Monotonicity**: LSN never decreases
- current_lsn after open >= 0
- LSN reflects actual records in WAL
- LSN persists across open/close

**Contiguity**: LSNs in WAL are sequential
- LSNs are 1, 2, 3, ..., current_lsn
- No gaps in LSN sequence
- No duplicate LSNs

### Buffer Invariants

**Empty Buffer**: Buffer is empty after open
- buffer_pos is 0
- No existing WAL data is buffered
- Buffer ready for new appends

**Allocation**: Buffer is always allocated
- Buffer capacity is fixed (64KB)
- Buffer is valid for WAL lifetime
- Buffer is freed on drop

### Position Invariants

**File Position**: File pointer is at end after open
- File position equals file size
- Next append writes at end
- File position matches file_pos field

**File Position Matches Size**: file_pos equals actual file size
- file_pos is updated during scan
- file_pos matches bytes in WAL file
- Used to position file pointer at end

## Dependencies

**Uses**:
- types module for Lsn type
- error module for Error, WalError types
- checksum module for CRC32C calculation
- Standard library file I/O (std::fs::File)
- Standard library allocator for memory management

**Used by**:
- Transaction module for WAL lifecycle management
- Db module for opening database with WAL
- Recovery module for crash recovery preparation

## Coordination with Other Components

### Db Module Coordination

**Db::openWithFile**:
- Checks if WAL file exists
- Calls Wal::create() if WAL doesn't exist
- Calls Wal::open() if WAL exists
- Compares checkpoint LSN with WAL LSN
- Calls recovery if needed
- Passes WAL to transaction layer

### Pager Module Coordination

**Checkpoint Process**:
- Pager flushes dirty pages to disk
- Pager updates meta page with checkpoint LSN
- Caller truncates WAL up to checkpoint LSN
- Coordination prevents loss of recovery capability

### Recovery Module Coordination

**Replay Process**:
- Recovery calls Wal::replay_from() to get transactions
- Wal returns list of committed transactions
- Recovery applies transactions to database
- Recovery updates database state
- Recovery may truncate WAL after completion
