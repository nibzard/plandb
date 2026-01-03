# Page Types

## Purpose

Pages are the fundamental unit of storage and I/O in NorthstarDB. Every read and write operation operates on fixed-size 16KB pages. The Page structure defines the binary format that is persisted to disk, including header metadata, checksums for corruption detection, and a payload area for type-specific data.

## Types

### Page

**Description**: A fixed-size 16KB block of storage that serves as the fundamental unit of disk I/O. Every page begins with a PageHeader followed by a variable-length payload area.

**Total Size**: Exactly 16384 bytes (16KB)

**Structure**:
- **PageHeader**: Fixed-size header (first 40 bytes)
- **Payload**: Variable-length data (remaining bytes, up to 16344 bytes)

**Invariants**:
- Total size must always equal the configured page size (default 16384 bytes)
- PageHeader must occupy exactly the first 40 bytes
- Payload length must never exceed page size minus header size
- All bytes past the payload length (within the page) are undefined and should not be read

### PageHeader

**Description**: Fixed-size metadata structure that precedes every page. Contains identification fields, page metadata, and dual checksums for integrity verification.

**Size**: Exactly 40 bytes

**Alignment**: Natural alignment (no special alignment requirements beyond field alignment)

**Fields**:

1. **magic** (u32, 4 bytes)
   - **Offset**: 0
   - **Purpose**: Page identification magic number
   - **Value**: 0x4E534442 (ASCII "NSDB")
   - **Validation**: Must equal this exact value or page is invalid
   - **Byte Order**: Little endian

2. **format_version** (u16, 2 bytes)
   - **Offset**: 4
   - **Purpose**: Format version identifier
   - **Value**: 0 for current format
   - **Validation**: Must match supported version
   - **Byte Order**: Little endian

3. **page_type** (u8, 1 byte)
   - **Offset**: 6
   - **Purpose**: Identifies what type of page this is
   - **Values**:
     - 0: meta page (database metadata)
     - 1: btree_internal (internal B+tree node)
     - 2: btree_leaf (B+tree leaf node)
     - 3: freelist (free page list)
     - 4: log_segment (WAL log segment)

4. **flags** (u8, 1 byte)
   - **Offset**: 7
   - **Purpose**: Page-specific flags and attributes
   - **Current Use**: Reserved (set to 0)
   - **Future**: May indicate encryption, compression, etc.

5. **page_id** (u64, 8 bytes)
   - **Offset**: 8
   - **Purpose**: Unique identifier for this page within the database
   - **Uniqueness**: Each allocated page has a unique ID
   - **Special Values**:
     - 0: Null/invalid page ID
     - 1: First meta page
     - 2: Second meta page
   - **Byte Order**: Little endian

6. **txn_id** (u64, 8 bytes)
   - **Offset**: 16
   - **Purpose**: Transaction ID that last modified this page
   - **Visibility**: Used for MVCC to determine if page is visible to a transaction
   - **Special Values**: 0 means page has never been modified
   - **Byte Order**: Little endian

7. **payload_len** (u32, 4 bytes)
   - **Offset**: 24
   - **Purpose**: Number of valid bytes in the payload area
   - **Maximum Value**: page_size - header_size (default: 16384 - 40 = 16344)
   - **Validation**: Must not exceed maximum payload size
   - **Byte Order**: Little endian

8. **header_crc32c** (u32, 4 bytes)
   - **Offset**: 28
   - **Purpose**: Checksum of header fields (excluding checksum fields themselves)
   - **Algorithm**: CRC32C (Castagnoli polynomial)
   - **Coverage**: Bytes 0-27 (magic through payload_len)
   - **Byte Order**: Little endian

9. **page_crc32c** (u32, 4 bytes)
   - **Offset**: 32
   - **Purpose**: Checksum of the payload area
   - **Algorithm**: CRC32C (Castagnoli polynomial)
   - **Coverage**: First payload_len bytes after header
   - **Byte Order**: Little endian

### PageType

**Description**: Enumeration of all possible page types in the database

**Size**: 1 byte (u8)

**Variants**:
- **Meta (0)**: Stores database-wide metadata (root page pointer, freelist head, etc.)
- **BtreeInternal (1)**: Internal B+tree node with keys and child page pointers
- **BtreeLeaf (2)**: B+tree leaf node with actual key-value pairs
- **Freelist (3)**: Page tracking free space available for reuse
- **LogSegment (4)**: Write-Ahead Log segment for transaction durability

## Functions

### calculateHeaderChecksum(header: PageHeader) -> u32

**Purpose**: Compute the CRC32C checksum for the header portion of the page

**Algorithm**:
1. Create a copy of the header with header_crc32c and page_crc32c fields set to zero
2. Calculate CRC32C over bytes 0-27 (magic through payload_len fields)
3. Return the resulting checksum

**Returns**: 32-bit checksum value

### validateHeaderChecksum(header: PageHeader) -> bool

**Purpose**: Verify that the stored header checksum matches the calculated value

**Algorithm**:
1. Calculate expected checksum using calculateHeaderChecksum
2. Compare with stored header_crc32c value
3. Return true if equal, false otherwise

**Returns**: Boolean indicating checksum validity

### calculatePageChecksum(payload: &[u8], length: u32) -> u32

**Purpose**: Compute the CRC32C checksum for the payload portion of the page

**Parameters**:
- payload: Reference to payload bytes
- length: Number of bytes to checksum

**Algorithm**:
1. Calculate CRC32C over the first 'length' bytes of payload
2. Return the resulting checksum

**Returns**: 32-bit checksum value

### validatePage(header: PageHeader, payload: &[u8]) -> Result<(), ValidationError>

**Purpose**: Perform complete validation of a page including all invariants and checksums

**Algorithm**:
1. Verify magic field equals 0x4E534442
2. Verify format_version is supported
3. Validate header_crc32c matches calculated header checksum
4. Validate payload_len does not exceed maximum (page_size - 40)
5. Validate page_crc32c matches calculated payload checksum
6. Return success if all validations pass

**Error Conditions**:
- InvalidMagic: Magic number does not match
- UnsupportedFormat: Format version not supported
- InvalidHeaderChecksum: Header checksum mismatch
- InvalidPayloadLength: Payload length exceeds maximum
- InvalidPageChecksum: Payload checksum mismatch

## Invariants

- **Fixed Page Size**: All pages must be exactly the configured page size (default 16KB)
- **Header Position**: PageHeader always occupies bytes 0-39
- **Magic Validation**: Magic must be 0x4E534442 ("NSDB") for valid pages
- **Checksum Integrity**: Both header and payload checksums must validate
- **Payload Bounds**: Payload length must not exceed page size minus header size
- **Type Consistency**: Page type must match expected payload structure
- **Transaction Consistency**: txn_id must monotonically increase for each page modification

## Memory Layout

### Binary Format (Byte-by-Byte)

```
Offset  Size  Field            Description
------  ----  -----            -----------
0       4     magic            0x4E534442 ("NSDB")
4       2     format_version   Format version (0)
6       1     page_type        Page type enumeration
7       1     flags            Page flags (reserved)
8       8     page_id          Unique page identifier
16      8     txn_id           Last modifying transaction ID
24      4     payload_len      Valid payload bytes
28      4     header_crc32c    Header checksum
32      4     page_crc32c      Payload checksum
36      4     [padding]        (implicit for alignment)
--      --    --               --
Total: 40 bytes                 PageHeader size
```

### Payload Area

```
Offset  Size  Description
------  ----  -----------
40      N     Payload data (where N = payload_len)
40+N    M     Undefined/trailing space (where M = page_size - 40 - N)
```

### Alignment and Padding

- All multi-byte integers use little-endian byte order
- The PageHeader structure is packed with no implicit padding
- Field offsets are explicitly defined (no compiler-dependent layout)
- Payload starts immediately at offset 40 with no padding

## Dependencies

- **Uses**: Error types module (for validation errors)
- **Used by**: Pager (for page I/O), B+tree (for node storage), WAL (for log segments)

## Rust Implementation Guidance

### Module Structure

The page types should be defined in a module hierarchy such as:
- `northstar_core::page::Page` - Main page struct
- `northstar_core::page::PageHeader` - Header structure
- `northstar_core::page::PageType` - Page type enumeration

### Type Definitions

**PageHeader**: Use `#[repr(C)]` to ensure exact binary layout matching the specification. The struct must have the exact same field order, sizes, and offsets as defined above. Consider using the `bytemuck` crate for safe byte casting if needed.

**PageType**: Implement as a Rust enum with `#[repr(u8)]` to ensure 1-byte size. Each variant should correspond to the values 0-4 as specified.

**Page**: Can be represented as a struct containing either:
- A fixed-size array `[u8; PAGE_SIZE]` for direct binary representation
- A tuple struct `(PageHeader, Vec<u8>)` for more idiomatic Rust
- A reference type `&[u8]` for zero-copy page reading

### Checksum Implementation

**CRC32C**: Use the `crc32c` or `crc-catalog` crate which provides hardware-accelerated CRC32C instructions. Do not implement CRC manually as hardware acceleration provides significant performance benefits.

**Recommended Crate**: `crc32c` crate with `hw` feature flag for acceleration

### Key Decisions

**Packed vs Aligned**: Use `#[repr(C, packed)]` for PageHeader to ensure no compiler-inserted padding. The specification defines exact offsets.

**Endianness**: All integers are stored in little-endian byte order. Use `u32::from_le_bytes()` and `u32::to_le_bytes()` for conversion when dealing with raw bytes. On little-endian platforms (most common), this is a no-op.

**Validation Strategy**: Implement validation as methods on the types:
- `PageHeader::validate(&self) -> Result<(), Error>`
- `Page::validate(&self) -> Result<(), Error>`

**Zero-Copy**: Consider using zero-copy parsing for performance. The Page can be a view into a byte buffer rather than owning data.

### Implementation Notes

1. **Header Checksum Calculation**: When computing header checksum, zero out both checksum fields before calculation. This matches the Zig implementation.

2. **Payload Validation**: Only checksum the first payload_len bytes of the payload area, not the entire remaining page space.

3. **Type Safety**: Consider using the `newtype` pattern for page IDs and transaction IDs rather than raw u64 to prevent misuse.

4. **Const Generics**: Use const generics for page size to allow compile-time configuration: `struct Page<const SIZE: usize>`.

5. **Debug Visibility**: Implement `Debug` trait that shows human-readable page type and key fields.

6. **Error Context**: When validation fails, include the page_id and what specifically failed (magic, checksum, etc.) in the error message.

### Testing Strategy

**Unit tests needed for**:
- Magic number validation (valid and invalid)
- Header checksum calculation and validation
- Payload checksum calculation and validation
- Payload length bounds checking
- Page type enumeration values
- Round-trip serialization (encode then decode)

**Property tests for**:
- Header checksum is invariant across encode/decode
- Page checksum catches single-bit errors
- Payload length rejection at boundaries (max_size, max_size+1)
- All page types have valid byte representations

**Integration scenarios**:
- Reading pages from disk validates correctly
- Writing pages produces expected binary format
- Corrupted pages are detected and rejected
- Pages from different format versions are rejected