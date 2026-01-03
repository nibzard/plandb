# Pager Validation

## Purpose

Pager validation ensures data integrity through comprehensive checksum verification, corruption detection, and consistent state checking. This specification details the checksum verification process, corruption detection strategy, error responses to corruption, and the panic vs error return decision for validation failures. Validation occurs on every page read and write, providing strong guarantees against silent data corruption.

## Checksum Verification Process

### Checksum Types

**Two Checksums per Page**:
1. **Header Checksum** (header_crc32c): Covers page header fields
2. **Page Checksum** (page_crc32c): Covers page payload data

**Rationale for Dual Checksums**:
- Header checksum: Detects corruption in critical metadata
- Page checksum: Detects corruption in page content
- Separate calculation enables validation at different stages
- Payload checksum calculated with header checksum field zeroed

### Header Checksum Calculation

**Purpose**: Verify integrity of page header structure

**Covered Fields** (first 32 bytes):
- magic (u32)
- format_version (u16)
- page_type (u8)
- flags (u8)
- page_id (u64)
- txn_id (u64)
- payload_len (u32)

**Algorithm**:
1. Create buffer containing first 32 bytes of page
2. Set header_crc32c field to 0 in buffer (exclude checksum itself)
3. Calculate CRC32C over 32 bytes
4. Compare calculated value with stored header_crc32c
5. Return validation result

**Excluded Fields**:
- header_crc32c itself (offset 28-31)
- page_crc32c (offset 32-35)
- Reserved bytes (offset 36-39)

**Rationale**: Checksum must be verifiable without depending on itself

### Page Checksum Calculation

**Purpose**: Verify integrity of page payload data

**Covered Data**:
- PageHeader with header_crc32c field as-is (included)
- Payload bytes (payload_len bytes)
- page_crc32c field zeroed during calculation

**Algorithm**:
1. Read PageHeader (40 bytes)
2. Read payload_len bytes from payload
3. Set page_crc32c field to 0 in header buffer
4. Calculate CRC32C over header + payload bytes
5. Compare calculated value with stored page_crc32c
6. Return validation result

**Validation Order**:
1. Validate header checksum first (fast rejection)
2. Then validate page checksum (confirms payload integrity)

**Rationale**: Header checksum cheaper to calculate (only 32 bytes vs potentially 16KB)

### Validation on Read

**Read Path**: All page reads validated

**Algorithm** (integrated into readPage):
1. Read page from storage
2. Parse PageHeader from first 40 bytes
3. Validate magic number equals PAGE_MAGIC
4. Validate format_version is supported (0)
5. Validate header_crc32c matches calculated value
6. Parse payload_len from header
7. Validate payload_len fits within page bounds
8. Validate page_crc32c matches calculated value
9. Return page data to caller if all validations pass

**Early Rejection**: Fail fast on first validation error
- Magic number wrong: Not a database page
- Checksum mismatch: Corrupted data
- Reduces unnecessary computation

**Error Conditions**:
- InvalidMagic: Magic number doesn't match
- InvalidHeaderChecksum: Header checksum failed
- InvalidPageChecksum: Page checksum failed
- InvalidPayloadLength: Payload length exceeds bounds
- UnsupportedVersion: Format version not recognized

### Validation on Write

**Write Path**: Pages validated before writing to storage

**Algorithm** (integrated into writePage):
1. Receive buffer from caller
2. Parse PageHeader from first 40 bytes
3. Validate page structure (magic, version, checksums)
4. Validate page_id in header matches target page_id
5. If validation fails: Return error without writing
6. If validation passes: Write page to storage
7. Invalidate cache entry (if present)

**Rationale**: Prevent writing corrupted data to disk
- Catch bugs in page construction
- Detect memory corruption
- Ensure only valid pages persisted

**Error Conditions**:
- InvalidMagic: Caller provided invalid page
- InvalidChecksum: Checksums don't match
- PageIdMismatch: Page ID inconsistent

## Corruption Detection Strategy

### CRC32C Algorithm

**Choice**: Castagnoli CRC32C polynomial

**Properties**:
- Polynomial: 0x1EDC6F41
- High error detection rate
- Hardware acceleration available (SSE4.2, ARM CRC)
- Fast computation

**Error Detection Capability**:
- Detects all single-bit errors
- Detects all double-bit errors
- Detects all odd number of bit errors
- Detects burst errors up to 32 bits
- Very low probability of undetected corruption

**Implementation**: Use hardware-accelerated library
- Rust: crc32c crate
- Zig: Built-in CRC32C support
- Falls back to software implementation if hardware unavailable

### Validation Frequency

**Every Read**: All pages validated on read
- No caching of unvalidated pages
- Cache contains only validated pages
- Readers always see validated data

**Every Write**: All pages validated on write
- Prevents corruption propagation
- Catches bugs before persistence
- Ensures storage always contains valid pages

**On Open**: Meta pages validated on database open
- Both meta pages read and validated
- Checksums verified
- Used to choose valid meta

### Torn Write Detection

**Problem**: Partial page write due to crash or power failure

**Detection**: Checksum mismatch on torn page
- Page written partially has incorrect checksum
- Validation fails on read
- Error returned to caller

**Dual Meta Pages**: Atomic update mechanism
- Write to opposite meta page
- Fsync to make durable
- Update committed_txn_id last
- At most one meta page valid after crash

**Recovery**: Choose meta with higher committed_txn_id
- Only fully written meta has higher txn_id
- Torn write has lower or zero txn_id
- Recovery always chooses complete page

## Error Responses to Corruption

### Error Types

**Validation Errors**: Specific error for each failure type

**InvalidMagic**: Magic number doesn't match
- **Cause**: Not a database page, or severe corruption
- **Severity**: Fatal (cannot recover page)
- **Action**: Return error to caller, database unusable if meta pages

**InvalidHeaderChecksum**: Header checksum mismatch
- **Cause**: Header bytes corrupted
- **Severity**: Fatal (cannot trust any header fields)
- **Action**: Return error to caller, do not use page

**InvalidPageChecksum**: Page checksum mismatch
- **Cause**: Payload bytes corrupted
- **Severity**: Fatal (payload data untrustworthy)
- **Action**: Return error to caller, do not use page

**InvalidPayloadLength**: Payload length exceeds bounds
- **Cause**: Header field corrupted or invalid
- **Severity**: Fatal (would cause buffer overflow)
- **Action**: Return error to caller, do not read payload

**UnsupportedVersion**: Format version not recognized
- **Cause**: Database from future version
- **Severity**: Fatal (incompatible format)
- **Action**: Return error, suggest upgrade

### Error Propagation

**Validation Failures**: Returned immediately to caller

**No Silent Failures**: All validation errors reported
- Caller must handle error
- No fallback to partial data
- No attempt to use corrupted pages

**Caller Responsibilities**:
- Meta page corruption: Database cannot open
- Data page corruption: Return error to user query
- Recovery may be possible from commit stream (future feature)

### Logging Strategy

**Log Validation Errors**: Record for debugging

**Information Logged**:
- Error type (which validation failed)
- Page ID (if available)
- Expected vs actual values (magic, checksums)
- File offset (for debugging)

**Log Level**:
- Corruption detected: Error or critical
- Validation failure details: Debug

**Example Log Message**:
```
ERROR: Page validation failed for page 123
  Invalid magic: expected 0x4E534442, found 0x00000000
  File offset: 201326592
  This may indicate disk corruption or database file mismatch
```

## Panic vs Error Return

### Design Choice: Always Return Error

**No Panics for Corruption**: Validation failures return errors

**Rationale**:
- Corruption is runtime condition, not programming error
- Caller may want to handle corruption gracefully
- Database can continue with other pages
- Panics lose data (unflushed buffers)

**Alternatives Considered**:
- Panic on meta corruption: Would prevent database open anyway
- Panic on data corruption: Too harsh for embedded database
- Panic for programming errors: Different from corruption

### Programming Errors vs Corruption

**Programming Errors**: May panic (in debug builds)
- Null pointer dereference: Panic
- Index out of bounds: Panic
- Assertion failure: Panic

**Data Corruption**: Never panic
- Invalid checksum: Return error
- Wrong magic number: Return error
- Torn write: Return error

**Rationale**: Data corruption is environmental, not code bug

### Graceful Degradation

**Partial Corruption**: Database partially usable
- Some pages corrupted: Other pages still accessible
- Queries avoid corrupted pages: Return error for those queries
- Database remains open: Allows recovery attempts

**Total Corruption**: Database unusable
- Both meta pages corrupted: Cannot open
- All data pages corrupted: Cannot query
- Return error to caller: Database must be restored from backup

**Recovery Options** (future):
- Rebuild from commit stream
- Restore from backup
- Export recoverable data

## Validation Implementation

### Rust Validation Functions

**PageHeader Validation**:
```rust
impl PageHeader {
    pub fn validate(&self) -> Result<(), ValidationError> {
        // Check magic
        if self.magic != PAGE_MAGIC {
            return Err(ValidationError::InvalidMagic {
                expected: PAGE_MAGIC,
                found: self.magic,
            });
        }

        // Check format version
        if self.format_version > 0 {
            return Err(ValidationError::UnsupportedVersion {
                version: self.format_version,
            });
        }

        // Validate header checksum
        let calculated = self.calculate_header_checksum();
        if self.header_crc32c != calculated {
            return Err(ValidationError::HeaderChecksumMismatch);
        }

        Ok(())
    }

    fn calculate_header_checksum(&self) -> u32 {
        // CRC32C of first 32 bytes with checksum field zeroed
        // Implementation details...
    }
}
```

**Page Validation**:
```rust
pub fn validate_page(buffer: &[u8]) -> Result<PageHeader, ValidationError> {
    // Parse header
    let header = PageHeader::decode(buffer)?;

    // Validate header
    header.validate()?;

    // Validate payload length
    let total_len = PageHeader::SIZE + header.payload_len as usize;
    if total_len > buffer.len() {
        return Err(ValidationError::InvalidPayloadLength);
    }

    // Validate page checksum
    let calculated = calculate_page_checksum(&buffer[..total_len]);
    if header.page_crc32c != calculated {
        return Err(ValidationError::PageChecksumMismatch);
    }

    Ok(header)
}
```

### Testing Strategy

**Unit tests needed for**:
- Valid page passes validation
- Invalid magic number detected
- Checksum mismatch detected
- Payload length overflow detected
- Unsupported version rejected

**Property tests for**:
- Corrupted byte in header always detected
- Corrupted byte in payload always detected
- Valid page always validates successfully

**Integration tests for**:
- Corrupted meta page prevents database open
- Corrupted data page returns error on read
- Torn write detected on recovery
- Checksum calculation matches reference implementation

**Fuzz Testing**: Validate robustness against random corruption
- Mutate random bytes in valid page
- Verify validation detects corruption
- Measure false negative rate (should be zero)
