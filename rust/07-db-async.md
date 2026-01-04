# Async API Considerations

## Purpose

This document describes considerations, trade-offs, and design decisions for an asynchronous NorthstarDB API. The current implementation is synchronous, but this document explores the requirements and challenges of adding async support using Rust's async/await ecosystem.

## Current State: Synchronous API

### Design Assumptions

**Synchronous Blocking Operations**:
- All database operations block the calling thread
- `db.begin_read()`, `db.begin_write()`, `txn.commit()` block until complete
- I/O operations (page reads, WAL flushes) block threads
- Simple, predictable control flow

**Thread Model**:
- Applications manage their own thread pools
- Each thread gets its own Db handle or shares via Arc
- NorthstarDB is thread-safe (Send + Sync) but doesn't spawn threads internally
- No background threads or internal executors

**Use Cases**:
- Thread-per-request servers (e.g., threaded web servers)
- Embedded applications with single-threaded or multi-threaded models
- CLI tools and synchronous applications
- Applications using their own async runtime (can run sync DB in thread pool)

**Benefits**:
- Simple implementation (no async complexity)
- Easy to understand and reason about
- Compatible with any runtime (sync or async)
- No dependency on async ecosystem

**Limitations**:
- Blocks thread during I/O (inefficient for high concurrency)
- Not ergonomic with async/await codebases
- Requires thread pool for concurrent operations in async applications
- Not ideal for IO-bound workloads with many concurrent operations

## Async Requirements

### Why Async API?

**High-Concurrency IO-Bound Workloads**:
- Thousands of concurrent database operations
- Minimal thread overhead (no 1:1 thread-per-operation)
- Efficient use of system resources
- Better latency under load

**Async Ecosystem Integration**:
- Applications using Tokio, async-std, smol
- Web frameworks (Actix-web, Rocket, Warp)
- gRPC and async HTTP servers
- Microservices with async messaging

**Use Cases**:
- Web servers with async request handling
- Microservices with high query concurrency
- Real-time applications (chat, gaming, streaming)
- Applications already using async/await

**Benefits**:
- Non-blocking I/O (operations don't block threads)
- Efficient resource usage (fewer threads, more concurrent operations)
- Better integration with async frameworks
- Improved throughput under high concurrency

**Trade-offs**:
- Increased complexity (async Rust learning curve)
- Runtime dependency (must choose Tokio, async-std, etc.)
- More complex error handling (async cancellation)
- Potential performance overhead (async state machines)
- Harder to reason about control flow

## Async Design Options

### Option 1: Dual API (Sync + Async)

**Description**: Provide both sync and async APIs side-by-side

**Sync API**: Existing Db, ReadTxn, WriteTxn (blocking)
**Async API**: AsyncDb, AsyncReadTxn, AsyncWriteTxn (non-blocking)

**Implementation**:
- Sync API uses std::fs::File (blocking I/O)
- Async API uses tokio::fs::File or async-std::fs::File (async I/O)
- Separate types, separate implementations
- Applications choose sync or async based on needs

**Benefits**:
- Maximum flexibility (users choose sync or async)
- No performance penalty for sync users
- Clean separation (no complexity pollution)
- Can optimize each API independently

**Drawbacks**:
- Code duplication (two implementations)
- Maintenance burden (sync and async must stay in sync)
- Complexity for contributors (two codebases to understand)
- Larger API surface (more types to learn)

**Example**:
```rust
// Sync API
let db = Db::open("db.ndb")?;
let txn = db.begin_read()?;
let value = txn.get(key)?;

// Async API
let db = AsyncDb::open("db.ndb").await?;
let txn = db.begin_read().await?;
let value = txn.get(key).await?;
```

### Option 2: Async-First with Sync Wrapper

**Description**: Implement core in async, provide sync wrapper via blocking calls

**Core**: Async implementation using Tokio/async-std
**Sync Wrapper**: blocking::Db that calls async API in thread pool

**Implementation**:
- AsyncDb uses tokio::fs::File internally
- blocking::Db spawns thread pool, runs async operations, blocks on result
- Single core implementation
- Sync API built on top of async

**Benefits**:
- Single core implementation (less duplication)
- Async gets first-class optimization
- Sync users still supported (via wrapper)
- Easier maintenance (core logic in one place)

**Drawbacks**:
- Sync users pay async overhead (state machine, thread pool)
- Blocking wrapper adds latency (thread hop)
- Runtime required even for sync users
- Potential performance regression for current sync users

**Example**:
```rust
// Async core
let db = AsyncDb::open("db.ndb").await?;
let txn = db.begin_read().await?;
let value = txn.get(key).await?;

// Sync wrapper (uses async internally)
let db = blocking::Db::open("db.ndb")?;  // Spawns runtime internally
let txn = db.begin_read()?;
let value = txn.get(key)?;
```

### Option 3: Runtime-Agnostic Async

**Description**: Support multiple async runtimes via trait abstraction

**Abstraction**: Define async traits for I/O operations
**Runtimes**: Implement traits for Tokio, async-std, smol

**Implementation**:
- Generic over async runtime
- Users provide runtime-specific implementation
- Or compile with feature flags (tokio, async-std)

**Benefits**:
- No runtime lock-in (users choose)
- Works with different async ecosystems
- Future-proof (new runtimes supported)

**Drawbacks**:
- Complex generics (harder to use)
- Trait object overhead
- More complex build configuration
- Limited by least-common-denominator of runtimes

**Example**:
```rust
// Runtime-agnostic
async fn open<R: Runtime>(path: &str) -> Result<Db<R>, Error>
where
    R: AsyncFile,
{
    // ...
}

// Tokio-specific
let db = open::<TokioRuntime>("db.ndb").await?;

// async-std-specific
let db = open::<AsyncStdRuntime>("db.ndb").await?;
```

### Option 4: Keep Sync Only, Run in Thread Pool

**Description**: No async API, recommend running sync DB in async thread pool

**Guidance**: Document how to use sync Db in async applications
**Pattern**: spawn threads or use `tokio::task::spawn_blocking`

**Benefits**:
- No async complexity in NorthstarDB
- Simpler codebase
- Users can still use in async apps (with thread pool)
- Zero overhead for sync users

**Drawbacks**:
- Async users have extra work (thread pool management)
- Not idiomatic for async ecosystem
- Thread-per-operation (less efficient)
- Doesn't solve the "I want native async" use case

**Example**:
```rust
// In async application, use spawn_blocking
let value = tokio::task::spawn_blocking(move || {
    let db = Db::open("db.ndb")?;
    let txn = db.begin_read()?;
    txn.get(key)
}).await??;
```

## Recommended Approach

### Phase 1: Document Sync-in-Async Pattern

**Status**: Current state (no async API)

**Guidance**: Document how to use sync Db in async applications
- Use `tokio::task::spawn_blocking` for blocking operations
- Use dedicated thread pool for database operations
- Example code for common async frameworks (Actix, Rocket, Warp)

**Rationale**:
- Sync API works well for many workloads
- Thread pool pattern is well-understood
- No complexity added to NorthstarDB
- Can add native async later if demand warrants

### Phase 2: Native Async API (Future)

**Status**: Planned, not implemented

**Approach**: Option 1 (Dual API: Sync + Async)

**Rationale**:
- Sync and async have different optimal I/O strategies
- No performance regression for sync users
- Clean separation (async users opt-in)
- Can optimize async API independently

**Implementation**:
- New types: AsyncDb, AsyncReadTxn, AsyncWriteTxn
- Async file I/O: tokio-uring or tokio::fs::File
- Async mutexes: tokio::sync::RwLock, tokio::sync::Mutex
- Feature flag: async-tokio, async-std (compile-time choice)

**API Design**:
```rust
// Async database
pub struct AsyncDb {
    inner: Arc<RwLock<AsyncDbInner>>,
    runtime: RuntimeHandle,
}

impl AsyncDb {
    pub async fn open<P: AsRef<Path>>(path: P) -> Result<Self, Error> {
        // Async file I/O
        let file = tokio::fs::File::open(path).await?;
        // ...
    }

    pub async fn begin_read(&self) -> Result<AsyncReadTxn, Error> {
        // Acquire lock asynchronously
        let inner = self.inner.read().await;
        // ...
    }

    pub async fn begin_write(&self) -> Result<AsyncWriteTxn, Error> {
        // Acquire lock asynchronously
        let inner = self.inner.write().await;
        // ...
    }
}

// Async read transaction
pub struct AsyncReadTxn<'db> {
    db: Arc<AsyncDb>,
    snapshot_lsn: Lsn,
    phantom: PhantomData<&'db AsyncDb>,
}

impl<'db> AsyncReadTxn<'db> {
    pub async fn get(&self, key: &[u8]) -> Result<Vec<u8>, Error> {
        // Async page read
        let page = self.db.pager.read_page(page_id).await?;
        // ...
    }

    pub async fn scan(&self, start: &[u8], end: &[u8]) -> Result<AsyncScanIterator, Error> {
        // ...
    }
}

// Async write transaction
pub struct AsyncWriteTxn<'db> {
    db: Arc<AsyncDb>,
    mutations: Vec<Mutation>,
    write_lock: tokio::sync::MutexGuard<'db, ()>,
}

impl<'db> AsyncWriteTxn<'db> {
    pub async fn get(&self, key: &[u8]) -> Result<Vec<u8>, Error> {
        // Check mutations, then async page read
        let page = self.db.pager.read_page(page_id).await?;
        // ...
    }

    pub async fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), Error> {
        // Buffer mutation
        self.mutations.push(Mutation::Put { key, value });
        Ok(())
    }

    pub async fn commit(self) -> Result<(), Error> {
        // Async two-phase commit
        self.db.wal.append(record).await?;
        self.db.btree.apply(&self.mutations).await?;
        self.db.pager.flush().await?;
        // ...
    }
}
```

## Async I/O Strategies

### Strategy 1: Tokio fs (Portability)

**Description**: Use tokio::fs::File for async file I/O

**Implementation**:
```rust
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

let mut file = File::open("db.ndb").await?;
let mut buffer = vec![0u8; page_size];
file.read_exact(&mut buffer).await?;
```

**Benefits**:
- Cross-platform (works on Linux, macOS, Windows)
- Mature, well-tested library
- Part of Tokio ecosystem
- Good enough performance for most workloads

**Drawbacks**:
- Thread pool for file I/O (not true async on disk)
- Limited by OS support (no io-uring on older Linux)
- Overhead from thread pool

**Performance**:
- Throughput: ~500K ops/sec (comparable to sync)
- Latency: Slightly higher than sync due to thread pool overhead
- Scalability: Good for concurrent workloads

### Strategy 2: Tokio-uring (Linux Only)

**Description**: Use tokio-uring for Linux io_uring-based async I/O

**Implementation**:
```rust
use tokio_uring::fs::File;

let file = File::open("db.ndb").await?;
let buffer = vec![0u8; page_size];
file.read_exact_at(buffer, offset).await?;
```

**Benefits**:
- True async I/O (no thread pool)
- Best performance on Linux
- Low latency, high throughput
- Efficient for many concurrent I/O operations

**Drawbacks**:
- Linux-only (kernel 5.1+)
- Not portable (macOS, Windows need different implementation)
- Less mature than tokio::fs
- Complexity (multiple code paths for different platforms)

**Performance**:
- Throughput: ~1M+ ops/sec (2x sync)
- Latency: Lower than sync (no thread hop)
- Scalability: Excellent for high concurrency

### Strategy 3: Async-std (Portability)

**Description**: Use async-std for async file I/O

**Implementation**:
```rust
use async_std::fs::File;
use async_std::prelude::*;

let mut file = File::open("db.ndb").await?;
let mut buffer = vec![0u8; page_size];
file.read(&mut buffer).await?;
```

**Benefits**:
- Cross-platform
- Part of async-std ecosystem
- More ergonomic than Tokio (some opinions)

**Drawbacks**:
- Smaller ecosystem than Tokio
- Less mature than Tokio
- Similar performance to tokio::fs

**Recommendation**: Start with tokio::fs for portability, add tokio-uring for Linux performance

## Async Concurrency Primitives

### Async Mutexes

**tokio::sync::Mutex**:
- Async-friendly (doesn't block thread)
- Awaiting lock yields to executor
- Use for: database state protection, write lock

**std::sync::Mutex**:
- Blocking (holds thread)
- Use in async code only if: guard held briefly, no .await while holding
- Use for: non-async code wrapped in spawn_blocking

**Async RwLock**:
- tokio::sync::RwLock for async read-write lock
- Multiple readers or one writer
- Use for: DbInner state protection

### Lock Ordering in Async

**Challenge**: Async locks can deadlock if not careful

**Deadlock Example**:
```rust
// Task 1:
let lock1 = db.lock1.write().await;
let lock2 = db.lock2.write().await;  // May deadlock if Task 2 holds lock2

// Task 2:
let lock2 = db.lock2.write().await;
let lock1 = db.lock1.write().await;  // May deadlock if Task 1 holds lock1
```

**Solution**: Consistent lock ordering
```rust
// Always acquire locks in same order:
let lock1 = db.lock1.write().await;
let lock2 = db.lock2.write().await;  // Safe (consistent order)
```

**Recommendation**:
- Single RwLock for DbInner (simpler)
- Or multiple locks with consistent ordering
- Avoid holding locks across .await points (drop lock before await)

### Async Channel for Events

**Use Case**: Background checkpoint thread signals completion

**Implementation**:
```rust
use tokio::sync::mpsc;

let (checkpoint_tx, mut checkpoint_rx) = mpsc::channel(1);

// Background task
tokio::spawn(async move {
    while let Some(trigger) = checkpoint_rx.recv().await {
        checkpoint().await;
        checkpoint_done_tx.send(()).await;
    }
});

// Trigger checkpoint
checkpoint_tx.send(()).await?;
```

## Async Cancellation

### Challenge: Async Operations Can Be Cancelled

**Example**:
```rust
let txn = db.begin_write().await?;
txn.put(key, value).await?;
txn.commit().await?;  // What if this is cancelled?
```

**Cancellation Safety**:
- Operation cancelled: Future dropped, cleanup may not run
- State inconsistent: Mutation buffered but not committed
- Resource leak: Locks held, file handles not closed

### Making Operations Cancellation-Safe

**Strategy 1: Use RAII Guards**
```rust
struct WriteGuard<'db> {
    db: &'db AsyncDb,
}

impl<'db> Drop for WriteGuard<'db> {
    fn drop(&mut self) {
        // Release lock on drop (cancellation-safe)
    }
}
```

**Strategy 2: Commute Operations**
```rust
async fn commit(mut self) -> Result<(), Error> {
    // Buffer mutations (cancellable until here)
    let mutations = self.mutations.clone();

    // Critical section: non-cancellable
    tokio::task::spawn_blocking(move || {
        // Synchronous commit (cannot be cancelled)
        sync_commit(&mutations)
    }).await?
}
```

**Strategy 3: Rollback on Drop**
```rust
impl<'db> Drop for AsyncWriteTxn<'db> {
    fn drop(&mut self) {
        // Rollback if not committed (cancellation-safe)
        if !self.committed {
            self.rollback_sync();
        }
    }
}
```

## Async Testing

### Testing Async Code

**tokio::test**:
```rust
#[cfg(test)]
mod tests {
    use tokio::test;

    #[test]
    async fn test_async_open() {
        let db = AsyncDb::open("test.db").await.unwrap();
        assert!(db.is_open());
    }

    #[test]
    async fn test_async_concurrent_reads() {
        let db = AsyncDb::open("test.db").await.unwrap();

        let mut handles = vec![];
        for i in 0..100 {
            let db = db.clone();
            handles.push(tokio::spawn(async move {
                let txn = db.begin_read().await.unwrap();
                txn.get(b"key").await
            }));
        }

        for handle in handles {
            handle.await.unwrap();
        }
    }
}
```

### Mock Async I/O

**Strategy**: Use async traits for abstraction
```rust
#[async_trait]
pub trait AsyncFile: Send + Sync {
    async fn read(&self, offset: u64, buf: &mut [u8]) -> Result<usize, Error>;
    async fn write(&self, offset: u64, buf: &[u8]) -> Result<usize, Error>;
    async fn sync(&self) -> Result<(), Error>;
}

// Production implementation
pub struct TokioFile {
    file: tokio::fs::File,
}

#[async_trait]
impl AsyncFile for TokioFile {
    async fn read(&self, offset: u64, buf: &mut [u8]) -> Result<usize, Error> {
        // ...
    }
}

// Test mock
pub struct MockFile {
    data: Vec<u8>,
}

#[async_trait]
impl AsyncFile for MockFile {
    async fn read(&self, offset: u64, buf: &mut [u8]) -> Result<usize, Error> {
        // Read from in-memory buffer (no I/O)
    }
}
```

## Performance Comparison

### Expected Performance Characteristics

**Synchronous API**:
- Throughput: ~500K operations/sec (single thread)
- Concurrency: Scales with threads (1 thread = 500K ops/sec)
- Latency: ~100μs per operation (cache hit)
- Thread usage: 1:1 with concurrent operations

**Asynchronous API (tokio::fs)**:
- Throughput: ~500K operations/sec (similar to sync)
- Concurrency: Scales better with many concurrent ops
- Latency: ~150μs per operation (thread pool overhead)
- Thread usage: Fewer threads than concurrent ops

**Asynchronous API (tokio-uring)**:
- Throughput: ~1M+ operations/sec (2x sync)
- Concurrency: Excellent scaling with thousands of concurrent ops
- Latency: ~80μs per operation (lower than sync)
- Thread usage: Minimal (no thread pool for I/O)

**Recommendation**:
- Use sync API for simple workloads, embedded systems
- Use async API for high-concurrency web services, microservices
- Use tokio-uring for maximum performance on Linux

## Migration Path

### From Sync to Async

**Step 1: Add Async Types Alongside Sync**
- Create AsyncDb, AsyncReadTxn, AsyncWriteTxn
- Keep Db, ReadTxn, WriteTxn unchanged
- Feature flag: async (disabled by default)

**Step 2: Implement Async Internals**
- AsyncPager with async file I/O
- AsyncWAL with async flush
- Async locks (tokio::sync::RwLock, Mutex)

**Step 3: Expose Async API**
- Export async types when async feature enabled
- Documentation for async API
- Examples for common async frameworks

**Step 4: Optimize**
- Add tokio-uring support
- Benchmark async vs sync
- Optimize hot paths

**Backward Compatibility**:
- Sync API unchanged (no breaking changes)
- Async users opt-in via feature flag
- Both APIs can coexist indefinitely

## Trade-offs Summary

### Complexity vs Ergonomics

| Aspect | Sync API | Async API |
|--------|----------|-----------|
| Implementation Complexity | Low | High |
| User Complexity | Low | Medium |
| Ecosystem Compatibility | Universal | Tokio/async-std |
| Learning Curve | Shallow | Steep |
| Debugging | Easy | Harder |

### Performance vs Concurrency

| Aspect | Sync API | Async API |
|--------|----------|-----------|
| Single-Threaded Throughput | High | High |
| Multi-Threaded Throughput | Scales with threads | Scales better |
| Thread Usage | 1:1 with ops | Fewer threads |
| Latency | Low | Low (lower with io-uring) |
| Memory Usage | Medium | Lower (fewer threads) |

### Use Case Fit

| Use Case | Recommended API |
|----------|-----------------|
| Embedded systems | Sync |
| CLI tools | Sync |
| Thread-per-request servers | Sync |
| Async web services | Async |
| Microservices | Async |
| Real-time applications | Async |
| High-concurrency workloads | Async |

## Conclusion

### Current Recommendation

**Phase 1**: Keep sync API, document async usage pattern
- No async implementation yet
- Provide examples for using sync Db in async apps
- Gather feedback from async users

**Phase 2**: Add native async API if demand warrants
- Dual API approach (sync + async)
- Tokio-first with tokio::fs
- Feature-gated async support
- Optimize for async ecosystem

### Decision Criteria

**Add Async API When**:
- Clear user demand (GitHub issues, community requests)
- Performance benchmarks show benefit
- Async ecosystem stabilizes (async traits mature)
- Resources available for implementation and maintenance

**Stay Sync-Only When**:
- Sync API meets performance needs
- Users comfortable with thread pool pattern
- Limited resources for dual implementation
- Async Rust ecosystem still evolving

## References

- Tokio documentation: https://tokio.rs/
- async-std documentation: https://async.rs/
- tokio-uring: https://github.com/tokio-rs/tokio-uring
- Async Rust book: https://rust-lang.github.io/async-book/
