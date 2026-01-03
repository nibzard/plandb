# Checksum

## Purpose

Checksums provide integrity verification for stored data in NorthstarDB, detecting corruption from disk failures, software bugs, or hardware errors. The database uses CRC32C (Cyclic Redundancy Check with Castagnoli polynomial) as its checksum algorithm, providing fast computation with hardware acceleration and strong error detection capabilities.

## CRC32C Algorithm

### Description

**CRC32C (Castagnoli)**: A 32-bit cyclic redundancy check using the Castagnoli polynomial (0x1EDC6F41). CRC32C is optimized for modern storage systems and provides excellent error detection with hardware acceleration on most x86-64 processors.

**Polynomial**: 0x1EDC6F41 (reversed representation: 0x82F63B78)

**Initial Value**: 0xFFFFFFFF

**Final XOR**: 0xFFFFFFFF

**Input Processing**: Process each byte sequentially, updating the CRC state

**Output**: 32-bit checksum value (0 to 4,294,967,295)

### Why CRC32C Was Chosen

**Hardware Acceleration**: SSE4.2 and ARM CRC extensions provide dedicated CPU instructions
- Intel/AMD: CRC32 instruction (SSE4.2 extension)
- ARM: CRC32 instructions (ARMv8 architecture)
- Performance: Hardware-accelerated CRC32C is 10-20x faster than software implementation

**Industry Standard**: Widely adopted in storage systems
- Used by iSCSI, SCTP, ext4, Btrfs, Ceph
- Proven reliability in production systems
- Extensive tooling and library support

**Error Detection**: Strong error detection capabilities
- Detects all single-bit errors
- Detects all double-bit errors
- Detects all odd-numbered bit errors
- Detects burst errors up to 32 bits
- Undetected error probability: approximately 1 in 2^32

**Performance**: Fast computation even without hardware acceleration
- Lookup table-based implementation is efficient
- Small memory footprint (256-entry table for software fallback)
- Suitable for real-time checksum verification

### CRC32C Algorithm Steps

**Lookup Table Generation** (software implementation):
1. Create a 256-entry table, one entry for each possible byte value (0-255)
2. For each entry i (0-255):
   - Start with CRC value equal to i
   - Process 8 bits (one byte) with polynomial division
   - Store result in table[i]

**Checksum Calculation**:
1. Initialize CRC to initial value (0xFFFFFFFF)
2. For each byte in input data:
   - XOR the byte with the lowest 8 bits of CRC
   - Use result as index into lookup table
   - XOR table entry with shifted CRC (CRC >> 8)
3. After all bytes processed, apply final XOR (0xFFFFFFFF)
4. Return resulting 32-bit value

**Pseudocode**:
```
crc = 0xFFFFFFFF
for each byte in data:
    index = (crc xor byte) and 0xFF
    crc = (crc >> 8) xor table[index]
return crc xor 0xFFFFFFFF
```

### Incremental Checksum Strategy

**Header Checksum**: Computed over header fields only
- Excludes checksum fields themselves (header_crc32c, page_crc32c)
- Covers bytes 0-27 of the page header
- Calculated with checksum fields zeroed, then stored in place

**Payload Checksum**: Computed over the payload area
- Covers the first payload_len bytes after the header
- Independent of header checksum
- Enables separate validation of header and payload

**Verification Strategy**:
1. Validate header checksum first (fast reject if header corrupted)
2. If header valid, validate payload checksum
3. If both valid, page is considered intact

## Checksum Placement

### Within Page Structure

**Page Header Checksum** (header_crc32c):
- **Offset**: 28 bytes from start of page
- **Size**: 4 bytes (u32)
- **Coverage**: Bytes 0-27 (magic through payload_len fields)
- **Byte Order**: Little-endian

**Page Payload Checksum** (page_crc32c):
- **Offset**: 32 bytes from start of page
- **Size**: 4 bytes (u32)
- **Coverage**: First payload_len bytes of payload area
- **Byte Order**: Little-endian

**Layout Visualization**:
```
Offset  Size  Field              Description
------  ----  -----              -----------
0       4     magic              Page identification
4       2     format_version     Format version
6       1     page_type          Page type enumeration
7       1     flags              Page flags
8       8     page_id            Page identifier
16      8     txn_id             Transaction ID
24      4     payload_len        Payload byte count
28      4     header_crc32c      HEADER checksum (covers bytes 0-27)
32      4     page_crc32c        PAYLOAD checksum (covers payload)
36      N     payload            Variable-length payload data
```

### Calculation Order

**When Writing a Page**:
1. Fill in all header fields except checksums
2. Zero out both checksum fields (set to 0)
3. Calculate header_crc32c over bytes 0-27
4. Store header_crc32c at offset 28
5. Calculate page_crc32c over payload area (first payload_len bytes)
6. Store page_crc32c at offset 32
7. Page is now ready to write to disk

**When Reading a Page**:
1. Read entire page from disk
2. Extract header_crc32c from offset 28
3. Calculate header checksum over bytes 0-27 (with checksum field zeroed)
4. Compare calculated value with extracted header_crc32c
5. If header valid, extract page_crc32c from offset 32
6. Calculate payload checksum over payload area
7. Compare calculated value with extracted page_crc32c
8. Page is valid if both checksums match

## Rust Crates for CRC32C

### Recommended Crates

**crc32c** (by danburkert)
- **Repository**: github.com/danburkert/crc32c
- **Features**: Hardware-accelerated CRC32C with software fallback
- **Architecture**: Uses runtime CPU feature detection
- **Pros**:
  - Automatic hardware acceleration on x86-64 and ARM
  - Pure Rust implementation with no unsafe code in fallback
  - Widely used and well-tested
  - MIT/Apache-2.0 licensing
- **API**: Simple function-based interface
- **Recommended**: Yes, primary choice

**crc-catalog** (by fearphage)
- **Repository**: github.com/fearphage/crc-catalog
- **Features**: Comprehensive CRC catalog including CRC32C
- **Architecture**: Table-based software implementation
- **Pros**:
  - Multiple CRC variants in one crate
  - No external C dependencies
  - Flexible API
- **Cons**:
  - No hardware acceleration (slower)
  - More complex API if you only need CRC32C
- **Recommended**: Alternative if hardware detection is problematic

**crc** (by mrhooray)
- **Repository**: github.com/mrhooray/crc
- **Features**: Generic CRC implementation with CRC32C support
- **Architecture**: Software-only with table lookup
- **Pros**:
  - Supports many CRC variants
  - Simple API
- **Cons**:
  - No hardware acceleration
  - Less actively maintained
- **Recommended**: Only if other crates are unavailable

### Crate Selection Criteria

**Performance**: Hardware acceleration is critical for database throughput
- crc32c crate provides 10-20x speedup with CPU instructions
- Software fallback ensures compatibility on all platforms

**Correctness**: Must match CRC32C specification exactly
- Polynomial: 0x1EDC6F41
- Initial value: 0xFFFFFFFF
- Final XOR: 0xFFFFFFFF
- All recommended crates implement correct CRC32C

**Licensing**: Must be compatible with project license
- crc32c: MIT/Apache-2.0 (permissive)
- crc-catalog: MIT (permissive)
- crc: MIT (permissive)

## Integration Approach

### Basic Integration

**Add Dependency**: Add to Cargo.toml
```toml
[dependencies]
crc32c = "0.6"
```

**Simple Usage**: Calculate checksum of byte slice
```rust
use crc32c::crc32c;

let data: &[u8] = &/* your data */;
let checksum = crc32c(data);
```

### Page Header Checksum

**Header Checksum Calculation**:
```rust
fn calculate_header_checksum(header: &PageHeader) -> u32 {
    // Create a copy with checksum fields zeroed
    let mut header_bytes = [0u8; 40];
    header_bytes[0..28].copy_from_slice(&header.as_bytes()[0..28]);
    // Bytes 28-39 remain zero (checksum fields and padding)

    // Calculate CRC32C over first 28 bytes
    crc32c(&header_bytes[0..28])
}
```

**Header Checksum Validation**:
```rust
fn validate_header_checksum(header: &PageHeader) -> bool {
    let stored = header.header_crc32c;
    let calculated = calculate_header_checksum(header);
    stored == calculated
}
```

### Page Payload Checksum

**Payload Checksum Calculation**:
```rust
fn calculate_payload_checksum(payload: &[u8], payload_len: u32) -> u32 {
    // Only checksum the valid payload bytes
    let valid_bytes = &payload[..payload_len as usize];
    crc32c(valid_bytes)
}
```

**Payload Checksum Validation**:
```rust
fn validate_payload_checksum(page: &Page) -> bool {
    let stored = page.header.page_crc32c;
    let calculated = calculate_payload_checksum(
        &page.payload,
        page.header.payload_len
    );
    stored == calculated
}
```

### Complete Page Validation

**Integrated Validation Function**:
```rust
fn validate_page(page: &Page) -> Result<(), PageError> {
    // Step 1: Validate magic number
    if page.header.magic != PAGE_MAGIC {
        return Err(PageError::InvalidMagic);
    }

    // Step 2: Validate header checksum
    if !validate_header_checksum(&page.header) {
        return Err(PageError::HeaderChecksumMismatch);
    }

    // Step 3: Validate payload length
    if page.header.payload_len as usize > page.payload.len() {
        return Err(PageError::PayloadLengthInvalid);
    }

    // Step 4: Validate payload checksum
    if !validate_payload_checksum(page) {
        return Err(PageError::PayloadChecksumMismatch);
    }

    Ok(())
}
```

### Performance Optimization

**Hardware Acceleration Detection**: The crc32c crate handles this automatically
- Uses CPUID to detect SSE4.2 or ARM CRC extensions at runtime
- Falls back to software implementation on unsupported hardware
- No configuration needed

**Batch Processing**: For multiple pages, use parallel processing
```rust
use rayon::prelude::*;

pages.par_iter()
    .map(|page| validate_page(page))
    .collect::<Result<Vec<_>, _>>()?;
```

**Incremental Update**: For partial page modifications, update checksum incrementally
- More complex than recalculating full checksum
- Only beneficial for very large payloads
- Generally not worth the complexity for 16KB pages

### Error Handling

**Checksum Mismatch**: Return specific error indicating corruption type
```rust
pub enum PageError {
    InvalidMagic,
    HeaderChecksumMismatch,
    PayloadChecksumMismatch,
    PayloadLengthInvalid,
    UnsupportedFormat,
}
```

**Recovery Strategy**: When corruption is detected
1. Log the corruption details (page_id, expected vs actual checksum)
2. Return error to caller
3. Caller may attempt recovery from WAL or replica
4. Database should not proceed with corrupted data

## Testing Strategy

**Unit tests needed for**:
- CRC32C calculation matches known test vectors
- Header checksum calculation is correct
- Payload checksum calculation is correct
- Checksum validation rejects corrupted data
- Checksum validation accepts correct data

**Property tests for**:
- Different inputs produce different checksums (avalanche property)
- Similar inputs produce very different checksums
- Checksum of empty buffer is deterministic
- Checksum is idempotent (same input always produces same output)

**Integration tests for**:
- Pages written and read maintain checksum validity
- Corrupted pages are detected during read
- Checksum validation catches single-bit errors
- Checksum validation catches burst errors up to 32 bits

**Known Test Vectors**: Verify against standard CRC32C test vectors
- Empty input: 0x00000000 (after final XOR)
- "123456789": 0xE3069283
- "Hello, World!": 0x2B3E8C0A
- 16KB of zeros: deterministic value

## Dependencies

- **Uses**: Page types (for header and payload structure)
- **Used by**: Pager (for page validation), WAL (for record integrity), Recovery (for corruption detection)

## Rust Implementation Guidance

### Crate Selection

**Use crc32c crate**: Best balance of performance and compatibility
```toml
[dependencies]
crc32c = "0.6"
```

**Enable hardware acceleration**: Default feature set
```toml
[dependencies]
crc32c = { version = "0.6", features = ["std"] }
```

### Module Structure

Create a dedicated checksum module:
```rust
// northstar_core::checksum
pub mod checksum;

pub use checksum::crc32c;
pub use checksum::{validate_header, validate_payload, validate_page};
```

### Type Definitions

**Checksum Type**: Use u32 for checksum values
```rust
pub type Checksum = u32;
```

**Validation Result**: Use Result for error handling
```rust
pub enum ChecksumError {
    HeaderMismatch { expected: u32, actual: u32 },
    PayloadMismatch { expected: u32, actual: u32 },
    LengthInvalid { len: u32, max: usize },
}
```

### Implementation Notes

1. **Const Evaluation**: CRC32C lookup table can be computed at compile time
   - Reduces initialization overhead
   - May not be possible with all crates (some use runtime CPU detection)

2. **Zero-Copy Validation**: Validate checksums without copying page data
   ```rust
   fn validate_page_bytes(bytes: &[u8]) -> Result<(), ChecksumError> {
       let header_checksum = crc32c(&bytes[0..28]);
       // Compare with stored checksum
       // Validate payload similarly
   }
   ```

3. **Checksum Caching**: For frequently accessed pages, cache validation result
   - Avoid recomputing checksum on every access
   - Invalidate cache when page is modified
   - Trade memory for reduced CPU usage

4. **Parallel Validation**: Use rayon for validating multiple pages concurrently
   ```rust
   use rayon::prelude::*;
   pages.par_iter().for_each(|page| validate_page(page));
   ```

5. **Debug Mode**: In debug builds, enable extra checksum verification
   - Verify checksums more frequently
   - Add sanity checks for development
   - May impact performance but catches bugs early