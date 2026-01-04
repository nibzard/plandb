# MVCC Serialization

## Purpose

MVCC serialization defines how snapshot state is persisted to disk and reconstructed during recovery in NorthstarDB. Snapshots must be durably stored to survive process crashes and enable recovery of the database to a consistent state. This specification describes the binary format for serialized snapshot data, the encoding and decoding algorithms, error handling for corrupt data, and the Rust implementation approach for efficient serialization.

## Core Concepts

### Serialization Requirements

Snapshot serialization must satisfy several critical requirements:

**Durability**: Snapshots must survive process crashes
- Committed snapshots written to stable storage before acknowledgment
- WAL flush ensures atomic commit
- Recovery can reconstruct registry from persisted state

**Efficiency**: Serialization overhead must be minimal
- Compact binary format to reduce storage footprint
- O(N) serialization time where N is snapshot count
- Minimal allocations during encode/decode

**Versioning**: Format must support schema evolution
- Version identifier in serialized data
- Backward compatibility for reading old formats
- Forward compatibility for new fields

**Corruption Detection**: Must detect and handle corrupt data
- Checksums for integrity verification
- Graceful handling of truncated data
- Clear error reporting for invalid snapshots

### Serialization Scope

The snapshot registry contains the following data that must be serialized:

**Snapshot Entries**: Transaction ID to root page ID mappings
- HashMap<u64, u64> mapping
- All committed transactions
- Genesis snapshot (txn_id 0) always included

**Current State**: Most recent committed transaction
- current_txn_id: Highest committed transaction ID
- current_root_page_id: Root page for current transaction

**Reference Counts**: Active reader counts (optional for V0)
- Per-transaction reference counts
- Used for cleanup decisions
- May be recomputed on recovery (V0 approach)

## Binary Format

### File Layout

Snapshot data is stored in the database file header region. The database file begins with:

```
+------------------+
| Database Header  |
+------------------+
| Snapshot Data    |
+------------------+
| WAL Region       |
+------------------+
| Page Allocation  |
+------------------+
| B+tree Pages     |
+------------------+
```

**Location**: Snapshot data immediately follows the database header at a fixed offset
**Size**: Variable size, depends on number of snapshots
**Alignment**: 8-byte aligned for efficient access

### Serialized Snapshot Structure

The snapshot data is organized as a contiguous binary structure:

```
+-------------------+ 0x00
| Magic Number      | 8 bytes
+-------------------+ 0x08
| Version           | 4 bytes
+-------------------+ 0x0C
| Checksum          | 4 bytes
+-------------------+ 0x10
| Entry Count       | 8 bytes
+-------------------+ 0x18
| Current Txn ID    | 8 bytes
+-------------------+ 0x20
| Current Root Page | 8 bytes
+-------------------+ 0x28
| Reserved          | 32 bytes
+-------------------+ 0x48
| Entry 0 Txn ID    | 8 bytes
+-------------------+ 0x50
| Entry 0 Root Page | 8 bytes
+-------------------+ 0x58
| Entry 1 Txn ID    | 8 bytes
+-------------------+ 0x60
| Entry 1 Root Page | 8 bytes
+-------------------+
| ...               |
+-------------------+
| Entry N-1 Txn ID  | 8 bytes
+-------------------+
| Entry N-1 Root Page| 8 bytes
+-------------------+
```

**Total Size**: 72 bytes + (16 bytes * entry_count)

### Field Definitions

**Magic Number**: 0x4E53544D54535054 ("NSTSNAPT" in ASCII)
- Identifies snapshot data block
- 8 bytes, little-endian
- Offset: 0x00

**Version**: Serialization format version
- 4 bytes, little-endian
- Current value: 1
- Offset: 0x08
- Enables format evolution

**Checksum**: CRC-32 of remaining data
- 4 bytes, little-endian
- Computed over bytes from offset 0x0C to end
- Offset: 0x0C
- Detects corruption

**Entry Count**: Number of snapshot entries
- 8 bytes (u64), little-endian
- Must be >= 1 (at least genesis)
- Offset: 0x10

**Current Txn ID**: Highest committed transaction ID
- 8 bytes (u64), little-endian
- Must equal max(entry txn_ids)
- Offset: 0x18

**Current Root Page**: Root page ID for current transaction
- 8 bytes (u64), little-endian
- Must equal root_page_id for current_txn_id
- Offset: 0x20

**Reserved**: Space for future fields
- 32 bytes, zero-filled
- Offset: 0x28
- Ensures forward compatibility

**Snapshot Entries**: Array of transaction ID and root page ID pairs
- Each entry: 16 bytes (8 bytes txn_id + 8 bytes root_page_id)
- Entries stored in ascending txn_id order
- All values little-endian
- Starting offset: 0x48

### Binary Layout Details

**Byte Order**: All multi-byte integers use little-endian encoding
- Rationale: Match host architecture (x86_64)
- Avoids byte swapping on common platforms
- Network order (big-endian) not needed (single-machine storage)

**Alignment**: All fields are naturally aligned
- 8-byte fields at 8-byte boundaries
- No padding within structure
- Enables direct memory mapping (future optimization)

**Range Constraints**:
- Entry count: 1 <= count <= 1,000,000 (practical limit)
- Transaction IDs: 0 <= txn_id < 2^64
- Root page IDs: 0 <= page_id < 2^64 (0 indicates empty database)

### Example Serialization

**Example Snapshot Registry**:
- Entry 0: txn_id=0, root_page_id=1 (genesis)
- Entry 1: txn_id=100, root_page_id=42
- Entry 2: txn_id=200, root_page_id=57
- current_txn_id=200
- current_root_page_id=57

**Serialized Bytes (hex dump)**:
```
Offset  Hex                                              ASCII
0x00    54 50 53 54 4D 53 4E                              NSTSNAPT
0x08    01 00 00 00                                       .... (version 1)
0x0C    [checksum]                                        CRC-32
0x10    03 00 00 00 00 00 00 00                           .... (3 entries)
0x18    C8 00 00 00 00 00 00 00                           .... (txn_id 200)
0x20    39 00 00 00 00 00 00 00                           .... (page_id 57)
0x28    00 00 00 00 00 00 00 00                           .... (reserved)
0x30    00 00 00 00 00 00 00 00                           .... (reserved)
0x38    00 00 00 00 00 00 00 00                           .... (reserved)
0x40    00 00 00 00 00 00 00 00                           .... (reserved)
0x48    00 00 00 00 00 00 00 00                           .... (txn_id 0)
0x50    01 00 00 00 00 00 00 00                           .... (page_id 1)
0x58    64 00 00 00 00 00 00 00                           .... (txn_id 100)
0x60    2A 00 00 00 00 00 00 00                           .... (page_id 42)
0x68    C8 00 00 00 00 00 00 00                           .... (txn_id 200)
0x70    39 00 00 00 00 00 00 00                           .... (page_id 57)
```

**Total Size**: 72 + (16 * 3) = 120 bytes

## Serialization Algorithm

### Encode Process

The serialization process converts an in-memory SnapshotRegistry to binary format:

**Input**: SnapshotRegistry with N entries

**Output**: Byte array of size 72 + (16 * N)

**Step 1: Validate Registry State**
1. Verify entry_count >= 1
2. Verify current_txn_id equals max(entry txn_ids)
3. Verify current_root_page_id matches current_txn_id entry
4. Verify entries are in ascending order
5. Return error if any invariant violated

**Step 2: Allocate Buffer**
1. Calculate total_size = 72 + (16 * entry_count)
2. Allocate byte vector of size total_size
3. Return AllocationFailed if allocation fails

**Step 3: Write Header**
1. Write magic number: 0x4E53544D54535054 at offset 0
2. Write version: 1 at offset 8
3. Write checksum placeholder: 0 at offset 12

**Step 4: Write Metadata**
1. Write entry_count at offset 16
2. Write current_txn_id at offset 24
3. Write current_root_page_id at offset 32
4. Write 32 zero bytes for reserved field at offset 40

**Step 5: Write Snapshot Entries**
1. Initialize offset = 72
2. For each entry in sorted order:
   - Write entry.txn_id at offset
   - Write entry.root_page_id at offset + 8
   - Increment offset by 16

**Step 6: Compute Checksum**
1. Calculate CRC-32 of bytes from offset 12 to end
2. Write checksum at offset 12 (overwriting placeholder)

**Step 7: Return Buffer**
1. Return serialized byte vector
2. Caller responsible for writing to disk

**Time Complexity**: O(N) where N is entry count
**Space Complexity**: O(N) for output buffer
**Error Conditions**:
- InvalidRegistry: State invariants violated
- AllocationFailed: Buffer allocation fails

### Write to Disk

After serialization, the data must be written to stable storage:

**Step 1: Acquire Write Lock**
1. Lock snapshot registry exclusively
2. Prevent concurrent modifications during write

**Step 2: Serialize Registry**
1. Call encode function with current registry state
2. Obtain byte buffer

**Step 3: Write to File**
1. Seek to snapshot data offset in database file
2. Write entire buffer with single write() call
3. Use write-ahead logging pattern if supported

**Step 4: Flush to Storage**
1. Call fsync() on file descriptor
2. Ensure data reaches stable storage
3. Wait for flush completion

**Step 5: Release Lock**
1. Drop registry write lock
2. Allow concurrent access

**Atomicity**: Either full write succeeds or no partial update visible
**Crash Safety**: If crash occurs before fsync, old data remains valid

## Deserialization Algorithm

### Decode Process

The deserialization process reconstructs a SnapshotRegistry from binary data:

**Input**: Byte array containing serialized snapshot data

**Output**: Initialized SnapshotRegistry

**Step 1: Validate Buffer Size**
1. Verify buffer_size >= 72 (minimum header size)
2. Return TruncatedData if too small

**Step 2: Verify Magic Number**
1. Read 8 bytes at offset 0
2. Compare to expected magic: 0x4E53544D54535054
3. Return InvalidMagic if mismatch

**Step 3: Verify Version**
1. Read 4 bytes at offset 8
2. Check if version is supported (currently only version 1)
3. Return UnsupportedVersion if not 1

**Step 4: Verify Checksum**
1. Read checksum at offset 12
2. Calculate CRC-32 of bytes from offset 16 to buffer end
3. Compare calculated checksum to stored checksum
4. Return ChecksumMismatch if not equal

**Step 5: Read Metadata**
1. Read entry_count at offset 16
2. Read current_txn_id at offset 24
3. Read current_root_page_id at offset 32
4. Validate: entry_count >= 1
5. Validate: buffer_size == 72 + (16 * entry_count)
6. Return CorruptedData if size mismatch

**Step 6: Read Reserved Field**
1. Skip 32 bytes at offset 40 (reserved for future)
2. In future versions, may decode additional fields

**Step 7: Read Snapshot Entries**
1. Initialize HashMap<u64, u64>
2. Initialize offset = 72
3. For i in 0..entry_count:
   - Read txn_id at offset
   - Read root_page_id at offset + 8
   - Insert (txn_id, root_page_id) into HashMap
   - Validate: txn_id < current_txn_id (except for current)
   - Increment offset by 16
4. Return AllocationFailed if HashMap insert fails

**Step 8: Validate Registry State**
1. Verify HashMap contains current_txn_id entry
2. Verify current_txn_id maps to current_root_page_id
3. Verify entry_count matches HashMap size
4. Verify all txn_ids are unique
5. Return CorruptedData if validation fails

**Step 9: Construct SnapshotRegistry**
1. Create SnapshotRegistry from deserialized data
2. Return initialized registry

**Time Complexity**: O(N) where N is entry count
**Space Complexity**: O(N) for HashMap storage
**Error Conditions**:
- TruncatedData: Buffer too small
- InvalidMagic: Magic number mismatch
- UnsupportedVersion: Unknown format version
- ChecksumMismatch: CRC verification failed
- CorruptedData: Invariant violations detected
- AllocationFailed: HashMap allocation failed

### Read from Disk

Deserialization occurs during database open and recovery:

**Step 1: Open Database File**
1. Open file with read-only mode initially
2. Verify file exists and is readable
3. Return error if file not found

**Step 2: Seek to Snapshot Region**
1. Seek to fixed offset where snapshot data stored
2. Calculate expected size from file metadata or read entire region

**Step 3: Read Snapshot Data**
1. Read metadata header (first 72 bytes)
2. Extract entry_count from header
3. Calculate total_size = 72 + (16 * entry_count)
4. Read remaining snapshot entry data
5. Return error if read fails or returns incomplete data

**Step 4: Deserialize Registry**
1. Call decode function with read buffer
2. Obtain SnapshotRegistry or error
3. Return error if deserialization fails

**Step 5: Verify Against WAL**
1. Read WAL commit records
2. Verify highest WAL LSN matches current_txn_id
3. Detect discrepancies between snapshot and WAL
4. Recover by rebuilding registry from WAL if mismatch detected

**Step 6: Initialize Database State**
1. Use deserialized registry for database operations
2. Allow reads and writes to proceed
3. Return success to caller

## Error Handling

### Corrupt Data Detection

Multiple mechanisms detect corrupted snapshot data:

**Checksum Validation**: CRC-32 covers all data after checksum field
- Detects accidental bit flips
- Detects partial writes
- Detects disk corruption
- Probability of undetected error: ~1 in 4 billion

**Size Validation**: Entry count must match actual data size
- Detects truncated files
- Detects size field corruption
- Prevents buffer overruns

**Magic Number**: Fixed identifier at start of data
- Detects reading wrong file region
- Detects endianness mismatch
- Quick reject for obviously invalid data

**Invariant Validation**: Consistency checks after deserialization
- current_txn_id equals max entry txn_id
- current_root_page_id matches current_txn_id entry
- All txn_ids are unique
- Genesis snapshot (txn_id 0) exists

### Error Recovery Strategies

**Strategy 1: Rebuild from WAL**

If snapshot data is corrupt or missing:
1. Scan WAL from beginning to end
2. Extract all commit records
3. Rebuild snapshot registry from commits
4. Use highest committed transaction as current state
5. Snapshot registry may have fewer entries than original
6. Time-travel capability reduced but functionality preserved

**Advantages**:
- Always possible if WAL is intact
- No data loss (committed transactions recovered)
- Automatic fallback mechanism

**Disadvantages**:
- Slower than loading snapshot (must scan entire WAL)
- Loses historical snapshots beyond those in WAL
- May increase startup time

**Strategy 2: Use Previous Snapshot**

If periodic snapshot backups exist:
1. Locate most recent valid snapshot backup
2. Load snapshot from backup
3. Replay WAL entries from backup point
4. Reconstruct current state
5. Overwrite corrupt snapshot with reconstructed data

**Advantages**:
- Faster than full WAL replay
- Preserves some historical data

**Disadvantages**:
- Requires backup mechanism
- May lose recent snapshots if backup is old

**Strategy 3: Initialize Empty Database**

If both snapshot and WAL are corrupt:
1. Treat database as new/empty
2. Initialize with genesis snapshot only
3. Log corruption error
4. Allow operation to proceed (may confuse applications)

**Advantages**:
- Database remains functional
- No crash or panic

**Disadvantages**:
- Data loss (all committed transactions lost)
- Application may see unexpected empty state
- Last resort only

### Error Reporting

Error types provide detailed diagnostic information:

**InvalidMagic { found: u64, expected: u64 }**
- Magic number mismatch
- Suggests reading wrong file region
- Check file offset calculation

**UnsupportedVersion { version: u32 }**
- Unknown format version
- Suggests database created by newer software
- Update software or migrate data

**ChecksumMismatch { stored: u32, calculated: u32 }**
- CRC verification failed
- Suggests data corruption or incomplete write
- May indicate disk hardware issues

**CorruptedData { reason: String }**
- Invariant violation detected
- Provides specific reason (e.g., "missing genesis snapshot")
- Suggests serious data integrity issue

**AllocationFailed**
- Memory allocation failed during deserialization
- System out of memory
- Retry or increase available memory

## Rust Implementation Guidance

### Serialization Approach

**Recommended Crate**: bincode for efficient binary serialization

**Alternative**: Manual serialization for maximum control
- Use byteorder crate for little-endian encoding
- Direct byte array manipulation
- More code but zero dependencies

**Choice for V0**: bincode
- Simple and ergonomic API
- Efficient binary format
- Well-tested and maintained
- Sufficient performance for V0

### Type Definitions

**Serialized Snapshot Structure**:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SerializedSnapshot {
    pub magic: u64,
    pub version: u32,
    pub checksum: u32,
    pub entry_count: u64,
    pub current_txn_id: u64,
    pub current_root_page_id: u64,
    pub reserved: [u8; 32],
    pub entries: Vec<(u64, u64)>, // (txn_id, root_page_id)
}

impl SerializedSnapshot {
    pub const MAGIC: u64 = 0x4E53544D54535054;
    pub const VERSION: u32 = 1;
    pub const HEADER_SIZE: usize = 72;
    pub const ENTRY_SIZE: usize = 16;
}
```

**Serialization Function**:

```rust
pub fn serialize(registry: &SnapshotRegistry) -> Result<Vec<u8>, Error> {
    use bincode::Options;
    use crc32fast::hash;

    // Validate registry state
    registry.validate()?;

    // Prepare entries (sorted by txn_id)
    let mut entries: Vec<(u64, u64)> = registry
        .snapshots()
        .iter()
        .map(|(&txn_id, &page_id)| (txn_id, page_id))
        .collect();
    entries.sort_by_key(|&(txn_id, _)| txn_id);

    // Create serialized structure
    let serialized = SerializedSnapshot {
        magic: SerializedSnapshot::MAGIC,
        version: SerializedSnapshot::VERSION,
        checksum: 0, // Placeholder
        entry_count: entries.len() as u64,
        current_txn_id: registry.current_txn_id(),
        current_root_page_id: registry.current_root_page_id(),
        reserved: [0u8; 32],
        entries,
    };

    // Serialize to bytes
    let mut bytes = bincode::serialize(&serialized)
        .map_err(|e| Error::SerializationFailed { reason: e.to_string() })?;

    // Calculate checksum
    let checksum_data = &bytes[12..]; // Skip magic, version, checksum placeholder
    let checksum = hash(checksum_data);

    // Write checksum to bytes
    bytes[12..16].copy_from_slice(&checksum.to_le_bytes());

    Ok(bytes)
}
```

**Deserialization Function**:

```rust
pub fn deserialize(bytes: &[u8]) -> Result<SnapshotRegistry, Error> {
    use crc32fast::hash;

    // Validate minimum size
    if bytes.len() < SerializedSnapshot::HEADER_SIZE {
        return Err(Error::TruncatedData {
            expected: SerializedSnapshot::HEADER_SIZE,
            found: bytes.len(),
        });
    }

    // Verify magic number
    let magic = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
    if magic != SerializedSnapshot::MAGIC {
        return Err(Error::InvalidMagic {
            found: magic,
            expected: SerializedSnapshot::MAGIC,
        });
    }

    // Verify version
    let version = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
    if version != SerializedSnapshot::VERSION {
        return Err(Error::UnsupportedVersion { version });
    }

    // Verify checksum
    let stored_checksum = u32::from_le_bytes(bytes[12..16].try_into().unwrap());
    let calculated_checksum = hash(&bytes[16..]);
    if stored_checksum != calculated_checksum {
        return Err(Error::ChecksumMismatch {
            stored: stored_checksum,
            calculated: calculated_checksum,
        });
    }

    // Deserialize structure
    let serialized: SerializedSnapshot = bincode::deserialize(bytes)
        .map_err(|e| Error::DeserializationFailed { reason: e.to_string() })?;

    // Validate invariants
    if serialized.entry_count == 0 {
        return Err(Error::CorruptedData {
            reason: "entry_count must be >= 1".to_string(),
        });
    }

    if serialized.entries.len() != serialized.entry_count as usize {
        return Err(Error::CorruptedData {
            reason: format!(
                "entry_count {} does not match actual entries {}",
                serialized.entry_count,
                serialized.entries.len()
            ),
        });
    }

    // Build snapshot registry
    let mut registry = SnapshotRegistry::new();
    for (txn_id, root_page_id) in serialized.entries {
        registry.register_snapshot(txn_id, root_page_id)?;
    }

    // Verify current state
    if registry.current_txn_id() != serialized.current_txn_id {
        return Err(Error::CorruptedData {
            reason: format!(
                "current_txn_id mismatch: {} != {}",
                registry.current_txn_id(),
                serialized.current_txn_id
            ),
        });
    }

    Ok(registry)
}
```

### Disk I/O Integration

**Write Snapshot to File**:

```rust
pub fn write_snapshot(
    file: &std::fs::File,
    registry: &SnapshotRegistry,
    offset: u64,
) -> Result<(), Error> {
    use std::io::{Seek, Write};

    // Serialize registry
    let bytes = serialize(registry)?;

    // Seek to snapshot offset
    let mut file = file;
    file.seek(std::io::SeekFrom::Start(offset))
        .map_err(|e| Error::Io { source: e })?;

    // Write snapshot data
    file.write_all(&bytes)
        .map_err(|e| Error::Io { source: e })?;

    // Sync to disk
    file.sync_all()
        .map_err(|e| Error::Io { source: e })?;

    Ok(())
}
```

**Read Snapshot from File**:

```rust
pub fn read_snapshot(
    file: &std::fs::File,
    offset: u64,
) -> Result<SnapshotRegistry, Error> {
    use std::io::{Read, Seek};

    // Seek to snapshot offset
    let mut file = file;
    file.seek(std::io::SeekFrom::Start(offset))
        .map_err(|e| Error::Io { source: e })?;

    // Read header to determine size
    let mut header = [0u8; SerializedSnapshot::HEADER_SIZE];
    file.read_exact(&mut header)
        .map_err(|e| Error::Io { source: e })?;

    let entry_count = u64::from_le_bytes(header[16..24].try_into().unwrap()) as usize;
    let total_size = SerializedSnapshot::HEADER_SIZE + (SerializedSnapshot::ENTRY_SIZE * entry_count);

    // Read entire snapshot
    file.seek(std::io::SeekFrom::Start(offset))
        .map_err(|e| Error::Io { source: e })?;

    let mut bytes = vec![0u8; total_size];
    file.read_exact(&mut bytes)
        .map_err(|e| Error::Io { source: e })?;

    // Deserialize
    deserialize(&bytes)
}
```

### Error Type Definitions

```rust
#[derive(Debug, thiserror::Error)]
pub enum SerializationError {
    #[error("truncated data: expected {expected} bytes, found {found}")]
    TruncatedData { expected: usize, found: usize },

    #[error("invalid magic number: found {found:#x}, expected {expected:#x}")]
    InvalidMagic { found: u64, expected: u64 },

    #[error("unsupported version: {version}")]
    UnsupportedVersion { version: u32 },

    #[error("checksum mismatch: stored {stored:#x}, calculated {calculated:#x}")]
    ChecksumMismatch { stored: u32, calculated: u32 },

    #[error("corrupted data: {reason}")]
    CorruptedData { reason: String },

    #[error("serialization failed: {reason}")]
    SerializationFailed { reason: String },

    #[error("deserialization failed: {reason}")]
    DeserializationFailed { reason: String },

    #[error("I/O error: {source}")]
    Io { source: std::io::Error },
}
```

### Testing Strategy

**Unit Tests**:

1. **Serialize-Deserialize Round Trip**
   - Create registry with multiple entries
   - Serialize to bytes
   - Deserialize back to registry
   - Verify original equals deserialized

2. **Magic Number Verification**
   - Serialize valid registry
   - Corrupt magic number bytes
   - Verify deserialization returns InvalidMagic error

3. **Checksum Validation**
   - Serialize valid registry
   - Corrupt a single byte in entries
   - Verify deserialization returns ChecksumMismatch error

4. **Version Handling**
   - Serialize with version 1
   - Modify version field to 2
   - Verify deserialization returns UnsupportedVersion error

5. **Truncated Data**
   - Provide partial buffer (< 72 bytes)
   - Verify deserialization returns TruncatedData error

6. **Invariant Validation**
   - Create registry with inconsistent state
   - Verify serialization returns error
   - Modify bytes to break invariants
   - Verify deserialization returns CorruptedData error

**Property Tests**:

1. **Round Trip Property**
   - For arbitrary registry, deserialize(serialize(registry)) == registry
   - Use proptest or quickcheck to generate random registries

2. **Size Invariance**
   - serialize(registry).len() == 72 + (16 * registry.entry_count())
   - Verify for various registry sizes

**Integration Tests**:

1. **Disk Persistence**
   - Create database, write snapshots
   - Close and reopen database
   - Verify snapshots correctly recovered

2. **Crash Recovery**
   - Write snapshot, simulate crash (kill process)
   - Restart and verify recovery
   - Corrupt snapshot file, verify WAL recovery works

## Summary

MVCC serialization provides durable storage of snapshot state:

**Binary Format**:
- 72-byte header + 16 bytes per snapshot entry
- Little-endian encoding
- CRC-32 checksum for integrity
- Version field for format evolution
- Fixed magic number for identification

**Serialization**:
- O(N) time complexity
- Compact binary representation
- Checksum computation before write
- Single atomic write + fsync

**Deserialization**:
- Multi-layer validation (magic, version, checksum, invariants)
- O(N) time complexity
- Detailed error reporting
- Graceful handling of corrupt data

**Error Recovery**:
- Rebuild from WAL if snapshot corrupt
- Use backup snapshots if available
- Initialize empty database as last resort
- Comprehensive error types for diagnostics

**Rust Implementation**:
- bincode for serialization
- crc32fast for checksums
- Explicit error handling
- Extensive unit and property tests
