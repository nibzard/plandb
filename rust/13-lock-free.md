# Phase 13.4: Lock-Free Data Structures Specification

## Overview

This specification defines lock-free data structures for NorthstarDB to minimize contention and maximize concurrency in hot paths. Lock-free structures enable multiple threads to operate concurrently without blocking, improving throughput and reducing latency under high concurrency.

**Goals:**
- Eliminate mutex contention in high-frequency operations
- Enable wait-free progress for common read operations
- Provide scalable performance under 16+ threads
- Maintain determinism and avoid starvation
- Support atomic operations for statistics and coordination

**Non-Goals:**
- Replace all locks with lock-free alternatives (locks still appropriate for coarse-grained operations)
- Wait-free guarantees for all operations (lock-free sufficient for most use cases)
- Complex lock-free algorithms (RCU, hazard pointers) unless necessary
- Cross-platform atomic operations beyond standard Rust atomics

## Atomic Primitives

### AtomicCounter

**Purpose:** Lock-free counter for statistics and ID generation.

**Use Cases:**
- Transaction ID generation (monotonic increasing)
- Page ID allocation
- Cache statistics (hits, misses, evictions)
- Operation counting (reads, writes, commits)

**Interface:**
```rust
/// Lock-free counter with overflow protection
pub struct AtomicCounter {
    inner: AtomicU64,
    mode: CounterMode,
}

pub enum CounterMode {
    /// Wraps on overflow (cyclic counters)
    Wrap,
    /// Returns error on overflow (monotonic IDs)
    Checked,
    /// Saturates at maximum value
    Saturate,
}

impl AtomicCounter {
    /// Create new counter with initial value
    pub fn new(initial: u64, mode: CounterMode) -> Self;

    /// Increment and return previous value
    pub fn fetch_inc(&self) -> Result<u64, CounterError>;

    /// Decrement and return previous value
    pub fn fetch_dec(&self) -> Result<u64, CounterError>;

    /// Add value and return previous value
    pub fn fetch_add(&self, delta: u64) -> Result<u64, CounterError>;

    /// Get current value (non-atomic snapshot)
    pub fn load(&self) -> u64;

    /// Set to specific value
    pub fn store(&self, value: u64);

    /// Compare and swap (CAS) operation
    pub fn compare_exchange(&self, current: u64, new: u64) -> Result<u64, u64>;
}
```

**Transaction ID Generation:**
```rust
impl TxnIdGenerator {
    pub fn next_id(&self) -> Result<TxnId, Error> {
        let id = self.counter.fetch_inc()?;
        Ok(TxnId::new(id))
    }
}
```

### AtomicBitmap

**Purpose:** Lock-free set for tracking page state and allocation.

**Use Cases:**
- Page allocation tracking (free/allocated)
- Snapshot visibility flags
- Transaction status tracking
- Dirty page tracking

**Interface:**
```rust
/// Lock-free bitmap for page state tracking
pub struct AtomicBitmap {
    bits: Vec<AtomicU8>,
    size: usize,
}

impl AtomicBitmap {
    /// Create bitmap with specified size
    pub fn new(size: usize) -> Self;

    /// Set bit atomically
    pub fn set(&self, index: usize) -> bool {
        // Returns true if bit was previously 0
    }

    /// Clear bit atomically
    pub fn clear(&self, index: usize) -> bool;

    /// Test if bit is set
    pub fn test(&self, index: usize) -> bool;

    /// Find first zero bit (atomic search)
    pub fn find_first_zero(&self, start: usize) -> Option<usize>;

    /// Compare and set bit
    pub fn compare_set(&self, index: usize, expected: bool, new: bool) -> bool;
}
```

**Page Allocation:**
```rust
impl PageAllocator {
    pub fn allocate_page(&self) -> Result<PageId, Error> {
        // Search for free page
        if let Some(idx) = self.bitmap.find_first_zero(0) {
            if self.bitmap.compare_set(idx, false, true) {
                return Ok(PageId::new(idx as u64));
            }
            // CAS failed, retry
        }
        Err(Error::OutOfSpace)
    }
}
```

## Lock-Free Queues

### MpscQueue

**Purpose:** Multi-producer, single-consumer queue for inter-thread communication.

**Use Cases:**
- WAL commit queue (multiple transactions, single WAL writer)
- Background task queue (multiple requesters, single worker)
- I/O completion queue (multiple I/O, single consumer)

**Interface:**
```rust
/// Lock-free MPSC queue
pub struct MpscQueue<T> {
    head: AtomicPtr<Node<T>>,
    tail: UnsafeCell<Node<T>>,
    marker: PhantomData<T>,
}

struct Node<T> {
    data: Option<T>,
    next: AtomicPtr<Node<T>>,
}

impl<T: Send> MpscQueue<T> {
    /// Create new queue
    pub fn new() -> Self;

    /// Push item (multiple producers)
    pub fn push(&self, item: T);

    /// Pop item (single consumer only)
    pub fn pop(&self) -> Option<T>;

    /// Check if empty (approximate)
    pub fn is_empty(&self) -> bool;
}

// Send + Sync bounds
unsafe impl<T: Send> Send for MpscQueue<T> {}
unsafe impl<T: Send> Sync for MpscQueue<T> {}
```

**WAL Commit Queue:**
```rust
impl WalWriter {
    pub fn append_commit(&self, record: CommitRecord) -> Result<(), Error> {
        // Enqueue commit record
        self.commit_queue.push(record);
        // Notify writer thread
        self.writer_notify.notify();
        Ok(())
    }

    fn writer_loop(&self) {
        loop {
            while let Some(record) = self.commit_queue.pop() {
                self.write_record(record)?;
            }
            self.writer_notify.wait();
        }
    }
}
```

### SpmcQueue

**Purpose:** Single-producer, multi-consumer queue for work distribution.

**Use Cases:**
- Page read work distribution (single scheduler, multiple workers)
- Checkpoint task distribution
- Background maintenance work

**Interface:**
```rust
/// Lock-free SPMC queue
pub struct SpmcQueue<T> {
    head: AtomicPtr<Node<T>>,
    tail: UnsafeCell<Node<T>>,
    marker: PhantomData<T>,
}

impl<T: Send> SpmcQueue<T> {
    /// Create new queue
    pub fn new() -> Self;

    /// Push item (single producer only)
    pub fn push(&self, item: T);

    /// Pop item (multiple consumers)
    pub fn try_pop(&self) -> Option<T>;

    /// Steal from other consumers
    pub fn steal(&self) -> Option<T>;
}
```

### MpmcQueue

**Purpose:** Multi-producer, multi-consumer queue for general work stealing.

**Use Cases:**
- Parallel query execution
- Batch processing pools
- Async task scheduling

**Interface:**
```rust
/// Lock-free MPMC queue using array-based CICADA algorithm
pub struct MpmcQueue<T, const N: usize> {
    buffer: [AtomicPtr<Node<T>>; N],
    head: AtomicUsize,
    tail: AtomicUsize,
    mask: usize,
}

impl<T: Send> MpmcQueue<T, { 1024 }> {
    /// Create new queue (size must be power of 2)
    pub fn new() -> Self;

    /// Push item
    pub fn push(&self, item: T) -> Result<(), T>;

    /// Pop item
    pub fn pop(&self) -> Option<T>;

    /// Check if empty (approximate)
    pub fn is_empty(&self) -> bool;
}
```

## Lock-Free Stack

### ConcurrentStack

**Purpose:** Lock-free stack for object pooling and LIFO caching.

**Use Cases:**
- Free page stack for page allocator
- B+Tree node pool
- Transaction context pool

**Interface:**
```rust
/// Lock-free stack using Treiber stack algorithm
pub struct ConcurrentStack<T> {
    head: AtomicPtr<Node<T>>,
    marker: PhantomData<T>,
}

struct Node<T> {
    data: ManuallyDrop<T>,
    next: *mut Node<T>,
}

impl<T: Send> ConcurrentStack<T> {
    /// Create new stack
    pub fn new() -> Self;

    /// Push item onto stack
    pub fn push(&self, item: T);

    /// Pop item from stack
    pub fn pop(&self) -> Option<T>;

    /// Check if empty (approximate)
    pub fn is_empty(&self) -> bool;
}
```

**Treiber Stack Algorithm:**
```rust
impl<T: Send> ConcurrentStack<T> {
    pub fn push(&self, item: T) {
        let node = Box::into_raw(Box::new(Node {
            data: ManuallyDrop::new(item),
            next: ptr::null_mut(),
        }));

        loop {
            let old_head = self.head.load(Acquire);
            node.next = old_head;

            if self.head.compare_exchange_weak(
                old_head,
                node,
                Release,
                Acquire,
            ).is_ok() {
                break;
            }
            // CAS failed, retry
        }
    }

    pub fn pop(&self) -> Option<T> {
        loop {
            let old_head = self.head.load(Acquire);
            if old_head.is_null() {
                return None;
            }

            let node = unsafe { &*old_head };
            let new_head = node.next;

            if self.head.compare_exchange_weak(
                old_head,
                new_head,
                Release,
                Acquire,
            ).is_ok() {
                unsafe {
                    let data = ptr::read(&node.data);
                    let _ = Box::from_raw(old_head);
                    return Some(ManuallyDrop::into_inner(data));
                }
            }
            // CAS failed, retry
        }
    }
}
```

## Sharded Data Structures

### ShardedHashMap

**Purpose:** Lock-free(ish) hash map with per-shard locking for high concurrency.

**Use Cases:**
- Transaction registry (txn_id -> txn state)
- Page cache metadata
- Snapshot registry

**Interface:**
```rust
/// Sharded hash map with per-shard mutex
pub struct ShardedHashMap<K, V>
where
    K: Eq + Hash,
{
    shards: Vec<Mutex<HashMap<K, V>>>,
    num_shards: usize,
    marker: PhantomData<(K, V)>,
}

impl<K: Eq + Hash + Clone, V: Clone> ShardedHashMap<K, V> {
    /// Create map with specified number of shards
    pub fn new(num_shards: usize) -> Self;

    /// Insert value
    pub fn insert(&self, key: K, value: V) -> Option<V>;

    /// Get value
    pub fn get(&self, key: &K) -> Option<V>;

    /// Remove value
    pub fn remove(&self, key: &K) -> Option<V>;

    /// Get or insert with factory
    pub fn get_or_insert_with<F>(&self, key: K, f: F) -> V
    where
        F: FnOnce() -> V;
}
```

**Sharding Strategy:**
```rust
impl<K: Eq + Hash + Clone, V: Clone> ShardedHashMap<K, V> {
    fn shard_index(&self, key: &K) -> usize {
        let mut hasher = DefaultHasher::new();
        key.hash(&mut hasher);
        (hasher.finish() as usize) % self.num_shards
    }

    pub fn insert(&self, key: K, value: V) -> Option<V> {
        let idx = self.shard_index(&key);
        let mut shard = self.shards[idx].lock();
        shard.insert(key, value)
    }
}
```

### ShardedCache

**Purpose:** Thread-local cache with shared fallback for minimal contention.

**Use Cases:**
- Page cache (thread-local hot pages, shared cold pages)
- B+Tree node cache
- Metadata cache

**Interface:**
```rust
/// Sharded cache with thread-local caches
pub struct ShardedCache<K, V>
where
    K: Eq + Hash,
{
    local: ThreadLocal<LocalCache<K, V>>,
    shared: Arc<SharedCache<K, V>>,
    stats: Arc<CacheStats>,
}

struct LocalCache<K, V> {
    entries: Vec<(K, V)>,
    capacity: usize,
}

impl<K: Eq + Hash + Clone, V: Clone> ShardedCache<K, V> {
    /// Create sharded cache
    pub fn new(local_capacity: usize, shared_capacity: usize) -> Self;

    /// Get value (check local, then shared)
    pub fn get(&self, key: &K) -> Option<V>;

    /// Insert value (local first, overflow to shared)
    pub fn insert(&self, key: K, value: V);

    /// Invalidate key across all caches
    pub fn invalidate(&self, key: &K);
}
```

**Cache Lookup:**
```rust
impl<K: Eq + Hash + Clone, V: Clone> ShardedCache<K, V> {
    pub fn get(&self, key: &K) -> Option<V> {
        // Check thread-local cache first (lock-free)
        if let Some(local) = self.local.get() {
            if let Some(value) = local.find(key) {
                self.stats.record_local_hit();
                return Some(value.clone());
            }
        }

        // Check shared cache
        if let Some(value) = self.shared.get(key) {
            self.stats.record_shared_hit();
            // Promote to local cache
            if let Some(local) = self.local.get() {
                local.insert(key.clone(), value.clone());
            }
            return Some(value);
        }

        self.stats.record_miss();
        None
    }
}
```

## Atomic Pointers

### AtomicArc

**Purpose:** Atomic reference counted pointer for lock-free sharing.

**Use Cases:**
- Global configuration reference
- Current snapshot pointer
- Active transaction list

**Interface:**
```rust
/// Atomic Arc for lock-free reference swapping
pub struct AtomicArc<T> {
    ptr: AtomicPtr<T>,
    marker: PhantomData<Arc<T>>,
}

impl<T: Clone> AtomicArc<T> {
    /// Create new atomic arc
    pub fn new(value: Arc<T>) -> Self;

    /// Load current value
    pub fn load(&self) -> Arc<T>;

    /// Store new value
    pub fn store(&self, value: Arc<T>);

    /// Compare and swap
    pub fn compare_exchange(
        &self,
        current: &Arc<T>,
        new: Arc<T>,
    ) -> Result<Arc<T>, Arc<T>>;

    /// Swap values and return old
    pub fn swap(&self, new: Arc<T>) -> Arc<T>;
}
```

**Snapshot Switch:**
```rust
impl SnapshotManager {
    pub fn switch_snapshot(&self, new_snapshot: Arc<Snapshot>) {
        // Atomically swap current snapshot
        let old = self.current.swap(new_snapshot);
        // Old snapshot dropped when all readers finish
    }

    pub fn current_snapshot(&self) -> Arc<Snapshot> {
        self.current.load()
    }
}
```

## Sequencer and Coordination

### Sequencer

**Purpose:** Lock-free sequence generator for ordering operations.

**Use Cases:**
- WAL sequence number (LSN) generation
- Operation ordering in concurrent B+Tree
- Event sequencing

**Interface:**
```rust
/// Lock-free sequencer for monotonic IDs
pub struct Sequencer {
    next: AtomicU64,
    watermark: AtomicU64,
}

impl Sequencer {
    /// Create new sequencer
    pub fn new(start: u64) -> Self;

    /// Acquire next sequence number
    pub fn next(&self) -> u64 {
        self.next.fetch_add(1, Acquire)
    }

    /// Get current sequence number
    pub fn current(&self) -> u64 {
        self.next.load(Acquire) - 1
    }

    /// Update completion watermark
    pub fn complete(&self, seq: u64) {
        let mut current = self.watermark.load(Acquire);
        while seq > current {
            match self.watermark.compare_exchange_weak(
                current,
                seq,
                Release,
                Acquire,
            ) {
                Ok(_) => break,
                Err(actual) => current = actual,
            }
        }
    }

    /// Get highest completed sequence
    pub fn watermark(&self) -> u64 {
        self.watermark.load(Acquire)
    }

    /// Check if sequence is complete
    pub fn is_complete(&self, seq: u64) -> bool {
        self.watermark() >= seq
    }
}
```

## Concurrency Model

### Memory Ordering

**Acquire:** For read operations that must see previous writes
```rust
let value = self.data.load(Acquire); // See all writes before this
```

**Release:** For write operations that must be visible to subsequent reads
```rust
self.data.store(value, Release); // Make visible to subsequent Acquire
```

**AcqRel:** For read-modify-write operations (fetch_add, compare_exchange)
```rust
self.counter.fetch_add(1, AcqRel); // Both acquire and release
```

**Relaxed:** For simple counters where ordering doesn't matter
```rust
self.stats.hits.fetch_add(1, Relaxed); // No ordering guarantees needed
```

### ABA Problem

**Issue:** CAS can succeed if value changes from A->B->A between reads.

**Solution:** Use versioned pointers or hazard pointers for long-lived operations.

```rust
/// Versioned pointer to avoid ABA
pub struct VersionedPtr<T> {
    ptr: usize, // Combines pointer and version counter
}

impl<T> VersionedPtr<T> {
    fn new(ptr: *mut T, version: u64) -> Self {
        // Pack pointer and version into single usize
        let version_bits = (version as usize) << 48;
        let ptr_bits = ptr as usize & ((1 << 48) - 1);
        VersionedPtr { ptr: version_bits | ptr_bits }
    }

    fn ptr(&self) -> *mut T {
        ((self.ptr as usize) & ((1 << 48) - 1)) as *mut T
    }

    fn version(&self) -> u64 {
        (self.ptr >> 48) as u64
    }
}
```

## Performance Targets

### Atomic Operation Latency

**Baseline (mutex):**
- Mutex lock/unlock: ~50ns (uncontended)
- Mutex contention: 1000ns+ (under contention)

**Target (lock-free):**
- Atomic load/store: <5ns
- Atomic fetch_add: <10ns
- CAS operation: <20ns (uncontended)
- CAS operation: <50ns (low contention)

**Improvement:** 5-10x faster than mutex for uncontended operations

### Throughput Scaling

**Target:** Linear scaling up to 16 threads
```rust
#[bench]
fn bench_atomic_counter_scaling(b: &mut Bencher) {
    let counter = Arc::new(AtomicCounter::new(0, CounterMode::Wrap));
    let handles: Vec<_> = (0..16)
        .map(|_| {
            let counter = counter.clone();
            thread::spawn(move || {
                for _ in 0..1000000 {
                    counter.fetch_inc().unwrap();
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    // Should achieve ~15x single-threaded throughput
    assert_eq!(counter.load(), 16_000_000);
}
```

### Cache Statistics Performance

**Target:** Lock-free stats with <1% overhead
```rust
impl CacheStats {
    pub fn record_hit(&self) {
        self.hits.fetch_add(1, Relaxed); // Minimal overhead
    }

    pub fn hit_rate(&self) -> f64 {
        let hits = self.hits.load(Relaxed);
        let total = self.total.load(Relaxed);
        (hits as f64) / (total as f64)
    }
}
```

### Comparison to Locked Alternatives

**Transaction ID Generation:**
- Mutex: ~100ns per ID (under contention)
- Atomic: ~10ns per ID
- Improvement: 10x

**Cache Statistics:**
- Mutex: ~50ns per update (under contention)
- Atomic: ~5ns per update
- Improvement: 10x

**Queue Operations:**
- Mutex queue: ~200ns push/pop (under contention)
- MPSC queue: ~50ns push/pop
- Improvement: 4x

## Testing Requirements

### Unit Tests

**Atomic Counter Tests:**
```rust
#[test]
fn test_atomic_counter_increment() {
    let counter = AtomicCounter::new(0, CounterMode::Wrap);
    assert_eq!(counter.fetch_inc().unwrap(), 0);
    assert_eq!(counter.fetch_inc().unwrap(), 1);
    assert_eq!(counter.load(), 2);
}

#[test]
fn test_atomic_counter_overflow() {
    let counter = AtomicCounter::new(u64::MAX, CounterMode::Checked);
    counter.fetch_inc().unwrap_err(); // Should error on overflow
}
```

**Concurrent Stack Tests:**
```rust
#[test]
fn test_concurrent_stack_push_pop() {
    let stack = Arc::new(ConcurrentStack::new());
    stack.push(42);
    assert_eq!(stack.pop(), Some(42));
    assert_eq!(stack.pop(), None);
}
```

**MPSC Queue Tests:**
```rust
#[test]
fn test_mpsc_queue_basic() {
    let queue = Arc::new(MpscQueue::new());
    queue.push(1);
    queue.push(2);
    assert_eq!(queue.pop(), Some(1));
    assert_eq!(queue.pop(), Some(2));
}
```

### Concurrency Tests

```rust
#[test]
fn test_concurrent_counter() {
    let counter = Arc::new(AtomicCounter::new(0, CounterMode::Wrap));
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let counter = counter.clone();
            thread::spawn(move || {
                for _ in 0..100000 {
                    counter.fetch_inc().unwrap();
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    assert_eq!(counter.load(), 800_000);
}

#[test]
fn test_concurrent_stack() {
    let stack = Arc::new(ConcurrentStack::new());
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let stack = stack.clone();
            thread::spawn(move || {
                for i in 0..10000 {
                    stack.push(i);
                    stack.pop();
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    // Stack should be empty
    assert!(stack.is_empty());
}
```

### Property-Based Tests

```rust
#[quickcheck]
fn prop_counter_monotonic(ops: Vec<Op>) -> bool {
    let counter = AtomicCounter::new(0, CounterMode::Wrap);
    let mut last = 0;

    for op in ops {
        match op {
            Op::Inc => {
                let val = counter.fetch_inc().unwrap();
                if val < last {
                    return false; // Not monotonic
                }
                last = val;
            }
            Op::Add(n) => {
                let val = counter.fetch_add(n).unwrap();
                if val < last {
                    return false;
                }
                last = val;
            }
        }
    }

    true
}
```

### Stress Tests

```rust
#[test]
fn test_atomic_stress() {
    let counter = Arc::new(AtomicCounter::new(0, CounterMode::Wrap));
    let handles: Vec<_> = (0..16)
        .map(|_| {
            let counter = counter.clone();
            thread::spawn(move || {
                for _ in 0..1000000 {
                    black_box(counter.fetch_inc());
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    assert_eq!(counter.load(), 16_000_000);
}
```

## Benchmarks

### Microbenchmarks

```rust
#[bench]
fn bench_atomic_load(b: &mut Bencher) {
    let counter = AtomicCounter::new(42, CounterMode::Wrap);
    b.iter(|| {
        black_box(counter.load());
    });
}

#[bench]
fn bench_atomic_fetch_add(b: &mut Bencher) {
    let counter = AtomicCounter::new(0, CounterMode::Wrap);
    b.iter(|| {
        black_box(counter.fetch_add(1));
    });
}

#[bench]
fn bench_atomic_compare_exchange(b: &mut Bencher) {
    let counter = AtomicCounter::new(0, CounterMode::Wrap);
    b.iter(|| {
        let current = counter.load();
        black_box(counter.compare_exchange(current, current + 1));
    });
}

#[bench]
fn bench_mpsc_queue_push(b: &mut Bencher) {
    let queue = Arc::new(MpscQueue::new());
    b.iter(|| {
        queue.push(black_box(42));
    });
}

#[bench]
fn bench_concurrent_stack_push(b: &mut Bencher) {
    let stack = Arc::new(ConcurrentStack::new());
    b.iter(|| {
        stack.push(black_box(42));
    });
}
```

### Concurrency Benchmarks

```rust
#[bench]
fn bench_atomic_counter_concurrent(b: &mut Bencher) {
    let counter = Arc::new(AtomicCounter::new(0, CounterMode::Wrap));
    let num_threads = 16;
    let ops_per_thread = 100_000;

    b.iter(|| {
        let handles: Vec<_> = (0..num_threads)
            .map(|_| {
                let counter = counter.clone();
                thread::spawn(move || {
                    for _ in 0..ops_per_thread {
                        black_box(counter.fetch_inc());
                    }
                })
            })
            .collect();

        for handle in handles {
            handle.join().unwrap();
        }
    });
}
```

## Integration Points

### Pager Integration

```rust
impl Pager {
    pub fn allocate_page(&self) -> Result<PageId, Error> {
        // Use atomic counter for page ID allocation
        let id = self.page_id_counter.fetch_inc()?;
        Ok(PageId::new(id))
    }

    pub fn mark_dirty(&self, page_id: PageId) {
        self.dirty_bitmap.set(page_id.as_u64() as usize);
    }
}
```

### Transaction Integration

```rust
impl TxnManager {
    pub fn begin_txn(&self) -> Result<TxnId, Error> {
        // Atomic transaction ID generation
        let id = self.txn_counter.fetch_inc()?;
        let txn = WriteTxn::new(id);
        self.registry.insert(id, txn);
        Ok(id)
    }
}
```

### Cache Integration

```rust
impl PageCache {
    pub fn record_access(&self, hit: bool) {
        if hit {
            self.stats.hits.fetch_add(1, Relaxed);
        } else {
            self.stats.misses.fetch_add(1, Relaxed);
        }
        self.stats.total.fetch_add(1, Relaxed);
    }

    pub fn hit_rate(&self) -> f64 {
        let hits = self.stats.hits.load(Relaxed);
        let total = self.stats.total.load(Relaxed);
        (hits as f64) / (total as f64)
    }
}
```

### WAL Integration

```rust
impl Wal {
    pub fn append(&self, record: WalRecord) -> Result<(), Error> {
        // Enqueue to commit queue (MPSC)
        self.commit_queue.push(record);
        self.notify_writer();
        Ok(())
    }

    fn writer_thread(&self) {
        loop {
            while let Some(record) = self.commit_queue.pop() {
                self.write_record(record)?;
            }
            self.wait_for_work();
        }
    }
}
```

## Rust Implementation Guidance

### Memory Ordering Rules

1. **Use Relaxed for simple counters** where ordering between operations doesn't matter
2. **Use Acquire for loads** that must see previous stores
3. **Use Release for stores** that must be visible to subsequent loads
4. **Use AcqRel for RMW operations** (fetch_add, compare_exchange)
5. **Use SeqCst only** when total ordering required (rare)

### Lock-Free Patterns

1. **Treiber Stack**: Simple, widely applicable
2. **MPSC Queue**: Single consumer avoids contention
3. **Sharded Maps**: Per-shard mutex reduces contention
4. **Atomic Counters**: Use for ID generation and statistics
5. **Versioned Pointers**: Avoid ABA problem for long-lived operations

### Common Pitfalls

1. **Forgetting memory ordering**: Always specify ordering explicitly
2. **ABA problem**: Use versioned pointers or epoch-based reclamation
3. **Memory leaks**: Ensure reclaimed nodes are freed
4. **Fairness**: Lock-free doesn't prevent starvation
5. **Composition**: Lock-free structures don't compose

### Testing Strategy

1. **Unit tests**: Basic functionality
2. **Concurrency tests**: Multiple threads
3. **Stress tests**: High contention
4. **Property tests**: Invariants preservation
5. **Benchmarks**: Performance validation

## Configuration Examples

### Development Profile

```rust
pub fn dev_atomic_config() -> AtomicConfig {
    AtomicConfig {
        enable_stats: true,
        enable_assertions: true,
        spin_backoff: SpinBackoff::Exponential,
    }
}
```

### Production Profile

```rust
pub fn prod_atomic_config() -> AtomicConfig {
    AtomicConfig {
        enable_stats: true,
        enable_assertions: false,
        spin_backoff: SpinBackoff::Yield,
    }
}
```

## Monitoring

**Metrics to expose:**
```rust
pub struct AtomicMetrics {
    pub operation_name: String,
    pub total_ops: AtomicU64,
    pub contentions: AtomicU64,
    pub retries: AtomicU64,
    pub avg_latency_ns: AtomicU64,
}
```

## Summary

Phase 13.4 completes the Phase 13 performance optimization suite by adding lock-free data structures to complement caching (13.1), I/O batching (13.2), and memory pooling (13.3). This specification provides:

1. **Atomic primitives**: Counters, bitmaps, pointers
2. **Lock-free queues**: MPSC, SPMC, MPMC
3. **Lock-free stack**: Treiber stack algorithm
4. **Sharded structures**: Per-shard locking for high concurrency
5. **Coordination**: Sequencer for ordering
6. **Performance targets**: 5-10x improvement over mutex
7. **Comprehensive testing**: Unit, concurrency, stress, property
8. **Rust guidance**: Memory ordering, patterns, pitfalls

**Next Phase:** Phase 14 - Production Hardening (crash safety, monitoring, observability)
