# Pager Overview

## Purpose

The Pager is the fundamental storage abstraction layer in NorthstarDB, responsible for managing page-based I/O, page allocation, caching, and file handle management. It sits between the higher-level database operations (B+tree, transactions) and the raw storage layer (files or memory), providing a consistent interface for reading and writing fixed-size pages. The Pager ensures data integrity through checksum validation, manages free space for efficient reuse, and provides caching to reduce I/O overhead.

## Responsibilities

### Page I/O Management

**Read Operations**: Retrieve pages from storage with validation
- Read complete pages from file or memory
- Validate page checksums before returning data
- Check magic numbers and format versions
- Return errors for corrupted or invalid pages

**Write Operations**: Persist pages to storage with integrity
- Write complete pages to file or memory
- Calculate and embed checksums before writing
- Ensure atomic page writes (no partial page corruption)
- Track dirty pages for write-back optimization

**Cached Access**: Provide zero-copy cached reads when possible
- Check page cache before disk reads
- Pin pages in cache during use
- Unpin pages when caller is done
- Manage cache eviction when full

### Page Allocation

**Allocate New Pages**: Extend the database file with fresh pages
- Check free list for reusable pages first
- Extend file if no free pages available
- Return unique page ID for allocated page
- Initialize page contents to zeros

**Free Pages**: Mark pages as available for future reuse
- Add freed page IDs to free list
- Prevent freeing of reserved pages (meta pages)
- Track free pages for efficient allocation
- Support free list persistence and recovery

**Free List Management**: Maintain list of available page IDs
- Rebuild free list on database open by scanning B+tree
- Track free pages in sorted order for efficient allocation
- Persist free list information in meta pages
- Validate free list integrity

### Metadata Management

**Meta Page Handling**: Manage dual meta pages for atomic updates
- Maintain two meta pages (META_A_PAGE_ID and META_B_PAGE_ID)
- Read both on open and choose the valid one with higher transaction ID
- Write to the inactive meta page then atomically switch
- Detect torn writes and corruption

**Database State**: Track current database state from meta pages
- Committed transaction ID (highest committed transaction)
- Root page ID (B+tree root location)
- Free list head page ID (start of free page chain)
- Log tail LSN (WAL position for recovery)

### State Tracking

**Current Meta State**: Cache active meta page information
- Store decoded meta payload for fast access
- Provide accessor methods for metadata fields
- Update meta state on commit or checkpoint

**Page Size**: Track fixed page size for database
- Usually 16KB (16384 bytes)
- Must be power of 2
- Used for I/O size calculations and buffer sizing

## Public Functions

### Database Lifecycle

**create(path: &[u8], allocator: Allocator) -> Result<Pager, Error>**
- **Purpose**: Create a new empty database file or in-memory database
- **Parameters**:
  - path: Filesystem path or ":memory:" for in-memory database
  - allocator: Memory allocator for internal allocations
- **Returns**: Initialized Pager instance
- **Behavior**:
  - For files: Creates new file, initializes both meta pages with empty state
  - For in-memory: Creates memory storage with same initialization
  - Initializes page allocator and page cache
  - Writes initial meta pages with transaction ID 0 and empty B+tree
- **Error Conditions**: File creation failure, allocation failure

**open(path: &[u8], allocator: Allocator) -> Result<Pager, Error>**
- **Purpose**: Open existing database file with recovery
- **Parameters**:
  - path: Filesystem path or ":memory:" (creates new database for in-memory)
  - allocator: Memory allocator for internal allocations
- **Returns**: Initialized Pager instance
- **Behavior**:
  - For files: Opens existing file, reads both meta pages
  - Chooses valid meta page with highest committed_txn_id
  - Detects torn writes and corruption
  - Rebuilds free list by scanning B+tree
  - Initializes page allocator and page cache
  - For in-memory: Creates new empty database (no persistence)
- **Error Conditions**:
  - File does not exist or cannot be opened
  - Both meta pages are corrupt or invalid
  - File size is too small (less than one page)
  - Page size mismatch (unsupported format)

**close(&mut self)**
- **Purpose**: Close database and release resources
- **Behavior**:
  - Flushes any pending writes
  - Closes file handle or releases memory storage
  - Deinitializes page allocator
  - Deinitializes page cache
  - Frees allocator memory
- **Note**: Pager is unusable after close

### Page I/O

**read_page(&self, page_id: u64, buffer: &mut [u8]) -> Result<(), Error>**
- **Purpose**: Read a page from storage into buffer
- **Parameters**:
  - page_id: Page identifier to read
  - buffer: Destination buffer (must be at least page_size bytes)
- **Returns**: Empty tuple on success
- **Behavior**:
  - Validates buffer size is at least page_size
  - Reads page from file or memory at calculated offset
  - Validates page header checksum
  - Validates page payload checksum
  - Returns error if checksums don't match
  - Returns error if page_id is out of bounds
- **Error Conditions**:
  - Buffer too small
  - I/O error reading from storage
  - Page checksum mismatch (corruption)
  - Page ID out of bounds

**write_page(&mut self, page_id: u64, buffer: &[u8]) -> Result<(), Error>**
- **Purpose**: Write a page from buffer to storage
- **Parameters**:
  - page_id: Page identifier to write
  - buffer: Source buffer (must be exactly page_size bytes)
- **Returns**: Empty tuple on success
- **Behavior**:
  - Validates buffer size is exactly page_size
  - Writes page to file or memory at calculated offset
  - Checksums must already be calculated and embedded
  - Does not automatically sync (caller controls durability)
  - Returns error if page_id is out of bounds
- **Error Conditions**:
  - Buffer size mismatch
  - I/O error writing to storage
  - Page ID out of bounds

**read_page_cached(&mut self, page_id: u64) -> Result<&[u8], Error>**
- **Purpose**: Read page with caching, returning borrowed reference
- **Parameters**:
  - page_id: Page identifier to read
- **Returns**: Borrowed slice reference to page data (pinned in cache)
- **Behavior**:
  - Check page cache first
  - If cache hit, return cached data
  - If cache miss, read from storage and populate cache
  - Pin page in cache to prevent eviction
  - Caller must call unpin_page when done
- **Error Conditions**:
  - Cache allocation failure
  - I/O error reading from storage
  - Page checksum mismatch

**unpin_page(&mut self, page_id: u64)**
- **Purpose**: Release pinned page from cache
- **Parameters**:
  - page_id: Page identifier to unpin
- **Behavior**:
  - Decrements pin count for page in cache
  - Page becomes eligible for eviction when pin count reaches zero
  - No-op if page is not pinned

### Page Allocation

**allocate_page(&mut self) -> Result<u64, Error>**
- **Purpose**: Allocate a new page from free list or file extension
- **Returns**: Newly allocated page ID
- **Behavior**:
  - Check free list for available pages
  - If free list has pages, take the lowest ID
  - If free list is empty, extend file by one page
  - Initialize new page with zeros
  - Return page ID to caller
- **Error Conditions**:
  - File extension failure
  - Maximum file size exceeded (platform limit)
  - Page allocator not initialized

**free_page(&mut self, page_id: u64) -> Result<(), Error>**
- **Purpose**: Free a page, adding it to the free list for reuse
- **Parameters**:
  - page_id: Page identifier to free
- **Behavior**:
  - Validate page_id is not a meta page (0 or 1)
  - Add page_id to free list in sorted order
  - Page contents are not immediately overwritten
  - Page may be reused by future allocate_page call
- **Error Conditions**:
  - Attempting to free meta pages (0 or 1)
  - Page allocator not initialized

### Metadata Accessors

**get_root_page_id(&self) -> u64**
- **Purpose**: Get the root page ID of the B+tree
- **Returns**: Current root page ID (0 if empty tree)
- **Behavior**: Reads from cached meta state, no I/O

**get_committed_txn_id(&self) -> u64**
- **Purpose**: Get the highest committed transaction ID
- **Returns**: Committed transaction ID from meta page
- **Behavior**: Reads from cached meta state, no I/O

**get_freelist_head_page_id(&self) -> u64**
- **Purpose**: Get the head of the free list page chain
- **Returns**: Page ID of first free list page (0 if none)
- **Behavior**: Reads from cached meta state, no I/O

**get_log_tail_lsn(&self) -> u64**
- **Purpose**: Get the log tail LSN (WAL position)
- **Returns**: LSN of the oldest WAL record needed
- **Behavior**: Reads from cached meta state, no I/O

## Invariants Maintained by Pager

### Page Integrity

**Valid Page Headers**: All pages in storage have valid headers
- Magic number matches PAGE_MAGIC (0x4E534442)
- Format version is supported (0 for current format)
- Header checksum is valid
- Payload checksum is valid
- Payload length does not exceed maximum

**Page Size Consistency**: All pages have the same size
- Page size is fixed at database creation
- Read and write operations enforce page size
- Buffer sizes are validated to match page size

**Page ID Uniqueness**: Each allocated page has a unique ID
- No two active pages share the same ID
- Freed page IDs may be reused after reallocation
- Page IDs are within valid range (0 to file_size / page_size - 1)

### Metadata Consistency

**Valid Meta Pages**: At least one meta page is valid
- On open, at least one meta page passes validation
- If both are valid, the one with higher committed_txn_id is active
- Torn writes are detected and rejected
- Corrupted meta pages are identified and rejected

**Meta State Synchronization**: Cached meta state matches storage
- current_meta reflects the active meta page
- Updates to meta state are persisted to both meta pages
- Meta page switch is atomic (write new page, then update pointer)

**Free List Integrity**: Free list contains only truly free pages
- Freed pages are not referenced by the B+tree
- Free list is rebuilt on open by scanning B+tree structure
- No page appears twice in free list
- Meta pages (0 and 1) are never in free list

### Resource Management

**File Handle Ownership**: Pager owns the file handle
- File is opened on create or open
- File is closed on pager close
- File is not accessible after close
- Concurrent access requires external synchronization

**Cache Coherence**: Cached pages match storage
- Dirty pages are written before eviction
- Read operations always see latest data
- Write operations update cache and storage
- Cache is consistent with file state

**Allocator Boundaries**: Page IDs are within valid range
- Allocated page IDs are less than total pages in file
- Read operations reject page IDs beyond file size
- Write operations extend file if necessary

### Crash Safety

**Atomic Page Writes**: Page writes are atomic (all or nothing)
- Either entire page is written or nothing is written
- Torn writes are detected by checksum validation
- Partial page writes are rejected on recovery

**Meta Page Atomicity**: Meta page updates use two-phase commit
- Write to inactive meta page first
- Validate write succeeded
- Active meta page is determined by highest committed_txn_id
- Torn writes result in choosing the other meta page

## Module Structure

### Rust Module Organization

**northstar_core::pager**: Top-level pager module
- **pager::pager**: Main Pager struct and lifecycle functions
- **pager::allocator**: PageAllocator for free list management
- **pager::cache**: PageCache for buffered I/O
- **pager::meta**: MetaPayload and meta page handling
- **pager::storage**: Storage abstraction (file vs memory)

**Module Hierarchy**:
```
northstar_core
└── pager
    ├── mod.rs (public exports)
    ├── pager.rs (Pager struct and main API)
    ├── allocator.rs (PageAllocator)
    ├── cache.rs (PageCache)
    ├── meta.rs (MetaPayload, MetaState)
    └── storage.rs (Storage enum, FileStorage, MemoryStorage)
```

### Public API Surface

**Re-exports**: Main pager module re-exports key types
- Pager (main struct)
- PageAllocator (if user-visible)
- PageCache (if user-visible)
- Error types (PagerError, etc.)

**Usage Pattern**: Typical user code
```rust
use northstar_core::pager::Pager;

// Create or open database
let mut pager = Pager::create("data.db", allocator)?;
// or
let mut pager = Pager::open("data.db", allocator)?;

// Use pager
let page_id = pager.allocate_page()?;
pager.write_page(page_id, &page_buffer)?;
pager.read_page(page_id, &mut read_buffer)?;

// Close when done
pager.close();
```

### Dependencies

**Internal Dependencies**:
- page_cache module for caching layer
- Allocator from standard library for memory management
- Error types from error module

**External Dependencies**:
- Standard library file I/O (std::fs::File)
- Standard library path manipulation (std::path::Path)

**Used By**:
- B+tree module for node storage
- Transaction module for persistent page access
- WAL module for log storage
- Higher-level database API