# Pager Free List

## Purpose

The Pager free list tracks unused pages in the database file for reuse during page allocation. The free list enables space reclamation when pages are freed (due to B+tree node merging or deletion operations), reduces file growth by recycling freed pages, and ensures efficient space utilization. This specification details the free list structure and persistence, free page tracking, crash recovery behavior, and the rebuild-on-open policy used in the current implementation.

## Free List Structure and Persistence

### FreelistPayload Structure

**Description**: On-disk format for free list page payload

**Fields**:
- **freelist_magic**: u32 (4 bytes) - Magic number identifying free list pages (0x46524545 = "FREE")
- **next_page_id**: u64 (8 bytes) - Page ID of next freelist page (0 if last in chain)
- **free_count**: u32 (4 bytes) - Number of free page IDs stored in this page
- **reserved**: [u8; 32] (32 bytes) - Reserved for future use
- **free_page_ids**: Variable length array of u64 values - Free page IDs (free_count entries)

**Total Size**: 48 bytes + (free_count * 8 bytes)

**Maximum Entries per Page**:
- Page size: 16384 bytes (default)
- PageHeader: 40 bytes
- FreelistPayload header: 48 bytes
- Available for page IDs: 16384 - 40 - 48 = 16296 bytes
- Maximum free_count: 16296 / 8 = 2036 page IDs

**Invariants**:
- freelist_magic must equal 0x46524545
- free_count must not exceed MAX_FREE_PER_PAGE (2036)
- Page IDs in free_page_ids must be valid (less than file size)
- Page IDs must be unique (no duplicates)

### Linked List Structure

**Chaining**: Multiple freelist pages linked via next_page_id

**Structure**:
- Meta page contains freelist_head_page_id (points to first freelist page)
- Each freelist page contains next_page_id pointing to next freelist page
- Last freelist page has next_page_id = 0
- Forms singly-linked list of free list pages

**Traversal**: Start at freelist_head_page_id, follow next_page_id until 0

**Capacity**: Scalable to large numbers of freed pages
- Each freelist page holds ~2000 free page IDs
- 100 freelist pages = 200,000 free pages
- Sufficient for most databases

### Persistence Behavior

**Current Design**: Free list NOT persisted to disk (rebuild-on-open)

**Rationale**:
- Simplifies implementation (no free list write logic)
- Avoids free list corruption on crash
- Free list rebuilt on every open from B+tree traversal
- Acceptable cost for embedded database use case

**Implications**:
- FreelistPayload structure defined but NOT used in V0
- freelist_head_page_id in meta page always 0
- Free pages tracked only in memory
- Crash recovery rebuilds free list automatically

**Future Enhancement**: Could persist free list for faster opens
- Write free list pages during database close
- Read free list pages during database open
- Requires free list validation and corruption recovery

## Free Page Tracking

### In-Memory Free List

**Data Structure**: Sorted array (ArrayList) of page IDs

**Representation**:
- free_pages: ArrayList<u64> - Dynamic array of free page IDs
- Maintained in sorted order (ascending)
- No duplicates (each page appears at most once)

**Sorting**: Ascending order by page ID
- Lowest page ID at index 0
- Highest page ID at last index
- Enables efficient allocation of lowest available ID

**Allocation Order**: Prefer lowest page ID first
- Extends file lifetime (reuses old pages)
- Reduces file fragmentation
- Maintains locality (old pages near start of file)

### Add to Free List

**Trigger**: Page freed during B+tree operation (merge, delete)

**Algorithm**:
1. Validate page_id is not a meta page (0 or 1)
2. Check if page_id already in free list (duplicate check)
3. Insert page_id at appropriate position to maintain sorted order
4. Return success

**Insertion Logic**:
- Iterate through existing free page IDs
- Find first ID greater than page_id
- Insert page_id before that ID (maintains sort order)
- If page_id greater than all existing IDs, append to end

**Complexity**: O(n) where n is number of free pages
- Linear search for insertion point
- Array insertion may shift elements
- Acceptable for moderate free list sizes

**Error Conditions**:
- InvalidOperation: Attempting to free meta page (ID 0 or 1)

### Allocate from Free List

**Trigger**: Page allocation requested (allocatePage)

**Algorithm**:
1. Check if free_pages has any entries
2. If empty: return error (caller must extend file)
3. Remove first entry (lowest page ID)
4. Return removed page ID to caller

**Removal Logic**:
- orderedRemove(0) removes and returns first element
- Shifts remaining elements down
- Maintains sorted order

**Complexity**: O(n) due to element shifting
- All elements after index 0 shifted down
- Acceptable for moderate free list sizes

### Free List Reconstruction

**Rebuild-on-Open Policy**: Free list rebuilt on every database open

**Algorithm**:
1. Get total pages in file (file_size / page_size)
2. Allocate boolean array marking page usage (one entry per page)
3. Mark all pages as potentially free (false)
4. Mark meta pages as in use (pages 0 and 1)
5. If root page exists: traverse B+tree from root
6. Mark all pages reachable from root as in use (true)
7. Build free_pages array from pages marked false
8. Sort free_pages array

**B+Tree Traversal**: Marks all reachable pages
- Start at root page ID
- Recursively visit child pages
- Mark all visited pages as in use
- Handles internal and leaf nodes
- Freelist pages are not traversed (not part of tree)

**Pages Considered Free**:
- Not reachable from root via B+tree links
- Not meta pages (0 and 1)
- Within file bounds (0 to total_pages - 1)

**Pages Considered In Use**:
- Meta pages (always)
- B+tree internal nodes reachable from root
- B+tree leaf nodes reachable from root
- Any page linked from tree nodes

**Complexity**: O(n) where n is total pages in file
- Must potentially examine every page
- Tree traversal visits each reachable page once
- Boolean array scan builds free list

**Cost**: Acceptable for embedded database
- Databases typically thousands to millions of pages
- Traversal happens once on open
- Subsequent allocations use in-memory free list

## Crash Recovery of Free List

### Free List Loss on Crash

**No Persistence**: Free list NOT written to disk

**Crash Behavior**:
- Free list exists only in memory while database open
- Crash or close loses free list
- Next open rebuilds free list from scratch
- No corruption of free list possible (always rebuilt)

**Implications**:
- Freed pages remain allocated in file until next open
- File size may not shrink immediately after frees
- Space reclaimed after rebuild and subsequent allocations
- No explicit free list corruption recovery needed

### Recovery Process

**Database Open**: Rebuild free list before operations

**Steps**:
1. Open database file and read meta pages
2. Determine committed root page ID
3. Call rebuildFreelist() to reconstruct free list
4. Page allocator now ready for allocations

**Consistency**: Free list always consistent with committed state
- Rebuilt from committed B+tree
- Uncommitted changes lost anyway
- No partial free list state possible

**No WAL Replay**: Free list not involved in recovery
- B+tree pages reconstructed from meta page
- Free list derived from tree traversal
- No separate free list WAL records

## Free List Type Definition

### FreelistPayload (On-Disk Format)

**Purpose**: Structure for free list pages (defined but unused in V0)

**Rust Definition**:
```rust
#[repr(C)]
pub struct FreelistPayload {
    pub freelist_magic: u32,      // 0x46524545 ("FREE")
    pub next_page_id: u64,         // Next freelist page or 0
    pub free_count: u32,           // Number of free page IDs
    pub reserved: [u8; 32],        // Reserved for future use
    // Followed by free_count * u64 page IDs
}
```

**Constants**:
- SIZE: 48 bytes (size of fixed fields)
- MAX_FREE_PER_PAGE: 2036 (for 16KB pages)

**Validation**:
- freelist_magic == 0x46524545
- free_count <= MAX_FREE_PER_PAGE

### PageAllocator (In-Memory)

**Purpose**: Manages free list and page allocation

**Rust Definition**:
```rust
pub struct PageAllocator {
    pager: &'a Pager,
    free_pages: Vec<u64>,          // Sorted list of free page IDs
    last_allocated_page: u64,      // Highest page ever allocated
}
```

**Invariants**:
- free_pages is sorted in ascending order
- No duplicate page IDs in free_pages
- No meta page IDs (0 or 1) in free_pages
- All page IDs < file size

## Functions

### allocatePage(&mut self) -> Result<u64, Error>

**Purpose**: Allocate a page from free list or extend file

**Returns**: Allocated page ID

**Algorithm**:
1. Check if free_pages has entries
2. If yes: remove and return first (lowest) page ID
3. If no: extend file and return new page ID
4. Update last_allocated_page

**Error Conditions**: None (always succeeds)

### freePage(&mut self, page_id: u64) -> Result<(), Error>

**Purpose**: Add page to free list for reuse

**Algorithm**:
1. Validate page_id is not meta page (0 or 1)
2. Insert page_id into free_pages in sorted order
3. Return success

**Error Conditions**:
- InvalidOperation: Attempting to free meta page

### rebuildFreelist(&mut self) -> Result<(), Error>

**Purpose**: Reconstruct free list by traversing B+tree

**Algorithm**:
1. Get total pages in file
2. Allocate boolean array for page usage
3. Mark all pages as free initially
4. Mark meta pages as in use
5. Traverse B+tree from root
6. Mark reachable pages as in use
7. Build free_pages from pages marked free
8. Sort free_pages

**Error Conditions**: None (rebuild always succeeds)

### getFreePageCount(&self) -> usize

**Purpose**: Get number of free pages available

**Returns**: Length of free_pages array

### getLastAllocatedPageId(&self) -> u64

**Purpose**: Get highest page ID ever allocated

**Returns**: last_allocated_page - 1 (highest allocated page)

## Invariants

- **Sorted Order**: free_pages array maintained in ascending order
- **No Duplicates**: Each page appears at most once in free_pages
- **No Meta Pages**: Meta pages (0 and 1) never in free_pages
- **Valid Page IDs**: All page IDs in free_pages < file size
- **Rebuild Consistency**: Free list always rebuilt on open

## Dependencies

- **Uses**: B+tree traversal (to find reachable pages), Storage (file size)
- **Used by**: Pager (page allocation), B+tree (node splitting/merging)

## Rust Implementation Guidance

### Module Structure

Free list integrated into PageAllocator module:
- northstar_core::pager::allocator - PageAllocator and FreelistPayload

### Type Definitions

**FreelistPayload**: On-disk free list page format (defined but unused in V0)
```rust
#[repr(C)]
pub struct FreelistPayload {
    pub freelist_magic: u32,
    pub next_page_id: u64,
    pub free_count: u32,
    pub reserved: [u8; 32],
}

impl FreelistPayload {
    pub const SIZE: usize = 48;

    pub const MAX_FREE_PER_PAGE: usize =
        (DEFAULT_PAGE_SIZE - PageHeader::SIZE - Self::SIZE) / 8;

    pub const FREELIST_MAGIC: u32 = 0x46524545; // "FREE"
}
```

**PageAllocator**: In-memory free list management
```rust
pub struct PageAllocator<'a> {
    pager: &'a Pager,
    free_pages: Vec<u64>,
    last_allocated_page: u64,
}
```

### Free List Operations

**Allocate from Free List**: Use Vec::remove
```rust
impl PageAllocator {
    pub fn allocate_page(&mut self) -> Result<u64, AllocError> {
        if let Some(page_id) = self.free_pages.first() {
            let page_id = *page_id;
            self.free_pages.remove(0);
            Ok(page_id)
        } else {
            // Extend file
            let page_id = self.last_allocated_page;
            self.last_allocated_page += 1;
            Ok(page_id)
        }
    }
}
```

**Free Page**: Insert maintaining sorted order
```rust
impl PageAllocator {
    pub fn free_page(&mut self, page_id: u64) -> Result<(), AllocError> {
        if page_id == META_A_PAGE_ID || page_id == META_B_PAGE_ID {
            return Err(AllocError::InvalidOperation);
        }

        // Find insertion point to maintain sorted order
        let pos = self.free_pages
            .binary_search(&page_id)
            .unwrap_or_else(|pos| pos);

        self.free_pages.insert(pos, page_id);
        Ok(())
    }
}
```

**Note**: binary_search returns Err(pos) where pos is insertion point for new element

### Rebuild Implementation

**B+Tree Traversal**: Recursive marking of reachable pages
```rust
impl PageAllocator {
    fn rebuild_freelist(&mut self) -> Result<(), AllocError> {
        let file_size = self.pager.get_file_size()?;
        let total_pages = file_size / self.pager.page_size() as u64;

        // Mark all pages as potentially free
        let mut page_in_use = vec![false; total_pages as usize];

        // Mark meta pages as in use
        if total_pages > 0 {
            page_in_use[META_A_PAGE_ID as usize] = true;
        }
        if total_pages > 1 {
            page_in_use[META_B_PAGE_ID as usize] = true;
        }

        // Traverse tree and mark reachable pages
        let root_page_id = self.pager.get_root_page_id();
        if root_page_id != 0 {
            self.mark_tree_pages(root_page_id, &mut page_in_use)?;
        }

        // Build free list from unused pages
        self.free_pages.clear();
        for (page_id, &in_use) in page_in_use.iter().enumerate() {
            if !in_use && page_id >= 2 { // Skip meta pages
                self.free_pages.push(page_id as u64);
            }
        }

        // Sort is automatic if we iterate in order
        // No explicit sort needed

        Ok(())
    }
}
```

### Testing Strategy

**Unit tests needed for**:
- allocate_page returns lowest free page ID
- allocate_page extends file when free list empty
- free_page inserts page ID in sorted order
- free_page rejects meta page IDs
- rebuild_freelist correctly identifies free pages
- rebuild_freelist marks all tree pages as in use

**Property tests for**:
- Free list always sorted after operations
- No duplicate page IDs in free list
- Allocated page IDs never repeat until freed
- Rebuilt free list matches manually tracked free pages

**Integration tests for**:
- Allocate, free, allocate cycle reuses freed page
- Rebuild after crash recovers same free list
- Free list growth with many freed pages
