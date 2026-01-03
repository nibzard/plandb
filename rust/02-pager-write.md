# Pager Write Operation

## Purpose

The Pager write operation is responsible for writing modified pages to storage with validation, checksum recalculation, and cache invalidation. This specification details the write flow, dirty page tracking via copy-on-write, cache invalidation strategy, and coordination with commit synchronization for durability. The write operation ensures data integrity through validation and checksum updates while maintaining consistency between in-memory cache and on-disk storage.

## Write Flow

### Step 1: Buffer Size Validation

**Purpose**: Ensure caller-provided buffer contains a complete page

**Validation**:
- Check buffer length is at least page_size bytes
- Return "buffer too small" error if buffer is too small

**Rationale**: Prevents partial page writes and ensures complete page data is available

**Error Condition**: Buffer length less than page_size (16384 bytes for V0)

### Step 2: Page Structure Validation

**Purpose**: Verify page integrity before writing to storage

**Validation**:
- Parse PageHeader from first 40 bytes of buffer
- Validate page structure using validatePage function
- Validate magic number equals PAGE_MAGIC
- Validate format version is supported
- Validate page type is known value
- Validate header checksum matches calculated value
- Validate payload length fits within page bounds

**Error Detection**:
- InvalidMagic: First 4 bytes don't match PAGE_MAGIC
- InvalidHeaderChecksum: Header checksum doesn't match calculated value
- InvalidPayloadLength: Payload length exceeds maximum possible
- UnexpectedPageType: Page type value is not recognized

**Error Handling**: Return specific error for each validation failure
- Log error details with page_id for debugging
- Return error to caller
- Invalid page is not written to storage

### Step 3: Page ID Consistency Check

**Purpose**: Verify page ID in header matches target page_id parameter

**Validation**:
- Compare page_id field in PageHeader with target page_id parameter
- Return "page ID mismatch" error if they don't match
- Log both values for debugging

**Rationale**: Detects page being written to wrong location (corruption or bug)

**Error Condition**: Header page_id differs from target page_id

### Step 4: Storage Write Operation

**Purpose**: Write page data to storage backend (file or memory)

**File Storage Path**:
- Calculate file offset as page_id multiplied by page_size
- Check for integer overflow (offset should equal product)
- Get current file size from storage
- Validate offset is not beyond file size
- Use pwrite (position-independent write) to write at offset
- Write exactly page_size bytes from buffer
- Return "write beyond file" error if offset exceeds file size

**Memory Storage Path**:
- Write page at page_id to memory buffer
- Write exactly page_size bytes
- Return error if write fails

**Rationale**: pwrite allows writing without changing file position, enabling concurrent writes

**Error Conditions**:
- IntegerOverflow: page_id * page_size calculation overflowed
- WriteBeyondFile: Attempting to write past end of file
- I/O error during write operation

### Step 5: Cache Invalidation

**Purpose**: Remove stale cached copy of page after write

**Invalidation Logic**:
- If page cache exists and contains page_id
- Remove page_id from cache hash map
- Remove page_id from LRU list
- Free page buffer associated with page_id
- If page does not exist in cache, no-op

**Rationale**: Cache must reflect latest written data; stale cached data would cause inconsistency

**Behavior**:
- Unpinned pages are immediately removed
- Pinned pages should not be written (caller error if pinned page is modified)
- Future reads will load fresh data from storage

### Step 6: Return Successfully

**Completion**: All validations passed, page written, cache invalidated

**State**:
- Page data is persisted to storage
- Cache no longer contains stale copy of page
- Checksums in page are valid
- Page ID in header matches target location
- Caller can proceed with next operation

## Dirty Page Tracking

### Copy-On-Write (COW) Mechanism

**Purpose**: Enable MVCC by creating new versions of modified pages

**COW Algorithm**:
1. Read original page from cache or storage
2. Allocate new buffer of page_size bytes
3. Copy entire page content to new buffer
4. Update transaction ID in page header
5. Recalculate header checksum (txn_id changed)
6. Recalculate page checksum with updated header
7. Return new buffer as mutable copy

**Transaction ID Update**:
- Original page has txn_id of previous modifier
- New page receives current transaction's txn_id
- Enables MVCC readers to see consistent snapshots
- Old page remains readable until unpinned

**Checksum Recalculation**:
- Header checksum recalculated because txn_id field changed
- Page checksum recalculated with updated header bytes
- Ensures new page version passes validation

**Usage Pattern**:
- Caller calls copyOnWritePage before modifying page
- Caller modifies new buffer in-place
- Caller calls writePage to persist new version
- Original page remains unchanged in storage until new version written

### Write Path Integration

**Put Operation Flow**:
1. Read page containing target key
2. Call copyOnWritePage to create mutable copy
3. Insert or update key-value pair in copy
4. Recalculate page checksum (data changed)
5. Call writePage to persist new version
6. Cache automatically invalidated

**Delete Operation Flow**:
1. Read page containing target key
2. Call copyOnWritePage to create mutable copy
3. Remove key-value pair from copy
4. Recalculate page checksum (data changed)
5. Call writePage to persist new version
6. Cache automatically invalidated

**Split Operation Flow**:
1. Read full page to split
2. Create two new pages via allocatePage
3. Copy entries to appropriate new page
4. Recalculate checksums for both new pages
5. Call writePage for both new pages
6. Original page may be freed later

### No Explicit Dirty Bit

**Design Choice**: Pages are not explicitly marked dirty

**Rationale**:
- COW ensures new pages are always written
- Original pages are never modified in-place
- Cache invalidation on write prevents stale reads
- Simpler than tracking dirty state

**Implications**:
- No dirty page set or dirty bit field
- No need for write-back tracking
- Every write is immediately reflected in storage
- Cache is either authoritative or empty

## Cache Invalidation Strategy

### Write-Through Cache

**Description**: Cache is a read-through, write-through cache

**Write Behavior**:
- Writes go directly to storage
- Cache entry is invalidated immediately
- No write-back delay
- No dirty pages in cache

**Read Behavior**:
- Reads check cache first
- Cache miss reads from storage
- Cache miss populates cache for future reads

**Advantages**:
- Storage always has latest data
- No risk of lost dirty pages on crash
- Simple consistency model
- No write-back queue to manage

**Disadvantages**:
- Every write triggers storage I/O
- No opportunity for write coalescing
- Higher write latency than write-back cache

### Invalidation Timing

**Immediate Invalidation**: Cache entry removed on writePage call
- Before write returns to caller
- Synchronous with storage write
- No window where cache and storage disagree

**Write Failure Handling**:
- If writePage fails, cache was already invalidated
- Next read will load from storage (which may have old data or fail)
- Caller must retry operation to restore consistent state

**Pinned Pages**:
- Pinned pages should not be written (indicates caller bug)
- If pinned page is written, it is removed from cache
- Future accesses by pin holders will read stale data from removed buffer
- Caller must unpin before modifying page

### Cache Repopulation

**After Invalidation**:
- Page is not in cache
- Next read of page_id will cause cache miss
- Read will populate cache with fresh data from storage
- Cache hit will return immediately thereafter

**Cost**:
- Cache miss requires storage read
- Cache repopulation requires memory allocation
- First read after write has higher latency

## Fsync Coordination

### Commit Synchronization Points

**Purpose**: Ensure durability ordering for two-phase commit

**Commit Ordering**: Log before Meta before Data
1. Append commit record to log file
2. Fsync log file (durable commit record)
3. Write meta page to database file
4. Fsync database file (durable meta update)

**Rationale**: Ensures commit record is recoverable before meta page claims transaction committed

### commitSync Function

**Purpose**: Final synchronization step for commit

**Preconditions**:
- All data pages have been written (via writePage)
- Commit record has been appended to log
- Log file has been fsynced

**Operation**:
- Sync database file to storage
- Ensures meta page write is durable
- May call fsync on file descriptor

**Postconditions**:
- Meta page update is on stable storage
- Transaction is fully committed and durable
- Crash after this point will recover committed transaction

### Sync Function

**Purpose**: Ensure all pending writes are durable

**Operation**:
- Call fsync on underlying file descriptor
- Flushes OS page cache to disk
- Blocks until data is on stable storage

**Use Cases**:
- Final step of commit (commitSync)
- Manual checkpoint operation
- Database close operation

**In-Memory Storage**:
- Sync is no-op for in-memory backend
- No durable storage to flush
- Used primarily for testing

## Functions

### writePage(&mut self, page_id: u64, buffer: &[u8]) -> Result<(), Error>

**Purpose**: Write a page to storage from caller-provided buffer

**Parameters**:
- page_id: Target page identifier to write
- buffer: Source buffer (must be at least page_size bytes)

**Returns**: Empty tuple on success

**Algorithm**: Described in "Write Flow" section

**Error Conditions**:
- BufferTooSmall: Caller buffer is too small
- InvalidMagic, InvalidChecksum: Page is corrupt
- PageIdMismatch: Page ID in header doesn't match target
- IntegerOverflow: Offset calculation overflowed
- WriteBeyondFile: Attempting to write past end of file
- IoError: Storage I/O error

### copyOnWritePage(&self, original_buffer: &[u8], txn_id: u64) -> Result<[u8; PAGE_SIZE], Error>

**Purpose**: Create a mutable copy of a page for COW modification

**Parameters**:
- original_buffer: Original page data to copy
- txn_id: New transaction ID for the copy

**Returns**: New page buffer with updated transaction ID and checksums

**Algorithm**:
1. Allocate new buffer of page_size bytes
2. Copy original_buffer to new buffer
3. Update txn_id field in page header
4. Recalculate header checksum (txn_id changed)
5. Recalculate page checksum with updated header
6. Return new buffer

**Error Conditions**:
- InvalidPage: Original buffer has invalid page structure

### commitSync(&mut self, wal: &Wal) -> Result<(), Error>

**Purpose**: Final synchronization for two-phase commit

**Parameters**:
- wal: Write-ahead log reference (used for documentation, not called)

**Returns**: Empty tuple on success

**Algorithm**:
1. Sync database file to storage
2. Ensure meta page write is durable
3. Return success

**Error Conditions**:
- IoError: fsync failed

### sync(&mut self) -> Result<(), Error>

**Purpose**: Ensure all pending writes are durable

**Returns**: Empty tuple on success

**Algorithm**:
1. Call fsync on underlying file descriptor
2. Block until data is on stable storage
3. Return success

**Error Conditions**:
- IoError: fsync failed

## Invariants

- **Buffer Size**: Caller buffer must be at least page_size bytes
- **Page Validation**: All written pages have valid checksums and structure
- **Page ID Consistency**: Page ID in header matches target page_id
- **Cache Consistency**: Written pages are removed from cache (no stale data)
- **Write Offset**: page_id * page_size must not overflow
- **Write Bounds**: Offset must not exceed file size
- **Commit Ordering**: Log synced before meta page synced
- **COW Isolation**: Original pages are never modified in-place

## Dependencies

- **Uses**: PageCache module for invalidation, Storage for I/O, Checksum module for validation
- **Used by**: B+tree (node writes after splits), Transactions (commit coordination)

## Rust Implementation Guidance

### Module Structure

Write operations integrated into Pager module:
- northstar_core::pager::Pager - Main struct with write methods
- Methods: write_page, copy_on_write_page, commit_sync, sync

### Type Definitions

**Write Error Types**: Specific errors for write operations
```rust
pub enum WriteError {
    BufferTooSmall { provided: usize, required: usize },
    PageIdMismatch { target: u64, header: u64 },
    IntegerOverflow,
    WriteBeyondFile { offset: u64, file_size: u64 },
    InvalidPage(ValidationError),
    Io(std::io::Error),
}
```

### Synchronization

**Write Thread Safety**: writePage requires mutable access or interior mutability

**Recommended**: Use &mut self for write operations
- Single writer prevents concurrent writes
- Rust borrow checker prevents data races
- Consistent with Zig's single-threaded writer model

**Alternative**: RwLock with exclusive write access
```rust
pub struct Pager {
    storage: RwLock<Storage>,
    cache: Option<RwLock<PageCache>>,
    // ...
}

impl Pager {
    pub fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<(), WriteError> {
        let mut storage = self.storage.write().unwrap();
        // Perform write with exclusive access
    }
}
```

### Copy-On-Write Implementation

**Array Return**: Return fixed-size array for page buffer
```rust
impl Pager {
    pub fn copy_on_write_page(
        &self,
        original_buffer: &[u8],
        txn_id: TransactionId,
    ) -> Result<[u8; PAGE_SIZE], WriteError> {
        let mut new_buffer = [0u8; PAGE_SIZE];
        new_buffer.copy_from_slice(original_buffer);

        // Parse and update header
        let mut header = PageHeader::decode(&new_buffer[..PageHeader::SIZE])?;
        header.txn_id = txn_id;

        // Recalculate checksums
        header.header_crc32c = header.calculate_header_checksum();
        header.encode(&mut new_buffer[..PageHeader::SIZE])?;

        let page_data = &new_buffer[..PageHeader::SIZE + header.payload_len as usize];
        header.page_crc32c = calculate_page_checksum(page_data);
        header.encode(&mut new_buffer[..PageHeader::SIZE])?;

        Ok(new_buffer)
    }
}
```

### Cache Invalidation

**Automatic Removal**: Remove from cache on successful write
```rust
impl Pager {
    pub fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<(), WriteError> {
        // ... validation and write logic ...

        // Invalidate cache entry
        if let Some(ref cache) = self.cache {
            cache.write().unwrap().remove(page_id);
        }

        Ok(())
    }
}
```

### Error Handling

**Validation Before Write**: Check page structure before I/O
```rust
impl Pager {
    pub fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<(), WriteError> {
        // Buffer size check
        if buffer.len() < self.page_size {
            return Err(WriteError::BufferTooSmall {
                provided: buffer.len(),
                required: self.page_size,
            });
        }

        // Page structure validation
        let header = PageHeader::decode(&buffer[..PageHeader::SIZE])?;
        header.validate()?;

        // Page ID consistency
        if header.page_id != page_id {
            return Err(WriteError::PageIdMismatch {
                target: page_id,
                header: header.page_id,
            });
        }

        // ... write to storage ...
    }
}
```

### Fsync Implementation

**Direct File Sync**: Use std::fs::File::sync_all or sync_data
```rust
impl Pager {
    pub fn sync(&self) -> Result<(), WriteError> {
        match self.storage.read().unwrap().as_ref() {
            Storage::File(file) => {
                file.sync_all()
                    .map_err(WriteError::Io)?;
            }
            Storage::Memory(_) => {
                // No-op for in-memory storage
            }
        }
        Ok(())
    }
}
```

### Testing Strategy

**Unit tests needed for**:
- WritePage succeeds with valid page buffer
- WritePage rejects buffer too small
- WritePage rejects invalid page structure
- WritePage rejects page ID mismatch
- WritePage invalidates cache entry
- CopyOnWrite creates independent copy
- CopyOnWrite updates transaction ID
- CopyOnWrite recalculates checksums
- Sync calls fsync on file storage
- Sync is no-op on memory storage
- commitSync calls sync

**Property tests for**:
- Written page passes validation on read
- Cache miss after write triggers storage read
- Copy-on-write buffer is independent from original
- Checksums change after COW (txn_id changed)

**Integration tests for**:
- Write followed by read returns same data
- Multiple writes to same page persist latest version
- Write failure does not corrupt cache
- Commit ordering ensures log before meta
- Crash recovery after commit sees committed data
