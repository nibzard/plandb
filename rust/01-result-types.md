# Benchmark Result Types

## Purpose

Benchmark result types provide structured data structures for capturing, analyzing, and reporting performance metrics from NorthstarDB benchmarks. These types organize measurements such as throughput, latency, resource usage, and system configuration into a hierarchical format that supports statistical analysis, historical comparison, and continuous integration regression testing.

## Types

### BenchmarkResult

**Description**: The top-level container representing all data from a single benchmark execution. Contains the benchmark name, execution environment metadata, configuration parameters, measured results, and repetition information.

**Fields**:
- **bench_name**: String name identifying which benchmark was run
- **profile**: Profile structure describing the test environment
- **build**: Build structure describing compiler and build settings
- **config**: Config structure containing benchmark configuration parameters
- **results**: Results structure containing all measured metrics
- **repeat_index**: Number indicating which repetition this is (starting from 0)
- **repeat_count**: Total number of repetitions planned or executed
- **timestamp_utc**: String timestamp in UTC format for when the benchmark ran
- **git**: Git structure containing version control information

**Size**: Variable (depends on contained structures)

**Invariants**:
- repeat_index must be less than repeat_count
- timestamp_utc must be valid ISO 8601 format
- All measured metrics must be present and valid

### Profile

**Description**: Metadata describing the hardware and software environment where the benchmark was executed. Enables understanding of performance differences across machines.

**Fields**:
- **name**: Enumeration indicating profile type (ci, dev_nvme, or custom)
- **cpu_model**: Optional string describing CPU model (e.g., "AMD Ryzen 9 7950X")
- **core_count**: 32-bit unsigned integer indicating number of CPU cores
- **ram_gb**: 64-bit floating point value indicating total RAM in gigabytes
- **os**: Optional string describing operating system and version
- **fs**: Optional string describing filesystem type (e.g., "ext4", "xfs", "ntfs")

**Purpose**: Enables comparison of results across different machines and identification of performance bottlenecks related to hardware.

**Invariants**:
- core_count must be greater than 0
- ram_gb must be positive
- name determines baseline expectations for performance

### Build

**Description**: Compiler and build configuration information that produced the database binary under test. Critical for understanding optimization levels and debugging capabilities.

**Fields**:
- **zig_version**: String indicating Zig compiler version (e.g., "0.11.0")
- **mode**: Enumeration of build modes (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)
- **target**: Optional string describing target triple (e.g., "x86_64-linux")
- **lto**: Optional boolean indicating whether link-time optimization was enabled

**Purpose**: Different build modes have dramatically different performance characteristics. Recording this information prevents incorrect comparisons.

**Invariants**:
- zig_version must be valid version string
- mode must match one of the four enumeration values

### Git

**Description**: Version control metadata for the exact code commit being benchmarked. Enables reproducibility and historical performance tracking.

**Fields**:
- **sha**: String containing 40-character git commit hash
- **branch**: Optional string containing branch name (e.g., "main", "develop")
- **dirty**: Optional boolean indicating whether working directory had uncommitted changes

**Purpose**: Associates benchmark results with specific code versions for regression detection and bisecting performance changes.

**Invariants**:
- sha must be valid 40-character hexadecimal string
- If dirty is true, the build may not be reproducible from git alone

### Config

**Description**: Benchmark configuration parameters that control workload, warmup, and threading. These parameters define the exact conditions under which measurements were taken.

**Fields**:
- **seed**: Optional 32-bit unsigned integer for random number generator seed
- **warmup_ops**: 32-bit unsigned integer for number of warmup operations (default 0)
- **warmup_ns**: 64-bit unsigned integer for warmup duration in nanoseconds (default 0)
- **measure_ops**: 32-bit unsigned integer for number of measured operations (default 1)
- **threads**: 32-bit unsigned integer for number of threads (default 1)
- **db**: DbConfig structure containing database-specific settings

**Purpose**: Enables exact reproduction of benchmark conditions and fair comparison across runs.

**Invariants**:
- At least one of warmup_ops or warmup_ns should be specified for proper warmup
- measure_ops must be greater than 0
- threads must be greater than 0

### DbConfig

**Description**: Database-specific configuration that affects storage and synchronization behavior.

**Fields**:
- **page_size**: 32-bit unsigned integer for database page size in bytes (e.g., 16384)
- **checksum**: Enumeration of checksum algorithm (crc32c, xxh3, none)
- **sync_mode**: Enumeration of synchronization strategy (fsync_per_commit, group_commit, nosync)
- **mmap**: Boolean indicating whether memory-mapped I/O is enabled

**Purpose**: Database configuration has major impact on performance and durability guarantees.

**Invariants**:
- page_size must be power of 2 and at least 4096
- sync_mode selection affects durability vs performance trade-offs

### Results

**Description**: Core performance measurements from a single benchmark repetition. Contains throughput, latency, resource usage, and error counts.

**Fields**:
- **ops_total**: 64-bit unsigned integer for total operations completed
- **duration_ns**: 64-bit unsigned integer for measurement duration in nanoseconds
- **ops_per_sec**: 64-bit floating point for throughput (operations per second)
- **latency_ns**: Latency structure containing percentile measurements
- **bytes**: Bytes structure containing I/O byte counts
- **io**: IO structure containing system call counts
- **alloc**: Alloc structure containing memory allocation metrics
- **errors_total**: 64-bit unsigned integer for total errors encountered (default 0)
- **notes**: Optional JSON value for arbitrary notes or extra metadata
- **stability**: Optional Stability structure for variance analysis

**Purpose**: Primary data structure for benchmark analysis and comparison.

**Invariants**:
- ops_per_sec equals ops_total divided by duration_ns times 1 billion
- duration_ns must be greater than 0
- All metrics must be non-negative

### Latency

**Description**: Statistical latency measurements showing distribution of operation latencies. Percentiles indicate the value below which a given percentage of observations fall.

**Fields**:
- **p50**: 64-bit unsigned integer for median latency in nanoseconds (50th percentile)
- **p95**: 64-bit unsigned integer for 95th percentile latency in nanoseconds
- **p99**: 64-bit unsigned integer for 99th percentile latency in nanoseconds
- **max**: 64-bit unsigned integer for maximum observed latency in nanoseconds

**Purpose**: Latency percentiles characterize the distribution better than average or min/max. Critical for understanding tail latency and user experience.

**Percentile Interpretation**:
- p50: Half of operations completed faster than this value
- p95: 95 percent of operations completed faster than this value
- p99: 99 percent of operations completed faster than this value
- max: Worst-case observed latency

**Invariants**:
- p50 must be less than or equal to p95
- p95 must be less than or equal to p99
- p99 must be less than or equal to max

### Bytes

**Description**: Total bytes read and written during the benchmark.

**Fields**:
- **read_total**: 64-bit unsigned integer for total bytes read from storage
- **write_total**: 64-bit unsigned integer for total bytes written to storage

**Purpose**: Measures I/O workload and enables calculation of throughput in megabytes per second.

**Invariants**:
- Both values must be non-negative
- read_total and write_total measure logical I/O, not physical disk I/O

### IO

**Description**: System call counts related to file I/O operations.

**Fields**:
- **fsync_count**: 64-bit unsigned integer for number of fsync system calls
- **fdatasync_count**: 64-bit unsigned integer for number of fdatasync calls (default 0)
- **open_count**: 64-bit unsigned integer for number of file open calls (default 0)
- **close_count**: 64-bit unsigned integer for number of file close calls (default 0)
- **mmap_faults**: 64-bit unsigned integer for number of memory-mapped I/O page faults (default 0)

**Purpose**: System call counts indicate the kernel interaction overhead and help identify where time is spent.

**Invariants**:
- All counts must be non-negative
- fsync_count is typically the most expensive operation

### Alloc

**Description**: Memory allocation statistics tracking heap usage during the benchmark.

**Fields**:
- **alloc_count**: 64-bit unsigned integer for number of heap allocations performed
- **alloc_bytes**: 64-bit unsigned integer for total bytes allocated (cumulative)

**Purpose**: Memory allocation patterns significantly affect performance. Tracking allocations helps identify optimization opportunities.

**Invariants**:
- alloc_count must be non-negative
- alloc_bytes measures cumulative allocation, not current heap size
- Reallocations and frees may not be reflected in alloc_bytes

### Stability

**Description**: Statistical analysis of result stability across multiple repetitions. Used to determine if measurements are consistent or if there is high variance.

**Fields**:
- **coefficient_of_variation**: 64-bit floating point ratio of standard deviation to mean
- **is_stable**: Boolean indicating whether variation is within acceptable threshold
- **repeat_count**: 32-bit unsigned integer for number of repetitions analyzed
- **threshold_used**: 64-bit floating point threshold that determined stability

**Purpose**: High variance indicates unstable measurements that may need more repetitions or environmental investigation.

**Invariants**:
- coefficient_of_variation must be non-negative
- is_stable is true if coefficient_of_variation is less than threshold_used
- repeat_count must be at least 2 for meaningful variance calculation

## Statistical Aggregation Methods

### Percentile Calculation

**Purpose**: Compute percentiles from a collection of individual operation latencies.

**Algorithm**: Sort latencies and select the value at the specified rank
1. Collect all latency measurements into a list
2. Sort the list in ascending order
3. Find the index corresponding to the desired percentile
4. Return the value at that index

**Index Formula**: For N measurements and percentile P, the index is (P * N) / 100
- For p50 with N=100: index 50
- For p95 with N=100: index 95
- For p99 with N=100: index 99

**Interpolation**: For precise percentiles when index is not an integer
- Use linear interpolation between nearest two values
- Example: For index 95.3 with values at 95 and 96, interpolate 30% from 95 to 96

**Handling Small Samples**: For small N (less than 100), use interpolation to estimate percentiles
- Avoids misleading results from very small samples
- Provides reasonable estimates even with limited data

### Throughput Calculation

**Formula**: Operations per second equals total operations divided by duration in seconds
- ops_per_sec = ops_total / (duration_ns / 1,000,000,000)

**Units**: Operations per second (higher is better)

**Significance**: Primary metric for overall system performance and capacity

### Coefficient of Variation

**Purpose**: Normalized measure of dispersion that enables comparison across different scales

**Formula**: CV equals standard deviation divided by mean
- CV = (standard_deviation / mean) * 100 (expressed as percentage)

**Interpretation**:
- CV less than 5%: Very stable measurements
- CV between 5% and 10%: Acceptable stability
- CV between 10% and 20%: Moderate variance, investigate
- CV greater than 20%: High variance, results unreliable

**Usage**: Determine if more repetitions are needed or if environmental factors are causing noise

### Mean and Standard Deviation

**Mean**: Average value across all repetitions
- Formula: sum of all values divided by count
- Represents central tendency of measurements

**Standard Deviation**: Measure of spread around the mean
- Formula: Square root of variance (average squared deviation from mean)
- Larger values indicate more spread in measurements

**Sample vs Population**: Use sample standard deviation (dividing by N-1) for unbiased estimate when N is small

### Aggregation Across Repetitions

**Median Reporting**: For metrics that vary across repetitions, report median
- More robust to outliers than mean
- Better represents typical performance

**Percentile Aggregation**: When aggregating percentiles across repetitions
- Option 1: Report median percentile across repetitions
- Option 2: Combine all measurements and recompute percentiles
- Recommended: Option 2 for accuracy, Option 1 for simplicity

## Metric Descriptions

### Throughput Metrics

**ops_per_sec**: Operations completed per second
- **Type**: 64-bit floating point number
- **Units**: Operations/second
- **Higher is Better**: Indicates greater capacity and performance
- **Typical Values**: Range from thousands to millions depending on operation type

**Purpose**: Primary measure of system capacity and overall performance efficiency

### Latency Metrics

**p50 (Median)**: Middle value of latency distribution
- **Type**: 64-bit unsigned integer
- **Units**: Nanoseconds
- **Lower is Better**: Indicates faster operation completion
- **Significance**: Represents typical user experience

**p95**: 95th percentile latency
- **Type**: 64-bit unsigned integer
- **Units**: Nanoseconds
- **Lower is Better**: Indicates consistent performance
- **Significance**: 95% of users experience at most this latency

**p99**: 99th percentile latency
- **Type**: 64-bit unsigned integer
- **Units**: Nanoseconds
- **Lower is Better**: Indicates minimal tail latency
- **Significance**: Only 1% of operations are slower (tail behavior)

**max**: Maximum observed latency
- **Type**: 64-bit unsigned integer
- **Units**: Nanoseconds
- **Lower is Better**: Indicates worst-case is not too bad
- **Significance**: Upper bound on latency, may indicate outliers

### Resource Usage Metrics

**bytes (read_total, write_total)**: Total I/O in bytes
- **Type**: 64-bit unsigned integer
- **Units**: Bytes
- **Context**: Used to calculate I/O throughput (megabytes per second)
- **Purpose**: Understanding I/O workload and efficiency

**alloc_count**: Number of heap allocations
- **Type**: 64-bit unsigned integer
- **Units**: Count
- **Lower is Better**: Fewer allocations indicate better memory efficiency
- **Purpose**: Identifies opportunities for allocation optimization

**alloc_bytes**: Total bytes allocated (cumulative)
- **Type**: 64-bit unsigned integer
- **Units**: Bytes
- **Lower is Better**: Less total allocation indicates better memory reuse
- **Purpose**: Measures memory allocation pressure

**fsync_count**: Number of fsync calls
- **Type**: 64-bit unsigned integer
- **Units**: Count
- **Lower is Better**: Fewer fsyncs typically improve performance
- **Purpose**: Durability has performance cost; tracking shows impact

## Rust Type Guidance

### Type Organization

Organize result types in a dedicated benchmark module:
- northstar_bench::result::BenchmarkResult - Top-level result container
- northstar_bench::result::Profile - Environment metadata
- northstar_bench::result::Latency - Percentile measurements
- northstar_bench::result::Results - Performance metrics

### Type Definitions

**Use Structs with Named Fields**: All result types should be structs with named fields for clarity
- Public fields for simple data containers
- Private fields with accessors for validated data
- Implement Debug, Clone, and Serialize for all result types

**String Types**: Use String for owned strings, str for borrowed strings in Result types
- Benchmark results typically own their string data
- Use String for bench_name, timestamp_utc, and other metadata

**Numeric Types**: Match Zig types exactly for compatibility
- Use u64 for all unsigned 64-bit integers (ops_total, duration_ns, etc.)
- Use f64 for all 64-bit floating point values (ops_per_sec, ram_gb, etc.)
- Use u32 for unsigned 32-bit integers (core_count, warmup_ops, etc.)

**Option Types**: Use Option for nullable fields
- Option<String> for optional string fields (cpu_model, os, fs, branch)
- Option<f64> for optional numeric values
- Option<T> for any field that may be absent

**Enum Types**: Use Rust enums for fixed enumerations
- enum for ProfileName (Ci, DevNvme, Custom)
- enum for BuildMode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)
- enum for ChecksumType (Crc32c, Xxh3, None)
- enum for SyncMode (FsyncPerCommit, GroupCommit, Nosync)

### Serialization

**Use Serde**: Implement Serialize and Deserialize for all result types
- Enables JSON export for result comparison tools
- Enables loading historical results for regression detection
- Standard practice for benchmark frameworks

**JSON Structure**: Maintain compatibility with Zig JSON output
- Field names should match Zig struct names exactly
- Enum representations should match Zig values
- Null fields should serialize as JSON null

### Validation

**Implement Validation Methods**: Add validate() methods that check invariants
- Returns Result<(), ValidationError> for easy error handling
- Called after deserialization to ensure data integrity
- Checked before using results in comparisons

**Error Types**: Define specific error types for validation failures
- ValidationError enum with variants for each validation rule
- Provides clear error messages for debugging
- Enables graceful handling of malformed results

### Statistical Helpers

**Percentile Calculation Function**: Provide utility for computing percentiles
- Input: Slice of u64 latency values
- Output: Latency struct with computed percentiles
- Implementation: Sort slice, select indices, interpolate if needed

**Coefficient of Variation Function**: Compute stability metric
- Input: Slice of f64 values from multiple repetitions
- Output: f64 coefficient of variation
- Implementation: Compute mean and standard deviation, divide

**Aggregation Function**: Combine results from multiple repetitions
- Input: Vec<Results> from multiple runs
- Output: Single aggregated Results
- Strategy: Median for most metrics, recompute percentiles for latency

### Testing Strategy

**Unit tests needed for**:
- All struct constructors create valid instances
- Validation methods reject invalid data
- Percentile calculation is accurate
- Throughput calculation matches formula
- Coefficient of variation matches formula

**Property tests for**:
- Serialization/deserialization round-trip preserves data
- Validation rejects all invalid combinations
- Percentile calculation produces sorted outputs

**Integration tests for**:
- Can load JSON output from Zig benchmarks
- Can compare results across multiple runs
- Regression detection works correctly
- Statistical aggregation produces expected outputs