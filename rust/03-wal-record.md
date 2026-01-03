# WAL Record Structure

## Purpose

The WAL record is the fundamental unit of persistence in the Write-Ahead Log. Each record represents a discrete, verifiable unit of work (typically a transaction commit) that can be written, read, and replayed independently. Records are framed with headers and trailers to enable corruption detection and recovery.

## Types

### Complete Record Layout

**Description**: The binary layout of a complete WAL record from start to finish

**Structure**: A WAL record consists of three parts:

1. **RecordHeader** (40 bytes): Fixed-size header with metadata
2. **Payload** (variable size): The actual data being logged
3. **RecordTrailer** (12 bytes): Fixed-size trailer for validation

**Total size**: 40 + payload_len + 12 bytes

**Invariants**:
- Header magic must equal 0x4C4F4752 ("LOGR")
- Trailer magic must equal 0x52474F4C ("RGOL")
- All checksums must be valid for the record to be considered intact
- Payload length can be zero (checkpoint records may have minimal payload)

### RecordHeader

**Description**: Fixed-size header that precedes every WAL record

**Fields**:
- magic: u32 (4 bytes, offset 0) - Magic number 0x4C4F4752 ("LOGR" in ASCII)
- record_version: u16 (2 bytes, offset 4) - Record format version (0 for V0)
- record_type: u16 (2 bytes, offset 6) - Type of record (0=commit, 1=checkpoint, 2=cartridge_meta)
- header_len: u16 (2 bytes, offset 8) - Header length in bytes (must be 40 for V0)
- flags: u16 (2 bytes, offset 10) - Record flags (see below)
- txn_id: u64 (8 bytes, offset 12) - Transaction identifier associated with this record
- prev_lsn: u64 (8 bytes, offset 20) - LSN of previous record (0 for first record)
- payload_len: u32 (4 bytes, offset 28) - Length of payload in bytes
- header_crc32c: u32 (4 bytes, offset 32) - CRC32C checksum of header fields
- payload_crc32c: u32 (4 bytes, offset 36) - CRC32C checksum of payload data

**Size**: 40 bytes total
**Alignment**: Natural alignment (no padding required)
**Byte order**: Little-endian for all multi-byte integers

**Flag bits** (flags field):
- Bit 0 (0x01): Reserved for future use
- Bit 1 (0x02): Payload contains inline values (V0 commit records set this)
- Bits 2-15: Reserved for future use, must be zero in V0

**Invariants**:
- magic must equal 0x4C4F4752
- record_version must equal 0 for V0 format
- header_len must equal 40
- record_type must be 0, 1, or 2
- prev_lsn equals the LSN of the immediately preceding record (enables chain verification)
- header_crc32c is calculated with the header_crc32c field itself set to zero
- payload_crc32c covers the entire payload data only

### RecordTrailer

**Description**: Fixed-size trailer that follows every WAL record

**Fields**:
- magic2: u32 (4 bytes, offset 0) - Magic number 0x52474F4C ("RGOL" = "LOGR" reversed)
- total_len: u32 (4 bytes, offset 4) - Total record length including header, payload, and trailer
- trailer_crc32c: u32 (4 bytes, offset 8) - CRC32C checksum of trailer fields

**Size**: 12 bytes total
**Alignment**: Natural alignment
**Byte order**: Little-endian

**Invariants**:
- magic2 must equal 0x52474F4C
- total_len equals header_len + payload_len + 12 (trailer size)
- trailer_crc32c is calculated with the trailer_crc32c field itself set to zero
- total_len serves as a consistency check with the header's payload_len

### RecordType

**Description**: Enumeration of valid WAL record types

**Variants**:
- **COMMIT** (0): Transaction commit record containing mutations
  - Payload: CommitPayloadHeader followed by encoded operations
  - Most common record type in production workload
  - txn_id field contains the committing transaction ID

- **CHECKPOINT** (1): Checkpoint marker indicating persistent state is consistent
  - Payload: u64 transaction ID (8 bytes)
  - Written after B+tree pages are flushed to database file
  - Used during recovery to determine where to start replay

- **CARTRIDGE_META** (2): AI cartridge metadata record
  - Payload: Cartridge metadata structure (defined in Phase 7)
  - Used for persisting AI intelligence layer data
  - txn_id field may contain cartridge identifier

**Invariants**:
- Only values 0, 1, and 2 are valid in V0 format
- Unknown record types should be skipped during replay (not cause errors)

### CommitPayloadHeader

**Description**: Header specific to commit record payloads

**Fields**:
- commit_magic: u32 (4 bytes) - Magic number 0x434D4954 ("CMIT" in ASCII)
- txn_id: u64 (8 bytes) - Transaction ID (repeated from outer header for sanity)
- root_page_id: u64 (8 bytes) - New B+tree root page after commit (0 if no change)
- padding: u32 (4 bytes) - Padding bytes (must be 0, exists for alignment)
- op_count: u32 (4 bytes) - Number of encoded operations that follow
- reserved: u32 (4 bytes) - Reserved field (must be 0 in V0)

**Size**: 32 bytes total
**Alignment**: 8-byte alignment required
**Byte order**: Little-endian

**Invariants**:
- commit_magic must equal 0x434D4954
- op_count must not exceed MAX_OPERATIONS_PER_COMMIT (1000)
- reserved must equal 0
- root_page_id is 0 for transactions that don't modify the B+tree structure

### EncodedOperation

**Description**: A single operation (Put or Delete) within a commit record

**Fields**:
- op_type: u8 (1 byte) - Operation type (0 = Put, 1 = Delete)
- op_flags: u8 (1 byte) - Operation flags (must be 0 in V0)
- key_len: u16 (2 bytes) - Length of key in bytes
- val_len: u32 (4 bytes) - Length of value in bytes (must be 0 for Delete)
- key_bytes: []u8 (key_len bytes) - The key data
- val_bytes: []u8 (val_len bytes) - The value data (only present for Put)

**Size**: 8 + key_len + val_len bytes total

**Size limits**:
- MAX_KEY_SIZE: 4096 bytes (4KB)
- MAX_VALUE_SIZE: 16,777,216 bytes (16MB)
- MAX_OPERATIONS_PER_COMMIT: 1000 operations

**Invariants**:
- op_type must be 0 or 1
- op_flags must be 0 in V0
- key_len must equal the actual length of key_bytes
- val_len must equal the actual length of val_bytes for Put operations
- val_len must be 0 for Delete operations
- key_bytes.len must equal key_len
- For Put (op_type=0): val_bytes is present and val_bytes.len must equal val_len
- For Delete (op_type=1): val_bytes is absent and val_len must be 0

### Mutation

**Description**: In-memory representation of a mutation (before encoding)

**Variants**:

**Put variant**:
- key: []u8 - The key to insert or update
- value: []u8 - The value to associate with the key

**Delete variant**:
- key: []u8 - The key to delete

**Invariants**:
- Put variants must have non-empty key and non-empty value
- Delete variants must have non-empty key
- Keys and values are owned slices (copied into transaction context)

### CommitRecord

**Description**: High-level in-memory representation of a complete commit

**Fields**:
- txn_id: u64 - Unique transaction identifier
- root_page_id: u64 - B+tree root page after applying mutations
- mutations: []Mutation - Array of mutations in this transaction
- checksum: u32 - CRC32C checksum of the serialized payload

**Invariants**:
- mutations array can be empty (transaction with no operations)
- checksum must equal calculatePayloadChecksum() result
- root_page_id is 0 if the transaction doesn't create a new root

## Functions

### RecordHeader.validate() -> bool

**Purpose**: Verify that a header is well-formed

**Returns**: true if header is valid, false otherwise

**Algorithm**:
1. Check that magic equals 0x4C4F4752
2. Check that record_version equals 0
3. Check that header_len equals 40
4. Check that record_type is 0, 1, or 2
5. Calculate header_crc32c with the field set to zero
6. Compare calculated checksum with stored header_crc32c
7. Return true only if all checks pass

### RecordTrailer.validate() -> bool

**Purpose**: Verify that a trailer is well-formed

**Returns**: true if trailer is valid, false otherwise

**Algorithm**:
1. Check that magic2 equals 0x52474F4C
2. Calculate expected total_len as header_len + payload_len + 12
3. Compare with stored total_len
4. Calculate trailer_crc32c with the field set to zero
5. Compare calculated checksum with stored trailer_crc32c
6. Return true only if all checks pass

### CommitRecord.calculatePayloadChecksum() -> u32

**Purpose**: Compute CRC32C checksum of the commit record payload

**Returns**: u32 checksum value

**Algorithm**:

1. Initialize CRC32C hasher

2. Create and hash CommitPayloadHeader:
   - commit_magic = 0x434D4954
   - txn_id = self.txn_id
   - root_page_id = self.root_page_id
   - padding = 0
   - op_count = mutations.len
   - reserved = 0
   - Serialize header to bytes and update hasher

3. For each mutation in mutations:
   - If Put variant:
     - Update hasher with op_type = 0
     - Update hasher with op_flags = 0
     - Update hasher with key_len (u16 little-endian)
     - Update hasher with val_len (u32 little-endian)
     - Update hasher with key bytes
     - Update hasher with value bytes
   - If Delete variant:
     - Update hasher with op_type = 1
     - Update hasher with op_flags = 0
     - Update hasher with key_len (u16 little-endian)
     - Update hasher with val_len = 0 (u32 little-endian)
     - Update hasher with key bytes

4. Finalize hasher and return checksum

### CommitRecord.validateChecksum() -> bool

**Purpose**: Verify that the stored checksum matches the calculated one

**Returns**: true if checksums match, false otherwise

**Algorithm**:
1. Call calculatePayloadChecksum()
2. Compare result with self.checksum
3. Return true if equal, false otherwise

### CommitPayloadHeader.validate() -> Result<(), Error>

**Purpose**: Verify commit payload header fields

**Returns**: Ok(()) if valid, Error if invalid

**Error conditions**:
- InvalidReservedField: reserved field is not zero
- TooManyOperations: op_count exceeds MAX_OPERATIONS_PER_COMMIT

**Algorithm**:
1. Check if reserved equals 0, return error if not
2. Check if op_count <= MAX_OPERATIONS_PER_COMMIT, return error if not
3. Return Ok(()) if all checks pass

### EncodedOperation.validate() -> Result<(), Error>

**Purpose**: Verify encoded operation fields

**Returns**: Ok(()) if valid, Error if invalid

**Error conditions**:
- InvalidOperationFlags: op_flags is not zero
- KeyTooLarge: key_len exceeds MAX_KEY_SIZE
- ValueTooLarge: val_len exceeds MAX_VALUE_SIZE
- KeyLengthMismatch: key_len doesn't match actual key_bytes length
- ValueLengthMismatch: val_len doesn't match actual val_bytes length
- DeleteHasValue: Delete operation has non-zero val_len

**Algorithm**:
1. Check if op_flags equals 0, return error if not
2. Check if key_len <= MAX_KEY_SIZE, return error if not
3. Check if val_len <= MAX_VALUE_SIZE, return error if not
4. Check if key_bytes.len equals key_len, return error if not
5. If op_type is 0 (Put):
   - Check if val_bytes.len equals val_len, return error if not
6. If op_type is 1 (Delete):
   - Check if val_len equals 0, return error if not
7. Return Ok(()) if all checks pass

## Invariants

### Record-Level Invariants

- **Header magic validation**: magic field must equal 0x4C4F4752
- **Trailer magic validation**: magic2 field must equal 0x52474F4C
- **Version consistency**: record_version must equal 0
- **Size consistency**: total_len in trailer must equal header_len + payload_len + 12
- **Checksum integrity**: All checksums must validate for the record to be considered intact

### Payload-Level Invariants

- **Commit magic validation**: commit_magic must equal 0x434D4954
- **Operation count accuracy**: op_count must match the actual number of operations
- **Reserved fields**: All reserved fields must be zero in V0
- **Type-specific constraints**: Put operations must have values, Delete operations must not

### Chain Invariants

- **LSN monotonicity**: Each record's prev_lsn must equal the previous record's LSN
- **Transaction ID uniqueness**: Each commit record has a unique txn_id
- **Checkpoint consistency**: Checkpoint records reference valid transaction IDs

## Dependencies

- **Uses**: CRC32C hashing algorithm (std.hash.Crc32 in Zig, crc32c crate in Rust)
- **Used by**: WAL append, WAL replay, WAL recovery

## Rust Implementation Guidance

### Module Structure

The record types should be organized in a dedicated module:

```
northstar_core::wal::record
├── pub struct RecordHeader
├── pub struct RecordTrailer
├── pub enum RecordType
├── pub struct CommitPayloadHeader
├── pub struct EncodedOperation
├── pub enum Mutation
└── pub struct CommitRecord
```

### Type Definitions

**RecordHeader**: Use `#[repr(C)]` to guarantee binary layout. Implement `Debug`, `Clone`, `Copy`.

**RecordTrailer**: Use `#[repr(C)]` for binary compatibility. Implement `Debug`, `Clone`, `Copy`.

**RecordType**: Use `#[repr(u16)]` enum to control representation.

**CommitPayloadHeader**: Use `#[repr(C)]` for 8-byte alignment.

**EncodedOperation**: This should not be repr(C) as it contains variable-length data. Use a struct with methods for serialization.

**Mutation**: Use a Rust enum with variants for Put and Delete.

**CommitRecord**: Owns its mutations (use `Vec<Mutation>`).

### Key Decisions

**Checksum library**: Use the `crc32c` crate which provides hardware-accelerated CRC32C on supported platforms (Intel/AMD SSE4.2, ARM CRC extensions).

**Byte ordering**: Use `to_le_bytes()` and `from_le_bytes()` methods on integer types. For reading, use the `byteorder` crate with `LittleEndian` for stream-based reading.

**Error handling**: Create a dedicated error enum for WAL record errors:

```
pub enum RecordError {
    InvalidMagic,
    InvalidVersion,
    InvalidChecksum,
    InvalidRecordType,
    PayloadTooLarge,
    PayloadTruncated,
    InvalidCommitMagic,
    InvalidReservedField,
    TooManyOperations,
    InvalidOperationFlags,
    KeyTooLarge,
    ValueTooLarge,
    DeleteHasValue,
    KeyLengthMismatch,
    ValueLengthMismatch,
}
```

### Implementation Notes

**Step 1: Define RecordHeader**
- Use `#[repr(C, packed)]` to ensure no padding between fields
- Implement `validate()` method that checks all invariants
- Implement `calculate_header_checksum()` that computes CRC with zeroed checksum field

**Step 2: Define RecordTrailer**
- Use `#[repr(C, packed)]` for consistent binary layout
- Implement `validate()` that checks magic and consistency
- Implement `calculate_trailer_checksum()` for CRC computation

**Step 3: Define CommitPayloadHeader**
- Use `#[repr(C, packed)]` for alignment
- Implement `serialize()` that writes to a `std::io::Write` stream
- Implement `deserialize()` that reads from a `std::io::Read` stream
- Implement `validate()` that checks reserved fields and limits

**Step 4: Define EncodedOperation**
- Not a repr(C) type; contains variable-length data
- Implement `serialize()` that writes op_type, op_flags, key_len, val_len, key_bytes, val_bytes
- Implement `calculate_size()` that returns total serialized size
- Implement `validate()` that checks all size limits and constraints

**Step 5: Define Mutation enum**
```rust
pub enum Mutation {
    Put { key: Vec<u8>, value: Vec<u8> },
    Delete { key: Vec<u8> },
}
```
- Implement `get_key()` method that returns key reference for either variant
- Owns the key and value data (Vec<u8>)

**Step 6: Define CommitRecord**
- Contains txn_id, root_page_id, mutations (Vec<Mutation>), checksum
- Implement `calculate_payload_checksum()` that computes CRC over serialized payload
- Implement `validate_checksum()` that compares stored vs calculated checksum

**Step 7: Serde integration**
- Consider implementing `serde::Serialize` and `serde::Deserialize` for testing
- Do NOT use serde for on-disk format; use explicit serialization for determinism

### Testing Strategy

**Unit tests needed for**:
- RecordHeader validation with valid and invalid magic numbers
- RecordHeader checksum calculation and verification
- RecordTrailer validation with valid and invalid magic numbers
- CommitPayloadHeader validation with various op_count values
- EncodedOperation validation for Put and Delete variants
- EncodedOperation validation for oversized keys/values
- CommitRecord payload checksum calculation
- Mutation enum getKey() method for both variants

**Property tests for**:
- Round-trip serialization: serialize then deserialize produces identical data
- Checksum determinism: same data always produces same checksum
- Size calculation: calculate_size() matches actual serialized size

**Integration scenarios**:
- Create CommitRecord, serialize to WAL, replay, verify identical
- Test corrupted magic numbers are detected
- Test corrupted checksums are detected
- Test oversized operations are rejected
- Test delete operations with values are rejected

### Size Limits

These are the V0 recommended size limits. Future versions may add support for larger sizes:

```
const MAX_KEY_SIZE: u32 = 4 * 1024;           // 4KB
const MAX_VALUE_SIZE: u32 = 16 * 1024 * 1024; // 16MB
const MAX_OPERATIONS_PER_COMMIT: u32 = 1000;
const MAX_PAYLOAD_SIZE: usize = 100 * 1024 * 1024; // 100MB practical limit
```

### Binary Format Diagram

```
+------------------+
| RecordHeader     |
| - magic: u32     | 0x4C4F4752 ("LOGR")
| - version: u16   | 0
| - type: u16      | 0=commit, 1=checkpoint, 2=cartridge
| - hdr_len: u16   | 40
| - flags: u16     | V0: 0x02 (inline values)
| - txn_id: u64    | Transaction ID
| - prev_lsn: u64  | Previous LSN
| - payload_len:   | Payload size in bytes
| - hdr_crc: u32   | Header checksum
| - payload_crc:   | Payload checksum
+------------------+ <- Offset 40
| Payload          |
| (variable size)  |
+------------------+
| RecordTrailer    |
| - magic2: u32    | 0x52474F4C ("RGOL")
| - total_len: u32 | Total record size
| - trailer_crc:   | Trailer checksum
+------------------+

For commit records (type=0), payload format:
+------------------+
| CommitPayload    |
| - magic: u32     | 0x434D4954 ("CMIT")
| - txn_id: u64    | (repeated)
| - root_page: u64 | New B+tree root
| - padding: u32   | 0
| - op_count: u32  | Number of operations
| - reserved: u32  | 0
+------------------+
| EncodedOperation |
| - op_type: u8    | 0=Put, 1=Del
| - flags: u8      | 0 (V0)
| - key_len: u16   | Key size
| - val_len: u32   | Value size (0 for Del)
| - key_bytes      |
| - val_bytes      | (only for Put)
+------------------+
| ... more ops     |
+------------------+
```
