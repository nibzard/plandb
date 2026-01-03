# Pager I/O

## Purpose

The Pager I/O specification details the input/output operations performed by the pager, including position-independent read/write operations, direct versus buffered I/O usage, alignment requirements, and the synchronous I/O design decision. The pager uses explicit I/O operations with pread/pwrite for thread-safe concurrent access, direct file access without OS buffering overhead where appropriate, and synchronous blocking I/O for simplicity and predictability.

## I/O Operations Performed

### Read Operations

**Position-Independent Read (pread)**: Read without changing file position

**Operation**: pread(file, buffer, offset)
- **file**: File descriptor or handle
- **buffer**: Destination buffer (must be at least page_size bytes)
- **offset**: Byte offset in file (page_id * page_size)

**Behavior**:
- Reads exactly page_size bytes from file at offset
- Does not change file position indicator
- Thread-safe: Multiple concurrent reads allowed
- Returns bytes read or error

**Usage Points**:
- readPage: Read single page from storage
- Database open: Read meta pages (offsets 0 and page_size)
- B+tree traversal: Read internal and leaf nodes

**Error Handling**:
- Returns error if offset beyond file size
- Returns error if fewer bytes read than expected
- UnexpectedEOF: Partial read or short read

### Write Operations

**Position-Independent Write (pwrite)**: Write without changing file position

**Operation**: pwrite(file, buffer, offset)
- **file**: File descriptor or handle
- **buffer**: Source buffer (must be at least page_size bytes)
- **offset**: Byte offset in file (page_id * page_size)

**Behavior**:
- Writes exactly page_size bytes to file at offset
- Does not change file position indicator
- Thread-safe: Concurrent writes to different offsets safe
- Returns bytes written or error

**Usage Points**:
- writePage: Write single page to storage
- Page allocation: Write zero page when extending file
- Meta page updates: Write meta pages (offsets 0 and page_size)
- B+tree splits: Write new leaf/internal pages

**Error Handling**:
- Returns error if offset beyond file size (before extension)
- Returns error if write interrupted
- IoError: Underlying OS write failure

### Synchronize Operations

**File Sync (fsync)**: Flush OS buffers to stable storage

**Operation**: fsync(file)
- **file**: File descriptor or handle

**Behavior**:
- Flushes all dirty pages for file to disk
- Blocks until data is on stable storage
- Ensures durability of prior writes

**Usage Points**:
- Transaction commit: Final step of two-phase commit
- commitSync: Explicit sync for durability
- Periodic checkpointing: Optional manual durability point

**Alternatives**:
- fdatasync: Flushes data only, not metadata (faster)
- sync_data: Rust equivalent of fdatasync

## Direct vs Buffered I/O

### Current Design: Buffered I/O

**OS Page Cache**: File writes go through OS buffer cache

**Behavior**:
- Writes buffered in OS page cache
- Written to disk on explicit fsync or OS policy
- Reads served from OS cache if available

**Advantages**:
- Simple implementation (use standard file I/O)
- OS may optimize sequential access patterns
- Read-ahead caching improves performance
- Write-behind caching reduces I/O operations

**Disadvantages**:
- Double caching with in-memory page cache (redundancy)
- Less predictable I/O latency
- Higher memory usage (OS cache + application cache)
- Data in OS cache may be evicted unpredictably

### Direct I/O (O_DIRECT)

**Alternative**: Bypass OS page cache

**Behavior**:
- Reads/writes go directly to disk
- No OS buffering or caching
- Application manages all caching

**Advantages**:
- Eliminates double caching
- More predictable I/O latency
- Lower memory usage (no OS cache overhead)
- Better control over I/O patterns

**Disadvantages**:
- More complex implementation
- Requires aligned buffers and offsets
- May be slower for sequential access
- Platform-specific (Linux, different on Windows/macOS)

**Current Choice**: Buffered I/O for simplicity
- Acceptable for embedded database workload
- In-memory page cache provides sufficient caching
- Simpler cross-platform compatibility

### Future Consideration: O_DIRECT Optimization

**Potential Optimization**: Use direct I/O for data files

**Requirements**:
- Align buffers to page boundary (typically 4KB)
- Align offsets to page boundary
- Use platform-specific flags (O_DIRECT on Linux)

**Trade-offs**:
- Complexity vs performance gain
- Platform compatibility
- Testing overhead

**Recommendation**: Start with buffered I/O, profile before optimizing

## Alignment Requirements

### Page Alignment

**Natural Alignment**: Pages aligned to page_size boundary

**Offset Calculation**: page_id * page_size
- Always aligned to page_size (16384 bytes for default)
- No partial page reads or writes
- No cross-page operations

**Rationale**:
- Simplifies I/O implementation
- Matches filesystem block size
- Enables efficient direct I/O if needed
- Prevents torn writes at page boundaries

### Buffer Alignment

**Current Design**: No special alignment required

**Buffer Allocation**:
- Allocated with standard allocator (heap allocation)
- No alignment constraints
- Works with buffered I/O

**Direct I/O Requirements** (if used in future):
- Buffer alignment: Typically 512 bytes or 4KB
- Offset alignment: Same as buffer alignment
- May require aligned_alloc or special allocator

**Memory Allocation Strategies**:
- Standard allocator: Current approach, works with buffered I/O
- Aligned allocator: Required for O_DIRECT
- Arena allocator: Alternative for aligned allocations

### Size Requirements

**Fixed Page Size**: All I/O operations use exact page_size bytes

**Read Size**: Exactly page_size bytes (16384 for default)
- No partial page reads
- No short reads accepted

**Write Size**: Exactly page_size bytes (16384 for default)
- No partial page writes
- No short writes accepted

**Validation**: Buffer size checked before I/O
- Buffer must be at least page_size bytes
- Error returned if buffer too small

## Async vs Sync I/O Decision

### Synchronous I/O (Current Design)

**Blocking Operations**: All I/O operations block until complete

**Behavior**:
- read/write calls block thread
- No other operations proceed during I/O
- Simple control flow
- Predictable operation order

**Advantages**:
- Simple implementation (no async/await complexity)
- Easier debugging (linear execution)
- No callback or future handling
- Sufficient for embedded database workload

**Disadvantages**:
- Thread blocked during I/O (cannot do other work)
- Lower throughput with many concurrent operations
- May need thread pool for concurrent I/O

**Current Use Case**: Single-threaded or few-threaded embedded database
- Simplicity valued over maximum throughput
- Predictable latency more important than peak performance
- Most operations are cache hits (no I/O)

### Asynchronous I/O (Future Consideration)

**Non-Blocking Operations**: I/O initiated, completion signaled later

**Approaches**:
- io_uring (Linux): High-performance async I/O
- epoll/kqueue: Event-driven I/O notification
- Async/await: Language-level async operations

**Advantages**:
- Higher throughput with many concurrent operations
- Better resource utilization (no blocked threads)
- Can interleave I/O and computation

**Disadvantages**:
- Much more complex implementation
- Harder debugging (non-linear execution)
- Platform-specific APIs (io_uring Linux-only)
- Overkill for embedded database use case

**Current Decision**: Synchronous I/O sufficient
- Embedded databases typically have low concurrency
- Cache hit rate high (I/O less frequent)
- Complexity not justified for current workload

## Rust Implementation Guidance

### I/O Primitives

**File Operations**: Use std::fs::File

**Read**:
```rust
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

impl FileStorage {
    pub fn read_page(&self, page_id: u64, buffer: &mut [u8]) -> Result<usize, IoError> {
        let offset = page_id * self.page_size as u64;
        self.file.seek(SeekFrom::Start(offset))?;
        self.file.read_exact(buffer)?;
        Ok(buffer.len())
    }
}
```

**Position-Independent Read** (better):
```rust
use std::os::unix::fs::FileExt; // Platform-specific

impl FileStorage {
    pub fn pread(&self, page_id: u64, buffer: &mut [u8]) -> Result<usize, IoError> {
        let offset = page_id * self.page_size as u64;
        self.file.read_at(buffer, offset)
    }
}
```

**Write**:
```rust
use std::os::unix::fs::FileExt;

impl FileStorage {
    pub fn pwrite(&self, page_id: u64, buffer: &[u8]) -> Result<usize, IoError> {
        let offset = page_id * self.page_size as u64;
        self.file.write_at(buffer, offset)
    }
}
```

**Sync**:
```rust
impl FileStorage {
    pub fn sync(&self) -> Result<(), IoError> {
        self.file.sync_all()  // sync_all: data + metadata
        // Alternative: sync_data() for data only (faster)
    }
}
```

### Platform-Specific Extensions

**Unix (Linux, macOS)**:
- Use std::os::unix::fs::FileExt for pread/pwrite
- O_DIRECT available but not used in V0
- fsync maps to sync_all, fdatasync maps to sync_data

**Windows**:
- Use std::os::windows::fs::FileExt for different API
- Different async I/O model (IOCP)
- Buffered I/O similar behavior

**Cross-Platform**: Use conditional compilation
```rust
#[cfg(unix)]
use std::os::unix::fs::FileExt;

#[cfg(windows)]
use std::os::windows::fs::FileExt;
```

### Error Handling

**I/O Errors**: Map to application error types
```rust
#[derive(Debug, thiserror::Error)]
pub enum IoError {
    #[error("Read error: {0}")]
    Read(#[from] std::io::Error),

    #[error("Unexpected EOF: read {0} bytes, expected {1}")]
    UnexpectedEof { got: usize, expected: usize },

    #[error("Write beyond file size: offset {offset}, size {size}")]
    WriteBeyondFile { offset: u64, size: u64 },
}
```

### Testing Strategy

**Unit tests needed for**:
- pread reads correct page at correct offset
- pwrite writes to correct offset
- Read returns error for offset beyond file
- Write returns error for offset beyond file
- Sync flushes data to disk

**Property tests for**:
- Round-trip read/write preserves data
- Concurrent reads don't interfere
- Page offset calculation correct

**Integration tests for**:
- Database open reads meta pages correctly
- Page allocation extends file correctly
- Write/read cycle preserves page data
- Sync ensures durability
