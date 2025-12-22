spec/machine_specs_v0.md

# Machine Specifications v0

## Overview

This document defines target machine specifications for NorthstarDB performance profiles. These specifications guide benchmark configuration, baseline management, and performance target validation.

## Profile: ci

### Hardware Requirements
- **CPU**: 4+ core virtual CPU
- **Architecture**: x86_64
- **RAM**: 8GB minimum
- **Storage**: 20GB standard VM storage
- **Network**: Standard (not performance-critical)

### Software Environment
- **OS**: Ubuntu 22.04 LTS or equivalent
- **Kernel**: Linux 5.15+
- **Filesystem**: ext4 (default)
- **Zig Version**: Current stable (tracked in build.zig)
- **Build Mode**: ReleaseFast

### Performance Characteristics
- **Variable**: Performance may vary between runs
- **Shared**: Hardware may be shared between builds
- **Best-effort**: No performance guarantees
- **Focus**: Consistency for regression detection

### Expected Performance Range
- CPU performance: Baseline (1.0x reference)
- Memory bandwidth: ~10-20 GB/s
- Storage IOPS: ~1,000-5,000 IOPS
- Storage throughput: ~100-300 MB/s

## Profile: dev_nvme

### Hardware Requirements
- **CPU**: 8+ physical cores
- **Architecture**: x86_64
- **Base Clock**: 3.0+ GHz
- **RAM**: 16GB+ DDR4/DDR5
- **Cache**: L3: 8MB+ per CPU

### Storage Requirements
- **Type**: NVMe SSD (PCIe 3.0+)
- **Capacity**: 500GB+ available for benchmarks
- **Sequential Read**: 3,000+ MB/s
- **Sequential Write**: 2,500+ MB/s
- **Random IOPS**: 100,000+ (4KB random read)
- **Latency**: < 100µs average 4KB random read

### Software Environment
- **OS**: Ubuntu 22.04+ or equivalent Linux
- **Kernel**: Linux 5.15+ with io_uring support
- **Filesystem**: ext4 or xfs
- **Mount Options**: noatime, barrier=1
- **Zig Version**: Current stable release
- **Build Mode**: ReleaseFast
- **CPU Governor**: Performance mode

### Performance Characteristics
- **Dedicated**: Hardware reserved for performance testing
- **Consistent**: Minimal background load during benchmarks
- **Optimized**: System tuned for performance
- **Validated**: Performance characteristics verified

### Expected Performance Range
- CPU performance: 2-4x CI profile
- Memory bandwidth: ~40-80 GB/s
- Storage IOPS: 100,000+ IOPS
- Storage throughput: 3,000+ MB/s sequential

## Database Configuration

### Common Settings (Both Profiles)
- **Page Size**: 16KB
- **Checksum Algorithm**: CRC32C
- **Sync Mode**: fsync_per_commit
- **Cache Policy**: Operating system default

### CI Profile Specific
- **Database Size**: Reduced for time constraints
- **Test Data**: May use smaller datasets
- **Timeouts**: Conservative to avoid CI time limits

### dev_nvme Profile Specific
- **Database Size**: Full specification sizes
- **Test Data**: Complete datasets as defined in benchmarks
- **Timeouts**: Optimized for performance measurement

## Validation Requirements

### Pre-Benchmark Validation
- Verify CPU core count and frequency
- Check available RAM meets minimum
- Validate storage performance meets minimum
- Confirm filesystem and mount options
- Check system load is minimal

### Runtime Monitoring
- CPU utilization during benchmarks
- Memory usage and pressure
- Storage I/O patterns and latency
- System load and interference
- Temperature and thermal throttling

### Post-Benchmark Validation
- Verify results meet profile expectations
- Check for system-level anomalies
- Validate hardware stayed within expected parameters
- Confirm no background interference

## Performance Baselines

### CI Profile Baselines
- Focus on regression detection
- Updated automatically via CI
- Hardware variability compensated for
- Conservative thresholds applied

### dev_nvme Profile Baselines
- Focus on absolute performance
- Updated manually on improvements
- Hardware consistency verified
- Aggressive but achievable targets

## Implementation Notes

### Hardware Detection
The benchmark system should automatically detect and validate:
- CPU model, core count, frequency
- Available RAM and memory bandwidth
- Storage type, capacity, and performance
- Filesystem and mount options
- System configuration and tuning

### Profile Selection
- Automatic profile detection based on hardware
- Manual override available for testing
- Clear logging of selected profile and reasoning
- Validation that hardware meets profile requirements

### Result Interpretation
- CI results interpreted with hardware variability in mind
- dev_nvme results used for absolute performance claims
- Clear documentation of actual hardware used
- Reproducible configuration tracking

## Future Evolution

### Hardware Updates
- Profiles will evolve with hardware improvements
- Baselines updated as new hardware becomes standard
- Backward compatibility maintained where possible
- Clear versioning of specification changes

### Additional Profiles
- May add specialized profiles for specific workloads
- Cloud provider profiles for standardized performance
- Embedded/IoT profiles for resource-constrained environments
- High-performance profiles for enterprise hardware