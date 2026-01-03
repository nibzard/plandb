# WAL Append Operation

## Purpose

The WAL append operation is the core mechanism for persisting transaction commits to durable storage. It provides append-only semantics, meaning records are written sequentially to the end of the log without modifying existing records. This append-only property enables crash recovery by replaying log entries.

## Types

### WriteAheadLog (Context for Append)

**Description**: The main WAL structure that manages append operations

**Fields relevant to append**:
- file: File handle - The underlying file for persistence
- current_lsn: u64 - Monotonically increasing log sequence number
- buffer: []u8 - In-memory buffer for batching writes (64KB)
- buffer_pos: usize - Current write position within buffer
- sync_needed: bool - Flag indicating whether fsync is required
- file_pos: usize - Current file position for appending

**Invariants**:
- current_lsn equals the number of records successfully appended
- buffer_pos never exceeds buffer length
- file_pos tracks the actual end of file (not including buffered data)
- sync_needed becomes true after any append, false after sync

### RecordHeader

**Description**: Fixed-size header preceding each WAL record

**Fields**:
- magic: u32 (4 bytes) - Magic number 0x4C4F4752 ("LOGR")
- record_version: u16 (2 bytes) - Record format version (0 for V0)
- record_type: u16 (2 bytes) - Type of record (0=commit, 1=checkpoint, 2=cartridge_meta)
- header_len: u16 (2 bytes) - Header length in bytes (40 for V0)
- flags: u16 (2 bytes) - Record flags (bit 1 indicates inline values)
- txn_id: u64 (8 bytes) - Transaction identifier
- prev_lsn: u64 (8 bytes) - Previous LSN for chain verification
- payload_len: u32 (4 bytes) - Length of payload in bytes
- header_crc32c: u32 (4 bytes) - CRC32C checksum of header fields
- payload_crc32c: u32 (4 bytes) - CRC32C checksum of payload

**Size**: 40 bytes total
**Alignment**: Natural alignment (no special padding required)

**Invariants**:
- magic must equal 0x4C4F4752
- header_crc32c is calculated with header_crc32c field set to zero
- header_len equals 40 for V0 format
- prev_lsn equals current_lsn before appending

### RecordTrailer

**Description**: Fixed-size trailer following each WAL record

**Fields**:
- magic2: u32 (4 bytes) - Magic number 0x52474F4C ("RGOL")
- total_len: u32 (4 bytes) - Total record length (header + payload + trailer)
- trailer_crc32c: u32 (4 bytes) - CRC32C checksum of trailer fields

**Size**: 12 bytes total
**Alignment**: Natural alignment

**Invariants**:
- magic2 must equal 0x52474F4C
- trailer_crc32c is calculated with trailer_crc32c field set to zero
- total_len equals header_len + payload_len + trailer_len (12)

### RecordType

**Description**: Enumeration of WAL record types

**Variants**:
- commit (0): Transaction commit record with mutations
- checkpoint (1): Checkpoint marker
- cartridge_meta (2): AI cartridge metadata

## Functions

### appendCommitRecord(record: CommitRecord) -> Result<u64, Error>

**Purpose**: Append a transaction commit record to the WAL

**Parameters**:
- record: CommitRecord - The commit record containing mutations to persist

**Returns**: u64 - The newly assigned LSN for this record

**Algorithm**:

1. **Validate input**: Check that the commit record's payload checksum is valid. Return InvalidChecksum error if validation fails.

2. **Serialize payload**: Convert the commit record into its binary payload format. This includes:
   - Commit payload header (CMIT magic, txn_id, root_page_id, op_count)
   - Encoded operations (each with type, flags, key_len, val_len, key_bytes, val_bytes)

3. **Calculate payload checksum**: Compute CRC32C checksum of the serialized payload data.

4. **Build record header**: Construct a RecordHeader with:
   - magic = 0x4C4F4752
   - record_version = 0
   - record_type = 0 (commit)
   - header_len = 40
   - flags = 0x02 (bit 1 set: payload contains inline values)
   - txn_id = record.txn_id
   - prev_lsn = current_lsn (before increment)
   - payload_len = serialized payload length
   - header_crc32c = 0 (calculated later)
   - payload_crc32c = calculated payload checksum

5. **Delegate to appendRecordWithTrailer**: Call the internal append function with header and payload.

6. **Return LSN**: The function returns the new LSN assigned to this record.

**Error Conditions**:
- InvalidChecksum: The commit record's payload checksum is invalid
- IoError: File write operation failed (disk full, permissions, etc.)
- UnexpectedEof: File system returned unexpected end of file

**Concurrency**: This function requires exclusive access. Must be called with write lock held in concurrent scenarios.

### appendRecordWithTrailer(header: RecordHeader, data: []u8) -> Result<u64, Error>

**Purpose**: Internal function that appends any record type with proper framing

**Parameters**:
- header: RecordHeader - The record header
- data: []u8 - The payload data

**Returns**: u64 - The newly assigned LSN

**Algorithm**:

1. **Calculate total size**: Compute record_size = RecordHeader.SIZE (40) + data.len + RecordTrailer.SIZE (12).

2. **Calculate header checksum**: Compute CRC32C of all header fields with header_crc32c set to zero. Use explicit field ordering for cross-language consistency.

3. **Calculate trailer checksum**: Compute CRC32C of trailer magic, total_len, with trailer_crc32c set to zero.

4. **Check buffer fit**: If buffer_pos + record_size exceeds buffer capacity (64KB):
   - Flush the buffer to disk
   - Reset buffer_pos to 0

5. **Handle oversized records**: If record_size exceeds buffer capacity (large payloads):
   - Write directly to file bypassing buffer
   - Write each header field individually in explicit byte order
   - Write payload data
   - Write each trailer field individually
   - Update file_pos by record_size
   - Increment current_lsn
   - Set sync_needed = true
   - Return new LSN

6. **Buffered write (normal case)**: For records that fit in buffer:
   - Copy header fields to buffer one by one in explicit order
   - Copy payload data to buffer
   - Copy trailer fields to buffer one by one
   - Update buffer_pos to new position
   - Increment current_lsn
   - Set sync_needed = true
   - Return new LSN

**Error Conditions**:
- IoError: File write failed or disk full

**Concurrency**: Internal function, assumes caller holds appropriate lock.

### appendCheckpoint(txn_id: u64) -> Result<u64, Error>

**Purpose**: Append a checkpoint marker record

**Parameters**:
- txn_id: u64 - The transaction ID being checkpointed

**Returns**: u64 - The newly assigned LSN

**Algorithm**:

1. **Serialize checkpoint data**: Convert txn_id to byte array (8 bytes).

2. **Build header**: Create RecordHeader with checkpoint type (record_type = 1).

3. **Delegate to appendRecord**: Use legacy append function for compatibility.

**Error Conditions**:
- IoError: File write failed

**Concurrency**: Requires exclusive access.

## Invariants

- **LSN monotonicity**: current_lsn strictly increases with each successful append
- **Append-only**: Records are always written at the end, never modifying existing data
- **Atomic headers**: Record headers are written completely or not at all (via buffer or direct write)
- **Checksum integrity**: All checksums are calculated before writing and include all relevant fields
- **File position tracking**: file_pos always points to where the next write should occur
- **Buffer consistency**: buffer_pos always reflects the next free byte in buffer
- **Sync flag**: sync_needed is true whenever un-synced data exists (in buffer or file)

## Dependencies

- **Uses**: txn module (CommitRecord, CommitPayloadHeader), CRC32C hashing
- **Used by**: Db module (WriteTxn.commit), checkpoint operations

## Rust Implementation Guidance

### Module Structure

The WAL append functionality should be organized as methods on the WriteAheadLog struct:

```
northstar_core::wal::WriteAheadLog
├── pub fn append_commit_record(&mut self, record: &CommitRecord) -> Result<u64>
├── pub fn append_checkpoint(&mut self, txn_id: u64) -> Result<u64>
├── fn append_record_with_trailer(&mut self, header: RecordHeader, data: &[u8]) -> Result<u64>
└── fn flush(&mut self) -> Result<()>
```

### Type Definitions

**WriteAheadLog struct fields**:
- Use `std::fs::File` for file handle
- Use `u64` for current_lsn
- Use `Vec<u8>` for buffer (pre-allocated to 64KB)
- Use `usize` for buffer_pos and file_pos
- Use `bool` for sync_needed

**RecordHeader**: Use `#[repr(C)]` struct to guarantee binary layout. All fields are little-endian integers.

**RecordTrailer**: Use `#[repr(C)]` struct for binary compatibility.

### Concurrency

- **Mutex<WriteAheadLog>**: Wrap the entire WAL in a Mutex for exclusive access
- **Rationale**: WAL append is inherently single-writer; multiple concurrent writers would corrupt the log
- **Alternative**: Consider `RwLock` if implementing concurrent readers, but write path still needs exclusive lock

### Key Decisions

**Buffering strategy**: Use a 64KB fixed-size buffer to batch small writes. This reduces system calls and improves throughput.

**Large record handling**: Records larger than buffer capacity should bypass buffering and write directly to file. This prevents unbounded memory usage.

**Checksum algorithm**: Use the `crc32c` crate for hardware-accelerated CRC32C calculation (Intel/AMD CPUs have SSE4.2 instructions).

**Byte ordering**: All multi-byte integers use little-endian. Use `to_le_bytes()` and `from_le_bytes()` methods for explicit conversion.

**LSN allocation**: LSN is simply a counter starting from 0, incremented after each successful append. LSN 1 is the first record (not LSN 0).

### Implementation Notes

**Step 1: Header checksum calculation**
- Calculate checksum over all header fields with header_crc32c field set to zero
- Update the header with calculated checksum before writing
- Use explicit field-by-field hashing for cross-language reproducibility

**Step 2: Trailer checksum calculation**
- Calculate over magic2, total_len with trailer_crc32c set to zero
- Calculate before writing trailer

**Step 3: Buffer management**
- Check if record fits: `if self.buffer_pos + record_size > self.buffer.len`
- Flush buffer if it doesn't fit
- For oversized records, write directly to avoid allocation

**Step 4: Writing header fields**
- Write each field individually in explicit order
- Use `file.write_all(&header.magic.to_le_bytes())` pattern
- Maintain explicit offset tracking when writing directly to file

**Step 5: LSN management**
- Increment LSN after successful write
- Store previous LSN in header for chain verification
- Return new LSN to caller

**Step 6: Sync flag**
- Set `sync_needed = true` after any append
- Reset to false only after explicit `sync()` call

### Testing Strategy

**Unit tests needed for**:
- Successful append of single commit record
- Multiple sequential appends with LSN tracking
- Buffer flush when buffer is full
- Direct write for records larger than buffer
- Checksum calculation and validation
- Error handling when disk is full
- Error handling on invalid input checksum

**Property tests for**:
- LSN monotonicity: appended records have strictly increasing LSNs
- Append-only invariant: file position never decreases
- Checksum correctness: all written records have valid checksums

**Integration scenarios**:
- Append commit record, sync, reopen WAL, verify record is readable
- Append multiple records, crash simulation (kill process), verify replay recovers all records
- Append record, truncate, verify correct LSN after reopen

### Performance Considerations

**Throughput optimization**:
- Batch small commits in buffer before fsync
- Use `write_all` for guaranteed complete writes
- Consider `fallocate` to pre-allocate WAL file space

**Latency optimization**:
- Keep buffer in memory until explicit sync
- Provide async API options for non-blocking appends
- Use `O_DSYNC` flag for synchronous writes if needed

**Memory usage**:
- Fixed 64KB buffer prevents unbounded growth
- Direct write path for large records prevents OOM
- Payload serialization should be streaming for very large commits
