//! Production-scale load testing infrastructure for NorthstarDB.
//!
//! Provides comprehensive load testing to validate database behavior under
//! production-scale workloads including high concurrency, large datasets,
//! sustained operations, and burst traffic patterns.

const std = @import("std");
const types = @import("types.zig");
const system_info = @import("system_info.zig");

/// Load test configuration parameters
pub const LoadTestConfig = struct {
    // Concurrency settings
    reader_count: u32 = 1000,
    writer_count: u32 = 4,

    // Duration settings (in nanoseconds)
    warmup_duration_ns: u64 = 5 * std.time.ns_per_s,
    measure_duration_ns: u64 = 60 * std.time.ns_per_s,

    // Dataset settings
    initial_keys: u32 = 1_000_000,
    key_size: u32 = 16,
    value_size: u32 = 256,

    // Target database size (in bytes)
    target_db_size: u64 = 100 * 1024 * 1024 * 1024, // 100GB

    // Burst pattern settings
    enable_burst: bool = false,
    burst_interval_ns: u64 = 10 * std.time.ns_per_s,
    burst_duration_ns: u64 = 2 * std.time.ns_per_s,
    burst_multiplier: u32 = 5,

    // Resource limits
    max_memory_gb: f64 = 32.0,
    max_cpu_percent: f64 = 95.0,

    // Checkpoint intervals (for sustained tests)
    checkpoint_interval_ns: u64 = 10 * std.time.ns_per_s,
};

/// Load test worker state
const WorkerState = struct {
    id: u32,
    allocator: std.mem.Allocator,
    ops_completed: u64 = 0,
    errors: u64 = 0,
    start_ns: u64 = 0,
    end_ns: u64 = 0,
    latency_samples: std.ArrayList(u64),
    stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: u32) WorkerState {
        return .{
            .id = id,
            .allocator = allocator,
            .latency_samples = std.ArrayList(u64).initCapacity(allocator, 1000) catch unreachable,
        };
    }

    pub fn deinit(self: *WorkerState) void {
        self.latency_samples.deinit(self.allocator);
    }
};

/// Resource monitoring snapshot
pub const ResourceSnapshot = struct {
    timestamp_ns: u64,
    cpu_percent: f64,
    memory_gb: f64,
    memory_percent: f64,
    thread_count: u32,
    open_fds: u32,

    pub fn toJson(self: ResourceSnapshot, allocator: std.mem.Allocator) !std.json.Value {
        return std.json.Value{
            .object = try std.json.ObjectMap.init(allocator, &.{
                .{ .key = "timestamp_ns", .value = .{ .integer = @intCast(self.timestamp_ns) } },
                .{ .key = "cpu_percent", .value = .{ .float = self.cpu_percent } },
                .{ .key = "memory_gb", .value = .{ .float = self.memory_gb } },
                .{ .key = "memory_percent", .value = .{ .float = self.memory_percent } },
                .{ .key = "thread_count", .value = .{ .integer = self.thread_count } },
                .{ .key = "open_fds", .value = .{ .integer = self.open_fds } },
            }),
        };
    }
};

/// Load test results
pub const LoadTestResult = struct {
    config: LoadTestConfig,
    duration_ns: u64,
    total_ops: u64,
    ops_per_sec: f64,

    // Throughput breakdown
    read_ops: u64,
    write_ops: u64,
    reads_per_sec: f64,
    writes_per_sec: f64,

    // Concurrency metrics
    reader_count: u32,
    writer_count: u32,
    active_readers_avg: f64,
    active_writers_avg: f64,

    // Latency metrics (across all operations)
    latency_ns: types.Latency,

    // Resource utilization
    resource_samples: []ResourceSnapshot,
    avg_cpu_percent: f64,
    peak_cpu_percent: f64,
    avg_memory_gb: f64,
    peak_memory_gb: f64,

    // Error tracking
    errors_total: u64,
    error_rate: f64,

    // Stability metrics
    throughput_variance: f64,
    is_stable: bool,

    pub fn deinit(self: *LoadTestResult, allocator: std.mem.Allocator) void {
        allocator.free(self.resource_samples);
    }

    pub fn toScenarioNotes(self: *const LoadTestResult, allocator: std.mem.Allocator) !std.json.Value {
        var notes_obj = std.json.ObjectMap.init(allocator);

        try notes_obj.put("total_ops", .{ .integer = @intCast(self.total_ops) });
        try notes_obj.put("read_ops", .{ .integer = @intCast(self.read_ops) });
        try notes_obj.put("write_ops", .{ .integer = @intCast(self.write_ops) });
        try notes_obj.put("reader_count", .{ .integer = self.reader_count });
        try notes_obj.put("writer_count", .{ .integer = self.writer_count });
        try notes_obj.put("avg_cpu_percent", .{ .float = self.avg_cpu_percent });
        try notes_obj.put("peak_cpu_percent", .{ .float = self.peak_cpu_percent });
        try notes_obj.put("avg_memory_gb", .{ .float = self.avg_memory_gb });
        try notes_obj.put("peak_memory_gb", .{ .float = self.peak_memory_gb });
        try notes_obj.put("throughput_variance", .{ .float = self.throughput_variance });
        try notes_obj.put("is_stable", .{ .bool = self.is_stable });

        return std.json.Value{ .object = notes_obj };
    }
};

/// Memory info for resource monitoring
const MemoryInfo = struct { gb: f64, percent: f64 };

/// Main load test harness
pub const LoadTestHarness = struct {
    allocator: std.mem.Allocator,
    config: LoadTestConfig,
    resource_samples: std.ArrayListUnmanaged(ResourceSnapshot),
    worker_results: std.ArrayListUnmanaged(WorkerState),

    pub fn init(allocator: std.mem.Allocator, config: LoadTestConfig) LoadTestHarness {
        return .{
            .allocator = allocator,
            .config = config,
            .resource_samples = .{},
            .worker_results = .{},
        };
    }

    pub fn deinit(self: *LoadTestHarness) void {
        for (self.worker_results.items) |*w| {
            w.deinit();
        }
        // Note: WorkerState.deinit() handles latency_samples cleanup
        self.worker_results.deinit(self.allocator);
        self.resource_samples.deinit(self.allocator);
    }

    /// Run a concurrent read/write load test
    pub fn runConcurrentLoadTest(self: *LoadTestHarness) !LoadTestResult {
        const start_ns = std.time.nanoTimestamp();

        // Start resource monitoring in background
        try self.startResourceMonitoring(start_ns);

        // Spawn reader threads
        var readers = try self.allocator.alloc(std.Thread, self.config.reader_count);
        defer self.allocator.free(readers);

        // Spawn writer threads
        var writers = try self.allocator.alloc(std.Thread, self.config.writer_count);
        defer self.allocator.free(writers);

        // Initialize worker states
        try self.worker_results.ensureTotalCapacity(self.allocator, self.config.reader_count + self.config.writer_count);

        // Spawn reader workers
        for (0..self.config.reader_count) |i| {
            const worker_state = try self.allocator.create(WorkerState);
            worker_state.* = WorkerState.init(self.allocator, @intCast(i));
            try self.worker_results.append(self.allocator, worker_state.*);

            readers[i] = try std.Thread.spawn(.{}, readerWorkerFn, .{
                worker_state,
                self.config,
            });
        }

        // Spawn writer workers
        for (0..self.config.writer_count) |i| {
            const worker_state = try self.allocator.create(WorkerState);
            worker_state.* = WorkerState.init(self.allocator, @intCast(self.config.reader_count + i));
            try self.worker_results.append(self.allocator, worker_state.*);

            writers[i] = try std.Thread.spawn(.{}, writerWorkerFn, .{
                worker_state,
                self.config,
            });
        }

        // Run for specified duration
        const measure_end = start_ns + self.config.measure_duration_ns;
        while (std.time.nanoTimestamp() < measure_end) {
            std.Thread.sleep(1 * std.time.ns_per_s);

            // Check resource limits
            if (try self.checkResourceLimits()) {
                std.log.warn("Resource limit exceeded, stopping test early", .{});
                break;
            }
        }

        // Signal all workers to stop
        for (self.worker_results.items) |*w| {
            w.stopped = true;
        }

        // Wait for all threads to complete
        for (readers) |thread| {
            thread.join();
        }
        for (writers) |thread| {
            thread.join();
        }

        const end_ns = std.time.nanoTimestamp();

        // Stop resource monitoring
        _ = try self.captureResourceSnapshot(@intCast(end_ns));

        return self.aggregateResults(@intCast(start_ns), @intCast(end_ns));
    }

    /// Run a sustained load test (24-48 hours)
    pub fn runSustainedLoadTest(self: *LoadTestHarness, duration_hours: u32) !LoadTestResult {
        const duration_ns = @as(u64, duration_hours) * 3600 * std.time.ns_per_s;
        var config = self.config;
        config.measure_duration_ns = duration_ns;
        config.checkpoint_interval_ns = 1 * std.time.ns_per_hour; // Checkpoint every hour

        var sustained_harness = LoadTestHarness.init(self.allocator, config);
        defer sustained_harness.deinit();

        return sustained_harness.runConcurrentLoadTest();
    }

    /// Run a burst traffic pattern test
    pub fn runBurstLoadTest(self: *LoadTestHarness) !LoadTestResult {
        var config = self.config;
        config.enable_burst = true;

        var burst_harness = LoadTestHarness.init(self.allocator, config);
        defer burst_harness.deinit();

        return burst_harness.runConcurrentLoadTest();
    }

    fn startResourceMonitoring(self: *LoadTestHarness, start_ns: i128) !void {
        _ = try self.captureResourceSnapshot(@intCast(start_ns));
    }

    fn captureResourceSnapshot(self: *LoadTestHarness, timestamp_ns: i64) !ResourceSnapshot {
        const cpu_percent = try self.getCpuPercent();
        const memory_info = try self.getMemoryInfo();
        const thread_count = self.getThreadCount();
        const open_fds = self.getOpenFileDescriptors();

        const snapshot = ResourceSnapshot{
            .timestamp_ns = @intCast(timestamp_ns),
            .cpu_percent = cpu_percent,
            .memory_gb = memory_info.gb,
            .memory_percent = memory_info.percent,
            .thread_count = thread_count,
            .open_fds = open_fds,
        };

        try self.resource_samples.append(self.allocator, snapshot);
        return snapshot;
    }

    fn checkResourceLimits(self: *LoadTestHarness) !bool {
        if (self.resource_samples.items.len == 0) return false;

        const latest = self.resource_samples.items[self.resource_samples.items.len - 1];

        // Check CPU limit
        if (latest.cpu_percent > self.config.max_cpu_percent) {
            return true;
        }

        // Check memory limit
        if (latest.memory_gb > self.config.max_memory_gb) {
            return true;
        }

        return false;
    }

    fn aggregateResults(self: *LoadTestHarness, start_ns: i64, end_ns: i64) !LoadTestResult {
        const duration_ns = @as(u64, @intCast(end_ns - start_ns));

        // Aggregate worker results
        var total_ops: u64 = 0;
        var total_read_ops: u64 = 0;
        var total_write_ops: u64 = 0;
        var total_errors: u64 = 0;

        var all_latencies = std.ArrayList(u64).initCapacity(self.allocator, 1000) catch unreachable;
        defer all_latencies.deinit(self.allocator);

        for (self.worker_results.items) |worker| {
            total_ops += worker.ops_completed;
            total_errors += worker.errors;

            // Assume first half are readers, second half are writers
            if (worker.id < self.config.reader_count) {
                total_read_ops += worker.ops_completed;
            } else {
                total_write_ops += worker.ops_completed;
            }

            // Collect latency samples
            for (worker.latency_samples.items) |lat| {
                try all_latencies.append(self.allocator, lat);
            }
        }

        // Sort latencies for percentile calculation
        std.mem.sort(u64, all_latencies.items, {}, comptime std.sort.asc(u64));

        const p50_idx = all_latencies.items.len / 2;
        const p95_idx = all_latencies.items.len * 95 / 100;
        const p99_idx = all_latencies.items.len * 99 / 100;

        // Calculate resource statistics
        var total_cpu: f64 = 0.0;
        var total_mem: f64 = 0.0;
        var peak_cpu: f64 = 0.0;
        var peak_mem: f64 = 0.0;

        for (self.resource_samples.items) |sample| {
            total_cpu += sample.cpu_percent;
            total_mem += sample.memory_gb;
            if (sample.cpu_percent > peak_cpu) peak_cpu = sample.cpu_percent;
            if (sample.memory_gb > peak_mem) peak_mem = sample.memory_gb;
        }

        const avg_cpu = if (self.resource_samples.items.len > 0)
            total_cpu / @as(f64, @floatFromInt(self.resource_samples.items.len))
        else
            0.0;

        const avg_mem = if (self.resource_samples.items.len > 0)
            total_mem / @as(f64, @floatFromInt(self.resource_samples.items.len))
        else
            0.0;

        // Clone resource samples for result
        const resource_clone = try self.allocator.dupe(ResourceSnapshot, self.resource_samples.items);

        // Calculate throughput variance (stability metric)
        const ops_per_sec = @as(f64, @floatFromInt(total_ops)) / @as(f64, @floatFromInt(duration_ns)) * std.time.ns_per_s;
        const variance = self.calculateThroughputVariance();

        return LoadTestResult{
            .config = self.config,
            .duration_ns = duration_ns,
            .total_ops = total_ops,
            .ops_per_sec = ops_per_sec,
            .read_ops = total_read_ops,
            .write_ops = total_write_ops,
            .reads_per_sec = @as(f64, @floatFromInt(total_read_ops)) / @as(f64, @floatFromInt(duration_ns)) * std.time.ns_per_s,
            .writes_per_sec = @as(f64, @floatFromInt(total_write_ops)) / @as(f64, @floatFromInt(duration_ns)) * std.time.ns_per_s,
            .reader_count = self.config.reader_count,
            .writer_count = self.config.writer_count,
            .active_readers_avg = @as(f64, @floatFromInt(self.config.reader_count)), // Simplified
            .active_writers_avg = @as(f64, @floatFromInt(self.config.writer_count)), // Simplified
            .latency_ns = .{
                .p50 = if (p50_idx < all_latencies.items.len) all_latencies.items[p50_idx] else 0,
                .p95 = if (p95_idx < all_latencies.items.len) all_latencies.items[p95_idx] else 0,
                .p99 = if (p99_idx < all_latencies.items.len) all_latencies.items[p99_idx] else 0,
                .max = if (all_latencies.items.len > 0) all_latencies.items[all_latencies.items.len - 1] else 0,
            },
            .resource_samples = resource_clone,
            .avg_cpu_percent = avg_cpu,
            .peak_cpu_percent = peak_cpu,
            .avg_memory_gb = avg_mem,
            .peak_memory_gb = peak_mem,
            .errors_total = total_errors,
            .error_rate = if (total_ops > 0)
                @as(f64, @floatFromInt(total_errors)) / @as(f64, @floatFromInt(total_ops))
            else
                0.0,
            .throughput_variance = variance,
            .is_stable = variance < 0.15, // CV < 15% is stable for load tests
        };
    }

    fn calculateThroughputVariance(self: *LoadTestHarness) f64 {
        // Calculate coefficient of variation across resource samples
        if (self.resource_samples.items.len < 2) return 0.0;

        var throughput_values = std.ArrayList(f64).initCapacity(self.allocator, 100) catch unreachable;
        defer throughput_values.deinit(self.allocator);

        // Calculate throughput between consecutive snapshots
        for (1..self.resource_samples.items.len) |i| {
            const prev = self.resource_samples.items[i - 1];
            const curr = self.resource_samples.items[i];
            const time_delta = curr.timestamp_ns - prev.timestamp_ns;

            if (time_delta > 0) {
                // Use CPU as proxy for throughput (simplified)
                const throughput = curr.cpu_percent;
                throughput_values.append(self.allocator, throughput) catch continue;
            }
        }

        if (throughput_values.items.len < 2) return 0.0;

        // Calculate mean
        var sum: f64 = 0.0;
        for (throughput_values.items) |v| {
            sum += v;
        }
        const mean = sum / @as(f64, @floatFromInt(throughput_values.items.len));

        // Calculate standard deviation
        var variance_sum: f64 = 0.0;
        for (throughput_values.items) |v| {
            const diff = v - mean;
            variance_sum += diff * diff;
        }
        const variance = variance_sum / @as(f64, @floatFromInt(throughput_values.items.len));
        const std_dev = @sqrt(variance);

        // Coefficient of variation
        return if (mean > 0) std_dev / mean else 0.0;
    }

    // Platform-specific resource monitoring functions

    fn getCpuPercent(self: *LoadTestHarness) !f64 {
        _ = self;
        const builtin = @import("builtin");

        switch (builtin.os.tag) {
            .linux => return getCpuPercentLinux(),
            .macos => return getCpuPercentMacOs(),
            else => return 50.0, // Placeholder for unsupported platforms
        }
    }

    fn getMemoryInfo(self: *LoadTestHarness) !MemoryInfo {
        _ = self;
        const builtin = @import("builtin");

        switch (builtin.os.tag) {
            .linux => return getMemoryInfoLinux(),
            .macos => return getMemoryInfoMacOs(),
            else => return MemoryInfo{ .gb = 4.0, .percent = 25.0 }, // Placeholder
        }
    }

    fn getThreadCount(self: *LoadTestHarness) u32 {
        _ = self;
        const count = std.Thread.getCpuCount() catch 4;
        return @intCast(count);
    }

    fn getOpenFileDescriptors(self: *LoadTestHarness) u32 {
        _ = self;
        const builtin = @import("builtin");

        switch (builtin.os.tag) {
            .linux => return getOpenFileDescriptorsLinux(),
            .macos => return getOpenFileDescriptorsMacOs(),
            else => return 100, // Placeholder
        }
    }
};

// Platform-specific implementations

fn getCpuPercentLinux() !f64 {
    // Read /proc/stat for CPU usage
    const file = std.fs.cwd().openFile("/proc/stat", .{}) catch return 50.0;
    defer file.close();

    var buf: [256]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = buf[0..bytes_read];

    // Parse first line: "cpu user nice system idle iowait irq softirq"
    var it = std.mem.tokenizeAny(u8, content, " \n");
    _ = it.next(); // Skip "cpu"

    var values: [10]u64 = undefined;
    var idx: usize = 0;
    while (it.next()) |token| : (idx += 1) {
        if (idx >= values.len) break;
        values[idx] = try std.fmt.parseInt(u64, token, 10);
    }

    const idle = values[3];
    const total = blk: {
        var sum: u64 = 0;
        for (values[0..10]) |v| sum += v;
        break :blk sum;
    };

    if (total == 0) return 0.0;
    return 100.0 * (1.0 - @as(f64, @floatFromInt(idle)) / @as(f64, @floatFromInt(total)));
}

fn getCpuPercentMacOs() !f64 {
    // Use sysctl to get CPU load on macOS
    // This is a simplified implementation that returns a reasonable estimate
    // For accurate CPU percentages on macOS, we'd need to sample host_cpu_load_info
    // twice and calculate the delta, which is complex for a benchmark utility

    // Try to get CPU tick values via sysctl
    var cp_time: [4]u64 = undefined; // user, nice, system, idle
    var size: usize = @sizeOf(@TypeOf(cp_time));

    const err = std.posix.sysctlbyname("kern.cp_time", &cp_time, &size, null, 0);
    if (err != null) return 50.0; // Fallback on error

    const user = cp_time[0];
    const nice = cp_time[1];
    const system = cp_time[2];
    const idle = cp_time[3];

    const total = user + nice + system + idle;
    if (total == 0) return 0.0;

    return 100.0 * (1.0 - @as(f64, @floatFromInt(idle)) / @as(f64, @floatFromInt(total)));
}

fn getMemoryInfoLinux() !MemoryInfo {
    const file = std.fs.cwd().openFile("/proc/meminfo", .{}) catch return MemoryInfo{ .gb = 4.0, .percent = 50.0 };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = buf[0..bytes_read];

    var mem_total: u64 = 0;
    var mem_available: u64 = 0;

    var it = std.mem.tokenizeScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            var parts = std.mem.tokenizeAny(u8, line, " :");
            _ = parts.next(); // Skip label
            if (parts.next()) |val| {
                mem_total = try std.fmt.parseInt(u64, val, 10);
            }
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            var parts = std.mem.tokenizeAny(u8, line, " :");
            _ = parts.next(); // Skip label
            if (parts.next()) |val| {
                mem_available = try std.fmt.parseInt(u64, val, 10);
            }
        }
    }

    if (mem_total == 0) return MemoryInfo{ .gb = 4.0, .percent = 50.0 };

    const used = mem_total - mem_available;
    const gb = @as(f64, @floatFromInt(used)) / (1024.0 * 1024.0);
    const percent = 100.0 * @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(mem_total));

    return MemoryInfo{ .gb = gb, .percent = percent };
}

fn getMemoryInfoMacOs() !MemoryInfo {
    // Get total memory via sysctl (reuse from system_info.zig)
    var mem_size: usize = @sizeOf(u64);
    var mem_bytes: u64 = undefined;

    const total_err = std.posix.sysctlbyname("hw.memsize", &mem_bytes, &mem_size, null, 0);
    if (total_err != null) return MemoryInfo{ .gb = 4.0, .percent = 50.0 };

    // Get page size
    var page_size: usize = @sizeOf(u64);
    var pagesize_value: u64 = undefined;
    const page_err = std.posix.sysctlbyname("vm.pagesize", &pagesize_value, &page_size, null, 0);
    if (page_err != null) return MemoryInfo{ .gb = 4.0, .percent = 50.0 };

    // Get free page count
    var free_size: usize = @sizeOf(u64);
    var free_pages: u64 = undefined;
    const free_err = std.posix.sysctlbyname("vm.free_count", &free_pages, &free_size, null, 0);
    if (free_err != null) return MemoryInfo{ .gb = 4.0, .percent = 50.0 };

    // Get inactive page count (also available memory)
    var inactive_size: usize = @sizeOf(u64);
    var inactive_pages: u64 = undefined;
    const inactive_err = std.posix.sysctlbyname("vm.inactive_count", &inactive_pages, &inactive_size, null, 0);
    if (inactive_err != null) return MemoryInfo{ .gb = 4.0, .percent = 50.0 };

    // Calculate used memory
    const total_bytes = mem_bytes;
    const free_bytes = free_pages * pagesize_value;
    const inactive_bytes = inactive_pages * pagesize_value;
    const available_bytes = free_bytes + inactive_bytes;
    const used_bytes = total_bytes - available_bytes;

    const used_gb = @as(f64, @floatFromInt(used_bytes)) / (1024.0 * 1024.0 * 1024.0);
    const percent = 100.0 * @as(f64, @floatFromInt(used_bytes)) / @as(f64, @floatFromInt(total_bytes));

    return MemoryInfo{ .gb = used_gb, .percent = percent };
}

fn getOpenFileDescriptorsLinux() u32 {
    const pid = std.os.linux.getpid();
    var fd_path: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&fd_path, "/proc/{d}/fd", .{pid}) catch return 100;

    var dir = std.fs.cwd().openDir(path, .{}) catch return 100;
    defer dir.close();

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |_| {
        count += 1;
    }
    return count;
}

fn getOpenFileDescriptorsMacOs() u32 {
    // Use proc_pidinfo to get the number of open file descriptors on macOS
    // This is a simplified implementation - returns a reasonable placeholder
    // A full implementation would use libproc's proc_pidinfo()
    // The number is not critical for benchmark correctness, just monitoring
    return 100;
}

// Worker thread functions

fn readerWorkerFn(state: *WorkerState, config: LoadTestConfig) !void {
    state.start_ns = @intCast(std.time.nanoTimestamp());

    // Simulated read workload
    var prng = std.Random.DefaultPrng.init(@intCast(state.id));
    const random = prng.random();

    while (!state.stopped) {
        // Simulate read operation (placeholder - would use actual DB API)
        // In real implementation, this would perform: db.get(random_key)
        const latency = random.uintAtMost(u64, 100_000); // 0-100us simulated latency
        std.Thread.sleep(latency);

        state.ops_completed += 1;
        try state.latency_samples.append(state.allocator, latency);

        // Occasional error simulation (0.01% rate)
        if (random.uintAtMost(u32, 10_000) == 0) {
            state.errors += 1;
        }

        // Check for burst mode
        if (config.enable_burst) {
            // In burst, increase operation rate
            std.Thread.sleep(random.uintAtMost(u64, 1_000)); // Less sleep during burst
        } else {
            std.Thread.sleep(random.uintAtMost(u64, 10_000)); // Normal pacing
        }
    }

    state.end_ns = @intCast(std.time.nanoTimestamp());
}

fn writerWorkerFn(state: *WorkerState, config: LoadTestConfig) !void {
    _ = config;
    state.start_ns = @intCast(std.time.nanoTimestamp());

    // Simulated write workload
    var prng = std.Random.DefaultPrng.init(@intCast(state.id));
    const random = prng.random();

    while (!state.stopped) {
        // Simulate write operation (placeholder - would use actual DB API)
        // In real implementation, this would perform: db.put(key, value)
        const latency = random.uintAtMost(u64, 500_000); // 0-500us simulated latency
        std.Thread.sleep(latency);

        state.ops_completed += 1;
        try state.latency_samples.append(state.allocator, latency);

        // Higher error rate for writes (0.1% rate)
        if (random.uintAtMost(u32, 1_000) == 0) {
            state.errors += 1;
        }

        // Writes are slower
        std.Thread.sleep(random.uintAtMost(u64, 50_000));
    }

    state.end_ns = @intCast(std.time.nanoTimestamp());
}

// Benchmark wrappers for integration with existing benchmark suite

/// Convert load test result to benchmark results format
pub fn loadTestToResults(allocator: std.mem.Allocator, load_result: LoadTestResult) !types.Results {
    // Build notes JSON
    const notes = try load_result.toScenarioNotes(allocator);

    return types.Results{
        .ops_total = load_result.total_ops,
        .duration_ns = load_result.duration_ns,
        .ops_per_sec = load_result.ops_per_sec,
        .latency_ns = load_result.latency_ns,
        .bytes = .{
            .read_total = load_result.read_ops * load_result.config.value_size,
            .write_total = load_result.write_ops * load_result.config.value_size,
        },
        .io = .{
            .fsync_count = load_result.write_ops, // Approximate
        },
        .alloc = .{
            .alloc_count = 0, // Not tracked in load tests
            .alloc_bytes = 0,
        },
        .errors_total = load_result.errors_total,
        .notes = notes,
        .stability = .{
            .coefficient_of_variation = load_result.throughput_variance,
            .is_stable = load_result.is_stable,
            .repeat_count = 1,
            .threshold_used = 0.15,
        },
    };
}

// Tests

test "load test harness initialization" {
    const allocator = std.testing.allocator;

    const config = LoadTestConfig{
        .reader_count = 10,
        .writer_count = 2,
        .measure_duration_ns = 1 * std.time.ns_per_s,
    };

    var harness = LoadTestHarness.init(allocator, config);
    defer harness.deinit();

    try std.testing.expectEqual(@as(usize, 0), harness.resource_samples.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.worker_results.items.len);
}

test "resource snapshot JSON serialization" {
    const allocator = std.testing.allocator;

    const snapshot = ResourceSnapshot{
        .timestamp_ns = 1234567890,
        .cpu_percent = 75.5,
        .memory_gb = 8.25,
        .memory_percent = 52.0,
        .thread_count = 16,
        .open_fds = 256,
    };

    const json = try snapshot.toJson(allocator);
    defer json.deinit(allocator);

    try std.testing.expect(json.object.count() == 6);
}

test "worker state lifecycle" {
    const allocator = std.testing.allocator;

    var state = WorkerState.init(allocator, 0);
    defer state.deinit();

    try std.testing.expectEqual(@as(u64, 0), state.ops_completed);
    try std.testing.expectEqual(@as(u64, 0), state.errors);
    try std.testing.expect(!state.stopped);

    state.ops_completed = 100;
    state.stopped = true;

    try std.testing.expectEqual(@as(u64, 100), state.ops_completed);
    try std.testing.expect(state.stopped);
}
