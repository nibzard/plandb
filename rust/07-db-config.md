# Database Configuration

## Purpose

This document describes all database configuration options, their validation rules, default values, performance implications, and interaction effects. Configuration controls database behavior at open time and affects performance, durability, memory usage, and recovery characteristics.

## Configuration Overview

### Configuration Philosophy

**Sensible Defaults**: All options have reasonable defaults for typical workloads
- Default configuration optimized for general-purpose use
- No required configuration for basic usage
- Advanced options available for tuning

**Validation at Build Time**: All configuration validated before database open
- Invalid configuration rejected immediately
- Clear error messages explaining what's wrong
- No partial initialization with invalid config

**Immutable After Open**: Configuration cannot be changed after database open
- Options validated once at construction
- No runtime reconfiguration
- Predictable behavior throughout database lifetime
- To change config: close and reopen with new config

**Builder Pattern**: Fluent, type-safe API for configuration
- Chainable setter methods
- Compile-time type checking
- Clear API ergonomics

## Configuration Options

### Option 1: cache_size

**Type**: usize
**Default**: 1024 pages
**Range**: 16 to 1,048,576 (2^20)
**Validation**: Must be power of 2

**Description**: Number of pages to cache in memory

**Purpose**: Controls Pager cache size, affecting read performance and memory usage

**Memory Calculation**:
- Total cache memory = cache_size * page_size
- Default: 1024 pages * 16KB = 16MB
- Maximum: 1,048,576 pages * 64KB = 64GB

**Performance Implications**:
- Larger cache → Higher cache hit rate → Better read performance
- Larger cache → More memory usage
- Smaller cache → More cache misses → More disk I/O
- Optimal size depends on working set size

**Use Cases**:
- Small cache (16-256 pages): Memory-constrained environments, small databases
- Medium cache (512-4096 pages): General-purpose workloads
- Large cache (8192-65536 pages): High-performance servers, large working sets
- Very large cache (131072+ pages): In-memory databases with disk persistence

**Validation Rules**:
1. Must be >= 16 (minimum useful cache)
2. Must be power of 2 (required for efficient hash table sizing)
3. Must be <= 1,048,576 (practical limit, ~64GB with 64KB pages)
4. If invalid: ConfigError::InvalidCacheSize { provided, min, max, reason }

**Trade-offs**:
- Memory vs performance: Larger cache uses more memory but faster reads
- Cache warming: Large cache takes longer to warm up
- TLB pressure: Very large cache may cause TLB misses

**Examples**:
```rust
// Small cache (4MB with 16KB pages)
.cache_size(256)

// Default cache (16MB)
.cache_size(1024)

// Large cache (256MB)
.cache_size(16384)

// Very large cache (4GB)
.cache_size(262144)
```

**Implementation Notes**:
- Stored in Config struct
- Passed to Pager::new() during open
- Affects Pager buffer pool allocation
- Cannot be changed after open (requires close and reopen)

### Option 2: page_size

**Type**: usize
**Default**: 16384 bytes (16KB)
**Range**: 4096 to 65536 (2^12 to 2^16)
**Validation**: Must be power of 2

**Description**: Database page size in bytes

**Purpose**: Controls I/O granularity, B+Tree fanout, and storage overhead

**B+Tree Implications**:
- Larger pages → Higher fanout → Shorter trees → Fewer disk reads
- Smaller pages → Lower fanout → Taller trees → More disk reads
- Page size affects maximum key count per node

**I/O Implications**:
- Larger pages → Fewer I/O operations for large scans
- Smaller pages → More fine-grained I/O, better for random reads
- Optimal size matches filesystem block size (usually 4KB)

**Memory Implications**:
- Larger pages → More memory per cached page
- Cache memory = cache_size * page_size
- Internal fragmentation proportional to page size

**Use Cases**:
- 4KB pages: Flash storage, small key-value pairs, memory-constrained
- 8KB pages: SSD storage, balanced workload
- 16KB pages: Default, HDD storage, general-purpose (optimal for most)
- 32KB pages: Large values, sequential workloads
- 64KB pages: Very large values, archival storage, HDD arrays

**Validation Rules**:
1. Must be power of 2
2. Must be >= 4096 (4KB, typical filesystem block)
3. Must be <= 65536 (64KB, practical limit)
4. Must match existing database if reopening (cannot change)
5. If invalid: ConfigError::InvalidPageSize { provided, min, max, reason }
6. If mismatch: ConfigError::PageSizeMismatch { config, database }

**Trade-offs**:
- Tree height: Smaller pages → taller trees → more lookups
- I/O granularity: Larger pages → coarser granularity
- Memory overhead: Larger pages → more internal fragmentation
- Update amplification: Larger pages → more data rewritten per update

**Constraints**:
- Cannot change after database created (stored in FileHeader)
- Must match filesystem block size for best performance (usually 4KB multiple)
- Must fit key_size + value_size + overhead in page

**Examples**:
```rust
// Small pages (4KB)
.page_size(4096)

// Default pages (16KB)
.page_size(16384)

// Large pages (32KB)
.page_size(32768)

// Very large pages (64KB)
.page_size(65536)
```

**Implementation Notes**:
- Stored in FileHeader (persists across closes)
- Validated on open: must match FileHeader page_size
- Affects B+Tree node capacity (fanout calculation)
- Passed to Pager during initialization
- Cannot be changed for existing database

### Option 3: wal_size_threshold

**Type**: u64
**Default**: 100,000,000 bytes (100MB)
**Range**: 1,048,576 (1MB) to 1,099,511,627,776 (1TB)
**Validation**: Must be >= 1MB

**Description**: WAL size threshold that triggers automatic checkpoint

**Purpose**: Controls frequency of automatic checkpoints, affecting recovery time and write amplification

**Checkpoint Trigger**:
- When WAL size exceeds threshold, auto-checkpoint triggered
- After checkpoint, WAL truncated to empty
- Reduces recovery time (less WAL to replay)

**Recovery Time Implications**:
- Larger threshold → Larger WAL → Longer recovery
- Smaller threshold → Smaller WAL → Faster recovery
- Recovery throughput: ~100K operations/second
- Example: 1GB WAL with 1M operations → ~10 seconds recovery

**Write Amplification Implications**:
- Smaller threshold → More frequent checkpoints → More write amplification
- Larger threshold → Less frequent checkpoints → Less write amplification
- Checkpoint flushes all dirty pages, may rewrite unchanged data

**Use Cases**:
- Small threshold (10-50MB): Fast recovery, acceptable write amplification
- Medium threshold (100-500MB): Balanced, default
- Large threshold (1-10GB): Maximum throughput, slower recovery
- Very large threshold (100GB+): Batch workloads, infrequent restarts

**Validation Rules**:
1. Must be >= 1,048,576 (1MB, minimum useful threshold)
2. Must be <= 1TB (practical limit)
3. If invalid: ConfigError::InvalidWalThreshold { provided, min, max }

**Trade-offs**:
- Recovery speed vs write amplification: Smaller threshold → faster recovery but more write amp
- Commit latency: Larger threshold → fewer checkpoints → less commit latency impact
- Disk space: Larger threshold → more disk space for WAL

**Interaction with Other Options**:
- auto_checkpoint must be true for threshold to take effect
- If auto_checkpoint is false, threshold ignored (manual checkpoint only)
- FlushPolicy::Immediate may trigger more frequent checkpoints

**Examples**:
```rust
// Small threshold (10MB, fast recovery)
.wal_size_threshold(10_000_000)

// Default threshold (100MB)
.wal_size_threshold(100_000_000)

// Large threshold (1GB)
.wal_size_threshold(1_000_000_000)

// Very large threshold (10GB)
.wal_size_threshold(10_000_000_000)
```

**Implementation Notes**:
- Stored in Config, not persisted
- Checked after each WAL append (in WAL::append)
- Checkpoint triggered by Pager when threshold exceeded
- Can be changed across opens (not persisted)

### Option 4: flush_policy

**Type**: FlushPolicy enum
**Default**: FlushPolicy::Batch { max_batch_ms: 10 }
**Variants**: Immediate, Batch, Periodic

**Description**: WAL flush policy controlling durability-latency trade-off

**Purpose**: Controls when WAL records are flushed to disk, affecting transaction durability and latency

**FlushPolicy Variants**:

**FlushPolicy::Immediate**:
- Flush WAL on every commit
- Maximum durability (every commit persisted)
- Minimum latency (no batching)
- Lowest throughput (fsync per transaction)
- Use case: Financial transactions, critical data

**FlushPolicy::Batch { max_batch_ms: u64 }**:
- Buffer commits for up to max_batch_ms milliseconds
- Flush when buffer full or timeout expires
- Balanced durability and throughput
- Default: 10ms batch window
- Use case: General-purpose workloads

**FlushPolicy::Periodic { interval_ms: u64 }**:
- Flush WAL every interval_ms milliseconds
- Maximum throughput (infrequent flushes)
- Maximum latency (commits delayed up to interval)
- Risk: Up to interval_ms of data loss on crash
- Use case: Analytics, bulk load, non-critical data

**Validation Rules**:
1. Immediate: No parameters (always valid)
2. Batch: max_batch_ms must be >= 1 and <= 10000 (10 seconds)
3. Periodic: interval_ms must be >= 10 and <= 60000 (1 minute)
4. If invalid: ConfigError::InvalidFlushPolicy { policy, reason }

**Performance Implications**:
- Immediate: ~1000 transactions/sec (fsync limited)
- Batch(10ms): ~10,000-50,000 transactions/sec
- Periodic(100ms): ~50,000-100,000 transactions/sec

**Durability Implications**:
- Immediate: No data loss on crash (committed = persisted)
- Batch(10ms): Up to 10ms of data loss
- Periodic(100ms): Up to 100ms of data loss

**Trade-offs**:
- Durability vs throughput: Immediate = durable but slow, Periodic = fast but less durable
- Latency vs batching: Immediate = low latency, Batch = balanced
- Data loss window: Immediate = 0, Batch = max_batch_ms, Periodic = interval_ms

**Examples**:
```rust
// Immediate flush (maximum durability)
.flush_policy(FlushPolicy::Immediate)

// Default batch (10ms window)
.flush_policy(FlushPolicy::Batch { max_batch_ms: 10 })

// Aggressive batch (100ms window)
.flush_policy(FlushPolicy::Batch { max_batch_ms: 100 })

// Periodic flush (100ms interval)
.flush_policy(FlushPolicy::Periodic { interval_ms: 100 })
```

**Implementation Notes**:
- Stored in Config
- Passed to WAL during initialization
- WAL manages flush timer and buffer
- Can be changed across opens
- Requires background thread for Batch and Periodic (future implementation)

### Option 5: snapshot_retention

**Type**: RetentionPolicy enum
**Default**: RetentionPolicy::CountBased { min_keep: 100 }
**Variants**: CountBased, AgeBased, Hybrid, Manual

**Description**: Snapshot garbage collection policy controlling MVCC history retention

**Purpose**: Controls how many historical snapshots are retained, affecting storage overhead and time-travel query capability

**RetentionPolicy Variants**:

**RetentionPolicy::CountBased { min_keep: usize }**:
- Keep at least min_keep snapshots
- Oldest snapshots deleted when count exceeds min_keep
- Default: 100 snapshots
- Use case: General-purpose, predictable memory overhead

**RetentionPolicy::AgeBased { max_age_seconds: u64 }**:
- Keep snapshots newer than max_age_seconds
- Snapshots older than max_age_seconds deleted
- Use case: Time-based retention (e.g., 1 hour history)

**RetentionPolicy::Hybrid { min_keep: usize, max_age_seconds: u64 }**:
- Keep at least min_keep snapshots AND newer than max_age_seconds
- Combines count and age retention
- Ensures minimum history regardless of age
- Use case: Flexible retention with guarantees

**RetentionPolicy::Manual**:
- No automatic snapshot cleanup
- User must trigger cleanup explicitly
- Snapshots accumulate indefinitely
- Use case: Application-controlled retention, debugging

**Validation Rules**:
1. CountBased: min_keep must be >= 1 and <= 1,000,000
2. AgeBased: max_age_seconds must be >= 60 (1 minute)
3. Hybrid: Both min_keep and max_age_seconds must be valid
4. Manual: No parameters (always valid)
5. If invalid: ConfigError::InvalidRetentionPolicy { policy, reason }

**Storage Implications**:
- More snapshots → More B+Tree versions retained → More disk usage
- Each snapshot retains root page and all unique pages
- Old pages freed when no snapshot references them
- Manual retention → unbounded growth (monitor required)

**Time-Travel Query Implications**:
- More snapshots → Further back in time you can query
- begin_read_at(txn_id) requires snapshot to exist
- If snapshot deleted, SnapshotNotFound error

**Performance Implications**:
- More snapshots → Slower page GC (more snapshots to check)
- More snapshots → Larger SnapshotRegistry
- Minimal impact on read/write performance

**Use Cases**:
- CountBased(10): Minimal history, low overhead
- CountBased(100): Default, reasonable history
- CountBased(10000): Long history for analytics
- AgeBased(3600): Keep 1 hour of snapshots
- Hybrid(100, 3600): At least 100 snapshots or 1 hour
- Manual: Application-managed, debugging

**Trade-offs**:
- Storage vs query capability: More snapshots = more storage but longer history
- GC overhead: More snapshots = slower cleanup
- Memory: More snapshots = larger registry

**Examples**:
```rust
// Minimal retention (10 snapshots)
.snapshot_retention(RetentionPolicy::CountBased { min_keep: 10 })

// Default retention (100 snapshots)
.snapshot_retention(RetentionPolicy::CountBased { min_keep: 100 })

// Large retention (10000 snapshots)
.snapshot_retention(RetentionPolicy::CountBased { min_keep: 10000 })

// Time-based retention (1 hour)
.snapshot_retention(RetentionPolicy::AgeBased { max_age_seconds: 3600 })

// Hybrid retention (100 snapshots or 1 hour, whichever is more)
.snapshot_retention(RetentionPolicy::Hybrid {
    min_keep: 100,
    max_age_seconds: 3600
})

// Manual retention (no automatic cleanup)
.snapshot_retention(RetentionPolicy::Manual)
```

**Implementation Notes**:
- Stored in Config
- Passed to SnapshotRegistry during initialization
- Registry runs GC on commit or periodically
- Can be changed across opens
- Manual retention: User calls db.cleanup_snapshots() explicitly

### Option 6: auto_checkpoint

**Type**: bool
**Default**: true
**Range**: true or false

**Description**: Enable or disable automatic checkpointing

**Purpose**: Controls whether WAL size threshold triggers automatic checkpoints

**Behavior**:
- true: Checkpoint triggered when WAL exceeds wal_size_threshold
- false: WAL grows indefinitely (until manual checkpoint)
- Manual checkpoint via db.checkpoint() still works

**Use Cases**:
- true (default): Automatic management, hands-off operation
- false: Manual checkpoint control, batch workloads, custom checkpoint logic

**Validation Rules**:
- Always valid (boolean has no invalid values)

**Interaction with Other Options**:
- Works with wal_size_threshold (threshold checked only if auto_checkpoint is true)
- If auto_checkpoint is false, threshold ignored
- Manual checkpoint always available via db.checkpoint()

**Performance Implications**:
- true: Periodic write amplification from checkpoint
- false: WAL grows large, recovery time increases, no write amp from checkpoint
- Trade-off: Write amplification vs recovery time

**Disk Space Implications**:
- true: WAL bounded by wal_size_threshold
- false: WAL unbounded, may consume significant disk space
- Monitor WAL size if auto_checkpoint is false

**Examples**:
```rust
// Enable automatic checkpoint (default)
.auto_checkpoint(true)

// Disable automatic checkpoint (manual only)
.auto_checkpoint(false)
```

**Implementation Notes**:
- Stored in Config
- Checked by WAL after append
- If true and WAL size > threshold, trigger checkpoint
- Can be changed across opens
- Manual checkpoint always available

### Option 7: compression

**Type**: Compression enum
**Default**: Compression::None
**Variants**: None, Lz4, Zstd, Snappy

**Description**: Value compression algorithm

**Purpose**: Reduce storage size and I/O bandwidth at cost of CPU

**Compression Variants**:

**Compression::None**:
- No compression (default)
- Zero CPU overhead
- Maximum compatibility
- Use case: CPU-constrained, already-compressed data

**Compression::Lz4**:
- LZ4 fast compression
- Compression ratio: ~2-3x
- Speed: ~500 MB/s compress, ~2 GB/s decompress
- CPU overhead: Low
- Use case: Balanced compression and speed

**Compression::Zstd**:
- Zstandard compression
- Compression ratio: ~3-5x
- Speed: ~100 MB/s compress, ~300 MB/s decompress
- CPU overhead: Medium
- Use case: Maximum compression, CPU available

**Compression::Snappy**:
- Snappy compression
- Compression ratio: ~2-3x
- Speed: ~300 MB/s compress, ~1 GB/s decompress
- CPU overhead: Low
- Use case: Compatible with other systems

**Validation Rules**:
1. None: Always available
2. Lz4, Zstd, Snappy: Must be enabled at compile-time (feature flags)
3. If requested algorithm not compiled: ConfigError::CompressionUnavailable { algorithm }

**Performance Implications**:
- Compression CPU cost: Paid on write (compress) and read (decompress)
- Compression I/O benefit: Fewer pages read/written
- Net benefit: Depends on data compressibility and CPU vs I/O bottleneck
- Compressible data (text, JSON): High benefit
- Incompressible data (already compressed, random): Low benefit, overhead

**Storage Implications**:
- Compressed values use fewer pages
- B+Tree nodes hold more compressed values
- Tree may be shorter (more entries per node)

**Use Cases**:
- None: General-purpose, CPU-constrained
- Lz4: Default compression choice, good balance
- Zstd: Maximum compression for text/JSON
- Snappy: Compatibility with other systems

**Trade-offs**:
- CPU vs storage: Compression trades CPU for storage
- Latency: Compression adds latency to writes
- Throughput: Compression may reduce throughput (CPU bottleneck)

**Examples**:
```rust
// No compression (default)
.compression(Compression::None)

// LZ4 compression (balanced)
.compression(Compression::Lz4)

// Zstd compression (maximum)
.compression(Compression::Zstd)
```

**Implementation Notes**:
- Stored in Config
- Passed to B+Tree during initialization
- B+Tree compresses values before storage, decompresses on read
- Can be changed across opens (but all values must be recompressed)
- Feature-gated: cargo features --features lz4, zstd, snappy
- Compression applied per-value, not per-page

## Configuration Validation

### Validation Order

**Step 1: Path Validation**
- Must be set via builder.path()
- Cannot be None
- Error: ConfigError::PathNotSet

**Step 2: Cache Size Validation**
- Must be power of 2
- Must be >= 16
- Error: ConfigError::InvalidCacheSize

**Step 3: Page Size Validation**
- Must be power of 2
- Must be in range [4096, 65536]
- Error: ConfigError::InvalidPageSize

**Step 4: WAL Threshold Validation**
- Must be >= 1MB
- Error: ConfigError::InvalidWalThreshold

**Step 5: Flush Policy Validation**
- Batch: max_batch_ms in range [1, 10000]
- Periodic: interval_ms in range [10, 60000]
- Error: ConfigError::InvalidFlushPolicy

**Step 6: Snapshot Retention Validation**
- CountBased: min_keep in range [1, 1000000]
- AgeBased: max_age_seconds >= 60
- Hybrid: Both conditions
- Error: ConfigError::InvalidRetentionPolicy

**Step 7: Compression Validation**
- Must be available at compile-time
- Error: ConfigError::CompressionUnavailable

**Step 8: Page Size Match Validation** (on open)
- Must match existing database page size
- Error: ConfigError::PageSizeMismatch

### Validation Errors

**ConfigError::PathNotSet**:
- Description: Database path not set
- Cause: builder.build() called without .path()
- Fix: Call .path("db.ndb") before .build()

**ConfigError::InvalidCacheSize { provided, min, max, reason }**:
- Description: Cache size invalid
- Cause: Not power of 2 or < 16 or > 1,048,576
- Fix: Use power of 2 in valid range
- Example: "cache_size 100 is not a power of 2"

**ConfigError::InvalidPageSize { provided, min, max, reason }**:
- Description: Page size invalid
- Cause: Not power of 2 or not in [4096, 65536]
- Fix: Use power of 2 in valid range
- Example: "page_size 10000 is not a power of 2"

**ConfigError::PageSizeMismatch { config, database }**:
- Description: Page size doesn't match existing database
- Cause: Database created with different page_size
- Fix: Use correct page_size for existing database
- Example: "config page_size 16384, database page_size 32768"

**ConfigError::InvalidWalThreshold { provided, min, max }**:
- Description: WAL size threshold invalid
- Cause: < 1MB
- Fix: Use threshold >= 1,048,576

**ConfigError::InvalidFlushPolicy { policy, reason }**:
- Description: Flush policy parameters invalid
- Cause: Batch max_batch_ms or Periodic interval_ms out of range
- Fix: Use valid parameters

**ConfigError::InvalidRetentionPolicy { policy, reason }**:
- Description: Snapshot retention policy invalid
- Cause: min_keep or max_age_seconds out of range
- Fix: Use valid parameters

**ConfigError::CompressionUnavailable { algorithm }**:
- Description: Compression algorithm not compiled
- Cause: Feature flag not enabled
- Fix: Enable feature flag or use Compression::None
- Example: "Lz4 compression unavailable, compile with --features lz4"

## Configuration Presets

### Preset 1: Memory-Constrained

```rust
Db::builder()
    .path("db.ndb")
    .cache_size(128)          // 2MB cache (16KB pages)
    .page_size(4096)           // 4KB pages
    .wal_size_threshold(10_000_000)  // 10MB WAL
    .flush_policy(FlushPolicy::Batch { max_batch_ms: 10 })
    .snapshot_retention(RetentionPolicy::CountBased { min_keep: 10 })
    .auto_checkpoint(true)
    .compression(Compression::None)
    .build()
```

**Characteristics**:
- Low memory footprint (~5MB)
- Suitable for embedded systems
- Fast recovery (small WAL)
- Minimal snapshot history

### Preset 2: Default (General-Purpose)

```rust
Db::builder()
    .path("db.ndb")
    .build()  // All defaults
```

**Characteristics**:
- 16MB cache (1024 pages * 16KB)
- Balanced performance
- Suitable for most workloads
- Reasonable recovery time

### Preset 3: High-Performance

```rust
Db::builder()
    .path("db.ndb")
    .cache_size(65536)         // 1GB cache (16KB pages)
    .page_size(32768)          // 32KB pages
    .wal_size_threshold(1_000_000_000)  // 1GB WAL
    .flush_policy(FlushPolicy::Batch { max_batch_ms: 100 })
    .snapshot_retention(RetentionPolicy::CountBased { min_keep: 1000 })
    .auto_checkpoint(true)
    .compression(Compression::Lz4)
    .build()
```

**Characteristics**:
- Large cache (~2GB total)
- High throughput
- Slower recovery (large WAL)
- Long snapshot history

### Preset 4: Maximum Durability

```rust
Db::builder()
    .path("db.ndb")
    .cache_size(4096)          // 64MB cache
    .page_size(16384)          // 16KB pages
    .wal_size_threshold(50_000_000)  // 50MB WAL
    .flush_policy(FlushPolicy::Immediate)  // Flush every commit
    .snapshot_retention(RetentionPolicy::CountBased { min_keep: 100 })
    .auto_checkpoint(true)
    .compression(Compression::None)
    .build()
```

**Characteristics**:
- Immediate flush on every commit
- Maximum durability (no data loss)
- Lower throughput (fsync per commit)
- Suitable for financial transactions

### Preset 5: Analytics / Batch Load

```rust
Db::builder()
    .path("db.ndb")
    .cache_size(262144)        // 4GB cache
    .page_size(65536)          // 64KB pages
    .wal_size_threshold(10_000_000_000)  // 10GB WAL
    .flush_policy(FlushPolicy::Periodic { interval_ms: 1000 })
    .snapshot_retention(RetentionPolicy::Manual)  // Keep all history
    .auto_checkpoint(false)    // Manual checkpoint only
    .compression(Compression::Zstd)
    .build()
```

**Characteristics**:
- Maximum throughput (periodic flush, large pages)
- Large cache, minimal disk I/O
- High compression (Zstd)
- Manual checkpoint control
- Long recovery time (large WAL)

## Configuration Builder

### Builder Type Definition

```rust
pub struct DbBuilder {
    config: Config,
    path: Option<PathBuf>,
}

impl DbBuilder {
    pub fn new() -> Self { ... }
    pub fn path<P: AsRef<Path>>(mut self, path: P) -> Self { ... }
    pub fn cache_size(mut self, size: usize) -> Self { ... }
    pub fn page_size(mut self, size: usize) -> Self { ... }
    pub fn wal_size_threshold(mut self, size: u64) -> Self { ... }
    pub fn flush_policy(mut self, policy: FlushPolicy) -> Self { ... }
    pub fn snapshot_retention(mut self, policy: RetentionPolicy) -> Self { ... }
    pub fn auto_checkpoint(mut self, enabled: bool) -> Self { ... }
    pub fn compression(mut self, algo: Compression) -> Self { ... }
    pub fn build(self) -> Result<Db, Error> { ... }
}
```

### Builder Pattern Benefits

**Fluent API**: Chainable methods for readable configuration
```rust
let db = Db::builder()
    .path("mydb.ndb")
    .cache_size(2048)
    .page_size(32768)
    .build()?;
```

**Compile-Time Type Safety**: Invalid configurations fail at compile or build time
```rust
// Compilation error: path() requires valid path type
Db::builder().path(123).build();  // ERROR

// Build-time error: cache_size validated
Db::builder().path("db.ndb").cache_size(100).build()?;  // ERROR: not power of 2
```

**Ergonomic Defaults**: No need to specify all options
```rust
// All defaults, just path required
let db = Db::builder().path("db.ndb").build()?;
```

**Clear Error Messages**: Validation errors explain what's wrong
```rust
// Error: "cache_size 100 is not a power of 2 (must be power of 2, >= 16)"
Db::builder().path("db.ndb").cache_size(100).build()?;
```

## Rust Implementation Guidance

### Module Structure

```
northstar-core/src/db/
├── mod.rs          # DbBuilder definition
├── config.rs       # Config, FlushPolicy, RetentionPolicy, Compression
└── error.rs        # ConfigError variants
```

### Type Definitions

**Config**:
```rust
#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub cache_size: usize,
    pub page_size: usize,
    pub wal_size_threshold: u64,
    pub flush_policy: FlushPolicy,
    pub snapshot_retention: RetentionPolicy,
    pub auto_checkpoint: bool,
    pub compression: Compression,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            cache_size: 1024,
            page_size: 16384,
            wal_size_threshold: 100_000_000,
            flush_policy: FlushPolicy::Batch { max_batch_ms: 10 },
            snapshot_retention: RetentionPolicy::CountBased { min_keep: 100 },
            auto_checkpoint: true,
            compression: Compression::None,
        }
    }
}
```

**FlushPolicy**:
```rust
#[derive(Clone, Debug, PartialEq)]
pub enum FlushPolicy {
    Immediate,
    Batch { max_batch_ms: u64 },
    Periodic { interval_ms: u64 },
}
```

**RetentionPolicy**:
```rust
#[derive(Clone, Debug, PartialEq)]
pub enum RetentionPolicy {
    CountBased { min_keep: usize },
    AgeBased { max_age_seconds: u64 },
    Hybrid { min_keep: usize, max_age_seconds: u64 },
    Manual,
}
```

**Compression**:
```rust
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Compression {
    None,
    #[cfg(feature = "lz4")]
    Lz4,
    #[cfg(feature = "zstd")]
    Zstd,
    #[cfg(feature = "snappy")]
    Snappy,
}
```

### Validation Implementation

**Config::validate()**:
```rust
impl Config {
    pub fn validate(&self) -> Result<(), ConfigError> {
        // Validate cache_size
        if !self.cache_size.is_power_of_two() || self.cache_size < 16 {
            return Err(ConfigError::InvalidCacheSize {
                provided: self.cache_size,
                min: 16,
                max: 1_048_576,
                reason: "must be power of 2 and >= 16".into(),
            });
        }

        // Validate page_size
        if !self.page_size.is_power_of_two() || self.page_size < 4096 || self.page_size > 65536 {
            return Err(ConfigError::InvalidPageSize {
                provided: self.page_size,
                min: 4096,
                max: 65536,
                reason: "must be power of 2 and between 4096 and 65536".into(),
            });
        }

        // Validate wal_size_threshold
        if self.wal_size_threshold < 1_048_576 {
            return Err(ConfigError::InvalidWalThreshold {
                provided: self.wal_size_threshold,
                min: 1_048_576,
                max: u64::MAX,
            });
        }

        // Validate flush_policy
        match &self.flush_policy {
            FlushPolicy::Batch { max_batch_ms } if *max_batch_ms == 0 || *max_batch_ms > 10000 => {
                return Err(ConfigError::InvalidFlushPolicy {
                    policy: self.flush_policy.clone(),
                    reason: "max_batch_ms must be between 1 and 10000".into(),
                });
            }
            FlushPolicy::Periodic { interval_ms } if *interval_ms < 10 || *interval_ms > 60000 => {
                return Err(ConfigError::InvalidFlushPolicy {
                    policy: self.flush_policy.clone(),
                    reason: "interval_ms must be between 10 and 60000".into(),
                });
            }
            _ => {}
        }

        // Validate snapshot_retention
        match &self.snapshot_retention {
            RetentionPolicy::CountBased { min_keep } if *min_keep < 1 || *min_keep > 1_000_000 => {
                return Err(ConfigError::InvalidRetentionPolicy {
                    policy: self.snapshot_retention.clone(),
                    reason: "min_keep must be between 1 and 1000000".into(),
                });
            }
            RetentionPolicy::AgeBased { max_age_seconds } if *max_age_seconds < 60 => {
                return Err(ConfigError::InvalidRetentionPolicy {
                    policy: self.snapshot_retention.clone(),
                    reason: "max_age_seconds must be >= 60".into(),
                });
            }
            RetentionPolicy::Hybrid { min_keep, max_age_seconds }
                if *min_keep < 1 || *min_keep > 1_000_000 || *max_age_seconds < 60 => {
                return Err(ConfigError::InvalidRetentionPolicy {
                    policy: self.snapshot_retention.clone(),
                    reason: "invalid hybrid parameters".into(),
                });
            }
            _ => {}
        }

        // Validate compression (compile-time check via feature flags)
        // (Handled by enum variants, no runtime check needed)

        Ok(())
    }
}
```

### Builder Implementation

**DbBuilder::build()**:
```rust
impl DbBuilder {
    pub fn build(self) -> Result<Db, Error> {
        // Validate path is set
        let path = self.path.ok_or(Error::ConfigError(ConfigError::PathNotSet))?;

        // Validate configuration
        self.config.validate()?;

        // Open database with validated configuration
        Db::open_internal(path, self.config)
    }
}
```

### Testing Strategy

**Unit tests needed for**:
- Config::default() returns valid configuration
- Config::validate() accepts all valid configurations
- Config::validate() rejects all invalid configurations
- Config::validate() provides clear error messages
- DbBuilder with all options set correctly
- DbBuilder with missing path (PathNotSet error)
- DbBuilder with invalid cache_size
- DbBuilder with invalid page_size
- DbBuilder with invalid wal_size_threshold
- DbBuilder with invalid flush_policy
- DbBuilder with invalid snapshot_retention
- DbBuilder with unavailable compression
- Configuration presets are valid

**Property tests needed for**:
- All valid configurations pass validation
- All invalid configurations fail validation with specific error
- Default configuration is always valid
- Config round-trip (serialize/deserialize) preserves values

**Integration tests needed for**:
- Open database with each preset configuration
- Open database with custom configuration
- Configuration affects database behavior (cache size, page size)
- Invalid configuration prevents database open
- Page size mismatch detected on reopen

**Performance tests needed for**:
- Cache size affects read performance
- Page size affects tree height and I/O
- Flush policy affects throughput and latency
- Compression affects storage size and CPU usage
- Snapshot retention affects memory usage
