# Pager Header

## Purpose

The Pager header specification describes the file identification and versioning mechanisms for NorthstarDB database files. Unlike traditional database systems that use a separate file header, NorthstarDB V0 uses the meta pages themselves as the file header, with the dual meta page scheme providing both atomic update capability and file identification. This specification details the meta page structure with offsets and sizes, magic bytes, versioning, and endianness handling.

## No Separate File Header

### Design Choice: Meta Pages Serve as File Header

**Traditional Approach**: Separate file header at beginning of file
- Contains database identification, version, page size
- Fixed location (offset 0)
- Read first to open database

**NorthstarDB V0 Approach**: No separate file header
- File begins directly with meta pages (Page 0 and Page 1)
- Meta pages contain file identification and configuration
- Eliminates separate header structure
- Simplifies file format

**Rationale**:
- Dual meta pages already contain identification fields
- No need for redundant header structure
- Atomic meta page updates work more cleanly
- Simpler file format (pages all the way)

**Implications**:
- Database identification requires reading meta pages
- Both meta pages must be validated on open
- No global configuration outside meta pages
- File is simply a sequence of pages from start to end

## Meta Page Structure

### Meta Page Layout

**Location**: Pages 0 (Meta A) and 1 (Meta B) at file start

**Total Size**: One page (16384 bytes for default page size)

**Two Sections**:
1. PageHeader (40 bytes) - Common page header
2. MetaPayload (variable) - Meta-specific data

### PageHeader Fields (First 40 Bytes)

**Purpose**: Common header for all pages, provides page identification

**Fields** (offsets in bytes):
- **Offset 0-3**: magic (u32) - Page magic number 0x4E534442 ("NSDB")
- **Offset 4-5**: format_version (u16) - Database format version (0 for V0)
- **Offset 6**: page_type (u8) - Page type enumeration (0 = meta)
- **Offset 7**: flags (u8) - Page flags (must be 0 in V0)
- **Offset 8-15**: page_id (u64) - Page identifier (0 for Meta A, 1 for Meta B)
- **Offset 16-23**: txn_id (u64) - Transaction ID of last write
- **Offset 24-27**: payload_len (u32) - Bytes used in payload section
- **Offset 28-31**: header_crc32c (u32) - Header checksum
- **Offset 32-35**: page_crc32c (u32) - Page payload checksum
- **Offset 36-39**: Reserved for future use (4 bytes)

**Total Header Size**: 40 bytes

### MetaPayload Fields (After PageHeader)

**Purpose**: Meta-specific database configuration and state

**Fields** (offsets from start of payload):
- **Offset 0-3**: meta_magic (u32) - Meta payload magic 0x4D455441 ("META")
- **Offset 4-5**: format_version (u16) - Meta format version (0 for V0)
- **Offset 6-7**: page_size (u16) - Database page size (16384 for default)
- **Offset 8-15**: committed_txn_id (u64) - Highest committed transaction ID
- **Offset 16-23**: root_page_id (u64) - Root of B+tree (0 if empty)
- **Offset 24-31**: freelist_head_page_id (u64) - Head of free list (0 if none)
- **Offset 32-39**: log_tail_lsn (u64) - Last commit record position
- **Offset 40-43**: meta_crc32c (u32) - Meta payload checksum
- **Offset 44-47**: Reserved for future use (4 bytes)

**Total MetaPayload Size**: 48 bytes

**Complete Meta Page Size**: 40 (header) + 48 (payload) = 88 bytes used

**Remaining Space**: 16384 - 88 = 16296 bytes unused (reserved for future)

## Magic Bytes and Versioning

### Magic Numbers

**Purpose**: Identify valid database files and structures

**Page Magic (PAGE_MAGIC)**: 0x4E534442
- **ASCII**: "NSDB" (NorthstarDB)
- **Location**: First 4 bytes of every page
- **Validation**: First check when reading any page
- **Purpose**: Distinguishes NorthstarDB pages from random data

**Meta Magic (META_MAGIC)**: 0x4D455441
- **ASCII**: "META"
- **Location**: First 4 bytes of MetaPayload
- **Validation**: Confirms meta page structure integrity
- **Purpose**: Distinguishes meta pages from other page types

**Format Version**: 0 (u16)
- **Location**: PageHeader offset 4 and MetaPayload offset 4
- **Current Value**: 0 (initial format)
- **Future**: Incremented for incompatible format changes
- **Validation**: Database refuses to open unsupported versions

### Validation Chain

**Page Validation**:
1. Read first 4 bytes, verify PAGE_MAGIC (0x4E534442)
2. Read format_version, verify supported value (0)
3. Read page_type, verify known value
4. Calculate and verify header_crc32c
5. Calculate and verify page_crc32c

**Meta Validation**:
1. Pass page validation (PAGE_MAGIC correct)
2. Verify page_type == 0 (meta page)
3. Read MetaPayload magic, verify META_MAGIC (0x4D455441)
4. Read MetaPayload format_version, verify 0
5. Calculate and verify meta_crc32c

**Failure Consequences**:
- Invalid PAGE_MAGIC: Not a NorthstarDB file
- Unsupported format_version: Incompatible database version
- Invalid META_MAGIC: Corrupted meta page
- Checksum failure: Corrupted data

## Endianness Handling

### Little-Endian Byte Order

**Specification**: All multi-byte integers stored in little-endian

**Rationale**:
- Matches most common CPU architectures (x86, x86_64, ARM)
- Standard for modern file formats
- Simplifies cross-platform compatibility

**Affected Fields**:
- All u16, u32, u64 fields in PageHeader
- All u16, u32, u64 fields in MetaPayload
- All multi-byte fields throughout file format

**Implementation**:
- Zig: Use built-in integer to bytes conversion (little-endian default on most platforms)
- Rust: Use to_le_bytes() and from_le_bytes() methods
- Explicit conversion ensures correctness regardless of host platform

**Example**:
```rust
// Write page_id in little-endian
let page_id_bytes = page_id.to_le_bytes();

// Read page_id from little-endian bytes
let page_id = u64::from_le_bytes(&bytes[8..16]);
```

### Cross-Platform Compatibility

**Big-Endian Platforms**: Rare but exist (some legacy systems)

**Handling**: Explicit byte order conversion
- Always read with from_le_bytes()
- Always write with to_le_bytes()
- Byte swapping performed on big-endian platforms
- No-op on little-endian platforms

**Validation**: Magic numbers help detect endianness issues
- Magic bytes appear backwards if read with wrong endianness
- 0x4E534442 becomes 0x4244534E if byte-swapped
- Easy to detect during validation

## Header Implementation

### Rust Type Definition

**PageHeader Structure**:
```rust
#[repr(C)]
pub struct PageHeader {
    pub magic: u32,           // 0x4E534442 ("NSDB")
    pub format_version: u16,  // 0 for V0
    pub page_type: u8,        // 0=meta, 1=internal, 2=leaf, etc.
    pub flags: u8,            // 0 for V0
    pub page_id: u64,         // Page identifier
    pub txn_id: u64,          // Last modifying transaction
    pub payload_len: u32,     // Payload bytes used
    pub header_crc32c: u32,   // Header checksum
    pub page_crc32c: u32,     // Payload checksum
    pub reserved: [u8; 4],    // Reserved
}
```

**MetaPayload Structure**:
```rust
#[repr(C)]
pub struct MetaPayload {
    pub meta_magic: u32,           // 0x4D455441 ("META")
    pub format_version: u16,       // 0 for V0
    pub page_size: u16,            // 16384 for default
    pub committed_txn_id: u64,     // Highest committed txn
    pub root_page_id: u64,         // B+tree root
    pub freelist_head_page_id: u64, // Free list head
    pub log_tail_lsn: u64,         // Last commit record
    pub meta_crc32c: u32,          // Payload checksum
    pub reserved: [u8; 4],         // Reserved
}
```

### Header Validation

**Validation Function**:
```rust
impl PageHeader {
    pub fn validate(&self) -> Result<(), HeaderError> {
        // Check magic number
        if self.magic != PAGE_MAGIC {
            return Err(HeaderError::InvalidMagic {
                expected: PAGE_MAGIC,
                found: self.magic,
            });
        }

        // Check format version
        if self.format_version != 0 {
            return Err(HeaderError::UnsupportedVersion {
                version: self.format_version,
            });
        }

        // Check page type
        if self.page_type > 4 {
            return Err(HeaderError::InvalidPageType {
                page_type: self.page_type,
            });
        }

        // Verify header checksum
        let calculated = self.calculate_header_checksum();
        if self.header_crc32c != calculated {
            return Err(HeaderError::HeaderChecksumMismatch);
        }

        Ok(())
    }
}
```

## Invariants

- **Magic Numbers**: PAGE_MAGIC and META_MAGIC must match expected values
- **Version Numbers**: format_version must be 0 (V0)
- **Page Size**: page_size must be power of 2 and at least 4096
- **Checksums**: All checksums must validate before trusting contents
- **Byte Order**: All multi-byte values in little-endian
- **Page IDs**: Meta A has page_id 0, Meta B has page_id 1
- **Dual Meta**: Exactly two meta pages exist (0 and 1)

## Dependencies

- **Uses**: Constants (magic numbers, version values), Checksum module
- **Used by**: Pager (open, validation), Database initialization

## Rust Implementation Guidance

### Module Structure

Header types in pager module:
- northstar_core::pager::PageHeader - Common page header
- northstar_core::pager::MetaPayload - Meta page payload

### Constants

Define magic numbers as constants:
```rust
pub const PAGE_MAGIC: u32 = 0x4E534442; // "NSDB"
pub const META_MAGIC: u32 = 0x4D455441; // "META"
pub const FORMAT_VERSION: u16 = 0;
pub const DEFAULT_PAGE_SIZE: u16 = 16384;
```

### Byte Order Conversion

Use standard library methods:
```rust
// Write u64 to bytes
let bytes = value.to_le_bytes();

// Read u64 from bytes
let value = u64::from_le_bytes(&bytes[offset..offset+8]);
```

### Testing Strategy

**Unit tests needed for**:
- PageHeader magic number validation
- MetaPayload magic number validation
- Version number validation (reject non-zero)
- Byte order conversion correctness
- Checksum calculation and validation
- Header size matches expected (40 + 48 bytes)

**Property tests for**:
- Round-trip serialization (header -> bytes -> header)
- Checksums change when header fields change
- Invalid magic numbers rejected
- Unsupported versions rejected

**Integration tests for**:
- Meta page validation on database open
- Corrupted meta page detection
- Endianness handling on different platforms
