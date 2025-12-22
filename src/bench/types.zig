//! Common types and data structures for benchmark framework.
//!
//! Defines the core data structures used throughout the benchmark system
//! including results, profiles, configurations, and metrics collection.

const std = @import("std");

pub const BenchmarkResult = struct {
    bench_name: []const u8,
    profile: Profile,
    build: Build,
    config: Config,
    results: Results,
    repeat_index: u32,
    repeat_count: u32,
    timestamp_utc: []const u8,
    git: Git,
};

pub const ProfileName = enum { ci, dev_nvme, custom };

pub const Profile = struct {
    name: ProfileName,
    cpu_model: ?[]const u8 = null,
    core_count: u32,
    ram_gb: f64,
    os: ?[]const u8 = null,
    fs: ?[]const u8 = null,
};

pub const Build = struct {
    zig_version: []const u8,
    mode: enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall },
    target: ?[]const u8 = null,
    lto: ?bool = null,
};

pub const Git = struct {
    sha: []const u8,
    branch: ?[]const u8 = null,
    dirty: ?bool = null,
};

pub const Config = struct {
    seed: ?u32 = null,
    warmup_ops: u32 = 0,
    warmup_ns: u64 = 0,
    measure_ops: u32 = 1,
    threads: u32 = 1,
    db: DbConfig,
};

pub const DbConfig = struct {
    page_size: u32,
    checksum: enum { crc32c, xxh3, none } = .crc32c,
    sync_mode: enum { fsync_per_commit, group_commit, nosync } = .fsync_per_commit,
    mmap: bool = false,
};

pub const Results = struct {
    ops_total: u64,
    duration_ns: u64,
    ops_per_sec: f64,
    latency_ns: Latency,
    bytes: Bytes,
    io: IO,
    alloc: Alloc,
    errors_total: u64 = 0,
    notes: ?std.json.Value = null,
    stability: ?Stability = null,
};

pub const Stability = struct {
    coefficient_of_variation: f64,
    is_stable: bool,
    repeat_count: u32,
    threshold_used: f64,
};

pub const Latency = struct {
    p50: u64,
    p95: u64,
    p99: u64,
    max: u64,
};

pub const Bytes = struct {
    read_total: u64,
    write_total: u64,
};

pub const IO = struct {
    fsync_count: u64,
    fdatasync_count: u64 = 0,
    open_count: u64 = 0,
    close_count: u64 = 0,
    mmap_faults: u64 = 0,
};

pub const Alloc = struct {
    alloc_count: u64,
    alloc_bytes: u64,
};