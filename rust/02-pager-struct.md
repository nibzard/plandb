# Pager Struct

## Purpose

The Pager struct is the central data structure that encapsulates all state for page-based storage management in NorthstarDB. It combines storage backend abstraction, metadata caching, page allocation tracking, and page caching into a single cohesive unit. This specification details every field in the Pager struct, explains the invariants maintained by each field, describes helper structures, and defines the Rust implementation with interior mutability patterns.

## Pager Struct Fields

### storage: Storage

**Type**: Storage enum (union of file handle or memory storage)

**Purpose**: Abstraction over the storage backend, enabling both file-based and in-memory databases

**Description**: The storage field holds either a file handle (for persistent databases) or an in-memory buffer (for temporary or testing databases). This union type allows the Pager to work with different storage backends through a common interface.

**Invariants**:
- storage is always initialized (never empty/invalid)
- If storage is a file, the file handle is valid and open
- If storage is memory, the memory buffer is properly allocated
- storage type cannot change after Pager creation (file vs memory is fixed)

**Helper Operations**:
- Read operations: Read from file or memory buffer at calculated offset
- Write operations: Write to file or memory buffer at calculated offset
- Close operation: Close file or deallocate memory buffer

### page_size: u16

**Type**: 16-bit unsigned integer

**Purpose**: Fixed page size for all pages in the database (typically 16384 bytes for 16KB pages)

**Description**: Defines the fundamental unit of I/O and allocation. All pages read or written must be exactly this size. The page size is fixed at database creation and cannot be changed.

**Invariants**:
- page_size is always a power of 2 (4096, 8192, 16384, 32768, or 65536)
- page_size is at least 4096 (typical system page size)
- page_size matches the page size in the meta page
- page_size never changes after Pager initialization

**Validation**:
- Used to validate buffer sizes for read and write operations
- Used to calculate file offsets (page_id * page_size)
- Checked against meta page page_size field for consistency

### current_meta: MetaState

**Type**: MetaState structure containing page_id, PageHeader, and MetaPayload

**Purpose**: Cached representation of the active meta page, providing fast access to database state without re-reading meta pages

**Description**: The current_meta field caches the decoded contents of whichever meta page (A or B) is currently active. This includes the page ID (0 or 1), the full page header, and the meta payload with committed transaction ID, root page ID, free list head, and log tail LSN.

**Invariants**:
- current_meta.page_id is either 0 (META_A_PAGE_ID) or 1 (META_B_PAGE_ID)
- current_meta is valid (passes all checksum and validation checks)
- current_meta represents the meta page with the highest committed_txn_id
- current_meta.meta.committed_txn_id is monotonic (never decreases)
- current_meta is kept in sync with storage (updated on commit)

**Helper Operations**:
- Accessor methods read fields from current_meta instead of storage
- Commit updates current_meta and writes it to storage
- Recovery chooses the valid meta page and caches it here

### allocator: Allocator

**Type**: Memory allocator (Zig: std.mem.Allocator, Rust: Allocator trait bound)

**Purpose**: Allocator used for all dynamic memory allocations within the Pager

**Description**: The allocator is used to allocate memory for internal data structures like the free list, page cache, and temporary buffers. In Zig, this is std.mem.Allocator. In Rust, this will be an Allocator trait bound or a specific allocator like std::alloc::System.

**Invariants**:
- allocator is valid and usable for the lifetime of the Pager
- All allocations through this allocator are freed before Pager is dropped
- allocator is not used after Pager is closed

**Helper Operations**:
- PageAllocator uses this allocator for its free list vector
- PageCache uses this allocator for cache entries
- Temporary buffers for I/O operations use this allocator

### page_allocator: Option<PageAllocator>

**Type**: Optional PageAllocator structure (null in Zig, Option in Rust)

**Purpose**: Manages free page tracking and page allocation, may be null during initialization

**Description**: The page_allocator maintains the list of free pages available for reuse and tracks the last allocated page ID for extending the file. It is initialized after the Pager is created, so it is optional during construction.

**Invariants**:
- page_allocator is null only during Pager construction
- page_allocator is always non-null after Pager is fully initialized
- page_allocator.free_pages contains sorted list of free page IDs
- page_allocator.last_allocated_page is the highest page ID ever allocated
- page_allocator.pager points back to the Pager (circular reference)

**Helper Operations**:
- allocate_page() delegates to page_allocator.allocatePage()
- free_page() delegates to page_allocator.freePage()
- Rebuilds free list on database open by scanning B+tree

### cache: Option<*PageCache>

**Type**: Optional pointer to PageCache structure (raw pointer in Zig, boxed or reference in Rust)

**Purpose**: Provides page-level caching to reduce I/O and improve performance

**Description**: The cache field points to a PageCache instance that manages cached pages, eviction policy, and pinning. The use of a raw pointer (in Zig) or reference (in Rust) avoids circular dependency issues since the cache may need to call back into the Pager.

**Invariants**:
- cache is null only during Pager construction
- cache is always non-null after Pager is fully initialized
- cache owns cached pages and manages their lifetimes
- Pages in cache match the contents of storage
- Dirty pages in cache are written back before eviction
- Pinning prevents eviction of pages currently in use

**Helper Operations**:
- read_page_cached() checks cache before reading from storage
- Pinning interface prevents cache eviction during use
- Unpinning releases pages for potential eviction

## Helper Structs

### MetaState

**Description**: Represents the state of a meta page, combining the page ID, header, and payload into a single structure for convenience and validation.

**Fields**:
- **page_id**: u64 - Page ID of this meta page (0 or 1)
- **header**: PageHeader - Decoded page header from the meta page
- **meta**: MetaPayload - Decoded metadata payload

**Purpose**: Encapsulates all information about a meta page for validation and comparison. Used during recovery to choose the valid meta page and to cache the active meta state.

**Invariants**:
- page_id matches the header.page_id field
- header.page_type is PageType::meta
- All checksums (header and meta) are valid
- page_id is either META_A_PAGE_ID (0) or META_B_PAGE_ID (1)

**Methods**:
- isValid(): Checks all checksums and page type
- isTornWrite(): Detects torn writes by checking internal consistency

### PageAllocator

**Description**: Manages the free list of pages available for reuse and tracks allocation state.

**Fields**:
- **pager**: Reference to Pager (for I/O operations)
- **free_pages**: Dynamic array of page IDs available for reuse
- **last_allocated_page**: Highest page ID ever allocated
- **allocator**: Memory allocator for dynamic array

**Purpose**: Efficiently allocates new pages by reusing freed pages when available, or extending the file when necessary. Maintains free list in sorted order to allocate the lowest available page ID first.

**Invariants**:
- free_pages is sorted in ascending order
- free_pages contains no duplicate page IDs
- free_pages contains no reserved page IDs (0 or 1)
- last_allocated_page is greater than or equal to the highest ID in free_pages
- All pages in free_pages are actually free (not referenced by B+tree)

### PageCache

**Description**: LRU (Least Recently Used) cache for pages, reducing disk I/O by keeping frequently accessed pages in memory.

**Fields** (implementation-specific):
- **entries**: Hash map from page ID to cached page data
- **lru_list**: Doubly-linked list or equivalent structure tracking usage order
- **pin_counts**: Map from page ID to number of active pins
- **capacity_bytes**: Maximum memory usage for cache
- **current_bytes**: Current memory usage

**Purpose**: Improve performance by caching frequently accessed pages, reducing the need for disk reads. Provides pinning to prevent eviction of pages currently in use.

**Invariants**:
- Cache size does not exceed capacity_bytes
- Pinned pages cannot be evicted
- Unpinned pages are evicted in LRU order when cache is full
- Dirty pages are written back before eviction
- Cached page data matches storage (for non-dirty pages)

### Storage

**Description**: Union type abstracting over file-based and memory-based storage backends.

**Variants**:
- **file**: File handle (std::fs::File or equivalent) for persistent storage
- **memory**: In-memory buffer for non-persistent databases

**Purpose**: Enable the same Pager API to work with both persistent file-based databases and transient in-memory databases, useful for testing and caching scenarios.

**Invariants**:
- Exactly one variant is active (file or memory, never both)
- File handle is valid and open (if file variant)
- Memory buffer is properly allocated (if memory variant)
- Storage type is fixed after Pager creation

## Rust Struct with Interior Mutability

### Struct Definition

**Layout**: Using standard Rust struct with all required fields
```rust
pub struct Pager {
    storage: Storage,
    page_size: u16,
    current_meta: MetaState,
    page_allocator: Option<PageAllocator>,
    cache: Option<Box<PageCache>>,
}
```

**Note**: allocator field in Zig becomes a lifetime parameter or generic parameter in Rust

### Interior Mutability Pattern

**Purpose**: Allow methods like read_page and allocate_page to modify Pager state even when Pager is behind an immutable reference

**Challenge**: Many Pager methods need to modify internal state (cache, allocator) but should be callable with shared references

**Pattern**: Use interior mutability with RwLock or Mutex

### Mutex vs RwLock Choice

**Use RwLock for Pager**: Recommended choice for Pager

**Rationale for RwLock**:
- **Multiple readers**: Many concurrent read operations (read_page, get_root_page_id, etc.)
- **Single writer**: Only one write operation at a time (write_page, allocate_page, free_page)
- **Read-heavy workload**: Databases typically have many more reads than writes
- **No blocking readers**: Multiple threads can read concurrently
- **Better performance**: Read operations don't block each other

**RwLock Behavior**:
- Any number of readers can hold read lock simultaneously
- Only one writer can hold write lock exclusively
- Writers wait for all readers to release read locks
- Readers wait for writer to release write lock
- Write operations are serialized (only one at a time)

**When Mutex Would Be Better**:
- Very low contention (single-threaded or rare concurrent access)
- Simple locking needed (no complex read/write patterns)
- Avoiding RwLock overhead (though RwLock overhead is minimal)

**Recommendation**: Use RwLock for Pager to support concurrent reads with better performance

### Interior Mutability Implementation

**Pattern**: Wrap Pager fields in RwLock or Arc<RwLock<Pager>>

**Option 1: RwLock Inside Struct**
```rust
pub struct Pager {
    storage: RwLock<Storage>,
    page_size: u16,
    current_meta: RwLock<MetaState>,
    page_allocator: RwLock<Option<PageAllocator>>,
    cache: RwLock<Option<Box<PageCache>>>,
}
```

**Option 2: Entire Pager Behind RwLock**
```rust
pub type Pager = Arc<RwLock<PagerInternal>>;

pub struct PagerInternal {
    storage: Storage,
    page_size: u16,
    current_meta: MetaState,
    page_allocator: Option<PageAllocator>,
    cache: Option<Box<PageCache>>,
}
```

**Recommendation**: Option 2 (entire Pager behind Arc<RwLock<>>)
- Simpler locking semantics (one lock for entire Pager)
- Easier to reason about (no lock ordering issues)
- Shared ownership via Arc for multiple references
- Consistent with Rust database patterns

### Method Signatures with Interior Mutability

**Read Methods**: Take &self, acquire read lock internally
```rust
impl Pager {
    pub fn get_root_page_id(&self) -> u64 {
        let pager = self.read().unwrap();
        pager.current_meta.root_page_id
    }

    pub fn read_page(&self, page_id: u64, buffer: &mut [u8]) -> Result<(), Error> {
        let mut pager = self.write().unwrap(); // Need write for cache
        pager.read_page_impl(page_id, buffer)
    }
}
```

**Write Methods**: Take &self, acquire write lock internally
```rust
impl Pager {
    pub fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<(), Error> {
        let mut pager = self.write().unwrap();
        pager.write_page_impl(page_id, buffer)
    }

    pub fn allocate_page(&self) -> Result<u64, Error> {
        let mut pager = self.write().unwrap();
        pager.allocate_page_impl()
    }
}
```

### Field-Level Invariants

**storage**: Storage backend
- Always valid after initialization
- File handle remains open for lifetime of Pager
- Memory buffer remains allocated for lifetime of Pager

**page_size**: Immutable configuration
- Set during creation, never changes
- Always power of 2, at least 4096
- Matches meta page page_size field

**current_meta**: Cached meta page state
- Always points to valid meta page (A or B)
- Kept in sync with storage
- Updated on commit or checkpoint

**page_allocator**: Free list management
- null during construction only
- Non-null after full initialization
- Free list sorted and contains only free pages

**cache**: Page caching layer
- null during construction only
- Non-null after full initialization
- Cache entries match storage
- Pinned pages cannot be evicted

## Rust Implementation Guidance

### Type Definition

**Recommended**: Use Arc<RwLock<PagerInternal>> for shared mutable state
```rust
use std::sync::{Arc, RwLock};

pub type Pager = Arc<RwLock<PagerInternal>>;

pub struct PagerInternal {
    storage: Storage,
    page_size: u16,
    current_meta: MetaState,
    page_allocator: Option<PageAllocator>,
    cache: Option<Box<PageCache>>,
}
```

**Rationale**:
- Arc enables shared ownership across threads
- RwLock allows concurrent reads with exclusive writes
- Type alias simplifies API (users see Pager, not Arc<RwLock<PagerInternal>>)

### Mutex vs RwLock Decision

**Use RwLock**: Recommended for Pager

**Reasons to prefer RwLock**:
- Read-heavy workload (typical for databases)
- Multiple concurrent readers improve performance
- Writers are relatively rare
- No additional complexity over Mutex

**When to use Mutex instead**:
- Single-threaded only (no concurrency needed)
- Very simple locking requirements
- Avoiding RwLock overhead (though minimal)

**Recommendation**: Start with RwLock, can switch to Mutex if profiling shows RwLock overhead is significant

### Interior Mutability Accessors

**Reading without modification**: Use read()
```rust
pub fn get_root_page_id(&self) -> u64 {
    let pager = self.read().unwrap();
    pager.current_meta.root_page_id
}
```

**Reading with possible modification**: Use write()
```rust
pub fn read_page_cached(&self, page_id: u64) -> Result<&[u8], Error> {
    let mut pager = self.write().unwrap();
    pager.read_page_cached_impl(page_id)
}
```

**Modification**: Use write()
```rust
pub fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<(), Error> {
    let mut pager = self.write().unwrap();
    pager.write_page_impl(page_id, buffer)
}
```

### Helper Struct Definitions

**MetaState**: Plain struct with public fields
```rust
pub struct MetaState {
    pub page_id: u64,
    pub header: PageHeader,
    pub meta: MetaPayload,
}
```

**PageAllocator**: Struct with Pager reference
```rust
pub struct PageAllocator {
    pager: Weak<RwLock<PagerInternal>>, // Weak to avoid cycle
    free_pages: Vec<u64>,
    last_allocated_page: u64,
}
```

**PageCache**: Opaque implementation detail
```rust
pub struct PageCache {
    // Internal fields private
    entries: HashMap<u64, Vec<u8>>,
    lru_list: VecDeque<u64>,
    pin_counts: HashMap<u64, usize>,
    capacity_bytes: usize,
    current_bytes: usize,
}
```

**Storage**: Enum for file vs memory
```rust
pub enum Storage {
    File(std::fs::File),
    Memory(MemoryStorage),
}
```

### Testing Strategy

**Unit tests needed for**:
- All fields initialized correctly on create
- All fields initialized correctly on open
- Invariants maintained through all operations
- RwLock provides correct concurrent access
- Weak reference in PageAllocator doesn't cause cycles

**Property tests for**:
- Page ID never exceeds last_allocated_page
- Free list is always sorted
- current_meta is always valid
- Cache size never exceeds capacity

**Integration tests for**:
- Multiple concurrent readers don't block
- Writers wait for readers to finish
- Readers wait for writer to finish
- No deadlocks under concurrent access