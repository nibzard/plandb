# Pager Close Operation

## Purpose

The Pager close operation is responsible for clean resource deallocation and graceful shutdown of the pager. This specification details the resource release sequence, shutdown handling, cleanup steps, and Drop trait behavior for Rust. The close operation ensures all allocated memory is freed, file descriptors are closed, and no resources are leaked during shutdown.

## Resource Release Sequence

### Step 1: Page Allocator Cleanup

**Purpose**: Deinitialize page allocator and free its memory

**Operation**:
- Check if page_allocator exists
- If exists: call deinit() on page allocator
- Frees free list array and allocator state
- Resets page_allocator field to null state

**Memory Freed**:
- Free page ID array
- Last allocated page counter
- Associated allocator metadata

**Rationale**: Page allocator must be closed before cache and storage (uses them)

**Error Handling**: No errors (deinit is infallible)

### Step 2: Page Cache Cleanup

**Purpose**: Deinitialize page cache and free cached pages

**Operation**:
- Check if cache exists
- If exists: call deinit() on cache
- Frees all cached page buffers
- Frees hash map and LRU list structures
- Destroys cache structure itself
- Resets cache field to null state

**Memory Freed**:
- All cached page buffers (each page_size bytes)
- Hash map entries
- LRU list nodes
- Cache metadata and statistics

**Rationale**: Cache must be closed before storage (may reference pages)

**No Flush Needed**: Write-through cache means no dirty pages to flush

**Error Handling**: No errors (deinit is infallible)

### Step 3: Storage Backend Cleanup

**Purpose**: Close file descriptor or deinitialize memory storage

**File Storage Path**:
- Close underlying file descriptor
- May flush OS buffers (platform-dependent)
- Releases file handle to OS

**Memory Storage Path**:
- Deinitialize memory buffer
- Free all stored page data
- No file descriptor to close

**Rationale**: Storage must be closed last (used by allocator and cache)

**Error Handling**: No errors (close is infallible in Zig, may log warnings)

### Step 4: Pager Structure Deallocated

**Purpose**: Pager structure itself freed by caller

**Operation**:
- Caller allocated Pager (via allocator or stack)
- Caller responsible for freeing Pager structure
- close() only frees internal resources
- Pager memory may be freed after close returns

**Zig Pattern**: close() is called explicitly, then caller frees structure

**Rust Pattern**: Drop trait deallocates structure and calls close logic

## Graceful Shutdown Handling

### No Explicit Sync on Close

**Design Choice**: close() does not call sync()

**Rationale**:
- Last commit already included fsync (via commitSync)
- Write-through cache means no dirty pages to flush
- All data already persisted to storage
- Avoids unnecessary fsync on every close

**Implications**:
- Crash between last commit and close loses no data
- Close is fast (no I/O required)
- Caller responsible for ensuring durability before close

**Best Practice**:
- Commit all transactions before closing
- Last commit's fsync ensures durability
- Close only deallocates resources

### Incomplete Operations

**Active Transactions**: Caller's responsibility
- close() does not abort or commit pending transactions
- Caller should commit or abort before close
- Uncommitted data is lost (transaction isolation)

**Pinned Pages**: Caller's responsibility
- close() does not unpin pages
- Pinned pages become invalid after cache freed
- Caller should unpin all pages before close
- Use after close leads to undefined behavior

**Open Iterators**: Caller's responsibility
- close() does not close iterators
- Iterators hold references to pager
- Caller should drop iterators before close
- Use after close leads to dangling references

### Concurrent Access Safety

**Single-Writer Model**: Zig assumes single writer
- close() should be called when no other operations in progress
- No concurrent reads or writes during close
- Caller ensures exclusive access

**Rust Ownership**: Borrow checker prevents use after close
- close() consumes self or requires &mut self
- No other references can exist during close
- Use after close is compile-time error

## Cleanup Steps in Order

### Dependency Graph

**Cleanup Must Respect Dependencies**:
```
Pager
  ├─> PageAllocator (uses Pager for storage access)
  ├─> PageCache (uses Pager for cache misses)
  └─> Storage (base layer)
```

**Reverse Dependency Order**:
1. PageAllocator (highest level)
2. PageCache (middle level)
3. Storage (base layer)

**Rationale**: Higher levels may reference lower levels

**Violating Order**: Would cause use-after-free or dangling references

### Detailed Cleanup Steps

**Step 1: PageAllocator.deinit()**
- Frees free page list
- Resets last_allocated_page counter
- Clears allocator state

**Step 2: PageCache.deinit()**
- Removes all cache entries
- Frees each cached page buffer
- Frees hash map structure
- Frees LRU list structure
- Destroys cache mutex (if present)

**Step 3: Storage.close()**
- File storage: close file descriptor
- Memory storage: free page buffer
- Release OS resources

**Step 4: Pager Structure (caller responsibility)**
- Zig: caller frees Pager with allocator.destroy()
- Rust: Drop trait deallocates structure

### Memory Safety Guarantees

**No Double Free**: Each resource freed exactly once
- Option fields ensure only non-null resources freed
- deinit methods check for null before freeing

**No Memory Leaks**: All allocated memory freed
- Page allocator: free list array freed
- Page cache: all page buffers freed
- Storage: file descriptor or buffer freed

**No Use After Free**: Caller cannot use pager after close
- Zig: convention, not enforced
- Rust: ownership system enforces

## Drop Trait Behavior

### Ownership Transfer

**Pattern**: close() consumes self in Rust

**Signature**:
```rust
impl Pager {
    pub fn close(self)  // Takes ownership, consumes Pager
    {
        // Cleanup logic
    }
}
```

**Alternative**: Return error but consume self
```rust
impl Pager {
    pub fn close(self) -> Result<(), CloseError>
    {
        // Cleanup logic with error handling
    }
}
```

**No Borrow After Close**: Ownership transfer prevents use
- Caller loses reference to Pager after close
- Any subsequent use is compile-time error
- Prevents use-after-free bugs

### Drop Trait Implementation

**Automatic Cleanup**: Drop trait called when value goes out of scope

**Implementation**:
```rust
impl Drop for Pager {
    fn drop(&mut self) {
        // Cleanup same resources as close()
        // But may not return errors (Drop cannot panic/panic)
    }
}
```

**Panic Safety**: Drop should not panic
- Use catch_unwind or ignore errors
- Cannot return errors to caller
- Best effort cleanup

**Explicit vs Implicit**: Caller can choose
- Explicit close(): explicit control, can handle errors
- Implicit drop(): automatic cleanup, no error handling

**Recommendation**: Provide both
- close() for explicit shutdown with error handling
- Drop for fallback cleanup in case of panic

### Close vs Drop

**close() Method**:
- Explicit call by caller
- Can return Result for error handling
- Consumes self to prevent reuse
- Allows caller to handle cleanup errors

**Drop Trait**:
- Implicit call when value goes out of scope
- Cannot return errors
- Must not panic
- Fallback for early returns or panics

**Best Practice**: Call close() explicitly, rely on Drop as safety net

## Close Operation Errors

### Infallible Close (Zig Design)

**Zig Choice**: close() returns void (cannot fail)

**Rationale**:
- All resources should be cleanable without errors
- File close failures are rare and non-critical
- Page cache and allocator cleanup cannot fail
- Simplifies shutdown logic

**OS Errors**: Ignored or logged
- File descriptor close failure: logged but ignored
- Memory always freed successfully
- No way to recover from close errors anyway

### Fallible Close (Rust Consideration)

**Rust Alternative**: close() could return Result

**Potential Errors**:
- IoError: file sync or close failed
- PoisonError: mutex poisoned during cache cleanup

**Handling Strategies**:
- Ignore and continue (best effort)
- Log error and continue
- Return error to caller (explicit handling)

**Recommendation**: Make close() infallible
- Sync errors should be handled before close
- Use sync() explicitly if needed
- close() only deallocates resources
- Drop trait cannot fail anyway

## Rust Implementation Guidance

### Module Structure

Close operations integrated into Pager module:
- northstar_core::pager::Pager - Main struct with close method
- Methods: close (consumes self)

### Type Definitions

**Close Error Type**: Not needed for infallible close

If fallible close desired:
```rust
#[derive(Debug, thiserror::Error)]
pub enum CloseError {
    #[error("IO error during close: {0}")]
    Io(#[from] std::io::Error),

    #[error("Cache cleanup failed: {0}")]
    CacheCleanup(String),
}
```

### Close Implementation

**Consuming Close**: Takes ownership of self
```rust
impl Pager {
    pub fn close(self) -> Result<(), CloseError> {
        // Page allocator cleanup
        if let Some(allocator) = self.page_allocator {
            allocator.deinit();
        }

        // Page cache cleanup
        if let Some(cache) = self.cache {
            cache.deinit();
        }

        // Storage cleanup
        self.storage.close()?;

        Ok(())
    }
}
```

**Note**: Fields not accessible after close (self consumed)

### Drop Implementation

**Fallback Cleanup**: Called automatically if close not called
```rust
impl Drop for Pager {
    fn drop(&mut self) {
        // Best-effort cleanup (cannot panic or return errors)
        if let Some(ref allocator) = self.page_allocator {
            // Cannot call deinit (takes owned value)
            // Leak is acceptable (process exiting anyway)
        }

        if let Some(ref cache) = self.cache {
            cache.deinit();
        }

        let _ = self.storage.close(); // Ignore errors
    }
}
```

**Better Pattern**: Use Option for owned cleanup
```rust
pub struct Pager {
    page_allocator: Option<PageAllocator>,
    cache: Option<PageCache>,
    storage: Storage,
}

impl Drop for Pager {
    fn drop(&mut self) {
        // Take ownership of Option values
        if let Some(allocator) = self.page_allocator.take() {
            allocator.deinit();
        }

        if let Some(cache) = self.cache.take() {
            cache.deinit();
        }

        let _ = self.storage.close();
    }
}
```

### Storage Close Implementation

**File Storage**:
```rust
impl Storage {
    pub fn close(self) -> Result<(), CloseError> {
        match self {
            Storage::File(file) => {
                // File closed by Drop on File
                // Explicit close optional
                drop(file);
            }
            Storage::Memory(memory) => {
                memory.deinit();
            }
        }
        Ok(())
    }
}
```

**Memory Storage**:
```rust
impl MemoryStorage {
    pub fn deinit(self) {
        // Buffer freed by Drop on Vec
        // Explicit cleanup not needed
        drop(self);
    }
}
```

### Close Best Practices

**Before Close**:
- Commit all active transactions
- Unpin all cached pages
- Drop all iterators
- Sync if final durability needed

**Calling Close**:
- Explicit close() preferred
- Handle errors if close returns Result
- Consider close() infallible for simplicity

**After Close**:
- Do not use Pager value
- All operations are invalid
- Drop will run again (must be idempotent)

### Testing Strategy

**Unit tests needed for**:
- close frees all resources
- close can be called multiple times (idempotent)
- Drop after close is safe
- Drop without close cleans up
- close with pinned pages is caller error (may panic)

**Property tests for**:
- Resources freed exactly once
- No double free on close + Drop
- No memory leaks after close

**Integration tests for**:
- Close after commit survives restart
- Close without sync loses uncommitted data
- Concurrent operations during close undefined

**Valgrind/ASAN**: Verify no leaks or use-after-free
