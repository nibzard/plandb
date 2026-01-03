# Constants

## Purpose

Constants define the fixed values, magic numbers, and configuration limits used throughout NorthstarDB. These values control database behavior, provide identification for data structures, and enforce safety boundaries. This specification organizes constants by module, explains the meaning of magic numbers, and defines the Rust module structure for organizing constants.

## Pager Constants

### Magic Numbers

**PAGE_MAGIC: 0x4E534442 (u32)**
- **ASCII Interpretation**: "NSDB" (NorthstarDB)
- **Purpose**: Identifies valid database pages at the start of each page
- **Location**: First 4 bytes of every page (offset 0)
- **Validation**: Used to detect corruption and identify database files
- **Rationale**: Human-readable ASCII makes debugging and hex dumps easier

**META_MAGIC: 0x4D455441 (u32)**
- **ASCII Interpretation**: "META"
- **Purpose**: Identifies metadata payload structures within meta pages
- **Location**: First 4 bytes of MetaPayload structure
- **Validation**: Confirms meta page structure integrity
- **Rationale**: Distinguishes metadata from other page payloads

**BTREE_MAGIC: 0x42545245 (u32)**
- **ASCII Interpretation**: "BTRE"
- **Purpose**: Identifies B+tree node structures
- **Location**: First 4 bytes of B+tree node header
- **Validation**: Confirms B+tree node integrity during traversal
- **Rationale**: Quick validation of B+tree page type

### Page Constants

**DEFAULT_PAGE_SIZE: 16384 (u16)**
- **Human-Readable**: 16 kilobytes
- **Purpose**: Default size for each page in the database
- **Range**: Valid page sizes are 4096, 8192, 16384, 32768, or 65536 bytes
- **Rationale**: Balances I/O overhead (smaller pages) with space efficiency (larger pages)
- **Trade-offs**: Larger pages reduce overhead but waste space for small values

**FORMAT_VERSION: 0 (u16)**
- **Purpose**: Identifies the database format version for compatibility checking
- **Current Value**: 0 (initial format)
- **Future Use**: Increment when incompatible changes are made to file format
- **Validation**: Database refuses to open files with unsupported format versions

### Page Type Enumerations

**PageType Enum Values**:
- **meta: 0** - Metadata pages containing database state
- **btree_internal: 1** - Internal B+tree nodes (keys and child pointers)
- **btree_leaf: 2** - B+tree leaf nodes (actual key-value pairs)
- **freelist: 3** - Free list pages tracking available space
- **log_segment: 4** - Write-Ahead Log segment pages

**Purpose**: Distinguishes page types for validation and routing

**Range**: 0 to 255 (u8), with values 5-255 reserved for future use

### Reserved Page IDs

**META_A_PAGE_ID: 0 (u64)**
- **Purpose**: First metadata page (primary copy)
- **Location**: First page in database file
- **Persistence**: Contains committed transaction ID, root page pointer, freelist head
- **Twin Page**: Paired with META_B_PAGE_ID for atomic updates

**META_B_PAGE_ID: 1 (u64)**
- **Purpose**: Second metadata page (alternate copy)
- **Location**: Second page in database file
- **Persistence**: Mirrors META_A_PAGE_ID for two-phase commit
- **Atomicity**: Only one meta page is active at a time (highest committed_txn_id wins)

**FIRST_DATA_PAGE: 2 (u64)**
- **Purpose**: First page available for data allocation
- **All IDs >= 2**: Available for B+tree nodes, WAL segments, freelist pages
- **Excluded**: IDs 0 and 1 are permanently reserved for meta pages

## WAL (Write-Ahead Log) Constants

### Record Magic Numbers

**COMMIT_MAGIC: 0x434D4954 (u32)**
- **ASCII Interpretation**: "CMIT" (Commit)
- **Purpose**: Identifies commit record payloads in the WAL
- **Location**: First 4 bytes of CommitPayloadHeader
- **Validation**: Ensures WAL record structure integrity during recovery
- **Rationale**: Quick corruption detection before parsing

### Operation Type Values

**EncodedOperation Type Values**:
- **Put: 0** - Insert or update operation
- **Delete: 1** - Delete operation

**Purpose**: Distinguishes operation types in WAL records

**Range**: 0 to 255 (u8), with values 2-255 reserved for future operation types

## Transaction Constants

### Size Limits

**MAX_KEY_SIZE: 4096 (u32)**
- **Human-Readable**: 4 kilobytes
- **Purpose**: Maximum allowed size for a key in any operation
- **Rationale**: Prevents excessively large keys that degrade performance
- **Enforcement**: Validation rejects operations exceeding this limit
- **Trade-offs**: Larger limits allow more flexibility but hurt performance

**MAX_VALUE_SIZE: 16,777,216 (u32)**
- **Human-Readable**: 16 megabytes
- **Purpose**: Maximum allowed size for a value in any operation
- **Rationale**: Prevents single values from exhausting memory
- **Enforcement**: Validation rejects operations exceeding this limit
- **Trade-offs**: Enables large values while bounding worst-case memory usage

**MAX_OPERATIONS_PER_COMMIT: 1000 (u32)**
- **Purpose**: Maximum number of mutations in a single transaction
- **Rationale**: Prevents transactions from becoming too large
- **Enforcement**: Validation rejects commits exceeding this limit
- **Trade-offs**: Allows reasonable batch sizes while bounding commit processing

### Transaction State Enumerations

**TransactionState Values**:
- **active: 0** - Transaction is in progress and accepting mutations
- **preparing: 1** - Transaction is preparing to commit (writing to WAL)
- **committed: 2** - Transaction has successfully committed
- **aborted: 3** - Transaction was rolled back

**Purpose**: Tracks transaction lifecycle for two-phase commit

**Transitions**: active -> preparing -> committed OR active -> aborted

## Snapshot Constants

### Snapshot States

**SnapshotState Values**:
- **Active: 0** - Snapshot is currently in use by a reader
- **Committed: 1** - Snapshot represents a committed transaction state
- **Aborted: 2** - Snapshot was invalidated (transaction aborted)

**Purpose**: Tracks snapshot lifecycle for MVCC

## B+Tree Constants

### Node Header Magic

**BTREE_MAGIC: 0x42545245 (u32)**
- **ASCII Interpretation**: "BTRE"
- **Purpose**: Identifies B+tree node structures
- **Location**: First 4 bytes of BtreeNodeHeader
- **Validation**: Confirms B+tree node integrity during traversal
- **Rationale**: Quick validation before processing node contents

### Node Type Enumerations

**BtreeNodeType Values** (from PageType):
- **btree_internal: 1** - Internal node with keys and child page pointers
- **btree_leaf: 2** - Leaf node with actual key-value pairs

**Purpose**: Distinguishes internal vs leaf nodes for traversal logic

## CRC32C Constants

### Polynomial

**CRC32C_POLYNOMIAL: 0x1EDC6F41 (u32)**
- **Purpose**: Polynomial for Castagnoli CRC32C checksum algorithm
- **Mathematical Representation**: x^32 + x^28 + x^27 + x^26 + x^25 + x^23 + x^22 + x^20 + x^19 + x^18 + x^14 + x^13 + x^11 + x^10 + x^9 + x^8 + x^6 + 1
- **Rationale**: Castagnoli polynomial has superior error detection properties
- **Hardware Support**: SSE4.2 and ARM CRC extensions provide acceleration

### Initial and Final Values

**CRC32C_INITIAL: 0xFFFFFFFF (u32)**
- **Purpose**: Initial CRC value before processing any bytes
- **Rationale**: Standard CRC32C initialization for consistent results

**CRC32C_FINAL_XOR: 0xFFFFFFFF (u32)**
- **Purpose**: Final XOR value applied after processing all bytes
- **Rationale**: Standard CRC32C post-processing for consistency

## Error Thresholds

### Torn Write Detection

**TORN_WRITE_THRESHOLD: 1,000,000,000,000 (u64)**
- **Human-Readable**: 1 trillion
- **Purpose**: Threshold for detecting implausible transaction IDs or page IDs
- **Validation**: Meta page validation rejects values exceeding this threshold
- **Rationale**: Torn writes produce impossibly large values; this detects corruption

## Magic Numbers Explained

### Purpose of Magic Numbers

**Identification**: Magic numbers uniquely identify data structures in the binary format
- Enable quick type checking without parsing entire structure
- Detect corruption early in processing pipeline
- Provide human-readable identifiers in hex dumps

**Validation**: Used to verify data integrity
- Incorrect magic number indicates corruption or wrong file type
- Fast rejection of invalid data before expensive parsing
- Debugging aid (hex dumps show readable identifiers)

**Version Control**: Some magic numbers encode format information
- Format version embedded in page headers
- Allows graceful rejection of unsupported formats
- Enables backward and forward compatibility planning

### ASCII vs Binary Magic Numbers

**NorthstarDB Choice**: Uses human-readable ASCII magic numbers
- **PAGE_MAGIC: "NSDB"** (0x4E534442)
- **META_MAGIC: "META"** (0x4D455441)
- **BTREE_MAGIC: "BTRE"** (0x42545245)
- **COMMIT_MAGIC: "CMIT"** (0x434D4954)

**Benefits of ASCII**:
- Easy to recognize in hex dumps and debuggers
- Self-documenting (spells out purpose)
- Prevents confusion (less likely to mistake for other data)

**Alternative: Binary Magic Numbers**
- Random 32-bit values
- Harder to accidentally duplicate
- Less human-readable

**Trade-off**: ASCII magic numbers are easier to work with but have higher collision risk than truly random values

### Magic Number Placement

**Page Headers**: Magic number is always first field
- Offset 0: PAGE_MAGIC (4 bytes)
- Enables instant identification when reading pages
- Checked before any other validation

**Structured Payloads**: Magic number identifies payload type
- META_MAGIC identifies metadata payload
- BTREE_MAGIC identifies B+tree node payload
- COMMIT_MAGIC identifies commit record payload

**Validation Order**:
1. Check magic number (fast rejection)
2. Check format version
3. Check checksums
4. Validate field contents

## Rust Const Module Structure

### Module Organization

Organize constants into logical modules mirroring the codebase structure:
- northstar_core::pager::constants - Pager-related constants
- northstar_core::wal::constants - WAL-related constants
- northstar_core::txn::constants - Transaction-related constants
- northstar_core::snapshot::constants - Snapshot-related constants
- northstar_core::btree::constants - B+tree-related constants

### Recommended Structure

**Central Constants Module**: Create a dedicated module for all constants
```rust
// northstar_core::constants
pub mod pager;
pub mod wal;
pub mod txn;
pub mod btree;

// Re-export commonly used constants
pub use pager::{PAGE_MAGIC, META_MAGIC, DEFAULT_PAGE_SIZE};
pub use wal::COMMIT_MAGIC;
pub use txn::{MAX_KEY_SIZE, MAX_VALUE_SIZE};
```

**Submodules**: Organize by functionality
```rust
// northstar_core::constants::pager
pub const PAGE_MAGIC: u32 = 0x4E534442;
pub const META_MAGIC: u32 = 0x4D455441;
pub const DEFAULT_PAGE_SIZE: u16 = 16384;
pub const FORMAT_VERSION: u16 = 0;
pub const META_A_PAGE_ID: u64 = 0;
pub const META_B_PAGE_ID: u64 = 1;
pub const FIRST_DATA_PAGE: u64 = 2;
```

### Naming Conventions

**Constants Naming**: Use SCREAMING_SNAKE_CASE for all constants
- PAGE_MAGIC (not page_magic or PageMagic)
- DEFAULT_PAGE_SIZE (not default_page_size)
- MAX_KEY_SIZE (not max_key_size)

**Rationale**: Follows Rust standard conventions for constants
- Distinguishes constants from variables and functions
- Matches Rust standard library style

**Module Naming**: Use lowercase for module names
- mod pager (not mod Pager or mod PAGER)
- mod constants (not mod Constants)

### Visibility

**Public Constants**: Use pub for constants used across modules
- Magic numbers used by multiple modules
- Size limits enforced publicly
- Page sizes configured by users

**Private Constants**: Omit pub for internal implementation details
- CRC lookup tables (internal only)
- Temporary buffer sizes
- Algorithm tuning parameters

### Const Generics

**Page Size as Const Generic**: Consider making page size a compile-time parameter
- Generic over page size for zero-cost abstraction
- Enables different page sizes without runtime overhead
- Provides type safety for page-sized operations

**Example Concept**:
```rust
pub struct Page<const SIZE: usize = 16384> {
    data: [u8; SIZE],
}

pub type DefaultPage = Page<16384>;
pub type LargePage = Page<32768>;
```

### Documentation

**Document Each Constant**: Provide rustdoc comments explaining purpose
```rust
/// Magic number identifying valid database pages
///
/// ASCII representation: "NSDB" (NorthstarDB)
/// Location: First 4 bytes of every page (offset 0)
/// Used for: Corruption detection and file type identification
pub const PAGE_MAGIC: u32 = 0x4E534442;
```

**Document Rationale**: Explain why specific values were chosen
- Why 16KB page size (I/O characteristics, trade-offs)
- Why specific magic numbers (ASCII readability)
- Why specific limits (performance vs flexibility)

### Testing

**Unit Tests for Constants**: Verify constant values
```rust
#[test]
fn test_magic_numbers_are_ascii() {
    // Verify magic numbers contain printable ASCII
    assert_eq!(std::str::from_utf8(&PAGE_MAGIC.to_be_bytes()).unwrap(), "NSDB");
}
```

**Compile-Time Assertions**: Use const_assert for invariant checking
```rust
const _: () = assert!(DEFAULT_PAGE_SIZE.is_power_of_two());
const _: () = assert!(DEFAULT_PAGE_SIZE >= 4096);
```

## Dependencies

- **Uses**: No external dependencies (constants are self-contained)
- **Used by**: All modules reference constants for validation and configuration

## Rust Implementation Guidance

### Define Constants in Dedicated Module

Create northstar_core::constants module:
```rust
pub mod constants;

pub use constants::{
    // Pager constants
    PAGE_MAGIC, META_MAGIC, BTREE_MAGIC,
    DEFAULT_PAGE_SIZE, FORMAT_VERSION,
    META_A_PAGE_ID, META_B_PAGE_ID,

    // WAL constants
    COMMIT_MAGIC,

    // Transaction constants
    MAX_KEY_SIZE, MAX_VALUE_SIZE, MAX_OPERATIONS_PER_COMMIT,
};
```

### Use pub const for All Constants

All constants should be marked pub for external access:
```rust
pub const PAGE_MAGIC: u32 = 0x4E534442;
pub const DEFAULT_PAGE_SIZE: u16 = 16384;
```

### Group Related Constants

Organize related constants together:
```rust
// Magic numbers
pub const PAGE_MAGIC: u32 = 0x4E534442;
pub const META_MAGIC: u32 = 0x4D455441;
pub const BTREE_MAGIC: u32 = 0x42545245;

// Page configuration
pub const DEFAULT_PAGE_SIZE: u16 = 16384;
pub const FORMAT_VERSION: u16 = 0;

// Reserved page IDs
pub const META_A_PAGE_ID: u64 = 0;
pub const META_B_PAGE_ID: u64 = 1;
pub const FIRST_DATA_PAGE: u64 = 2;
```

### Documentation Comments

Document every constant with rustdoc:
```rust
/// Magic number identifying valid database pages.
///
/// This value appears as the first 4 bytes of every page in the database.
/// It is used for corruption detection and file type identification.
/// The ASCII representation spells "NSDB" for easy recognition in hex dumps.
pub const PAGE_MAGIC: u32 = 0x4E534442;
```

### Testing Strategy

**Unit tests needed for**:
- Magic numbers match expected ASCII strings
- Page size is power of two and within valid range
- Reserved page IDs are sequential starting from 0
- Size limits are reasonable (not too small, not too large)
- Format version is 0 for initial implementation

**Compile-time assertions** for invariants:
- DEFAULT_PAGE_SIZE is power of two
- MAX_KEY_SIZE is less than DEFAULT_PAGE_SIZE
- Magic numbers have distinct values