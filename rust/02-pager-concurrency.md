# Pager Concurrency

## Purpose

The Pager concurrency specification details the threading model, lock usage patterns, deadlock prevention strategies, and Rust concurrency primitives. The Zig implementation uses a single-writer model with no internal locking, while the Rust implementation can leverage the type system for safe concurrent access through RwLock, Mutex, and AtomicU64 for thread-safe operations.

## Concurrency Model

### Zig Single-Writer Model

**Design Choice**: Single thread owns the pager

**Behavior**:
- No internal synchronization or locking
- Caller ensures exclusive access
- Single writer, single or multiple readers (coordinated)
- Relies on external coordination

**Rationale**:
- Simpler implementation (no lock overhead)
- Sufficient for embedded database use case
- Most embedded databases are single-threaded
- Avoids lock contention complexity

**Limitations**:
- Cannot safely share pager across threads
- Concurrent reads require external synchronization
- Not suitable for multi-threaded workloads

**Usage Pattern**:
```zig
var pager = try Pager.open(allocator, filename);
defer pager.close();

// All operations on pager happen in this thread
try pager.putBtreeValue(key, value, txn_id);
const value = try pager.getBtreeValue(key);
```

### Rust Concurrent Access Model

**Design Choice**: Support concurrent reads, exclusive writes

**Behavior**:
- Multiple threads can read concurrently
- Single writer at a time (excludes readers)
- Lock-based synchronization
- Type system prevents data races

**Rationale**:
- Better Rust ergonomics (sync + Send traits)
- Enables multi-threaded workloads
- Leverages Rust borrowing for safety
- Standard practice for Rust databases

**Usage Pattern**:
```rust
let pager = Arc::new(RwLock::new(Pager::open(&path)?));

// Concurrent reads
{
    let pager1 = pager.read().unwrap();
    let value1 = pager1.get(&key);
}

// Exclusive write
{
    let mut pager2 = pager.write().unwrap();
    pager2.put(&key, &value)?;
}
```

## Lock Usage Patterns

### RwLock for Page Access

**Purpose**: Allow multiple concurrent readers, exclusive writers

**Structure**: RwLock<Pager>
- Read lock: Shared access, multiple readers allowed
- Write lock: Exclusive access, only one writer

**Read Operations**: Use read() lock
- getBtreeValue: Read B+tree for value lookup
- readPage: Read page from storage
- createIterator: Create B+tree iterator

**Write Operations**: Use write() lock
- putBtreeValue: Insert or update key-value pair
- deleteBtreeValue: Delete key from B+tree
- writePage: Write page to storage

**Benefits**:
- Multiple readers can proceed concurrently
- Writers have exclusive access (no concurrent modifications)
- Read-heavy workloads benefit from concurrency

**Costs**:
- Lock overhead on every operation
- Write blocks all readers (reduced throughput)
- Potential for reader starvation (writers waiting)

### Mutex for Internal State

**Purpose**: Protect internal mutable state

**Use Cases**:
- Page allocator state (free_pages array)
- Cache modifications (insert/evict)
- Access counter updates

**Implementation**: Mutex<T> or RwLock<T>

**Example**:
```rust
pub struct PageCache {
    entries: RwLock<HashMap<u64, CacheEntry>>,
    lru_list: Mutex<LinkedList<CacheEntry>>,
    access_counter: AtomicU64,
}
```

**Rationale**: Fine-grained locking reduces contention
- Hash map readers don't block LRU list operations
- Atomic operations for counters avoid lock overhead

### Atomic Operations

**Purpose**: Lock-free synchronization for simple values

**Use Cases**:
- Transaction ID allocation (AtomicU64)
- Access counter for LRU (AtomicU64)
- Pin count updates (AtomicU32)

**Benefits**:
- No lock overhead
- High throughput for simple increments
- Avoids contention for hot fields

**Limitations**:
- Only works for single values
- Cannot protect complex invariants
- Requires careful ordering (memory ordering)

**Example**:
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

## Deadlock Prevention Strategies

### Lock Ordering

**Strategy**: Establish global lock acquisition order

**Rules**:
1. Always acquire locks in consistent order
2. Never acquire a lock while holding another lock (unless following order)
3. Release locks in reverse acquisition order

**Example Order**:
1. Page allocator lock (if needed)
2. Cache read lock (for lookup)
3. Cache write lock (for modification)
4. Storage lock (for I/O)

**Violating Order**: Risk of deadlock
- Thread A: Lock 1 → Lock 2
- Thread B: Lock 2 → Lock 1
- Result: Deadlock (each waiting for the other)

**Prevention**: Document and enforce lock ordering
- Code review to verify lock order
- Static analysis tools (lockdep)
- Runtime deadlock detection (optional)

### Minimize Lock Scope

**Strategy**: Hold locks for shortest time possible

**Pattern**:
```rust
// Bad: Lock held during I/O
{
    let mut cache = self.cache.write().unwrap();
    let page = self.read_page_from_storage(page_id)?;  // I/O with lock!
    cache.insert(page_id, page);
}

// Good: Release lock before I/O
{
    let page = self.read_page_from_storage(page_id)?;
}
{
    let mut cache = self.cache.write().unwrap();
    cache.insert(page_id, page);
}
```

**Benefits**:
- Reduces lock contention
- Allows concurrent operations during I/O
- Minimizes critical section

### Avoid Nested Locks

**Strategy**: Prefer single lock per operation

**Problem**: Nested locks complicate deadlock prevention

**Alternative**:
- Use coarser-grained locks (one lock for entire operation)
- Use lock-free data structures for hot paths
- Restructure code to avoid holding multiple locks

**Example**:
```rust
// Instead of nested locks:
// let cache = self.cache.write().unwrap();
// let allocator = self.allocator.lock().unwrap();

// Use single lock or restructure:
let mut pager = self.pager.write().unwrap();
pager.allocate_page();  // Handles both cache and allocator
```

### Try Lock for Time-Bounded Operations

**Strategy**: Use try_read() or try_write() with timeout

**Pattern**:
```rust
if let Some(pager) = self.pager.try_write_for(Duration::from_secs(1)) {
    // Got lock, proceed
} else {
    // Lock not available, handle timeout
}
```

**Use Cases**:
- Operations that cannot block indefinitely
- Deadlock detection and recovery
- Priority-based operations

**Cost**: More complex error handling

## Rust Concurrency Primitives

### RwLock

**Purpose**: Multiple readers, single writer

**Type**: std::sync::RwLock<T>

**Methods**:
- read(): Acquire shared read access (RwLockReadGuard)
- write(): Acquire exclusive write access (RwLockWriteGuard)
- try_read(): Non-blocking read attempt
- try_write(): Non-blocking write attempt

**Usage**:
```rust
pub struct Pager {
    inner: RwLock<PagerImpl>,
}

impl Pager {
    pub fn get(&self, key: &[u8]) -> Result<Option<Value>, Error> {
        let inner = self.inner.read().unwrap();
        inner.get(key)
    }

    pub fn put(&self, key: &[u8], value: &[u8]) -> Result<(), Error> {
        let mut inner = self.inner.write().unwrap();
        inner.put(key, value)
    }
}
```

**Trade-offs**:
- Pro: Excellent read scalability
- Con: Write blocks all readers
- Con: More complex than single Mutex

### Mutex

**Purpose**: Mutual exclusion for exclusive access

**Type**: std::sync::Mutex<T>

**Methods**:
- lock(): Acquire lock (MutexGuard)
- try_lock(): Non-blocking lock attempt

**Usage**:
```rust
pub struct PageAllocator {
    free_pages: Mutex<Vec<u64>>,
}

impl PageAllocator {
    pub fn allocate(&self) -> Option<u64> {
        let mut free_pages = self.free_pages.lock().unwrap();
        free_pages.pop()
    }
}
```

**Trade-offs**:
- Pro: Simpler than RwLock
- Pro: Exclusive access ensures safety
- Con: No concurrent reads

### AtomicU64

**Purpose**: Lock-free atomic operations on 64-bit values

**Type**: std::sync::atomic::AtomicU64

**Methods**:
- fetch_add(value, ordering): Atomic add-and-fetch
- load(ordering): Read current value
- store(value, ordering): Write new value
- compare_exchange(...): Compare-and-swap

**Usage**:
```rust
pub struct TransactionIdGenerator {
    next_id: AtomicU64,
}

impl TransactionIdGenerator {
    pub fn next(&self) -> TransactionId {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        TransactionId(id)
    }
}
```

**Memory Ordering**:
- Relaxed: No ordering guarantees (fastest)
- Acquire/Release: Synchronization with other operations
- SeqCst: Sequential consistency (strongest, default)

**Recommendation**: Use SeqCst for correctness, optimize if profiling shows contention

### Arc for Shared Ownership

**Purpose**: Enable shared ownership across threads

**Type**: std::sync::Arc<T>

**Usage**:
```rust
let pager = Arc::new(RwLock::new(Pager::open(&path)?));

// Clone Arc for new thread
let pager_clone = Arc::clone(&pager);
thread::spawn(move || {
    let pager = pager_clone.read().unwrap();
    // Use pager
});
```

**Thread Safety**:
- Arc<T> is Send + Sync if T is Send + Sync
- Arc<Mutex<T>> is Send + Sync if T is Send
- Arc<RwLock<T>> is Send + Sync if T is Send + Sync

## Implementation Guidance

### Thread-Safe Pager Wrapper

**Structure**: RwLock around implementation
```rust
pub struct Pager {
    inner: RwLock<PagerImpl>,
}

struct PagerImpl {
    storage: Storage,
    cache: Option<PageCache>,
    page_allocator: PageAllocator,
    current_meta: MetaState,
}
```

**Public API**: Delegates to inner with appropriate lock
```rust
impl Pager {
    pub fn read_page(&self, page_id: u64, buffer: &mut [u8]) -> Result<(), Error> {
        let inner = self.inner.read().unwrap();
        inner.read_page(page_id, buffer)
    }

    pub fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<(), Error> {
        let mut inner = self.inner.write().unwrap();
        inner.write_page(page_id, buffer)
    }
}
```

### Lock Granularity

**Coarse-Grained**: Single RwLock for entire pager
- Simple implementation
- Easy to reason about
- Sufficient for most workloads

**Fine-Grained**: Separate locks for components
- More complex implementation
- Potential for higher concurrency
- Risk of deadlock if not careful

**Recommendation**: Start with coarse-grained, profile before optimizing

### Testing Strategy

**Unit tests needed for**:
- Concurrent reads don't interfere
- Write excludes all other operations
- Lock acquisition order prevents deadlock
- Atomic operations are thread-safe

**Stress tests for**:
- Many threads reading simultaneously
- Many threads writing with contention
- Mixed read/write workloads

**Deadlock detection**:
- Use lockdep (Linux) if available
- Timeout-based testing
- Manual code review for lock ordering

**Thread sanitizer**: Use -Z sanitizer=thread in Rust to detect data races
