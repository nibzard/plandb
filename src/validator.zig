//! B+tree validator CLI tool.
//!
//! Provides utilities to dump and verify B+tree invariants for debugging.

const std = @import("std");
const testing = std.testing;
const pager = @import("pager.zig");

const PageType = pager.PageType;
const PageHeader = pager.PageHeader;
const BtreeNodeHeader = pager.BtreeNodeHeader;
const BtreeLeafPayload = pager.BtreeLeafPayload;
const BtreeInternalPayload = pager.BtreeInternalPayload;
const Pager = pager.Pager;

pub const ValidationError = error {
    InvalidPageType,
    InvalidBtreeMagic,
    KeysNotSorted,
    InvalidLeafLevel,
    InvalidInternalLevel,
    LeavesNotSameDepth,
    InvalidChildPageId,
    TreeEmpty,
    CycleDetected,
    DuplicateKeys,
} || std.mem.Allocator.Error;

pub const ValidationResult = struct {
    passed: bool,
    errors: []ValidationErrorDetails,
    stats: TreeStats,

    pub fn deinit(self: *const ValidationResult, allocator: std.mem.Allocator) void {
        for (self.errors) |*err| {
            err.deinit(allocator);
        }
        allocator.free(self.errors);
    }
};

pub const ValidationErrorDetails = struct {
    message: []const u8,
    page_id: u64,
    level: u16,

    pub fn deinit(self: *ValidationErrorDetails, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

pub const TreeStats = struct {
    total_pages: usize = 0,
    internal_nodes: usize = 0,
    leaf_nodes: usize = 0,
    tree_depth: u16 = 0,
    total_keys: usize = 0,
    min_leaf_keys: u16 = std.math.maxInt(u16),
    max_leaf_keys: u16 = 0,
};

pub const Validator = struct {
    allocator: std.mem.Allocator,
    pager: *Pager,
    errors: std.ArrayList(ValidationErrorDetails),
    visited: std.AutoHashMap(u64, void),
    stats: TreeStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, p: *Pager) Self {
        return .{
            .allocator = allocator,
            .pager = p,
            .errors = std.ArrayList(ValidationErrorDetails).initCapacity(allocator, 16) catch unreachable,
            .visited = std.AutoHashMap(u64, void).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.errors.items) |*err| {
            err.deinit(self.allocator);
        }
        self.errors.deinit(self.allocator);
        self.visited.deinit();
    }

    pub fn validateTree(self: *Self) !ValidationResult {
        const root_page_id = self.pager.getRootPageId();
        if (root_page_id == 0) {
            return ValidationResult{
                .passed = true,
                .errors = &[_]ValidationErrorDetails{},
                .stats = .{},
            };
        }

        self.visited.clearRetainingCapacity();
        self.stats = .{};
        _ = try self.validateNode(root_page_id, null);

        const errors = try self.errors.toOwnedSlice(self.allocator);
        return ValidationResult{
            .passed = errors.len == 0,
            .errors = errors,
            .stats = self.stats,
        };
    }

    fn validateNode(self: *Self, page_id: u64, expected_level: ?u16) !u16 {
        if (self.visited.get(page_id) != null) {
            try self.addError("Cycle detected: page visited twice", page_id, 0);
            return error.CycleDetected;
        }
        try self.visited.put(page_id, {});

        self.stats.total_pages += 1;

        var page_buffer: [pager.DEFAULT_PAGE_SIZE]u8 = undefined;
        try self.pager.readPage(page_id, &page_buffer);

        const header = try PageHeader.decode(page_buffer[0..PageHeader.SIZE]);

        const payload_start = PageHeader.SIZE;
        const payload_end = payload_start + header.payload_len;
        const payload_bytes = page_buffer[payload_start..payload_end];

        const node_header = std.mem.bytesAsValue(BtreeNodeHeader, payload_bytes[0..BtreeNodeHeader.SIZE]);

        const level = node_header.level;

        if (expected_level) |exp| {
            if (level != exp) {
                try self.addError("Level mismatch: expected {}, got {}", page_id, level);
            }
        }

        if (level == 0) {
            self.stats.leaf_nodes += 1;
            var leaf = BtreeLeafPayload{};
            leaf.validate(payload_bytes) catch |err| {
                try self.addError(@errorName(err), page_id, level);
            };
            self.stats.total_keys += node_header.key_count;
            self.stats.min_leaf_keys = @min(self.stats.min_leaf_keys, node_header.key_count);
            self.stats.max_leaf_keys = @max(self.stats.max_leaf_keys, node_header.key_count);
        } else {
            self.stats.internal_nodes += 1;
            var internal = BtreeInternalPayload{};
            internal.validate(payload_bytes) catch |err| {
                try self.addError(@errorName(err), page_id, level);
            };

            const child_count = node_header.key_count + 1;
            var max_child_depth: u16 = 0;
            for (0..child_count) |i| {
                const child_id = internal.getChildPageId(payload_bytes, @intCast(i)) catch |err| {
                    try self.addError(@errorName(err), page_id, level);
                    continue;
                };
                const child_depth = try self.validateNode(child_id, if (level > 0) level - 1 else null);
                if (i == 0) {
                    max_child_depth = child_depth;
                } else if (child_depth != max_child_depth) {
                    try self.addError("Children have different depths", page_id, level);
                }
            }
            self.stats.tree_depth = @max(self.stats.tree_depth, max_child_depth + 1);
            return max_child_depth + 1;
        }

        return 1;
    }

    fn addError(self: *Self, msg: []const u8, page_id: u64, level: u16) !void {
        const msg_copy = try self.allocator.dupe(u8, msg);
        try self.errors.append(self.allocator, ValidationErrorDetails{
            .message = msg_copy,
            .page_id = page_id,
            .level = level,
        });
    }
};

pub const DumpConfig = struct {
    show_keys: bool = true,
    show_values: bool = false,
    max_key_length: usize = 50,
    max_value_length: usize = 50,
};

pub fn dumpTree(allocator: std.mem.Allocator, db_path: []const u8, config: DumpConfig) !void {
    var p = try Pager.open(db_path, allocator);
    defer p.close();

    const root_page_id = p.getRootPageId();
    if (root_page_id == 0) {
        std.debug.print("Empty tree\n", .{});
        return;
    }

    std.debug.print("B+tree Dump\n", .{});
    std.debug.print("{s}\n\n", .{"=" ** 60});

    try dumpNode(allocator, &p, root_page_id, 0, config, "");
}

fn dumpNode(allocator: std.mem.Allocator, p: *Pager, page_id: u64, depth: u16, config: DumpConfig, prefix: []const u8) !void {
    var page_buffer: [pager.DEFAULT_PAGE_SIZE]u8 = undefined;
    try p.readPage(page_id, &page_buffer);

    const header = try PageHeader.decode(page_buffer[0..PageHeader.SIZE]);
    const payload_start = PageHeader.SIZE;
    const payload_end = payload_start + header.payload_len;
    const payload_bytes = page_buffer[payload_start..payload_end];

    const node_header = std.mem.bytesAsValue(BtreeNodeHeader, payload_bytes[0..BtreeNodeHeader.SIZE]);

    const is_leaf = node_header.level == 0;
    const node_type = if (is_leaf) "LEAF" else "INTERNAL";

    std.debug.print("{s}[{s}] Page {d} (level {d}, keys {d})\n", .{
        prefix, node_type, page_id, node_header.level, node_header.key_count,
    });

    if (is_leaf) {
        var leaf = BtreeLeafPayload{};
        var slot_buffer: [BtreeLeafPayload.MAX_KEYS_PER_LEAF + 1]u16 = undefined;
        _ = leaf.getSlotArray(payload_bytes, &slot_buffer);

        for (0..node_header.key_count) |i| {
            const entry = leaf.getEntry(payload_bytes, @intCast(i)) catch continue;

            const key_display = if (entry.key.len > config.max_key_length)
                entry.key[0..config.max_key_length]
            else
                entry.key;

            const value_display = if (config.show_values and entry.value.len > 0)
                if (entry.value.len > config.max_value_length)
                    entry.value[0..config.max_value_length]
                else
                    entry.value
            else
                "";

            if (config.show_values) {
                std.debug.print("{s}  [{d}] \"{s}\" => \"{s}\"\n", .{
                    prefix, i, key_display, value_display,
                });
            } else {
                std.debug.print("{s}  [{d}] \"{s}\"\n", .{ prefix, i, key_display });
            }
        }

        if (node_header.right_sibling != 0) {
            std.debug.print("{s}  -> sibling: {d}\n", .{ prefix, node_header.right_sibling });
        }
    } else {
        var internal = BtreeInternalPayload{};
        const child_count = node_header.key_count + 1;

        for (0..child_count) |i| {
            const child_id = internal.getChildPageId(payload_bytes, @intCast(i)) catch continue;

            if (i < node_header.key_count) {
                const sep_key = internal.getSeparatorKey(payload_bytes, @intCast(i)) catch continue;
                const sep_display = if (sep_key.len > config.max_key_length)
                    sep_key[0..config.max_key_length]
                else
                    sep_key;
                std.debug.print("{s}  child[{d}] (page {d}) separator: \"{s}\"\n", .{
                    prefix, i, child_id, sep_display,
                });
            } else {
                std.debug.print("{s}  child[{d}] (page {d})\n", .{ prefix, i, child_id });
            }
        }

        if (depth < 10) {
            const child_prefix = try std.fmt.allocPrint(allocator, "{s}  ", .{prefix});
            defer allocator.free(child_prefix);

            for (0..child_count) |i| {
                const child_id = internal.getChildPageId(payload_bytes, @intCast(i)) catch continue;
                try dumpNode(allocator, p, child_id, depth + 1, config, child_prefix);
            }
        } else {
            std.debug.print("{s}  ... (max depth reached)\n", .{prefix});
        }
    }

    std.debug.print("\n", .{});
}

pub fn runValidate(allocator: std.mem.Allocator, db_path: []const u8) !void {
    var p = try Pager.open(db_path, allocator);
    defer p.close();

    var validator = Validator.init(allocator, &p);
    defer validator.deinit();

    const result = try validator.validateTree();
    defer result.deinit(allocator);

    std.debug.print("B+tree Validation Results\n", .{});
    std.debug.print("{s}\n\n", .{"=" ** 60});

    std.debug.print("Statistics:\n", .{});
    std.debug.print("  Total pages: {d}\n", .{result.stats.total_pages});
    std.debug.print("  Internal nodes: {d}\n", .{result.stats.internal_nodes});
    std.debug.print("  Leaf nodes: {d}\n", .{result.stats.leaf_nodes});
    std.debug.print("  Tree depth: {d}\n", .{result.stats.tree_depth});
    std.debug.print("  Total keys: {d}\n", .{result.stats.total_keys});
    std.debug.print("  Keys per leaf: {d} - {d}\n", .{ result.stats.min_leaf_keys, result.stats.max_leaf_keys });

    if (result.passed) {
        std.debug.print("\n✅ All invariants PASSED\n", .{});
    } else {
        std.debug.print("\n❌ Validation FAILED\n", .{});
        std.debug.print("\nErrors:\n", .{});
        for (result.errors) |err| {
            std.debug.print("  [{d}:{d}] {s}\n", .{ err.page_id, err.level, err.message });
        }
        return error.ValidationFailed;
    }
}
