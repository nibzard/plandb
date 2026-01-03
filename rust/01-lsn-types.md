# LSN (Log Sequence Number)

## Purpose

LSN (Log Sequence Number) is a monotonically increasing counter that uniquely identifies each record in the Write-Ahead Log (WAL). LSNs provide a total ordering of all transaction operations, enabling crash recovery, replication, and point-in-time queries. Each WAL record carries its LSN, and LSNs are used to track log position, coordinate checkpointing, and detect replication lag.

## Types

### Lsn

**Description**: A newtype wrapper around u64 representing a unique position in the Write-Ahead Log sequence. LSNs increase monotonically as records are appended to the WAL.

**Size**: 8 bytes (same as the inner u64)

**Alignment**: 8-byte aligned (natural alignment for u64)

**Invariants**:
- LSN values never decrease within a WAL instance
- Each new WAL append receives a strictly greater LSN
- LSNs are contiguous (no gaps) within a single WAL file
- LSN 0 represents the initial state before any records
- LSN values persist across WAL truncation (only increase, never reset)

## Special Values

### INVALID_LSN (0)

**Description**: Initial LSN value before any WAL records are written

**Usage**:
- Initial value when WAL is created or opened empty
- Indicates "no previous record" for the first WAL entry
- Represents the starting point for recovery

**Semantics**: An LSN of 0 is valid but special - it means "before the beginning"

### First Valid LSN (1)

**Description**: The first actual WAL record receives LSN 1

**Usage**:
- First transaction's first operation
- First record after WAL creation

**Note**: LSNs start at 1, not 0, to distinguish from "no log" state

## Monotonicity Guarantees

### Strictly Increasing

**Append Operations**: Every WAL append increments the LSN
- If current LSN is N, next append receives LSN N+1
- No two records share the same LSN
- LSNs are never reused

**Persistence**: LSN values survive across restarts
- WAL stores LSN in record headers
- On recovery, LSN continues from highest found value
- Checkpointing stores highest LSN in metadata

### Ordering Properties

**Total Order**: LSNs provide a complete ordering of all operations
- For any two LSNs a and b: a < b, a = b, or a > b
- Operations can be compared by their LSN to determine order
- Used for MVCC visibility and conflict detection

**Causality**: Higher LSN implies "happened after"
- Record with LSN 100 occurred after record with LSN 99
- Used for replay to process operations in correct order
- Critical for crash recovery and replication

## Operations

### Comparison Operations

**Equality (a == b)**: Compare if two LSNs refer to the same log position
- Returns true if both LSNs have the same inner u64 value
- Used to check if a log position matches expected value

**Ordering (a < b, a <= b, a > b, a >= b)**: Compare LSN ordering
- Based on numeric comparison of inner u64 values
- Returns true if a's position in log is before/after b's position
- Used for range queries, progress tracking, validation

### Arithmetic Operations

**Distance Calculation (b - a)**: Calculate records between two LSNs
- **Purpose**: Determine how many records exist between two log positions
- **Returns**: Number of LSN steps from a to b (non-negative if b > a)
- **Usage**: Replication lag calculation, WAL size estimation
- **Implementation**: b.as_u64() - a.as_u64()
- **Note**: May overflow if u64 subtraction wraps

**Increment (a + 1)**: Get next LSN
- **Purpose**: Predict the LSN for next WAL append
- **Returns**: LSN with value (a.as_u64() + 1)
- **Usage**: Pre-allocation, reservation, validation
- **Panics**: On overflow at u64::MAX

**Add Offset (a + n)**: Add N records to LSN
- **Purpose**: Calculate future LSN based on current position
- **Returns**: LSN with value (a.as_u64() + n)
- **Usage**: Position prediction, buffer sizing
- **Panics**: On overflow

**Subtract Offset (a - n)**: Subtract N records from LSN
- **Purpose**: Calculate past LSN based on current position
- **Returns**: LSN with value (a.as_u64() - n)
- **Usage**: Rewind for retry, buffer management
- **Panics**: On underflow (if n > a.as_u64())

## Persistence Format

### On-Disk Representation

**Binary Format**: LSN stored as raw u64 in little-endian byte order
- **Size**: Exactly 8 bytes
- **Byte Order**: Little-endian (consistent with all multi-byte integers)
- **Location**: Stored in WAL record headers at fixed offset

**WAL Record Header**: LSN is a field in each record header
- **Offset**: First field in header (offset 0)
- **Purpose**: Self-identifying - record contains its own LSN
- **Validation**: Used to detect torn writes or corruption

**Metadata Storage**: LSN persisted in database meta page
- **Field**: log_tail_lsn in MetaPayload
- **Purpose**: Track checkpoint position, recovery starting point
- **Updated**: On checkpoint and WAL truncation

### Serialization

**To Bytes**: Convert Lsn to [u8; 8] array
- **Method**: Extract inner u64, convert to little-endian bytes
- **Usage**: Writing to file, network transmission
- **Implementation**: lsn.as_u64().to_le_bytes()

**From Bytes**: Parse Lsn from [u8; 8] array
- **Method**: Convert bytes to u64, wrap in Lsn
- **Usage**: Reading from file, network reception
- **Implementation**: Lsn::new(u64::from_le_bytes(bytes))

## Functions

### new(lsn: u64) -> Lsn

**Purpose**: Construct an Lsn from a raw u64 value

**Parameters**:
- lsn: Raw 64-bit log sequence number

**Returns**: Lsn wrapping the provided value

**Validation**: May validate that the LSN is within expected range

### as_u64(&self) -> u64

**Purpose**: Extract the raw u64 value from an Lsn

**Returns**: The inner 64-bit log sequence number

**Usage**: Needed for I/O operations, arithmetic, serialization

### is_valid(&self) -> bool

**Purpose**: Check if this LSN represents a valid log position

**Returns**: True if LSN > 0, false if LSN == 0

**Note**: Distinguishes "no log" state from actual log positions

### is_initial(&self) -> bool

**Purpose**: Check if this is the initial LSN (before any records)

**Returns**: True if LSN == 0, false otherwise

### distance_to(&self, other: Lsn) -> Option<u64>

**Purpose**: Calculate the number of records between two LSNs

**Parameters**:
- other: The other LSN to measure distance to

**Returns**: Some(number of records) if other >= self, None if underflow

**Note**: Handles overflow gracefully with Option return

### next(&self) -> Option<Lsn>

**Purpose**: Get the next sequential LSN

**Returns**: Some(Lsn) with incremented value, or None if overflow

**Usage**: Pre-allocating LSNs, validation

### offset(&self, count: u64) -> Option<Lsn>

**Purpose**: Add an offset to this LSN

**Parameters**:
- count: Number of records to advance

**Returns**: Some(Lsn) with offset applied, or None on overflow

## Trait Implementations

### Required Traits

**Copy**: Lsn should implement Copy trait
- **Reason**: Lsn is a simple wrapper around u64, cheap to duplicate
- **Semantics**: Copying creates a new reference to the same log position

**Clone**: Derived from Copy
- **Reason**: Required for generic APIs, trivial implementation

**Debug**: Display Lsn in human-readable format
- **Format**: "Lsn(42)" or similar
- **Usage**: Debugging, logging, diagnostics

**Display**: User-friendly string representation
- **Format**: May show as just the number, or with "LSN 42" prefix
- **Usage**: Error messages, user-facing output

**PartialEq/Eq**: Equality comparison
- **Semantics**: Two Lsns are equal if their inner u64 values match
- **Usage**: Comparing log positions, checking progress

**PartialOrd/Ord**: Ordering by numeric value
- **Semantics**: Ordering based on inner u64 value
- **Usage**: Binary search, sorting, range queries
- **Note**: Lower LSNs appear earlier in the log

**Hash**: Use in HashMap and HashSet
- **Implementation**: Hash the inner u64 value
- **Usage**: Caching log records, tracking seen positions

**Step**: Enable iteration over LSN ranges
- **Implementation**: Provide forward/backward step operations
- **Usage**: Range iteration (for lsn in start..end)

### Serialization Traits

**Serialize/Deserialize** (via serde): Convert to/from wire format
- **Representation**: Serialize as u64 (the inner value)
- **Usage**: Network protocols, replication, save files

## Conversions

### From u64

**Explicit Construction**: Lsn::new(value) or Lsn(value)
- **Rationale**: Explicit conversion prevents accidental misuse
- **Alternative**: Some APIs may accept u64 directly and convert internally

### From<usize>

**Safe Conversion**: usize to Lsn (when usize <= u64)
- **Usage**: Converting array indices or lengths
- **Panics**: On platforms where usize > u64 (unlikely in practice)

### To u64

**Accessor**: lsn.as_u64() or *lsn (via Deref)
- **Rationale**: Explicit extraction makes type conversions visible
- **Alternative**: Deref trait allows automatic coercion to u64

## Usage Patterns

### When to Use Lsn vs Raw u64

**Use Lsn**:
- In public APIs (function parameters, return values, struct fields)
- When storing log references (WAL headers, metadata, transaction state)
- When passing log positions between modules
- For type safety and compiler-assisted correctness

**Use Raw u64**:
- For I/O operations (file offsets, buffer indices)
- In performance-critical inner loops (after type checking at boundaries)
- When working with FFI or raw binary formats
- For arithmetic that needs to overflow to u64

### Common Operations

**Progress Tracking**: Compare current LSN to target
```rust
if current_lsn >= target_lsn {
    // Caught up to required position
}
```

**Replication Lag**: Calculate records behind
```rust
let lag = primary_lsn.distance_to(replica_lsn)
    .unwrap_or(u64::MAX);
```

**WAL Position**: Estimate byte offset (approximate)
```rust
let offset = lsn.as_u64() * avg_record_size;
```

**Recovery**: Scan from checkpoint LSN
```rust
for record in wal.scan_from(checkpoint_lsn.next()?) {
    // Replay operations
}
```

## Invariants

- **Monotonicity**: LSN values never decrease within a WAL
- **Uniqueness**: Each WAL record has a unique LSN
- **Contiguity**: LSNs are sequential with no gaps (1, 2, 3, ...)
- **Persistence**: LSN values survive process restarts and crashes
- **Ordering**: For any two LSNs a and b, exactly one is true: a < b, a = b, a > b
- **Overflow Protection**: LSN allocation should detect overflow before u64::MAX

## Dependencies

- **Uses**: Error types module (for overflow errors)
- **Used by**: WAL (record sequencing), Recovery (log replay), Replication (lag tracking), Metadata (checkpoint tracking)

## Rust Implementation Guidance

### Module Structure

Lsn should be defined in a central types module:
- `northstar_core::types::Lsn` - Core log sequence number type
- May be re-exported from `northstar_core::Lsn` for convenience

### Type Definition

**Newtype Pattern**: Use tuple struct with transparent representation
```rust
#[repr(transparent)]
#[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Lsn(u64);
```

**Rationale**:
- `repr(transparent)` ensures same layout and ABI as u64
- Zero-cost abstraction - no runtime overhead
- Private inner field prevents direct u64 manipulation
- Type safety from compiler prevents mixing with other u64 values

### Constructor Functions

**Primary Constructor**:
```rust
impl Lsn {
    pub const fn new(lsn: u64) -> Self {
        Self(lsn)
    }
}
```

**Const**: Allow construction in const contexts (compile-time LSNs)

**Checked Increment**:
```rust
impl Lsn {
    pub fn next(self) -> Option<Self> {
        self.0.checked_add(1).map(Self)
    }
}
```

### Accessor Methods

**Extraction**:
```rust
impl Lsn {
    pub const fn as_u64(self) -> u64 {
        self.0
    }
}
```

**Predicates**:
```rust
impl Lsn {
    pub const fn is_valid(self) -> bool {
        self.0 > 0
    }

    pub const fn is_initial(self) -> bool {
        self.0 == 0
    }
}
```

**Distance Calculation**:
```rust
impl Lsn {
    pub fn distance_to(self, other: Self) -> Option<u64> {
        other.0.checked_sub(self.0)
    }
}
```

### Trait Implementations

**Display**:
```rust
impl Display for Lsn {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "LSN {}", self.0)
    }
}
```

**Debug**:
```rust
impl Debug for Lsn {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "Lsn({})", self.0)
    }
}
```

**Serialization** (with serde):
```rust
impl Serialize for Lsn {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.0.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Lsn {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserialize<'de>,
    {
        u64::deserialize(deserializer).map(Self)
    }
}
```

**Step Trait** (for range iteration):
```rust
impl Step for Lsn {
    fn steps_between(start: &Self, end: &Self) -> Option<usize> {
        Step::steps_between(&start.0, &end.0)
    }

    fn forward_checked(start: Self, count: usize) -> Option<Self> {
        start.0.checked_add(count as u64).map(Self)
    }

    fn backward_checked(start: Self, count: usize) -> Option<Self> {
        start.0.checked_sub(count as u64).map(Self)
    }
}
```

### Key Decisions

**Transparent vs Opaque**: Use `repr(transparent)` for zero-cost abstraction. This guarantees:
- Same size and alignment as u64 (8 bytes)
- Same ABI compatibility for FFI
- Can transmute to/from u64 safely if needed

**Checked Arithmetic**: Use Option returns for overflow-prone operations
- Prevents silent overflow bugs
- Forces caller to handle edge case
- Better than panic for high-value LSNs near u64::MAX

**Const Where Possible**: Mark methods as `const` when possible
- Allows compile-time evaluation
- Enables use in const generics, array sizes
- Improves optimization opportunities

**Range Iteration**: Implement Step trait for idiomatic range syntax
```rust
for lsn in Lsn(10)..Lsn(20) {
    // Process LSNs 10-19
}
```

### Implementation Notes

1. **Arithmetic Traits**: Do NOT implement Add, Sub, Mul, etc.
   - LSNs are opaque identifiers, not numbers
   - Arithmetic on LSNs is error-prone (what does "LSN 10 + LSN 5" mean?)
   - Use explicit methods (next, distance_to, offset) for valid operations

2. **Overflow Protection**: LSN allocation must check before increment
   ```rust
   pub fn allocate_next(current: Lsn) -> Result<Lsn, Error> {
       current.next()
           .ok_or(Error::LsnOverflow)
   }
   ```

3. **WAL Truncation**: LSNs never decrease, even after WAL truncation
   - Truncation removes old records but doesn't reset LSN counter
   - New appends continue from highest LSN ever seen
   - Ensures LSN uniqueness across entire database lifetime

4. **Comparison Optimization**: Ord implementation allows efficient B-tree structures
   ```rust
   use std::collections::BTreeMap;
   let log_index: BTreeMap<Lsn, LogRecord> = BTreeMap::new();
   ```

5. **Serialization Compatibility**: Ensure little-endian byte order
   ```rust
   impl Lsn {
       pub fn to_le_bytes(self) -> [u8; 8] {
           self.0.to_le_bytes()
       }

       pub fn from_le_bytes(bytes: [u8; 8]) -> Self {
           Self(u64::from_le_bytes(bytes))
       }
   }
   ```

### Testing Strategy

**Unit tests needed for**:
- Construction from u64 values
- Equality and ordering comparisons
- Valid vs initial LSN detection
- Distance calculation correctness
- Next/offset operations
- Overflow handling (near u64::MAX)

**Property tests for**:
- Round-trip serialization (Lsn -> u64 -> Lsn)
- Monotonic ordering (if a < b, then a.as_u64() < b.as_u64())
- Distance formula (distance = b - a if b >= a)
- Transitivity (if a < b and b < c, then a < c)

**Integration scenarios**:
- WAL append assigns sequential LSNs
- Recovery scans from checkpoint LSN correctly
- Replication lag calculation works across restarts
- LSN overflow is detected before allocation