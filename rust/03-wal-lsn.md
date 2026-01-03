# WAL LSN (Log Sequence Number)

## Purpose

The LSN (Log Sequence Number) is a monotonically increasing identifier assigned to each WAL record. It provides ordering guarantees, enables recovery from specific points, and supports truncation of old records.

## Types

### LSN

**Description**: Unique identifier for each WAL record

**Representation**: u64 (64-bit unsigned integer)

**Range**: 0 to 18,446,744,073,709,551,615 (theoretical maximum)

**Special values**:
- LSN 0: No records (WAL is empty)
- LSN 1: First record in WAL
- LSN N: Nth record in WAL (1-indexed)

**Invariants**:
- LSNs are strictly increasing (no gaps, no duplicates)
- LSN is assigned atomically when record is appended
- LSN is never reused, even after truncation

### LsnAllocation

**Description**: Strategy for allocating LSNs to new records

**Fields**:
- current_lsn: u64 - The highest LSN allocated so far (0 if empty)
- next_lsn: u64 - The LSN that will be allocated to the next record (= current_lsn + 1)

**Invariants**:
- next_lsn always equals current_lsn + 1
- LSN allocation is atomic with respect to concurrent operations

## Functions

### getCurrentLsn() -> u64

**Purpose**: Get the highest LSN currently allocated

**Returns**: The LSN of the most recently appended record, or 0 if WAL is empty

**Algorithm**:
1. Return self.current_lsn directly (no computation needed)

**Concurrency**: Thread-safe if WAL is protected by Mutex

**Time complexity**: O(1) (simple field access)

### allocateLsn() -> u64

**Purpose**: Allocate a new LSN for an incoming record

**Returns**: The newly allocated LSN

**Algorithm**:
1. Increment current_lsn by 1
2. Return the new value of current_lsn

**Concurrency**: Must be atomic with respect to other allocations

**Time complexity**: O(1) (simple increment)

### scanHighestLsn(file: &File) -> Result<u64, Error>

**Purpose**: Scan the WAL file to determine the highest LSN (used during recovery)

**Parameters**:
- file: &File - Reference to the WAL file

**Returns**: The count of valid records found (which equals the highest LSN)

**Algorithm**:

1. **Initialize scanning**:
   - Set record_count = 0
   - Set file_pos = 0
   - Get file_size from file metadata

2. **Scan records**:
   - While file_pos < file_size:
     a. **Read header**:
        - Read RecordHeader.SIZE (40 bytes) from file_pos
        - If fewer than 40 bytes read: break (incomplete header)

     b. **Parse and validate header**:
        - Parse bytes into RecordHeader
        - If parsing fails: break (invalid format)
        - Check magic equals 0x4C4F4752
        - If magic is invalid: break (corruption)
        - Calculate and validate header checksum
        - If checksum is invalid: break (corruption)

     c. **Count record**:
        - Increment record_count by 1

     d. **Advance to next record**:
        - record_size = RecordHeader.SIZE + header.payload_len + RecordTrailer.SIZE
        - file_pos += record_size

3. **Return count**:
   - Return record_count (this equals the highest LSN)

**Error conditions**:
- IoError: File read operation failed

**Concurrency**: Single-threaded only. No concurrent operations during scanning.

**Time complexity**: O(N) where N is the number of records in WAL

### validateLsnChain() -> Result<(), Error>

**Purpose**: Verify that the prev_lsn field in each record forms a valid chain

**Algorithm**:

1. **Initialize**:
   - Set expected_prev_lsn = 0
   - Set file_pos = 0

2. **Scan and validate**:
   - For each record in WAL:
     a. Read and parse RecordHeader
     b. Check that header.prev_lsn equals expected_prev_lsn
     c. If mismatch: return ChainError
     d. Set expected_prev_lsn = current_lsn
     e. Advance to next record

3. **Return success**:
   - If all records validated: return Ok(())

**Error conditions**:
- ChainError: prev_lsn chain is broken
- CorruptionDetected: Invalid header or checksum

### lsnToPosition(lsn: u64) -> Result<usize, Error>

**Purpose**: Find the file position (byte offset) of a specific LSN

**Parameters**:
- lsn: u64 - The LSN to locate

**Returns**: Byte offset in WAL file where the record starts

**Algorithm**:

1. **Validate LSN**:
   - If lsn == 0: return InvalidLsn (no record 0)
   - If lsn > current_lsn: return LsnNotFound

2. **Scan for LSN**:
   - Set file_pos = 0
   - Set current_lsn = 1

   - While file_pos < file_size:
     a. Read and parse RecordHeader
     b. If current_lsn == lsn: return file_pos
     c. Calculate record_size
     d. file_pos += record_size
     e. current_lsn += 1

3. **Handle not found**:
   - If loop completes without finding LSN: return LsnNotFound

**Time complexity**: O(N) where N is the target LSN

**Optimization**: Maintain an index mapping LSN to file position for O(1) lookup

## Invariants

### LSN Allocation Invariants

- **Monotonicity**: LSNs strictly increase, never decrease
- **No gaps**: Every LSN from 1 to current_lsn has a record
- **Atomic allocation**: LSN is assigned as part of atomic append operation
- **Persistent after sync**: LSN is durable only after file is synced

### LSN Chain Invariants

- **prev_lsn consistency**: Record N has prev_lsn = N-1 (except first record where prev_lsn = 0)
- **Chain validity**: The prev_lsn chain can be followed from the newest to oldest record
- **Gap detection**: A gap in prev_lsn chain indicates lost or corrupted records

### Recovery Invariants

- **LSN recalculation**: After recovery, current_lsn is recalculated by scanning
- **Truncation effect**: Truncating WAL sets current_lsn to the count of remaining records
- **Empty WAL**: Empty WAL has current_lsn = 0

## Dependencies

- **Uses**: File I/O operations, RecordHeader parsing
- **Used by**: WAL append, WAL replay, WAL truncation

## Rust Implementation Guidance

### Module Structure

The LSN functionality should be organized as:

```
northstar_core::wal::lsn
├── pub type Lsn = u64;
├── pub struct LsnAllocation {
    pub current_lsn: Lsn,
    pub next_lsn: Lsn,
}
├── impl LsnAllocation {
    pub fn new() -> Self;
    pub fn allocate(&mut self) -> Lsn;
    pub fn current(&self) -> Lsn;
}
└── impl WriteAheadLog
    ├── pub fn get_current_lsn(&self) -> Lsn;
    ├── pub fn scan_highest_lsn(&file) -> Result<Lsn, Error>;
    └── pub fn lsn_to_position(&self, lsn: Lsn) -> Result<usize, Error>;
```

### Type Definitions

**LSN type alias**: Use a type alias for clarity and future flexibility

```rust
pub type Lsn = u64;

pub const LSN_INVALID: Lsn = 0;
pub const LSN_FIRST: Lsn = 1;
```

**LsnAllocation struct**: Tracks LSN allocation state

```rust
#[derive(Debug, Clone, Copy)]
pub struct LsnAllocation {
    current_lsn: Lsn,
}

impl LsnAllocation {
    pub fn new() -> Self {
        Self { current_lsn: 0 }
    }

    pub fn allocate(&mut self) -> Lsn {
        self.current_lsn += 1;
        self.current_lsn
    }

    pub fn current(&self) -> Lsn {
        self.current_lsn
    }

    pub fn is_empty(&self) -> bool {
        self.current_lsn == 0
    }
}

impl Default for LsnAllocation {
    fn default() -> Self {
        Self::new()
    }
}
```

### Key Decisions

**LSN as u64**: Simple and efficient. No wrapper type needed in Rust. Use type alias for documentation.

**Atomic allocation**: In concurrent scenarios, use atomic operations:

```rust
use std::sync::atomic::{AtomicU64, Ordering};

pub struct LsnAllocation {
    current_lsn: AtomicU64,
}

impl LsnAllocation {
    pub fn allocate(&self) -> Lsn {
        self.current_lsn.fetch_add(1, Ordering::SeqCst) + 1
    }
}
```

**LSN persistence**: LSN is not stored separately in the file. It's calculated by scanning records. This avoids the need for a separate metadata file.

**Optimization with index**: For large WAL files, maintain an in-memory index:

```rust
struct LsnIndex {
    positions: Vec<usize>, // positions[lsn] = file_offset
}

impl LsnIndex {
    pub fn get(&self, lsn: Lsn) -> Option<usize> {
        if lsn == 0 || lsn >= self.positions.len() as Lsn {
            None
        } else {
            Some(self.positions[lsn as usize])
        }
    }
}
```

### Implementation Notes

**Step 1: getCurrentLsn implementation**
```rust
pub fn get_current_lsn(&self) -> Lsn {
    self.lsn_allocation.current()
}
```
Simple field access, O(1) time.

**Step 2: LSN allocation during append**
```rust
pub fn append_commit_record(&mut self, record: &CommitRecord) -> Result<Lsn, Error> {
    // Allocate LSN first
    let new_lsn = self.lsn_allocation.allocate();

    // Build header with prev_lsn = current_lsn (before allocation)
    let header = RecordHeader {
        prev_lsn: new_lsn - 1, // Previous LSN
        // ... other fields
    };

    // Append record with this LSN
    self.append_record_with_trailer(header, payload)?;

    Ok(new_lsn)
}
```

**Step 3: scanHighestLsn implementation**
```rust
pub fn scan_highest_lsn(file: &File) -> Result<Lsn, ScanError> {
    let mut record_count = 0u64;
    let mut file_pos = 0usize;
    let file_size = file.metadata()?.len();

    while file_pos < file_size {
        // Read header
        let mut header_bytes = [0u8; RecordHeader::SIZE];
        let bytes_read = file.read_at(&mut header_bytes, file_pos)?;
        if bytes_read < RecordHeader::SIZE {
            break;
        }

        // Parse and validate
        let header = match RecordHeader::from_bytes(&header_bytes) {
            Ok(h) => h,
            Err(_) => break,
        };

        if !header.is_valid() {
            break;
        }

        // Count record
        record_count += 1;

        // Advance
        let record_size = RecordHeader::SIZE + header.payload_len as usize + RecordTrailer::SIZE;
        file_pos += record_size;
    }

    Ok(record_count)
}
```

**Step 4: lsnToPosition implementation**
```rust
pub fn lsn_to_position(&self, lsn: Lsn) -> Result<usize, LsnError> {
    if lsn == 0 {
        return Err(LsnError::InvalidLsn);
    }
    if lsn > self.get_current_lsn() {
        return Err(LsnError::NotFound);
    }

    let mut file_pos = 0;
    let mut current_lsn = 1;
    let file_size = self.file.metadata()?.len();

    while file_pos < file_size {
        let header = self.read_header_at(file_pos)?;

        if current_lsn == lsn {
            return Ok(file_pos);
        }

        let record_size = header.total_size();
        file_pos += record_size;
        current_lsn += 1;
    }

    Err(LsnError::NotFound)
}
```

### Testing Strategy

**Unit tests needed for**:
- Allocate first LSN (should be 1)
- Allocate subsequent LSNs (should increment)
- Get current LSN of empty WAL (should be 0)
- Scan WAL with single record (should return 1)
- Scan WAL with multiple records (should return count)
- Scan WAL with corruption (should stop at corruption)
- LSN to position conversion for valid LSN
- LSN to position for invalid LSN (should error)
- LSN to position for future LSN (should error)

**Property tests for**:
- LSN monotonicity: allocated LSNs are strictly increasing
- LSN contiguity: no gaps in allocated LSNs
- Scan accuracy: scan returns correct count

**Integration scenarios**:
- Append records, verify LSNs are sequential
- Crash with buffered data, reopen, verify scan recalculates LSN
- Truncate WAL, verify LSN is recalculated
- Find position of each LSN, verify correctness

### Performance Considerations

**LSN allocation**: O(1) operation, very fast. Just an increment.

**LSN scanning**: O(N) where N is the number of records. For large WAL (millions of records), this can take seconds.

**Optimization strategies**:
- Maintain LSN index for O(1) lookup
- Cache scan result in memory
- Persist index periodically for faster recovery
- Use memory-mapped file for faster scanning

**Index persistence**:
- Write index to separate file after every N records
- On recovery, load index if available
- If index is stale, rescan from last known position

**Memory usage**:
- Index: 8 bytes per record (u64 position)
- For 1M records: 8 MB of index memory
- Acceptable trade-off for O(1) lookups

### LSN in Record Format

The LSN appears in two places in a WAL record:

1. **In RecordHeader**:
   - `prev_lsn` field: LSN of the previous record
   - Enables chain verification and gap detection
   - First record has prev_lsn = 0

2. **Implicitly by position**:
   - The Nth record in the file has LSN = N
   - This is the primary way LSN is determined
   - No explicit LSN field is stored in the record

**Example**:
```
Record 1: prev_lsn = 0, LSN = 1
Record 2: prev_lsn = 1, LSN = 2
Record 3: prev_lsn = 2, LSN = 3
```

The LSN itself is not stored in the record. It's determined by the record's position in the file. The prev_lsn field enables verification that no records are missing.

### Gap Detection

The prev_lsn chain enables detection of missing or corrupted records:

1. **Normal case**: Record N has prev_lsn = N-1
2. **Gap case**: Record N has prev_lsn < N-1 (records are missing)
3. **Corruption case**: prev_lsn chain is broken or invalid

**Detection algorithm**:
```rust
let mut expected_lsn = 0;
for record in wal.records() {
    if record.prev_lsn != expected_lsn {
        // Gap detected between expected_lsn and record.prev_lsn
        return Err(GapDetected);
    }
    expected_lsn = record.lsn;
}
```

### LSN Overflow

With u64, LSN overflow is practically impossible:
- At 1 million records per second
- It would take 584,942 years to overflow
- No special handling needed for V0

If LSN overflow becomes a concern (future versions):
- Use u128 for LSN
- Or reset LSN sequence after checkpoint
- Or use segmented LSN (epoch + sequence)
