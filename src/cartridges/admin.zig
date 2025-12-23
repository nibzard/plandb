//! Admin introspection API for cartridges
//!
//! Provides administrative interface to inspect cartridge state,
//! rebuild status, metadata, and operational statistics.

const std = @import("std");
const ArrayListManaged = std.array_list.Managed;
const format = @import("format.zig");
const rebuild = @import("rebuild.zig");

/// Admin API for cartridge management
pub const CartridgeAdmin = struct {
    allocator: std.mem.Allocator,
    cartridge_dir: []const u8,
    registered_cartridges: std.StringHashMap(RegisteredCartridge),
    stats: GlobalStats,

    const Self = @This();

    /// Registered cartridge info
    const RegisteredCartridge = struct {
        path: []const u8,
        header: format.CartridgeHeader,
        metadata: format.CartridgeMetadata,
        last_accessed: i128,
        access_count: u64,
        rebuild_count: u64,

        pub fn init(
            allocator: std.mem.Allocator,
            path: []const u8,
            header: format.CartridgeHeader,
            metadata: format.CartridgeMetadata
        ) !RegisteredCartridge {
            return RegisteredCartridge{
                .path = try allocator.dupe(u8, path),
                .header = header,
                .metadata = metadata,
                .last_accessed = std.time.nanoTimestamp(),
                .access_count = 0,
                .rebuild_count = 0,
            };
        }

        pub fn deinit(self: *RegisteredCartridge, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.metadata.deinit(allocator);
        }
    };

    /// Global statistics
    const GlobalStats = struct {
        total_cartridges: u64 = 0,
        total_accesses: u64 = 0,
        total_rebuilds: u64 = 0,
        total_bytes_served: u64 = 0,
        total_errors: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, cartridge_dir: []const u8) Self {
        return CartridgeAdmin{
            .allocator = allocator,
            .cartridge_dir = cartridge_dir,
            .registered_cartridges = std.StringHashMap(RegisteredCartridge).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.registered_cartridges.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.registered_cartridges.deinit();
    }

    /// Register a cartridge with the admin system
    pub fn registerCartridge(
        self: *Self,
        name: []const u8,
        path: []const u8,
        header: format.CartridgeHeader,
        metadata: format.CartridgeMetadata
    ) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        var cartridge = try RegisteredCartridge.init(self.allocator, path, header, metadata);
        errdefer cartridge.deinit(self.allocator);

        try self.registered_cartridges.put(name_copy, cartridge);
        self.stats.total_cartridges += 1;
    }

    /// Unregister a cartridge
    pub fn unregisterCartridge(self: *Self, name: []const u8) !void {
        const entry = self.registered_cartridges.fetchRemove(name) orelse return error.CartridgeNotFound;
        self.allocator.free(entry.key);
        var value = entry.value;
        value.deinit(self.allocator);
        self.stats.total_cartridges -= 1;
    }

    /// Get cartridge info
    pub fn getCartridgeInfo(self: *Self, name: []const u8) !CartridgeInfo {
        var cartridge = self.registered_cartridges.getPtr(name) orelse return error.CartridgeNotFound;

        // Update access tracking
        cartridge.last_accessed = std.time.nanoTimestamp();
        cartridge.access_count += 1;
        self.stats.total_accesses += 1;

        return CartridgeInfo{
            .name = name,
            .path = cartridge.path,
            .cartridge_type = cartridge.header.cartridge_type,
            .source_txn_id = cartridge.header.source_txn_id,
            .entry_count = cartridge.header.entry_count,
            .created_at = cartridge.header.created_at,
            .file_size = self.getCartridgeSize(cartridge.path) catch 0,
            .access_count = cartridge.access_count,
            .rebuild_count = cartridge.rebuild_count,
            .last_accessed = cartridge.last_accessed,
        };
    }

    /// Get all registered cartridges
    pub fn listCartridges(self: *Self) ![]CartridgeInfo {
        var list = ArrayListManaged(CartridgeInfo).init(self.allocator);
        try list.ensureTotalCapacity(self.registered_cartridges.count());

        var it = self.registered_cartridges.iterator();
        while (it.next()) |entry| {
            const cartridge = entry.value_ptr.*;
            const info = CartridgeInfo{
                .name = entry.key_ptr.*,
                .path = cartridge.path,
                .cartridge_type = cartridge.header.cartridge_type,
                .source_txn_id = cartridge.header.source_txn_id,
                .entry_count = cartridge.header.entry_count,
                .created_at = cartridge.header.created_at,
                .file_size = self.getCartridgeSize(cartridge.path) catch 0,
                .access_count = cartridge.access_count,
                .rebuild_count = cartridge.rebuild_count,
                .last_accessed = cartridge.last_accessed,
            };
            list.appendAssumeCapacity(info);
        }

        return list.toOwnedSlice();
    }

    /// Get detailed cartridge metadata
    pub fn getCartridgeMetadata(self: *Self, name: []const u8) !DetailedMetadata {
        const cartridge = self.registered_cartridges.get(name) orelse return error.CartridgeNotFound;

        return DetailedMetadata{
            .format_name = cartridge.metadata.format_name,
            .schema_version = cartridge.metadata.schema_version,
            .build_time_ms = cartridge.metadata.build_time_ms,
            .source_db_hash = cartridge.metadata.source_db_hash,
            .builder_version = cartridge.metadata.builder_version,
            .max_age_seconds = cartridge.metadata.invalidation_policy.max_age_seconds,
            .min_new_txns = cartridge.metadata.invalidation_policy.min_new_txns,
            .max_new_txns = cartridge.metadata.invalidation_policy.max_new_txns,
            .pattern_count = cartridge.metadata.invalidation_policy.pattern_count,
        };
    }

    /// Check if cartridge needs rebuild
    pub fn checkRebuildStatus(self: *Self, name: []const u8, current_txn_id: u64) !RebuildStatus {
        const cartridge = self.registered_cartridges.get(name) orelse return error.CartridgeNotFound;

        const txn_delta = current_txn_id - cartridge.header.source_txn_id;
        const needs_rebuild = txn_delta >= cartridge.metadata.invalidation_policy.max_new_txns;

        const now = std.time.nanoTimestamp();
        const age_seconds: i128 = @divTrunc(now - @as(i128, @intCast(cartridge.header.created_at * 1_000_000)), 1_000_000_000);

        return RebuildStatus{
            .needs_rebuild = needs_rebuild,
            .reason = if (needs_rebuild) "Transaction threshold exceeded" else null,
            .txn_delta = txn_delta,
            .txn_threshold = cartridge.metadata.invalidation_policy.max_new_txns,
            .age_seconds = age_seconds,
            .age_threshold = cartridge.metadata.invalidation_policy.max_age_seconds,
        };
    }

    /// Get global statistics
    pub fn getGlobalStats(self: *const Self) GlobalStatistics {
        return GlobalStatistics{
            .total_cartridges = self.stats.total_cartridges,
            .total_accesses = self.stats.total_accesses,
            .total_rebuilds = self.stats.total_rebuilds,
            .total_bytes_served = self.stats.total_bytes_served,
            .total_errors = self.stats.total_errors,
            .registered_count = self.registered_cartridges.count(),
        };
    }

    /// Get health status of all cartridges
    pub fn getHealthStatus(self: *Self) !HealthReport {
        var healthy: u64 = 0;
        var stale: u64 = 0;
        const error_count: u64 = 0;

        var issues = ArrayListManaged(Issue).init(self.allocator);

        var it = self.registered_cartridges.iterator();
        while (it.next()) |entry| {
            const cartridge = entry.value_ptr.*;
            const now = std.time.nanoTimestamp();
            const age_ms = (now - @as(i128, @intCast(cartridge.header.created_at * 1_000_000))) / 1_000_000;
            const age_threshold_ms = cartridge.metadata.invalidation_policy.max_age_seconds * 1000;

            if (age_ms > 0 and age_ms >= @as(i128, @intCast(age_threshold_ms))) {
                stale += 1;
                try issues.append(.{
                    .cartridge_name = entry.key_ptr.*,
                    .severity = .warning,
                    .message = "Cartridge age exceeds threshold",
                    .details = try std.fmt.allocPrint(
                        self.allocator,
                        "Age: {d}s, Threshold: {d}s",
                        .{ age_ms / 1000, age_threshold_ms / 1000 }
                    ),
                });
            } else {
                healthy += 1;
            }
        }

        return HealthReport{
            .healthy_count = healthy,
            .stale_count = stale,
            .error_count = error_count,
            .issues = issues.toOwnedSlice(),
        };
    }

    /// Record a rebuild event
    pub fn recordRebuild(self: *Self, name: []const u8) !void {
        var cartridge = self.registered_cartridges.getPtr(name) orelse return error.CartridgeNotFound;
        cartridge.rebuild_count += 1;
        self.stats.total_rebuilds += 1;
    }

    /// Export cartridge state as JSON
    pub fn exportStateJson(self: *Self, writer: anytype) !void {
        try writer.writeAll("{");

        // Global stats
        try writer.writeAll("\"stats\":{");
        try writer.print("total_cartridges:{},total_accesses:{},total_rebuilds:{}", .{
            self.stats.total_cartridges,
            self.stats.total_accesses,
            self.stats.total_rebuilds,
        });
        try writer.writeAll("},");

        // Cartridges
        try writer.writeAll("\"cartridges\":[");
        var first = true;
        var it = self.registered_cartridges.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            const c = entry.value_ptr.*;
            try writer.print(
                \\{{"name":"{s}","type":"{s}","entries":{},"accesses":{},"rebuilds":{}}}
            , .{
                entry.key_ptr.*,
                c.header.cartridge_type.toString(),
                c.header.entry_count,
                c.access_count,
                c.rebuild_count,
            });
        }
        try writer.writeAll("]}");
    }

    /// Get cartridge file size
    fn getCartridgeSize(self: *Self, path: []const u8) !u64 {
        _ = self;
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        return file.getEndPos();
    }
};

/// Cartridge information summary
pub const CartridgeInfo = struct {
    name: []const u8,
    path: []const u8,
    cartridge_type: format.CartridgeType,
    source_txn_id: u64,
    entry_count: u64,
    created_at: u64,
    file_size: u64,
    access_count: u64,
    rebuild_count: u64,
    last_accessed: i128,
};

/// Detailed metadata view
pub const DetailedMetadata = struct {
    format_name: []const u8,
    schema_version: format.CartridgeMetadata.SchemaVersion,
    build_time_ms: u64,
    source_db_hash: [32]u8,
    builder_version: []const u8,
    max_age_seconds: u64,
    min_new_txns: u64,
    max_new_txns: u64,
    pattern_count: u32,
};

/// Rebuild status
pub const RebuildStatus = struct {
    needs_rebuild: bool,
    reason: ?[]const u8,
    txn_delta: u64,
    txn_threshold: u64,
    age_seconds: i128,
    age_threshold: u64,
};

/// Global statistics
pub const GlobalStatistics = struct {
    total_cartridges: u64,
    total_accesses: u64,
    total_rebuilds: u64,
    total_bytes_served: u64,
    total_errors: u64,
    registered_count: usize,
};

/// Health issue severity
pub const IssueSeverity = enum {
    info,
    warning,
    err,
};

/// Health issue
pub const Issue = struct {
    cartridge_name: []const u8,
    severity: IssueSeverity,
    message: []const u8,
    details: []const u8,

    pub fn deinit(self: *Issue, allocator: std.mem.Allocator) void {
        allocator.free(self.details);
    }
};

/// Health report
pub const HealthReport = struct {
    healthy_count: u64,
    stale_count: u64,
    error_count: u64,
    issues: []Issue,

    pub fn deinit(self: *HealthReport, allocator: std.mem.Allocator) void {
        for (self.issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(self.issues);
    }
};

/// Introspection query builder
pub const QueryBuilder = struct {
    filters: ArrayListManaged(Filter),
    sort_by: ?SortField = null,
    sort_desc: bool = true,
    limit_value: ?usize = null,

    const Filter = struct {
        field: Field,
        op: ComparisonOp,
        value: Value,
    };

    const Field = enum {
        name,
        cartridge_type,
        entry_count,
        created_at,
        access_count,
        rebuild_count,
        file_size,
    };

    const ComparisonOp = enum {
        eq,
        neq,
        gt,
        gte,
        lt,
        lte,
        contains,
    };

    const SortField = enum {
        name,
        created_at,
        access_count,
        entry_count,
        file_size,
    };

    const Value = union(enum) {
        string: []const u8,
        integer: u64,
        cartridge_type: format.CartridgeType,
    };

    pub fn init(allocator: std.mem.Allocator) QueryBuilder {
        return QueryBuilder{
            .filters = ArrayListManaged(Filter).init(allocator),
            .sort_by = null,
            .sort_desc = true,
            .limit_value = null,
        };
    }

    pub fn deinit(self: *QueryBuilder) void {
        self.filters.deinit();
    }

    pub fn filterType(self: *QueryBuilder, cartridge_type: format.CartridgeType) !void {
        try self.filters.append(.{
            .field = .cartridge_type,
            .op = .eq,
            .value = .{ .cartridge_type = cartridge_type },
        });
    }

    pub fn filterMinEntries(self: *QueryBuilder, count: u64) !void {
        try self.filters.append(.{
            .field = .entry_count,
            .op = .gte,
            .value = .{ .integer = count },
        });
    }

    pub fn sortByName(self: *QueryBuilder, desc: bool) *QueryBuilder {
        self.sort_by = .name;
        self.sort_desc = desc;
        return self;
    }

    pub fn sortByAccessCount(self: *QueryBuilder, desc: bool) *QueryBuilder {
        self.sort_by = .access_count;
        self.sort_desc = desc;
        return self;
    }

    pub fn limit(self: *QueryBuilder, n: usize) *QueryBuilder {
        self.limit_value = n;
        return self;
    }

    pub fn execute(self: *QueryBuilder, admin: *CartridgeAdmin) ![]CartridgeInfo {
        const all = try admin.listCartridges();
        defer {
            admin.allocator.free(all);
        }

        // Apply filters
        var filtered = ArrayListManaged(CartridgeInfo).init(admin.allocator);
        for (all) |info| {
            if (self.matchesFilters(info)) {
                try filtered.append(info);
            }
        }

        // Apply sort
        if (self.sort_by) |field| {
            self.sort(filtered.items, field);
        }

        // Apply limit
        if (self.limit_value) |n| {
            if (filtered.items.len > n) {
                filtered.items.len = n;
            }
        }

        return filtered.toOwnedSlice();
    }

    fn matchesFilters(self: *const QueryBuilder, info: CartridgeInfo) bool {
        for (self.filters.items) |filter| {
            const matches = switch (filter.field) {
                .cartridge_type => switch (filter.value) {
                    .cartridge_type => |ct| blk: {
                        break :blk switch (filter.op) {
                            .eq => info.cartridge_type == ct,
                            .neq => info.cartridge_type != ct,
                            else => false,
                        };
                    },
                    else => false,
                },
                .entry_count => switch (filter.value) {
                    .integer => |v| switch (filter.op) {
                        .eq => info.entry_count == v,
                        .neq => info.entry_count != v,
                        .gt => info.entry_count > v,
                        .gte => info.entry_count >= v,
                        .lt => info.entry_count < v,
                        .lte => info.entry_count <= v,
                        else => false,
                    },
                    else => false,
                },
                .access_count => switch (filter.value) {
                    .integer => |v| info.access_count >= v,
                    else => false,
                },
                else => true, // Not implemented for this field
            };

            if (!matches) return false;
        }
        return true;
    }

    fn sort(self: *const QueryBuilder, items: []CartridgeInfo, field: SortField) void {
        const sort_desc = self.sort_desc;
        switch (field) {
            .name => std.sort.insertion(CartridgeInfo, items, sort_desc, struct {
                fn lessThan(desc: bool, a: CartridgeInfo, b: CartridgeInfo) bool {
                    return if (desc)
                        std.mem.order(u8, a.name, b.name) == .gt
                    else
                        std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lessThan),
            .access_count => std.sort.insertion(CartridgeInfo, items, sort_desc, struct {
                fn lessThan(desc: bool, a: CartridgeInfo, b: CartridgeInfo) bool {
                    return if (desc) a.access_count > b.access_count else a.access_count < b.access_count;
                }
            }.lessThan),
            .entry_count => std.sort.insertion(CartridgeInfo, items, sort_desc, struct {
                fn lessThan(desc: bool, a: CartridgeInfo, b: CartridgeInfo) bool {
                    return if (desc) a.entry_count > b.entry_count else a.entry_count < b.entry_count;
                }
            }.lessThan),
            else => {},
        }
    }
};

/// Admin API with rebuild integration
pub const AdminWithRebuild = struct {
    admin: *CartridgeAdmin,
    queue: *rebuild.RebuildQueue,
    evaluator: *rebuild.TriggerEvaluator,

    /// Schedule a rebuild for a cartridge
    pub fn scheduleRebuild(
        self: *AdminWithRebuild,
        allocator: std.mem.Allocator,
        cartridge_name: []const u8
    ) !void {
        const cartridge = self.admin.registered_cartridges.get(cartridge_name) orelse return error.CartridgeNotFound;

        const reason = rebuild.RebuildReason{
            .trigger_type = .manual,
            .description = "Manual rebuild via admin API",
            .current_value = 0,
            .threshold_value = 0,
        };

        const task = try allocator.create(rebuild.RebuildTask);
        task.* = try rebuild.RebuildTask.init(
            allocator,
            cartridge.path,
            cartridge.header.cartridge_type,
            reason
        );

        try self.queue.enqueue(task);
    }

    /// Get rebuild queue status
    pub fn getRebuildQueueStatus(self: *const AdminWithRebuild) rebuild.QueueStats {
        return self.queue.getStats();
    }
};

// ==================== Tests ====================

test "CartridgeAdmin init" {
    var admin = CartridgeAdmin.init(std.testing.allocator, "cartridges");
    defer admin.deinit();

    try std.testing.expectEqual(@as(usize, 0), admin.registered_cartridges.count());
    try std.testing.expectEqual(@as(u64, 0), admin.stats.total_cartridges);
}

test "CartridgeAdmin register and unregister" {
    var admin = CartridgeAdmin.init(std.testing.allocator, "cartridges");
    defer admin.deinit();

    const header = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    const metadata = format.CartridgeMetadata.init("test", std.testing.allocator);

    try admin.registerCartridge("test", "test.cartridge", header, metadata);
    try std.testing.expectEqual(@as(usize, 1), admin.registered_cartridges.count());

    try admin.unregisterCartridge("test");
    try std.testing.expectEqual(@as(usize, 0), admin.registered_cartridges.count());
}

test "CartridgeAdmin getCartridgeInfo" {
    var admin = CartridgeAdmin.init(std.testing.allocator, "cartridges");
    defer admin.deinit();

    const header = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    const metadata = format.CartridgeMetadata.init("test", std.testing.allocator);

    try admin.registerCartridge("test", "test.cartridge", header, metadata);

    const info = try admin.getCartridgeInfo("test");
    try std.testing.expectEqualStrings("test", info.name);
    try std.testing.expectEqual(format.CartridgeType.pending_tasks_by_type, info.cartridge_type);
    try std.testing.expectEqual(@as(u64, 100), info.source_txn_id);
    try std.testing.expectEqual(@as(u64, 1), info.access_count); // Access is counted
}

test "CartridgeAdmin checkRebuildStatus" {
    var admin = CartridgeAdmin.init(std.testing.allocator, "cartridges");
    defer admin.deinit();

    const header = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    var metadata = format.CartridgeMetadata.init("test", std.testing.allocator);
    metadata.invalidation_policy.max_new_txns = 50; // This is a mutation

    try admin.registerCartridge("test", "test.cartridge", header, metadata);

    const status = try admin.checkRebuildStatus("test", 200);
    try std.testing.expect(status.needs_rebuild); // 200 - 100 = 100 >= 50
    try std.testing.expectEqual(@as(u64, 100), status.txn_delta);
}

test "CartridgeAdmin recordRebuild" {
    var admin = CartridgeAdmin.init(std.testing.allocator, "cartridges");
    defer admin.deinit();

    const header = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    const metadata = format.CartridgeMetadata.init("test", std.testing.allocator);

    try admin.registerCartridge("test", "test.cartridge", header, metadata);

    try admin.recordRebuild("test");
    const info = try admin.getCartridgeInfo("test");
    try std.testing.expectEqual(@as(u64, 1), info.rebuild_count);
}

test "CartridgeAdmin getGlobalStats" {
    var admin = CartridgeAdmin.init(std.testing.allocator, "cartridges");
    defer admin.deinit();

    const header = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    const metadata = format.CartridgeMetadata.init("test", std.testing.allocator);

    try admin.registerCartridge("test", "test.cartridge", header, metadata);
    _ = try admin.getCartridgeInfo("test");

    const stats = admin.getGlobalStats();
    try std.testing.expectEqual(@as(u64, 1), stats.total_cartridges);
    try std.testing.expectEqual(@as(u64, 1), stats.total_accesses);
    try std.testing.expectEqual(@as(usize, 1), stats.registered_count);
}

test "QueryBuilder filter and sort" {
    var admin = CartridgeAdmin.init(std.testing.allocator, "cartridges");
    defer admin.deinit();

    const header1 = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    const metadata1 = format.CartridgeMetadata.init("test1", std.testing.allocator);
    try admin.registerCartridge("test1", "test1.cartridge", header1, metadata1);

    const header2 = format.CartridgeHeader.init(.entity_index, 200);
    const metadata2 = format.CartridgeMetadata.init("test2", std.testing.allocator);
    try admin.registerCartridge("test2", "test2.cartridge", header2, metadata2);

    var builder = QueryBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.filterType(.pending_tasks_by_type);
    const results = try builder.execute(&admin);
    defer admin.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("test1", results[0].name);
}

test "QueryBuilder limit" {
    var admin = CartridgeAdmin.init(std.testing.allocator, "cartridges");
    defer admin.deinit();

    const header = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    const metadata1 = format.CartridgeMetadata.init("test1", std.testing.allocator);
    try admin.registerCartridge("test1", "test1.cartridge", header, metadata1);

    const metadata2 = format.CartridgeMetadata.init("test2", std.testing.allocator);
    try admin.registerCartridge("test2", "test2.cartridge", header, metadata2);

    var builder = QueryBuilder.init(std.testing.allocator);
    defer builder.deinit();
    _ = builder.limit(1);

    const results = try builder.execute(&admin);
    defer admin.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
}
