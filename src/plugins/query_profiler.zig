//! Query performance profiler for identifying slow queries and optimization opportunities
//!
//! Tracks per-query execution statistics:
//! - Per-query execution tracking
//! - Hot path identification (slow queries, hot keys)
//! - Index usage statistics
//! - Query plan visualization

const std = @import("std");

/// Query execution profile
pub const QueryProfile = struct {
    query_id: u64,
    query_text: []const u8,
    execution_count: u64,
    total_duration_ns: i64,
    min_duration_ns: i64,
    max_duration_ns: i64,
    avg_duration_ns: i64,
    last_executed_ms: u64,
    rows_scanned: u64,
    rows_returned: u64,
    index_used: ?[]const u8,
    tables_accessed: []const []const u8,

    pub fn deinit(self: QueryProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.query_text);
        if (self.index_used) |iu| allocator.free(iu);
        for (self.tables_accessed) |t| allocator.free(t);
        allocator.free(self.tables_accessed);
    }
};

/// Hot key result (frequently accessed keys)
pub const HotKeyResult = struct {
    key_name: []const u8,
    access_count: u64,
    avg_duration_ns: i64,
    last_accessed_ms: u64,

    pub fn deinit(self: HotKeyResult, allocator: std.mem.Allocator) void {
        allocator.free(self.key_name);
    }
};

/// Index usage statistics
pub const IndexStats = struct {
    index_name: []const u8,
    table_name: []const u8,
    lookups: u64,
    scans: u64,
    hits: u64,
    misses: u64,
    hit_rate: f64,
    avg_lookup_ns: i64,

    pub fn deinit(self: IndexStats, allocator: std.mem.Allocator) void {
        allocator.free(self.index_name);
        allocator.free(self.table_name);
    }
};

/// Query plan node for visualization
pub const PlanNode = struct {
    node_id: u64,
    node_type: NodeType,
    description: []const u8,
    estimated_cost: f64,
    actual_cost: f64,
    rows_produced: u64,
    duration_ns: i64,
    children: []const PlanNode,

    pub fn deinit(self: PlanNode, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        for (self.children) |*c| c.deinit(allocator);
        allocator.free(self.children);
    }

    pub const NodeType = enum {
        scan,
        index_scan,
        filter,
        join,
        aggregate,
        sort,
        limit,
        project,
        union,
        intersect,
    };
};

/// Query profiling session
pub const ProfilingSession = struct {
    session_id: u64,
    start_ms: u64,
    end_ms: ?u64,
    query_count: u64,
    profiles: std.StringHashMap(QueryProfile),

    pub fn init(allocator: std.mem.Allocator) ProfilingSession {
        return ProfilingSession{
            .session_id = std.crypto.random.int(u64),
            .start_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000))),
            .end_ms = null,
            .query_count = 0,
            .profiles = std.StringHashMap(QueryProfile).init(allocator),
        };
    }

    pub fn deinit(self: ProfilingSession) void {
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            self.profiles.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.profiles.allocator);
        }
        self.profiles.deinit();
    }
};

/// Query performance profiler plugin
pub const QueryProfilerPlugin = struct {
    allocator: std.mem.Allocator,
    session: ProfilingSession,
    config: Config,
    hot_keys: std.StringHashMap(u64),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
    ) !Self {
        return Self{
            .allocator = allocator,
            .session = ProfilingSession.init(allocator),
            .config = config,
            .hot_keys = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.session.deinit();

        var it = self.hot_keys.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.hot_keys.deinit();
    }

    /// Record a query execution
    pub fn recordQuery(
        self: *Self,
        query_text: []const u8,
        duration_ns: i64,
        rows_scanned: u64,
        rows_returned: u64,
        index_used: ?[]const u8,
    ) !void {
        const query_id = std.hash.Wyhash.hash(0, query_text);

        const entry = try self.session.profiles.getOrPut(query_text);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, query_text);
            entry.value_ptr.* = QueryProfile{
                .query_id = query_id,
                .query_text = try self.allocator.dupe(u8, query_text),
                .execution_count = 0,
                .total_duration_ns = 0,
                .min_duration_ns = std.math.maxInt(i64),
                .max_duration_ns = 0,
                .avg_duration_ns = 0,
                .last_executed_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000))),
                .rows_scanned = 0,
                .rows_returned = 0,
                .index_used = if (index_used) |iu| try self.allocator.dupe(u8, iu) else null,
                .tables_accessed = &.{},
            };
        }

        const profile = &entry.value_ptr.*;

        profile.execution_count += 1;
        profile.total_duration_ns += duration_ns;
        profile.min_duration_ns = @min(profile.min_duration_ns, duration_ns);
        profile.max_duration_ns = @max(profile.max_duration_ns, duration_ns);
        profile.avg_duration_ns = @divTrunc(profile.total_duration_ns, profile.execution_count);
        profile.rows_scanned += rows_scanned;
        profile.rows_returned += rows_returned;
        profile.last_executed_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp(), 1_000_000)));

        self.session.query_count += 1;

        // Track hot keys (simplified - would extract from query)
        _ = self.trackHotKey(query_text);
    }

    /// Get slow queries (above threshold)
    pub fn getSlowQueries(
        self: *Self,
        threshold_ms: i64,
    ) ![]const QueryProfile {
        var results = std.ArrayList(QueryProfile).init(self.allocator, {};

        var it = self.session.profiles.iterator();
        while (it.next()) |entry| {
            const profile = entry.value_ptr.*;
            const avg_ms = @divTrunc(profile.avg_duration_ns, 1_000_000);

            if (avg_ms > threshold_ms) {
                const copy = try self.copyProfile(profile);
                try results.append(copy);
            }
        }

        return results.toOwnedSlice();
    }

    /// Get hot keys (frequently accessed)
    pub fn getHotKeys(
        self: *Self,
        min_access_count: u64,
    ) ![]const HotKeyResult {
        var results = std.ArrayList(HotKeyResult).init(self.allocator, {};

        var it = self.hot_keys.iterator();
        while (it.next()) |entry| {
            const count = entry.value_ptr.*;
            if (count >= min_access_count) {
                const result = HotKeyResult{
                    .key_name = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .access_count = count,
                    .avg_duration_ns = 0, // Would need separate tracking
                    .last_accessed_ms = 0,
                };
                try results.append(result);
            }
        }

        // Sort by access count descending
        std.sort.insert(HotKeyResult, results.items, {}, compareHotKeysDesc);

        return results.toOwnedSlice();
    }

    /// Get scan ratio (rows scanned / rows returned)
    pub fn getScanRatio(self: *Self) !f64 {
        var total_scanned: u64 = 0;
        var total_returned: u64 = 0;

        var it = self.session.profiles.iterator();
        while (it.next()) |entry| {
            total_scanned += entry.value_ptr.rows_scanned;
            total_returned += entry.value_ptr.rows_returned;
        }

        if (total_returned == 0) return 0;
        return @as(f64, @floatFromInt(total_scanned)) / @as(f64, @floatFromInt(total_returned));
    }

    /// Generate query execution plan visualization
    pub fn generatePlan(
        self: *Self,
        query_text: []const u8,
    ) !PlanNode {
        _ = query_text;

        // Simplified plan - real implementation would parse and optimize
        return PlanNode{
            .node_id = 1,
            .node_type = .scan,
            .description = try self.allocator.dupe(u8, "Full table scan"),
            .estimated_cost = 100.0,
            .actual_cost = 100.0,
            .rows_produced = 1000,
            .duration_ns = 5_000_000,
            .children = &.{},
        };
    }

    /// Get profiling summary
    pub fn getSummary(self: *Self) !Summary {
        var total_queries: u64 = 0;
        var total_duration_ns: i64 = 0;
        var total_scanned: u64 = 0;
        var total_returned: u64 = 0;

        var it = self.session.profiles.iterator();
        while (it.next()) |entry| {
            const profile = entry.value_ptr.*;
            total_queries += profile.execution_count;
            total_duration_ns += profile.total_duration_ns;
            total_scanned += profile.rows_scanned;
            total_returned += profile.rows_returned;
        }

        return Summary{
            .total_queries = total_queries,
            .total_duration_ms = @divTrunc(total_duration_ns, 1_000_000),
            .avg_query_ms = if (total_queries > 0)
                @divTrunc(total_duration_ns, @as(i64, @intCast(total_queries))) / 1_000_000
            else
                0,
            .scan_ratio = if (total_returned > 0)
                @as(f64, @floatFromInt(total_scanned)) / @as(f64, @floatFromInt(total_returned))
            else
                0,
            .unique_queries = self.session.profiles.count(),
        };
    }

    fn trackHotKey(self: *Self, key: []const u8) !bool {
        const entry = try self.hot_keys.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, key);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
        return true;
    }

    fn copyProfile(self: *Self, profile: QueryProfile) !QueryProfile {
        var tables = std.ArrayList([]const u8).init(self.allocator, {};
        for (profile.tables_accessed) |t| {
            try tables.append(try self.allocator.dupe(u8, t));
        }

        return QueryProfile{
            .query_id = profile.query_id,
            .query_text = try self.allocator.dupe(u8, profile.query_text),
            .execution_count = profile.execution_count,
            .total_duration_ns = profile.total_duration_ns,
            .min_duration_ns = profile.min_duration_ns,
            .max_duration_ns = profile.max_duration_ns,
            .avg_duration_ns = profile.avg_duration_ns,
            .last_executed_ms = profile.last_executed_ms,
            .rows_scanned = profile.rows_scanned,
            .rows_returned = profile.rows_returned,
            .index_used = if (profile.index_used) |iu| try self.allocator.dupe(u8, iiu) else null,
            .tables_accessed = try tables.toOwnedSlice(),
        };
    }
};

fn compareHotKeysDesc(
    lhs: HotKeyResult,
    rhs: HotKeyResult,
) bool {
    return lhs.access_count > rhs.access_count;
}

/// Profiling summary
pub const Summary = struct {
    total_queries: u64,
    total_duration_ms: i64,
    avg_query_ms: i64,
    scan_ratio: f64,
    unique_queries: usize,
};

/// Profiler configuration
pub const Config = struct {
    /// Slow query threshold in milliseconds
    slow_query_threshold_ms: i64 = 100,
    /// Minimum hot key access count
    hot_key_threshold: u64 = 100,
    /// Maximum profiles to keep in memory
    max_profiles: usize = 10000,
};

// Tests
test "ProfilingSession.init" {
    const allocator = std.testing.allocator;
    var session = ProfilingSession.init(allocator);
    defer session.deinit();

    try std.testing.expect(session.session_id != 0);
    try std.testing.expectEqual(@as(usize, 0), session.profiles.count());
}

test "QueryProfilerPlugin.recordQuery" {
    const allocator = std.testing.allocator;

    const plugin = try QueryProfilerPlugin.init(
        allocator,
        undefined,
        .{},
    );
    defer plugin.deinit();

    try plugin.recordQuery("SELECT * FROM test", 5_000_000, 100, 50, null);

    const summary = try plugin.getSummary();
    try std.testing.expectEqual(@as(u64, 1), summary.total_queries);
}
