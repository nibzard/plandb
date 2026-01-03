# PageId

## Purpose

PageId is a strongly-typed identifier that uniquely represents a single page within a NorthstarDB database file. It wraps a raw 64-bit integer to provide type safety and prevent confusion between different identifier types (transaction IDs, log sequence numbers, etc.). Every page in the database has a unique PageId that remains constant for the lifetime of that page allocation.

## Types

### PageId

**Description**: A newtype wrapper around u64 representing a unique page identifier within a database file. The newtype pattern prevents accidental substitution of page IDs with other u64 values like transaction IDs or LSNs.

**Size**: 8 bytes (same as the inner u64)

**Alignment**: 8-byte aligned (natural alignment for u64)

**Invariants**:
- Each PageId must be unique within a database at any point in time
- Once assigned, a PageId is never reused for a different page (except via free/reallocation cycle)
- Special reserved IDs (0 and 1) always refer to meta pages and cannot be allocated for general use
- PageIds must be monotonically increasing during allocation (no gaps in new allocations)
- PageIds are in the range 0 to (total_pages - 1) for the database file

## Special Values

### Reserved Page IDs

**META_A_PAGE_ID (0)**: First meta page
- **Purpose**: Primary metadata page
- **Content**: Database metadata (root page pointer, freelist head, transaction state)
- **Invariants**: Never freed, never reallocated, always valid after database creation

**META_B_PAGE_ID (1)**: Second meta page
- **Purpose**: Alternate metadata page for atomic updates
- **Content**: Mirrors META_A_PAGE_ID, used for two-phase commit of metadata
- **Invariants**: Never freed, never reallocated, always valid after database creation

### Data Page Range

**FIRST_DATA_PAGE (2)**: First page available for data allocation
- **Purpose**: All page IDs >= 2 are available for B+tree nodes, WAL segments, freelist pages, etc.
- **Allocation**: Page allocator starts allocation from this value
- **Note**: Pages 0 and 1 are permanently reserved and exempt from general allocation

### Null/Invalid Indicator

**NULL_PAGE_ID (0)**: Technically same as META_A_PAGE_ID, but semantically used to indicate "no page"
- **Usage**: When a field may legitimately not have an associated page (e.g., empty tree has no root)
- **Ambiguity**: Overlaps with META_A_PAGE_ID, so context matters
- **Alternative**: Some code may use u64::MAX or a dedicated Option<PageId> type for clearer semantics

## PageId Allocation

### Allocation Strategy

**Monotonic Allocation**: New page IDs are allocated sequentially from the highest existing page ID
- If file has N pages, next allocation is page ID N
- This ensures no gaps in newly allocated IDs
- Supports efficient file size tracking (file_size = last_allocated_id * page_size)

**Free Page Reuse**: When pages are freed, their IDs are added to a free list for future reuse
- Freelist stores previously freed page IDs
- Allocator checks freelist before extending the file
- Reused pages are zeroed before reallocation
- Freelist is rebuilt on database open (not persisted directly)

### Uniqueness Guarantees

**Active Pages**: Each page ID in use (allocated but not freed) is unique
- No two active pages share the same ID
- A page ID cannot be allocated again until freed

**Lifetime Persistence**: A page ID persists for the lifetime of its allocation
- Moving page data requires allocating new IDs
- Copy-on-write creates new pages with new IDs
- Page IDs never change once assigned

**Reclamation**: Freed page IDs may be reused after a reallocation cycle
- Free-to-reuse gap allows time for crash recovery
- MVCC snapshots may still reference old page versions
- Reuse only occurs after freelist recycling

### Overflow Concerns

**Maximum Capacity**: With 64-bit page IDs, theoretical maximum is:
- Maximum page ID: 2^64 - 1
- With 16KB pages: 2^64 * 16KB = 256 exabytes (impractical)
- Practical limit: Filesystem size limits, not PageId range

**Page ID Exhaustion**: Not a practical concern:
- 64-bit ID space is astronomically large
- Database would hit filesystem limits first
- Even at 1 million pages per second, would take ~584,000 years to exhaust

## Functions

### new(id: u64) -> PageId

**Purpose**: Construct a PageId from a raw u64 value

**Parameters**:
- id: Raw 64-bit page identifier

**Returns**: PageId wrapping the provided value

**Validation**: May validate that the ID is within expected range (optional, depending on strictness)

### as_u64(&self) -> u64

**Purpose**: Extract the raw u64 value from a PageId

**Returns**: The inner 64-bit page identifier

**Usage**: Needed for I/O operations, file offset calculation, serialization

### is_meta_page(&self) -> bool

**Purpose**: Check if this PageId refers to a meta page

**Returns**: True if PageId is 0 or 1, false otherwise

### is_null(&self) -> bool

**Purpose**: Check if this PageId represents the null/invalid value

**Returns**: True if PageId is 0, false otherwise

**Note**: May be ambiguous with meta page check depending on usage

### file_offset(&self, page_size: u64) -> u64

**Purpose**: Calculate the byte offset of this page within the database file

**Parameters**:
- page_size: Page size in bytes (e.g., 16384)

**Returns**: Byte offset from start of file where this page begins

**Algorithm**: page_id * page_size

### opposite_meta_id(&self) -> Option<PageId>

**Purpose**: Get the other meta page ID

**Returns**:
- Some(1) if called on PageId(0)
- Some(0) if called on PageId(1)
- None for all other page IDs

### next(&self) -> PageId

**Purpose**: Get the next sequential PageId

**Returns**: PageId wrapping (inner_value + 1)

**Usage**: Helpful for iteration or allocation planning

## Trait Implementations

### Required Traits

**Copy**: PageId should implement Copy trait
- **Reason**: PageId is a simple wrapper around u64, cheap to duplicate
- **Semantics**: Copying creates a new reference to the same page (not a new page)

**Clone**: Derived from Copy
- **Reason**: Required for generic APIs, trivial implementation

**Debug**: Display PageId in human-readable format
- **Format**: "PageId(42)" or similar
- **Usage**: Debugging, logging, diagnostics

**Display**: User-friendly string representation
- **Format**: May show as just the number, or with "page 42" prefix
- **Usage**: Error messages, user-facing output

**PartialEq/Eq**: Equality comparison
- **Semantics**: Two PageIds are equal if their inner u64 values match
- **Usage**: Comparing page references, hash map keys

**PartialOrd/Ord**: Ordering by numeric value
- **Semantics**: Ordering based on inner u64 value
- **Usage**: Binary search, sorting, range queries
- **Note**: Lower page IDs appear earlier in the file

**Hash**: Use in HashMap and HashSet
- **Implementation**: Hash the inner u64 value
- **Usage**: Caching page data, tracking visited pages

### Serialization Traits

**Serialize/Deserialize** (via serde): Convert to/from wire format
- **Representation**: Serialize as u64 (the inner value)
- **Usage**: Network protocols, save files, inter-process communication

**Borrow/ToOwned**: If using reference-counted or borrowing patterns
- **Usage**: Avoid copying PageId in performance-critical code

## Conversions

### From u64

**Explicit Construction**: PageId::new(id) or PageId(id)
- **Rationale**: Explicit conversion prevents accidental misuse
- **Alternative**: Some APIs may accept u64 directly and convert internally

### From<T> for other integer types

**u32, u16, u8, usize**: May provide From implementations
- **Safety**: Must ensure no loss of precision (u32 to u64 is safe)
- **Usage**: Convenience for APIs that work with sized integers

### To u64

**Accessor**: page_id.as_u64() or *page_id (via Deref)
- **Rationale**: Explicit extraction makes type conversions visible
- **Alternative**: Deref trait allows automatic coercion to u64

### Option<PageId> patterns

**Null Representation**: Use Option<PageId> instead of sentinel values
- **Some(PageId(42))**: Valid page reference
- **None**: No page (empty tree, unallocated, etc.)
- **Advantage**: Clearer semantics than using 0 as both meta page and null indicator

## Usage Patterns

### When to Use PageId vs Raw u64

**Use PageId**:
- In public APIs (function parameters, return values, struct fields)
- When storing page references (page headers, B+tree nodes, metadata)
- When passing page identifiers between modules
- For type safety and compiler-assisted correctness

**Use Raw u64**:
- For I/O operations (file offsets, buffer indices)
- In performance-critical inner loops (after type checking at boundaries)
- When working with FFI or raw binary formats
- For arithmetic that needs to overflow to u64

### Common Operations

**Page Navigation**: Calculate offsets for reading/writing pages
```rust
let offset = page_id.file_offset(page_size);
file.seek(SeekFrom::Start(offset))?;
```

**Page Validation**: Check if page ID is within valid range
```rust
if page_id.as_u64() >= total_pages {
    return Err(Error::PageOutOfBounds);
}
```

**Meta Page Access**: Check for special pages
```rust
if page_id.is_meta_page() {
    // Handle meta pages specially
}
```

**Iteration**: Iterate through a range of pages
```rust
for page_id in PageId(2)..PageId(10) {
    // Process each page
}
```

## Invariants

- **Uniqueness**: Active page IDs are unique within a database
- **Monotonic Allocation**: New allocations use sequential IDs from the highest existing ID
- **Reserved Values**: IDs 0 and 1 are permanently reserved for meta pages
- **Lifetime Persistence**: A page ID never changes once assigned
- **Range Boundaries**: Valid page IDs are in range [0, total_pages)
- **Reuse Semantics**: Freed page IDs may be reused after a reallocation cycle

## Dependencies

- **Uses**: Error types module (for validation errors)
- **Used by**: Pager (page allocation), B+tree (node references), WAL (log management), all storage operations

## Rust Implementation Guidance

### Module Structure

PageId should be defined in a central types module:
- `northstar_core::types::PageId` - Core page identifier type
- May be re-exported from `northstar_core::PageId` for convenience

### Type Definition

**Newtype Pattern**: Use tuple struct with transparent representation
```rust
#[repr(transparent)]
#[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PageId(u64);
```

**Rationale**:
- `repr(transparent)` ensures same layout and ABI as u64
- Zero-cost abstraction - no runtime overhead
- Private inner field prevents direct u64 manipulation
- Type safety from compiler prevents mixing with other u64 values

### Constructor Functions

**Primary Constructor**:
```rust
impl PageId {
    pub const fn new(id: u64) -> Self {
        Self(id)
    }
}
```

**Const**: Allow construction in const contexts (compile-time page IDs)

**Validation Constructor** (optional):
```rust
impl PageId {
    pub fn try_new(id: u64, max_pages: u64) -> Result<Self, Error> {
        if id >= max_pages {
            return Err(Error::PageIdOutOfBounds { id, max_pages });
        }
        Ok(Self(id))
    }
}
```

### Accessor Methods

**Extraction**:
```rust
impl PageId {
    pub const fn as_u64(self) -> u64 {
        self.0
    }
}
```

**Predicates**:
```rust
impl PageId {
    pub const fn is_meta_page(self) -> bool {
        self.0 == 0 || self.0 == 1
    }

    pub const fn is_null(self) -> bool {
        self.0 == 0
    }

    pub const fn is_data_page(self) -> bool {
        self.0 >= 2
    }
}
```

### Trait Implementations

**Display**:
```rust
impl Display for PageId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "page {}", self.0)
    }
}
```

**Debug**:
```rust
impl Debug for PageId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "PageId({})", self.0)
    }
}
```

**Serialization** (with serde):
```rust
impl Serialize for PageId {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.0.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for PageId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserialize<'de>,
    {
        u64::deserialize(deserializer).map(Self)
    }
}
```

**Step Trait** (for iteration):
```rust
impl Step for PageId {
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

**Derive Traits**: Derive all standard traits (Copy, Clone, Debug, etc.) for idiomatic Rust

**Const Generics**: Consider making page size a const generic parameter:
```rust
pub struct PageId<const PAGE_SIZE: u64 = 16384>(u64);

impl<const PAGE_SIZE: u64> PageId<PAGE_SIZE> {
    pub const fn file_offset(self) -> u64 {
        self.0 * PAGE_SIZE
    }
}
```

**Option vs Sentinels**: Prefer `Option<PageId>` over using 0 as null indicator
- More explicit and type-safe
- Avoids ambiguity with meta page IDs
- Idiomatic Rust pattern

### Implementation Notes

1. **Arithmetic Operations**: Do NOT implement Add, Sub, Mul, etc. traits
   - Page IDs are opaque identifiers, not numbers
   - Arithmetic on IDs is error-prone (what does "page 5 + page 3" mean?)
   - Use explicit methods for valid operations (next, prev, offset)

2. **Range Checks**: Add helper methods for validation
   ```rust
   impl PageId {
       pub fn in_range(self, start: Self, end: Self) -> bool {
           self.0 >= start.0 && self.0 < end.0
       }
   }
   ```

3. **File Offset Calculation**: Provide efficient offset computation
   ```rust
   impl PageId {
       pub const fn file_offset(self, page_size: u64) -> u64 {
           self.0 * page_size
       }
   }
   ```

4. **Special Value Constructors**: Provide named constructors for reserved IDs
   ```rust
   impl PageId {
       pub const META_A: Self = Self(0);
       pub const META_B: Self = Self(1);
       pub const FIRST_DATA: Self = Self(2);
   }
   ```

5. **Conversion from usize**: Useful for array/vec indexing
   ```rust
   impl From<usize> for PageId {
       fn from(value: usize) -> Self {
           Self(value as u64)
       }
   }
   ```

6. **Borrow Semantics**: If using reference counting, consider:
   ```rust
   #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
   pub struct PageId(u64);

   // No Arc/RefCell needed - Copy semantics are correct
   ```

### Testing Strategy

**Unit tests needed for**:
- Construction from u64 values
- Equality and ordering comparisons
- Special value detection (is_meta_page, is_null)
- File offset calculation correctness
- Range validation
- Option<PageId> serialization

**Property tests for**:
- Round-trip serialization (PageId -> u64 -> PageId)
- Monotonic ordering (if a < b, then a.as_u64() < b.as_u64())
- File offset formula (offset = id * page_size)
- Meta page identification (only 0 and 1)

**Integration scenarios**:
- Page allocation returns sequential IDs
- Freelist reuses IDs correctly
- Page IDs persist across database open/close
- Reserved IDs are never allocated
- Overflow behavior (edge cases near u64::MAX)