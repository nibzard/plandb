//! System metadata collection for benchmark profiling.
//!
//! Provides cross-platform detection of hardware and system information
//! including CPU model, filesystem type, memory capacity, and OS details.
//! This ensures consistent benchmark metadata collection across Linux,
//! macOS, and other Unix-like systems.

const std = @import("std");
const builtin = @import("builtin");

pub const SystemInfo = struct {
    cpu_model: ?[]const u8,
    core_count: u32,
    ram_gb: f64,
    os_name: []const u8,
    fs_type: ?[]const u8,
};

/// Detect system information in a cross-platform manner
/// Returns allocated strings that must be freed by the caller
pub fn detectSystemInfo(allocator: std.mem.Allocator) !SystemInfo {
    const core_count = @as(u32, @intCast(try std.Thread.getCpuCount()));
    const os_name = getOsName();

    // Detect CPU model (platform-specific)
    const cpu_model = try detectCpuModel(allocator);

    // Detect RAM (platform-specific)
    const ram_gb = try detectRamGb();

    // Detect filesystem type (context-dependent)
    const fs_type = try detectFilesystemType(allocator);

    return SystemInfo{
        .cpu_model = cpu_model,
        .core_count = core_count,
        .ram_gb = ram_gb,
        .os_name = os_name,
        .fs_type = fs_type,
    };
}

/// Free allocated strings in SystemInfo
pub fn freeSystemInfo(allocator: std.mem.Allocator, info: SystemInfo) void {
    if (info.cpu_model) |cpu| {
        allocator.free(cpu);
    }
    if (info.fs_type) |fs| {
        allocator.free(fs);
    }
}

/// Get OS name as string
fn getOsName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .dragonfly => "dragonfly",
        else => "unknown",
    };
}

/// Detect CPU model string across platforms
fn detectCpuModel(allocator: std.mem.Allocator) !?[]const u8 {
    switch (builtin.os.tag) {
        .linux => return detectCpuModelLinux(allocator),
        .macos => return detectCpuModelMacOs(allocator),
        else => return null,
    }
}

/// Linux CPU model detection via /proc/cpuinfo
fn detectCpuModelLinux(allocator: std.mem.Allocator) !?[]const u8 {
    const file = std.fs.cwd().openFile("/proc/cpuinfo", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = buf[0..bytes_read];

    // Look for "model name" line
    var it = std.mem.tokenizeScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOf(u8, line, ":")) |colon_idx| {
                const model_part = line[colon_idx + 1..];
                const model_name = std.mem.trim(u8, model_part, " \t");
                if (model_name.len > 0) {
                    return try allocator.dupeZ(u8, model_name);
                }
            }
        }
    }

    return null;
}

/// macOS CPU model detection via sysctl
fn detectCpuModelMacOs(allocator: std.mem.Allocator) !?[]const u8 {
    var size: usize = 0;

    // Get required buffer size
    const get_size_err = std.posix.sysctlbyname("machdep.cpu.brand_string", null, &size, null, 0);
    if (get_size_err != null) return null;

    // Allocate buffer and get actual string
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    const get_err = std.posix.sysctlbyname("machdep.cpu.brand_string", buf.ptr, &size, null, 0);
    if (get_err != null) return null;

    // Trim trailing null and spaces
    const cpu_model = std.mem.trimRight(u8, buf, "\x00 ");
    if (cpu_model.len == 0) return null;

    return try allocator.dupeZ(u8, cpu_model);
}

/// Detect total RAM in GB across platforms
fn detectRamGb() !f64 {
    switch (builtin.os.tag) {
        .linux => return detectRamGbLinux(),
        .macos => return detectRamGbMacOs(),
        else => return 4.0, // Conservative fallback
    }
}

/// Linux RAM detection via /proc/meminfo
fn detectRamGbLinux() !f64 {
    const file = std.fs.cwd().openFile("/proc/meminfo", .{}) catch |err| switch (err) {
        error.FileNotFound => return 4.0,
        else => return err,
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = buf[0..bytes_read];

    // Look for "MemTotal" line
    var it = std.mem.tokenizeScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal")) {
            var parts_it = std.mem.tokenizeAny(u8, line, " \t:");
            _ = parts_it.next(); // Skip "MemTotal"
            if (parts_it.next()) |value_str| {
                if (std.fmt.parseFloat(f64, value_str)) |kb| {
                    return kb / (1024.0 * 1024.0); // Convert KB to GB
                } else |_| {
                    // Try parsing as integer first
                    if (std.fmt.parseInt(u64, value_str, 10)) |kb_int| {
                        return @as(f64, @floatFromInt(kb_int)) / (1024.0 * 1024.0);
                    } else |_| {}
                }
            }
        }
    }

    return 4.0; // Fallback
}

/// macOS RAM detection via sysctl
fn detectRamGbMacOs() !f64 {
    var size: usize = @sizeOf(u64);
    var mem_bytes: u64 = undefined;

    const err = std.posix.sysctlbyname("hw.memsize", &mem_bytes, &size, null, 0);
    if (err != null) return 4.0;

    return @as(f64, @floatFromInt(mem_bytes)) / (1024.0 * 1024.0 * 1024.0); // Convert bytes to GB
}

/// Detect filesystem type for the current working directory
fn detectFilesystemType(allocator: std.mem.Allocator) !?[]const u8 {
    switch (builtin.os.tag) {
        .linux => return detectFilesystemTypeLinux(allocator),
        .macos => return detectFilesystemTypeMacOs(allocator),
        else => return null,
    }
}

/// Linux filesystem type detection via /proc/mounts or statvfs
fn detectFilesystemTypeLinux(allocator: std.mem.Allocator) !?[]const u8 {
    // Try /proc/mounts first
    if (detectFilesystemTypeFromMounts(allocator)) |fs_type| {
        return fs_type;
    } else |_| {}

    // Fallback: try statfs system call
    return detectFilesystemTypeFromStatfs(allocator);
}

fn detectFilesystemTypeFromMounts(allocator: std.mem.Allocator) !?[]const u8 {
    const file = std.fs.cwd().openFile("/proc/mounts", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = buf[0..bytes_read];

    // Get current working directory
    var cwd_buf: [4096]u8 = undefined;
    const cwd_path = std.posix.getcwd(&cwd_buf) catch return null;

    var it = std.mem.tokenizeScalar(u8, content, '\n');
    while (it.next()) |line| {
        var parts_it = std.mem.tokenizeAny(u8, line, " \t");
        _ = parts_it.next() orelse continue; // device (unused)
        const mount_point = parts_it.next() orelse continue;
        const fs_type_str = parts_it.next() orelse continue;

        // Check if this mount point matches or contains our cwd
        if (std.mem.startsWith(u8, cwd_path, mount_point)) {
            // Normalize filesystem name
            const normalized = normalizeFsName(fs_type_str);
            if (normalized.len > 0) {
                return try allocator.dupeZ(u8, normalized);
            }
        }
    }

    return null;
}

fn detectFilesystemTypeFromStatfs(allocator: std.mem.Allocator) !?[]const u8 {
    _ = allocator;
    // This is a simplified fallback implementation
    // A full implementation would use the appropriate statfs call for the platform
    return null;
}

/// macOS filesystem type detection
fn detectFilesystemTypeMacOs(allocator: std.mem.Allocator) !?[]const u8 {
    _ = allocator;
    // This is a simplified implementation for macOS
    // A full implementation would use the appropriate statfs call for macOS
    return null;
}

/// Normalize filesystem names to common identifiers
fn normalizeFsName(fs_name: []const u8) []const u8 {
    // Common filesystem mappings
    if (std.mem.eql(u8, fs_name, "ext4")) return "ext4";
    if (std.mem.eql(u8, fs_name, "ext3")) return "ext3";
    if (std.mem.eql(u8, fs_name, "ext2")) return "ext2";
    if (std.mem.eql(u8, fs_name, "xfs")) return "xfs";
    if (std.mem.eql(u8, fs_name, "btrfs")) return "btrfs";
    if (std.mem.eql(u8, fs_name, "zfs")) return "zfs";
    if (std.mem.eql(u8, fs_name, "tmpfs")) return "tmpfs";
    if (std.mem.eql(u8, fs_name, "nfs")) return "nfs";
    if (std.mem.eql(u8, fs_name, "nfs4")) return "nfs4";
    if (std.mem.eql(u8, fs_name, "cifs")) return "cifs";
    if (std.mem.eql(u8, fs_name, "smb3")) return "smb3";
    if (std.mem.eql(u8, fs_name, "fuseblk")) return "fuseblk";
    if (std.mem.eql(u8, fs_name, "apfs")) return "apfs";
    if (std.mem.eql(u8, fs_name, "hfs")) return "hfs";

    return fs_name;
}

// Tests for system info detection
test "detect system info on current platform" {
    const allocator = std.testing.allocator;
    const info = try detectSystemInfo(allocator);

    // Basic sanity checks
    try std.testing.expect(info.core_count > 0);
    try std.testing.expect(info.ram_gb > 0.5);
    try std.testing.expect(info.os_name.len > 0);

    // CPU model and filesystem type might be null on some platforms
    if (info.cpu_model) |cpu| {
        try std.testing.expect(cpu.len > 0);
    }

    if (info.fs_type) |fs| {
        try std.testing.expect(fs.len > 0);
    }

    // Clean up allocated strings
    if (info.cpu_model) |cpu| {
        allocator.free(cpu);
    }
    if (info.fs_type) |fs| {
        allocator.free(fs);
    }
}