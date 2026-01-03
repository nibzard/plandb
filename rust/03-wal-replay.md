# WAL Replay

## Purpose

WAL replay reads log records and applies them to reconstruct database state after a crash or during recovery. Replay is the mechanism that ensures durability by re-applying committed transactions that may not have been fully persisted to the main database file.

## Types

### ReplayResult

**Description**: Contains the results of a WAL replay operation

**Fields**:
- commit_records: ArrayList<CommitRecord> - All successfully decoded commit records
- last_lsn: u64 - The LSN of the last successfully processed record
- last_checkpoint_txn_id: u64 - Transaction ID of the last checkpoint record seen
- truncate_lsn: Option<u64> - LSN to truncate to (if cartridge_meta record seen)

**Invariants**:
- commit_records contains only records with valid checksums
- last_lsn equals the count of records successfully processed
- last_checkpoint_txn_id is 0 if no checkpoint record was seen
- truncate_lsn is None if no cartridge_meta record was seen

### ReplayState

**Description**: Internal state during WAL replay

**Fields**:
- file_pos: usize - Current read position within WAL file
- current_lsn: u64 - LSN of the current record being processed
- records_processed: usize - Count of records successfully processed
- records_skipped: usize - Count of records skipped (before start_lsn or corrupted)
- bytes_read: usize - Total bytes read from WAL

**Invariants**:
- file_pos is always <= WAL file size
- current_lsn starts at 1 and increments each iteration
- records_processed + records_skipped = total records scanned

### ReplayOptions

**Description**: Configuration options for WAL replay behavior

**Fields**:
- start_lsn: u64 - Start replay from this LSN (default: 1)
- stop_on_error: bool - Stop immediately on error vs skip and continue (default: false)
- max_records: Option<u64> - Maximum number of records to process (default: None)
- validate_checksums: bool - Verify payload checksums (default: true)
- ignore_unknown_types: bool - Skip unknown record types vs error (default: true)

## Functions

### replayFrom(start_lsn: u64, allocator: Allocator) -> Result<ReplayResult, Error>

**Purpose**: Replay WAL records starting from a specified LSN

**Parameters**:
- start_lsn: u64 - The LSN to start replaying from (records before this are skipped)
- allocator: Allocator - Memory allocator for allocating commit records

**Returns**: ReplayResult containing all decoded commit records

**Algorithm**:

1. **Initialize result**:
   - Create ReplayResult with empty commit_records array
   - Set up error defer to clean up allocations if replay fails

2. **Seek to file start**:
   - Call file.seekTo(0) to start reading from beginning of WAL
   - Set file_pos = 0

3. **Get file size**:
   - Call file.getEndPos() to get WAL file size
   - This is the upper bound for reading

4. **Initialize replay state**:
   - Set current_lsn = 1 (LSN of first record)
   - Set iteration counter (for safety/debugging)

5. **Scan WAL records**:
   - While file_pos < file_size:
     a. **Validate header fits**:
        - If file_pos + RecordHeader.SIZE (40) > file_size: break (incomplete header)

     b. **Read record header**:
        - Allocate header_bytes array of 40 bytes
        - Read RecordHeader.SIZE bytes from file_pos using pread
        - If fewer than 40 bytes read: break (incomplete read)
        - Parse header_bytes into RecordHeader structure
        - If parsing fails: break (invalid header format)

     c. **Validate header magic**:
        - Check that header.magic equals 0x4C4F4752 ("LOGR")
        - If magic is invalid: break (corruption detected)

     d. **Validate header checksum**:
        - Calculate expected header CRC using explicit field ordering
        - Compare with header.header_crc32c
        - If checksums don't match: break (corruption detected)

     e. **Calculate record size**:
        - record_size = RecordHeader.SIZE + header.payload_len + RecordTrailer.SIZE

     f. **Validate record fits**:
        - If file_pos + record_size > file_size: break (incomplete record)

     g. **Check if we've reached start_lsn**:
        - If current_lsn < start_lsn:
          - Skip this record (not needed for recovery)
          - file_pos += record_size
          - current_lsn += 1
          - continue

     h. **Read record payload**:
        - Allocate record_data array of header.payload_len bytes
        - Set up defer to free record_data after processing
        - Read payload_len bytes from file_pos + RecordHeader.SIZE
        - If fewer bytes read: break (incomplete payload)

     i. **Validate payload checksum**:
        - Calculate CRC32C of record_data
        - Compare with header.payload_crc32c
        - If checksums don't match:
          - This record is corrupted
          - Skip it: file_pos += record_size
          - current_lsn += 1
          - continue (don't add to results)

     j. **Process record by type**:
        - Switch on header.record_type:
          - Case 0 (COMMIT):
            - Call deserializeCommitRecord(record_data, allocator)
            - If deserialization fails: break (invalid record format)
            - Append commit record to result.commit_records
          - Case 1 (CHECKPOINT):
            - If payload_len equals 8 bytes:
              - Read u64 checkpoint_txn_id from record_data
              - Set result.last_checkpoint_txn_id = checkpoint_txn_id
          - Case 2 (CARTRIDGE_META):
            - Set result.truncate_lsn = header.txn_id
          - Default (unknown type):
            - Ignore unknown record types (forward compatibility)
            - Don't add to results

     k. **Update result and advance**:
        - Set result.last_lsn = current_lsn
        - file_pos += record_size
        - current_lsn += 1

6. **Return result**:
   - Return ReplayResult with all successfully decoded commit records

**Error conditions**:
- IoError: File read operation failed
- InvalidHeaderFormat: Header could not be parsed
- CorruptedData: Magic number or checksum validation failed
- OutOfMemory: Allocation failed for commit records

**Concurrency**: Single-threaded only. Replay should not run concurrently with append or truncate operations.

**Memory allocation**:
- Allocates one ArrayList for all commit records
- Allocates one CommitRecord structure per commit
- Each CommitRecord owns its mutations, keys, and values
- Temporary allocations are freed promptly (defer cleanup)

## Invariants

### Replay Safety Invariants

- **Bounds checking**: All reads must validate that sufficient bytes remain
- **Checksum validation**: All payloads must have valid checksums before being applied
- **LSN tracking**: current_lsn always reflects the record being processed
- **No mutation during replay**: Database state is not modified during replay (replay builds list of changes to apply later)

### Recovery Guarantees

- **Idempotent**: Replaying the same WAL multiple times produces same result
- **Stop on corruption**: Corrupted records stop replay (conservative approach)
- **Skip before start_lsn**: Records before start_lsn are ignored (useful for incremental recovery)
- **Unknown types tolerated**: Unknown record types are skipped (forward compatibility)

### Checkpoint Handling

- **Checkpoint records are informational**: They indicate a consistent point but don't contain mutations
- **Checkpoint LSN defines recovery starting point**: Replay can start from checkpoint + 1
- **Last checkpoint txn_id is tracked**: Returned in result.last_checkpoint_txn_id

## Dependencies

- **Uses**: File I/O operations (pread, seekTo, getEndPos), CRC32C hashing
- **Used by**: Crash recovery, database open, WAL testing

## Rust Implementation Guidance

### Module Structure

The replay functionality should be organized as:

```
northstar_core::wal::replay
├── pub struct ReplayResult
├── pub struct ReplayState
├── pub struct ReplayOptions
├── pub fn replay_from(
    wal: &mut WriteAheadLog,
    options: &ReplayOptions
) -> Result<ReplayResult, ReplayError>
└── impl WriteAheadLog
    └── pub fn replay_from(
        &mut self,
        start_lsn: u64
    ) -> Result<ReplayResult, WalError>
```

### Type Definitions

**ReplayResult**: Struct containing replay results

```rust
pub struct ReplayResult {
    pub commit_records: Vec<CommitRecord>,
    pub last_lsn: u64,
    pub last_checkpoint_txn_id: u64,
    pub truncate_lsn: Option<u64>,
}

impl ReplayResult {
    pub fn is_empty(&self) -> bool {
        self.commit_records.is_empty()
    }

    pub fn len(&self) -> usize {
        self.commit_records.len()
    }
}
```

**ReplayOptions**: Configuration for replay behavior

```rust
pub struct ReplayOptions {
    pub start_lsn: u64,
    pub stop_on_error: bool,
    pub max_records: Option<u64>,
    pub validate_checksums: bool,
    pub ignore_unknown_types: bool,
}

impl Default for ReplayOptions {
    fn default() -> Self {
        Self {
            start_lsn: 1,
            stop_on_error: false,
            max_records: None,
            validate_checksums: true,
            ignore_unknown_types: true,
        }
    }
}
```

**ReplayError**: Errors specific to replay operations

```rust
pub enum ReplayError {
    Io(std::io::Error),
    InvalidHeaderFormat,
    CorruptedData { position: usize, reason: String },
    ChecksumMismatch { lsn: u64 },
    DecodeError(DecodeError),
    OutOfMemory,
}
```

### Key Decisions

**Error handling strategy**: By default, replay skips corrupted records and continues. This allows recovery of as much data as possible. The `stop_on_error` option can be set for stricter behavior where any error stops replay.

**Memory management**: Use arena allocation for many small allocations (keys, values). This reduces allocation overhead and fragmentation.

**Checksum validation**: Always enabled by default for safety. Can be disabled for performance in trusted scenarios (e.g., testing).

**Forward compatibility**: Unknown record types are skipped by default. This allows newer WAL formats to be read by older code.

### Implementation Notes

**Step 1: Initialize replay state**
```rust
let mut result = ReplayResult::default();
let mut file_pos = 0usize;
let mut current_lsn = 1u64;
let file_size = self.file.metadata()?.len();
```

**Step 2: Main replay loop**
```rust
while file_pos < file_size {
    // Read and validate header
    let header = self.read_header_at(file_pos)?;
    if !header.is_valid() {
        break; // Corruption detected, stop replay
    }

    let record_size = header.total_size();

    // Check start_lsn
    if current_lsn < options.start_lsn {
        file_pos += record_size;
        current_lsn += 1;
        continue;
    }

    // Read and validate payload
    let payload = self.read_payload_at(file_pos, header.payload_len)?;
    if options.validate_checksums && !self.validate_checksum(&payload, &header) {
        file_pos += record_size; // Skip corrupted record
        current_lsn += 1;
        continue;
    }

    // Process record
    match header.record_type {
        0 => { // COMMIT
            let record = deserialize_commit_record(&payload, allocator)?;
            result.commit_records.push(record);
        }
        1 => { // CHECKPOINT
            if payload.len() == 8 {
                result.last_checkpoint_txn_id = u64::from_le_bytes(payload.try_into()?);
            }
        }
        2 => { // CARTRIDGE_META
            result.truncate_lsn = Some(header.txn_id);
        }
        _ => {
            // Unknown type, skip
        }
    }

    result.last_lsn = current_lsn;
    file_pos += record_size;
    current_lsn += 1;
}
```

**Step 3: Handle allocation failures**
- Use allocator that can return errors (not panic)
- Clean up any partial allocations on error
- Return OutOfMemory error if allocation fails

**Step 4: Optimization - use mmap for large WAL**
```rust
// For WAL > 1GB, use mmap for faster access
if file_size > 1_000_000_000 {
    let mmap = unsafe { Mmap::map(&self.file)? };
    // Read directly from mmap instead of pread
}
```

### Testing Strategy

**Unit tests needed for**:
- Replay empty WAL
- Replay WAL with single commit record
- Replay WAL with multiple commit records
- Replay WAL with checkpoint record
- Replay WAL with corrupted record (should stop)
- Replay WAL with checksum mismatch (should skip)
- Replay WAL starting from middle LSN
- Replay WAL with unknown record type (should skip)
- Verify LSN tracking is accurate
- Verify memory is freed on error

**Property tests for**:
- Replay idempotency: replaying same WAL twice produces identical results
- Checksum validation: corrupted checksums are detected
- Order preservation: commit records are replayed in original order

**Integration scenarios**:
- Crash recovery: Simulate crash, verify replay recovers all committed transactions
- Large WAL: Replay multi-GB WAL to test performance
- Concurrent access: Attempt replay during append (should fail or serialize)

### Performance Considerations

**Throughput optimization**:
- Use mmap for large WAL files (reduces system call overhead)
- Batch small reads into larger buffers
- Use SIMD for checksum calculation
- Pre-allocate Vec with estimated capacity

**Memory efficiency**:
- Free payloads immediately after processing
- Use arena allocator for many small allocations
- Limit memory usage with max_records option

**CPU efficiency**:
- Checksum calculation is the bottleneck
- Use hardware CRC32C instruction (SSE4.2 on Intel/AMD)
- Parallelize replay of independent records (advanced optimization)

**I/O efficiency**:
- Sequential read pattern is cache-friendly
- Use readahead for large WAL
- Consider async I/O for very large WAL

### Recovery Workflow

The typical crash recovery workflow is:

1. **Open WAL**:
   - Open WAL file in read-only mode
   - File may be incomplete (truncated) due to crash

2. **Replay WAL**:
   - Call replay_from(start_lsn=1) to read all records
   - Collect all commit records into a list

3. **Apply to database**:
   - For each commit record in order:
     - Create new transaction
     - Apply each mutation (Put/Delete)
     - Commit transaction (write to database file, not WAL)
   - This brings database file up to date

4. **Checkpoint**:
   - After applying all records, write checkpoint record
   - Sync database file
   - Truncate WAL to remove replayed records

5. **Resume normal operation**:
   - Database is now consistent
   - Ready for new transactions

### Replay Statistics

For monitoring and debugging, collect these statistics:

- **Records scanned**: Total records examined
- **Records processed**: Successfully decoded and applied
- **Records skipped**: Before start_lsn or corrupted
- **Bytes read**: Total bytes read from WAL
- **Duration**: Time taken for replay
- **Throughput**: Records per second

Example:
```
Replay Statistics:
  Records scanned: 10,523
  Records processed: 10,500
  Records skipped: 23 (corrupted)
  Bytes read: 1.2 GB
  Duration: 3.4 seconds
  Throughput: 3,088 records/sec
```
