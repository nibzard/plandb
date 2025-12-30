//! Plugin security and sandboxing for NorthstarDB
//!
//! Provides permission management, sandboxing, and signature verification

const std = @import("std");
const packaging = @import("packaging.zig");

/// Security violation type
pub const SecurityViolation = struct {
    severity: Severity,
    field: []const u8,
    message: []const u8,

    pub const Severity = enum {
        warning,
        err,
        critical,
    };

    pub fn deinit(self: *SecurityViolation, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        allocator.free(self.message);
    }
};

/// Security policy validation result
pub const PolicyValidationResult = struct {
    is_safe: bool,
    violations: []SecurityViolation,

    pub fn deinit(self: *PolicyValidationResult, allocator: std.mem.Allocator) void {
        for (self.violations) |*v| v.deinit(allocator);
        allocator.free(self.violations);
    }
};

/// Security policy for plugin validation
pub const SecurityPolicy = struct {
    allow_network_access: bool = false,
    allow_filesystem_write: bool = false,
    allow_filesystem_read: bool = false,
    max_memory_mb: u32 = 256,
    max_cpu_percent: u8 = 50,
    max_llm_requests_per_hour: u32 = 100,
    require_signature: bool = false,
    allowed_domains: []const []const u8 = &[_][]const u8{},

    /// Validate plugin manifest against policy
    pub fn validateManifest(
        self: *const SecurityPolicy,
        allocator: std.mem.Allocator,
        manifest: *const packaging.PluginManifest
    ) !PolicyValidationResult {
        var violations = std.ArrayListUnmanaged(SecurityViolation){};
        errdefer {
            for (violations.items) |*v| v.deinit(allocator);
            violations.deinit(allocator);
        }

        const perms = manifest.permissions;

        // Check network access
        if (perms.network_access and !self.allow_network_access) {
            try violations.append(allocator, .{
                .severity = .err,
                .field = try allocator.dupe(u8, "permissions.network_access"),
                .message = try allocator.dupe(u8, "Network access is not allowed by policy"),
            });
        }

        // Check filesystem write
        if (perms.file_system_write and !self.allow_filesystem_write) {
            try violations.append(allocator, .{
                .severity = .err,
                .field = try allocator.dupe(u8, "permissions.file_system_write"),
                .message = try allocator.dupe(u8, "Filesystem write is not allowed by policy"),
            });
        }

        // Check filesystem read
        if (perms.file_system_read and !self.allow_filesystem_read) {
            try violations.append(allocator, .{
                .severity = .warning,
                .field = try allocator.dupe(u8, "permissions.file_system_read"),
                .message = try allocator.dupe(u8, "Filesystem read requires explicit permission"),
            });
        }

        // Check memory limits
        if (perms.max_memory_mb > self.max_memory_mb) {
            try violations.append(allocator, .{
                .severity = .err,
                .field = try allocator.dupe(u8, "permissions.max_memory_mb"),
                .message = try std.fmt.allocPrint(allocator, "Memory limit {}MB exceeds policy maximum {}MB", .{
                    perms.max_memory_mb, self.max_memory_mb
                }),
            });
        }

        // Check CPU limits
        if (perms.max_cpu_percent > self.max_cpu_percent) {
            try violations.append(allocator, .{
                .severity = .err,
                .field = try allocator.dupe(u8, "permissions.max_cpu_percent"),
                .message = try std.fmt.allocPrint(allocator, "CPU limit {}% exceeds policy maximum {}%", .{
                    perms.max_cpu_percent, self.max_cpu_percent
                }),
            });
        }

        // Check LLM rate limits
        if (perms.max_llm_requests_per_hour > self.max_llm_requests_per_hour) {
            try violations.append(allocator, .{
                .severity = .warning,
                .field = try allocator.dupe(u8, "permissions.max_llm_requests_per_hour"),
                .message = try std.fmt.allocPrint(allocator, "LLM rate limit {}/hr exceeds policy {}/hr", .{
                    perms.max_llm_requests_per_hour, self.max_llm_requests_per_hour
                }),
            });
        }

        // Check signature if required
        if (self.require_signature and manifest.checksum.len == 0) {
            try violations.append(allocator, .{
                .severity = .err,
                .field = try allocator.dupe(u8, "checksum"),
                .message = try allocator.dupe(u8, "Plugin signature is required by policy"),
            });
        }

        return PolicyValidationResult{
            .is_safe = blk: {
                for (violations.items) |v| {
                    if (v.severity == .err or v.severity == .critical) break :blk false;
                }
                break :blk true;
            },
            .violations = try violations.toOwnedSlice(allocator),
        };
    }
};

/// Default security policy for production use
pub const DefaultSecurityPolicy = SecurityPolicy{
    .allow_network_access = false,
    .allow_filesystem_write = false,
    .allow_filesystem_read = false,
    .max_memory_mb = 256,
    .max_cpu_percent = 50,
    .max_llm_requests_per_hour = 100,
    .require_signature = false,
    .allowed_domains = &[_][]const u8{},
};

/// Development security policy (more permissive)
pub const DevelopmentSecurityPolicy = SecurityPolicy{
    .allow_network_access = true,
    .allow_filesystem_write = true,
    .allow_filesystem_read = true,
    .max_memory_mb = 512,
    .max_cpu_percent = 80,
    .max_llm_requests_per_hour = 1000,
    .require_signature = false,
    .allowed_domains = &[_][]const u8{"api.openai.com", "api.anthropic.com"},
};

/// Sandbox for plugin execution
pub const PluginSandbox = struct {
    allocator: std.mem.Allocator,
    policy: SecurityPolicy,
    active: bool,
    stats: ResourceStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, policy: SecurityPolicy) Self {
        return Self{
            .allocator = allocator,
            .policy = policy,
            .active = true,
            .stats = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Execute a function within the sandbox
    pub fn execute(self: *Self, func: anytype, args: anytype) !@typeInfo(@TypeOf(func)).Fn.return_type.? {
        if (!self.active) {
            return @call(.auto, func, args);
        }

        // Track execution
        const start_time = std.time.nanoTimestamp();
        _ = start_time;

        // Execute function
        const result = @call(.auto, func, args);

        // TODO: Enforce resource limits
        self.stats.executions += 1;

        return result;
    }

    /// Execute a void function within the sandbox
    pub fn executeVoid(self: *Self, func: anytype, args: anytype) !void {
        if (!self.active) {
            @call(.auto, func, args);
            return;
        }

        // Track execution
        _ = std.time.nanoTimestamp();

        // Execute function
        @call(.auto, func, args);

        // TODO: Enforce resource limits
        self.stats.executions += 1;
    }

    /// Check if an operation is allowed by policy
    pub fn isAllowed(self: *const Self, operation: Operation) bool {
        return switch (operation) {
            .network_access => self.policy.allow_network_access,
            .filesystem_write => self.policy.allow_filesystem_write,
            .filesystem_read => self.policy.allow_filesystem_read,
            .llm_call => true, // Always allowed, subject to rate limiting
        };
    }

    /// Get current resource usage
    pub fn getStats(self: *const Self) ResourceStats {
        return self.stats;
    }

    pub const Operation = enum {
        network_access,
        filesystem_write,
        filesystem_read,
        llm_call,
    };
};

/// Resource usage statistics
pub const ResourceStats = struct {
    executions: u64 = 0,
    memory_used_mb: u32 = 0,
    cpu_time_ns: u64 = 0,
    llm_calls: u32 = 0,
    network_requests: u32 = 0,
    filesystem_reads: u32 = 0,
    filesystem_writes: u32 = 0,
};

/// Signature verification for plugins
pub const SignatureVerifier = struct {
    allocator: std.mem.Allocator,
    public_keys: std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .public_keys = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.public_keys.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.public_keys.deinit();
    }

    /// Add a trusted public key
    pub fn addPublicKey(self: *Self, key_id: []const u8, key_data: []const u8) !void {
        const key_id_copy = try self.allocator.dupe(u8, key_id);
        errdefer self.allocator.free(key_id_copy);

        const key_data_copy = try self.allocator.dupe(u8, key_data);
        errdefer self.allocator.free(key_data_copy);

        try self.public_keys.put(key_id_copy, key_data_copy);
    }

    /// Verify plugin package signature
    pub fn verify(self: *Self, package_path: []const u8, signature: []const u8) !bool {
        _ = package_path;
        _ = signature;

        // Simple verification - check if any public key exists
        // In production, this would use actual cryptographic verification
        return self.public_keys.count() > 0;
    }
};

/// Verify a plugin package signature
pub fn verifyPackageSignature(allocator: std.mem.Allocator, package_path: []const u8) !bool {
    // Check if .sig file exists
    const sig_path = try std.fmt.allocPrint(allocator, "{s}.sig", .{package_path});
    defer allocator.free(sig_path);

    const file = std.fs.cwd().openFile(sig_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return false;
        }
        return err;
    };
    defer file.close();

    // Read signature
    const signature = file.readToEndAlloc(allocator, 4096) catch |err| {
        if (err == error.IsDir) return false;
        return err;
    };
    defer allocator.free(signature);

    // In production, this would perform actual cryptographic verification
    // For now, we consider it verified if a signature file exists
    // We use the signature to avoid "pointless discard" error
    if (signature.len == 0) return false;
    return true;
}

/// Resource quota enforcement
pub const ResourceQuota = struct {
    max_memory_mb: u32,
    max_cpu_percent: u8,
    max_llm_requests_per_hour: u32,
    current_memory_mb: u32 = 0,
    current_cpu_percent: u8 = 0,
    llm_requests_this_hour: u32 = 0,
    hour_start: i64 = 0,

    pub fn init(max_memory_mb: u32, max_cpu_percent: u8, max_llm: u32) ResourceQuota {
        return ResourceQuota{
            .max_memory_mb = max_memory_mb,
            .max_cpu_percent = max_cpu_percent,
            .max_llm_requests_per_hour = max_llm,
            .hour_start = @as(i64, @intCast(std.time.nanoTimestamp())),
        };
    }

    /// Check if quota allows an LLM call
    pub fn checkLLMQuota(self: *ResourceQuota) !void {
        const now = @as(i64, @intCast(std.time.nanoTimestamp()));
        const hour_ns: i64 = 3_600_000_000_000;

        // Reset counter if hour has passed
        if (now - self.hour_start > hour_ns) {
            self.llm_requests_this_hour = 0;
            self.hour_start = now;
        }

        if (self.llm_requests_this_hour >= self.max_llm_requests_per_hour) {
            return error.QuotaExceeded;
        }
    }

    /// Record an LLM call
    pub fn recordLLMCall(self: *ResourceQuota) !void {
        try self.checkLLMQuota();
        self.llm_requests_this_hour += 1;
    }

    /// Get current quota usage
    pub fn getUsage(self: *const ResourceQuota) QuotaUsage {
        return .{
            .memory_used_mb = self.current_memory_mb,
            .memory_max_mb = self.max_memory_mb,
            .llm_requests = self.llm_requests_this_hour,
            .llm_max = self.max_llm_requests_per_hour,
        };
    }
};

pub const QuotaUsage = struct {
    memory_used_mb: u32,
    memory_max_mb: u32,
    llm_requests: u32,
    llm_max: u32,
};

/// Security context for running plugins
pub const SecurityContext = struct {
    sandbox: *PluginSandbox,
    quota: *ResourceQuota,

    pub fn init(sandbox: *PluginSandbox, quota: *ResourceQuota) SecurityContext {
        return .{
            .sandbox = sandbox,
            .quota = quota,
        };
    }

    /// Check if an operation is permitted
    pub fn checkPermission(self: *const SecurityContext, permission: packaging.Permissions.Permission) bool {
        _ = self;
        _ = permission;
        // TODO: implement permission checking
        return true;
    }
};

test "security_policy_validation" {
    const policy = &DefaultSecurityPolicy;

    var manifest = packaging.PluginManifest{
        .name = "test",
        .version = "1.0.0",
        .description = "Test",
        .author = "Test",
        .hooks = &[_][]const u8{},
        .permissions = .{
            .network_access = true,
            .max_memory_mb = 512,
        },
    };

    var result = try policy.validateManifest(std.testing.allocator, &manifest);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_safe); // Should fail due to network access
}

test "resource_quota" {
    var quota = ResourceQuota.init(256, 50, 10);

    // Should allow requests up to limit
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try quota.recordLLMCall();
    }

    // Should exceed quota
    try std.testing.expectError(error.QuotaExceeded, quota.recordLLMCall());
}

test "sandbox_permissions" {
    const policy = &DefaultSecurityPolicy;
    var sandbox = PluginSandbox.init(std.testing.allocator, policy.*);
    defer sandbox.deinit();

    try std.testing.expect(!sandbox.isAllowed(.network_access));
    try std.testing.expect(!sandbox.isAllowed(.filesystem_write));
    try std.testing.expect(sandbox.isAllowed(.llm_call));
}
