# Key and Value Types

## Purpose

Keys and values are the fundamental data types in NorthstarDB, representing the byte-oriented key-value pairs stored in the database. Keys uniquely identify data entries and provide ordering for B+tree operations, while values hold the actual payload data. This specification defines the types, ownership semantics, comparison behavior, and trade-offs for implementing keys and values in Rust.

## Types

### Key

**Description**: A sequence of bytes that uniquely identifies an entry in the database. Keys are used for lookups, range scans, and ordering within the B+tree. Keys must be comparable to enable sorted storage and efficient binary search.

**Representation**: Byte slice (slice of u8)

**Ownership Options**:
- **Owned**: Vec<u8> for heap-allocated, owned key data
- **Borrowed**: &[u8] for references into existing buffers
- **Arc-Shared**: Arc<[u8]> for reference-counted shared key data

**Constraints**:
- **Minimum Length**: 1 byte (empty keys are not allowed)
- **Maximum Length**: 4096 bytes (4KB) recommended maximum
- **Encoding**: Raw binary data, no transformation or validation
- **Comparison**: Lexicographic byte ordering

**Invariants**:
- Keys are immutable once created
- Two keys with identical byte sequences are considered equal
- Key comparison is deterministic and consistent
- Keys cannot contain null bytes in the middle (no special handling required)

### Value

**Description**: Arbitrary byte sequences associated with a key. Values hold the actual data payload and have no special semantics beyond being byte arrays. Values are not used for comparison or ordering.

**Representation**: Byte slice (slice of u8)

**Ownership Options**:
- **Owned**: Vec<u8> for heap-allocated, owned value data
- **Borrowed**: &[u8] for references into existing buffers
- **Arc-Shared**: Arc<[u8]> for reference-counted shared value data

**Constraints**:
- **Minimum Length**: 0 bytes (empty values are allowed)
- **Maximum Length**: 16,777,216 bytes (16MB) recommended maximum
- **Encoding**: Raw binary data, no transformation or validation

**Invariants**:
- Values are immutable once created
- Two values with identical byte sequences are considered equal
- Values have no ordering semantics (only equality matters)

## Comparison Semantics

### Lexicographic Ordering

**Definition**: Keys are compared using lexicographic (dictionary) ordering, which compares bytes from left to right and uses the first differing byte to determine order.

**Algorithm**:
1. Start at the first byte (index 0) of both keys
2. While both keys have bytes at current position:
   - If key A's byte is less than key B's byte, then A < B
   - If key A's byte is greater than key B's byte, then A > B
   - If bytes are equal, advance to next position
3. If one key is exhausted:
   - The shorter key is considered less than the longer key
   - Example: "abc" < "abcd" (prefix is less)

**Implementation**: Uses standard byte-by-byte comparison
- Equivalent to C's memcmp() function
- Equivalent to Rust's slice comparison (PartialOrd for [u8])
- Hardware-accelerated on most platforms (SIMD instructions)

**Examples**:
- "apple" < "banana" (first byte 'a' (97) < 'b' (98))
- "apple" < "applepie" (shorter prefix is less)
- "ABC" < "abc" (uppercase 'A' (65) < lowercase 'a' (97))
- "123" < "45" (first byte '1' (49) < '4' (52))

### Total Ordering

**Property**: Lexicographic ordering provides a total order, meaning any two keys can be compared and one of three relations holds: less than, equal to, or greater than.

**Implications**:
- No incomparable keys (unlike some floating-point comparisons)
- Enables binary search in B+tree nodes
- Enables range queries with defined start and end keys
- Enables iterator traversal in sorted order

### Case Sensitivity

**Behavior**: Comparison is case-sensitive and based on raw byte values
- Uppercase letters have lower byte values than lowercase
- No locale-specific collation or normalization
- No Unicode case folding or accent handling

**Example**:
- "Zebra" < "apple" (90 < 97)
- "Apple" != "apple" (different byte sequences)

### Binary Safety

**Property**: All byte values (0-255) are valid in keys and values
- No special treatment for null bytes (0x00)
- No escaping or encoding required
- Raw binary data is stored as-is

**Implications**:
- Can store any binary data (images, serialized structs, encrypted data)
- Comparison works correctly for all byte values
- No need for base64 or hex encoding

## Rust Type Options

### Owned Types (Vec<u8>)

**Description**: Heap-allocated byte buffers with owned data

**Type Signature**:
```rust
pub type Key = Vec<u8>;
pub type Value = Vec<u8>;
```

**Advantages**:
- Simple ownership model with clear lifetime semantics
- No lifetime parameters to complicate APIs
- Easy to store in collections (HashMap, BTreeMap, Vec)
- Compatible with most serialization frameworks
- idiomatic Rust for owned byte data

**Disadvantages**:
- Requires allocation for each key/value
- Clone creates deep copy (expensive for large data)
- Higher memory overhead due to reference counting and capacity tracking

**Use Cases**:
- Transaction mutations (buffering operations)
- In-memory indexes and caches
- User-facing APIs where simplicity is important
- When data lifetime is not tied to external buffers

### Borrowed Types (&[u8])

**Description**: Slice references into existing byte buffers

**Type Signature**:
```rust
pub type Key<'a> = &'a [u8];
pub type Value<'a> = &'a [u8];
```

**Advantages**:
- Zero-copy when referencing existing data
- No allocation overhead
- Very efficient for read-only operations
- Small memory footprint (just pointer and length)

**Disadvantages**:
- Lifetime parameters complicate APIs
- Limited scope (cannot outlive referenced data)
- Harder to store in collections
- Requires careful lifetime management

**Use Cases**:
- WAL decoding and validation
- B+tree traversal (temporary references)
- Network protocol handling
- Performance-critical inner loops

### Arc-Shared Types (Arc<[u8]>)

**Description**: Reference-counted smart pointers to byte slices

**Type Signature**:
```rust
pub type Key = Arc<[u8]>;
pub type Value = Arc<[u8]>;
```

**Advantages**:
- Shared ownership with cheap cloning (just increments reference count)
- No deep copy on clone
- Can be stored in collections efficiently
- Memory efficient for duplicate keys/values

**Disadvantages**:
- Reference counting overhead (atomic operations)
- More complex than Vec<u8>
- Requires heap allocation
- Slightly slower than Vec<u8 for single-owner scenarios

**Use Cases**:
- Duplicate key deduplication
- Shared snapshots between transactions
- Caching frequently accessed data
- When many references to same data exist

### Bytes Crate (bytes::Bytes)

**Description**: Specialized type for byte buffers with Arc-like behavior and optimization for small data

**Type Signature**:
```rust
use bytes::Bytes;

pub type Key = Bytes;
pub type Value = Bytes;
```

**Advantages**:
- Optimized for both small and large buffers
- Cheap cloning (Arc-like behavior)
- Zero-copy slicing with shared ownership
- Widely used in Rust ecosystem (tokio, futures)
- Excellent for network I/O and serialization

**Disadvantages**:
- External dependency (adds to crate dependencies)
- More complex API than Vec<u8>
- Requires learning Bytes-specific methods
- Overkill for simple use cases

**Use Cases**:
- Network protocols and RPC
- High-performance I/O operations
- When already using tokio or futures ecosystem
- When zero-copy slices are frequently needed

## Trade-offs: Clone vs Copy

### Copy Semantics

**Definition**: Copy trait creates a bitwise copy of a value

**Applicability**: NOT suitable for keys and values
- **Reason**: Keys and values are variable-length byte sequences
- **Issue**: Cannot implement Copy for heap-allocated data (Vec<u8>, Arc<[u8]>)
- **Alternative**: Fixed-size arrays could be Copy but are impractical (too large)

**Conclusion**: Keys and values should NOT implement Copy trait

### Clone Semantics

**Definition**: Clone trait creates an explicit deep copy of a value

**Vec<u8> Clone Behavior**:
- Allocates new buffer
- Copies all bytes
- O(n) time complexity where n is length
- Expensive for large keys/values

**Arc<[u8]> Clone Behavior**:
- Increments reference count
- No data copying
- O(1) time complexity
- Very cheap even for large data

**Bytes Clone Behavior**:
- Similar to Arc<[u8]> (reference count increment)
- Additional optimizations for small inline data
- O(1) time complexity
- Very cheap

### Performance Considerations

**Allocation Overhead**:
- Vec<u8> clone: Requires heap allocation + memory copy
- Arc<[u8]> clone: Atomic increment only
- Bytes clone: Atomic increment only

**Memory Usage**:
- Vec<u8>: Unique ownership, no shared overhead
- Arc<[u8]>: Reference count overhead (atomic variable)
- Bytes: Reference count + inline storage optimization

**Cache Locality**:
- Vec<u8>: Better (contiguous storage, fewer indirections)
- Arc<[u8]>: Worse (pointer indirection to reference-counted data)
- Bytes: Mixed (inline for small data, indirection for large)

### Recommended Approach

**Primary API**: Use Vec<u8> for simplicity
```rust
pub type Key = Vec<u8>;
pub type Value = Vec<u8>;
```

**Internal Optimization**: Use Arc<[u8]> or Bytes when beneficial
- Duplicate key deduplication: Arc<[u8]>
- High-performance I/O: Bytes
- Read-heavy workloads with shared data: Arc<[u8]>

**Conversion Functions**: Provide conversions between representations
```rust
impl Key {
    pub fn from_vec(vec: Vec<u8>) -> Self {
        // Wrap Vec<u8> into appropriate type
    }

    pub fn from_static(bytes: &'static [u8]) -> Self {
        // Convert static slice to owned type
    }
}
```

## Comparison with Standard Library

### HashMap vs BTreeMap Keys

**HashMap**: Requires Hash + Eq traits
- NorthstarDB keys can work with HashMap
- Use custom hasher if keys have special patterns
- Good for in-memory indexes and caches

**BTreeMap**: Requires Ord trait (lexicographic ordering)
- NorthstarDB keys naturally support Ord
- Used for ordered iteration and range queries
- Good for sorted data structures

### Standard Library Comparison

**Slice Comparison**: &[u8] already implements Ord
- Uses lexicographic ordering by default
- Matches NorthstarDB requirements exactly
- No custom implementation needed

**Vec<u8> Comparison**: Inherits from slice comparison
- Also uses lexicographic ordering
- Consistent with borrowed slice comparison
- No custom implementation needed

**Custom Comparison**: Only needed for special cases
- Case-insensitive comparison
- Locale-specific collation
- Custom ordering schemes

## Helper Types

### KeyType Alias

**Purpose**: Provide semantic clarity and future flexibility

**Definition**:
```rust
pub type Key = Vec<u8>;
pub type KeyRef<'a> = &'a [u8];
```

**Benefits**:
- Clear intent (Key vs arbitrary bytes)
- Easy to change implementation
- Self-documenting code

### ValueType Alias

**Purpose**: Distinguish values from keys despite same representation

**Definition**:
```rust
pub type Value = Vec<u8>;
pub type ValueRef<'a> = &'a [u8];
```

**Benefits**:
- Prevents mixing keys and values at type level
- Enables different optimization strategies later
- Clear semantic distinction

### Entry Type

**Purpose**: Combine key and value into a single unit

**Definition**:
```rust
pub struct Entry {
    pub key: Key,
    pub value: Value,
}
```

**Use Cases**:
- Returning results from range scans
- B+tree node entries
- Batch insert operations

## Functions

### Key Comparison Functions

**compare(a: &[u8], b: &[u8]) -> Ordering**

**Purpose**: Compare two keys lexicographically

**Returns**:
- Less: if a < b
- Equal: if a == b
- Greater: if a > b

**Implementation**: Delegates to standard slice comparison
```rust
pub fn compare(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
    a.cmp(b)
}
```

**is_prefix_of(key: &[u8], prefix: &[u8]) -> bool**

**Purpose**: Check if a key starts with a given prefix

**Returns**: True if key starts with prefix bytes

**Usage**: Range scan filtering, prefix queries

**Implementation**:
```rust
pub fn is_prefix_of(key: &[u8], prefix: &[u8]) -> bool {
    key.starts_with(prefix)
}
```

### Value Comparison Functions

**equals(a: &[u8], b: &[u8]) -> bool**

**Purpose**: Compare two values for equality

**Returns**: True if values have identical byte sequences

**Implementation**: Delegates to standard slice equality
```rust
pub fn equals(a: &[u8], b: &[u8]) -> bool {
    a == b
}
```

**Note**: Values don't need ordering, only equality

## Invariants

- **Key Non-Empty**: Keys must contain at least 1 byte
- **Key Ordering**: Lexicographic ordering is total and consistent
- **Value Can Be Empty**: Zero-length values are valid
- **Binary Safety**: All byte values (0-255) are valid
- **Immutability**: Keys and values are immutable after creation
- **Comparison Determinism**: Same keys always compare the same way

## Dependencies

- **Uses**: Standard library only (no external dependencies for basic types)
- **Used by**: B+tree (ordering and search), Transactions (mutations), WAL (serialization)

## Rust Implementation Guidance

### Module Structure

Define key and value types in a dedicated module:
```rust
// northstar_core::types
pub mod kv;

pub use kv::{Key, KeyRef, Value, ValueRef};
```

### Type Definitions

**Recommended**: Use Vec<u8> with type aliases
```rust
pub type Key = Vec<u8>;
pub type KeyRef<'a> = &'a [u8];

pub type Value = Vec<u8>;
pub type ValueRef<'a> = &'a [u8];
```

**Alternative**: Use newtype wrappers for type safety
```rust
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Key(Vec<u8>);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Value(Vec<u8>);
```

**Best of Both**: Re-export with semantic names
```rust
pub use std::vec::Vec as Key;
pub use std::vec::Vec as Value;
```

### Trait Implementations

**Key Traits**: Vec<u8> already has all required traits
- PartialEq, Eq: Equality comparison
- PartialOrd, Ord: Lexicographic ordering
- Hash: Hashing for HashMap
- Clone: Deep copy
- Borrow: Deref to [u8]

**Value Traits**: Vec<u8> has required traits
- PartialEq, Eq: Equality comparison
- Clone: Deep copy
- Borrow: Deref to [u8]
- Note: Ord not needed for values

### Performance Optimization

**Avoid Clone**: Use references instead of cloning when possible
```rust
// Bad: clones the key
let key = entry.key.clone();
process(key);

// Good: uses reference
process(&entry.key);
```

**Arc for Sharing**: Use Arc when data is shared
```rust
// For duplicate keys in B+tree nodes
pub type SharedKey = Arc<[u8]>;
```

**Bytes for I/O**: Use bytes crate for network/disk I/O
```rust
// Add dependency
[dependencies]
bytes = "1.0"

// Use for I/O operations
pub use bytes::Bytes as IoBuffer;
```

### Testing Strategy

**Unit tests needed for**:
- Key comparison works correctly (less, equal, greater)
- Lexicographic ordering matches expected behavior
- Prefix detection works correctly
- Value equality works correctly
- Empty value handling

**Property tests for**:
- Comparison is transitive (if a < b and b < c, then a < c)
- Comparison is symmetric (a < b implies b > a)
- Equal keys have equal comparison results
- Prefix detection is correct for all inputs

**Integration tests for**:
- Keys work correctly with BTreeMap
- Keys work correctly with HashMap
- Serialization/deserialization preserves data
- Performance benchmarks for comparison operations