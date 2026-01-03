# Configuration Types

## Purpose

Configuration types define the parameters that control NorthstarDB behavior, including benchmark execution settings, database tuning options, and system-level preferences. These types provide structured, validated configuration with sensible defaults, builder pattern support for fluent API construction, and comprehensive validation rules to prevent misconfiguration.

## Types

### Config

**Description**: Top-level configuration structure controlling benchmark execution parameters, workload settings, and database behavior. Contains all tunable parameters that affect benchmark execution and measurement.

**Fields**:
- **seed**: Optional 32-bit unsigned integer for random number generator seed
  - **Default**: null (random seed each run)
  - **Range**: 0 to 4,294,967,295
  - **Purpose**: Enables reproducible benchmarks with fixed randomness

- **warmup_ops**: 32-bit unsigned integer for number of warmup operations
  - **Default**: 0
  - **Range**: 0 to 1,000,000,000
  - **Purpose**: Perform specified operations before measurement starts

- **warmup_ns**: 64-bit unsigned integer for warmup duration in nanoseconds
  - **Default**: 0
  - **Range**: 0 to 360,000,000,000,000 (100 hours)
  - **Purpose**: Warm up for specified time before measurement

- **measure_ops**: 32-bit unsigned integer for number of measured operations
  - **Default**: 1
  - **Range**: 1 to 1,000,000,000
  - **Purpose**: Stop measurement after this many operations

- **threads**: 32-bit unsigned integer for number of concurrent threads
  - **Default**: 1
  - **Range**: 1 to 256
  - **Purpose**: Execute workload with specified thread concurrency

- **db**: DbConfig structure containing database-specific settings

**Size**: Variable (depends on contained DbConfig)

**Invariants**:
- At least one of warmup_ops or warmup_ns should be specified for proper warmup
- measure_ops must be at least 1
- threads must be at least 1
- Only one warmup mechanism should be specified (ops or time, not both)

### DbConfig

**Description**: Database-specific configuration that controls storage format, durability guarantees, and I/O behavior. These parameters significantly affect performance and durability characteristics.

**Fields**:
- **page_size**: 32-bit unsigned integer for database page size in bytes
  - **Default**: 16384 (16KB)
  - **Range**: 4096 to 65536 (must be power of 2)
  - **Purpose**: Size of fundamental I/O and allocation unit

- **checksum**: Enumeration of checksum algorithm selection
  - **Default**: crc32c
  - **Values**: crc32c, xxh3, none
  - **Purpose**: Select integrity checking algorithm for pages

- **sync_mode**: Enumeration of disk synchronization strategy
  - **Default**: fsync_per_commit
  - **Values**: fsync_per_commit, group_commit, nosync
  - **Purpose**: Control durability vs performance trade-off

- **mmap**: Boolean flag for memory-mapped I/O mode
  - **Default**: false
  - **Purpose**: Use memory mapping instead of explicit read/write calls

**Size**: 24 bytes (approximately)

**Invariants**:
- page_size must be a power of 2
- page_size must be at least 4096 (system page size)
- page_size should match filesystem block size for optimal performance

## Configuration Options

### Seed Option

**Purpose**: Control randomness in benchmark workloads

**Default**: null (uses system time or entropy source)

**Range**: 0 to 4,294,967,295 (entire u32 range)

**Validation Rules**:
- If null, random seed is generated each run
- If specified, same seed produces identical workload across runs
- Seed is used for all random number generation in the benchmark

**Use Cases**:
- Reproducible benchmarking for regression testing
- Comparative testing of different builds with identical workloads
- Debugging specific workload patterns

### Warmup Operations Option

**Purpose**: Perform unmeasured operations to warm up caches and JIT compilation

**Default**: 0 (no warmup)

**Range**: 0 to 1,000,000,000 operations

**Validation Rules**:
- If both warmup_ops and warmup_ns are zero, no warmup occurs
- If both are specified, warmup_ops takes precedence
- Large values may excessively prolong benchmark execution

**Use Cases**:
- CPU cache warmup for microbenchmarks
- JIT compilation warmup for interpreted languages
- Filesystem cache warmup for storage benchmarks

### Warmup Duration Option

**Purpose**: Perform unmeasured operations for a specified time duration

**Default**: 0 (no time-based warmup)

**Range**: 0 to 360,000,000,000,000 nanoseconds (100 hours)

**Validation Rules**:
- If both warmup_ops and warmup_ns are zero, no warmup occurs
- If both are specified, warmup_ops takes precedence
- Very long durations may be impractical

**Use Cases**:
- Fixed-duration warmup for consistent testing
- Allowing JIT compilation sufficient time
- Stabilizing thermal conditions for hardware

### Measure Operations Option

**Purpose**: Stop measurement after a specific number of operations

**Default**: 1 (measure single operation)

**Range**: 1 to 1,000,000,000 operations

**Validation Rules**:
- Must be at least 1
- Larger values provide more statistical confidence
- Very large values may take excessive time

**Use Cases**:
- Short microbenchmarks (1-1000 operations)
- Standard benchmarks (1,000,000 operations)
- Stress tests (100,000,000+ operations)

### Threads Option

**Purpose**: Control concurrency level for multi-threaded benchmarks

**Default**: 1 (single-threaded)

**Range**: 1 to 256 threads

**Validation Rules**:
- Must be at least 1
- Should not exceed available CPU cores
- More threads than cores yields diminishing returns

**Use Cases**:
- Single-threaded baseline (1 thread)
- Fully concurrent workload (equal to core count)
- Over-subscribed stress testing (more than core count)

### Page Size Option

**Purpose**: Set the fundamental I/O and allocation unit size

**Default**: 16384 bytes (16KB)

**Range**: 4096 to 65536 bytes (power of 2 only)

**Validation Rules**:
- Must be a power of 2 (4096, 8192, 16384, 32768, 65536)
- Must be at least 4096 (typical system page size)
- Should align with filesystem block size for optimal performance
- Larger pages reduce overhead but waste space for small data

**Use Cases**:
- 4096: Minimum size, matches typical filesystem block size
- 16384: Default, balances overhead and space efficiency
- 32768 or 65536: Large values for large key-value workloads

### Checksum Option

**Purpose**: Select integrity verification algorithm

**Default**: crc32c

**Values**:
- **crc32c**: Castagnoli CRC, hardware-accelerated, balanced performance and detection
- **xxh3**: Very fast hash, good error detection, no hardware acceleration needed
- **none**: No checksumming, fastest but no corruption detection

**Validation Rules**:
- crc32c requires SSE4.2 or ARM CRC extensions for hardware acceleration
- xxh3 is portable and fast on all platforms
- none is only appropriate for testing or ephemeral data

**Use Cases**:
- crc32c: Production databases with data integrity requirements
- xxh3: High-performance workloads on platforms without CRC32C hardware support
- none: Temporary testing databases or in-memory-only workloads

### Sync Mode Option

**Purpose**: Control disk flushing strategy for durability

**Default**: fsync_per_commit

**Values**:
- **fsync_per_commit**: Call fsync after every commit, maximum durability
- **group_commit**: Batch multiple commits before fsync, balanced approach
- **nosync**: Never call fsync, maximum performance but data loss on crash

**Validation Rules**:
- fsync_per_commit is safest but slowest
- group_commit requires careful tuning of batch size and timing
- nosync is only appropriate for testing or ephemeral databases

**Use Cases**:
- fsync_per_commit: Financial data, transactional systems requiring ACID
- group_commit: Web applications, analytics with relaxed durability
- nosync: Caches, temporary data, testing environments

### Memory-Mapped I/O Option

**Purpose**: Use memory mapping instead of explicit read/write system calls

**Default**: false

**Values**:
- **true**: Use mmap for file access, operating system manages paging
- **false**: Use explicit pread/pwrite system calls

**Validation Rules**:
- Requires operating system support for mmap
- May not work on networked filesystems
- Can improve performance by leveraging OS page cache

**Use Cases**:
- true: Read-heavy workloads, random access patterns
- false: Write-heavy workloads, sequential access patterns

## Builder Pattern Requirements

### Builder Purpose

**Rationale**: Configuration structs have many fields with complex interdependencies. Builder pattern provides:
- Fluent, readable API for configuration
- Compile-time enforcement of required fields
- Step-by-step construction with clear intent
- Validation before use
- Default values applied automatically

### Builder Structure

**ConfigBuilder**: Separate type that constructs Config
- Contains all optional fields as Option types
- Provides setter methods for each field
- Has build() method that validates and produces Config

**Method Naming**: Setters named after the field they set
- seed(value: u32) -> Self
- warmup_ops(value: u32) -> Self
- measure_ops(value: u32) -> Self
- threads(value: u32) -> Self
- db(value: DbConfig) -> Self

**Method Chaining**: Each setter returns self for chaining
- ConfigBuilder::new().warmup_ops(1000).measure_ops(10000).build()

**Validation**: build() method validates configuration before returning Config
- Checks all validation rules
- Returns Result<Config, ConfigError> on failure
- Provides clear error messages for validation failures

### DbConfigBuilder

**Separate Builder**: DbConfig has its own builder type
- Similar structure to ConfigBuilder
- Specific methods for database configuration

**Methods**:
- page_size(value: u32) -> Self
- checksum(value: ChecksumType) -> Self
- sync_mode(value: SyncMode) -> Self
- mmap(value: bool) -> Self

**Validation**:
- page_size must be power of 2
- page_size must be at least 4096
- Combined validation rules that cross fields

### Default Construction

**Config::default()**: Provide sensible defaults via Default trait
- Seed: null (random each run)
- Warmup: 0 operations, 0 nanoseconds (no warmup)
- Measure: 1 operation
- Threads: 1 (single-threaded)
- Database: DbConfig defaults

**DbConfig::default()**: Provide production-safe defaults
- page_size: 16384 (16KB)
- checksum: crc32c (hardware-accelerated)
- sync_mode: fsync_per_commit (maximum durability)
- mmap: false (explicit I/O)

### Builder Example Usage

**Basic Usage**: Configure with custom parameters
```rust
let config = ConfigBuilder::new()
    .warmup_ops(1000)
    .measure_ops(100000)
    .threads(4)
    .db(DbConfigBuilder::new()
        .page_size(32768)
        .sync_mode(SyncMode::GroupCommit)
        .build()?)
    .build()?;
```

**Minimal Usage**: Accept all defaults
```rust
let config = Config::default();
```

**Partial Configuration**: Override only specific fields
```rust
let config = ConfigBuilder::new()
    .measure_ops(1000000)
    .build()?;
```

## Validation Rules

### Cross-Field Validation

**Warmup Logic**: At most one warmup mechanism should be active
- If warmup_ops is greater than 0, warmup_ns should be 0
- If warmup_ns is greater than 0, warmup_ops should be 0
- Violation produces ConfigError::ConflictingWarmup error

**Thread Count**: Should not exceed available CPU cores
- Query hardware concurrency at runtime
- Issue warning if threads exceeds core count
- Do not enforce as hard error (over-subscription is sometimes intentional)

**Page Size vs Sync Mode**: Large pages with fsync_per_commit may be slow
- Warn if page_size is 65536 and sync_mode is fsync_per_commit
- Informative warning only, not an error

### Range Validation

**Numeric Bounds**: All numeric fields must be within valid range
- warmup_ops: 0 to 1,000,000,000
- warmup_ns: 0 to 360,000,000,000,000
- measure_ops: 1 to 1,000,000,000
- threads: 1 to 256
- page_size: 4096 to 65536

**Enumeration Values**: Enum fields must match defined values
- checksum: Only crc32c, xxh3, or none
- sync_mode: Only fsync_per_commit, group_commit, or nosync

**Power of Two**: page_size must be exactly a power of 2
- Validate by checking that exactly one bit is set
- Equivalent to (page_size & (page_size - 1)) == 0

### Semantic Validation

**Reasonable Defaults**: Warn about potentially misconfigured settings
- Large measure_ops (greater than 1 billion) may take too long
- Very small page_size (4096) with large values wastes space
- nosync mode should warn about data loss risk

**Hardware Constraints**: Check for hardware compatibility
- crc32c requires CPUID check for SSE4.2 or ARM CRC
- mmap may not work on network filesystems
- Large page sizes may not align with disk geometry

## Rust Type Guidance

### Type Organization

Create dedicated configuration module:
- northstar_core::config::Config - Top-level configuration
- northstar_core::config::DbConfig - Database configuration
- northstar_core::config::ConfigBuilder - Builder for Config
- northstar_core::config::DbConfigBuilder - Builder for DbConfig

### Type Definitions

**Config Struct**: Use plain struct with public or private fields
```rust
pub struct Config {
    pub seed: Option<u32>,
    pub warmup_ops: u32,
    pub warmup_ns: u64,
    pub measure_ops: u32,
    pub threads: u32,
    pub db: DbConfig,
}
```

**DbConfig Struct**: Use plain struct with enum fields
```rust
pub struct DbConfig {
    pub page_size: u32,
    pub checksum: ChecksumType,
    pub sync_mode: SyncMode,
    pub mmap: bool,
}
```

**Enum Types**: Define enums for configuration choices
```rust
pub enum ChecksumType {
    Crc32c,
    Xxh3,
    None,
}

pub enum SyncMode {
    FsyncPerCommit,
    GroupCommit,
    Nosync,
}
```

### Builder Implementation

**ConfigBuilder Struct**: Separate struct with Option fields
```rust
pub struct ConfigBuilder {
    seed: Option<Option<u32>>,
    warmup_ops: Option<u32>,
    warmup_ns: Option<u64>,
    measure_ops: Option<u32>,
    threads: Option<u32>,
    db: Option<DbConfig>,
}
```

**Builder Methods**: Fluent setter methods
```rust
impl ConfigBuilder {
    pub fn new() -> Self {
        Self {
            seed: None,
            warmup_ops: None,
            warmup_ns: None,
            measure_ops: None,
            threads: None,
            db: None,
        }
    }

    pub fn seed(mut self, value: u32) -> Self {
        self.seed = Some(Some(value));
        self
    }

    pub fn warmup_ops(mut self, value: u32) -> Self {
        self.warmup_ops = Some(value);
        self
    }

    // ... other setters ...

    pub fn build(self) -> Result<Config, ConfigError> {
        // Apply defaults
        let seed = self.seed.unwrap_or(None);
        let warmup_ops = self.warmup_ops.unwrap_or(0);
        let warmup_ns = self.warmup_ns.unwrap_or(0);
        let measure_ops = self.measure_ops.unwrap_or(1);
        let threads = self.threads.unwrap_or(1);
        let db = self.db.ok_or(ConfigError::MissingField("db"))?;

        // Validate
        validate_config(&seed, warmup_ops, warmup_ns, measure_ops, threads)?;

        Ok(Config {
            seed,
            warmup_ops,
            warmup_ns,
            measure_ops,
            threads,
            db,
        })
    }
}
```

### Validation Implementation

**Config Error Enum**: Define specific error types
```rust
pub enum ConfigError {
    ConflictingWarmup,
    MeasureOpsTooSmall { value: u32, min: u32 },
    ThreadsTooSmall { value: u32, min: u32 },
    PageSizeNotPowerOfTwo { value: u32 },
    PageSizeTooSmall { value: u32, min: u32 },
    MissingField(&'static str),
}
```

**Validation Function**: Implement all validation rules
```rust
fn validate_config(
    seed: &Option<u32>,
    warmup_ops: u32,
    warmup_ns: u64,
    measure_ops: u32,
    threads: u32,
) -> Result<(), ConfigError> {
    if warmup_ops > 0 && warmup_ns > 0 {
        return Err(ConfigError::ConflictingWarmup);
    }

    if measure_ops < 1 {
        return Err(ConfigError::MeasureOpsTooSmall {
            value: measure_ops,
            min: 1,
        });
    }

    if threads < 1 {
        return Err(ConfigError::ThreadsTooSmall {
            value: threads,
            min: 1,
        });
    }

    Ok(())
}
```

### Trait Implementations

**Default Trait**: Provide default configuration
```rust
impl Default for Config {
    fn default() -> Self {
        Self {
            seed: None,
            warmup_ops: 0,
            warmup_ns: 0,
            measure_ops: 1,
            threads: 1,
            db: DbConfig::default(),
        }
    }
}
```

**Clone and Debug**: Derive for convenience
```rust
#[derive(Clone, Debug)]
pub struct Config { /* ... */ }
```

**Serialize/Deserialize**: Support for configuration files
```rust
#[derive(Serialize, Deserialize)]
#[serde(default)]
pub struct Config { /* ... */ }
```

### Testing Strategy

**Unit tests needed for**:
- Builder constructs valid Config with all fields set
- Builder applies defaults correctly for missing fields
- Validation rejects invalid configurations
- Validation accepts all valid configurations
- Default configuration is valid

**Property tests for**:
- Any Config produced by builder passes validation
- Config round-trips through serialization correctly
- Builder methods can be called in any order

**Integration tests for**:
- Config works correctly with database open operations
- DbConfig page_size validation works with filesystem
- Sync mode changes affect fsync behavior correctly