# WAL Truncation

## Purpose

WAL truncation removes old log records that are no longer needed for recovery. This prevents unlimited WAL growth and reclaims disk space. Truncation is typically performed after a checkpoint, where all transaction effects have been persisted to the main database file.

## Types

### TruncationStrategy

**Description**: Defines when and how WAL truncation occurs

**Variants**:

**Manual**: Application explicitly requests truncation
- Caller specifies exact LSN to keep
- Gives full control to application
- Useful for testing and maintenance

**CheckpointBased**: Automatic truncation after successful checkpoint
- Truncate all records before checkpoint LSN
- Happens automatically during checkpoint operation
- Keeps WAL size bounded

**Scheduled**: Periodic truncation based on time or WAL size
- Truncates every N seconds
- Or truncates when WAL exceeds size threshold
- Background operation, non-blocking

**LSNBased**: Truncate all records before a specific LSN
- Directly specify the retention point
- All records with LSN < keep_lsn are removed
- Records with LSN >= keep_lsn are preserved

### TruncationResult

**Description**: Result of a truncation operation

**Fields**:
- records_before: u64 - Number of records before truncation
- records_after: u64 - Number of records after truncation
- bytes_reclaimed: u64 - Disk space reclaimed in bytes
- kept_lsn: u64 - The LSN that became the new first record (0 if empty)
- duration_ms: u64 - Time taken for truncation operation

## Functions

### truncate(keep_lsn: u64) -> Result<(), Error>

**Purpose**: Remove all WAL records with LSN less than the specified keep_lsn

**Parameters**:
- keep_lsn: u64 - The LSN threshold. Records with LSN >= keep_lsn are kept.

**Returns**: Result indicating success or I/O error

**Algorithm**:

1. **Flush buffered data**:
   - Call flush() to ensure all buffered records are written to disk
   - This ensures we have a complete view of the WAL

2. **Sync to disk**:
   - Call sync() to ensure all data is durably persisted
   - This prevents data loss if truncation fails midway

3. **Initialize scanning**:
   - Set file_pos = 0 (start of file)
   - Set current_lsn = 1 (LSN of first record)

4. **Get file size**:
   - Call file.getEndPos() to get current WAL file size
   - This is the upper bound for scanning

5. **Scan for keep_lsn position**:
   - While file_pos < file_size:
     a. **Read record header**:
        - Read RecordHeader.SIZE (40 bytes) from file_pos using pread
        - If fewer than 40 bytes read: break (incomplete header)
        - Parse header bytes into RecordHeader structure

     b. **Validate header**:
        - Check that magic equals 0x4C4F4752 ("LOGR")
        - If magic is invalid: break (corruption detected)
        - Validate header checksum
        - If checksum is invalid: break (corruption detected)

     c. **Calculate record size**:
        - record_size = RecordHeader.SIZE + header.payload_len + RecordTrailer.SIZE
        - This is the total byte size of the complete record

     d. **Check if we've reached keep_lsn**:
        - If current_lsn >= keep_lsn:
          - We've found the first record to keep
          - Truncate file at file_pos (remove all records before this position)
          - Call file.setEndPos(file_pos) to truncate
          - Reset file seek position to 0
          - Scan the truncated file to recalculate current_lsn
          - Update self.current_lsn to the recalculated value
          - Return success

     e. **Advance to next record**:
        - file_pos += record_size
        - current_lsn += 1

6. **Handle keep_lsn not found**:
   - If we finish loop without finding keep_lsn:
     - Truncate entire file (setEndPos(0))
     - Reset seek position to 0
     - Set current_lsn = 0
     - Return success (WAL is now empty)

**Error conditions**:
- IoError: File operation failed (read, seek, truncate)
- CorruptionDetected: WAL is corrupted before reaching keep_lsn

**Concurrency**: Must be called with exclusive access to WAL. No concurrent appends or replays during truncation.

**Side effects**:
- WAL file size is reduced
- current_lsn is recalculated
- File position is reset to 0
- Buffered data is flushed and synced

## Invariants

### Truncation Safety Invariants

- **Atomic truncation**: Truncation either completes fully or not at all
- **No data loss**: Records with LSN >= keep_lsn are never removed
- **Flush before truncate**: All buffered data must be written before truncating
- **Sync before truncate**: All data must be durably persisted before truncating
- **Recalculate LSN**: After truncation, current_lsn is recalculated by scanning

### Recovery Guarantees

- **Checkpoint invariant**: After checkpoint at LSN N, all records < N can be safely truncated
- **Recovery point**: The first record in WAL after truncation is the recovery starting point
- **Empty WAL**: Truncating with keep_lsn > current_lsn results in empty WAL

### Coordination with Pager

- **Checkpoint before truncate**: Truncation should only occur after successful checkpoint
- **Pager knows LSN**: Pager tracks the highest checkpointed LSN
- **WAL size bounded**: Regular truncation prevents unlimited WAL growth

## Dependencies

- **Uses**: File I/O operations (pread, setEndPos, seekTo, getEndPos)
- **Used by**: Checkpoint operations, manual WAL maintenance

## Rust Implementation Guidance

### Module Structure

The truncation functionality should be organized as:

```
northstar_core::wal::truncate
├── pub enum TruncationStrategy
├── pub struct TruncationResult
└── impl WriteAheadLog
    └── pub fn truncate(&mut self, keep_lsn: u64) -> Result<(), WalError>
```

### Type Definitions

**TruncationStrategy**: Enum for different truncation approaches

```rust
pub enum TruncationStrategy {
    Manual { keep_lsn: u64 },
    CheckpointBased { checkpoint_lsn: u64 },
    Scheduled { interval_secs: u64, max_size_bytes: u64 },
}
```

**TruncationResult**: Struct for truncation statistics

```rust
pub struct TruncationResult {
    pub records_before: u64,
    pub records_after: u64,
    pub bytes_reclaimed: u64,
    pub kept_lsn: u64,
    pub duration_ms: u64,
}
```

### Key Decisions

**Atomic truncation**: Use file truncation (set_len) which is atomic on most platforms. This ensures either the entire operation succeeds or fails cleanly.

**Validation approach**: After truncation, rescan the file to recalculate current_lsn. This provides a safety check that truncation worked correctly.

**Error handling**: If truncation fails partway through (e.g., disk error), the WAL file may be in an inconsistent state. The next open will scan and recalculate LSN.

**Performance optimization**: For large WAL files, scanning from the beginning is O(N) where N is the number of records. Consider maintaining an index of LSN positions for faster truncation.

### Implementation Notes

**Step 1: Flush and sync**
```rust
self.flush()?;
self.sync()?;
```
This ensures all buffered data is durably persisted before we modify the file structure.

**Step 2: Scan for keep_lsn position**
```rust
let mut file_pos = 0;
let mut current_lsn = 1;
let file_size = self.file.metadata()?.len();

while file_pos < file_size {
    // Read header
    let mut header_bytes = [0u8; RecordHeader::SIZE];
    self.file.read_exact_at(&mut header_bytes, file_pos)?;
    let header = RecordHeader::from_bytes(&header_bytes)?;

    // Calculate record size
    let record_size = RecordHeader::SIZE + header.payload_len as usize + RecordTrailer::SIZE;

    // Check if this is the keep_lsn
    if current_lsn >= keep_lsn {
        self.file.set_len(file_pos as u64)?;
        return Ok(());
    }

    // Advance
    file_pos += record_size;
    current_lsn += 1;
}
```

**Step 3: Handle not found case**
```rust
// keep_lsn not found, truncate everything
self.file.set_len(0)?;
self.current_lsn = 0;
Ok(())
```

**Step 4: Recalculate LSN after truncation**
```rust
// After truncation, verify by rescanning
self.current_lsn = self.scan_highest_lsn()?;
```

### Testing Strategy

**Unit tests needed for**:
- Truncate WAL with single record
- Truncate WAL with multiple records, keep middle record
- Truncate WAL, keep last record
- Truncate WAL, keep LSN that doesn't exist (should truncate all)
- Truncate empty WAL (should be no-op)
- Truncate WAL with keep_lsn = 0 (should truncate all)
- Truncate WAL with keep_lsn = current_lsn (should keep all)
- Verify file size is reduced after truncation
- Verify current_lsn is recalculated correctly

**Property tests for**:
- After truncation, first record has LSN >= keep_lsn
- Truncation never removes records with LSN >= keep_lsn
- After truncation, file can be reopened and replayed successfully

**Integration scenarios**:
- Append 100 records, truncate to keep records 50-100
- Truncate, then checkpoint, verify recovery works
- Truncate during concurrent reads (should fail or serialize)
- Truncate very large WAL (1GB+) to test performance

### Truncation Coordination with Checkpoint

The typical checkpoint and truncate sequence is:

1. **Begin checkpoint**:
   - Flush all dirty pages from buffer pool to database file
   - Note the highest LSN that has been applied: checkpoint_lsn

2. **Write checkpoint record**:
   - Append checkpoint record to WAL with checkpoint_lsn
   - Sync WAL

3. **Sync database file**:
   - Sync the database file to ensure pages are durable
   - Now all transactions <= checkpoint_lsn are recoverable from database file

4. **Truncate WAL**:
   - Call truncate(checkpoint_lsn + 1) to remove old records
   - This keeps records > checkpoint_lsn that may be needed for future recovery

5. **Update checkpoint metadata**:
   - Persist the checkpoint_lsn in database header or separate file
   - Next recovery starts from this checkpoint

### Error Recovery

**If truncation fails**:
- WAL file may be partially truncated or untouched
- Next WAL open will scan and recalculate LSN
- Recovery proceeds from the valid records present
- No data is lost (worst case: WAL is larger than expected)

**If system crashes during truncation**:
- File system ensures atomicity of set_len operation
- Either truncation completes or it doesn't happen at all
- No partial truncation state is possible
- Recovery scans WAL and determines actual state

**If keep_lsn is corrupted**:
- Scanning stops at corruption
- WAL is truncated at corruption point
- Recovery proceeds from valid prefix
- Corrupted records are lost (acceptable as they were unrecoverable anyway)

### Performance Considerations

**Scanning cost**:
- O(N) where N is number of records before keep_lsn
- For large WAL (GBs), this can take seconds
- Consider maintaining LSN-to-position index for faster lookup

**File system behavior**:
- set_len is typically fast (metadata update only)
- Actual space reclamation may be deferred by file system
- Some file systems require close() or explicit fallocate to reclaim space

**Optimization strategies**:
- Maintain an in-memory index mapping LSN to file position
- Persist index periodically for faster recovery
- Use mmap for faster scanning on large WAL
- Consider truncating in larger batches (e.g., every N checkpoints)

**Monitoring**:
- Track WAL size before and after truncation
- Track time taken for truncation
- Alert if WAL grows too large between truncations
- Alert if truncation takes too long

### Safety Checks

**Before truncating**:
- Ensure WAL is synced (data is durable)
- Ensure checkpoint is complete (database file is consistent)
- Verify keep_lsn is valid (0 < keep_lsn <= current_lsn + 1)

**After truncating**:
- Verify file is readable from start
- Verify first record has LSN >= keep_lsn
- Verify current_lsn is recalculated correctly
- Optionally verify by replaying entire WAL
