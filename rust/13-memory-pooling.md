# Phase 13.3: Memory Pooling Specification

## Overview

This specification defines a memory pooling system for NorthstarDB to minimize allocation overhead, improve memory locality, and reduce fragmentation for frequently allocated structures.

**Goals:**
- Reduce allocation overhead for hot paths
- Improve cache locality through object reuse
- Minimize memory fragmentation
- Provide deterministic allocation behavior
- Support concurrent access with minimal contention

**Non-Goals:**
- General-purpose allocator replacement
- Automatic memory management (Rust's ownership model remains)
- Cross-language memory sharing (FFI only at boundaries)

## Memory Pool Types

### 1. Object Pool - Fixed-Size Objects

**Purpose:** Reuse frequently allocated/deallocated fixed-size structures.

**Use Cases:**
- B+Tree nodes (internal and leaf)
- Transaction context structures
- Cache entries
- WAL segment buffers

**Interface:**
```rust
/// Fixed-size object pool
pub struct ObjectPool<T> {
    config: PoolConfig,
    local: LocalPool<T>,
    shared: Arc<SharedPool<T>>,
}

pub struct PoolConfig {
    /// Max objects per local pool (before spillover)
    pub local_capacity: usize,
    /// Max objects in shared central pool
    pub shared_capacity: usize,
    /// Pre-warm pool on creation
    pub prewarm: bool,
}

impl<T: Poolable> ObjectPool<T> {
    /// Acquire object from pool
    pub fn acquire(&self) -> Pooled<T>;

    /// Return object to pool
    pub fn release(&self, obj: Pooled<T>);

    /// Get current pool statistics
    pub fn stats(&self) -> PoolStats;
}

/// Trait for poolable objects
pub trait Poolable: Sized {
    /// Initialize object for reuse
    fn reset(&mut self);

    /// Default initial state
    fn new() -> Self;
}

/// Smart pointer for pooled objects
pub struct Pooled<T> {
    inner: ManuallyDrop<T>,
    pool: Weak<SharedPool<T>>,
}

impl<T> Drop for Pooled<T> {
    fn drop(&mut self) {
        // Return to pool on drop
        if let Some(pool) = self.pool.upgrade() {
            pool.release(unsafe { ptr::read(&self.inner) });
        }
    }
}
```

**Configuration Examples:**
```rust
// B+Tree internal nodes (1KB)
const BTREE_INTERNAL_SIZE: usize = 1024;
let btree_pool = ObjectPool::new(PoolConfig {
    local_capacity: 64,     // Per-thread cache
    shared_capacity: 4096,  // Global reserve
    prewarm: true,
});

// Transaction contexts (512B)
const TXN_CTX_SIZE: usize = 512;
let txn_pool = ObjectPool::new(PoolConfig {
    local_capacity: 128,
    shared_capacity: 2048,
    prewarm: false,
});
```

### 2. Buffer Pool - Page I/O Buffers

**Purpose:** Manage reusable I/O buffers for page reads/writes.

**Use Cases:**
- Page cache buffers
- WAL segment buffers
- Network I/O buffers (replication)

**Interface:**
```rust
/// Buffer pool for I/O operations
pub struct BufferPool {
    config: BufferConfig,
    buffers: Arc<SharedBuffers>,
}

pub struct BufferConfig {
    /// Buffer size (typically page size: 4KB, 8KB, 16KB)
    pub buffer_size: usize,
    /// Number of buffers per local pool
    pub local_buffers: usize,
    /// Global buffer reserve
    pub shared_buffers: usize,
    /// Alignment requirement (typically 512B for direct I/O)
    pub alignment: usize,
}

impl BufferPool {
    /// Acquire buffer for I/O
    pub fn acquire(&self) -> PooledBuffer;

    /// Acquire buffer with specific alignment
    pub fn acquire_aligned(&self, align: usize) -> PooledBuffer;
}

/// Pooled I/O buffer
pub struct PooledBuffer {
    ptr: NonNull<u8>,
    capacity: usize,
    pool: Weak<SharedBuffers>,
}

impl Deref for PooledBuffer {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        unsafe { slice::from_raw_parts(self.ptr.as_ptr(), self.capacity) }
    }
}

impl DerefMut for PooledBuffer {
    fn deref_mut(&mut self) -> &mut Self::Target {
        unsafe { slice::from_raw_parts_mut(self.ptr.as_ptr(), self.capacity) }
    }
}
```

**Page Cache Integration:**
```rust
// In pager module
impl Pager {
    pub fn read_page(&self, id: PageId) -> Result<&[u8]> {
        // Check cache first
        if let Some(cached) = self.cache.get(id) {
            return Ok(cached);
        }

        // Acquire buffer from pool
        let mut buffer = self.buffer_pool.acquire();
        self.storage.read_page(id, &mut buffer)?;

        // Insert into cache (takes ownership)
        Ok(self.cache.insert(id, buffer))
    }
}
```

### 3. Arena Allocator - Transaction-Scoped Data

**Purpose:** Allocate short-lived data that can be bulk-freed at transaction end.

**Use Cases:**
- Transaction read sets
- Write-ahead log entry construction
- Query execution intermediates
- Per-request allocations

**Interface:**
```rust
/// Arena allocator for scoped allocations
pub struct Arena {
    chunks: Vec<Chunk>,
    cursor: usize,
    config: ArenaConfig,
}

pub struct ArenaConfig {
    /// Initial chunk size
    pub initial_chunk: usize,
    /// Maximum chunk size (growth limit)
    pub max_chunk: usize,
    /// Alignment for allocations
    pub alignment: usize,
}

impl Arena {
    /// Allocate from arena
    pub fn alloc<T>(&mut self, value: T) -> &mut T {
        let ptr = self.alloc_raw(size_of::<T>(), align_of::<T>()) as *mut T;
        unsafe {
            ptr.write(value);
            &mut *ptr
        }
    }

    /// Allocate slice
    pub fn alloc_slice<T: Copy>(&mut self, slice: &[T]) -> &[T] {
        let ptr = self.alloc_raw(slice.len() * size_of::<T>(), align_of::<T>()) as *mut T;
        unsafe {
            ptr.copy_from_nonoverlapping(slice.as_ptr(), slice.len());
            slice::from_raw_parts(ptr, slice.len())
        }
    }

    /// Reset arena (free all allocations)
    pub fn reset(&mut self) {
        self.chunks.clear();
        self.cursor = 0;
    }
}

impl Drop for Arena {
    fn drop(&mut self) {
        self.reset(); // Explicit cleanup
    }
}
```

**Transaction Integration:**
```rust
impl WriteTxn {
    pub fn new(db: &Db) -> Self {
        WriteTxn {
            arena: Arena::with_config(ArenaConfig {
                initial_chunk: 4096,
                max_chunk: 65536,
                alignment: 8,
            }),
            // ...
        }
    }

    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        // Allocate in transaction arena
        let key = self.arena.alloc_slice(key);
        let value = self.arena.alloc_slice(value);
        self.write_set.push((key, value));
        Ok(())
    }
}

impl Drop for WriteTxn {
    fn drop(&mut self) {
        // Arena automatically frees all allocations
    }
}
```

## Allocation Algorithms

### Thread-Local Caching with Shared Spillover

**Design:** Thread-local caches reduce contention, shared pool handles imbalance.

**Algorithm:**
```
acquire():
    if local_pool.has_object():
        return local_pool.pop()
    if shared_pool.has_object():
        return shared_pool.steal()
    return allocate_new()

release(obj):
    if local_pool.has_capacity():
        local_pool.push(obj)
    else if shared_pool.has_capacity():
        shared_pool.push(obj)
    else:
        drop(obj)  // Pool full, deallocate
```

**Contention Reduction:**
- Fast path: Single-threaded, lock-free local cache
- Slow path: Lock-based shared pool access
- Work stealing: Shared pool distributes excess

### Size Classes for B+Tree Nodes

**Design:** Pre-defined size classes for common node sizes.

**Classes:**
```rust
pub enum NodeSizeClass {
    Tiny = 128,      // Small internal nodes
    Small = 512,     // Medium internal nodes
    Medium = 1024,   // Full leaf nodes (4KB page)
    Large = 2048,    // Compressed leaf nodes
    XLarge = 4096,   // Full page nodes
}

pub struct BTreeNodePool {
    tiny: ObjectPool<NodeSize128>,
    small: ObjectPool<NodeSize512>,
    medium: ObjectPool<NodeSize1024>,
    large: ObjectPool<NodeSize2048>,
    xlarge: ObjectPool<NodeSize4096>,
}

impl BTreeNodePool {
    pub fn acquire(&self, size: usize) -> PooledNode {
        match size {
            0..=128 => self.tiny.acquire().map(|n| PooledNode::Tiny(n)),
            129..=512 => self.small.acquire().map(|n| PooledNode::Small(n)),
            513..=1024 => self.medium.acquire().map(|n| PooledNode::Medium(n)),
            1025..=2048 => self.large.acquire().map(|n| PooledNode::Large(n)),
            _ => self.xlarge.acquire().map(|n| PooledNode::XLarge(n)),
        }
    }
}
```

### Pre-warming Strategy

**Design:** Populate pools during initialization to avoid cold-start misses.

**Configuration:**
```rust
pub struct PrewarmConfig {
    /// Percentage of capacity to pre-warm
    pub percentage: usize,
    /// Pre-warm on pool creation
    pub on_init: bool,
    /// Background pre-warming (lazy)
    pub background: bool,
}

impl<T: Poolable> ObjectPool<T> {
    pub fn prewarm(&self, config: &PrewarmConfig) {
        let count = (self.config.shared_capacity * config.percentage) / 100;
        for _ in 0..count {
            let obj = T::new();
            self.shared.release(obj);
        }
    }
}
```

## Module Integration

### Pager Integration

```rust
pub struct Pager {
    buffer_pool: Arc<BufferPool>,
    page_cache: Arc<PageCache>,
}

impl Pager {
    pub fn new(config: PagerConfig) -> Result<Self> {
        let buffer_pool = Arc::new(BufferPool::new(BufferConfig {
            buffer_size: config.page_size,
            local_buffers: 32,
            shared_buffers: 1024,
            alignment: 512, // Direct I/O alignment
        }));

        Ok(Pager {
            buffer_pool,
            page_cache: Arc::new(PageCache::new(config.cache_capacity)),
        })
    }

    pub fn read_page(&self, id: PageId) -> Result<PageGuard> {
        if let Some(cached) = self.page_cache.get(id) {
            return Ok(cached);
        }

        let mut buffer = self.buffer_pool.acquire();
        self.storage.read_page(id, &mut buffer)?;

        Ok(self.page_cache.insert(id, buffer))
    }
}
```

### B+Tree Integration

```rust
pub struct BTree {
    node_pool: Arc<BTreeNodePool>,
}

impl BTree {
    pub fn insert(&self, key: &[u8], value: &[u8]) -> Result<()> {
        // Acquire node from pool
        let mut node = self.node_pool.acquire(self.node_size());

        // Split and rebalance as needed
        if node.is_full() {
            let new_node = self.node_pool.acquire(self.node_size());
            node.split(new_node)?;
        }

        Ok(())
    }
}

impl Drop for BTreeNode {
    fn drop(&mut self) {
        // Return to pool
        self.pool.release(self);
    }
}
```

### Transaction Integration

```rust
pub struct WriteTxn {
    arena: Arena,
    write_set: Vec<(&'static [u8], &'static [u8])>,
}

impl WriteTxn {
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        // Allocate in arena (never dropped until txn ends)
        let key = self.arena.alloc_slice(key);
        let value = self.arena.alloc_slice(value);
        self.write_set.push((key, value));
        Ok(())
    }

    pub fn commit(self) -> Result<()> {
        // Apply writes
        for (key, value) in self.write_set {
            self.btree.insert(key, value)?;
        }

        // Arena dropped here, bulk free all allocations
        Ok(())
    }
}
```

## Performance Targets

### Allocation Overhead

**Baseline (without pooling):**
- B+Tree node allocation: ~200ns (system allocator)
- Page buffer allocation: ~500ns (with alignment)
- Transaction context: ~150ns

**Target (with pooling):**
- B+Tree node acquire: <50ns (thread-local hit)
- Page buffer acquire: <100ns (thread-local hit)
- Transaction context: <30ns

**Improvement:** 4-10x reduction in allocation latency

### Cache Locality

**Metrics:**
- L1 cache hit rate improvement: +15%
- L2 cache hit rate improvement: +10%
- Reduced pointer chasing: 30% fewer memory accesses

**Measurement:**
```rust
#[bench]
fn bench_btree_node_pool_locality(b: &mut Bencher) {
    let pool = ObjectPool::<BTreeNode>::new(PoolConfig {
        local_capacity: 64,
        shared_capacity: 4096,
        prewarm: true,
    });

    b.iter(|| {
        let node = pool.acquire();
        // Simulate node operations
        black_box(node);
    });
}
```

### Throughput Impact

**Target Improvements:**
- Point operations: +20% throughput
- Range scans: +15% throughput
- Batch inserts: +30% throughput

**CI Thresholds:**
- Must not regress baseline throughput by >5%
- Must show >10% improvement in at least 2 benchmarks

### Memory Usage

**Baseline:**
- Peak memory: 1.2x working set
- Fragmentation: ~15% overhead

**Target:**
- Peak memory: 1.05x working set
- Fragmentation: <5% overhead

**Leak Detection:**
```rust
#[test]
fn test_pool_no_leaks() {
    let pool = ObjectPool::<BTreeNode>::new(PoolConfig {
        local_capacity: 64,
        shared_capacity: 4096,
        prewarm: true,
    });

    let initial = pool.stats().allocated;
    for _ in 0..10000 {
        let node = pool.acquire();
        drop(node);
    }
    let final = pool.stats().allocated;

    assert_eq!(initial, final, "Pool leaked objects");
}
```

## Testing Requirements

### Unit Tests

**Object Pool Tests:**
```rust
#[test]
fn test_object_pool_acquire_release() {
    let pool = ObjectPool::<TestNode>::new(PoolConfig {
        local_capacity: 4,
        shared_capacity: 16,
        prewarm: false,
    });

    let obj = pool.acquire();
    assert_eq!(obj.value, 0); // Reset state
    drop(obj);

    assert_eq!(pool.stats().local_available, 1);
}

#[test]
fn test_object_pool_exhaustion() {
    let pool = ObjectPool::<TestNode>::new(PoolConfig {
        local_capacity: 2,
        shared_capacity: 4,
        prewarm: true,
    });

    let mut objs = Vec::new();
    for _ in 0..6 {
        objs.push(pool.acquire());
    }

    // Should allocate new object
    assert_eq!(pool.stats().allocated, 7); // 6 prewarmed + 1 new
}
```

**Arena Tests:**
```rust
#[test]
fn test_arena_allocation() {
    let mut arena = Arena::with_config(ArenaConfig {
        initial_chunk: 1024,
        max_chunk: 4096,
        alignment: 8,
    });

    let val = arena.alloc(42usize);
    assert_eq!(*val, 42);
}

#[test]
fn test_arena_reset() {
    let mut arena = Arena::with_config(ArenaConfig {
        initial_chunk: 1024,
        max_chunk: 4096,
        alignment: 8,
    });

    for i in 0..100 {
        arena.alloc(i);
    }

    arena.reset();
    assert_eq!(arena.chunks.len(), 0);
}
```

### Concurrency Tests

```rust
#[test]
fn test_concurrent_pool_access() {
    let pool = Arc::new(ObjectPool::<TestNode>::new(PoolConfig {
        local_capacity: 32,
        shared_capacity: 1024,
        prewarm: true,
    }));

    let handles: Vec<_> = (0..8)
        .map(|_| {
            let pool = pool.clone();
            thread::spawn(move || {
                for _ in 0..10000 {
                    let obj = pool.acquire();
                    black_box(obj);
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().unwrap();
    }

    // All objects returned
    assert_eq!(pool.stats().total_available(), pool.stats().allocated);
}
```

### Property-Based Tests

```rust
#[quickcheck]
fn prop_pool_preserves_state(mut initial: TestNode) -> Result<(), Error> {
    let pool = ObjectPool::<TestNode>::new(PoolConfig {
        local_capacity: 4,
        shared_capacity: 16,
        prewarm: false,
    });

    // Mutate object
    initial.value = 42;

    // Return to pool
    pool.release(initial);

    // Acquire should return reset object
    let acquired = pool.acquire();
    assert_eq!(acquired.value, 0); // Reset value

    Ok(())
}
```

### Hardening Tests

```rust
#[test]
fn test_pool_stress() {
    let pool = ObjectPool::<TestNode>::new(PoolConfig {
        local_capacity: 64,
        shared_capacity: 4096,
        prewarm: true,
    });

    // Random acquire/release pattern
    let mut rng = StdRng::seed_from_u64(42);
    let mut held = Vec::new();

    for _ in 0..100000 {
        if rng.gen_bool(0.5) && !held.is_empty() {
            let idx = rng.gen_range(0..held.len());
            held.remove(idx);
        } else {
            held.push(pool.acquire());
        }
    }

    // All objects returned
    assert_eq!(pool.stats().total_available(), pool.stats().allocated);
}

#[test]
fn test_arena_alignment() {
    let mut arena = Arena::with_config(ArenaConfig {
        initial_chunk: 1024,
        max_chunk: 4096,
        alignment: 512,
    });

    let ptr1 = arena.alloc(1u8);
    let ptr2 = arena.alloc(2u8);

    // Check alignment
    assert_eq!(ptr1 as usize % 512, 0);
    assert_eq!(ptr2 as usize % 512, 0);
}
```

### Integration Tests

```rust
#[test]
fn test_btree_with_pool() {
    let pool = Arc::new(BTreeNodePool::new());
    let btree = BTree::new(pool.clone());

    // Insert 10000 keys
    for i in 0..10000 {
        btree.insert(format!("key{}", i).as_bytes(), vec![i as u8]).unwrap();
    }

    // Verify pool stats
    let stats = pool.stats();
    assert!(stats.total_acquired > 10000);
    assert_eq!(stats.total_available(), stats.allocated);
}

#[test]
fn test_transaction_arena_cleanup() {
    let db = Db::open_in_memory()?;

    {
        let mut txn = db.write_txn()?;
        for i in 0..1000 {
            txn.put(format!("key{}", i).as_bytes(), vec![i as u8])?;
        }
        txn.commit()?;
    } // Arena dropped here

    // Verify memory returned to OS
    let stats = db.memory_stats();
    assert!(stats.active_arenas == 0);
}
```

## Benchmarks

### Microbenchmarks

```rust
#[bench]
fn bench_pool_acquire_release(b: &mut Bencher) {
    let pool = ObjectPool::<BTreeNode>::new(PoolConfig {
        local_capacity: 64,
        shared_capacity: 4096,
        prewarm: true,
    });

    b.iter(|| {
        let obj = pool.acquire();
        black_box(obj);
    });
}

#[bench]
fn bench_arena_alloc(b: &mut Bencher) {
    let mut arena = Arena::with_config(ArenaConfig {
        initial_chunk: 4096,
        max_chunk: 65536,
        alignment: 8,
    });

    b.iter(|| {
        arena.alloc(black_box(42usize));
    });
}

#[bench]
fn bench_buffer_pool_acquire(b: &mut Bencher) {
    let pool = BufferPool::new(BufferConfig {
        buffer_size: 4096,
        local_buffers: 32,
        shared_buffers: 1024,
        alignment: 512,
    });

    b.iter(|| {
        let buffer = pool.acquire();
        black_box(buffer);
    });
}
```

### Macro Benchmarks

```rust
#[bench]
fn bench_btree_with_pool(b: &mut Bencher) {
    let pool = Arc::new(BTreeNodePool::new());
    let btree = BTree::new(pool);

    b.iter(|| {
        for i in 0..1000 {
            btree.insert(format!("key{}", i).as_bytes(), vec![i as u8]).unwrap();
        }
    });
}

#[bench]
fn bench_transaction_with_arena(b: &mut Bencher) {
    let db = Db::open_in_memory()?;

    b.iter(|| {
        let mut txn = db.write_txn().unwrap();
        for i in 0..100 {
            txn.put(format!("key{}", i).as_bytes(), vec![i as u8]).unwrap();
        }
        txn.commit().unwrap();
    });
}
```

## Rust Implementation Guidance

### Memory Safety

**Use `ManuallyDrop` for pooled objects:**
```rust
pub struct Pooled<T> {
    inner: ManuallyDrop<T>,
    pool: Weak<SharedPool<T>>,
}

// Prevent double-drop
impl<T> Clone for Pooled<T> {
    fn clone(&self) -> Self {
        // Allocate new object from pool instead of cloning
        self.pool.upgrade().unwrap().acquire()
    }
}
```

**Ensure proper alignment:**
```rust
pub struct BufferPool {
    _align: [u8; 0], // Force alignment
    inner: UnsafeCell<BufferPoolInner>,
}
```

### Concurrency

**Lock-free local pools:**
```rust
struct LocalPool<T> {
    objects: Cell<Vec<T>>,
    capacity: usize,
}

impl<T: Poolable> LocalPool<T> {
    fn acquire(&self) -> Option<T> {
        let mut objects = self.objects.take();
        let obj = objects.pop()?;
        self.objects.set(objects);
        Some(obj)
    }
}
```

**Shared pool with mutex:**
```rust
struct SharedPool<T> {
    objects: Mutex<Vec<T>>,
    capacity: usize,
}

impl<T: Poolable> SharedPool<T> {
    fn steal(&self) -> Option<T> {
        let mut objects = self.objects.lock().unwrap();
        objects.pop()
    }
}
```

### Debug Support

**Pool tracking for leaks:**
```rust
#[cfg(debug_assertions)]
pub struct TrackingPool<T> {
    inner: ObjectPool<T>,
    allocations: HashSet<usize>,
}

#[cfg(not(debug_assertions))]
pub struct TrackingPool<T> {
    inner: ObjectPool<T>,
}
```

**Statistics collection:**
```rust
pub struct PoolStats {
    pub local_available: usize,
    pub shared_available: usize,
    pub allocated: usize,
    pub total_acquired: AtomicUsize,
    pub total_released: AtomicUsize,
    pub local_hits: AtomicUsize,
    pub shared_hits: AtomicUsize,
    pub misses: AtomicUsize,
}
```

### Configuration

**Builder pattern for pools:**
```rust
impl ObjectPool<BufferNode> {
    pub fn builder() -> PoolBuilder<BufferNode> {
        PoolBuilder::default()
    }
}

pub struct PoolBuilder<T> {
    config: PoolConfig,
    _phantom: PhantomData<T>,
}

impl<T: Poolable> PoolBuilder<T> {
    pub fn local_capacity(mut self, cap: usize) -> Self {
        self.config.local_capacity = cap;
        self
    }

    pub fn prewarm(mut self, prewarm: bool) -> Self {
        self.config.prewarm = prewarm;
        self
    }

    pub fn build(self) -> ObjectPool<T> {
        ObjectPool::new(self.config)
    }
}
```

## Configuration Examples

### Development Profile

```rust
pub fn dev_pools() -> PoolConfig {
    PoolConfig {
        local_capacity: 32,
        shared_capacity: 512,
        prewarm: false,
    }
}
```

### Production Profile

```rust
pub fn prod_pools() -> PoolConfig {
    PoolConfig {
        local_capacity: 64,
        shared_capacity: 4096,
        prewarm: true,
    }
}
```

### Memory-Constrained Profile

```rust
pub fn lowmem_pools() -> PoolConfig {
    PoolConfig {
        local_capacity: 16,
        shared_capacity: 128,
        prewarm: false,
    }
}
```

## Monitoring

**Metrics to expose:**
```rust
pub struct PoolMetrics {
    pub pool_name: String,
    pub pool_type: PoolType,
    pub total_capacity: usize,
    pub in_use: usize,
    pub available: usize,
    pub utilization_pct: f64,
    pub hit_rate_pct: f64,
    pub avg_acquire_latency_ns: f64,
    pub avg_release_latency_ns: f64,
}
```

**Integration with observability:**
```rust
impl<T: Poolable> ObjectPool<T> {
    pub fn export_metrics(&self) -> PoolMetrics {
        let stats = self.stats();
        PoolMetrics {
            pool_name: std::any::type_name::<T>().to_string(),
            pool_type: PoolType::Object,
            total_capacity: stats.allocated,
            in_use: stats.allocated - stats.total_available(),
            available: stats.total_available(),
            utilization_pct: (stats.allocated - stats.total_available()) as f64 / stats.allocated as f64 * 100.0,
            hit_rate_pct: (stats.local_hits + stats.shared_hits) as f64 / (stats.local_hits + stats.shared_hits + stats.misses) as f64 * 100.0,
            avg_acquire_latency_ns: 0.0, // Collect via histogram
            avg_release_latency_ns: 0.0,
        }
    }
}
```

## Summary

Phase 13.3 completes the performance optimization trilogy by adding memory pooling to complement caching (13.1) and I/O batching (13.2). This specification provides:

1. **Three pool types:** Object pool (fixed-size), Buffer pool (I/O), Arena (scoped)
2. **Thread-local caching:** Fast path with shared spillover
3. **Module integration:** Pager, B+Tree, Transaction hooks
4. **Performance targets:** 4-10x allocation overhead reduction
5. **Comprehensive testing:** Unit, concurrency, property, hardening
6. **Rust guidance:** Memory safety, concurrency, debug support

**Next Phase:** Phase 13.4 - Lock-Free Data Structures (reduce contention in hot paths)
