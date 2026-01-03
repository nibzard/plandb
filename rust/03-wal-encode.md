# WAL Encoding

## Purpose

WAL encoding defines how operations and commit records are converted to binary format for persistent storage. The encoding must be deterministic (same input always produces same output), compact (minimal overhead), and language-agnostic (works across Zig, Rust, and other implementations).

## Types

### EncodedOperation

**Description**: Binary encoding of a single database operation (Put or Delete)

**Fixed header** (8 bytes):
- op_type: u8 (1 byte, offset 0) - Operation type (0 = Put, 1 = Delete)
- op_flags: u8 (1 byte, offset 1) - Operation flags (must be 0 in V0)
- key_len: u16 (2 bytes, offset 2) - Length of key in bytes (little-endian)
- val_len: u32 (4 bytes, offset 4) - Length of value in bytes (little-endian, must be 0 for Delete)

**Variable data**:
- key_bytes: []u8 (key_len bytes) - The key data
- val_bytes: []u8 (val_len bytes) - The value data (only for Put operations)

**Total size**: 8 + key_len + val_len bytes

**Byte order**: Little-endian for all multi-byte integers

### CommitPayloadHeader

**Description**: Binary encoding of commit record metadata

**Fields**:
- commit_magic: u32 (4 bytes) - Magic number 0x434D4954 ("CMIT")
- txn_id: u64 (8 bytes) - Transaction ID (repeated from outer header)
- root_page_id: u64 (8 bytes) - New B+tree root page after commit
- padding: u32 (4 bytes) - Padding for alignment (must be 0)
- op_count: u32 (4 bytes) - Number of encoded operations that follow
- reserved: u32 (4 bytes) - Reserved field (must be 0 in V0)

**Total size**: 32 bytes

## Functions

### EncodedOperation.serialize(writer: Writer) -> Result<(), Error>

**Purpose**: Write an encoded operation to a binary stream

**Parameters**:
- writer: Writer - Any type implementing write/writeInt methods

**Returns**: Result indicating success or I/O error

**Algorithm**:

1. **Write op_type**: Write single byte containing 0 (Put) or 1 (Delete)

2. **Write op_flags**: Write single byte containing 0 (V0 has no flags defined)

3. **Write key_len**: Write u16 in little-endian format
   - Convert key_len to bytes using little-endian
   - Write exactly 2 bytes

4. **Write val_len**: Write u32 in little-endian format
   - Convert val_len to bytes using little-endian
   - Write exactly 4 bytes

5. **Write key_bytes**: Write the key data
   - Write exactly key_len bytes
   - No transformation or encoding on the key data itself

6. **Write val_bytes** (Put only): Write the value data
   - If op_type is 0 (Put): Write exactly val_len bytes
   - If op_type is 1 (Delete): Skip this step (Delete has no value)

**Error conditions**:
- IoError: Underlying write operation failed

**Concurrency**: Single-threaded only, assumes exclusive access to writer

### EncodedOperation.calculateSerializedSize() -> usize

**Purpose**: Calculate the total byte size of the serialized operation

**Returns**: Total size in bytes

**Algorithm**:

1. **Start with header size**: Base size is 8 bytes (1 + 1 + 2 + 4)

2. **Add key size**: Add key_len bytes for key_bytes

3. **Add value size** (Put only):
   - If op_type is 0 (Put): Add val_len bytes
   - If op_type is 1 (Delete): Add 0 bytes

4. **Return total**: Return the sum

### CommitPayloadHeader.serialize(writer: Writer) -> Result<(), Error>

**Purpose**: Write commit payload header to a binary stream

**Parameters**:
- writer: Writer - Any type implementing writeInt methods

**Returns**: Result indicating success or I/O error

**Algorithm**:

1. **Write commit_magic**: Write u32 value 0x434D4954 in little-endian

2. **Write txn_id**: Write u64 transaction ID in little-endian

3. **Write root_page_id**: Write u64 page ID in little-endian

4. **Write padding**: Write u32 value 0 (4 zero bytes) for alignment

5. **Write op_count**: Write u32 operation count in little-endian

6. **Write reserved**: Write u32 value 0 (reserved field, must be zero in V0)

**Error conditions**:
- IoError: Underlying write operation failed

### serializeCommitRecord(record: &CommitRecord) -> Vec<u8>

**Purpose**: Serialize a complete commit record to binary format

**Parameters**:
- record: &CommitRecord - Reference to commit record to serialize

**Returns**: Vec<u8> containing the serialized payload

**Algorithm**:

1. **Create buffer**: Initialize a growable buffer for output

2. **Serialize payload header**:
   - Create CommitPayloadHeader with:
     - commit_magic = 0x434D4954
     - txn_id = record.txn_id
     - root_page_id = record.root_page_id
     - padding = 0
     - op_count = record.mutations.len
     - reserved = 0
   - Call CommitPayloadHeader.serialize() to write header to buffer

3. **For each mutation** in record.mutations:
   - If mutation is Put:
     - Create EncodedOperation with:
       - op_type = 0
       - op_flags = 0
       - key_len = put.key.len
       - val_len = put.value.len
       - key_bytes = put.key
       - val_bytes = put.value
     - Call EncodedOperation.validate() to verify constraints
     - Call EncodedOperation.serialize() to write to buffer
   - If mutation is Delete:
     - Create EncodedOperation with:
       - op_type = 1
       - op_flags = 0
       - key_len = delete.key.len
       - val_len = 0
       - key_bytes = delete.key
       - val_bytes = empty slice
     - Call EncodedOperation.validate() to verify constraints
     - Call EncodedOperation.serialize() to write to buffer

4. **Return buffer**: Return the serialized bytes

**Error conditions**:
- InvalidChecksum: Record checksum validation failed
- KeyTooLarge: Key exceeds MAX_KEY_SIZE
- ValueTooLarge: Value exceeds MAX_VALUE_SIZE
- TooManyOperations: Operation count exceeds MAX_OPERATIONS_PER_COMMIT
- InvalidOperationFlags: op_flags is not zero
- DeleteHasValue: Delete operation has non-zero val_len
- IoError: Buffer write failed

## Invariants

### Operation Encoding Invariants

- **Deterministic**: Same operation always produces same byte sequence
- **Little-endian**: All multi-byte integers use little-endian byte order
- **Contiguous**: No gaps or padding between fields (except explicit padding in CommitPayloadHeader)
- **Length-prefixed**: All variable-length data is preceded by exact length
- **Type-first**: Operation type is the first byte for easy identification

### Size Limit Invariants

- **Key limit**: No key may exceed 4096 bytes (4KB)
- **Value limit**: No value may exceed 16,777,216 bytes (16MB)
- **Operation limit**: No commit may exceed 1000 operations
- **Practical limit**: Total payload should stay under 100MB for performance

### Delete Operation Invariants

- **Zero value length**: val_len must be 0 for Delete operations
- **No value bytes**: val_bytes is absent for Delete operations
- **Non-empty key**: Delete must have a key to delete

### Put Operation Invariants

- **Non-zero value length**: val_len must be greater than 0 for Put operations
- **Value present**: val_bytes must contain exactly val_len bytes
- **Non-empty key**: Put must have a key to insert

## Dependencies

- **Uses**: std::io::Write trait for serialization
- **Used by**: WAL append operation, commit record construction

## Rust Implementation Guidance

### Module Structure

The encoding functionality should be organized as:

```
northstar_core::wal::encode
├── pub struct EncodedOperation
├── impl EncodedOperation
│   ├── pub fn serialize<W: Write>(&self, writer: &mut W) -> Result<()>
│   ├── pub fn calculate_serialized_size(&self) -> usize
│   └── pub fn validate(&self) -> Result<(), EncodeError>
├── pub struct CommitPayloadHeader
├── impl CommitPayloadHeader
│   ├── pub fn serialize<W: Write>(&self, writer: &mut W) -> Result<()>
│   └── pub fn validate(&self) -> Result<(), EncodeError>
└── pub fn serialize_commit_record(record: &CommitRecord) -> Result<Vec<u8>, EncodeError>
```

### Type Definitions

**EncodedOperation**: Not a repr(C) type; contains variable-length data

```rust
pub struct EncodedOperation<'a> {
    pub op_type: u8,
    pub op_flags: u8,
    pub key_len: u16,
    pub val_len: u32,
    pub key_bytes: &'a [u8],
    pub val_bytes: &'a [u8],
}
```

- Uses lifetime parameter to borrow key/value data
- No Copy or Clone due to lifetime
- All fields are public for easy construction

**CommitPayloadHeader**: Use `#[repr(C)]` for binary compatibility

```rust
#[repr(C, packed)]
pub struct CommitPayloadHeader {
    pub commit_magic: u32,
    pub txn_id: u64,
    pub root_page_id: u64,
    pub padding: u32,
    pub op_count: u32,
    pub reserved: u32,
}
```

### Key Decisions

**Byte order**: Use `byteorder` crate with `LittleEndian` for explicit byte ordering:

```rust
use byteorder::{LittleEndian, WriteBytesExt};

writer.write_u8(self.op_type)?;
writer.write_u8(self.op_flags)?;
writer.write_u16::<LittleEndian>(self.key_len)?;
writer.write_u32::<LittleEndian>(self.val_len)?;
```

**Alternative**: Use `to_le_bytes()` and `write_all()` for zero-allocation encoding:

```rust
writer.write_all(&self.key_len.to_le_bytes())?;
```

**Error handling**: Create a dedicated EncodeError enum:

```rust
pub enum EncodeError {
    Io(std::io::Error),
    KeyTooLarge,
    ValueTooLarge,
    TooManyOperations,
    InvalidOperationFlags,
    DeleteHasValue,
    KeyLengthMismatch,
    ValueLengthMismatch,
}

impl From<std::io::Error> for EncodeError {
    fn from(err: std::io::Error) -> Self {
        EncodeError::Io(err)
    }
}
```

**Buffer allocation**: Use `Vec<u8>` with initial capacity:

```rust
let mut buffer = Vec::with_capacity(estimate_size(&record));
```

### Implementation Notes

**Step 1: Implement EncodedOperation::serialize**
- Use `std::io::Write` trait for flexibility
- Write fields in exact order: op_type, op_flags, key_len, val_len, key_bytes, val_bytes
- For Delete (op_type=1), skip writing val_bytes
- Use `write_all()` to ensure complete writes

**Step 2: Implement EncodedOperation::calculate_serialized_size**
- Start with 8 (header size)
- Add key_len
- If Put (op_type=0): add val_len
- If Delete (op_type=1): add 0

**Step 3: Implement EncodedOperation::validate**
- Check op_flags == 0
- Check key_len <= MAX_KEY_SIZE
- Check val_len <= MAX_VALUE_SIZE
- Check key_bytes.len() == key_len
- For Put: check val_bytes.len() == val_len
- For Delete: check val_len == 0

**Step 4: Implement CommitPayloadHeader::serialize**
- Write all 6 fields in order
- Use little-endian for all multi-byte values
- Padding and reserved must be written as zeros

**Step 5: Implement serialize_commit_record**
- Create Vec<u8> with reasonable initial capacity
- Create and serialize CommitPayloadHeader
- Iterate through mutations
- For each mutation, create EncodedOperation
- Validate before serializing
- Serialize to buffer
- Return buffer

**Step 6: Optimization - zero-copy where possible**
- Use slices instead of owned data where possible
- Avoid intermediate allocations
- Consider using `std::io::Cursor<Vec<u8>>` for writeable buffer

### Testing Strategy

**Unit tests needed for**:
- Serialize Put operation, verify exact byte sequence
- Serialize Delete operation, verify no value bytes written
- Serialize multiple operations, verify correct concatenation
- Calculate serialized size matches actual serialization
- Validate reject oversized keys
- Validate reject oversized values
- Validate reject Delete with non-zero val_len
- Validate reject non-zero op_flags

**Property tests for**:
- Round-trip: serialize then deserialize produces identical data
- Size accuracy: calculate_serialized_size() equals actual serialized length
- Determinism: same operation produces same bytes every time

**Integration scenarios**:
- Serialize commit record with 1000 Put operations
- Serialize commit record with mixed Put and Delete operations
- Verify serialized data matches expected binary format with hex dump

### Binary Format Examples

**Put operation** (key = "user:123", value = "Alice"):
```
Offset 0: 00          // op_type = Put
Offset 1: 00          // op_flags = 0
Offset 2-3: 08 00     // key_len = 8 (little-endian)
Offset 4-7: 05 00 00 00 // val_len = 5 (little-endian)
Offset 5-12: 75 73 65 72 3A 31 32 33 // "user:123"
Offset 13-17: 41 6C 69 63 65 // "Alice"
Total: 18 bytes
```

**Delete operation** (key = "user:456"):
```
Offset 0: 01          // op_type = Delete
Offset 1: 00          // op_flags = 0
Offset 2-3: 08 00     // key_len = 8 (little-endian)
Offset 4-7: 00 00 00 00 // val_len = 0 (little-endian)
Offset 5-12: 75 73 65 72 3A 34 35 36 // "user:456"
Total: 13 bytes
```

**Complete commit record** with 2 operations:
```
CommitPayloadHeader (32 bytes):
  00-03: 54 49 4D 43       // "CMIT" magic
  04-11: 01 00 00 00 00 00 00 00 // txn_id = 1
  12-19: 05 00 00 00 00 00 00 00 // root_page_id = 5
  20-23: 00 00 00 00       // padding = 0
  24-27: 02 00 00 00       // op_count = 2
  28-31: 00 00 00 00       // reserved = 0

Operation 1: Put("key1", "value1") (17 bytes)
  32-32: 00                // op_type = Put
  33-33: 00                // op_flags = 0
  34-35: 04 00             // key_len = 4
  36-39: 06 00 00 00       // val_len = 6
  40-43: 6B 65 79 31       // "key1"
  44-49: 76 61 6C 75 65 31 // "value1"

Operation 2: Delete("key2") (13 bytes)
  50-50: 01                // op_type = Delete
  51-51: 00                // op_flags = 0
  52-53: 04 00             // key_len = 4
  54-57: 00 00 00 00       // val_len = 0
  58-61: 6B 65 79 32       // "key2"

Total payload: 62 bytes
```

### Performance Considerations

**Throughput optimization**:
- Pre-allocate buffer with estimated capacity
- Use `write_all()` instead of multiple small writes
- Avoid copying key/value data (use slices)
- Consider using `BytesMut` from bytes crate for zero-copy cloning

**Memory efficiency**:
- Use references instead of owned data during encoding
- Reuse buffers where possible
- Drop encoded data promptly after writing to WAL

**CPU efficiency**:
- CRC32C calculation should be incremental during serialization
- Consider SIMD-accelerated CRC32C (hardware instruction on modern CPUs)
- Minimize branches in hot serialization path
