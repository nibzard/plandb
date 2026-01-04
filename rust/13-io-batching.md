# I/O Batching

## Purpose

I/O batching system for NorthstarDB that minimizes disk I/O operations and maximizes throughput through coalescing adjacent operations. Batching reduces system call overhead, amortizes sync costs across multiple operations, and enables sequential access optimization. The system supports write coalescing, read-ahead prefetching, and adaptive batching thresholds based on workload patterns.

## Types

### IoOperation

**Description**: Represents a single I/O operation to be batched.

**Fields**:
- `op_type: IoOpType` - Whether this is a read or write operation
- `page_id: PageId` - Target page identifier
- `offset: u64` - File offset in bytes (page_id * page_size)
- `data: Vec<u8>` - Data to write (for writes) or buffer to fill (for reads)
- `priority: IoPriority` - Operation priority for scheduling
- `callback: Option<IoCallback>` - Completion callback for async operations
- `deadline: Option<Instant>` - Optional deadline for time-sensitive operations

**Size**: Variable (48 bytes base + data size)

**Invariants**:
- `offset` must be aligned to page boundary
- `data.len()` must equal page_size for writes
- `priority` influences batching order but not correctness
- `deadline` if present must be in the future

### IoOpType

**Description**: Enumeration of I/O operation types.

**Variants**:
- `Read` - Read page from disk into memory
- `Write` - Write page from memory to disk
- `Sync` - Flush OS buffers to stable storage
- `Prefetch` - Speculative read-ahead for future access

**Default**: `Write` for batching operations, `Prefetch` for background tasks

### IoPriority

**Description**: Priority level for I/O operation scheduling.

**Variants**:
- `Critical` - User-visible operation (get/put), must complete quickly
- `High` - Transaction commit, WAL append
- `Normal` - Background operations, checkpointing
- `Low` - Prefetch, opportunistic operations

**Default**: `Normal` for most operations, `Critical` for user API calls

### BatchBuffer

**Description**: Accumulates pending I/O operations before execution.

**Fields**:
- `operations: Vec<IoOperation>` - Pending operations in batch
- `total_bytes: usize` - Total bytes in current batch
- `byte_threshold: usize` - Flush when batch reaches this size (default: 256KB)
- `count_threshold: usize` - Flush when batch has this many ops (default: 16)
- `timeout: Duration` - Maximum time to hold batch before flush (default: 10ms)
- `last_flush: Instant` - Timestamp of last batch flush
- `sync_pending: bool` - Whether unflushed data requires fsync

**Size**: Variable (typically ~200 bytes + operation storage)

**Invariants**:
- `total_bytes` equals sum of all operation data sizes
- `total_bytes <= byte_threshold` before flush
- `operations.len() <= count_threshold` before flush
- `last_flush` always in the past
- `sync_pending` true when any write operation is batched

### BatchConfig

**Description**: Configuration parameters for batching behavior.

**Fields**:
- `write_batch_size: usize` - Maximum bytes per write batch (default: 256KB)
- `write_batch_count: usize` - Maximum operations per write batch (default: 16)
- `read_batch_size: usize` - Maximum bytes per read batch (default: 512KB)
- `read_batch_count: usize` - Maximum operations per read batch (default: 32)
- `flush_timeout: Duration` - Maximum time to hold batch (default: 10ms)
- `enable_coalescing: bool` - Merge adjacent operations (default: true)
- `enable_reordering: bool` - Optimize for sequential access (default: true)
- `enable_prefetch: bool` - Automatic read-ahead (default: true)
- `prefetch_distance: usize` - Pages to prefetch ahead (default: 4)
- `max_pending_batches: usize` - Concurrent in-flight batches (default: 8)

**Validation Rules**:
- `write_batch_size` must be >= page_size (16KB minimum)
- `read_batch_size` must be >= page_size (16KB minimum)
- `write_batch_count` must be >= 2
- `read_batch_count` must be >= 2
- `flush_timeout` must be >= 1 millisecond
- `prefetch_distance` must be >= 1 if prefetch enabled

### BatchStats

**Description**: Performance metrics for batching system.

**Fields**:
- `batches_flushed: AtomicU64` - Total batches executed
- `operations_batched: AtomicU64` - Total operations batched
- `bytes_batched: AtomicU64` - Total bytes processed via batching
- `coalesced_operations: AtomicU64` - Operations merged via coalescing
- `prefetch_hits: AtomicU64` - Prefetch operations that were used
- `prefetch_misses: AtomicU64` - Prefetch operations that wasted I/O
- `avg_batch_size: AtomicU64` - Rolling average batch size
- `avg_batch_latency: AtomicU64` - Rolling average flush duration (microseconds)
- `current_pending: AtomicUsize` - Currently pending operations
- `flushes_by_timeout: AtomicU64` - Batches flushed due to timeout
- `flushes_by_size: AtomicU64` - Batches flushed due to size threshold
- `flushes_by_count: AtomicU64` - Batches flushed due to count threshold

**Derived Metrics**:
- `batch_efficiency = operations_batched / batches_flushed` - Average ops per batch
- `coalescing_rate = coalesced_operations / operations_batched` - Merge success rate
- `prefetch_accuracy = prefetch_hits / (prefetch_hits + prefetch_misses)` - Read-ahead effectiveness

### IoBatch

**Description**: Represents a batched I/O operation ready for execution.

**Fields**:
- `operations: Vec<IoOperation>` - Operations in this batch
- `start_offset: u64` - Starting file offset of batch
- `end_offset: u64` - Ending file offset of batch (start + total size)
- `is_sequential: bool` - Whether operations are sequential (optimized path)
- `priority: IoPriority` - Priority of this batch (highest of member ops)

**Size**: Variable (depends on operations in batch)

**Invariants**:
- `start_offset <= end_offset`
- Operations are sorted by offset for sequential access
- `is_sequential` true when operations are contiguous
- All operations in batch share same `op_type` (all reads or all writes)

### BatchManager

**Description**: Central coordinator for I/O batching system.

**Fields**:
- `write_buffer: Arc<BatchBuffer>` - Pending write operations
- `read_buffer: Arc<BatchBuffer>` - Pending read operations
- `config: Arc<BatchConfig>` - Shared configuration
- `stats: Arc<BatchStats>` - Shared statistics
- `pending_batches: VecDeque<IoBatch>` - In-flight batches
- `flush_task: Option<JoinHandle<()>>` - Background flush task handle
- `prefetch_state: PrefetchState` - Read-ahead tracking state

**Size**: Configuration-dependent (typically ~1KB)

**Invariants**:
- At most one background flush task running
- `pending_batches.len() <= config.max_pending_batches`
- Operations grouped by type (reads vs writes in separate buffers)

### PrefetchState

**Description**: Tracks sequential access patterns for read-ahead.

**Fields**:
- `last_page_id: Option<PageId>` - Most recently accessed page
- `sequential_count: usize` - Number of sequential accesses detected
- `prefetch_issued: HashSet<PageId>` - Pages already prefetched
- `direction: PrefetchDirection` - Forward or backward scan

**PrefetchDirection**:
- `Forward` - Increasing page IDs (common for table scans)
- `Backward` - Decreasing page IDs (less common, reverse scans)
- `None` - No detectable pattern (random access)

**Invariants**:
- `sequential_count` increments on sequential access, resets on random access
- Prefetch triggered when `sequential_count >= threshold` (default: 3)
- `prefetch_issued` cleared after batch flush to avoid stale data

## Functions

### batch_add(manager: &BatchManager, op: IoOperation) -> Result<(), BatchError>

**Purpose**: Add operation to appropriate batch buffer.

**Parameters**:
- manager: Batch manager coordinating batching
- op: Operation to add to batch

**Returns**: Result indicating success or error

**Algorithm**:
1. Determine target buffer based on `op.op_type` (write buffer or read buffer)
2. Check buffer capacity:
   - Calculate new size: `buffer.total_bytes + op.data.len()`
   - Calculate new count: `buffer.operations.len() + 1`
   - If new size > byte_threshold OR new count > count_threshold:
     - Trigger flush of existing buffer
     - Reset buffer after flush
3. Check timeout:
   - Calculate time since `buffer.last_flush`
   - If elapsed > buffer.timeout:
     - Trigger flush even if under thresholds
     - Reset buffer after flush
4. Apply coalescing if enabled and this is a write:
   - Check if any existing operation has overlapping offset
   - If overlap found: Merge or replace (later operation wins)
   - Increment `coalesced_operations` stat
5. Add operation to buffer:
   - Push operation to `buffer.operations`
   - Update `buffer.total_bytes`
   - Update `stats.operations_batched`
   - Update `stats.bytes_batched`
   - Set `sync_pending = true` if operation is write
6. Check if flush should trigger immediately:
   - Critical priority operations may bypass batching
   - If sync requested and buffer has operations, flush
7. Return success

**Error Conditions**:
- `BatchError::BufferFull`: Cannot fit operation even after flush (operation too large)
- `BatchError::InvalidOffset`: Operation offset not page-aligned
- `BatchError::InvalidSize`: Operation data size mismatch

**Concurrency**: Locks target buffer. Multiple threads can batch concurrently.

### batch_flush(buffer: &mut BatchBuffer, stats: &BatchStats) -> Result<usize, BatchError>

**Purpose**: Execute batched I/O operations.

**Parameters**:
- buffer: Buffer containing operations to flush
- stats: Statistics to update

**Returns**: Number of operations flushed

**Algorithm**:
1. Check if buffer is empty:
   - If no operations: Return 0 (nothing to do)
2. Create IoBatch from buffer operations:
   - Sort operations by offset for sequential access
   - Check if operations are contiguous (sequential optimization)
   - Determine batch priority (highest of member ops)
3. Update flush statistics:
   - Determine flush reason (timeout, size, count, or explicit)
   - Increment `batches_flushed`
   - Update flush reason counters
4. Execute batch:
   - If batch is sequential and large enough:
     - Use single contiguous readv/writev call
   - If batch is non-sequential:
     - Execute individual operations in sorted order
   - For sync operations: Call fsync after writes
5. Clear buffer:
   - Remove all operations
   - Reset `total_bytes` to 0
   - Update `last_flush` to now
   - Reset `sync_pending` to false
6. Return number of operations flushed

**Error Conditions**:
- `BatchError::IoError`: Underlying I/O operation failed
- `BatchError::PartialFlush`: Some operations succeeded, some failed

**Concurrency**: Exclusive access to buffer during flush.

### batch_merge(existing: &IoOperation, new: &IoOperation) -> Option<IoOperation>

**Purpose**: Merge two adjacent or overlapping operations into single operation.

**Parameters**:
- existing: Previously batched operation
- new: New operation to merge

**Returns**: Some(merged operation) if mergeable, None if not

**Algorithm**:
1. Check if operations are mergeable:
   - Must have same `op_type`
   - Must have compatible offsets (adjacent or overlapping)
   - Must not have critical priority (bypass batching)
2. Calculate overlap:
   - If new offset equals existing offset: Full overlap, replace existing
   - If new offset is adjacent (existing.end + page_size): Merge into single span
   - If new offset within existing span: Overlap, newer data wins
3. Create merged operation:
   - For full overlap: Return new operation (replace)
   - For adjacent: Create operation spanning both ranges
   - For partial overlap: Split or update as appropriate
4. Return merged operation or None if not mergeable

**Error Conditions**: None (returns None for non-mergeable operations)

**Concurrency**: Pure function, no locks needed.

### batch_sort(operations: &mut Vec<IoOperation>) -> bool

**Purpose**: Sort operations for optimal I/O access pattern.

**Parameters**:
- operations: Operations to sort (modified in place)

**Returns**: True if operations are sequential after sorting

**Algorithm**:
1. Sort operations by offset (ascending order)
2. Check contiguity:
   - Initialize `is_sequential = true`
   - For each adjacent pair of operations:
     - If next offset != current offset + current size:
       - Set `is_sequential = false`
       - Break loop
3. Return `is_sequential`

**Error Conditions**: None

**Concurrency**: Operates on provided vector, caller manages synchronization.

### batch_cancel(buffer: &mut BatchBuffer, page_id: PageId) -> bool

**Purpose**: Remove pending operation for specific page (cancellation).

**Parameters**:
- buffer: Buffer to modify
- page_id: Page ID of operation to cancel

**Returns**: True if operation was found and removed

**Algorithm**:
1. Search buffer operations for matching page_id
2. If found:
   - Remove operation from buffer
   - Update `total_bytes` (subtract operation size)
   - Return true
3. If not found:
   - Return false (already flushed or never added)

**Use Case**: Transaction rollback, prefetch cancellation, query timeout

**Error Conditions**: None

**Concurrency**: Exclusive access to buffer required.

### prefetch_detect(manager: &BatchManager, page_id: PageId) -> Option<Vec<PageId>>

**Purpose**: Detect sequential access pattern and suggest prefetch pages.

**Parameters**:
- manager: Batch manager with prefetch state
- page_id: Most recently accessed page

**Returns**: Pages to prefetch, or None if no pattern detected

**Algorithm**:
1. Check if prefetch is enabled in config
2. Analyze access pattern:
   - If `last_page_id` is None: First access, initialize state
   - If `page_id == last_page_id + 1`: Forward sequential access
     - Increment `sequential_count`
     - Set direction to Forward
   - If `page_id == last_page_id - 1`: Backward sequential access
     - Increment `sequential_count`
     - Set direction to Backward
   - Else: Random access
     - Reset `sequential_count` to 0
     - Clear `prefetch_issued`
3. Check threshold:
   - If `sequential_count >= 3` (configurable):
     - Generate prefetch list based on direction
     - For forward: page_id + 1 to page_id + prefetch_distance
     - For backward: page_id - 1 to page_id - prefetch_distance
     - Filter out already prefetched pages
     - Return prefetch list
   - Else:
     - Update `last_page_id`
     - Return None
4. Update prefetch state with new page_id

**Error Conditions**: None

**Concurrency**: Locks prefetch state.

### batch_execute(batch: IoBatch) -> Result<Vec<IoResult>, BatchError>

**Purpose**: Execute a prepared batch of I/O operations.

**Parameters**:
- batch: Batch to execute

**Returns**: Results for each operation in order

**Algorithm**:
1. Check batch optimization:
   - If `batch.is_sequential`:
     - Calculate contiguous span from `start_offset` to `end_offset`
     - Use single readv or writev system call
     - Split contiguous buffer into per-operation results
   - Else:
     - Execute each operation individually
     - Use pread/pwrite for position-independent I/O
2. For sync operations:
   - After all writes complete: Call fsync
   - Mark all operations as durable
3. Collect results:
   - Create result for each operation (success or error)
   - Preserve operation order for callbacks
4. Trigger callbacks if present:
   - For each operation with callback:
     - Invoke callback with operation result
5. Return result vector

**Error Conditions**:
- `BatchError::IoError`: Underlying I/O failed
- `BatchError::SyncFailed`: fsync failed after writes

**Concurrency**: Executes batch, may block on I/O.

## Invariants

- **Capacity Limits**: Batches never exceed configured byte or count thresholds
- **Timeout Guarantees**: Operations held no longer than configured timeout
- **Order Preservation**: Batch operations execute in offset order, not arrival order
- **Merge Correctness**: Coalesced operations preserve latest data for overlapping ranges
- **Sequential Detection**: Prefetch only triggers on confirmed sequential access
- **Sync Semantics**: Sync operations always execute fsync after pending writes
- **Atomic Flush**: Batch flush is all-or-nothing (partial returns error)
- **Priority Respect**: Critical operations bypass normal batching thresholds
- **Statistics Accuracy**: Counters updated atomically and monotonically

## Dependencies

**Uses**:
- `crate::pager::Pager` - For underlying I/O operations
- `crate::types::PageId` - For page identification
- `crate::config::Config` - For batch size configuration
- `std::collections::VecDeque` - For pending batch queue
- `std::time::{Instant, Duration}` - For timeout tracking
- `atomic` - For lock-free statistics

**Used by**:
- `crate::pager::Pager` - Integrates batching for write path
- `crate::wal::Wal` - Integrates batching for WAL append
- `crate::cache::PageCache` - Integrates read-ahead prefetching

## Rust Implementation Guidance

### Module Structure

```
northstar-core/src/batch/
├── mod.rs           # Batch module exports
├── types.rs         # IoOperation, IoBatch, IoPriority enums
├── buffer.rs        # BatchBuffer implementation
├── config.rs        # BatchConfig and validation
├── stats.rs         # BatchStats and metrics
├── manager.rs       # BatchManager coordinator
├── prefetch.rs      # PrefetchState and pattern detection
└── execute.rs       # Batch execution logic
```

### Type Definitions

**IoOperation**: Struct with `op_type`, `page_id`, `data`, `priority`, `callback`, `deadline`.
```rust
pub struct IoOperation {
    pub op_type: IoOpType,
    pub page_id: PageId,
    pub offset: u64,
    pub data: Vec<u8>,
    pub priority: IoPriority,
    pub callback: Option<Box<dyn FnOnce(IoResult) + Send>>,
    pub deadline: Option<Instant>,
}
```

**BatchBuffer**: Struct with operations vector, thresholds, timeout tracking.
```rust
pub struct BatchBuffer {
    operations: Vec<IoOperation>,
    total_bytes: usize,
    byte_threshold: usize,
    count_threshold: usize,
    timeout: Duration,
    last_flush: Instant,
    sync_pending: bool,
}
```

**BatchConfig**: Struct with sizing, tuning, and feature flags.
```rust
#[derive(Clone)]
pub struct BatchConfig {
    pub write_batch_size: usize,
    pub write_batch_count: usize,
    pub read_batch_size: usize,
    pub read_batch_count: usize,
    pub flush_timeout: Duration,
    pub enable_coalescing: bool,
    pub enable_reordering: bool,
    pub enable_prefetch: bool,
    pub prefetch_distance: usize,
    pub max_pending_batches: usize,
}
```

**BatchStats**: Struct with `AtomicU64` and `AtomicUsize` for lock-free metrics.
```rust
pub struct BatchStats {
    pub batches_flushed: AtomicU64,
    pub operations_batched: AtomicU64,
    pub bytes_batched: AtomicU64,
    pub coalesced_operations: AtomicU64,
    pub prefetch_hits: AtomicU64,
    pub prefetch_misses: AtomicU64,
    pub avg_batch_size: AtomicU64,
    pub avg_batch_latency: AtomicU64,
    pub current_pending: AtomicUsize,
    pub flushes_by_timeout: AtomicU64,
    pub flushes_by_size: AtomicU64,
    pub flushes_by_count: AtomicU64,
}
```

### Concurrency

- **Separate Read/Write Buffers**: Read and write operations batch independently to avoid read-write lock contention.
- **Mutex per Buffer**: Each `BatchBuffer` protected by `parking_lot::Mutex` for performance.
- **Atomic Statistics**: All counters use `AtomicU64` for lock-free reads.
- **Background Flush Task**: Single background task monitors timeouts and flushes expired batches.
- **Lock Ordering**: Always lock write buffer before read buffer to prevent deadlock.

### Key Decisions

**Batch Sizes**: Default to 256KB for writes (16 pages) and 512KB for reads (32 pages).
- Rationale: Large enough to amortize syscall overhead, small enough to avoid excessive latency
- Write batches smaller than read batches to minimize write amplification
- Read batches larger to maximize sequential throughput

**Timeout Strategy**: 10ms default flush timeout.
- Short enough to bound latency for interactive workloads
- Long enough to accumulate multiple operations in typical workloads
- Configurable for latency-sensitive vs throughput-sensitive deployments

**Coalescing Policy**: Later writes to same offset replace earlier writes.
- Rationale: MVCC copy-on-write means latest version is only one that matters
- Avoids writing stale data that will be immediately overwritten
- Simplifies crash recovery (only latest data persisted)

**Prefetch Threshold**: 3 sequential accesses before triggering prefetch.
- Rationale: Avoids wasteful I/O for random access patterns
- 3 accesses is strong signal of sequential scan
- Configurable based on workload characteristics

**Reordering**: Always sort by offset regardless of arrival order.
- Rationale: Disk seeks dominate I/O cost, sequential access much faster
- Safe for reads (no dependencies between reads)
- Safe for writes (pages are independent, WAL serializes transactions)
- Critical for throughput optimization

### Implementation Notes

**Step 1: Buffer Management**
- Use separate buffers for reads and writes
- Check both size and count thresholds before adding
- Flush before adding if either threshold exceeded
- Check timeout on every add operation

**Step 2: Coalescing Logic**
- Linear search for overlapping operations (acceptable for small batch sizes)
- For each existing operation: check if offsets overlap or are adjacent
- On overlap: newer operation replaces older (MVCC semantics)
- On adjacent: merge into single span if sequential optimization enabled

**Step 3: Sorting for Sequential Access**
- Sort operations by offset before execution
- Check if operations form contiguous range (sequential optimization)
- Use readv/writev for sequential batches (single syscall)
- Fall back to individual pread/pwrite for non-sequential

**Step 4: Prefetch Detection**
- Track last accessed page and access direction
- Increment counter on sequential access, reset on random access
- Trigger prefetch when counter reaches threshold (default 3)
- Issue prefetch operations with low priority

**Step 5: Background Flush Task**
- Spawn task on BatchManager creation
- Task loops forever, checking buffer timeouts
- Sleep for configurable interval (1ms default)
- Flush buffers that exceeded timeout
- Wake on any buffer modification for immediate response

**Step 6: Statistics Collection**
- Update counters on every operation add
- Record flush reason (timeout, size, count, explicit)
- Calculate rolling averages for batch size and latency
- Use atomic operations for lock-free reads

**Step 7: Error Handling**
- Partial batch failure: Return error with successful results
- I/O error during batch: Mark remaining operations as failed
- Sync failure: Return error but batch may have partially succeeded
- Caller must handle partial success semantics

### Testing Requirements

**Unit Tests**:
- Test batch add triggers flush at size threshold
- Test batch add triggers flush at count threshold
- Test batch add triggers flush at timeout
- Test coalescing merges overlapping operations
- Test sorting produces sequential access pattern
- Test prefetch detection on sequential access
- Test cancellation removes correct operation
- Test statistics update correctly

**Integration Tests**:
- Test batch flush executes all operations
- Test sequential batch uses readv/writev
- Test non-sequential batch uses pread/pwrite
- Test fsync called after write batch
- Test callbacks invoked on completion
- Test critical priority bypasses batching
- Test background task flushes timed-out batches

**Performance Tests**:
- Benchmark batch write vs individual write throughput (target: 2x improvement)
- Benchmark batch read vs individual read throughput (target: 2x improvement)
- Measure coalescing effectiveness (merge rate)
- Measure prefetch accuracy (hit rate)
- Profile lock contention under high concurrency
- Measure latency impact of batching (p50, p99)

**Property Tests**:
- Batch size never exceeds configured threshold
- Operations in batch sorted by offset
- Sequential batch has contiguous offsets
- Coalesced operations preserve latest data
- Flush reason correctly identified

### Example Usage

```rust
// Create batch manager with config
let config = BatchConfig::default()
    .write_batch_size(256 * 1024) // 256KB
    .flush_timeout(Duration::from_millis(10))
    .enable_prefetch(true);
let manager = BatchManager::new(config, pager)?;

// Batch write operations
let op1 = IoOperation::write(page_id_1, data_1, IoPriority::Critical);
batch_add(&manager, op1)?;

let op2 = IoOperation::write(page_id_2, data_2, IoPriority::Normal);
batch_add(&manager, op2)?;

// Operations held in buffer until threshold or timeout
// Then automatically flushed via background task or explicit flush

// Explicit flush (if needed)
batch_flush(&mut manager.write_buffer)?;

// Read with automatic prefetch
let page = pager.read_page(page_id_5)?;
// Prefetch automatically triggered for pages 6, 7, 8, 9
```

### Performance Targets

**Write Throughput**: Batched writes should achieve 2x throughput vs individual writes
- Target: 100K pages/sec batched vs 50K pages/sec individual
- Measure: Write 10,000 pages with and without batching

**Read Throughput**: Batched reads should achieve 2x throughput for sequential scans
- Target: 200K pages/sec batched vs 100K pages/sec individual
- Measure: Sequential scan of 100,000 pages

**Latency Impact**: Batching should not add more than 10ms p99 latency
- Target: p99 latency increase < 10ms vs unbatched
- Measure: Latency distribution of single-page operations

**Coalescing Rate**: Should merge 10-20% of operations in write-heavy workloads
- Target: 15% coalescing rate
- Measure: Ratio of coalesced operations to total operations

**Prefetch Accuracy**: Should achieve 70%+ hit rate for sequential scans
- Target: 75% of prefetched pages actually used
- Measure: Prefetch hits / (prefetch hits + prefetch misses)

### Integration Points

**Pager Integration**:
- `Pager::write_page` adds operation to write batch instead of direct pwrite
- `Pager::read_page` checks read batch for pending operation before direct pread
- `Pager::sync` triggers flush of write batch before fsync

**WAL Integration**:
- `Wal::append_commit_record` uses write batching for append operations
- WAL sync triggers batch flush before fsync

**Cache Integration**:
- `PageCache::get` triggers prefetch detection on cache miss
- Prefetch operations added to read batch with low priority

**Transaction Integration**:
- `WriteTxn::commit` triggers batch flush before sync
- Transaction rollback cancels pending batch operations
