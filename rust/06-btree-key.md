# B+Tree Key Encoding and Ordering

## Purpose

This specification defines how keys are encoded, stored, and compared within the B+Tree structure. Keys are the primary indexing mechanism that enables ordered storage and efficient retrieval. The encoding scheme ensures compact representation, fast comparison, and consistent ordering across all tree operations. Understanding key encoding is critical for implementing search, insert, delete, and range scan operations correctly.

## Types

### Key

**Description**: Variable-length byte array representing a lookup key in the B+Tree. Keys are opaque byte sequences interpreted only through comparison functions, allowing maximum flexibility for different data types while maintaining efficient storage.

**Size**: Variable length, 0 to 255 bytes

**Structure**:
- **Length prefix** (u8, 1 byte): Number of bytes in the key data
- **Key data** (byte array, 0-255 bytes): Raw key bytes

**Alignment**: None (byte-aligned)

**Invariants**:
- Key length must be between 0 and 255 bytes inclusive
- Empty keys (length 0) are allowed but unusual
- Key bytes are stored exactly as provided, no transformation
- Key comparison uses lexicographic byte ordering by default

### KeyPrefix

**Description**: Optimization structure for keys with common prefixes. Stores shared prefix once plus unique suffixes for each key. Used for prefix compression within nodes to reduce storage overhead.

**Size**: Variable length

**Structure**:
- **Common prefix** (byte array): Shared bytes among multiple keys
- **Unique suffixes** (array of byte arrays): Distinct byte sequences for each key

**Invariants**:
- Common prefix must be identical across all compressed keys
- Suffixes must be different for each key
- Full key = common_prefix + unique_suffix
- Compression beneficial only when common_prefix length > overhead

### KeyComparator

**Description**: Function pointer or trait object defining custom key comparison logic. Enables alternative ordering strategies beyond default lexicographic ordering.

**Type**: Function pointer: fn(key1: &[u8], key2: &[u8]) -> Ordering

**Return Values**:
- Less: key1 < key2
- Equal: key1 == key2
- Greater: key1 > key2

**Invariants**:
- Must be transitive: if a < b and b < c, then a < c
- Must be antisymmetric: if a < b, then not b < a
- Must be total: for any two keys, exactly one of a < b, a == b, a > b holds
- Must be consistent across all operations on a single tree

## Key Encoding

### Length-Prefix Encoding

**Description**: Simple encoding scheme storing key length immediately before key bytes. Enables fast key boundary detection during node traversal.

**Binary Format**:
```
Offset  Size    Field          Description
------  ----    -----          -----------
0       1       key_len        Number of key bytes (0-255)
1       N       key_bytes      Raw key data (N = key_len)
--      --      --             --
Total:  1+N bytes              Variable length
```

**Example Encodings**:
- Empty key: [0x00] (1 byte)
- Key "abc": [0x03, 0x61, 0x62, 0x63] (4 bytes)
- Key "\xFF\xFF\xFF": [0x03, 0xFF, 0xFF, 0xFF] (4 bytes)

**Advantages**:
- Simple to encode and decode
- No special characters or escape sequences
- Fast length calculation without scanning
- Compatible with lexicographic ordering

**Disadvantages**:
- 1-byte overhead per key
- Maximum key length limited to 255 bytes
- Length byte interferes with pure byte ordering

### Null-Terminated Encoding (Alternative)

**Description**: C-style string encoding with null terminator. Not used in NorthstarDB but described for comparison.

**Binary Format**:
- Key bytes followed by 0x00 terminator
- Length determined by scanning for terminator

**Advantages**:
- Zero overhead per key
- Compatible with C string libraries

**Disadvantages**:
- Keys cannot contain null bytes
- Requires scanning to find key boundary
- Slower than length-prefix encoding
- Incompatible with binary keys

### Varint Encoding (Alternative)

**Description**: Variable-length integer encoding for key length. Not used in V0 but potential future optimization.

**Binary Format**:
- Varint-encoded length (1-9 bytes depending on value)
- Followed by key bytes

**Advantages**:
- Efficient for small keys (1 byte overhead)
- Supports larger keys (>255 bytes) if needed

**Disadvantages**:
- More complex encoding/decoding
- Requires varint parsing on every key access
- Slower than fixed-length prefix

## Key Ordering

### Lexicographic Byte Ordering (Default)

**Description**: Standard byte-by-byte comparison from most significant to least significant byte. Same as memcmp() semantics in C.

**Algorithm**:
1. Find minimum length of the two keys
2. Compare bytes from index 0 to min_length-1
3. At first differing byte, key with smaller byte value is less
4. If all bytes equal up to min_length, shorter key is less

**Examples**:
- "abc" < "abd" (differs at position 2: 0x63 < 0x64)
- "ab" < "abc" (shorter key is less when prefix matches)
- "ABC" < "abc" (0x41 < 0x61 at position 0)
- "\x00\x00" < "\x00\x01" (differs at position 1)
- "123" < "45" (0x31 < 0x34 at position 0)

**Properties**:
- Total order: any two keys are comparable
- Transitive: consistent ordering across comparisons
- Compatible with unsigned byte interpretation
- Efficient: single pass through key bytes

**Implementation Notes**:
- Use memcmp() or equivalent for performance
- SIMD acceleration possible for longer keys
- Early exit on first differing byte
- No special cases for null bytes or other values

### Reverse Lexicographic Ordering

**Description**: Lexicographic comparison on bitwise-complemented keys. Enables efficient descending order scans.

**Algorithm**:
1. Complement all bytes in both keys: byte' = 0xFF - byte
2. Compare complemented keys using lexicographic ordering
3. Result is reverse of original ordering

**Properties**:
- Maintains total order property
- Enables reverse iteration without sorting
- Useful for "ORDER BY key DESC" queries

**Use Case**: Range scans in descending key order

### Custom Collation Ordering

**Description**: Application-defined comparison function implementing language-specific or domain-specific ordering rules.

**Examples**:
- Case-insensitive ordering: "ABC" == "abc"
- Numeric ordering: "key2" < "key10" (unlike lexicographic where "key10" < "key2")
- Locale-aware ordering: Language-specific character ordering
- Composite key ordering: Multi-field keys with type-aware comparison

**Implementation**:
- Function pointer passed to B+Tree creation
- Called for every key comparison
- Must maintain ordering invariants (transitive, antisymmetric, total)

**Tradeoffs**:
- Flexibility vs performance (custom function slower than memcmp)
- Requires careful implementation to avoid ordering bugs
- Cannot leverage SIMD or hardware optimizations

### Composite Key Encoding

**Description**: Keys composed of multiple fields concatenated with separators. Enables multi-dimensional indexing.

**Encoding Format**:
- Field 1 bytes + separator + Field 2 bytes + separator + ... + Field N bytes
- Separator: byte value not appearing in field data (often 0x00 or 0xFF)

**Example**: (user_id: 123, timestamp: 999999)
- Encoding: [0x03, 0x31, 0x32, 0x33, 0x00, 0x06, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39]
- Fields: "123" + 0x00 + "999999"

**Ordering**: Lexicographic ordering provides natural multi-dimensional sort
- Primary sort: Field 1
- Secondary sort: Field 2
- Tertiary sort: Field 3
- And so on...

**Applications**:
- Multi-column database indexes
- Time series data (user_id + timestamp)
- Geospatial data (latitude + longitude)

## Key Comparison Functions

### compare_keys(key1: &[u8], key2: &[u8]) -> Ordering

**Purpose**: Compare two keys using default lexicographic ordering

**Algorithm**:
1. Determine minimum length: min_len = min(key1.len(), key2.len())
2. Iterate i from 0 to min_len-1:
   a. Compare key1[i] and key2[i]
   b. If key1[i] < key2[i], return Less
   c. If key1[i] > key2[i], return Greater
3. If all bytes equal up to min_len:
   a. If key1.len() < key2.len(), return Less
   b. If key1.len() > key2.len(), return Greater
   c. Return Equal (keys identical)

**Returns**: Ordering enum (Less, Equal, Greater)

**Performance**: O(min(len(key1), len(key2))) byte comparisons

**Optimization**: Early exit on first differing byte

### compare_keys_reverse(key1: &[u8], key2: &[u8]) -> Ordering

**Purpose**: Compare two keys using reverse lexicographic ordering

**Algorithm**:
1. Complement key1: key1_rev[i] = 0xFF - key1[i] for all i
2. Complement key2: key2_rev[i] = 0xFF - key2[i] for all i
3. Return compare_keys(key1_rev, key2_rev)

**Returns**: Ordering enum (reversed from standard)

**Performance**: O(len(key1) + len(key2)) for complement + comparison

**Use Case**: Descending order range scans

### key_matches_prefix(key: &[u8], prefix: &[u8]) -> bool

**Purpose**: Check if a key starts with a given prefix

**Algorithm**:
1. If key.len() < prefix.len(), return false
2. Iterate i from 0 to prefix.len()-1:
   a. If key[i] != prefix[i], return false
3. Return true (all prefix bytes matched)

**Returns**: true if key starts with prefix, false otherwise

**Use Case**: Prefix-based range scans

### find_common_prefix(key1: &[u8], key2: &[u8]) -> usize

**Purpose**: Find length of common prefix between two keys

**Algorithm**:
1. Determine minimum length: min_len = min(key1.len(), key2.len())
2. Iterate i from 0 to min_len-1:
   a. If key1[i] != key2[i], return i
3. Return min_len (entire shorter key is common prefix)

**Returns**: Number of matching prefix bytes

**Use Case**: Prefix compression calculation

## Key Validation

### validate_key(key: &[u8]) -> Result<(), KeyError>

**Purpose**: Verify key meets all validity constraints

**Algorithm**:
1. Check key length <= MAX_KEY_SIZE (255 bytes)
   - If not, return KeyTooLarge error
2. Check key length >= 0 (always true)
3. No other validation (all byte sequences valid)

**Returns**: Ok(()) if valid, Err(KeyError) if invalid

**Error Conditions**:
- KeyTooLarge: key length exceeds 255 bytes

**Note**: All byte sequences are valid keys, no content restrictions

### validate_key_for_encoding(key: &[u8], encoding: KeyEncoding) -> Result<(), KeyError>

**Purpose**: Verify key compatible with specific encoding scheme

**Algorithm**:
1. Check validate_key(key) passes
2. If encoding is NullTerminated:
   a. Scan key bytes for 0x00
   b. If found, return InvalidNullByte error
3. Return Ok(())

**Returns**: Ok(()) if compatible, Err(KeyError) if not

**Error Conditions**:
- KeyTooLarge: key length exceeds maximum
- InvalidNullByte: null-terminated encoding cannot handle null bytes in key

## Key Size Limits

### Maximum Key Size

**Value**: 255 bytes

**Rationale**:
- Fits in single u8 length prefix
- Prevents oversized keys from consuming excessive node space
- Sufficient for most use cases (IDs, timestamps, composite keys)

**Alternatives Considered**:
- 64KB (u16 length prefix): More flexibility, but reduces node capacity
- Unlimited: Adds complexity, risks node overflow, hurts performance

**Tradeoffs**:
- Pro: Simple encoding, bounded node space, predictable performance
- Con: Cannot store large documents as keys (use values instead)

### Minimum Key Size

**Value**: 0 bytes (empty key allowed)

**Rationale**:
- Empty key is valid (e.g., "default" or "root" record)
- No technical reason to prohibit empty keys

**Use Cases**:
- Special sentinel values
- Default records
- Metadata entries

### Typical Key Sizes

**Database Primary Keys**: 4-16 bytes
- Integer IDs: 4-8 bytes
- UUIDs: 16 bytes
- String IDs: 4-32 bytes

**Composite Keys**: 8-64 bytes
- Two integers: 8 bytes
- UUID + timestamp: 24 bytes
- User ID + partition key: 16-32 bytes

**Time Series Keys**: 8-24 bytes
- Timestamp alone: 8 bytes
- Metric name + timestamp: 16-24 bytes

## Key Storage in Nodes

### Internal Node Keys

**Purpose**: Separator keys dividing key space between children

**Storage**: Array of length-prefixed keys in node body

**Layout**:
```
[Separator Key 1][Separator Key 2]...[Separator Key N]
```

**Properties**:
- Keys in strictly increasing order
- N = num_keys (from NodeHeader)
- All keys in Child[i] < Separator[i] <= all keys in Child[i+1]
- Separator keys are copies of keys from level below (not stored with values)

**Memory Overhead**:
- Each key: 1 byte length prefix + N bytes key data
- Total: sum(1 + len(separator[i])) for all separators

### Leaf Node Keys

**Purpose**: Actual data keys for key-value pairs

**Storage**: Array of length-prefixed keys interleaved with values

**Layout**:
```
[Key 1][Value 1][LSN 1][Key 2][Value 2][LSN 2]...[Key N][Value N][LSN N]
```

**Properties**:
- Keys in strictly increasing order
- N = num_keys (from NodeHeader)
- Each key associated with value and LSN

**Memory Overhead**:
- Each key: 1 byte length prefix + N bytes key data
- Total: sum(1 + len(key[i])) for all keys

## Key Comparison Optimization

### SIMD Acceleration

**Purpose**: Use vector instructions to compare multiple key bytes in parallel

**Implementation**:
- Use SIMD registers (128-bit SSE, 256-bit AVX, 512-bit AVX-512)
- Load 16/32/64 bytes from each key
- Compare with single vector instruction
- Find first differing byte with vector operations

**Benefits**:
- 16-32x speedup for long keys vs byte-by-byte comparison
- Most effective for keys > 16 bytes

**Limitations**:
- Only works for keys fitting in vector registers
- Requires CPU support (SSE2, AVX2, etc.)
- Added complexity for alignment and edge cases

### Short-Circuit Comparison

**Purpose**: Exit comparison as soon as ordering determined

**Algorithm**:
1. Compare bytes from index 0
2. On first differing byte, return result immediately
3. Never scan entire key unless keys equal

**Benefit**:
- Average case: 1-2 byte comparisons for random keys
- Worst case: O(min(len(key1), len(key2))) for identical prefixes

### Cached Key Hashes

**Purpose**: Precompute hash to accelerate equality checks

**Implementation**:
- Store hash (e.g., xxHash64) alongside key
- Compare hashes before comparing keys
- Only compare key bytes if hashes equal

**Benefits**:
- Fast inequality detection (single 64-bit compare)
- Useful for hash-based lookups or duplicate detection

**Drawbacks**:
- Storage overhead (8 bytes per key)
- Hash computation cost on key insert
- Not useful for ordering (hashes don't preserve order)

## Key Compression

### Prefix Compression

**Purpose**: Reduce storage by storing common prefix once per node

**Algorithm**:
1. Find common prefix among all keys in node
2. Store common prefix once in node header
3. For each key, store only unique suffix
4. Full key = common_prefix + unique_suffix

**Compression Ratio**:
- Depends on key distribution
- Best case: All keys share long prefix (e.g., same user_id)
- Worst case: Random keys, minimal common prefix
- Typical: 10-30% space savings

**Implementation Complexity**:
- Requires prefix computation on node modification
- Key comparison must reconstruct full key
- Adds CPU overhead for compression/decompression

**Use When**:
- Keys have structured prefixes (user IDs, timestamps, partition keys)
- Node space is at premium
- CPU overhead acceptable

### Dictionary Compression

**Purpose**: Replace common keys with dictionary references

**Algorithm**:
1. Identify most frequent keys in node
2. Store frequent keys in dictionary
3. Replace occurrences with dictionary index (1-2 bytes)
4. Reference dictionary on key access

**Benefits**:
- High compression for repetitive keys
- Very compact encoding for common keys

**Drawbacks**:
- Dictionary management overhead
- Indirection cost on key access
- Only effective for highly repetitive workloads

## Rust Implementation Guidance

### Module Structure

Define key types and functions in:
- `northstar_core::tree::key::Key` - Key type and encoding
- `northstar_core::tree::key::KeyComparator` - Comparison trait
- `northstar_core::tree::key::KeyEncoding` - Encoding schemes

### Type Definitions

**Key Type**: Use wrapper around byte slice for type safety:
```rust
pub type Key<'a> = &'a [u8];
pub type BoxedKey = Box<[u8]>;
```

**KeyComparator Trait**: Define interface for custom comparators:
```rust
pub trait KeyComparator: Send + Sync {
    fn compare(&self, key1: &[u8], key2: &[u8]) -> Ordering;
}
```

**Default Comparator**: Implement lexicographic ordering:
```rust
pub struct LexicographicComparator;

impl KeyComparator for LexicographicComparator {
    fn compare(&self, key1: &[u8], key2: &[u8]) -> Ordering {
        key1.cmp(key2)  // Uses standard lexicographic ordering
    }
}
```

### Key Encoding

**Length-Prefix Encoding**: Simple byte array manipulation:
```rust
pub fn encode_key(key: &[u8]) -> Vec<u8> {
    let mut encoded = Vec::with_capacity(1 + key.len());
    encoded.push(key.len() as u8);
    encoded.extend_from_slice(key);
    encoded
}

pub fn decode_key(encoded: &[u8]) -> Result<&[u8], KeyError> {
    if encoded.is_empty() {
        return Err(KeyError::EmptyEncoding);
    }
    let key_len = encoded[0] as usize;
    if encoded.len() < 1 + key_len {
        return Err(KeyError::TruncatedKey);
    }
    Ok(&encoded[1..=key_len])
}
```

**Validation**: Enforce size limits:
```rust
pub fn validate_key(key: &[u8]) -> Result<(), KeyError> {
    if key.len() > MAX_KEY_SIZE {
        return Err(KeyError::KeyTooLarge {
            len: key.len(),
            max: MAX_KEY_SIZE,
        });
    }
    Ok(())
}
```

### Comparison Functions

**Default Comparison**: Use standard library for performance:
```rust
pub fn compare_keys(key1: &[u8], key2: &[u8]) -> Ordering {
    key1.cmp(key2)  // Optimized memcmp-based implementation
}
```

**Reverse Comparison**: Complement bytes then compare:
```rust
pub fn compare_keys_reverse(key1: &[u8], key2: &[u8]) -> Ordering {
    // Avoid allocation if possible by implementing custom comparator
    for (b1, b2) in key1.iter().zip(key2.iter()) {
        match (0xFF - b1).cmp(&(0xFF - b2)) {
            Ordering::Equal => continue,
            other => return other,
        }
    }
    key1.len().cmp(&key2.len())
}
```

### SIMD Optimization

**Use Criterion**: Profile before optimizing
- Only implement SIMD if profiling shows key comparison is bottleneck
- Most workloads benefit more from algorithmic improvements

**Recommended Crate**: Use `std::intrinsics::memcmp` (highly optimized):
```rust
pub fn compare_keys_simd(key1: &[u8], key2: &[u8]) -> Ordering {
    match key1.len().cmp(&key2.len()) {
        Ordering::Equal => {
            // Same length, use memcmp
            unsafe {
                let cmp = std::intrinsics::memcmp(
                    key1.as_ptr(),
                    key2.as_ptr(),
                    key1.len()
                );
                cmp.cmp(&0)
            }
        }
        other => other,
    }
}
```

### Error Handling

**KeyError Enum**: Define all key-related errors:
```rust
#[derive(Debug, thiserror::Error)]
pub enum KeyError {
    #[error("key too large: {len} bytes (max: {max})")]
    KeyTooLarge { len: usize, max: usize },

    #[error("key encoding invalid")]
    InvalidEncoding,

    #[error("key contains null byte (incompatible with null-terminated encoding)")]
    InvalidNullByte,

    #[error("key encoding truncated")]
    TruncatedKey,

    #[error("empty key encoding")]
    EmptyEncoding,
}
```

### Testing Strategy

**Unit tests needed for**:
- Key encoding/decoding round-trip
- Key comparison correctness (equal, less, greater cases)
- Key validation (valid and invalid sizes)
- Prefix calculation accuracy
- Reverse comparison ordering

**Property tests for**:
- Comparison transitivity: if a < b and b < c, then a < c
- Comparison antisymmetry: if a < b, then not b < a
- Comparison totality: any two keys comparable
- Encoding round-trip: decode(encode(key)) == key

**Performance tests**:
- Comparison throughput (keys per second)
- SIMD vs scalar comparison speedup
- Encoding/decoding overhead

**Integration scenarios**:
- Insert keys in random order, verify sorted order
- Range scan returns keys in correct order
- Prefix-based scans include all matching keys
- Composite keys ordered by all fields

## Invariants

### Key Encoding Invariants
1. Encoded key length equals 1 + raw_key_length
2. Decoded key equals original raw key
3. Key length never exceeds 255 bytes
4. Empty keys encode to single 0x00 byte

### Key Ordering Invariants
1. Comparison is transitive: if a < b and b < c, then a < c
2. Comparison is antisymmetric: if a < b, then not (b < a)
3. Comparison is total: for any keys a, b, exactly one of a < b, a == b, a > b
4. Equal keys have equal encodings
5. Lexicographic ordering matches memcmp semantics

### Key Storage Invariants
1. Keys within node stored in strictly increasing order
2. Internal node separator keys divide key space correctly
3. Leaf node keys are unique within node (duplicates handled via versioning)
4. All keys in left child < separator key in parent
5. All keys in right child >= separator key in parent

## Dependencies

**Uses**:
- Error types module (for KeyError)
- Constants for MAX_KEY_SIZE

**Used By**:
- B+Tree search operations (key comparison)
- B+Tree insert operations (key ordering)
- B+Tree delete operations (key lookup)
- B+Tree range scan operations (key iteration)
- Node structures (key storage)
- Prefix compression (common prefix detection)

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and key usage
- **06-btree-node.md**: Key storage within node structures
- **06-btree-search.md**: Key comparison during search operations
- **06-btree-value.md**: Value storage (complementary to key storage)
- **01-key-value-types.md**: General key-value type definitions
- **04-txn-get.md**: Key lookup in transaction operations
