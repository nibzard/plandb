# WAL Decoding

## Purpose

WAL decoding converts binary-encoded log records back into in-memory data structures. Decoding must be robust against corruption, validate all constraints, and handle partial reads gracefully. This is critical for crash recovery where the WAL may be incomplete or corrupted.

## Types

### DecodeError

**Description**: Errors that can occur during WAL record decoding

**Variants**:

**PayloadTooSmall**: Input data is smaller than the minimum required size
- Occurs when data length < CommitPayloadHeader.SIZE (32 bytes)

**PayloadTruncated**: Input data ends unexpectedly
- Occurs when attempting to read beyond available data
- Indicates incomplete write or corruption

**InvalidCommitMagic**: Commit payload header has wrong magic number
- commit_magic field is not 0x434D4954 ("CMIT")
- Indicates wrong record type or corruption

**InvalidReservedField**: Reserved field contains non-zero value
- reserved field is not 0 in V0 format
- May indicate future format version

**TooManyOperations**: Operation count exceeds maximum allowed
- op_count > MAX_OPERATIONS_PER_COMMIT (1000)
- Protects against memory exhaustion attacks

**InvalidOperationType**: Operation type is not recognized
- op_type is not 0 or 1
- May indicate corruption or future format version

**InvalidOperationFlags**: Operation flags field is invalid
- op_flags is not 0 in V0 format
- May indicate future format version

**KeyTooLarge**: Key length exceeds maximum allowed
- key_len > MAX_KEY_SIZE (4096 bytes)
- Protects against memory exhaustion

**ValueTooLarge**: Value length exceeds maximum allowed
- val_len > MAX_VALUE_SIZE (16,777,216 bytes)
- Protects against memory exhaustion

**PutHasNoValue**: Put operation has zero-length value
- val_len is 0 when op_type is 0 (Put)
- Indicates corruption

**DeleteHasValue**: Delete operation has non-zero value length
- val_len is not 0 when op_type is 1 (Delete)
- Indicates corruption

**KeyLengthMismatch**: Key length does not match actual key data
- key_len field does not equal key_bytes.len
- Internal consistency error

**ValueLengthMismatch**: Value length does not match actual value data
- val_len field does not equal val_bytes.len
- Internal consistency error

**ChecksumMismatch**: Payload checksum does not match calculated checksum
- Stored payload_crc32c does not match calculated CRC
- Indicates corruption or tampering

### DecodingCursor

**Description**: Tracks position and bounds during decoding

**Fields**:
- data: &[u8] - Reference to input data slice
- pos: usize - Current read position within data
- remaining: usize - Bytes remaining (data.len - pos)

**Invariants**:
- pos is always <= data.len
- remaining equals data.len - pos
- pos is incremented as bytes are consumed

## Functions

### deserializeCommitRecord(data: &[u8], allocator: Allocator) -> Result<CommitRecord, DecodeError>

**Purpose**: Deserialize a commit record from binary format

**Parameters**:
- data: &[u8] - Input binary data (the payload from WAL record)
- allocator: Allocator - Memory allocator for allocating keys, values, and arrays

**Returns**: CommitRecord on success, DecodeError on failure

**Algorithm**:

1. **Validate minimum size**:
   - If data.len < CommitPayloadHeader.SIZE (32): return PayloadTooSmall error

2. **Initialize cursor**:
   - Set pos = 0
   - Track remaining bytes as data.len

3. **Read commit payload header**:
   - Read commit_magic (u32 little-endian)
   - If not 0x434D4954: return InvalidCommitMagic error
   - Read txn_id (u64 little-endian)
   - Read root_page_id (u64 little-endian)
   - Read padding (u32, should be 0, ignored)
   - Read op_count (u32 little-endian)
   - Read reserved (u32, should be 0)
   - If reserved != 0: return InvalidReservedField error
   - If op_count > MAX_OPERATIONS_PER_COMMIT: return TooManyOperations error
   - Advance pos by 32 bytes

4. **Validate operation count against data size**:
   - If op_count is suspiciously large for remaining data: return PayloadTruncated error
   - This is a heuristic check to avoid obvious overflow

5. **Initialize mutations array**:
   - Create ArrayList with capacity for op_count mutations
   - This array will own the allocated keys and values

6. **For each operation** (repeat op_count times):
   a. **Validate operation header fits**:
      - If pos + 8 > data.len: return PayloadTruncated error
      - Operation header is 8 bytes (1 + 1 + 2 + 4)

   b. **Read operation header**:
      - Read op_type (u8) from data[pos]
      - Read op_flags (u8) from data[pos + 1]
      - Read key_len (u16 little-endian) from data[pos + 2..4]
      - Read val_len (u32 little-endian) from data[pos + 4..8]
      - Advance pos by 8

   c. **Validate operation header fields**:
      - If op_type > 1: return InvalidOperationType error
      - If op_flags != 0: return InvalidOperationFlags error
      - If key_len > MAX_KEY_SIZE: return KeyTooLarge error
      - If val_len > MAX_VALUE_SIZE: return ValueTooLarge error

   d. **Validate key and value fit in remaining data**:
      - If pos + key_len + val_len > data.len: return PayloadTruncated error

   e. **Read key data**:
      - Allocate key_copy = allocator.dupe(u8, data[pos..pos + key_len])
      - If allocation fails: return allocation error
      - Advance pos by key_len

   f. **Process by operation type**:
      - If op_type == 0 (Put):
        - If val_len == 0: return PutHasNoValue error
        - Allocate value_copy = allocator.dupe(u8, data[pos..pos + val_len])
        - If allocation fails: return allocation error
        - Advance pos by val_len
        - Create Mutation.Put { key: key_copy, value: value_copy }
        - Append to mutations array
      - If op_type == 1 (Delete):
        - If val_len != 0: return DeleteHasValue error
        - Create Mutation.Delete { key: key_copy }
        - Append to mutations array
      - Else: return InvalidOperationType error (redundant check)

7. **Create CommitRecord**:
   - Create record with:
     - txn_id from header
     - root_page_id from header
     - mutations = mutations array
     - checksum = 0 (temporary)

8. **Calculate and verify checksum**:
   - Calculate expected_checksum = record.calculatePayloadChecksum()
   - Retrieve stored_checksum from RecordHeader (passed separately)
   - If checksums don't match: return ChecksumMismatch error

9. **Set checksum and return**:
   - Set record.checksum = expected_checksum
   - Return the CommitRecord

**Error conditions**: All DecodeError variants as listed above

**Concurrency**: Single-threaded only, assumes exclusive access to allocator

**Memory allocation**:
- Allocates one Vec<Mutation> for all operations
- Allocates one Vec<u8> for each key
- Allocates one Vec<u8> for each value (Put operations only)

### CommitPayloadHeader.deserialize(reader: Reader) -> Result<CommitPayloadHeader, DecodeError>

**Purpose**: Deserialize commit payload header from a binary stream

**Parameters**:
- reader: Reader - Any type implementing read methods

**Returns**: CommitPayloadHeader on success, DecodeError on failure

**Algorithm**:

1. **Read commit_magic**:
   - Read 4 bytes as u32 little-endian
   - If not 0x434D4954: return InvalidCommitMagic error

2. **Read txn_id**:
   - Read 8 bytes as u64 little-endian

3. **Read root_page_id**:
   - Read 8 bytes as u64 little-endian

4. **Read padding**:
   - Read 4 bytes as u32 (ignored in V0)

5. **Read op_count**:
   - Read 4 bytes as u32 little-endian

6. **Read reserved**:
   - Read 4 bytes as u32
   - If not 0: return InvalidReservedField error

7. **Create and validate header**:
   - Create CommitPayloadHeader with read values
   - Call header.validate()
   - Return validation error if validation fails

8. **Return header**:
   - Return the validated CommitPayloadHeader

**Error conditions**:
- IoError: Underlying read operation failed
- InvalidCommitMagic: Magic number incorrect
- InvalidReservedField: Reserved field non-zero
- TooManyOperations: op_count exceeds maximum

## Invariants

### Decoding Safety Invariants

- **Bounds checking**: All reads must validate that sufficient bytes remain before reading
- **Position tracking**: Cursor position must always reflect actual consumption
- **Allocation success**: All allocations must succeed or propagate errors cleanly

### Data Integrity Invariants

- **Magic validation**: All magic numbers must match expected values
- **Length consistency**: All length fields must match actual data lengths
- **Checksum verification**: Payload checksum must match calculated value
- **Flag validation**: All flags must be zero in V0 format

### Operation-Specific Invariants

- **Put must have value**: val_len > 0 when op_type is 0
- **Delete has no value**: val_len == 0 when op_type is 1
- **Non-empty keys**: key_len > 0 for both Put and Delete
- **Valid ranges**: All lengths must be within documented limits

### Recovery Guarantees

- **No panic on corruption**: Decoder must return errors, never panic
- **Partial recovery**: Can skip corrupted records and continue to next valid record
- **Resource cleanup**: All allocations must be freed on error path

## Dependencies

- **Uses**: std::io::Read trait for reading from byte streams
- **Used by**: WAL replay, crash recovery

## Rust Implementation Guidance

### Module Structure

The decoding functionality should be organized as:

```
northstar_core::wal::decode
├── pub enum DecodeError
├── pub struct DecodingCursor
├── impl DecodingCursor
│   ├── pub fn new(data: &[u8]) -> Self
│   ├── pub fn remaining(&self) -> usize
│   ├── pub fn advance(&mut self, n: usize) -> Result<(), DecodeError>
│   ├── pub fn read_u8(&mut self) -> Result<u8, DecodeError>
│   ├── pub fn read_u16_le(&mut self) -> Result<u16, DecodeError>
│   ├── pub fn read_u32_le(&mut self) -> Result<u32, DecodeError>
│   ├── pub fn read_u64_le(&mut self) -> Result<u64, DecodeError>
│   └── pub fn read_bytes(&mut self, n: usize) -> Result<&[u8], DecodeError>
├── impl CommitPayloadHeader
│   └── pub fn deserialize<R: Read>(reader: &mut R) -> Result<Self, DecodeError>
└── pub fn deserialize_commit_record(
    data: &[u8],
    alloc: &Allocator
) -> Result<CommitRecord, DecodeError>
```

### Type Definitions

**DecodeError**: Use an enum with all error variants

```rust
pub enum DecodeError {
    PayloadTooSmall,
    PayloadTruncated,
    InvalidCommitMagic,
    InvalidReservedField,
    TooManyOperations,
    InvalidOperationType,
    InvalidOperationFlags,
    KeyTooLarge,
    ValueTooLarge,
    PutHasNoValue,
    DeleteHasValue,
    KeyLengthMismatch,
    ValueLengthMismatch,
    ChecksumMismatch,
    Io(std::io::Error),
}

impl From<std::io::Error> for DecodeError {
    fn from(err: std::io::Error) -> Self {
        DecodeError::Io(err)
    }
}
```

**DecodingCursor**: Helper struct for bounds-checked reading

```rust
pub struct DecodingCursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> DecodingCursor<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn remaining(&self) -> usize {
        self.data.len() - self.pos
    }

    pub fn advance(&mut self, n: usize) -> Result<(), DecodeError> {
        if self.pos + n > self.data.len() {
            return Err(DecodeError::PayloadTruncated);
        }
        self.pos += n;
        Ok(())
    }

    pub fn read_u8(&mut self) -> Result<u8, DecodeError> {
        self.advance(1)?;
        Ok(self.data[self.pos - 1])
    }

    pub fn read_u16_le(&mut self) -> Result<u16, DecodeError> {
        self.advance(2)?;
        Ok(u16::from_le_bytes([
            self.data[self.pos - 2],
            self.data[self.pos - 1],
        ]))
    }

    pub fn read_u32_le(&mut self) -> Result<u32, DecodeError> {
        self.advance(4)?;
        Ok(u32::from_le_bytes([
            self.data[self.pos - 4],
            self.data[self.pos - 3],
            self.data[self.pos - 2],
            self.data[self.pos - 1],
        ]))
    }

    pub fn read_u64_le(&mut self) -> Result<u64, DecodeError> {
        self.advance(8)?;
        Ok(u64::from_le_bytes([
            self.data[self.pos - 8],
            self.data[self.pos - 7],
            self.data[self.pos - 6],
            self.data[self.pos - 5],
            self.data[self.pos - 4],
            self.data[self.pos - 3],
            self.data[self.pos - 2],
            self.data[self.pos - 1],
        ]))
    }

    pub fn read_bytes(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        self.advance(n)?;
        Ok(&self.data[self.pos - n..self.pos])
    }
}
```

### Key Decisions

**Bounds checking**: Use DecodingCursor helper to ensure all reads are bounds-checked. This prevents panics from slice indexing.

**Error handling**: Use Result types consistently. Never use unwrap() or expect() in decoding path.

**Memory allocation**: Use allocator parameter (in Rust, use generic allocator or Box::new). In practice, use the global allocator for simplicity.

**Byte order**: Use `byteorder` crate with `ReadBytesExt` trait:

```rust
use byteorder::{LittleEndian, ReadBytesExt};

let magic = reader.read_u32::<LittleEndian>()?;
```

**Alternative**: For zero-copy decoding, use DecodingCursor that returns slices into original data.

### Implementation Notes

**Step 1: Implement DecodingCursor**
- All read methods must check bounds before advancing position
- Return DecodeError::PayloadTruncated on any bounds violation
- Provide methods for reading u8, u16, u32, u64 in little-endian
- Provide method for reading byte slices

**Step 2: Implement CommitPayloadHeader::deserialize**
- Use std::io::Read trait for generic input
- Read all 6 fields in order
- Validate commit_magic is 0x434D4954
- Validate reserved is 0
- Call validate() to check op_count limit

**Step 3: Implement deserialize_commit_record**
- Create DecodingCursor from input data
- Check minimum size (32 bytes for header)
- Deserialize CommitPayloadHeader using cursor
- Pre-allocate Vec<Mutation> with capacity from op_count
- For each operation:
  - Read operation header (8 bytes)
  - Validate op_type, op_flags, key_len, val_len
  - Validate key and value fit in remaining data
  - Allocate and copy key bytes
  - If Put: allocate and copy value bytes
  - If Delete: skip value bytes
  - Create appropriate Mutation variant
  - Append to mutations Vec
- Create CommitRecord from header and mutations
- Calculate payload checksum
- Return CommitRecord

**Step 4: Handle errors gracefully**
- Use errdefer or Drop trait to clean up allocations on error
- Ensure all allocated keys and values are freed on error path
- Never leak memory even if decoding fails

**Step 5: Optimization considerations**
- Use iterators where possible for clean code
- Consider using `arrayvec` or `smallvec` for small operation counts
- Use `bytes::Bytes` for zero-copy cloning where applicable

### Testing Strategy

**Unit tests needed for**:
- Decode valid Put operation
- Decode valid Delete operation
- Decode multiple operations in one record
- Reject invalid commit magic
- Reject non-zero reserved field
- Reject op_count exceeding maximum
- Reject op_type > 1
- Reject non-zero op_flags
- Reject oversized key
- Reject oversized value
- Reject Put with zero-length value
- Reject Delete with non-zero value length
- Handle truncated payload gracefully
- Verify checksum calculation

**Property tests for**:
- Round-trip: encode then decode produces identical data
- Corruption: corrupted data returns appropriate error
- Bounds: all reads are bounds-checked, no panics

**Fuzzing**:
- Fuzz decode with random byte sequences
- Ensure no panics occur
- Verify appropriate errors are returned

**Integration scenarios**:
- Decode commit record from actual WAL file
- Decode corrupted WAL record, verify error
- Decode record with 1000 operations (maximum)
- Measure performance of decode path

### Error Recovery Strategy

**During WAL replay**:
- When a record fails to decode: skip to next record
- Use trailer magic to find next record start
- Log the error for debugging
- Continue replaying subsequent records
- Return count of successfully decoded records

**Checksum mismatch**:
- Checksum failure indicates corruption
- Do NOT trust the corrupted record
- Skip the record and continue
- Record the LSN of corrupted record for investigation

**Partial recovery**:
- It's acceptable to recover only a prefix of the WAL
- Last successfully decoded record defines recovery point
- Truncated WAL at end is expected after crash

### Performance Considerations

**Throughput optimization**:
- Pre-allocate arrays with known capacity
- Use memcpy for bulk copying key and value data
- Consider SIMD for checksum calculation
- Minimize branching in hot path

**Memory efficiency**:
- Use precise allocations (no over-allocation)
- Free intermediate data promptly
- Consider arena allocation for many records

**CPU efficiency**:
- Bounds checking adds overhead but is necessary
- Use branchless patterns where possible
- Profile to identify bottlenecks
- Consider unsafe code only after profiling proves necessary
