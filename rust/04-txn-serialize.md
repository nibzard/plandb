# Transaction Serialization

## Purpose

Transaction serialization converts the in-memory transaction state into a byte sequence for persistence in the Write-Ahead Log (WAL). This process enables durable commits by encoding mutations, transaction metadata, and checksums into a format that can be written to disk, recovered after crashes, and replayed to restore database state. Serialization happens during the prepare phase of commit, creating a CommitRecord that contains all transaction information needed for recovery. The serialization format is designed to be compact, deterministic, and recoverable, with clear separation between transaction-level semantics and WAL-level persistence.

## Overview

### Serialization Layer Responsibilities

Transaction serialization operates at the transaction layer, converting logical transaction state into a byte payload. This layer is responsible for encoding transaction metadata (transaction ID, root page ID, operation count) and mutation operations (Put and Delete) into a structured binary format. The serialized payload is then passed to the WAL layer, which wraps it with record headers, trailers, and checksums for persistence.

**Key Distinction**: Transaction serialization (this specification) vs WAL record framing (task 3.5)
- Transaction serialization: Encodes CommitRecord with mutations into byte payload
- WAL record framing: Wraps payload with RecordHeader/RecordTrailer for persistence
- Separation of concerns: Transaction logic vs storage implementation

### Serialization Process Flow

**Prepare Phase**:
1. Transaction calls commit, entering prepare phase
2. Validate transaction state and mutations
3. Call serializeCommitRecord to create byte payload
4. Pass payload to WAL layer for appending
5. WAL adds RecordHeader and RecordTrailer
6. WAL computes checksum over entire record
7. WAL writes record to log file
8. WAL syncs log file to disk

**Recovery Process**:
1. WAL reads records from log file
2. WAL validates record-level checksums
3. WAL extracts payload from each record
4. WAL calls deserializeCommitRecord on payload
5. Transaction layer reconstructs CommitRecord
6. Transaction layer applies mutations to database

## CommitRecord Structure

### Logical Representation

**CommitRecord**: In-memory representation of a transaction for persistence
```
CommitRecord {
    txn_id: TransactionId,           // Unique transaction identifier
    root_page_id: PageId,            // New B+tree root after commit (0 if unchanged)
    mutations: Vec<Mutation>,        // Ordered list of operations
    checksum: u32,                   // Payload checksum (CRC32C)
}
```

**Mutation Enum**: Operation types
```
Mutation {
    Put { key: Vec<u8>, value: Vec<u8> },   // Insert or update key-value pair
    Delete { key: Vec<u8> },                  // Delete key
}
```

### Serialized Representation

**CommitPayloadHeader**: Fixed-size header (20 bytes)
- Commits transaction metadata for recovery
- Enables payload validation before reading mutations
- Provides transaction identification and size information

**EncodedOperations**: Variable-length operation list
- Each operation encoded independently
- Operations serialized in transaction order
- Mixed Put and Delete operations supported

**Checksum**: Payload integrity verification (4 bytes)
- CRC32C checksum over entire payload
- Computed after header and operations serialized
- Validates payload integrity during recovery

## CommitPayloadHeader Format

### Header Fields

**commit_magic**: u32 (4 bytes) - Magic number for validation
- Value: 0x434D4954 (ASCII "CMIT")
- Byte order: Little-endian
- Purpose: Identify commit payload format version
- Validation: Deserializer rejects payloads with incorrect magic

**txn_id**: u64 (8 bytes) - Transaction identifier
- Byte order: Little-endian
- Purpose: Unique identification for recovery
- Repeated from WAL RecordHeader for redundancy
- Validation: Must match RecordHeader txn_id

**root_page_id**: u64 (8 bytes) - New B+tree root page ID
- Byte order: Little-endian
- Purpose: Database state after transaction applied
- Value 0: Root page unchanged (transaction had no structural changes)
- Non-zero: New root page (B+tree split, growth, or initial state)

**op_count**: u32 (4 bytes) - Number of operations in transaction
- Byte order: Little-endian
- Purpose: Enable pre-allocation and bounds checking
- Validation: Must be less than MAX_OPERATIONS_PER_COMMIT (1000)
- Used by deserializer to loop through operations

**reserved**: u32 (4 bytes) - Reserved for future use
- Byte order: Little-endian
- Value: Must be 0 in V0
- Purpose: Future extensions without format break

### Header Layout

**Byte-by-Byte Layout** (20 bytes total):
```
Offset  Size  Field           Value
------  ----  -----           -----
0       4     commit_magic    0x54494D43 ("CMIT" little-endian)
4       8     txn_id          Transaction ID (u64)
12      8     root_page_id    Root page ID (u64)
20      4     op_count        Number of operations (u32)
24      4     reserved        0 (u32)
```

**Total Size**: 32 bytes (not 20 as initially stated - layout corrected)

**Note**: The Zig struct has implicit padding for alignment. The serialized format explicitly writes padding bytes to ensure consistent layout.

### Header Validation

**Magic Number Check**: First 4 bytes must equal "CMIT"
- Wrong magic: Invalid format or version mismatch
- Deserializer returns InvalidCommitMagic error
- Prevents misinterpreting other data as commit payload

**Transaction ID Consistency**: txn_id must match WAL RecordHeader
- Mismatch: Corruption or WAL record corruption
- Deserializer returns TxnIdMismatch error
- Ensures record integrity

**Operation Count Limit**: op_count must be less than MAX_OPERATIONS_PER_COMMIT
- Exceeds limit: TooManyOperations error
- Prevents allocation attacks and excessive memory usage
- Enforces transaction size limits

**Reserved Field Check**: reserved must be 0 in V0
- Non-zero: Future version format or corruption
- Deserializer returns InvalidReservedField error
- Ensures forward compatibility

## EncodedOperation Format

### Operation Header

**op_type**: u8 (1 byte) - Operation type identifier
- Value 0: Put operation
- Value 1: Delete operation
- Values 2-255: Reserved for future operation types

**op_flags**: u8 (1 byte) - Operation flags
- Value 0: No flags (V0)
- Bits 0-7: Reserved for future flags (compression, encryption, etc.)

**key_len**: u16 (2 bytes) - Key length in bytes
- Byte order: Little-endian
- Range: 1 to 4096 (MAX_KEY_SIZE)
- Value 0: Invalid (empty keys not allowed)

**val_len**: u32 (4 bytes) - Value length in bytes
- Byte order: Little-endian
- Range: 0 to 16,777,216 (MAX_VALUE_SIZE)
- For Delete: Must be 0
- For Put: Must be greater than 0

### Operation Data

**key_bytes**: Variable length - Key data
- Length: key_len bytes
- Content: Raw key bytes (binary safe, may contain any byte values)
- Validation: Length must match key_len

**val_bytes**: Variable length - Value data (Put only)
- Length: val_len bytes
- Content: Raw value bytes (binary safe)
- Present only for Put operations
- Validation: Length must match val_len, must be 0 for Delete

### Operation Layout

**Put Operation Layout**:
```
Offset  Size  Field           Value
------  ----  -----           -----
0       1     op_type         0 (Put)
1       1     op_flags        0
2       2     key_len         Key length (u16)
4       4     val_len         Value length (u32)
8       key_len  key_bytes     Key data
8+key_len  val_len  val_bytes   Value data
```

**Delete Operation Layout**:
```
Offset  Size  Field           Value
------  ----  -----           -----
0       1     op_type         1 (Delete)
1       1     op_flags        0
2       2     key_len         Key length (u16)
4       4     val_len         0 (u32)
8       key_len  key_bytes     Key data
```

**Total Size**: 8 + key_len + val_len bytes

### Operation Validation

**Type Validation**: op_type must be 0 (Put) or 1 (Delete)
- Invalid type: InvalidOperationType error
- Prevents deserialization of unknown operation types

**Flags Validation**: op_flags must be 0 in V0
- Non-zero flags: InvalidOperationFlags error
- Ensures forward compatibility (future versions may use flags)

**Key Length Validation**: key_len must be between 1 and MAX_KEY_SIZE
- Zero: KeyEmpty error
- Too large: KeyTooLarge error
- Ensures key fits in B+tree

**Value Length Validation**: val_len must be between 0 and MAX_VALUE_SIZE
- Too large: ValueTooLarge error
- Put with zero length: PutHasNoValue error
- Delete with non-zero length: DeleteHasValue error

**Data Bounds Validation**: Must have enough bytes for key and value
- Truncated data: PayloadTruncated error
- Prevents buffer overruns during deserialization

## Serialization Algorithm

### serializeCommitRecord

**Purpose**: Convert in-memory CommitRecord to byte payload

**Input**: CommitRecord with txn_id, root_page_id, mutations, checksum

**Output**: Byte vector containing serialized payload

**Algorithm**:

1. **Calculate Payload Size**:
   - Header size: 32 bytes (CommitPayloadHeader)
   - For each mutation: Calculate operation size
     - Put: 8 + key.len() + value.len() bytes
     - Delete: 8 + key.len() bytes
   - Sum all operation sizes
   - Total size = header size + sum of operation sizes

2. **Allocate Buffer**:
   - Allocate byte vector with total size
   - Use arena or bump allocator for efficiency (recovery path)
   - Pre-allocate to avoid resizing during serialization

3. **Serialize Header**:
   - Write commit_magic: u32, little-endian, value 0x434D4954
   - Write txn_id: u64, little-endian, from record.txn_id
   - Write root_page_id: u64, little-endian, from record.root_page_id
   - Write padding: 4 bytes of zeros (for struct alignment)
   - Write op_count: u32, little-endian, mutations.len()
   - Write reserved: u32, little-endian, value 0

4. **Serialize Operations** (in transaction order):
   - For each mutation in record.mutations:
     - Match mutation variant (Put or Delete)
     - Create EncodedOperation from mutation
     - Validate operation (size limits, type constraints)
     - Write operation to buffer

5. **Serialize Put Operation**:
   - Write op_type: u8, value 0
   - Write op_flags: u8, value 0
   - Write key_len: u16, little-endian, key.len()
   - Write val_len: u32, little-endian, value.len()
   - Write key_bytes: key.len() bytes, copy from mutation
   - Write val_bytes: value.len() bytes, copy from mutation

6. **Serialize Delete Operation**:
   - Write op_type: u8, value 1
   - Write op_flags: u8, value 0
   - Write key_len: u16, little-endian, key.len()
   - Write val_len: u32, little-endian, value 0
   - Write key_bytes: key.len() bytes, copy from mutation
   - (No val_bytes for delete)

7. **Return Payload**:
   - Return owned byte vector
   - Caller passes to WAL layer for appending

**Error Handling**:
- Allocation failure: Return AllocationFailed error
- Validation failure: Return validation error (KeyTooLarge, ValueTooLarge, etc.)
- Buffer overflow: Return BufferOverflow error (should not happen with correct size calculation)

## Deserialization Algorithm

### deserializeCommitRecord

**Purpose**: Convert byte payload to in-memory CommitRecord

**Input**: Byte slice containing serialized payload

**Output**: CommitRecord with txn_id, root_page_id, mutations, checksum

**Algorithm**:

1. **Validate Payload Size**:
   - Check payload.len() >= CommitPayloadHeader.SIZE (32 bytes)
   - If too small: Return PayloadTooSmall error

2. **Deserialize Header**:
   - Create fixed buffer stream from payload bytes
   - Read commit_magic: u32, little-endian
   - Validate magic equals 0x434D4954, else InvalidCommitMagic
   - Read txn_id: u64, little-endian
   - Read root_page_id: u64, little-endian
   - Skip 4 bytes padding
   - Read op_count: u32, little-endian
   - Read reserved: u32, little-endian
   - Validate reserved equals 0, else InvalidReservedField
   - Validate op_count <= MAX_OPERATIONS_PER_COMMIT, else TooManyOperations
   - Advance position past header: pos = 32

3. **Allocate Mutations Vector**:
   - Pre-allocate ArrayList with op_count capacity
   - Use arena allocator for efficiency (recovery path)

4. **Deserialize Operations** (loop op_count times):
   - **Bounds Check**: Ensure payload has enough bytes for operation header
     - If pos + 8 > payload.len(): Return PayloadTruncated error

   - **Read Operation Header**:
     - Read op_type: u8 from payload[pos]
     - Read op_flags: u8 from payload[pos + 1]
     - Read key_len: u16, little-endian, from payload[pos + 2..4]
     - Read val_len: u32, little-endian, from payload[pos + 4..8]
     - Advance pos: pos += 8

   - **Validate Operation Header**:
     - Validate op_type <= 1, else InvalidOperationType
     - Validate op_flags == 0, else InvalidOperationFlags
     - Validate key_len >= 1 and key_len <= MAX_KEY_SIZE, else KeyTooLarge
     - Validate val_len <= MAX_VALUE_SIZE, else ValueTooLarge

   - **Bounds Check for Data**: Ensure payload has key and value bytes
     - If pos + key_len + val_len > payload.len(): Return PayloadTruncated error

   - **Read Key Data**:
     - Allocate key buffer: allocator.dupe(u8, payload[pos..pos + key_len])
     - Advance pos: pos += key_len

   - **Branch on Operation Type**:
     - **If Put (op_type == 0)**:
       - Validate val_len > 0, else PutHasNoValue error
       - Allocate value buffer: allocator.dupe(u8, payload[pos..pos + val_len])
       - Advance pos: pos += val_len
       - Create Mutation::Put { key, value }
       - Append to mutations vector

     - **If Delete (op_type == 1)**:
       - Validate val_len == 0, else DeleteHasValue error
       - Create Mutation::Delete { key }
       - Append to mutations vector

     - **Else**:
       - Return InvalidOperationType error (should not happen after validation)

5. **Construct CommitRecord**:
   - Create CommitRecord with deserialized fields
   - Set txn_id from header
   - Set root_page_id from header
   - Set mutations from deserialized vector
   - Set checksum (computed separately by WAL layer)

6. **Return CommitRecord**:
   - Return constructed record to caller

**Error Handling**:
- Payload too small: Return PayloadTooSmall error
- Invalid magic: Return InvalidCommitMagic error
- Invalid operation type: Return InvalidOperationType error
- Invalid flags: Return InvalidOperationFlags error
- Key too large: Return KeyTooLarge error
- Value too large: Return ValueTooLarge error
- Payload truncated: Return PayloadTruncated error
- Allocation failure: Return AllocationFailed error
- Invalid put/delete constraints: Return PutHasNoValue or DeleteHasValue error

## Checksum Calculation

### Checksum Scope

**Payload-Only Checksum**: Computed over serialized payload only
- Includes: CommitPayloadHeader and all EncodedOperations
- Excludes: WAL RecordHeader and RecordTrailer
- Computed by transaction layer after serialization complete

**Separate from WAL Checksum**: Transaction checksum vs WAL checksum
- Transaction checksum: Covers payload integrity (transaction layer)
- WAL checksum: Covers entire record including headers/trailers (WAL layer)
- Two-layer validation: Payload integrity + Record integrity

### Checksum Algorithm

**Algorithm**: CRC32C (CRC-32C Castagnoli)
- Polynomial: 0x1EDC6F41 (Castagnoli)
- Widely used for storage and networking
- Hardware acceleration available on many CPUs
- Better error detection than CRC32

**Computation Steps**:
1. Initialize CRC32C hash state
2. Update hash with entire payload bytes
3. Finalize hash to 32-bit checksum
4. Store checksum in CommitRecord.checksum field
5. (Checksum NOT written to payload - used in-memory only)

**Validation During Recovery**:
1. Deserialize payload from WAL record
2. Re-compute CRC32C over deserialized payload bytes
3. Compare with stored checksum
4. Mismatch: Payload corrupted, discard transaction
5. Match: Payload valid, proceed with recovery

**Note**: The checksum is stored in the in-memory CommitRecord but NOT serialized into the payload. The WAL layer computes its own checksum over the entire record (header + payload + trailer). This separation allows the transaction layer to verify payload integrity independently of WAL record integrity.

## Example Serialization

### Example Transaction

**Transaction Operations**:
1. Put("user:1", "Alice")
2. Put("user:2", "Bob")
3. Delete("user:3")

**Transaction Metadata**:
- txn_id: 100
- root_page_id: 42
- op_count: 3

### Serialized Payload

**CommitPayloadHeader** (32 bytes):
```
Offset  Hex                 ASCII    Field
------  -------             -------  -----
00-03   54 49 4D 43        "CMIT"   commit_magic
04-0B   64 00 00 00 00 00 00 00      txn_id (100)
0C-13   2A 00 00 00 00 00 00 00      root_page_id (42)
14-17   00 00 00 00                 padding
18-1B   03 00 00 00                 op_count (3)
1C-1F   00 00 00 00                 reserved (0)
```

**Operation 1: Put("user:1", "Alice")**:
```
Offset  Hex                 ASCII        Field
------  -------             -------       -----
20-20   00                               op_type (Put)
21-21   00                               op_flags (0)
22-23   06 00                            key_len (6)
24-27   05 00 00 00                      val_len (5)
28-2D   75 73 65 72 3A 31   "user:1"     key_bytes
2E-32   41 6C 69 63 65      "Alice"      val_bytes
```
Size: 8 + 6 + 5 = 19 bytes

**Operation 2: Put("user:2", "Bob")**:
```
Offset  Hex                 ASCII        Field
------  -------             -------       -----
33-33   00                               op_type (Put)
34-34   00                               op_flags (0)
35-36   06 00                            key_len (6)
37-3A   03 00 00 00                      val_len (3)
3B-40   75 73 65 72 3A 32   "user:2"     key_bytes
41-43   42 6F 62            "Bob"        val_bytes
```
Size: 8 + 6 + 3 = 17 bytes

**Operation 3: Delete("user:3")**:
```
Offset  Hex                 ASCII        Field
------  -------             -------       -----
44-44   01                               op_type (Delete)
45-45   00                               op_flags (0)
46-47   06 00                            key_len (6)
48-4B   00 00 00 00                      val_len (0)
4C-51   75 73 65 72 3A 33   "user:3"     key_bytes
```
Size: 8 + 6 + 0 = 14 bytes

**Total Payload Size**: 32 + 19 + 17 + 14 = 82 bytes

### Hex Dump of Complete Payload

```
00000000: 54 49 4D 43 64 00 00 00 00 00 00 00 2A 00 00 00  TIMd......*....
00000010: 00 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00  ................
00000020: 00 00 06 00 05 00 00 00 75 73 65 72 3A 31 41 6C  ..........user:1Al
00000030: 69 63 65 00 06 00 03 00 00 00 75 73 65 72 3A 32  ice......user:2
00000040: 42 6F 62 01 00 06 00 00 00 00 00 75 73 65 72 3A  Bob........user:
00000050: 33                                            3
```

## Size Calculation

### Payload Size Formula

**Total Size** = Header Size + Sum of Operation Sizes

**Header Size**: 32 bytes (fixed)

**Operation Size** = 8 + key_len + val_len
- 8 bytes for operation header (op_type, op_flags, key_len, val_len)
- key_len bytes for key data
- val_len bytes for value data (0 for delete)

**Example Calculations**:

**Empty Transaction** (0 operations):
- Size = 32 + 0 = 32 bytes

**Single Put** (key=10 bytes, value=100 bytes):
- Size = 32 + (8 + 10 + 100) = 150 bytes

**Single Delete** (key=10 bytes):
- Size = 32 + (8 + 10 + 0) = 50 bytes

**Maximum Transaction** (1000 operations, avg key=32 bytes, avg value=1024 bytes):
- Size = 32 + 1000 × (8 + 32 + 1024) = 32 + 1,064,000 = ~1.06 MB

### Size Limits

**Minimum Payload Size**: 32 bytes (header only, 0 operations)
- Empty transactions allowed (no mutations)

**Maximum Payload Size**:
- Header: 32 bytes
- Max operations: 1000
- Max key size: 4096 bytes
- Max value size: 16,777,216 bytes
- Theoretical max: 32 + 1000 × (8 + 4096 + 16,777,216) = ~16.7 GB
- Practical limit: Memory constraints prevent near-max payloads

**Recommendation**: Monitor total_mutation_size during transaction to prevent excessive payload sizes

## Relationship to WAL Layer

### Layer Separation

**Transaction Layer Responsibility**:
- Serialize CommitRecord to byte payload
- Compute payload checksum
- Validate transaction semantics
- Handle operation encoding

**WAL Layer Responsibility**:
- Wrap payload with RecordHeader
- Add RecordTrailer
- Compute record checksum (header + payload + trailer)
- Write to log file
- Sync to disk
- Maintain append-only guarantee

### Data Flow

**Commit Path**:
1. Transaction: serializeCommitRecord() → byte payload
2. Transaction: Pass payload to WAL
3. WAL: Create RecordHeader with txn_id, prev_lsn, payload_len
4. WAL: Append payload
5. WAL: Create RecordTrailer with total_len, trailer_crc
6. WAL: Compute record_crc over (header + payload + trailer)
7. WAL: Write (header + payload + trailer) to log file
8. WAL: Sync log file

**Recovery Path**:
1. WAL: Read record from log file
2. WAL: Validate record_crc
3. WAL: Extract payload from (header + payload + trailer)
4. WAL: Pass payload to transaction layer
5. Transaction: deserializeCommitRecord(payload) → CommitRecord
6. Transaction: Apply mutations to database

### Interface

**Transaction Calls WAL**:
```
let payload = serialize_commit_record(&commit_record)?;
wal.append_commit_record(txn_id, &payload)?;
```

**WAL Calls Transaction** (during recovery):
```
let payload = wal.extract_payload(record)?;
let commit_record = deserialize_commit_record(&payload)?;
apply_commit_record(&commit_record)?;
```

## Performance Considerations

### Serialization Performance

**Allocation Strategy**:
- Pre-allocate buffer with exact size (no resizing)
- Use arena allocator for recovery path (bulk allocation)
- Avoid small allocations (coalesce into single buffer)

**Copy Minimization**:
- Copy key and value bytes directly (no transformation)
- Avoid intermediate buffers
- Single pass serialization

**Checksum Performance**:
- CRC32C is fast (hardware acceleration on x86)
- Compute checksum during serialization (single pass)
- Avoid second pass over payload

### Deserialization Performance

**Bounds Checking**:
- Validate payload size once before reading operations
- Check bounds before each read (prevent buffer overruns)
- Early exit on corruption (fail fast)

**Allocation Strategy**:
- Pre-allocate mutations vector with op_count capacity
- Use arena allocator for recovery path
- Allocate key and value buffers directly from payload

**Validation Cost**:
- Validate during deserialization (single pass)
- Check operation constraints as bytes read
- Avoid second validation pass

## Testing Requirements

### Unit Tests

**Serialization Tests**:
- Serialize empty transaction: 32-byte payload
- Serialize single put: Correct header and operation
- Serialize single delete: Correct header and operation
- Serialize mixed operations: Correct order and types
- Serialize maximum transaction: 1000 operations, all limits

**Deserialization Tests**:
- Deserialize valid payload: Correct CommitRecord
- Deserialize invalid magic: InvalidCommitMagic error
- Deserialize truncated payload: PayloadTruncated error
- Deserialize invalid operation type: InvalidOperationType error
- Deserialize invalid flags: InvalidOperationFlags error
- Deserialize oversized key: KeyTooLarge error
- Deserialize oversized value: ValueTooLarge error
- Deserialize put with zero value: PutHasNoValue error
- Deserialize delete with non-zero value: DeleteHasValue error

**Round-Trip Tests**:
- Serialize then deserialize: identical CommitRecord
- Serialize complex transaction: Round-trip preserves all data
- Serialize maximum transaction: Round-trip succeeds

### Integration Tests

**WAL Integration**:
- Serialize transaction, append to WAL, read back, deserialize
- Recover transaction from WAL after crash
- Validate payload checksum after WAL write

**Size Validation**:
- Empty transaction: Minimum size (32 bytes)
- Large transaction: Size calculation correct
- Maximum transaction: Size within limits

### Property Tests

**Determinism Properties**:
- Same transaction serializes to same bytes
- Serialization order preserved (operation order)
- No random or timestamp-based fields

**Round-Trip Properties**:
- deserialize(serialize(T)) == T for all valid T
- Fields preserved exactly
- No data loss or corruption

**Size Properties**:
- Payload size matches calculation
- Size = 32 + sum(operation sizes)
- Operation size = 8 + key_len + val_len

## Rust Implementation Guidance

### Type Definitions

**CommitRecord Struct**:
```
pub struct CommitRecord {
    pub txn_id: TransactionId,
    pub root_page_id: PageId,
    pub mutations: Vec<Mutation>,
    pub checksum: u32,
}
```

**Mutation Enum**:
```
pub enum Mutation {
    Put { key: Vec<u8>, value: Vec<u8> },
    Delete { key: Vec<u8> },
}
```

**CommitPayloadHeader Struct**:
```
#[repr(C)]
pub struct CommitPayloadHeader {
    pub commit_magic: u32,      // 0x434D4954 ("CMIT")
    pub txn_id: u64,
    pub root_page_id: u64,
    pub _padding: u32,
    pub op_count: u32,
    pub reserved: u32,
}

impl CommitPayloadHeader {
    pub const SIZE: usize = 32;
}
```

### Serialization Implementation

**serialize_commit_record Function**:
```
pub fn serialize_commit_record(record: &CommitRecord) -> Result<Vec<u8>, Error> {
    // Calculate payload size
    let mut size = CommitPayloadHeader::SIZE;
    for mutation in &record.mutations {
        size += 8; // operation header
        size += mutation.key_len();
        size += mutation.value_len(); // 0 for delete
    }

    // Allocate buffer
    let mut buffer = Vec::with_capacity(size);

    // Serialize header
    let header = CommitPayloadHeader {
        commit_magic: 0x434D4954,
        txn_id: record.txn_id.into(),
        root_page_id: record.root_page_id.into(),
        _padding: 0,
        op_count: record.mutations.len() as u32,
        reserved: 0,
    };
    header.serialize(&mut buffer)?;

    // Serialize operations
    for mutation in &record.mutations {
        serialize_mutation(mutation, &mut buffer)?;
    }

    Ok(buffer)
}
```

**serialize_mutation Function**:
```
fn serialize_mutation(mutation: &Mutation, buffer: &mut Vec<u8>) -> Result<(), Error> {
    match mutation {
        Mutation::Put { key, value } => {
            buffer.push(0); // op_type: Put
            buffer.push(0); // op_flags
            buffer.extend_from_slice(&(key.len() as u16).to_le_bytes());
            buffer.extend_from_slice(&(value.len() as u32).to_le_bytes());
            buffer.extend_from_slice(key);
            buffer.extend_from_slice(value);
        }
        Mutation::Delete { key } => {
            buffer.push(1); // op_type: Delete
            buffer.push(0); // op_flags
            buffer.extend_from_slice(&(key.len() as u16).to_le_bytes());
            buffer.extend_from_slice(&0u32.to_le_bytes()); // val_len = 0
            buffer.extend_from_slice(key);
        }
    }
    Ok(())
}
```

### Deserialization Implementation

**deserialize_commit_record Function**:
```
pub fn deserialize_commit_record(data: &[u8]) -> Result<CommitRecord, Error> {
    if data.len() < CommitPayloadHeader::SIZE {
        return Err(Error::PayloadTooSmall);
    }

    // Deserialize header
    let header = CommitPayloadHeader::deserialize(&data[..CommitPayloadHeader::SIZE])?;

    // Validate header
    if header.commit_magic != 0x434D4954 {
        return Err(Error::InvalidCommitMagic);
    }
    if header.reserved != 0 {
        return Err(Error::InvalidReservedField);
    }
    if header.op_count > MAX_OPERATIONS_PER_COMMIT {
        return Err(Error::TooManyOperations);
    }

    // Deserialize operations
    let mut pos = CommitPayloadHeader::SIZE;
    let mut mutations = Vec::with_capacity(header.op_count as usize);

    for _ in 0..header.op_count {
        let (mutation, bytes_read) = deserialize_mutation(&data[pos..])?;
        mutations.push(mutation);
        pos += bytes_read;
    }

    Ok(CommitRecord {
        txn_id: TransactionId::from(header.txn_id),
        root_page_id: PageId::from(header.root_page_id),
        mutations,
        checksum: 0, // Computed separately
    })
}
```

**deserialize_mutation Function**:
```
fn deserialize_mutation(data: &[u8]) -> Result<(Mutation, usize), Error> {
    if data.len() < 8 {
        return Err(Error::PayloadTruncated);
    }

    let op_type = data[0];
    let op_flags = data[1];
    let key_len = u16::from_le_bytes(data[2..4].try_into().unwrap());
    let val_len = u32::from_le_bytes(data[4..8].try_into().unwrap());

    // Validate
    if op_type > 1 {
        return Err(Error::InvalidOperationType);
    }
    if op_flags != 0 {
        return Err(Error::InvalidOperationFlags);
    }
    if key_len == 0 || key_len > MAX_KEY_SIZE as u16 {
        return Err(Error::KeyTooLarge);
    }
    if val_len > MAX_VALUE_SIZE as u32 {
        return Err(Error::ValueTooLarge);
    }

    let total_size = 8 + key_len as usize + val_len as usize;
    if data.len() < total_size {
        return Err(Error::PayloadTruncated);
    }

    let key = data[8..8 + key_len as usize].to_vec();
    let value_start = 8 + key_len as usize;

    let mutation = match op_type {
        0 => { // Put
            if val_len == 0 {
                return Err(Error::PutHasNoValue);
            }
            let value = data[value_start..value_start + val_len as usize].to_vec();
            Mutation::Put { key, value }
        }
        1 => { // Delete
            if val_len != 0 {
                return Err(Error::DeleteHasValue);
            }
            Mutation::Delete { key }
        }
        _ => unreachable!(),
    };

    Ok((mutation, total_size))
}
```

### Constants

**Size Limits**:
```
pub const MAX_OPERATIONS_PER_COMMIT: usize = 1000;
pub const MAX_KEY_SIZE: usize = 4096;
pub const MAX_VALUE_SIZE: usize = 16 * 1024 * 1024; // 16MB
```

**Magic Numbers**:
```
pub const COMMIT_MAGIC: u32 = 0x434D4954; // "CMIT"
```

### Testing Implementation

**Round-Trip Test**:
```
#[test]
fn test_round_trip() {
    let record = CommitRecord {
        txn_id: TransactionId::new(100),
        root_page_id: PageId::new(42),
        mutations: vec![
            Mutation::Put { key: b"user:1".to_vec(), value: b"Alice".to_vec() },
            Mutation::Delete { key: b"user:2".to_vec() },
        ],
        checksum: 0,
    };

    let serialized = serialize_commit_record(&record).unwrap();
    let deserialized = deserialize_commit_record(&serialized).unwrap();

    assert_eq!(deserialized.txn_id, record.txn_id);
    assert_eq!(deserialized.root_page_id, record.root_page_id);
    assert_eq!(deserialized.mutations, record.mutations);
}
```

## Dependencies

- **Uses**:
  - CommitRecord type (transaction state)
  - Mutation type (operations)
  - TransactionId type (identifier)
  - PageId type (root page)
  - Error types (validation errors)
  - Constants (MAX_OPERATIONS_PER_COMMIT, MAX_KEY_SIZE, MAX_VALUE_SIZE)

- **Used By**:
  - Transaction commit (prepare phase)
  - WAL layer (record payload)
  - Recovery (rebuild state from WAL)
  - Testing (round-trip validation)

## Related Specifications

- **Transaction Commit**: rust/04-txn-commit.md - Prepare phase and serialization trigger
- **WAL Record**: rust/03-wal-record.md - WAL record framing (header + payload + trailer)
- **WAL Encoding**: rust/03-wal-encode.md - Operation encoding format
- **WAL Decoding**: rust/03-wal-decode.md - Operation deserialization
- **Semantics**: spec/semantics_v0.md - Transaction persistence and recovery
