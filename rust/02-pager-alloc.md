# Page Allocation

## Purpose

Page allocation is the mechanism by which NorthstarDB manages storage space, reusing freed pages when available and extending the database file when necessary. The allocator maintains a free list of page IDs that are available for reuse, tracks the highest allocated page ID for file extension, and rebuilds the free list on database open by scanning the B+tree structure. This specification details the allocation algorithm, free list management, thread safety considerations, and recovery semantics.

## Types

### PageAllocator

**Description**: Structure that manages page allocation and free list tracking for a Pager instance

**Fields**:
- **pager**: Reference to parent Pager (for I/O operations)
- **free_pages**: Dynamic array of page IDs available for reuse
- **last_allocated_page**: Highest page ID ever allocated (monotonically increasing)
- **allocator**: Memory allocator for dynamic array operations

**Invariants**:
- free_pages is sorted in ascending order
- free_pages contains no duplicate page IDs
- free_pages contains no reserved page IDs (0 or 1)
- last_allocated_page is greater than or equal to the highest ID in free_pages
- All pages in free_pages are actually free (not referenced by B+tree)

**Lifecycle**:
- Initialized after Pager is created
- Rebuilds free list by scanning B+tree structure
- Deallocated when Pager is closed

## Page Allocation Algorithm

### Fast Path: Reuse Freed Page

**Purpose**: Allocate a page by reusing a previously freed page ID

**Algorithm Steps**:
1. Check if free_pages array has any entries
2. If free_pages is not empty:
   - Remove the first entry (lowest page ID)
   - Return this page ID to caller
3. If free_pages is empty:
   - Fall through to slow path (extend file)

**Rationale**: Reusing freed pages is faster than extending the file
- No I/O required (page already exists)
- Keeps database size compact
- Lower page IDs are preferred (better locality)

**Complexity**: O(1) for removal from front of sorted array

**Return Value**: Page ID that caller can use immediately

### Slow Path: Extend File

**Purpose**: Allocate a page by extending the database file with a new page

**Algorithm Steps**:
1. Take current value of last_allocated_page as the new page ID
2. Increment last_allocated_page by 1 (monotonically increasing)
3. Allocate zeroed buffer of page size bytes
4. Create valid page header:
   - Set magic to PAGE_MAGIC
   - Set page_type to freelist (temporary, caller will overwrite)
   - Set page_id to the allocated page ID
   - Set txn_id to 0 (uninitialized)
   - Set payload_len to 0 (empty page)
   - Calculate and set header checksum
5. Encode header into buffer
6. Write entire buffer to storage:
   - Calculate offset as page_id multiplied by page_size
   - For file storage: Use pwrite to write buffer at offset
   - For memory storage: Write to memory buffer at page ID
7. Return new page ID to caller

**Rationale**: File extension is expensive but necessary when free list is empty
- Appends new page to end of file
- Page is pre-zeroed and initialized with valid header
- File size increases by page_size bytes

**Complexity**: O(1) for the allocation itself, O(1) for the write (system call)

**Error Conditions**:
- I/O error writing to storage
- File system full (cannot extend file)
- Integer overflow on page_id or offset calculation

### Allocation Function

**allocate_page(&mut self) -> Result<u64, Error>**

**Purpose**: Public method to allocate a new page, trying fast path first then slow path

**Behavior**:
- Calls allocator implementation directly
- Returns page ID that caller can use
- Page is ready for immediate use (initialized with valid header)

**Implementation**: Try fast path first, then slow path
- Fast path: Reuse from free list if available
- Slow path: Extend file if free list is empty

## Free List Management

### Free List Structure

**In-Memory Representation**: Dynamic array of 64-bit page IDs

**Properties**:
- Sorted in ascending order (lowest page ID first)
- No duplicate entries (each page appears at most once)
- Variable length (0 to N entries where N is total pages minus used pages)
- Grows and shrinks as pages are freed and allocated

**Allocation Preference**: Lowest page ID allocated first
- Optimizes for spatial locality
- Keeps file more compact
- Better cache behavior

### Free List Insertion

**Purpose**: Add a freed page ID to the free list for future reuse

**Algorithm Steps**:
1. Validate page_id is not a meta page (0 or 1)
   - Meta pages are permanently reserved
   - Attempting to free them is an error
2. Find correct insertion position to maintain sorted order
   - Iterate through free_pages array
   - Find first existing ID greater than page_id
   - Insert page_id at that position
3. If page_id is greater than all existing IDs:
   - Append to end of array
4. Free list remains sorted after insertion

**Rationale**: Maintaining sorted order enables efficient allocation
- Always allocate lowest page ID (good locality)
- Simple binary search for lookups if needed
- Prevents fragmentation of address space

**Complexity**: O(n) for insertion due to linear scan and shift

**Error Conditions**:
- InvalidOperation error: Attempting to free page 0 or 1 (meta pages)

### Free List Rebuild on Open

**Purpose**: Reconstruct free list by determining which pages are not in use

**Trigger**: Called during PageAllocator initialization on database open

**Algorithm Steps**:
1. Determine total number of pages from file size
   - File size divided by page_size equals total_pages
2. Allocate boolean array of size total_pages
   - Each entry represents one page (true = in use, false = free)
3. Mark meta pages as in use
   - Set entry 0 to true (META_A_PAGE_ID)
   - Set entry 1 to true if total_pages greater than 1 (META_B_PAGE_ID)
4. Get root page ID from current meta
   - If root_page_id equals 0, tree is empty (skip traversal)
5. If root_page_id is not 0:
   - Traverse B+tree starting from root
   - Mark every reachable page as in use
   - Use iterative stack-based traversal (avoid recursion)
   - For each internal node page: extract child page IDs, push to stack
   - For each leaf node page: mark as in use
   - Handle corrupt pages gracefully (skip and continue)
6. Build free list from unmarked pages
   - Clear existing free_pages array
   - Set last_allocated_page to total_pages
   - For each page_id from 2 to total_pages-1:
     - If page_in_use[page_id] is false:
       - Add page_id to free_pages array
7. Sort free_pages array in ascending order

**Rationale**: Rebuild-on-open ensures free list is accurate even after crashes
- Free list is not persisted separately
- Always reconstructed from B+tree structure
- Guarantees no freed pages are lost
- Guarantees no in-use pages are marked free

**Complexity**: O(N) where N is total number of pages
- Must scan entire B+tree (all pages)
- Must visit every page ID to determine if free
- Acceptable cost on open (one-time operation)

**Error Handling**:
- Corrupt pages are skipped during traversal
- Partial reads are handled gracefully
- I/O errors during page reads are propagated

### B+Tree Traversal for Rebuild

**Purpose**: Mark all pages reachable from the B+tree root as in use

**Algorithm Steps**:
1. Initialize stack with root page ID
2. While stack is not empty:
   - Pop page_id from stack
   - Skip if page_id is out of bounds or already marked
   - Mark page_in_use[page_id] = true
   - Read page from storage
   - If page is corrupt: skip and continue
   - If page type is btree_internal:
     - Extract child page IDs from internal node
     - Push each child page ID onto stack
   - If page type is btree_leaf:
     - No children to process
   - If page type is freelist or other:
     - No children to process

**Rationale**: Iterative traversal avoids stack overflow
- Recursive traversal could overflow stack for deep trees
- Iterative approach uses heap-allocated stack
- Handles arbitrarily deep B+tree structures

## Thread-Safe Allocation

### Concurrency Challenges

**Shared State**: Multiple threads may attempt to allocate or free pages concurrently

**Race Conditions**:
- Two threads allocating from free list simultaneously
- Two threads freeing pages simultaneously
- Allocation and free operation happening concurrently

**Data Races**:
- Concurrent modification of free_pages array
- Concurrent modification of last_allocated_page counter

### Synchronization Approach

**Recommended: Mutex for Exclusive Access**

**Rationale**: Use Mutex rather than RwLock for PageAllocator
- Both allocation and free modify state
- No read-only operations that benefit from shared access
- Mutex is simpler and sufficient
- Low contention expected (allocations are relatively rare)

**Protected Data**:
- free_pages array (entire array protected)
- last_allocated_page counter (protected)

**Lock Duration**: Hold lock for duration of operation
- Fast path: Lock for entire free page removal
- Slow path: Lock for entire file extension operation
- Free operation: Lock for entire insertion into free list

### Lock Ordering

**Pager-Level Locking**: PageAllocator is protected by Pager's RwLock
- Pager uses Arc<RwLock<PagerInternal>> for overall synchronization
- PageAllocator operations acquire write lock on Pager first
- Then manipulate PageAllocator fields

**Deadlock Prevention**: Establish global lock ordering
1. Always acquire Pager lock before PageAllocator lock
2. Pager lock is outer lock
3. PageAllocator internal lock (if separate) is inner lock
4. Never acquire locks in reverse order

**Implications**:
- PageAllocator methods take &mut self (requires write lock)
- Caller must hold Pager write lock during allocation/free
- No separate locking within PageAllocator needed

### Atomic Operations

**Counter Increment**: last_allocated_page increment can use atomic operation
- Use AtomicU64 for last_allocated_page
- Use fetch_add with ordering Relaxed or Release
- Allows lock-free counter updates

**Array Operations**: free_pages array operations require lock
- No safe lock-free concurrent vector operations
- Use Mutex to protect entire array during modifications

## Deallocation Process

### Free Page Operation

**Purpose**: Mark a page as available for future reuse

**Algorithm Steps**:
1. Validate page_id is not a meta page (0 or 1)
   - Meta pages are permanently reserved
   - Return InvalidOperation error if attempting to free meta page
2. Acquire synchronization lock
3. Find insertion position in free_pages to maintain sorted order
4. Insert page_id at correct position
5. Release synchronization lock

**Side Effects**:
- Page is added to free list (available for future allocation)
- Page contents on disk are not immediately overwritten
- Page will be reused (overwritten) when allocated again

**No Immediate I/O**: Page contents on storage are not modified
- Rationale: Avoids disk write for free operation
- Page will be zeroed when reallocated
- Safe because freed page should not be accessible after transaction commit

**Error Conditions**:
- InvalidOperation: Attempting to free page 0 or 1 (meta pages)

### Freeing Non-Existent Page

**Behavior**: Freeing a page that was never allocated is acceptable
- Free list rebuild will naturally include this page
- No validation that page was previously allocated
- Caller is responsible for only freeing actually allocated pages

**Rationale**: Tracking "allocated" state is complex and unnecessary
- Free list rebuild correctly identifies all free pages
- Simpler to not track allocation status separately

## Crash Recovery of Free List

### Free List Not Persisted

**Design Decision**: Free list is not stored persistently
- Free pages list exists only in memory
- Not written to meta pages or WAL
- Reconstructed from B+tree on every open

**Rationale**: Simplifies crash recovery
- No need to atomically update free list on every free/allocate
- No need to log free list operations in WAL
- Rebuild from B+tree is authoritative and always correct

**Rebuild on Open**: Free list reconstruction is the first step after opening database
- Happens during PageAllocator initialization
- Scans B+tree to find all in-use pages
- Everything else is free

### Crash During Allocation

**Scenario**: System crashes after file extension but before page is used in B+tree

**Detection**: On next open:
- Page is in file (file size reflects extension)
- Page is not reachable from B+tree root
- Rebuild algorithm marks page as free
- Page is available for reuse

**Recovery**: Page becomes part of free list
- No data loss (page was never used)
- Page may be allocated for a different purpose
- No special handling needed

### Crash During Free

**Scenario**: System crashes after page is freed but before rebuild

**Detection**: On next open:
- Freed page may still be referenced in old B+tree state
- Rebuild algorithm scans committed B+tree
- If page is not reachable in committed tree, it is free
- If page is still referenced, it is in use

**Recovery**: Correct state determined automatically
- No explicit free list persistence needed
- B+tree structure is source of truth
- Rebuild correctly identifies free pages

### Crash During B+Tree Update

**Scenario**: System crashes during B+tree modification (before commit)

**Detection**: On next open:
- Meta page has older committed_txn_id
- B+tree reflects state at last commit
- Rebuild scans committed B+tree
- Pages allocated but not committed are marked free
- Lost allocations are recovered (available for reuse)

**Recovery**: Rollback to last committed state
- Uncommitted pages become free
- No partial updates visible
- Atomicity preserved by meta page switching

## Functions

### allocate_page(&mut self) -> Result<u64, Error>

**Purpose**: Allocate a new page, reusing freed pages if available or extending file

**Returns**: Page ID that caller can use immediately

**Algorithm**:
1. Acquire exclusive lock
2. Check if free_pages has entries
3. If yes: Remove and return lowest page ID (fast path)
4. If no: Extend file with new page (slow path)
5. Release lock
6. Return page ID

**Error Conditions**:
- I/O error writing new page to storage
- File system full (cannot extend file)

### free_page(&mut self, page_id: u64) -> Result<(), Error>

**Purpose**: Mark a page as available for future reuse

**Parameters**:
- page_id: Page identifier to free

**Returns**: Empty tuple on success

**Algorithm**:
1. Acquire exclusive lock
2. Validate page_id is not 0 or 1 (meta pages)
3. Find insertion position in free_pages
4. Insert page_id at sorted position
5. Release lock

**Error Conditions**:
- InvalidOperation: Attempting to free meta pages (0 or 1)

### rebuild_freelist(&mut self) -> Result<(), Error>

**Purpose**: Reconstruct free list by scanning B+tree structure

**Algorithm**: Detailed in "Free List Rebuild on Open" section

**Returns**: Empty tuple on success

**Error Conditions**:
- I/O error reading pages during B+tree traversal
- Allocation failure for boolean array or stack

### get_free_page_count(&self) -> usize

**Purpose**: Query number of pages available for reuse

**Returns**: Number of entries in free_pages array

**Note**: Read-only operation, may acquire lock depending on synchronization strategy

### get_last_allocated_page_id(&self) -> u64

**Purpose**: Query the highest page ID ever allocated

**Returns**: last_allocated_page minus 1 (converts count to ID)

**Note**: Read-only operation, may use atomic read depending on synchronization strategy

## Invariants

- **Sorted Order**: free_pages is always sorted in ascending order
- **No Duplicates**: No page ID appears twice in free_pages
- **No Meta Pages**: free_pages never contains page IDs 0 or 1
- **Bounds**: All page IDs in free_pages are less than last_allocated_page
- **Consistency**: Pages in free_pages are not referenced by B+tree
- **Monotonicity**: last_allocated_page only increases, never decreases
- **Rebuild Accuracy**: Free list rebuild correctly identifies all free pages

## Dependencies

- **Uses**: Pager (for I/O operations), B+tree (for traversal)
- **Used by**: Pager (for allocate_page and free_page methods)

## Rust Implementation Guidance

### Module Structure

Page allocator implementation in dedicated module:
- northstar_core::pager::allocator - PageAllocator and related types
- Re-exported from northstar_core::pager module

### Type Definition

**PageAllocator Struct**: Standard Rust struct with fields
```rust
pub struct PageAllocator {
    pager: Weak<RwLock<PagerInternal>>,
    free_pages: Vec<u64>,
    last_allocated_page: AtomicU64,
}
```

**Weak Reference**: Use Weak to break circular reference
- Pager owns PageAllocator
- PageAllocator has Weak reference back to Pager
- Prevents reference cycles that would leak memory

**Atomic Counter**: Use AtomicU64 for last_allocated_page
- Allows lock-free reads and increments
- Still requires lock for free_pages operations
- Reduces contention for counter access

### Synchronization

**Mutex for Free List**: Protect free_pages array with Mutex
```rust
pub struct PageAllocator {
    free_pages: Mutex<Vec<u64>>,
    last_allocated_page: AtomicU64,
    pager: Weak<RwLock<PagerInternal>>,
}
```

**Lock Acquisition**: Acquire locks in consistent order
1. Lock Pager::write() first (outer lock)
2. Lock free_pages Mutex second (inner lock) if needed
3. Always release locks in reverse order

**Atomic Operations**: Use atomic operations for counter
```rust
// Increment counter
let new_id = self.last_allocated_page.fetch_add(1, Ordering::AcqRel);

// Read counter
let max_id = self.last_allocated_page.load(Ordering::Acquire);
```

### Allocation Implementation

**Fast Path**: Reuse from free list
```rust
fn allocate_page_impl(&self) -> Result<u64, Error> {
    let mut free_pages = self.free_pages.lock().unwrap();
    if !free_pages.is_empty() {
        Ok(free_pages.remove(0))
    } else {
        // Fall through to slow path
        self.extend_file()
    }
}
```

**Slow Path**: Extend file
```rust
fn extend_file(&self) -> Result<u64, Error> {
    let new_id = self.last_allocated_page.fetch_add(1, Ordering::AcqRel);

    // Initialize and write page
    let pager = self.pager.upgrade().ok_or(Error::PagerDropped)?;
    let pager = pager.read().unwrap();

    let mut buffer = vec![0u8; PAGE_SIZE];
    // Initialize page header...

    pager.write_page_impl(new_id, &buffer)?;
    Ok(new_id)
}
```

### Free Implementation

**Insert Sorted**: Maintain sorted order on insertion
```rust
fn free_page_impl(&self, page_id: u64) -> Result<(), Error> {
    if page_id < 2 {
        return Err(Error::InvalidOperation);
    }

    let mut free_pages = self.free_pages.lock().unwrap();

    // Find insertion position
    let pos = free_pages
        .iter()
        .position(|&id| id > page_id)
        .unwrap_or(free_pages.len());

    free_pages.insert(pos, page_id);
    Ok(())
}
```

### Rebuild Implementation

**B+Tree Traversal**: Use iterative stack-based approach
- Avoid recursion (prevent stack overflow)
- Handle corrupt pages gracefully
- Mark all reachable pages

**Array Allocation**: Use boolean array for page tracking
- Fixed size based on total pages
- True if page in use, false if free
- Efficient for marking and scanning

### Testing Strategy

**Unit tests needed for**:
- Allocation returns sequential IDs when free list is empty
- Allocation reuses lowest ID from free list
- Free page is added to free list in sorted position
- Freeing meta pages returns InvalidOperation error
- Rebuild correctly identifies all free pages
- Rebuild handles empty B+tree (root_page_id = 0)

**Property tests for**:
- Allocated page IDs are monotonic (never decrease)
- Free list is always sorted after any operation
- No duplicate page IDs in free list
- Rebuild produces same free list as manual tracking

**Integration tests for**:
- Allocation and free operations under concurrent access
- Crash recovery with partial B+tree updates
- File extension successfully increases database size
- Free list rebuild after crash recovers all free pages