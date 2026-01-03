# TransactionId

## Purpose

TransactionId is a strongly-typed identifier that uniquely represents a transaction within NorthstarDB. It wraps a raw 64-bit integer to provide type safety and prevent confusion with other identifier types (PageId, LSN, etc.). Each transaction receives a unique TransactionId at the beginning of its lifecycle, which is used for MVCC visibility tracking, conflict detection, and recovery coordination.

## Types

### TransactionId

**Description**: A newtype wrapper around u64 representing a unique transaction identifier. The newtype pattern prevents accidental substitution of transaction IDs with other u64 values and ensures compile-time type safety.

**Size**: 8 bytes (same as the inner u64)

**Alignment**: 8-byte aligned (natural alignment for u64)

**Invariants**:
- Each active or committed transaction has a unique TransactionId
- TransactionIds are allocated sequentially from a global counter
- TransactionId values are strictly increasing over time (never reused)
- TransactionId 0 is special and represents "no transaction" or "initial state"
- TransactionId allocation is atomic and thread-safe for concurrent access

## Special Values

### INVALID_TXN_ID (0)

**Description**: Sentinel value representing no transaction or invalid state

**Usage**:
- Initial value before any transactions begin
- Indicates "not in a transaction" context
- Represents the starting state before first transaction
- May indicate uninitialized or corrupted state in certain contexts

**Semantics**: TransactionId(0) is valid but special - means "before any transaction"

### First Valid TransactionId (1)

**Description**: The first actual transaction receives TransactionId 1

**Usage**:
- First user transaction after database initialization
- First transaction after recovery

**Note**: TransactionIds start at 1, not 0, to distinguish from "no transaction" state

## Allocation Strategy

### Sequential Counter Allocation

**Global Counter**: Database maintains a global next_txn_id counter
- **Location**: Stored in Db struct (in-memory state)
- **Initialization**: Set to (committed_txn_id + 1) on database open
- **Persistence**: Highest committed TransactionId stored in meta page

**Allocation Algorithm**:
1. Read current next_txn_id value
2. Assign this value to the new transaction
3. Increment next_txn_id by 1
4. Store original assigned value in transaction context

**Atomicity**: Allocation must be atomic for concurrent transactions
- Multiple transactions must not receive the same TransactionId
- Allocation should use atomic increment or locking
- In Zig: Uses direct counter access (single threaded writer)
- In Rust: Should use AtomicU64 or Mutex for thread safety

### Recovery Initialization

**After Recovery**: TransactionId counter initialized from committed state
1. Read committed_txn_id from meta page (highest committed transaction)
2. Set next_txn_id = committed_txn_id + 1
3. Ensures new transactions don't reuse committed TransactionIds

**Uncommitted Transactions**: After crash, uncommitted transactions are discarded
- Their TransactionIds are effectively skipped (never committed)
- This is acceptable - TransactionId gaps are allowed
- Monotonicity is preserved (counter never decreases)

## Uniqueness Guarantees

### Active Transactions

**Concurrent Uniqueness**: No two active transactions share the same TransactionId
- Guaranteed by atomic allocation (or single-threaded allocation)
- Each transaction begin operation receives a unique ID
- Used for MVCC visibility to distinguish transaction modifications

### Committed Transactions

**Historical Uniqueness**: Committed TransactionIds are never reused
- Once committed, a TransactionId is permanently associated with that transaction
- TransactionIds only increase, never wrap around
- Gaps may exist (aborted or crashed transactions) but IDs never repeat

### Persistent State

**Recovery Consistency**: TransactionId uniqueness survives crashes and restarts
- Committed TransactionId persisted in meta page
- Counter resumes from highest committed value after recovery
- Ensures new transactions don't conflict with historical state

## Overflow Considerations

### Maximum Capacity

**Theoretical Maximum**: With 64-bit TransactionIds:
- Maximum TransactionId: 2^64 - 1
- At 1 million transactions per second: ~584,000 years to exhaust
- Practical limit: Far beyond any realistic workload

### Overflow Detection

**Before Overflow**: System should detect approaching overflow
- Monitor TransactionId counter near u64::MAX
- May need database migration or export before overflow
- Current implementation: No explicit overflow handling

**After Overflow**: If counter were to wrap:
- TransactionId reuse would break MVCC guarantees
- Historical transactions could become confused with new ones
- System MUST prevent wraparound in production

## Comparison and Ordering

### Equality Comparison

**Same Transaction**: Two TransactionIds are equal if they refer to the same transaction
- Used to check if two operations are in the same transaction
- Compares inner u64 values for equality
- Basis for Hash and HashMap usage

### Ordering Comparison

**Chronological Order**: TransactionId ordering indicates transaction start order
- If txn_a < txn_b, then txn_a began before txn_b
- Used for MVCC snapshot determination
- Used for conflict detection and serialization ordering

**Partial Order**: TransactionIds provide a total order
- For any two TransactionIds a and b: a < b, a = b, or a > b
- Enables binary search and range queries on transaction history
- Used for time-travel queries and snapshot isolation

### Serialization Order

**Commit Order**: Transactions commit in TransactionId order (approximately)
- Higher TransactionId generally means later commit
- Used for write-write conflict detection
- Basis for serializable isolation level

## Persistence Format

### On-Disk Representation

**Binary Format**: TransactionId stored as raw u64 in little-endian byte order
- **Size**: Exactly 8 bytes
- **Byte Order**: Little-endian (consistent with all multi-byte integers)
- **Location**: Multiple storage locations

**Meta Page Storage**: committed_txn_id field in MetaPayload
- **Purpose**: Track highest committed transaction for recovery
- **Updated**: On each successful transaction commit
- **Usage**: Initialize next_txn_id counter after restart

**WAL Record Storage**: txn_id field in WAL record headers
- **Purpose**: Associate log records with transaction
- **Validation**: Cross-check txn_id in commit records
- **Recovery**: Rebuild transaction state during log replay

**Page Header Storage**: txn_id field in PageHeader
- **Purpose**: Track which transaction last modified each page
- **Usage**: MVCC visibility determination
- **Recovery**: Detect dirty pages during recovery

### Serialization

**To Bytes**: Convert TransactionId to [u8; 8] array
- **Method**: Extract inner u64, convert to little-endian bytes
- **Usage**: Writing to file, network transmission
- **Implementation**: txn_id.as_u64().to_le_bytes()

**From Bytes**: Parse TransactionId from [u8; 8] array
- **Method**: Convert bytes to u64, wrap in TransactionId
- **Usage**: Reading from file, network reception
- **Implementation**: TransactionId::new(u64::from_le_bytes(bytes))

## Functions

### new(id: u64) -> TransactionId

**Purpose**: Construct a TransactionId from a raw u64 value

**Parameters**:
- id: Raw 64-bit transaction identifier

**Returns**: TransactionId wrapping the provided value

**Validation**: May validate that the ID is within expected range

### as_u64(&self) -> u64

**Purpose**: Extract the raw u64 value from a TransactionId

**Returns**: The inner 64-bit transaction identifier

**Usage**: Needed for I/O operations, arithmetic, serialization

### is_valid(&self) -> bool

**Purpose**: Check if this TransactionId represents a valid transaction

**Returns**: True if TransactionId > 0, false if TransactionId == 0

**Note**: Distinguishes "no transaction" state from actual transactions

### is_initial(&self) -> bool

**Purpose**: Check if this is the initial TransactionId (no transaction)

**Returns**: True if TransactionId == 0, false otherwise

### next(&self) -> Option<TransactionId>

**Purpose**: Get the next sequential TransactionId

**Returns**: Some(TransactionId) with incremented value, or None on overflow

**Usage**: Predicting next allocation, pre-validation

### distance_to(&self, other: TransactionId) -> Option<u64>

**Purpose**: Calculate number of transactions between two TransactionIds

**Parameters**:
- other: The other TransactionId to measure distance to

**Returns**: Some(number of transactions) if other >= self, None if underflow

**Note**: Handles overflow gracefully with Option return

## Trait Implementations

### Required Traits

**Copy**: TransactionId should implement Copy trait
- **Reason**: TransactionId is a simple wrapper around u64, cheap to duplicate
- **Semantics**: Copying creates a new reference to the same transaction

**Clone**: Derived from Copy
- **Reason**: Required for generic APIs, trivial implementation

**Debug**: Display TransactionId in human-readable format
- **Format**: "TransactionId(42)" or similar
- **Usage**: Debugging, logging, diagnostics

**Display**: User-friendly string representation
- **Format**: May show as just the number, or with "txn 42" prefix
- **Usage**: Error messages, user-facing output

**PartialEq/Eq**: Equality comparison
- **Semantics**: Two TransactionIds are equal if their inner u64 values match
- **Usage**: Comparing transaction references, checking same transaction

**PartialOrd/Ord**: Ordering by numeric value
- **Semantics**: Ordering based on inner u64 value
- **Usage**: MVCC visibility, conflict detection, snapshot queries
- **Note**: Lower TransactionIds began earlier

**Hash**: Use in HashMap and HashSet
- **Implementation**: Hash the inner u64 value
- **Usage**: Tracking transaction state, caching

### Serialization Traits

**Serialize/Deserialize** (via serde): Convert to/from wire format
- **Representation**: Serialize as u64 (the inner value)
- **Usage**: Network protocols, save files, inter-process communication

## Conversions

### From u64

**Explicit Construction**: TransactionId::new(id) or TransactionId(id)
- **Rationale**: Explicit conversion prevents accidental misuse
- **Alternative**: Some APIs may accept u64 directly and convert internally

### From<usize>

**Safe Conversion**: usize to TransactionId (when usize <= u64)
- **Usage**: Converting array indices or lengths
- **Panics**: On platforms where usize > u64 (unlikely in practice)

### To u64

**Accessor**: txn_id.as_u64() or *txn_id (via Deref)
- **Rationale**: Explicit extraction makes type conversions visible
- **Alternative**: Deref trait allows automatic coercion to u64

## Usage Patterns

### When to Use TransactionId vs Raw u64

**Use TransactionId**:
- In public APIs (function parameters, return values, struct fields)
- When storing transaction references (page headers, WAL records, metadata)
- When passing transaction identifiers between modules
- For type safety and compiler-assisted correctness

**Use Raw u64**:
- For I/O operations (file offsets, buffer indices)
- In performance-critical inner loops (after type checking at boundaries)
- When working with FFI or raw binary formats
- For arithmetic that needs to overflow to u64

### Common Operations

**MVCC Visibility**: Compare transaction IDs for snapshot determination
```rust
if page_txn_id <= snapshot_txn_id {
    // Page is visible to snapshot
}
```

**Conflict Detection**: Check for write-write conflicts
```rust
if writer_txn_id != reader_txn_id {
    // Potential conflict - different transactions
}
```

**Serialization Order**: Order transactions by ID for commit
```rust
transactions.sort_by_key(|txn| txn.id());
```

**Recovery Validation**: Verify transaction IDs match expected state
```rust
if commit_txn_id != page_txn_id {
    // Mismatch indicates corruption
}
```

## Invariants

- **Uniqueness**: Active transaction IDs are unique within a database
- **Monotonicity**: TransactionId counter only increases, never decreases or wraps
- **Persistence**: Highest committed TransactionId survives process restarts
- **Ordering**: TransactionId ordering reflects transaction start order
- **Special Value**: TransactionId 0 is reserved for "no transaction" state
- **Overflow Protection**: TransactionId allocation should detect overflow before u64::MAX

## Relationships to Other Types

### TransactionId vs LSN

**Different Purposes**:
- TransactionId identifies a transaction (logical operation)
- LSN identifies a position in the WAL (physical log location)

**Relationship**:
- One transaction generates multiple WAL records (multiple LSNs)
- Commit record associates LSN with TransactionId
- Both are monotonically increasing but at different rates

### TransactionId vs PageId

**Different Domains**:
- TransactionId identifies transactions (ephemeral operation units)
- PageId identifies storage pages (persistent disk blocks)

**Interaction**:
- Page headers store txn_id of last modifying transaction
- Used for MVCC visibility determination
- Different types prevent accidental confusion

## Dependencies

- **Uses**: Error types module (for overflow errors)
- **Used by**: Transactions (allocation), MVCC (visibility), WAL (record association), Pager (page tracking), Recovery (state reconstruction)

## Rust Implementation Guidance

### Module Structure

TransactionId should be defined in a central types module:
- `northstar_core::types::TransactionId` - Core transaction identifier type
- May be re-exported from `northstar_core::TransactionId` for convenience

### Type Definition

**Newtype Pattern**: Use tuple struct with transparent representation
```rust
#[repr(transparent)]
#[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TransactionId(u64);
```

**Rationale**:
- `repr(transparent)` ensures same layout and ABI as u64
- Zero-cost abstraction - no runtime overhead
- Private inner field prevents direct u64 manipulation
- Type safety from compiler prevents mixing with other u64 values

### Constructor Functions

**Primary Constructor**:
```rust
impl TransactionId {
    pub const fn new(id: u64) -> Self {
        Self(id)
    }
}
```

**Const**: Allow construction in const contexts (compile-time TransactionIds)

**Checked Increment**:
```rust
impl TransactionId {
    pub fn next(self) -> Option<Self> {
        self.0.checked_add(1).map(Self)
    }
}
```

### Accessor Methods

**Extraction**:
```rust
impl TransactionId {
    pub const fn as_u64(self) -> u64 {
        self.0
    }
}
```

**Predicates**:
```rust
impl TransactionId {
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
impl TransactionId {
    pub fn distance_to(self, other: Self) -> Option<u64> {
        other.0.checked_sub(self.0)
    }
}
```

### Trait Implementations

**Display**:
```rust
impl Display for TransactionId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "txn {}", self.0)
    }
}
```

**Debug**:
```rust
impl Debug for TransactionId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "TransactionId({})", self.0)
    }
}
```

**Serialization** (with serde):
```rust
impl Serialize for TransactionId {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.0.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for TransactionId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserialize<'de>,
    {
        u64::deserialize(deserializer).map(Self)
    }
}
```

### Key Decisions

**Transparent vs Opaque**: Use `repr(transparent)` for zero-cost abstraction
- Same size and alignment as u64 (8 bytes)
- Same ABI compatibility for FFI
- Can transmute to/from u64 safely if needed

**Thread Safety**: For concurrent transaction allocation, use:
```rust
pub struct TransactionAllocator {
    next_id: AtomicU64,
}

impl TransactionAllocator {
    pub fn allocate(&self) -> TransactionId {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        TransactionId::new(id)
    }
}
```

**Checked Arithmetic**: Use Option returns for overflow-prone operations
- Prevents silent overflow bugs
- Forces caller to handle edge case
- Better than panic for high-value TransactionIds near u64::MAX

**Const Where Possible**: Mark methods as `const` when possible
- Allows compile-time evaluation
- Enables use in const generics, array sizes
- Improves optimization opportunities

### Implementation Notes

1. **Arithmetic Traits**: Do NOT implement Add, Sub, Mul, etc.
   - TransactionIds are opaque identifiers, not numbers
   - Arithmetic on IDs is error-prone
   - Use explicit methods (next, distance_to) for valid operations

2. **Overflow Protection**: TransactionId allocation must check before increment
   ```rust
   pub fn allocate_next(current: TransactionId) -> Result<TransactionId, Error> {
       current.next()
           .ok_or(Error::TransactionIdOverflow)
   }
   ```

3. **Recovery Initialization**: Restore counter from persistent state
   ```rust
   let next_id = committed_txn_id.as_u64() + 1;
   db.next_txn_id = AtomicU64::new(next_id);
   ```

4. **Comparison Optimization**: Ord implementation enables efficient B-tree structures
   ```rust
   use std::collections::BTreeMap;
   let txns: BTreeMap<TransactionId, TransactionState> = BTreeMap::new();
   ```

5. **Serialization Compatibility**: Ensure little-endian byte order
   ```rust
   impl TransactionId {
       pub fn to_le_bytes(self) -> [u8; 8] {
           self.0.to_le_bytes()
       }

       pub fn from_le_bytes(bytes: [u8; 8]) -> Self {
           Self(u64::from_le_bytes(bytes))
       }
   }
   ```

6. **Special Value Constructors**: Provide named constructors for special values
   ```rust
   impl TransactionId {
       pub const INITIAL: Self = Self(0);
       pub const FIRST: Self = Self(1);
   }
   ```

### Testing Strategy

**Unit tests needed for**:
- Construction from u64 values
- Equality and ordering comparisons
- Valid vs initial TransactionId detection
- Distance calculation correctness
- Next/offset operations
- Overflow handling (near u64::MAX)

**Property tests for**:
- Round-trip serialization (TransactionId -> u64 -> TransactionId)
- Monotonic ordering (if a < b, then a.as_u64() < b.as_u64())
- Distance formula (distance = b - a if b >= a)
- Transitivity (if a < b and b < c, then a < c)

**Integration scenarios**:
- Transaction begin allocates sequential IDs
- Recovery initializes counter correctly
- MVCC visibility uses ordering correctly
- Multiple transactions don't receive duplicate IDs